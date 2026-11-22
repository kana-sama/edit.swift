import AppKit

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

final class EditorTextView: NSTextView, NSTextViewDelegate {
    static let linePasteType = NSPasteboard.PasteboardType("dev.edit-swift.whole-line")
    private static let defaultFontSize: CGFloat = 12
    static let defaultFont = codeFont(ofSize: defaultFontSize)
    private var fontSize = EditorTextView.defaultFontSize
    private var currentLine = NSRect.zero
    private var lineRefreshPending = false
    let multiCaret = MultiCaretState()
    private weak var multiCaretWindow: NSWindow?
    private var multiCaretComposition: MultiCaretComposition?
    private var updatingComposition = false
    let editorUndoManager = EditorUndoManager()
    var focusSession: EditorFocusSession?
    var focusDecoration: FocusDecoration?
    var focusEditsAllowed = false
    var onFocusScopeChange: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onBlur: (() -> Void)?
    var onFindEditorInteraction: (() -> Void)?
    var onFindViewportChange: (() -> Void)?
    var onDrawFindHighlights: ((NSRect) -> Void)?
    weak var syntaxHighlighting: SyntaxHighlighting?
    var preferredLineEnding = "\n"


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
        // Keep AppKit’s selection background and leave syntax colors on the glyphs.
        editor.selectedTextAttributes.removeValue(forKey: .foregroundColor)
        editor.insertionPointColor = .textColor
        editor.delegate = editor
        editor.setFontSize(defaultFontSize)
        scrollView.documentView = editor
        return (scrollView, editor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        let events = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        if let previous = multiCaretWindow {
            for event in events { center.removeObserver(self, name: event, object: previous) }
        }
        multiCaretWindow = window
        if let window {
            for event in events {
                center.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: event, object: window)
            }
        }
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        hideCaretDecorations()
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

    override var undoManager: UndoManager? { editorUndoManager }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard focusSession == nil || focusEditsAllowed || replacementString == nil else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard focusSession == nil || focusEditsAllowed || replacementStrings == nil else { return false }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    override func selectAll(_ sender: Any?) {
        if !selectFocusedText() { super.selectAll(sender) }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        requestLineRefresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        multiCaret.pendingSkip = false
        if multiCaretComposition != nil { unmarkText() }
        hideCaretDecorations()
        onBlur?()
        return true
    }

    override func insertTab(_ sender: Any?) {
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
        guard !hasMarkedText() else {
            super.insertBacktab(sender)
            return
        }
        outdentLines(sender)
    }

    override func insertNewline(_ sender: Any?) {
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
        if editMultipleLines(.indent(outdent: false)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.indent(text, selection: selectedRange(), outdent: false))
    }

    @objc func outdentLines(_ sender: Any?) {
        if editMultipleLines(.indent(outdent: true)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.indent(text, selection: selectedRange(), outdent: true))
    }

    @objc func moveLinesUp(_ sender: Any?) {
        if editMultipleLines(.move(up: true)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.moveLines(text, selection: selectedRange(), up: true))
    }

    @objc func moveLinesDown(_ sender: Any?) {
        if editMultipleLines(.move(up: false)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.moveLines(text, selection: selectedRange(), up: false))
    }

    @objc func insertLineAbove(_ sender: Any?) {
        if editMultipleLines(.insert(above: true)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.insertLine(text, selection: selectedRange(), above: true))
    }

    @objc func insertLineBelow(_ sender: Any?) {
        if editMultipleLines(.insert(above: false)) { return }
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.insertLine(text, selection: selectedRange(), above: false))
    }

    override func copy(_ sender: Any?) {
        if copySelections(to: .general, cutting: false) { return }
        if selectedRange().length > 0 {
            super.copy(sender)
        } else {
            copyLine(to: .general, cutting: false)
        }
    }

    override func cut(_ sender: Any?) {
        if copySelections(to: .general, cutting: true) { return }
        if selectedRange().length > 0 {
            super.cut(sender)
        } else {
            copyLine(to: .general, cutting: true)
        }
    }

    override func paste(_ sender: Any?) {
        if !pasteAtCarets(from: .general) && !pasteLine(from: .general) {
            super.paste(sender)
        }
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
        onFindEditorInteraction?()
        if let focusSession, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            if !focusSession.contains(NSRange(location: offset, length: 0)) { exitFocus() }
        }
        if addCaret(at: event) { return }
        multiCaret.pendingSkip = false
        super.mouseDown(with: event)
        if focusSession == nil && hasSecondarySelections { keepPrimarySelection(nil) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if updatingComposition {
            super.insertText(string, replacementRange: replacementRange)
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
        if !insertAtCarets(string, replacementRange: replacementRange) {
            if focusSession != nil { return }
            if hasSecondarySelections { keepPrimarySelection(nil) }
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !updatingComposition else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        let preview = (string as? String) ?? (string as? NSAttributedString)?.string
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

        if multiCaretComposition == nil, hasSecondarySelections || focusSession != nil,
           let primary = caretSelections.last {
            let explicit = replacementRange.location != NSNotFound && replacementRange != primary
            let target = explicit && focusSession != nil ? replacementRange : primary
            guard focusAllowsEdits([target]) else { return }
            let selections = explicit && focusSession != nil ? [target] : caretSelections
            let groups = explicit ? nil : focusedSelectionGroups
            let activeEnd = activeEnd(of: target)
            setCaretSelections([target], record: false)
            if isEditable, preview?.isEmpty == false, let storage = textStorage,
               !explicit || focusSession != nil {
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
        if updatingComposition {
            super.unmarkText()
        } else if let composition = multiCaretComposition,
                  let preview = textStorage?.attributedSubstring(from: composition.preview).string {
            commitMultiCaretComposition(preview)
        } else {
            super.unmarkText()
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
        discardMultiCaretComposition()
        _ = insertAtCarets(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func uppercaseWord(_ sender: Any?) {
        if !transformFocusedSelections({ $0.uppercased() }) { super.uppercaseWord(sender) }
    }

    override func lowercaseWord(_ sender: Any?) {
        if !transformFocusedSelections({ $0.lowercased() }) { super.lowercaseWord(sender) }
    }

    override func capitalizeWord(_ sender: Any?) {
        if !transformFocusedSelections({ $0.capitalized }) { super.capitalizeWord(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if !deleteAtCarets(backward: true, word: false) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if !deleteAtCarets(backward: false, word: false) { super.deleteForward(sender) }
    }

    override func deleteWordBackward(_ sender: Any?) {
        if !deleteAtCarets(backward: true, word: true) { super.deleteWordBackward(sender) }
    }

    override func deleteWordForward(_ sender: Any?) {
        if !deleteAtCarets(backward: false, word: true) { super.deleteWordForward(sender) }
    }

    override func cancelOperation(_ sender: Any?) {
        if multiCaretComposition != nil {
            discardMultiCaretComposition()
            inputContext?.discardMarkedText()
        } else if focusSession != nil && !hasMarkedText() {
            if let primary = caretSelections.last, hasSecondarySelections || primary.length > 0 {
                setCaretSelections([NSRange(location: activeEnd(of: primary), length: 0)])
            } else {
                exitFocus()
            }
        } else if hasSecondarySelections && !hasMarkedText() {
            keepPrimarySelection(sender)
        } else {
            super.cancelOperation(sender)
        }
    }

    override func doCommand(by selector: Selector) {
        let before = selectedRange()
        if !moveSecondarySelections(command: selector) {
            super.doCommand(by: selector)
            let selection = selectedRange()
            if selection != before {
                let caret = selection.location == before.location ? NSMaxRange(selection) : selection.location
                revealHorizontally(NSRange(location: caret, length: 0))
            }
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        revealHorizontally(range)
    }

    private func revealHorizontally(_ range: NSRange) {
        guard range.location != NSNotFound, let window, let scroll = enclosingScrollView else { return }
        let insets = scroll.contentInsets
        var origin = scroll.visibleContentOrigin
        guard (insets.left > 0 && origin.x > 0) || insets.right > 0 else { return }

        // TextKit can consider a range visible while it is underneath the sidebar.
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
        } else {
            return
        }
        scroll.scrollToVisibleContentOrigin(origin)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleMultiCaretKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleMultiCaretKey(event) { return }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command && event.charactersIgnoringModifiers == "\u{F728}" && !hasMarkedText() {
            deleteToEndOfLine(nil)
            return
        }
        super.keyDown(with: event)
    }

    @objc func increaseTextSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseTextSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc func resetTextSize(_ sender: Any?) { setFontSize(Self.defaultFontSize) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return isSelectable && (textStorage?.length ?? 0) > 0
        case #selector(cut(_:)):
            return isEditable && (textStorage?.length ?? 0) > 0
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

    private func restoreZoomAnchor(_ anchor: ZoomAnchor, in scroll: NSScrollView) {
        guard let topLine = layoutLine(at: anchor.topLine) else { return }
        let offset = min(anchor.offsetIntoTopLine, max(0, topLine.height - 1))
        scrollToTextTop(topLine.minY + offset, horizontalOrigin: anchor.horizontalOrigin, in: scroll)

        let visible = textViewport(in: scroll)
        guard let active = anchor.visibleActiveLine, let line = layoutLine(at: active) else { return }
        var top = visible.lowerBound
        if line.maxY <= visible.lowerBound {
            top = line.minY
        } else if line.minY >= visible.upperBound {
            top = line.maxY - (visible.upperBound - visible.lowerBound)
        }
        scrollToTextTop(top, horizontalOrigin: anchor.horizontalOrigin, in: scroll)
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

    func lineBounds(at offset: Int) -> NSRect? {
        guard let window else { return nil }
        let caret = firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        return caret.height > 0 ? convert(window.convertFromScreen(caret), from: nil) : nil
    }

    private func apply(_ edit: LineEditing.Edit?) {
        guard let edit, !hasMarkedText() else { return }
        replace(edit.range, with: edit.replacement, selection: edit.selection)
    }

    func replaceFoundText(in range: NSRange, with replacement: String) -> Bool {
        guard !hasMarkedText() else { return false }
        return replace(range, with: replacement)
    }

    @discardableResult
    private func replace(_ range: NSRange, with replacement: String, selection: NSRange? = nil, coalesce: Bool = false) -> Bool {
        guard isEditable, range.length > 0 || !replacement.isEmpty, let textStorage else { return false }
        if !coalesce { breakUndoCoalescing() }
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: range, with: replacement)
        let next = selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0)
        setSelectedRange(next)
        didChangeText()
        if !coalesce { breakUndoCoalescing() }
        scrollRangeToVisible(next)
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !updatingComposition { nativeSelectionChanged() }
        requestLineRefresh()
    }

    func textDidChange(_ notification: Notification) {
        guard !updatingComposition else {
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
        requestLineRefresh()
    }

    func requestLineRefresh() {
        guard !lineRefreshPending else { return }
        lineRefreshPending = true
        // Resolving the caret can request viewport layout. Do it outside the layout callback.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshCurrentLine()
            self.lineRefreshPending = false
            self.onFindViewportChange?()
        }
    }

    func refreshCurrentLine() {
        refreshCaretDecorations()
        refreshFocusDecoration()
        let location = selectedRange().location
        var newLine = NSRect.zero
        if window != nil, caretIsNearViewport(location) {
            if let line = lineBounds(at: location) {
                newLine = NSRect(x: bounds.minX, y: line.minY, width: bounds.width, height: line.height)
            } else if textStorage?.length == 0, let paragraph = defaultParagraphStyle {
                newLine = NSRect(x: bounds.minX, y: textContainerOrigin.y, width: bounds.width,
                                 height: paragraph.minimumLineHeight)
            }
        }
        if newLine != currentLine {
            setNeedsDisplay(currentLine.intersection(visibleRect))
            currentLine = newLine
            setNeedsDisplay(currentLine.intersection(visibleRect))
        }
    }

    private func caretIsNearViewport(_ offset: Int) -> Bool {
        guard let manager = textLayoutManager,
              let viewport = manager.textViewportLayoutController.viewportRange,
              let caret = manager.location(manager.documentRange.location, offsetBy: offset) else { return true }
        return caret.compare(viewport.location) != .orderedAscending && caret.compare(viewport.endLocation) != .orderedDescending
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let stripe = dirtyRect.intersection(currentLine)
        if !stripe.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            stripe.fill()
        }
        onDrawFindHighlights?(dirtyRect)
        drawSecondarySelections(in: dirtyRect)
    }
}

@MainActor
private final class EditorScrollView: NSScrollView {
    private var preservingViewport = false

    override var contentInsets: NSEdgeInsets {
        get { super.contentInsets }
        set { preserveViewport { super.contentInsets = newValue } }
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
