import Foundation

extension WorkspaceStore {
    /// Keep instruction extraction before JSON encoding: the capture handed to publication is
    /// already slim, so the manifest cap measures only manifest bytes, never instruction rows.
    func encodedInstructionPackagePayload(
        components: WorkspacePackageComponents,
        reconstructionState: ReconstructionWorkspaceState
    ) throws -> (manifestData: Data, instructionSidecarData: Data) {
        var capturedManifest = components.manifest
        capturedManifest.analystFindings = try persistableAnalystFindings()
        capturedManifest.navigatorState = persistableNavigatorState()
        var manifest = try MacScopeDocumentPackage.preparedManifest(
            capturedManifest, reconstructionState: reconstructionState
        )
        manifest.reaEvidence = reaResultEvidence.records.isEmpty ? nil : try JSONEncoder().encode(reaResultEvidence)
        let storage = try MacScopeDocumentPackage.preparedInstructionStorage(manifest)
        let manifestData = try MacScopeDocumentPackage.encodedManifest(storage.manifest)
        _ = try MacScopeDocumentPackage.validatedContents(
            manifestData: manifestData,
            attachmentsByBinaryID: components.attachmentsByBinaryID,
            reconstructionState: reconstructionState,
            instructionSidecarData: storage.data
        )
        return (manifestData, storage.data)
    }
}
