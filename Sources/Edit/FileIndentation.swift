import Foundation

struct Indentation: Codable, Equatable, Sendable {
    enum Style: String, Codable, Sendable { case spaces, tabs }

    static let standard = Indentation(style: .spaces, width: 4)
    static let widths = 1...8
    private static let detectableWidths = [2, 4, 6, 8]

    var style: Style
    var width: Int

    func nextStop(after column: Int) -> Int { column + width - column % width }

    func previousStop(before column: Int) -> Int { max(0, column - 1) / width * width }

    func column(after text: String) -> Int {
        text.reduce(0) { $1 == "\t" ? nextStop(after: $0) : $0 + 1 }
    }

    func whitespace(to column: Int) -> String {
        switch style {
        case .spaces: String(repeating: " ", count: column)
        case .tabs: String(repeating: "\t", count: column / width) + String(repeating: " ", count: column % width)
        }
    }

    static func detect(in text: NSString) -> Self {
        let length = min(text.length, 64 * 1_024)
        var counts: [Int: Int] = [:]
        var tabs = 0
        var spaces = 0
        var previousSpaces = 0
        var offset = 0
        var lines = 0
        while offset < length, lines < 1_000 {
            var leadingSpaces = 0
            var leadingTabs = 0
            while offset < length {
                let unit = text.character(at: offset)
                if unit == 0x20 { leadingSpaces += 1 }
                else if unit == 0x09 { leadingTabs += 1 }
                else { break }
                offset += 1
            }
            guard offset < length else { break }
            let unit = text.character(at: offset)
            if unit != 0x0A && unit != 0x0D {
                if leadingTabs > 0 {
                    tabs += 1
                    previousSpaces = 0
                } else {
                    if leadingSpaces > 1 { spaces += 1 }
                    let difference = abs(leadingSpaces - previousSpaces)
                    if detectableWidths.contains(difference) { counts[difference, default: 0] += 1 }
                    previousSpaces = leadingSpaces
                }
            }
            while offset < length, text.character(at: offset) != 0x0A, text.character(at: offset) != 0x0D {
                offset += 1
            }
            if offset < length, text.character(at: offset) == 0x0D { offset += 1 }
            if offset < length, text.character(at: offset) == 0x0A { offset += 1 }
            lines += 1
        }
        if tabs > spaces { return Indentation(style: .tabs, width: standard.width) }
        let width = detectableWidths.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? standard.width
        return Indentation(style: .spaces, width: counts[width] == nil ? standard.width : width)
    }
}

@MainActor
final class FileIndentationOverrides {
    private static let key = "fileIndentationOverrides"
    private let defaults: UserDefaults?
    private var values: [String: Indentation]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let decoded = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Indentation].self, from: $0) }
        values = decoded?.filter { Indentation.widths.contains($0.value.width) } ?? [:]
    }

    subscript(file: URL) -> Indentation? {
        get { values[file.path] }
        set {
            guard values[file.path] != newValue else { return }
            values[file.path] = newValue
            persist()
        }
    }

    func move(from source: URL, to destination: URL) {
        let moved = values.compactMap { path, indentation -> (String, String, Indentation)? in
            guard let suffix = DocumentWindow.worktreePathSuffix(from: source, to: URL(fileURLWithPath: path)) else { return nil }
            return (path, suffix.isEmpty ? destination.path : destination.appending(path: suffix).path, indentation)
        }
        guard !moved.isEmpty else { return }
        for (path, _, _) in moved { values.removeValue(forKey: path) }
        for (_, path, value) in moved { values[path] = value }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        defaults.set(try? JSONEncoder().encode(values), forKey: Self.key)
    }
}
