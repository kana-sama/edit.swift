import Foundation

enum WorktreeDirectoryCheck {
    static func run() throws {
        let manager = FileManager.default
        let repo = manager.temporaryDirectory.appending(path: "Worktree Check \(UUID())", directoryHint: .isDirectory)
        let root = repo.appending(path: "Project", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: repo) }
        for directory in ["build/sub", "src", "inherited", "folder2", "folder10", "links"] {
            try manager.createDirectory(at: root.appending(path: directory), withIntermediateDirectories: true)
        }

        try write("gitdir: /elsewhere\n", to: repo.appending(path: ".git"))
        try write("/Project/inherited/\n*.tmp\nfolder-only/\nignore-link.txt\n", to: repo.appending(path: ".gitignore"))
        try write("build/\n!top.tmp\n/src/**/artifact.json\n", to: root.appending(path: ".gitignore"))
        try write("!nested.tmp\n", to: root.appending(path: "src/.gitignore"))
        try write("!*\n", to: root.appending(path: "build/.gitignore"))
        try write("linked.txt\n", to: repo.appending(path: "non-gitignore-rules"))
        for name in ["folder-only", "root.tmp", "top.tmp", "src/artifact.json", "src/nested.tmp",
                     "build/sub/file.txt", "links/linked.txt", ".hidden", ".DS_Store"] {
            try write("", to: root.appending(path: name))
        }
        let link = root.appending(path: "outside")
        try manager.createSymbolicLink(at: link, withDestinationURL: repo)
        try manager.createSymbolicLink(at: root.appending(path: "links/.gitignore"),
                                       withDestinationURL: repo.appending(path: "non-gitignore-rules"))

        let entries = try WorktreeDirectory.read(root, within: root)
        let folders = entries.filter(\.isDirectory).map { $0.url.lastPathComponent }
        try expect(folders == ["build", "folder2", "folder10", "inherited", "links", "src"],
                   "real directories are listed first in natural order")
        try expect(entries.prefix(folders.count).allSatisfy(\.isDirectory), "directory rows precede file rows")
        let flags = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.lastPathComponent, $0) })
        try expect(flags["build"]?.isIgnored == true && flags["inherited"]?.isIgnored == true,
                   "root and enclosing Git rules classify directories")
        try expect(flags["root.tmp"]?.isIgnored == true && flags["top.tmp"]?.isIgnored == false,
                   "a local negation overrides an inherited file pattern")
        try expect(flags["folder-only"]?.isIgnored == false, "directory-only patterns do not gray regular files")
        try expect(flags[".hidden"]?.isHidden == true && flags[".DS_Store"] == nil,
                   "dotfiles are hidden and Finder metadata is omitted")
        try expect(flags["outside"]?.isDirectory == false, "directory symlinks are leaf entries")

        let src = try WorktreeDirectory.read(root.appending(path: "src"), within: root)
        let srcFlags = Dictionary(uniqueKeysWithValues: src.map { ($0.url.lastPathComponent, $0.isIgnored) })
        try expect(srcFlags["artifact.json"] == true && srcFlags["nested.tmp"] == false,
                   "globstar and nested ignore rules classify files")
        let ignored = try WorktreeDirectory.read(root.appending(path: "build/sub"), within: root)
        try expect(ignored.first?.isIgnored == true, "children of ignored directories remain gray")
        let links = try WorktreeDirectory.read(root.appending(path: "links"), within: root)
        try expect(links.first { $0.url.lastPathComponent == "linked.txt" }?.isIgnored == false,
                   "rules from a symlinked .gitignore are skipped")
        for outside in [repo, link] {
            do {
                _ = try WorktreeDirectory.read(outside, within: root)
                throw Failure("directory traversal must stay within real project directories")
            } catch is CocoaError {
                // Either an outside path or an attempted symlink traversal must fail.
            }
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw Failure(detail) }
    }

    private struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { "Worktree listing: \(detail)" }
    }
}
