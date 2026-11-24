import AppKit

@MainActor
final class SourceControlPopover {
    let native = NSPopover()
#if EDIT_AGENT_CHECKS
    private let agentCheck: Bool
    private var checkWindow: NSWindow?
#endif

    init(agentCheck: Bool) {
#if EDIT_AGENT_CHECKS
        self.agentCheck = agentCheck
#endif
    }

    var isShown: Bool {
#if EDIT_AGENT_CHECKS
        if agentCheck { return checkWindow != nil }
#endif
        return native.isShown
    }

    var contentSize: NSSize {
        get { native.contentSize }
        set {
            native.contentSize = newValue
#if EDIT_AGENT_CHECKS
            checkWindow?.setContentSize(newValue)
#endif
        }
    }

    func show(relativeTo rect: NSRect, of anchor: NSView, preferredEdge: NSRectEdge) {
#if EDIT_AGENT_CHECKS
        if agentCheck {
            guard let view = native.contentViewController?.view, checkWindow == nil else { return }
            // AppKit positions the popover's own window. The anchor window's alpha does not hide it.
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.appearance = anchor.effectiveAppearance
            window.contentView = view
            checkWindow = window
            return
        }
#endif
        native.show(relativeTo: rect, of: anchor, preferredEdge: preferredEdge)
    }

    func close() {
#if EDIT_AGENT_CHECKS
        if agentCheck {
            guard let window = checkWindow else { return }
            native.delegate?.popoverWillClose?(Notification(name: NSPopover.willCloseNotification, object: native))
            checkWindow = nil
            window.contentView = nil
            window.close()
            native.delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: native))
            return
        }
#endif
        native.close()
    }
}
