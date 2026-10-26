import Foundation

/// Durable wall-clock lifecycle of one job or task row (milliseconds since 1970, UTC). Written by
/// `WorkspaceDatabase` next to the canonical record (columns `created_at_ms`, `started_at_ms`,
/// `finished_at_ms` on `reconstruction_jobs` / `reconstruction_tasks`), never inside the
/// canonical record JSON, so record identities and checkpoint hashes stay clock-free. Rows written
/// before the columns existed, or first seen already terminal (an imported/replayed copy), load
/// as nil: the lifecycle was not observed.
struct ReconstructionLifecycleTimes: Hashable, Sendable, Encodable {
    var createdAtMilliseconds: UInt64?
    var startedAtMilliseconds: UInt64?
    var finishedAtMilliseconds: UInt64?

    var isEmpty: Bool { createdAtMilliseconds == nil && startedAtMilliseconds == nil && finishedAtMilliseconds == nil }

    /// finished - (started ?? created) when both ends were observed.
    var wallClockElapsedMilliseconds: UInt64? {
        guard let finished = finishedAtMilliseconds,
              let start = startedAtMilliseconds ?? createdAtMilliseconds, finished >= start else { return nil }
        return finished - start
    }
}

/// Every job/task lifecycle row of one workspace, keyed by job/task ID.
struct ReconstructionLifecycleTimestamps: Hashable, Sendable {
    var jobs: [UUID: ReconstructionLifecycleTimes] = [:]
    var tasks: [UUID: ReconstructionLifecycleTimes] = [:]
    static let empty = ReconstructionLifecycleTimestamps()
}

/// Read-only job status derived from one durable `ReconstructionWorkspaceState`: the job state,
/// its terminal reason, every failed task's concrete diagnostic, the decompiler backend of each
/// decompile/compare task (D13), and, for a completed source-profile job, the final synthesis
/// record. Pure: no model, no clock, no live session; the same state (and durable lifecycle rows)
/// always yields the same value, so the UI and MCP/scripting read identical facts after Save/reopen.
struct ReconstructionJobStatusSummary: Hashable, Encodable, Sendable {
    struct FailedTask: Hashable, Encodable, Sendable {
        let taskID: UUID
        let kind: String
        let diagnostic: String?
        /// Durable task lifecycle (nil for rows written before the timestamp columns).
        let lifecycle: ReconstructionLifecycleTimes?
    }

    /// Which clock `elapsedMilliseconds` came from.
    enum ElapsedSource: String, Hashable, Encodable, Sendable {
        /// finished - started (or created) from the durable job lifecycle columns.
        case wallClock = "wall-clock"
        /// Sum of broker-measured source phase times (older rows without lifecycle timestamps).
        case phaseSum = "phase-sum"
    }

    struct DecompileProvenance: Hashable, Encodable, Sendable {
        let taskID: UUID
        let kind: String
        let functionStartAddress: UInt64?
        let symbol: String?
        let backend: String
        let fallbackReason: String?
    }

    /// The minimal final synthesis of a completed source-profile job (decision: required).
    struct SourceSynthesis: Hashable, Encodable, Sendable {
        static let schemaVersion = 1
        let schemaVersion: Int
        let profileID: String
        let acceptedRevisionSHA256: String
        let acceptedRevisionEvidenceID: UUID
        let acceptedEvaluationEvidenceID: UUID
        let harnessPassed: Int
        let harnessTotal: Int
        let revisionCount: Int
        let evaluationCount: Int
        /// Backend of every decompile/compare task of the job (`native` or `macir` + reason).
        let decompileProvenance: [DecompileProvenance]
        /// Wall-clock job time from the durable lifecycle columns when they were observed;
        /// otherwise (older rows) the sum of the broker-measured source phase durations of every
        /// evaluation. `elapsedSource` names which one.
        let elapsedMilliseconds: UInt64
        let elapsedSource: ElapsedSource
        /// The phase sum, always reported so the two can be compared.
        let phaseElapsedMilliseconds: UInt64
    }

    let jobID: UUID
    let state: String
    let terminalReason: String?
    let failedTasks: [FailedTask]
    let decompileProvenance: [DecompileProvenance]
    let finalSynthesis: SourceSynthesis?
    /// Durable job lifecycle (created/started/finished, ms since 1970); nil for older rows.
    let lifecycle: ReconstructionLifecycleTimes?
    /// Wall-clock when the lifecycle has both ends; otherwise the synthesis phase sum; else nil.
    let elapsedMilliseconds: UInt64?
    let elapsedSource: ElapsedSource?

    static func make(jobID: UUID, state: ReconstructionWorkspaceState,
        lifecycle: ReconstructionLifecycleTimestamps = .empty) -> ReconstructionJobStatusSummary? {
        guard let job = state.jobs.first(where: { $0.jobID == jobID }) else { return nil }
        let tasks = state.tasks.filter { $0.identity.jobID == jobID }
            .sorted { $0.identity.taskID.uuidString.lowercased() < $1.identity.taskID.uuidString.lowercased() }
        let failed = tasks.filter { $0.state == .failed }.map {
            FailedTask(taskID: $0.identity.taskID, kind: $0.identity.kind.rawValue, diagnostic: $0.diagnostic?.text,
                lifecycle: lifecycle.tasks[$0.identity.taskID].flatMap { $0.isEmpty ? nil : $0 })
        }
        let provenance: [DecompileProvenance] = tasks.compactMap { task in
            guard let backend = task.decompileBackend else { return nil }
            var address: UInt64?, symbol: String?
            if case .function(let function)? = task.identity.subject {
                address = function.startAddress; symbol = function.symbolHint
            }
            return .init(taskID: task.identity.taskID, kind: task.identity.kind.rawValue,
                functionStartAddress: address, symbol: symbol,
                backend: backend.backend, fallbackReason: backend.fallbackReason)
        }.sorted {
            ($0.functionStartAddress ?? 0, $0.kind) < ($1.functionStartAddress ?? 0, $1.kind)
        }
        let jobLifecycle = lifecycle.jobs[jobID].flatMap { $0.isEmpty ? nil : $0 }
        let synthesis = job.state == .completed && ReconstructionSourceProfile.admits(job.sourceProfileID)
            ? sourceSynthesis(job: job, state: state, provenance: provenance, lifecycle: jobLifecycle) : nil
        let elapsed: (UInt64, ElapsedSource)? = jobLifecycle?.wallClockElapsedMilliseconds.map { ($0, .wallClock) }
            ?? synthesis.map { ($0.elapsedMilliseconds, $0.elapsedSource) }
        return .init(jobID: jobID, state: job.state.rawValue, terminalReason: job.terminalReason?.text,
            failedTasks: failed, decompileProvenance: provenance, finalSynthesis: synthesis,
            lifecycle: jobLifecycle, elapsedMilliseconds: elapsed?.0, elapsedSource: elapsed?.1)
    }

    private static func sourceSynthesis(job: ReconstructionJobRecord, state: ReconstructionWorkspaceState,
        provenance: [DecompileProvenance], lifecycle: ReconstructionLifecycleTimes?) -> SourceSynthesis? {
        let records = state.evidence.filter { $0.creatingJobID == job.jobID }
        let revisions = records.filter { $0.operationID == ReconstructionSourceRevisionEvidence.operationID }
            .compactMap { record in
                (try? JSONDecoder().decode(ReconstructionSourceRevision.self, from: record.payload)).map { (record, $0) }
            }
        let evaluations = records.filter { $0.operationID == ReconstructionSourceEvaluationEvidence.operationID }
            .compactMap { record in
                (try? ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: record.payload)).map { (record, $0) }
            }
        let accepted = evaluations.filter { $0.1.capturedOutcome.status == .accepted }
            .sorted { $0.1.checkpointRevision < $1.1.checkpointRevision }
        guard let (evaluationRecord, evaluation) = accepted.last,
              let (revisionRecord, revision) = revisions.first(where: { $0.1.revisionSHA256 == evaluation.revisionSHA256 }),
              evaluation.profileID == job.sourceProfileID, revision.profileID == evaluation.profileID
        else { return nil }
        let total = evaluation.capturedOutcome.observations.count
        let failedCases = Set(evaluation.capturedOutcome.mismatches.map(\.index)).count
        let phaseElapsed = evaluations.reduce(UInt64(0)) { sum, entry in
            entry.1.capturedOutcome.phases.reduce(sum) { $0 &+ $1.elapsedMilliseconds }
        }
        let wallClock = lifecycle?.wallClockElapsedMilliseconds
        return .init(schemaVersion: SourceSynthesis.schemaVersion,
            profileID: evaluation.profileID,
            acceptedRevisionSHA256: revision.revisionSHA256,
            acceptedRevisionEvidenceID: revisionRecord.evidenceID,
            acceptedEvaluationEvidenceID: evaluationRecord.evidenceID,
            harnessPassed: max(0, total - failedCases), harnessTotal: total,
            revisionCount: revisions.count, evaluationCount: evaluations.count,
            decompileProvenance: provenance, elapsedMilliseconds: wallClock ?? phaseElapsed,
            elapsedSource: wallClock == nil ? .phaseSum : .wallClock, phaseElapsedMilliseconds: phaseElapsed)
    }
}
