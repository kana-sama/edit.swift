import AppKit

@MainActor
enum PanelLayout {
    static func finishHeaderLayout(_ item: NSToolbarItem, in window: NSWindow) {
        let previousLayer = item.view?.superview?.layer
        withoutAnimation {
            window.layoutIfNeeded()
            if let host = item.view?.window, host !== window { host.layoutIfNeeded() }
        }
        removeHeaderAnimations(from: previousLayer)
        removeHeaderAnimations(from: item.view?.layer)
        removeHeaderAnimations(from: item.view?.superview?.layer)
    }

    static func withoutAnimation(_ update: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            update()
            CATransaction.commit()
        }
    }

    private static func removeHeaderAnimations(from layer: CALayer?) {
        // AppKit can animate a toolbar item when it moves to another title-bar host.
        layer?.removeAnimation(forKey: #keyPath(CALayer.transform))
        layer?.removeAnimation(forKey: #keyPath(CALayer.opacity))
    }
}

@MainActor
final class EditorDocumentWindow: NSWindow {
    private weak var titlebarTrackingView: NSView?
    private var titlebarTrackingArea: NSTrackingArea?
    private var titlebarLayoutObservation: NSKeyValueObservation?

    func trackTitlebarPointer() {
        titlebarLayoutObservation = observe(\.contentLayoutRect, options: [.initial]) { window, _ in
            MainActor.assumeIsolated { window.updateTitlebarTrackingArea() }
        }
    }

    override func becomeKey() {
        updateTitlebarTrackingArea()
        super.becomeKey()
    }

    override func cursorUpdate(with event: NSEvent) {
        if (NSApp as? EditApplication)?.updatePointerCursor(in: self) == true { return }
        super.cursorUpdate(with: event)
    }

    private func updateTitlebarTrackingArea() {
        guard let view = contentView?.superview else { return }
        let top = contentLayoutRect.maxY
        let titlebar = NSRect(x: 0, y: top, width: frame.width, height: max(0, frame.height - top))
        let rect = view.convert(titlebar, from: nil).intersection(view.bounds)
        if titlebarTrackingView === view, titlebarTrackingArea?.rect == rect { return }
        if let area = titlebarTrackingArea { titlebarTrackingView?.removeTrackingArea(area) }
        titlebarTrackingView = view
        titlebarTrackingArea = nil
        guard !rect.isEmpty else { return }
        let area = NSTrackingArea(rect: rect, options: [.cursorUpdate, .activeInActiveApp], owner: self, userInfo: nil)
        view.addTrackingArea(area)
        titlebarTrackingArea = area
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, TerminalScrollView.routeWheel(event, in: self, at: event.locationInWindow) { return }
        super.sendEvent(event)
    }

    // Focused controls get Escape before it reaches these window-level fallbacks.
    override func cancelOperation(_ sender: Any?) {
        guard !isFullScreenEscape(NSApp.currentEvent) else { return }
        super.cancelOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        guard !isFullScreenEscape(event) else { return }
        super.keyDown(with: event)
    }

    private func isFullScreenEscape(_ event: NSEvent?) -> Bool {
        styleMask.contains(.fullScreen) && event?.type == .keyDown && event?.keyCode == 53
    }
}

@MainActor
final class DocumentWindow: NSObject, NSWindowDelegate {
    static let minimumEditorWidth: CGFloat = 128
    private static let minimumTerminalSidebarWidth: CGFloat = 160
    enum CloseChoice {
        case save(to: URL?)
        case discard
        case cancel
    }

    enum CloseDestination {
        case window
        case buffer(FileBuffer?, focusEditor: Bool = true, scratch: ScratchFile? = nil, folder: URL? = nil)
        case preview(OpenFilePreview, focusEditor: Bool, folder: URL? = nil)
        case sourceControlPreview(SourceControlRevisionPreview)
        case emptyFolder(focusContent: Bool, folder: URL? = nil)
    }

    let window: EditorDocumentWindow
    let editor: EditorTextView
    let scrollView: NSScrollView
    let editorContentView: NSView
    let documentSplitView = NSSplitView(frame: .zero)
    private var documentSplit: NSSplitViewController?
    private var terminalPanel: TerminalPanel?
    private var terminalDockView: TerminalDockView?
    private var terminalSidebar: NSSplitViewItem?
    private var terminalSidebarPanelConstraints: [NSLayoutConstraint] = []
    private var terminalTitleHost: NSView?
    private weak var terminalTitleWidthLimit: NSLayoutConstraint?
    private var terminalSidebarWidth = TerminalDockSizes().rightWidth
    private(set) var isTerminalVisible = false
    private var pendingTerminalRestore: DocumentTerminalState?
    private(set) lazy var titleBar = DocumentTitleBar(document: self, app: app)

    private unowned let app: Edit
    private(set) var fileURL: URL? {
        didSet {
            if oldValue != fileURL {
                fileRefresh.stop()
                scratchFile = nil
                detectedSyntaxLanguage = SyntaxLanguage.detected(at: fileURL)
            }
        }
    }
    private(set) var scratchFile: ScratchFile?
    private(set) var folderURL: URL?
    private var filePreview: OpenFilePreview?
    private var filePreviewView: FilePreviewView?
    private var emptyFolderView: EmptyFolderView?
    private var sourceControlRevision: SourceControlRevisionPreview?
    private(set) var sourceControlRevisionBanner: SourceControlRevisionBanner?
    private var editorTopConstraint: NSLayoutConstraint?
    private var filePreviewTopConstraint: NSLayoutConstraint?
    private var previewTopConstraint: NSLayoutConstraint?
    var isShowingFilePreview: Bool { filePreview != nil }
    var showsEmptyFolder: Bool { emptyFolderView != nil }
    var hasTextDocument: Bool { !isShowingFilePreview && !showsEmptyFolder }
    var hasEditableTextDocument: Bool { hasTextDocument && sourceControlRevision == nil }
    var displayedFileURL: URL? { sourceControlRevision == nil ? filePreview?.url ?? fileURL : nil }
    var fileIconURL: URL? { scratchFile?.filenameURL ?? displayedFileURL ?? sourceControlRevision?.url }
    var displayName: String { scratchFile?.name ?? fileIconURL?.lastPathComponent ?? "Untitled" }
    var hasJujutsuWorkspace: Bool { folderURL.map(JJRepository.hasWorkspace(at:)) ?? false }
    var contentResponder: NSView { (filePreviewView as NSView?) ?? (emptyFolderView as NSView?) ?? editor }

    func focusContent() {
        window.makeFirstResponder(contentResponder)
    }

    func setFolder(_ url: URL?) {
        guard folderURL != url else { return }
        folderURL = url
        if url == nil && showsEmptyFolder {
            let wasFocused = contentHasFocus
            removeEmptyFolder()
            activity.restoreEditabilityAfterMutation()
            editor.isEditable = !isBusy && !app.isQuitting
            if wasFocused { focusContent() }
        }
        updateTitle()
        sidebar.folderChanged()
    }

    private var detectedSyntaxLanguage: SyntaxLanguage = .plainText
    private(set) var fileIdentity: FileIdentity?
    private var savedText: NSString? = "" as NSString
    private var format = FileFormat()
    private var revision: FileRevision?
    private var normalFrame: NSRect?
    private var pendingFullScreen = false
    private let activity = DocumentActivity()
    private lazy var autosave = DocumentAutosave(document: self)
    private lazy var fileRefresh = DocumentFileRefresh(
        canRefresh: { [weak self] in self?.canRefreshFile == true },
        apply: { [weak self] in self?.applyExternalFile($0) }
    )
    private var draftRecoveryRevision: DraftRecoveryRevision?
    var draftRecoveryID: UUID? { draftRecoveryRevision?.id }
    private var draftCheckpoint: Task<Void, Never>?
    private var showedDraftRecoveryError = false
    private var syntaxHighlighting: SyntaxHighlighting?
    private(set) lazy var sidebar = DocumentSidebar(document: self, app: app)
    var findSettings = FindSettings() {
        didSet { updateOccurrenceFindSettings() }
    }
    var sidebarMode: SidebarMode { sidebar.mode }
    var isSidebarVisible: Bool { sidebar.isVisible }
    var isSearchSidebarVisible: Bool { sidebar.isSearchVisible }
    var worktreeSidebar: SidebarFileTree? { sidebar.worktree }
    var sourceControlSidebar: SourceControlSidebar? { sidebar.sourceControl }
    private var jjDocumentChanges: JJDocumentChanges?
    private var pendingSourceControlDiffFile: URL?
    var scratchOutline: NSOutlineView? { sidebar.scratchOutline }
    private var appearanceObservation: NSKeyValueObservation?
    private(set) var manualSyntaxLanguage: SyntaxLanguage?

    var resolvedSyntaxLanguage: SyntaxLanguage {
        manualSyntaxLanguage ?? detectedSyntaxLanguage
    }

    func setSyntaxLanguage(_ language: SyntaxLanguage?) {
        guard hasTextDocument, manualSyntaxLanguage != language else { return }
        manualSyntaxLanguage = language
        app.syntaxOverrides.set(language, for: fileURL)
        updateTitle()
        refreshSyntax(immediate: true)
    }

    var isBusy: Bool { activity.isBusy }
    var canReplaceBuffer: Bool { !isBusy && window.attachedSheet == nil }
    var canRequestOpen: Bool { window.attachedSheet == nil && activity.acceptsOpenRequest }
    var canRestoreSession: Bool {
        folderURL == nil && displayedFileURL == nil && !sidebar.hasContent && terminalPanel == nil && pendingTerminalRestore == nil &&
            !window.isDocumentEdited && autosave.generation == 0 && openRequestGeneration == 0 &&
            !editor.hasMarkedText() && canReplaceBuffer
    }

    var openRequestGeneration: UInt64 { activity.openGeneration }
    func beginOpenRequest() -> UInt64 { activity.beginOpenRequest() }

    init(app: Edit, placement: WindowPlacement? = nil) {
        self.app = app
        window = EditorDocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // SwiftTerm temporarily changes this window-wide setting and restores the value it found.
        window.acceptsMouseMovedEvents = true
        (scrollView, editor) = EditorTextView.scrollingEditor(in: window.contentLayoutRect)
        editorContentView = NSView(frame: scrollView.frame)
        super.init()
        // An ordered test window may need a live backing layer for AppKit drawing.
        if app.isAgentCheck {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        window.title = "Untitled"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.titleBar.update() }
        }
        window.contentView = editorContentView
        editorTopConstraint = pinToEditorContent(scrollView)
        window.toolbarStyle = .unifiedCompact
        window.toolbar = titleBar.toolbar
        window.trackTitlebarPointer()
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        editor.onTextChange = { [weak self] in self?.textDidChange() }
        editor.onFocusScopeChange = { [weak self] in
            guard let self else { return }
            self.sidebar.editorBufferReplaced()
            self.editor.occurrenceHighlighting.reset()
            self.editor.occurrenceHighlighting.selectionChanged()
        }
        editor.onBlur = { [weak self] in self?.editorLostFocus() }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedo(_:)), name: name, object: nil)
        }
        if let placement {
            restorePlacement(placement)
        } else {
            window.center()
        }
    }

    func installDocumentSplit() -> NSSplitViewController {
        if let documentSplit { return documentSplit }
        let size = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let frame = window.frame
        let responder = window.firstResponder as? NSView
        let editor = NSViewController()
        editor.view = editorContentView
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.automaticallyAdjustsSafeAreaInsets = true
        editorItem.minimumThickness = Self.minimumEditorWidth
        let split = NSSplitViewController()
        documentSplitView.isVertical = true
        documentSplitView.dividerStyle = .thin
        split.splitView = documentSplitView
        split.addSplitViewItem(editorItem)
        split.view.setFrameSize(size)
        window.contentViewController = split
        if window.frame != frame { window.setFrame(frame, display: window.isVisible) }
        window.initialFirstResponder = contentResponder
        if let responder, responder.window === window { window.makeFirstResponder(responder) }
        documentSplit = split
        NotificationCenter.default.addObserver(self, selector: #selector(documentSplitDidResize(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: documentSplitView)
        return split
    }

    var isTerminalDockedRight: Bool { terminalSidebar != nil }

    func terminalHasFocus(_ responder: NSResponder?) -> Bool {
        isTerminalVisible && terminalPanel?.containsTerminalResponder(responder) == true
    }

    func handleTerminalKey(_ event: NSEvent) -> Bool {
        guard !app.isQuitting, window.attachedSheet == nil else { return false }
        if TerminalShortcuts.isToggle(event) {
            if !event.isARepeat {
                if terminalHasFocus(window.firstResponder) { hideTerminal() }
                else { showTerminal() }
            }
            return true
        }
        guard terminalHasFocus(window.firstResponder) else { return false }
        if TerminalShortcuts.isClear(event) {
            if !event.isARepeat { terminalPanel?.clear() }
            return true
        }
        if TerminalShortcuts.isToggleContentWidth(event) {
            if !event.isARepeat { terminalPanel?.toggleContentWidth() }
            return true
        }
        guard let zoom = TerminalShortcuts.zoom(event) else { return false }
        terminalPanel?.zoom(zoom)
        return true
    }

    func toggleTerminal() {
        guard !app.isQuitting, window.attachedSheet == nil else { return }
        if isTerminalVisible { hideTerminal() }
        else { showTerminal() }
    }

    func showTerminal() {
        guard !app.isQuitting, window.attachedSheet == nil else { return }
        _ = attachTerminal(focusing: true)
    }

    func restoreTerminal(_ state: DocumentTerminalState?) {
        guard let state else { return }
        pendingTerminalRestore = state
        if pendingFullScreen, state.isVisible, state.panel.dock == .right {
            _ = installDocumentSplit()
        }
        restoreVisibleTerminalIfReady()
    }

    private func restoreVisibleTerminalIfReady() {
        // The normal frame can be smaller than the saved full-screen layout.
        guard !pendingFullScreen, let state = pendingTerminalRestore, state.isVisible else { return }
        let panel = attachTerminal()
        if state.wasFocused { panel.focusLastTerminal() }
    }

    private func attachTerminal(focusing: Bool = false) -> TerminalPanel {
        let panel: TerminalPanel
        if let terminalPanel {
            panel = terminalPanel
        } else {
            let saved = pendingTerminalRestore
            panel = TerminalPanel(
                directory: { [weak self] in
                    self?.folderURL ?? self?.displayedFileURL?.deletingLastPathComponent()
                        ?? FileManager.default.homeDirectoryForCurrentUser
                },
                onDockChange: { [weak self] dock in self?.moveTerminal(to: dock) },
                onLastShellExit: { [weak self] panelHadFocus in
                    guard let self, self.isTerminalVisible, !self.app.isQuitting else { return }
                    self.hideTerminal(restoringContentFocus: panelHadFocus)
                },
                launchShell: !app.isAgentCheck,
                restoredState: saved?.panel
            )
            terminalPanel = panel
            let sizes = saved?.sizes ?? TerminalDockSizes()
            terminalDockView = TerminalDockView(terminal: panel.view, height: sizes.belowHeight) { [weak self] height in
                self?.setEditorBottomInset(height)
            }
            if sizes.rightWidth.isFinite && sizes.rightWidth > 0 { terminalSidebarWidth = sizes.rightWidth }
            pendingTerminalRestore = nil
        }
        if focusing { panel.prepareSpace() }
        if !isTerminalVisible {
            isTerminalVisible = true
            moveTerminal(to: panel.dock)
            panel.setVisible(true)
        }
        if focusing { panel.focusLastTerminal() }
        return panel
    }

    private func terminalSessionState() -> DocumentTerminalState? {
        guard let terminalPanel, let terminalDockView else { return pendingTerminalRestore }
        let rightWidth = currentTerminalSidebarWidth
        let sizes = TerminalDockSizes(belowHeight: terminalDockView.savedHeight, rightWidth: rightWidth)
        return DocumentTerminalState(panel: terminalPanel.snapshot(), sizes: sizes,
                                     isVisible: isTerminalVisible, wasFocused: terminalHasFocus(window.firstResponder))
    }

    private func moveTerminal(to dock: TerminalDock) {
        guard let terminalPanel, isTerminalVisible else { return }
        let alreadyDocked = dock == .right ? terminalSidebar != nil : terminalDockView?.superview != nil
        guard !alreadyDocked else { return }
        updateTerminalLayout {
            detachTerminalPanel()
            if dock == .right {
                showTerminalSidebar(terminalPanel)
            } else {
                terminalDockView?.show(in: editorContentView)
            }
        }
    }

    private func showTerminalSidebar(_ panel: TerminalPanel) {
        let split = installDocumentSplit()
        let controller = NSViewController()
        let host = NSView()
        host.clipsToBounds = true
        controller.view = host
        let item = NSSplitViewItem(inspectorWithViewController: controller)
        item.allowsFullHeightLayout = true
        item.canCollapse = false
        item.minimumThickness = Self.minimumTerminalSidebarWidth
        item.maximumThickness = NSSplitViewItem.unspecifiedDimension
        item.preferredThicknessFraction = min(0.75, terminalSidebarWidth / max(documentSplitView.bounds.width, 1))

        let titleHost = NSView()
        let widthLimit = titleHost.widthAnchor.constraint(lessThanOrEqualToConstant: Self.minimumTerminalSidebarWidth)
        NSLayoutConstraint.activate([widthLimit, titleHost.heightAnchor.constraint(equalToConstant: 26)])
        terminalTitleHost = titleHost
        terminalTitleWidthLimit = widthLimit
        panel.fitDockedHeader(to: Self.minimumTerminalSidebarWidth)

        terminalSidebar = item
        split.addSplitViewItem(item)
        host.addSubview(panel.view)
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        terminalSidebarPanelConstraints = [
            panel.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.view.topAnchor.constraint(equalTo: host.topAnchor),
            panel.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        NSLayoutConstraint.activate(terminalSidebarPanelConstraints)
        panel.placeHeader(in: titleHost, contentTop: documentSplitView.safeAreaLayoutGuide.topAnchor)

        window.layoutIfNeeded()
        documentSplitView.setPosition(documentSplitView.bounds.maxX - terminalSidebarWidth,
                                      ofDividerAt: split.splitViewItems.count - 2)
        // AppKit reapplies a preferred fraction when entering full screen.
        item.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        resizeTitleBars()
        titleBar.setTerminalDocked(true)
    }

    private var currentTerminalSidebarWidth: CGFloat {
        terminalSidebar?.viewController.view.frame.width ?? terminalSidebarWidth
    }

    private func visibleTerminalSidebarWidth(_ item: NSSplitViewItem) -> CGFloat {
        let view = item.viewController.view
        guard view.window === window else { return 0 }
        return view.frame.width
    }

    func makeTerminalTitleItem() -> NSToolbarItem? {
        guard let host = terminalTitleHost else { return nil }
        host.isHidden = false
        let item = NSToolbarItem(itemIdentifier: DocumentTitleBar.terminalItemIdentifier)
        item.label = "Terminal Spaces"
        item.isBordered = false
        item.autovalidates = false
        item.visibilityPriority = .high
        item.view = host
        return item
    }

    private func resizeTitleBars() {
        if let sidebar = terminalSidebar, let widthLimit = terminalTitleWidthLimit {
            let width = visibleTerminalSidebarWidth(sidebar)
            let limit = max(Self.minimumTerminalSidebarWidth, width)
            if widthLimit.constant != limit {
                widthLimit.constant = limit
                terminalPanel?.fitDockedHeader(to: limit)
            }
        }
        titleBar.resize()
    }

    @objc private func documentSplitDidResize(_ notification: Notification) {
        guard terminalSidebar != nil else { return }
        resizeTitleBars()
    }

    private func detachTerminalPanel() {
        terminalDockView?.hide()
        guard let terminalSidebar else { return }
        let width = currentTerminalSidebarWidth
        if width > 0 { terminalSidebarWidth = width }
        titleBar.setTerminalDocked(false)
        terminalPanel?.placeHeader(in: nil)
        terminalTitleHost = nil
        terminalTitleWidthLimit = nil
        NSLayoutConstraint.deactivate(terminalSidebarPanelConstraints)
        terminalSidebarPanelConstraints.removeAll()
        terminalPanel?.view.removeFromSuperview()
        self.terminalSidebar = nil
        documentSplit?.removeSplitViewItem(terminalSidebar)
        resizeTitleBars()
    }

    private func hideTerminal(restoringContentFocus: Bool = true) {
        guard isTerminalVisible else { return }
        isTerminalVisible = false
        terminalPanel?.setVisible(false)
        if restoringContentFocus { focusContent() }
        let responder = window.firstResponder
        updateTerminalLayout { detachTerminalPanel() }
        if let responder = responder as? NSView, responder.window === window, window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
    }

    private func updateTerminalLayout(_ change: () -> Void) {
        let origin = scrollView.visibleContentOrigin
        PanelLayout.withoutAnimation {
            change()
            window.layoutIfNeeded()
            scrollView.scrollToVisibleContentOrigin(origin)
        }
    }

    private func setEditorBottomInset(_ height: CGFloat) {
        for case let view? in [scrollView as NSView?, filePreviewView, emptyFolderView] {
            var insets = view.additionalSafeAreaInsets
            guard insets.bottom != height else { continue }
            insets.bottom = height
            view.additionalSafeAreaInsets = insets
        }
    }

    @objc func splitTerminalFromControl(_ item: NSMenuItem) {
        guard isTerminalVisible, window.attachedSheet == nil, !app.isQuitting,
              let direction = item.representedObject as? TerminalSplitDirection else { return }
        terminalPanel?.split(direction)
    }

    func closeTerminalSessions() {
        terminalPanel?.close()
    }

    func canPerformFind(_ command: FindCommand) -> Bool {
        guard window.attachedSheet == nil else { return false }
        if !hasTextDocument { return command == .toggleSidebar }
        if !hasEditableTextDocument && (command == .replace || command == .toggleReplace) { return false }
        return sidebar.canPerformFind(command)
    }

    func performFind(_ command: FindCommand) {
        guard !app.isQuitting, window.attachedSheet == nil, canPerformFind(command) else { return }
        sidebar.performFind(command)
    }

    func canFocusSidebar(_ mode: SidebarMode) -> Bool {
        guard !app.isQuitting, window.attachedSheet == nil else { return false }
        return switch mode {
        case .search: hasTextDocument
        case .worktree: folderURL != nil
        case .sourceControl: hasJujutsuWorkspace
        case .scratches: true
        }
    }

    func toggleSidebarFocus(_ mode: SidebarMode) {
        guard canFocusSidebar(mode) else { return }
        sidebar.toggleFocus(of: mode)
    }

    func recheckJujutsuSidebar(available: Bool) { sidebar.recheckJujutsuAvailability(available) }

    func updateOccurrenceFindSettings() {
        editor.occurrenceHighlighting.updateFind(options: findSettings.options,
                                                 activeQuery: sidebar.isSearchVisible ? findSettings.query : nil)
    }

    func restoreSidebar(_ record: SessionDocument) {
        // Older sessions omitted the mode for Search even when they saved its sidebar state.
        let saved = record.findSettings
        if let saved { findSettings = saved.search }
        sidebar.restore(mode: record.sidebarMode ?? (saved == nil ? nil : .search),
                        width: saved?.width ?? SessionFindSettings.defaultWidth, visible: saved?.visible ?? false,
                        showsHidden: record.worktreeShowsHidden ?? false)
    }

    func present() {
        window.makeKeyAndOrderFront(nil)
        if pendingFullScreen { app.scheduleFullScreenRestore(for: self) }
    }

    func restoreFullScreen() -> Bool {
        guard pendingFullScreen && window.isVisible else { return false }
        normalFrame = window.frame
        window.toggleFullScreen(nil)
        return true
    }

    func restorePlacement(_ placement: WindowPlacement) {
        placement.restoreFrame(on: window)
        pendingFullScreen = placement.isFullScreen && !window.styleMask.contains(.fullScreen)
    }

    var placement: WindowPlacement {
        let fullScreen = window.styleMask.contains(.fullScreen) || pendingFullScreen
        let frame = fullScreen ? normalFrame ?? window.frame : window.frame
        return WindowPlacement(frame: frame, isFullScreen: fullScreen)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if normalFrame == nil { normalFrame = window.frame }
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        proposedOptions.subtracting(.autoHideToolbar)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        pendingFullScreen = false
        restoreVisibleTerminalIfReady()
        resizeTitleBars()
        titleBar.fullScreenTransitionDidFinish()
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        pendingFullScreen = false
        restoreVisibleTerminalIfReady()
        titleBar.fullScreenTransitionDidFinish()
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        normalFrame = nil
        resizeTitleBars()
        titleBar.fullScreenTransitionDidFinish()
    }

    func windowDidResignKey(_ notification: Notification) {
        editorLostFocus()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        editorLostFocus()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reportAutosaveFailure()
        jjDocumentChanges?.recheck()
        app.updateJujutsuShortcut()
    }

    func windowDidEndSheet(_ notification: Notification) {
        fileRefresh.resume()
        Task { @MainActor [weak self] in self?.reportAutosaveFailure() }
    }

    func checkForExternalFileChanges() { fileRefresh.check() }

    private func editorLostFocus() {
        requestAutosave()
        checkForExternalFileChanges()
    }

    private var canRefreshFile: Bool {
        canReplaceBuffer && !app.isQuitting && !window.isDocumentEdited && !autosave.hasWorker &&
            !editor.hasMarkedText() && !(NSApp.isActive && window.isKeyWindow && contentHasFocus)
    }

    private func applyExternalFile(_ file: FileBuffer) {
        let changedText = savedText?.isEqual(to: file.text) != true
        let position = changedText ? editor.capturePosition() : nil
        let changedRevision = revision != file.revision
        // The clean buffer may have a queued snapshot from before an undo.
        autosave.reset()
        updateIdentity(from: file)
        if changedText {
            installText(file.text, revealInWorktree: false)
            restoreEditorPosition(position)
        } else if changedRevision {
            updateJJContext()
        }
    }

    func load(
        _ file: FileBuffer, storedSyntaxLanguage: String? = nil, preparedSyntax: SyntaxSnapshot? = nil, scratch: ScratchFile? = nil
    ) {
        removeSourceControlRevision()
        removeFilePreview()
        removeEmptyFolder()
        updateIdentity(from: file)
        scratchFile = scratch
        if let scratch { detectedSyntaxLanguage = SyntaxLanguage.detected(at: scratch.filenameURL) }
        manualSyntaxLanguage = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: fileURL)
        installText(file.text, preparedSyntax: preparedSyntax)
    }

    func prepareOpeningSyntax(
        _ file: FileBuffer, position: EditorPosition?, storedSyntaxLanguage: String? = nil, scratch: ScratchFile? = nil
    ) async -> SyntaxSnapshot? {
        let language = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: file.url) ?? SyntaxLanguage.detected(at: scratch?.filenameURL ?? file.url)
        guard language != .plainText, position?.topLine != nil || (position?.verticalOffset ?? 0) <= 0 else { return nil }
        let topOffset = position?.topLine?.textOffset ?? 0
        let lineHeight = max(1, editor.defaultParagraphStyle?.maximumLineHeight ?? 18)
        let visibleLines = Int(ceil(scrollView.bounds.height / lineHeight)) + 2
        let task = Task.detached(priority: .userInitiated) {
            SyntaxEngine.prepareOpening(file.text, language: language, topOffset: topOffset, visibleLines: visibleLines)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func loadPreview(_ preview: OpenFilePreview, revealInWorktree: Bool = true) {
        removeSourceControlRevision()
        installFilePreview(preview, revealInWorktree: revealInWorktree)
    }

    private func installFilePreview(_ preview: OpenFilePreview, revealInWorktree: Bool) {
        let view = FilePreviewView(preview: preview)
        removeFilePreview()
        removeEmptyFolder()
        filePreview = preview
        fileURL = nil
        fileIdentity = preview.identity
        manualSyntaxLanguage = nil
        savedText = "" as NSString
        format = FileFormat()
        revision = nil
        editor.isEditable = false
        filePreviewView = view
        filePreviewTopConstraint = pinToEditorContent(view)
        window.initialFirstResponder = view
        scrollView.isHidden = true
        installText("", revealInWorktree: revealInWorktree)
    }

    private func removeFilePreview() {
        guard let filePreviewView else { return }
        window.initialFirstResponder = editor
        self.filePreviewView = nil
        filePreview = nil
        filePreviewTopConstraint = nil
        filePreviewView.stop()
        filePreviewView.removeFromSuperview()
        scrollView.isHidden = false
    }

    func openSourceControlFile(
        _ file: JJSourceControlFile, in change: JJSourceControlRevision, workspace: JJWorkspace,
        operationID: String, while isWanted: @escaping () -> Bool
    ) async -> Bool {
        guard canRequestOpen, isWanted(), !app.isQuitting else { return false }
        let url = workspace.root.appending(path: file.path, directoryHint: .notDirectory)
        let folder = folderURL
        let opensWorkingCopy = change.isWorkingCopy && !file.isDeleted
        let metadata = opensWorkingCopy ? SourceControlRevisionPreview.metadata(for: file, at: url) : nil
        do {
            if opensWorkingCopy && metadata == nil {
                guard try await app.openFile(url, in: self, focusEditor: false, shouldOpen: isWanted) != nil,
                      isWanted(), !Task.isCancelled else { return false }
                if let fileURL, hasEditableTextDocument {
                    pendingSourceControlDiffFile = editor.jjInlineDiff?.expandAll() == true ? nil : fileURL
                }
                return true
            }

            let generation = beginOpenRequest()
            let isCurrent = { [self] in
                !Task.isCancelled && !app.isQuitting && openRequestGeneration == generation && folderURL == folder &&
                    isWanted() && app.documents.contains(where: { $0 === self })
            }
            if let metadata { return await open(.preview(metadata, focusEditor: false), while: isCurrent) }
            let contents = try await JJSourceControlRepository.file(file, in: change, workspace: workspace, at: operationID)
            guard isCurrent() else { return false }
            let preview = try await SourceControlRevisionPreview.prepare(contents, file: file, revision: change, at: url)
            return await open(.sourceControlPreview(preview), while: isCurrent)
        } catch {
            if isWanted(), !app.isQuitting, !Task.isCancelled, canReplaceBuffer,
               app.documents.contains(where: { $0 === self }) {
                await showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
            }
            return false
        }
    }

    private func loadSourceControlRevision(_ preview: SourceControlRevisionPreview) {
        removeSourceControlRevision()
        removeFilePreview()
        removeEmptyFolder()
        autosave.reset()
        sourceControlRevision = preview
        switch preview.content {
        case .text(let text, let format, let analysis):
            fileURL = nil
            fileIdentity = nil
            revision = nil
            manualSyntaxLanguage = nil
            detectedSyntaxLanguage = .detected(at: preview.url)
            savedText = text as NSString
            self.format = format
            editor.isEditable = false
            installText(text)
            editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks)
            editor.jjInlineDiff?.expandAll()
        case .media(let media):
            installFilePreview(media, revealInWorktree: false)
        }

        let banner = SourceControlRevisionBanner(preview)
        sourceControlRevisionBanner = banner
        let content = filePreviewView as NSView? ?? scrollView
        let oldTop = filePreviewTopConstraint ?? editorTopConstraint
        editorContentView.addSubview(banner)
        oldTop?.isActive = false
        let newTop = content.topAnchor.constraint(equalTo: banner.bottomAnchor)
        previewTopConstraint = newTop
        let guide = editorContentView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: guide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            newTop,
        ])
    }

    private func removeSourceControlRevision() {
        guard sourceControlRevision != nil else { return }
        sourceControlRevision = nil
        editor.setJJLineMarks([])
        previewTopConstraint?.isActive = false
        previewTopConstraint = nil
        sourceControlRevisionBanner?.removeFromSuperview()
        sourceControlRevisionBanner = nil
        (filePreviewTopConstraint ?? editorTopConstraint)?.isActive = true
    }

    func loadEmptyFolder() {
        removeSourceControlRevision()
        removeFilePreview()
        if !showsEmptyFolder {
            let view = EmptyFolderView()
            emptyFolderView = view
            pinToEditorContent(view)
            window.initialFirstResponder = view
            scrollView.isHidden = true
        }
        editor.isEditable = false
        resetDocument()
    }

    private func removeEmptyFolder() {
        guard let view = emptyFolderView else { return }
        emptyFolderView = nil
        window.initialFirstResponder = editor
        view.removeFromSuperview()
        scrollView.isHidden = false
    }

    private func resetDocument() {
        fileURL = nil
        manualSyntaxLanguage = nil
        fileIdentity = nil
        savedText = "" as NSString
        format = FileFormat()
        revision = nil
        autosave.clearFailure()
        installText("")
    }

    @discardableResult
    private func pinToEditorContent(_ view: NSView) -> NSLayoutConstraint {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let dock = terminalDockView, dock.superview === editorContentView {
            editorContentView.addSubview(view, positioned: .below, relativeTo: dock)
        } else {
            editorContentView.addSubview(view)
        }
        let top = view.topAnchor.constraint(equalTo: editorContentView.topAnchor)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: editorContentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: editorContentView.trailingAnchor),
            top,
            view.bottomAnchor.constraint(equalTo: editorContentView.bottomAnchor),
        ])
        setEditorBottomInset(terminalDockView?.coveredHeight ?? 0)
        return top
    }

    func restoreDraft(_ record: SessionDocument, text: String, identity: FileIdentity? = nil, scratch: ScratchFile? = nil) {
        removeSourceControlRevision()
        fileRefresh.stop()
        fileURL = record.path.map { URL(fileURLWithPath: $0) }
        scratchFile = scratch
        if let scratch { detectedSyntaxLanguage = SyntaxLanguage.detected(at: scratch.filenameURL) }
        fileIdentity = identity
        savedText = fileURL == nil ? "" as NSString : nil
        format = record.format ?? FileFormat()
        revision = record.revision
        manualSyntaxLanguage = record.syntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: fileURL)
        installText(text)
        if fileURL == nil {
            draftRecoveryRevision = record.draftRecovery
            scheduleDraftCheckpoint()
        }
    }

    func sessionDocument() -> SessionDocument {
        let savedFind = SessionFindSettings(search: findSettings, sidebarVisible: sidebar.isVisible, sidebarWidth: sidebar.width)
        return SessionDocument(
            path: displayedFileURL?.path,
            draft: window.isDocumentEdited ? editor.string : nil,
            format: fileURL == nil ? nil : format,
            revision: revision,
            placement: placement,
            syntaxLanguage: manualSyntaxLanguage?.rawValue,
            folderPath: folderURL?.path,
            findSettings: savedFind == .empty ? nil : savedFind,
            editorPosition: hasEditableTextDocument ? editor.capturePosition() : nil,
            sidebarMode: sidebar.rememberedMode,
            worktreeShowsHidden: sidebar.worktreeShowsHidden ? true : nil,
            isFilePreview: displayedFileURL != nil && isShowingFilePreview ? true : nil,
            showsEmptyFolder: folderURL != nil && displayedFileURL == nil ? showsEmptyFolder || sourceControlRevision != nil : nil,
            terminal: terminalSessionState(),
            draftRecovery: draftRecoveryRevision
        )
    }

    func restoreEditorPosition(_ position: EditorPosition?) {
        guard hasTextDocument, let position else { return }
        // AppKit calculates the titlebar inset during layout, including in a window not presented yet.
        window.layoutIfNeeded()
        editor.restorePosition(position)
    }

    func rememberFilePosition(_ position: EditorPosition? = nil) {
        guard let fileURL, let fileIdentity else { return }
        app.recentFiles.rememberPosition(position ?? editor.capturePosition(), for: fileURL, identity: fileIdentity)
    }

    @discardableResult
    func save(
        asNew: Bool = false, to selectedURL: URL? = nil, encoding: FileTextEncoding? = nil,
        duringWorkspaceMutation: Bool = false
    ) async -> Bool {
        guard hasEditableTextDocument, activity.beginSave(duringWorkspaceMutation: duringWorkspaceMutation) else { return false }
        if editor.hasMarkedText() { editor.unmarkText() }
        defer {
            activity.endSave()
            autosave.resume()
            autosaveDidFinish()
        }
        await autosave.waitForWrite()
        if selectedURL == nil, !asNew, fileURL != nil, revision != .missing, !window.isDocumentEdited {
            return true
        }

        var destination = selectedURL ?? fileURL
        var saveFormat = format.using(encoding ?? format.encoding)
        if selectedURL == nil, destination == nil || asNew {
            guard !app.isAgentCheck else { return false }
            let panel = makeSavePanel()
            let accessory = SavePanelAccessory(selected: saveFormat.encoding, scratchPanel: fileURL == nil ? panel : nil)
            panel.accessoryView = accessory
            let result = await response(to: panel)
            if let name = accessory.scratchName {
                return await saveScratchFromPanel(name: name, encoding: accessory.selection)
            }
            guard result == .OK else { return false }
            destination = panel.url
            saveFormat = saveFormat.using(accessory.selection)
        }
        guard let destination else { return false }
        let (target, identity) = await Task.detached {
            let url = FileBuffer.canonicalURL(destination)
            return (url, FileIdentity.at(url))
        }.value
        let promote = asNew || target != fileURL || revision == .missing
        guard app.reserveSave(to: target, identity: identity, for: self,
                              duringWorkspaceMutation: duringWorkspaceMutation) else {
            await showError("The file is in use by another window.")
            return false
        }
        defer { app.finishSave(to: target) }

        let text = editor.string
        let writtenGeneration = autosave.generation
        let expected = target == fileURL ? revision : nil

        do {
            do {
                try await write(text, to: target, format: saveFormat, expected: expected)
            } catch FileBufferError.changedOnDisk {
                guard !app.isAgentCheck else {
                    await showError("The file changed on disk.")
                    return false
                }
                let conflictingRevision = try await Task.detached { try FileBuffer.revision(at: target) }.value
                let alert = NSAlert()
                alert.messageText = "The file changed on disk."
                alert.informativeText = "Replace the on-disk version of “\(target.lastPathComponent)” with the text in Edit?"
                alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
                alert.addButton(withTitle: "Replace").hasDestructiveAction = true
                guard await response(to: alert) == .alertSecondButtonReturn else { return false }
                try await write(text, to: target, format: saveFormat, expected: conflictingRevision)
            }
            autosave.didSave(through: writtenGeneration)
            if promote && !app.scratchStore.identifiesScratch(at: target) {
                await app.recentFiles.record(destination, in: folderURL)
            }
            return true
        } catch {
            await showError("Could Not Save “\(target.lastPathComponent)”", detail: error.localizedDescription)
            return false
        }
    }

    func saveAsScratch() async {
        guard canReplaceBuffer, hasEditableTextDocument, !app.isQuitting, activity.beginSave() else { return }
        defer {
            activity.endSave()
            autosave.resume()
            autosaveDidFinish()
        }
        if editor.hasMarkedText() { editor.unmarkText() }
        await autosave.waitForWrite()
        let known = (try? await app.scratchStore.files()) ?? []
        let folders = app.recentFiles.folders.map(\.canonicalURL) + known.compactMap { file in
            file.folderPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
        }
        let sheet = ScratchSaveSheet(
            window: window, name: fileURL == nil ? "Untitled.txt" : displayName,
            folders: folders, selectedFolder: folderURL
        ) { [self] name, folder in
            _ = try await saveScratch(name: name, folder: folder)
        }
        await sheet.run()
    }

    private func saveScratchFromPanel(name: String, encoding: FileTextEncoding) async -> Bool {
        do {
            _ = try await saveScratch(name: name, folder: folderURL, encoding: encoding)
            return true
        } catch {
            await showError("Could Not Save Scratch", detail: error.localizedDescription)
            return false
        }
    }

    func saveScratch(name: String, folder: URL?, encoding: FileTextEncoding? = nil) async throws -> ScratchFile {
        let text = editor.string
        let writtenGeneration = autosave.generation
        let saveFormat = format.using(encoding ?? format.encoding)
        let (scratch, buffer) = try await app.scratchStore.create(name: name, text: text, format: saveFormat,
                                                                  in: folder, openedAt: Date())
        adoptSavedFile(buffer, scratch: scratch)
        autosave.didSave(through: writtenGeneration)
        app.scratchesDidChange()
        return scratch
    }

    private func write(_ text: String, to target: URL, format: FileFormat, expected: FileRevision?) async throws {
        let result = try await Task.detached {
            try FileBuffer.save(text, to: target, format: format, expected: expected)
        }.value
        if let previous = result.replacedIdentity, let current = result.file.identity {
            for document in app.documents { document.worktreeSidebar?.fileReplaced(previous, with: current) }
        }
        adoptSavedFile(result.file)
    }

    private func adoptSavedFile(_ file: FileBuffer, scratch: ScratchFile? = nil) {
        let changedPath = fileURL != file.url
        if changedPath { discardDraftCheckpoint() }
        if changedPath { rememberFilePosition() }
        let previousLanguage = resolvedSyntaxLanguage
        updateIdentity(from: file)
        if let scratch {
            scratchFile = scratch
            detectedSyntaxLanguage = SyntaxLanguage.detected(at: scratch.filenameURL)
        }
        if changedPath {
            app.syntaxOverrides.set(manualSyntaxLanguage, for: fileURL)
        }
        if resolvedSyntaxLanguage != previousLanguage {
            refreshSyntax(immediate: true)
        }
        updateTitle()
        updateEditedState()
        autosave.clearFailure()
    }

    var canScheduleAutosave: Bool {
        fileURL != nil && !app.isQuitting && (window.isDocumentEdited || autosave.hasWorker || activity.isSaving)
    }

    var canRunAutosave: Bool { !isBusy && !app.isQuitting }

    func requestAutosave() { autosave.request() }

    func autosaveDidFinish() {
        fileRefresh.resume()
        reportAutosaveFailure()
    }

    // Closing, replacing, and quitting hold off new writes while draining the queue.
    func flushAutosave() async { await autosave.flush() }

    func writeAutosave(_ text: String) async throws {
        guard let target = fileURL, let revision, savedText?.isEqual(to: text) != true else { return }
        guard app.reserveSave(to: target, identity: fileIdentity, for: self) else {
            throw DocumentAutosave.WriteError.inUse
        }
        defer { app.finishSave(to: target) }
        try await write(text, to: target, format: format, expected: revision)
    }

    func worktreeMutationAffects(_ sources: [URL]) -> Bool {
        sources.contains { source in
            [displayedFileURL, folderURL].compactMap { $0 }.contains { Self.worktreePathSuffix(from: source, to: $0) != nil }
        }
    }

    func beginWorktreeMutation() {
        if editor.hasMarkedText() { editor.unmarkText() }
        activity.beginMutation(wasEditable: editor.isEditable)
        editor.isEditable = false
        autosave.cancelIdle()
    }

    func waitForWorktreeWrites() async {
        await autosave.waitForWrite()
    }

    func finishWorktreeMutation() {
        let wasEditable = activity.endMutation()
        editor.isEditable = hasEditableTextDocument && wasEditable
        autosave.resume()
        if !autosave.hasWorker { autosave.scheduleIdle() }
        fileRefresh.resume()
    }

    @discardableResult
    func performSourceControlMutation(
        in workspace: JJWorkspace, operation: @MainActor () async throws -> Void
    ) async throws -> Bool {
        let affected = app.documents.filter { document in
            document.fileURL.map { Self.worktreePathSuffix(from: workspace.root, to: $0) != nil } == true
        }
        return try await app.performWorktreeMutation(affecting: [workspace.root]) {
            var discarded: Set<ObjectIdentifier> = []
            for document in affected where document.window.isDocumentEdited {
                guard let folder = document.fileURL?.deletingLastPathComponent() else { continue }
                if let owner = await JJRepository.discover(at: folder), owner != workspace { continue }
                guard !Task.isCancelled, !app.isAgentCheck else { return false }
                if document !== self && !document.window.isKeyWindow { document.window.makeKeyAndOrderFront(nil) }
                let choice = await document.confirmNamedClose(
                    consequence: "Continuing without saving discards your edits if the repository operation succeeds."
                )
                switch choice {
                case .save:
                    guard await document.save(duringWorkspaceMutation: true), !document.window.isDocumentEdited else {
                        return false
                    }
                case .discard:
                    discarded.insert(ObjectIdentifier(document))
                case .cancel:
                    return false
                }
            }
            try Task.checkCancellation()
            do {
                try await operation()
            } catch {
                for document in affected { await document.refreshAfterSourceControlMutation(discard: false) }
                throw error
            }
            for document in affected {
                await document.refreshAfterSourceControlMutation(discard: discarded.contains(ObjectIdentifier(document)))
            }
            return true
        }
    }

    private func refreshAfterSourceControlMutation(discard: Bool) async {
        guard let url = fileURL, discard || !window.isDocumentEdited else { return }
        guard let disk = try? await Task.detached(operation: { try FileBuffer.revision(at: url) }).value,
              disk != revision || discard else { return }
        let wasFocused = contentHasFocus
        if disk == .missing {
            autosave.reset()
            rememberFilePosition()
            if folderURL != nil { loadEmptyFolder() }
            else { resetDocument() }
            if wasFocused { focusContent() }
            return
        }
        let position = editor.capturePosition()
        switch try? await Edit.readForOpening(url) {
        case .text(let file):
            if discard {
                autosave.reset()
                updateIdentity(from: file)
                installText(file.text, revealInWorktree: false)
            } else {
                applyExternalFile(file)
            }
            restoreEditorPosition(position)
        case .preview(let preview):
            autosave.reset()
            loadPreview(preview, revealInWorktree: false)
            if wasFocused { focusContent() }
        case nil:
            fileRefresh.check()
        }
    }

    func retargetMovedFile(from source: URL, to destination: URL, revealInWorktree: Bool = true) {
        if let folderURL, let suffix = Self.worktreePathSuffix(from: source, to: folderURL) {
            let movedFolder = suffix.isEmpty ? destination : destination.appending(path: suffix, directoryHint: .isDirectory)
            setFolder(URL(filePath: movedFolder.path, directoryHint: .isDirectory))
        }
        guard let original = displayedFileURL, let suffix = Self.worktreePathSuffix(from: source, to: original) else { return }
        let movedFile = suffix.isEmpty ? destination : destination.appending(path: suffix, directoryHint: .notDirectory)
        let movedURL = URL(filePath: movedFile.path, directoryHint: .notDirectory)
        if let filePreview {
            let wasFocused = contentHasFocus
            loadPreview(OpenFilePreview(url: movedURL, identity: FileIdentity.at(movedURL),
                                        reason: filePreview.reason, details: filePreview.details),
                        revealInWorktree: revealInWorktree)
            if wasFocused { focusContent() }
            let folder = folderURL
            Task { await app.recentFiles.record(movedURL, in: folder) }
            return
        }
        let previousLanguage = resolvedSyntaxLanguage
        fileURL = movedURL
        fileIdentity = fileURL.flatMap { FileIdentity.at($0) }
        if revision != nil, revision != .missing { fileRefresh.observe(movedURL, stamp: nil) }
        if let manualSyntaxLanguage {
            app.syntaxOverrides.set(nil, for: original)
            app.syntaxOverrides.set(manualSyntaxLanguage, for: fileURL)
        }
        autosave.clearFailure()
        updateTitle(revealInWorktree: revealInWorktree)
        if resolvedSyntaxLanguage != previousLanguage { refreshSyntax(immediate: true) }
        if let fileURL {
            let recents = app.recentFiles
            let folder = folderURL
            Task { await recents.record(fileURL, in: folder) }
        }
    }

    func detachTrashedFile(at source: URL) {
        if let folderURL, Self.worktreePathSuffix(from: source, to: folderURL) != nil { setFolder(nil) }
        guard let displayedFileURL, Self.worktreePathSuffix(from: source, to: displayedFileURL) != nil else { return }
        let wasPreview = isShowingFilePreview
        let wasFocused = contentHasFocus
        removeFilePreview()
        if wasPreview { activity.restoreEditabilityAfterMutation() }
        let edited = window.isDocumentEdited
        let previousLanguage = resolvedSyntaxLanguage
        self.fileURL = nil
        fileIdentity = nil
        savedText = "" as NSString
        revision = nil
        autosave.reset()
        if edited {
            manualSyntaxLanguage = previousLanguage == .plainText ? nil : previousLanguage
            updateTitle()
            updateEditedState()
            scheduleDraftCheckpoint()
        } else {
            manualSyntaxLanguage = nil
            format = FileFormat()
            installText("")
        }
        if wasPreview && wasFocused { focusContent() }
    }

    private var contentHasFocus: Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view.isDescendant(of: contentResponder)
    }

    static func worktreePathSuffix(from source: URL, to file: URL) -> String? {
        let sourcePath = WorktreeFileOperations.path(source)
        let filePath = WorktreeFileOperations.path(file)
        if sourcePath == filePath { return "" }
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : nil
    }

    func takeAutosaveFailure() -> String? {
        guard window.isDocumentEdited, let detail = autosave.takeFailure() else { return nil }
        return "“\(displayName)” — \(detail)"
    }

    func reportAutosaveFailure() {
        guard window.isDocumentEdited, !isBusy, !app.isQuitting, !app.isAgentCheck, window.isKeyWindow,
              NSApplication.shared.isActive, window.attachedSheet == nil, let detail = autosave.takeFailure() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Autosave “\(displayName)”"
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    @objc private func undoOrRedo(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager, manager === editor.undoManager else { return }
        editor.bracketNavigation.reset()
        editor.occurrenceHighlighting.contentChanged()
        editor.requestLineRefresh()
        textDidChange()
    }

    private func textDidChange() {
        pendingSourceControlDiffFile = nil
        autosave.noteEdit()
        updateEditedState()
        scheduleDraftCheckpoint()
        autosave.scheduleIdle()
        refreshSyntax(immediate: false)
        jjDocumentChanges?.bufferChanged()
    }

    private func refreshSyntax(immediate: Bool, preparedSyntax: SyntaxSnapshot? = nil) {
        let language = resolvedSyntaxLanguage
        editor.bracketNavigation.setLanguage(language)
        editor.occurrenceHighlighting.update(language: language)
        if language == .plainText {
            syntaxHighlighting?.cancel()
            return
        }
        if syntaxHighlighting == nil {
            syntaxHighlighting = SyntaxHighlighting(editor: editor)
        }
        if let preparedSyntax, preparedSyntax.language == language {
            syntaxHighlighting?.install(preparedSyntax)
        } else {
            syntaxHighlighting?.update(language: language, immediate: immediate)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        if folderURL != nil {
            // Holding Command-W must not dispatch both steps of a project close.
            if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat,
               event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" { return false }
            if !showsEmptyFolder {
                activity.beginClose(invalidateOpenRequests: true)
                Task { await closeBuffer(destination: .emptyFolder(focusContent: true)) }
                return false
            }
        }
        guard window.isDocumentEdited || autosave.hasWorker else { return true }
        activity.beginClose()
        Task { await closeBuffer(destination: .window) }
        return false
    }

    func newBuffer() async {
        guard canReplaceBuffer, !app.isQuitting else { return }
        activity.beginClose(invalidateOpenRequests: true)
        await closeBuffer(destination: .buffer(nil))
    }

    func open(_ destination: CloseDestination, while isCurrent: () -> Bool) async -> Bool {
        await activity.waitForOpenReplacement()
        guard canReplaceBuffer, isCurrent() else { return false }
        switch destination {
        case .buffer(let file, _, _, let folder?) where file?.url == displayedFileURL:
            setFolder(folder)
            return true
        case .preview(let preview, _, let folder?) where preview.url == displayedFileURL:
            setFolder(folder)
            return true
        default:
            break
        }
        activity.beginOpenReplacement()
        return await closeBuffer(destination: destination, while: isCurrent)
    }

    @discardableResult
    private func closeBuffer(destination: CloseDestination, while isCurrent: () -> Bool = { true }) async -> Bool {
        if editor.hasMarkedText() { editor.unmarkText() }
        let previousFolder = folderURL
        let wasEditable = !hasEditableTextDocument || editor.isEditable
        editor.isEditable = false
        defer {
            editor.isEditable = hasEditableTextDocument && wasEditable
            activity.endReplacement()
            if folderURL != previousFolder { sidebar.folderChanged() }
            autosave.resume()
            fileRefresh.resume()
        }

        await flushAutosave()
        guard isCurrent(), !Task.isCancelled else { return false }
        let choice: CloseChoice
        if !window.isDocumentEdited {
            choice = .discard
        } else if app.isAgentCheck {
            choice = .cancel
        } else if fileURL == nil {
            let sheet = UntitledCloseSheet(window: window, folder: folderURL) { [self] destination, encoding in
                await save(to: destination, encoding: encoding)
            }
            switch await sheet.confirmClose() {
            case .close:
                choice = .discard
            case .cancel:
                choice = .cancel
            case .scratch(let name, let encoding):
                guard isCurrent(), !Task.isCancelled else { return false }
                choice = await saveScratchFromPanel(name: name, encoding: encoding) ? .discard : .cancel
            }
        } else {
            choice = await confirmNamedClose()
        }
        return await finishClose(choice, destination: destination, while: isCurrent)
    }

    @discardableResult
    func finishClose(
        _ choice: CloseChoice, destination: CloseDestination = .window, while isCurrent: () -> Bool = { true }
    ) async -> Bool {
        guard isCurrent(), !Task.isCancelled else { return false }
        switch choice {
        case .save(let url):
            guard await save(to: url), !window.isDocumentEdited else { return false }
        case .discard:
            break
        case .cancel:
            return false
        }
        guard isCurrent(), !Task.isCancelled else { return false }

        switch destination {
        case .buffer(let file, let focusEditor, let scratch, let folder):
            let restoreFocus = focusEditor || contentHasFocus
            editor.breakUndoCoalescing()
            var position: EditorPosition?
            if let file {
                // Saving the outgoing draft to the target already installed the latest revision.
                if file.url != fileURL {
                    rememberFilePosition()
                    position = await app.recentFiles.position(for: file.url, identity: file.identity)
                    guard isCurrent(), !Task.isCancelled else { return false }
                    let preparedSyntax = await prepareOpeningSyntax(file, position: position, scratch: scratch)
                    guard isCurrent(), !Task.isCancelled else { return false }
                    installContent(in: folder) {
                        load(file, preparedSyntax: preparedSyntax, scratch: scratch)
                    }
                } else if let folder {
                    setFolder(folder)
                }
            } else {
                rememberFilePosition()
                installContent(in: folder) {
                    removeSourceControlRevision()
                    removeFilePreview()
                    removeEmptyFolder()
                    resetDocument()
                }
            }
            autosave.clearFailure()
            if restoreFocus { focusContent() }
            restoreEditorPosition(position)
        case .preview(let preview, let focusEditor, let folder):
            let restoreFocus = focusEditor || contentHasFocus
            autosave.clearFailure()
            rememberFilePosition()
            installContent(in: folder) { loadPreview(preview) }
            if restoreFocus { focusContent() }
        case .sourceControlPreview(let preview):
            let restoreFocus = contentHasFocus
            rememberFilePosition()
            loadSourceControlRevision(preview)
            if restoreFocus { focusContent() }
        case .emptyFolder(let focus, let folder):
            let restoreFocus = focus || contentHasFocus
            rememberFilePosition()
            if folder == nil { app.recordClosedFile(in: self) }
            installContent(in: folder) { loadEmptyFolder() }
            if restoreFocus { focusContent() }
        case .window:
            window.close()
        }
        return true
    }

    private func installContent(in folder: URL?, _ install: () -> Void) {
        if let folder { folderURL = folder }
        install()
    }

    func openScratch(_ file: ScratchFile, focusEditor: Bool = true, shouldOpen: @escaping () -> Bool = { true }) async -> Bool {
        do {
            guard try await app.openFile(app.scratchStore.url(for: file), in: self, focusEditor: focusEditor,
                                         shouldOpen: shouldOpen) != nil else { return false }
            if focusEditor {
                focusContent()
                sidebar.revealCurrentScratch()
            }
            return true
        } catch {
            if !Task.isCancelled, !app.isQuitting, canReplaceBuffer, app.documents.contains(where: { $0 === self }) {
                await showError("Could Not Open “\(file.name)”", detail: error.localizedDescription)
            }
            return false
        }
    }

    func chooseScratchFolder() async -> String? {
        guard canReplaceBuffer, !app.isQuitting else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.directoryURL = folderURL
        requestAutosave()
        guard await response(to: panel) == .OK, let folder = panel.url, !app.isQuitting else { return nil }
        return await Task.detached { ScratchStore.folderPath(for: folder) }.value
    }

    func updateScratch(_ file: ScratchFile) {
        guard let previous = scratchFile, previous.id == file.id, previous != file else { return }
        scratchFile = file
        guard previous.name != file.name else { return }
        let previousLanguage = resolvedSyntaxLanguage
        detectedSyntaxLanguage = SyntaxLanguage.detected(at: file.filenameURL)
        updateTitle(revealInWorktree: false)
        if resolvedSyntaxLanguage != previousLanguage { refreshSyntax(immediate: true) }
    }

    func reloadScratches() { sidebar.reloadScratches() }

    private func confirmNamedClose(consequence: String = "Closing this document without saving discards your edits.") async -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        if let detail = autosave.takeFailure(includingReported: true) {
            alert.informativeText = detail + "\n\n" + consequence
        } else {
            alert.informativeText = consequence
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        switch await response(to: alert) {
        case .alertFirstButtonReturn: return .save(to: nil)
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    func windowDidResize(_ notification: Notification) {
        resizeTitleBars()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor.undoManager
    }

    var canFocusSelection: Bool { canReplaceBuffer && hasEditableTextDocument && editor.canFocusSelection }
    var canExitFocus: Bool { canReplaceBuffer && editor.focusRanges != nil }

    func focusSelection() {
        guard canFocusSelection else { return }
        editor.beginFocus()
        focusContent()
    }

    func exitFocus() {
        guard canExitFocus else { return }
        editor.exitFocus()
        focusContent()
    }

    func windowWillClose(_ notification: Notification) {
        if !app.isQuitting { discardDraftCheckpoint() }
        fileRefresh.stop()
        closeTerminalSessions()
        jjDocumentChanges?.stop()
        rememberFilePosition()
        editor.exitFocus(notify: false)
        filePreviewView?.stop()
        syntaxHighlighting?.cancel(clearingColors: false)
        autosave.reset()
        app.didClose(self)
    }

    func showError(_ title: String, detail: String = "") async {
        if app.isAgentCheck {
            FileHandle.standardError.write(Data("\(title) \(detail)\n".utf8))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        _ = await response(to: alert)
    }

    private func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if fileURL == nil { panel.showsTagField = false }
        panel.nameFieldStringValue = fileURL == nil ? "Untitled.txt" : displayName
        panel.directoryURL = scratchFile == nil ? fileURL?.deletingLastPathComponent() ?? folderURL : folderURL
        return panel
    }

    private func response(to panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { result in
                panel.orderOut(nil)
                continuation.resume(returning: result)
            }
        }
    }

    private func response(to alert: NSAlert) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func installText(
        _ text: String, preparedSyntax: SyntaxSnapshot? = nil, revealInWorktree: Bool = true
    ) {
        pendingSourceControlDiffFile = nil
        discardDraftCheckpoint()
        editor.exitFocus(notify: false)
        editor.preferredLineEnding = format.lineEnding
        editor.resetMultiCarets()
        syntaxHighlighting?.prepareForBufferReplacement()
        editor.bracketNavigation.reset()
        editor.occurrenceHighlighting.reset()
        editor.string = text
        refreshSyntax(immediate: true, preparedSyntax: preparedSyntax)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.requestLineRefresh()
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.undoManager?.removeAllActions()
        updateTitle(revealInWorktree: revealInWorktree)
        updateEditedState()
        sidebar.editorBufferReplaced()
        jjDocumentChanges?.bufferReplaced()
    }

    private func updateIdentity(from file: FileBuffer) {
        fileURL = file.url
        fileIdentity = file.identity
        revision = file.revision
        format = file.format
        savedText = file.text as NSString
        editor.preferredLineEnding = format.lineEnding
        if file.diskStamp != nil { fileRefresh.observe(file.url, stamp: file.diskStamp) }
    }

    private func updateTitle(revealInWorktree: Bool = true) {
        if window.representedURL != displayedFileURL { window.representedURL = displayedFileURL }
        if let folderURL {
            let folderName = folderURL.lastPathComponent
            let name = folderName.isEmpty ? folderURL.path : folderName
            window.title = showsEmptyFolder ? name : "\(name) — \(displayName)"
        } else {
            window.title = displayName
        }
        titleBar.update()
        sidebar.documentTitleChanged(reveal: revealInWorktree)
        updateJJContext()
    }

    func updateJJContext() {
        let file = hasTextDocument && scratchFile == nil ? fileURL : nil
        let folder = worktreeSidebar?.isObservingWorktree == true ? folderURL : nil
        if jjDocumentChanges == nil {
            guard file != nil || folder != nil else { return }
            jjDocumentChanges = JJDocumentChanges(monitor: app.jjChanges, text: { [weak self] in
                guard let editor = self?.editor, !editor.hasMarkedText() else { return nil }
                return editor.string
            }, showMarks: { [weak self] result, normalizeCRLF in
                guard let self, sourceControlRevision == nil else { return }
                editor.setJJLineMarks(result?.marks ?? [], lineStarts: result?.lineStarts ?? [],
                                      hunks: result?.hunks ?? [], normalizeCRLF: normalizeCRLF)
                if result != nil, pendingSourceControlDiffFile != nil, pendingSourceControlDiffFile == fileURL {
                    pendingSourceControlDiffFile = nil
                    editor.jjInlineDiff?.expandAll()
                }
            }, suspendMarkerNavigation: { [weak self] in
                self?.editor.suspendJJMarkerNavigation()
            }, showWorktree: { [weak self] decorations in
                self?.worktreeSidebar?.setJJDecorations(decorations)
            })
            editor.onJJCompositionChange = { [weak self] in self?.jjDocumentChanges?.bufferChanged() }
        }
        jjDocumentChanges?.update(file: file, revision: revision, folder: folder)
    }

    private func updateEditedState() {
        let isEdited = savedText.map { !(editor.textStorage?.mutableString.isEqual($0) ?? false) } ?? true
        if isEdited != window.isDocumentEdited {
            window.isDocumentEdited = isEdited
            if !isEdited { fileRefresh.resume() }
        }
    }

    private func scheduleDraftCheckpoint() {
        guard !app.isQuitting, !editor.hasMarkedText() else { return }
        guard hasEditableTextDocument, fileURL == nil, window.isDocumentEdited else {
            discardDraftCheckpoint()
            return
        }
        let previous = draftRecoveryRevision
        draftRecoveryRevision = DraftRecoveryRevision(id: previous?.id ?? UUID(), version: (previous?.version ?? 0) + 1)
        guard draftCheckpoint == nil else { return }
        // Start the interval with the first edit so continuous typing is checkpointed too.
        draftCheckpoint = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            draftCheckpoint = nil
            guard !app.isQuitting, !editor.hasMarkedText(), let revision = draftRecoveryRevision else { return }
            writeDraftCheckpoint(DraftCheckpoint(revision: revision, text: editor.string,
                                                 folderPath: folderURL?.path, placement: placement))
        }
    }

    private func discardDraftCheckpoint() {
        draftCheckpoint?.cancel()
        draftCheckpoint = nil
        guard let previous = draftRecoveryRevision else { return }
        draftRecoveryRevision = nil
        // This also retires the same draft from the last saved session after an interrupted run.
        let revision = DraftRecoveryRevision(id: previous.id, version: previous.version + 1)
        writeDraftCheckpoint(DraftCheckpoint(revision: revision, text: nil))
    }

    private func writeDraftCheckpoint(_ checkpoint: DraftCheckpoint) {
        app.draftRecovery.write(checkpoint) { [weak self] detail in
            guard let self, !showedDraftRecoveryError, !app.isQuitting, window.isVisible, window.attachedSheet == nil else { return }
            showedDraftRecoveryError = true
            Task { await showError("Could Not Update Draft Recovery", detail: detail) }
        }
    }
}
