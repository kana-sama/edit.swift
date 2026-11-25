import AppKit

@MainActor
enum LanguageServerStateCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "LSP workspace state: \(detail)" }
    }

    static func run(in app: Edit, replacing initial: DocumentWindow, capture: (NSWindow) throws -> Void) async throws {
        let files = FileManager.default
        let profile = files.temporaryDirectory
        let workspace = FileBuffer.canonicalURL(profile.appending(path: "LSP Workspace", directoryHint: .isDirectory))
        let firstProject = workspace.appending(path: "First", directoryHint: .isDirectory)
        let secondProject = workspace.appending(path: "Second", directoryHint: .isDirectory)
        let header = firstProject.appending(path: "Fixture.h")
        let otherHeader = secondProject.appending(path: "Other.h")
        let restoring = files.fileExists(atPath: header.path)
        let suite = "dev.edit-swift.Edit.agent.lsp-state.\(profile.lastPathComponent)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(detail: "open isolated preferences") }
        var keepPreferences = false
        defer { if !keepPreferences { defaults.removePersistentDomain(forName: suite) } }

        let text = """
            #ifndef FIXTURE_H
            #define FIXTURE_H
            #include <stdint.h>
            typedef void (*FixtureCallback)(uint32_t value);
            #endif
            """
        if !restoring {
            for (project, file) in [(firstProject, header), (secondProject, otherHeader)] {
                try files.createDirectory(at: project, withIntermediateDirectories: true)
                try "-std=c++17\n".write(to: project.appending(path: "compile_flags.txt"), atomically: true, encoding: .utf8)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        initial.window.close()
        app.workspaceLanguageServers = WorkspaceLanguageServers(defaults: defaults)
        let document = app.makeDocument()
        defer { document.window.close() }
        let lsp = document.languageFeatures
        document.setFolder(workspace)
        if restoring {
            try await wait("show the stopped workspace before opening a source file") {
                lsp.statusIndicatorForCheck == .stopped
            }
        }
        try require(try await app.openFile(header, in: document) === document, "open the C header")
        let session = lsp.session

        if restoring {
            try await wait("restore SourceKit-LSP as stopped after relaunch") {
                session.isEligible && session.state == .stopped && lsp.statusIndicatorForCheck == .stopped
            }
            try require(lsp.canPerform(.start), "offer an explicit start after restoration")
            try require(!app.workspaceLanguageServers.isStopped(.zig, in: workspace), "keep ZLS enabled independently")
            lsp.perform(.start)
            try await wait("explicitly start the restored server") { session.state == .ready }
            try require(!WorkspaceLanguageServers(defaults: defaults).isStopped(.sourceKit, in: workspace),
                        "persist the explicit start")
            lsp.perform(.stop)
            try await wait("stop after explicit start") { session.state == .stopped }
            lsp.perform(.restart)
            try await wait("explicitly restart the stopped server") { session.state == .ready }
            try require(!WorkspaceLanguageServers(defaults: defaults).isStopped(.sourceKit, in: workspace),
                        "persist the explicit restart")
            return
        }

        let peer = app.makeDocument()
        defer { peer.window.close() }
        peer.setFolder(workspace)
        try require(try await app.openFile(otherHeader, in: peer) === peer, "open a second project in the same workspace")
        let peerSession = peer.languageFeatures.session
        try await wait("start SourceKit-LSP for both projects") { session.state == .ready && peerSession.state == .ready }
        try require(session.workspaceRoot?.path == firstProject.path && peerSession.workspaceRoot?.path == secondProject.path,
                    "use distinct compilation databases in the same workspace")
        lsp.perform(.stop)
        try await wait("stop the server in both workspace windows") {
            session.state == .stopped && peerSession.state == .stopped && lsp.statusIndicatorForCheck == .stopped
        }
        try require(document.resolvedSyntaxLanguage == .cpp, "auto-detect the header as C++")
        if let manager = document.editor.textLayoutManager {
            for token in ["#ifndef", "<stdint.h>", "typedef", "uint32_t"] {
                try await SyntaxCheck.waitForColor(at: (text as NSString).range(of: token), in: manager)
            }
        } else { throw Failure(detail: "get the header's rendering attributes") }
        try capture(document.window)

        peer.setFolder(secondProject)
        try await wait("allow a different workspace to start the server for the same project") { peerSession.state == .ready }
        try require(session.state == .stopped, "leave the original workspace stopped")
        keepPreferences = true
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure(detail: detail) }
    }

    private static func wait(_ detail: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
