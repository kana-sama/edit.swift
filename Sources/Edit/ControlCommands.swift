import AppKit

@MainActor
struct ControlCommand {
    let id: String
    let title: String
    let item: NSMenuItem

    var result: ControlEntry {
        ControlEntry(id: id, title: title, shortcut: shortcut)
    }

    private var shortcut: String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let flags = item.keyEquivalentModifierMask
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = symbols.compactMap { flags.contains($0.0) ? $0.1 : nil }.joined()
        let display = ["\r": "Return", "\t": "Tab", "\u{F700}": "↑", "\u{F701}": "↓",
                       "\u{F702}": "←", "\u{F703}": "→", " ": "Space"]
        return prefix + (display[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    func isAvailable(in document: DocumentWindow, focus: NSResponder?) -> Bool {
        guard let action = item.action, !item.isHidden else { return false }
        if let target = item.target as? NSUserInterfaceValidations {
            return target.validateUserInterfaceItem(item)
        }
        if action == #selector(NSWindow.performClose(_:)) { return document.canReplaceBuffer }
        if action == Selector(("undo:")) {
            return (focus ?? document.editor).undoManager?.canUndo == true
        }
        if action == Selector(("redo:")) {
            return (focus ?? document.editor).undoManager?.canRedo == true
        }
        if let focus = focus as? NSUserInterfaceValidations, (focus as? NSObject)?.responds(to: action) == true {
            return focus.validateUserInterfaceItem(item)
        }
        return true
    }

    func run() {
        guard let action = item.action else { return }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    static func fromMenu(_ menu: NSMenu) -> [ControlCommand] {
        menu.items.flatMap { top -> [ControlCommand] in
            guard let submenu = top.submenu, top.title != "Help" else { return [] }
            return commands(in: submenu, prefix: top.title)
        }
    }

    private static func commands(in menu: NSMenu, prefix: String) -> [ControlCommand] {
        menu.items.flatMap { item -> [ControlCommand] in
            if item.title == "Open Recent" { return [] }
            if let submenu = item.submenu { return commands(in: submenu, prefix: prefix) }
            guard let action = item.action, !item.isSeparatorItem, !item.isHidden,
                  item.title != "Command Mode…" else { return [] }
            if prefix == "Window",
               action != #selector(NSWindow.performMiniaturize(_:)),
               action != #selector(NSWindow.performZoom(_:)) { return [] }
            return [ControlCommand(id: NSStringFromSelector(action), title: "\(prefix): \(item.title)", item: item)]
        }
    }
}

@MainActor
final class ControlCommandHistory {
    private static let key = "control-command-history"
    private var ids: [String]
    private let persist: Bool

    init(persist: Bool) {
        self.persist = persist
        ids = persist ? UserDefaults.standard.stringArray(forKey: Self.key) ?? [] : []
    }

    func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > 100 { ids.removeLast(ids.count - 100) }
        if persist { UserDefaults.standard.set(ids, forKey: Self.key) }
    }

    func arrange(_ commands: [ControlCommand]) -> [ControlCommand] {
        let order = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return commands.sorted {
            let left = order[$0.id] ?? Int.max
            let right = order[$1.id] ?? Int.max
            if left != right { return left < right }
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
    }
}
