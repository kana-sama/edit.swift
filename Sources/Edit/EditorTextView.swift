import AppKit

// The native input client displays one primary preview. The original selections
// and attributed text are the baseline for the eventual editor transaction.
private struct MultiCaretComposition {
    let selections: [NSRange]
    let original: NSAttributedString
    var preview: NSRange
    var focusedRanges: EditorFocusSession.Snapshot? = nil
    var focusedGroups: [[NSRange]]? = nil
    var focusedPrimaryEnd: Int? = nil

    func contains(_ range: NSRange) -> Bool {
        range.location >= preview.location && range.location <= NSMaxRange(preview)
            && range.length <= NSMaxRange(preview) - range.location
    }

    func restoreRange(_ range: NSRange) -> NSRange {
        guard range.location != NSNotFound else { return range }
        func restore(_ offset: Int, trailing: Bool) -> Int {
            if offset < preview.location { return offset }
            if offset >= NSMaxRange(preview) { return offset + original.length - preview.length }
            return preview.location + (trailing ? original.length : 0)
        }
        let start = restore(range.location, trailing: false)
        let end = restore(NSMaxRange(range), trailing: range.length > 0)
        return NSRange(location: start, length: max(0, end - start))
    }
}

@MainActor
private struct EditorRenameDraft {
    var range: NSRange
    let source: String
    let original: NSAttributedString
    let selection: NSRange
    let affinity: NSSelectionAffinity
    let focus: EditorFocusSession.Snapshot?
    let undoManager = UndoManager()
    var isSubmitted = false

    func contains(_ range: NSRange) -> Bool {
        range.location >= self.range.location && range.location <= self.range.upperBound &&
            range.length <= self.range.upperBound - range.location
    }
}

final class EditorTextView: NSTextView, NSTextViewDelegate {
    static let linePasteType = NSPasteboard.PasteboardType("dev.edit-swift.whole-line")
    private static let defaultFontSize: CGFloat = 12
    static let defaultFont = codeFont(ofSize: defaultFontSize)
    private var fontSize = EditorTextView.defaultFontSize
    private(set) var wrapsWords = false
    private let currentLineHighlight = CurrentLineHighlight()
    private var lineRefreshPending = false
    let multiCaret = MultiCaretState()
    private weak var observedWindow: NSWindow?
    private var multiCaretComposition: MultiCaretComposition?
    private var updatingComposition = false
    var editorUndoManager = EditorUndoManager()
    var focusSession: EditorFocusSession?
    var focusDecoration: FocusDecoration?
    var focusEditsAllowed = false
    var onFocusScopeChange: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onNavigationSelectionChange: (() -> Void)?
    var onNavigationTextEdit: ((NSRange) -> Void)?
    var onJJCompositionChange: (() -> Void)?
    var onConflictSelectionChange: (() -> Void)?
    var conflictEdits: [JJConflictEdit] = []
    var replacingConflictStructure = false
    var onBlur: (() -> Void)?
    var onFindEditorInteraction: (() -> Void)?
    var onFindViewportChange: (() -> Void)?
    var onDrawFindHighlights: ((NSRect) -> Void)?
    var onBufferEdit: ((NSTextStorage, [EditorTextEdit]?) -> Void)?
    private var applyingTextEdits: [EditorTextEdit]?
    lazy var layoutSpacing = EditorLayoutSpacing(editor: self)
    fileprivate var jjDecorations: JJEditorDecorations?
    private(set) var jjConflictDecorations: JJConflictDecorations?
    private(set) var jjInlineDiff: JJInlineDiff?
    weak var syntaxHighlighting: SyntaxHighlighting?
    let syntaxAnalysis = EditorSyntaxAnalysis()
    lazy var bracketNavigation = BracketNavigation(editor: self)
    lazy var occurrenceHighlighting = OccurrenceHighlighting(editor: self)
    private lazy var languageInteraction = EditorLanguageInteraction(editor: self)
    var languageAssistance: EditorLanguageAssistance?
    private var isTypingForLanguageAssistance = false
    private var languageTrackingArea: NSTrackingArea?
    var languageProbe: ((Int, NSRange) async -> NSRange?)?
    var languageHover: ((Int, NSRange) async -> EditorLanguageHover?)?
    var languageFollowLink: ((Int, NSRange) -> Void)?
    var languageFollowHoverLink: ((LSPLocation, NSRange) -> Void)?
    var onRenameSymbol: (() -> Bool)?
    var onCancelSymbolRename: (() -> Bool)?
    var onSubmitSymbolRename: (() -> Void)?
    var isRenamingSymbol = false
    private var renameDraft: EditorRenameDraft?
    private var renameShade: EditorRenameShade?
    var renameRange: NSRange? { renameDraft?.range }
    // The editor lays out the draft. File and language services read the underlying source.
    var sourceString: String { renameDraft?.source ?? string }
    var languageContextItems: ((EditorLanguageInteraction.Hit) -> [NSMenuItem])?
    var languageInteractionEnabled = false {
        didSet {
            guard languageInteractionEnabled != oldValue else { return }
            languageInteraction.setEnabled(languageInteractionEnabled)
            updateTrackingAreas()
        }
    }
    var markdownLink: ((Int, Bool) -> Bool)?
    private var pointsAtMarkdownLink = false
    private var markdownToolTipLinks: [MarkdownDocument.Link] = []
    private struct MarkdownToolTip: Equatable {
        let rect: NSRect
        let label: NSString
    }
    private var markdownToolTips: [MarkdownToolTip] = []
    private var markdownToolTipTags: [NSView.ToolTipTag] = []
    var languageDefinitionLinkRange: NSRange? { languageInteractionEnabled ? languageInteraction.linkRange : nil }
    var preferredLineEnding = "\n"
    var syntaxLanguage: SyntaxLanguage = .plainText

    var hasBufferFocus: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    override var shouldDrawInsertionPoint: Bool { hasBufferFocus && super.shouldDrawInsertionPoint }


    private static func codeFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func scrollingEditor(in frame: NSRect) -> (NSScrollView, EditorTextView) {
        let scrollView = EditorScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.backgroundColor = .textBackgroundColor

        let editor = EditorTextView(usingTextLayoutManager: true)
        if let layout = editor.textLayoutManager {
            layout.textSelectionNavigation = EditorWordNavigation(dataSource: layout)
        }
        editor.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width, .height]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.size = editor.maxSize
        editor.textContainerInset = NSSize(width: 7, height: 8)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        editor.currentLineHighlight.wantsLayer = true
        editor.currentLineHighlight.setAccessibilityElement(false)
        editor.addSubview(editor.currentLineHighlight, positioned: .below, relativeTo: nil)
        // Keep AppKit’s selection background and leave syntax colors on the glyphs.
        editor.selectedTextAttributes.removeValue(forKey: .foregroundColor)
        editor.insertionPointColor = .textColor
        editor.delegate = editor
        if let storage = editor.textStorage {
            NotificationCenter.default.addObserver(editor, selector: #selector(storageDidEdit(_:)),
                                                   name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        editor.setFontSize(defaultFontSize)
        scrollView.documentView = editor
        return (scrollView, editor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        let events = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        if let previous = observedWindow {
            for event in events { center.removeObserver(self, name: event, object: previous) }
        }
        observedWindow = window
        if let window {
            for event in events {
                center.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: event, object: window)
            }
        }
        windowFocusChanged(nil)
    }

    @objc private func windowFocusChanged(_ notification: NSNotification?) {
        hideCaretDecorations()
        let focused = hasBufferFocus
        if !focused {
            if renameDraft != nil { _ = onCancelSymbolRename?() }
            if notification?.name == NSWindow.didResignKeyNotification { languageAssistance?.dismiss() }
            setCurrentLine(.zero)
            bracketNavigation.clearHighlights()
        }
        if languageInteractionEnabled { languageInteraction.keyWindowChanged() }
        occurrenceHighlighting.focusChanged(focused)
        requestLineRefresh()
    }

    override func viewDidEndLiveResize() {
        // TextKit may reveal its selection when a window or a split view finishes resizing.
        if let scroll = enclosingScrollView as? EditorScrollView {
            scroll.preserveViewport { super.viewDidEndLiveResize() }
        } else {
            super.viewDidEndLiveResize()
        }
    }

    override func setFrameSize(_ size: NSSize) {
        // An unwrapped annotation is part of the scroll extent, outside TextKit's layout.
        super.setFrameSize(NSSize(width: max(size.width, diagnosticMinimumWidth), height: size.height))
    }

    override var undoManager: UndoManager? { renameDraft?.undoManager ?? editorUndoManager }

    func beginSymbolRename(in range: NSRange, source: String) -> Bool {
        guard renameDraft == nil, let storage = textStorage, range.length > 0,
              range.upperBound <= storage.length, window?.firstResponder === self else { return false }
        breakUndoCoalescing()
        renameDraft = EditorRenameDraft(range: range, source: source, original: storage.attributedSubstring(from: range),
                                        selection: selectedRange(), affinity: selectionAffinity, focus: captureFocusSnapshot())
        occurrenceHighlighting.reset()
        bracketNavigation.clearHighlights()
        setSelectedRange(range)
        scrollRangeToVisible(range)
        window?.layoutIfNeeded()
        textLayoutManager?.textViewportLayoutController.layoutViewport()

        let shade = EditorRenameShade(editor: self)
        renameShade = shade
        addSubview(shade, positioned: .above, relativeTo: nil)
        shade.update()
        return true
    }

    var symbolRenameText: String? {
        guard let range = renameRange, let storage = textStorage, range.upperBound <= storage.length else { return nil }
        return storage.mutableString.substring(with: range)
    }

    func lockSymbolRename() -> Bool {
        guard renameDraft?.isSubmitted == false else { return false }
        renameDraft?.isSubmitted = true
        renameDraft?.undoManager.removeAllActions()
        return true
    }

    func focusAllowsSourceEdits(_ ranges: [NSRange]) -> Bool {
        focusAllowsEdits(ranges, in: renameDraft?.focus)
    }

    func endSymbolRename() {
        guard let draft = renameDraft else { return }
        withTransientComposition {
            if hasMarkedText() {
                super.unmarkText()
                inputContext?.discardMarkedText()
            }
            if let focus = draft.focus { focusSession?.restore(focus) }
            if let storage = textStorage, draft.range.upperBound <= storage.length,
               !storage.mutableString.substring(with: draft.range).utf8.elementsEqual(draft.original.string.utf8) {
                storage.replaceCharacters(in: draft.range, with: draft.original)
            }
            setSelectedRange(draft.selection, affinity: draft.affinity, stillSelecting: false)
        }
        renameDraft = nil
        renameShade?.removeFromSuperview()
        renameShade = nil
        occurrenceHighlighting.selectionChanged()
        requestLineRefresh()
    }

    private func allowsRenameEdit(_ range: NSRange, _ replacement: String?, in draft: EditorRenameDraft) -> Bool {
        !draft.isSubmitted && draft.contains(range) && replacement?.rangeOfCharacter(from: .newlines) == nil
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let draft = renameDraft {
            guard replacementString == nil || allowsRenameEdit(affectedCharRange, replacementString, in: draft) else { return false }
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }
        guard focusSession == nil || focusEditsAllowed || replacementString == nil else { return false }
        guard replacementString == nil || allowsProjectedChange(in: affectedCharRange) else { return false }
        if let replacementString, !allowsConflictEdit(in: affectedCharRange, replacement: replacementString) { return false }
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, let replacementString {
            syntaxHighlighting?.prepareForDeletions(in: replacementString.isEmpty ? [affectedCharRange] : [])
        }
        return allowed
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if let draft = renameDraft {
            if let replacementStrings {
                guard affectedRanges.count == 1, replacementStrings.count == 1,
                      allowsRenameEdit(affectedRanges[0].rangeValue, replacementStrings[0], in: draft) else { return false }
            }
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        guard focusSession == nil || focusEditsAllowed || replacementStrings == nil else { return false }
        guard replacementStrings == nil || affectedRanges.allSatisfy({ allowsProjectedChange(in: $0.rangeValue) }) else { return false }
        if let replacementStrings {
            guard affectedRanges.count == replacementStrings.count,
                  zip(affectedRanges, replacementStrings).allSatisfy({
                      allowsConflictEdit(in: $0.0.rangeValue, replacement: $0.1)
                  }) else { return false }
        }
        let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if allowed, let replacementStrings {
            syntaxHighlighting?.prepareForDeletions(in: zip(affectedRanges, replacementStrings).compactMap { range, replacement in
                replacement.isEmpty ? range.rangeValue : nil
            })
        }
        return allowed
    }

    private func allowsConflictEdit(in range: NSRange, replacement: String) -> Bool {
        guard !replacingConflictStructure, !updatingComposition, !conflictEdits.isEmpty else { return true }
        guard let source = textStorage?.mutableString, range.location <= source.length,
              range.length <= source.length - range.location else { return false }
        return conflictEdits.allSatisfy { $0.allows(range, replacement: replacement, in: source) }
    }

    override func selectAll(_ sender: Any?) {
        if let renameRange { setSelectedRange(renameRange); return }
        if !selectFocusedText(), jjInlineDiff?.handleSelectionCommand(#selector(selectAll(_:))) != true {
            super.selectAll(sender)
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        // AppKit assigns the window's first responder after this callback returns.
        Task { [weak self] in
            guard let self, hasBufferFocus else { return }
            occurrenceHighlighting.focusChanged(true)
        }
        requestLineRefresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        if renameDraft != nil { _ = onCancelSymbolRename?() }
        languageAssistance?.dismiss()
        multiCaret.pendingSkip = false
        if multiCaretComposition != nil { unmarkText() }
        hideCaretDecorations()
        setCurrentLine(.zero)
        bracketNavigation.clearHighlights()
        occurrenceHighlighting.focusChanged(false)
        onBlur?()
        return true
    }

    override func insertTab(_ sender: Any?) {
        if renameDraft != nil { return }
        guard prepareProjectedLineCommand() else { return }
        if editMultipleLines(.tab) { return }
        guard !hasMarkedText(), let text = textStorage?.mutableString else {
            super.insertTab(sender)
            return
        }
        let selection = selectedRange()
        if selection.length == 0 {
            replace(selection, with: "    ", coalesce: true)
        } else {
            apply(LineEditing.indent(text, selection: selection, outdent: false))
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if renameDraft != nil { return }
        guard !hasMarkedText() else {
            super.insertBacktab(sender)
            return
        }
        outdentLines(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if renameDraft != nil {
            if hasMarkedText() { super.insertNewline(sender) }
            else { onSubmitSymbolRename?() }
            return
        }
        guard prepareProjectedLineCommand() else { return }
        if editMultipleLines(.newline) { return }
        guard !hasMarkedText(), let text = textStorage?.mutableString else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let start = LineEditing.line(at: selection.location, in: text).start
        var end = start
        while end < selection.location {
            let character = text.character(at: end)
            guard character == 32 || character == 9 else { break }
            end += 1
        }
        let indent = text.substring(with: NSRange(location: start, length: end - start))
        replace(selection, with: preferredLineEnding + indent, coalesce: true)
    }

    @objc func indentLines(_ sender: Any?) {
        guard prepareProjectedLineCommand() else { return }
        if editMultipleLines(.indent(outdent: false)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.indent(text, selection: selectedRange(), outdent: false))
    }

    @objc func toggleLineComments(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let prefix = syntaxLanguage.lineCommentPrefix,
              prepareProjectedLineCommand(), let text = textStorage?.mutableString else { return }
        let selections = caretSelections
        let edits = MultiCaretEditing.toggleLineComments(in: text, for: selections, prefix: prefix)
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(selections, after: edits),
                        actionName: "Toggle Line Comments")
    }

    @objc func outdentLines(_ sender: Any?) {
        guard prepareProjectedLineCommand() else { return }
        if editMultipleLines(.indent(outdent: true)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.indent(text, selection: selectedRange(), outdent: true))
    }

    @objc func moveLinesUp(_ sender: Any?) {
        moveLines(up: true)
    }

    @objc func moveLinesDown(_ sender: Any?) {
        moveLines(up: false)
    }

    private func moveLines(up: Bool) {
        guard !hasMarkedText(), prepareProjectedLineCommand() else { return }
        if editMultipleLines(.move(up: up)) { return }
        guard let text = textStorage?.mutableString,
              let move = LineEditing.moveLines(text, selection: selectedRange(), up: up) else { return }
        applyMultiEdits([EditorTextEdit(range: move.range, text: move.replacement)], selections: [move.selection])
    }

    @objc func insertLineAbove(_ sender: Any?) {
        guard prepareProjectedLineCommand() else { return }
        if editMultipleLines(.insert(above: true)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.insertLine(text, selection: selectedRange(), above: true))
    }

    @objc func insertLineBelow(_ sender: Any?) {
        guard prepareProjectedLineCommand() else { return }
        if editMultipleLines(.insert(above: false)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.insertLine(text, selection: selectedRange(), above: false))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Cut", #selector(cut(_:))), ("Copy", #selector(copy(_:))),
                                ("Paste", #selector(paste(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if languageInteractionEnabled, let hit = languageInteraction.hit(at: event.locationInWindow),
           let items = languageContextItems?(hit), !items.isEmpty {
            menu.addItem(.separator())
            items.forEach(menu.addItem)
        }
        return menu
    }

    override func copy(_ sender: Any?) {
        if renameDraft != nil { super.copy(sender); return }
        if jjInlineDiff?.copyProjectedSelection(to: .general, cutting: false) == true { return }
        if copySelections(to: .general, cutting: false) { return }
        if selectedRange().length > 0 {
            super.copy(sender)
        } else {
            copyLine(to: .general, cutting: false)
        }
    }

    override func cut(_ sender: Any?) {
        if renameDraft != nil { super.cut(sender); return }
        if jjInlineDiff?.copyProjectedSelection(to: .general, cutting: true) == true { return }
        if copySelections(to: .general, cutting: true) { return }
        if selectedRange().length > 0 {
            super.cut(sender)
        } else {
            copyLine(to: .general, cutting: true)
        }
    }

    override func paste(_ sender: Any?) {
        if renameDraft != nil { super.pasteAsPlainText(sender); return }
        if jjInlineDiff?.projectedEditRange != nil {
            _ = replaceProjectedSelection(with: NSPasteboard.general.string(forType: .string))
            return
        }
        if pasteIntoEmptyConflictSnapshot() { return }
        if !pasteAtCarets(from: .general) && !pasteLine(from: .general) {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if jjInlineDiff?.projectedEditRange != nil { paste(sender) }
        else if !pasteIntoEmptyConflictSnapshot() { super.pasteAsPlainText(sender) }
    }

    override func pasteAsRichText(_ sender: Any?) {
        if jjInlineDiff?.projectedEditRange != nil { paste(sender) }
        else if !pasteIntoEmptyConflictSnapshot() { super.pasteAsRichText(sender) }
    }

    func copyLine(to pasteboard: NSPasteboard, cutting: Bool) {
        guard let text = textStorage?.mutableString, text.length > 0, !hasMarkedText(),
              !cutting || isEditable else { return }
        let caret = selectedRange().location
        let line = LineEditing.line(at: caret, in: text)
        let contents = text.substring(with: NSRange(location: line.start, length: line.end - line.start))
        let completeLine = line.end == line.contentEnd ? contents + preferredLineEnding : contents
        pasteboard.declareTypes([.string, Self.linePasteType], owner: nil)
        pasteboard.setString(completeLine, forType: .string)
        pasteboard.setString(completeLine, forType: Self.linePasteType)

        if cutting {
            // When cutting the final unterminated line, remove its preceding line break.
            let start = line.end == line.contentEnd && line.start > 0
                ? LineEditing.line(at: line.start - 1, in: text).contentEnd
                : line.start
            replace(NSRange(location: start, length: line.end - start), with: "")
        }
    }

    @discardableResult
    func pasteLine(from pasteboard: NSPasteboard) -> Bool {
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              let contents = pasteboard.string(forType: Self.linePasteType),
              let text = textStorage?.mutableString else { return false }
        let start = LineEditing.line(at: selection.location, in: text).start
        replace(NSRange(location: start, length: 0), with: contents)
        return true
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        if replaceProjectedSelection(with: "") { return }
        if editMultipleLines(.deleteLineBoundary(backward: true)) { return }
        guard !hasMarkedText(), let text = textStorage?.mutableString else {
            super.deleteToBeginningOfLine(sender)
            return
        }
        let selection = selectedRange()
        let start = LineEditing.line(at: selection.location, in: text).start
        let lowerBound = selection.length == 0 && start == selection.location && start > 0
            ? LineEditing.line(at: start - 1, in: text).contentEnd
            : start
        replace(NSRange(location: lowerBound, length: NSMaxRange(selection) - lowerBound), with: "")
    }

    override func deleteToEndOfLine(_ sender: Any?) {
        if replaceProjectedSelection(with: "") { return }
        if editMultipleLines(.deleteLineBoundary(backward: false)) { return }
        guard !hasMarkedText(), let text = textStorage?.mutableString else {
            super.deleteToEndOfLine(sender)
            return
        }
        let selection = selectedRange()
        let line = LineEditing.line(at: selection.location, in: text)
        let end = selection.length == 0 && selection.location == line.contentEnd
            ? line.end
            : max(NSMaxRange(selection), line.contentEnd)
        replace(NSRange(location: selection.location, length: end - selection.location), with: "")
    }

    override func mouseDown(with event: NSEvent) {
        languageAssistance?.dismiss()
        if let draft = renameDraft {
            let point = convert(event.locationInWindow, from: nil)
            let offset = characterIndexForInsertion(at: point)
            if draft.contains(NSRange(location: offset, length: 0)),
               highlightRects(for: [draft.range]).contains(where: { $0.contains(point) }) {
                super.mouseDown(with: event)
                return
            }
            _ = onCancelSymbolRename?()
        }
        if markdownLink(at: event.locationInWindow, modifiers: event.modifierFlags, activate: true) { return }
        if languageInteractionEnabled, languageInteraction.followClick(event) { return }
        onFindEditorInteraction?()
        if let focusSession, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if !focusSession.contains(NSRange(location: offset, length: 0)) { exitFocus() }
        }
        if addCaret(at: event) { return }
        multiCaret.pendingSkip = false
        if jjInlineDiff?.handleMouseDown(event) == true { return }
        jjInlineDiff?.clearProjectedSelection()
        super.mouseDown(with: event)
        if focusSession == nil && hasSecondarySelections { keepPrimarySelection(nil) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if updatingComposition || renameDraft != nil {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if jjInlineDiff?.projectedEditRange != nil {
            _ = replaceProjectedSelection(with: (string as? String) ?? (string as? NSAttributedString)?.string)
            return
        }
        if let composition = multiCaretComposition {
            let target = replacementRange.location == NSNotFound ? markedRange() : replacementRange
            if composition.contains(target),
               let preview = textStorage?.attributedSubstring(from: composition.preview).string,
               let final = (string as? String) ?? (string as? NSAttributedString)?.string {
                let relative = NSRange(location: target.location - composition.preview.location,
                                       length: target.length)
                commitMultiCaretComposition((preview as NSString).replacingCharacters(in: relative, with: final))
                return
            }
            // A replacement outside the marked preview is a primary-only action.
            let restoredRange = composition.restoreRange(replacementRange)
            discardMultiCaretComposition()
            keepPrimarySelection(nil)
            if focusSession != nil {
                _ = insertAtCarets(string, replacementRange: restoredRange)
            } else {
                super.insertText(string, replacementRange: restoredRange)
            }
            return
        }
        if let plainText = (string as? String) ?? (string as? NSAttributedString)?.string,
           insertInEmptyConflictSnapshot(plainText, at: replacementRange.location == NSNotFound ? selectedRange() : replacementRange) {
            return
        }
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        let character = typed.flatMap { $0.count == 1 && $0 != "\n" && $0 != "\r" && $0 != "\t" ? $0 : nil }
        trackLanguageTyping(character, enabled: character != nil) {
            if !insertAtCarets(string, replacementRange: replacementRange) {
                if focusSession != nil { return }
                if hasSecondarySelections { keepPrimarySelection(nil) }
                super.insertText(string, replacementRange: replacementRange)
            }
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        languageAssistance?.dismiss()
        if renameDraft?.isSubmitted == true { return }
        guard !updatingComposition, renameDraft == nil else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        let preview = (string as? String) ?? (string as? NSAttributedString)?.string
        if let diff = jjInlineDiff, let projected = diff.projectedEditRange {
            guard isEditable, projected.length > 0, focusAllowsEdits([projected]), preview?.isEmpty == false else { return }
            diff.clearProjectedSelection()
            setMarkedText(string, selectedRange: selectedRange, replacementRange: projected)
            return
        }
        if preview?.isEmpty == true, multiCaretComposition != nil {
            discardMultiCaretComposition()
            return
        }

        if let composition = multiCaretComposition, replacementRange.location != NSNotFound,
           !composition.contains(replacementRange) {
            let restoredRange = composition.restoreRange(replacementRange)
            discardMultiCaretComposition()
            keepPrimarySelection(nil)
            if focusSession != nil {
                setMarkedText(string, selectedRange: selectedRange, replacementRange: restoredRange)
            } else {
                super.setMarkedText(string, selectedRange: selectedRange, replacementRange: restoredRange)
            }
            return
        }

        if multiCaretComposition == nil, hasSecondarySelections || focusSession != nil || !conflictEdits.isEmpty,
           let primary = caretSelections.last {
            let explicit = replacementRange.location != NSNotFound && replacementRange != primary
            let tracked = !conflictEdits.isEmpty
            let target = explicit && (focusSession != nil || tracked) ? replacementRange : primary
            guard focusAllowsEdits([target]), allowsConflictEdit(in: target, replacement: preview ?? "") else { return }
            let selections = explicit && (focusSession != nil || tracked) ? [target] : caretSelections
            let groups = explicit ? nil : focusedSelectionGroups
            let activeEnd = activeEnd(of: target)
            setCaretSelections([target], record: false)
            if isEditable, preview?.isEmpty == false, let storage = textStorage,
               !explicit || focusSession != nil || tracked {
                breakUndoCoalescing()
                multiCaretComposition = MultiCaretComposition(
                    selections: selections, original: storage.attributedSubstring(from: target), preview: target,
                    focusedRanges: captureFocusSnapshot(), focusedGroups: groups, focusedPrimaryEnd: activeEnd
                )
            }
        }

        guard let composition = multiCaretComposition, let storage = textStorage else {
            if focusSession != nil { return }
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        let oldLength = storage.length
        let target = replacementRange.location == NSNotFound ? composition.preview : replacementRange
        if let snapshot = composition.focusedRanges, let preview {
            updateMarkedFocus(snapshot, composition: composition,
                              length: composition.preview.length - target.length + preview.utf16.count)
        }
        withTransientComposition {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        multiCaretComposition?.preview.length += storage.length - oldLength
        if let snapshot = composition.focusedRanges, let marked = multiCaretComposition, marked.preview.length >= 0 {
            updateMarkedFocus(snapshot, composition: marked, length: marked.preview.length)
        }
        if !hasMarkedText() || (multiCaretComposition?.preview.length ?? 0) < 0 {
            discardMultiCaretComposition()
        }
    }

    override func unmarkText() {
        if updatingComposition || renameDraft != nil {
            super.unmarkText()
        } else if let composition = multiCaretComposition,
                  let preview = textStorage?.attributedSubstring(from: composition.preview).string {
            commitMultiCaretComposition(preview)
        } else {
            super.unmarkText()
            onJJCompositionChange?()
        }
    }

    private func withTransientComposition(_ change: () -> Void) {
        updatingComposition = true
        let manager = undoManager
        manager?.disableUndoRegistration()
        defer {
            manager?.enableUndoRegistration()
            updatingComposition = false
        }
        withFocusEditsAllowed(change)
    }

    private func updateMarkedFocus(
        _ snapshot: EditorFocusSession.Snapshot, composition: MultiCaretComposition, length: Int
    ) {
        focusSession?.restore(snapshot)
        let original = NSRange(location: composition.preview.location, length: composition.original.length)
        focusSession?.resizeMarkedRange(original, to: length)
    }

    func discardMultiCaretComposition() {
        guard let composition = multiCaretComposition else { return }
        restoreCompositionBaseline(composition)
        onJJCompositionChange?()
    }

    private func restoreCompositionBaseline(_ composition: MultiCaretComposition) {
        multiCaretComposition = nil
        withTransientComposition {
            super.unmarkText()
            if let snapshot = composition.focusedRanges { focusSession?.restore(snapshot) }
            if let storage = textStorage, composition.preview.length >= 0,
               NSMaxRange(composition.preview) <= storage.length {
                storage.replaceCharacters(in: composition.preview, with: composition.original)
            }
            if let groups = composition.focusedGroups {
                restoreFocusedSelectionGroups(groups, primary: composition.selections.last,
                                              activeEnd: composition.focusedPrimaryEnd)
            } else {
                setCaretSelections(composition.selections, record: false)
            }
        }
    }

    private func commitMultiCaretComposition(_ text: String) {
        guard let composition = multiCaretComposition else { return }
        restoreCompositionBaseline(composition)
        _ = insertAtCarets(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        onJJCompositionChange?()
    }

    override func uppercaseWord(_ sender: Any?) {
        if !transformCase({ $0.uppercased() }) { super.uppercaseWord(sender) }
    }

    override func lowercaseWord(_ sender: Any?) {
        if !transformCase({ $0.lowercased() }) { super.lowercaseWord(sender) }
    }

    override func capitalizeWord(_ sender: Any?) {
        if transformProjectedSelection({ $0.capitalized }) { return }
        if !transformFocusedSelections({ $0.capitalized }) { super.capitalizeWord(sender) }
    }

    override func delete(_ sender: Any?) {
        if renameDraft != nil { super.delete(sender); return }
        if !replaceProjectedSelection(with: "") { super.delete(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if renameDraft != nil { super.deleteBackward(sender); return }
        if replaceProjectedSelection(with: "") { return }
        trackLanguageTyping(nil, enabled: true) {
            if !deleteAtCarets(backward: true, word: false) { super.deleteBackward(sender) }
        }
    }

    override func deleteForward(_ sender: Any?) {
        if renameDraft != nil { super.deleteForward(sender); return }
        if replaceProjectedSelection(with: "") { return }
        if !deleteAtCarets(backward: false, word: false) { super.deleteForward(sender) }
    }

    override func deleteWordBackward(_ sender: Any?) {
        if renameDraft != nil { super.deleteWordBackward(sender); return }
        if replaceProjectedSelection(with: "") { return }
        if !deleteAtCarets(backward: true, word: true) { super.deleteWordBackward(sender) }
    }

    override func deleteWordForward(_ sender: Any?) {
        if renameDraft != nil { super.deleteWordForward(sender); return }
        if replaceProjectedSelection(with: "") { return }
        if !deleteAtCarets(backward: false, word: true) { super.deleteWordForward(sender) }
    }

    override func cancelOperation(_ sender: Any?) {
        if multiCaretComposition != nil {
            discardMultiCaretComposition()
            inputContext?.discardMarkedText()
            return
        }
        guard !hasMarkedText() else {
            super.cancelOperation(sender)
            return
        }
        if onCancelSymbolRename?() == true { return }
        if languageAssistance?.dismiss() == true { return }
        if languageInteractionEnabled, languageInteraction.dismissHover() { return }
        if jjInlineDiff?.collapseAll() == true { return }

        if let scope = focusRanges {
            let selections = focusedSelections(in: scope)
            if let primary = selections.last, selections.count > 1 {
                setFocusedSelections([primary], in: scope)
            } else if let primary = selections.last, primary.anchor != primary.head {
                setFocusedSelections([FocusNavigationSelection(anchor: primary.head, head: primary.head)], in: scope)
            } else {
                exitFocus()
            }
        } else if hasSecondarySelections {
            keepPrimarySelection(sender)
        } else if let primary = caretSelections.last, primary.length > 0 {
            setCaretSelections([NSRange(location: activeEnd(of: primary), length: 0)])
        } else {
            super.cancelOperation(sender)
        }
    }

    override func doCommand(by selector: Selector) {
        if renameDraft != nil { super.doCommand(by: selector); return }
        if jjInlineDiff?.handleSelectionCommand(selector) == true { return }
        let before = selectedRange()
        if !moveSelections(command: selector) {
            if before.length == 0, !hasSecondarySelections, focusRanges == nil {
                multiCaret.navigation.removeValue(forKey: before)
            }
            super.doCommand(by: selector)
            let selection = selectedRange()
            if selection != before {
                let caret = selection.location == before.location ? NSMaxRange(selection) : selection.location
                revealInExposedArea(NSRange(location: caret, length: 0))
            }
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        revealInExposedArea(range)
    }

    func revealNavigationSelection(_ range: NSRange) {
        guard let scroll = enclosingScrollView else { return }
        let viewport = textViewport(in: scroll)
        let offset = activeEnd(of: range)
        if let line = laidOutLineBounds(at: offset), viewport.contains(line.minY), viewport.contains(line.maxY) {
            revealInExposedArea(range)
            return
        }
        guard let line = layoutLine(at: offset) else { return }
        let height = viewport.upperBound - viewport.lowerBound
        scrollToTextTop(line.midY - height / 2, horizontalOrigin: scroll.visibleContentOrigin.x, in: scroll)
        revealInExposedArea(range)
    }

    private func revealInExposedArea(_ range: NSRange) {
        guard range.location != NSNotFound, let window, let scroll = enclosingScrollView else { return }
        let insets = scroll.contentInsets
        var origin = scroll.visibleContentOrigin
        guard (insets.left > 0 && origin.x > 0) || insets.right > 0 || insets.bottom > 0 else { return }

        // TextKit can consider a range visible while it is under a glass panel.
        let screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        guard screenRect.height > 0 else { return }
        let rect = convert(window.convertFromScreen(screenRect), from: nil)
        let visible = scroll.documentVisibleRect
        let left = visible.minX + insets.left
        let right = visible.maxX - insets.right
        guard right > left else { return }

        if insets.left > 0 && rect.minX < left {
            origin.x += rect.minX - left - textContainerInset.width
        } else if insets.right > 0 && rect.maxX > right, rect.width <= right - left {
            origin.x += rect.maxX - right + textContainerInset.width
        }
        let bottom = visible.maxY - insets.bottom
        if insets.bottom > 0 && rect.maxY > bottom {
            origin.y += rect.maxY - bottom + textContainerInset.height
        }
        scroll.scrollToVisibleContentOrigin(origin)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if renameDraft == nil, window?.firstResponder === self, handleMultiCaretKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 120, modifiers.isEmpty {
            if isRenamingSymbol || (!event.isARepeat && onRenameSymbol?() == true) { return }
        }
        if renameDraft != nil { super.keyDown(with: event); return }
        if !hasMarkedText(), languageAssistance?.handleKey(event) == true { return }
        if handleMultiCaretKey(event) { return }
        if modifiers == .command && event.charactersIgnoringModifiers == "\u{F728}" && !hasMarkedText() {
            deleteToEndOfLine(nil)
            return
        }
        super.keyDown(with: event)
    }

    @objc func increaseTextSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseTextSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetTextSize(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    override func complete(_ sender: Any?) {
        if languageAssistance?.canComplete == true { languageAssistance?.complete() }
        else { super.complete(sender) }
    }

    @objc func showSignatureHelp(_ sender: Any?) { languageAssistance?.showSignature() }
    @objc func formatDocument(_ sender: Any?) { languageAssistance?.format() }

    func languageBufferChanged() {
        languageAssistance?.bufferChanged(whileTyping: isTypingForLanguageAssistance)
    }

    private func trackLanguageTyping(_ character: String?, enabled: Bool, editing: () -> Void) {
        guard enabled, let languageAssistance,
              languageAssistance.canComplete || languageAssistance.canShowSignature else {
            editing()
            return
        }
        let previous = selectedRange()
        isTypingForLanguageAssistance = true
        editing()
        isTypingForLanguageAssistance = false
        if selectedRange() != previous { languageAssistance.typed(character) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return isSelectable && (jjInlineDiff?.projectedEditRange != nil || (textStorage?.length ?? 0) > 0)
        case #selector(cut(_:)):
            return isEditable && (jjInlineDiff?.projectedEditRange?.length ?? textStorage?.length ?? 0) > 0
        case #selector(uppercaseWord(_:)), #selector(lowercaseWord(_:)):
            return isEditable && !hasMarkedText() && (textStorage?.length ?? 0) > 0
        case #selector(toggleLineComments(_:)):
            return isEditable && !hasMarkedText() && syntaxLanguage.lineCommentPrefix != nil
        case #selector(complete(_:)):
            return languageAssistance?.canComplete == true
        case #selector(showSignatureHelp(_:)):
            return languageAssistance?.canShowSignature == true
        case #selector(formatDocument(_:)):
            return languageAssistance?.canFormat == true
        case #selector(increaseTextSize(_:)):
            return fontSize < 72
        case #selector(decreaseTextSize(_:)):
            return fontSize > 6
        case #selector(resetTextSize(_:)):
            return fontSize != Self.defaultFontSize
        default:
            return validateSelectionCommand(item.action) ?? super.validateUserInterfaceItem(item)
        }
    }

    func capturePosition() -> EditorPosition {
        let focus = captureFocusPosition()
        guard let scroll = enclosingScrollView else {
            return EditorPosition(selections: caretSelections, horizontalOffset: 0, verticalOffset: 0, topLine: nil,
                                  focus: focus)
        }
        let top = textViewport(in: scroll).lowerBound
        return EditorPosition(selections: caretSelections, horizontalOffset: scroll.visibleContentOrigin.x,
                              verticalOffset: top, topLine: capturePositionTopLine(at: top), focus: focus)
    }

    func setWordWrap(_ enabled: Bool, preservingViewport: Bool = false) {
        guard wrapsWords != enabled, let scroll = enclosingScrollView as? EditorScrollView,
              let container = textContainer else { return }
        let anchor = preservingViewport ? zoomAnchor() : nil
        wrapsWords = enabled
        if enabled { updateDiagnosticWidth() }
        isHorizontallyResizable = !enabled
        autoresizingMask = enabled ? [.height] : [.width, .height]
        container.widthTracksTextView = enabled
        if !enabled {
            container.size = maxSize
            setFrameSize(NSSize(width: scroll.contentSize.width, height: frame.height))
        }
        scroll.horizontalScrollElasticity = enabled ? .none : .automatic
        scroll.hasHorizontalScroller = !enabled
        scroll.updateWordWrapWidth()
        if !enabled { updateDiagnosticWidth() }
        if enabled {
            scroll.scrollToVisibleContentOrigin(NSPoint(x: 0, y: scroll.visibleContentOrigin.y))
        }
        if preservingViewport {
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            if let anchor { restoreZoomAnchor(anchor, in: scroll, horizontalOrigin: 0) }
        }
        requestLineRefresh()
    }

    func restorePosition(_ position: EditorPosition) {
        if let text = textStorage?.mutableString {
            let focusRestored = position.focus.map { restoreFocusPosition($0, in: text) } ?? false
            if !focusRestored {
                let selections = position.selections.compactMap { restoredSelection($0, in: text) }
                setCaretSelections(selections.isEmpty ? [NSRange(location: 0, length: 0)] : selections, record: false)
            }
        }

        guard let scroll = enclosingScrollView,
              position.horizontalOffset.isFinite, position.verticalOffset.isFinite else { return }
        let viewport = textLayoutManager?.textViewportLayoutController
        viewport?.layoutViewport()
        if let anchor = position.topLine, anchor.textOffset >= 0,
           anchor.textOffset <= (textStorage?.length ?? 0), !caretIsNearViewport(anchor.textOffset) {
            scrollRangeToVisible(NSRange(location: anchor.textOffset, length: 0))
            viewport?.layoutViewport()
        }
        let top = position.topLine.flatMap { positionTopLineOrigin($0) } ?? position.verticalOffset
        // Restore the saved viewport last, even if the primary selection is outside it.
        scrollToTextTop(top, horizontalOrigin: position.horizontalOffset, in: scroll)

        // TextKit may adjust estimated coordinates when newly visible fragments are laid out.
        let settledTop = position.topLine.flatMap { positionTopLineOrigin($0) } ?? top
        if abs(textViewport(in: scroll).lowerBound - settledTop) > 0.5 ||
            abs(scroll.visibleContentOrigin.x - position.horizontalOffset) > 0.5 {
            scrollToTextTop(settledTop, horizontalOrigin: position.horizontalOffset, in: scroll)
        }
    }

    private func restoredSelection(_ range: NSRange, in text: NSString) -> NSRange? {
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0 else { return nil }
        let start = min(range.location, text.length)
        let end = start + min(range.length, text.length - start)

        func splitsSurrogate(at offset: Int) -> Bool {
            offset > 0 && offset < text.length && UTF16.isLeadSurrogate(text.character(at: offset - 1))
                && UTF16.isTrailSurrogate(text.character(at: offset))
        }

        let lowerBound = splitsSurrogate(at: start) ? start - 1 : start
        if start == end { return NSRange(location: lowerBound, length: 0) }
        let upperBound = splitsSurrogate(at: end) ? end + 1 : end
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    private func capturePositionTopLine(at top: CGFloat) -> EditorPosition.TopLine? {
        guard let manager = textLayoutManager else { return nil }
        let point = NSPoint(x: textContainer?.lineFragmentPadding ?? 0, y: max(0, top - textContainerOrigin.y))
        // Layout coordinates stay available when a line's first character is horizontally offscreen.
        guard let fragment = manager.textLayoutFragment(for: point), fragment.state == .layoutAvailable else {
            return nil
        }
        let offset = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
        let lineTop = fragment.layoutFragmentFrame.minY + textContainerOrigin.y
        return EditorPosition.TopLine(textOffset: offset, offsetIntoLine: top - lineTop)
    }

    private func positionTopLineOrigin(_ anchor: EditorPosition.TopLine) -> CGFloat? {
        guard anchor.textOffset >= 0, anchor.textOffset <= (textStorage?.length ?? 0),
              anchor.offsetIntoLine.isFinite, let manager = textLayoutManager,
              let location = manager.location(manager.documentRange.location, offsetBy: anchor.textOffset),
              let fragment = manager.textLayoutFragment(for: location), fragment.state == .layoutAvailable else {
            return nil
        }
        return fragment.layoutFragmentFrame.minY + textContainerOrigin.y + anchor.offsetIntoLine
    }

    private func topLine(at top: CGFloat) -> EditorPosition.TopLine? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let offset = characterIndexForInsertion(at: NSPoint(x: textContainerOrigin.x,
                                                           y: max(textContainerOrigin.y, top)))
        guard offset <= textStorage.length, let line = lineBounds(at: offset) else { return nil }
        return EditorPosition.TopLine(textOffset: offset, offsetIntoLine: top - line.minY)
    }

    private struct ZoomAnchor {
        let topLine: Int
        let offsetIntoTopLine: CGFloat
        let visibleActiveLine: Int?
        let horizontalOrigin: CGFloat
    }

    private func setFontSize(_ size: CGFloat) {
        let newSize = min(max(size, 6), 72)
        let anchor = newSize == fontSize ? nil : zoomAnchor()
        fontSize = newSize
        let font = fontSize == Self.defaultFontSize ? Self.defaultFont : Self.codeFont(ofSize: fontSize)
        self.font = font

        let paragraph = NSMutableParagraphStyle()
        let lineHeight = (fontSize * 1.5).rounded()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        defaultParagraphStyle = paragraph
        rebuildDiagnosticMessages()
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        if range.length > 0 {
            textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        if range.length > 0 {
            // Rebuild the visible fragments after changing both the font and paragraph metrics.
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            if let anchor, let scroll = enclosingScrollView {
                restoreZoomAnchor(anchor, in: scroll)
            }
        }
        requestLineRefresh()
    }

    private func zoomAnchor() -> ZoomAnchor? {
        guard let scroll = enclosingScrollView, let textStorage, textStorage.length > 0 else { return nil }
        let visible = textViewport(in: scroll)
        guard let topLine = topLine(at: visible.lowerBound) else { return nil }
        let active = selectedRange().location
        let visibleActiveLine: Int?
        if active <= textStorage.length, caretIsNearViewport(active), let line = lineBounds(at: active),
           line.maxY > visible.lowerBound, line.minY < visible.upperBound {
            visibleActiveLine = active
        } else {
            visibleActiveLine = nil
        }
        return ZoomAnchor(topLine: topLine.textOffset, offsetIntoTopLine: topLine.offsetIntoLine,
                          visibleActiveLine: visibleActiveLine, horizontalOrigin: scroll.visibleContentOrigin.x)
    }

    private func restoreZoomAnchor(_ anchor: ZoomAnchor, in scroll: NSScrollView, horizontalOrigin: CGFloat? = nil) {
        guard let topLine = layoutLine(at: anchor.topLine) else { return }
        let horizontalOrigin = horizontalOrigin ?? anchor.horizontalOrigin
        let offset = min(anchor.offsetIntoTopLine, max(0, topLine.height - 1))
        scrollToTextTop(topLine.minY + offset, horizontalOrigin: horizontalOrigin, in: scroll)

        let visible = textViewport(in: scroll)
        guard let active = anchor.visibleActiveLine, let line = layoutLine(at: active) else { return }
        var top = visible.lowerBound
        if line.maxY <= visible.lowerBound {
            top = line.minY
        } else if line.minY >= visible.upperBound {
            top = line.maxY - (visible.upperBound - visible.lowerBound)
        }
        scrollToTextTop(top, horizontalOrigin: horizontalOrigin, in: scroll)
    }

    private func layoutLine(at offset: Int) -> NSRect? {
        if let line = lineBounds(at: offset) { return line }
        // TextKit can omit geometry for lines outside its current layout viewport.
        scrollRangeToVisible(NSRange(location: offset, length: 0))
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        return lineBounds(at: offset)
    }

    private func scrollToTextTop(_ top: CGFloat, horizontalOrigin: CGFloat, in scroll: NSScrollView) {
        var origin = scroll.visibleContentOrigin
        origin.x = horizontalOrigin
        origin.y += top - textViewport(in: scroll).lowerBound
        if scroll.scrollToVisibleContentOrigin(origin) {
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    private func textViewport(in scroll: NSScrollView) -> ClosedRange<CGFloat> {
        let rect = scroll.documentVisibleRect
        let top = rect.minY + scroll.contentInsets.top
        return top...max(top, rect.maxY - scroll.contentInsets.bottom)
    }

    func laidOutLineBounds(at offset: Int) -> NSRect? {
        guard let layout = textLayoutManager,
              let location = layout.location(layout.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false) else { return nil }
        let frame = fragment.layoutFragmentFrame
        return line.typographicBounds.offsetBy(dx: frame.minX + textContainerOrigin.x,
                                               dy: frame.minY + textContainerOrigin.y)
    }

    func lineBounds(at offset: Int) -> NSRect? {
        guard let window else { return nil }
        let caret = firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        return caret.height > 0 ? convert(window.convertFromScreen(caret), from: nil) : nil
    }

    private func apply(_ edit: LineEditing.Edit?) {
        guard let edit, !hasMarkedText() else { return }
        replace(edit.range, with: edit.replacement, selection: edit.selection)
    }

    func replaceFoundText(_ edits: [EditorTextEdit], caret: Int) -> Bool {
        guard !hasMarkedText() else { return false }
        jjInlineDiff?.clearProjectedSelection()
        return applyMultiEdits(edits, selections: [NSRange(location: caret, length: 0)])
    }

    private func allowsProjectedChange(in range: NSRange) -> Bool {
        guard let editable = jjInlineDiff?.projectedEditRange else { return true }
        return editable.length > 0 && range.location >= editable.location && range.location <= editable.upperBound
            && range.length >= 0 && range.length <= editable.upperBound - range.location
    }

    private func prepareProjectedLineCommand() -> Bool {
        guard let diff = jjInlineDiff, let editable = diff.projectedEditRange else { return true }
        guard isEditable, editable.length > 0, focusAllowsEdits([editable]) else { return false }
        diff.clearProjectedSelection()
        return true
    }

    private func replaceProjectedSelection(with replacement: String?) -> Bool {
        guard let diff = jjInlineDiff, let editable = diff.projectedEditRange else { return false }
        guard let replacement, isEditable, editable.length > 0, !hasMarkedText(), focusAllowsEdits([editable]) else { return true }
        diff.clearProjectedSelection()
        let caret = NSRange(location: editable.location + replacement.utf16.count, length: 0)
        applyMultiEdits([.init(range: editable, text: replacement)], selections: [caret])
        return true
    }

    private func transformCase(_ transform: (String) -> String) -> Bool {
        guard isEditable, !hasMarkedText() else { return true }
        if transformProjectedSelection(transform) || transformFocusedSelections(transform) { return true }

        let selections = caretSelections
        guard selections.count > 1 || (selections.first?.length ?? 0) > 0,
              let text = textStorage?.mutableString else { return false }
        let edits = MultiCaretEditing.ordered(selections.filter { $0.length > 0 }).compactMap {
            range -> MultiCaretEditing.Replacement? in
            let original = text.substring(with: range)
            let transformed = transform(original)
            return original == transformed ? nil : MultiCaretEditing.Replacement(range: range, text: transformed)
        }
        let carets = selections.map { NSRange(location: NSMaxRange($0), length: 0) }
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(carets, after: edits))
        return true
    }

    private func transformProjectedSelection(_ transform: (String) -> String) -> Bool {
        guard let editable = jjInlineDiff?.projectedEditRange else { return false }
        guard let storage = textStorage, editable.length > 0, editable.upperBound <= storage.length else { return true }
        return replaceProjectedSelection(with: transform(storage.attributedSubstring(from: editable).string))
    }

    @discardableResult
    private func replace(_ range: NSRange, with replacement: String, selection: NSRange? = nil, coalesce: Bool = false) -> Bool {
        guard isEditable, range.length > 0 || !replacement.isEmpty, let textStorage else { return false }
        if insertInEmptyConflictSnapshot(replacement, at: range) { return true }
        if !coalesce { breakUndoCoalescing() }
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        withTextEdits([EditorTextEdit(range: range, text: replacement)]) {
            textStorage.replaceCharacters(in: range, with: replacement)
        }
        let next = selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0)
        setSelectedRange(next)
        didChangeText()
        if !coalesce { breakUndoCoalescing() }
        scrollRangeToVisible(next)
        return true
    }

    private func pasteIntoEmptyConflictSnapshot() -> Bool {
        guard !conflictEdits.isEmpty, let text = NSPasteboard.general.string(forType: .string) else { return false }
        return insertInEmptyConflictSnapshot(text, at: selectedRange())
    }

    private func insertInEmptyConflictSnapshot(_ text: String, at range: NSRange) -> Bool {
        guard isEditable, !hasMarkedText(), !hasSecondarySelections, range.length == 0, !text.isEmpty,
              let snapshot = conflictEdits.first(where: { !$0.hasSeparator && $0.result == range }) else { return false }
        let edit = EditorTextEdit(range: range, text: text + snapshot.original.lineEnding)
        let tracked = conflictEdits.compactMap { item in
            item.id == snapshot.id ? item.withInitialResult(length: text.utf16.count) : item.remapped(after: [edit])
        }
        let caret = NSRange(location: range.location + text.utf16.count, length: 0)
        return applyMultiEdits([edit], selections: [caret], actionName: "Edit Snapshot", conflictEditsAfter: tracked)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !isTypingForLanguageAssistance { languageAssistance?.selectionChanged() }
        if renameDraft != nil {
            multiCaret.restartBlink = true
            requestLineRefresh()
            return
        }
        if !updatingComposition, !multiCaret.isApplying {
            nativeSelectionChanged()
            occurrenceHighlighting.selectionChanged()
        }
        requestLineRefresh()
        jjInlineDiff?.selectionChanged()
        onConflictSelectionChange?()
        if !updatingComposition { onNavigationSelectionChange?() }
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                  toCharacterRange newRange: NSRange) -> NSRange {
        guard let range = renameRange, !updatingComposition else { return newRange }
        let start = min(max(newRange.location, range.location), range.upperBound)
        let end = min(max(newRange.upperBound, start), range.upperBound)
        return NSRange(location: start, length: end - start)
    }

    func withTextEdits(_ edits: [EditorTextEdit], _ apply: () -> Void) {
        let previous = applyingTextEdits
        applyingTextEdits = edits
        defer { applyingTextEdits = previous }
        apply()
    }

    @objc private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let delta = storage.changeInLength
        let edited = storage.editedRange
        let changes = applyingTextEdits?.map { EditorTextChange(range: $0.range, delta: $0.lengthChange) }
            ?? (edited.location != NSNotFound && edited.length >= delta
                ? [EditorTextChange(range: NSRange(location: edited.location, length: edited.length - delta), delta: delta)] : [])
        if SyntaxEngine.supportsIncremental(syntaxLanguage) {
            syntaxAnalysis.recordEdit(edited, delta: delta, length: storage.length)
        }
        bracketNavigation.sourceDidEdit(changes)
        let affectedColors = syntaxHighlighting?.storageDidEdit(storage, replacements: applyingTextEdits)
        defer {
            if let affectedColors { syntaxHighlighting?.invalidateEditedColors(in: affectedColors) }
        }
        if languageInteractionEnabled { languageInteraction.invalidate(afterTextEdit: true) }
        layoutSpacing.sourceDidEdit()
        if let draft = renameDraft {
            if !updatingComposition {
                let length = draft.range.length + storage.changeInLength
                renameDraft?.range.length = length
                focusSession?.resizeMarkedRange(draft.range, to: length)
            }
            requestLineRefresh()
            return
        }
        jjDecorations?.sourceDidEdit(changes)
        // Both preedit and its rollback are presentation. Subscribers still hold
        // the baseline onto which the real replacements will be applied.
        guard !updatingComposition else { return }
        onNavigationTextEdit?(storage.editedRange)
        if !replacingConflictStructure, !conflictEdits.isEmpty {
            let range = storage.editedRange
            let previousLength = range.length - storage.changeInLength
            let changes = applyingTextEdits ?? [EditorTextEdit(range: NSRange(location: range.location, length: previousLength),
                                                             text: storage.mutableString.substring(with: range))]
            conflictEdits = conflictEdits.compactMap { $0.remapped(after: changes) }
        }
        onBufferEdit?(storage, applyingTextEdits)
    }

    func textDidChange(_ notification: Notification) {
        syntaxHighlighting?.refreshEditedRenderingColors()
        if renameDraft != nil {
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            renameShade?.update()
            refreshCaretDecorations()
            requestLineRefresh()
            return
        }
        jjInlineDiff?.sourceTextChanged()
        guard !updatingComposition else {
            onJJCompositionChange?()
            occurrenceHighlighting.reset()
            requestLineRefresh()
            return
        }
        if !multiCaret.isApplying {
            exitFocus()
            multiCaret.selections = [selectedRange()]
            multiCaret.navigation = [:]
        }
        resetSelectionHistory()
        multiCaret.restartBlink = true
        occurrenceHighlighting.contentChanged()
        // The text and the custom insertion indicators must reach the same display pass.
        refreshCaretDecorations()
        bracketNavigation.refresh()
        requestLineRefresh()
        onTextChange?()
    }

    override func textViewportLayoutController(
        _ controller: NSTextViewportLayoutController, configureRenderingSurfaceFor fragment: NSTextLayoutFragment
    ) {
        if let manager = controller.textLayoutManager {
            syntaxHighlighting?.prepareForDrawing(fragment, using: manager)
        }
        super.textViewportLayoutController(controller, configureRenderingSurfaceFor: fragment)
    }

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        if !diagnostics.isEmpty {
            refreshDiagnosticForeground(redraw: true)
            invalidateOverscrollBackground()
        }
        bracketNavigation.layoutHighlights()
        if let range = renameRange, range.length > 0 { renameShade?.update() }
        requestLineRefresh()
    }

    func setJJLineMarks(_ marks: [JJLineMark], lineStarts: [Int] = [], hunks: [JJDiffHunk] = [], normalizeCRLF: Bool = false) {
        if jjDecorations == nil, !marks.isEmpty { jjDecorations = JJEditorDecorations(editor: self) }
        if jjInlineDiff == nil, !hunks.isEmpty { jjInlineDiff = JJInlineDiff(editor: self) }
        jjInlineDiff?.update(hunks, normalizeCRLF: normalizeCRLF)
        jjDecorations?.setMarks(marks, lineStarts: lineStarts, hunks: hunks)
    }

    var jjLineMarks: [JJLineMark] { jjDecorations?.marks ?? [] }

    func setJJConflictHighlights(_ highlights: [JJConflict.Highlight]) {
        if jjConflictDecorations == nil, !highlights.isEmpty { jjConflictDecorations = JJConflictDecorations(editor: self) }
        jjConflictDecorations?.update(highlights)
    }

    func installConflictProjection(_ removals: [EditorTextEdit], tracked: [JJConflictEdit]) {
        guard let storage = textStorage, !removals.isEmpty else { return }
        let selections = MultiCaretEditing.mapped(caretSelections, after: removals)
        replacingConflictStructure = true
        conflictEdits = tracked
        withTextEdits(removals) {
            storage.beginEditing()
            for removal in removals.reversed() { storage.deleteCharacters(in: removal.range) }
            _ = updateFocus(after: removals, restoring: nil)
            storage.endEditing()
        }
        replacingConflictStructure = false
        setCaretSelections(selections, record: false)
        bracketNavigation.reset()
        occurrenceHighlighting.contentChanged()
        requestLineRefresh()
    }

    func suspendJJMarkerNavigation() {
        jjDecorations?.allowsNavigation = false
        jjInlineDiff?.suspend()
    }

    func requestLineRefresh() {
        guard !lineRefreshPending else { return }
        lineRefreshPending = true
        // Resolving the caret can request viewport layout. Do it outside the layout callback.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshCurrentLine()
            self.bracketNavigation.refresh()
            self.syntaxHighlighting?.refreshSyntaxViewport()
            self.occurrenceHighlighting.layout()
            self.jjInlineDiff?.layout()
            self.jjConflictDecorations?.layout()
            if let scroll = self.enclosingScrollView { self.jjDecorations?.layout(in: scroll) }
            self.renameShade?.update()
            self.updateMarkdownToolTips()
            self.lineRefreshPending = false
            self.languageAssistance?.viewportChanged()
            self.onFindViewportChange?()
        }
    }

    func refreshCurrentLine() {
        refreshCaretDecorations()
        refreshFocusDecoration()
        guard hasBufferFocus else {
            setCurrentLine(.zero)
            return
        }
        let location = selectedRange().location
        var newLine = NSRect.zero
        if jjInlineDiff?.hasProjectedCaret == true {
            if let line = jjInlineDiff?.projectedCaretRect {
                newLine = NSRect(x: bounds.minX, y: line.minY, width: bounds.width, height: line.height)
            }
        } else if caretIsNearViewport(location) {
            if let line = currentLineBounds(at: location) {
                newLine = NSRect(x: bounds.minX, y: line.minY, width: bounds.width, height: line.height)
            } else if textStorage?.length == 0, let paragraph = defaultParagraphStyle {
                newLine = NSRect(x: bounds.minX, y: textContainerOrigin.y, width: bounds.width,
                                 height: paragraph.minimumLineHeight)
            }
        }
        setCurrentLine(newLine)
    }

    private func setCurrentLine(_ newLine: NSRect) {
        // Moving one layer keeps old line backgrounds out of the text view's scrolling tiles.
        if currentLineHighlight.frame != newLine {
            currentLineHighlight.frame = newLine
            invalidateOverscrollBackground()
        }
    }

    func invalidateOverscrollBackground() {
        (enclosingScrollView as? EditorScrollView)?.invalidateOverscrollBackground()
    }

    fileprivate func drawOverscrollBackground(in dirtyRect: NSRect) {
        jjInlineDiff?.drawBackground(in: dirtyRect, includesText: false)
        jjConflictDecorations?.draw(in: dirtyRect, includesDetails: false)
        drawDiagnosticBackground(in: dirtyRect)
        let line = currentLineHighlight.frame
        let band = NSRect(x: dirtyRect.minX, y: line.minY, width: dirtyRect.width, height: line.height)
        CurrentLineHighlight.color.setFill()
        band.intersection(dirtyRect).fill()
    }

    private func currentLineBounds(at offset: Int) -> NSRect? {
        if let bounds = lineBounds(at: offset) { return bounds }
        // The caret rect can be unavailable when the row is visible but the caret is offscreen horizontally.
        guard let layout = textLayoutManager,
              let location = layout.location(layout.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false) else { return nil }
        let frame = fragment.layoutFragmentFrame
        return line.typographicBounds.offsetBy(dx: frame.minX + textContainerOrigin.x, dy: frame.minY + textContainerOrigin.y)
    }

    private func caretIsNearViewport(_ offset: Int) -> Bool {
        guard let manager = textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange,
              let caret = manager.location(manager.documentRange.location, offsetBy: offset) else { return true }
        return caret.compare(viewport.location) != .orderedAscending && caret.compare(viewport.endLocation) != .orderedDescending
    }

    func invalidateLanguageInteraction() {
        if languageInteractionEnabled { languageInteraction.invalidate() }
    }

    func showLanguageFeedback(_ message: String, at range: NSRange) {
        if languageInteractionEnabled { languageInteraction.showFeedback(message, at: range) }
    }

#if EDIT_AGENT_CHECKS
    var beforeApplyLanguageFormattingForCheck: (() async -> Void)?
    var completionLabelsForCheck: [String] { languageAssistance?.completionLabelsForCheck ?? [] }
    var signatureLabelForCheck: String? { languageAssistance?.signatureLabelForCheck }
    var signatureParameterForCheck: NSRange? { languageAssistance?.signatureParameterForCheck }
    var completionFrameForCheck: NSRect? { languageAssistance?.completionFrameForCheck }
    var completionCaretFrameForCheck: NSRect? { languageAssistance?.completionCaretFrameForCheck }
    var completionDocumentationForCheck: String? { languageAssistance?.completionDocumentationForCheck }
    var completionDocumentationFrameForCheck: NSRect? { languageAssistance?.completionDocumentationFrameForCheck }
    var completionListFrameForCheck: NSRect? { languageAssistance?.completionListFrameForCheck }
    var completionListForCheck: NSTableView? { languageAssistance?.completionListForCheck }
    var signatureFrameForCheck: NSRect? { languageAssistance?.signatureFrameForCheck }
#endif

    func hasLanguageDefinitionLink(at point: NSPoint) -> Bool {
        languageInteractionEnabled && languageInteraction.linkContains(point)
    }

#if EDIT_AGENT_CHECKS
    var languageHoverWindowForCheck: NSWindow? { languageInteraction.hoverWindow }
    var languageHoverPointerScreenXForCheck: CGFloat? { languageInteraction.hoverPointerScreenXForCheck }

    func observeEditorUnhideForCheck(_ action: (() -> Void)?) {
        (enclosingScrollView as? EditorScrollView)?.onUnhideForCheck = action
    }

    var markdownToolTipsForCheck: [String] { markdownToolTips.map { $0.label as String } }
#endif

    func setMarkdownToolTipLinks(_ links: [MarkdownDocument.Link]) {
        markdownToolTipLinks = links
        updateMarkdownToolTips()
    }

    private func updateMarkdownToolTips() {
        var tips: [MarkdownToolTip] = []
        if !markdownToolTipLinks.isEmpty, let manager = textLayoutManager,
           let viewport = manager.textViewportLayoutController.viewportRange {
            let visible = charRange(viewport, in: manager)
            for link in markdownToolTipLinks {
                let range = NSRange(location: link.start, length: link.end - link.start)
                guard NSIntersectionRange(visible, range).length > 0, let label = link.toolTip, !label.isEmpty else { continue }
                for frame in highlightRects(for: [range]) {
                    let rect = frame.intersection(visibleRect)
                    if !rect.isEmpty { tips.append(MarkdownToolTip(rect: rect, label: label as NSString)) }
                }
            }
        }
        guard tips != markdownToolTips else { return }
        markdownToolTipTags.forEach(removeToolTip)
        markdownToolTips = tips
        markdownToolTipTags = tips.map { addToolTip($0.rect, owner: $0.label, userData: nil) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let languageTrackingArea {
            removeTrackingArea(languageTrackingArea)
            self.languageTrackingArea = nil
        }
        guard languageInteractionEnabled || syntaxLanguage == .markdown else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        languageTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if !updateMarkdownPointer(at: event.locationInWindow, modifiers: event.modifierFlags), languageInteractionEnabled {
            languageInteraction.track(at: event.locationInWindow, modifiers: event.modifierFlags)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if updateMarkdownPointer(at: event.locationInWindow, modifiers: event.modifierFlags) { return }
        if languageInteractionEnabled, event.trackingArea === languageTrackingArea {
            languageInteraction.track(at: event.locationInWindow, modifiers: event.modifierFlags)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pointsAtMarkdownLink = false
        if languageInteractionEnabled, event.trackingArea === languageTrackingArea { languageInteraction.pointerExited() }
    }

    override func cursorUpdate(with event: NSEvent) {
        // Native tracking can come straight to the text view, even beneath window chrome.
        if let window, (NSApp as? EditApplication)?.updatePointerCursor(in: window) == true { return }
        if updateMarkdownPointer(at: event.locationInWindow, modifiers: event.modifierFlags) { return }
        super.cursorUpdate(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if let window { _ = updateMarkdownPointer(at: window.mouseLocationOutsideOfEventStream, modifiers: event.modifierFlags) }
    }

    private func updateMarkdownPointer(at position: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        let linked = markdownLink(at: position, modifiers: modifiers, activate: false)
        if linked { NSCursor.pointingHand.set() }
        else if pointsAtMarkdownLink { NSCursor.iBeam.set() }
        pointsAtMarkdownLink = linked
        return linked
    }

    private func markdownLink(at position: NSPoint, modifiers: NSEvent.ModifierFlags, activate: Bool) -> Bool {
        guard syntaxLanguage == .markdown, modifiers.intersection([.command, .option, .control, .shift]) == .command,
              let markdownLink else { return false }
        let point = convert(position, from: nil)
        guard visibleRect.contains(point) else { return false }
        let offset = characterIndexForInsertion(at: point)
        guard offset != NSNotFound else { return false }
        if offset < string.utf16.count,
           highlightRects(for: [NSRange(location: offset, length: 1)]).contains(where: { $0.contains(point) }),
           markdownLink(offset, activate) { return true }
        return offset > 0 && highlightRects(for: [NSRange(location: offset - 1, length: 1)]).contains(where: { $0.contains(point) })
            && markdownLink(offset - 1, activate)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        jjInlineDiff?.drawBackground(in: dirtyRect.intersection(bounds))
        jjConflictDecorations?.draw(in: dirtyRect.intersection(bounds))
        drawDiagnosticBackground(in: dirtyRect.intersection(bounds))
        occurrenceHighlighting.draw(in: dirtyRect)
        bracketNavigation.draw(in: dirtyRect)
        onDrawFindHighlights?(dirtyRect)
        if renameDraft == nil { drawSecondarySelections(in: dirtyRect) }
    }

    private(set) var diagnostics: [LSPError] = []
    var diagnosticMessagesByLineEnd: [Int: DiagnosticMessage] = [:]
    var diagnosticMinimumWidth: CGFloat = 0
    private var diagnosticForeground: EditorDiagnosticForeground?

    func setDiagnostics(_ errors: [LSPError]) {
        guard errors != diagnostics else { return }
        diagnostics = errors
        rebuildDiagnosticMessages()
        languageInteraction.diagnosticsDidChange()
        refreshDiagnosticForeground(redraw: true)
        setNeedsDisplay(visibleRect)
        invalidateOverscrollBackground()
    }

    fileprivate func refreshDiagnosticForeground(redraw: Bool = false) {
        guard !diagnostics.isEmpty else {
            diagnosticForeground?.removeFromSuperview()
            diagnosticForeground = nil
            return
        }
        let viewport = visibleRect
        let foreground: EditorDiagnosticForeground
        if let existing = diagnosticForeground {
            foreground = existing
        } else {
            foreground = EditorDiagnosticForeground(frame: viewport)
            addSubview(foreground, positioned: .above, relativeTo: nil)
            diagnosticForeground = foreground
        }
        let moved = foreground.frame != viewport
        if moved { foreground.frame = viewport }
        if moved || redraw { foreground.needsDisplay = true }
    }
}

/// TextKit draws its selection above the editor background.
@MainActor
private final class EditorDiagnosticForeground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        clipsToBounds = true
        wantsLayer = true
        layer?.zPosition = 1
    }

    required init?(coder: NSCoder) { fatalError("Diagnostic decorations are created in code.") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor = superview as? EditorTextView, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: -frame.minX, y: -frame.minY)
        editor.drawDiagnosticForeground(in: dirtyRect.offsetBy(dx: frame.minX, dy: frame.minY))
        context.restoreGState()
    }
}

@MainActor
private final class CurrentLineHighlight: NSView {
    static var color: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = Self.color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class EditorOverscrollBackground: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        guard !rect.isEmpty, let editor = superview as? EditorTextView,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = frame.origin
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        editor.drawOverscrollBackground(in: rect.offsetBy(dx: origin.x, dy: origin.y))
        context.restoreGState()
    }
}

@MainActor
private final class EditorScrollView: NSScrollView {
    private var preservingViewport = false
    private let leftOverscroll = EditorOverscrollBackground()
    private let rightOverscroll = EditorOverscrollBackground()

    #if EDIT_AGENT_CHECKS
    var onUnhideForCheck: (() -> Void)?

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onUnhideForCheck?()
    }
    #endif

    override var contentInsets: NSEdgeInsets {
        get { super.contentInsets }
        set {
            preserveViewport {
                super.contentInsets = newValue
                updateWordWrapWidth()
            }
        }
    }

    override func tile() {
        super.tile()
        updateWordWrapWidth()
        refreshScrollDecorations()
    }

    func updateWordWrapWidth() {
        guard let editor = documentView as? EditorTextView, editor.wrapsWords else { return }
        // The scroll view underlaps the sidebars. Wrap within the exposed buffer.
        let width = max(1, contentView.bounds.width - contentInsets.left - contentInsets.right)
        guard editor.frame.width != width else { return }
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        if !editor.diagnostics.isEmpty { editor.setNeedsDisplay(editor.visibleRect) }
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        refreshScrollDecorations()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let nativeHit = super.hitTest(point) else { return nil }
        let markers = (documentView as? EditorTextView)?.jjDecorations
        return markers?.hitTest(in: self, at: convert(point, from: superview), nativeHit: nativeHit) ?? nativeHit
    }

    private func refreshScrollDecorations() {
        guard let editor = documentView as? EditorTextView else { return }
        if !editor.diagnostics.isEmpty { editor.refreshDiagnosticForeground() }
        if editor.renameRange != nil { editor.requestLineRefresh() }
        editor.jjDecorations?.layout(in: self)
        editor.jjConflictDecorations?.alignActionsHorizontally(in: self)
        let clip = contentView
        let viewport = clip.bounds
        // NSTextView's drawing stops at the document edges. Cover only the space exposed beyond them.
        func place(_ background: EditorOverscrollBackground, from start: CGFloat, to end: CGFloat) {
            guard start < end else {
                background.removeFromSuperview()
                return
            }
            if background.superview == nil {
                background.clipsToBounds = true
                editor.addSubview(background, positioned: .below, relativeTo: nil)
            }
            let strip = NSRect(x: start, y: viewport.minY, width: end - start, height: viewport.height)
            let frame = editor.convert(strip, from: clip)
            if background.frame != frame {
                background.frame = frame
                background.needsDisplay = true
            }
        }
        place(leftOverscroll, from: viewport.minX, to: min(viewport.maxX, editor.frame.minX))
        place(rightOverscroll, from: max(viewport.minX, editor.frame.maxX), to: viewport.maxX)
    }

    func invalidateOverscrollBackground() {
        if leftOverscroll.superview != nil { leftOverscroll.needsDisplay = true }
        if rightOverscroll.superview != nil { rightOverscroll.needsDisplay = true }
    }

    func preserveViewport(_ change: () -> Void) {
        guard documentView != nil, !preservingViewport else {
            change()
            return
        }
        let origin = visibleContentOrigin
        preservingViewport = true
        defer { preservingViewport = false }
        change()
        if origin != visibleContentOrigin { scrollToVisibleContentOrigin(origin) }
    }
}

extension NSScrollView {
    // Measure from the unobscured edge so adding or resizing an overlay doesn't change the text position.
    var visibleContentOrigin: NSPoint {
        let origin = contentView.bounds.origin
        return NSPoint(x: origin.x + contentInsets.left, y: origin.y + contentInsets.top)
    }

    @discardableResult
    func scrollToVisibleContentOrigin(_ origin: NSPoint) -> Bool {
        let clip = contentView
        let proposed = NSPoint(x: origin.x - contentInsets.left, y: origin.y - contentInsets.top)
        let constrained = clip.constrainBoundsRect(NSRect(origin: proposed, size: clip.bounds.size)).origin
        guard clip.bounds.origin != constrained else { return false }
        clip.scroll(to: constrained)
        reflectScrolledClipView(clip)
        return true
    }
}
