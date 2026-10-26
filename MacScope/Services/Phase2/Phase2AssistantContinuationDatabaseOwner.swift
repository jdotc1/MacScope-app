import Foundation

@MainActor
final class Phase2AssistantContinuationDatabaseOwner {
    enum OwnerError: Error, Equatable {
        case invalidBaseDirectory
        case retired
        case identityMismatch
    }

    struct RecoveryProjection: Equatable, Sendable {
        let record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord
        let priorLogicalState: String
        let restorePolicy: String
        let diagnostic: String
    }

    let workspaceUUID: UUID
    let documentID: UUID
    let databaseURL: URL
    private(set) var workspaceRowID: Int64?
    private var retainedDatabase: WorkspaceDatabase?

    var database: WorkspaceDatabase {
        get throws {
            guard let retainedDatabase else { throw OwnerError.retired }
            return retainedDatabase
        }
    }

    init(
        workspaceUUID: UUID,
        documentID: UUID,
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let base: URL
        if let baseDirectoryURL {
            guard baseDirectoryURL.isFileURL else { throw OwnerError.invalidBaseDirectory }
            base = baseDirectoryURL
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            base = applicationSupport
                .appendingPathComponent("MacScope", isDirectory: true)
                .appendingPathComponent("ContinuationCheckpoints", isDirectory: true)
        }
        let workspaceDirectory = base.appendingPathComponent(
            workspaceUUID.uuidString.lowercased(),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = workspaceDirectory.appendingPathComponent(
            documentID.uuidString.lowercased() + ".sqlite",
            isDirectory: false
        )
        let database = try WorkspaceDatabase(path: databaseURL.path)
        try database.applySchema()
        self.workspaceUUID = workspaceUUID
        self.documentID = documentID
        self.databaseURL = databaseURL
        retainedDatabase = database
    }

    func bindWorkspaceRowID(_ rowID: Int64, workspaceUUID: UUID, documentID: UUID) throws {
        guard retainedDatabase != nil,
              workspaceUUID == self.workspaceUUID,
              documentID == self.documentID,
              rowID > 0,
              workspaceRowID.map({ $0 == rowID }) ?? true else {
            throw OwnerError.identityMismatch
        }
        workspaceRowID = rowID
    }

    func checkpointAdapter(
        recordID: UUID,
        now: @escaping () -> Date = Date.init
    ) throws -> Phase2AssistantShellContinuationDatabaseCheckpoint {
        guard try assistantRecord(id: recordID) != nil else {
            throw OwnerError.identityMismatch
        }
        return Phase2AssistantShellContinuationDatabaseCheckpoint(
            database: try database,
            assistantSessionRecordID: recordID,
            now: now
        )
    }

    func assistantRecord(
        id: UUID
    ) throws -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord? {
        guard let record = try database.phase2AssistantSessionRecord(id: id) else { return nil }
        guard isOwned(record) else { throw OwnerError.identityMismatch }
        return record
    }

    func sealTerminal(
        recordID: UUID,
        seal: Phase2AssistantShellContinuationTerminalSeal
    ) async throws -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord {
        try await checkpointAdapter(recordID: recordID).sealTerminal(seal)
    }

    /// Reduces orphaned continuation checkpoints after a durable reopen. Recovery never invokes a
    /// provider or execution surface: v3 does not persist the complete frozen provider context, so
    /// an apparent resumable state cannot prove that redispatch would reproduce the original turn.
    func recoverNonterminalCheckpoints(
        now: Date = Date()
    ) throws -> [RecoveryProjection] {
        guard let workspaceRowID else { throw OwnerError.identityMismatch }
        let database = try database
        let records = try database.nonterminalPhase2AssistantContinuationRecords(
            workspaceID: workspaceRowID,
            workspaceUUID: workspaceUUID,
            documentID: documentID
        )
        var projections: [RecoveryProjection] = []
        for record in records {
            guard isOwned(record) else { throw OwnerError.identityMismatch }
            guard var checkpoint = record.continuationCheckpoint else { continue }
            let priorState = checkpoint.logicalState
            let state = Phase2AssistantShellContinuationState(rawValue: priorState)
            let policy = state.map {
                Phase2AssistantShellContinuationMachine.restoreDecision(
                    for: $0,
                    hasDurablyCorrelatedContinuationTerminal:
                        checkpoint.continuationTerminalEventDigest != nil
                )
            }
            let policyName = Self.restorePolicyName(policy)
            let diagnostic = "durable_reopen_failed_closed:missing_frozen_provider_context:" + policyName
            checkpoint.logicalState = Phase2AssistantShellContinuationState.failed.rawValue
            checkpoint.continuationDispatchState = "recovery_failed_closed"
            checkpoint.finalProvenanceJSON = Self.recoveryDiagnosticJSON(
                priorLogicalState: priorState,
                restorePolicy: policyName,
                diagnostic: diagnostic
            )
            var replacement = record
            replacement.status = .failed
            replacement.completedAt = now
            replacement.answerText = nil
            replacement.transcriptText += "\nRecovery: " + diagnostic
            replacement.continuationCheckpoint = checkpoint
            replacement.contentSHA256 = replacement.calculatedContentSHA256()
            guard try database.transitionPhase2AssistantSessionRecord(
                id: record.id,
                expectedStatus: .outcomeUnknown,
                expectedLogicalState: priorState,
                to: replacement
            ) else { continue }
            projections.append(.init(
                record: replacement,
                priorLogicalState: priorState,
                restorePolicy: policyName,
                diagnostic: diagnostic
            ))
        }
        return projections
    }

    private static func restorePolicyName(
        _ decision: Phase2AssistantShellContinuationRestoreDecision?
    ) -> String {
        switch decision {
        case .resumeLocalState: return "resume_local_state"
        case .reserveUndispatchedContinuation: return "reserve_undispatched_continuation"
        case .reduceDurablyCorrelatedTerminalOnly: return "reduce_durably_correlated_terminal_only"
        case .terminal: return "terminal"
        case .failedClosed(let failure): return "failed_closed_" + failure.rawValue
        case nil: return "invalid_persisted_state"
        }
    }

    private static func recoveryDiagnosticJSON(
        priorLogicalState: String,
        restorePolicy: String,
        diagnostic: String
    ) -> String {
        let object = [
            "diagnostic": diagnostic,
            "prior_logical_state": priorLogicalState,
            "restore_policy": restorePolicy,
            "recovery_action": "failed_closed_without_provider_or_shell_dispatch",
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    func retire(fileManager: FileManager = .default) throws {
        retainedDatabase = nil
        workspaceRowID = nil
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let directory = databaseURL.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try fileManager.removeItem(at: directory)
        }
    }

    private func isOwned(
        _ record: WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord
    ) -> Bool {
        guard let workspaceRowID else { return false }
        return record.workspaceID == workspaceRowID
            && record.workspaceUUID == workspaceUUID
            && record.documentID == documentID
            && record.id == record.inferenceTurnID
            && record.contextDigest == Phase2AssistantWorkspaceDocumentIdentity.digest(
                documentID: documentID,
                workspaceID: workspaceUUID
            )
    }
}
