import Foundation

struct Phase2TerminalGridColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct Phase2TerminalGridCellStyle: Equatable, Sendable {
    let foreground: Phase2TerminalGridColor
    let background: Phase2TerminalGridColor
    let bold: Bool
    let italic: Bool
    let faint: Bool
    let inverse: Bool
    let invisible: Bool
    let strikethrough: Bool
    let overline: Bool
    let underline: Int32
}

enum Phase2TerminalGridCellWidth: Equatable, Sendable {
    case narrow
    case wide
    case spacerTail
    case spacerHead
}

struct Phase2TerminalGridCell: Equatable, Sendable {
    let grapheme: String
    let width: Phase2TerminalGridCellWidth
    let style: Phase2TerminalGridCellStyle
    let isSelected: Bool
}

struct Phase2TerminalGridRow: Equatable, Sendable {
    let cells: [Phase2TerminalGridCell]
    let isDirty: Bool
}

enum Phase2TerminalGridCursorStyle: Equatable, Sendable {
    case bar
    case block
    case underline
    case hollowBlock
}

struct Phase2TerminalGridCursor: Equatable, Sendable {
    let column: Int
    let row: Int
    let style: Phase2TerminalGridCursorStyle
    let isVisible: Bool
    let shouldBlink: Bool
}

struct Phase2TerminalGridSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let columns: Int
    let rows: Int
    let defaultForeground: Phase2TerminalGridColor
    let defaultBackground: Phase2TerminalGridColor
    let gridRows: [Phase2TerminalGridRow]
    let cursor: Phase2TerminalGridCursor?
    let lastAppliedSequence: UInt64?
    let missingSequenceRanges: [ClosedRange<UInt64>]
    let viewport: Phase2TerminalViewportState

    var plainText: String {
        gridRows.map { row in
            row.cells
                .filter { $0.width != .spacerTail && $0.width != .spacerHead }
                .map(\.grapheme)
                .joined()
                .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
        .replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
    }
}

struct Phase2TerminalViewportState: Equatable, Sendable {
    let totalRows: Int
    let offset: Int
    let visibleRows: Int

    var scrollbackRows: Int { max(0, totalRows - visibleRows) }
    var isAtBottom: Bool { offset >= max(0, totalRows - visibleRows) }
}

struct Phase2TerminalGridPoint: Equatable, Sendable {
    let column: Int
    let row: Int
}

struct Phase2TerminalPixelGeometry: Equatable, Sendable {
    let screenWidth: UInt32
    let screenHeight: UInt32
    let cellWidth: UInt32
    let cellHeight: UInt32

    var isValid: Bool {
        screenWidth > 0 && screenHeight > 0 && cellWidth > 0 && cellHeight > 0
    }
}

#if canImport(GhosttyVt)
import GhosttyVt

struct Phase2TerminalMouseEvent: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case press
        case release
        case motion

        var ghosttyValue: GhosttyMouseAction {
            switch self {
            case .press: GHOSTTY_MOUSE_ACTION_PRESS
            case .release: GHOSTTY_MOUSE_ACTION_RELEASE
            case .motion: GHOSTTY_MOUSE_ACTION_MOTION
            }
        }
    }

    enum Button: Equatable, Sendable {
        case left
        case right
        case middle
        case four
        case five

        var ghosttyValue: GhosttyMouseButton {
            switch self {
            case .left: GHOSTTY_MOUSE_BUTTON_LEFT
            case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
            case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
            case .four: GHOSTTY_MOUSE_BUTTON_FOUR
            case .five: GHOSTTY_MOUSE_BUTTON_FIVE
            }
        }
    }

    let action: Action
    let button: Button?
    let modifiers: UInt16
    let position: Phase2TerminalMousePosition
}

struct Phase2TerminalMousePosition: Equatable, Sendable {
    let x: Double
    let y: Double
}
#endif

enum Phase2GhosttyTerminalIntegrity: Equatable, Sendable {
    case authoritative
    case sequenceGap(ClosedRange<UInt64>)
    case transcriptGap(reason: Phase2HumanPTYGapReason, lostByteCount: Int)
}

struct Phase2GhosttyTerminalIngestion: Equatable, Sendable {
    let appliedSequences: [UInt64]
    let ignoredDuplicateSequences: [UInt64]
    let ignoredForeignSessionSequences: [UInt64]
    let missingSequenceRanges: [ClosedRange<UInt64>]
}
