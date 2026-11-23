import AppKit

@MainActor
final class SourceControlRevsetEditor: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    private static let inset: CGFloat = 14
    private static let width: CGFloat = 306

    private weak var anchor: NSView?
    private let onSave: (String, String, String?) async throws -> Void
    private let popover = NSPopover()
    private let layout = NSStackView()
    private let heading = NSTextField(labelWithString: "")
    private let name = NSTextField()
    private let expression = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let save = NSButton()
    private var editingID: String?
    private var request: Task<Void, Never>?

    init(anchor: NSView, onSave: @escaping (String, String, String?) async throws -> Void) {
        self.anchor = anchor
        self.onSave = onSave
        super.init()
        configure()
    }

    isolated deinit { request?.cancel() }

    func show(editing entry: SourceControlRevset?) {
        guard let anchor, anchor.window != nil else { return }
        editingID = entry?.id
        heading.stringValue = entry == nil ? "New Revset" : "Edit Revset"
        name.stringValue = entry?.name ?? ""
        expression.stringValue = entry?.expression ?? ""
        setError(nil)
        updateControls()
        if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX) }
        name.window?.makeFirstResponder(name)
        name.selectText(nil)
    }

    func close() {
        request?.cancel()
        request = nil
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        request?.cancel()
        request = nil
    }

    func controlTextDidChange(_ notification: Notification) {
        if !errorLabel.isHidden { setError(nil) }
        updateControls()
    }

    @objc private func submit() {
        let nameValue = trimmed(name)
        let expressionValue = trimmed(expression)
        guard request == nil, !nameValue.isEmpty, !expressionValue.isEmpty else { return }
        setError(nil)
        let id = editingID
        request = Task { [weak self, onSave] in
            do {
                try await onSave(nameValue, expressionValue, id)
                guard !Task.isCancelled else { return }
                self?.close()
            } catch {
                guard let self, !Task.isCancelled else { return }
                request = nil
                setError(error.localizedDescription)
                updateControls()
            }
        }
        updateControls()
    }

    @objc private func cancel() { close() }

    private func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateControls() {
        name.isEnabled = request == nil
        expression.isEnabled = request == nil
        save.isEnabled = request == nil && !trimmed(name).isEmpty && !trimmed(expression).isEmpty
    }

    private func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        let size = NSSize(width: Self.width + 2 * Self.inset, height: ceil(layout.fittingSize.height) + 2 * Self.inset)
        popover.contentSize = size
        if !popover.isShown { popover.contentViewController?.view.setFrameSize(size) }
    }

    private func configure() {
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        name.placeholderString = "My changes"
        expression.placeholderString = "mutable()"
        expression.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        expression.alignment = .left
        for (field, label) in [(name, "Name"), (expression, "Revset Expression")] {
            field.setAccessibilityLabel(label)
            field.cell?.usesSingleLineMode = true
            field.delegate = self
            field.target = self
            field.action = #selector(submit)
        }
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.alignment = .left
        errorLabel.lineBreakMode = .byCharWrapping
        errorLabel.maximumNumberOfLines = 6
        errorLabel.preferredMaxLayoutWidth = Self.width
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        save.title = "Save"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.target = self
        save.action = #selector(submit)
        let footer = NSStackView(views: [NSView(), cancel, save])
        footer.spacing = 8
        let nameLabel = label("Name")
        let expressionLabel = label("Revset Expression")
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 9
        for child in [heading, nameLabel, name, expressionLabel, expression, errorLabel, footer] {
            layout.addArrangedSubview(child)
            child.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        }
        layout.setCustomSpacing(4, after: nameLabel)
        layout.setCustomSpacing(4, after: expressionLabel)
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
        popover.delegate = self
        setError(nil)
        updateControls()
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

#if EDIT_AGENT_CHECKS
    var checkView: NSView { popover.contentViewController!.view }
#endif
}
