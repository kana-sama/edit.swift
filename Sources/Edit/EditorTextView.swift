import AppKit

final class EditorTextView: NSTextView, NSTextViewDelegate {
    private static let linePasteType = NSPasteboard.PasteboardType("dev.edit-swift.whole-line")
    private static let defaultFontSize: CGFloat = 13
    private var fontSize = EditorTextView.defaultFontSize
    private var currentLine = NSRect.zero
    private var lineRefreshPending = false
    var onTextChange: (() -> Void)?
    var preferredLineEnding = "\n"

    static func scrollingEditor(in frame: NSRect) -> (NSScrollView, EditorTextView) {
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
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
        editor.insertionPointColor = .textColor
        editor.delegate = editor
        editor.setFontSize(defaultFontSize)
        scrollView.documentView = editor
        return (scrollView, editor)
    }

    override func insertTab(_ sender: Any?) {
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
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.indent(text, selection: selectedRange(), outdent: false))
    }

    @objc func outdentLines(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.indent(text, selection: selectedRange(), outdent: true))
    }

    @objc func moveLinesUp(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.moveLines(text, selection: selectedRange(), up: true))
    }

    @objc func moveLinesDown(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.moveLines(text, selection: selectedRange(), up: false))
    }

    @objc func insertLineAbove(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.insertLine(text, selection: selectedRange(), above: true))
    }

    @objc func insertLineBelow(_ sender: Any?) {
        guard let text = textStorage?.mutableString else { return }
        apply(LineEditing.insertLine(text, selection: selectedRange(), above: false))
    }

    override func copy(_ sender: Any?) {
        if selectedRange().length > 0 {
            super.copy(sender)
        } else {
            copyLine(to: .general, cutting: false)
        }
    }

    override func cut(_ sender: Any?) {
        if selectedRange().length > 0 {
            super.cut(sender)
        } else {
            copyLine(to: .general, cutting: true)
        }
    }

    override func paste(_ sender: Any?) {
        if !pasteLine(from: .general) {
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

    override func keyDown(with event: NSEvent) {
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
            return super.validateUserInterfaceItem(item)
        }
    }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 6), 72)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.font = font

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        defaultParagraphStyle = paragraph
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        if range.length > 0 {
            textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        requestLineRefresh()
    }

    private func apply(_ edit: LineEditing.Edit?) {
        guard let edit, !hasMarkedText() else { return }
        replace(edit.range, with: edit.replacement, selection: edit.selection)
    }

    private func replace(_ range: NSRange, with replacement: String, selection: NSRange? = nil, coalesce: Bool = false) {
        guard isEditable, range.length > 0 || !replacement.isEmpty, let textStorage else { return }
        if !coalesce { breakUndoCoalescing() }
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage.replaceCharacters(in: range, with: replacement)
        let next = selection ?? NSRange(location: range.location + replacement.utf16.count, length: 0)
        setSelectedRange(next)
        didChangeText()
        if !coalesce { breakUndoCoalescing() }
        scrollRangeToVisible(next)
    }

    func textViewDidChangeSelection(_ notification: Notification) { requestLineRefresh() }
    func textDidChange(_ notification: Notification) {
        requestLineRefresh()
        onTextChange?()
    }

    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        requestLineRefresh()
    }

    private func requestLineRefresh() {
        guard !lineRefreshPending else { return }
        lineRefreshPending = true
        // Resolving the caret can request viewport layout. Do it outside the layout callback.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshCurrentLine()
            self.lineRefreshPending = false
        }
    }

    func refreshCurrentLine() {
        let location = NSRange(location: selectedRange().location, length: 0)
        var newLine = NSRect.zero
        if let window, caretIsNearViewport(location.location) {
            let caret = firstRect(forCharacterRange: location, actualRange: nil)
            if caret.height > 0 {
                let local = convert(window.convertFromScreen(caret), from: nil)
                newLine = NSRect(x: bounds.minX, y: local.minY, width: bounds.width, height: local.height)
            } else if textStorage?.length == 0, let font {
                newLine = NSRect(x: bounds.minX, y: textContainerOrigin.y, width: bounds.width,
                                 height: ceil(font.ascender - font.descender + font.leading))
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
    }
}
