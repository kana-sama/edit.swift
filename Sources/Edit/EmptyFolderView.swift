import AppKit

@MainActor
final class EmptyFolderView: NSView {
    init() {
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: "No File Open")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        let open = NSTextField(wrappingLabelWithString: "Press ⌘P to open a file.")
        let close = NSTextField(wrappingLabelWithString: "Press ⌘W to close the folder.")
        for hint in [open, close] {
            hint.alignment = .center
            hint.textColor = .secondaryLabelColor
        }

        let content = NSStackView(views: [title, open, close])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 5
        content.setCustomSpacing(10, after: title)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let area = safeAreaLayoutGuide
        let preferredWidth = content.widthAnchor.constraint(equalToConstant: 300)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: area.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: area.trailingAnchor, constant: -16),
            preferredWidth,
            title.widthAnchor.constraint(equalTo: content.widthAnchor),
            open.widthAnchor.constraint(equalTo: content.widthAnchor),
            close.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EmptyFolderView is created in code.") }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
