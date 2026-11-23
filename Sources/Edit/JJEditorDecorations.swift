import AppKit

extension JJLineMark.Kind {
    @MainActor var color: NSColor {
        switch self {
        case .insertion: .systemGreen
        case .replacement: .systemBlue
        case .deletion: .systemRed
        case .conflict: .systemPurple
        }
    }

    fileprivate var drawingPriority: Int {
        switch self {
        case .insertion: 0
        case .replacement: 1
        case .deletion: 2
        case .conflict: 3
        }
    }
}

@MainActor
final class JJEditorDecorations {
    private struct PositionedMark {
        let mark: JJLineMark
        let rect: NSRect
    }

    private weak var editor: EditorTextView?
    private weak var nativeScroller: NSScroller?
    private var scrollerStyle: NSScroller.Style?
    private var lineStarts: [Int] = []
    private(set) var marks: [JJLineMark] = []
    var allowsNavigation = true
    private var lastMarkLines: [Int] = []
    private var trackSize = NSSize.zero
    private var trackMarks: [PositionedMark] = []
    private let gutter = JJEditorMarkerView()
    private let track = JJEditorMarkerView()

    init(editor: EditorTextView) {
        self.editor = editor
        gutter.clipsToBounds = true
        track.clipsToBounds = true
        gutter.drawMarks = { [weak self] rect in self?.drawGutter(in: rect) }
        track.drawMarks = { [weak self] rect in self?.drawTrack(in: rect) }
        track.onClick = { [weak self] event in self?.clickTrack(event) }
    }

    func setMarks(_ marks: [JJLineMark], lineStarts: [Int]) {
        allowsNavigation = true
        guard marks != self.marks || lineStarts != self.lineStarts else { return }
        self.marks = marks.sorted {
            if $0.lines.lowerBound != $1.lines.lowerBound { return $0.lines.lowerBound < $1.lines.lowerBound }
            return $0.kind.drawingPriority < $1.kind.drawingPriority
        }
        self.lineStarts = lineStarts
        var lastLine = 0
        lastMarkLines = self.marks.map {
            lastLine = max(lastLine, $0.lines.upperBound)
            return lastLine
        }
        if marks.isEmpty {
            gutter.removeFromSuperview()
            track.removeFromSuperview()
            trackMarks.removeAll()
        } else if let scroll = editor?.enclosingScrollView {
            layout(in: scroll)
            updateTrackMarks()
        }
    }

    func layout(in scroll: NSScrollView) {
        guard !marks.isEmpty, let editor else { return }
        let clip = scroll.contentView.frame
        let exposedOrigin = editor.convert(scroll.visibleContentOrigin, to: scroll)
        let gutterFrame = NSRect(x: max(clip.minX, exposedOrigin.x), y: clip.minY, width: 7, height: clip.height)
        if gutter.superview !== scroll {
            scroll.addSubview(gutter, positioned: .above, relativeTo: scroll.contentView)
        }
        if gutter.frame != gutterFrame { gutter.frame = gutterFrame }
        gutter.needsDisplay = true

        let scroller = scroll.verticalScroller
        let style = scroll.scrollerStyle
        if track.superview !== scroll || scroller !== nativeScroller || style != scrollerStyle {
            track.removeFromSuperview()
            // An overlay scroller is transparent when it fades. A legacy track has an
            // opaque background, so draw above it and clip the marks around the knob.
            if let scroller, scroller.superview === scroll {
                scroll.addSubview(track, positioned: style == .overlay ? .below : .above, relativeTo: scroller)
            } else {
                scroll.addSubview(track, positioned: .above, relativeTo: scroll.contentView)
            }
            nativeScroller = scroller
            scrollerStyle = style
        }
        let frame = trackFrame(in: scroll, scroller: scroller)
        if track.frame != frame { track.frame = frame }
        if frame.size != trackSize { updateTrackMarks() }
        if style != .overlay { track.needsDisplay = true }
    }

    func hitTest(in scroll: NSScrollView, at point: NSPoint, nativeHit: NSView) -> NSView? {
        guard allowsNavigation, track.superview === scroll, hasVerticalScrollRange(in: scroll),
              trackMark(at: track.convert(point, from: scroll)) != nil else { return nil }
        if let scroller = nativeScroller,
           nativeHit === scroller || nativeHit.isDescendant(of: scroller),
           scroller.testPart(scroll.convert(point, to: nil)) == .knob { return nil }
        return track
    }

    private func trackFrame(in scroll: NSScrollView, scroller: NSScroller?) -> NSRect {
        let clip = scroll.contentView.frame
        let width = NSScroller.scrollerWidth(for: scroller?.controlSize ?? .regular, scrollerStyle: scroll.scrollerStyle)
        // The scroll view extends under the docked sidebars. The scroller follows the exposed pane.
        let edge = NSRect(x: scroll.safeAreaRect.maxX - width, y: clip.minY, width: width, height: clip.height)

        guard let scroller, scroller.superview === scroll, hasVerticalScrollRange(in: scroll) else { return edge }
        let slot = scroll.convert(scroller.rect(for: .knobSlot), from: scroller).intersection(scroll.bounds)
        // AppKit can retain the scroller's old frame while the editor pane is resizing.
        guard !slot.isEmpty, slot.minX >= edge.minX else { return edge }
        return slot
    }

    private func hasVerticalScrollRange(in scroll: NSScrollView) -> Bool {
        scroll.contentView.bounds.height < (scroll.documentView?.frame.height ?? 0)
    }

    private func updateTrackMarks() {
        trackSize = track.bounds.size
        let height = trackSize.height
        let width = min(6, trackSize.width)
        let minimumHeight = min(3, height)
        let lineCount = CGFloat(max(1, lineStarts.count))
        trackMarks = marks.map { mark in
            // Edit lays out source text without wrapping, on one uniform-height row per line.
            let top = height * CGFloat(mark.lines.lowerBound) / lineCount
            let bottom = height * CGFloat(mark.lines.upperBound) / lineCount
            let markHeight = min(height, max(minimumHeight, bottom - top))
            let centered = (top + bottom - markHeight) / 2
            let rect = NSRect(x: (trackSize.width - width) / 2, y: max(0, min(height - markHeight, centered)),
                              width: width, height: markHeight)
            return PositionedMark(mark: mark, rect: rect)
        }.sorted { $0.mark.kind.drawingPriority < $1.mark.kind.drawingPriority }
        track.needsDisplay = true
    }

    private func trackMark(at point: NSPoint) -> JJLineMark? {
        guard track.bounds.contains(point) else { return nil }
        // Choose visible paint before hit slop so the visible priority always wins collisions.
        return trackMarks.reversed().first { $0.rect.contains(point) }?.mark
            ?? trackMarks.reversed().first { $0.rect.insetBy(dx: -2, dy: -1).contains(point) }?.mark
    }

    private func clickTrack(_ event: NSEvent) {
        if !event.modifierFlags.intersection([.option, .control]).isEmpty {
            nativeScroller?.mouseDown(with: event)
            return
        }
        guard allowsNavigation, let editor, let scroll = editor.enclosingScrollView,
              let mark = trackMark(at: track.convert(event.locationInWindow, from: nil)) else { return }
        let line = mark.lines.lowerBound
        let lineHeight = editor.defaultParagraphStyle?.minimumLineHeight ?? 18
        let visibleHeight = max(0, scroll.documentVisibleRect.height - scroll.contentInsets.top - scroll.contentInsets.bottom)
        let horizontal = scroll.visibleContentOrigin.x
        func center(_ y: CGFloat) {
            let currentTop = scroll.documentVisibleRect.minY + scroll.contentInsets.top
            let next = NSPoint(x: horizontal, y: scroll.visibleContentOrigin.y + y - visibleHeight / 2 - currentTop)
            if scroll.scrollToVisibleContentOrigin(next) {
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            }
        }
        let estimate = editor.textContainerOrigin.y + CGFloat(line) * lineHeight
        let first = boundary(line, editor: editor) ?? estimate
        center(first)
        // TextKit lays out the destination after scrolling and may refine its original estimate.
        if let settled = boundary(line, editor: editor) {
            if abs(settled - first) > 0.5 { center(settled) }
        } else {
            let offset = lineStarts.indices.contains(line) ? lineStarts[line] : (editor.textStorage?.length ?? 0)
            editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            if let settled = boundary(line, editor: editor) {
                center(settled)
            } else {
                var origin = scroll.visibleContentOrigin
                origin.x = horizontal
                scroll.scrollToVisibleContentOrigin(origin)
            }
        }
    }

    private func drawTrack(in dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if scrollerStyle == .legacy, let scroller = nativeScroller, !scroller.isHidden, scroller.isEnabled {
            let knob = track.convert(scroller.rect(for: .knob), from: scroller).intersection(track.bounds)
            if !knob.isEmpty {
                let paint = NSBezierPath(rect: track.bounds)
                paint.appendRect(knob)
                paint.windingRule = .evenOdd
                paint.addClip()
            }
        }
        for marker in trackMarks where marker.rect.intersects(dirtyRect) {
            fill(marker.rect, kind: marker.mark.kind)
        }
    }

    private func drawGutter(in dirtyRect: NSRect) {
        guard let editor, let layout = editor.textLayoutManager else { return }
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let viewport = layout.textViewportLayoutController.viewportRange.map { editor.charRange($0, in: layout) }
        guard viewport != nil || lineStarts.isEmpty else { return }
        let firstLine = max(0, lineIndex(at: viewport?.lowerBound ?? 0) - 1)
        let lastLine = min(lineStarts.count, lineIndex(at: viewport?.upperBound ?? 0) + 1)
        var index = firstMarkEnding(atOrAfter: firstLine)
        while index < marks.count && marks[index].lines.lowerBound <= lastLine {
            drawGutterMark(marks[index], firstLine: firstLine, lastLine: lastLine, editor: editor, dirtyRect: dirtyRect)
            index += 1
        }
    }

    private func lineIndex(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 }
            else { high = middle }
        }
        return max(0, low - 1)
    }

    private func firstMarkEnding(atOrAfter line: Int) -> Int {
        var low = 0
        var high = lastMarkLines.count
        while low < high {
            let middle = (low + high) / 2
            if lastMarkLines[middle] < line { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    private func drawGutterMark(
        _ mark: JJLineMark, firstLine: Int, lastLine: Int, editor: EditorTextView, dirtyRect: NSRect
    ) {
        if mark.kind == .deletion {
            guard mark.lines.lowerBound >= firstLine, let y = boundary(mark.lines.lowerBound, editor: editor) else { return }
            let axis = gutter.convert(NSPoint(x: 0, y: y), from: editor).y
            guard axis >= dirtyRect.minY - 4, axis <= dirtyRect.maxY + 4 else { return }
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 1, y: axis - 3))
            path.line(to: NSPoint(x: 1, y: axis + 3))
            path.line(to: NSPoint(x: 6, y: axis))
            path.close()
            mark.kind.color.setFill()
            path.fill()
            return
        }
        let start = max(mark.lines.lowerBound, firstLine)
        let end = min(mark.lines.upperBound, lastLine)
        guard start < end else { return }
        for line in start..<end {
            guard let row = laidOutLine(at: line, editor: editor) else { continue }
            let rect = gutter.convert(row, from: editor)
            let stripe = NSRect(x: 2, y: rect.minY, width: 3, height: rect.height)
            guard stripe.intersects(dirtyRect) else { continue }
            fill(stripe, kind: mark.kind)
        }
    }

    private func laidOutLine(at line: Int, editor: EditorTextView) -> NSRect? {
        guard lineStarts.indices.contains(line), let layout = editor.textLayoutManager,
              let location = layout.location(layout.documentRange.location, offsetBy: lineStarts[line]),
              let fragment = layout.textLayoutFragment(for: location), fragment.state == .layoutAvailable else { return nil }
        let row = fragment.textLineFragment(for: location, isUpstreamAffinity: false)?.typographicBounds
        let frame = fragment.layoutFragmentFrame
        let lineHeight = editor.defaultParagraphStyle?.minimumLineHeight ?? 18
        return NSRect(x: editor.textContainerOrigin.x, y: editor.textContainerOrigin.y + frame.minY + (row?.minY ?? 0),
                      width: 1, height: row?.height ?? lineHeight)
    }

    private func boundary(_ line: Int, editor: EditorTextView) -> CGFloat? {
        if lineStarts.isEmpty { return line == 0 ? editor.textContainerOrigin.y : nil }
        if let next = laidOutLine(at: line, editor: editor) { return next.minY }
        return line > 0 ? laidOutLine(at: line - 1, editor: editor)?.maxY : nil
    }

    private func fill(_ rect: NSRect, kind: JJLineMark.Kind) {
        kind.color.setFill()
        if kind != .conflict || rect.height < 4 {
            rect.fill()
            return
        }
        // Give hatching a solid background so lower-priority track marks do not show through.
        (NSColor.textBackgroundColor.blended(withFraction: 0.16, of: kind.color) ?? .textBackgroundColor).setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        kind.color.setStroke()
        let stripes = NSBezierPath()
        stripes.lineWidth = 1
        var y = rect.minY
        while y < rect.maxY + rect.width {
            stripes.move(to: NSPoint(x: rect.minX, y: y))
            stripes.line(to: NSPoint(x: rect.maxX, y: y - rect.width))
            y += 3
        }
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class JJEditorMarkerView: NSView {
    var drawMarks: ((NSRect) -> Void)?
    var onClick: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawMarks?(dirtyRect) }
    override func mouseDown(with event: NSEvent) { onClick?(event) }
}
