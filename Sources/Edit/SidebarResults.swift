import AppKit

@MainActor
enum SidebarResults {
    static let rowHeight: CGFloat = 24

    static func configure(_ table: NSTableView, in scroll: NSScrollView) {
        table.headerView = nil
        table.style = .fullWidth
        table.rowSizeStyle = .custom
        table.rowHeight = rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true

        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        scroll.contentView.clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
    }

    static func excerpt(of source: NSString, match: NSRange, scope: NSRange? = nil) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.tighteningFactorForTruncation = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: EditorTextView.defaultFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        guard match.location >= 0, match.location <= source.length, match.length >= 0,
              match.length <= source.length - match.location else {
            return NSAttributedString(string: source as String, attributes: attributes)
        }
        var start = 0
        var contentEnd = 0
        source.getLineStart(&start, end: nil, contentsEnd: &contentEnd,
                            for: NSRange(location: match.location, length: 0))
        if let scope {
            start = max(start, scope.location)
            contentEnd = min(contentEnd, NSMaxRange(scope))
        }
        // Keep enough room for the hit before the trailing edge of the row.
        let from = max(start, match.location - 9)
        let to = max(from, min(contentEnd, max(NSMaxRange(match), from + 100)))
        let composed = source.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
        let excerptRange = scope.map { NSIntersectionRange(composed, $0) } ?? composed
        let prefix = excerptRange.location > start ? "…" : ""
        let suffix = NSMaxRange(excerptRange) < contentEnd ? "…" : ""
        let text = source.substring(with: excerptRange).replacingOccurrences(of: "\t", with: " ")
        let label = NSMutableAttributedString(string: text.isEmpty ? "↵" : prefix + text + suffix,
                                              attributes: attributes)
        let hit = NSIntersectionRange(match, excerptRange)
        if hit.length > 0 {
            label.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                               range: NSRange(location: hit.location - excerptRange.location + prefix.utf16.count,
                                              length: hit.length))
        }
        return label
    }
}

@MainActor
final class SidebarResultFileHeader: NSTableCellView {
    private let name: NSTextField
    private let icon = NSImageView()
    private let detail: NSTextField
    private var file: URL?
    private var language: String?

    var detailText: String {
        get { detail.stringValue }
        set { detail.stringValue = newValue }
    }

    init(name: String, detail: String, prioritizesName: Bool = false) {
        self.name = NSTextField(labelWithString: name)
        self.detail = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        self.name.maximumNumberOfLines = 1
        self.name.lineBreakMode = .byTruncatingMiddle
        self.name.setContentCompressionResistancePriority(prioritizesName ? .defaultHigh : .defaultLow,
                                                          for: .horizontal)
        self.name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        self.detail.lineBreakMode = prioritizesName ? .byTruncatingHead : .byTruncatingTail
        self.detail.textColor = .secondaryLabelColor
        self.detail.setContentHuggingPriority(.required, for: .horizontal)
        self.detail.setContentCompressionResistancePriority(prioritizesName ? .defaultLow : .defaultHigh,
                                                            for: .horizontal)
        self.detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        icon.setAccessibilityElement(false)
        for label in [icon, self.name, self.detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            self.name.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.name.trailingAnchor.constraint(lessThanOrEqualTo: self.detail.leadingAnchor, constant: -5),
            self.detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            self.detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Sidebar result headers are created in code.") }

    func updateFile(_ title: String, url: URL?, language: String? = nil) {
        name.stringValue = title
        file = url
        self.language = language
        updateIcon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateIcon()
    }

    private func updateIcon() {
        icon.image = FileIcons.image(for: file, appearance: effectiveAppearance, language: language)
    }
}

@MainActor
final class SidebarResultRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor
class SidebarResultExcerptCell: NSTableCellView {
    let excerpt = NSTextField(labelWithString: "")
    private(set) lazy var fullExcerptWidth = excerpt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        excerpt.allowsEditingTextAttributes = true
        excerpt.maximumNumberOfLines = 1
        excerpt.cell?.usesSingleLineMode = true
        excerpt.cell?.wraps = false
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        excerpt.setContentHuggingPriority(.defaultLow, for: .horizontal)
        excerpt.translatesAutoresizingMaskIntoConstraints = false
        addSubview(excerpt)
        NSLayoutConstraint.activate([
            excerpt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            excerpt.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            excerpt.centerYAnchor.constraint(equalTo: centerYAnchor),
            fullExcerptWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Sidebar result cells are created in code.") }

    func configureExcerpt(_ text: NSAttributedString) {
        excerpt.attributedStringValue = text
        setAccessibilityLabel(excerpt.stringValue)
    }
}
