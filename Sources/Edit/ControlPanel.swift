import AppKit

@MainActor
final class ControlPanel: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: Edit
    private let panel = ControlWindow()
    enum Mode { case files, commands, languages }

    private let input = NSSearchField()
    private let commandMark = NSTextField(labelWithString: ">")
    private lazy var history = ControlCommandHistory(persist: !app.isAgentCheck)
    private var commands: [String: ControlCommand] = [:]
    private var mode: Mode = .files
    private let progress = NSProgressIndicator()
    private let table = ControlTable()
    private let scroll = NSScrollView()
    private let feedback = NSTextField(labelWithString: "")
    private var height: NSLayoutConstraint!
    private weak var document: DocumentWindow?
    private weak var originalFocus: NSResponder?
    private var monitor: Any?
    private var entries: [ControlMatch] = []
    private var request: Task<Void, Never>?
    private var generation = 0
    private var opening = 0
    private var pending = false
    private var activating = false
    private var updatingRows = false

    init(app: Edit) {
        self.app = app
        super.init()
        buildPanel()
    }

    func toggle(in document: DocumentWindow, mode: Mode = .files) {
        if self.document === document, self.mode == mode {
            dismiss(restoreFocus: true)
        } else if self.document === document {
            switchMode(to: mode, query: self.mode == .languages ? "" : input.stringValue)
        } else {
            show(in: document, mode: mode)
        }
    }

    private func show(in document: DocumentWindow, mode: Mode = .files) {
        dismiss(restoreFocus: false)
        guard document.window.attachedSheet == nil else { return }
        document.requestAutosave()
        self.document = document
        let focus = document.window.firstResponder
        if let field = focus as? NSTextView, field.isFieldEditor {
            originalFocus = (field.delegate as? NSControl) ?? focus
        } else {
            originalFocus = focus
        }

        configure(mode)
        input.stringValue = ""
        feedback.stringValue = ""
        apply(ControlMatching.rank(sourceEntries(), query: ""), selected: initialID)
        position()
        if !app.isAgentCheck {
            document.window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(input)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return intercept(event)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(parentResized),
                                                   name: NSWindow.didResizeNotification, object: document.window)
        }
        refreshFiles(for: document)
    }

    private func configure(_ mode: Mode) {
        self.mode = mode
        commandMark.isHidden = mode != .commands
        switch mode {
        case .files: input.placeholderString = "Search recent files"
        case .commands: input.placeholderString = "Search commands"
        case .languages: input.placeholderString = "Search languages"
        }
        input.setAccessibilityLabel(input.placeholderString)
    }

    private func switchMode(to mode: Mode, query: String) {
        configure(mode)
        input.stringValue = query
        panel.makeFirstResponder(input)
        if let field = input.currentEditor() as? NSTextView {
            field.undoManager?.removeAllActions()
            field.setSelectedRange(NSRange(location: query.utf16.count, length: 0))
        }
        search(preserving: initialID)
        if let document { refreshFiles(for: document) }
    }

    private func refreshFiles(for document: DocumentWindow) {
        guard mode == .files else { return }
        let current = opening
        Task { [weak self] in
            guard let self else { return }
            await app.recentFiles.prune()
            guard mode == .files, self.document === document, current == opening, !isHovering else { return }
            search(preserving: selectedID)
        }
    }

    func dismiss(restoreFocus: Bool) {
        guard let document else { return }
        self.document = nil
        opening &+= 1
        generation &+= 1
        request?.cancel()
        request = nil
        pending = false
        activating = false
        deferredRefresh = false
        progress.stopAnimation(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: document.window)
        if panel.parent === document.window { document.window.removeChildWindow(panel) }
        panel.orderOut(nil)
        if restoreFocus && !app.isAgentCheck {
            document.window.makeKey()
            document.window.makeFirstResponder(originalFocus ?? document.editor)
        }
        originalFocus = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if !activating { dismiss(restoreFocus: false) }
    }

    @objc private func parentResized() { position() }

    private func position() {
        guard let parent = document?.window else { return }
        let width = min(620, max(240, parent.frame.width - 32))
        let rows = min(10, max(1, entries.count))
        let listHeight = CGFloat(rows) * table.rowHeight
        height.constant = entries.isEmpty ? 0 : listHeight
        scroll.isHidden = entries.isEmpty
        let messageHeight: CGFloat = feedback.isHidden ? 0 : 23
        let panelHeight = listHeight * (entries.isEmpty ? 0 : 1) + 60 + messageHeight
        let top = parent.frame.maxY - min(85, max(24, (parent.frame.height - panelHeight) / 2))
        panel.setFrame(NSRect(x: parent.frame.midX - width / 2, y: top - panelHeight,
                              width: width, height: panelHeight), display: panel.isVisible)
    }

    private func buildPanel() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.title = "Control"

        let appearance = NSVisualEffectView()
        appearance.material = .popover
        appearance.blendingMode = .behindWindow
        appearance.state = .active
        appearance.wantsLayer = true
        appearance.layer?.cornerRadius = 14
        appearance.layer?.masksToBounds = true
        panel.contentView = appearance

        input.placeholderString = "Search recent files"
        input.sendsWholeSearchString = false
        input.delegate = self
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        commandMark.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        commandMark.textColor = .secondaryLabelColor
        commandMark.isHidden = true
        let header = NSStackView(views: [commandMark, input, progress])
        header.spacing = 8
        header.alignment = .centerY

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 38
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        table.target = self
        table.action = #selector(activateClickedRow)
        table.appearanceChanged = { [weak self] in self?.table.reloadData() }
        table.hoverChanged = { [weak self] previous, next in
            self?.updateButtons(at: [previous, next])
            if next < 0, let self, self.deferredRefresh {
                self.deferredRefresh = false
                self.search(preserving: self.selectedID)
            }
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true

        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [header, scroll, feedback])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        appearance.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: appearance.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: appearance.trailingAnchor),
            stack.topAnchor.constraint(equalTo: appearance.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: appearance.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: header.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: header.widthAnchor),
        ])
    }

    private var deferredRefresh = false
    private var isHovering: Bool {
        if table.hovered >= 0 { deferredRefresh = true }
        return table.hovered >= 0
    }

    private func fileEntries() -> [ControlEntry] {
        app.recentFiles.entries.map { file in
            ControlEntry(id: file.url.absoluteString, title: file.url.lastPathComponent,
                         detail: (file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                         recent: file)
        }
    }

    private var initialID: String? {
        guard mode == .languages, let document else { return nil }
        return document.manualSyntaxLanguage?.rawValue ?? "auto"
    }

    private func sourceEntries() -> [ControlEntry] {
        if mode == .files { return fileEntries() }
        guard let document else { return [] }
        if mode == .languages {
            let automatic = SyntaxLanguage.detected(at: document.fileURL)
            var entries = [ControlEntry(id: "auto", title: "Auto Detect", detail: automatic.displayName,
                                        shortcut: initialID == "auto" ? "✓" : nil,
                                        iconLanguage: automatic.iconIdentifier)]
            let languages = SyntaxLanguage.allCases.filter { $0 != .plainText }.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            entries.append(contentsOf: ([.plainText] + languages).map {
                ControlEntry(id: $0.rawValue, title: $0.displayName,
                             shortcut: initialID == $0.rawValue ? "✓" : nil, iconLanguage: $0.iconIdentifier)
            })
            return entries
        }
        guard let menu = NSApplication.shared.mainMenu else { return [] }
        let available = ControlCommand.fromMenu(menu).filter { $0.isAvailable(in: document, focus: originalFocus) }
        let arranged = history.arrange(available)
        commands = Dictionary(arranged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids: Set<String> = []
        return arranged.filter { ids.insert($0.id).inserted }.map(\.result)
    }

    private var selectedID: String? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].entry.id : nil
    }

    private func search(preserving id: String? = nil) {
        request?.cancel()
        generation &+= 1
        let current = generation
        let rows = sourceEntries()
        let query = input.stringValue
        feedback.stringValue = ""
        pending = true
        request = Task { [self] in
            let worker = Task.detached(priority: .userInitiated) {
                ControlMatching.rank(rows, query: query)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, current == generation, pending else { return }
                progress.startAnimation(nil)
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard current == generation, document != nil else { return }
            pending = false
            progress.stopAnimation(nil)
            apply(results, selected: id)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if mode == .files, input.stringValue.hasPrefix(">"),
           (input.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            switchMode(to: .commands, query: String(input.stringValue.dropFirst()))
        } else {
            search()
        }
    }

    private func apply(_ results: [ControlMatch], selected id: String?) {
        entries = results
        updatingRows = true
        table.reloadData()
        if !results.isEmpty {
            let row = id.flatMap { key in results.firstIndex { $0.entry.id == key } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updatingRows = false
        feedback.stringValue = entries.isEmpty ? "No matching results" : ""
        feedback.isHidden = !entries.isEmpty
        position()
        updateButtons(at: [table.selectedRow, table.hovered])
    }

    private func intercept(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if event.window !== panel { dismiss(restoreFocus: false) }
            return event
        }
        guard event.window === panel, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              (input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return event }
        switch event.keyCode {
        case 53: dismiss(restoreFocus: true)
        case 125: moveSelection(by: 1)
        case 126: moveSelection(by: -1)
        case 36, 76: activate(row: table.selectedRow)
        case 51 where mode == .commands && (input.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 0):
            let query = input.stringValue
            switchMode(to: .files, query: query)
            (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
        default: return event
        }
        return nil
    }

    private func moveSelection(by step: Int) {
        guard !pending, !entries.isEmpty else { return }
        let row = (max(0, table.selectedRow) + step + entries.count) % entries.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func activateClickedRow() { activate(row: table.clickedRow) }

    func checkHidden(in document: DocumentWindow) throws {
        guard app.isAgentCheck else { return }
        show(in: document)
        defer { dismiss(restoreFocus: false) }
        panel.layoutIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        guard !panel.isVisible, panel.contentView?.bounds.height ?? 0 > 0,
              table.numberOfRows > 0, table.selectedRow == 0 else {
            throw CheckFailure.invalidPanel
        }
        apply(ControlMatching.rank(fileEntries(), query: "not-a-real-result"), selected: nil)
        guard table.numberOfRows == 0, !feedback.isHidden else { throw CheckFailure.invalidPanel }
        configure(.commands)
        let commands = sourceEntries()
        guard !commands.isEmpty, ControlMatching.rank(commands, query: "save").first?.entry.title == "File: Save" else {
            throw CheckFailure.invalidPanel
        }
        configure(.languages)
        let choices = sourceEntries()
        guard choices.count == 25, choices.first?.id == "auto", choices[1].id == SyntaxLanguage.plainText.rawValue else {
            throw CheckFailure.invalidPanel
        }
    }

    private enum CheckFailure: LocalizedError {
        case invalidPanel
        var errorDescription: String? { "Control did not render its recent list and empty state quietly." }
    }

    private func activate(row: Int) {
        guard !pending, !activating, entries.indices.contains(row), let document else { return }
        let entry = entries[row].entry
        if mode == .commands {
            runCommand(entry, in: document)
            return
        }
        if mode == .languages {
            let language = SyntaxLanguage(rawValue: entry.id)
            document.setSyntaxLanguage(language)
            dismiss(restoreFocus: true)
            return
        }
        guard let recent = entry.recent else { return }
        activating = true
        document.requestAutosave()
        let current = generation
        Task {
            do {
                if try await app.openFile(recent.url, promoteExisting: false) != nil, self.document === document {
                    dismiss(restoreFocus: false)
                }
            } catch {
                await app.recentFiles.removeIfMissing(recent.url)
                guard self.document === document, current == generation else {
                    activating = false
                    return
                }
                let results = ControlMatching.rank(fileEntries(), query: input.stringValue)
                let replacement = results.indices.contains(row) ? results[row].entry.id : results.last?.entry.id
                apply(results, selected: results.contains(where: { $0.entry.id == recent.url.absoluteString })
                      ? recent.url.absoluteString : replacement)
                feedback.stringValue = error.localizedDescription
                feedback.isHidden = false
                position()
            }
            activating = false
        }
    }

    private func runCommand(_ entry: ControlEntry, in document: DocumentWindow) {
        guard let command = commands[entry.id], command.isAvailable(in: document, focus: originalFocus) else {
            search(preserving: entry.id)
            return
        }
        history.record(command.id)
        if command.item.action == #selector(Edit.showGoToFile(_:)) {
            switchMode(to: .files, query: "")
            return
        }
        if command.item.action == #selector(Edit.showLanguageModes(_:)) {
            switchMode(to: .languages, query: "")
            return
        }
        dismiss(restoreFocus: true)
        command.run()
    }

    @objc private func dismissRecent(_ button: NSButton) {
        guard !pending, !activating, let id = button.identifier?.rawValue,
              let row = entries.firstIndex(where: { $0.entry.id == id }), let recent = entries[row].entry.recent else { return }
        let neighbor = row + 1 < entries.count ? entries[row + 1].entry.id : row > 0 ? entries[row - 1].entry.id : nil
        let selected = selectedID == id ? neighbor : selectedID
        app.recentFiles.dismiss(recent)
        search(preserving: selected)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updatingRows {
            updateButtons(at: Array(entries.indices))
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = entries[row]
        let title = makeLabel(match.entry.title, highlights: match.titleCharacters, secondary: false)
        var views: [NSView] = []
        let file = match.entry.recent
        let language = match.entry.iconLanguage ?? file.flatMap { app.manualIconLanguage(for: $0) }
        if file != nil || language != nil,
           let image = FileIcons.image(for: file?.url, appearance: tableView.effectiveAppearance, language: language) {
            let icon = NSImageView(image: image)
            icon.setAccessibilityElement(false)
            views.append(icon)
        }
        views.append(title)
        if let detail = match.entry.detail {
            let path = makeLabel(detail, highlights: match.detailCharacters, secondary: true)
            path.lineBreakMode = .byTruncatingHead
            views.append(path)
        }
        if let shortcut = match.entry.shortcut {
            views.append(makeLabel(shortcut, highlights: [], secondary: true))
        }
        if match.entry.recent != nil {
            let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Remove from recent files")!,
                                  target: self, action: #selector(dismissRecent(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(match.entry.id)
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.alphaValue = row == table.selectedRow || row == table.hovered ? 1 : 0
            button.isEnabled = button.alphaValue > 0
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
        return stack
    }

    private func makeLabel(_ text: String, highlights: Set<Int>, secondary: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = secondary ? .systemFont(ofSize: NSFont.smallSystemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        let styled = NSMutableAttributedString(string: text, attributes: [.font: field.font!, .foregroundColor: field.textColor!])
        var offset = 0
        for (index, character) in text.enumerated() {
            let length = String(character).utf16.count
            if highlights.contains(index) {
                styled.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                    range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        field.attributedStringValue = styled
        field.setContentCompressionResistancePriority(secondary ? .defaultLow : .defaultHigh, for: .horizontal)
        return field
    }

    private func updateButtons(at indices: [Int]) {
        for row in indices where entries.indices.contains(row) {
            guard let stack = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSStackView,
                  let button = stack.arrangedSubviews.last as? NSButton else { continue }
            let visible = row == table.selectedRow || row == table.hovered
            button.alphaValue = visible ? 1 : 0
            button.isEnabled = visible
        }
    }
}

@MainActor
private final class ControlWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ControlTable: NSTableView {
    private var tracking: NSTrackingArea?
    private(set) var hovered = -1
    var hoverChanged: ((Int, Int) -> Void)?
    var appearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) { setHover(-1) }

    private func setHover(_ row: Int) {
        guard row != hovered else { return }
        let previous = hovered
        hovered = row
        hoverChanged?(previous, row)
    }
}
