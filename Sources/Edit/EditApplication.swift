import AppKit

/// A custom click target whose hit test already limits it to its actionable area.
@MainActor
protocol ClickTarget: AnyObject {}

@MainActor
final class EditApplication: NSApplication {
    private var cursorOverride: (applied: NSCursor, original: NSCursor)?

    override func finishLaunching() {
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        super.finishLaunching()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        (notification.object as? NSWindow)?.acceptsMouseMovedEvents = true
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        switch event.type {
        case .mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited, .leftMouseUp, .scrollWheel:
            break
        default:
            return
        }
        guard isActive, let window = event.window, window.isVisible else { return }

        // AppKit can update the cursor from a text view behind a floating control.
        // Resolve the foreground click target after AppKit dispatches the event.
        let current = NSCursor.current
        if let cursor = Self.clickCursor(in: window, at: event.locationInWindow) {
            guard current !== cursor else { return }
            let original = cursorOverride.flatMap { $0.applied === current ? $0.original : nil } ?? current
            cursorOverride = (cursor, original)
            cursor.set()
        } else if let cursorOverride {
            self.cursorOverride = nil
            if current === cursorOverride.applied { cursorOverride.original.set() }
        }
    }

    static func clickCursor(in window: NSWindow, at location: NSPoint) -> NSCursor? {
        guard let content = window.contentView, let root = content.superview,
              root.bounds.contains(root.convert(location, from: nil)) else { return nil }
        let frameHit = root.hitTest(root.superview?.convert(location, from: nil) ?? location)
        // A full-size content view can offer click targets at the window frame's edge.
        var view = frameHit === root ? content.hitTest(root.convert(location, from: nil)) : frameHit
        while let hit = view {
            switch hit {
            case let button as NSButton:
                return button.isEnabled ? .pointingHand : .arrow
            case is ClickTarget:
                return .pointingHand
            case is JJInlineDiffControls:
                // Disabled buttons can yield hit testing to the panel's background.
                return .arrow
            case let field as NSTextField where field.isEditable || field.isSelectable:
                return nil
            case is NSTextView:
                return nil
            case let table as NSTableView:
                let point = table.convert(location, from: nil)
                let row = table.row(at: point)
                guard row >= 0, table.rect(ofRow: row).contains(point) else { return nil }
                // AppKit can report the row hit while its shared field editor is in front.
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                   editor.visibleRect.contains(editor.convert(location, from: nil)) { return nil }
                let selectable = table.delegate?.tableView?(table, shouldSelectRow: row) ?? true
                return table.isEnabled && selectable ? .pointingHand : .arrow
            default:
                view = hit.superview
            }
        }
        return nil
    }
}
