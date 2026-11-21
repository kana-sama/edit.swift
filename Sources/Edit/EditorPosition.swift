import Foundation

struct EditorPosition: Codable, Equatable, Sendable {
    struct TopLine: Codable, Equatable, Sendable {
        let textOffset: Int
        let offsetIntoLine: CGFloat
    }

    let selections: [NSRange]
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let topLine: TopLine?
}
