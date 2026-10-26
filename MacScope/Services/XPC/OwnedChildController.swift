import Foundation

struct OwnedChildRequestKey: Hashable, Sendable {
    let channel: AnalysisWorkerOwnedChildChannel
    let requestID: UUID
    let connectionGeneration: UUID
}
struct OwnedChildLaunch: Sendable {
    let parent: AnalysisWorkerProcessIdentity
    let spawnNonce: UUID
    let key: OwnedChildRequestKey
}
struct OwnedChildPolicy: Sendable {
    let timeoutMS: Int
    let abortGraceMS: Int
    let cleanupGraceMS: Int
    let maximumRequestBytes: Int
    let maximumReplyBytes: Int
}
enum OwnedChildSpawnResult: Sendable {
    case created(pid: Int32)
    case notCreated(errno: Int32)
    // The adapter cannot prove that no child was created. Never release admission.
    case ownershipUncertain(errno: Int32)
}
enum OwnedChildWaitResult: Sendable {
    case pending, interrupted, nonterminal
    case terminal(pid: Int32, rawStatus: Int32, termination: AnalysisWorkerOwnedChildTermination)
    case failed(errno: Int32)
}
enum OwnedChildSignalResult: Equatable, Sendable { case sent, failed(errno: Int32) }
enum OwnedChildCommand: Sendable { case initialize, execute(Data), abort, shutdown }

/// Future worker-only adapter supplies posix_spawn/pipes/kill/waitpid. All methods run on
/// the controller's sole owner queue, must be nonblocking, and must never synchronously
/// reenter it. send queues a bounded pipe write; it must not wait for a child/native call.
/// preservesWaitableChildren asserts SIG_DFL, no SA_NOCLDWAIT and exclusive waiter
/// ownership for this controller's entire lifetime, not just a signal-disposition snapshot.
/// No other parent subsystem may change those invariants while any child is unresolved.
/// No production adapter or worker entrypoint is supplied in this source tranche.
protocol OwnedChildProcessOperations: Sendable {
    func preservesWaitableChildren() -> Bool
    func spawn(_ launch: OwnedChildLaunch) -> OwnedChildSpawnResult
    func send(_ command: OwnedChildCommand, to identity: AnalysisWorkerOwnedChildIdentity) -> Bool
    func signalKill(_ identity: AnalysisWorkerOwnedChildIdentity) -> OwnedChildSignalResult
    func waitNoHang(_ identity: AnalysisWorkerOwnedChildIdentity) -> OwnedChildWaitResult
    /// After exact terminal waitpid, finish the bounded stdout drain/decoder before calling
    /// a missing terminal frame a protocol failure. Return only a validated same-key reply.
    /// Nonblocking: child has exited, descendants are forbidden, and buffers remain bounded.
    func finalReplyAfterExit(_ identity: AnalysisWorkerOwnedChildIdentity) -> Data?
}

/// Instantiate once per worker process when future composition is granted. The injected
/// operations have no production implementation here; the app never gains signal authority.
final class OwnedChildController: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable {
        case busy, unavailable, invalidPolicy, duplicateRequest
        case spawnFailed(Int32), ownershipLost(Int32), supervisorLost
        case invalidSpawnIdentity, invalidReapIdentity
        case timedOut, cancelled, protocolFailure, deliveryFailed
        case childExited(Int32), childSignalled(Int32)
    }
    enum Event: Sendable {
        case settled(AnalysisWorkerOwnedChildIdentity, Result<Data, Failure>)
        case quarantined(AnalysisWorkerOwnedChildIdentity, Failure)
        case signalAttempt(AnalysisWorkerOwnedChildIdentity, OwnedChildSignalResult)
        case reaped(AnalysisWorkerOwnedChildExitReceipt)
        case admissionReleased(AnalysisWorkerOwnedChildIdentity)
    }
    typealias Schedule = @Sendable (Int, @escaping @Sendable () -> Void) -> Void
    private struct LogicalKey: Hashable {
        let channel: AnalysisWorkerOwnedChildChannel
        let requestID: UUID
    }
    private struct Record {
        let identity: AnalysisWorkerOwnedChildIdentity
        let policy: OwnedChildPolicy
        var payload: Data
        var phase: AnalysisWorkerOwnedChildPhase = .awaitingHandshake
        var settled = false
        var returned = false
        // Phase can advance to abortRequested without a handshake; preserve dispatch
        // authority independently so no terminal path can infer it from phase alone.
        var dispatched = false
        var authority = true
        var failure: Failure?
        var graceToken: UUID?
    }
    private let queue = DispatchQueue(label: "org.macscope.app.owned-child-controller")
    private let parent: AnalysisWorkerProcessIdentity
    private let ops: any OwnedChildProcessOperations
    private let schedule: Schedule
    private let sink: @Sendable (Event) -> Void
    private let capacity: Int
    private var seen: Set<LogicalKey> = []
    private var record: Record?
    private var disabled = false
    private var uncertainLaunch: OwnedChildLaunch?
    private let eventLock = NSLock()
    private var outbox: [Event] = []
    private var delivering = false

    /// schedule must defer callbacks (never invoke inline) using monotonic relative delays.
    /// The live adapter must bind its lifecycle to this controller until every child is reaped;
    /// dropping this object or losing the supervisor is NOT release of an outstanding lease.
    init(parent: AnalysisWorkerProcessIdentity, operations: any OwnedChildProcessOperations,
         capacity: Int = 4096, schedule: @escaping Schedule,
         events: @escaping @Sendable (Event) -> Void) {
        self.parent = parent; ops = operations; self.capacity = max(0, capacity)
        self.schedule = schedule; sink = events
    }

    var admissionAvailable: Bool { queue.sync { record == nil && !disabled && parent.processID > 1 } }
    var phase: AnalysisWorkerOwnedChildPhase? {
        queue.sync { record?.phase ?? (uncertainLaunch == nil ? nil : .exitUnconfirmed) }
    }

    func start(key: OwnedChildRequestKey, payload: Data, policy: OwnedChildPolicy)
        -> Result<AnalysisWorkerOwnedChildIdentity, Failure> {
        var initialEvents: [Event] = []
        let result: Result<AnalysisWorkerOwnedChildIdentity, Failure> = queue.sync {
            defer { enqueue(initialEvents) }
            guard !disabled, parent.processID > 1 else { return .failure(.unavailable) }
            guard record == nil else { return .failure(.busy) }
            guard policy.timeoutMS > 0, policy.abortGraceMS > 0, policy.cleanupGraceMS > 0,
                  policy.maximumRequestBytes > 0, policy.maximumReplyBytes > 0,
                  payload.count <= policy.maximumRequestBytes else { return .failure(.invalidPolicy) }
            let logical = LogicalKey(channel: key.channel, requestID: key.requestID)
            guard seen.count < capacity, !seen.contains(logical) else { return .failure(.duplicateRequest) }
            guard ops.preservesWaitableChildren() else { disabled = true; return .failure(.unavailable) }
            seen.insert(logical)
            let launch = OwnedChildLaunch(parent: parent, spawnNonce: UUID(), key: key)
            // Armed before spawn. A future monotonic adapter must not extend these deadlines
            // on partial output. Only a matching record can act when these callbacks arrive.
            schedule(policy.timeoutMS) { [weak self] in self?.deadline(launch.spawnNonce) }
            schedule(min(2000, policy.timeoutMS)) { [weak self] in self?.handshakeDeadline(launch.spawnNonce) }
            switch ops.spawn(launch) {
            case .notCreated(let error): return .failure(.spawnFailed(error))
            case .ownershipUncertain(let error):
                disabled = true; uncertainLaunch = launch // No trustworthy PID to signal/reap.
                return .failure(.ownershipLost(error))
            case .created(let pid):
                guard pid > 1, pid != parent.processID else {
                    disabled = true; uncertainLaunch = launch; return .failure(.invalidSpawnIdentity)
                }
                let identity = AnalysisWorkerOwnedChildIdentity(parentStartupNonce: parent.startupNonce,
                    spawnNonce: launch.spawnNonce, processID: pid, channel: key.channel,
                    requestID: key.requestID, connectionGeneration: key.connectionGeneration)
                record = Record(identity: identity, policy: policy, payload: payload)
                armPoll(identity)
                if !ops.send(.initialize, to: identity) {
                    // Start still returns the owned identity. Caller can never mistake an
                    // uncertain delivery for a failed spawn with no native lease.
                    initialEvents = beginAbort(.deliveryFailed)
                }
                return .success(identity)
            }
        }
        drainEvents()
        return result
    }

    /// Only the bounded pipe decoder may pass a fully validated first handshake here.
    func acceptHandshake(_ identity: AnalysisWorkerOwnedChildIdentity) {
        perform {
            guard var current = record, current.identity == identity, current.authority,
                  current.phase == .awaitingHandshake else { return [] }
            current.phase = .running
            current.dispatched = true
            let payload = current.payload
            current.payload = Data()
            record = current // Register before dispatch; no native request precedes handshake.
            return ops.send(.execute(payload), to: identity) ? [] : beginAbort(.deliveryFailed)
        }
    }

    func rejectProtocol(_ identity: AnalysisWorkerOwnedChildIdentity) {
        abort(identity, reason: .protocolFailure)
    }
    func cancel(_ identity: AnalysisWorkerOwnedChildIdentity) { abort(identity, reason: .cancelled) }
    func deliveryFailed(_ identity: AnalysisWorkerOwnedChildIdentity) { abort(identity, reason: .deliveryFailed) }

    /// Actual same-operation terminal evidence from the bounded authenticated child stream.
    /// A control acknowledgement or pipe EOF must never invoke this method.
    func nativeReturned(_ identity: AnalysisWorkerOwnedChildIdentity, payload: Data) {
        perform {
            guard var current = record, current.identity == identity, current.authority,
                  current.dispatched, !current.returned else { return [] }
            guard payload.count <= current.policy.maximumReplyBytes else { return beginAbort(.protocolFailure) }
            current.returned = true; current.phase = .nativeReturned
            let token = UUID(); current.graceToken = token
            let shouldSettle = !current.settled
            current.settled = true
            record = current
            schedule(current.policy.cleanupGraceMS) { [weak self] in self?.escalate(identity, token: token) }
            _ = ops.send(.shutdown, to: identity)
            return shouldSettle ? [.settled(identity, .success(payload))] : []
        }
    }

    /// Ownership/lifecycle loss, NOT an NSXPC interruption/invalidation notification.
    /// Retain the unresolved record and disable every future spawn/signal/wait operation.
    func supervisorLost() {
        perform {
            disabled = true
            return loseAuthority(.supervisorLost)
        }
    }

    private func abort(_ identity: AnalysisWorkerOwnedChildIdentity, reason: Failure) {
        perform {
            guard record?.identity == identity, record?.authority == true else { return [] }
            return beginAbort(reason)
        }
    }
    private func deadline(_ nonce: UUID) {
        perform {
            guard record?.identity.spawnNonce == nonce, record?.returned == false,
                  record?.authority == true else { return [] }
            return beginAbort(.timedOut)
        }
    }
    private func handshakeDeadline(_ nonce: UUID) {
        perform {
            guard record?.identity.spawnNonce == nonce, record?.phase == .awaitingHandshake,
                  record?.authority == true else { return [] }
            return beginAbort(.timedOut)
        }
    }
    private func beginAbort(_ reason: Failure) -> [Event] {
        guard var current = record, current.authority, current.failure == nil,
              !current.returned else { return [] }
        current.failure = reason; current.phase = .abortRequested
        let token = UUID(); current.graceToken = token
        let shouldSettle = !current.settled
        current.settled = true; record = current
        // All process ops are nonblocking. A failed abort write is still followed by kill/reap.
        let identity = current.identity
        schedule(current.policy.abortGraceMS) { [weak self] in self?.escalate(identity, token: token) }
        _ = ops.send(.abort, to: current.identity)
        var events: [Event] = [.quarantined(current.identity, reason)]
        if shouldSettle { events.append(.settled(current.identity, .failure(reason))) }
        return events
    }
    private func escalate(_ identity: AnalysisWorkerOwnedChildIdentity, token: UUID) {
        perform {
            guard var current = record, current.identity == identity, current.authority,
                  current.graceToken == token else { return [] }
            current.graceToken = nil; current.phase = .killRequested; record = current
            // Same queue as waitNoHang, with unreaped ownership still held through the signal.
            let result = ops.signalKill(identity)
            record?.phase = .exitUnconfirmed
            return [.signalAttempt(identity, result)] // Never release on success, ESRCH or EPERM.
        }
    }
    private func armPoll(_ identity: AnalysisWorkerOwnedChildIdentity) {
        schedule(10) { [weak self] in self?.poll(identity) }
    }
    private func poll(_ identity: AnalysisWorkerOwnedChildIdentity) {
        perform {
            guard let current = record, current.identity == identity, current.authority else { return [] }
            switch ops.waitNoHang(identity) {
            case .pending, .interrupted, .nonterminal:
                armPoll(identity); return []
            case .failed(let error): return loseAuthority(.ownershipLost(error))
            case .terminal(let pid, let rawStatus, let termination):
                guard pid == identity.processID else { return loseAuthority(.invalidReapIdentity) }
                record = nil // Retire signal authority BEFORE any external callback can run.
                let finalReply = ops.finalReplyAfterExit(identity)
                let receipt = AnalysisWorkerOwnedChildExitReceipt(identity: identity,
                    rawWaitStatus: rawStatus, termination: termination)
                var events: [Event] = [.reaped(receipt)]
                if !current.settled {
                    if current.dispatched, let finalReply,
                       finalReply.count <= current.policy.maximumReplyBytes {
                        // Reaping can beat delivery of a fully buffered terminal frame.
                        events.append(.settled(identity, .success(finalReply)))
                    } else {
                        let failure: Failure
                        switch termination {
                        case .exited(let code): failure = code == 0 ? .protocolFailure : .childExited(code)
                        case .signalled(let signal, _): failure = .childSignalled(signal)
                        }
                        events.append(.settled(identity, .failure(finalReply == nil ? failure : .protocolFailure)))
                    }
                }
                events.append(.admissionReleased(identity))
                return events
            }
        }
    }
    private func loseAuthority(_ reason: Failure) -> [Event] {
        disabled = true
        guard var current = record, current.authority else { return [] }
        current.authority = false; current.phase = .exitUnconfirmed; current.graceToken = nil
        let shouldSettle = !current.settled
        current.settled = true; record = current
        var events: [Event] = [.quarantined(current.identity, reason)]
        if shouldSettle { events.append(.settled(current.identity, .failure(reason))) }
        return events
    }
    private func perform(_ body: () -> [Event]) {
        queue.sync { enqueue(body()) }
        drainEvents()
    }
    private func enqueue(_ events: [Event]) {
        eventLock.withLock { outbox.append(contentsOf: events) }
    }
    private func drainEvents() {
        let takeDelivery = eventLock.withLock {
            guard !delivering else { return false }
            delivering = true
            return true
        }
        guard takeDelivery else { return }
        while true {
            let next: Event? = eventLock.withLock {
                guard !outbox.isEmpty else { delivering = false; return nil }
                return outbox.removeFirst()
            }
            guard let next else { return }
            // Transition order is preserved, but callbacks hold neither owner queue nor
            // event lock. A callback can safely reenter and append further transitions.
            sink(next)
        }
    }
}
