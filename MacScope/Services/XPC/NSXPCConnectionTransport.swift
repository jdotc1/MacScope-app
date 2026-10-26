import Darwin
import Foundation

/// Narrow adapter over `NSXPCConnection` used to fault-test the transport without launching a
/// service process. The production adapter below forwards each operation directly to Foundation.
protocol AnalysisXPCConnecting: AnyObject {
    var remoteProcessIdentifier: pid_t? { get }
    func setRemoteObjectInterface(_ interface: NSXPCInterface)
    /// Installs the peer code-signing requirement (`NSXPCConnection.setCodeSigningRequirement`).
    func setCodeSigningRequirement(_ requirement: String)
    func setInterruptionHandler(_ handler: @escaping () -> Void)
    func setInvalidationHandler(_ handler: @escaping () -> Void)
    func resume()
    func invalidate()
    func remoteObjectProxy(withErrorHandler handler: @escaping (Error) -> Void) -> Any?
}

/// Real `AnalysisTransport` backed by the bundled analysis-worker XPC service.
///
/// A connection interruption fails only requests currently in flight. The same
/// `NSXPCConnection` remains installed so Foundation can relaunch/reconnect the on-demand service
/// when `XPCAnalysisProvider` permits the next request. Invalidation retires the connection;
/// after the provider's explicit `resetConnection()`, the next send creates a fresh one.
final class NSXPCConnectionTransport: AnalysisTransport, DyldCacheAnalysisTransport, REAInspectionTransport, PatternInterpretationTransport, @unchecked Sendable {
    static let serviceName = "org.macscope.app.AnalysisWorker"

    typealias ConnectionFactory = (String) -> any AnalysisXPCConnecting

    private struct ConnectionRecord {
        let id: UUID
        let connection: any AnalysisXPCConnecting
    }

    private struct PendingRequest {
        let connectionID: UUID
        let continuation: CheckedContinuation<Data, Error>
    }

    private enum RequestChannel: Hashable {
        case analysis
        case dyldCache
    }

    private struct PendingRequestKey: Hashable {
        let channel: RequestChannel
        let requestID: UUID
    }

    private let lock = NSLock()
    private let requestedServiceName: String
    private let connectionFactory: ConnectionFactory
    private let patternChannel: any PatternInterpretationTransport
    private let reaChannel: REAConnectionChannel
    private var connectionRecord: ConnectionRecord?
    private var pendingRequests: [PendingRequestKey: PendingRequest] = [:]

    var remoteProcessIdentifier: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return connectionRecord?.connection.remoteProcessIdentifier
    }

    init(
        serviceName: String = NSXPCConnectionTransport.serviceName,
        connectionFactory: @escaping ConnectionFactory = { LiveAnalysisXPCConnection(serviceName: $0) },
        patternChannel: any PatternInterpretationTransport = UnavailablePatternInterpretationTransport()
    ) {
        requestedServiceName = serviceName
        self.connectionFactory = connectionFactory
        self.patternChannel = patternChannel
        reaChannel = REAConnectionChannel(serviceName: serviceName, factory: connectionFactory)

        // Match the plugin-host lifecycle: configure the interface and resume a real connection
        // as part of transport construction, before the first request is issued.
        lock.lock()
        _ = activeConnectionLocked()
        lock.unlock()
    }

    var patternAvailable: Bool { patternChannel.patternAvailable }
    func sendPatternInterpretation(requestID: UUID, payload: Data) async throws -> Data {
        try await patternChannel.sendPatternInterpretation(requestID: requestID, payload: payload)
    }
    func cancelPatternInterpretation(requestID: UUID) {
        patternChannel.cancelPatternInterpretation(requestID: requestID)
    }

    func sendREAInspection(requestID: UUID, payload: Data) async throws -> Data {
        try await reaChannel.send(requestID: requestID, payload: payload)
    }
    func cancelREAInspection(requestID: UUID) { reaChannel.cancel(requestID) }
    func retireREAConnection(requestID: UUID) { reaChannel.retire(requestID) }

    private enum AnalysisSelector {
        case analyze
        case analyzePinned(FileHandle)
        case rehydrate
        case rehydratePinned(FileHandle)
    }

    func send(requestID: UUID, payload: Data) async throws -> Data {
        try await send(requestID: requestID, payload: payload, selector: .analyze)
    }

    func sendPinned(requestID: UUID, payload: Data, source: FileHandle) async throws -> Data {
        try await send(requestID: requestID, payload: payload, selector: .analyzePinned(source))
    }

    func sendRehydrate(requestID: UUID, payload: Data) async throws -> Data {
        try await send(requestID: requestID, payload: payload, selector: .rehydrate)
    }

    func sendRehydratePinned(requestID: UUID, payload: Data, imageSource: FileHandle) async throws -> Data {
        try await send(requestID: requestID, payload: payload, selector: .rehydratePinned(imageSource))
    }

    private func send(requestID: UUID, payload: Data, selector: AnalysisSelector) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let key = PendingRequestKey(channel: .analysis, requestID: requestID)
            let record: ConnectionRecord
            let displaced: PendingRequest?

            lock.lock()
            record = activeConnectionLocked()
            displaced = pendingRequests.updateValue(
                PendingRequest(connectionID: record.id, continuation: continuation),
                forKey: key
            )
            lock.unlock()

            displaced?.continuation.resume(
                throwing: AnalysisTransportError.invalidated(
                    reason: "duplicate request identifier \(requestID.uuidString)"
                )
            )

            let proxy = record.connection.remoteObjectProxy { [weak self] error in
                self?.failDelivery(
                    channel: .analysis,
                    requestID: requestID,
                    connectionID: record.id,
                    reason: error.localizedDescription
                )
            }
            guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
                failDelivery(
                    channel: .analysis,
                    requestID: requestID,
                    connectionID: record.id,
                    reason: "analysis worker remote proxy is unavailable"
                )
                return
            }

            let completion: (Data) -> Void = { [weak self] replyData in
                self?.complete(
                    channel: .analysis,
                    requestID: requestID,
                    connectionID: record.id,
                    with: .success(replyData)
                )
            }
            switch selector {
            case .analyze:
                worker.analyze(requestData: payload, requestID: requestID, with: completion)
            case .analyzePinned(let source):
                worker.analyzePinned(requestData: payload, requestID: requestID, source: source, with: completion)
            case .rehydrate:
                worker.rehydrate(requestData: payload, requestID: requestID, with: completion)
            case .rehydratePinned(let imageSource):
                worker.rehydratePinned(requestData: payload, requestID: requestID,
                                       imageSource: imageSource, with: completion)
            }
        }
    }

    func sendDyldCacheInspection(requestID: UUID, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let key = PendingRequestKey(channel: .dyldCache, requestID: requestID)
            let record: ConnectionRecord
            let displaced: PendingRequest?

            lock.lock()
            record = activeConnectionLocked()
            displaced = pendingRequests.updateValue(
                PendingRequest(connectionID: record.id, continuation: continuation),
                forKey: key
            )
            lock.unlock()

            displaced?.continuation.resume(
                throwing: AnalysisTransportError.invalidated(
                    reason: "duplicate dyld-cache request identifier \(requestID.uuidString)"
                )
            )

            let proxy = record.connection.remoteObjectProxy { [weak self] error in
                self?.failDelivery(
                    channel: .dyldCache,
                    requestID: requestID,
                    connectionID: record.id,
                    reason: error.localizedDescription
                )
            }
            guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
                failDelivery(
                    channel: .dyldCache,
                    requestID: requestID,
                    connectionID: record.id,
                    reason: "analysis worker dyld-cache proxy is unavailable"
                )
                return
            }

            worker.inspectDyldCache(
                requestData: payload,
                requestID: requestID
            ) { [weak self] replyData in
                self?.complete(
                    channel: .dyldCache,
                    requestID: requestID,
                    connectionID: record.id,
                    with: .success(replyData)
                )
            }
        }
    }

    func cancel(requestID: UUID) {
        let record: ConnectionRecord?
        lock.lock()
        record = connectionRecord
        lock.unlock()

        // Forward even when the matching analyze call has not reached the service yet. The
        // worker's cancellation registry intentionally remembers this early-cancel race.
        // If the connection already ended, its lifecycle handler completed any pending send and
        // there is no surviving proxy to notify.
        guard let record else { return }
        let proxy = record.connection.remoteObjectProxy { [weak self] error in
            self?.failDelivery(
                channel: .analysis,
                requestID: requestID,
                connectionID: record.id,
                reason: error.localizedDescription
            )
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            failDelivery(
                channel: .analysis,
                requestID: requestID,
                connectionID: record.id,
                reason: "analysis worker remote proxy is unavailable during cancellation"
            )
            return
        }
        worker.cancel(requestID: requestID)
    }

    /// HOP-3: polls the live connection for `requestID`'s phase. Never opens a connection and never
    /// fails the request it asks about: an error, an older worker or no answer within a second is nil.
    func progress(requestID: UUID) async -> AnalysisProgress? {
        guard let record = lock.withLock({ connectionRecord }) else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ProgressPollOnce(continuation)
            let proxy = record.connection.remoteObjectProxy { _ in once.finish(nil) }
            guard let worker = proxy as? AnalysisWorkerXPCProtocol, let poll = worker.progress else {
                once.finish(nil)
                return
            }
            poll(requestID) { data in once.finish(AnalysisProgressReply.decode(data)?.progress(for: requestID)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { once.finish(nil) }
        }
    }

    func cancelDyldCacheInspection(requestID: UUID) {
        let record: ConnectionRecord?
        lock.lock()
        record = connectionRecord
        lock.unlock()

        guard let record else { return }
        let proxy = record.connection.remoteObjectProxy { [weak self] error in
            self?.failDelivery(
                channel: .dyldCache,
                requestID: requestID,
                connectionID: record.id,
                reason: error.localizedDescription
            )
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            failDelivery(
                channel: .dyldCache,
                requestID: requestID,
                connectionID: record.id,
                reason: "analysis worker dyld-cache proxy is unavailable during cancellation"
            )
            return
        }
        worker.cancelDyldCacheInspection(requestID: requestID)
    }

    func retireDyldCacheConnection(requestID: UUID) {
        let connectionToInvalidate: (any AnalysisXPCConnecting)?
        let continuations: [CheckedContinuation<Data, Error>]

        lock.lock()
        if let record = connectionRecord,
           pendingRequests[PendingRequestKey(channel: .dyldCache, requestID: requestID)]?.connectionID
                == record.id {
            connectionToInvalidate = record.connection
            connectionRecord = nil
            let keys = pendingRequests.compactMap { key, pending in
                pending.connectionID == record.id ? key : nil
            }
            continuations = keys.compactMap { key in
                pendingRequests.removeValue(forKey: key)?.continuation
            }
        } else {
            connectionToInvalidate = nil
            continuations = []
        }
        lock.unlock()

        let error = AnalysisTransportError.invalidated(
            reason: "dyld-cache deadline retired the worker connection"
        )
        continuations.forEach { $0.resume(throwing: error) }
        connectionToInvalidate?.invalidate()
    }

    private func activeConnectionLocked() -> ConnectionRecord {
        if let connectionRecord { return connectionRecord }

        let recordID = UUID()
        let connection = connectionFactory(requestedServiceName)
        // Peer authentication before any configuration the worker could observe:
        // the app accepts replies only from the signed analysis service.
        connection.setCodeSigningRequirement(AnalysisWorkerXPCPeerRequirement.worker)
        let interface = NSXPCInterface(with: AnalysisWorkerXPCProtocol.self)
        connection.setRemoteObjectInterface(interface)
        connection.setInterruptionHandler { [weak self] in
            self?.handleInterruption(connectionID: recordID)
        }
        connection.setInvalidationHandler { [weak self] in
            self?.handleInvalidation(connectionID: recordID)
        }
        let record = ConnectionRecord(id: recordID, connection: connection)
        connectionRecord = record
        connection.resume()
        return record
    }

    private func handleInterruption(connectionID: UUID) {
        let continuations = takePendingContinuations(connectionID: connectionID, retireConnection: false)
        let error = AnalysisTransportError.interrupted(reason: "connection interrupted")
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func handleInvalidation(connectionID: UUID) {
        let continuations = takePendingContinuations(connectionID: connectionID, retireConnection: true)
        let error = AnalysisTransportError.invalidated(reason: "connection invalidated")
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func takePendingContinuations(
        connectionID: UUID,
        retireConnection: Bool
    ) -> [CheckedContinuation<Data, Error>] {
        lock.lock()
        defer { lock.unlock() }

        guard connectionRecord?.id == connectionID else { return [] }
        if retireConnection {
            connectionRecord = nil
        }

        let matchingRequestKeys = pendingRequests.compactMap { key, pending in
            pending.connectionID == connectionID ? key : nil
        }
        return matchingRequestKeys.compactMap { key in
            pendingRequests.removeValue(forKey: key)?.continuation
        }
    }

    private func failDelivery(
        channel: RequestChannel,
        requestID: UUID,
        connectionID: UUID,
        reason: String
    ) {
        let connectionToInvalidate: (any AnalysisXPCConnecting)?
        let continuations: [CheckedContinuation<Data, Error>]

        lock.lock()
        if connectionRecord?.id == connectionID {
            connectionToInvalidate = connectionRecord?.connection
            connectionRecord = nil
            let matchingRequestKeys = pendingRequests.compactMap { key, pending in
                pending.connectionID == connectionID ? key : nil
            }
            continuations = matchingRequestKeys.compactMap { key in
                pendingRequests.removeValue(forKey: key)?.continuation
            }
        } else {
            connectionToInvalidate = nil
            // A stale generation cannot retire the current connection, but complete its own
            // request if that callback raced with generation replacement.
            let key = PendingRequestKey(channel: channel, requestID: requestID)
            if pendingRequests[key]?.connectionID == connectionID,
               let continuation = pendingRequests.removeValue(forKey: key)?.continuation {
                continuations = [continuation]
            } else {
                continuations = []
            }
        }
        lock.unlock()

        let error = AnalysisTransportError.invalidated(reason: reason)
        continuations.forEach { $0.resume(throwing: error) }
        // Retire a proxy that could not deliver. Its later invalidation callback is generation-
        // checked and therefore cannot disturb a replacement connection or double-resume.
        connectionToInvalidate?.invalidate()
    }

    private func complete(
        channel: RequestChannel,
        requestID: UUID,
        connectionID: UUID,
        with result: Result<Data, Error>
    ) {
        let continuation: CheckedContinuation<Data, Error>?
        let key = PendingRequestKey(channel: channel, requestID: requestID)
        lock.lock()
        if pendingRequests[key]?.connectionID == connectionID {
            continuation = pendingRequests.removeValue(forKey: key)?.continuation
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class LiveAnalysisXPCConnection: AnalysisXPCConnecting {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        connection = NSXPCConnection(serviceName: serviceName)
    }

    var remoteProcessIdentifier: pid_t? { connection.processIdentifier }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {
        connection.remoteObjectInterface = interface
    }

    func setCodeSigningRequirement(_ requirement: String) {
        connection.setCodeSigningRequirement(requirement)
    }

    func setInterruptionHandler(_ handler: @escaping () -> Void) {
        connection.interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping () -> Void) {
        connection.invalidationHandler = handler
    }

    func resume() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func remoteObjectProxy(withErrorHandler handler: @escaping (Error) -> Void) -> Any? {
        connection.remoteObjectProxyWithErrorHandler(handler)
    }
}

/// Resumes a progress poll's continuation exactly once (reply, error handler or timeout).
private final class ProgressPollOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AnalysisProgress?, Never>?

    init(_ continuation: CheckedContinuation<AnalysisProgress?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: AnalysisProgress?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
