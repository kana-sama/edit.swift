import AppKit

@MainActor
final class SyntaxHighlighting {
    private weak var editor: EditorTextView?
    private var spans: [SyntaxSpan] = []
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activity: NSTitlebarAccessoryViewController?
    private var generation = 0

    init(editor: EditorTextView) {
        self.editor = editor
        editor.textLayoutManager?.renderingAttributesValidator = { [weak self] manager, fragment in
            MainActor.assumeIsolated {
                self?.paint(fragment.rangeInElement, using: manager)
            }
        }
    }

    func update(language: SyntaxLanguage, immediate: Bool) {
        generation &+= 1
        let request = generation
        task?.cancel()
        task = nil
        stopProgress()
        clearColors()
        guard language != .plainText else { return }

        task = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(70))
            }
            guard !Task.isCancelled, let source = self?.editor?.string else { return }
            let worker = Task.detached(priority: .userInitiated) { SyntaxEngine.spans(in: source, language: language) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.spans = result ?? []
            if let manager = self.editor?.textLayoutManager,
               let visible = manager.textViewportLayoutController.viewportRange {
                self.paint(visible, using: manager)
            }
            self.stopProgress()
        }

        if immediate {
            progressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.showProgress()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopProgress()
        clearColors()
    }

    private func clearColors() {
        guard !spans.isEmpty else { return }
        spans = []
        if let manager = editor?.textLayoutManager {
            manager.removeRenderingAttribute(.foregroundColor, for: manager.documentRange)
        }
    }

    private func paint(_ range: NSTextRange, using manager: NSTextLayoutManager) {
        guard !spans.isEmpty else { return }
        let origin = manager.documentRange.location
        let start = manager.offset(from: origin, to: range.location)
        let end = manager.offset(from: origin, to: range.endLocation)
        guard start < end else { return }

        var low = 0
        var high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].end <= start {
                low = middle + 1
            } else {
                high = middle
            }
        }
        for index in low..<spans.count {
            let span = spans[index]
            if span.start >= end { break }
            guard let from = manager.location(origin, offsetBy: max(start, span.start)),
                  let to = manager.location(origin, offsetBy: min(end, span.end)),
                  let target = NSTextRange(location: from, end: to) else { continue }
            manager.addRenderingAttribute(.foregroundColor, value: span.color.nativeColor, for: target)
        }
    }

    private func showProgress() {
        guard let window = editor?.window, window.isVisible, activity == nil else { return }
        let controller = NSTitlebarAccessoryViewController()
        let indicator = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        let bounds = NSRect(x: 4, y: 4, width: 16, height: 16)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let icon = NSImageView(frame: bounds)
            icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            indicator.addSubview(icon)
        } else {
            let spinner = NSProgressIndicator(frame: bounds)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            indicator.addSubview(spinner)
        }
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityLabel("Highlighting syntax")
        controller.view = indicator
        controller.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(controller)
        activity = controller
    }

    private func stopProgress() {
        progressTask?.cancel()
        progressTask = nil
        activity?.removeFromParent()
        activity = nil
    }
}

private extension SyntaxColor {
    static let colors = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeNativeColor()) })

    var nativeColor: NSColor { Self.colors[self] ?? .textColor }

    func makeNativeColor() -> NSColor {
        let pair: (dark: UInt32, light: UInt32)
        switch self {
        case .keyword: pair = (0x569CD6, 0x0000FF)
        case .control: pair = (0xC586C0, 0xAF00DB)
        case .type: pair = (0x4EC9B0, 0x226E84)
        case .function: pair = (0xDCDCAA, 0x795E26)
        case .string: pair = (0xCE9178, 0xA31515)
        case .number: pair = (0xB5CEA8, 0x08764D)
        case .comment: pair = (0x6E9D59, 0x007800)
        case .property: pair = (0x9CDCFE, 0x001080)
        case .markup: pair = (0x569CD6, 0x800000)
        case .attribute: pair = (0x9CDCFE, 0xC00000)
        }
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = dark ? pair.dark : pair.light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255,
                alpha: 1
            )
        }
    }
}
