import Foundation
import SQLite3

/// Compact, live-database-only provenance retained after terminal Save prunes active journals.
/// Completed packages intentionally carry only their ordinary immutable model receipts. A
/// missing history row means unknown provenance, never that every receipt was freshly inferred.
struct ReconstructionInferenceHistory: Codable, Equatable, Sendable {
    struct Round: Codable, Equatable, Sendable {
        let logicalRoundIndex: Int
        let mode: ReconstructionModelReplayReceipt.Mode
        let originalRequestID: UUID
    }
    static let schemaVersion = 1
    static let maximumBytes = 65_536
    let schemaVersion: Int
    let jobID: UUID
    let rounds: [Round]

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              rounds.count <= WorkspaceDatabase.maximumOwnerReplayRecordsPerJob,
              rounds.allSatisfy({ $0.logicalRoundIndex >= 0 }),
              Set(rounds.map(\.logicalRoundIndex)).count == rounds.count,
              Set(rounds.map(\.originalRequestID)).count == rounds.count,
              rounds.map(\.logicalRoundIndex) == rounds.map(\.logicalRoundIndex).sorted() else {
            throw ReconstructionReplayError.invalidRecord
        }
    }

    static func make(jobID: UUID, records: [ReconstructionReplayRecord],
                     receipts: [ReconstructionModelReceipt]) throws -> Self {
        let accepted = Dictionary(uniqueKeysWithValues: receipts.filter {
            $0.jobID == jobID && $0.terminalState == .completed
        }.map { ($0.receiptID, $0) })
        var rounds: [Round] = []
        for record in records where record.identity.objectiveID == jobID {
            try record.validate()
            guard let observed = record.latestObservation,
                  let receipt = accepted[observed.currentRequestID] else { continue }
            guard receipt.taskID == record.identity.taskID, receipt.diagnostic == nil else {
                throw ReconstructionReplayError.invalidRecord
            }
            rounds.append(.init(logicalRoundIndex: observed.logicalRoundIndex,
                mode: observed.mode, originalRequestID: observed.originalRequestID))
        }
        let result = Self(schemaVersion: schemaVersion, jobID: jobID,
            rounds: rounds.sorted { $0.logicalRoundIndex < $1.logicalRoundIndex })
        try result.validate()
        return result
    }
}

extension ReconstructionDatabaseOwner {
    func inferenceHistory(workspaceID: UUID, jobID: UUID) throws -> ReconstructionInferenceHistory? {
        try withActiveDatabase { database in
            guard try database.reconstructionWorkspaceID(containingJobID: jobID) == workspaceID else {
                throw ReconstructionReplayError.invalidScope
            }
            return try database.ownerInferenceHistory(workspaceID: workspaceID, jobID: jobID)
        }
    }
}

extension WorkspaceDatabase {
    static let ownerInferenceHistoryTable = "owner_job_inference_history"

    private func ensureOwnerInferenceHistorySchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS owner_job_inference_history (
                workspace_uuid TEXT NOT NULL, job_id TEXT PRIMARY KEY NOT NULL,
                record_json BLOB NOT NULL, record_sha256 TEXT NOT NULL
            );
            """)
        let columns = try query("PRAGMA table_info(owner_job_inference_history);") { row in
            (String(cString: sqlite3_column_text(row, 1)), String(cString: sqlite3_column_text(row, 2)),
             sqlite3_column_int(row, 3), sqlite3_column_int(row, 5))
        }
        let expected: [(String, String, Int32, Int32)] = [
            ("workspace_uuid", "TEXT", 1, 0), ("job_id", "TEXT", 1, 1),
            ("record_json", "BLOB", 1, 0), ("record_sha256", "TEXT", 1, 0)]
        guard columns.count == expected.count, zip(columns, expected).allSatisfy({ observed, wanted in
            observed.0 == wanted.0 && observed.1 == wanted.1 && observed.2 == wanted.2 && observed.3 == wanted.3
        }) else { throw ReconstructionReplayError.invalidRecord }
    }

    func ownerInferenceHistory(workspaceID: UUID, jobID: UUID) throws -> ReconstructionInferenceHistory? {
        guard try tableNames().contains(Self.ownerInferenceHistoryTable) else { return nil }
        try ensureOwnerInferenceHistorySchema()
        let records = try query("""
            SELECT record_json, record_sha256 FROM owner_job_inference_history
            WHERE workspace_uuid = ? AND job_id = ?;
            """, bindings: [.text(workspaceID.uuidString), .text(jobID.uuidString)]) { row in
            let count = Int(sqlite3_column_bytes(row, 0))
            guard count > 0, count <= ReconstructionInferenceHistory.maximumBytes,
                  let raw = sqlite3_column_blob(row, 0), let digest = sqlite3_column_text(row, 1) else {
                throw ReconstructionReplayError.invalidRecord
            }
            let bytes = Data(bytes: raw, count: count)
            guard ReconstructionSourceInferenceContract.sha256(bytes) == String(cString: digest) else {
                throw ReconstructionReplayError.invalidRecord
            }
            let record = try JSONDecoder().decode(ReconstructionInferenceHistory.self, from: bytes)
            try record.validate()
            guard record.jobID == jobID, try ReconstructionCanonicalJSON.encode(record) == bytes else {
                throw ReconstructionReplayError.invalidRecord
            }
            return record
        }
        guard records.count <= 1 else { throw ReconstructionReplayError.invalidRecord }
        return records.first
    }

    /// Runs in the same Save transaction as journal deletion. A second Save preserves the first
    /// summary; pruned active records must not silently replace historical provenance with empty.
    func retainOwnerInferenceHistory(workspaceID: UUID, jobID: UUID,
                                     records: [ReconstructionReplayRecord],
                                     receipts: [ReconstructionModelReceipt]) throws {
        let records = records.filter { $0.identity.objectiveID == jobID }
        let prior = try ownerInferenceHistory(workspaceID: workspaceID, jobID: jobID)
        if records.isEmpty { return }
        let history = try ReconstructionInferenceHistory.make(jobID: jobID, records: records, receipts: receipts)
        if let prior {
            guard prior == history else { throw ReconstructionReplayError.conflictingRecord }
            return
        }
        let bytes = try ReconstructionCanonicalJSON.encode(history)
        guard bytes.count <= ReconstructionInferenceHistory.maximumBytes else { throw ReconstructionReplayError.journalFull }
        try ensureOwnerInferenceHistorySchema()
        try run("""
            INSERT INTO owner_job_inference_history (workspace_uuid, job_id, record_json, record_sha256)
            VALUES (?, ?, ?, ?);
            """, bindings: [.text(workspaceID.uuidString), .text(jobID.uuidString), .blob(bytes),
                .text(ReconstructionSourceInferenceContract.sha256(bytes))])
    }
}
