import AppKit

@MainActor
final class WorkspaceFindField: NSView, NSTextFieldDelegate {
    let input = NSTextField()
    private let bezel = NSTextFieldCell(textCell: "")
    var changed: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    init(label: String, name: String, option: NSButton? = nil) {
        super.init(frame: .zero)
        bezel.isBezeled = true
        bezel.bezelStyle = .roundedBezel
        bezel.drawsBackground = true
        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.setAccessibilityElement(false)
        caption.widthAnchor.constraint(equalToConstant: 20).isActive = true
        caption.setContentCompressionResistancePriority(.required, for: .horizontal)
        input.isBezeled = false
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.usesSingleLineMode = true
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.font = EditorTextView.defaultFont
        input.delegate = self
        input.setAccessibilityLabel(name)
        toolTip = "Enter workspace-relative paths or glob patterns separated by commas."
        input.toolTip = name + ". " + (toolTip ?? "")
        let stack = NSStackView(views: [caption, input] + (option.map { [$0] } ?? []))
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 23),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        bezel.draw(withFrame: bounds, in: self)
        guard window?.isKeyWindow == true, input.currentEditor() != nil else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        outline.lineWidth = 2
        NSColor.keyboardFocusIndicatorColor.setStroke()
        outline.stroke()
    }

    func controlTextDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidChange(_ notification: Notification) { changed?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): onReturn?(); return true
        case #selector(NSResponder.cancelOperation(_:)): onEscape?(); return true
        default: return false
        }
    }
}

@MainActor
final class WorkspaceFindTable: SidebarActionResultTable {
    var canUndoChanges: ((Bool) -> Bool)?
    var onUndoChanges: ((Bool) -> Void)?

    @objc func undo(_ sender: Any?) { onUndoChanges?(false) }
    @objc func redo(_ sender: Any?) { onUndoChanges?(true) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndoChanges?(false) == true }
        if item.action == #selector(redo(_:)) { return canUndoChanges?(true) == true }
        return super.validateUserInterfaceItem(item)
    }
}
