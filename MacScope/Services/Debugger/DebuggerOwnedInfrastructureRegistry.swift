import Foundation

enum DebuggerOwnedInfrastructureKind: Hashable, Sendable {
    case persistentLLDBAdapter
}

struct DebuggerOwnedInfrastructureRevision: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (
        lhs: DebuggerOwnedInfrastructureRevision,
        rhs: DebuggerOwnedInfrastructureRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerOwnedInfrastructureSpawnToken: Hashable, Sendable {
    fileprivate let recordID: UUID
    let generation: UInt64
    let kind: DebuggerOwnedInfrastructureKind
}

struct DebuggerOwnedInfrastructureLaunchClaim: Hashable, Sendable {
    fileprivate let recordID: UUID
    fileprivate let nonce: UUID
    let generation: UInt64
    let kind: DebuggerOwnedInfrastructureKind
}

/// Exact retained-process authority used while converting a pre-launch claim into one stable
/// infrastructure instance. Production conformers must answer from the same retained process
/// object that was launched; a raw PID is deliberately insufficient.
protocol DebuggerOwnedInfrastructureRetainedProcessBinding: AnyObject, Sendable {
    func retainedProcessIdentifierForInfrastructure() async -> Int32
    func retainedProcessIsRunningForInfrastructure() async -> Bool
    func retainedProcessDispositionForInfrastructure() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition
}

enum DebuggerOwnedInfrastructureRetainedProcessDisposition: Hashable, Sendable {
    case notLaunched
    case running
    case exitedAndReaped
    case unknown
}

struct DebuggerOwnedInfrastructureRegistration: Hashable, Sendable {
    fileprivate let recordID: UUID
    let generation: UInt64
    let kind: DebuggerOwnedInfrastructureKind
    let fingerprint: DebuggerLocalProcessCatalogFingerprint
    let instanceKey: DebuggerLocalProcessInstanceKey
}

struct DebuggerOwnedInfrastructureSnapshot: Hashable, Sendable {
    let attachWriteInterlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let revision: DebuggerOwnedInfrastructureRevision
    let excludedInstances: Set<DebuggerLocalProcessInstanceKey>
    let pendingSpawnCount: Int
    let unresolvedSpawnCount: Int

    var isAuthoritative: Bool {
        pendingSpawnCount == 0 && unresolvedSpawnCount == 0
    }
}

enum DebuggerOwnedInfrastructureRegistryError: Error, Hashable, Sendable {
    case generationOverflow
    case revisionOverflow
    case invalidProcessID
    case selfProcess
    case staleSpawnToken
    case staleRegistration
    case invalidStateTransition
    case processIDAlreadyClaimed
    case processInstanceAlreadyRegistered
    case retainedProcessBindingMismatch
    case retainedProcessNotSettled
    case identityCaptureFailed(DebuggerLocalAttachDenial)
    case spawnedProcessStillPresent
    case retirementProofFailed(DebuggerLocalAttachDenial)
    case registryInvariantViolation
}

/// Process-global accounting for helpers that MacScope itself owns.
///
/// A record is created before a process may become visible. Until two stable catalog observations
/// bind it to one exact PID/start-time pair, snapshots are non-authoritative and attach policy must
/// fail closed. Removal likewise requires two complete PID enumerations proving absence; a caller's
/// generic shutdown receipt is never release authority.
actor DebuggerOwnedInfrastructureRegistry {
    private enum RecordPhase: Sendable {
        case pending
        case launching(claim: DebuggerOwnedInfrastructureLaunchClaim)
        case settlingUnlaunched(claim: DebuggerOwnedInfrastructureLaunchClaim)
        case identifying
        case validatingRetry(processID: Int32, denial: DebuggerLocalAttachDenial)
        case capturing(processID: Int32)
        case unresolved(processID: Int32?, denial: DebuggerLocalAttachDenial)
        case registered(
            fingerprint: DebuggerLocalProcessCatalogFingerprint,
            instanceKey: DebuggerLocalProcessInstanceKey
        )
        case retiringRegistered(
            fingerprint: DebuggerLocalProcessCatalogFingerprint,
            instanceKey: DebuggerLocalProcessInstanceKey
        )
        case retiringUnresolved(processID: Int32?, denial: DebuggerLocalAttachDenial)
    }

    private struct Record: Sendable {
        let token: DebuggerOwnedInfrastructureSpawnToken
        var phase: RecordPhase
        var retainedProcess: (any DebuggerOwnedInfrastructureRetainedProcessBinding)?
    }

    private enum StableCatalogCapture: Sendable {
        case captured(
            fingerprint: DebuggerLocalProcessCatalogFingerprint,
            instanceKey: DebuggerLocalProcessInstanceKey
        )
        case failed(DebuggerLocalAttachDenial)
    }

    private enum AbsenceProof: Sendable {
        case absent
        case present
        case failed(DebuggerLocalAttachDenial)
    }

    private let processEvidenceProvider: any DebuggerLocalProcessEvidenceProviding
    private let hostProcessID: Int32
    nonisolated let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    private var lastGeneration: UInt64 = 0
    private var currentRevision: UInt64 = 0
    private var recordsByID: [UUID: Record] = [:]
    private var recordIDByClaimedProcessID: [Int32: UUID] = [:]
    private var recordIDByInstance: [DebuggerLocalProcessInstanceKey: UUID] = [:]

    init(
        processEvidenceProvider: any DebuggerLocalProcessEvidenceProviding =
            DarwinDebuggerLocalProcessEvidenceProvider(),
        hostProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock =
            DebuggerLocalProcessAttachWriteInterlock(
                initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                    ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                    leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
                )
            )
    ) {
        self.processEvidenceProvider = processEvidenceProvider
        self.hostProcessID = hostProcessID
        self.attachWriteInterlock = attachWriteInterlock
    }

    var snapshot: DebuggerOwnedInfrastructureSnapshot {
        var excluded: Set<DebuggerLocalProcessInstanceKey> = []
        var pendingCount = 0
        var unresolvedCount = 0
        for record in recordsByID.values {
            switch record.phase {
            case .pending, .launching, .settlingUnlaunched, .identifying,
                 .validatingRetry, .capturing:
                pendingCount += 1
            case .unresolved, .retiringUnresolved:
                unresolvedCount += 1
            case let .registered(_, instanceKey),
                 let .retiringRegistered(_, instanceKey):
                excluded.insert(instanceKey)
            }
        }
        return DebuggerOwnedInfrastructureSnapshot(
            attachWriteInterlockIdentity: attachWriteInterlock.identity,
            revision: DebuggerOwnedInfrastructureRevision(rawValue: currentRevision),
            excludedInstances: excluded,
            pendingSpawnCount: pendingCount,
            unresolvedSpawnCount: unresolvedCount
        )
    }

    func beginSpawn(
        kind: DebuggerOwnedInfrastructureKind = .persistentLLDBAdapter
    ) throws -> DebuggerOwnedInfrastructureSpawnToken {
        let generation = try nextGeneration()
        var recordID = UUID()
        while recordsByID[recordID] != nil {
            recordID = UUID()
        }
        let token = DebuggerOwnedInfrastructureSpawnToken(
            recordID: recordID,
            generation: generation,
            kind: kind
        )
        try commitRevision {
            lastGeneration = generation
            recordsByID[recordID] = Record(
                token: token,
                phase: .pending,
                retainedProcess: nil
            )
        }
        return token
    }

    func cancelBeforeProcessLaunch(
        _ token: DebuggerOwnedInfrastructureSpawnToken
    ) throws {
        let record = try validatedRecord(for: token)
        guard case .pending = record.phase else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        try commitRevision {
            recordsByID.removeValue(forKey: token.recordID)
        }
    }

    /// Consumes the only pre-launch state before a process launcher may be invoked. Once this
    /// claim exists, `cancelBeforeProcessLaunch` is invalid and the record remains fail-closed
    /// until exact registration or absence-backed unresolved retirement succeeds.
    func beginLaunchAttempt(
        _ token: DebuggerOwnedInfrastructureSpawnToken
    ) throws -> DebuggerOwnedInfrastructureLaunchClaim {
        let record = try validatedRecord(for: token)
        guard case .pending = record.phase else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        let claim = DebuggerOwnedInfrastructureLaunchClaim(
            recordID: token.recordID,
            nonce: UUID(),
            generation: token.generation,
            kind: token.kind
        )
        try commitRevision {
            recordsByID[token.recordID]?.phase = .launching(claim: claim)
        }
        return claim
    }

    /// Settles an exact launch claim only when its retained process object proves that launch
    /// never occurred. Cancellation cannot interrupt the disposition query after the claim is
    /// consumed. Every other disposition remains pinned to the same object as an unresolved
    /// record so it cannot be redirected through a reused claim.
    func settleUnlaunchedProcess(
        _ claim: DebuggerOwnedInfrastructureLaunchClaim,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async throws {
        let token = try validatedToken(for: claim)
        try bindUnlaunchedSettlement(
            token: token,
            claim: claim,
            retainedProcess: retainedProcess
        )

        let disposition = await settledDisposition(retainedProcess: retainedProcess)
        let record = try validatedRecord(for: token)
        guard case let .settlingUnlaunched(currentClaim) = record.phase,
              currentClaim == claim else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }
        try requireSameRetainedProcess(record, retainedProcess: retainedProcess)

        guard disposition == .notLaunched else {
            try pinUnresolved(token: token, processID: nil, denial: .unstableSnapshot)
            throw DebuggerOwnedInfrastructureRegistryError.retainedProcessNotSettled
        }

        try commitRevision {
            recordsByID.removeValue(forKey: token.recordID)
        }
    }

    func registerSpawnedProcess(
        _ claim: DebuggerOwnedInfrastructureLaunchClaim,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async throws -> DebuggerOwnedInfrastructureRegistration {
        let token = try validatedToken(for: claim)
        try bindLaunchClaim(token: token, claim: claim, retainedProcess: retainedProcess)
        let processIDTask = Task.detached(priority: .userInitiated) {
            await retainedProcess.retainedProcessIdentifierForInfrastructure()
        }
        let processID = await processIDTask.value
        try validateIdentifyingRecord(token: token, retainedProcess: retainedProcess)
        guard processID > 1 else {
            try pinUnresolved(token: token, processID: nil, denial: .unstableSnapshot)
            throw DebuggerOwnedInfrastructureRegistryError.invalidProcessID
        }
        guard processID != hostProcessID else {
            try pinUnresolved(token: token, processID: nil, denial: .unstableSnapshot)
            throw DebuggerOwnedInfrastructureRegistryError.selfProcess
        }
        if let owner = recordIDByClaimedProcessID[processID], owner != token.recordID {
            try pinUnresolved(token: token, processID: processID, denial: .alreadyTraced)
            throw DebuggerOwnedInfrastructureRegistryError.processIDAlreadyClaimed
        }
        try transitionToCapturing(token: token, processID: processID)
        return try await finishIdentityCapture(
            token: token,
            processID: processID,
            retainedProcess: retainedProcess
        )
    }

    func retryIdentityCapture(
        _ token: DebuggerOwnedInfrastructureSpawnToken,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async throws -> DebuggerOwnedInfrastructureRegistration {
        try Task.checkCancellation()
        let record = try validatedRecord(for: token)
        guard case let .unresolved(processID?, denial) = record.phase else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        try requireSameRetainedProcess(record, retainedProcess: retainedProcess)
        try commitRevision {
            recordsByID[token.recordID]?.phase = .validatingRetry(
                processID: processID,
                denial: denial
            )
        }
        let processIDTask = Task.detached(priority: .userInitiated) {
            await retainedProcess.retainedProcessIdentifierForInfrastructure()
        }
        let reboundProcessID = await processIDTask.value
        let current = try validatedRecord(for: token)
        guard case let .validatingRetry(currentPID, currentDenial) = current.phase,
              currentPID == processID,
              currentDenial == denial else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }
        try requireSameRetainedProcess(current, retainedProcess: retainedProcess)
        guard reboundProcessID == processID else {
            try pinUnresolved(token: token, processID: processID, denial: .identityChanged)
            throw DebuggerOwnedInfrastructureRegistryError.identityCaptureFailed(.identityChanged)
        }
        if let owner = recordIDByClaimedProcessID[processID], owner != token.recordID {
            try pinUnresolved(token: token, processID: processID, denial: .alreadyTraced)
            throw DebuggerOwnedInfrastructureRegistryError.processIDAlreadyClaimed
        }
        try transitionToCapturing(token: token, processID: processID)
        return try await finishIdentityCapture(
            token: token,
            processID: processID,
            retainedProcess: retainedProcess
        )
    }

    func retire(
        _ registration: DebuggerOwnedInfrastructureRegistration
    ) async throws {
        try Task.checkCancellation()
        let record = try validatedRecord(for: registration)
        guard case let .registered(fingerprint, instanceKey) = record.phase,
              fingerprint == registration.fingerprint,
              instanceKey == registration.instanceKey else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        try commitRevision {
            recordsByID[registration.recordID]?.phase = .retiringRegistered(
                fingerprint: fingerprint,
                instanceKey: instanceKey
            )
        }

        let proof = await proveProcessAbsent(processID: fingerprint.processID)
        let current = try validatedRecord(for: registration)
        guard case let .retiringRegistered(currentFingerprint, currentKey) = current.phase,
              currentFingerprint == fingerprint,
              currentKey == instanceKey else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }
        switch proof {
        case .absent:
            try removeRegisteredRecord(registration, fingerprint: fingerprint, key: instanceKey)
        case .present:
            try restoreRegisteredRecord(
                registration,
                fingerprint: fingerprint,
                key: instanceKey
            )
            throw DebuggerOwnedInfrastructureRegistryError.spawnedProcessStillPresent
        case .failed(let denial):
            try restoreRegisteredRecord(
                registration,
                fingerprint: fingerprint,
                key: instanceKey
            )
            throw DebuggerOwnedInfrastructureRegistryError.retirementProofFailed(denial)
        }
    }

    func retireUnresolvedSpawn(
        _ token: DebuggerOwnedInfrastructureSpawnToken,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async throws {
        try Task.checkCancellation()
        let record = try validatedRecord(for: token)
        guard case let .unresolved(processID, denial) = record.phase else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        try requireSameRetainedProcess(record, retainedProcess: retainedProcess)
        try commitRevision {
            recordsByID[token.recordID]?.phase = .retiringUnresolved(
                processID: processID,
                denial: denial
            )
        }

        let disposition = await settledDisposition(retainedProcess: retainedProcess)
        guard disposition == .notLaunched || disposition == .exitedAndReaped else {
            try restoreUnresolvedRecord(token, processID: processID, denial: denial)
            throw DebuggerOwnedInfrastructureRegistryError.retainedProcessNotSettled
        }
        let proof: AbsenceProof
        if let processID {
            proof = await proveProcessAbsent(processID: processID)
        } else {
            proof = .absent
        }
        let current = try validatedRecord(for: token)
        guard case let .retiringUnresolved(currentPID, currentDenial) = current.phase,
              currentPID == processID,
              currentDenial == denial else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }
        switch proof {
        case .absent:
            try commitRevision {
                recordsByID.removeValue(forKey: token.recordID)
                if let processID,
                   recordIDByClaimedProcessID[processID] == token.recordID {
                    recordIDByClaimedProcessID.removeValue(forKey: processID)
                }
            }
        case .present:
            try restoreUnresolvedRecord(token, processID: processID, denial: denial)
            throw DebuggerOwnedInfrastructureRegistryError.spawnedProcessStillPresent
        case .failed(let proofDenial):
            try restoreUnresolvedRecord(token, processID: processID, denial: denial)
            throw DebuggerOwnedInfrastructureRegistryError.retirementProofFailed(proofDenial)
        }
    }

    private func transitionToCapturing(
        token: DebuggerOwnedInfrastructureSpawnToken,
        processID: Int32
    ) throws {
        try commitRevision {
            recordsByID[token.recordID]?.phase = .capturing(processID: processID)
            recordIDByClaimedProcessID[processID] = token.recordID
        }
    }

    private func bindLaunchClaim(
        token: DebuggerOwnedInfrastructureSpawnToken,
        claim: DebuggerOwnedInfrastructureLaunchClaim,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) throws {
        let record = try validatedRecord(for: token)
        guard case let .launching(currentClaim) = record.phase,
              currentClaim == claim,
              record.retainedProcess == nil else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        try commitRevision {
            recordsByID[token.recordID]?.phase = .identifying
            recordsByID[token.recordID]?.retainedProcess = retainedProcess
        }
    }

    private func bindUnlaunchedSettlement(
        token: DebuggerOwnedInfrastructureSpawnToken,
        claim: DebuggerOwnedInfrastructureLaunchClaim,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) throws {
        let record = try validatedRecord(for: token)
        guard case let .launching(currentClaim) = record.phase,
              currentClaim == claim,
              record.retainedProcess == nil else {
            throw DebuggerOwnedInfrastructureRegistryError.invalidStateTransition
        }
        try commitRevision {
            recordsByID[token.recordID]?.phase = .settlingUnlaunched(claim: claim)
            recordsByID[token.recordID]?.retainedProcess = retainedProcess
        }
    }

    private func validateIdentifyingRecord(
        token: DebuggerOwnedInfrastructureSpawnToken,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) throws {
        let record = try validatedRecord(for: token)
        guard case .identifying = record.phase else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }
        try requireSameRetainedProcess(record, retainedProcess: retainedProcess)
    }

    private func requireSameRetainedProcess(
        _ record: Record,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) throws {
        guard let bound = record.retainedProcess,
              ObjectIdentifier(bound) == ObjectIdentifier(retainedProcess) else {
            throw DebuggerOwnedInfrastructureRegistryError.retainedProcessBindingMismatch
        }
    }

    private func finishIdentityCapture(
        token: DebuggerOwnedInfrastructureSpawnToken,
        processID: Int32,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async throws -> DebuggerOwnedInfrastructureRegistration {
        let provider = processEvidenceProvider
        let captureTask = Task.detached(priority: .userInitiated) {
            await Self.captureStableCatalog(
                processID: processID,
                provider: provider,
                retainedProcess: retainedProcess
            )
        }
        let capture = await captureTask.value
        let record = try validatedRecord(for: token)
        guard case let .capturing(currentPID) = record.phase,
              currentPID == processID,
              recordIDByClaimedProcessID[processID] == token.recordID else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }

        switch capture {
        case let .captured(fingerprint, instanceKey):
            if let owner = recordIDByInstance[instanceKey], owner != token.recordID {
                try pinUnresolved(
                    token: token,
                    processID: processID,
                    denial: .alreadyTraced
                )
                throw DebuggerOwnedInfrastructureRegistryError
                    .processInstanceAlreadyRegistered
            }
            try commitRevision {
                recordsByID[token.recordID]?.phase = .registered(
                    fingerprint: fingerprint,
                    instanceKey: instanceKey
                )
                recordIDByInstance[instanceKey] = token.recordID
            }
            return DebuggerOwnedInfrastructureRegistration(
                recordID: token.recordID,
                generation: token.generation,
                kind: token.kind,
                fingerprint: fingerprint,
                instanceKey: instanceKey
            )
        case .failed(let denial):
            try pinUnresolved(token: token, processID: processID, denial: denial)
            throw DebuggerOwnedInfrastructureRegistryError.identityCaptureFailed(denial)
        }
    }

    private func pinUnresolved(
        token: DebuggerOwnedInfrastructureSpawnToken,
        processID: Int32?,
        denial: DebuggerLocalAttachDenial
    ) throws {
        try commitRevision {
            recordsByID[token.recordID]?.phase = .unresolved(
                processID: processID,
                denial: denial
            )
        }
    }

    private nonisolated static func captureStableCatalog(
        processID: Int32,
        provider: any DebuggerLocalProcessEvidenceProviding,
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async -> StableCatalogCapture {
        guard await retainedProcess.retainedProcessIsRunningForInfrastructure() else {
            return .failed(.disappeared)
        }
        let first = await provider.catalogEvidence(processID: processID)
        guard case let .resolved(firstEvidence) = first else {
            return .failed(first.denial ?? .unstableSnapshot)
        }
        guard await retainedProcess.retainedProcessIsRunningForInfrastructure() else {
            return .failed(.identityChanged)
        }
        let second = await provider.catalogEvidence(processID: processID)
        guard case let .resolved(secondEvidence) = second else {
            return .failed(second.denial ?? .unstableSnapshot)
        }
        guard await retainedProcess.retainedProcessIsRunningForInfrastructure() else {
            return .failed(.identityChanged)
        }
        let firstFingerprint = firstEvidence.fingerprint
        let secondFingerprint = secondEvidence.fingerprint
        guard firstFingerprint.processID == processID,
              secondFingerprint.processID == processID,
              firstFingerprint == secondFingerprint else {
            return .failed(.identityChanged)
        }
        return .captured(
            fingerprint: secondFingerprint,
            instanceKey: DebuggerLocalProcessInstanceKey(
                processID: processID,
                startTime: secondFingerprint.startTime
            )
        )
    }

    private func proveProcessAbsent(processID: Int32) async -> AbsenceProof {
        let provider = processEvidenceProvider
        let proofTask = Task.detached(priority: .userInitiated) {
            let first = await provider.processIDs()
            let second = await provider.processIDs()
            guard case let .resolved(firstPIDs) = first else {
                return AbsenceProof.failed(first.denial ?? .unstableSnapshot)
            }
            guard case let .resolved(secondPIDs) = second else {
                return AbsenceProof.failed(second.denial ?? .unstableSnapshot)
            }
            guard !firstPIDs.contains(processID), !secondPIDs.contains(processID) else {
                return AbsenceProof.present
            }
            return AbsenceProof.absent
        }
        return await proofTask.value
    }

    private func settledDisposition(
        retainedProcess: any DebuggerOwnedInfrastructureRetainedProcessBinding
    ) async -> DebuggerOwnedInfrastructureRetainedProcessDisposition {
        let dispositionTask = Task.detached(priority: .userInitiated) {
            await retainedProcess.retainedProcessDispositionForInfrastructure()
        }
        return await dispositionTask.value
    }

    private func removeRegisteredRecord(
        _ registration: DebuggerOwnedInfrastructureRegistration,
        fingerprint: DebuggerLocalProcessCatalogFingerprint,
        key: DebuggerLocalProcessInstanceKey
    ) throws {
        guard recordIDByClaimedProcessID[fingerprint.processID] == registration.recordID,
              recordIDByInstance[key] == registration.recordID else {
            throw DebuggerOwnedInfrastructureRegistryError.registryInvariantViolation
        }
        try commitRevision {
            recordsByID.removeValue(forKey: registration.recordID)
            recordIDByClaimedProcessID.removeValue(forKey: fingerprint.processID)
            recordIDByInstance.removeValue(forKey: key)
        }
    }

    private func restoreRegisteredRecord(
        _ registration: DebuggerOwnedInfrastructureRegistration,
        fingerprint: DebuggerLocalProcessCatalogFingerprint,
        key: DebuggerLocalProcessInstanceKey
    ) throws {
        try commitRevision {
            recordsByID[registration.recordID]?.phase = .registered(
                fingerprint: fingerprint,
                instanceKey: key
            )
        }
    }

    private func restoreUnresolvedRecord(
        _ token: DebuggerOwnedInfrastructureSpawnToken,
        processID: Int32?,
        denial: DebuggerLocalAttachDenial
    ) throws {
        try commitRevision {
            recordsByID[token.recordID]?.phase = .unresolved(
                processID: processID,
                denial: denial
            )
        }
    }

    private func validatedRecord(
        for token: DebuggerOwnedInfrastructureSpawnToken
    ) throws -> Record {
        guard let record = recordsByID[token.recordID], record.token == token else {
            throw DebuggerOwnedInfrastructureRegistryError.staleSpawnToken
        }
        return record
    }

    private func validatedToken(
        for claim: DebuggerOwnedInfrastructureLaunchClaim
    ) throws -> DebuggerOwnedInfrastructureSpawnToken {
        guard let record = recordsByID[claim.recordID],
              record.token.generation == claim.generation,
              record.token.kind == claim.kind,
              case let .launching(currentClaim) = record.phase,
              currentClaim == claim else {
            throw DebuggerOwnedInfrastructureRegistryError.staleSpawnToken
        }
        return record.token
    }

    private func validatedRecord(
        for registration: DebuggerOwnedInfrastructureRegistration
    ) throws -> Record {
        guard let record = recordsByID[registration.recordID],
              record.token.generation == registration.generation,
              record.token.kind == registration.kind else {
            throw DebuggerOwnedInfrastructureRegistryError.staleRegistration
        }
        return record
    }

    private func nextGeneration() throws -> UInt64 {
        let (value, overflowed) = lastGeneration.addingReportingOverflow(1)
        guard !overflowed, value > 0 else {
            throw DebuggerOwnedInfrastructureRegistryError.generationOverflow
        }
        return value
    }

    private func nextRevision() throws -> UInt64 {
        let (value, overflowed) = currentRevision.addingReportingOverflow(1)
        guard !overflowed, value > 0 else {
            throw DebuggerOwnedInfrastructureRegistryError.revisionOverflow
        }
        return value
    }

    /// Linearizes the registry mutation and its published revision with the exact attach writer.
    /// No suspension or interlock re-entry is permitted inside `mutation`.
    private func commitRevision(_ mutation: () -> Void) throws {
        let expected = DebuggerOwnedInfrastructureRevision(rawValue: currentRevision)
        let next = DebuggerOwnedInfrastructureRevision(rawValue: try nextRevision())
        try attachWriteInterlock.commitOwnedInfrastructureRevision(
            from: expected,
            to: next
        ) {
            mutation()
            currentRevision = next.rawValue
        }
    }
}
