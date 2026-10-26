import LumenUI
import SwiftUI

/// Branch lanes for the disassembly listing (Lumen branch-lane layout): each jump
/// inside a function drawn as a bracket in the listing's leading gutter, from the branch row to its
/// target. Built with the listing on the background worker. Lanes are grouped per function, so a row
/// lays out only its own function's jumps and columns stay consistent down that function.
struct DisassemblyBranchLanes: Sendable {
    struct Lane: Hashable, Sendable {
        let fromRow: Int
        let toRow: Int
        let isConditional: Bool
    }

    /// Lanes for each function that has jumps.
    let groups: [[Lane]]
    /// Each listing row's group: that of the nearest instruction at or above it, or -1.
    let groupByRow: [Int32]
    /// The row of each lane end, by instruction address (to highlight the selection's jumps).
    let endpointRows: [UInt64: Int]

    static let empty = DisassemblyBranchLanes(groups: [], groupByRow: [], endpointRows: [:])

    /// The gutter the lanes draw in: room for Lumen's maximum of four columns, so rows stay aligned
    /// whatever their function needs.
    @MainActor static var gutterWidth: CGFloat { LumenBranchLanes.width(columns: 4) }

    /// - Parameters:
    ///   - rows: the listing rows, in order.
    ///   - edges: the image's control-flow edges. Branch and switch edges whose source and target lie
    ///     in the same function become lanes; calls and fall-throughs don't (a fall-through goes to
    ///     the next row). A branch is conditional when its source also falls through.
    ///   - functions: the image's functions.
    static func build(rows: [ListingRow], edges: [ControlFlowEdge], functions: [FunctionSummary]) -> Self {
        let sorted = functions.filter { $0.endAddress > $0.startAddress }.sorted { $0.startAddress < $1.startAddress }
        func function(containing address: UInt64) -> Int? {
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].startAddress <= address { low = mid + 1 } else { high = mid }
            }
            let index = low - 1
            return index >= 0 && address < sorted[index].endAddress ? index : nil
        }

        var rowByAddress: [UInt64: Int] = [:]
        for (index, row) in rows.enumerated() {
            if case let .instruction(instruction) = row { rowByAddress[instruction.address] = index }
        }
        let conditional = LumenGraphEdgeKind.conditionalSources(edges.map { (from: $0.from, kind: $0.kind) })
        var lanesByFunction: [Int: [Lane]] = [:]
        var endpointRows: [UInt64: Int] = [:]
        for edge in edges where edge.kind == "branch" || edge.kind == "switch" {
            guard let owner = function(containing: edge.from), function(containing: edge.to) == owner,
                  let fromRow = rowByAddress[edge.from], let toRow = rowByAddress[edge.to], fromRow != toRow
            else { continue }
            endpointRows[edge.from] = fromRow
            endpointRows[edge.to] = toRow
            lanesByFunction[owner, default: []].append(
                Lane(fromRow: fromRow, toRow: toRow, isConditional: conditional.contains(edge.from)))
        }
        guard !lanesByFunction.isEmpty else { return .empty }

        var groups: [[Lane]] = []
        var groupByFunction: [Int: Int32] = [:]
        for owner in lanesByFunction.keys.sorted() {
            groupByFunction[owner] = Int32(groups.count)
            groups.append(Array(Set(lanesByFunction[owner]!)).sorted { ($0.fromRow, $0.toRow) < ($1.fromRow, $1.toRow) })
        }
        var groupByRow = [Int32](repeating: -1, count: rows.count)
        var current: Int32 = -1
        for (index, row) in rows.enumerated() {
            if case let .instruction(instruction) = row {
                current = function(containing: instruction.address).flatMap { groupByFunction[$0] } ?? -1
            }
            groupByRow[index] = current
        }
        return DisassemblyBranchLanes(groups: groups, groupByRow: groupByRow, endpointRows: endpointRows)
    }

    /// The lanes the row at `row` draws, as Lumen lanes; those from or to `selectedRow` highlighted.
    /// Empty when no jump in the row's function passes through it.
    func lumenLanes(atRow row: Int, selectedRow: Int?) -> [LumenBranchLane] {
        guard groupByRow.indices.contains(row), groupByRow[row] >= 0 else { return [] }
        let lanes = groups[Int(groupByRow[row])]
        guard lanes.contains(where: { min($0.fromRow, $0.toRow) <= row && row <= max($0.fromRow, $0.toRow) }) else { return [] }
        return lanes.map { lane in
            LumenBranchLane(fromRow: lane.fromRow, toRow: lane.toRow,
                            kind: lane.isConditional ? .taken : .unconditional,
                            isHighlighted: selectedRow.map { $0 == lane.fromRow || $0 == lane.toRow } ?? false)
        }
    }
}

/// A listing row's slice of the branch lanes, drawn over the row in its leading gutter `width` wide
/// (after the s5 side inset). The row itself leaves that room inside its band (U10-3: bands span
/// the pane, the gutter shares the canvas). The slice is as tall as the row, so rows taller than
/// the standard height (wrapped comments) keep the lanes continuous.
struct DisassemblyLaneGutter: ViewModifier {
    let lanes: [LumenBranchLane]
    let row: Int
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if !lanes.isEmpty {
                    GeometryReader { proxy in
                        LumenBranchLanes(lanes, rowHeight: proxy.size.height, firstRow: row, rowCount: 1)
                            .frame(width: width, height: proxy.size.height, alignment: .trailing)
                    }
                    .frame(width: width)
                    .padding(.leading, Lumen.Space.s5)
                }
            }
    }
}
