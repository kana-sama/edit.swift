import AppKit

@MainActor
final class EditorLanguageInteraction: NSObject {
    struct Hit {
        let offset: Int
        let word: NSRange
    }

    private static let hoverDelay: Duration = .milliseconds(300)

    private weak var editor: EditorTextView?
    private var eventMonitor: Any?
    private var probeWord: NSRange?
    private var probeTask: Task<Void, Never>?
    private var hoverWord: NSRange?
    private var hoverTask: Task<Void, Never>?
    private var popover: EditorHoverPopover?
    private var popoverWord: NSRange?
    private var dismissTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    private(set) var linkRange: NSRange?
    var hoverWindow: NSWindow? { popover?.window }

    init(editor: EditorTextView) { self.editor = editor }

    func setEnabled(_ enabled: Bool) {
        if enabled, eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown,
                                                                       .rightMouseDown, .otherMouseDown,
                                                                       .mouseMoved, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return handle(event)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(deactivate),
                                                   name: NSApplication.didResignActiveNotification, object: NSApp)
        } else if !enabled {
            stopMonitoring()
            invalidate()
        }
    }

    isolated deinit {
        stopMonitoring()
        popover?.close(restoreFocus: false)
        probeTask?.cancel()
        hoverTask?.cancel()
        dismissTask?.cancel()
        feedbackTask?.cancel()
    }

    private func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func deactivate() { invalidate(restoreFocus: false) }

    func invalidate(afterTextEdit: Bool = false, restoreFocus: Bool = true) {
        cancelProbe()
        setLink(nil, afterTextEdit: afterTextEdit)
        cancelHoverRequest()
        closePopover(restoreFocus: restoreFocus)
    }

    func keyWindowChanged() {
        Task { [weak self] in
            guard let self, editor?.window?.isKeyWindow != true, popover?.window.isKeyWindow != true else { return }
            invalidate(restoreFocus: false)
        }
    }

    func track(at location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let editor, editor.languageInteractionEnabled, !editor.isRenamingSymbol else { return }
        let target = hit(at: location)
        if Self.isCommandLink(modifiers) {
            updateProbe(for: target)
        } else {
            cancelProbe()
            setLink(nil)
        }
        updateHover(for: target)
    }

    func pointerExited() {
        cancelProbe()
        setLink(nil)
        cancelHoverRequest()
        scheduleDeparture()
    }

    func linkContains(_ point: NSPoint) -> Bool {
        guard let editor, let range = linkRange else { return false }
        return editor.highlightRects(for: [range]).contains { $0.contains(point) }
    }

    func followClick(_ down: NSEvent) -> Bool {
        guard let editor, editor.languageInteractionEnabled, let owner = editor.window,
              let follow = editor.languageFollowLink, down.clickCount == 1,
              Self.isCommandLink(down.modifierFlags), linkContains(editor.convert(down.locationInWindow, from: nil)),
              let pressed = hit(at: down.locationInWindow) else { return false }

        var release: NSEvent?
        owner.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: .greatestFiniteMagnitude,
                          mode: .eventTracking) { event, stop in
            release = event
            stop.pointee = true
        }
        if let release, release.type == .leftMouseDragged {
            // AppKit receives the original mouse-down and this first dragged event for native selection.
            NSApp.postEvent(release, atStart: true)
            return false
        }
        guard let release, Self.isCommandLink(release.modifierFlags),
              let released = hit(at: release.locationInWindow), pressed.word == released.word else { return true }
        cancelHoverRequest()
        closePopover(restoreFocus: true)
        follow(pressed.offset, pressed.word)
        return true
    }

    func dismissHover() -> Bool {
        guard popover != nil || hoverTask != nil else { return false }
        cancelHoverRequest()
        closePopover(restoreFocus: true)
        return true
    }

    func showFeedback(_ message: String, at range: NSRange) {
        cancelHoverRequest()
        closePopover(restoreFocus: true)
        let presentation = EditorHoverPresentation(text: message, isMarkdown: false)
        show(presentation, at: range, fallback: range)
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            self?.closePopover(restoreFocus: true)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let editor, editor.languageInteractionEnabled, let owner = editor.window else { return event }
        let inPanel = popover != nil && event.window === popover?.window
        guard inPanel || event.window === owner else {
            if popover != nil && [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                invalidate(restoreFocus: false)
            }
            return event
        }
        switch event.type {
        case .flagsChanged:
            if inPanel { pointerEnteredPopover() }
            else { track(at: owner.mouseLocationOutsideOfEventStream, modifiers: event.modifierFlags) }
        case .mouseMoved where inPanel:
            pointerEnteredPopover()
        case .keyDown:
            if event.keyCode == 53, dismissHover() { return nil }
            if !inPanel { invalidate() }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !inPanel {
                cancelHoverRequest()
                closePopover(restoreFocus: false)
            }
        case .scrollWheel where !inPanel:
            invalidate()
        default:
            break
        }
        return event
    }

    private static func isCommandLink(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .control, .option, .shift]) == .command
    }

    func hit(at location: NSPoint) -> Hit? {
        guard let editor, let window = editor.window, let source = editor.textStorage?.mutableString,
              source.length > 0, !editor.hasMarkedText(), !editor.isHiddenOrHasHiddenAncestor,
              window.attachedSheet == nil, window.contentLayoutRect.contains(location) else { return nil }
        let point = editor.convert(location, from: nil)
        guard editor.visibleRect.contains(point), let content = window.contentView,
              let foreground = content.hitTest(content.superview?.convert(location, from: nil) ?? location),
              foreground === editor || foreground.isDescendant(of: editor) else { return nil }
        let offset = editor.characterIndexForInsertion(at: point)
        guard offset <= source.length else { return nil }
        let line = LineEditing.line(at: offset, in: source)
        let lower = max(line.start, offset - 512)
        let upper = min(line.contentEnd, offset + 512)
        guard lower < upper else { return nil }
        let slice = source.substring(with: NSRange(location: lower, length: upper - lower))
        var target: Hit?
        OccurrenceSearch.zigIdentifierPattern.enumerateMatches(in: slice, range: NSRange(location: 0, length: upper - lower)) { match, _, stop in
            guard let match else { return }
            let range = NSRange(location: lower + match.range.location, length: match.range.length)
            if range.location > offset { stop.pointee = true; return }
            if offset <= NSMaxRange(range), editor.highlightRects(for: [range]).contains(where: { $0.contains(point) }) {
                let character = source.rangeOfComposedCharacterSequence(at: min(offset, NSMaxRange(range) - 1))
                target = Hit(offset: character.location, word: range)
                stop.pointee = true
            }
        }
        if let target, let focus = editor.focusRanges,
           !focus.contains(where: { NSIntersectionRange($0, target.word) == target.word }) { return nil }
        return target
    }

    private func updateProbe(for target: Hit?) {
        guard let target, let probe = editor?.languageProbe else {
            cancelProbe()
            setLink(nil)
            return
        }
        guard probeWord != target.word else { return }
        cancelProbe()
        setLink(nil)
        probeWord = target.word
        probeTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let range = await probe(target.offset, target.word)
            guard !Task.isCancelled, let self, probeWord == target.word else { return }
            probeTask = nil
            if let range, let size = editor?.textStorage?.length, range.location <= size,
               range.length > 0, range.length <= size - range.location, NSLocationInRange(target.offset, range) {
                setLink(range)
            }
        }
    }

    private func cancelProbe() {
        probeTask?.cancel()
        probeTask = nil
        probeWord = nil
    }

    private func setLink(_ range: NSRange?, afterTextEdit: Bool = false) {
        guard range != linkRange, let editor else { return }
        linkRange = range
        if afterTextEdit {
            // Do not begin an attribute transaction from TextStorage's editing callback.
            Task { [weak editor] in editor?.syntaxHighlighting?.refreshColors() }
        } else {
            editor.syntaxHighlighting?.refreshColors()
        }
        if let window = editor.window { (NSApp as? EditApplication)?.updatePointerCursor(in: window) }
    }

    private func updateHover(for target: Hit?) {
        if popoverWord != nil, target?.word == popoverWord {
            dismissTask?.cancel()
            dismissTask = nil
            return
        }
        guard let target, let request = editor?.languageHover else {
            cancelHoverRequest()
            scheduleDeparture()
            return
        }
        guard hoverWord != target.word else { return }
        cancelHoverRequest()
        scheduleDeparture()
        hoverWord = target.word
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.hoverDelay) } catch { return }
            let response = await request(target.offset, target.word)
            guard !Task.isCancelled else { return }
            guard let response, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self?.hoverTask = nil
                return
            }
            let parse = Task.detached(priority: .userInitiated) {
                EditorHoverPresentation(text: response.text, isMarkdown: response.isMarkdown)
            }
            let content = await withTaskCancellationHandler { await parse.value } onCancel: { parse.cancel() }
            guard !Task.isCancelled, let self, hoverWord == target.word else { return }
            hoverTask = nil
            closePopover(restoreFocus: true)
            show(content, at: response.range ?? target.word, fallback: target.word)
            if popover != nil { popoverWord = target.word }
        }
    }

    private func cancelHoverRequest() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverWord = nil
    }

    private func closePopover(restoreFocus: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        let previous = popover
        popover = nil
        popoverWord = nil
        if let previous {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: previous.window)
            previous.close(restoreFocus: restoreFocus)
        }
    }

    private func pointerEnteredPopover() {
        cancelProbe()
        setLink(nil)
        cancelHoverRequest()
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func scheduleDeparture() {
        guard let popover, dismissTask == nil else { return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.hoverDelay) } catch { return }
            guard let self, self.popover === popover else { return }
            dismissTask = nil
            let point = NSEvent.mouseLocation
            guard !popover.anchor.contains(point), !popover.frame.contains(point), !popover.isSelecting else { return }
            closePopover(restoreFocus: true)
        }
    }

    private func show(_ presentation: EditorHoverPresentation, at range: NSRange, fallback: NSRange) {
        guard let editor, let window = editor.window else { return }
        let original = editor.highlightRects(for: [fallback]).first
        let preferred = editor.highlightRects(for: [range]).first { rect in
            original.map { $0.intersects(rect) } ?? true
        }
        guard let rect = preferred ?? original else { return }
        let windowRect = editor.convert(rect.intersection(editor.visibleRect), to: nil)
        let anchor = window.convertToScreen(windowRect.intersection(window.contentLayoutRect))
        popover = EditorHoverPopover(
            owner: window, appearance: editor.effectiveAppearance, anchor: anchor, presentation: presentation,
            onNavigate: { [weak self] location in
                guard let self, popoverWord == fallback, let follow = self.editor?.languageFollowHoverLink else { return }
                _ = dismissHover()
                follow(location, fallback)
            },
            onEnter: { [weak self] in self?.pointerEnteredPopover() },
            onExit: { [weak self] in self?.scheduleDeparture() }
        )
        if let popover {
            NotificationCenter.default.addObserver(self, selector: #selector(popoverResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: popover.window)
        }
    }

    @objc private func popoverResignedKey() { keyWindowChanged() }
}
