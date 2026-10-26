import Foundation

struct ReconstructionSourceNavigationRequest: Sendable {
    let workspaceID: UUID
    let projectID: UUID
    let function: ReconstructionFunctionCoordinate
}

struct ReconstructionSourceNavigationTarget: Equatable, Sendable {
    let imageSlot: ImageSlot
    let binaryID: UUID
    let functionID: UUID
    let startAddress: UInt64
}

enum ReconstructionSourceNavigationError: Error, Equatable, Sendable {
    case workspaceMismatch
    case workspaceStateInvalid
    case projectUnavailable
    case currentManifestUnavailable
    case artifactOutsideCurrentManifest
    case functionAuthorityMismatch
    case addressUnavailable
}

/// Pure, fail-closed authority resolution for a dashboard-to-source jump. The caller receives a
/// complete navigation target only after the durable workspace/project/corpus identity and the
/// transient image/function identity agree. No UI or Store state is mutated here.
enum ReconstructionSourceNavigationAuthority {
    static func resolve(
        request: ReconstructionSourceNavigationRequest,
        currentWorkspaceID: UUID,
        state: ReconstructionWorkspaceState,
        snapshot: WorkspaceSnapshot
    ) throws -> ReconstructionSourceNavigationTarget {
        guard request.workspaceID == currentWorkspaceID else {
            throw ReconstructionSourceNavigationError.workspaceMismatch
        }
        guard let project = state.projects.first(where: {
            $0.projectID == request.projectID
        }) else {
            throw ReconstructionSourceNavigationError.projectUnavailable
        }
        guard let currentManifestSHA256 = project.currentCorpusManifestSHA256 else {
            throw ReconstructionSourceNavigationError.currentManifestUnavailable
        }

        let history: ReconstructionCorpusHistoryIndex
        do {
            history = try ReconstructionCorpusHistoryIndex(
                projects: state.projects,
                manifests: state.corpusManifests
            )
        } catch {
            throw ReconstructionSourceNavigationError.workspaceStateInvalid
        }
        guard history.contains(
            .function(request.function),
            projectID: request.projectID,
            manifestSHA256: currentManifestSHA256
        ) else {
            throw ReconstructionSourceNavigationError.artifactOutsideCurrentManifest
        }
        guard let function = ReconstructionReboundFunctionAuthority.resolve(
            request.function,
            in: snapshot
        ) else {
            throw ReconstructionSourceNavigationError.functionAuthorityMismatch
        }
        guard snapshot.containsLoadedAddress(
            request.function.startAddress,
            in: request.function.image.imageSlot
        ) else {
            throw ReconstructionSourceNavigationError.addressUnavailable
        }
        return ReconstructionSourceNavigationTarget(
            imageSlot: request.function.image.imageSlot,
            binaryID: request.function.image.binaryID,
            functionID: function.id,
            startAddress: request.function.startAddress
        )
    }
}

@MainActor
extension WorkspaceStore {
    /// Reveals one exact Reconstruction function in the ordinary Project/disassembly surface.
    /// Resolution is synchronous and completes before the first mutation, so a rejected request
    /// cannot partially change tool, image focus, sidebar selection, or address selection.
    @discardableResult
    func revealReconstructionSource(
        _ request: ReconstructionSourceNavigationRequest
    ) throws -> ReconstructionSourceNavigationTarget {
        let target = try ReconstructionSourceNavigationAuthority.resolve(
            request: request,
            currentWorkspaceID: workspaceID,
            state: reconstructionState,
            snapshot: snapshot
        )

        selectedTool = .project
        focusImage(target.imageSlot)
        precondition(
            selectAddress(ImageAddress(slot: target.imageSlot, address: target.startAddress)),
            "A source-navigation target changed after synchronous authority resolution"
        )
        let functionSidebarItemID = "function:\(target.functionID.uuidString)"
        selectedSidebarItemID = functionSidebarItemID
        requestSidebarKeyboardFocus(for: functionSidebarItemID)
        return target
    }

    /// Proves that a once-current source request becomes invalid after its exact live function
    /// authority is retired. The retirement is deliberately scoped to one synchronous fresh
    /// resolution and restored with `defer` before this method returns. In particular, an already
    /// dirty document, Save, or autosave can never observe the synthetic snapshot as persistent
    /// workspace state. The caller must already have crossed the candidate-bound create-only
    /// barrier and must turn a successful proof into a refusal rather than navigation.
    @discardableResult
    func retireReconstructionSourceAuthorityForInstalledQualification(
        _ request: ReconstructionSourceNavigationRequest
    ) -> Bool {
        guard let target = try? ReconstructionSourceNavigationAuthority.resolve(
            request: request,
            currentWorkspaceID: workspaceID,
            state: reconstructionState,
            snapshot: snapshot
        ),
        let currentAnalysis = snapshot.analysis(in: target.imageSlot),
        currentAnalysis.functions.filter({ $0.id == target.functionID }).count == 1 else {
            return false
        }

        let priorSnapshot = snapshot
        let priorTool = selectedTool
        let priorAddress = selectedAddress
        let priorSidebarItemID = selectedSidebarItemID
        let priorFocusedImageSlot = focusedImageSlot
        let priorDirtyState = isDirty

        var retiredAnalysis = currentAnalysis
        retiredAnalysis.functions.removeAll { $0.id == target.functionID }
        var retiredSnapshot = priorSnapshot
        retiredSnapshot.replaceAnalysis(retiredAnalysis, in: target.imageSlot)

        // WorkspaceStore is MainActor-isolated. Do not widen this temporary publication around
        // UI dispatch: `defer` restores the ordinary snapshot before any caller can return to the
        // run loop or invoke an ordinary persistence path.
        snapshot = retiredSnapshot
        defer { snapshot = priorSnapshot }
        let authorityWasRetired = (try? ReconstructionSourceNavigationAuthority.resolve(
            request: request,
            currentWorkspaceID: workspaceID,
            state: reconstructionState,
            snapshot: snapshot
        )) == nil
        let presentationWasPreserved = selectedTool == priorTool
            && selectedAddress == priorAddress
            && selectedSidebarItemID == priorSidebarItemID
            && focusedImageSlot == priorFocusedImageSlot
            && isDirty == priorDirtyState
        return authorityWasRetired && presentationWasPreserved
    }
}
