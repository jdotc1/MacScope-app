import Foundation

// MS-18: package rehydrate runs the format loaders in the analysis worker. The handler shares the
// analyze path's cancellation registry, so the client's `cancel(requestID:)` reaches it unchanged.
extension AnalysisWorkerService {
    /// Decodes, rehydrates, and encodes without allowing any error to escape the service boundary.
    /// Loader refusals (including MS-14's PE string budgets) come back as typed load failures;
    /// PERF-C transfer-cap refusals come back as typed `AnalysisTransferLimitExceeded` failures.
    /// `imageSource` is the sealed descriptor carrying the image bytes (PERF-C); nil for the
    /// inline form.
    func handleRehydrate(
        requestData: Data,
        requestID: UUID,
        imageSource: FileHandle? = nil,
        codec: AnalysisRehydrateWireCodec = AnalysisRehydrateWireCodec()
    ) -> Data {
        let request: AnalysisRehydrateLoaderRequest
        do {
            request = try codec.decodeRequest(requestData, imageSource: imageSource)
            guard request.requestID == requestID else {
                return codec.encodeLoaderReply(.failure(AnalysisWorkerServiceError.malformedRequest))
            }
        } catch let error as AnalysisWorkerError {
            return codec.encodeLoaderReply(.failure(AnalysisWorkerServiceError.unexpectedFailure(
                error.localizedDescription
            )))
        } catch let error as AnalysisTransferLimitExceeded {
            return codec.encodeLoaderReply(.failure(error))
        } catch {
            return codec.encodeLoaderReply(.failure(AnalysisWorkerServiceError.malformedRequest))
        }

        let token = cancellationRegistry.register(requestID: requestID)
        defer { cancellationRegistry.deregister(requestID: requestID) }

        do {
            guard let loaderProvider = engine as? any RehydrationLoaderProductsProviding else {
                throw AnalysisWorkerServiceError.unexpectedFailure(
                    "The injected analysis provider does not support loader-only rehydration."
                )
            }
            let loader = try AnalysisParallelism.withBudget(
                admittedBudget(request.resourceBudget)
            ) {
                try loaderProvider.rehydrateLoaderProducts(
                    imageBytes: request.imageBytes,
                    requestedSliceIndex: request.requestedSliceIndex,
                    requestID: request.requestID,
                    coffSectionLayoutVersion: request.coffSectionLayoutVersion,
                    cancellation: token
                )
            }
            return codec.encodeLoaderReply(.success(loader))
        } catch is AnalysisCancelled {
            return codec.encodeLoaderReply(.failure(AnalysisWorkerServiceError.cancelled))
        } catch {
            if token.isCancelled {
                return codec.encodeLoaderReply(.failure(AnalysisWorkerServiceError.cancelled))
            }
            return codec.encodeLoaderReply(.failure(AnalysisWorkerServiceError.analysisFailed(
                error.localizedDescription
            )))
        }
    }
}
