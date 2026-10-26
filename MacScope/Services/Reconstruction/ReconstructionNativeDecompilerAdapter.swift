import Foundation

struct ReconstructionNativeDecompilationRequest: Sendable {
    let taskID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let subject: ReconstructionFunctionCoordinate
    let projection: NativeDecompilerProjectionRequest
}

struct ReconstructionNativeTaskSuccess: Equatable, Sendable {
    let taskID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let execution: NativeDecompilerValidatedExecution
}

enum ReconstructionNativeTaskFailure: Equatable, Sendable {
    case authorityMismatch
    case providerUnavailable
}

enum ReconstructionNativeTaskResult: Equatable, Sendable {
    case completed(ReconstructionNativeTaskSuccess)
    case cancelled
    case failed(ReconstructionNativeTaskFailure)
}

protocol ReconstructionNativeTaskDecompiling: Sendable {
    func decompile(
        _ request: ReconstructionNativeDecompilationRequest,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionNativeTaskResult
    func cancelOutstanding() async
    func retire() async
}

actor ReconstructionNativeDecompilerAdapter: ReconstructionNativeTaskDecompiling {
    private let admission: any NativeDecompilerOwnerAdmission
    private var isRetired = false
    private var cancellationGeneration: UInt64 = 0

    init(admission: any NativeDecompilerOwnerAdmission) {
        self.admission = admission
    }

    func decompile(
        _ request: ReconstructionNativeDecompilationRequest,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionNativeTaskResult {
        guard !isRetired else { return .failed(.providerUnavailable) }
        let admittedCancellationGeneration = cancellationGeneration
        do {
            try cancellation.check()
            try Self.validateAuthority(request)
            let execution = try await admission.decompile(
                request.projection,
                cacheLookupPolicy: .allowValidatedCache
            )
            try cancellation.check()
            if let invalidation = lifecycleInvalidation(
                admittedCancellationGeneration: admittedCancellationGeneration
            ) {
                return invalidation
            }
            guard execution.imageSlot == request.projection.imageSlot,
                  execution.functionID == request.projection.functionID,
                  execution.analysisInputFingerprintSHA256
                    == request.subject.analysisFingerprintSHA256,
                  execution.success.result.function.functionID
                    == request.projection.functionID.uuidString.lowercased(),
                  execution.success.result.function.entryAddress.value
                    == request.subject.startAddress,
                  execution.success.result.function.endAddressExclusive.value
                    == request.subject.endAddressExclusive
            else {
                return .failed(.authorityMismatch)
            }
            return .completed(.init(
                taskID: request.taskID,
                checkpointID: request.checkpointID,
                checkpointRevision: request.checkpointRevision,
                corpusManifestSHA256: request.corpusManifestSHA256,
                execution: execution
            ))
        } catch is CancellationError {
            if let invalidation = lifecycleInvalidation(
                admittedCancellationGeneration: admittedCancellationGeneration
            ) {
                return invalidation
            }
            return .cancelled
        } catch is ReconstructionValidationError {
            return .failed(.authorityMismatch)
        } catch let error as NativeDecompilerOwnerAdmissionError
            where error == .ownerRetired {
            return .failed(.providerUnavailable)
        } catch {
            if let invalidation = lifecycleInvalidation(
                admittedCancellationGeneration: admittedCancellationGeneration
            ) {
                return invalidation
            }
            return .failed(.providerUnavailable)
        }
    }

    func cancelOutstanding() async {
        cancellationGeneration &+= 1
        await admission.cancelOutstanding()
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        await admission.retire()
    }

    private func lifecycleInvalidation(
        admittedCancellationGeneration: UInt64
    ) -> ReconstructionNativeTaskResult? {
        if isRetired { return .failed(.providerUnavailable) }
        if cancellationGeneration != admittedCancellationGeneration { return .cancelled }
        return nil
    }

    private static func validateAuthority(
        _ request: ReconstructionNativeDecompilationRequest
    ) throws {
        try ReconstructionValidation.requireSHA256(
            request.corpusManifestSHA256,
            field: "native reconstruction corpus manifest"
        )
        guard request.subject.image.imageSlot == request.projection.imageSlot,
              request.subject.analysisFingerprintSHA256
                == request.projection.analysisInputFingerprintSHA256,
              let reboundFunction = ReconstructionReboundFunctionAuthority.resolve(
                  request.subject,
                  in: request.projection.workspace
              ),
              reboundFunction.id == request.projection.functionID
        else {
            throw ReconstructionValidationError.invalidReference(
                field: "native reconstruction projection authority"
            )
        }
    }
}
