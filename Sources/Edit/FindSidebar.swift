import AppKit

enum SidebarMode: String, Codable, Sendable {
    case search, worktree, scratches

    var title: String {
        switch self {
        case .search: "Search"
        case .worktree: "Worktree"
        case .scratches: "Scratches"
        }
    }
}

enum FindCommand {
    case find, replace, next, previous, toggleSidebar
    case refresh, toggleReplace, toggleCase, toggleWholeWord, toggleRegex
    case replaceAll, replaceSelected, dismissSelected, clearSelection
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
final class FindSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSMenuDelegate {
    private static let sidebarMenuItem = NSToolbarItem.Identifier("Edit.SidebarMenu")
    private static let sidebarTitleItem = NSToolbarItem.Identifier("Edit.SidebarTitle")
    // The toolbar needs room for the window controls, Worktree title and options button.
    private static let minimumSidebarWidth: CGFloat = 208 + SidebarMenuItem.titleLeadingPadding
    private static let maximumSidebarWidth: CGFloat = 650
    private static let contentInset: CGFloat = 10
    private unowned let document: DocumentWindow
    private unowned let app: Edit
    private var settings: FindSettings {
        get { document.findSettings }
        set { document.findSettings = newValue }
    }
    private let matchCase = NSButton(title: "Aa", target: nil, action: nil)
    private let wholeWord = NSButton(title: "ab", target: nil, action: nil)
    private let regex = NSButton(title: ".*", target: nil, action: nil)
    private lazy var findInput = FindInput(name: "Find", options: [matchCase, wholeWord, regex])
    private let replaceInput = FindInput(name: "Replace")
    private let replaceToggle = NSButton(title: "", target: nil, action: nil)
    private let replaceButton = NSButton(title: "", target: nil, action: nil)
    private let resultFile = NSTextField(labelWithString: "Untitled")
    private let resultIcon = NSImageView()
    private let resultStatus = NSTextField(labelWithString: "No results")
    private let results = FindResultsTable()
    private let resultScroll = FindResultsScrollView()
    private let replaceRow = NSStackView()
    private var splitView: NSSplitView { document.documentSplitView }
    private let sidebarContent = NSView()
    private let searchContent = NSStackView()
    private(set) var worktree: WorktreeSidebar?
    private var scratches: WorktreeSidebar?
    var scratchOutline: NSOutlineView? { scratches?.outline }
    private var scratchReload: Task<Void, Never>?
    private let sidebar = NSViewController()
    private lazy var sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    private lazy var decorations = FindDecorations(editor: document.editor)
    private var installed = false
    private weak var sidebarHeader: SidebarMenuItem?
    private var nativeHeaderVisible = false
    private weak var focusBeforeSidebar: NSView?
    private weak var focusBeforeMode: NSView?
    private var previousMode: SidebarMode?
    private var bufferSnapshot: String
    private var resultSnapshot = ""
    private var baseMatches: [FindHit] = []
    private var matches: [FindHit] = []
    private var dismissed: Set<NSRange> = []
    private var selected: Int?
    private var selectedMatchLocation: Int?
    private var editingResults = false
    private var previewRequested = false
    private var movingDismissalsForReplacement = false
    private var applyingEdits = false
    private var bufferSearchScheduled = false
    private var pending = false
    private var validResults = false
    private var generation: UInt64 = 0
    private var work: Task<FindSearch.Outcome, Never>?
    private var activity: Task<Void, Never>?
    private var queuedDirection: Int?
    private weak var pendingResultFocus: FindFieldTextView?
    private var advanceFrom: Int?

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
        bufferSnapshot = document.editor.string
        super.init()
        configure()
        if let storage = document.editor.textStorage {
            NotificationCenter.default.addObserver(self, selector: #selector(storageDidEdit(_:)),
                                                   name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
    }

    deinit {
        work?.cancel()
        activity?.cancel()
        scratchReload?.cancel()
    }

    private var searchVisible: Bool { settings.visible && document.sidebarMode == .search }
    private var worktreeVisible: Bool { settings.visible && document.sidebarMode == .worktree }
    private var scratchesVisible: Bool { settings.visible && document.sidebarMode == .scratches }
    private var worktreeFile: URL? { document.scratchFile == nil ? document.displayedFileURL : nil }

    func restoreVisibility() {
        guard settings.visible else { return }
        switch document.sidebarMode {
        case .worktree:
            showWorktree(focus: false)
        case .scratches:
            showScratches(focus: false)
        case .search:
            present(focusing: nil)
            requestSearch()
        }
    }

    func toggleFocus(of mode: SidebarMode) {
        guard mode != .worktree || document.folderURL != nil else { return }
        if settings.visible && document.sidebarMode == mode && focusIsInSidebar {
            returnFocus(allowingModeChange: true)
            return
        }
        rememberFocus(entering: mode)
        switch mode {
        case .search: focusSearch()
        case .worktree: showWorktree()
        case .scratches: showScratches()
        }
    }

    private func rememberFocus(entering mode: SidebarMode) {
        let responder = document.window.firstResponder as? NSView
        if focusIsInSidebar {
            if document.sidebarMode != mode {
                focusBeforeMode = responder
                previousMode = document.sidebarMode
            }
        } else {
            focusBeforeSidebar = responder
            focusBeforeMode = nil
            previousMode = nil
        }
    }

    private func returnFocus(allowingModeChange: Bool) {
        let window = document.window
        let priorMode = previousMode
        let priorView = focusBeforeMode
        previousMode = nil
        focusBeforeMode = nil
        pendingResultFocus = nil
        previewRequested = false

        if allowingModeChange, let priorMode, let priorView,
           priorMode != .worktree || document.folderURL != nil {
            switch priorMode {
            case .search: showSearch(focusing: nil)
            case .worktree: showWorktree(focus: false)
            case .scratches: showScratches(focus: false)
            }
            if priorView.window === window && !priorView.isHiddenOrHasHiddenAncestor && window.makeFirstResponder(priorView) {
                refreshDecorations()
                return
            }
        }
        let responder = focusBeforeSidebar
        focusBeforeSidebar = nil
        if let responder, responder.window === window, !responder.isHiddenOrHasHiddenAncestor,
           window.makeFirstResponder(responder) {
            refreshDecorations()
            return
        }
        document.focusContent()
        refreshDecorations()
    }

    private func showWorktree(focus: Bool = true) {
        guard let folder = document.folderURL else { return }
        document.requestAutosave()
        let browser: WorktreeSidebar
        if let worktree {
            browser = worktree
        } else {
            browser = WorktreeSidebar(document: document, app: app)
            worktree = browser
            if document.worktreeShowsHidden { browser.setShowsHidden(true) }
            installSidebar(browser.view)
        }
        selectMode(.worktree)
        browser.update(folder: folder, currentFile: worktreeFile)
        present(focusing: focus ? browser.outline : nil)
        browser.setActive(true)
    }

    private func showScratches(focus: Bool = true) {
        document.requestAutosave()
        let list: WorktreeSidebar
        if let scratches {
            list = scratches
        } else {
            list = WorktreeSidebar(document: document, app: app, mode: .scratches)
            scratches = list
            installSidebar(list.view)
        }
        selectMode(.scratches)
        list.updateScratchCurrent(document.scratchFile?.id, reveal: true)
        present(focusing: focus ? list.outline : nil)
        list.setActive(true)
        reloadScratches()
    }

    private func installSidebar(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        sidebarContent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor),
            view.topAnchor.constraint(equalTo: sidebarContent.topAnchor),
            view.bottomAnchor.constraint(equalTo: sidebarContent.bottomAnchor),
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
                guard !Task.isCancelled, let self, settings.visible, document.sidebarMode == .scratches else { return }
                await document.showError("Could Not Load Scratches", detail: error.localizedDescription)
            }
        }
    }

    private func selectMode(_ mode: SidebarMode) {
        let changed = mode != document.sidebarMode
        document.sidebarMode = mode
        searchContent.isHidden = mode != .search
        worktree?.view.isHidden = mode != .worktree
        scratches?.view.isHidden = mode != .scratches
        if mode != .worktree { worktree?.setActive(false) }
        if mode != .scratches { scratches?.setActive(false) }
        if changed && mode != .search {
            previewRequested = false
            pendingResultFocus = nil
            queuedDirection = nil
            requestSearchIfNeeded()
        }
        updateSidebarMenu()
    }

    func folderChanged() {
        if let folder = document.folderURL {
            if worktreeVisible { worktree?.update(folder: folder, currentFile: worktreeFile) }
        } else if document.sidebarMode == .worktree {
            let wasFocused = focusIsInSidebar
            selectMode(.search)
            if settings.visible {
                if wasFocused { document.window.makeFirstResponder(findInput.input) }
                requestSearchIfNeeded()
            }
        }
        updateSidebarMenu()
        reloadScratches()
    }

    func canPerform(_ action: FindCommand) -> Bool {
        switch action {
        case .find, .replace, .toggleSidebar:
            return true
        case .next, .previous:
            return !settings.query.isEmpty
        case .refresh, .toggleReplace, .toggleCase, .toggleWholeWord, .toggleRegex:
            return searchVisible
        case .replaceAll:
            return searchVisible && settings.showsReplacement && validResults && !matches.isEmpty &&
                document.editor.isEditable && !document.editor.hasMarkedText()
        case .replaceSelected:
            return canPerform(.replaceAll) && selected != nil
        case .dismissSelected:
            return searchVisible && validResults && selected != nil
        case .clearSelection:
            return searchVisible && selected != nil
        }
    }

    func perform(_ action: FindCommand) {
        guard canPerform(action) else { return }
        switch action {
        case .find:
            toggleFocus(of: .search)
        case .replace:
            rememberFocus(entering: .search)
            openField(replace: true)
        case .next:
            moveResult(by: 1)
        case .previous:
            moveResult(by: -1)
        case .toggleSidebar:
            if settings.visible {
                hide()
            } else {
                switch document.sidebarMode {
                case .worktree: showWorktree(focus: false)
                case .scratches: showScratches(focus: false)
                case .search: showSearch(focusing: nil)
                }
            }
        case .refresh:
            resetMatches()
        case .toggleReplace:
            setReplacementVisible(!settings.showsReplacement)
        case .toggleCase:
            matchCase.state = settings.options.caseSensitive ? .off : .on
            changeOptions(nil)
        case .toggleWholeWord:
            wholeWord.state = settings.options.wholeWord ? .off : .on
            changeOptions(nil)
        case .toggleRegex:
            regex.state = settings.options.regularExpression ? .off : .on
            changeOptions(nil)
        case .replaceAll:
            apply(matches, advance: false)
        case .replaceSelected:
            if let selected { apply([matches[selected]], advance: true) }
        case .dismissSelected:
            if let selected { dismiss(matches[selected].range) }
        case .clearSelection:
            clearResultFocus()
        }
    }

    func updateName() {
        resultFile.stringValue = document.showsEmptyFolder ? "No File Open" : document.displayName
        resultIcon.image = FileIcons.image(for: document.displayedFileURL, appearance: sidebar.view.effectiveAppearance,
                                           language: document.manualSyntaxLanguage?.iconIdentifier)
    }

    func updateCurrentFile(reveal: Bool) {
        if worktreeVisible, let folder = document.folderURL {
            worktree?.update(folder: folder, currentFile: worktreeFile, revealCurrentFile: reveal)
        }
        scratches?.updateScratchCurrent(document.scratchFile?.id, reveal: reveal)
    }

    func revealCurrentScratch() { scratches?.revealCurrentScratch() }

    func bufferReplaced() {
        dismissed.removeAll()
        selectedMatchLocation = nil
        advanceFrom = nil
        queuedDirection = nil
        pendingResultFocus = nil
        bufferSnapshot = document.editor.string
        publish([])
        requestSearchIfNeeded()
    }

    @objc private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let text = storage.string
        let movesDismissals = !movingDismissalsForReplacement && !dismissed.isEmpty
        if selectedMatchLocation != nil || movesDismissals {
            let range = storage.editedRange
            let oldLength = range.length - storage.changeInLength
            let edit: FindTextEdit
            let oldCount = bufferSnapshot.utf16.count
            if range.location != NSNotFound && NSMaxRange(range) <= storage.length &&
                oldLength >= 0 && oldLength <= oldCount && range.location <= oldCount - oldLength {
                edit = FindTextEdit(range: NSRange(location: range.location, length: oldLength),
                                    replacement: (text as NSString).substring(with: range))
            } else {
                edit = FindTextEdit.singleChange(from: bufferSnapshot as NSString, to: text as NSString)
            }
            if movesDismissals { dismissed = FindTextEdit.moving(dismissed, through: [edit]) }
            if let location = selectedMatchLocation, edit.range.location <= location {
                // Preserve the position in the current buffer, including while its search is pending.
                selectedMatchLocation = location >= NSMaxRange(edit.range)
                    ? location + edit.replacement.utf16.count - edit.range.length
                    : edit.range.location
            }
        }
        bufferSnapshot = text
        generation &+= 1
        validResults = false
        work?.cancel()
        guard !bufferSearchScheduled else { return }
        bufferSearchScheduled = true
        // TextKit finishes its edit notification before decoration updates can lay out text.
        Task { @MainActor [weak self] in
            guard let self else { return }
            bufferSearchScheduled = false
            requestSearchIfNeeded()
        }
    }

    func editorInteracted() {
        guard !applyingEdits, previewRequested else { return }
        previewRequested = false
        refreshDecorations()
    }

    private func configure() {
        for (option, label) in [(matchCase, "Match Case"), (wholeWord, "Whole Word"), (regex, "Regular Expression")] {
            option.setButtonType(.pushOnPushOff)
            option.bezelStyle = .accessoryBar
            option.controlSize = .small
            option.image = optionImage(option.title, underlined: option === wholeWord)
            option.imagePosition = .imageOnly
            option.target = self
            option.action = #selector(changeOptions(_:))
            option.toolTip = label
            option.setAccessibilityLabel(label)
            option.widthAnchor.constraint(equalToConstant: 23).isActive = true
            option.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        matchCase.state = settings.options.caseSensitive ? .on : .off
        wholeWord.state = settings.options.wholeWord ? .on : .off
        regex.state = settings.options.regularExpression ? .on : .off
        updateSearchOptionsAppearance()

        findInput.value = settings.query
        replaceInput.value = settings.replacement
        findInput.onChange = { [weak self] in self?.queryChanged() }
        replaceInput.onChange = { [weak self] in
            guard let self else { return }
            settings.replacement = replaceInput.value
            refreshDecorations()
        }
        findInput.onReturn = { [weak self] in self?.advanceFindFocus() }
        replaceInput.onReturn = { [weak self] in self?.focusFirstResult() }
        findInput.onEscape = { [weak self] in self?.returnFocus(allowingModeChange: false) }
        replaceInput.onEscape = { [weak self] in self?.returnFocus(allowingModeChange: false) }

        configureFieldAction(replaceToggle, label: "Show or Hide Replace", action: #selector(toggleReplaceSection(_:)))
        configureFieldAction(replaceButton, label: "Replace All", action: #selector(replaceAllMatches(_:)))
        replaceButton.image = optionImage("R*")
        let findRow = horizontal([findInput, replaceToggle])
        replaceRow.orientation = .horizontal
        replaceRow.alignment = .top
        replaceRow.spacing = 5
        replaceRow.addArrangedSubview(replaceInput)
        replaceRow.addArrangedSubview(replaceButton)
        updateReplacementVisibility()

        resultFile.maximumNumberOfLines = 1
        resultFile.lineBreakMode = .byTruncatingMiddle
        resultFile.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultFile.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resultFile.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        resultStatus.lineBreakMode = .byTruncatingTail
        resultStatus.textColor = .secondaryLabelColor
        resultStatus.setContentHuggingPriority(.required, for: .horizontal)
        resultStatus.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        resultStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resultIcon.setAccessibilityElement(false)
        resultIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        resultIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let resultHeader = NSView()
        for label in [resultIcon, resultFile, resultStatus] {
            label.translatesAutoresizingMaskIntoConstraints = false
            resultHeader.addSubview(label)
        }
        NSLayoutConstraint.activate([
            resultHeader.heightAnchor.constraint(equalToConstant: 24),
            resultIcon.leadingAnchor.constraint(equalTo: resultHeader.leadingAnchor, constant: 4),
            resultIcon.centerYAnchor.constraint(equalTo: resultHeader.centerYAnchor),
            resultFile.leadingAnchor.constraint(equalTo: resultIcon.trailingAnchor, constant: 5),
            resultFile.centerYAnchor.constraint(equalTo: resultHeader.centerYAnchor),
            resultFile.trailingAnchor.constraint(lessThanOrEqualTo: resultStatus.leadingAnchor, constant: -5),
            resultStatus.trailingAnchor.constraint(equalTo: resultHeader.trailingAnchor, constant: -4),
            resultStatus.centerYAnchor.constraint(equalTo: resultHeader.centerYAnchor),
        ])
        setupResults()

        let content = searchContent
        for control in [findRow, replaceRow, resultHeader, resultScroll] {
            content.addArrangedSubview(control)
        }
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 5
        content.setCustomSpacing(10, after: replaceRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        let view = FindSidebarSurface(frame: NSRect(x: 0, y: 0, width: settings.width, height: 500))
        view.appearanceChanged = { [weak self] in self?.updateName() }
        view.clipsToBounds = true
        sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarContent)
        sidebarContent.addSubview(content)
        sidebar.view = view
        updateName()
        NSLayoutConstraint.activate([
            sidebarContent.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarContent.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sidebarContent.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarContent.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        for control in [findRow, replaceRow, resultHeader] {
            control.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * Self.contentInset).isActive = true
        }
        resultScroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        resultScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        replaceButton.isEnabled = false
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 5
        return stack
    }

    private func optionImage(_ title: String, underlined: Bool = false) -> NSImage {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = NSSize(width: ceil(text.size().width), height: ceil(text.size().height))
        let image = NSImage(size: size, flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func configureFieldAction(_ button: NSButton, label: String, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (nativeHeaderVisible ? [Self.sidebarTitleItem, .sidebarTrackingSeparator] : [.sidebarTrackingSeparator]) +
            document.titleBar.defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarTitleItem, .sidebarTrackingSeparator] + document.titleBar.allowedItemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = document.titleBar.makeItem(identifier) { return item }
        guard identifier == Self.sidebarTitleItem else { return nil }
        let item = SidebarMenuItem(itemIdentifier: identifier, showsTitle: true, mode: document.sidebarMode)
        let options = SidebarMenuItem(itemIdentifier: Self.sidebarMenuItem, showsTitle: false, mode: document.sidebarMode)
        options.menu.delegate = self
        updateSidebarMenuItems(item)
        updateSidebarMenuItems(options)
        item.installOptions(options, trailingInset: Self.contentInset, maximumWidth: Self.maximumSidebarWidth)
        item.isHidden = false
        options.isHidden = options.menu.items.isEmpty
        options.view?.isHidden = options.isHidden
        sidebarHeader = item
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let options = sidebarHeader?.options, options.menu === menu {
            updateSidebarMenuItems(options)
        }
    }

    private func updateSidebarMenu() {
        guard let header = sidebarHeader, let options = header.options else { return }
        header.updateTitle(for: document.sidebarMode)
        options.updateTitle(for: document.sidebarMode)
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
            menu.addItem(withTitle: "Source Control", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: SidebarMode.search.title, action: #selector(selectSearchSidebar(_:)),
                         keyEquivalent: "").target = self
        }
        menu.item(withTitle: SidebarMode.worktree.title)?.isEnabled = document.folderURL != nil
        picker.selectItem(at: menu.indexOfItem(withTitle: document.sidebarMode.title))
    }

    private func updateSidebarOptions(_ menu: NSMenu) {
        switch document.sidebarMode {
        case .search:
            menu.addItem(withTitle: "Refresh Search", action: #selector(refreshSearch(_:)), keyEquivalent: "").target = self
        case .worktree:
            guard let worktree, document.folderURL != nil else { return }
            worktree.addRootCreationItems(to: menu)
            menu.addItem(.separator())
            let hidden = menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
            hidden.target = self
            hidden.state = worktree.showsHidden ? .on : .off
        case .scratches:
            scratches?.addRootCreationItems(to: menu)
        }
    }

    private func setupResults() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SearchResult"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        results.addTableColumn(column)
        results.headerView = nil
        results.style = .fullWidth
        results.rowSizeStyle = .custom
        results.rowHeight = 24
        results.usesAutomaticRowHeights = false
        results.intercellSpacing = .zero
        results.backgroundColor = .clear
        results.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        results.allowsEmptySelection = true
        results.setAccessibilityLabel("Search Results")
        results.dataSource = self
        results.delegate = self
        results.target = self
        results.doubleAction = #selector(openClickedResult(_:))
        results.onReturn = { [weak self] in self?.activateResult() }
        results.onSpace = { [weak self] in
            guard let self, let selected else { return }
            openResult(at: selected)
        }
        results.onEscape = { [weak self] in self?.clearResultFocus() }
        resultScroll.drawsBackground = false
        resultScroll.automaticallyAdjustsContentInsets = false
        resultScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        resultScroll.contentView.clipsToBounds = true
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.documentView = results
    }

    private func installIfNeeded() {
        guard !installed else { return }
        let window = document.window
        let split = document.installDocumentSplit()
        sidebarItem.minimumThickness = Self.minimumSidebarWidth
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.maximumThickness = Self.maximumSidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = min(0.7, CGFloat(settings.width) / max(splitView.bounds.width, 1))
        sidebarItem.isCollapsed = true
        split.insertSplitViewItem(sidebarItem, at: 0)
        window.toolbar = document.titleBar.makeToolbar(delegate: self)
        window.initialFirstResponder = document.contentResponder
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        installed = true
    }

    func resizeTitleBar() {
        document.titleBar.resize(sidebarWidth: installed && !sidebarItem.isCollapsed ? sidebar.view.frame.width : 0)
    }

    @objc private func splitResized(_ notification: Notification) {
        guard installed else { return }
        resizeTitleBar()
        settings.visible = !sidebarItem.isCollapsed
        let width = sidebar.view.frame.width
        if settings.visible && width >= sidebarItem.minimumThickness {
            settings.width = width
        }
        updateSidebarToolbarVisibility()
        worktree?.setActive(worktreeVisible)
        scratches?.setActive(scratchesVisible)
        if !settings.visible {
            previewRequested = false
            if focusIsInSidebar { returnFocus(allowingModeChange: false) }
        }
        refreshDecorations()
    }

    private var focusIsInSidebar: Bool {
        guard installed, let view = document.window.firstResponder as? NSView else { return false }
        return view.isDescendant(of: sidebar.view)
    }

    private func present(focusing input: NSView?) {
        let window = document.window
        let responder = window.firstResponder
        let desiredWidth = max(settings.width, Self.minimumSidebarWidth)
        let needsOpening = !installed || !settings.visible || sidebarItem.isCollapsed
        PanelLayout.withoutAnimation {
            installIfNeeded()
            settings.visible = true
            if needsOpening {
                sidebarItem.preferredThicknessFraction = min(0.7, CGFloat(desiredWidth) / max(splitView.bounds.width, 1))
                setSidebarCollapsed(false, desiredWidth: desiredWidth)
            }
        }
        if let input {
            pendingResultFocus = nil
            window.makeFirstResponder(input)
        } else if let responder, !focusIsInSidebar {
            window.makeFirstResponder(responder)
        }
        refreshDecorations()
    }

    private func hide() {
        guard installed && settings.visible else { return }
        pendingResultFocus = nil
        if focusIsInSidebar { returnFocus(allowingModeChange: false) }
        settings.visible = false
        worktree?.setActive(false)
        scratches?.setActive(false)
        previewRequested = false
        PanelLayout.withoutAnimation { setSidebarCollapsed(true) }
        refreshDecorations()
    }

    private func updateSidebarToolbarVisibility() {
        setNativeHeaderVisible(settings.visible && !sidebarItem.isCollapsed)
        guard let header = sidebarHeader, let options = header.options else { return }
        let optionsHidden = options.menu.items.isEmpty
        PanelLayout.withoutAnimation {
            if options.isHidden != optionsHidden { options.isHidden = optionsHidden }
            if options.view?.isHidden != optionsHidden { options.view?.isHidden = optionsHidden }
        }
    }

    private func setNativeHeaderVisible(_ visible: Bool) {
        guard nativeHeaderVisible != visible, let toolbar = document.window.toolbar else { return }
        nativeHeaderVisible = visible
        PanelLayout.withoutAnimation {
            if visible {
                toolbar.insertItem(withItemIdentifier: Self.sidebarTitleItem, at: 0)
            } else {
                sidebarHeader?.view?.isHidden = true
                toolbar.removeItem(identifier: Self.sidebarTitleItem)
            }
            let window = document.window
            window.layoutIfNeeded()
            if let host = document.titleBar.toolbarWindow, host !== window { host.layoutIfNeeded() }
        }
    }

    private func setSidebarCollapsed(_ collapsed: Bool, desiredWidth: CGFloat? = nil) {
        sidebarItem.isCollapsed = collapsed
        if let desiredWidth { splitView.setPosition(desiredWidth, ofDividerAt: 0) }
        document.window.layoutIfNeeded()
        resizeTitleBar()
        updateSidebarToolbarVisibility()
    }

    func finishSidebarHeaderLayout() {
        guard let header = sidebarHeader, !header.isHidden else { return }
        PanelLayout.finishHeaderLayout(header, in: document.window)
    }

    private func focusSearch() {
        guard selectedMatchLocation != nil else {
            openField(replace: false)
            return
        }
        document.requestAutosave()
        previewRequested = settings.showsReplacement
        showSearch(focusing: results)
        if validResults, let selected {
            selectRow(selected, reveal: true, preview: true)
        }
    }

    private func openField(replace: Bool) {
        document.requestAutosave()
        var changedQuery = false
        if let editor = document.window.firstResponder as? EditorTextView, editor === document.editor {
            let selection = editor.selectedRange()
            let text = editor.string as NSString
            if selection.length > 0 && NSMaxRange(selection) <= text.length {
                let selectedText: String
                if let ranges = editor.focusRanges {
                    selectedText = ranges
                        .map { NSIntersectionRange($0, selection) }
                        .filter { $0.length > 0 }
                        .map { text.substring(with: $0) }
                        .joined(separator: editor.preferredLineEnding)
                } else {
                    selectedText = text.substring(with: selection)
                }
                let query = settings.options.regularExpression ? NSRegularExpression.escapedPattern(for: selectedText) : selectedText
                if !query.isEmpty && query != settings.query {
                    changedQuery = true
                    settings.query = query
                    findInput.value = query
                    dismissed.removeAll()
                    selected = nil
                    selectedMatchLocation = nil
                }
            }
        }
        selectMode(.search)
        if replace { setReplacementVisible(true) }
        present(focusing: replace ? replaceInput.input : findInput.input)
        previewRequested = false
        if changedQuery || (!validResults && !pending) { requestSearch() }
        refreshDecorations()
    }

    private func setReplacementVisible(_ visible: Bool) {
        if settings.showsReplacement != visible { pendingResultFocus = nil }
        if !visible && document.window.firstResponder === replaceInput.input {
            document.window.makeFirstResponder(findInput.input)
        }
        settings.showsReplacement = visible
        updateReplacementVisibility()
        if let selected { selectRow(selected, reveal: false, preview: visible && previewRequested) }
        refreshVisibleRows()
        refreshDecorations()
        updateReplaceAvailability()
    }

    private func updateReplacementVisibility() {
        replaceToggle.image = NSImage(systemSymbolName: settings.showsReplacement ? "chevron.down" : "chevron.right",
                                      accessibilityDescription: nil)
        replaceRow.isHidden = !settings.showsReplacement
    }

    @objc private func toggleReplaceSection(_ sender: Any?) { perform(.toggleReplace) }
    @objc private func replaceAllMatches(_ sender: Any?) { perform(.replaceAll) }
    @objc private func refreshSearch(_ sender: Any?) { perform(.refresh) }

    @objc private func selectSearchSidebar(_ sender: Any?) {
        rememberFocus(entering: .search)
        document.requestAutosave()
        showSearch(focusing: findInput.input)
    }

    @objc private func selectWorktreeSidebar(_ sender: Any?) {
        rememberFocus(entering: .worktree)
        showWorktree()
    }

    @objc private func selectScratchSidebar(_ sender: Any?) {
        rememberFocus(entering: .scratches)
        showScratches()
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        guard worktreeVisible, let worktree else { return }
        worktree.setShowsHidden(!worktree.showsHidden)
        document.worktreeShowsHidden = worktree.showsHidden
        updateSidebarMenu()
    }

    private func showSearch(focusing input: NSView?) {
        selectMode(.search)
        present(focusing: input)
        if !validResults && !pending { requestSearch() }
    }

    @objc private func changeOptions(_ sender: Any?) {
        settings.options = FindOptions(caseSensitive: matchCase.state == .on, wholeWord: wholeWord.state == .on,
                                       regularExpression: regex.state == .on)
        updateSearchOptionsAppearance()
        resetMatches()
    }

    private func updateSearchOptionsAppearance() {
        for option in [matchCase, wholeWord, regex] {
            option.contentTintColor = option.state == .on ? .controlAccentColor : nil
        }
    }

    private func queryChanged() {
        settings.query = findInput.value
        resetMatches()
    }

    private func resetMatches() {
        dismissed.removeAll()
        queuedDirection = nil
        pendingResultFocus = nil
        advanceFrom = nil
        selected = nil
        selectedMatchLocation = nil
        previewRequested = false
        requestSearch()
    }

    private func requestSearchIfNeeded() {
        if searchVisible || queuedDirection != nil {
            requestSearch()
        } else {
            generation &+= 1
            work?.cancel()
            activity?.cancel()
            validResults = false
            pending = false
            refreshDecorations()
        }
    }

    private func requestSearch() {
        generation &+= 1
        let searchGeneration = generation
        work?.cancel()
        activity?.cancel()
        validResults = false
        pending = false
        updateReplaceAvailability()
        if settings.query.isEmpty {
            resultSnapshot = bufferSnapshot
            publish([])
            return
        }
        pending = true
        refreshDecorations()
        refreshVisibleRows()
        let snapshot = bufferSnapshot
        let query = settings.query
        let options = settings.options
        let ranges = document.editor.focusRanges
        let worker = Task.detached(priority: .userInitiated) {
            FindSearch.match(query, in: snapshot, options: options, ranges: ranges)
        }
        work = worker
        activity = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, generation == searchGeneration, pending else { return }
            resultStatus.stringValue = "Searching…"
        }
        Task { [weak self] in
            let outcome = await worker.value
            guard let self, generation == searchGeneration, ranges == document.editor.focusRanges else { return }
            activity?.cancel()
            pending = false
            resultSnapshot = snapshot
            switch outcome {
            case .matches(let found):
                publish(found)
            case .invalidExpression:
                publish([], invalid: true)
            }
        }
    }

    private func publish(_ found: [FindHit], invalid: Bool = false) {
        let previousLocation = selectedMatchLocation
        baseMatches = found
        matches = found.filter { !dismissed.contains($0.range) }
        validResults = !invalid && !settings.query.isEmpty
        let target = previousLocation.flatMap { location in
            matches.firstIndex { $0.range.location >= location } ?? matches.indices.first
        }
        let focusedResults = document.window.firstResponder === results
        selected = nil
        selectedMatchLocation = nil
        editingResults = true
        results.reloadData()
        results.deselectAll(nil)
        editingResults = false
        resultStatus.stringValue = invalid ? "Invalid regex" : matches.isEmpty ? "No results"
            : matches.count == 1 ? "1 match" : "\(matches.count) matches"
        updateReplaceAvailability()
        if let advanceFrom {
            self.advanceFrom = nil
            if searchVisible, let next = matches.firstIndex(where: { $0.range.location >= advanceFrom }) {
                selectRow(next, reveal: true, preview: true)
            } else if searchVisible && document.window.firstResponder === results {
                document.window.makeFirstResponder(findInput.input)
            }
        } else if let queuedDirection {
            self.queuedDirection = nil
            moveResult(by: queuedDirection)
        } else if let target {
            selectRow(target, reveal: focusedResults, preview: previewRequested)
        } else {
            previewRequested = false
            if focusedResults { document.window.makeFirstResponder(findInput.input) }
        }
        if let input = pendingResultFocus {
            pendingResultFocus = nil
            if document.window.firstResponder === input { focusFirstResult() }
        }
        refreshDecorations()
        refreshVisibleRows()
    }

    private func moveResult(by direction: Int) {
        pendingResultFocus = nil
        guard !settings.query.isEmpty else { return }
        guard validResults else {
            if pending {
                queuedDirection = direction
            } else if resultStatus.stringValue != "Invalid regex" {
                queuedDirection = direction
                requestSearch()
            }
            return
        }
        guard !matches.isEmpty else { return }
        let base = selected ?? (direction > 0 ? -1 : 0)
        selectRow((base + direction + matches.count) % matches.count, reveal: true, preview: searchVisible && focusIsInSidebar)
    }

    private func advanceFindFocus() {
        if settings.showsReplacement {
            document.window.makeFirstResponder(replaceInput.input)
        } else {
            focusFirstResult()
        }
    }

    private func focusFirstResult() {
        guard searchVisible else { return }
        let window = document.window
        if pending || bufferSearchScheduled {
            queuedDirection = nil
            pendingResultFocus = window.firstResponder as? FindFieldTextView
            return
        }
        guard validResults, !matches.isEmpty, window.makeFirstResponder(results) else { return }
        selectRow(0, reveal: true, preview: true)
    }

    private func selectRow(_ index: Int?, reveal: Bool, preview: Bool) {
        if let index {
            guard validResults, matches.indices.contains(index) else { return }
        }
        let previous = selected
        selected = index
        selectedMatchLocation = index.map { matches[$0].range.location }
        previewRequested = index != nil && preview && settings.showsReplacement && searchVisible
        if results.selectedRow != (index ?? -1) {
            editingResults = true
            if let index {
                results.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                results.deselectAll(nil)
            }
            editingResults = false
        }
        updateRowSelection(previous)
        if previous != index { updateRowSelection(index) }
        if reveal, let index {
            results.scrollRowToVisible(index)
            document.editor.scrollRangeToVisible(matches[index].range)
        }
        refreshDecorations()
    }

    private func clearResultFocus() {
        selectRow(nil, reveal: false, preview: false)
        document.window.makeFirstResponder(findInput.input)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        validResults
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !editingResults else { return }
        let row = results.selectedRow
        selectRow(row >= 0 ? row : nil, reveal: true, preview: true)
    }

    @objc private func openClickedResult(_ sender: NSTableView) {
        openResult(at: sender.clickedRow)
    }

    private func openResult(at row: Int) {
        guard validResults, matches.indices.contains(row) else { return }
        selectRow(row, reveal: false, preview: false)
        let caret = NSRange(location: NSMaxRange(matches[row].range), length: 0)
        let editor = document.editor
        guard document.window.makeFirstResponder(editor) else { return }
        editor.setCaretSelections([caret])
        editor.scrollRangeToVisible(caret)
    }

    private func activateResult() {
        guard validResults, let selected, matches.indices.contains(selected) else { return }
        if settings.showsReplacement {
            apply([matches[selected]], advance: true)
        } else {
            openResult(at: selected)
        }
    }

    private func dismiss(_ range: NSRange) {
        guard validResults, let index = matches.firstIndex(where: { $0.range == range }) else { return }
        dismissed.insert(range)
        publish(baseMatches)
        if matches.isEmpty {
            document.window.makeFirstResponder(findInput.input)
        } else {
            selectRow(min(index, matches.count - 1), reveal: true, preview: true)
        }
    }

    private func apply(_ hits: [FindHit], advance: Bool) {
        guard validResults, searchVisible, settings.showsReplacement,
              document.editor.isEditable, !document.editor.hasMarkedText(),
              let first = hits.first, let last = hits.last, document.editor.string == resultSnapshot else { return }
        let source = resultSnapshot as NSString
        let edits = hits.map { FindTextEdit(range: $0.range, replacement: $0.replacement(
            using: settings.replacement, in: source, isRegex: settings.options.regularExpression
        )) }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let editor = document.editor
        let scoped = editor.focusRanges != nil
        var output: String?
        if !scoped {
            var start = span.location
            var replacement = ""
            for edit in edits {
                replacement += source.substring(with: NSRange(location: start, length: edit.range.location - start))
                replacement += edit.replacement
                start = NSMaxRange(edit.range)
            }
            output = replacement
        }

        advanceFrom = advance ? first.range.location + edits[0].replacement.utf16.count : nil
        let replacements = scoped ? edits.compactMap { edit -> MultiCaretEditing.Replacement? in
            guard edit.replacement != source.substring(with: edit.range) else { return nil }
            return MultiCaretEditing.Replacement(range: edit.range, text: edit.replacement)
        } : []
        if scoped ? replacements.isEmpty : output == source.substring(with: span) {
            publish(baseMatches)
            return
        }
        let oldDismissed = dismissed
        dismissed = FindTextEdit.moving(dismissed, through: edits)
        decorations.clearPreview()
        movingDismissalsForReplacement = true
        applyingEdits = true
        let changed: Bool
        if let output {
            changed = editor.replaceFoundText(in: span, with: output)
        } else {
            let end = NSMaxRange(last.range) + replacements.reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
            changed = editor.applyMultiEdits(replacements, selections: [NSRange(location: end, length: 0)])
        }
        movingDismissalsForReplacement = false
        applyingEdits = false
        if changed {
            document.requestAutosave()
        } else {
            dismissed = oldDismissed
            advanceFrom = nil
        }
    }

    private func updateReplaceAvailability() { replaceButton.isEnabled = canPerform(.replaceAll) }

    func viewportChanged() { decorations.layout() }

    private func refreshDecorations() {
        let hit = validResults ? selected.map { matches[$0] } : nil
        let preview = previewRequested && searchVisible && settings.showsReplacement
            ? hit.map { ($0.range, $0.replacement(using: settings.replacement, in: resultSnapshot as NSString,
                                                  isRegex: settings.options.regularExpression)) }
            : nil
        decorations.update(snapshot: resultSnapshot, ranges: searchVisible && validResults ? matches.map(\.range) : [],
                           selected: hit?.range, preview: preview)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("FindResultRow")
        if let row = tableView.makeView(withIdentifier: identifier, owner: nil) as? FindResultRow { return row }
        let view = FindResultRow()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FindMatch")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FindResultCell
            ?? FindResultCell(frame: .zero)
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: FindResultCell, row: Int) {
        let range = matches[row].range
        cell.configure(text: excerpt(of: matches[row]), replacementAvailable: settings.showsReplacement,
                       acceptsActions: validResults, selected: selected == row,
                       apply: { [weak self] in
                           guard let self, let match = matches.first(where: { $0.range == range }) else { return }
                           apply([match], advance: true)
                       },
                       dismiss: { [weak self] in self?.dismiss(range) })
        results.configureHover(for: cell, row: row)
    }

    private func updateRowSelection(_ row: Int?) {
        guard let row, matches.indices.contains(row) else { return }
        (results.view(atColumn: 0, row: row, makeIfNecessary: false) as? FindResultCell)?.updateSelection(selected == row)
    }

    private func refreshVisibleRows() {
        let visible = results.rows(in: results.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<min(NSMaxRange(visible), matches.count) {
            if let cell = results.view(atColumn: 0, row: row, makeIfNecessary: false) as? FindResultCell {
                configure(cell, row: row)
            }
        }
    }

    private func excerpt(of hit: FindHit) -> NSAttributedString {
        let range = hit.range
        let source = resultSnapshot as NSString
        var start = 0
        var end = 0
        var contentEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                            for: NSRange(location: range.location, length: 0))
        if let scope = hit.scope {
            start = max(start, scope.location)
            contentEnd = min(contentEnd, NSMaxRange(scope))
        }
        // Keep enough room for the match itself before the trailing row actions.
        let from = max(start, range.location - 9)
        let to = max(from, min(contentEnd, max(NSMaxRange(range), from + 100)))
        let composed = source.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
        let excerptRange = hit.scope.map { NSIntersectionRange(composed, $0) } ?? composed
        let prefix = excerptRange.location > start ? "…" : ""
        let suffix = NSMaxRange(excerptRange) < contentEnd ? "…" : ""
        let text = source.substring(with: excerptRange).replacingOccurrences(of: "\t", with: " ")
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.tighteningFactorForTruncation = 0
        let label = NSMutableAttributedString(string: text.isEmpty ? "↵" : prefix + text + suffix, attributes: [
            .font: EditorTextView.defaultFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
        let intersection = NSIntersectionRange(range, excerptRange)
        if intersection.length > 0 {
            label.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                               range: NSRange(location: intersection.location - excerptRange.location + prefix.utf16.count,
                                              length: intersection.length))
        }
        return label
    }
}


@MainActor
private final class FindSidebarSurface: NSView {
    var appearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}
