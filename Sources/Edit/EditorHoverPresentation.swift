import AppKit

enum EditorHoverPresentation: Sendable {
    struct Section: Sendable {
        enum Kind: String, Sendable {
            case declaration = "Declaration"
            case type = "Type"
            case documentation = "Description"
            case goTo = "Go to"

            var isCode: Bool { self == .declaration || self == .type }
        }

        let kind: Kind
        let content: EditorHoverContent
    }

    case markdown(EditorHoverContent)
    case structured([Section])

    var maximumWidth: CGFloat {
        switch self {
        case .markdown: 460
        case .structured: 560
        }
    }

    init(text: String, isMarkdown: Bool) {
        guard isMarkdown, let hover = ZLSHover(markdown: text) else {
            self = .markdown(EditorHoverContent(text: text, isMarkdown: isMarkdown))
            return
        }

        var sections = [Section(kind: .declaration, content: EditorHoverContent(zigCode: [hover.declaration]))]
        if !hover.types.isEmpty {
            let types = hover.hasMoreTypes ? hover.types + ["…"] : hover.types
            sections.append(Section(kind: .type, content: EditorHoverContent(zigCode: types)))
        }
        if let documentation = hover.documentation {
            sections.append(Section(kind: .documentation, content: EditorHoverContent(text: documentation, isMarkdown: true)))
        }
        if !hover.references.isEmpty {
            sections.append(Section(kind: .goTo, content: EditorHoverContent(references: hover.references)))
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
            let attributed = content.attributedText()
            guard attributed.length > 0 else { return nil }
            let text = HoverTextView(width: maximumWidth, text: attributed, inset: NSSize(width: 12, height: 10))
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
        }
    }
}

@MainActor
private final class HoverSectionsView: NSView {
    let textViews: [HoverTextView]

    override var isFlipped: Bool { true }

    init?(_ sections: [EditorHoverPresentation.Section], maximumWidth: CGFloat) {
        let inset: CGFloat = 12
        let rowSpacing: CGFloat = 8
        let columnSpacing: CGFloat = 14
        let codePadding = NSSize(width: 6, height: 4)
        let rows: [(label: NSTextField, body: HoverTextView, isCode: Bool)] = sections.map { section in
            let name = section.kind.rawValue
            let label = NSTextField(labelWithString: name)
            label.identifier = .init("EditorLanguageHover.\(name).label")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))

            let body = HoverTextView(width: maximumWidth, text: section.content.attributedText(), inset: .zero)
            body.identifier = .init("EditorLanguageHover.\(name).body")
            return (label: label, body: body, isCode: section.kind.isCode)
        }
        let labelWidth = rows.map { row in
            let insets = row.label.alignmentRectInsets
            return ceil(row.label.fittingSize.width - insets.left - insets.right)
        }.max() ?? 0
        let bodyLeading = inset + labelWidth + columnSpacing
        let trailingInset = inset + codePadding.width
        let availableWidth = maximumWidth - bodyLeading - trailingInset
        guard availableWidth > 0 else { return nil }
        var preferredWidth: CGFloat = 104
        for row in rows {
            guard let size = row.body.measure(at: availableWidth) else { return nil }
            preferredWidth = max(preferredWidth, size.width)
        }
        let bodyWidth = min(availableWidth, preferredWidth)
        textViews = rows.map { $0.body }
        super.init(frame: .zero)

        var top = inset
        for (index, row) in rows.enumerated() {
            guard let size = row.body.measure(at: bodyWidth), let bodyBaseline = row.body.firstTextBaseline else { return nil }
            let padding = row.isCode ? codePadding : .zero
            let labelHeight = ceil(row.label.fittingSize.height)
            let labelBaseline = row.label.firstBaselineOffsetFromTop
            let baseline = top + max(labelBaseline, padding.height + bodyBaseline)
            let labelFrame = NSRect(x: inset, y: baseline - labelBaseline, width: labelWidth, height: labelHeight)
            row.label.frame = row.label.frame(forAlignmentRect: labelFrame)
            addSubview(row.label)

            let bodyFrame = NSRect(x: bodyLeading, y: baseline - bodyBaseline, width: bodyWidth, height: size.height)
            let paddedBody = bodyFrame.insetBy(dx: -padding.width, dy: -padding.height)
            if row.isCode {
                let background = NSBox(frame: paddedBody)
                background.boxType = .custom
                background.titlePosition = .noTitle
                background.borderWidth = 0
                background.cornerRadius = 6
                background.fillColor = .labelColor.withAlphaComponent(0.065)
                background.setAccessibilityElement(false)
                addSubview(background)
            }
            row.body.frame = bodyFrame
            addSubview(row.body)
            top = max(labelFrame.maxY, paddedBody.maxY)
            if index < rows.count - 1 { top += rowSpacing }
        }
        setFrameSize(NSSize(width: bodyLeading + bodyWidth + trailingInset, height: top + inset))
    }

    required init?(coder: NSCoder) { fatalError("Hover sections are created in code.") }
}
