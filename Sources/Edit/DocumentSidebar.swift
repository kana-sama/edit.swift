import AppKit

enum SidebarMode: String, Codable, Sendable {
    case search, worktree, scratches, sourceControl, references

    var title: String {
        switch self {
        case .search: "Search"
        case .worktree: "Worktree"
        case .scratches: "Scratches"
        case .sourceControl: "Jujutsu"
        case .references: "References"
        }
    }
}

@MainActor
private final class SidebarHeaderView: NSView {
    init(title: NSView, options: NSView, trailingInset: CGFloat, maximumWidth: CGFloat) {
        super.init(frame: .zero)
        title.translatesAutoresizingMaskIntoConstraints = false
        options.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(options)
        // AppKit leaves four points between the toolbar item's edge and the sidebar divider.
        let trackingSeparatorSpacing: CGFloat = 4
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.bottomAnchor.constraint(equalTo: bottomAnchor),
            options.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            options.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trackingSeparatorSpacing - trailingInset),
            options.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Let the native tracking separator determine the width available after the window buttons.
            widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SidebarHeaderView is created in code.") }
}

@MainActor
final class SidebarMenuItem: NSToolbarItem {
    static let titleLeadingPadding: CGFloat = 3
    private static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

    let menu: NSMenu
    private var pickerWidth: NSLayoutConstraint?
    private(set) weak var modePicker: NSPopUpButton?
    private(set) var options: SidebarMenuItem?

    init(itemIdentifier identifier: NSToolbarItem.Identifier, showsTitle: Bool, mode: SidebarMode) {
        menu = NSMenu(title: showsTitle ? "Switch Sidebar" : "Sidebar Options")
        super.init(itemIdentifier: identifier)
        label = menu.title
        isBordered = false
        visibilityPriority = .high
        isHidden = true
        autovalidates = false
        menu.autoenablesItems = false

        let button: NSButton = showsTitle ? NSPopUpButton(frame: .zero, pullsDown: false) : NSButton()
        button.controlSize = .small
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        if let picker = button as? NSPopUpButton, let cell = picker.cell as? NSPopUpButtonCell {
            picker.menu = menu
            picker.autoenablesItems = false
            picker.usesItemFromMenu = false
            picker.font = Self.titleFont
            picker.alignment = .natural
            picker.imagePosition = .imageTrailing
            cell.arrowPosition = .noArrow
            let display = NSMenuItem(title: mode.title, action: nil, keyEquivalent: "")
            display.attributedTitle = Self.title(for: mode)
            if let glyph = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                let gap: CGFloat = 3
                let isRightToLeft = picker.userInterfaceLayoutDirection == .rightToLeft
                let size = NSSize(width: glyph.size.width + gap, height: glyph.size.height)
                display.image = NSImage(size: size, flipped: false) { bounds in
                    let rect = NSRect(origin: NSPoint(x: bounds.minX + (isRightToLeft ? 0 : gap), y: bounds.minY),
                                      size: glyph.size)
                    glyph.draw(in: rect)
                    NSColor.secondaryLabelColor.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
            }
            cell.menuItem = display
            let width = picker.widthAnchor.constraint(equalToConstant: ceil(picker.intrinsicContentSize.width))
            width.isActive = true
            pickerWidth = width
            modePicker = picker
            let title = NSStackView(views: [picker])
            title.alignment = .centerY
            // Align with the folder label in the collapsed toolbar.
            title.edgeInsets.left = Self.titleLeadingPadding
            view = title
        } else {
            button.target = self
            button.action = #selector(showOptions(_:))
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            view = button
        }
        updateTitle(for: mode)

        let overflow = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        overflow.submenu = menu
        menuFormRepresentation = overflow
    }

    func installOptions(_ options: SidebarMenuItem, trailingInset: CGFloat, maximumWidth: CGFloat) {
        guard let title = view, let button = options.view else { return }
        self.options = options
        view = SidebarHeaderView(title: title, options: button, trailingInset: trailingInset, maximumWidth: maximumWidth)
    }

    private static func title(for mode: SidebarMode) -> NSAttributedString {
        NSAttributedString(string: mode.title, attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    func updateTitle(for mode: SidebarMode) {
        if let picker = modePicker {
            if let display = (picker.cell as? NSPopUpButtonCell)?.menuItem {
                display.title = mode.title
                display.attributedTitle = Self.title(for: mode)
            }
            // Fit the native cell to keep the gap between the title and trailing chevron.
            picker.invalidateIntrinsicContentSize()
            pickerWidth?.constant = ceil(picker.intrinsicContentSize.width)
            picker.setAccessibilityLabel("\(mode.title), Switch Sidebar")
            picker.needsDisplay = true
        } else {
            view?.setAccessibilityLabel("\(mode.title) Options")
        }
    }

    func popupOrigin(in button: NSView) -> NSPoint {
        let bounds = button.bounds
        let x = button.userInterfaceLayoutDirection == .rightToLeft ? bounds.maxX : bounds.maxX - menu.size.width
        return NSPoint(x: x, y: button.isFlipped ? bounds.maxY : bounds.minY)
    }

    @objc private func showOptions(_ button: NSButton) {
        menu.popUp(positioning: nil, at: popupOrigin(in: button), in: button)
    }
}

@MainActor
final class DocumentSidebar: NSObject, NSMenuDelegate {
    private static let sidebarMenuItem = NSToolbarItem.Identifier("Edit.SidebarMenu")
    // Leave room for the window controls, Worktree title and options button.
    private static let minimumWidth: CGFloat = 208 + SidebarMenuItem.titleLeadingPadding
    private static let maximumWidth: CGFloat = 650
    private static let headerInset: CGFloat = 10

    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private let controller = NSViewController()
    private lazy var item = NSSplitViewItem(sidebarWithViewController: controller)
    private var splitView: NSSplitView { document.documentSplitView }
    private var installed = false
    private weak var sidebarHeader: SidebarMenuItem?
    private weak var focusBeforeSidebar: NSView?
    private(set) var rememberedMode: SidebarMode?
    private(set) var isVisible = false
    var width = SessionFindSettings.defaultWidth
    private var restoredWorktreeShowsHidden = false
    private(set) var searchTreeMode = false
    private(set) var referencesTreeMode = false

    private var search: FindSidebar?
    private(set) var worktree: SidebarFileTree?
    private var scratches: SidebarFileTree?
    private(set) var sourceControl: SourceControlSidebar?
    private var references: ReferencesSidebar?
    private var scratchReload: Task<Void, Never>?

    var mode: SidebarMode { rememberedMode ?? (document.folderURL == nil ? .scratches : .search) }
    var isSearchVisible: Bool { isVisible && mode == .search }
    private var worktreeVisible: Bool { isVisible && mode == .worktree }
    private var scratchesVisible: Bool { isVisible && mode == .scratches }
    private var sourceControlVisible: Bool { isVisible && mode == .sourceControl }
    private var worktreeFile: URL? { document.scratchFile == nil ? document.displayedFileURL : nil }
    var scratchOutline: NSOutlineView? { scratches?.outline }
    var hasReferences: Bool { references != nil }
    var hasContent: Bool { search != nil || worktree != nil || scratches != nil || sourceControl != nil || hasReferences }
    var worktreeShowsHidden: Bool { worktree?.showsHidden ?? restoredWorktreeShowsHidden }

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        super.init()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        view.clipsToBounds = true
        controller.view = view
        document.editor.onFindEditorInteraction = { [weak self] in self?.editorInteracted() }
    }

    deinit { scratchReload?.cancel() }

    func restore(mode: SidebarMode?, width: Double, visible: Bool, showsHidden: Bool,
                 searchTreeMode: Bool, referencesTreeMode: Bool) {
        rememberedMode = mode.map(availableMode)
        self.width = width
        restoredWorktreeShowsHidden = showsHidden
        self.searchTreeMode = searchTreeMode
        self.referencesTreeMode = referencesTreeMode
        document.updateOccurrenceFindSettings()
        if visible { showCurrentMode() }
    }

    func canPerformFind(_ command: FindCommand) -> Bool {
        switch command {
        case .find, .replace, .toggleSidebar: return true
        case .next, .previous: return !document.findSettings.query.isEmpty
        default: return search?.canPerform(command) == true
        }
    }

    func performFind(_ command: FindCommand) {
        switch command {
        case .find:
            toggleFocus(of: .search)
        case .replace:
            rememberFocus()
            searchPanel().openField(replace: true, reveal: revealSearch)
        case .toggleSidebar:
            if isVisible { hide() }
            else { showCurrentMode() }
        default:
            searchPanel().perform(command)
        }
    }

    private func showCurrentMode() {
        switch availableMode(mode) {
        case .search: showSearch()
        case .worktree: showWorktree(focus: false)
        case .scratches: showScratches(focus: false)
        case .sourceControl: showSourceControl(focus: false)
        case .references: showReferences(focus: false)
        }
    }

    private func searchPanel() -> FindSidebar {
        if let search { return search }
        let search = FindSidebar(document: document) { [weak self] in
            self?.returnFocus()
        }
        self.search = search
        installContent(search.view)
        search.view.isHidden = mode != .search
        return search
    }

    private func showSearch(focusingQuery: Bool = false) {
        let search = searchPanel()
        selectMode(.search)
        present(focusing: focusingQuery ? search.queryResponder : nil)
        search.searchWhenShown()
    }

    private func revealSearch(focusing input: NSView, expandingReplacement: Bool) {
        selectMode(.search)
        if expandingReplacement { search?.setReplacementVisible(true) }
        present(focusing: input)
    }

    func toggleFocus(of mode: SidebarMode) {
        if isVisible && self.mode == mode && focusIsInSidebar {
            focusBeforeSidebar = nil
            returnFocus()
            return
        }
        rememberFocus()
        switch mode {
        case .search: searchPanel().focusSearch(reveal: revealSearch)
        case .worktree: showWorktree()
        case .scratches: showScratches()
        case .sourceControl: showSourceControl()
        case .references: showReferences()
        }
    }

    private func rememberFocus() {
        if !focusIsInSidebar { focusBeforeSidebar = document.window.firstResponder as? NSView }
    }

    private func editorInteracted() {
        if isVisible && mode == .references { references?.clearPreview() }
        else { search?.editorInteracted() }
    }

    private func returnFocus() {
        let window = document.window
        search?.clearTransientFocus()
        let responder = focusBeforeSidebar
        focusBeforeSidebar = nil
        if let responder, responder.window === window, !responder.isHiddenOrHasHiddenAncestor,
           window.makeFirstResponder(responder) {
            search?.refreshDecorations()
            return
        }
        document.focusContent()
        search?.refreshDecorations()
    }

    private func showWorktree(focus: Bool = true) {
        guard let folder = document.folderURL else { return }
        document.requestAutosave()
        let browser: SidebarFileTree
        if let worktree {
            browser = worktree
        } else {
            browser = SidebarFileTree(document: document, app: app, mode: .worktree)
            worktree = browser
            if restoredWorktreeShowsHidden { browser.setShowsHidden(true) }
            installContent(browser.view)
        }
        selectMode(.worktree)
        browser.update(folder: folder, currentFile: worktreeFile)
        present(focusing: focus ? browser.outline : nil)
        browser.setActive(true)
    }

    private func showScratches(focus: Bool = true) {
        document.requestAutosave()
        let list: SidebarFileTree
        if let scratches {
            list = scratches
        } else {
            list = SidebarFileTree(document: document, app: app, mode: .scratches)
            scratches = list
            installContent(list.view)
        }
        selectMode(.scratches)
        list.updateScratchCurrent(document.scratchFile?.id, reveal: true)
        present(focusing: focus ? list.outline : nil)
        list.setActive(true)
        reloadScratches()
    }

    private func showSourceControl(focus: Bool = true) {
        guard document.hasJujutsuWorkspace else { return }
        document.requestAutosave()
        let panel: SourceControlSidebar
        if let sourceControl {
            panel = sourceControl
        } else {
            panel = SourceControlSidebar(document: document, app: app)
            sourceControl = panel
            installContent(panel.view)
        }
        panel.update(folder: document.folderURL)
        selectMode(.sourceControl)
        present(focusing: focus ? panel.focusResponder : nil)
        panel.setActive(true)
    }

    func showReferences(symbol: String, originURL: URL, originLine: Int, originColumn: Int,
                        results: [ReferenceResult], preview: @escaping (ReferenceResult, [Int]) -> Void,
                        activate: @escaping (ReferenceResult, [Int]) -> Void, didHide: @escaping () -> Void) {
        guard !results.isEmpty else { return }
        let panel: ReferencesSidebar
        if let references {
            panel = references
        } else {
            panel = ReferencesSidebar { [weak self] in self?.returnFocus() }
            panel.setTreeMode(referencesTreeMode)
            references = panel
            panel.view.isHidden = true
            installContent(panel.view)
        }
        panel.update(symbol: symbol, originURL: originURL, originLine: originLine, originColumn: originColumn,
                     root: document.folderURL ?? originURL.deletingLastPathComponent(), results: results,
                     preview: preview, activate: activate, didHide: didHide)
        rememberFocus()
        showReferences()
    }

    private func showReferences(focus: Bool = true) {
        guard let references else { return }
        selectMode(.references)
        present(focusing: focus ? references.focusResponder : nil)
        references.revealSelection(previewSelection: focus)
    }

    private func installContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: controller.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
    }

    func reloadScratches() {
        guard scratchesVisible, let scratches else { return }
        scratchReload?.cancel()
        let store = app.scratchStore
        scratchReload = Task { [weak self, weak scratches] in
            do {
                let files = try await store.files()
                guard !Task.isCancelled, let self, scratchesVisible else { return }
                scratches?.updateScratches(files, current: document.scratchFile?.id)
            } catch {
                guard !Task.isCancelled, let self, scratchesVisible else { return }
                await document.showError("Could Not Load Scratches", detail: error.localizedDescription)
            }
        }
    }

    private func selectMode(_ mode: SidebarMode) {
        let changed = mode != self.mode
        if changed && self.mode == .references && isVisible { references?.clearPreview() }
        rememberedMode = mode
        search?.view.isHidden = mode != .search
        worktree?.view.isHidden = mode != .worktree
        scratches?.view.isHidden = mode != .scratches
        sourceControl?.view.isHidden = mode != .sourceControl
        references?.view.isHidden = mode != .references
        if mode != .worktree { worktree?.setActive(false) }
        if mode != .scratches { scratches?.setActive(false) }
        if mode != .sourceControl { sourceControl?.setActive(false) }
        document.updateOccurrenceFindSettings()
        if changed && mode != .search { search?.switchedAway() }
        updateSidebarMenu()
    }

    func folderChanged() {
        if worktreeVisible, let folder = document.folderURL { worktree?.update(folder: folder, currentFile: worktreeFile) }
        switchToAvailableMode()
        reloadScratches()
        sourceControl?.update(folder: document.folderURL)
        app.updateJujutsuShortcut()
    }

    func hideWorkspacePanel() {
        if worktreeVisible || sourceControlVisible { hide() }
    }

    func recheckJujutsuAvailability(_ available: Bool) {
        if mode == .sourceControl, !available { switchToAvailableMode() }
        sidebarHeader?.menu.item(withTitle: SidebarMode.sourceControl.title)?.isEnabled = available
    }

    private func availableMode(_ mode: SidebarMode) -> SidebarMode {
        if mode == .sourceControl, !document.hasJujutsuWorkspace { return document.folderURL == nil ? .search : .worktree }
        if mode == .worktree, document.folderURL == nil { return .search }
        if mode == .references, !hasReferences { return .search }
        return mode
    }

    private func switchToAvailableMode() {
        let available = availableMode(mode)
        if available == mode {
            updateSidebarMenu()
        } else if !isVisible {
            selectMode(available)
        } else if available == .worktree {
            showWorktree(focus: focusIsInSidebar)
        } else {
            showSearch(focusingQuery: focusIsInSidebar)
        }
    }

    func documentTitleChanged(reveal: Bool) {
        search?.updateName()
        if worktreeVisible, let folder = document.folderURL {
            worktree?.update(folder: folder, currentFile: worktreeFile, revealCurrentFile: reveal)
        }
        scratches?.updateScratchCurrent(document.scratchFile?.id, reveal: reveal)
    }

    func revealCurrentScratch() { scratches?.revealCurrentScratch() }

    func editorBufferReplaced() { search?.bufferReplaced() }

    func markdownModeChanged() { search?.updateReplaceAvailability() }

    func makeSidebarHeader() -> SidebarMenuItem {
        let item = SidebarMenuItem(itemIdentifier: DocumentTitleBar.sidebarItemIdentifier, showsTitle: true, mode: mode)
        let options = SidebarMenuItem(itemIdentifier: Self.sidebarMenuItem, showsTitle: false, mode: mode)
        item.menu.delegate = self
        options.menu.delegate = self
        updateSidebarMenuItems(item)
        updateSidebarMenuItems(options)
        item.installOptions(options, trailingInset: Self.headerInset, maximumWidth: Self.maximumWidth)
        item.isHidden = false
        options.isHidden = options.menu.items.isEmpty
        options.view?.isHidden = options.isHidden
        sidebarHeader = item
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if sidebarHeader?.menu === menu {
            recheckJujutsuAvailability(document.hasJujutsuWorkspace)
        } else if let options = sidebarHeader?.options, options.menu === menu {
            updateSidebarMenuItems(options)
        }
    }

    private func updateSidebarMenu() {
        guard let header = sidebarHeader, let options = header.options else { return }
        header.updateTitle(for: mode)
        options.updateTitle(for: mode)
        updateSidebarMenuItems(header)
        updateSidebarMenuItems(options)
        updateSidebarToolbarVisibility()
    }

    private func updateSidebarMenuItems(_ item: SidebarMenuItem) {
        let menu = item.menu
        guard let picker = item.modePicker else {
            menu.removeAllItems()
            updateSidebarOptions(menu)
            return
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: SidebarMode.worktree.title, action: #selector(selectWorktreeSidebar(_:)),
                         keyEquivalent: "").target = self
            menu.addItem(withTitle: SidebarMode.scratches.title, action: #selector(selectScratchSidebar(_:)),
                         keyEquivalent: "").target = self
            menu.addItem(withTitle: SidebarMode.sourceControl.title, action: #selector(selectSourceControlSidebar(_:)),
                         keyEquivalent: "").target = self
            menu.addItem(withTitle: SidebarMode.search.title, action: #selector(selectSearchSidebar(_:)),
                         keyEquivalent: "").target = self
        }
        if hasReferences, menu.item(withTitle: SidebarMode.references.title) == nil {
            menu.addItem(withTitle: SidebarMode.references.title, action: #selector(selectReferencesSidebar(_:)),
                         keyEquivalent: "").target = self
        }
        menu.item(withTitle: SidebarMode.worktree.title)?.isEnabled = document.folderURL != nil
        menu.item(withTitle: SidebarMode.sourceControl.title)?.isEnabled = document.hasJujutsuWorkspace
        picker.selectItem(at: menu.indexOfItem(withTitle: mode.title))
    }

    private func updateSidebarOptions(_ menu: NSMenu) {
        switch mode {
        case .search:
            menu.addItem(withTitle: "Refresh Search", action: #selector(refreshSearch(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            addTreeMode(to: menu, enabled: searchTreeMode)
        case .worktree:
            guard let worktree, document.folderURL != nil else { return }
            worktree.addRootCreationItems(to: menu)
            menu.addItem(.separator())
            let hidden = menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
            hidden.target = self
            hidden.state = worktree.showsHidden ? .on : .off
        case .scratches:
            scratches?.addRootCreationItems(to: menu)
        case .sourceControl:
            menu.addItem(withTitle: "Refresh Changes", action: #selector(refreshSourceControl(_:)), keyEquivalent: "").target = self
        case .references:
            addTreeMode(to: menu, enabled: referencesTreeMode)
        }
    }

    private func addTreeMode(to menu: NSMenu, enabled: Bool) {
        let item = menu.addItem(withTitle: "Tree Mode", action: #selector(toggleResultTreeMode(_:)), keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
    }

    private func installIfNeeded() {
        guard !installed else { return }
        let window = document.window
        let split = document.installDocumentSplit()
        item.minimumThickness = Self.minimumWidth
        item.allowsFullHeightLayout = true
        item.maximumThickness = Self.maximumWidth
        item.canCollapse = true
        item.preferredThicknessFraction = min(0.7, CGFloat(width) / max(splitView.bounds.width, 1))
        item.isCollapsed = true
        split.insertSplitViewItem(item, at: 0)
        document.titleBar.installSidebar(self)
        window.initialFirstResponder = document.contentResponder
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        installed = true
    }

    @objc private func splitResized(_ notification: Notification) {
        guard installed else { return }
        document.titleBar.resize()
        setVisible(!item.isCollapsed)
        let currentWidth = controller.view.frame.width
        if isVisible && currentWidth >= item.minimumThickness {
            width = currentWidth
        }
        updateSidebarToolbarVisibility()
        worktree?.setActive(worktreeVisible)
        scratches?.setActive(scratchesVisible)
        sourceControl?.setActive(sourceControlVisible)
        if !isVisible {
            search?.clearTransientFocus()
            if focusIsInSidebar { returnFocus() }
        }
        search?.refreshDecorations()
    }

    private var focusIsInSidebar: Bool {
        guard installed, let view = document.window.firstResponder as? NSView else { return false }
        return view.isDescendant(of: controller.view)
    }

    private func present(focusing input: NSView?) {
        let window = document.window
        let responder = window.firstResponder
        let desiredWidth = max(width, Self.minimumWidth)
        let needsOpening = !installed || !isVisible || item.isCollapsed
        PanelLayout.withoutAnimation {
            installIfNeeded()
            setVisible(true)
            if needsOpening {
                item.preferredThicknessFraction = min(0.7, CGFloat(desiredWidth) / max(splitView.bounds.width, 1))
                setSidebarCollapsed(false, desiredWidth: desiredWidth)
            }
        }
        if let input {
            search?.cancelPendingFocus()
            window.makeFirstResponder(input)
        } else if let responder, !focusIsInSidebar {
            window.makeFirstResponder(responder)
        }
        search?.refreshDecorations()
    }

    private func hide() {
        guard installed && isVisible else { return }
        if focusIsInSidebar { returnFocus() }
        setVisible(false)
        worktree?.setActive(false)
        scratches?.setActive(false)
        sourceControl?.setActive(false)
        search?.clearTransientFocus()
        PanelLayout.withoutAnimation { setSidebarCollapsed(true) }
        search?.refreshDecorations()
    }

    private func updateSidebarToolbarVisibility() {
        document.titleBar.setSidebarHeaderVisible(isVisible && !item.isCollapsed)
        guard let header = sidebarHeader, let options = header.options else { return }
        let optionsHidden = options.menu.items.isEmpty
        PanelLayout.withoutAnimation {
            if options.isHidden != optionsHidden { options.isHidden = optionsHidden }
            if options.view?.isHidden != optionsHidden { options.view?.isHidden = optionsHidden }
        }
    }

    private func setSidebarCollapsed(_ collapsed: Bool, desiredWidth: CGFloat? = nil) {
        item.isCollapsed = collapsed
        if let desiredWidth { splitView.setPosition(desiredWidth, ofDividerAt: 0) }
        document.window.layoutIfNeeded()
        document.titleBar.resize()
        updateSidebarToolbarVisibility()
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        if !visible && mode == .references { references?.clearPreview() }
        isVisible = visible
        document.updateOccurrenceFindSettings()
    }

    @objc private func selectSearchSidebar(_ sender: Any?) {
        rememberFocus()
        document.requestAutosave()
        showSearch(focusingQuery: true)
    }

    @objc private func selectWorktreeSidebar(_ sender: Any?) {
        rememberFocus()
        showWorktree()
    }

    @objc private func selectScratchSidebar(_ sender: Any?) {
        rememberFocus()
        showScratches()
    }

    @objc private func selectSourceControlSidebar(_ sender: Any?) {
        rememberFocus()
        showSourceControl()
    }

    @objc private func selectReferencesSidebar(_ sender: Any?) {
        rememberFocus()
        showReferences()
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        guard worktreeVisible, let worktree else { return }
        worktree.setShowsHidden(!worktree.showsHidden)
        updateSidebarMenu()
    }

    @objc private func refreshSearch(_ sender: Any?) { search?.perform(.refresh) }

    @objc private func toggleResultTreeMode(_ sender: Any?) {
        switch mode {
        case .search: searchTreeMode.toggle()
        case .references:
            referencesTreeMode.toggle()
            references?.setTreeMode(referencesTreeMode)
        default: return
        }
        updateSidebarMenu()
    }

    @objc private func refreshSourceControl(_ sender: Any?) { sourceControl?.refresh() }
}
