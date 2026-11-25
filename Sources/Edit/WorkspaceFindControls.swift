import AppKit

@MainActor
final class WorkspaceFindTable: SidebarActionResultTable {
    var canUndoChanges: ((Bool) -> Bool)?
    var onUndoChanges: ((Bool) -> Void)?

    @objc func undo(_ sender: Any?) { onUndoChanges?(false) }
    @objc func redo(_ sender: Any?) { onUndoChanges?(true) }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndoChanges?(false) == true }
        if item.action == #selector(redo(_:)) { return canUndoChanges?(true) == true }
        return super.validateUserInterfaceItem(item)
    }
}
