import AppKit

/// A custom click target whose hit test already limits it to its actionable area.
@MainActor
protocol ClickTarget: AnyObject {}

@MainActor
final class EditApplication: NSApplication {
    private let clickCursorTracking = ClickCursorTracking()

    override func finishLaunching() {
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowStoppedTracking(_:)),
                                                   name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: self)
        super.finishLaunching()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        (notification.object as? NSWindow)?.acceptsMouseMovedEvents = true
    }

    @objc private func windowStoppedTracking(_ notification: Notification) {
        if let window = notification.object as? NSWindow, clickCursorTracking.window === window {
            clickCursorTracking.end(restoreImage: false)
        }
    }

    @objc private func appResignedActive(_ notification: Notification) {
        clickCursorTracking.end(restoreImage: false)
    }

    override func sendEvent(_ event: NSEvent) {
        let refreshAfterDispatch: Bool
        switch event.type {
        case .mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited:
            refreshAfterDispatch = false
        case .leftMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel:
            refreshAfterDispatch = true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .rightMouseDown:
            clickCursorTracking.end(restoreImage: false)
            super.sendEvent(event)
            return
        default:
            super.sendEvent(event)
            return
        }
        guard isActive, let window = event.window, window.isVisible else {
            super.sendEvent(event)
            return
        }
        // AppKit can deliver several tracking events for the same movement when rows
        // or controls appear. Resolve them all against the current pointer location.
        let handled = updateClickCursor(in: window)
        if event.type == .cursorUpdate && handled { return }
        super.sendEvent(event)
        if refreshAfterDispatch, isActive, window.isVisible { updateClickCursor(in: window) }
    }

    @discardableResult
    private func updateClickCursor(in window: NSWindow) -> Bool {
        let point = window.mouseLocationOutsideOfEventStream
        return clickCursorTracking.update(Self.clickCursor(in: window, at: point), in: window)
    }

    @MainActor
    final class ClickCursorTracking {
        private(set) weak var window: NSWindow?
        private var cursorOverride: (applied: NSCursor, original: NSCursor)?
        private var restoresCursorRects = false
        private let currentCursor: () -> NSCursor
        private let setCursor: (NSCursor) -> Void

        init(currentCursor: @escaping () -> NSCursor = { NSCursor.current },
             setCursor: @escaping (NSCursor) -> Void = { $0.set() }) {
            self.currentCursor = currentCursor
            self.setCursor = setCursor
        }

        @discardableResult
        func update(_ cursor: NSCursor?, in window: NSWindow) -> Bool {
            if self.window !== window || cursor == nil { end() }
            guard let cursor else { return false }

            if self.window == nil {
                self.window = window
                cursorOverride = (cursor, currentCursor())
            }
            // Choose one cursor owner before dispatch. A native reset followed
            // by a manual set would show two cursor images for one event.
            if window.areCursorRectsEnabled {
                window.disableCursorRects()
                restoresCursorRects = true
            }
            cursorOverride?.applied = cursor
            if currentCursor() !== cursor { setCursor(cursor) }
            return true
        }

        func end(restoreImage: Bool = true) {
            let previousWindow = window
            let previousCursor = cursorOverride
            let enableCursorRects = restoresCursorRects
            window = nil
            cursorOverride = nil
            restoresCursorRects = false
            if enableCursorRects { previousWindow?.enableCursorRects() }
            if restoreImage, let previousCursor, currentCursor() === previousCursor.applied,
               previousCursor.original !== previousCursor.applied {
                setCursor(previousCursor.original)
            }
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
