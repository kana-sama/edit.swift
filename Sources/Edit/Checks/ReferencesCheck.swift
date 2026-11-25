import AppKit

@MainActor
enum ReferencesCheck {
    static func run(in document: DocumentWindow, capture: (NSWindow, String) throws -> Void) throws {
        defer { document.window.close() }
        let root = URL(fileURLWithPath: "/Reference fixture", isDirectory: true)
        let first = root.appending(path: "Sources/Edit/First.swift")
        let second = root.appending(path: "Tests/Second.swift")
        let sibling = root.appending(path: "Sources/Root.swift")
        document.setFolder(root)
        let hits = [first, first, second, sibling].enumerated().map { index, file in
            ReferenceResult(index: index, url: file, line: index, column: 4,
                            excerpt: "let value = \(index)", match: NSRange(location: 4, length: 5))
        }
        var previewed: Int?
        var retained: [Int] = []
        func show() {
            document.sidebar.showReferences(symbol: "value", originURL: first, originLine: 0, originColumn: 4,
                                            results: hits, preview: { reference, indices in
                previewed = reference.index
                retained = indices
            }, activate: { _, _ in }, didHide: { previewed = nil })
            document.window.layoutIfNeeded()
        }
        show()
        guard let header = document.window.toolbar?.items.compactMap({ $0 as? SidebarMenuItem }).first,
              let options = header.options,
              let table = descendant(in: document.window.contentView, of: SidebarActionResultTable.self),
              let sidebar = table.enclosingScrollView?.superview else {
            throw Failure("find the native References table and options")
        }
        try expect(table.numberOfRows == 7 && previewed == 0 && table.selectedRow == 1,
                   "the flat list selects the originating hit")
        func labels(at row: Int) -> [String]? {
            table.view(atColumn: 0, row: row, makeIfNecessary: true)?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        }
        func checkAlignment(at row: Int, leading: CGFloat) throws {
            guard let header = table.view(atColumn: 0, row: row, makeIfNecessary: true),
                  let icon = header.subviews.first(where: { $0 is NSImageView }),
                  let badge = header.subviews.first(where: { $0 is NSBox && !$0.isHidden }) else {
                throw Failure("find a group icon and count badge")
            }
            header.layoutSubtreeIfNeeded()
            let left = sidebar.convert(icon.bounds, from: icon).minX
            let right = sidebar.bounds.maxX - sidebar.convert(badge.bounds, from: badge).maxX
            try expect(abs(left - leading) < 1 && abs(right - 10) < 1,
                       "align the group icon and count to the sidebar edges (left \(left), right \(right))")
        }
        let laterHeading = table.view(atColumn: 0, row: 5, makeIfNecessary: true)
        try expect(labels(at: 0) == ["First.swift", "2"] && laterHeading?.toolTip == second.path &&
                   table.rect(ofRow: 3).height > table.rect(ofRow: 0).height,
                   "headings show only filename and count, with full path in a tooltip and space between groups")
        try checkAlignment(at: 0, leading: 10)
        try capture(document.window, "list")

        let tree = options.menu.indexOfItem(withTitle: "Tree Mode")
        try expect(tree >= 0 && options.menu.items[tree].state == .off, "Tree Mode starts unchecked")
        options.menu.performActionForItem(at: tree)
        try expect(table.numberOfRows == 10 && table.selectedRow == 3 && previewed == 0 &&
                   options.menu.item(withTitle: "Tree Mode")?.state == .on,
                   "turning on Tree Mode adds folders and retains the selected hit")
        try expect(labels(at: 0) == ["Sources", "3"] && labels(at: 1) == ["Edit", "2"] &&
                   labels(at: 2) == ["First.swift", "2"] && labels(at: 7) == ["Tests", "1"],
                   "folder badges sum direct and nested results")
        try checkAlignment(at: 0, leading: 10)
        try checkAlignment(at: 1, leading: 22)
        try checkAlignment(at: 2, leading: 34)
        try capture(document.window, "tree")
        try expect(table.onClickGroup?(0) == true && table.numberOfRows == 4 && table.selectedRow == 0 &&
                   labels(at: 0) == ["Sources", "3"], "collapsing a folder keeps its count and leaves sibling results visible")
        try expect(table.onHorizontalNavigation?(true) == true && table.numberOfRows == 10,
                   "Right expands the selected folder")

        table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        func dismissSelected() throws {
            guard let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true),
                  let button = cell.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Dismiss This Match" }),
                  !button.isHidden else { throw Failure("show the selected reference's dismiss button") }
            button.performClick(nil)
        }
        try dismissSelected()
        try expect(table.numberOfRows == 9 && previewed == 1 && retained == [1, 2, 3] &&
                   labels(at: 0) == ["Sources", "2"] && labels(at: 1) == ["Edit", "1"],
                   "dismissing advances to the next hit and updates every ancestor count")
        try dismissSelected()
        try expect(table.numberOfRows == 6 && previewed == 3 && retained == [2, 3] &&
                   labels(at: 0) == ["Sources", "1"] && labels(at: 1) == ["Root.swift", "1"],
                   "dismissing the last hit removes empty ancestors and selects the next file's result")
        show()
        try expect(table.numberOfRows == 10 && previewed == 0, "a new lookup restores dismissed hits")
        try expect(document.sessionDocument().referencesTreeMode == true && document.sessionDocument().searchTreeMode == nil,
                   "each sidebar remembers its own tree setting")

        document.performFind(.find)
        options.menu.performActionForItem(at: options.menu.indexOfItem(withTitle: "Tree Mode"))
        try expect(document.sessionDocument().searchTreeMode == true && document.sessionDocument().referencesTreeMode == true,
                   "Search stores its own tree setting")
    }

    private static func descendant<T: NSView>(in view: NSView?, of type: T.Type) -> T? {
        guard let view else { return nil }
        return (view as? T) ?? view.subviews.lazy.compactMap { descendant(in: $0, of: type) }.first
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "References: \(detail)" }
    }
}
