import Foundation

enum NativeDecompilerCacheLookupPolicy: Equatable, Sendable {
    case allowValidatedCache
    case bypassCacheLookup
}

enum NativeDriveOrigin: Hashable, Sendable {
    case freshImport
    case authoritativeRestore
    case interactiveAdoption
}

struct NativeDriveContext: Hashable, Sendable {
    let documentID: UUID
    let workspaceID: UUID
    let driveGeneration: UInt64
    let origin: NativeDriveOrigin
}

struct NativeDriveImageOwner: Hashable, Sendable {
    let imageSlot: ImageSlot
    let binaryID: UUID
}

struct NativeDriveTargetSeed: Hashable, Sendable {
    let context: NativeDriveContext
    let owner: NativeDriveImageOwner
    let selectedAddress: UInt64
}

struct NativeDriveResolvedTarget: Hashable, Sendable {
    let context: NativeDriveContext
    let owner: NativeDriveImageOwner
    let functionID: UUID
    let functionStart: UInt64
    let analysisFingerprintSHA256: String
}

struct NativeDriveSubmissionTicket: Hashable, Sendable {
    let driveGeneration: UInt64
    let handlerBindingGeneration: UInt64
    let semanticInputGeneration: UInt64
    let manualIntentGeneration: UInt64
    let target: NativeDriveResolvedTarget
}

struct NativeDriveHandlerBindingID: Hashable, Sendable {
    let rawValue: UUID
}

enum NativeDriveWaitReason: Equatable, Sendable {
    case selectedOwnerNeedsRehydration
    case structuralReanalysisPending
    case refreshLatchedUntilReadiness
}

/// Internal causal-counter axis. This is a D-lane fail-closed fact, not the E-lane public failure
/// catalog or user-facing copy.
enum NativeDriveCounterAxis: Equatable, Sendable {
    case drive
    case handlerBinding
    case semanticInput
    case manualIntent
    case cancellationFence
}

enum NativeDriveRetirementReason: Equatable, Sendable {
    case noSelection
    case noExactFunction
    case focusRemoved
    case imageOwnerRemoved
    case authoritativeReplacement
    case readinessFailed
    case counterExhausted(NativeDriveCounterAxis)
    case sessionTerminated
}

enum NativeDriveReadinessFailure: Equatable, Sendable {
    case analysisUnavailable
    case rehydrationFailed(code: String)
    case counterExhausted(NativeDriveCounterAxis)
}

enum NativeDriveReconcileReason: Equatable, Sendable {
    case installationCompleted
    case handlerBound
    case selectedOwnerReady
    case selectionOrFocusChanged
    case acceptedStructuralAnalysis
    case semanticAuthoring
    case manualRequest
    case manualRefresh
}

enum NativeDriveTerminalResult: Equatable, Sendable {
    case success
    case retryableFailure
    case terminalFailure
}

enum NativeDriveState: Equatable, Sendable {
    case idle
    case exhausted(NativeDriveCounterAxis)
    case installing(NativeDriveContext)
    case waitingForReadiness(NativeDriveContext, NativeDriveTargetSeed, NativeDriveWaitReason)
    case ready(NativeDriveContext, NativeDriveResolvedTarget)
    case submitted(NativeDriveSubmissionTicket)
    case retired(NativeDriveContext, NativeDriveRetirementReason)
}

enum NativeDriveEffect: Equatable, Sendable {
    case invalidateOutstanding
    case submit(
        ticket: NativeDriveSubmissionTicket,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    )
    case publishProjectionFailure(
        NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    )
    case publishReadinessFailure(NativeDriveReadinessFailure)
    case cancelOutstanding
    case retry(frozenTicket: NativeDriveSubmissionTicket)
}

enum NativeDriveEvent: Equatable, Sendable {
    case establish(NativeDriveContext)
    case installTarget(
        seed: NativeDriveTargetSeed?,
        resolved: NativeDriveResolvedTarget?,
        waitReason: NativeDriveWaitReason?
    )
    case bind(NativeDriveHandlerBindingID)
    case selectedOwnerReady(NativeDriveResolvedTarget)
    case selectedOwnerFailed(NativeDriveReadinessFailure)
    case targetChanged(seed: NativeDriveTargetSeed?, resolved: NativeDriveResolvedTarget?)
    case semanticInputChanged(
        NativeDecompilerSemanticInputState,
        deferUntilStructuralLanding: Bool
    )
    case patchedBytesChanged
    case acceptedStructuralLanding(NativeDriveResolvedTarget?)
    case terminal(NativeDriveTerminalResult, ticket: NativeDriveSubmissionTicket)
    case request
    case retry
    case refresh
    case cancel
    case counterExhausted(NativeDriveCounterAxis)
    case retire(NativeDriveRetirementReason)
}
