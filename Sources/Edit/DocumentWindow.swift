import AppKit
import UniformTypeIdentifiers

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
    private static let fileUndoHistoryLimit = 100
    enum CloseChoice {
        case save(to: URL?)
        case discard
        case cancel
    }

    enum CloseDestination {
        case window
        case workspace
        case buffer(FileBuffer?, focusEditor: Bool = true, scratch: ScratchFile? = nil, folder: URL? = nil)
        case preview(OpenFilePreview, focusEditor: Bool, folder: URL? = nil)
        case sourceControlPreview(SourceControlRevisionPreview, selection: SourceControlFile)
        case emptyFolder(focusContent: Bool, folder: URL? = nil)
    }

    let window: EditorDocumentWindow
    let editor: EditorTextView
    let scrollView: NSScrollView
    let editorContentView: NSView
    let documentSplitView = NSSplitView(frame: .zero)
    private var documentSplit: NSSplitViewController?
    private var terminalPanel: TerminalPanel?
    private var inactiveTerminals: [String?: DocumentTerminalState] = [:]
    private var terminalDockView: TerminalDockView?
    private var terminalSidebar: NSSplitViewItem?
    private var terminalSidebarPanelConstraints: [NSLayoutConstraint] = []
    private var terminalTitleHost: NSView?
    private weak var terminalTitleWidthLimit: NSLayoutConstraint?
    private var terminalSidebarWidth = TerminalDockSizes().rightWidth
    private(set) var isTerminalVisible = false
    private var pendingTerminalFocus: Bool?
    private var zigTestStart: Task<Void, Never>?
    private(set) lazy var titleBar = DocumentTitleBar(document: self, app: app)
    private(set) lazy var languageFeatures = DocumentLanguageFeatures(document: self, app: app)
    private(set) lazy var resultDecorations: FindDecorations = {
        let decorations = FindDecorations(editor: editor)
        editor.onFindViewportChange = { [weak decorations] in decorations?.layout() }
        return decorations
    }()
    let navigationHistory = NavigationHistory()
    var isReplayingNavigation = false
    private var navigationBufferID = UUID()
    private var navigationSelectionAnchor: LineEditing.LineAnchor?
    private var restoringNavigationSelection = false

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
    private var markdownTableContext: (source: String, caret: Int, table: MarkdownTable?)?
    private var markdownPreview: MarkdownPreviewView?
    private var markdownState = MarkdownViewState()
    private var markdownRender: Task<Void, Never>?
    private var markdownPage: (source: String, document: MarkdownDocument)?
    private var markdownNoteOrigins: [String: Int] = [:]
    private var pendingMarkdownFragment: String?
    private struct PreparedMarkdownOpening {
        let view: MarkdownPreviewView
        let source: String
        let document: MarkdownDocument
        var state: MarkdownViewState
    }
    private var markdownFiles: [(url: URL, identity: FileIdentity, state: MarkdownViewState)] = []
    private var markdownRevisions: [String: (SourceControlFile, EditorPosition)] = [:]
    #if EDIT_AGENT_CHECKS
    var beforePresentMarkdownForCheck: ((MarkdownPreviewView) async -> Void)?
    var beforeInstallFileForCheck: ((FileBuffer) async -> Void)?
    var beforePublishingWorkspaceFindForCheck: (() async -> Void)?
    var confirmWorkspaceReplaceForCheck: ((Int, Int) async -> Bool)?
    var beforeCloseWorkspaceForCheck: (() async -> Void)?
    #endif
    private var emptyFolderView: EmptyFolderView?
    private var sourceControlRevision: SourceControlRevisionPreview?
    struct SourceControlFile: Equatable {
        let file: JJSourceControlFile
        let revision: JJSourceControlRevision
        let workspace: JJWorkspace
        let operationID: String

        var url: URL { workspace.root.appending(path: file.path, directoryHint: .notDirectory) }

        func ownsWorkingCopy(_ checkout: JJRepositoryState) -> Bool {
            revision.changeID == checkout.changeID && (!revision.isDivergent || revision.id == checkout.commitID)
        }
    }
    private var sourceControlFile: SourceControlFile?
    private var sourceControlFileSubscription: JJChangeMonitor.Subscription?
    private var sourceControlCheckout: JJRepositoryState?
    private var lastLiveSourceControlCheckout: JJRepositoryState?
    private var sourceControlFileTransition: Task<Void, Never>?
    private(set) var sourceControlRevisionBanner: SourceControlRevisionBanner?
    private(set) var conflictPanel: JJConflictPanel?
    private var conflictBlocks: [JJConflict] = []
    var displayedConflicts: [JJConflict] { conflictBlocks }
    private var conflictPresentationCurrent = false
    private var conflictStyleTask: Task<Void, Never>?
    private var conflictApplyTask: Task<Void, Never>?
    private var failedConflictDiffs: [UUID: Set<Int>] = [:]
    private let pendingConflictChanges = JJConflictPendingChanges()
    private var showsPendingConflictChanges = false

    var isShowingFilePreview: Bool { filePreview != nil }
    var showsEmptyFolder: Bool { emptyFolderView != nil }
    var hasTextDocument: Bool { !isShowingFilePreview && !showsEmptyFolder }
    var hasEditableTextDocument: Bool { hasTextDocument && sourceControlRevision == nil }
    var displayedFileURL: URL? { sourceControlRevision == nil ? filePreview?.url ?? fileURL : nil }
    var fileIconURL: URL? { scratchFile?.filenameURL ?? displayedFileURL ?? sourceControlRevision?.url }
    var displayName: String { scratchFile?.name ?? fileIconURL?.lastPathComponent ?? "Untitled" }
    var hasJujutsuWorkspace: Bool { folderURL.map(JJRepository.hasWorkspace(at:)) ?? false }
    var contentResponder: NSView { markdownPreview?.responder ?? (filePreviewView as NSView?) ?? (emptyFolderView as NSView?) ?? editor }

    func focusContent() {
        window.makeFirstResponder(contentResponder)
    }

    var navigationLocation: NavigationHistory.Location? { navigationLocation(at: nil) }

    private var navigationResource: NavigationHistory.Resource? {
        guard !showsEmptyFolder else { return nil }
        if sourceControlRevision != nil {
            return sourceControlFile.map { .revision(markdownRevisionKey($0)) }
        }
        return displayedFileURL.map { .file($0.standardizedFileURL) } ?? .buffer(navigationBufferID)
    }

    func navigationLocation(at range: NSRange?) -> NavigationHistory.Location? {
        guard let resource = navigationResource else { return nil }
        let selection: NavigationHistory.Selection?
        if hasTextDocument, editor.conflictEdits.isEmpty, let text = editor.textStorage?.mutableString {
            let caret = range ?? (markdownState.showsPreview ? markdownState.reading.map {
                NSRange(location: min($0.sourceOffset, text.length), length: 0)
            } : nil) ?? editor.selectedRange()
            selection = .init(range: caret, in: text, activeEnd: editor.activeEnd(of: caret), previousAnchor: navigationSelectionAnchor)
            navigationSelectionAnchor = selection?.anchor
        } else {
            selection = nil
        }
        return .init(resource: resource, selection: selection,
                     markdown: resolvedSyntaxLanguage == .markdown ? markdownState : nil)
    }

    func restoreNavigationSelection(_ selection: NavigationHistory.Selection) {
        guard hasTextDocument else { return }
        applyNavigationSelection(selection.range(in: editor.sourceString), backward: selection.isBackward)
    }

    func navigate(to caret: NSRange, from origin: NavigationHistory.Location?) {
        if let origin { app.recordNavigation(origin, in: self, reason: .selection) }
        applyNavigationSelection(caret)
        app.recordNavigation(in: self, reason: .jump)
    }

    private func applyNavigationSelection(_ range: NSRange, backward: Bool = false) {
        if editor.renameRange != nil { _ = editor.onCancelSymbolRename?() }
        restoringNavigationSelection = true
        defer { restoringNavigationSelection = false }
        if let scope = editor.focusRanges,
           !scope.contains(where: { $0.location <= range.location && range.upperBound <= $0.upperBound }) {
            editor.exitFocus()
        }
        focusContent()
        editor.setCaretSelections([range], record: false, primaryAffinity: backward ? .upstream : .downstream)
        editor.revealNavigationSelection(range)
    }

    private func recordEditorSelection() {
        guard !restoringNavigationSelection, !isBusy, window.firstResponder === editor, !editor.hasMarkedText() else { return }
        app.recordNavigation(in: self, reason: .selection)
    }

    func setFolder(_ url: URL?) {
        guard folderURL != url else { return }
        changeFolder(to: url) {
            if url == nil && showsEmptyFolder {
                let wasFocused = contentHasFocus
                removeEmptyFolder()
                activity.restoreEditabilityAfterMutation()
                editor.isEditable = !isBusy && !app.isQuitting
                if wasFocused { focusContent() }
            }
            updateTitle()
            updateTreeSitterHighlighting()
            sidebar.folderChanged()
        }
    }

    private var detectedSyntaxLanguage: SyntaxLanguage = .plainText
    private(set) var fileIdentity: FileIdentity?
    private var savedText: NSString? = "" as NSString
    private var format = FileFormat()
    private var revision: FileRevision?
    private struct FileUndoHistory {
        let url: URL
        let identity: FileIdentity
        let revision: FileRevision
        let format: FileFormat
        let manager: EditorUndoManager
        let focusRanges: [NSRange]?
        let focusHistory: EditorUndoManager.FocusHistory?
    }
    private var fileUndoHistories: [FileUndoHistory] = []
    private var normalFrame: NSRect?
    private var pendingFullScreen = false
    private let activity = DocumentActivity()
    private lazy var autosave = DocumentAutosave(document: self)
    private lazy var fileRefresh = DocumentFileRefresh(
        canRefresh: { [weak self] in self?.canRefreshFile == true },
        validateDiskOwner: { [weak self] in await self?.validateSourceControlDiskOwner() == true },
        apply: { [weak self] in self?.applyExternalFile($0, openingConflicts: $1) }
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
    var findScope: FindScope = .buffer {
        didSet { updateOccurrenceFindSettings() }
    }
    var sidebarMode: SidebarMode { sidebar.mode }
    var isSidebarVisible: Bool { sidebar.isVisible }
    var isSearchSidebarVisible: Bool { sidebar.isSearchVisible }
    var worktreeSidebar: SidebarFileTree? { sidebar.worktree }
    var sourceControlSidebar: SourceControlSidebar? { sidebar.sourceControl }
    private var jjDocumentChanges: JJDocumentChanges?
    var jjLiveFileStatus: JJWorkingCopyFileStatus? { jjDocumentChanges?.localStatus }
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
    var canCloseDocument: Bool { canReplaceBuffer && !app.isQuitting }
    var canCloseWorkspace: Bool { folderURL != nil && canCloseDocument }
    var canToggleWordWrap: Bool {
        hasTextDocument && window.attachedSheet == nil && !app.isQuitting
    }

    var canToggleHighlighting: Bool { window.attachedSheet == nil && !app.isQuitting }

    func isHighlightingEnabled(_ layer: HighlightingLayer) -> Bool {
        app.workspaceHighlighting.isEnabled(layer, in: folderURL)
    }

    func toggleHighlighting(_ layer: HighlightingLayer) {
        guard canToggleHighlighting else { return }
        let folder = folderURL?.standardizedFileURL
        app.workspaceHighlighting.setEnabled(!isHighlightingEnabled(layer), for: layer, in: folder)
        for document in app.documents where document.folderURL?.standardizedFileURL == folder {
            switch layer {
            case .treeSitter: document.updateTreeSitterHighlighting()
            case .lsp: document.updateLSPHighlighting()
            }
        }
    }

    private func updateTreeSitterHighlighting() {
        syntaxHighlighting?.setTreeSitterEnabled(isHighlightingEnabled(.treeSitter), language: resolvedSyntaxLanguage)
    }

    func updateLSPHighlighting(immediate: Bool = true) {
        syntaxHighlighting?.updateSemanticSource(languageFeatures.highlightingSession,
                                                 language: resolvedSyntaxLanguage, immediate: immediate)
    }

    private var wordWrapFileURL: URL? {
        hasTextDocument ? fileURL ?? sourceControlRevision?.url : nil
    }

    func toggleWordWrap() {
        guard canToggleWordWrap else { return }
        let enabled = !editor.wrapsWords
        editor.setWordWrap(enabled, preservingViewport: !scrollView.isHidden)
        if let url = wordWrapFileURL {
            app.fileWordWrap.set(enabled, for: url)
            for document in app.documents where document !== self && document.wordWrapFileURL == url {
                document.editor.setWordWrap(enabled, preservingViewport: !document.scrollView.isHidden)
            }
        }
    }

    var canRequestOpen: Bool { window.attachedSheet == nil && activity.acceptsOpenRequest }
    var canRestoreSession: Bool {
        folderURL == nil && displayedFileURL == nil && !sidebar.hasContent && terminalPanel == nil && inactiveTerminals.isEmpty &&
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
            Task { @MainActor in
                guard let self else { return }
                self.titleBar.update()
                if self.isShowingMarkdownPreview { self.refreshMarkdown(immediate: true) }
            }
        }
        window.contentView = editorContentView
        pinToEditorContent(scrollView)
        window.toolbarStyle = .unifiedCompact
        window.toolbar = titleBar.toolbar
        window.trackTitlebarPointer()
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        editor.onTextChange = { [weak self] in self?.textDidChange() }
        editor.markdownLink = { [weak self] offset, activate in self?.markdownLink(at: offset, activate: activate) ?? false }
        editor.onNavigationSelectionChange = { [weak self] in
            guard let self else { return }
            titleBar.updateCaretPosition()
            recordEditorSelection()
        }
        editor.onNavigationTextEdit = { [weak self] range in
            guard let self else { return }
            titleBar.invalidateCaretLine(from: range.location)
            if let anchor = navigationSelectionAnchor, range.location <= anchor.offset {
                navigationSelectionAnchor = nil
            }
        }
        editor.onConflictSelectionChange = { [weak self] in self?.updateConflictControls() }
        editor.onFocusScopeChange = { [weak self] in
            guard let self else { return }
            self.sidebar.editorBufferReplaced()
            self.editor.occurrenceHighlighting.reset()
            self.editor.occurrenceHighlighting.selectionChanged()
        }
        editor.onBlur = { [weak self] in self?.editorLostFocus() }
        languageFeatures.connectEditor()
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
        terminalPanel?.stopLearningStartupPrompt()
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
        attachTerminal(focusing: true)
    }

    private var zigTestFile: URL? {
        guard hasEditableTextDocument, scratchFile == nil, resolvedSyntaxLanguage == .zig,
              let fileURL, fileURL.pathExtension.lowercased() == "zig" else { return nil }
        return fileURL
    }

    private func refreshTestCodeLens() {
        guard let file = zigTestFile else {
            editor.testCodeLens?.reset()
            editor.testCodeLens = nil
            return
        }
        if editor.testCodeLens == nil {
            let lens = EditorTestCodeLens(editor: editor)
            lens.run = { [weak self] test in self?.runZigTest(test) }
            editor.testCodeLens = lens
        }
        editor.testCodeLens?.update(file: file)
    }

    private func runZigTest(_ test: ZigTestDeclaration) {
        guard zigTestStart == nil, canReplaceBuffer, editor.isEditable, !editor.hasMarkedText(), !app.isQuitting,
              editor.conflictEdits.isEmpty, let file = zigTestFile, let lens = editor.testCodeLens else { return }
        if terminalPanel?.revealRunningTest() == true {
            attachTerminal(focusing: false)
            return
        }
        let opening = openRequestGeneration
        let folder = folderURL
        let source = editor.sourceString
        zigTestStart = Task { [weak self] in
            guard let self else { return }
            defer { zigTestStart = nil }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !app.isQuitting && zigTestFile == file && folderURL == folder &&
                    openRequestGeneration == opening && editor.sourceString == source && editor.conflictEdits.isEmpty
            }
            guard await lens.isCurrent(test, file: file), isCurrent(), await save(), isCurrent() else { return }
            do {
                let invocation = try await ZigTestInvocation.prepare(test: test, file: file, folder: folder,
                                                                      cacheRoot: ZigTestCache.location(isolated: app.isAgentCheck))
                guard isCurrent() else { return }
                prepareTerminal().runTest(invocation)
                attachTerminal(focusing: false)
            } catch {
                if isCurrent() { await showError("Could Not Run Zig Test", detail: error.localizedDescription) }
            }
        }
    }

    func restoreTerminal(_ state: DocumentTerminalState?) {
        guard let state else { return }
        let panel = prepareTerminal(restoring: state)
        if state.isVisible { restoreVisibleTerminal(focusing: state.wasFocused) }
        panel.startSavedShells()
    }

    func restoreTerminals(from record: SessionDocument) {
        for terminal in record.inactiveTerminals ?? [] where terminal.folderPath != folderURL?.path {
            inactiveTerminals[terminal.folderPath] = terminal.state
        }
        restoreTerminal(record.terminal)
    }

    private func restoreVisibleTerminal(focusing: Bool) {
        pendingTerminalFocus = focusing
        if pendingFullScreen && terminalPanel?.dock == .right { _ = installDocumentSplit() }
        restoreVisibleTerminalIfReady()
    }

    private func restoreVisibleTerminalIfReady() {
        // The normal frame can be smaller than the saved full-screen layout.
        guard !pendingFullScreen, let shouldFocus = pendingTerminalFocus else { return }
        attachTerminal(focusing: shouldFocus)
    }

    private func prepareTerminal(restoring saved: DocumentTerminalState? = nil) -> TerminalPanel {
        if let terminalPanel { return terminalPanel }
        let panel = TerminalPanel(
            directory: { [weak self] in
                self?.folderURL ?? self?.displayedFileURL?.deletingLastPathComponent()
                    ?? FileManager.default.homeDirectoryForCurrentUser
            },
            onDockChange: { [weak self] dock in self?.moveTerminal(to: dock) },
            onLastShellExit: { [weak self] panel, panelHadFocus in
                guard let self, self.terminalPanel === panel, !self.app.isQuitting else { return }
                self.pendingTerminalFocus = nil
                self.hideTerminal(restoringContentFocus: panelHadFocus)
            },
            shell: TerminalPanel.loginShell(forAgentCheck: app.isAgentCheck),
            restoredState: saved?.panel
        )
        terminalPanel = panel
        let sizes = saved?.sizes ?? TerminalDockSizes()
        terminalDockView = TerminalDockView(terminal: panel.view, height: sizes.belowHeight) { [weak self] height in
            self?.setEditorBottomInset(height)
        }
        terminalSidebarWidth = sizes.rightWidth.isFinite && sizes.rightWidth > 0 ? sizes.rightWidth : TerminalDockSizes().rightWidth
        return panel
    }

    private func attachTerminal(focusing: Bool) {
        let panel = prepareTerminal()
        pendingTerminalFocus = nil
        if focusing { panel.prepareSpace() }
        if !isTerminalVisible {
            isTerminalVisible = true
            moveTerminal(to: panel.dock)
            panel.setVisible(true)
        }
        if focusing { panel.focusLastTerminal() }
    }

    private func terminalSessionState() -> DocumentTerminalState? {
        guard let terminalPanel, let terminalDockView else { return nil }
        let sizes = TerminalDockSizes(belowHeight: terminalDockView.savedHeight, rightWidth: currentTerminalSidebarWidth)
        return DocumentTerminalState(panel: terminalPanel.snapshot(), sizes: sizes,
                                     isVisible: isTerminalVisible || pendingTerminalFocus != nil,
                                     wasFocused: pendingTerminalFocus ?? terminalHasFocus(window.firstResponder))
    }

    private func moveTerminal(to dock: TerminalDock) {
        guard let terminalPanel, isTerminalVisible else { return }
        let alreadyDocked = dock == .right ? terminalSidebar != nil : terminalDockView?.superview != nil
        guard !alreadyDocked else { return }
        preserveEditorViewport {
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
        preserveEditorViewport { detachTerminalPanel() }
        if let responder = responder as? NSView, responder.window === window, window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
    }

    private func preserveEditorViewport(_ change: () -> Void) {
        let origin = scrollView.visibleContentOrigin
        PanelLayout.withoutAnimation {
            change()
            window.layoutIfNeeded()
            scrollView.scrollToVisibleContentOrigin(origin)
        }
    }

    private func setEditorBottomInset(_ height: CGFloat) {
        for case let view? in [scrollView as NSView?, filePreviewView, emptyFolderView, markdownPreview] {
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
        if command == .find || command == .findWorkspace || findScope == .workspace {
            return sidebar.canPerformFind(command)
        }
        if markdownPreview != nil {
            return command == .next || command == .previous || command == .toggleSidebar
        }
        if !hasTextDocument { return command == .toggleSidebar }
        if !hasEditableTextDocument && (command == .replace || command == .toggleReplace) { return false }
        return sidebar.canPerformFind(command)
    }

    func performFind(_ requestedCommand: FindCommand) {
        let command = requestedCommand == .findWorkspace && folderURL == nil ? .find : requestedCommand
        guard !app.isQuitting, window.attachedSheet == nil, canPerformFind(command) else { return }
        if let markdownPreview, command == .find || (findScope == .buffer && command != .findWorkspace) {
            switch command {
            case .find: sidebar.selectBufferSearch(); markdownPreview.showFind(); return
            case .next: markdownPreview.find(); return
            case .previous: markdownPreview.find(backward: true); return
            default: break
            }
        }
        sidebar.performFind(command)
    }

    func canFocusSidebar(_ mode: SidebarMode) -> Bool {
        guard !app.isQuitting, window.attachedSheet == nil else { return false }
        return switch mode {
        case .search: hasTextDocument
        case .references: sidebar.hasReferences
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
                                                 activeQuery: sidebar.isSearchVisible && findScope == .buffer ? findSettings.query : nil)
    }

    func restoreSidebar(_ record: SessionDocument) {
        // Older sessions omitted the mode for Search even when they saved its sidebar state.
        let saved = record.findSettings
        if let saved { findSettings = saved.search }
        if folderURL != nil { findScope = saved?.scope ?? .buffer }
        sidebar.restore(mode: record.sidebarMode ?? (saved == nil ? nil : .search),
                        width: saved?.width ?? SessionFindSettings.defaultWidth, visible: saved?.visible ?? false,
                        showsHidden: record.worktreeShowsHidden ?? false, searchTreeMode: record.searchTreeMode ?? false,
                        referencesTreeMode: record.referencesTreeMode ?? false)
    }

    func present(behind frontWindow: NSWindow? = nil) {
        if pendingFullScreen {
            app.scheduleFullScreenRestore(for: self)
        } else if let frontWindow {
            window.order(.below, relativeTo: frontWindow.windowNumber)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func restoreFullScreen() -> Bool {
        guard pendingFullScreen else { return false }
        normalFrame = window.frame
        // Native fullscreen requires an ordered window. Do not expose its normal frame.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        if !app.isAgentCheck { window.toggleFullScreen(nil) }
        return true
    }

    private func finishFullScreenEntry() {
        let wasRestoring = pendingFullScreen
        pendingFullScreen = false
        restoreVisibleTerminalIfReady()
        resizeTitleBars()
        titleBar.fullScreenTransitionDidFinish()
        if wasRestoring && !app.isAgentCheck {
            window.ignoresMouseEvents = false
            window.alphaValue = 1
        }
        app.didFinishFullScreenRestore(for: self)
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
        finishFullScreenEntry()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        normalFrame = nil
        finishFullScreenEntry()
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
        app.jjChanges.refreshSoon(sourceControlFileSubscription)
        app.updateJujutsuShortcut()
        if navigationHistory.isEmpty, !isBusy, displayedFileURL != nil || (hasTextDocument && !editor.string.isEmpty) {
            app.recordNavigation(in: self, reason: .selection)
        }
    }

    func windowDidEndSheet(_ notification: Notification) {
        fileRefresh.resume()
        scheduleSourceControlFileTransition()
        Task { @MainActor [weak self] in self?.reportAutosaveFailure() }
    }

    func checkForExternalFileChanges() { fileRefresh.check() }

    private func editorLostFocus() {
        requestAutosave()
        checkForExternalFileChanges()
    }

    private var canRefreshFile: Bool {
        canReplaceBuffer && !app.isQuitting && !window.isDocumentEdited && !autosave.hasWorker &&
            !sourceControlFileNeedsTransition && !editor.hasMarkedText() &&
            !(NSApp.isActive && window.isKeyWindow && contentHasFocus)
    }

    private func applyExternalFile(_ file: FileBuffer, openingConflicts: JJOpeningConflicts?) {
        let changedText = savedText?.isEqual(to: file.text) != true
        let position = changedText ? captureFileEditorPosition() : nil
        let changedRevision = revision != file.revision
        // The clean buffer may have a queued snapshot from before an undo.
        autosave.reset()
        updateIdentity(from: file)
        if changedText {
            installText(file.text, openingConflicts: openingConflicts, revealInWorktree: false)
            restoreEditorPosition(position)
        } else if changedRevision {
            updateJJContext()
        }
    }

    func load(
        _ file: FileBuffer, storedSyntaxLanguage: String? = nil, preparedSyntax: SyntaxSnapshot? = nil,
        openingConflicts: JJOpeningConflicts? = nil, scratch: ScratchFile? = nil, keepingMarkdownPresentation: Bool = false
    ) {
        clearSourceControlFile()
        installBuffer(file, storedSyntaxLanguage: storedSyntaxLanguage, preparedSyntax: preparedSyntax,
                      openingConflicts: openingConflicts, scratch: scratch, keepingMarkdownPresentation: keepingMarkdownPresentation)
    }

    private func installBuffer(
        _ file: FileBuffer, storedSyntaxLanguage: String? = nil, preparedSyntax: SyntaxSnapshot? = nil,
        openingConflicts: JJOpeningConflicts? = nil, scratch: ScratchFile? = nil, keepingMarkdownPresentation: Bool = false
    ) {
        resetMarkdownView(keepingPresentation: keepingMarkdownPresentation)
        removeSourceControlRevision()
        removeFilePreview()
        removeEmptyFolder()
        updateIdentity(from: file)
        scratchFile = scratch
        if let scratch { detectedSyntaxLanguage = SyntaxLanguage.detected(at: scratch.filenameURL) }
        manualSyntaxLanguage = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: fileURL)
        editor.setWordWrap(app.fileWordWrap.isEnabled(for: fileURL))
        installText(file.text, preparedSyntax: preparedSyntax, openingConflicts: openingConflicts)
    }

    func prepareOpeningSyntax(
        _ file: FileBuffer, position: EditorPosition?, folder: URL?, storedSyntaxLanguage: String? = nil,
        scratch: ScratchFile? = nil
    ) async -> SyntaxSnapshot? {
        let lineHeight = max(1, editor.defaultParagraphStyle?.maximumLineHeight ?? 18)
        return await Self.prepareOpeningSyntax(
            file, position: position, folder: folder, storedSyntaxLanguage: storedSyntaxLanguage, scratch: scratch,
            app: app, visibleLines: Int(ceil(scrollView.bounds.height / lineHeight)) + 2
        )
    }

    static func prepareOpeningSyntax(
        _ file: FileBuffer, position: EditorPosition?, folder: URL?, storedSyntaxLanguage: String?,
        scratch: ScratchFile?, app: Edit, visibleLines: Int
    ) async -> SyntaxSnapshot? {
        let language = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: file.url) ?? SyntaxLanguage.detected(at: scratch?.filenameURL ?? file.url)
        guard app.workspaceHighlighting.isEnabled(.treeSitter, in: folder), language != .plainText,
              position?.topLine != nil || (position?.verticalOffset ?? 0) <= 0 else { return nil }
        let topOffset = position?.topLine?.textOffset ?? 0
        let task = Task.detached(priority: .userInitiated) {
            SyntaxEngine.prepareOpening(file.text, language: language, topOffset: topOffset, visibleLines: visibleLines)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func loadPreview(_ preview: OpenFilePreview, revealInWorktree: Bool = true) {
        clearSourceControlFile()
        removeSourceControlRevision()
        installFilePreview(preview, revealInWorktree: revealInWorktree)
    }

    private func installFilePreview(_ preview: OpenFilePreview, revealInWorktree: Bool) {
        resetMarkdownView()
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
        editor.setWordWrap(false)
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

    func openSourceControlFile(
        _ file: JJSourceControlFile, in change: JJSourceControlRevision, workspace: JJWorkspace,
        operationID: String, markdownLink: MarkdownLinkOpening? = nil, while isWanted: @escaping () -> Bool
    ) async -> Bool {
        guard canRequestOpen, isWanted(), !app.isQuitting else { return false }
        let selection = SourceControlFile(file: file, revision: change, workspace: workspace, operationID: operationID)
        let url = selection.url
        let folder = folderURL
        let opensWorkingCopy = change.isWorkingCopy && !file.isDeleted
        let metadata = opensWorkingCopy ? SourceControlRevisionPreview.metadata(for: file, at: url) : nil
        do {
            if opensWorkingCopy && metadata == nil {
                guard try await app.openFile(url, in: self, focusEditor: false, markdownLink: markdownLink, shouldOpen: isWanted) != nil,
                      isWanted(), !Task.isCancelled, displayedFileURL == FileBuffer.canonicalURL(url) else { return false }
                if let fileURL, hasEditableTextDocument {
                    pendingSourceControlDiffFile = editor.jjInlineDiff?.expandAll() == true ? nil : fileURL
                }
                observeSourceControlFile(selection)
                return true
            }

            let generation = beginOpenRequest()
            let isCurrent = { [self] in
                !Task.isCancelled && !app.isQuitting && openRequestGeneration == generation && folderURL == folder &&
                    isWanted() && app.documents.contains(where: { $0 === self })
            }
            let destination: CloseDestination
            if let metadata {
                destination = .preview(metadata, focusEditor: false)
            } else {
                let contents = try await JJSourceControlRepository.file(file, in: change, workspace: workspace, at: operationID)
                guard isCurrent() else { return false }
                let preview = try await SourceControlRevisionPreview.prepare(contents, file: file, revision: change, at: url)
                destination = .sourceControlPreview(preview, selection: selection)
            }
            guard await open(destination, markdownLink: markdownLink, while: isCurrent), isCurrent() else { return false }
            if metadata != nil { observeSourceControlFile(selection) }
            return true
        } catch {
            if isWanted(), !app.isQuitting, !Task.isCancelled, canReplaceBuffer,
               app.documents.contains(where: { $0 === self }) {
                await showError("Could Not Open “\(url.lastPathComponent)”", detail: error.localizedDescription)
            }
            return false
        }
    }

    private func observeSourceControlFile(_ selection: SourceControlFile) {
        clearSourceControlFile()
        sourceControlFile = selection
        sourceControlFileSubscription = app.jjChanges.subscribe(to: selection.workspace) { [weak self] contents in
            guard let self, let state = contents?.repository else { return }
            recordSourceControlCheckout(state)
            scheduleSourceControlFileTransition()
            fileRefresh.resume()
        }
    }

    private func clearSourceControlFile() {
        rememberMarkdownRevisionPosition()
        sourceControlFileTransition?.cancel()
        sourceControlFileTransition = nil
        app.jjChanges.unsubscribe(sourceControlFileSubscription)
        sourceControlFileSubscription = nil
        sourceControlCheckout = nil
        lastLiveSourceControlCheckout = nil
        sourceControlFile = nil
    }

    private func recordSourceControlCheckout(_ state: JJRepositoryState) {
        guard let sourceControlFile, sourceControlFile.workspace == state.workspace else { return }
        sourceControlCheckout = state
        if sourceControlFile.ownsWorkingCopy(state) { lastLiveSourceControlCheckout = state }
    }

    private var sourceControlFileNeedsTransition: Bool {
        guard let sourceControlFile, let sourceControlCheckout else { return false }
        let shouldBeLive = sourceControlFile.ownsWorkingCopy(sourceControlCheckout) &&
            sourceControlCheckout.changes[sourceControlFile.file.path]?.status != .removed
        return shouldBeLive != (sourceControlRevision == nil)
    }

    private func validateSourceControlDiskOwner() async -> Bool {
        guard let selection = sourceControlFile else { return true }
        guard let head = try? await JJRepository.operation(in: selection.workspace), selection == sourceControlFile else {
            return false
        }
        if sourceControlCheckout?.operationID != head {
            // A disk event can arrive before the workspace watcher publishes the checkout.
            guard let state = try? await JJRepository.read(selection.workspace, at: head),
                  (try? await JJRepository.operation(in: selection.workspace)) == head,
                  selection == sourceControlFile else { return false }
            recordSourceControlCheckout(state)
            scheduleSourceControlFileTransition()
        }
        return !sourceControlFileNeedsTransition
    }

    private func scheduleSourceControlFileTransition() {
        guard canReplaceBuffer, !app.isQuitting, !window.isDocumentEdited, !autosave.hasWorker,
              !editor.hasMarkedText(), sourceControlFileNeedsTransition, sourceControlFileTransition == nil else { return }
        sourceControlFileTransition = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let state = sourceControlCheckout, sourceControlFileNeedsTransition {
                await transitionSourceControlFile(discard: false, duringMutation: false)
                // A newer observation during the load gets a fresh attempt.
                if sourceControlCheckout?.operationID == state.operationID { break }
            }
            if !Task.isCancelled { sourceControlFileTransition = nil }
        }
    }

    private func transitionSourceControlFile(discard: Bool, duringMutation: Bool) async {
        guard let selection = sourceControlFile, let state = sourceControlCheckout, sourceControlFileNeedsTransition else { return }
        let generation = openRequestGeneration
        func isCurrent() -> Bool {
            !Task.isCancelled && !app.isQuitting && sourceControlCheckout?.operationID == state.operationID &&
                sourceControlFile == selection && openRequestGeneration == generation &&
                (duringMutation || (canReplaceBuffer && !autosave.hasWorker && !editor.hasMarkedText())) &&
                (discard || !window.isDocumentEdited)
        }
        guard isCurrent() else { return }

        do {
            let preview: (details: SourceControlRevisionPreview, operationID: String)?
            let live: OpenedFile?
            let openingConflicts: JJOpeningConflicts?
            if selection.ownsWorkingCopy(state) && state.changes[selection.file.path]?.status != .removed {
                let opened = try await Edit.readForOpening(selection.url, within: selection.workspace.root)
                // A sparse or missing path has no writable working-copy representation.
                guard opened.identity != nil else { return }
                live = opened
                preview = nil
                if case .text(let file) = opened {
                    openingConflicts = await JJOpeningConflicts.prepare(file.text, at: file.url)
                } else {
                    openingConflicts = nil
                }
            } else {
                let (file, revision, contents, snapshot) = try await JJSourceControlRepository.departedFile(
                    selection.file, from: selection.revision, lastCommitID: lastLiveSourceControlCheckout?.commitID ?? selection.revision.id,
                    lastOperationID: lastLiveSourceControlCheckout?.operationID ?? selection.operationID,
                    in: selection.workspace, at: state.operationID
                )
                let details = try await SourceControlRevisionPreview.prepare(contents, file: file, revision: revision, at: selection.url)
                preview = (details, snapshot)
                live = nil
                openingConflicts = nil
            }
            guard isCurrent(), try await JJRepository.operation(in: selection.workspace) == state.operationID,
                  isCurrent() else { return }
            let position = hasTextDocument ? captureFileEditorPosition() : nil
            let wasFocused = contentHasFocus
            PanelLayout.withoutAnimation {
                autosave.reset()
                if let preview {
                    loadSourceControlRevision(preview.details, workspace: selection.workspace, operationID: preview.operationID)
                } else if let live {
                    switch live {
                    case .text(let file):
                        installBuffer(file, openingConflicts: openingConflicts)
                        pendingSourceControlDiffFile = file.url
                        activity.restoreEditabilityAfterMutation()
                        editor.isEditable = !duringMutation
                        if conflictPresentationCurrent { updateConflictActions() }
                    case .preview(let details):
                        removeSourceControlRevision()
                        installFilePreview(details, revealInWorktree: false)
                    }
                }
                if wasFocused { focusContent() }
                window.layoutIfNeeded()
                if hasTextDocument { restoreEditorPosition(position) }
            }
        } catch {
            // Keep the current buffer if a concurrently rewritten revision cannot supply a replacement.
        }
    }

    private func loadSourceControlRevision(_ preview: SourceControlRevisionPreview, workspace: JJWorkspace, operationID: String,
                                           keepingMarkdownPresentation: Bool = false) {
        resetMarkdownView(keepingPresentation: keepingMarkdownPresentation)
        removeSourceControlRevision()
        removeFilePreview()
        removeEmptyFolder()
        autosave.reset()
        sourceControlRevision = preview
        switch preview.content {
        case .text(let text, let format, let analysis, _):
            fileURL = nil
            fileIdentity = nil
            revision = nil
            manualSyntaxLanguage = nil
            detectedSyntaxLanguage = .detected(at: preview.url)
            savedText = text as NSString
            self.format = format
            editor.isEditable = false
            editor.setWordWrap(app.fileWordWrap.isEnabled(for: wordWrapFileURL))
            installText(text, confirmedConflicts: analysis.conflicts)
            setConflictAnalysisMarks(analysis)
            editor.jjInlineDiff?.expandAll()
        case .media(let media):
            installFilePreview(media, revealInWorktree: false)
        }

        let context = SourceControlRevisionHover.LinkContext(workspace: workspace, operationID: operationID)
        sourceControlRevisionBanner = SourceControlRevisionBanner(preview, linkContext: context, ownerWindow: window)
        updateDocumentHeader()
    }

    private func removeSourceControlRevision() {
        guard sourceControlRevision != nil else { return }
        sourceControlRevision = nil
        editor.setJJLineMarks([])
        sourceControlRevisionBanner?.dismissHover()
        sourceControlRevisionBanner = nil
        editor.conflictEdits.removeAll()
        showEditorConflicts([])
        updateDocumentHeader()
    }

    func loadEmptyFolder() {
        clearSourceControlFile()
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
        resetMarkdownView()
        clearSourceControlFile()
        navigationBufferID = UUID()
        fileURL = nil
        manualSyntaxLanguage = nil
        fileIdentity = nil
        savedText = "" as NSString
        format = FileFormat()
        revision = nil
        autosave.clearFailure()
        editor.setWordWrap(false)
        installText("")
    }

    private func pinToEditorContent(_ view: NSView, below presentation: NSView? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let presentation {
            editorContentView.addSubview(view, positioned: .below, relativeTo: presentation)
        } else if let dock = terminalDockView, dock.superview === editorContentView {
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

    private func updateDocumentHeader() {
        titleBar.setDocumentStatus(revision: sourceControlRevisionBanner, conflict: conflictPanel)
    }

    func restoreDraft(_ record: SessionDocument, text: String, identity: FileIdentity? = nil, scratch: ScratchFile? = nil,
                      openingConflicts: JJOpeningConflicts? = nil, restoredConflicts: [JJConflictEdit] = []) {
        resetMarkdownView()
        clearSourceControlFile()
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
        editor.setWordWrap(app.fileWordWrap.isEnabled(for: fileURL))
        installText(text, openingConflicts: openingConflicts, restoredConflicts: restoredConflicts)
        if fileURL == nil {
            draftRecoveryRevision = record.draftRecovery
            scheduleDraftCheckpoint()
        }
    }

    func sessionDocument() -> SessionDocument {
        let savedFind = SessionFindSettings(search: findSettings, sidebarVisible: sidebar.isVisible, sidebarWidth: sidebar.width,
                                             scope: findScope)
        let conflictDrafts = inlineConflictDrafts
        return SessionDocument(
            path: displayedFileURL?.path,
            draft: window.isDocumentEdited ? textWithConflictPrefixes : nil,
            format: fileURL == nil ? nil : format,
            revision: revision,
            placement: placement,
            syntaxLanguage: manualSyntaxLanguage?.rawValue,
            folderPath: folderURL?.path,
            findSettings: savedFind == .empty ? nil : savedFind,
            editorPosition: hasEditableTextDocument || markdownRevisionRecord != nil ? captureFileEditorPosition() : nil,
            sidebarMode: sidebar.rememberedMode,
            worktreeShowsHidden: sidebar.worktreeShowsHidden ? true : nil,
            searchTreeMode: sidebar.searchTreeMode ? true : nil,
            referencesTreeMode: sidebar.referencesTreeMode ? true : nil,
            isFilePreview: displayedFileURL != nil && isShowingFilePreview ? true : nil,
            showsEmptyFolder: folderURL != nil && displayedFileURL == nil ? showsEmptyFolder || sourceControlRevision != nil : nil,
            terminal: terminalSessionState(),
            inactiveTerminals: inactiveTerminals.isEmpty ? nil : inactiveTerminals.map { path, terminal in
                SessionFolderTerminal(folderPath: path, state: terminal)
            }.sorted { ($0.folderPath ?? "") < ($1.folderPath ?? "") },
            draftRecovery: draftRecoveryRevision,
            conflictDrafts: conflictDrafts.isEmpty ? nil : conflictDrafts,
            markdownRevision: markdownRevisionRecord
        )
    }

    func restoreEditorPosition(_ position: EditorPosition?, restoringMarkdown: Bool = true, showingMarkdownPreview: Bool? = nil) {
        guard hasTextDocument, let position else { return }
        // AppKit calculates the titlebar inset during layout, including in a window not presented yet.
        window.layoutIfNeeded()
        let projection = JJConflictEdit.projection(for: editor.conflictEdits)
        editor.restorePosition(position.mappingOffsets(projection.visibleOffset))
        if restoringMarkdown, resolvedSyntaxLanguage == .markdown {
            var state = position.markdown ?? MarkdownViewState()
            if let showingMarkdownPreview { state.showsPreview = showingMarkdownPreview }
            restoreMarkdownState(state)
        }
    }

    private func captureFileEditorPosition() -> EditorPosition {
        let projection = JJConflictEdit.projection(for: editor.conflictEdits)
        var position = editor.capturePosition().mappingOffsets(projection.rawOffset)
        if resolvedSyntaxLanguage == .markdown { position.markdown = markdownState }
        return position
    }

    func rememberFilePosition(_ position: EditorPosition? = nil) {
        guard let fileURL, let fileIdentity else { return }
        let position = position ?? captureFileEditorPosition()
        if let state = position.markdown {
            markdownFiles.removeAll { $0.url == fileURL || $0.identity == fileIdentity }
            markdownFiles.insert((fileURL, fileIdentity, state), at: 0)
            if markdownFiles.count > 100 { markdownFiles.removeLast() }
        }
        app.recentFiles.rememberPosition(position, for: fileURL, identity: fileIdentity)
    }

    private func rememberFileUndoHistory() {
        guard hasEditableTextDocument, let fileURL, let fileIdentity, let revision, revision != .missing else { return }
        fileUndoHistories.removeAll { $0.url == fileURL || $0.identity == fileIdentity }
        guard !window.isDocumentEdited else { return }

        let manager = editor.editorUndoManager
        editor.breakUndoCoalescing()
        while manager.groupingLevel > 0 { manager.endUndoGrouping() }
        guard manager.undoCount > 0 || manager.redoCount > 0 else { return }

        fileUndoHistories.append(FileUndoHistory(url: fileURL, identity: fileIdentity, revision: revision, format: format,
                                                manager: manager, focusRanges: editor.focusRanges,
                                                focusHistory: manager.focusHistory))
        if fileUndoHistories.count > Self.fileUndoHistoryLimit { fileUndoHistories.removeFirst() }
        // AppKit can update the active undo manager when the text view's storage is replaced.
        editor.exitFocus(notify: false)
        editor.editorUndoManager = EditorUndoManager()
    }

    private func takeFileUndoHistory(for file: FileBuffer) -> FileUndoHistory? {
        guard let index = fileUndoHistories.firstIndex(where: { $0.url == file.url || $0.identity == file.identity }) else {
            return nil
        }
        let history = fileUndoHistories.remove(at: index)
        guard history.identity == file.identity, history.revision == file.revision, history.format == file.format else {
            return nil
        }
        return history
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

        let text = textForSaving
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
        let text = textForSaving
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
        languageFeatures.documentDidSave(result.file.url, text: text)
    }

    private func adoptSavedFile(_ file: FileBuffer, scratch: ScratchFile? = nil) {
        let wasUntitled = fileURL == nil
        let changedPath = fileURL != file.url
        if changedPath {
            clearSourceControlFile()
            discardDraftCheckpoint()
            rememberFilePosition()
        }
        let previousLanguage = resolvedSyntaxLanguage
        updateIdentity(from: file)
        if let scratch {
            scratchFile = scratch
            detectedSyntaxLanguage = SyntaxLanguage.detected(at: scratch.filenameURL)
        }
        if changedPath {
            app.syntaxOverrides.set(manualSyntaxLanguage, for: fileURL)
            if wasUntitled && editor.wrapsWords { app.fileWordWrap.set(true, for: file.url) }
            editor.setWordWrap(app.fileWordWrap.isEnabled(for: file.url), preservingViewport: true)
        }
        if resolvedSyntaxLanguage != previousLanguage {
            refreshSyntax(immediate: true)
        }
        updateTitle()
        updateEditedState()
        autosave.clearFailure()
    }

    func canApplyWorkspaceFind(_ change: WorkspaceFindReplacement.Change, disk: FileBuffer) -> Bool {
        fileURL?.path == disk.url.path && revision == disk.revision && fileIdentity == disk.identity &&
            editor.conflictEdits.isEmpty && editor.renameRange == nil && !editor.hasMarkedText() &&
            editor.jjInlineDiff?.projectedEditRange == nil && editor.textStorage != nil &&
            editor.string.utf8.elementsEqual(change.original.utf8) && editor.focusAllowsSourceEdits(change.edits.map(\.range))
    }

    func applyWorkspaceFind(_ change: WorkspaceFindReplacement.Change, saved: FileBuffer) {
        let selections = MultiCaretEditing.mapped(editor.caretSelections, after: change.edits)
        _ = editor.applyMultiEdits(change.edits, selections: selections, validate: false, actionName: "Replace in Workspace")
        adoptSavedFile(saved)
        autosave.didSave(through: autosave.generation)
    }

    var canScheduleAutosave: Bool {
        fileURL != nil && !app.isQuitting && !sourceControlFileNeedsTransition &&
            (window.isDocumentEdited || autosave.hasWorker || activity.isSaving)
    }

    var canRunAutosave: Bool { !isBusy && !app.isQuitting && !sourceControlFileNeedsTransition }

    func requestAutosave() { autosave.request() }

    func autosaveDidFinish() {
        fileRefresh.resume()
        scheduleSourceControlFileTransition()
        reportAutosaveFailure()
    }

    // Closing, replacing, and quitting hold off new writes while draining the queue.
    func flushAutosave() async { await autosave.flush() }

    func writeAutosave(_ text: String) async throws {
        guard let target = fileURL, let revision, savedText?.isEqual(to: text) != true else { return }
        guard await validateSourceControlDiskOwner(), target == fileURL else { throw FileBufferError.changedOnDisk }
        guard app.reserveSave(to: target, identity: fileIdentity, for: self) else {
            throw DocumentAutosave.WriteError.inUse
        }
        defer { app.finishSave(to: target) }
        try await write(text, to: target, format: format, expected: revision)
    }

    func worktreeMutationAffects(_ sources: [URL]) -> Bool {
        sources.contains { source in
            [displayedFileURL ?? sourceControlFile?.url, folderURL].compactMap { $0 }.contains {
                Self.worktreePathSuffix(from: source, to: $0) != nil
            }
        }
    }

    func beginWorktreeMutation(preservingRename: Bool) {
        if !preservingRename, editor.renameRange != nil { _ = editor.onCancelSymbolRename?() }
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
        scheduleSourceControlFileTransition()
    }

    @discardableResult
    func performSourceControlMutation(
        in workspace: JJWorkspace, discardingChangesTo files: [URL]? = nil, operation: @MainActor () async throws -> Void
    ) async throws -> Bool {
        let paths = files ?? [workspace.root]
        let affected = app.documents.filter { document in
            guard let file = document.fileURL ?? (document.sourceControlFile?.workspace == workspace
                ? document.sourceControlFile?.url : nil) else { return false }
            return paths.contains { path in
                guard let suffix = Self.worktreePathSuffix(from: path, to: file) else { return false }
                return files == nil || suffix.isEmpty
            }
        }
        return try await app.performWorktreeMutation(affecting: paths) {
            var discarded: Set<ObjectIdentifier> = []
            for document in affected where document.window.isDocumentEdited {
                if files != nil {
                    discarded.insert(ObjectIdentifier(document))
                    continue
                }
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
            let checkout: JJRepositoryState?
            if affected.contains(where: { $0.sourceControlFile?.workspace == workspace }),
               let head = try? await JJRepository.operation(in: workspace) {
                checkout = try? await JJRepository.read(workspace, at: head)
            } else {
                checkout = nil
            }
            for document in affected {
                let discard = discarded.contains(ObjectIdentifier(document))
                if let checkout, document.sourceControlFile?.workspace == workspace {
                    document.recordSourceControlCheckout(checkout)
                    if document.sourceControlFileNeedsTransition {
                        await document.transitionSourceControlFile(discard: discard, duringMutation: true)
                        continue
                    }
                }
                await document.refreshAfterSourceControlMutation(discard: discard)
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
        let position = captureFileEditorPosition()
        switch try? await Edit.readForOpening(url) {
        case .text(let file):
            let conflicts = await JJOpeningConflicts.prepare(file.text, at: file.url)
            guard !Task.isCancelled, fileURL == url else { return }
            if discard {
                autosave.reset()
                updateIdentity(from: file)
                installText(file.text, openingConflicts: conflicts, revealInWorktree: false)
            } else {
                applyExternalFile(file, openingConflicts: conflicts)
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
        clearSourceControlFile()
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
            editor.setWordWrap(false)
            installText("")
        }
        if wasPreview && wasFocused { focusContent() }
    }

    private var contentHasFocus: Bool {
        if let markdownPreview { return markdownPreview.containsResponder(window.firstResponder) }
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
        guard editor.renameRange == nil, let manager = notification.object as? UndoManager,
              manager === editor.undoManager else { return }
        editor.occurrenceHighlighting.contentChanged()
        editor.requestLineRefresh()
        textDidChange()
    }

    private func textDidChange() {
        titleBar.updateCaretPosition()
        if conflictPanel != nil || !editor.conflictEdits.isEmpty {
            conflictStyleTask?.cancel()
            conflictApplyTask?.cancel()
            conflictApplyTask = nil
            failedConflictDiffs.removeAll()
            showEditorConflicts([])
        }
        pendingSourceControlDiffFile = nil
        autosave.noteEdit()
        updateEditedState()
        scheduleDraftCheckpoint()
        autosave.scheduleIdle()
        languageFeatures.documentTextChanged()
        refreshSyntax(immediate: false)
        jjDocumentChanges?.bufferChanged()
        if !isBusy, window.firstResponder === editor { app.recordNavigation(in: self, reason: .edit) }
    }

    private func refreshSyntax(immediate: Bool, preparedSyntax: SyntaxSnapshot? = nil, allowsLSP: Bool = true) {
        defer { refreshTestCodeLens() }
        let language = resolvedSyntaxLanguage
        refreshMarkdown(immediate: immediate)
        editor.syntaxLanguage = language
        editor.bracketNavigation.setLanguage(language)
        editor.occurrenceHighlighting.update(language: language)
        if language == .plainText {
            syntaxHighlighting?.cancel()
            return
        }
        if syntaxHighlighting == nil {
            syntaxHighlighting = SyntaxHighlighting(editor: editor)
        }
        let local = isHighlightingEnabled(.treeSitter)
        if local, let preparedSyntax, preparedSyntax.language == language {
            syntaxHighlighting?.install(preparedSyntax)
        } else {
            syntaxHighlighting?.update(language: language, immediate: immediate, treeSitter: local,
                                       session: allowsLSP ? languageFeatures.highlightingSession : nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canCloseDocument else { return false }
        guard window.isDocumentEdited || autosave.hasWorker || editor.hasMarkedText() else { return true }
        requestClose(.window)
        return false
    }

    func closeDocument() {
        guard canCloseDocument else { return }
        if folderURL != nil {
            // Holding Command-W must not dispatch both steps of a project close.
            if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat,
               event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" { return }
            if !showsEmptyFolder {
                requestClose(.emptyFolder(focusContent: true))
                return
            }
        }
        window.performClose(nil)
    }

    func closeWorkspace() {
        guard canCloseWorkspace, let folder = folderURL else { return }
        if sourceControlRevision != nil || displayedFileURL.map({ WorktreeFileOperations.contains($0, in: folder) }) == true {
            requestClose(.workspace)
        } else {
            _ = beginOpenRequest()
            sidebar.hideWorkspacePanel()
            setFolder(nil)
            app.workspaceDidClose(in: self)
        }
    }

    private func requestClose(_ destination: CloseDestination) {
        activity.beginClose(invalidateOpenRequests: true)
        Task { await closeBuffer(destination: destination) }
    }

    func newBuffer() async {
        guard canReplaceBuffer, !app.isQuitting else { return }
        activity.beginClose(invalidateOpenRequests: true)
        await closeBuffer(destination: .buffer(nil))
    }

    func open(_ destination: CloseDestination, markdownLink: MarkdownLinkOpening? = nil, while isCurrent: () -> Bool) async -> Bool {
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
        return await closeBuffer(destination: destination, markdownLink: markdownLink, while: isCurrent)
    }

    @discardableResult
    private func closeBuffer(destination: CloseDestination, markdownLink: MarkdownLinkOpening? = nil,
                             while isCurrent: () -> Bool = { true }) async -> Bool {
        if editor.hasMarkedText() { editor.unmarkText() }
        let previousFolder = folderURL
        let wasEditable = !hasEditableTextDocument || editor.isEditable
        editor.isEditable = false
        defer {
            editor.isEditable = hasEditableTextDocument && wasEditable
            if conflictPresentationCurrent { updateConflictActions() }
            activity.endReplacement()
            if folderURL != previousFolder {
                sidebar.folderChanged()
                if folderURL == nil { app.workspaceDidClose(in: self) }
            }
            autosave.resume()
            fileRefresh.resume()
            scheduleSourceControlFileTransition()
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
        return await finishClose(choice, destination: destination, markdownLink: markdownLink, while: isCurrent)
    }

    @discardableResult
    func finishClose(
        _ choice: CloseChoice, destination: CloseDestination = .window, markdownLink: MarkdownLinkOpening? = nil,
        while isCurrent: () -> Bool = { true }
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

        let previousResource = navigationResource
        switch destination {
        case .workspace:
            #if EDIT_AGENT_CHECKS
            if let beforeCloseWorkspaceForCheck {
                await beforeCloseWorkspaceForCheck()
                guard isCurrent(), !Task.isCancelled else { return false }
            }
            #endif
            rememberFilePosition()
            rememberFileUndoHistory()
            app.recordClosedFile(in: self)
            sidebar.hideWorkspacePanel()
            changeFolder(to: nil) {
                installUntitled()
                focusContent()
            }
        case .buffer(let file, let focusEditor, let scratch, let folder):
            let restoreFocus = focusEditor || contentHasFocus
            let previousFolder = folderURL
            // Saving the outgoing draft to the target already installed the latest revision.
            let incoming = file?.url == fileURL ? nil : file
            editor.breakUndoCoalescing()
            var position: EditorPosition?
            var undoHistory: FileUndoHistory?
            var preparedSyntax: SyntaxSnapshot?
            var openingConflicts: JJOpeningConflicts?
            var preparedMarkdown: PreparedMarkdownOpening?
            if let file = incoming {
                rememberFilePosition()
                position = await app.recentFiles.position(for: file.url, identity: file.identity)
                if let state = markdownFiles.first(where: { $0.url == file.url || $0.identity == file.identity })?.state {
                    if position == nil { position = EditorPosition(selections: [], horizontalOffset: 0, verticalOffset: 0, topLine: nil) }
                    position?.markdown = state
                }
                guard isCurrent(), !Task.isCancelled else { return false }
                let openingPosition = position
                let openingFolder = folder ?? folderURL
                async let syntax = prepareOpeningSyntax(file, position: openingPosition,
                                                        folder: openingFolder, scratch: scratch)
                async let conflicts = JJOpeningConflicts.prepare(file.text, at: scratch == nil ? file.url : nil)
                (preparedSyntax, openingConflicts) = await (syntax, conflicts)
                guard isCurrent(), !Task.isCancelled else { return false }
                let language = app.syntaxOverrides.language(for: file.url) ?? .detected(at: scratch?.filenameURL ?? file.url)
                if language == .markdown, (markdownLink?.showsPreview ?? position?.markdown?.showsPreview) == true {
                    let source = JJConflictEdit.project(openingConflicts?.blocks ?? [], in: file.text).text
                    guard let prepared = await prepareMarkdownOpening(source, position: position, fragment: markdownLink?.fragment,
                        writable: file.revision == .missing || FileManager.default.isWritableFile(atPath: file.url.path),
                        while: isCurrent) else { return false }
                    guard isCurrent(), !Task.isCancelled else { prepared.view.removeFromSuperview(); return false }
                    preparedMarkdown = prepared
                }
                #if EDIT_AGENT_CHECKS
                if let beforeInstallFileForCheck {
                    await beforeInstallFileForCheck(file)
                    guard isCurrent(), !Task.isCancelled else { preparedMarkdown?.view.removeFromSuperview(); return false }
                }
                #endif
                rememberFileUndoHistory()
            } else if file == nil {
                rememberFilePosition()
                rememberFileUndoHistory()
            }
            changeFolder(to: folder ?? folderURL) {
                if let file = incoming {
                    load(file, preparedSyntax: preparedSyntax, openingConflicts: openingConflicts, scratch: scratch,
                         keepingMarkdownPresentation: preparedMarkdown != nil)
                    undoHistory = takeFileUndoHistory(for: file)
                    if let undoHistory { editor.editorUndoManager = undoHistory.manager }
                } else if file == nil {
                    installUntitled()
                } else if folderURL != previousFolder {
                    updateTitle()
                    updateTreeSitterHighlighting()
                }
                autosave.clearFailure()
                finishOpeningPresentation(preparedMarkdown, position: position, focus: restoreFocus, markdownLink: markdownLink)
            }
            if let undoHistory, let focusHistory = undoHistory.focusHistory, editor.focusRanges == undoHistory.focusRanges,
               editor.focusRanges != nil {
                undoHistory.manager.restoreFocusHistory(focusHistory)
            }
            if focusEditor { app.recordNavigation(in: self, reason: .selection) }
        case .preview(let preview, let focusEditor, let folder):
            let restoreFocus = focusEditor || contentHasFocus
            autosave.clearFailure()
            rememberFilePosition()
            rememberFileUndoHistory()
            changeFolder(to: folder ?? folderURL) {
                loadPreview(preview)
                if restoreFocus { focusContent() }
            }
            if focusEditor { app.recordNavigation(in: self, reason: .selection) }
        case .sourceControlPreview(let preview, let selection):
            let restoreFocus = contentHasFocus
            let position = markdownRevisions[markdownRevisionKey(selection)]?.1
            var preparedMarkdown: PreparedMarkdownOpening?
            if case .text(let text, _, let analysis, _) = preview.content, SyntaxLanguage.detected(at: preview.url) == .markdown,
               (markdownLink?.showsPreview ?? position?.markdown?.showsPreview) == true {
                let source = JJConflictEdit.project(analysis.conflicts, in: text).text
                guard let prepared = await prepareMarkdownOpening(source, position: position, fragment: markdownLink?.fragment,
                    writable: false, while: isCurrent) else { return false }
                guard isCurrent(), !Task.isCancelled else { prepared.view.removeFromSuperview(); return false }
                preparedMarkdown = prepared
            }
            rememberFilePosition()
            rememberFileUndoHistory()
            clearSourceControlFile()
            loadSourceControlRevision(preview, workspace: selection.workspace, operationID: selection.operationID,
                                      keepingMarkdownPresentation: preparedMarkdown != nil)
            observeSourceControlFile(selection)
            finishOpeningPresentation(preparedMarkdown, position: position, focus: restoreFocus, markdownLink: markdownLink)
        case .emptyFolder(let focus, let folder):
            let restoreFocus = focus || contentHasFocus
            rememberFilePosition()
            rememberFileUndoHistory()
            if folder == nil { app.recordClosedFile(in: self) }
            changeFolder(to: folder ?? folderURL) {
                loadEmptyFolder()
                if restoreFocus { focusContent() }
            }
        case .window:
            window.close()
        }
        if case .buffer(let id) = previousResource, navigationResource != .buffer(id) {
            navigationHistory.remove(resource: .buffer(id))
        }
        return true
    }

    private func changeFolder(to folder: URL?, _ install: () -> Void) {
        guard folderURL?.path != folder?.path else { install(); return }
        let terminalHadFocus = terminalHasFocus(window.firstResponder)
        if let state = terminalSessionState() {
            inactiveTerminals[folderURL?.path] = state
            pendingTerminalFocus = nil
            hideTerminal(restoringContentFocus: false)
            closeTerminalSessions()
            terminalPanel = nil
            terminalDockView = nil
        }
        folderURL = folder
        install()
        if terminalHadFocus { focusContent() }
        restoreTerminal(inactiveTerminals.removeValue(forKey: folder?.path))
    }

    private func installUntitled() {
        removeSourceControlRevision()
        removeFilePreview()
        removeEmptyFolder()
        resetDocument()
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
        if !inlineConflictDrafts.isEmpty {
            alert.messageText = "Discard unfinished edits to “\(displayName)”?"
            alert.informativeText = "The original conflict stays in the working copy. Choose Keep Editing to finish resolving it."
            alert.addButton(withTitle: "Keep Editing").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: "Discard Edits").hasDestructiveAction = true
            return await response(to: alert) == .alertSecondButtonReturn ? .discard : .cancel
        }
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

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        markdownPreview?.fieldEditor(for: client)
    }

    var canFocusSelection: Bool { markdownPreview == nil && canReplaceBuffer && hasEditableTextDocument && editor.canFocusSelection }
    var canExitFocus: Bool { markdownPreview == nil && canReplaceBuffer && editor.focusRanges != nil }

    var currentMarkdownTable: MarkdownTable? {
        guard markdownPreview == nil, hasEditableTextDocument, canReplaceBuffer, editor.isEditable,
              resolvedSyntaxLanguage == .markdown, !editor.hasMarkedText() else { return nil }
        let source = editor.string
        let caret = editor.selectedRange().location
        if markdownTableContext?.caret != caret || markdownTableContext?.source != source {
            markdownTableContext = (source, caret, MarkdownTable(source: source, caret: caret))
        }
        guard let table = markdownTableContext?.table, editor.focusAllowsEdits([table.range]) else { return nil }
        return table
    }

    @objc func performMarkdownTableCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MarkdownTableCommand, let table = currentMarkdownTable else { return }
        let edit = table.edit(command)
        let source = editor.string as NSString
        guard source.substring(with: table.range) != edit.text else { return }
        if editor.applyMultiEdits([EditorTextEdit(range: table.range, text: edit.text)],
                                  selections: [NSRange(location: edit.caret, length: 0)], actionName: command.title) {
            focusContent()
            editor.scrollRangeToVisible(NSRange(location: edit.caret, length: 0))
        }
    }

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
        app.recordClosedFile(in: self)
        if !app.isQuitting { discardDraftCheckpoint() }
        fileRefresh.stop()
        languageFeatures.close()
        zigTestStart?.cancel()
        editor.testCodeLens?.reset()
        closeTerminalSessions()
        jjDocumentChanges?.stop()
        clearSourceControlFile()
        rememberFilePosition()
        editor.exitFocus(notify: false)
        filePreviewView?.stop()
        markdownRender?.cancel()
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
        _ text: String, preparedSyntax: SyntaxSnapshot? = nil, openingConflicts: JJOpeningConflicts? = nil,
        confirmedConflicts: [JJConflict] = [], restoredConflicts: [JJConflictEdit] = [], revealInWorktree: Bool = true,
        preservingConflictPresentation: Bool = false
    ) {
        if editor.renameRange != nil { _ = editor.onCancelSymbolRename?() }
        navigationSelectionAnchor = nil
        titleBar.invalidateCaretLine(from: 0)
        let projection = restoredConflicts.isEmpty
            ? JJConflictEdit.project(openingConflicts?.blocks ?? confirmedConflicts, in: text)
            : (text: text, edits: restoredConflicts)
        conflictStyleTask?.cancel()
        editor.conflictEdits.removeAll()
        failedConflictDiffs.removeAll()
        if !preservingConflictPresentation { showEditorConflicts([]) }
        pendingSourceControlDiffFile = nil
        discardDraftCheckpoint()
        editor.exitFocus(notify: false)
        editor.preferredLineEnding = format.lineEnding
        editor.resetMultiCarets()
        syntaxHighlighting?.prepareForBufferReplacement()
        editor.testCodeLens?.reset()
        editor.bracketNavigation.reset()
        editor.occurrenceHighlighting.reset()
        editor.string = projection.text
        editor.conflictEdits = projection.edits
        refreshSyntax(immediate: true, preparedSyntax: projection.text.utf8.elementsEqual(text.utf8) ? preparedSyntax : nil,
                      allowsLSP: false)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.requestLineRefresh()
        editor.undoManager?.removeAllActions()
        if preservingConflictPresentation || !projection.edits.isEmpty { showEditorConflicts([]) }
        updateTitle(revealInWorktree: revealInWorktree)
        updateEditedState()
        sidebar.editorBufferReplaced()
        jjDocumentChanges?.bufferReplaced(openingConflictOperation: openingConflicts?.operation)
        editor.scrollRangeToVisible(editor.selectedRange())
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
        languageFeatures.updateDocument()
        refreshTestCodeLens()
        sidebar.documentTitleChanged(reveal: revealInWorktree)
        updateJJContext()
    }

    func updateJJContext() {
        let file = hasTextDocument && scratchFile == nil ? fileURL : nil
        let folder = worktreeSidebar?.isObservingWorktree == true ? folderURL : nil
        if jjDocumentChanges == nil {
            guard file != nil || folder != nil else { return }
            jjDocumentChanges = JJDocumentChanges(monitor: app.jjChanges, text: { [weak self] in
                guard let self, !editor.hasMarkedText() else { return nil }
                return textWithConflictPrefixes
            }, showMarks: { [weak self] result, normalizeCRLF in
                guard let self, sourceControlRevision == nil else { return }
                showEditorConflicts(result?.conflicts ?? [])
                setConflictAnalysisMarks(result, normalizeCRLF: normalizeCRLF)
                if result != nil, pendingSourceControlDiffFile != nil, pendingSourceControlDiffFile == fileURL {
                    pendingSourceControlDiffFile = nil
                    editor.jjInlineDiff?.expandAll()
                }
            }, suspendMarkerNavigation: { [weak self] in
                guard let self else { return }
                editor.suspendJJMarkerNavigation()
                // The conflict block's tracked ranges are updated by the editor before the
                // repository's diff refresh. Its inline actions still have current text.
                if editor.conflictEdits.isEmpty { suspendConflictControls(keepingPresentation: true) }
            }, showWorktree: { [weak self] decorations in
                self?.worktreeSidebar?.setJJDecorations(decorations)
            }, workingCopyStatusChanged: { [weak self] in
                self?.sourceControlSidebar?.updateLiveFile()
            })
            editor.onJJCompositionChange = { [weak self] in self?.jjDocumentChanges?.bufferChanged() }
        }
        jjDocumentChanges?.update(file: file, revision: revision, folder: folder)
    }

    private func showEditorConflicts(_ confirmed: [JJConflict]) {
        installNewConflictProjections(confirmed)
        let source = editor.string as NSString
        let conflicts = editor.conflictEdits.compactMap { $0.displayed(in: source) }
        conflictBlocks = conflicts
        conflictPresentationCurrent = !conflicts.isEmpty
        if !conflicts.isEmpty && syntaxHighlighting == nil { syntaxHighlighting = SyntaxHighlighting(editor: editor) }
        updateConflictHighlights()
        guard !conflicts.isEmpty else {
            suspendConflictControls()
            if conflictPanel != nil {
                conflictPanel = nil
                updateDocumentHeader()
            }
            return
        }

        if conflictPanel == nil {
            let panel = JJConflictPanel()
            conflictPanel = panel
            panel.onNavigate = { [weak self] offset in self?.revealConflict(offsetBy: offset) }
            editor.jjConflictDecorations?.onAction = { [weak self] block, action in
                self?.performConflictAction(action, in: block)
            }
            panel.onChangeStyle = { [weak self] style in self?.changeConflictStyle(to: style) }
            panel.onShowPendingChanges = { [weak self] enabled in
                guard let self else { return }
                showsPendingConflictChanges = enabled
                updateConflictHighlights()
            }
        }
        updateConflictControls()
        updateDocumentHeader()
        updateConflictActions()
    }

    private func installNewConflictProjections(_ confirmed: [JJConflict]) {
        guard !confirmed.isEmpty, !editor.hasMarkedText() else { return }
        let existing = editor.conflictEdits
        let projection = JJConflictEdit.projection(for: existing)
        let source = editor.string as NSString
        var removals: [EditorTextEdit] = []
        var additions: [JJConflictEdit] = []
        for block in confirmed {
            let range = projection.visibleRange(block.range)
            guard !existing.contains(where: { NSIntersectionRange($0.block, range).length > 0 }),
                  range.length == block.range.length, NSMaxRange(range) <= source.length,
                  source.substring(with: range).utf8.elementsEqual(block.source.utf8) else { continue }
            let rows = block.highlights.filter { $0.role != .marker }
            // Edits in an existing undo stack use the old buffer's coordinates. The normal
            // opening and reload paths prepare their projection before an undo stack is installed.
            guard rows.isEmpty || (editor.editorUndoManager.undoCount == 0 && editor.editorUndoManager.redoCount == 0) else { continue }
            additions.append(JJConflictEdit(block).relocated(to: range.location - removals.count))
            removals += rows.map {
                EditorTextEdit(range: NSRange(location: projection.visibleOffset($0.range.location), length: 1), text: "")
            }
        }
        guard !additions.isEmpty else { return }
        let tracked = (existing.compactMap { $0.remapped(after: removals) } + additions).sorted { $0.block.location < $1.block.location }
        if removals.isEmpty { editor.conflictEdits = tracked }
        else { preserveEditorViewport { editor.installConflictProjection(removals, tracked: tracked) } }
    }

    private func setConflictAnalysisMarks(_ analysis: JJTextAnalysis?, normalizeCRLF: Bool = false) {
        guard let analysis else {
            editor.setJJLineMarks([])
            return
        }
        let tracked = editor.conflictEdits
        guard !tracked.isEmpty else {
            editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts, hunks: analysis.hunks, normalizeCRLF: normalizeCRLF)
            return
        }
        let projection = JJConflictEdit.projection(for: tracked)
        let hunks = analysis.hunks.compactMap { hunk -> JJDiffHunk? in
            let range = projection.visibleRange(hunk.currentRange)
            guard range.length == hunk.currentRange.length else { return nil }
            let touchesConflict = tracked.contains { edit in
                range.length == 0 ? NSLocationInRange(range.location, edit.block) : NSIntersectionRange(edit.block, range).length > 0
            }
            guard !touchesConflict else { return nil }
            return JJDiffHunk(mark: hunk.mark, baseRange: hunk.baseRange, currentRange: range,
                              removedText: hunk.removedText, insertedText: hunk.insertedText,
                              removedHighlights: hunk.removedHighlights, insertedHighlights: hunk.insertedHighlights)
        }
        editor.setJJLineMarks(analysis.marks, lineStarts: analysis.lineStarts.map(projection.visibleOffset),
                              hunks: hunks, normalizeCRLF: normalizeCRLF)
    }

    private var selectedConflictIndex: Int? {
        guard !conflictBlocks.isEmpty else { return nil }
        let caret = editor.selectedRange().location
        return conflictBlocks.firstIndex { NSMaxRange($0.range) > caret } ?? conflictBlocks.count - 1
    }

    private var hasAppliedConflictDiff: Bool { editor.conflictEdits.contains { !$0.appliedSides.isEmpty } }

    private var hasInlineConflictResult: Bool {
        hasAppliedConflictDiff || conflictBlocks.contains(where: \.hasEditedResult)
    }

    private func updateConflictControls() {
        guard conflictPresentationCurrent, let index = selectedConflictIndex else { return }
        conflictPanel?.update(conflictBlocks, selected: index, hasDraft: hasInlineConflictResult,
                              pendingChanges: showsPendingConflictChanges && canShowPendingConflictChanges,
                              canShowPending: canShowPendingConflictChanges)
    }

    private var canShowPendingConflictChanges: Bool {
        sourceControlRevision == nil && conflictBlocks.contains { $0.style == .diff && $0.resultRange != nil }
    }

    private func updateConflictHighlights() {
        let showPending = showsPendingConflictChanges && canShowPendingConflictChanges
        let tracked = showPending ? Dictionary(uniqueKeysWithValues: editor.conflictEdits.map { ($0.block, $0) }) : [:]
        let inputs: [JJConflictPendingChanges.Input] = conflictBlocks.compactMap { conflict in
            guard conflict.style == .diff, let edit = tracked[conflict.range] else { return nil }
            return .init(id: edit.id, original: edit.original, result: conflict.startingResult)
        }
        pendingConflictChanges.update(inputs) { [weak self] in self?.renderConflictHighlights() }
        renderConflictHighlights()
    }

    private func renderConflictHighlights() {
        let showPending = showsPendingConflictChanges && canShowPendingConflictChanges
        let ids = showPending ? Dictionary(uniqueKeysWithValues: editor.conflictEdits.map { ($0.block, $0.id) }) : [:]
        editor.setJJConflictHighlights(conflictBlocks.flatMap { conflict in
            guard conflict.style == .diff, let id = ids[conflict.range] else {
                return conflict.highlights.filter { $0.role != .context }
            }
            return conflict.highlightingPendingChanges(confirmed: pendingConflictChanges.confirmedRows(for: id))
        })
    }

    private var inlineConflictDrafts: [JJConflictEdit.SavedDraft] {
        JJConflictEdit.drafts(in: editor.string, edits: editor.conflictEdits)
    }

    var textForSaving: String { JJConflictEdit.textForSaving(editor.sourceString, edits: editor.conflictEdits) }
    var textWithConflictPrefixes: String { JJConflictEdit.textWithDrafts(editor.sourceString, edits: editor.conflictEdits) }

    private func updateConflictActions() {
        let tracked = Dictionary(uniqueKeysWithValues: editor.conflictEdits.map { ($0.block, $0) })
        editor.jjConflictDecorations?.setActionBlocks(editor.isEditable ? conflictBlocks.compactMap { conflict in
            guard let edit = tracked[conflict.range] else { return nil }
            return .init(conflict: conflict, id: edit.id, appliedSides: edit.appliedSides,
                         failedSides: failedConflictDiffs[edit.id] ?? [],
                         hasDraft: conflict.hasEditedResult || !edit.appliedSides.isEmpty)
        } : [])
        editor.jjConflictDecorations?.setActionsEnabled(true)
    }

    private func suspendConflictControls(keepingPresentation: Bool = false) {
        conflictApplyTask?.cancel()
        conflictApplyTask = nil
        conflictPresentationCurrent = false
        conflictPanel?.suspend()
        if keepingPresentation { editor.jjConflictDecorations?.setActionsEnabled(false) }
        else { editor.jjConflictDecorations?.setActionBlocks([]) }
    }

    private func revealConflict(offsetBy offset: Int) {
        guard conflictPresentationCurrent, let index = selectedConflictIndex else { return }
        let count = conflictBlocks.count
        let block = conflictBlocks[(index + offset + count) % count]
        let target = NSRange(location: block.range.location, length: 0)
        editor.setCaretSelections([target])
        focusContent()
        editor.scrollRangeToVisible(target)
        markdownPreview?.restore(.init(sourceOffset: target.location))
    }

    private func canResolve(_ conflict: JJConflict) -> Bool {
        conflictPresentationCurrent && editor.isEditable && !editor.hasMarkedText() &&
            conflictBlocks.contains(conflict) && Self.conflictMatches(conflict, in: editor.string as NSString)
    }

    private func performConflictAction(_ action: JJConflictActions.Action, in conflict: JJConflict) {
        guard canResolve(conflict), conflictApplyTask == nil,
              let tracked = editor.conflictEdits.first(where: { $0.block == conflict.range }) else { return }
        switch action {
        case .markResolved:
            resolveConflict(conflict, with: conflict.startingResult)
        case let .applyDiff(side):
            guard !tracked.appliedSides.contains(side),
                  let segment = conflict.segments.first(where: { $0.kind.diffSide == side }) else { return }
            let text = conflict.startingResult
            let id = tracked.id
            conflictApplyTask = Task { [weak self] in
                let result = await Self.replayConflictDiff(segment, in: conflict, onto: text)
                guard let self, !Task.isCancelled else { return }
                conflictApplyTask = nil
                guard canResolve(conflict), let current = editor.conflictEdits.first(where: { $0.id == id }),
                      !current.appliedSides.contains(side) else { return }
                if let result {
                    let replacement = result.utf8.elementsEqual(text.utf8) ? nil : conflict.displayedResult(result)
                    preserveEditorViewport { applyConflictResult(replacement, for: current, side: side) }
                    focusContent()
                } else {
                    failedConflictDiffs[id, default: []].insert(side)
                    if let range = current.result, let line = editor.laidOutLineBounds(at: range.location) {
                        let viewport = JJEditorActionBar.viewport(in: scrollView)
                        let anchor = scrollView.convert(line, from: editor)
                        if anchor.midY >= viewport.minY, anchor.midY <= viewport.maxY {
                            preserveEditorViewport {
                                editor.setCaretSelections([NSRange(location: range.location, length: 0)])
                                focusContent()
                            }
                        }
                    }
                    updateConflictActions()
                }
            }
        }
    }

    private func applyConflictResult(_ replacement: String?, for current: JJConflictEdit, side: Int) {
        guard let result = current.result else { return }
        let edits = replacement.map {
            [EditorTextEdit(range: result, text: current.hasSeparator ? $0 : $0 + current.original.lineEnding)]
        } ?? []
        let tracked = editor.conflictEdits.compactMap { item -> JJConflictEdit? in
            guard item.id == current.id else { return item.remapped(after: edits) }
            var updated: JJConflictEdit
            if let replacement, !item.hasSeparator {
                updated = item.withInitialResult(length: replacement.utf16.count)
            } else if let mapped = item.remapped(after: edits) {
                updated = mapped
            } else { return nil }
            updated.appliedSides.insert(side)
            return updated
        }
        let selections = MultiCaretEditing.mapped(editor.caretSelections, after: edits)
        editor.applyMultiEdits(edits, selections: selections, actionName: "Apply Diff", conflictEditsAfter: tracked)
    }

    private func resolveConflict(_ conflict: JJConflict, with text: String) {
        guard canResolve(conflict) else { return }
        let edit = EditorTextEdit(range: conflict.range, text: text)
        let caret = NSRange(location: conflict.range.location, length: 0)
        let remaining = editor.conflictEdits.filter { $0.block != conflict.range }.compactMap { $0.remapped(after: [edit]) }
        if editor.applyMultiEdits([edit], selections: [caret], actionName: "Resolve Conflict", conflictEditsAfter: remaining) {
            focusContent()
        }
    }

    @concurrent
    private static func replayConflictDiff(_ segment: JJConflict.Segment, in conflict: JJConflict, onto text: String) async -> String? {
        conflict.applyingDiff(for: segment, onto: text)
    }

    private func changeConflictStyle(to style: JJConflict.Style) {
        guard conflictPresentationCurrent, !hasInlineConflictResult, !editor.hasMarkedText(),
              editor.isEditable || sourceControlRevision != nil else { return }
        let original = editor.string
        guard conflictBlocks.allSatisfy({ Self.conflictMatches($0, in: original as NSString) }) else { return }
        let tracked = editor.conflictEdits
        let raw = textWithConflictPrefixes
        let preview = sourceControlRevision
        let baseline: String?
        if let preview, case .text(_, _, _, let text) = preview.content { baseline = text }
        else { baseline = nil }
        conflictStyleTask?.cancel()
        suspendConflictControls(keepingPresentation: true)
        conflictStyleTask = Task { [weak self] in
            let conversion = await Self.convertConflictStyle(tracked, in: raw, to: style, baseline: baseline)
            guard let self, !Task.isCancelled, editor.string.utf8.elementsEqual(original.utf8) else { return }
            conflictStyleTask = nil
            guard let conversion else {
                conflictPresentationCurrent = true
                updateConflictControls()
                updateConflictActions()
                return
            }
            let (edits, rawText, projected, analysis) = conversion
            if preview != nil {
                let position = editor.capturePosition()
                PanelLayout.withoutAnimation {
                    savedText = rawText as NSString
                    installText(projected.text, restoredConflicts: projected.edits, revealInWorktree: false,
                                preservingConflictPresentation: true)
                    setConflictAnalysisMarks(analysis)
                    editor.jjInlineDiff?.expandAll()
                    editor.restorePosition(position)
                }
            } else {
                let mapped = MultiCaretEditing.mapped(editor.caretSelections, after: edits)
                if editor.applyMultiEdits(edits, selections: mapped, actionName: "Change Conflict Format", conflictEditsAfter: projected.edits) {
                    showEditorConflicts([])
                    focusContent()
                } else {
                    conflictPresentationCurrent = true
                    updateConflictControls()
                    updateConflictActions()
                }
            }
        }
    }

    private static func conflictMatches(_ conflict: JJConflict, in buffer: NSString) -> Bool {
        NSMaxRange(conflict.range) <= buffer.length &&
            buffer.substring(with: conflict.range).utf8.elementsEqual(conflict.source.utf8)
    }

    @concurrent
    private static func convertConflictStyle(
        _ blocks: [JJConflictEdit], in original: String, to style: JJConflict.Style, baseline: String?
    ) async -> (edits: [EditorTextEdit], materialized: String, projected: (text: String, edits: [JJConflictEdit]), analysis: JJTextAnalysis)? {
        guard blocks.contains(where: { $0.original.style != style }) else { return nil }
        let projection = JJConflictEdit.projection(for: blocks)
        var rawEdits: [EditorTextEdit] = []
        var converted: [JJConflict] = []
        var delta = 0
        for block in blocks {
            let rawRange = NSRange(location: projection.rawOffset(block.block.location), length: block.original.range.length)
            guard !Task.isCancelled, let text = block.original.rendered(as: style),
                  let conflict = JJLineDiff.parseConflict(text, at: rawRange.location + delta) else { return nil }
            converted.append(conflict)
            if block.original.style != style {
                rawEdits.append(EditorTextEdit(range: rawRange, text: text))
                delta += text.utf16.count - rawRange.length
            }
        }
        let updated = NSMutableString(string: original)
        for edit in rawEdits.reversed() { updated.replaceCharacters(in: edit.range, with: edit.text) }
        let text = updated as String
        let projected = JJConflictEdit.project(converted, in: text)
        guard projected.edits.count == blocks.count else { return nil }
        let edits = zip(blocks, projected.edits).compactMap { old, new -> EditorTextEdit? in
            guard old.original.style != style else { return nil }
            return EditorTextEdit(range: old.block, text: new.projected.source)
        }
        let analysis = JJLineDiff.analyze(base: baseline, current: text, isConflicted: true, recordedConflict: text)
        return (edits, text, projected, analysis)
    }

    private func updateEditedState() {
        let matchesSaved = savedText.map { saved in
            if editor.conflictEdits.isEmpty && editor.renameRange == nil {
                return editor.textStorage?.mutableString.isEqual(saved) ?? false
            }
            return saved.isEqual(to: textWithConflictPrefixes)
        } ?? false
        let isEdited = hasAppliedConflictDiff || !matchesSaved
        if isEdited != window.isDocumentEdited {
            window.isDocumentEdited = isEdited
            if !isEdited {
                fileRefresh.resume()
                scheduleSourceControlFileTransition()
            }
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

extension DocumentWindow {
    var isShowingMarkdownPreview: Bool { markdownPreview != nil }
    var markdownPositionForClose: EditorPosition? {
        hasTextDocument && resolvedSyntaxLanguage == .markdown ? captureFileEditorPosition() : nil
    }

    var markdownRevisionRecord: MarkdownRevisionRecord? {
        guard sourceControlRevision != nil, resolvedSyntaxLanguage == .markdown, let file = sourceControlFile else { return nil }
        return MarkdownRevisionRecord(root: file.workspace.root, path: file.file.path, commit: file.revision.id,
                                      operation: file.operationID)
    }

    func restoreMarkdownRevision(_ loaded: MarkdownRevisionRecord.Loaded, syntax: String? = nil) {
        clearSourceControlFile()
        loadSourceControlRevision(loaded.preview, workspace: loaded.workspace, operationID: loaded.operation)
        observeSourceControlFile(SourceControlFile(file: loaded.file, revision: loaded.revision,
                                                  workspace: loaded.workspace, operationID: loaded.operation))
        if let syntax, let language = SyntaxLanguage(rawValue: syntax) { setSyntaxLanguage(language) }
        focusContent()
    }

    var canToggleMarkdownPreview: Bool {
        hasTextDocument && resolvedSyntaxLanguage == .markdown && canReplaceBuffer && !editor.hasMarkedText()
    }

    func toggleMarkdownPreview() {
        guard canToggleMarkdownPreview else { return }
        setMarkdownPreview(!isShowingMarkdownPreview, focus: true)
    }

    func handleMarkdownEscape() -> Bool {
        guard let markdownPreview, window.attachedSheet == nil, markdownPreview.containsResponder(window.firstResponder) else { return false }
        if !markdownPreview.dismissFind() { setMarkdownPreview(false, focus: true) }
        return true
    }

    func handleMarkdownUndo(redo: Bool) -> Bool {
        guard let preview = markdownPreview, window.attachedSheet == nil, preview.containsResponder(window.firstResponder),
              !preview.isFinding, markdownTasksAreWritable, let manager = editor.undoManager else { return false }
        if redo { manager.redo() } else { manager.undo() }
        return true
    }

    func restoreMarkdownState(_ state: MarkdownViewState) {
        guard hasTextDocument, resolvedSyntaxLanguage == .markdown else { return }
        let focus = contentHasFocus
        markdownState = state
        setMarkdownPreview(state.showsPreview, focus: focus)
        if let reading = state.reading { markdownPreview?.restore(reading) }
    }

    func setMarkdownPreview(_ enabled: Bool, focus: Bool) {
        markdownState.showsPreview = enabled
        if enabled, markdownPreview == nil {
            editor.setMarkdownToolTipLinks([])
            if markdownState.reading == nil {
                markdownState.reading = .init(sourceOffset: captureFileEditorPosition().topLine?.textOffset ?? 0)
            }
            let view = MarkdownPreviewView()
            markdownPreview = view
            connectMarkdownPreview(view)
            pinToEditorContent(view)
            scrollView.isHidden = true
            refreshMarkdown(immediate: true)
        } else if !enabled, let view = markdownPreview {
            markdownPreview = nil
            view.removeFromSuperview()
            scrollView.isHidden = isShowingFilePreview || showsEmptyFolder
            editor.setMarkdownToolTipLinks(markdownPage?.source == editor.string ? markdownPage?.document.links ?? [] : [])
        }
        titleBar.updateCaretPosition()
        window.initialFirstResponder = contentResponder
        sidebar.markdownModeChanged()
        if focus { focusContent() }
    }

    private func connectMarkdownPreview(_ view: MarkdownPreviewView) {
        view.onState = { [weak self, weak view] reading in
            guard let self, let view, markdownPreview === view else { return }
            markdownState.reading = reading
        }
        view.onTask = { [weak self, weak view] offset, checked in
            guard let self, let view, markdownPreview === view else { return }
            toggleMarkdownTask(at: offset, checked: checked)
        }
        view.onLink = { [weak self, weak view] target in
            Task {
                guard let self, let view, self.markdownPreview === view else { return }
                await self.followMarkdown(target, from: nil)
            }
        }
        view.onImage = { [weak self, weak view] index, activate in
            Task {
                guard let self, let view, self.markdownPreview === view else { return }
                await self.loadMarkdownImage(index, activate: activate)
            }
        }
        view.onFragment = { [weak self, weak view] fragment, found in
            guard let self, let view, markdownPreview === view else { return }
            finishMarkdownFragment(fragment, found: found)
        }
    }

    private func finishMarkdownFragment(_ fragment: String, found: Bool) {
        if found { recordMarkdownAnchorJump(fragment) }
        else {
            app.recordNavigation(in: self, reason: .jump)
            Task { await showError("Heading or Anchor Not Found", detail: fragment) }
        }
    }

    private func prepareMarkdownOpening(
        _ source: String, position: EditorPosition?, fragment: String?, writable: Bool,
        while isCurrent: () -> Bool
    ) async -> PreparedMarkdownOpening? {
        do {
            let document = try await MarkdownDocumentRenderer.shared.render(source, includeHTML: true)
            let highlighted = await Task.detached(priority: .userInitiated) { document.code.map { $0.highlighted() } }.value
            guard isCurrent(), !Task.isCancelled else { return nil }
            var state = position?.markdown ?? MarkdownViewState()
            state.showsPreview = true
            let reading = state.reading ?? .init(sourceOffset: position?.topLine?.textOffset ?? 0)
            let view = MarkdownPreviewView()
            var keepView = false
            defer { if !keepView { view.removeFromSuperview() } }
            let visible = (markdownPreview as NSView?) ?? (filePreviewView as NSView?) ?? (emptyFolderView as NSView?) ?? scrollView
            view.additionalSafeAreaInsets.bottom = terminalDockView?.coveredHeight ?? 0
            pinToEditorContent(view, below: visible)
            window.layoutIfNeeded()
            view.show(html: document.html, highlighted: highlighted, reading: reading, writable: writable,
                      fragment: fragment, staged: true)
            try await view.waitForPreparedFrame(while: isCurrent)
            #if EDIT_AGENT_CHECKS
            await beforePresentMarkdownForCheck?(view)
            #endif
            guard isCurrent(), !Task.isCancelled else { return nil }
            state.reading = view.presentedReading ?? reading
            keepView = true
            return PreparedMarkdownOpening(view: view, source: source, document: document, state: state)
        } catch is CancellationError {
            return nil
        } catch {
            if isCurrent(), !Task.isCancelled { await showError("Could Not Prepare Markdown Preview", detail: error.localizedDescription) }
            return nil
        }
    }

    private func presentMarkdownOpening(_ prepared: PreparedMarkdownOpening) {
        let previous = markdownPreview
        markdownRender?.cancel()
        markdownRender = nil
        markdownState = prepared.state
        markdownPage = (prepared.source, prepared.document)
        markdownPreview = prepared.view
        titleBar.updateCaretPosition()
        connectMarkdownPreview(prepared.view)
        scrollView.isHidden = true
        previous?.removeFromSuperview()
        window.initialFirstResponder = contentResponder
        sidebar.markdownModeChanged()
        prepared.view.activatePreparedFrame()
    }

    private func finishOpeningPresentation(_ prepared: PreparedMarkdownOpening?, position: EditorPosition?,
                                           focus: Bool, markdownLink: MarkdownLinkOpening?) {
        if let prepared {
            restoreEditorPosition(position, restoringMarkdown: false)
            presentMarkdownOpening(prepared)
            if focus { focusContent() }
        } else {
            if focus { focusContent() }
            restoreEditorPosition(position, showingMarkdownPreview: markdownLink?.showsPreview)
        }
        sidebar.searchDocumentPresented()
    }

    private func resetMarkdownView(keepingPresentation: Bool = false) {
        rememberMarkdownRevisionPosition()
        if !keepingPresentation { setMarkdownPreview(false, focus: false) }
        markdownRender?.cancel()
        markdownRender = nil
        markdownPage = nil
        editor.setMarkdownToolTipLinks([])
        markdownNoteOrigins.removeAll()
        markdownState = MarkdownViewState()
        pendingMarkdownFragment = nil
    }

    private func rememberMarkdownRevisionPosition() {
        if sourceControlRevision != nil, let file = sourceControlFile {
            markdownRevisions[markdownRevisionKey(file)] = (file, captureFileEditorPosition())
        }
    }

    private func refreshMarkdown(immediate: Bool) {
        markdownRender?.cancel()
        guard hasTextDocument, resolvedSyntaxLanguage == .markdown else {
            setMarkdownPreview(false, focus: isShowingMarkdownPreview && contentHasFocus)
            markdownPage = nil
            editor.setMarkdownToolTipLinks([])
            return
        }
        let source = editor.string
        if source != markdownPage?.source { editor.setMarkdownToolTipLinks([]) }
        let includesPreview = isShowingMarkdownPreview
        markdownRender = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(60)) }
                let loaded = try await MarkdownDocumentRenderer.shared.render(source, includeHTML: includesPreview)
                let highlights = includesPreview ? await Task.detached(priority: .userInitiated) {
                    loaded.code.map { $0.highlighted() }
                }.value : []
                guard let self, !Task.isCancelled, editor.string == source, resolvedSyntaxLanguage == .markdown else { return }
                markdownPage = (source, loaded)
                if let preview = markdownPreview, includesPreview {
                    preview.show(html: loaded.html, highlighted: highlights,
                                 reading: markdownState.reading ?? .init(sourceOffset: 0),
                                 writable: markdownTasksAreWritable, fragment: pendingMarkdownFragment)
                    pendingMarkdownFragment = nil
                } else if markdownPreview == nil {
                    editor.setMarkdownToolTipLinks(loaded.links)
                }
            } catch {
                guard let self, !Task.isCancelled, let preview = markdownPreview else { return }
                preview.show(html: "<p>Could not render this Markdown document.</p>", highlighted: [],
                             reading: .init(sourceOffset: 0), writable: false, fragment: nil)
            }
        }
    }

    private var markdownTasksAreWritable: Bool {
        guard hasEditableTextDocument else { return false }
        return fileURL.map { FileManager.default.isWritableFile(atPath: $0.path) || revision == .missing } ?? true
    }

    private func toggleMarkdownTask(at offset: Int, checked: Bool) {
        guard markdownPreview != nil, markdownTasksAreWritable, canReplaceBuffer, !editor.hasMarkedText(),
              let markdownPage, markdownPage.source == editor.string else { return }
        let text = markdownPage.source as NSString
        guard offset > 0, offset + 1 < text.length, text.character(at: offset - 1) == 91,
              text.character(at: offset + 1) == 93, [32, 88, 120].contains(text.character(at: offset)) else { return }
        let edit = EditorTextEdit(range: NSRange(location: offset, length: 1), text: checked ? "x" : " ")
        if !editor.applyMultiEdits([edit], selections: editor.caretSelections, actionName: "Toggle Markdown Task") {
            refreshMarkdown(immediate: true)
        }
    }

    private func markdownLink(at offset: Int, activate: Bool) -> Bool {
        guard resolvedSyntaxLanguage == .markdown, markdownPreview == nil,
              let markdownPage, markdownPage.source == editor.string,
              let link = markdownPage.document.links.first(where: { $0.start <= offset && offset < $0.end }) else { return false }
        if activate {
            let origin = navigationLocation(at: NSRange(location: offset, length: 0))
            if let target = link.target {
                Task { await followMarkdown(target, from: origin) }
            } else if let note = link.note {
                if let destination = link.destination {
                    markdownNoteOrigins[note] = link.start
                    navigate(to: NSRange(location: destination, length: 0), from: origin)
                } else if let reference = markdownNoteOrigins[note] ?? link.references?.first {
                    navigate(to: NSRange(location: reference, length: 0), from: origin)
                }
            }
        }
        return true
    }

    private var markdownFileURL: URL? { sourceControlRevision?.url ?? (scratchFile == nil ? fileURL : nil) }

    private func markdownTarget(_ path: String) async -> URL? {
        if let url = URL(string: path), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" {
            return url.standardizedFileURL
        }
        guard let decoded = path.removingPercentEncoding else { return nil }
        let directory = markdownFileURL?.deletingLastPathComponent() ?? folderURL
        if decoded.hasPrefix("/") {
            let start = directory
            let historyRoot = sourceControlRevision == nil ? nil : sourceControlFile?.workspace.root
            let root = await Task.detached { () -> URL? in
                if let historyRoot { return historyRoot }
                guard var candidate = start else { return nil }
                while true {
                    if [".git", ".jj"].contains(where: {
                        FileManager.default.fileExists(atPath: candidate.appending(path: $0).path)
                    }) { return candidate }
                    let parent = candidate.deletingLastPathComponent()
                    if parent.path == candidate.path || candidate.path == "/" { return nil }
                    candidate = parent
                }
            }.value
            return (root ?? folderURL ?? directory)?.appending(path: String(decoded.dropFirst())).standardizedFileURL
        }
        return directory?.appending(path: decoded).standardizedFileURL
    }

    private func followMarkdown(_ target: String, from sourceOrigin: NavigationHistory.Location?) async {
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            if !app.isAgentCheck { NSWorkspace.shared.open(url) }
            return
        }
        let origin = sourceOrigin ?? navigationLocation
        let originatingPreview = markdownPreview
        let opensPreview = originatingPreview != nil
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = parts.first.map(String.init) else { return }
        let fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        if path.isEmpty {
            if let fragment { await revealMarkdownFragment(fragment, from: origin) }
            return
        }
        if let scheme = URL(string: path)?.scheme, scheme.lowercased() != "file" { return }
        let opening = MarkdownLinkOpening(showsPreview: opensPreview, fragment: fragment)
        let initialGeneration = openRequestGeneration
        guard let targetURL = await markdownTarget(path), initialGeneration == openRequestGeneration else {
            if initialGeneration == openRequestGeneration { await showError("Could Not Open Link", detail: path) }
            return
        }
        do {
            if let history = sourceControlRevision != nil ? sourceControlFile : nil {
                guard let path = Self.worktreePathSuffix(from: history.workspace.root, to: targetURL), !path.isEmpty else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                if path == history.file.path {
                    if let fragment { await revealMarkdownFragment(fragment, from: origin) }
                    return
                }
                let file = try await JJSourceControlRepository.linkedFile(path, in: history.revision, workspace: history.workspace,
                                                                         at: history.operationID)
                guard initialGeneration == openRequestGeneration,
                      await openSourceControlFile(file, in: history.revision, workspace: history.workspace,
                                                  operationID: history.operationID, markdownLink: opening, while: { true }) else { return }
            } else {
                let canonical = await Task.detached { FileBuffer.canonicalURL(targetURL) }.value
                guard initialGeneration == openRequestGeneration else { return }
                guard FileManager.default.isReadableFile(atPath: canonical.path) else { throw CocoaError(.fileReadNoSuchFile) }
                guard try await app.openFile(canonical, in: self, focusEditor: false, markdownLink: opening) != nil else { return }
            }
            guard openRequestGeneration == initialGeneration &+ 1 else { return }
            if let origin { app.recordNavigation(origin, in: self, reason: .selection) }
            if resolvedSyntaxLanguage == .markdown && hasTextDocument {
                focusContent()
                if let fragment {
                    if markdownPreview !== originatingPreview, let presented = markdownPreview?.presentedFragment,
                       presented.target == fragment {
                        finishMarkdownFragment(fragment, found: presented.found)
                    } else {
                        await revealMarkdownFragment(fragment, from: nil)
                    }
                } else {
                    app.recordNavigation(in: self, reason: .jump)
                }
            } else {
                focusContent()
                app.recordNavigation(in: self, reason: .jump)
            }
        } catch {
            await showError("Could Not Open Link", detail: targetURL.path)
        }
    }

    private func revealMarkdownFragment(_ fragment: String, from origin: NavigationHistory.Location?) async {
        if let preview = markdownPreview {
            if !preview.hasCurrentDocument || markdownPage?.source != editor.string {
                pendingMarkdownFragment = fragment
                refreshMarkdown(immediate: true)
                return
            }
            if await preview.jump(to: fragment) {
                if let origin { app.recordNavigation(origin, in: self, reason: .selection) }
                recordMarkdownAnchorJump(fragment)
                return
            }
        } else {
            let source = editor.string
            let page: MarkdownDocument?
            if markdownPage?.source == source { page = markdownPage?.document }
            else { page = try? await MarkdownDocumentRenderer.shared.render(source, includeHTML: false) }
            guard source == editor.string else { return }
            if let offset = page?.anchors[fragment] {
                navigate(to: NSRange(location: offset, length: 0), from: origin)
                return
            }
        }
        await showError("Heading or Anchor Not Found", detail: fragment)
    }

    private func recordMarkdownAnchorJump(_ fragment: String) {
        let range = markdownPage?.document.anchors[fragment].map { NSRange(location: $0, length: 0) }
        if let location = navigationLocation(at: range) { app.recordNavigation(location, in: self, reason: .jump) }
    }

    private func loadMarkdownImage(_ index: Int, activate: Bool) async {
        guard let preview = markdownPreview, let page = markdownPage, page.document.images.indices.contains(index) else { return }
        let value = page.document.images[index]
        var data: Data?
        var type: String?
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            let key = "markdown-approved-image-urls"
            var approved = Set(app.isAgentCheck ? [] : UserDefaults.standard.stringArray(forKey: key) ?? [])
            guard activate || approved.contains(url.absoluteString) else {
                preview.showImage(index, url: nil, remote: true)
                return
            }
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            if let (bytes, response) = try? await session.data(from: url), response.mimeType?.hasPrefix("image/") == true {
                data = bytes
                type = response.mimeType
                if activate && !app.isAgentCheck {
                    approved.insert(url.absoluteString)
                    UserDefaults.standard.set(approved.sorted(), forKey: key)
                }
            }
        } else if let url = await markdownTarget(value), let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                  mime.hasPrefix("image/") {
            type = mime
            if let history = sourceControlRevision != nil ? sourceControlFile : nil {
                if let path = Self.worktreePathSuffix(from: history.workspace.root, to: url),
                   let file = try? await JJSourceControlRepository.linkedFile(path, in: history.revision, workspace: history.workspace,
                                                                             at: history.operationID) {
                    data = try? await JJSourceControlRepository.file(file, in: history.revision, workspace: history.workspace,
                                                                    at: history.operationID).recorded
                }
            } else {
                data = await Task.detached { try? Data(contentsOf: url) }.value
            }
        }
        guard markdownPreview === preview, markdownPage?.source == page.source, let data, let type else { return }
        preview.showImage(index, url: "data:\(type);base64,\(data.base64EncodedString())", remote: false)
    }

    private func markdownRevisionKey(_ file: SourceControlFile) -> String {
        "\(file.workspace.root.path)\u{1f}\(file.revision.id)\u{1f}\(file.file.path)"
    }

    func reopenMarkdownRevision(_ key: String, while wanted: @escaping () -> Bool) async -> Bool {
        guard let (file, _) = markdownRevisions[key] else { return false }
        return await openSourceControlFile(file.file, in: file.revision, workspace: file.workspace, operationID: file.operationID, while: wanted)
    }

    #if EDIT_AGENT_CHECKS
    var markdownPreviewForCheck: MarkdownPreviewView? { markdownPreview }
    func followMarkdownForCheck(_ target: String) async { await followMarkdown(target, from: nil) }
    #endif
}
