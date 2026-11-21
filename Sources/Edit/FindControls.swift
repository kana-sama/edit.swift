import AppKit

final class FindInput: NSScrollView, NSTextViewDelegate {
    private(set) var input: NSTextView!
    private var inputHeight: NSLayoutConstraint?
    var onChange: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    var value: String {
        get { input.string }
        set {
            input.string = newValue
            adjustHeight()
        }
    }

    init(name: String) {
        super.init(frame: .zero)
        borderType = .bezelBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasVerticalScroller = false

        let view = FindFieldTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 4, height: 2)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize.height = CGFloat.greatestFiniteMagnitude
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = self
        view.setAccessibilityLabel(name)
        view.onReturn = { [weak self] in self?.onReturn?() }
        view.onEscape = { [weak self] in self?.onEscape?() }
        documentView = view
        input = view

        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: 25)
        height.isActive = true
        inputHeight = height
    }

    required init?(coder: NSCoder) { fatalError("Find inputs are programmatically constructed") }

    func textDidChange(_ notification: Notification) {
        adjustHeight()
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

    override func tile() {
        super.tile()
        adjustHeight()
    }

    private func adjustHeight() {
        guard let input, let inputHeight, let font = input.font,
              let manager = input.layoutManager, let container = input.textContainer else { return }
        manager.ensureLayout(for: container)
        let lineHeight = ceil(manager.defaultLineHeight(for: font))
        let textHeight = max(manager.usedRect(for: container).height, manager.extraLineFragmentUsedRect.maxY)
        let cap = min(5, max(1, Int((window?.contentLayoutRect.height ?? 560) / 105)))
        let newHeight = min(lineHeight * CGFloat(cap), max(lineHeight, ceil(textHeight))) + 8
        if inputHeight.constant != newHeight { inputHeight.constant = newHeight }
    }
}

private final class FindFieldTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

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

final class FindResultsTable: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 {
                if !event.isARepeat { onReturn?() }
                return
            }
            if event.keyCode == 53 {
                onEscape?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

final class FindResultCell: NSTableCellView {
    private let excerpt = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private let applyButton = NSButton(image: NSImage(systemSymbolName: "arrow.turn.down.right",
                                                        accessibilityDescription: nil)!,
                                             target: nil, action: nil)
    private let dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                                         target: nil, action: nil)
    private var hover = false
    private var selected = false
    private var acceptsActions = false
    private var tracking: NSTrackingArea?
    private var excerptEnd: NSLayoutConstraint?
    private var excerptBeforeActions: NSLayoutConstraint?
    private var onApply: (() -> Void)?
    private var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        excerpt.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (button, label, action) in [
            (applyButton, "Replace This Match", #selector(applyMatch(_:))),
            (dismissButton, "Dismiss This Match", #selector(dismissMatch(_:))),
        ] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        }
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 1
        actions.addArrangedSubview(applyButton)
        actions.addArrangedSubview(dismissButton)
        excerpt.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(excerpt)
        addSubview(actions)
        let end = excerpt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        excerptEnd = end
        excerptBeforeActions = excerpt.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            excerpt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            excerpt.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            end,
        ])
    }

    required init?(coder: NSCoder) { fatalError("Find result cells are programmatically constructed") }

    func configure(
        text: NSAttributedString, replacementAvailable: Bool, acceptsActions: Bool,
        selected: Bool, apply: @escaping () -> Void, dismiss: @escaping () -> Void
    ) {
        excerpt.attributedStringValue = text
        setAccessibilityLabel(excerpt.stringValue)
        self.acceptsActions = acceptsActions
        applyButton.isHidden = !replacementAvailable
        onApply = apply
        onDismiss = dismiss
        updateSelection(selected)
    }

    func updateSelection(_ selected: Bool) {
        self.selected = selected
        updateActions()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hover = true; updateActions() }
    override func mouseExited(with event: NSEvent) { hover = false; updateActions() }

    private func updateActions() {
        let show = acceptsActions && (hover || selected)
        actions.isHidden = !show
        if show {
            excerptEnd?.isActive = false
            excerptBeforeActions?.isActive = true
        } else {
            excerptBeforeActions?.isActive = false
            excerptEnd?.isActive = true
        }
    }

    @objc private func applyMatch(_ sender: Any?) { onApply?() }
    @objc private func dismissMatch(_ sender: Any?) { onDismiss?() }
}
