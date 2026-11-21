import Darwin
import Foundation

struct FolderIgnoreRules: Sendable {
    private let directoryPrefix: String
    private let rules: [Rule]

    static func read(in directory: URL) -> FolderIgnoreRules? {
        let source = directory.appending(path: ".gitignore", directoryHint: .notDirectory)
        let descriptor = source.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? file.readToEnd() else { return nil }
        let contents = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        let rules = contents.split(separator: 0x0A).compactMap { line -> Rule? in
            let bytes = line.last == 0x0D ? line.dropLast() : line
            return Rule(String(decoding: bytes, as: UTF8.self))
        }
        guard !rules.isEmpty else { return nil }
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return FolderIgnoreRules(directoryPrefix: prefix, rules: rules)
    }

    func ignores(_ url: URL, isDirectory: Bool = true) -> Bool? {
        let path = url.path
        guard path.hasPrefix(directoryPrefix) else { return nil }
        let relative = path.dropFirst(directoryPrefix.count)
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        for rule in rules.reversed() where (isDirectory || !rule.directoriesOnly) && rule.matches(components) {
            return rule.excludes
        }
        return nil
    }

    private struct Rule: Sendable {
        let excludes: Bool
        let directoriesOnly: Bool
        let matchesBasename: Bool
        let pattern: [String]

        init?(_ text: String) {
            var text = text[...]
            while text.last == " " {
                let escapeCount = text.dropLast().reversed().prefix { $0 == "\\" }.count
                guard escapeCount.isMultiple(of: 2) else { break }
                text.removeLast()
            }
            guard let first = text.first, first != "#", !text.utf8.contains(0) else { return nil }

            excludes = first != "!"
            if !excludes { text.removeFirst() }

            directoriesOnly = text.last == "/"
            if directoriesOnly { text.removeLast() }
            matchesBasename = !text.contains("/")
            if text.first == "/" { text.removeFirst() }
            guard let components = Self.components(in: text) else { return nil }
            pattern = components.map { component in
                component.hasPrefix("**") && component.allSatisfy({ $0 == "*" }) ? "**" : component
            }
        }

        func matches(_ path: [String]) -> Bool {
            if matchesBasename {
                return fnmatch(pattern[0], path[path.count - 1], 0) == 0
            }

            var ruleIndex = 0
            var pathIndex = 0
            var globstar: (ruleIndex: Int, nextPathIndex: Int)?
            while pathIndex < path.count {
                if ruleIndex < pattern.count {
                    let component = pattern[ruleIndex]
                    if component == "**" {
                        // A trailing /** matches descendants, so it requires a remaining component.
                        if ruleIndex == pattern.count - 1 { return true }
                        globstar = (ruleIndex, pathIndex + 1)
                        ruleIndex += 1
                        continue
                    }
                    if fnmatch(component, path[pathIndex], 0) == 0 {
                        ruleIndex += 1
                        pathIndex += 1
                        continue
                    }
                }
                guard let retry = globstar, retry.nextPathIndex < path.count else { return false }
                // Retry the suffix after consuming another path component with the last globstar.
                ruleIndex = retry.ruleIndex + 1
                pathIndex = retry.nextPathIndex
                globstar = (retry.ruleIndex, retry.nextPathIndex + 1)
            }
            return ruleIndex == pattern.count
        }

        private static func components(in text: Substring) -> [String]? {
            var components: [String] = []
            var component = ""
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                switch character {
                case "\\":
                    let next = text.index(after: index)
                    guard next < text.endIndex else { return nil }
                    if text[next] == "/" {
                        components.append(component)
                        component = ""
                    } else {
                        component.append(character)
                        component.append(text[next])
                    }
                    index = text.index(after: next)
                case "[":
                    guard let end = classEnd(in: text, from: text.index(after: index)) else { return nil }
                    component.append(contentsOf: text[index..<end])
                    index = end
                case "/":
                    components.append(component)
                    component = ""
                    text.formIndex(after: &index)
                default:
                    component.append(character)
                    text.formIndex(after: &index)
                }
            }
            components.append(component)
            return components.contains("") ? nil : components
        }

        private static func classEnd(in text: Substring, from start: String.Index) -> String.Index? {
            var index = start
            if index < text.endIndex, text[index] == "!" || text[index] == "^" {
                text.formIndex(after: &index)
            }
            if index < text.endIndex, text[index] == "]" {
                text.formIndex(after: &index)
            }
            while index < text.endIndex {
                let character = text[index]
                if character == "]" { return text.index(after: index) }
                if character == "[", text[index...].hasPrefix("[:"),
                   let classMarker = text[index...].range(of: ":]") {
                    index = classMarker.upperBound
                    continue
                }
                text.formIndex(after: &index)
                if character == "\\", index < text.endIndex { text.formIndex(after: &index) }
            }
            return nil
        }
    }
}
