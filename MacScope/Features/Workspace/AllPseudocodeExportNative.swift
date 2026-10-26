import Foundation

/// The batch uses the registry's D09 batch capture: the image is validated once per export, and
/// each function goes through the same projection, process runtime and validated cache as the
/// pane. Task cancellation reaches the native request.
extension NativeDecompilerRuntimeRegistry: NativePseudocodeBatchDecompiling {
    func beginBatchExport(snapshot: WorkspaceSnapshot, imageSlot: ImageSlot) async throws
        -> any NativePseudocodeBatchSession {
        RegistryNativeBatchSession(
            registry: self, lease: try await beginNativeBatchCapture(snapshot: snapshot, imageSlot: imageSlot))
    }

    /// The same product policy `productionShared` is built with.
    static var isProductEnabled: Bool {
        NativeDecompilerRuntimePolicy.productPolicy(
            environment: ProcessInfo.processInfo.environment,
            defaultsValue: UserDefaults.standard.object(forKey: NativeDecompilerRuntimePolicy.defaultsKey) as? Bool
        ).isEnabled
    }
}

private struct RegistryNativeBatchSession: NativePseudocodeBatchSession {
    let registry: NativeDecompilerRuntimeRegistry
    let lease: NativeDecompilerBatchCaptureLease

    func decompile(functionID: UUID) async throws -> NativeDecompilerValidatedExecution {
        try await registry.decompileNativeBatchFunction(lease: lease, functionID: functionID)
    }

    func cancel() { lease.cancel() }

    func retire() async { await registry.retireNativeBatchCapture(lease) }
}

enum AllPseudocodeExportNativeCapture {
    enum Refusal: Error, Equatable {
        case nativeDisabled
        case noImage
        case missingArtifactIdentity
        case missingAnalysisFingerprint

        var message: String {
            switch self {
            case .nativeDisabled: "The native decompiler is turned off, so there is nothing to export natively."
            case .noImage: "There is no image to export."
            case .missingArtifactIdentity: "Native export needs the image's identity, which this image does not have."
            case .missingAnalysisFingerprint: "Native export needs a finished analysis of this image."
            }
        }
    }

    @MainActor
    static func capture(store: WorkspaceStore, nativeEnabled: Bool)
        throws -> (NativePseudocodeBatchExport.Context, [NativePseudocodeBatchExport.Item]) {
        guard nativeEnabled else { throw Refusal.nativeDisabled }
        let snapshot = store.snapshot
        let slot = store.focusedImageSlot
        guard let binary = snapshot.binary(in: slot), let analysis = snapshot.analysis(in: slot) else {
            throw Refusal.noImage
        }
        guard let artifactUUID = binary.artifactIdentity?.uuid else { throw Refusal.missingArtifactIdentity }
        guard let fingerprint = analysis.analysisInputFingerprint?.overallSHA256 else {
            throw Refusal.missingAnalysisFingerprint
        }
        let context = NativePseudocodeBatchExport.Context(
            workspaceID: store.workspaceID, imageName: binary.name, imageSlot: slot, binaryID: binary.id,
            artifactUUID: artifactUUID, analysisInputFingerprintSHA256: fingerprint,
            documentGeneration: store.mutationGeneration.rawValue, snapshot: snapshot)
        return (context, NativePseudocodeBatchExport.items(for: analysis))
    }
}

extension AllPseudocodeExportNativeCapture {
    /// The one construction of a native whole-image export: the capture above plus the owner the
    /// export fences on. File › Export All Pseudocode (Native) and the headless
    /// `--export-native-pseudocode` mode both build their operation here; each supplies its own
    /// owner generation (the GUI's window generation, a fresh one per headless run).
    @MainActor
    static func makeOperation(store: WorkspaceStore, nativeEnabled: Bool, ownerGeneration: UUID)
        throws -> NativePseudocodeBatchExportOperation {
        let (context, items) = try capture(store: store, nativeEnabled: nativeEnabled)
        let owner = AllPseudocodeExportOperation.Owner(
            documentID: store.documentID, windowGeneration: ownerGeneration,
            documentGeneration: context.documentGeneration,
            imageSlot: context.imageSlot.rawValue, binaryID: context.binaryID)
        return NativePseudocodeBatchExportOperation(owner: owner, context: context, items: items)
    }

    /// The user-facing reason a native export run failed.
    static func describe(_ error: Error) -> String {
        switch error as? NativePseudocodeBatchExportOperation.Failure {
        case .itemLimit?: "The image has more functions than one native export allows."
        case .aggregateTextLimit?: "The native output is larger than one export allows."
        case .reportLimit?: "The per-function report is larger than one export allows."
        case .staleOwner?: "The document changed during the export."
        case .sessionEnded(let reason)?: "The native decompiler stopped (\(reason))."
        default: error.localizedDescription
        }
    }
}
