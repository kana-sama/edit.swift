import AppKit

@MainActor
final class OccurrenceHighlighting {
    struct Session: Sendable {
        let query: String

        fileprivate var search: OccurrenceSearch.Query {
            OccurrenceSearch.Query(text: query, caseSensitive: true, wholeWord: false)
        }
    }

    private weak var editor: EditorTextView?
    private var language = SyntaxLanguage.plainText
    private var findSettings = FindSettings()
    private var occurrenceSession: Session?
    private var textSnapshot: String?
    private var wordTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var wordGeneration = 0
    private var selectionGeneration = 0
    private var wordRects: [NSRect] = []
    private var selectionRects: [NSRect] = []
    private var layingOut = false
    private(set) var wordRanges: [NSRange] = []
    private(set) var selectionRanges: [NSRange] = []

    init(editor: EditorTextView) {
        self.editor = editor
    }

    deinit {
        wordTask?.cancel()
        selectionTask?.cancel()
    }

    func selectionChanged(occurrenceSession: Session? = nil) {
        self.occurrenceSession = occurrenceSession
        guard let input = input() else {
            reset()
            return
        }
        refreshWords(input)
        refreshSelection(input)
    }

    func contentChanged() {
        occurrenceSession = nil
        textSnapshot = nil
        cancelWordQuery()
        wordRanges = []
        selectionRanges = []
        refreshSelection(input(), after: .milliseconds(300))
        layout()
    }

    func reset() {
        occurrenceSession = nil
        textSnapshot = nil
        cancelWordQuery()
        cancelSelectionQuery()
        wordRanges = []
        selectionRanges = []
        layout()
    }

    func focusChanged(_ focused: Bool) {
        if focused {
            refreshWords(input())
        } else {
            cancelWordQuery()
            wordRanges = []
            layout()
        }
    }

    func update(language: SyntaxLanguage) {
        guard self.language != language else { return }
        self.language = language
        wordRanges = []
        refreshWords(input())
        layout()
    }

    func update(findSettings: FindSettings) {
        let previous = self.findSettings
        self.findSettings = findSettings
        guard previous.visible != findSettings.visible || previous.options != findSettings.options
                || (findSettings.visible && previous.query != findSettings.query) else { return }
        refreshSelection(input())
    }

    private func input() -> OccurrenceSearch.Input? {
        guard let editor, !editor.hasMarkedText() else { return nil }
        let selections = editor.focusedSelectionGroups ?? editor.caretSelections.map { [$0] }
        guard let primary = selections.last?.first, primary.location != NSNotFound else { return nil }
        let text = textSnapshot ?? editor.string
        textSnapshot = text
        return OccurrenceSearch.Input(text: text, scopes: editor.focusRanges,
                                      selections: selections, activeEnd: editor.activeEnd(of: primary))
    }

    private func cancelWordQuery() {
        wordGeneration &+= 1
        wordTask?.cancel()
        wordTask = nil
    }

    private func cancelSelectionQuery() {
        selectionGeneration &+= 1
        selectionTask?.cancel()
        selectionTask = nil
    }

    private func refreshWords(_ input: OccurrenceSearch.Input?) {
        cancelWordQuery()
        guard let input else {
            wordRanges = []
            layout()
            return
        }
        if let group = input.selections.last, group.count == 1, let caret = group.first, caret.length == 0,
           wordRanges.contains(where: { $0.location <= caret.location && caret.location <= $0.upperBound }) {
            return
        }
        if !wordRanges.isEmpty {
            wordRanges = []
            layout()
        }
        let generation = wordGeneration
        let language = self.language
        wordTask = Task.detached(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            let ranges = input.wordMatches(language: language)
            if !Task.isCancelled { await self?.applyWords(ranges, generation: generation) }
        }
    }

    private func refreshSelection(_ input: OccurrenceSearch.Input?, after delay: Duration = .zero) {
        cancelSelectionQuery()
        guard let input, let primary = input.selections.last, primary.count == 1,
              let selection = primary.first, selection.length > 0 else {
            selectionRanges = []
            layout()
            return
        }
        let generation = selectionGeneration
        let find = findSettings
        let session = occurrenceSession?.search
        selectionTask = Task.detached(priority: .userInitiated) { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            let ranges = input.selectionMatches(find: find, session: session)
            if !Task.isCancelled { await self?.applySelection(ranges, generation: generation) }
        }
    }

    private func applyWords(_ ranges: [NSRange], generation: Int) {
        guard generation == wordGeneration else { return }
        wordTask = nil
        wordRanges = ranges
        layout()
    }

    private func applySelection(_ ranges: [NSRange], generation: Int) {
        guard generation == selectionGeneration else { return }
        selectionTask = nil
        selectionRanges = ranges
        layout()
    }

    func layout() {
        guard let editor, !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        setRects(words: editor.highlightRects(for: wordRanges),
                 selections: editor.highlightRects(for: selectionRanges), in: editor)
    }

    private func setRects(words: [NSRect], selections: [NSRect], in editor: EditorTextView) {
        guard wordRects != words || selectionRects != selections else { return }
        let changed = (wordRects + selectionRects + words + selections).reduce(NSRect.null) { $0.union($1) }
        wordRects = words
        selectionRects = selections
        if !changed.isNull { editor.setNeedsDisplay(changed) }
    }

    func draw(in dirtyRect: NSRect) {
        if !wordRects.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.17).setFill()
            for rect in wordRects where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
        }
        if !selectionRects.isEmpty {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.44).setFill()
            for rect in selectionRects where rect.intersects(dirtyRect) { rect.intersection(dirtyRect).fill() }
        }
    }
}
