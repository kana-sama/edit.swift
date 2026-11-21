import AppKit

enum FindCommand {
    case find, replace, next, previous, toggleSidebar
    case refresh, toggleReplace, toggleCase, toggleWholeWord, toggleRegex
    case replaceAll, replaceSelected, dismissSelected, clearSelection
}

@MainActor
private final class FindSplitView: NSSplitView {
    var trackDivider: ((() -> Void) -> Void)?

    @objc dynamic var animatedDividerPosition: CGFloat {
        get { arrangedSubviews.first?.frame.maxX ?? 0 }
        set { setPosition(newValue, ofDividerAt: 0) }
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == #keyPath(FindSplitView.animatedDividerPosition) { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    override func mouseDown(with event: NSEvent) {
        if let trackDivider {
            trackDivider { super.mouseDown(with: event) }
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class FindSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    private static let sidebarMenuItem = NSToolbarItem.Identifier("Edit.SidebarMenu")
    private static let minimumSidebarWidth: CGFloat = 185
    private static let minimumEditorWidth: CGFloat = 128
    private static let contentInset: CGFloat = 10
    private unowned let document: DocumentWindow
    private let writesPreferences: Bool
    private var settings: FindSettings
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
    private let resultScroll = NSScrollView()
    private let replaceRow = NSStackView()
    private let split = NSSplitViewController()
    private let splitView = FindSplitView(frame: .zero)
    private var contentTrailing: NSLayoutConstraint?
    private var contentWidth: NSLayoutConstraint?
    private let sidebar = NSViewController()
    private let editorController = NSViewController()
    private lazy var sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    private lazy var decorations = FindDecorations(editor: document.editor)
    private var installed = false
    private var layoutAnchor: NSPoint?
    private var sidebarTransition: UInt64 = 0
    private var sidebarAnimating = false
    private var bufferSnapshot: String
    private var resultSnapshot = ""
    private var baseMatches: [FindHit] = []
    private var matches: [FindHit] = []
    private var dismissed: Set<NSRange> = []
    private var selected: Int?
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
    private var preferenceWrite: Task<Void, Never>?
    private var queuedDirection: Int?
    private var advanceFrom: Int?

    init(document: DocumentWindow, settings: FindSettings, writesPreferences: Bool) {
        self.document = document
        self.settings = settings
        self.writesPreferences = writesPreferences
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
        preferenceWrite?.cancel()
    }

    func restoreVisibility() {
        guard settings.visible else { return }
        present(focusing: nil, animate: false)
        requestSearch()
    }

    func canPerform(_ action: FindCommand) -> Bool {
        switch action {
        case .find, .replace, .toggleSidebar:
            return true
        case .next, .previous:
            return !settings.query.isEmpty
        case .refresh, .toggleReplace, .toggleCase, .toggleWholeWord, .toggleRegex:
            return settings.visible
        case .replaceAll:
            return settings.visible && settings.showsReplacement && validResults && !matches.isEmpty &&
                document.editor.isEditable && !document.editor.hasMarkedText()
        case .replaceSelected:
            return canPerform(.replaceAll) && selected != nil
        case .dismissSelected:
            return settings.visible && validResults && selected != nil
        case .clearSelection:
            return settings.visible && selected != nil
        }
    }

    func perform(_ action: FindCommand) {
        guard canPerform(action) else { return }
        switch action {
        case .find:
            openField(replace: false)
        case .replace:
            openField(replace: true)
        case .next:
            moveResult(by: 1)
        case .previous:
            moveResult(by: -1)
        case .toggleSidebar:
            if settings.visible {
                hide()
            } else {
                present(focusing: nil, animate: true)
                if !validResults && !pending { requestSearch() }
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
        resultFile.stringValue = document.window.title
        resultIcon.image = FileIcons.image(for: document.fileURL, appearance: sidebar.view.effectiveAppearance,
                                           language: document.manualSyntaxLanguage?.iconIdentifier)
    }

    func bufferReplaced() {
        dismissed.removeAll()
        advanceFrom = nil
        queuedDirection = nil
        bufferSnapshot = document.editor.string
        publish([])
        requestSearchIfNeeded()
    }

    @objc private func storageDidEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let text = storage.string
        if !movingDismissalsForReplacement && !dismissed.isEmpty {
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
            dismissed = FindTextEdit.moving(dismissed, through: [edit])
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

    func persistSettings() {
        preferenceWrite?.cancel()
        guard writesPreferences else { return }
        settings.store(in: .standard)
    }

    private func schedulePreferencesWrite() {
        guard writesPreferences else { return }
        preferenceWrite?.cancel()
        preferenceWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            self.settings.store(in: .standard)
        }
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
            schedulePreferencesWrite()
            refreshDecorations()
        }
        findInput.onReturn = { [weak self] in self?.moveResult(by: 1) }
        replaceInput.onReturn = { [weak self] in self?.focusFirstResult() }
        findInput.onEscape = { [weak self] in self?.hide() }
        replaceInput.onEscape = { [weak self] in self?.hide() }

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

        let content = NSStackView(views: [findRow, replaceRow, resultHeader, resultScroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.setCustomSpacing(10, after: replaceRow)
        content.translatesAutoresizingMaskIntoConstraints = false
        let view = FindSidebarSurface(frame: NSRect(x: 0, y: 0, width: settings.width, height: 500))
        view.appearanceChanged = { [weak self] in self?.updateName() }
        view.clipsToBounds = true
        view.addSubview(content)
        sidebar.view = view
        updateName()
        let trailing = content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.contentInset)
        contentTrailing = trailing
        contentWidth = content.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.contentInset),
            trailing,
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        for control in [findRow, replaceRow, resultHeader, resultScroll] {
            control.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
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
        [.flexibleSpace, Self.sidebarMenuItem, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.sidebarMenuItem else { return nil }
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.isBordered = true
        item.isHidden = true
        item.label = "Sidebar Menu"
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: item.label)
        item.showsIndicator = false

        let menu = NSMenu(title: "Sidebars")
        let search = menu.addItem(withTitle: "Search", action: #selector(selectSearchSidebar(_:)), keyEquivalent: "")
        search.target = self
        search.state = .on
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Search", action: #selector(refreshSearch(_:)), keyEquivalent: "").target = self
        item.menu = menu
        return item
    }

    private func setupResults() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SearchResult"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        results.addTableColumn(column)
        results.headerView = nil
        results.style = .sourceList
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
        results.onEscape = { [weak self] in self?.clearResultFocus() }
        resultScroll.drawsBackground = false
        resultScroll.automaticallyAdjustsContentInsets = false
        resultScroll.contentView.clipsToBounds = true
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.documentView = results
    }

    private func installIfNeeded() {
        guard !installed else { return }
        let window = document.window
        let previousSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let oldFrame = window.frame
        let editorPane = NSView(frame: NSRect(origin: .zero, size: previousSize))
        let scroll = document.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        editorPane.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: editorPane.topAnchor),
        ])
        editorController.view = editorPane
        let editorItem = NSSplitViewItem(viewController: editorController)
        editorItem.minimumThickness = Self.minimumEditorWidth
        sidebarItem.minimumThickness = Self.minimumSidebarWidth
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.maximumThickness = 650
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = min(0.7, CGFloat(settings.width) / max(previousSize.width, 1))
        sidebarItem.isCollapsed = true
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.trackDivider = { [weak self] track in
            guard let self else {
                track()
                return
            }
            guard !sidebarAnimating else { return }
            let transition = beginSidebarTransition()
            track()
            // NSTextView can scroll to its caret as AppKit ends live resize, after the last split notification.
            finishSidebarTransition(transition)
        }
        split.splitView = splitView
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        split.view.setFrameSize(previousSize)
        window.contentViewController = split
        let toolbar = NSToolbar(identifier: "Edit.Search")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        if window.frame != oldFrame { window.setFrame(oldFrame, display: window.isVisible) }
        window.initialFirstResponder = document.editor
        restoreEditorAnchor()
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        installed = true
    }

    @objc private func splitResized(_ notification: Notification) {
        guard installed else { return }
        restoreEditorAnchor()
        guard !sidebarAnimating else { return }
        settings.visible = !sidebarItem.isCollapsed
        let width = sidebar.view.frame.width
        if settings.visible && width >= sidebarItem.minimumThickness {
            settings.width = width
        }
        updateSidebarToolbarVisibility()
        if !settings.visible {
            previewRequested = false
            if focusIsInSidebar { document.window.makeFirstResponder(document.editor) }
        }
        refreshDecorations()
        schedulePreferencesWrite()
    }

    private var focusIsInSidebar: Bool {
        guard installed, let view = document.window.firstResponder as? NSView else { return false }
        return view.isDescendant(of: sidebar.view)
    }

    private func present(focusing input: NSTextView?, animate: Bool) {
        let window = document.window
        let responder = window.firstResponder
        let desiredWidth = settings.width
        let transition = !installed || !settings.visible || sidebarItem.isCollapsed ? beginSidebarTransition() : nil
        installIfNeeded()
        settings.visible = true
        if let transition {
            if !sidebarAnimating {
                sidebarItem.preferredThicknessFraction = min(0.7, CGFloat(desiredWidth) / max(splitView.bounds.width, 1))
            }
            setSidebarCollapsed(false, animate: animate, transition: transition, desiredWidth: desiredWidth)
        }
        if let input {
            window.makeFirstResponder(input)
        } else if let responder, !focusIsInSidebar {
            window.makeFirstResponder(responder)
        }
        refreshDecorations()
        schedulePreferencesWrite()
    }

    private func hide() {
        guard installed && settings.visible else { return }
        let animation = beginSidebarTransition()
        if focusIsInSidebar { document.window.makeFirstResponder(document.editor) }
        settings.visible = false
        updateSidebarToolbarVisibility()
        previewRequested = false
        setSidebarCollapsed(true, animate: true, transition: animation)
        refreshDecorations()
        schedulePreferencesWrite()
    }

    private func updateSidebarToolbarVisibility() {
        let hidden = !settings.visible || sidebarItem.isCollapsed || sidebarAnimating
        guard let item = document.window.toolbar?.items.first(where: { $0.itemIdentifier == Self.sidebarMenuItem }),
              item.isHidden != hidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            item.isHidden = hidden
        }
    }

    private func beginSidebarTransition() -> UInt64 {
        let scroll = document.scrollView
        // Anchor to the visible edge below the titlebar if its inset changes during layout.
        var anchor = scroll.contentView.bounds.origin
        anchor.y += scroll.contentInsets.top
        layoutAnchor = anchor
        sidebarTransition &+= 1
        return sidebarTransition
    }

    private func setSidebarCollapsed(
        _ collapsed: Bool, animate: Bool, transition: UInt64, desiredWidth: CGFloat? = nil
    ) {
        let canAnimate = animate && document.window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let availableWidth = splitView.bounds.width - Self.minimumEditorWidth - splitView.dividerThickness
        let width = min(desiredWidth ?? settings.width, availableWidth)
        let dividerIsAnimating = contentWidth?.isActive == true
        if dividerIsAnimating || (canAnimate && !sidebarAnimating && width >= Self.minimumSidebarWidth) {
            animateDivider(to: collapsed ? 0 : max(0, width), openWidth: width,
                           animated: canAnimate, transition: transition)
        } else if canAnimate {
            // AppKit provides the overlay sidebar when the window cannot fit both panes.
            sidebarAnimating = true
            updateSidebarToolbarVisibility()
            NSAnimationContext.runAnimationGroup { _ in
                sidebarItem.animator().isCollapsed = collapsed
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.finishSidebarTransition(transition) }
            }
        } else {
            sidebarItem.isCollapsed = collapsed
            if let desiredWidth { splitView.setPosition(desiredWidth, ofDividerAt: 0) }
            finishSidebarTransition(transition)
        }
    }

    private func animateDivider(to position: CGFloat, openWidth: CGFloat, animated: Bool, transition: UInt64) {
        sidebarAnimating = true
        updateSidebarToolbarVisibility()
        if contentWidth?.isActive != true {
            // The sidebar clips its contents as the native divider moves.
            contentTrailing?.isActive = false
            contentWidth?.constant = max(0, openWidth - 2 * Self.contentInset)
            contentWidth?.isActive = true
            sidebarItem.minimumThickness = 0
            sidebarItem.canCollapse = false
            if sidebarItem.isCollapsed {
                sidebarItem.isCollapsed = false
                splitView.animatedDividerPosition = 0
            }
        }
        let distance = abs(position - splitView.animatedDividerPosition)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? context.duration * Double(min(1, distance / max(openWidth, 1))) : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            splitView.animator().animatedDividerPosition = position
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.finishSidebarTransition(transition) }
        }
    }

    private func finishSidebarTransition(_ transition: UInt64) {
        guard sidebarTransition == transition else { return }
        if contentWidth?.isActive == true {
            if !settings.visible { sidebarItem.isCollapsed = true }
            sidebarItem.minimumThickness = Self.minimumSidebarWidth
            sidebarItem.canCollapse = true
            contentWidth?.isActive = false
            contentTrailing?.isActive = true
        }
        sidebarAnimating = false
        document.window.layoutIfNeeded()
        updateSidebarToolbarVisibility()
        restoreEditorAnchor()
        // AppKit also reconciles its text viewport after focus and split changes.
        Task { @MainActor [weak self] in
            guard let self, sidebarTransition == transition else { return }
            restoreEditorAnchor()
            layoutAnchor = nil
        }
    }

    private func restoreEditorAnchor() {
        guard var layoutAnchor else { return }
        let scroll = document.scrollView
        let clip = scroll.contentView
        layoutAnchor.y -= scroll.contentInsets.top
        let bounds = clip.constrainBoundsRect(NSRect(origin: layoutAnchor, size: clip.bounds.size))
        guard clip.bounds.origin != bounds.origin else { return }
        clip.scroll(to: bounds.origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func openField(replace: Bool) {
        document.requestAutosave()
        var changedQuery = false
        if let editor = document.window.firstResponder as? EditorTextView, editor === document.editor {
            let selection = editor.selectedRange()
            let text = editor.string as NSString
            if selection.length > 0 && NSMaxRange(selection) <= text.length {
                let selectedText = text.substring(with: selection)
                let query = settings.options.regularExpression ? NSRegularExpression.escapedPattern(for: selectedText) : selectedText
                if query != settings.query {
                    changedQuery = true
                    settings.query = query
                    findInput.value = query
                    dismissed.removeAll()
                    selected = nil
                }
            }
        }
        if replace { setReplacementVisible(true) }
        present(focusing: replace ? replaceInput.input : findInput.input, animate: true)
        previewRequested = false
        if changedQuery || (!validResults && !pending) { requestSearch() }
        refreshDecorations()
    }

    private func setReplacementVisible(_ visible: Bool) {
        if !visible && document.window.firstResponder === replaceInput.input {
            document.window.makeFirstResponder(findInput.input)
        }
        settings.showsReplacement = visible
        updateReplacementVisibility()
        if let selected { selectRow(selected, reveal: false, preview: visible && previewRequested) }
        refreshVisibleRows()
        refreshDecorations()
        updateReplaceAvailability()
        schedulePreferencesWrite()
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
        document.requestAutosave()
        present(focusing: findInput.input, animate: true)
    }

    @objc private func changeOptions(_ sender: Any?) {
        settings.options = FindOptions(caseSensitive: matchCase.state == .on, wholeWord: wholeWord.state == .on,
                                       regularExpression: regex.state == .on)
        updateSearchOptionsAppearance()
        resetMatches()
        schedulePreferencesWrite()
    }

    private func updateSearchOptionsAppearance() {
        for option in [matchCase, wholeWord, regex] {
            option.contentTintColor = option.state == .on ? .controlAccentColor : nil
        }
    }

    private func queryChanged() {
        settings.query = findInput.value
        resetMatches()
        schedulePreferencesWrite()
    }

    private func resetMatches() {
        dismissed.removeAll()
        queuedDirection = nil
        advanceFrom = nil
        selected = nil
        previewRequested = false
        requestSearch()
    }

    private func requestSearchIfNeeded() {
        if settings.visible || queuedDirection != nil {
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
        let worker = Task.detached(priority: .userInitiated) {
            FindSearch.match(query, in: snapshot, options: options)
        }
        work = worker
        activity = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, generation == searchGeneration, pending else { return }
            resultStatus.stringValue = "Searching…"
        }
        Task { [weak self] in
            let outcome = await worker.value
            guard let self, generation == searchGeneration else { return }
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
        let previous = selected.flatMap { matches.indices.contains($0) ? matches[$0].range : nil }
        baseMatches = found
        matches = found.filter { !dismissed.contains($0.range) }
        validResults = !invalid && !settings.query.isEmpty
        let target = previous.flatMap { range in matches.firstIndex { $0.range == range } }
        selected = nil
        editingResults = true
        results.reloadData()
        results.deselectAll(nil)
        editingResults = false
        resultStatus.stringValue = invalid ? "Invalid regex" : matches.isEmpty ? "No results"
            : matches.count == 1 ? "1 match" : "\(matches.count) matches"
        updateReplaceAvailability()
        if let advanceFrom {
            self.advanceFrom = nil
            if settings.visible, let next = matches.firstIndex(where: { $0.range.location >= advanceFrom }) {
                selectRow(next, reveal: true, preview: true)
            } else if settings.visible && document.window.firstResponder === results {
                document.window.makeFirstResponder(findInput.input)
            }
        } else if let queuedDirection {
            self.queuedDirection = nil
            moveResult(by: queuedDirection)
        } else if let target {
            selectRow(target, reveal: false, preview: previewRequested)
        } else {
            previewRequested = false
        }
        refreshDecorations()
        refreshVisibleRows()
    }

    private func moveResult(by direction: Int) {
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
        selectRow((base + direction + matches.count) % matches.count, reveal: true, preview: focusIsInSidebar)
    }

    private func focusFirstResult() {
        guard validResults, !matches.isEmpty else { return }
        document.window.makeFirstResponder(results)
        selectRow(0, reveal: true, preview: true)
    }

    private func selectRow(_ index: Int?, reveal: Bool, preview: Bool) {
        if let index {
            guard validResults, matches.indices.contains(index) else { return }
        }
        let previous = selected
        selected = index
        previewRequested = index != nil && preview && settings.showsReplacement && settings.visible
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
            layoutAnchor = nil
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
        let row = sender.clickedRow
        guard validResults, matches.indices.contains(row) else { return }
        layoutAnchor = nil
        selectRow(row, reveal: false, preview: false)
        let caret = NSRange(location: NSMaxRange(matches[row].range), length: 0)
        let editor = document.editor
        guard document.window.makeFirstResponder(editor) else { return }
        editor.setCaretSelections([caret])
        editor.scrollRangeToVisible(caret)
    }

    private func activateResult() {
        guard let selected, validResults else { return }
        if settings.showsReplacement {
            apply([matches[selected]], advance: true)
        } else {
            selectRow(selected, reveal: true, preview: false)
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
        guard validResults, settings.visible, settings.showsReplacement,
              document.editor.isEditable, !document.editor.hasMarkedText(),
              let first = hits.first, let last = hits.last, document.editor.string == resultSnapshot else { return }
        let source = resultSnapshot as NSString
        let edits = hits.map { FindTextEdit(range: $0.range, replacement: $0.replacement(
            using: settings.replacement, in: source, isRegex: settings.options.regularExpression
        )) }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var start = span.location
        var output = ""
        for edit in edits {
            output += source.substring(with: NSRange(location: start, length: edit.range.location - start))
            output += edit.replacement
            start = NSMaxRange(edit.range)
        }

        advanceFrom = advance ? first.range.location + edits[0].replacement.utf16.count : nil
        if output == source.substring(with: span) {
            publish(baseMatches)
            return
        }
        let oldDismissed = dismissed
        dismissed = FindTextEdit.moving(dismissed, through: edits)
        decorations.clearPreview()
        movingDismissalsForReplacement = true
        applyingEdits = true
        let changed = document.editor.replaceFoundText(in: span, with: output)
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
        let preview = previewRequested && settings.visible && settings.showsReplacement
            ? hit.map { ($0.range, $0.replacement(using: settings.replacement, in: resultSnapshot as NSString,
                                                  isRegex: settings.options.regularExpression)) }
            : nil
        decorations.update(snapshot: resultSnapshot, ranges: settings.visible && validResults ? matches.map(\.range) : [],
                           selected: hit?.range, preview: preview)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

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
        cell.configure(text: excerpt(of: range), replacementAvailable: settings.showsReplacement,
                       acceptsActions: validResults, selected: selected == row,
                       apply: { [weak self] in
                           guard let self, let match = matches.first(where: { $0.range == range }) else { return }
                           apply([match], advance: true)
                       },
                       dismiss: { [weak self] in self?.dismiss(range) })
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

    private func excerpt(of range: NSRange) -> NSAttributedString {
        let source = resultSnapshot as NSString
        var start = 0
        var end = 0
        var contentEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                            for: NSRange(location: range.location, length: 0))
        // Keep enough room for the match itself before the trailing row actions.
        let from = max(start, range.location - 9)
        let to = max(from, min(contentEnd, max(NSMaxRange(range), from + 100)))
        let excerptRange = source.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
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
