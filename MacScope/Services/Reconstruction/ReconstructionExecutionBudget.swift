import Foundation
import SQLite3

struct ReconstructionExecutionBudgetRecord: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let jobID: UUID
    let allowanceSeconds: Double
    let chargedSeconds: Double
    let activationID: UUID?
    let processSessionID: UUID?
    let activationStartedAt: Date?
    /// A killed process has no trustworthy end timestamp. Charge the unclosed interval through
    /// resume conservatively, including downtime, instead of silently resetting the job budget.
    let recoveredUnclosedIntervals: Int

    func validate() throws {
        guard schemaVersion == Self.schemaVersion, allowanceSeconds.isFinite,
              (1...86_400).contains(allowanceSeconds), chargedSeconds.isFinite,
              (0...allowanceSeconds).contains(chargedSeconds), recoveredUnclosedIntervals >= 0,
              (activationID == nil) == (activationStartedAt == nil),
              (activationID == nil) == (processSessionID == nil),
              activationStartedAt?.timeIntervalSince1970.isFinite != false else {
            throw ReconstructionReplayError.invalidRecord
        }
    }

    func charged(through now: Date) -> Double {
        min(allowanceSeconds, chargedSeconds + (activationStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0))
    }
}

extension ReconstructionDatabaseOwner {
    private static let executionBudgetProcessSessionID = UUID()

    func beginExecutionBudget(workspaceID: UUID, jobID: UUID, activationID: UUID,
                              policy: ReconstructionBudgetPolicy, now: Date = Date()) throws -> Double {
        guard policy.isValid else { throw ReconstructionReplayError.invalidScope }
        return try withActiveDatabase { database in
            guard try database.reconstructionWorkspaceID(containingJobID: jobID) == workspaceID else {
                throw ReconstructionReplayError.invalidScope
            }
            let prior = try database.ownerExecutionBudget(jobID: jobID)
            guard prior?.processSessionID != Self.executionBudgetProcessSessionID else {
                throw ReconstructionReplayError.requestInFlight
            }
            // Raising the explicit policy can extend a previously exhausted allowance. Merely
            // pressing Resume or restarting the same build never replenishes spent time.
            let allowance = max(prior?.allowanceSeconds ?? policy.jobSeconds, policy.jobSeconds)
            let charged = prior?.charged(through: now) ?? 0
            let next = ReconstructionExecutionBudgetRecord(schemaVersion: 1, jobID: jobID,
                allowanceSeconds: allowance, chargedSeconds: charged, activationID: activationID,
                processSessionID: Self.executionBudgetProcessSessionID, activationStartedAt: now,
                recoveredUnclosedIntervals: (prior?.recoveredUnclosedIntervals ?? 0)
                    + (prior?.activationID == nil ? 0 : 1))
            try database.publishOwnerExecutionBudget(workspaceID: workspaceID, record: next)
            return max(0, allowance - charged)
        }
    }

    func finishExecutionBudget(workspaceID: UUID, jobID: UUID, activationID: UUID,
                               now: Date = Date()) throws {
        try withActiveDatabase { database in
            guard let prior = try database.ownerExecutionBudget(jobID: jobID),
                  prior.activationID == activationID,
                  prior.processSessionID == Self.executionBudgetProcessSessionID else {
                throw ReconstructionReplayError.staleAdmission
            }
            let next = ReconstructionExecutionBudgetRecord(schemaVersion: 1, jobID: jobID,
                allowanceSeconds: prior.allowanceSeconds, chargedSeconds: prior.charged(through: now),
                activationID: nil, processSessionID: nil, activationStartedAt: nil,
                recoveredUnclosedIntervals: prior.recoveredUnclosedIntervals)
            try database.publishOwnerExecutionBudget(workspaceID: workspaceID, record: next)
        }
    }
}

extension WorkspaceDatabase {
    static let ownerExecutionBudgetTable = "owner_job_execution_budget"

    private func ensureOwnerExecutionBudgetSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS owner_job_execution_budget (
                workspace_uuid TEXT NOT NULL, job_id TEXT PRIMARY KEY NOT NULL, record_json BLOB NOT NULL
            );
            """)
        let columns = try query("PRAGMA table_info(owner_job_execution_budget);") { row in
            (String(cString: sqlite3_column_text(row, 1)), String(cString: sqlite3_column_text(row, 2)),
             sqlite3_column_int(row, 3), sqlite3_column_int(row, 5))
        }
        let expected: [(String, String, Int32, Int32)] = [
            ("workspace_uuid", "TEXT", 1, 0), ("job_id", "TEXT", 1, 1), ("record_json", "BLOB", 1, 0)]
        guard columns.count == expected.count, zip(columns, expected).allSatisfy({ observed, wanted in
            observed.0 == wanted.0 && observed.1 == wanted.1 && observed.2 == wanted.2 && observed.3 == wanted.3
        }) else { throw ReconstructionReplayError.invalidRecord }
    }

    func ownerExecutionBudget(jobID: UUID) throws -> ReconstructionExecutionBudgetRecord? {
        guard try tableNames().contains(Self.ownerExecutionBudgetTable) else { return nil }
        try ensureOwnerExecutionBudgetSchema()
        let records = try query("SELECT record_json FROM owner_job_execution_budget WHERE job_id = ?;",
            bindings: [.text(jobID.uuidString)], map: Self.decodeOwnerExecutionBudget)
        guard records.count <= 1, records.first?.jobID == jobID || records.isEmpty else {
            throw ReconstructionReplayError.invalidRecord
        }
        return records.first
    }

    private static func decodeOwnerExecutionBudget(_ row: OpaquePointer) throws -> ReconstructionExecutionBudgetRecord {
        let count = Int(sqlite3_column_bytes(row, 0))
        guard count > 0, count <= 8_192, let raw = sqlite3_column_blob(row, 0) else {
            throw ReconstructionReplayError.invalidRecord
        }
        let bytes = Data(bytes: raw, count: count)
        let record = try JSONDecoder().decode(ReconstructionExecutionBudgetRecord.self, from: bytes)
        try record.validate()
        guard try ReconstructionCanonicalJSON.encode(record) == bytes else { throw ReconstructionReplayError.invalidRecord }
        return record
    }

    func publishOwnerExecutionBudget(workspaceID: UUID, record: ReconstructionExecutionBudgetRecord) throws {
        try record.validate()
        try ensureOwnerExecutionBudgetSchema()
        let synchronous = try query("PRAGMA synchronous;") { sqlite3_column_int($0, 0) }.first ?? 2
        if synchronous < 2 { try execute("PRAGMA synchronous=FULL;") }
        defer { if synchronous < 2 { try? execute("PRAGMA synchronous=\(synchronous);") } }
        try withOwnerReplayTransaction { try writeOwnerExecutionBudget(workspaceID: workspaceID, record: record) }
    }

    private func writeOwnerExecutionBudget(workspaceID: UUID, record: ReconstructionExecutionBudgetRecord) throws {
        let bytes = try ReconstructionCanonicalJSON.encode(record)
        guard bytes.count <= 8_192 else { throw ReconstructionReplayError.journalFull }
        try admitOwnerReplayStorage(workspaceID: workspaceID, newBytes: bytes.count, replacingBudgetJobID: record.jobID)
        try run("""
            INSERT INTO owner_job_execution_budget (workspace_uuid, job_id, record_json) VALUES (?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET record_json=excluded.record_json;
            """, bindings: [.text(workspaceID.uuidString), .text(record.jobID.uuidString),
                .blob(bytes)])
    }

    func ownerExecutionBudgetEnvelopes(workspaceID: UUID) throws -> [ReconstructionWorkspaceReplayRecord] {
        guard try tableNames().contains(Self.ownerExecutionBudgetTable) else { return [] }
        try ensureOwnerExecutionBudgetSchema()
        return try query("SELECT record_json FROM owner_job_execution_budget WHERE workspace_uuid = ? ORDER BY job_id;",
            bindings: [.text(workspaceID.uuidString)], map: Self.decodeOwnerExecutionBudget).map {
                .init(jobID: $0.jobID, payload: try ReconstructionCanonicalJSON.encode($0), kind: .executionBudget)
            }
    }

    /// Already inside an import transaction. Active budget markers travel with Save; a new host
    /// conservatively settles an unclosed interval at its next explicit activation.
    func restoreOwnerExecutionBudgets(workspaceID: UUID, state: ReconstructionWorkspaceState) throws {
        let envelopes = (state.replayRecords ?? []).filter { $0.kind == .executionBudget }
        guard !envelopes.isEmpty else { return }
        try ensureOwnerExecutionBudgetSchema()
        var jobs: Set<UUID> = []
        for envelope in envelopes {
            let record = try JSONDecoder().decode(ReconstructionExecutionBudgetRecord.self, from: envelope.payload)
            try record.validate()
            guard jobs.insert(record.jobID).inserted, record.jobID == envelope.jobID,
                  state.jobs.contains(where: { $0.jobID == record.jobID }),
                  try ReconstructionCanonicalJSON.encode(record) == envelope.payload else {
                throw ReconstructionReplayError.invalidRecord
            }
            if let prior = try ownerExecutionBudget(jobID: record.jobID), prior != record {
                throw ReconstructionReplayError.conflictingRecord
            }
            try writeOwnerExecutionBudget(workspaceID: workspaceID, record: record)
        }
    }

    func pruneTerminalOwnerExecutionBudgets(workspaceID: UUID, state: ReconstructionWorkspaceState) throws {
        guard try tableNames().contains(Self.ownerExecutionBudgetTable) else { return }
        try ensureOwnerExecutionBudgetSchema()
        for job in state.jobs where job.state.isTerminal {
            try run("DELETE FROM owner_job_execution_budget WHERE workspace_uuid = ? AND job_id = ?;",
                bindings: [.text(workspaceID.uuidString), .text(job.jobID.uuidString)])
        }
    }
}
