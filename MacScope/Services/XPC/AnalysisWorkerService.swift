import Foundation

// `AnalysisRequest` and the wire-codec protocols now live in `AnalysisWireCodec.swift` (the
// unified seam). This file owns only the worker service logic and its failure taxonomy.

/// Stable semantic failures that the worker asks its injected codec to encode.
enum AnalysisWorkerServiceError: Error, Equatable, LocalizedError {
    case malformedRequest
    case cancelled
    case analysisFailed(String)
    case unexpectedFailure(String)

    var errorDescription: String? {
        switch self {
        case .malformedRequest:
            "The analysis request is malformed."
        case .cancelled:
            "Analysis was cancelled."
        case let .analysisFailed(description):
            description
        case let .unexpectedFailure(description):
            "Analysis failed unexpectedly: \(description)"
        }
    }
}

/// Unit-testable worker logic, intentionally independent of `NSXPCListener` and target wiring.
struct AnalysisWorkerService: Sendable {
    let engine: any AnalysisProviding
    private let codec: any AnalysisWorkerWireCodec
    let cancellationRegistry: AnalysisWorkerCancellationRegistry
    private let hostResourceBudget: @Sendable () -> AnalysisResourceBudget

    init(engine: any AnalysisProviding, codec: any AnalysisWorkerWireCodec,
         hostResourceBudget: @escaping @Sendable () -> AnalysisResourceBudget = { .interactive }) {
        self.engine = engine
        self.codec = codec
        self.hostResourceBudget = hostResourceBudget
        cancellationRegistry = AnalysisWorkerCancellationRegistry()
    }

    /// The request's CPU ceiling, never above this host's current interactive ceiling (PERF-B).
    func admittedBudget(_ requested: AnalysisResourceBudget?) -> AnalysisResourceBudget {
        let current = hostResourceBudget()
        return requested?.clamped(to: current) ?? current
    }

    /// Decodes, analyzes, and encodes without allowing any error to escape this service boundary.
    ///
    /// `pinnedSource` is the descriptor `analyzePinned` transferred (PERF-C2). The engine reads it
    /// through `/dev/fd/N` (or `pinnedURL` when given), and a successful reply describes the image
    /// bytes as a verified range of it instead of carrying them, when such a range exists.
    func handle(requestData: Data, requestID: UUID, pinnedURL: URL? = nil, pinnedSource: FileHandle? = nil) -> Data {
        let request: AnalysisRequest
        do {
            request = try codec.decodeRequest(requestData)
        } catch {
            return codec.encodeReply(.failure(AnalysisWorkerServiceError.malformedRequest))
        }

        // HOP-3: the budget's clock starts at registration, after decoding; an early cancel still wins.
        let token = cancellationRegistry.register(requestID: requestID, budget: request.analysisBudget ?? .unlimited)
        defer { cancellationRegistry.deregister(requestID: requestID) }

        do {
            let snapshot = try AnalysisParallelism.withBudget(
                admittedBudget(request.resourceBudget)
            ) {
                try engine.analyze(
                    url: pinnedURL
                        ?? pinnedSource.map { URL(fileURLWithPath: "/dev/fd/\($0.fileDescriptor)") }
                        ?? request.url,
                    selection: request.selection,
                    overrides: request.overrides,
                    cancellation: token
                )
            }
            let pinnedImageBytes = pinnedSource.flatMap {
                AnalysisPinnedImageBytes.locate(snapshot.imageBytes, in: $0, selection: request.selection)
            }
            return codec.encodeReply(.success(snapshot), pinnedImageBytes: pinnedImageBytes)
        } catch is AnalysisCancelled {
            return codec.encodeReply(.failure(AnalysisWorkerServiceError.cancelled))
        } catch let error as AnalysisBudgetExceeded {
            // Typed on the wire; mapping it to `.unexpected` lost the phase and the reason.
            return codec.encodeReply(.failure(error))
        } catch let error as AnalysisEngineError {
            return codec.encodeReply(
                .failure(AnalysisWorkerServiceError.analysisFailed(error.localizedDescription))
            )
        } catch let error as ELFArchiveLoadError {
            return codec.encodeReply(
                .failure(AnalysisWorkerServiceError.analysisFailed(error.localizedDescription))
            )
        } catch let error as BinaryLoadSelectionError {
            return codec.encodeReply(
                .failure(AnalysisWorkerServiceError.analysisFailed(error.localizedDescription))
            )
        } catch {
            return codec.encodeReply(
                .failure(AnalysisWorkerServiceError.unexpectedFailure(error.localizedDescription))
            )
        }
    }

    func cancel(requestID: UUID) {
        cancellationRegistry.cancel(requestID: requestID)
    }

    /// HOP-3: the encoded `AnalysisProgressReply` for a poll; unknown IDs answer phase nil.
    func progressReply(requestID: UUID) -> Data {
        AnalysisProgressReply(requestID: requestID, progress: cancellationRegistry.progress(requestID: requestID)).encoded()
    }
}
