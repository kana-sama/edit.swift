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
        let text = (input as? String) ?? (input as? NSAttributedString)?.string
        if let focusedSelectionGroups {
            guard let text, !hasMarkedText(), isEditable else { return true }
            let implicitRange = replacementRange.location == NSNotFound || replacementRange == selectedRange()
            if implicitRange {
                replaceFocusedGroups(focusedSelectionGroups, with: [text])
            } else if focusAllowsEdits([replacementRange]) {
                replaceFocusedGroups([[replacementRange]], with: [text])
            }
            return true
        }
        guard hasSecondarySelections, !hasMarkedText(),
              replacementRange.location == NSNotFound || replacementRange == selectedRange(),
              let text else { return false }
        replaceSelections(with: [text])
        return true
    }

    func deleteAtCarets(backward: Bool, word: Bool) -> Bool {
        let groups = focusedSelectionGroups
        guard !hasMarkedText(), let layout = textLayoutManager else {
            return groups != nil && !hasMarkedText()
        }
        let direction: NSTextSelectionNavigation.Direction = backward ? .backward : .forward
        if !hasSecondarySelections && groups == nil {
            let caret = selectedRange()
            guard word, isEditable, caret.length == 0, let range = textRange(caret, in: layout),
                  let navigation = layout.textSelectionNavigation as? EditorWordNavigation,
                  let adjusted = navigation.dottedDeletion(for: NSTextSelection(range: range, affinity: .downstream,
                      granularity: .character), direction: direction) else { return false }
            deleteRanges([charRange(adjusted, in: layout)])
            return true
        }
        func deletions(at caret: NSRange) -> [NSRange] {
            guard let text = textRange(caret, in: layout) else { return [] }
            let selection = NSTextSelection(range: text, affinity: .downstream, granularity: .character)
            return layout.textSelectionNavigation.deletionRanges(
                for: selection, direction: direction,
                destination: word ? .word : .character, allowsDecomposition: false
            ).map { charRange($0, in: layout) }
        }
        if let groups {
            let removals = groups.map { group -> [NSRange] in
                guard let first = group.first, first.length == 0,
                      let scope = editScope(containing: first.location) else { return group }
                return deletions(at: first).map { NSIntersectionRange($0, scope) }.filter { $0.length > 0 }
            }
            let carets = zip(groups, removals).compactMap { group, removed in
                (removed.first ?? group.first).map { NSRange(location: $0.location, length: 0) }
            }
            deleteRanges(removals.flatMap { $0 }, selections: carets)
        } else {
            let ranges = caretSelections.flatMap { $0.length == 0 ? deletions(at: $0) : [$0] }
            deleteRanges(ranges)
        }
        return true
    }

    private func deleteRanges(_ ranges: [NSRange], selections: [NSRange]? = nil) {
        let edits = MultiCaretEditing.ordered(MultiCaretEditing.merged(ranges.filter { $0.length > 0 }))
            .map { Replacement(range: $0, text: "") }
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(selections ?? caretSelections, after: edits))
    }

    func editMultipleLines(_ command: LineCommand) -> Bool {
        guard !hasMarkedText(), let text = textStorage?.mutableString else { return false }
        if let groups = focusedSelectionGroups, let scopes = focusRanges {
            editFocusedLines(command, in: text, scopes: scopes, groups: groups)
            return true
        }
        guard hasSecondarySelections else { return false }
        let plan = lineEdits(command, in: text, selections: caretSelections)
        applyMultiEdits(plan.edits, selections: plan.selections)
        return true
    }

    private func lineEdits(
        _ command: LineCommand, in text: NSString, selections: [NSRange], inFocus: Bool = false
    ) -> (edits: [Replacement], selections: [NSRange]) {
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
                guard lines.insert(location).inserted else { continue }
                if inFocus, LineEditing.line(at: range.location, in: text).separatorRange.length == 0,
                   location == 0 {
                    let line = LineEditing.line(at: range.location, in: text)
                    let indentation = text.substring(to: LineEditing.indentationEnd(in: line, text: text))
                    let insertion = above ? line.start : line.end
                    let replacement = above ? indentation + preferredLineEnding : preferredLineEnding + indentation
                    let caret = insertion + (above ? indentation.utf16.count : replacement.utf16.count)
                    edited.append((location, LineEditing.Edit(range: NSRange(location: insertion, length: 0),
                        replacement: replacement, selection: NSRange(location: caret, length: 0))))
                } else if let edit = LineEditing.insertLine(text, selection: range, above: above) {
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
            changes = MultiCaretEditing.ordered(MultiCaretEditing.merged(deleted.filter { $0.length > 0 }))
                .map { Replacement(range: $0, text: "") }
        }
        return (changes, next ?? MultiCaretEditing.mapped(selections, after: changes))
    }

    func copySelections(to pasteboard: NSPasteboard, cutting: Bool) -> Bool {
        if let groups = focusedSelectionGroups, !hasMarkedText() {
            if let text = textStorage?.mutableString, !cutting || isEditable {
                copyFocusedSelections(groups, in: text, to: pasteboard, cutting: cutting)
            }
            return true
        }
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
        if let groups = focusedSelectionGroups, !hasMarkedText() {
            if isEditable, let text = textStorage?.mutableString {
                pasteIntoFocus(groups, in: text, from: pasteboard)
            }
            return true
        }
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

    func transformFocusedSelections(_ transform: (String) -> String) -> Bool {
        guard let groups = focusedSelectionGroups, !hasMarkedText(), let text = textStorage?.mutableString else {
            return false
        }
        let edits = MultiCaretEditing.ordered(groups.flatMap { $0 }.filter { $0.length > 0 }).compactMap {
            range -> Replacement? in
            let original = text.substring(with: range)
            let transformed = transform(original)
            return original == transformed ? nil : Replacement(range: range, text: transformed)
        }
        let carets = groups.compactMap(\.last).map { NSRange(location: NSMaxRange($0), length: 0) }
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(carets, after: edits))
        return true
    }

    private func editScope(containing location: Int) -> NSRange? {
        focusRanges?.first { $0.location <= location && location <= NSMaxRange($0) }
    }

    private func focusedLine(at location: Int, in text: NSString, scope: NSRange) -> LineEditing.Line {
        let line = LineEditing.line(at: location, in: text)
        return LineEditing.Line(start: max(line.start, scope.location),
                                contentEnd: min(line.contentEnd, NSMaxRange(scope)),
                                end: min(line.end, NSMaxRange(scope)))
    }

    private func editFocusedLines(
        _ command: LineCommand, in text: NSString, scopes: [NSRange], groups: [[NSRange]]
    ) {
        if case .newline = command {
            let inserts = groups.map { group -> String in
                guard let first = group.first, let scope = editScope(containing: first.location) else {
                    return preferredLineEnding
                }
                let line = focusedLine(at: first.location, in: text, scope: scope)
                let end = min(first.location, LineEditing.indentationEnd(in: line, text: text))
                let indentation = text.substring(with: NSRange(location: line.start, length: end - line.start))
                return preferredLineEnding + indentation
            }
            replaceFocusedGroups(groups, with: inserts)
            return
        }

        let pieces = groups.flatMap { $0 }
        var replacements: [Replacement] = []
        var selections: [(index: Int, range: NSRange)] = []
        var precedingDelta = 0
        for scope in scopes {
            let affected = pieces.enumerated().filter {
                $0.element.location >= scope.location && NSMaxRange($0.element) <= NSMaxRange(scope)
            }
            guard !affected.isEmpty else { continue }
            let relative = affected.map { NSRange(location: $0.element.location - scope.location, length: $0.element.length) }
            let plan = lineEdits(command, in: text.substring(with: scope) as NSString,
                                 selections: relative, inFocus: true)
            replacements += plan.edits.map {
                Replacement(range: NSRange(location: scope.location + $0.range.location, length: $0.range.length), text: $0.text)
            }
            selections += zip(affected, plan.selections).map {
                ($0.0.offset, NSRange(location: scope.location + precedingDelta + $0.1.location, length: $0.1.length))
            }
            precedingDelta += plan.edits.reduce(0) { $0 + $1.text.utf16.count - $1.range.length }
        }
        applyMultiEdits(replacements, selections: selections.sorted { $0.index < $1.index }.map(\.range))
    }

    private func copyFocusedSelections(
        _ groups: [[NSRange]], in text: NSString, to pasteboard: NSPasteboard, cutting: Bool
    ) {
        let selected = groups.filter { $0.contains(where: { $0.length > 0 }) }
        let removed: [NSRange]
        let parts: [String]
        let wholeLines: Bool
        if selected.isEmpty {
            let lines = Set(groups.compactMap { group -> NSRange? in
                guard let caret = group.first, let scope = editScope(containing: caret.location) else { return nil }
                return focusedLine(at: caret.location, in: text, scope: scope).range
            }).filter { $0.length > 0 }
            removed = MultiCaretEditing.ordered(Array(lines))
            wholeLines = removed.allSatisfy { LineEditing.line(at: $0.location, in: text).range == $0 }
            parts = removed.map { range in
                let value = text.substring(with: range)
                let line = LineEditing.line(at: range.location, in: text)
                return wholeLines && line.end == line.contentEnd ? value + preferredLineEnding : value
            }
        } else {
            let ordered = selected.sorted { ($0.first?.location ?? 0) < ($1.first?.location ?? 0) }
            removed = ordered.flatMap { $0 }
            parts = ordered.map { $0.map { text.substring(with: $0) }.joined(separator: preferredLineEnding) }
            wholeLines = false
        }
        guard !parts.isEmpty else { return }
        let payload = parts.joined(separator: wholeLines ? "" : preferredLineEnding)
        let type = wholeLines ? Self.linesPasteType : Self.selectionPasteType
        let types: [NSPasteboard.PasteboardType] = wholeLines ? [.string, type, Self.linePasteType] : [.string, type]
        if cutting {
            let carets = selected.isEmpty ? nil : groups.compactMap { group in
                group.first.map { NSRange(location: $0.location, length: 0) }
            }
            let edits = MultiCaretEditing.ordered(MultiCaretEditing.merged(removed))
                .map { Replacement(range: $0, text: "") }
            let next = MultiCaretEditing.mapped(carets ?? caretSelections, after: edits)
            guard applyMultiEdits(edits, selections: next) else { return }
        }
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(payload, forType: .string)
        pasteboard.setPropertyList(parts, forType: type)
        if wholeLines { pasteboard.setString(payload, forType: Self.linePasteType) }
    }

    private func pasteIntoFocus(_ groups: [[NSRange]], in text: NSString, from pasteboard: NSPasteboard) {
        if let lines = pasteboard.string(forType: Self.linePasteType),
           groups.allSatisfy({ $0.count == 1 && $0[0].length == 0 }) {
            let starts = groups.compactMap { group -> Int? in
                guard let caret = group.first, let scope = editScope(containing: caret.location) else { return nil }
                return focusedLine(at: caret.location, in: text, scope: scope).start
            }
            let locations = Set(starts).sorted()
            let parts = pasteboard.propertyList(forType: Self.linesPasteType) as? [String] ?? []
            let edits = locations.enumerated().map { index, start in
                Replacement(range: NSRange(location: start, length: 0),
                            text: parts.count == locations.count ? parts[index] : lines)
            }
            applyMultiEdits(edits, selections: MultiCaretEditing.mapped(caretSelections, after: edits))
            return
        }
        guard let text = pasteboard.string(forType: .string) else { return }
        let parts = pasteboard.propertyList(forType: Self.selectionPasteType) as? [String] ?? []
        if parts.count == groups.count, parts.count > 1 {
            let order = groups.indices.sorted { (groups[$0].first?.location ?? 0) < (groups[$1].first?.location ?? 0) }
            var mapped = parts
            for (index, groupIndex) in order.enumerated() { mapped[groupIndex] = parts[index] }
            replaceFocusedGroups(groups, with: mapped)
        } else {
            replaceFocusedGroups(groups, with: [text])
        }
    }

    private func replaceFocusedGroups(_ groups: [[NSRange]], with texts: [String]) {
        var edits: [Replacement] = []
        var carets: [NSRange] = []
        for (index, group) in groups.enumerated() {
            guard let start = group.first else { continue }
            edits.append(Replacement(range: start, text: texts.count == 1 ? texts[0] : texts[index]))
            edits += group.dropFirst().map { Replacement(range: $0, text: "") }
            carets.append(NSRange(location: start.location, length: 0))
        }
        edits.sort { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        applyMultiEdits(edits, selections: MultiCaretEditing.mapped(carets, after: edits))
    }

    @discardableResult
    func applyMultiEdits(
        _ replacements: [MultiCaretEditing.Replacement], selections: [NSRange], validate: Bool = true,
        restoreFocus: EditorFocusSession.Snapshot? = nil,
        restoreNavigation: [FocusNavigationSelection]? = nil
    ) -> Bool {
        let edits = replacements.filter { $0.range.length > 0 || !$0.text.isEmpty }
        guard !edits.isEmpty, let storage = textStorage else { return false }
        let previous = caretSelections
        let previousFocus = captureFocusSnapshot()
        let previousFocusNavigation = multiCaret.focusNavigation
        let manager = undoManager
        if validate {
            let ranges = edits.map(\.range)
            guard isEditable, focusAllowsEdits(ranges),
                  ranges.allSatisfy({ $0.location >= 0 && $0.location <= storage.length &&
                      $0.length >= 0 && $0.length <= storage.length - $0.location }),
                  zip(ranges, ranges.dropFirst()).allSatisfy({ NSMaxRange($0) <= $1.location }) else { return false }
            breakUndoCoalescing()
            manager?.disableUndoRegistration()
            let allowed = withFocusEditsAllowed {
                shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text))
            }
            manager?.enableUndoRegistration()
            guard allowed else { return false }
        } else {
            breakUndoCoalescing()
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
        let restoredLiveFocus = updateFocus(after: edits, restoring: restoreFocus)
        storage.endEditing()
        setCaretSelections(selections, record: false,
                           focusNavigation: restoredLiveFocus ? restoreNavigation : nil)
        multiCaret.isApplying = true
        didChangeText()
        multiCaret.isApplying = false
        breakUndoCoalescing()
        if let primary = caretSelections.last { scrollRangeToVisible(primary) }

        let ownsUndoGroup = previousFocus != nil && manager?.groupingLevel == 0 &&
            manager?.isUndoing == false && manager?.isRedoing == false
        if ownsUndoGroup { manager?.beginUndoGrouping() }
        manager?.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                editor.applyMultiEdits(inverse, selections: previous, validate: false, restoreFocus: previousFocus,
                                       restoreNavigation: previousFocusNavigation)
            }
        }
        if ownsUndoGroup { manager?.endUndoGrouping() }
        return true
    }
}
