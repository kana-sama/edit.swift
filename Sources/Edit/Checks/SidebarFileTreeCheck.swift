import AppKit

@MainActor
enum SidebarFileTreeCheck {
    static func checkNameWidths(in tree: NSOutlineView, rows: [Int]) throws {
        tree.window?.layoutIfNeeded()
        for row in rows {
            guard let rowView = tree.rowView(atRow: row, makeIfNecessary: true),
                  let cell = tree.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let label = cell.textField, let textCell = label.cell else {
                throw Failure("Lay out the file tree name at row \(row)")
            }
            rowView.layoutSubtreeIfNeeded()
            let textBounds = textCell.titleRect(forBounds: label.bounds)
            let textEnd = label.convert(textBounds, to: rowView).maxX
            let highlightEnd = rowView.bounds.maxX - 6
            let gap = highlightEnd - textEnd
            guard abs(gap) <= 2, label.lineBreakMode == .byTruncatingMiddle else {
                throw Failure("File tree name \(label.stringValue) truncates in the middle at the selection edge (gap: \(gap) pt)")
            }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}
