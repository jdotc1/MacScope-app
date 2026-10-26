import Foundation

enum DyldCacheAnalysisFailureCode: String, Codable, Equatable, Sendable {
    case cancelled
    case timeout
    case malformedRequest
    case invalidRequest
    case sourceIdentityMismatch
    case subjectIdentityMismatch
    case staleGeneration
    case sourceChanged
    case providerUnavailable
    case providerRejectedInput
    case outputLimitExceeded
    case unexpectedFailure
}
struct RemoteDyldCacheAnalysisFailure: Error, Equatable, LocalizedError {
    let code: DyldCacheAnalysisFailureCode

    var errorDescription: String? {
        switch code {
        case .cancelled: "Dyld cache analysis was cancelled."
        case .timeout: "Dyld cache analysis exceeded its time budget."
        case .malformedRequest: "The dyld cache analysis request was malformed."
        case .invalidRequest: "The dyld cache analysis request was invalid."
        case .sourceIdentityMismatch: "The dyld cache source identity no longer matches."
        case .subjectIdentityMismatch: "The dyld cache result belongs to another artifact or image."
        case .staleGeneration: "The dyld cache result belongs to a stale analysis generation."
        case .sourceChanged: "The dyld cache source changed during inspection."
        case .providerUnavailable: "The dyld cache analysis provider is unavailable."
        case .providerRejectedInput: "The dyld cache analysis provider rejected the input."
        case .outputLimitExceeded: "The dyld cache analysis result exceeded its output limit."
        case .unexpectedFailure: "Dyld cache analysis failed unexpectedly."
        }
    }
}

protocol DyldCacheAnalysisClientWireCodec: Sendable {
    func encodeRequest(_ request: DyldCacheAnalysisRequest) throws -> Data
    func decodeReply(_ data: Data) throws -> DyldCacheAnalysisResult
}

protocol DyldCacheAnalysisWorkerWireCodec: Sendable {
    func decodeRequest(_ data: Data) throws -> DyldCacheAnalysisRequest
    func encodeReply(_ result: Result<DyldCacheAnalysisResult, Error>) -> Data
}

struct DyldCacheAnalysisWireCodec:
    DyldCacheAnalysisClientWireCodec,
    DyldCacheAnalysisWorkerWireCodec
{
    static let wireVersion = 2
    static let maximumRequestBytes = 64 * 1024
    static let maximumReplyBytes = DyldCacheAnalysisLimits.hardMaximum.maximumOutputBytes
        + (1024 * 1024)

    private struct RequestEnvelope: Codable {
        let version: Int
        let path: String
        let expectedSourceIdentity: DyldCacheFileIdentity
        let subject: DyldCacheAnalysisSubjectIdentity
        let categories: [DyldCacheAnalysisCategory]
        let limits: DyldCacheAnalysisLimits
        let requestID: UUID
    }

    private struct ReplyEnvelope: Codable {
        let version: Int
        let result: DyldCacheAnalysisResult?
        let failure: DyldCacheAnalysisFailureCode?
    }

    func encodeRequest(_ request: DyldCacheAnalysisRequest) throws -> Data {
        let request = try request.validated()
        guard request.url.path.utf8.count <= 4_096 else {
            throw DyldCacheAnalysisModelError.invalidPath
        }
        let data = try Self.encoder.encode(RequestEnvelope(
            version: Self.wireVersion,
            path: request.url.path,
            expectedSourceIdentity: request.expectedSourceIdentity,
            subject: request.subject,
            categories: request.categories,
            limits: request.limits,
            requestID: request.requestID
        ))
        guard data.count <= Self.maximumRequestBytes else {
            throw DyldCacheAnalysisProviderError.outputLimitExceeded
        }
        return data
    }

    func decodeRequest(_ data: Data) throws -> DyldCacheAnalysisRequest {
        guard data.count <= Self.maximumRequestBytes else {
            throw DyldCacheAnalysisProviderError.outputLimitExceeded
        }
        let envelope = try Self.decoder.decode(RequestEnvelope.self, from: data)
        guard envelope.version == Self.wireVersion else {
            throw AnalysisWorkerError.versionMismatch(expected: Self.wireVersion, got: envelope.version)
        }
        guard envelope.path.utf8.count <= 4_096,
              envelope.path.hasPrefix("/"),
              !envelope.path.utf8.contains(0) else {
            throw DyldCacheAnalysisModelError.invalidPath
        }
        return try DyldCacheAnalysisRequest(
            url: URL(fileURLWithPath: envelope.path),
            expectedSourceIdentity: envelope.expectedSourceIdentity,
            subject: envelope.subject,
            categories: envelope.categories,
            limits: envelope.limits,
            requestID: envelope.requestID
        ).validated()
    }

    func encodeReply(_ result: Result<DyldCacheAnalysisResult, Error>) -> Data {
        let envelope: ReplyEnvelope
        switch result {
        case let .success(value):
            if let validated = try? value.validated() {
                envelope = ReplyEnvelope(version: Self.wireVersion, result: validated, failure: nil)
            } else {
                envelope = ReplyEnvelope(
                    version: Self.wireVersion,
                    result: nil,
                    failure: .providerRejectedInput
                )
            }
        case let .failure(error):
            envelope = ReplyEnvelope(
                version: Self.wireVersion,
                result: nil,
                failure: Self.failureCode(for: error)
            )
        }
        if let data = try? Self.encoder.encode(envelope) { return data }
        return Self.unexpectedFailureReply
    }

    func decodeReply(_ data: Data) throws -> DyldCacheAnalysisResult {
        guard data.count <= Self.maximumReplyBytes else {
            throw AnalysisWorkerError.malformedReply(reason: "dyld cache reply exceeds wire limit")
        }
        let envelope: ReplyEnvelope
        do {
            envelope = try Self.decoder.decode(ReplyEnvelope.self, from: data)
        } catch {
            throw AnalysisWorkerError.malformedReply(reason: "dyld cache reply is not a valid envelope")
        }
        guard envelope.version == Self.wireVersion else {
            throw AnalysisWorkerError.versionMismatch(expected: Self.wireVersion, got: envelope.version)
        }
        if let result = envelope.result, envelope.failure == nil {
            guard result.version == DyldCacheAnalysisResult.schemaVersion else {
                throw AnalysisWorkerError.versionMismatch(
                    expected: DyldCacheAnalysisResult.schemaVersion,
                    got: result.version
                )
            }
            do {
                return try result.validated()
            } catch {
                throw AnalysisWorkerError.malformedReply(
                    reason: "dyld cache result violates its structural contract"
                )
            }
        }
        if let failure = envelope.failure, envelope.result == nil {
            if failure == .cancelled { throw AnalysisCancelled() }
            throw RemoteDyldCacheAnalysisFailure(code: failure)
        }
        throw AnalysisWorkerError.malformedReply(
            reason: "dyld cache reply contains conflicting fields"
        )
    }

    private static func failureCode(for error: Error) -> DyldCacheAnalysisFailureCode {
        switch error {
        case is AnalysisCancelled:
            .cancelled
        case let error as DyldCacheAnalysisWorkerServiceError:
            error.failureCode
        case let error as DyldCacheAnalysisProviderError:
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
        default:
            .unexpectedFailure
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static let unexpectedFailureReply: Data = {
        (try? encoder.encode(ReplyEnvelope(
            version: wireVersion,
            result: nil,
            failure: .unexpectedFailure
        ))) ?? Data()
    }()
}
