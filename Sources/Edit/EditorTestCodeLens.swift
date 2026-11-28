import AppKit

@MainActor
final class EditorTestCodeLens: NSObject {
    private static let gap: CGFloat = 12
    private static let trailingInset: CGFloat = 8
    private unowned let editor: EditorTextView
    private var file: URL?
    private var source: String?
    private var discovery: Task<[ZigTestDeclaration]?, Never>?
    private var staleTimeout: Task<Void, Never>?
    private var tests: [ZigTestDeclaration] = []
    private var buttons: [Button] = []
    private(set) var minimumWidth: CGFloat = 0
    var run: ((ZigTestDeclaration) -> Void)?

    init(editor: EditorTextView) { self.editor = editor }

    deinit {
        discovery?.cancel()
        staleTimeout?.cancel()
    }

    func reset() {
        discovery?.cancel()
        discovery = nil
        staleTimeout?.cancel()
        staleTimeout = nil
        file = nil
        source = nil
        tests = []
        removeButtons(startingAt: 0)
        setMinimumWidth(0)
    }

    func update(file: URL?) {
        if self.file != file { reset() }
        guard let file else { return }
        self.file = file
        let source = editor.sourceString
        guard source != self.source else { return }
        self.source = source
        discovery?.cancel()
        if staleTimeout == nil, !tests.isEmpty {
            staleTimeout = Task { [weak self] in
                guard (try? await Task.sleep(for: .milliseconds(750))) != nil, let self else { return }
                tests = []
                staleTimeout = nil
                editor.requestLineRefresh()
            }
        }
        let analysis = editor.syntaxAnalysis
        let task = Task { () -> [ZigTestDeclaration]? in
            if source.isEmpty { return [] }
            guard let tree = await analysis.tree(in: source, language: .zig), !Task.isCancelled else { return nil }
            let query = Task.detached(priority: .userInitiated) { tree.zigTests() }
            return await withTaskCancellationHandler { await query.value } onCancel: { query.cancel() }
        }
        discovery = task
        Task { [weak self] in
            guard let tests = await task.value, !task.isCancelled, let self else { return }
            staleTimeout?.cancel()
            staleTimeout = nil
            self.tests = tests
            editor.requestLineRefresh()
        }
    }

    func sourceDidEdit(_ changes: [EditorTextChange]) {
        guard !tests.isEmpty else { return }
        tests = tests.compactMap { test in
            var test = test
            for change in changes.reversed() {
                if change.range.upperBound <= test.header.location {
                    test.header.location += change.delta
                } else if change.range.location < test.header.location + 4 {
                    return nil
                } else if change.range.location < test.header.upperBound {
                    test.header.length = max(4, test.header.length + change.delta)
                }
            }
            return test
        }
    }

    func isCurrent(_ test: ZigTestDeclaration, file: URL) async -> Bool {
        guard self.file == file, let task = discovery, let source, let discovered = await task.value else { return false }
        return !task.isCancelled && self.file == file && editor.sourceString == source && discovered.contains(test)
    }

    func layout() {
        guard !tests.isEmpty, editor.renameRange == nil, !editor.hasMarkedText(), editor.conflictEdits.isEmpty,
              let manager = editor.textLayoutManager, let viewport = manager.textViewportLayoutController.viewportRange else {
            removeButtons(startingAt: 0)
            if tests.isEmpty || editor.wrapsWords { setMinimumWidth(0) }
            return
        }
        let visible = editor.charRange(viewport, in: manager)
        let font = NSFont.systemFont(ofSize: max(10, (editor.font ?? EditorTextView.defaultFont).pointSize - 1))
        let width = ceil(("Run test" as NSString).size(withAttributes: [.font: font]).width) + 8
        var rowEnd: [CGFloat: CGFloat] = [:]
        var count = 0
        var requiredWidth = editor.wrapsWords ? 0 : minimumWidth
        for test in tests where NSLocationInRange(test.header.location, visible) {
            guard let row = editor.laidOutLineBounds(at: test.header.location),
                  row.maxY > editor.visibleRect.minY, row.minY < editor.visibleRect.maxY else { continue }
            let x = max(row.maxX, rowEnd[row.minY] ?? 0) + Self.gap
            let frame = NSRect(x: x, y: row.minY, width: width, height: row.height)
            let edge = frame.maxX + Self.trailingInset
            guard !editor.wrapsWords || edge <= editor.bounds.maxX else { continue }
            rowEnd[row.minY] = frame.maxX
            requiredWidth = editor.wrapsWords ? 0 : max(requiredWidth, edge)
            let button = count < buttons.count ? buttons[count] : addButton()
            button.configure(test: test, font: font)
            if button.frame != frame { button.frame = frame }
            count += 1
        }
        removeButtons(startingAt: count)
        setMinimumWidth(requiredWidth)
    }

    func trailingEdge(on row: NSRect) -> CGFloat? {
        buttons.last(where: { abs($0.frame.minY - row.minY) < 0.5 })?.frame.maxX
    }

    func menuItems(at offset: Int) -> [NSMenuItem] {
        guard editor.renameRange == nil, !editor.hasMarkedText(), editor.conflictEdits.isEmpty,
              let text = editor.textStorage?.mutableString, (0...text.length).contains(offset),
              let row = editor.laidOutLineBounds(at: offset) else { return [] }
        let line = LineEditing.line(at: offset, in: text).contentRange
        let onRow = tests.filter {
            NSLocationInRange($0.header.location, line) && editor.laidOutLineBounds(at: $0.header.location)?.minY == row.minY
        }
        return onRow.map { test in
            let title = onRow.count == 1 ? "Run test" : "Run test “\(test.name)”"
            let item = NSMenuItem(title: title, action: #selector(activate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = test
            return item
        }
    }

    private func setMinimumWidth(_ width: CGFloat) {
        let previous = minimumWidth
        guard width != previous else { return }
        minimumWidth = width
        if editor.frame.width < width {
            editor.setFrameSize(NSSize(width: ceil(width), height: editor.frame.height))
        } else if !editor.wrapsWords, width < previous, editor.frame.width <= ceil(previous),
                  let scroll = editor.enclosingScrollView, let manager = editor.textLayoutManager {
            let textWidth = ceil(manager.usageBoundsForTextContainer.maxX + 2 * editor.textContainerOrigin.x)
            editor.setFrameSize(NSSize(width: max(scroll.contentSize.width, textWidth, width), height: editor.frame.height))
        }
    }

    private func addButton() -> Button {
        let button = Button(frame: .zero)
        button.title = "Run test"
        button.isBordered = false
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(activate(_:))
        button.identifier = .init("Edit.TestCodeLens.Run")
        editor.addSubview(button, positioned: .above, relativeTo: nil)
        buttons.append(button)
        return button
    }

    private func removeButtons(startingAt index: Int) {
        guard index < buttons.count else { return }
        for button in buttons[index...] { button.removeFromSuperview() }
        buttons.removeLast(buttons.count - index)
    }

    @objc private func activate(_ sender: Any) {
        if let test = (sender as? Button)?.test ?? (sender as? NSMenuItem)?.representedObject as? ZigTestDeclaration {
            run?(test)
        }
    }

    private final class Button: NSButton {
        private(set) var test: ZigTestDeclaration?

        func configure(test: ZigTestDeclaration, font: NSFont) {
            if self.test != test {
                self.test = test
                toolTip = "Run test “\(test.name)”"
                setAccessibilityLabel(toolTip)
            }
            if self.font != font {
                self.font = font
                attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.linkColor])
            }
        }
    }
}
