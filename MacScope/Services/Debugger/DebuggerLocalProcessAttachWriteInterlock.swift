import CryptoKit
import Foundation

/// Process-global identity for the one authority that linearizes exact local-process attach writes.
/// The value is intentionally opaque: callers may retain and compare it, but only an interlock can
/// mint one.
struct DebuggerLocalProcessAttachWriteInterlockIdentity: Hashable, Sendable {
    fileprivate let rawValue: UUID
}

/// One synchronous view of the interlock authority and both policy-source revisions.
struct DebuggerLocalProcessAttachWriteInterlockSnapshot: Hashable, Sendable {
    let identity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let revision: DebuggerLocalProcessObservationPolicyRevisionVector
}

/// Domain-separated digest of the exact final semantic command admitted to the attach writer.
/// Exact attach has one final command; installation and staging commands never receive this token.
struct DebuggerLocalProcessAttachWriteSemanticDigest: Hashable, Sendable {
    let bytes: Data

    init?(semanticCommands: [String]) {
        guard semanticCommands.count == 1, let command = semanticCommands.first else {
            return nil
        }
        do {
            try LLDBCLITranscriptDecoder.validateRenderedCommand(command)
        } catch {
            return nil
        }

        var material = Data("MacScope.DebuggerLocalProcessAttach.FinalSemanticCommand.v1".utf8)
        material.append(0)
        material.appendAttachWriteLengthFramed(command)
        bytes = Data(SHA256.hash(data: material))
    }

    init?(semanticCommand: String) {
        self.init(semanticCommands: [semanticCommand])
    }
}

/// Frozen canonical program identity consumed when one registry permit begins its only attach
/// transaction. Adapter binding is deliberately a second synchronous step: the permit is spent
/// before the coordinator's first executor await, then bound to the one retained adapter returned
/// by that await before any staging authority can be issued.
struct DebuggerLocalProcessExactAttachTransactionClaimInput: Sendable {
    let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector
    let permitBindingDigest: Data
    let permitAuthority: DebuggerSessionTargetAuthority
    let permitAdmissionSession: DebuggerSessionCoordinate
    let permitAdapterGeneration: UInt64
    let finalAttachRequest: DebuggerRequestContext
    let canonicalProgramSourceDigest: Data
    let canonicalStagingCommandCount: Int
    let canonicalProgramDigest: Data
    let canonicalFinalSemanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest
    let bindingDigest: Data
    fileprivate let permitTransactionAuthority:
        DebuggerLocalProcessExactAttachPermitTransactionAuthority

    init?(
        policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        permit: DebuggerSessionLeaseExactAttachPermit,
        finalAttachRequest: DebuggerRequestContext
    ) {
        guard permit.bindingDigest.count == SHA256.byteCount,
              permit.observationPolicyRevision == policyRevision,
              permit.attachWriteInterlockIdentity == interlockIdentity,
              permit.adapterGeneration > 0,
              case .attached = permit.authority.origin,
              finalAttachRequest.operation == .attach,
              finalAttachRequest.isInternallyConsistent,
              finalAttachRequest.id.sequence > 0,
              finalAttachRequest.expectedSession == permit.admissionSession,
              finalAttachRequest.targetAuthority == permit.authority,
              finalAttachRequest.requiredStop == nil else {
            return nil
        }

        let program = PersistentLLDBAttachProgram.current
        let commands: [String]
        do {
            let request = try PersistentLLDBAttachProgramRequest(
                sessionEpoch: permit.admissionSession.epoch,
                requestSequence: finalAttachRequest.id.sequence,
                adapterGeneration: permit.adapterGeneration,
                authority: permit.authority,
                correlationToken: permit.correlationToken
            )
            commands = program.installChunkCommands
                + [program.installFinalizeCommand]
                + (try program.requestCommands(for: request))
        } catch {
            return nil
        }
        guard commands.count > 1,
              let finalCommand = commands.last,
              let finalDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                  semanticCommand: finalCommand
              ) else {
            return nil
        }

        self.interlockIdentity = interlockIdentity
        self.policyRevision = policyRevision
        self.permitBindingDigest = permit.bindingDigest
        self.permitAuthority = permit.authority
        self.permitAdmissionSession = permit.admissionSession
        self.permitAdapterGeneration = permit.adapterGeneration
        self.finalAttachRequest = finalAttachRequest
        self.canonicalProgramSourceDigest = program.sourceSHA256
        self.canonicalStagingCommandCount = commands.count - 1
        self.canonicalProgramDigest = Self.programDigest(commands)
        self.canonicalFinalSemanticDigest = finalDigest
        self.permitTransactionAuthority = permit.exactAttachTransactionAuthority
        self.bindingDigest = Self.bindingDigest(
            interlockIdentity: interlockIdentity,
            policyRevision: policyRevision,
            permitBindingDigest: permit.bindingDigest,
            finalAttachRequest: finalAttachRequest,
            programSourceDigest: program.sourceSHA256,
            stagingCommandCount: commands.count - 1,
            programDigest: Self.programDigest(commands),
            finalSemanticDigest: finalDigest
        )
    }

    fileprivate var hasValidBinding: Bool {
        bindingDigest == Self.bindingDigest(
            interlockIdentity: interlockIdentity,
            policyRevision: policyRevision,
            permitBindingDigest: permitBindingDigest,
            finalAttachRequest: finalAttachRequest,
            programSourceDigest: canonicalProgramSourceDigest,
            stagingCommandCount: canonicalStagingCommandCount,
            programDigest: canonicalProgramDigest,
            finalSemanticDigest: canonicalFinalSemanticDigest
        )
    }

    private static func programDigest(_ commands: [String]) -> Data {
        var material = Data("MacScope.DebuggerLocalProcessAttach.CanonicalProgram.v1".utf8)
        material.append(0)
        material.appendAttachWriteUInt64(UInt64(commands.count))
        for command in commands {
            material.appendAttachWriteLengthFramed(command)
        }
        return Data(SHA256.hash(data: material))
    }

    private static func bindingDigest(
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        permitBindingDigest: Data,
        finalAttachRequest: DebuggerRequestContext,
        programSourceDigest: Data,
        stagingCommandCount: Int,
        programDigest: Data,
        finalSemanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest
    ) -> Data {
        var material = Data("MacScope.DebuggerLocalProcessAttach.TransactionClaim.v1".utf8)
        material.append(0)
        material.appendAttachWriteLengthFramed(interlockIdentity.rawValue.uuidString.lowercased())
        material.appendAttachWriteUInt64(policyRevision.ownedInfrastructure.rawValue)
        material.appendAttachWriteUInt64(policyRevision.leaseMembership.rawValue)
        material.append(permitBindingDigest)
        material.appendAttachWriteLengthFramed(finalAttachRequest.id.epoch.rawValue.uuidString.lowercased())
        material.appendAttachWriteUInt64(finalAttachRequest.id.sequence)
        material.append(programSourceDigest)
        material.appendAttachWriteUInt64(UInt64(stagingCommandCount))
        material.append(programDigest)
        material.append(finalSemanticDigest.bytes)
        return Data(SHA256.hash(data: material))
    }
}

/// Opaque identity for the one transaction that consumed a registry permit. Copies retain the
/// same bounded permit-owned authority; the interlock retains no historical claim ledger.
struct DebuggerLocalProcessExactAttachTransactionClaim: Hashable, Sendable {
    fileprivate let authority: DebuggerLocalProcessExactAttachPermitTransactionAuthority
    fileprivate let claimID: UUID
    let bindingDigest: Data

    static func == (
        lhs: DebuggerLocalProcessExactAttachTransactionClaim,
        rhs: DebuggerLocalProcessExactAttachTransactionClaim
    ) -> Bool {
        lhs.authority === rhs.authority
            && lhs.claimID == rhs.claimID
            && lhs.bindingDigest == rhs.bindingDigest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(authority))
        hasher.combine(claimID)
        hasher.combine(bindingDigest)
    }
}

/// Frozen authority presented twice: once when a grant is issued, and again at the adapter's
/// final write boundary. This type deliberately extracts permit fields instead of retaining a
/// mutable registry projection, while its initializer still requires a registry-minted permit.
struct DebuggerLocalProcessAttachWriteIssuanceInput: Hashable, Sendable {
    let transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim?
    let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector
    let permitBindingDigest: Data
    let permitCorrelationToken: Data
    let permitAuthority: DebuggerSessionTargetAuthority
    let permitAdmissionSession: DebuggerSessionCoordinate
    let permitAdapterGeneration: UInt64
    let adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    let finalAttachRequest: DebuggerRequestContext
    let semanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest
    let bindingDigest: Data

    init?(
        policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        permit: DebuggerSessionLeaseExactAttachPermit,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        finalAttachRequest: DebuggerRequestContext,
        semanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest,
        transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim? = nil
    ) {
        guard permit.bindingDigest.count == SHA256.byteCount,
              permit.correlationToken.count == SHA256.byteCount,
              permit.observationPolicyRevision == policyRevision,
              permit.attachWriteInterlockIdentity == interlockIdentity,
              permit.adapterGeneration > 0,
              case .attached = permit.authority.origin,
              adapterInstanceBinding.digest.count == SHA256.byteCount,
              adapterInstanceBinding.sessionEpoch == permit.admissionSession.epoch,
              adapterInstanceBinding.adapterGeneration == permit.adapterGeneration,
              finalAttachRequest.operation == .attach,
              finalAttachRequest.isInternallyConsistent,
              finalAttachRequest.id.sequence > 0,
              finalAttachRequest.expectedSession == permit.admissionSession,
              finalAttachRequest.targetAuthority == permit.authority,
              finalAttachRequest.requiredStop == nil,
              semanticDigest.bytes.count == SHA256.byteCount else {
            return nil
        }

        self.transactionClaim = transactionClaim
        self.interlockIdentity = interlockIdentity
        self.policyRevision = policyRevision
        self.permitBindingDigest = permit.bindingDigest
        self.permitCorrelationToken = permit.correlationToken
        self.permitAuthority = permit.authority
        self.permitAdmissionSession = permit.admissionSession
        self.permitAdapterGeneration = permit.adapterGeneration
        self.adapterInstanceBinding = adapterInstanceBinding
        self.finalAttachRequest = finalAttachRequest
        self.semanticDigest = semanticDigest
        self.bindingDigest = Self.makeBindingDigest(
            interlockIdentity: interlockIdentity,
            policyRevision: policyRevision,
            permitBindingDigest: permit.bindingDigest,
            permitCorrelationToken: permit.correlationToken,
            permitAuthority: permit.authority,
            permitAdmissionSession: permit.admissionSession,
            permitAdapterGeneration: permit.adapterGeneration,
            adapterInstanceBinding: adapterInstanceBinding,
            finalAttachRequest: finalAttachRequest,
            semanticDigest: semanticDigest
        )
    }

    fileprivate var hasValidBinding: Bool {
        bindingDigest == Self.makeBindingDigest(
            interlockIdentity: interlockIdentity,
            policyRevision: policyRevision,
            permitBindingDigest: permitBindingDigest,
            permitCorrelationToken: permitCorrelationToken,
            permitAuthority: permitAuthority,
            permitAdmissionSession: permitAdmissionSession,
            permitAdapterGeneration: permitAdapterGeneration,
            adapterInstanceBinding: adapterInstanceBinding,
            finalAttachRequest: finalAttachRequest,
            semanticDigest: semanticDigest
        )
    }

    private static func makeBindingDigest(
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        permitBindingDigest: Data,
        permitCorrelationToken: Data,
        permitAuthority: DebuggerSessionTargetAuthority,
        permitAdmissionSession: DebuggerSessionCoordinate,
        permitAdapterGeneration: UInt64,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        finalAttachRequest: DebuggerRequestContext,
        semanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest
    ) -> Data {
        var material = Data("MacScope.DebuggerLocalProcessAttach.WriteIssuance.v1".utf8)
        material.append(0)
        material.appendAttachWriteLengthFramed(interlockIdentity.rawValue.uuidString.lowercased())
        material.appendAttachWriteUInt64(policyRevision.ownedInfrastructure.rawValue)
        material.appendAttachWriteUInt64(policyRevision.leaseMembership.rawValue)
        material.append(permitBindingDigest)
        material.append(permitCorrelationToken)
        material.appendAttachWriteInt32(permitAuthority.processID)
        material.appendAttachWriteLengthFramed(permitAuthority.identityDigest.lowercaseHex)
        material.appendAttachWriteLengthFramed(
            permitAdmissionSession.epoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(permitAdmissionSession.lifecycleRevision.rawValue)
        material.appendAttachWriteUInt64(permitAdapterGeneration)
        material.append(adapterInstanceBinding.digest)
        material.appendAttachWriteLengthFramed(
            adapterInstanceBinding.sessionEpoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(adapterInstanceBinding.adapterGeneration)
        material.appendAttachWriteLengthFramed(
            finalAttachRequest.id.epoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(finalAttachRequest.id.sequence)
        material.appendAttachWriteLengthFramed(finalAttachRequest.operation.rawValue)
        material.appendAttachWriteLengthFramed(
            finalAttachRequest.expectedSession.epoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(
            finalAttachRequest.expectedSession.lifecycleRevision.rawValue
        )
        material.append(semanticDigest.bytes)
        return Data(SHA256.hash(data: material))
    }
}

/// Frozen authority for exactly one canonical pre-final exchange in the current exact-attach
/// program. The initializer reconstructs the program instead of trusting a caller-supplied
/// staging label, so the canonical final command cannot be downgraded to an optional-PID write.
struct DebuggerLocalProcessAttachStagingWriteIssuanceInput: Hashable, Sendable {
    let transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim?
    let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector
    let permitBindingDigest: Data
    let permitCorrelationToken: Data
    let permitAuthority: DebuggerSessionTargetAuthority
    let permitAdmissionSession: DebuggerSessionCoordinate
    let permitAdapterGeneration: UInt64
    let adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    let stagingRequest: DebuggerRequestContext
    let finalAttachRequest: DebuggerRequestContext
    let stagingOrdinal: Int
    let semanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest
    let canonicalProgramSourceDigest: Data
    let canonicalStagingCommandCount: Int
    let bindingDigest: Data

    init?(
        policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        permit: DebuggerSessionLeaseExactAttachPermit,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        stagingRequest: DebuggerRequestContext,
        finalAttachRequest: DebuggerRequestContext,
        stagingOrdinal: Int,
        semanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest,
        transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim? = nil
    ) {
        guard permit.bindingDigest.count == SHA256.byteCount,
              permit.correlationToken.count == SHA256.byteCount,
              permit.observationPolicyRevision == policyRevision,
              permit.attachWriteInterlockIdentity == interlockIdentity,
              permit.adapterGeneration > 0,
              case .attached = permit.authority.origin,
              adapterInstanceBinding.digest.count == SHA256.byteCount,
              adapterInstanceBinding.sessionEpoch == permit.admissionSession.epoch,
              adapterInstanceBinding.adapterGeneration == permit.adapterGeneration,
              stagingRequest.operation == .attach,
              stagingRequest.isInternallyConsistent,
              stagingRequest.id.sequence > 0,
              stagingRequest.expectedSession == permit.admissionSession,
              stagingRequest.targetAuthority == permit.authority,
              stagingRequest.requiredStop == nil,
              finalAttachRequest.operation == .attach,
              finalAttachRequest.isInternallyConsistent,
              finalAttachRequest.id.sequence > 0,
              finalAttachRequest.expectedSession == permit.admissionSession,
              finalAttachRequest.targetAuthority == permit.authority,
              finalAttachRequest.requiredStop == nil,
              stagingRequest.id.epoch == finalAttachRequest.id.epoch,
              stagingOrdinal >= 0,
              semanticDigest.bytes.count == SHA256.byteCount else {
            return nil
        }

        let program = PersistentLLDBAttachProgram.current
        let programRequest: PersistentLLDBAttachProgramRequest
        let commands: [String]
        do {
            programRequest = try PersistentLLDBAttachProgramRequest(
                sessionEpoch: permit.admissionSession.epoch,
                requestSequence: finalAttachRequest.id.sequence,
                adapterGeneration: permit.adapterGeneration,
                authority: permit.authority,
                correlationToken: permit.correlationToken
            )
            commands = program.installChunkCommands
                + [program.installFinalizeCommand]
                + (try program.requestCommands(for: programRequest))
        } catch {
            return nil
        }
        let stagingCount = commands.count - 1
        guard stagingCount > 0,
              stagingOrdinal < stagingCount,
              let stagingCountValue = UInt64(exactly: stagingCount),
              finalAttachRequest.id.sequence > stagingCountValue,
              let ordinalValue = UInt64(exactly: stagingOrdinal) else {
            return nil
        }
        let firstStagingSequence = finalAttachRequest.id.sequence - stagingCountValue
        let expectedStagingSequence = firstStagingSequence.addingReportingOverflow(ordinalValue)
        guard !expectedStagingSequence.overflow,
              stagingRequest.id.sequence == expectedStagingSequence.partialValue,
              semanticDigest == DebuggerLocalProcessAttachWriteSemanticDigest(
                  semanticCommand: commands[stagingOrdinal]
              ) else {
            return nil
        }

        self.transactionClaim = transactionClaim
        self.interlockIdentity = interlockIdentity
        self.policyRevision = policyRevision
        self.permitBindingDigest = permit.bindingDigest
        self.permitCorrelationToken = permit.correlationToken
        self.permitAuthority = permit.authority
        self.permitAdmissionSession = permit.admissionSession
        self.permitAdapterGeneration = permit.adapterGeneration
        self.adapterInstanceBinding = adapterInstanceBinding
        self.stagingRequest = stagingRequest
        self.finalAttachRequest = finalAttachRequest
        self.stagingOrdinal = stagingOrdinal
        self.semanticDigest = semanticDigest
        self.canonicalProgramSourceDigest = program.sourceSHA256
        self.canonicalStagingCommandCount = stagingCount
        self.bindingDigest = Self.makeBindingDigest(
            interlockIdentity: interlockIdentity,
            policyRevision: policyRevision,
            permitBindingDigest: permit.bindingDigest,
            permitCorrelationToken: permit.correlationToken,
            permitAuthority: permit.authority,
            permitAdmissionSession: permit.admissionSession,
            permitAdapterGeneration: permit.adapterGeneration,
            adapterInstanceBinding: adapterInstanceBinding,
            stagingRequest: stagingRequest,
            finalAttachRequest: finalAttachRequest,
            stagingOrdinal: stagingOrdinal,
            semanticDigest: semanticDigest,
            canonicalProgramSourceDigest: program.sourceSHA256,
            canonicalStagingCommandCount: stagingCount
        )
    }

    fileprivate var hasValidBinding: Bool {
        bindingDigest == Self.makeBindingDigest(
            interlockIdentity: interlockIdentity,
            policyRevision: policyRevision,
            permitBindingDigest: permitBindingDigest,
            permitCorrelationToken: permitCorrelationToken,
            permitAuthority: permitAuthority,
            permitAdmissionSession: permitAdmissionSession,
            permitAdapterGeneration: permitAdapterGeneration,
            adapterInstanceBinding: adapterInstanceBinding,
            stagingRequest: stagingRequest,
            finalAttachRequest: finalAttachRequest,
            stagingOrdinal: stagingOrdinal,
            semanticDigest: semanticDigest,
            canonicalProgramSourceDigest: canonicalProgramSourceDigest,
            canonicalStagingCommandCount: canonicalStagingCommandCount
        )
    }

    private static func makeBindingDigest(
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        policyRevision: DebuggerLocalProcessObservationPolicyRevisionVector,
        permitBindingDigest: Data,
        permitCorrelationToken: Data,
        permitAuthority: DebuggerSessionTargetAuthority,
        permitAdmissionSession: DebuggerSessionCoordinate,
        permitAdapterGeneration: UInt64,
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        stagingRequest: DebuggerRequestContext,
        finalAttachRequest: DebuggerRequestContext,
        stagingOrdinal: Int,
        semanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest,
        canonicalProgramSourceDigest: Data,
        canonicalStagingCommandCount: Int
    ) -> Data {
        var material = Data("MacScope.DebuggerLocalProcessAttach.StagingWriteIssuance.v1".utf8)
        material.append(0)
        material.appendAttachWriteLengthFramed(interlockIdentity.rawValue.uuidString.lowercased())
        material.appendAttachWriteUInt64(policyRevision.ownedInfrastructure.rawValue)
        material.appendAttachWriteUInt64(policyRevision.leaseMembership.rawValue)
        material.append(permitBindingDigest)
        material.append(permitCorrelationToken)
        material.appendAttachWriteInt32(permitAuthority.processID)
        material.appendAttachWriteLengthFramed(permitAuthority.identityDigest.lowercaseHex)
        material.appendAttachWriteLengthFramed(
            permitAdmissionSession.epoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(permitAdmissionSession.lifecycleRevision.rawValue)
        material.appendAttachWriteUInt64(permitAdapterGeneration)
        material.append(adapterInstanceBinding.digest)
        material.appendAttachWriteLengthFramed(
            stagingRequest.id.epoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(stagingRequest.id.sequence)
        material.appendAttachWriteLengthFramed(
            finalAttachRequest.id.epoch.rawValue.uuidString.lowercased()
        )
        material.appendAttachWriteUInt64(finalAttachRequest.id.sequence)
        material.appendAttachWriteUInt64(UInt64(stagingOrdinal))
        material.append(semanticDigest.bytes)
        material.append(canonicalProgramSourceDigest)
        material.appendAttachWriteUInt64(UInt64(canonicalStagingCommandCount))
        return Data(SHA256.hash(data: material))
    }
}

/// Opaque one-shot authority for one canonical attach-program staging write. Copies share the same
/// consumed state, while abandoned authorizations deallocate without an interlock-owned ledger.
struct DebuggerLocalProcessAttachStagingWriteAuthorization: Hashable, Sendable {
    fileprivate let authority:
        DebuggerLocalProcessAttachStagingWriteAuthorizationAuthority

    static func == (
        lhs: DebuggerLocalProcessAttachStagingWriteAuthorization,
        rhs: DebuggerLocalProcessAttachStagingWriteAuthorization
    ) -> Bool {
        lhs.authority === rhs.authority
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(authority))
    }
}

/// Opaque, copyable handle for one possible final attach write. Copying does not create another
/// use: consumption is recorded by the issuing interlock.
struct DebuggerLocalProcessAttachWriteGrant: Hashable, Sendable {
    fileprivate let authority: DebuggerLocalProcessAttachWriteGrantAuthority

    fileprivate var interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity {
        authority.interlockIdentity
    }

    fileprivate var bindingDigest: Data { authority.bindingDigest }

    static func == (
        lhs: DebuggerLocalProcessAttachWriteGrant,
        rhs: DebuggerLocalProcessAttachWriteGrant
    ) -> Bool {
        lhs.authority === rhs.authority
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(authority))
    }
}

/// Opaque proof of the synchronous point at which one exact final attach write became authorized.
/// Its constructor is private to this file; a generic request or caller-provided digest cannot be
/// promoted into a committed attach write.
struct DebuggerLocalProcessAttachWriteCommit: Hashable, Sendable {
    let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let requestID: DebuggerRequestID
    let bindingDigest: Data
    fileprivate let grantID: UUID
    fileprivate let commitID: UUID
}

enum DebuggerLocalProcessAttachWriteInterlockError: Error, Hashable, Sendable {
    case revisionMismatch
    case nonSuccessorRevision
    case foreignInterlockIdentity
    case foreignGrant
    case grantBindingMismatch
    case grantAlreadyConsumed
    case foreignStagingAuthorization
    case stagingAuthorizationBindingMismatch
    case stagingAuthorizationAlreadyConsumed
    case foreignPermitTransactionAuthority
    case transactionClaimBindingMismatch
    case permitTransactionAlreadyClaimed
    case transactionAdapterAlreadyBound
    case transactionAdapterNotBound
    case stagingAuthorizationOutOfOrder
    case finalGrantBeforeStagingComplete
    case finalGrantAlreadyIssued
}

/// Synchronous process-global fence shared by both policy-source registries and the retained LLDB
/// writer. Registry revisions and the final attach-write authorization therefore have one total
/// order even though the owning registries themselves are actors.
final class DebuggerLocalProcessAttachWriteInterlock: @unchecked Sendable {
    let identity: DebuggerLocalProcessAttachWriteInterlockIdentity

    private let lock = NSLock()
    private var revision: DebuggerLocalProcessObservationPolicyRevisionVector

    init(initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector) {
        identity = DebuggerLocalProcessAttachWriteInterlockIdentity(rawValue: UUID())
        revision = initialRevision
    }

    var currentSnapshot: DebuggerLocalProcessAttachWriteInterlockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DebuggerLocalProcessAttachWriteInterlockSnapshot(
            identity: identity,
            revision: revision
        )
    }

    func validatesCurrentRevision(
        _ candidate: DebuggerLocalProcessObservationPolicyRevisionVector
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == candidate
    }

    /// The closure must contain only the registry's synchronous state commit and must not re-enter
    /// this interlock. It runs under the same lock as final attach-write authorization.
    func commitOwnedInfrastructureRevision(
        from expected: DebuggerOwnedInfrastructureRevision,
        to next: DebuggerOwnedInfrastructureRevision,
        _ mutation: () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard revision.ownedInfrastructure == expected else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard Self.isExactSuccessor(next.rawValue, of: expected.rawValue) else {
            throw DebuggerLocalProcessAttachWriteInterlockError.nonSuccessorRevision
        }
        mutation()
        revision = DebuggerLocalProcessObservationPolicyRevisionVector(
            ownedInfrastructure: next,
            leaseMembership: revision.leaseMembership
        )
    }

    /// The closure must contain only the registry's synchronous state commit and must not re-enter
    /// this interlock. It runs under the same lock as final attach-write authorization.
    func commitLeaseMembershipRevision(
        from expected: DebuggerSessionLeaseMembershipRevision,
        to next: DebuggerSessionLeaseMembershipRevision,
        _ mutation: () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard revision.leaseMembership == expected else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard Self.isExactSuccessor(next.rawValue, of: expected.rawValue) else {
            throw DebuggerLocalProcessAttachWriteInterlockError.nonSuccessorRevision
        }
        mutation()
        revision = DebuggerLocalProcessObservationPolicyRevisionVector(
            ownedInfrastructure: revision.ownedInfrastructure,
            leaseMembership: next
        )
    }

    /// Atomically authenticates a certified pre-write exact-attach failure and removes its lease.
    /// Keeping failure authentication, registry mutation, and revision advancement under this one
    /// lock prevents a transaction claim from interposing after validation but before removal.
    func commitExactAttachFailureLeaseRemoval(
        permit: DebuggerSessionLeaseExactAttachPermit,
        claim: DebuggerLocalProcessExactAttachTransactionClaim?,
        disposition: PersistentLLDBExactAttachFinalCommandDisposition,
        from expected: DebuggerSessionLeaseMembershipRevision,
        to next: DebuggerSessionLeaseMembershipRevision,
        _ mutation: () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard validatesExactAttachFailureSettlementLocked(
            permit: permit,
            claim: claim,
            disposition: disposition
        ) else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionClaimBindingMismatch
        }
        guard revision.leaseMembership == expected else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard Self.isExactSuccessor(next.rawValue, of: expected.rawValue) else {
            throw DebuggerLocalProcessAttachWriteInterlockError.nonSuccessorRevision
        }
        mutation()
        revision = DebuggerLocalProcessObservationPolicyRevisionVector(
            ownedInfrastructure: revision.ownedInfrastructure,
            leaseMembership: next
        )
    }

    /// Permanently spends a registry-minted permit for one exact canonical transaction. This is
    /// intentionally synchronous and must run before the coordinator's first executor await.
    func claimExactAttachTransaction(
        _ input: DebuggerLocalProcessExactAttachTransactionClaimInput
    ) throws -> DebuggerLocalProcessExactAttachTransactionClaim {
        lock.lock()
        defer { lock.unlock() }
        let authority = input.permitTransactionAuthority
        guard authority.interlockIdentity == identity,
              authority.permitBindingDigest == input.permitBindingDigest else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .foreignPermitTransactionAuthority
        }
        guard input.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignInterlockIdentity
        }
        guard input.policyRevision == revision else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard input.hasValidBinding else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionClaimBindingMismatch
        }
        guard authority.claimID == nil else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .permitTransactionAlreadyClaimed
        }

        let claimID = UUID()
        authority.claimID = claimID
        authority.claimBindingDigest = input.bindingDigest
        authority.finalRequestID = input.finalAttachRequest.id
        authority.programSourceDigest = input.canonicalProgramSourceDigest
        authority.programDigest = input.canonicalProgramDigest
        authority.finalSemanticDigest = input.canonicalFinalSemanticDigest
        authority.stagingConsumed = Array(
            repeating: false,
            count: input.canonicalStagingCommandCount
        )
        return DebuggerLocalProcessExactAttachTransactionClaim(
            authority: authority,
            claimID: claimID,
            bindingDigest: input.bindingDigest
        )
    }

    /// Binds the already-spent permit to exactly one retained adapter. A replay is rejected before
    /// it can ask an executor for a second binding; this method only completes the first claim.
    func bindExactAttachTransactionAdapter(
        _ adapter: PersistentLLDBCLIAdapterInstanceBinding,
        to claim: DebuggerLocalProcessExactAttachTransactionClaim
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard validatesClaimLocked(claim) else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionClaimBindingMismatch
        }
        guard adapter.digest.count == SHA256.byteCount,
              adapter.sessionEpoch == claim.authority.finalRequestID?.epoch,
              adapter.adapterGeneration == claim.authority.permitAdapterGeneration else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionClaimBindingMismatch
        }
        guard claim.authority.adapterBinding == nil else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionAdapterAlreadyBound
        }
        claim.authority.adapterBinding = adapter
    }

    func issueExactAttachWriteGrant(
        for input: DebuggerLocalProcessAttachWriteIssuanceInput
    ) throws -> DebuggerLocalProcessAttachWriteGrant {
        lock.lock()
        defer { lock.unlock() }
        guard input.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignInterlockIdentity
        }
        guard input.policyRevision == revision else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard input.hasValidBinding else {
            throw DebuggerLocalProcessAttachWriteInterlockError.grantBindingMismatch
        }
        guard let claim = input.transactionClaim,
              validatesClaimLocked(claim),
              claimMatchesFinalIssuanceLocked(claim, input: input) else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionClaimBindingMismatch
        }
        guard claim.authority.adapterBinding != nil else {
            throw DebuggerLocalProcessAttachWriteInterlockError.transactionAdapterNotBound
        }
        guard claim.authority.stagingConsumed.allSatisfy({ $0 }) else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .finalGrantBeforeStagingComplete
        }
        guard !claim.authority.finalGrantIssued else {
            throw DebuggerLocalProcessAttachWriteInterlockError.finalGrantAlreadyIssued
        }
        claim.authority.finalGrantIssued = true

        return DebuggerLocalProcessAttachWriteGrant(
            authority: DebuggerLocalProcessAttachWriteGrantAuthority(
                interlockIdentity: identity,
                bindingDigest: input.bindingDigest
            )
        )
    }

    func issueExactAttachStagingWriteAuthorization(
        for input: DebuggerLocalProcessAttachStagingWriteIssuanceInput
    ) throws -> DebuggerLocalProcessAttachStagingWriteAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard input.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignInterlockIdentity
        }
        guard input.policyRevision == revision else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard input.hasValidBinding else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .stagingAuthorizationBindingMismatch
        }
        guard let claim = input.transactionClaim,
              validatesClaimLocked(claim),
              claimMatchesStagingIssuanceLocked(claim, input: input),
              claim.authority.adapterBinding != nil,
              claim.authority.outstandingStagingOrdinal == nil,
              input.stagingOrdinal == claim.authority.nextStagingOrdinal,
              input.stagingOrdinal < claim.authority.stagingConsumed.count,
              !claim.authority.stagingConsumed[input.stagingOrdinal] else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .stagingAuthorizationOutOfOrder
        }
        claim.authority.outstandingStagingOrdinal = input.stagingOrdinal
        return DebuggerLocalProcessAttachStagingWriteAuthorization(
            authority: DebuggerLocalProcessAttachStagingWriteAuthorizationAuthority(
                interlockIdentity: identity,
                bindingDigest: input.bindingDigest
            )
        )
    }

    /// The adapter consumes this authority immediately before the exact canonical staging write.
    /// No final-write commit is produced: staging is lifecycle-neutral and cannot prove attach.
    func consumeExactAttachStagingWriteAuthorization(
        _ authorization: DebuggerLocalProcessAttachStagingWriteAuthorization,
        matching input: DebuggerLocalProcessAttachStagingWriteIssuanceInput
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard authorization.authority.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .foreignStagingAuthorization
        }
        guard input.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignInterlockIdentity
        }
        guard input.policyRevision == revision else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard input.hasValidBinding,
              authorization.authority.bindingDigest == input.bindingDigest else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .stagingAuthorizationBindingMismatch
        }
        guard !authorization.authority.isConsumed else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .stagingAuthorizationAlreadyConsumed
        }
        guard let claim = input.transactionClaim,
              validatesClaimLocked(claim),
              claimMatchesStagingIssuanceLocked(claim, input: input),
              claim.authority.outstandingStagingOrdinal == input.stagingOrdinal,
              input.stagingOrdinal == claim.authority.nextStagingOrdinal else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .stagingAuthorizationOutOfOrder
        }
        authorization.authority.isConsumed = true
        claim.authority.stagingConsumed[input.stagingOrdinal] = true
        claim.authority.outstandingStagingOrdinal = nil
        claim.authority.nextStagingOrdinal += 1
    }

    /// This call is the pre-write linearization point. The grant is consumed before the opaque
    /// commit escapes, so neither copying the grant nor retrying after an uncertain adapter result
    /// can authorize a second final attach write.
    func commitExactAttachWrite(
        _ grant: DebuggerLocalProcessAttachWriteGrant,
        matching input: DebuggerLocalProcessAttachWriteIssuanceInput
    ) throws -> DebuggerLocalProcessAttachWriteCommit {
        lock.lock()
        defer { lock.unlock() }
        guard grant.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignGrant
        }
        guard input.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignInterlockIdentity
        }
        guard input.policyRevision == revision else {
            throw DebuggerLocalProcessAttachWriteInterlockError.revisionMismatch
        }
        guard input.hasValidBinding,
              input.bindingDigest == grant.bindingDigest else {
            throw DebuggerLocalProcessAttachWriteInterlockError.grantBindingMismatch
        }
        guard grant.authority.interlockIdentity == identity else {
            throw DebuggerLocalProcessAttachWriteInterlockError.foreignGrant
        }
        guard grant.authority.bindingDigest == input.bindingDigest else {
            throw DebuggerLocalProcessAttachWriteInterlockError.grantBindingMismatch
        }
        guard let claim = input.transactionClaim,
              validatesClaimLocked(claim),
              claimMatchesFinalIssuanceLocked(claim, input: input),
              claim.authority.finalGrantIssued else {
            throw DebuggerLocalProcessAttachWriteInterlockError
                .transactionClaimBindingMismatch
        }
        guard !grant.authority.isConsumed else {
            throw DebuggerLocalProcessAttachWriteInterlockError.grantAlreadyConsumed
        }
        guard !claim.authority.finalCommitted else {
            throw DebuggerLocalProcessAttachWriteInterlockError.grantAlreadyConsumed
        }

        let commitID = UUID()
        grant.authority.isConsumed = true
        grant.authority.commitID = commitID
        claim.authority.finalCommitted = true
        return DebuggerLocalProcessAttachWriteCommit(
            interlockIdentity: identity,
            requestID: input.finalAttachRequest.id,
            bindingDigest: input.bindingDigest,
            grantID: grant.authority.grantID,
            commitID: commitID
        )
    }

    /// Authenticates a returned commit against the exact issued grant reference. Matching request
    /// and binding values are insufficient because two grants may deliberately freeze the same
    /// issuance input; only the grant consumed at the writer can validate its stored commit ID.
    func validatesExactAttachWriteCommit(
        _ commit: DebuggerLocalProcessAttachWriteCommit,
        for grant: DebuggerLocalProcessAttachWriteGrant,
        matching input: DebuggerLocalProcessAttachWriteIssuanceInput
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return grant.authority.interlockIdentity == identity
            && input.interlockIdentity == identity
            && input.hasValidBinding
            && grant.authority.bindingDigest == input.bindingDigest
            && grant.authority.isConsumed
            && grant.authority.commitID == commit.commitID
            && grant.authority.grantID == commit.grantID
            && commit.interlockIdentity == identity
            && commit.requestID == input.finalAttachRequest.id
            && commit.bindingDigest == input.bindingDigest
            && input.transactionClaim.map(validatesClaimLocked) == true
            && input.transactionClaim?.authority.finalCommitted == true
    }

    /// Registry settlement authentication. A nil claim is valid only while the permit genuinely
    /// remains unclaimed; a claimed failure must carry the exact original claim. A certified
    /// definitely-not-written result can never settle a transaction whose final grant committed.
    func validatesExactAttachFailureSettlement(
        permit: DebuggerSessionLeaseExactAttachPermit,
        claim: DebuggerLocalProcessExactAttachTransactionClaim?,
        disposition: PersistentLLDBExactAttachFinalCommandDisposition
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return validatesExactAttachFailureSettlementLocked(
            permit: permit,
            claim: claim,
            disposition: disposition
        )
    }

    private func validatesExactAttachFailureSettlementLocked(
        permit: DebuggerSessionLeaseExactAttachPermit,
        claim: DebuggerLocalProcessExactAttachTransactionClaim?,
        disposition: PersistentLLDBExactAttachFinalCommandDisposition
    ) -> Bool {
        let authority = permit.exactAttachTransactionAuthority
        guard authority.interlockIdentity == identity,
              authority.permitBindingDigest == permit.bindingDigest else {
            return false
        }
        guard let claim else {
            return authority.claimID == nil
                && disposition == .definitelyNotDispatchedOrWritten
        }
        guard claim.authority === authority, validatesClaimLocked(claim) else {
            return false
        }
        return disposition != .definitelyNotDispatchedOrWritten
            || !authority.finalCommitted
    }

    func validatesCompletedExactAttachClaim(
        _ claim: DebuggerLocalProcessExactAttachTransactionClaim,
        permit: DebuggerSessionLeaseExactAttachPermit
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claim.authority === permit.exactAttachTransactionAuthority
            && validatesClaimLocked(claim)
            && claim.authority.finalCommitted
    }

    func hasBegunExactAttachTransaction(
        for permit: DebuggerSessionLeaseExactAttachPermit
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let authority = permit.exactAttachTransactionAuthority
        return authority.interlockIdentity == identity
            && authority.permitBindingDigest == permit.bindingDigest
            && authority.claimID != nil
    }

    private func validatesClaimLocked(
        _ claim: DebuggerLocalProcessExactAttachTransactionClaim
    ) -> Bool {
        claim.authority.interlockIdentity == identity
            && claim.authority.claimID == claim.claimID
            && claim.authority.claimBindingDigest == claim.bindingDigest
    }

    private func claimMatchesFinalIssuanceLocked(
        _ claim: DebuggerLocalProcessExactAttachTransactionClaim,
        input: DebuggerLocalProcessAttachWriteIssuanceInput
    ) -> Bool {
        claim.authority.finalRequestID == input.finalAttachRequest.id
            && claim.authority.adapterBinding == input.adapterInstanceBinding
            && claim.authority.finalSemanticDigest == input.semanticDigest
    }

    private func claimMatchesStagingIssuanceLocked(
        _ claim: DebuggerLocalProcessExactAttachTransactionClaim,
        input: DebuggerLocalProcessAttachStagingWriteIssuanceInput
    ) -> Bool {
        claim.authority.finalRequestID == input.finalAttachRequest.id
            && claim.authority.adapterBinding == input.adapterInstanceBinding
            && claim.authority.programSourceDigest == input.canonicalProgramSourceDigest
            && claim.authority.stagingConsumed.count == input.canonicalStagingCommandCount
    }

    private static func isExactSuccessor(_ candidate: UInt64, of current: UInt64) -> Bool {
        let (successor, overflowed) = current.addingReportingOverflow(1)
        return !overflowed && candidate == successor
    }
}

/// Permit-owned mutable claim state. The registry mints this reference once and permit copies
/// share it. Its storage is bounded by the canonical staging count and dies with the permit.
final class DebuggerLocalProcessExactAttachPermitTransactionAuthority: @unchecked Sendable {
    fileprivate let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    fileprivate let permitBindingDigest: Data
    fileprivate let permitAdapterGeneration: UInt64
    fileprivate var claimID: UUID?
    fileprivate var claimBindingDigest: Data?
    fileprivate var finalRequestID: DebuggerRequestID?
    fileprivate var programSourceDigest: Data?
    fileprivate var programDigest: Data?
    fileprivate var finalSemanticDigest: DebuggerLocalProcessAttachWriteSemanticDigest?
    fileprivate var adapterBinding: PersistentLLDBCLIAdapterInstanceBinding?
    fileprivate var stagingConsumed: [Bool] = []
    fileprivate var nextStagingOrdinal = 0
    fileprivate var outstandingStagingOrdinal: Int?
    fileprivate var finalGrantIssued = false
    fileprivate var finalCommitted = false

    init(
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        permitBindingDigest: Data,
        permitAdapterGeneration: UInt64
    ) {
        self.interlockIdentity = interlockIdentity
        self.permitBindingDigest = permitBindingDigest
        self.permitAdapterGeneration = permitAdapterGeneration
    }
}

/// Reference identity keeps every copied grant one-shot without retaining historical grants in the
/// app-global interlock. All mutation occurs while the issuing interlock's lock is held.
fileprivate final class DebuggerLocalProcessAttachWriteGrantAuthority: @unchecked Sendable {
    let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let grantID: UUID
    let bindingDigest: Data
    var isConsumed = false
    var commitID: UUID?

    init(
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        bindingDigest: Data
    ) {
        self.interlockIdentity = interlockIdentity
        grantID = UUID()
        self.bindingDigest = bindingDigest
    }
}

fileprivate final class DebuggerLocalProcessAttachStagingWriteAuthorizationAuthority:
    @unchecked Sendable
{
    let interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity
    let bindingDigest: Data
    var isConsumed = false

    init(
        interlockIdentity: DebuggerLocalProcessAttachWriteInterlockIdentity,
        bindingDigest: Data
    ) {
        self.interlockIdentity = interlockIdentity
        self.bindingDigest = bindingDigest
    }
}

private extension SHA256 {
    static var byteCount: Int { 32 }
}

private extension Data {
    mutating func appendAttachWriteLengthFramed(_ value: String) {
        let bytes = Data(value.utf8)
        appendAttachWriteUInt64(UInt64(bytes.count))
        append(bytes)
    }

    mutating func appendAttachWriteUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendAttachWriteInt32(_ value: Int32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
