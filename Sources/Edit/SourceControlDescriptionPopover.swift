import AppKit

@MainActor
final class SourceControlDescriptionPopover: NSObject, NSPopoverDelegate, @MainActor NSTextContentStorageDelegate {
    private static let inset: CGFloat = 14
    private static let editorHeight: CGFloat = 226
    private static let editorColumns = 72
    private static let subjectLimit = 50
    private static let editorTextWidth = (String(repeating: "0", count: editorColumns) as NSString)
        .size(withAttributes: [.font: EditorTextView.defaultFont]).width

    private weak var anchor: NSView?
    private let popover = NSPopover()
    private let scroll: NSScrollView
    private let text: EditorTextView
    private let layout = NSStackView()
    private let identity = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "The description changed in Jujutsu. Reopen it to edit the current version.")
    private let cancel = NSButton()
    private let apply = NSButton()
    private let onSave: (String) -> Void
    private lazy var viewportWidth = scroll.widthAnchor.constraint(equalToConstant: 0)
    private(set) var draft: JJSourceControlRevision?
    private var pendingOpen: JJSourceControlRevision?

    init(anchor: NSView, onSave: @escaping (String) -> Void) {
        self.anchor = anchor
        self.onSave = onSave
        (scroll, text) = EditorTextView.scrollingEditor(
            in: NSRect(x: 0, y: 0, width: ceil(Self.editorTextWidth), height: Self.editorHeight)
        )
        super.init()
        configure()
    }

    func show(_ revision: JJSourceControlRevision) {
        guard let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
        if popover.isShown {
            // AppKit still reports the popover as shown during its closing animation.
            if draft == nil { pendingOpen = revision }
            else { close() }
            return
        }

        draft = revision
        let readOnly = revision.isImmutable
        text.resetMultiCarets()
        text.isEditable = !readOnly
        text.string = readOnly && revision.description.isEmpty ? "No description" : revision.description
        text.undoManager?.removeAllActions()
        identity.stringValue = readOnly ? "\(revision.shortID)  ·  Read-only" : revision.shortID
        counter.isHidden = readOnly && revision.description.isEmpty
        updateCounter()
        cancel.isHidden = readOnly
        apply.title = readOnly ? "Done" : "Save"
        apply.keyEquivalent = readOnly ? "\u{1b}" : "\r"
        apply.keyEquivalentModifierMask = readOnly ? [] : .command
        update(revision, canMutate: true)
        fitContent()

        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        text.window?.makeFirstResponder(text)
        let length = readOnly ? 0 : Self.subject(in: text.string).utf16.count
        text.setSelectedRange(NSRange(location: 0, length: length))
        scroll.scrollToVisibleContentOrigin(.zero)
    }

    func update(_ revision: JJSourceControlRevision?, canMutate: Bool) {
        if let pendingOpen {
            self.pendingOpen = revision?.changeID == pendingOpen.changeID ? revision : nil
        }
        guard let draft else { return }
        guard let revision, revision.changeID == draft.changeID else { close(); return }
        let unchanged = revision.description == draft.description
        let showNotice = !draft.isImmutable && !unchanged
        if notice.isHidden == showNotice {
            notice.isHidden = !showNotice
            if popover.isShown { fitContent() }
        }
        apply.isEnabled = draft.isImmutable || (canMutate && unchanged && !revision.isImmutable)
        apply.bezelColor = apply.isEnabled && !draft.isImmutable ? .controlAccentColor : nil
    }

    func close() {
        pendingOpen = nil
        guard draft != nil else { return }
        draft = nil
        if popover.isShown { popover.close() }
    }

    func popoverWillClose(_ notification: Notification) { draft = nil }

    func popoverDidClose(_ notification: Notification) {
        guard let pendingOpen else { return }
        self.pendingOpen = nil
        show(pendingOpen)
    }

    private static func subject(in string: String) -> Substring {
        string.prefix(while: { !$0.isNewline })
    }

    // Style the TextKit paragraph while keeping the editor buffer and its undo history plain.
    func textContentStorage(_ contentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard range.location == 0, range.length > 0, let storage = contentStorage.textStorage else { return nil }
        if let draft, draft.isImmutable, draft.description.isEmpty { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let subject = Self.subject(in: paragraph.string)
        guard !subject.isEmpty else { return nil }
        let emphasizedLength = subject.prefix(Self.subjectLimit).utf16.count
        let subjectLength = subject.utf16.count
        let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? EditorTextView.defaultFont
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        paragraph.addAttribute(.font, value: bold, range: NSRange(location: 0, length: emphasizedLength))
        if subjectLength > emphasizedLength {
            paragraph.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                   range: NSRange(location: emphasizedLength, length: subjectLength - emphasizedLength))
        }
        return NSTextParagraph(attributedString: paragraph)
    }

    @objc private func dismiss(_ sender: Any?) { close() }

    @objc private func save(_ sender: Any?) {
        guard let draft else { return }
        if draft.isImmutable || draft.description.trimmingCharacters(in: .newlines) == text.string.trimmingCharacters(in: .newlines) {
            close()
        } else {
            onSave(text.string)
        }
    }

    private func updateCounter() {
        let count = Self.subject(in: text.string).count
        counter.stringValue = "Subject  \(count) / \(Self.subjectLimit)"
        counter.setAccessibilityLabel("Subject length, \(count) of \(Self.subjectLimit) characters")
        counter.textColor = count > Self.subjectLimit ? .systemRed : .secondaryLabelColor
    }

    private func fitContent() {
        let padding = text.textContainerInset.width + (text.textContainer?.lineFragmentPadding ?? 0)
        let viewport = NSSize(width: ceil(Self.editorTextWidth + 2 * padding), height: Self.editorHeight)
        let frame = NSScrollView.frameSize(
            forContentSize: viewport, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: scroll.borderType, controlSize: .regular, scrollerStyle: scroll.scrollerStyle
        )
        viewportWidth.constant = frame.width
        notice.preferredMaxLayoutWidth = frame.width
        let fitted = layout.fittingSize
        let size = NSSize(width: ceil(fitted.width), height: ceil(fitted.height))
        popover.contentSize = size
        if !popover.isShown { popover.contentViewController?.view.setFrameSize(size) }
    }

    private func configure() {
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        text.isHorizontallyResizable = false
        text.minSize.height = Self.editorHeight
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 9, height: 9)
        text.setAccessibilityLabel("Change Description")
        (text.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = self
        text.onTextChange = { [weak self] in self?.updateCounter() }

        let title = NSTextField(labelWithString: "Change Description")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        identity.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        identity.textColor = .secondaryLabelColor
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .systemOrange
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

        let header = NSStackView(views: [title, NSView(), identity])
        header.alignment = .centerY
        header.spacing = 10
        let footer = NSStackView(views: [counter, NSView(), cancel, apply])
        footer.alignment = .centerY
        footer.spacing = 8
        layout.orientation = .vertical
        layout.alignment = .width
        layout.spacing = 10
        layout.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        for child in [header, scroll, notice, footer] { layout.addArrangedSubview(child) }
        viewportWidth.isActive = true
        scroll.heightAnchor.constraint(equalToConstant: Self.editorHeight).isActive = true
        let root = NSView()
        root.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        fitContent()
    }

#if EDIT_AGENT_CHECKS
    var checkView: NSView { popover.contentViewController!.view }
#endif
}
