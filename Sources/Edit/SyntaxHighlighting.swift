import AppKit

@MainActor
final class SyntaxHighlighting {
    private weak var editor: EditorTextView?
    private var spans: [SyntaxSpan] = []
    private var hasRenderingColors = false
    private var backedColorRange: NSRange?
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activity: NSTitlebarAccessoryViewController?
    private var generation = 0

    init(editor: EditorTextView) {
        self.editor = editor
        editor.syntaxHighlighting = self
    }

    func update(language: SyntaxLanguage, immediate: Bool, keepingColors: Bool = false) {
        cancelPending()
        if let editor { editor.syntaxAnalysis.cancelIfChanged(to: editor.string, language: language) }
        let request = generation
        if !keepingColors {
            if immediate {
                display([])
            } else {
                spans = []
            }
        }
        guard language != .plainText else { return }

        task = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(45))
            }
            guard !Task.isCancelled, let editor = self?.editor else { return }
            let source = editor.string
            let visibleRange = self?.visibleRange()
            let job = editor.syntaxAnalysis.request(in: source, language: language,
                                                    visibleRange: visibleRange, publishesPreview: !keepingColors)
            for await preview in job.previews {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.display(preview)
                self.stopProgress()
            }
            guard !Task.isCancelled else { return }
            let result = await job.task.value
            guard !Task.isCancelled, let self, self.generation == request else { return }
            if let result {
                self.display(result.spans)
            } else if !keepingColors {
                self.display([])
            }
            self.stopProgress()
        }

        if immediate && !keepingColors {
            progressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.showProgress()
            }
        }
    }

    func prepareForBufferReplacement() {
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        spans = []
        clearColors()
        updateBackingColors(in: nil)
    }

    func install(_ snapshot: SyntaxSnapshot) {
        cancelPending()
        display(snapshot.analysis.spans)
        if snapshot.coversDocument, let editor {
            editor.syntaxAnalysis.install(snapshot.analysis, in: editor.string, language: snapshot.language)
        } else {
            update(language: snapshot.language, immediate: true, keepingColors: true)
        }
    }

    func cancel(clearingColors: Bool = true) {
        cancelPending()
        editor?.syntaxAnalysis.cancel()
        if clearingColors { display([]) }
    }

    private func cancelPending() {
        generation &+= 1
        task?.cancel()
        task = nil
        stopProgress()
    }

    private func display(_ result: [SyntaxSpan]) {
        let needsRedraw = hasRenderingColors || backedColorRange != nil || !result.isEmpty
        spans = result
        if needsRedraw { refreshColors() }
    }

    func refreshColors() {
        clearColors()
        guard let editor, let manager = editor.textLayoutManager else { return }
        let viewport = manager.textViewportLayoutController
        let scroll = editor.enclosingScrollView
        let origin = scroll?.visibleContentOrigin

        // Rendering attributes color newly drawn fragments. A native attribute edit also tells
        // TextKit to redraw glyphs that are already on screen, even if the viewport is stationary.
        if viewport.viewportRange == nil { viewport.layoutViewport() }
        let prefix = NSRange(location: 0, length: min(editor.textStorage?.length ?? 0, 4_096))
        updateBackingColors(in: visibleRange() ?? prefix)
        viewport.layoutViewport()
        if let scroll, let origin, scroll.scrollToVisibleContentOrigin(origin) {
            viewport.layoutViewport()
        }
        editor.setNeedsDisplay(editor.visibleRect)
    }

    func storageDidEdit(_ storage: NSTextStorage) {
        guard let backed = backedColorRange else { return }
        let edit = storage.editedRange
        let delta = storage.changeInLength
        let replacedLength = edit.length - delta
        guard edit.location != NSNotFound, edit.location <= storage.length,
              edit.length <= storage.length - edit.location, replacedLength >= 0 else {
            backedColorRange = NSRange(location: 0, length: storage.length)
            return
        }
        let beforeEnd = edit.location + replacedLength
        if beforeEnd < backed.location {
            backedColorRange = NSRange(location: backed.location + delta, length: backed.length)
        } else if edit.location <= backed.upperBound {
            // Edits touching the cached colors can inherit them across the replaced range.
            let start = min(backed.location, edit.location)
            let end = max(edit.upperBound, backed.upperBound + delta)
            backedColorRange = NSRange(location: start, length: end - start)
        }
    }

    private func updateBackingColors(in visible: NSRange?) {
        guard let editor, !editor.hasMarkedText(), let storage = editor.textStorage,
              let content = editor.textLayoutManager?.textContentManager else { return }
        let document = NSRange(location: 0, length: storage.length)
        let previous = backedColorRange.map { NSIntersectionRange($0, document) }
        let visible = visible.map { NSIntersectionRange($0, document) }
        let colors = visible.map { spans(overlapping: $0) } ?? []
        let markers = visible.flatMap { editor.jjConflictDecorations?.markerRanges(in: $0) } ?? []
        guard (previous?.length ?? 0) > 0 || (visible?.length ?? 0) > 0 else {
            backedColorRange = nil
            return
        }
        var typingAttributes = editor.typingAttributes
        typingAttributes[.foregroundColor] = NSColor.textColor
        content.performEditingTransaction {
            storage.beginEditing()
            if let previous, previous.length > 0, previous != visible {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: previous)
            }
            if let visible, visible.length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: visible)
                for span in colors {
                    let range = NSIntersectionRange(visible, NSRange(location: span.start, length: span.end - span.start))
                    storage.addAttribute(.foregroundColor, value: span.color.nativeColor, range: range)
                }
                for marker in markers {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: marker)
                }
            }
            storage.endEditing()
        }
        editor.typingAttributes = typingAttributes
        backedColorRange = colors.isEmpty && markers.isEmpty ? nil : visible
    }

    private func visibleRange() -> NSRange? {
        guard let editor, let manager = editor.textLayoutManager,
              let visible = manager.textViewportLayoutController.viewportRange else { return nil }
        return editor.charRange(visible, in: manager)
    }

    func prepareForDrawing(_ fragment: NSTextLayoutFragment, using manager: NSTextLayoutManager) {
        paint(fragment.rangeInElement, using: manager)
    }

    private func clearColors() {
        guard hasRenderingColors else { return }
        hasRenderingColors = false
        if let manager = editor?.textLayoutManager {
            manager.removeRenderingAttribute(.foregroundColor, for: manager.documentRange)
        }
    }

    private func paint(_ range: NSTextRange, using manager: NSTextLayoutManager) {
        guard !spans.isEmpty || editor?.jjConflictDecorations?.hasHighlights == true else { return }
        let origin = manager.documentRange.location
        let start = manager.offset(from: origin, to: range.location)
        let end = start + manager.offset(from: range.location, to: range.endLocation)
        guard start < end else { return }

        let visible = NSRange(location: start, length: end - start)
        func paintColor(_ color: NSColor, in span: NSRange) {
            guard let from = manager.location(range.location, offsetBy: span.location - start),
                  let to = manager.location(from, offsetBy: span.length),
                  let target = NSTextRange(location: from, end: to) else { return }
            manager.addRenderingAttribute(.foregroundColor, value: color, for: target)
            hasRenderingColors = true
        }
        for span in spans(overlapping: visible) {
            paintColor(span.color.nativeColor, in: NSIntersectionRange(visible, NSRange(location: span.start, length: span.end - span.start)))
        }
        for marker in editor?.jjConflictDecorations?.markerRanges(in: visible) ?? [] {
            paintColor(.systemPurple, in: marker)
        }
    }

    private func spans(overlapping range: NSRange) -> ArraySlice<SyntaxSpan> {
        guard range.length > 0 else { return [] }
        var low = 0
        var high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].end <= range.location { low = middle + 1 }
            else { high = middle }
        }
        var end = low
        while end < spans.count && spans[end].start < NSMaxRange(range) { end += 1 }
        return spans[low..<end]
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

extension SyntaxColor {
    private static let colors = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeNativeColor()) })

    var nativeColor: NSColor { Self.colors[self] ?? .textColor }

    private func makeNativeColor() -> NSColor {
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
