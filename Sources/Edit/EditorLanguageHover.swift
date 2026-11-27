import AppKit

struct EditorLanguageHover: Sendable {
    let text: String
    let isMarkdown: Bool
    let range: NSRange?
    let server: LanguageServer
    let solidityDocumentation: SolarHover.Documentation?

    var presentation: EditorHoverPresentation {
        EditorHoverPresentation(text: text, isMarkdown: isMarkdown, server: server, solidityDocumentation: solidityDocumentation)
    }
}

enum HoverLink {
    case external(URL)
    case definition(LSPLocation)

    init?(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            self = .external(url)
        case "file":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["", "localhost"].contains(components.host?.lowercased() ?? ""),
                  components.user == nil, components.password == nil, components.port == nil, components.query == nil,
                  components.path.hasPrefix("/"), !components.path.utf8.contains(0), !url.hasDirectoryPath,
                  let fragment = components.fragment, fragment.first == "L" else { return nil }
            let digits = fragment.dropFirst()
            guard digits.utf8.allSatisfy({ (48...57).contains($0) }), let line = Int(digits), line > 0 else { return nil }
            let position = LSPPosition(line: line - 1, character: 0)
            let file = URL(filePath: components.path, directoryHint: .notDirectory)
            self = .definition(LSPLocation(url: file, range: LSPRange(start: position, end: position)))
        default:
            return nil
        }
    }
}

struct EditorHoverContent: Sendable {
    struct NatSpecLayout {
        let labelFont: NSFont
        let descriptionColumn: CGFloat?
    }

    private struct Run: Sendable {
        let text: String
        var emphasis = false
        var strong = false
        var code = false
        var crossedOut = false
        var link: URL?
    }

    private struct Block: Sendable {
        struct Cell: Sendable {
            let table: Int
            let columnCount: Int
            let row: Int
            let column: Int
            let alignment: NSTextAlignment
        }

        var identity: Int?
        var heading: Int?
        var listMarker: String?
        var indentation = 0
        var isQuote = false
        var isCode = false
        var codeLanguage: SyntaxLanguage?
        var codeSpans: [SyntaxSpan] = []
        var soliditySignature: SolidityHoverSignature?
        var cell: Cell?
        var isTopLevelParagraph = false
        var alignedFields: [OLSHover.Field]?
        var continuesNatSpecField = false
        var runs: [Run] = []

        var natSpecName: String? {
            guard let first = runs.first, first.code,
                  runs.dropFirst().first?.text.hasPrefix(": ") == true else { return nil }
            return first.text
        }
    }

    private let blocks: [Block]

    init(code snippets: [String], language: SyntaxLanguage) {
        blocks = snippets.map { snippet in
            let spans = Task.isCancelled ? [] : SyntaxEngine.analysis(in: snippet, language: language, includesBrackets: false)?.spans ?? []
            return Block(isCode: true, codeSpans: spans, runs: [Run(text: snippet)])
        }
    }

    init(references: [ZLSHover.Reference]) {
        var runs: [Run] = []
        for reference in references {
            if !runs.isEmpty { runs.append(Run(text: ", ")) }
            runs.append(Run(text: reference.title, link: reference.url))
        }
        blocks = [Block(runs: runs)]
    }

    init(text: String, isMarkdown: Bool, preservesSoftBreaks: Bool = false) {
        let options = AttributedString.MarkdownParsingOptions(appliesSourcePositionAttributes: preservesSoftBreaks)
        guard isMarkdown, let value = try? AttributedString(markdown: text, options: options), !value.characters.isEmpty else {
            blocks = [Block(runs: [Run(text: text)])]
            return
        }

        var blocks: [Block] = []
        for run in value.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            if blocks.isEmpty || blocks.last?.identity != identity {
                let isOrdered = components.contains { $0.kind == .orderedList }
                var block = Block(identity: identity)
                block.isTopLevelParagraph = components.count == 1 && components.first?.kind == .paragraph
                var table: (id: Int, columns: [PresentationIntent.TableColumn])?
                var row: Int?
                var column: Int?
                for component in components {
                    switch component.kind {
                    case .header(let level): block.heading = level
                    case .listItem(let ordinal):
                        if block.listMarker == nil { block.listMarker = isOrdered ? "\(ordinal). " : "• " }
                        block.indentation += 1
                    case .blockQuote: block.isQuote = true
                    case .codeBlock(let hint):
                        block.isCode = true
                        block.codeLanguage = hint.flatMap { SyntaxLanguage(rawValue: $0.lowercased()) }
                    case .table(let columns): table = (component.identity, columns)
                    case .tableHeaderRow: row = 0
                    case .tableRow(let index): row = index
                    case .tableCell(let index): column = index
                    default: break
                    }
                }
                if let table, let row, let column, table.columns.indices.contains(column) {
                    let alignment: NSTextAlignment = switch table.columns[column].alignment {
                    case .right: .right
                    case .center: .center
                    default: .left
                    }
                    block.cell = .init(table: table.id, columnCount: table.columns.count, row: row,
                                       column: column, alignment: alignment)
                }
                blocks.append(block)
            }

            let attributes = run.inlinePresentationIntent ?? []
            let link = run.link.flatMap { HoverLink($0) == nil ? nil : $0 }
            var text = String(value[run.range].characters)
            // Foundation emits a synthetic space for a Markdown soft break.
            if preservesSoftBreaks, text == " ", run.markdownSourcePosition == nil, components.first?.kind == .paragraph {
                text = "\n"
            }
            blocks[blocks.count - 1].runs.append(Run(text: text,
                                                     emphasis: attributes.contains(.emphasized),
                                                     strong: attributes.contains(.stronglyEmphasized),
                                                     code: attributes.contains(.code),
                                                     crossedOut: attributes.contains(.strikethrough), link: link))
        }

        for index in blocks.indices {
            if Task.isCancelled { break }
            if let language = blocks[index].codeLanguage {
                let code = blocks[index].runs.map(\.text).joined()
                blocks[index].codeSpans = SyntaxEngine.analysis(in: code, language: language, includesBrackets: false)?.spans ?? []
            } else if preservesSoftBreaks, blocks[index].isTopLevelParagraph {
                blocks[index].alignedFields = OLSHover.alignedFields(in: blocks[index].runs.map(\.text).joined())
            }
        }
        self.blocks = blocks
    }

    private init(blocks: [Block]) { self.blocks = blocks }

    private enum NatSpecField: String {
        case notes = "@dev"
        case parameter = "@param"
        case result = "@return"
    }

    func natSpecSections(source: SolarHover.Documentation?) -> [EditorHoverPresentation.Section] {
        var declaration = blocks.first.flatMap { $0.codeLanguage == .solidity ? $0 : nil }
        if let code = declaration?.runs.map(\.text).joined() {
            declaration?.soliditySignature = SolidityHoverSignature(code)
        }
        var description: [Block] = []
        var developer: [Block] = []
        var parameters: [Block] = []
        var returns: [Block] = []
        var field: NatSpecField?
        for index in blocks.indices.dropFirst(declaration == nil ? 0 : 1) {
            var block = blocks[index]
            if let tag = Self.natSpecField(in: block) {
                if tag == .notes || (blocks.indices.contains(index + 1) && Self.isNatSpecItem(blocks[index + 1])) {
                    field = tag
                    continue
                }
            }
            if field == .notes {
                developer.append(block)
            } else if let tag = field, Self.isNatSpecItem(block) {
                block.indentation = 0
                block.listMarker = nil
                if tag == .parameter { parameters.append(block) }
                else { returns.append(block) }
            } else {
                field = nil
                description.append(block)
            }
        }
        if let source {
            description = source.notice.map { Self(text: $0, isMarkdown: true).blocks } ?? []
            developer = source.developer.map { Self(text: $0, isMarkdown: true).blocks } ?? []
            parameters = source.parameters.flatMap { parameter in
                Self.natSpecEntry("`\(parameter.name)`: \(parameter.text)")
            }
            let returnNames = Set(returns.compactMap(\.natSpecName))
            returns = source.returns.flatMap { body in
                let name = body.prefix(while: { !$0.isWhitespace })
                let text = returnNames.contains(String(name))
                    ? "`\(name)`: \(body[name.endIndex...].drop(while: \.isWhitespace))" : body
                return Self.natSpecEntry(text)
            }
        }
        if description.isEmpty {
            description = developer
            developer = []
        }
        let sections: [(EditorHoverPresentation.Section.Kind, [Block])] = [
            (.declaration, declaration.map { [$0] } ?? []),
            (.documentation, description),
            (.note, developer),
            (.parameters, parameters),
            (.returns, returns)
        ]
        return sections.compactMap { kind, content in
            content.isEmpty ? nil : EditorHoverPresentation.Section(kind: kind, content: Self(blocks: content))
        }
    }

    private static func natSpecField(in block: Block) -> NatSpecField? {
        // Solar renders NatSpec tags as standalone bold paragraphs in the Markdown response.
        guard block.isTopLevelParagraph, block.runs.allSatisfy({ $0.strong && !$0.code && $0.link == nil }) else { return nil }
        return NatSpecField(rawValue: block.runs.map(\.text).joined())
    }

    private static func isNatSpecItem(_ block: Block) -> Bool {
        block.listMarker == "• " && block.indentation == 1 && !block.isCode && !block.isQuote && block.cell == nil
    }

    private static func natSpecEntry(_ text: String) -> [Block] {
        var blocks = Self(text: text, isMarkdown: true).blocks
        if blocks.first?.natSpecName != nil {
            for index in blocks.indices.dropFirst() { blocks[index].continuesNatSpecField = true }
        }
        return blocks
    }

    @MainActor
    func natSpecNameWidth(using font: NSFont) -> CGFloat {
        blocks.lazy.compactMap(\.natSpecName).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }

    @MainActor
    func attributedText(maximumWidth: CGFloat = .greatestFiniteMagnitude,
                        natSpecLayout: NatSpecLayout? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let codeBackground = NSColor.labelColor.withAlphaComponent(0.075)
        var tables: [Int: NSTextTable] = [:]
        for (index, original) in blocks.enumerated() {
            var block = original
            if let signature = block.soliditySignature {
                let attributes: [NSAttributedString.Key: Any] = [.font: EditorTextView.defaultFont]
                let code = signature.formatted { ($0 as NSString).size(withAttributes: attributes).width <= maximumWidth }
                if code != block.runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) {
                    block.runs = [Run(text: code)]
                    block.codeSpans = SyntaxEngine.analysis(in: code, language: .solidity, includesBrackets: false)?.spans ?? []
                }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = block.isCode ? 0 : 2
            paragraph.lineBreakMode = .byWordWrapping
            if block.indentation > 0 {
                paragraph.firstLineHeadIndent = CGFloat(block.indentation - 1) * 14
                paragraph.headIndent = CGFloat(block.indentation) * 14
            }
            if block.isQuote {
                paragraph.firstLineHeadIndent += 12
                paragraph.headIndent += 12
            }
            let fieldName = natSpecLayout == nil ? nil : block.natSpecName
            if let natSpecLayout, let column = natSpecLayout.descriptionColumn {
                if fieldName != nil {
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
                    paragraph.headIndent = column
                } else if block.continuesNatSpecField {
                    paragraph.firstLineHeadIndent += column
                    paragraph.headIndent += column
                }
            }
            if let cell = block.cell {
                let table: NSTextTable
                if let existing = tables[cell.table] { table = existing }
                else {
                    table = NSTextTable()
                    table.numberOfColumns = cell.columnCount
                    table.collapsesBorders = true
                    tables[cell.table] = table
                }
                let box = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: 1,
                                          startingColumn: cell.column, columnSpan: 1)
                box.setWidth(5, type: .absolute, for: .padding)
                box.setWidth(1, type: .absolute, for: .border)
                box.setBorderColor(.separatorColor)
                if cell.row == 0 { box.backgroundColor = codeBackground }
                paragraph.textBlocks = [box]
                paragraph.alignment = cell.alignment
            }
            let size: CGFloat = block.heading == 1 ? 15 : block.heading != nil ? 14 : 13
            let foreground: NSColor = block.isQuote ? .secondaryLabelColor : .labelColor
            let baseFont = block.isCode ? EditorTextView.defaultFont : NSFont.systemFont(ofSize: size)
            let base = [NSAttributedString.Key.font: baseFont,
                        .foregroundColor: foreground, .paragraphStyle: paragraph] as [NSAttributedString.Key: Any]

            let blockStart = result.length
            if let marker = block.listMarker { result.append(NSAttributedString(string: marker, attributes: base)) }
            let start = result.length
            for run in block.runs {
                var attributes = base
                if run.code && !block.isCode {
                    attributes[.font] = EditorTextView.defaultFont
                    attributes[.backgroundColor] = codeBackground
                } else if !block.isCode && (run.strong || block.heading != nil || block.cell?.row == 0) {
                    attributes[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                }
                if run.emphasis, let font = attributes[.font] as? NSFont {
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                if run.crossedOut { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            for span in block.codeSpans where start + span.end <= result.length {
                result.addAttribute(.foregroundColor, value: span.color.nativeColor,
                                    range: NSRange(location: start + span.start, length: span.end - span.start))
            }
            if let fieldName, let natSpecLayout {
                let prefix = NSRange(location: start, length: fieldName.utf16.count + 2)
                let label = natSpecLayout.descriptionColumn == nil ? "\(fieldName)\n" : "\(fieldName)\t"
                var attributes = base
                attributes[.font] = natSpecLayout.labelFont
                // The selectable text view draws labels without the vibrancy of an NSTextField.
                attributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.75)
                result.replaceCharacters(in: prefix, with: NSAttributedString(string: label, attributes: attributes))
            }
            if let fields = block.alignedFields {
                alignFields(fields, in: result, startingAt: start, paragraph: paragraph, maximumWidth: maximumWidth)
            }
            // Foundation includes the newline before the closing Markdown fence in the code.
            if block.isCode, result.length > start, result.mutableString.hasSuffix("\n") {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            }
            if (index < blocks.count - 1 || block.cell != nil), block.isCode || !result.mutableString.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
            if index > 0, block.cell == nil, blockStart < result.length {
                let previous = blocks[index - 1]
                let leadingParagraph = NSMutableParagraphStyle()
                leadingParagraph.setParagraphStyle(paragraph)
                leadingParagraph.paragraphSpacingBefore = previous.isCode && block.isCode ? 4 : 7
                if previous.indentation > 0 && block.indentation > 0 { leadingParagraph.paragraphSpacingBefore = 2 }
                let first = result.mutableString.paragraphRange(for: NSRange(location: blockStart, length: 0))
                result.addAttribute(.paragraphStyle, value: leadingParagraph, range: first)
            }
        }
        return result
    }

    @MainActor
    private func alignFields(_ fields: [OLSHover.Field], in text: NSMutableAttributedString,
                             startingAt start: Int, paragraph: NSMutableParagraphStyle, maximumWidth: CGFloat) {
        let labels = fields.map { NSRange(location: start + $0.label.location, length: $0.label.length) }
        let longestLabel = labels.map { text.attributedSubstring(from: $0).size().width }.max() ?? 0
        let column = ceil(longestLabel) + 14
        guard column <= maximumWidth * 0.6 else { return }

        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(paragraph)
        style.tabStops = [NSTextTab(textAlignment: .left, location: column)]
        style.headIndent = column
        let labelColor = NSColor.labelColor.withAlphaComponent(0.8)
        for (field, label) in zip(fields, labels).reversed() {
            text.addAttribute(.foregroundColor, value: labelColor, range: label)
            text.replaceCharacters(in: NSRange(location: start + field.padding.location, length: field.padding.length), with: "\t")
        }
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: text.length - start))
        paragraph.setParagraphStyle(style)
    }
}

struct EditorHoverPlacement {
    static let screenInset: CGFloat = 8
    private static let gap: CGFloat = 4

    let frame: NSRect
    let shape: AnchoredPopoverShape

    init?(anchor: NSRect, contentSize: NSSize, screen: NSRect, pointerX: CGFloat? = nil, prefersAbove: Bool = true) {
        let available = screen.insetBy(dx: Self.screenInset, dy: Self.screenInset)
        let width = contentSize.width
        let pointerHeight = AnchoredPopoverShape.pointerHeight
        let wantedHeight = min(contentSize.height, 320) + pointerHeight
        let spaceAbove = available.maxY - anchor.maxY - Self.gap
        let spaceBelow = anchor.minY - available.minY - Self.gap
        let above = if prefersAbove {
            spaceAbove >= wantedHeight || spaceAbove >= spaceBelow
        } else {
            spaceBelow < wantedHeight && spaceAbove > spaceBelow
        }
        let height = min(wantedHeight, above ? spaceAbove : spaceBelow)
        guard height > pointerHeight else { return nil }

        // Use the screen margin near an edge so the tip stays over the anchor.
        let anchorX = min(max(pointerX ?? anchor.midX, anchor.minX), anchor.maxX)
        let pointerInset = AnchoredPopoverShape.pointerEdgeInset
        let minX = min(available.minX, max(screen.minX, anchorX - pointerInset))
        let maxX = max(available.maxX, min(screen.maxX, anchorX + pointerInset))
        let x = min(max(anchorX - width / 2, minX), maxX - width)
        let y = above ? anchor.maxY + Self.gap : anchor.minY - Self.gap - height
        frame = NSRect(x: x, y: y, width: width, height: height)
        shape = AnchoredPopoverShape(contentSize: NSSize(width: width, height: height - pointerHeight),
                                     pointerX: anchorX - x, pointsDown: above)
    }
}

@MainActor
final class EditorHoverPopover {
    private let panel: HoverPanel
    private let content: HoverSurface
    let anchor: NSRect

    var window: NSWindow { panel }
    var frame: NSRect { panel.frame }
    var isSelecting: Bool { content.selecting }
#if EDIT_AGENT_CHECKS
    let pointerScreenXForCheck: CGFloat
#endif

    init?(owner: NSWindow, appearance: NSAppearance, anchor: NSRect, presentation: EditorHoverPresentation, pointerX: CGFloat? = nil,
          onNavigate: @escaping (LSPLocation) -> Void, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        guard !anchor.isEmpty, let screen = owner.screen ?? NSScreen.main else { return nil }
        let screenFrame = screen.visibleFrame
        let maximumWidth = min(presentation.maximumWidth, screenFrame.width - 2 * EditorHoverPlacement.screenInset)
        guard let layout = EditorHoverLayout(presentation, maximumWidth: maximumWidth),
              let placement = EditorHoverPlacement(anchor: anchor, contentSize: layout.view.frame.size,
                                                  screen: screenFrame, pointerX: pointerX)
        else { return nil }

        self.anchor = anchor
#if EDIT_AGENT_CHECKS
        pointerScreenXForCheck = placement.frame.minX + placement.shape.pointerX
#endif
        panel = HoverPanel(contentRect: placement.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        content = HoverSurface(placement: placement, layout: layout,
                               onNavigate: onNavigate, onEnter: onEnter, onExit: onExit)
        panel.contentView = content
        panel.setFrame(placement.frame, display: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = owner.ignoresMouseEvents
        panel.alphaValue = owner.alphaValue
        panel.appearance = appearance
        if owner.isVisible { owner.addChildWindow(panel, ordered: .above) }
    }

    func close(restoreFocus: Bool) {
        let owner = panel.parent
        let wasKey = panel.isKeyWindow
        owner?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus && wasKey && NSApp.isActive { owner?.makeKey() }
    }
}

private final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class HoverSurface: AnchoredPopoverSurface, NSTextViewDelegate {
    private let onNavigate: (LSPLocation) -> Void
    private let onEnter: () -> Void
    private let onExit: () -> Void
    private var area: NSTrackingArea?
    private let textViews: [HoverTextView]

    var selecting: Bool { textViews.contains(where: \.selecting) }

    init(placement: EditorHoverPlacement, layout: EditorHoverLayout,
         onNavigate: @escaping (LSPLocation) -> Void, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onNavigate = onNavigate
        self.onEnter = onEnter
        self.onExit = onExit
        textViews = layout.textViews
        super.init(frame: NSRect(origin: .zero, size: placement.frame.size))
        identifier = .init("EditorLanguageHover")
        applyOutline(placement.shape)

        for text in textViews { text.delegate = self }

        let scroll = NSScrollView(frame: placement.shape.contentFrame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = layout.view.frame.height > scroll.frame.height
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = layout.view
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("Language hover surfaces are created in code.") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, let destination = HoverLink(url) {
            switch destination {
            case .external(let url): NSWorkspace.shared.open(url)
            case .definition(let location): onNavigate(location)
            }
        }
        return true
    }
}

final class HoverTextView: NSTextView {
    private(set) var selecting = false

    convenience init(width: CGFloat, text: NSAttributedString, inset: NSSize) {
        var hasTable = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { style, _, stop in
            if let style = style as? NSParagraphStyle, !style.textBlocks.isEmpty {
                hasTable = true
                stop.pointee = true
            }
        }
        // NSTextTable lays out columns in TextKit 1. TextKit 2 stacks the cells.
        self.init(usingTextLayoutManager: !hasTable)
        setFrameSize(NSSize(width: width, height: 0))
        identifier = .init("EditorLanguageHoverText")
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = inset
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textStorage?.setAttributedString(text)
    }

    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var firstTextBaseline: CGFloat? {
        if let layout = textLayoutManager {
            guard let fragment = layout.textLayoutFragment(for: layout.documentRange.location),
                  let line = fragment.textLineFragments.first else { return nil }
            return textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.glyphOrigin.y
        }
        guard let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return nil }
        return textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
            + layout.location(forGlyphAt: 0).y
    }

    func measure(at width: CGFloat) -> NSSize? {
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        let used: NSRect
        if let layout = textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            used = layout.usageBoundsForTextContainer
        } else if let layout = layoutManager, let container = textContainer {
            layout.ensureLayout(for: container)
            used = layout.usedRect(for: container)
        } else { return nil }
        return NSSize(width: ceil(used.maxX) + textContainerInset.width * 2,
                      height: ceil(used.maxY) + textContainerInset.height * 2)
    }

    func pointerCursor(atWindowPoint point: NSPoint) -> NSCursor {
        guard let window, let textStorage else { return .arrow }
        let screenPoint = window.convertPoint(toScreen: point)
        let character = characterIndex(for: screenPoint)
        guard character < textStorage.length,
              firstRect(forCharacterRange: NSRange(location: character, length: 1), actualRange: nil).contains(screenPoint)
        else { return .arrow }
        return textStorage.attribute(.link, at: character, effectiveRange: nil) == nil ? .iBeam : .pointingHand
    }

    override func mouseDown(with event: NSEvent) {
        selecting = true
        defer { selecting = false }
        super.mouseDown(with: event)
    }
}
