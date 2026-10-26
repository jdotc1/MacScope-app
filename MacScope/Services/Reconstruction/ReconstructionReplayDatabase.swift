import Foundation
import SQLite3

extension ReconstructionDatabaseOwner {
    /// Actor serialization plus the shared runtime's exclusive sidecar ownership fence every
    /// journal transaction. A dispatched marker is durable before the caller can send a request.
    func replayRecord(workspaceID: UUID, jobID: UUID, key: String) throws -> ReconstructionReplayRecord? {
        try withActiveDatabase { database in
            guard try database.reconstructionWorkspaceID(containingJobID: jobID) == workspaceID else {
                throw ReconstructionReplayError.invalidScope
            }
            return try database.ownerReplayRecord(jobID: jobID, key: key)
        }
    }

    /// True when a completed reply exists for the same job, task, logical round, request kind
    /// and objective whose original request canonicalizes to `request`, but whose recorded model
    /// identity differs from the current one. The provider prompt body embeds the model, so the
    /// comparison uses the model-free canonical semantic request, not canonicalPromptSHA256.
    func hasRecordedReplyUnderDifferentModel(workspaceID: UUID, jobID: UUID,
                                             current identity: ReconstructionPromptReplayIdentity,
                                             request: ReconstructionAIWorkerRequest) throws -> Bool {
        try withActiveDatabase { database in
            guard try database.reconstructionWorkspaceID(containingJobID: jobID) == workspaceID else {
                throw ReconstructionReplayError.invalidScope
            }
            let candidates = try database.ownerReplayRecords(workspaceID: workspaceID).filter {
                $0.identity.objectiveID == jobID && $0.identity.taskID == identity.taskID
                    && $0.identity.logicalRoundIndex == identity.logicalRoundIndex
                    && $0.identity.requestKind == identity.requestKind
                    && $0.identity.objectiveSHA256 == identity.objectiveSHA256
                    && $0.identity.modelIdentitySHA256 != identity.modelIdentitySHA256
                    && $0.freshReply != nil
            }
            guard !candidates.isEmpty else { return false }
            let current = try ReconstructionPromptReplayIdentity.canonicalRequest(request)
            return try candidates.contains { record in
                // Kinds with no replay decoder never replay, so they cannot be a model change.
                guard let reply = record.freshReply, let original = try? ReconstructionReplaySession
                    .decodeOriginal(reply, kind: identity.requestKind) else { return false }
                return try ReconstructionPromptReplayIdentity.canonicalRequest(original) == current
            }
        }
    }

    func publishReplayRecord(workspaceID: UUID, record: ReconstructionReplayRecord,
                             expected: ReconstructionReplayRecord?) throws {
        try record.validate()
        try withActiveDatabase { database in
            guard try database.reconstructionWorkspaceID(containingJobID: record.identity.objectiveID) == workspaceID else {
                throw ReconstructionReplayError.invalidScope
            }
            try database.publishOwnerReplayRecord(workspaceID: workspaceID, record: record, expected: expected)
        }
    }
}

/// Additive private storage, deliberately outside the closed reconstruction_* projection set.
/// Package portability is provided by the explicit replay reader feature, not by pretending a
/// package is a SQLite copy. These methods are invoked through ReconstructionDatabaseOwner.
extension WorkspaceDatabase {
    static let ownerReplayTable = "owner_job_inference_replay"
    static let maximumOwnerReplayRecordsPerJob = 128
    static let maximumOwnerReplayBytesPerJob = 16 * 1_048_576

    /// Match the portable state's aggregate bounds before a write, so many paused jobs cannot
    /// create a database state that the workspace reader is subsequently unable to open.
    func admitOwnerReplayStorage(workspaceID: UUID, newBytes: Int,
                                replacingInference: (jobID: UUID, key: String)? = nil,
                                replacingBudgetJobID: UUID? = nil) throws {
        let names = try tableNames()
        var count = 0, bytes = 0
        if names.contains(Self.ownerReplayTable) {
            let totals = try query("""
                SELECT COUNT(*), COALESCE(SUM(length(record_json)), 0)
                FROM owner_job_inference_replay WHERE workspace_uuid = ?
                AND NOT (job_id = ? AND replay_key = ?);
                """, bindings: [.text(workspaceID.uuidString),
                    .text(replacingInference?.jobID.uuidString ?? ""), .text(replacingInference?.key ?? "")]) { row in
                    (Int(sqlite3_column_int64(row, 0)), Int(sqlite3_column_int64(row, 1)))
                }.first ?? (0, 0)
            count += totals.0; bytes += totals.1
        }
        if names.contains(Self.ownerExecutionBudgetTable) {
            let totals = try query("""
                SELECT COUNT(*), COALESCE(SUM(length(record_json)), 0)
                FROM owner_job_execution_budget WHERE workspace_uuid = ? AND job_id != ?;
                """, bindings: [.text(workspaceID.uuidString), .text(replacingBudgetJobID?.uuidString ?? "")]) { row in
                    (Int(sqlite3_column_int64(row, 0)), Int(sqlite3_column_int64(row, 1)))
                }.first ?? (0, 0)
            count += totals.0; bytes += totals.1
        }
        guard newBytes > 0, newBytes <= ReconstructionReplayRecord.maximumRecordBytes,
              count < 2_048, bytes <= 64 * 1_048_576 - newBytes else {
            throw ReconstructionReplayError.journalFull
        }
    }

    private func ensureOwnerReplaySchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS owner_job_inference_replay (
                workspace_uuid TEXT NOT NULL,
                job_id TEXT NOT NULL,
                replay_key TEXT NOT NULL,
                record_json BLOB NOT NULL,
                record_sha256 TEXT NOT NULL,
                PRIMARY KEY (job_id, replay_key)
            );
            """)
        let columns = try query("PRAGMA table_info(owner_job_inference_replay);") { row in
            (String(cString: sqlite3_column_text(row, 1)), String(cString: sqlite3_column_text(row, 2)),
             sqlite3_column_int(row, 3), sqlite3_column_int(row, 5))
        }
        let expected: [(String, String, Int32, Int32)] = [
            ("workspace_uuid", "TEXT", 1, 0), ("job_id", "TEXT", 1, 1),
            ("replay_key", "TEXT", 1, 2), ("record_json", "BLOB", 1, 0),
            ("record_sha256", "TEXT", 1, 0)]
        guard columns.count == expected.count,
              zip(columns, expected).allSatisfy({ observed, wanted in
                  observed.0 == wanted.0 && observed.1 == wanted.1 && observed.2 == wanted.2 && observed.3 == wanted.3
              }) else {
            throw ReconstructionReplayError.invalidRecord
        }
    }

    func ownerReplayRecord(jobID: UUID, key: String) throws -> ReconstructionReplayRecord? {
        guard try tableNames().contains(Self.ownerReplayTable) else { return nil }
        try ensureOwnerReplaySchema()
        guard ReconstructionSourceInferenceContract.isSHA256(key) else { throw ReconstructionReplayError.invalidScope }
        let records = try query("""
            SELECT record_json, record_sha256 FROM owner_job_inference_replay
            WHERE job_id = ? AND replay_key = ?;
            """, bindings: [.text(jobID.uuidString), .text(key)]) { row -> ReconstructionReplayRecord in
            try Self.decodeOwnerReplayRow(row)
        }
        guard records.count <= 1 else { throw ReconstructionReplayError.invalidRecord }
        if let record = records.first {
            guard record.identity.objectiveID == jobID, try record.identity.key == key else {
                throw ReconstructionReplayError.invalidRecord
            }
        }
        return records.first
    }

    func ownerReplayRecords(workspaceID: UUID) throws -> [ReconstructionReplayRecord] {
        guard try tableNames().contains(Self.ownerReplayTable) else { return [] }
        try ensureOwnerReplaySchema()
        return try query("""
            SELECT record_json, record_sha256 FROM owner_job_inference_replay
            WHERE workspace_uuid = ? ORDER BY job_id, replay_key;
            """, bindings: [.text(workspaceID.uuidString)], map: Self.decodeOwnerReplayRow)
    }

    private static func decodeOwnerReplayRow(_ row: OpaquePointer) throws -> ReconstructionReplayRecord {
        let count = Int(sqlite3_column_bytes(row, 0))
        guard count > 0, count <= ReconstructionReplayRecord.maximumRecordBytes,
              let raw = sqlite3_column_blob(row, 0), let digest = sqlite3_column_text(row, 1) else {
            throw ReconstructionReplayError.invalidRecord
        }
        let bytes = Data(bytes: raw, count: count)
        guard ReconstructionSourceInferenceContract.sha256(bytes) == String(cString: digest) else {
            throw ReconstructionReplayError.invalidRecord
        }
        let record = try JSONDecoder().decode(ReconstructionReplayRecord.self, from: bytes)
        try record.validate()
        guard try ReconstructionCanonicalJSON.encode(record) == bytes else { throw ReconstructionReplayError.invalidRecord }
        return record
    }

    func publishOwnerReplayRecord(workspaceID: UUID, record: ReconstructionReplayRecord,
                                  expected: ReconstructionReplayRecord?) throws {
        try record.validate()
        let key = try record.identity.key
        let bytes = try ReconstructionCanonicalJSON.encode(record)
        guard bytes.count <= ReconstructionReplayRecord.maximumRecordBytes else { throw ReconstructionReplayError.journalFull }
        try ensureOwnerReplaySchema()
        // NORMAL WAL commits do not promise the response survives power loss. This narrow owner
        // transaction requires a synced WAL commit before returning the reply to the planner.
        let synchronous = try query("PRAGMA synchronous;") { sqlite3_column_int($0, 0) }.first ?? 2
        if synchronous < 2 { try execute("PRAGMA synchronous=FULL;") }
        defer { if synchronous < 2 { try? execute("PRAGMA synchronous=\(synchronous);") } }
        try withOwnerReplayTransaction {
            let prior = try ownerReplayRecord(jobID: record.identity.objectiveID, key: key)
            guard prior == expected else { throw ReconstructionReplayError.conflictingRecord }
            let totals = try query("""
                SELECT COUNT(*), COALESCE(SUM(length(record_json)), 0)
                FROM owner_job_inference_replay WHERE job_id = ? AND replay_key != ?;
                """, bindings: [.text(record.identity.objectiveID.uuidString), .text(key)]) { row in
                    (Int(sqlite3_column_int64(row, 0)), Int(sqlite3_column_int64(row, 1)))
                }.first ?? (0, 0)
            guard totals.0 < Self.maximumOwnerReplayRecordsPerJob,
                  totals.1 <= Self.maximumOwnerReplayBytesPerJob - bytes.count else {
                throw ReconstructionReplayError.journalFull
            }
            try admitOwnerReplayStorage(workspaceID: workspaceID, newBytes: bytes.count,
                replacingInference: (record.identity.objectiveID, key))
            try run("""
                INSERT INTO owner_job_inference_replay
                    (workspace_uuid, job_id, replay_key, record_json, record_sha256)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(job_id, replay_key) DO UPDATE SET record_json=excluded.record_json,
                    record_sha256=excluded.record_sha256;
                """, bindings: [.text(workspaceID.uuidString), .text(record.identity.objectiveID.uuidString),
                    .text(key), .blob(bytes), .text(ReconstructionSourceInferenceContract.sha256(bytes))])
        }
    }
}

extension WorkspaceDatabase {
    func ownerReplayEnvelopes(workspaceID: UUID) throws -> [ReconstructionWorkspaceReplayRecord] {
        try ownerReplayRecords(workspaceID: workspaceID).map {
            ReconstructionWorkspaceReplayRecord(jobID: $0.identity.objectiveID, payload: try ReconstructionCanonicalJSON.encode($0))
        } + ownerExecutionBudgetEnvelopes(workspaceID: workspaceID)
    }

    /// Called inside the package/state import transaction. Imported observations are never
    /// promoted to a live lease, and a conflicting live journal cannot be overwritten by Save.
    func restoreOwnerReplayEnvelopes(workspaceID: UUID, state: ReconstructionWorkspaceState) throws {
        try restoreOwnerExecutionBudgets(workspaceID: workspaceID, state: state)
        guard let records = state.replayRecords else { return }
        let envelopes = records.filter { $0.kind == .inference }
        guard !envelopes.isEmpty else { return }
        let jobs = Dictionary(uniqueKeysWithValues: state.jobs.map { ($0.jobID, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.identity.taskID, $0) })
        var keys: Set<String> = []
        var totals: [UUID: (count: Int, bytes: Int)] = [:]
        let decoded = try envelopes.map { envelope -> ReconstructionReplayRecord in
            let record = try JSONDecoder().decode(ReconstructionReplayRecord.self, from: envelope.payload)
            try record.validate()
            guard try ReconstructionCanonicalJSON.encode(record) == envelope.payload,
                  envelope.jobID == record.identity.objectiveID,
                  let job = jobs[envelope.jobID], job.objectiveSHA256 == record.identity.objectiveSHA256,
                  let task = tasks[record.identity.taskID], task.identity.jobID == job.jobID,
                  task.identity.kind == .modelRound, keys.insert(try record.identity.key).inserted else {
                throw ReconstructionReplayError.invalidRecord
            }
            let prior = totals[envelope.jobID] ?? (0, 0)
            guard prior.count < Self.maximumOwnerReplayRecordsPerJob,
                  prior.bytes <= Self.maximumOwnerReplayBytesPerJob - envelope.payload.count else {
                throw ReconstructionReplayError.journalFull
            }
            totals[envelope.jobID] = (prior.count + 1, prior.bytes + envelope.payload.count)
            return record
        }
        try ensureOwnerReplaySchema()
        for (record, envelope) in zip(decoded, envelopes) {
            let key = try record.identity.key
            if let prior = try ownerReplayRecord(jobID: record.identity.objectiveID, key: key) {
                guard prior == record else { throw ReconstructionReplayError.conflictingRecord }
                continue
            }
            try admitOwnerReplayStorage(workspaceID: workspaceID, newBytes: envelope.payload.count)
            try run("""
                INSERT INTO owner_job_inference_replay
                    (workspace_uuid, job_id, replay_key, record_json, record_sha256)
                VALUES (?, ?, ?, ?, ?);
                """, bindings: [.text(workspaceID.uuidString), .text(envelope.jobID.uuidString), .text(key),
                    .blob(envelope.payload), .text(ReconstructionSourceInferenceContract.sha256(envelope.payload))])
        }
    }

    /// Save is the retention boundary; terminal jobs' immutable model receipts remain intact.
    func pruneTerminalOwnerReplayRecords(workspaceID: UUID, state: ReconstructionWorkspaceState) throws {
        try pruneTerminalOwnerExecutionBudgets(workspaceID: workspaceID, state: state)
        guard try tableNames().contains(Self.ownerReplayTable) else { return }
        try ensureOwnerReplaySchema()
        let records = try ownerReplayRecords(workspaceID: workspaceID)
        for job in state.jobs where job.state.isTerminal {
            try retainOwnerInferenceHistory(workspaceID: workspaceID, jobID: job.jobID,
                records: records, receipts: state.modelReceipts)
            try run("DELETE FROM owner_job_inference_replay WHERE workspace_uuid = ? AND job_id = ?;",
                bindings: [.text(workspaceID.uuidString), .text(job.jobID.uuidString)])
        }
    }
}
