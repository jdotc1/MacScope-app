import CryptoKit
import Foundation

enum Phase2AssistantShellContinuationState: String, CaseIterable, Codable, Equatable, Sendable {
    case prepared
    case selectingTools
    case finalizing
    case awaitingShellReview
    case executingShell
    case awaitingShellContinuation
    case continuingShell
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

struct Phase2AssistantShellTurnIdentity: Codable, Equatable, Hashable, Sendable {
    let workspaceID: UUID
    let workspaceDocumentIdentityDigest: String
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let originatingFinalizationRequestID: UUID

    var isStructurallyValid: Bool {
        let identifiers = correlationIdentifiers
        return turnSequence > 0
            && Self.isLowercaseSHA256(workspaceDocumentIdentityDigest)
            && !identifiers.contains(Self.zeroUUID)
            && Set(identifiers).count == identifiers.count
    }

    var correlationIdentifiers: [UUID] {
        [workspaceID, conversationID, inferenceTurnID, originatingFinalizationRequestID]
    }

    static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
            }
    }
}

enum Phase2AssistantWorkspaceDocumentIdentity {
    static func digest(documentID: UUID, workspaceID: UUID) -> String {
        sha256(
            "phase2-document-identity-v1\0"
                + documentID.uuidString.lowercased()
                + "\0"
                + workspaceID.uuidString.lowercased()
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum Phase2AssistantShellExecutionResultCanonicalizer {
    static func digest(_ result: Phase2AIShellOneShotExecutionResult) -> String {
        var data = Data("phase2-shell-execution-result-v2".utf8)
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }

        append(result.id.uuidString.lowercased())
        append(String(result.schemaVersion))
        append(result.proposalID.uuidString.lowercased())
        append(result.executablePath)
        append(String(result.arguments.count))
        result.arguments.forEach(append)
        append(result.workingDirectoryPath == nil ? "0" : "1")
        if let workingDirectoryPath = result.workingDirectoryPath { append(workingDirectoryPath) }
        append(String(result.timeoutMilliseconds))
        append(String(result.maximumOutputBytes))
        append(result.disposition.rawValue)
        append(result.terminationStatus == nil ? "0" : "1")
        if let terminationStatus = result.terminationStatus { append(String(terminationStatus)) }
        append(result.standardOutput)
        append(result.standardError)
        append(result.outputWasTruncated ? "1" : "0")
        append(String(result.startedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16))
        append(String(result.completedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16))
        append(result.failureMessage == nil ? "0" : "1")
        if let failureMessage = result.failureMessage { append(failureMessage) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum Phase2AssistantShellTerminalEventCanonicalizer {
    static func digest(
        turnIdentity: Phase2AssistantShellTurnIdentity,
        kind: String,
        content: String
    ) -> String {
        let canonical = [
            "phase2-terminal-result-v1",
            turnIdentity.workspaceID.uuidString.lowercased(),
            turnIdentity.conversationID.uuidString.lowercased(),
            turnIdentity.inferenceTurnID.uuidString.lowercased(),
            String(turnIdentity.turnSequence),
            turnIdentity.originatingFinalizationRequestID.uuidString.lowercased(),
            kind,
            content,
        ].joined(separator: "\0")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// App-owned immutable coordinate for the sole provider continuation admitted after one exact
/// restricted one-shot execution. Wire and persistence layers adapt this canonical semantic type;
/// they must not create competing coordinate ownership.
struct Phase2AssistantShellContinuationCoordinate: Codable, Equatable, Hashable, Sendable {
    static let continuationOrdinal: UInt64 = 1

    // Canonical field order. Do not reorder without a new coordinate schema.
    let workspaceID: UUID
    let workspaceDocumentIdentityDigest: String
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let originatingFinalizationRequestID: UUID
    let shellProposalID: UUID
    let shellExecutionID: UUID
    let runtimeAuthorityRecordID: UUID
    let shellProposalDigest: String
    let shellExecutionResultDigest: String
    let runtimeAuthorityRecordDigest: String
    let productionManifestIdentity: String
    let providerRevision: UInt64
    let continuationOrdinal: UInt64
    let continuationRequestID: UUID
    let integrityDigest: String

    init?(
        workspaceID: UUID,
        workspaceDocumentIdentityDigest: String,
        conversationID: UUID,
        inferenceTurnID: UUID,
        turnSequence: UInt64,
        originatingFinalizationRequestID: UUID,
        shellProposalID: UUID,
        shellExecutionID: UUID,
        runtimeAuthorityRecordID: UUID,
        shellProposalDigest: String,
        shellExecutionResultDigest: String,
        runtimeAuthorityRecordDigest: String,
        productionManifestIdentity: String,
        providerRevision: UInt64,
        continuationOrdinal: UInt64 = Self.continuationOrdinal,
        continuationRequestID: UUID,
        integrityDigest: String? = nil
    ) {
        guard turnSequence > 0,
              providerRevision > 0,
              continuationOrdinal == Self.continuationOrdinal,
              Phase2AssistantShellTurnIdentity.isLowercaseSHA256(workspaceDocumentIdentityDigest),
              Phase2AssistantShellTurnIdentity.isLowercaseSHA256(shellProposalDigest),
              Phase2AssistantShellTurnIdentity.isLowercaseSHA256(shellExecutionResultDigest),
              Phase2AssistantShellTurnIdentity.isLowercaseSHA256(runtimeAuthorityRecordDigest),
              Self.isManifestIdentity(productionManifestIdentity),
              Self.identifiersAreValid([
                  workspaceID, conversationID, inferenceTurnID, originatingFinalizationRequestID,
                  shellProposalID, shellExecutionID, runtimeAuthorityRecordID,
                  continuationRequestID,
              ])
        else { return nil }

        self.workspaceID = workspaceID
        self.workspaceDocumentIdentityDigest = workspaceDocumentIdentityDigest
        self.conversationID = conversationID
        self.inferenceTurnID = inferenceTurnID
        self.turnSequence = turnSequence
        self.originatingFinalizationRequestID = originatingFinalizationRequestID
        self.shellProposalID = shellProposalID
        self.shellExecutionID = shellExecutionID
        self.runtimeAuthorityRecordID = runtimeAuthorityRecordID
        self.shellProposalDigest = shellProposalDigest
        self.shellExecutionResultDigest = shellExecutionResultDigest
        self.runtimeAuthorityRecordDigest = runtimeAuthorityRecordDigest
        self.productionManifestIdentity = productionManifestIdentity
        self.providerRevision = providerRevision
        self.continuationOrdinal = continuationOrdinal
        self.continuationRequestID = continuationRequestID

        let computed = Self.computeIntegrityDigest(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: workspaceDocumentIdentityDigest,
            conversationID: conversationID,
            inferenceTurnID: inferenceTurnID,
            turnSequence: turnSequence,
            originatingFinalizationRequestID: originatingFinalizationRequestID,
            shellProposalID: shellProposalID,
            shellExecutionID: shellExecutionID,
            runtimeAuthorityRecordID: runtimeAuthorityRecordID,
            shellProposalDigest: shellProposalDigest,
            shellExecutionResultDigest: shellExecutionResultDigest,
            runtimeAuthorityRecordDigest: runtimeAuthorityRecordDigest,
            productionManifestIdentity: productionManifestIdentity,
            providerRevision: providerRevision,
            continuationOrdinal: continuationOrdinal,
            continuationRequestID: continuationRequestID
        )
        guard integrityDigest == nil || integrityDigest == computed else { return nil }
        self.integrityDigest = computed
    }

    var turnIdentity: Phase2AssistantShellTurnIdentity {
        .init(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: workspaceDocumentIdentityDigest,
            conversationID: conversationID,
            inferenceTurnID: inferenceTurnID,
            turnSequence: turnSequence,
            originatingFinalizationRequestID: originatingFinalizationRequestID
        )
    }

    var isIntegrityValid: Bool {
        guard let rebuilt = Self(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: workspaceDocumentIdentityDigest,
            conversationID: conversationID,
            inferenceTurnID: inferenceTurnID,
            turnSequence: turnSequence,
            originatingFinalizationRequestID: originatingFinalizationRequestID,
            shellProposalID: shellProposalID,
            shellExecutionID: shellExecutionID,
            runtimeAuthorityRecordID: runtimeAuthorityRecordID,
            shellProposalDigest: shellProposalDigest,
            shellExecutionResultDigest: shellExecutionResultDigest,
            runtimeAuthorityRecordDigest: runtimeAuthorityRecordDigest,
            productionManifestIdentity: productionManifestIdentity,
            providerRevision: providerRevision,
            continuationOrdinal: continuationOrdinal,
            continuationRequestID: continuationRequestID,
            integrityDigest: integrityDigest
        ) else { return false }
        return rebuilt.integrityDigest == integrityDigest
    }

    private static func isManifestIdentity(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        return Phase2AssistantShellTurnIdentity.isLowercaseSHA256(String(value.dropFirst(7)))
    }

    private static func identifiersAreValid(_ identifiers: [UUID]) -> Bool {
        !identifiers.contains(Phase2AssistantShellTurnIdentity.zeroUUID)
            && Set(identifiers).count == identifiers.count
    }

    private static func computeIntegrityDigest(
        workspaceID: UUID,
        workspaceDocumentIdentityDigest: String,
        conversationID: UUID,
        inferenceTurnID: UUID,
        turnSequence: UInt64,
        originatingFinalizationRequestID: UUID,
        shellProposalID: UUID,
        shellExecutionID: UUID,
        runtimeAuthorityRecordID: UUID,
        shellProposalDigest: String,
        shellExecutionResultDigest: String,
        runtimeAuthorityRecordDigest: String,
        productionManifestIdentity: String,
        providerRevision: UInt64,
        continuationOrdinal: UInt64,
        continuationRequestID: UUID
    ) -> String {
        var data = Data()
        [
            "phase2-assistant-shell-continuation-coordinate-v1",
            workspaceID.uuidString.lowercased(),
            workspaceDocumentIdentityDigest,
            conversationID.uuidString.lowercased(),
            inferenceTurnID.uuidString.lowercased(),
            String(turnSequence),
            originatingFinalizationRequestID.uuidString.lowercased(),
            shellProposalID.uuidString.lowercased(),
            shellExecutionID.uuidString.lowercased(),
            runtimeAuthorityRecordID.uuidString.lowercased(),
            shellProposalDigest,
            shellExecutionResultDigest,
            runtimeAuthorityRecordDigest,
            productionManifestIdentity,
            String(providerRevision),
            String(continuationOrdinal),
            continuationRequestID.uuidString.lowercased(),
        ].forEach { field in
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct Phase2AssistantShellProposalProvenance: Equatable, Sendable {
    let turnIdentity: Phase2AssistantShellTurnIdentity
    let proposalID: UUID
    let proposalDigest: String
    let executionSurface: Phase2AIShellExecutionSurface
    let isLegacy: Bool
}

enum Phase2AssistantShellProposalCanonicalizer {
    static func digest(_ proposal: Phase2AIShellCommandProposal) -> String {
        let fields = [
            proposal.proposalID.uuidString.lowercased(),
            proposal.executablePath,
            proposal.arguments.joined(separator: "\u{0}"),
            proposal.environment.sorted { $0.key < $1.key }
                .map { $0.key + "=" + $0.value }.joined(separator: "\u{0}"),
            proposal.workingDirectoryPath ?? "",
            String(proposal.timeoutMilliseconds),
            String(proposal.maximumOutputBytes),
            proposal.executionSurface.rawValue,
            proposal.requestedEffects.map(\.rawValue).sorted().joined(separator: ","),
        ]
        var bytes = Data("phase2-shell-proposal-v1".utf8)
        for field in fields {
            let data = Data(field.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(data)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct Phase2AssistantShellApproval: Equatable, Sendable {
    let turnIdentity: Phase2AssistantShellTurnIdentity
    let proposalID: UUID
    let proposalDigest: String
    let reservedExecutionID: UUID
}

struct Phase2AssistantShellExecutionAuthorityJoin: Equatable, Sendable {
    let turnIdentity: Phase2AssistantShellTurnIdentity
    let proposalID: UUID
    let proposalDigest: String
    let executionID: UUID
    let executionProposalID: UUID
    let executionResultDigest: String
    let executionDisposition: Phase2AIShellOneShotExecutionDisposition
    let runtimeAuthorityRecordID: UUID
    let runtimeAuthoritySessionID: UUID
    let runtimeAuthorityRecordDigest: String
    let runtimeAuthoritySurfaces: Set<Phase2RuntimeAuthoritySurface>
    let providerVisibleShellExecutionEnabled: Bool
    let productionManifestIdentity: String
    let providerRevision: UInt64
    let wasAlreadyConsumed: Bool
    let continuationRequestID: UUID
}

enum Phase2AssistantShellContinuationTerminalFailure: String, Codable, Equatable, Sendable {
    case proposalRejected
    case proposalInvalid
    case executionFailed
    case executionAuthorityInvalid
    case continuationFailed
    case ambiguousRestoredExecution
    case ambiguousRestoredContinuation
    case staleOrForeignEvent
}

enum Phase2AssistantShellContinuationRejection: Error, Equatable, Sendable {
    case invalidTransition(from: Phase2AssistantShellContinuationState)
    case staleOrForeignIdentity
    case invalidProposalProvenance
    case proposalAlreadyStaged
    case approvalMismatch
    case executionMismatch
    case invalidRuntimeAuthority
    case executionAlreadyConsumed
    case invalidCoordinate
    case continuationMismatch
}

enum Phase2AssistantShellContinuationAction: Equatable, Sendable {
    case beginToolSelection(Phase2AssistantShellTurnIdentity)
    case beginFinalization(Phase2AssistantShellTurnIdentity)
    case completeWithoutShell(Phase2AssistantShellTurnIdentity)
    case stageProposal(Phase2AssistantShellProposalProvenance)
    case approveAndReserveExecution(Phase2AssistantShellApproval)
    case rejectProposal(Phase2AssistantShellTurnIdentity)
    case cancel(Phase2AssistantShellTurnIdentity)
    case sealCompletedExecution(
        Phase2AssistantShellExecutionAuthorityJoin,
        Phase2AssistantShellContinuationCoordinate
    )
    case recordExecutionFailure(Phase2AssistantShellTurnIdentity)
    case reserveContinuation(Phase2AssistantShellContinuationCoordinate)
    case acceptContinuationFinal(Phase2AssistantShellContinuationCoordinate)
    case recordContinuationFailure(Phase2AssistantShellContinuationCoordinate)
}

enum Phase2AssistantShellContinuationRestoreDecision: Equatable, Sendable {
    case resumeLocalState
    case reserveUndispatchedContinuation
    case reduceDurablyCorrelatedTerminalOnly
    case terminal
    case failedClosed(Phase2AssistantShellContinuationTerminalFailure)
}

struct Phase2AssistantShellContinuationMachine: Equatable, Sendable {
    let turnIdentity: Phase2AssistantShellTurnIdentity
    private(set) var state: Phase2AssistantShellContinuationState = .prepared
    private(set) var proposal: Phase2AssistantShellProposalProvenance?
    private(set) var approvalWasConsumed = false
    private(set) var reservedExecutionID: UUID?
    private(set) var coordinate: Phase2AssistantShellContinuationCoordinate?
    private(set) var terminalFailure: Phase2AssistantShellContinuationTerminalFailure?

    init?(turnIdentity: Phase2AssistantShellTurnIdentity) {
        guard turnIdentity.isStructurallyValid else { return nil }
        self.turnIdentity = turnIdentity
    }

    @discardableResult
    mutating func apply(
        _ action: Phase2AssistantShellContinuationAction
    ) -> Result<Void, Phase2AssistantShellContinuationRejection> {
        guard actionIdentity(action) == turnIdentity else {
            return .failure(.staleOrForeignIdentity)
        }
        switch action {
        case .beginToolSelection:
            return transition(from: .prepared, to: .selectingTools)
        case .beginFinalization:
            return transition(from: .selectingTools, to: .finalizing)
        case .completeWithoutShell:
            return transition(from: .finalizing, to: .completed)
        case .stageProposal(let provenance):
            guard state == .finalizing else { return .failure(.invalidTransition(from: state)) }
            guard proposal == nil else { return .failure(.proposalAlreadyStaged) }
            guard !provenance.isLegacy,
                  provenance.executionSurface == .restrictedOneShotJob,
                  Phase2AssistantShellTurnIdentity.isLowercaseSHA256(provenance.proposalDigest),
                  !turnIdentity.correlationIdentifiers.contains(provenance.proposalID),
                  provenance.proposalID != Phase2AssistantShellTurnIdentity.zeroUUID
            else { return .failure(.invalidProposalProvenance) }
            proposal = provenance
            state = .awaitingShellReview
            return .success(())
        case .approveAndReserveExecution(let approval):
            guard state == .awaitingShellReview else {
                return .failure(.invalidTransition(from: state))
            }
            let approvalIdentifiers = turnIdentityIdentifiers + [
                proposal?.proposalID ?? Phase2AssistantShellTurnIdentity.zeroUUID,
                approval.reservedExecutionID,
            ]
            guard let proposal,
                  approval.proposalID == proposal.proposalID,
                  approval.proposalDigest == proposal.proposalDigest,
                  Self.identifiersAreValid(approvalIdentifiers),
                  !approvalWasConsumed,
                  reservedExecutionID == nil
            else { return .failure(.approvalMismatch) }
            approvalWasConsumed = true
            reservedExecutionID = approval.reservedExecutionID
            state = .executingShell
            return .success(())
        case .rejectProposal:
            guard state == .awaitingShellReview else {
                return .failure(.invalidTransition(from: state))
            }
            terminalFailure = .proposalRejected
            state = .failed
            return .success(())
        case .cancel:
            guard !state.isTerminal else { return .failure(.invalidTransition(from: state)) }
            state = .cancelled
            return .success(())
        case .sealCompletedExecution(let join, let coordinate):
            guard state == .executingShell else {
                return .failure(.invalidTransition(from: state))
            }
            guard let proposal,
                  let reservedExecutionID,
                  join.proposalID == proposal.proposalID,
                  join.proposalDigest == proposal.proposalDigest,
                  join.executionID == reservedExecutionID,
                  join.executionProposalID == proposal.proposalID,
                  join.executionDisposition == .completed,
                  Phase2AssistantShellTurnIdentity.isLowercaseSHA256(join.executionResultDigest)
            else { return .failure(.executionMismatch) }
            guard !join.wasAlreadyConsumed else { return .failure(.executionAlreadyConsumed) }
            guard join.runtimeAuthoritySessionID == join.executionID,
                  join.providerVisibleShellExecutionEnabled,
                  join.runtimeAuthoritySurfaces.contains(.providerVisibleShellExecution),
                  Phase2AssistantShellTurnIdentity.isLowercaseSHA256(join.runtimeAuthorityRecordDigest)
            else { return .failure(.invalidRuntimeAuthority) }
            guard coordinate.isIntegrityValid,
                  coordinate.turnIdentity == turnIdentity,
                  coordinate.shellProposalID == proposal.proposalID,
                  coordinate.shellProposalDigest == proposal.proposalDigest,
                  coordinate.shellExecutionID == join.executionID,
                  coordinate.shellExecutionResultDigest == join.executionResultDigest,
                  coordinate.runtimeAuthorityRecordID == join.runtimeAuthorityRecordID,
                  coordinate.runtimeAuthorityRecordDigest == join.runtimeAuthorityRecordDigest,
                  coordinate.productionManifestIdentity == join.productionManifestIdentity,
                  coordinate.providerRevision == join.providerRevision,
                  coordinate.continuationRequestID == join.continuationRequestID
            else { return .failure(.invalidCoordinate) }
            self.coordinate = coordinate
            state = .awaitingShellContinuation
            return .success(())
        case .recordExecutionFailure:
            guard state == .executingShell else {
                return .failure(.invalidTransition(from: state))
            }
            terminalFailure = .executionFailed
            state = .failed
            return .success(())
        case .reserveContinuation(let coordinate):
            guard state == .awaitingShellContinuation else {
                return .failure(.invalidTransition(from: state))
            }
            guard self.coordinate == coordinate, coordinate.isIntegrityValid else {
                return .failure(.continuationMismatch)
            }
            state = .continuingShell
            return .success(())
        case .acceptContinuationFinal(let coordinate):
            guard state == .continuingShell else {
                return .failure(.invalidTransition(from: state))
            }
            guard self.coordinate == coordinate, coordinate.isIntegrityValid else {
                return .failure(.continuationMismatch)
            }
            state = .completed
            return .success(())
        case .recordContinuationFailure(let coordinate):
            guard state == .continuingShell else {
                return .failure(.invalidTransition(from: state))
            }
            guard self.coordinate == coordinate, coordinate.isIntegrityValid else {
                return .failure(.continuationMismatch)
            }
            terminalFailure = .continuationFailed
            state = .failed
            return .success(())
        }
    }

    mutating func applyRestorePolicy(
        hasDurablyCorrelatedContinuationTerminal: Bool
    ) -> Phase2AssistantShellContinuationRestoreDecision {
        let decision = Self.restoreDecision(
            for: state,
            hasDurablyCorrelatedContinuationTerminal: hasDurablyCorrelatedContinuationTerminal
        )
        if case .failedClosed(let failure) = decision {
            terminalFailure = failure
            state = .failed
        }
        return decision
    }

    static func restoreDecision(
        for state: Phase2AssistantShellContinuationState,
        hasDurablyCorrelatedContinuationTerminal: Bool
    ) -> Phase2AssistantShellContinuationRestoreDecision {
        switch state {
        case .executingShell:
            return .failedClosed(.ambiguousRestoredExecution)
        case .awaitingShellContinuation:
            return .reserveUndispatchedContinuation
        case .continuingShell:
            if hasDurablyCorrelatedContinuationTerminal {
                return .reduceDurablyCorrelatedTerminalOnly
            }
            return .failedClosed(.ambiguousRestoredContinuation)
        case .completed, .failed, .cancelled:
            return .terminal
        case .prepared, .selectingTools, .finalizing, .awaitingShellReview:
            return .resumeLocalState
        }
    }

    private mutating func transition(
        from expected: Phase2AssistantShellContinuationState,
        to next: Phase2AssistantShellContinuationState
    ) -> Result<Void, Phase2AssistantShellContinuationRejection> {
        guard state == expected else { return .failure(.invalidTransition(from: state)) }
        state = next
        return .success(())
    }

    private func actionIdentity(
        _ action: Phase2AssistantShellContinuationAction
    ) -> Phase2AssistantShellTurnIdentity {
        switch action {
        case .beginToolSelection(let identity),
             .beginFinalization(let identity),
             .completeWithoutShell(let identity),
             .rejectProposal(let identity),
             .cancel(let identity),
             .recordExecutionFailure(let identity):
            return identity
        case .stageProposal(let provenance):
            return provenance.turnIdentity
        case .approveAndReserveExecution(let approval):
            return approval.turnIdentity
        case .sealCompletedExecution(let join, _):
            return join.turnIdentity
        case .reserveContinuation(let coordinate),
             .acceptContinuationFinal(let coordinate),
             .recordContinuationFailure(let coordinate):
            return coordinate.turnIdentity
        }
    }

    private var turnIdentityIdentifiers: [UUID] {
        [
            turnIdentity.workspaceID,
            turnIdentity.conversationID,
            turnIdentity.inferenceTurnID,
            turnIdentity.originatingFinalizationRequestID,
        ]
    }

    private static func identifiersAreValid(_ identifiers: [UUID]) -> Bool {
        !identifiers.contains(Phase2AssistantShellTurnIdentity.zeroUUID)
            && Set(identifiers).count == identifiers.count
    }
}
