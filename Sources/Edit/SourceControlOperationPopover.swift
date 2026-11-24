import AppKit

@MainActor
final class SourceControlOperationPopover: NSObject, NSPopoverDelegate {
    typealias Direction = JJSourceControlOperations.Direction
    typealias Preview = JJSourceControlOperations.Preview

    private static let inset: CGFloat = 14
    private static let contentWidth: CGFloat = 390
    private static let effectWidth = contentWidth - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) - 2

    private weak var anchor: NSView?
    private let prepare: (Direction) async throws -> Preview
    private let apply: (Preview) async throws -> Void
    private let popover: SourceControlPopover
    private let layout = NSStackView()
    private let directionControl = NSSegmentedControl()
    private let scroll = NSScrollView()
    private let scrollDocument = SourceControlOperationDocumentView()
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 52)
    private let contents = NSStackView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let command = NSTextField(labelWithString: "")
    private let applyButton = NSButton()
    private var direction: Direction = .undo
    private var preview: Preview?
    private var request: Task<Void, Never>?
    private var applying = false
    private var diskExpanded = true
    private var diskList: NSStackView?
    private weak var filesToggle: NSButton?

    init(anchor: NSView, agentCheck: Bool, prepare: @escaping (Direction) async throws -> Preview, apply: @escaping (Preview) async throws -> Void) {
        self.anchor = anchor
        popover = SourceControlPopover(agentCheck: agentCheck)
        self.prepare = prepare
        self.apply = apply
        super.init()
        configure()
    }

    deinit { request?.cancel() }

    func show() {
        if popover.isShown { close(); return }
        guard let anchor, anchor.window != nil else { return }
        direction = .undo
        diskExpanded = true
        refresh()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    func close() {
        request?.cancel()
        request = nil
        if popover.isShown { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) {
        request?.cancel()
        request = nil
        preview = nil
    }

    func invalidate() {
        guard popover.isShown, !applying else { return }
        refresh(keepContents: true)
    }

    private func refresh(keepContents: Bool = false, note: String? = nil) {
        request?.cancel()
        preview = nil
        notice.stringValue = note ?? ""
        notice.isHidden = note == nil
        updateButtons()
        if !keepContents { showMessage("Preparing \(direction.title.lowercased())…") }
        let direction = self.direction
        request = Task { [weak self, prepare] in
            do {
                let preview = try await prepare(direction)
                guard let self, !Task.isCancelled, popover.isShown else { return }
                request = nil
                self.preview = preview
                render(preview)
                updateButtons()
            } catch {
                guard let self, !Task.isCancelled, popover.isShown else { return }
                request = nil
                showMessage(error.localizedDescription)
                updateButtons()
            }
        }
    }

    private func showMessage(_ message: String) {
        clearContents()
        addEffect(label(message, secondary: true))
        fitContent()
    }

    private func render(_ preview: Preview) {
        clearContents()
        let description = label(preview.description)
        description.font = .systemFont(ofSize: 13, weight: .semibold)
        addEffect(description)
        addEffect(label([preview.origin, preview.time, String(preview.operationID.prefix(8))]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), secondary: true))

        addSection("Working Copy After \(preview.direction.title)")
        if preview.workingCopyChangeIDBefore == preview.workingCopyChangeIDAfter {
            addEffect(label("Stays on \(preview.workingCopyAfter)"))
        } else {
            addEffect(label("From \(preview.workingCopyBefore)"))
            addEffect(label("To \(preview.workingCopyAfter)"))
        }

        addSection("Change Graph")
        for effect in preview.revisionEffects.isEmpty ? ["No graph changes"] : preview.revisionEffects {
            addEffect(label(effect))
        }
        if !preview.bookmarkEffects.isEmpty {
            addSection("Bookmarks and Tags")
            for effect in preview.bookmarkEffects { addEffect(label(effect)) }
        }

        addDivider()
        let toggle = NSButton(title: "Files on Disk · \(preview.fileEffects.count)", target: self, action: #selector(toggleFiles(_:)))
        toggle.isBordered = false
        toggle.alignment = .left
        toggle.imagePosition = .imageLeading
        toggle.font = .systemFont(ofSize: 11, weight: .semibold)
        filesToggle = toggle
        addEffect(toggle, fullWidth: false)
        let paths = NSStackView()
        paths.orientation = .vertical
        paths.alignment = .leading
        paths.spacing = 6
        if preview.fileEffects.isEmpty { paths.addArrangedSubview(label("No on-disk content changes", secondary: true)) }
        for file in preview.fileEffects {
            let path = label(file.path)
            path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            path.lineBreakMode = .byCharWrapping
            let status = label(file.label, secondary: true)
            status.lineBreakMode = .byCharWrapping
            let row = NSStackView(views: [path, status])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            paths.addArrangedSubview(row)
            for view in [path, status, row] { view.widthAnchor.constraint(equalToConstant: Self.effectWidth).isActive = true }
        }
        addEffect(paths)
        diskList = paths
        updateFilesDisclosure()
        scroll.contentView.scroll(to: .zero)
    }

    private func clearContents() {
        for child in contents.arrangedSubviews {
            contents.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        diskList = nil
        filesToggle = nil
    }

    @objc private func toggleFiles(_ sender: Any?) {
        diskExpanded.toggle()
        updateFilesDisclosure()
    }

    private func updateFilesDisclosure() {
        diskList?.isHidden = !diskExpanded
        filesToggle?.image = NSImage(systemSymbolName: diskExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        fitContent()
    }

    private func fitContent() {
        let documentHeight = max(1, ceil(contents.fittingSize.height))
        scrollDocument.setFrameSize(NSSize(width: Self.effectWidth, height: documentHeight))
        scrollHeight.constant = min(360, max(52, documentHeight + 1))
        let size = NSSize(width: Self.contentWidth + 2 * Self.inset, height: ceil(layout.fittingSize.height) + 2 * Self.inset)
        popover.contentSize = size
        if !popover.isShown { popover.native.contentViewController?.view.setFrameSize(size) }
    }

    private func updateButtons() {
        directionControl.selectedSegment = direction == .undo ? 0 : 1
        directionControl.isEnabled = !applying
        applyButton.title = "\(direction.title) Operation"
        applyButton.isEnabled = preview != nil && !applying
        applyButton.bezelColor = applyButton.isEnabled ? .controlAccentColor : nil
        command.stringValue = "jj \(direction.rawValue)"
    }

    @objc private func changeDirection(_ sender: NSSegmentedControl) {
        direction = sender.selectedSegment == 0 ? .undo : .redo
        diskExpanded = true
        refresh()
    }

    @objc private func runOperation(_ sender: Any?) {
        guard !applying, let preview else { return }
        applying = true
        updateButtons()
        Task {
            do {
                try await apply(preview)
                applying = false
                guard popover.isShown else { return }
                refresh()
            } catch {
                applying = false
                guard popover.isShown else { return }
                refresh(note: error.localizedDescription)
            }
        }
    }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.alignment = .left
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.font = .systemFont(ofSize: secondary ? 11 : 12)
        field.preferredMaxLayoutWidth = Self.effectWidth
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func addEffect(_ view: NSView, fullWidth: Bool = true) {
        contents.addArrangedSubview(view)
        if fullWidth { view.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true }
    }

    private func addSection(_ title: String) {
        addDivider()
        let heading = label(title, secondary: true)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        addEffect(heading)
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        addEffect(divider)
    }

    private func configure() {
        let wrapper = NSView()
        let title = NSTextField(labelWithString: "Repository Operations")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let dismiss = NSButton()
        dismiss.isBordered = false
        dismiss.imagePosition = .imageOnly
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Repository Operations")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        dismiss.target = self
        dismiss.action = #selector(dismissPopover)
        dismiss.toolTip = "Close Repository Operations"
        let header = NSView()
        addRow(leading: title, trailing: dismiss, to: header)
        dismiss.widthAnchor.constraint(equalToConstant: 20).isActive = true
        dismiss.heightAnchor.constraint(equalToConstant: 20).isActive = true

        directionControl.segmentCount = 2
        directionControl.setLabel("Undo", forSegment: 0)
        directionControl.setLabel("Redo", forSegment: 1)
        directionControl.trackingMode = .selectOne
        directionControl.segmentDistribution = .fillEqually
        directionControl.target = self
        directionControl.action = #selector(changeDirection(_:))
        directionControl.setAccessibilityLabel("Operation Direction")
        command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        command.textColor = .secondaryLabelColor
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(runOperation(_:))
        notice.textColor = .systemOrange
        notice.maximumNumberOfLines = 3
        notice.font = .systemFont(ofSize: 11)
        notice.preferredMaxLayoutWidth = Self.contentWidth
        notice.isHidden = true
        let footer = NSView()
        addRow(leading: command, trailing: applyButton, to: footer)
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 10
        for view in [header, directionControl, notice, scroll, footer] {
            layout.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
        wrapper.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: Self.inset),
            layout.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: Self.inset),
            scrollHeight
        ])
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 5
        scrollDocument.addSubview(contents)
        scroll.documentView = scrollDocument
        contents.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: scrollDocument.leadingAnchor),
            contents.topAnchor.constraint(equalTo: scrollDocument.topAnchor),
            contents.widthAnchor.constraint(equalToConstant: Self.effectWidth)
        ])
        let controller = NSViewController()
        controller.view = wrapper
        popover.native.behavior = .transient
        popover.native.delegate = self
        popover.native.contentViewController = controller
        updateButtons()
        fitContent()
    }

    private func addRow(leading: NSView, trailing: NSView, to row: NSView) {
        for view in [leading, trailing] {
            row.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.topAnchor.constraint(equalTo: row.topAnchor),
            trailing.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
    }

    @objc private func dismissPopover() { close() }

#if EDIT_AGENT_CHECKS
    var checkView: NSView { popover.native.contentViewController!.view }

    func viewForCheck(_ preview: Preview) -> NSView {
        direction = preview.direction
        self.preview = preview
        updateButtons()
        render(preview)
        return checkView
    }
#endif
}

@MainActor
private final class SourceControlOperationDocumentView: NSView {
    override var isFlipped: Bool { true }
}
