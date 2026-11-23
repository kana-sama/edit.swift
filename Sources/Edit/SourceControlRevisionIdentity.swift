import AppKit

@MainActor
final class SourceControlRevisionIdentity: NSView {
    private struct Status {
        let symbol: String
        let name: String
        let color: NSColor
    }

    private let symbols = NSStackView()
    private let changeID = NSTextField(labelWithString: "")
    private let bookmarks = NSTextField(labelWithString: "")
    private var icons: [(NSImageView, NSColor)] = []
    private var shownStatuses: [Status] = []
    private var gap: NSLayoutConstraint!
    private var emphasized = false

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        changeID.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        changeID.setContentCompressionResistancePriority(.required, for: .horizontal)
        bookmarks.font = .systemFont(ofSize: 11)
        bookmarks.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [changeID, bookmarks] {
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
        }
        symbols.orientation = .horizontal
        symbols.spacing = 4
        symbols.alignment = .centerY
        for child in [symbols, changeID, bookmarks] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        gap = changeID.leadingAnchor.constraint(equalTo: symbols.trailingAnchor)
        NSLayoutConstraint.activate([
            symbols.leadingAnchor.constraint(equalTo: leadingAnchor), symbols.centerYAnchor.constraint(equalTo: centerYAnchor),
            gap, changeID.centerYAnchor.constraint(equalTo: centerYAnchor),
            bookmarks.leadingAnchor.constraint(equalTo: changeID.trailingAnchor, constant: 7),
            bookmarks.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), bookmarks.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Change identifiers are created in code.") }

    func update(_ revision: JJSourceControlRevision, showsBookmarks: Bool = true) {
        var statuses: [Status] = []
        if revision.isWorkingCopy { statuses.append(.init(symbol: "at", name: "Working copy", color: .controlAccentColor)) }
        if revision.isImmutable { statuses.append(.init(symbol: "lock.fill", name: "Immutable", color: .systemTeal)) }
        if revision.isConflicted { statuses.append(.init(symbol: "exclamationmark.diamond.fill", name: "Conflict", color: .systemPurple)) }
        if revision.isDivergent { statuses.append(.init(symbol: "arrow.triangle.branch", name: "Divergent", color: .systemOrange)) }
        if shownStatuses.map(\.symbol) != statuses.map(\.symbol) {
            for (icon, _) in icons {
                symbols.removeArrangedSubview(icon)
                icon.removeFromSuperview()
            }
            icons = statuses.map { status in
                let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) ?? NSImage()
                let icon = NSImageView(image: image)
                icon.imageScaling = .scaleProportionallyDown
                icon.toolTip = status.name
                icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 13).isActive = true
                symbols.addArrangedSubview(icon)
                return (icon, status.color)
            }
            shownStatuses = statuses
            gap.constant = statuses.isEmpty ? 0 : 4
        }
        changeID.stringValue = revision.shortID
        bookmarks.stringValue = showsBookmarks ? revision.bookmarks.joined(separator: "  ") : ""
        let labels = [revision.shortID] + statuses.map(\.name) + (showsBookmarks ? revision.bookmarks : [])
        setAccessibilityLabel(labels.joined(separator: ", "))
        toolTip = labels.joined(separator: " · ")
        updateColors()
    }

    func setEmphasized(_ emphasized: Bool) {
        self.emphasized = emphasized
        updateColors()
    }

    private func updateColors() {
        let selected = NSColor.alternateSelectedControlTextColor
        changeID.textColor = emphasized ? selected : (shownStatuses.first?.color ?? .secondaryLabelColor)
        bookmarks.textColor = emphasized ? selected : .controlAccentColor
        for (icon, color) in icons { icon.contentTintColor = emphasized ? selected : color }
    }
}
