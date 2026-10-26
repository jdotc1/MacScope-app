import Combine
import Foundation

/// Serial execution keeps superseded bounded audits from multiplying CPU work.
/// The unchanged engine has no intra-audit cancellation checkpoints: cancellation
/// retires publication immediately, and queued work checks cancellation before entry.
private actor UnwindAuditWorker {
    func load(_ capture: @Sendable () throws -> LoadedBinary) throws -> LoadedBinary {
        try Task.checkCancellation()
        let binary = try capture()
        try Task.checkCancellation()
        return binary
    }

    func audit(_ binary: LoadedBinary, limits: UnwindAuditLimits) throws -> UnwindAuditReport {
        try Task.checkCancellation()
        let report = try UnwindAuditService.audit(binary: binary, limits: limits)
        try Task.checkCancellation()
        return report
    }
}

@MainActor
final class UnwindAuditCoordinator: ObservableObject {
    typealias Runner = @Sendable (LoadedBinary, UnwindAuditLimits) async throws -> UnwindAuditReport

    @Published private(set) var state = UnwindAuditResultState()
    /// Synchronous notification after the request/generation fence accepts publication.
    var onAcceptedPublication: (@MainActor (UnwindAuditReport, UnwindAuditRequest) -> Void)?
    private let runner: Runner
    private let worker: UnwindAuditWorker
    private var task: Task<Void, Never>?

    init(runner: Runner? = nil) {
        let worker = UnwindAuditWorker()
        self.worker = worker
        self.runner = runner ?? { binary, limits in try await worker.audit(binary, limits: limits) }
    }

    deinit { task?.cancel() }

    func activate(_ key: UnwindAuditResultKey?) {
        guard state.key != key else { return }
        task?.cancel()
        task = nil
        state.activate(key)
    }

    @discardableResult
    func start(binary: LoadedBinary, key: UnwindAuditResultKey) -> Task<Void, Never>? {
        task?.cancel()
        let request = state.begin(key)
        guard binary.artifactIntegrityState == .verified,
              binary.artifactIdentity == key.identity,
              key.modelID == UnwindAuditResultKey.currentModelID else {
            state.fail("A verified loaded image and the supported audit model are required.", for: request)
            task = nil
            return nil
        }
        return launch(request: request) { binary }
    }

    /// Parsing and the bounded engine share the serial worker, keeping both off
    /// the main actor. Captured inputs never reopen a path or follow current focus.
    @discardableResult
    func start(key: UnwindAuditResultKey,
               load: @escaping @Sendable () throws -> LoadedBinary) -> Task<Void, Never> {
        task?.cancel()
        return launch(request: state.begin(key), load: load)
    }

    private func launch(request: UnwindAuditRequest,
                        load: @escaping @Sendable () throws -> LoadedBinary) -> Task<Void, Never> {
        let runner = runner
        let worker = worker
        let task = Task { [weak self] in
            do {
                let binary = try await worker.load(load)
                guard binary.artifactIntegrityState == .verified,
                      binary.artifactIdentity == request.key.identity,
                      request.key.modelID == UnwindAuditResultKey.currentModelID else {
                    throw MachOBinaryLoader.RetainedInputError.unverifiedIdentity
                }
                try Task.checkCancellation()
                let report = try await runner(binary, request.key.configuration)
                // Even an uncooperative runner must pass the request and generation fence.
                if let self, self.state.publish(report, for: request) {
                    self.onAcceptedPublication?(report, request)
                }
            } catch {
                self?.state.fail(String(describing: error), for: request)
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        task?.cancel()
        task = nil
        state.cancel()
    }
}
