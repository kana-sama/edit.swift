import AppKit

@MainActor
enum LanguageServerProgressCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "LSP progress check: \(detail)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: @escaping (NSView, String) throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ZLS build \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let buildFile = root.appending(path: "build.zig")
        try """
            const std = @import("std");
            pub fn build(b: *std.Build) void { _ = b; }

            """.write(to: buildFile, atomically: true, encoding: .utf8)

        let lsp = document.languageFeatures
        document.setFolder(FileBuffer.canonicalURL(root))
        try await wait("show initialization in the header") { lsp.statusIndicatorForCheck == .busy }
        try captureActivity("Initializing", in: lsp, suffix: "servers-initializing", capture: capture)
        try await wait("finish initializing before opening a Zig file") { lsp.statusIndicatorForCheck == .ready }

        let title = "Loading build configuration"
        var loading: Result<Void, Error>?
        let update = lsp.session.onProgressChange
        lsp.session.onProgressChange = {
            update?()
            guard loading == nil, lsp.session.progress.contains(where: { $0.title == title }) else { return }
            loading = Result {
                guard lsp.session.supportsDefinition else { throw Failure(detail: "keep language requests available during background work") }
                try captureActivity(title, in: lsp, suffix: "servers-build-progress", capture: capture)
                try capture(lsp.statusButton, "servers-header-progress")
            }
        }
        defer { lsp.session.onProgressChange = update }
        guard try await app.openFile(buildFile, in: document) === document else {
            throw Failure(detail: "open a project build file")
        }
        try await wait("receive build configuration progress from ZLS") { loading != nil }
        try loading?.get()
        try await wait("restore the ready dot after the build runner finishes") {
            lsp.session.progress.isEmpty && lsp.statusIndicatorForCheck == .ready && lsp.statusButton.image != nil
        }
    }

    private static func captureActivity(_ expected: String, in lsp: DocumentLanguageFeatures, suffix: String,
                                        capture: (NSView, String) throws -> Void) throws {
        guard let content = lsp.statusPopoverForCheck,
              let identity = content.subviews.first(where: { $0 is NSStackView }) as? NSStackView,
              let detail = identity.views.first(where: { $0.identifier?.rawValue == "Edit.LanguageServer.detail" }) as? NSTextField
        else { throw Failure(detail: "find the visible status line") }
        let button = lsp.statusButton
        let spinner = button.subviews.first(where: { $0 is NSProgressIndicator })
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !button.isHidden, button.title.isEmpty, lsp.statusIndicatorForCheck == .busy,
              button.toolTip?.contains(expected) == true, detail.stringValue == expected,
              reducedMotion ? button.image != nil : button.image == nil && spinner != nil
        else { throw Failure(detail: "show \(expected) in the header and popover") }

        let window = NSWindow(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = button.effectiveAppearance
        window.contentView = content
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        try capture(content, suffix)
    }

    private static func wait(_ detail: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}
