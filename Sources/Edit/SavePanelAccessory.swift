import AppKit

@MainActor
final class SavePanelAccessory: NSStackView {
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var scratchPanel: NSSavePanel?
    private(set) var scratchName: String?

    var selection: FileTextEncoding {
        let index = picker.indexOfSelectedItem
        let encodings = FileTextEncoding.allCases
        return encodings.indices.contains(index) ? encodings[index] : .utf8
    }

    init(selected: FileTextEncoding, scratchPanel: NSSavePanel? = nil) {
        self.scratchPanel = scratchPanel
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "Plain Text Encoding:")
        picker.setAccessibilityLabel("Plain Text Encoding")
        let encodings = FileTextEncoding.allCases
        picker.addItems(withTitles: encodings.map(\.title))
        if let index = encodings.firstIndex(of: selected) { picker.selectItem(at: index) }

        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        addArrangedSubview(label)
        addArrangedSubview(picker)
        if scratchPanel != nil {
            let button = NSButton(title: "Scratch", target: self, action: #selector(saveScratch))
            addArrangedSubview(button)
        }
        // An expanded file browser must never become the minimum width of a compact sheet.
        setFrameSize(fittingSize)
    }

    @objc private func saveScratch() {
        guard let scratchPanel, scratchName == nil else { return }
        scratchName = scratchPanel.nameFieldStringValue
        // Return through the panel's normal completion before saving to Edit's scratch storage.
        scratchPanel.cancel(scratchPanel)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("SavePanelAccessory is created in code.") }
}
