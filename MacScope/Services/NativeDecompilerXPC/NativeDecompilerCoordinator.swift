import Foundation
import OSLog

struct NativeDecompilerRuntimePolicy: Equatable, Sendable {
    static let environmentKey = "MACSCOPE_NATIVE_DECOMPILER_ENABLED"
    static let defaultsKey = "nativeDecompiler.enabled"
    static let enabled = NativeDecompilerRuntimePolicy(isEnabled: true)
    static let disabled = NativeDecompilerRuntimePolicy(isEnabled: false)

    let isEnabled: Bool

    static func productPolicy(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultsValue: Bool? = nil
    ) -> NativeDecompilerRuntimePolicy {
        if let rawValue = environment[environmentKey] {
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["0", "false", "no", "off"].contains(normalized) {
                return .disabled
            }
            if ["1", "true", "yes", "on"].contains(normalized) {
                return .enabled
            }
            return .enabled
        }
        return NativeDecompilerRuntimePolicy(isEnabled: defaultsValue ?? true)
    }
}

/// A request-shaped value snapshot whose correlation UUID is deliberately rebound by the client.
/// Copying the wire values here prevents a later caller mutation from changing native input.
struct NativeDecompilerRequestProjection: Equatable, Sendable {
    private let request: NativeDecompilerWireRequest
    private let requestSchemaVersion: UInt32
    /// `decompile-document` asks for the pseudocode document only (bound into the digest).
    let operation: NativeDecompilerWireRequestOperation
    /// App-side request identity beyond the wire digest: the explicit context omission set.
    let contextOmissions: NativeDecompilerContextOmissionManifest

    init(
        request: NativeDecompilerWireRequest,
        operation: NativeDecompilerWireRequestOperation = .decompile,
        contextOmissions: NativeDecompilerContextOmissionManifest = .empty
    ) {
        self.request = request
        self.operation = operation
        requestSchemaVersion = request.function.codeRanges == nil
            ? NativeDecompilerWireRequestEnvelope.currentSchemaVersion
            : NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion
        self.contextOmissions = contextOmissions
    }

    init(snapshotProjection snapshot: NativeDecompilerSnapshotProjection,
         operation: NativeDecompilerWireRequestOperation = .decompile) throws {
        self.operation = operation
        let budgets = NativeDecompilerProductBudgetProfile.productDefault
        let schemaVersion = snapshot.function.codeRanges == nil
            ? NativeDecompilerWireRequestEnvelope.currentSchemaVersion
            : NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion
        let requestSHA256 = try NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: schemaVersion,
            operation: operation,
            target: snapshot.target,
            image: snapshot.image,
            function: snapshot.function,
            memoryRegions: snapshot.memoryRegions,
            symbols: snapshot.symbols,
            authoredInputs: snapshot.authoredInputs,
            budgets: budgets
        )
        request = NativeDecompilerWireRequest(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            requestSHA256: requestSHA256,
            target: snapshot.target,
            image: snapshot.image,
            function: snapshot.function,
            memoryRegions: snapshot.memoryRegions,
            symbols: snapshot.symbols,
            authoredInputs: snapshot.authoredInputs,
            budgets: budgets.wireValue
        )
        requestSchemaVersion = schemaVersion
        contextOmissions = snapshot.contextOmissions
    }

    var image: NativeDecompilerWireImageIdentity { request.image }
    var function: NativeDecompilerWireFunctionIdentity { request.function }
    var requestSHA256: String { request.requestSHA256 }
    var contextOmissionSHA256: String { contextOmissions.identitySHA256 }
    var target: NativeDecompilerWireTarget { request.target }
    var schemaVersion: UInt32 { requestSchemaVersion }

    func makeRequestEnvelope(requestID: UUID) -> NativeDecompilerWireRequestEnvelope {
        let reboundRequest = NativeDecompilerWireRequest(
            requestID: requestID,
            requestSHA256: request.requestSHA256,
            target: request.target,
            image: request.image,
            function: request.function,
            memoryRegions: request.memoryRegions,
            symbols: request.symbols,
            authoredInputs: request.authoredInputs,
            budgets: request.budgets
        )
        return NativeDecompilerWireRequestEnvelope(
            schemaVersion: requestSchemaVersion, requestID: requestID, operation: operation,
            body: reboundRequest
        )
    }
}

/// One immutable request whose exact encoded bytes are simultaneously the transport
/// payload, the reply-binding authority, and the process-runtime queued-weight charge.
struct NativeDecompilerPreencodedDispatchRequest: Equatable, Sendable {
    let envelope: NativeDecompilerWireRequestEnvelope
    let payload: Data
    let expectedBinding: NativeDecompilerWireExpectedRequestBinding

    var requestID: UUID { envelope.requestID }
    var encodedByteCount: UInt64 { UInt64(payload.count) }

    init(
        projection: NativeDecompilerRequestProjection,
        requestID: UUID = UUID(),
        codec: NativeDecompilerWireCodec = .init()
    ) throws {
        let envelope = projection.makeRequestEnvelope(requestID: requestID)
        do {
            payload = try codec.encodeRequest(envelope, matching: requestID)
        } catch NativeDecompilerWireCodecError.requestTooLarge {
            throw NativeDecompilerSnapshotProjectionError.requestTooLarge
        } catch {
            throw NativeDecompilerSnapshotProjectionError.invalidProjectedRequest
        }
        self.envelope = envelope
        expectedBinding = NativeDecompilerWireExpectedRequestBinding(request: envelope)
    }
}

struct NativeDecompilerReferenceCounts: Equatable, Sendable {
    let instructions: Int?
    let blocks: Int?
    let edges: Int?
    let calls: Int?

    init(
        instructions: Int? = nil,
        blocks: Int? = nil,
        edges: Int? = nil,
        calls: Int? = nil
    ) {
        self.instructions = instructions
        self.blocks = blocks
        self.edges = edges
        self.calls = calls
    }
}

struct NativeDecompilerSubmission: Equatable, Sendable {
    let projection: NativeDecompilerRequestProjection
    let dispatchRequest: NativeDecompilerPreencodedDispatchRequest
    let analysisInputFingerprintSHA256: String?
    let elapsedTimeBudget: Duration?
    let referenceCounts: NativeDecompilerReferenceCounts

    init(
        projection: NativeDecompilerRequestProjection,
        requestID: UUID = UUID(),
        analysisInputFingerprintSHA256: String? = nil,
        elapsedTimeBudget: Duration? = nil,
        referenceCounts: NativeDecompilerReferenceCounts = .init()
    ) throws {
        self.projection = projection
        dispatchRequest = try NativeDecompilerPreencodedDispatchRequest(
            projection: projection,
            requestID: requestID
        )
        self.analysisInputFingerprintSHA256 = analysisInputFingerprintSHA256
        self.elapsedTimeBudget = elapsedTimeBudget
        self.referenceCounts = referenceCounts
    }
}

/// Implementations must honor Swift task cancellation while a request is in flight. The
/// coordinator rejects a cancelled generation before entry and suppresses any late completion,
/// while the dispatcher owns cancellation of transport work already admitted.
protocol NativeDecompilerDispatching: Sendable {
    func decompile(
        request: NativeDecompilerPreencodedDispatchRequest,
        elapsedTimeBudget: Duration?
    ) async throws -> NativeDecompilerWireReplyEnvelope
}

extension NativeDecompilerXPCClient: NativeDecompilerDispatching {}

struct NativeDecompilerRecordCounts: Equatable, Sendable {
    let addressSpaces: Int
    let types: Int
    let instructions: Int
    let varnodes: Int
    let operations: Int
    let blocks: Int
    let edges: Int
    let ssaValues: Int
    let ssaBindings: Int
    let phis: Int
    let memoryVersions: Int
    let memoryPhis: Int
    let memoryEffects: Int
    let variables: Int
    let calls: Int
    let regions: Int
    let tokens: Int
    let warnings: Int

    init(result: NativeDecompilerWireStructuredResult) {
        addressSpaces = result.addressSpaces.count
        types = result.types.count
        instructions = result.instructions.count
        varnodes = result.varnodes.count
        operations = result.operations.count
        blocks = result.blocks.count
        edges = result.edges.count
        ssaValues = result.ssaValues.count
        ssaBindings = result.ssaBindings.count
        phis = result.phis.count
        memoryVersions = result.memoryVersions.count
        memoryPhis = result.memoryPhis.count
        memoryEffects = result.memoryEffects.count
        variables = result.variables.count
        calls = result.calls.count
        regions = result.regions.count
        tokens = result.tokens.count
        warnings = result.warnings.count
    }
}

enum NativeDecompilerMismatchCategory: String, CaseIterable, Equatable, Sendable {
    case instructionCount
    case blockCount
    case edgeCount
    case callCount
}

enum NativeDecompilerTerminalStatus: Equatable, Sendable {
    case success
    case providerFailure(NativeDecompilerWireFailureCode)
    case clientFailure(NativeDecompilerXPCClientFailure)
    case invalidReply
    case transportFailure

    fileprivate var logCode: String {
        switch self {
        case .success:
            "success"
        case let .providerFailure(code):
            "provider-\(code.rawValue)"
        case let .clientFailure(code):
            "client-\(code.rawValue)"
        case .invalidReply:
            "invalid-reply"
        case .transportFailure:
            "transport-failure"
        }
    }
}

enum NativeDecompilerCompletion: Equatable, Sendable {
    case ready(NativeDecompilerWireSuccess)
    case terminal(NativeDecompilerPresentationTerminalReason)
}

enum NativeDecompilerCoordinatorExecutionError: Error, Equatable, Sendable {
    case notAccepted
}

/// Cancellation-safe one-shot bridge from the coordinator's callback surface to the process
/// runtime's structured async operation. Cancellation may win before coordinator admission,
/// while native work is running, or after completion; exactly one result resumes the waiter.
private final class NativeDecompilerCompletionBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NativeDecompilerCompletion, any Error>?
    private var pendingResult: Result<NativeDecompilerCompletion, any Error>?
    private var isResolved = false

    func install(
        _ continuation: CheckedContinuation<NativeDecompilerCompletion, any Error>
    ) {
        let pending: Result<NativeDecompilerCompletion, any Error>? = lock.withLock {
            precondition(self.continuation == nil)
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func resolve(_ result: Result<NativeDecompilerCompletion, any Error>) {
        let continuation: CheckedContinuation<NativeDecompilerCompletion, any Error>? =
            lock.withLock {
                guard !isResolved else { return nil }
                isResolved = true
                guard let continuation = self.continuation else {
                    pendingResult = result
                    return nil
                }
                self.continuation = nil
                return continuation
            }
        continuation?.resume(with: result)
    }
}

struct NativeDecompilerFunctionMetadata: Equatable, Sendable {
    let functionID: String
    let entryAddress: NativeDecompilerWireUInt64
    let endAddressExclusive: NativeDecompilerWireUInt64
}

struct NativeDecompilerProviderMetadata: Equatable, Sendable {
    let backendID: String
    let engineVersion: String
    let engineGitRevision: String
    let wrapperVersion: String
    let wrapperGitRevision: String
}

struct NativeDecompilerObservation: Equatable, Sendable {
    let requestID: UUID?
    let imageUUID: UUID
    let function: NativeDecompilerFunctionMetadata
    let provider: NativeDecompilerProviderMetadata?
    let capabilities: NativeDecompilerWireBackendCapabilities?
    let durationMilliseconds: UInt64
    let status: NativeDecompilerTerminalStatus
    let recordCounts: NativeDecompilerRecordCounts?
    let mismatchCategories: [NativeDecompilerMismatchCategory]
}

/// This is the entire operational logging payload. It intentionally cannot carry paths, binary
/// bytes, symbols, diagnostics, pseudocode, or provider-rendered content.
struct NativeDecompilerLogRecord: Equatable, Sendable {
    let requestID: UUID?
    let imageUUID: UUID
    let durationMilliseconds: UInt64
    let statusCode: String
    let mismatchCount: Int
}

struct NativeDecompilerCoordinatorConfiguration: Equatable, Sendable {
    let maximumObservations: Int
    let maximumMismatchCategories: Int
    let maximumIdentifierUTF8Bytes: Int
    let maximumGeneration: UInt64

    init(
        maximumObservations: Int = 128,
        maximumMismatchCategories: Int = NativeDecompilerMismatchCategory.allCases.count,
        maximumIdentifierUTF8Bytes: Int = 256,
        maximumGeneration: UInt64 = .max
    ) {
        precondition(maximumObservations > 0)
        precondition(maximumMismatchCategories >= 0)
        precondition(maximumIdentifierUTF8Bytes > 0)
        precondition(maximumGeneration > 0)
        self.maximumObservations = maximumObservations
        self.maximumMismatchCategories = maximumMismatchCategories
        self.maximumIdentifierUTF8Bytes = maximumIdentifierUTF8Bytes
        self.maximumGeneration = maximumGeneration
    }
}

/// Session-owned monotonic fence that linearizes workspace-generation replacement before the
/// runtime crosses into the coordinator actor. Actor messages from unrelated tasks are not FIFO,
/// so task cancellation and a registry-side generation check alone cannot prevent an older
/// landing from reaching coordinator admission after its replacement.
final class NativeDecompilerAdmissionFence: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumGeneration: UInt64
    private var generation: UInt64
    private var isRevoked = false

    init(generation: UInt64 = 0, maximumGeneration: UInt64 = .max) {
        precondition(maximumGeneration > 0)
        precondition(generation <= maximumGeneration)
        self.maximumGeneration = maximumGeneration
        self.generation = generation
    }

    func advance() -> NativeDecompilerAdmissionToken? {
        lock.withLock {
            guard !isRevoked, generation < maximumGeneration else { return nil }
            generation += 1
            return NativeDecompilerAdmissionToken(fence: self, generation: generation)
        }
    }

    /// Terminally close the fence when its counter cannot advance for retirement.
    func revoke() {
        lock.withLock { isRevoked = true }
    }

    fileprivate func admits(_ candidate: UInt64) -> Bool {
        lock.withLock { !isRevoked && generation == candidate }
    }
}

struct NativeDecompilerAdmissionToken: Sendable {
    fileprivate let fence: NativeDecompilerAdmissionFence
    let generation: UInt64

    var isCurrent: Bool {
        fence.admits(generation)
    }
}

actor NativeDecompilerCoordinator {
    typealias MonotonicNanoseconds = @Sendable () -> UInt64
    typealias LogSink = @Sendable (NativeDecompilerLogRecord) -> Void
    typealias CompletionSink = @Sendable (NativeDecompilerCompletion) async -> Void
    /// Synchronization-only observer for focused admission-race tests. It receives no request,
    /// snapshot, binding, provider result, or product state.
    typealias DispatchAdmission = @Sendable () async -> Void

    private enum CompletionOutcome: Sendable {
        case reply(NativeDecompilerWireReplyEnvelope)
        case failure(NativeDecompilerTerminalStatus)
    }

    private let policy: NativeDecompilerRuntimePolicy
    private let dispatcher: any NativeDecompilerDispatching
    private let configuration: NativeDecompilerCoordinatorConfiguration
    private let monotonicNanoseconds: MonotonicNanoseconds
    private let logSink: LogSink
    private let dispatchAdmission: DispatchAdmission
    private var generation: UInt64 = 0
    private var isGenerationExhausted = false
    private var activeTask: Task<Void, Never>?
    private var activeOwnerToken: UUID?
    private var observations: [NativeDecompilerObservation] = []

    init(
        policy: NativeDecompilerRuntimePolicy = .disabled,
        dispatcher: any NativeDecompilerDispatching,
        configuration: NativeDecompilerCoordinatorConfiguration = .init(),
        monotonicNanoseconds: @escaping MonotonicNanoseconds = {
            DispatchTime.now().uptimeNanoseconds
        },
        logSink: @escaping LogSink = NativeDecompilerOperationalLogger.record,
        dispatchAdmission: @escaping DispatchAdmission = {}
    ) {
        self.policy = policy
        self.dispatcher = dispatcher
        self.configuration = configuration
        self.monotonicNanoseconds = monotonicNanoseconds
        self.logSink = logSink
        self.dispatchAdmission = dispatchAdmission
    }

    @discardableResult
    func submit(
        _ submission: NativeDecompilerSubmission,
        ownerToken: UUID? = nil,
        admissionToken: NativeDecompilerAdmissionToken? = nil,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity? = nil,
        completionSink: CompletionSink? = nil
    ) -> Bool {
        guard policy.isEnabled, !isGenerationExhausted,
              admissionToken?.isCurrent ?? true else { return false }

        guard advanceGeneration() else {
            isGenerationExhausted = true
            activeTask?.cancel()
            activeTask = nil
            activeOwnerToken = nil
            return false
        }
        let submittedGeneration = generation
        activeTask?.cancel()
        activeOwnerToken = ownerToken
        let dispatcher = self.dispatcher
        let monotonicNanoseconds = self.monotonicNanoseconds
        let dispatchAdmission = self.dispatchAdmission
        let capture = NativeDecompilerRequestCapture()
        capture.record(submission.dispatchRequest.envelope)

        activeTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await dispatchAdmission()
            guard !Task.isCancelled else { return }
            let start = monotonicNanoseconds()
            let outcome: CompletionOutcome
            do {
                guard !Task.isCancelled else { return }
                let reply = try await dispatcher.decompile(
                    request: submission.dispatchRequest,
                    elapsedTimeBudget: submission.elapsedTimeBudget
                )
                outcome = .reply(reply)
            } catch let failure as NativeDecompilerXPCClientFailure {
                outcome = .failure(.clientFailure(failure))
            } catch {
                outcome = .failure(.transportFailure)
            }
            let end = monotonicNanoseconds()
            await self?.finish(
                submission: submission,
                generation: submittedGeneration,
                capture: capture.snapshot,
                durationNanoseconds: Self.elapsedNanoseconds(from: start, to: end),
                outcome: outcome,
                expectedRuntimeIdentity: expectedRuntimeIdentity,
                completionSink: completionSink
            )
        }
        return true
    }

    /// Executes one scheduler-approved operation and makes task cancellation terminate only that
    /// operation token. The fair process runtime is the sole production caller; direct `submit`
    /// remains available to focused coordinator tests.
    func perform(
        _ submission: NativeDecompilerSubmission,
        executionToken: UUID,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity
    ) async throws -> NativeDecompilerCompletion {
        let bridge = NativeDecompilerCompletionBridge()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                bridge.install(continuation)
                let accepted = submit(
                    submission,
                    ownerToken: executionToken,
                    expectedRuntimeIdentity: expectedRuntimeIdentity,
                    completionSink: { completion in
                        bridge.resolve(.success(completion))
                    }
                )
                if !accepted {
                    bridge.resolve(
                        .failure(NativeDecompilerCoordinatorExecutionError.notAccepted)
                    )
                }
            }
        } onCancel: {
            bridge.resolve(.failure(CancellationError()))
            Task { await self.cancel(ownerToken: executionToken) }
        }
    }

    func cancel() {
        guard advanceGeneration() else {
            isGenerationExhausted = true
            activeTask?.cancel()
            activeTask = nil
            activeOwnerToken = nil
            return
        }
        activeTask?.cancel()
        activeTask = nil
        activeOwnerToken = nil
    }

    /// Cancels only the submission currently owned by `ownerToken`. Keeping ownership beside the
    /// coordinator generation makes admission and cancellation one actor-atomic decision; a late
    /// window invalidation cannot cancel a newer request that another window now owns.
    func cancel(
        ownerToken: UUID,
        admissionToken: NativeDecompilerAdmissionToken? = nil
    ) {
        guard admissionToken?.isCurrent ?? true else { return }
        guard activeOwnerToken == ownerToken else { return }
        cancel()
    }

    func observationSnapshot() -> [NativeDecompilerObservation] {
        observations
    }

    private func advanceGeneration() -> Bool {
        guard generation < configuration.maximumGeneration else { return false }
        generation += 1
        return true
    }

    private func finish(
        submission: NativeDecompilerSubmission,
        generation submittedGeneration: UInt64,
        capture: NativeDecompilerRequestCapture.Snapshot,
        durationNanoseconds: UInt64,
        outcome: CompletionOutcome,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity?,
        completionSink: CompletionSink?
    ) async {
        guard submittedGeneration == generation, !Task.isCancelled else { return }
        activeTask = nil
        activeOwnerToken = nil

        let result = makeObservation(
            submission: submission,
            capture: capture,
            durationMilliseconds: durationNanoseconds / 1_000_000,
            outcome: outcome,
            expectedRuntimeIdentity: expectedRuntimeIdentity
        )
        let observation = result.observation
        observations.append(observation)
        let overflow = observations.count - configuration.maximumObservations
        if overflow > 0 { observations.removeFirst(overflow) }

        logSink(NativeDecompilerLogRecord(
            requestID: observation.requestID,
            imageUUID: observation.imageUUID,
            durationMilliseconds: observation.durationMilliseconds,
            statusCode: observation.status.logCode,
            mismatchCount: observation.mismatchCategories.count
        ))
        await completionSink?(result.completion)
    }

    private struct ObservedCompletion: Sendable {
        let observation: NativeDecompilerObservation
        let completion: NativeDecompilerCompletion
    }

    private func makeObservation(
        submission: NativeDecompilerSubmission,
        capture: NativeDecompilerRequestCapture.Snapshot,
        durationMilliseconds: UInt64,
        outcome: CompletionOutcome,
        expectedRuntimeIdentity: NativeDecompilerRuntimeIdentity? = nil
    ) -> ObservedCompletion {
        let function = NativeDecompilerFunctionMetadata(
            functionID: bounded(submission.projection.function.functionID),
            entryAddress: submission.projection.function.entryAddress,
            endAddressExclusive: submission.projection.function.endAddressExclusive
        )
        let failureBase: (NativeDecompilerTerminalStatus) -> ObservedCompletion = {
            status in
            ObservedCompletion(
                observation: NativeDecompilerObservation(
                    requestID: capture.request?.requestID,
                    imageUUID: submission.projection.image.uuid,
                    function: function,
                    provider: nil,
                    capabilities: nil,
                    durationMilliseconds: durationMilliseconds,
                    status: status,
                    recordCounts: nil,
                    mismatchCategories: []
                ),
                completion: .terminal(Self.presentationReason(for: status))
            )
        }

        switch outcome {
        case let .failure(status):
            return failureBase(status)
        case let .reply(reply):
            guard let request = capture.request, reply.requestID == request.requestID else {
                return failureBase(.invalidReply)
            }
            switch reply.outcome {
            case .success:
                guard reply.failure == nil,
                      let success = reply.success,
                      success.availability.available,
                      expectedRuntimeIdentity.map({
                        success.availability.runtimeIdentity == $0
                      }) ?? true,
                      isBound(success.result, to: request)
                else {
                    return failureBase(.invalidReply)
                }
                let counts = NativeDecompilerRecordCounts(result: success.result)
                let identity = success.availability.runtimeIdentity
                return ObservedCompletion(
                    observation: NativeDecompilerObservation(
                        requestID: request.requestID,
                        imageUUID: submission.projection.image.uuid,
                        function: function,
                        provider: NativeDecompilerProviderMetadata(
                            backendID: bounded(identity.backendID),
                            engineVersion: bounded(identity.engineVersion),
                            engineGitRevision: bounded(identity.engineRevision),
                            wrapperVersion: bounded(identity.wrapperVersion),
                            wrapperGitRevision: bounded(identity.wrapperRevision)
                        ),
                        capabilities: success.availability.capabilities,
                        durationMilliseconds: durationMilliseconds,
                        status: .success,
                        recordCounts: counts,
                        mismatchCategories: mismatchCategories(
                            reference: submission.referenceCounts,
                            native: counts
                        )
                    ),
                    completion: .ready(success)
                )
            case .failure:
                guard reply.success == nil, let failure = reply.failure else {
                    return failureBase(.invalidReply)
                }
                // Keep the provider's own failure detail (bounded, single line) so
                // reports can name the real cause, not only the failure class.
                let base = failureBase(.providerFailure(failure.code))
                return ObservedCompletion(observation: base.observation, completion: .terminal(
                    .provider(failure.code, detail: Self.boundedFailureDetail(failure.detail))))
            }
        }
    }

    /// Printable ASCII, one line, at most 160 bytes; nil when nothing usable remains.
    static func boundedFailureDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let printable = String(detail.unicodeScalars.prefix(160).map { scalar -> Character in
            (0x21...0x7e).contains(scalar.value) ? Character(scalar) : "_"
        })
        return printable.isEmpty ? nil : printable
    }

    private static func presentationReason(
        for status: NativeDecompilerTerminalStatus
    ) -> NativeDecompilerPresentationTerminalReason {
        switch status {
        case let .providerFailure(code):
            .provider(code)
        case let .clientFailure(code):
            .client(code)
        case .invalidReply:
            .invalidReply
        case .transportFailure:
            .transportFailure
        case .success:
            preconditionFailure("success is represented by NativeDecompilerCompletion.ready")
        }
    }

    private func isBound(
        _ result: NativeDecompilerWireStructuredResult,
        to request: NativeDecompilerWireRequestEnvelope
    ) -> Bool {
        result.requestID == request.requestID
            && result.requestSHA256 == request.body.requestSHA256
            && result.image == request.body.image
            && result.function == request.body.function
    }

    private func mismatchCategories(
        reference: NativeDecompilerReferenceCounts,
        native: NativeDecompilerRecordCounts
    ) -> [NativeDecompilerMismatchCategory] {
        var mismatches: [NativeDecompilerMismatchCategory] = []
        if let expected = reference.instructions, expected != native.instructions {
            mismatches.append(.instructionCount)
        }
        if let expected = reference.blocks, expected != native.blocks {
            mismatches.append(.blockCount)
        }
        if let expected = reference.edges, expected != native.edges {
            mismatches.append(.edgeCount)
        }
        if let expected = reference.calls, expected != native.calls {
            mismatches.append(.callCount)
        }
        return Array(mismatches.prefix(configuration.maximumMismatchCategories))
    }

    private func bounded(_ value: String) -> String {
        let limit = configuration.maximumIdentifierUTF8Bytes
        guard value.utf8.count > limit else { return value }
        var bytes = Array(value.utf8.prefix(limit))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            bytes.removeLast()
        }
        return ""
    }

    private static func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

private enum NativeDecompilerOperationalLogger {
    private static let logger = Logger(
        subsystem: "org.macscope.MacScope",
        category: "NativeDecompiler"
    )

    static func record(_ record: NativeDecompilerLogRecord) {
        let requestID = record.requestID?.uuidString ?? "none"
        logger.info(
            "native request=\(requestID, privacy: .private(mask: .hash)) image=\(record.imageUUID.uuidString, privacy: .private(mask: .hash)) status=\(record.statusCode, privacy: .private(mask: .hash)) duration-ms=\(record.durationMilliseconds, privacy: .private(mask: .hash)) mismatches=\(record.mismatchCount, privacy: .private(mask: .hash))"
        )
    }
}

private final class NativeDecompilerRequestCapture: @unchecked Sendable {
    struct Snapshot: Sendable {
        let request: NativeDecompilerWireRequestEnvelope?
    }

    private let lock = NSLock()
    private var request: NativeDecompilerWireRequestEnvelope?

    var snapshot: Snapshot {
        lock.withLock { Snapshot(request: request) }
    }

    func record(_ request: NativeDecompilerWireRequestEnvelope) {
        lock.withLock { self.request = request }
    }
}
