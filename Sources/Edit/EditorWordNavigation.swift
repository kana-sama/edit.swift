import AppKit

final class EditorWordNavigation: NSTextSelectionNavigation {
    override func destinationSelection(
        for selection: NSTextSelection, direction: Direction, destination: Destination, extending: Bool, confined: Bool
    ) -> NSTextSelection? {
        let native = super.destinationSelection(for: selection, direction: direction, destination: destination,
                                                extending: extending, confined: confined)
        guard destination == .word, let native, selection.textRanges.count == 1, native.textRanges.count == 1,
              let original = selection.textRanges.first, let proposed = native.textRanges.first else { return native }

        let target = native.affinity == .upstream ? proposed.location : proposed.endLocation
        if extending {
            let backward = selection.affinity == .upstream
            let head = backward ? original.location : original.endLocation
            guard let stop = dotBoundary(from: head, toward: target) else { return native }
            let anchor = backward ? original.endLocation : original.location
            let reversed = stop.compare(anchor) == .orderedAscending
            guard let range = NSTextRange(location: reversed ? stop : anchor, end: reversed ? anchor : stop) else {
                return native
            }
            return NSTextSelection(range: range, affinity: reversed ? .upstream : .downstream, granularity: native.granularity)
        }

        let forward = target.compare(original.endLocation) == .orderedDescending
        let edge = forward ? original.endLocation : original.location
        guard forward || target.compare(edge) == .orderedAscending,
              let stop = dotBoundary(from: edge, toward: target) else { return native }
        return NSTextSelection(stop, affinity: native.affinity)
    }

    func dottedDeletion(for selection: NSTextSelection, direction: Direction) -> NSTextRange? {
        guard let caret = selection.textRanges.first,
              let proposed = super.destinationSelection(for: selection, direction: direction, destination: .word,
                                                        extending: false, confined: false)?.textRanges.first,
              let stop = dotBoundary(from: caret.location, toward: proposed.location) else { return nil }
        let backward = direction == .backward
        return NSTextRange(location: backward ? stop : caret.location, end: backward ? caret.location : stop)
    }

    private func dotBoundary(from origin: any NSTextLocation, toward destination: any NSTextLocation) -> (any NSTextLocation)? {
        guard let source = textSelectionDataSource else { return nil }
        let direction = origin.compare(destination)
        guard direction != .orderedSame else { return nil }
        let backward = direction == .orderedDescending
        let period: UInt16 = 0x2E
        var stop: (any NSTextLocation)?

        // Split the native word, preserving TextKit's Unicode segmentation and movement across other separators.
        source.enumerateSubstrings(from: origin, options: backward ? [.byWords, .reverse] : .byWords) {
            word, range, _, finished in
            finished.pointee = true
            guard let units = word?.utf16,
                  let dot = backward ? units.lastIndex(of: period) : units.firstIndex(of: period) else { return }
            let offset = units.distance(from: units.startIndex, to: dot) + (backward ? 1 : 0)
            guard let boundary = source.location(range.location, offsetBy: offset),
                  origin.compare(boundary) == direction, boundary.compare(destination) == direction else { return }
            stop = boundary
        }
        return stop
    }
}
