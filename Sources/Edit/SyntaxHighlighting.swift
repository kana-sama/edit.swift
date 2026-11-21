import AppKit

@MainActor
final class SyntaxHighlighting {
    private weak var editor: EditorTextView?
    private var spans: [SyntaxSpan] = []
    private var hasRenderingColors = false
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activity: NSTitlebarAccessoryViewController?
    private var generation = 0

    init(editor: EditorTextView) {
        self.editor = editor
        editor.syntaxHighlighting = self
    }

    func update(language: SyntaxLanguage, immediate: Bool) {
        cancelPending()
        let request = generation
        if immediate {
            display([], refreshVisibleLayout: true)
        } else {
            spans = []
        }
        guard language != .plainText else { return }

        task = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(45))
            }
            guard !Task.isCancelled, let editor = self?.editor else { return }
            let source = editor.string
            let visibleRange = self?.visibleRange()
            let (updates, continuation) = AsyncStream<[SyntaxSpan]>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let worker = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                let result = SyntaxEngine.spans(in: source, language: language, visibleRange: visibleRange) { preview in
                    continuation.yield(preview)
                }
                if !Task.isCancelled { continuation.yield(result ?? []) }
            }
            await withTaskCancellationHandler {
                for await result in updates {
                    guard !Task.isCancelled, let self, self.generation == request else { break }
                    self.display(result, refreshVisibleLayout: immediate)
                    self.stopProgress()
                }
            } onCancel: {
                worker.cancel()
            }
        }

        if immediate {
            progressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.showProgress()
            }
        }
    }

    func install(_ result: [SyntaxSpan]) {
        cancelPending()
        display(result)
    }

    func cancel(clearingColors: Bool = true) {
        cancelPending()
        if clearingColors { display([], refreshVisibleLayout: true) }
    }

    private func cancelPending() {
        generation &+= 1
        task?.cancel()
        task = nil
        stopProgress()
    }

    private func display(_ result: [SyntaxSpan], refreshVisibleLayout: Bool = false) {
        let needsRedraw = hasRenderingColors || !result.isEmpty
        clearColors()
        spans = result
        if needsRedraw { redrawSyntax(refreshVisibleLayout: refreshVisibleLayout) }
    }

    private func visibleRange() -> NSRange? {
        guard let editor, let manager = editor.textLayoutManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return nil }
        return editor.charRange(visible, in: manager)
    }

    func prepareForDrawing(_ fragment: NSTextLayoutFragment, using manager: NSTextLayoutManager) {
        paint(fragment.rangeInElement, using: manager)
    }

    private func redrawSyntax(refreshVisibleLayout: Bool) {
        guard let editor, let manager = editor.textLayoutManager else { return }
        let viewport = manager.textViewportLayoutController
        let scroll = editor.enclosingScrollView
        let origin = refreshVisibleLayout ? scroll?.visibleContentOrigin : nil
        if let visible = viewport.viewportRange {
            // A new mode must update existing rendering surfaces even if the viewport hasn't moved.
            if refreshVisibleLayout { manager.invalidateLayout(for: visible) }
            paint(visible, using: manager)
        }
        viewport.layoutViewport()
        if let origin, let scroll, scroll.scrollToVisibleContentOrigin(origin) {
            viewport.layoutViewport()
        }
        editor.setNeedsDisplay(editor.visibleRect)
    }

    private func clearColors() {
        guard hasRenderingColors else { return }
        hasRenderingColors = false
        if let manager = editor?.textLayoutManager {
            manager.removeRenderingAttribute(.foregroundColor, for: manager.documentRange)
        }
    }

    private func paint(_ range: NSTextRange, using manager: NSTextLayoutManager) {
        guard !spans.isEmpty else { return }
        let origin = manager.documentRange.location
        let start = manager.offset(from: origin, to: range.location)
        let end = start + manager.offset(from: range.location, to: range.endLocation)
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
            guard let from = manager.location(range.location, offsetBy: max(0, span.start - start)),
                  let to = manager.location(from, offsetBy: min(end, span.end) - max(start, span.start)),
                  let target = NSTextRange(location: from, end: to) else { continue }
            manager.addRenderingAttribute(.foregroundColor, value: span.color.nativeColor, for: target)
            hasRenderingColors = true
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
