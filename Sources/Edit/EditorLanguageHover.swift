import AppKit

struct EditorLanguageHover: Sendable {
    let text: String
    let isMarkdown: Bool
    let range: NSRange?
    let server: LanguageServer

    var presentation: EditorHoverPresentation {
        EditorHoverPresentation(text: text, isMarkdown: isMarkdown, server: server)
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
    private struct Run: Sendable {
        let text: String
        var emphasis = false
        var strong = false
        var code = false
        var crossedOut = false
        var link: URL?
    }

    private struct Block: Sendable {
        var identity: Int?
        var heading: Int?
        var listMarker: String?
        var indentation = 0
        var isQuote = false
        var isCode = false
        var codeLanguage: SyntaxLanguage?
        var codeSpans: [SyntaxSpan] = []
        var runs: [Run] = []
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

    init(text: String, isMarkdown: Bool) {
        guard isMarkdown, let value = try? AttributedString(markdown: text), !value.characters.isEmpty else {
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
                    default: break
                    }
                }
                blocks.append(block)
            }

            let attributes = run.inlinePresentationIntent ?? []
            let link = run.link.flatMap { HoverLink($0) == nil ? nil : $0 }
            blocks[blocks.count - 1].runs.append(Run(text: String(value[run.range].characters),
                                                     emphasis: attributes.contains(.emphasized),
                                                     strong: attributes.contains(.stronglyEmphasized),
                                                     code: attributes.contains(.code),
                                                     crossedOut: attributes.contains(.strikethrough), link: link))
        }

        for index in blocks.indices {
            guard let language = blocks[index].codeLanguage, !Task.isCancelled else { continue }
            let code = blocks[index].runs.map(\.text).joined()
            blocks[index].codeSpans = SyntaxEngine.analysis(in: code, language: language, includesBrackets: false)?.spans ?? []
        }
        self.blocks = blocks
    }

    @MainActor
    func attributedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let codeBackground = NSColor.labelColor.withAlphaComponent(0.075)
        for (index, block) in blocks.enumerated() {
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
                } else if !block.isCode && (run.strong || block.heading != nil) {
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
            // Foundation includes the newline before the closing Markdown fence in the code.
            if block.isCode, result.length > start, result.mutableString.hasSuffix("\n") {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            }
            if index < blocks.count - 1, block.isCode || !result.mutableString.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
            if index > 0, blockStart < result.length {
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
}

struct EditorHoverPlacement {
    static let screenInset: CGFloat = 8
    private static let gap: CGFloat = 4

    let frame: NSRect
    let shape: AnchoredPopoverShape

    init?(anchor: NSRect, contentSize: NSSize, screen: NSRect) {
        let available = screen.insetBy(dx: Self.screenInset, dy: Self.screenInset)
        let width = contentSize.width
        let pointerHeight = AnchoredPopoverShape.pointerHeight
        let wantedHeight = min(contentSize.height, 320) + pointerHeight
        let spaceAbove = available.maxY - anchor.maxY - Self.gap
        let spaceBelow = anchor.minY - available.minY - Self.gap
        let above = spaceAbove >= wantedHeight || spaceAbove >= spaceBelow
        let height = min(wantedHeight, above ? spaceAbove : spaceBelow)
        guard height > pointerHeight else { return nil }

        // Use the screen margin near an edge so the tip can stay over the symbol.
        let pointerInset = AnchoredPopoverShape.pointerEdgeInset
        let minX = min(available.minX, max(screen.minX, anchor.midX - pointerInset))
        let maxX = max(available.maxX, min(screen.maxX, anchor.midX + pointerInset))
        let x = min(max(anchor.midX - width / 2, minX), maxX - width)
        let y = above ? anchor.maxY + Self.gap : anchor.minY - Self.gap - height
        frame = NSRect(x: x, y: y, width: width, height: height)
        shape = AnchoredPopoverShape(contentSize: NSSize(width: width, height: height - pointerHeight),
                                     pointerX: anchor.midX - x, pointsDown: above)
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

    init?(owner: NSWindow, appearance: NSAppearance, anchor: NSRect, presentation: EditorHoverPresentation,
          onNavigate: @escaping (LSPLocation) -> Void, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        guard !anchor.isEmpty, let screen = owner.screen ?? NSScreen.main else { return nil }
        let screenFrame = screen.visibleFrame
        let maximumWidth = min(presentation.maximumWidth, screenFrame.width - 2 * EditorHoverPlacement.screenInset)
        guard let layout = EditorHoverLayout(presentation, maximumWidth: maximumWidth),
              let placement = EditorHoverPlacement(anchor: anchor, contentSize: layout.view.frame.size, screen: screenFrame)
        else { return nil }

        self.anchor = anchor
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
        self.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
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
        guard let layout = textLayoutManager,
              let fragment = layout.textLayoutFragment(for: layout.documentRange.location),
              let line = fragment.textLineFragments.first else { return nil }
        return textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.glyphOrigin.y
    }

    func measure(at width: CGFloat) -> NSSize? {
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        guard let layout = textLayoutManager else { return nil }
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer
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
