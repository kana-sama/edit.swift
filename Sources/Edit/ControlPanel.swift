import AppKit

@MainActor
final class ControlPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: Edit
    private let panel = ControlWindow()
    enum Mode { case files, commands, languages }

    private let input = NSTextField()
    private let leadingIcon = NSImageView()
    private let clearButton = NSButton()
    private let headerHeight: CGFloat = 44
    private let headerInset: CGFloat = 14
    private let iconSize: CGFloat = 18
    private let separatorHeight: CGFloat = 1
    private let rowSpacing: CGFloat = 2
    private static let searchImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    private lazy var history = ControlCommandHistory(persist: !app.isAgentCheck)
    private var commands: [String: ControlCommand] = [:]
    private var mode: Mode = .files
    private let progress = NSProgressIndicator()
    private let table = ControlTable()
    private let scroll = NSScrollView()
    private let feedback = NSTextField(labelWithString: "")
    private var listHeight: NSLayoutConstraint!
    private var feedbackHeight: NSLayoutConstraint!
    private weak var document: DocumentWindow?
    private weak var originalFocus: NSResponder?
    private var monitor: Any?
    private var entries: [ControlMatch] = []
    private var request: Task<Void, Never>?
    private var generation = 0
    private var opening = 0
    private var pending = false
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

    private func show(in document: DocumentWindow, mode: Mode = .files,
                      failure: (query: String, id: String, message: String)? = nil) {
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
        let query = failure?.query ?? ""
        input.stringValue = query
        clearButton.isHidden = query.isEmpty
        apply(ControlMatching.rank(sourceEntries(), query: query), selected: failure?.id ?? initialID)
        if let failure {
            feedback.stringValue = failure.message
            feedback.isHidden = false
        }
        position()
        if !app.isAgentCheck {
            document.window.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            focusQuery()
            (input.currentEditor() as? NSTextView)?.undoManager?.removeAllActions()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return intercept(event)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(parentResized),
                                                   name: NSWindow.didResizeNotification, object: document.window)
        }
        if failure == nil { refreshFiles(for: document) }
    }

    private func configure(_ mode: Mode) {
        self.mode = mode
        leadingIcon.image = mode == .commands ? Self.commandImage : Self.searchImage
        let hint: String
        switch mode {
        case .files: hint = "Search recent files"
        case .commands: hint = "Search commands"
        case .languages: hint = "Search languages"
        }
        input.placeholderString = hint
        input.setAccessibilityLabel(hint)
    }

    private func switchMode(to mode: Mode, query: String) {
        configure(mode)
        input.stringValue = query
        focusQuery()
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
        deferredRefresh = false
        setSearching(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: document.window)
        if panel.parent === document.window { document.window.removeChildWindow(panel) }
        panel.orderOut(nil)
        table.clearHover()
        if restoreFocus && !app.isAgentCheck {
            document.window.makeKey()
            document.window.makeFirstResponder(originalFocus ?? document.editor)
        }
        originalFocus = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(restoreFocus: false)
    }

    @objc private func parentResized() { position() }

    private func position() {
        guard let parent = document?.window else { return }
        let width = min(600, max(240, parent.frame.width - 32))
        let messageHeight = feedback.isHidden ? 0 : feedback.intrinsicContentSize.height + 16
        // AppKit's inset table provides a top gap but no space after the last row.
        let edgePadding = entries.isEmpty ? 0 : table.rect(ofRow: 0).minY
        if scroll.contentInsets.bottom != edgePadding {
            scroll.contentInsets.bottom = edgePadding
        }
        let room = parent.frame.height - headerHeight - separatorHeight - messageHeight - 104 - 2 * edgePadding
        let rowCount = min(entries.count, 10, max(1, Int(room / (table.rowHeight + rowSpacing))))
        let trailingPadding = rowCount == entries.count ? edgePadding : 0
        let resultsHeight = rowCount == 0 ? 0 : table.rect(ofRow: rowCount - 1).maxY + trailingPadding
        listHeight.constant = resultsHeight
        feedbackHeight.constant = messageHeight
        scroll.isHidden = rowCount == 0
        let panelHeight = headerHeight + separatorHeight + resultsHeight + messageHeight
        let top = parent.frame.maxY - min(85, max(24, (parent.frame.height - panelHeight) / 2))
        panel.setFrame(NSRect(x: parent.frame.midX - width / 2, y: top - panelHeight,
                              width: width, height: panelHeight), display: panel.isVisible)
        panel.contentView?.layoutSubtreeIfNeeded()
        if rowCount == entries.count && scroll.contentView.bounds.origin != .zero {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private static let commandImage: NSImage = {
        // Use the prompt marker's shape from the Rust editor in the native search icon slot.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.labelColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
            let origin = NSPoint(x: rect.midX - 6, y: rect.midY - 4)
            let chevron = NSBezierPath()
            chevron.move(to: origin)
            for (x, y) in [(6.0, 3.5), (6, 4.5), (0, 8), (0, 6.5), (4.25, 4), (0, 1.5)] {
                chevron.line(to: NSPoint(x: origin.x + x, y: origin.y + y))
            }
            chevron.close()
            NSColor.labelColor.setFill()
            chevron.fill()
            NSBezierPath(roundedRect: NSRect(x: origin.x + 7.5, y: origin.y + 6.5, width: 4.5, height: 1.5),
                         xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
        return image
    }()

    private func setSearching(_ searching: Bool) {
        leadingIcon.isHidden = searching
        if searching {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private func buildPanel() {
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.title = "Control"

        let appearance = ControlSurface()
        appearance.material = .menu
        appearance.blendingMode = .behindWindow
        appearance.state = .active
        appearance.wantsLayer = true
        appearance.layer?.cornerRadius = 14
        appearance.layer?.masksToBounds = true
        appearance.layer?.borderWidth = 0.5
        appearance.updateBorder()
        panel.contentView = appearance

        input.isBordered = false
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 14)
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.setAccessibilitySubrole(.searchField)
        input.delegate = self
        leadingIcon.contentTintColor = .secondaryLabelColor
        leadingIcon.imageScaling = .scaleNone
        leadingIcon.setAccessibilityElement(false)
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.isBordered = false
        clearButton.isHidden = true
        clearButton.target = self
        clearButton.action = #selector(clearQuery)
        clearButton.setAccessibilityLabel("Clear search")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityElement(false)
        let separator = NSBox()
        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.rowHeight = 23
        table.intercellSpacing = NSSize(width: 0, height: rowSpacing)
        table.focusRingType = .none
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
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.drawsBackground = false
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)

        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        let feedbackArea = NSView()
        feedbackHeight = feedbackArea.heightAnchor.constraint(equalToConstant: 0)
        for view in [leadingIcon, input, clearButton, progress, separator, scroll, feedbackArea] {
            view.translatesAutoresizingMaskIntoConstraints = false
            appearance.addSubview(view)
        }
        feedback.translatesAutoresizingMaskIntoConstraints = false
        feedbackArea.addSubview(feedback)
        NSLayoutConstraint.activate([
            leadingIcon.topAnchor.constraint(equalTo: appearance.topAnchor, constant: (headerHeight - iconSize) / 2),
            leadingIcon.leadingAnchor.constraint(equalTo: appearance.leadingAnchor, constant: headerInset),
            leadingIcon.widthAnchor.constraint(equalToConstant: iconSize),
            leadingIcon.heightAnchor.constraint(equalToConstant: iconSize),
            input.centerYAnchor.constraint(equalTo: leadingIcon.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: leadingIcon.trailingAnchor, constant: 6),
            input.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: leadingIcon.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: appearance.trailingAnchor, constant: -headerInset),
            clearButton.widthAnchor.constraint(equalTo: leadingIcon.widthAnchor),
            clearButton.heightAnchor.constraint(equalTo: leadingIcon.heightAnchor),
            progress.centerYAnchor.constraint(equalTo: leadingIcon.centerYAnchor),
            progress.centerXAnchor.constraint(equalTo: leadingIcon.centerXAnchor),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14),
            separator.topAnchor.constraint(equalTo: appearance.topAnchor, constant: headerHeight),
            separator.leadingAnchor.constraint(equalTo: appearance.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: appearance.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: separatorHeight),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: appearance.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: appearance.trailingAnchor),
            listHeight,
            feedbackArea.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            feedbackArea.leadingAnchor.constraint(equalTo: appearance.leadingAnchor),
            feedbackArea.trailingAnchor.constraint(equalTo: appearance.trailingAnchor),
            feedbackHeight,
            feedback.centerYAnchor.constraint(equalTo: feedbackArea.centerYAnchor),
            feedback.leadingAnchor.constraint(equalTo: feedbackArea.leadingAnchor, constant: headerInset),
            feedback.trailingAnchor.constraint(equalTo: feedbackArea.trailingAnchor, constant: -headerInset),
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
        let available = (ControlCommand.fromMenu(menu) + ControlCommand.editorCommands(for: document)
                         + ControlCommand.searchCommands(for: app)).filter {
            $0.isAvailable(in: document, focus: originalFocus)
        }
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
        clearButton.isHidden = query.isEmpty
        feedback.stringValue = ""
        pending = true
        request = Task { [self] in
            let worker = Task.detached(priority: .userInitiated) {
                ControlMatching.rank(rows, query: query)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, current == generation, pending else { return }
                setSearching(true)
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard current == generation, document != nil else { return }
            pending = false
            setSearching(false)
            apply(results, selected: id)
        }
    }

    @objc private func clearQuery() {
        input.stringValue = ""
        focusQuery()
        search(preserving: initialID)
    }

    private func focusQuery() {
        panel.makeFirstResponder(input)
        (input.currentEditor() as? NSTextView)?.allowsUndo = true
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
        feedback.stringValue = entries.isEmpty ? "No matching results" : ""
        feedback.isHidden = !entries.isEmpty
        position()
        if !results.isEmpty {
            let row = id.flatMap { key in results.firstIndex { $0.entry.id == key } } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            reveal(row)
        }
        updatingRows = false
        updateButtons(at: [table.selectedRow, table.hovered])
    }

    private func intercept(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if event.window !== panel { dismiss(restoreFocus: false) }
            return event
        }
        guard event.type == .keyDown, let document, event.window === panel || panel.isKeyWindow else { return event }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (key, modifiers) {
        case ("q", .command):
            return event
        case ("p", .command):
            toggle(in: document, mode: .files)
            return nil
        case ("p", [.command, .shift]):
            toggle(in: document, mode: .commands)
            return nil
        case ("w", .command):
            dismiss(restoreFocus: true)
            return nil
        case ("f", .command), ("f", [.command, .option]):
            dismiss(restoreFocus: true)
            document.performFind(modifiers.contains(.option) ? .replace : .find)
            return nil
        default:
            break
        }

        let field = input.currentEditor() as? NSTextView
        if field?.hasMarkedText() != true {
            switch (event.keyCode, modifiers) {
            case (53, []):
                dismiss(restoreFocus: true)
                return nil
            case (125, []):
                moveSelection(by: 1)
                return nil
            case (126, []):
                moveSelection(by: -1)
                return nil
            case (36, []), (76, []):
                activate(row: table.selectedRow)
                return nil
            case (36, _), (76, _):
                return nil
            case (51, []) where mode == .commands && field?.selectedRange() == NSRange(location: 0, length: 0):
                switchMode(to: .files, query: input.stringValue)
                (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
                return nil
            default:
                break
            }
        }

        // A targetless menu action can fall through from the key panel to the main document.
        sendToQuery(event, key: key, modifiers: modifiers, field: field)
        return nil
    }

    private func sendToQuery(_ event: NSEvent, key: String, modifiers: NSEvent.ModifierFlags, field: NSTextView?) {
        guard modifiers.contains(.command) else {
            panel.firstResponder?.keyDown(with: event)
            return
        }
        guard let field else { return }
        switch (key, modifiers) {
        case ("x", .command): field.cut(nil)
        case ("c", .command): field.copy(nil)
        case ("v", .command): field.paste(nil)
        case ("a", .command): field.selectAll(nil)
        case ("z", .command):
            if let undo = field.undoManager, undo.canUndo { undo.undo() }
        case ("z", [.command, .shift]):
            if let undo = field.undoManager, undo.canRedo { undo.redo() }
        default:
            // Command-arrow and Command-delete are native single-field navigation and deletion.
            if modifiers.isSubset(of: [.command, .shift]),
               [51, 117, 123, 124, 125, 126].contains(event.keyCode) {
                field.keyDown(with: event)
            }
        }
    }

    private func moveSelection(by step: Int) {
        guard !pending, !entries.isEmpty else { return }
        let row = (max(0, table.selectedRow) + step + entries.count) % entries.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        reveal(row)
    }

    private func reveal(_ row: Int) {
        if row == 0 || row == entries.count - 1 {
            let clip = scroll.contentView
            let bottom = table.rect(ofRow: row).maxY + scroll.contentInsets.bottom - clip.bounds.height
            clip.scroll(to: NSPoint(x: 0, y: row == 0 ? 0 : max(0, bottom)))
            scroll.reflectScrolledClipView(clip)
        } else if !table.visibleRect.contains(table.rect(ofRow: row)) {
            table.scrollRowToVisible(row)
        }
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
        let files = Array(ControlMatching.rank(fileEntries(), query: "").prefix(2))
        guard files.count == 2 else { throw CheckFailure.invalidPanel }
        apply(files, selected: files.last?.entry.id)
        let edgePadding = table.rect(ofRow: 0).minY
        guard !scroll.hasVerticalScroller, !scroll.hasHorizontalScroller,
              let content = panel.contentView, abs(scroll.frame.width - content.bounds.width) < 0.5,
              abs(scroll.frame.minY - content.bounds.minY) < 0.5,
              scroll.contentView.bounds.origin == .zero,
              edgePadding > 0, abs(scroll.contentView.bounds.maxY - table.rect(ofRow: 1).maxY - edgePadding) < 0.5,
              scroll.contentView.bounds.contains(table.rect(ofRow: 1)) else {
            throw CheckFailure.invalidPanel
        }
        apply(ControlMatching.rank(fileEntries(), query: "not-a-real-result"), selected: nil)
        guard table.numberOfRows == 0, !feedback.isHidden else { throw CheckFailure.invalidPanel }
        configure(.commands)
        let commands = sourceEntries()
        guard leadingIcon.image === Self.commandImage, !input.isBezeled, !input.drawsBackground,
              ControlMatching.rank(commands, query: "save").first?.entry.title == "File: Save",
              ControlMatching.rank(commands, query: "sva").first?.entry.title == "File: Save As…",
              commands.contains(where: { $0.title == "Move Caret Left" && $0.shortcut == "←" }) else {
            throw CheckFailure.invalidPanel
        }
        apply(ControlMatching.rank(commands, query: ""), selected: commands.last?.id)
        let lastRow = table.rect(ofRow: table.selectedRow)
        guard commands.count > 10, scroll.contentView.bounds.minY > 0,
              abs(scroll.contentView.bounds.maxY - lastRow.maxY - edgePadding) < 0.5,
              table.visibleRect.contains(lastRow) else { throw CheckFailure.invalidPanel }
        apply(files, selected: files.last?.entry.id)
        guard scroll.contentView.bounds.origin == .zero else { throw CheckFailure.invalidPanel }
        configure(.languages)
        let choices = sourceEntries()
        guard leadingIcon.image === Self.searchImage,
              choices.count == 25, choices.first?.id == "auto", choices[1].id == SyntaxLanguage.plainText.rawValue else {
            throw CheckFailure.invalidPanel
        }
        configure(.files)
        guard panel.makeFirstResponder(input), let field = input.currentEditor() as? NSTextView else {
            throw CheckFailure.invalidSearchField
        }
        field.insertText(">save", replacementRange: field.selectedRange())
        guard mode == .commands, field.string == "save", !clearButton.isHidden,
              leadingIcon.image === Self.commandImage, abs(leadingIcon.frame.midY - input.frame.midY) < 1 else {
            throw CheckFailure.invalidSearchField
        }
        clearQuery()
        guard field.string.isEmpty, clearButton.isHidden, input.currentEditor() === field else {
            throw CheckFailure.invalidSearchField
        }
        try checkKeyboardRouting()
    }

    private func checkKeyboardRouting() throws {
        let probe = app.makeDocument()
        let text = "one one\ntwo\nthree"
        let selection = NSRange(location: 0, length: 3)
        probe.editor.string = text
        probe.editor.setSelectedRange(selection)
        let count = app.documents.count
        show(in: probe, mode: .commands)
        defer { dismiss(restoreFocus: false) }
        focusQuery()

        func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
        }

        let protectedKeys: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("\r", 36, .command), ("\r", 36, [.command, .shift]),
            ("\u{F700}", 126, .option), ("\u{F701}", 125, [.command, .option]),
            ("]", 30, .command), ("d", 2, .command), ("u", 32, .command),
            ("n", 45, .command), ("o", 31, .command), ("s", 1, .command), ("=", 24, .command),
        ]
        for (characters, code, modifiers) in protectedKeys {
            guard intercept(key(characters, code, modifiers)) == nil else {
                throw CheckFailure.shortcutEscaped
            }
        }
        guard probe.editor.string == text, probe.editor.selectedRange() == selection, !probe.editor.hasSecondarySelections,
              app.documents.count == count, document === probe, mode == .commands,
              let query = input.currentEditor() as? NSTextView, let undo = query.undoManager,
              undo !== probe.editor.undoManager else {
            throw CheckFailure.shortcutEscaped
        }

        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let typed = intercept(key("x", 7))
        undo.endUndoGrouping()
        guard typed == nil, query.string == "x",
              intercept(key("a", 0, .command)) == nil,
              query.selectedRange() == NSRange(location: 0, length: 1),
              intercept(key("z", 6, .command)) == nil, query.string.isEmpty,
              intercept(key("Z", 6, [.command, .shift])) == nil, query.string == "x",
              probe.editor.string == text else { throw CheckFailure.invalidSearchField }
        undo.groupsByEvent = true

        query.setSelectedRange(NSRange(location: 1, length: 0))
        guard intercept(key("\u{F702}", 123, .command)) == nil,
              query.selectedRange() == NSRange(location: 0, length: 0) else {
            throw CheckFailure.invalidSearchField
        }

        guard intercept(key("p", 35, .command)) == nil, mode == .files, input.stringValue == "x",
              intercept(key("P", 35, [.command, .shift])) == nil, mode == .commands, input.stringValue == "x",
              intercept(key("w", 13, .command)) == nil, document == nil else {
            throw CheckFailure.shortcutEscaped
        }

        show(in: probe, mode: .commands)
        focusQuery()
        let results = ControlMatching.rank(sourceEntries(), query: "Insert Line Break")
        guard results.first?.entry.id == "insertNewline:" else { throw CheckFailure.shortcutEscaped }
        apply(results, selected: nil)
        probe.editor.setSelectedRange(NSRange(location: 3, length: 0))
        guard intercept(key("\r", 36)) == nil, document == nil, probe.editor.string == "one\n one\ntwo\nthree"
        else { throw CheckFailure.shortcutEscaped }
    }

    private enum CheckFailure: LocalizedError {
        case invalidPanel
        case invalidSearchField
        case shortcutEscaped

        var errorDescription: String? {
            switch self {
            case .invalidPanel: "Control did not render its recent list and empty state quietly."
            case .invalidSearchField: "Control did not preserve editing, switching modes, or clearing the search."
            case .shortcutEscaped: "Control did not keep document shortcuts separate from palette commands."
            }
        }
    }

    private func activate(row: Int) {
        guard !pending, entries.indices.contains(row), let document else { return }
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
        let query = input.stringValue
        dismiss(restoreFocus: true)
        let dismissedOpening = opening
        Task {
            do {
                try await app.openFile(recent.url, in: document)
            } catch {
                await app.recentFiles.removeIfMissing(recent.url)
                guard opening == dismissedOpening, self.document == nil, document.window.isKeyWindow else { return }
                show(in: document, failure: (query, entry.id, error.localizedDescription))
            }
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
        if command.item.action == #selector(Edit.toggleFindSidebar(_:)) {
            command.run(in: document)
            return
        }
        if command.item.action == #selector(Edit.showLanguageModes(_:)) {
            switchMode(to: .languages, query: "")
            return
        }
        dismiss(restoreFocus: true)
        command.run(in: document)
    }

    @objc private func dismissRecent(_ button: NSButton) {
        guard !pending, let id = button.identifier?.rawValue,
              let row = entries.firstIndex(where: { $0.entry.id == id }), let recent = entries[row].entry.recent else { return }
        let neighbor = row + 1 < entries.count ? entries[row + 1].entry.id : row > 0 ? entries[row - 1].entry.id : nil
        let selected = selectedID == id ? neighbor : selectedID
        app.recentFiles.dismiss(recent)
        search(preserving: selected)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ControlRow()
    }

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
            views.append(makeLabel(detail, highlights: match.detailCharacters, secondary: true, lineBreak: .byTruncatingHead))
        }
        if let shortcut = match.entry.shortcut {
            views.append(NSView())
            views.append(makeLabel(shortcut, highlights: [], secondary: true))
        }
        if match.entry.recent != nil {
            views.append(NSView())
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
        stack.spacing = 7
        return stack
    }

    private func makeLabel(
        _ text: String, highlights: Set<Int>, secondary: Bool, lineBreak: NSLineBreakMode = .byTruncatingTail
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        let size = secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .labelColor.withAlphaComponent(0.65) : .labelColor
        field.lineBreakMode = lineBreak
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: field.font!, .foregroundColor: field.textColor!, .paragraphStyle: paragraph
        ])
        var offset = 0
        for (index, character) in text.enumerated() {
            let length = String(character).utf16.count
            if highlights.contains(index) {
                styled.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold),
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
private final class ControlSurface: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
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
private final class ControlRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor.controlAccentColor.withAlphaComponent(dark ? 0.38 : 0.22).setFill()
        let selection = bounds.insetBy(dx: 8, dy: 0.5)
        NSBezierPath(roundedRect: selection, xRadius: 6, yRadius: 6).fill()
    }
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

    override func mouseExited(with event: NSEvent) { clearHover() }

    func clearHover() { setHover(-1) }

    private func setHover(_ row: Int) {
        guard row != hovered else { return }
        let previous = hovered
        hovered = row
        hoverChanged?(previous, row)
    }
}
