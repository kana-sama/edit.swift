import AppKit
import WebKit

@MainActor
final class MarkdownPreviewView: NSView, WKNavigationDelegate, NSSearchFieldDelegate {
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var view: MarkdownPreviewView?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            view?.receive(message)
        }
    }

    private let webView: WKWebView
    private let searchField = NSSearchField()
    private let bridge = Bridge()
    private var isReady = false
    private var pending: (() -> Void)?
    private var revision = 0
    private var hasMath = false
    private var hasDiagrams = false
    private var presentationFailed = false
    private(set) var hasCurrentDocument = false
    private(set) var presentedReading: MarkdownViewState.Reading?
    private(set) var presentedFragment: (target: String, found: Bool)?

    var onState: ((MarkdownViewState.Reading) -> Void)?
    var onLink: ((String) -> Void)?
    var onTask: ((Int, Bool) -> Void)?
    var onImage: ((Int, Bool) -> Void)?
    var onFragment: ((String, Bool) -> Void)?

    var responder: NSView { webView }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: "markdown")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        bridge.view = self
        webView.navigationDelegate = self
        webView.setAccessibilityLabel("Markdown preview")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find in Preview"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.isHidden = true
        addSubview(searchField)

        NSLayoutConstraint.activate([
            // WebKit insets the page for the native titlebar while painting through the scroll edge.
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            searchField.widthAnchor.constraint(equalToConstant: 220),
        ])
        let css = SyntaxColor.allCases.map { token in
            let (dark, light) = token.appearanceRGB
            return ".syntax-\(token) { color: light-dark(\(String(format: "#%06x", light)), \(String(format: "#%06x", dark))); }"
        }.joined(separator: "\n")
        let html = (try? MarkdownAssets.text("preview.html").replacingOccurrences(of: "/* Code colors */", with: css))
            ?? "<p>Markdown Preview is unavailable.</p>"
        webView.loadHTMLString(html, baseURL: nil)
    }

    required init?(coder: NSCoder) { nil }

    func containsResponder(_ responder: NSResponder?) -> Bool {
        if responder === searchField.currentEditor() && responder != nil { return true }
        guard let view = responder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    func dismissFind() -> Bool {
        guard !searchField.isHidden else { return false }
        searchField.isHidden = true
        window?.makeFirstResponder(webView)
        return true
    }

    var isFinding: Bool { !searchField.isHidden && searchField.currentEditor() != nil }

    func showFind() {
        searchField.isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func find(backward: Bool = false) {
        guard !searchField.stringValue.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backward
        configuration.wraps = true
        webView.find(searchField.stringValue, configuration: configuration) { _ in }
    }

    func controlTextDidChange(_ notification: Notification) { find() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): return dismissFind()
        case #selector(NSResponder.insertNewline(_:)): find(); return true
        default: return false
        }
    }

    func show(html: String, highlighted: [String], reading: MarkdownViewState.Reading, writable: Bool,
              fragment: String?, staged: Bool = false) {
        revision += 1
        hasCurrentDocument = false
        presentedReading = nil
        presentedFragment = nil
        let token = revision
        let arguments: [String: Any] = ["html": html, "highlighted": highlighted, "state": reading.arguments,
                                        "writable": writable, "token": token, "fragment": fragment ?? "", "staged": staged]
        let show = { [weak self] in
            guard let self else { return }
            Task {
                if html.contains("data-math"), !hasMath {
                    hasMath = await install("math.js")
                    if hasMath, let css = try? MarkdownAssets.text("math.css") {
                        _ = try? await webView.callAsyncJavaScript(
                            "const style = document.createElement('style'); style.textContent = css; document.head.append(style);",
                            arguments: ["css": css], in: nil, contentWorld: .page
                        )
                    }
                }
                guard revision == token else { return }
                if html.contains("data-mermaid"), !hasDiagrams { hasDiagrams = await install("diagrams.js") }
                guard revision == token else { return }
                let shown = try? await webView.callAsyncJavaScript("return await EditPreview.show(payload)", arguments: ["payload": arguments],
                                                                  in: nil, contentWorld: .page)
                guard revision == token else { return }
                if let result = shown as? [String: Any], let reading = decodeReading(result["state"]) {
                    presentedReading = reading
                    hasCurrentDocument = true
                    if let fragment, let found = result["fragmentFound"] as? Bool { presentedFragment = (fragment, found) }
                } else {
                    presentationFailed = true
                }
            }
        }
        if isReady { show() } else { pending = show }
    }

    func waitForPreparedFrame(while isCurrent: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !hasCurrentDocument {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            guard !presentationFailed, ContinuousClock.now < deadline else { throw CocoaError(.fileReadCorruptFile) }
            try await Task.sleep(for: .milliseconds(16))
        }
        // A DOM update can complete before WebKit has drawn the new document.
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        _ = try await webView.takeSnapshot(configuration: configuration)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
    }

    func activatePreparedFrame() {
        webView.evaluateJavaScript("EditPreview.activate()", completionHandler: nil)
    }

    private func install(_ asset: String) async -> Bool {
        guard let source = try? MarkdownAssets.text(asset) else { return false }
        do { _ = try await webView.evaluateJavaScript(source); return true }
        catch { return false }
    }

    func jump(to fragment: String) async -> Bool {
        let result = try? await webView.callAsyncJavaScript("return EditPreview.jump(fragment)",
            arguments: ["fragment": fragment], in: nil, contentWorld: .page)
        guard let reading = decodeReading(result) else { return false }
        onState?(reading)
        return true
    }

    func restore(_ reading: MarkdownViewState.Reading) {
        webView.callAsyncJavaScript("EditPreview.restore(state)", arguments: ["state": reading.arguments],
                                    in: nil, in: .page, completionHandler: nil)
    }

    func showImage(_ index: Int, url: String?, remote: Bool) {
        webView.callAsyncJavaScript("EditPreview.image(index, url, remote)",
            arguments: ["index": index, "url": url ?? "", "remote": remote], in: nil, in: .page, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        pending?()
        pending = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        presentationFailed = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        presentationFailed = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" && !isReady ? .allow : .cancel
    }

    private func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let values = message.body as? [String: Any],
              values["revision"] as? Int == revision, let kind = values["kind"] as? String else { return }
        switch kind {
        case "state":
            if let reading = decodeReading(values["state"]) { onState?(reading) }
        case "link":
            if let target = values["target"] as? String { onLink?(target) }
        case "task":
            if let offset = values["offset"] as? Int, let checked = values["checked"] as? Bool { onTask?(offset, checked) }
        case "image":
            if let index = values["index"] as? Int { onImage?(index, values["activate"] as? Bool ?? false) }
        case "fragment":
            if let target = values["target"] as? String, let found = values["found"] as? Bool { onFragment?(target, found) }
        default: break
        }
    }

    private func decodeReading(_ value: Any?) -> MarkdownViewState.Reading? {
        guard let value = value as? [String: Any], let bytes = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(MarkdownViewState.Reading.self, from: bytes)
    }

    #if EDIT_AGENT_CHECKS
    var topContentInsetForCheck: CGFloat { webView.obscuredContentInsets.top }

    func evaluateForCheck(_ script: String) async throws -> Any? { try await webView.evaluateJavaScript(script) }

    func captureForCheck(to destination: String) async throws {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: URL(fileURLWithPath: destination))
    }
    #endif
}
