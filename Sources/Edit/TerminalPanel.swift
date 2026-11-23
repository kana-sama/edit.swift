import AppKit
import Darwin
import SwiftTerm

enum TerminalDock: String, Codable, Sendable {
    case below, right
}

enum TerminalSplitDirection: String, Codable, Sendable {
    case right, down
}

enum TerminalZoom {
    case increase, decrease, reset
}

@MainActor
final class TerminalPanel: NSObject {
    private enum HeaderMetrics {
        static let inset: CGFloat = 8
        static let buttonSize: CGFloat = 24
        static let minimumButtonWidth: CGFloat = 16
        static let minimumPickerWidth: CGFloat = 32
        static let spacing: CGFloat = 4
        static let pairSpacing: CGFloat = 2
        static let toolbarPadding: CGFloat = 16
    }

    let view = NSView()
    private(set) var dock: TerminalDock = .below

    private let content = TerminalSlot()
    private let header = NSView()
    private var headerConstraints: [NSLayoutConstraint] = []
    private var headerButtonWidths: [NSLayoutConstraint] = []
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var dockedPickerWidth = picker.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
    private let dockPopover = TerminalDockPopover()
    private var spaceActionButtons: [NSButton] = []
    private let directory: () -> URL
    private let onDockChange: (TerminalDock) -> Void
    private let onLastShellExit: (Bool) -> Void
    private let launchShell: Bool
    private var spaces: [TerminalSpace] = []
    private var selectedSpace: TerminalSpace?
    private var refreshSpaceNames: Task<Void, Never>?
    private var closed = false

    init(directory: @escaping () -> URL, onDockChange: @escaping (TerminalDock) -> Void,
         onLastShellExit: @escaping (Bool) -> Void,
         launchShell: Bool = true, restoredState: TerminalPanelState? = nil) {
        self.directory = directory
        self.onDockChange = onDockChange
        self.onLastShellExit = onLastShellExit
        self.launchShell = launchShell
        super.init()
        configureView()
        if let restoredState { restore(restoredState) }
    }

    func snapshot() -> TerminalPanelState {
        TerminalPanelState(
            dock: dock,
            spaces: spaces.compactMap { space in
                guard let layout = space.root.snapshot() else { return nil }
                return TerminalSpaceState(id: space.id, name: space.name, layout: layout, lastPane: space.last.id)
            },
            selectedSpace: selectedSpace?.id,
            nextSpaceNumber: spaces.count + 1
        )
    }

    private func restore(_ state: TerminalPanelState) {
        dock = state.dock
        spaces = state.spaces.compactMap { space in
            let (view, panes) = restoreLayout(space.layout)
            guard let last = panes.first(where: { $0.id == space.lastPane }) ?? panes.first else { return nil }
            return TerminalSpace(id: space.id, view: view, panes: panes, last: last)
        }
        select(spaces.first(where: { $0.id == state.selectedSpace }) ?? spaces.first)
    }

    private func restoreLayout(_ layout: TerminalLayoutState) -> (NSView, [TerminalPane]) {
        switch layout {
        case .pane(let state):
            let pane = makePane(in: state.workingDirectory, restoredState: state)
            return (pane, [pane])
        case .split(let direction, let fraction, let first, let second):
            let split = TerminalSplitView(frame: .zero, direction: direction, firstFraction: fraction)
            let (firstView, firstPanes) = restoreLayout(first)
            let (secondView, secondPanes) = restoreLayout(second)
            split.first.display(firstView)
            split.second.display(secondView)
            return (split, firstPanes + secondPanes)
        }
    }

    func prepareSpace() {
        guard !closed else { return }
        if selectedSpace == nil { addSpace() }
    }

    func focusLastTerminal() {
        prepareSpace()
        selectedSpace?.last.focus()
    }

    func containsTerminalResponder(_ responder: NSResponder?) -> Bool {
        guard let responder = responder as? NSView, let selectedSpace else { return false }
        return selectedSpace.panes.contains {
            responder === $0.terminal || responder.isDescendant(of: $0.terminal)
        }
    }

    func split(_ direction: TerminalSplitDirection) {
        guard let pane = selectedSpace?.last else { return }
        split(direction, pane: pane)
    }

    private func split(_ direction: TerminalSplitDirection, pane existing: TerminalPane) {
        guard !closed, let space = selectedSpace, space.panes.contains(where: { $0 === existing }),
              let slot = existing.superview as? TerminalSlot else { return }
        let added = makePane(in: existing.workingDirectory)
        let split = TerminalSplitView(frame: slot.bounds, direction: direction)
        slot.display(split)
        split.first.display(existing)
        split.second.display(added)
        split.adjustSubviews()
        space.panes.append(added)
        space.last = added
        added.focus()
    }

    func zoom(_ action: TerminalZoom) {
        selectedSpace?.last.zoom(action)
    }

    func toggleContentWidth() {
        selectedSpace?.last.toggleContentWidth()
    }

    func clear() {
        selectedSpace?.last.clear()
    }

    func setVisible(_ visible: Bool) {
        guard visible else {
            dockPopover.close(restoreFocus: false)
            refreshSpaceNames?.cancel()
            refreshSpaceNames = nil
            return
        }
        guard refreshSpaceNames == nil, !closed else { return }
        refreshSpaceNames = Task { @MainActor [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.updateForegroundProcesses()
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        setVisible(false)
        spaces.forEach { $0.panes.forEach { $0.close() } }
        spaces.removeAll()
        select(nil)
    }

    private func configureView() {
        view.identifier = .init("Edit.Terminal.Panel")
        view.setAccessibilityLabel("Terminal")
        view.clipsToBounds = true
        picker.identifier = .init("Edit.Terminal.Spaces")
        picker.setAccessibilityLabel("Terminal Space")
        picker.menu?.autoenablesItems = false
        picker.target = self
        picker.action = #selector(selectSpace(_:))
        picker.isBordered = false
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        picker.cell?.lineBreakMode = .byTruncatingTail
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let add = headerButton(symbol: "plus", label: "New Space", action: #selector(newSpace(_:)))
        add.identifier = .init("Edit.Terminal.NewSpace")
        let delete = headerButton(symbol: "minus", label: "Delete Space", action: #selector(confirmDeleteSpace(_:)))
        delete.identifier = .init("Edit.Terminal.DeleteSpace")
        let splitRight = headerButton(symbol: "rectangle.split.2x1", label: "Split Terminal Right",
                                      action: #selector(Self.splitRight(_:)))
        splitRight.identifier = .init("Edit.Terminal.SplitRight")
        let splitDown = headerButton(symbol: "rectangle.split.1x2", label: "Split Terminal Down",
                                     action: #selector(Self.splitDown(_:)))
        splitDown.identifier = .init("Edit.Terminal.SplitDown")
        spaceActionButtons = [delete, splitRight, splitDown]
        let options = headerButton(symbol: "ellipsis", label: "Terminal Dock Position", action: #selector(showOptions(_:)))
        options.identifier = .init("Edit.Terminal.Options")
        header.identifier = .init("Edit.Terminal.Header")
        header.translatesAutoresizingMaskIntoConstraints = false
        content.identifier = .init("Edit.Terminal.Content")
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        for subview in [picker, add, delete, splitRight, splitDown, options] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: HeaderMetrics.inset),
            picker.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            add.leadingAnchor.constraint(equalTo: picker.trailingAnchor, constant: HeaderMetrics.spacing),
            add.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            delete.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: HeaderMetrics.pairSpacing),
            delete.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitRight.leadingAnchor.constraint(equalTo: delete.trailingAnchor, constant: HeaderMetrics.spacing),
            splitRight.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitDown.leadingAnchor.constraint(equalTo: splitRight.trailingAnchor, constant: HeaderMetrics.pairSpacing),
            splitDown.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            splitDown.trailingAnchor.constraint(lessThanOrEqualTo: options.leadingAnchor, constant: -HeaderMetrics.spacing),
            options.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -HeaderMetrics.inset),
            options.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        placeHeader(in: nil)
        updatePicker()
    }

    func fitDockedHeader(to sidebarWidth: CGFloat) {
        // Fit the buttons and popup chevron within the sidebar's native toolbar slot.
        let available = sidebarWidth - 2 * HeaderMetrics.inset - 3 * HeaderMetrics.spacing
            - 2 * HeaderMetrics.pairSpacing - HeaderMetrics.toolbarPadding
        let count = CGFloat(headerButtonWidths.count)
        let buttonWidth = min(HeaderMetrics.buttonSize, max(HeaderMetrics.minimumButtonWidth,
            floor((available - HeaderMetrics.minimumPickerWidth) / count)))
        for width in headerButtonWidths where width.constant != buttonWidth { width.constant = buttonWidth }
        let pickerWidth = max(0, available - count * buttonWidth)
        if dockedPickerWidth.constant != pickerWidth { dockedPickerWidth.constant = pickerWidth }
    }

    func placeHeader(in titlebar: NSView?, contentTop: NSLayoutYAxisAnchor? = nil) {
        let host = titlebar ?? view
        guard header.superview !== host else { return }
        dockPopover.close()
        NSLayoutConstraint.deactivate(headerConstraints)
        header.removeFromSuperview()
        host.addSubview(header)
        let safeArea = view.safeAreaLayoutGuide
        if let titlebar {
            headerConstraints = [
                header.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
                header.topAnchor.constraint(equalTo: titlebar.topAnchor),
                header.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),
                dockedPickerWidth,
                content.topAnchor.constraint(equalTo: contentTop ?? safeArea.topAnchor),
            ]
        } else {
            for width in headerButtonWidths { width.constant = HeaderMetrics.buttonSize }
            headerConstraints = [
                header.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                header.topAnchor.constraint(equalTo: safeArea.topAnchor),
                header.heightAnchor.constraint(equalToConstant: 34),
                content.topAnchor.constraint(equalTo: header.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(headerConstraints)
    }

    private func headerButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        let width = button.widthAnchor.constraint(equalToConstant: HeaderMetrics.buttonSize)
        headerButtonWidths.append(width)
        NSLayoutConstraint.activate([width, button.heightAnchor.constraint(equalToConstant: HeaderMetrics.buttonSize)])
        return button
    }

    private func makePane(in directory: URL, restoredState: TerminalPaneState? = nil) -> TerminalPane {
        let pane = TerminalPane(directory: directory, launchShell: launchShell, restoredState: restoredState)
        pane.onClose = { [weak self] pane in self?.removePane(pane) }
        pane.onSplit = { [weak self] pane, direction in self?.split(direction, pane: pane) }
        pane.onTitleChange = { [weak self] in self?.updatePickerNames() }
        pane.terminal.onFocusChange = { [weak self, weak pane] focused in
            guard let pane else { return }
            pane.showsFocusOutline = focused
            guard focused, let space = self?.selectedSpace, space.panes.contains(where: { $0 === pane }) else { return }
            space.last = pane
        }
        return pane
    }

    private func removePane(_ pane: TerminalPane) {
        guard !closed, let spaceIndex = spaces.firstIndex(where: { $0.panes.contains { $0 === pane } }),
              let slot = pane.superview as? TerminalSlot else { return }
        let space = spaces[spaceIndex]
        guard let paneIndex = space.panes.firstIndex(where: { $0 === pane }) else { return }
        let window = view.window
        let responder = window?.firstResponder as? NSView
        let paneHadFocus = responder?.isDescendant(of: pane) == true

        pane.close()
        slot.removePane()
        space.panes.remove(at: paneIndex)
        if !space.panes.isEmpty {
            if space.last === pane { space.last = space.panes[min(paneIndex, space.panes.count - 1)] }
            if paneHadFocus {
                space.last.focus()
            } else if let window, let responder, responder.window === window, window.firstResponder !== responder {
                // Collapsing a split can briefly detach the surviving pane.
                window.makeFirstResponder(responder)
            }
            return
        }

        spaces.remove(at: spaceIndex)
        if space === selectedSpace {
            select(spaces.isEmpty ? nil : spaces[min(spaceIndex, spaces.count - 1)])
            if paneHadFocus { selectedSpace?.last.focus() }
        } else {
            updatePicker()
        }
        if spaces.isEmpty { onLastShellExit(responder?.isDescendant(of: view) == true || paneHadFocus) }
    }

    private func select(_ space: TerminalSpace?) {
        selectedSpace = space
        content.display(space?.root)
        updatePicker()
    }

    private func updatePicker() {
        picker.removeAllItems()
        picker.isEnabled = !spaces.isEmpty
        for button in spaceActionButtons { button.isEnabled = selectedSpace != nil }
        if spaces.isEmpty {
            picker.addItem(withTitle: "Spaces")
        } else {
            // Insert by index so different spaces can have identical titles.
            for space in spaces {
                picker.menu?.addItem(NSMenuItem(title: space.name, action: nil, keyEquivalent: ""))
            }
            if let index = spaces.firstIndex(where: { $0 === selectedSpace }) { picker.selectItem(at: index) }
        }
    }

    private func updatePickerNames() {
        for (space, item) in zip(spaces, picker.itemArray) where item.title != space.name {
            item.title = space.name
        }
    }

    private func updateForegroundProcesses() async {
        let panes = spaces.flatMap(\.panes)
        let requests = panes.compactMap { pane -> (UUID, pid_t, String?)? in
            guard let process = pane.terminal.process, process.running else { return nil }
            let pid = process.shellPid
            guard pid > 0 else { return nil }
            return (pane.id, pid, pane.shellName)
        }
        guard !requests.isEmpty else { return }
        let results = await Task.detached(priority: .utility) {
            requests.compactMap { id, pid, shellName in
                TerminalForegroundProcess.inspect(shellPID: pid, shellName: shellName).map { (id, pid, $0) }
            }
        }.value
        guard !Task.isCancelled else { return }
        for (id, pid, result) in results {
            guard let pane = panes.first(where: { $0.id == id }), let process = pane.terminal.process,
                  process.running, process.shellPid == pid else { continue }
            pane.updateForegroundProcess(result)
        }
    }

    private func addSpace() {
        let space = TerminalSpace(pane: makePane(in: directory()))
        spaces.append(space)
        select(space)
    }

    @objc private func newSpace(_ sender: NSButton) {
        addSpace()
        selectedSpace?.last.focus()
    }

    @objc private func splitRight(_ sender: NSButton) {
        split(.right)
    }

    @objc private func splitDown(_ sender: NSButton) {
        split(.down)
    }

    @objc private func selectSpace(_ sender: NSPopUpButton) {
        guard spaces.indices.contains(sender.indexOfSelectedItem) else { return }
        select(spaces[sender.indexOfSelectedItem])
        selectedSpace?.last.focus()
    }

    @objc private func showOptions(_ sender: NSButton) {
        if dockPopover.isShown {
            dockPopover.close()
        } else if let window = view.window {
            dockPopover.show(makeDockPicker(), from: sender, in: window, preferAbove: dock == .below)
        }
    }

    func makeDockPicker() -> TerminalDockPicker {
        TerminalDockPicker(selected: dock) { [weak self] dock in
            guard let self else { return }
            dockPopover.close()
            if self.dock != dock {
                self.dock = dock
                onDockChange(dock)
            }
            selectedSpace?.last.focus()
        }
    }

    @objc private func confirmDeleteSpace(_ sender: NSButton) {
        guard let space = selectedSpace, let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.name)”?"
        alert.informativeText = space.panes.count == 1
            ? "The terminal session in this space will close."
            : "All \(space.panes.count) terminal sessions in this space will close."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self, weak space] response in
            guard let self, let space, !self.closed else { return }
            if response == .alertSecondButtonReturn { self.delete(space) }
            self.selectedSpace?.last.focus()
        }
    }

    private func delete(_ space: TerminalSpace) {
        guard let index = spaces.firstIndex(where: { $0 === space }) else { return }
        space.panes.forEach { $0.close() }
        spaces.remove(at: index)
        select(spaces.isEmpty ? nil : spaces[min(index, spaces.count - 1)])
    }
}

@MainActor
private final class TerminalSpace {
    let id: UUID
    let root = TerminalSlot()
    var panes: [TerminalPane]
    var last: TerminalPane

    var name: String {
        var seen: Set<String> = []
        return panes.map(\.title).filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    convenience init(pane: TerminalPane) {
        self.init(id: UUID(), view: pane, panes: [pane], last: pane)
    }

    init(id: UUID, view: NSView, panes: [TerminalPane], last: TerminalPane) {
        self.id = id
        self.panes = panes
        self.last = last
        root.display(view)
    }
}

private struct TerminalPaneEdges: OptionSet {
    let rawValue: UInt8

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)
    static let all: Self = [.left, .right, .bottom, .top]
    static let borderWidth: CGFloat = 1
}

@MainActor
private final class TerminalSlot: NSView {
    private var content: NSView?
    var outerEdges: TerminalPaneEdges = .all {
        didSet { if outerEdges != oldValue { applyOuterEdges() } }
    }

    func display(_ view: NSView?) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        content = view
        guard let view else { return }
        applyOuterEdges()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func applyOuterEdges() {
        (content as? TerminalPane)?.outerEdges = outerEdges
        (content as? TerminalSplitView)?.setOuterEdges(outerEdges)
    }

    func snapshot() -> TerminalLayoutState? {
        if let pane = content as? TerminalPane { return .pane(pane.snapshot()) }
        return (content as? TerminalSplitView)?.snapshot()
    }

    func removePane() {
        display(nil)
        guard let split = superview as? TerminalSplitView, let parent = split.superview as? TerminalSlot else { return }
        let sibling = self === split.first ? split.second : split.first
        let remaining = sibling.content
        sibling.display(nil)
        parent.display(remaining)
    }
}

@MainActor
private final class TerminalSplitView: NSSplitView, NSSplitViewDelegate {
    let first = TerminalSlot()
    let second = TerminalSlot()
    private let direction: TerminalSplitDirection
    private var firstFraction: CGFloat

    init(frame: NSRect, direction: TerminalSplitDirection, firstFraction: CGFloat = 0.5) {
        self.direction = direction
        self.firstFraction = firstFraction.isFinite ? min(1, max(0, firstFraction)) : 0.5
        super.init(frame: frame)
        identifier = .init("Edit.Terminal.Split")
        isVertical = direction == .right
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(first)
        addArrangedSubview(second)
    }

    required init?(coder: NSCoder) { nil }

    override var dividerThickness: CGFloat { TerminalPaneEdges.borderWidth }

    func setOuterEdges(_ edges: TerminalPaneEdges) {
        let firstSharedEdge: TerminalPaneEdges = isVertical ? .right : (isFlipped ? .bottom : .top)
        let secondSharedEdge: TerminalPaneEdges = isVertical ? .left : (isFlipped ? .top : .bottom)
        first.outerEdges = edges.subtracting(firstSharedEdge)
        second.outerEdges = edges.subtracting(secondSharedEdge)
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(rect)

        guard let terminal = window?.firstResponder as? TerminalSessionView,
              let pane = terminal.enclosingScrollView?.superview as? TerminalPane,
              pane.isDescendant(of: self) else { return }
        let paneBounds = convert(pane.bounds, from: pane)
        let adjacent: Bool
        let strip: NSRect
        if isVertical {
            adjacent = abs(paneBounds.maxX - rect.minX) < 0.5 || abs(paneBounds.minX - rect.maxX) < 0.5
            strip = NSRect(x: rect.minX, y: paneBounds.minY, width: rect.width, height: paneBounds.height)
        } else {
            adjacent = abs(paneBounds.maxY - rect.minY) < 0.5 || abs(paneBounds.minY - rect.maxY) < 0.5
            strip = NSRect(x: paneBounds.minX, y: rect.minY, width: paneBounds.width, height: rect.height)
        }
        guard adjacent else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath.fill(rect.intersection(strip))
    }

    private var availableLength: CGFloat {
        max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
    }

    func snapshot() -> TerminalLayoutState? {
        guard let first = first.snapshot(), let second = second.snapshot() else { return nil }
        return .split(direction: direction, firstFraction: firstFraction, first: first, second: second)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard availableLength > 0, let first = arrangedSubviews.first else { return }
        let length = isVertical ? first.frame.width : first.frame.height
        firstFraction = length / availableLength
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard arrangedSubviews.count == 2 else { return }
        let available = availableLength
        let minimum = min(72, available / 2)
        let first = min(max((available * firstFraction).rounded(), minimum), available - minimum)
        let remaining = available - first
        if isVertical {
            let gap = min(bounds.width, dividerThickness)
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
            arrangedSubviews[1].frame = NSRect(x: first + gap, y: 0, width: remaining, height: bounds.height)
        } else {
            let gap = min(bounds.height, dividerThickness)
            arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
            arrangedSubviews[1].frame = NSRect(x: 0, y: first + gap, width: bounds.width, height: remaining)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, min(72, availableLength / 2))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, availableLength - min(72, availableLength / 2))
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: isVertical ? -4 : 0, dy: isVertical ? 0 : -4)
    }
}

@MainActor
private final class TerminalSessionView: LocalProcessTerminalView {
    var onFocusChange: ((Bool) -> Void)?
    weak var pane: TerminalPane?

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            onFocusChange?(newValue)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let pane else { return super.menu(for: event) }
        window?.makeFirstResponder(self)
        return pane.makeContextMenu()
    }
}

@MainActor
final class TerminalScrollView: NSScrollView {
    static func routeWheel(_ event: NSEvent, in window: NSWindow, at location: NSPoint) -> Bool {
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        guard dx > dy || (dx == 0 && dy == 0), let content = window.contentView else { return false }
        let point = content.superview?.convert(location, from: nil) ?? location
        var hit = content.hitTest(point)
        while let view = hit {
            if let scrollView = view as? TerminalScrollView, scrollView.hasHorizontalScroller {
                // SwiftTerm handles vertical wheel events inside its own viewport.
                scrollView.scrollWheel(with: event)
                return true
            }
            hit = view.superview
        }
        return false
    }

    func layoutViewport(_ viewport: NSRect, minimumColumns: Int?) {
        if frame != viewport { frame = viewport }
        guard viewport.width > 0, viewport.height > 0, let terminal = documentView as? TerminalView else { return }

        let viewportWidth = contentSize.width
        let gridWidth: CGFloat
        if let minimumColumns, let currentColumns = terminal.terminalInputStateSnapshot()?.dimensions.cols, currentColumns > 0 {
            // SwiftTerm's overlay scroller reserves no width. Its optimal frame is the point width of its grid.
            let columnWidth = terminal.getOptimalFrameSize().width / CGFloat(currentColumns)
            let scale = window?.backingScaleFactor ?? 1
            gridWidth = ceil(CGFloat(minimumColumns) * columnWidth * scale) / scale
        } else {
            gridWidth = 0
        }

        let shouldScroll = gridWidth > viewportWidth
        if hasHorizontalScroller != shouldScroll { hasHorizontalScroller = shouldScroll }
        let size = NSSize(width: max(viewportWidth, gridWidth), height: contentSize.height)
        if terminal.frame.size != size {
            let offset = contentView.bounds.minX
            terminal.setFrameSize(size)
            scrollHorizontally(to: offset)
        }
    }

    func scrollHorizontally(to offset: CGFloat) {
        let clip = contentView
        let end = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        clip.scroll(to: NSPoint(x: offset.isFinite ? min(end, max(0, offset)) : 0, y: 0))
        reflectScrolledClipView(clip)
    }
}

@MainActor
private final class TerminalPaneBorder: NSView {
    weak var pane: TerminalPane?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        pane?.drawOutline(in: bounds)
    }
}

@MainActor
private final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    private static let defaultFontSize: CGFloat = 12
    private static let maximumSavedScrollbackRows = 2_000
    private static let defaultFixedColumns = 240
    private static let maximumFixedColumns = 1_024
    let id: UUID
    let terminal = TerminalSessionView(frame: .zero)
    var onClose: ((TerminalPane) -> Void)?
    var onSplit: ((TerminalPane, TerminalSplitDirection) -> Void)?
    var onTitleChange: (() -> Void)?
    var outerEdges: TerminalPaneEdges = .all {
        didSet { if outerEdges != oldValue { border.needsDisplay = true } }
    }
    var showsFocusOutline = false {
        didSet {
            guard showsFocusOutline != oldValue else { return }
            border.needsDisplay = true
            var container = superview
            while let view = container {
                (view as? TerminalSplitView)?.needsDisplay = true
                container = view.superview
            }
        }
    }
    private(set) var workingDirectory: URL {
        didSet { if workingDirectory != oldValue { onTitleChange?() } }
    }
    private(set) var shellName: String?
    private var foregroundCommand: String? {
        didSet { if foregroundCommand != oldValue { onTitleChange?() } }
    }
    var title: String {
        if let foregroundCommand { return foregroundCommand }
        let folder = workingDirectory.lastPathComponent
        return folder.isEmpty ? workingDirectory.path : folder
    }
    var wrapsLines: Bool { fixedColumns == nil }

    private let launchShell: Bool
    private let scrollView = TerminalScrollView()
    private let stoppedActions = NSStackView()
    private let border = TerminalPaneBorder()
    private var fixedColumns: Int?
    private var pendingHorizontalOffset: CGFloat?
    private var running = false
    private var closed = false
    private var pendingHistory: (transcript: TerminalTranscript, scrollbackOffset: Int)?

    init(directory: URL, launchShell: Bool, restoredState: TerminalPaneState?) {
        id = restoredState?.id ?? UUID()
        workingDirectory = directory
        foregroundCommand = restoredState?.foregroundCommand
        self.launchShell = launchShell
        if let restoredState, !restoredState.wrapsLines {
            fixedColumns = min(Self.maximumFixedColumns, max(1, restoredState.fixedColumns ?? Self.defaultFixedColumns))
            pendingHorizontalOffset = restoredState.horizontalOffset
        }
        pendingHistory = restoredState.map {
            (TerminalTranscript(text: $0.transcript, styles: $0.transcriptStyles ?? []), $0.scrollbackOffset)
        }
        super.init(frame: .zero)
        identifier = .init("Edit.Terminal.Pane")
        clipsToBounds = true
        terminal.pane = self
        terminal.processDelegate = self
        terminal.configureNativeColors()
        terminal.backgroundOpacity = 0
        terminal.scrollerStyle = .overlay
        let pointSize = restoredState?.pointSize ?? Self.defaultFontSize
        setFontSize(pointSize.isFinite ? min(72, max(6, pointSize)) : Self.defaultFontSize)
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = terminal
        addSubview(scrollView)

        let restartButton = NSButton(title: "Restart Shell", target: self, action: #selector(restart(_:)))
        restartButton.identifier = .init("Edit.Terminal.RestartShell")
        restartButton.controlSize = .small
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeStoppedPane(_:)))
        closeButton.identifier = .init("Edit.Terminal.CloseShell")
        closeButton.controlSize = .small
        stoppedActions.orientation = .horizontal
        stoppedActions.alignment = .centerY
        stoppedActions.spacing = 6
        stoppedActions.addArrangedSubview(restartButton)
        stoppedActions.addArrangedSubview(closeButton)
        // Reopening the saved history leaves the shell stopped until explicitly restarted.
        stoppedActions.isHidden = restoredState == nil
        stoppedActions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stoppedActions)
        NSLayoutConstraint.activate([
            stoppedActions.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stoppedActions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stoppedActions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        // SwiftTerm clears its viewport while drawing. Keep the inward curves above it.
        border.pane = self
        border.frame = bounds
        border.autoresizingMask = [.width, .height]
        addSubview(border)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        border.needsDisplay = true
    }

    override var cornerConfiguration: NSViewCornerConfiguration? {
        .corners(topLeftRadius: .fixed(0), topRightRadius: .fixed(0),
                 bottomLeftRadius: .containerConcentric, bottomRightRadius: .containerConcentric)
    }

    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        border.needsDisplay = true
    }

    fileprivate func drawOutline(in bounds: NSRect) {
        let width = TerminalPaneEdges.borderWidth
        let corners = bottomCornerRadii()
        let outline = NSBezierPath()
        if outerEdges.contains(.left) {
            outline.appendRect(NSRect(x: bounds.minX, y: bounds.minY + corners.left,
                                      width: width, height: bounds.height - corners.left))
        }
        if outerEdges.contains(.right) {
            outline.appendRect(NSRect(x: bounds.maxX - width, y: bounds.minY + corners.right,
                                      width: width, height: bounds.height - corners.right))
        }
        if outerEdges.contains(.bottom) {
            outline.appendRect(NSRect(x: bounds.minX + corners.left, y: bounds.minY,
                                      width: bounds.width - corners.left - corners.right, height: width))
        }
        if outerEdges.contains(.top) {
            outline.appendRect(NSRect(x: bounds.minX, y: bounds.maxY - width, width: bounds.width, height: width))
        }
        let color = showsFocusOutline ? NSColor.controlAccentColor : NSColor.separatorColor
        color.setFill()
        outline.fill()

        let arcs = NSBezierPath()
        if corners.left > 0 {
            let center = NSPoint(x: bounds.minX + corners.left, y: bounds.minY + corners.left)
            arcs.move(to: NSPoint(x: bounds.minX + width / 2, y: center.y))
            arcs.appendArc(withCenter: center, radius: corners.left - width / 2,
                           startAngle: 180, endAngle: 270)
        }
        if corners.right > 0 {
            let center = NSPoint(x: bounds.maxX - corners.right, y: bounds.minY + corners.right)
            arcs.move(to: NSPoint(x: center.x, y: bounds.minY + width / 2))
            arcs.appendArc(withCenter: center, radius: corners.right - width / 2,
                           startAngle: 270, endAngle: 360)
        }
        arcs.lineWidth = width
        color.setStroke()
        arcs.stroke()
    }

    private func bottomCornerRadii() -> (left: CGFloat, right: CGFloat) {
        guard outerEdges.contains(.bottom), let window, !window.styleMask.contains(.fullScreen),
              let content = window.contentView, let radii = effectiveCornerRadii else { return (0, 0) }

        let paneFrame = convert(bounds, to: nil)
        let contentFrame = content.convert(content.bounds, to: nil)
        guard abs(paneFrame.minY - contentFrame.minY) < 0.5 else { return (0, 0) }

        let limit = min(bounds.width / 2, bounds.height)
        let minimum = TerminalPaneEdges.borderWidth
        let left = outerEdges.contains(.left) && abs(paneFrame.minX - contentFrame.minX) < 0.5
            ? min(radii.bottomLeft, limit) : 0
        let right = outerEdges.contains(.right) && abs(paneFrame.maxX - contentFrame.maxX) < 0.5
            ? min(radii.bottomRight, limit) : 0
        return (left >= minimum ? left : 0, right >= minimum ? right : 0)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        layoutTerminal()
        restoreTranscriptIfReady()
        if !running, stoppedActions.isHidden { startShell() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutTerminal()
        restoreTranscriptIfReady()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutTerminal()
    }

    private func layoutTerminal() {
        let inset = TerminalPaneEdges.borderWidth
        let viewport = NSRect(x: bounds.minX + inset, y: bounds.minY + inset,
                              width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - 2 * inset))
        scrollView.layoutViewport(viewport, minimumColumns: fixedColumns)
    }

    func toggleContentWidth(forNewOutput: Bool = false) {
        if fixedColumns != nil {
            fixedColumns = nil
        } else {
            guard let content = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 128)) else { return }
            var length = 0
            var longest = 0
            for row in content.rows {
                if !row.isWrapped { length = 0 }
                if let end = row.cells.lastIndex(where: { !$0.isBlank }) {
                    length += end + max(1, row.cells[end].width)
                }
                longest = max(longest, length)
            }
            let columns = min(Self.maximumFixedColumns, max(forNewOutput ? Self.defaultFixedColumns : 0, longest))
            guard forNewOutput || columns > content.dimensions.cols else { return }
            fixedColumns = min(Self.maximumFixedColumns, max(content.dimensions.cols, columns))
        }
        layoutTerminal()
        scrollView.scrollHorizontally(to: 0)
    }

    func snapshot() -> TerminalPaneState {
        let history = pendingHistory ?? currentHistory()
        return TerminalPaneState(id: id, workingDirectory: workingDirectory, foregroundCommand: foregroundCommand,
                                 pointSize: terminal.font.pointSize,
                                 wrapsLines: wrapsLines,
                                 transcript: history.transcript.text,
                                 transcriptStyles: history.transcript.styles.isEmpty ? nil : history.transcript.styles,
                                 scrollbackOffset: history.scrollbackOffset, fixedColumns: fixedColumns,
                                 horizontalOffset: fixedColumns.map { _ in
                                     pendingHorizontalOffset ?? scrollView.contentView.bounds.minX
                                 })
    }

    private func currentHistory() -> (transcript: TerminalTranscript, scrollbackOffset: Int) {
        guard let normal = terminal.terminalContentSnapshot(
            region: .history(maximumScrollbackRows: Self.maximumSavedScrollbackRows), buffer: .normal
        ) else { return (TerminalTranscript(text: ""), 0) }
        var snapshots = [normal]
        var scrollbackOffset = 0
        if normal.inputState.isAlternateBuffer,
           let screen = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0), buffer: .alt) {
            snapshots.append(screen)
        } else {
            let viewport = terminal.terminalContentSnapshot(region: .viewport, buffer: .normal)
            let viewedRow = max(normal.capturedRange.lowerBound, viewport?.capturedRange.lowerBound ?? normal.liveTopRow)
            scrollbackOffset = max(0, normal.liveTopRow - viewedRow)
        }
        let transcript = TerminalTranscript(snapshots: snapshots, useBrightColors: terminal.useBrightColors,
                                            collapseBrightColorsToBase: terminal.collapseBrightColorsToBase)
        return (transcript, scrollbackOffset)
    }

    private func restoreTranscriptIfReady() {
        guard window != nil, terminal.bounds.width > 0, terminal.bounds.height > 0, let pendingHistory else { return }
        self.pendingHistory = nil
        let transcript = pendingHistory.transcript.replayText
        if !transcript.isEmpty {
            // A narrower restored pane can reflow the saved text into more physical rows.
            terminal.changeScrollback(Self.maximumSavedScrollbackRows)
            terminal.feed(text: "\u{1B}[?7h" + transcript + "\r\n")
            terminal.scrollTo(row: Int.max, notifyAccessibility: false)
            terminal.scrollUp(lines: min(Self.maximumSavedScrollbackRows, max(0, pendingHistory.scrollbackOffset)))
        }
        if let pendingHorizontalOffset {
            self.pendingHorizontalOffset = nil
            scrollView.scrollHorizontally(to: pendingHorizontalOffset)
        }
    }

    func focus() {
        window?.makeFirstResponder(terminal)
    }

    func updateForegroundProcess(_ result: TerminalForegroundProcess) {
        guard !closed else { return }
        if let directory = result.workingDirectory { workingDirectory = directory }
        foregroundCommand = result.command
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(TerminalSessionView.copy(_:)), keyEquivalent: "c")
        copy.target = terminal
        copy.isEnabled = terminal.selectionActive
        let paste = NSMenuItem(title: "Paste", action: #selector(TerminalSessionView.paste(_:)), keyEquivalent: "v")
        paste.target = terminal
        paste.isEnabled = terminal.process.running && NSPasteboard.general.availableType(from: [.string]) != nil
        let splitRight = NSMenuItem(title: "Split Terminal Right", action: #selector(splitFromMenu(_:)), keyEquivalent: "")
        splitRight.target = self
        splitRight.representedObject = TerminalSplitDirection.right
        let splitDown = NSMenuItem(title: "Split Terminal Down", action: #selector(splitFromMenu(_:)), keyEquivalent: "")
        splitDown.target = self
        splitDown.representedObject = TerminalSplitDirection.down
        let wrap = NSMenuItem(title: "Wrap Lines", action: #selector(toggleWrapFromMenu(_:)), keyEquivalent: "")
        wrap.target = self
        wrap.state = wrapsLines ? .on : .off
        let clear = NSMenuItem(title: "Clear Terminal", action: #selector(clearFromMenu(_:)), keyEquivalent: "k")
        clear.target = self
        let kill = NSMenuItem(title: "Kill Terminal", action: #selector(killFromMenu(_:)), keyEquivalent: "")
        kill.target = self
        for item in [copy, paste, .separator(), splitRight, splitDown, .separator(), wrap, clear, .separator(), kill] {
            menu.addItem(item)
        }
        return menu
    }

    @objc private func splitFromMenu(_ sender: NSMenuItem) {
        guard let direction = sender.representedObject as? TerminalSplitDirection else { return }
        onSplit?(self, direction)
    }

    @objc private func toggleWrapFromMenu(_ sender: NSMenuItem) {
        toggleContentWidth(forNewOutput: true)
    }

    @objc private func clearFromMenu(_ sender: NSMenuItem) {
        clear()
    }

    @objc private func killFromMenu(_ sender: NSMenuItem) {
        // SwiftTerm's reaper escalates securely when releasing the closed pane's process.
        terminal.process?.killEscalationDelay = 0
        onClose?(self)
    }

    func clear() {
        pendingHistory = nil
        pendingHorizontalOffset = nil
        terminal.selectNone()
        let cursor = terminal.terminalContentSnapshot(region: .rows(0..<0))
        if terminal.process.running, let cursor, cursor.bufferKind == .normal {
            // Move the cursor's line to the top without re-encoding its cells or sending input to the shell.
            let row = max(0, min(cursor.dimensions.rows - 1, cursor.cursorRow - cursor.liveTopRow))
            let up = row > 0 ? "\u{1B}[\(row)S" : ""
            let below = cursor.dimensions.rows > 1 ? "\u{1B}[2;1H\u{1B}[J" : ""
            terminal.feed(text: up + below + "\u{1B}[1;\(cursor.cursorColumn + 1)H\u{1B}[3J")
        } else if cursor?.bufferKind == .alt {
            terminal.feed(text: "\u{1B}[2J")
        } else {
            terminal.feed(text: "\u{1B}[2J\u{1B}[3J\u{1B}[H")
        }
        terminal.scrollTo(row: Int.max, notifyAccessibility: false)
        scrollView.scrollHorizontally(to: 0)
    }

    func zoom(_ action: TerminalZoom) {
        let size = terminal.font.pointSize
        switch action {
        case .increase: setFontSize(min(72, size + 1))
        case .decrease: setFontSize(max(6, size - 1))
        case .reset: setFontSize(Self.defaultFontSize)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        terminal.processDelegate = nil
        terminal.terminate()
        terminal.updateUiClosed()
    }

    private func setFontSize(_ size: CGFloat) {
        terminal.font = NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        layoutTerminal()
    }

    private func startShell() {
        guard launchShell, !closed else { return }
        let fileManager = FileManager.default
        let configuredShell = getpwuid(getuid()).flatMap { entry -> String? in
            guard let path = entry.pointee.pw_shell else { return nil }
            return String(cString: path)
        }
        let shell = configuredShell ?? "/bin/zsh"
        let executable = fileManager.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
        shellName = URL(fileURLWithPath: executable).lastPathComponent
        foregroundCommand = nil
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            workingDirectory = fileManager.homeDirectoryForCurrentUser
        }
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        let environment = inheritedEnvironment.merging([
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Edit",
            "SHELL": executable,
            "PWD": workingDirectory.path,
            "LANG": inheritedEnvironment["LANG"] ?? "en_US.UTF-8",
        ]) { _, value in value }
        running = true
        stoppedActions.isHidden = true
        terminal.startProcess(executable: executable, environment: environment.map { "\($0.key)=\($0.value)" },
                              execName: shellName.map { "-" + $0 },
                              currentDirectory: workingDirectory.path)
    }

    @objc private func restart(_ sender: NSButton) {
        guard !running else { return }
        restoreTranscriptIfReady()
        startShell()
        focus()
    }

    @objc private func closeStoppedPane(_ sender: NSButton) {
        guard !running, !closed else { return }
        onClose?(self)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if directory.hasPrefix("/") {
            workingDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            return
        }
        guard let url = URL(string: directory), url.isFileURL, url.path.hasPrefix("/") else { return }
        let host = url.host()
        let localHost = ProcessInfo.processInfo.hostName
        guard host == nil || host == "" || host == "localhost" || host == localHost else { return }
        workingDirectory = url
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !closed else { return }
        onClose?(self)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        running = false
        stoppedActions.isHidden = false
    }
}
