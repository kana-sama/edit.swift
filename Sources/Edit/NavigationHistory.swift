import Foundation

/// The unfiltered editor location stack. A nearby ordinary selection updates its current stop.
@MainActor
final class NavigationHistory {
    enum Direction {
        case back, forward

        fileprivate var step: Int { self == .back ? -1 : 1 }
    }

    enum Reason {
        case selection, edit, jump
    }

    enum Resource: Equatable {
        case file(URL)
        case buffer(UUID)
        case revision(String)
    }

    struct Selection: Equatable {
        struct Anchor {
            let offset: Int
            fileprivate let line: Int
        }

        private struct Position: Equatable {
            let line: Int
            let column: Int
        }

        private let start: Position
        private let end: Position
        let isBackward: Bool
        let anchor: Anchor

        fileprivate var line: Int { start.line }

        init?(range: NSRange, in content: String, activeEnd: Int? = nil, previousAnchor: Anchor? = nil) {
            self.init(range: range, in: content as NSString, activeEnd: activeEnd, previousAnchor: previousAnchor)
        }

        init?(range: NSRange, in text: NSString, activeEnd: Int? = nil, previousAnchor: Anchor? = nil) {
            guard range.location >= 0, range.location <= text.length,
                  range.length >= 0, range.length <= text.length - range.location else { return nil }

            let firstLine = LineEditing.line(at: range.location, in: text)
            let firstLineNumber = Self.lineNumber(at: firstLine.start, from: previousAnchor, in: text)
            let lastLine = LineEditing.line(at: range.upperBound, in: text)
            anchor = Anchor(offset: firstLine.start, line: firstLineNumber)
            start = Position(line: firstLineNumber, column: range.location - firstLine.start)
            end = Position(line: Self.lineNumber(at: lastLine.start, from: anchor, in: text),
                           column: range.upperBound - lastLine.start)
            isBackward = range.length > 0 && activeEnd == range.location
        }

        static func == (lhs: Selection, rhs: Selection) -> Bool {
            lhs.start == rhs.start && lhs.end == rhs.end && lhs.isBackward == rhs.isBackward
        }

        func range(in content: String) -> NSRange {
            let text = content as NSString
            let startOffset = Self.offset(of: start, in: text)
            let endOffset = Self.offset(of: end, in: text)
            return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
        }

        private static func lineNumber(at lineStart: Int, from anchor: Anchor?, in text: NSString) -> Int {
            let reference = anchor.flatMap {
                $0.offset <= text.length && abs($0.offset - lineStart) <= lineStart ? $0 : nil
            }
            var cursor = reference?.offset ?? 0
            var number = reference?.line ?? 0
            while cursor < lineStart {
                let next = LineEditing.line(at: cursor, in: text).end
                guard next > cursor else { break }
                cursor = next
                number += 1
            }
            while cursor > lineStart {
                let previous = LineEditing.line(at: cursor - 1, in: text).start
                guard previous < cursor else { break }
                cursor = previous
                number -= 1
            }
            return number
        }

        private static func offset(of position: Position, in text: NSString) -> Int {
            var line = LineEditing.line(at: 0, in: text)
            for _ in 0..<position.line {
                guard line.end > line.start, line.end > line.contentEnd else { return text.length }
                line = LineEditing.line(at: line.end, in: text)
            }
            let offset = min(line.contentEnd, line.start + position.column)
            return offset > line.start && offset < text.length && (0xDC00...0xDFFF).contains(text.character(at: offset))
                ? offset - 1 : offset
        }
    }

    struct Location: Equatable {
        let window: ObjectIdentifier
        let resource: Resource
        let selection: Selection?
        var markdown: MarkdownViewState? = nil

        fileprivate func matchesEditor(_ other: Location) -> Bool {
            window == other.window && resource == other.resource
        }
    }

    struct Move: Equatable {
        fileprivate let id: UInt64
        fileprivate let index: Int
        let location: Location
    }

    private static let limit = 50
    private static let nearbyLineCount = 10
    private var entries: [Location] = []
    private var index = -1
    private var moveID: UInt64 = 0
    private var pending: Move?

    func record(_ location: Location, reason: Reason) {
        guard !entries.indices.contains(index) || entries[index] != location else { return }
        pending = nil
        if let current = entries.indices.contains(index) ? entries[index] : nil,
           current.matchesEditor(location) {
            if let old = current.selection, let new = location.selection {
                let distance = abs(old.line - new.line)
                if distance == 0 || (distance < Self.nearbyLineCount && reason != .jump) {
                    entries[index] = location
                    return
                }
            } else if current.selection == nil {
                entries[index] = location
                return
            } else if location.selection == nil {
                return
            }
        }
        entries.replaceSubrange((index + 1)..., with: [location])
        if entries.count > Self.limit { entries.removeFirst() }
        index = entries.count - 1
    }

    func canGo(_ direction: Direction) -> Bool {
        entries.indices.contains((pending?.index ?? index) + direction.step)
    }

    func begin(_ direction: Direction) -> Move? {
        let next = (pending?.index ?? index) + direction.step
        guard entries.indices.contains(next) else { return nil }
        moveID &+= 1
        let move = Move(id: moveID, index: next, location: entries[next])
        pending = move
        return move
    }

    func isPending(_ move: Move) -> Bool { pending?.id == move.id }

    func finish(_ move: Move, opened: Bool) {
        guard let pending, pending.id == move.id else { return }
        if opened { index = pending.index }
        self.pending = nil
    }

    func remove(window: ObjectIdentifier, resource: Resource? = nil) {
        remove { location in
            location.window == window && (resource == nil || location.resource == resource)
        }
    }

    func removeFiles(matching isRemoved: (URL) -> Bool) {
        remove { location in
            guard case .file(let url) = location.resource else { return false }
            return isRemoved(url)
        }
    }

    func moveFiles(using destination: (URL) -> URL?) {
        for index in entries.indices {
            let location = entries[index]
            guard case .file(let url) = location.resource, let moved = destination(url) else { continue }
            entries[index] = Location(window: location.window, resource: .file(moved), selection: location.selection,
                                      markdown: location.markdown)
            if pending?.index == index { pending = nil }
        }
    }

    private func remove(matching isRemoved: (Location) -> Bool) {
        let survivors = entries.enumerated().filter { !isRemoved($0.element) }
        guard survivors.count != entries.count else { return }
        if let pending, let newIndex = survivors.firstIndex(where: { $0.offset == pending.index }) {
            self.pending = Move(id: pending.id, index: newIndex, location: pending.location)
        } else {
            pending = nil
        }
        index = survivors.lastIndex(where: { $0.offset <= index }) ?? -1
        entries = survivors.map(\.element)
    }
}
