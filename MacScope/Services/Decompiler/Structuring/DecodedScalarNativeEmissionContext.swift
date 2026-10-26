import Foundation

/// Per-render ownership only. Native scalar/condition rendering stays in the
/// existing printer; this context cannot resolve another plan's edge tokens.
final class DecodedScalarNativeEmissionContext {
    let function: MacIRFunction
    let cfg: CFG
    let values: DecodedScalarNativeValuePlan
    let control: DecodedScalarNativeControlPlan
    let originals: [Int: PseudocodeLine]
    var failed = false
    var activeLoops: [Int] = []
    var rows: Set<Int> = []
    var slots: Set<DecodedScalarNativeControlPlan.EdgeEmissionSlotID> = []
    var originalLineIndices: [Int: Int] = [:]
    var copiedEdges: Set<DecodedScalarNativeControlPlan.OriginalEdgeID> = []
    var transferredEdges: Set<DecodedScalarNativeControlPlan.OriginalEdgeID> = []

    init(function: MacIRFunction, cfg: CFG, values: DecodedScalarNativeValuePlan,
         control: DecodedScalarNativeControlPlan, originals: [Int: PseudocodeLine]) {
        self.function = function; self.cfg = cfg; self.values = values
        self.control = control; self.originals = originals
        if !values.matches(function: function, cfg: cfg) || !control.matches(function: function, cfg: cfg) {
            failed = true
        }
    }
    func own(_ row: Int) -> Bool {
        guard function.instructions.indices.contains(row), rows.insert(row).inserted else {
            failed = true; return false
        }
        return true
    }
    func own(_ slot: DecodedScalarNativeControlPlan.EdgeEmissionSlot) -> Bool {
        guard control.edgeSlots[slot.id] == slot,
              slots.insert(slot.id).inserted, slot.origins.count == 1,
              slot.phase == .copiesAndTransfer, slot.nearestLoopHeader == activeLoops.last,
              let edge = slot.origins.first, control.originalEdges.contains(edge),
              copiedEdges.insert(edge).inserted, transferredEdges.insert(edge).inserted else {
            failed = true; return false
        }
        return true
    }
    /// The retained do/while owns its actual conditional edges and any separate
    /// B-only stub edge. Empty text never means an unowned original source row.
    func ownDoWhileEdges(_ loop: DecodedScalarNativeControlPlan.LoopBinding) -> Bool {
        guard loop.kind == .doWhile else { failed = true; return false }
        for edge in loop.implicitEdges {
            guard control.originalEdges.contains(edge), (values.edgeCopies[edge.cfgEdge] ?? []).isEmpty,
                  copiedEdges.insert(edge).inserted, transferredEdges.insert(edge).inserted else {
                failed = true; return false
            }
        }
        for row in loop.implicitRows {
            guard values.groups.indices.contains(row), values.groups[row].isEmpty, own(row) else {
                failed = true; return false
            }
        }
        return true
    }
    var complete: Bool {
        !failed && activeLoops.isEmpty && rows == values.ownedRows && rows == control.ownedRows
            && slots == Set(control.edgeSlots.keys)
            && copiedEdges == control.originalEdges && transferredEdges == control.originalEdges
            && Set(originalLineIndices.keys) == Set(originals.keys)
    }
}
