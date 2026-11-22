import AppKit

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
    enum CloseChoice {
        case save(to: URL?)
        case discard
        case cancel
    }

    enum CloseDestination {
        case window
        case buffer(FileBuffer?, focusEditor: Bool = true)
        case preview(OpenFilePreview, focusEditor: Bool)
    }

    private struct AutosaveRequest {
        let generation: UInt
        let text: String
    }

    let window: NSWindow
    let editor: EditorTextView
    let scrollView: NSScrollView
    let editorContentView: NSView
    private(set) lazy var titleBar = DocumentTitleBar(document: self, app: app)

    private unowned let app: Edit
    private(set) var fileURL: URL? {
        didSet {
            if oldValue != fileURL { detectedSyntaxLanguage = SyntaxLanguage.detected(at: fileURL) }
        }
    }
    private(set) var folderURL: URL?
    private var filePreview: OpenFilePreview?
    private var filePreviewView: FilePreviewView?
    var openRequestGeneration: UInt64 = 0
    var isShowingFilePreview: Bool { filePreview != nil }
    var displayedFileURL: URL? { filePreview?.url ?? fileURL }
    var displayName: String { displayedFileURL?.lastPathComponent ?? "Untitled" }
    var contentResponder: NSView { (filePreviewView as NSView?) ?? editor }

    func focusContent() {
        window.makeFirstResponder(contentResponder)
    }

    func setFolder(_ url: URL?) {
        guard folderURL != url else { return }
        folderURL = url
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
    var findSettings = FindSettings()
    var sidebarMode: SidebarMode = .search
    var worktreeShowsHidden = false
    var worktreeSidebar: WorktreeSidebar? { findPanel?.worktree }
    private var appearanceObservation: NSKeyValueObservation?
    private(set) var manualSyntaxLanguage: SyntaxLanguage?

    var resolvedSyntaxLanguage: SyntaxLanguage {
        manualSyntaxLanguage ?? detectedSyntaxLanguage
    }

    func setSyntaxLanguage(_ language: SyntaxLanguage?) {
        guard !isShowingFilePreview, manualSyntaxLanguage != language else { return }
        manualSyntaxLanguage = language
        app.syntaxOverrides.set(language, for: fileURL)
        updateTitle()
        refreshSyntax(immediate: true)
    }

    var isBusy: Bool { saving || promptingToClose || worktreeMutation }
    var canReplaceBuffer: Bool { !isBusy && window.attachedSheet == nil }
    var isReusable: Bool {
        folderURL == nil && displayedFileURL == nil && findPanel == nil && !window.isDocumentEdited && canReplaceBuffer
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
        let toolbar = NSToolbar(identifier: "Edit.Document")
        toolbar.delegate = titleBar
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        window.initialFirstResponder = editor
        window.makeFirstResponder(editor)
        editor.onTextChange = { [weak self] in self?.textDidChange() }
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

    func canPerformFind(_ command: FindCommand) -> Bool {
        guard window.attachedSheet == nil else { return false }
        if isShowingFilePreview { return command == .toggleSidebar }
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
        guard !app.isQuitting, window.attachedSheet == nil, mode != .worktree || folderURL != nil else { return }
        searchPanel().toggleFocus(of: mode)
    }

    func restoreFindSettings(_ settings: FindSettings) {
        findSettings = settings
        if settings.visible {
            searchPanel().restoreVisibility()
        }
    }

    func restoreSidebar(_ record: SessionDocument) {
        sidebarMode = folderURL == nil ? .search : record.sidebarMode ?? .search
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

    func windowDidEnterFullScreen(_ notification: Notification) {
        pendingFullScreen = false
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        pendingFullScreen = false
        app.didFinishFullScreenRestore(for: self)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        normalFrame = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        requestAutosave()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        requestAutosave()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reportAutosaveFailure()
    }

    func windowDidEndSheet(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.reportAutosaveFailure() }
    }

    func load(_ file: FileBuffer, storedSyntaxLanguage: String? = nil, preparedSyntax: SyntaxSnapshot? = nil) {
        removeFilePreview()
        updateIdentity(from: file)
        manualSyntaxLanguage = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: fileURL)
        installText(file.text, preparedSyntax: preparedSyntax)
    }

    func prepareOpeningSyntax(
        _ file: FileBuffer, position: EditorPosition?, storedSyntaxLanguage: String? = nil
    ) async -> SyntaxSnapshot? {
        let language = storedSyntaxLanguage.flatMap(SyntaxLanguage.init(rawValue:))
            ?? app.syntaxOverrides.language(for: file.url) ?? SyntaxLanguage.detected(at: file.url)
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

    private func pinToEditorContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        editorContentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: editorContentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: editorContentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: editorContentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: editorContentView.bottomAnchor),
        ])
    }

    func restoreDraft(_ record: SessionDocument, text: String, identity: FileIdentity? = nil) {
        fileURL = record.path.map { URL(fileURLWithPath: $0) }
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
            editorPosition: isShowingFilePreview ? nil : editor.capturePosition(),
            sidebarMode: sidebarMode == .search ? nil : sidebarMode,
            worktreeShowsHidden: (worktreeSidebar?.showsHidden ?? worktreeShowsHidden) ? true : nil,
            isFilePreview: isShowingFilePreview ? true : nil
        )
    }

    func restoreEditorPosition(_ position: EditorPosition?) {
        if let position {
            // AppKit calculates the titlebar inset during layout, including in a window not presented yet.
            window.layoutIfNeeded()
            editor.restorePosition(position)
        }
    }

    func rememberFilePosition(_ position: EditorPosition? = nil) {
        guard let fileURL, let fileIdentity else { return }
        app.recentFiles.rememberPosition(position ?? editor.capturePosition(), for: fileURL, identity: fileIdentity)
    }

    @discardableResult
    func save(asNew: Bool = false, to selectedURL: URL? = nil, encoding: FileTextEncoding? = nil) async -> Bool {
        guard !isShowingFilePreview, !saving, !worktreeMutation else { return false }
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
            let accessory = SaveEncodingAccessory(selected: saveFormat.encoding)
            panel.accessoryView = accessory
            guard await response(to: panel) == .OK else { return false }
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
            if let queuedAutosave, queuedAutosave.generation <= writtenGeneration { self.queuedAutosave = nil }
            if window.isDocumentEdited { scheduleIdleAutosave() }
            if promote { await app.recentFiles.record(destination, in: folderURL) }
            return true
        } catch {
            await showError("Could Not Save “\(target.lastPathComponent)”", detail: error.localizedDescription)
            return false
        }
    }

    private func write(_ text: String, to target: URL, format: FileFormat, expected: FileRevision?) async throws {
        let file = try await Task.detached {
            try FileBuffer.save(text, to: target, format: format, expected: expected)
        }.value
        let changedPath = fileURL != file.url
        if changedPath { rememberFilePosition() }
        let previousLanguage = resolvedSyntaxLanguage
        updateIdentity(from: file)
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
        editor.isEditable = !isShowingFilePreview && worktreePriorEditability
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
        textDidChange()
    }

    private func textDidChange() {
        editGeneration &+= 1
        updateEditedState()
        scheduleIdleAutosave()
        refreshSyntax(immediate: false)
    }

    private func refreshSyntax(immediate: Bool, preparedSyntax: SyntaxSnapshot? = nil) {
        let language = resolvedSyntaxLanguage
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
        with file: FileBuffer?, focusEditor: Bool = true
    ) async -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        promptingToClose = true
        return await closeBuffer(destination: .buffer(file, focusEditor: focusEditor))
    }

    func replaceBuffer(withPreview preview: OpenFilePreview, focusEditor: Bool) async -> Bool {
        guard canReplaceBuffer, !app.isQuitting else { return false }
        promptingToClose = true
        return await closeBuffer(destination: .preview(preview, focusEditor: focusEditor))
    }

    @discardableResult
    private func closeBuffer(destination: CloseDestination) async -> Bool {
        if editor.hasMarkedText() { editor.unmarkText() }
        let wasEditable = isShowingFilePreview || editor.isEditable
        editor.isEditable = false
        defer {
            editor.isEditable = !isShowingFilePreview && wasEditable
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
            choice = await sheet.confirmClose() ? .discard : .cancel
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
        case .buffer(let file, let focusEditor):
            autosaveFailure = nil
            let restoreFocus = focusEditor || contentHasFocus
            editor.breakUndoCoalescing()
            var position: EditorPosition?
            if let file {
                // Saving the outgoing draft to the target already installed the latest revision.
                if file.url != fileURL {
                    rememberFilePosition()
                    position = await app.recentFiles.position(for: file.url, identity: file.identity)
                    let preparedSyntax = await prepareOpeningSyntax(file, position: position)
                    guard !Task.isCancelled else { return false }
                    load(file, preparedSyntax: preparedSyntax)
                }
            } else {
                rememberFilePosition()
                removeFilePreview()
                fileURL = nil
                manualSyntaxLanguage = nil
                fileIdentity = nil
                savedText = "" as NSString
                format = FileFormat()
                revision = nil
                installText("")
            }
            if restoreFocus { focusContent() }
            restoreEditorPosition(position)
        case .preview(let preview, let focusEditor):
            let restoreFocus = focusEditor || contentHasFocus
            autosaveFailure = nil
            rememberFilePosition()
            loadPreview(preview)
            if restoreFocus { focusContent() }
        case .window:
            window.close()
        }
        return true
    }

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
        if let findPanel { findPanel.resizeTitleBar() }
        else { titleBar.resize() }
    }

    func windowWillClose(_ notification: Notification) {
        rememberFilePosition()
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
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.txt"
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? folderURL
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
        editor.preferredLineEnding = format.lineEnding
        editor.resetMultiCarets()
        syntaxHighlighting?.prepareForBufferReplacement()
        editor.string = text
        refreshSyntax(immediate: true, preparedSyntax: preparedSyntax)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.undoManager?.removeAllActions()
        updateTitle(revealInWorktree: revealInWorktree)
        updateEditedState()
        findPanel?.bufferReplaced()
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
            window.title = "\(folderName.isEmpty ? folderURL.path : folderName) — \(displayName)"
        } else {
            window.title = displayName
        }
        titleBar.update()
        findPanel?.updateName()
        findPanel?.updateCurrentFile(reveal: revealInWorktree)
    }

    private func updateEditedState() {
        let isEdited = savedText.map { !(editor.textStorage?.mutableString.isEqual($0) ?? false) } ?? true
        if isEdited != window.isDocumentEdited {
            window.isDocumentEdited = isEdited
        }
    }
}
