import Darwin
import Foundation
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

protocol Phase2DurableShellBrokerProcessIdentityObserving: Sendable {
    func observe(
        processIdentifier: Int32,
        expectedExecutablePath: String
    ) -> Phase2DurableShellBrokerProcessIdentity?
}

struct Phase2SystemDurableShellBrokerProcessIdentityObserver: Phase2DurableShellBrokerProcessIdentityObserving {
    func observe(
        processIdentifier pid: Int32,
        expectedExecutablePath: String
    ) -> Phase2DurableShellBrokerProcessIdentity? {
        guard let first = snapshot(processIdentifier: pid),
              let second = snapshot(processIdentifier: pid),
              first.processIdentifier == pid,
              second.processIdentifier == pid,
              first.startSeconds == second.startSeconds,
              first.startMicroseconds == second.startMicroseconds,
              first.executablePath == second.executablePath,
              first.processGroupIdentifier == second.processGroupIdentifier,
              first.executablePath == expectedExecutablePath,
              canonicalPath(first.executablePath) == canonicalPath(expectedExecutablePath)
        else { return nil }

        let seconds = first.startSeconds
        let microseconds = first.startMicroseconds
        let startNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let subsecondNanoseconds = microseconds.multipliedReportingOverflow(by: 1_000)
        guard !startNanoseconds.overflow, !subsecondNanoseconds.overflow else { return nil }
        let total = startNanoseconds.partialValue.addingReportingOverflow(subsecondNanoseconds.partialValue)
        guard !total.overflow else { return nil }
        return Phase2DurableShellBrokerProcessIdentity(
            processIdentifier: pid,
            processStartTimeUnixNanoseconds: total.partialValue,
            executablePath: first.executablePath,
            processGroupIdentifier: first.processGroupIdentifier
        )
    }

    private func snapshot(processIdentifier pid: Int32) -> (
        processIdentifier: Int32,
        startSeconds: UInt64,
        startMicroseconds: UInt64,
        executablePath: String,
        processGroupIdentifier: Int32
    )? {
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.stride
        let observed = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(infoSize))
        }
        guard observed == infoSize else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathByteCount = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathByteCount > 0 else { return nil }
        let observedPath = String(decoding: pathBuffer.prefix(Int(pathByteCount)).map(UInt8.init(bitPattern:)), as: UTF8.self)
        let processGroup = getpgid(pid)
        guard processGroup > 1 else { return nil }
        return (
            processIdentifier: Int32(bitPattern: info.pbi_pid),
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec),
            executablePath: observedPath,
            processGroupIdentifier: processGroup
        )
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

final class Phase2DurableShellBrokerRegistry: @unchecked Sendable {
    struct SessionHandle: @unchecked Sendable {
        let identity: Phase2DurableShellBrokerIdentity
        let lease: Phase2ShellBrokerProcessLease
    }

    struct TranscriptSnapshot: Equatable, Sendable {
        let events: [Phase2HumanPTYTranscriptEvent]
        let nextSequence: UInt64
    }

    enum RegistryError: Error, Equatable {
        case invalidLaunchRequest
        case invalidCapabilitySecret
        case launchIdentityMismatch
        case processIdentityUnavailable
        case duplicateSession
        case duplicateCapability
        case sessionNotFound
        case invalidTranscriptRequest
        case authenticationFailed([Phase2DurableShellBrokerAuthenticationIssue])
    }

    private struct Record {
        let identity: Phase2DurableShellBrokerIdentity
        let lease: Phase2ShellBrokerProcessLease
        let drainID: UUID
        var attachedClientIDs: Set<UUID>
        var lastHeartbeatByClientID: [UUID: Date]
        var detachedDeadline: Date?
        var isCommitted: Bool
        var transcriptEvents: [Phase2HumanPTYTranscriptEvent]
        var nextTranscriptSequence: UInt64
        let transcriptLimits: Phase2HumanPTYTranscriptLimits
    }

    static let maximumDurableLifetime: TimeInterval = 24 * 60 * 60
    static let maximumCreationClockSkew: TimeInterval = 5 * 60
    static let heartbeatTimeout: TimeInterval = 5 * 60
    static let detachedGrace: TimeInterval = 2 * 60
    static let expirySweepInterval: TimeInterval = 30
    private static let maximumDrainBurstBytes = 256 * 1_024
    private static let maximumDrainBurstReads = 64

    let brokerIncarnationID: UUID
    private let lock = NSLock()
    private let processIdentityObserver: any Phase2DurableShellBrokerProcessIdentityObserving
    private let maximumDurableLifetime: TimeInterval
    private let heartbeatTimeout: TimeInterval
    private let detachedGrace: TimeInterval
    private let drainQueue = DispatchQueue(
        label: "org.macscope.app.shell-broker.durable-pty-drain",
        qos: .userInitiated
    )
    private var expiryTimer: DispatchSourceTimer?
    private var records: [UUID: Record] = [:]
    var registrationWillPublish: (@Sendable () -> Void)?

    init(
        brokerIncarnationID: UUID = UUID(),
        processIdentityObserver: any Phase2DurableShellBrokerProcessIdentityObserving = Phase2SystemDurableShellBrokerProcessIdentityObserver(),
        maximumDurableLifetime: TimeInterval = Phase2DurableShellBrokerRegistry.maximumDurableLifetime,
        heartbeatTimeout: TimeInterval = Phase2DurableShellBrokerRegistry.heartbeatTimeout,
        detachedGrace: TimeInterval = Phase2DurableShellBrokerRegistry.detachedGrace,
        startExpirySweeper: Bool = true
    ) {
        self.brokerIncarnationID = brokerIncarnationID
        self.processIdentityObserver = processIdentityObserver
        self.maximumDurableLifetime = maximumDurableLifetime
        self.heartbeatTimeout = heartbeatTimeout
        self.detachedGrace = detachedGrace
        if startExpirySweeper {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.macscope.app.shell-broker.expiry"))
            timer.schedule(
                deadline: .now() + Self.expirySweepInterval,
                repeating: Self.expirySweepInterval
            )
            timer.setEventHandler { [weak self] in
                _ = self?.cleanupExpired()
            }
            timer.resume()
            expiryTimer = timer
        }
    }

    deinit { expiryTimer?.cancel() }

    func register(
        launchRequest: Phase2DurableShellBrokerLaunchRequest,
        capabilitySecretBytes: [UInt8],
        lease: Phase2ShellBrokerProcessLease,
        clientID: UUID,
        initialTranscriptEvents: [Phase2HumanPTYTranscriptEvent] = [],
        nextTranscriptSequence: UInt64 = 1,
        now: Date = Date()
    ) throws -> Phase2DurableShellBrokerIdentity {
        guard launchRequest.isStructurallyValid else { throw RegistryError.invalidLaunchRequest }
        guard launchRequest.brokerIncarnationID == brokerIncarnationID,
              launchRequest.sessionID == lease.ownedProcess.sessionID,
              launchRequest.requestID == lease.ownedProcess.requestID,
              launchRequest.executablePath == lease.ownedProcess.executablePath,
              launchRequest.arguments == lease.plan.arguments,
              launchRequest.workingDirectoryPath == lease.plan.workingDirectoryPath
        else { throw RegistryError.launchIdentityMismatch }

        let secret: Phase2DurableShellBrokerCapabilitySecret
        do {
            secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(capabilitySecretBytes))
        } catch {
            throw RegistryError.invalidCapabilitySecret
        }
        guard lease.isRunning else { throw RegistryError.processIdentityUnavailable }
        guard let processIdentity = processIdentityObserver.observe(
            processIdentifier: lease.ownedProcess.processIdentifier,
            expectedExecutablePath: lease.ownedProcess.executablePath
        ), lease.isRunning,
              processIdentity.processIdentifier == lease.ownedProcess.processIdentifier,
              processIdentity.executablePath == lease.ownedProcess.executablePath
        else {
            throw RegistryError.processIdentityUnavailable
        }
        guard launchRequest.createdAt <= now.addingTimeInterval(Self.maximumCreationClockSkew) else {
            throw RegistryError.invalidLaunchRequest
        }
        let effectiveCreatedAt = max(now, launchRequest.createdAt)
        let maximumExpiry = now.addingTimeInterval(maximumDurableLifetime)
        let effectiveExpiry = min(launchRequest.expiresAt, maximumExpiry)
        guard effectiveCreatedAt < effectiveExpiry else { throw RegistryError.invalidLaunchRequest }
        let identity = Phase2DurableShellBrokerIdentity(
            launchRequest: launchRequest,
            processIdentity: processIdentity,
            createdAt: effectiveCreatedAt,
            expiresAt: effectiveExpiry,
            nextTranscriptSequence: nextTranscriptSequence,
            capabilityVerifierSHA256: secret.verifier(
                launchRequest: launchRequest,
                processIdentity: processIdentity
            )
        )
        guard identity.isStructurallyValid else { throw RegistryError.invalidLaunchRequest }
        guard nextTranscriptSequence > (initialTranscriptEvents.map(\.sequence).max() ?? 0),
              initialTranscriptEvents.allSatisfy({ $0.sessionID == identity.sessionID })
        else { throw RegistryError.invalidLaunchRequest }

        registrationWillPublish?()
        let drainID = UUID()
        try lock.withLock {
            guard records[identity.sessionID] == nil else { throw RegistryError.duplicateSession }
            guard !records.values.contains(where: { $0.identity.capabilityID == identity.capabilityID }) else {
                throw RegistryError.duplicateCapability
            }
            records[identity.sessionID] = Record(
                identity: identity,
                lease: lease,
                drainID: drainID,
                attachedClientIDs: [clientID],
                lastHeartbeatByClientID: [clientID: now],
                detachedDeadline: nil,
                isCommitted: false,
                transcriptEvents: initialTranscriptEvents,
                nextTranscriptSequence: nextTranscriptSequence,
                transcriptLimits: lease.plan.transcriptLimits
            )
        }
        startDurablePTYDrain(sessionID: identity.sessionID, drainID: drainID, lease: lease)
        return identity
    }

    func commit(
        authentication: Phase2DurableShellBrokerAuthenticationRequest,
        clientID: UUID,
        now: Date = Date()
    ) throws -> Phase2DurableShellBrokerIdentity {
        try lock.withLock {
            var record = try authenticatedRecord(authentication, now: now)
            guard record.attachedClientIDs.contains(clientID) else { throw RegistryError.sessionNotFound }
            record.isCommitted = true
            record.detachedDeadline = nil
            records[record.identity.sessionID] = record
            return record.identity
        }
    }

    func appendTranscriptEvent(
        sessionID: UUID,
        source: Phase2HumanPTYEventSource,
        payload: Phase2HumanPTYEventPayload
    ) throws -> Phase2HumanPTYTranscriptEvent {
        try lock.withLock {
            guard var record = records[sessionID] else { throw RegistryError.sessionNotFound }
            let event = Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: record.nextTranscriptSequence,
                source: source,
                payload: payload
            )
            record.transcriptEvents.append(event)
            record.nextTranscriptSequence = event.sequence &+ 1
            compactTranscriptEventsIfNeeded(&record)
            records[sessionID] = record
            return event
        }
    }

    func appendTerminalTranscriptEventIfNeeded(
        sessionID: UUID,
        outcome: Phase2HumanPTYTerminalOutcome
    ) throws -> Phase2HumanPTYTranscriptEvent? {
        try lock.withLock {
            guard var record = records[sessionID] else { throw RegistryError.sessionNotFound }
            guard !record.transcriptEvents.contains(where: {
                if case .terminal = $0.payload { return true }
                return false
            }) else { return nil }
            let event = Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: record.nextTranscriptSequence,
                source: .broker,
                payload: .terminal(outcome)
            )
            record.transcriptEvents.append(event)
            record.nextTranscriptSequence = event.sequence &+ 1
            compactTranscriptEventsIfNeeded(&record)
            records[sessionID] = record
            return event
        }
    }

    func transcriptSnapshot(
        sessionID: UUID,
        afterSequence: UInt64,
        maximumEvents: Int,
        maximumBytes: Int
    ) throws -> TranscriptSnapshot {
        guard maximumEvents > 0, maximumBytes > 0 else { throw RegistryError.invalidTranscriptRequest }
        return try lock.withLock {
            guard let record = records[sessionID] else { throw RegistryError.sessionNotFound }
            var selected: [Phase2HumanPTYTranscriptEvent] = []
            var selectedBytes = 0
            for event in record.transcriptEvents where event.sequence > afterSequence {
                guard selected.count < maximumEvents else { break }
                let eventBytes = event.payload.byteCount
                guard selectedBytes + eventBytes <= maximumBytes else { break }
                selected.append(event)
                selectedBytes += eventBytes
            }
            return TranscriptSnapshot(events: selected, nextSequence: record.nextTranscriptSequence)
        }
    }

    func nextTranscriptSequence(sessionID: UUID) -> UInt64? {
        lock.withLock { records[sessionID]?.nextTranscriptSequence }
    }

    private func startDurablePTYDrain(
        sessionID: UUID,
        drainID: UUID,
        lease: Phase2ShellBrokerProcessLease
    ) {
        drainQueue.async { [weak self] in
            self?.drainDurablePTYOnce(sessionID: sessionID, drainID: drainID, lease: lease)
        }
    }

    private func drainDurablePTYOnce(
        sessionID: UUID,
        drainID: UUID,
        lease: Phase2ShellBrokerProcessLease
    ) {
        let maximumEventBytes = lock.withLock {
            records[sessionID]?.transcriptLimits.maximumEventBytes
        } ?? 0
        guard maximumEventBytes > 0 else { return }

        var drainedByteCount = 0
        var readCount = 0
        while drainedByteCount < Self.maximumDrainBurstBytes,
              readCount < Self.maximumDrainBurstReads {
            guard shouldContinueDrain(sessionID: sessionID, drainID: drainID) else { return }
            let outputBytes = lease.readAvailablePTYOutput(
                maxBytes: min(maximumEventBytes, 16 * 1_024),
                timeout: 0.01
            )
            if outputBytes.isEmpty {
                if let outcome = lease.observedTerminalOutcomeIfExited {
                    _ = try? appendTerminalTranscriptEventIfNeeded(
                        sessionID: sessionID,
                        outcome: outcome
                    )
                    lease.closePTYAfterObservedExit()
                    return
                }
                drainQueue.async { [weak self] in
                    self?.drainDurablePTYOnce(
                        sessionID: sessionID,
                        drainID: drainID,
                        lease: lease
                    )
                }
                return
            }

            _ = try? appendTranscriptEvent(
                sessionID: sessionID,
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: outputBytes)
            )
            drainedByteCount += outputBytes.count
            readCount += 1
        }

        drainQueue.async { [weak self] in
            self?.drainDurablePTYOnce(sessionID: sessionID, drainID: drainID, lease: lease)
        }
    }

    private func shouldContinueDrain(sessionID: UUID, drainID: UUID) -> Bool {
        lock.withLock { records[sessionID]?.drainID == drainID }
    }

    func status(
        authentication: Phase2DurableShellBrokerAuthenticationRequest,
        clientID: UUID,
        now: Date = Date()
    ) throws -> (identity: Phase2DurableShellBrokerIdentity, clientAttached: Bool, processRunning: Bool) {
        try lock.withLock {
            let record = try authenticatedRecord(authentication, now: now)
            return (record.identity, record.attachedClientIDs.contains(clientID), record.lease.isRunning)
        }
    }

    func attach(
        authentication: Phase2DurableShellBrokerAuthenticationRequest,
        clientID: UUID,
        now: Date = Date()
    ) throws -> SessionHandle {
        try lock.withLock {
            var record = try authenticatedRecord(authentication, now: now)
            record.attachedClientIDs.insert(clientID)
            record.lastHeartbeatByClientID[clientID] = now
            record.detachedDeadline = nil
            records[record.identity.sessionID] = record
            return SessionHandle(identity: record.identity, lease: record.lease)
        }
    }

    func detach(
        authentication: Phase2DurableShellBrokerAuthenticationRequest,
        clientID: UUID,
        now: Date = Date()
    ) throws -> Phase2DurableShellBrokerIdentity {
        try lock.withLock {
            var record = try authenticatedRecord(authentication, now: now)
            record.attachedClientIDs.remove(clientID)
            record.lastHeartbeatByClientID.removeValue(forKey: clientID)
            if record.attachedClientIDs.isEmpty, !record.isCommitted {
                record.detachedDeadline = now.addingTimeInterval(detachedGrace)
            }
            records[record.identity.sessionID] = record
            return record.identity
        }
    }

    func heartbeat(
        authentication: Phase2DurableShellBrokerAuthenticationRequest,
        clientID: UUID,
        now: Date = Date()
    ) throws -> Phase2DurableShellBrokerIdentity {
        try lock.withLock {
            var record = try authenticatedRecord(authentication, now: now)
            guard record.attachedClientIDs.contains(clientID) else { throw RegistryError.sessionNotFound }
            record.lastHeartbeatByClientID[clientID] = now
            records[record.identity.sessionID] = record
            return record.identity
        }
    }

    /// Connection loss relinquishes only client attachment. The registry remains the lease owner.
    func detachClient(_ clientID: UUID, now: Date = Date()) {
        lock.withLock {
            for sessionID in Array(records.keys) {
                guard var record = records[sessionID] else { continue }
                record.attachedClientIDs.remove(clientID)
                record.lastHeartbeatByClientID.removeValue(forKey: clientID)
                if record.attachedClientIDs.isEmpty, !record.isCommitted {
                    record.detachedDeadline = now.addingTimeInterval(detachedGrace)
                }
                records[sessionID] = record
            }
        }
    }

    @discardableResult
    func cleanup(
        authentication: Phase2DurableShellBrokerAuthenticationRequest,
        now: Date = Date()
    ) throws -> Phase2ShellBrokerCleanupProof {
        let record = try lock.withLock { () throws -> Record in
            let record = try authenticatedRecord(authentication, now: now)
            records.removeValue(forKey: record.identity.sessionID)
            return record
        }
        return record.lease.cleanup(outcome: .canceled)
    }

    func cleanupAllForTesting() {
        let leases = lock.withLock {
            let leases = records.values.map(\.lease)
            records.removeAll()
            return leases
        }
        for lease in leases {
            _ = lease.cleanup(outcome: .canceled, timeout: 1.0)
        }
    }

    @discardableResult
    func cleanupExpired(now: Date = Date()) -> [Phase2ShellBrokerCleanupProof] {
        let leases = lock.withLock {
            for sessionID in Array(records.keys) {
                guard var record = records[sessionID] else { continue }
                let staleClients = record.lastHeartbeatByClientID.compactMap { clientID, heartbeat in
                    heartbeat.addingTimeInterval(heartbeatTimeout) <= now ? clientID : nil
                }
                for clientID in staleClients {
                    record.attachedClientIDs.remove(clientID)
                    record.lastHeartbeatByClientID.removeValue(forKey: clientID)
                }
                if record.attachedClientIDs.isEmpty, !record.isCommitted, record.detachedDeadline == nil {
                    record.detachedDeadline = now.addingTimeInterval(detachedGrace)
                }
                records[sessionID] = record
            }
            let expiredSessionIDs = records.compactMap { sessionID, record in
                let hardExpired = record.identity.expiresAt <= now
                let graceExpired = record.detachedDeadline.map { $0 <= now } ?? false
                return hardExpired || graceExpired ? sessionID : nil
            }
            let leases = expiredSessionIDs.compactMap { records.removeValue(forKey: $0)?.lease }
            return leases
        }
        return leases.map { $0.cleanup(outcome: .canceled, timeout: 1.0) }
    }

    private func authenticatedRecord(
        _ authentication: Phase2DurableShellBrokerAuthenticationRequest,
        now: Date
    ) throws -> Record {
        guard let record = records[authentication.sessionID] else { throw RegistryError.sessionNotFound }
        let validation = Phase2DurableShellBrokerAuthenticator.validate(
            authentication,
            identity: record.identity,
            now: now
        )
        guard validation.isAuthenticated else {
            throw RegistryError.authenticationFailed(validation.issues)
        }
        return record
    }

    private func compactTranscriptEventsIfNeeded(_ record: inout Record) {
        let limits = record.transcriptLimits
        guard limits.isValid else { return }
        let cumulativeBytes = record.transcriptEvents.reduce(0) { $0 + $1.payload.byteCount }
        guard record.transcriptEvents.count > limits.maximumEvents ||
                cumulativeBytes > limits.maximumCumulativeBytes
        else { return }

        let retainedBudget = max(1, limits.maximumEvents - 1)
        var retainedReversed: [Phase2HumanPTYTranscriptEvent] = []
        var retainedBytes = 0
        for event in record.transcriptEvents.reversed() {
            guard retainedReversed.count < retainedBudget else { break }
            let eventBytes = event.payload.byteCount
            guard retainedBytes + eventBytes <= limits.maximumCumulativeBytes else { break }
            retainedReversed.append(event)
            retainedBytes += eventBytes
        }
        let retained = Array(retainedReversed.reversed())
        let dropped: ArraySlice<Phase2HumanPTYTranscriptEvent>
        let gapSequence: UInt64
        if let firstRetained = retained.first {
            dropped = record.transcriptEvents.prefix { $0.sequence < firstRetained.sequence }
            gapSequence = firstRetained.sequence > 1 ? firstRetained.sequence - 1 : firstRetained.sequence
        } else {
            dropped = record.transcriptEvents[...]
            gapSequence = record.nextTranscriptSequence > 1 ? record.nextTranscriptSequence - 1 : 1
        }
        guard !dropped.isEmpty else { return }
        let lostByteCount = dropped.reduce(0) { partial, event in
            if case .gap(_, let priorLostByteCount) = event.payload { return partial + priorLostByteCount }
            return partial + event.payload.byteCount
        }
        let gap = Phase2HumanPTYTranscriptEvent(
            sessionID: record.identity.sessionID,
            sequence: gapSequence,
            source: .broker,
            payload: .gap(reason: .spoolLimitExceeded, lostByteCount: max(lostByteCount, dropped.count))
        )
        record.transcriptEvents = limits.maximumEvents == 1 ? [gap] : [gap] + retained
    }

}
