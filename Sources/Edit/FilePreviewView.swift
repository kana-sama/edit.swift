import AppKit

@MainActor
final class FilePreviewView: NSView {
    private let url: URL
    private let scrollView = NSScrollView()
    private let document = PreviewScrollDocument()
    private let content = NSStackView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let metadata = NSStackView()
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private lazy var contentWidth = content.widthAnchor.constraint(equalToConstant: 0)
    private var mediaHeightLimit: NSLayoutConstraint?
    private var loadTask: Task<Void, Never>?
    private var video: FileVideoPreviewView?

    init(url: URL, reason: String) {
        self.url = url
        super.init(frame: .zero)
        configure(reason: reason)
        loadTask = Task { [weak self] in
            let details = await FilePreviewDetails.load(url)
            guard !Task.isCancelled else { return }
            self?.show(details)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loadTask?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }

    func stop() {
        loadTask?.cancel()
        video?.stop()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        let viewport = scrollView.contentSize
        let width = min(544, max(1, viewport.width - 48))
        contentWidth.constant = width
        mediaHeightLimit?.constant = min(330, max(108, floor(viewport.height * 0.52)))
        let height = max(viewport.height, ceil(content.fittingSize.height) + 48)
        let size = NSSize(width: viewport.width, height: height)
        if document.frame.size != size {
            document.setFrameSize(size)
        }
    }

    private func configure(reason: String) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        addSubview(scrollView)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let filename = NSTextField(wrappingLabelWithString: url.lastPathComponent)
        filename.font = .systemFont(ofSize: 17, weight: .semibold)
        filename.textColor = .labelColor
        filename.maximumNumberOfLines = 0
        filename.lineBreakMode = .byCharWrapping
        filename.isSelectable = true
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 0
        summary.isHidden = true
        message.stringValue = reason
        message.isHidden = reason.isEmpty
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 0
        message.isSelectable = true

        let introduction = NSStackView(views: [filename, summary, message])
        introduction.orientation = .vertical
        introduction.alignment = .leading
        introduction.spacing = 4
        content.addArrangedSubview(introduction)
        introduction.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 5
        content.addArrangedSubview(metadata)
        metadata.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        revealButton.target = self
        revealButton.action = #selector(revealInFinder)
        revealButton.bezelStyle = .rounded
        content.addArrangedSubview(revealButton)
        revealButton.isHidden = true

        let safeArea = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            contentWidth,
        ])
    }

    private func show(_ details: FilePreviewDetails) {
        if details.playableVideo {
            let player = FileVideoPreviewView(url: url, poster: details.image)
            video = player
            addMedia(player, width: details.width ?? 16, height: details.height ?? 9)
        } else if let image = details.image {
            let preview = NSImageView(image: NSImage(cgImage: image, size: .zero))
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.setAccessibilityElement(true)
            preview.setAccessibilityLabel("Preview of \(url.lastPathComponent)")
            addMedia(preview, width: image.width, height: image.height)
        }

        if details.image == nil && !details.playableVideo && message.stringValue.isEmpty {
            message.stringValue = "A preview is unavailable for this file."
            message.isHidden = false
        }
        let size = details.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        summary.stringValue = [details.kind, size].compactMap { $0 }.joined(separator: " – ")
        summary.isHidden = false
        if let width = details.width, let height = details.height {
            addMetadata("Dimensions", "\(width) × \(height)")
        }
        if let duration = details.duration {
            let pattern: Duration.TimeFormatStyle.Pattern = duration >= 3600 ? .hourMinuteSecond : .minuteSecond
            addMetadata("Duration", Duration.seconds(duration).formatted(.time(pattern: pattern)))
        }
        if let created = details.created {
            addMetadata("Created", created.formatted(date: .abbreviated, time: .shortened))
        }
        if let modified = details.modified {
            addMetadata("Modified", modified.formatted(date: .abbreviated, time: .shortened))
        }
        addMetadata("Path", url.path(percentEncoded: false))
        revealButton.isHidden = details.size == nil && details.modified == nil
        needsLayout = true
    }

    private func addMedia(_ media: NSView, width: Int, height: Int) {
        media.wantsLayer = true
        media.layer?.cornerRadius = 6
        media.layer?.masksToBounds = true
        content.insertArrangedSubview(media, at: 0)
        content.setCustomSpacing(16, after: media)
        let aspectRatio = CGFloat(max(1, height)) / CGFloat(max(1, width))
        let naturalHeight = media.heightAnchor.constraint(equalTo: media.widthAnchor, multiplier: aspectRatio)
        naturalHeight.priority = .defaultHigh
        media.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        media.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let heightLimit = media.heightAnchor.constraint(lessThanOrEqualToConstant: 330)
        mediaHeightLimit = heightLimit
        NSLayoutConstraint.activate([
            media.widthAnchor.constraint(equalTo: content.widthAnchor),
            media.heightAnchor.constraint(greaterThanOrEqualToConstant: 108),
            heightLimit,
            naturalHeight,
        ])
    }

    private func addMetadata(_ label: String, _ value: String) {
        if !metadata.arrangedSubviews.isEmpty {
            let divider = NSBox()
            divider.boxType = .separator
            metadata.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: metadata.widthAnchor).isActive = true
        }
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        name.textColor = .secondaryLabelColor
        name.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.isSelectable = true
        field.alignment = label == "Path" ? .left : .right
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byCharWrapping
        let row = NSStackView(views: [name, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        metadata.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: metadata.widthAnchor),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private final class PreviewScrollDocument: NSView {
    override var isFlipped: Bool { true }
}
