import AppKit

@MainActor
final class ControlPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private unowned let app: Edit
    private let panel = ControlWindow()
    enum Mode {
        case files, commands, languages, documentSymbols, workspaceSymbols

        var isSymbolMode: Bool { self == .documentSymbols || self == .workspaceSymbols }
        var acceptsPins: Bool { self == .files || self == .commands }
        var hasPrefix: Bool { self == .commands || isSymbolMode }

        init?(prefix: Character?) {
            switch prefix {
            case ">": self = .commands
            case ":": self = .documentSymbols
            case "#": self = .workspaceSymbols
            default: return nil
            }
        }
    }

    private struct NavigationContext: Equatable {
        struct Session: Equatable {
            let server: LanguageServer
            let generation: Int
            let revision: Int

            @MainActor init(_ session: LanguageServerSession) {
                server = session.server
                generation = session.generation
                revision = session.revision
            }
        }

        let folder: URL?
        let openGeneration: UInt64
        let session: Session
        let workspaceSessions: [Session]

        @MainActor init(_ document: DocumentWindow) {
            let features = document.languageFeatures
            folder = document.folderURL
            openGeneration = document.openRequestGeneration
            session = Session(features.session)
            workspaceSessions = features.workspaceSessions.map(Session.init)
        }
    }

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
    private static let pinDragType = NSPasteboard.PasteboardType("dev.edit-swift.control-pin")
    private static let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    private static let scratchImage = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    private lazy var history = ControlCommandHistory(persist: !app.isAgentCheck)
    private lazy var pins = ControlPins(defaults: app.isAgentCheck ? nil : .standard)
    private var pinsChangedInPlace = false
    private var cachedPinnedRows: [Int]?
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
    private var keyboardLayouts = ControlKeyboardLayouts()
    private var request: Task<Void, Never>?
    private var folderScan: (scope: FolderFileSearch.Scope, task: Task<FolderFileSearch.Index, Never>)?
    private var scratchLoad: Task<[ScratchFile], Error>?
    private var resultsFolder: URL?
    private var navigationContext: NavigationContext?
    private var documentSymbols: (context: NavigationContext, symbols: [LSPSymbol])?
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
            let preservesQuery = self.mode.acceptsPins && mode.acceptsPins
            switchMode(to: mode, query: preservesQuery ? input.stringValue : "")
        } else {
            show(in: document, mode: mode)
        }
    }

    func folderDidChange(in document: DocumentWindow) {
        guard self.document === document, mode == .files || mode.isSymbolMode else { return }
        configure(mode)
        apply([], selected: nil, emptyMessage: nil)
        search()
    }

    func recentFilesDidChange(in document: DocumentWindow) {
        guard self.document === document, mode == .files, !pinsChangedInPlace, !isHovering else { return }
        search(preserving: selectedID)
    }

    func languageServerStateDidChange(in document: DocumentWindow) {
        guard self.document === document, mode.isSymbolMode else { return }
        let contextChanged = navigationContext != NavigationContext(document)
        if contextChanged { apply([], selected: nil, emptyMessage: nil) }
        search(preserving: selectedID)
    }

    func scratchesDidChange(recencyOnly: Bool = false) {
        scratchLoad?.cancel()
        scratchLoad = nil
        guard document != nil, mode == .files, !recencyOnly || !isHovering else { return }
        search(preserving: selectedID)
    }

    private func show(in document: DocumentWindow, mode: Mode = .files,
                      retry: (query: String, id: String, message: String?)? = nil) {
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
        let query = retry?.query ?? ""
        input.stringValue = query
        clearButton.isHidden = query.isEmpty
        let searchesFolder = mode == .files && document.folderURL != nil
        let deferred = searchesFolder || mode.isSymbolMode
        let source = deferred ? [] : sourceEntries()
        let pinnedFiles = mode == .files && !searchesFolder ? pinnedFileEntries(reusing: source) : []
        let rows = ControlMatching.rank(includingPins(pinnedFiles, in: source), query: query,
                                        alternateCharacters: alternateCharacters(for: query),
                                        preferShorterTitles: mode == .commands)
        apply(orderedRows(rows, pinnedFiles: pinnedFiles, query: query), selected: retry?.id ?? initialID,
              error: retry?.message, emptyMessage: mode.isSymbolMode ? nil : "No matching results")
        if mode == .files || mode.isSymbolMode {
            if searchesFolder, retry?.message == nil { feedback.isHidden = true }
            search(preserving: retry?.id ?? initialID, error: retry?.message)
        }
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
        if retry == nil { refreshFiles(for: document) }
    }

    private func configure(_ mode: Mode) {
        self.mode = mode
        let hint: String
        switch mode {
        case .files:
            hint = document?.folderURL == nil ? "Search recent files" : "Search files"
            leadingIcon.image = Self.searchImage
        case .commands:
            hint = "Search commands"
            leadingIcon.image = Self.commandImage
        case .languages:
            hint = "Search languages"
            leadingIcon.image = Self.searchImage
        case .documentSymbols:
            hint = "Enter a line number or document symbol"
            leadingIcon.image = Self.documentSymbolImage
        case .workspaceSymbols:
            hint = "Search workspace symbols"
            leadingIcon.image = Self.workspaceSymbolImage
        }
        input.placeholderString = hint
        input.setAccessibilityLabel(hint)
    }

    private func switchMode(to mode: Mode, query: String) {
        let resetsRows = self.mode != mode && (self.mode.isSymbolMode || mode.isSymbolMode)
        configure(mode)
        if resetsRows { apply([], selected: nil, emptyMessage: nil) }
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
        let recent = app.recentFiles.entries(in: document.folderURL)
        Task { [weak self] in
            guard let self else { return }
            await app.recentFiles.prune()
            guard current == opening,
                  app.recentFiles.entries(in: document.folderURL) != recent else { return }
            recentFilesDidChange(in: document)
        }
    }

    func dismiss(restoreFocus: Bool) {
        guard let document else { return }
        self.document = nil
        opening &+= 1
        generation &+= 1
        request?.cancel()
        request = nil
        folderScan?.task.cancel()
        folderScan = nil
        scratchLoad?.cancel()
        scratchLoad = nil
        resultsFolder = nil
        navigationContext = nil
        documentSymbols = nil
        pending = false
        deferredRefresh = false
        pinsChangedInPlace = false
        setSearching(false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: document.window)
        if panel.parent === document.window { document.window.removeChildWindow(panel) }
        panel.orderOut(nil)
        table.clearHover()
        if restoreFocus && !app.isAgentCheck {
            document.window.makeKey()
            if let originalFocus = originalFocus as? NSView, originalFocus.window === document.window,
               !originalFocus.isHiddenOrHasHiddenAncestor {
                document.window.makeFirstResponder(originalFocus)
            } else {
                document.focusContent()
            }
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

    private static let documentSymbolImage = markerImage(":")
    private static let workspaceSymbolImage = markerImage("#")

    private static func markerImage(_ marker: String) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let label = NSAttributedString(string: marker, attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

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
        table.registerForDraggedTypes([Self.pinDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.appearanceChanged = { [weak self] in self?.table.reloadData() }
        table.hoverChanged = { [weak self] previous, next in
            self?.updateButtons(at: [previous, next])
            if next < 0, let self, self.deferredRefresh {
                self.deferredRefresh = false
                if !self.pinsChangedInPlace { self.search(preserving: self.selectedID) }
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
        app.recentFiles.entries(in: document?.folderURL)
            .compactMap { fileEntry($0.url, canonical: $0.canonicalURL, recent: $0) }
    }

    private func fileEntry(_ url: URL, canonical: URL, recent: RecentFile? = nil,
                           identity: FileIdentity? = nil) -> ControlEntry? {
        guard !FolderFileSearch.isExcludedFile(url), !FolderFileSearch.isExcludedFile(canonical) else { return nil }
        let relative = document?.folderURL.flatMap { folder in
            FolderFileSearch.relativeDirectory(of: url, in: folder)
                ?? FolderFileSearch.relativeDirectory(of: canonical, in: folder)
        }
        let parent = relative ?? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return ControlEntry(id: url.absoluteString, title: url.lastPathComponent,
                            detail: parent.isEmpty ? nil : parent, recent: recent,
                            folderFileURL: recent == nil ? url : nil, folderFileIdentity: identity,
                            directoryDepth: relative.map(FolderFileSearch.directoryDepth))
    }

    private func pinnedFileEntries(reusing recent: [ControlEntry], scratches: [ControlEntry] = []) -> [ControlEntry] {
        let scratchesByID = Dictionary(uniqueKeysWithValues: scratches.compactMap { entry in
            entry.scratch.map { ($0.id, entry) }
        })
        return pins.entries.compactMap { pin in
            switch pin {
            case let .file(url, canonical, identity):
                recent.first(where: pin.matches) ?? fileEntry(url, canonical: canonical, identity: identity)
            case let .scratch(id): scratchesByID[id]
            case .command: nil
            }
        }
    }

    private func includingPins(_ pinned: [ControlEntry], in source: [ControlEntry]) -> [ControlEntry] {
        guard !pinned.isEmpty else { return source }
        let ids = Set(source.map(\.id))
        return source + pinned.filter { !ids.contains($0.id) }
    }

    private func orderedRows(_ results: [ControlMatch], pinnedFiles: [ControlEntry], query: String) -> [ControlMatch] {
        guard mode.acceptsPins, query.allSatisfy(\.isWhitespace), !pins.entries.isEmpty else { return results }
        let prefix: [ControlMatch]
        if mode == .files {
            prefix = ControlMatching.rank(pinnedFiles, query: "")
        } else {
            let byCommand = Dictionary(results.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
            prefix = pins.entries.compactMap { pin in
                guard case .command(let id) = pin else { return nil }
                return byCommand[id]
            }
        }
        let pinnedIDs = Set(prefix.map { $0.entry.id })
        return prefix + results.filter { !pinnedIDs.contains($0.entry.id) }
    }

    private var initialID: String? {
        guard mode == .languages, let document else { return nil }
        return document.manualSyntaxLanguage?.rawValue ?? "auto"
    }

    private func sourceEntries() -> [ControlEntry] {
        if mode == .files { return fileEntries() }
        if mode.isSymbolMode { return [] }
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
        let terminalSplits = ControlCommand.terminalCommands(for: document).filter {
            $0.isAvailable(in: document, focus: originalFocus)
        }
        let available = (ControlCommand.fromMenu(menu) + ControlCommand.editorCommands(for: document)
                         + ControlCommand.searchCommands(for: app)
                         + ControlCommand.markdownTableCommands(for: document)
                         + ControlCommand.languageServerCommands(for: document)).filter {
            $0.isAvailable(in: document, focus: originalFocus)
        }
        let arranged = terminalSplits + history.arrange(available)
        commands = Dictionary(arranged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ids: Set<String> = []
        return arranged.filter { ids.insert($0.id).inserted }.map(\.result)
    }

    #if EDIT_AGENT_CHECKS
    func checkTerminalCommands(in document: DocumentWindow, expected: Bool) throws {
        show(in: document, mode: .commands)
        defer { dismiss(restoreFocus: false) }
        let splitIDs = Set(["terminal.split-right", "terminal.split-down"])
        let shown = Set(entries.prefix(2).map(\.entry.id))
        let found = entries.contains { splitIDs.contains($0.entry.id) }
        guard expected ? shown == splitIDs : !found else { throw CheckFailure.shortcutEscaped }
    }
    #endif

    private var selectedID: String? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].entry.id : nil
    }

    private func scanFolder(_ scope: FolderFileSearch.Scope?) -> Task<FolderFileSearch.Index, Never>? {
        if let folderScan, folderScan.scope == scope { return folderScan.task }
        folderScan?.task.cancel()
        folderScan = scope.map { scope in
            (scope, Task.detached(priority: .userInitiated) { FolderFileSearch.index(in: scope) })
        }
        return folderScan?.task
    }

    private func loadScratches() -> Task<[ScratchFile], Error> {
        if let scratchLoad { return scratchLoad }
        let store = app.scratchStore
        let load = Task { try await store.files() }
        scratchLoad = load
        return load
    }

    private func search(preserving id: String? = nil, error: String? = nil) {
        request?.cancel()
        generation &+= 1
        let current = generation
        pinsChangedInPlace = false
        let query = input.stringValue
        clearButton.isHidden = query.isEmpty
        if mode.isSymbolMode {
            _ = scanFolder(nil)
            searchNavigation(query, generation: current, selected: id, message: error)
            return
        }
        let rows = sourceEntries()
        let pinnedFiles = mode == .files ? pinnedFileEntries(reusing: rows) : []
        let folder = mode == .files ? document?.folderURL : nil
        let path = folder == nil ? nil : FolderFileSearch.DirectoryQuery(query)
        let scope = folder.map { FolderFileSearch.Scope(folder: $0, components: path?.components) }
        let scan = scanFolder(query.allSatisfy(\.isWhitespace) ? nil : scope)
        let load = mode == .files && path == nil ? loadScratches() : nil
        let filter = path?.filter ?? query
        let alternateCharacters = alternateCharacters(for: filter)
        let searchablePins = path == nil ? pinnedFiles : []
        let rowsWithPins = folder == nil ? includingPins(pinnedFiles, in: rows) : rows
        let isFileSearch = mode == .files
        let isCommandSearch = mode == .commands
        if error == nil { feedback.stringValue = "" }
        pending = true
        request = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                var scratches: [ControlEntry] = []
                var scratchError: String?
                if let load {
                    do {
                        let folderPath = ScratchStore.folderPath(for: folder)
                        scratches = try await load.value.filter { $0.folderPath == folderPath }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                            .map(ControlEntry.init(scratch:))
                    } catch {
                        scratchError = "Couldn’t load scratches. \(error.localizedDescription)"
                    }
                }
                let results: [ControlMatch]
                if let scan {
                    let index = await scan.value
                    results = index.rank(rows, query: filter, alternateCharacters: alternateCharacters,
                                         pinnedFiles: searchablePins, scratches: scratches)
                } else if let folder {
                    results = FolderFileSearch.recentMatches(rows, scratches: scratches, in: folder)
                } else if isFileSearch {
                    results = ControlMatching.rankFiles(rowsWithPins + scratches, query: query,
                                                        alternateCharacters: alternateCharacters)
                } else {
                    results = ControlMatching.rank(rowsWithPins, query: query, alternateCharacters: alternateCharacters,
                                                   preferShorterTitles: isCommandSearch)
                }
                return (results, scratches, scratchError)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, current == generation, pending else { return }
                setSearching(true)
            }
            let (results, scratches, scratchError) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, let document, current == generation else { return }
            if mode == .files && document.folderURL != folder {
                configure(mode)
                search(preserving: id, error: error)
                return
            }
            pending = false
            resultsFolder = folder
            if scratchError != nil { scratchLoad = nil }
            setSearching(false)
            let orderedPins = scratches.isEmpty ? pinnedFiles : pinnedFileEntries(reusing: rows, scratches: scratches)
            apply(orderedRows(results, pinnedFiles: orderedPins, query: query), selected: id, error: error ?? scratchError)
        }
    }

    private func searchNavigation(_ input: String, generation current: Int, selected id: String?, message: String?) {
        guard let document else { return }
        let context = NavigationContext(document)
        navigationContext = context
        request = nil
        pending = false
        setSearching(false)
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = mode == .workspaceSymbols
        let isLine = !workspace && ControlNavigation.lineQuery(query)
        let features = document.languageFeatures
        let session = features.session
        if isLine, !document.hasTextDocument {
            apply([], selected: nil, error: "No text document is open")
            return
        }
        if !isLine, workspace ? features.workspaceSessions.isEmpty : !session.supportsDocumentSymbols {
            let unavailable = workspace ? "Workspace symbols require an active language server"
                : (query.isEmpty && document.hasTextDocument ? "Enter a line number" : "Document symbols require an active language server")
            apply([], selected: nil, error: message ?? unavailable)
            return
        }
        if workspace, query.isEmpty {
            apply([], selected: nil, error: message, emptyMessage: nil)
            return
        }

        let lineText = isLine ? document.editor.string : nil
        let cachedSymbols = documentSymbols.flatMap { $0.context == context ? $0.symbols : nil }
        let alternate = alternateCharacters(for: query)
        let folder = context.folder ?? session.workspaceRoot
        pending = true
        request = Task { [weak self, weak document] in
            do {
                let symbols: [LSPSymbol]
                if isLine {
                    symbols = []
                } else if workspace {
                    try await Task.sleep(for: .milliseconds(120))
                    guard let document else { return }
                    let primary = try await document.languageFeatures.workspaceSymbols(query: query)
                    let translated = String(query.map { alternate[$0] ?? $0 })
                    if primary.isEmpty, translated != query {
                        symbols = try await document.languageFeatures.workspaceSymbols(query: translated)
                    } else {
                        symbols = primary
                    }
                } else if let cachedSymbols {
                    symbols = cachedSymbols
                } else {
                    symbols = try await session.documentSymbols()
                }

                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    if let lineText {
                        return ControlNavigation.lineResult(query, text: lineText).map { [$0] } ?? []
                    }
                    return ControlNavigation.symbolResults(symbols, query: query, workspace: workspace,
                                                           folder: folder, alternateCharacters: alternate)
                }
                let rows = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard let self, let document, current == generation, !Task.isCancelled else { return }
                guard context == NavigationContext(document) else { search(preserving: id, error: message); return }
                if !workspace && !isLine { documentSymbols = (context, symbols) }
                pending = false
                setSearching(false)
                apply(rows, selected: id, error: message,
                      emptyMessage: isLine ? "Line number is outside the document" : "No matching symbols")
            } catch {
                guard let self, current == generation, !Task.isCancelled else { return }
                if error is CancellationError, let document, context != NavigationContext(document) {
                    search(preserving: id, error: message)
                } else {
                    pending = false
                    setSearching(false)
                    apply([], selected: nil, error: message ?? error.localizedDescription)
                }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, current == generation, pending else { return }
            setSearching(true)
            try? await Task.sleep(for: .milliseconds(350))
            guard current == generation, pending else { return }
            apply([], selected: nil, emptyMessage: nil)
        }
    }

    private func alternateCharacters(for query: String) -> [Character: Character] {
        guard !query.allSatisfy(\.isWhitespace) else { return [:] }
        return keyboardLayouts.alternatives(for: query)
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
        if mode == .files, let next = Mode(prefix: input.stringValue.first),
           (input.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            switchMode(to: next, query: String(input.stringValue.dropFirst()))
        } else {
            search()
        }
    }

    private func apply(_ results: [ControlMatch], selected id: String?, error: String? = nil,
                       emptyMessage: String? = "No matching results") {
        entries = results
        cachedPinnedRows = nil
        updatingRows = true
        table.reloadData()
        feedback.stringValue = error ?? (entries.isEmpty ? emptyMessage : nil) ?? ""
        feedback.isHidden = feedback.stringValue.isEmpty
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

        if TerminalShortcuts.isToggle(event) {
            if !event.isARepeat {
                dismiss(restoreFocus: true)
                document.showTerminal()
            }
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Some layouts produce a Latin shortcut character only with Command held.
        if modifiers == .command || modifiers == [.command, .shift],
           key == "p" || event.characters?.lowercased() == "p" {
            toggle(in: document, mode: modifiers.contains(.shift) ? .commands : .files)
            return nil
        }
        switch (key, modifiers) {
        case ("q", .command):
            return event
        case ("w", .command):
            dismiss(restoreFocus: true)
            return nil
        case ("b", .command):
            document.performFind(.toggleSidebar)
            return nil
        case ("g", [.command, .shift]) where document.canFocusSidebar(.sourceControl):
            dismiss(restoreFocus: true)
            document.toggleSidebarFocus(.sourceControl)
            return nil
        case ("f", .command), ("e", [.command, .shift]), ("w", [.command, .shift]):
            let mode: SidebarMode = switch key {
            case "f": .search
            case "e": .worktree
            default: .scratches
            }
            guard mode != .worktree || document.folderURL != nil else { return nil }
            dismiss(restoreFocus: true)
            document.toggleSidebarFocus(mode)
            return nil
        case ("f", [.command, .option]):
            dismiss(restoreFocus: true)
            document.performFind(.replace)
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
            case (36, .shift), (76, .shift):
                if !event.isARepeat { togglePin(at: table.selectedRow) }
                return nil
            case (125, [.option, .shift]), (126, [.option, .shift]):
                guard pin(at: table.selectedRow) != nil else { break }
                moveSelectedPin(by: event.keyCode == 125 ? 1 : -1)
                return nil
            case (36, []), (76, []):
                activate(row: table.selectedRow)
                return nil
            case (36, _), (76, _):
                return nil
            case (51, []) where mode.hasPrefix && field?.selectedRange() == NSRange(location: 0, length: 0):
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

    private func pin(at row: Int) -> ControlPin? {
        guard mode.acceptsPins, entries.indices.contains(row) else { return nil }
        return pins.pin(matching: entries[row].entry)
    }

    private func togglePin(at row: Int) {
        guard !pending, mode.acceptsPins, entries.indices.contains(row) else { return }
        let entry = entries[row].entry
        let pin: ControlPin
        if let scratch = entry.scratch {
            pin = .scratch(scratch.id)
        } else if let url = entry.fileURL {
            pin = .file(url, canonicalURL: entry.recent?.canonicalURL ?? url,
                        identity: entry.recent?.identity ?? entry.folderFileIdentity)
        } else {
            guard mode == .commands else { return }
            pin = .command(entry.id)
        }
        pins.toggle(pin, for: entry)
        cachedPinnedRows = nil
        pinsChangedInPlace = true
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private var pinnedRows: [Int] {
        if let cachedPinnedRows { return cachedPinnedRows }
        var unique: Set<ControlPin> = []
        let rows = entries.indices.filter { row in
            guard let pin = pin(at: row) else { return false }
            return unique.insert(pin).inserted
        }
        cachedPinnedRows = rows
        return rows
    }

    private func moveSelectedPin(by offset: Int) {
        guard !pending else { return }
        let rows = pinnedRows
        guard let from = rows.firstIndex(of: table.selectedRow), rows.indices.contains(from + offset) else { return }
        let to = from + offset
        var reordered = rows.map { entries[$0] }
        let moving = reordered.remove(at: from)
        reordered.insert(moving, at: to)
        let pinOrder = reordered.compactMap { pins.pin(matching: $0.entry) }
        guard pinOrder.count == reordered.count else { return }

        // Keyboard moves step through the visible pinned slots.
        let range = min(from, to)...max(from, to)
        for index in range { entries[rows[index]] = reordered[index] }
        finishPinMove(to: rows[to], changedRows: IndexSet(range.map { rows[$0] }), pinOrder: pinOrder)
    }

    private func finishPinMove(to destination: Int, changedRows: IndexSet, pinOrder: [ControlPin]) {
        pins.reorder(pinOrder)
        cachedPinnedRows = nil
        pinsChangedInPlace = true
        table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
        table.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        reveal(destination)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !pending, pin(at: row) != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(entries[row].entry.id, forType: Self.pinDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt point: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        pinsChangedInPlace = true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let drop = pinDrop(info, row: row, operation: operation) else { return [] }
        tableView.setDropRow(drop.boundary, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let drop = pinDrop(info, row: row, operation: operation) else { return false }
        var reorderedPins = pinnedRows.filter { $0 != drop.source }
        let pinIndex = reorderedPins.firstIndex { $0 >= drop.boundary } ?? reorderedPins.endIndex
        reorderedPins.insert(drop.source, at: pinIndex)
        let pinOrder = reorderedPins.compactMap { pin(at: $0) }

        let destination = drop.source < drop.boundary ? drop.boundary - 1 : drop.boundary
        let moving = entries.remove(at: drop.source)
        entries.insert(moving, at: destination)
        let changedRows = min(drop.source, destination)..<(max(drop.source, destination) + 1)
        finishPinMove(to: destination, changedRows: IndexSet(integersIn: changedRows), pinOrder: pinOrder)
        return true
    }

    private func pinDrop(_ info: any NSDraggingInfo, row: Int,
                         operation: NSTableView.DropOperation) -> (source: Int, boundary: Int)? {
        guard !pending, (info.draggingSource as? NSTableView) === table,
              (0...entries.count).contains(row),
              let id = info.draggingPasteboard.string(forType: Self.pinDragType) else { return nil }
        let rows = pinnedRows
        guard let source = rows.first(where: { entries[$0].entry.id == id }) else { return nil }
        var boundary = row
        if operation == .on, entries.indices.contains(row) {
            let point = table.convert(info.draggingLocation, from: nil)
            if point.y >= table.rect(ofRow: row).midY { boundary += 1 }
        }
        guard boundary != source, boundary != source + 1,
              rows.contains(boundary) || rows.contains(boundary - 1) else { return nil }
        return (source, boundary)
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

    @objc private func activateClickedRow() { _ = activate(row: table.clickedRow) }

    #if EDIT_AGENT_CHECKS
    func checkSymbols(in document: DocumentWindow, documentSymbol: String, workspaceSymbol: String,
                      workspaceFile: URL, workspaceSource: URL? = nil,
                      capture: (NSView, String) throws -> Void) async throws {
        guard app.isAgentCheck, let originalFile = document.fileURL else { throw CheckFailure.invalidSymbols("open a source file") }
        let originalCaret = document.editor.selectedRange()
        let workspacePath = document.folderURL
            .flatMap { FolderFileSearch.relativeDirectory(of: workspaceFile, in: $0) }
            .map { $0.isEmpty ? workspaceFile.lastPathComponent : "\($0)/\(workspaceFile.lastPathComponent)" }
            ?? workspaceFile.lastPathComponent
        defer { dismiss(restoreFocus: false) }

        func enter(_ query: String) async throws {
            show(in: document)
            focusQuery()
            guard let field = input.currentEditor() as? NSTextView else { throw CheckFailure.invalidSearchField }
            field.insertText(query, replacementRange: field.selectedRange())
            while pending { await request?.value }
        }

        try await enter(":0")
        guard mode == .documentSymbols, entries.isEmpty, feedback.stringValue == "Line number is outside the document" else {
            throw CheckFailure.invalidSymbols("reject line zero in colon mode")
        }
        try await enter(":2")
        let buffer = document.editor.string as NSString
        let secondLine = buffer.lineRange(for: NSRange(location: 0, length: 0)).upperBound
        guard mode == .documentSymbols, leadingIcon.image === Self.documentSymbolImage,
              input.stringValue == "2", table.selectedRow == 0, entries.map(\.entry.title) == ["Line 2"] else {
            throw CheckFailure.invalidSymbols("interpret a colon followed by a number as a line")
        }
        guard let enterKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
              intercept(enterKey) == nil, self.document == nil, document.editor.selectedRange().location == secondLine,
              document.window.firstResponder === document.editor else {
            throw CheckFailure.invalidSymbols("jump to the one-based line with Return and restore editor focus")
        }

        try await enter(":\(documentSymbol.uppercased())")
        guard mode == .documentSymbols, input.stringValue == documentSymbol.uppercased(),
              let row = entries.firstIndex(where: { $0.entry.title == documentSymbol }),
              case .symbol(let local, _) = entries[row].entry.navigation,
              let localCaret = symbolCaret(local, in: document), let view = panel.contentView else {
            throw CheckFailure.invalidSymbols("find a document symbol case-insensitively")
        }
        try capture(view, "document-symbols")
        activate(row: row)
        guard self.document == nil, document.fileURL == originalFile, document.editor.selectedRange() == localCaret else {
            throw CheckFailure.invalidSymbols("jump to the selected symbol in the active document")
        }

        try await enter("#\(workspaceSymbol)")
        guard mode == .workspaceSymbols, leadingIcon.image === Self.workspaceSymbolImage,
              input.stringValue == workspaceSymbol, let view = panel.contentView,
              let row = entries.firstIndex(where: {
                  guard $0.entry.title == workspaceSymbol, case .symbol(let location, _) = $0.entry.navigation else { return false }
                  return location.url.standardizedFileURL == workspaceFile.standardizedFileURL &&
                      $0.entry.detail == workspacePath
              }), case .symbol(let projectLocation, _) = entries[row].entry.navigation else {
            throw CheckFailure.invalidSymbols("find a project symbol in another file and show its path")
        }
        try capture(view, "workspace-symbols")
        guard let jump = activate(row: row) else { throw CheckFailure.invalidSymbols("open the workspace symbol") }
        await jump.value
        guard self.document == nil, document.fileURL == workspaceFile,
              document.editor.selectedRange() == symbolCaret(projectLocation, in: document),
              document.window.firstResponder === document.editor else {
            throw CheckFailure.invalidSymbols("open the workspace symbol at its location in the same window")
        }
        await app.navigate(.back)
        guard document.fileURL == originalFile, document.editor.selectedRange() == localCaret else {
            throw CheckFailure.invalidSymbols("return to the originating file and caret using Go Back")
        }
        if let workspaceSource {
            guard try await app.openFile(workspaceSource, in: document) === document,
                  !document.languageFeatures.session.supportsDocumentSymbols else {
                throw CheckFailure.invalidSymbols("open a plain text file in the same project")
            }
            let session = document.languageFeatures.session
            let deadline = ContinuousClock.now + .seconds(5)
            while !session.supportsWorkspaceSymbols && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(15))
            }
            guard session.supportsWorkspaceSymbols else {
                throw CheckFailure.invalidSymbols("wait for workspace symbols on a plain text file (\(session.state.title))")
            }
            try await enter("#\(workspaceSymbol)")
            guard mode == .workspaceSymbols, entries.contains(where: {
                $0.entry.title == workspaceSymbol && $0.entry.detail == workspacePath
            }) else {
                throw CheckFailure.invalidSymbols("find the workspace symbol while a plain text file is open (\(feedback.stringValue), \(entries.map(\.entry.title)))")
            }
            dismiss(restoreFocus: false)
            guard try await app.openFile(originalFile, in: document) === document else {
                throw CheckFailure.invalidSymbols("restore the original source file")
            }
        }
        document.editor.setCaretSelections([originalCaret], record: false)
    }

    func checkHidden(in document: DocumentWindow) async throws {
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
              ControlMatching.rank(commands, query: "save", preferShorterTitles: true).first?.entry.title == "File: Save",
              ControlMatching.rank(commands, query: "sva", preferShorterTitles: true).first?.entry.title == "File: Save As…",
              ControlMatching.rank(commands, query: "save as scratch").first?.entry.title == "File: Save as Scratch…",
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
              choices.count == SyntaxLanguage.allCases.count + 1,
              choices.first?.id == "auto", choices[1].id == SyntaxLanguage.plainText.rawValue else {
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
        if let wrongLayout = checkQueryInOtherLayout("save") {
            field.insertText(wrongLayout, replacementRange: field.selectedRange())
            while pending { await request?.value }
            let saveRows = entries.indices.filter { entries[$0].entry.title == "File: Save" }
            guard field.string == wrongLayout, table.numberOfRows == entries.count,
                  let row = saveRows.first, saveRows.count == 1,
                  entries[row].titleCharacters == [6, 7, 8, 9] else {
                throw CheckFailure.invalidSearchField
            }
        }
        configure(.languages)
        if let wrongLayout = checkQueryInOtherLayout("Swift") {
            input.stringValue = wrongLayout
            search()
            while pending { await request?.value }
            guard entries.contains(where: { $0.entry.title == "Swift" && $0.titleCharacters == [0, 1, 2, 3, 4] }) else {
                throw CheckFailure.invalidSearchField
            }
        }
        configure(.files)
        if let recent = files.first?.entry, let wrongLayout = checkQueryInOtherLayout(recent.title) {
            input.stringValue = wrongLayout
            search()
            while pending { await request?.value }
            guard entries.filter({ $0.entry.id == recent.id }).count == 1 else {
                throw CheckFailure.invalidSearchField
            }
        }
        try checkKeyboardRouting()
    }

    private func checkQueryInOtherLayout(_ text: String) -> String? {
        let alternate = alternateCharacters(for: text)
        let converted = String(text.map { alternate[$0] ?? $0 })
        let reverse = alternateCharacters(for: converted)
        guard converted != text, String(converted.map { reverse[$0] ?? $0 }) == text else { return nil }
        return converted
    }

    func checkFolder(in document: DocumentWindow, file: URL) async throws {
        guard app.isAgentCheck else { return }
        let file = FileBuffer.canonicalURL(file)
        show(in: document)
        defer { dismiss(restoreFocus: false) }
        while pending { await request?.value }
        guard folderScan == nil, !entries.isEmpty, entries.allSatisfy({ $0.entry.recent != nil }) else {
            throw CheckFailure.invalidFolderResults("blank query")
        }

        input.stringValue = "  "
        search()
        while pending { await request?.value }
        guard folderScan == nil, !entries.isEmpty, entries.allSatisfy({ $0.entry.recent != nil }) else {
            throw CheckFailure.invalidFolderResults("whitespace-only query")
        }

        let folder = document.folderURL
        input.stringValue = "\(file.deletingLastPathComponent().lastPathComponent) \(file.lastPathComponent)"
        search()
        while pending { await request?.value }
        guard let row = entries.firstIndex(where: { $0.entry.folderFileURL?.path == file.path }),
              let activation = activate(row: row) else { throw CheckFailure.invalidFolderResults("nested file") }
        await activation.value
        guard document.fileURL == file, document.folderURL == folder else {
            throw CheckFailure.invalidFolderResults("same-window activation")
        }

        show(in: document)
        input.stringValue = file.lastPathComponent
        search()
        while pending { await request?.value }
        let matchingFiles = entries.filter { ($0.entry.recent?.canonicalURL ?? $0.entry.folderFileURL)?.path == file.path }
        guard matchingFiles.count == 1, matchingFiles.first?.entry.recent != nil else {
            throw CheckFailure.invalidFolderResults("recent file deduplication")
        }
        if let folder, let directory = FolderFileSearch.relativeDirectory(of: file, in: folder), !directory.isEmpty,
           let wrongLayout = checkQueryInOtherLayout(file.lastPathComponent), !wrongLayout.contains("/") {
            input.stringValue = directory + "/" + wrongLayout
            search()
            while pending { await request?.value }
            let matching = entries.filter { ($0.entry.recent?.canonicalURL ?? $0.entry.folderFileURL) == file }
            guard matching.count == 1, folderScan?.scope.components == directory.split(separator: "/").map(String.init),
                  matching.first?.titleCharacters == Set(0..<file.lastPathComponent.count) else {
                throw CheckFailure.invalidFolderResults("alternate layout inside an explicit directory")
            }
        }
    }

    func checkFolderQueries(
        in document: DocumentWindow, expectations: [(query: String, files: [URL])],
        relativeDetails: [URL: String], opening file: URL
    ) async throws {
        guard app.isAgentCheck, let root = document.folderURL else { return }
        show(in: document)
        defer { dismiss(restoreFocus: false) }
        let expectedDetails = Dictionary(uniqueKeysWithValues: relativeDetails.map {
            (FileBuffer.canonicalURL($0.key), $0.value)
        })
        for (query, files) in expectations {
            input.stringValue = query
            search()
            while pending { await request?.value }
            let found = entries.compactMap { match in
                (match.entry.recent?.canonicalURL ?? match.entry.folderFileURL)?.path
            }.filter { $0.hasPrefix(root.path + "/") }
            let expected = files.map { FileBuffer.canonicalURL($0).path }
            guard found.sorted() == expected.sorted() else {
                throw CheckFailure.invalidFolderResults("query \(String(reflecting: query)), files \(found)")
            }
            for (row, match) in entries.enumerated() {
                guard let url = match.entry.recent?.canonicalURL ?? match.entry.folderFileURL else { continue }
                guard url.lastPathComponent != ".DS_Store" else {
                    throw CheckFailure.invalidFolderResults("Finder metadata in query \(String(reflecting: query))")
                }
                guard let expected = expectedDetails[url] else { continue }
                let cell = tableView(table, viewFor: table.tableColumns.first, row: row) as? NSStackView
                let labels = cell?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
                guard labels?.contains(expected) == true else {
                    throw CheckFailure.invalidFolderResults("relative directory for \(url.lastPathComponent)")
                }
            }
            if let path = FolderFileSearch.DirectoryQuery(query) {
                guard folderScan?.scope.components == path.components else {
                    throw CheckFailure.invalidFolderResults("scan limited to the requested path")
                }
            } else if query.isEmpty {
                guard folderScan == nil else { throw CheckFailure.invalidFolderResults("unnecessary scan") }
            }
        }
        let target = FileBuffer.canonicalURL(file)
        guard let row = entries.firstIndex(where: { ($0.entry.recent?.canonicalURL ?? $0.entry.folderFileURL) == target }),
              let activation = activate(row: row) else {
            throw CheckFailure.invalidFolderResults("activating an explicit path")
        }
        await activation.value
        guard document.fileURL == target && document.folderURL == root else {
            throw CheckFailure.invalidFolderResults("opening an excluded file in the current folder window")
        }
    }

    func checkFileOrder(in document: DocumentWindow, within fixture: URL, query: String, expected: [URL],
                        openFirst: Bool = false, capture: ((NSView) throws -> Void)? = nil) async throws {
        show(in: document)
        defer { dismiss(restoreFocus: false) }
        input.stringValue = query
        search()
        while pending { await request?.value }
        let found = entries.compactMap { $0.entry.recent?.canonicalURL ?? $0.entry.folderFileURL }
            .filter { FolderFileSearch.relativeDirectory(of: $0, in: fixture) != nil }
        guard found.map(\.path) == expected.map(\.path) else {
            throw CheckFailure.invalidFolderResults("order for \(String(reflecting: query)): \(found.map(\.path))")
        }
        if let capture, let view = panel.contentView { try capture(view) }
        if openFirst {
            guard table.selectedRow == 0, entries.first?.entry.fileURL?.path == expected.first?.path,
                  let activation = activate(row: table.selectedRow) else {
                throw CheckFailure.invalidFolderResults("the root match is selected by default")
            }
            await activation.value
            guard document.fileURL?.path == expected.first?.path else {
                throw CheckFailure.invalidFolderResults("open the default match in the current window")
            }
        }
    }

    func checkHeaderLanguagePicker(in document: DocumentWindow) throws {
        guard app.isAgentCheck, self.document === document, mode == .languages,
              entries.prefix(2).map(\.entry.title) == ["Auto Detect", "Plain Text"],
              let row = entries.firstIndex(where: { $0.entry.id == SyntaxLanguage.rust.rawValue }) else {
            throw CheckFailure.invalidPanel
        }
        activate(row: row)
        guard document.manualSyntaxLanguage == .rust && self.document == nil else {
            throw CheckFailure.invalidPanel
        }
    }

    func checkScratches(in document: DocumentWindow, scratch: ScratchFile, global: ScratchFile) async throws {
        guard app.isAgentCheck, let folder = document.folderURL else { return }
        let folderless = app.makeDocument()
        defer {
            dismiss(restoreFocus: false)
            folderless.window.close()
        }
        show(in: document)
        input.stringValue = scratch.name
        search()
        while pending { await request?.value }
        guard let scratchRow = entries.firstIndex(where: { $0.entry.scratch?.id == scratch.id }),
              entries.filter({ $0.entry.scratch?.id == scratch.id }).count == 1,
              !entries.contains(where: { $0.entry.scratch?.id == global.id }) else {
            throw CheckFailure.invalidScratches("find the current folder’s scratch even without recent history")
        }
        togglePin(at: scratchRow)
        input.stringValue = ""
        search()
        while pending { await request?.value }
        guard pin(at: 0) == .scratch(scratch.id),
              let cell = tableView(table, viewFor: table.tableColumns.first, row: 0) as? NSStackView,
              let accessory = cell.arrangedSubviews.last as? ControlFileAccessory,
              accessory.dismissButton == nil,
              accessory.subviews.compactMap({ ($0 as? NSImageView)?.accessibilityLabel() }) == ["Pinned", "Scratch"],
              accessory.subviews.compactMap({ ($0 as? NSImageView)?.image }).count == 2 else {
            throw CheckFailure.invalidScratches("show both status icons without a recent-file action")
        }

        input.stringValue = "scratch-scope-check/"
        search()
        while pending { await request?.value }
        guard !entries.contains(where: { $0.entry.scratch != nil }) else {
            throw CheckFailure.invalidScratches("respect an explicit directory query")
        }
        show(in: folderless)
        input.stringValue = global.name
        search()
        while pending { await request?.value }
        guard entries.contains(where: { $0.entry.scratch?.id == global.id }),
              !entries.contains(where: { $0.entry.scratch?.id == scratch.id }) else {
            throw CheckFailure.invalidScratches("limit a folderless window to global scratches even with a folder pin")
        }

        show(in: document)
        input.stringValue = scratch.name
        search()
        while pending { await request?.value }
        guard let row = entries.firstIndex(where: { $0.entry.scratch?.id == scratch.id }),
              pin(at: row) == .scratch(scratch.id), let open = activate(row: row) else {
            throw CheckFailure.invalidScratches("find and activate a pinned scratch with fuzzy search")
        }
        await open.value
        guard document.folderURL == folder, document.fileURL == FileBuffer.canonicalURL(app.scratchStore.url(for: scratch)) else {
            throw CheckFailure.invalidScratches("open the scratch without changing the window’s folder")
        }
    }

    func checkScratchRecency(in document: DocumentWindow, scratch: ScratchFile, older: URL, newer: URL) async throws {
        guard app.isAgentCheck else { return }
        defer { dismiss(restoreFocus: false) }
        let (unopened, _) = try await app.scratchStore.create(name: "Unopened Recency Check.txt", text: "",
                                                               format: FileFormat(), in: document.folderURL)
        let olderPath = FileBuffer.canonicalURL(older).path
        let newerPath = FileBuffer.canonicalURL(newer).path
        let scratchID = scratch.id.uuidString
        let recentOrder = [newerPath, scratchID, olderPath]
        func firstThree() -> [String] {
            entries.prefix(3).compactMap { $0.entry.scratch?.id.uuidString ?? $0.entry.recent?.canonicalURL.path }
        }
        show(in: document)
        while pending { await request?.value }
        guard firstThree() == recentOrder, !entries.contains(where: { $0.entry.scratch?.id == unopened.id }) else {
            throw CheckFailure.invalidScratches("mix an unpinned scratch with older and newer ordinary files")
        }

        togglePin(at: 1)
        search()
        while pending { await request?.value }
        guard entries.first?.entry.scratch?.id == scratch.id && pin(at: 0) == .scratch(scratch.id) else {
            throw CheckFailure.invalidScratches("move the scratch to the top after pinning")
        }
        togglePin(at: 0)
        search()
        while pending { await request?.value }
        guard firstThree() == recentOrder else {
            throw CheckFailure.invalidScratches("return an unpinned scratch to its recent position")
        }

        input.stringValue = unopened.name
        search()
        while pending { await request?.value }
        guard entries.contains(where: { $0.entry.scratch?.id == unopened.id }) else {
            throw CheckFailure.invalidScratches("find an unopened scratch when filtering by name")
        }

        dismiss(restoreFocus: false)
        guard await document.openScratch(scratch) else { throw CheckFailure.invalidScratches("reopen a scratch") }
        show(in: document)
        while pending { await request?.value }
        guard firstThree() == [scratchID, newerPath, olderPath], pin(at: 0) == nil else {
            throw CheckFailure.invalidScratches("promote a reopened scratch through recency alone")
        }
    }

    func checkPins(in document: DocumentWindow) async throws {
        guard app.isAgentCheck else { return }
        try ControlPinsCheck.run()
        let originalText = document.editor.string
        let originalFile = document.fileURL
        defer { dismiss(restoreFocus: false) }

        func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
        }

        let toggle = key("\r", 36, .shift)
        let moveUp = key("\u{F700}", 126, [.option, .shift])
        let moveDown = key("\u{F701}", 125, [.option, .shift])
        show(in: document, mode: .commands)
        await request?.value
        guard entries.count > 5 else { throw CheckFailure.invalidPins("load command rows") }
        let starting = entries.map { $0.entry.id }
        let earlier = starting[2]
        let later = starting[5]
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        guard intercept(toggle) == nil, pin(at: 2) == .command(earlier),
              table.selectedRow == 2, entries.map({ $0.entry.id }) == starting,
              document.editor.string == originalText else {
            throw CheckFailure.invalidPins("toggle a command without moving, selecting, or running it")
        }
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        _ = intercept(toggle)
        _ = intercept(moveUp)
        guard entries[2].entry.id == later, entries[3].entry.id == starting[3],
              entries[4].entry.id == starting[4], entries[5].entry.id == earlier, table.selectedRow == 2 else {
            throw CheckFailure.invalidPins("move only the pinned slots, including immediately after pinning")
        }
        let drag = self.tableView(table, pasteboardWriterForRow: 2) as? NSPasteboardItem
        guard drag?.string(forType: Self.pinDragType) == later,
              self.tableView(table, pasteboardWriterForRow: 3) == nil else {
            throw CheckFailure.invalidPins("export only pinned rows for local dragging")
        }

        let beforeDrag = entries
        let firstGap = starting[3]
        let secondGap = starting[4]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let drops: [(source: Int, target: Int, below: Bool, destination: Int, order: [String])] = [
            (5, 2, true, 3, [later, earlier, firstGap, secondGap]),
            (5, 2, false, 2, [earlier, later, firstGap, secondGap]),
            (2, 5, true, 5, [firstGap, secondGap, earlier, later]),
            (2, 5, false, 4, [firstGap, secondGap, later, earlier]),
        ]
        for drop in drops {
            apply(beforeDrag, selected: beforeDrag[drop.source].entry.id)
            guard let payload = tableView(table, pasteboardWriterForRow: drop.source) else {
                throw CheckFailure.invalidPins("start the pin drag")
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([payload]) else { throw CheckFailure.invalidPins("write the pin drag payload") }
            let rect = table.rect(ofRow: drop.target)
            let y = rect.midY + rect.height * (drop.below ? 0.25 : -0.25)
            let location = table.convert(NSPoint(x: rect.midX, y: y), to: nil)
            let info = ControlPinDragCheck(table: table, location: location, pasteboard: pasteboard)
            let boundary = drop.target + (drop.below ? 1 : 0)
            guard tableView(table, validateDrop: info, proposedRow: drop.target, proposedDropOperation: .on) == .move,
                  tableView(table, acceptDrop: info, row: boundary, dropOperation: .above),
                  entries[2...5].map({ $0.entry.id }) == drop.order, table.selectedRow == drop.destination else {
                throw CheckFailure.invalidPins("insert a dragged pin at its marked position and shift the intervening rows")
            }
        }

        show(in: document, mode: .commands)
        guard entries.prefix(2).map({ $0.entry.id }) == [later, earlier] else {
            throw CheckFailure.invalidPins("show the saved command order on reopening")
        }
        let reordered = entries.map { $0.entry.id }
        _ = intercept(toggle)
        guard entries.map({ $0.entry.id }) == reordered, pin(at: 0) == nil, table.selectedRow == 0 else {
            throw CheckFailure.invalidPins("unpin in place with selection intact")
        }
        input.stringValue = "save"
        search()
        await request?.value
        guard entries.first?.entry.title == "File: Save" else { throw CheckFailure.invalidPins("rank filtered commands normally") }
        clearQuery()
        await request?.value
        guard entries.first?.entry.id == earlier else { throw CheckFailure.invalidPins("apply pin order on clearing the query") }

        show(in: document, mode: .files)
        await request?.value
        guard entries.count >= 2 else { throw CheckFailure.invalidPins("load recent file rows") }
        let recentOrder = entries.map { $0.entry.id }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        _ = intercept(toggle)
        guard entries.map({ $0.entry.id }) == recentOrder, pin(at: 1) != nil,
              document.fileURL == originalFile else { throw CheckFailure.invalidPins("pin a file in place without opening it") }
        _ = intercept(key("\u{F700}", 126, []))
        _ = intercept(toggle)
        _ = intercept(moveDown)
        show(in: document, mode: .files)
        await request?.value
        guard entries.prefix(2).map({ $0.entry.id }) == [recentOrder[1], recentOrder[0]] else {
            throw CheckFailure.invalidPins("put files first in their manual order")
        }
        let firstEntry = entries[0].entry
        if let recent = firstEntry.recent {
            app.recentFiles.dismiss(recent)
            show(in: document, mode: .files)
            await request?.value
            guard entries.first?.entry.fileURL == firstEntry.fileURL, entries.first?.entry.recent == nil else {
                throw CheckFailure.invalidPins("keep files pinned independently of recent history")
            }
            if let url = firstEntry.fileURL { await app.recentFiles.record(url) }
        }

        let root = FileManager.default.temporaryDirectory.appending(path: "Pinned folder check \(UUID())")
        let excluded = root.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let module = excluded.appending(path: "PinnedModule.js")
        try Data("const test = true".utf8).write(to: module)
        let folderDocument = app.makeDocument()
        defer { folderDocument.window.close() }
        _ = try await app.openFile(root, in: folderDocument)
        show(in: folderDocument, mode: .files)
        input.stringValue = "node_modules/"
        search()
        await request?.value
        guard entries.count == 1, entries.first?.entry.title == module.lastPathComponent,
              entries.first?.entry.recent == nil else { throw CheckFailure.invalidPins("load an explicit folder result") }
        _ = intercept(toggle)
        _ = intercept(moveUp)
        clearQuery()
        await request?.value
        guard entries.first?.entry.id == recentOrder[1],
              entries.contains(where: { $0.entry.title == module.lastPathComponent }) else {
            throw CheckFailure.invalidPins("retain an explicitly pinned excluded file in an empty query")
        }
        input.stringValue = "PinnedModule"
        search()
        await request?.value
        guard entries.count == 1, entries.first?.entry.title == module.lastPathComponent else {
            throw CheckFailure.invalidPins("find the pinned file with an ordinary query")
        }
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

        func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                 ignoringModifiers: String? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
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

        guard !probe.isSidebarVisible,
              intercept(key("b", 11, .command)) == nil, probe.isSidebarVisible, document === probe,
              intercept(key("b", 11, .command)) == nil, !probe.isSidebarVisible, document === probe else {
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
              intercept(key("p", 35, .command, ignoringModifiers: "з")) == nil,
              document === probe, mode == .files, input.placeholderString == "Search recent files",
              input.currentEditor() === query, query.string == "x",
              intercept(key("P", 35, [.command, .shift], ignoringModifiers: "З")) == nil,
              document === probe, mode == .commands, input.placeholderString == "Search commands",
              input.currentEditor() === query, query.string == "x",
              intercept(key("w", 13, .command)) == nil, document == nil else {
            throw CheckFailure.shortcutEscaped
        }

        show(in: probe, mode: .commands)
        guard intercept(key("W", 13, [.command, .shift])) == nil, document == nil,
              let outline = probe.scratchOutline, probe.sidebarMode == .scratches && probe.isSidebarVisible,
              probe.window.firstResponder === outline else {
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
        case invalidFolderResults(String)
        case invalidPins(String)
        case invalidScratches(String)
        case invalidSymbols(String)
        case shortcutEscaped

        var errorDescription: String? {
            switch self {
            case .invalidPanel: "Control did not render its recent list and empty state quietly."
            case .invalidSearchField: "Control did not preserve editing, switching modes, or clearing the search."
            case .shortcutEscaped: "Control did not keep document shortcuts separate from palette commands."
            case .invalidFolderResults(let stage): "Control failed the folder search check for \(stage)."
            case .invalidPins(let stage): "Control pins could not \(stage)."
            case .invalidScratches(let stage): "Control could not \(stage)."
            case .invalidSymbols(let stage): "Control could not \(stage)."
            }
        }
    }

    #endif

    @discardableResult
    private func activate(row: Int) -> Task<Void, Never>? {
        guard !pending, entries.indices.contains(row), let document else { return nil }
        let entry = entries[row].entry
        if mode == .commands {
            runCommand(entry, in: document)
            return nil
        }
        if mode == .languages {
            let language = SyntaxLanguage(rawValue: entry.id)
            document.setSyntaxLanguage(language)
            dismiss(restoreFocus: true)
            return nil
        }
        if let target = entry.navigation {
            return activateNavigation(target, entry: entry, in: document)
        }
        if mode == .files && document.folderURL != resultsFolder {
            configure(mode)
            search()
            return nil
        }
        let query = input.stringValue
        if let scratch = entry.scratch {
            dismiss(restoreFocus: true)
            let dismissedOpening = opening
            return Task {
                guard !(await document.openScratch(scratch)), opening == dismissedOpening, self.document == nil,
                      app.isAgentCheck || document.window.isKeyWindow else { return }
                show(in: document, retry: (query, entry.id, nil))
            }
        }
        guard let url = entry.fileURL else { return nil }
        dismiss(restoreFocus: true)
        let dismissedOpening = opening
        return Task {
            do {
                try await app.openFile(url, in: document)
            } catch {
                if entry.recent != nil { await app.recentFiles.removeIfMissing(url) }
                guard opening == dismissedOpening, self.document == nil, document.window.isKeyWindow else { return }
                show(in: document, retry: (query, entry.id, error.localizedDescription))
            }
        }
    }

    private func activateNavigation(_ target: ControlNavigation, entry: ControlEntry,
                                    in document: DocumentWindow) -> Task<Void, Never>? {
        guard navigationContext == NavigationContext(document) else { search(preserving: entry.id); return nil }
        let origin = document.navigationLocation
        switch target {
        case let .line(range, text):
            guard document.hasTextDocument, document.editor.string.utf8.elementsEqual(text.utf8) else {
                search(preserving: entry.id)
                return nil
            }
            dismiss(restoreFocus: true)
            document.navigate(to: range, from: origin)
            return nil
        case let .symbol(location, _):
            let url = location.url.standardizedFileURL
            if url == document.fileURL?.standardizedFileURL {
                guard let caret = symbolCaret(location, in: document) else {
                    apply(entries, selected: entry.id, error: "Symbol location is no longer available")
                    return nil
                }
                dismiss(restoreFocus: true)
                document.navigate(to: caret, from: origin)
                return nil
            }

            let query = input.stringValue
            let mode = mode
            let openGeneration = document.openRequestGeneration
            dismiss(restoreFocus: true)
            let dismissedOpening = opening
            return Task {
                @MainActor func stillWanted() -> Bool {
                    opening == dismissedOpening && self.document == nil && !app.isQuitting
                }
                guard document.openRequestGeneration == openGeneration, stillWanted() else { return }
                do {
                    guard try await app.openFile(url, in: document, focusEditor: false, shouldOpen: stillWanted) != nil,
                          document.openRequestGeneration == openGeneration &+ 1, stillWanted() else { return }
                    guard let caret = symbolCaret(location, in: document) else { throw LSPFailure.invalidPosition }
                    document.navigate(to: caret, from: origin)
                } catch {
                    guard document.openRequestGeneration == openGeneration &+ 1, stillWanted(),
                          app.isAgentCheck || document.window.isKeyWindow else { return }
                    show(in: document, mode: mode, retry: (query, entry.id, error.localizedDescription))
                }
            }
        }
    }

    private func symbolCaret(_ location: LSPLocation, in document: DocumentWindow) -> NSRange? {
        guard document.hasEditableTextDocument, document.editor.conflictEdits.isEmpty,
              let range = location.range.nsRange(in: document.editor.string) else { return nil }
        return NSRange(location: range.location, length: 0)
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
        if command.item.action == #selector(Edit.toggleSidebar(_:)) {
            command.run(in: document)
            return
        }
        if command.item.action == #selector(Edit.showLanguageModes(_:)) {
            switchMode(to: .languages, query: "")
            return
        }
        if command.item.action == #selector(Edit.showDocumentSymbols(_:)) {
            switchMode(to: .documentSymbols, query: "")
            return
        }
        if command.item.action == #selector(Edit.showWorkspaceSymbols(_:)) {
            switchMode(to: .workspaceSymbols, query: "")
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
            let visible = table.rows(in: table.visibleRect)
            updateButtons(at: Array(visible.location..<NSMaxRange(visible)))
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = entries[row]
        let title = makeLabel(match.entry.title, highlights: match.titleCharacters, secondary: false)
        var views: [NSView] = []
        let scratchURL = match.entry.scratch.map { app.scratchStore.url(for: $0) }
        let fileURL = match.entry.fileURL ?? match.entry.scratch?.filenameURL
        let language = match.entry.iconLanguage
            ?? match.entry.recent.flatMap { app.manualIconLanguage(for: $0) }
            ?? match.entry.folderFileURL.flatMap { app.syntaxOverrides.language(for: $0)?.iconIdentifier }
            ?? scratchURL.flatMap { app.syntaxOverrides.language(for: $0)?.iconIdentifier }
        if fileURL != nil || language != nil,
           let image = FileIcons.image(for: fileURL, appearance: tableView.effectiveAppearance, language: language) {
            let icon = NSImageView(image: image)
            icon.setAccessibilityElement(false)
            views.append(icon)
        }
        if let target = match.entry.navigation, let image = Self.navigationImage(for: target) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityElement(false)
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            views.append(icon)
        }
        views.append(title)
        if let detail = match.entry.detail {
            views.append(makeLabel(detail, highlights: match.detailCharacters, secondary: true, lineBreak: .byTruncatingHead))
        }
        if mode != .languages || match.entry.shortcut != nil { views.append(NSView()) }
        if mode == .commands { views.append(pinMarker(for: row)) }
        if let shortcut = match.entry.shortcut {
            views.append(makeLabel(shortcut, highlights: [], secondary: true))
        }
        if mode == .files { views.append(fileAccessory(for: match.entry, row: row)) }
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = 7
        return stack
    }

    private static func navigationImage(for target: ControlNavigation) -> NSImage? {
        let symbol: String
        switch target {
        case .line: symbol = "line.3.horizontal"
        case .symbol(_, let kind):
            switch kind {
            case 6, 9, 12, 25: symbol = "f.cursive"
            case 5, 10, 11, 23: symbol = "cube"
            case 2, 3, 4: symbol = "shippingbox"
            case 7, 8, 13, 14, 22: symbol = "curlybraces"
            default: symbol = "circle"
            }
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
    }

    private func pinMarker(for row: Int) -> NSImageView {
        let marker = NSImageView()
        marker.image = Self.pinImage
        marker.imageScaling = .scaleNone
        marker.contentTintColor = .secondaryLabelColor
        let pinned = pin(at: row) != nil
        marker.alphaValue = pinned ? 1 : 0
        marker.setAccessibilityElement(pinned)
        marker.setAccessibilityLabel("Pinned")
        marker.widthAnchor.constraint(equalToConstant: 17).isActive = true
        marker.heightAnchor.constraint(equalToConstant: 17).isActive = true
        return marker
    }

    private func fileAccessory(for entry: ControlEntry, row: Int) -> NSView {
        let hasScratch = entry.scratch != nil
        let accessory = ControlFileAccessory()
        accessory.widthAnchor.constraint(equalToConstant: hasScratch ? 40 : 20).isActive = true
        accessory.heightAnchor.constraint(equalToConstant: 19).isActive = true
        let marker = pinMarker(for: row)
        marker.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(marker)
        NSLayoutConstraint.activate([
            marker.centerXAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 10),
            marker.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
        ])
        if hasScratch {
            let scratch = NSImageView()
            scratch.image = Self.scratchImage
            scratch.imageScaling = .scaleNone
            scratch.contentTintColor = .secondaryLabelColor
            scratch.setAccessibilityElement(true)
            scratch.setAccessibilityLabel("Scratch")
            scratch.translatesAutoresizingMaskIntoConstraints = false
            accessory.addSubview(scratch)
            NSLayoutConstraint.activate([
                scratch.widthAnchor.constraint(equalTo: marker.widthAnchor),
                scratch.heightAnchor.constraint(equalTo: marker.heightAnchor),
                scratch.centerXAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -10),
                scratch.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            ])
        }
        if entry.recent != nil && pin(at: row) == nil {
            let image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Remove from recent files")!
            let button = NSButton(image: image, target: self, action: #selector(dismissRecent(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(entry.id)
            button.translatesAutoresizingMaskIntoConstraints = false
            accessory.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            ])
            accessory.dismissButton = button
            updateDismissButton(button, at: row)
        }
        return accessory
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
                  let accessory = stack.arrangedSubviews.last as? ControlFileAccessory,
                  let button = accessory.dismissButton else { continue }
            updateDismissButton(button, at: row)
        }
    }

    private func updateDismissButton(_ button: NSButton, at row: Int) {
        let visible = row == table.selectedRow || row == table.hovered
        button.alphaValue = visible ? 1 : 0
        button.isEnabled = visible
    }
}

@MainActor
private final class ControlFileAccessory: NSView {
    weak var dismissButton: NSButton?
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
