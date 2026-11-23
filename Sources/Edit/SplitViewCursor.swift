import AppKit

extension NSSplitView {
    /// The cursor for a direct hit on the split view. AppKit's hit test uses the
    /// delegate's effective divider area, including the grip outside the drawn line.
    var dividerResizeCursor: NSCursor? {
        let visiblePanes = arrangedSubviews.lazy.filter { !$0.isHidden && !self.isSubviewCollapsed($0) }
        guard visiblePanes.prefix(2).count == 2 else { return nil }
        return isVertical ? .columnResize : .rowResize
    }
}
