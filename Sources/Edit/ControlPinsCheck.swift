import Foundation

@MainActor
enum ControlPinsCheck {
    static func run() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appending(path: "first.swift", directoryHint: .notDirectory)
        let second = base.appending(path: "second.swift", directoryHint: .notDirectory)
        let third = base.appending(path: "third.swift", directoryHint: .notDirectory)
        let alias = base.appending(path: "alias.swift", directoryHint: .notDirectory)
        let hardLink = base.appending(path: "hard-link.swift", directoryHint: .notDirectory)
        try Data().write(to: first)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        try FileManager.default.linkItem(at: first, to: hardLink)
        guard let recent = RecentFile.read(alias), let hardLinkIdentity = FileIdentity.at(hardLink) else {
            throw Failure("read file aliases")
        }

        let domain = "Edit.ControlPinsCheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw Failure("create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let pins = ControlPins(defaults: defaults)

        let firstEntry = ControlEntry(id: recent.url.absoluteString, title: "alias.swift", recent: recent)
        let secondEntry = ControlEntry(id: second.absoluteString, title: "second.swift", folderFileURL: second)
        let thirdEntry = ControlEntry(id: third.absoluteString, title: "third.swift", folderFileURL: third)
        let hardLinkEntry = ControlEntry(id: hardLink.absoluteString, title: "hard-link.swift",
                                         folderFileURL: hardLink, folderFileIdentity: hardLinkIdentity)
        let canonicalEntry = ControlEntry(id: recent.canonicalURL.absoluteString, title: "first.swift",
                                          folderFileURL: recent.canonicalURL)
        let copy = ControlEntry(id: "copy", title: "Edit: Copy")
        let save = ControlEntry(id: "save", title: "File: Save")
        let firstPin = ControlPin.file(recent.url, canonicalURL: recent.canonicalURL, identity: recent.identity)
        let secondPin = ControlPin.file(second, canonicalURL: second, identity: nil)
        let thirdPin = ControlPin.file(third, canonicalURL: third, identity: nil)
        let copyPin = ControlPin.command(copy.id)
        let savePin = ControlPin.command(save.id)

        pins.toggle(copyPin, for: copy)
        pins.toggle(firstPin, for: firstEntry)
        pins.toggle(savePin, for: save)
        pins.toggle(secondPin, for: secondEntry)
        pins.toggle(thirdPin, for: thirdEntry)
        try expect(pins.pin(matching: canonicalEntry) == firstPin, "recognize the canonical file path")
        try expect(pins.pin(matching: hardLinkEntry) == firstPin, "recognize hard links by identity")
        try expect(pins.pin(matching: secondEntry) == secondPin, "pin a file directly from folder search")

        try expect(pins.reorder([thirdPin, firstPin]), "reorder one visible subset without moving a hidden file")
        try expect(pins.reorder([savePin, copyPin]), "reorder the pinned commands")
        try expect(!pins.reorder([firstPin, savePin]), "keep the two orders independent")
        try expect(!pins.reorder([firstPin, firstPin]), "reject duplicate pins")
        try expect(!pins.reorder([firstPin, .file(alias, canonicalURL: alias, identity: nil)]), "reject an unpinned file")
        try expect(!pins.reorder([savePin, copyPin]), "preserve the existing order on a no-op")
        let restored = ControlPins(defaults: defaults)
        try expect(restored.entries == [thirdPin, secondPin, firstPin, savePin, copyPin], "restore the saved pin order")

        let aliasPin = ControlPin.file(hardLink, canonicalURL: hardLink, identity: hardLinkIdentity)
        restored.toggle(aliasPin, for: hardLinkEntry)
        try expect(restored.pin(matching: firstEntry) == nil, "unpin through a different spelling of the path")
        try expect(ControlPins(defaults: defaults).entries == [thirdPin, secondPin, savePin, copyPin], "persist removal")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let message: String

        init(_ message: String) { self.message = message }

        var errorDescription: String? { "Control pins could not \(message)." }
    }
}
