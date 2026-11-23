import AppKit

@MainActor
final class SourceControlPanes: NSView {
    private let graphHeader: NSView
    private let graph: NSView
    private let changeHeader: NSView
    private let change: NSView
    private let divider = SourceControlDivider()
    private var graphHeight: CGFloat = 200
    private(set) var graphExpanded = true
    private(set) var changeExpanded = true

    override var isFlipped: Bool { true }

    init(graphHeader: NSView, graph: NSView, changeHeader: NSView, change: NSView) {
        self.graphHeader = graphHeader
        self.graph = graph
        self.changeHeader = changeHeader
        self.change = change
        super.init(frame: .zero)
        clipsToBounds = true
        graph.clipsToBounds = true
        change.clipsToBounds = true
        for child in [graphHeader, graph, divider, changeHeader, change] { addSubview(child) }
        divider.onDrag = { [weak self] movement in
            guard let self else { return }
            graphHeight = graph.frame.height + movement
            needsLayout = true
            layoutSubtreeIfNeeded()
            graphHeight = graph.frame.height
        }
    }

    required init?(coder: NSCoder) { fatalError("Source Control panes are created in code.") }

    func setGraphExpanded(_ expanded: Bool) {
        graphExpanded = expanded
        needsLayout = true
    }

    func setChangeExpanded(_ expanded: Bool) {
        changeExpanded = expanded
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let graphHeaderHeight: CGFloat = 34
        let changeHeaderHeight: CGFloat = 32
        let dividerHeight: CGFloat = 7
        let available = max(0, bounds.height - graphHeaderHeight - changeHeaderHeight - dividerHeight)
        let graphArea: CGFloat
        if !graphExpanded { graphArea = 0 }
        else if !changeExpanded { graphArea = available }
        else {
            let minimumGraph = min(76, available * 0.4)
            let minimumChange = min(125, available * 0.45)
            graphArea = max(minimumGraph, min(graphHeight, available - minimumChange))
        }
        let changeArea = changeExpanded ? available - graphArea : 0
        var top: CGFloat = 0
        for (child, height) in [(graphHeader, graphHeaderHeight), (graph, graphArea), (divider, dividerHeight),
                                (changeHeader, changeHeaderHeight), (change, changeArea)] {
            child.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            top += height
        }
        graph.isHidden = !graphExpanded
        change.isHidden = !changeExpanded
        divider.isMovable = graphExpanded && changeExpanded && available > 0
    }
}

@MainActor
final class SourceControlDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var isMovable = true {
        didSet {
            guard isMovable != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        if isMovable {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 10, y: bounds.midY - 1.5, width: 20, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func resetCursorRects() {
        if isMovable { addCursorRect(bounds, cursor: .rowResize) }
    }

    override func mouseDragged(with event: NSEvent) {
        if isMovable { onDrag?(event.deltaY) }
    }
}
