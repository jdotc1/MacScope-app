import CoreGraphics
import LumenUI
import SwiftUI
import LumenTokens

// MARK: Graph node card (Lumen 0.23.0, "A · Summary cards")

/// How a graph block relates to the selection.
enum DSGraphNodeState {
    case normal
    /// Holds the selected instruction but doesn't start there: an accent hairline.
    case currentBlock
    /// Is the selection: an accent border and glow.
    case selected

    fileprivate var lumen: LumenGraphNodeState {
        switch self {
        case .normal: .normal
        case .currentBlock: .currentBlock
        case .selected: .selected
        }
    }
}

/// A control-flow-graph block as Lumen's summary card: its kind's tile, its title and instruction
/// count, and its address range (scaled before it clips), with the selection in the accent, a
/// dashed outline for the multi-selection and a leading stripe for a color tag. Fills the frame the
/// graph layout gives it.
struct DSGraphNode: View {
    let title: String
    var detail: String?
    var systemImage: String
    var hue: LumenToken
    var count: Int?
    var state: DSGraphNodeState = .normal
    var isMultiSelected = false
    /// A `ColorTag` raw value (red, orange, yellow, green, blue, purple, gray).
    var tagRawValue: String?

    var body: some View {
        LumenGraphNode(title, detail: detail, systemImage: systemImage, hue: hue, count: count,
                       state: state.lumen, isMultiSelected: isMultiSelected,
                       tag: tagRawValue.flatMap(LumenTagColor.init(rawValue:)))
    }
}

// MARK: Edge kinds (Lumen 0.23.0; mapping agreed with the Lumen session)

extension LumenGraphEdgeKind {
    /// MacScope's edge `kind` string as a Lumen edge kind. A source with both a branch and a
    /// fall-through edge is a conditional jump: its branch is taken (T) and its fall-through not
    /// taken (F). Every other branch, switch or fall-through is unconditional; calls and
    /// cross-references draw as `.call` (accent, dashed).
    static func macScope(kind: String, isConditionalSource: Bool) -> LumenGraphEdgeKind {
        switch kind {
        case "call", "reference": .call
        case "branch": isConditionalSource ? .taken : .unconditional
        case "fallthrough": isConditionalSource ? .notTaken : .unconditional
        default: .unconditional
        }
    }

    /// The source addresses of conditional jumps among `edges`: those with both a branch and a
    /// fall-through edge (the analysis emits that pair only after a conditional jump).
    static func conditionalSources(_ edges: [(from: UInt64, kind: String)]) -> Set<UInt64> {
        var branches = Set<UInt64>(), fallthroughs = Set<UInt64>()
        for edge in edges {
            if edge.kind == "branch" { branches.insert(edge.from) }
            if edge.kind == "fallthrough" { fallthroughs.insert(edge.from) }
        }
        return branches.intersection(fallthroughs)
    }
}
