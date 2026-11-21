import AppKit

extension EditorTextView {
    private static let selectionPasteType = NSPasteboard.PasteboardType("dev.edit-swift.selections")
    private static let linesPasteType = NSPasteboard.PasteboardType("dev.edit-swift.lines")

    enum LineCommand {
        case tab
        case indent(outdent: Bool)
        case newline
        case move(up: Bool)
        case insert(above: Bool)
        case deleteLineBoundary(backward: Bool)
    }

    private typealias Replacement = MultiCaretEditing.Replacement

    func insertAtCarets(_ input: Any, replacementRange: NSRange) -> Bool {
        guard hasSecondarySelections, !hasMarkedText(),
              replacementRange.location == NSNotFound || replacementRange == selectedRange(),
              let text = (input as? String) ?? (input as? NSAttributedString)?.string else { return false }
        replaceSelections(with: [text])
        return true
    }

    func deleteAtCarets(backward: Bool, word: Bool) -> Bool {
        guard hasSecondarySelections, !hasMarkedText(), let layout = textLayoutManager else { return false }
        let ranges = caretSelections.flatMap { range -> [NSRange] in
            if range.length > 0 { return [range] }
            guard let text = textRange(range, in: layout) else { return [] }
            let selection = NSTextSelection(range: text, affinity: .downstream, granularity: .character)
            return layout.textSelectionNavigation.deletionRanges(
                for: selection, direction: backward ? .backward : .forward,
                destination: word ? .word : .character, allowsDecomposition: false
            ).map { charRange($0, in: layout) }
        }
        deleteRanges(ranges)
        return true
    }

    private func deleteRanges(_ ranges: [NSRange]) {
        let edits = MultiCaretEditing.ordered(MultiCaretEditing.merged(ranges.filter { $0.length > 0 }))
            .map { Replacement(range: $0, text: "") }
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(caretSelections, after: edits))
    }

    func editMultipleLines(_ command: LineCommand) -> Bool {
        guard hasSecondarySelections, !hasMarkedText(), let text = textStorage?.mutableString else { return false }
        let selections = caretSelections
        let changes: [Replacement]
        var next: [NSRange]?

        switch command {
        case .tab:
            let indent = MultiCaretEditing.indentation(in: text, for: selections.filter { $0.length > 0 }, outdent: false)
            let existing = Set(indent.map(\.range.location))
            changes = (indent + selections.filter { $0.length == 0 && !existing.contains($0.location) }
                .map { Replacement(range: $0, text: "    ") }).sorted { $0.range.location < $1.range.location }
        case .indent(let outdent):
            changes = MultiCaretEditing.indentation(in: text, for: selections, outdent: outdent)
        case .newline:
            changes = MultiCaretEditing.ordered(selections).map { range in
                let line = LineEditing.line(at: range.location, in: text)
                let end = min(range.location, LineEditing.indentationEnd(in: line, text: text))
                let indentation = text.substring(with: NSRange(location: line.start, length: end - line.start))
                return Replacement(range: range, text: preferredLineEnding + indentation)
            }
        case .move(let up):
            var moved = selections
            changes = MultiCaretEditing.lineBlocks(in: text, for: selections).compactMap { block in
                guard let movement = LineEditing.move(text, block: block.line, up: up) else { return nil }
                for index in block.indices { moved[index] = movement.selection(selections[index]) }
                return Replacement(range: movement.range, text: movement.replacement)
            }
            next = moved
        case .insert(let above):
            var edited: [(location: Int, edit: LineEditing.Edit)] = []
            var lines: Set<Int> = []
            for range in MultiCaretEditing.ordered(selections) {
                let location = LineEditing.line(at: range.location, in: text).start
                if lines.insert(location).inserted, let edit = LineEditing.insertLine(text, selection: range, above: above) {
                    edited.append((location, edit))
                }
            }
            var inserts: [Replacement] = []
            var offsets: [Int: NSRange] = [:]
            var added = 0
            for (location, edit) in edited {
                offsets[location] = NSRange(location: edit.selection.location + added, length: 0)
                added += edit.replacement.utf16.count
                if inserts.last?.range.location == edit.range.location {
                    inserts[inserts.count - 1].text += edit.replacement
                } else {
                    inserts.append(Replacement(range: edit.range, text: edit.replacement))
                }
            }
            changes = inserts
            next = selections.compactMap { offsets[LineEditing.line(at: $0.location, in: text).start] }
        case .deleteLineBoundary(let backward):
            let deleted = selections.map { range in
                let line = LineEditing.line(at: range.location, in: text)
                if backward {
                    let start = range.length == 0 && range.location == line.start && line.start > 0
                        ? LineEditing.line(at: line.start - 1, in: text).contentEnd : line.start
                    return NSRange(location: start, length: NSMaxRange(range) - start)
                }
                let end = range.length == 0 && range.location == line.contentEnd
                    ? line.end : max(NSMaxRange(range), line.contentEnd)
                return NSRange(location: range.location, length: end - range.location)
            }
            deleteRanges(deleted)
            return true
        }
        applyMultiEdits(changes, selections: next ?? MultiCaretEditing.mapped(selections, after: changes))
        return true
    }

    func copySelections(to pasteboard: NSPasteboard, cutting: Bool) -> Bool {
        guard hasSecondarySelections, !hasMarkedText(), let text = textStorage?.mutableString,
              !cutting || isEditable else { return false }
        let selections = MultiCaretEditing.ordered(caretSelections)
        let nonempty = selections.filter { $0.length > 0 }
        if !nonempty.isEmpty {
            let parts = nonempty.map { text.substring(with: $0) }
            pasteboard.declareTypes([.string, Self.selectionPasteType], owner: nil)
            pasteboard.setString(parts.joined(separator: preferredLineEnding), forType: .string)
            pasteboard.setPropertyList(parts, forType: Self.selectionPasteType)
            if cutting { deleteRanges(nonempty) }
            return true
        }

        var seen: Set<Int> = []
        let lines = selections.map { LineEditing.line(at: $0.location, in: text) }
            .filter { seen.insert($0.start).inserted }
        let parts = lines.map { line in
            let content = text.substring(with: line.range)
            return line.end == line.contentEnd ? content + preferredLineEnding : content
        }
        let joined = parts.joined()
        pasteboard.declareTypes([.string, Self.linePasteType, Self.linesPasteType], owner: nil)
        pasteboard.setString(joined, forType: .string)
        pasteboard.setString(joined, forType: Self.linePasteType)
        pasteboard.setPropertyList(parts, forType: Self.linesPasteType)
        if cutting {
            deleteRanges(lines.map { line in
                let start = line.end == line.contentEnd && line.start > 0
                    ? LineEditing.line(at: line.start - 1, in: text).contentEnd : line.start
                return NSRange(location: start, length: line.end - start)
            })
        }
        return true
    }

    func pasteAtCarets(from pasteboard: NSPasteboard) -> Bool {
        guard hasSecondarySelections, isEditable, !hasMarkedText() else { return false }
        if let pastedLines = pasteboard.string(forType: Self.linePasteType),
           let text = textStorage?.mutableString, caretSelections.allSatisfy({ $0.length == 0 }) {
            let starts = Set(caretSelections.map { LineEditing.line(at: $0.location, in: text).start }).sorted()
            let parts = pasteboard.propertyList(forType: Self.linesPasteType) as? [String] ?? []
            let edits = starts.enumerated().map { index, start in
                Replacement(range: NSRange(location: start, length: 0),
                            text: parts.count == starts.count ? parts[index] : pastedLines)
            }
            applyMultiEdits(edits, selections: MultiCaretEditing.mapped(caretSelections, after: edits))
            return true
        }
        guard let string = pasteboard.string(forType: .string) else { return false }
        let parts = pasteboard.propertyList(forType: Self.selectionPasteType) as? [String] ?? []
        replaceSelections(with: parts.count == caretSelections.count ? parts : [string])
        return true
    }

    private func replaceSelections(with texts: [String]) {
        let edits = MultiCaretEditing.ordered(caretSelections).enumerated().map { index, range in
            Replacement(range: range, text: texts.count == 1 ? texts[0] : texts[index])
        }
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(caretSelections, after: edits))
    }

    private func applyMultiEdits(_ replacements: [Replacement], selections: [NSRange], validate: Bool = true) {
        let edits = replacements.filter { $0.range.length > 0 || !$0.text.isEmpty }
        guard !edits.isEmpty, let storage = textStorage else { return }
        let previous = caretSelections
        breakUndoCoalescing()
        if validate {
            undoManager?.disableUndoRegistration()
            let allowed = shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) },
                                           replacementStrings: edits.map(\.text))
            undoManager?.enableUndoRegistration()
            guard allowed else { return }
        }

        var delta = 0
        let inverse = edits.map { replacement in
            let result = replacement.result(at: delta)
            delta += result.length - replacement.range.length
            return Replacement(range: result, text: storage.attributedSubstring(from: replacement.range).string)
        }

        multiCaret.isApplying = true
        storage.beginEditing()
        for replacement in edits.reversed() {
            storage.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        storage.endEditing()
        setCaretSelections(selections, record: false)
        multiCaret.isApplying = true
        didChangeText()
        multiCaret.isApplying = false
        breakUndoCoalescing()
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }

        undoManager?.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                editor.applyMultiEdits(inverse, selections: previous, validate: false)
            }
        }
    }
}
