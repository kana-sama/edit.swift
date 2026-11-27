import AppKit

@MainActor
final class SyntaxHighlighting {
    private static let odinQuotes = CharacterSet(charactersIn: "\"'`")
    private static let solidityQuotes = CharacterSet(charactersIn: "\"'")
    private static let solidityCompoundOperators: Set<String> = [
        "++", "--", "**", "&&", "||", "<<", ">>", ":=", "==", "!=", "<=", ">=",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
    ]
    private static let bareWordSeparators = Set(" \t\n\r\u{0B}\u{0C}!%&()*+,-./:;<=>?[]^{|}~".utf16)
    // The native tree currently takes a contiguous UTF-16 snapshot. Defer that copy for large buffers.
    private static let foregroundSyntaxSnapshotLimit = 256 * 1_024

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
    private var editedRenderingColorRange: NSRange?
    private var wordDeletions: Set<NSRange> = []
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activity: NSTitlebarAccessoryViewController?
    private var generation = 0
    private var syntaxCoveredRange: NSRange?
    private var syntaxRequestedRange: NSRange?
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
    var syntaxCoveredRangeForCheck: NSRange? { syntaxCoveredRange }
    private(set) var zigImmediateUpdatesForCheck = 0
    var beforeInstallTreeTokensForCheck: (() async -> Void)?
    var beforeInstallSemanticTokensForCheck: (() async -> Void)?
    var expireForegroundParseForCheck = false
    var expireProjectedQueryForCheck = false
#endif

    init(editor: EditorTextView) {
        self.editor = editor
        editor.syntaxHighlighting = self
        editor.textLayoutManager?.renderingAttributesValidator = { [weak self] manager, fragment in
            self?.paint(fragment.rangeInElement, using: manager)
        }
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
            syntaxCoveredRange = nil
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
        if SyntaxEngine.supportsIncremental(language) {
            if treeLanguage != language {
                cancelPending()
                treeLanguage = language
                syntaxCoveredRange = nil
                if !keepingColors { displayTree([]) }
            }
            refreshSyntaxViewport()
            return
        }
        cancelPending()
        syntaxCoveredRange = nil
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

    func refreshSyntaxViewport() {
        guard treeSitterEnabled, let language = treeLanguage, SyntaxEngine.supportsIncremental(language),
              let editor, editor.syntaxLanguage == language, let text = editor.textStorage?.mutableString else { return }
        let document = NSRange(location: 0, length: text.length)
        let visible = NSIntersectionRange(visibleRange() ?? NSRange(location: 0, length: min(4_096, text.length)), document)
        guard visible.length > 0,
              syntaxCoveredRange.map({ NSIntersectionRange($0, visible) }) != visible,
              syntaxRequestedRange.map({ NSIntersectionRange($0, visible) }) != visible else { return }

        cancelPending()
        let start = max(0, visible.location - 512)
        let end = min(text.length, visible.upperBound + 512)
        let range = text.lineRange(for: NSRange(location: start, length: end - start))
        syntaxRequestedRange = range
        let request = generation
        let source = editor.string
        task = Task { [weak self, weak editor] in
            defer {
                if let self, self.generation == request {
                    self.task = nil
                    self.syntaxRequestedRange = nil
                    self.stopProgress()
                }
            }
            guard let editor, let tree = await editor.syntaxAnalysis.tree(in: source, language: language), !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) { tree.highlights(in: range) }
            let spans = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
#if EDIT_AGENT_CHECKS
            if spans != nil { await self?.beforeInstallTreeTokensForCheck?() }
#endif
            guard let self, !Task.isCancelled, self.generation == request, let spans else { return }
            if self.semanticSpansAreStale { self.discardOverriddenColors(in: &self.semanticSpans, with: spans) }
            self.treeSpansAreStale = false
            self.treeSpans = spans
            self.syntaxCoveredRange = range
            // Refresh the installed viewport. Scrolling will request its own slice of this tree.
            self.refreshColors()
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
        syntaxCoveredRange = nil
        treeSpans = []
        semanticSpans = []
        clearColors()
    }

    func install(_ snapshot: SyntaxSnapshot) {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        treeSitterEnabled = true
        treeLanguage = snapshot.language
        syntaxCoveredRange = snapshot.tree.map { NSRange(location: 0, length: $0.length) }
        semanticSpans = []
        displayTree(snapshot.analysis.spans)
        if snapshot.coversDocument, let editor {
            editor.syntaxAnalysis.install(snapshot.analysis, in: editor.string, language: snapshot.language, tree: snapshot.tree)
            if SyntaxEngine.supportsIncremental(snapshot.language) { refreshSyntaxViewport() }
        } else {
            updateTreeSitter(language: snapshot.language, immediate: true, keepingColors: true)
        }
    }

    func cancel(clearingColors: Bool = true) {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        syntaxCoveredRange = nil
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
        syntaxRequestedRange = nil
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
        if hasRenderingColors || !treeSpans.isEmpty || !semanticSpans.isEmpty {
            refreshColors()
        }
    }

    func refreshColors() {
        guard let editor, let manager = editor.textLayoutManager else { return }
        clearColors()
        let visible = manager.textViewportLayoutController.viewportRange
        if let visible {
            paint(visible, using: manager)
        } else {
            manager.invalidateRenderingAttributes(for: manager.documentRange)
        }

        // NSTextView can back each visible text fragment with a separate view.
        // An invalidation of the editor alone does not dirty those views.
        func invalidateVisibleViews(_ view: NSView) {
            let rect = view.visibleRect
            guard !rect.isEmpty else { return }
            view.setNeedsDisplay(rect)
            for child in view.subviews { invalidateVisibleViews(child) }
        }
        invalidateVisibleViews(editor)
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
        if let treeLanguage, SyntaxEngine.supportsIncremental(treeLanguage) {
            cancelPending()
            syntaxCoveredRange = nil
        }
        let edit = storage.editedRange
        let delta = storage.changeInLength
        let replacedLength = edit.length - delta
        guard edit.location != NSNotFound, edit.location <= storage.length,
              edit.length <= storage.length - edit.location, replacedLength >= 0 else {
            treeSpans = []
            semanticSpans = []
            return NSRange(location: 0, length: storage.length)
        }

        let edits = replacements?.map { EditorTextChange(range: $0.range, delta: $0.lengthChange) }
            ?? [EditorTextChange(range: NSRange(location: edit.location, length: replacedLength), delta: delta)]
        var invalidated = invalidatedColorRange(after: edits, lengthChange: delta)
        let firstEditRange = treeLanguage.flatMap { SyntaxEngine.supportsIncremental($0) ? edit : nil }
        if let visible = visibleRange() ?? firstEditRange {
            let typingText = editor?.hasMarkedText() == false && editor?.isRenamingSymbol == false
                ? storage.mutableString : nil
            let previousTree = treeSpans
            treeSpans = remappedSpans(treeSpans, in: visible, after: edits, typingText: typingText)
            semanticSpans = remappedSpans(semanticSpans, in: visible, after: edits, typingText: typingText)
            if let typingText {
                let updated: NSRange?
                if treeLanguage == .zig {
                    if edits.count == 1 {
                        updated = refreshZigEdit(edit, in: typingText) ?? refreshZigString(edit, in: typingText)
                            ?? refreshZigWord(after: edits[0], previous: previousTree, in: typingText)
                    } else {
                        updated = nil
                    }
                } else {
                    updated = refreshEditedViewport(edit, visible: visible, in: typingText)
                        ?? (edits.count == 1 ? refreshOdinQuote(edit, in: typingText) : nil)
                }
                if let range = updated ?? preserveEditedSyntax(edit, visible: visible, previous: previousTree,
                                                                edits: edits, in: typingText) {
                    invalidated = invalidated.map { NSUnionRange($0, range) } ?? range
                }
            }
        } else {
            treeSpans = []
            semanticSpans = []
        }
        return invalidated
    }

    private func refreshEditedViewport(_ edit: NSRange, visible: NSRange, in text: NSString) -> NSRange? {
        guard treeSitterEnabled, let language = treeLanguage, SyntaxEngine.supportsIncremental(language),
              let editor, editor.syntaxLanguage == language, text.length > 0,
              text.length <= Self.foregroundSyntaxSnapshotLimit else { return nil }
        let document = NSRange(location: 0, length: text.length)
        let range = text.lineRange(for: NSUnionRange(NSIntersectionRange(visible, document), edit))
        let source = editor.string
        let deadline: ContinuousClock.Instant
#if EDIT_AGENT_CHECKS
        deadline = expireForegroundParseForCheck ? .now : .now + .milliseconds(6)
#else
        deadline = .now + .milliseconds(6)
#endif
        let tree = editor.syntaxAnalysis.treeForEdit(in: source, language: language, length: text.length, deadline: deadline)
        guard let fresh = tree?.highlights(in: range, deadline: deadline) else { return nil }

        // All edited viewport colors come from the current tree, including tokens that span lines.
        // Retire a cached semantic color if it competes with the new syntax at the edit.
        let start = max(0, edit.location - 1)
        let touched = NSRange(location: start, length: min(edit.upperBound + 1, text.length) - start)
        let affected = Array(spans(overlapping: touched, from: treeSpans)) + spans(overlapping: touched, from: fresh)
        semanticSpans.removeAll { cached in
            affected.contains { NSIntersectionRange(cached.range, $0.range).length > 0 }
        }
        treeSpans = fresh
        treeSpansAreStale = false
        return range
    }

    private func refreshOdinQuote(_ edit: NSRange, in text: NSString) -> NSRange? {
        guard treeSitterEnabled, treeLanguage == .odin, editor?.syntaxLanguage == .odin,
              edit.location < text.length else { return nil }
        let line = LineEditing.line(at: edit.location, in: text).contentRange
        guard line.length <= 2_048, edit.upperBound <= line.upperBound,
              text.rangeOfCharacter(from: Self.odinQuotes, options: [], range: line).location != NSNotFound else { return nil }

        // Keep preceding lines for constructs such as proc followed by a comment and its convention.
        let lowerBound = max(0, line.upperBound - 2_048)
        var start = lowerBound == 0 ? 0 : text.lineRange(for: NSRange(location: lowerBound - 1, length: 1)).upperBound
        guard start <= line.location else { return nil }
        if let crossing = spans(overlapping: NSRange(location: start, length: 1), from: treeSpans).first,
           crossing.start < start {
            // A bounded parse must start outside a multiline comment or literal.
            guard crossing.end <= edit.location else { return nil }
            start = crossing.end
        }
        let fragment = NSRange(location: start, length: line.upperBound - start)
        let deadline = ContinuousClock.now + .milliseconds(4)
        guard let tree = SyntaxEngine.Tree(source: text.substring(with: fragment), language: .odin, previous: nil,
                                           deadline: deadline),
              let spans = tree.highlights(in: NSRange(location: 0, length: fragment.length), deadline: deadline),
              let literal = spans.first(where: {
                  ($0.color == .string || $0.color == .control) && $0.start <= edit.location - start
                      && $0.end >= max(edit.location - start + 1, edit.upperBound - start)
                      && Self.odinQuotes.contains(Unicode.Scalar(text.character(at: start + $0.start)) ?? " ")
              }) else { return nil }
        let fresh = SyntaxSpan(start: start + literal.start, end: start + literal.end, color: literal.color)
        let old = self.spans(overlapping: fresh.range, from: treeSpans)
        guard old.allSatisfy({ $0.start >= fresh.start && $0.end <= fresh.end }) else { return nil }
        treeSpans.replaceSubrange(old.startIndex..<old.endIndex, with: [fresh])
        return fresh.range
    }

    private func preserveEditedSyntax(_ edit: NSRange, visible: NSRange, previous: [SyntaxSpan],
                                      edits: [EditorTextChange], in text: NSString) -> NSRange? {
        guard treeSitterEnabled, let language = treeLanguage, SyntaxEngine.supportsIncremental(language),
              let editor, editor.syntaxLanguage == language, text.length > 0 else { return nil }
        let document = NSRange(location: 0, length: text.length)
        let affectedViewport = NSUnionRange(NSIntersectionRange(visible, document), edit)
        if language == .solidity {
            // A projected tree can leave the inserted prefix outside the token's capture.
            // Keep its paint on the entire surviving token until the fresh lexer can classify it.
            treeSpans = carryPreviousColors(previous, after: edits, solidityText: text)
            return affectedViewport
        }
        let deadline: ContinuousClock.Instant
#if EDIT_AGENT_CHECKS
        deadline = expireProjectedQueryForCheck ? .now : .now + .milliseconds(6)
#else
        deadline = .now + .milliseconds(6)
#endif
        // Apply the edit to the previous tree's positions while the new syntax is pending.
        if edits.count == 1, text.length <= Self.foregroundSyntaxSnapshotLimit, deadline > .now,
           let tree = editor.syntaxAnalysis.projectedTree(in: editor.string, language: language,
                                                          length: text.length, deadline: deadline) {
            let range = text.lineRange(for: affectedViewport)
            if let colors = tree.highlights(in: range, deadline: deadline) {
                treeSpans = colors
                return range
            }
        }
        // Keep paint for each individual edit when a query exceeds the budget or a batch would merge their ranges.
        treeSpans = carryPreviousColors(previous, after: edits)
        return affectedViewport
    }

    private func carryPreviousColors(_ previous: [SyntaxSpan], after edits: [EditorTextChange],
                                     solidityText: NSString? = nil) -> [SyntaxSpan] {
        // Work in the old coordinates. At an insertion between two spans, the preceding span owns the new text.
        var scan = 0
        var shift = 0
        var result: [SyntaxSpan] = []
        for span in previous {
            var leadingLength = 0
            while scan < edits.count, edits[scan].range.upperBound <= span.start {
                let edit = edits[scan]
                leadingLength = edit.range.upperBound == span.start ? edit.replacementLength : 0
                shift += edit.delta
                scan += 1
            }
            var start = span.start + shift
            var end = span.end + shift
            var localShift = shift
            for edit in edits[scan...] {
                if edit.range.location > span.end { break }
                let editStart = edit.range.location + localShift
                let replacementEnd = editStart + edit.replacementLength
                if edit.range.location == span.end {
                    if edit.range.length == 0 {
                        end = solidityText.map {
                            Self.solidityContinuationEnd(color: span.color, start: start, at: editStart,
                                                           limit: replacementEnd, in: $0)
                        } ?? replacementEnd
                    }
                    break
                }
                if edit.range.location <= span.start {
                    start = replacementEnd
                    leadingLength = edit.replacementLength
                }
                if edit.range.upperBound <= span.end {
                    end += edit.delta
                } else {
                    end = replacementEnd
                    break
                }
                localShift += edit.delta
            }
            if start < end {
                if let solidityText, leadingLength > 0, start - leadingLength >= (result.last?.end ?? 0),
                   Self.isSolidityTokenPrefix(from: start - leadingLength, to: start, color: span.color, in: solidityText) {
                    start -= leadingLength
                }
                result.append(SyntaxSpan(start: start, end: end, color: span.color, provisional: true))
            }
        }
        return result
    }

    private static func isSolidityTokenPrefix(from start: Int, to end: Int, color: SyntaxColor, in text: NSString) -> Bool {
        let next = text.character(at: end)
        switch color {
        case .number, .string:
            guard (48...57).contains(next) else { return false }
            return (start..<end).allSatisfy { (48...57).contains(text.character(at: $0)) }
                || (end == start + 1 && text.character(at: start) == 46)
        case .keyword, .control, .type, .function, .property:
            if color == .keyword, end == start + 1, !isSolidityIdentifierUnit(next) {
                return solidityCompoundOperators.contains(text.substring(with: NSRange(location: start, length: 2)))
            }
            return isSolidityIdentifierUnit(next) && (start..<end).allSatisfy { isSolidityIdentifierUnit(text.character(at: $0)) }
        default:
            return false
        }
    }

    private static func isSolidityIdentifierUnit(_ unit: UInt16) -> Bool { isWord(unit) || unit == 36 }

    private static func solidityContinuationEnd(color: SyntaxColor, start: Int, at boundary: Int, limit: Int,
                                                 in text: NSString) -> Int {
        guard start < boundary, boundary < limit else { return boundary }
        let inserted = NSRange(location: boundary, length: limit - boundary)
        switch color {
        case .comment:
            if boundary - start >= 2, text.character(at: start + 1) == 42 {
                if boundary - start >= 4, text.character(at: boundary - 2) == 42,
                   text.character(at: boundary - 1) == 47 { return boundary }
                let searchStart = max(start + 2, boundary - 1)
                let close = text.range(of: "*/", options: .literal, range: NSRange(location: searchStart, length: limit - searchStart))
                return close.location == NSNotFound ? limit : close.upperBound
            }
            let lineBreak = text.rangeOfCharacter(from: .newlines, range: inserted)
            return lineBreak.location == NSNotFound ? limit : lineBreak.location
        case .string where !(48...57).contains(text.character(at: start)):
            return solidityStringContinuationEnd(start: start, appended: inserted, in: text)
        default:
            break
        }

        let previous = text.character(at: boundary - 1)
        var end = boundary
        while end < limit {
            let next = text.character(at: end)
            let continues: Bool
            if color == .number || color == .string {
                continues = isSolidityIdentifierUnit(next) || next == 46
            } else if isSolidityIdentifierUnit(previous) {
                continues = isSolidityIdentifierUnit(next)
            } else {
                // Repeated operators and a compound assignment keep the operator color.
                continues = next == previous || next == 61
            }
            if !continues { break }
            end += 1
        }
        return end
    }

    private static func solidityStringContinuationEnd(start: Int, appended: NSRange, in text: NSString) -> Int {
        let boundary = appended.location
        // The opening quote is at the start of an ordinary string or just after a literal prefix.
        let opening = text.rangeOfCharacter(from: solidityQuotes, range: NSRange(location: start, length: min(16, boundary - start)))
        var end = boundary
        let quote: UInt16
        if opening.location != NSNotFound {
            quote = text.character(at: opening.location)
        } else {
            quote = text.character(at: boundary)
            guard quote == 34 || quote == 39 else { return boundary }
            end += 1
        }
        // A trailing backslash can escape a closing quote or the first appended character.
        var escapes = 0
        let lastWasQuote = text.character(at: boundary - 1) == quote
        var offset = boundary - (lastWasQuote ? 2 : 1)
        while offset >= start, text.character(at: offset) == 92 {
            escapes += 1
            offset -= 1
        }
        if lastWasQuote, opening.location < boundary - 1, escapes.isMultiple(of: 2) { return boundary }
        var escaped = !lastWasQuote && !escapes.isMultiple(of: 2)
        while end < appended.upperBound {
            let unit = text.character(at: end)
            if !escaped {
                if unit == quote { return end + 1 }
                if let scalar = Unicode.Scalar(unit), CharacterSet.newlines.contains(scalar) { return end }
            } else if unit == 13, end + 1 < appended.upperBound, text.character(at: end + 1) == 10 {
                end += 1
            }
            escaped = !escaped && unit == 92
            end += 1
        }
        return end
    }

    private func refreshZigEdit(_ edit: NSRange, in text: NSString) -> NSRange? {
#if EDIT_AGENT_CHECKS
        if expireForegroundParseForCheck { return nil }
#endif
        guard treeSitterEnabled, treeLanguage == .zig, let editor, editor.syntaxLanguage == .zig,
              text.length > 0, SyntaxEngine.supportsIncremental(.zig) else { return nil }
        let line = LineEditing.line(at: edit.location, in: text).contentRange
        guard edit.upperBound <= line.upperBound, line.length <= 2_048 else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(2)
        guard let tree = editor.syntaxAnalysis.treeForEdit(in: editor.string, language: .zig, length: text.length,
                                                          deadline: deadline),
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

    private func refreshZigString(_ edit: NSRange, in text: NSString) -> NSRange? {
        guard treeSitterEnabled, treeLanguage == .zig, editor?.syntaxLanguage == .zig else { return nil }
        let line = LineEditing.line(at: edit.location, in: text).contentRange
        // Ordinary Zig strings and their escapes have only line-local lexical context. Classify
        // the first quote and its body even while the whole-buffer parse is busy or over budget.
        guard edit.upperBound <= line.upperBound, line.length <= 2_048,
              text.range(of: "\"", options: .literal, range: line).location != NSNotFound,
              let analysis = SyntaxEngine.analysis(in: text.substring(with: line), language: .zig,
                                                   includesBrackets: false) else { return nil }
        let start = max(line.location, edit.location - 1) - line.location
        let end = min(line.upperBound, edit.upperBound + 1) - line.location
        let touched = NSRange(location: start, length: end - start)
        guard let span = analysis.spans.first(where: { $0.color == .string && NSIntersectionRange($0.range, touched).length > 0 }) else {
            return nil
        }
        let fresh = SyntaxSpan(start: span.start + line.location, end: span.end + line.location, color: .string)
        let old = spans(overlapping: fresh.range, from: treeSpans)
        guard old.allSatisfy({ $0.start >= fresh.start && $0.end <= fresh.end }) else { return nil }
        treeSpans.replaceSubrange(old.startIndex..<old.endIndex, with: [fresh])
        semanticSpans.removeAll { NSIntersectionRange($0.range, fresh.range).length > 0 }
        return fresh.range
    }

    private func refreshZigWord(after edit: EditorTextChange, previous: [SyntaxSpan], in text: NSString) -> NSRange? {
        guard let color = classifyZigWord(after: edit, previous: previous, in: text) else { return nil }
        let cached = spans(overlapping: color.range, from: treeSpans)
        guard cached.isEmpty || cached.first?.range == color.range else { return nil }
        treeSpans.replaceSubrange(cached.startIndex..<cached.endIndex, with: [color])
        semanticSpans.removeAll { NSIntersectionRange($0.range, color.range).length > 0 }
        return color.range
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

    func invalidateEditedColors(in affected: NSRange) {
        let range = NSIntersectionRange(affected, NSRange(location: 0, length: editor?.textStorage?.length ?? 0))
        guard range.length > 0 else { return }
        editedRenderingColorRange = editedRenderingColorRange.map { NSUnionRange($0, range) } ?? range
    }

    func refreshEditedRenderingColors() {
        guard let edited = editedRenderingColorRange, let editor, let storage = editor.textStorage,
              let manager = editor.textLayoutManager else { return }
        editedRenderingColorRange = nil
        let range = NSIntersectionRange(edited, NSRange(location: 0, length: storage.length))
        if range.length > 0, let target = editor.textRange(range, in: manager) {
            manager.invalidateRenderingAttributes(for: target)
            paint(target, using: manager)
            editor.setNeedsDisplay(editor.visibleRect)
        }
    }

    private func visibleRange() -> NSRange? {
        guard let editor, let manager = editor.textLayoutManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return nil }
        return editor.charRange(visible, in: manager)
    }

    func prepareForDrawing(_ fragment: NSTextLayoutFragment, using manager: NSTextLayoutManager) {
        refreshEditedRenderingColors()
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
        let origin = manager.documentRange.location
        let start = manager.offset(from: origin, to: range.location)
        let end = start + manager.offset(from: range.location, to: range.endLocation)
        guard start < end else { return }

        let visible = NSRange(location: start, length: end - start)
        // An already rendered fragment can retain the previous foreground. A
        // plain run has an explicit color even when both highlighting layers are off.
        if editor?.syntaxLanguage != .plainText {
            manager.addRenderingAttribute(.foregroundColor, value: NSColor.textColor, for: range)
            hasRenderingColors = true
        }
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
        // Semantic foregrounds override Tree-sitter foregrounds.
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
