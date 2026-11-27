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
        let server: LanguageServer
        let generation: Int
        let revision: Int
        let openGeneration: UInt64
    }

    private enum SymbolNavigation {
        case definition, definitionLink, references

        var failureMessage: String {
            switch self {
            case .definition, .definitionLink: "Could not navigate to symbol"
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
    private let sessions: [LanguageServerSession]
    var workspaceSessions: [LanguageServerSession] { sessions.filter(\.supportsWorkspaceSymbols) }
    var highlightingSession: LanguageServerSession? {
        guard !isClosed, document.isHighlightingEnabled(.lsp), document.editor.conflictEdits.isEmpty,
              sourceURL != nil, sourceURL == document.fileURL, sourceLanguage == document.resolvedSyntaxLanguage,
              session.supportsSemanticTokens else { return nil }
        return session
    }
    var session: LanguageServerSession {
        sourceServer.flatMap { session(for: $0) }
            ?? workspaceSessions.first ?? sessions.first(where: \.isEligible) ?? sessions[0]
    }

    private func session(for server: LanguageServer) -> LanguageServerSession? {
        sessions.first { $0.server == server }
    }
    private lazy var symbolRename = DocumentSymbolRename(document: document, app: app)
    private lazy var status = LanguageServerStatusPopover { [weak self] server, command in
        self?.perform(command, for: server)
    }
    var statusButton: NSButton { status.button }
#if EDIT_AGENT_CHECKS
    var statusPopoverForCheck: NSView? { status.contentForCheck }
    var statusIndicatorForCheck: LanguageServerStatusPopover.Indicator? { status.indicator }
    var serversStoppedForCheck: Bool { sessions.allSatisfy { $0.state == .stopped } }
#endif
    private var sourceURL: URL?
    private var sourceLanguage: SyntaxLanguage?
    private var sourceServer: LanguageServer? { sourceLanguage.flatMap(LanguageServer.init(language:)) }
    private var sourceFolder: URL?
    private var searchesParentProjects = false
    private var navigationTask: Task<Void, Never>?
    private var navigationID: UInt64 = 0
    private var referenceTask: Task<Void, Never>?
    private var referenceID: UInt64 = 0
    private var isClosed = false
    private(set) var pathsWithErrors: Set<String> = []

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        sessions = LanguageServer.allCases.map {
            LanguageServerSession(server: $0, workspacePreferences: app.workspaceLanguageServers)
        }
        super.init()
    }

    func connectEditor() {
        for session in sessions {
            session.onStateChange = { [weak self] in self?.stateChanged() }
            session.onProgressChange = { [weak self] in self?.updateServerStatus() }
            session.onDiagnosticsChange = { [weak self] in self?.updateDiagnostics() }
            session.onSemanticTokensRefresh = { [weak self, weak session] in
                guard let self, let session, self.highlightingSession === session else { return }
                self.document.updateLSPHighlighting(immediate: false)
            }
        }
        document.editor.languageProbe = { [weak self] offset, word in await self?.probe(at: offset, word: word) }
        document.editor.languageHover = { [weak self] offset, word in
            guard let self, document.editor.languageAssistance?.isPresenting != true else { return nil }
            return await hover(at: offset, word: word)
        }
        document.editor.languageFollowLink = { [weak self] offset, word in self?.followLink(at: offset, word: word) }
        document.editor.languageFollowHoverLink = { [weak self] location, word in self?.followHoverLink(location, from: word) }
        document.editor.languageContextItems = { [weak self] hit in self?.contextItems(at: hit) ?? [] }
        document.editor.onRenameSymbol = { [weak self] in self?.symbolRename.start() ?? false }
        document.editor.onCancelSymbolRename = { [weak self] in self?.symbolRename.cancel() ?? false }
        document.editor.onSubmitSymbolRename = { [weak self] in self?.symbolRename.submit() }
        document.editor.occurrenceHighlighting.semanticWordHighlights = { [weak self] offset in
            await self?.documentHighlights(at: offset) ?? []
        }
        document.editor.languageAssistance = EditorLanguageAssistance(editor: document.editor) { [weak self] in
            guard let self, editableSourceURL != nil, document.editor.isEditable,
                  document.editor.jjInlineDiff?.projectedEditRange == nil else { return nil }
            let session = session
            return .init(session: session, revision: session.revision, generation: session.generation,
                         opening: document.openRequestGeneration)
        }
    }

    func updateDocument() {
        guard !isClosed, !app.isQuitting else { return }
        let language = document.resolvedSyntaxLanguage
        let server = LanguageServer(language: language)
        let url = document.hasEditableTextDocument && server != nil ? document.fileURL : nil
        let sourceLanguage = url == nil ? nil : language
        let folder = document.folderURL ?? document.displayedFileURL?.deletingLastPathComponent()
        let inferRoot = document.folderURL == nil
        guard sourceURL != url || self.sourceLanguage != sourceLanguage || sourceFolder != folder
            || searchesParentProjects != inferRoot else {
            documentTextChanged()
            document.updateLSPHighlighting()
            return
        }
        symbolRename.cancel()
        document.editor.languageAssistance?.contextChanged()
        sourceURL = url
        self.sourceLanguage = sourceLanguage
        sourceFolder = folder
        searchesParentProjects = inferRoot
        cancelLookup()
        document.editor.invalidateLanguageInteraction()
        let text = url == nil ? "" : document.textWithConflictPrefixes
        for session in sessions {
            session.setDocument(url: session.server == sourceServer ? url : nil,
                                language: session.server == sourceServer ? sourceLanguage : nil,
                                folder: folder, searchesParentProjects: inferRoot, text: text)
        }
        stateChanged()
    }

    func documentTextChanged() {
        guard sourceURL != nil, !isClosed else { return }
        let revision = session.revision
        session.updateText(document.textWithConflictPrefixes)
        if session.revision != revision {
            document.editor.languageBufferChanged()
            updateDiagnostics()
            symbolRename.cancel()
            cancelLookup()
            document.editor.invalidateLanguageInteraction()
        }
    }

    func documentDidSave(_ url: URL, text: String) {
        guard !isClosed, sourceServer == .solidity, sourceURL == url else { return }
        session.didSave(url, text: text)
    }

    func workspaceSymbols(query: String) async throws -> [LSPSymbol] {
        let results = await withTaskGroup(of: (Int, Result<[LSPSymbol], Error>).self) { group in
            for (index, session) in workspaceSessions.enumerated() {
                group.addTask { (index, await self.workspaceSymbolResult(in: session, query: query)) }
            }
            var results: [(Int, Result<[LSPSymbol], Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        try Task.checkCancellation()
        var matches: [[LSPSymbol]] = []
        var firstError: Error?
        for result in results {
            switch result {
            case .success(let symbols): matches.append(symbols)
            case .failure(let error): if firstError == nil { firstError = error }
            }
        }
        if matches.isEmpty, let firstError { throw firstError }
        return matches.flatMap { $0 }
    }

    private func workspaceSymbolResult(in session: LanguageServerSession, query: String) async -> Result<[LSPSymbol], Error> {
        do { return .success(try await session.workspaceSymbols(query: query)) }
        catch { return .failure(error) }
    }

    func close() {
        isClosed = true
        document.editor.languageAssistance?.contextChanged()
        symbolRename.cancel()
        navigationID &+= 1
        cancelLookup()
        referenceTask?.cancel()
        status.close()
        document.editor.languageInteractionEnabled = false
        for session in sessions {
            session.onStateChange = nil
            session.onProgressChange = nil
            session.onSemanticTokensRefresh = nil
            session.onDiagnosticsChange = nil
            session.close()
        }
        updateWorktreeDiagnostics()
    }

    private func stateChanged() {
        document.updateLSPHighlighting()
        updateDiagnostics()
        if sourceURL == nil || session.state != .ready {
            symbolRename.cancel()
            document.editor.languageAssistance?.contextChanged()
        }
        if !document.editor.languageInteractionEnabled { cancelLookup() }
        document.editor.occurrenceHighlighting.setSemanticWordHighlightsEnabled(session.supportsDocumentHighlight)
        updateServerStatus()
        app.languageServerStateDidChange(in: document)
    }

    private func updateDiagnostics() {
        let isCurrent = sourceURL != nil && sourceURL == document.fileURL
            && sourceLanguage == document.resolvedSyntaxLanguage && document.editor.conflictEdits.isEmpty
        document.editor.setDiagnostics(isCurrent ? session.diagnostics : [])
        document.editor.languageInteractionEnabled = sourceURL != nil && (session.supportsDefinition || session.supportsHover
            || session.supportsReferences || session.supportsRename || !document.editor.diagnostics.isEmpty)
        updateWorktreeDiagnostics()
    }

    private func updateWorktreeDiagnostics() {
        let paths = sessions.reduce(into: Set<String>()) { $0.formUnion($1.pathsWithErrors) }
        guard paths != pathsWithErrors else { return }
        pathsWithErrors = paths
        app.worktreeDiagnosticsDidChange()
    }

    private func updateServerStatus() {
        status.update(sessions.filter(\.isEligible).map { session in
            .init(server: session.server, state: session.state, progress: session.progress,
                  enabled: Set(LanguageServerCommand.allCases.filter { canPerform($0, in: session) }))
        })
        document.titleBar.languageServerStatusChanged()
    }

    func canPerform(_ command: LanguageServerCommand) -> Bool {
        canPerform(command, in: session)
    }

    private func canPerform(_ command: LanguageServerCommand, in session: LanguageServerSession) -> Bool {
        guard !isClosed, !app.isQuitting, document.window.attachedSheet == nil else { return false }
        switch command {
        case .start: return session.canStart
        case .stop: return session.canStop
        case .restart: return session.canRestart
        }
    }

    func perform(_ command: LanguageServerCommand) {
        perform(command, for: session.server)
    }

    private func perform(_ command: LanguageServerCommand, for server: LanguageServer) {
        guard let target = session(for: server), canPerform(command, in: target) else { return }
        if command != .start, target === session {
            navigationID &+= 1
            cancelLookup()
            document.editor.invalidateLanguageInteraction()
        }
        switch command {
        case .start: target.start()
        case .stop: target.stop()
        case .restart: target.restart()
        }
        for peer in app.documents where peer !== document {
            let features = peer.languageFeatures
            guard !features.isClosed else { continue }
            features.session(for: server)?.workspacePreferenceDidChange()
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
            case #selector(goToDefinition(_:)): return session.supportsDefinition
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
        if session.supportsDefinition {
            items.append(symbolMenuItem("Go to Definition", action: #selector(goToDefinition(_:)), target: target))
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

    @objc private func goToDefinition(_ item: NSMenuItem) {
        guard validateUserInterfaceItem(item), let target = item.representedObject as? SymbolMenuTarget else { return }
        navigateSymbol(.definition, at: target.hit.offset, word: target.hit.word, query: target.query)
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

    private var editableSourceURL: URL? {
        guard let url = sourceURL, !isClosed, !app.isQuitting, document.window.attachedSheet == nil,
              document.hasEditableTextDocument, document.editor.conflictEdits.isEmpty,
              !document.editor.hasMarkedText(), document.editor.renameRange == nil else { return nil }
        return url
    }

    private func query() -> Query? {
        guard let url = editableSourceURL else { return nil }
        return Query(url: url, text: document.editor.string, server: session.server,
                     generation: session.generation, revision: session.revision,
                     openGeneration: document.openRequestGeneration)
    }

    private func isCurrent(_ query: Query) -> Bool {
        !Task.isCancelled && !isClosed && !app.isQuitting && sourceURL == query.url && session.server == query.server &&
            session.generation == query.generation && session.revision == query.revision &&
            document.openRequestGeneration == query.openGeneration
    }

    private func isCurrentLocation(_ location: LSPLocation, at offset: Int, word: NSRange, in query: Query) -> Bool {
        guard location.url.standardizedFileURL == query.url.standardizedFileURL,
              let range = location.range.nsRange(in: query.text) else { return false }
        return range.length == 0 ? NSLocationInRange(range.location, word) : NSLocationInRange(offset, range)
    }

    func probe(at offset: Int, word: NSRange) async -> NSRange? {
        guard session.supportsDefinition, let query = query(),
              let matches = try? await session.definition(at: offset), isCurrent(query), let first = matches.first,
              matches.count > 1 || !isCurrentLocation(first, at: offset, word: word, in: query) || session.supportsReferences else { return nil }
        return first.originRange?.nsRange(in: query.text) ?? word
    }

    func hover(at offset: Int, word: NSRange) async -> EditorLanguageHover? {
        guard session.supportsHover, let query = query(), let result = try? await session.hover(at: offset),
              isCurrent(query) else { return nil }
        let range = result.range?.nsRange(in: query.text)
        // OLS sometimes returns the package declaration range for an import hover.
        let anchor = range.flatMap { query.server == .odin && !NSLocationInRange(offset, $0) ? nil : $0 }
        return EditorLanguageHover(text: result.content, isMarkdown: result.isMarkdown, range: anchor ?? word,
                                   server: query.server)
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
        navigateSymbol(.definitionLink, at: offset, word: word, query: query)
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
                let locations = try await session.definition(at: offset)
                guard isCurrent(query) else { return }
                switch locations.count {
                case 0:
                    document.editor.invalidateLanguageInteraction()
                    if command == .definition { document.editor.showLanguageFeedback("No definition found", at: word) }
                case 1 where command == .definitionLink && isCurrentLocation(locations[0], at: offset, word: word, in: query):
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
            let symbol = String(query.text[wordInText])
            let preparation = Task.detached(priority: .userInitiated) {
                Self.referenceRows(matches, symbol: symbol, sourceURL: query.url, sourceText: query.text)
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
            if let navigationOrigin { app.recordNavigation(navigationOrigin, in: document, reason: .selection) }
            document.sidebar.showReferences(symbol: symbol, originURL: query.url,
                                            originLine: origin.line, originColumn: origin.character,
                                            results: results, preview: { [weak self] row, retained in
                self?.selectReference(matches[row.index], in: retained.map { matches[$0] }, symbol: symbol, activate: false)
            }, activate: { [weak self] row, retained in
                self?.selectReference(matches[row.index], in: retained.map { matches[$0] }, symbol: symbol, activate: true)
            }, didHide: { [weak self] in
                self?.clearReferencePreview()
            })
        }
    }

    private func selectReference(_ location: LSPLocation, in matches: [LSPLocation], symbol: String, activate: Bool) {
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
            let text = snapshot as NSString
            guard let range = Self.referenceMatch(location.range, symbol: symbol, index: index, text: text) else { return }
            if activate {
                commitNavigation(to: range, origin: nil)
            } else {
                document.editor.scrollRangeToVisible(range)
            }
            let ranges = matches.filter { $0.url.standardizedFileURL == target }
                .compactMap { Self.referenceMatch($0.range, symbol: symbol, index: index, text: text) }
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

    private nonisolated static func referenceMatch(_ range: LSPRange, symbol: String,
                                                   index: LSPTextIndex, text: NSString) -> NSRange? {
        guard let match = index.nsRange(range) else { return nil }
        // SourceKit-LSP can return point locations from its index.
        guard match.length == 0 else { return match }
        let candidate = NSRange(location: match.location, length: symbol.utf16.count)
        if candidate.upperBound <= text.length, text.substring(with: candidate).utf8.elementsEqual(symbol.utf8) {
            return candidate
        }
        return match
    }

    private nonisolated static func referenceRows(_ locations: [LSPLocation], symbol: String,
                                                  sourceURL: URL, sourceText: String) -> [ReferenceResult] {
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
            guard let source = sources[url],
                  let match = referenceMatch(location.range, symbol: symbol, index: source.index, text: source.text) else { return nil }
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
