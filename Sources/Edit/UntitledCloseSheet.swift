import AppKit
import UniformTypeIdentifiers

// AppKit owns the close sheet. Edit remains responsible for writing the buffer.
@MainActor
final class UntitledCloseSheet: NSDocument {
    enum Decision {
        case close
        case cancel
        case scratch(name: String, encoding: FileTextEncoding)
    }

    private let parent: NSWindow
    private let folder: URL?
    private let saveDraft: (URL, FileTextEncoding) async -> Bool
    private var accessory: SavePanelAccessory?
    private var closeReply: CheckedContinuation<Decision, Never>?

    init(window: NSWindow, folder: URL?, saveDraft: @escaping (URL, FileTextEncoding) async -> Bool) {
        parent = window
        self.folder = folder
        self.saveDraft = saveDraft
        super.init()
        fileType = UTType.plainText.identifier
        displayName = "Untitled"
        updateChangeCount(.changeDone)
    }

    override nonisolated class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { false }
    override var windowForSheet: NSWindow? { parent }

    override nonisolated func writableTypes(for saveOperation: SaveOperationType) -> [String] {
        [UTType.plainText.identifier]
    }

    override func scheduleAutosaving() {}

    func confirmClose() async -> Decision {
        await withCheckedContinuation { reply in
            closeReply = reply
            canClose(withDelegate: self, shouldClose: #selector(didDecideClose(_:shouldClose:contextInfo:)),
                     contextInfo: nil)
        }
    }

    @objc private func didDecideClose(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let reply = closeReply
        closeReply = nil
        if let accessory, let name = accessory.scratchName {
            reply?.resume(returning: .scratch(name: name, encoding: accessory.selection))
        } else {
            reply?.resume(returning: shouldClose ? .close : .cancel)
        }
    }

    override func prepareSavePanel(_ panel: NSSavePanel) -> Bool {
        panel.nameFieldStringValue = "Untitled.txt"
        if let folder { panel.directoryURL = folder }
        panel.allowsOtherFileTypes = true
        panel.showsTagField = false
        panel.canSelectHiddenExtension = false
        panel.isExtensionHidden = false

        let accessory = SavePanelAccessory(selected: .utf8, scratchPanel: panel)
        panel.accessoryView = accessory
        self.accessory = accessory
        return true
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        Task {
            let didSave = await saveDraft(url, accessory?.selection ?? .utf8)
            completionHandler(didSave ? nil : CocoaError(.userCancelled))
        }
    }
}
