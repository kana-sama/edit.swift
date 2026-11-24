import AppKit

@MainActor
final class SourceControlRevisionCard: NSView {
    private static let cardWidth: CGFloat = 332
    private static let inset: CGFloat = 14
    private static let textWidth = cardWidth - 2 * inset

    init(revision: JJSourceControlRevision) {
        super.init(frame: .zero)
        let subject = Self.label(revision.subject, id: "Subject", font: .systemFont(ofSize: 14, weight: .semibold), lines: 2)

        let dates = Self.label(Self.creationDates(for: revision).joined(separator: "\n"), id: "Dates",
                               font: .systemFont(ofSize: 11), lines: 3)
        let metadata = Self.stack()
        metadata.spacing = 3
        if !revision.author.isEmpty {
            let author = Self.label(revision.author, id: "Author", font: .systemFont(ofSize: 11, weight: .medium),
                                    lines: 1, width: Self.textWidth - 18)
            let authorRow = NSStackView(views: [Self.icon("person.crop.circle", color: .secondaryLabelColor), author])
            authorRow.spacing = 5
            authorRow.alignment = .centerY
            metadata.addArrangedSubview(authorRow)
        }
        metadata.addArrangedSubview(dates)

        let identity = SourceControlRevisionIdentity()
        identity.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionCardID")
        identity.update(revision, showsAuthor: false)
        identity.toolTip = nil
        let statuses = [revision.isWorkingCopy ? "Working copy" : nil, revision.isImmutable ? "Immutable" : nil,
                        revision.isConflicted ? "Conflict" : nil, revision.isDivergent ? "Divergent" : nil].compactMap { $0 }
        let footer = NSStackView(views: [identity])
        footer.spacing = 8
        footer.alignment = .centerY
        if !statuses.isEmpty {
            let status = NSTextField(labelWithString: statuses.joined(separator: " · "))
            status.font = .systemFont(ofSize: 11)
            status.textColor = .labelColor
            status.lineBreakMode = .byTruncatingTail
            footer.addArrangedSubview(status)
        }

        let content = Self.stack()
        content.spacing = 10
        content.addArrangedSubview(subject)
        content.setCustomSpacing(5, after: subject)
        content.addArrangedSubview(metadata)
        if let body = Self.body(of: revision.description) {
            content.addArrangedSubview(Self.label(body, id: "Description", font: .systemFont(ofSize: 12), lines: 8))
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
        label.isSelectable = false
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let height = CGFloat(lines) * lineHeight + 2
        label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        label.heightAnchor.constraint(lessThanOrEqualToConstant: height).isActive = true
        return label
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
