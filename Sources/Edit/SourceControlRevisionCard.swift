import AppKit

@MainActor
final class SourceControlRevisionCard: NSView, NSTextViewDelegate {
    private static let cardWidth: CGFloat = 332
    private static let inset: CGFloat = 14
    private static let textWidth = cardWidth - 2 * inset
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let markdownLink = try? NSRegularExpression(pattern: #"\[([^\]\r\n]+)\]\((https?://(?:[^\s()]|\([^\s()]*\))+)\)"#,
                                                               options: .caseInsensitive)
    private let openURL: (URL) -> Void
    private let commitButton = NSButton()
    private var commitLink: JJSourceControlCommitLink?

    init(revision: JJSourceControlRevision, onOpenURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        openURL = onOpenURL
        super.init(frame: .zero)
        let subject = textView(revision.subject, id: "Subject", font: .systemFont(ofSize: 14, weight: .semibold), lines: 2)

        let dates = Self.label(Self.creationDates(for: revision).joined(separator: "\n"), id: "Dates",
                               font: .systemFont(ofSize: 11), lines: 3)
        let metadata = Self.stack()
        metadata.spacing = 3
        if !revision.author.isEmpty {
            let name = revision.authorEmail.isEmpty || revision.author == revision.authorEmail
                ? revision.author : "\(revision.author) (\(revision.authorEmail))"
            let author = Self.label(name, id: "Author", font: .systemFont(ofSize: 11, weight: .medium),
                                    lines: 2, width: Self.textWidth - 18)
            let authorRow = NSStackView(views: [Self.icon("person.crop.circle", color: .secondaryLabelColor), author])
            authorRow.spacing = 5
            authorRow.alignment = .centerY
            metadata.addArrangedSubview(authorRow)
        }
        metadata.addArrangedSubview(dates)

        let identity = SourceControlRevisionIdentity()
        identity.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionCardID")
        identity.update(revision, showsAuthor: false, showsAllStatuses: true)
        identity.isChangeIDSelectable = true
        identity.toolTip = nil
        commitButton.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionCardOpenCommit")
        commitButton.target = self
        commitButton.action = #selector(openCommit)
        commitButton.isBordered = false
        commitButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        commitButton.imagePosition = .imageTrailing
        commitButton.imageHugsTitle = true
        commitButton.contentTintColor = .linkColor
        commitButton.heightAnchor.constraint(equalToConstant: identity.intrinsicContentSize.height).isActive = true
        commitButton.isHidden = true
        let footer = NSStackView(views: [identity, NSView(), commitButton])
        footer.spacing = 8
        footer.alignment = .centerY
        footer.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true

        let content = Self.stack()
        content.spacing = 10
        content.addArrangedSubview(subject)
        content.setCustomSpacing(5, after: subject)
        content.addArrangedSubview(metadata)
        if let body = Self.body(of: revision.description) {
            content.addArrangedSubview(textView(body, id: "Description", font: .systemFont(ofSize: 12), lines: 8))
        }

        let separator = NSBox()
        separator.boxType = .separator
        content.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: Self.textWidth).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        content.setCustomSpacing(8, after: separator)
        if !revision.bookmarks.isEmpty {
            let bookmarks = Self.label(revision.bookmarks.joined(separator: "  ·  "), id: "Bookmarks",
                                       font: .systemFont(ofSize: 11, weight: .medium), color: .linkColor,
                                       lines: 3, width: Self.textWidth - 18)
            let bookmarkRow = NSStackView(views: [Self.icon("bookmark", color: .linkColor), bookmarks])
            bookmarkRow.spacing = 5
            bookmarkRow.alignment = .top
            content.addArrangedSubview(bookmarkRow)
            content.setCustomSpacing(7, after: bookmarkRow)
        }
        content.addArrangedSubview(footer)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Revision cards are created in code.") }

    func setCommitLink(_ link: JJSourceControlCommitLink?) {
        commitLink = link
        commitButton.isHidden = link == nil
        guard let link else { return }
        commitButton.attributedTitle = NSAttributedString(string: "Open on \(link.hostName)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.linkColor,
        ])
    }

    @objc private func openCommit() {
        if let url = commitLink?.url { openURL(url) }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, Self.isWebURL(url) { openURL(url) }
        return true
    }

    static func creationDates(for revision: JJSourceControlRevision) -> [String] {
        let style = Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute().second()
        let author = revision.authorDate.formatted(style)
        if revision.authorDate == revision.committerDate { return ["Created · \(author)"] }

        let committer = revision.committerDate.formatted(style)
        if author == committer {
            let precise = style.secondFraction(.fractional(3))
            return ["Change created · \(revision.authorDate.formatted(precise))",
                    "Commit created · \(revision.committerDate.formatted(precise))"]
        }
        return ["Change created · \(author)", "Commit created · \(committer)"]
    }

    private static func body(of description: String) -> String? {
        guard let subjectEnd = description.firstIndex(where: \.isNewline) else { return nil }
        var body = description[description.index(after: subjectEnd)...]
        if body.first?.isNewline == true { body = body.dropFirst() }
        while body.last?.isNewline == true { body = body.dropLast() }
        guard body.contains(where: { !$0.isWhitespace }) else { return nil }
        return String(body)
    }

    private static func stack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        return stack
    }

    private static func label(_ text: String, id: String, font: NSFont, color: NSColor = .labelColor,
                              lines: Int, width: CGFloat = textWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionCard\(id)")
        label.font = font
        label.textColor = color
        label.preferredMaxLayoutWidth = width
        label.maximumNumberOfLines = lines
        label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = true
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = CGFloat(lines) * lineHeight + 2
        label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        label.heightAnchor.constraint(lessThanOrEqualToConstant: height).isActive = true
        return label
    }

    private func textView(_ text: String, id: String, font: NSFont, lines: Int) -> NSTextView {
        let formatted = Self.linkedText(text, font: font)
        let view = SourceControlRevisionCardText(formatted, width: Self.textWidth, lines: lines)
        view.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionCard\(id)")
        view.delegate = self
        return view
    }

    private static func linkedText(_ text: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let source = text as NSString
        let markdown = markdownLink?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []
        for match in markdown.reversed() {
            guard let url = URL(string: source.substring(with: match.range(at: 2))), isWebURL(url) else { continue }
            let title = source.substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: NSAttributedString(string: title, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .link: url,
            ]))
        }

        let detectedLinks = linkDetector?.matches(in: result.string, range: NSRange(location: 0, length: result.length)) ?? []
        for match in detectedLinks {
            guard let url = match.url, isWebURL(url),
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            result.addAttribute(.link, value: url, range: match.range)
        }
        return result
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func icon(_ name: String, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        view.widthAnchor.constraint(equalToConstant: 13).isActive = true
        view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return view
    }
}

@MainActor
private final class SourceControlRevisionCardText: NSTextView {
    private let storage: NSTextStorage
    private var measuredSize = NSSize.zero

    init(_ text: NSAttributedString, width: CGFloat, lines: Int) {
        storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0), textContainer: container)
        textContainerInset = .zero
        drawsBackground = false
        isEditable = false
        isSelectable = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        displaysLinkToolTips = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        manager.ensureLayout(for: container)
        measuredSize = NSSize(width: width, height: ceil(manager.usedRect(for: container).height))
        invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) { fatalError("Revision card text views are created in code.") }

    override var intrinsicContentSize: NSSize { measuredSize }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
