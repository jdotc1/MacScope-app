import Foundation

// MS-18: package rehydrate runs the format loaders in the analysis worker, not in the app.
//
// Rehydration is not part of the single-flight analyze state machine: the worker's request queue
// is concurrent, and a reopen may rehydrate while a structural reanalysis is in flight. It still
// honors a sticky invalidation, maps transport faults exactly like analyze, and records a newly
// observed invalidation.
extension XPCAnalysisProvider {
    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        try rehydrate(
            imageBytes: imageBytes,
            requestedSliceIndex: requestedSliceIndex,
            preserving: persisted,
            overrides: [:],
            cancellation: cancellation
        )
    }

    /// Synchronous bridge, like `analyze`. The caller's cancellation token is polled on the
    /// CALLING thread, so a token that reads `Task.isCancelled` observes the caller's task (the
    /// store's retained rehydration task). Cancellation forwards `cancel(requestID:)` to the worker
    /// and returns `AnalysisCancelled` at once; the abandoned reply is dropped when it arrives.
    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        try rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
            preserving: persisted, overrides: overrides,
            coffSectionLayoutVersion: BinaryLoadSelection.legacyCOFFRehydrateLayoutVersion(for: imageBytes),
            cancellation: cancellation)
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   overrides: [UInt64: AddressOverride], coffSectionLayoutVersion: Int?,
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try rehydrate(
            imageBytes: imageBytes,
            requestedSliceIndex: requestedSliceIndex,
            preserving: persisted,
            overrides: overrides,
            cancellation: cancellation,
            coffSectionLayoutVersion: coffSectionLayoutVersion,
            transferLimits: .standard,
            makeImageSource: { try AnalysisSealedByteDescriptor.make($0) }
        )
    }

    /// PERF-C: the image bytes travel raw on a sealed descriptor (`rehydratePinned`), not as base64
    /// inside the JSON envelope; if no descriptor can be made, they fall back to the inline form.
    /// Oversize image bytes are refused with `AnalysisTransferLimitExceeded` before any encoding,
    /// descriptor or send. `transferLimits` / `makeImageSource` are injectable for tests.
    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken,
        coffSectionLayoutVersion: Int? = nil,
        transferLimits: AnalysisRehydrateTransferLimits,
        makeImageSource: (Data) throws -> FileHandle
    ) throws -> ImageAnalysis {
        try cancellation.check()
        try rehydrateAdmission()

        let requestID = UUID()
        let codec = AnalysisRehydrateWireCodec(limits: transferLimits)
        try codec.preflight(imageByteCount: imageBytes.count)
        let imageSource = try? makeImageSource(imageBytes)
        let payload: Data
        do {
            payload = try codec.encodeRequest(AnalysisRehydrateRequest(
                imageBytes: imageBytes,
                requestedSliceIndex: requestedSliceIndex,
                persisted: persisted,
                overrides: overrides,
                resourceBudget: resourceBudget,
                requestID: requestID,
                coffSectionLayoutVersion: coffSectionLayoutVersion
                    ?? BinaryLoadSelection.legacyCOFFRehydrateLayoutVersion(for: imageBytes)
            ), imageBytesOnDescriptor: imageSource != nil)
        } catch let limit as AnalysisTransferLimitExceeded {
            throw limit
        } catch {
            throw AnalysisWorkerError.workerUnavailable(
                reason: "rehydrate request encoding failed: \(error.localizedDescription)"
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = RehydrateResultBox()
        let transport = self.transport
        Task.detached {
            let result: Result<Data, Error>
            do {
                if let imageSource {
                    result = .success(try await transport.sendRehydratePinned(
                        requestID: requestID, payload: payload, imageSource: imageSource
                    ))
                } else {
                    result = .success(try await transport.sendRehydrate(requestID: requestID, payload: payload))
                }
            } catch {
                result = .failure(error)
            }
            box.store(result)
            semaphore.signal()
        }

        while semaphore.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            if cancellation.isCancelled {
                transport.cancel(requestID: requestID)
                throw AnalysisCancelled()
            }
        }

        let reply: Data
        switch box.take() {
        case .success(let data):
            reply = data
        case .failure(let error):
            switch error {
            case is AnalysisCancelled, is CancellationError:
                throw AnalysisCancelled()
            case AnalysisTransportError.interrupted(let reason):
                throw AnalysisWorkerError.workerCrashed(reason: reason)
            case AnalysisTransportError.invalidated(let reason):
                recordRehydrateInvalidation(reason: reason)
                throw AnalysisWorkerError.workerUnavailable(reason: reason)
            default:
                throw AnalysisWorkerError.workerUnavailable(reason: String(describing: error))
            }
        }

        try cancellation.check(.rehydrate)
        let loader: RehydrationLoaderProducts
        do {
            loader = try codec.decodeLoaderReply(reply, requestID: requestID,
                requestImageByteCount: imageBytes.count, requestedSliceIndex: requestedSliceIndex)
        } catch is AnalysisCancelled {
            throw AnalysisCancelled()
        } catch let failure as RemoteAnalysisFailure {
            throw failure
        } catch let limit as AnalysisTransferLimitExceeded {
            throw limit
        } catch let error as AnalysisWorkerError {
            if case .versionMismatch = error { throw error }
            throw AnalysisWorkerError.malformedReply(reason: String(describing: error))
        } catch {
            throw AnalysisWorkerError.malformedReply(reason: String(describing: error))
        }

        // No binary parser runs here. Exact captured bytes and caller-owned edits meet only
        // worker-admitted mappings/layout, then the shared resolver and collector run locally.
        do {
            return try RehydrationDerivedProducts.rebuild(persisted: persisted, loader: loader,
                imageBytes: imageBytes, overrides: overrides, cancellation: cancellation)
        } catch is AnalysisCancelled {
            throw AnalysisCancelled()
        } catch {
            // An invalid authored patch had the same typed load-failure surface when this
            // postprocessing ran in the worker; keep that recovery behavior after the split.
            throw RemoteAnalysisFailure(message: error.localizedDescription)
        }
    }
}

private final class RehydrateResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func store(_ result: Result<Data, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(AnalysisTransportError.invalidated(reason: "rehydrate reply missing"))
    }
}
