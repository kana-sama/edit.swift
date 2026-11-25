import AppKit

@MainActor
enum SidebarResults {
    static let rowHeight: CGFloat = 24
    static let fileGroupSpacing: CGFloat = 8
    static let fileLeading: CGFloat = 10
    static let excerptLeading: CGFloat = 36

    static func indentation(at depth: Int) -> CGFloat { CGFloat(min(depth, 6)) * 12 }

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
class SidebarResultTable: NSTableView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    var onClickSelectedRow: ((Int) -> Void)?
    var isFileHeader: ((Int) -> Bool)?
    var onClickGroup: ((Int) -> Bool)?
    var onHorizontalNavigation: ((Bool) -> Bool)?

    func install(in scrollView: NSScrollView, column identifier: NSUserInterfaceItemIdentifier,
                 accessibilityLabel: String) {
        let column = NSTableColumn(identifier: identifier)
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        addTableColumn(column)
        SidebarResults.configure(self, in: scrollView)
        setAccessibilityLabel(accessibilityLabel)
    }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        if let isFileHeader, !indexes.isEmpty {
            let results = IndexSet(indexes.filter { !isFileHeader($0) })
            if !results.isEmpty { super.selectRowIndexes(results, byExtendingSelection: extend) }
        } else {
            super.selectRowIndexes(indexes, byExtendingSelection: extend)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        let plainClick = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plainClick && clicked >= 0 && onClickGroup?(clicked) == true { return }
        if clicked >= 0, let isFileHeader {
            guard !isFileHeader(clicked) else { return }
            if plainClick {
                window?.makeFirstResponder(self)
                if selectedRow == clicked { onClickSelectedRow?(clicked) }
                else { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
                return
            }
        }
        let clickedSelection = clicked >= 0 && clicked == selectedRow
        super.mouseDown(with: event)

        // AppKit sends a selection change when a different row is clicked.
        if clickedSelection, selectedRow == clicked, event.clickCount == 1, plainClick {
            onClickSelectedRow?(clicked)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 36, 76:
                if !event.isARepeat { onReturn?() }
                return
            case 49:
                if !event.isARepeat { onSpace?() }
                return
            case 53:
                onEscape?()
                return
            case 123, 124:
                if onHorizontalNavigation?(event.keyCode == 124) == true { return }
            case 125, 126:
                if let isFileHeader {
                    moveResult(by: event.keyCode == 125 ? 1 : -1, isFileHeader: isFileHeader)
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    private func moveResult(by step: Int, isFileHeader: (Int) -> Bool) {
        let boundary = step > 0 ? 0 : numberOfRows - 1
        var candidate = selectedRow >= 0 ? selectedRow + step : boundary
        while (0..<numberOfRows).contains(candidate) {
            if !isFileHeader(candidate) {
                selectRowIndexes(IndexSet(integer: candidate), byExtendingSelection: false)
                scrollRowToVisible(candidate)
                return
            }
            candidate += step
        }
    }
}

@MainActor
final class SidebarResultFileHeader: NSTableCellView {
    private let name: NSTextField
    private let icon = NSImageView()
    private let detail: NSTextField
    private let badge = NSBox()
    private var file: URL?
    private var language: String?
    private lazy var iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor)

    var detailText: String {
        get { detail.stringValue }
        set {
            detail.stringValue = newValue
            detail.setAccessibilityLabel(newValue)
            badge.isHidden = true
        }
    }

    init(name: String, detail: String) {
        self.name = NSTextField(labelWithString: name)
        self.detail = NSTextField(labelWithString: detail)
        super.init(frame: .zero)
        self.name.maximumNumberOfLines = 1
        self.name.lineBreakMode = .byTruncatingMiddle
        self.name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        self.detail.lineBreakMode = .byTruncatingTail
        self.detail.textColor = .secondaryLabelColor
        self.detail.setContentHuggingPriority(.required, for: .horizontal)
        self.detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        self.detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badge.boxType = .custom
        badge.borderWidth = 0
        badge.cornerRadius = 4
        badge.fillColor = .quaternaryLabelColor
        badge.isHidden = true
        badge.setAccessibilityElement(false)
        icon.setAccessibilityElement(false)
        for label in [icon, self.name, badge, self.detail] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            self.name.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.name.trailingAnchor.constraint(lessThanOrEqualTo: self.detail.leadingAnchor, constant: -5),
            self.detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            self.detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: self.detail.leadingAnchor, constant: -5),
            badge.trailingAnchor.constraint(equalTo: self.detail.trailingAnchor, constant: 5),
            badge.centerYAnchor.constraint(equalTo: self.detail.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 16),
        ])
        setIndent(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Sidebar result headers are created in code.") }

    func updateFile(_ title: String, url: URL?, language: String? = nil) {
        name.stringValue = title
        file = url
        self.language = language
        toolTip = url?.path
        updateIcon()
    }

    func setIndent(_ depth: Int) {
        iconLeading.constant = SidebarResults.fileLeading + SidebarResults.indentation(at: depth)
    }

    func updateCount(_ count: Int, accessibilityLabel: String) {
        detail.stringValue = count.formatted()
        detail.setAccessibilityLabel(accessibilityLabel)
        badge.isHidden = false
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
    lazy var excerptLeading = excerpt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
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
            excerptLeading,
            excerpt.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            // Center the visible monospaced glyphs within the row and its action buttons.
            excerpt.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
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

final class SidebarActionResultScrollView: NSScrollView {
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        (documentView as? SidebarActionResultTable)?.refreshHover()
    }
}

final class SidebarActionResultTable: SidebarResultTable {
    private var pointerTracking: NSTrackingArea?
    private var hoveredRow = -1
    private weak var hoveredCell: SidebarActionResultCell?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        updateHover(at: nil)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            if let window { center.removeObserver(self, name: name, object: window) }
            if let newWindow {
                center.addObserver(self, selector: #selector(refreshHover), name: name, object: newWindow)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if pointerTracking == nil {
            let tracking = NSTrackingArea(rect: .zero,
                                          options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                          owner: self, userInfo: nil)
            addTrackingArea(tracking)
            pointerTracking = tracking
        }
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }

    @objc func refreshHover() {
        guard let window, window.isKeyWindow else {
            updateHover(at: nil)
            return
        }
        updateHover(at: window.mouseLocationOutsideOfEventStream)
    }

    func configureHover(for cell: SidebarActionResultCell, row: Int) {
        let hovered = hoveredRow == row
        if hovered, hoveredCell !== cell {
            hoveredCell?.updateHover(false)
            hoveredCell = cell
        }
        cell.updateHover(hovered)
    }

    private func updateHover(at location: NSPoint?) {
        let row = location.flatMap { location -> Int? in
            let local = convert(location, from: nil)
            return !isHiddenOrHasHiddenAncestor && visibleRect.contains(local) ? self.row(at: local) : nil
        } ?? -1
        if hoveredRow != row {
            hoveredCell?.updateHover(false)
            hoveredCell = nil
            hoveredRow = row
        }
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarActionResultCell {
            configureHover(for: cell, row: row)
        }
    }
}

final class SidebarActionResultCell: SidebarResultExcerptCell {
    private static let actionSize: CGFloat = 20
    private static let actionSpacing: CGFloat = 1
    // The button's hit area extends beyond its glyph. Let the excerpt use that transparent leading edge.
    private static let excerptOverlap: CGFloat = 1
    private let applyButton = NSButton(image: NSImage(systemSymbolName: "arrow.turn.down.right",
                                                        accessibilityDescription: nil)!,
                                             target: nil, action: nil)
    private let dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                                         target: nil, action: nil)
    private var hover = false
    private var selected = false
    private var acceptsActions = false
    private var replacementAvailable = false
    private lazy var excerptBeforeDismiss = excerpt.trailingAnchor.constraint(
        equalTo: dismissButton.leadingAnchor, constant: Self.excerptOverlap
    )
    private lazy var excerptBeforeApply = excerpt.trailingAnchor.constraint(
        equalTo: applyButton.leadingAnchor, constant: Self.excerptOverlap
    )
    private var onApply: (() -> Void)?
    private var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fullExcerptWidth.isActive = false
        for (button, label, action) in [
            (applyButton, "Replace This Match", #selector(applyMatch(_:))),
            (dismissButton, "Dismiss This Match", #selector(dismissMatch(_:))),
        ] {
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.actionSize),
                button.heightAnchor.constraint(equalToConstant: Self.actionSize),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            applyButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -Self.actionSpacing),
            excerptBeforeDismiss,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Sidebar result cells are programmatically constructed") }

    func configure(
        text: NSAttributedString, replacementAvailable: Bool, acceptsActions: Bool,
        selected: Bool, apply: (() -> Void)? = nil, dismiss: @escaping () -> Void
    ) {
        configureExcerpt(text)
        self.acceptsActions = acceptsActions
        // Keep the same text column whether the row actions are currently visible or hidden.
        if self.replacementAvailable != replacementAvailable {
            (self.replacementAvailable ? excerptBeforeApply : excerptBeforeDismiss).isActive = false
            (replacementAvailable ? excerptBeforeApply : excerptBeforeDismiss).isActive = true
            self.replacementAvailable = replacementAvailable
        }
        onApply = apply
        onDismiss = dismiss
        updateSelection(selected)
    }

    func updateSelection(_ selected: Bool) {
        self.selected = selected
        updateActions()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hover = false
        selected = false
        acceptsActions = false
        updateActions()
    }

    func updateHover(_ hovered: Bool) {
        guard hover != hovered else { return }
        hover = hovered
        updateActions()
    }

    private func updateActions() {
        let showDismiss = acceptsActions && (hover || selected)
        let showApply = showDismiss && replacementAvailable
        dismissButton.isHidden = !showDismiss
        applyButton.isHidden = !showApply
    }

    @objc private func applyMatch(_ sender: Any?) { onApply?() }
    @objc private func dismissMatch(_ sender: Any?) { onDismiss?() }
}
