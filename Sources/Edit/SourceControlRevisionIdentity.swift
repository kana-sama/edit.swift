import AppKit

@MainActor
struct SourceControlRevisionStatus {
    static let iconWidth: CGFloat = 12
    let symbol: String
    let name: String
    let color: NSColor

    static func statuses(for revision: JJSourceControlRevision) -> [Self] {
        guard !revision.isRoot else { return [] }
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
        if symbol == "lock.fill" { icon.identifier = .init("JujutsuImmutableIcon") }
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: Self.iconWidth).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        return icon
    }
}

@MainActor
final class SourceControlRevisionIdentity: NSView {
    private static let textSpacing: CGFloat = 7
    private let showsBadge: Bool
    private let horizontalInset: CGFloat
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
    private var isWorkingCopy = false

    init(showsBadge: Bool = false) {
        self.showsBadge = showsBadge
        horizontalInset = showsBadge ? 6 : 0
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
            symbols.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            symbols.centerYAnchor.constraint(equalTo: centerYAnchor), symbolWidth,
            statusGap, changeID.centerYAnchor.constraint(equalTo: centerYAnchor),
            changeID.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -horizontalInset),
            authorGap, author.leadingAnchor.constraint(greaterThanOrEqualTo: changeID.trailingAnchor),
            author.centerYAnchor.constraint(equalTo: centerYAnchor),
            bookmarkGap, bookmarks.leadingAnchor.constraint(greaterThanOrEqualTo: author.trailingAnchor),
            bookmarks.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -horizontalInset),
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
        return NSSize(width: ceil(width) + 2 * horizontalInset, height: showsBadge ? 21 : 14)
    }

    var badgeFillColor: NSColor? {
        guard showsBadge else { return nil }
        return isWorkingCopy ? NSColor.systemBlue.withAlphaComponent(0.20) : NSColor.labelColor.withAlphaComponent(0.10)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let badgeFillColor else { return }
        badgeFillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if showsBadge { needsDisplay = true }
    }

    func update(_ revision: JJSourceControlRevision, showsAuthor: Bool = true, showsAllStatuses: Bool = false) {
        let statuses = SourceControlRevisionStatus.statuses(for: revision)
        let symbolsToShow = showsBadge ? statuses.filter { $0.symbol != "at" } : statuses
        let visibleStatuses = showsAuthor || showsAllStatuses ? symbolsToShow : Array(symbolsToShow.prefix(2))
        if isWorkingCopy != revision.isWorkingCopy {
            isWorkingCopy = revision.isWorkingCopy
            if showsBadge { needsDisplay = true }
        }
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
        let identifierColor: NSColor = showsBadge ? .labelColor : (shownStatuses.first?.color ?? .secondaryLabelColor)
        changeID.textColor = emphasized ? selected : identifierColor
        author.textColor = emphasized ? selected : .secondaryLabelColor
        bookmarks.textColor = emphasized ? selected : .controlAccentColor
        for (icon, color) in icons { icon.contentTintColor = emphasized ? selected : color }
    }
}
