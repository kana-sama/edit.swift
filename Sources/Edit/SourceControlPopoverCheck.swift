import AppKit

@MainActor
enum SourceControlPopoverCheck {
    static func run(preview: JJSourceControlOperations.Preview) throws {
        let anchor = NSView()
        let operations = SourceControlOperationPopover(anchor: anchor, prepare: { _ in preview }, apply: { _ in })
        let operationView = operations.viewForCheck(preview)
        operationView.layoutSubtreeIfNeeded()
        let operationTitle = try label("Repository Operations", in: operationView)
        let workingCopyHeading = try label("Working Copy After \(preview.direction.title)", in: operationView)
        let graphHeading = try label("Change Graph", in: operationView)
        let command = try label("jj \(preview.direction.rawValue)", in: operationView)
        guard let directions = descendants(of: operationView, as: NSSegmentedControl.self).first,
              let scroll = descendants(of: operationView, as: NSScrollView.self).first,
              let apply = descendants(of: operationView, as: NSButton.self).first(where: { $0.title == "\(preview.direction.title) Operation" }) else {
            throw Failure("Missing operation controls")
        }
        let leading = minX(operationTitle, in: operationView)
        for view in [workingCopyHeading, graphHeading, command, directions] {
            try expect(abs(minX(view, in: operationView) - leading) < 1, "Keep the operation title, directions, effects, and command left-aligned")
        }
        try expect(directions.frame.width > 370 && directions.segmentDistribution == .fillEqually,
                   "Use the popover width for Undo and Redo")
        try expect(scroll.hasVerticalScroller && minX(apply, in: operationView) > leading + 200 &&
                   operationView.convert(apply.bounds, from: apply).maxY <= operationView.convert(scroll.bounds, from: scroll).minY,
                   "Keep the Apply button in a fixed trailing footer below the scroll view")
        if let path = preview.fileEffects.first?.path {
            let file = try label(path, in: operationView)
            try expect(abs(minX(file, in: operationView) - leading) < 1 && file.lineBreakMode == .byCharWrapping,
                       "Align paths with the effects and allow long paths to wrap")
        }
    }

    private static func minX(_ child: NSView, in root: NSView) -> CGFloat {
        root.convert(child.alignmentRect(forFrame: child.frame), from: child.superview).minX
    }

    private static func label(_ title: String, in root: NSView) throws -> NSTextField {
        guard let label = descendants(of: root, as: NSTextField.self).first(where: { $0.stringValue == title }) else {
            throw Failure("Missing \(title)")
        }
        return label
    }

    private static func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        root.subviews.flatMap { child in (child as? T).map { [$0] } ?? [] } + root.subviews.flatMap { descendants(of: $0, as: type) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = "Jujutsu popovers: \(message)" }
    }
}
