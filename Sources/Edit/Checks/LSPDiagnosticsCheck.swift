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
        let underlines = rects.map { NSRect(x: $0.minX, y: $0.maxY - 4, width: $0.width, height: 4) }
        try require(try hasRedPixels(in: underlines, document: document), "paint the underline in the native editor")
        let end = (zigText as NSString).range(of: "\r\n").location
        guard let row = editor.laidOutLineBounds(at: end) else { throw Failure(detail: "find the diagnosed row") }
        let gap = ("0000" as NSString).size(withAttributes: [.font: editor.font ?? EditorTextView.defaultFont]).width
        let messageArea = NSRect(x: row.maxX + gap, y: row.minY, width: 100, height: row.height)
        try require(try hasRedPixels(in: [messageArea], document: document), "paint the message glyphs red")
        let band = NSRect(x: row.maxX + 2, y: row.minY + 2, width: gap + 80, height: 1)
        try require(try !hasPixels(in: [band], document: document, matching: { !isLineTint($0) }),
                    "carry the same faint tint from the code through the inline message")
        try require(editor.string == zigText, "keep diagnostic text outside the source buffer")

        guard let first = editor.diagnostics.first(where: { $0.range.location == zigError.location }) else {
            throw Failure(detail: "find the primary error for the multiple-error fixture")
        }
        guard let move = NSEvent.mouseEvent(
            with: .mouseMoved, location: editor.convert(NSPoint(x: row.minX + 2, y: row.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: document.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) else { throw Failure(detail: "create a pointer event over the start of the line") }
        editor.mouseMoved(with: move)
        try await wait("show the full error when hovering away from the underline on its row") {
            guard let view = editor.languageHoverWindowForCheck?.contentView else { return false }
            return hoverContains(first.message, in: view)
        }
        if let view = editor.languageHoverWindowForCheck?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let color = bitmap.colorAt(x: 12, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            try require(color.map(isRed) == true, "tint the diagnostic card red")
        } else {
            throw Failure(detail: "capture the diagnostic card")
        }
        try checkHorizontalScroll(in: document, lineEnd: end)

        editor.insertText("1", replacementRange: zigError)
        try require(editor.diagnosticRanges.isEmpty, "clear the old revision immediately after the edit")
        try require(editor.languageHoverWindowForCheck == nil, "dismiss the obsolete diagnostic card")
        try require(try !hasRedPixels(in: underlines + [messageArea], document: document),
                    "remove the underline and inline message from the native editor")
        editor.undoManager?.undo()
        try require(editor.string == zigText, "restore the errored source with Undo")
        try await wait("repaint the ZLS error after Undo") { !editor.diagnosticRanges.isEmpty }
        let features = document.languageFeatures
        features.perform(.stop)
        try require(editor.diagnosticRanges.isEmpty, "clear diagnostics as soon as the server is stopped")
        try await wait("stop ZLS") { features.session.state == .stopped }
        // No server publications can replace the synthetic second error while hover is pending.
        editor.languageInteractionEnabled = true
        editor.setDiagnostics([first])
        let singleWidth = editor.diagnosticMinimumWidth
        let detail = "Another error on this line. Its full explanation is only visible in the diagnostic card."
        editor.setDiagnostics([first, LSPError(range: first.range, lineEnd: end, message: detail)])
        let extraWidth = editor.diagnosticMinimumWidth - singleWidth
        try require(extraWidth > 0 && extraWidth < 30, "reserve room for the count and keep only the first message inline")
        try capture(document.window)
        editor.mouseMoved(with: move)
        try await wait("show both full errors when hovering their row") {
            guard let view = editor.languageHoverWindowForCheck?.contentView else { return false }
            return hoverContains(first.message, in: view) && hoverContains(detail, in: view)
        }
        editor.setDiagnostics([])
        editor.languageInteractionEnabled = false
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
        let error = #"{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"severity":1,"message":"First error"}"#
        let second = error.replacingOccurrences(of: "First error", with: "Second error")
        let warning = #"{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"severity":2}"#
        let invalid = #"{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}}}"#
        func decode(_ uri: URL, _ version: Int?, _ items: [String]) throws -> [LSPError]? {
            let versionField = version.map { "\"version\":\($0)," } ?? ""
            let json = "{\"uri\":\"\(uri.absoluteString)\",\(versionField)\"diagnostics\":[\(items.joined(separator: ","))]}"
            return try JSONDecoder().decode(LSPPublishedDiagnostics.self, from: Data(json.utf8))
                .errors(for: document, index: index)
        }
        let errors = try decode(url, 7, [warning, error, error, second, invalid])
        try require(errors?.map(\.message) == ["First error", "Second error"]
                    && errors?.allSatisfy { $0.range == NSRange(location: 3, length: 3) && $0.lineEnd == 6 } == true,
                    "filter invalid reports, deduplicate repeated messages and keep distinct errors at the same location")
        try require(try decode(url, 6, [error]) == nil && decode(url.appendingPathExtension("old"), 7, [error]) == nil,
                    "ignore both stale versions and other documents")
        try require(try decode(url, nil, [error])?.count == 1 && decode(url, 7, []) == [],
                    "accept unversioned reports and an empty replacement")
    }

    private static func hoverContains(_ message: String, in view: NSView) -> Bool {
        if let text = view as? NSTextView, text.isSelectable && text.string.contains(message) { return true }
        return view.subviews.contains { hoverContains(message, in: $0) }
    }

    private static func checkHorizontalScroll(in document: DocumentWindow, lineEnd: Int) throws {
        let editor = document.editor
        let scroll = document.scrollView
        let original = editor.diagnostics
        let origin = scroll.visibleContentOrigin
        let viewportWidth = editor.visibleRect.width
        let wasWrapped = editor.wrapsWords
        guard let first = original.first else { throw Failure(detail: "use a live range for the long diagnostic") }
        let long = LSPError(range: first.range, lineEnd: lineEnd,
                            message: String(repeating: "An error with a long explanation. ", count: 8) + "END")
        defer {
            editor.setDiagnostics(original)
            editor.setWordWrap(wasWrapped)
            scroll.scrollToVisibleContentOrigin(origin)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        editor.setWordWrap(false)
        editor.setDiagnostics([long])
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try require(scroll.contentView.documentRect.width > viewportWidth + 400,
                    "include the full message in the unwrapped document width")

        guard let row = editor.laidOutLineBounds(at: lineEnd) else { throw Failure(detail: "lay out the long diagnostic") }
        let oldEdge = editor.visibleRect.maxX - 4
        let acrossEdge = NSRect(x: oldEdge - 10, y: row.minY + 2, width: 20, height: 1)
        for distance: CGFloat in [32, 120, 48] {
            scroll.scrollToVisibleContentOrigin(NSPoint(x: origin.x + distance, y: origin.y))
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            try require(try !hasPixels(in: [acrossEdge], document: document, matching: { !isLineTint($0) }),
                        "paint continuously across an earlier viewport edge after scrolling")
        }

        let documentEnd = scroll.contentView.documentRect.maxX
        scroll.scrollToVisibleContentOrigin(NSPoint(x: documentEnd, y: origin.y))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let tail = NSRect(x: documentEnd - 48, y: row.midY - 4, width: 36, height: 8)
        try require(try hasRedPixels(in: [tail], document: document),
                    "scroll far enough to draw the last glyphs of the message")

        editor.setWordWrap(true)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let wrappedWidth = scroll.contentView.bounds.width - scroll.contentInsets.left - scroll.contentInsets.right
        try require(!scroll.hasHorizontalScroller && abs(editor.frame.width - wrappedWidth) < 1,
                    "keep word wrap within the viewport (editor \(editor.frame.width), expected \(wrappedWidth), scroller \(scroll.hasHorizontalScroller))")
        try require(editor.laidOutLineBounds(at: lineEnd)?.height == row.height
                    && editor.diagnosticHover(at: NSPoint(x: 16, y: row.midY))?.text.hasSuffix("END") == true,
                    "keep the message on one row and reveal its full text on hover in word wrap")

        editor.setWordWrap(false)
        try require(editor.frame.width > viewportWidth + 400, "restore the message's full width after disabling Word Wrap")
        editor.setDiagnostics([])
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try require(editor.frame.width <= viewportWidth + 1, "release the extra scroll extent when the report clears")
    }

    private static func hasRedPixels(in rects: [NSRect], document: DocumentWindow) throws -> Bool {
        try hasPixels(in: rects, document: document, matching: isRed)
    }

    private static func isRed(_ pixel: NSColor) -> Bool {
        pixel.redComponent > pixel.greenComponent + 0.15 && pixel.redComponent > pixel.blueComponent + 0.15
    }

    private static func isLineTint(_ pixel: NSColor) -> Bool {
        let tint = pixel.redComponent - max(pixel.greenComponent, pixel.blueComponent)
        return (0.04...0.13).contains(tint)
    }

    private static func hasPixels(in rects: [NSRect], document: DocumentWindow, matching: (NSColor) -> Bool) throws -> Bool {
        let clip = document.scrollView.contentView
        let bounds = clip.bounds
        guard let bitmap = clip.bitmapImageRepForCachingDisplay(in: bounds) else { throw Failure(detail: "capture editor pixels") }
        clip.cacheDisplay(in: bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / bounds.width
        for rect in rects {
            let frame = clip.convert(rect, from: document.editor)
            let x = Int(((frame.minX - bounds.minX) * scale).rounded(.down))..<Int(((frame.maxX - bounds.minX) * scale).rounded(.up))
            let y = Int(((frame.minY - bounds.minY) * scale).rounded(.down))..<Int(((frame.maxY - bounds.minY) * scale).rounded(.up))
            for row in y where (0..<bitmap.pixelsHigh).contains(row) {
                for column in x where (0..<bitmap.pixelsWide).contains(column) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    if matching(pixel) { return true }
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
