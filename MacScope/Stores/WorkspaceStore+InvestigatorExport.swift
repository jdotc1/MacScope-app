import Foundation

@MainActor
extension WorkspaceStore {
    /// Capture the exact current owner, analysis and revision cut for one selected function.
    /// The caller may materialize `InvestigatorNativeExporter.export` away from the store.
    func captureInvestigatorNativeExport(functionID: UUID, in slot: ImageSlot)
        -> InvestigatorNativeExportInput? {
        let cut = snapshot
        guard let binary = cut.binary(in: slot),
              let analysis = cut.analysis(in: slot),
              let image = phase2ReadLedger.imageIdentity(in: slot, snapshot: cut) else {
            return nil
        }
        let dependencies = phase2ReadLedger.dependencies(
            for: [.workspaceTopology, .inputBytesAndSlice, .functionBoundaries, .instructionDecoding],
            image: image, snapshot: cut
        )
        let precondition = Phase2ReadPrecondition(
            workspace: phase2ReadLedger.workspace,
            workspaceRevision: phase2ReadLedger.workspaceRevision,
            strictWholeWorkspace: true,
            image: image,
            dependencies: dependencies
        )
        return .init(captureID: UUID(), documentID: documentID, workspaceID: workspaceID,
                     precondition: precondition, binary: binary, analysis: analysis,
                     functionID: functionID)
    }

    /// The UI owner supplies the capture ID it still intends to publish. A later
    /// request or a replacement document cannot attach an older completed export.
    func mayPublishInvestigatorNativeExport(_ export: InvestigatorNativeExport,
                                             activeCaptureID: UUID) -> Bool {
        export.mayPublish(documentID: documentID, workspaceID: workspaceID,
                          activeCaptureID: activeCaptureID,
                          currentState: phase2ReadLedger.currentState(
                            for: export.precondition.image?.slot, snapshot: snapshot
                          ))
    }
}
