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
        let (scrollView, editor) = EditorTextView.scrollingEditor(in: window.contentLayoutRect)
        window.contentView = scrollView
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        window.center()
        self.window = window

        let app = NSApplication.shared
        installMenus(in: app)
        if CommandLine.arguments.dropFirst().first == "--agent-check" {
            do {
                try EditorCheck.run(in: window, editor: editor, scrollView: scrollView)
                try checkWindow(window, screenshot: CommandLine.arguments.dropFirst(2).first)
                print("Edit passed its native editor checks without activation.")
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("Edit window check: \(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }

        window.makeKeyAndOrderFront(nil)
        app.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenus(in app: NSApplication) {
        let menuBar = NSMenu()
        func addMenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            menuBar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }

        let appMenu = addMenu("Edit")
        appMenu.addItem(withTitle: "Quit Edit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = addMenu("Edit")
        edit.addCommand("Undo", Selector(("undo:")), "z")
        edit.addCommand("Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        edit.addCommand("Cut", #selector(NSText.cut(_:)), "x")
        edit.addCommand("Copy", #selector(NSText.copy(_:)), "c")
        edit.addCommand("Paste", #selector(NSText.paste(_:)), "v")
        edit.addCommand("Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())

        let lines = NSMenu(title: "Lines")
        lines.addCommand("Move Line Up", #selector(EditorTextView.moveLinesUp(_:)), "\u{F700}", [.option])
        lines.addCommand("Move Line Down", #selector(EditorTextView.moveLinesDown(_:)), "\u{F701}", [.option])
        lines.addCommand("Insert Line Above", #selector(EditorTextView.insertLineAbove(_:)), "\r", [.command, .shift])
        lines.addCommand("Insert Line Below", #selector(EditorTextView.insertLineBelow(_:)), "\r")
        lines.addCommand("Indent Lines", #selector(EditorTextView.indentLines(_:)), "]")
        lines.addCommand("Outdent Lines", #selector(EditorTextView.outdentLines(_:)), "[")
        edit.addItem(withTitle: "Lines", action: nil, keyEquivalent: "").submenu = lines

        let view = addMenu("View")
        view.addCommand("Increase Text Size", #selector(EditorTextView.increaseTextSize(_:)), "=")
        view.addCommand("Decrease Text Size", #selector(EditorTextView.decreaseTextSize(_:)), "-")
        view.addCommand("Reset Text Size", #selector(EditorTextView.resetTextSize(_:)), "0")
        view.addItem(.separator())
        view.addCommand("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.control, .command])

        let window = addMenu("Window")
        window.addCommand("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        window.addCommand("Zoom", #selector(NSWindow.performZoom(_:)))
        window.addCommand("Close Window", #selector(NSWindow.performClose(_:)), "w")
        let help = addMenu("Help")
        app.mainMenu = menuBar
        app.windowsMenu = window
        app.helpMenu = help
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

private extension NSMenu {
    func addCommand(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
    ) {
        addItem(withTitle: title, action: action, keyEquivalent: key).keyEquivalentModifierMask = modifiers
    }
}
