import Foundation
import XCTest
@testable import MacScope

final class ReconstructionProductionDynamicDAGTests: XCTestCase {
    /// Removing refresh scheduling/context admission, terminal result commits or package
    /// receipt retention must fail this joined production-owner regression.
    @MainActor
    func testImportedFocusedJobCoordinatorRefreshFinalSurvivesPhysicalPackageReopen() async throws {
        try await ReconstructionJoinedWorkflowTestFixture.run()
    }

    @MainActor
    func testFreshImportedJobAdmitsLoadAuthorityWithoutPreanalyzedWorkspace() async throws {
        try await ReconstructionJoinedWorkflowTestFixture.run(preanalyzedWorkspace: false)
    }

    func testRefreshGatesNextRoundUntilDurableBatchCompletion() async throws {
        let fixture = try await makeRefreshGraphFixture()
        try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            fixture.tasks, jobID: fixture.jobID, maximumTasks: 32)
        let pending = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder
            .pendingRegularModelFrontier(in: fixture.tasks))
        XCTAssertTrue(pending.retrieve.identity.dependencyTaskIDs.contains(fixture.refreshID))
        XCTAssertNil(try ReconstructionProductionRoundPlanBuilder
            .authorizedRegularModelFrontier(in: fixture.tasks))
        var forged = fixture.tasks.map { record in
            guard record.identity.taskID == pending.retrieve.identity.taskID
                || record.identity.taskID == pending.model.identity.taskID else { return record }
            return ReconstructionTaskRecord(identity: record.identity, state: .running, diagnostic: nil)
        }
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            forged, jobID: fixture.jobID, maximumTasks: 32))
        let refreshIndex = try XCTUnwrap(forged.firstIndex { $0.identity.taskID == fixture.refreshID })
        forged[refreshIndex] = .init(identity: forged[refreshIndex].identity,
            state: .completed, diagnostic: nil)
        XCTAssertNoThrow(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            forged, jobID: fixture.jobID, maximumTasks: 32))
    }

    func testRefreshGraphRejectsOrphanAndUnrelatedSuccessorDependency() async throws {
        let fixture = try await makeRefreshGraphFixture()
        let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder
            .pendingRegularModelFrontier(in: fixture.tasks))
        var forged = fixture.tasks
        let index = try XCTUnwrap(forged.firstIndex {
            $0.identity.taskID == frontier.retrieve.identity.taskID
        })
        let predecessor = try XCTUnwrap(frontier.retrieve.identity.dependencyTaskIDs.first {
            $0 != fixture.refreshID
        })
        let unrelated = try XCTUnwrap(forged.first { $0.identity.kind == .enumerateFunctions })
        for extraDependencies in [[], [unrelated.identity.taskID]] {
            forged[index] = try task(id: frontier.retrieve.identity.taskID,
                jobID: fixture.jobID, kind: .retrieveEvidence, subject: nil,
                dependencies: [predecessor] + extraDependencies, state: .pending,
                operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery)
            XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
                forged, jobID: fixture.jobID, maximumTasks: 32))
        }
    }

    private func makeRefreshGraphFixture() async throws -> (tasks: [ReconstructionTaskRecord],
        jobID: UUID, refreshID: UUID) {
        let fixture = try await makeActiveModelFixture()
        let inference = modelInference(fixture: fixture, disposition: .continue)
        let plan = try await fixture.builder.makeCommitPlan(cut: fixture.cut,
            lease: try modelLease(), requestAuthority: try roundRequestAuthority(fixture: fixture,
                terminalReceipt: inference.terminalReceipt), inference: inference, executions: [])
        let basis = try applying(plan: plan, to: fixture.basis)
        var tasks = basis.tasks
        let enumeration = try XCTUnwrap(tasks.first { $0.identity.kind == .enumerateFunctions })
        guard case .image(let image)? = enumeration.identity.subject else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let function = try ReconstructionFunctionCoordinate(artifact: image.artifact,
            image: image.image, analysisFingerprintSHA256: image.analysisFingerprintSHA256,
            startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
            functionUUIDHint: nil, symbolHint: nil)
        let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder
            .pendingRegularModelFrontier(in: tasks))
        let predecessor = try XCTUnwrap(frontier.retrieve.identity.dependencyTaskIDs.first)
        let refresh = try task(id: UUID(), jobID: basis.job.jobID, kind: .decompileMacScope,
            subject: .function(function), dependencies: [predecessor, enumeration.identity.taskID],
            state: .pending)
        let retrieveIndex = try XCTUnwrap(tasks.firstIndex {
            $0.identity.taskID == frontier.retrieve.identity.taskID
        })
        tasks[retrieveIndex] = try task(id: frontier.retrieve.identity.taskID,
            jobID: basis.job.jobID, kind: .retrieveEvidence, subject: nil,
            dependencies: [predecessor, refresh.identity.taskID], state: .pending,
            operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery)
        tasks.append(refresh)
        return (tasks, basis.job.jobID, refresh.identity.taskID)
    }

    func testLoadCompletionCreatesOnlyImageBoundIndexAndEnumerationTasks() async throws {
        let fixture = try makeLoadFixture()
        let plan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let mutation = try XCTUnwrap(plan?.mutation)

        XCTAssertEqual(mutation.newTasks.map(\.identity.kind), [.indexImage, .enumerateFunctions])
        XCTAssertTrue(mutation.newTasks.allSatisfy { task in
            if case .image = task.identity.subject { return true }
            return false
        })
        let index = try XCTUnwrap(mutation.newTasks.first { $0.identity.kind == .indexImage })
        let enumerate = try XCTUnwrap(
            mutation.newTasks.first { $0.identity.kind == .enumerateFunctions }
        )
        XCTAssertEqual(index.identity.dependencyTaskIDs, [fixture.terminalTaskID])
        XCTAssertEqual(enumerate.identity.dependencyTaskIDs, [index.identity.taskID])
    }

    func testDynamicGraphRejectsArtifactScopedIndexRegression() throws {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID],
            state: .completed
        )
        let load = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let invalidIndex = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
            subject: .artifact(artifact), dependencies: [load.identity.taskID], state: .pending
        )

        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder
            .validateDynamicTaskGraph(
                [ingest, classify, discover, load, invalidIndex],
                jobID: foundation.job.jobID,
                maximumTasks: 8
            ))
    }

    func testDynamicGraphRejectsCompareWithoutBothDecompilerDependencies() async throws {
        let fixture = try makeEnumerationFixture(maximumTasks: 16)
        let plan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let mutation = try XCTUnwrap(plan?.mutation)
        var tasks = fixture.basis.tasks + mutation.newTasks
        let compareIndex = try XCTUnwrap(tasks.firstIndex {
            $0.identity.kind == .compareDecompilers
        })
        let compare = tasks[compareIndex]
        let nativeID = try XCTUnwrap(tasks.first {
            $0.identity.kind == .decompileNative
        }?.identity.taskID)
        let invalidIdentity = try ReconstructionTaskIdentity.make(
            taskID: compare.identity.taskID,
            jobID: compare.identity.jobID,
            kind: compare.identity.kind,
            subject: compare.identity.subject,
            dependencyTaskIDs: [nativeID],
            operationContractIdentity: compare.identity.operationContractIdentity
        )
        tasks[compareIndex] = ReconstructionTaskRecord(
            identity: invalidIdentity,
            state: compare.state,
            diagnostic: compare.diagnostic
        )

        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder
            .validateDynamicTaskGraph(
                tasks,
                jobID: fixture.basis.job.jobID,
                maximumTasks: fixture.basis.job.budget.maxTasks
            ))
    }

    func testEnumerationExpansionDegradesAndPausesAtMaximumTaskBudget() async throws {
        let fixture = try makeEnumerationFixture(maximumTasks: 8)

        let preparedPlan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let plan = try XCTUnwrap(preparedPlan)
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(plan.disposition, .paused(.evidenceStalled))
        XCTAssertLessThanOrEqual(fixture.basis.tasks.count + mutation.newTasks.count, 8)
        XCTAssertTrue(mutation.taskTransitions.contains {
            $0.diagnostic?.text.contains("truncated by the task budget") == true
        })
    }

    func testCompletedDynamicBatchCreatesBrokerBoundModelLeafChain() async throws {
        let fixture = try makeEnumerationFixture(
            maximumTasks: 16,
            includesFunction: false
        )
        let plan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let tasks = try XCTUnwrap(plan?.mutation).newTasks

        XCTAssertEqual(tasks.map(\.identity.kind), [
            .retrieveEvidence, .modelRound, .checkpoint,
        ])
        let retrieve = try XCTUnwrap(tasks.first { $0.identity.kind == .retrieveEvidence })
        let model = try XCTUnwrap(tasks.first { $0.identity.kind == .modelRound })
        let checkpoint = try XCTUnwrap(tasks.first { $0.identity.kind == .checkpoint })
        XCTAssertEqual(
            retrieve.identity.operationContractIdentity,
            ReconstructionOperationID.evidenceQuery.rawValue
        )
        XCTAssertEqual(model.identity.dependencyTaskIDs, [retrieve.identity.taskID])
        XCTAssertEqual(checkpoint.identity.dependencyTaskIDs, [model.identity.taskID])
    }

    func testCompletedNonExecutableArtifactChainCreatesModelLeafWithoutLoad() async throws {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID],
            state: .pending
        )
        let basis = try makeBasis(
            foundation: foundation,
            tasks: [ingest, classify, discover],
            maximumTasks: 8,
            currentImages: []
        )
        let prepared = try ReconstructionProductionPreparedRoundBuilder
            .makeDirectCommitDescriptor(from: basis)
        let fixture = try registeredFixture(
            basis: basis,
            prepared: prepared,
            result: ReconstructionTerminalTaskResult(
                jobID: basis.job.jobID,
                taskID: discover.identity.taskID,
                checkpointID: basis.checkpoint.checkpointID,
                checkpointRevision: basis.checkpoint.revision,
                corpusManifestSHA256: basis.manifest.canonicalSHA256,
                outcome: .completed
            )
        )

        let plan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        XCTAssertEqual(try XCTUnwrap(plan?.mutation).newTasks.map(\.identity.kind), [
            .retrieveEvidence, .modelRound, .checkpoint,
        ])
    }

    func testPreparedEvidenceQueryExecutesThroughProductionBrokerContract() async throws {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID],
            state: .completed
        )
        let load = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let imageBinding = ReconstructionImageBinding(
            binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                occurrenceID: artifact.occurrenceID,
                selectedSliceIndex: nil
            ),
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let image = try ReconstructionImageCoordinate(
            artifact: artifact,
            image: imageBinding,
            analysisFingerprintSHA256: digest("a")
        )
        let index = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
            subject: .image(image), dependencies: [load.identity.taskID], state: .completed
        )
        let enumerate = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .enumerateFunctions,
            subject: .image(image), dependencies: [index.identity.taskID], state: .completed
        )
        let retrieve = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .retrieveEvidence,
            subject: nil,
            dependencies: [discover.identity.taskID, enumerate.identity.taskID],
            state: .running,
            operationContractIdentity: ReconstructionOperationID.evidenceQuery.rawValue
        )
        let model = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .modelRound,
            subject: nil, dependencies: [retrieve.identity.taskID], state: .running
        )
        let checkpoint = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .checkpoint,
            subject: nil, dependencies: [model.identity.taskID], state: .pending
        )
        let basis = try makeBasis(
            foundation: foundation,
            tasks: [
                ingest, classify, discover, load, index, enumerate,
                retrieve, model, checkpoint,
            ],
            maximumTasks: 16,
            currentImages: [image],
            focus: .artifact(artifact)
        )
        try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            basis.tasks,
            jobID: basis.job.jobID,
            maximumTasks: basis.job.budget.maxTasks
        )
        let producer = try evidenceQueryProducer()
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: producer
        ).makePreparedRound(from: basis)
        XCTAssertEqual(prepared.retrievalQuery.focus, .artifact(artifact))
        XCTAssertNil(prepared.retrievalQuery.subject)
        XCTAssertEqual(prepared.requests.first?.retrievalQuery?.focus, .artifact(artifact))
        XCTAssertNil(prepared.requests.first?.subject)
        XCTAssertEqual(prepared.projectorInput.producersByOperation, [
            .evidenceQuery: producer,
        ])
        let handles = try ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority,
            requests: prepared.requests
        )
        let handle = try XCTUnwrap(handles.first)
        let executions = try await ReconstructionToolBroker(
            projectors: [ReconstructionEvidenceToolProjector()]
        ).execute(
            selectedHandleIDs: [handle.handleID],
            offeredHandles: handles,
            input: prepared.projectorInput
        )

        XCTAssertEqual(executions.count, 1)
        XCTAssertEqual(executions[0].operationID, .evidenceQuery)
        XCTAssertEqual(executions[0].result.outcome, .success)
        XCTAssertEqual(executions[0].receipt.producer, producer)
    }

    func testContinueModelOutcomeCompletesCurrentTrioAndActivatesNextRevisionTrio()
        async throws
    {
        let fixture = try await makeActiveModelFixture()
        let inference = modelInference(fixture: fixture, disposition: .continue)
        let requestAuthority = try roundRequestAuthority(
            fixture: fixture,
            terminalReceipt: inference.terminalReceipt
        )
        let plan = try await fixture.builder.makeCommitPlan(
            cut: fixture.cut,
            lease: try modelLease(),
            requestAuthority: requestAuthority,
            inference: inference,
            executions: []
        )
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(plan.disposition, .continue)
        XCTAssertEqual(mutation.taskTransitions.map(\.successorState), [
            .completed, .completed, .completed,
        ])
        XCTAssertEqual(mutation.newTasks.map(\.identity.kind), [
            .retrieveEvidence, .modelRound, .checkpoint,
        ])
        let priorCheckpointTaskID = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .checkpoint
        }?.identity.taskID)
        let nextRetrieve = try XCTUnwrap(mutation.newTasks.first {
            $0.identity.kind == .retrieveEvidence
        })
        XCTAssertEqual(nextRetrieve.identity.dependencyTaskIDs, [priorCheckpointTaskID])

        let pendingBasis = try applying(plan: plan, to: fixture.basis)
        let activation = try await makePreInferenceFixture(basis: pendingBasis)
        let proposedActivationPlan = try await activation.builder.makePreInferenceCommitPlan(
            cut: activation.cut
        )
        let activationPlan = try XCTUnwrap(proposedActivationPlan)
        let activationMutation = try XCTUnwrap(activationPlan.mutation)
        XCTAssertEqual(
            Set(activationMutation.taskTransitions.map(\.taskID)),
            Set(mutation.newTasks.filter {
                $0.identity.kind == .retrieveEvidence || $0.identity.kind == .modelRound
            }.map(\.identity.taskID))
        )
        XCTAssertTrue(activationMutation.taskTransitions.allSatisfy {
            $0.expectedState == .pending && $0.successorState == .running
        })

        let activeBasis = try applying(plan: activationPlan, to: pendingBasis)
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: evidenceQueryProducer()
        ).makePreparedRound(from: activeBasis)
        XCTAssertNil(prepared.finalSynthesisRequest)
        XCTAssertEqual(prepared.requests.count, 1)
        XCTAssertEqual(prepared.requests[0].operationID, .evidenceQuery)
    }

    func testOrdinaryModelResponsePausesWithoutExceedingSuccessorTaskBudget() async throws {
        for maximumTasks in [9, 10] {
            for disposition in [ReconstructionInferenceDisposition.continue, .blocked, .sufficientEvidence] {
                let fixture = try await makeActiveModelFixture(maximumTasks: maximumTasks)
                let inference = modelInference(fixture: fixture, disposition: disposition)
                let authority = try roundRequestAuthority(fixture: fixture,
                    terminalReceipt: inference.terminalReceipt)
                let plan = try await fixture.builder.makeCommitPlan(cut: fixture.cut,
                    lease: try modelLease(), requestAuthority: authority,
                    inference: inference, executions: [])
                let mutation = try XCTUnwrap(plan.mutation)
                XCTAssertEqual(plan.disposition, .paused(.evidenceStalled))
                XCTAssertTrue(mutation.newTasks.isEmpty)
                XCTAssertEqual(mutation.modelReceipts.count, 1)
                XCTAssertTrue(mutation.taskTransitions.contains {
                    $0.diagnostic?.text.contains("Task budget reached") == true
                })
                XCTAssertLessThanOrEqual(fixture.basis.tasks.count, maximumTasks)
            }
        }
    }

    func testDurableRoundBudgetResetsFromSelectedToolEvidenceAndIgnoresFinalReceipt()
        throws
    {
        let fixture = try historicalModelBudgetFixture()
        let count = try ReconstructionProductionModelRoundBudgetAuthority
            .consecutiveRoundsWithoutEvidence(
                jobID: fixture.jobID,
                tasks: fixture.tasks,
                toolReceipts: fixture.toolReceipts,
                modelReceipts: fixture.modelReceipts,
                taskCompletionAuthorities: fixture.taskCompletionAuthorities
            )
        XCTAssertEqual(count, 3)

        // Reconstructing the authority from only the same persisted rows must yield the same
        // answer; no coordinator-local counter is allowed to participate.
        let reopenedCount = try ReconstructionProductionModelRoundBudgetAuthority
            .consecutiveRoundsWithoutEvidence(
                jobID: fixture.jobID,
                tasks: fixture.tasks,
                toolReceipts: fixture.toolReceipts,
                modelReceipts: fixture.modelReceipts,
                taskCompletionAuthorities: fixture.taskCompletionAuthorities
            )
        XCTAssertEqual(reopenedCount, count)
        XCTAssertEqual(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: Array(fixture.modelReceipts.dropLast()),
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                ),
            count,
            "a final-synthesis receipt must not consume or reset the ordinary-round budget"
        )

        let evidenceReceipt = try XCTUnwrap(fixture.toolReceipts.first)
        let evidenceRemoved = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: evidenceReceipt.receiptID,
            jobID: evidenceReceipt.jobID,
            taskID: evidenceReceipt.taskID,
            checkpointRevision: evidenceReceipt.checkpointRevision,
            requestIdentitySHA256: evidenceReceipt.requestIdentitySHA256,
            producer: evidenceReceipt.producer,
            terminalState: evidenceReceipt.terminalState,
            outputEvidenceIDs: [],
            diagnostic: evidenceReceipt.diagnostic
        )
        XCTAssertEqual(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: [evidenceRemoved],
                    modelReceipts: fixture.modelReceipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                ),
            4,
            "removing the persisted accepted-evidence link must make the prior round count"
        )
    }

    func testDurableRoundBudgetCountsTerminalOrdinaryRoundAndTerminalEvidenceResets()
        throws
    {
        let fixture = try historicalModelBudgetFixture()
        XCTAssertEqual(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: fixture.modelReceipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                ),
            3,
            "the last completed ordinary round counts even when final synthesis follows"
        )

        let terminalOrdinaryReceipt = try XCTUnwrap(fixture.modelReceipts.dropLast().last)
        let terminalModelTask = try XCTUnwrap(fixture.tasks.first {
            $0.identity.taskID == terminalOrdinaryReceipt.taskID
        })
        let retrieveTaskID = try XCTUnwrap(
            terminalModelTask.identity.dependencyTaskIDs.first
        )
        let evidenceHandleID = UUID()
        let terminalEvidenceReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: evidenceHandleID,
            jobID: fixture.jobID,
            taskID: retrieveTaskID,
            checkpointRevision: terminalOrdinaryReceipt.checkpointRevision,
            requestIdentitySHA256: digest("5"),
            producer: try evidenceQueryProducer(),
            terminalState: .completed,
            outputEvidenceIDs: [UUID()],
            diagnostic: nil
        )
        let terminalEvidenceModelReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: terminalOrdinaryReceipt.receiptID,
            jobID: terminalOrdinaryReceipt.jobID,
            taskID: terminalOrdinaryReceipt.taskID,
            checkpointRevision: terminalOrdinaryReceipt.checkpointRevision,
            requestIdentitySHA256: terminalOrdinaryReceipt.requestIdentitySHA256,
            producer: terminalOrdinaryReceipt.producer,
            terminalState: .completed,
            selectedHandleIDs: [evidenceHandleID.uuidString.lowercased()],
            acceptedEvidenceIDs: [],
            diagnostic: nil
        )
        let modelReceipts = fixture.modelReceipts.map {
            $0.receiptID == terminalEvidenceModelReceipt.receiptID
                ? terminalEvidenceModelReceipt
                : $0
        }

        XCTAssertEqual(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts + [terminalEvidenceReceipt],
                    modelReceipts: modelReceipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                ),
            0,
            "accepted evidence in the terminal ordinary round resets the durable streak"
        )
    }

    func testDurableRoundBudgetCountsBlockedOrdinaryModelOutcome() throws {
        let fixture = try historicalModelBudgetFixture()
        let frontiers = try ReconstructionProductionRoundPlanBuilder
            .regularModelFrontiers(in: fixture.tasks)
        let lastOrdinary = try XCTUnwrap(frontiers.last)
        let finalModel = try XCTUnwrap(fixture.tasks.first {
            $0.identity.operationContractIdentity
                == ReconstructionProductionTaskContract.finalSynthesis
        })
        let finalTaskIDs = Set(
            fixture.tasks.filter {
                $0.identity.taskID == finalModel.identity.taskID
                    || $0.identity.dependencyTaskIDs == [finalModel.identity.taskID]
            }.map(\.identity.taskID)
        )
        let blockedTasks = fixture.tasks.compactMap { task -> ReconstructionTaskRecord? in
            guard !finalTaskIDs.contains(task.identity.taskID) else { return nil }
            guard task.identity.taskID == lastOrdinary.checkpoint.identity.taskID else {
                return task
            }
            return ReconstructionTaskRecord(
                identity: task.identity,
                state: .blocked,
                diagnostic: .sanitizing("Committed evidence remains insufficient.")
            )
        }

        XCTAssertEqual(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: blockedTasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: fixture.modelReceipts.filter {
                        $0.finalResultCommitment == nil
                    },
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                ),
            3
        )
    }

    func testDurableRoundBudgetRejectsMissingHistoricalModelReceipt() throws {
        let fixture = try historicalModelBudgetFixture()
        let missing = try XCTUnwrap(fixture.modelReceipts.first {
            $0.finalResultCommitment == nil
        })

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: fixture.modelReceipts.filter {
                        $0.receiptID != missing.receiptID
                    },
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testDurableRoundBudgetRejectsReceiptIntroducedAfterFirstTaskCompletion() throws {
        let fixture = try historicalModelBudgetFixture()
        let evidenceReceipt = try XCTUnwrap(fixture.toolReceipts.first)
        let evidenceModelReceipt = try XCTUnwrap(fixture.modelReceipts.first {
            $0.selectedHandleIDs == [evidenceReceipt.receiptID.uuidString.lowercased()]
        })
        let movedRevision: UInt64 = 1_000
        let movedToolReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: evidenceReceipt.receiptID,
            jobID: evidenceReceipt.jobID,
            taskID: evidenceReceipt.taskID,
            checkpointRevision: movedRevision,
            requestIdentitySHA256: evidenceReceipt.requestIdentitySHA256,
            producer: evidenceReceipt.producer,
            terminalState: evidenceReceipt.terminalState,
            outputEvidenceIDs: evidenceReceipt.outputEvidenceIDs,
            diagnostic: evidenceReceipt.diagnostic
        )
        let movedModelReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: evidenceModelReceipt.receiptID,
            jobID: evidenceModelReceipt.jobID,
            taskID: evidenceModelReceipt.taskID,
            checkpointRevision: movedRevision,
            requestIdentitySHA256: evidenceModelReceipt.requestIdentitySHA256,
            producer: evidenceModelReceipt.producer,
            terminalState: evidenceModelReceipt.terminalState,
            selectedHandleIDs: evidenceModelReceipt.selectedHandleIDs,
            acceptedEvidenceIDs: evidenceModelReceipt.acceptedEvidenceIDs,
            diagnostic: evidenceModelReceipt.diagnostic
        )
        let movedModelReceipts = fixture.modelReceipts.map {
            $0.receiptID == movedModelReceipt.receiptID ? movedModelReceipt : $0
        }

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: [movedToolReceipt],
                    modelReceipts: movedModelReceipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testDurableRoundBudgetRejectsForeignSameRevisionToolReceipt() throws {
        let fixture = try historicalModelBudgetFixture()
        let evidenceReceipt = try XCTUnwrap(fixture.toolReceipts.first)
        let foreignReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: evidenceReceipt.receiptID,
            jobID: evidenceReceipt.jobID,
            taskID: UUID(),
            checkpointRevision: evidenceReceipt.checkpointRevision,
            requestIdentitySHA256: evidenceReceipt.requestIdentitySHA256,
            producer: evidenceReceipt.producer,
            terminalState: evidenceReceipt.terminalState,
            outputEvidenceIDs: evidenceReceipt.outputEvidenceIDs,
            diagnostic: evidenceReceipt.diagnostic
        )

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: [foreignReceipt],
                    modelReceipts: fixture.modelReceipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testDurableRoundBudgetRejectsDuplicateModelReceiptForOneFrontier() throws {
        let fixture = try historicalModelBudgetFixture()
        let original = try XCTUnwrap(fixture.modelReceipts.first {
            $0.finalResultCommitment == nil
        })
        let (differentRevision, overflow) = original.checkpointRevision
            .addingReportingOverflow(100)
        XCTAssertFalse(overflow)
        let duplicate = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: UUID(),
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointRevision: differentRevision,
            requestIdentitySHA256: original.requestIdentitySHA256,
            producer: original.producer,
            terminalState: original.terminalState,
            selectedHandleIDs: original.selectedHandleIDs,
            acceptedEvidenceIDs: original.acceptedEvidenceIDs,
            diagnostic: original.diagnostic
        )

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: fixture.modelReceipts + [duplicate],
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testDurableRoundBudgetRejectsWrongModelProducerOperation() throws {
        let fixture = try historicalModelBudgetFixture()
        let original = try XCTUnwrap(fixture.modelReceipts.first {
            $0.finalResultCommitment == nil
        })
        let wrongOperationReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: original.receiptID,
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointRevision: original.checkpointRevision,
            requestIdentitySHA256: original.requestIdentitySHA256,
            producer: try modelProducer(
                operationIdentity: ReconstructionProductionTaskContract.finalSynthesis
            ),
            terminalState: original.terminalState,
            selectedHandleIDs: original.selectedHandleIDs,
            acceptedEvidenceIDs: original.acceptedEvidenceIDs,
            diagnostic: original.diagnostic
        )
        let receipts = fixture.modelReceipts.map {
            $0.receiptID == original.receiptID ? wrongOperationReceipt : $0
        }

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: receipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testDurableRoundBudgetRejectsWrongToolProducerOperation() throws {
        let fixture = try historicalModelBudgetFixture()
        let original = try XCTUnwrap(fixture.toolReceipts.first)
        let wrongOperationReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: original.receiptID,
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointRevision: original.checkpointRevision,
            requestIdentitySHA256: original.requestIdentitySHA256,
            producer: try toolProducer(operationID: .evidenceGet),
            terminalState: original.terminalState,
            outputEvidenceIDs: original.outputEvidenceIDs,
            diagnostic: original.diagnostic
        )

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: [wrongOperationReceipt],
                    modelReceipts: fixture.modelReceipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testDurableRoundBudgetRejectsNoncanonicalSelectedHandleSpelling() throws {
        let fixture = try historicalModelBudgetFixture()
        let original = try XCTUnwrap(fixture.modelReceipts.first {
            !$0.selectedHandleIDs.isEmpty
        })
        let noncanonical = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: original.receiptID,
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointRevision: original.checkpointRevision,
            requestIdentitySHA256: original.requestIdentitySHA256,
            producer: original.producer,
            terminalState: original.terminalState,
            selectedHandleIDs: original.selectedHandleIDs.map { $0.uppercased() },
            acceptedEvidenceIDs: original.acceptedEvidenceIDs,
            diagnostic: original.diagnostic
        )
        let receipts = fixture.modelReceipts.map {
            $0.receiptID == original.receiptID ? noncanonical : $0
        }

        XCTAssertThrowsError(
            try ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: fixture.jobID,
                    tasks: fixture.tasks,
                    toolReceipts: fixture.toolReceipts,
                    modelReceipts: receipts,
                    taskCompletionAuthorities: fixture.taskCompletionAuthorities
                )
        )
    }

    func testCheckpointRevisionBeyondMaxRoundsCreatesFinalLeafAndCompletesItAtomically()
        async throws
    {
        let fixture = try await makeActiveModelFixture(startingRevision: 9, focusArtifact: true)
        XCTAssertEqual(fixture.basis.job.budget.maxRounds, 8)
        XCTAssertGreaterThan(fixture.basis.checkpoint.revision, 8)
        XCTAssertEqual(fixture.basis.snapshot.consecutiveModelRoundsWithoutEvidence, 0)
        let inference = modelInference(fixture: fixture, disposition: .sufficientEvidence)
        let requestAuthority = try roundRequestAuthority(
            fixture: fixture,
            terminalReceipt: inference.terminalReceipt
        )
        let modelPlan = try await fixture.builder.makeCommitPlan(
            cut: fixture.cut,
            lease: try modelLease(),
            requestAuthority: requestAuthority,
            inference: inference,
            executions: []
        )
        let modelMutation = try XCTUnwrap(modelPlan.mutation)
        XCTAssertEqual(modelMutation.newTasks.map(\.identity.kind), [.modelRound, .checkpoint])
        let finalModel = try XCTUnwrap(modelMutation.newTasks.first {
            $0.identity.kind == .modelRound
        })
        XCTAssertEqual(
            finalModel.identity.operationContractIdentity,
            ReconstructionProductionTaskContract.finalSynthesis
        )

        let pendingFinalBasis = try applying(plan: modelPlan, to: fixture.basis)
        let activation = try await makePreInferenceFixture(basis: pendingFinalBasis)
        let proposedActivationPlan = try await activation.builder.makePreInferenceCommitPlan(
            cut: activation.cut
        )
        let activationPlan = try XCTUnwrap(proposedActivationPlan)
        let activeFinalBasis = try applying(plan: activationPlan, to: pendingFinalBasis)
        let finalPrepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: evidenceQueryProducer()
        ).makePreparedRound(from: activeFinalBasis)
        let finalRequest = try XCTUnwrap(finalPrepared.finalSynthesisRequest)
        XCTAssertTrue(finalPrepared.requests.isEmpty)
        XCTAssertTrue(finalPrepared.projectorInput.producersByOperation.isEmpty)
        XCTAssertEqual(finalPrepared.retrievalQuery.classifications, [.acceptedCurrent])
        XCTAssertNotNil(fixture.basis.job.focus)
        XCTAssertEqual(finalPrepared.retrievalQuery.focus, fixture.basis.job.focus)
        XCTAssertEqual(finalRequest.acceptedEvidenceIDs, finalRequest.context.evidenceIDs)
        XCTAssertEqual(finalRequest.jobID, activeFinalBasis.job.jobID)
        XCTAssertEqual(finalRequest.checkpointRevision, activeFinalBasis.checkpoint.revision)

        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: activeFinalBasis,
            prepared: finalPrepared
        )
        let finalBuilder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry,
            receiptAuthor: StructuralPassThroughReceiptPlanAuthor()
        )
        let finalCut = ReconstructionProductionCommittedRoundCut(
            snapshot: activeFinalBasis.snapshot,
            parentCheckpointID: activeFinalBasis.checkpoint.checkpointID,
            parentCheckpointSHA256: activeFinalBasis.checkpoint.canonicalSHA256,
            prepared: finalPrepared,
            batchTerminalResults: []
        )
        let terminalReceipt = ReconstructionTerminalReceipt(
            requestID: UUID(),
            jobID: activeFinalBasis.job.jobID,
            checkpointRevision: activeFinalBasis.checkpoint.revision,
            roundID: nil,
            status: .completed
        )
        let finalAuthority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: terminalReceipt.requestID,
            request: finalPrepared.objective.map {
                .finalSynthesisR2(.init(protocolVersion: 9, objective: $0, request: finalRequest))
            } ?? .finalSynthesis(finalRequest),
            terminalReceipt: terminalReceipt
        )
        let synthesis = ReconstructionFinalSynthesisExecutionResult(
            candidate: ReconstructionFinalSynthesisCandidate(
                kind: .synthesis,
                text: "Bounded final synthesis.",
                evidenceIDs: finalRequest.acceptedEvidenceIDs
            ),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: terminalReceipt
        )
        let finalPlan = try await finalBuilder.makeFinalCommitPlan(
            cut: finalCut,
            lease: try modelLease(),
            requestAuthority: finalAuthority,
            synthesis: synthesis
        )
        let finalMutation = try XCTUnwrap(finalPlan.mutation)
        XCTAssertEqual(finalPlan.disposition, .completed)
        XCTAssertGreaterThan(finalMutation.successorCheckpoint.revision, 8)
        XCTAssertEqual(finalMutation.successorCheckpoint.coordinatorState, .completed)
        XCTAssertEqual(finalMutation.taskTransitions.map(\.successorState), [
            .completed, .completed,
        ])
        XCTAssertTrue(finalMutation.successorCheckpoint.pendingTaskIDs.isEmpty)
        XCTAssertTrue(finalMutation.successorCheckpoint.runningTaskIDs.isEmpty)
        XCTAssertTrue(finalMutation.successorCheckpoint.failedTaskIDs.isEmpty)
        XCTAssertTrue(finalMutation.successorCheckpoint.blockedTaskIDs.isEmpty)
    }

    func testBuilderRejectsConflictingCommittedImageFingerprint() async throws {
        let fixture = try makeEnumerationFixture(
            maximumTasks: 16,
            committedFingerprint: digest("a"),
            resultFingerprint: digest("b")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        }
    }

    func testBuilderRejectsForeignTerminalCheckpointOrCorpus() async throws {
        for mutation in [ForeignResultMutation.checkpoint, .corpus] {
            let fixture = try makeLoadFixture(foreignResult: mutation)
            await XCTAssertThrowsErrorAsync("Accepted foreign \(mutation)") {
                _ = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
            }
        }
    }

    func testCutProviderBuildsFreshExecutionFacadeForEachOwnedAttachmentAuthority()
        async throws
    {
        let firstDatabaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let firstFoundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: firstDatabaseFixture.binaryID
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = temporaryRoot.appendingPathComponent("source.bin")
        let firstVault = temporaryRoot.appendingPathComponent("vault-one", isDirectory: true)
        let secondVault = temporaryRoot.appendingPathComponent("vault-two", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: sourceURL, options: .atomic)
        firstDatabaseFixture.database.configureReconstructionAttachmentVault(rootURL: firstVault)
        _ = try firstDatabaseFixture.database.publishDurableReconstructionAttachmentSources(
            [ReconstructionAttachmentSource(
                contentIdentity: firstFoundation.occurrence.contentIdentity,
                verifiedURL: sourceURL
            )],
            for: firstFoundation.manifest
        )
        try firstDatabaseFixture.database.replaceReconstructionState(
            workspaceID: firstDatabaseFixture.workspaceUUID,
            state: firstFoundation.state
        )

        let firstRows = try firstDatabaseFixture.database.captureReconstructionProductionRoundRows(
            workspaceID: firstDatabaseFixture.workspaceUUID,
            jobID: firstFoundation.job.jobID
        )
        let firstBasis = try ReconstructionProductionRoundBasis(rows: firstRows)
        let registry = ReconstructionProductionRoundBasisRegistry()
        let executionBuilder = RecordingBatchExecutionBuilder()
        let firstWorkspaceID = firstDatabaseFixture.workspaceUUID
        let firstOwner = ReconstructionDatabaseOwner(database: firstDatabaseFixture.database)
        let firstProvider = ReconstructionProductionCommittedRoundCutProvider(
            workspaceID: firstWorkspaceID,
            owner: firstOwner,
            batchExecutionBuilder: executionBuilder,
            preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                evidenceQueryProducer: evidenceQueryProducer()
            ),
            basisRegistry: registry,
            maximumConcurrentTasks: 2
        )
        let firstCut = try await firstProvider.capture(snapshot: firstBasis.snapshot)
        await registry.remove(
            roundID: firstCut.prepared.roundID,
            matching: firstCut.snapshot,
            prepared: firstCut.prepared
        )

        let secondDatabaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let secondFoundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: secondDatabaseFixture.binaryID
        )
        secondDatabaseFixture.database.configureReconstructionAttachmentVault(rootURL: secondVault)
        _ = try secondDatabaseFixture.database.publishDurableReconstructionAttachmentSources(
            [ReconstructionAttachmentSource(
                contentIdentity: secondFoundation.occurrence.contentIdentity,
                verifiedURL: sourceURL
            )],
            for: secondFoundation.manifest
        )
        try secondDatabaseFixture.database.replaceReconstructionState(
            workspaceID: secondDatabaseFixture.workspaceUUID,
            state: secondFoundation.state
        )
        let secondRows = try secondDatabaseFixture.database
            .captureReconstructionProductionRoundRows(
                workspaceID: secondDatabaseFixture.workspaceUUID,
                jobID: secondFoundation.job.jobID
            )
        let secondBasis = try ReconstructionProductionRoundBasis(rows: secondRows)
        let secondWorkspaceID = secondDatabaseFixture.workspaceUUID
        let secondOwner = ReconstructionDatabaseOwner(database: secondDatabaseFixture.database)
        let secondProvider = ReconstructionProductionCommittedRoundCutProvider(
            workspaceID: secondWorkspaceID,
            owner: secondOwner,
            batchExecutionBuilder: executionBuilder,
            preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                evidenceQueryProducer: evidenceQueryProducer()
            ),
            basisRegistry: registry,
            maximumConcurrentTasks: 2
        )
        _ = try await secondProvider.capture(snapshot: secondBasis.snapshot)

        let captured = await executionBuilder.capturedAttachmentURLs()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].count, 1)
        XCTAssertEqual(captured[1].count, 1)
        XCTAssertNotEqual(captured[0], captured[1])
        XCTAssertTrue(captured[0][0].path.hasPrefix(firstVault.path))
        XCTAssertTrue(captured[1][0].path.hasPrefix(secondVault.path))
    }

    func testStaleDiscardCannotEvictExactPreparedRoundBasis() async throws {
        let fixture = try makeLoadFixture()
        let snapshot = fixture.basis.snapshot
        let staleSnapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: snapshot.jobID,
            jobCreationOrder: snapshot.jobCreationOrder,
            checkpointID: snapshot.checkpointID,
            checkpointRevision: snapshot.checkpointRevision + 1,
            checkpointCorpusManifestSHA256: snapshot.checkpointCorpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: snapshot.checkpointEvidenceFrontierSHA256,
            currentCorpusManifestSHA256: snapshot.currentCorpusManifestSHA256,
            evidenceFrontierSHA256: snapshot.evidenceFrontierSHA256,
            currentDurableJobState: snapshot.currentDurableJobState,
            pauseContext: snapshot.pauseContext,
            maximumRoundsWithoutEvidence: snapshot.maximumRoundsWithoutEvidence,
            tasks: snapshot.tasks,
            terminalReceiptStatesByTaskID: snapshot.terminalReceiptStatesByTaskID
        )

        let staleCut = ReconstructionProductionCommittedRoundCut(
            snapshot: staleSnapshot,
            parentCheckpointID: fixture.cut.parentCheckpointID,
            parentCheckpointSHA256: fixture.cut.parentCheckpointSHA256,
            prepared: fixture.cut.prepared,
            batchTerminalResults: fixture.cut.batchTerminalResults
        )
        await fixture.builder.discardPreparedRound(cut: staleCut)
        _ = try await fixture.registry.basis(roundID: fixture.cut.prepared.roundID)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.builder.makePreInferenceCommitPlan(cut: staleCut)
        }
        _ = try await fixture.registry.basis(roundID: fixture.cut.prepared.roundID)

        await fixture.builder.discardPreparedRound(cut: fixture.cut)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.registry.basis(roundID: fixture.cut.prepared.roundID)
        }
    }

    func testPreparedRoundRegistryFailsClosedAtBound() async throws {
        let registry = ReconstructionProductionRoundBasisRegistry()
        for _ in 0 ..< ReconstructionProductionRoundBasis.maximumRegisteredRounds {
            let fixture = try makeLoadFixture()
            try await registry.register(fixture.basis, prepared: fixture.cut.prepared)
        }
        let overflow = try makeLoadFixture()
        do {
            try await registry.register(overflow.basis, prepared: overflow.cut.prepared)
            XCTFail("Registry accepted a prepared round beyond its fixed bound")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionProductionRoundBasisError,
                .registryCapacityExceeded
            )
        }
    }

    func testJobScopedExecutionControllerControlsFreshPerCutSchedulers() async throws {
        let fixture = try makeLoadFixture()
        let tracker = ProductionBatchSchedulerLifecycleTracker()
        let controller = ReconstructionProductionBatchExecutionController(
            durableJobID: fixture.basis.job.jobID,
            builder: { basis, authority in
                try await tracker.makeScheduler(basis: basis, authority: authority)
            },
            retireJobAuthority: {
                await tracker.recordJobAuthorityRetire()
            }
        )
        let authority = try ReconstructionBatchAuthority(
            jobID: fixture.basis.job.jobID,
            checkpointID: fixture.basis.checkpoint.checkpointID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256
        )

        let first = try await controller.makeScheduler(
            for: fixture.basis,
            authority: authority
        )
        _ = try await first.executeReadyTasks(
            fixture.basis.tasks,
            authority: authority,
            budget: .init(maximumTasks: 16, maximumConcurrentTasks: 2)
        )
        let second = try await controller.makeScheduler(
            for: fixture.basis,
            authority: authority
        )
        _ = try await second.executeReadyTasks(
            fixture.basis.tasks,
            authority: authority,
            budget: .init(maximumTasks: 16, maximumConcurrentTasks: 2),
            allowedTaskKinds: [.ingest]
        )
        let executionTaskKinds = await tracker.executionTaskKinds()
        XCTAssertEqual(executionTaskKinds, [nil, Set<ReconstructionTaskKind>([.ingest])])
        let afterReplacement = await tracker.counts()
        XCTAssertEqual(
            afterReplacement,
            .init(
                created: 2,
                executed: 2,
                paused: 1,
                resumed: 0,
                childRetired: 0,
                jobAuthorityRetired: 0
            )
        )

        await controller.pause(jobID: fixture.basis.job.jobID)
        await controller.resume(jobID: fixture.basis.job.jobID)
        await controller.retire(jobID: fixture.basis.job.jobID)
        await controller.retire(jobID: fixture.basis.job.jobID)
        let afterRetirement = await tracker.counts()
        XCTAssertEqual(
            afterRetirement,
            .init(
                created: 2,
                executed: 2,
                paused: 3,
                resumed: 1,
                childRetired: 0,
                jobAuthorityRetired: 1
            )
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await controller.makeScheduler(for: fixture.basis, authority: authority)
        }
    }

    private enum ForeignResultMutation: Equatable, CustomStringConvertible {
        case checkpoint
        case corpus

        var description: String {
            switch self {
            case .checkpoint: "checkpoint"
            case .corpus: "corpus"
            }
        }
    }

    private struct Fixture {
        let basis: ReconstructionProductionRoundBasis
        let cut: ReconstructionProductionCommittedRoundCut
        let builder: ReconstructionProductionRoundPlanBuilder
        let registry: ReconstructionProductionRoundBasisRegistry
        let terminalTaskID: UUID
    }

    private func makeLoadFixture(
        foreignResult: ForeignResultMutation? = nil
    ) throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID],
            state: .completed
        )
        let load = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID], state: .pending
        )
        let image = ReconstructionImageBinding(
            binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                occurrenceID: artifact.occurrenceID,
                selectedSliceIndex: nil
            ),
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let projection = try ReconstructionTransientAnalysisProjection(
            taskID: load.identity.taskID,
            taskKind: .loadBinary,
            artifact: artifact,
            image: image,
            analysisFingerprintSHA256: digest("a"),
            functionCatalog: [],
            function: nil,
            macScopePseudocode: nil
        )
        let basis = try makeBasis(
            foundation: foundation,
            tasks: [ingest, classify, discover, load],
            maximumTasks: 16,
            currentImages: []
        )
        let prepared = try ReconstructionProductionPreparedRoundBuilder
            .makeDirectCommitDescriptor(from: basis)
        let checkpointID = foreignResult == .checkpoint
            ? UUID()
            : basis.checkpoint.checkpointID
        let corpus = foreignResult == .corpus
            ? digest("f")
            : basis.manifest.canonicalSHA256
        let result = ReconstructionTerminalTaskResult(
            jobID: basis.job.jobID,
            taskID: load.identity.taskID,
            checkpointID: checkpointID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: corpus,
            outcome: .completed,
            analysisProjection: projection
        )
        return try registeredFixture(basis: basis, prepared: prepared, result: result)
    }

    private func makeEnumerationFixture(
        maximumTasks: Int,
        committedFingerprint: String? = nil,
        resultFingerprint: String? = nil,
        includesFunction: Bool = true
    ) throws -> Fixture {
        let resolvedResultFingerprint = resultFingerprint ?? digest("a")
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let imageBinding = ReconstructionImageBinding(
            binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                occurrenceID: artifact.occurrenceID,
                selectedSliceIndex: nil
            ),
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let resultImage = try ReconstructionImageCoordinate(
            artifact: artifact,
            image: imageBinding,
            analysisFingerprintSHA256: resolvedResultFingerprint
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID],
            state: .completed
        )
        let load = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let index = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
            subject: .image(resultImage), dependencies: [load.identity.taskID], state: .completed
        )
        let enumerate = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .enumerateFunctions,
            subject: .image(resultImage), dependencies: [index.identity.taskID], state: .pending
        )
        let function = FunctionSummary(
            id: ReconstructionStableImageAuthority.stableFunctionID(
                image: imageBinding,
                analysisFingerprintSHA256: resolvedResultFingerprint,
                startAddress: 0x1000,
                endAddressExclusive: 0x1010,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion
            ),
            name: "entry",
            startAddress: 0x1000,
            endAddress: 0x1010,
            confidence: 1.0
        )
        let projection = try ReconstructionTransientAnalysisProjection(
            taskID: enumerate.identity.taskID,
            taskKind: .enumerateFunctions,
            artifact: artifact,
            image: imageBinding,
            analysisFingerprintSHA256: resolvedResultFingerprint,
            functionCatalog: includesFunction ? [function] : [],
            function: nil,
            macScopePseudocode: nil
        )
        let committedImages: [ReconstructionImageCoordinate] = try committedFingerprint.map {
            [try ReconstructionImageCoordinate(
                artifact: artifact,
                image: imageBinding,
                analysisFingerprintSHA256: $0
            )]
        } ?? []
        let basis = try makeBasis(
            foundation: foundation,
            tasks: [ingest, classify, discover, load, index, enumerate],
            maximumTasks: maximumTasks,
            currentImages: committedImages
        )
        let prepared = try ReconstructionProductionPreparedRoundBuilder
            .makeDirectCommitDescriptor(from: basis)
        let result = ReconstructionTerminalTaskResult(
            jobID: basis.job.jobID,
            taskID: enumerate.identity.taskID,
            checkpointID: basis.checkpoint.checkpointID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            outcome: .completed,
            analysisProjection: projection
        )
        return try registeredFixture(basis: basis, prepared: prepared, result: result)
    }

    private func makeActiveModelFixture(
        startingRevision: UInt64 = 0,
        maximumTasks: Int = 32,
        focusArtifact: Bool = false
    ) async throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID],
            state: .completed
        )
        let load = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let imageBinding = ReconstructionImageBinding(
            binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                occurrenceID: artifact.occurrenceID,
                selectedSliceIndex: nil
            ),
            imageSlot: .primary,
            selectedSliceIndex: nil,
            architecture: .arm64,
            machOIdentity: nil
        )
        let image = try ReconstructionImageCoordinate(
            artifact: artifact,
            image: imageBinding,
            analysisFingerprintSHA256: digest("a")
        )
        let index = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
            subject: .image(image), dependencies: [load.identity.taskID], state: .completed
        )
        let enumerate = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .enumerateFunctions,
            subject: .image(image), dependencies: [index.identity.taskID], state: .completed
        )
        let retrieve = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .retrieveEvidence,
            subject: nil,
            dependencies: [discover.identity.taskID, enumerate.identity.taskID],
            state: .running,
            operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery
        )
        let model = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .modelRound,
            subject: nil, dependencies: [retrieve.identity.taskID], state: .running,
            operationContractIdentity: ReconstructionProductionTaskContract.modelRound
        )
        let checkpoint = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .checkpoint,
            subject: nil, dependencies: [model.identity.taskID], state: .pending,
            operationContractIdentity: ReconstructionProductionTaskContract.checkpoint
        )
        let basis = try makeBasis(
            foundation: foundation,
            tasks: [
                ingest, classify, discover, load, index, enumerate,
                retrieve, model, checkpoint,
            ],
            maximumTasks: maximumTasks,
            currentImages: [image],
            startingRevision: startingRevision,
            focus: focusArtifact ? .artifact(artifact) : nil
        )
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: evidenceQueryProducer()
        ).makePreparedRound(from: basis)
        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: basis,
            prepared: prepared
        )
        return Fixture(
            basis: basis,
            cut: ReconstructionProductionCommittedRoundCut(
                snapshot: basis.snapshot,
                parentCheckpointID: basis.checkpoint.checkpointID,
                parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
                prepared: prepared,
                batchTerminalResults: []
            ),
            builder: ReconstructionProductionRoundPlanBuilder(
                basisRegistry: registry,
                receiptAuthor: ReconstructionProductionReceiptPlanAuthor(
                    modelProducerContext: ReconstructionModelProducerIdentityContext(
                        macScopeBuildIdentity: digest("a"),
                        macScopeSourceIdentity: digest("b"),
                        operationIdentity: ReconstructionProductionTaskContract.modelRound,
                        registryIdentity: "reconstruction.registry.v1",
                        protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                        toolchainIdentity: "xcode-test"
                    )
                )
            ),
            registry: registry,
            terminalTaskID: model.identity.taskID
        )
    }

    private func historicalModelBudgetFixture() throws -> (
        jobID: UUID,
        tasks: [ReconstructionTaskRecord],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        taskCompletionAuthorities: [ReconstructionProductionTaskCompletionAuthority]
    ) {
        let jobID = UUID()
        let toolProducer = try evidenceQueryProducer()
        let modelProducer = try testModelProducer()
        var tasks: [ReconstructionTaskRecord] = []
        var frontiers: [ReconstructionProductionRegularModelFrontier] = []
        var predecessorID = UUID() // represents the completed deterministic batch leaf
        for _ in 0 ..< 4 {
            let retrieve = try task(
                id: UUID(), jobID: jobID, kind: .retrieveEvidence,
                subject: nil, dependencies: [predecessorID], state: .completed,
                operationContractIdentity: ReconstructionProductionTaskContract.evidenceQuery
            )
            let model = try task(
                id: UUID(), jobID: jobID, kind: .modelRound,
                subject: nil, dependencies: [retrieve.identity.taskID], state: .completed,
                operationContractIdentity: ReconstructionProductionTaskContract.modelRound
            )
            let checkpoint = try task(
                id: UUID(), jobID: jobID, kind: .checkpoint,
                subject: nil, dependencies: [model.identity.taskID], state: .completed,
                operationContractIdentity: ReconstructionProductionTaskContract.checkpoint
            )
            frontiers.append(.init(retrieve: retrieve, model: model, checkpoint: checkpoint))
            tasks.append(contentsOf: [retrieve, model, checkpoint])
            predecessorID = checkpoint.identity.taskID
        }
        let finalModel = try task(
            id: UUID(), jobID: jobID, kind: .modelRound,
            subject: nil, dependencies: [predecessorID], state: .completed,
            operationContractIdentity: ReconstructionProductionTaskContract.finalSynthesis
        )
        let finalCheckpoint = try task(
            id: UUID(), jobID: jobID, kind: .checkpoint,
            subject: nil, dependencies: [finalModel.identity.taskID], state: .completed,
            operationContractIdentity: ReconstructionProductionTaskContract.checkpoint
        )
        tasks.append(contentsOf: [finalModel, finalCheckpoint])

        let evidenceReceiptID = UUID(
            uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )!
        let toolReceipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: evidenceReceiptID,
            jobID: jobID,
            taskID: frontiers[0].retrieve.identity.taskID,
            checkpointRevision: 40,
            requestIdentitySHA256: digest("1"),
            producer: toolProducer,
            terminalState: .completed,
            outputEvidenceIDs: [UUID()],
            diagnostic: nil
        )
        var modelReceipts: [ReconstructionModelReceipt] = []
        for (index, frontier) in frontiers.enumerated() {
            modelReceipts.append(try ReconstructionReceiptAuthority.makeModelReceipt(
                receiptID: UUID(),
                jobID: jobID,
                taskID: frontier.model.identity.taskID,
                checkpointRevision: UInt64(40 + index),
                requestIdentitySHA256: digest("2"),
                producer: modelProducer,
                terminalState: .completed,
                selectedHandleIDs: index == 0
                    ? [evidenceReceiptID.uuidString.lowercased()]
                    : [],
                acceptedEvidenceIDs: [],
                diagnostic: nil
            ))
        }
        modelReceipts.append(try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: UUID(),
            jobID: jobID,
            taskID: finalModel.identity.taskID,
            checkpointRevision: 44,
            requestIdentitySHA256: digest("3"),
            producer: modelProducer,
            terminalState: .completed,
            selectedHandleIDs: [],
            acceptedEvidenceIDs: [],
            diagnostic: nil,
            finalResultCommitment: try ReconstructionFinalResultCommitment(
                resultID: UUID(),
                canonicalSHA256: digest("4")
            )
        ))
        var taskCompletionAuthorities: [ReconstructionProductionTaskCompletionAuthority] = []
        for (index, frontier) in frontiers.enumerated() {
            let revision = UInt64(40 + index)
            taskCompletionAuthorities.append(contentsOf: [
                .init(
                    taskID: frontier.retrieve.identity.taskID,
                    firstCompletedAtRevision: revision
                ),
                .init(
                    taskID: frontier.model.identity.taskID,
                    firstCompletedAtRevision: revision
                ),
            ])
        }
        taskCompletionAuthorities.append(contentsOf: [
            .init(taskID: finalModel.identity.taskID, firstCompletedAtRevision: 44),
            .init(taskID: finalCheckpoint.identity.taskID, firstCompletedAtRevision: 44),
        ])
        return (jobID, tasks, [toolReceipt], modelReceipts, taskCompletionAuthorities)
    }

    private func makePreInferenceFixture(
        basis: ReconstructionProductionRoundBasis
    ) async throws -> Fixture {
        let prepared = try ReconstructionProductionPreparedRoundBuilder
            .makeDirectCommitDescriptor(from: basis)
        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: basis,
            prepared: prepared
        )
        return Fixture(
            basis: basis,
            cut: ReconstructionProductionCommittedRoundCut(
                snapshot: basis.snapshot,
                parentCheckpointID: basis.checkpoint.checkpointID,
                parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
                prepared: prepared,
                batchTerminalResults: []
            ),
            builder: ReconstructionProductionRoundPlanBuilder(
                basisRegistry: registry,
                receiptAuthor: StructuralPassThroughReceiptPlanAuthor()
            ),
            registry: registry,
            terminalTaskID: basis.job.jobID
        )
    }

    private func modelInference(
        fixture: Fixture,
        disposition: ReconstructionInferenceDisposition
    ) -> ReconstructionInferenceExecutionResult {
        let terminalReceipt = ReconstructionTerminalReceipt(
            requestID: UUID(),
            jobID: fixture.basis.job.jobID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            roundID: fixture.cut.prepared.roundID,
            status: .completed
        )
        return ReconstructionInferenceExecutionResult(
            candidate: ReconstructionInferenceRoundCandidate(
                jobID: fixture.basis.job.jobID,
                checkpointRevision: fixture.basis.checkpoint.revision,
                roundID: fixture.cut.prepared.roundID,
                selectedHandleIDs: [],
                disposition: disposition,
                unresolvedGaps: []
            ),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: terminalReceipt
        )
    }

    private func roundRequestAuthority(
        fixture: Fixture,
        terminalReceipt: ReconstructionTerminalReceipt
    ) throws -> ReconstructionModelTerminalRequestAuthority {
        let prepared = fixture.cut.prepared
        let context = try ReconstructionContextCompiler().compile(
            cut: prepared.evidenceCut,
            query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories
        )
        let handles = try ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority,
            requests: prepared.requests
        )
        let request = ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: fixture.basis.job.jobID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            roundID: prepared.roundID,
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: fixture.basis.evidenceCut.frontierSHA256,
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
                .toolRegistry.identity.sha256,
            context: context,
            handles: handles.map {
                .init(handleID: $0.handleID, operationID: $0.operationID)
            }
        )
        return try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: terminalReceipt.requestID,
            request: prepared.objective.map {
                .roundR2(.init(protocolVersion: 9, objective: $0, request: request))
            } ?? .round(request),
            terminalReceipt: terminalReceipt
        )
    }

    private func modelLease() throws -> Phase2ReadyInferenceLease {
        .init(
            providerRevision: 1,
            configuration: try Phase2AIProviderConfiguration(
                profileID: UUID(),
                generation: 1,
                endpointOrigin: "http://127.0.0.1:1234",
                model: "local-model",
                maximumTokens: 1_024,
                requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 60_000
            ),
            observedModelInventorySHA256: digest("c")
        )
    }

    private func applying(
        plan: ReconstructionJobCommitPlan,
        to basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionProductionRoundBasis {
        guard let mutation = plan.mutation,
              mutation.jobID == basis.job.jobID,
              mutation.expectedParentCheckpointID == basis.checkpoint.checkpointID,
              mutation.expectedParentRevision == basis.checkpoint.revision,
              mutation.evidence.isEmpty,
              mutation.evidenceRelations.isEmpty,
              mutation.evidenceGaps.isEmpty,
              mutation.toolReceipts.isEmpty,
              mutation.finalResults.isEmpty,
              Set(mutation.taskTransitions.map(\.taskID)).count
                == mutation.taskTransitions.count else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let transitions = Dictionary(uniqueKeysWithValues: mutation.taskTransitions.map {
            ($0.taskID, $0)
        })
        let transitioned = try basis.tasks.map { task -> ReconstructionTaskRecord in
            guard let transition = transitions[task.identity.taskID] else { return task }
            guard task.state == transition.expectedState else {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            return ReconstructionTaskRecord(
                identity: task.identity,
                state: transition.successorState,
                diagnostic: transition.diagnostic
            )
        }
        let tasks = transitioned + mutation.newTasks
        let checkpoint = mutation.successorCheckpoint
        let modelReceipts = basis.modelReceipts + mutation.modelReceipts
        var firstCompletionRevisionByTaskID = Dictionary(
            uniqueKeysWithValues: basis.taskCompletionAuthorities.map {
                ($0.taskID, $0.firstCompletedAtRevision)
            }
        )
        func recordCompletedTaskIDs(_ taskIDs: [UUID], at revision: UInt64) {
            for taskID in taskIDs {
                if let existing = firstCompletionRevisionByTaskID[taskID] {
                    firstCompletionRevisionByTaskID[taskID] = min(existing, revision)
                } else {
                    firstCompletionRevisionByTaskID[taskID] = revision
                }
            }
        }
        recordCompletedTaskIDs(
            basis.checkpoint.completedTaskIDs,
            at: basis.checkpoint.revision
        )
        recordCompletedTaskIDs(checkpoint.completedTaskIDs, at: checkpoint.revision)
        let taskCompletionAuthorities = firstCompletionRevisionByTaskID.map {
            ReconstructionProductionTaskCompletionAuthority(
                taskID: $0.key,
                firstCompletedAtRevision: $0.value
            )
        }.sorted {
            $0.taskID.uuidString.lowercased() < $1.taskID.uuidString.lowercased()
        }
        var terminalStates: [UUID: ReconstructionTaskState] = [:]
        func recordTerminalState(
            taskID: UUID,
            receiptState: ReconstructionReceiptTerminalState
        ) throws {
            let state: ReconstructionTaskState = switch receiptState {
            case .completed, .truncated: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            }
            if let existing = terminalStates[taskID], existing != state {
                throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
            }
            terminalStates[taskID] = state
        }
        for receipt in basis.toolReceipts {
            try recordTerminalState(
                taskID: receipt.taskID,
                receiptState: receipt.terminalState
            )
        }
        for receipt in modelReceipts {
            try recordTerminalState(
                taskID: receipt.taskID,
                receiptState: receipt.terminalState
            )
        }
        let consecutiveModelRoundsWithoutEvidence = try
            ReconstructionProductionModelRoundBudgetAuthority
                .consecutiveRoundsWithoutEvidence(
                    jobID: basis.job.jobID,
                    tasks: tasks,
                    toolReceipts: basis.toolReceipts,
                    modelReceipts: modelReceipts,
                    taskCompletionAuthorities: taskCompletionAuthorities
                )
        let job = try ReconstructionJobRecord(
            jobID: basis.job.jobID,
            reconstructionProjectID: basis.project.projectID,
            objective: basis.job.objective,
            objectiveSHA256: basis.job.objectiveSHA256,
            creationCorpusManifestSHA256: basis.job.creationCorpusManifestSHA256,
            state: checkpoint.coordinatorState,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: checkpoint.terminalReason,
            budget: basis.job.budget,
            creationOrdinal: try XCTUnwrap(basis.job.creationOrdinal),
            pauseContext: mutation.successorPauseContext,
            focus: basis.job.focus
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: job.jobID,
            jobCreationOrder: try XCTUnwrap(job.creationOrdinal),
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
            currentDurableJobState: job.state,
            pauseContext: job.pauseContext,
            maximumRoundsWithoutEvidence: job.budget.maxRounds,
            tasks: tasks,
            terminalReceiptStatesByTaskID: terminalStates,
            consecutiveModelRoundsWithoutEvidence: consecutiveModelRoundsWithoutEvidence
        )
        return try ReconstructionProductionRoundBasis(
            workspaceID: basis.workspaceID,
            project: basis.project,
            manifest: basis.manifest,
            job: job,
            checkpoint: checkpoint,
            tasks: tasks,
            toolReceipts: basis.toolReceipts,
            modelReceipts: modelReceipts,
            taskCompletionAuthorities: taskCompletionAuthorities,
            attachmentSources: basis.attachmentSources,
            evidenceCut: basis.evidenceCut,
            freshnessAuthority: mutation.freshnessAuthority,
            snapshot: snapshot
        )
    }

    private func makeBasis(
        foundation: ReconstructionDatabaseTestFixtures.StateFixture,
        tasks: [ReconstructionTaskRecord],
        maximumTasks: Int,
        currentImages: [ReconstructionImageCoordinate],
        startingRevision: UInt64 = 0,
        focus: ReconstructionSubjectCoordinate? = nil
    ) throws -> ReconstructionProductionRoundBasis {
        let evidenceCut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            records: [],
            relations: [],
            gaps: foundation.state.evidenceGaps,
            frontierSHA256: try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: foundation.manifest.canonicalSHA256,
                records: [],
                projectedClassificationsByEvidenceID: [:],
                relations: [],
                gaps: foundation.state.evidenceGaps,
                checkpointRevisionsByID: [:]
            ),
            projectedClassificationsByEvidenceID: [:],
            checkpointRevisionsByID: [:]
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: UUID(),
            jobID: foundation.job.jobID,
            revision: startingRevision,
            parentCheckpointID: startingRevision == 0 ? nil : UUID(),
            parentCheckpointSHA256: startingRevision == 0 ? nil : digest("9"),
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceCut.frontierSHA256,
            pendingTaskIDs: tasks.filter { $0.state == .pending }.map(\.identity.taskID),
            runningTaskIDs: tasks.filter { $0.state == .running }.map(\.identity.taskID),
            completedTaskIDs: tasks.filter { $0.state == .completed }.map(\.identity.taskID),
            failedTaskIDs: tasks.filter { $0.state == .failed }.map(\.identity.taskID),
            blockedTaskIDs: tasks.filter { $0.state == .blocked }.map(\.identity.taskID),
            unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                .canonicalSHA256(for: foundation.state.evidenceGaps),
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.project.projectID,
            objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.manifest.canonicalSHA256,
            state: .retrieving,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil,
            budget: try ReconstructionJobBudget(
                maxRounds: 8,
                maxTasks: maximumTasks,
                maxEvidenceRecords: 128,
                maxEncodedBytes: 1_048_576
            ),
            creationOrdinal: 1,
            focus: focus
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: job.jobID,
            jobCreationOrder: 1,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: foundation.manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceCut.frontierSHA256,
            currentDurableJobState: .retrieving,
            pauseContext: nil,
            maximumRoundsWithoutEvidence: 8,
            tasks: tasks,
            terminalReceiptStatesByTaskID: [:]
        )
        let artifacts = foundation.manifest.artifacts.map {
            ReconstructionArtifactCoordinate(
                occurrenceID: $0.occurrenceID,
                contentIdentity: $0.contentIdentity
            )
        }
        return try ReconstructionProductionRoundBasis(
            workspaceID: UUID(),
            project: foundation.project,
            manifest: foundation.manifest,
            job: job,
            checkpoint: checkpoint,
            tasks: tasks,
            toolReceipts: [],
            modelReceipts: [],
            attachmentSources: [ReconstructionAttachmentSource(
                contentIdentity: foundation.occurrence.contentIdentity,
                verifiedURL: URL(fileURLWithPath: "/tmp/reconstruction-dynamic-fixture")
            )],
            evidenceCut: evidenceCut,
            freshnessAuthority: try ReconstructionFreshnessAuthority(
                corpusManifestSHA256: foundation.manifest.canonicalSHA256,
                currentArtifacts: artifacts,
                currentImages: currentImages,
                currentFacetFingerprints: [:]
            ),
            snapshot: snapshot
        )
    }

    private func registeredFixture(
        basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound,
        result: ReconstructionTerminalTaskResult
    ) throws -> Fixture {
        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: basis,
            prepared: prepared
        )
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry,
            receiptAuthor: StructuralPassThroughReceiptPlanAuthor()
        )
        let cut = ReconstructionProductionCommittedRoundCut(
            snapshot: basis.snapshot,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            prepared: prepared,
            batchTerminalResults: [result]
        )
        return Fixture(
            basis: basis,
            cut: cut,
            builder: builder,
            registry: registry,
            terminalTaskID: result.taskID
        )
    }

    private func task(
        id: UUID,
        jobID: UUID,
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?,
        dependencies: [UUID],
        state: ReconstructionTaskState,
        operationContractIdentity: String? = nil
    ) throws -> ReconstructionTaskRecord {
        ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: id,
                jobID: jobID,
                kind: kind,
                subject: subject,
                dependencyTaskIDs: dependencies,
                operationContractIdentity: operationContractIdentity
                    ?? "reconstruction.\(kind.rawValue).v1"
            ),
            state: state,
            diagnostic: nil
        )
    }

    private func digest(_ scalar: Character) -> String {
        String(repeating: String(scalar), count: 64)
    }

    private func toolProducer(
        operationID: MacScopeAnalysisCore.ReconstructionOperationID
    ) throws -> ReconstructionProducerIdentity {
        try ReconstructionProductionReceiptPlanAuthor(
            modelProducerContext: ReconstructionModelProducerIdentityContext(
                macScopeBuildIdentity: digest("a"),
                macScopeSourceIdentity: digest("b"),
                operationIdentity: "reconstruction.modelRound.v1",
                registryIdentity: "reconstruction.registry.v1",
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                toolchainIdentity: "xcode-test"
            )
        ).makeToolProducer(operationID: operationID)
    }

    private func evidenceQueryProducer() throws -> ReconstructionProducerIdentity {
        try toolProducer(operationID: .evidenceQuery)
    }

    private func testModelProducer() throws -> ReconstructionProducerIdentity {
        try modelProducer(operationIdentity: ReconstructionProductionTaskContract.modelRound)
    }

    private func modelProducer(
        operationIdentity: String
    ) throws -> ReconstructionProducerIdentity {
        try ReconstructionReceiptAuthority.makeModelProducerIdentity(
            lease: modelLease(),
            context: ReconstructionModelProducerIdentityContext(
                macScopeBuildIdentity: digest("a"),
                macScopeSourceIdentity: digest("b"),
                operationIdentity: operationIdentity,
                registryIdentity: "reconstruction.registry.v1",
                protocolIdentity: "reconstruction.protocol.v1",
                toolchainIdentity: "xcode-test"
            )
        )
    }
}

private actor RecordingBatchExecutionBuilder:
    ReconstructionProductionBatchExecutionBuilding
{
    private var attachmentURLs: [[URL]] = []

    func makeScheduler(
        for basis: ReconstructionProductionRoundBasis,
        authority: ReconstructionBatchAuthority
    ) async throws -> any ReconstructionProductionBatchScheduling {
        guard basis.job.jobID == authority.jobID,
              basis.checkpoint.checkpointID == authority.checkpointID,
              basis.checkpoint.revision == authority.checkpointRevision,
              basis.manifest.canonicalSHA256 == authority.corpusManifestSHA256 else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        attachmentURLs.append(basis.attachmentSources.map(\.verifiedURL))
        return EmptyProductionBatchScheduler()
    }

    func capturedAttachmentURLs() -> [[URL]] {
        attachmentURLs
    }
}

private struct EmptyProductionBatchScheduler: ReconstructionProductionBatchScheduling {
    func executeReadyTasks(
        _ tasks: [ReconstructionTaskRecord],
        authority: ReconstructionBatchAuthority,
        budget: ReconstructionBatchBudget,
        allowedTaskKinds: Set<ReconstructionTaskKind>?
    ) async throws -> [ReconstructionTerminalTaskResult] {
        []
    }
}

private actor ProductionBatchSchedulerLifecycleTracker {
    struct Counts: Equatable, Sendable {
        let created: Int
        let executed: Int
        let paused: Int
        let resumed: Int
        let childRetired: Int
        let jobAuthorityRetired: Int
    }

    private var created = 0
    private var executed = 0
    private var taskKindsByExecution: [Set<ReconstructionTaskKind>?] = []
    private var paused = 0
    private var resumed = 0
    private var childRetired = 0
    private var jobAuthorityRetired = 0

    func makeScheduler(
        basis: ReconstructionProductionRoundBasis,
        authority: ReconstructionBatchAuthority
    ) throws -> any ReconstructionProductionControllableBatchScheduling {
        guard basis.job.jobID == authority.jobID else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        created += 1
        return ProductionBatchSchedulerLifecycleProbe(tracker: self)
    }

    func recordExecution(allowedTaskKinds: Set<ReconstructionTaskKind>?) {
        executed += 1
        taskKindsByExecution.append(allowedTaskKinds)
    }
    func executionTaskKinds() -> [Set<ReconstructionTaskKind>?] { taskKindsByExecution }
    func recordPause() { paused += 1 }
    func recordResume() { resumed += 1 }
    func recordChildRetire() { childRetired += 1 }
    func recordJobAuthorityRetire() { jobAuthorityRetired += 1 }

    func counts() -> Counts {
        Counts(
            created: created,
            executed: executed,
            paused: paused,
            resumed: resumed,
            childRetired: childRetired,
            jobAuthorityRetired: jobAuthorityRetired
        )
    }
}

private actor ProductionBatchSchedulerLifecycleProbe:
    ReconstructionProductionControllableBatchScheduling
{
    private let tracker: ProductionBatchSchedulerLifecycleTracker

    init(tracker: ProductionBatchSchedulerLifecycleTracker) {
        self.tracker = tracker
    }

    func executeReadyTasks(
        _ tasks: [ReconstructionTaskRecord],
        authority: ReconstructionBatchAuthority,
        budget: ReconstructionBatchBudget,
        allowedTaskKinds: Set<ReconstructionTaskKind>?
    ) async throws -> [ReconstructionTerminalTaskResult] {
        await tracker.recordExecution(allowedTaskKinds: allowedTaskKinds)
        return []
    }

    func pause(jobID: UUID) async { await tracker.recordPause() }
    func resume(jobID: UUID) async { await tracker.recordResume() }
    func retire(jobID: UUID) async { await tracker.recordChildRetire() }
}

private struct StructuralPassThroughReceiptPlanAuthor:
    ReconstructionProductionReceiptPlanAuthoring
{
    func makeBatchCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan
    ) async throws -> ReconstructionJobCommitPlan {
        basePlan
    }

    func makeModelCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan {
        basePlan
    }

    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        basePlan
    }

    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        basePlan
    }

    func makeRecoveryPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }

    func makeControlPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ message: @autoclosure () -> String = "",
        _ expression: () async throws -> Void
    ) async {
        do {
            try await expression()
            XCTFail("Expected error. \(message())")
        } catch {}
    }
}
