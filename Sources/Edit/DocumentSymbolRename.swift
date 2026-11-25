import AppKit

@MainActor
final class DocumentSymbolRename {
    private struct Source: Sendable {
        let url: URL
        let root: URL
        let server: LanguageServer
        let language: SyntaxLanguage
        let text: String
        let generation: Int
        let revision: Int
        let openGeneration: UInt64
        let selection: NSRange
        let offset: Int
    }

    private struct Target {
        let source: Source
        let range: NSRange
        let name: String
        let spelling: String
    }

    private struct Submission {
        let draft: String
        let caretOffset: Int
        let name: String
        private let namePrefixBytes: Int
        private let language: SyntaxLanguage

        init(draft: String, caretOffset: Int, language: SyntaxLanguage, quoted: Bool) {
            self.draft = draft
            self.caretOffset = caretOffset
            self.language = language
            let caret = String.Index(utf16Offset: caretOffset, in: draft)
            let draftPrefixBytes = draft[..<caret].utf8.count
            var decodedPrefixBytes = 0
            if quoted, let decoded = ZigRenameName.decoded("@\"\(draft)\"", onQuoteBoundary: { spellingBytes, nameBytes in
                if spellingBytes <= draftPrefixBytes { decodedPrefixBytes = nameBytes }
            }) {
                name = decoded
                namePrefixBytes = decodedPrefixBytes
            } else {
                name = draft
                namePrefixBytes = draftPrefixBytes
            }
        }

        func offset(in spelling: String) -> Int {
            if language == .swift {
                let quoteDelta = (spelling.hasPrefix("`") ? 1 : 0) - (draft.hasPrefix("`") ? 1 : 0)
                return min(max(0, caretOffset + quoteDelta), spelling.utf16.count)
            }
            guard language == .zig else { return min(caretOffset, spelling.utf16.count) }
            guard spelling.hasPrefix("@\"") else {
                return min(namePrefixBytes, spelling.utf16.count)
            }
            // ZLS can add quotes and escapes to the spelling shown in the draft.
            let body = spelling.utf8.dropFirst(2).dropLast()
            if body.elementsEqual(draft.utf8) { return 2 + caretOffset }
            var spellingPrefixBytes = 0
            _ = ZigRenameName.decoded(spelling, onQuoteBoundary: { spellingBytes, nameBytes in
                if nameBytes <= namePrefixBytes { spellingPrefixBytes = spellingBytes }
            })
            let index = spelling.utf8.index(body.startIndex, offsetBy: spellingPrefixBytes)
            return index.utf16Offset(in: spelling)
        }

        func selection(in target: NSRange, after edits: [EditorTextEdit]) -> NSRange? {
            var delta = 0
            for edit in edits {
                guard edit.range.location <= target.location else { break }
                if target.upperBound <= edit.range.upperBound {
                    let replacement = edit.result(at: delta)
                    return NSRange(location: replacement.location + offset(in: edit.text), length: 0)
                }
                delta += edit.lengthChange
            }
            return nil
        }
    }

    private struct FileChange: Sendable {
        let url: URL
        let original: String
        let updated: String
        let edits: [EditorTextEdit]
        let disk: FileBuffer?
    }

    private struct RenameFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private weak var document: DocumentWindow?
    private weak var app: Edit?
    private var task: Task<Void, Never>?
    private var target: Target?
    private var operation: UUID?
    private var isCommitting = false

    init(document: DocumentWindow, app: Edit) {
        self.document = document
        self.app = app
    }

    var canStart: Bool {
        guard operation == nil, let document, let app, !app.isQuitting,
              document.languageFeatures.session.supportsRename else { return false }
        let editor = document.editor
        return document.hasEditableTextDocument && document.canReplaceBuffer && editor.isEditable &&
            !editor.hasMarkedText() && editor.conflictEdits.isEmpty && editor.jjInlineDiff?.projectedEditRange == nil
    }

    func start(at hit: EditorLanguageInteraction.Hit? = nil) -> Bool {
        if operation != nil { return true }
        guard canStart, let document, let url = document.fileURL,
              let selection = document.editor.caretSelections.last else { return false }
        let session = document.languageFeatures.session
        guard let root = session.workspaceRoot else { return false }
        let editor = document.editor
        let source = Source(url: url, root: root, server: session.server, language: document.resolvedSyntaxLanguage,
                            text: editor.string, generation: session.generation,
                            revision: session.revision, openGeneration: document.openRequestGeneration,
                            selection: selection, offset: hit?.offset ?? editor.activeEnd(of: selection))
        let anchor = hit?.word ?? selection
        let id = UUID()
        operation = id
        editor.isRenamingSymbol = true
        editor.invalidateLanguageInteraction()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if operation == id { task = nil } }
            do {
                let prepared = try await session.prepareRename(at: source.offset)
                guard isCurrent(id, source: source), document.window.firstResponder === editor,
                      editor.caretSelections.last == source.selection else {
                    if operation == id { finish() }
                    return
                }
                let index = LSPTextIndex(source.text)
                guard let prepared, let range = index.nsRange(prepared.range, clampingColumns: false),
                      range.length > 0, editor.focusAllowsEdits([range]) else {
                    finish()
                    editor.showLanguageFeedback("No symbol to rename", at: anchor)
                    return
                }
                let text = source.text as NSString
                let sourceName = text.substring(with: range)
                let quoted = source.server == .zig && range.location >= 2 && range.upperBound < text.length &&
                    text.substring(with: NSRange(location: range.location - 2, length: 2)) == "@\"" &&
                    text.character(at: range.upperBound) == 34
                let spelling = quoted ? "@\"\(sourceName)\"" : sourceName
                let name = if source.server == .zig {
                    ZigRenameName.decoded(spelling) ?? prepared.placeholder ?? sourceName
                } else {
                    sourceName
                }
                if source.language == .swift, !SwiftRenameName.isValid(sourceName) {
                    finish()
                    editor.showLanguageFeedback("Select a Swift symbol name to rename", at: anchor)
                    return
                }
                if source.language != .swift, source.language != .zig, !ClangRenameName.isIdentifier(sourceName) {
                    finish()
                    editor.showLanguageFeedback("Select a single identifier to rename", at: anchor)
                    return
                }
                guard editor.beginSymbolRename(in: range, source: source.text) else {
                    finish()
                    return
                }
                target = Target(source: source, range: range, name: name, spelling: spelling)
            } catch {
                let report = isCurrent(id, source: source)
                if operation == id { finish() }
                if report { editor.showLanguageFeedback(error.localizedDescription, at: anchor) }
            }
        }
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        guard operation != nil, !isCommitting else { return false }
        finish()
        return true
    }

    private func finish() {
        operation = nil
        task?.cancel()
        task = nil
        target = nil
        document?.editor.endSymbolRename()
        document?.editor.isRenamingSymbol = false
    }

    private func isCurrent(_ id: UUID, source: Source) -> Bool {
        guard !Task.isCancelled, operation == id, let document, let app, !app.isQuitting else { return false }
        let session = document.languageFeatures.session
        return document.fileURL == source.url && document.hasEditableTextDocument && document.window.attachedSheet == nil &&
            !document.editor.hasMarkedText() && document.editor.conflictEdits.isEmpty &&
            session.server == source.server && session.revision == source.revision && session.generation == source.generation &&
            document.openRequestGeneration == source.openGeneration
    }

    func submit() {
        guard let target, let id = operation, let document, isCurrent(id, source: target.source),
              let draft = document.editor.symbolRenameText, let range = document.editor.renameRange else {
            cancel()
            return
        }
        let editor = document.editor
        let selection = editor.selectedRange()
        let caret = editor.selectionAffinity == .upstream ? selection.location : selection.upperBound
        let offset = min(max(caret, range.location), range.upperBound) - range.location
        let language = target.source.language
        let submission = Submission(draft: draft, caretOffset: offset, language: language,
                                    quoted: target.spelling.hasPrefix("@\""))
        let name = submission.name
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              language != .swift || SwiftRenameName.isValid(name),
              language == .swift || language == .zig || ClangRenameName.isIdentifier(name),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            NSSound.beep()
            return
        }
        guard !name.utf8.elementsEqual(target.name.utf8) else {
            finish()
            let quotePrefix = target.spelling.utf16.count == target.range.length ? 0 : 2
            let location = target.range.location + submission.offset(in: target.spelling) - quotePrefix
            editor.setCaretSelections(editor.caretSelections.dropLast() + [NSRange(location: location, length: 0)], record: false)
            return
        }
        guard editor.lockSymbolRename() else { return }
        let session = document.languageFeatures.session
        task = Task { [weak self] in
            guard let self else { return }
            defer { if operation == id { finish() } }
            do {
                guard let edit = try await session.rename(at: target.source.offset, to: name),
                      !edit.documents.isEmpty else { throw RenameFailure("\(session.server.name) found no edits for this symbol.") }
                try await apply(edit, to: target, submission: submission, id: id)
            } catch {
                if operation == id, !Task.isCancelled {
                    finish()
                    document.editor.showLanguageFeedback(error.localizedDescription, at: target.range)
                }
            }
        }
    }

    private func apply(_ edit: LSPWorkspaceEdit, to target: Target, submission: Submission, id: UUID) async throws {
        let source = target.source
        let spelling = target.spelling
        let oldName = target.name
        let newName = submission.name
        let build = Task.detached(priority: .userInitiated) {
            try Self.plan(edit, source: source, spelling: spelling, oldName: oldName, newName: newName)
        }
        let files = try await withTaskCancellationHandler {
            try await build.value
        } onCancel: { build.cancel() }
        guard let app, isCurrent(id, source: source) else { throw CancellationError() }
        try await app.performWorktreeMutation(affecting: files.map(\.url), preservingRenameIn: document) {
            guard isCurrent(id, source: source) else { throw CancellationError() }
            var open: [(DocumentWindow, FileChange)] = []
            var closed: [FileChange] = []
            for file in files {
                let windows = app.documents.filter { $0.fileURL == file.url && $0.hasEditableTextDocument }
                if windows.isEmpty {
                    guard file.disk != nil else { throw CancellationError() }
                    closed.append(file)
                }
                for document in windows {
                    let editor = document.editor
                    guard editor.textStorage != nil, !editor.hasMarkedText(), editor.conflictEdits.isEmpty,
                          editor.jjInlineDiff?.projectedEditRange == nil,
                          editor.sourceString.utf8.elementsEqual(file.original.utf8) else {
                        throw RenameFailure("“\(file.url.lastPathComponent)” has edits that \(source.server.name) has not seen.")
                    }
                    guard editor.focusAllowsSourceEdits(file.edits.map(\.range)) else {
                        throw RenameFailure("Exit Focus in “\(file.url.lastPathComponent)” to rename this symbol.")
                    }
                    open.append((document, file))
                }
            }
            isCommitting = true
            defer { isCommitting = false }
            let diskChanges = closed
            let results = try await Task.detached(priority: .userInitiated) { try Self.write(diskChanges) }.value
            for result in results {
                if let previous = result.replacedIdentity, let current = result.file.identity {
                    for document in app.documents { document.worktreeSidebar?.fileReplaced(previous, with: current) }
                }
            }
            for (document, file) in open {
                let editor = document.editor
                if document === self.document { editor.endSymbolRename() }
                let current = editor.caretSelections
                var selections = MultiCaretEditing.mapped(current, after: file.edits)
                if document === self.document, current.last == source.selection,
                   let caret = submission.selection(in: target.range, after: file.edits) {
                    selections[selections.count - 1] = caret
                }
                editor.applyMultiEdits(file.edits, selections: selections, validate: false, actionName: "Rename Symbol")
            }
        }
    }

    private nonisolated static func plan(_ edit: LSPWorkspaceEdit, source: Source, spelling: String,
                                         oldName: String, newName: String) throws -> [FileChange] {
        let origin = FileBuffer.canonicalURL(source.url)
        let root = FileBuffer.canonicalURL(source.root)
        let serverName = source.server.name
        var files: [FileChange] = []
        var documents: [URL: LSPDocumentEdits] = [:]
        for document in edit.documents where !document.edits.isEmpty {
            try Task.checkCancellation()
            let url = FileBuffer.canonicalURL(document.url)
            guard url.isFileURL, url.pathComponents.starts(with: root.pathComponents) else {
                throw RenameFailure("\(serverName) returned “\(url.lastPathComponent)” outside the project.")
            }
            if let previous = documents[url] {
                // SourceKit-LSP can report both an open-document URI and an index path for the same file.
                guard source.server == .sourceKit,
                      previous.version == nil || document.version == nil || previous.version == document.version else {
                    throw RenameFailure("\(serverName) listed incompatible edits for “\(url.lastPathComponent)”.")
                }
                documents[url] = LSPDocumentEdits(url: url, version: previous.version ?? document.version,
                                                 edits: previous.edits + document.edits)
            } else {
                documents[url] = document
            }
        }
        var validatedSpellings: Set<Data> = []
        for url in documents.keys.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard let document = documents[url] else { continue }
            let isOrigin = url == origin
            if let version = document.version, !isOrigin || version != source.revision {
                throw RenameFailure("“\(url.lastPathComponent)” changed after \(serverName) prepared the rename.")
            }
            let disk = isOrigin ? nil : try FileBuffer.read(url)
            let original = disk?.text ?? source.text
            let text = original as NSString
            let index = LSPTextIndex(original)
            var edits: [EditorTextEdit] = []
            for edit in document.edits {
                guard let range = index.nsRange(edit.range, clampingColumns: false) else {
                    throw RenameFailure("\(serverName) returned an invalid symbol range in “\(url.lastPathComponent)”.")
                }
                if source.language == .swift {
                    guard SwiftRenameName.matchesEdit(in: text, range: range, replacement: edit.newText,
                                                      oldName: oldName, newName: newName) else {
                        throw RenameFailure("The rename no longer matches the Swift symbol in “\(url.lastPathComponent)”.")
                    }
                    edits.append(EditorTextEdit(range: range, text: edit.newText))
                    continue
                }
                if source.language != .zig {
                    guard ClangRenameName.matchesEdit(in: text, range: range, replacement: edit.newText,
                                                       oldName: oldName, newName: newName) else {
                        throw RenameFailure("The rename no longer matches the symbol in “\(url.lastPathComponent)”.")
                    }
                    edits.append(EditorTextEdit(range: range, text: edit.newText))
                    continue
                }
                let old = text.substring(with: range)
                guard range.length > 0, ZigRenameName.isToken(old, at: range, in: text),
                      old.utf8.elementsEqual(spelling.utf8) || ZigRenameName.decoded(old)?.utf8.elementsEqual(oldName.utf8) == true else {
                    throw RenameFailure("The symbol in “\(url.lastPathComponent)” has changed.")
                }
                if validatedSpellings.insert(Data(edit.newText.utf8)).inserted {
                    guard ZigRenameName.decoded(edit.newText)?.utf8.elementsEqual(newName.utf8) == true else {
                        throw RenameFailure("\(serverName) did not return a valid spelling for the new symbol name.")
                    }
                }
                edits.append(EditorTextEdit(range: range, text: edit.newText))
            }
            edits.sort { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
            var unique: [EditorTextEdit] = []
            for edit in edits {
                if let previous = unique.last {
                    if previous.range == edit.range, previous.text.utf8.elementsEqual(edit.text.utf8) { continue }
                    guard previous.range.upperBound <= edit.range.location else {
                        throw RenameFailure("\(serverName) returned overlapping edits in “\(url.lastPathComponent)”.")
                    }
                }
                unique.append(edit)
            }
            let updated = NSMutableString(string: original)
            for edit in unique.reversed() { updated.replaceCharacters(in: edit.range, with: edit.text) }
            files.append(FileChange(url: url, original: original, updated: updated as String, edits: unique, disk: disk))
        }
        guard !files.isEmpty else { throw RenameFailure("\(serverName) found no edits for this symbol.") }
        return files
    }

    private nonisolated static func write(_ changes: [FileChange]) throws -> [FileBuffer.SaveResult] {
        var written: [(original: FileBuffer, result: FileBuffer.SaveResult)] = []
        do {
            for change in changes {
                guard let disk = change.disk else { throw CancellationError() }
                let result = try FileBuffer.save(change.updated, to: change.url, format: disk.format, expected: disk.revision)
                written.append((disk, result))
            }
        } catch {
            var unrecovered: [String] = []
            for (original, result) in written.reversed() {
                do {
                    _ = try FileBuffer.save(original.text, to: original.url, format: original.format, expected: result.file.revision)
                } catch {
                    unrecovered.append(original.url.lastPathComponent)
                }
            }
            if !unrecovered.isEmpty {
                throw RenameFailure("Could not restore \(unrecovered.joined(separator: ", ")) after a rename failed.")
            }
            throw error
        }
        return written.map(\.result)
    }
}

private enum ClangRenameName {
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || first == "$" || first.properties.isXIDStart else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy(isIdentifierContinuation)
    }

    static func matchesEdit(in text: NSString, range: NSRange, replacement: String,
                            oldName: String, newName: String) -> Bool {
        guard text.substring(with: range).utf8.elementsEqual(oldName.utf8),
              replacement.utf8.elementsEqual(newName.utf8) else { return false }
        for offset in [range.location - 1, range.upperBound] where offset >= 0 && offset < text.length {
            let neighbor = text.substring(with: text.rangeOfComposedCharacterSequence(at: offset))
            if neighbor.unicodeScalars.contains(where: isIdentifierContinuation) { return false }
        }
        return true
    }

    private static func isIdentifierContinuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "$" || scalar.properties.isXIDContinue
    }
}

private enum SwiftRenameName {
    private static let reserved = Set("""
        associatedtype class deinit enum extension fileprivate func import init inout internal let open
        operator precedencegroup private protocol public rethrows static struct subscript typealias var
        break case catch continue default defer do else fallthrough for guard if in repeat return switch
        throw where while as Any false is nil self Self super throws true try _
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func isValid(_ spelling: String) -> Bool {
        let name = unquoted(spelling)
        guard let first = name.first else { return false }
        if first.isLetter || first == "_" || isSymbolicIdentifier(first) {
            return name.allSatisfy(isIdentifierCharacter) && (name != spelling || !reserved.contains(name))
        }
        return name == spelling && !name.contains("//") && !name.contains("/*") && !name.contains("*/")
            && name.allSatisfy(isOperatorCharacter)
    }

    static func matchesEdit(in text: NSString, range: NSRange, replacement: String,
                            oldName: String, newName: String) -> Bool {
        var spelling = replacement
        var token = range
        if range.length == 0 {
            // Renaming a local parameter can insert a second name after its external label.
            guard replacement.hasPrefix(" "), range.location >= oldName.utf16.count else { return false }
            spelling.removeFirst()
            token = NSRange(location: range.location - oldName.utf16.count, length: oldName.utf16.count)
        }
        let oldSpelling = text.substring(with: token)
        guard unquoted(oldSpelling).utf8.elementsEqual(unquoted(oldName).utf8),
              unquoted(spelling).utf8.elementsEqual(unquoted(newName).utf8),
              isValid(spelling) else { return false }
        let continues = unquoted(oldName).first.map(isOperatorCharacter) == true
            ? isOperatorCharacter : isIdentifierCharacter
        for offset in [token.location - 1, token.upperBound] where offset >= 0 && offset < text.length {
            let neighbor = text.substring(with: text.rangeOfComposedCharacterSequence(at: offset))
            if let first = neighbor.first, continues(first) { return false }
        }
        return true
    }

    private static func unquoted(_ name: String) -> String {
        if name.count > 1, name.hasPrefix("`"), name.hasSuffix("`") { return String(name.dropFirst().dropLast()) }
        return name
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || isSymbolicIdentifier(character)
    }

    private static func isSymbolicIdentifier(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { $0.properties.generalCategory == .otherSymbol } == true
    }

    private static func isOperatorCharacter(_ character: Character) -> Bool {
        "/=-+!*%<>&|^~?.".contains(character) ||
            character.unicodeScalars.first.map { $0.properties.generalCategory == .mathSymbol } == true
    }
}

private enum ZigRenameName {
    private static let reserved = Set("""
        _ addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum
        errdefer error export extern fn for if inline noalias noinline nosuspend opaque or orelse packed pub resume return
        linksection struct suspend switch test threadlocal try union unreachable var volatile while anyerror anyopaque
        bool c_char c_short c_ushort c_int c_uint c_long c_ulong c_longlong c_ulonglong c_longdouble comptime_float
        comptime_int f16 f32 f64 f80 f128 false isize noreturn null true type undefined usize void
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func decoded(_ spelling: String, onQuoteBoundary: ((Int, Int) -> Void)? = nil) -> String? {
        let bytes = spelling.utf8
        guard bytes.starts(with: [64, 34]) else {
            guard let first = bytes.first, isLetter(first), bytes.dropFirst().allSatisfy({
                isLetter($0) || (48...57).contains($0)
            }), !reserved.contains(spelling) else { return nil }
            if (first == 105 || first == 117), bytes.count > 1, bytes.dropFirst().allSatisfy({ (48...57).contains($0) }) {
                return nil
            }
            return spelling
        }
        guard bytes.count >= 3, bytes.last == 34 else { return nil }

        // Zig quotes names with string-literal escapes. Compare the decoded bytes so the
        // same name can be written with either a bare identifier or an escaped spelling.
        var source = bytes.dropFirst(2).dropLast().makeIterator()
        var result: [UInt8] = []
        var spellingBytes = 0
        func nextByte() -> UInt8? {
            guard let byte = source.next() else { return nil }
            spellingBytes += 1
            return byte
        }
        while let byte = nextByte() {
            switch byte {
            case 34, 0...31, 127: return nil
            case 92:
                switch nextByte() {
                case 34: result.append(34)
                case 39: result.append(39)
                case 92: result.append(92)
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 120:
                    guard let first = nextByte(), let high = hexValue(first),
                          let second = nextByte(), let low = hexValue(second) else { return nil }
                    result.append(UInt8(16 * high + low))
                case 117:
                    guard nextByte() == 123 else { return nil }
                    var digits = 0
                    var value: UInt32 = 0
                    var next = nextByte()
                    while let byte = next, let digit = hexValue(byte), digits < 6 {
                        digits += 1
                        value = 16 * value + digit
                        next = nextByte()
                    }
                    guard next == 125, digits > 0, let scalar = UnicodeScalar(value) else { return nil }
                    result.append(contentsOf: String(scalar).utf8)
                default: return nil
                }
            default:
                result.append(byte)
            }
            onQuoteBoundary?(spellingBytes, result.count)
        }
        return String(validating: result, as: UTF8.self)
    }

    static func isToken(_ spelling: String, at range: NSRange, in text: NSString) -> Bool {
        if spelling.hasPrefix("@\"") { return true }
        if range.location > 0 {
            let previous = text.character(at: range.location - 1)
            if isNameContinuation(previous) || previous == 64 { return false }
            if previous == 34, range.location > 1, text.character(at: range.location - 2) == 64 { return false }
        }
        return range.upperBound == text.length || !isNameContinuation(text.character(at: range.upperBound))
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }

    private static func isNameContinuation(_ unit: UInt16) -> Bool {
        guard let byte = UInt8(exactly: unit) else { return false }
        return isLetter(byte) || (48...57).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 48...57: UInt32(byte - 48)
        case 65...70: UInt32(byte - 55)
        case 97...102: UInt32(byte - 87)
        default: nil
        }
    }
}
