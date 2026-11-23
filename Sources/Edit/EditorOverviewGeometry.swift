import AppKit

/// Projects source line boundaries onto the same vertical axis for overview paint and navigation.
@MainActor
struct EditorOverviewGeometry {
    private struct Reservation {
        let line: Int
        let totalBefore: CGFloat
        let height: CGFloat
    }

    private let editor: EditorTextView
    private let starts: [Int]
    private let reservations: [Reservation]
    private let origin: CGFloat
    private let lineHeight: CGFloat
    private let viewport: NSRange?
    let height: CGFloat

    init(editor: EditorTextView, lineStarts: [Int]) {
        self.editor = editor
        starts = lineStarts
        let spacing = editor.layoutSpacing
        origin = spacing.unspacedOriginY ?? editor.textContainerOrigin.y
        lineHeight = editor.defaultParagraphStyle?.minimumLineHeight ?? 18
        viewport = editor.textLayoutManager.flatMap { manager in
            manager.textViewportLayoutController.viewportRange.map { editor.charRange($0, in: manager) }
        }
        var gaps: [Int: CGFloat] = [:]
        for block in spacing.reservedBlocks {
            let line = Self.line(containing: block.paragraph, starts: lineStarts)
            let boundary = block.edge == .before ? line : line + 1
            gaps[min(boundary, lineStarts.count), default: 0] += block.height
        }
        var total: CGFloat = 0
        reservations = gaps.keys.sorted().map { line in
            let height = gaps[line, default: 0]
            let reservation = Reservation(line: line, totalBefore: total, height: height)
            total += height
            return reservation
        }
        height = max(1, CGFloat(max(1, lineStarts.count)) * lineHeight + total)
    }

    func position(at line: Int, afterReservation: Bool = false) -> CGFloat {
        let reservationIndex = lowerBound(reservations.count) { reservations[$0].line >= line }
        let current = reservationIndex < reservations.count ? reservations[reservationIndex] : nil
        let ownHeight = current?.line == line ? current?.height ?? 0 : 0
        if starts.indices.contains(line), let viewport, NSLocationInRange(starts[line], viewport),
           let bounds = editor.laidOutLineBounds(at: starts[line]) {
            return bounds.minY - (afterReservation ? 0 : ownHeight)
        }
        let totalBefore = current?.totalBefore ?? reservations.last.map { $0.totalBefore + $0.height } ?? 0
        return origin + CGFloat(line) * lineHeight + totalBefore + (afterReservation ? ownHeight : 0)
    }

    func fraction(at position: CGFloat) -> CGFloat { min(1, max(0, (position - origin) / height)) }

    func nativeBoundary(at line: Int) -> CGFloat? {
        if starts.isEmpty { return line == 0 ? origin : nil }
        if starts.indices.contains(line) { return editor.laidOutLineBounds(at: starts[line])?.minY }
        return line == starts.count ? starts.last.flatMap { editor.laidOutLineBounds(at: $0)?.maxY } : nil
    }

    private static func line(containing offset: Int, starts: [Int]) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }

    private func lowerBound(_ count: Int, satisfying condition: (Int) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if condition(middle) { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }
}
