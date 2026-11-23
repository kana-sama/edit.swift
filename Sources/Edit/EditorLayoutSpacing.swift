import AppKit
import os

/// Display space between native paragraphs. The live text and paragraph styles stay intact.
@MainActor
final class EditorLayoutSpacing: NSObject, NSTextLayoutManagerDelegate {
    enum ID: Hashable {
        case removed(NSRange)
        case replacement
    }

    enum Owner {
        case diff, find
    }

    enum Edge {
        case before, after
    }

    struct Block: Equatable {
        let id: ID
        let paragraph: Int
        let edge: Edge
        let height: CGFloat
    }

    private struct Gap: Equatable, Sendable {
        var before: CGFloat = 0
        var after: CGFloat = 0
    }

    private struct Slot {
        let block: Block
        let offset: CGFloat
    }

    private static let attribute = NSAttributedString.Key("dev.edit.layout-spacing")
    private weak var editor: EditorTextView?
    private var groups: [Owner: [Block]] = [:]
    private var slots: [ID: Slot] = [:]
    private nonisolated let gaps = OSAllocatedUnfairLock(initialState: [Int: Gap]())
    private var emptyInset: NSSize?
    private var sourceChanged = false

    init(editor: EditorTextView) { self.editor = editor }

    func sourceDidEdit() {
        if !slots.isEmpty { sourceChanged = true }
    }

    func set(_ blocks: [Block], for owner: Owner) {
        guard let editor, let manager = editor.textLayoutManager, let storage = editor.textStorage,
              groups[owner, default: []] != blocks || sourceChanged else { return }
        groups[owner] = blocks
        let source = storage.mutableString
        var next: [Int: Gap] = [:]
        var slots: [ID: Slot] = [:]
        // Place a Replace preview immediately after its live line, before a deletion at EOF.
        for block in groups[.find, default: []] + groups[.diff, default: []]
            where block.paragraph >= 0 && (source.length == 0 ? block.paragraph == 0 : block.paragraph < source.length) {
            var gap = next[block.paragraph, default: Gap()]
            switch block.edge {
            case .before:
                slots[block.id] = Slot(block: block, offset: gap.before)
                gap.before += block.height
            case .after:
                slots[block.id] = Slot(block: block, offset: gap.after)
                gap.after += block.height
            }
            next[block.paragraph] = gap
        }
        self.slots = slots

        if source.length == 0, let gap = next[0] {
            // TextKit owns the empty editor's insertion row.
            let original = emptyInset ?? editor.textContainerInset
            emptyInset = original
            let inset = NSSize(width: original.width, height: original.height + gap.before)
            if editor.textContainerInset != inset { editor.textContainerInset = inset }
            next = [:]
        } else if let original = emptyInset {
            emptyInset = nil
            editor.textContainerInset = original
        }

        let changed = gaps.withLock { [next] previous in
            guard previous != next else { return false }
            previous = next
            return true
        }
        guard changed || sourceChanged else { return }
        sourceChanged = false
        if next.isEmpty {
            if manager.delegate === self { manager.delegate = nil }
        } else {
            manager.delegate = self
        }
        if source.length > 0 {
            storage.beginEditing()
            // A layout invalidation alone can reuse fragments. Rebuild through the delegate
            // by changing only this presentation marker on affected paragraphs.
            storage.enumerateAttribute(Self.attribute, in: NSRange(location: 0, length: source.length)) { value, range, _ in
                if value != nil { storage.removeAttribute(Self.attribute, range: range) }
            }
            for offset in next.keys {
                let range = source.lineRange(for: NSRange(location: offset, length: 0))
                storage.addAttribute(Self.attribute, value: true, range: range)
            }
            storage.endEditing()
        }
        manager.textViewportLayoutController.layoutViewport()
    }

    func rect(for id: ID) -> NSRect? {
        guard let editor, let slot = slots[id] else { return nil }
        let block = slot.block
        let y: CGFloat
        if let original = emptyInset {
            y = original.height + slot.offset
        } else {
            guard let manager = editor.textLayoutManager,
                  let location = manager.location(manager.documentRange.location, offsetBy: block.paragraph),
                  let fragment = manager.textLayoutFragment(for: location) as? SpacedEditorFragment,
                  fragment.state == .layoutAvailable else { return nil }
            let frame = fragment.layoutFragmentFrame
            let edge = switch block.edge {
            case .before: frame.minY + fragment.topMargin - fragment.before
            case .after: frame.maxY - fragment.after
            }
            y = editor.textContainerOrigin.y + edge + slot.offset
        }
        return NSRect(x: editor.bounds.minX, y: y, width: editor.bounds.width, height: block.height)
    }

    nonisolated func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                       in element: NSTextElement) -> NSTextLayoutFragment {
        let offset = manager.offset(from: manager.documentRange.location, to: location)
        guard let gap = gaps.withLock({ $0[offset] }) else {
            return NSTextLayoutFragment(textElement: element, range: nil)
        }
        let fragment = SpacedEditorFragment(textElement: element, range: nil)
        fragment.before = gap.before
        fragment.after = gap.after
        return fragment
    }
}

private final class SpacedEditorFragment: NSTextLayoutFragment {
    var before: CGFloat = 0
    var after: CGFloat = 0
    override var topMargin: CGFloat { super.topMargin + before }
    override var bottomMargin: CGFloat { super.bottomMargin + after }
}
