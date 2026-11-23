import AppKit

@MainActor
final class SourceControlDescriptionPopover: NSObject, NSPopoverDelegate {
    private weak var anchor: NSView?
    private let popover = NSPopover()
    private let text = NSTextView()
    private let title = NSTextField(labelWithString: "Change Description")
    private let notice = NSTextField(wrappingLabelWithString: "The description changed in Jujutsu. Reopen it to edit the current version.")
    private let cancel = NSButton()
    private let apply = NSButton()
    private let onSave: (String) -> Void
    private(set) var draft: JJSourceControlRevision?

    init(anchor: NSView, onSave: @escaping (String) -> Void) {
        self.anchor = anchor
        self.onSave = onSave
        super.init()
        configure()
    }

    func show(_ revision: JJSourceControlRevision) {
        guard let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
        if popover.isShown { popover.close(); return }
        draft = revision
        text.isEditable = !revision.isImmutable
        text.string = revision.description.isEmpty && revision.isImmutable ? "No description" : revision.description
        let string = text.string as NSString
        let newline = string.rangeOfCharacter(from: .newlines).location
        let range = revision.isImmutable ? NSRange(location: 0, length: 0) :
            NSRange(location: 0, length: newline == NSNotFound ? string.length : newline)
        text.setSelectedRange(range)
        cancel.isHidden = revision.isImmutable
        apply.title = revision.isImmutable ? "Done" : "Save"
        update(revision, canMutate: true)
        popover.contentSize = NSSize(width: 402, height: 250)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        text.window?.makeFirstResponder(text)
        text.scrollRangeToVisible(range)
    }

    func update(_ revision: JJSourceControlRevision?, canMutate: Bool) {
        guard let draft else { return }
        guard let revision, revision.changeID == draft.changeID else { close(); return }
        let unchanged = revision.description == draft.description
        notice.isHidden = draft.isImmutable || unchanged
        apply.isEnabled = draft.isImmutable || (canMutate && unchanged && !revision.isImmutable)
    }

    func close() {
        draft = nil
        if popover.isShown { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) { draft = nil }

    @objc private func dismiss(_ sender: Any?) { close() }

    @objc private func save(_ sender: Any?) {
        guard let draft else { return }
        if draft.isImmutable || draft.description.trimmingCharacters(in: .newlines) == text.string.trimmingCharacters(in: .newlines) {
            close()
        } else {
            onSave(text.string)
        }
    }

    private func configure() {
        let root = NSView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 374, height: 160))
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        Self.configureEditor(text, in: scroll)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.isHidden = true
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(dismiss(_:))
        cancel.keyEquivalent = "\u{1b}"
        apply.title = "Save"
        apply.bezelStyle = .rounded
        apply.target = self
        apply.action = #selector(save(_:))
        apply.keyEquivalent = "\r"
        apply.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let heading = NSStackView(views: [title, notice])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5
        for child in [heading, scroll, buttons] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            notice.widthAnchor.constraint(lessThanOrEqualTo: heading.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -13)
        ])
        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    static func configureEditor(_ text: NSTextView, in scroll: NSScrollView) {
        text.isRichText = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.setAccessibilityLabel("Change Description")
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
    }
}
