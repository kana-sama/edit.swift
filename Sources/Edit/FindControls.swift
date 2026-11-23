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

final class FindResultsScrollView: NSScrollView {
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        (documentView as? FindResultsTable)?.refreshHover()
    }
}

final class FindResultsTable: NSTableView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    var onClickSelectedRow: ((Int) -> Void)?
    private var pointerTracking: NSTrackingArea?
    private var hoveredRow = -1
    private weak var hoveredCell: FindResultCell?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        updateHover(at: nil)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            if let window { center.removeObserver(self, name: name, object: window) }
            if let newWindow {
                center.addObserver(self, selector: #selector(refreshHover), name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if pointerTracking == nil {
            let tracking = NSTrackingArea(rect: .zero,
                                          options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                          owner: self, userInfo: nil)
            addTrackingArea(tracking)
            pointerTracking = tracking
        }
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }

    @objc func refreshHover() {
        guard let window, window.isKeyWindow else {
            updateHover(at: nil)
            return
        }
        updateHover(at: window.mouseLocationOutsideOfEventStream)
    }

    func configureHover(for cell: FindResultCell, row: Int) {
        let hovered = hoveredRow == row
        if hovered, hoveredCell !== cell {
            hoveredCell?.updateHover(false)
            hoveredCell = cell
        }
        cell.updateHover(hovered)
    }

    private func updateHover(at location: NSPoint?) {
        let row = location.flatMap { location -> Int? in
            let local = convert(location, from: nil)
            return !isHiddenOrHasHiddenAncestor && visibleRect.contains(local) ? self.row(at: local) : nil
        } ?? -1
        if hoveredRow != row {
            hoveredCell?.updateHover(false)
            hoveredCell = nil
            hoveredRow = row
        }
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? FindResultCell {
            configureHover(for: cell, row: row)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        let clickedSelection = clicked >= 0 && clicked == selectedRow
        super.mouseDown(with: event)

        // A repeated click on the selected row does not notify the selection delegate.
        guard clickedSelection, selectedRow == clicked, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
        onClickSelectedRow?(clicked)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 {
                if !event.isARepeat { onReturn?() }
                return
            }
            if event.keyCode == 49 {
                if !event.isARepeat { onSpace?() }
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

final class FindResultRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 8, yRadius: 8).fill()
    }
}

final class FindResultCell: NSTableCellView {
    private let excerpt = NSTextField(labelWithString: "")
    private static let actionSize: CGFloat = 20
    private static let actionSpacing: CGFloat = 1
    // The button's hit area extends beyond its glyph. Let the excerpt use that transparent leading edge.
    private static let excerptOverlap: CGFloat = 1
    private let applyButton = NSButton(image: NSImage(systemSymbolName: "arrow.turn.down.right",
                                                        accessibilityDescription: nil)!,
                                             target: nil, action: nil)
    private let dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                                         target: nil, action: nil)
    private var hover = false
    private var selected = false
    private var acceptsActions = false
    private var replacementAvailable = false
    private lazy var excerptBeforeDismiss = excerpt.trailingAnchor.constraint(
        equalTo: dismissButton.leadingAnchor, constant: Self.excerptOverlap
    )
    private lazy var excerptBeforeApply = excerpt.trailingAnchor.constraint(
        equalTo: applyButton.leadingAnchor, constant: Self.excerptOverlap
    )
    private var onApply: (() -> Void)?
    private var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        excerpt.allowsEditingTextAttributes = true
        excerpt.maximumNumberOfLines = 1
        excerpt.cell?.usesSingleLineMode = true
        excerpt.cell?.wraps = false
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        excerpt.setContentHuggingPriority(.defaultLow, for: .horizontal)

        excerpt.translatesAutoresizingMaskIntoConstraints = false
        addSubview(excerpt)
        for (button, label, action) in [
            (applyButton, "Replace This Match", #selector(applyMatch(_:))),
            (dismissButton, "Dismiss This Match", #selector(dismissMatch(_:))),
        ] {
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.actionSize),
                button.heightAnchor.constraint(equalToConstant: Self.actionSize),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            excerpt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            excerpt.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            excerpt.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            applyButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -Self.actionSpacing),
            excerptBeforeDismiss,
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
        // Keep the same text column whether the row actions are currently visible or hidden.
        if self.replacementAvailable != replacementAvailable {
            (self.replacementAvailable ? excerptBeforeApply : excerptBeforeDismiss).isActive = false
            (replacementAvailable ? excerptBeforeApply : excerptBeforeDismiss).isActive = true
            self.replacementAvailable = replacementAvailable
        }
        onApply = apply
        onDismiss = dismiss
        updateSelection(selected)
    }

    func updateSelection(_ selected: Bool) {
        self.selected = selected
        updateActions()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hover = false
        selected = false
        acceptsActions = false
        updateActions()
    }

    func updateHover(_ hovered: Bool) {
        guard hover != hovered else { return }
        hover = hovered
        updateActions()
    }

    private func updateActions() {
        let showDismiss = acceptsActions && (hover || selected)
        let showApply = showDismiss && replacementAvailable
        dismissButton.isHidden = !showDismiss
        applyButton.isHidden = !showApply
    }

    @objc private func applyMatch(_ sender: Any?) { onApply?() }
    @objc private func dismissMatch(_ sender: Any?) { onDismiss?() }
}
