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
        switch event.type {
        case .mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited,
             .leftMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel:
            break
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .rightMouseDown:
            clickCursorTracking.end(restoreImage: false)
            super.sendEvent(event)
            return
        default:
            super.sendEvent(event)
            return
        }
        guard isActive else {
            super.sendEvent(event)
            return
        }
        let point = NSEvent.mouseLocation
        guard let window = Self.cursorWindow(for: event, at: point, windowAt: { point in
            self.window(withWindowNumber: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
        }) else {
            clickCursorTracking.end(restoreImage: false)
            super.sendEvent(event)
            return
        }
        clickCursorTracking.dispatch(event.type, in: window, resolve: {
            guard self.isActive, window.isVisible else { return nil }
            return Self.clickCursor(in: window, at: window.mouseLocationOutsideOfEventStream)
        }) {
            super.sendEvent(event)
        }
    }

    @discardableResult
    func updatePointerCursor(in window: NSWindow) -> Bool {
        guard isActive, window.isVisible else { return false }
        guard let cursor = Self.clickCursor(in: window, at: window.mouseLocationOutsideOfEventStream) else {
            clickCursorTracking.end(restoreImage: false)
            return false
        }
        return clickCursorTracking.update(cursor, in: window)
    }

    static func cursorWindow(for event: NSEvent, at screenPoint: NSPoint,
                             windowAt: (NSPoint) -> NSWindow?) -> NSWindow? {
        // Mouse movement can arrive with no AppKit window, including over window chrome.
        // Resolve the current pointer consistently across queued tracking events.
        if let window = event.window, window.isVisible, window.frame.contains(screenPoint) { return window }
        guard let window = windowAt(screenPoint), window.isVisible else { return nil }
        return window
    }

    @MainActor
    final class ClickCursorTracking {
        private(set) weak var window: NSWindow?
        private var originalCursor: NSCursor?
        private var appliedCursor: NSCursor?
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
            guard let cursor else {
                end()
                return false
            }
            prepare(cursor, in: window)
            appliedCursor = cursor
            if currentCursor() !== cursor { setCursor(cursor) }
            return true
        }

        func dispatch(_ type: NSEvent.EventType, in window: NSWindow,
                      resolve: () -> NSCursor?, send: () -> Void) {
            let cursor = resolve()
            if type == .cursorUpdate {
                if let cursor {
                    update(cursor, in: window)
                } else {
                    end(restoreImage: false)
                    send()
                }
                return
            }
            // AppKit can show or move a control during dispatch. Resolve its cursor afterward.
            prepare(cursor, in: window)
            send()
            update(resolve(), in: window)
        }

        private func prepare(_ cursor: NSCursor?, in window: NSWindow) {
            if self.window !== window { end(restoreImage: false) }
            guard cursor != nil || self.window === window else { return }
            if self.window == nil {
                self.window = window
                originalCursor = currentCursor()
            }
            // Document views use native tracking callbacks too. Disabling their rectangles
            // makes AppKit show the default arrow during an internal cursor refresh.
            if !(window is EditorDocumentWindow), window.areCursorRectsEnabled {
                window.disableCursorRects()
                restoresCursorRects = true
            }
        }

        func end(restoreImage: Bool = true) {
            let previousWindow = window
            let original = originalCursor
            let applied = appliedCursor
            let enableCursorRects = restoresCursorRects
            window = nil
            originalCursor = nil
            appliedCursor = nil
            restoresCursorRects = false
            if enableCursorRects { previousWindow?.enableCursorRects() }
            if restoreImage, let original, let applied, currentCursor() === applied, original !== applied {
                setCursor(original)
            }
        }
    }

    static func clickCursor(in window: NSWindow, at location: NSPoint) -> NSCursor? {
        guard let content = window.contentView, let root = content.superview,
              root.bounds.contains(root.convert(location, from: nil)) else { return nil }
        // Full-size content can draw behind the titlebar. That text does not own its cursor.
        let titlebar = window.styleMask.contains(.titled) && location.y >= window.contentLayoutRect.maxY
        let background: NSCursor? = titlebar ? .arrow : nil
        let frameHit = root.hitTest(root.superview?.convert(location, from: nil) ?? location)
        // A full-size content view can offer click targets at the window frame's edge.
        let foregroundHit = frameHit === root && !titlebar ? content.hitTest(root.convert(location, from: nil)) : frameHit
        var view = foregroundHit
        while let hit = view {
            switch hit {
            case let button as NSButton:
                return button.isEnabled ? .pointingHand : .arrow
            case let split as NSSplitView where hit === foregroundHit:
                return split.dividerResizeCursor ?? background
            case let divider as SourceControlDivider:
                return divider.isMovable ? .rowResize : .arrow
            case is ClickTarget:
                return .pointingHand
            case is JJInlineDiffControls:
                // Disabled buttons can yield hit testing to the panel's background.
                return .arrow
            case let field as NSTextField where field.isEditable || field.isSelectable:
                return background
            case is NSTextView:
                return background
            case let table as NSTableView:
                if titlebar { return .arrow }
                let point = table.convert(location, from: nil)
                let row = table.row(at: point)
                guard row >= 0, table.rect(ofRow: row).contains(point) else { return .arrow }
                // AppKit can report the row hit while its shared field editor is in front.
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                   editor.visibleRect.contains(editor.convert(location, from: nil)) { return nil }
                let selectable = table.delegate?.tableView?(table, shouldSelectRow: row) ?? true
                return table.isEnabled && selectable ? .pointingHand : .arrow
            default:
                view = hit.superview
            }
        }
        return background
    }
}
