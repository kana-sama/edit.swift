import AppKit

enum LanguageServerCommand: String, CaseIterable {
    case start, stop, restart

    var title: String {
        switch self {
        case .start: "Start LSP"
        case .stop: "Stop LSP"
        case .restart: "Restart LSP"
        }
    }
}

@MainActor
final class DocumentLanguageFeatures: NSObject, NSUserInterfaceValidations {
    private struct Query {
        let url: URL
        let text: String
        let generation: Int
        let revision: Int
        let openGeneration: UInt64
    }

    private enum SymbolNavigation {
        case definition, declaration, references

        var failureMessage: String {
            switch self {
            case .definition, .declaration: "Could not navigate to symbol"
            case .references: "Could not find references"
            }
        }
    }

    private struct SymbolMenuTarget {
        let hit: EditorLanguageInteraction.Hit
        let query: Query
    }

    private unowned let document: DocumentWindow
    private unowned let app: Edit
    let session = LanguageServerSession()
    private lazy var symbolRename = DocumentSymbolRename(document: document, app: app, session: session)
    private lazy var status = LanguageServerStatusPopover { [weak self] command in self?.perform(command) }
    var statusButton: NSButton { status.button }
#if EDIT_AGENT_CHECKS
    var statusPopoverForCheck: NSView? { status.contentForCheck }
    var statusIndicatorForCheck: LanguageServerStatusPopover.Indicator? { status.indicator }
#endif
    private var sourceURL: URL?
    private var sourceFolder: URL?
    private var searchesParentProjects = false
    private var navigationTask: Task<Void, Never>?
    private var navigationID: UInt64 = 0
    private var referenceTask: Task<Void, Never>?
    private var referenceID: UInt64 = 0
    private var isClosed = false

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        super.init()
    }

    func connectEditor() {
        session.onStateChange = { [weak self] in self?.stateChanged() }
        document.editor.languageProbe = { [weak self] offset, word in await self?.probe(at: offset, word: word) }
        document.editor.languageHover = { [weak self] offset, word in await self?.hover(at: offset, word: word) }
        document.editor.languageFollowLink = { [weak self] offset, word in self?.followLink(at: offset, word: word) }
        document.editor.languageFollowHoverLink = { [weak self] location, word in self?.followHoverLink(location, from: word) }
        document.editor.languageContextItems = { [weak self] hit in self?.contextItems(at: hit) ?? [] }
        document.editor.onRenameSymbol = { [weak self] in self?.symbolRename.start() ?? false }
        document.editor.onCancelSymbolRename = { [weak self] in self?.symbolRename.cancel(restoreFocus: true) ?? false }
        document.editor.occurrenceHighlighting.semanticWordHighlights = { [weak self] offset in
            await self?.documentHighlights(at: offset) ?? []
        }
    }

    func updateDocument() {
        guard !isClosed, !app.isQuitting else { return }
        let url = document.hasEditableTextDocument && document.resolvedSyntaxLanguage == .zig ? document.fileURL : nil
        let folder = document.folderURL ?? document.displayedFileURL?.deletingLastPathComponent()
        let inferRoot = document.folderURL == nil
        guard sourceURL != url || sourceFolder != folder || searchesParentProjects != inferRoot else {
            documentTextChanged()
            return
        }
        sourceURL = url
        sourceFolder = folder
        searchesParentProjects = inferRoot
        symbolRename.cancel(restoreFocus: true)
        cancelLookup()
        document.editor.invalidateLanguageInteraction()
        session.setDocument(url: url, folder: folder, searchesParentProjects: inferRoot,
                            text: url == nil ? "" : document.textWithConflictPrefixes)
        stateChanged()
    }

    func documentTextChanged() {
        guard sourceURL != nil, !isClosed else { return }
        let revision = session.revision
        session.updateText(document.textWithConflictPrefixes)
        if session.revision != revision {
            symbolRename.cancel(restoreFocus: true)
            cancelLookup()
            document.editor.invalidateLanguageInteraction()
        }
    }

    func close() {
        isClosed = true
        symbolRename.cancel(restoreFocus: false)
        navigationID &+= 1
        cancelLookup()
        referenceTask?.cancel()
        status.close()
        document.editor.languageInteractionEnabled = false
        session.onStateChange = nil
        session.close()
    }

    private func stateChanged() {
        if session.state != .ready { symbolRename.cancel(restoreFocus: true) }
        let canInteract = session.supportsDefinition || session.supportsHover || session.supportsDeclaration
            || session.supportsReferences || session.supportsRename
        document.editor.languageInteractionEnabled = canInteract
        if !canInteract { cancelLookup() }
        document.editor.occurrenceHighlighting.setSemanticWordHighlightsEnabled(session.supportsDocumentHighlight)
        status.update(visible: session.isEligible, state: session.state,
                      enabled: Set(LanguageServerCommand.allCases.filter(canPerform)))
        document.titleBar.languageServerStatusChanged()
        app.languageServerStateDidChange(in: document)
    }

    func canPerform(_ command: LanguageServerCommand) -> Bool {
        guard !isClosed, !app.isQuitting, document.window.attachedSheet == nil else { return false }
        switch command {
        case .start: return session.canStart
        case .stop: return session.canStop
        case .restart: return session.canRestart
        }
    }

    func perform(_ command: LanguageServerCommand) {
        guard canPerform(command) else { return }
        if command != .start {
            navigationID &+= 1
            cancelLookup()
            document.editor.invalidateLanguageInteraction()
        }
        switch command {
        case .start: session.start()
        case .stop: session.stop()
        case .restart: session.restart()
        }
    }

    @objc func performControlCommand(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let command = LanguageServerCommand(rawValue: name) else { return }
        perform(command)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let target = (item as? NSMenuItem)?.representedObject as? SymbolMenuTarget {
            guard isCurrent(target.query), query() != nil else { return false }
            switch item.action {
            case #selector(goToDeclaration(_:)): return session.supportsDeclaration
            case #selector(findSymbolReferences(_:)): return session.supportsReferences
            case #selector(renameContextSymbol(_:)): return symbolRename.canStart
            default: return false
            }
        }
        guard let name = (item as? NSMenuItem)?.representedObject as? String,
              let command = LanguageServerCommand(rawValue: name) else { return false }
        return canPerform(command)
    }

    private func contextItems(at hit: EditorLanguageInteraction.Hit) -> [NSMenuItem] {
        guard let query = query() else { return [] }
        let target = SymbolMenuTarget(hit: hit, query: query)
        var items: [NSMenuItem] = []
        if session.supportsDeclaration {
            items.append(symbolMenuItem("Go to Declaration", action: #selector(goToDeclaration(_:)), target: target))
        }
        if session.supportsReferences {
            items.append(symbolMenuItem("Find References", action: #selector(findSymbolReferences(_:)), target: target))
        }
        if symbolRename.canStart {
            items.append(symbolMenuItem("Rename…", action: #selector(renameContextSymbol(_:)), target: target))
        }
        return items
    }

    private func symbolMenuItem(_ title: String, action: Selector, target: SymbolMenuTarget) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = target
        return item
    }

    @objc private func goToDeclaration(_ item: NSMenuItem) {
        guard validateUserInterfaceItem(item), let target = item.representedObject as? SymbolMenuTarget else { return }
        navigateSymbol(.declaration, at: target.hit.offset, word: target.hit.word, query: target.query)
    }

    @objc private func findSymbolReferences(_ item: NSMenuItem) {
        guard validateUserInterfaceItem(item), let target = item.representedObject as? SymbolMenuTarget else { return }
        navigateSymbol(.references, at: target.hit.offset, word: target.hit.word, query: target.query)
    }

    @objc private func renameContextSymbol(_ item: NSMenuItem) {
        guard validateUserInterfaceItem(item), let target = item.representedObject as? SymbolMenuTarget,
              document.window.makeFirstResponder(document.editor) else { return }
        _ = symbolRename.start(at: target.hit)
    }

    private func query() -> Query? {
        guard let url = sourceURL, !isClosed, !app.isQuitting, document.window.attachedSheet == nil,
              document.hasEditableTextDocument, document.editor.conflictEdits.isEmpty,
              !document.editor.hasMarkedText() else { return nil }
        return Query(url: url, text: document.editor.string, generation: session.generation, revision: session.revision,
                     openGeneration: document.openRequestGeneration)
    }

    private func isCurrent(_ query: Query) -> Bool {
        !Task.isCancelled && !isClosed && !app.isQuitting && sourceURL == query.url &&
            session.generation == query.generation && session.revision == query.revision &&
            document.openRequestGeneration == query.openGeneration
    }

    private func isCurrentLocation(_ location: LSPLocation, at offset: Int, in query: Query) -> Bool {
        guard location.url.standardizedFileURL == query.url.standardizedFileURL,
              let range = location.range.nsRange(in: query.text) else { return false }
        return range.length == 0 ? range.location == offset : NSLocationInRange(offset, range)
    }

    func probe(at offset: Int, word: NSRange) async -> NSRange? {
        guard session.supportsDefinition, let query = query(),
              let matches = try? await session.definition(at: offset), isCurrent(query), let first = matches.first,
              matches.count > 1 || !isCurrentLocation(first, at: offset, in: query) || session.supportsReferences else { return nil }
        return first.originRange?.nsRange(in: query.text) ?? word
    }

    func hover(at offset: Int, word: NSRange) async -> EditorLanguageHover? {
        guard session.supportsHover, let query = query(), let result = try? await session.hover(at: offset),
              isCurrent(query) else { return nil }
        return EditorLanguageHover(text: result.content, isMarkdown: result.isMarkdown,
                                   range: result.range?.nsRange(in: query.text) ?? word)
    }

    func documentHighlights(at offset: Int) async -> [NSRange] {
        guard session.supportsDocumentHighlight, let query = query(),
              let ranges = try? await session.documentHighlights(at: offset), isCurrent(query) else { return [] }
        return ranges
    }

    private func followHoverLink(_ location: LSPLocation, from word: NSRange) {
        guard session.supportsHover, query() != nil else { return }
        let origin = document.navigationLocation(at: NSRange(location: word.location, length: 0))
        navigate(location, source: word, origin: origin)
    }

    func followLink(at offset: Int, word: NSRange) {
        guard session.supportsDefinition, let query = query() else { return }
        navigateSymbol(.definition, at: offset, word: word, query: query)
    }

    private func navigateSymbol(_ command: SymbolNavigation, at offset: Int, word: NSRange, query: Query) {
        let origin = document.navigationLocation(at: NSRange(location: offset, length: 0))
        cancelLookup()
        navigationID &+= 1
        let id = navigationID
        navigationTask = Task { [weak self] in
            guard let self else { return }
            defer { if navigationID == id { navigationTask = nil } }
            do {
                if command == .references {
                    try await findReferences(at: offset, word: word, query: query, id: id, navigationOrigin: origin)
                    return
                }
                let locations = try await command == .declaration
                    ? session.declaration(at: offset) : session.definition(at: offset)
                guard isCurrent(query) else { return }
                switch locations.count {
                case 0:
                    document.editor.invalidateLanguageInteraction()
                    if command == .declaration { document.editor.showLanguageFeedback("No declaration found", at: word) }
                case 1 where command == .definition && isCurrentLocation(locations[0], at: offset, in: query):
                    if session.supportsReferences {
                        try await findReferences(at: offset, word: word, query: query, id: id, navigationOrigin: origin)
                    }
                case 1:
                    navigationTask = nil
                    await open(locations[0], id: id, source: word, navigationOrigin: origin)
                default:
                    chooseDefinition(locations, at: word, navigationOrigin: origin)
                }
            } catch {
                if isCurrent(query) { document.editor.showLanguageFeedback(command.failureMessage, at: word) }
            }
        }
    }

    private func findReferences(at offset: Int, word: NSRange, query: Query, id: UInt64,
                                navigationOrigin: NavigationHistory.Location?) async throws {
        var locations = try await session.references(at: offset, includeDeclaration: true)
        guard isCurrent(query) else { return }
        if locations.count == 2, let uses = try? await session.references(at: offset, includeDeclaration: false), uses.count == 1 {
            locations = uses
        }
        guard isCurrent(query) else { return }
        let matches = locations
        switch matches.count {
        case 0:
            document.editor.showLanguageFeedback("No references found", at: word)
        case 1:
            navigationTask = nil
            await open(matches[0], id: id, source: word, navigationOrigin: navigationOrigin)
        default:
            guard let origin = LSPPosition.at(utf16Offset: offset, in: query.text),
                  let wordInText = Range(word, in: query.text) else { return }
            let preparation = Task.detached(priority: .userInitiated) {
                Self.referenceRows(matches, sourceURL: query.url, sourceText: query.text)
            }
            let results = await withTaskCancellationHandler {
                await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard isCurrent(query) else { return }
            if results.isEmpty {
                document.editor.showLanguageFeedback("No references found", at: word)
                return
            }
            if results.count == 1 {
                navigationTask = nil
                await open(matches[results[0].index], id: id, source: word, navigationOrigin: navigationOrigin)
                return
            }
            if let navigationOrigin { app.recordNavigation(navigationOrigin, reason: .selection) }
            document.sidebar.showReferences(symbol: String(query.text[wordInText]), originURL: query.url,
                                            originLine: origin.line, originColumn: origin.character,
                                            results: results, preview: { [weak self] row in
                self?.selectReference(matches[row.index], in: matches, activate: false)
            }, activate: { [weak self] row in
                self?.selectReference(matches[row.index], in: matches, activate: true)
            }, didHide: { [weak self] in
                self?.clearReferencePreview()
            })
        }
    }

    private func selectReference(_ location: LSPLocation, in matches: [LSPLocation], activate: Bool) {
        referenceTask?.cancel()
        referenceID &+= 1
        let id = referenceID
        referenceTask = Task { [weak self] in
            guard let self else { return }
            defer { if referenceID == id { referenceTask = nil } }
            let target = location.url.standardizedFileURL
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !isClosed && !app.isQuitting && referenceID == id &&
                    document.isSidebarVisible && document.sidebarMode == .references
            }
            guard isCurrent() else { return }
            if target != document.fileURL?.standardizedFileURL {
                guard (try? await app.openFile(target, in: document, focusEditor: false, shouldOpen: isCurrent)) != nil else { return }
            }
            guard isCurrent(), document.hasEditableTextDocument, document.editor.conflictEdits.isEmpty else { return }
            let snapshot = document.editor.string
            let index = LSPTextIndex(snapshot)
            guard let range = index.nsRange(location.range) else { return }
            if activate {
                commitNavigation(to: range, origin: nil)
            } else {
                document.editor.scrollRangeToVisible(range)
            }
            let ranges = matches.filter { $0.url.standardizedFileURL == target }.compactMap { index.nsRange($0.range) }
                .sorted { $0.location < $1.location }
            document.resultDecorations.update(snapshot: snapshot, ranges: ranges, selected: range, preview: nil)
        }
    }

    private func clearReferencePreview() {
        referenceID &+= 1
        referenceTask?.cancel()
        referenceTask = nil
        document.resultDecorations.update(snapshot: "", ranges: [], selected: nil, preview: nil)
    }

    private nonisolated static func referenceRows(_ locations: [LSPLocation], sourceURL: URL, sourceText: String) -> [ReferenceResult] {
        struct Source {
            let text: NSString
            let index: LSPTextIndex

            init(_ text: String) {
                self.text = text as NSString
                index = LSPTextIndex(text)
            }
        }
        let origin = sourceURL.standardizedFileURL
        var sources = [origin: Source(sourceText)]
        var unreadable: Set<URL> = []
        return locations.enumerated().compactMap { offset, location in
            let url = location.url.standardizedFileURL
            guard !Task.isCancelled, !unreadable.contains(url) else { return nil }
            if sources[url] == nil {
                guard let file = try? FileBuffer.read(url) else {
                    unreadable.insert(url)
                    return nil
                }
                sources[url] = Source(file.text)
            }
            guard let source = sources[url], let match = source.index.nsRange(location.range) else { return nil }
            var start = 0
            var end = 0
            source.text.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: match.location, length: 0))
            let excerpt = source.text.substring(with: NSRange(location: start, length: end - start))
            let highlight = NSRange(location: match.location - start, length: max(0, min(end, NSMaxRange(match)) - match.location))
            return ReferenceResult(index: offset, url: url, line: location.range.start.line,
                                   column: location.range.start.character, excerpt: excerpt, match: highlight)
        }
    }

    private struct DefinitionChoice {
        let location: LSPLocation
        let origin: NavigationHistory.Location?
    }

    private func chooseDefinition(_ locations: [LSPLocation], at word: NSRange, navigationOrigin: NavigationHistory.Location?) {
        guard !app.isAgentCheck, let window = document.editor.window else { return }
        let menu = NSMenu(title: "Peek Definition")
        for location in locations {
            let title = "\(location.url.lastPathComponent):\(location.range.start.line + 1):\(location.range.start.character + 1)"
            let item = NSMenuItem(title: title, action: #selector(openDefinition(_:)), keyEquivalent: "")
            item.toolTip = location.url.path
            item.target = self
            item.representedObject = DefinitionChoice(location: location, origin: navigationOrigin)
            menu.addItem(item)
        }
        let screen = document.editor.firstRect(forCharacterRange: word, actualRange: nil)
        let point = document.editor.convert(window.convertPoint(fromScreen: NSPoint(x: screen.minX, y: screen.minY)), from: nil)
        menu.popUp(positioning: nil, at: point, in: document.editor)
    }

    @objc private func openDefinition(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? DefinitionChoice else { return }
        navigate(choice.location, source: nil, origin: choice.origin)
    }

    private func navigate(_ location: LSPLocation, source: NSRange?, origin: NavigationHistory.Location?) {
        cancelLookup()
        navigationID &+= 1
        let id = navigationID
        let generation = document.openRequestGeneration
        Task { [weak self] in
            guard let self, document.openRequestGeneration == generation else { return }
            await open(location, id: id, source: source, navigationOrigin: origin)
        }
    }

    private func open(_ location: LSPLocation, id: UInt64, source: NSRange?, navigationOrigin: NavigationHistory.Location?) async {
        guard navigationID == id, !isClosed, !app.isQuitting else { return }
        let target = location.url.standardizedFileURL
        if target != document.fileURL?.standardizedFileURL {
            do {
                guard try await app.openFile(target, in: document, focusEditor: false, shouldOpen: { [weak self] in
                    self?.navigationID == id && self?.isClosed == false
                }) != nil else { return }
            } catch {
                if let source, navigationID == id { document.editor.showLanguageFeedback("Could not open location", at: source) }
                return
            }
        }
        guard navigationID == id, document.hasEditableTextDocument, document.editor.conflictEdits.isEmpty,
              let range = location.range.nsRange(in: document.editor.string) else { return }
        commitNavigation(to: range, origin: navigationOrigin)
    }

    private func commitNavigation(to range: NSRange, origin: NavigationHistory.Location?) {
        let caret = NSRange(location: range.location, length: 0)
        document.navigate(to: caret, from: origin)
    }

    private func cancelLookup() {
        navigationTask?.cancel()
        navigationTask = nil
    }
}
