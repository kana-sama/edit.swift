import AppKit

@MainActor
final class SourceControlOperationPopover: NSObject, NSPopoverDelegate {
    typealias Direction = JJSourceControlOperations.Direction
    typealias Preview = JJSourceControlOperations.Preview

    private weak var anchor: NSView?
    private let prepare: (Direction) async throws -> Preview
    private let apply: (Preview) async throws -> Bool
    private let popover = NSPopover()
    private let directionControl = NSSegmentedControl()
    private let scroll = NSScrollView()
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

    init(anchor: NSView, prepare: @escaping (Direction) async throws -> Preview, apply: @escaping (Preview) async throws -> Bool) {
        self.anchor = anchor
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
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        refresh()
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
        contents.addArrangedSubview(label(message, secondary: true))
        resize(to: 190)
    }

    private func render(_ preview: Preview) {
        clearContents()
        let description = label(preview.description)
        description.font = .systemFont(ofSize: 13, weight: .semibold)
        contents.addArrangedSubview(description)
        contents.addArrangedSubview(label([preview.origin, preview.time, String(preview.operationID.prefix(8))]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), secondary: true))

        addDivider()
        contents.addArrangedSubview(label("Working Copy After \(preview.direction.title)", secondary: true))
        if preview.workingCopyChangeIDBefore == preview.workingCopyChangeIDAfter {
            contents.addArrangedSubview(label("Stays on \(preview.workingCopyAfter)"))
        } else {
            contents.addArrangedSubview(label("From \(preview.workingCopyBefore)"))
            contents.addArrangedSubview(label("To \(preview.workingCopyAfter)"))
        }

        addDivider()
        contents.addArrangedSubview(label("Change Graph", secondary: true))
        for effect in preview.revisionEffects.isEmpty ? ["No graph changes"] : preview.revisionEffects {
            contents.addArrangedSubview(label(effect))
        }
        if !preview.bookmarkEffects.isEmpty {
            addDivider()
            contents.addArrangedSubview(label("Bookmarks and Tags", secondary: true))
            for effect in preview.bookmarkEffects { contents.addArrangedSubview(label(effect)) }
        }

        addDivider()
        let toggle = NSButton(title: "Files on Disk · \(preview.fileEffects.count)", target: self, action: #selector(toggleFiles(_:)))
        toggle.isBordered = false
        toggle.alignment = .left
        toggle.imagePosition = .imageLeading
        toggle.font = .systemFont(ofSize: 11, weight: .semibold)
        filesToggle = toggle
        contents.addArrangedSubview(toggle)
        let paths = NSStackView()
        paths.orientation = .vertical
        paths.alignment = .width
        paths.spacing = 3
        if preview.fileEffects.isEmpty { paths.addArrangedSubview(label("No on-disk content changes", secondary: true)) }
        for file in preview.fileEffects {
            let row = label("\(file.label)  \(file.path)")
            row.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            paths.addArrangedSubview(row)
        }
        contents.addArrangedSubview(paths)
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
        let height = 130 + max(100, contents.fittingSize.height) + (notice.isHidden ? 0 : 34)
        resize(to: min(510, max(280, height)))
    }

    private func resize(to height: CGFloat) {
        popover.contentSize = NSSize(width: 412, height: height)
    }

    private func updateButtons() {
        directionControl.selectedSegment = direction == .undo ? 0 : 1
        directionControl.isEnabled = !applying
        applyButton.title = "\(direction.title) Operation"
        applyButton.isEnabled = preview != nil && !applying
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
                let ran = try await apply(preview)
                applying = false
                guard popover.isShown else { return }
                if ran { direction = preview.direction == .undo ? .redo : .undo }
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
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        contents.addArrangedSubview(divider)
    }

    private func configure() {
        let layout = NSView()
        let title = label("Repository Operations")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        directionControl.segmentCount = 2
        directionControl.setLabel("Undo", forSegment: 0)
        directionControl.setLabel("Redo", forSegment: 1)
        directionControl.trackingMode = .selectOne
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
        notice.isHidden = true
        let footer = NSStackView(views: [command, NSView(), applyButton])
        let stack = NSStackView(views: [title, directionControl, notice, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)
        layout.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layout.leadingAnchor), stack.trailingAnchor.constraint(equalTo: layout.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layout.topAnchor), stack.bottomAnchor.constraint(equalTo: layout.bottomAnchor)
        ])
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        contents.orientation = .vertical
        contents.alignment = .width
        contents.spacing = 5
        let documentView = SourceControlOperationDocumentView()
        documentView.addSubview(contents)
        scroll.documentView = documentView
        documentView.translatesAutoresizingMaskIntoConstraints = false
        contents.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contents.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contents.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -4),
            contents.topAnchor.constraint(equalTo: documentView.topAnchor), contents.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
        let controller = NSViewController()
        controller.view = layout
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        resize(to: 190)
    }
}

@MainActor
private final class SourceControlOperationDocumentView: NSView {
    override var isFlipped: Bool { true }
}
