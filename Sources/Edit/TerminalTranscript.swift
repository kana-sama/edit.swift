import Foundation
import SwiftTerm

struct TerminalPrompt {
    struct Line: Equatable {
        let cells: ArraySlice<TerminalCellSnapshot>
        let cursorColumn: Int

        init?(_ snapshot: TerminalContentSnapshot) {
            guard !snapshot.inputState.isAlternateBuffer, snapshot.cursorColumn > 0,
                  let row = snapshot.rows.last(where: { $0.cells.contains { !$0.isBlank } }),
                  row.absoluteRow == snapshot.cursorRow, !row.isWrapped,
                  row.cells.dropFirst(snapshot.cursorColumn).allSatisfy(\.isBlank) else { return nil }
            guard !row.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            cells = row.cells.prefix(snapshot.cursorColumn)
            cursorColumn = snapshot.cursorColumn
        }
    }

    private var start: Position?
    private var end: Position?
    private var shellMarksPrompts = false

    mutating func observe(_ event: TerminalOscEvent) {
        let fields = String(decoding: event.payload, as: UTF8.self).split(separator: ";")
        switch fields.first {
        case "A", "N", "P":
            if let kind = fields.dropFirst().first(where: { $0.hasPrefix("k=") }), kind != "k=i" { return }
            shellMarksPrompts = true
            start = event.cursor.col == 0 ? event.cursor : nil
            end = nil
        case "B", "I":
            end = event.cursor
        case "C", "D":
            start = nil
            end = nil
        default:
            break
        }
    }

    func trailingRow(in snapshot: TerminalContentSnapshot, startupLine: Line?) -> Int? {
        guard let line = Line(snapshot) else { return nil }
        if shellMarksPrompts {
            // OSC reports live-screen coordinates. Limit detection to a complete single row.
            guard let start, let end, start.row == end.row, end.col == line.cursorColumn,
                  snapshot.liveTopRow + end.row == snapshot.cursorRow else { return nil }
        } else {
            guard snapshot.inputState.bracketedPasteMode, line == startupLine else { return nil }
        }
        return snapshot.cursorRow
    }
}

struct TerminalTranscript {
    struct Style: Codable, Sendable, Equatable {
        let byteOffset: Int
        let parameters: String

        var isValid: Bool {
            let bytes = parameters.utf8
            return !bytes.isEmpty && bytes.count <= 128 &&
                bytes.allSatisfy { (48...57).contains($0) || $0 == 58 || $0 == 59 } &&
                bytes.split(whereSeparator: { $0 == 58 || $0 == 59 }).allSatisfy { $0.count <= 3 }
        }
    }

    private static let maximumTextBytes = 256 * 1024
    private static let maximumStyleChanges = 8_192
    private static let reset = "0"

    let text: String
    let styles: [Style]

    init(text: String, styles: [Style] = []) {
        let bytes = text.utf8
        let tail = bytes.suffix(Self.maximumTextBytes).drop(while: { $0 & 0xC0 == 0x80 })
        self.text = String(decoding: tail, as: UTF8.self)
        let cutoff = bytes.count - tail.count
        var retained: [Style] = []
        var lastOffset = -1
        var openingStyle = Self.reset
        for style in styles.suffix(Self.maximumStyleChanges) {
            let offset = style.byteOffset
            guard offset > lastOffset, offset < bytes.count, style.isValid else { continue }
            lastOffset = offset
            if offset < cutoff {
                openingStyle = style.parameters
            } else {
                let index = tail.index(tail.startIndex, offsetBy: offset - cutoff)
                guard tail[index] & 0xC0 != 0x80 else { continue }
                retained.append(Style(byteOffset: offset - cutoff, parameters: style.parameters))
            }
        }
        if !tail.isEmpty, openingStyle != Self.reset, retained.first?.byteOffset != 0 {
            retained.insert(Style(byteOffset: 0, parameters: openingStyle), at: 0)
        }
        self.styles = retained
    }

    init(snapshots: [TerminalContentSnapshot], omittingNormalRowsFrom promptRow: Int? = nil,
         useBrightColors: Bool, collapseBrightColorsToBase: Bool) {
        var text = ""
        var styles: [Style] = []
        var byteOffset = 0

        func append(_ string: String) {
            text += string
            byteOffset += string.utf8.count
        }

        for snapshot in snapshots {
            let rows = if let promptRow, snapshot.bufferKind == .normal {
                snapshot.rows.prefix { $0.absoluteRow < promptRow }
            } else {
                snapshot.rows[...]
            }
            guard let last = rows.lastIndex(where: { $0.cells.contains { !$0.isBlank } }) else { continue }
            var attribute: Attribute?
            if !text.isEmpty { append("\n\n") }
            for (index, row) in rows[...last].enumerated() {
                if index > 0 && !row.isWrapped { append("\n") }
                guard let end = row.cells.lastIndex(where: { !$0.isBlank }) else { continue }
                for column in 0...end {
                    let cell = row.cells[column]
                    if cell.isBlank && column > 0 && row.cells[column - 1].width == 2 { continue }
                    let text = cell.isBlank ? " " : Self.visibleText(cell.text)
                    guard !text.isEmpty else { continue }
                    if attribute != cell.attribute {
                        attribute = cell.attribute
                        let parameters = Self.styleParameters(for: cell.attribute, palette: snapshot.palette,
                                                              useBrightColors: useBrightColors,
                                                              collapseBrightColorsToBase: collapseBrightColorsToBase)
                        if parameters != (styles.last?.parameters ?? Self.reset) {
                            styles.append(Style(byteOffset: byteOffset, parameters: parameters))
                            if styles.count == Self.maximumStyleChanges * 2 {
                                styles.removeFirst(Self.maximumStyleChanges)
                            }
                        }
                    }
                    append(text)
                }
            }
        }
        self.init(text: text, styles: styles)
    }

    var replayText: String {
        let bytes = text.utf8
        var result = ""
        var start = bytes.startIndex
        for style in styles {
            let end = bytes.index(bytes.startIndex, offsetBy: style.byteOffset)
            result += Self.visibleText(String(decoding: bytes[start..<end], as: UTF8.self))
            // All style parameters are numeric SGR. Session text cannot insert terminal commands.
            result += "\u{1B}[\(style.parameters)m"
            start = end
        }
        result += Self.visibleText(String(decoding: bytes[start...], as: UTF8.self))
        if !styles.isEmpty { result += "\u{1B}[0m" }
        return result.replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func visibleText(_ text: String) -> String {
        func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value == 10 || (scalar.value >= 32 && !(127...159).contains(scalar.value))
        }
        guard !text.unicodeScalars.allSatisfy(isPrintable) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter(isPrintable)))
    }

    private static func styleParameters(for attribute: Attribute, palette: [Color], useBrightColors: Bool,
                                        collapseBrightColorsToBase: Bool) -> String {
        var parameters = attribute.sgrParameters()
        let inverse = attribute.style.contains(.inverse)
        let bold = attribute.style.contains(.bold)

        // Freeze indexed colors in the saved output without changing the next shell's palette.
        func appendRGB(_ color: Attribute.Color, selector: Int, bright: Bool) {
            guard case .ansi256(let code) = color else { return }
            var index = Int(code)
            if useBrightColors {
                if bright && code < 8 { index += 8 }
            } else if collapseBrightColorsToBase && code > 7 {
                index -= 8
            }
            guard palette.indices.contains(index) else { return }
            let color = palette[index]
            func byte(_ value: UInt16) -> UInt32 { (UInt32(value) + 128) / 257 }
            parameters += ";\(selector);2;\(byte(color.red));\(byte(color.green));\(byte(color.blue))"
        }

        appendRGB(attribute.fg, selector: 38, bright: bold && !inverse)
        appendRGB(attribute.bg, selector: 48, bright: bold && inverse)
        if let underlineColor = attribute.underlineColor {
            appendRGB(underlineColor, selector: 58, bright: false)
        }
        return parameters
    }
}
