import AppKit

@main
@MainActor
final class Edit: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = Edit()
        app.delegate = delegate
        let isAgentCheck = CommandLine.arguments.dropFirst().first == "--agent-check"
        app.setActivationPolicy(isAgentCheck ? .prohibited : .regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit"
        window.center()
        self.window = window

        let app = NSApplication.shared
        if CommandLine.arguments.dropFirst().first == "--agent-check" {
            do {
                try checkWindow(window, screenshot: CommandLine.arguments.dropFirst(2).first)
                print("Edit created and rendered its window without activation.")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("Edit window check: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        let editMenu = NSMenu()
        let appItem = editMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Edit")
        appMenu.addItem(withTitle: "Quit Edit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        app.mainMenu = editMenu

        window.makeKeyAndOrderFront(nil)
        app.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func checkWindow(_ window: NSWindow, screenshot: String?) throws {
        let app = NSApplication.shared
        guard app.activationPolicy() == .prohibited, !app.isActive, !window.isVisible,
              window.title == "Edit", let frameView = window.contentView?.superview else {
            throw CheckError.unexpectedWindow
        }

        window.layoutIfNeeded()
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CheckError.unrenderableWindow
        }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        if let screenshot {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CheckError.unrenderableWindow
            }
            try png.write(to: URL(fileURLWithPath: screenshot), options: .atomic)
        }
    }

    private enum CheckError: LocalizedError {
        case unexpectedWindow
        case unrenderableWindow

        var errorDescription: String? {
            switch self {
            case .unexpectedWindow:
                "Expected a hidden, non-activating window titled Edit."
            case .unrenderableWindow:
                "AppKit could not render the window."
            }
        }
    }
}
