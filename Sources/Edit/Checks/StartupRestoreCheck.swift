import AppKit

@MainActor
enum StartupRestoreCheck {
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        var isWaiting: Bool { continuation != nil }

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct Frame {
        let rect: CGRect
        let title: String
        let folder: URL?
        let text: String
        let ordered: Bool
        let window: DocumentWindow

        @MainActor
        init(_ document: DocumentWindow) {
            rect = document.window.frame
            title = document.window.title
            folder = document.folderURL
            text = document.editor.string
            ordered = document.window.isVisible
            window = document
        }
    }

    static func run(in app: Edit) async throws {
        // Run the production startup path without arranging for a placeholder window.
        let existing = app.documents
        existing.forEach { $0.window.close() }
        let root = URL(filePath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
                       directoryHint: .isDirectory).appending(path: "startup-restore", directoryHint: .isDirectory)
        let folder = root.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slow = folder.appending(path: "Slow.txt")
        let fast = folder.appending(path: "Fast.txt")
        try Data("slow document".utf8).write(to: slow)
        try Data("fast document".utf8).write(to: fast)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let slowFrame = CGRect(x: screen.minX + 30, y: screen.minY + 40, width: 640, height: 440)
        let fastFrame = CGRect(x: screen.minX + 110, y: screen.minY + 95, width: 605, height: 380)
        let store = SessionStore(url: root.appending(path: "session.json"))
        let slowRecord = SessionDocument(path: slow.path, placement: .init(frame: slowFrame, isFullScreen: false),
                                         folderPath: folder.path)
        let fastRecord = SessionDocument(path: fast.path, placement: .init(frame: fastFrame, isFullScreen: false),
                                         folderPath: folder.path)
        try store.write(EditorSession(documents: [slowRecord, fastRecord], activeIndex: 1, lastWindow: nil))

        var frames: [Frame] = []
        let sessionGate = Gate()
        let fileGate = Gate()
        app.holdSessionFileReadForCheck = { url in
            if url == slow { await fileGate.wait() }
        }
        app.observeStartupPresentationForCheck = { frames.append(Frame($0)) }
        defer {
            app.holdSessionFileReadForCheck = nil
            app.observeStartupPresentationForCheck = nil
            app.documents.forEach { $0.window.close() }
            app.makeDocument()
        }

        let restore = Task {
            let read = Task {
                await sessionGate.wait()
                return try await app.readStartupSession(from: store).value
            }
            await app.restoreStartupSession(from: read)
        }
        do {
            try await waitFor("startup waiting for session") { sessionGate.isWaiting }
            try expect(app.documents.isEmpty && frames.isEmpty, "no default window while session geometry is pending")
            sessionGate.release()
            try await waitFor("fast window while the first file is pending") { fileGate.isWaiting && frames.count == 1 }
            try expect(app.documents.count == 1, "a pending file did not create an empty window")
            let first = frames[0]
            try expect(first.ordered && first.rect == fastFrame && first.folder == folder
                       && first.title.contains("Fast.txt") && first.text == "fast document",
                       "the first ordered frame already has saved geometry, project, title and text")
            fileGate.release()
            await restore.value
            try expect(frames.count == 2, "each restored document is presented once")
            let second = frames[1]
            try expect(second.ordered && second.rect == slowFrame && second.folder == folder
                       && second.title.contains("Slow.txt") && second.text == "slow document",
                       "the slow document's first ordered frame has matching geometry and content")
            try expect(app.documents.first === second.window && app.documents.last === first.window,
                       "independent completion preserves saved session order")
        } catch {
            sessionGate.release()
            fileGate.release()
            await restore.value
            throw error
        }

        app.documents.forEach { $0.window.close() }
        frames.removeAll()
        try store.write(EditorSession(documents: [], activeIndex: nil,
                                      lastWindow: .init(frame: fastFrame, isFullScreen: false)))
        await app.restoreStartupSession(from: app.readStartupSession(from: store))
        try expect(frames.count == 1 && frames[0].ordered && frames[0].rect == fastFrame,
                   "an empty saved session opens its fallback directly at the remembered frame")

        app.documents.forEach { $0.window.close() }
        frames.removeAll()
        var fullscreen = fastRecord
        fullscreen.placement.isFullScreen = true
        try store.write(EditorSession(documents: [fullscreen], activeIndex: 0, lastWindow: nil))
        await app.restoreStartupSession(from: app.readStartupSession(from: store))
        try expect(frames.count == 1 && !frames[0].ordered && frames[0].rect == fastFrame,
                   "a fullscreen restore does not order the normal window as a regular presentation")
        let document = frames[0].window
        try await waitFor("transparent fullscreen staging window") { document.window.isVisible }
        try expect(document.window.alphaValue == 0 && document.window.ignoresMouseEvents
                   && document.placement.isFullScreen && document.placement.frame == fastFrame,
                   "the staged native window is hidden and retains its normal frame throughout the transition")
        // The isolated app must never switch the owner's Space. Exercise the failure callback in place.
        document.windowDidFailToEnterFullScreen(document.window)
        try expect(!document.placement.isFullScreen && document.window.frame == fastFrame
                   && !NSApp.isActive && document.window.alphaValue == 0,
                   "a failed transition leaves the restored regular frame without exposing the test window")
        print("Edit passed its native startup first-frame checks without activation.")
    }

    private static func waitFor(_ description: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition() {
            try expect(clock.now < deadline, description)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else {
            throw CocoaError(.validationMissingMandatoryProperty, userInfo: [NSLocalizedDescriptionKey: description])
        }
    }
}
