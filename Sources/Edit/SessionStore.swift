import AppKit
import Darwin
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

struct DocumentTerminalState: Codable, Sendable {
    let panel: TerminalPanelState
    let sizes: TerminalDockSizes
    let isVisible: Bool
    let wasFocused: Bool
}

// Keep the existing session fields while search and sidebar state are managed separately at runtime.
struct SessionFindSettings: Codable, Equatable, Sendable {
    static let defaultWidth: Double = 280
    static let empty = Self(search: FindSettings(), sidebarVisible: false, sidebarWidth: defaultWidth)

    var visible: Bool
    var showsReplacement: Bool
    var query: String
    var replacement: String
    var options: FindOptions
    var width: Double

    init(search: FindSettings, sidebarVisible: Bool, sidebarWidth: Double) {
        visible = sidebarVisible
        showsReplacement = search.showsReplacement
        query = search.query
        replacement = search.replacement
        options = search.options
        width = sidebarWidth
    }

    var search: FindSettings {
        FindSettings(showsReplacement: showsReplacement, query: query, replacement: replacement, options: options)
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
    var findSettings: SessionFindSettings? = nil
    var editorPosition: EditorPosition? = nil
    var sidebarMode: SidebarMode? = nil
    var worktreeShowsHidden: Bool? = nil
    var isFilePreview: Bool? = nil
    var showsEmptyFolder: Bool? = nil
    var terminal: DocumentTerminalState? = nil
    var draftRecovery: DraftRecoveryRevision? = nil
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
        try Self.writePrivate(JSONEncoder().encode(session), to: url)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".edit-session-\(UUID().uuidString)")
        // Drafts and terminal output can contain private text.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
