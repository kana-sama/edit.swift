import AppKit

@MainActor
enum WorkspaceFindReplacement {
    struct Change: Sendable {
        let disk: FileBuffer
        let original: String
        let updated: String
        let edits: [EditorTextEdit]
        let inverse: [EditorTextEdit]

        nonisolated init?(file: WorkspaceFindSearch.File, hits: [FindHit], replacement: String, regex: Bool) {
            let source = file.text as NSString
            let lineEnding = file.disk.format.lineEnding
            let template = replacement.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: lineEnding)
            let edits = hits.compactMap { hit -> EditorTextEdit? in
                let value = hit.replacement(using: template, in: source, isRegex: regex)
                guard !value.utf8.elementsEqual(source.substring(with: hit.range).utf8) else { return nil }
                return EditorTextEdit(range: hit.range, text: value)
            }
            guard !edits.isEmpty else { return nil }
            let updated = NSMutableString(string: file.text)
            var offset = 0
            let inverse = edits.map { edit in
                let range = NSRange(location: edit.range.location + offset, length: edit.text.utf16.count)
                offset += edit.lengthChange
                return EditorTextEdit(range: range, text: source.substring(with: edit.range))
            }
            for edit in edits.reversed() { updated.replaceCharacters(in: edit.range, with: edit.text) }
            self.init(disk: file.disk, original: file.text, updated: updated as String, edits: edits, inverse: inverse)
        }

        private nonisolated init(disk: FileBuffer, original: String, updated: String,
                                 edits: [EditorTextEdit], inverse: [EditorTextEdit]) {
            self.disk = disk
            self.original = original
            self.updated = updated
            self.edits = edits
            self.inverse = inverse
        }

        func reversing(saved: FileBuffer) -> Change {
            Change(disk: saved, original: updated, updated: original, edits: inverse, inverse: edits)
        }
    }

    struct Report {
        var reversed: [Change] = []
        var failed: [String] = []
    }

    static func apply(_ changes: [Change], in app: Edit, root: URL) async -> Report {
        var report = Report()
        for change in changes {
            let url = change.disk.url
            do {
                let saved = try await app.performWorktreeMutation(affecting: [url]) {
                    let disk = try await Task.detached {
                        let current = try FileBuffer.read(url)
                        guard current.url.path == url.path, WorktreeFileOperations.contains(current.url, in: root) else {
                            throw FileBufferError.invalidPath(url)
                        }
                        return current
                    }.value
                    let open = app.documents.filter {
                        $0.hasEditableTextDocument && ($0.fileURL?.path == url.path ||
                            (disk.identity != nil && $0.fileIdentity == disk.identity))
                    }
                    guard open.allSatisfy({ $0.canApplyWorkspaceFind(change, disk: disk) }),
                          disk.revision == change.disk.revision && disk.identity == change.disk.identity ||
                            (!open.isEmpty && disk.text.utf8.elementsEqual(change.original.utf8)) else {
                        throw FileBufferError.changedOnDisk
                    }
                    let written = try await Task.detached {
                        try FileBuffer.save(change.updated, to: url, format: disk.format, expected: disk.revision)
                    }.value
                    if let previous = written.replacedIdentity, let current = written.file.identity {
                        for document in app.documents { document.worktreeSidebar?.fileReplaced(previous, with: current) }
                    }
                    for document in open { document.applyWorkspaceFind(change, saved: written.file) }
                    return written.file
                }
                report.reversed.append(change.reversing(saved: saved))
            } catch {
                let path = DocumentWindow.worktreePathSuffix(from: root, to: url) ?? url.path
                report.failed.append("\(path) — \(error.localizedDescription)")
            }
        }
        return report
    }
}
