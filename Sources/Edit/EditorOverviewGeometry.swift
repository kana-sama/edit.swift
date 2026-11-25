import AppKit

/// Projects source line boundaries onto the same vertical axis for overview paint and navigation.
@MainActor
struct EditorOverviewGeometry {
    private struct Reservation {
        let line: Int
        let totalBefore: CGFloat
        let height: CGFloat
    }

    private let reservations: [Reservation]
    private let reservedRanges: [EditorLayoutSpacing.ID: Range<CGFloat>]
    private let origin: CGFloat
    private let lineHeight: CGFloat
    private let wrappedOffsets: [CGFloat]?
    let height: CGFloat

    init(editor: EditorTextView, lineStarts: [Int], wrappedOffsets: [CGFloat]? = nil) {
        self.wrappedOffsets = wrappedOffsets
        let spacing = editor.layoutSpacing
        let origin = spacing.unspacedOriginY ?? editor.textContainerOrigin.y
        let lineHeight = editor.defaultParagraphStyle?.minimumLineHeight ?? 18
        self.origin = origin
        self.lineHeight = lineHeight
        var gaps: [Int: [EditorLayoutSpacing.Block]] = [:]
        for block in spacing.reservedBlocks {
            let line = Self.line(containing: block.paragraph, starts: lineStarts)
            let boundary = min(block.edge == .before ? line : line + 1, lineStarts.count)
            gaps[boundary, default: []].append(block)
        }
        var total: CGFloat = 0
        var ranges: [EditorLayoutSpacing.ID: Range<CGFloat>] = [:]
        reservations = gaps.keys.sorted().map { line in
            let before = total
            let base = origin + (wrappedOffsets?[line] ?? CGFloat(line) * lineHeight)
            let blocks = gaps[line, default: []]
            // Space after the previous paragraph precedes space before the next paragraph.
            for block in blocks.sorted(by: { $0.edge == .after && $1.edge == .before }) {
                let top = base + total
                total += block.height
                ranges[block.id] = top..<(base + total)
            }
            return Reservation(line: line, totalBefore: before, height: total - before)
        }
        reservedRanges = ranges
        let textHeight = wrappedOffsets?.last ?? CGFloat(lineStarts.count) * lineHeight
        height = max(lineHeight, textHeight) + total
    }

    func position(at line: Int, afterReservation: Bool = false) -> CGFloat {
        let reservationIndex = lowerBound(reservations.count) { reservations[$0].line >= line }
        let current = reservationIndex < reservations.count ? reservations[reservationIndex] : nil
        let ownHeight = current?.line == line ? current?.height ?? 0 : 0
        let totalBefore = current?.totalBefore ?? reservations.last.map { $0.totalBefore + $0.height } ?? 0
        let offset = wrappedOffsets?[line] ?? CGFloat(line) * lineHeight
        return origin + offset + totalBefore + (afterReservation ? ownHeight : 0)
    }

    func fraction(at position: CGFloat) -> CGFloat { min(1, max(0, (position - origin) / height)) }

    func range(for reservation: EditorLayoutSpacing.ID) -> Range<CGFloat>? { reservedRanges[reservation] }

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
