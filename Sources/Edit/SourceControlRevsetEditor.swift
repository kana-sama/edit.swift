import AppKit

@MainActor
final class SourceControlRevsetEditor: NSObject, NSTextFieldDelegate {
    let view = NSStackView()

    private let heading = NSTextField(labelWithString: "")
    private let name = NSTextField()
    private let code = SourceControlRevsetCode(height: 142)
    private let explanation = NSTextField(labelWithString: "Built-in expression")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let delete = NSButton()
    private let save = NSButton()
    private let onSave: (String, String, String?) async throws -> Void
    private let onDelete: (String) throws -> Void
    private let onDone: () -> Void
    private let onResize: () -> Void
    private var entry: SourceControlRevset?
    private var request: Task<Void, Never>?

    init(onSave: @escaping (String, String, String?) async throws -> Void, onDelete: @escaping (String) throws -> Void,
         onDone: @escaping () -> Void, onResize: @escaping () -> Void) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.onDone = onDone
        self.onResize = onResize
        super.init()
        configure()
    }

    isolated deinit { request?.cancel() }

    func install(_ entry: SourceControlRevset?, configuredExpression: String?) {
        stop()
        self.entry = entry
        let builtIn = entry?.isBuiltIn == true
        heading.stringValue = entry == nil ? "New Revset" : "Edit Revset"
        name.stringValue = entry?.name ?? ""
        code.install(entry?.expression ?? configuredExpression ?? "", editable: !builtIn)
        delete.isHidden = entry == nil || builtIn
        explanation.isHidden = !builtIn
        explanation.stringValue = builtIn && entry?.expression == nil && configuredExpression == nil
            ? "Loading configured expression…" : "Built-in expression"
        updateControls()
    }

    func installConfiguredExpression(_ result: Result<String, Error>) {
        guard entry?.id == SourceControlRevset.defaultLog.id else { return }
        explanation.stringValue = "Built-in expression"
        switch result {
        case .success(let expression): code.install(expression, editable: false)
        case .failure(let error): setError(error.localizedDescription)
        }
    }

    func focusName() {
        name.window?.makeFirstResponder(name)
        name.selectText(nil)
    }

    func stop() {
        request?.cancel()
        request = nil
        errorLabel.isHidden = true
    }

    func controlTextDidChange(_ notification: Notification) { inputChanged() }

    private func inputChanged() {
        if !errorLabel.isHidden { setError(nil) }
        updateControls()
    }

    @objc private func submit() {
        let newName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = trimmedExpression
        guard request == nil, !newName.isEmpty, entry?.isBuiltIn == true || !expression.isEmpty else { return }
        setError(nil)
        let id = entry?.id
        request = Task { [weak self, onSave] in
            do {
                try await onSave(newName, expression, id)
                guard let self, !Task.isCancelled else { return }
                request = nil
                onDone()
            } catch {
                guard let self, !Task.isCancelled else { return }
                request = nil
                setError(error.localizedDescription)
                updateControls()
            }
        }
        updateControls()
    }

    @objc private func remove() {
        guard request == nil, let entry, !entry.isBuiltIn else { return }
        do {
            try onDelete(entry.id)
            onDone()
        } catch {
            setError(error.localizedDescription)
        }
    }

    @objc private func cancel() {
        stop()
        onDone()
    }

    private var trimmedExpression: String {
        code.editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateControls() {
        name.isEnabled = request == nil
        code.editor.isEditable = request == nil && entry?.isBuiltIn != true
        delete.isEnabled = request == nil
        save.isEnabled = request == nil && !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (entry?.isBuiltIn == true || !trimmedExpression.isEmpty)
        save.bezelColor = save.isEnabled ? .controlAccentColor : nil
    }

    private func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        onResize()
    }

    private func configure() {
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.alignment = .left
        name.placeholderString = "My changes"
        name.setAccessibilityLabel("Revset Name")
        name.cell?.usesSingleLineMode = true
        name.lineBreakMode = .byTruncatingTail
        name.delegate = self
        name.target = self
        name.action = #selector(submit)
        code.editor.onTextChange = { [weak self] in self?.inputChanged() }
        name.nextKeyView = code.editor
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let expressionLabel = NSTextField(labelWithString: "Expression")
        expressionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        expressionLabel.textColor = .secondaryLabelColor
        let labelRow = NSStackView(views: [expressionLabel, NSView(), explanation])
        labelRow.alignment = .centerY
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.alignment = .left
        errorLabel.lineBreakMode = .byCharWrapping
        errorLabel.maximumNumberOfLines = 6
        errorLabel.preferredMaxLayoutWidth = 372
        errorLabel.isHidden = true
        delete.title = "Delete Revset"
        delete.bezelStyle = .rounded
        delete.hasDestructiveAction = true
        delete.target = self
        delete.action = #selector(remove)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        save.title = "Save"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        save.target = self
        save.action = #selector(submit)
        let footer = NSStackView(views: [delete, NSView(), cancel, save])
        footer.alignment = .centerY
        footer.spacing = 8
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        for child in [heading, name, labelRow, code.scroll, errorLabel, footer] {
            view.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        view.setCustomSpacing(4, after: labelRow)
    }
}
