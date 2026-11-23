import AppKit

@MainActor
final class SourceControlFilterPopover: NSObject, NSTextFieldDelegate {
    private static let inset: CGFloat = 14
    private static let contentWidth: CGFloat = 302

    private weak var anchor: NSView?
    private let onScopeChange: (JJSourceControlScope) -> Void
    private let onQueryChange: (String) -> Void
    private let popover = NSPopover()
    private let layout = NSStackView()
    private let scope = NSSegmentedControl()
    private let search = NSSearchField()
    private let revset = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let revsetGroup = NSStackView()

    init(anchor: NSView, onScopeChange: @escaping (JJSourceControlScope) -> Void, onQueryChange: @escaping (String) -> Void) {
        self.anchor = anchor
        self.onScopeChange = onScopeChange
        self.onQueryChange = onQueryChange
        super.init()
        configure()
    }

    func show() {
        if popover.isShown { close(); return }
        guard let anchor, anchor.window != nil else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        search.window?.makeFirstResponder(search)
    }

    func close() { popover.close() }

    func setQuery(_ query: String) { search.stringValue = query }

    func setError(_ message: String?) {
        guard errorLabel.stringValue != message ?? "" || errorLabel.isHidden != (message == nil) else { return }
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        fitContent()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === revset, !errorLabel.isHidden {
            setError(nil)
        }
    }

    @objc private func findInGraph() {
        onQueryChange(search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func chooseScope(_ sender: NSSegmentedControl) {
        revsetGroup.isHidden = sender.selectedSegment != 2
        setError(nil)
        fitContent()
        switch sender.selectedSegment {
        case 0: onScopeChange(.log)
        case 1: onScopeChange(.stack)
        default:
            revset.window?.makeFirstResponder(revset)
            applyRevset()
        }
    }

    @objc private func applyRevset() {
        let expression = revset.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expression.isEmpty { onScopeChange(.revset(expression)) }
    }

    @objc private func done() { close() }

    private func configure() {
        let width = Self.contentWidth
        let title = NSTextField(labelWithString: "Filter Changes")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        scope.segmentCount = 3
        for (index, label) in ["Default Log", "Current Stack", "Revset"].enumerated() {
            scope.setLabel(label, forSegment: index)
        }
        scope.segmentDistribution = .fillEqually
        scope.trackingMode = .selectOne
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(chooseScope(_:))
        scope.setAccessibilityLabel("Graph Scope")

        search.placeholderString = "Description, change ID, bookmark"
        search.setAccessibilityLabel("Find in Graph")
        search.target = self
        search.action = #selector(findInGraph)
        search.sendsSearchStringImmediately = true

        revset.stringValue = "mutable() | trunk()"
        revset.setAccessibilityLabel("Revset")
        revset.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        revset.delegate = self
        revset.target = self
        revset.action = #selector(applyRevset)
        revset.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let apply = NSButton(title: "Apply Revset", target: self, action: #selector(applyRevset))
        apply.bezelStyle = .rounded
        apply.setContentHuggingPriority(.required, for: .horizontal)
        let revsetRow = NSStackView(views: [revset, apply])
        revsetRow.alignment = .centerY
        revsetRow.spacing = 8
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.lineBreakMode = .byCharWrapping
        errorLabel.maximumNumberOfLines = 6
        errorLabel.preferredMaxLayoutWidth = width
        errorLabel.isHidden = true
        revsetGroup.orientation = .vertical
        revsetGroup.alignment = .leading
        revsetGroup.spacing = 4
        for view in [caption("Revset"), revsetRow, errorLabel] {
            revsetGroup.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        revsetGroup.isHidden = true

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSView()
        footer.addSubview(done)
        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: footer.topAnchor),
            done.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            done.trailingAnchor.constraint(equalTo: footer.trailingAnchor)
        ])

        let searchCaption = caption("Find in Graph")
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 9
        for view in [title, scope, searchCaption, search, revsetGroup, footer] {
            layout.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        layout.setCustomSpacing(4, after: searchCaption)
        let content = NSView()
        content.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.inset)
        ])
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        fitContent()
    }

    private func caption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func fitContent() {
        let size = NSSize(width: Self.contentWidth + 2 * Self.inset, height: ceil(layout.fittingSize.height) + 2 * Self.inset)
        popover.contentSize = size
        if !popover.isShown { popover.contentViewController?.view.setFrameSize(size) }
    }

#if EDIT_AGENT_CHECKS
    var checkView: NSView { popover.contentViewController!.view }

    func selectRevsetForCheck() {
        scope.selectedSegment = 2
        chooseScope(scope)
    }
#endif
}
