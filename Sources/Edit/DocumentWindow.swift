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
private final class EditorDocumentWindow: NSWindow {
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
        case buffer(FileBuffer?, focusEditor: Bool = true, scratch: ScratchFile? = nil)
        case preview(OpenFilePreview, focusEditor: Bool)
        case emptyFolder(focusContent: Bool)
    }

    private struct AutosaveRequest {
        let generation: UInt
        let text: String
    }

    let window: NSWindow
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
    var openRequestGeneration: UInt64 = 0
    var isShowingFilePreview: Bool { filePreview != nil }
    var showsEmptyFolder: Bool { emptyFolderView != nil }
    var hasTextDocument: Bool { !isShowingFilePreview && !showsEmptyFolder }
    var displayedFileURL: URL? { filePreview?.url ?? fileURL }
    var fileIconURL: URL? { scratchFile?.filenameURL ?? displayedFileURL }
    var displayName: String { scratchFile?.name ?? displayedFileURL?.lastPathComponent ?? "Untitled" }
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
            if worktreeMutation { worktreePriorEditability = true }
            editor.isEditable = !isBusy && !app.isQuitting
            if wasFocused { focusContent() }
        }
        updateTitle()
        findPanel?.folderChanged()
    }

    private var detectedSyntaxLanguage: SyntaxLanguage = .plainText
    private(set) var fileIdentity: FileIdentity?
    private var savedText: NSString? = "" as NSString
    private var format = FileFormat()
    private var revision: FileRevision?
    private var normalFrame: NSRect?
    private var pendingFullScreen = false
    private var saving = false
    private var promptingToClose = false
    private var worktreeMutation = false
    private var worktreePriorEditability = true
    private var editGeneration: UInt = 0
    private var idleSave: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var queuedAutosave: AutosaveRequest?
    private var writingGeneration: UInt?
    private var autosaveFailure: (generation: UInt, detail: String, reported: Bool)?
    private var syntaxHighlighting: SyntaxHighlighting?
    private var findPanel: FindSidebar?
    var findSettings = FindSettings() {
        didSet { updateOccurrenceFindSettings() }
    }
    private var lastSidebarMode: SidebarMode?
    var sidebarMode: SidebarMode {
        get { lastSidebarMode ?? (folderURL == nil ? .scratches : .search) }
        set {
            lastSidebarMode = newValue
            updateOccurrenceFindSettings()
        }
    }
    var worktreeShowsHidden = false
    var worktreeSidebar: WorktreeSidebar? { findPanel?.worktree }
    private var jjDocumentChanges: JJDocumentChanges?
    var scratchOutline: NSOutlineView? { findPanel?.scratchOutline }
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

    var isBusy: Bool { saving || promptingToClose || worktreeMutation }
    var canReplaceBuffer: Bool { !isBusy && window.attachedSheet == nil }
    var isReusable: Bool {
        folderURL == nil && displayedFileURL == nil && findPanel == nil && terminalPanel == nil && pendingTerminalRestore == nil &&
            !window.isDocumentEdited && canReplaceBuffer
    }

    init(app: Edit, placement: WindowPlacement? = nil) {
        self.app = app
        window = EditorDocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
        pinToEditorContent(scrollView)
        window.toolbarStyle = .unifiedCompact
        window.toolbar = titleBar.makeToolbar(delegate: titleBar)
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        editor.onTextChange = { [weak self] in self?.textDidChange() }
        editor.onFocusScopeChange = { [weak self] in
            guard let self else { return }
            self.findPanel?.bufferReplaced()
            self.editor.occurrenceHighlighting.reset()
            self.editor.occurrenceHighlighting.selectionChanged()
        }
        editor.onBlur = { [weak self] in self?.requestAutosave() }
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

    var terminalSidebarThickness: CGFloat {
        guard let terminalSidebar else { return 0 }
        let width = visibleTerminalSidebarWidth(terminalSidebar)
        return width > 0 ? width + documentSplitView.dividerThickness : 0
    }

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
        if let toolbar = window.toolbar {
            if !toolbar.items.contains(where: { $0.itemIdentifier == .inspectorTrackingSeparator }) {
                toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: toolbar.items.count)
            }
            resizeTitleBars()
            titleBar.setTerminalTitleVisible(true, in: toolbar)
        }
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
        if let findPanel { findPanel.resizeTitleBar() }
        else { titleBar.resize() }
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
        if let toolbar = window.toolbar {
            titleBar.setTerminalTitleVisible(false, in: toolbar)
            toolbar.removeItem(identifier: .inspectorTrackingSeparator)
        }
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
        if let findPanel { return findPanel.canPerform(command) }
        switch command {
        case .find, .replace, .toggleSidebar: return true
        case .next, .previous: return !findSettings.query.isEmpty
        default: return false
        }
    }

    func performFind(_ command: FindCommand) {
        guard !app.isQuitting, window.attachedSheet == nil, canPerformFind(command) else { return }
        searchPanel().perform(command)
    }

    func toggleSidebarFocus(_ mode: SidebarMode) {
        guard !app.isQuitting, window.attachedSheet == nil,
              mode != .worktree || folderURL != nil, mode != .search || hasTextDocument else { return }
        searchPanel().toggleFocus(of: mode)
    }

    func restoreFindSettings(_ settings: FindSettings) {
        findSettings = settings
        if settings.visible {
            searchPanel().restoreVisibility()
        }
    }

    private func updateOccurrenceFindSettings() {
        var settings = findSettings
        settings.visible = settings.visible && sidebarMode == .search
        editor.occurrenceHighlighting.update(findSettings: settings)
    }

    func restoreSidebar(_ record: SessionDocument) {
        // Older sessions omitted the mode for Search even when they saved its sidebar state.
        lastSidebarMode = record.sidebarMode ?? (record.findSettings == nil ? nil : .search)
        if lastSidebarMode == .worktree && folderURL == nil { lastSidebarMode = .search }
        worktreeShowsHidden = record.worktreeShowsHidden ?? false
        if let settings = record.findSettings { restoreFindSettings(settings) }
    }

    private func searchPanel() -> FindSidebar {
        if let findPanel { return findPanel }
        let panel = FindSidebar(document: self, app: app)
        findPanel = panel
        editor.onFindEditorInteraction = { [weak panel] in panel?.editorInteracted() }
        editor.onFindViewportChange = { [weak panel] in panel?.viewportChanged() }
        return panel
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
        titleBar.setFullScreen(true)
        findPanel?.finishSidebarHeaderLayout()
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        pendingFullScreen = false
        restoreVisibleTerminalIfReady()
        titleBar.setFullScreen(false)
        findPanel?.finishSidebarHeaderLayout()
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        normalFrame = nil
        titleBar.setFullScreen(false)
        resizeTitleBars()
        findPanel?.finishSidebarHeaderLayout()
    }

    func windowDidResignKey(_ notification: Notification) {
        requestAutosave()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        requestAutosave()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reportAutosaveFailure()
        jjDocumentChanges?.recheck()
    }

    func windowDidEndSheet(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.reportAutosaveFailure() }
    }

    func load(
        _ file: FileBuffer, storedSyntaxLanguage: String? = nil, preparedSyntax: SyntaxSnapshot? = nil, scratch: ScratchFile? = nil
    ) {
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
        pinToEditorContent(view)
        window.initialFirstResponder = view
        scrollView.isHidden = true
        installText("", revealInWorktree: revealInWorktree)
    }

    private func removeFilePreview() {
        guard let filePreviewView else { return }
        window.initialFirstResponder = editor
        self.filePreviewView = nil
        filePreview = nil
        filePreviewView.stop()
        filePreviewView.removeFromSuperview()
        scrollView.isHidden = false
    }

    func loadEmptyFolder() {
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
        autosaveFailure = nil
        installText("")
    }

    private func pinToEditorContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let dock = terminalDockView, dock.superview === editorContentView {
            editorContentView.addSubview(view, positioned: .below, relativeTo: dock)
        } else {
            editorContentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: editorContentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: editorContentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: editorContentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: editorContentView.bottomAnchor),
        ])
        setEditorBottomInset(terminalDockView?.coveredHeight ?? 0)
    }

    func restoreDraft(_ record: SessionDocument, text: String, identity: FileIdentity? = nil, scratch: ScratchFile? = nil) {
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
    }

    func sessionDocument() -> SessionDocument {
        SessionDocument(
            path: displayedFileURL?.path,
            draft: window.isDocumentEdited ? editor.string : nil,
            format: fileURL == nil ? nil : format,
            revision: revision,
            placement: placement,
            syntaxLanguage: manualSyntaxLanguage?.rawValue,
            folderPath: folderURL?.path,
            findSettings: findSettings == FindSettings() ? nil : findSettings,
            editorPosition: hasTextDocument ? editor.capturePosition() : nil,
            sidebarMode: lastSidebarMode,
            worktreeShowsHidden: (worktreeSidebar?.showsHidden ?? worktreeShowsHidden) ? true : nil,
            isFilePreview: isShowingFilePreview ? true : nil,
            showsEmptyFolder: folderURL != nil && displayedFileURL == nil ? showsEmptyFolder : nil,
            terminal: terminalSessionState()
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
    func save(asNew: Bool = false, to selectedURL: URL? = nil, encoding: FileTextEncoding? = nil) async -> Bool {
        guard hasTextDocument, !saving, !worktreeMutation else { return false }
        saving = true
        if editor.hasMarkedText() { editor.unmarkText() }
        defer {
            saving = false
            startRequestedAutosave()
            reportAutosaveFailure()
        }
        await autosaveTask?.value
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
        guard app.reserveSave(to: target, identity: identity, for: self) else {
            await showError("The file is in use by another window.")
            return false
        }
        defer { app.finishSave(to: target) }

        let text = editor.string
        let writtenGeneration = editGeneration
        let expected = target == fileURL ? revision : nil

        do {
            do {
                try await write(text, to: target, format: saveFormat, expected: expected)
            } catch FileBufferError.changedOnDisk {
                guard !app.isAgentCheck else {
                    await showError("The file changed on disk.")
                    return false
                }
                let alert = NSAlert()
                alert.messageText = "The file changed on disk."
                alert.informativeText = "Replace the on-disk version of “\(target.lastPathComponent)” with the text in Edit?"
                alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
                alert.addButton(withTitle: "Replace").hasDestructiveAction = true
                guard await response(to: alert) == .alertSecondButtonReturn else { return false }
                try await write(text, to: target, format: saveFormat, expected: nil)
            }
            resumeAutosave(afterSaving: writtenGeneration)
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
        guard canReplaceBuffer, hasTextDocument, !app.isQuitting else { return }
        saving = true
        defer {
            saving = false
            startRequestedAutosave()
            reportAutosaveFailure()
        }
        if editor.hasMarkedText() { editor.unmarkText() }
        await autosaveTask?.value
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
        let writtenGeneration = editGeneration
        let saveFormat = format.using(encoding ?? format.encoding)
        let (scratch, buffer) = try await app.scratchStore.create(name: name, text: text, format: saveFormat,
                                                                  in: folder, openedAt: Date())
        adoptSavedFile(buffer, scratch: scratch)
        resumeAutosave(afterSaving: writtenGeneration)
        app.scratchesDidChange()
        return scratch
    }

    private func resumeAutosave(afterSaving generation: UInt) {
        if let queuedAutosave, queuedAutosave.generation <= generation { self.queuedAutosave = nil }
        if window.isDocumentEdited { scheduleIdleAutosave() }
    }

    private func write(_ text: String, to target: URL, format: FileFormat, expected: FileRevision?) async throws {
        let file = try await Task.detached {
            try FileBuffer.save(text, to: target, format: format, expected: expected)
        }.value
        adoptSavedFile(file)
    }

    private func adoptSavedFile(_ file: FileBuffer, scratch: ScratchFile? = nil) {
        let changedPath = fileURL != file.url
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
        autosaveFailure = nil
    }

    func requestAutosave() {
        guard fileURL != nil, !app.isQuitting,
              window.isDocumentEdited || autosaveTask != nil || saving else { return }
        if editor.hasMarkedText() {
            scheduleIdleAutosave()
            return
        }
        guard queuedAutosave?.generation != editGeneration, writingGeneration != editGeneration,
              autosaveFailure?.generation != editGeneration else { return }
        queuedAutosave = AutosaveRequest(generation: editGeneration, text: editor.string)
        startRequestedAutosave()
    }

    private func startRequestedAutosave() {
        guard queuedAutosave != nil, autosaveTask == nil, !isBusy, !app.isQuitting else { return }
        autosaveTask = Task {
            while let request = queuedAutosave, !isBusy, !app.isQuitting {
                queuedAutosave = nil
                if editor.hasMarkedText() {
                    scheduleIdleAutosave()
                    break
                }
                await writeAutosave(request)
            }
            autosaveTask = nil
            reportAutosaveFailure()
        }
    }

    // Closing, replacing, and quitting hold off new background writes while draining this one.
    func flushAutosave() async {
        idleSave?.cancel()
        idleSave = nil
        await autosaveTask?.value
        queuedAutosave = nil
        if window.isDocumentEdited {
            await writeAutosave(AutosaveRequest(generation: editGeneration, text: editor.string), retryFailed: true)
        }
    }

    private func writeAutosave(_ request: AutosaveRequest, retryFailed: Bool = false) async {
        let generation = request.generation
        guard let target = fileURL, let revision, savedText?.isEqual(to: request.text) != true,
              retryFailed || autosaveFailure?.generation != generation else { return }
        writingGeneration = generation
        defer { writingGeneration = nil }
        guard app.reserveSave(to: target, identity: fileIdentity, for: self) else {
            autosaveFailure = (generation, "The file is in use by another window.", false)
            return
        }
        defer { app.finishSave(to: target) }
        do {
            try await write(request.text, to: target, format: format, expected: revision)
        } catch FileBufferError.changedOnDisk {
            autosaveFailure = (generation, "The file changed on disk. Use Save to review whether to replace it.", false)
        } catch {
            autosaveFailure = (generation, error.localizedDescription, false)
        }
    }

    func worktreeMutationAffects(_ sources: [URL]) -> Bool {
        sources.contains { source in
            [displayedFileURL, folderURL].compactMap { $0 }.contains { Self.worktreePathSuffix(from: source, to: $0) != nil }
        }
    }

    func beginWorktreeMutation() {
        if editor.hasMarkedText() { editor.unmarkText() }
        worktreeMutation = true
        worktreePriorEditability = editor.isEditable
        editor.isEditable = false
        idleSave?.cancel()
        idleSave = nil
    }

    func waitForWorktreeWrites() async {
        await autosaveTask?.value
    }

    func finishWorktreeMutation() {
        worktreeMutation = false
        editor.isEditable = hasTextDocument && worktreePriorEditability
        startRequestedAutosave()
        if autosaveTask == nil { scheduleIdleAutosave() }
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
        if let manualSyntaxLanguage {
            app.syntaxOverrides.set(nil, for: original)
            app.syntaxOverrides.set(manualSyntaxLanguage, for: fileURL)
        }
        autosaveFailure = nil
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
        if wasPreview { worktreePriorEditability = true }
        let edited = window.isDocumentEdited
        let previousLanguage = resolvedSyntaxLanguage
        self.fileURL = nil
        fileIdentity = nil
        savedText = "" as NSString
        revision = nil
        queuedAutosave = nil
        autosaveFailure = nil
        if edited {
            manualSyntaxLanguage = previousLanguage == .plainText ? nil : previousLanguage
            updateTitle()
            updateEditedState()
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
        guard let failure = autosaveFailure, !failure.reported, window.isDocumentEdited else { return nil }
        autosaveFailure?.reported = true
        return "“\(displayName)” — \(failure.detail)"
    }

    private func reportAutosaveFailure() {
        guard let failure = autosaveFailure, !failure.reported, window.isDocumentEdited,
              !isBusy, !app.isQuitting, !app.isAgentCheck, window.isKeyWindow,
              NSApplication.shared.isActive, window.attachedSheet == nil else { return }
        autosaveFailure?.reported = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Autosave “\(displayName)”"
        alert.informativeText = failure.detail
        alert.beginSheetModal(for: window)
    }

    private func scheduleIdleAutosave() {
        idleSave?.cancel()
        idleSave = nil
        guard fileURL != nil, !app.isQuitting,
              window.isDocumentEdited || autosaveTask != nil || saving else { return }
        idleSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            idleSave = nil
            requestAutosave()
        }
    }

    @objc private func undoOrRedo(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager, manager === editor.undoManager else { return }
        editor.bracketNavigation.reset()
        editor.occurrenceHighlighting.contentChanged()
        editor.requestLineRefresh()
        textDidChange()
    }

    private func textDidChange() {
        editGeneration &+= 1
        updateEditedState()
        scheduleIdleAutosave()
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
                openRequestGeneration &+= 1
                promptingToClose = true
                Task { await closeBuffer(destination: .emptyFolder(focusContent: true)) }
                return false
            }
        }
        guard window.isDocumentEdited || autosaveTask != nil else { return true }
        promptingToClose = true
        Task { await closeBuffer(destination: .window) }
        return false
    }

    func newBuffer() async {
        guard canReplaceBuffer, !app.isQuitting else { return }
        openRequestGeneration &+= 1
        await replaceBuffer(with: nil)
    }

    @discardableResult
    func replaceBuffer(
        with file: FileBuffer?, focusEditor: Bool = true, scratch: ScratchFile? = nil
    ) async -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        promptingToClose = true
        return await closeBuffer(destination: .buffer(file, focusEditor: focusEditor, scratch: scratch))
    }

    func replaceBuffer(withPreview preview: OpenFilePreview, focusEditor: Bool) async -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        promptingToClose = true
        return await closeBuffer(destination: .preview(preview, focusEditor: focusEditor))
    }

    func replaceBuffer(withEmptyFolder folder: URL, focusContent: Bool) async -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        promptingToClose = true
        guard await closeBuffer(destination: .emptyFolder(focusContent: focusContent)) else { return false }
        setFolder(folder)
        return true
    }

    @discardableResult
    private func closeBuffer(destination: CloseDestination) async -> Bool {
        if editor.hasMarkedText() { editor.unmarkText() }
        let wasEditable = !hasTextDocument || editor.isEditable
        editor.isEditable = false
        defer {
            editor.isEditable = hasTextDocument && wasEditable
            promptingToClose = false
            startRequestedAutosave()
        }

        await flushAutosave()
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
                choice = await saveScratchFromPanel(name: name, encoding: encoding) ? .discard : .cancel
            }
        } else {
            choice = await confirmNamedClose()
        }
        return await finishClose(choice, destination: destination)
    }

    @discardableResult
    func finishClose(_ choice: CloseChoice, destination: CloseDestination = .window) async -> Bool {
        switch choice {
        case .save(let url):
            guard await save(to: url), !window.isDocumentEdited else { return false }
        case .discard:
            break
        case .cancel:
            return false
        }

        switch destination {
        case .buffer(let file, let focusEditor, let scratch):
            autosaveFailure = nil
            let restoreFocus = focusEditor || contentHasFocus
            editor.breakUndoCoalescing()
            var position: EditorPosition?
            if let file {
                // Saving the outgoing draft to the target already installed the latest revision.
                if file.url != fileURL {
                    rememberFilePosition()
                    position = await app.recentFiles.position(for: file.url, identity: file.identity)
                    let preparedSyntax = await prepareOpeningSyntax(file, position: position, scratch: scratch)
                    guard !Task.isCancelled else { return false }
                    load(file, preparedSyntax: preparedSyntax, scratch: scratch)
                }
            } else {
                rememberFilePosition()
                removeFilePreview()
                removeEmptyFolder()
                resetDocument()
            }
            if restoreFocus { focusContent() }
            restoreEditorPosition(position)
        case .preview(let preview, let focusEditor):
            let restoreFocus = focusEditor || contentHasFocus
            autosaveFailure = nil
            rememberFilePosition()
            loadPreview(preview)
            if restoreFocus { focusContent() }
        case .emptyFolder(let focus):
            let restoreFocus = focus || contentHasFocus
            rememberFilePosition()
            loadEmptyFolder()
            if restoreFocus { focusContent() }
        case .window:
            window.close()
        }
        return true
    }

    func openScratch(_ file: ScratchFile, focusEditor: Bool = true, shouldOpen: () -> Bool = { true }) async -> Bool {
        do {
            guard try await app.openFile(app.scratchStore.url(for: file), in: self, focusEditor: focusEditor,
                                         shouldOpen: shouldOpen) != nil else { return false }
            if focusEditor {
                focusContent()
                findPanel?.revealCurrentScratch()
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

    func reloadScratches() { findPanel?.reloadScratches() }

    private func confirmNamedClose() async -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(displayName)”?"
        let consequence = "Closing this document without saving discards your edits."
        if let failure = autosaveFailure {
            alert.informativeText = failure.detail + "\n\n" + consequence
            autosaveFailure?.reported = true
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

    var canFocusSelection: Bool { canReplaceBuffer && hasTextDocument && editor.canFocusSelection }
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
        closeTerminalSessions()
        jjDocumentChanges?.stop()
        rememberFilePosition()
        editor.exitFocus(notify: false)
        filePreviewView?.stop()
        syntaxHighlighting?.cancel(clearingColors: false)
        idleSave?.cancel()
        idleSave = nil
        queuedAutosave = nil
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
        findPanel?.bufferReplaced()
        jjDocumentChanges?.bufferReplaced()
    }

    private func updateIdentity(from file: FileBuffer) {
        fileURL = file.url
        fileIdentity = file.identity
        revision = file.revision
        format = file.format
        savedText = file.text as NSString
        editor.preferredLineEnding = format.lineEnding
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
        findPanel?.updateName()
        findPanel?.updateCurrentFile(reveal: revealInWorktree)
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
            }, showMarks: { [weak self] marks, starts in
                self?.editor.setJJLineMarks(marks, lineStarts: starts)
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
        }
    }
}
