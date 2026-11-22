import AppKit
import AVFoundation
import AVKit
import ImageIO
import UniformTypeIdentifiers

struct FilePreviewDetails: Sendable {
    let kind: String
    let size: Int64?
    let created: Date?
    let modified: Date?
    private(set) var width: Int?
    private(set) var height: Int?
    private(set) var duration: Double?
    private(set) var image: CGImage?
    private(set) var playableVideo = false

    private static let previewPixelLimit = 1600

    @concurrent
    static func load(_ url: URL) async -> Self {
        let target = url.resolvingSymlinksInPath()
        let values = try? target.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isRegularFileKey
        ])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        var details = Self(
            kind: type?.localizedDescription ?? "File",
            size: values?.fileSize.map(Int64.init),
            created: values?.creationDate,
            modified: values?.contentModificationDate
        )
        guard values?.isRegularFile == true, !Task.isCancelled else { return details }

        if type?.conforms(to: .image) == true {
            details.loadImage(target)
        } else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            await details.loadVideo(target)
        }
        return details
    }

    private mutating func loadImage(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return }

        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int
            height = properties[kCGImagePropertyPixelHeight] as? Int
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
        }
        guard !Task.isCancelled else { return }
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.previewPixelLimit
        ] as CFDictionary)
    }

    private mutating func loadVideo(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first,
              !Task.isCancelled else { return }

        if let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
            width = Int(exactly: bounds.width.rounded())
            height = Int(exactly: bounds.height.rounded())
        }
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds >= 0 {
            duration = seconds
        }
        playableVideo = (try? await asset.load(.isPlayable)) == true

        guard !Task.isCancelled else { return }
        let start = (try? await track.load(.timeRange).start) ?? .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.previewPixelLimit, height: Self.previewPixelLimit)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        image = try? await generator.image(at: start).image
    }
}

@MainActor
final class FileVideoPreviewView: NSView {
    private let url: URL
    private let playerView = AVPlayerView()
    private var firstFrameObservation: NSKeyValueObservation?

    init(url: URL, poster: CGImage?) {
        self.url = url
        super.init(frame: .zero)
        playerView.controlsStyle = .none
        playerView.updatesNowPlayingInfoCenter = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let poster, let overlay = playerView.contentOverlayView {
            let image = NSImageView(image: NSImage(cgImage: poster, size: .zero))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                image.topAnchor.constraint(equalTo: overlay.topAnchor),
                image.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
            ])
            firstFrameObservation = playerView.observe(\.isReadyForDisplay, options: [.initial, .new]) {
                [weak self, weak image] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor in
                    image?.removeFromSuperview()
                    self?.firstFrameObservation = nil
                }
            }
        }

        let play = NSButton(title: "Play", target: self, action: #selector(startPlayback(_:)))
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.bezelStyle = .rounded
        play.translatesAutoresizingMaskIntoConstraints = false
        addSubview(play)
        NSLayoutConstraint.activate([
            play.centerXAnchor.constraint(equalTo: centerXAnchor),
            play.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func startPlayback(_ sender: NSButton) {
        let player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        playerView.player = player
        window?.makeFirstResponder(playerView)
        sender.removeFromSuperview()
        player.play()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { playerView.player?.pause() }
        super.viewWillMove(toWindow: newWindow)
    }

    func stop() {
        firstFrameObservation = nil
        playerView.player?.pause()
        playerView.player = nil
    }
}
