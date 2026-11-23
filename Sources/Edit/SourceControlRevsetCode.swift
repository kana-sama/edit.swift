import AppKit

@MainActor
final class SourceControlRevsetCode: NSObject, @MainActor NSTextContentStorageDelegate {
    private static let tokenPattern = try! NSRegularExpression(pattern:
        #"("(?:[^"\\]|\\[\s\S])*"?|'[^']*'?)|([a-zA-Z_][a-zA-Z_0-9]*)(?=\()|([a-zA-Z_][a-zA-Z_0-9-]*)(?=:(?!:))|[\p{L}\p{M}\p{N}_*/]+(?:(?:\.|-+|\+)[\p{L}\p{M}\p{N}_*/]+)*|(::|\.\.|[@:&|~+\-^=])"#
    )

    let scroll: NSScrollView
    let editor: EditorTextView
    private let viewportHeight: NSLayoutConstraint
    private var highlightedSource: String?
    private var tokens: [(NSRange, SyntaxColor)] = []

    init(height: CGFloat) {
        (scroll, editor) = EditorTextView.scrollingEditor(in: NSRect(x: 0, y: 0, width: 372, height: height))
        viewportHeight = scroll.heightAnchor.constraint(equalToConstant: height)
        super.init()
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        viewportHeight.isActive = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.minSize.height = height
        editor.setAccessibilityLabel("Revset Expression")
        (editor.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = self
    }

    func resizeViewport(to height: CGFloat) {
        viewportHeight.constant = height
        editor.minSize.height = height
    }

    func install(_ expression: String, editable: Bool) {
        editor.resetMultiCarets()
        editor.isEditable = editable
        editor.string = expression
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.scrollToVisibleContentOrigin(.zero)
        editor.undoManager?.removeAllActions()
    }

    func textContentStorage(_ contentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard range.length > 0, let storage = contentStorage.textStorage else { return nil }
        let source = storage.string
        if highlightedSource != source {
            highlightedSource = source
            tokens = Self.colors(in: source)
        }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        for (token, color) in tokens {
            if token.location >= NSMaxRange(range) { break }
            let visible = NSIntersectionRange(range, token)
            guard visible.length > 0 else { continue }
            paragraph.addAttribute(.foregroundColor, value: color.nativeColor,
                                   range: NSRange(location: visible.location - range.location, length: visible.length))
        }
        return NSTextParagraph(attributedString: paragraph)
    }

    static func colors(in expression: String) -> [(NSRange, SyntaxColor)] {
        let range = NSRange(expression.startIndex..<expression.endIndex, in: expression)
        return tokenPattern.matches(in: expression, range: range).compactMap { token in
            let groups: [SyntaxColor] = [.string, .function, .type, .keyword]
            for (index, color) in groups.enumerated() {
                let match = token.range(at: index + 1)
                if match.location != NSNotFound { return (match, color) }
            }
            return nil
        }
    }
}
