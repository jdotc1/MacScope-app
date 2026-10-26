import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

protocol Phase2AIWorkerModelLifecycleHandling: Sendable {
    func performModelLifecycle(
        request: Phase2AIWorkerModelLifecycleRequest,
        reserveDispatch: @escaping @Sendable () -> Bool
    ) async -> Phase2AIWorkerModelLifecycleReply
}

/// MTPLX model lifecycle remains external. No legacy wire may dispatch a
/// retired provider's load/unload mutation through the production worker.
struct Phase2LiveModelLifecycleHandler: Phase2AIWorkerModelLifecycleHandling, Sendable {
    func performModelLifecycle(
        request: Phase2AIWorkerModelLifecycleRequest,
        reserveDispatch: @escaping @Sendable () -> Bool
    ) async -> Phase2AIWorkerModelLifecycleReply {
        .init(schemaVersion: Phase2AIWorkerModelLifecycleWireCodec.schemaVersion,
              effectID: request.effectID, profileID: request.profileID,
              generation: request.generation, operationKind: request.operation.kind,
              status: .incompatibleBeforeDispatch, receipt: nil)
    }
}
