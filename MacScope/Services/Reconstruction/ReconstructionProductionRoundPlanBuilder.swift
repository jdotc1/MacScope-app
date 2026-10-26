import CryptoKit
import Foundation

enum ReconstructionProductionTaskContract {
    static let evidenceQuery = ReconstructionOperationID.evidenceQuery.rawValue
    static let modelRound = "reconstruction.\(ReconstructionTaskKind.modelRound.rawValue).v1"
    static let finalSynthesis = "reconstruction.finalSynthesis.v1"
    static let sourceRevision = ReconstructionSourceRevisionEvidence.taskContract
    static let checkpoint = "reconstruction.\(ReconstructionTaskKind.checkpoint.rawValue).v1"
}

struct ReconstructionProductionRegularModelFrontier: Sendable {
    let retrieve: ReconstructionTaskRecord
    let model: ReconstructionTaskRecord
    let checkpoint: ReconstructionTaskRecord
}

struct ReconstructionProductionFinalSynthesisFrontier: Sendable {
    let model: ReconstructionTaskRecord
    let checkpoint: ReconstructionTaskRecord
}

struct ReconstructionProductionSourceExecutionFrontier: Sendable {
    let execution: ReconstructionTaskRecord
    let checkpoint: ReconstructionTaskRecord
}

struct ReconstructionProductionSourceRevisionFrontier: Sendable {
    let model: ReconstructionTaskRecord
    let checkpoint: ReconstructionTaskRecord
}

/// The first committed checkpoint revision at which a task entered `.completed`.
///
/// This is captured from the complete durable checkpoint chain in the same database-owner turn as
/// the round basis. Keeping the normalized authority here prevents a later cumulative checkpoint
/// from moving an old receipt/evidence result forward and incorrectly resetting `maxRounds`.
struct ReconstructionProductionTaskCompletionAuthority: Codable, Hashable, Sendable {
    let taskID: UUID
    let firstCompletedAtRevision: UInt64
}

/// Durable authority for the job budget named `maxRounds`. The budget counts completed ordinary
/// model rounds without accepted evidence, including an ordinary round that proceeds to final
/// synthesis or a typed pause. Failed/cancelled attempts and the distinct final-synthesis operation
/// do not count. Checkpoint revisions also cover deterministic batches, activation, recovery, and
/// control, so they are deliberately not a model-round counter.
enum ReconstructionProductionModelRoundBudgetAuthority {
    private struct CompletedOrdinaryRound {
        let checkpointRevision: UInt64
        let acceptedEvidence: Bool
    }

    static func consecutiveRoundsWithoutEvidence(
        jobID: UUID,
        tasks: [ReconstructionTaskRecord],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        taskCompletionAuthorities: [ReconstructionProductionTaskCompletionAuthority]
    ) throws -> Int {
        var firstCompletionRevisionByTaskID: [UUID: UInt64] = [:]
        for authority in taskCompletionAuthorities {
            guard firstCompletionRevisionByTaskID.updateValue(
                authority.firstCompletedAtRevision,
                forKey: authority.taskID
            ) == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        let frontiers = try ReconstructionProductionRoundPlanBuilder
            .regularModelFrontiers(in: tasks)
        guard !frontiers.isEmpty else {
            guard !modelReceipts.contains(where: { $0.jobID == jobID }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return 0
        }
        let checkpointTaskIDs = Set(frontiers.map(\.checkpoint.identity.taskID))
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.identity.taskID, $0) })
        var regularSuccessorsByCheckpointTaskID:
            [UUID: [ReconstructionProductionRegularModelFrontier]] = [:]
        var initialFrontiers: [ReconstructionProductionRegularModelFrontier] = []
        for frontier in frontiers {
            let dependencies = frontier.retrieve.identity.dependencyTaskIDs
            guard !dependencies.isEmpty else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let checkpointDependencies = dependencies.filter {
                checkpointTaskIDs.contains($0)
            }
            if checkpointDependencies.isEmpty {
                // The initial regular frontier depends on the deterministic batch leaves, not
                // on a prior checkpoint, and therefore is not a successor round.
                initialFrontiers.append(frontier)
                continue
            }
            guard (1...2).contains(dependencies.count),
                  checkpointDependencies.count == 1,
                  let predecessorID = checkpointDependencies.first else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            if dependencies.count == 2 {
                guard let refreshID = dependencies.first(where: { $0 != predecessorID }),
                      let refresh = tasksByID[refreshID],
                      refresh.identity.kind == .decompileMacScope,
                      refresh.identity.dependencyTaskIDs.count == 2,
                      refresh.identity.dependencyTaskIDs.contains(predecessorID),
                      refresh.identity.dependencyTaskIDs.compactMap({ tasksByID[$0] })
                        .filter({ $0.identity.kind == .enumerateFunctions && $0.state == .completed })
                        .count == 1 else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            }
            regularSuccessorsByCheckpointTaskID[predecessorID, default: []]
                .append(frontier)
        }
        guard initialFrontiers.count == 1, let initialFrontier = initialFrontiers.first else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        var orderedFrontiers: [ReconstructionProductionRegularModelFrontier] = []
        var visitedModelTaskIDs: Set<UUID> = []
        var current: ReconstructionProductionRegularModelFrontier? = initialFrontier
        while let frontier = current {
            guard visitedModelTaskIDs.insert(frontier.model.identity.taskID).inserted else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            orderedFrontiers.append(frontier)
            let successors = regularSuccessorsByCheckpointTaskID[
                frontier.checkpoint.identity.taskID
            ] ?? []
            guard successors.count <= 1 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            current = successors.first
        }
        guard orderedFrontiers.count == frontiers.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        var toolReceiptsByID: [UUID: ReconstructionToolReceipt] = [:]
        for receipt in toolReceipts where receipt.jobID == jobID {
            guard toolReceiptsByID.updateValue(receipt, forKey: receipt.receiptID) == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        var modelReceiptsByTaskID: [UUID: [ReconstructionModelReceipt]] = [:]
        var modelReceiptIDs: Set<UUID> = []
        for receipt in modelReceipts where receipt.jobID == jobID {
            guard modelReceiptIDs.insert(receipt.receiptID).inserted else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            // Failed provider attempts remain audit records but do not become a second
            // successful completion authority when the same durable frontier is retried.
            if receipt.terminalState == .completed {
                modelReceiptsByTaskID[receipt.taskID, default: []].append(receipt)
            }
        }

        var completed: [CompletedOrdinaryRound] = []
        for frontier in orderedFrontiers {
            let successors = regularSuccessorsByCheckpointTaskID[
                frontier.checkpoint.identity.taskID
            ] ?? []
            guard successors.count <= 1 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            guard frontier.model.state == .completed else {
                guard successors.isEmpty else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                // Pending/running frontiers and failed/cancelled attempts are not completed
                // ordinary rounds and therefore do not consume this budget.
                continue
            }
            // Reconstruct from the durable task graph, never from whichever receipts happened to
            // survive import. Every completed ordinary model task must have completed retrieval,
            // settled its checkpoint, and authored exactly one ordinary model receipt.
            guard frontier.retrieve.state == .completed,
                  frontier.checkpoint.state == .completed
                    || frontier.checkpoint.state == .blocked,
                  successors.isEmpty || frontier.checkpoint.state == .completed,
                  let receipts = modelReceiptsByTaskID[frontier.model.identity.taskID],
                  receipts.count == 1,
                  let receipt = receipts.first,
                  receipt.terminalState == .completed,
                  receipt.finalResultCommitment == nil,
                  receipt.producer.operationIdentity
                    == frontier.model.identity.operationContractIdentity,
                  try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(receipt.producer)
                    == receipt.producer.canonicalSHA256,
                  try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt),
                  firstCompletionRevisionByTaskID[frontier.model.identity.taskID]
                    == receipt.checkpointRevision,
                  firstCompletionRevisionByTaskID[frontier.retrieve.identity.taskID]
                    == receipt.checkpointRevision,
                  Set(receipt.selectedHandleIDs).count == receipt.selectedHandleIDs.count else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }

            var acceptedEvidence = false
            for handleID in receipt.selectedHandleIDs {
                guard let receiptID = UUID(uuidString: handleID),
                      handleID == receiptID.uuidString.lowercased(),
                      let toolReceipt = toolReceiptsByID[receiptID],
                      toolReceipt.jobID == jobID,
                      toolReceipt.taskID == frontier.retrieve.identity.taskID,
                      toolReceipt.checkpointRevision == receipt.checkpointRevision,
                      (toolReceipt.producer.operationIdentity
                        == frontier.retrieve.identity.operationContractIdentity
                        || (toolReceipt.producer.operationIdentity
                            == "reconstruction.analysis.macscope.refresh"
                            && toolReceipt.outputEvidenceIDs.isEmpty
                            && toolReceipt.terminalState == .completed)),
                      try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(
                        toolReceipt.producer
                      ) == toolReceipt.producer.canonicalSHA256,
                      try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(
                        toolReceipt
                      ) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                if !toolReceipt.outputEvidenceIDs.isEmpty {
                    guard toolReceipt.terminalState == .completed
                            || toolReceipt.terminalState == .truncated else {
                        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                    }
                    acceptedEvidence = true
                }
            }
            // A demand acknowledgement is control evidence. Only the completed deterministic
            // analysis receipt between the two model rounds can reset the evidence streak.
            for task in tasks where task.identity.kind == .decompileMacScope
                && frontier.retrieve.identity.dependencyTaskIDs.contains(task.identity.taskID)
                && task.identity.dependencyTaskIDs.count == 2 {
                if task.state == .completed,
                   let completedRevision = firstCompletionRevisionByTaskID[task.identity.taskID],
                   let precedingRevision = completed.last?.checkpointRevision,
                   completedRevision > precedingRevision,
                   completedRevision < receipt.checkpointRevision,
                   toolReceipts.contains(where: { tool in
                       tool.taskID == task.identity.taskID && tool.jobID == jobID
                         && tool.checkpointRevision == completedRevision
                         && tool.terminalState == .completed && !tool.outputEvidenceIDs.isEmpty
                         && tool.producer.operationIdentity == task.identity.operationContractIdentity
                         && (try? ReconstructionEvidenceIntegrity.canonicalProducerSHA256(tool.producer))
                            == tool.producer.canonicalSHA256
                         && (try? ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(tool)) == true
                   }) {
                    acceptedEvidence = true
                }
            }
            completed.append(.init(
                checkpointRevision: receipt.checkpointRevision,
                acceptedEvidence: acceptedEvidence
            ))
        }
        guard Set(completed.map(\.checkpointRevision)).count == completed.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        if let pending = orderedFrontiers.last, pending.model.state != .completed,
           let priorRevision = completed.last?.checkpointRevision {
            for task in tasks where task.identity.kind == .decompileMacScope
                && pending.retrieve.identity.dependencyTaskIDs.contains(task.identity.taskID)
                && task.identity.dependencyTaskIDs.count == 2 && task.state == .completed {
                if let revision = firstCompletionRevisionByTaskID[task.identity.taskID],
                   revision > priorRevision,
                   toolReceipts.contains(where: { tool in
                       tool.taskID == task.identity.taskID && tool.jobID == jobID
                        && tool.checkpointRevision == revision && tool.terminalState == .completed
                        && !tool.outputEvidenceIDs.isEmpty
                        && tool.producer.operationIdentity == task.identity.operationContractIdentity
                        && (try? ReconstructionEvidenceIntegrity.canonicalProducerSHA256(tool.producer))
                            == tool.producer.canonicalSHA256
                        && (try? ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(tool)) == true
                   }) {
                    return 0
                }
            }
        }

        var count = 0
        // The committed task DAG, not a mutable/imported receipt revision, defines round order.
        // Receipt revisions remain exact bindings (and must be unique), but cannot reorder the
        // evidence/no-evidence streak reconstructed from the unique successor chain.
        for round in completed.reversed() {
            if round.acceptedEvidence { break }
            let (next, overflow) = count.addingReportingOverflow(1)
            guard !overflow else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            count = next
        }
        return count
    }

    static func taskCompletionAuthorities(
        jobID: UUID,
        checkpoints: [ReconstructionCheckpoint]
    ) throws -> [ReconstructionProductionTaskCompletionAuthority] {
        let jobCheckpoints = checkpoints.filter { $0.jobID == jobID }
        guard Set(jobCheckpoints.map(\.checkpointID)).count == jobCheckpoints.count,
              Set(jobCheckpoints.map(\.revision)).count == jobCheckpoints.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        var firstRevisionByTaskID: [UUID: UInt64] = [:]
        for checkpoint in jobCheckpoints {
            for taskID in checkpoint.completedTaskIDs {
                if let existing = firstRevisionByTaskID[taskID] {
                    firstRevisionByTaskID[taskID] = min(existing, checkpoint.revision)
                } else {
                    firstRevisionByTaskID[taskID] = checkpoint.revision
                }
            }
        }
        return firstRevisionByTaskID.map {
            ReconstructionProductionTaskCompletionAuthority(
                taskID: $0.key,
                firstCompletedAtRevision: $0.value
            )
        }.sorted { lhs, rhs in
            lhs.taskID.uuidString.lowercased() < rhs.taskID.uuidString.lowercased()
        }
    }

    static func planSchedulesAnotherRegularRound(
        _ plan: ReconstructionJobCommitPlan,
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws -> Bool {
        guard let mutation = plan.mutation else { return false }
        switch plan.disposition {
        case .continue, .advancePhase: break
        case .completed, .paused, .cancelled, .failed: return false
        }
        let newFrontiers = try ReconstructionProductionRoundPlanBuilder
            .regularModelFrontiers(in: mutation.newTasks)
        guard newFrontiers.count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        guard newFrontiers.count == 1 else { return false }

        var tasksByID: [UUID: ReconstructionTaskRecord] = [:]
        for task in snapshot.tasks {
            guard tasksByID.updateValue(task, forKey: task.identity.taskID) == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        let completedRegularReceipts = mutation.modelReceipts.filter { receipt in
            guard receipt.jobID == snapshot.jobID,
                  receipt.terminalState == .completed,
                  receipt.finalResultCommitment == nil,
                  let task = tasksByID[receipt.taskID] else {
                return false
            }
            return task.identity.kind == .modelRound
                && task.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.modelRound
                && mutation.taskTransitions.contains(where: {
                    $0.taskID == task.identity.taskID
                        && $0.successorState == .completed
                })
        }
        guard completedRegularReceipts.count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return completedRegularReceipts.count == 1
    }

    static func hasPendingRegularRound(
        _ tasks: [ReconstructionTaskRecord]
    ) throws -> Bool {
        try ReconstructionProductionRoundPlanBuilder.pendingRegularModelFrontier(
            in: tasks
        ) != nil
    }
}

/// Receipt-bearing model/control plans remain owned by the canonical receipt authority. This
/// seam prevents the dynamic DAG builder from duplicating receipt preimages or producer identity.
protocol ReconstructionProductionReceiptPlanAuthoring: Sendable {
    func makeBatchCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan
    ) async throws -> ReconstructionJobCommitPlan
    func makeModelCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan
    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan
    func makeSourceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan
    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan
    func makeRecoveryPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan
    func makeControlPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan
}

extension ReconstructionProductionReceiptPlanAuthoring {
    /// Legacy receipt authors cannot authorize a source result through ordinary-round handling.
    func makeSourceCommitPlan(cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis, basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease, requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
}

actor ReconstructionProductionRoundPlanBuilder: ReconstructionProductionRoundPlanBuilding {
    private static let taskIdentityDomain = "MacScope.ReconstructionDynamicTask.v1"
    private static let checkpointIdentityDomain = "MacScope.ReconstructionCheckpoint.v1"

    private struct EncodedTransition: Encodable {
        let taskID: UUID
        let expectedState: ReconstructionTaskState
        let successorState: ReconstructionTaskState
        let diagnostic: ReconstructionDiagnostic?

        init(_ transition: ReconstructionTaskTransition) {
            taskID = transition.taskID
            expectedState = transition.expectedState
            successorState = transition.successorState
            diagnostic = transition.diagnostic
        }
    }

    private let basisRegistry: ReconstructionProductionRoundBasisRegistry
    private let receiptAuthor: any ReconstructionProductionReceiptPlanAuthoring

    init(
        basisRegistry: ReconstructionProductionRoundBasisRegistry,
        receiptAuthor: any ReconstructionProductionReceiptPlanAuthoring
    ) {
        self.basisRegistry = basisRegistry
        self.receiptAuthor = receiptAuthor
    }

    /// Only pure forward admissions occur here. Later-phase restored cuts are never rewound to
    /// match recovered pending batch leaves; their existing durable admission remains authority.
    static func preExecutionPhase(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws -> ReconstructionJobState? {
        let batch = snapshot.tasks.filter { isBatchTask($0.identity.kind) }
        guard !batch.isEmpty else { return nil }
        switch snapshot.currentDurableJobState {
        case .created:
            return .ingesting
        case .ingesting:
            let ingest = batch.filter { $0.identity.kind == .ingest }
            return !ingest.isEmpty && ingest.allSatisfy({ $0.state == .completed })
                ? .indexing : nil
        case .indexing:
            return batch.allSatisfy({ $0.state == .completed }) ? .retrieving : nil
        case .retrieving:
            return try authorizedRegularModelFrontier(in: snapshot.tasks) != nil
                || authorizedSourceRevisionFrontier(in: snapshot.tasks) != nil
                ? .awaitingModel : nil
        case .awaitingModel:
            // A running source task still needs its dedicated inference request. Its
            // completed predecessor is not evidence that this request has executed.
            if try authorizedSourceRevisionFrontier(in: snapshot.tasks) != nil { return nil }
            return try authorizedRegularModelFrontier(in: snapshot.tasks) != nil
                || hasCommittedRegularSuccessor(snapshot)
                ? .executingReads : nil
        case .executingReads:
            // Recover older source cuts that ordinary normalization advanced prematurely.
            if try authorizedSourceRevisionFrontier(in: snapshot.tasks) != nil { return nil }
            // Older same-state response commits may already have accepted the ordinary round
            // and created its successor. Normalize forward; never replay that completed request.
            return try hasCommittedRegularSuccessor(snapshot) ? .acceptingEvidence : nil
        case .acceptingEvidence, .checkpointing:
            guard try hasCommittedRegularSuccessor(snapshot) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return snapshot.currentDurableJobState == .acceptingEvidence
                ? .checkpointing : .retrieving
        case .paused, .completed, .cancelled, .failed:
            return nil
        }
    }

    private static func hasCommittedRegularSuccessor(
        _ snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws -> Bool {
        let regular = try pendingRegularModelFrontier(in: snapshot.tasks)
        let final = try pendingFinalSynthesisFrontier(in: snapshot.tasks)
            ?? authorizedFinalSynthesisFrontier(in: snapshot.tasks)
        let source = try pendingSourceRevisionFrontier(in: snapshot.tasks)
            ?? authorizedSourceRevisionFrontier(in: snapshot.tasks)
        let executions = try sourceExecutionFrontiers(in: snapshot.tasks)
        let pendingExecution = executions.first { $0.execution.state == .pending || $0.execution.state == .running }
        let dependencies = regular?.retrieve.identity.dependencyTaskIDs
            ?? final?.model.identity.dependencyTaskIDs ?? source?.model.identity.dependencyTaskIDs
            ?? pendingExecution?.execution.identity.dependencyTaskIDs ?? []
        let checkpointIDs = Set(snapshot.tasks.filter { $0.identity.kind == .checkpoint }
            .map(\.identity.taskID))
        guard let predecessor = dependencies.first(where: { checkpointIDs.contains($0) }) else {
            return false
        }
        let finals = try finalSynthesisFrontiers(in: snapshot.tasks)
        if source != nil, finals.contains(where: {
            $0.checkpoint.identity.taskID == predecessor && $0.model.state == .completed
                && $0.checkpoint.state == .completed
                && snapshot.terminalReceiptStatesByTaskID[$0.model.identity.taskID] == .completed
        }) { return true }
        let sourceFrontiers = try sourceRevisionFrontiers(in: snapshot.tasks)
        if sourceFrontiers.contains(where: {
            $0.checkpoint.identity.taskID == predecessor && $0.model.state == .completed
                && $0.checkpoint.state == .completed
                && snapshot.terminalReceiptStatesByTaskID[$0.model.identity.taskID] == .completed
        }) { return true }
        if executions.contains(where: {
            $0.checkpoint.identity.taskID == predecessor && $0.execution.state == .completed
                && $0.checkpoint.state == .completed
                && snapshot.terminalReceiptStatesByTaskID[$0.execution.identity.taskID] == .completed
        }) { return true }
        let frontiers = try regularModelFrontiers(in: snapshot.tasks)
        return frontiers.contains {
            $0.checkpoint.identity.taskID == predecessor
                && $0.retrieve.state == .completed && $0.model.state == .completed
                && $0.checkpoint.state == .completed
                && snapshot.terminalReceiptStatesByTaskID[$0.model.identity.taskID] == .completed
        }
    }

    private static func batchDisposition(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        successorTasks: [ReconstructionTaskRecord]
    ) -> ReconstructionJobCoordinatorDisposition {
        if snapshot.currentDurableJobState == .ingesting {
            let ingest = successorTasks.filter { $0.identity.kind == .ingest }
            if !ingest.isEmpty && ingest.allSatisfy({ $0.state == .completed }) {
                return .advancePhase(.indexing)
            }
        } else if snapshot.currentDurableJobState == .indexing,
                  successorTasks.filter({ isBatchTask($0.identity.kind) })
                    .allSatisfy({ $0.state == .completed }) {
            return .advancePhase(.retrieving)
        }
        return .continue
    }

    /// Explicit phase plans must carry the right real frontier, not merely a legal enum edge.
    /// Receipt/evidence-bearing phase changes stay inside the original atomic commit.
    static func validatePhaseAuthority(
        _ target: ReconstructionJobState,
        mutation: ReconstructionCheckpointMutation,
        snapshot: ReconstructionJobOrchestrationSnapshot
    ) throws {
        guard snapshot.currentDurableJobState != .paused,
              mutation.finalResults.isEmpty,
              mutation.successorPauseContext == nil,
              mutation.successorCheckpoint.terminalReason == nil else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let transitions = mutation.taskTransitions
        guard Set(snapshot.tasks.map(\.identity.taskID)).count == snapshot.tasks.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let oldTasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map {
            ($0.identity.taskID, $0)
        })
        guard Set(transitions.map(\.taskID)).count == transitions.count,
              transitions.allSatisfy({ oldTasks[$0.taskID]?.state == $0.expectedState }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let successorTasks = applying(transitions, to: snapshot.tasks) + mutation.newTasks
        try validateDynamicTaskGraph(
            successorTasks, jobID: snapshot.jobID, maximumTasks: max(1, successorTasks.count)
        )
        let phaseOnly = transitions.isEmpty && mutation.newTasks.isEmpty
            && mutation.evidence.isEmpty && mutation.evidenceRelations.isEmpty
            && mutation.evidenceGaps.isEmpty && mutation.toolReceipts.isEmpty
            && mutation.modelReceipts.isEmpty
        if phaseOnly, try preExecutionPhase(from: snapshot) == target { return }
        switch (snapshot.currentDurableJobState, target) {
        case (.ingesting, .indexing), (.indexing, .retrieving):
            guard batchDisposition(from: snapshot, successorTasks: successorTasks)
                    == .advancePhase(target),
                  !transitions.isEmpty, mutation.modelReceipts.isEmpty,
                  transitions.allSatisfy({ transition in
                      guard let task = oldTasks[transition.taskID] else { return false }
                      return isBatchTask(task.identity.kind)
                          && (snapshot.currentDurableJobState != .ingesting
                              || task.identity.kind == .ingest)
                          && transition.successorState == .completed
                  }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        case (.retrieving, .awaitingModel):
            if let frontier = try pendingSourceRevisionFrontier(in: snapshot.tasks) {
                guard try authorizedSourceRevisionFrontier(in: successorTasks) != nil,
                      transitions.count == 1, transitions.first?.taskID == frontier.model.identity.taskID,
                      transitions.first?.expectedState == .pending,
                      transitions.first?.successorState == .running,
                      mutation.newTasks.isEmpty, mutation.evidence.isEmpty,
                      mutation.evidenceRelations.isEmpty, mutation.evidenceGaps.isEmpty,
                      mutation.toolReceipts.isEmpty, mutation.modelReceipts.isEmpty else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                return
            }
            guard let frontier = try pendingRegularModelFrontier(in: snapshot.tasks),
                  try authorizedRegularModelFrontier(in: successorTasks) != nil,
                  Set(transitions.map(\.taskID)) == [
                    frontier.retrieve.identity.taskID, frontier.model.identity.taskID,
                  ],
                  transitions.allSatisfy({
                      $0.expectedState == .pending && $0.successorState == .running
                  }),
                  mutation.newTasks.isEmpty, mutation.evidence.isEmpty,
                  mutation.evidenceRelations.isEmpty, mutation.evidenceGaps.isEmpty,
                  mutation.toolReceipts.isEmpty, mutation.modelReceipts.isEmpty else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        case (.executingReads, .acceptingEvidence):
            guard let frontier = try authorizedRegularModelFrontier(in: snapshot.tasks),
                  Set(transitions.map(\.taskID)) == [
                    frontier.retrieve.identity.taskID, frontier.model.identity.taskID,
                    frontier.checkpoint.identity.taskID,
                  ],
                  transitions.allSatisfy({ $0.successorState == .completed }),
                  mutation.modelReceipts.count == 1,
                  mutation.modelReceipts.first?.taskID == frontier.model.identity.taskID,
                  mutation.modelReceipts.first?.terminalState == .completed,
                  mutation.modelReceipts.first?.finalResultCommitment == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        default:
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    func makePreInferenceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut
    ) async throws -> ReconstructionJobCommitPlan? {
        let roundID = cut.prepared.roundID
        let basis = try await basisRegistry.basis(roundID: roundID, prepared: cut.prepared)
        do {
            try Self.validate(cut: cut, basis: basis)
            if basis.job.state == .paused {
                guard let target = basis.job.pauseContext?.resumeTarget,
                      basis.snapshot.currentDurableActiveState == target,
                      cut.batchTerminalResults.isEmpty else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                // Resume restores only the exact durable target. The next active cut performs
                // its normal phase admission before executing batch work or activating a model.
                do {
                    try ReconstructionJobStateMachine.transition(
                        from: .paused, to: target, resumeTarget: target
                    )
                } catch {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                let plan = try Self.makePlan(
                    basis: basis, disposition: .continue,
                    newTasks: [], transitions: [], freshnessAuthority: basis.freshnessAuthority
                )
                try Self.validateBudget(plan, basis: basis)
                await removeBasis(for: cut)
                return plan
            }
            if let phase = try Self.preExecutionPhase(from: basis.snapshot) {
                guard cut.batchTerminalResults.isEmpty else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                let plan = try Self.makePlan(
                    basis: basis, disposition: .advancePhase(phase),
                    newTasks: [], transitions: [], freshnessAuthority: basis.freshnessAuthority
                )
                try Self.validateBudget(plan, basis: basis)
                await removeBasis(for: cut)
                return plan
            }
            if !cut.batchTerminalResults.isEmpty {
                let basePlan = try Self.makeBatchCommitPlan(cut: cut, basis: basis)
                let plan = try await receiptAuthor.makeBatchCommitPlan(
                    cut: cut,
                    basis: basis,
                    basePlan: basePlan
                )
                let completedFunctionSubjects = Set(cut.batchTerminalResults.compactMap { result
                    -> ReconstructionSubjectCoordinate? in
                    guard result.outcome == .completed,
                          let task = basis.tasks.first(where: { $0.identity.taskID == result.taskID }),
                          task.identity.kind == .decompileMacScope,
                          case .function = task.identity.subject,
                          Self.terminalPayloadIsValid(result, for: task,
                            checkpoint: basis.checkpoint,
                            corpusManifestSHA256: basis.manifest.canonicalSHA256) else { return nil }
                    return task.identity.subject
                })
                try Self.validateStructuralAugmentation(plan, preserves: basePlan,
                    allowedEmptyFunctionFacets: completedFunctionSubjects)
                try Self.validateBudget(plan, basis: basis)
                await removeBasis(for: cut)
                return plan
            }
            if let plan = try Self.makeModelActivationPlan(cut: cut, basis: basis) {
                try Self.validateBudget(plan, basis: basis)
                await removeBasis(for: cut)
                return plan
            }
            if let source = try Self.authorizedSourceRevisionFrontier(in: basis.tasks) {
                guard let request = cut.prepared.sourceRevisionRequest,
                      cut.prepared.finalSynthesisRequest == nil,
                      request.jobID == basis.job.jobID, request.roundID == cut.prepared.roundID,
                      request.checkpointRevision == basis.checkpoint.revision,
                      request.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
                      request.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256,
                      request.taskID == source.model.identity.taskID,
                      source.model.identity.subject == .function(request.function) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                do { try request.validate() }
                catch { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            } else if cut.prepared.sourceRevisionRequest != nil {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            guard try Self.modelExecutionIsDurablyAuthorized(basis.tasks) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return nil
        } catch {
            await removeBasis(for: cut)
            throw error
        }
    }

    func discardPreparedRound(cut: ReconstructionProductionCommittedRoundCut) async {
        await basisRegistry.remove(
            roundID: cut.prepared.roundID,
            matching: cut.snapshot,
            prepared: cut.prepared
        )
    }

    func makeCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan {
        try await consumeBasis(cut: cut) { basis in
            let basePlan = try Self.makeModelCommitBasePlan(
                cut: cut,
                basis: basis,
                inference: inference
            )
            let plan = try await receiptAuthor.makeModelCommitPlan(
                cut: cut,
                basis: basis,
                basePlan: basePlan,
                lease: lease,
                requestAuthority: requestAuthority,
                inference: inference,
                executions: executions
            )
            try Self.validateStructuralAugmentation(plan, preserves: basePlan)
            return plan
        }
    }

    func makeSourceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        try await consumeBasis(cut: cut) { basis in
            guard cut.batchTerminalResults.isEmpty, cut.prepared.finalSynthesisRequest == nil,
                  let request = cut.prepared.sourceRevisionRequest,
                  request.jobID == basis.job.jobID, request.roundID == cut.prepared.roundID,
                  request.checkpointRevision == basis.checkpoint.revision,
                  request.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
                  request.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256,
                  let frontier = try Self.authorizedSourceRevisionFrontier(in: basis.tasks),
                  request.taskID == frontier.model.identity.taskID,
                  frontier.model.identity.subject == .function(request.function) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            do { try source.candidate.validate(for: request) }
            catch { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            let transitions: [ReconstructionTaskTransition] = [
                .init(taskID: frontier.model.identity.taskID, expectedState: .running,
                    successorState: .completed, diagnostic: nil),
                .init(taskID: frontier.checkpoint.identity.taskID, expectedState: .pending,
                    successorState: .completed, diagnostic: nil),
            ]
            let transitioned = Self.applying(transitions, to: basis.tasks)
            let evaluation = try Self.makeSourceExecutionLeafTasks(jobID: basis.job.jobID,
                function: request.function, predecessorCheckpointID: frontier.checkpoint.identity.taskID,
                contract: ReconstructionSourceExecutionTaskContract.evaluate, tasks: transitioned,
                maximumTasks: basis.job.budget.maxTasks)
            let basePlan = try Self.makePlan(basis: basis, disposition: .continue,
                newTasks: evaluation, transitions: transitions, freshnessAuthority: basis.freshnessAuthority)
            let plan = try await receiptAuthor.makeSourceCommitPlan(cut: cut, basis: basis,
                basePlan: basePlan, lease: lease, requestAuthority: requestAuthority, source: source)
            try Self.validateStructuralAugmentation(plan, preserves: basePlan)
            return plan
        }
    }

    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        try await consumeBasis(cut: cut) { basis in
            let basePlan = try Self.makeFailedModelCommitBasePlan(
                cut: cut,
                basis: basis,
                reason: reason
            )
            let plan = try await receiptAuthor.makeFailedModelPlan(
                cut: cut,
                basis: basis,
                basePlan: basePlan,
                lease: lease,
                requestAuthority: requestAuthority,
                reason: reason
            )
            try Self.validateStructuralAugmentation(plan, preserves: basePlan)
            return plan
        }
    }

    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        try await consumeBasis(cut: cut) { basis in
            let basePlan = try Self.makeFinalCommitBasePlan(
                cut: cut,
                basis: basis
            )
            let plan = try await receiptAuthor.makeFinalCommitPlan(
                cut: cut,
                basis: basis,
                basePlan: basePlan,
                lease: lease,
                requestAuthority: requestAuthority,
                synthesis: synthesis
            )
            try Self.validateStructuralAugmentation(plan, preserves: basePlan)
            return plan
        }
    }

    func makeRecoveryPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        try await consumeBasis(cut: cut) { basis in
            try await receiptAuthor.makeRecoveryPlan(
                cut: cut,
                basis: basis,
                transitions: transitions
            )
        }
    }

    func makeControlPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        try await consumeBasis(cut: cut) { basis in
            try await receiptAuthor.makeControlPlan(
                cut: cut,
                basis: basis,
                reason: reason
            )
        }
    }

    private func consumeBasis(
        cut: ReconstructionProductionCommittedRoundCut,
        operation: (ReconstructionProductionRoundBasis) async throws
            -> ReconstructionJobCommitPlan
    ) async throws -> ReconstructionJobCommitPlan {
        let roundID = cut.prepared.roundID
        let basis = try await basisRegistry.basis(roundID: roundID, prepared: cut.prepared)
        do {
            try Self.validate(cut: cut, basis: basis)
            let result = try await operation(basis)
            try Self.validateBudget(result, basis: basis)
            await removeBasis(for: cut)
            return result
        } catch {
            await removeBasis(for: cut)
            throw error
        }
    }

    private func removeBasis(
        for cut: ReconstructionProductionCommittedRoundCut
    ) async {
        await basisRegistry.remove(
            roundID: cut.prepared.roundID,
            matching: cut.snapshot,
            prepared: cut.prepared
        )
    }

    private static func validate(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis
    ) throws {
        guard cut.snapshot == basis.snapshot,
              cut.parentCheckpointID == basis.checkpoint.checkpointID,
              cut.parentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              cut.prepared.evidenceCut == basis.evidenceCut,
              cut.prepared.authority.jobID == basis.job.jobID,
              cut.prepared.authority.checkpointRevision == basis.checkpoint.revision,
              cut.prepared.authority.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              cut.prepared.authority.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    private static func makeBatchCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionJobCommitPlan {
        let tasksByID = Dictionary(uniqueKeysWithValues: basis.tasks.map {
            ($0.identity.taskID, $0)
        })
        guard Set(cut.batchTerminalResults.map(\.taskID)).count
                == cut.batchTerminalResults.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }

        var transitions: [ReconstructionTaskTransition] = []
        var hasFailure = false
        var hasCancellation = false
        var failureReason: ReconstructionDiagnostic?
        var failureReasonTaskID: String?
        for result in cut.batchTerminalResults {
            guard let task = tasksByID[result.taskID],
                  task.identity.jobID == basis.job.jobID,
                  task.state == .pending || task.state == .running,
                  isBatchTask(task.identity.kind),
                  task.identity.dependencyTaskIDs.allSatisfy({
                      tasksByID[$0]?.state == .completed
                  }),
                  result.jobID == basis.job.jobID,
                  result.checkpointID == basis.checkpoint.checkpointID,
                  result.checkpointRevision == basis.checkpoint.revision,
                  result.corpusManifestSHA256 == basis.manifest.canonicalSHA256 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            guard terminalPayloadIsValid(
                result,
                for: task,
                checkpoint: basis.checkpoint,
                corpusManifestSHA256: basis.manifest.canonicalSHA256
            ) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let successor: ReconstructionTaskState
            let diagnostic: ReconstructionDiagnostic?
            var backend: ReconstructionDecompileBackendRecord?
            switch result.outcome {
            case .completed:
                successor = .completed
                diagnostic = nil
                if task.identity.kind == .decompileNative || task.identity.kind == .compareDecompilers {
                    backend = result.nativeResult == nil
                        ? .macIRFallback(result.decompileFallbackReason ?? ReconstructionDecompileBackendRecord.nativeUnavailable)
                        : .nativeBackend
                }
            case .failed:
                successor = .failed
                if let concrete = result.failureDiagnostic, !concrete.text.isEmpty {
                    diagnostic = concrete
                    // Deterministic: the lowest task ID's concrete failure names the job failure.
                    let key = task.identity.taskID.uuidString.lowercased()
                    if failureReasonTaskID.map({ key < $0 }) ?? true {
                        failureReasonTaskID = key
                        failureReason = .sanitizing("A deterministic reconstruction task failed (\(task.identity.kind.rawValue)): \(concrete.text)")
                    }
                } else {
                    diagnostic = .sanitizing("Deterministic reconstruction task failed.")
                }
                hasFailure = true
            case .cancelled:
                successor = .cancelled
                diagnostic = .sanitizing("Deterministic reconstruction task was cancelled.")
                hasCancellation = true
            case .staleAuthority:
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            transitions.append(.init(
                taskID: task.identity.taskID,
                expectedState: task.state,
                successorState: successor,
                diagnostic: diagnostic,
                decompileBackend: backend
            ))
        }

        if hasFailure || hasCancellation {
            let transitionedIDs = Set(transitions.map(\.taskID))
            for task in basis.tasks where !transitionedIDs.contains(task.identity.taskID)
                && (task.state == .pending || task.state == .running) {
                transitions.append(.init(
                    taskID: task.identity.taskID,
                    expectedState: task.state,
                    successorState: .blocked,
                    diagnostic: .sanitizing("Blocked by a terminal deterministic task result.")
                ))
            }
            return try makePlan(
                basis: basis,
                disposition: hasFailure ? .failed : .cancelled,
                newTasks: [],
                transitions: transitions,
                freshnessAuthority: basis.freshnessAuthority,
                failureReason: failureReason
            )
        }

        var newTasks: [ReconstructionTaskRecord] = []
        var taskBudgetTruncated = false
        var sourceDisposition: ReconstructionJobCoordinatorDisposition?
        var successorFreshness = basis.freshnessAuthority
        for result in cut.batchTerminalResults {
            guard let task = tasksByID[result.taskID] else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            switch task.identity.kind {
            case .loadBinary:
                guard let projection = result.analysisProjection,
                      projection.taskKind == .loadBinary else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                let image = try imageCoordinate(projection)
                successorFreshness = try adding(
                    image: image,
                    to: successorFreshness
                )
                let index = try makeTask(
                    jobID: basis.job.jobID,
                    kind: .indexImage,
                    subject: .image(image),
                    dependencies: [task.identity.taskID]
                )
                let enumerate = try makeTask(
                    jobID: basis.job.jobID,
                    kind: .enumerateFunctions,
                    subject: .image(image),
                    dependencies: [index.identity.taskID]
                )
                newTasks.append(contentsOf: [index, enumerate])
            case .enumerateFunctions:
                guard let projection = result.analysisProjection,
                      projection.taskKind == .enumerateFunctions,
                      !projection.functionCatalogWasTruncated,
                      !projection.functionNamesWereTruncated else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                let image = try imageCoordinate(projection)
                successorFreshness = try adding(
                    image: image,
                    to: successorFreshness
                )
                let coordinates = try orderedFunctionCoordinates(
                    projection: projection, focus: basis.job.focus
                )
                for coordinate in coordinates {
                    // Reserve the model chain without starving small historical budgets.
                    let finalReserve = min(2, basis.job.budget.maxTasks)
                    let modelReserve = min(basis.job.budget.maxTasks / 4,
                        min((basis.job.budget.maxTasks - finalReserve) / 3,
                            basis.job.budget.maxRounds) * 3 + finalReserve)
                    guard basis.tasks.count + newTasks.count + 3
                            <= basis.job.budget.maxTasks - modelReserve else {
                        taskBudgetTruncated = true
                        if let index = transitions.firstIndex(where: { $0.taskID == task.identity.taskID }) {
                            transitions[index] = .init(taskID: task.identity.taskID,
                                expectedState: task.state, successorState: .completed,
                                diagnostic: .sanitizing("Function coverage was truncated by the task budget; unprocessed functions are not reconstructed."))
                        }
                        continue
                    }
                    let native = try makeTask(
                        jobID: basis.job.jobID,
                        kind: .decompileNative,
                        subject: .function(coordinate),
                        dependencies: [task.identity.taskID]
                    )
                    let macScope = try makeTask(
                        jobID: basis.job.jobID,
                        kind: .decompileMacScope,
                        subject: .function(coordinate),
                        dependencies: [task.identity.taskID]
                    )
                    let compare = try makeTask(
                        jobID: basis.job.jobID,
                        kind: .compareDecompilers,
                        subject: .function(coordinate),
                        dependencies: [native.identity.taskID, macScope.identity.taskID]
                    )
                    newTasks.append(contentsOf: [native, macScope, compare])
                }
            case .executeSource:
                guard cut.batchTerminalResults.count == 1,
                      let executionFrontier = try sourceExecutionFrontiers(in: basis.tasks).first(where: {
                        $0.execution.identity.taskID == task.identity.taskID
                      }), let payload = result.sourceExecution,
                      case .function(let function)? = task.identity.subject else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                transitions.append(.init(taskID: executionFrontier.checkpoint.identity.taskID,
                    expectedState: .pending, successorState: .completed, diagnostic: nil))
                let transitioned = applying(transitions, to: basis.tasks)
                switch payload {
                case .oracle(let oracle):
                    guard oracle.projectID == basis.project.projectID, oracle.jobID == basis.job.jobID,
                          oracle.function == function else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
                    newTasks = try makeSourceRevisionLeafTasks(jobID: basis.job.jobID, function: function,
                        predecessorCheckpointID: executionFrontier.checkpoint.identity.taskID,
                        tasks: transitioned, maximumTasks: basis.job.budget.maxTasks)
                    sourceDisposition = .continue
                case .evaluation(let evaluation):
                    let revisions = try ReconstructionProductionSourceAuthority.committedRevisions(
                        function: function, basis: basis)
                    let oracle = try ReconstructionProductionSourceAuthority.committedOracle(function: function, basis: basis)
                    guard let committed = revisions.last,
                          evaluation.sourceAuthority == .admittedRevision(revisionSHA256: committed.revision.revisionSHA256),
                          evaluation.sourceSHA256 == committed.revision.sourceSHA256,
                          evaluation.oracleSuiteSHA256 == oracle.suiteSHA256,
                          evaluation.function == function else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
                    if evaluation.matchesOracle {
                        guard evaluation.observations.map(\.output) == oracle.outputs else {
                            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                        }
                        sourceDisposition = .completed
                    } else if revisions.count == 1 {
                        newTasks = try makeSourceRevisionLeafTasks(jobID: basis.job.jobID, function: function,
                            predecessorCheckpointID: executionFrontier.checkpoint.identity.taskID,
                            tasks: transitioned, maximumTasks: basis.job.budget.maxTasks)
                        sourceDisposition = .continue
                    } else {
                        sourceDisposition = .paused(.evidenceStalled)
                    }
                }
            case .ingest, .classify, .discoverRelations, .indexImage,
                 .decompileNative, .decompileMacScope, .compareDecompilers:
                break
            case .retrieveEvidence, .modelRound, .checkpoint:
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }

        var successorTasks = applying(transitions, to: basis.tasks) + newTasks
        if successorTasks.filter({ isBatchTask($0.identity.kind) }).allSatisfy({
            $0.state == .completed
        }) && !successorTasks.contains(where: { !isBatchTask($0.identity.kind) }) {
            let leafIDs = batchLeafTaskIDs(successorTasks)
            guard !leafIDs.isEmpty else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let leaves = try makeRegularModelLeafTasks(
                jobID: basis.job.jobID,
                dependencies: leafIDs
            )
            if successorTasks.count + leaves.count <= basis.job.budget.maxTasks {
                newTasks.append(contentsOf: leaves)
                successorTasks.append(contentsOf: leaves)
            } else {
                taskBudgetTruncated = true
            }
        }
        try validateDynamicTaskGraph(
            successorTasks,
            jobID: basis.job.jobID,
            maximumTasks: basis.job.budget.maxTasks
        )
        return try makePlan(
            basis: basis,
            disposition: sourceDisposition ?? (taskBudgetTruncated && !successorTasks.contains(where: { $0.state == .running })
                ? .paused(.evidenceStalled)
                : batchDisposition(from: basis.snapshot, successorTasks: successorTasks)),
            newTasks: newTasks,
            transitions: transitions,
            freshnessAuthority: successorFreshness
        )
    }

    private static func makeModelActivationPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionJobCommitPlan? {
        guard cut.batchTerminalResults.isEmpty else { return nil }
        try validateDynamicTaskGraph(
            basis.tasks,
            jobID: basis.job.jobID,
            maximumTasks: basis.job.budget.maxTasks
        )
        let batchTasks = basis.tasks.filter { isBatchTask($0.identity.kind) }
        guard !batchTasks.isEmpty, batchTasks.allSatisfy({ $0.state == .completed }) else {
            return nil
        }
        if let frontier = try pendingRegularModelFrontier(in: basis.tasks) {
            guard cut.prepared.sourceRevisionRequest == nil else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            return try makePlan(
                basis: basis,
                disposition: basis.job.state == .retrieving
                    ? .advancePhase(.awaitingModel) : .continue,
                newTasks: [],
                transitions: [
                    .init(
                        taskID: frontier.retrieve.identity.taskID,
                        expectedState: .pending,
                        successorState: .running,
                        diagnostic: nil
                    ),
                    .init(
                        taskID: frontier.model.identity.taskID,
                        expectedState: .pending,
                        successorState: .running,
                        diagnostic: nil
                    ),
                ],
                freshnessAuthority: basis.freshnessAuthority
            )
        }
        if let frontier = try pendingFinalSynthesisFrontier(in: basis.tasks) {
            guard cut.prepared.sourceRevisionRequest == nil else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            return try makePlan(
                basis: basis,
                disposition: .continue,
                newTasks: [],
                transitions: [
                    .init(
                        taskID: frontier.model.identity.taskID,
                        expectedState: .pending,
                        successorState: .running,
                        diagnostic: nil
                    ),
                ],
                freshnessAuthority: basis.freshnessAuthority
            )
        }
        if let frontier = try pendingSourceRevisionFrontier(in: basis.tasks) {
            guard let request = cut.prepared.sourceRevisionRequest,
                  request.taskID == frontier.model.identity.taskID,
                  frontier.model.identity.subject == .function(request.function),
                  request.jobID == basis.job.jobID, request.roundID == cut.prepared.roundID,
                  request.checkpointRevision == basis.checkpoint.revision,
                  request.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
                  request.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256,
                  cut.prepared.finalSynthesisRequest == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            do { try request.validate() }
            catch { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            return try makePlan(basis: basis,
                disposition: basis.job.state == .retrieving ? .advancePhase(.awaitingModel) : .continue,
                newTasks: [], transitions: [
                    .init(taskID: frontier.model.identity.taskID, expectedState: .pending,
                        successorState: .running, diagnostic: nil),
                ], freshnessAuthority: basis.freshnessAuthority)
        }
        return nil
    }

    private static func makeModelCommitBasePlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        inference: ReconstructionInferenceExecutionResult
    ) throws -> ReconstructionJobCommitPlan {
        guard cut.batchTerminalResults.isEmpty,
              cut.prepared.finalSynthesisRequest == nil,
              cut.prepared.sourceRevisionRequest == nil,
              inference.candidate.jobID == basis.job.jobID,
              inference.candidate.checkpointRevision == basis.checkpoint.revision,
              inference.candidate.roundID == cut.prepared.roundID,
              let frontier = try authorizedRegularModelFrontier(in: basis.tasks) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }

        let completedTransitions = [
            ReconstructionTaskTransition(
                taskID: frontier.retrieve.identity.taskID,
                expectedState: .running,
                successorState: .completed,
                diagnostic: nil
            ),
            ReconstructionTaskTransition(
                taskID: frontier.model.identity.taskID,
                expectedState: .running,
                successorState: .completed,
                diagnostic: nil
            ),
            ReconstructionTaskTransition(
                taskID: frontier.checkpoint.identity.taskID,
                expectedState: .pending,
                successorState: .completed,
                diagnostic: nil
            ),
        ]
        var disposition: ReconstructionJobCoordinatorDisposition
        var transitions: [ReconstructionTaskTransition]
        var newTasks: [ReconstructionTaskRecord]
        let registry = ReconstructionToolRegistry()
        let handles = try registry.mintHandles(authority: cut.prepared.authority,
            requests: cut.prepared.requests)
        let selectedIDs = inference.candidate.selectedHandleIDs
        guard Set(selectedIDs).count == selectedIDs.count,
              selectedIDs.allSatisfy({ id in handles.contains { $0.handleID == id } }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let demands = try handles.filter { selectedIDs.contains($0.handleID)
            && $0.operationID == .analysisMacScopeRefresh }.map {
                try registry.decodeCanonicalRequest($0)
            }
        guard demands.count <= 1,
              demands.isEmpty || inference.candidate.disposition == .continue else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        var refresh: ReconstructionTaskRecord?
        if let demand = demands.first {
            guard demand.taskID == frontier.retrieve.identity.taskID,
                  demand.retrievalQuery == nil, demand.offset == 0, demand.maximumRecords == 1,
                  case .function(let function)? = demand.subject else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let enumeration = try ReconstructionMacScopeAnalysisDemand.enumerationTask(
                for: function, tasks: basis.tasks, evidenceCut: basis.evidenceCut)
            refresh = try makeTask(jobID: basis.job.jobID, kind: .decompileMacScope,
                subject: .function(function), dependencies: [enumeration.identity.taskID,
                    frontier.checkpoint.identity.taskID])
        }
        switch inference.candidate.disposition {
        case .continue:
            disposition = basis.job.state == .executingReads
                ? .advancePhase(.acceptingEvidence) : .continue
            transitions = completedTransitions
            newTasks = try makeRegularModelLeafTasks(
                jobID: basis.job.jobID,
                dependencies: [frontier.checkpoint.identity.taskID]
                    + (refresh.map { [$0.identity.taskID] } ?? [])
            )
            if let refresh { newTasks.insert(refresh, at: 0) }
        case .blocked:
            disposition = .paused(.evidenceStalled)
            transitions = completedTransitions
            newTasks = try makeRegularModelLeafTasks(
                jobID: basis.job.jobID,
                dependencies: [frontier.checkpoint.identity.taskID]
            )
        case .sufficientEvidence:
            disposition = basis.job.state == .executingReads
                ? .advancePhase(.acceptingEvidence) : .continue
            transitions = completedTransitions
            if cut.prepared.sourceOracleRequested && cut.prepared.sourceOracleFunction == nil {
                disposition = .paused(.evidenceStalled)
                newTasks = try makeRegularModelLeafTasks(jobID: basis.job.jobID,
                    dependencies: [frontier.checkpoint.identity.taskID])
                transitions[2] = .init(taskID: frontier.checkpoint.identity.taskID,
                    expectedState: .pending, successorState: .completed,
                    diagnostic: .sanitizing("The prepared source sample's function could not be qualified from committed analysis."))
            } else if let function = cut.prepared.sourceOracleFunction {
                guard ReconstructionSourceOriginalSessionRegistry.committedFunctions(in: basis).contains(function) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                newTasks = try makeSourceExecutionLeafTasks(jobID: basis.job.jobID, function: function,
                    predecessorCheckpointID: frontier.checkpoint.identity.taskID,
                    contract: ReconstructionSourceExecutionTaskContract.oracle,
                    tasks: applying(completedTransitions, to: basis.tasks), maximumTasks: basis.job.budget.maxTasks)
            } else {
                newTasks = try makeFinalSynthesisLeafTasks(
                    jobID: basis.job.jobID, dependencies: [frontier.checkpoint.identity.taskID])
            }
        }
        if newTasks.count > basis.job.budget.maxTasks - basis.tasks.count {
            disposition = .paused(.evidenceStalled)
            newTasks = []
            transitions[2] = .init(taskID: frontier.checkpoint.identity.taskID,
                expectedState: .pending, successorState: .completed,
                diagnostic: .sanitizing(ReconstructionTaskBudgetPause.diagnostic))
        }
        let successorTasks = applying(transitions, to: basis.tasks) + newTasks
        try validateDynamicTaskGraph(
            successorTasks,
            jobID: basis.job.jobID,
            maximumTasks: basis.job.budget.maxTasks
        )
        return try makePlan(
            basis: basis,
            disposition: disposition,
            newTasks: newTasks,
            transitions: transitions,
            freshnessAuthority: basis.freshnessAuthority
        )
    }

    private static func makeFailedModelCommitBasePlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        reason: ReconstructionJobCoordinatorFailure
    ) throws -> ReconstructionJobCommitPlan {
        guard cut.batchTerminalResults.isEmpty else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        if case .retryableProviderFailure(let providerReason) = reason {
            let diagnostic = ReconstructionDiagnostic.sanitizing("Model request paused: \(providerReason).")
            let transitions = basis.tasks.filter { $0.state == .running }.map {
                ReconstructionTaskTransition(taskID: $0.identity.taskID,
                    expectedState: .running, successorState: .pending, diagnostic: diagnostic)
            }
            return try makePlan(basis: basis, disposition: .paused(.modelUnavailable),
                newTasks: [], transitions: transitions, freshnessAuthority: basis.freshnessAuthority)
        }
        guard reason == .malformedOutput else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
        let diagnostic = ReconstructionDiagnostic.sanitizing(
            "The model provider returned a terminal result that could not be accepted."
        )
        let transitions: [ReconstructionTaskTransition]
        if cut.prepared.sourceRevisionRequest != nil,
           cut.prepared.finalSynthesisRequest == nil,
           let frontier = try authorizedSourceRevisionFrontier(in: basis.tasks) {
            transitions = [
                .init(taskID: frontier.model.identity.taskID, expectedState: .running,
                    successorState: .failed, diagnostic: diagnostic),
                .init(taskID: frontier.checkpoint.identity.taskID, expectedState: .pending,
                    successorState: .blocked, diagnostic: diagnostic),
            ]
        } else if cut.prepared.finalSynthesisRequest == nil,
           cut.prepared.sourceRevisionRequest == nil,
           let frontier = try authorizedRegularModelFrontier(in: basis.tasks) {
            transitions = [
                .init(
                    taskID: frontier.retrieve.identity.taskID,
                    expectedState: .running,
                    successorState: .completed,
                    diagnostic: nil
                ),
                .init(
                    taskID: frontier.model.identity.taskID,
                    expectedState: .running,
                    successorState: .failed,
                    diagnostic: diagnostic
                ),
                .init(
                    taskID: frontier.checkpoint.identity.taskID,
                    expectedState: .pending,
                    successorState: .blocked,
                    diagnostic: diagnostic
                ),
            ]
        } else if cut.prepared.finalSynthesisRequest != nil,
                  cut.prepared.sourceRevisionRequest == nil,
                  let frontier = try authorizedFinalSynthesisFrontier(in: basis.tasks) {
            transitions = [
                .init(
                    taskID: frontier.model.identity.taskID,
                    expectedState: .running,
                    successorState: .failed,
                    diagnostic: diagnostic
                ),
                .init(
                    taskID: frontier.checkpoint.identity.taskID,
                    expectedState: .pending,
                    successorState: .blocked,
                    diagnostic: diagnostic
                ),
            ]
        } else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let successorTasks = applying(transitions, to: basis.tasks)
        try validateDynamicTaskGraph(
            successorTasks,
            jobID: basis.job.jobID,
            maximumTasks: basis.job.budget.maxTasks
        )
        return try makePlan(
            basis: basis,
            disposition: .failed,
            newTasks: [],
            transitions: transitions,
            freshnessAuthority: basis.freshnessAuthority
        )
    }

    private static func makeFinalCommitBasePlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionJobCommitPlan {
        guard cut.batchTerminalResults.isEmpty,
              cut.prepared.finalSynthesisRequest != nil,
              cut.prepared.sourceRevisionRequest == nil,
              let frontier = try authorizedFinalSynthesisFrontier(in: basis.tasks) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let transitions = [
            ReconstructionTaskTransition(
                taskID: frontier.model.identity.taskID,
                expectedState: .running,
                successorState: .completed,
                diagnostic: nil
            ),
            ReconstructionTaskTransition(
                taskID: frontier.checkpoint.identity.taskID,
                expectedState: .pending,
                successorState: .completed,
                diagnostic: nil
            ),
        ]
        let successorTasks = applying(transitions, to: basis.tasks)
        try validateDynamicTaskGraph(
            successorTasks,
            jobID: basis.job.jobID,
            maximumTasks: basis.job.budget.maxTasks
        )
        guard successorTasks.allSatisfy({ $0.state == .completed }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return try makePlan(
            basis: basis,
            disposition: .completed,
            newTasks: [],
            transitions: transitions,
            freshnessAuthority: basis.freshnessAuthority
        )
    }

    private static func modelExecutionIsDurablyAuthorized(
        _ tasks: [ReconstructionTaskRecord]
    ) throws -> Bool {
        if try authorizedRegularModelFrontier(in: tasks) != nil { return true }
        return try authorizedFinalSynthesisFrontier(in: tasks) != nil
            || authorizedSourceRevisionFrontier(in: tasks) != nil
    }

    static func regularModelFrontiers(
        in tasks: [ReconstructionTaskRecord]
    ) throws -> [ReconstructionProductionRegularModelFrontier] {
        var tasksByID: [UUID: ReconstructionTaskRecord] = [:]
        for task in tasks {
            guard tasksByID.updateValue(task, forKey: task.identity.taskID) == nil else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        return try tasks.compactMap { model in
            guard model.identity.kind == .modelRound,
                  model.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.modelRound else {
                return nil
            }
            guard model.identity.subject == nil,
                  model.identity.dependencyTaskIDs.count == 1,
                  let retrieve = tasksByID[model.identity.dependencyTaskIDs[0]],
                  retrieve.identity.kind == .retrieveEvidence,
                  retrieve.identity.subject == nil,
                  retrieve.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.evidenceQuery else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let checkpoints = tasks.filter {
                $0.identity.kind == .checkpoint
                    && $0.identity.dependencyTaskIDs == [model.identity.taskID]
            }
            guard checkpoints.count == 1, let checkpoint = checkpoints.first,
                  checkpoint.identity.subject == nil,
                  checkpoint.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.checkpoint else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return ReconstructionProductionRegularModelFrontier(
                retrieve: retrieve,
                model: model,
                checkpoint: checkpoint
            )
        }
    }

    static func finalSynthesisFrontiers(
        in tasks: [ReconstructionTaskRecord]
    ) throws -> [ReconstructionProductionFinalSynthesisFrontier] {
        try tasks.compactMap { model in
            guard model.identity.kind == .modelRound,
                  model.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.finalSynthesis else {
                return nil
            }
            guard model.identity.subject == nil,
                  model.identity.dependencyTaskIDs.count == 1 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let checkpoints = tasks.filter {
                $0.identity.kind == .checkpoint
                    && $0.identity.dependencyTaskIDs == [model.identity.taskID]
            }
            guard checkpoints.count == 1, let checkpoint = checkpoints.first,
                  checkpoint.identity.subject == nil,
                  checkpoint.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.checkpoint else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return ReconstructionProductionFinalSynthesisFrontier(
                model: model,
                checkpoint: checkpoint
            )
        }
    }

    static func pendingRegularModelFrontier(
        in tasks: [ReconstructionTaskRecord]
    ) throws -> ReconstructionProductionRegularModelFrontier? {
        let matches = try regularModelFrontiers(in: tasks).filter {
            $0.retrieve.state == .pending
                && $0.model.state == .pending
                && $0.checkpoint.state == .pending
        }
        guard matches.count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return matches.first
    }

    static func authorizedRegularModelFrontier(
        in tasks: [ReconstructionTaskRecord]
    ) throws -> ReconstructionProductionRegularModelFrontier? {
        let matches = try regularModelFrontiers(in: tasks).filter {
            $0.retrieve.state == .running
                && $0.model.state == .running
                && $0.checkpoint.state == .pending
        }
        guard matches.count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return matches.first
    }

    static func pendingFinalSynthesisFrontier(
        in tasks: [ReconstructionTaskRecord]
    ) throws -> ReconstructionProductionFinalSynthesisFrontier? {
        let matches = try finalSynthesisFrontiers(in: tasks).filter {
            $0.model.state == .pending && $0.checkpoint.state == .pending
        }
        guard matches.count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return matches.first
    }

    static func authorizedFinalSynthesisFrontier(
        in tasks: [ReconstructionTaskRecord]
    ) throws -> ReconstructionProductionFinalSynthesisFrontier? {
        let matches = try finalSynthesisFrontiers(in: tasks).filter {
            $0.model.state == .running && $0.checkpoint.state == .pending
        }
        guard matches.count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return matches.first
    }

    static func sourceRevisionFrontiers(in tasks: [ReconstructionTaskRecord]) throws
        -> [ReconstructionProductionSourceRevisionFrontier] {
        guard Set(tasks.map(\.identity.taskID)).count == tasks.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.identity.taskID, $0) })
        let frontiers = try tasks.compactMap { model -> ReconstructionProductionSourceRevisionFrontier? in
            guard model.identity.kind == .modelRound,
                  model.identity.operationContractIdentity == ReconstructionProductionTaskContract.sourceRevision else { return nil }
            guard case .function(let function)? = model.identity.subject,
                  function.image.architecture == .arm64,
                  model.identity.dependencyTaskIDs.count == 1,
                  let predecessor = tasksByID[model.identity.dependencyTaskIDs[0]],
                  predecessor.identity.kind == .checkpoint, predecessor.state == .completed else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let checkpoints = tasks.filter { $0.identity.kind == .checkpoint
                && $0.identity.dependencyTaskIDs == [model.identity.taskID] }
            guard checkpoints.count == 1, let checkpoint = checkpoints.first,
                  checkpoint.identity.subject == nil,
                  checkpoint.identity.operationContractIdentity == ReconstructionProductionTaskContract.checkpoint else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            switch (model.state, checkpoint.state) {
            case (.pending, .pending), (.running, .pending), (.completed, .completed),
                 (.failed, .blocked), (.failed, .failed), (.blocked, .blocked), (.cancelled, .blocked),
                 (.cancelled, .cancelled): break
            default: throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return .init(model: model, checkpoint: checkpoint)
        }
        guard frontiers.count <= 2, Set(frontiers.compactMap { $0.model.identity.subject }).count <= 1 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return frontiers
    }

    static func pendingSourceRevisionFrontier(in tasks: [ReconstructionTaskRecord]) throws
        -> ReconstructionProductionSourceRevisionFrontier? {
        let matches = try sourceRevisionFrontiers(in: tasks).filter {
            $0.model.state == .pending && $0.checkpoint.state == .pending
        }
        guard matches.count <= 1 else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
        return matches.first
    }

    static func authorizedSourceRevisionFrontier(in tasks: [ReconstructionTaskRecord]) throws
        -> ReconstructionProductionSourceRevisionFrontier? {
        let matches = try sourceRevisionFrontiers(in: tasks).filter {
            $0.model.state == .running && $0.checkpoint.state == .pending
        }
        guard matches.count <= 1 else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
        return matches.first
    }

    /// Explicit owner admission seam. The caller must bind committed oracle evidence and parent
    /// revision authority before publishing these tasks through the existing checkpoint owner.
    /// An ordinary or final model response never silently schedules executable source work.
    static func makeSourceRevisionLeafTasks(jobID: UUID, function: ReconstructionFunctionCoordinate,
        predecessorCheckpointID: UUID, tasks: [ReconstructionTaskRecord], maximumTasks: Int) throws
        -> [ReconstructionTaskRecord] {
        try validateDynamicTaskGraph(tasks, jobID: jobID, maximumTasks: maximumTasks)
        guard function.image.architecture == .arm64, maximumTasks >= 2,
              tasks.count <= maximumTasks - 2,
              try sourceRevisionFrontiers(in: tasks).count < 2,
              tasks.contains(where: { $0.identity.taskID == predecessorCheckpointID
                && $0.identity.kind == .checkpoint && $0.state == .completed }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let predecessor = tasks.first { $0.identity.taskID == predecessorCheckpointID }
        let completedSourceCount = try sourceRevisionFrontiers(in: tasks).count
        if completedSourceCount > 0 {
            guard let predecessor, predecessor.identity.dependencyTaskIDs.count == 1,
                  let evaluation = tasks.first(where: { $0.identity.taskID == predecessor.identity.dependencyTaskIDs[0] }),
                  evaluation.identity.kind == .executeSource,
                  evaluation.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate,
                  evaluation.identity.subject == .function(function), evaluation.state == .completed else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        let model = try makeTask(jobID: jobID, kind: .modelRound, subject: .function(function),
            dependencies: [predecessorCheckpointID],
            operationContractIdentity: ReconstructionProductionTaskContract.sourceRevision)
        let checkpoint = try makeTask(jobID: jobID, kind: .checkpoint, subject: nil,
            dependencies: [model.identity.taskID])
        let created = [model, checkpoint]
        try validateDynamicTaskGraph(tasks + created, jobID: jobID, maximumTasks: maximumTasks)
        return created
    }

    static func sourceExecutionFrontiers(in tasks: [ReconstructionTaskRecord]) throws
        -> [ReconstructionProductionSourceExecutionFrontier] {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.identity.taskID, $0) })
        return try tasks.filter { $0.identity.kind == .executeSource }.map { execution in
            guard case .function(let function)? = execution.identity.subject,
                  function.image.architecture == .arm64,
                  execution.identity.dependencyTaskIDs.count == 1,
                  let predecessor = byID[execution.identity.dependencyTaskIDs[0]],
                  predecessor.identity.kind == .checkpoint, predecessor.state == .completed,
                  execution.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle
                    || execution.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate
            else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            let checkpoints = tasks.filter { $0.identity.kind == .checkpoint
                && $0.identity.dependencyTaskIDs == [execution.identity.taskID] }
            guard checkpoints.count == 1, let checkpoint = checkpoints.first,
                  checkpoint.identity.subject == nil,
                  checkpoint.identity.operationContractIdentity == ReconstructionProductionTaskContract.checkpoint
            else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            switch (execution.state, checkpoint.state) {
            case (.pending, .pending), (.running, .pending), (.completed, .completed),
                 (.failed, .blocked), (.cancelled, .blocked), (.blocked, .blocked): break
            default: throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return .init(execution: execution, checkpoint: checkpoint)
        }
    }

    static func makeSourceExecutionLeafTasks(jobID: UUID, function: ReconstructionFunctionCoordinate,
        predecessorCheckpointID: UUID, contract: String, tasks: [ReconstructionTaskRecord],
        maximumTasks: Int) throws -> [ReconstructionTaskRecord] {
        guard maximumTasks >= 2, tasks.count <= maximumTasks - 2,
              contract == ReconstructionSourceExecutionTaskContract.oracle
                || contract == ReconstructionSourceExecutionTaskContract.evaluate,
              tasks.contains(where: { $0.identity.taskID == predecessorCheckpointID
                && $0.identity.kind == .checkpoint && $0.state == .completed }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        guard let predecessor = tasks.first(where: { $0.identity.taskID == predecessorCheckpointID }),
              predecessor.identity.dependencyTaskIDs.count == 1,
              let previous = tasks.first(where: { $0.identity.taskID == predecessor.identity.dependencyTaskIDs[0] }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        if contract == ReconstructionSourceExecutionTaskContract.evaluate {
            guard previous.identity.kind == .modelRound,
                  previous.identity.operationContractIdentity == ReconstructionProductionTaskContract.sourceRevision,
                  previous.identity.subject == .function(function), previous.state == .completed else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        } else {
            guard previous.identity.kind == .modelRound,
                  previous.identity.operationContractIdentity != ReconstructionProductionTaskContract.sourceRevision,
                  !tasks.contains(where: { $0.identity.kind == .executeSource }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        let execution = try makeTask(jobID: jobID, kind: .executeSource, subject: .function(function),
            dependencies: [predecessorCheckpointID], operationContractIdentity: contract)
        let checkpoint = try makeTask(jobID: jobID, kind: .checkpoint, subject: nil,
            dependencies: [execution.identity.taskID])
        let created = [execution, checkpoint]
        try validateDynamicTaskGraph(tasks + created, jobID: jobID, maximumTasks: maximumTasks)
        return created
    }

    static func validateDynamicTaskGraph(
        _ tasks: [ReconstructionTaskRecord],
        jobID: UUID,
        maximumTasks: Int
    ) throws {
        guard tasks.count <= maximumTasks,
              Set(tasks.map(\.identity.taskID)).count == tasks.count,
              tasks.allSatisfy({ $0.identity.jobID == jobID }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map {
            ($0.identity.taskID, $0)
        })
        for task in tasks {
            guard task.identity.dependencyTaskIDs.allSatisfy({ tasksByID[$0] != nil }),
                  taskContractIsValid(task.identity) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            switch (task.identity.kind, task.identity.subject) {
            case (.ingest, .artifact):
                guard task.identity.dependencyTaskIDs.isEmpty else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.classify, .artifact(let artifact)):
                guard task.identity.dependencyTaskIDs.count == 1,
                      let dependency = tasksByID[task.identity.dependencyTaskIDs[0]],
                      dependency.identity.kind == .ingest,
                      dependency.identity.subject == .artifact(artifact) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.discoverRelations, .artifact(let artifact)):
                guard task.identity.dependencyTaskIDs.count == 1,
                      let dependency = tasksByID[task.identity.dependencyTaskIDs[0]],
                      dependency.identity.kind == .classify,
                      dependency.identity.subject == .artifact(artifact) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.loadBinary, .artifact(let artifact)):
                guard task.identity.dependencyTaskIDs.count == 1,
                      let dependency = tasksByID[task.identity.dependencyTaskIDs[0]],
                      dependency.identity.kind == .ingest,
                      dependency.identity.subject == .artifact(artifact) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.indexImage, .image(let image)):
                guard task.identity.dependencyTaskIDs.count == 1,
                      let dependency = tasksByID[task.identity.dependencyTaskIDs[0]],
                      dependency.identity.kind == .loadBinary,
                      dependency.identity.subject == .artifact(image.artifact) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.enumerateFunctions, .image(let image)):
                guard task.identity.dependencyTaskIDs.count == 1,
                      let dependency = tasksByID[task.identity.dependencyTaskIDs[0]],
                      dependency.identity.kind == .indexImage,
                      dependency.identity.subject == .image(image) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.decompileNative, .function(let function)),
                 (.decompileMacScope, .function(let function)):
                let expectedImage = try ReconstructionImageCoordinate(
                    artifact: function.artifact,
                    image: function.image,
                    analysisFingerprintSHA256: function.analysisFingerprintSHA256
                )
                let dependencies = task.identity.dependencyTaskIDs.compactMap { tasksByID[$0] }
                let enumerations = dependencies.filter { $0.identity.kind == .enumerateFunctions }
                let checkpoints = dependencies.filter { $0.identity.kind == .checkpoint }
                guard let dependency = enumerations.first, enumerations.count == 1,
                      (dependencies.count == 1 || (task.identity.kind == .decompileMacScope
                        && dependencies.count == 2 && checkpoints.count == 1
                        && checkpoints[0].state == .completed && dependency.state == .completed)),
                      dependency.identity.kind == .enumerateFunctions,
                      dependency.identity.subject.flatMap({ subjectImage($0) })
                        == expectedImage else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.compareDecompilers, .function(let function)):
                guard task.identity.dependencyTaskIDs.count == 2 else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                let dependencies = task.identity.dependencyTaskIDs.compactMap { tasksByID[$0] }
                guard Set(dependencies.map(\.identity.kind))
                        == Set([.decompileNative, .decompileMacScope]),
                      dependencies.allSatisfy({ $0.identity.subject == .function(function) }) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.executeSource, .function(let function)):
                guard function.image.architecture == .arm64,
                      task.identity.dependencyTaskIDs.count == 1,
                      let dependency = tasksByID[task.identity.dependencyTaskIDs[0]],
                      dependency.identity.kind == .checkpoint, dependency.state == .completed else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.executeSource, _):
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            case (.modelRound, .function):
                guard task.identity.operationContractIdentity == ReconstructionProductionTaskContract.sourceRevision else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            case (.ingest, _), (.classify, _), (.discoverRelations, _),
                 (.loadBinary, _), (.indexImage, _), (.enumerateFunctions, _),
                 (.decompileNative, _), (.decompileMacScope, _),
                 (.compareDecompilers, _), (.retrieveEvidence, .some),
                 (.modelRound, .some), (.checkpoint, .some):
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            default:
                break
            }
        }
        let ingestTasks = tasks.filter { $0.identity.kind == .ingest }
        guard !ingestTasks.isEmpty,
              Set(ingestTasks.compactMap { task -> ReconstructionArtifactCoordinate? in
                  guard case .artifact(let artifact)? = task.identity.subject else { return nil }
                  return artifact
              }).count == ingestTasks.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        for ingest in ingestTasks {
            guard case .artifact(let artifact)? = ingest.identity.subject else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let classify = tasks.filter {
                $0.identity.kind == .classify
                    && $0.identity.subject == .artifact(artifact)
                    && $0.identity.dependencyTaskIDs == [ingest.identity.taskID]
            }
            let load = tasks.filter {
                $0.identity.kind == .loadBinary
                    && $0.identity.subject == .artifact(artifact)
                    && $0.identity.dependencyTaskIDs == [ingest.identity.taskID]
            }
            guard classify.count == 1, load.count <= 1,
                  let classifyTask = classify.first else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let discover = tasks.filter {
                $0.identity.kind == .discoverRelations
                    && $0.identity.subject == .artifact(artifact)
                    && $0.identity.dependencyTaskIDs == [classifyTask.identity.taskID]
            }
            guard discover.count == 1 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            if let loadTask = load.first {
                let imageIndexes = tasks.filter { task in
                    guard task.identity.kind == .indexImage,
                          task.identity.dependencyTaskIDs == [loadTask.identity.taskID],
                          case .image(let image)? = task.identity.subject else {
                        return false
                    }
                    return image.artifact == artifact
                }
                if loadTask.state == .completed {
                    guard imageIndexes.count == 1 else {
                        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                    }
                } else if !imageIndexes.isEmpty {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            }
        }
        for index in tasks where index.identity.kind == .indexImage {
            let enumerations = tasks.filter {
                $0.identity.kind == .enumerateFunctions
                    && $0.identity.subject == index.identity.subject
                    && $0.identity.dependencyTaskIDs == [index.identity.taskID]
            }
            guard enumerations.count == 1 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        let retrieveTasks = tasks.filter { $0.identity.kind == .retrieveEvidence }
        let modelTasks = tasks.filter { $0.identity.kind == .modelRound }
        let checkpointTasks = tasks.filter { $0.identity.kind == .checkpoint }
        guard retrieveTasks.count + modelTasks.count + checkpointTasks.count > 0 else { return }

        let regular = try regularModelFrontiers(in: tasks)
        let finals = try finalSynthesisFrontiers(in: tasks)
        let sources = try sourceRevisionFrontiers(in: tasks)
        let executions = try sourceExecutionFrontiers(in: tasks)
        let batchTasks = tasks.filter { isBatchTask($0.identity.kind) && $0.identity.kind != .executeSource
            && !($0.identity.kind == .decompileMacScope && $0.identity.dependencyTaskIDs.count == 2) }
        let leafTaskIDs = batchLeafTaskIDs(tasks)
        guard !batchTasks.isEmpty,
              batchTasks.allSatisfy({ $0.state == .completed }),
              !leafTaskIDs.isEmpty,
              !regular.isEmpty,
              finals.count <= 1,
              retrieveTasks.count == regular.count,
              modelTasks.count == regular.count + finals.count + sources.count,
              checkpointTasks.count == regular.count + finals.count + sources.count + executions.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }

        let initial = regular.filter {
            Set($0.retrieve.identity.dependencyTaskIDs) == Set(leafTaskIDs)
        }
        guard initial.count == 1, let first = initial.first else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let checkpointsByID = Dictionary(uniqueKeysWithValues: checkpointTasks.map {
            ($0.identity.taskID, $0)
        })
        for frontier in regular where frontier.retrieve.identity.taskID
            != first.retrieve.identity.taskID {
            let dependencies = frontier.retrieve.identity.dependencyTaskIDs
            let predecessors = dependencies.compactMap { checkpointsByID[$0] }
            guard let predecessor = predecessors.first, predecessors.count == 1,
                  predecessor.state == .completed, (1...2).contains(dependencies.count) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            if dependencies.count == 2 {
                guard let refreshID = dependencies.first(where: { $0 != predecessor.identity.taskID }),
                      let refresh = tasksByID[refreshID],
                      refresh.identity.kind == .decompileMacScope,
                      refresh.identity.dependencyTaskIDs.count == 2,
                      refresh.identity.dependencyTaskIDs.contains(predecessor.identity.taskID),
                      refresh.state == .completed || (frontier.retrieve.state == .pending
                        && frontier.model.state == .pending && frontier.checkpoint.state == .pending)
                        || ((refresh.state == .failed || refresh.state == .cancelled)
                            && frontier.retrieve.state == .blocked
                            && frontier.model.state == .blocked && frontier.checkpoint.state == .blocked) else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
            }
        }
        for refresh in tasks where refresh.identity.kind == .decompileMacScope
            && refresh.identity.dependencyTaskIDs.count == 2 {
            let checkpointIDs = refresh.identity.dependencyTaskIDs.filter { checkpointsByID[$0] != nil }
            guard checkpointIDs.count == 1,
                  regular.filter({ $0.retrieve.identity.dependencyTaskIDs.contains(refresh.identity.taskID)
                    && $0.retrieve.identity.dependencyTaskIDs.contains(checkpointIDs[0]) }).count == 1,
                  tasks.filter({ $0.identity.kind == .decompileMacScope
                    && $0.identity.dependencyTaskIDs.contains(checkpointIDs[0]) }).count == 1 else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }
        for frontier in finals {
            guard frontier.model.identity.dependencyTaskIDs.count == 1,
                  let predecessor = checkpointsByID[
                    frontier.model.identity.dependencyTaskIDs[0]
                  ], predecessor.state == .completed else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
        }

        enum Phase {
            case regular(ReconstructionProductionRegularModelFrontier)
            case final(ReconstructionProductionFinalSynthesisFrontier)
            case source(ReconstructionProductionSourceRevisionFrontier)
            case execution(ReconstructionProductionSourceExecutionFrontier)

            var isSource: Bool { if case .source = self { return true }; return false }
            var taskIDs: [UUID] {
                switch self {
                case .regular(let value):
                    [
                        value.retrieve.identity.taskID,
                        value.model.identity.taskID,
                        value.checkpoint.identity.taskID,
                    ]
                case .final(let value):
                    [value.model.identity.taskID, value.checkpoint.identity.taskID]
                case .source(let value):
                    [value.model.identity.taskID, value.checkpoint.identity.taskID]
                case .execution(let value):
                    [value.execution.identity.taskID, value.checkpoint.identity.taskID]
                }
            }

            var checkpoint: ReconstructionTaskRecord {
                switch self {
                case .regular(let value): value.checkpoint
                case .final(let value): value.checkpoint
                case .source(let value): value.checkpoint
                case .execution(let value): value.checkpoint
                }
            }

            var isCompleted: Bool {
                switch self {
                case .regular(let value):
                    value.retrieve.state == .completed
                        && value.model.state == .completed
                        && value.checkpoint.state == .completed
                case .final(let value):
                    value.model.state == .completed
                        && value.checkpoint.state == .completed
                case .source(let value):
                    value.model.state == .completed
                        && value.checkpoint.state == .completed
                case .execution(let value):
                    value.execution.state == .completed && value.checkpoint.state == .completed
                }
            }
        }

        var regularByPredecessor: [UUID: [ReconstructionProductionRegularModelFrontier]] = [:]
        for frontier in regular where frontier.retrieve.identity.taskID != first.retrieve.identity.taskID {
            guard let predecessorID = frontier.retrieve.identity.dependencyTaskIDs.first(where: {
                checkpointsByID[$0] != nil
            }) else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
            regularByPredecessor[predecessorID, default: []].append(frontier)
        }
        let finalByPredecessor = Dictionary(grouping: finals, by: {
            $0.model.identity.dependencyTaskIDs[0]
        })
        let sourceByPredecessor = Dictionary(grouping: sources, by: {
            $0.model.identity.dependencyTaskIDs[0]
        })
        let executionByPredecessor = Dictionary(grouping: executions, by: {
            $0.execution.identity.dependencyTaskIDs[0]
        })
        var visited: Set<UUID> = []
        var phase = Phase.regular(first)
        while true {
            guard phase.taskIDs.allSatisfy({ visited.insert($0).inserted }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            let checkpointID = phase.checkpoint.identity.taskID
            let regularSuccessors = regularByPredecessor[checkpointID] ?? []
            let finalSuccessors = finalByPredecessor[checkpointID] ?? []
            let sourceSuccessors = sourceByPredecessor[checkpointID] ?? []
            let executionSuccessors = executionByPredecessor[checkpointID] ?? []
            guard regularSuccessors.count + finalSuccessors.count + sourceSuccessors.count + executionSuccessors.count <= 1,
                  !phase.isSource || (regularSuccessors.isEmpty && finalSuccessors.isEmpty) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            if let successor = executionSuccessors.first {
                guard phase.isCompleted else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
                switch phase {
                case .source(let source):
                    guard successor.execution.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate,
                          successor.execution.identity.subject == source.model.identity.subject else {
                        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                    }
                case .regular, .final:
                    guard successor.execution.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle else {
                        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                    }
                case .execution: throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                phase = .execution(successor)
                continue
            }
            if let successor = regularSuccessors.first {
                if case .execution = phase { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
                guard phase.isCompleted else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                phase = .regular(successor)
                continue
            }
            if let successor = finalSuccessors.first {
                if case .execution = phase { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
                guard phase.isCompleted else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                phase = .final(successor)
                continue
            }
            if let successor = sourceSuccessors.first {
                guard phase.isCompleted else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
                switch phase {
                case .execution(let execution):
                    guard execution.execution.identity.subject == successor.model.identity.subject else {
                        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                    }
                case .regular, .final: break // retained pre-execution source fixture compatibility
                case .source: throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                phase = .source(successor)
                continue
            }
            break
        }
        guard visited.count == retrieveTasks.count + modelTasks.count + checkpointTasks.count + executions.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    private static func validateStructuralAugmentation(
        _ augmented: ReconstructionJobCommitPlan,
        preserves base: ReconstructionJobCommitPlan,
        allowedEmptyFunctionFacets: Set<ReconstructionSubjectCoordinate> = []
    ) throws {
        guard augmented.successorRevision == base.successorRevision,
              augmented.disposition == base.disposition,
              let mutation = augmented.mutation,
              let baseMutation = base.mutation,
              mutation.jobID == baseMutation.jobID,
              mutation.expectedParentCheckpointID
                == baseMutation.expectedParentCheckpointID,
              mutation.expectedParentCheckpointSHA256
                == baseMutation.expectedParentCheckpointSHA256,
              mutation.expectedParentRevision == baseMutation.expectedParentRevision,
              mutation.newTasks == baseMutation.newTasks,
              mutation.taskTransitions == baseMutation.taskTransitions,
              mutation.successorPauseContext == baseMutation.successorPauseContext,
              freshnessAuthorityMatches(
                  mutation.freshnessAuthority,
                  baseMutation.freshnessAuthority,
                  allowedEmptyFunctionFacets: allowedEmptyFunctionFacets.filter { subject in
                      mutation.evidence.contains { $0.subject == subject
                          && $0.classification == .acceptedCurrent
                          && $0.operationID == ReconstructionOperationID.decompilerMacScope.rawValue
                          && $0.facetDependencies.isEmpty }
                  }
              ),
              checkpointTaskAuthorityMatches(
                  mutation.successorCheckpoint,
                  baseMutation.successorCheckpoint
              ) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
    }

    private static func validateBudget(
        _ plan: ReconstructionJobCommitPlan,
        basis: ReconstructionProductionRoundBasis
    ) throws {
        let existingEvidenceCount = basis.evidenceCut.records.count
        guard let mutation = plan.mutation,
              mutation.jobID == basis.job.jobID,
              mutation.newTasks.allSatisfy({ $0.identity.jobID == basis.job.jobID }),
              mutation.evidence.allSatisfy({ $0.creatingJobID == basis.job.jobID }),
              mutation.toolReceipts.allSatisfy({ $0.jobID == basis.job.jobID }),
              mutation.modelReceipts.allSatisfy({ $0.jobID == basis.job.jobID }),
              mutation.finalResults.allSatisfy({ $0.jobID == basis.job.jobID }),
              mutation.newTasks.count <= basis.job.budget.maxTasks,
              basis.tasks.count <= basis.job.budget.maxTasks - mutation.newTasks.count,
              mutation.evidence.count <= basis.job.budget.maxEvidenceRecords,
              existingEvidenceCount
                <= basis.job.budget.maxEvidenceRecords - mutation.evidence.count,
              mutation.successorCheckpoint.canonicalEncodedByteCount
                <= basis.job.budget.maxEncodedBytes else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let payloads: [Data] = try [
            ReconstructionCanonicalJSON.encode(mutation.evidence),
            ReconstructionCanonicalJSON.encode(mutation.evidenceRelations),
            ReconstructionCanonicalJSON.encode(mutation.evidenceGaps),
            ReconstructionCanonicalJSON.encode(mutation.toolReceipts),
            ReconstructionCanonicalJSON.encode(mutation.modelReceipts),
            ReconstructionCanonicalJSON.encode(mutation.finalResults),
            ReconstructionCanonicalJSON.encode(mutation.newTasks),
            ReconstructionCanonicalJSON.encode(
                mutation.taskTransitions.map(EncodedTransition.init)
            ),
        ]
        var totalBytes = mutation.successorCheckpoint.canonicalEncodedByteCount
        for payload in payloads {
            let (next, overflow) = totalBytes.addingReportingOverflow(UInt64(payload.count))
            guard !overflow, next <= basis.job.budget.maxEncodedBytes else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            totalBytes = next
        }
    }

    private static func checkpointTaskAuthorityMatches(
        _ lhs: ReconstructionCheckpoint,
        _ rhs: ReconstructionCheckpoint
    ) -> Bool {
        lhs.checkpointID == rhs.checkpointID
            && lhs.jobID == rhs.jobID
            && lhs.revision == rhs.revision
            && lhs.parentCheckpointID == rhs.parentCheckpointID
            && lhs.parentCheckpointSHA256 == rhs.parentCheckpointSHA256
            && lhs.corpusManifestSHA256 == rhs.corpusManifestSHA256
            && lhs.pendingTaskIDs == rhs.pendingTaskIDs
            && lhs.runningTaskIDs == rhs.runningTaskIDs
            && lhs.completedTaskIDs == rhs.completedTaskIDs
            && lhs.failedTaskIDs == rhs.failedTaskIDs
            && lhs.blockedTaskIDs == rhs.blockedTaskIDs
            && lhs.coordinatorState == rhs.coordinatorState
            && lhs.terminalReason == rhs.terminalReason
    }

    private static func freshnessAuthorityMatches(
        _ lhs: ReconstructionFreshnessAuthority,
        _ rhs: ReconstructionFreshnessAuthority,
        allowedEmptyFunctionFacets: Set<ReconstructionSubjectCoordinate> = []
    ) -> Bool {
        let added = Set(lhs.currentFacetFingerprints.keys).subtracting(rhs.currentFacetFingerprints.keys)
        guard added.isSubset(of: allowedEmptyFunctionFacets),
              added.allSatisfy({ lhs.currentFacetFingerprints[$0]?.isEmpty == true }),
              rhs.currentFacetFingerprints.allSatisfy({ lhs.currentFacetFingerprints[$0.key] == $0.value })
        else { return false }
        return lhs.corpusManifestSHA256 == rhs.corpusManifestSHA256
            && lhs.currentArtifacts == rhs.currentArtifacts
            && lhs.currentImages == rhs.currentImages
    }

    private static func terminalPayloadIsValid(
        _ result: ReconstructionTerminalTaskResult,
        for task: ReconstructionTaskRecord,
        checkpoint: ReconstructionCheckpoint,
        corpusManifestSHA256: String
    ) -> Bool {
        guard result.outcome == .completed else {
            return result.analysisProjection == nil && result.nativeResult == nil
        }
        switch task.identity.kind {
        case .ingest, .classify, .discoverRelations:
            return result.analysisProjection == nil && result.nativeResult == nil
        case .loadBinary, .indexImage, .enumerateFunctions:
            return result.nativeResult == nil
                && result.analysisProjection.map {
                    projectionMatches($0, task: task)
                } == true
        case .decompileMacScope:
            return result.nativeResult == nil
                && result.analysisProjection.map {
                    projectionMatches($0, task: task) && $0.macScopePseudocode != nil
                } == true
        case .decompileNative, .compareDecompilers:
            guard let projection = result.analysisProjection,
                  projectionMatches(projection, task: task),
                  task.identity.kind != .compareDecompilers
                    || projection.macScopePseudocode != nil else {
                return false
            }
            if result.nativeResult == nil, let reason = result.decompileFallbackReason {
                return !reason.isEmpty
            }
            guard case .completed(let success)? = result.nativeResult else {
                return false
            }
            return success.taskID == task.identity.taskID
                && success.checkpointID == checkpoint.checkpointID
                && success.checkpointRevision == checkpoint.revision
                && success.corpusManifestSHA256 == corpusManifestSHA256
                && success.execution.imageSlot == projection.image.imageSlot
                && success.execution.functionID == projection.function?.id
                && success.execution.analysisInputFingerprintSHA256
                    == projection.analysisFingerprintSHA256
        case .executeSource:
            guard let authority = try? ReconstructionBatchAuthority(jobID: task.identity.jobID,
                checkpointID: checkpoint.checkpointID, checkpointRevision: checkpoint.revision,
                corpusManifestSHA256: corpusManifestSHA256) else { return false }
            return result.analysisProjection == nil && result.nativeResult == nil
                && result.sourceExecution?.isValid(for: task, authority: authority) == true
        case .retrieveEvidence, .modelRound, .checkpoint:
            return false
        }
    }

    private static func projectionMatches(
        _ projection: ReconstructionTransientAnalysisProjection,
        task: ReconstructionTaskRecord
    ) -> Bool {
        guard projection.taskID == task.identity.taskID,
              projection.taskKind == task.identity.kind else {
            return false
        }
        switch task.identity.subject {
        case .artifact(let artifact):
            return projection.artifact == artifact
        case .image(let image):
            return projection.artifact == image.artifact
                && projection.image == image.image
                && projection.analysisFingerprintSHA256 == image.analysisFingerprintSHA256
        case .function(let function):
            guard let projectedFunction = projection.function else { return false }
            return projection.artifact == function.artifact
                && projection.image == function.image
                && projection.analysisFingerprintSHA256
                    == function.analysisFingerprintSHA256
                && ReconstructionReboundFunctionAuthority.matches(
                    projectedFunction,
                    coordinate: function
                )
        case nil:
            return false
        }
    }

    private static func makePlan(
        basis: ReconstructionProductionRoundBasis,
        disposition: ReconstructionJobCoordinatorDisposition,
        newTasks: [ReconstructionTaskRecord],
        transitions: [ReconstructionTaskTransition],
        freshnessAuthority: ReconstructionFreshnessAuthority,
        failureReason: ReconstructionDiagnostic? = nil
    ) throws -> ReconstructionJobCommitPlan {
        let (successorRevision, revisionOverflow) = basis.checkpoint.revision
            .addingReportingOverflow(1)
        guard !revisionOverflow,
              basis.evidenceCut.records.count <= basis.job.budget.maxEvidenceRecords else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let successorTasks = applying(transitions, to: basis.tasks) + newTasks
        guard successorTasks.count <= basis.job.budget.maxTasks,
              UInt64(try ReconstructionCanonicalJSON.encode(successorTasks).count)
                <= basis.job.budget.maxEncodedBytes else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let successorState: ReconstructionJobState
        let terminalReason: ReconstructionDiagnostic?
        let successorPauseContext: ReconstructionJobPauseContext?
        switch disposition {
        case .advancePhase(let phase):
            guard basis.job.state != .paused,
                  ReconstructionJobState.activeStates.contains(phase) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            do {
                try ReconstructionJobStateMachine.transition(
                    from: basis.job.state, to: phase, resumeTarget: nil
                )
            } catch {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = phase
            terminalReason = nil
            successorPauseContext = nil
        case .continue:
            guard let activeState = basis.snapshot.currentDurableActiveState else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = activeState
            terminalReason = nil
            successorPauseContext = nil
        case .completed:
            guard successorTasks.allSatisfy({ $0.state == .completed }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = .completed
            terminalReason = nil
            successorPauseContext = nil
        case .paused(let reason):
            guard let cause = reason.durablePauseCause,
                  let activeState = basis.snapshot.currentDurableActiveState,
                  !successorTasks.contains(where: { $0.state == .running }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = .paused
            terminalReason = nil
            successorPauseContext = try ReconstructionJobPauseContext(
                cause: cause,
                resumeTarget: activeState
            )
        case .failed:
            guard !successorTasks.contains(where: {
                $0.state == .pending || $0.state == .running
            }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = .failed
            terminalReason = failureReason ?? .sanitizing("A deterministic reconstruction task failed.")
            successorPauseContext = nil
        case .cancelled:
            guard !successorTasks.contains(where: {
                $0.state == .pending || $0.state == .running
            }) else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            successorState = .cancelled
            terminalReason = .sanitizing("The reconstruction round was cancelled.")
            successorPauseContext = nil
        }
        let successorCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: deterministicCheckpointID(
                jobID: basis.job.jobID,
                parentCheckpointID: basis.checkpoint.checkpointID,
                successorRevision: successorRevision
            ),
            jobID: basis.job.jobID,
            revision: successorRevision,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
            pendingTaskIDs: taskIDs(state: .pending, in: successorTasks),
            runningTaskIDs: taskIDs(state: .running, in: successorTasks),
            completedTaskIDs: taskIDs(state: .completed, in: successorTasks),
            failedTaskIDs: taskIDs(state: .failed, in: successorTasks),
            blockedTaskIDs: taskIDs(state: .blocked, in: successorTasks),
            unresolvedEvidenceGapSHA256: basis.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: basis.checkpoint.modelReceiptIDs,
            toolReceiptIDs: basis.checkpoint.toolReceiptIDs,
            coordinatorState: successorState,
            terminalReason: terminalReason
        )
        guard successorCheckpoint.canonicalEncodedByteCount
                <= basis.job.budget.maxEncodedBytes else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        return ReconstructionJobCommitPlan(
            successorRevision: successorRevision,
            acceptedEvidenceCount: 0,
            disposition: disposition,
            mutation: ReconstructionCheckpointMutation(
                jobID: basis.job.jobID,
                expectedParentCheckpointID: basis.checkpoint.checkpointID,
                expectedParentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
                expectedParentRevision: basis.checkpoint.revision,
                evidence: [],
                evidenceRelations: [],
                evidenceGaps: [],
                toolReceipts: [],
                modelReceipts: [],
                finalResults: [],
                newTasks: newTasks,
                taskTransitions: transitions,
                freshnessAuthority: freshnessAuthority,
                successorCheckpoint: successorCheckpoint,
                successorPauseContext: successorPauseContext
            )
        )
    }

    private static func applying(
        _ transitions: [ReconstructionTaskTransition],
        to tasks: [ReconstructionTaskRecord]
    ) -> [ReconstructionTaskRecord] {
        let transitionsByID = Dictionary(uniqueKeysWithValues: transitions.map {
            ($0.taskID, $0)
        })
        return tasks.map { task in
            guard let transition = transitionsByID[task.identity.taskID] else { return task }
            return ReconstructionTaskRecord(
                identity: task.identity,
                state: transition.successorState,
                diagnostic: transition.diagnostic,
                decompileBackend: transition.decompileBackend
            )
        }
    }

    /// Validate the complete catalog before scheduling or truncating any work. Focus is immutable
    /// job authority, not a request to manufacture a boundary or infer tasks from objective text.
    private static func orderedFunctionCoordinates(
        projection: ReconstructionTransientAnalysisProjection,
        focus: ReconstructionSubjectCoordinate?
    ) throws -> [ReconstructionFunctionCoordinate] {
        let ranges = projection.functionCatalog.map { "\($0.startAddress):\($0.endAddress)" }
        guard Set(ranges).count == ranges.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        var coordinates = try projection.functionCatalog.map { function in
            let expectedID = ReconstructionStableImageAuthority.stableFunctionID(
                image: projection.image,
                analysisFingerprintSHA256: projection.analysisFingerprintSHA256,
                startAddress: function.startAddress,
                endAddressExclusive: function.endAddress,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion
            )
            guard function.id == expectedID, function.startAddress < function.endAddress else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return try ReconstructionFunctionCoordinate(
                artifact: projection.artifact,
                image: projection.image,
                analysisFingerprintSHA256: projection.analysisFingerprintSHA256,
                startAddress: function.startAddress,
                endAddressExclusive: function.endAddress,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
                functionUUIDHint: nil,
                symbolHint: nil
            )
        }
        guard case .function(let selected)? = focus,
              selected.artifact == projection.artifact,
              selected.image == projection.image else {
            // Unrelated images retain deterministic general coverage, even at the same address.
            return coordinates
        }
        guard selected.analysisFingerprintSHA256 == projection.analysisFingerprintSHA256,
              let selectedIndex = coordinates.firstIndex(of: selected) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let selectedCoordinate = coordinates.remove(at: selectedIndex)
        coordinates.insert(selectedCoordinate, at: 0)
        return coordinates
    }

    private static func imageCoordinate(
        _ projection: ReconstructionTransientAnalysisProjection
    ) throws -> ReconstructionImageCoordinate {
        try ReconstructionImageCoordinate(
            artifact: projection.artifact,
            image: projection.image,
            analysisFingerprintSHA256: projection.analysisFingerprintSHA256
        )
    }

    private static func adding(
        image: ReconstructionImageCoordinate,
        to authority: ReconstructionFreshnessAuthority
    ) throws -> ReconstructionFreshnessAuthority {
        var images = authority.currentImages
        guard !images.contains(where: {
            $0.artifact == image.artifact
                && $0.image == image.image
                && $0.analysisFingerprintSHA256 != image.analysisFingerprintSHA256
        }) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        if !images.contains(image) { images.append(image) }
        return try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: authority.corpusManifestSHA256,
            currentArtifacts: authority.currentArtifacts,
            currentImages: images,
            currentFacetFingerprints: authority.currentFacetFingerprints
        )
    }

    private static func makeTask(
        jobID: UUID,
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?,
        dependencies: [UUID],
        operationContractIdentity: String? = nil
    ) throws -> ReconstructionTaskRecord {
        let normalizedDependencies = ReconstructionValidation.sortedUUIDs(dependencies)
        let defaultContract = switch kind {
        case .retrieveEvidence:
            ReconstructionProductionTaskContract.evidenceQuery
        case .modelRound:
            ReconstructionProductionTaskContract.modelRound
        case .checkpoint:
            ReconstructionProductionTaskContract.checkpoint
        default:
            "reconstruction.\(kind.rawValue).v1"
        }
        let contract = operationContractIdentity ?? defaultContract
        let taskID = try deterministicTaskID(
            jobID: jobID,
            kind: kind,
            subject: subject,
            dependencies: normalizedDependencies,
            contract: contract
        )
        return ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: taskID,
                jobID: jobID,
                kind: kind,
                subject: subject,
                dependencyTaskIDs: normalizedDependencies,
                operationContractIdentity: contract
            ),
            state: .pending,
            diagnostic: nil
        )
    }

    private static func makeRegularModelLeafTasks(
        jobID: UUID,
        dependencies: [UUID]
    ) throws -> [ReconstructionTaskRecord] {
        let retrieve = try makeTask(
            jobID: jobID,
            kind: .retrieveEvidence,
            subject: nil,
            dependencies: dependencies
        )
        let model = try makeTask(
            jobID: jobID,
            kind: .modelRound,
            subject: nil,
            dependencies: [retrieve.identity.taskID]
        )
        let checkpoint = try makeTask(
            jobID: jobID,
            kind: .checkpoint,
            subject: nil,
            dependencies: [model.identity.taskID]
        )
        return [retrieve, model, checkpoint]
    }

    private static func makeFinalSynthesisLeafTasks(
        jobID: UUID,
        dependencies: [UUID]
    ) throws -> [ReconstructionTaskRecord] {
        let model = try makeTask(
            jobID: jobID,
            kind: .modelRound,
            subject: nil,
            dependencies: dependencies,
            operationContractIdentity: ReconstructionProductionTaskContract.finalSynthesis
        )
        let checkpoint = try makeTask(
            jobID: jobID,
            kind: .checkpoint,
            subject: nil,
            dependencies: [model.identity.taskID]
        )
        return [model, checkpoint]
    }

    private struct TaskIDPreimage: Encodable {
        let domain: String
        let jobID: UUID
        let kind: ReconstructionTaskKind
        let subject: ReconstructionSubjectCoordinate?
        let dependencies: [UUID]
        let contract: String
    }

    private static func deterministicTaskID(
        jobID: UUID,
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?,
        dependencies: [UUID],
        contract: String
    ) throws -> UUID {
        nameDerivedUUID(try ReconstructionCanonicalJSON.encode(TaskIDPreimage(
            domain: taskIdentityDomain,
            jobID: jobID,
            kind: kind,
            subject: subject,
            dependencies: dependencies,
            contract: contract
        )))
    }

    private static func deterministicCheckpointID(
        jobID: UUID,
        parentCheckpointID: UUID,
        successorRevision: UInt64
    ) -> UUID {
        var preimage = Data(checkpointIdentityDomain.utf8)
        preimage.append(0)
        preimage.append(contentsOf: jobID.uuidString.lowercased().utf8)
        preimage.append(0)
        preimage.append(contentsOf: parentCheckpointID.uuidString.lowercased().utf8)
        preimage.append(0)
        var revision = successorRevision.bigEndian
        withUnsafeBytes(of: &revision) { preimage.append(contentsOf: $0) }
        return nameDerivedUUID(preimage)
    }

    private static func nameDerivedUUID(_ preimage: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: preimage).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func taskIDs(
        state: ReconstructionTaskState,
        in tasks: [ReconstructionTaskRecord]
    ) -> [UUID] {
        tasks.filter { $0.state == state }.map(\.identity.taskID)
    }

    private static func batchLeafTaskIDs(_ tasks: [ReconstructionTaskRecord]) -> [UUID] {
        let batch = tasks.filter { isBatchTask($0.identity.kind) && $0.identity.kind != .executeSource
            && !($0.identity.kind == .decompileMacScope && $0.identity.dependencyTaskIDs.count == 2) }
        let dependedUpon = Set(batch.flatMap(\.identity.dependencyTaskIDs))
        return ReconstructionValidation.sortedUUIDs(batch.compactMap { task in
            dependedUpon.contains(task.identity.taskID) ? nil : task.identity.taskID
        })
    }

    private static func subjectImage(
        _ subject: ReconstructionSubjectCoordinate
    ) -> ReconstructionImageCoordinate? {
        switch subject {
        case .artifact:
            return nil
        case .image(let image):
            return image
        case .function(let function):
            return try? ReconstructionImageCoordinate(
                artifact: function.artifact,
                image: function.image,
                analysisFingerprintSHA256: function.analysisFingerprintSHA256
            )
        }
    }

    private static func taskContractIsValid(
        _ identity: ReconstructionTaskIdentity
    ) -> Bool {
        switch identity.kind {
        case .retrieveEvidence:
            identity.operationContractIdentity == ReconstructionProductionTaskContract.evidenceQuery
        case .modelRound:
            identity.operationContractIdentity == ReconstructionProductionTaskContract.modelRound
                || identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.finalSynthesis
                || identity.operationContractIdentity == ReconstructionProductionTaskContract.sourceRevision
        case .checkpoint:
            identity.operationContractIdentity == ReconstructionProductionTaskContract.checkpoint
        case .executeSource:
            identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle
                || identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate
        default:
            identity.operationContractIdentity == "reconstruction.\(identity.kind.rawValue).v1"
        }
    }

    private static func isBatchTask(_ kind: ReconstructionTaskKind) -> Bool {
        switch kind {
        case .ingest, .classify, .discoverRelations, .loadBinary, .indexImage,
             .enumerateFunctions, .decompileNative, .decompileMacScope,
             .compareDecompilers, .executeSource:
            true
        case .retrieveEvidence, .modelRound, .checkpoint:
            false
        }
    }
}
