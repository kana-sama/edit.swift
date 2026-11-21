import AppKit

@MainActor
final class DocumentWindow: NSObject, NSWindowDelegate {
    enum CloseChoice {
        case save(to: URL?)
        case discard
        case cancel
    }

    let window: NSWindow
    let editor: EditorTextView
    let scrollView: NSScrollView

    private unowned let app: Edit
    private(set) var fileURL: URL?
    private var savedText: NSString? = "" as NSString
    private var format = FileFormat()
    private var revision: FileRevision?
    private var normalFrame: NSRect?
    private var pendingFullScreen = false
    private var saving = false
    private var promptingToClose = false

    var isBusy: Bool { saving || promptingToClose }
    var isReusable: Bool { fileURL == nil && !window.isDocumentEdited && !isBusy }

    init(app: Edit, placement: WindowPlacement? = nil) {
        self.app = app
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        (scrollView, editor) = EditorTextView.scrollingEditor(in: window.contentLayoutRect)
        super.init()
        window.title = "Untitled"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = scrollView
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        editor.onTextChange = { [weak self] in self?.updateEditedState() }
        if let placement {
            restorePlacement(placement)
        } else {
            window.center()
        }
    }

    func present() {
        window.makeKeyAndOrderFront(nil)
        if pendingFullScreen { app.scheduleFullScreenRestore(for: self) }
    }

    func restoreFullScreen() -> Bool {
        guard pendingFullScreen && window.isVisible else { return false }
        normalFrame = window.frame
        window.toggleFullScreen(nil)
        return true
    }

    func restorePlacement(_ placement: WindowPlacement) {
        placement.restoreFrame(on: window)
        pendingFullScreen = placement.isFullScreen && !window.styleMask.contains(.fullScreen)
    }

    var placement: WindowPlacement {
        let fullScreen = window.styleMask.contains(.fullScreen) || pendingFullScreen
        let frame = fullScreen ? normalFrame ?? window.frame : window.frame
        return WindowPlacement(frame: frame, isFullScreen: fullScreen)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if normalFrame == nil { normalFrame = window.frame }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        pendingFullScreen = false
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        pendingFullScreen = false
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        normalFrame = nil
    }

    func load(_ file: FileBuffer) {
        updateIdentity(from: file)
        installText(file.text)
    }

    func restoreDraft(_ record: SessionDocument, text: String) {
        fileURL = record.path.map { URL(fileURLWithPath: $0) }
        savedText = fileURL == nil ? "" as NSString : nil
        format = record.format ?? FileFormat()
        revision = record.revision
        installText(text)
    }

    func sessionDocument() -> SessionDocument {
        SessionDocument(
            path: fileURL?.path,
            draft: window.isDocumentEdited ? editor.string : nil,
            format: fileURL == nil ? nil : format,
            revision: revision,
            placement: placement
        )
    }

    @discardableResult
    func save(asNew: Bool = false, to selectedURL: URL? = nil) async -> Bool {
        guard !saving else { return false }
        if selectedURL == nil, !asNew, fileURL != nil, revision != .missing, !window.isDocumentEdited {
            return true
        }
        saving = true
        defer { saving = false }

        var destination = selectedURL ?? fileURL
        if selectedURL == nil, destination == nil || asNew {
            guard !app.isAgentCheck else { return false }
            let panel = makeSavePanel()
            guard await response(to: panel) == .OK else { return false }
            destination = panel.url
        }
        guard let destination else { return false }
        let target = await Task.detached { FileBuffer.canonicalURL(destination) }.value
        guard app.reserveSave(to: target, for: self) else {
            await showError("The file is already open in another window.")
            return false
        }
        defer { app.finishSave(to: target) }

        let text = editor.string
        let format = format
        let expected = target == fileURL ? revision : nil

        do {
            let file: FileBuffer
            do {
                file = try await Task.detached {
                    try FileBuffer.save(text, to: target, format: format, expected: expected)
                }.value
            } catch FileBufferError.changedOnDisk {
                guard !app.isAgentCheck else {
                    await showError("The file changed on disk.")
                    return false
                }
                let alert = NSAlert()
                alert.messageText = "The file changed on disk."
                alert.informativeText = "Replace the on-disk version of “\(target.lastPathComponent)” with the text in Edit?"
                alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
                alert.addButton(withTitle: "Replace").hasDestructiveAction = true
                guard await response(to: alert) == .alertSecondButtonReturn else { return false }
                file = try await Task.detached { try FileBuffer.save(text, to: target, format: format, expected: nil) }.value
            }
            updateIdentity(from: file)
            updateTitle()
            updateEditedState()
            return true
        } catch {
            await showError("Could Not Save “\(target.lastPathComponent)”", detail: error.localizedDescription)
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isBusy && !app.isQuitting else { return false }
        guard window.isDocumentEdited else { return true }
        guard !app.isAgentCheck else { return false }

        promptingToClose = true
        Task { @MainActor in
            let choice = fileURL == nil ? await confirmUntitledClose() : await confirmNamedClose()
            await finishClose(choice)
        }
        return false
    }

    func finishClose(_ choice: CloseChoice) async {
        defer { promptingToClose = false }
        switch choice {
        case .save(let url):
            if await save(to: url), !window.isDocumentEdited { window.close() }
        case .discard:
            window.close()
        case .cancel:
            break
        }
    }

    private func confirmUntitledClose() async -> CloseChoice {
        let panel = makeSavePanel()
        panel.message = "Save this new document before closing? You can save it now or delete the draft."
        panel.showsTagField = false
        panel.canSelectHiddenExtension = false
        panel.isExtensionHidden = false

        let delete = DeleteDraftAction(panel: panel)
        let button = NSButton(title: "Delete", target: delete, action: #selector(DeleteDraftAction.deleteDraft(_:)))
        button.bezelStyle = .push
        button.hasDestructiveAction = true

        let encoding = NSTextField(labelWithString: "Plain Text Encoding: Unicode (UTF-8)")
        let accessory = NSStackView(views: [button, encoding])
        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 16
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory

        switch await response(to: panel) {
        case .OK:
            if let url = panel.url { return .save(to: url) }
        case .cancel:
            if delete.wasChosen { return .discard }
        default:
            break
        }
        return .cancel
    }

    private func confirmNamedClose() async -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(window.title)”?"
        alert.informativeText = "Your edits will be lost if you close the window without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        switch await response(to: alert) {
        case .alertFirstButtonReturn: return .save(to: nil)
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowWillClose(_ notification: Notification) {
        app.didClose(self)
    }

    func showError(_ title: String, detail: String = "") async {
        if app.isAgentCheck {
            FileHandle.standardError.write(Data("\(title) \(detail)\n".utf8))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        _ = await response(to: alert)
    }

    private func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.txt"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        return panel
    }

    private func response(to panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { result in
                panel.orderOut(nil)
                continuation.resume(returning: result)
            }
        }
    }

    private func response(to alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func installText(_ text: String) {
        editor.preferredLineEnding = format.lineEnding
        editor.string = text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.undoManager?.removeAllActions()
        updateTitle()
        updateEditedState()
    }

    private func updateIdentity(from file: FileBuffer) {
        fileURL = file.url
        revision = file.revision
        format = file.format
        savedText = file.text as NSString
        editor.preferredLineEnding = format.lineEnding
    }

    private func updateTitle() {
        window.representedURL = fileURL
        window.title = fileURL?.lastPathComponent ?? "Untitled"
    }

    private func updateEditedState() {
        let isEdited = savedText.map { !(editor.textStorage?.mutableString.isEqual($0) ?? false) } ?? true
        if isEdited != window.isDocumentEdited {
            window.isDocumentEdited = isEdited
        }
    }
}

@MainActor
private final class DeleteDraftAction: NSObject {
    private weak var panel: NSSavePanel?
    private(set) var wasChosen = false

    init(panel: NSSavePanel) {
        self.panel = panel
    }

    @objc func deleteDraft(_ sender: NSButton) {
        wasChosen = true
        panel?.cancel(sender)
    }
}
