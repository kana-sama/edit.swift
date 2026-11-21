import Foundation

enum ControlPin: Codable, Hashable, Sendable {
    case file(URL, canonicalURL: URL, identity: FileIdentity?)
    case command(String)

    var fileURL: URL? {
        if case let .file(url, _, _) = self { return url }
        return nil
    }

    func matches(_ entry: ControlEntry) -> Bool {
        switch self {
        case let .command(id):
            return entry.fileURL == nil && entry.id == id
        case let .file(url, canonicalURL, identity):
            guard let candidate = entry.fileURL else { return false }
            let candidateCanonicalURL = entry.recent?.canonicalURL ?? candidate
            let candidateIdentity = entry.recent?.identity ?? entry.folderFileIdentity
            if let identity, identity == candidateIdentity { return true }

            let path = candidate.path
            let canonicalPath = candidateCanonicalURL.path
            let pinnedPath = url.path
            let pinnedCanonicalPath = canonicalURL.path
            return path == pinnedPath || path == pinnedCanonicalPath
                || canonicalPath == pinnedPath || canonicalPath == pinnedCanonicalPath
        }
    }
}

@MainActor
final class ControlPins {
    private static let key = "control-pins"
    private let defaults: UserDefaults?
    private(set) var entries: [ControlPin]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: Self.key)
        entries = saved.flatMap { try? JSONDecoder().decode([ControlPin].self, from: $0) } ?? []
    }

    func pin(matching entry: ControlEntry) -> ControlPin? {
        entries.first { $0.matches(entry) }
    }

    func toggle(_ pin: ControlPin, for entry: ControlEntry) {
        if let index = entries.firstIndex(where: { $0.matches(entry) }) {
            entries.remove(at: index)
        } else if pin.fileURL != nil, let firstCommand = entries.firstIndex(where: { $0.fileURL == nil }) {
            entries.insert(pin, at: firstCommand)
        } else {
            entries.append(pin)
        }
        persist()
    }

    @discardableResult
    func reorder(_ pins: [ControlPin]) -> Bool {
        guard let first = pins.first, pins.count > 1 else { return false }
        let reordered = Set(pins)
        let areFiles = first.fileURL != nil
        guard reordered.count == pins.count, pins.allSatisfy({ ($0.fileURL != nil) == areFiles }) else {
            return false
        }

        // Reordering a filtered list keeps the slots of pins outside that list.
        let slots = entries.indices.filter { reordered.contains(entries[$0]) }
        guard slots.count == pins.count,
              zip(slots, pins).contains(where: { entries[$0] != $1 }) else { return false }
        for (slot, pin) in zip(slots, pins) { entries[slot] = pin }
        persist()
        return true
    }

    private func persist() {
        guard let defaults, let saved = try? JSONEncoder().encode(entries) else { return }
        defaults.set(saved, forKey: Self.key)
    }
}
