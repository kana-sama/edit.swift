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

    private struct GutterMark {
        let mark: JJLineMark
        let bounds: NSRect
        let stripes: [NSRect]
        var isDeletionBoundary = false
    }

    private weak var editor: EditorTextView?
    private weak var nativeScroller: NSScroller?
    private var scrollerStyle: NSScroller.Style?
    private var lineStarts: [Int] = []
    private(set) var marks: [JJLineMark] = []
    var allowsNavigation = true
    private var lastMarkLines: [Int] = []
    private var trackSize = NSSize.zero
    private var trackOverviewRevision: UInt = 0
    private var trackMarks: [PositionedMark] = []
    private let gutterWidth: CGFloat = 7
    private let gutter = JJEditorMarkerView()
    private let track = JJEditorMarkerView()

    init(editor: EditorTextView) {
        self.editor = editor
        gutter.clipsToBounds = true
        track.clipsToBounds = true
        gutter.drawMarks = { [weak self] rect in self?.drawGutter(in: rect) }
        gutter.onClick = { [weak self] event in
            guard let self, let mark = gutterMark(at: gutter.convert(event.locationInWindow, from: nil)) else { return }
            self.editor?.jjInlineDiff?.toggle(mark)
        }
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
        let gutterFrame = NSRect(x: max(clip.minX, exposedOrigin.x), y: clip.minY, width: gutterWidth + 5,
                                 height: clip.height)
        // Compose the gutter with the text so both pass under the same native titlebar material.
        if gutter.superview !== editor {
            editor.addSubview(gutter, positioned: .above, relativeTo: nil)
        }
        let gutterInEditor = editor.convert(gutterFrame, from: scroll)
        if gutter.frame != gutterInEditor { gutter.frame = gutterInEditor }
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
        if frame.size != trackSize || trackOverviewRevision != (editor.jjInlineDiff?.overviewRevision ?? 0) {
            updateTrackMarks()
        }
        if style != .overlay { track.needsDisplay = true }
    }

    func hitTest(in scroll: NSScrollView, at point: NSPoint, nativeHit: NSView) -> NSView? {
        if gutter.superview != nil, scroll.safeAreaRect.contains(point),
           gutterMark(at: gutter.convert(point, from: scroll)) != nil {
            // The paint view shares the titlebar's material with the text. Route clicks
            // at the scroll view, whose edge decorations can cover that subtree.
            var hit: NSView? = nativeHit
            while let view = hit, view !== scroll {
                if view is NSControl || view is JJInlineDiffControls { return nil }
                hit = view.superview
            }
            return gutter
        }
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
        let diff = editor?.jjInlineDiff
        trackOverviewRevision = diff?.overviewRevision ?? 0
        let height = trackSize.height
        let width = min(6, trackSize.width)
        let minimumHeight = min(3, height)
        let rowCount = CGFloat(max(1, diff?.overviewRow(lineStarts.count, includingRemovedAtBoundary: true) ?? lineStarts.count))
        trackMarks = marks.map { mark in
            let rows = diff?.overviewRows(for: mark) ?? mark.lines
            let top = height * CGFloat(rows.lowerBound) / rowCount
            let bottom = height * CGFloat(rows.upperBound) / rowCount
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
        if editor.jjInlineDiff?.revealExpanded(mark) == true { return }
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
            fill(marker.rect, kind: marker.mark.kind, conflictBackground: .textBackgroundColor)
        }
    }

    private func drawGutter(in dirtyRect: NSRect) {
        guard let editor else { return }
        for marker in visibleGutterMarks(in: editor) where marker.bounds.intersects(dirtyRect) {
            if marker.isDeletionBoundary {
                let rect = marker.bounds
                let path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                path.close()
                marker.mark.kind.color.setFill()
                path.fill()
            } else {
                for stripe in marker.stripes where stripe.intersects(dirtyRect) {
                    fill(stripe, kind: marker.mark.kind)
                }
            }
        }
    }

    private func visibleGutterMarks(in editor: EditorTextView) -> [GutterMark] {
        guard let layout = editor.textLayoutManager else { return [] }
        let viewport = layout.textViewportLayoutController.viewportRange.map { editor.charRange($0, in: layout) }
        guard viewport != nil || lineStarts.isEmpty else { return [] }
        let firstLine = max(0, lineIndex(at: viewport?.lowerBound ?? 0) - 1)
        let lastLine = min(lineStarts.count, lineIndex(at: viewport?.upperBound ?? 0) + 1)
        var index = firstMarkEnding(atOrAfter: firstLine)
        var positions: [GutterMark] = []
        while index < marks.count && marks[index].lines.lowerBound <= lastLine {
            if let marker = gutterMark(marks[index], firstLine: firstLine, lastLine: lastLine, in: editor),
               !gutterHitArea(around: marker.bounds).isEmpty {
                positions.append(marker)
            }
            index += 1
        }
        return positions
    }

    private func gutterMark(at point: NSPoint) -> JJLineMark? {
        guard allowsNavigation, gutter.bounds.contains(point), let editor, let diff = editor.jjInlineDiff else { return nil }
        let candidates = visibleGutterMarks(in: editor).filter { diff.canToggle($0.mark) }
        if let exact = candidates.first(where: { point.y >= $0.bounds.minY && point.y < $0.bounds.maxY }) {
            return exact.mark
        }
        return candidates.filter { gutterHitArea(around: $0.bounds).contains(point) }
            .min { abs($0.bounds.midY - point.y) < abs($1.bounds.midY - point.y) }?.mark
    }

    private func gutterHitArea(around rect: NSRect) -> NSRect {
        NSRect(x: 0, y: rect.minY - 4, width: gutter.bounds.width, height: rect.height + 8)
            .intersection(gutter.bounds)
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

    private func gutterMark(_ mark: JJLineMark, firstLine: Int, lastLine: Int, in editor: EditorTextView) -> GutterMark? {
        if let expanded = editor.jjInlineDiff?.expandedRegion(for: mark) {
            let rect = gutter.convert(expanded, from: editor)
            let stripe = NSRect(x: 2, y: rect.minY, width: 3, height: rect.height)
            return GutterMark(mark: mark, bounds: stripe, stripes: [stripe])
        }
        if mark.kind == .deletion {
            guard mark.lines.lowerBound >= firstLine, let y = boundary(mark.lines.lowerBound, editor: editor) else { return nil }
            let axis = gutter.convert(NSPoint(x: 0, y: y), from: editor).y
            let triangle = NSRect(x: 1, y: axis - 3, width: 5, height: 6)
            return GutterMark(mark: mark, bounds: triangle, stripes: [], isDeletionBoundary: true)
        }
        let start = max(mark.lines.lowerBound, firstLine)
        let end = min(mark.lines.upperBound, lastLine)
        guard start < end else { return nil }
        var bounds = NSRect.null
        var stripes: [NSRect] = []
        for line in start..<end {
            guard let row = laidOutLine(at: line, editor: editor) else { continue }
            let rect = gutter.convert(row, from: editor)
            let stripe = NSRect(x: 2, y: rect.minY, width: 3, height: rect.height)
            stripes.append(stripe)
            bounds = bounds.union(stripe)
        }
        return bounds.isNull ? nil : GutterMark(mark: mark, bounds: bounds, stripes: stripes)
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

    private func fill(_ rect: NSRect, kind: JJLineMark.Kind, conflictBackground: NSColor? = nil) {
        kind.color.setFill()
        if kind != .conflict || rect.height < 4 {
            rect.fill()
            return
        }
        if let conflictBackground {
            // Preserve the conflict mark's priority where scrollbar marks overlap.
            (conflictBackground.blended(withFraction: 0.16, of: kind.color) ?? conflictBackground).setFill()
            rect.fill()
        }
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
private final class JJEditorMarkerView: NSView, ClickTarget {
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
