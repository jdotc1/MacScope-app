import AppKit
import Foundation
import XCTest
@testable import MacScope

/// T27 uses bounded synthetic records. No selected user model, sealed export or corpus pass.
@MainActor
final class ReconstructionReplayTests: XCTestCase {
    func testUnknownReaderFeatureIsNamedBeforeClosedManifestCodec() throws {
        let root = TestWorkRoot.authorityURL("lane27-evidence")
            .appendingPathComponent("t27-reader-feature-\(UUID().uuidString).mscope")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"requiredReaderFeatures":["reconstruction.future.v9"],"unexpectedRootField":true}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try MacScopeDocumentPackage.readManifest(from: root)) { error in
            XCTAssertEqual((error as? MacScopeDocumentPackage.UnsupportedReaderFeaturesError)?.features,
                ["reconstruction.future.v9"])
            XCTAssertTrue(error.localizedDescription.contains("reconstruction.future.v9"))
        }
    }

    func testActualTier2jPackagesOpenWithNoReplayAndResaveWithoutReaderFeature() throws {
        let fixtures = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/reconstruction-replay/tier2j-8c91f2134")
        let root = TestWorkRoot.authorityURL("lane27-evidence")
            .appendingPathComponent("t27-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["plain-c-sample", "annotated-c-sample"] {
            // Historical packages retain embedded attachments and old-writer structure.
            // Descriptive host paths are sanitized for the public fixture.
            let old = try MacScopeDocumentPackage.openPackage(from: fixtures.appendingPathComponent(name + ".mscope"))
            XCTAssertTrue(old.reconstructionState.jobs.isEmpty)
            XCTAssertNil(old.reconstructionState.replayRecords)
            XCTAssertTrue(old.manifest.requiredReaderFeatures.isEmpty)
            let saved = root.appendingPathComponent(name + ".mscope")
            try MacScopeDocumentPackage.writePackage(old.manifest, attachmentsByBinaryID: old.attachmentsByBinaryID,
                reconstructionState: old.reconstructionState, reconstructionAttachmentSources: old.reconstructionAttachmentSources,
                to: saved, instructionSidecarData: old.instructionSidecarData)
            let bytes = try Data(contentsOf: saved.appendingPathComponent("manifest.json"))
            let manifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertNil(manifestObject["requiredReaderFeatures"])
            let reopened = try MacScopeDocumentPackage.openPackage(from: saved)
            // Empty breakpoint catalogs acquire a launch-local UUID on decode. Compare the
            // persisted representation, which omits that empty transient catalog identity.
            XCTAssertEqual(try MacScopeDocumentPackage.encodedManifest(reopened.manifest),
                try MacScopeDocumentPackage.encodedManifest(old.manifest))
        }
    }

    func testExplicitHeadlessHostSuppressesQuitOnlyDuringActivity() throws {
        // Only meaningful in a host launched with MACSCOPE_HEADLESS_HOST=1 (the resume matrix and
        // canary hosts); ordinary CoreTests hosts must stay .regular for the window tests.
        try XCTSkipUnless(MacScopeHeadlessHostPolicy.isEnabled,
            "Requires a test host launched with MACSCOPE_HEADLESS_HOST=1")
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
        XCTAssertEqual(MacScopeHeadlessHostPolicy.terminationReply(), .terminateNow)
        let token = ReconstructionExecutionActivity.shared.begin()
        XCTAssertEqual(MacScopeHeadlessHostPolicy.terminationReply(), .terminateCancel)
        ReconstructionExecutionActivity.shared.end(token)
        XCTAssertEqual(MacScopeHeadlessHostPolicy.terminationReply(), .terminateNow)
        XCTAssertFalse(MacScopeHeadlessHostPolicy.shouldIgnoreQuit(isHeadless: false, isExecuting: true))
    }

    func testPromptIdentitySurvivesLaunchAndRetryBindingsButBindsSemanticChanges() throws {
        let fixture = try ReplayFixture()
        let first = try fixture.identity(request: fixture.request(revision: 4), model: fixture.model())
        let restarted = try fixture.model(profileID: UUID(), generation: 9, instanceID: "new-process")
        XCTAssertEqual(first, try fixture.identity(request: fixture.request(revision: 19), model: restarted))
        XCTAssertNotEqual(first, try fixture.identity(request: fixture.request(revision: 19,
            context: Data(#"{"records":[],"diagnostic":"new"}"#.utf8)), model: restarted))
        XCTAssertNotEqual(first, try fixture.identity(request: fixture.request(revision: 19),
            model: fixture.model(contextLength: 16_384)))
        XCTAssertNotEqual(first, try fixture.identity(request: fixture.request(revision: 19),
            model: fixture.model(modelKey: "different-model")))
        XCTAssertNotEqual(first, try fixture.identity(request: fixture.request(revision: 19),
            model: restarted, round: 1))
    }

    func testCompletedReplyReplaysUnderCurrentRequestWithoutFreshProviderCall() async throws {
        let fixture = try ReplayFixture()
        let owner = try fixture.owner()
        let model = try fixture.model()
        let request = fixture.request(revision: 4)
        let fresh = try await fixture.begin(owner: owner, request: request, model: model)
        let terminal = fixture.terminal(request: request, requestID: fresh.requestID)
        let candidate = fixture.candidate(request: request)
        let authority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: fresh.requestID, request: request, terminalReceipt: terminal)
        let published = try await fresh.publish(authority: authority, candidate: candidate,
            usage: .init(promptTokens: 3, completionTokens: 2, totalTokens: 5), provider: UnusedReplayProvider())
        XCTAssertEqual(published.replayReceipt?.mode, .fresh)

        let restarted = try fixture.model(profileID: UUID(), generation: 9, instanceID: "new-process")
        let current = fixture.request(revision: 7)
        let replay = try await fixture.begin(owner: owner, request: current, model: restarted)
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(replay.requestID, fresh.requestID, "Replay retains the original provider-call identity")
        let provider = try XCTUnwrap(replay.provider)
        guard case .roundR2(let round) = current else { return XCTFail("round") }
        let result = try await ReconstructionInferenceRunner().run(requestID: replay.requestID,
            request: round.request, provider: provider, objective: round.objective)
        XCTAssertEqual(result.candidate.checkpointRevision, 7)
        XCTAssertEqual(result.candidate.roundID, round.request.roundID)
        let replayAuthority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: replay.requestID, request: current, terminalReceipt: result.terminalReceipt)
        let admitted = try await replay.publish(authority: replayAuthority, candidate: .round(result.candidate),
            usage: result.usage, provider: provider)
        XCTAssertEqual(admitted.replayReceipt?.mode, .replayed)
        XCTAssertEqual(admitted.replayReceipt?.originalRequestID, fresh.requestID)
        XCTAssertEqual(admitted.replayReceipt?.freshModelCallCount, 0)
        let stored = try await owner.replayRecord(workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, key: replay.record.identity.key)
        XCTAssertEqual(stored?.freshReply?.terminalReceipt, terminal)
        XCTAssertEqual(stored?.replayCount, 1)
        await owner.revoke()
    }

    func testRecordedReplyUnderDifferentModelIsTerminalModelChanged() async throws {
        let fixture = try ReplayFixture()
        let owner = try fixture.owner()
        let request = fixture.request(revision: 4)
        let fresh = try await fixture.begin(owner: owner, request: request, model: fixture.model())
        let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: fresh.requestID,
            request: request, terminalReceipt: fixture.terminal(request: request, requestID: fresh.requestID))
        _ = try await fresh.publish(authority: authority, candidate: fixture.candidate(request: request),
            usage: .init(promptTokens: 3, completionTokens: 2, totalTokens: 5), provider: UnusedReplayProvider())

        let switched = try fixture.model(modelKey: "different-model")
        do {
            _ = try await fixture.begin(owner: owner, request: fixture.request(revision: 7), model: switched)
            XCTFail("The same request answered under another model must not replay or re-dispatch")
        } catch let error as ReconstructionReplayError {
            XCTAssertEqual(error, .modelChanged)
        }
        // Typed and terminal end to end: never mapped to a retryable provider failure or a pause.
        XCTAssertEqual(ReconstructionReadyInferenceFailure.replayAdmission(ReconstructionReplayError.modelChanged),
            .modelChanged)
        XCTAssertEqual(ReconstructionReadyInferenceFailure.replayAdmission(ReconstructionReplayError.staleAdmission),
            .retryableProviderFailure(nil))
        XCTAssertEqual(ReconstructionJobPauseReason.modelChanged.controlDisposition, .failed)
        XCTAssertNil(ReconstructionJobPauseReason.modelChanged.durablePauseCause)
        XCTAssertEqual(try ReconstructionProductionJobRoundMaterializer.failedModelDisposition(for: .modelChanged), .failed)

        // A semantically different request under the new model is an ordinary fresh dispatch.
        let other = try await fixture.begin(owner: owner, request: fixture.request(revision: 7,
            context: Data(#"{"records":[],"diagnostic":"new"}"#.utf8)), model: switched)
        XCTAssertFalse(other.isReplay)
        await owner.revoke()
    }

    func testColdRoundBudgetKeysOnFirstFreshDispatchPerModelLoadNotRoundZero() async throws {
        let tracker = ReconstructionColdRoundTracker()
        let profile = UUID()
        let key = ReconstructionColdRoundTracker.Key(profileID: profile, generation: 1, modelIdentitySHA256: "a")
        XCTAssertTrue(tracker.isColdRound(isReplay: false, key: key), "first dispatch after load is cold")
        XCTAssertFalse(tracker.isColdRound(isReplay: false, key: key), "an already-warm model is warm")
        XCTAssertTrue(tracker.isColdRound(isReplay: false, key: .init(profileID: profile, generation: 2,
            modelIdentitySHA256: "a")), "endpoint reconfiguration reloads")
        XCTAssertTrue(tracker.isColdRound(isReplay: false, key: .init(profileID: UUID(), generation: 1,
            modelIdentitySHA256: "a")), "relaunch (new profile) is cold")
        let other = ReconstructionColdRoundTracker.Key(profileID: profile, generation: 1, modelIdentitySHA256: "b")
        XCTAssertFalse(tracker.isColdRound(isReplay: true, key: other), "a replay makes no provider call")
        XCTAssertTrue(tracker.isColdRound(isReplay: false, key: other), "and does not consume the cold claim")

        // Through a real admission: logical round 0 on a model this process already warmed is warm.
        let fixture = try ReplayFixture()
        let owner = try fixture.owner()
        let model = try fixture.model()
        let session = try await fixture.begin(owner: owner, request: fixture.request(revision: 1), model: model)
        XCTAssertEqual(session.scope.logicalRoundIndex, 0)
        let sessionTracker = ReconstructionColdRoundTracker()
        let policy = ReconstructionBudgetPolicy(warmRoundSeconds: 2, coldRoundMultiplier: 2, jobSeconds: 10)
        XCTAssertEqual(policy.roundSeconds(isColdFirstRound: sessionTracker.isColdRound(session)), 4)
        XCTAssertEqual(policy.roundSeconds(isColdFirstRound: sessionTracker.isColdRound(session)), 2)
        await owner.revoke()
    }

    func testRepairPromptIdentityRetainsDiagnosticFloorAndRejectsFutureEvidence() throws {
        // A bounded synthetic repair envelope built from the failed fixture's original source
        // prompt. The actual provider encoder enforces diagnostic revision <= request revision.
        let path = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/reconstruction-replay/repair-request-floor.json")
        let bytes = try Data(contentsOf: path)
        let request = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self, from: bytes)
        let semantic = ReconstructionAIWorkerRequest.sourceRevision(request)
        let configuration = Phase2AIWorkerConfigurationWire(schemaVersion: 1, profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: "t27-loopback",
            protocolManifestDigest: (try semantic.protocolBundle).manifestDigest, maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000, inferencePolicy: .init())
        let encoder = Phase2ReconstructionOpenAIChatRequestEncoder()
        XCTAssertNoThrow(try encoder.encode(request: semantic, configuration: configuration))
        let canonical = try ReconstructionPromptReplayIdentity.canonicalRequest(semantic)
        guard case .sourceRevision(let normalized) = canonical else { return XCTFail("source") }
        XCTAssertEqual(normalized.checkpointRevision, 20)
        XCTAssertEqual(normalized.context, request.context)
        let body = try encoder.encode(request: canonical, configuration: configuration).requestBody
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["checkpointRevision"] = 99
        object["roundID"] = UUID().uuidString
        let retried = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try encoder.encode(request: ReconstructionPromptReplayIdentity.canonicalRequest(.sourceRevision(retried)),
            configuration: configuration).requestBody, body)
        object["checkpointRevision"] = 19
        let future = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try ReconstructionPromptReplayIdentity.canonicalRequest(.sourceRevision(future)))
    }

    func testDispatchedWithoutReplyRetainsUnknownOutcomeOnRedispatch() async throws {
        let fixture = try ReplayFixture()
        let owner = try fixture.owner()
        let model = try fixture.model()
        let first = try await fixture.begin(owner: owner, request: fixture.request(revision: 1), model: model)
        let retry = try await fixture.begin(owner: owner, request: fixture.request(revision: 2), model: model)
        XCTAssertFalse(retry.isReplay)
        XCTAssertEqual(retry.record.dispatches.count, 2)
        XCTAssertEqual(retry.record.dispatches.last?.previousRequestOutcomeUnknown, first.requestID)
        await owner.revoke()
    }

    func testTerminalSaveRetainsLiveHistoryAndMissingHistoryMeansUnknown() async throws {
        let fixture = try ReplayFixture()
        let root = TestWorkRoot.authorityURL("lane27-evidence")
            .appendingPathComponent("t27-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("workspace.sqlite").path
        let owner = ReconstructionDatabaseOwner(database: try fixture.database(path: path))
        let absent = try await owner.inferenceHistory(workspaceID: fixture.workspaceID, jobID: fixture.job.jobID)
        XCTAssertNil(absent)
        let model = try fixture.model(), request = fixture.request(revision: 1)
        let fresh = try await fixture.begin(owner: owner, request: request, model: model)
        let freshAuthority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: fresh.requestID,
            request: request, terminalReceipt: fixture.terminal(request: request, requestID: fresh.requestID))
        _ = try await fresh.publish(authority: freshAuthority, candidate: fixture.candidate(request: request),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), provider: UnusedReplayProvider())
        let current = fixture.request(revision: 2)
        let replay = try await fixture.begin(owner: owner, request: current, model: model)
        let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: replay.requestID,
            request: current, terminalReceipt: fixture.terminal(request: current, requestID: replay.requestID))
        _ = try await replay.publish(authority: authority, candidate: fixture.candidate(request: current),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), provider: UnusedReplayProvider())
        await owner.revoke()
        let database = try WorkspaceDatabase(path: path)
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(receiptID: replay.requestID,
            jobID: fixture.job.jobID, taskID: fixture.task.identity.taskID, checkpointRevision: 1,
            requestIdentitySHA256: authority.requestIdentitySHA256,
            producer: ReconstructionDatabaseTestFixtures.makeProducer(operationID: ReconstructionProductionTaskContract.modelRound),
            terminalState: .completed, selectedHandleIDs: [], acceptedEvidenceIDs: [], diagnostic: nil)
        let terminal = try fixture.terminalState(replayRecords: nil, modelReceipt: receipt)
        try database.withOwnerReplayTransaction {
            try database.pruneTerminalOwnerReplayRecords(workspaceID: fixture.workspaceID, state: terminal)
        }
        let history = try XCTUnwrap(database.ownerInferenceHistory(workspaceID: fixture.workspaceID, jobID: fixture.job.jobID))
        XCTAssertEqual(history.rounds, [.init(logicalRoundIndex: 0, mode: .replayed, originalRequestID: fresh.requestID)])
        XCTAssertTrue(try database.ownerReplayRecords(workspaceID: fixture.workspaceID).isEmpty)
        // Repeated Save is a changed operation under test: it must retain the existing history
        // even though the first Save removed the detailed active journal.
        try database.withOwnerReplayTransaction {
            try database.pruneTerminalOwnerReplayRecords(workspaceID: fixture.workspaceID, state: terminal)
        }
        XCTAssertEqual(try database.ownerInferenceHistory(workspaceID: fixture.workspaceID, jobID: fixture.job.jobID), history)
        try database.execute("UPDATE owner_job_inference_history SET record_json = X'7b7d';")
        XCTAssertThrowsError(try database.ownerInferenceHistory(workspaceID: fixture.workspaceID, jobID: fixture.job.jobID))
    }

    func testAggregateReplayStorageCountsBudgetRowsBeforeAdmittingAnotherJob() throws {
        let fixture = try ReplayFixture(), database = try fixture.database()
        let budget = ReconstructionExecutionBudgetRecord(schemaVersion: 1, jobID: fixture.job.jobID,
            allowanceSeconds: 10, chargedSeconds: 0, activationID: nil, processSessionID: nil,
            activationStartedAt: nil, recoveredUnclosedIntervals: 0)
        try database.publishOwnerExecutionBudget(workspaceID: fixture.workspaceID, record: budget)
        // Small fixed rows exercise the workspace count boundary without any binary corpus.
        try database.run("""
            WITH RECURSIVE counts(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM counts WHERE n < 2047)
            INSERT INTO owner_job_execution_budget (workspace_uuid, job_id, record_json)
            SELECT ?, 'boundary-' || n, X'7b7d' FROM counts;
            """, bindings: [.text(fixture.workspaceID.uuidString)])
        let identity = try fixture.identity(request: fixture.request(revision: 1), model: fixture.model())
        let marker = ReconstructionReplayRecord(schemaVersion: 1, identity: identity,
            dispatches: [.init(requestID: UUID(), processSessionID: UUID(), dispatchedAt: Date(), previousRequestOutcomeUnknown: nil)],
            freshReply: nil, latestObservation: nil, replayCount: 0)
        XCTAssertThrowsError(try database.publishOwnerReplayRecord(workspaceID: fixture.workspaceID, record: marker, expected: nil)) {
            XCTAssertEqual($0 as? ReconstructionReplayError, .journalFull)
        }
        XCTAssertNil(try database.ownerReplayRecord(jobID: fixture.job.jobID, key: identity.key))
        XCTAssertNoThrow(try database.publishOwnerExecutionBudget(workspaceID: fixture.workspaceID, record: budget))
    }

    func testPreT27DatabaseWithNoTableOpensAndAdmitsFreshResume() async throws {
        let fixture = try ReplayFixture()
        let database = try fixture.database()
        XCTAssertFalse(try database.tableNames().contains(WorkspaceDatabase.ownerReplayTable))
        let state = try database.loadReconstructionState(workspaceID: fixture.workspaceID)
        XCTAssertNil(state.replayRecords)
        let owner = ReconstructionDatabaseOwner(database: database)
        let first = try await fixture.begin(owner: owner, request: fixture.request(revision: 1), model: fixture.model())
        XCTAssertFalse(first.isReplay)
        XCTAssertNil(first.record.latestObservation)
        await owner.revoke()
    }

    func testOwnerTablesPreserveIntegrityAndFailClosedOnCorruptReply() throws {
        let fixture = try ReplayFixture()
        let database = try fixture.database()
        let identity = try fixture.identity(request: fixture.request(revision: 1), model: fixture.model())
        let marker = ReconstructionReplayRecord(schemaVersion: 1, identity: identity,
            dispatches: [.init(requestID: UUID(), processSessionID: UUID(), dispatchedAt: Date(),
                previousRequestOutcomeUnknown: nil)], freshReply: nil, latestObservation: nil, replayCount: 0)
        try database.publishOwnerReplayRecord(workspaceID: fixture.workspaceID, record: marker, expected: nil)
        try database.applySchema()
        XCTAssertEqual(try database.integrityCheck(), ["ok"])
        XCTAssertEqual(try database.ownerReplayRecord(jobID: fixture.job.jobID, key: identity.key), marker)
        try database.execute("UPDATE owner_job_inference_replay SET record_json = X'7b7d';")
        XCTAssertThrowsError(try database.ownerReplayRecord(jobID: fixture.job.jobID, key: identity.key))
    }

    func testPortableActiveRecordsRequireFeatureAndTerminalSavePrunesThem() throws {
        let fixture = try ReplayFixture()
        let identity = try fixture.identity(request: fixture.request(revision: 1), model: fixture.model())
        let marker = ReconstructionReplayRecord(schemaVersion: 1, identity: identity,
            dispatches: [.init(requestID: UUID(), processSessionID: UUID(), dispatchedAt: Date(),
                previousRequestOutcomeUnknown: nil)], freshReply: nil, latestObservation: nil, replayCount: 0)
        let active = try fixture.state.replacingReplayRecords([
            .init(jobID: fixture.job.jobID, payload: ReconstructionCanonicalJSON.encode(marker))])
        let encoded = try ReconstructionPackageCodec.encode(active)
        let decoded = try ReconstructionPackageCodec.decode(descriptor: encoded.descriptor,
            corpusData: encoded.corpusData, evidenceData: encoded.evidenceData, checkpointData: encoded.checkpointData)
        XCTAssertEqual(decoded.replayRecords, active.replayRecords)
        // Frozen pre-T27 canonical checkpoint codec rejects an active extra key honestly.
        let old = try JSONDecoder().decode(PreT27CheckpointManifest.self, from: encoded.checkpointData)
        XCTAssertNotEqual(try ReconstructionCanonicalJSON.encode(old), encoded.checkpointData)
        let terminal = try fixture.terminalState(replayRecords: active.replayRecords)
        let terminalBytes = try ReconstructionPackageCodec.encode(terminal)
        let terminalOld = try JSONDecoder().decode(PreT27CheckpointManifest.self, from: terminalBytes.checkpointData)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(terminalOld), terminalBytes.checkpointData)
        let database = try fixture.database()
        try database.replaceReconstructionState(workspaceID: fixture.workspaceID, state: active)
        XCTAssertEqual(try database.loadReconstructionState(workspaceID: fixture.workspaceID).replayRecords,
            active.replayRecords)
    }

    func testHeadlessPolicyAndBudgetOverrideAreExplicit() {
        XCTAssertFalse(ReconstructionHeadlessHostConfiguration.isRequested(arguments: ["MacScope"],
            environment: ["XCTestConfigurationFilePath": "fixture.xctestconfiguration"]))
        XCTAssertTrue(ReconstructionHeadlessHostConfiguration.isRequested(arguments: ["MacScope", "--run-script"], environment: [:]))
        let overrides = [ReconstructionBudgetPolicy.warmRoundEnvironmentKey: "2",
            ReconstructionBudgetPolicy.coldMultiplierEnvironmentKey: "2", ReconstructionBudgetPolicy.jobEnvironmentKey: "10"]
        XCTAssertEqual(ReconstructionBudgetPolicy.forProcess(arguments: ["MacScope"], environment: overrides), .defaults)
        let host = overrides.merging(["MACSCOPE_HEADLESS_HOST": "1"]) { _, new in new }
        let policy = ReconstructionBudgetPolicy.forProcess(arguments: ["MacScope"], environment: host)
        XCTAssertEqual(policy.roundSeconds(isColdFirstRound: false), 2)
        XCTAssertEqual(policy.roundSeconds(isColdFirstRound: true), 4)
        XCTAssertEqual(policy.jobSeconds, 10)
    }

    func testResumeDoesNotResetDurableJobBudget() async throws {
        let fixture = try ReplayFixture()
        let owner = try fixture.owner()
        let policy = ReconstructionBudgetPolicy(warmRoundSeconds: 2, coldRoundMultiplier: 2, jobSeconds: 10)
        let first = UUID(), second = UUID(), start = Date(timeIntervalSince1970: 1_900_000_000)
        let initial = try await owner.beginExecutionBudget(workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, activationID: first, policy: policy, now: start)
        XCTAssertEqual(initial, 10)
        try await owner.finishExecutionBudget(workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, activationID: first, now: start.addingTimeInterval(4))
        let remaining = try await owner.beginExecutionBudget(workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, activationID: second, policy: policy, now: start.addingTimeInterval(30))
        XCTAssertEqual(remaining, 6)
        try await owner.finishExecutionBudget(workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, activationID: second, now: start.addingTimeInterval(40))
        let exhausted = try await owner.beginExecutionBudget(workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, activationID: UUID(), policy: policy, now: start.addingTimeInterval(50))
        XCTAssertEqual(exhausted, 0)
        await owner.revoke()
    }

    func testOrdinaryUnscopedInferenceNeverAcquiresAReplayJournal() async throws {
        let fixture = try ReplayFixture()
        let model = try fixture.model()
        let result = try await ReconstructionReplaySession.begin(request: fixture.request(revision: 1),
            lease: model.lease, inventory: model.inventory)
        XCTAssertNil(result, "Standalone inference has no product job owner and must take the unchanged path")
    }

    func testOrdinaryAssistantRequestDoesNotUseReconstructionJournalEvenInsideScope() async throws {
        let fixture = try ReplayFixture()
        let owner = try fixture.owner()
        let controller = try await ReconstructionResumeHost.makeController()
        let provider = OrdinaryAssistantReplayFixtureProvider()
        let coordinator = Phase2ReadyInferenceCoordinator(controller: controller, providerFactory: { _ in provider })
        let document = Phase2ReadDocumentIdentity(instanceID: UUID())
        let request = Phase2InferenceRequest(protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
            phase: .finalization, sessionID: UUID(), turnID: UUID(), requestID: UUID(), document: document,
            workspace: .init(document: document, instanceID: UUID()), lifecycleRevision: 1,
            userGoal: "Explain the supplied function.",
            groundedContext: try Phase2GroundedContextCompiler().compile(records: [], currentStateByEvidenceID: [:]),
            toolHandles: [], conversationContext: .init(turns: [], omittedTurnCount: 0), limits: .maximum)
        let scope = ReconstructionReplayScope(owner: owner, workspaceID: fixture.workspaceID,
            jobID: fixture.job.jobID, taskID: fixture.task.identity.taskID, logicalRoundIndex: 0,
            objectiveSHA256: try XCTUnwrap(fixture.request(revision: 1).replayObjective?.sha256), toolRequests: [])
        let result = await ReconstructionReplayScope.$current.withValue(scope) { await coordinator.run(request: request) }
        guard case .finished = result else { return XCTFail("ordinary request failed: \(result)") }
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        let state = try await owner.load(workspaceID: fixture.workspaceID)
        XCTAssertNil(state.replayRecords)
        await owner.revoke()
    }
}

private actor OrdinaryAssistantReplayFixtureProvider: Phase2InferenceProviding {
    private(set) var calls = 0
    func run(request: Phase2InferenceRequest,
             emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void) async throws {
        calls += 1
        let bodies: [Phase2InferenceEventBody] = [
            .finalCandidate(.init(kind: .insufficientEvidence, text: "No supplied evidence.", evidenceIDs: [])),
            .usage(Phase2ProviderUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2)!), .completed]
        for (index, body) in bodies.enumerated() {
            try await emit(.init(protocolVersion: request.protocolVersion, phase: request.phase,
                sessionID: request.sessionID, turnID: request.turnID, requestID: request.requestID,
                document: request.document, workspace: request.workspace, lifecycleRevision: request.lifecycleRevision,
                sequence: UInt64(index + 1), body: body))
        }
    }
    func cancel(requestID: UUID) async {}
}

/// The real 8c91f2134 checkpoint type had exactly these fields. Its strict decoder decoded this
/// type and compared its canonical re-encoding to input bytes; extra replayRecords fail there.
private struct PreT27CheckpointManifest: Codable {
    let schemaVersion: Int
    let jobs: [ReconstructionJobRecord]
    let tasks: [ReconstructionTaskRecord]
    let checkpoints: [ReconstructionCheckpoint]
}

private struct ReplayFixture {
    let workspaceID = ReconstructionDatabaseTestFixtures.workspaceUUID
    let state: ReconstructionWorkspaceState
    let job: ReconstructionJobRecord
    let task: ReconstructionTaskRecord
    let checkpoint: ReconstructionCheckpoint

    init() throws {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: UUID())
        job = foundation.job
        checkpoint = foundation.checkpoint
        task = .init(identity: try .make(taskID: foundation.task.identity.taskID, jobID: job.jobID,
            kind: .modelRound, subject: foundation.task.identity.subject, dependencyTaskIDs: [],
            operationContractIdentity: ReconstructionProductionTaskContract.modelRound), state: .pending, diagnostic: nil)
        state = try .init(projects: foundation.state.projects, corpusManifests: foundation.state.corpusManifests,
            evidence: [], evidenceRelations: [], evidenceGaps: foundation.state.evidenceGaps,
            jobs: [job], tasks: [task], checkpoints: [checkpoint], toolReceipts: [], modelReceipts: [])
    }

    func database(path: String? = nil) throws -> WorkspaceDatabase {
        let database: WorkspaceDatabase
        if let path { database = try WorkspaceDatabase(path: path) }
        else { database = try WorkspaceDatabase.inMemory() }
        try database.applySchema()
        _ = try database.saveSnapshot(workspaceUUID: workspaceID, workspaceName: "T27 synthetic replay",
            snapshot: .init(binaries: [], analysisBySlot: [:]), now: Date())
        try database.replaceReconstructionState(workspaceID: workspaceID, state: state)
        return database
    }
    func owner() throws -> ReconstructionDatabaseOwner { .init(database: try database()) }

    struct Model { let lease: Phase2ReadyInferenceLease; let inventory: Phase2LocalModelInventory }
    func model(profileID: UUID = UUID(), generation: UInt64 = 1, instanceID: String = "fixture",
               contextLength: Int = 32_768, modelKey: String = "t27-loopback") throws -> Model {
        let descriptor = Phase2LocalModelDescriptor(type: .language, publisher: "Loopback", key: modelKey,
            displayName: "T27 fixture", architecture: nil, quantization: nil, sizeBytesOnDisk: 1,
            parameterCountDescription: nil, maximumContextLength: contextLength, format: nil, capabilities: nil,
            variants: [], providerSelectedVariant: nil,
            loadedInstances: [.init(id: instanceID, configuration: .init(effectiveContextLength: contextLength))])
        let inventory = try Phase2LocalModelInventory(profileID: profileID, generation: generation, models: [descriptor])
        return .init(lease: .init(providerRevision: generation, configuration: try .init(profileID: profileID,
            generation: generation, endpointOrigin: "http://127.0.0.1:8000", model: modelKey,
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000),
            observedModelInventorySHA256: Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory)), inventory: inventory)
    }
    func request(revision: UInt64, context: Data = Data(#"{"records":[]}"#.utf8)) -> ReconstructionAIWorkerRequest {
        let objective = try! ReconstructionRequestObjective(jobID: job.jobID, text: job.objective, sha256: job.objectiveSHA256)
        return .roundR2(.init(protocolVersion: 9, objective: objective, request: .init(protocolVersion: 8,
            jobID: job.jobID, checkpointRevision: revision, roundID: UUID(),
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
            context: .init(canonicalBytes: context, canonicalSHA256: ReconstructionSourceInferenceContract.sha256(context),
                evidenceIDs: []), handles: [.init(handleID: UUID(), operationID: .corpusSummary)])))
    }
    var toolRequests: [ReconstructionToolRequest] {
        [.init(operationID: .corpusSummary, taskID: task.identity.taskID, subject: nil,
            retrievalQuery: nil, offset: 0, maximumRecords: 1, maximumEncodedBytes: 4_096)]
    }
    func identity(request: ReconstructionAIWorkerRequest, model: Model, round: Int = 0) throws -> ReconstructionPromptReplayIdentity {
        try .make(request: request, lease: model.lease, jobID: job.jobID, taskID: task.identity.taskID,
            logicalRoundIndex: round, objectiveSHA256: job.objectiveSHA256, toolRequests: toolRequests,
            selectedModelIdentitySHA256: ReconstructionReplayModelIdentity.stableSelectedModelIdentity(
                lease: model.lease, inventory: model.inventory))
    }
    func begin(owner: ReconstructionDatabaseOwner, request: ReconstructionAIWorkerRequest, model: Model) async throws -> ReconstructionReplaySession {
        let scope = ReconstructionReplayScope(owner: owner, workspaceID: workspaceID, jobID: job.jobID,
            taskID: task.identity.taskID, logicalRoundIndex: 0, objectiveSHA256: job.objectiveSHA256, toolRequests: toolRequests)
        return try await ReconstructionReplayScope.$current.withValue(scope) {
            let result = try await ReconstructionReplaySession.begin(request: request, lease: model.lease, inventory: model.inventory)
            return try XCTUnwrap(result)
        }
    }
    func terminal(request: ReconstructionAIWorkerRequest, requestID: UUID) -> ReconstructionTerminalReceipt {
        .init(requestID: requestID, jobID: job.jobID, checkpointRevision: request.replayCheckpointRevision,
            roundID: request.replayRoundID, status: .completed)
    }
    func candidate(request: ReconstructionAIWorkerRequest) -> ReconstructionReplayCandidate {
        .round(.init(jobID: job.jobID, checkpointRevision: request.replayCheckpointRevision,
            roundID: request.replayRoundID!, selectedHandleIDs: [], disposition: .sufficientEvidence, unresolvedGaps: []))
    }
    func terminalState(replayRecords: [ReconstructionWorkspaceReplayRecord]?,
                       modelReceipt: ReconstructionModelReceipt? = nil) throws -> ReconstructionWorkspaceState {
        let terminalCheckpoint = try ReconstructionCheckpoint.make(checkpointID: UUID(), jobID: job.jobID,
            revision: 1, parentCheckpointID: checkpoint.checkpointID, parentCheckpointSHA256: checkpoint.canonicalSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256, evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: modelReceipt == nil ? [] : [task.identity.taskID],
            failedTaskIDs: modelReceipt == nil ? [task.identity.taskID] : [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: modelReceipt.map { [$0.receiptID] } ?? [], toolReceiptIDs: [],
            coordinatorState: .cancelled, terminalReason: .sanitizing("Fixture cancelled"))
        let terminalJob = try ReconstructionJobRecord(jobID: job.jobID, reconstructionProjectID: job.reconstructionProjectID,
            objective: job.objective, objectiveSHA256: job.objectiveSHA256,
            creationCorpusManifestSHA256: job.creationCorpusManifestSHA256, state: .cancelled,
            currentCheckpointID: terminalCheckpoint.checkpointID, terminalReason: .sanitizing("Fixture cancelled"), budget: job.budget)
        return try .init(projects: state.projects, corpusManifests: state.corpusManifests, evidence: [],
            evidenceRelations: [], evidenceGaps: state.evidenceGaps, jobs: [terminalJob],
            tasks: [.init(identity: task.identity, state: modelReceipt == nil ? .cancelled : .completed, diagnostic: nil)],
            checkpoints: [checkpoint, terminalCheckpoint], toolReceipts: [], modelReceipts: modelReceipt.map { [$0] } ?? [],
            replayRecords: replayRecords)
    }
}

private struct UnusedReplayProvider: ReconstructionInferenceProviding {
    func cancel(requestID: UUID) async {}
    func runRound(requestID: UUID, request: ReconstructionInferenceRoundRequest,
                  emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        XCTFail("A replay must not invoke a fresh provider")
        throw ReconstructionReplayError.invalidScope
    }
    func runFinalSynthesis(requestID: UUID, request: ReconstructionFinalSynthesisRequest,
                          emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        XCTFail("A replay must not invoke a fresh provider")
        throw ReconstructionReplayError.invalidScope
    }
}
