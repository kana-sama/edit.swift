import AppKit

final class FindInput: NSView, NSTextViewDelegate {
    let input = FindFieldTextView(frame: .zero)
    private let scroll = NSScrollView()
    private let bezel = NSTextFieldCell(textCell: "")
    private let fieldUndo = UndoManager()
    private let singleLine: Bool
    private let lineHeight: CGFloat
    private let rowHeight: CGFloat
    private lazy var inputHeight = heightAnchor.constraint(equalToConstant: rowHeight)
    var onChange: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    var value: String {
        get { input.string }
        set {
            guard input.string != newValue else { return }
            input.string = newValue
            fieldUndo.removeAllActions()
            updateContents()
        }
    }

    init(name: String, options: [NSButton] = [], singleLine: Bool = false) {
        self.singleLine = singleLine
        let font = EditorTextView.defaultFont
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        rowHeight = max(26, lineHeight + 8)
        super.init(frame: .zero)
        bezel.isBezeled = true
        bezel.bezelStyle = .roundedBezel
        bezel.drawsBackground = true
        focusRingType = .none

        input.placeholder = name
        input.singleLine = singleLine
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.font = font
        input.drawsBackground = false
        input.focusRingType = .none
        input.textContainerInset = NSSize(width: 0, height: (rowHeight - lineHeight) / 2 - 2)
        input.textContainer?.lineFragmentPadding = 0
        input.isVerticallyResizable = !singleLine
        input.isHorizontallyResizable = singleLine
        input.autoresizingMask = singleLine ? [.height] : [.width]
        input.textContainer?.widthTracksTextView = !singleLine
        if singleLine { input.textContainer?.containerSize.width = CGFloat.greatestFiniteMagnitude }
        input.textContainer?.heightTracksTextView = false
        input.textContainer?.containerSize.height = CGFloat.greatestFiniteMagnitude
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.delegate = self
        input.setAccessibilityLabel(name)
        input.onReturn = { [weak self] in self?.onReturn?() }
        input.onEscape = { [weak self] in self?.onEscape?() }
        input.onFocusChange = { [weak self] in self?.needsDisplay = true }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        scroll.documentView = input
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        var trailing = trailingAnchor
        if !options.isEmpty {
            let buttons = NSStackView(views: options)
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 1
            buttons.translatesAutoresizingMaskIntoConstraints = false
            addSubview(buttons)
            for option in options {
                option.widthAnchor.constraint(equalToConstant: 23).isActive = true
                option.heightAnchor.constraint(equalToConstant: 22).isActive = true
            }
            NSLayoutConstraint.activate([
                buttons.centerYAnchor.constraint(equalTo: topAnchor, constant: rowHeight / 2),
                buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ])
            trailing = buttons.leadingAnchor
        }

        NSLayoutConstraint.activate([
            inputHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            scroll.trailingAnchor.constraint(equalTo: trailing, constant: options.isEmpty ? -4 : 0),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        updateContents()
    }

    required init?(coder: NSCoder) { fatalError("Find inputs are programmatically constructed") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            if let window { center.removeObserver(self, name: name, object: window) }
            if let newWindow {
                center.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        bezel.draw(withFrame: bounds, in: self)
        guard window?.isKeyWindow == true, window?.firstResponder === input else { return }

        // Keep the outline inside the shared bezel so clipped redraws of the field and buttons agree.
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        outline.lineWidth = 2
        NSColor.keyboardFocusIndicatorColor.setStroke()
        outline.stroke()
    }

    @objc private func windowFocusChanged(_ notification: Notification) {
        needsDisplay = true
    }

    @objc private func scrollFrameChanged(_ notification: Notification) {
        // Updating field height can trigger a second Auto Layout pass.
        Task { @MainActor [weak self] in self?.updateContents() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { fieldUndo }

    func textDidChange(_ notification: Notification) {
        updateContents()
        onChange?()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        !singleLine || replacementString?.rangeOfCharacter(from: .newlines) == nil
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(input)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(input)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if singleLine { onReturn?() }
            return singleLine
        default:
            return false
        }
    }

    private func updateContents() {
        input.needsDisplay = true
        guard scroll.bounds.width > 0, let manager = input.layoutManager, let container = input.textContainer else { return }
        manager.ensureLayout(for: container)
        if singleLine {
            let minimum = scroll.contentSize
            input.minSize = minimum
            let size = NSSize(width: max(minimum.width, ceil(manager.usedRect(for: container).width) + 1),
                              height: minimum.height)
            if input.frame.size != size { input.setFrameSize(size) }
            return
        }
        let textHeight = max(manager.usedRect(for: container).height, manager.extraLineFragmentUsedRect.maxY)
        let cap = min(5, max(1, Int((window?.contentLayoutRect.height ?? 560) / 105)))
        let newHeight = rowHeight + max(0, min(lineHeight * CGFloat(cap), ceil(textHeight)) - lineHeight)
        if inputHeight.constant != newHeight { inputHeight.constant = newHeight }
    }
}
final class FindFieldTextView: NSTextView {
    var placeholder = ""
    var singleLine = false
    var onFocusChange: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard singleLine, let text = (insertString as? NSAttributedString)?.string ?? insertString as? String,
              text.rangeOfCharacter(from: .newlines) != nil else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        super.insertText(text.components(separatedBy: .newlines).joined(separator: " "), replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        if singleLine, let text = NSPasteboard.general.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        } else {
            super.paste(sender)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 && modifiers.isEmpty {
                onEscape?()
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if modifiers.isEmpty {
                    onReturn?()
                    return
                }
                if modifiers == .shift {
                    if !singleLine { insertNewline(nil) }
                    return
                }
            }
        }
        super.keyDown(with: event)
    }
}
