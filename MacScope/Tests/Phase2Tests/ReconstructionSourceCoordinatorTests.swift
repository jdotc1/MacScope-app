import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ReconstructionSourceCoordinatorTests: XCTestCase {
    func testSourceUsesDedicatedReadyAndCommitBranchesWithoutTools() async throws {
        let fixture = try SourceCoordinatorFixture()
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let ready = SourceCoordinatorReady(result: fixture.finished)
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        _ = try await planner.planRound(from: fixture.snapshot)
        XCTAssertEqual(ready.sourceRequests, [fixture.request])
        XCTAssertEqual(ready.regularCalls, 0)
        XCTAssertEqual(ready.finalCalls, 0)
        let sources = await materializer.sources
        XCTAssertEqual(sources, [fixture.source])
        let failures = await materializer.failures
        XCTAssertTrue(failures.isEmpty)
    }

    func testPendingSourceTaskFailsBeforeInferenceAndDiscardsCut() async throws {
        let fixture = try SourceCoordinatorFixture(taskState: .pending)
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let ready = SourceCoordinatorReady(result: fixture.finished)
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        await assertFailure(.malformedOutput) { try await planner.planRound(from: fixture.snapshot) }
        XCTAssertTrue(ready.sourceRequests.isEmpty)
        let discards = await materializer.discards
        XCTAssertEqual(discards, 1)
    }

    func testSourceDirectAdmissionRejectsMismatchedRoundAuthority() throws {
        let fixture = try SourceCoordinatorFixture()
        let wrongAuthority = try ReconstructionToolAuthorityCut(
            jobID: fixture.snapshot.jobID, checkpointRevision: fixture.snapshot.checkpointRevision,
            roundID: UUID(), corpusManifestSHA256: fixture.snapshot.currentCorpusManifestSHA256,
            evidenceFrontierSHA256: fixture.snapshot.evidenceFrontierSHA256,
            projectionFrontierSHA256: fixture.prepared.authority.projectionFrontierSHA256)
        let prepared = ReconstructionPreparedModelRound(roundID: fixture.prepared.roundID,
            evidenceCut: fixture.prepared.evidenceCut, retrievalQuery: fixture.prepared.retrievalQuery,
            allowedGapSubjects: [], allowedGapCategories: [], authority: wrongAuthority,
            requests: [], projectorInput: fixture.prepared.projectorInput,
            sourceRevisionRequest: fixture.request, objective: fixture.prepared.objective)
        XCTAssertThrowsError(try ReconstructionProductionJobRoundPlanner.validateSourceRequest(
            fixture.request, prepared: prepared, snapshot: fixture.snapshot)) { error in
                XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .malformedOutput)
        }
    }

    func testChangedContextFailsBeforeInference() async throws {
        let fixture = try SourceCoordinatorFixture(contextText: "invented replacement evidence")
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let ready = SourceCoordinatorReady(result: fixture.finished)
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        await assertFailure(.malformedOutput) { try await planner.planRound(from: fixture.snapshot) }
        XCTAssertTrue(ready.sourceRequests.isEmpty)
    }

    func testOrdinaryContextCannotFallBackIntoSourceInference() async throws {
        let fixture = try SourceCoordinatorFixture(useOrdinaryContext: true)
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let ready = SourceCoordinatorReady(result: fixture.finished)
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        await assertFailure(.malformedOutput) { try await planner.planRound(from: fixture.snapshot) }
        XCTAssertTrue(ready.sourceRequests.isEmpty)
        XCTAssertEqual(ready.regularCalls, 0)
    }

    func testTerminalFailureCommitsFailureButPreAdmissionBusyDoesNot() async throws {
        let fixture = try SourceCoordinatorFixture()
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let terminal = ReconstructionTerminalReceipt(requestID: fixture.source.terminalReceipt.requestID,
            jobID: fixture.request.jobID, checkpointRevision: fixture.request.checkpointRevision,
            roundID: fixture.request.roundID, status: .failed)
        let authority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: terminal.requestID, request: .sourceRevision(fixture.request),
            terminalReceipt: terminal)
        let ready = SourceCoordinatorReady(result: .failedWithTerminalAuthority(lease: fixture.lease,
            requestAuthority: authority, failure: .runner(.invalidSourceCandidate)))
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        _ = try await planner.planRound(from: fixture.snapshot)
        let failures = await materializer.failures
        XCTAssertEqual(failures, [.malformedOutput])
        ready.result = .busy
        await assertFailure(.inferenceBusy) { try await planner.planRound(from: fixture.snapshot) }
        let afterBusy = await materializer.failures
        XCTAssertEqual(afterBusy, failures)
    }

    func testSourceAndFinalCannotBothBePrepared() async throws {
        let fixture = try SourceCoordinatorFixture(includeFinal: true)
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let ready = SourceCoordinatorReady(result: fixture.finished)
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        await assertFailure(.malformedOutput) { try await planner.planRound(from: fixture.snapshot) }
        XCTAssertTrue(ready.sourceRequests.isEmpty)
        XCTAssertEqual(ready.finalCalls, 0)
    }

    func testSourceCancellationDiscardsPreparedRoundWithoutReceipt() async throws {
        let fixture = try SourceCoordinatorFixture()
        let materializer = SourceCoordinatorMaterializer(prepared: fixture.prepared)
        let ready = SourceCoordinatorReady(result: fixture.finished)
        ready.suspendSource = true
        let entered = expectation(description: "source inference entered")
        ready.entered = entered
        let planner = ReconstructionProductionJobRoundPlanner(materializer: materializer,
            inference: ready, projectors: [])
        let running = Task { try await planner.planRound(from: fixture.snapshot) }
        await fulfillment(of: [entered], timeout: 1.0)
        await planner.cancel(jobID: fixture.snapshot.jobID)
        do { _ = try await running.value; XCTFail("Expected source cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Expected CancellationError, got \(error)") }
        let sources = await materializer.sources
        let failures = await materializer.failures
        let discards = await materializer.discards
        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(discards, 1)
    }

    func testMaterializerConsumesSourceCutOnceAndRejectsRequestSwap() async throws {
        let fixture = try SourceCoordinatorFixture()
        let builder = SourceCoordinatorPlanBuilder()
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: SourceCoordinatorCutProvider(cut: fixture.cut), planBuilder: builder)
        _ = try await materializer.prepare(snapshot: fixture.snapshot)
        await assertFailure(.invalidCommitPlan) {
            try await materializer.makeSourceCommitPlan(snapshot: fixture.snapshot,
                prepared: fixture.prepared, lease: fixture.lease,
                requestAuthority: fixture.authority, source: fixture.source)
        }
        await assertFailure(.malformedOutput) {
            try await materializer.makeSourceCommitPlan(snapshot: fixture.snapshot,
                prepared: fixture.prepared, lease: fixture.lease,
                requestAuthority: fixture.authority, source: fixture.source)
        }
        let sourceCalls = await builder.sourceCalls
        XCTAssertEqual(sourceCalls, 1)
        _ = try await materializer.prepare(snapshot: fixture.snapshot)
        let swapped = fixture.preparedReplacingSource(nil)
        await assertFailure(.malformedOutput) {
            try await materializer.makeSourceCommitPlan(snapshot: fixture.snapshot,
                prepared: swapped, lease: fixture.lease,
                requestAuthority: fixture.authority, source: fixture.source)
        }
        let afterSwap = await builder.sourceCalls
        XCTAssertEqual(afterSwap, 1)
    }

    private func assertFailure(_ expected: ReconstructionJobCoordinatorFailure,
        operation: () async throws -> ReconstructionJobCommitPlan) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, expected) }
    }
}

private struct SourceCoordinatorFixture {
    let snapshot: ReconstructionJobOrchestrationSnapshot
    let prepared: ReconstructionPreparedModelRound
    let request: ReconstructionSourceRevisionRequest
    let lease: Phase2ReadyInferenceLease
    let source: ReconstructionSourceRevisionExecutionResult
    let authority: ReconstructionModelTerminalRequestAuthority
    var finished: ReconstructionReadySourceRevisionExecutionResult {
        .finished(lease: lease, requestAuthority: authority, outcome: source)
    }
    var cut: ReconstructionProductionCommittedRoundCut {
        .init(snapshot: snapshot, parentCheckpointID: snapshot.checkpointID,
            parentCheckpointSHA256: sourceCoordinatorSHA("checkpoint"), prepared: prepared,
            batchTerminalResults: [])
    }

    init(taskState: ReconstructionTaskState = .running, contextText: String? = nil,
        includeFinal: Bool = false, useOrdinaryContext: Bool = false, ordinaryPayload: Data? = nil) throws {
        let jobID = UUID(), taskID = UUID(), roundID = UUID(), checkpointID = UUID()
        let function = try ReconstructionFunctionCoordinate(
            artifact: .init(occurrenceID: .init(rawValue: UUID()),
                contentIdentity: .init(algorithm: .sha256, digest: sourceCoordinatorSHA("binary"), byteCount: 32)),
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil,
                architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sourceCoordinatorSHA("analysis"),
            startAddress: 0x1000, endAddressExclusive: 0x1010, boundarySchemaVersion: 1,
            functionUUIDHint: nil, symbolHint: nil)
        let task = ReconstructionTaskRecord(identity: try .make(taskID: taskID, jobID: jobID,
            kind: .modelRound, subject: .function(function), dependencyTaskIDs: [],
            operationContractIdentity: ReconstructionSourceRevisionEvidence.taskContract),
            state: taskState, diagnostic: nil)
        let draft = try ReconstructionCorpusManifest(reconstructionProjectID: UUID(),
            artifacts: [], relations: [], canonicalSHA256: sourceCoordinatorSHA("draft"))
        let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: draft.reconstructionProjectID,
            artifacts: [], relations: [], canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft))
        let payload = ordinaryPayload ?? Data("Original observed input/output authority".utf8)
        let ordinaryOperation = ordinaryPayload == nil ? MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary : .decompilerMacScope
        let evidence = try ReconstructionEvidenceRecord(evidenceID: UUID(), subject: .function(function),
            operationID: ordinaryOperation.rawValue, payloadKind: ordinaryPayload == nil ? .text : .structuredJSON,
            payload: payload, payloadByteCount: UInt64(payload.count), payloadSHA256: sourceCoordinatorSHA(payload),
            facetDependencies: [], producer: .init(macScopeBuildIdentity: "fixture", macScopeSourceIdentity: "fixture",
                operationIdentity: ordinaryOperation.rawValue,
                registryIdentity: "fixture", protocolIdentity: "fixture", canonicalSHA256: sourceCoordinatorSHA("producer")),
            citations: ordinaryPayload == nil ? [] : [try .init(citationID: UUID(), sourceEvidenceID: nil,
                subject: .function(function), locator: "function:0x1000")], creatingJobID: jobID, creatingTaskID: UUID(), creatingCheckpointID: checkpointID,
            modelReceiptID: nil, toolReceiptID: UUID(), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let observed = harness.inputs.map { "\($0):\($0 == UInt32.max ? $0 : $0 + 1)\n" }.joined()
        let oracle = try ReconstructionSourceOracleEvidence.admit(authority: .init(
            projectID: manifest.reconstructionProjectID, jobID: jobID, function: function,
            execution: .init(originalImageSHA256: function.artifact.contentIdentity.digest,
                originalExecutableSHA256: sourceCoordinatorSHA("original-executable"), originalSourceSHA256: nil,
                harnessSHA256: sourceCoordinatorSHA(harness.sourceUTF8), compilerSHA256: sourceCoordinatorSHA("compiler"),
                sdkIdentitySHA256: sourceCoordinatorSHA("sdk"), compileProfileSHA256: sourceCoordinatorSHA("profile"),
                compileArgumentsSHA256: sourceCoordinatorSHA("compile"), executionArgumentsSHA256: sourceCoordinatorSHA("execution"),
                producerSHA256: sourceCoordinatorSHA("producer"), standardOutput: Data(observed.utf8),
                sessionID: UUID(), requestID: UUID(), processIdentifier: 123, sampledProcessIDs: [123],
                exitCode: 0, observedProcessAbsent: true), evidenceIDs: [evidence.evidenceID]))
        let oraclePayload = try ReconstructionSourceOracleEvidence.encode(oracle)
        let oracleRecord = try ReconstructionEvidenceRecord(evidenceID: UUID(), subject: .function(function),
            operationID: ReconstructionSourceOracleEvidence.operationID, payloadKind: .structuredJSON,
            payload: oraclePayload, payloadByteCount: UInt64(oraclePayload.count), payloadSHA256: sourceCoordinatorSHA(oraclePayload),
            facetDependencies: [], producer: evidence.producer, citations: [], creatingJobID: jobID,
            creatingTaskID: UUID(), creatingCheckpointID: checkpointID, modelReceiptID: nil, toolReceiptID: UUID(),
            classification: .acceptedCurrent, supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let records = [evidence, oracleRecord]
        let classifications = Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent) })
        let revisions: [UUID: UInt64] = [checkpointID: 1]
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256, records: records,
            projectedClassificationsByEvidenceID: classifications, relations: [], gaps: [], checkpointRevisionsByID: revisions)
        let evidenceCut = try ReconstructionEvidenceCut(corpusManifestSHA256: manifest.canonicalSHA256,
            records: records, relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: classifications, checkpointRevisionsByID: revisions)
        snapshot = .init(jobID: jobID, jobCreationOrder: 1, checkpointID: checkpointID,
            checkpointRevision: 1, checkpointCorpusManifestSHA256: manifest.canonicalSHA256,
            checkpointEvidenceFrontierSHA256: frontier, currentCorpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier, currentDurableJobState: .awaitingModel, pauseContext: nil,
            maximumRoundsWithoutEvidence: 3, tasks: [task], terminalReceiptStatesByTaskID: [:])
        let projection = try ReconstructionToolProjectorInput.canonicalProjectionFrontierSHA256(
            projectedItemsByOperation: [:], staleOperations: [], tasks: [task], receipts: [],
            producersByOperation: [:], evidenceAuthorityCutsByOperation: [:])
        let toolAuthority = try ReconstructionToolAuthorityCut(jobID: jobID, checkpointRevision: 1,
            roundID: roundID, corpusManifestSHA256: manifest.canonicalSHA256, evidenceFrontierSHA256: frontier,
            projectionFrontierSHA256: projection)
        let query = try ReconstructionRetrievalQuery(corpusManifestSHA256: manifest.canonicalSHA256,
            subject: .function(function), operationIDs: [ordinaryOperation], classifications: [.acceptedCurrent],
            cursor: nil, maximumRecords: 1, maximumEncodedBytes: 65_536)
        let projector = try ReconstructionToolProjectorInput(authority: toolAuthority, corpusManifest: manifest,
            evidenceCut: evidenceCut, tasks: [task], receipts: [], producersByOperation: [:],
            projectedItemsByOperation: [:], staleOperations: [], evidenceAuthorityCutsByOperation: [:])
        var context = try ReconstructionSourceContextCompiler().compile(cut: evidenceCut, query: query,
            function: function, oracleSuiteSHA256: oracle.suiteSHA256, parentRevisionSHA256: nil)
        if useOrdinaryContext {
            context = try ReconstructionContextCompiler(maximumContextBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes).compileSourceBase(cut: evidenceCut,
                query: query)
            // A legitimate ordinary context is not a source context, even if its IDs include
            // an ordinary record. Preserve a bounded citation so this is not merely emptiness.
            if context.evidenceIDs.isEmpty {
                context = .init(canonicalBytes: context.canonicalBytes, canonicalSHA256: context.canonicalSHA256,
                    evidenceIDs: [evidence.evidenceID])
            }
        }
        if let contextText {
            let bytes = Data(contextText.utf8)
            context = .init(canonicalBytes: bytes, canonicalSHA256: sourceCoordinatorSHA(bytes), evidenceIDs: context.evidenceIDs)
        }
        let objective = try ReconstructionRequestObjective(jobID: jobID, text: "Reconstruct bounded C",
            sha256: sourceCoordinatorSHA("Reconstruct bounded C"))
        request = .init(protocolVersion: 10, objective: objective, projectID: manifest.reconstructionProjectID,
            jobID: jobID, taskID: taskID, checkpointRevision: 1, roundID: roundID, function: function,
            corpusManifestSHA256: manifest.canonicalSHA256, evidenceFrontierSHA256: frontier,
            oracleSuiteSHA256: oracle.suiteSHA256, profileID: ReconstructionSourceInferenceContract.profileID,
            parentRevisionSHA256: nil, context: context)
        prepared = .init(roundID: roundID, evidenceCut: evidenceCut, retrievalQuery: query,
            allowedGapSubjects: [], allowedGapCategories: [], authority: toolAuthority, requests: [],
            projectorInput: projector, sourceRevisionRequest: request,
            finalSynthesisRequest: includeFinal ? .init(jobID: jobID, checkpointRevision: 1,
                corpusManifestSHA256: manifest.canonicalSHA256, evidenceFrontierSHA256: frontier,
                acceptedEvidenceIDs: context.evidenceIDs, context: context) : nil, objective: objective)
        lease = .init(providerRevision: 1, configuration: try .init(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:1234", model: "fixture-model", maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000),
            observedModelInventorySHA256: sourceCoordinatorSHA("inventory"))
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: jobID,
            checkpointRevision: 1, roundID: roundID, status: .completed)
        source = .init(candidate: .init(profileID: request.profileID, parentRevisionSHA256: nil,
            sourceText: "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }",
            evidenceIDs: context.evidenceIDs), usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: terminal)
        authority = try .make(expectedRequestID: terminal.requestID, request: .sourceRevision(request), terminalReceipt: terminal)
    }

    func preparedReplacingSource(_ request: ReconstructionSourceRevisionRequest?) -> ReconstructionPreparedModelRound {
        .init(roundID: prepared.roundID, evidenceCut: prepared.evidenceCut, retrievalQuery: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects, allowedGapCategories: prepared.allowedGapCategories,
            authority: prepared.authority, requests: prepared.requests, projectorInput: prepared.projectorInput,
            sourceRevisionRequest: request, finalSynthesisRequest: prepared.finalSynthesisRequest, objective: prepared.objective)
    }
}

@MainActor
private final class SourceCoordinatorReady: ReconstructionReadyInferenceCoordinating {
    var result: ReconstructionReadySourceRevisionExecutionResult
    var suspendSource = false
    var entered: XCTestExpectation?
    private(set) var sourceRequests: [ReconstructionSourceRevisionRequest] = []
    private(set) var regularCalls = 0
    private(set) var finalCalls = 0
    init(result: ReconstructionReadySourceRevisionExecutionResult) { self.result = result }
    func proposeSourceRevision(request: ReconstructionSourceRevisionRequest) async -> ReconstructionReadySourceRevisionExecutionResult {
        sourceRequests.append(request)
        entered?.fulfill()
        if suspendSource {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return .failedWithoutTerminalAuthority(.cancelled) }
        }
        return result
    }
    func run(request: ReconstructionInferenceRoundRequest) async -> ReconstructionReadyInferenceExecutionResult {
        regularCalls += 1; return .busy
    }
    func synthesize(request: ReconstructionFinalSynthesisRequest) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        finalCalls += 1; return .busy
    }
}

private actor SourceCoordinatorMaterializer: ReconstructionJobRoundMaterializing {
    let prepared: ReconstructionPreparedModelRound
    private(set) var sources: [ReconstructionSourceRevisionExecutionResult] = []
    private(set) var failures: [ReconstructionJobCoordinatorFailure] = []
    private(set) var discards = 0
    init(prepared: ReconstructionPreparedModelRound) { self.prepared = prepared }
    func prepare(snapshot: ReconstructionJobOrchestrationSnapshot) async throws -> ReconstructionRoundPreparation { .model(prepared) }
    func discardPreparedRound(snapshot: ReconstructionJobOrchestrationSnapshot, prepared: ReconstructionPreparedModelRound) async { discards += 1 }
    func makeSourceCommitPlan(snapshot: ReconstructionJobOrchestrationSnapshot, prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease, requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult) async throws -> ReconstructionJobCommitPlan {
        sources.append(source); return .init(successorRevision: snapshot.checkpointRevision + 1, acceptedEvidenceCount: 1, disposition: .continue, mutation: nil)
    }
    func makeCommitPlan(snapshot: ReconstructionJobOrchestrationSnapshot, prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease, requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult, executions: [ReconstructionToolExecution]) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeFailedModelPlan(snapshot: ReconstructionJobOrchestrationSnapshot, prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease, requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure) async throws -> ReconstructionJobCommitPlan {
        failures.append(reason); return .init(successorRevision: snapshot.checkpointRevision + 1, acceptedEvidenceCount: 0, disposition: .continue, mutation: nil)
    }
    func makeFinalCommitPlan(snapshot: ReconstructionJobOrchestrationSnapshot, prepared: ReconstructionPreparedModelRound,
        lease: Phase2ReadyInferenceLease, requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeRecoveryPlan(snapshot: ReconstructionJobOrchestrationSnapshot, transitions: [ReconstructionTaskTransition]) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeControlPlan(snapshot: ReconstructionJobOrchestrationSnapshot, reason: ReconstructionJobPauseReason) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
}

private struct SourceCoordinatorCutProvider: ReconstructionProductionCommittedRoundCutProviding {
    let cut: ReconstructionProductionCommittedRoundCut
    func capture(snapshot: ReconstructionJobOrchestrationSnapshot) async throws -> ReconstructionProductionCommittedRoundCut { cut }
}

private actor SourceCoordinatorPlanBuilder: ReconstructionProductionRoundPlanBuilding {
    private(set) var sourceCalls = 0
    func makePreInferenceCommitPlan(cut: ReconstructionProductionCommittedRoundCut) async throws -> ReconstructionJobCommitPlan? { nil }
    func makeSourceCommitPlan(cut: ReconstructionProductionCommittedRoundCut, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority, source: ReconstructionSourceRevisionExecutionResult) async throws -> ReconstructionJobCommitPlan {
        sourceCalls += 1; throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func makeCommitPlan(cut: ReconstructionProductionCommittedRoundCut, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority, inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeFailedModelPlan(cut: ReconstructionProductionCommittedRoundCut, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority, reason: ReconstructionJobCoordinatorFailure) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeFinalCommitPlan(cut: ReconstructionProductionCommittedRoundCut, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority, synthesis: ReconstructionFinalSynthesisExecutionResult) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeRecoveryPlan(cut: ReconstructionProductionCommittedRoundCut, transitions: [ReconstructionTaskTransition]) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func makeControlPlan(cut: ReconstructionProductionCommittedRoundCut, reason: ReconstructionJobPauseReason) async throws -> ReconstructionJobCommitPlan { throw ReconstructionJobCoordinatorFailure.invalidCommitPlan }
    func discardPreparedRound(cut: ReconstructionProductionCommittedRoundCut) async {}
}

private func sourceCoordinatorSHA(_ text: String) -> String { sourceCoordinatorSHA(Data(text.utf8)) }
private func sourceCoordinatorSHA(_ data: Data) -> String { ReconstructionSourceInferenceContract.sha256(data) }

final class ReconstructionSourceContextCompilerTests: XCTestCase {
    func testProductionSizedDecompilerObservationSurvivesContextWireAndRequestBinding() throws {
        // Synthetic content at the retained installed observation's 3086-byte payload size;
        // this verifies admission bounds, not model execution or oracle correctness.
        var observation: [String: Any] = ["schemaVersion": 1, "outcome": "completed",
            "task": ["operationID": ReconstructionOperationID.decompilerMacScope.rawValue],
            "projection": ["analysisFingerprintSHA256": sourceCoordinatorSHA("analysis"),
                "function": ["name": "reconstructed", "startAddress": 4_096, "endAddress": 4_112],
                "functionCatalog": [], "functionCatalogWasTruncated": false,
                "functionNamesWereTruncated": false, "macScopePseudocode": ""]]
        let empty = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys, .withoutEscapingSlashes])
        var projection = try XCTUnwrap(observation["projection"] as? [String: Any])
        projection["macScopePseudocode"] = String(repeating: "x", count: 3_086 - empty.count)
        observation["projection"] = projection
        let payload = try JSONSerialization.data(withJSONObject: observation,
            options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(payload.count, 3_086)
        let fixture = try SourceCoordinatorFixture(ordinaryPayload: payload)
        let request = fixture.request
        try request.validate()
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: request.context.canonicalBytes)
        XCTAssertGreaterThan(envelope.baseContext.count, 4_096)
        XCTAssertLessThanOrEqual(envelope.baseContext.count, ReconstructionSourceContextCompiler.maximumBaseContextBytes)
        XCTAssertLessThanOrEqual(request.context.canonicalBytes.count, ReconstructionSourceContextCompiler.maximumContextBytes)
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let requestID = UUID()
        let wire = try codec.encodeSourceRequest(request, requestID: requestID)
        guard case .sourceRevision(let decodedID, let decoded) = try codec.decodeRequest(wire) else {
            return XCTFail("Expected source request")
        }
        XCTAssertEqual(decodedID, requestID)
        XCTAssertEqual(decoded, request)
        let configuration = Phase2AIWorkerConfigurationWire(schemaVersion: 1, profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: "fixture-model",
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest,
            maximumTokens: 16_384, requestTimeoutMilliseconds: 300_000, resourceTimeoutMilliseconds: 1_800_000,
            inferencePolicy: .init())
        let provider = try Phase2ReconstructionOpenAIChatRequestEncoder().encode(
            request: .sourceRevision(decoded), configuration: configuration)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: provider.requestBody) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let visible = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(visible.contains("macScopePseudocode"))
        XCTAssertTrue(visible.contains(String(repeating: "x", count: 128)))
        XCTAssertFalse(visible.contains(request.context.canonicalBytes.base64EncodedString()))
        let (_, revision) = try parent(fixture, source: "uint32_t reconstructed(uint32_t x) { return x; }", bound: true)
        XCTAssertEqual(revision.requestBinding?.canonicalRequestBytes, try ReconstructionCanonicalJSON.encode(request))
        let ordinary = try XCTUnwrap(fixture.prepared.evidenceCut.records.first { $0.operationID == ReconstructionOperationID.decompilerMacScope.rawValue })
        XCTAssertEqual(ordinary.payload, payload)
        XCTAssertTrue(request.context.evidenceIDs.contains(ordinary.evidenceID))
    }

    func testProductionSourceQueryUsesBoundedBaseBudgetInPreparationAndAuthorityCapture() throws {
        let fixture = try ProductionSourceOwnerFixture.make(sourceState: .pending)
        let prepared = try ReconstructionProductionPreparedRoundBuilder.makeDirectCommitDescriptor(from: fixture.basis)
        XCTAssertEqual(prepared.retrievalQuery.maximumEncodedBytes,
            ReconstructionSourceContextCompiler.maximumBaseContextBytes)
        XCTAssertEqual(prepared.retrievalQuery.maximumRecords, 4)
        let request = try XCTUnwrap(prepared.sourceRevisionRequest)
        XCTAssertLessThanOrEqual(request.context.canonicalBytes.count, ReconstructionSourceContextCompiler.maximumContextBytes)
        let captured = try ReconstructionProductionSourceAuthority.capture(request: request, basis: fixture.basis)
        XCTAssertEqual(captured.authority.admissibleEvidenceIDs, Set(request.context.evidenceIDs))
        let smallerQuery = try ReconstructionRetrievalQuery(corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256,
            subject: .function(fixture.function), operationIDs: MacScopeAnalysisCore.ReconstructionOperationID.allCases,
            classifications: [.acceptedCurrent], cursor: nil, maximumRecords: 4,
            maximumEncodedBytes: 2_048, focus: fixture.basis.job.focus)
        // The actual production-shaped ordinary observation must fit without changing its evidence
        // bytes: under the smaller page budget it travels alone on a flagged oversize page (lead 0351).
        let oversize = try ReconstructionRetrievalCompiler().compile(cut: fixture.basis.evidenceCut, query: smallerQuery)
        XCTAssertTrue(oversize.oversizePage)
        XCTAssertNil(oversize.recordTooLarge)
        XCTAssertEqual(oversize.records.count, 1)
        XCTAssertGreaterThan(oversize.encodedByteCount, 2_048)
    }

    func testOracleSummaryIsReadableBoundedAndDistinctFromOrdinaryContext() throws {
        let fixture = try SourceCoordinatorFixture()
        let context = fixture.request.context
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: context.canonicalBytes)
        XCTAssertEqual(envelope.domain, ReconstructionSourceContextCompiler.domain)
        XCTAssertEqual(envelope.schemaVersion, 10)
        XCTAssertEqual(envelope.oracle.inputs.count, 37)
        XCTAssertEqual(envelope.oracle.outputs.count, 37)
        XCTAssertEqual(envelope.oracle.suiteSHA256, fixture.request.oracleSuiteSHA256)
        XCTAssertTrue(context.evidenceIDs.contains(envelope.oracle.evidenceID))
        XCTAssertLessThanOrEqual(context.canonicalBytes.count, ReconstructionSourceContextCompiler.maximumContextBytes)
        XCTAssertTrue(context.allowedGapIDs.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: context.canonicalBytes) as? [String: Any])
        let oracleObject = try XCTUnwrap(object["oracle"] as? [String: Any])
        XCTAssertNil(oracleObject["execution"])
        XCTAssertNil(oracleObject["standardOutput"])
        let ordinary = try ReconstructionContextCompiler(maximumContextBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes).compileSourceBase(
            cut: fixture.prepared.evidenceCut, query: fixture.prepared.retrievalQuery)
        XCTAssertNotEqual(context, ordinary)
    }

    func testOracleCannotBeMissingDuplicatedOrSelectedByInventedSuite() throws {
        let fixture = try SourceCoordinatorFixture()
        let records = fixture.prepared.evidenceCut.records
        let oracle = try XCTUnwrap(records.first { $0.operationID == ReconstructionSourceOracleEvidence.operationID })
        XCTAssertThrowsError(try compile(fixture, records: records.filter { $0.evidenceID != oracle.evidenceID }))
        let duplicate = try record(fixture, operation: oracle.operationID, payload: oracle.payload)
        XCTAssertThrowsError(try compile(fixture, records: records + [duplicate]))
        XCTAssertThrowsError(try ReconstructionSourceContextCompiler().compile(
            cut: fixture.prepared.evidenceCut, query: fixture.prepared.retrievalQuery,
            function: fixture.request.function, oracleSuiteSHA256: sourceCoordinatorSHA("invented-suite"), parentRevisionSHA256: nil))
    }

    func testSourceBaseRejectsUnknownOperationsInsteadOfGrantingGenericDiagnosticAuthority() throws {
        let fixture = try SourceCoordinatorFixture()
        let unknown = try record(fixture, operation: "unknown.diagnostic", payload: Data("unknown".utf8))
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [unknown])) { error in
            XCTAssertEqual(error as? ReconstructionContextCompilerError,
                .retrieval(.unknownOperation("unknown.diagnostic")))
        }
    }

    func testParentIsExactSourceAndCannotBeInventedOrTruncated() throws {
        let fixture = try SourceCoordinatorFixture()
        let (parentRecord, revision) = try parent(fixture, source: "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }")
        let context = try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord], parent: revision.revisionSHA256)
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: context.canonicalBytes)
        XCTAssertEqual(envelope.parent?.sourceText, String(data: revision.sourceUTF8, encoding: .utf8))
        XCTAssertEqual(envelope.parent?.revisionSHA256, revision.revisionSHA256)
        XCTAssertEqual(envelope.parent?.sourceSHA256, revision.sourceSHA256)
        XCTAssertTrue(context.evidenceIDs.contains(parentRecord.evidenceID))
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord], parent: sourceCoordinatorSHA("invented-parent")))
        let (oversizeRecord, oversize) = try parent(fixture, source: String(repeating: "x", count: 4_097))
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [oversizeRecord], parent: oversize.revisionSHA256))
    }

    func testBoundParentUsesOfferedRequestEvidenceWhenCandidateCitesStrictSubset() throws {
        let fixture = try SourceCoordinatorFixture()
        let records = fixture.prepared.evidenceCut.records
        let ordinary = try XCTUnwrap(records.first {
            $0.operationID == MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue
        })
        let oracle = try XCTUnwrap(records.first {
            $0.operationID == ReconstructionSourceOracleEvidence.operationID
        })
        let offered = fixture.request.context.evidenceIDs
        XCTAssertEqual(Set(offered), Set([ordinary.evidenceID, oracle.evidenceID]))
        // Cite only the oracle, while retaining the ordinary record in the bound request's offered set.
        let (parentRecord, revision) = try parent(fixture,
            source: "uint32_t reconstructed(uint32_t x) { return x; }", bound: true,
            citedIDs: [oracle.evidenceID])
        let result = try compile(fixture, records: records + [parentRecord], parent: revision.revisionSHA256)
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: result.canonicalBytes)
        XCTAssertEqual(envelope.parent?.revisionSHA256, revision.revisionSHA256)
        XCTAssertEqual(revision.evidenceIDs, [oracle.evidenceID])
        XCTAssertLessThan(Set(revision.evidenceIDs).count, offered.count)
        let missingOffered = records.filter { $0.evidenceID != ordinary.evidenceID } + [parentRecord]
        XCTAssertThrowsError(try compile(fixture, records: missingOffered,
            parent: revision.revisionSHA256)) { error in
                XCTAssertEqual(error as? ReconstructionSourceContextCompiler.Failure, .invalidParent)
            }

        let payloadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: parentRecord.payload) as? [String: Any])
        for field in ["requestSHA256", "taskID", "roundID", "checkpointRevision"] {
            var object = payloadObject
            var binding = try XCTUnwrap(object["requestBinding"] as? [String: Any])
            if field == "checkpointRevision" { binding[field] = 99 }
            else if field == "requestSHA256" { binding[field] = sourceCoordinatorSHA("forged") }
            else { binding[field] = UUID().uuidString }
            object["requestBinding"] = binding
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let forged = try record(fixture, operation: ReconstructionSourceRevisionEvidence.operationID,
                payload: bytes, taskID: fixture.request.taskID)
            XCTAssertThrowsError(try compile(fixture, records: records + [forged],
                parent: revision.revisionSHA256), field) { error in
                XCTAssertEqual(error as? ReconstructionSourceContextCompiler.Failure, .invalidParent, field)
            }
        }
    }

    func testOnlyLatestExplicitDiagnosticForExactParentIsIncluded() throws {
        let fixture = try SourceCoordinatorFixture()
        let (parentRecord, revision) = try parent(fixture, source: "uint32_t reconstructed(uint32_t x) { return x; }")
        let older = try diagnostic(fixture, revision: revision, text: "old mismatch", checkpointRevision: 1)
        let newest = try diagnostic(fixture, revision: revision, text: "current case 4294967295 differs", checkpointRevision: 2)
        let unrelated = try record(fixture, operation: MacScopeAnalysisCore.ReconstructionOperationID.functionReview.rawValue, payload: Data("unrelated ordinary review".utf8))
        let context = try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, older.record, newest.record, unrelated],
            parent: revision.revisionSHA256, revisions: [older.record.creatingCheckpointID: 1, newest.record.creatingCheckpointID: 2])
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: context.canonicalBytes)
        XCTAssertEqual(envelope.diagnostics.count, 1)
        XCTAssertEqual(envelope.diagnostics.first?.evidenceID, newest.record.evidenceID)
        XCTAssertEqual(envelope.diagnostics.first?.diagnostic, "current case 4294967295 differs")
        XCTAssertFalse(context.evidenceIDs.contains(older.record.evidenceID))
        XCTAssertFalse(context.evidenceIDs.contains(unrelated.evidenceID))
        let tie = try diagnostic(fixture, revision: revision, text: "ambiguous retry", checkpointRevision: 2)
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, newest.record, tie.record],
            parent: revision.revisionSHA256, revisions: [newest.record.creatingCheckpointID: 2, tie.record.creatingCheckpointID: 2]))
    }

    func testEnlargedContextBudgetPreservesParentAndDiagnosticsWithoutTruncation() throws {
        let fixture = try SourceCoordinatorFixture()
        let (parentRecord, revision) = try parent(fixture, source: String(repeating: "x", count: 4_096))
        let payload = try ReconstructionCanonicalJSON.encode(ReconstructionSourceDiagnosticPayload(version: 1,
            profileID: revision.profileID, function: revision.function, revisionSHA256: revision.revisionSHA256,
            sourceSHA256: revision.sourceSHA256, diagnostic: String(repeating: "d", count: 2_048)))
        let build = try record(fixture, operation: ReconstructionSourceContextCompiler.buildOperationID, payload: payload)
        let behavior = try record(fixture, operation: ReconstructionSourceContextCompiler.behaviorOperationID, payload: payload)
        let context = try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, build, behavior],
            parent: revision.revisionSHA256)
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: context.canonicalBytes)
        XCTAssertEqual(envelope.parent?.sourceText, String(repeating: "x", count: 4_096))
        XCTAssertEqual(envelope.diagnostics.count, 2)
        XCTAssertLessThanOrEqual(context.canonicalBytes.count, ReconstructionSourceContextCompiler.maximumContextBytes)
    }

    func testAggregateEvaluationUsesOneActualRecordAndLatestCheckpoint() throws {
        let fixture = try SourceCoordinatorFixture()
        let (parentRecord, revision) = try parent(fixture, source: "uint32_t reconstructed(uint32_t x) { return x; }", bound: true)
        let older = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 2)
        let newest = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 3)
        let legacy = try diagnostic(fixture, revision: revision, text: "legacy observation", checkpointRevision: 4)
        let context = try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, older, newest, legacy.record],
            parent: revision.revisionSHA256, revisions: [older.creatingCheckpointID: 2, newest.creatingCheckpointID: 3, legacy.record.creatingCheckpointID: 4])
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: context.canonicalBytes)
        XCTAssertEqual(envelope.diagnostics.count, 1)
        let summary = try XCTUnwrap(envelope.diagnostics.first)
        XCTAssertEqual(summary.operationID, ReconstructionSourceContextCompiler.evaluationOperationID)
        XCTAssertEqual(summary.evidenceID, newest.evidenceID)
        XCTAssertEqual(summary.payloadSHA256, newest.payloadSHA256)
        XCTAssertEqual(summary.checkpointRevision, 3)
        XCTAssertTrue(summary.diagnostic.contains("Compiler: completed"))
        XCTAssertTrue(summary.diagnostic.contains("Behavior: completed"))
        XCTAssertTrue(summary.diagnostic.contains("input=4294967295 expected=4294967295 observed=0"))
        XCTAssertTrue(context.evidenceIDs.contains(newest.evidenceID))
        XCTAssertFalse(context.evidenceIDs.contains(older.evidenceID))
        XCTAssertFalse(context.evidenceIDs.contains(legacy.record.evidenceID))
        XCTAssertEqual(envelope.parent?.sourceText, String(data: revision.sourceUTF8, encoding: .utf8))
        XCTAssertEqual(envelope.oracle.suiteSHA256, fixture.request.oracleSuiteSHA256)
    }

    func testAggregateEvaluationRejectsOracleRequestCheckpointAndTieDrift() throws {
        let fixture = try SourceCoordinatorFixture()
        let (parentRecord, revision) = try parent(fixture, source: "uint32_t reconstructed(uint32_t x) { return x; }", bound: true)
        let wrongOracle = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 2,
            oracleSuiteSHA256: sourceCoordinatorSHA("different oracle"))
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, wrongOracle],
            parent: revision.revisionSHA256, revisions: [wrongOracle.creatingCheckpointID: 2]))
        let wrongRequest = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 2,
            sourceRequestSHA256: sourceCoordinatorSHA("different source request"))
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, wrongRequest],
            parent: revision.revisionSHA256, revisions: [wrongRequest.creatingCheckpointID: 2]))
        let one = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 2)
        let two = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 2)
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, one, two],
            parent: revision.revisionSHA256, revisions: [one.creatingCheckpointID: 2, two.creatingCheckpointID: 2]))
        XCTAssertThrowsError(try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, one],
            parent: revision.revisionSHA256, revisions: [one.creatingCheckpointID: 3]))
    }

    func testAggregatePresentationBoundsEveryStageAndPreservesMandatorySource() throws {
        let fixture = try SourceCoordinatorFixture()
        let (parentRecord, revision) = try parent(fixture, source: "uint32_t reconstructed(uint32_t x) { return x; }", bound: true)
        let large = try evaluation(fixture, parentRecord: parentRecord, revision: revision, checkpointRevision: 2,
            compilerDiagnostic: Data(String(repeating: "é", count: 8_192).utf8))
        let context = try compile(fixture, records: fixture.prepared.evidenceCut.records + [parentRecord, large],
            parent: revision.revisionSHA256, revisions: [large.creatingCheckpointID: 2])
        let envelope = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self, from: context.canonicalBytes)
        let summary = try XCTUnwrap(envelope.diagnostics.first)
        XCTAssertLessThanOrEqual(summary.diagnostic.utf8.count, 2_048)
        XCTAssertTrue(summary.diagnostic.contains("Inspection: completed"))
        XCTAssertTrue(summary.diagnostic.contains("Compiler: completed"))
        XCTAssertTrue(summary.diagnostic.contains("Behavior: completed"))
        XCTAssertTrue(summary.diagnostic.contains("[diagnostic text omitted]"))
        XCTAssertLessThanOrEqual(context.canonicalBytes.count, ReconstructionSourceContextCompiler.maximumContextBytes)
        XCTAssertEqual(envelope.parent?.sourceText, String(data: revision.sourceUTF8, encoding: .utf8))
        XCTAssertEqual(envelope.oracle.inputs.count, 37)
        XCTAssertEqual(envelope.oracle.outputs.count, 37)
    }

    private func evaluation(_ fixture: SourceCoordinatorFixture, parentRecord: ReconstructionEvidenceRecord,
        revision: ReconstructionSourceRevision, checkpointRevision: UInt64,
        oracleSuiteSHA256: String? = nil, sourceRequestSHA256: String? = nil,
        compilerDiagnostic: Data = Data("actual controlled compiler observation".utf8)) throws -> ReconstructionEvidenceRecord {
        let oracleRecord = try XCTUnwrap(fixture.prepared.evidenceCut.records.first { $0.operationID == ReconstructionSourceOracleEvidence.operationID })
        let oracle = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: oracleRecord.payload)
        let producer = try ReconstructionProducerIdentity(macScopeBuildIdentity: "fixture", macScopeSourceIdentity: "fixture",
            operationIdentity: ReconstructionSourceContextCompiler.evaluationOperationID, registryIdentity: "fixture",
            protocolIdentity: "fixture", canonicalSHA256: sourceCoordinatorSHA("producer"))
        let sessionID = UUID(), taskID = UUID()
        let terminal = ReconstructionSourceEvaluation.Terminal(kind: .exited, status: 0)
        var outputs = oracle.outputs
        outputs[4] = 0
        let observedText = oracle.inputs.indices.map { "\(oracle.inputs[$0]):\(outputs[$0])\n" }.joined()
        let phases = [ReconstructionSourceEvaluation.Operation.inspect, .compile, .behavior].map { operation in
            let requestID = UUID()
            let diagnostic: Data = operation == .compile ? compilerDiagnostic : operation == .behavior ? Data(observedText.utf8) : Data()
            return ReconstructionSourceEvaluation.Phase(operation: operation, requestID: requestID, sessionID: sessionID,
                requestIdentitySHA256: sourceCoordinatorSHA(operation.rawValue), status: .completed,
                terminal: terminal, failure: nil, diagnostics: diagnostic,
                cleanup: .init(sessionID: sessionID, requestID: requestID, processIdentifier: 345,
                    observedProcessAbsent: true, outcome: terminal), sampledProcessIDs: [345], peakGroupResidentBytes: 1_024,
                elapsedMilliseconds: 10)
        }
        let outcome = ReconstructionSourceEvaluation.CapturedOutcome(status: .behaviorMismatch,
            failureDetail: "one independently observed case differs", runnerSHA256: sourceCoordinatorSHA("runner"),
            compilerSHA256: sourceCoordinatorSHA("compiler"), sdkSettingsSHA256: sourceCoordinatorSHA("sdk"),
            harnessSHA256: oracle.execution.harnessSHA256, inspectionSHA256: sourceCoordinatorSHA("ast"),
            astSHA256: sourceCoordinatorSHA("ast"), executableSHA256: sourceCoordinatorSHA("executable"), phases: phases,
            observations: oracle.inputs.indices.map { .init(input: oracle.inputs[$0], output: outputs[$0]) },
            mismatches: [.init(index: 4, input: oracle.inputs[4], expected: oracle.outputs[4], actual: outputs[4])])
        func value(_ identity: String) -> ReconstructionSourceEvaluation {
            .init(version: 1, profileID: ReconstructionSourceEvaluation.profileID, projectID: fixture.request.projectID,
                jobID: fixture.request.jobID, taskID: taskID, checkpointRevision: checkpointRevision,
                evaluationRequestSHA256: sourceCoordinatorSHA("evaluation request"), function: fixture.request.function,
                sourceEvidenceID: parentRecord.evidenceID, sourcePayloadSHA256: parentRecord.payloadSHA256,
                revisionSHA256: revision.revisionSHA256, sourceSHA256: revision.sourceSHA256,
                sourceRequestSHA256: sourceRequestSHA256 ?? revision.requestBinding?.requestSHA256 ?? sourceCoordinatorSHA("unbound request"),
                oracleEvidenceID: oracleRecord.evidenceID, oraclePayloadSHA256: oracleRecord.payloadSHA256,
                oracleSuiteSHA256: oracleSuiteSHA256 ?? oracle.suiteSHA256, producerSHA256: producer.canonicalSHA256,
                capturedOutcome: outcome, evaluationSHA256: identity)
        }
        let payload = try ReconstructionSourceEvaluationCodec.encode(value(
            ReconstructionSourceEvaluationCodec.canonicalIdentity(value(sourceCoordinatorSHA("draft")))))
        _ = try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: payload)
        return try record(fixture, operation: ReconstructionSourceContextCompiler.evaluationOperationID,
            payload: payload, checkpointID: UUID(), taskID: taskID, producer: producer)
    }

    private func compile(_ fixture: SourceCoordinatorFixture, records: [ReconstructionEvidenceRecord], parent: String? = nil,
        revisions overrides: [UUID: UInt64] = [:]) throws -> ReconstructionRetrievedContext {
        let classifications = Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, $0.classification) })
        let revisions = Dictionary(records.map { ($0.creatingCheckpointID, overrides[$0.creatingCheckpointID] ?? 1) }, uniquingKeysWith: { first, _ in first })
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(corpusManifestSHA256: fixture.request.corpusManifestSHA256,
            records: records, projectedClassificationsByEvidenceID: classifications, relations: [], gaps: [], checkpointRevisionsByID: revisions)
        let cut = try ReconstructionEvidenceCut(corpusManifestSHA256: fixture.request.corpusManifestSHA256,
            records: records, relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: classifications, checkpointRevisionsByID: revisions)
        return try ReconstructionSourceContextCompiler().compile(cut: cut, query: fixture.prepared.retrievalQuery,
            function: fixture.request.function, oracleSuiteSHA256: fixture.request.oracleSuiteSHA256, parentRevisionSHA256: parent)
    }

    private func record(_ fixture: SourceCoordinatorFixture, operation: String, payload: Data,
        checkpointID: UUID? = nil, taskID: UUID? = nil,
        producer: ReconstructionProducerIdentity? = nil) throws -> ReconstructionEvidenceRecord {
        try .init(evidenceID: UUID(), subject: .function(fixture.request.function), operationID: operation,
            payloadKind: .structuredJSON, payload: payload, payloadByteCount: UInt64(payload.count), payloadSHA256: sourceCoordinatorSHA(payload),
            facetDependencies: [], producer: producer ?? fixture.prepared.evidenceCut.records[0].producer, citations: [],
            creatingJobID: fixture.request.jobID, creatingTaskID: taskID ?? UUID(), creatingCheckpointID: checkpointID ?? fixture.snapshot.checkpointID,
            modelReceiptID: nil, toolReceiptID: UUID(), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
    }

    private func parent(_ fixture: SourceCoordinatorFixture, source: String, bound: Bool = false,
        citedIDs: [UUID]? = nil, requestOverride: ReconstructionSourceRevisionRequest? = nil) throws -> (ReconstructionEvidenceRecord, ReconstructionSourceRevision) {
        let bytes = Data(source.utf8)
        let request = requestOverride ?? fixture.request
        let originalAuthority = ReconstructionSourceRevisionAuthority(projectID: fixture.request.projectID,
            jobID: fixture.request.jobID, function: fixture.request.function, objectiveSHA256: fixture.request.objective.sha256,
            evidenceFrontierSHA256: request.evidenceFrontierSHA256, oracleSuiteSHA256: fixture.request.oracleSuiteSHA256,
            admissibleEvidenceIDs: Set(request.context.evidenceIDs), currentRevision: nil)
        let binding: ReconstructionSourceRequestBinding?
        if bound {
            binding = try ReconstructionSourceRevisionAdmission.makeRequestBinding(
                canonicalRequestBytes: ReconstructionCanonicalJSON.encode(request),
                requestSHA256: ReconstructionCanonicalJSON.sha256(of: request), authority: originalAuthority,
                expectedTaskID: fixture.request.taskID, expectedRoundID: fixture.request.roundID,
                expectedCheckpointRevision: fixture.request.checkpointRevision)
        } else { binding = nil }
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: .init(parentRevisionSHA256: nil,
            sourceUTF8: bytes, claimedSourceSHA256: sourceCoordinatorSHA(bytes), evidenceIDs: citedIDs ?? fixture.request.context.evidenceIDs),
            authority: .init(projectID: fixture.request.projectID, jobID: fixture.request.jobID, function: fixture.request.function,
                objectiveSHA256: fixture.request.objective.sha256, evidenceFrontierSHA256: request.evidenceFrontierSHA256,
                oracleSuiteSHA256: fixture.request.oracleSuiteSHA256, admissibleEvidenceIDs: Set(request.context.evidenceIDs),
                currentRevision: nil, requestBinding: binding))
        return (try record(fixture, operation: ReconstructionSourceRevisionEvidence.operationID,
            payload: ReconstructionSourceRevisionAdmission.encode(revision), taskID: bound ? fixture.request.taskID : nil), revision)
    }

    private func diagnostic(_ fixture: SourceCoordinatorFixture, revision: ReconstructionSourceRevision, text: String,
        checkpointRevision: UInt64) throws -> (record: ReconstructionEvidenceRecord, revision: UInt64) {
        let payload = ReconstructionSourceDiagnosticPayload(version: 1, profileID: revision.profileID,
            function: revision.function, revisionSHA256: revision.revisionSHA256, sourceSHA256: revision.sourceSHA256, diagnostic: text)
        return (try record(fixture, operation: ReconstructionSourceContextCompiler.behaviorOperationID,
            payload: ReconstructionCanonicalJSON.encode(payload), checkpointID: UUID()), checkpointRevision)
    }
}
