import AppKit

@MainActor
enum LSPDiagnosticsCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "LSP diagnostics check: \(detail)" }
    }

    static func run(in app: Edit, document: DocumentWindow, capture: (NSWindow) throws -> Void) async throws {
        try checkPublications()
        let files = FileManager.default
        let root = FileBuffer.canonicalURL(files.temporaryDirectory.appending(path: "LSP Diagnostics # \(UUID())"))
        let sources = root.appending(path: "Sources/Fixture")
        let cRoot = root.appending(path: "C")
        try files.createDirectory(at: sources, withIntermediateDirectories: true)
        try files.createDirectory(at: cRoot, withIntermediateDirectories: true)
        defer {
            if app.documents.contains(where: { $0 === document }) { document.window.close() }
            try? files.removeItem(at: root)
        }
        let zig = root.appending(path: "Error.zig")
        let swift = sources.appending(path: "Error.swift")
        let odin = root.appending(path: "Error.odin")
        let c = cRoot.appending(path: "Error.c")
        let clean = root.appending(path: "Clean.txt")
        let zigText = "pub const label = \"🧩\"; pub const value = );\r\n"
        let swiftText = "let label = \"🧩\"; let value = missingName\r\n"
        let odinText = "package fixture\nmain :: proc() { x := ) }\n"
        let cText = "int value(void) { return missing_name; }\n"
        try zigText.write(to: zig, atomically: true, encoding: .utf8)
        try swiftText.write(to: swift, atomically: true, encoding: .utf8)
        try odinText.write(to: odin, atomically: true, encoding: .utf8)
        try cText.write(to: c, atomically: true, encoding: .utf8)
        try "clean\n".write(to: clean, atomically: true, encoding: .utf8)
        try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
            """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try #"{"enable_parser_errors":true}"#.write(to: root.appending(path: "ols.json"), atomically: true, encoding: .utf8)

        document.setFolder(root)
        let editor = document.editor
        try require(try await app.openFile(zig, in: document) === document, "open Zig fixture")
        let zigError = (zigText as NSString).range(of: ")")
        try await wait("receive the ZLS error after an astral character") {
            editor.diagnosticRanges.contains { $0.location == zigError.location }
        }
        document.toggleHighlighting(.lsp)
        document.window.layoutIfNeeded()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try require(!document.isHighlightingEnabled(.lsp) && !editor.diagnosticRanges.isEmpty,
                    "keep diagnostics with semantic colors off")
        let rects = editor.diagnosticRects()
        try require(!rects.isEmpty, "lay out the underline in the native editor")
        try require(try hasRedPixels(in: rects, document: document), "paint the underline in the native editor")
        try capture(document.window)

        editor.insertText("1", replacementRange: zigError)
        try require(editor.diagnosticRanges.isEmpty, "clear the old revision immediately after the edit")
        try require(try !hasRedPixels(in: rects, document: document), "remove the underline from the native editor")
        editor.undoManager?.undo()
        try require(editor.string == zigText, "restore the errored source with Undo")
        try await wait("repaint the ZLS error after Undo") { !editor.diagnosticRanges.isEmpty }
        let features = document.languageFeatures
        features.perform(.stop)
        try require(editor.diagnosticRanges.isEmpty, "clear diagnostics as soon as the server is stopped")
        try await wait("stop ZLS") { features.session.state == .stopped }
        features.perform(.start)
        try await wait("receive fresh diagnostics after server start") { !editor.diagnosticRanges.isEmpty }

        let title = document.window.title
        let (heldOpen, finishOpen) = AsyncStream<Void>.makeStream()
        var pending = false
        document.beforeInstallFileForCheck = { incoming in
            guard incoming.url == clean else { return }
            pending = true
            for await _ in heldOpen { break }
        }
        let opening = Task { try await app.openFile(clean, in: document) }
        defer {
            document.beforeInstallFileForCheck = nil
            finishOpen.finish()
            opening.cancel()
        }
        try await wait("hold the incoming text file") { pending }
        try require(document.window.title == title && editor.string == zigText && !editor.diagnosticRanges.isEmpty,
                    "keep the outgoing title, buffer, and diagnostics together")
        finishOpen.finish()
        try require(try await opening.value === document, "open the clean file")
        try require(document.window.title.hasSuffix("Clean.txt") && editor.diagnosticRanges.isEmpty,
                    "clear outgoing diagnostics on the first presentation of the new file")

        for (url, text, marker, server) in [(swift, swiftText, "missingName", LanguageServer.sourceKit),
                                            (odin, odinText, "main ::", .odin)] {
            try require(try await app.openFile(url, in: document) === document, "open \(server.name) fixture")
            let error = (text as NSString).range(of: marker)
            try await wait("receive \(server.name) diagnostics for \(marker)") {
                editor.diagnosticRanges.contains { $0.location == error.location }
            }
        }
        document.setFolder(cRoot)
        try require(try await app.openFile(c, in: document) === document, "open C fixture")
        let cError = (cText as NSString).range(of: "missing_name")
        try await wait("receive the Clang error through SourceKit-LSP") {
            editor.diagnosticRanges.contains { $0.location == cError.location }
        }
        document.window.close()
        try await wait("stop the fixture servers") { features.serversStoppedForCheck }
    }

    private static func checkPublications() throws {
        let text = "🧩 bad\r\nother"
        let url = URL(filePath: "/tmp/Diagnostics.swift")
        let document = LSPDocument(url: url, language: .swift, text: text, revision: 7)
        let index = LSPTextIndex(text)
        let error = #"{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"severity":1}"#
        let warning = #"{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"severity":2}"#
        let invalid = #"{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}}}"#
        func decode(_ uri: URL, _ version: Int?, _ items: [String]) throws -> [NSRange]? {
            let versionField = version.map { "\"version\":\($0)," } ?? ""
            let json = "{\"uri\":\"\(uri.absoluteString)\",\(versionField)\"diagnostics\":[\(items.joined(separator: ","))]}"
            return try JSONDecoder().decode(LSPPublishedDiagnostics.self, from: Data(json.utf8))
                .errors(for: document, index: index)
        }
        try require(try decode(url, 7, [warning, error, error, invalid]) == [NSRange(location: 3, length: 3)],
                    "filter warnings and invalid UTF-16 ranges and deduplicate errors")
        try require(try decode(url, 6, [error]) == nil && decode(url.appendingPathExtension("old"), 7, [error]) == nil,
                    "ignore both stale versions and other documents")
        try require(try decode(url, nil, [error])?.count == 1 && decode(url, 7, []) == [],
                    "accept unversioned reports and an empty replacement")
    }

    private static func hasRedPixels(in rects: [NSRect], document: DocumentWindow) throws -> Bool {
        let clip = document.scrollView.contentView
        let bounds = clip.bounds
        guard let bitmap = clip.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure(detail: "capture editor pixels") }
        clip.cacheDisplay(in: bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / bounds.width
        for rect in rects {
            let stripe = NSRect(x: rect.minX, y: rect.maxY - 4, width: rect.width, height: 4)
            let frame = clip.convert(stripe, from: document.editor)
            let x = Int(((frame.minX - bounds.minX) * scale).rounded(.down))..<Int(((frame.maxX - bounds.minX) * scale).rounded(.up))
            let y = Int(((frame.minY - bounds.minY) * scale).rounded(.down))..<Int(((frame.maxY - bounds.minY) * scale).rounded(.up))
            for row in y where (0..<bitmap.pixelsHigh).contains(row) {
                for column in x where (0..<bitmap.pixelsWide).contains(column) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    if pixel.redComponent > pixel.greenComponent + 0.15 && pixel.redComponent > pixel.blueComponent + 0.15 {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func wait(_ detail: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try require(ContinuousClock.now < deadline, detail)
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure(detail: detail) }
    }
}
