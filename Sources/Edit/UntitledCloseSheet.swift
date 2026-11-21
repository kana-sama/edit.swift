import AppKit
import UniformTypeIdentifiers

// AppKit owns the close sheet. Edit remains responsible for writing the buffer.
@MainActor
final class UntitledCloseSheet: NSDocument {
    private let parent: NSWindow
    private let saveDraft: (URL, FileTextEncoding) async -> Bool
    private lazy var encodingAccessory = SaveEncodingAccessory(selected: .utf8)
    private var closeReply: CheckedContinuation<Bool, Never>?

    init(window: NSWindow, saveDraft: @escaping (URL, FileTextEncoding) async -> Bool) {
        parent = window
        self.saveDraft = saveDraft
        super.init()
        fileType = UTType.plainText.identifier
        displayName = window.title
        updateChangeCount(.changeDone)
    }

    override nonisolated class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { false }
    override var windowForSheet: NSWindow? { parent }

    override nonisolated func writableTypes(for saveOperation: SaveOperationType) -> [String] {
        [UTType.plainText.identifier]
    }

    override func scheduleAutosaving() {}

    func confirmClose() async -> Bool {
        await withCheckedContinuation { reply in
            closeReply = reply
            canClose(withDelegate: self, shouldClose: #selector(didDecideClose(_:shouldClose:contextInfo:)),
                     contextInfo: nil)
        }
    }

    @objc private func didDecideClose(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let reply = closeReply
        closeReply = nil
        reply?.resume(returning: shouldClose)
    }

    override func prepareSavePanel(_ panel: NSSavePanel) -> Bool {
        panel.nameFieldStringValue = "Untitled.txt"
        panel.allowsOtherFileTypes = true
        panel.showsTagField = false
        panel.canSelectHiddenExtension = false
        panel.isExtensionHidden = false

        panel.accessoryView = encodingAccessory
        return true
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        Task {
            let didSave = await saveDraft(url, encodingAccessory.selection)
            completionHandler(didSave ? nil : CocoaError(.userCancelled))
        }
    }
}
