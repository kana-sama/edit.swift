import AppKit

@MainActor
final class DocumentWindow: NSObject, NSWindowDelegate {
    enum CloseChoice {
        case save(to: URL?)
        case discard
        case cancel
    }

    enum CloseDestination {
        case window
        case buffer(FileBuffer?)
    }

    private struct AutosaveRequest {
        let generation: UInt
        let text: String
    }

    let window: NSWindow
    let editor: EditorTextView
    let scrollView: NSScrollView

    private unowned let app: Edit
    private(set) var fileURL: URL? {
        didSet {
            if oldValue != fileURL { detectedSyntaxLanguage = SyntaxLanguage.detected(at: fileURL) }
        }
    }
    private var detectedSyntaxLanguage: SyntaxLanguage = .plainText
    private(set) var fileIdentity: FileIdentity?
    private var savedText: NSString? = "" as NSString
    private var format = FileFormat()
    private var revision: FileRevision?
    private var normalFrame: NSRect?
    private var pendingFullScreen = false
    private var saving = false
    private var promptingToClose = false
    private var editGeneration: UInt = 0
    private var idleSave: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var queuedAutosave: AutosaveRequest?
    private var writingGeneration: UInt?
    private var autosaveFailure: (generation: UInt, detail: String, reported: Bool)?
    private var syntaxHighlighting: SyntaxHighlighting?
    private var findPanel: FindSidebar?
    private var appearanceObservation: NSKeyValueObservation?
    private(set) var manualSyntaxLanguage: SyntaxLanguage?

    var resolvedSyntaxLanguage: SyntaxLanguage {
        manualSyntaxLanguage ?? detectedSyntaxLanguage
    }

    func setSyntaxLanguage(_ language: SyntaxLanguage?) {
        guard manualSyntaxLanguage != language else { return }
        manualSyntaxLanguage = language
        app.syntaxOverrides.set(language, for: fileURL)
        updateTitle()
        refreshSyntax(immediate: true)
    }

    var isBusy: Bool { saving || promptingToClose }
    var canReplaceBuffer: Bool { !isBusy && window.attachedSheet == nil }
    var isReusable: Bool { fileURL == nil && !window.isDocumentEdited && canReplaceBuffer }

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
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateTitleIcon() }
        }
        window.contentView = scrollView
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        editor.onTextChange = { [weak self] in self?.textDidChange() }
        editor.onBlur = { [weak self] in self?.requestAutosave() }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedo(_:)), name: name, object: nil)
        }
        if let placement {
            restorePlacement(placement)
        } else {
            window.center()
        }
        if !app.isAgentCheck {
            let settings = FindSettings.current(in: .standard)
            if settings.visible { searchPanel(settings: settings).restoreVisibility() }
        }
    }

    func canPerformFind(_ command: FindCommand) -> Bool {
        if let findPanel { return findPanel.canPerform(command) }
        switch command {
        case .find, .replace, .toggleSidebar: return true
        default: return false
        }
    }

    func performFind(_ command: FindCommand) {
        guard !app.isQuitting, window.attachedSheet == nil, canPerformFind(command) else { return }
        searchPanel().perform(command)
    }

    func persistFindSettings() { findPanel?.persistSettings() }

    private func searchPanel(settings: FindSettings? = nil) -> FindSidebar {
        if let findPanel { return findPanel }
        let resolved = settings ?? (app.isAgentCheck ? FindSettings() : FindSettings.current(in: .standard))
        let panel = FindSidebar(document: self, settings: resolved, writesPreferences: !app.isAgentCheck)
        findPanel = panel
        editor.onFindEditorInteraction = { [weak panel] in panel?.editorInteracted() }
        editor.onFindViewportChange = { [weak panel] in panel?.viewportChanged() }
        return panel
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

    func windowDidResignKey(_ notification: Notification) {
        requestAutosave()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        requestAutosave()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reportAutosaveFailure()
    }

    func windowDidEndSheet(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.reportAutosaveFailure() }
    }

    func load(_ file: FileBuffer, storedSyntaxLanguage: String? = nil) {
        updateIdentity(from: file)
        manualSyntaxLanguage = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: fileURL)
        installText(file.text)
    }

    func restoreDraft(_ record: SessionDocument, text: String, identity: FileIdentity? = nil) {
        fileURL = record.path.map { URL(fileURLWithPath: $0) }
        fileIdentity = identity
        savedText = fileURL == nil ? "" as NSString : nil
        format = record.format ?? FileFormat()
        revision = record.revision
        manualSyntaxLanguage = record.syntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: fileURL)
        installText(text)
    }

    func sessionDocument() -> SessionDocument {
        SessionDocument(
            path: fileURL?.path,
            draft: window.isDocumentEdited ? editor.string : nil,
            format: fileURL == nil ? nil : format,
            revision: revision,
            placement: placement,
            syntaxLanguage: manualSyntaxLanguage?.rawValue
        )
    }

    @discardableResult
    func save(asNew: Bool = false, to selectedURL: URL? = nil, encoding: FileTextEncoding? = nil) async -> Bool {
        guard !saving else { return false }
        saving = true
        if editor.hasMarkedText() { editor.unmarkText() }
        defer {
            saving = false
            startRequestedAutosave()
            reportAutosaveFailure()
        }
        await autosaveTask?.value
        if selectedURL == nil, !asNew, fileURL != nil, revision != .missing, !window.isDocumentEdited {
            return true
        }

        var destination = selectedURL ?? fileURL
        var saveFormat = format.using(encoding ?? format.encoding)
        if selectedURL == nil, destination == nil || asNew {
            guard !app.isAgentCheck else { return false }
            let panel = makeSavePanel()
            let accessory = SaveEncodingAccessory(selected: saveFormat.encoding)
            panel.accessoryView = accessory
            guard await response(to: panel) == .OK else { return false }
            destination = panel.url
            saveFormat = saveFormat.using(accessory.selection)
        }
        guard let destination else { return false }
        let (target, identity) = await Task.detached {
            let url = FileBuffer.canonicalURL(destination)
            return (url, FileIdentity.at(url))
        }.value
        let promote = asNew || target != fileURL
        guard app.reserveSave(to: target, identity: identity, for: self) else {
            await showError("The file is in use by another window.")
            return false
        }
        defer { app.finishSave(to: target) }

        let text = editor.string
        let writtenGeneration = editGeneration
        let expected = target == fileURL ? revision : nil

        do {
            do {
                try await write(text, to: target, format: saveFormat, expected: expected)
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
                try await write(text, to: target, format: saveFormat, expected: nil)
            }
            if let queuedAutosave, queuedAutosave.generation <= writtenGeneration { self.queuedAutosave = nil }
            if window.isDocumentEdited { scheduleIdleAutosave() }
            if promote { await app.recentFiles.record(destination) }
            return true
        } catch {
            await showError("Could Not Save “\(target.lastPathComponent)”", detail: error.localizedDescription)
            return false
        }
    }

    private func write(_ text: String, to target: URL, format: FileFormat, expected: FileRevision?) async throws {
        let file = try await Task.detached {
            try FileBuffer.save(text, to: target, format: format, expected: expected)
        }.value
        let changedPath = fileURL != file.url
        let previousLanguage = resolvedSyntaxLanguage
        updateIdentity(from: file)
        if changedPath {
            app.syntaxOverrides.set(manualSyntaxLanguage, for: fileURL)
        }
        if resolvedSyntaxLanguage != previousLanguage {
            refreshSyntax(immediate: true)
        }
        updateTitle()
        updateEditedState()
        autosaveFailure = nil
    }

    func requestAutosave() {
        guard fileURL != nil, !app.isQuitting,
              window.isDocumentEdited || autosaveTask != nil || saving else { return }
        if editor.hasMarkedText() {
            scheduleIdleAutosave()
            return
        }
        guard queuedAutosave?.generation != editGeneration, writingGeneration != editGeneration,
              autosaveFailure?.generation != editGeneration else { return }
        queuedAutosave = AutosaveRequest(generation: editGeneration, text: editor.string)
        startRequestedAutosave()
    }

    private func startRequestedAutosave() {
        guard queuedAutosave != nil, autosaveTask == nil, !isBusy, !app.isQuitting else { return }
        autosaveTask = Task {
            while let request = queuedAutosave, !isBusy, !app.isQuitting {
                queuedAutosave = nil
                if editor.hasMarkedText() {
                    scheduleIdleAutosave()
                    break
                }
                await writeAutosave(request)
            }
            autosaveTask = nil
            reportAutosaveFailure()
        }
    }

    // Closing, replacing, and quitting hold off new background writes while draining this one.
    func flushAutosave() async {
        idleSave?.cancel()
        idleSave = nil
        await autosaveTask?.value
        queuedAutosave = nil
        if window.isDocumentEdited {
            await writeAutosave(AutosaveRequest(generation: editGeneration, text: editor.string), retryFailed: true)
        }
    }

    private func writeAutosave(_ request: AutosaveRequest, retryFailed: Bool = false) async {
        let generation = request.generation
        guard let target = fileURL, let revision, savedText?.isEqual(to: request.text) != true,
              retryFailed || autosaveFailure?.generation != generation else { return }
        writingGeneration = generation
        defer { writingGeneration = nil }
        guard app.reserveSave(to: target, identity: fileIdentity, for: self) else {
            autosaveFailure = (generation, "The file is in use by another window.", false)
            return
        }
        defer { app.finishSave(to: target) }
        do {
            try await write(request.text, to: target, format: format, expected: revision)
        } catch FileBufferError.changedOnDisk {
            autosaveFailure = (generation, "The file changed on disk. Use Save to review whether to replace it.", false)
        } catch {
            autosaveFailure = (generation, error.localizedDescription, false)
        }
    }

    func takeAutosaveFailure() -> String? {
        guard let failure = autosaveFailure, !failure.reported, window.isDocumentEdited else { return nil }
        autosaveFailure?.reported = true
        return "“\(window.title)” — \(failure.detail)"
    }

    private func reportAutosaveFailure() {
        guard let failure = autosaveFailure, !failure.reported, window.isDocumentEdited,
              !isBusy, !app.isQuitting, !app.isAgentCheck, window.isKeyWindow,
              NSApplication.shared.isActive, window.attachedSheet == nil else { return }
        autosaveFailure?.reported = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Autosave “\(window.title)”"
        alert.informativeText = failure.detail
        alert.beginSheetModal(for: window)
    }

    private func scheduleIdleAutosave() {
        idleSave?.cancel()
        idleSave = nil
        guard fileURL != nil, !app.isQuitting,
              window.isDocumentEdited || autosaveTask != nil || saving else { return }
        idleSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            idleSave = nil
            requestAutosave()
        }
    }

    @objc private func undoOrRedo(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager, manager === editor.undoManager else { return }
        textDidChange()
    }

    private func textDidChange() {
        editGeneration &+= 1
        updateEditedState()
        scheduleIdleAutosave()
        refreshSyntax(immediate: false)
    }

    private func refreshSyntax(immediate: Bool) {
        let language = resolvedSyntaxLanguage
        if language == .plainText {
            syntaxHighlighting?.cancel()
            return
        }
        if syntaxHighlighting == nil {
            syntaxHighlighting = SyntaxHighlighting(editor: editor)
        }
        syntaxHighlighting?.update(language: language, immediate: immediate)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        guard window.isDocumentEdited || autosaveTask != nil else { return true }
        promptingToClose = true
        Task { await closeBuffer(destination: .window) }
        return false
    }

    func newBuffer() async {
        await replaceBuffer(with: nil)
    }

    @discardableResult
    func replaceBuffer(with file: FileBuffer?) async -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        promptingToClose = true
        return await closeBuffer(destination: .buffer(file))
    }

    @discardableResult
    private func closeBuffer(destination: CloseDestination) async -> Bool {
        if editor.hasMarkedText() { editor.unmarkText() }
        let wasEditable = editor.isEditable
        editor.isEditable = false
        defer {
            editor.isEditable = wasEditable
            promptingToClose = false
            startRequestedAutosave()
        }

        await flushAutosave()
        let choice: CloseChoice
        if !window.isDocumentEdited {
            choice = .discard
        } else if app.isAgentCheck {
            choice = .cancel
        } else if fileURL == nil {
            let sheet = UntitledCloseSheet(window: window) { [self] destination, encoding in
                await save(to: destination, encoding: encoding)
            }
            choice = await sheet.confirmClose() ? .discard : .cancel
        } else {
            choice = await confirmNamedClose()
        }
        return await finishClose(choice, destination: destination)
    }

    @discardableResult
    func finishClose(_ choice: CloseChoice, destination: CloseDestination = .window) async -> Bool {
        switch choice {
        case .save(let url):
            guard await save(to: url), !window.isDocumentEdited else { return false }
        case .discard:
            break
        case .cancel:
            return false
        }

        switch destination {
        case .buffer(let file):
            autosaveFailure = nil
            editor.breakUndoCoalescing()
            if let file {
                // Saving the outgoing draft to the target already installed the latest revision.
                if file.url != fileURL { load(file) }
            } else {
                fileURL = nil
                manualSyntaxLanguage = nil
                fileIdentity = nil
                savedText = "" as NSString
                format = FileFormat()
                revision = nil
                installText("")
            }
            window.makeFirstResponder(editor)
        case .window:
            window.close()
        }
        return true
    }

    private func confirmNamedClose() async -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(window.title)”?"
        let consequence = "Closing this document without saving discards your edits."
        if let failure = autosaveFailure {
            alert.informativeText = failure.detail + "\n\n" + consequence
            autosaveFailure?.reported = true
        } else {
            alert.informativeText = consequence
        }
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
        persistFindSettings()
        syntaxHighlighting?.cancel()
        idleSave?.cancel()
        idleSave = nil
        queuedAutosave = nil
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
        editor.resetMultiCarets()
        editor.string = text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.undoManager?.removeAllActions()
        updateTitle()
        updateEditedState()
        refreshSyntax(immediate: true)
        findPanel?.bufferReplaced()
    }

    private func updateIdentity(from file: FileBuffer) {
        fileURL = file.url
        fileIdentity = file.identity
        revision = file.revision
        format = file.format
        savedText = file.text as NSString
        editor.preferredLineEnding = format.lineEnding
    }

    private func updateTitle() {
        if window.representedURL != fileURL { window.representedURL = fileURL }
        window.title = fileURL?.lastPathComponent ?? "Untitled"
        updateTitleIcon()
        findPanel?.updateName()
    }

    private func updateTitleIcon() {
        guard let fileURL else { return }
        window.standardWindowButton(.documentIconButton)?.image = FileIcons.image(
            for: fileURL, appearance: window.effectiveAppearance, language: manualSyntaxLanguage?.iconIdentifier
        )
    }

    private func updateEditedState() {
        let isEdited = savedText.map { !(editor.textStorage?.mutableString.isEqual($0) ?? false) } ?? true
        if isEdited != window.isDocumentEdited {
            window.isDocumentEdited = isEdited
        }
    }
}
