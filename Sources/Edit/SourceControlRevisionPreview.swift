import AppKit

struct SourceControlRevisionPreview: Sendable {
    enum Content: Sendable {
        case text(String, FileFormat, JJTextAnalysis, baseline: String?)
        case media(OpenFilePreview)
    }

    let url: URL
    let revision: JJSourceControlRevision
    let isDeleted: Bool
    let content: Content

    var changeID: String { revision.shortID }
    var subject: String { revision.subject }

    @concurrent
    static func prepare(
        _ contents: JJSourceControlFileContents, file: JJSourceControlFile, revision: JJSourceControlRevision, at url: URL
    ) async throws -> Self {
        let content: Content
        let bytes = file.isDeleted ? contents.base : contents.recorded
        if let bytes, let (text, format) = try? FileBuffer.decode(bytes, from: url), !text.utf8.contains(0) {
            let current = file.isDeleted ? "" : text
            let baseline: String?
            if file.isDeleted {
                baseline = text
            } else if let base = contents.base {
                baseline = (try? FileBuffer.decode(base, from: url))?.0
            } else {
                baseline = ""
            }
            let conflict = contents.isConflict && !file.isDeleted
            let analysis = JJLineDiff.analyze(base: baseline, current: current, isConflicted: conflict,
                                              recordedConflict: conflict ? current : nil)
            content = .text(current, format, analysis, baseline: baseline)
        } else if let bytes {
            let (details, backing) = await FilePreviewDetails.loadRevision(bytes, at: url)
            let reason = details.image == nil && !details.playableVideo ? "A text diff is unavailable for this file." : ""
            content = .media(OpenFilePreview(url: url, identity: nil, reason: reason, details: details,
                                             mediaBacking: backing, allowsReveal: false))
        } else if let preview = metadata(for: file, at: url) {
            content = .media(preview)
        } else if file.source == .absent && file.target == .absent {
            content = .media(OpenFilePreview(url: url, identity: nil, reason: "This path is absent from this revision.",
                                              details: .revisionEntry(kind: "Unavailable File"), allowsReveal: false))
        } else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try Task.checkCancellation()
        return Self(url: url, revision: revision, isDeleted: file.isDeleted, content: content)
    }

    static func metadata(for file: JJSourceControlFile, at url: URL) -> OpenFilePreview? {
        let kind: String
        switch file.isDeleted ? file.source : file.target {
        case .symlink: kind = "Symbolic Link"
        case .submodule: kind = "Git Submodule"
        case .tree: kind = "Directory"
        case .absent, .file, .conflict: return nil
        }
        return OpenFilePreview(url: url, identity: nil, reason: file.statusName,
                               details: .revisionEntry(kind: kind), allowsReveal: false)
    }
}

@MainActor
final class SourceControlRevisionBanner: NSView {
    enum Presentation {
        case full, label, icon
    }

    private static let gap: CGFloat = 5
    private static let inset: CGFloat = 6
    private static let iconWidth: CGFloat = 12
    private let preview: SourceControlRevisionPreview
    private let linkContext: SourceControlRevisionHover.LinkContext?
    private weak var ownerWindow: NSWindow?
    private let hover = SourceControlRevisionHover()
    private let label: NSTextField
    private let change: NSTextField
    private var hoverTrackingArea: NSTrackingArea?

    var presentation: Presentation = .full {
        didSet {
            guard oldValue != presentation else { return }
            label.isHidden = presentation == .icon
            change.isHidden = presentation != .full
            invalidateIntrinsicContentSize()
            dismissHover()
        }
    }

    init(_ preview: SourceControlRevisionPreview, linkContext: SourceControlRevisionHover.LinkContext? = nil,
         ownerWindow: NSWindow? = nil) {
        self.preview = preview
        self.linkContext = linkContext
        self.ownerWindow = ownerWindow
        let status = preview.isDeleted ? "Deleted File · Read-only" : "Read-only"
        label = NSTextField(labelWithString: status)
        change = NSTextField(labelWithString: preview.changeID)
        super.init(frame: .zero)
        identifier = .init("JujutsuReadOnlyStatus")
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(status), \(preview.changeID), \(preview.subject)")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.allowsExpansionToolTips = false
        label.setAccessibilityElement(false)
        change.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        change.allowsExpansionToolTips = false
        change.setAccessibilityElement(false)

        let lock = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil) ?? NSImage())
        lock.setAccessibilityElement(false)
        lock.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [lock, label, change])
        stack.spacing = Self.gap
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: Self.iconWidth),
            lock.heightAnchor.constraint(equalToConstant: Self.iconWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Revision indicators are created in code.") }

    override var mouseDownCanMoveWindow: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: width(for: presentation), height: 23) }

    func width(for presentation: Presentation) -> CGFloat {
        let icon = Self.iconWidth + 2 * Self.inset
        let labeled = icon + Self.gap + ceil(label.intrinsicContentSize.width)
        return switch presentation {
        case .full: labeled + Self.gap + ceil(change.intrinsicContentSize.width)
        case .label: labeled
        case .icon: icon
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { trackHover(with: event) }

    override func mouseMoved(with event: NSEvent) { trackHover(with: event) }

    override func mouseExited(with event: NSEvent) {
        if let window { hover.pointerLeft(at: window.convertPoint(toScreen: event.locationInWindow)) }
    }

    func dismissHover() { hover.dismiss() }

    private func trackHover(with event: NSEvent) {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        hover.track(preview.revision, at: point, in: self, owner: ownerWindow ?? window, linkContext: linkContext)
    }
}
