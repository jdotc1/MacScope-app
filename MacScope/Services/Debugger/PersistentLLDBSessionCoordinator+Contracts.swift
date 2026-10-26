import Foundation

/// Narrow execution seam used by the session coordinator. The concrete persistent adapter and
/// tests both conform without exposing its byte channel, retained process, or raw interpreter.
protocol PersistentLLDBCLIExecuting: Sendable {
    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse
    func executeCoordinatorSelected(
        _ request: PersistentLLDBCLIRequest
    ) async throws -> PersistentLLDBCLIResponse
    func exactAdapterInstanceBinding() async -> PersistentLLDBCLIAdapterInstanceBinding?
}

extension PersistentLLDBCLIExecuting {
    func executeCoordinatorSelected(
        _ request: PersistentLLDBCLIRequest
    ) async throws -> PersistentLLDBCLIResponse {
        try await execute(request)
    }

    func exactAdapterInstanceBinding() async -> PersistentLLDBCLIAdapterInstanceBinding? { nil }
}

extension PersistentLLDBCLIAdapter: PersistentLLDBCLIExecuting {
    func exactAdapterInstanceBinding() async -> PersistentLLDBCLIAdapterInstanceBinding? {
        adapterInstanceBinding()
    }
}

/// Converts one already-admitted typed request context into the private adapter request. Keeping
/// rendering behind this seam means the coordinator API never accepts raw LLDB command text.
protocol PersistentLLDBCLIRequestPreparing: Sendable {
    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest

    /// Converts only the bounded, correlated request transcript into typed reducer payloads.
    /// Implementations must not return PID/lifecycle facts; those remain decoder-owned above.
    func reducerPayloads(
        for context: DebuggerRequestContext,
        transcript: LLDBCLITranscriptResult
    ) async throws -> [DebuggerEventPayload]

    func validateResponse(
        for context: DebuggerRequestContext,
        transcript: LLDBCLITranscriptResult
    ) async throws
}

extension PersistentLLDBCLIRequestPreparing {
    func validateResponse(
        for context: DebuggerRequestContext,
        transcript: LLDBCLITranscriptResult
    ) async throws {}

    func reducerPayloads(
        for context: DebuggerRequestContext,
        transcript: LLDBCLITranscriptResult
    ) async throws -> [DebuggerEventPayload] {
        []
    }
}


/// Complete typed authority for one private logical-breakpoint transaction. Rendered commands are
/// derived only inside the coordinator from the frozen program and prepared canonical pages.
struct PersistentLLDBLogicalBreakpointReconciliationInput: Sendable {
    let observation: DebuggerBreakpointResolutionObservation
    let prepared: LLDBLogicalBreakpointPreparedTransaction
    let reservation: LLDBLogicalBreakpointTransactionReservation
    let token: Data
}

struct PersistentLLDBLogicalBreakpointReconciliationResult: Sendable {
    let receipt: DebuggerBreakpointBindingReceipt
    let reducerState: DebuggerReducerState
}

/// Complete authority and pre-reserved physical capacity for one private Run-to-Cursor creation.
/// The private receipt is deliberately separate from the durable logical-breakpoint inventory.
struct PersistentLLDBRunToCursorCreationInput: Sendable {
    let prepared: LLDBRunToCursorPreparedTransaction
    let reservation: LLDBLogicalBreakpointTransactionReservation
    let token: Data
}

struct PersistentLLDBRunToCursorCreationResult: Sendable {
    let receipt: LLDBRunToCursorPrivateReceipt
    let reducerState: DebuggerReducerState
}

/// Distinguishes admission/proof failures that are known to precede target mutation from failures
/// after the private helper apply may have written backend state.
struct PersistentLLDBRunToCursorCreationFailure: Error, Sendable {
    let code: PersistentLLDBSessionCoordinatorFailureCode
    let targetRecoveryRequired: Bool
}

struct PersistentLLDBRunToCursorCleanupInput: Sendable {
    let receipt: LLDBRunToCursorPrivateReceipt
    let ownerDigest: DebuggerBreakpointDigest
    let token: Data
}

enum PersistentLLDBLogicalBreakpointSessionDisposition: Equatable, Sendable {
    case retainCorrelatedSession
    case invalidateAndShutdown
}

/// A post-admission failure always carries the collector's bounded recovery disposition. The
/// coordinator deliberately leaves a post-write session valid long enough for the controller's
/// operation-gated target recovery; it never invalidates before that recovery can be admitted.
struct PersistentLLDBLogicalBreakpointReconciliationFailure: Error, Sendable {
    let code: PersistentLLDBSessionCoordinatorFailureCode
    let classification: LLDBLogicalBreakpointTransactionFailureClassification
    let sessionDisposition: PersistentLLDBLogicalBreakpointSessionDisposition
    let reducerState: DebuggerReducerState
    let validatedReceipt: DebuggerBreakpointBindingReceipt?
}

enum PersistentLLDBLogicalBreakpointCallbackDrainDisposition: Sendable {
    case terminateAndReap
}

/// A failed correlated drain leaves the session valid only so the controller can use its already-
/// held operation gate for bounded terminate/poll/reap recovery. The failure itself never clears
/// retained callback authority or strands an active target behind an invalidated reducer.
struct PersistentLLDBLogicalBreakpointCallbackDrainFailure: Error, Sendable {
    let code: PersistentLLDBSessionCoordinatorFailureCode
    let disposition: PersistentLLDBLogicalBreakpointCallbackDrainDisposition
    let reducerState: DebuggerReducerState
}

enum PersistentLLDBExactDetachPreFinalFailureDisposition: Equatable, Sendable {
    /// Retire the untrusted adapter generation, then re-observe through controller-owned policy.
    /// No target action is implied because the detach command has not been dispatched.
    case retireAdapterAndReobserve
}

struct PersistentLLDBExactDetachPreFinalFailure: Error, Sendable {
    let code: PersistentLLDBSessionCoordinatorFailureCode
    let disposition: PersistentLLDBExactDetachPreFinalFailureDisposition
    let reducerState: DebuggerReducerState
}


enum PersistentLLDBSessionCoordinatorFailureCode: String, Equatable, Sendable {
    case requestSequenceExhausted
    case eventSequenceExhausted
    case admissionRejected
    case requestPreparationFailed
    case preparedRequestMismatch
    case responseCorrelationMismatch
    case responseProjectionFailed
    case invalidObservedProcess
    case adapterCancelled
    case adapterFailedBeforeWrite
    case adapterInvalidated
    case reducerRejected
}

/// Why the coordinator invalidated the adapter generation (§4.88). `adapterInvalidated` alone
/// cannot distinguish a slow LLDB from a dead one or from broken framing; this names the cause in
/// the typed error and in the reducer's invalidation diagnostic.
enum PersistentLLDBAdapterInvalidationCause: Equatable, Sendable {
    /// The adapter invalidated its generation after the write. `deadline` is the request's own
    /// exchange deadline and is reported for a timeout.
    case transport(DebuggerTransportInvalidationReason, deadline: Duration?)
    /// A bounded decoder rejection from the correlated request, without raw transcript data.
    case transcriptValidation(LLDBCLITranscriptDiagnosticCode)
    /// The adapter failure named a different request than the one in flight.
    case failureCorrelationLost
    /// The adapter returned a disposition that cannot follow a write (completed or non-unknown).
    case invalidDisposition
    /// The executor threw something other than a typed adapter failure.
    case unboundedDisposition

    var summary: String {
        switch self {
        case .transport(.timeoutAfterWrite, let deadline?):
            "LLDB did not answer within the \(Self.render(deadline)) exchange deadline"
        case .transport(.timeoutAfterWrite, nil):
            "LLDB did not answer within the exchange deadline"
        case .transport(.endOfFileAfterWrite, _):
            "LLDB closed its output (end of file) after the request was written"
        case .transport(.framingLoss, _):
            "the LLDB response failed transcript validation (framing, markers or process status)"
        case .transport(.oversizedTranscript, _):
            "the LLDB response exceeded the bounded exchange size"
        case .transport(.cancellationAfterWrite, _):
            "the request was cancelled after it was written"
        case .transport(.adapterFailure, _):
            "the LLDB adapter process failed (write or read error)"
        case .transcriptValidation(let code):
            "the LLDB response failed transcript validation (\(code.rawValue))"
        case .failureCorrelationLost:
            "the adapter failure named a different request"
        case .invalidDisposition:
            "the adapter reported an impossible post-write disposition"
        case .unboundedDisposition:
            "the request failed without a bounded adapter disposition"
        }
    }

    static func render(_ duration: Duration) -> String {
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        if milliseconds % 1_000 == 0 { return "\(milliseconds / 1_000) s" }
        return "\(milliseconds) ms"
    }
}

struct PersistentLLDBSessionCoordinatorFailure: Error, Equatable, Sendable {
    let code: PersistentLLDBSessionCoordinatorFailureCode
    let requestID: DebuggerRequestID?
    let reducerRejection: DebuggerReducerRejection?
    let invalidationCause: PersistentLLDBAdapterInvalidationCause?

    init(
        code: PersistentLLDBSessionCoordinatorFailureCode,
        requestID: DebuggerRequestID? = nil,
        reducerRejection: DebuggerReducerRejection? = nil,
        invalidationCause: PersistentLLDBAdapterInvalidationCause? = nil
    ) {
        self.code = code
        self.requestID = requestID
        self.reducerRejection = reducerRejection
        self.invalidationCause = invalidationCause
    }

    /// `code`, plus the named invalidation cause when there is one.
    var detail: String {
        guard let invalidationCause else { return code.rawValue }
        return "\(code.rawValue): \(invalidationCause.summary)"
    }
}

