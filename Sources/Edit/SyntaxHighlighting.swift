import AppKit

@MainActor
final class SyntaxHighlighting {
    private static let bareWordSeparators = Set(" \t\n\r\u{0B}\u{0C}!%&()*+,-./:;<=>?[]^{|}~".utf16)

    private struct SemanticRequest: Equatable {
        let session: ObjectIdentifier
        let generation: Int
        let language: SyntaxLanguage
        let revision: Int
        let refresh: Int
    }

    private weak var editor: EditorTextView?
    private var treeSpans: [SyntaxSpan] = []
    private var semanticSpans: [SyntaxSpan] = []
    private var treeSpansAreStale = false
    private var semanticSpansAreStale = false
    private var treeSitterEnabled = true
    private var treeLanguage: SyntaxLanguage?
    private var hasRenderingColors = false
    private var backedColorRange: NSRange?
    private var editedRenderingColorRange: NSRange?
    private var wordDeletions: Set<NSRange> = []
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activity: NSTitlebarAccessoryViewController?
    private var generation = 0
    private var zigCoveredRange: NSRange?
    private var zigRequestedRange: NSRange?
    private var semanticRequest: SemanticRequest?
    private var lastSemanticColors: (request: SemanticRequest, spans: [SyntaxSpan])?
    private var semanticTask: Task<Void, Never>?
    private var semanticPreviewTask: Task<Void, Never>?
    private var semanticExpiry: Task<Void, Never>?
#if EDIT_AGENT_CHECKS
    var usesLSPForCheck: Bool { !semanticSpans.isEmpty }
    var treeSpansForCheck: [SyntaxSpan] { treeSpans }
    var semanticSpansForCheck: [SyntaxSpan] { semanticSpans }
    var needsFullSemanticTokensForCheck: Bool { lastSemanticColors == nil }
    var zigCoveredRangeForCheck: NSRange? { zigCoveredRange }
    private(set) var zigImmediateUpdatesForCheck = 0
    var beforeInstallTreeTokensForCheck: (() async -> Void)?
    var beforeInstallSemanticTokensForCheck: (() async -> Void)?
#endif

    init(editor: EditorTextView) {
        self.editor = editor
        editor.syntaxHighlighting = self
    }

    deinit {
        semanticPreviewTask?.cancel()
        semanticTask?.cancel()
        semanticExpiry?.cancel()
    }

    func update(language: SyntaxLanguage, immediate: Bool, treeSitter: Bool, session: LanguageServerSession?) {
        if let editor { editor.syntaxAnalysis.cancelIfChanged(to: editor.string, language: language) }
        if treeSitterEnabled != treeSitter {
            setTreeSitterEnabled(treeSitter, language: language)
        } else if treeSitter {
            updateTreeSitter(language: language, immediate: immediate, keepingColors: treeLanguage == language)
        }
        updateSemanticSource(session, language: language, immediate: immediate)
    }

    func setTreeSitterEnabled(_ enabled: Bool, language: SyntaxLanguage) {
        guard enabled != treeSitterEnabled else { return }
        treeSitterEnabled = enabled
        if enabled {
            updateTreeSitter(language: language, immediate: true, keepingColors: true)
        } else {
            cancelPending()
            zigCoveredRange = nil
            displayTree([])
        }
    }

    func updateSemanticSource(_ session: LanguageServerSession?, language: SyntaxLanguage, immediate: Bool = true) {
        guard let session else {
            if semanticRequest != nil {
                cancelSemanticTokens()
                displaySemantic([])
            }
            return
        }
        let request = SemanticRequest(session: ObjectIdentifier(session), generation: session.generation, language: language,
                                      revision: session.revision, refresh: session.semanticTokensRefresh)
        let previous = semanticRequest
        guard request != previous else { return }
        semanticRequest = request
        semanticPreviewTask?.cancel()
        semanticPreviewTask = nil
        semanticTask?.cancel()

        if let cached = lastSemanticColors, cached.request == request {
            semanticTask = nil
            installSemanticColors(cached.spans, request: request)
            return
        }
        lastSemanticColors = nil
        if let previous, (previous.session, previous.generation, previous.language) !=
            (request.session, request.generation, request.language) {
            semanticExpiry?.cancel()
            semanticExpiry = nil
            displaySemantic([])
        } else if semanticExpiry == nil, semanticSpans.contains(where: \.provisional) {
            // Only a token whose text changed has a speculative color. Keep the rest until replacement.
            semanticExpiry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self else { return }
                self.semanticExpiry = nil
                let count = self.semanticSpans.count
                self.semanticSpans.removeAll(where: \.provisional)
                if self.semanticSpans.count != count { self.repaintLayers() }
            }
        }

        if previous == nil, immediate, session.canPreviewSemanticTokens,
           let visible = visibleRange(), let length = editor?.textStorage?.length,
           visible.length > 0, visible.length <= length / 4 {
            semanticPreviewTask = Task { [weak self, weak session] in
                guard let session, !Task.isCancelled else { return }
                let spans = try? await session.semanticTokens(visibleRange: visible)
                guard !Task.isCancelled, let self, self.semanticRequest == request else { return }
                self.semanticPreviewTask = nil
                if let spans, !spans.isEmpty { self.displaySemantic(spans) }
            }
        }

        semanticTask = Task { [weak self, weak session] in
            if !immediate { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled, let session else { return }
            let spans = try? await session.semanticTokens()
#if EDIT_AGENT_CHECKS
            if spans != nil { await self?.beforeInstallSemanticTokensForCheck?() }
#endif
            guard !Task.isCancelled, self?.semanticRequest == request else { return }
            guard let spans else {
                self?.semanticTask = nil
                return
            }
            self?.installSemanticColors(spans, request: request)
            // The first Swift response can be syntactic while SourceKit loads build settings.
            if immediate && language == .swift && !spans.contains(where: {
                $0.color == .type || $0.color == .function || $0.color == .property || $0.color == .plain
            }) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self?.semanticRequest == request else { return }
                let settled = try? await session.semanticTokens()
                guard !Task.isCancelled, self?.semanticRequest == request else { return }
                if let settled { self?.installSemanticColors(settled, request: request) }
            }
            self?.semanticTask = nil
        }
    }

    private func installSemanticColors(_ spans: [SyntaxSpan], request: SemanticRequest) {
        lastSemanticColors = (request, spans)
        semanticPreviewTask?.cancel()
        semanticPreviewTask = nil
        semanticExpiry?.cancel()
        semanticExpiry = nil
        displaySemantic(spans)
    }

    private func cancelSemanticTokens() {
        semanticPreviewTask?.cancel()
        semanticPreviewTask = nil
        semanticTask?.cancel()
        semanticTask = nil
        semanticRequest = nil
        semanticExpiry?.cancel()
        semanticExpiry = nil
    }

    private func updateTreeSitter(language: SyntaxLanguage, immediate: Bool, keepingColors: Bool) {
        if language == .zig && SyntaxEngine.supportsIncrementalZig {
            if treeLanguage != language {
                cancelPending()
                treeLanguage = language
                zigCoveredRange = nil
                if !keepingColors { displayTree([]) }
            }
            refreshZigViewport()
            return
        }
        cancelPending()
        zigCoveredRange = nil
        let request = generation
        treeLanguage = language
        if immediate && !keepingColors { displayTree([]) }
        guard language != .plainText else { return }

        task = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(45))
            }
            guard !Task.isCancelled, let editor = self?.editor else { return }
            let source = editor.string
            let visibleRange = self?.visibleRange()
            let job = editor.syntaxAnalysis.request(in: source, language: language,
                                                    visibleRange: visibleRange, publishesPreview: !keepingColors)
            for await preview in job.previews {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.displayTree(preview)
                self.stopProgress()
            }
            guard !Task.isCancelled else { return }
            let result = await job.task.value
#if EDIT_AGENT_CHECKS
            if result != nil { await self?.beforeInstallTreeTokensForCheck?() }
#endif
            guard !Task.isCancelled, let self, self.generation == request else { return }
            if let result {
                self.displayTree(result.spans)
            } else {
                self.displayTree([])
            }
            self.stopProgress()
        }

        if immediate && !keepingColors {
            progressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.showProgress()
            }
        }
    }

    func refreshZigViewport() {
        guard treeSitterEnabled, treeLanguage == .zig, SyntaxEngine.supportsIncrementalZig,
              let editor, editor.syntaxLanguage == .zig, let text = editor.textStorage?.mutableString else { return }
        let document = NSRange(location: 0, length: text.length)
        let visible = NSIntersectionRange(visibleRange() ?? NSRange(location: 0, length: min(4_096, text.length)), document)
        guard visible.length > 0,
              zigCoveredRange.map({ NSIntersectionRange($0, visible) }) != visible,
              zigRequestedRange.map({ NSIntersectionRange($0, visible) }) != visible else { return }

        cancelPending()
        let start = max(0, visible.location - 512)
        let end = min(text.length, visible.upperBound + 512)
        let range = text.lineRange(for: NSRange(location: start, length: end - start))
        zigRequestedRange = range
        let request = generation
        let source = editor.string
        task = Task { [weak self, weak editor] in
            defer {
                if let self, self.generation == request {
                    self.task = nil
                    self.zigRequestedRange = nil
                    self.stopProgress()
                }
            }
            guard let editor, let tree = await editor.syntaxAnalysis.zigTree(in: source), !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { tree.highlights(in: range) }
            let spans = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
#if EDIT_AGENT_CHECKS
            if spans != nil { await self?.beforeInstallTreeTokensForCheck?() }
#endif
            guard let self, !Task.isCancelled, self.generation == request, let spans else { return }
            if self.semanticSpansAreStale { self.discardOverriddenColors(in: &self.semanticSpans, with: spans) }
            self.treeSpansAreStale = false
            self.treeSpans = spans
            self.zigCoveredRange = range
            // Refresh the installed viewport. Scrolling will request its own slice of this tree.
            self.refreshColors(renderingRange: range)
        }
        if treeSpans.isEmpty {
            progressTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.showProgress()
            }
        }
    }

    func prepareForBufferReplacement() {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        treeLanguage = nil
        zigCoveredRange = nil
        treeSpans = []
        semanticSpans = []
        clearColors()
        updateBackingColors(in: nil)
    }

    func install(_ snapshot: SyntaxSnapshot) {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        treeSitterEnabled = true
        treeLanguage = snapshot.language
        zigCoveredRange = snapshot.zigTree.map { NSRange(location: 0, length: $0.length) }
        semanticSpans = []
        displayTree(snapshot.analysis.spans)
        if snapshot.coversDocument, let editor {
            editor.syntaxAnalysis.install(snapshot.analysis, in: editor.string, language: snapshot.language, zigTree: snapshot.zigTree)
            if snapshot.language == .zig { refreshZigViewport() }
        } else {
            updateTreeSitter(language: snapshot.language, immediate: true, keepingColors: true)
        }
    }

    func cancel(clearingColors: Bool = true) {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        zigCoveredRange = nil
        if clearingColors {
            treeSpans = []
            semanticSpans = []
            repaintLayers()
        }
    }

    private func cancelPending() {
        generation &+= 1
        task?.cancel()
        task = nil
        zigRequestedRange = nil
        stopProgress()
    }

    private func displayTree(_ spans: [SyntaxSpan]) {
        guard !treeSpans.isEmpty || !spans.isEmpty else { return }
        treeSpansAreStale = false
        if semanticSpansAreStale { discardOverriddenColors(in: &semanticSpans, with: spans) }
        treeSpans = spans
        repaintLayers()
    }

    private func displaySemantic(_ spans: [SyntaxSpan]) {
        guard !semanticSpans.isEmpty || !spans.isEmpty else { return }
        semanticSpansAreStale = false
        if treeSpansAreStale { discardOverriddenColors(in: &treeSpans, with: spans) }
        semanticSpans = spans
        repaintLayers()
    }

    private func discardOverriddenColors(in cached: inout [SyntaxSpan], with fresh: [SyntaxSpan]) {
        cached.removeAll { token in
            spans(overlapping: token.range, from: fresh).contains { current in
                token.provisional || (token.color != current.color && token.range != current.range)
            }
        }
    }

    private func repaintLayers() {
        if hasRenderingColors || backedColorRange != nil || !treeSpans.isEmpty || !semanticSpans.isEmpty {
            refreshColors()
        }
    }

    func refreshColors(renderingRange: NSRange? = nil) {
        guard let editor, let manager = editor.textLayoutManager else { return }
        if let renderingRange {
            clearEditedRenderingColors()
            if let backedColorRange, NSIntersectionRange(backedColorRange, renderingRange) != backedColorRange,
               let previous = editor.textRange(backedColorRange, in: manager) {
                manager.removeRenderingAttribute(.foregroundColor, for: previous)
            }
            if let target = editor.textRange(renderingRange, in: manager) {
                manager.removeRenderingAttribute(.foregroundColor, for: target)
            }
        } else {
            clearColors()
        }
        let viewport = manager.textViewportLayoutController
        let scroll = editor.enclosingScrollView
        let origin = scroll?.visibleContentOrigin

        // Rendering attributes color newly drawn fragments. A native attribute edit also tells
        // TextKit to redraw glyphs that are already on screen, even if the viewport is stationary.
        if viewport.viewportRange == nil { viewport.layoutViewport() }
        let prefix = NSRange(location: 0, length: min(editor.textStorage?.length ?? 0, 4_096))
        updateBackingColors(in: visibleRange() ?? prefix)
        viewport.layoutViewport()
        if let scroll, let origin, scroll.scrollToVisibleContentOrigin(origin) {
            viewport.layoutViewport()
        }
        editor.setNeedsDisplay(editor.visibleRect)
    }

    func prepareForDeletions(in ranges: [NSRange]) {
        wordDeletions.removeAll(keepingCapacity: true)
        guard !ranges.isEmpty, !treeSpans.isEmpty || !semanticSpans.isEmpty,
              let text = editor?.textStorage?.mutableString else { return }
        // Check the removed characters while they can still tell us whether this was part of a word.
        for range in ranges where range.location != NSNotFound && range.length > 0 && range.upperBound <= text.length {
            if (range.location..<range.upperBound).allSatisfy({ Self.isWord(text.character(at: $0)) }) {
                wordDeletions.insert(range)
            }
        }
    }

    func storageDidEdit(_ storage: NSTextStorage, replacements: [EditorTextEdit]?) -> NSRange? {
        defer { wordDeletions.removeAll(keepingCapacity: true) }
        lastSemanticColors = nil
        treeSpansAreStale = true
        semanticSpansAreStale = true
        if treeLanguage == .zig && SyntaxEngine.supportsIncrementalZig {
            cancelPending()
            zigCoveredRange = nil
        }
        let edit = storage.editedRange
        let delta = storage.changeInLength
        let replacedLength = edit.length - delta
        guard edit.location != NSNotFound, edit.location <= storage.length,
              edit.length <= storage.length - edit.location, replacedLength >= 0 else {
            backedColorRange = NSRange(location: 0, length: storage.length)
            treeSpans = []
            semanticSpans = []
            return backedColorRange
        }

        let edits = replacements?.map { EditorTextChange(range: $0.range, delta: $0.lengthChange) }
            ?? [EditorTextChange(range: NSRange(location: edit.location, length: replacedLength), delta: delta)]
        var invalidated = invalidatedColorRange(after: edits, lengthChange: delta)
        if let visible = visibleRange() ?? backedColorRange {
            let typingText = editor?.hasMarkedText() == false && editor?.isRenamingSymbol == false
                ? storage.mutableString : nil
            let previousTree = treeSpans
            treeSpans = remappedSpans(treeSpans, in: visible, after: edits, typingText: typingText)
            semanticSpans = remappedSpans(semanticSpans, in: visible, after: edits, typingText: typingText)
            if let typingText, edits.count == 1, let range = refreshZigEdit(edit, in: typingText) {
                invalidated = invalidated.map { NSUnionRange($0, range) } ?? range
            } else if let typingText, edits.count == 1, let edit = edits.first,
                      let localWord = classifyZigWord(after: edit, previous: previousTree, in: typingText) {
                let cached = spans(overlapping: localWord.range, from: treeSpans)
                if cached.isEmpty || cached.first?.range == localWord.range {
                    treeSpans.replaceSubrange(cached.startIndex..<cached.endIndex, with: [localWord])
                    // Install the whole word in the same display update as the new characters.
                    semanticSpans.removeAll { NSIntersectionRange($0.range, localWord.range).length > 0 }
                    invalidated = invalidated.map { NSUnionRange($0, localWord.range) } ?? localWord.range
                }
            }
        } else {
            treeSpans = []
            semanticSpans = []
        }
        guard let backed = backedColorRange else { return invalidated }
        let beforeEnd = edit.location + replacedLength
        if beforeEnd < backed.location {
            backedColorRange = NSRange(location: backed.location + delta, length: backed.length)
        } else if edit.location <= backed.upperBound {
            // Edits touching the cached colors can inherit them across the replaced range.
            let start = min(backed.location, edit.location)
            let end = max(edit.upperBound, backed.upperBound + delta)
            backedColorRange = NSRange(location: start, length: end - start)
        }
        return invalidated
    }

    private func refreshZigEdit(_ edit: NSRange, in text: NSString) -> NSRange? {
        guard treeSitterEnabled, treeLanguage == .zig, let editor, editor.syntaxLanguage == .zig,
              text.length > 0, SyntaxEngine.supportsIncrementalZig else { return nil }
        let line = LineEditing.line(at: edit.location, in: text).contentRange
        guard edit.upperBound <= line.upperBound, line.length <= 2_048 else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(2)
        guard let tree = editor.syntaxAnalysis.zigTreeForEdit(in: editor.string, deadline: deadline),
              let fresh = tree.highlights(in: line, deadline: deadline) else { return nil }
        let previous = spans(overlapping: line, from: treeSpans)
        guard previous.allSatisfy({ $0.start >= line.location && $0.end <= line.upperBound }),
              fresh.allSatisfy({ $0.start >= line.location && $0.end <= line.upperBound }) else { return nil }

        let start = max(0, edit.location - 1)
        let touched = NSRange(location: start, length: min(edit.upperBound + 1, text.length) - start)
        let affectedSyntax = Array(spans(overlapping: touched, from: treeSpans)) + spans(overlapping: touched, from: fresh)
        semanticSpans.removeAll { cached in
            affectedSyntax.contains { NSIntersectionRange(cached.range, $0.range).length > 0 }
        }
        treeSpans.replaceSubrange(previous.startIndex..<previous.endIndex, with: fresh)
#if EDIT_AGENT_CHECKS
        zigImmediateUpdatesForCheck += 1
#endif
        return line
    }

    private func classifyZigWord(after edit: EditorTextChange, previous: [SyntaxSpan], in text: NSString) -> SyntaxSpan? {
        guard treeSitterEnabled, treeLanguage == .zig, editor?.syntaxLanguage == .zig else { return nil }
        let word: SyntaxSpan
        if edit.range.length == 0 && edit.delta > 0 {
            // A new word can be classified locally when it starts an explicit error tag.
            word = SyntaxSpan(start: edit.range.location, end: edit.range.location + edit.delta, color: .type)
        } else {
            let deletion = edit.range
            guard edit.replacementLength == 0, wordDeletions.contains(deletion),
                  let previous = spans(overlapping: deletion, from: previous).first,
                  deletion.location >= previous.start, deletion.upperBound <= previous.end else { return nil }
            // The control color also paints labels whose syntax can depend on another line.
            word = SyntaxSpan(start: previous.start, end: previous.end - deletion.length, color: previous.color)
        }
        let wasKeyword = word.color == .keyword
        let errorPrefix = "error."
        let prefixStart = word.start - errorPrefix.utf16.count
        let isErrorTag = word.color == .type && prefixStart >= 0
            && (prefixStart == 0 || Self.bareWordSeparators.contains(text.character(at: prefixStart - 1)))
            && text.substring(with: NSRange(location: prefixStart, length: errorPrefix.utf16.count)) == errorPrefix
        guard (wasKeyword || isErrorTag), word.start < word.end else { return nil }

        let line = LineEditing.line(at: word.start, in: text)
        // Restrict the synchronous parse to one short line and roles with enough context on that line.
        guard line.contentRange.length <= 2_048, word.end <= line.contentEnd,
              colorAfterBoundaryEdit(to: word, appended: 0, in: text) != nil,
              let result = SyntaxEngine.analysis(in: text.substring(with: line.contentRange), language: .zig,
                                                 includesBrackets: false) else { return nil }

        let localRange = NSRange(location: word.start - line.start, length: word.range.length)
        let local = spans(overlapping: localRange, from: result.spans)
        let color: SyntaxColor
        if let span = local.first {
            guard local.count == 1, span.range == localRange else { return nil }
            if isErrorTag {
                guard span.color == .type else { return nil }
            } else {
                guard span.color == .keyword || span.color == .control else { return nil }
            }
            color = span.color
        } else {
            guard wasKeyword else { return nil }
            color = .plain
        }
        return SyntaxSpan(start: word.start, end: word.end, color: color)
    }

    private func invalidatedColorRange(after edits: [EditorTextChange], lengthChange: Int) -> NSRange? {
        var invalidated: NSRange?
        for edit in edits {
            // Include the neighbors of both boundaries. Deleting a separator can join two tokens.
            let start = max(0, edit.range.location - 1)
            let touching = NSRange(location: start, length: edit.range.upperBound + 1 - start)
            let local = spans(overlapping: touching, from: treeSpans)
            let semantic = spans(overlapping: touching, from: semanticSpans)
            for layer in [local, semantic] {
                guard let first = layer.first, let last = layer.last else { continue }
                let wholeTokens = NSRange(location: first.start, length: last.end - first.start)
                invalidated = invalidated.map { NSUnionRange($0, wholeTokens) } ?? wholeTokens
            }
        }
        guard let invalidated, let first = edits.first, let last = edits.last else { return nil }
        // Rebase the union once. Individual discarded ranges can contain several edits.
        let start = min(invalidated.location, first.range.location)
        let end = max(invalidated.upperBound, last.range.upperBound) + lengthChange
        return NSRange(location: start, length: end - start)
    }

    private func remappedSpans(_ spans: [SyntaxSpan], in visible: NSRange,
                               after edits: [EditorTextChange], typingText: NSString?) -> [SyntaxSpan] {
        var mapped: [SyntaxSpan] = []
        var editIndex = 0
        var offset = 0
        spanLoop: for span in self.spans(overlapping: visible, from: spans) {
            var editedAtStart = false
            while editIndex < edits.count, edits[editIndex].range.upperBound <= span.start {
                let edit = edits[editIndex]
                editedAtStart = edit.range.upperBound == span.start
                offset += edit.delta
                editIndex += 1
            }
            var nextIndex = editIndex
            var removed = 0
            while nextIndex < edits.count, edits[nextIndex].range.location < span.end {
                let edit = edits[nextIndex]
                guard typingText != nil, edit.range.upperBound <= span.end,
                      edit.delta == -edit.range.length, wordDeletions.contains(edit.range) else { continue spanLoop }
                removed += edit.range.length
                nextIndex += 1
            }
            let next = nextIndex < edits.count ? edits[nextIndex] : nil
            let shifted = SyntaxSpan(start: span.start + offset, end: span.end + offset - removed,
                                     color: span.color, provisional: span.provisional || removed > 0)
            let editedAtEnd = next?.range.location == span.end
            if removed == 0 && !editedAtStart && !editedAtEnd {
                mapped.append(shifted)
            } else if let typingText {
                let appended = if let next, editedAtEnd, next.range.length == 0 { next.delta } else { 0 }
                if let carried = colorAfterBoundaryEdit(to: shifted, appended: appended, in: typingText) {
                    mapped.append(carried)
                }
            }
        }
        return mapped
    }

    private static func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 }
    private static func isWord(_ unit: UInt16) -> Bool { isLetter(unit) || (48...57).contains(unit) }

    private func colorAfterBoundaryEdit(to span: SyntaxSpan, appended: Int, in text: NSString) -> SyntaxSpan? {
        switch span.color {
        case .plain, .keyword, .control, .type, .function, .property: break
        default: return nil
        }
        guard let language = editor?.syntaxLanguage else { return nil }
        switch language {
        case .c, .cpp, .go, .javascript, .javascriptJSX, .lua, .objectiveC, .objectiveCPP, .python, .rust,
             .solidity, .swift, .typescript, .tsx, .zig: break
        default: return nil
        }
        guard span.start >= 0, span.start < span.end, span.end + appended <= text.length else { return nil }

        func isWordBoundary(at offset: Int) -> Bool {
            guard offset >= 0, offset < text.length else { return true }
            return Self.bareWordSeparators.contains(text.character(at: offset))
        }

        guard Self.isLetter(text.character(at: span.start)), isWordBoundary(at: span.start - 1),
              (span.start..<span.end).allSatisfy({ Self.isWord(text.character(at: $0)) }) else { return nil }
        if isWordBoundary(at: span.end) { return span }
        // If deleting a separator joins words, the old ranges are no longer tokens.
        // When typing an identifier continuation, carry its color on the new whole range.
        let end = span.end + appended
        guard appended > 0, isWordBoundary(at: end),
              (span.end..<end).allSatisfy({ Self.isWord(text.character(at: $0)) }) else { return nil }
        return SyntaxSpan(start: span.start, end: end, color: span.color, provisional: true)
    }

    func repaintEditedColors(in affected: NSRange, storage: NSTextStorage) {
        let range = NSIntersectionRange(affected, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        if hasRenderingColors {
            editedRenderingColorRange = editedRenderingColorRange.map { NSUnionRange($0, range) } ?? range
        }
        // Set only foregrounds during storage processing so inherited color is removed
        // before TextKit lays out the edit. Keep any surviving colors in the same update.
        applyForegroundColors(in: range, to: storage)
    }

    func clearEditedRenderingColors() {
        guard let edited = editedRenderingColorRange, let editor, let storage = editor.textStorage,
              let manager = editor.textLayoutManager else { return }
        editedRenderingColorRange = nil
        let range = NSIntersectionRange(edited, NSRange(location: 0, length: storage.length))
        if range.length > 0, let target = editor.textRange(range, in: manager) {
            // TextKit has rebased its rendering attributes into the new text by this point.
            manager.removeRenderingAttribute(.foregroundColor, for: target)
        }
    }

    private func updateBackingColors(in visible: NSRange?) {
        guard let editor, !editor.hasMarkedText(), let storage = editor.textStorage,
              let content = editor.textLayoutManager?.textContentManager else { return }
        let document = NSRange(location: 0, length: storage.length)
        let previous = backedColorRange.map { NSIntersectionRange($0, document) }
        let visible = visible.map { NSIntersectionRange($0, document) }
        guard (previous?.length ?? 0) > 0 || (visible?.length ?? 0) > 0 else {
            backedColorRange = nil
            return
        }
        var typingAttributes = editor.typingAttributes
        typingAttributes[.foregroundColor] = NSColor.textColor
        var hasColors = false
        content.performEditingTransaction {
            storage.beginEditing()
            if let previous, previous.length > 0, previous != visible {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: previous)
            }
            if let visible, visible.length > 0 {
                hasColors = applyForegroundColors(in: visible, to: storage)
            }
            storage.endEditing()
        }
        editor.typingAttributes = typingAttributes
        backedColorRange = hasColors ? visible : nil
    }

    @discardableResult
    private func applyForegroundColors(in range: NSRange, to storage: NSTextStorage) -> Bool {
        let colors = colors(in: range)
        let conflictColors = editor?.jjConflictDecorations?.foregrounds(in: range) ?? []
        let link = editor?.languageDefinitionLinkRange.map { NSIntersectionRange(range, $0) }
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
        for span in colors {
            storage.addAttribute(.foregroundColor, value: span.color.nativeColor, range: NSIntersectionRange(range, span.range))
        }
        for (part, color) in conflictColors {
            storage.addAttribute(.foregroundColor, value: color, range: part)
        }
        if let link, link.length > 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: link)
        }
        return !colors.isEmpty || !conflictColors.isEmpty || (link?.length ?? 0) > 0
    }

    private func visibleRange() -> NSRange? {
        guard let editor, let manager = editor.textLayoutManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return nil }
        return editor.charRange(visible, in: manager)
    }

    func prepareForDrawing(_ fragment: NSTextLayoutFragment, using manager: NSTextLayoutManager) {
        clearEditedRenderingColors()
        paint(fragment.rangeInElement, using: manager)
    }

    private func clearColors() {
        editedRenderingColorRange = nil
        guard hasRenderingColors else { return }
        hasRenderingColors = false
        if let manager = editor?.textLayoutManager {
            manager.removeRenderingAttribute(.foregroundColor, for: manager.documentRange)
            manager.removeRenderingAttribute(.underlineStyle, for: manager.documentRange)
        }
    }

    private func paint(_ range: NSTextRange, using manager: NSTextLayoutManager) {
        let link = editor?.languageDefinitionLinkRange
        guard !treeSpans.isEmpty || !semanticSpans.isEmpty ||
                editor?.jjConflictDecorations?.hasHighlights == true || link != nil else { return }
        let origin = manager.documentRange.location
        let start = manager.offset(from: origin, to: range.location)
        let end = start + manager.offset(from: range.location, to: range.endLocation)
        guard start < end else { return }

        let visible = NSRange(location: start, length: end - start)
        func paintColor(_ color: NSColor, in span: NSRange) {
            guard let from = manager.location(range.location, offsetBy: span.location - start),
                  let to = manager.location(from, offsetBy: span.length),
                  let target = NSTextRange(location: from, end: to) else { return }
            manager.addRenderingAttribute(.foregroundColor, value: color, for: target)
            hasRenderingColors = true
        }
        for span in colors(in: visible) {
            paintColor(span.color.nativeColor, in: NSIntersectionRange(visible, NSRange(location: span.start, length: span.end - span.start)))
        }
        for (range, color) in editor?.jjConflictDecorations?.foregrounds(in: visible) ?? [] {
            paintColor(color, in: range)
        }
        if let editor, let link {
            let linked = NSIntersectionRange(visible, link)
            if linked.length > 0, let target = editor.textRange(linked, in: manager) {
                paintColor(.linkColor, in: linked)
                manager.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, for: target)
            }
        }
    }

    private func colors(in range: NSRange) -> [SyntaxSpan] {
        let local = spans(overlapping: range, from: treeSpans)
        let semantic = spans(overlapping: range, from: semanticSpans)
        // Both TextKit drawing paths apply foregrounds in order.
        return Array(local) + semantic
    }

    private func spans(overlapping range: NSRange, from spans: [SyntaxSpan]) -> ArraySlice<SyntaxSpan> {
        guard range.length > 0 else { return [] }
        var low = 0
        var high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].end <= range.location { low = middle + 1 }
            else { high = middle }
        }
        var end = low
        while end < spans.count && spans[end].start < NSMaxRange(range) { end += 1 }
        return spans[low..<end]
    }

    private func showProgress() {
        guard let window = editor?.window, window.isVisible, activity == nil else { return }
        let controller = NSTitlebarAccessoryViewController()
        let indicator = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        let bounds = NSRect(x: 4, y: 4, width: 16, height: 16)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let icon = NSImageView(frame: bounds)
            icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            indicator.addSubview(icon)
        } else {
            let spinner = NSProgressIndicator(frame: bounds)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            indicator.addSubview(spinner)
        }
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityLabel("Highlighting syntax")
        controller.view = indicator
        controller.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(controller)
        activity = controller
    }

    private func stopProgress() {
        progressTask?.cancel()
        progressTask = nil
        activity?.removeFromParent()
        activity = nil
    }
}

extension SyntaxColor {
    private static let colors = Dictionary(uniqueKeysWithValues: allCases.filter { $0 != .plain }.map { ($0, $0.makeNativeColor()) })

    var nativeColor: NSColor { Self.colors[self] ?? .textColor }

    var appearanceRGB: (dark: UInt32, light: UInt32) {
        switch self {
        case .plain: (0xFFFFFF, 0x000000)
        case .keyword: (0x569CD6, 0x0000FF)
        case .control: (0xC586C0, 0xAF00DB)
        case .type: (0x4EC9B0, 0x226E84)
        case .function: (0xDCDCAA, 0x795E26)
        case .string: (0xCE9178, 0xA31515)
        case .number: (0xB5CEA8, 0x08764D)
        case .comment: (0x6E9D59, 0x007800)
        case .property: (0x9CDCFE, 0x001080)
        case .markup: (0x569CD6, 0x800000)
        case .attribute: (0x9CDCFE, 0xC00000)
        }
    }

    private func makeNativeColor() -> NSColor {
        let pair = appearanceRGB
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = dark ? pair.dark : pair.light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255,
                alpha: 1
            )
        }
    }
}
