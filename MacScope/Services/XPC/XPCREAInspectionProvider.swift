import Foundation

final class XPCREAInspectionProvider: Sendable {
    enum Failure: Error, Equatable, Sendable { case timeout, operationMismatch }
    private let transport: any REAInspectionTransport
    private let timeoutNanoseconds: UInt64
    init(transport: any REAInspectionTransport, timeout: TimeInterval = 30) {
        self.transport = transport
        timeoutNanoseconds = UInt64(min(max(timeout.isFinite ? timeout : 30, 0.001), 30) * 1_000_000_000)
    }
    func inspect(requestData: Data, requestID: UUID, operation: REAInspectionOperation,
                 implementationIdentity: String) async throws -> Data {
        try Task.checkCancellation()
        let header = try REAInspectionWireCodec.validateRequest(requestData, requestID: requestID)
        guard header.operation == operation else { throw Failure.operationMismatch }
        let waiter = REAClientWaiter()
        let transport = transport
        let timer = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            waiter.finish(.failure(Failure.timeout)) {
                transport.cancelREAInspection(requestID: requestID)
                transport.retireREAConnection(requestID: requestID)
            }
        }
        Task {
            do {
                let data = try await transport.sendREAInspection(requestID: requestID, payload: requestData)
                _ = waiter.finish(.success(data))
            } catch { _ = waiter.finish(.failure(error)) }
        }
        let data = try await withTaskCancellationHandler {
            defer { timer.cancel() }
            return try await waiter.value()
        } onCancel: {
            waiter.finish(.failure(CancellationError())) {
                transport.cancelREAInspection(requestID: requestID)
                transport.retireREAConnection(requestID: requestID)
            }
        }
        try Task.checkCancellation()
        try REAInspectionWireCodec.validateResponse(data, requestID: requestID,
            operation: operation, implementationIdentity: implementationIdentity)
        return data
    }
}

private final class REAClientWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    @discardableResult func finish(_ result: Result<Data, Error>, beforeResume: () -> Void = {}) -> Bool {
        let saved: (Bool, CheckedContinuation<Data, Error>?) = lock.withLock {
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let current = continuation; continuation = nil
            return (true, current)
        }
        if saved.0 { beforeResume() }
        saved.1?.resume(with: result)
        return saved.0
    }
    func value() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let saved = lock.withLock { () -> Result<Data, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil as Result<Data, Error>?
            }
            if let saved { continuation.resume(with: saved) }
        }
    }
}
