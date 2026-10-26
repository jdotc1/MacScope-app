import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceIntentSelectionTests: XCTestCase {
    func testAuthorizedSourceAfterCompletedFinalAndOracleDispatchesWithoutPhaseCommit() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let original = fixture.basis
        let classify = try ProductionSourceOwnerFixture.task(603, jobID: original.job.jobID, kind: .classify,
            subject: .artifact(fixture.function.artifact), dependencies: [ProductionSourceOwnerFixture.id(10)])
        let discover = try ProductionSourceOwnerFixture.task(604, jobID: original.job.jobID, kind: .discoverRelations,
            subject: .artifact(fixture.function.artifact), dependencies: [classify.identity.taskID])
        let retrieve = try ProductionSourceOwnerFixture.task(11, jobID: original.job.jobID, kind: .retrieveEvidence,
            dependencies: [discover.identity.taskID], contract: ReconstructionProductionTaskContract.evidenceQuery)
        let oracle = try ProductionSourceOwnerFixture.task(14, jobID: original.job.jobID, kind: .executeSource,
            subject: .function(fixture.function), dependencies: [ProductionSourceOwnerFixture.id(601)],
            contract: ReconstructionSourceExecutionTaskContract.oracle)
        let oracleCheckpoint = try ProductionSourceOwnerFixture.task(605, jobID: original.job.jobID, kind: .checkpoint,
            dependencies: [oracle.identity.taskID])
        let final = try ProductionSourceOwnerFixture.task(600, jobID: original.job.jobID, kind: .modelRound,
            dependencies: [ProductionSourceOwnerFixture.id(13)], contract: ReconstructionProductionTaskContract.finalSynthesis)
        let finalCheckpoint = try ProductionSourceOwnerFixture.task(601, jobID: original.job.jobID, kind: .checkpoint,
            dependencies: [final.identity.taskID])
        let source = try ProductionSourceOwnerFixture.task(15, jobID: original.job.jobID, kind: .modelRound,
            subject: .function(fixture.function), dependencies: [oracleCheckpoint.identity.taskID], state: .running,
            contract: ReconstructionProductionTaskContract.sourceRevision)
        let replacements = [source, retrieve, oracle]
        let tasks = original.tasks.map { task in
            replacements.first { $0.identity.taskID == task.identity.taskID } ?? task
        } + [classify, discover, oracleCheckpoint, final, finalCheckpoint]
        try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(tasks,
            jobID: original.job.jobID, maximumTasks: original.job.budget.maxTasks)
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: ProductionSourceOwnerFixture.id(602),
            jobID: original.job.jobID, taskID: final.identity.taskID, checkpointRevision: original.checkpoint.revision,
            requestIdentitySHA256: ProductionSourceOwnerFixture.hash("completed final request"),
            producer: ProductionSourceOwnerFixture.producer(ReconstructionProductionTaskContract.finalSynthesis),
            terminalState: .completed, selectedHandleIDs: [], acceptedEvidenceIDs: [], diagnostic: nil)
        let receipts = original.modelReceipts + [receipt]
        for state in [ReconstructionJobState.awaitingModel, .executingReads] {
            let checkpoint = try ProductionSourceOwnerFixture.checkpoint(id: original.checkpoint.checkpointID,
                revision: original.checkpoint.revision, parent: original.checkpointHistory.last,
                manifest: original.manifest, frontier: original.evidenceCut.frontierSHA256, tasks: tasks,
                modelReceipts: receipts, toolReceipts: original.toolReceipts, jobID: original.job.jobID, coordinatorState: state)
            let job = try ProductionSourceOwnerFixture.alter(original.job) { $0["state"] = state.rawValue }
            var terminals = original.snapshot.terminalReceiptStatesByTaskID
            terminals[final.identity.taskID] = .completed
            terminals[oracle.identity.taskID] = .completed
            let snapshot = ReconstructionJobOrchestrationSnapshot(jobID: job.jobID, jobCreationOrder: 1,
                checkpointID: checkpoint.checkpointID, checkpointRevision: checkpoint.revision,
                checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
                checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
                currentCorpusManifestSHA256: original.manifest.canonicalSHA256,
                evidenceFrontierSHA256: original.evidenceCut.frontierSHA256, currentDurableJobState: state,
                pauseContext: nil, maximumRoundsWithoutEvidence: job.budget.maxRounds, tasks: tasks,
                terminalReceiptStatesByTaskID: terminals,
                consecutiveModelRoundsWithoutEvidence: original.snapshot.consecutiveModelRoundsWithoutEvidence)
            let basis = try ReconstructionProductionRoundBasis(workspaceID: original.workspaceID,
                project: original.project, manifest: original.manifest, job: job, checkpoint: checkpoint,
                tasks: tasks, toolReceipts: original.toolReceipts, modelReceipts: receipts,
                taskCompletionAuthorities: original.taskCompletionAuthorities, attachmentSources: original.attachmentSources,
                evidenceCut: original.evidenceCut, freshnessAuthority: original.freshnessAuthority, snapshot: snapshot,
                checkpointHistory: original.checkpointHistory)
            let prepared = try await ReconstructionProductionPreparedRoundBuilder(evidenceQueryProducer:
                ProductionSourceOwnerFixture.producer(ReconstructionOperationID.evidenceQuery.rawValue)).makePreparedRound(from: basis)
            let expectedRequest = try XCTUnwrap(prepared.sourceRevisionRequest)
            let registry = ReconstructionProductionRoundBasisRegistry(basis: basis, prepared: prepared)
            let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
                macScopeBuildIdentity: ProductionSourceOwnerFixture.hash("build"), macScopeSourceIdentity: ProductionSourceOwnerFixture.hash("source"),
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest, toolchainIdentity: "fixture"))
            let planner = ReconstructionProductionRoundPlanBuilder(basisRegistry: registry, receiptAuthor: author)
            let cut = ReconstructionProductionCommittedRoundCut(snapshot: snapshot, parentCheckpointID: checkpoint.checkpointID,
                parentCheckpointSHA256: checkpoint.canonicalSHA256, prepared: prepared, batchTerminalResults: [])
            let materializer = ReconstructionProductionJobRoundMaterializer(
                cutProvider: IntentSelectionSourceCutProvider(cut: cut), planBuilder: planner)
            // The predecessor's completed receipt cannot stand in for this unexecuted source request.
            guard case .model(let dispatched) = try await materializer.prepare(snapshot: snapshot) else {
                return XCTFail("Authorized source in \(state) must dispatch inference instead of committing another phase")
            }
            XCTAssertEqual(dispatched.sourceRevisionRequest, expectedRequest)
            XCTAssertEqual(dispatched.sourceRevisionRequest?.taskID, source.identity.taskID)
            XCTAssertNil(dispatched.finalSynthesisRequest)
            await materializer.discardPreparedRound(snapshot: snapshot, prepared: dispatched)
        }
    }

    func testRegistryRetainsExplicitIntentEvenWhenTargetIsUnavailable() async throws {
        let fixture = try ProductionSourceOwnerFixture.make(sourceState: .pending)
        let original = try ReconstructionProductionPreparedRoundBuilder.makeDirectCommitDescriptor(from: fixture.basis)
        let requested = copy(original, requested: true, target: nil)
        let registry = ReconstructionProductionRoundBasisRegistry()
        try await registry.register(fixture.basis, prepared: requested)
        let cleared = await registry.remove(roundID: requested.roundID, matching: fixture.basis.snapshot,
            prepared: copy(requested, requested: false, target: nil))
        XCTAssertNil(cleared)
        let substituted = await registry.remove(roundID: requested.roundID, matching: fixture.basis.snapshot,
            prepared: copy(requested, requested: true, target: fixture.function))
        XCTAssertNil(substituted)
        let retained = try await registry.basis(roundID: requested.roundID, objective: requested.objective)
        XCTAssertEqual(retained.checkpoint, fixture.basis.checkpoint)
        let removed = await registry.remove(roundID: requested.roundID, matching: fixture.basis.snapshot, prepared: requested)
        XCTAssertNotNil(removed)
    }

    func testOrdinaryPreparedDescriptorDefaultsToNoSourceIntent() throws {
        let fixture = try ProductionSourceOwnerFixture.make(sourceState: .pending)
        let prepared = try ReconstructionProductionPreparedRoundBuilder.makeDirectCommitDescriptor(from: fixture.basis)
        XCTAssertFalse(prepared.sourceOracleRequested)
        XCTAssertNil(prepared.sourceOracleFunction)
    }

    func testUnrelatedProjectionCannotSupplyOriginalTargetName() async throws {
        let fixture = try ProductionSourceOwnerFixture.make()
        let b = fixture.basis
        let decompile = try ProductionSourceOwnerFixture.task(500, jobID: b.job.jobID, kind: .decompileMacScope,
            subject: .function(fixture.function), state: .completed)
        let stableID = try XCTUnwrap(ReconstructionReboundFunctionAuthority.expectedFunctionID(for: fixture.function))
        func payload(_ name: String) throws -> Data {
            let function = FunctionSummary(id: stableID, name: name, startAddress: fixture.function.startAddress,
                endAddress: fixture.function.endAddressExclusive, confidence: 1)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(function))
            return try JSONSerialization.data(withJSONObject: ["projection": ["function": object]], options: [.sortedKeys])
        }
        let legitimateBytes = try payload("other_function")
        let legitimate = try ReconstructionEvidenceRecord(evidenceID: ProductionSourceOwnerFixture.id(501),
            subject: .function(fixture.function), operationID: ReconstructionOperationID.decompilerMacScope.rawValue,
            payloadKind: .structuredJSON, payload: legitimateBytes, payloadByteCount: UInt64(legitimateBytes.count),
            payloadSHA256: ProductionSourceOwnerFixture.sha(legitimateBytes), facetDependencies: [],
            producer: ProductionSourceOwnerFixture.producer(ReconstructionOperationID.decompilerMacScope.rawValue),
            citations: [], creatingJobID: b.job.jobID, creatingTaskID: decompile.identity.taskID,
            creatingCheckpointID: b.checkpoint.checkpointID, modelReceiptID: nil,
            toolReceiptID: ProductionSourceOwnerFixture.id(502), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let spoofBytes = try payload("reconstructed")
        let spoof = try ProductionSourceOwnerFixture.alter(legitimate) {
            $0["evidenceID"] = ProductionSourceOwnerFixture.id(503).uuidString
            $0["operationID"] = ReconstructionSourceRevisionEvidence.operationID
            $0["payload"] = spoofBytes.base64EncodedString()
            $0["payloadByteCount"] = spoofBytes.count
            $0["payloadSHA256"] = ProductionSourceOwnerFixture.sha(spoofBytes)
        }
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: ProductionSourceOwnerFixture.id(1))
        let basis = try ProductionSourceOwnerFixture.rebuild(foundation: foundation,
            tasks: b.tasks + [decompile], records: b.evidenceCut.records + [legitimate, spoof],
            modelReceipts: b.modelReceipts, toolReceipts: b.toolReceipts, history: b.checkpointHistory,
            function: fixture.function, revision: b.checkpoint.revision,
            checkpointID: b.checkpoint.checkpointID, parent: b.checkpointHistory.last)
        XCTAssertEqual(ReconstructionSourceOriginalSessionRegistry.committedFunctions(in: basis), [fixture.function])
        let transport = IntentSelectionNoExecutionTransport()
        let workflow = ReconstructionSourceExecutionWorkflow(transport: transport, toolAuthority: .init(
            compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            sdkRootPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
            runnerSHA256: ProductionSourceOwnerFixture.hash("runner"),
            compilerSHA256: ProductionSourceOwnerFixture.hash("compiler"),
            sdkSettingsSHA256: ProductionSourceOwnerFixture.hash("SDK")))
        let session = ReconstructionSourceOriginalSession(workflow: workflow,
            stageParent: TestWorkRoot.authority)
        let registry = ReconstructionSourceOriginalSessionRegistry()
        try await registry.register(workspaceID: basis.workspaceID, jobID: basis.job.jobID, session: session)
        let target = try await registry.targetFunction(in: basis)
        XCTAssertNil(target)
        let count = await transport.calls
        XCTAssertEqual(count, 0)
        await registry.remove(workspaceID: basis.workspaceID, jobID: basis.job.jobID)
    }

    func testMissingTargetSufficientEvidenceProducesDurablePauseInsteadOfFinalSynthesis() async throws {
        let basis = try ordinaryBasis()
        let evidenceCut = basis.evidenceCut
        let manifest = basis.manifest
        let frontier = evidenceCut.frontierSHA256
        let checkpoint = basis.checkpoint
        let jobID = basis.job.jobID
        let snapshot = basis.snapshot
        let builder = try ReconstructionProductionPreparedRoundBuilder(evidenceQueryProducer:
            ProductionSourceOwnerFixture.producer(ReconstructionOperationID.evidenceQuery.rawValue))
        let original = try await builder.makePreparedRound(from: basis)
        let prepared = copy(original, requested: true, target: nil)
        let context = try ReconstructionContextCompiler().compile(cut: evidenceCut, query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects, allowedGapCategories: prepared.allowedGapCategories)
        let handles = try ReconstructionToolRegistry().mintHandles(authority: prepared.authority, requests: prepared.requests)
        let round = ReconstructionInferenceRoundRequest(protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: jobID, checkpointRevision: 0, roundID: prepared.roundID, corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
            context: context, handles: handles.map { .init(handleID: $0.handleID, operationID: $0.operationID) })
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: jobID, checkpointRevision: 0,
            roundID: prepared.roundID, status: .completed)
        let requestAuthority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: terminal.requestID,
            request: .roundR2(.init(protocolVersion: 9, objective: XCTUnwrap(prepared.objective), request: round)), terminalReceipt: terminal)
        let inference = ReconstructionInferenceExecutionResult(candidate: .init(jobID: jobID,
            checkpointRevision: 0, roundID: prepared.roundID, selectedHandleIDs: [], disposition: .sufficientEvidence, unresolvedGaps: []),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal)
        let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
            macScopeBuildIdentity: ProductionSourceOwnerFixture.hash("build"), macScopeSourceIdentity: ProductionSourceOwnerFixture.hash("source"),
            operationIdentity: ReconstructionProductionTaskContract.modelRound,
            registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest, toolchainIdentity: "17A123"))
        let planner = ReconstructionProductionRoundPlanBuilder(basisRegistry: .init(basis: basis, prepared: prepared), receiptAuthor: author)
        let lease = Phase2ReadyInferenceLease(providerRevision: 1, configuration: try .init(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:1234", model: "fixture", maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000),
            observedModelInventorySHA256: ProductionSourceOwnerFixture.hash("inventory"))
        let plan = try await planner.makeCommitPlan(cut: .init(snapshot: snapshot,
            parentCheckpointID: checkpoint.checkpointID, parentCheckpointSHA256: checkpoint.canonicalSHA256,
            prepared: prepared, batchTerminalResults: []), lease: lease, requestAuthority: requestAuthority,
            inference: inference, executions: [])
        XCTAssertEqual(plan.disposition, .paused(.evidenceStalled))
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(mutation.successorCheckpoint.coordinatorState, .paused)
        XCTAssertEqual(mutation.modelReceipts.count, 1)
        XCTAssertTrue(mutation.finalResults.isEmpty)
        XCTAssertEqual(mutation.newTasks.count, 3)
        XCTAssertFalse(mutation.newTasks.contains { $0.identity.operationContractIdentity == ReconstructionProductionTaskContract.finalSynthesis })
    }

    func testFixedProfilePaginationMatchesPreparedQueryAndCanonicalHandleWithoutObjectiveInference() async throws {
        let objective = "Reconstruct the original function as bounded C source"
        let builder = try ReconstructionProductionPreparedRoundBuilder(evidenceQueryProducer:
            ProductionSourceOwnerFixture.producer(ReconstructionOperationID.evidenceQuery.rawValue))
        for profile in [nil, ReconstructionSourceExecutionTaskContract.profileID] as [String?] {
            let basis = try ordinaryBasis(sourceProfileID: profile, objective: objective)
            XCTAssertEqual(basis.job.recordSchemaVersion, 5)
            XCTAssertEqual(basis.job.sourceProfileID, profile)
            let prepared = try await builder.makePreparedRound(from: basis)
            XCTAssertEqual(prepared.sourceOracleRequested, profile != nil)
            XCTAssertNil(prepared.sourceOracleFunction)
            let expectedRecords = profile == nil ? 128 : 8
            let expectedBytes = profile == nil ? 1_048_576 : 8_192
            XCTAssertEqual(prepared.retrievalQuery.maximumRecords, expectedRecords)
            if profile == nil {
                // The ordinary envelope reserves Base64 and authority-array overhead.
                XCTAssertGreaterThan(prepared.retrievalQuery.maximumEncodedBytes, 8_192)
                XCTAssertLessThanOrEqual(prepared.retrievalQuery.maximumEncodedBytes, expectedBytes)
            } else {
                XCTAssertEqual(prepared.retrievalQuery.maximumEncodedBytes, expectedBytes)
            }
            // Preparation bounds this exact query before minting the app-owned tool request.
            let request = try XCTUnwrap(prepared.requests.first { $0.operationID == .evidenceQuery })
            XCTAssertEqual(request.retrievalQuery, prepared.retrievalQuery)
            XCTAssertEqual(request.maximumRecords, expectedRecords)
            XCTAssertEqual(request.maximumEncodedBytes, prepared.retrievalQuery.maximumEncodedBytes)
            let registry = ReconstructionToolRegistry()
            let handles = try registry.mintHandles(authority: prepared.authority, requests: prepared.requests)
            let handle = try XCTUnwrap(handles.first { $0.operationID == .evidenceQuery })
            let envelope = try registry.decodeCanonicalRequest(handle)
            XCTAssertEqual(envelope.request, request)
            XCTAssertEqual(envelope.retrievalQuery, prepared.retrievalQuery)
            XCTAssertEqual(envelope.maximumRecords, expectedRecords)
            XCTAssertEqual(envelope.maximumEncodedBytes, prepared.retrievalQuery.maximumEncodedBytes)
            // Selecting the fixed profile changes page bounds, not the durable job budget.
            XCTAssertEqual(basis.job.budget.maxEvidenceRecords, 128)
            XCTAssertEqual(basis.job.budget.maxEncodedBytes, 1_048_576)
        }
    }

    private func ordinaryBasis(sourceProfileID: String? = nil,
                               objective: String = "Reconstruct selected artifact") throws -> ReconstructionProductionRoundBasis {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: UUID())
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity)
        let jobID = foundation.job.jobID
        let ids = (10...15).map(SourcePhaseTestFixture.id)
        let kinds: [ReconstructionTaskKind] = [.ingest, .classify, .discoverRelations, .retrieveEvidence, .modelRound, .checkpoint]
        let tasks = try kinds.enumerated().map { index, kind -> ReconstructionTaskRecord in
            let state: ReconstructionTaskState = index < 3 ? .completed : (index < 5 ? .running : .pending)
            return .init(identity: try .make(taskID: ids[index], jobID: jobID, kind: kind,
                subject: index < 3 ? .artifact(artifact) : nil,
                dependencyTaskIDs: index == 0 ? [] : [ids[index - 1]],
                operationContractIdentity: kind == .retrieveEvidence ? ReconstructionProductionTaskContract.evidenceQuery
                    : "reconstruction.\(kind.rawValue).v1"), state: state, diagnostic: nil)
        }
        let manifest = foundation.manifest
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(corpusManifestSHA256: manifest.canonicalSHA256,
            records: [], projectedClassificationsByEvidenceID: [:], relations: [], gaps: [], checkpointRevisionsByID: [:])
        let evidenceCut = try ReconstructionEvidenceCut(corpusManifestSHA256: manifest.canonicalSHA256,
            records: [], relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: [:], checkpointRevisionsByID: [:])
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: UUID(), jobID: jobID, revision: 0,
            parentCheckpointID: nil, parentCheckpointSHA256: nil, corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, pendingTaskIDs: [ids[5]], runningTaskIDs: [ids[3], ids[4]],
            completedTaskIDs: Array(ids.prefix(3)), failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: ReconstructionEvidenceGapFrontier.canonicalSHA256(for: []),
            modelReceiptIDs: [], toolReceiptIDs: [], coordinatorState: .executingReads, terminalReason: nil)
        let job = try ReconstructionJobRecord(jobID: jobID, reconstructionProjectID: foundation.project.projectID,
            objective: objective, objectiveSHA256: ProductionSourceOwnerFixture.hash(objective),
            creationCorpusManifestSHA256: manifest.canonicalSHA256, state: .executingReads,
            currentCheckpointID: checkpoint.checkpointID, terminalReason: nil,
            budget: .init(maxRounds: 8, maxTasks: 32, maxEvidenceRecords: 128, maxEncodedBytes: 1_048_576), creationOrdinal: 1, sourceProfileID: sourceProfileID)
        let snapshot = ReconstructionJobOrchestrationSnapshot(jobID: jobID, jobCreationOrder: 1,
            checkpointID: checkpoint.checkpointID, checkpointRevision: 0, checkpointCorpusManifestSHA256: manifest.canonicalSHA256,
            checkpointEvidenceFrontierSHA256: frontier, currentCorpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, currentDurableJobState: .executingReads, pauseContext: nil,
            maximumRoundsWithoutEvidence: 8, tasks: tasks, terminalReceiptStatesByTaskID: [:])
        return try ReconstructionProductionRoundBasis(workspaceID: UUID(), project: foundation.project,
            manifest: manifest, job: job, checkpoint: checkpoint, tasks: tasks, toolReceipts: [], modelReceipts: [],
            attachmentSources: manifest.artifacts.map { .init(contentIdentity: $0.contentIdentity,
                verifiedURL: TestWorkRoot.authorityURL("intent-fixture-\($0.contentIdentity.digest)")) },
            // This cut has artifact ingestion only: no committed image analysis or facet evidence.
            evidenceCut: evidenceCut, freshnessAuthority: ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
                manifest: manifest, authoritativeSubjects: tasks.compactMap(\.identity.subject),
                includesCurrentAnalysis: false), snapshot: snapshot)
    }

    private func copy(_ prepared: ReconstructionPreparedModelRound, requested: Bool,
                      target: ReconstructionFunctionCoordinate?) -> ReconstructionPreparedModelRound {
        .init(roundID: prepared.roundID, evidenceCut: prepared.evidenceCut, retrievalQuery: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects, allowedGapCategories: prepared.allowedGapCategories,
            authority: prepared.authority, requests: prepared.requests, projectorInput: prepared.projectorInput,
            sourceRevisionRequest: prepared.sourceRevisionRequest, sourceOracleFunction: target,
            sourceOracleRequested: requested, finalSynthesisRequest: prepared.finalSynthesisRequest, objective: prepared.objective)
    }
}

private actor IntentSelectionNoExecutionTransport: ShellBrokerXPCTransport {
    private(set) var calls = 0
    func executeSource(_ request: MacScope.Phase2SourceExecutionRequest) async throws -> MacScope.Phase2SourceExecutionResponse {
        calls += 1
        throw ShellBrokerXPCTransportError.unavailable("Selection must not execute")
    }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        calls += 1
        throw ShellBrokerXPCTransportError.unavailable("Generic execution forbidden")
    }
    func prepareBrokerProcessReceipt() async throws -> ShellBrokerXPCProcessReceipt {
        throw ShellBrokerXPCTransportError.unavailable("Unused")
    }
    func revalidateBrokerProcessReceipt(_ receipt: ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async {}
}

private struct IntentSelectionSourceCutProvider: ReconstructionProductionCommittedRoundCutProviding {
    let cut: ReconstructionProductionCommittedRoundCut
    func capture(snapshot: ReconstructionJobOrchestrationSnapshot) async throws -> ReconstructionProductionCommittedRoundCut {
        guard snapshot == cut.snapshot else { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
        return cut
    }
}
