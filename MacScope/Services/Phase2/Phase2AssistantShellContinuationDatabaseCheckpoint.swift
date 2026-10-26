import Foundation

struct Phase2AssistantShellContinuationTerminalSeal: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case completed(answer: String)
        case failed(diagnostic: String)
        case rejected(diagnostic: String)
        case cancelled
    }

    let expectedLogicalState: Phase2AssistantShellContinuationState
    let disposition: Disposition
    let terminalEventDigest: String
    let completedAt: Date
}

@MainActor
final class Phase2AssistantShellContinuationDatabaseCheckpoint:
    Phase2AssistantShellContinuationCheckpointing
{
    enum PersistenceError: Error, Equatable {
        case recordMissing
        case checkpointMissing
        case identityMismatch
        case invalidState
        case invalidCoordinate
        case invalidTerminalSeal
        case staleTransition
    }

    private let database: WorkspaceDatabase
    private let assistantSessionRecordID: UUID
    private let now: () -> Date

    init(
        database: WorkspaceDatabase,
        assistantSessionRecordID: UUID,
        now: @escaping () -> Date = Date.init
    ) {
        self.database = database
        self.assistantSessionRecordID = assistantSessionRecordID
        self.now = now
    }

    func persistAssistantShellContinuation(
        _ machine: Phase2AssistantShellContinuationMachine
    ) async throws {
        guard var record = try database.phase2AssistantSessionRecord(id: assistantSessionRecordID) else {
            throw PersistenceError.recordMissing
        }
        guard var checkpoint = record.continuationCheckpoint else {
            throw PersistenceError.checkpointMissing
        }
        guard record.status == .outcomeUnknown,
              let storedIdentity = Self.turnIdentity(record: record, checkpoint: checkpoint),
              storedIdentity == machine.turnIdentity,
              checkpoint.isStructurallyValid(
                  workspaceID: record.workspaceUUID,
                  conversationID: record.conversationID,
                  inferenceTurnID: record.inferenceTurnID,
                  turnSequence: record.turnSequence
              ),
              checkpoint.shellProposalID == machine.proposal?.proposalID,
              checkpoint.shellProposalSHA256 == machine.proposal?.proposalDigest else {
            throw PersistenceError.identityMismatch
        }
        guard let expectedState = expectedPredecessor(of: machine.state),
              checkpoint.logicalState == expectedState.rawValue else {
            throw PersistenceError.invalidState
        }

        checkpoint.logicalState = machine.state.rawValue
        switch machine.state {
        case .executingShell:
            guard machine.approvalWasConsumed, let executionID = machine.reservedExecutionID else {
                throw PersistenceError.invalidState
            }
            checkpoint.humanDecision = "approved"
            checkpoint.approvalState = "consumed"
            checkpoint.approvalConsumedAt = now()
            checkpoint.shellExecutionID = executionID
        case .awaitingShellContinuation, .continuingShell, .completed, .failed:
            if let coordinate = machine.coordinate {
                guard coordinate.isIntegrityValid,
                      let mapped = Self.persistenceCoordinate(from: coordinate) else {
                    throw PersistenceError.invalidCoordinate
                }
                checkpoint.shellExecutionID = coordinate.shellExecutionID
                checkpoint.shellExecutionSHA256 = coordinate.shellExecutionResultDigest
                checkpoint.completedExecutionReference = coordinate.shellExecutionID.uuidString
                checkpoint.runtimeAuthorityRecordID = coordinate.runtimeAuthorityRecordID
                checkpoint.runtimeAuthoritySHA256 = coordinate.runtimeAuthorityRecordDigest
                checkpoint.continuationCoordinate = mapped
                checkpoint.continuationOrdinal = Int(coordinate.continuationOrdinal)
                checkpoint.continuationRequestID = coordinate.continuationRequestID
                checkpoint.continuationDispatchState = machine.state == .awaitingShellContinuation
                    ? "not_dispatched" : "dispatched"
            } else if machine.state != .failed {
                throw PersistenceError.invalidCoordinate
            }
        default:
            throw PersistenceError.invalidState
        }

        record.continuationCheckpoint = checkpoint
        record.contentSHA256 = WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord.contentSHA256(
            id: record.id,
            workspaceUUID: record.workspaceUUID,
            documentID: record.documentID,
            sequence: record.sequence,
            conversationID: record.conversationID,
            turnSequence: record.turnSequence,
            inferenceTurnID: record.inferenceTurnID,
            isLegacy: record.isLegacy,
            intentID: record.intentID,
            userGoal: record.userGoal,
            status: record.status,
            promptText: record.promptText,
            answerText: record.answerText,
            transcriptText: record.transcriptText,
            contextDigest: record.contextDigest,
            canonicalByteCount: record.canonicalByteCount,
            providerToolCount: record.providerToolCount,
            recordSchemaVersion: record.recordSchemaVersion,
            createdAt: record.createdAt,
            completedAt: record.completedAt,
            continuationCheckpoint: checkpoint
        )
        guard try database.transitionPhase2AssistantSessionRecord(
            id: record.id,
            expectedStatus: record.status,
            expectedLogicalState: expectedState.rawValue,
            to: record
        ) else {
            throw PersistenceError.staleTransition
        }
    }

    /// Durably seals the exact terminal event before any UI publication. A byte-for-byte
    /// equivalent retry returns the winning record; stale or conflicting terminal candidates fail
    /// closed and cannot overwrite it.
    func sealTerminal(
        _ seal: Phase2AssistantShellContinuationTerminalSeal
    ) async throws -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord {
        guard seal.expectedLogicalState == .awaitingShellReview
                || seal.expectedLogicalState == .executingShell
                || seal.expectedLogicalState == .awaitingShellContinuation
                || seal.expectedLogicalState == .continuingShell,
              Self.isLowercaseSHA256(seal.terminalEventDigest) else {
            throw PersistenceError.invalidTerminalSeal
        }
        guard let current = try database.phase2AssistantSessionRecord(id: assistantSessionRecordID)
        else { throw PersistenceError.recordMissing }
        guard var checkpoint = current.continuationCheckpoint
        else { throw PersistenceError.checkpointMissing }
        guard let storedIdentity = Self.turnIdentity(record: current, checkpoint: checkpoint),
              checkpoint.isStructurallyValid(
                  workspaceID: current.workspaceUUID,
                  conversationID: current.conversationID,
                  inferenceTurnID: current.inferenceTurnID,
                  turnSequence: current.turnSequence
              ),
              let terminalEvent = Self.terminalEvent(for: seal.disposition),
              seal.terminalEventDigest == Phase2AssistantShellTerminalEventCanonicalizer.digest(
                  turnIdentity: storedIdentity,
                  kind: terminalEvent.kind,
                  content: terminalEvent.content
              ),
              seal.completedAt >= current.createdAt else {
            throw PersistenceError.invalidTerminalSeal
        }

        let provenance = try Self.canonicalTerminalProvenance(
            record: current,
            seal: seal
        )
        let terminal = Self.terminalProjection(for: seal.disposition)
        if current.status != .outcomeUnknown {
            guard Self.isEquivalentTerminalWinner(
                current,
                logicalState: terminal.logicalState,
                status: terminal.status,
                answer: terminal.answer,
                completedAt: seal.completedAt,
                terminalEventDigest: seal.terminalEventDigest,
                finalProvenanceJSON: provenance
            ) else { throw PersistenceError.staleTransition }
            return current
        }
        guard checkpoint.logicalState == seal.expectedLogicalState.rawValue else {
            throw PersistenceError.staleTransition
        }

        checkpoint.logicalState = terminal.logicalState.rawValue
        checkpoint.continuationDispatchState = "terminal_received"
        checkpoint.continuationTerminalEventDigest = seal.terminalEventDigest
        checkpoint.finalProvenanceJSON = provenance
        var replacement = current
        replacement.status = terminal.status
        replacement.answerText = terminal.answer
        replacement.completedAt = seal.completedAt
        replacement.continuationCheckpoint = checkpoint
        replacement.contentSHA256 = replacement.calculatedContentSHA256()

        guard try database.transitionPhase2AssistantSessionRecord(
            id: current.id,
            expectedStatus: .outcomeUnknown,
            expectedLogicalState: seal.expectedLogicalState.rawValue,
            to: replacement
        ) else {
            guard let winner = try database.phase2AssistantSessionRecord(id: current.id),
                  Self.isEquivalentTerminalWinner(
                    winner,
                    logicalState: terminal.logicalState,
                    status: terminal.status,
                    answer: terminal.answer,
                    completedAt: seal.completedAt,
                    terminalEventDigest: seal.terminalEventDigest,
                    finalProvenanceJSON: provenance
                  ) else { throw PersistenceError.staleTransition }
            return winner
        }
        guard let sealed = try database.phase2AssistantSessionRecord(id: current.id) else {
            throw PersistenceError.recordMissing
        }
        return sealed
    }

    static func persistenceCoordinate(
        from coordinate: Phase2AssistantShellContinuationCoordinate
    ) -> Phase2AssistantContinuationCoordinateRecord? {
        guard coordinate.isIntegrityValid,
              let turnSequence = Int(exactly: coordinate.turnSequence),
              let providerRevision = Int(exactly: coordinate.providerRevision),
              let ordinal = Int(exactly: coordinate.continuationOrdinal) else { return nil }
        return .init(
            workspaceID: coordinate.workspaceID,
            workspaceDocumentIdentityDigest: coordinate.workspaceDocumentIdentityDigest,
            conversationID: coordinate.conversationID,
            inferenceTurnID: coordinate.inferenceTurnID,
            turnSequence: turnSequence,
            originatingFinalizationRequestID: coordinate.originatingFinalizationRequestID,
            shellProposalID: coordinate.shellProposalID,
            shellExecutionID: coordinate.shellExecutionID,
            runtimeAuthorityRecordID: coordinate.runtimeAuthorityRecordID,
            shellProposalDigest: coordinate.shellProposalDigest,
            shellExecutionResultDigest: coordinate.shellExecutionResultDigest,
            runtimeAuthorityRecordDigest: coordinate.runtimeAuthorityRecordDigest,
            productionManifestIdentity: coordinate.productionManifestIdentity,
            providerRevision: String(providerRevision),
            continuationOrdinal: ordinal,
            continuationRequestID: coordinate.continuationRequestID,
            integrityDigest: coordinate.integrityDigest
        )
    }

    private func expectedPredecessor(
        of state: Phase2AssistantShellContinuationState
    ) -> Phase2AssistantShellContinuationState? {
        switch state {
        case .executingShell: .awaitingShellReview
        case .awaitingShellContinuation: .executingShell
        case .continuingShell: .awaitingShellContinuation
        case .completed: .continuingShell
        case .failed:
            Phase2AssistantShellContinuationState(rawValue:
                (try? database.phase2AssistantSessionRecord(id: assistantSessionRecordID))?
                    .continuationCheckpoint?.logicalState ?? ""
            )
        default: nil
        }
    }

    private static func terminalProjection(
        for disposition: Phase2AssistantShellContinuationTerminalSeal.Disposition
    ) -> (
        logicalState: Phase2AssistantShellContinuationState,
        status: WorkspaceDatabase.Phase2AssistantPersistedSessionStatus,
        answer: String?
    ) {
        switch disposition {
        case .completed(let answer): return (.completed, .completed, answer)
        case .failed, .rejected: return (.failed, .failed, nil)
        case .cancelled: return (.cancelled, .cancelled, nil)
        }
    }

    private static func canonicalTerminalProvenance(
        record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord,
        seal: Phase2AssistantShellContinuationTerminalSeal
    ) throws -> String {
        guard let checkpoint = record.continuationCheckpoint else {
            throw PersistenceError.checkpointMissing
        }
        var object: [String: Any] = [
            "conversation_id": record.conversationID.uuidString.lowercased(),
            "inference_turn_id": record.inferenceTurnID.uuidString.lowercased(),
            "shell_proposal_id": checkpoint.shellProposalID.uuidString.lowercased(),
            "terminal_event_digest": seal.terminalEventDigest,
            "turn_sequence": record.turnSequence,
        ]
        if let continuationRequestID = checkpoint.continuationRequestID {
            object["continuation_request_id"] = continuationRequestID.uuidString.lowercased()
        }
        switch seal.disposition {
        case .completed(let answer):
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersistenceError.invalidTerminalSeal
            }
            object["disposition"] = "completed"
        case .failed(let diagnostic):
            guard !diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersistenceError.invalidTerminalSeal
            }
            object["disposition"] = "failed"
            object["diagnostic"] = diagnostic
        case .rejected(let diagnostic):
            guard !diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersistenceError.invalidTerminalSeal
            }
            object["disposition"] = "rejected"
            object["diagnostic"] = diagnostic
        case .cancelled:
            object["disposition"] = "cancelled"
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func turnIdentity(
        record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord,
        checkpoint: Phase2AssistantContinuationCheckpointRecord
    ) -> Phase2AssistantShellTurnIdentity? {
        guard record.id == record.inferenceTurnID,
              let documentDigest = record.contextDigest,
              documentDigest == Phase2AssistantWorkspaceDocumentIdentity.digest(
                  documentID: record.documentID,
                  workspaceID: record.workspaceUUID
              ),
              let turnSequence = UInt64(exactly: record.turnSequence) else { return nil }
        let identity = Phase2AssistantShellTurnIdentity(
            workspaceID: record.workspaceUUID,
            workspaceDocumentIdentityDigest: documentDigest,
            conversationID: record.conversationID,
            inferenceTurnID: record.inferenceTurnID,
            turnSequence: turnSequence,
            originatingFinalizationRequestID: checkpoint.initialRequestID
        )
        return identity.isStructurallyValid ? identity : nil
    }

    private static func terminalEvent(
        for disposition: Phase2AssistantShellContinuationTerminalSeal.Disposition
    ) -> (kind: String, content: String)? {
        let kind: String
        let content: String
        let maximumBytes: Int
        switch disposition {
        case .completed(let answer):
            kind = "completed"
            content = answer
            maximumBytes = 60_000
        case .failed(let diagnostic):
            kind = "failed"
            content = diagnostic
            maximumBytes = 4_096
        case .rejected(let diagnostic):
            kind = "rejected"
            content = diagnostic
            maximumBytes = 4_096
        case .cancelled:
            kind = "cancelled"
            content = ""
            maximumBytes = 0
        }
        guard content.utf8.count <= maximumBytes,
              kind == "cancelled"
                || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (kind, content)
    }

    private static func isEquivalentTerminalWinner(
        _ record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord,
        logicalState: Phase2AssistantShellContinuationState,
        status: WorkspaceDatabase.Phase2AssistantPersistedSessionStatus,
        answer: String?,
        completedAt: Date,
        terminalEventDigest: String,
        finalProvenanceJSON: String
    ) -> Bool {
        record.status == status
            && record.answerText == answer
            && record.completedAt == completedAt
            && record.continuationCheckpoint?.logicalState == logicalState.rawValue
            && record.continuationCheckpoint?.continuationDispatchState == "terminal_received"
            && record.continuationCheckpoint?.continuationTerminalEventDigest == terminalEventDigest
            && record.continuationCheckpoint?.finalProvenanceJSON == finalProvenanceJSON
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
