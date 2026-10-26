import Foundation

enum DyldCacheAnalysisWorkerServiceError: Error, Equatable, LocalizedError {
    case malformedRequest
    case invalidRequest
    case cancelled
    case timeout
    case sourceIdentityMismatch
    case subjectIdentityMismatch
    case staleGeneration
    case sourceChanged
    case providerUnavailable
    case providerRejectedInput
    case outputLimitExceeded
    case unexpectedFailure

    var failureCode: DyldCacheAnalysisFailureCode {
        switch self {
        case .malformedRequest: .malformedRequest
        case .invalidRequest: .invalidRequest
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .sourceIdentityMismatch: .sourceIdentityMismatch
        case .subjectIdentityMismatch: .subjectIdentityMismatch
        case .staleGeneration: .staleGeneration
        case .sourceChanged: .sourceChanged
        case .providerUnavailable: .providerUnavailable
        case .providerRejectedInput: .providerRejectedInput
        case .outputLimitExceeded: .outputLimitExceeded
        case .unexpectedFailure: .unexpectedFailure
        }
    }

    var errorDescription: String? {
        RemoteDyldCacheAnalysisFailure(code: failureCode).localizedDescription
    }
}

struct DyldCacheAnalysisWorkerService: Sendable {
    private let provider: any DyldCacheAnalysisWorkerProviding
    private let codec: any DyldCacheAnalysisWorkerWireCodec
    private let cancellationRegistry: AnalysisWorkerCancellationRegistry

    init(
        provider: any DyldCacheAnalysisWorkerProviding,
        codec: any DyldCacheAnalysisWorkerWireCodec
    ) {
        self.provider = provider
        self.codec = codec
        cancellationRegistry = AnalysisWorkerCancellationRegistry()
    }

    static func unavailable() -> Self {
        Self(
            provider: UnavailableDyldCacheAnalysisWorkerProvider(),
            codec: DyldCacheAnalysisWireCodec()
        )
    }

    func handle(requestData: Data, requestID: UUID) -> Data {
        let request: DyldCacheAnalysisRequest
        do {
            request = try codec.decodeRequest(requestData)
        } catch is AnalysisWorkerError {
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.malformedRequest))
        } catch is DecodingError {
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.malformedRequest))
        } catch DyldCacheAnalysisProviderError.outputLimitExceeded {
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.outputLimitExceeded))
        } catch {
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.invalidRequest))
        }

        guard request.requestID == requestID else {
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.invalidRequest))
        }

        let token = cancellationRegistry.register(requestID: requestID)
        defer { cancellationRegistry.deregister(requestID: requestID) }

        do {
            try token.check()
            let rawResult = try provider.inspectCache(request: request, cancellation: token)
            try token.check()
            guard rawResult.version == DyldCacheAnalysisResult.schemaVersion,
                  rawResult.requestID == request.requestID else {
                return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.invalidRequest))
            }
            guard rawResult.subject.analysisGeneration
                    == request.subject.analysisGeneration else {
                return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.staleGeneration))
            }
            guard rawResult.subject.artifactIdentity == request.subject.artifactIdentity,
                  rawResult.subject.imageIdentity == request.subject.imageIdentity else {
                return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.subjectIdentityMismatch))
            }
            guard rawResult.sourceIdentity == request.expectedSourceIdentity else {
                return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.sourceIdentityMismatch))
            }
            let result = try request.validate(result: rawResult)
            guard result.provider == .machOKit0522 else {
                return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.providerRejectedInput))
            }
            let encoded = codec.encodeReply(.success(result))
            guard encoded.count <= request.limits.maximumOutputBytes else {
                return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.outputLimitExceeded))
            }
            return encoded
        } catch is AnalysisCancelled {
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.cancelled))
        } catch let error as DyldCacheAnalysisProviderError {
            return codec.encodeReply(.failure(Self.serviceError(for: error)))
        } catch is DyldCacheAnalysisModelError {
            // The request was already decoded and validated before provider dispatch. A model
            // failure here therefore belongs to untrusted provider output, not caller input.
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.providerRejectedInput))
        } catch {
            // Never return a vendor diagnostic, source path, or input-derived string over XPC.
            return codec.encodeReply(.failure(DyldCacheAnalysisWorkerServiceError.providerRejectedInput))
        }
    }

    func cancel(requestID: UUID) {
        cancellationRegistry.cancel(requestID: requestID)
    }

    private static func serviceError(
        for error: DyldCacheAnalysisProviderError
    ) -> DyldCacheAnalysisWorkerServiceError {
        switch error {
        case .sourceIdentityMismatch: .sourceIdentityMismatch
        case .subjectIdentityMismatch: .subjectIdentityMismatch
        case .staleGeneration: .staleGeneration
        case .sourceChangedDuringInspection: .sourceChanged
        case .providerUnavailable: .providerUnavailable
        case .outputLimitExceeded: .outputLimitExceeded
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .sourceIsNotRegularFile, .unsafeSubcacheSuffix, .providerRejectedInput:
            .providerRejectedInput
        }
    }
}
