import Foundation

struct AnalysisWorkerProcessIdentity: Codable, Equatable, Sendable {
    let startupNonce: UUID
    let processID: Int32
}

struct AnalysisWorkerControlReply: Codable, Sendable {
    let schemaVersion: Int
    let challenge: UUID
    // The actual producing process identity, never an echoed caller identity.
    let identity: AnalysisWorkerProcessIdentity
    let accepted: Bool
}

/// No process construction or termination implementation belongs in the shared target.
protocol AnalysisWorkerProcessControlling: AnyObject, Sendable {
    var identity: AnalysisWorkerProcessIdentity { get }
    func requestTermination(expectedNonce: UUID) -> Bool
}

protocol PatternWorkerWatchdog: AnyObject, Sendable {
    var identity: AnalysisWorkerProcessIdentity { get }
    func arm(requestID: UUID, expectedNonce: UUID, timeoutMS: Int,
             abort: @escaping @Sendable () -> Void) -> Bool
    func nativeReturned(requestID: UUID)
}

/// Worker-side policy with injectable scheduling/actions; production actions exist only in
/// AnalysisWorkerService. A self-watchdog does NOT cover a fully frozen process. No signal
/// acknowledgement proves exit; a future host observer must keep that process quarantined.
final class AnalysisWorkerDeadlineWatchdog: PatternWorkerWatchdog, @unchecked Sendable {
    typealias Schedule = @Sendable (Int, @escaping @Sendable () -> Void) -> Void
    private struct Flight {
        let token: UUID
        let abort: @Sendable () -> Void
        var expired = false
        var escalated = false
    }
    let identity: AnalysisWorkerProcessIdentity
    private let lock = NSLock()
    private let schedule: Schedule
    private let terminateSelf: @Sendable () -> Void
    private let graceMS: Int
    private var active: [UUID: Flight] = [:]
    private var seen: Set<UUID> = []
    private var quarantined = false
    private let capacity: Int

    init(identity: AnalysisWorkerProcessIdentity, graceMS: Int = 250, capacity: Int = 4096,
         schedule: @escaping Schedule, terminateSelf: @escaping @Sendable () -> Void) {
        self.identity = identity
        self.graceMS = max(1, graceMS)
        self.capacity = max(0, capacity)
        self.schedule = schedule
        self.terminateSelf = terminateSelf
    }

    func arm(requestID: UUID, expectedNonce: UUID, timeoutMS: Int,
             abort: @escaping @Sendable () -> Void) -> Bool {
        let token = UUID()
        let admitted = lock.withLock {
            guard identity.processID > 0, expectedNonce == identity.startupNonce,
                  (1...2000).contains(timeoutMS), !quarantined,
                  seen.count < capacity, !seen.contains(requestID) else { return false }
            seen.insert(requestID)
            active[requestID] = Flight(token: token, abort: abort)
            return true
        }
        guard admitted else { return false }
        schedule(timeoutMS) { [weak self] in self?.expire(requestID: requestID, token: token) }
        return true
    }

    private func expire(requestID: UUID, token: UUID) {
        let abort: (@Sendable () -> Void)? = lock.withLock {
            guard var flight = active[requestID], flight.token == token,
                  !flight.expired else { return nil }
            flight.expired = true
            active[requestID] = flight
            quarantined = true
            return flight.abort
        }
        guard let abort else { return }
        // Arm escalation BEFORE invoking cancellation, which could itself stall.
        schedule(graceMS) { [weak self] in self?.escalate(requestID: requestID, token: token) }
        abort()
    }

    private func escalate(requestID: UUID, token: UUID) {
        let shouldTerminate = lock.withLock {
            guard var flight = active[requestID], flight.token == token,
                  flight.expired, !flight.escalated else { return false }
            flight.escalated = true
            active[requestID] = flight
            return true
        }
        // A return racing this decision may still retire this already quarantined worker.
        // Only this process is targeted; no retained remote PID is signalled.
        if shouldTerminate { terminateSelf() }
    }

    func nativeReturned(requestID: UUID) {
        lock.withLock { _ = active.removeValue(forKey: requestID) }
        // Expired processes never reopen, even if a late native return arrives.
    }
}

/// Host bookkeeping foundation only. No production admission adapter is installed in this
/// slice. The future signed challenge/registered observer adapter supplies identity + binding.
/// Cancellation, invalidation and timer expiry never establish native return or process exit.
final class AnalysisWorkerSupervision: @unchecked Sendable {
    enum Phase: Equatable { case idle, running, quarantined, exitObserved }
    private let lock = NSLock()
    private let identity: AnalysisWorkerProcessIdentity
    private let observerID: UUID
    private var phase: Phase = .idle
    private var flights: Set<UUID> = []
    private var seen: Set<UUID> = []
    private let capacity: Int

    init(identity: AnalysisWorkerProcessIdentity, observerID: UUID, capacity: Int = 4096) {
        self.identity = identity
        self.observerID = observerID
        self.capacity = max(0, capacity)
    }

    var currentPhase: Phase { lock.withLock { phase } }
    var unresolvedCount: Int { lock.withLock { flights.count } }

    func register(requestID: UUID, expectedNonce: UUID) -> Bool {
        lock.withLock {
            guard identity.processID > 0, expectedNonce == identity.startupNonce,
                  phase == .idle || phase == .running,
                  seen.count < capacity, !seen.contains(requestID) else { return false }
            seen.insert(requestID)
            flights.insert(requestID)
            phase = .running
            return true
        }
    }

    func deadlineExpired(requestID: UUID) {
        lock.withLock {
            if flights.contains(requestID), phase != .exitObserved { phase = .quarantined }
        }
    }

    /// An actual authenticated same-operation return, never a transport/control acknowledgement.
    func nativeReturned(requestID: UUID, producingNonce: UUID) {
        lock.withLock {
            guard producingNonce == identity.startupNonce else { return }
            flights.remove(requestID)
            if flights.isEmpty, phase == .running { phase = .idle }
        }
    }

    /// Must be called only by the retained, registered observer binding. Numeric PID equality,
    /// connection interruption/invalidation and successful signal delivery are insufficient.
    func observedExit(identity exited: AnalysisWorkerProcessIdentity, observerID: UUID) {
        lock.withLock {
            guard exited == identity, observerID == self.observerID else { return }
            flights.removeAll()
            phase = .exitObserved
        }
    }
}

// MARK: - Proposed owned-child contract vocabulary (no runtime integration)

/// See docs/design/P4-SUPERVISOR-CONTRACT.md. These inert types do not turn the
/// self-watchdog above into a child supervisor or authorize any PID-only app kill.
enum AnalysisWorkerOwnedChildChannel: String, Codable, Hashable, Sendable {
    case pattern, decompiler, analysis, dyld, rea
}

/// Created only from a successful worker-owned spawn and matched first handshake
/// in the future adapter. PID is usable for signals only while this exact child
/// remains unreaped under the sole owner queue. Never reconstruct from NSXPC PID.
struct AnalysisWorkerOwnedChildIdentity: Codable, Equatable, Sendable {
    let parentStartupNonce: UUID
    let spawnNonce: UUID
    let processID: Int32
    let channel: AnalysisWorkerOwnedChildChannel
    let requestID: UUID
    let connectionGeneration: UUID
}

/// Caller settlement is separate from native flight/reap state. Abort, signal
/// delivery and NSXPC invalidation never produce the reaped state. A parent loss
/// leaves exitUnconfirmed, even after a replacement XPC process is reachable.
enum AnalysisWorkerOwnedChildPhase: String, Codable, Sendable {
    case spawning, awaitingHandshake, running, nativeReturned
    case abortRequested, killRequested, exitUnconfirmed, reaped
}

/// Decode only a positive exact-PID terminal waitpid result in the sole reaper.
/// ECHILD, EINTR, stopped/continued status, or signal acknowledgement cannot mint it.
enum AnalysisWorkerOwnedChildTermination: Codable, Equatable, Sendable {
    case exited(code: Int32)
    case signalled(signal: Int32, coreDumped: Bool)
}

/// A proposed transport receipt, not a production proof constructor. A future
/// adapter must restrict minting to the sole reaper and validate the full identity;
/// decoding this Codable value alone does not establish process termination.
struct AnalysisWorkerOwnedChildExitReceipt: Codable, Equatable, Sendable {
    let identity: AnalysisWorkerOwnedChildIdentity
    let rawWaitStatus: Int32
    let termination: AnalysisWorkerOwnedChildTermination
}
