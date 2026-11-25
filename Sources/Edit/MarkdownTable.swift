import Foundation

enum MarkdownTableCommand: String, CaseIterable {
    case format
    case rowBelow
    case columnLeft
    case columnRight
    case toggleBorders

    var title: String {
        switch self {
        case .format: "Format Table"
        case .rowBelow: "Insert Table Row Below"
        case .columnLeft: "Insert Table Column Left"
        case .columnRight: "Insert Table Column Right"
        case .toggleBorders: "Toggle Table Borders"
        }
    }
}

struct MarkdownTable {
    private struct Cell {
        let text: String
        let source: NSRange

        static let empty = Self(text: "", source: NSRange(location: 0, length: 0))
    }

    private struct Row {
        let start: Int
        let end: Int
        let prefix: String
        let raw: String
        var lineEnding: String
        var cells: [Cell]
        var leadingPipe: Bool
        var trailingPipe: Bool

        init(source: NSString, content: NSRange) {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: content.location, length: 0))
            self.start = start
            self.end = contentsEnd
            prefix = source.substring(with: NSRange(location: start, length: content.location - start))
            lineEnding = source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
            let length = max(0, contentsEnd - content.location)
            raw = source.substring(with: NSRange(location: content.location, length: length))
            let units = Array(raw.utf16)
            var pipes: [Int] = []
            var escaped = false
            for (index, unit) in units.enumerated() {
                if unit == 124, !escaped { pipes.append(index) }
                escaped = unit == 92 && !escaped
            }
            let first = units.firstIndex(where: { $0 != 32 && $0 != 9 })
            let last = units.lastIndex(where: { $0 != 32 && $0 != 9 })
            leadingPipe = !pipes.isEmpty && pipes.first == first
            trailingPipe = !pipes.isEmpty && pipes.last == last && (pipes.count > 1 || !leadingPipe)
            let left = leadingPipe ? pipes.removeFirst() + 1 : 0
            let right = trailingPipe ? pipes.removeLast() : length
            let boundaries = [left] + pipes.map { $0 + 1 } + [right + 1]
            cells = zip(boundaries, boundaries.dropFirst()).map { lower, boundary in
                var start = lower
                var end = boundary - 1
                while start < end && (units[start] == 32 || units[start] == 9) { start += 1 }
                while end > start && (units[end - 1] == 32 || units[end - 1] == 9) { end -= 1 }
                return Cell(text: String(decoding: units[start..<end], as: UTF16.self),
                            source: NSRange(location: content.location + start, length: end - start))
            }
        }
    }

    let range: NSRange
    private let rows: [Row]
    private let rowIndex: Int
    private let column: Int
    private let cellOffset: Int

    init?(source: String, caret: Int) {
        let text = source as NSString
        let rowRanges = SyntaxEngine.markdownTableRows(in: source, caret: caret)
        let rows = rowRanges.map { Row(source: text, content: $0) }
        guard rows.count >= 2, let first = rows.first, let last = rows.last,
              let rowIndex = rows.firstIndex(where: { $0.start <= caret && caret <= $0.end }),
              !first.cells.isEmpty, rows[1].cells.count == first.cells.count else { return nil }
        let cells = rows[rowIndex].cells
        let column = cells.firstIndex { caret <= $0.source.upperBound } ?? (cells.count - 1)
        guard column >= 0 else { return nil }
        self.rows = rows
        self.rowIndex = rowIndex
        self.column = min(column, first.cells.count - 1)
        let cell = cells[self.column].source
        cellOffset = min(max(caret - cell.location, 0), cell.length)
        range = NSRange(location: first.start, length: last.end - first.start)
    }

    func edit(_ command: MarkdownTableCommand) -> (text: String, caret: Int) {
        if command == .toggleBorders { return toggleBorders() }
        var rows = self.rows
        var rowIndex = self.rowIndex
        var column = self.column
        var cellOffset = self.cellOffset
        var logicalColumns = rows[0].cells.count
        for index in rows.indices where rows[index].cells.count < logicalColumns {
            rows[index].cells += Array(repeating: .empty, count: logicalColumns - rows[index].cells.count)
        }
        switch command {
        case .format:
            break
        case .rowBelow:
            let after = max(rowIndex, 1)
            var row = rows[after]
            row.cells = Array(repeating: .empty, count: logicalColumns)
            if rows[after].lineEnding.isEmpty {
                rows[after].lineEnding = rows.first(where: { !$0.lineEnding.isEmpty })?.lineEnding ?? "\n"
            }
            rows.insert(row, at: after + 1)
            rowIndex = after + 1
            cellOffset = 0
        case .columnLeft, .columnRight:
            if command == .columnRight { column += 1 }
            for index in rows.indices { rows[index].cells.insert(.empty, at: column) }
            logicalColumns += 1
            cellOffset = 0
        case .toggleBorders:
            break
        }

        let widthCount = rows.map(\.cells.count).max() ?? logicalColumns
        let separator = rows[1].cells.map { cell in (cell.text.hasPrefix(":"), cell.text.hasSuffix(":")) }
        var widths = Array(repeating: 3, count: widthCount)
        for (index, row) in rows.enumerated() where index != 1 {
            for (column, cell) in row.cells.enumerated() {
                widths[column] = max(widths[column], cell.text.count)
            }
        }
        for (column, (left, right)) in separator.enumerated() {
            widths[column] = max(widths[column], 3 + (left ? 1 : 0) + (right ? 1 : 0))
        }

        var lines: [String] = []
        var caret = range.location
        var offset = range.location
        for (index, row) in rows.enumerated() {
            let leading = row.leadingPipe || logicalColumns == 1 || (index != 1 && row.cells.first?.text == "")
            let trailing = row.trailingPipe || (index != 1 && row.cells.last?.text == "")
            var text = row.prefix + (leading ? "| " : "")
            var lineOffset = offset + text.utf16.count
            for (cellIndex, cell) in row.cells.enumerated() {
                if index == rowIndex && cellIndex == column {
                    caret = lineOffset + min(cellOffset, cell.text.utf16.count)
                }
                let cellText: String
                if index == 1 {
                    let (left, right) = separator[cellIndex]
                    let hyphens = widths[cellIndex] - (left ? 1 : 0) - (right ? 1 : 0)
                    cellText = (left ? ":" : "") + String(repeating: "-", count: hyphens) + (right ? ":" : "")
                } else {
                    let isLast = cellIndex == row.cells.count - 1
                    let padding = isLast && !trailing ? 0 : widths[cellIndex] - cell.text.count
                    cellText = cell.text + String(repeating: " ", count: padding)
                }
                let suffix = cellIndex + 1 < row.cells.count ? " | " : (trailing ? " |" : "")
                text += cellText + suffix
                lineOffset += cellText.utf16.count + suffix.utf16.count
            }
            if index + 1 < rows.count { text += row.lineEnding }
            lines.append(text)
            offset += text.utf16.count
        }
        return (lines.joined(), caret)
    }

    var hasBorders: Bool { rows.allSatisfy { $0.leadingPipe && $0.trailingPipe } }

    private func toggleBorders() -> (text: String, caret: Int) {
        let remove = hasBorders
        let singleColumn = rows[0].cells.count == 1
        var text = ""
        var caret = range.location
        for (index, row) in rows.enumerated() {
            var units = Array(row.raw.utf16)
            var delta = 0
            if remove {
                if row.cells.last?.text != "", let pipe = units.lastIndex(of: 124) {
                    let start = pipe > 0 && units[pipe - 1] == 32 ? pipe - 1 : pipe
                    units.removeSubrange(start...pipe)
                }
                if !singleColumn, row.cells.first?.text != "", let pipe = units.firstIndex(of: 124) {
                    let end = pipe + 1 < units.count && units[pipe + 1] == 32 ? pipe + 1 : pipe
                    units.removeSubrange(pipe...end)
                    delta = pipe - end - 1
                }
            } else {
                if !row.leadingPipe { units.insert(contentsOf: [124, 32], at: 0); delta = 2 }
                if !row.trailingPipe { units.append(contentsOf: [32, 124]) }
            }
            if index == rowIndex {
                let cell = row.cells[column].source
                caret = range.location + text.utf16.count + min(max(cell.location - row.start + cellOffset + delta, 0),
                                                              row.prefix.utf16.count + units.count)
            }
            text += row.prefix + String(decoding: units, as: UTF16.self)
            if index + 1 < rows.count { text += row.lineEnding }
        }
        return (text, caret)
    }
}
