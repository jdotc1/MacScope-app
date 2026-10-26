import CryptoKit
import Foundation
import XCTest

@testable import MacScope

/// Explicit, opt-in generator for the installed-app Task 10 fixture.  The fixture is never
/// hand-authored: the production `WorkspaceStore` serializer creates the package and this test
/// then records the exact resource tree used by the UI target.
///
/// Required physical regeneration after this source changes (do not run this during a
/// host-independent source gate):
///
/// ```sh
/// touch /private/tmp/MacScope-Task10-generate-installed-fixture
/// MACSCOPE_GHOSTTY_SOURCE_DIR=<path-to>/macscope-deps/ghostty-main \
/// MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=<path-to>/macscope-deps/sleigh-native-dcp05c \
/// ./Scripts/qualify_local_private_build.sh \
///   --work-root /private/tmp/macscope-task10-fixture-qual \
///   --integration-ref HEAD \
///   --mode focused-test \
///   --only-testing CoreTests/Task10InstalledWorkspaceFixtureGeneratorTests/testOptInGeneratesInstalledScenarioCatalogThroughProductionPersistence
/// ditto /private/tmp/macscope-task10-fixture-gen/Task10InstalledScenarios \
///   MacScope/Tests/MacScopeInstalledAppUITests/Fixtures/Task10InstalledScenarios
/// cp /private/tmp/macscope-task10-fixture-gen/Task10InstalledScenarios.fixture.json \
///   MacScope/Tests/MacScopeInstalledAppUITests/Fixtures/Task10InstalledScenarios.fixture.json
/// ```
///
/// Review the generated package tree and sidecar before staging them, then run the installed
/// matrix; the old schema-2 resource is deliberately not a substitute for this v3 proof.
@MainActor
final class Task10InstalledWorkspaceFixtureGeneratorTests: XCTestCase {
    private static let optInFlagPath = "/private/tmp/MacScope-Task10-generate-installed-fixture"
    private static let defaultOutputRoot = URL(
        fileURLWithPath: "/private/tmp/macscope-task10-fixture-gen",
        isDirectory: true
    )
    private static let outputRootEnvironmentKey = "MACSCOPE_TASK10_FIXTURE_OUTPUT_ROOT"
    private static let packageName = "Task10PersistedWorkspace.mscope"
    private static let sidecarName = "Task10PersistedWorkspace.fixture.json"
    private static let workspaceName = "Task 10 persisted workspace"

    private struct ScenarioOracle: Codable {
        let expectedCheckpointFreshness: String?
        let expectedCorpusOccurrenceCount: Int
        let expectedCorpusRelationCount: Int
        let expectedCorpusUniqueContentCount: Int
        let expectedCorpusUnresolvedRelationCount: Int
        let expectedCurrentGapOperationID: String?
        let expectedEvidenceCount: Int
        let expectedEvidenceCurrentCount: Int
        let expectedEvidenceHistoricalCount: Int
        let expectedEvidenceStaleCount: Int
        let expectedEvidenceUnavailableCount: Int
        let expectedEditorMode: String
        let expectedFocusedImageName: String
        let expectedFunctionAddress: UInt64?
        let expectedStartingImageName: String?
        let expectedStartingFunctionAddress: UInt64?
        let expectedGapCount: Int
        let expectedJobID: UUID?
        let expectedJobState: String?
        let expectedNavigableEvidenceID: UUID?
        let expectedPauseCause: String?
        let expectedResumeTarget: String?
        let expectedTaskCount: Int
        let forbiddenRawPathCanary: String?
        let forbiddenRawPromptCanary: String?
        let forbiddenRawPseudocodeCanary: String?
        let packageName: String
        let packageTreeSHA256: String
        let scenarioID: String
        let workspaceName: String
    }

    private struct ScenarioCatalog: Codable {
        let generator: String
        let provider: ProviderOracle
        let scenarios: [ScenarioOracle]
        let schemaVersion: Int
    }

    private struct ProviderOracle: Codable {
        let displayName: String
        let instanceID: String
        let modelKey: String
        let publisher: String
    }

    func testScenarioSeedPackagesAreProductionReadableAndMatchClosedStates() throws {
        for scenario in Task10InstalledScenario.allCases {
            let seed = try Task10InstalledScenarioSeedPackage.make(scenario)
            defer { seed.remove() }
            let opened = try MacScopeDocumentPackage.openPackage(from: seed.packageURL)
            XCTAssertEqual(opened.manifest.workspaceName, scenario.workspaceName)
            XCTAssertEqual(opened.reconstructionState.jobs.first?.jobID, seed.expectedJobID)
            XCTAssertEqual(opened.reconstructionState.jobs.first?.state, scenario.expectedJobState)
            XCTAssertEqual(
                opened.reconstructionState.jobs.first?.pauseContext?.cause,
                scenario.pauseCause
            )
            XCTAssertEqual(
                opened.reconstructionState.jobs.first?.pauseContext?.resumeTarget,
                scenario.resumeTarget
            )
            XCTAssertEqual(opened.reconstructionState.tasks.count, seed.expectedTaskCount)
            XCTAssertEqual(opened.reconstructionState.evidence.count, seed.expectedEvidenceCount)
            XCTAssertEqual(opened.reconstructionState.evidenceGaps.count, seed.expectedGapCount)
            let currentManifest = try XCTUnwrap(
                opened.reconstructionState.corpusManifests.first(where: {
                    $0.canonicalSHA256
                        == opened.reconstructionState.projects.first?.currentCorpusManifestSHA256
                })
            )
            XCTAssertEqual(currentManifest.artifacts.count, seed.expectedCorpusOccurrenceCount)
            XCTAssertEqual(
                Set(currentManifest.artifacts.map(\.contentIdentity)).count,
                seed.expectedCorpusUniqueContentCount
            )
            XCTAssertEqual(currentManifest.relations.count, seed.expectedCorpusRelationCount)
            XCTAssertEqual(
                currentManifest.relations.filter { $0.kind == .unresolvedDependency }.count,
                seed.expectedCorpusUnresolvedRelationCount
            )
            let restored = try WorkspaceStore.restoredPackage(
                from: seed.packageURL,
                scheduleDurableRecovery: false
            )
            if scenario == .navigationCurrent {
                XCTAssertEqual(opened.manifest.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
                XCTAssertEqual(opened.manifest.analysisFormatVersion, WorkspacePackageManifest.reconstructionFormatVersion)
                let startingName = try XCTUnwrap(seed.expectedStartingImageName)
                let startingAddress = try XCTUnwrap(seed.expectedStartingFunctionAddress)
                let startingBinary = try XCTUnwrap(
                    opened.manifest.binaries.first(where: { $0.displayName == startingName })
                )
                let startingBytes = try Data(contentsOf: seed.packageURL.appendingPathComponent(
                    startingBinary.attachmentRelativePath
                ))
                XCTAssertEqual(startingBinary.kind, "Raw data")
                XCTAssertEqual(startingBytes, Data("T10START".utf8))
                XCTAssertEqual(startingBinary.fileSize, 8)
                XCTAssertEqual(startingBinary.fileHash, MacScopeDocumentPackage.fileHash(for: startingBytes))
                XCTAssertNotEqual(startingBinary.slot, .primary)
                XCTAssertNotEqual(startingAddress, seed.expectedFunctionAddress)
                XCTAssertEqual(restored.focusedImageSlot, startingBinary.slot)
                XCTAssertEqual(restored.selectedAddress, startingAddress)
            }
        }
    }

    /// An active fixture must survive the real pre-inference planner, not merely deserialize an
    /// active enum. The former empty graph failed before the held installed-provider chat route.
    func testContinuationFixturesReachProductionModelBoundaryWithoutFailing() async throws {
        for scenario in [Task10InstalledScenario.activeExecutingReads, .activeRetrieving,
                         .pausedUserRetrieving, .pausedModelUnavailableAwaitingModel] {
            try await verifyProductionModelBoundary(scenario)
        }
    }

    func testLiveCoordinatorReachesModelWithoutRecoveringItsOwnActiveLeaves() async throws {
        for scenario in [Task10InstalledScenario.activeExecutingReads, .activeRetrieving,
                         .pausedUserRetrieving, .pausedModelUnavailableAwaitingModel] {
            try await verifyProductionModelBoundary(scenario, throughCoordinator: true)
        }
    }

    func testFreshCoordinatorRecoversInterruptedModelLeavesThenReachesModel() async throws {
        try await verifyProductionModelBoundary(
            .activeExecutingReads, throughCoordinator: true, reopenActiveLeaves: true
        )
    }

    /// Catch the production loop completing ingestion/indexing and admitting a provider while
    /// its durable checkpoint still says created. Keep the initial transaction and real planner.
    func testCreatedCoordinatorCommitsActualPhasesBeforeModelExecution() async throws {
        try await verifyProductionModelBoundary(.noJob, throughCoordinator: true)
    }

    func testCreatedCoordinatorCyclesRealReceiptCommitsAndCompletesFinalRetrieval() async throws {
        try await verifyProductionModelBoundary(
            .noJob, throughCoordinator: true, completesModelCycles: true
        )
    }

    func testRestoredLegacyFinalLeavesCompleteWithoutReplayingRegularModel() async throws {
        for state in [ReconstructionJobState.executingReads, .awaitingModel] {
            for activated in [false, true] {
                try await verifyProductionModelBoundary(
                    state == .executingReads ? .activeExecutingReads : .pausedModelUnavailableAwaitingModel,
                    throughCoordinator: true, legacyFinalState: state,
                    legacyFinalAlreadyActivated: activated
                )
            }
        }
    }

    func testCoordinatorPauseResumesEveryExactActivePhaseBeforeExecutingWork() async throws {
        let phases: [ReconstructionJobState] = [
            .created, .ingesting, .indexing, .retrieving, .awaitingModel, .executingReads,
            .acceptingEvidence, .checkpointing,
        ]
        XCTAssertEqual(Set(phases), Set(ReconstructionJobState.activeStates))
        for phase in phases {
            do {
                try await verifyProductionModelBoundary(
                    .noJob, throughCoordinator: true, pauseResumeState: phase
                )
            } catch {
                XCTFail("Exact resume of \(phase) threw: \(error)")
            }
        }
    }

    private func verifyProductionModelBoundary(
        _ scenario: Task10InstalledScenario,
        throughCoordinator: Bool = false,
        reopenActiveLeaves: Bool = false,
        completesModelCycles: Bool = false,
        legacyFinalState: ReconstructionJobState? = nil,
        legacyFinalAlreadyActivated: Bool = false,
        pauseResumeState: ReconstructionJobState? = nil
    ) async throws {
        let seed = try Task10InstalledScenarioSeedPackage.make(scenario)
        defer { seed.remove() }
        let opened = try MacScopeDocumentPackage.openPackage(from: seed.packageURL)
        let sidecars = seed.rootURL.appendingPathComponent("sidecars", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sidecars, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: ReconstructionWorkspaceStateBinding(
                workspaceID: opened.manifest.workspaceUUID,
                documentID: opened.manifest.documentID,
                canonicalPackagePath: seed.packageURL.resolvingSymlinksInPath().path
            ),
            packageState: opened.reconstructionState,
            packageAttachmentSources: opened.reconstructionAttachmentSources,
            baseDirectoryURL: sidecars
        )
        do {
            let owner = try runtime.databaseOwner()
            let job: ReconstructionJobRecord
            if scenario == .noJob {
                let project = try XCTUnwrap(opened.reconstructionState.projects.first)
                let manifest = try XCTUnwrap(opened.reconstructionState.corpusManifests.first)
                let committed = try await owner.commitInitialJob(
                    workspaceID: opened.manifest.workspaceUUID,
                    mutation: ReconstructionInitialJobMutation(
                        jobID: UUID(), projectID: project.projectID,
                        selectedOccurrenceIDs: [try XCTUnwrap(manifest.artifacts.first).occurrenceID],
                        objective: "Recover the selected opaque fixture",
                        budget: try ReconstructionJobBudget(
                            maxRounds: 8, maxTasks: 128, maxEvidenceRecords: 512,
                            maxEncodedBytes: 4 * 1_024 * 1_024
                        )
                    )
                )
                XCTAssertEqual(committed.job.state, .created)
                XCTAssertEqual(committed.checkpoint.coordinatorState, .created)
                XCTAssertEqual(committed.checkpoint.revision, 0)
                XCTAssertNil(committed.checkpoint.parentCheckpointID)
                XCTAssertTrue(committed.state.tasks.allSatisfy { $0.state == .pending })
                job = committed.job
            } else {
                job = try XCTUnwrap(opened.reconstructionState.jobs.first)
                XCTAssertEqual(job.state, scenario.expectedJobState)
            }
            XCTAssertEqual(job.pauseContext?.cause, scenario.pauseCause)
            XCTAssertEqual(job.pauseContext?.resumeTarget, scenario.resumeTarget)
            let activeState = scenario.resumeTarget ?? job.state
            let initial = try await owner.load(workspaceID: opened.manifest.workspaceUUID)
            XCTAssertEqual(Set(initial.tasks.map(\.identity.kind)), [
                .ingest, .classify, .discoverRelations,
            ])
            let receiptAuthor = ReconstructionProductionReceiptPlanAuthor(
                modelProducerContext: ReconstructionModelProducerIdentityContext(
                    macScopeBuildIdentity: String(repeating: "a", count: 64),
                    macScopeSourceIdentity: String(repeating: "b", count: 64),
                    operationIdentity: ReconstructionProductionTaskContract.modelRound,
                    registryIdentity: "reconstruction.registry.v1",
                    protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                    toolchainIdentity: "fixture-test"
                )
            )
            let registry = ReconstructionProductionRoundBasisRegistry()
            let execution = ReconstructionProductionBatchExecutionController(
                durableJobID: job.jobID,
                builder: { basis, _ in
                    ReconstructionBatchScheduler(
                        durableJobID: job.jobID,
                        executor: ReconstructionBatchTaskExecutor(
                            resolver: try ReconstructionHeadlessAnalysisRequestResolver(
                                manifest: basis.manifest,
                                attachmentSources: basis.attachmentSources
                            ),
                            headless: Task10FixtureRejectingHeadlessExecutor(),
                            native: Task10FixtureRejectingNativeDecompiler()
                        )
                    )
                },
                retireJobAuthority: {}
            )
            let materializer = ReconstructionProductionJobRoundMaterializer(
                cutProvider: ReconstructionProductionCommittedRoundCutProvider(
                    workspaceID: opened.manifest.workspaceUUID,
                    owner: owner,
                    batchExecutionBuilder: execution,
                    preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                        evidenceQueryProducer: receiptAuthor.makeToolProducer(
                            operationID: .evidenceQuery
                        )
                    ),
                    basisRegistry: registry,
                    maximumConcurrentTasks: 1
                ),
                planBuilder: ReconstructionProductionRoundPlanBuilder(
                    basisRegistry: registry, receiptAuthor: receiptAuthor
                )
            )
            let persistence = ReconstructionDatabaseJobPersistence(
                workspaceID: opened.manifest.workspaceUUID, owner: owner
            )
            if throughCoordinator && !reopenActiveLeaves {
                if let pauseResumeState {
                    try await verifyExactPhasePauseResume(
                        phase: pauseResumeState, materializer: materializer,
                        persistence: persistence, jobID: job.jobID
                    )
                } else if let legacyFinalState {
                    try await verifyRestoredLegacyFinalCut(
                        state: legacyFinalState, activated: legacyFinalAlreadyActivated,
                        materializer: materializer, persistence: persistence,
                        owner: owner, workspaceID: opened.manifest.workspaceUUID,
                        jobID: job.jobID, registry: registry, receiptAuthor: receiptAuthor
                    )
                } else {
                    try await verifyCoordinatorModelBoundary(
                    materializer: materializer, persistence: persistence,
                    jobID: job.jobID, expectedRecoveryCount: 0,
                    expectedPhases: scenario == .noJob ? [
                        .created, .ingesting, .indexing, .retrieving, .awaitingModel, .executingReads,
                    ] : nil,
                    completesModelCycles: completesModelCycles
                )
                }
                if completesModelCycles || legacyFinalState != nil || pauseResumeState != nil {
                    let completed = try await owner.load(workspaceID: opened.manifest.workspaceUUID)
                    let result = try XCTUnwrap(completed.finalResults.first)
                    XCTAssertEqual(completed.finalResults.count, 1)
                    XCTAssertEqual(result.kind, .insufficientEvidence)
                    XCTAssertEqual(result.checkpointID, completed.jobs.first?.currentCheckpointID)
                    let checkpoint = try XCTUnwrap(completed.checkpoints.first {
                        $0.checkpointID == result.checkpointID
                    })
                    XCTAssertEqual(checkpoint.coordinatorState, .completed)
                    XCTAssertEqual(checkpoint.revision, result.checkpointRevision)
                    XCTAssertTrue(checkpoint.modelReceiptIDs.contains(result.modelReceiptID))
                    XCTAssertTrue(completed.tasks.allSatisfy { $0.state == .completed })
                }
                await execution.retire(jobID: job.jobID)
                await runtime.close()
                return
            }
            var reachedModel = false
            // Three corpus leaves, activation and at most two phase admissions, then preparation.
            // The original executingReads fixture remains same-phase; retrieving/awaitingModel
            // may move only forward to execution, never backward through the new creation path.
            // No real model,
            // native worker, or headless binary analysis is needed for this opaque occurrence.
            for _ in 0..<7 {
                let snapshot = try await persistence.load(jobID: job.jobID)
                let permittedStates: [ReconstructionJobState] = switch activeState {
                case .retrieving: [.retrieving, .awaitingModel, .executingReads]
                case .awaitingModel: [.awaitingModel, .executingReads]
                default: [activeState]
                }
                XCTAssertTrue(permittedStates.contains(try XCTUnwrap(snapshot.currentDurableActiveState)))
                XCTAssertEqual(
                    snapshot.checkpointEvidenceFrontierSHA256, snapshot.evidenceFrontierSHA256
                )
                switch try await materializer.prepare(snapshot: snapshot) {
                case .commit(let plan):
                    if case .advancePhase(let phase) = plan.disposition {
                        XCTAssertTrue(permittedStates.contains(phase))
                        try ReconstructionJobStateMachine.transition(
                            from: snapshot.currentDurableJobState, to: phase, resumeTarget: nil
                        )
                    } else {
                        XCTAssertEqual(plan.disposition, .continue)
                    }
                    _ = try await owner.commit(try XCTUnwrap(plan.mutation))
                case .model(let prepared):
                    let state = try await owner.load(workspaceID: opened.manifest.workspaceUUID)
                    XCTAssertNotNil(try ReconstructionProductionRoundPlanBuilder
                        .authorizedRegularModelFrontier(in: state.tasks))
                    reachedModel = true
                    if reopenActiveLeaves {
                        await materializer.discardPreparedRound(
                            snapshot: snapshot, prepared: prepared
                        )
                    }
                }
                if reachedModel { break }
            }
            XCTAssertTrue(reachedModel, "\(scenario.rawValue) never reached model execution.")
            if reopenActiveLeaves {
                try await verifyCoordinatorModelBoundary(
                    materializer: materializer, persistence: persistence,
                    jobID: job.jobID, expectedRecoveryCount: 1
                )
            }
            await execution.retire(jobID: job.jobID)
            await runtime.close()
        } catch {
            await runtime.close()
            throw error
        }
    }

    private func verifyExactPhasePauseResume(
        phase: ReconstructionJobState,
        materializer: ReconstructionProductionJobRoundMaterializer,
        persistence: ReconstructionDatabaseJobPersistence,
        jobID: UUID
    ) async throws {
        // The ordinary cycle commits revision16. Pause/resume add2; interrupted model leaves
        // require one additional lawful reactivation after the existing fresh-token recovery.
        let planner = Task10FixtureCoordinatorBoundaryPlanner(
            materializer: materializer, completesModelCycles: true, maximumCheckpointRevision: 20
        )
        var reached = false
        for _ in 0..<17 {
            let snapshot = try await persistence.load(jobID: jobID)
            if snapshot.currentDurableJobState == phase { reached = true; break }
            let plan = try await planner.planRound(from: snapshot)
            _ = try await persistence.commit(plan, for: snapshot)
        }
        XCTAssertTrue(reached, "Did not reach actual \(phase) phase through production commits")
        guard reached else { return }
        let beforePause = try await persistence.load(jobID: jobID)
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence, planner: planner, publisher: Task10FixtureCoordinatorPublisher()
        )
        await coordinator.pause(jobID: jobID)
        let paused = try await persistence.load(jobID: jobID)
        XCTAssertEqual(paused.currentDurableJobState, .paused)
        XCTAssertEqual(paused.pauseContext?.resumeTarget, phase)
        XCTAssertEqual(paused.checkpointRevision, beforePause.checkpointRevision + 1)
        XCTAssertEqual(paused.tasks, beforePause.tasks)

        // Inspect without committing: a paused cut must restore exactly its durable phase before
        // ingest/index work or next model activation can mutate the graph or acquire request input.
        guard case .commit(let admission) = try await materializer.prepare(snapshot: paused) else {
            return XCTFail("Paused \(phase) offered model execution before exact resume admission")
        }
        let mutation = try XCTUnwrap(admission.mutation)
        XCTAssertEqual(admission.disposition, .continue)
        XCTAssertEqual(mutation.successorCheckpoint.coordinatorState, phase)
        XCTAssertNil(mutation.successorPauseContext)
        XCTAssertTrue(mutation.taskTransitions.isEmpty, "Resume \(phase) executed/activated tasks")
        XCTAssertTrue(mutation.newTasks.isEmpty)
        XCTAssertTrue(mutation.evidence.isEmpty && mutation.evidenceRelations.isEmpty)
        XCTAssertTrue(mutation.evidenceGaps.isEmpty && mutation.finalResults.isEmpty)
        XCTAssertTrue(mutation.toolReceipts.isEmpty && mutation.modelReceipts.isEmpty)
        XCTAssertEqual(mutation.successorCheckpoint.pendingTaskIDs,
                       paused.tasks.filter { $0.state == .pending }.map(\.identity.taskID).sorted {
                           $0.uuidString.lowercased() < $1.uuidString.lowercased()
                       })
        // Exercise the actual resume=start coordinator seam, not a manually advanced test state.
        await coordinator.resume(jobID: jobID)
        let completed = try await persistence.load(jobID: jobID)
        XCTAssertEqual(completed.currentDurableJobState, .completed, "Resume \(phase) failed")
        let interrupted = beforePause.tasks.contains { $0.state == .running }
        XCTAssertEqual(completed.checkpointRevision, interrupted ? 19 : 18)
        XCTAssertNil(completed.pauseContext)
        let preparations = await planner.modelPreparationCount
        XCTAssertEqual(preparations, 3, "Exactly two ordinary rounds and one final request")
    }

    private func verifyRestoredLegacyFinalCut(
        state: ReconstructionJobState,
        activated: Bool,
        materializer: ReconstructionProductionJobRoundMaterializer,
        persistence: ReconstructionDatabaseJobPersistence,
        owner: ReconstructionDatabaseOwner,
        workspaceID: UUID,
        jobID: UUID,
        registry: ReconstructionProductionRoundBasisRegistry,
        receiptAuthor: ReconstructionProductionReceiptPlanAuthor
    ) async throws {
        // Reach a genuinely activated ordinary frontier in the real DB, stopping before the
        // new phase admission. Then reproduce the former same-state successful receipt commit.
        for _ in 0..<5 {
            let snapshot = try await persistence.load(jobID: jobID)
            if try ReconstructionProductionRoundPlanBuilder
                .authorizedRegularModelFrontier(in: snapshot.tasks) != nil { break }
            guard case .commit(let plan) = try await materializer.prepare(snapshot: snapshot) else {
                return XCTFail("Expected durable batch/model activation before legacy response")
            }
            _ = try await persistence.commit(plan, for: snapshot)
        }
        var basis = try ReconstructionProductionRoundBasis(rows: await owner.captureProductionRoundRows(
            workspaceID: workspaceID, jobID: jobID
        ))
        XCTAssertEqual(basis.job.state, state)
        XCTAssertNotNil(try ReconstructionProductionRoundPlanBuilder
            .authorizedRegularModelFrontier(in: basis.tasks))
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: receiptAuthor.makeToolProducer(operationID: .evidenceQuery)
        ).makePreparedRound(from: basis)
        try await registry.register(basis, prepared: prepared)
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry, receiptAuthor: receiptAuthor
        )
        let cut = ReconstructionProductionCommittedRoundCut(
            snapshot: basis.snapshot, parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            prepared: prepared, batchTerminalResults: []
        )
        let responsePlanner = Task10FixtureCoordinatorBoundaryPlanner(
            materializer: materializer, completesModelCycles: true
        )
        let response = try await responsePlanner.commitModelFixture(
            snapshot: basis.snapshot, prepared: prepared, directCut: cut, directBuilder: builder
        )
        let mutation = try XCTUnwrap(response.mutation)
        let legacy = try legacySameStateFixturePlan(
            basis: basis, checkpoint: mutation.successorCheckpoint, payload: mutation
        )
        _ = try await persistence.commit(legacy, for: basis.snapshot)
        basis = try ReconstructionProductionRoundBasis(rows: await owner.captureProductionRoundRows(
            workspaceID: workspaceID, jobID: jobID
        ))
        if activated {
            let final = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder
                .pendingFinalSynthesisFrontier(in: basis.tasks))
            let activation = try legacySameStateFixturePlan(
                basis: basis, checkpoint: basis.checkpoint,
                activatingTaskID: final.model.identity.taskID,
                transitions: [.init(
                    taskID: final.model.identity.taskID, expectedState: .pending,
                    successorState: .running, diagnostic: nil
                )]
            )
            _ = try await persistence.commit(activation, for: basis.snapshot)
        }
        let opening = try await persistence.load(jobID: jobID)
        XCTAssertEqual(opening.currentDurableJobState, state)
        XCTAssertEqual(opening.consecutiveModelRoundsWithoutEvidence, 1)
        let planner = Task10FixtureCoordinatorBoundaryPlanner(
            materializer: materializer, completesModelCycles: true
        )
        // A fresh coordinator token loads the already-committed legacy cut. Recovery must reset
        // only the interrupted final leaf; no completed ordinary request is replayed.
        await ReconstructionJobCoordinator(
            persistence: persistence, planner: planner, publisher: Task10FixtureCoordinatorPublisher()
        ).start(jobID: jobID)
        let phases = await planner.observedPhases
        XCTAssertEqual(phases, (state == .awaitingModel ? [.awaitingModel] : []) + [
            .executingReads, .acceptingEvidence, .checkpointing, .retrieving,
        ])
        let modelPreparations = await planner.modelPreparationCount
        XCTAssertEqual(modelPreparations, 1, "Completed ordinary model round must not replay")
        let recoveries = await planner.recoveryTransitions
        XCTAssertEqual(recoveries.count, activated ? 1 : 0)
        if activated {
            XCTAssertEqual(recoveries.first?.count, 1)
            XCTAssertEqual(recoveries.first?.first?.expectedState, .running)
            XCTAssertEqual(recoveries.first?.first?.successorState, .pending)
        }
        let final = try await persistence.load(jobID: jobID)
        XCTAssertEqual(final.currentDurableJobState, .completed)
        XCTAssertEqual(final.consecutiveModelRoundsWithoutEvidence, 1)
        XCTAssertEqual(final.checkpointRevision - opening.checkpointRevision,
                       (state == .awaitingModel ? 6 : 5) + (activated ? 1 : 0))
    }

    /// Reconstructs a historically valid same-state cut using accessible canonical DTOs, not
    /// the author's private implementation. Receipt-bearing payloads come unchanged from the
    /// real production model author; the receipt/checkpoint IDs and revision remain identical.
    private func legacySameStateFixturePlan(
        basis: ReconstructionProductionRoundBasis,
        checkpoint: ReconstructionCheckpoint,
        payload: ReconstructionCheckpointMutation? = nil,
        activatingTaskID: UUID? = nil,
        transitions: [ReconstructionTaskTransition] = []
    ) throws -> ReconstructionJobCommitPlan {
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: payload == nil ? UUID() : checkpoint.checkpointID,
            jobID: basis.job.jobID, revision: basis.checkpoint.revision + 1,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: checkpoint.pendingTaskIDs.filter { $0 != activatingTaskID },
            runningTaskIDs: checkpoint.runningTaskIDs + (activatingTaskID.map { [$0] } ?? []),
            completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs,
            blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: checkpoint.modelReceiptIDs,
            toolReceiptIDs: checkpoint.toolReceiptIDs,
            coordinatorState: basis.job.state, terminalReason: nil
        )
        let mutation = ReconstructionCheckpointMutation(
            jobID: basis.job.jobID,
            expectedParentCheckpointID: basis.checkpoint.checkpointID,
            expectedParentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            expectedParentRevision: basis.checkpoint.revision,
            evidence: payload?.evidence ?? [],
            evidenceRelations: payload?.evidenceRelations ?? [],
            evidenceGaps: payload?.evidenceGaps ?? [],
            toolReceipts: payload?.toolReceipts ?? [],
            modelReceipts: payload?.modelReceipts ?? [],
            finalResults: payload?.finalResults ?? [],
            newTasks: payload?.newTasks ?? [],
            taskTransitions: payload?.taskTransitions ?? transitions,
            freshnessAuthority: payload?.freshnessAuthority ?? basis.freshnessAuthority,
            successorCheckpoint: successor
        )
        return .init(
            successorRevision: successor.revision,
            acceptedEvidenceCount: mutation.evidence.count,
            disposition: .continue, mutation: mutation
        )
    }

    private func verifyCoordinatorModelBoundary(
        materializer: ReconstructionProductionJobRoundMaterializer,
        persistence: ReconstructionDatabaseJobPersistence,
        jobID: UUID,
        expectedRecoveryCount: Int,
        expectedPhases: [ReconstructionJobState]? = nil,
        completesModelCycles: Bool = false
    ) async throws {
        let opening = try await persistence.load(jobID: jobID)
        let resumesPausedBoundary = !completesModelCycles
            && opening.currentDurableJobState == .paused
        let planner = Task10FixtureCoordinatorBoundaryPlanner(
            materializer: materializer, completesModelCycles: completesModelCycles,
            // Paused seed revision1 + exact resume +3 corpus commits +activation +execution
            // reaches preparation at7, then the normal cancellation checkpoint is exactly8.
            maximumCheckpointRevision: resumesPausedBoundary ? 8 : nil
        )
        let coordinator = ReconstructionJobCoordinator(
            persistence: persistence, planner: planner,
            publisher: Task10FixtureCoordinatorPublisher()
        )
        await coordinator.start(jobID: jobID)
        let modelPreparations = await planner.modelPreparationCount
        let recoveries = await planner.recoveryTransitions
        if let expectedPhases {
            let observedPhases = await planner.observedPhases
            let completeCycle: [ReconstructionJobState] = [
                .acceptingEvidence, .checkpointing, .retrieving, .awaitingModel, .executingReads,
                .acceptingEvidence, .checkpointing, .retrieving,
            ]
            XCTAssertEqual(
                observedPhases, expectedPhases + (completesModelCycles ? completeCycle : [])
            )
        }
        let final = try await persistence.load(jobID: jobID)
        XCTAssertEqual(
            modelPreparations, completesModelCycles ? 3 : 1,
            "Live model activation was mistaken for crash debris."
        )
        XCTAssertEqual(recoveries.count, expectedRecoveryCount)
        for transitions in recoveries {
            XCTAssertEqual(transitions.count, 2)
            XCTAssertTrue(transitions.allSatisfy {
                $0.expectedState == .running && $0.successorState == .pending
            })
        }
        if completesModelCycles {
            XCTAssertEqual(final.checkpointRevision, 16)
            XCTAssertEqual(final.currentDurableJobState, .completed)
        } else {
            XCTAssertLessThanOrEqual(final.checkpointRevision, 8, "Fixture must bound runaway commits.")
            XCTAssertEqual(final.currentDurableJobState, .cancelled)
            if resumesPausedBoundary {
                XCTAssertEqual(opening.checkpointRevision, 1)
                let revisions = await planner.modelPreparationRevisions
                XCTAssertEqual(revisions, [7], "Exact resume must precede the real model boundary")
                XCTAssertEqual(final.checkpointRevision, 8)
            }
        }
    }

    func testExplicitGeneratorOutputRootRejectsExistingDirectory() throws {
        let root = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../task10-output-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        XCTAssertEqual(
            try Self.outputRoot(environment: [Self.outputRootEnvironmentKey: root.path]), root
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try Self.outputRoot(environment: [
            Self.outputRootEnvironmentKey: root.path,
        ]))
        XCTAssertThrowsError(try Self.outputRoot(environment: [
            Self.outputRootEnvironmentKey: "relative-fixture-output",
        ]))
        let alias = root.deletingLastPathComponent()
            .appendingPathComponent("task10-output-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try Self.outputRoot(environment: [
            Self.outputRootEnvironmentKey: alias.appendingPathComponent("new-output").path,
        ]))
        XCTAssertThrowsError(try Self.outputRoot(environment: [
            Self.outputRootEnvironmentKey:
                root.appendingPathComponent("missing-parent/new-output").path,
        ]))
    }

    private static func outputRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let path = environment[outputRootEnvironmentKey] else { return defaultOutputRoot }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        // Foundation may leave an aliased path unchanged when its final component is absent.
        // Resolve the existing parent instead, and admit only one new child of that directory.
        let parent = root.deletingLastPathComponent()
        let parentAttributes = try? FileManager.default.attributesOfItem(atPath: parent.path)
        guard path.hasPrefix("/"),
              parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path,
              (parentAttributes?[.type] as? FileAttributeType) == .typeDirectory,
              !FileManager.default.fileExists(atPath: root.path),
              (try? FileManager.default.attributesOfItem(atPath: root.path)) == nil else {
            throw NSError(
                domain: "MacScopeTests.Task10InstalledFixtureOutput", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Explicit fixture output must be a new absolute directory without path aliases."]
            )
        }
        return root
    }

    func testIsolatedFixtureCopiesHaveIndependentProductionSidecarsAndStableSaveIdentity()
        async throws
    {
        let fixturesRoot = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacScopeInstalledAppUITests/Fixtures/Task10InstalledScenarios")
        // Keep test artifacts beside, not inside, this checkout. The parent controls the source
        // checkout location and serialized native build; no user's production sidecars are used.
        let root = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../", isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent("task10-identity-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecars = root.appendingPathComponent("sidecars", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sidecars, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var documentIDs = Set<UUID>()
        var workspaceIDs = Set<UUID>()
        var sidecarPaths = Set<String>()
        for scenario in Task10InstalledScenario.allCases {
            let source = fixturesRoot.appendingPathComponent("\(scenario.rawValue).mscope")
            let original = try MacScopeDocumentPackage.openPackage(from: source)
            for copyIndex in 0..<2 {
                let copy = root.appendingPathComponent("\(scenario.rawValue)-\(copyIndex).mscope")
                try FileManager.default.copyItem(at: source, to: copy)
                let manifestURL = copy.appendingPathComponent("manifest.json")
                let isolated = try Task10FixtureDocumentIdentity.isolatedManifest(
                    from: Data(contentsOf: manifestURL)
                )
                try isolated.write(to: manifestURL, options: .atomic)
                for path in try FileManager.default.subpathsOfDirectory(atPath: source.path)
                    where path != "manifest.json" {
                    let sourceFile = source.appendingPathComponent(path)
                    if try sourceFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        XCTAssertEqual(
                            try Data(contentsOf: copy.appendingPathComponent(path)),
                            try Data(contentsOf: sourceFile), path
                        )
                    }
                }
                let opened = try MacScopeDocumentPackage.openPackage(from: copy)
                XCTAssertNotEqual(opened.manifest.documentID, original.manifest.documentID)
                XCTAssertNotEqual(opened.manifest.workspaceUUID, original.manifest.workspaceUUID)
                XCTAssertTrue(documentIDs.insert(opened.manifest.documentID).inserted)
                XCTAssertTrue(workspaceIDs.insert(opened.manifest.workspaceUUID).inserted)
                XCTAssertEqual(opened.reconstructionState, original.reconstructionState)
                let binding = ReconstructionWorkspaceStateBinding(
                    workspaceID: opened.manifest.workspaceUUID,
                    documentID: opened.manifest.documentID,
                    canonicalPackagePath: copy.resolvingSymlinksInPath().standardizedFileURL.path
                )
                let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: opened.reconstructionState,
                    packageAttachmentSources: opened.reconstructionAttachmentSources,
                    baseDirectoryURL: sidecars
                )
                XCTAssertTrue(sidecarPaths.insert(runtime.sidecarDirectoryURL.path).inserted)
                await runtime.close()

                let store = try WorkspaceStore.restoredPackage(
                    from: copy, scheduleDurableRecovery: false
                )
                XCTAssertTrue(store.writeDocumentPackage(to: copy), store.saveError ?? "Save failed")
                let reopened = try MacScopeDocumentPackage.openPackage(from: copy)
                XCTAssertEqual(reopened.manifest.documentID, binding.documentID)
                XCTAssertEqual(reopened.manifest.workspaceUUID, binding.workspaceID)
                XCTAssertEqual(reopened.reconstructionState, opened.reconstructionState)
                let reopenedRuntime = try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: reopened.reconstructionState,
                    packageAttachmentSources: reopened.reconstructionAttachmentSources,
                    baseDirectoryURL: sidecars
                )
                XCTAssertEqual(reopenedRuntime.sidecarDirectoryURL, runtime.sidecarDirectoryURL)
                await reopenedRuntime.close()
            }
        }
        XCTAssertEqual(documentIDs.count, Task10InstalledScenario.allCases.count * 2)
        XCTAssertEqual(workspaceIDs.count, documentIDs.count)
        XCTAssertEqual(sidecarPaths.count, documentIDs.count)
    }

    func testCommittedInstalledScenarioPackagesAreProductionReadable() throws {
        let fixturesRoot = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacScopeInstalledAppUITests/Fixtures/Task10InstalledScenarios")
        for scenario in Task10InstalledScenario.allCases {
            let packageURL = fixturesRoot.appendingPathComponent("\(scenario.rawValue).mscope")
            do {
                let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
                XCTAssertEqual(opened.manifest.workspaceName, scenario.workspaceName)
            } catch {
                XCTFail("Committed installed scenario \(scenario.rawValue) cannot open: \(error)")
            }
        }
    }

    func testOptInGeneratesInstalledWorkspaceFixtureThroughProductionPersistence() throws {
        guard FileManager.default.fileExists(atPath: Self.optInFlagPath) else {
            throw XCTSkip("Create \(Self.optInFlagPath) to generate the Task 10 UI fixture.")
        }
        let outputRoot = try Self.outputRoot()
        let packageURL = outputRoot.appendingPathComponent(Self.packageName, isDirectory: true)
        let sidecarURL = outputRoot.appendingPathComponent(Self.sidecarName)
        let manager = FileManager.default
        try manager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        if manager.fileExists(atPath: packageURL.path) {
            try manager.removeItem(at: packageURL)
        }
        if manager.fileExists(atPath: sidecarURL.path) {
            try manager.removeItem(at: sidecarURL)
        }

        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.workspaceName = Self.workspaceName
        XCTAssertTrue(
            store.writeDocumentPackage(
                to: packageURL,
                now: Date(timeIntervalSince1970: 1_725_000_000)
            ),
            store.saveError ?? "The production writer rejected the fixture package."
        )
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(opened.manifest.workspaceName, Self.workspaceName)

        let sidecar = FixtureSidecar(
            schemaVersion: 1,
            generator: "WorkspaceStore.writeDocumentPackage",
            workspaceName: Self.workspaceName,
            packageTreeSHA256: try packageTreeSHA256(at: packageURL)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: sidecarURL, options: .atomic)
    }

    func testOptInGeneratesInstalledScenarioCatalogThroughProductionPersistence() throws {
        guard FileManager.default.fileExists(atPath: Self.optInFlagPath) else {
            throw XCTSkip("Create \(Self.optInFlagPath) to generate the Task 10 UI fixtures.")
        }
        let outputRoot = try Self.outputRoot()
        let scenarioRoot = outputRoot.appendingPathComponent(
            "Task10InstalledScenarios",
            isDirectory: true
        )
        let catalogURL = outputRoot.appendingPathComponent(
            "Task10InstalledScenarios.fixture.json"
        )
        let manager = FileManager.default
        if manager.fileExists(atPath: scenarioRoot.path) {
            try manager.removeItem(at: scenarioRoot)
        }
        if manager.fileExists(atPath: catalogURL.path) {
            try manager.removeItem(at: catalogURL)
        }
        try manager.createDirectory(at: scenarioRoot, withIntermediateDirectories: true)

        var oracleRows: [ScenarioOracle] = []
        for scenario in Task10InstalledScenario.allCases {
            let seed = try Task10InstalledScenarioSeedPackage.make(scenario)
            defer { seed.remove() }
            let packageName = "\(scenario.rawValue).mscope"
            let packageURL = scenarioRoot.appendingPathComponent(packageName, isDirectory: true)

            // Reopen through the production reader, then save through WorkspaceStore. This makes
            // the generated package exercise the exact installed Save/terminate/reopen boundary.
            let store = try WorkspaceStore.restoredPackage(
                from: seed.packageURL,
                scheduleDurableRecovery: false
            )
            store.workspaceName = scenario.workspaceName
            XCTAssertTrue(
                store.writeDocumentPackage(
                    to: packageURL,
                    now: Date(timeIntervalSince1970: 1_725_000_000)
                ),
                store.saveError ?? "The production writer rejected \(scenario.rawValue)."
            )
            let reopened = try MacScopeDocumentPackage.openPackage(from: packageURL)
            XCTAssertEqual(reopened.manifest.workspaceName, scenario.workspaceName)
            XCTAssertEqual(reopened.reconstructionState.jobs.first?.jobID, seed.expectedJobID)
            XCTAssertEqual(
                reopened.reconstructionState.jobs.first?.state,
                scenario.expectedJobState
            )
            XCTAssertEqual(
                reopened.reconstructionState.jobs.first?.pauseContext?.cause,
                scenario.pauseCause
            )
            XCTAssertEqual(
                reopened.reconstructionState.jobs.first?.pauseContext?.resumeTarget,
                scenario.resumeTarget
            )

            let verificationURL = outputRoot.appendingPathComponent(
                ".Task10InstalledScenario-\(scenario.rawValue)-verification.mscope",
                isDirectory: true
            )
            if manager.fileExists(atPath: verificationURL.path) {
                try manager.removeItem(at: verificationURL)
            }
            XCTAssertTrue(
                store.writeDocumentPackage(
                    to: verificationURL,
                    now: Date(timeIntervalSince1970: 1_725_000_000)
                ),
                store.saveError ?? "The production writer rejected deterministic replay."
            )
            let packageDigest = try packageTreeSHA256(at: packageURL)
            XCTAssertEqual(
                try packageTreeSHA256(at: verificationURL),
                packageDigest,
                "fresh production writes must be byte-identical for \(scenario.rawValue)"
            )
            try manager.removeItem(at: verificationURL)

            oracleRows.append(
                ScenarioOracle(
                    expectedCheckpointFreshness: scenario.expectedCheckpointFreshness,
                    expectedCorpusOccurrenceCount: seed.expectedCorpusOccurrenceCount,
                    expectedCorpusRelationCount: seed.expectedCorpusRelationCount,
                    expectedCorpusUniqueContentCount: seed.expectedCorpusUniqueContentCount,
                    expectedCorpusUnresolvedRelationCount:
                        seed.expectedCorpusUnresolvedRelationCount,
                    expectedCurrentGapOperationID: scenario.expectedCurrentGapOperationID,
                    expectedEvidenceCount: seed.expectedEvidenceCount,
                    expectedEvidenceCurrentCount: seed.expectedEvidenceCurrentCount,
                    expectedEvidenceHistoricalCount: seed.expectedEvidenceHistoricalCount,
                    expectedEvidenceStaleCount: seed.expectedEvidenceStaleCount,
                    expectedEvidenceUnavailableCount: seed.expectedEvidenceUnavailableCount,
                    expectedEditorMode: "Disassembly",
                    expectedFocusedImageName: "Installed fixture",
                    expectedFunctionAddress: seed.expectedFunctionAddress,
                    expectedStartingImageName: seed.expectedStartingImageName,
                    expectedStartingFunctionAddress: seed.expectedStartingFunctionAddress,
                    expectedGapCount: seed.expectedGapCount,
                    expectedJobID: seed.expectedJobID,
                    expectedJobState: scenario.expectedJobState?.rawValue,
                    expectedNavigableEvidenceID: scenario.expectedNavigableEvidenceID,
                    expectedPauseCause: scenario.pauseCause?.rawValue,
                    expectedResumeTarget: scenario.resumeTarget?.rawValue,
                    expectedTaskCount: seed.expectedTaskCount,
                    forbiddenRawPathCanary: scenario.exposesPrivacyCanaries
                        ? Task10InstalledScenarioSeedPackage.rawPathPrivacyCanary
                        : nil,
                    forbiddenRawPromptCanary: scenario.exposesPrivacyCanaries
                        ? Task10InstalledScenarioSeedPackage.rawPromptPrivacyCanary
                        : nil,
                    forbiddenRawPseudocodeCanary: scenario.exposesPrivacyCanaries
                        ? Task10InstalledScenarioSeedPackage.rawPseudocodePrivacyCanary
                        : nil,
                    packageName: packageName,
                    packageTreeSHA256: packageDigest,
                    scenarioID: scenario.rawValue,
                    workspaceName: scenario.workspaceName
                )
            )
        }
        XCTAssertEqual(oracleRows.map(\.scenarioID), oracleRows.map(\.scenarioID).sorted())
        let catalog = ScenarioCatalog(
            generator: "WorkspaceStore.restoredPackage/writeDocumentPackage",
            provider: ProviderOracle(
                displayName: "Task 10 Deterministic Model",
                instanceID: "task10-installed-instance",
                modelKey: "task10-installed-model",
                publisher: "MacScope Tests"
            ),
            scenarios: oracleRows,
            // Version 3 requires the persisted distinct starting image used by the current
            // Reveal Source proof. Regenerate the checked-in resource through this opt-in test.
            schemaVersion: 3
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(catalog).write(to: catalogURL, options: .atomic)
    }

    private func packageTreeSHA256(at packageURL: URL) throws -> String {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try manager.subpathsOfDirectory(atPath: packageURL.path)
        .map { packageURL.appendingPathComponent($0) }
        .filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
        .sorted { $0.path < $1.path }

        var digest = SHA256()
        for url in files {
            let relativePath = url.path.replacingOccurrences(of: packageURL.path + "/", with: "")
            digest.update(data: Data(relativePath.utf8))
            digest.update(data: Data([0]))
            digest.update(data: try Data(contentsOf: url))
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct FixtureSidecar: Codable {
    let schemaVersion: Int
    let generator: String
    let workspaceName: String
    let packageTreeSHA256: String
}

// Opaque fixture corpus tasks must never need binary analysis or native decompilation. Keep the
// actual resolver/executor/planner path; reject only these unrelated external execution seams.
private struct Task10FixtureRejectingHeadlessExecutor: ReconstructionHeadlessAnalysisExecuting {
    func execute(
        _ request: ReconstructionHeadlessAnalysisRequest,
        cancellation: ReconstructionCancellation
    ) async throws -> ReconstructionHeadlessAnalysisResult {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func pause() async {}
    func resume() async {}
    func retire() async {}
}

private struct Task10FixtureRejectingNativeDecompiler: ReconstructionNativeTaskDecompiling {
    func decompile(
        _ request: ReconstructionNativeDecompilationRequest,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionNativeTaskResult {
        .failed(.providerUnavailable)
    }
    func cancelOutstanding() async {}
    func retire() async {}
}

// Exercise the actual coordinator/DB/materializer loop, stopping at the real model-preparation
// boundary instead of invoking a provider. The revision ceiling makes a recovery/activation loop
// terminate with a failed checkpoint, so a regression cannot hang the native test process.
private actor Task10FixtureCoordinatorBoundaryPlanner: ReconstructionJobRoundPlanning {
    let materializer: ReconstructionProductionJobRoundMaterializer
    private(set) var modelPreparationCount = 0
    private(set) var modelPreparationRevisions: [UInt64] = []
    private(set) var recoveryTransitions: [[ReconstructionTaskTransition]] = []
    private(set) var observedPhases: [ReconstructionJobState] = []
    let completesModelCycles: Bool
    let maximumCheckpointRevision: UInt64

    init(
        materializer: ReconstructionProductionJobRoundMaterializer,
        completesModelCycles: Bool = false,
        maximumCheckpointRevision: UInt64? = nil
    ) {
        self.materializer = materializer
        self.completesModelCycles = completesModelCycles
        self.maximumCheckpointRevision = maximumCheckpointRevision ?? (completesModelCycles ? 17 : 7)
    }

    func planRound(
        from snapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionJobCommitPlan {
        if observedPhases.last != snapshot.currentDurableJobState {
            observedPhases.append(snapshot.currentDurableJobState)
        }
        guard snapshot.checkpointRevision < maximumCheckpointRevision else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        switch try await materializer.prepare(snapshot: snapshot) {
        case .commit(let plan): return plan
        case .model(let prepared):
            modelPreparationCount += 1
            modelPreparationRevisions.append(snapshot.checkpointRevision)
            if completesModelCycles {
                return try await commitModelFixture(snapshot: snapshot, prepared: prepared)
            }
            await materializer.discardPreparedRound(snapshot: snapshot, prepared: prepared)
            throw CancellationError()
        }
    }

    func planRecovery(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        // Full-cycle restored cuts include the committed ordinary response and final activation;
        // apply the same finite ceiling as planRound, rather than the short boundary-only limit.
        guard snapshot.checkpointRevision < maximumCheckpointRevision else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        recoveryTransitions.append(transitions)
        return try await materializer.makeRecoveryPlan(snapshot: snapshot, transitions: transitions)
    }

    func planControl(
        from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        try await materializer.makeControlPlan(snapshot: snapshot, reason: reason)
    }

    func cancel(jobID: UUID) async {}

    // Only the external model response is canned. Request context/handles, terminal authority,
    // canonical receipts, successor DAG, materializer validation and database commit are real.
    func commitModelFixture(
        snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound,
        directCut: ReconstructionProductionCommittedRoundCut? = nil,
        directBuilder: ReconstructionProductionRoundPlanBuilder? = nil
    ) async throws -> ReconstructionJobCommitPlan {
        let lease = Phase2ReadyInferenceLease(
            providerRevision: 1,
            configuration: try Phase2AIProviderConfiguration(
                profileID: UUID(), generation: 1,
                endpointOrigin: "http://127.0.0.1:1234", model: "fixture-model",
                maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 60_000,
                inferencePolicy: .init()
            ),
            observedModelInventorySHA256: String(repeating: "c", count: 64)
        )
        let terminal = ReconstructionTerminalReceipt(
            requestID: UUID(), jobID: snapshot.jobID,
            checkpointRevision: snapshot.checkpointRevision,
            roundID: prepared.finalSynthesisRequest == nil ? prepared.roundID : nil,
            status: .completed
        )
        // The real materializer captures the committed objective and seals the
        // complete R2 envelope; the canned response must bind that same authority.
        let objective = try XCTUnwrap(prepared.objective)
        if let final = prepared.finalSynthesisRequest {
            XCTAssertEqual(snapshot.currentDurableJobState, .retrieving)
            let authority = try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: terminal.requestID,
                request: .finalSynthesisR2(ReconstructionFinalSynthesisRequestR2(
                    protocolVersion: 9, objective: objective, request: final
                )), terminalReceipt: terminal
            )
            return try await materializer.makeFinalCommitPlan(
                snapshot: snapshot, prepared: prepared, lease: lease, requestAuthority: authority,
                synthesis: ReconstructionFinalSynthesisExecutionResult(
                    candidate: .init(
                        kind: .insufficientEvidence,
                        text: "No model-authored conclusion is justified by this fixture.",
                        evidenceIDs: []
                    ),
                    usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
                    terminalReceipt: terminal
                )
            )
        }
        if directCut == nil { XCTAssertEqual(snapshot.currentDurableJobState, .executingReads) }
        let context = try ReconstructionContextCompiler().compile(
            cut: prepared.evidenceCut, query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories
        )
        let handles = try ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority, requests: prepared.requests
        )
        let request = ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: snapshot.jobID, checkpointRevision: snapshot.checkpointRevision,
            roundID: prepared.roundID,
            corpusManifestSHA256: prepared.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: prepared.authority.evidenceFrontierSHA256,
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
                .toolRegistry.identity.sha256,
            context: context,
            handles: handles.map { .init(handleID: $0.handleID, operationID: $0.operationID) }
        )
        let authority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: terminal.requestID,
            request: .roundR2(ReconstructionInferenceRoundRequestR2(
                protocolVersion: 9, objective: objective, request: request
            )), terminalReceipt: terminal
        )
        let inference = ReconstructionInferenceExecutionResult(
                candidate: .init(
                    jobID: snapshot.jobID, checkpointRevision: snapshot.checkpointRevision,
                    roundID: prepared.roundID, selectedHandleIDs: [],
                    disposition: directCut == nil && modelPreparationCount == 1
                        ? .continue : .sufficientEvidence,
                    unresolvedGaps: []
                ),
                usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
                terminalReceipt: terminal
            )
        if let directCut, let directBuilder {
            return try await directBuilder.makeCommitPlan(
                cut: directCut, lease: lease, requestAuthority: authority,
                inference: inference, executions: []
            )
        }
        return try await materializer.makeCommitPlan(
            snapshot: snapshot, prepared: prepared, lease: lease, requestAuthority: authority,
            inference: inference,
            executions: []
        )
    }
}

private struct Task10FixtureCoordinatorPublisher: ReconstructionJobStatusPublishing {
    func publish(_ receipt: ReconstructionJobCommitReceipt) async {}
}
