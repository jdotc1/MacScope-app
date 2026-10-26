import CryptoKit
import Foundation

/// The byte channel is intentionally narrower than `Foundation.Process`: the adapter owns
/// serialization and framing, while an integration wrapper owns the concrete pipes. Implementations
/// must merge lifecycle-authoritative output into one ordered stream.
protocol PersistentLLDBCLIByteChannel: Sendable {
    func write(_ data: Data) async throws
    func nextBytes() async throws -> Data?
    func closeInput() async
    func closeHandles() async
}

/// A monotonic sleep seam. Production uses `ContinuousClock`; tests can advance a manual clock
/// without sleeping or consulting wall time.
protocol PersistentLLDBCLIClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct PersistentLLDBCLIContinuousClock: PersistentLLDBCLIClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

/// Exact retained-adapter authority. A conformer may signal only the child process instance it
/// retained when LLDB was spawned. These methods never authorize signaling the debug target.
protocol PersistentLLDBCLIRetainedProcess: Sendable {
    func waitForExit(maximumDuration: Duration) async -> Bool
    func terminateRetainedAdapter() async
    func killRetainedAdapterIfStillRunning() async -> Bool
    func reapAndClose() async -> Bool
}

/// The one request role that may consume an exact-attach write grant. Keeping the authority in a
/// dedicated associated value makes it structurally impossible for an ordinary or staging request
/// to smuggle a grant to the adapter's write boundary.
struct PersistentLLDBCLIExactAttachFinalWriteAuthorization: Sendable {
    let interlock: DebuggerLocalProcessAttachWriteInterlock
    let issuanceInput: DebuggerLocalProcessAttachWriteIssuanceInput
    let grant: DebuggerLocalProcessAttachWriteGrant
}

/// The one-shot authority for exactly one canonical pre-final exchange in the current attach
/// program. The adapter retains the issuing interlock and frozen input so the opaque authorization
/// can only be consumed against the exact request that reaches this instance's write boundary.
struct PersistentLLDBCLIExactAttachStagingWriteAuthorization: Sendable {
    let interlock: DebuggerLocalProcessAttachWriteInterlock
    let issuanceInput: DebuggerLocalProcessAttachStagingWriteIssuanceInput
    let authorization: DebuggerLocalProcessAttachStagingWriteAuthorization
}

enum PersistentLLDBCLIRequestWriteRole: Sendable {
    case ordinary
    case exactAttachStaging(PersistentLLDBCLIExactAttachStagingWriteAuthorization?)
    case exactAttachFinal(PersistentLLDBCLIExactAttachFinalWriteAuthorization?)
}

/// Per-adapter reference authority for ordinary command writes. Only the concrete adapter can mint
/// this identity, so a raw or copied request cannot promote itself into an admitted ordinary write.
fileprivate final class PersistentLLDBCLIOrdinaryWriteAuthority: @unchecked Sendable {}

/// Opaque evidence that one concrete adapter sealed the exact physical request fields after the
/// coordinator matched them to its admitted semantic operation. Equality is intentionally exact:
/// context, rendered commands, PID observation mode, and timeout are all writer-bound.
fileprivate struct PersistentLLDBCLIOrdinaryWriteAuthorization: Sendable {
    let authority: PersistentLLDBCLIOrdinaryWriteAuthority
    let context: DebuggerRequestContext
    let semanticCommands: [String]
    let observedPIDRequirement: LLDBCLIObservedPIDRequirement
    let timeout: Duration
}

struct PersistentLLDBCLIRequest: Sendable {
    let context: DebuggerRequestContext
    let semanticCommands: [String]
    let observedPIDRequirement: LLDBCLIObservedPIDRequirement
    let timeout: Duration
    let writeRole: PersistentLLDBCLIRequestWriteRole
    private let ordinaryWriteAuthorization: PersistentLLDBCLIOrdinaryWriteAuthorization?

    init(
        context: DebuggerRequestContext,
        semanticCommands: [String],
        observedPIDRequirement: LLDBCLIObservedPIDRequirement,
        timeout: Duration,
        writeRole: PersistentLLDBCLIRequestWriteRole = .ordinary
    ) throws {
        let isStatusOnlyObservation = context.operation == .pollProcessStatus
            && semanticCommands.isEmpty
        guard context.isInternallyConsistent,
              (!semanticCommands.isEmpty || isStatusOnlyObservation),
              timeout > .zero else {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: context.id,
                generation: 0,
                disposition: .failedBeforeWrite
            )
        }
        for command in semanticCommands {
            try LLDBCLITranscriptDecoder.validateRenderedCommand(command)
        }

        self.context = context
        self.semanticCommands = semanticCommands
        self.observedPIDRequirement = observedPIDRequirement
        self.timeout = timeout
        self.writeRole = writeRole
        self.ordinaryWriteAuthorization = nil
    }

    private init(
        sealing request: PersistentLLDBCLIRequest,
        authority: PersistentLLDBCLIOrdinaryWriteAuthority
    ) {
        context = request.context
        semanticCommands = request.semanticCommands
        observedPIDRequirement = request.observedPIDRequirement
        timeout = request.timeout
        writeRole = request.writeRole
        ordinaryWriteAuthorization = PersistentLLDBCLIOrdinaryWriteAuthorization(
            authority: authority,
            context: request.context,
            semanticCommands: request.semanticCommands,
            observedPIDRequirement: request.observedPIDRequirement,
            timeout: request.timeout
        )
    }

    fileprivate func sealingOrdinaryWrite(
        with authority: PersistentLLDBCLIOrdinaryWriteAuthority
    ) -> PersistentLLDBCLIRequest {
        PersistentLLDBCLIRequest(sealing: self, authority: authority)
    }

    fileprivate var hasOrdinaryWriteAuthorization: Bool {
        ordinaryWriteAuthorization != nil
    }

    fileprivate func hasExactOrdinaryWriteAuthorization(
        from authority: PersistentLLDBCLIOrdinaryWriteAuthority
    ) -> Bool {
        guard let authorization = ordinaryWriteAuthorization else { return false }
        return authorization.authority === authority
            && authorization.context == context
            && authorization.semanticCommands == semanticCommands
            && authorization.observedPIDRequirement == observedPIDRequirement
            && authorization.timeout == timeout
    }
}

struct PersistentLLDBCLIResponse: Sendable, Equatable {
    let requestID: DebuggerRequestID
    let generation: UInt64
    let transcript: LLDBCLITranscriptResult
    let exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit?

    init(
        requestID: DebuggerRequestID,
        generation: UInt64,
        transcript: LLDBCLITranscriptResult,
        exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit? = nil
    ) {
        self.requestID = requestID
        self.generation = generation
        self.transcript = transcript
        self.exactAttachWriteCommit = exactAttachWriteCommit
    }
}

enum PersistentLLDBCLIAdapterFailureCode: String, Sendable, Equatable {
    case invalidRequest
    case cancelledBeforeWrite
    case exactAttachWriteRejected
    case staleGeneration
    case invalidatedGeneration
}

struct PersistentLLDBCLIAdapterFailure: Error, Sendable, Equatable {
    let code: PersistentLLDBCLIAdapterFailureCode
    let requestID: DebuggerRequestID?
    let generation: UInt64
    let disposition: DebuggerRequestDisposition
    /// Exact decoder rejection; carries no target output or command text.
    let transcriptDiagnosticCode: LLDBCLITranscriptDiagnosticCode?

    init(
        code: PersistentLLDBCLIAdapterFailureCode,
        requestID: DebuggerRequestID?,
        generation: UInt64,
        disposition: DebuggerRequestDisposition,
        transcriptDiagnosticCode: LLDBCLITranscriptDiagnosticCode? = nil
    ) {
        self.code = code
        self.requestID = requestID
        self.generation = generation
        self.disposition = disposition
        self.transcriptDiagnosticCode = transcriptDiagnosticCode
    }
}

enum PersistentLLDBCLIAdapterState: Sendable, Equatable {
    case active(generation: UInt64)
    case invalidated(generation: UInt64)
    case closed(generation: UInt64)
}

struct PersistentLLDBCLIShutdownReceipt: Sendable, Equatable {
    let requestedGracefulQuit: Bool
    let sentTerminate: Bool
    let sentKill: Bool
    let didExit: Bool
    let didReap: Bool
}

/// Opaque identity for one concrete persistent CLI executor instance. Generation and epoch alone
/// are insufficient: another adapter can deliberately share both values while retaining a
/// different child process. Each executor mints one binding and returns the same value for its
/// entire lifetime.
struct PersistentLLDBCLIAdapterInstanceBinding: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let digest: Data

    fileprivate init(sessionEpoch: DebuggerSessionEpoch, adapterGeneration: UInt64) {
        precondition(adapterGeneration > 0)
        let nonce = UUID()
        var material = Data("MacScope.PersistentLLDB.AdapterInstance.v1".utf8)
        material.append(0)
        material.append(Data(sessionEpoch.rawValue.uuidString.lowercased().utf8))
        material.append(0)
        var generation = adapterGeneration.bigEndian
        Swift.withUnsafeBytes(of: &generation) { material.append(contentsOf: $0) }
        material.append(0)
        material.append(Data(nonce.uuidString.lowercased().utf8))
        self.sessionEpoch = sessionEpoch
        self.adapterGeneration = adapterGeneration
        self.digest = Data(SHA256.hash(data: material))
    }
}

/// Sealed evidence that the exact retained LLDB adapter for one attached session exited and was
/// reaped without MacScope first writing `quit` (or any other debugger command) during retirement.
///
/// The proof deliberately binds to coordinator-minted attached-session evidence. Its constructor
/// remains private to this file so a generic shutdown receipt can never be promoted into lease-
/// release authority by another subsystem.
struct PersistentLLDBCLICommandFreeAdapterExitReapProof: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let adapterInstanceBindingDigest: Data
    let attachedSessionBindingDigest: Data
    let verifiedCommandQuiescence: Bool

    fileprivate init?(
        attachedSession: PersistentLLDBExactAttachedSessionEvidence,
        receipt: PersistentLLDBCLIShutdownReceipt,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        verifiedCommandQuiescence: Bool
    ) {
        guard !receipt.requestedGracefulQuit,
              receipt.didExit,
              receipt.didReap,
              verifiedCommandQuiescence,
              attachedSession.adapterInstanceBinding == adapterInstanceBinding else {
            return nil
        }
        self.sessionEpoch = attachedSession.establishedSession.epoch
        self.adapterGeneration = attachedSession.permit.adapterGeneration
        self.adapterInstanceBindingDigest = adapterInstanceBinding.digest
        self.attachedSessionBindingDigest = attachedSession.bindingDigest
        self.verifiedCommandQuiescence = true
    }
}

/// Exact-attached retirement never hides incomplete transport cleanup behind ordinary receipt
/// data. Only `.proven` may participate in the registry's atomic terminal lease release.
enum PersistentLLDBCLIExactAttachedRetirementOutcome: Sendable {
    case proven(PersistentLLDBCLICommandFreeAdapterExitReapProof)
    case unproven(PersistentLLDBCLIShutdownReceipt)
}

/// Counter-only evidence that a caller-selected literal reached LLDB's inbound byte stream.
///
/// The probe retains the caller-owned needle and a prefix length, never received bytes. Its
/// streaming matcher therefore detects a literal split across channel reads without turning the
/// proof seam into a transcript recorder. Locking permits the live-proof owner to read a snapshot
/// while the adapter's read pump is observing bytes.
struct PersistentLLDBCLIInboundNeedleProbeSnapshot: Sendable, Equatable {
    let observedByteCount: Int
    let matchCount: Int
}

final class PersistentLLDBCLIInboundNeedleProbe: @unchecked Sendable {
    private struct State {
        var observedByteCount = 0
        var matchCount = 0
        var matchedPrefixByteCount = 0
    }

    private let needle: [UInt8]
    private let prefixFallbacks: [Int]
    private let lock = NSLock()
    private var state = State()

    init(needle: Data) {
        precondition(!needle.isEmpty, "An inbound needle probe requires a nonempty literal.")
        self.needle = Array(needle)
        self.prefixFallbacks = Self.makePrefixFallbacks(for: Array(needle))
    }

    var snapshot: PersistentLLDBCLIInboundNeedleProbeSnapshot {
        lock.withLock {
            PersistentLLDBCLIInboundNeedleProbeSnapshot(
                observedByteCount: state.observedByteCount,
                matchCount: state.matchCount
            )
        }
    }

    func observe(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.withLock {
            state.observedByteCount = state.observedByteCount.addingSaturating(bytes.count)
            for byte in bytes {
                while state.matchedPrefixByteCount > 0,
                      needle[state.matchedPrefixByteCount] != byte {
                    state.matchedPrefixByteCount = prefixFallbacks[
                        state.matchedPrefixByteCount - 1
                    ]
                }
                if needle[state.matchedPrefixByteCount] == byte {
                    state.matchedPrefixByteCount += 1
                }
                if state.matchedPrefixByteCount == needle.count {
                    state.matchCount = state.matchCount.addingSaturating(1)
                    state.matchedPrefixByteCount = prefixFallbacks[needle.count - 1]
                }
            }
        }
    }

    private static func makePrefixFallbacks(for needle: [UInt8]) -> [Int] {
        var fallbacks = Array(repeating: 0, count: needle.count)
        var prefixByteCount = 0
        guard needle.count > 1 else { return fallbacks }
        for index in 1..<needle.count {
            while prefixByteCount > 0, needle[prefixByteCount] != needle[index] {
                prefixByteCount = fallbacks[prefixByteCount - 1]
            }
            if needle[prefixByteCount] == needle[index] {
                prefixByteCount += 1
            }
            fallbacks[index] = prefixByteCount
        }
        return fallbacks
    }
}

/// One persistent, serialized LLDB CLI interpreter.
///
/// Only this actor chooses the next request to write. Once a request is selected for writing,
/// cancellation is conservatively post-write: the generation is invalidated because a pipe write
/// may have partially succeeded. Timeout, EOF, oversize, and framing failure use the same terminal
/// path. No invalidated interpreter is ever reused.
actor PersistentLLDBCLIAdapter {
    private enum ShutdownMode: Equatable {
        case gracefulWhenHealthy
        case retainedAdapterOnly
    }

    private struct PendingRequest {
        let request: PersistentLLDBCLIRequest
        let continuation: CheckedContinuation<PersistentLLDBCLIResponse, Error>
    }

    private struct InFlightRequest {
        let pending: PendingRequest
        let generation: UInt64
        var decoder: LLDBCLITranscriptDecoder
        let exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit?
        var timeoutTask: Task<Void, Never>?
    }

    private struct OutstandingWrite {
        let token: UUID
        let requestID: DebuggerRequestID
        let generation: UInt64
        let task: Task<Bool, Never>
    }

    private let epoch: DebuggerSessionEpoch
    private let channel: any PersistentLLDBCLIByteChannel
    private let retainedProcess: any PersistentLLDBCLIRetainedProcess
    private let clock: any PersistentLLDBCLIClock
    private let markerSecret: Data
    private let shutdownStepTimeout: Duration
    private let retirementStdinEOFGracePeriod: Duration
    private let inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe?
    nonisolated private let instanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    nonisolated private let ordinaryWriteAuthority = PersistentLLDBCLIOrdinaryWriteAuthority()

    private var adapterState: PersistentLLDBCLIAdapterState = .active(generation: 1)
    private var queue: [PendingRequest] = []
    private var inFlight: InFlightRequest?
    private var lastAdmittedRequestSequence: UInt64 = 0
    private var readPumpTask: Task<Void, Never>?
    private var shutdownReceipt: PersistentLLDBCLIShutdownReceipt?
    private var shutdownInProgress = false
    private var shutdownWaiters: [CheckedContinuation<PersistentLLDBCLIShutdownReceipt, Never>] = []
    private var lateByteCount = 0
    private var outstandingWrite: OutstandingWrite?
    private var exactRetirementAdmissionClosed = false

    init(
        epoch: DebuggerSessionEpoch,
        channel: any PersistentLLDBCLIByteChannel,
        retainedProcess: any PersistentLLDBCLIRetainedProcess,
        clock: any PersistentLLDBCLIClock = PersistentLLDBCLIContinuousClock(),
        markerSecret: Data = PersistentLLDBCLIAdapter.makeMarkerSecret(),
        shutdownStepTimeout: Duration = .seconds(1),
        retirementStdinEOFGracePeriod: Duration =
            PersistentLLDBCLIAdapter.defaultRetirementStdinEOFGracePeriod,
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil
    ) {
        precondition(markerSecret.count >= 32, "The CLI marker secret must contain at least 256 bits.")
        precondition(shutdownStepTimeout > .zero, "Shutdown steps require a positive bound.")
        precondition(
            retirementStdinEOFGracePeriod > .zero,
            "Command-free retirement requires a positive stdin-EOF grace bound."
        )
        self.epoch = epoch
        self.channel = channel
        self.retainedProcess = retainedProcess
        self.clock = clock
        self.markerSecret = markerSecret
        self.shutdownStepTimeout = shutdownStepTimeout
        self.retirementStdinEOFGracePeriod = retirementStdinEOFGracePeriod
        self.inboundNeedleProbe = inboundNeedleProbe
        self.instanceBinding = PersistentLLDBCLIAdapterInstanceBinding(
            sessionEpoch: epoch,
            adapterGeneration: 1
        )
    }

    func adapterInstanceBinding() -> PersistentLLDBCLIAdapterInstanceBinding {
        instanceBinding
    }

    /// Called only after the coordinator has matched a prepared physical request to the exact
    /// operation context it admitted. No actor hop is needed: sealing reads only this adapter's
    /// immutable opaque authority, and writer selection later validates the same reference.
    nonisolated func sealOrdinaryWrite(
        _ request: PersistentLLDBCLIRequest
    ) throws -> PersistentLLDBCLIRequest {
        guard case .ordinary = request.writeRole,
              request.context.operation != .attach,
              !request.hasOrdinaryWriteAuthorization else {
            throw PersistentLLDBCLIAdapterFailure(
                code: .exactAttachWriteRejected,
                requestID: request.context.id,
                generation: instanceBinding.adapterGeneration,
                disposition: .failedBeforeWrite
            )
        }
        return request.sealingOrdinaryWrite(with: ordinaryWriteAuthority)
    }

    /// Single production dispatch choke for a coordinator-selected physical request. Exact attach
    /// roles retain their dedicated staging/final authorities; every ordinary role is sealed with
    /// this adapter's opaque identity immediately before entering the normal serialized executor.
    func executeCoordinatorSelected(
        _ request: PersistentLLDBCLIRequest
    ) async throws -> PersistentLLDBCLIResponse {
        switch request.writeRole {
        case .ordinary:
            return try await execute(sealOrdinaryWrite(request))
        case .exactAttachStaging, .exactAttachFinal:
            return try await execute(request)
        }
    }

    var state: PersistentLLDBCLIAdapterState {
        adapterState
    }

    var discardedLateByteCount: Int {
        lateByteCount
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        if Task.isCancelled {
            throw failure(
                code: .cancelledBeforeWrite,
                requestID: request.context.id,
                disposition: .cancelledBeforeWrite
            )
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(request, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.context.id) }
        }
    }

    func shutdown() async -> PersistentLLDBCLIShutdownReceipt {
        await shutdown(mode: .gracefulWhenHealthy)
    }

    /// Retires only the exact LLDB child retained by this adapter. This path deliberately writes no
    /// debugger command: it is safe to use after target disposition becomes unknown because neither
    /// `quit` nor any target lifecycle command can reach LLDB or the debug target.
    func retireRetainedAdapterWithoutDebuggerCommand() async -> PersistentLLDBCLIShutdownReceipt {
        await shutdown(mode: .retainedAdapterOnly)
    }

    /// Retires the adapter bound to coordinator-sealed exact-attach evidence. A proof is returned
    /// only when the evidence names this adapter epoch/generation and the command-free shutdown
    /// both observed process exit and completed reap. A prior graceful shutdown is diagnostic-only
    /// and can never be upgraded to command-free proof.
    func retireExactAttachedAdapterWithoutDebuggerCommand(
        boundTo attachedSession: PersistentLLDBExactAttachedSessionEvidence
    ) async -> PersistentLLDBCLIExactAttachedRetirementOutcome {
        let bindsThisAdapter = attachedSession.establishedSession.epoch == epoch
            && attachedSession.permit.adapterGeneration == currentGeneration
            && attachedSession.adapterInstanceBinding == instanceBinding
        let admittedQuiescent = queue.isEmpty && inFlight == nil && outstandingWrite == nil
        exactRetirementAdmissionClosed = true
        let pendingWrite = outstandingWrite
        let pendingWriteCompleted = await pendingWrite?.task.value ?? true
        if let pendingWrite,
           outstandingWrite?.token == pendingWrite.token {
            outstandingWrite = nil
        }
        let verifiedCommandQuiescence = admittedQuiescent
            && pendingWriteCompleted
            && queue.isEmpty
            && inFlight == nil
            && outstandingWrite == nil
        let receipt = await shutdown(mode: .retainedAdapterOnly)
        guard bindsThisAdapter,
              let proof = PersistentLLDBCLICommandFreeAdapterExitReapProof(
                  attachedSession: attachedSession,
                  receipt: receipt,
                  adapterInstanceBinding: instanceBinding,
                  verifiedCommandQuiescence: verifiedCommandQuiescence
              ) else {
            return .unproven(receipt)
        }
        return .proven(proof)
    }

    private func shutdown(mode: ShutdownMode) async -> PersistentLLDBCLIShutdownReceipt {
        if let shutdownReceipt {
            return shutdownReceipt
        }
        if shutdownInProgress {
            return await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        }

        let graceful = mode == .gracefulWhenHealthy && isHealthyAndIdle
        if !graceful, case .active = adapterState {
            invalidate(
                reason: .adapterFailure,
                activeCode: .invalidatedGeneration,
                scheduleShutdown: false
            )
        }
        shutdownInProgress = true

        var requestedGracefulQuit = false
        var sentTerminate = false
        var sentKill = false
        var didExit = false

        if graceful {
            requestedGracefulQuit = true
            try? await channel.write(Data("quit\n".utf8))
            await channel.closeInput()
            didExit = await retainedProcess.waitForExit(maximumDuration: shutdownStepTimeout)
        } else {
            // Command-free retirement: closing stdin is LLDB's own end-of-input exit path, during
            // which it kills and reaps any inferior it launched. Signalling LLDB first leaves that
            // inferior stopped (state T) and orphaned, so give LLDB a bounded grace period to exit
            // on its own and escalate to SIGTERM/SIGKILL only if it is still alive afterwards.
            await channel.closeInput()
            didExit = await retainedProcess.waitForExit(
                maximumDuration: retirementStdinEOFGracePeriod
            )
        }

        if !didExit {
            sentTerminate = true
            await retainedProcess.terminateRetainedAdapter()
            didExit = await retainedProcess.waitForExit(maximumDuration: shutdownStepTimeout)
        }
        if !didExit {
            sentKill = await retainedProcess.killRetainedAdapterIfStillRunning()
            didExit = await retainedProcess.waitForExit(maximumDuration: shutdownStepTimeout)
        }

        let didReap = await retainedProcess.reapAndClose()
        await channel.closeHandles()
        if case .active(let generation) = adapterState {
            adapterState = .closed(generation: generation)
        }
        let receipt = PersistentLLDBCLIShutdownReceipt(
            requestedGracefulQuit: requestedGracefulQuit,
            sentTerminate: sentTerminate,
            sentKill: sentKill,
            didExit: didExit,
            didReap: didReap
        )
        shutdownReceipt = receipt
        shutdownInProgress = false
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        waiters.forEach { $0.resume(returning: receipt) }
        return receipt
    }

    private var activeGeneration: UInt64? {
        guard case .active(let generation) = adapterState else { return nil }
        return generation
    }

    private var isHealthyAndIdle: Bool {
        activeGeneration != nil && inFlight == nil && queue.isEmpty
    }

    private func enqueue(
        _ request: PersistentLLDBCLIRequest,
        continuation: CheckedContinuation<PersistentLLDBCLIResponse, Error>
    ) {
        guard !exactRetirementAdmissionClosed,
              let generation = activeGeneration else {
            continuation.resume(
                throwing: failure(
                    code: .staleGeneration,
                    requestID: request.context.id,
                    disposition: .failedBeforeWrite
                )
            )
            return
        }
        if case .ordinary = request.writeRole,
           (request.context.operation == .attach
            || !request.hasExactOrdinaryWriteAuthorization(from: ordinaryWriteAuthority)) {
            continuation.resume(
                throwing: PersistentLLDBCLIAdapterFailure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            )
            return
        }
        guard request.context.id.epoch == epoch,
              request.context.expectedSession.epoch == epoch,
              request.context.isInternallyConsistent,
              request.context.id.sequence > lastAdmittedRequestSequence else {
            continuation.resume(
                throwing: PersistentLLDBCLIAdapterFailure(
                    code: .invalidRequest,
                    requestID: request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            )
            return
        }

        lastAdmittedRequestSequence = request.context.id.sequence
        queue.append(PendingRequest(request: request, continuation: continuation))
        startReadPumpIfNeeded(generation: generation)
        startNextRequestIfPossible()
    }

    private func startNextRequestIfPossible() {
        guard inFlight == nil,
              let generation = activeGeneration,
              !queue.isEmpty else { return }

        let pending = queue.removeFirst()
        do {
            let markers = try makeMarkers(for: pending.request.context.id, generation: generation)
            let wire = try makeWirePayload(for: pending.request, markers: markers)
            let exactAttachWriteCommit = try authorizeExactAttachWriteIfRequired(
                for: pending.request,
                generation: generation
            )
            var request = InFlightRequest(
                pending: pending,
                generation: generation,
                decoder: LLDBCLITranscriptDecoder(
                    markers: markers,
                    observedPIDRequirement: pending.request.observedPIDRequirement,
                    requiresSemanticCommandStatus: true,
                    expectedSemanticCommandCount: pending.request.semanticCommands.count
                ),
                exactAttachWriteCommit: exactAttachWriteCommit,
                timeoutTask: nil
            )
            let requestID = pending.request.context.id
            let duration = pending.request.timeout
            let clock = self.clock
            request.timeoutTask = Task {
                do {
                    try await clock.sleep(for: duration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.deadlineExpired(requestID: requestID, generation: generation)
            }
            inFlight = request

            let channel = self.channel
            let writeToken = UUID()
            let writeTask = Task { () -> Bool in
                do {
                    try await channel.write(wire)
                    return true
                } catch {
                    return false
                }
            }
            outstandingWrite = OutstandingWrite(
                token: writeToken,
                requestID: requestID,
                generation: generation,
                task: writeTask
            )
            Task {
                let succeeded = await writeTask.value
                self.writeCompleted(
                    token: writeToken,
                    requestID: requestID,
                    generation: generation,
                    succeeded: succeeded
                )
            }
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            pending.continuation.resume(throwing: failure)
            startNextRequestIfPossible()
        } catch {
            pending.continuation.resume(
                throwing: PersistentLLDBCLIAdapterFailure(
                    code: .invalidRequest,
                    requestID: pending.request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            )
            startNextRequestIfPossible()
        }
    }

    private func startReadPumpIfNeeded(generation: UInt64) {
        guard readPumpTask == nil else { return }
        let channel = self.channel
        readPumpTask = Task {
            do {
                while !Task.isCancelled {
                    guard let bytes = try await channel.nextBytes() else {
                        self.reachedEOF(generation: generation)
                        return
                    }
                    self.receive(bytes, generation: generation)
                }
            } catch {
                self.readFailed(generation: generation)
            }
        }
    }

    private func receive(_ bytes: Data, generation: UInt64) {
        inboundNeedleProbe?.observe(bytes)
        guard generation == activeGeneration,
              var active = inFlight,
              active.generation == generation else {
            lateByteCount = lateByteCount.addingSaturating(bytes.count)
            return
        }

        do {
            if let result = try active.decoder.append(bytes) {
                active.timeoutTask?.cancel()
                inFlight = nil
                active.pending.continuation.resume(
                    returning: PersistentLLDBCLIResponse(
                        requestID: active.pending.request.context.id,
                        generation: generation,
                        transcript: result,
                        exactAttachWriteCommit: active.exactAttachWriteCommit
                    )
                )
                startNextRequestIfPossible()
            } else {
                inFlight = active
            }
        } catch let failure as LLDBCLITranscriptFailure {
            let reason: DebuggerTransportInvalidationReason = failure.code == .exchangeTooLarge
                ? .oversizedTranscript
                : .framingLoss
            invalidate(
                reason: reason,
                activeCode: .invalidatedGeneration,
                transcriptDiagnosticCode: failure.code
            )
        } catch {
            invalidate(reason: .framingLoss, activeCode: .invalidatedGeneration)
        }
    }

    private func cancel(requestID: DebuggerRequestID) {
        if let queuedIndex = queue.firstIndex(where: { $0.request.context.id == requestID }) {
            let pending = queue.remove(at: queuedIndex)
            pending.continuation.resume(
                throwing: failure(
                    code: .cancelledBeforeWrite,
                    requestID: requestID,
                    disposition: .cancelledBeforeWrite
                )
            )
            return
        }
        guard inFlight?.pending.request.context.id == requestID else { return }
        invalidate(reason: .cancellationAfterWrite, activeCode: .invalidatedGeneration)
    }

    private func deadlineExpired(requestID: DebuggerRequestID, generation: UInt64) {
        guard activeGeneration == generation,
              inFlight?.pending.request.context.id == requestID else { return }
        invalidate(reason: .timeoutAfterWrite, activeCode: .invalidatedGeneration)
    }

    private func writeFailed(requestID: DebuggerRequestID, generation: UInt64) {
        guard activeGeneration == generation,
              inFlight?.pending.request.context.id == requestID else { return }
        invalidate(reason: .adapterFailure, activeCode: .invalidatedGeneration)
    }

    private func writeCompleted(
        token: UUID,
        requestID: DebuggerRequestID,
        generation: UInt64,
        succeeded: Bool
    ) {
        guard outstandingWrite?.token == token else { return }
        outstandingWrite = nil
        if !succeeded {
            writeFailed(requestID: requestID, generation: generation)
        }
    }

    private func reachedEOF(generation: UInt64) {
        guard activeGeneration == generation else { return }
        let reason: DebuggerTransportInvalidationReason = inFlight == nil
            ? .adapterFailure
            : .endOfFileAfterWrite
        invalidate(reason: reason, activeCode: .invalidatedGeneration)
    }

    private func readFailed(generation: UInt64) {
        guard activeGeneration == generation else { return }
        invalidate(reason: .adapterFailure, activeCode: .invalidatedGeneration)
    }

    private func invalidate(
        reason: DebuggerTransportInvalidationReason,
        activeCode: PersistentLLDBCLIAdapterFailureCode,
        scheduleShutdown: Bool = true,
        transcriptDiagnosticCode: LLDBCLITranscriptDiagnosticCode? = nil
    ) {
        guard let generation = activeGeneration else { return }
        adapterState = .invalidated(generation: generation)

        if let active = inFlight {
            active.timeoutTask?.cancel()
            active.pending.continuation.resume(
                throwing: PersistentLLDBCLIAdapterFailure(
                    code: activeCode,
                    requestID: active.pending.request.context.id,
                    generation: generation,
                    disposition: .invalidatedAfterWrite(reason: reason, target: .unknown),
                    transcriptDiagnosticCode: transcriptDiagnosticCode
                )
            )
            inFlight = nil
        }

        let stale = queue
        queue.removeAll()
        for pending in stale {
            pending.continuation.resume(
                throwing: PersistentLLDBCLIAdapterFailure(
                    code: .staleGeneration,
                    requestID: pending.request.context.id,
                    generation: generation,
                    disposition: .failedBeforeWrite
                )
            )
        }

        if scheduleShutdown {
            Task { _ = await self.shutdown() }
        }
    }

    private func failure(
        code: PersistentLLDBCLIAdapterFailureCode,
        requestID: DebuggerRequestID?,
        disposition: DebuggerRequestDisposition
    ) -> PersistentLLDBCLIAdapterFailure {
        PersistentLLDBCLIAdapterFailure(
            code: code,
            requestID: requestID,
            generation: activeGeneration ?? currentGeneration,
            disposition: disposition
        )
    }

    private var currentGeneration: UInt64 {
        switch adapterState {
        case .active(let generation), .invalidated(let generation), .closed(let generation):
            generation
        }
    }

    private func makeMarkers(
        for requestID: DebuggerRequestID,
        generation: UInt64
    ) throws -> LLDBCLIExchangeMarkers {
        var material = markerSecret
        material.append(contentsOf: epoch.rawValue.uuidString.utf8)
        material.append(contentsOf: String(generation).utf8)
        material.append(contentsOf: String(requestID.sequence).utf8)
        let token = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return try LLDBCLIExchangeMarkers(token: token)
    }

    /// Linearizes each canonical staging or final attach request against its exact one-shot
    /// authority after the wire has been constructed but before this actor records an in-flight
    /// request or creates a channel-write task. The method contains no suspension point, so
    /// cancellation cannot enter between authority consumption and the conservative
    /// post-consumption request state.
    private func authorizeExactAttachWriteIfRequired(
        for request: PersistentLLDBCLIRequest,
        generation: UInt64
    ) throws -> DebuggerLocalProcessAttachWriteCommit? {
        switch request.writeRole {
        case .ordinary:
            guard request.context.operation != .attach,
                  request.hasExactOrdinaryWriteAuthorization(from: ordinaryWriteAuthority) else {
                throw failure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    disposition: .failedBeforeWrite
                )
            }
            return nil
        case .exactAttachStaging(let authorization):
            guard let authorization,
                  request.context.operation == .attach,
                  request.observedPIDRequirement == .optional,
                  request.context.id.epoch == epoch,
                  request.context.expectedSession.epoch == epoch,
                  request.context == authorization.issuanceInput.stagingRequest,
                  generation == authorization.issuanceInput.permitAdapterGeneration,
                  instanceBinding == authorization.issuanceInput.adapterInstanceBinding,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                      semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == authorization.issuanceInput.semanticDigest else {
                throw failure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    disposition: .failedBeforeWrite
                )
            }
            do {
                try authorization.interlock.consumeExactAttachStagingWriteAuthorization(
                    authorization.authorization,
                    matching: authorization.issuanceInput
                )
                return nil
            } catch {
                throw failure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    disposition: .failedBeforeWrite
                )
            }
        case .exactAttachFinal(let authorization):
            guard let authorization,
                  request.context.operation == .attach,
                  request.observedPIDRequirement == .required,
                  request.context.id.epoch == epoch,
                  request.context.expectedSession.epoch == epoch,
                  request.context == authorization.issuanceInput.finalAttachRequest,
                  generation == authorization.issuanceInput.permitAdapterGeneration,
                  instanceBinding == authorization.issuanceInput.adapterInstanceBinding,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                      semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == authorization.issuanceInput.semanticDigest else {
                throw failure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    disposition: .failedBeforeWrite
                )
            }
            do {
                return try authorization.interlock.commitExactAttachWrite(
                    authorization.grant,
                    matching: authorization.issuanceInput
                )
            } catch {
                throw failure(
                    code: .exactAttachWriteRejected,
                    requestID: request.context.id,
                    disposition: .failedBeforeWrite
                )
            }
        }
    }

    private func makeWirePayload(
        for request: PersistentLLDBCLIRequest,
        markers: LLDBCLIExchangeMarkers
    ) throws -> Data {
        let payload = Self.encodedWirePayload(
            semanticCommands: request.semanticCommands,
            markers: markers
        )
        guard payload.count <= LLDBCLITranscriptDecoder.maximumCommandBytes else {
            throw PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: request.context.id,
                generation: currentGeneration,
                disposition: .failedBeforeWrite
            )
        }
        return payload
    }

    nonisolated static func encodedWirePayload(
        semanticCommands: [String],
        markers: LLDBCLIExchangeMarkers
    ) -> Data {
        let commandsData = try! JSONEncoder().encode(semanticCommands)
        let commandsBase64 = commandsData.base64EncodedString()
        let hasNativeRunControl = semanticCommands.contains {
            switch $0 {
            case "process continue", "process interrupt", "process kill",
                 "thread step-over", "thread step-in", "thread step-out":
                true
            default:
                false
            }
        }
        let nativeDefinitions = hasNativeRunControl
            ? "a={'process continue':'Continue','process interrupt':'Stop','process kill':'Kill'};v={'thread step-over':'StepOver','thread step-in':'StepInto','thread step-out':'StepOut'}"
            : ""
        let dispatch = (hasNativeRunControl
            ? [
                "        if x in a or x in v:",
                "            d=lldb.debugger;e=lldb.SBError()",
                "            try:",
                "                p=d.GetSelectedTarget().GetProcess()",
                "                if not d.GetAsync():e.SetErrorString(x)",
                "                elif not p.IsValid():e.SetErrorString(x)",
                "                elif x in a:e=getattr(p,a[x])()",
                "                else:",
                "                    e=lldb.SBError();h=p.GetSelectedThread()",
                "                    if not h.IsValid():e.SetErrorString(x)",
                "                    elif x=='thread step-over':h.StepOver(lldb.eOnlyDuringStepping,e)",
                "                    elif x=='thread step-in':h.StepInto(None,0,e,lldb.eOnlyDuringStepping)",
                "                    else:h.StepOut(e)",
                "            except Exception as k:e=lldb.SBError();e.SetErrorString(str(k))",
                "            if e.Fail():r.SetError(e.GetCString() or x)",
                "            else:r.SetStatus(lldb.eReturnStatusSuccessFinishNoResult)",
                "        elif x.startswith('script '):",
                "            with c.redirect_stdout(s),c.redirect_stderr(s):i.HandleCommand(x,r)",
                "        else:i.HandleCommand(x,r)",
            ]
            : [
                "        if x.startswith('script '):",
                "            with c.redirect_stdout(s),c.redirect_stderr(s):i.HandleCommand(x,r)",
                "        else:i.HandleCommand(x,r)",
            ])
            .joined(separator: "\n")
        // The compact local names keep the complete correlated wire under its frozen 4 KiB
        // ceiling. The function scope prevents a nested `script` command from overwriting wrapper
        // state in LLDB's shared Python globals. Nested Python output is redirected into the
        // correlated transcript; run control uses direct SB APIs in the startup-proven asynchronous
        // mode to avoid interpreter reentrancy while target output remains on LLDB's native stream.
        //
        // The status readback names the selected target's CURRENT process explicitly. LLDB pins
        // the interpreter's execution context for the whole outer `script` command, so a plain
        // `HandleCommand('process status')` after an in-exchange `process launch` still sees the
        // pre-launch, process-less context ("Command requires a current process.") even though
        // the target is stopped at entry. The decoder then found no PID and invalidated the
        // adapter, so every Launch Target failed with `adapterInvalidated` (lldb-2103, Xcode 27).
        let program = """
        import base64 as b,contextlib as c,io,json,lldb
        q=json.loads(b.b64decode('\(commandsBase64)').decode())
        i=lldb.debugger.GetCommandInterpreter()
        \(nativeDefinitions)
        def z(q,i):
            f=None;E=lambda t:b.b64encode(t.encode('utf-8','backslashreplace')).decode()
            for n,x in enumerate(q):
                r=lldb.SBCommandReturnObject()
                s=io.StringIO()
        \(dispatch)
                t=(r.GetOutput() or '')+s.getvalue()+(r.GetError() or '')
                print(f'\(markers.commandResultPrefix){n}_{E(t)}__')
                if not r.Succeeded():f=n;break
            print('\(markers.commandsSucceededLine)' if f is None else f'\(markers.commandsFailedPrefix){f}__')
            print('\(markers.statusBeginLine)')
            r=lldb.SBCommandReturnObject();i.HandleCommand('process status',lldb.SBExecutionContext(lldb.debugger.GetSelectedTarget().process),r)
            t=(r.GetOutput()or'')+(r.GetError()or'')
            print('\(markers.statusResultPrefix)'+E(t)+'__\\n\(markers.statusEndLine)\\n\(markers.requestEndLine)')
        z(q,i)
        """
        let programBase64 = Data(program.utf8).base64EncodedString()
        let execute = "script exec(__import__('base64').b64decode('\(programBase64)').decode('utf-8'))"
        let lines = [markerPrintCommand(markers.requestBeginLine), execute]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    nonisolated private static func markerPrintCommand(_ marker: String) -> String {
        // LLDB echoes commands received on piped stdin even when
        // `interpreter.echo-commands` is disabled. Keep the unpredictable framing marker out of
        // that echoed command so only the trusted Python evaluation emits marker-family text.
        let encoded = Data(marker.utf8).base64EncodedString()
        return "script print(__import__('base64').b64decode('\(encoded)').decode('ascii'))"
    }

    /// How long command-free retirement waits, after closing LLDB's stdin, for LLDB to exit on its
    /// own (cleaning up any inferior it launched) before it signals the retained LLDB child.
    nonisolated static let defaultRetirementStdinEOFGracePeriod: Duration = .seconds(2)

    nonisolated private static func makeMarkerSecret() -> Data {
        let entropy = UUID().uuidString + UUID().uuidString
        return Data(SHA256.hash(data: Data(entropy.utf8)))
    }
}

private extension Int {
    func addingSaturating(_ other: Int) -> Int {
        let (sum, overflowed) = addingReportingOverflow(other)
        return overflowed ? .max : sum
    }
}
