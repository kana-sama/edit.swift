import Foundation

enum FindScope: String, Codable, Sendable {
    case buffer, workspace
}

struct WorkspaceFindFilters: Codable, Equatable, Sendable {
    var include = ""
    var exclude = ""
    var respectsIgnoreFiles = true
}

@MainActor
final class WorkspaceFindPreferences {
    private static let key = "workspaceFindFilters"
    private let defaults: UserDefaults?
    private var filters: [String: WorkspaceFindFilters]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        filters = defaults?.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: WorkspaceFindFilters].self, from: $0) } ?? [:]
    }

    subscript(folder: URL) -> WorkspaceFindFilters {
        get { filters[folder.path] ?? WorkspaceFindFilters() }
        set {
            guard self[folder] != newValue else { return }
            filters[folder.path] = newValue
            if let data = try? JSONEncoder().encode(filters) { defaults?.set(data, forKey: Self.key) }
        }
    }
}

struct WorkspaceFindGlob {
    struct Invalid: Error {}
    private let patterns: [NSRegularExpression]

    init(_ input: String) throws {
        patterns = try Self.terms(input).map { term in
            let anchored = term.hasPrefix("./")
            var parser = Parser(rest: anchored ? term.dropFirst(2) : term[...])
            guard !parser.rest.isEmpty else { throw Invalid() }
            let pattern = try parser.sequence()
            guard parser.rest.isEmpty else { throw Invalid() }
            let prefix = anchored ? "\\A" : "(?:\\A|/)"
            return try NSRegularExpression(pattern: prefix + pattern + "(?:/.*)?\\z", options: .dotMatchesLineSeparators)
        }
    }

    var isEmpty: Bool { patterns.isEmpty }

    func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return patterns.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    static func folder(_ relativePath: String) -> String {
        "./" + relativePath.reduce(into: "") { escaped, character in
            if "*?[]{}\\,".contains(character) { escaped.append("\\") }
            escaped.append(character)
        } + "/**"
    }

    private static func terms(_ input: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var braceDepth = 0
        var inClass = false
        var escaped = false
        for character in input {
            if escaped {
                escaped = false
            } else {
                switch character {
                case "\\": escaped = true
                case "[" where !inClass: inClass = true
                case "]": inClass = false
                case "{" where !inClass: braceDepth += 1
                case "}" where !inClass: braceDepth -= 1
                case "," where !inClass && braceDepth == 0:
                    terms.append(current)
                    current = ""
                    continue
                default: break
                }
            }
            current.append(character)
        }
        terms.append(current)
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private struct Parser {
        var rest: Substring

        mutating func sequence(inBrace: Bool = false) throws -> String {
            var expression = ""
            while let character = rest.first {
                if inBrace && (character == "," || character == "}") { break }
                rest = rest.dropFirst()
                switch character {
                case "\\":
                    guard let literal = rest.popFirst() else { throw Invalid() }
                    expression += NSRegularExpression.escapedPattern(for: String(literal))
                case "*":
                    if rest.first == "*" {
                        rest = rest.drop(while: { $0 == "*" })
                        if rest.first == "/" {
                            rest = rest.dropFirst()
                            expression += "(?:.*/)?"
                        } else {
                            expression += ".*"
                        }
                    } else {
                        expression += "[^/]*"
                    }
                case "?": expression += "[^/]"
                case "[":
                    expression += try characterClass()
                case "{":
                    var alternatives: [String] = []
                    alternatives.append(try sequence(inBrace: true))
                    while rest.first == "," {
                        rest = rest.dropFirst()
                        alternatives.append(try sequence(inBrace: true))
                    }
                    guard rest.popFirst() == "}", alternatives.count > 1 else { throw Invalid() }
                    expression += "(?:" + alternatives.joined(separator: "|") + ")"
                case "}", "]": throw Invalid()
                default: expression += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            return expression
        }

        private mutating func characterClass() throws -> String {
            var characters = ""
            if rest.first == "!" {
                characters = "^"
                rest = rest.dropFirst()
            }
            let openingLength = characters.count
            while let character = rest.popFirst() {
                switch character {
                case "]":
                    guard characters.count > openingLength else { throw Invalid() }
                    return "(?!/)[" + characters + "]"
                case "\\":
                    guard let literal = rest.popFirst() else { throw Invalid() }
                    characters += "\\" + String(literal)
                case "[", "^", "&": characters += "\\" + String(character)
                default: characters.append(character)
                }
            }
            throw Invalid()
        }
    }
}

enum WorkspaceFindSearch {
    struct File: Sendable {
        let disk: FileBuffer
        let text: String
        let hits: [FindHit]
        var url: URL { disk.url }
    }

    enum Outcome: Sendable {
        case matches([File], limited: Bool)
        case invalid(String)
    }

    struct Repository: Sendable {
        // Ordered from repository root to the parent of the search root.
        let ancestors: [URL]

        static func containing(_ root: URL) -> Repository? {
            var directory = root
            var ancestors: [URL] = []
            while !Task.isCancelled {
                if [".git", ".jj"].contains(where: { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }) {
                    return Repository(ancestors: ancestors.reversed())
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { return nil }
                ancestors.append(parent)
                directory = parent
            }
            return nil
        }
    }

    static func run(root: URL, query: String, options: FindOptions, filters: WorkspaceFindFilters,
                    repository: Repository?, openText: [String: String]) -> Outcome {
        guard let include = try? WorkspaceFindGlob(filters.include) else { return .invalid("Invalid Include pattern") }
        guard let exclude = try? WorkspaceFindGlob(filters.exclude) else { return .invalid("Invalid Exclude pattern") }
        guard !query.isEmpty else { return .matches([], limited: false) }
        guard let matcher = FindSearch.Matcher(query, options: options) else { return .invalid("Invalid regex") }

        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return .invalid("Could not read workspace")
        }
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let respectIgnore = filters.respectsIgnoreFiles && repository != nil
        var rules: [String: [FolderIgnoreRules]] = [:]
        if respectIgnore, let repository {
            rules[rootPath] = (repository.ancestors + [root]).compactMap { FolderIgnoreRules.read(in: $0) }
        }
        let metadata: Set<String> = [".git", ".jj", ".hg", ".svn", ".DS_Store"]
        let matchLimit = 5_000
        let snapshotLimit = 32 * 1024 * 1024
        var matchCount = 0
        var snapshotBytes = 0
        var files: [File] = []
        var limited = false
        for case let url as URL in paths {
            if Task.isCancelled { break }
            let path = url.path
            guard path.hasPrefix(prefix), let values = try? url.resourceValues(forKeys: keys) else {
                paths.skipDescendants()
                continue
            }
            let relative = String(path.dropFirst(prefix.count))
            let directory = values.isDirectory == true
            let inherited = rules[url.deletingLastPathComponent().path] ?? []
            let ignored = inherited.reversed().lazy.compactMap { $0.ignores(url, isDirectory: directory) }.first == true
            if metadata.contains(url.lastPathComponent) || values.isSymbolicLink == true || ignored || exclude.matches(relative) {
                paths.skipDescendants()
                continue
            }
            if directory {
                if respectIgnore {
                    rules[path] = inherited + [FolderIgnoreRules.read(in: url)].compactMap { $0 }
                }
                continue
            }
            guard values.isRegularFile == true, (include.isEmpty || include.matches(relative)),
                  let disk = try? FileBuffer.read(url), disk.url.path.hasPrefix(prefix), disk.identity != nil else { continue }
            let text = openText[disk.url.path] ?? disk.text
            guard !text.utf8.contains(0) else { continue }
            let hits = matcher.matches(in: text, limit: matchLimit - matchCount + 1)
            guard !hits.isEmpty else { continue }
            let available = matchLimit - matchCount
            snapshotBytes += disk.text.utf8.count + (openText[disk.url.path]?.utf8.count ?? 0)
            if snapshotBytes > snapshotLimit, !files.isEmpty {
                limited = true
                break
            }
            if available > 0 { files.append(File(disk: disk, text: text, hits: Array(hits.prefix(available)))) }
            matchCount += min(available, hits.count)
            if hits.count > available || snapshotBytes > snapshotLimit {
                limited = true
                break
            }
        }
        return .matches(files.sorted { $0.url.path < $1.url.path }, limited: limited)
    }
}
