import AppKit
import Foundation

struct WindowPlacement: Codable, Sendable {
    var frame: CGRect
    var isFullScreen: Bool

    @MainActor
    func restoreFrame(on window: NSWindow) {
        guard frame.minX.isFinite, frame.minY.isFinite,
              frame.maxX.isFinite, frame.maxY.isFinite,
              frame.size.width > 0, frame.size.height > 0 else {
            window.center()
            return
        }

        let screens = NSScreen.screens
        let titleBarPoint = CGPoint(x: frame.midX, y: frame.maxY.nextDown)
        if screens.contains(where: { $0.visibleFrame.contains(titleBarPoint) }) {
            window.setFrame(frame, display: false)
            return
        }

        let overlappingScreen = screens.max {
            let first = $0.visibleFrame.intersection(frame)
            let second = $1.visibleFrame.intersection(frame)
            return first.width * first.height < second.width * second.height
        }
        let visibleBounds = overlappingScreen?.visibleFrame
        let overlapsDisplay = visibleBounds?.intersects(frame) == true
        guard let bounds = overlapsDisplay
            ? visibleBounds
            : (window.screen ?? NSScreen.main ?? screens.first)?.visibleFrame else {
            window.center()
            return
        }

        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        let x = overlapsDisplay
            ? min(max(frame.minX, bounds.minX), bounds.maxX - width)
            : bounds.midX - width / 2
        let y = overlapsDisplay
            ? min(max(frame.minY, bounds.minY), bounds.maxY - height)
            : bounds.midY - height / 2
        window.setFrame(CGRect(x: x, y: y, width: width, height: height), display: false)
    }
}

struct SessionDocument: Codable, Sendable {
    var path: String?
    var draft: String?
    var format: FileFormat?
    var revision: FileRevision?
    var placement: WindowPlacement
    var syntaxLanguage: String? = nil
    var folderPath: String? = nil
    var findSettings: FindSettings? = nil
    var editorPosition: EditorPosition? = nil
    var sidebarMode: SidebarMode? = nil
    var worktreeShowsHidden: Bool? = nil
    var isFilePreview: Bool? = nil
    var showsEmptyFolder: Bool? = nil
}

struct EditorSession: Codable, Sendable {
    var documents: [SessionDocument]
    var activeIndex: Int?
    var lastWindow: WindowPlacement?
}

struct SessionStore: Sendable {
    let url: URL

    static func application() -> SessionStore {
        let url = URL.applicationSupportDirectory
            .appending(path: "dev.edit-swift.Edit", directoryHint: .isDirectory)
            .appending(path: "session.json", directoryHint: .notDirectory)
        return SessionStore(url: url)
    }

    func read() throws -> EditorSession? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(EditorSession.self, from: data)
    }

    func write(_ session: EditorSession) throws {
        let data = try JSONEncoder().encode(session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
