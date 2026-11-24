import AppKit

@MainActor
final class SourceControlRevisionCard: NSView, NSTextViewDelegate {
    private static let cardWidth: CGFloat = 332
    private static let inset: CGFloat = 14
    private static let textWidth = cardWidth - 2 * inset
    private static let descriptionColor = NSColor(name: nil) { appearance in
        var color = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance {
            if let label = NSColor.labelColor.usingColorSpace(.sRGB) {
                color = label.withAlphaComponent(label.alphaComponent * 0.82)
            }
        }
        return color
    }
    private let openURL: (URL) -> Void
    private let commitButton = NSButton()
    private var commitLink: JJSourceControlCommitLink?

    init(revision: JJSourceControlRevision, onOpenURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        openURL = onOpenURL
        super.init(frame: .zero)
        let subject = textView(RevisionCardMessage.subject(revision.subject), id: "Subject")
        let description = RevisionCardMessage.parts(revision.description)
        let metadata = makeMetadata(revision, trailers: description.trailers)

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
        if let body = description.body {
            let formatted = RevisionCardMessage.body(body, width: Self.textWidth, color: Self.descriptionColor)
            content.addArrangedSubview(textView(formatted, id: "Description"))
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
        if let url = link as? URL, RevisionCardMessage.canOpen(url) { openURL(url) }
        return true
    }

    static func creationDates(for revision: JJSourceControlRevision) -> [String] {
        dateRows(for: revision).map { "\($0.label) · \($0.value)" }
    }

    private static func dateRows(for revision: JJSourceControlRevision) -> [(label: String, value: String)] {
        let style = Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute().second()
        let author = revision.authorDate.formatted(style)
        if revision.authorDate == revision.committerDate { return [("Created", author)] }

        let committer = revision.committerDate.formatted(style)
        if author == committer {
            let precise = style.secondFraction(.fractional(3))
            return [("Created", revision.authorDate.formatted(precise)), ("Modified", revision.committerDate.formatted(precise))]
        }
        return [("Created", author), ("Modified", committer)]
    }

    private func makeMetadata(_ revision: JJSourceControlRevision, trailers: [RevisionCardMessage.Trailer]) -> NSGridView {
        var rows: [(label: String, value: String)] = []
        let name = revision.author
        let email = revision.authorEmail
        if !name.isEmpty || !email.isEmpty {
            let author = Self.formattedAuthor(name, email: email)
            rows.append(("Author", author))
        }
        rows += trailers.filter(\.isCoauthor).map { ("Co-author", $0.value) }
        rows += Self.dateRows(for: revision)
        rows += trailers.filter { !$0.isCoauthor }.map { ($0.label, $0.value) }

        let labels = rows.map { row in
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
            return label
        }
        let labelWidth = min(112, ceil(labels.map { $0.intrinsicContentSize.width }.max() ?? 0))
        let spacing: CGFloat = 12
        let valueWidth = Self.textWidth - labelWidth - spacing
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let fields: [[NSView]] = zip(labels, rows).map { label, row in
            let singleLine = row.value.split(whereSeparator: \.isNewline).joined(separator: " ")
            let formatted = NSMutableAttributedString(string: singleLine, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
            RevisionCardMessage.addLinks(to: formatted)
            let value = textView(formatted, id: row.label, width: valueWidth, singleLine: true)
            value.setAccessibilityLabel("\(row.label), \(formatted.string)")
            return [label, value]
        }
        let grid = NSGridView(views: fields)
        grid.columnSpacing = spacing
        grid.rowSpacing = 3
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .fill
        grid.column(at: 0).width = labelWidth
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = valueWidth
        return grid
    }

    private static func formattedAuthor(_ name: String, email: String) -> String {
        if name.isEmpty || name == email { return email }
        return email.isEmpty ? name : "\(name) \(email)"
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

    private func textView(_ text: NSAttributedString, id: String, width: CGFloat = textWidth, singleLine: Bool = false) -> NSTextView {
        let view = SourceControlRevisionCardText(text, width: width, singleLine: singleLine)
        view.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionCard\(id)")
        view.delegate = self
        return view
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
private enum RevisionCardMessage {
    struct Trailer {
        let label: String
        let value: String

        var isCoauthor: Bool { label.caseInsensitiveCompare("Co-authored-by") == .orderedSame }
    }

    private struct ListMarker {
        let indent: Int
        let label: String
        let width: CGFloat
        let numberColumn: Int?
    }

    private static let trailer = try? NSRegularExpression(
        pattern: #"^([A-Za-z0-9-]+|BREAKING CHANGE)[ \t]*:[ \t]+(\S.*)$"#, options: .caseInsensitive
    )
    private static let listItem = try? NSRegularExpression(pattern: #"^[ \t]*([-*]|[0-9]+\.)[ \t]+(\S.*)$"#)
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let markdownLink = try? NSRegularExpression(
        pattern: #"\[([^\]\r\n]+)\]\(((?:https?://|mailto:)(?:[^\s()]|\([^\s()]*\))+)\)"#, options: .caseInsensitive
    )

    static func parts(_ description: String) -> (body: String?, trailers: [Trailer]) {
        guard let subjectEnd = description.firstIndex(where: \.isNewline) else { return (nil, []) }
        var body = description[description.index(after: subjectEnd)...]
        if body.first?.isNewline == true { body = body.dropFirst() }
        var lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }

        var bodyEnd = lines.endIndex
        var trailers: [Trailer] = []
        for index in lines.indices.reversed() {
            let line = String(lines[index])
            if line.allSatisfy(\.isWhitespace) { break }
            let source = line as NSString
            let range = NSRange(location: 0, length: source.length)
            // An indented continuation belongs to the preceding trailer, if there is one.
            if line.first?.isWhitespace == true {
                if listItem?.firstMatch(in: line, range: range) != nil { break }
                continue
            }
            guard let match = trailer?.firstMatch(in: line, range: range) else { break }
            let label = source.substring(with: match.range(at: 1))
            let firstLine = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let continued = lines[(index + 1)..<bodyEnd].map { $0.trimmingCharacters(in: .whitespaces) }
            trailers.append(Trailer(label: label, value: ([firstLine] + continued).joined(separator: "\n")))
            bodyEnd = index
        }
        while bodyEnd > 0 && lines[bodyEnd - 1].allSatisfy(\.isWhitespace) { bodyEnd -= 1 }
        return (bodyEnd == 0 ? nil : lines[..<bodyEnd].joined(separator: "\n"), Array(trailers.reversed()))
    }

    static func subject(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        addLinks(to: result)
        return result
    }

    static func body(_ text: String, width: CGFloat, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let markerGap: CGFloat = 4
        var paragraphs: [(content: String, marker: ListMarker?)] = []
        var numberWidths: [CGFloat] = []
        var openNumberedLists: [(indent: Int, column: Int)] = []
        for line in text.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let source = line as NSString
            guard let match = listItem?.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
                let content = line.trimmingCharacters(in: .whitespaces)
                if content.isEmpty {
                    paragraphs.append(("", nil))
                } else if let marker = paragraphs.last?.marker, indent > marker.indent {
                    paragraphs[paragraphs.count - 1].content += " " + content
                } else {
                    openNumberedLists.removeAll()
                    paragraphs.append((line, nil))
                }
                continue
            }
            let token = source.substring(with: match.range(at: 1))
            let numbered = token.hasSuffix(".")
            let label = numbered ? token : (indent == 0 ? "•" : "◦")
            let markerWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
            guard listInset(indent, width: width) + markerWidth + markerGap < width / 2 else {
                openNumberedLists.removeAll()
                paragraphs.append((line, nil))
                continue
            }
            while let last = openNumberedLists.last, last.indent > indent || (!numbered && last.indent == indent) {
                openNumberedLists.removeLast()
            }
            var numberColumn: Int?
            if numbered {
                if let last = openNumberedLists.last, last.indent == indent {
                    numberColumn = last.column
                    numberWidths[last.column] = max(numberWidths[last.column], markerWidth)
                } else {
                    numberColumn = numberWidths.count
                    openNumberedLists.append((indent, numberWidths.count))
                    numberWidths.append(markerWidth)
                }
            }
            paragraphs.append((source.substring(with: match.range(at: 2)),
                               ListMarker(indent: indent, label: label, width: markerWidth, numberColumn: numberColumn)))
        }

        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let ending = index == paragraphs.count - 1 ? "" : "\n"
            guard let marker = paragraph.marker else {
                result.append(NSAttributedString(string: paragraph.content + ending, attributes: attributes))
                continue
            }
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = listInset(marker.indent, width: width)
            let markerRight = style.firstLineHeadIndent + (marker.numberColumn.map { numberWidths[$0] } ?? marker.width)
            style.headIndent = markerRight + markerGap
            let textTab = NSTextTab(textAlignment: .left, location: style.headIndent)
            let prefix: String
            if marker.numberColumn != nil {
                style.tabStops = [NSTextTab(textAlignment: .right, location: markerRight), textTab]
                prefix = "\t\(marker.label)\t"
            } else {
                style.tabStops = [textTab]
                prefix = "\(marker.label)\t"
            }
            var itemAttributes = attributes
            itemAttributes[.paragraphStyle] = style
            result.append(NSAttributedString(string: prefix + paragraph.content + ending, attributes: itemAttributes))
        }
        addLinks(to: result)
        return result
    }

    private static func listInset(_ indent: Int, width: CGFloat) -> CGFloat {
        min(CGFloat(indent) * 3, width / 6)
    }

    static func addLinks(to text: NSMutableAttributedString) {
        let source = text.string as NSString
        let markdown = markdownLink?.matches(in: text.string, range: NSRange(location: 0, length: source.length)) ?? []
        for match in markdown.reversed() {
            guard let url = URL(string: source.substring(with: match.range(at: 2))), canOpen(url) else { continue }
            var attributes = text.attributes(at: match.range.location, effectiveRange: nil)
            attributes[.link] = url
            let title = source.substring(with: match.range(at: 1))
            text.replaceCharacters(in: match.range, with: NSAttributedString(string: title, attributes: attributes))
        }
        let rendered = text.string as NSString
        let links = linkDetector?.matches(in: text.string, range: NSRange(location: 0, length: rendered.length)) ?? []
        for match in links.reversed() {
            guard let url = match.url, canOpen(url) else { continue }
            var range = match.range
            let end = NSMaxRange(range)
            if url.scheme == "mailto", range.location > 0, end < rendered.length,
               rendered.character(at: range.location - 1) == 0x3C, rendered.character(at: end) == 0x3E {
                text.deleteCharacters(in: NSRange(location: end, length: 1))
                text.deleteCharacters(in: NSRange(location: range.location - 1, length: 1))
                range.location -= 1
            }
            if text.attribute(.link, at: range.location, effectiveRange: nil) == nil {
                text.addAttribute(.link, value: url, range: range)
            }
        }
    }

    static func canOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host?.isEmpty == false
        case "mailto": URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.contains("@") == true
        default: false
        }
    }
}

@MainActor
final class SourceControlRevisionCardText: NSTextView {
    private let storage: NSTextStorage
    private var measuredSize = NSSize.zero
    private var firstBaseline: CGFloat = 0

    init(_ text: NSAttributedString, width: CGFloat, singleLine: Bool) {
        storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = singleLine ? 1 : 0
        container.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
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
        if manager.numberOfGlyphs > 0 { firstBaseline = manager.location(forGlyphAt: 0).y }
        invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) { fatalError("Revision card text views are created in code.") }

    override var intrinsicContentSize: NSSize { measuredSize }
    override var firstBaselineOffsetFromTop: CGFloat { firstBaseline }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func hasLink(at point: NSPoint) -> Bool {
        guard bounds.contains(point), let layoutManager, let textContainer else { return false }
        let origin = textContainerOrigin
        let location = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        guard NSLocationInRange(glyph, layoutManager.glyphRange(for: textContainer)),
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(location)
        else { return false }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return character < storage.length && storage.attribute(.link, at: character, effectiveRange: nil) != nil
    }
}
