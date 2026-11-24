import AppKit

enum EditorHoverPresentation: Sendable {
    struct Section: Sendable {
        enum Kind: String, Sendable {
            case declaration = "Declaration"
            case type = "Type"
            case documentation = "Description"
            case references = "References"

            var isDetail: Bool { self == .type || self == .references }
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
        if let documentation = hover.documentation {
            sections.append(Section(kind: .documentation, content: EditorHoverContent(text: documentation, isMarkdown: true)))
        }
        if !hover.types.isEmpty {
            let types = hover.hasMoreTypes ? hover.types + ["…"] : hover.types
            sections.append(Section(kind: .type, content: EditorHoverContent(zigCode: types)))
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
        let inset: CGFloat = 16
        let columnSpacing: CGFloat = 14
        let availableWidth = maximumWidth - 2 * inset
        let rows = sections.map { section in
            let kind = section.kind
            let name = kind.rawValue
            let label: NSTextField?
            if kind.isDetail {
                let field = NSTextField(labelWithString: name)
                field.identifier = .init("EditorLanguageHover.\(name).label")
                field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                field.textColor = .labelColor
                field.alignment = .right
                field.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
                label = field
            } else {
                label = nil
            }

            let isDeclaration = kind == .declaration
            let attributed = section.content.attributedText(
                proseSize: kind == .documentation ? 14 : 13,
                codeFont: isDeclaration ? NSFontManager.shared.convert(EditorTextView.defaultFont, toSize: 13)
                    : EditorTextView.defaultFont
            )
            let padding = isDeclaration ? NSSize(width: 10, height: 8) : .zero
            let body = HoverTextView(width: maximumWidth, text: attributed, inset: padding)
            body.identifier = .init("EditorLanguageHover.\(name).body")
            if label == nil { body.setAccessibilityLabel(name) }
            return (kind: kind, label: label, body: body)
        }
        let labelWidth = rows.compactMap(\.label).map { label in
            let insets = label.alignmentRectInsets
            return ceil(label.fittingSize.width - insets.left - insets.right)
        }.max() ?? 0
        let detailOffset = labelWidth + columnSpacing
        guard availableWidth > detailOffset else { return nil }
        var preferredWidth: CGFloat = 172
        for row in rows {
            let offset = row.kind.isDetail ? detailOffset : 0
            guard let size = row.body.measure(at: availableWidth - offset) else { return nil }
            preferredWidth = max(preferredWidth, size.width + offset)
        }
        let bodyWidth = min(availableWidth, preferredWidth)
        textViews = rows.map { $0.body }
        super.init(frame: .zero)

        var top = inset
        var inDetails = false
        for (index, row) in rows.enumerated() {
            if row.kind.isDetail && !inDetails {
                top += 12
                let separator = NSBox(frame: NSRect(x: inset, y: top, width: bodyWidth, height: 1))
                separator.identifier = .init("EditorLanguageHover.separator")
                separator.boxType = .separator
                addSubview(separator)
                top += 11
                inDetails = true
            } else if index > 0 {
                top += inDetails ? 5 : 10
            }

            let offset = row.kind.isDetail ? detailOffset : 0
            let width = bodyWidth - offset
            guard let size = row.body.measure(at: width) else { return nil }
            var bodyFrame = NSRect(x: inset + offset, y: top, width: width, height: size.height)
            if let label = row.label {
                guard let bodyBaseline = row.body.firstTextBaseline else { return nil }
                let labelBaseline = label.firstBaselineOffsetFromTop
                let baseline = top + max(labelBaseline, bodyBaseline)
                let labelFrame = NSRect(x: inset, y: baseline - labelBaseline, width: labelWidth,
                                        height: ceil(label.fittingSize.height))
                label.frame = label.frame(forAlignmentRect: labelFrame)
                addSubview(label)
                bodyFrame.origin.y = baseline - bodyBaseline
                top = labelFrame.maxY
            }
            if row.kind == .declaration {
                let background = NSBox(frame: bodyFrame)
                background.boxType = .custom
                background.titlePosition = .noTitle
                background.borderWidth = 0
                background.cornerRadius = 7
                background.fillColor = .labelColor.withAlphaComponent(0.055)
                background.setAccessibilityElement(false)
                addSubview(background)
            }
            row.body.frame = bodyFrame
            addSubview(row.body)
            top = max(top, bodyFrame.maxY)
        }
        setFrameSize(NSSize(width: bodyWidth + 2 * inset, height: top + inset))
    }

    required init?(coder: NSCoder) { fatalError("Hover sections are created in code.") }
}
