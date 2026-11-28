import AppKit

// AppKit's shared field editor drops its Undo stack when it changes controls.
// Give a long-lived input its own editor so focus changes do not discard edits.
final class InputFieldEditor: NSTextView {
    private let history = UndoManager()

    static func make() -> InputFieldEditor {
        let editor = InputFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        return editor
    }

    override var undoManager: UndoManager? { history }

    // A field editor otherwise lets the window handle these actions.
    @objc func undo(_ sender: Any?) { if history.canUndo { history.undo() } }
    @objc func redo(_ sender: Any?) { if history.canRedo { history.redo() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return history.canUndo
        case #selector(redo(_:)): return history.canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

extension NSTextView {
    func replaceAllTextUndoably(with value: String) {
        guard string != value else { return }
        breakUndoCoalescing()
        insertText(value, replacementRange: NSRange(location: 0, length: string.utf16.count))
        breakUndoCoalescing()
    }
}
