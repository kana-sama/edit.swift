import AppKit

@MainActor
final class SyntaxHighlighting {
    private struct SemanticRequest: Equatable {
        let session: ObjectIdentifier
        let generation: Int
        let revision: Int
        let refresh: Int
    }

    private weak var editor: EditorTextView?
    private var spans: [SyntaxSpan] = []
    private var hasRenderingColors = false
    private var backedColorRange: NSRange?
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activity: NSTitlebarAccessoryViewController?
    private var generation = 0
    private var semanticRequest: SemanticRequest?
    private var lastSemanticColors: (request: SemanticRequest, spans: [SyntaxSpan])?
    private var semanticTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var usesTreeSitterWhileWaiting = true
#if EDIT_AGENT_CHECKS
    private(set) var usesLSPForCheck = false
    var spansForCheck: [SyntaxSpan] { spans }
    var beforeInstallSemanticTokensForCheck: (() async -> Void)?
#endif

    init(editor: EditorTextView) {
        self.editor = editor
        editor.syntaxHighlighting = self
    }

    deinit {
        semanticTask?.cancel()
        fallbackTask?.cancel()
    }

    func update(language: SyntaxLanguage, immediate: Bool, session: LanguageServerSession?) {
        if let editor { editor.syntaxAnalysis.cancelIfChanged(to: editor.string, language: language) }
        if let session {
            if usesTreeSitterWhileWaiting {
                updateTreeSitter(language: language, immediate: immediate, keepingColors: true)
            }
            requestSemanticTokens(from: session, language: language, immediate: immediate)
        } else {
            let keepingColors = semanticRequest != nil
            cancelSemanticTokens()
            if !immediate { lastSemanticColors = nil }
            updateTreeSitter(language: language, immediate: immediate, keepingColors: keepingColors)
        }
    }

    func updateSemanticSource(_ session: LanguageServerSession?, language: SyntaxLanguage, immediate: Bool = true) {
        if let session {
            requestSemanticTokens(from: session, language: language, immediate: immediate)
        } else if semanticRequest != nil {
            update(language: language, immediate: immediate, session: nil)
        }
    }

    private func requestSemanticTokens(from session: LanguageServerSession, language: SyntaxLanguage, immediate: Bool) {
        let request = SemanticRequest(session: ObjectIdentifier(session), generation: session.generation,
                                      revision: session.revision, refresh: session.semanticTokensRefresh)
        guard request != semanticRequest else { return }
        semanticRequest = request
        semanticTask?.cancel()
        if let cached = lastSemanticColors, cached.request == request {
            semanticTask = nil
            installSemanticColors(cached.spans, request: request)
            return
        }
        lastSemanticColors = nil

        if !usesTreeSitterWhileWaiting && fallbackTask == nil {
            // Start the deadline once, so continued typing cannot leave stale colors indefinitely.
            fallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.useTreeSitterWhileWaiting(language: language)
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
                if self?.usesTreeSitterWhileWaiting == false { self?.useTreeSitterWhileWaiting(language: language) }
                return
            }
            self?.installSemanticColors(spans, request: request)
            // SourceKit can answer the first Swift request with syntax alone while
            // loading build settings, without sending a refresh when they arrive.
            if immediate && language == .swift && !spans.contains(where: {
                $0.color == .type || $0.color == .function || $0.color == .property
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
        fallbackTask?.cancel()
        fallbackTask = nil
        cancelPending()
        usesTreeSitterWhileWaiting = false
        display(spans, semantic: true)
    }

    private func useTreeSitterWhileWaiting(language: SyntaxLanguage) {
        fallbackTask?.cancel()
        fallbackTask = nil
        usesTreeSitterWhileWaiting = true
        updateTreeSitter(language: language, immediate: true, keepingColors: true)
    }

    private func cancelSemanticTokens() {
        semanticTask?.cancel()
        semanticTask = nil
        semanticRequest = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        usesTreeSitterWhileWaiting = true
    }

    private func updateTreeSitter(language: SyntaxLanguage, immediate: Bool, keepingColors: Bool) {
        cancelPending()
        let request = generation
        if immediate && !keepingColors { display([]) }
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
                self.display(preview)
                self.stopProgress()
            }
            guard !Task.isCancelled else { return }
            let result = await job.task.value
            guard !Task.isCancelled, let self, self.generation == request else { return }
            if let result {
                self.display(result.spans)
            } else {
                self.display([])
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

    func prepareForBufferReplacement() {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        spans = []
#if EDIT_AGENT_CHECKS
        usesLSPForCheck = false
#endif
        clearColors()
        updateBackingColors(in: nil)
    }

    func install(_ snapshot: SyntaxSnapshot) {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        display(snapshot.analysis.spans)
        if snapshot.coversDocument, let editor {
            editor.syntaxAnalysis.install(snapshot.analysis, in: editor.string, language: snapshot.language)
        } else {
            updateTreeSitter(language: snapshot.language, immediate: true, keepingColors: true)
        }
    }

    func cancel(clearingColors: Bool = true) {
        cancelSemanticTokens()
        lastSemanticColors = nil
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        if clearingColors { display([]) }
    }

    private func cancelPending() {
        generation &+= 1
        task?.cancel()
        task = nil
        stopProgress()
    }

    private func display(_ result: [SyntaxSpan], semantic: Bool = false) {
#if EDIT_AGENT_CHECKS
        usesLSPForCheck = semantic
#endif
        let needsRedraw = hasRenderingColors || backedColorRange != nil || !result.isEmpty
        spans = result
        if needsRedraw { refreshColors() }
    }

    func refreshColors() {
        clearColors()
        guard let editor, let manager = editor.textLayoutManager else { return }
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

    func storageDidEdit(_ storage: NSTextStorage, replacements: [EditorTextEdit]?) {
        guard let backed = backedColorRange else {
            spans = []
            return
        }
        let edit = storage.editedRange
        let delta = storage.changeInLength
        let replacedLength = edit.length - delta
        guard edit.location != NSNotFound, edit.location <= storage.length,
              edit.length <= storage.length - edit.location, replacedLength >= 0 else {
            backedColorRange = NSRange(location: 0, length: storage.length)
            spans = []
            return
        }

        // Conflict overlays can repaint existing syntax before the next parse. Keep the
        // visible colors aligned with the surviving text without walking offscreen captures.
        if !spans.isEmpty {
            let edits = replacements?.map { (range: $0.range, delta: $0.text.utf16.count - $0.range.length) }
                ?? [(range: NSRange(location: edit.location, length: replacedLength), delta: delta)]
            remapSpans(in: backed, after: edits)
        }
        let beforeEnd = edit.location + replacedLength
        if beforeEnd < backed.location {
            backedColorRange = NSRange(location: backed.location + delta, length: backed.length)
        } else if edit.location <= backed.upperBound {
            // Edits touching the cached colors can inherit them across the replaced range.
            let start = min(backed.location, edit.location)
            let end = max(edit.upperBound, backed.upperBound + delta)
            backedColorRange = NSRange(location: start, length: end - start)
        }
    }

    private func remapSpans(in visible: NSRange, after edits: [(range: NSRange, delta: Int)]) {
        var mapped: [SyntaxSpan] = []
        var editIndex = 0
        var offset = 0
        for span in spans(overlapping: visible) {
            var start = span.start
            while editIndex < edits.count, edits[editIndex].range.location < span.end {
                let edit = edits[editIndex]
                if start < edit.range.location {
                    mapped.append(SyntaxSpan(start: start + offset, end: edit.range.location + offset, color: span.color))
                }
                start = max(start, edit.range.upperBound)
                if edit.range.upperBound > span.end { break }
                offset += edit.delta
                editIndex += 1
            }
            if start < span.end {
                mapped.append(SyntaxSpan(start: start + offset, end: span.end + offset, color: span.color))
            }
        }
        spans = mapped
    }

    private func updateBackingColors(in visible: NSRange?) {
        guard let editor, !editor.hasMarkedText(), let storage = editor.textStorage,
              let content = editor.textLayoutManager?.textContentManager else { return }
        let document = NSRange(location: 0, length: storage.length)
        let previous = backedColorRange.map { NSIntersectionRange($0, document) }
        let visible = visible.map { NSIntersectionRange($0, document) }
        let colors = visible.map { spans(overlapping: $0) } ?? []
        let conflictColors = visible.flatMap { editor.jjConflictDecorations?.foregrounds(in: $0) } ?? []
        let link = visible.flatMap { visible in editor.languageDefinitionLinkRange.map { NSIntersectionRange(visible, $0) } }
        guard (previous?.length ?? 0) > 0 || (visible?.length ?? 0) > 0 else {
            backedColorRange = nil
            return
        }
        var typingAttributes = editor.typingAttributes
        typingAttributes[.foregroundColor] = NSColor.textColor
        content.performEditingTransaction {
            storage.beginEditing()
            if let previous, previous.length > 0, previous != visible {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: previous)
            }
            if let visible, visible.length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: visible)
                for span in colors {
                    let range = NSIntersectionRange(visible, NSRange(location: span.start, length: span.end - span.start))
                    storage.addAttribute(.foregroundColor, value: span.color.nativeColor, range: range)
                }
                for (range, color) in conflictColors {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
                if let link, link.length > 0 {
                    storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: link)
                }
            }
            storage.endEditing()
        }
        editor.typingAttributes = typingAttributes
        backedColorRange = colors.isEmpty && conflictColors.isEmpty && (link?.length ?? 0) == 0 ? nil : visible
    }

    private func visibleRange() -> NSRange? {
        guard let editor, let manager = editor.textLayoutManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return nil }
        return editor.charRange(visible, in: manager)
    }

    func prepareForDrawing(_ fragment: NSTextLayoutFragment, using manager: NSTextLayoutManager) {
        paint(fragment.rangeInElement, using: manager)
    }

    private func clearColors() {
        guard hasRenderingColors else { return }
        hasRenderingColors = false
        if let manager = editor?.textLayoutManager {
            manager.removeRenderingAttribute(.foregroundColor, for: manager.documentRange)
            manager.removeRenderingAttribute(.underlineStyle, for: manager.documentRange)
        }
    }

    private func paint(_ range: NSTextRange, using manager: NSTextLayoutManager) {
        let link = editor?.languageDefinitionLinkRange
        guard !spans.isEmpty || editor?.jjConflictDecorations?.hasHighlights == true || link != nil else { return }
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
        for span in spans(overlapping: visible) {
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

    private func spans(overlapping range: NSRange) -> ArraySlice<SyntaxSpan> {
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
    private static let colors = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeNativeColor()) })

    var nativeColor: NSColor { Self.colors[self] ?? .textColor }

    var appearanceRGB: (dark: UInt32, light: UInt32) {
        switch self {
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
