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

    private unowned let document: DocumentWindow
    private unowned let app: Edit
    let session = LanguageServerSession()
    private lazy var status = LanguageServerStatusPopover { [weak self] command in self?.perform(command) }
    var statusButton: NSButton { status.button }
#if EDIT_AGENT_CHECKS
    var statusPopoverForCheck: NSView? { status.contentForCheck }
#endif
    private var sourceURL: URL?
    private var sourceFolder: URL?
    private var navigationTask: Task<Void, Never>?
    private var navigationID: UInt64 = 0
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
    }

    func updateDocument() {
        guard !isClosed, !app.isQuitting else { return }
        let url = document.hasEditableTextDocument && document.resolvedSyntaxLanguage == .zig ? document.fileURL : nil
        let folder = url == nil ? nil : document.folderURL
        guard sourceURL != url || sourceFolder != folder else {
            documentTextChanged()
            return
        }
        sourceURL = url
        sourceFolder = folder
        cancelLookup()
        document.editor.invalidateLanguageInteraction()
        session.setDocument(url: url, folder: folder, text: url == nil ? "" : document.textWithConflictPrefixes)
        stateChanged()
    }

    func documentTextChanged() {
        guard sourceURL != nil, !isClosed else { return }
        let revision = session.revision
        session.updateText(document.textWithConflictPrefixes)
        if session.revision != revision {
            cancelLookup()
            document.editor.invalidateLanguageInteraction()
        }
    }

    func close() {
        isClosed = true
        navigationID &+= 1
        cancelLookup()
        status.close()
        document.editor.languageInteractionEnabled = false
        session.onStateChange = nil
        session.close()
    }

    private func stateChanged() {
        let canInteract = session.supportsDefinition || session.supportsHover
        document.editor.languageInteractionEnabled = canInteract
        if !canInteract { cancelLookup() }
        status.update(visible: session.isEligible, title: session.state.title, detail: session.state.failureReason,
                      enabled: Set(LanguageServerCommand.allCases.filter(canPerform)))
        document.titleBar.languageServerStatusChanged()
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
        guard let name = (item as? NSMenuItem)?.representedObject as? String,
              let command = LanguageServerCommand(rawValue: name) else { return false }
        return canPerform(command)
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

    func followLink(at offset: Int, word: NSRange) {
        guard session.supportsDefinition, let query = query() else { return }
        cancelLookup()
        navigationID &+= 1
        let id = navigationID
        navigationTask = Task { [weak self] in
            guard let self else { return }
            defer { if navigationID == id { navigationTask = nil } }
            do {
                let locations = try await session.definition(at: offset)
                guard isCurrent(query) else { return }
                switch locations.count {
                case 0:
                    document.editor.invalidateLanguageInteraction()
                case 1 where isCurrentLocation(locations[0], at: offset, in: query):
                    if session.supportsReferences { try await findReferences(at: offset, word: word, query: query, id: id) }
                case 1:
                    navigationTask = nil
                    await open(locations[0], id: id, source: word)
                default:
                    chooseDefinition(locations, at: word)
                }
            } catch {
                if isCurrent(query) { document.editor.showLanguageFeedback("Could not navigate to symbol", at: word) }
            }
        }
    }

    private func findReferences(at offset: Int, word: NSRange, query: Query, id: UInt64) async throws {
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
            await open(matches[0], id: id, source: word)
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
                await open(matches[results[0].index], id: id, source: word)
                return
            }
            document.sidebar.showReferences(symbol: String(query.text[wordInText]), originURL: query.url,
                                            originLine: origin.line, originColumn: origin.character,
                                            results: results) { [weak self] row in
                self?.openResult(matches[row.index])
            }
        }
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

    private func chooseDefinition(_ locations: [LSPLocation], at word: NSRange) {
        guard !app.isAgentCheck, let window = document.editor.window else { return }
        let menu = NSMenu(title: "Peek Definition")
        for location in locations {
            let title = "\(location.url.lastPathComponent):\(location.range.start.line + 1):\(location.range.start.character + 1)"
            let item = NSMenuItem(title: title, action: #selector(openDefinition(_:)), keyEquivalent: "")
            item.toolTip = location.url.path
            item.target = self
            item.representedObject = location
            menu.addItem(item)
        }
        let screen = document.editor.firstRect(forCharacterRange: word, actualRange: nil)
        let point = document.editor.convert(window.convertPoint(fromScreen: NSPoint(x: screen.minX, y: screen.minY)), from: nil)
        menu.popUp(positioning: nil, at: point, in: document.editor)
    }

    @objc private func openDefinition(_ item: NSMenuItem) {
        guard let location = item.representedObject as? LSPLocation else { return }
        openResult(location)
    }

    private func openResult(_ location: LSPLocation) {
        cancelLookup()
        navigationID &+= 1
        let id = navigationID
        Task { [weak self] in await self?.open(location, id: id, source: nil) }
    }

    private func open(_ location: LSPLocation, id: UInt64, source: NSRange?) async {
        guard navigationID == id, !isClosed, !app.isQuitting else { return }
        let target = location.url.standardizedFileURL
        if target != document.fileURL?.standardizedFileURL {
            do {
                guard try await app.openFile(target, in: document, shouldOpen: { [weak self] in
                    self?.navigationID == id && self?.isClosed == false
                }) != nil else { return }
            } catch {
                if let source, navigationID == id { document.editor.showLanguageFeedback("Could not open location", at: source) }
                return
            }
        }
        guard navigationID == id, document.hasEditableTextDocument, document.editor.conflictEdits.isEmpty,
              let range = location.range.nsRange(in: document.editor.string) else { return }
        let caret = NSRange(location: range.location, length: 0)
        if let scope = document.editor.focusRanges, !scope.contains(where: { NSLocationInRange(caret.location, $0) }) {
            document.editor.exitFocus()
        }
        document.focusContent()
        document.editor.setCaretSelections([caret])
        document.editor.scrollRangeToVisible(caret)
    }

    private func cancelLookup() {
        navigationTask?.cancel()
        navigationTask = nil
    }
}
