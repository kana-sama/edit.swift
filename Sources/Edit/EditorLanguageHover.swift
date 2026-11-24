import AppKit

struct EditorLanguageHover: Sendable {
    let text: String
    let isMarkdown: Bool
    let range: NSRange?
}

private enum HoverLink {
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
            paragraph.paragraphSpacing = 7
            paragraph.lineSpacing = 2
            paragraph.lineBreakMode = .byWordWrapping
            if block.indentation > 0 {
                paragraph.firstLineHeadIndent = CGFloat(block.indentation - 1) * 14
                paragraph.headIndent = CGFloat(block.indentation) * 14
                if index + 1 < blocks.count, blocks[index + 1].indentation > 0 { paragraph.paragraphSpacing = 2 }
            }
            if block.isQuote {
                paragraph.firstLineHeadIndent += 12
                paragraph.headIndent += 12
            }
            let size: CGFloat = block.heading == 1 ? 15 : block.heading != nil ? 14 : 13
            let foreground: NSColor = block.isQuote ? .secondaryLabelColor : .labelColor
            let base = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: size),
                        .foregroundColor: foreground, .paragraphStyle: paragraph] as [NSAttributedString.Key: Any]

            if let marker = block.listMarker { result.append(NSAttributedString(string: marker, attributes: base)) }
            let start = result.length
            for run in block.runs {
                var attributes = base
                if block.isCode || run.code {
                    attributes[.font] = EditorTextView.defaultFont
                    attributes[.backgroundColor] = codeBackground
                } else if run.strong || block.heading != nil {
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
            if index < blocks.count - 1, result.mutableString.hasSuffix("\n") == false {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return result
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

    init?(owner: NSWindow, appearance: NSAppearance, anchor: NSRect, text: NSAttributedString,
          onNavigate: @escaping (LSPLocation) -> Void, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        guard !anchor.isEmpty, text.length > 0, let screen = owner.screen ?? NSScreen.main else { return nil }
        let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let inset: CGFloat = 12
        let maximumWidth = min(460, area.width)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let width = text.boundingRect(with: NSSize(width: maximumWidth - inset * 2,
                                                  height: .greatestFiniteMagnitude), options: options).width
        let panelWidth = min(maximumWidth, max(84, ceil(width) + inset * 2))
        let textHeight = ceil(text.boundingRect(with: NSSize(width: panelWidth - inset * 2,
                                                            height: .greatestFiniteMagnitude), options: options).height)
        let contentHeight = textHeight + 20
        let gap: CGFloat = 4
        let spaceAbove = max(0, area.maxY - anchor.maxY - gap)
        let spaceBelow = max(0, anchor.minY - area.minY - gap)
        let wantedHeight = min(contentHeight, 320)
        let above = spaceAbove >= wantedHeight || spaceAbove >= spaceBelow
        let panelHeight = min(wantedHeight, max(42, above ? spaceAbove : spaceBelow))
        let x = min(max(anchor.minX, area.minX), area.maxX - panelWidth)
        let y = min(max(above ? anchor.maxY + gap : anchor.minY - gap - panelHeight, area.minY), area.maxY - panelHeight)
        let frame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)

        self.anchor = anchor
        panel = HoverPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        content = HoverSurface(size: frame.size, contentHeight: contentHeight, text: text, inset: inset,
                               onNavigate: onNavigate, onEnter: onEnter, onExit: onExit)
        panel.contentView = content
        panel.setFrame(frame, display: false)
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

private final class HoverSurface: NSVisualEffectView, NSTextViewDelegate {
    private let onNavigate: (LSPLocation) -> Void
    private let onEnter: () -> Void
    private let onExit: () -> Void
    private var area: NSTrackingArea?
    private let richText: HoverTextView

    var selecting: Bool { richText.selecting }

    init(size: NSSize, contentHeight: CGFloat, text: NSAttributedString, inset: CGFloat,
         onNavigate: @escaping (LSPLocation) -> Void, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onNavigate = onNavigate
        self.onEnter = onEnter
        self.onExit = onExit
        richText = HoverTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: max(size.height, contentHeight)))
        super.init(frame: NSRect(origin: .zero, size: size))
        identifier = .init("EditorLanguageHover")
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        richText.identifier = .init("EditorLanguageHoverText")
        richText.isEditable = false
        richText.isSelectable = true
        richText.isRichText = true
        richText.drawsBackground = false
        richText.textContainerInset = NSSize(width: inset, height: 10)
        richText.textContainer?.lineFragmentPadding = 0
        richText.textContainer?.widthTracksTextView = true
        richText.textContainer?.heightTracksTextView = false
        richText.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        richText.delegate = self
        richText.textStorage?.setAttributedString(text)

        let scroll = NSScrollView(frame: bounds)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentHeight > size.height
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = richText
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

    override var needsPanelToBecomeKey: Bool { true }

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
