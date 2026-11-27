import AppKit

@MainActor
final class EditorLanguageAssistance {
    struct Context: Equatable {
        let session: LanguageServerSession
        let revision: Int
        let generation: Int
        let opening: UInt64

        static func == (left: Self, right: Self) -> Bool {
            left.session === right.session && left.revision == right.revision &&
                left.generation == right.generation && left.opening == right.opening
        }
    }

    private struct Completion {
        let context: Context
        let caret: Int
        let range: NSRange
        let items: [LSPCompletionItem]
        let isIncomplete: Bool
        var selected: Int
    }

    private struct Signature {
        let label: String
        let parameter: NSRange?
        let documentation: LSPMarkup?
    }

    private weak var editor: EditorTextView?
    private let context: () -> Context?
    private var completion: Completion?
    private var signature: Signature?
    private var completionTask: Task<Void, Never>?
    private var signatureTask: Task<Void, Never>?
    private var completionExpiry: Task<Void, Never>?
    private var signatureExpiry: Task<Void, Never>?
    private var acceptanceTask: Task<Void, Never>?
    private var formatTask: Task<Void, Never>?
    private var trackedCaret: Int?
    private var lastBufferEdit: ContinuousClock.Instant?
    private lazy var choices = EditorCompletionChoices { [weak self] row in self?.accept(row) }
    private lazy var completionPopup = EditorAssistancePopup(prefersAbove: false)
    private lazy var signaturePopup = EditorAssistancePopup(prefersAbove: true)
    private static let staleInterval: Duration = .milliseconds(300)

    init(editor: EditorTextView, context: @escaping () -> Context?) {
        self.editor = editor
        self.context = context
    }

    var isPresenting: Bool { completion != nil || signature != nil }
    var isTrackingInput: Bool { isPresenting || completionTask != nil || signatureTask != nil }
    var canComplete: Bool { caret != nil && context()?.session.supportsCompletion == true }
    var canShowSignature: Bool { caret != nil && context()?.session.supportsSignatureHelp == true }
    var offersCompletion: Bool { context()?.session.supportsCompletion == true }
    var offersSignatureHelp: Bool { context()?.session.supportsSignatureHelp == true }
    var canFormat: Bool { editor?.focusRanges == nil && context()?.session.supportsFormatting == true }

    private var caret: Int? {
        guard let editor, editor.window?.firstResponder === editor,
              !editor.hasSecondarySelections, editor.selectedRange().length == 0 else { return nil }
        return editor.selectedRange().location
    }

    func complete() { requestCompletion(trigger: nil, delay: false) }
    func showSignature() { requestSignature(trigger: nil) }

    func typed(_ character: String?) {
        acceptanceTask?.cancel()
        guard let state = context(), let editor, let caret else {
            dismiss()
            return
        }
        let memberTrigger = character.flatMap { state.session.completionTriggers.contains($0) ? $0 : nil }
        let signatureTrigger = character.flatMap {
            state.session.signatureTriggers.contains($0) || (signature != nil && state.session.signatureRetriggers.contains($0)) ? $0 : nil
        }
        let continuesWord = character.map(Self.isIdentifier) ?? (completion != nil || completionTask != nil)
        let prefixLength = Self.prefix(in: editor.string as NSString, endingAt: caret).length
        if memberTrigger != nil || (continuesWord && (completion != nil || completionTask != nil || prefixLength >= 2)) {
            requestCompletion(trigger: memberTrigger, delay: memberTrigger == nil)
        } else {
            closeCompletion()
        }
        if signatureTrigger != nil || signature != nil || signatureTask != nil {
            requestSignature(trigger: signatureTrigger)
        }
    }

    func selectionChanged() {
        if caret != trackedCaret { dismiss() }
    }

    func contextChanged() {
        dismiss()
        formatTask?.cancel()
        lastBufferEdit = nil
    }

    func bufferChanged(whileTyping: Bool) {
        if !whileTyping { contextChanged() }
        lastBufferEdit = .now
    }

    @discardableResult
    func dismiss() -> Bool {
        let hadAssistance = isPresenting || completionTask != nil || signatureTask != nil || acceptanceTask != nil
        closeSignature()
        closeCompletion()
        acceptanceTask?.cancel()
        acceptanceTask = nil
        trackedCaret = nil
        return hadAssistance
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              var completion, isCurrent(completion.context, caret: completion.caret) else { return false }
        switch event.keyCode {
        case 125, 126:
            let direction = event.keyCode == 125 ? 1 : -1
            completion.selected = min(max(0, completion.selected + direction), completion.items.count - 1)
            self.completion = completion
            choices.select(completion.selected)
        case 36, 48, 76:
            accept(completion.selected)
        default:
            return false
        }
        return true
    }

    func viewportChanged() {
        guard isPresenting, let editor, let caret,
              let owner = editor.window, let anchor = Self.anchor(for: caret, in: editor) else {
            if isPresenting {
                completionPopup.close()
                signaturePopup.close()
            }
            return
        }
        if let completion {
            let start = Self.anchor(for: completion.range.location, in: editor) ?? anchor
            completionPopup.show(choices.view, anchoredAt: start, in: owner, appearance: editor.effectiveAppearance)
        }
        if signature != nil, let signatureView {
            signaturePopup.show(signatureView, anchoredAt: anchor, in: owner, appearance: editor.effectiveAppearance,
                                avoiding: completion == nil ? nil : completionPopup.frame)
        }
    }

    private func requestCompletion(trigger: String?, delay: Bool) {
        guard let state = context(), state.session.supportsCompletion, let editor, let caret else { return }
        trackedCaret = caret
        let incomplete = trigger == nil && completion?.isIncomplete == true
        let range = Self.prefix(in: editor.string as NSString, endingAt: caret)
        let prefix = (editor.string as NSString).substring(with: range)
        completionTask?.cancel()
        if completion != nil, completionExpiry == nil {
            choices.setPending(true)
            completionExpiry = Task { [weak self] in
                do { try await Task.sleep(for: Self.staleInterval) } catch { return }
                self?.clearCompletion()
            }
        }
        completionTask = Task { [weak self, weak editor] in
            if delay {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            let result = try? await state.session.completion(at: caret, trigger: trigger, retriggering: incomplete)
            guard let self, !Task.isCancelled else { return }
            completionTask = nil
            guard isCurrent(state, caret: caret), let result, !result.items.isEmpty else {
                clearCompletion()
                return
            }
            let items = Self.orderedItems(result.items, prefix: prefix)
            let previous = completion.map { $0.items[$0.selected].label }
            let selected = items.firstIndex { $0.label == previous } ?? 0
            completionExpiry?.cancel()
            completionExpiry = nil
            completion = Completion(context: state, caret: caret, range: range, items: items,
                                    isIncomplete: result.isIncomplete, selected: selected)
            choices.update(items, selected: selected)
            editor?.invalidateLanguageInteraction()
            viewportChanged()
        }
    }

    private func requestSignature(trigger: String?) {
        guard let state = context(), state.session.supportsSignatureHelp, let caret else { return }
        trackedCaret = caret
        let active = signature != nil
        let analyzingEdit = lastBufferEdit.map { $0.duration(to: .now) < .seconds(1) } == true || trigger != nil
        signatureTask?.cancel()
        if signature != nil, signatureExpiry == nil {
            signatureExpiry = Task { [weak self] in
                do { try await Task.sleep(for: Self.staleInterval) } catch { return }
                self?.clearSignature()
            }
        }
        signatureTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { signatureTask = nil } }
            var result: LSPSignatureHelp?
            do {
                result = try await state.session.signatureHelp(at: caret, trigger: trigger, retriggering: active)
                if analyzingEdit {
                    // Solar returns null while its debounced source analysis is pending.
                    for delay in [Duration.milliseconds(220), .milliseconds(280), .milliseconds(500)] where result == nil {
                        try await Task.sleep(for: delay)
                        guard isCurrent(state, caret: caret) else { return }
                        result = try await state.session.signatureHelp(at: caret, retriggering: active)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                result = nil
            }
            guard !Task.isCancelled else { return }
            guard isCurrent(state, caret: caret), let result, !result.signatures.isEmpty else {
                clearSignature()
                return
            }
            let index = result.activeSignature ?? 0
            let entry = result.signatures[result.signatures.indices.contains(index) ? index : 0]
            let active = entry.activeParameter ?? result.activeParameter ?? 0
            let value = entry.parameters.flatMap { $0.indices.contains(active) ? $0[active] : nil }
            let parameter = Self.parameterRange(entry, active: active)
            signatureExpiry?.cancel()
            signatureExpiry = nil
            let signature = Signature(label: entry.label, parameter: parameter,
                                      documentation: value?.documentation ?? entry.documentation)
            self.signature = signature
            signatureView = Self.signatureView(for: signature)
            editor?.invalidateLanguageInteraction()
            viewportChanged()
        }
    }

    private var signatureView: NSView?

    private func accept(_ row: Int) {
        guard let completion, completion.items.indices.contains(row),
              isCurrent(completion.context, caret: completion.caret) else { return }
        let item = completion.items[row]
        closeCompletion()
        acceptanceTask?.cancel()
        acceptanceTask = Task { [weak self] in
            let resolved = (try? await completion.context.session.resolveCompletion(item)) ?? item
            guard let self, !Task.isCancelled else { return }
            acceptanceTask = nil
            guard let editor, isCurrent(completion.context, caret: completion.caret) else { return }
            do {
                try insert(resolved, from: completion, in: editor)
            } catch {
                editor.showLanguageFeedback(error.localizedDescription, at: completion.range)
            }
        }
    }

    private func insert(_ item: LSPCompletionItem, from completion: Completion, in editor: EditorTextView) throws {
        let text = editor.string
        let index = LSPTextIndex(text)
        let edit: EditorTextEdit
        if let serverEdit = item.textEdit {
            guard let range = index.nsRange(serverEdit.insertRange, clampingColumns: false),
                  range.location <= completion.caret, completion.caret <= range.upperBound else {
                throw LSPFailure.invalidMessage
            }
            edit = EditorTextEdit(range: range, text: serverEdit.newText)
        } else {
            edit = EditorTextEdit(range: completion.range, text: item.insertText ?? item.label)
        }
        // Without the snippet capability, a snippet would appear as source code.
        guard item.insertTextFormat != 2 else { throw LSPFailure.invalidMessage }
        let additional = try Self.edits(item.additionalTextEdits ?? [], in: index)
        let edits = try Self.orderedEdits(additional + [edit])
        let preceding = additional.lazy.filter { $0.range.location < edit.range.location }.reduce(0) { $0 + $1.lengthChange }
        let end = edit.range.location + preceding + edit.text.utf16.count
        Self.apply(edits, selections: [NSRange(location: end, length: 0)], named: "Complete", in: editor)
    }

    func format() {
        guard canFormat, let state = context(), let editor else { return }
        dismiss()
        let text = editor.string
        formatTask?.cancel()
        formatTask = Task { [weak self] in
            do {
                let raw = try await state.session.formatting(tabSize: 4, insertSpaces: true)
                let edits = try await Self.formattingEdits(raw, in: text)
#if EDIT_AGENT_CHECKS
                if let beforeFormat = editor.beforeApplyLanguageFormattingForCheck { await beforeFormat() }
#endif
                guard let self, context() == state, !Task.isCancelled, canFormat else { return }
                let selections = MultiCaretEditing.mapped(editor.caretSelections, after: edits)
                Self.apply(edits, selections: selections, named: "Format Document", in: editor)
            } catch is CancellationError {
                return
            } catch {
                guard let self, context() == state, !Task.isCancelled else { return }
                editor.showLanguageFeedback("Could not format the document: \(error.localizedDescription)", at: editor.selectedRange())
            }
        }
    }

    private static func apply(_ edits: [EditorTextEdit], selections: [NSRange], named name: String, in editor: EditorTextView) {
        // The replies arrive between input events. Keep AppKit's event group intact for the next keystroke.
        if editor.applyMultiEdits(edits, selections: selections) { editor.undoManager?.setActionName(name) }
    }

    private func isCurrent(_ state: Context, caret: Int) -> Bool {
        context() == state && self.caret == caret
    }

    private func clearCompletion() {
        completionExpiry?.cancel()
        completionExpiry = nil
        completion = nil
        completionPopup.close()
        viewportChanged()
    }

    private func closeCompletion() {
        completionTask?.cancel()
        completionTask = nil
        clearCompletion()
    }

    private func clearSignature() {
        signatureExpiry?.cancel()
        signatureExpiry = nil
        signature = nil
        signatureView = nil
        signaturePopup.close()
    }

    private func closeSignature() {
        signatureTask?.cancel()
        signatureTask = nil
        clearSignature()
    }

    private static func isIdentifier(_ character: String) -> Bool {
        character.utf16.count == 1 && isIdentifier(character.utf16.first ?? 0)
    }

    private static func isIdentifier(_ character: UInt16) -> Bool {
        (65...90).contains(character) || (97...122).contains(character) || (48...57).contains(character) ||
            character == 95 || character == 36
    }

    private static func prefix(in text: NSString, endingAt caret: Int) -> NSRange {
        var start = min(caret, text.length)
        while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: caret - start)
    }

    private static func orderedItems(_ items: [LSPCompletionItem], prefix: String) -> [LSPCompletionItem] {
        let prefix = prefix.lowercased()
        let usesSortKeys = items.contains { $0.sortText != nil }
        return items.enumerated().sorted { first, second in
            let left = first.element
            let right = second.element
            let leftMatches = (left.filterText ?? left.label).lowercased().hasPrefix(prefix)
            let rightMatches = (right.filterText ?? right.label).lowercased().hasPrefix(prefix)
            if leftMatches != rightMatches { return leftMatches }
            if usesSortKeys {
                let left = left.sortText ?? left.label
                let right = right.sortText ?? right.label
                if left != right { return left < right }
            }
            return first.offset < second.offset
        }.map(\.element)
    }

    private static func parameterRange(_ signature: LSPSignatureHelp.Signature, active: Int) -> NSRange? {
        guard let parameters = signature.parameters, parameters.indices.contains(active) else { return nil }
        let label = signature.label as NSString
        switch parameters[active].label {
        case .range(let range):
            return range.location >= 0 && range.location <= label.length && range.length > 0 &&
                range.length <= label.length - range.location ? range : nil
        case .string:
            // Search successive labels in order to distinguish parameters with identical type labels.
            var start = label.range(of: "(").location
            start = start == NSNotFound ? 0 : start + 1
            for (index, parameter) in parameters.prefix(active + 1).enumerated() {
                guard case .string(let name) = parameter.label, !name.isEmpty else { continue }
                let found = label.range(of: name, options: .literal,
                                        range: NSRange(location: start, length: label.length - start))
                guard found.location != NSNotFound else { return nil }
                if index == active { return found }
                start = found.upperBound
            }
            return nil
        }
    }

    private static func anchor(for caret: Int, in editor: EditorTextView) -> NSRect? {
        guard let window = editor.window else { return nil }
        var rect = editor.firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        guard rect.height > 0 else { return nil }
        rect.size.width = 2
        let viewport = editor.convert(editor.visibleRect, to: nil).intersection(window.contentLayoutRect)
        let anchor = rect.intersection(window.convertToScreen(viewport))
        return anchor.isEmpty ? nil : anchor
    }

    private static func signatureView(for signature: Signature) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let label = NSMutableAttributedString(string: signature.label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let parameter = signature.parameter {
            label.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                                 .underlineStyle: NSUnderlineStyle.single.rawValue], range: parameter)
        }
        let width = min(520, max(210, ceil(label.size().width) + 24))
        let textWidth = width - 24
        let code = NSTextField(wrappingLabelWithString: "")
        code.attributedStringValue = label
        code.setAccessibilityLabel(signature.label)
        let height = code.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 140)).height ?? 18
        var contentsHeight = height + 18
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentsHeight))
        if let documentation = signature.documentation, !documentation.value.isEmpty {
            let attributed = EditorHoverContent(text: documentation.value, isMarkdown: documentation.isMarkdown)
                .attributedText(maximumWidth: textWidth)
            let text = NSTextField(wrappingLabelWithString: "")
            text.attributedStringValue = attributed
            text.maximumNumberOfLines = 4
            let detailHeight = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 90)).height ?? 18
            text.frame = NSRect(x: 12, y: 9, width: textWidth, height: min(detailHeight, 76))
            view.addSubview(text)
            contentsHeight += text.frame.height + 6
            view.setFrameSize(NSSize(width: width, height: contentsHeight))
        }
        code.frame = NSRect(x: 12, y: contentsHeight - height - 9, width: textWidth, height: height)
        view.addSubview(code)
        return view
    }

    private nonisolated static func edits(_ items: [LSPTextEdit], in index: LSPTextIndex) throws -> [EditorTextEdit] {
        try items.map { item in
            guard let range = index.nsRange(item.range, clampingColumns: false) else { throw LSPFailure.invalidMessage }
            return EditorTextEdit(range: range, text: item.newText)
        }
    }

    private nonisolated static func orderedEdits(_ edits: [EditorTextEdit]) throws -> [EditorTextEdit] {
        let edits = edits.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        guard zip(edits, edits.dropFirst()).allSatisfy({ first, second in
            first.range.upperBound <= second.range.location && first.range.location != second.range.location
        }) else { throw LSPFailure.invalidMessage }
        return edits
    }

    @concurrent private static func formattingEdits(_ raw: [LSPTextEdit], in text: String) async throws -> [EditorTextEdit] {
        let edits = try orderedEdits(edits(raw, in: LSPTextIndex(text)))
        let original = text as NSString
        return edits.flatMap { edit -> [EditorTextEdit] in
            let old = original.substring(with: edit.range)
            if old.utf8.elementsEqual(edit.text.utf8) { return [] }
            if let spaces = whitespaceEdits(in: old, replacingWith: edit.text, at: edit.range.location) { return spaces }
            let hunks = JJLineDiff.analyze(base: old, current: edit.text, isConflicted: false, recordedConflict: nil).hunks
            if hunks.isEmpty { return [edit] }
            return hunks.flatMap { hunk in
                let start = edit.range.location + hunk.baseRange.location
                return whitespaceEdits(in: hunk.removedText, replacingWith: hunk.insertedText, at: start)
                    ?? [EditorTextEdit(range: NSRange(location: start, length: hunk.baseRange.length), text: hunk.insertedText)]
            }
        }
    }

    // Forge can return a whole-document edit for whitespace changes. Keep the carets on their tokens.
    private nonisolated static func whitespaceEdits(in old: String, replacingWith new: String,
                                                    at location: Int) -> [EditorTextEdit]? {
        let old = old as NSString
        let new = new as NSString
        var left = 0
        var right = 0
        var edits: [EditorTextEdit] = []
        while left < old.length || right < new.length {
            let start = left
            let replacementStart = right
            while left < old.length, isFormattingWhitespace(old.character(at: left)) { left += 1 }
            while right < new.length, isFormattingWhitespace(new.character(at: right)) { right += 1 }
            let range = NSRange(location: start, length: left - start)
            let replacement = new.substring(with: NSRange(location: replacementStart, length: right - replacementStart))
            if old.substring(with: range) != replacement {
                edits.append(EditorTextEdit(range: NSRange(location: location + start, length: range.length), text: replacement))
            }
            if left == old.length, right == new.length { break }
            guard left < old.length, right < new.length, old.character(at: left) == new.character(at: right) else { return nil }
            left += 1
            right += 1
        }
        return edits
    }

    private nonisolated static func isFormattingWhitespace(_ code: UInt16) -> Bool {
        code == 32 || code == 9 || code == 10 || code == 13
    }

#if EDIT_AGENT_CHECKS
    var completionLabelsForCheck: [String] { completion?.items.map(\.label) ?? [] }
    var signatureLabelForCheck: String? { signature?.label }
    var signatureParameterForCheck: NSRange? { signature?.parameter }
    var completionFrameForCheck: NSRect? { completionPopup.frame }
    var signatureFrameForCheck: NSRect? { signaturePopup.frame }
#endif
}
