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
        let documentY: CGFloat
        let reservation: EditorLayoutSpacing.ID?
    }

    private struct GutterMark {
        let mark: JJLineMark
        let bounds: NSRect
        let stripes: [NSRect]
        var isDeletionBoundary = false
        var isExpanded = false
    }

    private weak var editor: EditorTextView?
    private weak var nativeScroller: NSScroller?
    private var scrollerStyle: NSScroller.Style?
    private var lineStarts: [Int] = []
    private var gutterEdits: [EditorTextChange] = []
    private var removedBlocks: [JJLineMark: EditorLayoutSpacing.ID] = [:]
    private var projectedConflictStarts: Set<Int> = []
    private(set) var marks: [JJLineMark] = []
    var allowsNavigation = true
    private var lastMarkLines: [Int] = []
    private var trackSize = NSSize.zero
    private var trackOverviewRevision: UInt = 0
    private var trackStyle: EditorProjectedTextLayout.Style?
    private var wrapLayout: (style: EditorProjectedTextLayout.Style, offsets: [CGFloat])?
    private var pendingWrap: (style: EditorProjectedTextLayout.Style, task: Task<Void, Never>)?
    private var trackExpiry: Task<Void, Never>?
    private var marksMatchBuffer = true
    private var trackNeedsUpdate = true
    private var trackMarks: [PositionedMark] = []
    private static var restingOverlaySlots: [NSControl.ControlSize: NSRect] = [:]
    private let gutterHitWidth: CGFloat = 12
    private let gutterStripeWidth: CGFloat = 2
    private let passiveMarkerOpacity: CGFloat = 0.5
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

    isolated deinit {
        pendingWrap?.task.cancel()
        trackExpiry?.cancel()
    }

    func sourceDidEdit(_ changes: [EditorTextChange]) {
        marksMatchBuffer = false
        if !marks.isEmpty {
            // Changes within one batch use the same old coordinates.
            gutterEdits.append(contentsOf: changes.reversed())
        }
        resetWrapLayout()
    }

    private func resetWrapLayout() {
        pendingWrap?.task.cancel()
        pendingWrap = nil
        wrapLayout = nil
    }

    func setMarks(_ marks: [JJLineMark], lineStarts: [Int], hunks: [JJDiffHunk]) {
        allowsNavigation = true
        let sourceChanged = !marksMatchBuffer || lineStarts != self.lineStarts
        marksMatchBuffer = true
        let projectedStarts = Set(editor?.conflictEdits.map(\.block.location) ?? [])
        let removedBlocks = Dictionary(hunks.filter { !$0.removedText.isEmpty }.map { ($0.mark, EditorLayoutSpacing.ID.removed($0.baseRange)) },
                                       uniquingKeysWith: { first, _ in first })
        guard sourceChanged || marks != self.marks || projectedStarts != projectedConflictStarts || removedBlocks != self.removedBlocks else { return }
        if sourceChanged { resetWrapLayout() }
        projectedConflictStarts = projectedStarts
        self.removedBlocks = removedBlocks
        self.marks = marks.sorted {
            if $0.lines.lowerBound != $1.lines.lowerBound { return $0.lines.lowerBound < $1.lines.lowerBound }
            return $0.kind.drawingPriority < $1.kind.drawingPriority
        }
        self.lineStarts = lineStarts
        gutterEdits.removeAll(keepingCapacity: true)
        var lastLine = 0
        lastMarkLines = self.marks.map {
            lastLine = max(lastLine, $0.lines.upperBound)
            return lastLine
        }
        if marks.isEmpty {
            track.removeFromSuperview()
            trackMarks.removeAll()
            cancelTrackExpiry()
        }
        trackNeedsUpdate = true
        if let scroll = editor?.enclosingScrollView { layout(in: scroll) }
    }

    func layout(in scroll: NSScrollView) {
        guard let editor else { return }
        if marks.isEmpty && editor.conflictEdits.isEmpty {
            gutter.removeFromSuperview()
            return
        }
        let clip = scroll.contentView.frame
        let exposedOrigin = editor.convert(scroll.visibleContentOrigin, to: scroll)
        let gutterFrame = NSRect(x: max(clip.minX, exposedOrigin.x), y: clip.minY, width: gutterHitWidth,
                                 height: clip.height)
        // Compose the gutter with the text so both pass under the same native titlebar material.
        if gutter.superview !== editor {
            editor.addSubview(gutter, positioned: .above, relativeTo: nil)
        }
        let gutterInEditor = editor.convert(gutterFrame, from: scroll)
        if gutter.frame != gutterInEditor { gutter.frame = gutterInEditor }
        gutter.needsDisplay = true

        guard !marks.isEmpty else { return }
        let scroller = scroll.verticalScroller
        let style = scroll.scrollerStyle
        let styleChanged = style != scrollerStyle
        if track.superview !== scroll || scroller !== nativeScroller || styleChanged {
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
        if styleChanged || frame.size != trackSize { trackNeedsUpdate = true }
        if marksMatchBuffer, editor.renameRange == nil { updateTrackMarks(for: editor) }
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
        guard let editor, trackIsCurrent(for: editor), track.superview === scroll, hasVerticalScrollRange(in: scroll),
              trackMark(at: track.convert(point, from: scroll)) != nil else { return nil }
        if let scroller = nativeScroller,
           nativeHit === scroller || nativeHit.isDescendant(of: scroller),
           scroller.testPart(scroll.convert(point, to: nil)) == .knob { return nil }
        return track
    }

    private func trackFrame(in scroll: NSScrollView, scroller: NSScroller?) -> NSRect {
        let clip = scroll.contentView.frame
        let size = scroller?.controlSize ?? .regular
        let width = NSScroller.scrollerWidth(for: size, scrollerStyle: scroll.scrollerStyle)
        // The scroll view extends under the docked sidebars. The scroller follows the exposed pane.
        let edge = NSRect(x: scroll.safeAreaRect.maxX - width, y: clip.minY, width: width, height: clip.height)
        var slot = edge
        var rightEdge = edge.maxX
        if let scroller, scroller.superview === scroll, hasVerticalScrollRange(in: scroll) {
            let frame = scroll.convert(scroller.bounds, from: scroller)
            let nativeSlot = scroll.convert(scroller.rect(for: .knobSlot), from: scroller).intersection(scroll.bounds)
            // AppKit can retain the old scroller frame while a sidebar is moving.
            if abs(frame.maxX - rightEdge) < 1, !nativeSlot.isEmpty {
                slot = nativeSlot
                rightEdge = frame.maxX
            }
        }
        guard scroll.scrollerStyle == .overlay else { return slot }

        let resting = Self.restingOverlaySlot(for: size, width: width)
        return NSRect(x: rightEdge - width + resting.minX, y: slot.minY, width: resting.width, height: slot.height)
    }

    private static func restingOverlaySlot(for size: NSControl.ControlSize, width: CGFloat) -> NSRect {
        if let slot = restingOverlaySlots[size] { return slot }
        // A detached scroller provides AppKit's unexpanded geometry without hover or fade state.
        let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: width, height: width * 8))
        scroller.controlSize = size
        scroller.scrollerStyle = .overlay
        scroller.knobProportion = 0.5
        let slot = scroller.rect(for: .knobSlot)
        if slot.isEmpty { return scroller.bounds }
        restingOverlaySlots[size] = slot
        return slot
    }

    private func hasVerticalScrollRange(in scroll: NSScrollView) -> Bool {
        scroll.contentView.bounds.height < (scroll.documentView?.frame.height ?? 0)
    }

    private func trackIsCurrent(for editor: EditorTextView) -> Bool {
        allowsNavigation && marksMatchBuffer && editor.renameRange == nil && !trackNeedsUpdate &&
            trackOverviewRevision == editor.layoutSpacing.overviewRevision &&
            trackStyle == .init(editor: editor, wrapsToEditor: true)
    }

    private func updateTrackMarks(for editor: EditorTextView) {
        let style = EditorProjectedTextLayout.Style(editor: editor, wrapsToEditor: true)
        let offsets: [CGFloat]?
        if style.wrapWidth != nil {
            guard let wrapLayout, wrapLayout.style == style else {
                prepareWrapLayout(for: editor, style: style)
                return
            }
            pendingWrap?.task.cancel()
            pendingWrap = nil
            offsets = wrapLayout.offsets
        } else {
            resetWrapLayout()
            offsets = nil
        }
        cancelTrackExpiry()
        guard trackNeedsUpdate || trackStyle != style || trackOverviewRevision != editor.layoutSpacing.overviewRevision else { return }
        trackNeedsUpdate = false
        trackSize = track.bounds.size
        trackOverviewRevision = editor.layoutSpacing.overviewRevision
        trackStyle = style
        let geometry = EditorOverviewGeometry(editor: editor, lineStarts: lineStarts, wrappedOffsets: offsets)
        let height = trackSize.height
        let sideClearance: CGFloat = scrollerStyle == .overlay ? 2 : 0
        let width = min(4, max(0, trackSize.width - sideClearance)) * (2.0 / 3.0)
        let minimumHeight = min(3, height)
        trackMarks = marks.map { mark in
            let reservation = removedBlocks[mark]
            let removed = reservation.flatMap { geometry.range(for: $0) }
            let position = removed?.lowerBound ?? geometry.position(at: mark.lines.lowerBound, afterReservation: true)
            let end = mark.lines.isEmpty ? removed?.upperBound ?? position : geometry.position(at: mark.lines.upperBound)
            let top = height * geometry.fraction(at: position)
            let bottom = height * geometry.fraction(at: max(end, position))
            let markHeight = min(height, max(minimumHeight, bottom - top))
            let centered = (top + bottom - markHeight) / 2
            let rect = NSRect(x: (trackSize.width - width) / 2, y: max(0, min(height - markHeight, centered)),
                              width: width, height: markHeight)
            return PositionedMark(mark: mark, rect: rect, documentY: position, reservation: removed == nil ? nil : reservation)
        }.sorted { $0.mark.kind.drawingPriority < $1.mark.kind.drawingPriority }
        track.needsDisplay = true
    }

    private func prepareWrapLayout(for editor: EditorTextView, style: EditorProjectedTextLayout.Style) {
        guard pendingWrap?.style != style else { return }
        pendingWrap?.task.cancel()
        if trackExpiry == nil, !trackMarks.isEmpty {
            trackExpiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(750)) }
                catch { return }
                guard let self else { return }
                trackExpiry = nil
                trackNeedsUpdate = true
                trackMarks.removeAll()
                track.needsDisplay = true
            }
        }
        let starts = lineStarts
        let text = editor.string
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let layout = EditorProjectedTextLayout(text: text, style: style)
            let offsets = await layout.lineBoundaryOffsets(starts)
            guard !Task.isCancelled, let self else { return }
            if let offsets, let scroll = self.editor?.enclosingScrollView {
                pendingWrap = nil
                wrapLayout = (style, offsets)
                self.layout(in: scroll)
            }
        }
        pendingWrap = (style, task)
    }

    private func cancelTrackExpiry() {
        trackExpiry?.cancel()
        trackExpiry = nil
    }

    private func trackMark(at point: NSPoint) -> PositionedMark? {
        if !track.bounds.contains(point) {
            // Retain click slop in the native slot when an overlay expands beyond its resting lane.
            guard scrollerStyle == .overlay, let scroller = nativeScroller,
                  track.convert(scroller.rect(for: .knobSlot), from: scroller).contains(point) else { return nil }
        }
        // Choose visible paint before hit slop so the visible priority always wins collisions.
        return trackMarks.reversed().first { $0.rect.contains(point) }
            // Include the space removed from each side when narrowing the paint to two thirds.
            ?? trackMarks.reversed().first { $0.rect.insetBy(dx: -(3 + $0.rect.width / 4), dy: -1).contains(point) }
    }

    private func clickTrack(_ event: NSEvent) {
        if !event.modifierFlags.intersection([.option, .control]).isEmpty {
            nativeScroller?.mouseDown(with: event)
            return
        }
        guard let editor, trackIsCurrent(for: editor), let scroll = editor.enclosingScrollView,
              let positioned = trackMark(at: track.convert(event.locationInWindow, from: nil)) else { return }
        let line = positioned.mark.lines.lowerBound
        let length = editor.textStorage?.length ?? 0
        let atEnd = !lineStarts.indices.contains(line)
        let offset = atEnd ? max(0, length - 1) : lineStarts[line]
        let visibleHeight = max(0, scroll.documentVisibleRect.height - scroll.contentInsets.top - scroll.contentInsets.bottom)
        let horizontal = scroll.visibleContentOrigin.x
        func center(_ y: CGFloat) {
            let currentTop = scroll.documentVisibleRect.minY + scroll.contentInsets.top
            let next = NSPoint(x: horizontal, y: scroll.visibleContentOrigin.y + y - visibleHeight / 2 - currentTop)
            if scroll.scrollToVisibleContentOrigin(next) {
                editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            }
        }
        func nativeTarget() -> CGFloat? {
            if let reservation = positioned.reservation { return editor.layoutSpacing.rect(for: reservation)?.minY }
            if length == 0 { return editor.textContainerOrigin.y }
            guard let row = editor.laidOutLineBounds(at: offset) else { return nil }
            return atEnd ? row.maxY : row.minY
        }
        center(positioned.documentY)
        if let target = nativeTarget() { center(target) }
        let visible = scroll.documentVisibleRect
        let exposedTop = visible.minY + scroll.contentInsets.top
        let exposedBottom = visible.maxY - scroll.contentInsets.bottom
        // A large jump can expose live coordinates that TextKit was still estimating.
        if nativeTarget().map({ $0 < exposedTop - 1 || $0 > exposedBottom + 1 }) ?? true {
            editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            if let target = nativeTarget() { center(target) }
            else { scroll.scrollToVisibleContentOrigin(NSPoint(x: horizontal, y: scroll.visibleContentOrigin.y)) }
        }
        editor.jjInlineDiff?.layout()
    }

    private func drawTrack(in dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
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
        // Composite the marks together so overlapping marks keep their priority and opacity.
        context.setAlpha(passiveMarkerOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        for marker in trackMarks where marker.rect.intersects(dirtyRect) {
            fill(marker.rect, kind: marker.mark.kind, conflictBackground: .textBackgroundColor)
        }
    }

    private func drawGutter(in dirtyRect: NSRect) {
        guard let editor else { return }
        for marker in visibleGutterMarks(in: editor) where marker.bounds.intersects(dirtyRect) {
            let opacity: CGFloat = marker.isExpanded ? 1 : passiveMarkerOpacity
            if marker.isDeletionBoundary {
                let rect = marker.bounds
                let path = NSBezierPath()
                path.move(to: NSPoint(x: rect.minX, y: rect.minY))
                path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                path.close()
                marker.mark.kind.color.withAlphaComponent(opacity).setFill()
                path.fill()
            } else {
                for stripe in marker.stripes where stripe.intersects(dirtyRect) {
                    fill(stripe, kind: marker.mark.kind, opacity: opacity)
                }
            }
        }
        drawProjectedConflicts(in: dirtyRect, editor: editor)
    }

    private func drawProjectedConflicts(in dirtyRect: NSRect, editor: EditorTextView) {
        guard !editor.conflictEdits.isEmpty, let text = editor.textStorage?.mutableString,
              let layout = editor.textLayoutManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let visible = NSIntersectionRange(editor.charRange(viewport, in: layout), NSRange(location: 0, length: text.length))
        for edit in editor.conflictEdits {
            if edit.block.location >= visible.upperBound { break }
            let range = NSIntersectionRange(edit.block, visible)
            guard range.length > 0 else { continue }
            var offset = LineEditing.line(at: range.location, in: text).start
            while offset < range.upperBound {
                if let row = editor.laidOutLineBounds(at: offset) {
                    let rect = gutter.convert(row, from: editor)
                    let stripe = NSRect(x: 2, y: rect.minY, width: gutterStripeWidth, height: rect.height)
                    if stripe.intersects(dirtyRect) { fill(stripe, kind: .conflict, opacity: passiveMarkerOpacity) }
                }
                let next = LineEditing.line(at: offset, in: text).end
                guard next > offset else { break }
                offset = next
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
            let mark = marks[index]
            index += 1
            let start = mark.lines.lowerBound
            // Projected blocks already follow buffer edits. The matching cached mark belongs
            // to that block until the next comparison, even if the block has been resolved.
            if mark.kind == .conflict, lineStarts.indices.contains(start), projectedConflictStarts.contains(lineStarts[start]) { continue }
            if let marker = gutterMark(mark, firstLine: firstLine, lastLine: lastLine, in: editor),
               !gutterHitArea(around: marker.bounds).isEmpty {
                positions.append(marker)
            }
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
            if gutterOffset(for: middle) <= offset { low = middle + 1 }
            else { high = middle }
        }
        return max(0, low - 1)
    }

    private func gutterOffset(for line: Int) -> Int {
        var offset = lineStarts[line]
        for edit in gutterEdits {
            if offset >= edit.range.upperBound { offset += edit.delta }
            else if offset >= edit.range.location { offset = edit.range.location }
        }
        return offset
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
            let stripe = NSRect(x: 2, y: rect.minY, width: gutterStripeWidth, height: rect.height)
            return GutterMark(mark: mark, bounds: stripe, stripes: [stripe], isExpanded: true)
        }
        if mark.kind == .deletion {
            guard mark.lines.lowerBound >= firstLine, let y = boundary(mark.lines.lowerBound, editor: editor) else { return nil }
            let axis = gutter.convert(NSPoint(x: 0, y: y), from: editor).y
            let triangle = NSRect(x: 1, y: axis - 3, width: 10.0 / 3.0, height: 6)
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
            let stripe = NSRect(x: 2, y: rect.minY, width: gutterStripeWidth, height: rect.height)
            stripes.append(stripe)
            bounds = bounds.union(stripe)
        }
        return bounds.isNull ? nil : GutterMark(mark: mark, bounds: bounds, stripes: stripes)
    }

    private func laidOutLine(at line: Int, editor: EditorTextView) -> NSRect? {
        guard lineStarts.indices.contains(line), let layout = editor.textLayoutManager else { return nil }
        var offset = gutterOffset(for: line)
        if !gutterEdits.isEmpty, let text = editor.textStorage?.mutableString {
            // The cached mark still belongs to a source row, including when that row wraps.
            offset = LineEditing.line(at: min(offset, text.length), in: text).start
        }
        guard let location = layout.location(layout.documentRange.location, offsetBy: offset),
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

    private func fill(_ rect: NSRect, kind: JJLineMark.Kind, opacity: CGFloat = 1, conflictBackground: NSColor? = nil) {
        let color = kind.color.withAlphaComponent(opacity)
        color.setFill()
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
        color.setStroke()
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
