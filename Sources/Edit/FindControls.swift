import AppKit

final class FindInput: NSView, NSTextViewDelegate {
    let input = FindFieldTextView(frame: .zero)
    private let scroll = NSScrollView()
    private let placeholder: NSTextField
    private let bezel = NSTextFieldCell(textCell: "")
    private let fieldUndo = UndoManager()
    private var inputHeight: NSLayoutConstraint?
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

    init(name: String, options: [NSButton] = []) {
        placeholder = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        bezel.isBezeled = true
        bezel.bezelStyle = .roundedBezel
        bezel.drawsBackground = true
        focusRingType = .none

        let font = EditorTextView.defaultFont
        input.isRichText = false
        input.importsGraphics = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.font = font
        input.drawsBackground = false
        input.focusRingType = .none
        input.textContainerInset = NSSize(width: 0, height: 2)
        input.textContainer?.lineFragmentPadding = 0
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
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

        placeholder.font = font
        placeholder.textColor = .placeholderTextColor
        placeholder.setAccessibilityElement(false)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        // In the native text view so clicking the placeholder still focuses the input.
        input.addSubview(placeholder)

        var trailing = trailingAnchor
        if !options.isEmpty {
            let buttons = NSStackView(views: options)
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 1
            buttons.translatesAutoresizingMaskIntoConstraints = false
            addSubview(buttons)
            NSLayoutConstraint.activate([
                buttons.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ])
            trailing = buttons.leadingAnchor
        }

        let height = heightAnchor.constraint(equalToConstant: 26)
        inputHeight = height
        NSLayoutConstraint.activate([
            height,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            scroll.trailingAnchor.constraint(equalTo: trailing, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 2),
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

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(input)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(input)
            return true
        default:
            return false
        }
    }

    private func updateContents() {
        placeholder.isHidden = !value.isEmpty
        guard let inputHeight, let font = input.font, scroll.bounds.width > 0,
              let manager = input.layoutManager, let container = input.textContainer else { return }
        manager.ensureLayout(for: container)
        let lineHeight = ceil(manager.defaultLineHeight(for: font))
        let textHeight = max(manager.usedRect(for: container).height, manager.extraLineFragmentUsedRect.maxY)
        let cap = min(5, max(1, Int((window?.contentLayoutRect.height ?? 560) / 105)))
        let newHeight = max(26, min(lineHeight * CGFloat(cap), max(lineHeight, ceil(textHeight))) + 10)
        if inputHeight.constant != newHeight { inputHeight.constant = newHeight }
    }
}
final class FindFieldTextView: NSTextView {
    var onFocusChange: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

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
                    insertNewline(nil)
                    return
                }
            }
        }
        super.keyDown(with: event)
    }
}
