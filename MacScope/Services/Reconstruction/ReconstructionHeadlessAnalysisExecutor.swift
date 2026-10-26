import Foundation

enum ReconstructionHeadlessImageAuthorityIntent: Equatable, Sendable {
    /// `loadBinary` may establish the first durable image binding for an artifact occurrence.
    case initialLoad
    /// Every later task must arrive with an already committed image binding.
    case existingImage
}

struct ReconstructionHeadlessAnalysisRequest: Sendable {
    let source: ReconstructionAttachmentSource
    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding?
    /// Compatibility-only convenience hint. `functionCoordinate` is the durable authority;
    /// artifact/image graph work intentionally carries neither value.
    let functionID: UUID?
    let functionCoordinate: ReconstructionFunctionCoordinate?
    let overrides: [UInt64: AddressOverride]
    let imageAuthorityIntent: ReconstructionHeadlessImageAuthorityIntent

    init(
        source: ReconstructionAttachmentSource,
        artifact: ReconstructionArtifactCoordinate,
        image: ReconstructionImageBinding?,
        functionID: UUID?,
        overrides: [UInt64: AddressOverride],
        imageAuthorityIntent: ReconstructionHeadlessImageAuthorityIntent = .existingImage,
        functionCoordinate: ReconstructionFunctionCoordinate? = nil
    ) {
        self.source = source
        self.artifact = artifact
        self.image = image
        self.functionID = functionID
        self.functionCoordinate = functionCoordinate
        self.overrides = overrides
        self.imageAuthorityIntent = imageAuthorityIntent
    }
}

struct ReconstructionHeadlessAnalysisResult: Sendable {
    let detached: ReconstructionDetachedAnalysisSnapshot
    let projection: NativeDecompilerProjectionRequest?
}

protocol ReconstructionHeadlessAnalysisExecuting: Sendable {
    func execute(
        _ request: ReconstructionHeadlessAnalysisRequest,
        cancellation: ReconstructionCancellation
    ) async throws -> ReconstructionHeadlessAnalysisResult

    func pause() async
    func resume() async
    func retire() async
}

actor ReconstructionHeadlessAnalysisExecutor: ReconstructionHeadlessAnalysisExecuting {
    private let pool: ReconstructionAnalysisProviderPool

    init(pool: ReconstructionAnalysisProviderPool) {
        self.pool = pool
    }

    func execute(
        _ request: ReconstructionHeadlessAnalysisRequest,
        cancellation: ReconstructionCancellation
    ) async throws -> ReconstructionHeadlessAnalysisResult {
        try cancellation.check()
        switch request.imageAuthorityIntent {
        case .initialLoad:
            guard request.functionID == nil, request.functionCoordinate == nil else {
                throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
            }
        case .existingImage:
            guard request.image != nil else {
                throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
            }
        }
        guard request.functionID == nil || request.functionCoordinate != nil else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        return try await pool.withProvider { provider in
            var detached = try await ReconstructionDetachedAnalysisSnapshotBuilder.build(
                source: request.source,
                artifact: request.artifact,
                expectedImage: request.image,
                provider: provider,
                overrides: request.overrides,
                cancellation: cancellation
            )
            try cancellation.check()
            let projection: NativeDecompilerProjectionRequest?
            if let functionCoordinate = request.functionCoordinate {
                let rebound = try ReconstructionStableImageAuthority.bindFunction(
                    functionCoordinate,
                    artifact: request.artifact,
                    in: .init(
                        image: detached.image,
                        workspace: detached.workspace,
                        analysisInputFingerprintSHA256:
                            detached.analysisInputFingerprintSHA256
                    )
                )
                detached = .init(
                    artifact: detached.artifact,
                    image: rebound.snapshot.image,
                    workspace: rebound.snapshot.workspace,
                    analysisInputFingerprintSHA256:
                        rebound.snapshot.analysisInputFingerprintSHA256
                )
                projection = try NativeDecompilerProjectionRequest(
                    workspace: detached.workspace,
                    imageSlot: detached.image.imageSlot,
                    functionID: rebound.functionID,
                    analysisInputFingerprintSHA256: detached.analysisInputFingerprintSHA256
                )
            } else {
                projection = nil
            }
            return .init(detached: detached, projection: projection)
        }
    }

    func pause() async {
        await pool.pause()
    }

    func resume() async {
        await pool.resume()
    }

    func retire() async {
        await pool.retire()
    }
}
