import AppKit

@MainActor
final class ScratchSaveSheet: NSObject {
    private static let contentWidth: CGFloat = 372
    private static let inset: CGFloat = 20

    private let parent: NSWindow
    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
    )
    private let nameField = NSTextField(string: "")
    private let attachment = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let layout = NSStackView()
    private let save: (String, URL?) async throws -> Void
    private var folders: [URL]
    private var selectedFolder: URL?
    private var busy = false

    init(window: NSWindow, name: String, folders: [URL], selectedFolder: URL?,
         save: @escaping (String, URL?) async throws -> Void) {
        parent = window
        self.save = save
        self.folders = folders.map(\.standardizedFileURL)
        self.selectedFolder = selectedFolder?.standardizedFileURL
        super.init()
        if let folder = self.selectedFolder { self.folders.append(folder) }
        nameField.stringValue = name
        configurePanel()
        updateAttachments()
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parent.beginSheet(panel) { [panel] _ in
                panel.orderOut(nil)
                continuation.resume()
            }
            nameField.selectText(nil)
            if let editor = nameField.currentEditor() {
                let basename = (nameField.stringValue as NSString).deletingPathExtension
                editor.selectedRange = NSRange(location: 0, length: basename.utf16.count)
            }
        }
    }

    private func configurePanel() {
        panel.title = "Save as Scratch"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = parent.alphaValue
        panel.ignoresMouseEvents = parent.ignoresMouseEvents

        let nameLabel = NSTextField(labelWithString: "Save As:")
        let attachmentLabel = NSTextField(labelWithString: "Attach to:")
        nameField.setAccessibilityLabel("Save As")
        attachment.setAccessibilityLabel("Attach to")
        attachment.target = self
        attachment.action = #selector(attachmentChanged)
        attachment.lineBreakMode = .byTruncatingMiddle
        attachment.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fields = NSGridView(views: [[nameLabel, nameField], [attachmentLabel, attachment]])
        fields.columnSpacing = 8
        fields.rowSpacing = 10
        fields.rowAlignment = .firstBaseline
        fields.yPlacement = .center
        fields.column(at: 0).xPlacement = .trailing
        fields.column(at: 0).width = 66
        fields.column(at: 1).xPlacement = .fill
        fields.column(at: 1).width = Self.contentWidth - fields.column(at: 0).width - fields.columnSpacing

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSView()
        footer.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: footer.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
        ])

        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true
        errorLabel.preferredMaxLayoutWidth = Self.contentWidth
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 14
        for view in [fields, errorLabel, footer] {
            layout.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }

        let content = NSView()
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
        ])
        panel.contentView = content
        panel.initialFirstResponder = nameField
        panel.defaultButtonCell = saveButton.cell as? NSButtonCell
        fitContent()
    }

    private func fitContent() {
        panel.setContentSize(NSSize(width: Self.contentWidth + 2 * Self.inset,
                                    height: layout.fittingSize.height + 2 * Self.inset))
    }

    private func updateAttachments() {
        var paths: Set<String> = []
        folders = folders.filter { paths.insert($0.path).inserted }
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let names = Dictionary(grouping: folders) { $0.lastPathComponent.lowercased() }
        let chooseTitle = "Choose Folder…"
        attachment.removeAllItems()
        attachment.addItem(withTitle: "Global")
        let global = attachment.lastItem
        var selected = global
        for folder in folders {
            let name = folder.lastPathComponent
            let key = name.lowercased()
            let distinguish = key == "global" || key == chooseTitle.lowercased() || names[key, default: []].count > 1
            let path = (folder.path as NSString).abbreviatingWithTildeInPath
            attachment.addItem(withTitle: distinguish ? "\(name) (\(path))" : name)
            let item = attachment.lastItem
            item?.representedObject = folder
            item?.toolTip = path
            if folder.path == selectedFolder?.path { selected = item }
        }
        attachment.menu?.addItem(.separator())
        attachment.addItem(withTitle: chooseTitle)
        attachment.select(selected)
    }

    @objc private func attachmentChanged() {
        guard !busy else { return }
        guard attachment.selectedItem === attachment.lastItem else {
            selectedFolder = attachment.selectedItem?.representedObject as? URL
            return
        }

        updateAttachments()
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.prompt = "Choose"
        chooser.directoryURL = selectedFolder
        chooser.alphaValue = panel.alphaValue
        chooser.ignoresMouseEvents = panel.ignoresMouseEvents
        chooser.beginSheetModal(for: panel) { [self] result in
            chooser.orderOut(nil)
            guard result == .OK, let folder = chooser.url?.standardizedFileURL else { return }
            selectedFolder = folder
            folders.append(folder)
            updateAttachments()
            panel.makeFirstResponder(attachment)
        }
    }

    @objc private func savePressed() {
        guard !busy, panel.attachedSheet == nil, panel.makeFirstResponder(nil) else { return }
        errorLabel.isHidden = true
        setBusy(true)
        fitContent()
        let name = nameField.stringValue
        let folder = selectedFolder
        Task {
            do {
                try await save(name, folder)
                parent.endSheet(panel, returnCode: .OK)
            } catch {
                errorLabel.stringValue = error.localizedDescription
                errorLabel.isHidden = false
                fitContent()
                setBusy(false)
                panel.makeFirstResponder(nameField)
            }
        }
    }

    @objc private func cancelPressed() {
        guard !busy, panel.attachedSheet == nil else { return }
        parent.endSheet(panel, returnCode: .cancel)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        for control: NSControl in [nameField, attachment, cancelButton, saveButton] {
            control.isEnabled = !value
        }
    }
}

extension ScratchSaveSheet {
    static func check() async throws {
        struct Failure: LocalizedError {
            let errorDescription: String?
            init(_ message: String) { errorDescription = message }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure("Scratch save sheet: \(message)") }
        }
        func waitFor(_ condition: () -> Bool, _ message: String) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure("Scratch save sheet: \(message)")
        }

        let parent = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 380),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.alphaValue = 0
        parent.ignoresMouseEvents = true
        parent.isReleasedWhenClosed = false
        parent.orderBack(nil)
        var unblock: CheckedContinuation<Void, Never>?
        defer {
            unblock?.resume()
            if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            parent.close()
        }

        let first = URL(filePath: "/example/one/Notes", directoryHint: .isDirectory)
        let second = URL(filePath: "/example/two/Notes", directoryHint: .isDirectory)
        var writes: [(String, URL?)] = []
        let detail = String(repeating: "Could not write scratch file. ", count: 8)
        let sheet = ScratchSaveSheet(window: parent, name: "Draft.txt", folders: [first, second],
                                     selectedFolder: second) { name, folder in
            writes.append((name, folder))
            if writes.count == 1 { throw Failure(detail) }
            await withCheckedContinuation { unblock = $0 }
        }
        sheet.panel.alphaValue = 0
        sheet.panel.ignoresMouseEvents = true
        let response = Task { await sheet.run() }
        try await waitFor({ parent.attachedSheet === sheet.panel }, "presentation")
        sheet.panel.layoutIfNeeded()
        let compactSize = sheet.panel.frame.size
        let saveEdge = sheet.saveButton.convert(sheet.saveButton.bounds, to: nil).maxX
        let fieldEdge = sheet.nameField.convert(sheet.nameField.bounds, to: nil).maxX
        try expect(abs(saveEdge - fieldEdge) < 1, "align the footer to the trailing edge of the inputs")
        try expect(sheet.nameField.currentEditor()?.selectedRange == NSRange(location: 0, length: 5),
                   "select the basename, excluding the extension")
        try expect(sheet.attachment.numberOfItems == 5, "deduplicate the current folder in the menu")
        try expect(sheet.attachment.selectedItem?.title.contains(second.path) == true,
                   "select the current folder and distinguish identically named folders")
        try expect(sheet.panel.defaultButtonCell === sheet.saveButton.cell && sheet.cancelButton.keyEquivalent == "\u{1b}",
                   "Save is the default and Escape cancels")

        sheet.attachment.select(sheet.attachment.lastItem)
        sheet.attachment.sendAction(sheet.attachment.action, to: sheet)
        try await waitFor({ sheet.panel.attachedSheet is NSOpenPanel }, "present the native folder chooser")
        guard let chooser = sheet.panel.attachedSheet as? NSOpenPanel else { throw Failure("Missing folder chooser") }
        chooser.cancel(nil)
        try await waitFor({ sheet.panel.attachedSheet == nil }, "dismiss the folder chooser")
        try expect(sheet.attachment.selectedItem?.title.contains(second.path) == true, "cancel leaves the attachment selected")

        sheet.saveButton.performClick(nil)
        try await waitFor({ !sheet.errorLabel.isHidden }, "show a failed write inline")
        try expect(writes[0] == ("Draft.txt", second), "submit the current filename and selected folder")
        try expect(sheet.panel.frame.width == compactSize.width && sheet.panel.frame.height > compactSize.height,
                   "wrap errors vertically without changing the sheet width")

        sheet.attachment.selectItem(at: 0)
        sheet.attachment.sendAction(sheet.attachment.action, to: sheet)
        sheet.nameField.currentEditor()?.string = "Retry.txt"
        sheet.saveButton.performClick(nil)
        try await waitFor({ unblock != nil }, "retry saving after correcting the inputs")
        try expect(writes[1] == ("Retry.txt", nil), "submit corrected filename and Global")
        try expect(!sheet.saveButton.isEnabled && !sheet.cancelButton.isEnabled && !sheet.attachment.isEnabled,
                   "hold the sheet open and disable actions during a write")
        sheet.saveButton.performClick(nil)
        try expect(writes.count == 2, "suppress duplicate writes")
        unblock?.resume()
        unblock = nil
        await response.value
        try expect(parent.attachedSheet == nil, "dismiss on successful write")

        let cancelled = ScratchSaveSheet(window: parent, name: "Untitled.txt", folders: [], selectedFolder: nil) { _, _ in
            writes.append(("Unexpected", nil))
        }
        cancelled.panel.alphaValue = 0
        cancelled.panel.ignoresMouseEvents = true
        let cancellation = Task { await cancelled.run() }
        try await waitFor({ parent.attachedSheet === cancelled.panel }, "present in a folderless window")
        try expect(cancelled.attachment.selectedItem?.title == "Global", "default to Global without a folder")
        cancelled.cancelButton.performClick(nil)
        await cancellation.value
        try expect(writes.count == 2, "cancel without saving")
    }
}
