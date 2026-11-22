import AppKit

@MainActor
enum OpenFilePanelCheck {
    static func run() async throws {
        let panel = OpenFilePanel()
        let stalled = Process()
        stalled.executableURL = URL(filePath: "/bin/sleep")
        stalled.arguments = ["30"]
        var outcome: Result<URL?, Error>?
        defer { panel.cancel() }

        try expect(panel.start(stalled, startupTimeout: .milliseconds(240)) { outcome = $0 },
                   "start one native picker request")
        let repeated = Process()
        repeated.executableURL = stalled.executableURL
        repeated.arguments = stalled.arguments
        try expect(!panel.start(repeated) { _ in }, "ignore a repeated request before a picker appears")
        try await Task.sleep(for: .milliseconds(20))
        try expect(panel.isOpening && outcome == nil && stalled.isRunning && !repeated.isRunning,
                   "keep the main actor responsive while one picker is blocked")

        try await waitUntil("finish the stalled request and stop its process") { outcome != nil && !stalled.isRunning }
        guard let outcome, case .failure(OpenFilePanel.Failure.startupTimedOut) = outcome,
              !panel.isOpening else { throw Failure("release the chooser after its startup timeout") }

        let picked = URL(filePath: "/tmp/Edit Open check/space & line\nbreak.swift")
        let lateSelection = try scripted([.initialized, .visible], then: .selected(picked))
        let selected = try await complete(panel, with: lateSelection, timeout: .milliseconds(400)).get()
        try expect(selected == picked, "accept a native file URL after the startup deadline once the dialog is visible")

        let folder = FileManager.default.temporaryDirectory.appending(path: "Open panel check \(UUID())",
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folderSelection = try scripted([.visible, .selected(folder, bookmark: bookmark)])
        let selectedFolder = try await complete(panel, with: folderSelection).get()
        try expect(selectedFolder?.standardizedFileURL.path == folder.standardizedFileURL.path,
                   "receive a folder and its access bookmark from the picker process")

        let cancelled = try scripted([.visible, .cancelled])
        let cancellation = try await complete(panel, with: cancelled).get()
        try expect(cancellation == nil && !panel.isOpening, "allow reopening after the user cancels")

        let earlyCancellation = try scripted([.cancelled])
        guard case .failure(OpenFilePanel.Failure.unavailable) = try await complete(panel, with: earlyCancellation)
        else { throw Failure("report a picker that closes before appearing") }

        let crashed = Process()
        crashed.executableURL = URL(filePath: "/usr/bin/false")
        guard case .failure(OpenFilePanel.Failure.unavailable) = try await complete(panel, with: crashed)
        else { throw Failure("recover from a picker process that exits without a result") }

        // Exercise the real constructor in the agent bundle without putting up a window.
        guard let native = OpenFilePanelHelper.process(directory: FileManager.default.temporaryDirectory, probe: true)
        else { throw Failure("locate the native picker executable") }
        let nativeResult = try await complete(panel, with: native).get()
        try expect(nativeResult == nil && !panel.isOpening && !NSApp.isActive,
                   "initialize a real NSOpenPanel in a separate process without activating either app")
    }

    private static func complete(_ panel: OpenFilePanel, with process: Process,
                                 timeout: Duration = .seconds(6)) async throws -> Result<URL?, Error> {
        var outcome: Result<URL?, Error>?
        try expect(panel.start(process, startupTimeout: timeout) { outcome = $0 }, "start the next picker")
        try await waitUntil("receive the next picker result") { outcome != nil }
        guard let outcome else { throw Failure("receive the next picker result") }
        return outcome
    }

    private static func scripted(_ first: [OpenPanelMessage], then last: OpenPanelMessage? = nil) throws -> Process {
        let encoder = JSONEncoder()
        func line(_ message: OpenPanelMessage) throws -> String {
            String(decoding: try encoder.encode(message), as: UTF8.self)
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", #"printf '%s\n' "$1"; if [ -n "$2" ]; then sleep 0.6; printf '%s\n' "$2"; fi"#,
                             "dialog-fixture", try first.map(line).joined(separator: "\n"), try last.map(line) ?? ""]
        return process
    }

    private static func waitUntil(_ detail: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while !condition() {
            guard clock.now < deadline else { throw Failure(detail) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Open dialog: \(detail)" }
    }
}
