import AppKit

struct SourceControlRevisionPreview: Sendable {
    enum Content: Sendable {
        case text(String, FileFormat, JJTextAnalysis)
        case media(OpenFilePreview)
    }

    let url: URL
    let changeID: String
    let subject: String
    let isDeleted: Bool
    let content: Content

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
            content = .text(current, format, analysis)
        } else if let bytes {
            let (details, backing) = await FilePreviewDetails.loadRevision(bytes, at: url)
            content = .media(OpenFilePreview(url: url, identity: nil, reason: "", details: details,
                                             mediaBacking: backing, allowsReveal: false))
        } else if let preview = metadata(for: file, at: url) {
            content = .media(preview)
        } else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try Task.checkCancellation()
        return Self(url: url, changeID: revision.shortID, subject: revision.subject, isDeleted: file.isDeleted, content: content)
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
    init(_ preview: SourceControlRevisionPreview) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let status = preview.isDeleted ? "Deleted File · Read-only" : "Read-only"
        let label = NSTextField(labelWithString: status)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let details = preview.subject.isEmpty ? preview.changeID : "\(preview.changeID) · \(preview.subject)"
        let change = NSTextField(labelWithString: details)
        change.lineBreakMode = .byTruncatingTail
        change.toolTip = details
        change.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        change.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        change.textColor = .secondaryLabelColor

        let lock = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil) ?? NSImage())
        lock.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [lock, label, change])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            lock.widthAnchor.constraint(equalToConstant: 11),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Revision banners are programmatically constructed") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
