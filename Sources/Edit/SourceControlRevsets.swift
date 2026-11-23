import Foundation

struct SourceControlRevset: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let expression: String?

    static let defaultLog = Self(id: "default", name: "Default Log", expression: nil)
    static let allChanges = Self(id: "all", name: "All Changes", expression: "all()")
}

struct SourceControlRevsets: Codable, Sendable {
    private(set) var custom: [SourceControlRevset] = []
    private var selectedID = SourceControlRevset.defaultLog.id

    var entries: [SourceControlRevset] { [.defaultLog, .allChanges] + custom }
    var selected: SourceControlRevset { entries.first { $0.id == selectedID } ?? .defaultLog }
    var canEditSelected: Bool { custom.contains { $0.id == selected.id } }

    private enum Failure: LocalizedError {
        case missing, duplicateName

        var errorDescription: String? {
            switch self {
            case .missing: "This revset is no longer available."
            case .duplicateName: "A revset with this name already exists."
            }
        }
    }

    mutating func select(_ id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { throw Failure.missing }
        selectedID = id
    }

    mutating func save(name: String, expression: String, replacing id: String?) throws {
        guard !entries.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw Failure.duplicateName
        }
        if let id {
            guard let index = custom.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
            custom[index] = SourceControlRevset(id: id, name: name, expression: expression)
            selectedID = id
        } else {
            let entry = SourceControlRevset(id: UUID().uuidString, name: name, expression: expression)
            custom.append(entry)
            selectedID = entry.id
        }
    }

    mutating func remove(_ id: String) {
        custom.removeAll { $0.id == id }
        if selectedID == id { selectedID = SourceControlRevset.defaultLog.id }
    }
}

struct SourceControlRevsetStore {
    let url: URL

    func read(for workspace: JJWorkspace) throws -> SourceControlRevsets {
        try readProjects()[workspace.root.path] ?? SourceControlRevsets()
    }

    func update(for workspace: JJWorkspace, _ change: (inout SourceControlRevsets) throws -> Void) throws -> SourceControlRevsets {
        var projects = try readProjects()
        var settings = projects[workspace.root.path] ?? SourceControlRevsets()
        try change(&settings)
        projects[workspace.root.path] = settings
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(projects).write(to: url, options: .atomic)
        return settings
    }

    private func readProjects() throws -> [String: SourceControlRevsets] {
        do {
            return try JSONDecoder().decode([String: SourceControlRevsets].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
    }
}
