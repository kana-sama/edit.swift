import AppKit

@MainActor
final class BracketNavigation {
    enum Command { case go, select }

    private weak var editor: EditorTextView?
    private var language = SyntaxLanguage.plainText
    private var scope: [NSRange]?
    private var model: BracketMatching?
    private var indexing: Task<Void, Never>?
    private var pending: (selections: [NSRange], commands: [Command])?
    private(set) var highlightRanges: [NSRange] = []
    private(set) var highlightFrames: [NSRect] = []

    init(editor: EditorTextView) { self.editor = editor }

    deinit { indexing?.cancel() }

    func setLanguage(_ language: SyntaxLanguage) {
        guard self.language != language else { return }
        self.language = language
        if let editor { editor.syntaxAnalysis.cancelIfChanged(to: editor.string, language: language) }
        reset()
        editor?.requestLineRefresh()
    }

    func reset() {
        indexing?.cancel()
        indexing = nil
        model = nil
        pending = nil
        clearHighlights()
    }

    func clearHighlights() {
        highlightRanges = []
        setHighlightFrames([])
    }

    func refresh() {
        guard let editor else { return }
        updateScope(editor.focusRanges)
        let selections = selections(in: editor)
        guard editor.hasBufferFocus, !editor.hasMarkedText(), selections.count <= 100,
              selections.contains(where: { $0.length == 0 }) else {
            clearHighlights()
            return
        }
        guard let model else {
            if (editor.textStorage?.length ?? 0) > 0 { indexText(in: editor, immediate: false) }
            return
        }
        var ranges: Set<NSRange> = []
        for selection in selections where selection.length == 0 {
            guard let pair = model.pair(at: selection.location) else { continue }
            ranges.insert(pair.opening)
            ranges.insert(pair.closing)
        }
        highlightRanges = MultiCaretEditing.ordered(Array(ranges))
        setHighlightFrames(editor.highlightRects(for: highlightRanges))
    }

    func draw(in dirtyRect: NSRect) {
        guard editor?.hasBufferFocus == true, !highlightFrames.isEmpty else { return }
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        for frame in highlightFrames where frame.intersects(dirtyRect) {
            frame.fill()
            NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    func run(_ command: Command) {
        guard let editor, editor.canNavigateBrackets else { return }
        updateScope(editor.focusRanges)
        if let model {
            apply(command, using: model, in: editor)
        } else {
            let selections = selections(in: editor)
            if pending?.selections == selections {
                pending?.commands.append(command)
            } else {
                pending = (selections, [command])
            }
            indexText(in: editor, immediate: true)
        }
    }

    private func updateScope(_ ranges: [NSRange]?) {
        if scope != ranges {
            scope = ranges
            reset()
        }
    }

    private func indexText(in editor: EditorTextView, immediate: Bool) {
        guard indexing == nil else { return }
        let language = language
        let scope = scope
        indexing = Task { [weak self, weak editor] in
            if !immediate { try? await Task.sleep(for: .milliseconds(50)) }
            guard !Task.isCancelled, let analysis = editor?.syntaxAnalysis, let source = editor?.string else { return }
            let context: BracketSyntax.Context
            if language == .plainText {
                context = .empty
            } else {
                let job = analysis.request(in: source, language: language)
                context = await job.task.value?.brackets ?? .empty
            }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) {
                return BracketMatching(text: Task.isCancelled ? "" : source, language: language,
                                       ignoredRanges: context.ignoredRanges, scope: scope,
                                       embeddedLanguages: context.embeddedLanguages.map { ($0.range, $0.language) })
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self, let editor else { return }
            self.indexing = nil
            guard editor.string == source, editor.focusRanges == scope else {
                self.pending = nil
                editor.requestLineRefresh()
                return
            }
            self.model = result
            let pending = self.pending
            self.pending = nil
            if let pending, pending.selections == self.selections(in: editor),
               editor.window?.firstResponder === editor, editor.canNavigateBrackets {
                for command in pending.commands { self.apply(command, using: result, in: editor) }
            }
            editor.requestLineRefresh()
        }
    }

    private func selections(in editor: EditorTextView) -> [NSRange] {
        if let scope = editor.focusRanges { return editor.focusedSelections(in: scope).map(\.extent) }
        return editor.caretSelections
    }

    private func apply(_ command: Command, using model: BracketMatching, in editor: EditorTextView) {
        let results = selections(in: editor).compactMap { range -> FocusNavigationSelection? in
            switch command {
            case .go:
                let target = model.jump(from: range.location)
                return FocusNavigationSelection(anchor: target, head: target)
            case .select:
                guard let result = model.selection(from: range.location) else { return nil }
                return FocusNavigationSelection(anchor: result.anchor, head: result.head)
            }
        }
        guard let primary = results.last else { return }
        if let scope = editor.focusRanges {
            editor.setFocusedSelections(results, in: scope)
        } else {
            let ranges = results.map(\.extent)
            var navigation: [NSRange: NSTextSelection] = [:]
            if let manager = editor.textLayoutManager {
                for range in MultiCaretEditing.merged(ranges) {
                    guard let direction = results.last(where: {
                        range.location <= $0.extent.location && $0.extent.upperBound <= range.upperBound
                    }),
                          let textRange = editor.textRange(range, in: manager) else { continue }
                    navigation[range] = NSTextSelection(range: textRange,
                        affinity: direction.head < direction.anchor ? .upstream : .downstream, granularity: .character)
                }
            }
            editor.setCaretSelections(ranges, navigation: navigation,
                                      primaryAffinity: primary.head < primary.anchor ? .upstream : .downstream)
        }
        editor.scrollRangeToVisible(NSRange(location: primary.head, length: 0))
    }

    private func setHighlightFrames(_ frames: [NSRect]) {
        guard frames != highlightFrames else { return }
        let redraw = highlightFrames + frames
        highlightFrames = frames
        guard let editor else { return }
        for frame in redraw { editor.setNeedsDisplay(frame.intersection(editor.visibleRect)) }
    }
}

extension EditorTextView {
    var canNavigateBrackets: Bool { isSelectable && !hasMarkedText() && (textStorage?.length ?? 0) > 0 }

    @objc func goToBracket(_ sender: Any?) { bracketNavigation.run(.go) }
    @objc func selectToBracket(_ sender: Any?) { bracketNavigation.run(.select) }

    func highlightRects(for ranges: [NSRange]) -> [NSRect] {
        guard !ranges.isEmpty, let manager = textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange else { return [] }
        let visible = charRange(viewport, in: manager)
        let origin = textContainerOrigin
        var frames: [NSRect] = []
        for range in ranges {
            let intersection = NSIntersectionRange(visible, range)
            guard intersection.length > 0, let segment = textRange(intersection, in: manager) else { continue }
            manager.enumerateTextSegments(in: segment, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if !rect.isEmpty, rect != frames.last { frames.append(rect) }
                return true
            }
        }
        return frames
    }
}
