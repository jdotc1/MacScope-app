import CryptoKit
import Foundation

/// Opaque coordinator-local authority carried only by execution results minted at acceptance.
/// Reference identity deliberately cannot be reconstructed from the result's value fields.
fileprivate final class PersistentLLDBSessionExecutionSealAuthority: @unchecked Sendable {}

struct PersistentLLDBSessionExecutionResult: Equatable, Sendable {
    let requestID: DebuggerRequestID
    let reducerState: DebuggerReducerState

    private let sealAuthority: PersistentLLDBSessionExecutionSealAuthority?

    /// Compatibility initializer for projections, tests, and controller fallback values. These
    /// values preserve result semantics but deliberately carry no coordinator seal authority.
    init(
        requestID: DebuggerRequestID,
        reducerState: DebuggerReducerState
    ) {
        self.requestID = requestID
        self.reducerState = reducerState
        self.sealAuthority = nil
    }

    fileprivate init(
        requestID: DebuggerRequestID,
        reducerState: DebuggerReducerState,
        sealAuthority: PersistentLLDBSessionExecutionSealAuthority
    ) {
        self.requestID = requestID
        self.reducerState = reducerState
        self.sealAuthority = sealAuthority
    }

    fileprivate func wasMinted(
        with authority: PersistentLLDBSessionExecutionSealAuthority
    ) -> Bool {
        sealAuthority === authority
    }

    static func == (
        lhs: PersistentLLDBSessionExecutionResult,
        rhs: PersistentLLDBSessionExecutionResult
    ) -> Bool {
        lhs.requestID == rhs.requestID && lhs.reducerState == rhs.reducerState
    }
}

/// Complete immutable authority for one exact local-process attach. The caller supplies the
/// already-authorized identity plus retained-adapter correlation, but never LLDB command text.
struct PersistentLLDBExactAttachTransactionInput: Sendable {
    let request: DebuggerLocalAttachRequest
    let permit: DebuggerSessionLeaseExactAttachPermit
}

private struct PersistentLLDBExactAttachClaimAdmissionFailure: Error {
    let failure: PersistentLLDBSessionCoordinatorFailure
}

struct PersistentLLDBExactAttachedSessionEvidence: Hashable, Sendable {
    let permit: DebuggerSessionLeaseExactAttachPermit
    let transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim
    let adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    let establishedSession: DebuggerSessionCoordinate
    let lldbProcessUniqueID: UInt64
    let bindingDigest: Data

    fileprivate init(
        permit: DebuggerSessionLeaseExactAttachPermit,
        transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        establishedSession: DebuggerSessionCoordinate,
        lldbProcessUniqueID: UInt64
    ) {
        self.permit = permit
        self.transactionClaim = transactionClaim
        self.adapterInstanceBinding = adapterInstanceBinding
        self.establishedSession = establishedSession
        self.lldbProcessUniqueID = lldbProcessUniqueID
        self.bindingDigest = Self.makeBindingDigest(
            permit: permit,
            transactionClaim: transactionClaim,
            adapterInstanceBinding: adapterInstanceBinding,
            establishedSession: establishedSession,
            lldbProcessUniqueID: lldbProcessUniqueID
        )
    }

    func hasValidBinding() -> Bool {
        bindingDigest == Self.makeBindingDigest(
            permit: permit,
            transactionClaim: transactionClaim,
            adapterInstanceBinding: adapterInstanceBinding,
            establishedSession: establishedSession,
            lldbProcessUniqueID: lldbProcessUniqueID
        )
    }

    private static func makeBindingDigest(
        permit: DebuggerSessionLeaseExactAttachPermit,
        transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        establishedSession: DebuggerSessionCoordinate,
        lldbProcessUniqueID: UInt64
    ) -> Data {
        var material = Data("MacScope.PersistentLLDB.ExactAttachedSession.v1".utf8)
        material.append(0)
        material.append(permit.bindingDigest)
        material.append(transactionClaim.bindingDigest)
        material.append(adapterInstanceBinding.digest)
        var revision = establishedSession.lifecycleRevision.rawValue.bigEndian
        withUnsafeBytes(of: &revision) { material.append(contentsOf: $0) }
        var uniqueID = lldbProcessUniqueID.bigEndian
        withUnsafeBytes(of: &uniqueID) { material.append(contentsOf: $0) }
        return Data(SHA256.hash(data: material))
    }
}

/// Coordinator-sealed proof that the exact process controlled by one attached session reached a
/// terminal external-exit state. The proof is deliberately tied to the current correlated
/// execution result and retained adapter instance; a caller cannot promote an old reducer
/// snapshot or a same-PID observation into terminal lease-release authority.
struct PersistentLLDBExactAttachedExternalExitResult: Hashable, Sendable {
    let attachedSession: PersistentLLDBExactAttachedSessionEvidence
    let adapterInstanceBindingDigest: Data
    let requestID: DebuggerRequestID
    let terminalLifecycleRevision: DebuggerLifecycleRevision
    let processID: Int32
    let exitStatus: Int32?
    let bindingDigest: Data

    fileprivate init(
        attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        adapterInstanceBindingDigest: Data,
        requestID: DebuggerRequestID,
        terminalLifecycleRevision: DebuggerLifecycleRevision,
        processID: Int32,
        exitStatus: Int32?
    ) {
        self.attachedSession = attachedSession
        self.adapterInstanceBindingDigest = adapterInstanceBindingDigest
        self.requestID = requestID
        self.terminalLifecycleRevision = terminalLifecycleRevision
        self.processID = processID
        self.exitStatus = exitStatus
        self.bindingDigest = Self.makeBindingDigest(
            attachedSession: attachedSession,
            adapterInstanceBindingDigest: adapterInstanceBindingDigest,
            requestID: requestID,
            terminalLifecycleRevision: terminalLifecycleRevision,
            processID: processID,
            exitStatus: exitStatus
        )
    }

    func hasValidBinding() -> Bool {
        attachedSession.hasValidBinding()
            && bindingDigest == Self.makeBindingDigest(
                attachedSession: attachedSession,
                adapterInstanceBindingDigest: adapterInstanceBindingDigest,
                requestID: requestID,
                terminalLifecycleRevision: terminalLifecycleRevision,
                processID: processID,
                exitStatus: exitStatus
            )
    }

    private static func makeBindingDigest(
        attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        adapterInstanceBindingDigest: Data,
        requestID: DebuggerRequestID,
        terminalLifecycleRevision: DebuggerLifecycleRevision,
        processID: Int32,
        exitStatus: Int32?
    ) -> Data {
        var material = Data("MacScope.PersistentLLDB.ExactAttachedExternalExit.v1".utf8)
        material.append(0)
        material.append(attachedSession.bindingDigest)
        material.append(adapterInstanceBindingDigest)
        material.append(Data(requestID.epoch.rawValue.uuidString.lowercased().utf8))
        var requestSequence = requestID.sequence.bigEndian
        withUnsafeBytes(of: &requestSequence) { material.append(contentsOf: $0) }
        var lifecycleRevision = terminalLifecycleRevision.rawValue.bigEndian
        withUnsafeBytes(of: &lifecycleRevision) { material.append(contentsOf: $0) }
        var pid = UInt32(bitPattern: processID).bigEndian
        withUnsafeBytes(of: &pid) { material.append(contentsOf: $0) }
        material.append(exitStatus == nil ? 0 : 1)
        if let exitStatus {
            var status = UInt32(bitPattern: exitStatus).bigEndian
            withUnsafeBytes(of: &status) { material.append(contentsOf: $0) }
        }
        return Data(SHA256.hash(data: material))
    }
}

struct PersistentLLDBExactAttachTransactionResult: Sendable {
    let requestID: DebuggerRequestID
    let receipt: PersistentLLDBAttachReceipt
    let reducerState: DebuggerReducerState
    let attachedSession: PersistentLLDBExactAttachedSessionEvidence

    fileprivate init(
        requestID: DebuggerRequestID,
        receipt: PersistentLLDBAttachReceipt,
        reducerState: DebuggerReducerState,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) {
        self.requestID = requestID
        self.receipt = receipt
        self.reducerState = reducerState
        self.attachedSession = attachedSession
    }
}

enum PersistentLLDBExactAttachFinalCommandDisposition: Equatable, Sendable {
    /// The transaction's final, lifecycle-changing command was never dispatched, or the
    /// correlated adapter proved that it failed before any bytes were written.
    case definitelyNotDispatchedOrWritten
    /// The final command may have been written, or a returned response may have established
    /// target authority before later proof failed. Recovery must therefore remain conservative.
    case mayHaveWrittenOrAcceptedAuthority
}

/// A post-reservation exact-attach failure carries the final request identity and a disposition
/// derived from transport facts. Callers never classify lease safety from diagnostics or text.
struct PersistentLLDBExactAttachTransactionFailure: Error, Sendable {
    let permit: DebuggerSessionLeaseExactAttachPermit
    let transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim?
    let failure: PersistentLLDBSessionCoordinatorFailure
    let finalRequestID: DebuggerRequestID?
    let finalCommandDisposition: PersistentLLDBExactAttachFinalCommandDisposition
    let reducerState: DebuggerReducerState

    var code: PersistentLLDBSessionCoordinatorFailureCode { failure.code }

    fileprivate init(
        permit: DebuggerSessionLeaseExactAttachPermit,
        transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim?,
        failure: PersistentLLDBSessionCoordinatorFailure,
        finalRequestID: DebuggerRequestID?,
        finalCommandDisposition: PersistentLLDBExactAttachFinalCommandDisposition,
        reducerState: DebuggerReducerState
    ) {
        self.permit = permit
        self.transactionClaim = transactionClaim
        self.failure = failure
        self.finalRequestID = finalRequestID
        self.finalCommandDisposition = finalCommandDisposition
        self.reducerState = reducerState
    }
}

/// Complete immutable launch material. The target PID and process identity are deliberately absent:
/// both are acquired only from the correlated adapter response and two complete OS observations.
struct PersistentLLDBExactLaunchTransactionInput: Sendable {
    let plan: DebuggerLLDBSealedLaunchPlan
    let expectedSession: DebuggerSessionCoordinate
    let adapterGeneration: UInt64
}

struct PersistentLLDBExactLaunchTransactionResult: Sendable {
    let requestID: DebuggerRequestID
    let authority: DebuggerSessionTargetAuthority
    let reducerState: DebuggerReducerState
}

/// Complete reducer-owned authority for one exact non-killing detach. The attached identity itself
/// is deliberately not caller supplied: the transaction derives it only from accepted reducer state.
struct PersistentLLDBExactDetachTransactionInput: Sendable {
    let attachedSession: PersistentLLDBExactAttachedSessionEvidence
}

struct PersistentLLDBExactDetachTransactionResult: Sendable {
    let requestID: DebuggerRequestID
    let receipt: PersistentLLDBDetachReceipt
    let reducerState: DebuggerReducerState
    let attachedSession: PersistentLLDBExactAttachedSessionEvidence

    fileprivate init(
        requestID: DebuggerRequestID,
        receipt: PersistentLLDBDetachReceipt,
        reducerState: DebuggerReducerState,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) {
        self.requestID = requestID
        self.receipt = receipt
        self.reducerState = reducerState
        self.attachedSession = attachedSession
    }
}

/// The two authoritative terminal outcomes of an exact detach attempt. A detach receipt exists
/// only when LLDB completed the non-killing detach. If the exact target exits first, the
/// coordinator instead returns its sealed external-exit evidence and terminal reducer snapshot.
enum PersistentLLDBExactDetachTransactionOutcome: Sendable {
    case detached(PersistentLLDBExactDetachTransactionResult)
    case targetExited(
        PersistentLLDBExactAttachedExternalExitResult,
        DebuggerReducerState
    )
}

/// One private physical request within a logical runtime-module refresh. The coordinator supplies
/// the reserved request context; the collector supplies only fixed app-authored commands and
/// bounded transport policy.
struct PersistentLLDBRuntimeModulePhysicalRequest: Sendable {
    let semanticCommands: [String]
    let observedPIDRequirement: LLDBCLIObservedPIDRequirement
    let timeout: Duration

    init(
        semanticCommands: [String],
        observedPIDRequirement: LLDBCLIObservedPIDRequirement,
        timeout: Duration
    ) {
        self.semanticCommands = semanticCommands
        self.observedPIDRequirement = observedPIDRequirement
        self.timeout = timeout
    }
}

/// Complete all-or-nothing collector result. Partial pages never cross this coordinator seam.
struct PersistentLLDBRuntimeModuleRefreshCollection: Sendable {
    let observations: [DebuggerRuntimeModuleObservation]
    let observedPID: Int32
    let observedStopID: UInt32
    let adapterGeneration: UInt64

    init(
        observations: [DebuggerRuntimeModuleObservation],
        observedPID: Int32,
        observedStopID: UInt32,
        adapterGeneration: UInt64
    ) {
        self.observations = observations
        self.observedPID = observedPID
        self.observedStopID = observedStopID
        self.adapterGeneration = adapterGeneration
    }
}

/// Single-use exchange surface injected into the production collector. Ordinary exchanges consume
/// the first 111 reserved contexts. Cleanup alone consumes the final reserved context and becomes
/// proven only after its caller-supplied exact-sentinel validator succeeds.
struct PersistentLLDBRuntimeModuleExchangeChannel: Sendable {
    typealias CleanupValidator = @Sendable (LLDBCLITranscriptResult) throws -> Void

    private let executeImplementation: @Sendable (
        PersistentLLDBRuntimeModulePhysicalRequest
    ) async throws -> PersistentLLDBCLIResponse
    private let cleanupImplementation: @Sendable (
        PersistentLLDBRuntimeModulePhysicalRequest,
        @escaping CleanupValidator
    ) async throws -> PersistentLLDBCLIResponse
    fileprivate let parentContext: DebuggerRequestContext
    fileprivate let internalContexts: [DebuggerRequestContext]

    fileprivate init(
        parentContext: DebuggerRequestContext,
        internalContexts: [DebuggerRequestContext],
        execute: @escaping @Sendable (
            PersistentLLDBRuntimeModulePhysicalRequest
        ) async throws -> PersistentLLDBCLIResponse,
        cleanup: @escaping @Sendable (
            PersistentLLDBRuntimeModulePhysicalRequest,
            @escaping CleanupValidator
        ) async throws -> PersistentLLDBCLIResponse
    ) {
        self.parentContext = parentContext
        self.internalContexts = internalContexts
        self.executeImplementation = execute
        self.cleanupImplementation = cleanup
    }

    func execute(
        _ request: PersistentLLDBRuntimeModulePhysicalRequest
    ) async throws -> PersistentLLDBCLIResponse {
        try await executeImplementation(request)
    }

    func cleanup(
        _ request: PersistentLLDBRuntimeModulePhysicalRequest,
        validate: @escaping CleanupValidator
    ) async throws -> PersistentLLDBCLIResponse {
        try await cleanupImplementation(request, validate)
    }
}

/// Sole live-session coordinator above the persistent CLI adapter.
///
/// The coordinator mints all request and event sequences, admits typed coordinates before any
/// request is rendered or dispatched, and feeds only decoder-observed process facts into the pure
/// reducer. It deliberately has no snapshot input, requested-PID input, or arbitrary-command API.
actor PersistentLLDBSessionCoordinator {
    static let runtimeModulePhysicalContextCount = 112
    static let runtimeModuleParentEventBudget: UInt64 = 3
    /// Controller recovery after a possible backend write is bounded to one terminate plus twenty
    /// stopped-status polls. Each request can consume at most three reducer events; one additional
    /// event remains available for the fail-closed invalidation tombstone.
    static let logicalBreakpointRecoveryRequestCapacity: UInt64 = 21
    static let logicalBreakpointRecoveryEventCapacity: UInt64 = 64
    /// A callback page contains at least one of the helper ring's at most 1,024 records unless it
    /// is the final empty acknowledgement. Reserving the record ceiling therefore bounds every
    /// possible complete drain without trusting helper-provided cursors.
    static let logicalBreakpointCallbackDrainPageCapacity = 1_024
    private static let ordinaryOperationEventCapacity: UInt64 = 4

    private struct ValidatedObservation {
        let processID: Int32
        let state: LLDBCLIObservedProcessState
    }

    private struct LogicalBreakpointCallbackDrainAuthority: Sendable {
        let sessionEpoch: DebuggerSessionEpoch
        let adapterGeneration: UInt64
        let processID: Int32
        let token: Data
        let bindingIDsByWireID: [String: DebuggerTransientBreakpointBindingID]
    }

    private struct ReservedOperationContexts: Sendable {
        let parent: DebuggerRequestContext
        let callbackDrain: [DebuggerRequestContext]
    }

    private struct ReservedLogicalBreakpointContexts: Sendable {
        let callbackDrain: [DebuggerRequestContext]
        let transaction: [DebuggerRequestContext]
    }

    private struct ReservedExactDetachContexts: Sendable {
        let callbackDrain: [DebuggerRequestContext]
        let staging: [DebuggerRequestContext]
        let parent: DebuggerRequestContext
    }

    private enum ExactDetachStagingResponseDisposition: Sendable {
        case targetStillLive
        case targetExited(status: Int32?)
    }

    private enum ExactDetachFinalResponseDisposition: Sendable {
        case requiresDetachReceipt
        case targetExited(status: Int32?)
    }

    private let epoch: DebuggerSessionEpoch
    private let executor: any PersistentLLDBCLIExecuting
    private let requestPreparer: any PersistentLLDBCLIRequestPreparing
    private let launchedProcessEvidenceProvider: (any DebuggerLocalProcessEvidenceProviding)?
    private let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock?
    /// Synchronous seam for adversarial tests that linearize a policy mutation or competing
    /// claim after coordinator validation but immediately before the interlock claim. Production
    /// coordinators leave this nil.
    private let exactAttachClaimBoundaryAction: (@Sendable (
        DebuggerLocalProcessExactAttachTransactionClaimInput
    ) -> Void)?
    private var reducer: DebuggerSessionReducer
    private var lastRequestSequence: UInt64 = 0
    private var lastEventSequence = DebuggerEventSequence.initial
    private var activePollRequestID: DebuggerRequestID?
    private var pollCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var logicalBreakpointCallbackAuthority: LogicalBreakpointCallbackDrainAuthority?
    private var logicalBreakpointCallbackDrainIsQuarantined = false
    private var currentExecutionSealAuthority: PersistentLLDBSessionExecutionSealAuthority?

    init(
        epoch: DebuggerSessionEpoch = DebuggerSessionEpoch(),
        executor: any PersistentLLDBCLIExecuting,
        requestPreparer: any PersistentLLDBCLIRequestPreparing,
        capabilities: DebuggerTransportCapabilities = .persistentCLI(
            attachPolicyReason: "Production attach remains policy denied during WS-19."
        ),
        initialRequestSequence: UInt64 = 0,
        initialEventSequence: DebuggerEventSequence = .initial,
        launchedProcessEvidenceProvider: (any DebuggerLocalProcessEvidenceProviding)? = nil,
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock? = nil,
        exactAttachClaimBoundaryAction: (@Sendable (
            DebuggerLocalProcessExactAttachTransactionClaimInput
        ) -> Void)? = nil
    ) {
        self.epoch = epoch
        self.executor = executor
        self.requestPreparer = requestPreparer
        self.launchedProcessEvidenceProvider = launchedProcessEvidenceProvider
        self.attachWriteInterlock = attachWriteInterlock
        self.exactAttachClaimBoundaryAction = exactAttachClaimBoundaryAction
        self.reducer = DebuggerSessionReducer(epoch: epoch, capabilities: capabilities)
        self.lastRequestSequence = initialRequestSequence
        self.lastEventSequence = initialEventSequence
    }

    var reducerState: DebuggerReducerState {
        reducer.state
    }

    /// Direct immutable input for `DebuggerTransportSnapshotProjector`. Projection is one-way;
    /// neither that compatibility snapshot nor any other presentation model can author state.
    var projectionInput: DebuggerReducerState {
        reducer.state
    }

    /// Projects only reducer-accepted authority into post-establishment contexts. The generic
    /// coordinator path deliberately returns `nil` for both establishment operations: legacy
    /// nil-authority launch remains supported, while exact establishment uses a specialized
    /// transaction that corroborates retained-transport evidence before publishing authority.
    static func sessionScopedTargetAuthority(
        for operation: DebuggerOperation,
        reducerState: DebuggerReducerState
    ) -> DebuggerSessionTargetAuthority? {
        guard operation.classification != .sessionEstablishing else { return nil }
        return reducerState.acceptedTargetAuthority
    }

    /// Executes one frozen launch plan and keeps its nil-target parent admitted while the actual
    /// process identity is acquired. No caller PID, identity, snapshot, or command surface enters
    /// this transaction: the retained adapter supplies the PID/stopped state, then the OS evidence
    /// provider must independently return the same complete immutable identity twice.
    func performExactLaunchTransaction(
        _ input: PersistentLLDBExactLaunchTransactionInput
    ) async throws -> PersistentLLDBExactLaunchTransactionResult {
        guard let launchedProcessEvidenceProvider else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestPreparationFailed)
        }
        try validateExactLaunchPreconditions(input)
        guard input.plan.claimExactLaunchExecution() else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        let contexts = try reserveExactLaunchContexts(
            count: input.plan.semanticCommands.count,
            expectedSession: input.expectedSession
        )
        guard let finalContext = contexts.last else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let requests: [PersistentLLDBCLIRequest]
        do {
            requests = try zip(contexts, input.plan.semanticCommands).enumerated().map {
                offset, pair in
                let (context, command) = pair
                return try exactLaunchPhysicalRequest(
                    context: context,
                    command: command,
                    observedPIDRequirement: offset == contexts.count - 1 ? .required : .optional,
                    timeout: input.plan.timeout
                )
            }
        } catch {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestPreparationFailed,
                requestID: finalContext.id
            )
        }

        // The final launch is the only lifecycle-changing command and the highest reserved parent.
        // Admit it before the first executor suspension so actor reentrancy cannot admit another
        // operation while lifecycle-neutral staging is in flight.
        switch reducer.admit(finalContext) {
        case .accepted:
            break
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id,
                reducerRejection: rejection
            )
        }

        for request in requests.dropLast() {
            let context = request.context
            let response: PersistentLLDBCLIResponse
            do {
                response = try await executor.executeCoordinatorSelected(request)
            } catch let failure as PersistentLLDBCLIAdapterFailure {
                guard failure.requestID == context.id,
                      failure.generation == input.adapterGeneration else {
                    try failBeforeWrite(
                        finalContext,
                        label: "Exact launch staging adapter correlation was lost."
                    )
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .adapterInvalidated,
                        requestID: context.id
                    )
                }
                let projected = exactLaunchStagingFailure(failure, for: context)
                try failBeforeWrite(
                    finalContext,
                    label: "Exact launch staging failed before final target dispatch."
                )
                throw projected
            } catch {
                try failBeforeWrite(
                    finalContext,
                    label: "Exact launch staging lost its bounded adapter disposition."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: context.id
                )
            }
            do {
                try validateExactLaunchStagingResponse(
                    response,
                    context: context,
                    adapterGeneration: input.adapterGeneration
                )
                try validateAdmittedExactLaunchState(input, finalContext: finalContext)
            } catch let failure as PersistentLLDBSessionCoordinatorFailure
                where failure.code == .invalidObservedProcess {
                try invalidate(
                    finalContext,
                    label: "Exact launch staging unexpectedly observed a live target."
                )
                throw failure
            } catch {
                try failBeforeWrite(
                    finalContext,
                    label: "Exact launch staging evidence was contradictory."
                )
                throw error
            }
        }

        try validateAdmittedExactLaunchState(input, finalContext: finalContext)
        guard let finalRequest = requests.last else {
            try failBeforeWrite(
                finalContext,
                label: "Exact launch final request was not reserved."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestPreparationFailed,
                requestID: finalContext.id
            )
        }
        let response: PersistentLLDBCLIResponse
        do {
            response = try await executor.executeCoordinatorSelected(finalRequest)
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            guard failure.requestID == finalContext.id,
                  failure.generation == input.adapterGeneration else {
                try markStarted(finalContext)
                try invalidate(finalContext, label: "Exact launch adapter correlation was lost.")
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: finalContext.id
                )
            }
            if case .completed = failure.disposition {
                try markStarted(finalContext)
            }
            try handleAdapterFailure(failure, for: finalContext, deadline: finalRequest.timeout)
            preconditionFailure("Adapter failure handling always throws.")
        } catch {
            try markStarted(finalContext)
            try invalidate(
                finalContext,
                label: "Exact launch execution lost its bounded write disposition."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: finalContext.id
            )
        }

        guard response.requestID == finalContext.id,
              response.generation == input.adapterGeneration else {
            try markStarted(finalContext)
            try invalidate(finalContext, label: "Exact launch response correlation was lost.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: finalContext.id
            )
        }
        try markStarted(finalContext)

        let transcript = response.transcript
        guard transcript.semanticCommandsSucceeded,
              transcript.firstFailedSemanticCommandIndex == nil,
              transcript.semanticCommandTranscripts.count == 1,
              transcript.semanticCommandResultLineByteCounts.count == 1,
              let observedProcessID = transcript.observedProcessID,
              observedProcessID > 0,
              transcript.observedProcessState == .stopped(processID: observedProcessID) else {
            try invalidate(
                finalContext,
                label: "Exact launch did not prove one successful stopped process."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: finalContext.id
            )
        }

        // This unstructured task does not inherit caller cancellation. Both complete observations
        // always execute after the stopped response, and the admitted parent remains pending until
        // their pair is evaluated by this coordinator.
        let seal = input.plan.executableSeal
        let proofTask = Task.detached {
            let first = await launchedProcessEvidenceProvider.authorizationEvidence(
                processID: observedProcessID
            )
            let second = await launchedProcessEvidenceProvider.authorizationEvidence(
                processID: observedProcessID
            )
            guard case .resolved(let first) = first,
                  case .resolved(let second) = second,
                  first.fingerprint.matches(first.identity),
                  second.fingerprint.matches(second.identity),
                  first.identity.processID == observedProcessID,
                  second.identity.processID == observedProcessID,
                  first.identity == second.identity,
                  first.identity.identityDigest == second.identity.identityDigest else {
                return Optional<DebuggerLocalProcessIdentity>.none
            }
            let identity = second.identity
            let expectedArchitecture: DebuggerLocalProcessArchitecture =
                seal.architecture == .arm64 ? .arm64 : .arm64e
            guard identity.canonicalExecutablePath.utf8.elementsEqual(seal.canonicalPath.utf8),
                  identity.executableDeviceID == seal.deviceID,
                  identity.executableFileID == seal.fileID,
                  identity.executableByteCount == seal.byteCount,
                  identity.executableSHA256 == seal.sha256,
                  identity.architecture == expectedArchitecture,
                  identity.machOUUID == seal.machOUUID else {
                return Optional<DebuggerLocalProcessIdentity>.none
            }
            return Optional(identity)
        }
        let provenIdentity = await withTaskCancellationHandler {
            await proofTask.value
        } onCancel: {
            // Once final launch may have committed, caller cancellation cannot interrupt the two
            // mandatory authority observations or authorize speculative target cleanup.
        }
        try validateStartedExactLaunchState(input, finalContext: finalContext)
        guard let provenIdentity,
              provenIdentity.processID == observedProcessID else {
            try invalidate(
                finalContext,
                label: "Exact launch process identity was unstable or contradicted its sealed plan."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: finalContext.id
            )
        }

        let authority = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: provenIdentity))
        )
        try emit(
            .authorizedSessionOpened(
                observedPID: observedProcessID,
                authority: authority
            ),
            for: finalContext
        )
        try emit(
            .processStopped(
                observedPID: observedProcessID,
                reason: .unknown("launch stop-at-entry")
            ),
            for: finalContext
        )
        try emit(
            .requestCompleted(.completed(target: reducer.state.targetDisposition)),
            for: finalContext
        )
        return PersistentLLDBExactLaunchTransactionResult(
            requestID: finalContext.id,
            authority: authority,
            reducerState: reducer.state
        )
    }

    /// Executes the frozen D0 attach helper as individually framed physical exchanges. Every
    /// physical request is reserved up front and contains exactly one app-authored command. Helper
    /// installation and path staging remain lifecycle-neutral; only the highest, final attach
    /// context is admitted, before the first await, so actor reentrancy cannot admit other work.
    func performExactAttachTransaction(
        _ input: PersistentLLDBExactAttachTransactionInput
    ) async throws -> PersistentLLDBExactAttachTransactionResult {
        do {
            return try await performExactAttachTransactionCore(input)
        } catch let failure as PersistentLLDBExactAttachTransactionFailure {
            throw failure
        } catch let admission as PersistentLLDBExactAttachClaimAdmissionFailure {
            // A replay never becomes a registry-settleable exact failure. Only the transaction
            // that actually consumed the permit can carry claim evidence into settlement.
            throw admission.failure
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            throw PersistentLLDBExactAttachTransactionFailure(
                permit: input.permit,
                transactionClaim: nil,
                failure: failure,
                finalRequestID: failure.requestID,
                finalCommandDisposition: .definitelyNotDispatchedOrWritten,
                reducerState: reducer.state
            )
        } catch {
            throw PersistentLLDBExactAttachTransactionFailure(
                permit: input.permit,
                transactionClaim: nil,
                failure: PersistentLLDBSessionCoordinatorFailure(code: .requestPreparationFailed),
                finalRequestID: nil,
                finalCommandDisposition: .definitelyNotDispatchedOrWritten,
                reducerState: reducer.state
            )
        }
    }

    private func performExactAttachTransactionCore(
        _ input: PersistentLLDBExactAttachTransactionInput
    ) async throws -> PersistentLLDBExactAttachTransactionResult {
        let identityInterlock = try validateExactAttachWriteInterlockIdentity(input)
        if identityInterlock.hasBegunExactAttachTransaction(for: input.permit) {
            throw PersistentLLDBExactAttachClaimAdmissionFailure(
                failure: PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
            )
        }
        let interlock = try validateExactAttachWriteInterlock(input)
        let authority = DebuggerSessionTargetAuthority(
            origin: .attached(input.request.selectedIdentity)
        )
        try validateExactAttachPreconditions(input, authority: authority)

        let program = PersistentLLDBAttachProgram.current
        let provisional = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: 1,
            adapterGeneration: input.permit.adapterGeneration,
            authority: authority,
            correlationToken: input.permit.correlationToken
        )
        let provisionalRequestCommands = try program.requestCommands(for: provisional)
        let commandCount = program.installChunkCommands.count
            + 1
            + provisionalRequestCommands.count
        let contexts = try reserveExactAttachContexts(
            count: commandCount,
            expectedSession: input.permit.admissionSession,
            authority: authority
        )
        guard let finalContext = contexts.last else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }

        let programRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: finalContext.id.sequence,
            adapterGeneration: input.permit.adapterGeneration,
            authority: authority,
            correlationToken: input.permit.correlationToken
        )
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: programRequest))
        guard commands.count == contexts.count else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
        }
        do {
            for command in commands {
                _ = try program.completeEncodedWireByteCount(for: command)
            }
        } catch {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestPreparationFailed)
        }

        guard let claimInput = DebuggerLocalProcessExactAttachTransactionClaimInput(
            policyRevision: input.permit.observationPolicyRevision,
            interlockIdentity: input.permit.attachWriteInterlockIdentity,
            permit: input.permit,
            finalAttachRequest: finalContext
        ) else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .preparedRequestMismatch,
                requestID: finalContext.id
            )
        }
        let transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim
        exactAttachClaimBoundaryAction?(claimInput)
        do {
            transactionClaim = try interlock.claimExactAttachTransaction(claimInput)
        } catch {
            // The earlier hasBegun check owns ordinary spent-permit replay rejection. A failure
            // here can instead be legitimate revision drift while the permit remains unclaimed.
            // Preserve a nil-claim, definitely-not-written typed failure so registry settlement
            // can remove that authentic lease. If a competing claimant won this boundary race,
            // atomic interlock settlement observes its claim and rejects removal.
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id
            )
        }

        var finalCommandDisposition =
            PersistentLLDBExactAttachFinalCommandDisposition.definitelyNotDispatchedOrWritten
        do {
        guard let adapterInstanceBinding = await executor.exactAdapterInstanceBinding(),
              adapterInstanceBinding.sessionEpoch == input.permit.admissionSession.epoch,
              adapterInstanceBinding.adapterGeneration == input.permit.adapterGeneration,
              adapterInstanceBinding.digest.count == 32 else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        do {
            try interlock.bindExactAttachTransactionAdapter(
                adapterInstanceBinding,
                to: transactionClaim
            )
        } catch {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id
            )
        }

        switch reducer.admit(finalContext) {
        case .accepted:
            break
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id,
                reducerRejection: rejection
            )
        }

        for (stagingOrdinal, pair) in zip(
            contexts.dropLast(),
            commands.dropLast()
        ).enumerated() {
            let (context, command) = pair
            let request: PersistentLLDBCLIRequest
            do {
                let interlock = try validateExactAttachWriteInterlock(input)
                guard let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: [command]
                ),
                      let issuanceInput = DebuggerLocalProcessAttachStagingWriteIssuanceInput(
                        policyRevision: input.permit.observationPolicyRevision,
                        interlockIdentity: input.permit.attachWriteInterlockIdentity,
                        permit: input.permit,
                        adapterInstanceBinding: adapterInstanceBinding,
                        stagingRequest: context,
                        finalAttachRequest: finalContext,
                        stagingOrdinal: stagingOrdinal,
                        semanticDigest: semanticDigest,
                        transactionClaim: transactionClaim
                      ) else {
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .preparedRequestMismatch,
                        requestID: context.id
                    )
                }
                let authorization = try interlock.issueExactAttachStagingWriteAuthorization(
                    for: issuanceInput
                )
                request = try exactAttachPhysicalRequest(
                    context: context,
                    command: command,
                    observedPIDRequirement: .optional,
                    writeRole: .exactAttachStaging(
                        PersistentLLDBCLIExactAttachStagingWriteAuthorization(
                            interlock: interlock,
                            issuanceInput: issuanceInput,
                            authorization: authorization
                        )
                    )
                )
            } catch {
                try failBeforeWrite(
                    finalContext,
                    label: "Exact attach staging request construction failed."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .requestPreparationFailed,
                    requestID: context.id
                )
            }
            let response: PersistentLLDBCLIResponse
            do {
                response = try await executor.executeCoordinatorSelected(request)
            } catch let failure as PersistentLLDBCLIAdapterFailure {
                guard failure.requestID == context.id,
                      failure.generation == input.permit.adapterGeneration else {
                    try failBeforeWrite(
                        finalContext,
                        label: "Exact attach staging adapter correlation was lost."
                    )
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .adapterInvalidated,
                        requestID: context.id
                    )
                }
                let projected = exactAttachStagingFailure(failure, for: context)
                try failBeforeWrite(
                    finalContext,
                    label: "Exact attach staging failed before final target dispatch."
                )
                throw projected
            } catch {
                try failBeforeWrite(
                    finalContext,
                    label: "Exact attach staging lost its bounded adapter disposition."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: context.id
                )
            }
            do {
                try validateExactAttachStagingResponse(
                    response,
                    context: context,
                    adapterGeneration: input.permit.adapterGeneration
                )
                try validateAdmittedExactAttachState(
                    input,
                    authority: authority,
                    finalContext: finalContext
                )
                try validateExactAttachWriteInterlock(input)
            } catch let failure as PersistentLLDBSessionCoordinatorFailure
                where failure.code == .invalidObservedProcess {
                try invalidate(
                    finalContext,
                    label: "Exact attach staging unexpectedly observed a live target."
                )
                throw failure
            } catch {
                try failBeforeWrite(
                    finalContext,
                    label: "Exact attach staging evidence was contradictory."
                )
                throw error
            }
        }

        let finalRequest: PersistentLLDBCLIRequest
        let finalIssuanceInput: DebuggerLocalProcessAttachWriteIssuanceInput
        let finalWriteGrant: DebuggerLocalProcessAttachWriteGrant
        do {
            let finalCommand = commands[commands.index(before: commands.endIndex)]
            let interlock = try validateExactAttachWriteInterlock(input)
            guard let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                semanticCommands: [finalCommand]
            ),
                  let issuanceInput = DebuggerLocalProcessAttachWriteIssuanceInput(
                    policyRevision: input.permit.observationPolicyRevision,
                    interlockIdentity: input.permit.attachWriteInterlockIdentity,
                    permit: input.permit,
                    adapterInstanceBinding: adapterInstanceBinding,
                    finalAttachRequest: finalContext,
                    semanticDigest: semanticDigest,
                    transactionClaim: transactionClaim
                  ) else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .preparedRequestMismatch,
                    requestID: finalContext.id
                )
            }
            let grant = try interlock.issueExactAttachWriteGrant(for: issuanceInput)
            finalRequest = try exactAttachPhysicalRequest(
                context: finalContext,
                command: finalCommand,
                observedPIDRequirement: .required,
                writeRole: .exactAttachFinal(
                    PersistentLLDBCLIExactAttachFinalWriteAuthorization(
                        interlock: interlock,
                        issuanceInput: issuanceInput,
                        grant: grant
                    )
                )
            )
            finalIssuanceInput = issuanceInput
            finalWriteGrant = grant
        } catch {
            try failBeforeWrite(finalContext, label: "Exact attach request construction failed.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestPreparationFailed,
                requestID: finalContext.id
            )
        }

        let response: PersistentLLDBCLIResponse
        finalCommandDisposition = .mayHaveWrittenOrAcceptedAuthority
        do {
            response = try await executor.executeCoordinatorSelected(finalRequest)
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            guard failure.requestID == finalContext.id,
                  failure.generation == input.permit.adapterGeneration else {
                try markStarted(finalContext)
                try invalidate(
                    finalContext,
                    label: "Exact attach final adapter correlation was lost."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: finalContext.id
                )
            }
            switch failure.disposition {
            case .cancelledBeforeWrite, .failedBeforeWrite:
                finalCommandDisposition = .definitelyNotDispatchedOrWritten
            case .invalidatedAfterWrite, .completed:
                break
            }
            try handleAdapterFailure(failure, for: finalContext, deadline: finalRequest.timeout)
            preconditionFailure("Adapter failure handling always throws.")
        } catch {
            try markStarted(finalContext)
            try invalidate(
                finalContext,
                label: "Exact attach execution failed after an unbounded write disposition."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: finalContext.id
            )
        }

        try markStarted(finalContext)
        guard let interlock = attachWriteInterlock,
              let exactAttachWriteCommit = response.exactAttachWriteCommit,
              interlock.validatesExactAttachWriteCommit(
                exactAttachWriteCommit,
                for: finalWriteGrant,
                matching: finalIssuanceInput
              ) else {
            try invalidate(
                finalContext,
                label: "Exact attach response lacked the exact final-write commit proof."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: finalContext.id
            )
        }
        let receipt: PersistentLLDBAttachReceipt
        do {
            receipt = try PersistentLLDBLifecycleReceiptTranscriptDecoder()
                .decodeAttachReceipt(from: response, expected: programRequest)
        } catch {
            try invalidate(finalContext, label: "Exact attach receipt was not canonical and correlated.")
            let code: PersistentLLDBSessionCoordinatorFailureCode
            if let decoding = error as? PersistentLLDBLifecycleReceiptTranscriptDecoderError,
               decoding == .responseCorrelationMismatch {
                code = .responseCorrelationMismatch
            } else {
                code = .responseProjectionFailed
            }
            throw PersistentLLDBSessionCoordinatorFailure(
                code: code,
                requestID: finalContext.id
            )
        }
        guard response.transcript.observedProcessID == authority.processID,
              response.transcript.observedProcessState
                == .stopped(processID: authority.processID),
              receipt.observedProcessID == authority.processID,
              receipt.state == .stopped else {
            try invalidate(finalContext, label: "Exact attach process observation was contradictory.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: finalContext.id
            )
        }

        try emit(
            .authorizedSessionOpened(
                observedPID: authority.processID,
                authority: authority
            ),
            for: finalContext
        )
        try emit(
            .processStopped(
                observedPID: authority.processID,
                reason: exactAttachStopReason(receipt.stopReason)
            ),
            for: finalContext
        )
        try emit(
            .requestCompleted(.completed(target: reducer.state.targetDisposition)),
            for: finalContext
        )
        let establishedState = reducer.state
        guard establishedState.sessionCoordinate.epoch == finalContext.id.epoch,
              establishedState.sessionCoordinate.epoch == input.permit.admissionSession.epoch,
              establishedState.lastAdmittedRequestSequence == finalContext.id.sequence,
              establishedState.pendingRequest == nil,
              establishedState.acceptedTargetAuthority == input.permit.authority,
              establishedState.observedProcessID == input.permit.authority.processID,
              receipt.observedProcessID == input.permit.authority.processID,
              receipt.lldbProcessUniqueID > 0 else {
            try invalidate(
                finalContext,
                label: "Exact attach established evidence failed reducer/request correlation."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: finalContext.id
            )
        }
        let attachedSession = PersistentLLDBExactAttachedSessionEvidence(
            permit: input.permit,
            transactionClaim: transactionClaim,
            adapterInstanceBinding: adapterInstanceBinding,
            establishedSession: establishedState.sessionCoordinate,
            lldbProcessUniqueID: receipt.lldbProcessUniqueID
        )
        return PersistentLLDBExactAttachTransactionResult(
            requestID: finalContext.id,
            receipt: receipt,
            reducerState: establishedState,
            attachedSession: attachedSession
        )
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            if interlock.validatesCompletedExactAttachClaim(
                transactionClaim,
                permit: input.permit
            ) {
                finalCommandDisposition = .mayHaveWrittenOrAcceptedAuthority
            }
            throw PersistentLLDBExactAttachTransactionFailure(
                permit: input.permit,
                transactionClaim: transactionClaim,
                failure: failure,
                finalRequestID: finalContext.id,
                finalCommandDisposition: finalCommandDisposition,
                reducerState: reducer.state
            )
        } catch {
            if interlock.validatesCompletedExactAttachClaim(
                transactionClaim,
                permit: input.permit
            ) {
                finalCommandDisposition = .mayHaveWrittenOrAcceptedAuthority
            }
            let code: PersistentLLDBSessionCoordinatorFailureCode =
                finalCommandDisposition == .definitelyNotDispatchedOrWritten
                    ? .requestPreparationFailed
                    : .responseProjectionFailed
            throw PersistentLLDBExactAttachTransactionFailure(
                permit: input.permit,
                transactionClaim: transactionClaim,
                failure: PersistentLLDBSessionCoordinatorFailure(
                    code: code,
                    requestID: finalContext.id
                ),
                finalRequestID: finalContext.id,
                finalCommandDisposition: finalCommandDisposition,
                reducerState: reducer.state
            )
        }
    }

    private func validateExactLaunchPreconditions(
        _ input: PersistentLLDBExactLaunchTransactionInput
    ) throws {
        let state = reducer.state
        let path = input.plan.canonicalExecutablePath
        guard input.adapterGeneration > 0,
              !input.plan.semanticCommands.isEmpty,
              input.plan.semanticCommands.last
                == "process launch --stop-at-entry --no-stdio",
              path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.hasPrefix("//"),
              (path as NSString).standardizingPath == path,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              state.epoch == epoch,
              state.sessionCoordinate == input.expectedSession,
              state.pendingRequest == nil,
              state.processPhase == .noTarget,
              state.observedProcessID == nil,
              state.acceptedTargetAuthority == nil,
              state.targetDisposition == .notStarted,
              state.stopRevision == nil,
              !state.isInvalidated else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
    }

    private func reserveExactLaunchContexts(
        count: Int,
        expectedSession: DebuggerSessionCoordinate
    ) throws -> [DebuggerRequestContext] {
        guard count > 0, let requestCount = UInt64(exactly: count) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let end = lastRequestSequence.addingReportingOverflow(requestCount)
        guard !end.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        guard !lastEventSequence.rawValue.addingReportingOverflow(4).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        let first = lastRequestSequence + 1
        let contexts = (0..<count).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(
                    epoch: epoch,
                    sequence: first + UInt64(offset)
                ),
                operation: .launch,
                expectedSession: expectedSession,
                requiredStop: nil,
                targetAuthority: nil
            )
        }
        guard contexts.allSatisfy(\.isInternallyConsistent) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
        }
        lastRequestSequence = end.partialValue
        return contexts
    }

    private func exactLaunchPhysicalRequest(
        context: DebuggerRequestContext,
        command: String,
        observedPIDRequirement: LLDBCLIObservedPIDRequirement,
        timeout: Duration
    ) throws -> PersistentLLDBCLIRequest {
        try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [command],
            observedPIDRequirement: observedPIDRequirement,
            timeout: timeout
        )
    }

    private func validateExactLaunchStagingResponse(
        _ response: PersistentLLDBCLIResponse,
        context: DebuggerRequestContext,
        adapterGeneration: UInt64
    ) throws {
        guard response.requestID == context.id,
              response.generation == adapterGeneration else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }
        let transcript = response.transcript
        guard transcript.semanticCommandsSucceeded,
              transcript.firstFailedSemanticCommandIndex == nil,
              transcript.semanticCommandTranscripts.count == 1,
              transcript.semanticCommandResultLineByteCounts.count == 1 else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: context.id
            )
        }
        guard transcript.observedProcessID == nil,
              transcript.observedProcessState == nil else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
    }

    private func validateAdmittedExactLaunchState(
        _ input: PersistentLLDBExactLaunchTransactionInput,
        finalContext: DebuggerRequestContext
    ) throws {
        let state = reducer.state
        guard state.sessionCoordinate == input.expectedSession,
              state.pendingRequest?.context == finalContext,
              state.pendingRequest?.hasStarted == false,
              state.processPhase == .noTarget,
              state.observedProcessID == nil,
              state.acceptedTargetAuthority == nil,
              state.targetDisposition == .notStarted,
              !state.isInvalidated else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id
            )
        }
    }

    private func validateStartedExactLaunchState(
        _ input: PersistentLLDBExactLaunchTransactionInput,
        finalContext: DebuggerRequestContext
    ) throws {
        let state = reducer.state
        guard state.sessionCoordinate == input.expectedSession,
              state.pendingRequest?.context == finalContext,
              state.pendingRequest?.hasStarted == true,
              state.processPhase == .noTarget,
              state.observedProcessID == nil,
              state.acceptedTargetAuthority == nil,
              state.targetDisposition == .notStarted,
              !state.isInvalidated else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id
            )
        }
    }

    private func exactLaunchStagingFailure(
        _ failure: PersistentLLDBCLIAdapterFailure,
        for context: DebuggerRequestContext
    ) -> PersistentLLDBSessionCoordinatorFailure {
        precondition(failure.requestID == context.id)
        let code: PersistentLLDBSessionCoordinatorFailureCode
        switch failure.disposition {
        case .cancelledBeforeWrite:
            code = .adapterCancelled
        case .failedBeforeWrite:
            code = .adapterFailedBeforeWrite
        case .invalidatedAfterWrite, .completed:
            code = .adapterInvalidated
        }
        return PersistentLLDBSessionCoordinatorFailure(
            code: code,
            requestID: context.id
        )
    }

    private func validateExactAttachPreconditions(
        _ input: PersistentLLDBExactAttachTransactionInput,
        authority: DebuggerSessionTargetAuthority
    ) throws {
        let state = reducer.state
        guard let attachWriteInterlock,
              attachWriteInterlock.identity == input.permit.attachWriteInterlockIdentity,
              attachWriteInterlock.validatesCurrentRevision(
                input.permit.observationPolicyRevision
              ),
              input.permit.adapterGeneration > 0,
              input.permit.correlationToken.count == 32,
              input.permit.bindingDigest.count == 32,
              state.epoch == epoch,
              state.sessionCoordinate == input.permit.admissionSession,
              state.pendingRequest == nil,
              state.processPhase == .noTarget,
              state.observedProcessID == nil,
              state.acceptedTargetAuthority == nil,
              state.targetDisposition == .notStarted,
              !state.isInvalidated,
              input.permit.authority == authority,
              authority.processID == input.request.selectedIdentity.processID,
              case .attached(let identity) = authority.origin,
              identity == input.request.selectedIdentity else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
    }

    private func reserveExactAttachContexts(
        count: Int,
        expectedSession: DebuggerSessionCoordinate,
        authority: DebuggerSessionTargetAuthority
    ) throws -> [DebuggerRequestContext] {
        guard count > 0, let requestCount = UInt64(exactly: count) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let end = lastRequestSequence.addingReportingOverflow(requestCount)
        guard !end.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        guard !lastEventSequence.rawValue.addingReportingOverflow(4).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        let first = lastRequestSequence + 1
        let contexts = (0..<count).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(
                    epoch: epoch,
                    sequence: first + UInt64(offset)
                ),
                operation: .attach,
                expectedSession: expectedSession,
                requiredStop: nil,
                targetAuthority: authority
            )
        }
        guard contexts.allSatisfy(\.isInternallyConsistent) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
        }
        lastRequestSequence = end.partialValue
        return contexts
    }

    private func validateAdmittedExactAttachState(
        _ input: PersistentLLDBExactAttachTransactionInput,
        authority: DebuggerSessionTargetAuthority,
        finalContext: DebuggerRequestContext
    ) throws {
        let state = reducer.state
        guard state.sessionCoordinate == input.permit.admissionSession,
              state.pendingRequest?.context == finalContext,
              state.pendingRequest?.hasStarted == false,
              state.processPhase == .noTarget,
              state.observedProcessID == nil,
              state.acceptedTargetAuthority == nil,
              state.targetDisposition == .notStarted,
              !state.isInvalidated,
              finalContext.targetAuthority == authority else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: finalContext.id
            )
        }
    }

    private func exactAttachPhysicalRequest(
        context: DebuggerRequestContext,
        command: String,
        observedPIDRequirement: LLDBCLIObservedPIDRequirement,
        writeRole: PersistentLLDBCLIRequestWriteRole = .ordinary
    ) throws -> PersistentLLDBCLIRequest {
        try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [command],
            observedPIDRequirement: observedPIDRequirement,
            timeout: .seconds(5),
            writeRole: writeRole
        )
    }

    @discardableResult
    private func validateExactAttachWriteInterlockIdentity(
        _ input: PersistentLLDBExactAttachTransactionInput
    ) throws -> DebuggerLocalProcessAttachWriteInterlock {
        guard let attachWriteInterlock,
              attachWriteInterlock.identity == input.permit.attachWriteInterlockIdentity else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        return attachWriteInterlock
    }

    @discardableResult
    private func validateExactAttachWriteInterlock(
        _ input: PersistentLLDBExactAttachTransactionInput
    ) throws -> DebuggerLocalProcessAttachWriteInterlock {
        let attachWriteInterlock = try validateExactAttachWriteInterlockIdentity(input)
        guard attachWriteInterlock.validatesCurrentRevision(
            input.permit.observationPolicyRevision
        ) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        return attachWriteInterlock
    }

    private func validateExactAttachStagingResponse(
        _ response: PersistentLLDBCLIResponse,
        context: DebuggerRequestContext,
        adapterGeneration: UInt64
    ) throws {
        guard response.requestID == context.id,
              response.generation == adapterGeneration else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }
        let transcript = response.transcript
        let semanticByteCount = transcript.semanticCommandTranscripts.first?.utf8.count
        guard transcript.semanticCommandsSucceeded,
              transcript.firstFailedSemanticCommandIndex == nil,
              transcript.semanticCommandTranscripts.count == 1,
              transcript.semanticCommandResultLineByteCounts.count == 1,
              transcript.semanticCommandTranscripts[0].isEmpty,
              let semanticByteCount,
              transcript.semanticCommandResultLineByteCounts[0] >= semanticByteCount,
              transcript.semanticCommandResultLineByteCounts[0]
                <= LLDBCLITranscriptDecoder.maximumExchangeBytes,
              transcript.exchangeByteCount >= 0,
              transcript.exchangeByteCount <= LLDBCLITranscriptDecoder.maximumExchangeBytes else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: context.id
            )
        }
        guard transcript.observedProcessID == nil,
              transcript.observedProcessState == nil else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
    }

    private func exactAttachStagingFailure(
        _ failure: PersistentLLDBCLIAdapterFailure,
        for context: DebuggerRequestContext
    ) -> PersistentLLDBSessionCoordinatorFailure {
        precondition(failure.requestID == context.id)
        let code: PersistentLLDBSessionCoordinatorFailureCode
        switch failure.disposition {
        case .cancelledBeforeWrite:
            code = .adapterCancelled
        case .failedBeforeWrite:
            code = .adapterFailedBeforeWrite
        case .invalidatedAfterWrite, .completed:
            code = .adapterInvalidated
        }
        return PersistentLLDBSessionCoordinatorFailure(
            code: code,
            requestID: context.id
        )
    }

    private func exactAttachStopReason(
        _ reason: PersistentLLDBAttachStopReason
    ) -> DebuggerTransportStopReason {
        switch reason.kind {
        case .trace, .planComplete:
            return .step
        case .signal:
            return .signal(reason.data.first.map { String($0) } ?? "unknown")
        case .breakpoint, .watchpoint, .exception, .exec, .threadExiting,
             .instrumentation, .processorTrace, .fork, .vfork, .vforkDone:
            return .unknown("LLDB exact attach stop reason: \(reason.kind.rawValue).")
        }
    }

    /// Executes the frozen D0 detach helper through individually correlated exchanges. Callback
    /// pages and helper installation are private transport work; only the highest final context is
    /// admitted to the reducer, and it is admitted before the first suspension point.
    func performExactDetachTransaction(
        _ input: PersistentLLDBExactDetachTransactionInput
    ) async throws -> PersistentLLDBExactDetachTransactionOutcome {
        let attachedSession = input.attachedSession
        let permit = attachedSession.permit
        let authority = try validateExactDetachPreconditions(input)
        let program = PersistentLLDBDetachProgram()
        let stagingCommands = program.installChunkCommands + [program.installFinalizeCommand]
        let reserved = try reserveExactDetachContexts(
            stagingCount: stagingCommands.count,
            expectedSession: attachedSession.establishedSession,
            authority: authority
        )
        let programRequest = try PersistentLLDBDetachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: reserved.parent.id.sequence,
            adapterGeneration: permit.adapterGeneration,
            authority: authority,
            expectedLLDBProcessUniqueID: attachedSession.lldbProcessUniqueID,
            correlationToken: permit.correlationToken
        )
        let finalCommand: String
        do {
            finalCommand = try program.command(for: programRequest)
            for command in stagingCommands + [finalCommand] {
                _ = try program.completeEncodedWireByteCount(for: command)
            }
        } catch {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestPreparationFailed)
        }

        switch reducer.admit(reserved.parent) {
        case .accepted:
            break
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: reserved.parent.id,
                reducerRejection: rejection
            )
        }

        if let callbackAuthority = logicalBreakpointCallbackAuthority {
            let latestState: LLDBCLIObservedProcessState
            do {
                let initialState = try callbackDrainInitialProcessState(for: callbackAuthority)
                latestState = try await drainLogicalBreakpointCallbacksBeforeLifecycleAcceptance(
                    callbackAuthority,
                    contexts: reserved.callbackDrain,
                    initialProcessState: initialState,
                    permitsInitialResumeTransition: false
                )
                try validateAdmittedExactDetachState(
                    input,
                    authority: authority,
                    parent: reserved.parent
                )
            } catch {
                logicalBreakpointCallbackDrainIsQuarantined = true
                try failPendingRequestAfterCallbackDrain(reserved.parent)
                throw PersistentLLDBExactDetachPreFinalFailure(
                    code: logicalBreakpointFailureCode(error),
                    disposition: .retireAdapterAndReobserve,
                    reducerState: reducer.state
                )
            }
            switch latestState {
            case .running(let processID), .stopped(let processID):
                guard processID == authority.processID else {
                    try invalidate(
                        reserved.parent,
                        label: "Exact detach callback drain changed process authority."
                    )
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .invalidObservedProcess,
                        requestID: reserved.parent.id
                    )
                }
            case .exited(let processID, let status):
                guard processID == authority.processID else {
                    try invalidate(
                        reserved.parent,
                        label: "Exact detach callback drain changed process authority."
                    )
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .invalidObservedProcess,
                        requestID: reserved.parent.id
                    )
                }
                return try await exactDetachTargetExitedOutcome(
                    status: status,
                    attachedSession: attachedSession,
                    parent: reserved.parent
                )
            }
        }

        for (context, command) in zip(reserved.staging, stagingCommands) {
            try validateAdmittedExactDetachState(
                input,
                authority: authority,
                parent: reserved.parent
            )
            let request: PersistentLLDBCLIRequest
            do {
                request = try exactDetachPhysicalRequest(
                    context: context,
                    command: command,
                    observedPIDRequirement: .required
                )
            } catch {
                try failBeforeWrite(
                    reserved.parent,
                    label: "Exact detach staging request construction failed."
                )
                throw exactDetachPreFinalFailure(code: .requestPreparationFailed)
            }

            let response: PersistentLLDBCLIResponse
            do {
                response = try await executor.executeCoordinatorSelected(request)
            } catch let failure as PersistentLLDBCLIAdapterFailure {
                try handleExactDetachStagingFailure(
                    failure,
                    context: context,
                    parent: reserved.parent,
                    adapterGeneration: permit.adapterGeneration
                )
                preconditionFailure("Exact detach staging failure handling always throws.")
            } catch {
                try failBeforeWrite(
                    reserved.parent,
                    label: "Exact detach helper staging lost its bounded adapter disposition "
                        + "before detach dispatch."
                )
                throw exactDetachPreFinalFailure(code: .adapterInvalidated)
            }

            let stagingDisposition: ExactDetachStagingResponseDisposition
            do {
                stagingDisposition = try validateExactDetachStagingResponse(
                    response,
                    context: context,
                    adapterGeneration: permit.adapterGeneration,
                    authority: authority
                )
            } catch let failure as PersistentLLDBSessionCoordinatorFailure {
                if failure.code == .invalidObservedProcess {
                    try invalidate(
                        reserved.parent,
                        label: "Exact detach staging process authority was contradictory."
                    )
                } else {
                    try failBeforeWrite(
                        reserved.parent,
                        label: "Exact detach helper staging was rejected before detach dispatch."
                    )
                    throw exactDetachPreFinalFailure(code: failure.code)
                }
                throw failure
            } catch {
                try failBeforeWrite(
                    reserved.parent,
                    label: "Exact detach helper staging could not be projected before detach "
                        + "dispatch."
                )
                throw exactDetachPreFinalFailure(code: .responseProjectionFailed)
            }

            switch stagingDisposition {
            case .targetStillLive:
                try validateAdmittedExactDetachState(
                    input,
                    authority: authority,
                    parent: reserved.parent
                )
            case .targetExited(let status):
                return try await exactDetachTargetExitedOutcome(
                    status: status,
                    attachedSession: attachedSession,
                    parent: reserved.parent
                )
            }
        }

        try validateAdmittedExactDetachState(
            input,
            authority: authority,
            parent: reserved.parent
        )
        let finalRequest: PersistentLLDBCLIRequest
        do {
            finalRequest = try exactDetachPhysicalRequest(
                context: reserved.parent,
                command: finalCommand,
                observedPIDRequirement: .optional
            )
        } catch {
            try failBeforeWrite(reserved.parent, label: "Exact detach request construction failed.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestPreparationFailed,
                requestID: reserved.parent.id
            )
        }

        let response: PersistentLLDBCLIResponse
        do {
            response = try await executor.executeCoordinatorSelected(finalRequest)
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            guard failure.requestID == reserved.parent.id,
                  failure.generation == permit.adapterGeneration else {
                try markStarted(reserved.parent)
                try invalidate(
                    reserved.parent,
                    label: "Exact detach final adapter correlation was lost."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: reserved.parent.id
                )
            }
            if case .completed = failure.disposition {
                try markStarted(reserved.parent)
                try invalidate(
                    reserved.parent,
                    label: "Exact detach final exchange threw a completed disposition."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: reserved.parent.id
                )
            }
            try handleAdapterFailure(failure, for: reserved.parent, deadline: finalRequest.timeout)
            preconditionFailure("Adapter failure handling always throws.")
        } catch {
            try markStarted(reserved.parent)
            try invalidate(
                reserved.parent,
                label: "Exact detach execution failed after an unbounded write disposition."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: reserved.parent.id
            )
        }

        try markStarted(reserved.parent)
        let finalDisposition: ExactDetachFinalResponseDisposition
        do {
            finalDisposition = try exactDetachFinalResponseDisposition(
                response,
                context: reserved.parent,
                adapterGeneration: permit.adapterGeneration,
                authority: authority
            )
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            try invalidate(
                reserved.parent,
                label: "Exact detach final response process authority was contradictory."
            )
            throw failure
        }
        if case .targetExited(let status) = finalDisposition {
            return try await exactDetachTargetExitedOutcome(
                status: status,
                attachedSession: attachedSession,
                parent: reserved.parent
            )
        }

        let receipt: PersistentLLDBDetachReceipt
        do {
            receipt = try PersistentLLDBLifecycleReceiptTranscriptDecoder()
                .decodeDetachReceipt(from: response, expected: programRequest)
        } catch {
            try invalidate(
                reserved.parent,
                label: "Exact detach receipt was not canonical and correlated."
            )
            let code: PersistentLLDBSessionCoordinatorFailureCode
            if let decoding = error as? PersistentLLDBLifecycleReceiptTranscriptDecoderError,
               decoding == .responseCorrelationMismatch {
                code = .responseCorrelationMismatch
            } else {
                code = .responseProjectionFailed
            }
            throw PersistentLLDBSessionCoordinatorFailure(
                code: code,
                requestID: reserved.parent.id
            )
        }
        guard receipt.observedProcessID == authority.processID,
           receipt.lldbProcessUniqueID == attachedSession.lldbProcessUniqueID,
           receipt.acknowledged,
           receipt.resumeOnDetach else {
            try invalidate(
                reserved.parent,
                label: "Exact detach process observation was contradictory."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: reserved.parent.id
            )
        }

        try emit(.processDetached(authority: authority), for: reserved.parent)
        return .detached(
            PersistentLLDBExactDetachTransactionResult(
                requestID: reserved.parent.id,
                receipt: receipt,
                reducerState: reducer.state,
                attachedSession: attachedSession
            )
        )
    }

    private func validateExactDetachPreconditions(
        _ input: PersistentLLDBExactDetachTransactionInput
    ) throws -> DebuggerSessionTargetAuthority {
        let attachedSession = input.attachedSession
        let permit = attachedSession.permit
        let state = reducer.state
        guard permit.adapterGeneration > 0,
              permit.correlationToken.count == 32,
              permit.bindingDigest.count == 32,
              attachedSession.lldbProcessUniqueID > 0,
              attachedSession.bindingDigest.count == 32,
              attachedSession.hasValidBinding(),
              !logicalBreakpointCallbackDrainIsQuarantined,
              state.epoch == epoch,
              permit.admissionSession.epoch == epoch,
              state.sessionCoordinate == attachedSession.establishedSession,
              state.pendingRequest == nil,
              !state.isInvalidated,
              let authority = state.acceptedTargetAuthority,
              case .attached = authority.origin,
              authority == permit.authority,
              state.observedProcessID == authority.processID else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        switch (state.processPhase, state.targetDisposition) {
        case let (.running(phasePID), .running(dispositionPID)):
            guard phasePID == authority.processID,
                  dispositionPID == authority.processID,
                  state.stopRevision == nil else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
            }
        case let (.stopped(phasePID, _), .stopped(dispositionPID)):
            guard phasePID == authority.processID,
                  dispositionPID == authority.processID,
                  state.stopCoordinate?.session == state.sessionCoordinate else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
            }
        case (.noTarget, _), (.detaching, _), (.exited, _), (.detached, _),
             (.terminated, _), (.invalidated, _), (.running, _), (.stopped, _):
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        return authority
    }

    private func reserveExactDetachContexts(
        stagingCount: Int,
        expectedSession: DebuggerSessionCoordinate,
        authority: DebuggerSessionTargetAuthority
    ) throws -> ReservedExactDetachContexts {
        guard stagingCount > 0, let stagingRequestCount = UInt64(exactly: stagingCount) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let callbackCount = logicalBreakpointCallbackAuthority == nil
            ? 0
            : Self.logicalBreakpointCallbackDrainPageCapacity
        guard let callbackRequestCount = UInt64(exactly: callbackCount) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let subtotal = callbackRequestCount.addingReportingOverflow(stagingRequestCount)
        guard !subtotal.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let total = subtotal.partialValue.addingReportingOverflow(1)
        guard !total.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let end = lastRequestSequence.addingReportingOverflow(total.partialValue)
        guard !end.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let eventCapacity = callbackRequestCount.addingReportingOverflow(2)
        guard !eventCapacity.overflow,
              !lastEventSequence.rawValue.addingReportingOverflow(
                  eventCapacity.partialValue
              ).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }

        let first = lastRequestSequence + 1
        let callbackDrain = (0..<callbackCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: first + UInt64(offset)),
                operation: .pollProcessStatus,
                expectedSession: expectedSession,
                requiredStop: nil,
                targetAuthority: authority
            )
        }
        let stagingFirst = first + callbackRequestCount
        let staging = (0..<stagingCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: stagingFirst + UInt64(offset)),
                operation: .detach,
                expectedSession: expectedSession,
                requiredStop: nil,
                targetAuthority: authority
            )
        }
        let parent = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: end.partialValue),
            operation: .detach,
            expectedSession: expectedSession,
            requiredStop: nil,
            targetAuthority: authority
        )
        guard callbackDrain.allSatisfy(\.isInternallyConsistent),
              staging.allSatisfy(\.isInternallyConsistent),
              parent.isInternallyConsistent else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
        }
        lastRequestSequence = end.partialValue
        return ReservedExactDetachContexts(
            callbackDrain: callbackDrain,
            staging: staging,
            parent: parent
        )
    }

    private func validateAdmittedExactDetachState(
        _ input: PersistentLLDBExactDetachTransactionInput,
        authority: DebuggerSessionTargetAuthority,
        parent: DebuggerRequestContext
    ) throws {
        let state = reducer.state
        guard state.sessionCoordinate == input.attachedSession.establishedSession,
              state.pendingRequest?.context == parent,
              state.pendingRequest?.hasStarted == false,
              state.observedProcessID == authority.processID,
              state.acceptedTargetAuthority == authority,
              !state.isInvalidated else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: parent.id
            )
        }
        switch state.processPhase {
        case .running(let processID), .stopped(let processID, _):
            guard processID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .invalidObservedProcess,
                    requestID: parent.id
                )
            }
        case .noTarget, .detaching, .exited, .detached, .terminated, .invalidated:
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: parent.id
            )
        }
    }

    private func exactDetachPhysicalRequest(
        context: DebuggerRequestContext,
        command: String,
        observedPIDRequirement: LLDBCLIObservedPIDRequirement
    ) throws -> PersistentLLDBCLIRequest {
        try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [command],
            observedPIDRequirement: observedPIDRequirement,
            timeout: .seconds(5)
        )
    }

    private func validateExactDetachStagingResponse(
        _ response: PersistentLLDBCLIResponse,
        context: DebuggerRequestContext,
        adapterGeneration: UInt64,
        authority: DebuggerSessionTargetAuthority
    ) throws -> ExactDetachStagingResponseDisposition {
        guard response.requestID == context.id,
              response.generation == adapterGeneration else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }
        let transcript = response.transcript
        guard transcript.observedProcessID == authority.processID,
              let observed = transcript.observedProcessState,
              observed.processID == authority.processID else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
        switch observed {
        case .running, .stopped:
            guard exactDetachObservationMatchesReducer(observed, authority: authority) else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .invalidObservedProcess,
                    requestID: context.id
                )
            }
        case .exited(_, let status):
            return .targetExited(status: status)
        }
        let semanticByteCount = transcript.semanticCommandTranscripts.first?.utf8.count
        guard transcript.semanticCommandsSucceeded,
              transcript.firstFailedSemanticCommandIndex == nil,
              transcript.semanticCommandTranscripts.count == 1,
              transcript.semanticCommandResultLineByteCounts.count == 1,
              transcript.semanticCommandTranscripts[0].isEmpty,
              let semanticByteCount,
              transcript.semanticCommandResultLineByteCounts[0] >= semanticByteCount,
              transcript.semanticCommandResultLineByteCounts[0]
                <= LLDBCLITranscriptDecoder.maximumExchangeBytes,
              transcript.exchangeByteCount >= 0,
              transcript.exchangeByteCount <= LLDBCLITranscriptDecoder.maximumExchangeBytes else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: context.id
            )
        }
        return .targetStillLive
    }

    private func exactDetachObservationMatchesReducer(
        _ observation: LLDBCLIObservedProcessState,
        authority: DebuggerSessionTargetAuthority
    ) -> Bool {
        switch (reducer.state.processPhase, observation) {
        case let (.running(reducerPID), .running(observedPID)),
             let (.stopped(reducerPID, _), .stopped(observedPID)):
            reducerPID == authority.processID && observedPID == authority.processID
        case (.noTarget, _), (.detaching, _), (.exited, _), (.detached, _),
             (.terminated, _), (.invalidated, _), (.running, _), (.stopped, _):
            false
        }
    }

    private func handleExactDetachStagingFailure(
        _ failure: PersistentLLDBCLIAdapterFailure,
        context: DebuggerRequestContext,
        parent: DebuggerRequestContext,
        adapterGeneration: UInt64
    ) throws {
        guard failure.requestID == context.id,
              failure.generation == adapterGeneration else {
            try failBeforeWrite(
                parent,
                label: "Exact detach staging adapter correlation was lost before detach dispatch."
            )
            throw exactDetachPreFinalFailure(code: .adapterInvalidated)
        }
        switch failure.disposition {
        case .cancelledBeforeWrite:
            try emit(.requestCancelled(.cancelledBeforeWrite), for: parent)
            throw exactDetachPreFinalFailure(code: .adapterCancelled)
        case .failedBeforeWrite:
            try failBeforeWrite(
                parent,
                label: "Exact detach staging failed before final detach dispatch."
            )
            throw exactDetachPreFinalFailure(code: .adapterFailedBeforeWrite)
        case .invalidatedAfterWrite, .completed:
            try failBeforeWrite(
                parent,
                label: "Exact detach helper staging invalidated adapter authority before detach "
                    + "dispatch."
            )
            throw exactDetachPreFinalFailure(code: .adapterInvalidated)
        }
    }

    private func exactDetachPreFinalFailure(
        code: PersistentLLDBSessionCoordinatorFailureCode
    ) -> PersistentLLDBExactDetachPreFinalFailure {
        PersistentLLDBExactDetachPreFinalFailure(
            code: code,
            disposition: .retireAdapterAndReobserve,
            reducerState: reducer.state
        )
    }

    private func exactDetachFinalResponseDisposition(
        _ response: PersistentLLDBCLIResponse,
        context: DebuggerRequestContext,
        adapterGeneration: UInt64,
        authority: DebuggerSessionTargetAuthority
    ) throws -> ExactDetachFinalResponseDisposition {
        guard response.requestID == context.id,
              response.generation == adapterGeneration else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }
        switch (
            response.transcript.observedProcessID,
            response.transcript.observedProcessState
        ) {
        case (nil, nil):
            return .requiresDetachReceipt
        case let (.some(observedPID), .some(.exited(statePID, status))):
            guard observedPID == authority.processID,
                  statePID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .invalidObservedProcess,
                    requestID: context.id
                )
            }
            return .targetExited(status: status)
        case let (.some(observedPID), .some(.running(statePID))),
             let (.some(observedPID), .some(.stopped(statePID))):
            guard observedPID == authority.processID,
                  statePID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .invalidObservedProcess,
                    requestID: context.id
                )
            }
            return .requiresDetachReceipt
        case (.some, .none), (.none, .some):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
    }

    /// Reduces and seals an exact external exit against the already-admitted logical detach
    /// parent. Private callback and staging request IDs are never admitted and therefore can never
    /// become terminal lease-release authority.
    private func exactDetachTargetExitedOutcome(
        status: Int32?,
        attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        parent: DebuggerRequestContext
    ) async throws -> PersistentLLDBExactDetachTransactionOutcome {
        guard reducer.state.pendingRequest?.context == parent else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: parent.id
            )
        }
        if reducer.state.pendingRequest?.hasStarted == false {
            try markStarted(parent)
        }
        try emit(
            .processExited(
                observedPID: attachedSession.permit.authority.processID,
                exitCode: status
            ),
            for: parent
        )
        let executionResult = mintExecutionResult(
            requestID: parent.id,
            reducerState: reducer.state
        )
        let externalExit = try await sealExactAttachedExternalExitResult(
            attachedSession: attachedSession,
            executionResult: executionResult
        )
        return .targetExited(externalExit, reducer.state)
    }

    /// Executes one exact reducer-admitted logical-breakpoint plan over private fixed-offset
    /// requests. There is no generic parent request and no caller-authored command surface.
    func performLogicalBreakpointReconciliation(
        _ input: PersistentLLDBLogicalBreakpointReconciliationInput
    ) async throws -> PersistentLLDBLogicalBreakpointReconciliationResult {
        if logicalBreakpointCallbackDrainIsQuarantined {
            throw PersistentLLDBLogicalBreakpointCallbackDrainFailure(
                code: .admissionRejected,
                disposition: .terminateAndReap,
                reducerState: reducer.state
            )
        }
        try validateLogicalBreakpointInput(input)
        let reserved = try reserveLogicalBreakpointCapacity(input)

        if let authority = logicalBreakpointCallbackAuthority {
            do {
                let observedState = try await drainLogicalBreakpointCallbacksBeforeLifecycleAcceptance(
                    authority,
                    contexts: reserved.callbackDrain,
                    initialProcessState: .stopped(processID: authority.processID),
                    permitsInitialResumeTransition: false
                )
                guard observedState == .stopped(processID: authority.processID) else {
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .invalidObservedProcess
                    )
                }
                // Draining can tombstone a hit binding or fail closed. Recheck the caller's exact
                // plan only after the old token/wire ledger has reached its final acknowledgement.
                try validateLogicalBreakpointInput(input)
            } catch {
                logicalBreakpointCallbackDrainIsQuarantined = true
                throw PersistentLLDBLogicalBreakpointCallbackDrainFailure(
                    code: logicalBreakpointFailureCode(error),
                    disposition: .terminateAndReap,
                    reducerState: reducer.state
                )
            }
        }
        let contexts = reserved.transaction

        // Observation + plan admission is one value-semantic reducer transaction. Failure cannot
        // publish a newer observation while leaving its derived plan unadmitted.
        var candidate = reducer
        guard candidate.admitLogicalBreakpointReconciliation(
            observation: input.observation,
            plan: input.prepared.plan
        ) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        reducer = candidate

        var collector = LLDBLogicalBreakpointTransactionCollector(
            reservation: input.reservation
        )
        var validatedReceipt: DebuggerBreakpointBindingReceipt?
        do {
            try await prepareLogicalBreakpointHelper(input, contexts: contexts)

            let beginIndex = input.reservation.helperPreparationRequestCount
            let beginCommand = try input.prepared.beginCommand(token: input.token)
            let beginStep = try collector.dispatchNextStep()
            guard beginStep == .begin else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
            }
            let begun = try await executeLogicalBreakpointCommand(
                beginCommand,
                context: contexts[beginIndex],
                plan: input.prepared.plan
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                begun.transcript,
                expecting: .begin(token: input.token)
            )
            try collector.completeDispatchedStep()

            let uploadCommands = try input.prepared.uploadCommands(token: input.token)
            for (index, command) in uploadCommands.enumerated() {
                let step = try collector.dispatchNextStep()
                guard step == .upload(pageIndex: index) else {
                    throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
                }
                let response = try await executeLogicalBreakpointCommand(
                    command,
                    context: contexts[beginIndex + 1 + index],
                    plan: input.prepared.plan
                )
                _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                    response.transcript,
                    expecting: .upload(token: input.token, pageIndex: index)
                )
                try collector.completeDispatchedStep()
            }

            let applyIndex = beginIndex + 1 + uploadCommands.count
            let applyStep = try collector.dispatchNextStep()
            guard applyStep == .apply else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
            }
            let applyResponse = try await executeLogicalBreakpointCommand(
                try LLDBLogicalBreakpointProgram.current.applyCommand(token: input.token),
                context: contexts[applyIndex],
                plan: input.prepared.plan
            )
            let applied = try LLDBLogicalBreakpointResponseDecoder().decode(
                applyResponse.transcript,
                expecting: .apply(token: input.token)
            )
            try collector.completeDispatchedStep()
            var assembler = try LLDBLogicalBreakpointReceiptAssembler(
                prepared: input.prepared,
                token: input.token,
                appliedResponse: applied
            )

            let receiptBaseIndex = applyIndex + 1
            while !collector.hasCompleteReceiptBytes {
                guard case .receipt(let pageIndex, let cursor) = collector.nextStep else {
                    throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
                }
                let step = try collector.dispatchNextStep()
                guard step == .receipt(pageIndex: pageIndex, cursor: cursor) else {
                    throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
                }
                let response = try await executeLogicalBreakpointCommand(
                    try LLDBLogicalBreakpointProgram.current.receiptPageCommand(
                        token: input.token,
                        cursor: cursor
                    ),
                    context: contexts[receiptBaseIndex + pageIndex],
                    plan: input.prepared.plan
                )
                let page = try LLDBLogicalBreakpointResponseDecoder().decode(
                    response.transcript,
                    expecting: .receiptPage(token: input.token, cursor: cursor)
                )
                guard case .receiptPage(_, _, _, let isFinal, _, let payload) = page else {
                    throw PersistentLLDBSessionCoordinatorFailure(code: .responseProjectionFailed)
                }
                try collector.completeDispatchedStep(
                    .receiptPage(payloadByteCount: payload.count, isFinal: isFinal)
                )
                try assembler.append(page)
            }

            let receipt = try assembler.finish()
            validatedReceipt = receipt
            try collector.markCompleteReceiptValidated()
            try await completeLogicalBreakpointCleanup(
                input,
                contexts: contexts,
                collector: &collector
            )
            guard reducer.completeLogicalBreakpointBinding(receipt) else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .reducerRejected)
            }
            replaceLogicalBreakpointCallbackAuthority(after: receipt, input: input)
            return PersistentLLDBLogicalBreakpointReconciliationResult(
                receipt: receipt,
                reducerState: reducer.state
            )
        } catch {
            throw await finishLogicalBreakpointFailure(
                error,
                input: input,
                contexts: contexts,
                collector: &collector,
                validatedReceipt: validatedReceipt
            )
        }
    }

    /// Creates one exact private one-shot binding while the reducer remains at the admitted stop.
    /// The caller may admit the resume-capable `.runToCursor` operation only after this returns a
    /// validated receipt. Any failure after apply is conservatively recovered by the controller's
    /// existing correlated terminate/reap path.
    func createRunToCursorBinding(
        _ input: PersistentLLDBRunToCursorCreationInput
    ) async throws -> PersistentLLDBRunToCursorCreationResult {
        let contexts: [DebuggerRequestContext]
        do {
            try validateRunToCursorCreationInput(input)
            contexts = try reserveRunToCursorCreationCapacity(input)
        } catch {
            throw PersistentLLDBRunToCursorCreationFailure(
                code: logicalBreakpointFailureCode(error),
                targetRecoveryRequired: false
            )
        }
        let program = LLDBLogicalBreakpointProgram.current
        let decoder = LLDBLogicalBreakpointResponseDecoder()
        var beginDispatched = false
        var backendMutationPossible = false
        var scratchCleanupDispatched = false
        var scratchCleanupProven = false
        do {
            try await prepareRunToCursorHelper(input, contexts: contexts)
            let base = input.reservation.helperPreparationRequestCount
            beginDispatched = true
            let begun = try await executeRunToCursorCommand(
                try program.beginCommand(
                    token: input.token,
                    adapterGeneration: input.prepared.adapterGeneration,
                    expectedProcessID: input.prepared.observedPID,
                    expectedStopID: input.prepared.observedStopID,
                    pageCount: input.prepared.pages.count,
                    planByteCount: input.prepared.canonicalPlanBytes.count,
                    planSHA256: input.prepared.canonicalPlanDigest.bytes
                ),
                context: contexts[base],
                prepared: input.prepared
            )
            _ = try decoder.decode(begun.transcript, expecting: .begin(token: input.token))

            for page in input.prepared.pages {
                let response = try await executeRunToCursorCommand(
                    try program.uploadPageCommand(
                        token: input.token,
                        pageIndex: page.index,
                        pageCount: input.prepared.pages.count,
                        payloadBase64: page.payloadBase64,
                        payloadSHA256: page.payloadSHA256
                    ),
                    context: contexts[base + 1 + page.index],
                    prepared: input.prepared
                )
                _ = try decoder.decode(
                    response.transcript,
                    expecting: .upload(token: input.token, pageIndex: page.index)
                )
            }

            let applyIndex = base + 1 + input.prepared.pages.count
            // Once apply is dispatched, an error can no longer prove the backend was untouched.
            backendMutationPossible = true
            let appliedResponse = try await executeRunToCursorCommand(
                try program.applyCommand(token: input.token),
                context: contexts[applyIndex],
                prepared: input.prepared
            )
            guard case .applied(_, let locationCount, let expectedReceiptDigest) = try decoder.decode(
                appliedResponse.transcript,
                expecting: .apply(token: input.token)
            ), locationCount == 1 else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .responseProjectionFailed)
            }

            var receiptBytes = Data()
            var cursor = 0
            var receiptPage = 0
            while true {
                guard receiptPage < input.reservation.receiptPageCountUpperBound else {
                    throw PersistentLLDBSessionCoordinatorFailure(code: .responseProjectionFailed)
                }
                let response = try await executeRunToCursorCommand(
                    try program.receiptPageCommand(token: input.token, cursor: cursor),
                    context: contexts[applyIndex + 1 + receiptPage],
                    prepared: input.prepared
                )
                guard case .receiptPage(
                    _, let receivedCursor, let nextCursor, let isFinal,
                    let receiptDigest, let payload
                ) = try decoder.decode(
                    response.transcript,
                    expecting: .receiptPage(token: input.token, cursor: cursor)
                ), receivedCursor == cursor,
                   receiptDigest == expectedReceiptDigest,
                   nextCursor == cursor + payload.count,
                   receiptBytes.count + payload.count
                    <= input.prepared.receiptByteCountUpperBound else {
                    throw PersistentLLDBSessionCoordinatorFailure(code: .responseProjectionFailed)
                }
                receiptBytes.append(payload)
                cursor = nextCursor
                receiptPage += 1
                if isFinal { break }
            }
            guard Data(SHA256.hash(data: receiptBytes)) == expectedReceiptDigest else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .responseProjectionFailed)
            }
            let receipt = try LLDBRunToCursorTransactionCodec().decodeReceipt(
                receiptBytes,
                for: input.prepared
            )
            scratchCleanupDispatched = true
            let cleanup = try await executeRunToCursorCommand(
                try program.cleanupCommand(token: input.token),
                context: contexts[input.reservation.cleanupPhysicalRequestOffset],
                prepared: input.prepared
            )
            _ = try decoder.decode(cleanup.transcript, expecting: .cleanup(token: input.token))
            scratchCleanupProven = true
            return PersistentLLDBRunToCursorCreationResult(
                receipt: receipt,
                reducerState: reducer.state
            )
        } catch {
            if beginDispatched && !scratchCleanupDispatched {
                let cleanupIndex = input.reservation.cleanupPhysicalRequestOffset
                scratchCleanupDispatched = true
                if let cleanup = try? await executeRunToCursorCommand(
                    try program.cleanupCommand(token: input.token),
                    context: contexts[cleanupIndex],
                    prepared: input.prepared
                ), (try? decoder.decode(
                    cleanup.transcript,
                    expecting: .cleanup(token: input.token)
                )) != nil {
                    scratchCleanupProven = true
                }
            }
            throw PersistentLLDBRunToCursorCreationFailure(
                code: logicalBreakpointFailureCode(error),
                targetRecoveryRequired: backendMutationPossible
                    || (beginDispatched && !scratchCleanupProven)
            )
        }
    }

    /// At the first later stop, prove the exact private one-shot is already absent or delete only
    /// its still-owned backend ID. This never publishes a logical-breakpoint inventory mutation.
    func cleanupRunToCursorBinding(
        _ input: PersistentLLDBRunToCursorCleanupInput
    ) async throws -> DebuggerReducerState {
        let state = reducer.state
        guard input.token.count == 32,
              input.ownerDigest.bytes.count == 32,
              !state.isInvalidated,
              state.pendingRequest == nil,
              case .stopped(let processID, _) = state.processPhase,
              processID == input.receipt.observedPID,
              state.observedProcessID == processID,
              state.stopCoordinate != nil,
              let backendID = Int(exactly: input.receipt.backendBreakpointID),
              let locationID = Int(exactly: input.receipt.backendLocationID) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        let next = lastRequestSequence.addingReportingOverflow(1)
        guard !next.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        lastRequestSequence = next.partialValue
        let context = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: next.partialValue),
            operation: .runToCursor,
            expectedSession: state.sessionCoordinate,
            requiredStop: state.stopCoordinate,
            targetAuthority: Self.sessionScopedTargetAuthority(
                for: .runToCursor,
                reducerState: state
            )
        )
        let request = try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [try LLDBLogicalBreakpointProgram.current
                .privateBreakpointCleanupCommand(
                    token: input.token,
                    adapterGeneration: input.receipt.adapterGeneration,
                    expectedProcessID: input.receipt.observedPID,
                    backendBreakpointID: backendID,
                    backendLocationID: locationID,
                    ownerTagDigest: input.ownerDigest.bytes,
                    nameSHA256: input.receipt.nameOwnerDigest.bytes,
                    runtimeAddress: input.receipt.runtimeAddress
                )],
            observedPIDRequirement: .required,
            timeout: .seconds(10)
        )
        let response = try await executor.executeCoordinatorSelected(request)
        guard response.requestID == context.id,
              response.generation == input.receipt.adapterGeneration,
              response.transcript.observedProcessID == processID,
              response.transcript.observedProcessState == .stopped(processID: processID) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .responseCorrelationMismatch)
        }
        _ = try LLDBLogicalBreakpointResponseDecoder().decode(
            response.transcript,
            expecting: .privateCleanup(
                token: input.token,
                backendBreakpointID: backendID,
                backendLocationID: locationID,
                ownerTagDigest: input.ownerDigest.bytes,
                nameSHA256: input.receipt.nameOwnerDigest.bytes,
                runtimeAddress: input.receipt.runtimeAddress
            )
        )
        let final = reducer.state
        guard final.stopCoordinate == state.stopCoordinate,
              final.observedProcessID == processID,
              final.pendingRequest == nil else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        return final
    }

    /// Fail-closed terminal used only after a typed side-effecting command may have partially
    /// mutated backend state and a correlated recovery kill could not prove target exit.
    func invalidateAfterUnrecoverablePartialMutation(
        operation: DebuggerOperation
    ) throws -> DebuggerReducerState {
        let diagnostic = DebuggerDiagnostic.make(
            code: .protocolViolation,
            severity: .error,
            rawText: "LLDB could not prove recovery from a partial debugger mutation.",
            operation: operation,
            targetDisposition: .unknown
        )
        guard let sequence = lastEventSequence.incremented() else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        lastEventSequence = sequence
        let envelope = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: sequence,
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: reducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .sessionInvalidated(diagnostic)
        )
        switch reducer.reduce(envelope) {
        case .accepted:
            logicalBreakpointCallbackAuthority = nil
            logicalBreakpointCallbackDrainIsQuarantined = false
            return reducer.state
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .reducerRejected,
                reducerRejection: rejection
            )
        }
    }

    /// Prepares and admits one typed operation against caller-supplied exact coordinates before
    /// request rendering or adapter execution. Reducer rejection therefore guarantees zero
    /// request-preparer and adapter calls.
    func perform(
        _ operation: DebuggerOperation,
        expectedSession: DebuggerSessionCoordinate,
        requiredStop: DebuggerStopCoordinate?,
        variableExpansionRequest: DebuggerVariableExpansionRequest? = nil
    ) async throws -> PersistentLLDBSessionExecutionResult {
        // A user pause is allowed to wait behind the one already-written, short status poll. It
        // never cancels that poll. When the poll reports a transition, the caller's exact session
        // coordinate becomes stale and ordinary reducer admission prevents an obsolete interrupt.
        if operation == .pause, activePollRequestID != nil {
            await waitForActivePoll()
            if Task.isCancelled {
                throw PersistentLLDBSessionCoordinatorFailure(code: .adapterCancelled)
            }
        }

        let reserved = try reserveOperationContexts(
            operation: operation,
            expectedSession: expectedSession,
            requiredStop: requiredStop,
            variableExpansionRequest: variableExpansionRequest
        )
        let context = reserved.parent
        var ownsActivePoll = false
        defer {
            if ownsActivePoll {
                finishActivePoll(context.id)
            }
        }

        switch reducer.admit(context) {
        case .accepted:
            break
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: context.id,
                reducerRejection: rejection
            )
        }

        if operation == .pollProcessStatus {
            precondition(activePollRequestID == nil, "Reducer admission must serialize status polls.")
            activePollRequestID = context.id
            ownsActivePoll = true
        }

        let request: PersistentLLDBCLIRequest
        do {
            request = try await requestPreparer.prepareRequest(for: context)
        } catch is CancellationError {
            try emit(.requestCancelled(.cancelledBeforeWrite), for: context)
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterCancelled,
                requestID: context.id
            )
        } catch {
            try failBeforeWrite(context, label: "Debugger request preparation failed.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestPreparationFailed,
                requestID: context.id
            )
        }

        guard request.context == context else {
            try failBeforeWrite(context, label: "Prepared debugger request did not match admission.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .preparedRequestMismatch,
                requestID: context.id
            )
        }

        do {
            let response = try await executor.executeCoordinatorSelected(request)
            return try await accept(
                response,
                for: context,
                callbackDrainContexts: reserved.callbackDrain
            )
        } catch let failure as PersistentLLDBLogicalBreakpointCallbackDrainFailure {
            throw failure
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            throw failure
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            try handleAdapterFailure(failure, for: context, deadline: request.timeout)
        } catch {
            let cause = PersistentLLDBAdapterInvalidationCause.unboundedDisposition
            try invalidate(
                context,
                label: "Persistent LLDB execution failed (\(cause.summary))."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: context.id,
                invalidationCause: cause
            )
        }

        preconditionFailure("Adapter failure handling always throws.")
    }

    /// Seals only the coordinator's current exact attached external-exit result. The executor
    /// binding is re-read before the actor-local state check so actor reentrancy cannot turn a
    /// stale execution result into terminal evidence.
    func sealExactAttachedExternalExitResult(
        attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        executionResult: PersistentLLDBSessionExecutionResult
    ) async throws -> PersistentLLDBExactAttachedExternalExitResult {
        guard let adapterInstanceBinding = await executor.exactAdapterInstanceBinding() else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }

        let state = reducer.state
        guard let sealAuthority = currentExecutionSealAuthority,
              executionResult.wasMinted(with: sealAuthority),
              attachedSession.hasValidBinding(),
              attachedSession.adapterInstanceBinding == adapterInstanceBinding,
              attachedSession.adapterInstanceBinding.digest.count == 32,
              attachedSession.establishedSession.epoch == epoch,
              attachedSession.establishedSession.lifecycleRevision < state.lifecycleRevision,
              executionResult.requestID.epoch == epoch,
              executionResult.requestID.sequence > 0,
              executionResult.requestID.sequence == state.lastAdmittedRequestSequence,
              executionResult.reducerState == state,
              state.epoch == epoch,
              state.pendingRequest == nil,
              state.isInvalidated,
              state.stopRevision == nil,
              state.acceptedTargetAuthority == attachedSession.permit.authority,
              state.observedProcessID == attachedSession.permit.authority.processID,
              case .attached = attachedSession.permit.authority.origin,
              case .exited(let processID, let exitStatus) = state.processPhase,
              processID == attachedSession.permit.authority.processID,
              state.targetDisposition == .exited(code: exitStatus) else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: executionResult.requestID
            )
        }

        currentExecutionSealAuthority = nil
        return PersistentLLDBExactAttachedExternalExitResult(
            attachedSession: attachedSession,
            adapterInstanceBindingDigest: adapterInstanceBinding.digest,
            requestID: executionResult.requestID,
            terminalLifecycleRevision: state.lifecycleRevision,
            processID: processID,
            exitStatus: exitStatus
        )
    }

    /// Performs one logical exact-stop runtime-module refresh over multiple private physical
    /// adapter exchanges. The complete parent plus physical range is checked and reserved before
    /// reducer admission, and no internal context is ever admitted to or published by the reducer.
    func performRuntimeModuleRefresh(
        expectedSession: DebuggerSessionCoordinate,
        requiredStop: DebuggerStopCoordinate,
        collect: @escaping @Sendable (
            PersistentLLDBRuntimeModuleExchangeChannel
        ) async throws -> PersistentLLDBRuntimeModuleRefreshCollection
    ) async throws -> PersistentLLDBSessionExecutionResult {
        try reserveRuntimeModuleRefreshEventBudget()
        let reservation = try reserveRuntimeModuleRefreshContexts(
            expectedSession: expectedSession,
            requiredStop: requiredStop
        )
        let parent = reservation.parent

        switch reducer.admit(parent) {
        case .accepted:
            break
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .admissionRejected,
                requestID: parent.id,
                reducerRejection: rejection
            )
        }

        guard case .stopped(let processID, _) = reducer.state.processPhase,
              processID > 0,
              reducer.state.observedProcessID == processID else {
            try invalidate(parent, label: "Runtime-module refresh lacked exact stopped-process authority.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: parent.id
            )
        }
        let admittedAuthorityRevision = reducer.state.runtimeModuleInventoryState.authorityRevision

        let exchanges = PersistentLLDBRuntimeModuleReservedExchange(
            parent: parent,
            regularContexts: Array(reservation.physical.dropLast()),
            cleanupContext: reservation.physical[reservation.physical.index(before: reservation.physical.endIndex)],
            expectedProcessID: processID,
            executor: executor,
            validateAuthority: { [weak self] in
                guard let self else {
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .adapterInvalidated,
                        requestID: parent.id
                    )
                }
                try await self.validateRuntimeModuleRefreshAuthority(
                    parent,
                    processID: processID,
                    authorityRevision: admittedAuthorityRevision
                )
            },
            markParentStarted: { [weak self] in
                guard let self else {
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .adapterInvalidated,
                        requestID: parent.id
                    )
                }
                try await self.markRuntimeModuleRefreshStarted(parent)
            }
        )
        let channel = PersistentLLDBRuntimeModuleExchangeChannel(
            parentContext: parent,
            internalContexts: reservation.physical,
            execute: { request in
                try await exchanges.execute(request)
            },
            cleanup: { request, validator in
                try await exchanges.cleanup(request, validate: validator)
            }
        )

        let collection: PersistentLLDBRuntimeModuleRefreshCollection
        do {
            collection = try await collect(channel)
        } catch {
            let status = await exchanges.status
            let collectorRequiresInvalidation =
                (error as? DebuggerRuntimeModuleInventoryCollectorFailure)?
                    .requiresAdapterInvalidation == true
            if status.requiresInvalidation {
                try invalidate(
                    parent,
                    label: "Runtime-module refresh could not prove private snapshot cleanup."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: parent.id
                )
            }
            if !status.didAttemptPhysicalExchange || !status.mayHaveWritten {
                try failBeforeWrite(
                    parent,
                    label: "Runtime-module collection failed before any physical write."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .responseProjectionFailed,
                    requestID: parent.id
                )
            }
            if collectorRequiresInvalidation {
                try invalidate(
                    parent,
                    label: "Runtime-module refresh could not prove private snapshot cleanup."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: parent.id
                )
            }
            guard status.cleanupProven else {
                try invalidate(
                    parent,
                    label: "Runtime-module refresh could not prove private snapshot cleanup."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: parent.id
                )
            }
            try failBeforeWrite(parent, label: "Runtime-module collection failed within bounded cleanup.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: parent.id
            )
        }

        let exchangeStatus = await exchanges.status
        guard exchangeStatus.cleanupProven, !exchangeStatus.requiresInvalidation else {
            try invalidate(parent, label: "Runtime-module refresh returned without proven cleanup.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: parent.id
            )
        }

        do {
            try validateRuntimeModuleRefreshAuthority(
                parent,
                processID: processID,
                authorityRevision: admittedAuthorityRevision
            )
        } catch {
            try invalidate(parent, label: "Runtime-module refresh lost exact stopped authority.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: parent.id
            )
        }

        guard collection.observedPID == processID,
              collection.adapterGeneration > 0,
              collection.observations.allSatisfy({ observation in
                  observation.processID == collection.observedPID
                      && observation.observedStopID == collection.observedStopID
              }) else {
            try failBeforeWrite(parent, label: "Runtime-module collection did not form one coherent inventory.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: parent.id
            )
        }

        try emit(
            .runtimeModulesRefreshed(
                DebuggerRuntimeModulesRefreshPayload(
                    observations: collection.observations,
                    observedStopID: collection.observedStopID,
                    processID: collection.observedPID,
                    adapterGeneration: collection.adapterGeneration
                )
            ),
            for: parent
        )
        try emit(
            .requestCompleted(.completed(target: reducer.state.targetDisposition)),
            for: parent
        )
        return mintExecutionResult(requestID: parent.id, reducerState: reducer.state)
    }

    /// A logical refresh can publish at most request-started, one atomic inventory, and one
    /// completion. Check the complete capacity before reducer admission or physical I/O. The
    /// reducer's single pending-parent rule makes this capacity exclusive to the admitted refresh.
    private func reserveRuntimeModuleRefreshEventBudget() throws {
        let (_, overflowed) = lastEventSequence.rawValue.addingReportingOverflow(
            Self.runtimeModuleParentEventBudget
        )
        guard !overflowed else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
    }

    /// Production convenience that adapts the fixed D1 collector to the coordinator-owned
    /// physical exchange channel. The collector can validate program generation and receipts, but
    /// cannot bypass coordinator correlation or exact-authority checks.
    func performRuntimeModuleRefresh(
        expectedSession: DebuggerSessionCoordinate,
        requiredStop: DebuggerStopCoordinate,
        adapterGeneration: UInt64,
        token: Data,
        collector: DebuggerRuntimeModuleInventoryCollector
    ) async throws -> PersistentLLDBSessionExecutionResult {
        try await performRuntimeModuleRefresh(
            expectedSession: expectedSession,
            requiredStop: requiredStop
        ) { channel in
            guard case .stopped(let processID, _) = await self.reducerState.processPhase else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .invalidObservedProcess)
            }
            let collectorExecutor = PersistentLLDBRuntimeModuleCollectorExecutor(
                channel: channel
            )
            let decoded = try await collector.collect(
                plan: DebuggerRuntimeModuleInventoryCollectionPlan(
                    parentContext: channel.parentContext,
                    internalContexts: channel.internalContexts,
                    adapterGeneration: adapterGeneration,
                    expectedProcessID: processID,
                    token: token
                ),
                executor: collectorExecutor
            )
            return PersistentLLDBRuntimeModuleRefreshCollection(
                observations: decoded.modules,
                observedPID: decoded.observedProcessID,
                observedStopID: decoded.observedStopID,
                adapterGeneration: adapterGeneration
            )
        }
    }

    private func reserveRuntimeModuleRefreshContexts(
        expectedSession: DebuggerSessionCoordinate,
        requiredStop: DebuggerStopCoordinate
    ) throws -> (parent: DebuggerRequestContext, physical: [DebuggerRequestContext]) {
        let targetAuthority = Self.sessionScopedTargetAuthority(
            for: .refreshRuntimeModules,
            reducerState: reducer.state
        )
        let completeReservationCount = UInt64(Self.runtimeModulePhysicalContextCount + 1)
        let (reservedEnd, overflowed) = lastRequestSequence.addingReportingOverflow(
            completeReservationCount
        )
        guard !overflowed else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }

        let parentSequence = lastRequestSequence + 1
        let parent = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: parentSequence),
            operation: .refreshRuntimeModules,
            expectedSession: expectedSession,
            requiredStop: requiredStop,
            targetAuthority: targetAuthority
        )
        let physical = (0..<Self.runtimeModulePhysicalContextCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(
                    epoch: epoch,
                    sequence: parentSequence + UInt64(offset) + 1
                ),
                operation: .refreshRuntimeModules,
                expectedSession: expectedSession,
                requiredStop: requiredStop,
                targetAuthority: targetAuthority
            )
        }
        lastRequestSequence = reservedEnd
        return (parent, physical)
    }

    private func validateRuntimeModuleRefreshAuthority(
        _ parent: DebuggerRequestContext,
        processID: Int32,
        authorityRevision: DebuggerRuntimeModuleAuthorityRevision
    ) throws {
        let state = reducer.state
        let runtime = state.runtimeModuleInventoryState
        guard case .stopped(let authoritativeProcessID, _) = state.processPhase,
              authoritativeProcessID == processID,
              !state.isInvalidated,
              state.pendingRequest?.context == parent,
              state.sessionCoordinate == parent.expectedSession,
              state.stopCoordinate == parent.requiredStop,
              state.observedProcessID == processID,
              runtime.session == parent.expectedSession,
              runtime.processID == processID,
              runtime.currentStop == parent.requiredStop,
              runtime.authorityRevision == authorityRevision,
              runtime.authority == .unavailable(.refreshInProgress),
              !runtime.isSessionInvalidated else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: parent.id
            )
        }
    }

    private func markRuntimeModuleRefreshStarted(
        _ parent: DebuggerRequestContext
    ) throws {
        try validatePendingRuntimeModuleRefresh(parent)
        if reducer.state.pendingRequest?.hasStarted == false {
            try emit(.requestStarted, for: parent)
        }
    }

    private func validatePendingRuntimeModuleRefresh(
        _ parent: DebuggerRequestContext
    ) throws {
        guard reducer.state.pendingRequest?.context == parent,
              !reducer.state.isInvalidated else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: parent.id
            )
        }
    }

    private func validateLogicalBreakpointInput(
        _ input: PersistentLLDBLogicalBreakpointReconciliationInput
    ) throws {
        let plan = input.prepared.plan
        guard input.token.count == 32,
              input.observation.logicalCatalogCoordinate == plan.logicalCatalogCoordinate,
              input.observation.resolutionCatalogCoordinate == plan.resolutionCatalogCoordinate,
              input.observation.mappingKey == plan.mappingKey,
              input.observation.canonicalDigest == plan.resolutionObservationDigest,
              input.reservation.planPageCount == input.prepared.pages.count,
              input.reservation.receiptByteCountUpperBound
                == input.prepared.receiptByteCountUpperBound else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
        }
    }

    private func validateRunToCursorCreationInput(
        _ input: PersistentLLDBRunToCursorCreationInput
    ) throws {
        let prepared = input.prepared
        let state = reducer.state
        guard input.token.count == 32,
              input.reservation.planPageCount == prepared.pages.count,
              input.reservation.receiptByteCountUpperBound
                == prepared.receiptByteCountUpperBound,
              !state.isInvalidated,
              state.pendingRequest == nil,
              case .stopped(let processID, _) = state.processPhase,
              processID == prepared.observedPID,
              state.observedProcessID == processID,
              state.stopCoordinate == prepared.resolvedAddress.projectionKey.stopCoordinate,
              state.runtimeModuleInventoryState.authorityRevision
                == prepared.resolvedAddress.projectionKey.authorityRevision,
              case .available(let inventory) = state.runtimeModuleInventoryState.authority,
              inventory.stop == prepared.resolvedAddress.projectionKey.stopCoordinate,
              inventory.processID == processID,
              inventory.observedStopID == prepared.observedStopID,
              inventory.revision == prepared.resolvedAddress.projectionKey.inventoryRevision,
              inventory.modules.contains(where: {
                  $0.id == prepared.resolvedAddress.moduleInstanceID
              }) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
    }

    private func reserveRunToCursorCreationCapacity(
        _ input: PersistentLLDBRunToCursorCreationInput
    ) throws -> [DebuggerRequestContext] {
        guard let requestCount = UInt64(exactly: input.reservation.physicalRequestCount),
              !requestCount.addingReportingOverflow(
                Self.logicalBreakpointRecoveryRequestCapacity + 2
              ).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let end = lastRequestSequence.addingReportingOverflow(requestCount)
        let recoveryCapacityEnd = lastRequestSequence.addingReportingOverflow(
            requestCount + Self.logicalBreakpointRecoveryRequestCapacity + 2
        )
        guard !end.overflow, !recoveryCapacityEnd.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let eventCapacity = lastEventSequence.rawValue.addingReportingOverflow(
            Self.logicalBreakpointRecoveryEventCapacity + 1
        )
        guard !eventCapacity.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        let first = lastRequestSequence + 1
        let stop = input.prepared.resolvedAddress.projectionKey.stopCoordinate
        let targetAuthority = Self.sessionScopedTargetAuthority(
            for: .runToCursor,
            reducerState: reducer.state
        )
        let contexts = (0..<input.reservation.physicalRequestCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: first + UInt64(offset)),
                operation: .runToCursor,
                expectedSession: stop.session,
                requiredStop: stop,
                targetAuthority: targetAuthority
            )
        }
        // Consume only helper-transaction IDs. The controller operation gate preserves the
        // preflighted contiguous headroom for resume, exact private cleanup, and failure recovery.
        lastRequestSequence = end.partialValue
        return contexts
    }

    private func prepareRunToCursorHelper(
        _ input: PersistentLLDBRunToCursorCreationInput,
        contexts: [DebuggerRequestContext]
    ) async throws {
        let program = LLDBLogicalBreakpointProgram.current
        switch input.reservation.helperPreparation {
        case .alreadyProvenForGeneration:
            return
        case .proveOnly:
            let response = try await executeRunToCursorCommand(
                program.installedProofCommand,
                context: contexts[0],
                prepared: input.prepared
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                response.transcript,
                expecting: .install(sourceSHA256: program.sourceSHA256)
            )
        case .proveInstallAndReprove:
            do {
                let response = try await executeRunToCursorCommand(
                    program.installedProofCommand,
                    context: contexts[0],
                    prepared: input.prepared
                )
                _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                    response.transcript,
                    expecting: .install(sourceSHA256: program.sourceSHA256)
                )
                return
            } catch LLDBLogicalBreakpointResponseError.semanticCommandFailed {
                // The exact retained generation lacks this frozen helper; use the fully reserved
                // install/chunk/finalize/reproof path before any private breakpoint mutation.
            }
            for (index, command) in program.installChunkCommands.enumerated() {
                let response = try await executeRunToCursorCommand(
                    command,
                    context: contexts[index + 1],
                    prepared: input.prepared
                )
                guard response.transcript.semanticCommandsSucceeded,
                      response.transcript.firstFailedSemanticCommandIndex == nil else {
                    throw LLDBLogicalBreakpointResponseError.semanticCommandFailed
                }
            }
            let finalizeIndex = program.installChunkCommands.count + 1
            let finalized = try await executeRunToCursorCommand(
                program.installFinalizeCommand,
                context: contexts[finalizeIndex],
                prepared: input.prepared
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                finalized.transcript,
                expecting: .install(sourceSHA256: program.sourceSHA256)
            )
            let reproved = try await executeRunToCursorCommand(
                program.installedProofCommand,
                context: contexts[finalizeIndex + 1],
                prepared: input.prepared
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                reproved.transcript,
                expecting: .install(sourceSHA256: program.sourceSHA256)
            )
        }
    }

    private func executeRunToCursorCommand(
        _ command: String,
        context: DebuggerRequestContext,
        prepared: LLDBRunToCursorPreparedTransaction
    ) async throws -> PersistentLLDBCLIResponse {
        try validateRunToCursorAuthority(prepared)
        let request = try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [command],
            observedPIDRequirement: .required,
            timeout: .seconds(10)
        )
        let response = try await executor.executeCoordinatorSelected(request)
        guard response.requestID == context.id else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }
        guard response.generation == prepared.adapterGeneration,
              response.transcript.observedProcessID == prepared.observedPID,
              response.transcript.observedProcessState == .stopped(
                processID: prepared.observedPID
              ) else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
        try validateRunToCursorAuthority(prepared)
        return response
    }

    private func validateRunToCursorAuthority(
        _ prepared: LLDBRunToCursorPreparedTransaction
    ) throws {
        let state = reducer.state
        let key = prepared.resolvedAddress.projectionKey
        guard !state.isInvalidated,
              state.pendingRequest == nil,
              state.stopCoordinate == key.stopCoordinate,
              state.observedProcessID == prepared.observedPID,
              state.runtimeModuleInventoryState.authorityRevision == key.authorityRevision,
              case .available(let inventory) = state.runtimeModuleInventoryState.authority,
              inventory.stop == key.stopCoordinate,
              inventory.processID == prepared.observedPID,
              inventory.observedStopID == prepared.observedStopID,
              inventory.revision == key.inventoryRevision,
              inventory.modules.contains(where: {
                  $0.id == prepared.resolvedAddress.moduleInstanceID
              }) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
    }

    private func reserveLogicalBreakpointCapacity(
        _ input: PersistentLLDBLogicalBreakpointReconciliationInput
    ) throws -> ReservedLogicalBreakpointContexts {
        let callbackCount = logicalBreakpointCallbackAuthority == nil
            ? 0
            : Self.logicalBreakpointCallbackDrainPageCapacity
        guard let transactionEventCount = UInt64(exactly: input.reservation.eventSequenceCount),
              let callbackEventCount = UInt64(exactly: callbackCount),
              !transactionEventCount.addingReportingOverflow(
                callbackEventCount + Self.logicalBreakpointRecoveryEventCapacity
              ).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        let totalEventCount = callbackEventCount + transactionEventCount
            + Self.logicalBreakpointRecoveryEventCapacity
        guard !lastEventSequence.rawValue.addingReportingOverflow(totalEventCount).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        guard let transactionRequestCount = UInt64(
            exactly: input.reservation.physicalRequestCount
        ), let callbackRequestCount = UInt64(exactly: callbackCount),
              !transactionRequestCount.addingReportingOverflow(
                callbackRequestCount + Self.logicalBreakpointRecoveryRequestCapacity
              ).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let completeRequestCount = callbackRequestCount + transactionRequestCount
        let physicalEnd = lastRequestSequence.addingReportingOverflow(completeRequestCount)
        let recoveryCapacityEnd = lastRequestSequence.addingReportingOverflow(
            completeRequestCount + Self.logicalBreakpointRecoveryRequestCapacity
        )
        guard !physicalEnd.overflow, !recoveryCapacityEnd.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let first = lastRequestSequence + 1
        let plan = input.prepared.plan
        let targetAuthority = Self.sessionScopedTargetAuthority(
            for: .reconcileLogicalBreakpoints,
            reducerState: reducer.state
        )
        let callbackContexts = (0..<callbackCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: first + UInt64(offset)),
                operation: .reconcileLogicalBreakpoints,
                expectedSession: plan.stopCoordinate.session,
                requiredStop: plan.stopCoordinate,
                targetAuthority: targetAuthority
            )
        }
        let transactionFirst = first + UInt64(callbackCount)
        let transactionContexts = (0..<input.reservation.physicalRequestCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(
                    epoch: epoch,
                    sequence: transactionFirst + UInt64(offset)
                ),
                operation: .reconcileLogicalBreakpoints,
                expectedSession: plan.stopCoordinate.session,
                requiredStop: plan.stopCoordinate,
                targetAuthority: targetAuthority
            )
        }
        // Only the physical transaction range is consumed now. The controller operation gate
        // excludes intervening requests, so the proven recovery headroom remains contiguous for
        // the generic terminate/poll path if it becomes necessary.
        lastRequestSequence = physicalEnd.partialValue
        return ReservedLogicalBreakpointContexts(
            callbackDrain: callbackContexts,
            transaction: transactionContexts
        )
    }

    private func prepareLogicalBreakpointHelper(
        _ input: PersistentLLDBLogicalBreakpointReconciliationInput,
        contexts: [DebuggerRequestContext]
    ) async throws {
        let program = LLDBLogicalBreakpointProgram.current
        switch input.reservation.helperPreparation {
        case .alreadyProvenForGeneration:
            return
        case .proveOnly:
            let response = try await executeLogicalBreakpointCommand(
                program.installedProofCommand,
                context: contexts[0],
                plan: input.prepared.plan
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                response.transcript,
                expecting: .install(sourceSHA256: program.sourceSHA256)
            )
        case .proveInstallAndReprove:
            do {
                let proof = try await executeLogicalBreakpointCommand(
                    program.installedProofCommand,
                    context: contexts[0],
                    plan: input.prepared.plan
                )
                _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                    proof.transcript,
                    expecting: .install(sourceSHA256: program.sourceSHA256)
                )
                return
            } catch LLDBLogicalBreakpointResponseError.semanticCommandFailed {
                // The proof established that this adapter generation does not yet own the
                // frozen helper. Continue through the fully reserved install and reproof path.
            }
            for (index, command) in program.installChunkCommands.enumerated() {
                let response = try await executeLogicalBreakpointCommand(
                    command,
                    context: contexts[index + 1],
                    plan: input.prepared.plan
                )
                guard response.transcript.semanticCommandsSucceeded,
                      response.transcript.firstFailedSemanticCommandIndex == nil else {
                    throw LLDBLogicalBreakpointResponseError.semanticCommandFailed
                }
            }
            let finalizeIndex = program.installChunkCommands.count + 1
            let finalized = try await executeLogicalBreakpointCommand(
                program.installFinalizeCommand,
                context: contexts[finalizeIndex],
                plan: input.prepared.plan
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                finalized.transcript,
                expecting: .install(sourceSHA256: program.sourceSHA256)
            )
            let reproved = try await executeLogicalBreakpointCommand(
                program.installedProofCommand,
                context: contexts[finalizeIndex + 1],
                plan: input.prepared.plan
            )
            _ = try LLDBLogicalBreakpointResponseDecoder().decode(
                reproved.transcript,
                expecting: .install(sourceSHA256: program.sourceSHA256)
            )
        }
    }

    private func executeLogicalBreakpointCommand(
        _ command: String,
        context: DebuggerRequestContext,
        plan: DebuggerBreakpointBindingPlan
    ) async throws -> PersistentLLDBCLIResponse {
        try validateLogicalBreakpointAuthority(plan)
        let request = try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [command],
            observedPIDRequirement: .required,
            timeout: .seconds(10)
        )
        let response = try await executor.executeCoordinatorSelected(request)
        guard response.requestID == context.id else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }
        guard response.generation == plan.adapterGeneration,
              response.transcript.observedProcessID == plan.observedPID,
              response.transcript.observedProcessState == .stopped(
                processID: plan.observedPID
              ) else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
        try validateLogicalBreakpointAuthority(plan)
        return response
    }

    private func validateLogicalBreakpointAuthority(
        _ plan: DebuggerBreakpointBindingPlan
    ) throws {
        let state = reducer.state
        guard !state.isInvalidated,
              state.stopCoordinate == plan.stopCoordinate,
              state.observedProcessID == plan.observedPID,
              state.breakpointBindingState.adapterGeneration == plan.adapterGeneration,
              state.breakpointBindingState.observedStopID == plan.observedStopID,
              state.breakpointBindingState.pendingPlan?.transactionID == plan.transactionID else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
    }

    private func completeLogicalBreakpointCleanup(
        _ input: PersistentLLDBLogicalBreakpointReconciliationInput,
        contexts: [DebuggerRequestContext],
        collector: inout LLDBLogicalBreakpointTransactionCollector
    ) async throws {
        let step = try collector.dispatchNextStep()
        guard step == .cleanup else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .preparedRequestMismatch)
        }
        let response = try await executeLogicalBreakpointCommand(
            try LLDBLogicalBreakpointProgram.current.cleanupCommand(token: input.token),
            context: contexts[input.reservation.cleanupPhysicalRequestOffset],
            plan: input.prepared.plan
        )
        _ = try LLDBLogicalBreakpointResponseDecoder().decode(
            response.transcript,
            expecting: .cleanup(token: input.token)
        )
        try collector.completeDispatchedStep()
    }

    private func finishLogicalBreakpointFailure(
        _ error: Error,
        input: PersistentLLDBLogicalBreakpointReconciliationInput,
        contexts: [DebuggerRequestContext],
        collector: inout LLDBLogicalBreakpointTransactionCollector,
        validatedReceipt: DebuggerBreakpointBindingReceipt?
    ) async -> PersistentLLDBLogicalBreakpointReconciliationFailure {
        var retainedReceipt: DebuggerBreakpointBindingReceipt?
        var validatedReceiptRetentionFailed = false
        if collector.dispatchedStep != nil {
            let evidence: LLDBLogicalBreakpointDispatchedStepFailureEvidence =
                logicalBreakpointFailureWasProvenBeforeWrite(error)
                    ? .provenBeforeWrite
                    : .writeUncertain
            try? collector.failDispatchedStep(evidence)
        }

        let cleanupCanRun = logicalBreakpointAdapterCanAttemptCleanup(error)
        if logicalBreakpointCleanupRequiresAttempt(collector.failureClassification) {
            if cleanupCanRun {
                do {
                    try collector.forceCleanupAfterFailure()
                    try await completeLogicalBreakpointCleanup(
                        input,
                        contexts: contexts,
                        collector: &collector
                    )
                } catch let cleanupError {
                    if collector.dispatchedStep != nil {
                        try? collector.failDispatchedStep(
                            logicalBreakpointFailureWasProvenBeforeWrite(cleanupError)
                                ? .provenBeforeWrite
                                : .writeUncertain
                        )
                    }
                    if logicalBreakpointCleanupRequiresAttempt(
                        collector.failureClassification
                    ) {
                        try? collector.markCleanupUnavailableAfterFailure()
                    }
                }
            } else {
                try? collector.markCleanupUnavailableAfterFailure()
            }
        }

        let classification = collector.failureClassification
        switch classification {
        case .cancelBeforeWrite:
            _ = reducer.cancelLogicalBreakpointBindingBeforeWrite(
                transactionID: input.prepared.plan.transactionID
            )
        case .rejectMalformedAfterPossibleWrite(
            _, let retainValidatedCompleteReceipt, _
        ):
            if retainValidatedCompleteReceipt, let validatedReceipt {
                if reducer.completeLogicalBreakpointBinding(validatedReceipt) {
                    retainedReceipt = validatedReceipt
                    replaceLogicalBreakpointCallbackAuthority(
                        after: validatedReceipt,
                        input: input
                    )
                } else {
                    validatedReceiptRetentionFailed = true
                }
            }
        }
        let sessionDisposition = validatedReceiptRetentionFailed
            ? PersistentLLDBLogicalBreakpointSessionDisposition.invalidateAndShutdown
            : logicalBreakpointSessionDisposition(
                error,
                classification: classification
            )
        if sessionDisposition == .invalidateAndShutdown {
            // The controller's bounded terminate/poll recovery owns the reserved recovery tail.
            // Do not let retained callback authority recursively allocate a 1,024-page drain.
            logicalBreakpointCallbackDrainIsQuarantined = true
        }
        return PersistentLLDBLogicalBreakpointReconciliationFailure(
            code: logicalBreakpointFailureCode(error),
            classification: classification,
            sessionDisposition: sessionDisposition,
            reducerState: reducer.state,
            validatedReceipt: retainedReceipt
        )
    }

    /// Replaces the prior token only after the exact receipt has been accepted by the reducer.
    /// Empty convergence retires callback ownership because the old token reached a final drain
    /// before apply and no callback-capable backend location remains afterward.
    private func replaceLogicalBreakpointCallbackAuthority(
        after receipt: DebuggerBreakpointBindingReceipt,
        input: PersistentLLDBLogicalBreakpointReconciliationInput
    ) {
        logicalBreakpointCallbackDrainIsQuarantined = false
        guard !receipt.completeOwnedInventory.isEmpty else {
            logicalBreakpointCallbackAuthority = nil
            return
        }
        logicalBreakpointCallbackAuthority = LogicalBreakpointCallbackDrainAuthority(
            sessionEpoch: receipt.sessionEpoch,
            adapterGeneration: receipt.adapterGeneration,
            processID: receipt.observedPID,
            token: input.token,
            bindingIDsByWireID: Dictionary(
                uniqueKeysWithValues: input.prepared.wireBindings.map {
                    ($0.wireID, $0.binding.id)
                }
            )
        )
    }

    private func logicalBreakpointCleanupRequiresAttempt(
        _ classification: LLDBLogicalBreakpointTransactionFailureClassification
    ) -> Bool {
        let evidence: LLDBLogicalBreakpointCleanupEvidence
        switch classification {
        case .cancelBeforeWrite(let cleanup):
            evidence = cleanup
        case .rejectMalformedAfterPossibleWrite(let cleanup, _, _):
            evidence = cleanup
        }
        return evidence == .required
    }

    private func logicalBreakpointFailureWasProvenBeforeWrite(_ error: Error) -> Bool {
        guard let failure = error as? PersistentLLDBCLIAdapterFailure else { return false }
        return switch failure.disposition {
        case .cancelledBeforeWrite, .failedBeforeWrite: true
        case .invalidatedAfterWrite, .completed: false
        }
    }

    private func logicalBreakpointAdapterCanAttemptCleanup(_ error: Error) -> Bool {
        if let failure = error as? PersistentLLDBSessionCoordinatorFailure {
            switch failure.code {
            case .preparedRequestMismatch, .responseCorrelationMismatch,
                 .responseProjectionFailed:
                return true
            case .requestSequenceExhausted, .eventSequenceExhausted, .admissionRejected,
                 .requestPreparationFailed, .invalidObservedProcess, .adapterCancelled,
                 .adapterFailedBeforeWrite, .adapterInvalidated, .reducerRejected:
                return false
            }
        }
        guard let failure = error as? PersistentLLDBCLIAdapterFailure else {
            return true
        }
        switch failure.code {
        case .cancelledBeforeWrite, .invalidRequest, .exactAttachWriteRejected:
            return true
        case .staleGeneration, .invalidatedGeneration:
            return false
        }
    }

    private func logicalBreakpointSessionDisposition(
        _ error: Error,
        classification: LLDBLogicalBreakpointTransactionFailureClassification
    ) -> PersistentLLDBLogicalBreakpointSessionDisposition {
        let cleanup: LLDBLogicalBreakpointCleanupEvidence
        switch classification {
        case .cancelBeforeWrite(let evidence):
            cleanup = evidence
        case .rejectMalformedAfterPossibleWrite(let evidence, _, _):
            cleanup = evidence
        }
        if cleanup == .failedOrUnproven {
            return .invalidateAndShutdown
        }
        if let failure = error as? PersistentLLDBCLIAdapterFailure {
            switch failure.code {
            case .staleGeneration, .invalidatedGeneration:
                return .invalidateAndShutdown
            case .cancelledBeforeWrite, .invalidRequest, .exactAttachWriteRejected:
                break
            }
            switch failure.disposition {
            case .invalidatedAfterWrite, .completed:
                return .invalidateAndShutdown
            case .cancelledBeforeWrite, .failedBeforeWrite:
                break
            }
        }
        if let failure = error as? PersistentLLDBSessionCoordinatorFailure {
            switch failure.code {
            case .responseCorrelationMismatch, .invalidObservedProcess, .adapterInvalidated:
                return .invalidateAndShutdown
            case .requestSequenceExhausted, .eventSequenceExhausted, .admissionRejected,
                 .requestPreparationFailed, .preparedRequestMismatch,
                 .responseProjectionFailed, .adapterCancelled, .adapterFailedBeforeWrite,
                 .reducerRejected:
                break
            }
        }
        return .retainCorrelatedSession
    }

    private func logicalBreakpointFailureCode(
        _ error: Error
    ) -> PersistentLLDBSessionCoordinatorFailureCode {
        if let failure = error as? PersistentLLDBSessionCoordinatorFailure {
            return failure.code
        }
        if let failure = error as? PersistentLLDBCLIAdapterFailure {
            switch failure.disposition {
            case .cancelledBeforeWrite: return .adapterCancelled
            case .failedBeforeWrite: return .adapterFailedBeforeWrite
            case .invalidatedAfterWrite, .completed: return .adapterInvalidated
            }
        }
        return .responseProjectionFailed
    }

    /// Drains the exact retained token/wire ledger to one final acknowledgement. The caller has
    /// already reserved every physical context and event slot. Each accepted page is published as
    /// a session-scoped nil-request event before any lifecycle transition can tombstone the prior
    /// binding identities.
    private func drainLogicalBreakpointCallbacksBeforeLifecycleAcceptance(
        _ authority: LogicalBreakpointCallbackDrainAuthority,
        contexts: [DebuggerRequestContext],
        initialProcessState: LLDBCLIObservedProcessState,
        permitsInitialResumeTransition: Bool
    ) async throws -> LLDBCLIObservedProcessState {
        guard contexts.count == Self.logicalBreakpointCallbackDrainPageCapacity,
              authority.sessionEpoch == epoch,
              authority.adapterGeneration > 0,
              authority.processID > 0,
              authority.token.count == 32,
              initialProcessState.processID == authority.processID else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        let decoder = LLDBLogicalBreakpointResponseDecoder()
        let callbackDecoder = LLDBLogicalBreakpointCallbackBatchDecoder(
            expectedSessionEpoch: authority.sessionEpoch,
            expectedAdapterGeneration: authority.adapterGeneration,
            expectedProcessID: authority.processID,
            bindingIDsByWireID: authority.bindingIDsByWireID
        )
        var afterSequence = reducer.state.breakpointBindingState.lastCallbackSequence
        var latestProcessState = initialProcessState
        var isFirstPage = true
        for context in contexts {
            guard clock.now < deadline else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .responseProjectionFailed)
            }
            try validateCallbackDrainAuthority(authority)
            let remaining = clock.now.duration(to: deadline)
            let request = try PersistentLLDBCLIRequest(
                context: context,
                semanticCommands: [try LLDBLogicalBreakpointProgram.current.drainLogsCommand(
                    token: authority.token,
                    sessionEpoch: authority.sessionEpoch,
                    adapterGeneration: authority.adapterGeneration,
                    expectedProcessID: authority.processID,
                    afterSequence: afterSequence
                )],
                observedPIDRequirement: .required,
                timeout: remaining
            )
            let response = try await executor.executeCoordinatorSelected(request)
            guard clock.now <= deadline else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .responseProjectionFailed,
                    requestID: context.id
                )
            }
            guard response.requestID == context.id,
                  response.generation == authority.adapterGeneration,
                  response.transcript.observedProcessID == authority.processID,
                  let observedProcessState = response.transcript.observedProcessState,
                  observedProcessState.processID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .responseCorrelationMismatch,
                    requestID: context.id
                )
            }
            guard Self.callbackDrainTransitionIsMonotonic(
                from: latestProcessState,
                to: observedProcessState,
                permitsResumeTransition: permitsInitialResumeTransition && isFirstPage
            ) else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .invalidObservedProcess,
                    requestID: context.id
                )
            }
            latestProcessState = observedProcessState
            isFirstPage = false
            guard case .logs(
                _, _, _, _, let receivedAfterSequence, let nextSequence,
                let isFinal, let canonicalRecords
            ) = try decoder.decode(
                response.transcript,
                expecting: .logs(
                    token: authority.token,
                    sessionEpoch: authority.sessionEpoch,
                    adapterGeneration: authority.adapterGeneration,
                    processID: authority.processID,
                    afterSequence: afterSequence
                )
            ), receivedAfterSequence == afterSequence else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .responseProjectionFailed,
                    requestID: context.id
                )
            }
            let batch = try callbackDecoder.decode(
                canonicalRecords: canonicalRecords,
                afterSequence: afterSequence,
                nextSequence: nextSequence,
                isFinal: isFinal
            )
            guard isFinal || nextSequence > afterSequence else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .responseProjectionFailed,
                    requestID: context.id
                )
            }
            try emitLogicalBreakpointCallbackBatch(batch)
            guard !reducer.state.breakpointBindingState.isInvalidated else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .reducerRejected,
                    requestID: context.id
                )
            }
            afterSequence = nextSequence
            if isFinal {
                return latestProcessState
            }
        }
        throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
    }

    static func callbackDrainTransitionIsMonotonic(
        from previous: LLDBCLIObservedProcessState,
        to next: LLDBCLIObservedProcessState,
        permitsResumeTransition: Bool
    ) -> Bool {
        switch (previous, next) {
        case (.running(let previousPID), .running(let nextPID)),
             (.running(let previousPID), .stopped(let nextPID)),
             (.stopped(let previousPID), .stopped(let nextPID)):
            return previousPID == nextPID
        case (.running(let previousPID), .exited(let nextPID, _)),
             (.stopped(let previousPID), .exited(let nextPID, _)):
            return previousPID == nextPID
        case (.stopped(let previousPID), .running(let nextPID)):
            return permitsResumeTransition && previousPID == nextPID
        case (.exited(let previousPID, let previousStatus),
              .exited(let nextPID, let nextStatus)):
            return previousPID == nextPID && previousStatus == nextStatus
        case (.exited, .running), (.exited, .stopped):
            return false
        }
    }

    private func callbackDrainInitialProcessState(
        for authority: LogicalBreakpointCallbackDrainAuthority
    ) throws -> LLDBCLIObservedProcessState {
        switch reducer.state.processPhase {
        case .running(let processID):
            guard processID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .invalidObservedProcess)
            }
            return .running(processID: processID)
        case .stopped(let processID, _):
            guard processID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .invalidObservedProcess)
            }
            return .stopped(processID: processID)
        case .exited(let processID, let status):
            guard processID == authority.processID else {
                throw PersistentLLDBSessionCoordinatorFailure(code: .invalidObservedProcess)
            }
            return .exited(processID: processID, status: status)
        case .noTarget, .detaching, .detached, .terminated, .invalidated:
            throw PersistentLLDBSessionCoordinatorFailure(code: .invalidObservedProcess)
        }
    }

    private func operationPermitsResumeTransition(_ operation: DebuggerOperation) -> Bool {
        switch operation {
        case .continue, .runToCursor, .stepOver, .stepInto, .stepOut:
            return true
        case .launch, .attach, .pause, .detach, .terminate, .replaceBreakpoints,
             .reconcileLogicalBreakpoints, .writeRegister, .readMemory, .writeMemory, .updateWatchpoints,
             .evaluateExpression, .expandVariableChildren, .selectThread, .selectFrame,
             .refreshSnapshot, .refreshRuntimeModules, .pollProcessStatus:
            return false
        }
    }

    private func validateCallbackDrainAuthority(
        _ authority: LogicalBreakpointCallbackDrainAuthority
    ) throws {
        let state = reducer.state
        let binding = state.breakpointBindingState
        guard !state.isInvalidated,
              !binding.isInvalidated,
              !binding.isTerminal,
              state.epoch == authority.sessionEpoch,
              state.observedProcessID == authority.processID,
              binding.sessionEpoch == authority.sessionEpoch,
              binding.adapterGeneration == authority.adapterGeneration,
              binding.observedPID == authority.processID,
              Set(authority.bindingIDsByWireID.values)
                == Set(binding.ownedLocations.map(\.bindingID)) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
    }

    private func emitLogicalBreakpointCallbackBatch(
        _ batch: DebuggerBreakpointCallbackBatch
    ) throws {
        guard let sequence = lastEventSequence.incremented() else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        lastEventSequence = sequence
        let envelope = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: sequence,
            requestID: nil,
            operation: nil,
            capturedLifecycleRevision: reducer.state.lifecycleRevision,
            boundStopRevision: nil,
            payload: .logicalBreakpointCallbacksDrained(batch)
        )
        switch reducer.reduce(envelope) {
        case .accepted:
            if reducer.state.isInvalidated {
                logicalBreakpointCallbackAuthority = nil
                logicalBreakpointCallbackDrainIsQuarantined = false
            }
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .reducerRejected,
                reducerRejection: rejection
            )
        }
    }

    private func failPendingRequestAfterCallbackDrain(
        _ context: DebuggerRequestContext
    ) throws {
        let diagnostic = DebuggerDiagnostic.make(
            code: .protocolViolation,
            severity: .error,
            rawText: "Logical breakpoint callbacks could not be correlated safely.",
            operation: context.operation,
            targetDisposition: reducer.state.targetDisposition
        )
        try emit(.requestFailed(diagnostic), for: context)
    }

    private func reserveOperationContexts(
        operation: DebuggerOperation,
        expectedSession: DebuggerSessionCoordinate,
        requiredStop: DebuggerStopCoordinate?,
        variableExpansionRequest: DebuggerVariableExpansionRequest? = nil
    ) throws -> ReservedOperationContexts {
        let targetAuthority = Self.sessionScopedTargetAuthority(
            for: operation,
            reducerState: reducer.state
        )
        if logicalBreakpointCallbackDrainIsQuarantined,
           operation != .terminate,
           operation != .pollProcessStatus {
            throw PersistentLLDBSessionCoordinatorFailure(code: .admissionRejected)
        }
        let shouldReserveDrain = logicalBreakpointCallbackAuthority != nil
            && !logicalBreakpointCallbackDrainIsQuarantined
            && (operation.classification == .lifecycleMutating
                || operation.classification == .sessionObserving)
        let callbackCount = shouldReserveDrain
            ? Self.logicalBreakpointCallbackDrainPageCapacity
            : 0
        guard let callbackRequestCount = UInt64(exactly: callbackCount) else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let completeRequestCount = callbackRequestCount + 1
        let end = lastRequestSequence.addingReportingOverflow(completeRequestCount)
        guard !end.overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .requestSequenceExhausted)
        }
        let eventCapacity = UInt64(callbackCount) + Self.ordinaryOperationEventCapacity
        guard !lastEventSequence.rawValue.addingReportingOverflow(eventCapacity).overflow else {
            throw PersistentLLDBSessionCoordinatorFailure(code: .eventSequenceExhausted)
        }
        let parentSequence = lastRequestSequence + 1
        let parent = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: parentSequence),
            operation: operation,
            expectedSession: expectedSession,
            requiredStop: requiredStop,
            targetAuthority: targetAuthority,
            variableExpansionRequest: variableExpansionRequest
        )
        let callbackDrain = (0..<callbackCount).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(
                    epoch: epoch,
                    sequence: parentSequence + 1 + UInt64(offset)
                ),
                operation: .pollProcessStatus,
                expectedSession: expectedSession,
                requiredStop: nil,
                targetAuthority: targetAuthority
            )
        }
        lastRequestSequence = end.partialValue
        return ReservedOperationContexts(parent: parent, callbackDrain: callbackDrain)
    }

    private func accept(
        _ response: PersistentLLDBCLIResponse,
        for context: DebuggerRequestContext,
        callbackDrainContexts: [DebuggerRequestContext]
    ) async throws -> PersistentLLDBSessionExecutionResult {
        guard response.requestID == context.id else {
            try markStarted(context)
            try invalidate(context, label: "Persistent LLDB response correlation failed.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: context.id
            )
        }

        let observation: ValidatedObservation?
        do {
            observation = try validateObservation(
                response.transcript,
                for: context.operation
            )
        } catch {
            try markStarted(context)
            try invalidate(context, label: "Persistent LLDB did not prove one exact process.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }

        try markStarted(context)

        if var observation {
            if let authority = logicalBreakpointCallbackAuthority,
               !callbackDrainContexts.isEmpty {
                do {
                    guard authority.processID == observation.processID else {
                        throw PersistentLLDBSessionCoordinatorFailure(
                            code: .invalidObservedProcess,
                            requestID: context.id
                        )
                    }
                    let authoritativeInitialState = try callbackDrainInitialProcessState(
                        for: authority
                    )
                    let latestState = try await drainLogicalBreakpointCallbacksBeforeLifecycleAcceptance(
                        authority,
                        contexts: callbackDrainContexts,
                        initialProcessState: authoritativeInitialState,
                        permitsInitialResumeTransition: operationPermitsResumeTransition(
                            context.operation
                        )
                    )
                    observation = ValidatedObservation(
                        processID: authority.processID,
                        state: latestState
                    )
                } catch {
                    logicalBreakpointCallbackDrainIsQuarantined = true
                    try failPendingRequestAfterCallbackDrain(context)
                    throw PersistentLLDBLogicalBreakpointCallbackDrainFailure(
                        code: logicalBreakpointFailureCode(error),
                        disposition: .terminateAndReap,
                        reducerState: reducer.state
                    )
                }
                if reducer.state.isInvalidated {
                    return mintExecutionResult(
                        requestID: context.id,
                        reducerState: reducer.state
                    )
                }
            }
            switch context.operation.classification {
            case .sessionEstablishing:
                try emit(.sessionOpened(observedPID: observation.processID), for: context)
                try emitLifecycle(observation.state, for: context)

            case .lifecycleMutating:
                // A rejected command that merely re-observes the current stopped/running state
                // must not mint a fresh lifecycle/stop revision. A genuinely changed observed
                // state (including running or exited after a command reported failure) remains
                // authoritative and is reduced before the typed request failure.
                if !response.transcript.semanticCommandsSucceeded,
                   observationMatchesCurrentAuthority(observation) {
                    break
                }
                if !isUnchangedAsynchronousMutationObservation(
                    observation,
                    operation: context.operation
                ) {
                    try emitLifecycle(observation.state, for: context)
                }

            case .sessionObserving:
                try emitObservedSessionTransition(observation, for: context)

            case .stoppedStateMutating, .stoppedStateReading, .presentationOnly:
                guard observationMatchesCurrentAuthority(observation) else {
                    try invalidate(context, label: "Persistent LLDB process state lost authority.")
                    throw PersistentLLDBSessionCoordinatorFailure(
                        code: .invalidObservedProcess,
                        requestID: context.id
                    )
                }
            }
        }

        do {
            try await requestPreparer.validateResponse(
                for: context,
                transcript: response.transcript
            )
        } catch {
            let diagnostic = DebuggerDiagnostic.make(
                code: .operationFailed,
                severity: .error,
                rawText: "LLDB rejected the typed debugger operation.",
                operation: context.operation,
                targetDisposition: reducer.state.targetDisposition
            )
            try emit(.requestFailed(diagnostic), for: context)
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: context.id
            )
        }

        if reducer.state.isInvalidated {
            return mintExecutionResult(
                requestID: context.id,
                reducerState: reducer.state
            )
        }

        do {
            let payloads = try await requestPreparer.reducerPayloads(
                for: context,
                transcript: response.transcript
            )
            for payload in payloads {
                try emit(payload, for: context)
            }
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            throw failure
        } catch {
            let diagnostic = DebuggerDiagnostic.make(
                code: .operationFailed,
                severity: .error,
                rawText: "The bounded LLDB response could not be converted into typed debugger state.",
                operation: context.operation,
                targetDisposition: reducer.state.targetDisposition
            )
            try emit(.requestFailed(diagnostic), for: context)
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseProjectionFailed,
                requestID: context.id
            )
        }

        try emit(
            .requestCompleted(.completed(target: reducer.state.targetDisposition)),
            for: context
        )
        return mintExecutionResult(requestID: context.id, reducerState: reducer.state)
    }

    private func mintExecutionResult(
        requestID: DebuggerRequestID,
        reducerState: DebuggerReducerState
    ) -> PersistentLLDBSessionExecutionResult {
        let authority = PersistentLLDBSessionExecutionSealAuthority()
        currentExecutionSealAuthority = authority
        return PersistentLLDBSessionExecutionResult(
            requestID: requestID,
            reducerState: reducerState,
            sealAuthority: authority
        )
    }

    private func validateObservation(
        _ transcript: LLDBCLITranscriptResult,
        for operation: DebuggerOperation
    ) throws -> ValidatedObservation? {
        if operation == .replaceBreakpoints,
           transcript.observedProcessID == nil,
           transcript.observedProcessState == nil,
           reducer.state.observedProcessID == nil,
           reducer.state.processPhase == .noTarget {
            return nil
        }

        guard let observedPID = transcript.observedProcessID,
              observedPID > 0,
              let observedState = transcript.observedProcessState,
              observedState.processID == observedPID else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess
            )
        }

        if let authoritativePID = reducer.state.observedProcessID,
           authoritativePID != observedPID {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess
            )
        }
        return ValidatedObservation(processID: observedPID, state: observedState)
    }

    private func observationMatchesCurrentAuthority(
        _ observation: ValidatedObservation
    ) -> Bool {
        guard reducer.state.observedProcessID == observation.processID else { return false }
        switch (reducer.state.processPhase, observation.state) {
        case (.running(let current), .running(let observed)):
            return current == observed
        case (.stopped(let current, _), .stopped(let observed)):
            return current == observed
        case (.exited(let current, let currentCode), .exited(let observed, let observedCode)):
            return current == observed && currentCode == observedCode
        case (.noTarget, _), (.detaching, _), (.detached, _), (.terminated, _),
             (.invalidated, _), (.running, _), (.stopped, _), (.exited, _):
            return false
        }
    }

    private func isUnchangedAsynchronousMutationObservation(
        _ observation: ValidatedObservation,
        operation: DebuggerOperation
    ) -> Bool {
        switch (operation, reducer.state.processPhase, observation.state) {
        case (.pause, .running(let current), .running(let observed)),
             (.terminate, .running(let current), .running(let observed)),
             (.terminate, .stopped(let current, _), .stopped(let observed)):
            return current == observed
        default:
            return false
        }
    }

    private func emitLifecycle(
        _ state: LLDBCLIObservedProcessState,
        for context: DebuggerRequestContext
    ) throws {
        switch state {
        case .running(let processID):
            try emit(.processRunning(observedPID: processID), for: context)
        case .stopped(let processID):
            try emit(
                .processStopped(
                    observedPID: processID,
                    reason: .unknown("LLDB reported a stopped process.")
                ),
                for: context
            )
        case .exited(let processID, let status):
            try emit(
                .processExited(observedPID: processID, exitCode: status),
                for: context
            )
        }
    }

    /// Status polling observes an asynchronous target without claiming that an unchanged running
    /// status is a second lifecycle transition. A newly stopped or exited status remains
    /// authoritative and is reduced exactly once.
    private func emitObservedSessionTransition(
        _ observation: ValidatedObservation,
        for context: DebuggerRequestContext
    ) throws {
        switch (reducer.state.processPhase, observation.state) {
        case (.running(let current), .running(let observed)) where current == observed,
             (.stopped(let current, _), .stopped(let observed)) where current == observed:
            // Same-state status is an observation, not a new lifecycle event.
            return
        case (.running(let current), .stopped(let observed)) where current == observed,
             (.running(let current), .exited(let observed, _)) where current == observed,
             (.stopped(let current, _), .exited(let observed, _)) where current == observed:
            try emitLifecycle(observation.state, for: context)
        default:
            try invalidate(context, label: "A status poll lost exact session authority.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: context.id
            )
        }
    }

    private func waitForActivePoll() async {
        guard activePollRequestID != nil else { return }
        await withCheckedContinuation { continuation in
            pollCompletionWaiters.append(continuation)
        }
    }

    private func finishActivePoll(_ requestID: DebuggerRequestID) {
        guard activePollRequestID == requestID else { return }
        activePollRequestID = nil
        let waiters = pollCompletionWaiters
        pollCompletionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func handleAdapterFailure(
        _ failure: PersistentLLDBCLIAdapterFailure,
        for context: DebuggerRequestContext,
        deadline: Duration? = nil
    ) throws {
        guard failure.requestID == context.id else {
            let cause = PersistentLLDBAdapterInvalidationCause.failureCorrelationLost
            try invalidate(
                context,
                label: "Persistent LLDB failure correlation was lost (\(cause.summary))."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: context.id,
                invalidationCause: cause
            )
        }

        switch failure.disposition {
        case .cancelledBeforeWrite:
            try emit(.requestCancelled(.cancelledBeforeWrite), for: context)
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterCancelled,
                requestID: context.id
            )

        case .failedBeforeWrite:
            try failBeforeWrite(context, label: "Persistent LLDB rejected the request before write.")
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterFailedBeforeWrite,
                requestID: context.id
            )

        case .invalidatedAfterWrite(let reason, let target):
            guard target == .unknown else {
                let cause = PersistentLLDBAdapterInvalidationCause.invalidDisposition
                try invalidate(
                    context,
                    label: "Persistent LLDB returned an invalid disposition (\(cause.summary))."
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterInvalidated,
                    requestID: context.id,
                    invalidationCause: cause
                )
            }
            try markStarted(context)
            if reason == .cancellationAfterWrite {
                try emit(
                    .requestCancelled(.invalidatedAfterWrite(reason: reason, target: .unknown)),
                    for: context
                )
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .adapterCancelled,
                    requestID: context.id
                )
            }
            let cause = failure.transcriptDiagnosticCode.map {
                PersistentLLDBAdapterInvalidationCause.transcriptValidation($0)
            } ?? .transport(
                reason,
                deadline: reason == .timeoutAfterWrite ? deadline : nil
            )
            try invalidate(
                context,
                label: "Persistent LLDB adapter generation was invalidated (\(cause.summary))."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: context.id,
                invalidationCause: cause
            )

        case .completed:
            let cause = PersistentLLDBAdapterInvalidationCause.invalidDisposition
            try invalidate(
                context,
                label: "Persistent LLDB threw a completed disposition (\(cause.summary))."
            )
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: context.id,
                invalidationCause: cause
            )
        }
    }

    private func markStarted(_ context: DebuggerRequestContext) throws {
        if reducer.state.pendingRequest?.hasStarted == false {
            try emit(.requestStarted, for: context)
        }
    }

    private func failBeforeWrite(
        _ context: DebuggerRequestContext,
        label: String
    ) throws {
        let diagnostic = DebuggerDiagnostic.make(
            code: .operationFailed,
            severity: .error,
            rawText: label,
            operation: context.operation,
            targetDisposition: reducer.state.targetDisposition
        )
        try emit(.requestFailed(diagnostic), for: context)
    }

    private func invalidate(
        _ context: DebuggerRequestContext,
        label: String
    ) throws {
        let diagnostic = DebuggerDiagnostic.make(
            code: .protocolViolation,
            severity: .error,
            rawText: label,
            operation: context.operation,
            targetDisposition: .unknown
        )
        try emit(.sessionInvalidated(diagnostic), for: context)
    }

    private func emit(
        _ payload: DebuggerEventPayload,
        for context: DebuggerRequestContext
    ) throws {
        guard let sequence = lastEventSequence.incremented() else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .eventSequenceExhausted,
                requestID: context.id
            )
        }
        lastEventSequence = sequence
        let envelope = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: sequence,
            requestID: context.id,
            operation: context.operation,
            capturedLifecycleRevision: context.expectedSession.lifecycleRevision,
            boundStopRevision: context.requiredStop?.stopRevision,
            payload: payload
        )
        switch reducer.reduce(envelope) {
        case .accepted:
            if reducer.state.isInvalidated {
                logicalBreakpointCallbackAuthority = nil
                logicalBreakpointCallbackDrainIsQuarantined = false
            } else if case .processExited = payload {
                logicalBreakpointCallbackAuthority = nil
                logicalBreakpointCallbackDrainIsQuarantined = false
            }
            return
        case .rejected(let rejection):
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .reducerRejected,
                requestID: context.id,
                reducerRejection: rejection
            )
        }
    }
}

/// Owns consumption of the pre-reserved physical range while the coordinator actor may re-enter.
/// This prevents a collector from racing two page exchanges, reusing a context, or consuming the
/// cleanup-only tail context as an ordinary page.
private actor PersistentLLDBRuntimeModuleReservedExchange {
    struct Status: Sendable {
        let cleanupProven: Bool
        let requiresInvalidation: Bool
        let didAttemptPhysicalExchange: Bool
        let mayHaveWritten: Bool
    }

    private let parent: DebuggerRequestContext
    private let regularContexts: [DebuggerRequestContext]
    private let cleanupContext: DebuggerRequestContext
    private let expectedProcessID: Int32
    private let executor: any PersistentLLDBCLIExecuting
    private let validateAuthority: @Sendable () async throws -> Void
    private let markParentStarted: @Sendable () async throws -> Void

    private var nextRegularIndex = 0
    private var didAttemptCleanup = false
    private var didProveCleanup = false
    private var invalidationRequired = false
    private var didAttemptPhysicalExchange = false
    private var mayHaveWritten = false
    private var isExchangeInFlight = false
    private var exchangeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        parent: DebuggerRequestContext,
        regularContexts: [DebuggerRequestContext],
        cleanupContext: DebuggerRequestContext,
        expectedProcessID: Int32,
        executor: any PersistentLLDBCLIExecuting,
        validateAuthority: @escaping @Sendable () async throws -> Void,
        markParentStarted: @escaping @Sendable () async throws -> Void
    ) {
        self.parent = parent
        self.regularContexts = regularContexts
        self.cleanupContext = cleanupContext
        self.expectedProcessID = expectedProcessID
        self.executor = executor
        self.validateAuthority = validateAuthority
        self.markParentStarted = markParentStarted
    }

    var status: Status {
        Status(
            cleanupProven: didProveCleanup,
            requiresInvalidation: invalidationRequired,
            didAttemptPhysicalExchange: didAttemptPhysicalExchange,
            mayHaveWritten: mayHaveWritten
        )
    }

    func execute(
        _ physical: PersistentLLDBRuntimeModulePhysicalRequest
    ) async throws -> PersistentLLDBCLIResponse {
        await acquireExchangeTurn()
        defer { releaseExchangeTurn() }
        guard !didAttemptCleanup,
              nextRegularIndex < regularContexts.count else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestSequenceExhausted,
                requestID: parent.id
            )
        }
        let context = regularContexts[nextRegularIndex]
        nextRegularIndex += 1
        return try await perform(physical, context: context, cleanupValidator: nil)
    }

    func cleanup(
        _ physical: PersistentLLDBRuntimeModulePhysicalRequest,
        validate: @escaping PersistentLLDBRuntimeModuleExchangeChannel.CleanupValidator
    ) async throws -> PersistentLLDBCLIResponse {
        await acquireExchangeTurn()
        defer { releaseExchangeTurn() }
        guard !didAttemptCleanup else {
            invalidationRequired = true
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .adapterInvalidated,
                requestID: parent.id
            )
        }
        didAttemptCleanup = true
        return try await perform(physical, context: cleanupContext, cleanupValidator: validate)
    }

    private func perform(
        _ physical: PersistentLLDBRuntimeModulePhysicalRequest,
        context: DebuggerRequestContext,
        cleanupValidator: PersistentLLDBRuntimeModuleExchangeChannel.CleanupValidator?
    ) async throws -> PersistentLLDBCLIResponse {
        didAttemptPhysicalExchange = true
        try await validateAuthority()

        let request: PersistentLLDBCLIRequest
        do {
            request = try PersistentLLDBCLIRequest(
                context: context,
                semanticCommands: physical.semanticCommands,
                observedPIDRequirement: physical.observedPIDRequirement,
                timeout: physical.timeout
            )
        } catch {
            throw error
        }

        let response: PersistentLLDBCLIResponse
        do {
            response = try await executor.executeCoordinatorSelected(request)
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            if failure.requestID != context.id {
                invalidationRequired = true
            }
            switch failure.disposition {
            case .invalidatedAfterWrite, .completed:
                mayHaveWritten = true
                invalidationRequired = true
                try? await markParentStarted()
            case .cancelledBeforeWrite, .failedBeforeWrite:
                break
            }
            throw failure
        } catch {
            mayHaveWritten = true
            invalidationRequired = true
            throw error
        }

        mayHaveWritten = true

        guard response.requestID == context.id else {
            invalidationRequired = true
            try? await markParentStarted()
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: parent.id
            )
        }
        try await markParentStarted()

        guard response.transcript.observedProcessID == expectedProcessID,
              response.transcript.observedProcessState == .stopped(
                  processID: expectedProcessID
              ) else {
            invalidationRequired = true
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .invalidObservedProcess,
                requestID: parent.id
            )
        }

        do {
            try await validateAuthority()
        } catch {
            invalidationRequired = true
            throw error
        }

        if let cleanupValidator {
            do {
                try cleanupValidator(response.transcript)
                didProveCleanup = true
            } catch {
                invalidationRequired = true
                throw error
            }
        }
        return response
    }

    private func acquireExchangeTurn() async {
        if !isExchangeInFlight {
            isExchangeInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            exchangeWaiters.append(continuation)
        }
    }

    private func releaseExchangeTurn() {
        guard !exchangeWaiters.isEmpty else {
            isExchangeInFlight = false
            return
        }
        let next = exchangeWaiters.removeFirst()
        next.resume()
    }
}

/// Adapter facade used only by the already-structured D1 collector. It rejects any attempt to
/// supply a different or reordered context, then delegates the actual exchange through the
/// coordinator-owned channel.
private actor PersistentLLDBRuntimeModuleCollectorExecutor: PersistentLLDBCLIExecuting {
    private let channel: PersistentLLDBRuntimeModuleExchangeChannel
    private var nextRegularIndex = 0
    private var didUseCleanup = false

    init(channel: PersistentLLDBRuntimeModuleExchangeChannel) {
        self.channel = channel
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        let contexts = channel.internalContexts
        guard let cleanupContext = contexts.last else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .requestSequenceExhausted,
                requestID: channel.parentContext.id
            )
        }
        let physical = PersistentLLDBRuntimeModulePhysicalRequest(
            semanticCommands: request.semanticCommands,
            observedPIDRequirement: request.observedPIDRequirement,
            timeout: request.timeout
        )

        if request.context == cleanupContext {
            guard !didUseCleanup else {
                throw PersistentLLDBSessionCoordinatorFailure(
                    code: .responseCorrelationMismatch,
                    requestID: channel.parentContext.id
                )
            }
            didUseCleanup = true
            return try await channel.cleanup(physical) { _ in }
        }

        guard !didUseCleanup,
              nextRegularIndex < contexts.count - 1,
              request.context == contexts[nextRegularIndex] else {
            throw PersistentLLDBSessionCoordinatorFailure(
                code: .responseCorrelationMismatch,
                requestID: channel.parentContext.id
            )
        }
        nextRegularIndex += 1
        return try await channel.execute(physical)
    }
}
