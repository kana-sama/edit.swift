import AppKit

@MainActor
enum SolidityLSPCheck {
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Solidity LSP check: \(detail)" }
    }

    static func run(in app: Edit, document: DocumentWindow, captureHover: (NSView) throws -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(
            path: "Solidity LSP \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let base = FileBuffer.canonicalURL(temporary)
        defer {
            document.window.close()
            try? FileManager.default.removeItem(at: base)
        }
        let project = ProcessInfo.processInfo.environment["EDIT_SOLIDITY_CHECK_PROJECT"] ?? ""
        try await checkFixture(in: base, app: app, document: document) { view in
            if project.isEmpty { try captureHover(view) }
        }
        if !project.isEmpty {
            let source = URL(filePath: project, directoryHint: .isDirectory)
            let copy = base.appending(path: "BarterLend copy", directoryHint: .isDirectory)
            try await Task.detached {
                try FileManager.default.copyItem(at: source, to: copy)
            }.value
            try await checkBarterLend(at: copy, app: app, document: document, captureHover: captureHover)
        }
        try require(!document.window.isVisible && document.window.alphaValue == 0 && !NSApp.isActive,
                    "keep the Editor instance hidden during live requests")
    }

    private static func checkFixture(in base: URL, app: Edit, document: DocumentWindow,
                                     captureHover: (NSView) throws -> Void) async throws {
        let root = base.appending(path: "Foundry # café", directoryHint: .isDirectory)
        let sources = root.appending(path: "contracts src", directoryHint: .isDirectory)
        let dependency = root.appending(path: "lib/math/src", directoryHint: .isDirectory)
        let main = sources.appending(path: "Counter.sol")
        let other = sources.appending(path: "Other.sol")
        let helper = sources.appending(path: "Helper.sol")
        let math = dependency.appending(path: "Math.sol")
        let manifest = """
            [profile.default]
            src = "contracts src"
            libs = ["lib"]
            offline = true

            [fmt]
            tab_width = 2

            """
        let mainText = """
            // SPDX-License-Identifier: MIT
            pragma solidity ^0.8.29;
            import {Math} from "@math/Math.sol";
            import {localValue} from "./Helper.sol";
            enum Operation { Leverage, Deleverage }
            contract Counter {
                function count() external pure returns (uint256) {
                    /* 🌿 */ return Math.add(2,3) + localValue();
                }
            }

            """
        let mathText = """
            // SPDX-License-Identifier: MIT
            pragma solidity ^0.8.29;
            library Math {
                /// @notice Adds two numbers.
                /// The inputs use the same scale.
                ///
                /// The sum must fit the type.
                /// @dev Uses checked [arithmetic](https://docs.soliditylang.org/).
                /// This applies to both inputs.
                ///
                /// * A positive input.
                /// * A zero input.
                ///
                /// ```text
                /// * A literal asterisk.
                /// ```
                /// @param left First number,
                /// in input units.
                /// @param right Second number.
                /// @return The sum in input units.
                function add(uint256 left, uint256 right) internal pure returns (uint256) { return left + right; }
                /// @notice Multiplies two numbers.
                function multiply(uint256 left, uint256 right) internal pure returns (uint256) { return left * right; }
            }

            """
        let helperText = """
            // SPDX-License-Identifier: MIT
            pragma solidity ^0.8.29;
            function localValue() pure returns (uint256) { return 7; }

            """
        for directory in [sources, dependency] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (url, text) in [
            (root.appending(path: "foundry.toml"), manifest),
            (root.appending(path: "remappings.txt"), "@math/=lib/math/src/\n"),
            (main, mainText), (other, mainText.replacingOccurrences(of: "Counter", with: "Other")),
            (helper, helperText), (math, mathText),
        ] {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let standaloneRoot = LanguageServer.solidity.projectRoot(in: sources, activeFile: main, previousRoot: nil,
                                                                 searchesParents: true)
        try require(standaloneRoot?.path == root.path, "find the enclosing Foundry root for a standalone .sol file")
        document.setFolder(root)
        try require(try await app.openFile(main, in: document) === document, "open the Solidity fixture")
        let lsp = document.languageFeatures
        let session = lsp.session
        try require(session.server == .solidity && document.resolvedSyntaxLanguage == .solidity,
                    "route Solidity to the Foundry server")
        try await wait("start forge lsp from PATH", session: session) { session.supportsDefinition }
        try require(session.workspaceRoot?.path == root.path && lsp.statusIndicatorForCheck == .ready,
                    "initialize the Foundry workspace and show it as ready")

        let use = try range("add", in: mainText)
        let declaration = try range("add", in: mathText, options: .backwards)
        let position = use.location + 1
        let locations = try await session.definition(at: position)
        try require(locations.count == 1 && locations.first?.url.path == math.path
                    && locations.first?.range.nsRange(in: mathText) == declaration,
                    "resolve the remapped dependency after an emoji in a workspace with a reserved path character")
        let hover = await lsp.hover(at: position, word: use)
        try require(hover?.range == use && hover?.isMarkdown == true && hover?.text.contains("Adds two numbers.") == true,
                    "return a ranged Markdown hover with the dependency's NatSpec")
        try await checkHover(at: use, in: document) { description, returns, view in
            try require(description.string == "Adds two numbers. The inputs use the same scale.\nThe sum must fit the type.",
                        "keep the wrapped notice and its second paragraph in the description")
            guard let note = hoverSubview("Note.body", in: view) as? NSTextView,
                  let rail = hoverSubview("Note.rail", in: view), let divider = hoverSubview("separator", in: view)
            else { throw Failure(detail: "show the developer note with a quote rail") }
            try require(note.string.hasPrefix("Note\nUses checked arithmetic. This applies to both inputs.")
                        && note.string.contains("• A positive input.\n• A zero input.")
                        && note.string.contains("\n* A literal asterisk."),
                        "keep the developer text, its list and code example together")
            try require(description.frame.maxY < note.frame.minY && note.frame.maxY < divider.frame.minY
                        && rail.frame.maxX < note.frame.minX && rail.frame.height == note.frame.height,
                        "place the note beneath the description and above the metadata divider")
            guard let parameters = hoverSubview("Parameters.body", in: view) as? NSTextView
            else { throw Failure(detail: "show the Parameters section") }
            try require(parameters.string == "\tleft\tFirst number, in input units.\n\tright\tSecond number."
                        && returns?.string == "The sum in input units.",
                        "show the documented parameters and return value under their headings")
            try require(returns.map { parameters.frame.maxY < $0.frame.minY && parameters.frame.minX == $0.frame.minX } == true,
                        "start both sections at the same left edge")
            let link = try range("arithmetic", in: note.string)
            let parameter = try range("left", in: parameters.string)
            try require(note.textStorage?.attribute(.link, at: link.location, effectiveRange: nil) as? URL
                        == URL(string: "https://docs.soliditylang.org/")
                        && parameters.textStorage?.attribute(.backgroundColor, at: parameter.location, effectiveRange: nil) == nil,
                        "preserve Markdown links and draw field names as plain labels")
            let shortName = parameters.firstRect(forCharacterRange: parameter, actualRange: nil)
            let longName = parameters.firstRect(forCharacterRange: try range("right", in: parameters.string), actualRange: nil)
            try require(!shortName.isEmpty && !longName.isEmpty && shortName.minX > longName.minX
                        && abs(shortName.maxX - longName.maxX) < 1,
                        "right-align the rendered field names in the label column")
            try captureHover(view)
        }
        try checkMultipleReturnHover()
        let references = try await session.references(at: position, includeDeclaration: true)
        try require(Set(references.map { $0.url.path }) == [main.path, other.path, math.path],
                    "find usages in the open and closed files and the remapped definition")
        try require(await lsp.documentHighlights(at: position) == [use], "highlight the member at its UTF-16 range")
        try require(try await session.documentSymbols().contains { $0.name == "count" },
                    "list functions in the active Solidity file")
        try require(try await session.workspaceSymbols(query: "Other").contains {
            $0.name == "Other" && $0.location.url.path == other.path
        }, "find a contract in a closed Solidity document")

        try await checkDefinitionTransition(from: mainText, use: use, to: math, text: mathText,
                                            declaration: declaration, in: document)
        let generation = session.generation
        try require(try await app.openFile(main, in: document) === document, "return to the Foundry fixture")
        try await wait("reuse the server for another document in the same project") {
            session.supportsDefinition && session.generation == generation
        }
        let editor = document.editor
        document.window.makeFirstResponder(editor)
        try await checkTyping(in: document, original: mainText)
        try await checkIncompleteStatement(in: document, before: "        /* 🌿 */ return Math.add")
        try await checkIncompleteEnum(in: document, before: "        /* 🌿 */ return Math.add",
                                      members: ["Leverage", "Deleverage"])
        try await checkDiagnostics(in: document, file: main, original: mainText)
        try await checkFormatting(in: document, file: main, original: mainText, caretWord: "count(") {
            $0.contains("\n  function count()") && $0.contains("Math.add(2, 3)")
        }
        try await checkStaleFormatting(in: document)
        try await checkRename(in: document, helper: helper, other: other)

        lsp.perform(.stop)
        try await wait("stop the Solidity server") { session.state == .stopped }
        try require(app.workspaceLanguageServers.isStopped(.solidity, in: root),
                    "remember Stop for the Foundry workspace")
        lsp.perform(.restart)
        try await wait("restart the Solidity server", session: session) { session.supportsDefinition }
        try require(!app.workspaceLanguageServers.isStopped(.solidity, in: root),
                    "clear the workspace Stop preference after Restart")
        try require(await document.save(), "save renamed source within the disposable fixture")
    }

    private static func checkDefinitionTransition(from source: String, use: NSRange, to destination: URL, text: String,
                                                  declaration: NSRange, in document: DocumentWindow) async throws {
        let title = document.window.title
        let (pending, release) = AsyncStream<Void>.makeStream()
        var staged = false
        document.beforeInstallFileForCheck = { file in
            guard file.url.path == destination.path else { return }
            staged = true
            for await _ in pending { break }
        }
        defer {
            release.finish()
            document.beforeInstallFileForCheck = nil
        }
        document.languageFeatures.followLink(at: use.location + 1, word: use)
        try await wait("hold the cross-file Solidity definition") { staged }
        try require(document.editor.string == source && document.window.title == title,
                    "retain the original text and title until the definition is ready")
        release.finish()
        try await wait("open the remapped definition and place the caret") {
            document.fileURL?.path == destination.path && document.editor.selectedRange().location == declaration.location
        }
        try require(document.editor.string == text && document.window.title.hasSuffix(destination.lastPathComponent),
                    "present the definition and destination title together")
    }

    private static func checkTyping(in document: DocumentWindow, original: String) async throws {
        let editor = document.editor
        try replace(".add", with: "", in: editor)
        let receiver = try range("Math(", in: editor.string)
        select(receiver.location + 4, in: editor)
        try key(47, ".", in: document)
        try await wait("receive member completion after typing a dot") { editor.completionLabelsForCheck.contains("add") }
        try require(editor.completionFrameForCheck != nil && document.window.childWindows?.isEmpty != false,
                    "lay out the completion panel without ordering it above the hidden editor")
        try await checkCompletionLayout(in: editor, documentation: "Adds two numbers.")
        try key(53, "\u{1B}", in: document)
        try require(editor.completionLabelsForCheck.isEmpty && editor.string.contains("Math.(2,3)"),
                    "dismiss completion with Escape without inserting a member")
        editor.complete(nil)
        try await wait("reopen member completion with two functions") {
            editor.completionLabelsForCheck.contains("add") && editor.completionLabelsForCheck.contains("multiply")
        }
        guard let second = editor.completionLabelsForCheck.dropFirst().first else {
            throw Failure(detail: "show a second selectable completion")
        }
        try key(125, "\u{F701}", in: document)
        try await wait("show the NatSpec of the completion selected with the Down arrow") {
            editor.completionDocumentationForCheck?.contains("Multiplies two numbers.") == true
        }
        try key(36, "\r", in: document)
        try await wait("accept the completion selected with the Down arrow") {
            editor.string.contains("Math.\(second)(2,3)")
        }
        try replace("Math.\(second)(", with: "Math.ad(", in: editor)
        let partial = try range("Math.ad", in: editor.string)
        select(partial.upperBound, in: editor)
        editor.complete(nil)
        try await wait("show completion for a partially typed member") { editor.completionLabelsForCheck.first == "add" }
        try key(36, "\r", in: document)
        try await wait("accept completion and replace the typed prefix") {
            editor.string == original && editor.completionLabelsForCheck.isEmpty
        }
        try require(document.window.firstResponder === editor, "keep editor focus during completion")

        try replace("add(", with: "add", in: editor)
        let callee = try range("Math.add", in: editor.string)
        select(callee.upperBound, in: editor)
        try key(25, "(", in: document, modifiers: .shift)
        try require(editor.string == original && editor.selectedRange().location == callee.upperBound + 1,
                    "type the opening parenthesis and leave the caret immediately after it (caret \(editor.selectedRange()))")
        try await checkParameter("uint256 left", in: document)
        try replace("2,3", with: "23", in: editor)
        let argumentStart = try range("add(2", in: editor.string)
        select(argumentStart.upperBound, in: editor)
        try key(43, ",", in: document)
        try await checkParameter("uint256 right", in: document)
        try key(53, "\u{1B}", in: document)
        try require(editor.signatureLabelForCheck == nil && editor.string == original,
                    "dismiss the signature on Escape without moving or editing the call")
    }

    private static func checkCompletionLayout(in editor: EditorTextView, documentation: String) async throws {
        try await wait("show selected completion documentation") {
            editor.completionDocumentationForCheck?.contains(documentation) == true
        }
        guard let caret = editor.completionCaretFrameForCheck, let list = editor.completionListFrameForCheck,
              let guide = editor.completionDocumentationFrameForCheck else {
            throw Failure(detail: "lay out completion, caret, and documentation beside one another")
        }
        try require(list.minX >= caret.maxX - 1, "start completion to the right of the caret instead of at the token's start")
        try require(guide.minX >= list.maxX - 1 && guide.minY < list.maxY && guide.maxY > list.minY,
                    "show the selected item's documentation in an adjacent column")
    }

    private static func checkIncompleteStatement(in document: DocumentWindow, before nextStatement: String) async throws {
        let editor = document.editor
        let original = editor.string
        let insertion = try range(nextStatement, in: original).location
        let indent = "        "
        let addedLines = indent + "\n\n"
        editor.insertText(addedLines, replacementRange: NSRange(location: insertion, length: 0))
        let caret = insertion + indent.utf16.count
        select(caret, in: editor)
        try key(31, "O", in: document, modifiers: .shift)
        try key(35, "p", in: document)
        try key(14, "e", in: document)
        let incomplete = indent + "Ope\n\n"
        let expectedBroken = (original as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: incomplete)
        try require(editor.string == expectedBroken && editor.selectedRange().location == caret + 3,
                    "type the screenshot's incomplete identifier on its own line")
        let next = try range(nextStatement, in: expectedBroken)
        let keyword = try range("return", in: nextStatement)
        let diagnosed = NSRange(location: next.location + keyword.location, length: keyword.length)
        try await wait("show the parse error on the following return and retain Operation completion") {
            editor.diagnosticRanges.contains { NSIntersectionRange($0, diagnosed).length > 0 }
                && editor.completionLabelsForCheck.first == "Operation"
        }
        try key(53, "\u{1B}", in: document)
        try require(editor.completionLabelsForCheck.isEmpty, "dismiss the automatic completion")
        editor.complete(nil)
        try await wait("manually complete Operation once Solar has diagnosed the incomplete statement") {
            editor.completionLabelsForCheck.first == "Operation"
        }
        try key(36, "\r", in: document)
        let accepted = indent + "Operation\n\n"
        let expectedAccepted = (original as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: accepted)
        try await wait("replace only the incomplete symbol while preserving the return statement") {
            editor.string == expectedAccepted
        }
        editor.insertText("", replacementRange: NSRange(location: insertion, length: accepted.utf16.count))
        try require(editor.string == original, "restore the disposable source after the incomplete statement check")
    }

    private static func checkDiagnostics(in document: DocumentWindow, file: URL, original: String) async throws {
        let editor = document.editor
        editor.breakUndoCoalescing()
        try replace("add(2", with: #"add("wrong""#, in: editor)
        let bad = try range(#""wrong""#, in: editor.string)
        try await wait("paint the unsaved Solidity type error") {
            editor.diagnosticRanges.contains { NSIntersectionRange($0, bad).length == bad.length }
        }
        try require(try String(contentsOf: file, encoding: .utf8) == original, "show the error before saving")
        try replace(#""wrong""#, with: "2", in: editor)
        try require(editor.string == original,
                    "restore the original argument text")
        do {
            try await wait("clear diagnostics after correcting the argument") { editor.diagnosticRanges.isEmpty }
        } catch {
            let session = document.languageFeatures.session
            let reports = session.diagnostics.map { "\($0.displayRange): \($0.message)" }
            throw Failure(detail: "clear diagnostics after correcting the argument. "
                + "Buffer \(editor.string.debugDescription), editor ranges \(editor.diagnosticRanges), "
                + "session revision \(session.revision), session reports \(reports)")
        }
    }

    private static func checkIncompleteEnum(in document: DocumentWindow, before nextStatement: String,
                                            members: Set<String>) async throws {
        let editor = document.editor
        let original = editor.string
        let insertion = try range(nextStatement, in: original).location
        let dot = "        Operation."
        let caret = insertion + dot.utf16.count
        for terminator in [";", ""] {
            let added = dot + terminator + "\n"
            editor.insertText("        Operation" + terminator + "\n", replacementRange: NSRange(location: insertion, length: 0))
            select(caret - 1, in: editor)
            try key(47, ".", in: document)
            if terminator.isEmpty {
                try await wait("let Solar diagnose Operation. before the following return") {
                    !editor.diagnosticRanges.isEmpty
                }
            }
            try await wait("complete all Operation members on typing the dot with terminator \(terminator.debugDescription)") {
                Set(editor.completionLabelsForCheck) == members
            }
            try key(53, "\u{1B}", in: document)
            if terminator.isEmpty {
                editor.complete(nil)
                try await wait("reopen enum completion after Solar has analyzed the incomplete statement") {
                    Set(editor.completionLabelsForCheck) == members
                }
                try key(53, "\u{1B}", in: document)
                editor.insertText("Lev", replacementRange: NSRange(location: caret, length: 0))
                select(caret + 3, in: editor)
                editor.complete(nil)
                try await wait("complete the partial enum member without a semicolon") {
                    editor.completionLabelsForCheck.first == "Leverage"
                }
                try key(36, "\r", in: document)
                let accepted = dot + "Leverage\n"
                let expected = (original as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0),
                                                                          with: accepted)
                try await wait("insert only the enum value, leaving the following return intact") {
                    editor.string == expected
                }
                editor.insertText("", replacementRange: NSRange(location: insertion, length: accepted.utf16.count))
            } else {
                editor.insertText("", replacementRange: NSRange(location: insertion, length: added.utf16.count))
            }
            try require(editor.string == original, "restore the disposable enum completion fixture")
        }
    }

    private static func checkFormatting(in document: DocumentWindow, file: URL, original: String, caretWord: String? = nil,
                                        isFormatted: (String) -> Bool) async throws {
        let editor = document.editor
        let before = editor.string
        if let caretWord { select(try range(caretWord, in: before).location + 1, in: editor) }
        let selection = editor.selectedRange()
        let title = document.window.title
        let (pending, release) = AsyncStream<Void>.makeStream()
        var waiting = false
        editor.beforeApplyLanguageFormattingForCheck = {
            waiting = true
            for await _ in pending { break }
        }
        defer {
            release.finish()
            editor.beforeApplyLanguageFormattingForCheck = nil
        }
        // The preceding fixture inputs call the view directly, outside the window's event dispatch.
        // Keep their undo events out of this check of the formatter's own transaction.
        editor.breakUndoCoalescing()
        editor.undoManager?.removeAllActions()
        editor.formatDocument(nil)
        try await wait("hold the formatting response before installation") { waiting }
        try require(editor.string == before && document.window.title == title && editor.selectedRange() == selection,
                    "retain the text, title, and caret while formatting is pending")
        release.finish()
        try await wait("apply Foundry formatting to the buffer") { editor.string != before && isFormatted(editor.string) }
        try require(document.window.title == title, "keep the document title on the formatted frame")
        try require(try String(contentsOf: file, encoding: .utf8) == original,
                    "leave formatted edits in the buffer until save")
        if let caretWord {
            let offset = try range(caretWord, in: editor.string).location + 1
            try require(editor.selectedRange().location == offset, "keep the caret on the same token after formatting")
        }
        editor.undoManager?.undo()
        try require(editor.string == before && editor.selectedRange() == selection,
                    "undo all formatting and restore the caret in one operation")
    }

    private static func checkStaleFormatting(in document: DocumentWindow) async throws {
        let editor = document.editor
        let original = editor.string
        let (pending, release) = AsyncStream<Void>.makeStream()
        var waiting = false
        var returned = false
        editor.beforeApplyLanguageFormattingForCheck = {
            waiting = true
            for await _ in pending { break }
            returned = true
        }
        defer {
            release.finish()
            editor.beforeApplyLanguageFormattingForCheck = nil
        }
        editor.formatDocument(nil)
        try await wait("hold a second formatting response for a now-stale revision") { waiting }
        let edit = "// Typed in the meantime\n"
        editor.breakUndoCoalescing()
        editor.insertText(edit, replacementRange: NSRange(location: original.utf16.count, length: 0))
        release.finish()
        try await wait("return from the stale result gate") { returned }
        try require(editor.string == original + edit, "keep newer edits when an earlier formatting result arrives")
        try replace(edit, with: "", in: editor)
        try require(editor.string == original, "restore the fixture after the formatting race")
    }

    private static func checkRename(in document: DocumentWindow, helper: URL, other: URL) async throws {
        let editor = document.editor
        let name = try range("localValue", in: editor.string, options: .backwards)
        select(name.location + 1, in: editor)
        try key(120, "\u{F707}", in: document)
        try await wait("prepare rename for a project-owned Solidity function") { editor.renameRange == name }
        editor.insertText("renamedLocal", replacementRange: editor.selectedRange())
        try key(36, "\r", in: document)
        try await wait("rename the symbol in the buffer and two closed files") {
            editor.renameRange == nil && editor.string.contains("+ renamedLocal()")
                && (try? String(contentsOf: helper, encoding: .utf8))?.contains("function renamedLocal()") == true
                && (try? String(contentsOf: other, encoding: .utf8))?.contains("+ renamedLocal()") == true
        }
    }

    private static func checkBarterLend(at root: URL, app: Edit, document: DocumentWindow,
                                        captureHover: (NSView) throws -> Void) async throws {
        let file = root.appending(path: "src/PendlePtPriceOracle.sol")
        try require(FileBuffer.canonicalURL(file).path == file.path, "open the oracle source from the disposable copy")
        let original = try String(contentsOf: file, encoding: .utf8)
        document.setFolder(root)
        try require(try await app.openFile(file, in: document) === document, "open the isolated BarterLend oracle")
        let lsp = document.languageFeatures
        let session = lsp.session
        try await wait("index BarterLend with Solar", session: session) { session.supportsDefinition }
        try require(session.workspaceRoot?.path == root.path, "use the real foundry.toml in the BarterLend copy")

        let token = try range("IERC20Metadata", in: original)
        let dependency = root.appending(path: "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol")
        let positions = try await session.definition(at: token.location + 2)
        try require(positions.contains {
            $0.url.path == dependency.path
        }, "resolve the oracle's OpenZeppelin import into the project dependency")
        let references = try await session.references(at: token.location + 2, includeDeclaration: true)
        try require(references.contains { $0.url.path == root.appending(path: "src/ChainlinkPriceOracle.sol").path },
                    "find that dependency's references from another BarterLend oracle")
        try require(try await session.workspaceSymbols(query: "PendlePtPriceOracle").contains {
            $0.name == "PendlePtPriceOracle" && $0.location.url.path == file.path
        }, "find the oracle in the workspace symbol index")
        let generation = session.generation
        lsp.followLink(at: token.location + 2, word: token)
        try await wait("open the dependency from the BarterLend definition link") {
            document.fileURL?.path == dependency.path && session.supportsDefinition
        }
        try require(session.workspaceRoot?.path == root.path && session.generation == generation,
                    "stay in the BarterLend workspace when a dependency has its own foundry.toml")
        try require(try await app.openFile(file, in: document) === document, "return to the BarterLend oracle")
        try await wait("synchronize the oracle after visiting its dependency") { session.supportsDefinition }

        let editor = document.editor
        document.window.makeFirstResponder(editor)
        try replace("pendleOracle.getPtToAssetRate(", with: "pendleOracle.getPtToAssetRa(", in: editor)
        let partial = try range("pendleOracle.getPtToAssetRa", in: editor.string)
        select(partial.upperBound, in: editor)
        editor.complete(nil)
        try await wait("offer getPtToAssetRate on the typed oracle interface") {
            editor.completionLabelsForCheck.first == "getPtToAssetRate"
        }
        try require(editor.completionFrameForCheck != nil, "place completion near the BarterLend caret")
        try key(36, "\r", in: document)
        try await wait("accept the BarterLend completion without changing any other source") {
            editor.string == original
        }
        let argument = try range("pendleOracle.getPtToAssetRate(market,", in: editor.string)
        select(argument.upperBound, in: editor)
        editor.showSignatureHelp(nil)
        try await checkParameter("uint32 duration", in: document)
        try key(53, "\u{1B}", in: document)

        try replace("uint256 marketPrice =", with: "uint256 marketPrice  =", in: editor)
        try await checkFormatting(in: document, file: file, original: original) {
            $0.contains("uint256 marketPrice =") && !$0.contains("uint256 marketPrice  =")
        }
        try replace("uint256 marketPrice  =", with: "uint256 marketPrice =", in: editor)
        try require(editor.string == original, "restore the exact BarterLend source in the disposable buffer")

        let router = root.appending(path: "src/periphery/LeverageRouter.sol")
        try require(FileManager.default.fileExists(atPath: router.path), "include LeverageRouter.sol in the BarterLend fixture copy")
        try require(try await app.openFile(router, in: document) === document && document.fileURL?.path == router.path,
                    "open the BarterLend source shown in the screenshot")
        try await wait("synchronize LeverageRouter.sol", session: session) { session.supportsCompletion }
        document.window.makeFirstResponder(editor)
        let getter = try range("getStalePriceWindow", in: editor.string)
        try await checkHover(at: getter, in: document) { description, returns, view in
            try require(description.string.contains("Returns the maximum staleness of an oracle price."),
                        "show the BarterLend getter description above the divider")
            try require(returns?.string == "Maximum price staleness, in seconds."
                        && hoverSubview("Parameters.label", in: view) == nil,
                        "show only the Returns row for the BarterLend getter")
        }
        let approval = try range("forceApprove", in: editor.string)
        try await checkHover(at: approval, in: document) { description, _, view in
            try require(description.string.contains("such as USDT.\nNOTE: If the token implements ERC-7674")
                        && !description.string.contains(" *") && hoverSubview("Note.body", in: view) == nil,
                        "use the OpenZeppelin developer comment as the main description and preserve the note paragraph")
        }
        try await checkIncompleteStatement(in: document, before: "        return FlashLoanContext({")
        try await checkIncompleteEnum(in: document, before: "        return FlashLoanContext({",
                                      members: ["Leverage", "Deleverage", "ReducePosition"])

        let interface = root.appending(path: "src/interfaces/ICreditPool.sol")
        try require(try await app.openFile(interface, in: document) === document, "open the BarterLend credit pool interface")
        let preview = try range("previewProvideExactIn(", in: editor.string)
        try await checkHover(at: NSRange(location: preview.location, length: preview.length - 1), in: document) { description, returns, view in
            guard let note = hoverSubview("Note.body", in: view) as? NSTextView,
                  let parameters = hoverSubview("Parameters.body", in: view) as? NSTextView, let returns
            else { throw Failure(detail: "show notes and parameters for the BarterLend preview") }
            try require(description.string == "Previews providing an exact asset amount by matching against existing borrow or reloan orders."
                        && note.string == "Note\nRequires an active market. May return a partial result when liquidity or the crossing limit is insufficient. Does not check the account's pool balance or authorization."
                        && parameters.string.contains("before share rounding, in loan token base units. Ignored by this preview.")
                        && parameters.string.contains("including skipped and invalidated orders.")
                        && returns.string.contains("\tcollectedLoan\tLoan claim produced, net of protocol fees and before share rounding, in loan token base units."),
                        "restore each wrapped NatSpec fragment to the notice, developer note, parameter or return it documents")
            let columns = try [descriptionColumn(after: "market", in: parameters),
                               descriptionColumn(after: "minLoanAmount", in: parameters),
                               descriptionColumn(after: "collectedLoan", in: returns),
                               descriptionColumn(after: "crossedOrders", in: returns)]
            try require(columns.allSatisfy { abs($0 - columns[0]) < 0.5 },
                        "share the description column across named parameters and returns, including wrapped lines")
            try captureHover(view)
        }
    }

    private static func checkHover(at word: NSRange, in document: DocumentWindow,
                                   verify: (NSTextView, NSTextView?, NSView) throws -> Void) async throws {
        let editor = document.editor
        select(word.location, in: editor)
        guard let rect = editor.highlightRects(for: [word]).first,
              let event = NSEvent.mouseEvent(with: .mouseMoved,
                  location: editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: document.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { throw Failure(detail: "create the pointer event for the Solidity hover") }
        editor.mouseMoved(with: event)
        defer { editor.cancelOperation(nil) }
        try await wait("show the native Solidity hover") { editor.languageHoverWindowForCheck != nil }
        guard let panel = editor.languageHoverWindowForCheck, let view = panel.contentView,
              let declaration = hoverSubview("Declaration.body", in: view) as? NSTextView,
              let description = hoverSubview("Description.body", in: view) as? NSTextView,
              let codeBlock = declaration.superview?.subviews.compactMap({ $0 as? NSBox }).first(where: {
                  $0.boxType == .custom && $0.frame.contains(declaration.frame)
              })
        else { throw Failure(detail: "find the Solidity signature code block and description") }
        let returns = hoverSubview("Returns.body", in: view) as? NSTextView
        try require(!panel.isVisible && panel.alphaValue == 0 && declaration.isSelectable
                    && description.isSelectable && returns?.isSelectable != false,
                    "keep the hover content selectable in the hidden native check")
        try require(codeBlock.frame.maxY < description.frame.minY, "show the description below the code block")
        if let returns {
            guard let divider = hoverSubview("separator", in: view) as? NSBox
            else { throw Failure(detail: "find the NatSpec divider") }
            let returnsHeading = try checkHeading("Returns", above: returns, in: view)
            let firstHeading: NSRect
            if let parameters = hoverSubview("Parameters.body", in: view) {
                firstHeading = try checkHeading("Parameters", above: parameters, in: view)
                try require(parameters.frame.maxY < returnsHeading.minY, "place the Returns heading after the parameters")
            } else {
                firstHeading = returnsHeading
            }
            try require(description.frame.maxY < divider.frame.minY && divider.frame.maxY < firstHeading.minY
                        && description.frame.minX == firstHeading.minX && divider.boxType == .separator
                        && divider.frame.minX == codeBlock.frame.minX && divider.frame.width == codeBlock.frame.width,
                        "use the shared divider above full-width NatSpec sections")
        }
        try verify(description, returns, view)
    }

    private static func checkHeading(_ title: String, above body: NSView, in view: NSView) throws -> NSRect {
        guard let heading = hoverSubview("\(title).label", in: view) as? NSTextField
        else { throw Failure(detail: "find the \(title) heading") }
        let frame = heading.alignmentRect(forFrame: heading.frame)
        try require(!heading.isHidden && heading.stringValue == title && heading.alignment == .left
                    && frame.maxY < body.frame.minY && abs(frame.minX - body.frame.minX) < 0.5,
                    "place the \(title) heading above the body at the same left edge")
        return frame
    }

    private static func descriptionColumn(after name: String, in view: NSTextView) throws -> CGFloat {
        let label = try range("\t\(name)\t", in: view.string)
        let style = view.textStorage?.attribute(.paragraphStyle, at: label.upperBound, effectiveRange: nil) as? NSParagraphStyle
        guard let style, style.tabStops.count == 2, let nameTab = style.tabStops.first, let valueTab = style.tabStops.last,
              nameTab.alignment == .right, valueTab.alignment == .left, nameTab.location < valueTab.location,
              valueTab.location == style.headIndent
        else { throw Failure(detail: "align the description and wrapped lines for \(name)") }
        return view.frame.minX + valueTab.location
    }

    private static func hoverSubview(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "EditorLanguageHover.\(id)" { return view }
        return view.subviews.lazy.compactMap { hoverSubview(id, in: $0) }.first
    }

    private static func checkMultipleReturnHover() throws {
        let markdown = """
            ```solidity
            function limits() returns (uint64 lower, uint64 upper)
            ```

            A Markdown list:
            * First item.
            * Second item.

            **@return**

            - `lower`: Lower bound.
            - `upper`: Upper bound.

            ```
            A literal example:
                 * Keep this asterisk.
                 *
            **@return**
            ```
            """
        let presentation = EditorHoverPresentation(text: markdown, isMarkdown: true, server: .solidity)
        guard let layout = EditorHoverLayout(presentation, maximumWidth: presentation.maximumWidth),
              let description = hoverSubview("Description.body", in: layout.view) as? NSTextView,
              let returns = hoverSubview("Returns.body", in: layout.view) as? NSTextView
        else { throw Failure(detail: "lay out the named returns after the description") }
        try require(description.string.contains("• First item.\n• Second item.")
                    && description.string.hasSuffix("A literal example:\n     * Keep this asterisk.\n     *\n**@return**")
                    && returns.string == "\tlower\tLower bound.\n\tupper\tUpper bound.",
                    "preserve Markdown lists, asterisks inside a fenced example and both named returns")
    }

    private static func checkParameter(_ text: String, in document: DocumentWindow) async throws {
        let editor = document.editor
        do {
            try await wait("highlight signature parameter \(text)") {
                guard let label = editor.signatureLabelForCheck, let active = editor.signatureParameterForCheck,
                      let expected = try? range(text, in: label) else { return false }
                return active == expected
            }
        } catch {
            try Task.checkCancellation()
            let caret = editor.selectedRange()
            let buffer = editor.string as NSString
            let line = caret.location <= buffer.length ? buffer.substring(with: buffer.lineRange(for: caret)) : ""
            let direct = try? await document.languageFeatures.session.signatureHelp(at: caret.location)
            let response = direct.map { "\($0.signatures.map(\.label)) parameter \(String(describing: $0.activeParameter))" } ?? "nil"
            throw Failure(detail: "highlight signature parameter \(text) at \(caret) on \(line.debugDescription). "
                + "Panel label \(String(describing: editor.signatureLabelForCheck)), "
                + "active range \(String(describing: editor.signatureParameterForCheck)), server \(response)")
        }
        try require(editor.signatureFrameForCheck != nil, "place signature help near the call")
    }

    private static func replace(_ text: String, with replacement: String, in editor: EditorTextView) throws {
        editor.insertText(replacement, replacementRange: try range(text, in: editor.string))
    }

    private static func range(_ token: String, in text: String, options: NSString.CompareOptions = []) throws -> NSRange {
        let range = (text as NSString).range(of: token, options: options)
        guard range.location != NSNotFound else { throw Failure(detail: "find \(token) in the fixture text") }
        return range
    }

    private static func select(_ offset: Int, in editor: EditorTextView) {
        let caret = NSRange(location: offset, length: 0)
        editor.setCaretSelections([caret], record: false)
        editor.window?.layoutIfNeeded()
        editor.revealNavigationSelection(caret)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    private static func key(_ code: UInt16, _ character: String, in document: DocumentWindow,
                            modifiers: NSEvent.ModifierFlags = []) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: document.window.windowNumber, context: nil, characters: character,
                                          charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else {
            throw Failure(detail: "create an isolated editor key event")
        }
        document.editor.keyDown(with: event)
    }

    private static func wait(_ detail: String, session: LanguageServerSession? = nil,
                             until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !(await condition()) {
            if let failure = session?.failureReason { throw Failure(detail: "\(detail) (\(failure))") }
            if session?.state == .notOnPATH { throw Failure(detail: "forge is not on PATH") }
            guard ContinuousClock.now < deadline else { throw Failure(detail: detail) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw Failure(detail: detail) }
    }
}
