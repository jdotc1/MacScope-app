import Foundation

/// One immutable native workspace cut supplied by the app-owned coordinator.
struct Phase2ReadProjectionInput: Sendable {
    let workspaceName: String
    let snapshot: WorkspaceSnapshot
    let currentState: Phase2ReadCurrentState
    let focusedImageSlot: ImageSlot?
    let nativeDecompilerState: NativeDecompilerPresentationState
    let reaResultStore: REAResultEvidenceStore?
    let reaWorkspaceID: UUID?
    let reaActiveAuthority: REAResultAuthority?

    init(
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        currentState: Phase2ReadCurrentState,
        focusedImageSlot: ImageSlot?,
        nativeDecompilerState: NativeDecompilerPresentationState = .idle,
        reaResultStore: REAResultEvidenceStore? = nil,
        reaWorkspaceID: UUID? = nil,
        reaActiveAuthority: REAResultAuthority? = nil
    ) {
        self.workspaceName = workspaceName
        self.snapshot = snapshot
        self.currentState = currentState
        self.focusedImageSlot = focusedImageSlot
        self.nativeDecompilerState = nativeDecompilerState
        self.reaResultStore = reaResultStore
        self.reaWorkspaceID = reaWorkspaceID
        self.reaActiveAuthority = reaActiveAuthority
    }
}
