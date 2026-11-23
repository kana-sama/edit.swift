import AppKit
import Darwin
import SwiftTerm

@MainActor
enum TerminalCheck {
    private static let titleControls = ["Edit.Terminal.Spaces", "Edit.Terminal.NewSpace", "Edit.Terminal.DeleteSpace",
                                        "Edit.Terminal.SplitRight", "Edit.Terminal.SplitDown", "Edit.Terminal.Options"]

    static func run(in app: Edit) async throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        var roomyFrame = window.frame
        roomyFrame.size.width = 1024
        window.setFrame(roomyFrame, display: false)
        try checkToolbar(in: window)
        try checkTranscriptStyleBounds()

        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
            try require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code),
                        "create a keyboard event")
        }

        let toggle = try key("ё", .control, code: TerminalShortcuts.toggleKeyCode)
        let buffer = document.scrollView.superview
        try expect(document.handleTerminalKey(toggle) && document.isTerminalVisible, "reveal the terminal by physical key")
        let terminal = try require(window.firstResponder as? LocalProcessTerminalView, "focus the first terminal")
        let panel = try require(view("Edit.Terminal.Panel", in: window.contentView), "find the native panel")
        let options = try require(view("Edit.Terminal.Options", in: panel) as? NSButton, "find terminal options")
        let controller = try require(options.target as? TerminalPanel, "connect native options")
        let editorFrame = windowPosition(of: document.scrollView)
        let panelFrame = windowPosition(of: panel)
        try expect(abs(panelFrame.minY - editorFrame.minY) < 1 && panelFrame.maxY < editorFrame.maxY,
                   "dock over the bottom of the buffer")
        try checkBottomGlass(in: document, panel: panel)
        try expect(terminal.backgroundOpacity == 0, "show glass through the terminal's default background")
        try await checkShell(in: terminal)
        try await checkScrollAndClear(in: document, terminal: terminal,
                                     widthKey: key("Ω", .option, code: 6), clearKey: key("k", .command, code: 40))

        let split = ControlCommand.terminalCommands(for: document)
        try expect(split.count == 2 && split.allSatisfy { $0.isAvailable(in: document, focus: terminal) },
                   "offer both Control splits from a terminal")
        let control = ControlPanel(app: app)
        try control.checkTerminalCommands(in: document, expected: true)
        document.focusContent()
        try expect(split.allSatisfy { !$0.isAvailable(in: document, focus: window.firstResponder) },
                   "hide terminal splits from the buffer")
        try control.checkTerminalCommands(in: document, expected: false)
        try expect(document.handleTerminalKey(toggle) && window.firstResponder === terminal && document.isTerminalVisible,
                   "focus the visible terminal from the editor")
        try expect(document.handleTerminalKey(toggle) && !document.isTerminalVisible && window.firstResponder === document.editor,
                   "hide the terminal from its focused pane")
        try expect(document.scrollView.superview === buffer, "restore the standalone editor layout")
        try expect(document.handleTerminalKey(toggle) && window.firstResponder === terminal,
                   "recover the same terminal when reopening")

        let splitRight = try require(view("Edit.Terminal.SplitRight", in: panel) as? NSButton, "find the split-right button")
        try expect(splitRight.isEnabled && splitRight.image != nil &&
                   NSApp.sendAction(try require(splitRight.action, "connect the split-right button"),
                                    to: splitRight.target, from: splitRight), "split from the bottom panel header")
        let right = try require(window.firstResponder as? LocalProcessTerminalView, "focus the new split")
        try expect(right !== terminal && windowPosition(of: terminal).maxX < windowPosition(of: right).minX,
                   "split to the right")
        try expect(dockAction(.right, in: controller) && window.firstResponder === right, "dock right before splitting down")
        let dockedHeader = try rightHeader(in: window)
        let splitDown = try require(view("Edit.Terminal.SplitDown", in: dockedHeader) as? NSButton, "find the split-down button")
        try expect(splitDown.isEnabled && splitDown.image != nil &&
                   NSApp.sendAction(try require(splitDown.action, "connect the split-down button"),
                                    to: splitDown.target, from: splitDown), "split from the right sidebar header")
        let below = try require(window.firstResponder as? LocalProcessTerminalView, "focus the lower split")
        try expect(below !== right && windowPosition(of: below).maxY < windowPosition(of: right).minY,
                   "nest a split below its source")
        try expect(dockAction(.below, in: controller) && window.firstResponder === below,
                   "keep the new pane focused when docking below")
        let outer = try require(view("Edit.Terminal.Split", in: panel) as? NSSplitView, "find the left and right split")
        let inner = try require(view("Edit.Terminal.Split", in: outer.arrangedSubviews[1]) as? NSSplitView,
                                "find the nested top and bottom split")
        try checkSharedDivider(outer)
        try checkSharedDivider(inner)
        try checkFocusOutline(in: document, terminals: [terminal, right, below])

        let increase = try key("+", [.command, .shift], code: 24)
        let reset = try key("0", .command, code: 29)
        try expect(document.handleTerminalKey(increase) && below.font.pointSize == 13 && right.font.pointSize == 12,
                   "zoom the focused pane only")
        try expect(document.handleTerminalKey(reset) && below.font.pointSize == 12, "reset terminal zoom")
        let context = try contextMenu(for: below)
        try expect(context.item(withTitle: "Copy")?.target === below && context.item(withTitle: "Paste")?.target === below,
                   "route clipboard actions to the clicked terminal")
        try expect(menuAction("Wrap Lines", in: context) &&
                   contextMenu(for: below).item(withTitle: "Wrap Lines")?.state == .off,
                   "toggle wrapping in the clicked pane")
        try expect(contextMenu(for: right).item(withTitle: "Wrap Lines")?.state == .on && window.firstResponder === right,
                   "keep wrapping enabled after right-clicking another pane")

        try expect(dockAction(.right, in: controller) && window.firstResponder === right,
                   "preserve terminal focus when moving the split layout to the right")
        _ = try checkRightSidebar(in: document, panel: panel)
        let header = try rightHeader(in: window)
        let add = try require(view("Edit.Terminal.NewSpace", in: header) as? NSButton, "find the add-space button")
        let delete = try require(view("Edit.Terminal.DeleteSpace", in: header) as? NSButton, "find the delete-space button")
        try expect(delete.isEnabled && abs(windowPosition(of: delete).minX - windowPosition(of: add).maxX - 2) < 1,
                   "place the delete-space button directly beside the add-space button")
        try expect(NSApp.sendAction(try require(add.action, "connect add-space action"), to: add.target, from: add),
                   "create a second space")
        try expect(window.firstResponder !== right, "focus the shell in the new space")
        let spaces = try require(view("Edit.Terminal.Spaces", in: header) as? NSPopUpButton, "find the space picker")
        try expect(spaces.numberOfItems == 2, "keep the two spaces independently selectable")
        spaces.selectItem(at: 0)
        try expect(NSApp.sendAction(try require(spaces.action, "connect space picker"), to: spaces.target, from: spaces) &&
                   window.firstResponder === right && terminal.window === window,
                   "restore the first space's layout and last terminal")
        document.performFind(.toggleSidebar)
        let sidebarSplit = try checkRightSidebar(in: document, panel: panel)
        try checkToolbar(in: window)
        let sidebarItem = try require(sidebarSplit.splitViewItems.first, "find the leading sidebar")
        let sidebar = sidebarItem.viewController.view
        try expect(sidebarSplit.splitViewItems.count == 3 && sidebarItem.behavior == .sidebar && sidebar.bounds.width > 0 &&
                   windowPosition(of: sidebar).maxX < windowPosition(of: panel).minX && document.isTerminalVisible,
                   "keep the right-docked terminal beside the native left sidebar")
        try checkLeftHeader(in: window, sidebar: sidebar)
        try checkLeftHeaderAfterFullScreen(in: document, sidebar: sidebar)
        try checkRightSidebarFullScreenRoundTrip(in: document, panel: panel, leftSidebar: sidebar)
        try expect(dockAction(.below, in: controller), "dock below with a sidebar open")
        try checkBottomGlass(in: document, panel: panel)
        try expect(view("Edit.Terminal.Spaces", in: panel) === spaces &&
                   window.toolbar?.items.allSatisfy { !DocumentTitleBar.terminalItemIdentifiers.contains($0.itemIdentifier) } == true &&
                   sidebar.bounds.width > 0 &&
                   windowPosition(of: spaces).minX >= windowPosition(of: sidebar).maxX - 1,
                   "move the same terminal header below the editor")
        try checkBottomHeight(in: app)
        try checkBottomUnderlay(in: app)
        try await checkRestoration(in: app, visible: document, controller: controller, pane: right)
        try await checkShellExit(in: app)
        try await checkSpaceNamesAndContextActions(in: app)
        try checkImmediateTerminalToggles(in: app)
        try checkDockPicker(in: app)
        try checkDetachedTerminalHeader(in: app)
        try expect(!NSApp.isActive && !window.isVisible, "keep the entire terminal check in the background")
    }

    private static func checkSpaceNamesAndContextActions(in app: Edit) async throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Terminal names \(UUID())", directoryHint: .isDirectory)
        let project = folder.appending(path: "Terminal Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        document.showTerminal()
        let panel = try require(view("Edit.Terminal.Panel", in: window.contentView), "find the named spaces panel")
        var terminal: LocalProcessTerminalView! = try require(window.firstResponder as? LocalProcessTerminalView,
                                                              "focus the first named terminal")
        let picker = try require(view("Edit.Terminal.Spaces", in: panel) as? NSPopUpButton, "find the named spaces picker")
        let add = try require(view("Edit.Terminal.NewSpace", in: panel) as? NSButton, "find the new-space control")
        let initial = try require(picker.titleOfSelectedItem, "show the initial shell folder")
        try expect(NSApp.sendAction(try require(add.action, "connect the new-space control"), to: add.target, from: add) &&
                   picker.itemTitles == [initial, initial], "keep two spaces with the same folder name")
        let duplicate = try require(window.firstResponder as? LocalProcessTerminalView, "focus the duplicate named space")
        try expect(duplicate !== terminal && menuAction("Kill Terminal", in: contextMenu(for: duplicate)) &&
                   duplicate.window == nil && window.firstResponder === terminal && picker.numberOfItems == 1,
                   "kill only the clicked terminal and return to the other space")

        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--norc", "-i"],
                              environment: ["HOME=\(folder.path)", "PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=EditPrompt> "],
                              currentDirectory: folder.path)
        defer { terminal?.terminate() }
        try await waitFor("name the idle shell space after its actual folder") {
            picker.titleOfSelectedItem == folder.lastPathComponent && containsText("EditPrompt>", in: terminal)
        }
        terminal.send(txt: "cd 'Terminal Project'\r")
        try await waitFor("rename a shell space on cd without a shell hook") { picker.titleOfSelectedItem == project.lastPathComponent }
        terminal.send(txt: "/bin/sleep 30\r")
        try await waitFor("name the space after its foreground app") { picker.titleOfSelectedItem == "sleep" }
        try expect(document.sessionDocument().terminal?.panel.spaces.first?.name == "sleep", "save the live space title with its history")
        terminal.send(txt: "\u{3}")
        try await waitFor("return to the shell folder title after the foreground app exits") { picker.titleOfSelectedItem == project.lastPathComponent }

        terminal.send(txt: "echo ContextClearMarker\r")
        try await waitFor("populate the context menu test terminal") { containsText("ContextClearMarker", in: terminal) }
        terminal.selectAll(nil)
        let menu = try contextMenu(for: terminal)
        try expect(menu.item(withTitle: "Copy")?.isEnabled == true && menu.item(withTitle: "Paste")?.target === terminal,
                   "offer copy of the selection and paste into the clicked pane")
        try expect(menuAction("Clear Terminal", in: menu), "clear output through the context menu")
        try await waitFor("clear the clicked pane while its shell keeps running") {
            terminal.process.running && !containsText("ContextClearMarker", in: terminal)
        }
        try expect(menuAction("Split Terminal Right", in: menu), "split the clicked pane to the right")
        let right = try require(window.firstResponder as? LocalProcessTerminalView, "focus the right split from the menu")
        try expect(right !== terminal && windowPosition(of: terminal).maxX < windowPosition(of: right).minX,
                   "place the newly focused pane to the right of the clicked pane")

        let splitMenu = try contextMenu(for: terminal)
        try expect(window.makeFirstResponder(right) && menuAction("Split Terminal Down", in: splitMenu),
                   "split the clicked pane even if another terminal has focus")
        let below = try require(window.firstResponder as? LocalProcessTerminalView, "focus the bottom split from the menu")
        try expect(below !== terminal && below !== right &&
                   windowPosition(of: below).maxY < windowPosition(of: terminal).minY &&
                   windowPosition(of: below).maxX < windowPosition(of: right).minX &&
                   picker.numberOfItems == 1 && terminal.process.running,
                   "place the new pane below the clicked terminal and keep its space and shell")
        try expect(menuAction("Kill Terminal", in: contextMenu(for: below)) &&
                   menuAction("Kill Terminal", in: contextMenu(for: right)) && window.firstResponder === terminal,
                   "close both added splits and return to the original terminal")

        let shellPID = terminal.process.shellPid
        try expect(shellPID > 0 && menuAction("Kill Terminal", in: contextMenu(for: terminal)),
                   "kill the clicked pane through the context menu")
        try expect(!document.isTerminalVisible && terminal.window == nil, "close the empty panel after killing its terminal")
        terminal = nil
        try await waitFor("stop the clicked pane's process and close the empty panel") {
            kill(shellPID, 0) == -1 && errno == ESRCH
        }
    }

    private static func checkImmediateTerminalToggles(in app: Edit) throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1024, height: 620), display: false)
        window.orderBack(nil)
        try expect(window.isVisible && window.alphaValue == 0 && !NSApp.isActive,
                   "exercise terminal visibility in a transparent ordered window")
        try expect(window.acceptsMouseMovedEvents, "enable mouse movement before attaching terminal views")
        document.performFind(.toggleSidebar)
        document.showTerminal()
        let panel = try require(view("Edit.Terminal.Panel", in: window.contentView), "find the terminal panel")
        let terminal = try require(window.firstResponder as? LocalProcessTerminalView, "focus the terminal")
        terminal.linkHighlightMode = .hover
        terminal.linkHighlightMode = .hoverWithModifier
        try expect(window.acceptsMouseMovedEvents, "keep hover delivery after the terminal stops tracking links")
        let options = try require(view("Edit.Terminal.Options", in: panel) as? NSButton, "find the terminal dock options")
        let controller = try require(options.target as? TerminalPanel, "find the terminal controller")
        let frame = window.frame

        for dock in [TerminalDock.below, .right] {
            if dock == .right {
                try expect(dockAction(.right, in: controller), "dock the terminal on the right")
                try checkTitleButtonHover(in: window)
            }
            let settledPanel = windowPosition(of: panel)
            let coveredHeight = document.scrollView.contentInsets.bottom
            for _ in 0..<3 {
                document.toggleTerminal()
                try expect(!document.isTerminalVisible && panel.window == nil && window.firstResponder === document.editor &&
                           document.scrollView.contentInsets.bottom == 0 && window.frame == frame,
                           "hide the terminal and restore the editor in the same call")
                try expect(window.toolbar?.items.allSatisfy {
                    !DocumentTitleBar.terminalItemIdentifiers.contains($0.itemIdentifier)
                } == true, "remove the right toolbar section in the same call")
                document.showTerminal()
                try expect(document.isTerminalVisible && panel.window === window && window.firstResponder === terminal &&
                           windowPosition(of: panel) == settledPanel && window.frame == frame &&
                           document.scrollView.contentInsets.bottom == coveredHeight,
                           "show the same terminal at its remembered size and restore focus in the same call")
                if dock == .right {
                    let header = try rightHeader(in: window)
                    try expect(!header.isHiddenOrHasHiddenAncestor &&
                               header.superview?.layer?.animation(forKey: #keyPath(CALayer.transform)) == nil &&
                               header.superview?.layer?.animation(forKey: #keyPath(CALayer.opacity)) == nil,
                               "attach the right header immediately at its normal geometry")
                }
            }
        }
    }

    private static func checkTitleButtonHover(in window: NSWindow) throws {
        let header = try rightHeader(in: window)
        var cursorImages: [NSCursor] = []
        let tracking = EditApplication.ClickCursorTracking(currentCursor: { cursorImages.last ?? .iBeam },
                                                            setCursor: { cursorImages.append($0) })
        defer { tracking.end() }
        for identifier in ["Edit.Terminal.SplitDown", "Edit.Terminal.SplitRight"] {
            let button = try require(view(identifier, in: header) as? NSButton, "find a native titlebar button")
            let frame = windowPosition(of: button)
            for x in [frame.minX + 2, frame.midX, frame.maxX - 2] {
                let location = NSPoint(x: x, y: frame.midY)
                let screenPoint = window.convertPoint(toScreen: location)
                let hover = try require(NSEvent.mouseEvent(with: .mouseMoved, location: screenPoint, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 0, pressure: 0),
                    "create a hover event with no window")
                let target = EditApplication.cursorWindow(for: hover, at: screenPoint) { point in
                    point == screenPoint ? window : nil
                }
                try expect(hover.window == nil && target === window, "resolve windowless hover over the titlebar")
                var nativeRectsEnabled = true
                tracking.dispatch(hover.type, in: window, resolve: {
                    EditApplication.clickCursor(in: window, at: location)
                }) {
                    nativeRectsEnabled = window.areCursorRectsEnabled
                }
                try expect(!nativeRectsEnabled && cursorImages == [.pointingHand],
                           "show one pointing hand on first hover and keep it across titlebar buttons")
            }
        }
    }

    private static func checkDockPicker(in app: Edit) throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        let display = try require(NSScreen.main?.visibleFrame, "find the display for the dock picker")
        window.setFrame(NSRect(x: display.maxX - 1024, y: display.maxY - 620, width: 1024, height: 620), display: false)
        window.orderBack(nil)
        document.showTerminal()
        let terminal = try require(window.firstResponder as? LocalProcessTerminalView, "focus the terminal before picking its dock")
        let body = try require(view("Edit.Terminal.Panel", in: window.contentView), "find the terminal panel")
        let pickerID = "Edit.Terminal.DockPicker"

        for dock in [TerminalDock.below, .right] {
            window.layoutIfNeeded()
            let header = dock == .right ? try rightHeader(in: window) : body
            let options = try require(view("Edit.Terminal.Options", in: header) as? NSButton, "find the dock picker button")
            let action = try require(options.action, "connect the dock picker button")
            try expect(NSApp.sendAction(action, to: options.target, from: options), "open the dock picker from the header")
            let popup = try require(window.childWindows?.first { $0.contentView?.identifier?.rawValue == pickerID },
                                    "show the dock picker as a child of the editor")
            let surface = try require(popup.contentView as? NSVisualEffectView, "draw the dock picker on a popover surface")
            let anchorWindow = try require(options.window, "find the window containing the ellipsis")
            let anchor = anchorWindow.convertToScreen(options.convert(options.bounds, to: nil))
            let shape = TerminalDockPopoverLayout(anchor: anchor,
                                                 size: NSSize(width: 224, height: 100), screen: display,
                                                 preferAbove: dock == .below)
            let outline = shape.outline()
            let tipY = dock == .below ? 1 : shape.frame.height - 1
            try expect(popup.alphaValue == 0 && popup.ignoresMouseEvents && !NSApp.isActive,
                       "keep the dock picker test quiet")
            try expect(surface.maskImage != nil, "mask the popover surface to the outline")
            try expect(dock == .below ? popup.frame.minY > anchor.maxY : popup.frame.maxY < anchor.minY,
                       "open the picker on the appropriate side of the ellipsis (\(dock), \(popup.frame), \(anchor))")
            try expect(popup.frame.maxX <= display.maxX && abs(shape.frame.minX + shape.pointerX - anchor.midX) < 0.5 &&
                       outline.contains(CGPoint(x: shape.pointerX, y: tipY)) &&
                       !outline.contains(CGPoint(x: shape.frame.width - 1, y: tipY)),
                       "point at the ellipsis without filling in the rounded corner (\(dock), \(outline.boundingBoxOfPath), \(shape.pointerX), \(tipY))")

            let selectedID = dock == .below ? "Edit.Terminal.DockBelow" : "Edit.Terminal.DockRight"
            let otherID = dock == .below ? "Edit.Terminal.DockRight" : "Edit.Terminal.DockBelow"
            let selected = try require(view(selectedID, in: surface) as? NSButton, "find the selected dock")
            let other = try require(view(otherID, in: surface) as? NSButton, "find the other dock")
            try expect(selected.state == .on && popup.firstResponder === selected && other.state == .off,
                       "focus and outline the selected miniature")
            try expect(NSApp.sendAction(action, to: options.target, from: options) && popup.parent == nil && !popup.isVisible,
                       "dismiss the picker when the ellipsis is pressed again")
            try expect(NSApp.sendAction(action, to: options.target, from: options), "reopen the dock picker")
            let reopened = try require(window.childWindows?.first { $0.contentView?.identifier?.rawValue == pickerID },
                                       "find the reopened dock picker")
            let choice = try require(view(otherID, in: reopened.contentView) as? NSButton, "find the other dock after reopening")
            let choose = try require(choice.action, "connect the other dock choice")
            try expect(NSApp.sendAction(choose, to: choice.target, from: choice) && !reopened.isVisible &&
                       terminal.window === window && window.firstResponder === terminal,
                       "move the live terminal and return focus to it after choosing a dock")
        }
    }

    private static func checkDetachedTerminalHeader(in app: Edit) throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        document.showTerminal()
        let options = try require(view("Edit.Terminal.Options", in: window.contentView) as? NSButton,
                                  "find the terminal dock options")
        let panel = try require(options.target as? TerminalPanel, "find the terminal controller")
        try expect(dockAction(.right, in: panel), "prepare the right panel's toolbar item")
        let toolbar = try require(window.toolbar, "find the document toolbar")
        // Keep the real item in a separate window, as AppKit can do in full screen.
        let frame = NSRect(x: -10_000, y: -10_000, width: 1024, height: 180)
        let companion = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        companion.isReleasedWhenClosed = false
        companion.alphaValue = 0
        companion.ignoresMouseEvents = true
        companion.collectionBehavior = [.fullScreenAuxiliary]
        companion.toolbarStyle = window.toolbarStyle
        window.toolbar = nil
        companion.toolbar = toolbar
        defer {
            companion.toolbar = nil
            window.toolbar = toolbar
            companion.close()
        }
        companion.orderBack(nil)
        companion.setFrame(frame, display: false)
        companion.layoutIfNeeded()
        try expect(companion.isVisible && !NSApp.isActive && document.titleBar.toolbarWindow === companion,
                   "host the toolbar in a transparent, inactive companion window")
        let header = try rightHeader(in: companion)
        try expect(header.window === companion, "attach the right header to the companion window")
        let headerFrame = windowPosition(of: header)
        document.titleBar.setTerminalTitleVisible(false, in: toolbar)
        try expect(header.isHidden && !toolbar.items.contains { $0.itemIdentifier == DocumentTitleBar.terminalItemIdentifier },
                   "remove the native title immediately from the companion window")
        document.titleBar.setTerminalTitleVisible(true, in: toolbar)
        let restored = try rightHeader(in: companion)
        try expect(restored === header && !restored.isHiddenOrHasHiddenAncestor && windowPosition(of: restored) == headerFrame &&
                   restored.superview?.layer?.animation(forKey: #keyPath(CALayer.transform)) == nil &&
                   restored.superview?.layer?.animation(forKey: #keyPath(CALayer.opacity)) == nil,
                   "restore the full-size native title immediately in the companion window")
    }

    private static func checkFocusOutline(in document: DocumentWindow,
                                          terminals: [LocalProcessTerminalView]) throws {
        let window = document.window
        window.layoutIfNeeded()
        let panes = try terminals.map {
            try require($0.enclosingScrollView?.superview, "find the pane surrounding the terminal viewport")
        }
        let frames = terminals.map { windowPosition(of: $0) }
        let grids = terminals.map { $0.terminalInputStateSnapshot()?.dimensions }

        func edgeColor(of pane: NSView, leading: Bool) throws -> NSColor {
            let bounds = pane.bounds
            let bitmap = try require(pane.bitmapImageRepForCachingDisplay(in: bounds), "capture a terminal pane")
            pane.cacheDisplay(in: bounds, to: bitmap)
            let offset = Int(0.5 * CGFloat(bitmap.pixelsWide) / bounds.width)
            let x = leading ? offset : bitmap.pixelsWide - offset - 1
            return try require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB),
                               "read the terminal's outer border")
        }

        document.focusContent()
        let resting = try panes.enumerated().map { try edgeColor(of: $0.element, leading: $0.offset == 0) }
        try expect(resting.allSatisfy {
            let brightest = max($0.redComponent, $0.greenComponent, $0.blueComponent)
            let darkest = min($0.redComponent, $0.greenComponent, $0.blueComponent)
            return $0.alphaComponent > 0.02 && brightest - darkest < 0.1
        }, "paint a visible gray border before any terminal takes focus")

        func check(_ focused: Int?) throws {
            window.layoutIfNeeded()
            for (index, pane) in panes.enumerated() {
                let color = try edgeColor(of: pane, leading: index == 0)
                let gray = resting[index]
                let difference = abs(color.alphaComponent - gray.alphaComponent) +
                    abs(color.redComponent - gray.redComponent) + abs(color.greenComponent - gray.greenComponent) +
                    abs(color.blueComponent - gray.blueComponent)
                try expect(index == focused ? difference > 0.1 : difference < 0.05,
                           "accent only the focused pane and keep the other borders gray")
            }
            try expect(terminals.map { windowPosition(of: $0) } == frames &&
                       terminals.map { $0.terminalInputStateSnapshot()?.dimensions } == grids,
                       "keep terminal positions and grid sizes fixed while changing focus")
        }

        for (index, terminal) in terminals.enumerated() {
            try expect(window.makeFirstResponder(terminal), "focus a split terminal")
            try check(index)
        }
        document.focusContent()
        try check(nil)
        try expect(window.makeFirstResponder(terminals.last), "return focus to the lower split")
    }

    private static func checkSharedDivider(_ split: NSSplitView) throws {
        let first = split.arrangedSubviews[0].frame
        let second = split.arrangedSubviews[1].frame
        let drawn = split.isVertical
            ? NSRect(x: first.maxX, y: split.bounds.minY, width: second.minX - first.maxX, height: split.bounds.height)
            : NSRect(x: split.bounds.minX, y: first.maxY, width: split.bounds.width, height: second.minY - first.maxY)
        let width = split.isVertical ? drawn.width : drawn.height
        try expect(abs(width - 1) < 0.5 && split.dividerThickness == 1, "give adjacent panes one shared one-point edge")
        let effective = split.delegate?.splitView?(split, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0) ?? drawn
        try expect(effective.contains(NSPoint(x: drawn.midX, y: drawn.midY)), "resize panes at their shared edge")
    }

    private static func checkBottomGlass(in document: DocumentWindow, panel: NSView) throws {
        document.window.layoutIfNeeded()
        let dock = try bottomDock(in: document)
        let holder = try require(dock.arrangedSubviews.last, "find the bottom dock's holder")
        let glass = try require(holder.subviews.first { $0 is NSGlassEffectView } as? NSGlassEffectView,
                                "find the dock's glass background")
        let holderFrame = windowPosition(of: holder)
        let glassFrame = windowPosition(of: glass)
        try expect(glass.style == .regular && glass.cornerRadius == 0 && holder.clipsToBounds &&
                   glassFrame.minX < holderFrame.minX && glassFrame.minY < holderFrame.minY &&
                   glassFrame.maxX > holderFrame.maxX && glassFrame.maxY > holderFrame.maxY &&
                   panel.superview === holder && panel.frame == holder.bounds,
                   "fill the bottom dock with glass (panel \(panel.frame), holder \(holder.bounds), glass \(glassFrame))")
        try checkPaneRegion(in: panel)
    }

    private static func bottomDock(in document: DocumentWindow) throws -> TerminalDockView {
        try require(view("Edit.Terminal.Dock", in: document.editorContentView) as? TerminalDockView, "find the bottom dock")
    }

    private static func checkBottomHeight(in app: Edit) throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }

        func resizeWindow(to height: CGFloat) {
            var frame = window.frame
            frame.size.height = height
            window.setFrame(frame, display: false)
            window.layoutIfNeeded()
        }

        resizeWindow(to: 620)
        document.showTerminal()
        let dock = try bottomDock(in: document)
        let buffer = try require(dock.arrangedSubviews.first, "find space above the bottom dock")
        let holder = try require(dock.arrangedSubviews.last, "find the bottom pane")
        let height: CGFloat = 300
        dock.setPosition(dock.bounds.height - dock.dividerThickness - height, ofDividerAt: 0)
        try expect(abs(holder.frame.height - height) < 1 && abs(dock.savedHeight - height) < 1,
                   "remember the divider's chosen terminal height")
        for windowHeight in [CGFloat(740), 515] {
            resizeWindow(to: windowHeight)
            try expect(abs(holder.frame.height - height) < 1, "keep the terminal height when both panes fit")
        }

        resizeWindow(to: 360)
        try expect(holder.frame.height < height && buffer.frame.height >= 109,
                   "compress the terminal to leave room for the buffer")
        try expect(document.sessionDocument().terminal?.sizes.belowHeight == height,
                   "save the chosen height while the terminal is compressed")
        document.toggleTerminal()
        document.showTerminal()
        try expect(holder.frame.height < height, "reopen the compressed terminal in the small window")
        resizeWindow(to: 620)
        try expect(abs(holder.frame.height - height) < 1, "restore the chosen height once both panes fit again")
    }

    private static func checkBottomUnderlay(in app: Edit) throws {
        let document = app.makeDocument()
        let window = document.window
        let scroll = document.scrollView
        let editor = document.editor
        defer { window.close() }
        var frame = window.frame
        frame.size = NSSize(width: 1024, height: 620)
        window.setFrame(frame, display: false)
        let line = String(repeating: "Window text ", count: 22) + "\n"
        editor.string = String(repeating: line, count: 70)
        document.performFind(.toggleSidebar)
        document.showTerminal()
        document.focusContent()
        window.layoutIfNeeded()

        let split = try require(window.contentViewController as? NSSplitViewController, "find the sidebar split")
        let sidebar = try require(split.splitViewItems.first?.viewController.view, "find the leading sidebar")
        let dock = try bottomDock(in: document)
        let holder = try require(dock.arrangedSubviews.last, "find the bottom glass panel")
        let sidebarFrame = windowPosition(of: sidebar)
        let panelFrame = windowPosition(of: holder)
        let clipFrame = windowPosition(of: scroll.contentView)
        try expect(abs(panelFrame.minX - sidebarFrame.maxX) < 2,
                   "stop the bottom panel at the sidebar edge (\(panelFrame), sidebar \(sidebarFrame))")
        try expect(clipFrame.minX <= sidebarFrame.minX + 1 && clipFrame.minY <= panelFrame.minY + 1 &&
                   abs(scroll.contentInsets.bottom - dock.coveredHeight) < 2,
                   "extend the clip behind both panels and inset scrolling above the terminal (clip \(clipFrame), bottom inset \(scroll.contentInsets.bottom), coverage \(dock.coveredHeight))")

        let openArea = NSPoint(x: dock.bounds.midX, y: 100)
        let hostPoint = dock.convert(openArea, to: document.editorContentView)
        try expect(dock.hitTest(hostPoint) == nil, "pass clicks above the divider to the editor")

        scroll.scrollToVisibleContentOrigin(NSPoint(x: 140, y: 0))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        func glyphFrame(_ range: NSRange) -> NSRect {
            window.convertFromScreen(editor.firstRect(forCharacterRange: range, actualRange: nil))
        }
        let stride = line.utf16.count
        let behindSidebar = glyphFrame(NSRange(location: stride * 3 + 4, length: 1))
        try expect(behindSidebar.height > 0 && sidebarFrame.contains(behindSidebar) && clipFrame.contains(behindSidebar),
                   "scroll editor text underneath the sidebar")
        let lowerGlyph = try require((16..<40).map { NSRange(location: stride * $0 + 30, length: 1) }.first {
            let glyph = glyphFrame($0)
            return glyph.height > 0 && panelFrame.contains(glyph) && clipFrame.contains(glyph)
        }, "lay out editor text underneath the terminal")
        editor.scrollRangeToVisible(lowerGlyph)
        try expect(glyphFrame(lowerGlyph).minY >= panelFrame.maxY - 1,
                   "reveal a glyph above the terminal when navigating to it")
    }

    private static func checkPaneRegion(in panel: NSView) throws {
        let region = try require(view("Edit.Terminal.Content", in: panel), "find the pane region")
        let frame = windowPosition(of: region)
        let safeFrame = panel.convert(panel.safeAreaRect, to: nil)
        try expect(abs(frame.minX - safeFrame.minX) < 0.5 && abs(frame.maxX - safeFrame.maxX) < 0.5 &&
                   abs(frame.minY - windowPosition(of: panel).minY) < 0.5,
                   "extend the pane region to the available sides and bottom")
        let layout = try require(region.subviews.first, "find the pane layout")
        try expect(layout.frame == region.bounds, "place the outside borders flush with the pane region")
    }

    private static func rightHeader(in window: NSWindow) throws -> NSView {
        let items = window.toolbar?.items ?? []
        let headers = items.filter { $0.itemIdentifier == DocumentTitleBar.terminalItemIdentifier }
        try expect(headers.count == 1, "attach one terminal header to the toolbar")
        return try require(headers[0].view, "find the terminal toolbar controls")
    }

    private static func checkLeftHeader(in window: NSWindow, sidebar: NSView) throws {
        let toolbar = try require(window.toolbar, "find the toolbar with both sidebars")
        let title = try require(toolbar.items.first { $0.itemIdentifier.rawValue == "Edit.SidebarTitle" } as? SidebarMenuItem,
                                "find the left sidebar title item")
        let picker = try require(title.modePicker, "find the left sidebar picker")
        let options = try require(title.options?.view, "find the left sidebar options")
        let sidebarFrame = windowPosition(of: sidebar)
        for control in [picker, options] {
            let frame = windowPosition(of: control)
            try expect(control.window === window && !control.isHiddenOrHasHiddenAncestor &&
                       control.visibleRect.contains(control.bounds) && frame.minX >= sidebarFrame.minX &&
                       frame.maxX <= sidebarFrame.maxX + 1,
                       "keep the left sidebar controls visible in its title bar (control \(frame), visible \(control.visibleRect), sidebar \(sidebarFrame))")
        }
        let optionsInset = sidebarFrame.maxX - windowPosition(of: options).maxX
        try expect(abs(optionsInset - 10) <= 0.5,
                   "pin the left sidebar options to the divider inset (got \(optionsInset) pt)")
        let visible = Set(toolbar.visibleItems?.map(\.itemIdentifier) ?? [])
        let expected = toolbar.items.filter { !$0.isHidden && $0.view != nil }.map(\.itemIdentifier)
        try expect(expected.allSatisfy { visible.contains($0) }, "fit the toolbar without an overflow button in a roomy window")
    }

    private static func checkLeftHeaderAfterFullScreen(in document: DocumentWindow, sidebar: NSView) throws {
        let window = document.window
        let toolbar = try require(window.toolbar, "find the toolbar during the full-screen transition")
        let item = try require(toolbar.items.compactMap { $0 as? SidebarMenuItem }.first,
                               "find the leading toolbar item")
        let picker = try require(item.modePicker, "find the leading mode picker")
        let initialLeading = windowPosition(of: picker).minX

        // Change the leading reservation without moving the user's window to a different Space.
        toolbar.insertItem(withItemIdentifier: .space, at: 0)
        window.layoutIfNeeded()
        try expect(toolbar.items.first?.itemIdentifier == .space && windowPosition(of: picker).minX > initialLeading,
                   "move the picker right when the native toolbar reserves space at the leading edge")
        try checkLeftHeader(in: window, sidebar: sidebar)

        toolbar.removeItem(at: 0)
        document.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        try expect(abs(windowPosition(of: picker).minX - initialLeading) <= 0.5,
                   "return the picker to its original position after removing the leading reservation")
        try checkLeftHeader(in: window, sidebar: sidebar)
    }

    private static func checkRightSidebar(in document: DocumentWindow, panel: NSView) throws -> NSSplitViewController {
        let window = document.window
        window.layoutIfNeeded()
        let split = try require(window.contentViewController as? NSSplitViewController, "find the native window split")
        let item = try require(split.splitViewItems.last, "find the trailing terminal item")
        let host = item.viewController.view
        try expect(item.behavior == .inspector && item.allowsFullHeightLayout && !item.isCollapsed &&
                   (panel === host || panel.isDescendant(of: host)), "use a native trailing sidebar for the terminal")

        let sidebar = windowPosition(of: host)
        let frame = windowPosition(of: split.splitView)
        try expect(abs(sidebar.minY - frame.minY) < 2 && abs(sidebar.maxY - frame.maxY) < 2 &&
                   sidebar.maxY > window.contentLayoutRect.maxY,
                   "extend the right terminal from the window bottom into the titlebar")
        let items = window.toolbar?.items ?? []
        let divider = try require(items.firstIndex { $0.itemIdentifier == .inspectorTrackingSeparator },
                                  "continue the inspector divider through the toolbar")
        let tracking = try require(items[divider] as? NSTrackingSeparatorToolbarItem, "use a native inspector separator")
        try expect(tracking.splitView === split.splitView && tracking.dividerIndex == split.splitViewItems.count - 2 &&
                   items.indices.contains(divider + 1) && items[divider + 1].itemIdentifier == DocumentTitleBar.terminalItemIdentifier,
                   "track the active right divider and keep the terminal controls in its toolbar section")
        try expect(window.titlebarAccessoryViewControllers.isEmpty, "keep the right sidebar in the same title bar layout as the editor")
        let editor = document.editorContentView
        let exposedEditor = editor.convert(editor.safeAreaRect, to: nil)
        try expect(exposedEditor.maxX <= sidebar.minX + 2, "keep the exposed editor beside the terminal")
        try checkPaneRegion(in: panel)

        let header = try rightHeader(in: window)
        let file = try require(window.toolbar?.items.first { $0.itemIdentifier == DocumentTitleBar.fileItemIdentifier }?.view,
                               "find the document title row")
        for identifier in titleControls {
            try expect(view(identifier, in: panel) == nil, "keep the terminal title bar controls outside the panel body")
            let control = try require(view(identifier, in: header), "find \(identifier) in the terminal title bar")
            let controlFrame = windowPosition(of: control)
            try expect(control.window === window && !control.isHiddenOrHasHiddenAncestor &&
                       control.visibleRect.contains(control.bounds) && controlFrame.minX >= sidebar.minX - 1 &&
                       controlFrame.maxX <= sidebar.maxX + 1 && abs(controlFrame.midY - windowPosition(of: file).midY) < 4,
                       "place \(identifier) within the right sidebar on the document title row (control \(controlFrame), sidebar \(sidebar), title \(windowPosition(of: file)))")
        }
        return split
    }

    private static func checkRightSidebarFullScreenRoundTrip(in document: DocumentWindow, panel: NSView, leftSidebar: NSView) throws {
        let window = document.window
        let split = try checkRightSidebar(in: document, panel: panel)
        let originalFrame = window.frame
        let originalWidth = panel.frame.width
        let focus = window.firstResponder
        let header = try rightHeader(in: window)
        let inspector = try require(split.splitViewItems.last, "find the right sidebar before resizing")
        let dividerIndex = split.splitViewItems.count - 2
        let availableWidth = split.splitView.bounds.width - split.splitView.dividerThickness
        let originalPosition = availableWidth - originalWidth
        let minimumPosition = availableWidth - inspector.minimumThickness

        split.splitView.setPosition(minimumPosition, ofDividerAt: dividerIndex)
        _ = try checkRightSidebar(in: document, panel: panel)
        try checkLeftHeader(in: window, sidebar: leftSidebar)
        split.splitView.setPosition(originalPosition, ofDividerAt: dividerIndex)
        window.layoutIfNeeded()
        try expect(abs(panel.frame.width - originalWidth) <= 1,
                   "restore the sidebar's original width after dragging the divider (got \(panel.frame.width), expected \(originalWidth), split \(split.splitView.bounds.width), divider \(originalPosition))")

        // Run the native resize and delegate handling without switching the user's macOS Spaces.
        document.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        var expanded = originalFrame
        expanded.size.width += 320
        expanded.size.height += 160
        window.setFrame(expanded, display: false)
        document.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        _ = try checkRightSidebar(in: document, panel: panel)
        try checkLeftHeader(in: window, sidebar: leftSidebar)
        let dividers = try require(view("Edit.TitleBar.Dividers", in: window.contentView?.superview) as? TitleBarDividers,
                                   "find the full-screen title bar dividers")
        let strokes = dividers.strokes.map { dividers.convert($0, to: nil) }.sorted { $0.minX < $1.minX }
        let backingStrokes = strokes.map { window.convertToBacking($0) }
        let leftEdge = window.convertToBacking(windowPosition(of: leftSidebar)).maxX.rounded()
        let rightEdge = window.convertToBacking(windowPosition(of: panel)).minX.rounded()
        try expect(backingStrokes.count == 2 && backingStrokes[0].minX == leftEdge - 1 &&
                   backingStrokes[1].minX == rightEdge && backingStrokes.allSatisfy { $0.width == 1 },
                   "continue both visible sidebar edges with one aligned backing pixel (got \(backingStrokes), edges \(leftEdge) and \(rightEdge))")
        try expect(strokes.allSatisfy { abs($0.minY - window.contentLayoutRect.maxY) <= 2 &&
                       abs($0.maxY - windowPosition(of: split.splitView).maxY) <= 2 },
                   "extend both sidebar dividers through the full title bar (strokes \(strokes), title bar bottom \(window.contentLayoutRect.maxY))")
        try expect(abs(panel.frame.width - originalWidth) <= 1,
                   "preserve the right sidebar width on full-screen entry (got \(panel.frame.width), expected \(originalWidth))")
        try expect(window.firstResponder === focus, "preserve focus on full-screen entry")

        window.setFrame(originalFrame, display: false)
        document.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        try expect(dividers.superview == nil, "return to the native windowed title bar dividers on exit")
        _ = try checkRightSidebar(in: document, panel: panel)
        try checkLeftHeader(in: window, sidebar: leftSidebar)
        let restoredHeader = try rightHeader(in: window)
        try expect(restoredHeader === header && abs(panel.frame.width - originalWidth) <= 1 && window.firstResponder === focus,
                   "preserve the terminal header, width and focus across the full-screen round trip")
    }

    private static func checkScrollAndClear(in document: DocumentWindow, terminal: LocalProcessTerminalView,
                                            widthKey: NSEvent, clearKey: NSEvent) async throws {
        let scroll = try require(terminal.enclosingScrollView as? TerminalScrollView, "find the terminal's horizontal viewport")
        let columns = try require(terminal.terminalInputStateSnapshot()?.dimensions.cols, "read the initial PTY width")
        terminal.feed(text: String(repeating: "OldTerminalHistory\r\n", count: 40) +
                      "LongStart" + String(repeating: "x", count: columns * 2) + "LongEnd\r\nPrompt> editing")
        try expect(document.handleTerminalKey(widthKey) && scroll.hasHorizontalScroller &&
                   terminal.frame.width > scroll.contentSize.width, "fit the full output line and enable horizontal scrolling")
        let wide = try require(terminal.terminalContentSnapshot(region: .viewport), "read the widened buffer")
        try expect(wide.rows.contains { $0.text.hasPrefix("LongStart") && $0.text.hasSuffix("LongEnd") },
                   "reflow the entire long line into one terminal row")

        let wheel = try require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: 0, wheel2: -180, wheel3: 0).flatMap(NSEvent.init(cgEvent:)),
                                "make a horizontal scroll event")
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        try expect(TerminalScrollView.routeWheel(wheel, in: document.window, at: point),
                   "dispatch the horizontal wheel event to the terminal under the pointer")
        try await waitFor("scroll the terminal horizontally") { scroll.contentView.bounds.minX > 0 }
        try expect(document.handleTerminalKey(widthKey) && !scroll.hasHorizontalScroller &&
                   scroll.contentView.bounds.minX == 0, "return to the fitted width and left edge")

        document.focusContent()
        try expect(!document.handleTerminalKey(clearKey) && containsText("Prompt> editing", in: terminal),
                   "leave the terminal alone when Command-K is pressed in the editor")
        try expect(document.window.makeFirstResponder(terminal) && document.handleTerminalKey(clearKey),
                   "clear the focused terminal with Command-K")
        let cleared = try require(terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 200)),
                                  "read the cleared terminal")
        try expect(cleared.rows.first?.text == "Prompt> editing" &&
                   cleared.rows.dropFirst().allSatisfy { $0.text.isEmpty } &&
                   cleared.capturedRange.lowerBound == cleared.liveTopRow && terminal.process.running,
                   "keep the shell and its input while clearing prior output and scrollback")

        terminal.feed(text: "\u{1B}[?1049hAlternateScreen")
        try expect(document.handleTerminalKey(clearKey) && !containsText("AlternateScreen", in: terminal),
                   "clear the active alternate screen")
        terminal.feed(text: "\u{1B}[?1049l")
        try expect(containsText("Prompt> editing", in: terminal), "keep the normal buffer when clearing the alternate screen")
    }

    private static func checkShellExit(in app: Edit) async throws {
        let document = app.makeDocument()
        let window = document.window
        defer { window.close() }
        document.showTerminal()
        let left = try require(window.firstResponder as? LocalProcessTerminalView, "find the first pane")
        let panel = try require(view("Edit.Terminal.Panel", in: window.contentView), "find the exit test panel")
        let options = try require(view("Edit.Terminal.Options", in: panel) as? NSButton, "find the exit test options")
        let controller = try require(options.target as? TerminalPanel, "find the exit test controller")

        controller.split(.right)
        let right = try require(window.firstResponder as? LocalProcessTerminalView, "find the right pane")
        controller.split(.down)
        let lower = try require(window.firstResponder as? LocalProcessTerminalView, "find the lower pane")
        right.startProcess(executable: "/bin/sh", args: ["-c", "printf 'SurvivingShell\n'; exec /bin/sleep 60"])
        try await waitFor("start the surviving shell") { right.process.running && containsText("SurvivingShell", in: right) }

        lower.startProcess(executable: "/bin/sh", args: ["-c", "exit 7"])
        try await waitFor("close a focused pane on shell exit") { lower.window == nil }
        let split = try require(view("Edit.Terminal.Split", in: panel) as? NSSplitView, "keep the outer split")
        try expect(window.firstResponder === right && split.isVertical &&
                   view("Edit.Terminal.Split", in: split.arrangedSubviews[1]) == nil, "collapse only the inner split and focus its sibling")
        try expect(right.process.running && containsText("SurvivingShell", in: right), "keep the sibling's running shell and output")

        document.focusContent()
        left.startProcess(executable: "/bin/sh", args: ["-c", "exit"])
        try await waitFor("close a pane while the editor has focus") { left.window == nil }
        try expect(window.firstResponder === document.editor && right.window === window &&
                   view("Edit.Terminal.Split", in: panel) == nil, "fill the panel with the remaining pane and keep editor focus")

        let add = try require(view("Edit.Terminal.NewSpace", in: panel) as? NSButton, "find the new-space button")
        let spaces = try require(view("Edit.Terminal.Spaces", in: panel) as? NSPopUpButton, "find the exit test picker")
        try expect(NSApp.sendAction(try require(add.action, "connect the new-space action"), to: add.target, from: add),
                   "create another space")
        let second = try require(window.firstResponder as? LocalProcessTerminalView, "focus the second space")
        second.startProcess(executable: "/bin/sh", args: ["-c", "exit"])
        try await waitFor("remove the selected space when its only shell exits") { spaces.numberOfItems == 1 }
        try expect(window.firstResponder === right && document.isTerminalVisible, "return to the surviving space")

        let single = app.makeDocument()
        defer { single.window.close() }
        single.showTerminal()
        let last = try require(single.window.firstResponder as? LocalProcessTerminalView, "focus the only pane")
        last.startProcess(executable: "/bin/sh", args: ["-c", "exit"])
        try await waitFor("hide the panel after the final shell exits") { !single.isTerminalVisible }
        try expect(single.window.firstResponder === single.editor, "return focus to the editor after the final exit")
        single.showTerminal()
        try expect(single.window.firstResponder is LocalProcessTerminalView && single.window.firstResponder !== last,
                   "create a fresh pane after reopening the emptied panel")
    }

    private static func checkRestoration(in app: Edit, visible: DocumentWindow, controller: TerminalPanel,
                                         pane: LocalProcessTerminalView) async throws {
        let dock = try bottomDock(in: visible)
        dock.setPosition(dock.bounds.height - dock.dividerThickness - 172, ofDividerAt: 0)
        try expect(dockAction(.right, in: controller), "set the saved dock side")
        let split = try checkRightSidebar(in: visible, panel: controller.view)
        split.splitView.setPosition(split.splitView.bounds.width - split.splitView.dividerThickness - 283,
                                    ofDividerAt: split.splitViewItems.count - 2)
        controller.zoom(.increase)
        try expect(menuAction("Wrap Lines", in: contextMenu(for: pane)), "change wrap before saving")
        let scrolling = try require(pane.enclosingScrollView, "find the viewport of the saved pane")
        scrolling.contentView.scroll(to: NSPoint(x: 90, y: 0))
        scrolling.reflectScrolledClipView(scrolling.contentView)
        try expect(scrolling.contentView.bounds.minX == 90, "scroll before saving")
        pane.startProcess(executable: "/bin/sh", args: ["-c",
            "printf '\\033]4;1;rgb:22/55/88\\007\\033[31mEditHistory\\033[38;2;17;34;51m色\\033[0m✓\\n'; exec /bin/sleep 15",
        ])
        defer { pane.terminate() }
        try await waitFor("capture output from the live shell") { pane.process.running && containsText("EditHistory", in: pane) }

        let hidden = app.makeDocument()
        defer { hidden.window.close() }
        hidden.showTerminal()
        let hiddenPane = try require(hidden.window.firstResponder as? LocalProcessTerminalView, "focus the second window's terminal")
        hiddenPane.feed(text: "HiddenHistory\r\n")
        hidden.toggleTerminal()

        let visibleRecord = visible.sessionDocument()
        let hiddenRecord = hidden.sessionDocument()
        let saved = try require(visibleRecord.terminal, "save the visible terminal")
        try expect(saved.isVisible && saved.wasFocused && hiddenRecord.terminal?.isVisible == false, "record both visibility states")
        try expect(abs(saved.sizes.belowHeight - 172) < 2 && abs(saved.sizes.rightWidth - 283) < 2,
                   "save a dock height of 172 and a sidebar width of 283 (got \(saved.sizes.belowHeight), \(saved.sizes.rightWidth))")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(url: file)
        var fullScreenRecord = visibleRecord
        fullScreenRecord.placement.isFullScreen = true
        try store.write(EditorSession(documents: [visibleRecord, hiddenRecord, fullScreenRecord], activeIndex: 0, lastWindow: nil))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "save terminal output privately")
        let snapshot = try require(store.read(), "read persisted terminal windows")
        visible.closeTerminalSessions()
        try await waitFor("stop the saved shell process") { !pane.process.running }

        let offset = app.documents.count
        await app.restore(snapshot, reusing: app.makeDocument())
        let restored = Array(app.documents.dropFirst(offset))
        defer { restored.forEach { $0.window.close() } }
        try expect(restored.count == 3, "reopen all terminal windows")
        let active = restored[0]
        let inactive = restored[1]
        let restoredPane = try require(active.window.firstResponder as? LocalProcessTerminalView, "restore the active pane")
        let restoredPanel = try require(view("Edit.Terminal.Panel", in: active.window.contentView), "restore the visible panel")
        let restoredOptions = try require(view("Edit.Terminal.Options", in: rightHeader(in: active.window)) as? NSButton,
                                          "restore title bar options")
        let restoredController = try require(restoredOptions.target as? TerminalPanel, "recover the panel controller")
        let restoredSplit = try require(view("Edit.Terminal.Split", in: restoredPanel) as? NSSplitView, "restore the split tree")
        let restoredDock = try checkRightSidebar(in: active, panel: restoredPanel)
        let restoredWidth = try require(restoredDock.splitViewItems.last, "restore the trailing terminal item")
            .viewController.view.frame.width
        try expect(active.isTerminalVisible && restoredController.dock == .right &&
                   abs(restoredWidth - saved.sizes.rightWidth) < 2, "restore the visible panel on the right at its saved size")
        try expect(restoredSplit.isVertical &&
                   view("Edit.Terminal.Split", in: restoredSplit.arrangedSubviews[1]) != nil, "restore both split axes")
        try expect(restoredPane.font.pointSize == 13 &&
                   contextMenu(for: restoredPane).item(withTitle: "Wrap Lines")?.state == .off, "restore per-pane zoom and wrap")
        try expect(restoredPane.enclosingScrollView?.contentView.bounds.minX == 90, "restore the horizontal scroll position")
        try await waitFor("restore history in a stopped terminal") {
            !restoredPane.process.running && containsText("EditHistory", in: restoredPane)
        }
        let styledRow = try require(restoredPane.terminalContentSnapshot(region: .history(maximumScrollbackRows: 128))?
            .rows.first { $0.text.contains("EditHistory色✓") }, "restore colored text and the wide glyph together")
        try expect(styledRow.cells.first { $0.text == "E" }?.attribute.fg == .trueColor(red: 34, green: 85, blue: 136) &&
                   styledRow.cells.first { $0.text == "色" }?.attribute.fg == .trueColor(red: 17, green: 34, blue: 51) &&
                   styledRow.cells.first { $0.text == "✓" }?.attribute.fg == .defaultColor,
                   "restore indexed and RGB color runs and the reset to the default color after reopening")
        try expect(!inactive.isTerminalVisible && view("Edit.Terminal.Panel", in: inactive.window.contentView) == nil,
                   "restore a hidden panel lazily")
        let hiddenAgain = inactive.sessionDocument()
        try expect(hiddenAgain.terminal?.isVisible == false, "retain unopened terminal state for a second quit")
        inactive.showTerminal()
        let reopened = try require(inactive.window.firstResponder as? LocalProcessTerminalView, "show the previously hidden session")
        try await waitFor("recover stopped history from the hidden panel") {
            !reopened.process.running && containsText("HiddenHistory", in: reopened)
        }
        try await checkFullScreenRestoration(in: restored[2], saved: saved)
        try closeStoppedPane(restoredPane, in: active.window)
        try expect(active.isTerminalVisible && active.window.firstResponder is LocalProcessTerminalView,
                   "close one stopped pane and focus a survivor in the split")
        try closeStoppedPane(reopened, in: inactive.window)
        try expect(!inactive.isTerminalVisible && inactive.window.firstResponder === inactive.editor,
                   "hide the panel and return focus to the editor after closing the final stopped pane")
    }

    private static func checkFullScreenRestoration(in document: DocumentWindow, saved: DocumentTerminalState) async throws {
        let window = document.window
        try expect(!document.isTerminalVisible && view("Edit.Terminal.Panel", in: window.contentView) == nil,
                   "wait for full screen before mounting the restored terminal")
        let pending = try require(document.sessionDocument().terminal, "keep the pending terminal available for another save")
        try expect(pending.sizes == saved.sizes && pending.isVisible && pending.wasFocused && pending.panel == saved.panel,
                   "save the original terminal state while full-screen restoration is pending")

        // Deliver the layout and callback without switching the user's macOS Spaces.
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
        let presentation = document.window(window, willUseFullScreenPresentationOptions: proposed)
        try expect(presentation.contains(.fullScreen) && !presentation.contains(.autoHideToolbar),
                   "keep the terminal title bar available in full screen")
        var expanded = window.frame
        expanded.size.width += 400
        expanded.size.height += 180
        window.setFrame(expanded, display: false)
        document.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))

        let panel = try require(view("Edit.Terminal.Panel", in: window.contentView), "mount the terminal after entering full screen")
        let split = try checkRightSidebar(in: document, panel: panel)
        let sidebar = try require(split.splitViewItems.last, "find the restored full-screen sidebar")
        let actualWidth = sidebar.viewController.view.frame.width
        try expect(abs(actualWidth - saved.sizes.rightWidth) < 2 &&
                   sidebar.preferredThicknessFraction == NSSplitViewItem.unspecifiedDimension,
                   "restore the saved sidebar width in the larger frame (got \(actualWidth), expected \(saved.sizes.rightWidth))")
        let layout = try require(view("Edit.Terminal.Split", in: panel) as? NSSplitView, "restore the full-screen split tree")
        let nested = view("Edit.Terminal.Split", in: layout.arrangedSubviews[1]) as? NSSplitView
        try expect(layout.isVertical && nested?.isVertical == false, "restore both full-screen split axes")
        let focused = try require(window.firstResponder as? LocalProcessTerminalView, "focus the restored full-screen pane")
        try await waitFor("restore full-screen terminal history without a process") {
            !focused.process.running && containsText("EditHistory", in: focused)
        }
    }

    private static func closeStoppedPane(_ terminal: LocalProcessTerminalView, in window: NSWindow) throws {
        let pane = try require(terminal.enclosingScrollView?.superview, "find the stopped pane")
        let restart = try require(view("Edit.Terminal.RestartShell", in: pane) as? NSButton, "find Restart Shell")
        let close = try require(view("Edit.Terminal.CloseShell", in: pane) as? NSButton, "find Close")
        try expect(!terminal.process.running && !restart.isHiddenOrHasHiddenAncestor && !close.isHiddenOrHasHiddenAncestor &&
                   restart.superview === close.superview && abs(windowPosition(of: restart).midY - windowPosition(of: close).midY) < 1,
                   "show Close beside Restart Shell")
        try expect(window.makeFirstResponder(terminal), "focus the stopped pane before closing it")
        let action = try require(close.action, "connect the Close button")
        try expect(NSApp.sendAction(action, to: close.target, from: close) && terminal.window == nil,
                   "remove the stopped pane from the window")
    }

    private static func containsText(_ needle: String, in terminal: LocalProcessTerminalView) -> Bool {
        terminal.terminalStateSnapshot().visibleRows.contains { $0.text.contains(needle) }
    }

    private static func checkTranscriptStyleBounds() throws {
        let transcript = TerminalTranscript(text: "é" + String(repeating: "a", count: 256 * 1024 - 1),
                                            styles: [.init(byteOffset: 0, parameters: "0;31")])
        try expect(transcript.replayText.hasPrefix("\u{1B}[0;31ma") && transcript.replayText.hasSuffix("\u{1B}[0m"),
                   "retain the color active at the clipped UTF-8 boundary and reset it at the end")
        let malformed = TerminalTranscript(text: "é\u{1B}[2J", styles: [
            .init(byteOffset: 1, parameters: "0;31"),
            .init(byteOffset: 2, parameters: "0m\u{1B}[2J"),
        ])
        try expect(malformed.replayText == "é[2J", "play session text without replaying embedded terminal commands")
    }

    private static func checkShell(in terminal: LocalProcessTerminalView) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-pty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        terminal.startProcess(executable: "/bin/sh",
                              args: ["-c", "test -t 0 && test -t 1 && printf 'edit-pty:%s\n' \"${PWD##*/}\" && exec /bin/sleep 60"],
                              environment: ["HOME=\(folder.path)", "TERM=xterm-256color", "PATH=/usr/bin:/bin"],
                              currentDirectory: folder.path)
        try await waitFor("read a real PTY command’s output in its requested directory") {
            containsText("edit-pty:terminal-pty", in: terminal) && terminal.process.running
        }
    }

    private static func waitFor(_ description: String, interval: Duration = .milliseconds(20), until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: interval)
        }
        throw Failure(description)
    }

    private static func menuAction(_ title: String, in menu: NSMenu) -> Bool {
        guard let item = menu.item(withTitle: title), let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func dockAction(_ dock: TerminalDock, in panel: TerminalPanel) -> Bool {
        let picker = panel.makeDockPicker()
        let identifier = dock == .below ? "Edit.Terminal.DockBelow" : "Edit.Terminal.DockRight"
        guard let button = view(identifier, in: picker.view) as? NSButton, let action = button.action else { return false }
        return NSApp.sendAction(action, to: button.target, from: button)
    }

    private static func contextMenu(for terminal: LocalProcessTerminalView) throws -> NSMenu {
        let event = try require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: terminal.window?.windowNumber ?? 0, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1), "create a contextual click")
        return try require(terminal.menu(for: event), "find the clicked terminal's context menu")
    }

    private static func windowPosition(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    private static func view(_ identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews {
            if let found = view(identifier, in: child) { return found }
        }
        return nil
    }

    private static func expect(_ result: Bool, _ description: String) throws {
        if !result { throw Failure(description) }
    }

    private static func checkToolbar(in window: NSWindow) throws {
        let toolbar = try require(window.toolbar, "find the document toolbar")
        try expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "Edit.Terminal" },
                   "keep terminal access out of the document toolbar")
    }

    private static func require<Value>(_ value: Value?, _ description: String) throws -> Value {
        guard let value else { throw Failure(description) }
        return value
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = "Terminal check could not \(description)." }
    }
}
