import Foundation
import Dispatch

@MainActor
protocol NativeDecompilerWorkspaceSessionHandling: AnyObject, Sendable {
    func submit(_ submission: NativeDecompilerWorkspaceSubmission)
    func retry(_ retry: NativeDecompilerWorkspaceRetry)
    func publishAuthoredProjectionFailure(
        _ diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    )
    func cancelOutstanding()
    func terminateSession()
}

struct NativeDecompilerWorkspaceSubmission: Sendable {
    let ticket: NativeDriveSubmissionTicket
    let snapshot: WorkspaceSnapshot
    let snapshotRevision: UUID
    let imageSlot: ImageSlot
    let functionID: UUID
    let cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
}

struct NativeDecompilerWorkspaceRetry: Sendable {
    let frozenTicket: NativeDriveSubmissionTicket
    let snapshot: WorkspaceSnapshot
    let snapshotRevision: UUID
    let imageSlot: ImageSlot
    let functionID: UUID
}

/// One verified image value per window owner. A revision is minted by WorkspaceStore on
/// every snapshot write, so a digest supplied by a later snapshot cannot authorize reuse.
actor NativeDecompilerValidatedImageStore {
    private struct Entry {
        let revision: UUID
        let imageSlot: ImageSlot
        let image: NativeDecompilerSnapshotBuilder.ValidatedImage
    }
    private var entries: [UUID: Entry] = [:]
    private var validations = 0
    private let maximumOwners = 4
    private let maximumRetainedBytes = 64 * 1_048_576

    func capture(
        owner: UUID, revision: UUID, snapshot: WorkspaceSnapshot, imageSlot: ImageSlot,
        admissionToken: NativeDecompilerAdmissionToken
    ) throws -> NativeDecompilerSnapshotBuilder.ValidatedImage {
        // The session advances this fence synchronously before asynchronous retire.
        // A queued operation cannot revive a terminated owner's captured image.
        try Task.checkCancellation()
        guard admissionToken.isCurrent else { throw CancellationError() }
        if let entry = entries[owner], entry.revision == revision,
           entry.imageSlot == imageSlot {
            return entry.image
        }
        entries.removeValue(forKey: owner)
        let image = try NativeDecompilerSnapshotBuilder.validateImage(
            from: snapshot, imageSlot: imageSlot
        )
        guard admissionToken.isCurrent else { throw CancellationError() }
        validations += 1
        if image.retainedBytes <= maximumRetainedBytes {
            if entries.count >= maximumOwners, let first = entries.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }).first {
                entries.removeValue(forKey: first)
            }
            entries[owner] = Entry(revision: revision, imageSlot: imageSlot, image: image)
        }
        return image
    }

    /// Batch leases retain their own bounded capture. Do not insert them into
    /// the window-owner cache, where a fallback export could evict a pane.
    func validateForBatch(
        snapshot: WorkspaceSnapshot, imageSlot: ImageSlot,
        admissionToken: NativeDecompilerAdmissionToken
    ) throws -> NativeDecompilerSnapshotBuilder.ValidatedImage {
        try Task.checkCancellation()
        guard admissionToken.isCurrent else { throw CancellationError() }
        let image = try NativeDecompilerSnapshotBuilder.validateImage(
            from: snapshot, imageSlot: imageSlot
        )
        guard admissionToken.isCurrent else { throw CancellationError() }
        validations += 1
        return image
    }

    func retire(owner: UUID) {
        entries.removeValue(forKey: owner)
    }
    func clear() { entries.removeAll() }
    func captureCount() -> Int { entries.count }
    func validationCount() -> Int { validations }
}

/// The captured image can be discarded under memory pressure while a lease remains
/// usable through the ordinary per-function validation path.
fileprivate final class NativeDecompilerBatchCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var image: NativeDecompilerSnapshotBuilder.ValidatedImage?
    private var active: [UUID: Task<NativeDecompilerValidatedExecution, Error>] = [:]
    private var isCancelled = false

    init(image: NativeDecompilerSnapshotBuilder.ValidatedImage?) { self.image = image }
    func currentImage() -> NativeDecompilerSnapshotBuilder.ValidatedImage? {
        lock.withLock { image }
    }
    func clearImage() { lock.withLock { image = nil } }
    func track(_ task: Task<NativeDecompilerValidatedExecution, Error>, id: UUID) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            active[id] = task
            return true
        }
    }
    func finish(id: UUID) { _ = lock.withLock { active.removeValue(forKey: id) } }
    func cancel() {
        let tasks = lock.withLock { () -> [Task<NativeDecompilerValidatedExecution, Error>] in
            isCancelled = true
            image = nil
            let tasks = Array(active.values)
            active.removeAll()
            return tasks
        }
        for task in tasks { task.cancel() }
    }
}

/// One export's frozen input and image validation. Cancellation closes admission
/// synchronously, including while the registry is waiting on another actor.
struct NativeDecompilerBatchCaptureLease: Sendable {
    fileprivate let registryID: UUID
    fileprivate let owner: UUID
    fileprivate let snapshot: WorkspaceSnapshot
    fileprivate let imageSlot: ImageSlot
    fileprivate let fingerprint: String
    fileprivate let state: NativeDecompilerBatchCaptureState
    fileprivate let fence: NativeDecompilerAdmissionFence
    fileprivate let token: NativeDecompilerAdmissionToken

    func cancel() {
        fence.revoke()
        state.cancel()
    }
}

protocol NativeDecompilerSessionProviding: AnyObject, Sendable {
    @MainActor
    func makeWorkspaceSession(
        windowID: WorkspaceWindowID,
        presentation: NativeDecompilerPresentationModel
    ) -> any NativeDecompilerWorkspaceSessionHandling
}

/// One application-process owner for the native decompiler product lane.
///
/// The registry owns exactly one accepted XPC client/coordinator pair. Window sessions carry only
/// an owner key and a cancellable task; closing a non-owner window cannot cancel another window's
/// current generation. Validated results publish only to the matching window-owned transient
/// presentation model and never flow into authoritative or persisted workspace state.
actor NativeDecompilerRuntimeRegistry: NativeDecompilerSessionProviding {
    typealias SubmissionAdmission = @Sendable (_ landingGeneration: UInt64) async -> Void
    /// Synchronization-only seam used to stop a task after its final runtime-generation check but
    /// before the cross-actor coordinator admission. It receives no snapshot or request content.
    typealias CoordinatorAdmission = @Sendable (_ landingGeneration: UInt64) async -> Void
    typealias TransportShutdown = @Sendable () async -> Void

    fileprivate struct SessionOwner: Hashable, Sendable {
        let windowID: WorkspaceWindowID
        let token: UUID
    }

    // v3 (32 MiB output) is the default for every native request; v1 and v2
    // stay named profiles for frozen fixtures.
    static let productBudgets =
        NativeDecompilerProductBudgetProfile.productDefault.wireValue

    private nonisolated let isEnabled: Bool
    private let coordinator: NativeDecompilerCoordinator
    private let processRuntime: NativeDecompilerProcessRuntime
    private let projectionGate: NativeDecompilerProjectionGate
    private let validatedImages = NativeDecompilerValidatedImageStore()
    private let registryID = UUID()
    private var batchCaptures: [UUID: NativeDecompilerBatchCaptureState] = [:]
    private let telemetry: NativeDecompilerTelemetryRecorder
    private let submissionAdmission: SubmissionAdmission
    private let coordinatorAdmission: CoordinatorAdmission
    private let transportShutdown: TransportShutdown
    private var latestLandingGenerationByOwner: [SessionOwner: UInt64] = [:]
    private var isShutDown = false
    private var shutdownTask: Task<Void, Never>?

    private init(
        policy: NativeDecompilerRuntimePolicy,
        dispatcher: any NativeDecompilerDispatching,
        authorityProvider: any NativeDecompilerRuntimeAuthorityProviding,
        telemetry: NativeDecompilerTelemetryRecorder = .init(),
        submissionAdmission: @escaping SubmissionAdmission = { _ in },
        coordinatorAdmission: @escaping CoordinatorAdmission = { _ in },
        transportShutdown: @escaping TransportShutdown = {}
    ) {
        isEnabled = policy.isEnabled
        self.submissionAdmission = submissionAdmission
        self.coordinatorAdmission = coordinatorAdmission
        self.transportShutdown = transportShutdown
        self.telemetry = telemetry
        let coordinator = NativeDecompilerCoordinator(
            policy: policy,
            dispatcher: dispatcher
        )
        self.coordinator = coordinator
        projectionGate = NativeDecompilerProjectionGate()
        processRuntime = NativeDecompilerProcessRuntime(
            authorityProvider: authorityProvider
        ) { submission, executionToken, expectedRuntimeIdentity in
            try await coordinator.perform(
                submission,
                executionToken: executionToken,
                expectedRuntimeIdentity: expectedRuntimeIdentity
            )
        }
    }

    #if DEBUG
    /// Explicit test-only composition seam. Release product code has no generic constructor and
    /// can obtain only the single app-owned `productionShared` graph below.
    static func testing(
        policy: NativeDecompilerRuntimePolicy,
        dispatcher: any NativeDecompilerDispatching,
        authorityProvider: any NativeDecompilerRuntimeAuthorityProviding,
        telemetry: NativeDecompilerTelemetryRecorder = .init(),
        submissionAdmission: @escaping SubmissionAdmission = { _ in },
        coordinatorAdmission: @escaping CoordinatorAdmission = { _ in },
        transportShutdown: @escaping TransportShutdown = {}
    ) -> NativeDecompilerRuntimeRegistry {
        NativeDecompilerRuntimeRegistry(
            policy: policy,
            dispatcher: dispatcher,
            authorityProvider: authorityProvider,
            telemetry: telemetry,
            submissionAdmission: submissionAdmission,
            coordinatorAdmission: coordinatorAdmission,
            transportShutdown: transportShutdown
        )
    }
    #endif

    static let productionShared: NativeDecompilerRuntimeRegistry = {
        let defaultsValue = UserDefaults.standard.object(
            forKey: NativeDecompilerRuntimePolicy.defaultsKey
        ) as? Bool
        let client = NativeDecompilerXPCClient()
        let registry = NativeDecompilerRuntimeRegistry(
            policy: .productPolicy(
                environment: ProcessInfo.processInfo.environment,
                defaultsValue: defaultsValue
            ),
            dispatcher: client,
            authorityProvider: NativeDecompilerBundleRuntimeAuthorityProvider(),
            transportShutdown: { await client.shutdown() }
        )
        registry.bindProcessLifecycle(to: client)
        return registry
    }()

    /// Binds the accepted signed transport generation to the process-runtime epoch. Tests use the
    /// same seam with the real embedded service so interruption/relaunch proof cannot accidentally
    /// exercise a lifecycle path that differs from production composition.
    nonisolated func bindProcessLifecycle(to client: NativeDecompilerXPCClient) {
        client.setConnectionLifecycleHandler { [weak self] event, generation in
            switch event {
            case .interrupted:
                await self?.replaceProcessEpoch(
                    cause: .interrupted,
                    connectionGeneration: generation
                )
            case .invalidated:
                await self?.replaceProcessEpoch(
                    cause: .invalidated,
                    connectionGeneration: generation
                )
            case .connectionFailure:
                return
            }
        }
    }

    @MainActor
    func makeWorkspaceSession(
        windowID: WorkspaceWindowID,
        presentation: NativeDecompilerPresentationModel
    ) -> any NativeDecompilerWorkspaceSessionHandling {
        guard isEnabled else {
            return NativeDecompilerDisabledWorkspaceSession.shared
        }
        let ownerToken = UUID()
        presentation.activate(ownerToken: ownerToken)
        return NativeDecompilerWorkspaceSession(
            owner: SessionOwner(windowID: windowID, token: ownerToken),
            runtime: self,
            presentation: presentation
        )
    }

    @discardableResult
    fileprivate func submit(
        owner: SessionOwner,
        landingGeneration: UInt64,
        admissionToken: NativeDecompilerAdmissionToken,
        snapshot: WorkspaceSnapshot,
        snapshotRevision: UUID,
        imageSlot: ImageSlot,
        functionID: UUID,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy,
        presentation: NativeDecompilerPresentationModel
    ) async -> Bool {
        guard !isShutDown else { return false }
        await submissionAdmission(landingGeneration)
        guard !isShutDown, !Task.isCancelled else { return false }
        guard acceptNewGeneration(landingGeneration, for: owner) else { return false }

        let retainedProjectionWeight = Self.retainedProjectionWeight(for: snapshot)
        let telemetryToken = telemetry.begin(
            kind: .endToEndAttempt,
            cacheDisposition: cacheLookupPolicy == .allowValidatedCache
                ? .lookupMiss
                : .bypassed,
            ownerKind: .windowSession,
            sizeBucket: Self.telemetrySizeBucket(for: retainedProjectionWeight),
            countBucket: Self.telemetryCountBucket(for: snapshot.binaries.count),
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        var telemetryOutcome: NativeDecompilerTelemetryOutcome = .failure
        defer {
            _ = telemetry.end(
                token: telemetryToken,
                outcome: telemetryOutcome,
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }

        guard isCurrent(landingGeneration, for: owner), !Task.isCancelled else {
            telemetryOutcome = .superseded
            _ = await presentation.clear(
                ownerToken: owner.token,
                generation: landingGeneration
            )
            return false
        }
        guard let analysis = snapshot.analysis(in: imageSlot) else {
            telemetryOutcome = .rejected
            _ = await presentation.publishProjectionFailure(
                ownerToken: owner.token,
                generation: landingGeneration,
                error: .analysisNotFound
            )
            return false
        }
        guard let function = NativeDecompilerExactFunctionResolver.resolve(
            functionID: functionID,
            functions: analysis.functions
        ) else {
            telemetryOutcome = .rejected
            _ = await presentation.publishProjectionFailure(
                ownerToken: owner.token,
                generation: landingGeneration,
                error: .functionNotFound
            )
            return false
        }

        let projection: NativeDecompilerSnapshotProjection
        do {
            projection = try await projectionGate.project(
                owner: owner.token,
                key: NativeDecompilerProjectionKey(
                    imageSlot: imageSlot,
                    ownerBinaryID: projectionOwnerBinaryID(
                        snapshot: snapshot,
                        imageSlot: imageSlot
                    ),
                    analysisInputFingerprintSHA256:
                        analysis.analysisInputFingerprint?.overallSHA256 ?? "",
                    functionID: function.id
                ),
                queuedWeight: retainedProjectionWeight,
                operation: { [validatedImages] in
                    try Task.checkCancellation()
                    let image = try await validatedImages.capture(
                        owner: owner.token, revision: snapshotRevision,
                        snapshot: snapshot, imageSlot: imageSlot,
                        admissionToken: admissionToken
                    )
                    return try NativeDecompilerSnapshotBuilder.build(
                        from: snapshot,
                        validatedImage: image,
                        functionID: function.id,
                        budgets: Self.productBudgets
                    )
                }
            )
        } catch is CancellationError {
            telemetryOutcome = .cancelled
            return false
        } catch let error as NativeDecompilerSnapshotProjectionError {
            telemetryOutcome = error == .unsupportedArchitecture ? .unavailable : .rejected
            _ = await presentation.publishProjectionFailure(
                ownerToken: owner.token,
                generation: landingGeneration,
                error: error
            )
            return false
        } catch {
            telemetryOutcome = .rejected
            _ = await presentation.publishProjectionFailure(
                ownerToken: owner.token,
                generation: landingGeneration,
                error: .invalidProjectedRequest
            )
            return false
        }
        guard isCurrent(landingGeneration, for: owner), !Task.isCancelled else {
            telemetryOutcome = .superseded
            _ = await presentation.clear(
                ownerToken: owner.token,
                generation: landingGeneration
            )
            return false
        }

        let submission: NativeDecompilerSubmission
        do {
            submission = try NativeDecompilerSubmission(
                snapshot: projection,
                referenceCounts: Self.referenceCounts(
                    analysis: analysis,
                    function: function
                )
            )
        } catch {
            telemetryOutcome = .rejected
            _ = await presentation.publishProjectionFailure(
                ownerToken: owner.token,
                generation: landingGeneration,
                error: .invalidProjectedRequest
            )
            return false
        }

        var coordinate = NativeDecompilerPresentationCoordinate(
            imageSlot: projection.coordinate.imageSlot,
            ownerBinaryID: projection.coordinate.ownerBinaryID,
            artifactUUID: projection.image.uuid,
            imageID: projection.image.imageID,
            functionID: projection.function.functionID,
            requestSHA256: submission.projection.requestSHA256,
            analysisInputFingerprintSHA256:
                projection.coordinate.analysisInputFingerprintSHA256,
            contextOmissions: projection.contextOmissions
        )
        let presentationAccepted = await presentation.begin(
            ownerToken: owner.token,
            generation: landingGeneration,
            coordinate: coordinate
        )
        guard presentationAccepted else { return false }

        await coordinatorAdmission(landingGeneration)
        var execution: NativeDecompilerProcessRuntimeExecution
        do {
            execution = try await processRuntime.submit(
                owner: owner.token,
                submission: submission,
                queuedWeight: submission.dispatchRequest.encodedByteCount,
                cacheLookupPolicy: cacheLookupPolicy
            )
        } catch is CancellationError {
            telemetryOutcome = .cancelled
            _ = await presentation.discard(
                ownerToken: owner.token,
                generation: landingGeneration
            )
            return false
        } catch let error as FairSingleLaneSchedulerError {
            telemetryOutcome = .unavailable
            let reason: NativeDecompilerPresentationTerminalReason = switch error {
            case .queueLimitReached, .queuedWeightLimitReached:
                .provider(.busy)
            case .shutDown:
                .transportFailure
            }
            _ = await presentation.publishTerminal(
                ownerToken: owner.token,
                generation: landingGeneration,
                coordinate: coordinate,
                reason: reason
            )
            return false
        } catch let error as NativeDecompilerRuntimeValidationError {
            telemetryOutcome = .rejected
            _ = await presentation.publishTerminal(
                ownerToken: owner.token,
                generation: landingGeneration,
                coordinate: coordinate,
                reason: .runtimeValidation(error)
            )
            return false
        } catch let error as NativeDecompilerProcessRuntimeError {
            telemetryOutcome = switch error {
            case .staleEpoch, .runtimeTransitionInProgress: .superseded
            case .runtimeAuthorityUnavailable, .shutDown: .unavailable
            }
            _ = await presentation.publishTerminal(
                ownerToken: owner.token,
                generation: landingGeneration,
                coordinate: coordinate,
                reason: .runtime(error)
            )
            return false
        } catch {
            telemetryOutcome = .failure
            _ = await presentation.publishTerminal(
                ownerToken: owner.token,
                generation: landingGeneration,
                coordinate: coordinate,
                reason: .transportFailure
            )
            return false
        }
        guard isCurrent(landingGeneration, for: owner), !Task.isCancelled else {
            telemetryOutcome = .superseded
            _ = await presentation.discard(
                ownerToken: owner.token,
                generation: landingGeneration
            )
            return false
        }
        // A graph too large to return in time or within the output budget (libjpeg
        // `_encode_one_block`) degrades once to a document-only request: the pane shows the
        // text with "structure omitted" instead of an error.
        if Self.retriesAsDocumentOnly(execution.completion),
           let documentSubmission = try? NativeDecompilerSubmission(
               snapshot: projection,
               operation: .decompileDocument,
               referenceCounts: Self.referenceCounts(analysis: analysis, function: function)
           ) {
            let documentCoordinate = coordinate.withRequestSHA256(documentSubmission.projection.requestSHA256)
            if await presentation.rebindAnalyzing(
                ownerToken: owner.token, generation: landingGeneration,
                from: coordinate, to: documentCoordinate
            ) {
                coordinate = documentCoordinate
                if let retried = try? await processRuntime.submit(
                    owner: owner.token,
                    submission: documentSubmission,
                    queuedWeight: documentSubmission.dispatchRequest.encodedByteCount,
                    cacheLookupPolicy: cacheLookupPolicy
                ) {
                    execution = retried
                }
                guard isCurrent(landingGeneration, for: owner), !Task.isCancelled else {
                    telemetryOutcome = .superseded
                    _ = await presentation.discard(ownerToken: owner.token, generation: landingGeneration)
                    return false
                }
            }
        }
        switch execution.completion {
        case let .ready(success):
            telemetryOutcome = execution.source == .validatedCache ? .cacheHit : .success
            _ = await presentation.publishReady(
                ownerToken: owner.token,
                generation: landingGeneration,
                coordinate: coordinate,
                success: success
            )
        case let .terminal(reason):
            telemetryOutcome = Self.telemetryOutcome(for: reason)
            _ = await presentation.publishTerminal(
                ownerToken: owner.token,
                generation: landingGeneration,
                coordinate: coordinate,
                reason: reason
            )
        }
        return true
    }

    func decompileForReconstruction(
        owner: UUID,
        request: NativeDecompilerProjectionRequest,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    ) async throws -> NativeDecompilerValidatedExecution {
        let run = try await submitOwnedProjection(
            owner: owner,
            request: request,
            cacheLookupPolicy: cacheLookupPolicy
        )
        guard case let .ready(success) = run.execution.completion else {
            throw NativeDecompilerOwnerAdmissionError.terminal(run.execution.completion)
        }
        return NativeDecompilerValidatedExecution(
            requestSHA256: run.submission.projection.requestSHA256,
            analysisInputFingerprintSHA256:
                run.projection.coordinate.analysisInputFingerprintSHA256,
            imageSlot: run.projection.coordinate.imageSlot,
            functionID: request.functionID,
            success: success,
            source: run.execution.source,
            contextOmissions: run.projection.contextOmissions
        )
    }

    /// D10 batch adapter: one frozen capture for the export, with live per-function
    /// authored projection and ordinary native runtime validation. A large image
    /// uses the existing per-function path instead of retaining an unbounded cache.
    func beginNativeBatchCapture(
        snapshot: WorkspaceSnapshot,
        imageSlot: ImageSlot
    ) async throws -> NativeDecompilerBatchCaptureLease {
        guard isEnabled, !isShutDown else {
            throw NativeDecompilerProcessRuntimeError.shutDown
        }
        try Task.checkCancellation()
        let fence = NativeDecompilerAdmissionFence()
        guard let token = fence.advance() else { throw CancellationError() }
        let owner = UUID()
        let image = try await validatedImages.validateForBatch(
            snapshot: snapshot,
            imageSlot: imageSlot, admissionToken: token
        )
        guard !isShutDown else {
            fence.revoke()
            throw NativeDecompilerProcessRuntimeError.shutDown
        }
        guard token.isCurrent, !Task.isCancelled else {
            throw CancellationError()
        }
        let cachedImage = image.retainedBytes <= 64 * 1_048_576 && batchCaptures.count < 4
            ? image : nil
        let state = NativeDecompilerBatchCaptureState(image: cachedImage)
        if cachedImage != nil { batchCaptures[owner] = state }
        return NativeDecompilerBatchCaptureLease(
            registryID: registryID, owner: owner, snapshot: snapshot,
            imageSlot: imageSlot, fingerprint: image.fingerprint.overallSHA256,
            state: state, fence: fence, token: token
        )
    }

    /// The full request failed only because its structured graph was too large to deliver.
    static func retriesAsDocumentOnly(_ completion: NativeDecompilerCompletion) -> Bool {
        switch completion {
        case .terminal(.client(.timedOut)), .terminal(.provider(.responseTooLarge, _)):
            true
        case let .terminal(.provider(_, detail)):
            detail == "native-provider-output-budget-exceeded"
        default:
            false
        }
    }

    func decompileNativeBatchFunction(
        lease: NativeDecompilerBatchCaptureLease,
        functionID: UUID
    ) async throws -> NativeDecompilerValidatedExecution {
        guard lease.registryID == registryID, lease.token.isCurrent else {
            throw CancellationError()
        }
        let taskID = UUID()
        let task = Task {
            try await runNativeBatchFunction(lease: lease, functionID: functionID)
        }
        guard lease.state.track(task, id: taskID) else {
            task.cancel()
            throw CancellationError()
        }
        defer { lease.state.finish(id: taskID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runNativeBatchFunction(
        lease: NativeDecompilerBatchCaptureLease,
        functionID: UUID
    ) async throws -> NativeDecompilerValidatedExecution {
        try Task.checkCancellation()
        guard lease.token.isCurrent else { throw CancellationError() }
        let request = try NativeDecompilerProjectionRequest(
            workspace: lease.snapshot, imageSlot: lease.imageSlot,
            functionID: functionID,
            analysisInputFingerprintSHA256: lease.fingerprint
        )
        // Whole-image export consumes the text only; a document-only request keeps a huge
        // function's structured graph from being encoded and transferred (libjpeg
        // `_encode_one_block`: ~32 MiB reply outlived the service hard deadline).
        let run = try await submitOwnedProjection(
            owner: lease.owner, request: request,
            cacheLookupPolicy: .allowValidatedCache, batchLease: lease,
            operation: .decompileDocument
        )
        guard lease.token.isCurrent else { throw CancellationError() }
        guard case let .ready(success) = run.execution.completion else {
            throw NativeDecompilerOwnerAdmissionError.terminal(run.execution.completion)
        }
        return NativeDecompilerValidatedExecution(
            requestSHA256: run.submission.projection.requestSHA256,
            analysisInputFingerprintSHA256:
                run.projection.coordinate.analysisInputFingerprintSHA256,
            imageSlot: run.projection.coordinate.imageSlot,
            functionID: functionID, success: success,
            source: run.execution.source,
            contextOmissions: run.projection.contextOmissions
        )
    }

    func retireNativeBatchCapture(_ lease: NativeDecompilerBatchCaptureLease) async {
        guard lease.registryID == registryID else { return }
        lease.cancel()
        batchCaptures.removeValue(forKey: lease.owner)
    }

    /// Scripted/MCP `decompile`: the reconstruction admission path (same projection, process
    /// runtime and validated cache as the pane) under one process-wide scripting owner. Never
    /// throws; every non-ready result maps to an outcome the caller falls back to MacIR on.
    func decompileForScripting(
        _ request: ScriptingNativeDecompileRequest
    ) async -> ScriptingNativeDecompileOutcome {
        guard isEnabled, !isShutDown else { return .unavailable }
        guard let fingerprint = request.snapshot.analysis(in: request.imageSlot)?
                .analysisInputFingerprint?.overallSHA256,
              let projectionRequest = try? NativeDecompilerProjectionRequest(
                  workspace: request.snapshot,
                  imageSlot: request.imageSlot,
                  functionID: request.functionID,
                  analysisInputFingerprintSHA256: fingerprint
              )
        else {
            return .failed(code: "missing-analysis-fingerprint")
        }
        do {
            let run = try await submitOwnedProjection(
                owner: Self.scriptingOwner,
                request: projectionRequest,
                cacheLookupPolicy: .allowValidatedCache
            )
            switch run.execution.completion {
            case .ready(let success):
                return .completed(success.result.pseudocodeDocument)
            case .terminal(let reason):
                return .terminal(reason)
            }
        } catch is CancellationError {
            return .failed(code: "cancelled")
        } catch let error as NativeDecompilerSnapshotProjectionError {
            return .terminal(.projection(error))
        } catch let error as NativeDecompilerProcessRuntimeError {
            return .terminal(.runtime(error))
        } catch let error as NativeDecompilerRuntimeValidationError {
            return .terminal(.runtimeValidation(error))
        } catch {
            return .failed(code: "error-\(type(of: error))")
        }
    }

    /// Fairness owner shared by every scripted/MCP decompile in this process.
    private static let scriptingOwner = UUID()

    private func submitOwnedProjection(
        owner: UUID,
        request: NativeDecompilerProjectionRequest,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy,
        batchLease: NativeDecompilerBatchCaptureLease? = nil,
        operation: NativeDecompilerWireRequestOperation = .decompile
    ) async throws -> (
        projection: NativeDecompilerSnapshotProjection,
        submission: NativeDecompilerSubmission,
        execution: NativeDecompilerProcessRuntimeExecution
    ) {
        guard !isShutDown else {
            throw NativeDecompilerProcessRuntimeError.shutDown
        }
        try Task.checkCancellation()
        guard let analysis = request.workspace.analysis(in: request.imageSlot),
              analysis.analysisInputFingerprint?.overallSHA256
                == request.analysisInputFingerprintSHA256,
              let function = NativeDecompilerExactFunctionResolver.resolve(
                  functionID: request.functionID,
                  functions: analysis.functions
              )
        else {
            throw NativeDecompilerSnapshotProjectionError.functionNotFound
        }

        let projection = try await projectionGate.project(
            owner: owner,
            key: NativeDecompilerProjectionKey(
                imageSlot: request.imageSlot,
                ownerBinaryID: projectionOwnerBinaryID(
                    snapshot: request.workspace,
                    imageSlot: request.imageSlot
                ),
                analysisInputFingerprintSHA256: request.analysisInputFingerprintSHA256,
                functionID: function.id
            ),
            queuedWeight: Self.retainedProjectionWeight(for: request.workspace),
            operation: {
                if let batchLease {
                    guard batchLease.token.isCurrent else { throw CancellationError() }
                    let projection: NativeDecompilerSnapshotProjection
                    if let image = batchLease.state.currentImage() {
                        projection = try NativeDecompilerSnapshotBuilder.build(
                            from: request.workspace, validatedImage: image,
                            functionID: function.id, budgets: Self.productBudgets
                        )
                    } else {
                        projection = try NativeDecompilerSnapshotBuilder.build(
                            from: request.workspace, imageSlot: request.imageSlot,
                            functionID: function.id, budgets: Self.productBudgets
                        )
                    }
                    guard batchLease.token.isCurrent else { throw CancellationError() }
                    return projection
                }
                return try NativeDecompilerSnapshotBuilder.build(
                    from: request.workspace, imageSlot: request.imageSlot,
                    functionID: function.id, budgets: Self.productBudgets
                )
            }
        )
        if let batchLease, !batchLease.token.isCurrent { throw CancellationError() }
        try Task.checkCancellation()
        let submission = try NativeDecompilerSubmission(
            snapshot: projection,
            operation: operation,
            referenceCounts: Self.referenceCounts(
                analysis: analysis,
                function: function
            )
        )
        let execution = try await processRuntime.submit(
            owner: owner,
            submission: submission,
            queuedWeight: submission.dispatchRequest.encodedByteCount,
            cacheLookupPolicy: cacheLookupPolicy
        )
        if let batchLease, !batchLease.token.isCurrent { throw CancellationError() }
        try Task.checkCancellation()
        return (projection, submission, execution)
    }

    fileprivate func invalidate(
        owner: SessionOwner,
        landingGeneration: UInt64,
        admissionToken _: NativeDecompilerAdmissionToken,
        presentation: NativeDecompilerPresentationModel
    ) async {
        guard acceptNewGeneration(landingGeneration, for: owner) else { return }
        _ = await presentation.clear(
            ownerToken: owner.token,
            generation: landingGeneration
        )
    }

    fileprivate func retire(
        owner: SessionOwner,
        landingGeneration: UInt64,
        admissionToken _: NativeDecompilerAdmissionToken,
        presentation: NativeDecompilerPresentationModel
    ) async {
        guard landingGeneration > latestLandingGenerationByOwner[owner, default: 0]
        else { return }
        latestLandingGenerationByOwner.removeValue(forKey: owner)
        await validatedImages.retire(owner: owner.token)
        _ = await presentation.clear(
            ownerToken: owner.token,
            generation: landingGeneration
        )
    }

    fileprivate func retireExhaustedSession(owner: SessionOwner) {
        latestLandingGenerationByOwner.removeValue(forKey: owner)
        Task { await validatedImages.retire(owner: owner.token) }
    }

    func activeSessionOwnerCountForTesting() -> Int {
        latestLandingGenerationByOwner.count
    }

    #if DEBUG
    func validatedImageValidationCountForTesting() async -> Int {
        await validatedImages.validationCount()
    }
    #endif

    func observationSnapshot() async -> [NativeDecompilerObservation] {
        await coordinator.observationSnapshot()
    }

    func replaceProcessEpoch(
        cause: NativeDecompilerRuntimeTransitionCause = .appOwnedReattestation,
        connectionGeneration: UInt64? = nil
    ) async {
        await processRuntime.replaceEpoch(
            cause: cause,
            connectionGeneration: connectionGeneration
        )
    }

    func memoryPressureDidOccur(_ level: NativeDecompilerMemoryPressureLevel = .critical) async {
        for capture in batchCaptures.values { capture.clearImage() }
        batchCaptures.removeAll()
        await validatedImages.clear()
        switch level {
        case .warning:
            await processRuntime.trimValidatedCache(
                maximumEntries: 32,
                maximumBytes: 32 * 1_048_576
            )
        case .critical:
            await processRuntime.clearValidatedCache()
        }
    }

    func processRuntimeSnapshotForTesting() async -> NativeDecompilerProcessRuntimeSnapshot {
        await processRuntime.snapshot()
    }

    func telemetrySnapshotForTesting() -> NativeDecompilerTelemetrySnapshot {
        telemetry.snapshot()
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShutDown = true
        for capture in batchCaptures.values { capture.cancel() }
        batchCaptures.removeAll()
        await validatedImages.clear()
        let runtimeTask = await processRuntime.beginShutdown()
        let projectionGate = self.projectionGate
        let transportShutdown = self.transportShutdown
        let task = Task {
            await projectionGate.shutdown()
            await transportShutdown()
            await runtimeTask.value
        }
        shutdownTask = task
        await task.value
    }

    private func acceptNewGeneration(_ generation: UInt64, for owner: SessionOwner) -> Bool {
        guard generation > latestLandingGenerationByOwner[owner, default: 0] else { return false }
        latestLandingGenerationByOwner[owner] = generation
        return true
    }

    private func isCurrent(_ generation: UInt64, for owner: SessionOwner) -> Bool {
        latestLandingGenerationByOwner[owner] == generation
    }

    private func projectionOwnerBinaryID(
        snapshot: WorkspaceSnapshot,
        imageSlot: ImageSlot
    ) -> UUID {
        snapshot.binaries.first(where: { $0.slot == imageSlot })?.id
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    /// Conservative retained-memory charge for a queued closure that captures the immutable
    /// workspace snapshot. Raw image bytes dominate, while a fixed per-record allowance prevents
    /// metadata-heavy snapshots from being represented as a near-zero queue cost.
    static func retainedProjectionWeight(for snapshot: WorkspaceSnapshot) -> UInt64 {
        var weight: UInt64 = 1
        func add(_ value: UInt64) {
            let (sum, overflow) = weight.addingReportingOverflow(value)
            weight = overflow ? .max : sum
        }
        func addRecords(_ count: Int) {
            let (bytes, overflow) = UInt64(clamping: count).multipliedReportingOverflow(by: 512)
            add(overflow ? .max : bytes)
        }

        for binary in snapshot.binaries {
            add(UInt64(binary.name.utf8.count))
            add(UInt64(binary.path.utf8.count))
            add(UInt64(binary.kind.utf8.count))
            add(UInt64(binary.architecture.utf8.count))
            add(UInt64(binary.originalPathBookmark?.count ?? 0))
            add(256)
        }
        for analysis in snapshot.analysisBySlot.values {
            add(UInt64(analysis.imageBytes.count))
            add(UInt64(analysis.hexBytes.count))
            addRecords(analysis.functions.count)
            addRecords(analysis.symbols.count)
            addRecords(analysis.imports.count)
            addRecords(analysis.indirectSymbols.count)
            addRecords(analysis.exports.count)
            addRecords(analysis.stringLiterals.count)
            addRecords(analysis.basicBlocks.count)
            addRecords(analysis.instructions.count)
            addRecords(analysis.xrefs.count)
            addRecords(analysis.controlFlowEdges.count)
            addRecords(analysis.sections.count)
            addRecords(analysis.relocations.count)
            addRecords(analysis.sourceLines.count)
            addRecords(analysis.diagnostics.count)
        }
        return weight
    }

    private static func referenceCounts(
        analysis: ImageAnalysis,
        function: FunctionSummary
    ) -> NativeDecompilerReferenceCounts {
        let range = function.startAddress ..< function.endAddress
        return NativeDecompilerReferenceCounts(
            instructions: analysis.instructions.count(where: { range.contains($0.address) }),
            blocks: analysis.basicBlocks.count(where: { $0.functionID == function.id }),
            edges: analysis.controlFlowEdges.count(where: { range.contains($0.from) }),
            calls: analysis.xrefs.count(where: {
                $0.kind == XRefKind.call && range.contains($0.from)
            })
        )
    }

    private static func telemetrySizeBucket(
        for bytes: UInt64
    ) -> NativeDecompilerTelemetrySizeBucket {
        switch bytes {
        case 0: .none
        case 1 ... 4_096: .tiny
        case 4_097 ... 65_536: .small
        case 65_537 ... 1_048_576: .medium
        case 1_048_577 ... 8_388_608: .large
        default: .oversized
        }
    }

    private static func telemetryCountBucket(
        for count: Int
    ) -> NativeDecompilerTelemetryCountBucket {
        switch count {
        case ...0: .zero
        case 1: .one
        case 2 ... 4: .twoToFour
        case 5 ... 16: .fiveToSixteen
        case 17 ... 64: .seventeenToSixtyFour
        default: .moreThanSixtyFour
        }
    }

    private static func telemetryOutcome(
        for reason: NativeDecompilerPresentationTerminalReason
    ) -> NativeDecompilerTelemetryOutcome {
        switch reason {
        case .provider(.cancelled, _), .client(.cancelled): .cancelled
        case .provider(.timedOut, _), .client(.timedOut): .timeout
        case .invalidReply, .runtimeValidation(.replyRuntimeIdentityMismatch): .rejected
        case .runtime(.staleEpoch), .runtime(.runtimeTransitionInProgress): .superseded
        case .provider(.unavailable, _), .client(.connectionUnavailable), .transportFailure,
             .projection(.unsupportedArchitecture),
             .runtimeValidation(.runtimeAuthorityMismatch),
             .runtime(.runtimeAuthorityUnavailable), .runtime(.shutDown):
            .unavailable
        case .provider, .client, .projection, .runtimeValidation, .runtime:
            .failure
        }
    }

    @MainActor
    static func makeWindowCommandRouter(
        store: WorkspaceStore,
        presentation: NativeDecompilerPresentationModel
    ) -> NativeDecompilerWindowCommandRouter {
        NativeDecompilerWindowCommandRouter(store: store, presentation: presentation)
    }

}

@MainActor
final class NativeDecompilerWindowCommandRouter:
    ObservableObject,
    NativeDecompilerWindowCommandRouting
{
    private weak var store: WorkspaceStore?
    private let presentation: NativeDecompilerPresentationModel

    init(store: WorkspaceStore, presentation: NativeDecompilerPresentationModel) {
        self.store = store
        self.presentation = presentation
    }

    var enabledCommands: Set<NativeDecompilerControlCommand> {
        guard let store,
              !Self.ownerIsTerminal(in: store),
              let expected = Self.expectedIdentity(in: store)
        else { return [] }
        let projected = NativePseudocodePresentation.project(
            state: presentation.state,
            expected: expected,
            macScopeIsAvailable: store.focusedAnalysis != nil
        )
        var commands = NativeDecompilerCommandAvailability.enabledCommands(
            for: projected,
            exactTargetEligible: true
        )
        if commands.contains(.retry), !Self.retryAuthorityMatches(in: store) {
            commands.remove(.retry)
        }
        return commands
    }

    func perform(_ command: NativeDecompilerControlCommand) {
        guard enabledCommands.contains(command), let store else { return }
        switch command {
        case .request:
            store.requestNativeDecompiler()
        case .retry:
            store.retryNativeDecompiler()
        case .refresh:
            store.refreshNativeDecompiler()
        case .cancel:
            store.cancelNativeDecompiler()
        }
    }

    private static func expectedIdentity(
        in store: WorkspaceStore
    ) -> DecompilerPresentationIdentity? {
        guard let selection = store.selectedImageAddress,
              selection.slot == store.focusedImageSlot,
              let binary = store.snapshot.binary(in: selection.slot),
              let artifactUUID = binary.artifactIdentity?.uuid,
              let analysis = store.snapshot.analysis(in: selection.slot),
              let fingerprint = analysis.analysisInputFingerprint?.overallSHA256,
              let function = NativeDecompilerExactFunctionResolver.resolve(
                  selectedAddress: selection.address,
                  functions: analysis.functions
              )
        else { return nil }
        return DecompilerPresentationIdentity(
            imageSlot: selection.slot,
            ownerBinaryID: binary.id,
            artifactUUID: artifactUUID,
            functionID: function.id.uuidString.lowercased(),
            analysisInputFingerprintSHA256: fingerprint
        )
    }

    private static func retryAuthorityMatches(in store: WorkspaceStore) -> Bool {
        guard case let .submitted(ticket) = store.nativeDecompilerDriveContext.machine.state,
              let selection = store.selectedImageAddress,
              selection.slot == ticket.target.owner.imageSlot,
              store.snapshot.binary(in: selection.slot)?.id == ticket.target.owner.binaryID,
              let analysis = store.snapshot.analysis(in: selection.slot),
              analysis.analysisInputFingerprint?.overallSHA256
                == ticket.target.analysisFingerprintSHA256,
              let function = NativeDecompilerExactFunctionResolver.resolve(
                selectedAddress: selection.address,
                functions: analysis.functions
              )
        else { return false }
        return function.id == ticket.target.functionID
            && function.startAddress == ticket.target.functionStart
    }

    private static func ownerIsTerminal(in store: WorkspaceStore) -> Bool {
        if case .retired = store.nativeDecompilerDriveContext.machine.state {
            return true
        }
        return false
    }
}

/// Immutable disabled-policy handle. It schedules no task, retains no snapshot, and cannot create
/// or activate an XPC connection.
@MainActor
final class NativeDecompilerDisabledWorkspaceSession: NativeDecompilerWorkspaceSessionHandling,
    @unchecked Sendable
{
    static let shared = NativeDecompilerDisabledWorkspaceSession()

    private init() {}

    func submit(_ submission: NativeDecompilerWorkspaceSubmission) {}
    func retry(_ retry: NativeDecompilerWorkspaceRetry) {}
    func publishAuthoredProjectionFailure(
        _ diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    ) {}
    func cancelOutstanding() {}
    func terminateSession() {}
}

@MainActor
private final class NativeDecompilerWorkspaceSession: @unchecked Sendable,
    NativeDecompilerWorkspaceSessionHandling
{
    private let owner: NativeDecompilerRuntimeRegistry.SessionOwner
    private let runtime: NativeDecompilerRuntimeRegistry
    private let presentation: NativeDecompilerPresentationModel
    private var activeTask: Task<Void, Never>?
    private let admissionFence = NativeDecompilerAdmissionFence()
    private var currentTicket: NativeDriveSubmissionTicket?
    private var isTerminated = false

    init(
        owner: NativeDecompilerRuntimeRegistry.SessionOwner,
        runtime: NativeDecompilerRuntimeRegistry,
        presentation: NativeDecompilerPresentationModel
    ) {
        self.owner = owner
        self.runtime = runtime
        self.presentation = presentation
    }

    func submit(_ submission: NativeDecompilerWorkspaceSubmission) {
        guard !isTerminated else { return }
        currentTicket = submission.ticket
        start(
            ticket: submission.ticket,
            snapshot: submission.snapshot,
            snapshotRevision: submission.snapshotRevision,
            imageSlot: submission.imageSlot,
            functionID: submission.functionID,
            cacheLookupPolicy: submission.cacheLookupPolicy
        )
    }

    func retry(_ retry: NativeDecompilerWorkspaceRetry) {
        guard !isTerminated, currentTicket == retry.frozenTicket else { return }
        start(
            ticket: retry.frozenTicket,
            snapshot: retry.snapshot,
            snapshotRevision: retry.snapshotRevision,
            imageSlot: retry.imageSlot,
            functionID: retry.functionID,
            cacheLookupPolicy: .bypassCacheLookup
        )
    }

    func publishAuthoredProjectionFailure(
        _ diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    ) {
        guard !isTerminated else { return }
        _ = diagnostic
        currentTicket = ticket
        activeTask?.cancel()
        activeTask = nil
        guard let admissionToken = admissionFence.advance() else {
            handleAdmissionFenceExhaustion()
            return
        }
        _ = presentation.publishProjectionFailure(
            ownerToken: owner.token,
            generation: admissionToken.generation,
            error: .invalidProjectedRequest
        )
    }

    func cancelOutstanding() {
        invalidateCurrentGeneration(terminating: false)
    }

    func terminateSession() {
        invalidateCurrentGeneration(terminating: true)
    }

    private func start(
        ticket: NativeDriveSubmissionTicket,
        snapshot: WorkspaceSnapshot,
        snapshotRevision: UUID,
        imageSlot: ImageSlot,
        functionID: UUID,
        cacheLookupPolicy: NativeDecompilerCacheLookupPolicy
    ) {
        guard let admissionToken = admissionFence.advance() else {
            handleAdmissionFenceExhaustion()
            return
        }
        activeTask?.cancel()
        activeTask = Task { [owner, runtime, presentation] in
            _ = await runtime.submit(
                owner: owner,
                landingGeneration: admissionToken.generation,
                admissionToken: admissionToken,
                snapshot: snapshot,
                snapshotRevision: snapshotRevision,
                imageSlot: imageSlot,
                functionID: functionID,
                cacheLookupPolicy: cacheLookupPolicy,
                presentation: presentation
            )
        }
        _ = ticket
    }

    private func invalidateCurrentGeneration(terminating: Bool) {
        guard !isTerminated else { return }
        guard let admissionToken = admissionFence.advance() else {
            handleAdmissionFenceExhaustion()
            return
        }
        if terminating { isTerminated = true }
        if terminating { currentTicket = nil }
        activeTask?.cancel()
        activeTask = nil
        // Admission changes synchronously on the main actor. Retire the visible
        // publication in that same turn: export/actions must not capture the
        // previous ready result while actor cleanup is still queued.
        _ = presentation.clear(
            ownerToken: owner.token,
            generation: admissionToken.generation
        )
        Task { [owner, runtime, presentation] in
            if terminating {
                await runtime.retire(
                    owner: owner,
                    landingGeneration: admissionToken.generation,
                    admissionToken: admissionToken,
                    presentation: presentation
                )
            } else {
                await runtime.invalidate(
                    owner: owner,
                    landingGeneration: admissionToken.generation,
                    admissionToken: admissionToken,
                    presentation: presentation
                )
            }
        }
    }

    private func handleAdmissionFenceExhaustion() {
        guard !isTerminated else { return }
        admissionFence.revoke()
        isTerminated = true
        currentTicket = nil
        activeTask?.cancel()
        activeTask = nil
        Task { [owner, runtime] in
            await runtime.retireExhaustedSession(owner: owner)
        }
    }
}

extension NativeDecompilerSubmission {
    /// Bridges the accepted immutable app snapshot to the coordinator without independently
    /// rebuilding any request field. The placeholder correlation UUID is rebound by the client at
    /// dispatch time; every content-bearing field and the request digest remain frozen.
    init(
        snapshot: NativeDecompilerSnapshotProjection,
        operation: NativeDecompilerWireRequestOperation = .decompile,
        referenceCounts: NativeDecompilerReferenceCounts = .init()
    ) throws {
        try self.init(
            projection: try NativeDecompilerRequestProjection(snapshotProjection: snapshot, operation: operation),
            analysisInputFingerprintSHA256:
                snapshot.coordinate.analysisInputFingerprintSHA256,
            elapsedTimeBudget: NativeDecompilerProductBudgetProfile.clientWaitBudget(),
            referenceCounts: referenceCounts
        )
    }
}

extension NativeDecompilerRuntimeRegistry: ScriptingNativeDecompiling {
    func decompile(
        _ request: ScriptingNativeDecompileRequest
    ) async -> ScriptingNativeDecompileOutcome {
        await decompileForScripting(request)
    }
}
