import AppKit

enum EditorHoverPresentation: Sendable {
    struct Section: Sendable {
        enum Kind: String, Sendable {
            case declaration = "Declaration"
            case type = "Type"
            case documentation = "Documentation"
            case goTo = "Go to"

            var isCode: Bool { self == .declaration || self == .type }
        }

        let kind: Kind
        let content: EditorHoverContent
    }

    case markdown(EditorHoverContent)
    case structured([Section])

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
        let sectionSpacing: CGFloat = 11
        let labelSpacing: CGFloat = 4
        let availableWidth = maximumWidth - 2 * inset
        let rows: [(label: NSTextField, body: HoverTextView, isCode: Bool)] = sections.map { section in
            let name = section.kind.rawValue
            let label = NSTextField(labelWithString: name)
            label.identifier = .init("EditorLanguageHover.\(name).label")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .labelColor
            label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))

            let padding = section.kind.isCode ? NSSize(width: 8, height: 6) : .zero
            let body = HoverTextView(width: availableWidth, text: section.content.attributedText(), inset: padding)
            body.identifier = .init("EditorLanguageHover.\(name).body")
            return (label: label, body: body, isCode: section.kind.isCode)
        }
        var preferredWidth: CGFloat = 172
        for row in rows {
            guard let size = row.body.measure(at: availableWidth) else { return nil }
            preferredWidth = max(preferredWidth, size.width, ceil(row.label.fittingSize.width))
        }
        let bodyWidth = min(availableWidth, preferredWidth)
        textViews = rows.map { $0.body }
        super.init(frame: .zero)

        var top = inset
        for (index, row) in rows.enumerated() {
            let labelHeight = ceil(row.label.fittingSize.height)
            row.label.frame = row.label.frame(forAlignmentRect: NSRect(x: inset, y: top, width: bodyWidth, height: labelHeight))
            addSubview(row.label)
            top += labelHeight + labelSpacing

            guard let size = row.body.measure(at: bodyWidth) else { return nil }
            let bodyFrame = NSRect(x: inset, y: top, width: bodyWidth, height: size.height)
            if row.isCode {
                let background = NSBox(frame: bodyFrame)
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
            top += size.height
            if index < rows.count - 1 { top += sectionSpacing }
        }
        setFrameSize(NSSize(width: bodyWidth + 2 * inset, height: top + inset))
    }

    required init?(coder: NSCoder) { fatalError("Hover sections are created in code.") }
}
