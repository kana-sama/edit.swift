import Foundation

struct TerminalPanelState: Codable, Sendable, Equatable {
    let dock: TerminalDock
    let spaces: [TerminalSpaceState]
    let selectedSpace: UUID?
    let nextSpaceNumber: Int
}

struct TerminalSpaceState: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let layout: TerminalLayoutState
    let lastPane: UUID
}

indirect enum TerminalLayoutState: Codable, Sendable, Equatable {
    case pane(TerminalPaneState)
    case split(direction: TerminalSplitDirection, firstFraction: CGFloat,
               first: TerminalLayoutState, second: TerminalLayoutState)
}

struct TerminalPaneState: Codable, Sendable, Equatable {
    let id: UUID
    let workingDirectory: URL
    let foregroundCommand: String?
    let pointSize: CGFloat
    let wrapsLines: Bool
    let transcript: String
    let transcriptStyles: [TerminalTranscript.Style]?
    let scrollbackOffset: Int
    let fixedColumns: Int?
    let horizontalOffset: CGFloat?
    let isTestOutput: Bool?
}
