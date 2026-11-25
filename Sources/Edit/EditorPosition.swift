import CryptoKit
import Foundation

struct EditorPosition: Codable, Equatable, Sendable {
    struct TopLine: Codable, Equatable, Sendable {
        let textOffset: Int
        let offsetIntoLine: CGFloat
    }

    struct Focus: Codable, Equatable, Sendable {
        private let textDigest: Data
        let ranges: [NSRange]
        let selections: [FocusNavigationSelection]

        init(text: String, ranges: [NSRange], selections: [FocusNavigationSelection]) {
            textDigest = Self.digest(of: text)
            self.ranges = ranges
            self.selections = selections
        }

        func matches(_ text: String) -> Bool {
            textDigest == Self.digest(of: text)
        }

        private static func digest(of text: String) -> Data {
            Data(SHA256.hash(data: Data(text.utf8)))
        }
    }

    let selections: [NSRange]
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let topLine: TopLine?
    var focus: Focus? = nil
    var markdown: MarkdownViewState? = nil

    func mappingOffsets(_ map: (Int) -> Int) -> Self {
        let selections = selections.map { selection in
            let start = map(selection.location)
            return NSRange(location: start, length: map(NSMaxRange(selection)) - start)
        }
        let topLine = topLine.map { TopLine(textOffset: map($0.textOffset), offsetIntoLine: $0.offsetIntoLine) }
        return Self(selections: selections, horizontalOffset: horizontalOffset, verticalOffset: verticalOffset,
                    topLine: topLine, focus: focus, markdown: markdown)
    }
}
