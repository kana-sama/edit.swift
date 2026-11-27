import AppKit

enum EditorHoverPresentation: Sendable {
    struct Section: Sendable {
        enum Kind: String, Sendable {
            case declaration = "Declaration"
            case type = "Type"
            case documentation = "Description"
            case note = "Note"
            case references = "Links"
            case parameters = "Parameters"
            case returns = "Returns"

            var isCode: Bool { self == .declaration || self == .type }
            var showsLabel: Bool { self == .type || self == .references }
            var showsHeading: Bool { self == .parameters || self == .returns }
            var followsDivider: Bool { showsLabel || showsHeading }
        }

        let kind: Kind
        let content: EditorHoverContent
    }

    case markdown(EditorHoverContent)
    case structured([Section])
    case diagnostics([String])

    var maximumWidth: CGFloat {
        switch self {
        case .markdown: 460
        case .structured: 560
        case .diagnostics: 520
        }
    }

    init(text: String, isMarkdown: Bool, server: LanguageServer? = nil, solidityDocumentation: SolarHover.Documentation? = nil) {
        if isMarkdown, server == .solidity {
            let content = EditorHoverContent(text: SolarHover.markdownWithoutCommentMargins(text), isMarkdown: true)
            let sections = content.natSpecSections(source: solidityDocumentation)
            self = sections.count == 1 && sections.first?.kind == .documentation
                ? .markdown(sections[0].content) : .structured(sections)
            return
        }
        if isMarkdown, server == .odin, let hover = OLSHover(markdown: text) {
            var sections = [Section(kind: .declaration, content: EditorHoverContent(code: [hover.declaration], language: .odin))]
            if let documentation = hover.documentation {
                sections.append(Section(kind: .documentation, content: EditorHoverContent(
                    text: documentation, isMarkdown: true, preservesSoftBreaks: true)))
            }
            self = .structured(sections)
            return
        }
        guard isMarkdown, server != .odin, let hover = ZLSHover(markdown: text) else {
            self = .markdown(EditorHoverContent(text: text, isMarkdown: isMarkdown))
            return
        }

        var sections = [Section(kind: .declaration, content: EditorHoverContent(code: [hover.declaration], language: .zig))]
        if let documentation = hover.documentation {
            sections.append(Section(kind: .documentation, content: EditorHoverContent(text: documentation, isMarkdown: true)))
        }
        if !hover.types.isEmpty {
            let types = hover.hasMoreTypes ? hover.types + ["…"] : hover.types
            sections.append(Section(kind: .type, content: EditorHoverContent(code: types, language: .zig)))
        }
        if !hover.references.isEmpty {
            sections.append(Section(kind: .references, content: EditorHoverContent(references: hover.references)))
        }
        self = .structured(sections)
    }
}

@MainActor
struct EditorHoverLayout {
    let view: NSView
    let textViews: [HoverTextView]

    init?(_ presentation: EditorHoverPresentation, maximumWidth: CGFloat) {
        switch presentation {
        case .markdown(let content):
            let inset = NSSize(width: 12, height: 10)
            let attributed = content.attributedText(maximumWidth: maximumWidth - 2 * inset.width)
            guard attributed.length > 0 else { return nil }
            let text = HoverTextView(width: maximumWidth, text: attributed, inset: inset)
            guard let natural = text.measure(at: maximumWidth) else { return nil }
            let width = min(maximumWidth, max(84, natural.width))
            guard let size = text.measure(at: width) else { return nil }
            text.setFrameSize(NSSize(width: width, height: size.height))
            view = text
            textViews = [text]
        case .structured(let sections):
            guard let contents = HoverSectionsView(sections, maximumWidth: maximumWidth) else { return nil }
            view = contents
            textViews = contents.textViews
        case .diagnostics(let messages):
            guard let contents = DiagnosticHoverRows(messages: messages, maximumWidth: maximumWidth) else { return nil }
            view = contents
            textViews = contents.textViews
        }
    }
}

@MainActor
private final class DiagnosticHoverRows: NSView {
    let textViews: [HoverTextView]

    override var isFlipped: Bool { true }

    init?(messages: [String], maximumWidth: CGFloat) {
        let inset: CGFloat = 12
        let rowPadding: CGFloat = 8
        let iconSize: CGFloat = 14
        let textLeading = inset + iconSize + 9
        let spaceForText = maximumWidth - textLeading - inset
        guard spaceForText > 0, !messages.isEmpty else { return nil }

        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let rows = messages.map { message in
            HoverTextView(width: spaceForText, text: NSAttributedString(string: message, attributes: attributes), inset: .zero)
        }
        let naturalWidth = rows.compactMap { $0.measure(at: spaceForText)?.width }.max() ?? 0
        let textWidth = min(spaceForText, max(120, naturalWidth))
        let width = textLeading + textWidth + inset
        textViews = rows
        super.init(frame: .zero)

        let icon = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium))
        var top: CGFloat = 0
        for (index, text) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox(frame: NSRect(x: textLeading, y: top, width: textWidth, height: 1))
                separator.boxType = .separator
                separator.setAccessibilityElement(false)
                addSubview(separator)
                top += 1
            }
            guard let size = text.measure(at: textWidth), let baseline = text.firstTextBaseline else { return nil }
            let bodyTop = top + rowPadding
            let symbol = NSImageView(frame: NSRect(x: inset, y: bodyTop + baseline - font.capHeight / 2 - iconSize / 2,
                                                   width: iconSize, height: iconSize))
            symbol.image = icon
            symbol.contentTintColor = .systemRed
            symbol.setAccessibilityElement(false)
            addSubview(symbol)

            text.setAccessibilityLabel("Error")
            text.frame = NSRect(x: textLeading, y: bodyTop, width: textWidth, height: size.height)
            addSubview(text)
            top = max(symbol.frame.maxY, text.frame.maxY) + rowPadding
        }
        setFrameSize(NSSize(width: width, height: top))
    }

    required init?(coder: NSCoder) { fatalError("Diagnostic hover rows are created in code.") }
}

@MainActor
private final class HoverSectionsView: NSView {
    private static let codeBackgroundColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.065)
        }
        return NSColor.black.withAlphaComponent(0.075)
    }

    let textViews: [HoverTextView]

    override var isFlipped: Bool { true }

    init?(_ sections: [EditorHoverPresentation.Section], maximumWidth: CGFloat) {
        let inset: CGFloat = 12
        let rowSpacing: CGFloat = 8
        let fieldGroupSpacing: CGFloat = 16
        let columnSpacing: CGFloat = 14
        let quoteInset: CGFloat = 12
        let codePadding = NSSize(width: 6, height: 4)
        let textWidth = maximumWidth - 2 * inset - codePadding.width
        let sideLabelFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let fieldWidth = ceil(sections.lazy.filter { $0.kind.showsHeading }
            .map { $0.content.natSpecNameWidth(using: sideLabelFont) }.max() ?? 0)
        let natSpecLayout = EditorHoverContent.NatSpecLayout(
            labelFont: sideLabelFont, labelWidth: fieldWidth + columnSpacing <= textWidth * 0.6 ? fieldWidth : 0,
            columnSpacing: columnSpacing)
        let rows: [(label: NSTextField, body: HoverTextView, isCode: Bool)] = sections.map { section in
            let kind = section.kind
            let name = kind.rawValue
            let label = NSTextField(labelWithString: name)
            label.identifier = .init("EditorLanguageHover.\(name).label")
            label.font = kind.showsHeading ? .systemFont(ofSize: 13, weight: .semibold) : sideLabelFont
            label.textColor = kind.showsHeading ? .labelColor : .secondaryLabelColor
            label.alignment = kind.showsHeading ? .left : .right
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
            label.isHidden = !kind.followsDivider

            let bodyWidth = textWidth - (kind.isCode ? codePadding.width : 0)
            let text = section.content.attributedText(maximumWidth: bodyWidth,
                                                       natSpecLayout: kind.showsHeading ? natSpecLayout : nil)
            let body = HoverTextView(width: maximumWidth, text: text, inset: .zero)
            body.identifier = .init("EditorLanguageHover.\(name).body")
            if label.isHidden { body.setAccessibilityLabel(name) }
            return (label: label, body: body, isCode: kind.isCode)
        }
        let labelWidth = sections.indices.filter { sections[$0].kind.showsLabel }.map { index in
            let row = rows[index]
            let insets = row.label.alignmentRectInsets
            return ceil(row.label.fittingSize.width - insets.left - insets.right)
        }.max() ?? 0
        let labeledLeading = inset + labelWidth + columnSpacing
        let leadingEdges = zip(rows, sections).map { row, section in
            if section.kind == .note { return inset + quoteInset }
            return section.kind.showsLabel ? labeledLeading : inset + (row.isCode ? codePadding.width : 0)
        }
        let trailingInset = inset + codePadding.width
        var preferredWidth: CGFloat = 0
        for (row, leading) in zip(rows, leadingEdges) {
            let availableWidth = maximumWidth - leading - trailingInset
            guard availableWidth > 0, let size = row.body.measure(at: availableWidth) else { return nil }
            preferredWidth = max(preferredWidth, leading + max(104, size.width) + trailingInset)
        }
        let width = min(maximumWidth, preferredWidth)
        textViews = rows.map { $0.body }
        super.init(frame: .zero)

        var top = inset
        for (index, row) in rows.enumerated() {
            let kind = sections[index].kind
            if index > 0, kind.followsDivider, !sections[index - 1].kind.followsDivider {
                let separator = NSBox(frame: NSRect(x: inset, y: top, width: width - 2 * inset, height: 1))
                separator.identifier = .init("EditorLanguageHover.separator")
                separator.boxType = .separator
                addSubview(separator)
                top += 1 + rowSpacing
            }
            let bodyLeading = leadingEdges[index]
            let bodyWidth = width - bodyLeading - trailingInset
            guard let size = row.body.measure(at: bodyWidth), let bodyBaseline = row.body.firstTextBaseline else { return nil }
            let padding = row.isCode ? codePadding : .zero
            let labelHeight = ceil(row.label.fittingSize.height)
            let labelFrame: NSRect
            let bodyTop: CGFloat
            if kind.showsHeading {
                labelFrame = NSRect(x: bodyLeading, y: top, width: bodyWidth, height: labelHeight)
                bodyTop = labelFrame.maxY + 4
            } else {
                let labelBaseline = row.label.firstBaselineOffsetFromTop
                let baseline = top + max(labelBaseline, padding.height + bodyBaseline)
                labelFrame = NSRect(x: inset, y: baseline - labelBaseline, width: labelWidth, height: labelHeight)
                bodyTop = baseline - bodyBaseline
            }
            row.label.frame = row.label.frame(forAlignmentRect: labelFrame)
            addSubview(row.label)

            let bodyFrame = NSRect(x: bodyLeading, y: bodyTop, width: bodyWidth, height: size.height)
            let paddedBody = bodyFrame.insetBy(dx: -padding.width, dy: -padding.height)
            if row.isCode {
                let background = NSBox(frame: paddedBody)
                background.boxType = .custom
                background.titlePosition = .noTitle
                background.borderWidth = 0
                background.cornerRadius = 6
                background.fillColor = Self.codeBackgroundColor
                background.setAccessibilityElement(false)
                addSubview(background)
            }
            if kind == .note {
                let rail = NSBox(frame: NSRect(x: inset, y: bodyFrame.minY, width: 2, height: bodyFrame.height))
                rail.identifier = .init("EditorLanguageHover.Note.rail")
                rail.boxType = .custom
                rail.borderWidth = 0
                rail.cornerRadius = 1
                rail.fillColor = .controlAccentColor
                rail.setAccessibilityElement(false)
                addSubview(rail)
            }
            row.body.frame = bodyFrame
            addSubview(row.body)
            top = max(labelFrame.maxY, paddedBody.maxY)
            if index < rows.count - 1 {
                top += kind == .parameters && sections[index + 1].kind == .returns ? fieldGroupSpacing : rowSpacing
            }
        }
        setFrameSize(NSSize(width: width, height: top + inset))
    }

    required init?(coder: NSCoder) { fatalError("Hover sections are created in code.") }
}
