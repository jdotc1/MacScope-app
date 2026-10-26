import Foundation

extension WorkspaceStore {
    /// DP04 D2: commits an accepted struct candidate in ONE undoable step: the catalog type,
    /// and optionally `Name *` as the type of one stack local of the procedure. Undo removes
    /// the authored change, not the static evidence it came from.
    func acceptStructCandidate(
        _ definition: TypeDefinition,
        assigningStackLocal local: (procedureStart: UInt64, imageSlot: ImageSlot, entryRange: Range<Int64>)?
    ) {
        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent
        if needsExplicitGroup { manager.beginUndoGrouping() }
        upsertTypeDefinition(definition)
        if let local {
            editStackLocal(procedureStart: local.procedureStart, in: local.imageSlot, entryRange: local.entryRange,
                           name: nil, typeName: "\(definition.name) *")
        }
        manager.setActionName("Accept Struct")
        if needsExplicitGroup { manager.endUndoGrouping() }
    }
}
