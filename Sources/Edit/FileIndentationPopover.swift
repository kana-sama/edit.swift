import AppKit

@MainActor
final class FileIndentationPopover: NSObject {
    private let popover = NSPopover()
    private let style = NSPopUpButton(frame: .zero, pullsDown: false)
    private let width = NSPopUpButton(frame: .zero, pullsDown: false)
    private let change: (Indentation?) -> Void
    private var effective = Indentation.standard

    init(change: @escaping (Indentation?) -> Void) {
        self.change = change
        super.init()
        style.addItems(withTitles: ["Automatic", "Spaces", "Tabs"])
        style.setAccessibilityLabel("Indent Using")
        style.identifier = .init("Edit.FileSettings.IndentStyle")
        style.target = self
        style.action = #selector(changeStyle(_:))
        for size in Indentation.widths {
            width.addItem(withTitle: String(size))
            width.lastItem?.tag = size
        }
        width.setAccessibilityLabel("Tab Width")
        width.identifier = .init("Edit.FileSettings.TabWidth")
        width.target = self
        width.action = #selector(changeWidth(_:))

        let fields = NSGridView(views: [
            [NSTextField(labelWithString: "Indent using"), style],
            [NSTextField(labelWithString: "Tab width"), width],
        ])
        fields.columnSpacing = 14
        fields.rowSpacing = 8
        fields.yPlacement = .center
        fields.column(at: 0).xPlacement = .leading
        fields.column(at: 1).xPlacement = .fill
        let content = NSStackView(views: [fields])
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
    }

    func update(effective: Indentation, detected: Indentation, override: Indentation?) {
        self.effective = effective
        style.item(at: 0)?.title = detected.style == .tabs ? "Automatic (Tabs)" : "Automatic (Spaces)"
        style.selectItem(at: override.map { $0.style == .tabs ? 2 : 1 } ?? 0)
        width.selectItem(withTag: effective.width)
        if popover.isShown, let view = popover.contentViewController?.view { popover.contentSize = view.fittingSize }
    }

    func toggle(at anchor: NSView, testing: Bool) {
        if popover.isShown { close(); return }
        guard !testing, anchor.window != nil, let view = popover.contentViewController?.view else { return }
        popover.contentSize = view.fittingSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        if popover.isShown { popover.close() }
    }

    @objc private func changeStyle(_ sender: NSPopUpButton) {
        let selected = sender.indexOfSelectedItem
        change(selected == 0 ? nil : Indentation(style: selected == 2 ? .tabs : .spaces, width: effective.width))
    }

    @objc private func changeWidth(_ sender: NSPopUpButton) {
        guard Indentation.widths.contains(sender.selectedTag()) else { return }
        change(Indentation(style: effective.style, width: sender.selectedTag()))
    }

#if EDIT_AGENT_CHECKS
    var contentForCheck: NSView? { popover.contentViewController?.view }
#endif
}
