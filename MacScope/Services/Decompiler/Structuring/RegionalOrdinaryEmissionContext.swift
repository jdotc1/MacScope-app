import Foundation

/// Per-render ownership bookkeeping for the native printer's certified overlay.
/// No expression, scalar statement or control text is generated in this type.
final class RegionalOrdinaryEmissionContext {
    let function: MacIRFunction
    let cfg: CFG
    let values: RegionalOrdinaryValuePlan
    let control: RegionalOrdinaryControlPlan
    let originals: [Int: PseudocodeLine]
    let callRows: Set<Int>
    var failed = false
    var activeLoops: [Int] = []
    var rows: Set<Int> = []
    var labels: Set<Int> = []
    var slots: Set<RegionalOrdinaryControlPlan.EdgeEmissionSlotID> = []
    var originalLineIndices: [Int: Int] = [:]
    var copiedEdges: Set<RegionalOrdinaryControlPlan.OriginalEdgeID> = []
    var transferredEdges: Set<RegionalOrdinaryControlPlan.OriginalEdgeID> = []

    init(function: MacIRFunction, cfg: CFG, values: RegionalOrdinaryValuePlan,
         control: RegionalOrdinaryControlPlan, originals: [Int: PseudocodeLine],
         callRows: Set<Int>) {
        self.function = function; self.cfg = cfg; self.values = values
        self.control = control; self.originals = originals; self.callRows = callRows
    }
    func own(_ row: Int) -> Bool {
        guard function.instructions.indices.contains(row), rows.insert(row).inserted else {
            failed = true; return false
        }
        return true
    }
    func own(_ slot: RegionalOrdinaryControlPlan.EdgeEmissionSlot) -> Bool {
        guard slots.insert(slot.id).inserted, !slot.origins.isEmpty else { failed = true; return false }
        for edge in slot.origins {
            if slot.phase != .transferOnly, !copiedEdges.insert(edge).inserted { failed = true; return false }
            if slot.phase != .copiesOnly, !transferredEdges.insert(edge).inserted { failed = true; return false }
        }
        return true
    }
    /// A do/while represents its two latch edges without a printed slot only
    /// when the control certificate proved both edge-copy lists empty.
    func ownDoWhileEdges(_ loop: RegionalOrdinaryControlPlan.LoopBinding) -> Bool {
        for edge in [loop.backedge, loop.exitEdge] {
            guard (values.edgeCopies[edge.cfgEdge] ?? []).isEmpty,
                  copiedEdges.insert(edge).inserted,
                  transferredEdges.insert(edge).inserted else { failed = true; return false }
        }
        return true
    }
    var complete: Bool {
        !failed && rows == values.ownedRows && rows == control.ownedRows
            && labels == Set(control.labels.keys) && slots == Set(control.edgeSlots.keys)
            && copiedEdges == control.originalEdges && transferredEdges == control.originalEdges
            && Set(originalLineIndices.keys) == Set(originals.keys)
    }
}
