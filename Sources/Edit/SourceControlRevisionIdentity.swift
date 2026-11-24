import AppKit

@MainActor
struct SourceControlRevisionStatus {
    static let iconWidth: CGFloat = 12
    let symbol: String
    let name: String
    let color: NSColor

    static func statuses(for revision: JJSourceControlRevision) -> [Self] {
        var statuses: [Self] = []
        if revision.isWorkingCopy { statuses.append(.init(symbol: "at", name: "Working copy", color: .controlAccentColor)) }
        if revision.isImmutable { statuses.append(.init(symbol: "lock.fill", name: "Immutable", color: .systemTeal)) }
        if revision.isConflicted { statuses.append(.init(symbol: "xmark.circle.fill", name: "Conflict", color: .systemPurple)) }
        if revision.isDivergent { statuses.append(.init(symbol: "arrow.triangle.branch", name: "Divergent", color: .systemOrange)) }
        return statuses
    }

    func makeIcon() -> NSImageView {
        let isConflict = symbol == "xmark.circle.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: isConflict ? 13 : 10, weight: isConflict ? .bold : .semibold)) ?? NSImage()
        let icon = NSImageView(image: image)
        if isConflict { icon.identifier = .init("JujutsuConflictIcon") }
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: Self.iconWidth).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        return icon
    }
}

@MainActor
final class SourceControlRevisionIdentity: NSView {
    private static let textSpacing: CGFloat = 7
    private let symbols = NSStackView()
    private let changeID = NSTextField(labelWithString: "")
    private let author = NSTextField(labelWithString: "")
    private let bookmarks = NSTextField(labelWithString: "")
    private var icons: [(NSImageView, NSColor)] = []
    private var shownStatuses: [SourceControlRevisionStatus] = []
    private var symbolWidth: NSLayoutConstraint!
    private var statusGap: NSLayoutConstraint!
    private var authorGap: NSLayoutConstraint!
    private var bookmarkGap: NSLayoutConstraint!
    private var bookmarkMinimumWidth: NSLayoutConstraint!
    private var emphasized = false

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        changeID.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        changeID.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        author.font = .systemFont(ofSize: 11)
        author.setContentCompressionResistancePriority(.init(rawValue: 260), for: .horizontal)
        bookmarks.identifier = NSUserInterfaceItemIdentifier("JujutsuRevisionBookmarks")
        bookmarks.font = .systemFont(ofSize: 11)
        bookmarks.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [changeID, author, bookmarks] {
            label.allowsExpansionToolTips = false
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
        }
        symbols.orientation = .horizontal
        symbols.spacing = 4
        symbols.alignment = .centerY
        for child in [symbols, changeID, author, bookmarks] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        statusGap = changeID.leadingAnchor.constraint(equalTo: symbols.trailingAnchor)
        symbolWidth = symbols.widthAnchor.constraint(equalToConstant: 0)
        authorGap = author.leadingAnchor.constraint(equalTo: changeID.trailingAnchor)
        authorGap.priority = .defaultHigh
        bookmarkGap = bookmarks.leadingAnchor.constraint(equalTo: author.trailingAnchor)
        bookmarkGap.priority = .defaultHigh
        bookmarkMinimumWidth = bookmarks.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        bookmarkMinimumWidth.priority = .init(rawValue: 500)
        NSLayoutConstraint.activate([
            symbols.leadingAnchor.constraint(equalTo: leadingAnchor), symbols.centerYAnchor.constraint(equalTo: centerYAnchor), symbolWidth,
            statusGap, changeID.centerYAnchor.constraint(equalTo: centerYAnchor),
            changeID.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            authorGap, author.leadingAnchor.constraint(greaterThanOrEqualTo: changeID.trailingAnchor),
            author.centerYAnchor.constraint(equalTo: centerYAnchor),
            bookmarkGap, bookmarks.leadingAnchor.constraint(greaterThanOrEqualTo: author.trailingAnchor),
            bookmarks.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bookmarks.centerYAnchor.constraint(equalTo: centerYAnchor), bookmarkMinimumWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("Change identifiers are created in code.") }

    var isChangeIDSelectable: Bool {
        get { changeID.isSelectable }
        set { changeID.isSelectable = newValue }
    }

    override var intrinsicContentSize: NSSize {
        let authorWidth = author.isHidden ? 0 : Self.textSpacing + author.intrinsicContentSize.width
        let bookmarkWidth = bookmarks.isHidden ? 0 : Self.textSpacing + bookmarks.intrinsicContentSize.width
        let width = symbolWidth.constant + statusGap.constant + changeID.intrinsicContentSize.width + authorWidth + bookmarkWidth
        return NSSize(width: ceil(width), height: 14)
    }

    func update(_ revision: JJSourceControlRevision, showsAuthor: Bool = true, showsAllStatuses: Bool = false) {
        let statuses = SourceControlRevisionStatus.statuses(for: revision)
        let visibleStatuses = showsAuthor || showsAllStatuses ? statuses : Array(statuses.prefix(2))
        if shownStatuses.map(\.symbol) != visibleStatuses.map(\.symbol) {
            for (icon, _) in icons {
                symbols.removeArrangedSubview(icon)
                icon.removeFromSuperview()
            }
            icons = visibleStatuses.map { status in
                let icon = status.makeIcon()
                symbols.addArrangedSubview(icon)
                return (icon, status.color)
            }
            shownStatuses = visibleStatuses
            symbolWidth.constant = CGFloat(icons.count) * SourceControlRevisionStatus.iconWidth
                + CGFloat(max(0, icons.count - 1)) * symbols.spacing
            statusGap.constant = visibleStatuses.isEmpty ? 0 : 4
        }
        changeID.stringValue = revision.shortID
        author.stringValue = showsAuthor ? revision.author : ""
        author.isHidden = author.stringValue.isEmpty
        authorGap.constant = author.isHidden ? 0 : Self.textSpacing
        let bookmarkNames = showsAuthor ? revision.bookmarks.joined(separator: ", ") : ""
        bookmarks.stringValue = bookmarkNames
        bookmarks.isHidden = bookmarkNames.isEmpty
        bookmarkGap.constant = bookmarks.isHidden ? 0 : Self.textSpacing
        // Leave room for the start of a bookmark even when the author's name is long.
        bookmarkMinimumWidth.constant = bookmarks.isHidden ? 0 : min(44, bookmarks.intrinsicContentSize.width)
        invalidateIntrinsicContentSize()
        let labels = [revision.shortID] + statuses.map(\.name) + (author.isHidden ? [] : [author.stringValue])
        setAccessibilityLabel(labels.joined(separator: ", "))
        toolTip = showsAuthor ? nil : labels.joined(separator: " · ")
        updateColors()
    }

    func setEmphasized(_ emphasized: Bool) {
        self.emphasized = emphasized
        updateColors()
    }

    private func updateColors() {
        let selected = NSColor.alternateSelectedControlTextColor
        changeID.textColor = emphasized ? selected : (shownStatuses.first?.color ?? .secondaryLabelColor)
        author.textColor = emphasized ? selected : .secondaryLabelColor
        bookmarks.textColor = emphasized ? selected : .controlAccentColor
        for (icon, color) in icons { icon.contentTintColor = emphasized ? selected : color }
    }
}
