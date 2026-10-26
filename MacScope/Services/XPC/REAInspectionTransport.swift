import Foundation

protocol REAInspectionTransport: Sendable {
    func sendREAInspection(requestID: UUID, payload: Data) async throws -> Data
    func cancelREAInspection(requestID: UUID)
    /// Retires only the client connection/waiter. This is not worker termination proof.
    func retireREAConnection(requestID: UUID)
}

/// Separate authenticated REA connections keep retirement from failing ordinary analysis.
/// Every callback is bound to a unique generation; late replies cannot settle a replacement.
final class REAConnectionChannel: @unchecked Sendable {
    private struct Pending {
        let generation: UUID
        let connection: any AnalysisXPCConnecting
        let continuation: CheckedContinuation<Data, Error>
    }
    private let lock = NSLock()
    private let serviceName: String
    private let factory: NSXPCConnectionTransport.ConnectionFactory
    private var pending: [UUID: Pending] = [:]
    private var seen: Set<UUID> = []
    private var cancelled: Set<UUID> = []
    private var saturated = false
    init(serviceName: String, factory: @escaping NSXPCConnectionTransport.ConnectionFactory) {
        self.serviceName = serviceName; self.factory = factory
    }
    func send(requestID: UUID, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let generation = UUID(), connection = factory(serviceName)
            connection.setCodeSigningRequirement(AnalysisWorkerXPCPeerRequirement.worker)
            connection.setRemoteObjectInterface(NSXPCInterface(with: AnalysisWorkerXPCProtocol.self))
            let rejection: Error? = lock.withLock {
                guard !saturated, pending.count < 128, seen.count < 65_536 else {
                    return AnalysisTransportError.invalidated(reason: "REA transport capacity unavailable")
                }
                guard !seen.contains(requestID) else {
                    return AnalysisTransportError.invalidated(reason: "duplicate REA request identifier")
                }
                seen.insert(requestID)
                if cancelled.remove(requestID) != nil { return CancellationError() }
                pending[requestID] = .init(generation: generation, connection: connection, continuation: continuation)
                return nil
            }
            if let rejection { continuation.resume(throwing: rejection); return }
            connection.setInterruptionHandler { [weak self] in
                self?.finish(requestID, generation, .failure(AnalysisTransportError.interrupted(reason: "REA connection interrupted")))
            }
            connection.setInvalidationHandler { [weak self] in
                self?.finish(requestID, generation, .failure(AnalysisTransportError.invalidated(reason: "REA connection invalidated")))
            }
            guard lock.withLock({ pending[requestID]?.generation == generation }) else {
                connection.invalidate(); return
            }
            connection.resume()
            let proxy = connection.remoteObjectProxy { [weak self] _ in
                self?.finish(requestID, generation, .failure(AnalysisTransportError.invalidated(reason: "REA delivery failed")))
            }
            guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
                finish(requestID, generation, .failure(AnalysisTransportError.invalidated(reason: "REA proxy unavailable"))); return
            }
            // A cancellation can remove registration while interface/proxy setup was running.
            let remains = lock.withLock { pending[requestID]?.generation == generation }
            guard remains else { connection.invalidate(); return }
            worker.inspectREA(requestData: payload, requestID: requestID) { [weak self] data in
                self?.finish(requestID, generation, .success(data))
            }
        }
    }
    func cancel(_ id: UUID) {
        let record: Pending? = lock.withLock {
            if let record = pending[id] { return record }
            if !seen.contains(id) {
                if cancelled.count < 4_096 { cancelled.insert(id) } else { saturated = true }
            }
            return nil
        }
        guard let record else { return }
        if let worker = record.connection.remoteObjectProxy(withErrorHandler: { _ in }) as? AnalysisWorkerXPCProtocol {
            worker.cancelREAInspection(requestID: id)
        }
    }
    func retire(_ id: UUID) {
        cancel(id)
        let record = lock.withLock { pending[id] }
        if let record { finish(id, record.generation, .failure(CancellationError())) }
    }
    private func finish(_ id: UUID, _ generation: UUID, _ result: Result<Data, Error>) {
        let record: Pending? = lock.withLock {
            guard pending[id]?.generation == generation else { return nil }
            return pending.removeValue(forKey: id)
        }
        guard let record else { return }
        record.continuation.resume(with: result)
        record.connection.invalidate()
    }
}
