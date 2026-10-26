import Foundation
import XCTest
@testable import MacScope

final class ReconstructionProductionSourceReceiptTests: XCTestCase {
    func testSourcePlanWritesActualEvidenceReceiptAndFinalCheckpointTogether() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let authored = try await fixture.authorSource()
        let mutation = try XCTUnwrap(authored.plan.mutation)
        let record = try XCTUnwrap(mutation.evidence.first)
        XCTAssertEqual(mutation.evidence.count, 1)
        XCTAssertEqual(mutation.modelReceipts.count, 1)
        XCTAssertTrue(mutation.toolReceipts.isEmpty)
        XCTAssertTrue(mutation.finalResults.isEmpty)
        XCTAssertEqual(record.creatingTaskID, fixture.model.identity.taskID)
        XCTAssertEqual(record.creatingCheckpointID, mutation.successorCheckpoint.checkpointID)
        XCTAssertEqual(record.modelReceiptID, mutation.modelReceipts.first?.receiptID)
        XCTAssertEqual(mutation.modelReceipts.first?.acceptedEvidenceIDs, [record.evidenceID])
        XCTAssertEqual(mutation.modelReceipts.first?.requestIdentitySHA256,
            try ReconstructionCanonicalJSON.sha256(of: authored.request))
        XCTAssertEqual(mutation.modelReceipts.first?.producer.protocolIdentity,
            Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest)
        XCTAssertEqual(authored.revision.requestBinding?.canonicalRequestBytes,
            try ReconstructionCanonicalJSON.encode(authored.request))
        XCTAssertEqual(authored.revision.status, .proposed)
        XCTAssertEqual(authored.plan.disposition, .continue)
        XCTAssertNotEqual(mutation.successorCheckpoint.evidenceFrontierSHA256,
            fixture.basis.checkpoint.evidenceFrontierSHA256)
        XCTAssertEqual(try ReconstructionSourceRevisionEvidence.validate(record: record, context: authored.context), authored.revision)
    }

    func testReceiptWriterRejectsTerminalRequestSubstitutionAndUndeliveredCitation() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        do {
            _ = try await fixture.authorSource(terminalCheckpointRevision: 99)
            XCTFail("Stale terminal authority must not produce a mutation")
        } catch { }
        do {
            _ = try await fixture.authorSource(candidateEvidenceIDs: [ProductionSourceOwnerFixture.id(999)])
            XCTFail("An undelivered citation must not be accepted")
        } catch { }
    }

    func testRepairRevalidatesParentThroughItsOwnOriginalRequestAndCheckpoint() async throws {
        let first = try ProductionSourceOwnerFixture.make()
        let authored = try await first.authorSource()
        let successor = try first.successor(from: authored, nextModelNumber: 40)
        let request = try successor.request(parentSHA256: authored.revision.revisionSHA256)
        let captured = try ReconstructionProductionSourceAuthority.capture(request: request, basis: successor.basis)
        XCTAssertEqual(captured.authority.currentRevision, authored.revision)
        XCTAssertEqual(captured.priorRecords.count, 1)
        let original = try XCTUnwrap(captured.priorContexts.first)
        XCTAssertEqual(original.expectedRequestIdentitySHA256,
            try ReconstructionCanonicalJSON.sha256(of: authored.request))
        XCTAssertEqual(original.admissionAuthority.evidenceFrontierSHA256, first.basis.evidenceCut.frontierSHA256)
        XCTAssertNotEqual(original.admissionAuthority.evidenceFrontierSHA256, request.evidenceFrontierSHA256)
        XCTAssertEqual(original.checkpoint.checkpointID, authored.context.checkpoint.checkpointID)
        XCTAssertEqual(try ReconstructionSourceRevisionEvidence.validate(record: captured.priorRecords[0], context: original), authored.revision)
        let missingOriginal = try successor.replacingHistory(successor.basis.checkpointHistory.filter {
            $0.checkpointID != first.basis.checkpoint.checkpointID
        })
        XCTAssertThrowsError(try ReconstructionProductionSourceAuthority.capture(request: request, basis: missingOriginal.basis))
    }

    func testSecondRevisionUsesSameOracleAndThirdRevisionIsRejected() async throws {
        let first = try ProductionSourceOwnerFixture.make()
        let firstAuthored = try await first.authorSource()
        let second = try first.successor(from: firstAuthored, nextModelNumber: 40)
        let secondAuthored = try await second.authorSource(parentSHA256: firstAuthored.revision.revisionSHA256)
        XCTAssertEqual(secondAuthored.revision.parentRevisionSHA256, firstAuthored.revision.revisionSHA256)
        XCTAssertEqual(secondAuthored.revision.oracleSuiteSHA256, firstAuthored.revision.oracleSuiteSHA256)
        let third = try second.successor(from: secondAuthored, nextModelNumber: 50)
        XCTAssertThrowsError(try third.request(parentSHA256: secondAuthored.revision.revisionSHA256))
    }
}

extension ProductionSourceOwnerFixture {
    struct Authored {
        let plan: ReconstructionJobCommitPlan
        let request: ReconstructionSourceRevisionRequest
        let revision: ReconstructionSourceRevision
        let context: ReconstructionSourceRevisionEvidence.Context
    }
    func authorSource(parentSHA256: String? = nil, terminalCheckpointRevision: UInt64? = nil,
                      candidateEvidenceIDs: [UUID]? = nil) async throws -> Authored {
        let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
            macScopeBuildIdentity: Self.hash("build"), macScopeSourceIdentity: Self.hash("source"),
            operationIdentity: ReconstructionSourceRevisionEvidence.operationID,
            registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest, toolchainIdentity: "17A123"))
        let builder = try ReconstructionProductionPreparedRoundBuilder(evidenceQueryProducer:
            Self.producer(ReconstructionOperationID.evidenceQuery.rawValue))
        let prepared = try await builder.makePreparedRound(from: basis)
        let request = try XCTUnwrap(prepared.sourceRevisionRequest)
        XCTAssertEqual(request.parentRevisionSHA256, parentSHA256)
        let cut = ReconstructionProductionCommittedRoundCut(snapshot: basis.snapshot,
            parentCheckpointID: basis.checkpoint.checkpointID, parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            prepared: prepared, batchTerminalResults: [])
        let transitions: [ReconstructionTaskTransition] = [
            .init(taskID: model.identity.taskID, expectedState: .running, successorState: .completed, diagnostic: nil),
            .init(taskID: sourceCheckpoint.identity.taskID, expectedState: .pending, successorState: .completed, diagnostic: nil)]
        let base = try receiptFreeSourceBasePlan(transitions: transitions)
        let terminal = ReconstructionTerminalReceipt(requestID: Self.id(200 + Int(basis.checkpoint.revision)),
            jobID: basis.job.jobID, checkpointRevision: terminalCheckpointRevision ?? basis.checkpoint.revision,
            roundID: prepared.roundID, status: .completed)
        let requestAuthority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: terminal.requestID,
            request: .sourceRevision(request), terminalReceipt: terminal)
        let candidate = ReconstructionSourceRevisionCandidate(profileID: ReconstructionSourceRevision.profileID,
            parentRevisionSHA256: parentSHA256, sourceText: "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }\n",
            evidenceIDs: candidateEvidenceIDs ?? request.context.evidenceIDs)
        let lease = MacScope.Phase2ReadyInferenceLease(providerRevision: 1,
            configuration: try .init(profileID: Self.id(201), generation: 1, endpointOrigin: "http://127.0.0.1:1234",
                model: "controlled-model", maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 60_000), observedModelInventorySHA256: Self.hash("inventory"))
        let plan = try await author.makeSourceCommitPlan(cut: cut, basis: basis, basePlan: base, lease: lease,
            requestAuthority: requestAuthority, source: .init(candidate: candidate,
                usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal))
        let mutation = try XCTUnwrap(plan.mutation)
        let record = try XCTUnwrap(mutation.evidence.first)
        let captured = try ReconstructionProductionSourceAuthority.capture(request: request, basis: basis)
        let completed = ReconstructionTaskRecord(identity: model.identity, state: .completed, diagnostic: nil)
        let context = ReconstructionSourceRevisionEvidence.Context(admissionAuthority: captured.authority,
            task: completed, checkpoint: mutation.successorCheckpoint, modelReceipt: try XCTUnwrap(mutation.modelReceipts.first),
            expectedRequestIdentitySHA256: requestAuthority.requestIdentitySHA256, committedEvidenceCut: basis.evidenceCut.records,
            committedPriorRevisionRecords: captured.priorRecords, priorRevisionContexts: captured.priorContexts)
        return .init(plan: plan, request: request,
            revision: try ReconstructionSourceRevisionEvidence.validate(record: record, context: context), context: context)
    }

    // Keep this fixture at the receipt-author boundary. The production planner owns scheduling
    // evaluation work; this base contains only the source model/checkpoint completions under test.
    private func receiptFreeSourceBasePlan(transitions: [ReconstructionTaskTransition]) throws -> ReconstructionJobCommitPlan {
        let transitionsByID = Dictionary(uniqueKeysWithValues: transitions.map { ($0.taskID, $0) })
        let tasks = basis.tasks.map { task -> ReconstructionTaskRecord in
            guard let transition = transitionsByID[task.identity.taskID] else { return task }
            XCTAssertEqual(task.state, transition.expectedState)
            return .init(identity: task.identity, state: transition.successorState, diagnostic: transition.diagnostic)
        }
        let checkpoint = try Self.checkpoint(id: Self.id(100 + Int(basis.checkpoint.revision)),
            revision: basis.checkpoint.revision + 1, parent: basis.checkpoint, manifest: basis.manifest,
            frontier: basis.evidenceCut.frontierSHA256, tasks: tasks,
            modelReceipts: basis.modelReceipts, toolReceipts: basis.toolReceipts, jobID: basis.job.jobID)
        let mutation = ReconstructionCheckpointMutation(jobID: basis.job.jobID,
            expectedParentCheckpointID: basis.checkpoint.checkpointID,
            expectedParentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            expectedParentRevision: basis.checkpoint.revision, evidence: [], evidenceRelations: [],
            toolReceipts: [], modelReceipts: [], taskTransitions: transitions,
            freshnessAuthority: basis.freshnessAuthority, successorCheckpoint: checkpoint)
        return .init(successorRevision: checkpoint.revision, acceptedEvidenceCount: 0,
            disposition: .continue, mutation: mutation)
    }

    func successor(from authored: Authored, nextModelNumber: Int) throws -> Self {
        let mutation = try XCTUnwrap(authored.plan.mutation)
        var tasks = basis.tasks.map { task -> ReconstructionTaskRecord in
            guard task.identity.taskID == model.identity.taskID || task.identity.taskID == sourceCheckpoint.identity.taskID else { return task }
            return .init(identity: task.identity, state: .completed, diagnostic: nil)
        }
        let nextModel = try Self.task(nextModelNumber, jobID: basis.job.jobID, kind: .modelRound,
            subject: .function(function), dependencies: [sourceCheckpoint.identity.taskID], state: .running,
            contract: ReconstructionSourceRevisionEvidence.taskContract)
        let nextCheckpoint = try Self.task(nextModelNumber + 1, jobID: basis.job.jobID, kind: .checkpoint,
            dependencies: [nextModel.identity.taskID], state: .pending)
        tasks += [nextModel, nextCheckpoint]
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: Self.id(1))
        let history = basis.checkpointHistory + [basis.checkpoint, mutation.successorCheckpoint]
        let nextBasis = try Self.rebuild(foundation: foundation, tasks: tasks,
            records: basis.evidenceCut.records + mutation.evidence,
            modelReceipts: basis.modelReceipts + mutation.modelReceipts, toolReceipts: basis.toolReceipts,
            history: history, function: function, revision: mutation.successorCheckpoint.revision + 1,
            checkpointID: Self.id(nextModelNumber + 2), parent: mutation.successorCheckpoint)
        return .init(basis: nextBasis, function: function, oracle: oracle, model: nextModel, sourceCheckpoint: nextCheckpoint)
    }
    func replacingHistory(_ history: [ReconstructionCheckpoint]) throws -> Self {
        let b = basis
        let altered = try ReconstructionProductionRoundBasis(workspaceID: b.workspaceID, project: b.project,
            manifest: b.manifest, job: b.job, checkpoint: b.checkpoint, tasks: b.tasks,
            toolReceipts: b.toolReceipts, modelReceipts: b.modelReceipts, taskCompletionAuthorities: b.taskCompletionAuthorities,
            attachmentSources: b.attachmentSources, evidenceCut: b.evidenceCut, freshnessAuthority: b.freshnessAuthority,
            snapshot: b.snapshot, checkpointHistory: history)
        return .init(basis: altered, function: function, oracle: oracle, model: model, sourceCheckpoint: sourceCheckpoint)
    }
}

extension ReconstructionProductionSourceReceiptTests {
    func testObservationProjectionPreservesLegacyMutationAndBindsFinalRound() async throws {
        let fixture = try await ObservationProjectionFixture.make()
        let before = try fixture.durableBytes(fixture.legacyPlan)
        let diagnostic = try XCTUnwrap(fixture.plan.observationDiagnostics.first)
        guard case .compared(let original, let candidate, let comparison) = diagnostic.result(for: diagnostic.binding) else {
            return XCTFail("Expected exact final evidence to project")
        }
        XCTAssertTrue(comparison.isEquivalent)
        XCTAssertEqual(original.cases.map(\.input), fixture.oracle.inputs)
        XCTAssertEqual(candidate.cases.map(\.input), fixture.oracle.inputs)
        XCTAssertEqual(diagnostic.binding.successorCheckpointSHA256, fixture.context.checkpoint.canonicalSHA256)
        XCTAssertEqual(diagnostic.binding.successorEvidenceFrontierSHA256, fixture.context.checkpoint.evidenceFrontierSHA256)
        XCTAssertEqual(diagnostic.binding.evaluationEvidenceID, fixture.evidenceID)
        XCTAssertEqual(try fixture.durableBytes(fixture.plan), before)
        let current = try XCTUnwrap(fixture.plan.mutation)
        let legacy = try XCTUnwrap(fixture.legacyPlan.mutation)
        XCTAssertEqual(current.taskTransitions, legacy.taskTransitions)
        XCTAssertEqual(current.newTasks, legacy.newTasks)
        XCTAssertEqual(current.evidenceRelations, legacy.evidenceRelations)
        XCTAssertEqual(current.evidenceGaps, legacy.evidenceGaps)
        XCTAssertEqual(fixture.plan.acceptedEvidenceCount, fixture.legacyPlan.acceptedEvidenceCount)
        XCTAssertEqual(fixture.plan.disposition, fixture.legacyPlan.disposition)
        XCTAssertEqual(fixture.plan.observationDiagnostics.count, 1)
        XCTAssertTrue(fixture.legacyPlan.observationDiagnostics.isEmpty)
        XCTAssertNil(fixture.project(basis: fixture.unscopedBasis))
    }

    func testObservationProjectionRefusesStaleAndForeignAuthority() async throws {
        let fixture = try await ObservationProjectionFixture.make()
        let stale = try fixture.scopedBasis(additionalEvidenceID: ProductionSourceOwnerFixture.id(999))
        let refused = try XCTUnwrap(fixture.project(basis: stale))
        guard case .unavailable(.staleScope(let ids)) = refused.result(for: refused.binding) else {
            return XCTFail("An unavailable scope dependency must remain stale")
        }
        XCTAssertEqual(ids, [ProductionSourceOwnerFixture.id(999)])
        let foreign = try ProductionSourceOwnerFixture.alter(fixture.context.sourceRecord) {
            $0["evidenceID"] = ProductionSourceOwnerFixture.id(998).uuidString
        }
        let context = fixture.contextReplacing(sourceRecord: foreign)
        let rejected = try XCTUnwrap(fixture.project(context: context))
        guard case .unavailable(.foreignSourceOrOracle) = rejected.result(for: rejected.binding) else {
            return XCTFail("A source outside this committed cut must be refused")
        }
        let oldContext = fixture.contextReplacing(checkpoint: fixture.basis.checkpoint)
        let old = try XCTUnwrap(fixture.project(context: oldContext))
        guard case .unavailable(.invalidFinalCheckpoint) = old.result(for: old.binding) else {
            return XCTFail("A parent or provisional context cannot validate final evidence")
        }
        let foreignCut = ReconstructionProductionCommittedRoundCut(snapshot: fixture.cut.snapshot,
            parentCheckpointID: fixture.cut.parentCheckpointID,
            parentCheckpointSHA256: ProductionSourceOwnerFixture.hash("foreign-parent"),
            prepared: fixture.cut.prepared, batchTerminalResults: fixture.cut.batchTerminalResults)
        let foreignRound = try XCTUnwrap(fixture.project(cut: foreignCut))
        guard case .unavailable(.invalidRoundBinding) = foreignRound.result(for: foreignRound.binding) else {
            return XCTFail("A foreign committed checkpoint must be refused")
        }
        let diagnostic = try XCTUnwrap(fixture.project())
        let other = try XCTUnwrap(fixture.project(basis: stale))
        guard case .unavailable(.differentRound) = diagnostic.result(for: other.binding) else {
            return XCTFail("A diagnostic may only be consumed with its complete originating binding")
        }
    }

    func testObservationProjectionPreservesAbsentAndFailedOutcomes() async throws {
        let fixture = try await ObservationProjectionFixture.make(buildRejected: true)
        let diagnostic = try XCTUnwrap(fixture.project())
        guard case .compared(_, let candidate, let comparison) = diagnostic.result(for: diagnostic.binding) else {
            return XCTFail("A completed negative evaluation still projects absent observations")
        }
        XCTAssertTrue(candidate.cases.allSatisfy { $0.effects.isEmpty && $0.completeness == .absent(.notExecuted) })
        XCTAssertTrue(comparison.cases.allSatisfy { $0.verdict == .incomplete(.candidate) })
        XCTAssertFalse(comparison.isEquivalent)
        let failed = try await fixture.failedPlan()
        XCTAssertTrue(failed.observationDiagnostics.isEmpty)
        XCTAssertTrue(try XCTUnwrap(failed.mutation).evidence.isEmpty)
        XCTAssertEqual(failed.mutation?.toolReceipts.first?.terminalState, .failed)
    }
}

/// Pure synthetic evidence-owner fixture. It never invokes a native worker, compiler, inference
/// provider or database; it exercises projection against independently supplied owner contexts.
private struct ObservationProjectionFixture {
    let unscopedBasis: ReconstructionProductionRoundBasis
    let basis: ReconstructionProductionRoundBasis
    let cut: ReconstructionProductionCommittedRoundCut
    let plan: ReconstructionJobCommitPlan
    let legacyPlan: ReconstructionJobCommitPlan
    let context: ReconstructionSourceEvaluationEvidence.Context
    let evidenceID: UUID
    let oracle: ReconstructionSourceOracle

    func project(basis: ReconstructionProductionRoundBasis? = nil,
                 context: ReconstructionSourceEvaluationEvidence.Context? = nil,
                 cut: ReconstructionProductionCommittedRoundCut? = nil)
        -> ReconstructionProductionObservationDiagnostic? {
        ReconstructionProductionObservationProjection.project(basis: basis ?? self.basis,
            cut: cut ?? self.cut, plan: plan, evaluationEvidenceID: evidenceID, context: context ?? self.context)
    }

    func contextReplacing(sourceRecord: ReconstructionEvidenceRecord? = nil,
                          checkpoint: ReconstructionCheckpoint? = nil) -> ReconstructionSourceEvaluationEvidence.Context {
        .init(sourceRecord: sourceRecord ?? context.sourceRecord, sourceContext: context.sourceContext,
            oracleRecord: context.oracleRecord, oracleContext: context.oracleContext,
            task: context.task, checkpoint: checkpoint ?? context.checkpoint, toolReceipt: context.toolReceipt,
            expectedRequestIdentitySHA256: context.expectedRequestIdentitySHA256,
            expectedProducer: context.expectedProducer, expectedCapturedOutcome: context.expectedCapturedOutcome)
    }

    func scopedBasis(additionalEvidenceID: UUID? = nil) throws -> ReconstructionProductionRoundBasis {
        try Self.scoped(unscopedBasis, oracle: oracle, additionalEvidenceID: additionalEvidenceID)
    }

    private static func scoped(_ b: ReconstructionProductionRoundBasis, oracle: ReconstructionSourceOracle,
                               additionalEvidenceID: UUID? = nil) throws -> ReconstructionProductionRoundBasis {
        let oracleID = ProductionSourceOwnerFixture.id(26)
        let scope = try ReconstructionFeatureScope.make(projectID: b.project.projectID, jobID: b.job.jobID,
            feature: oracle.function, acceptedEvidenceIDs: b.evidenceCut.records.map(\.evidenceID) + [additionalEvidenceID].compactMap { $0 },
            scenarios: [.init(oracleEvidenceID: oracleID, suiteSHA256: oracle.suiteSHA256,
                caseCount: oracle.inputs.count, role: .development)], dependencies: [],
            dependencyBasisEvidenceIDs: [oracleID], observationContract: .scalarU32ReturnV1,
            admittedAtCheckpointID: b.checkpoint.checkpointID, admittedAtCheckpointRevision: b.checkpoint.revision,
            admittedAtCheckpointSHA256: b.checkpoint.canonicalSHA256, evidenceFrontierSHA256: b.evidenceCut.frontierSHA256)
        let j = b.job
        let job = try ReconstructionJobRecord(jobID: j.jobID, reconstructionProjectID: j.reconstructionProjectID,
            objective: j.objective, objectiveSHA256: j.objectiveSHA256,
            creationCorpusManifestSHA256: j.creationCorpusManifestSHA256, state: j.state,
            currentCheckpointID: j.currentCheckpointID, terminalReason: j.terminalReason, budget: j.budget,
            creationOrdinal: j.creationOrdinal ?? 1, pauseContext: j.pauseContext, focus: .function(oracle.function),
            sourceProfileID: ReconstructionSourceRevision.profileID, featureScope: scope)
        return try .init(workspaceID: b.workspaceID, project: b.project, manifest: b.manifest, job: job,
            checkpoint: b.checkpoint, tasks: b.tasks, toolReceipts: b.toolReceipts, modelReceipts: b.modelReceipts,
            taskCompletionAuthorities: b.taskCompletionAuthorities, attachmentSources: b.attachmentSources,
            evidenceCut: b.evidenceCut, freshnessAuthority: b.freshnessAuthority, snapshot: b.snapshot,
            checkpointHistory: b.checkpointHistory)
    }

    func failedPlan() async throws -> ReconstructionJobCommitPlan {
        let diagnostic = ReconstructionDiagnostic.sanitizing("Synthetic transport failure")
        let result = ReconstructionTerminalTaskResult(jobID: basis.job.jobID, taskID: context.task.identity.taskID,
            checkpointID: basis.checkpoint.checkpointID, checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256, outcome: .failed, failureDiagnostic: diagnostic)
        let failedCut = ReconstructionProductionCommittedRoundCut(snapshot: cut.snapshot,
            parentCheckpointID: cut.parentCheckpointID, parentCheckpointSHA256: cut.parentCheckpointSHA256,
            prepared: cut.prepared, batchTerminalResults: [result])
        let mutation = ReconstructionCheckpointMutation(jobID: basis.job.jobID,
            expectedParentCheckpointID: basis.checkpoint.checkpointID,
            expectedParentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            expectedParentRevision: basis.checkpoint.revision, evidence: [], evidenceRelations: [],
            toolReceipts: [], modelReceipts: [],
            taskTransitions: [.init(taskID: context.task.identity.taskID, expectedState: .running,
                successorState: .failed, diagnostic: diagnostic)], freshnessAuthority: basis.freshnessAuthority,
            successorCheckpoint: context.checkpoint)
        let base = ReconstructionJobCommitPlan(successorRevision: plan.successorRevision,
            acceptedEvidenceCount: 0, disposition: .continue, mutation: mutation)
        return try await Self.author().makeBatchCommitPlan(cut: failedCut, basis: basis, basePlan: base)
    }

    private static func author() -> ReconstructionProductionReceiptPlanAuthor {
        typealias F = ProductionSourceOwnerFixture
        return .init(modelProducerContext: .init(macScopeBuildIdentity: F.hash("build"),
            macScopeSourceIdentity: F.hash("source"), operationIdentity: ReconstructionSourceRevisionEvidence.operationID,
            registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest, toolchainIdentity: "17A123"))
    }

    func durableBytes(_ value: ReconstructionJobCommitPlan) throws -> [Data] {
        let mutation = try XCTUnwrap(value.mutation)
        return try [ReconstructionCanonicalJSON.encode(mutation.evidence),
            ReconstructionCanonicalJSON.encode(mutation.toolReceipts),
            ReconstructionCanonicalJSON.encode(mutation.modelReceipts),
            ReconstructionCanonicalJSON.encode(mutation.finalResults),
            ReconstructionCanonicalJSON.encode(mutation.successorCheckpoint)]
    }

    static func make(buildRejected: Bool = false) async throws -> Self {
        typealias F = ProductionSourceOwnerFixture
        let initial = try F.make()
        let source = try await initial.authorSource()
        let next = try initial.successor(from: source, nextModelNumber: 40)
        let task = try F.task(70, jobID: next.basis.job.jobID, kind: .executeSource,
            subject: .function(next.function), dependencies: [], state: .running,
            contract: ReconstructionSourceEvaluationEvidence.taskContract)
        let n = next.basis
        let b = try F.rebuild(foundation: ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: F.id(1)),
            tasks: n.tasks + [task], records: n.evidenceCut.records, modelReceipts: n.modelReceipts,
            toolReceipts: n.toolReceipts, history: n.checkpointHistory, function: next.function,
            revision: n.checkpoint.revision, checkpointID: n.checkpoint.checkpointID,
            parent: source.plan.mutation?.successorCheckpoint)
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: F.producer(ReconstructionOperationID.evidenceQuery.rawValue)).makePreparedRound(from: b)
        let tools = ReconstructionSourceExecutionWorkflow.ToolAuthority(compilerPath: "/synthetic/clang",
            sdkRootPath: "/synthetic/sdk", toolchainRootPath: "/synthetic/toolchain",
            runnerSHA256: F.hash("runner"), compilerSHA256: initial.oracle.execution.compilerSHA256,
            sdkSettingsSHA256: initial.oracle.execution.sdkIdentitySHA256)
        let session = F.id(73)
        let operations: [MacScope.Phase2SourceExecutionOperation] = buildRejected ? [.inspect, .compile] : [.inspect, .compile, .behavior]
        let phases = operations.enumerated().map { index, operation -> ReconstructionSourceExecutionWorkflow.Phase in
            let request = MacScope.Phase2SourceExecutionRequest(requestID: F.id(80 + index), sessionID: session,
                operation: operation, sourceAuthority: .admittedRevision,
                stageRootPath: TestWorkRoot.authorityPath("synthetic-observation-projection"),
                revisionSHA256: source.revision.revisionSHA256, sourceSHA256: source.revision.sourceSHA256,
                harnessSHA256: initial.oracle.execution.harnessSHA256, compilerPath: tools.compilerPath,
                sdkRootPath: tools.sdkRootPath, toolchainRootPath: tools.toolchainRootPath,
                runnerSHA256: tools.runnerSHA256, compilerSHA256: tools.compilerSHA256,
                sdkSettingsSHA256: tools.sdkSettingsSHA256)
            let terminal = MacScope.Phase2SourceExecutionTerminal(kind: .exited,
                status: buildRejected && operation == .compile ? 1 : 0)
            let response = MacScope.Phase2SourceExecutionResponse(requestID: request.requestID, sessionID: session,
                operation: operation, status: .completed, failure: nil, terminal: terminal, diagnostics: Data(),
                peakGroupResidentBytes: 1_024, sampledProcessIDs: [123], elapsedSeconds: 0.01,
                cleanup: .init(sessionID: session, requestID: request.requestID, processIdentifier: 123,
                    observedProcessAbsent: true, outcome: terminal))
            return .init(request: request, response: response, transportError: nil)
        }
        let outcome = ReconstructionSourceExecutionWorkflow.Outcome(
            sourceAuthority: .admittedRevision(revisionSHA256: source.revision.revisionSHA256),
            function: next.function, sourceSHA256: source.revision.sourceSHA256,
            harnessSHA256: initial.oracle.execution.harnessSHA256, toolAuthority: tools,
            oracleSuiteSHA256: initial.oracle.suiteSHA256, phases: phases,
            inspection: .init(device: 1, inode: 2, byteCount: 1, sha256: F.hash("inspection")),
            astAdmission: .init(sourceSHA256: source.revision.sourceSHA256, profileID: source.revision.profileID,
                astSHA256: F.hash("inspection"), functionName: "reconstructed", nodeCount: 1),
            executable: buildRejected ? nil : .init(device: 1, inode: 3, byteCount: 1, sha256: F.hash("executable")),
            observations: buildRejected ? [] : zip(initial.oracle.inputs, initial.oracle.outputs).map {
                .init(input: $0.0, output: $0.1)
            }, mismatches: [], failure: buildRejected ? .phaseRejected(.compile) : nil)
        let terminal = ReconstructionTerminalTaskResult(jobID: b.job.jobID, taskID: task.identity.taskID,
            checkpointID: b.checkpoint.checkpointID, checkpointRevision: b.checkpoint.revision,
            corpusManifestSHA256: b.manifest.canonicalSHA256, outcome: .completed, sourceExecution: .evaluation(outcome))
        let cut = ReconstructionProductionCommittedRoundCut(snapshot: b.snapshot,
            parentCheckpointID: b.checkpoint.checkpointID, parentCheckpointSHA256: b.checkpoint.canonicalSHA256,
            prepared: prepared, batchTerminalResults: [terminal])
        let completed = ReconstructionTaskRecord(identity: task.identity, state: .completed, diagnostic: nil)
        let tasks = b.tasks.map { $0.identity.taskID == task.identity.taskID ? completed : $0 }
        let provisional = try F.checkpoint(id: F.id(74), revision: b.checkpoint.revision + 1,
            parent: b.checkpoint, manifest: b.manifest, frontier: b.evidenceCut.frontierSHA256,
            tasks: tasks, modelReceipts: b.modelReceipts, toolReceipts: b.toolReceipts, jobID: b.job.jobID)
        let mutation = ReconstructionCheckpointMutation(jobID: b.job.jobID,
            expectedParentCheckpointID: b.checkpoint.checkpointID, expectedParentCheckpointSHA256: b.checkpoint.canonicalSHA256,
            expectedParentRevision: b.checkpoint.revision, evidence: [], evidenceRelations: [], toolReceipts: [], modelReceipts: [],
            taskTransitions: [.init(taskID: task.identity.taskID, expectedState: .running, successorState: .completed, diagnostic: nil)],
            freshnessAuthority: b.freshnessAuthority, successorCheckpoint: provisional)
        let basePlan = ReconstructionJobCommitPlan(successorRevision: provisional.revision,
            acceptedEvidenceCount: 0, disposition: .continue, mutation: mutation)
        let author = Self.author()
        let scoped = try scoped(b, oracle: initial.oracle)
        let legacy = try await author.makeBatchCommitPlan(cut: cut, basis: b, basePlan: basePlan)
        let plan = try await author.makeBatchCommitPlan(cut: cut, basis: scoped, basePlan: basePlan)
        let final = try XCTUnwrap(plan.mutation)
        let record = try XCTUnwrap(final.evidence.first)
        let receipt = try XCTUnwrap(final.toolReceipts.first)
        let oracle = try ReconstructionProductionSourceAuthority.oracleContext(function: next.function, basis: b)
        let context = ReconstructionSourceEvaluationEvidence.Context(
            sourceRecord: try XCTUnwrap(source.plan.mutation?.evidence.first), sourceContext: source.context,
            oracleRecord: oracle.record, oracleContext: oracle.context, task: completed,
            checkpoint: final.successorCheckpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: receipt.requestIdentitySHA256,
            expectedProducer: try author.makeSourceToolProducer(contract: ReconstructionSourceEvaluationEvidence.taskContract),
            expectedCapturedOutcome: try ReconstructionSourceEvaluationCapture.capture(outcome))
        XCTAssertNotEqual(provisional.canonicalSHA256, final.successorCheckpoint.canonicalSHA256)
        return .init(unscopedBasis: b, basis: scoped, cut: cut, plan: plan, legacyPlan: legacy,
            context: context, evidenceID: record.evidenceID, oracle: initial.oracle)
    }
}
