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
}
