import Foundation

protocol ReconstructionHeadlessAnalysisRequestResolving: Sendable {
    func request(
        for task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority
    ) async throws -> ReconstructionHeadlessAnalysisRequest
}

/// The injected app-owned executor uses the existing broker process owner and returns only after
/// execution/cleanup is settled. No command, compiler flag, path or supervisor comes from a model.
protocol ReconstructionSourceTaskExecuting: Sendable {
    func execute(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation) async -> ReconstructionTerminalTaskResult
    func pause() async
    func resume() async
    func retire() async
}

actor ReconstructionBatchTaskExecutor: ReconstructionBatchTaskExecuting {
    private let resolver: any ReconstructionHeadlessAnalysisRequestResolving
    private let headless: any ReconstructionHeadlessAnalysisExecuting
    private let native: any ReconstructionNativeTaskDecompiling
    private let sourceExecutor: (any ReconstructionSourceTaskExecuting)?

    init(
        resolver: any ReconstructionHeadlessAnalysisRequestResolving,
        headless: any ReconstructionHeadlessAnalysisExecuting,
        native: any ReconstructionNativeTaskDecompiling,
        sourceExecutor: (any ReconstructionSourceTaskExecuting)? = nil
    ) {
        self.resolver = resolver
        self.headless = headless
        self.native = native
        self.sourceExecutor = sourceExecutor
    }

    func execute(
        task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionTerminalTaskResult {
        var analysisProjection: ReconstructionTransientAnalysisProjection?
        var nativeResult: ReconstructionNativeTaskResult?
        var loadedImageAdmission: ReconstructionLoadedImageAdmission?
        var decompileFallbackReason: String?
        let outcome: ReconstructionTerminalTaskOutcome
        do {
            try cancellation.check()
            if task.identity.kind == .executeSource {
                guard task.identity.jobID == authority.jobID else {
                    return terminal(task, authority, .staleAuthority)
                }
                guard ReconstructionSourceExecutionTaskContract.admits(task), let sourceExecutor else {
                    return terminal(task, authority, .failed)
                }
                let result = await sourceExecutor.execute(task: task, authority: authority,
                    cancellation: cancellation)
                try cancellation.check()
                guard result.jobID == authority.jobID, result.taskID == task.identity.taskID,
                      result.checkpointID == authority.checkpointID,
                      result.checkpointRevision == authority.checkpointRevision,
                      result.corpusManifestSHA256 == authority.corpusManifestSHA256,
                      result.analysisProjection == nil, result.nativeResult == nil,
                      result.loadedImageAdmission == nil else {
                    return terminal(task, authority, .staleAuthority)
                }
                guard result.outcome != .completed
                    || result.sourceExecution?.isValid(for: task, authority: authority) == true else {
                    return terminal(task, authority, .staleAuthority)
                }
                return result
            }
            let request = try await resolver.request(for: task, authority: authority)
            try cancellation.check()
            if [.ingest, .classify, .discoverRelations].contains(task.identity.kind) {
                // Resolving these kinds already verifies the immutable manifest occurrence and
                // durable attachment identity. They do not need (and must not trigger) a full
                // binary analysis merely to attest committed-corpus work.
                return terminal(task, authority, .completed)
            }
            let headlessResult = try await headless.execute(request, cancellation: cancellation)
            try cancellation.check()
            guard task.identity.jobID == authority.jobID else {
                return terminal(task, authority, .staleAuthority)
            }
            let projectedAnalysis: ReconstructionTransientAnalysisProjection
            if task.identity.kind == .decompileMacScope || task.identity.kind == .compareDecompilers {
                projectedAnalysis = try await PseudocodeRenderingThread.run {
                    try ReconstructionTransientAnalysisProjection.project(
                        task: task, detached: headlessResult.detached
                    )
                }
            } else {
                projectedAnalysis = try ReconstructionTransientAnalysisProjection.project(
                    task: task, detached: headlessResult.detached
                )
            }
            analysisProjection = projectedAnalysis
            if task.identity.kind == .loadBinary {
                loadedImageAdmission = .init(taskID: task.identity.taskID, snapshot: headlessResult.detached)
            }
            try cancellation.check()
            if task.identity.kind == .decompileNative
                || task.identity.kind == .compareDecompilers {
                guard case let .function(subject)? = task.identity.subject,
                      let exactFunctionID = projectedAnalysis.function?.id else {
                    return terminal(task, authority, .failed)
                }
                guard let nativeProjection = headlessResult.projection else {
                    // D13: no native projection for this function; the task completes on MacIR.
                    return terminal(task, authority, .completed, analysisProjection: projectedAnalysis,
                        decompileFallbackReason: ReconstructionDecompileBackendRecord.nativeUnavailable)
                }
                // A projection for a different function/image/fingerprint is an integrity failure,
                // not a native fail-closed, so it never falls back.
                guard nativeProjection.imageSlot == projectedAnalysis.image.imageSlot,
                      nativeProjection.functionID == exactFunctionID,
                      nativeProjection.analysisInputFingerprintSHA256
                        == projectedAnalysis.analysisFingerprintSHA256 else {
                    return terminal(
                        task,
                        authority,
                        .failed,
                        analysisProjection: projectedAnalysis
                    )
                }
                let completedNativeResult = await native.decompile(
                    .init(
                        taskID: task.identity.taskID,
                        checkpointID: authority.checkpointID,
                        checkpointRevision: authority.checkpointRevision,
                        corpusManifestSHA256: authority.corpusManifestSHA256,
                        subject: subject,
                        projection: nativeProjection
                    ),
                    cancellation: cancellation
                )
                switch completedNativeResult {
                case .completed:
                    nativeResult = completedNativeResult
                    outcome = .completed
                case .cancelled: outcome = .cancelled
                case .failed(.authorityMismatch): outcome = .staleAuthority
                case .failed(let failure):
                    // D13: native failed closed. The MacIR decompile of the same function (the
                    // sibling decompileMacScope task, and this projection for a comparison) stands
                    // in, and the task records backend=macir with the reason, as MCP decompile does.
                    decompileFallbackReason = ReconstructionDecompileBackendRecord.nativeFailed(
                        String(describing: failure))
                    outcome = .completed
                }
            } else {
                outcome = .completed
            }
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed
        }
        return terminal(
            task,
            authority,
            outcome,
            analysisProjection: analysisProjection,
            nativeResult: nativeResult,
            loadedImageAdmission: loadedImageAdmission,
            decompileFallbackReason: decompileFallbackReason
        )
    }

    func pause() async {
        async let pauseHeadless: Void = headless.pause()
        async let cancelNative: Void = native.cancelOutstanding()
        await sourceExecutor?.pause()
        _ = await (pauseHeadless, cancelNative)
    }

    func resume() async {
        async let resumeHeadless: Void = headless.resume()
        await sourceExecutor?.resume()
        await resumeHeadless
    }

    func retire() async {
        async let retireHeadless: Void = headless.retire()
        async let retireNative: Void = native.retire()
        await sourceExecutor?.retire()
        _ = await (retireHeadless, retireNative)
    }

    private func terminal(
        _ task: ReconstructionTaskRecord,
        _ authority: ReconstructionBatchAuthority,
        _ outcome: ReconstructionTerminalTaskOutcome,
        analysisProjection: ReconstructionTransientAnalysisProjection? = nil,
        nativeResult: ReconstructionNativeTaskResult? = nil,
        loadedImageAdmission: ReconstructionLoadedImageAdmission? = nil,
        decompileFallbackReason: String? = nil
    ) -> ReconstructionTerminalTaskResult {
        .init(
            jobID: authority.jobID,
            taskID: task.identity.taskID,
            checkpointID: authority.checkpointID,
            checkpointRevision: authority.checkpointRevision,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: outcome,
            analysisProjection: analysisProjection,
            nativeResult: nativeResult,
            loadedImageAdmission: loadedImageAdmission,
            decompileFallbackReason: decompileFallbackReason
        )
    }
}
