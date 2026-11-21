import AppKit

@MainActor
final class SaveEncodingAccessory: NSStackView {
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)

    var selection: FileTextEncoding {
        let index = picker.indexOfSelectedItem
        let encodings = FileTextEncoding.allCases
        return encodings.indices.contains(index) ? encodings[index] : .utf8
    }

    init(selected: FileTextEncoding) {
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
        // An expanded file browser must never become the minimum width of a compact sheet.
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("SaveEncodingAccessory is created in code.") }
}
