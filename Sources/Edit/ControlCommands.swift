import AppKit

@MainActor
struct ControlCommand {
    let id: String
    let title: String
    let item: NSMenuItem
    var documentOnly = false
    var displayedShortcut: String?

    var result: ControlEntry {
        ControlEntry(id: id, title: title, shortcut: shortcut)
    }

    private var shortcut: String? {
        if let displayedShortcut { return displayedShortcut }
        if item.action == #selector(EditorTextView.skipNextOccurrence(_:)) { return "⌘K ⌘D" }
        if item.action == #selector(EditorTextView.outdentLines(_:)) { return "⌘[ · ⇧Tab" }
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
        if action == #selector(DocumentWindow.splitTerminalFromControl(_:)) {
            return document.window.attachedSheet == nil && document.terminalHasFocus(focus)
        }
        if action == #selector(Edit.focusSelection(_:)) { return document.canFocusSelection }
        if action == #selector(Edit.exitFocus(_:)) { return document.canExitFocus }
        if action == #selector(Edit.closeDocument(_:)) { return document.canCloseDocument }
        if action == #selector(Edit.closeWorkspace(_:)) { return document.canCloseWorkspace }
        if action == #selector(Edit.toggleWordWrap(_:)) { return document.canToggleWordWrap }
        if action == #selector(Edit.toggleLSPHighlight(_:)) { return document.canToggleLSPHighlight }
        if action == #selector(Edit.performFindControlAction(_:)), let command = item.representedObject as? FindCommand {
            return document.canPerformFind(command)
        }
        if action == #selector(DocumentWindow.performMarkdownTableCommand(_:)) { return document.currentMarkdownTable != nil }
        if documentOnly {
            guard document.hasTextDocument, !document.isShowingMarkdownPreview, document.window.attachedSheet == nil,
                  document.editor.responds(to: action) else { return false }
            if Self.isCaseCommand(action) { return document.editor.validateUserInterfaceItem(item) }
            return !Self.isBracketCommand(action) || document.editor.canNavigateBrackets
        }
        if let target = item.target as? NSUserInterfaceValidations {
            return target.validateUserInterfaceItem(item)
        }
        if let focus = focus as? NSUserInterfaceValidations, (focus as? NSObject)?.responds(to: action) == true {
            return focus.validateUserInterfaceItem(item)
        }
        if action == Selector(("undo:")) {
            return (focus ?? document.editor).undoManager?.canUndo == true
        }
        if action == Selector(("redo:")) {
            return (focus ?? document.editor).undoManager?.canRedo == true
        }
        return true
    }

    func toggleState(in document: DocumentWindow) -> Bool? {
        switch item.action {
        case #selector(Edit.toggleLSPHighlight(_:)): return document.isLSPHighlightEnabled
        case #selector(Edit.toggleWordWrap(_:)): return document.editor.wrapsWords
        case #selector(Edit.toggleMarkdownPreview(_:)): return document.isShowingMarkdownPreview
        case #selector(Edit.toggleSidebar(_:)): return document.isSidebarVisible
        case #selector(Edit.toggleTerminal(_:)): return document.isTerminalVisible
        case #selector(NSWindow.toggleFullScreen(_:)): return document.window.styleMask.contains(.fullScreen)
        case #selector(Edit.performFindControlAction(_:)):
            switch item.representedObject as? FindCommand {
            case .toggleReplace: return document.findSettings.showsReplacement
            case .toggleCase: return document.findSettings.options.caseSensitive
            case .toggleWholeWord: return document.findSettings.options.wholeWord
            case .toggleRegex: return document.findSettings.options.regularExpression
            default: return nil
            }
        case #selector(DocumentWindow.performMarkdownTableCommand(_:)):
            guard item.representedObject as? MarkdownTableCommand == .toggleBorders else { return nil }
            return document.currentMarkdownTable?.hasBorders
        default: return nil
        }
    }

    func run(in document: DocumentWindow) {
        guard let action = item.action else { return }
        if action == #selector(DocumentWindow.splitTerminalFromControl(_:)) {
            document.splitTerminalFromControl(item)
            return
        }
        if action == #selector(Edit.focusSelection(_:)) {
            document.focusSelection()
            return
        }
        if action == #selector(Edit.exitFocus(_:)) {
            document.exitFocus()
            return
        }
        if action == #selector(Edit.closeDocument(_:)) {
            document.closeDocument()
            return
        }
        if action == #selector(Edit.closeWorkspace(_:)) {
            document.closeWorkspace()
            return
        }
        if action == #selector(Edit.toggleMarkdownPreview(_:)) {
            document.toggleMarkdownPreview()
            return
        }
        if action == #selector(Edit.toggleWordWrap(_:)) {
            document.toggleWordWrap()
            return
        }
        if action == #selector(Edit.toggleLSPHighlight(_:)) {
            document.toggleLSPHighlight()
            return
        }
        if action == #selector(Edit.toggleSidebar(_:)) {
            document.performFind(.toggleSidebar)
            return
        }
        if action == #selector(Edit.toggleTerminal(_:)) {
            document.toggleTerminal()
            return
        }
        if action == #selector(NSWindow.toggleFullScreen(_:)) {
            document.window.toggleFullScreen(item)
            return
        }
        if action == #selector(Edit.performFindControlAction(_:)), let command = item.representedObject as? FindCommand {
            document.performFind(command)
            return
        }
        if documentOnly {
            guard document.hasTextDocument else { return }
            document.focusContent()
            document.editor.doCommand(by: action)
            return
        }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    static func fromMenu(_ menu: NSMenu) -> [ControlCommand] {
        menu.items.flatMap { top -> [ControlCommand] in
            guard let submenu = top.submenu, top.title != "Help" else { return [] }
            return commands(in: submenu, prefix: top.title)
        }
    }

    static func editorCommands(for document: DocumentWindow) -> [ControlCommand] {
        let nativeActions: [(String, String, String)] = [
            ("Insert Line Break", "insertNewline:", "Return"),
            ("Indent at Caret or Selection", "insertTab:", "Tab"),
            ("Delete Backward", "deleteBackward:", "⌫"),
            ("Delete Forward", "deleteForward:", "⌦"),
            ("Delete Word Backward", "deleteWordBackward:", "⌥⌫"),
            ("Delete Word Forward", "deleteWordForward:", "⌥⌦"),
            ("Delete to Beginning of Line", "deleteToBeginningOfLine:", "⌘⌫"),
            ("Delete to End of Line", "deleteToEndOfLine:", "⌘⌦"),
            ("Move Caret Left", "moveLeft:", "←"), ("Move Caret Right", "moveRight:", "→"),
            ("Move Caret Up", "moveUp:", "↑"), ("Move Caret Down", "moveDown:", "↓"),
            ("Move to Previous Word Start", "moveWordLeft:", "⌥←"),
            ("Move to Next Word End", "moveWordRight:", "⌥→"),
            ("Move to Beginning of Line", "moveToBeginningOfLine:", "⌘←"),
            ("Move to End of Line", "moveToEndOfLine:", "⌘→"),
            ("Move to Beginning of Document", "moveToBeginningOfDocument:", "⌘↑"),
            ("Move to End of Document", "moveToEndOfDocument:", "⌘↓"),
            ("Extend Selection Left", "moveLeftAndModifySelection:", "⇧←"),
            ("Extend Selection Right", "moveRightAndModifySelection:", "⇧→"),
            ("Extend Selection Up", "moveUpAndModifySelection:", "⇧↑"),
            ("Extend Selection Down", "moveDownAndModifySelection:", "⇧↓"),
            ("Extend Selection to Previous Word Start", "moveWordLeftAndModifySelection:", "⌥⇧←"),
            ("Extend Selection to Next Word End", "moveWordRightAndModifySelection:", "⌥⇧→"),
            ("Extend Selection to Beginning of Line", "moveToBeginningOfLineAndModifySelection:", "⇧⌘←"),
            ("Extend Selection to End of Line", "moveToEndOfLineAndModifySelection:", "⇧⌘→"),
            ("Extend Selection to Beginning of Document", "moveToBeginningOfDocumentAndModifySelection:", "⇧⌘↑"),
            ("Extend Selection to End of Document", "moveToEndOfDocumentAndModifySelection:", "⇧⌘↓"),
            ("Scroll Page Up", "scrollPageUp:", "Page Up"), ("Scroll Page Down", "scrollPageDown:", "Page Down"),
            ("Extend Selection One Page Up", "pageUpAndModifySelection:", "⇧Page Up"),
            ("Extend Selection One Page Down", "pageDownAndModifySelection:", "⇧Page Down"),
            ("Scroll to Beginning of Document", "scrollToBeginningOfDocument:", "Home"),
            ("Scroll to End of Document", "scrollToEndOfDocument:", "End")
        ]
        return nativeActions.map { title, selector, shortcut in
            let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: "")
            item.target = document.editor
            return ControlCommand(id: selector, title: title, item: item, documentOnly: true, displayedShortcut: shortcut)
        }
    }

    static func searchCommands(for app: Edit) -> [ControlCommand] {
        let labels: [(FindCommand, String)] = [
            (.refresh, "Refresh Search"), (.toggleReplace, "Toggle Replace Section"),
            (.toggleCase, "Toggle Match Case"), (.toggleWholeWord, "Toggle Match Whole Word"),
            (.toggleRegex, "Toggle Regular Expression"), (.replaceAll, "Replace All"),
            (.replaceSelected, "Replace Selected Match"), (.dismissSelected, "Dismiss Selected Match"),
            (.clearSelection, "Clear Search Result Selection")
        ]
        return labels.map { action, title in
            let item = NSMenuItem(title: title, action: #selector(Edit.performFindControlAction(_:)), keyEquivalent: "")
            item.target = app
            item.representedObject = action
            return ControlCommand(id: "find.\(action)", title: title, item: item)
        }
    }

    static func markdownTableCommands(for document: DocumentWindow) -> [ControlCommand] {
        MarkdownTableCommand.allCases.map { command in
            let title = "Markdown: \(command.title.lowercased())"
            let item = NSMenuItem(title: title, action: #selector(DocumentWindow.performMarkdownTableCommand(_:)), keyEquivalent: "")
            item.target = document
            item.representedObject = command
            return ControlCommand(id: "markdown.table.\(command.rawValue)", title: title, item: item)
        }
    }

    static func terminalCommands(for document: DocumentWindow) -> [ControlCommand] {
        let splits: [(TerminalSplitDirection, String, String)] = [
            (.right, "terminal.split-right", "Split Terminal Right"),
            (.down, "terminal.split-down", "Split Terminal Down"),
        ]
        return splits.map { direction, id, title in
            let item = NSMenuItem(title: title, action: #selector(DocumentWindow.splitTerminalFromControl(_:)), keyEquivalent: "")
            item.target = document
            item.representedObject = direction
            return ControlCommand(id: id, title: title, item: item)
        }
    }

    static func languageServerCommands(for document: DocumentWindow) -> [ControlCommand] {
        LanguageServerCommand.allCases.map { command in
            let item = NSMenuItem(title: command.title, action: #selector(DocumentLanguageFeatures.performControlCommand(_:)), keyEquivalent: "")
            item.target = document.languageFeatures
            item.representedObject = command.rawValue
            return ControlCommand(id: "lsp.\(command.rawValue)", title: command.title, item: item)
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
            let title = action == #selector(Edit.goBack(_:)) || action == #selector(Edit.goForward(_:))
                || action == #selector(Edit.toggleMarkdownPreview(_:))
                || action == #selector(Edit.toggleLSPHighlight(_:))
                ? item.title : "\(prefix): \(item.title)"
            return [ControlCommand(id: NSStringFromSelector(action), title: title, item: item,
                                   documentOnly: isBracketCommand(action) || isCaseCommand(action))]
        }
    }

    private static func isBracketCommand(_ action: Selector) -> Bool {
        action == #selector(EditorTextView.goToBracket(_:)) || action == #selector(EditorTextView.selectToBracket(_:))
    }

    private static func isCaseCommand(_ action: Selector) -> Bool {
        action == #selector(EditorTextView.uppercaseWord(_:)) || action == #selector(EditorTextView.lowercaseWord(_:))
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
