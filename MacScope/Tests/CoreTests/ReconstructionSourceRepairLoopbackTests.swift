import Foundation
import XCTest
@testable import MacScope

/// F1: the scripted-model source repair loop through the production reconstruction job path.
///
/// Everything except inference is the production owner: the signed host's job-session factory,
/// original preparation through the shell broker, corpus import, native decompiler admission,
/// source build/behaviour evaluation, receipt admission, durable commits and physical package
/// Save/reopen. The stand-in inference returns `ReconstructionSourceRepairFixture.broken` for the
/// parentless revision and `.repaired` for its child, so this is an engineering proof of the loop,
/// not model-quality evidence. No MTPLX, network endpoint or installed Release is involved.
@MainActor
final class ReconstructionSourceRepairLoopbackTests: XCTestCase {
    nonisolated static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("GoldenFixtures/reconstruction-c-sample")
    /// The F target: the original C sample built by production original preparation on 2026-10-08,
    /// previously only in the canary vault (33,656 B, two functions `_reconstructed` and `_main`).
    nonisolated static let fixtureBinarySHA256 = "e4aaf1e887ae299011a9b1611a29aebd5bd48054c1d0c6d7145230dd89263ff0"

    func testCheckedInCSampleMatchesProductionOriginalSourceAndHarness() throws {
        let binary = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("original-arm64"))
        XCTAssertEqual(binary.count, 33_656)
        XCTAssertEqual(ReconstructionSourceInferenceContract.sha256(binary), Self.fixtureBinarySHA256)
        let loaded = try MachOBinaryLoader().load(at: Self.fixtureDirectory.appendingPathComponent("original-arm64"))
        XCTAssertFalse(loaded.identityEffectiveByteRanges.isEmpty)
        XCTAssertEqual(loaded.functionStarts.count, 2)
        XCTAssertEqual(try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("candidate.c")),
            ReconstructionSourceOriginalSession.originalSourceUTF8)
        XCTAssertEqual(try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("harness.c")),
            try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().sourceUTF8)
    }

    func testScriptedRepairLoopCompletesThroughProductionJobAndPhysicallyReopens() async throws {
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-recon-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if succeeded && (testRun?.failureCount ?? 1) == 0 { try? FileManager.default.removeItem(at: root) } }
        // The dev-loop host is a Debug build without canonical Release provenance, so the sealed
        // factory refuses it by design. The unsealed seam composes the identical job graph and
        // takes the model producer identity a Release would derive from its provenance.
        XCTAssertNil(ReconstructionProductionComposition.jobSessionFactoryBuilder(
            nativeDecompilerRuntime: .productionShared), "A Debug host must not pass the sealed Release check")
        let builder = ReconstructionProductionComposition.unsealedHostJobSessionFactoryBuilderForTesting(
            nativeDecompilerRuntime: .productionShared,
            modelProducerContext: .init(
                macScopeBuildIdentity: ReconstructionSourceInferenceContract.sha256(Data("f1-loopback-debug-build".utf8)),
                macScopeSourceIdentity: ReconstructionSourceInferenceContract.sha256(Data("f1-loopback-debug-source".utf8)),
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                toolchainIdentity: "17A123"))
        let broker = NSXPCShellBrokerTransport()
        let original = ReconstructionSourceOriginalSession(workflow: .init(transport: broker,
            toolAuthority: try .capture()), stageParent: root)
        let candidate: ReconstructionSourceOriginalSession.ImportCandidate
        do { candidate = try await original.prepare() }
        catch { await original.retire(); await broker.reset(); throw error }
        // Production rebuilds the original each run; the checked-in fixture is the 10-08 build.
        print("RECON_LOOPBACK_ORIGINAL sha256=\(candidate.executable.sha256) bytes=\(candidate.executable.byteCount) fixture=\(Self.fixtureBinarySHA256) identical=\(candidate.executable.sha256 == Self.fixtureBinarySHA256)")

        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let databasePath = root.appendingPathComponent("workspace.sqlite").path
        let (workspaceRowID, owner) = try makeLoopbackDatabaseOwner(path: databasePath,
            workspaceID: workspaceID, attachmentVaultRootURL: root.appendingPathComponent("vault"))
        var liveSession: ReconstructionJobSession?
        func teardown() async {
            await liveSession?.retire()
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await original.retire(); await broker.reset(); await owner.revoke()
        }
        do {
            let imported = await ReconstructionCorpusImporter().ingest(
                selections: [.init(rootURL: candidate.executableURL, roles: [.primaryTarget])],
                projectID: projectID, cancellation: ReconstructionCancellation())
            XCTAssertTrue(imported.failures.isEmpty)
            let occurrence = try XCTUnwrap(imported.occurrences.first { $0.kind == .machOImage })
            XCTAssertEqual(occurrence.contentIdentity.digest, candidate.executable.sha256)
            let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID,
                contentIdentity: occurrence.contentIdentity)
            let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
                artifacts: imported.occurrences, relations: imported.relations,
                canonicalSHA256: imported.canonicalManifestSHA256)
            _ = try await owner.commitCorpus(workspaceID: workspaceID,
                mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                    successorManifest: manifest, attachmentSources: imported.attachmentSources))
            let objective = "Scripted F1 loopback: reconstruct the imported C sample under the fixed profile; one broken revision, one child repair."
            let committed = try await owner.commitInitialJob(workspaceID: workspaceID,
                mutation: .init(jobID: jobID, projectID: projectID,
                    selectedOccurrenceIDs: [occurrence.occurrenceID], objective: objective,
                    budget: try .init(maxRounds: 8, maxTasks: 256, maxEvidenceRecords: 512,
                        maxEncodedBytes: 8_388_608), focus: .artifact(artifact),
                    sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
            try await original.bind(projectID: projectID, jobID: jobID, importedArtifact: artifact)
            try await ReconstructionSourceOriginalSessionRegistry.shared.register(
                workspaceID: workspaceID, jobID: jobID, session: original)

            let inference = try ScriptedRepairInference()
            let store = WorkspaceStore(workspaceName: "Scripted loopback repair",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(),
                autosaveScheduler: nil, workspaceID: workspaceID)
            let session = try await builder(inference)(workspaceID, jobID, owner, store)
            liveSession = session
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                await session.retire()
            }
            defer { watchdog.cancel() }
            let finished = await session.start(authority: ReconstructionJobCommandAuthority(jobID: jobID,
                expectedJobState: .created, checkpointID: committed.checkpoint.checkpointID,
                checkpointRevision: committed.checkpoint.revision,
                corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256))
            let state = try await owner.load(workspaceID: workspaceID)
            try ReconstructionCanonicalJSON.encode(state).write(to: root.appendingPathComponent("durable-state.json"))
            try Data("sources=\(inference.sources.count) rounds=\(inference.rounds.count) finals=\(inference.finals.count) finalResults=\(state.finalResults.count)\n".utf8)
                .write(to: root.appendingPathComponent("calls.txt"))
            print("RECON_LOOPBACK_CALLS sources=\(inference.sources.count) rounds=\(inference.rounds.count) finals=\(inference.finals.count) tasks=\(state.tasks.filter { $0.identity.jobID == jobID }.map { "\($0.identity.kind):\($0.state)" })")
            XCTAssertTrue(finished)
            XCTAssertEqual(state.jobs.first { $0.jobID == jobID }?.state, .completed)

            // Native: both functions of the F target admitted by the native decompiler.
            let nativeTasks = state.tasks.filter { $0.identity.jobID == jobID && $0.identity.kind == .decompileNative }
            XCTAssertEqual(nativeTasks.count, 2)
            XCTAssertTrue(nativeTasks.allSatisfy { $0.state == .completed },
                "native decompile tasks: \(nativeTasks.map(\.state))")
            // Native output is consumed by the per-function decompiler comparison (with MacIR).
            let comparisons = state.tasks.filter { $0.identity.jobID == jobID && $0.identity.kind == .compareDecompilers }
            XCTAssertEqual(comparisons.count, 2)
            XCTAssertTrue(comparisons.allSatisfy { $0.state == .completed })

            // Source: exactly two revisions; the child repairs the failed parent.
            let sourceRecords = state.evidence.filter { $0.creatingJobID == jobID
                && $0.operationID == ReconstructionSourceRevisionEvidence.operationID }
            let evaluationRecords = state.evidence.filter { $0.creatingJobID == jobID
                && $0.operationID == ReconstructionSourceEvaluationEvidence.operationID }
            XCTAssertEqual(sourceRecords.count, 2)
            XCTAssertEqual(evaluationRecords.count, 2)
            XCTAssertEqual(inference.sources.count, 2)
            let revisions = try sourceRecords.map { try JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload) }
            let evaluations = try evaluationRecords.map {
                try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: $0.payload)
            }
            let first = try XCTUnwrap(revisions.first { $0.parentRevisionSHA256 == nil })
            let repaired = try XCTUnwrap(revisions.first { $0.parentRevisionSHA256 == first.revisionSHA256 })
            XCTAssertEqual(first.sourceUTF8, Data(ReconstructionSourceRepairFixture.broken.utf8))
            XCTAssertEqual(repaired.sourceUTF8, Data(ReconstructionSourceRepairFixture.repaired.utf8))
            let failed = try XCTUnwrap(evaluations.first { $0.revisionSHA256 == first.revisionSHA256 })
            let accepted = try XCTUnwrap(evaluations.first { $0.revisionSHA256 == repaired.revisionSHA256 })
            // The production harness's maximum-input case (index 4 of 37) is the fixture's CASE:3.
            XCTAssertEqual(failed.capturedOutcome.status, .behaviorMismatch)
            XCTAssertEqual(failed.capturedOutcome.mismatches,
                [.init(index: 4, input: UInt32.max, expected: UInt32.max, actual: 0)])
            XCTAssertEqual(failed.capturedOutcome.observations.count, 37)
            XCTAssertEqual(accepted.capturedOutcome.status, .accepted)
            XCTAssertEqual(accepted.capturedOutcome.observations.count, 37)
            XCTAssertTrue(accepted.capturedOutcome.mismatches.isEmpty)
            XCTAssertEqual(inference.sources[0].parentRevisionSHA256, nil)
            XCTAssertEqual(inference.sources[1].parentRevisionSHA256, first.revisionSHA256)
            let failedPayload = try ReconstructionSourceEvaluationCodec.encode(failed)
            let failedRecord = try XCTUnwrap(evaluationRecords.first { $0.payload == failedPayload })
            XCTAssertTrue(inference.sources[1].context.evidenceIDs.contains(failedRecord.evidenceID),
                "The repair request must carry the failed evaluation diagnostic")
            // Observed on 2026-10-12: after the accepted repair the ordinary round's sufficientEvidence
            // completes the job without a model final-synthesis frontier. The deterministic final
            // synthesis record (F2c) is derived from the durable state and read by UI and MCP.
            let summary = try XCTUnwrap(ReconstructionJobStatusSummary.make(jobID: jobID, state: state))
            let synthesis = try XCTUnwrap(summary.finalSynthesis, "A completed source job must carry its final synthesis")
            XCTAssertEqual(synthesis.acceptedRevisionSHA256, repaired.revisionSHA256)
            XCTAssertEqual(synthesis.acceptedRevisionEvidenceID, try XCTUnwrap(sourceRecords.first {
                (try? JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload))?.revisionSHA256
                    == repaired.revisionSHA256 }).evidenceID)
            XCTAssertEqual(synthesis.harnessPassed, 37)
            XCTAssertEqual(synthesis.harnessTotal, 37)
            XCTAssertEqual(synthesis.revisionCount, 2)
            XCTAssertEqual(synthesis.evaluationCount, 2)
            XCTAssertEqual(synthesis.profileID, ReconstructionSourceExecutionTaskContract.profileID)
            XCTAssertGreaterThan(synthesis.elapsedMilliseconds, 0)
            // F3: without lifecycle rows (older state) elapsed is the phase sum; with the durable
            // lifecycle columns it is wall-clock finished - started, which covers the phases.
            XCTAssertEqual(synthesis.elapsedSource, .phaseSum)
            XCTAssertEqual(synthesis.elapsedMilliseconds, synthesis.phaseElapsedMilliseconds)
            let lifecycle = try await owner.lifecycle(workspaceID: workspaceID)
            let timed = try XCTUnwrap(ReconstructionJobStatusSummary.make(jobID: jobID, state: state, lifecycle: lifecycle))
            let jobTimes = try XCTUnwrap(timed.lifecycle)
            XCTAssertNotNil(jobTimes.createdAtMilliseconds)
            XCTAssertNotNil(jobTimes.startedAtMilliseconds)
            XCTAssertNotNil(jobTimes.finishedAtMilliseconds)
            XCTAssertEqual(timed.elapsedSource, .wallClock)
            XCTAssertEqual(timed.finalSynthesis?.elapsedSource, .wallClock)
            XCTAssertEqual(timed.finalSynthesis?.elapsedMilliseconds, jobTimes.wallClockElapsedMilliseconds)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(timed.elapsedMilliseconds), synthesis.phaseElapsedMilliseconds)
            print("RECON_LOOPBACK_ELAPSED wallClock=\(timed.elapsedMilliseconds ?? 0) phaseSum=\(synthesis.phaseElapsedMilliseconds)")
            XCTAssertEqual(synthesis.decompileProvenance.count, 4)
            XCTAssertTrue(synthesis.decompileProvenance.allSatisfy { $0.backend == "native" && $0.fallbackReason == nil })
            XCTAssertTrue(summary.failedTasks.isEmpty)
            // The same record through the MCP/scripting job-status read.
            let scripted = try WorkspaceScriptingAPI.reconstructionJobsStatus(
                .object(["job": .string(jobID.uuidString)]), state: state)
            let scriptedJob = try XCTUnwrap(scripted.arrayValue?.first)
            XCTAssertEqual(scriptedJob["state"]?.stringValue, "completed")
            XCTAssertEqual(scriptedJob["finalSynthesis"]?["acceptedRevisionSHA256"]?.stringValue, repaired.revisionSHA256)
            XCTAssertEqual(scriptedJob["finalSynthesis"]?["harnessPassed"]?.stringValue, "37")
            XCTAssertEqual(scriptedJob["finalSynthesis"]?["harnessTotal"]?.stringValue, "37")

            // Save, physically reopen, re-save and cold-open: the accepted revision is byte-identical.
            let sources = try await owner.availableDurableAttachmentSources(workspaceID: workspaceID)
            await session.retire(); liveSession = nil
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await original.retire(); await broker.reset(); await owner.revoke()
            let reopenedDatabase = try WorkspaceDatabase(path: databasePath)
            let coldDatabaseState = try reopenedDatabase.loadReconstructionState(workspaceID: workspaceID)
            XCTAssertEqual(coldDatabaseState, state)
            let components = try reopenedDatabase.packageComponents(workspaceID: workspaceRowID, documentID: UUID(),
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
            let package = root.appendingPathComponent("LoopbackRepair.mscope")
            try MacScopeDocumentPackage.writePackage(components.manifest,
                attachmentsByBinaryID: components.attachmentsByBinaryID, reconstructionState: coldDatabaseState,
                reconstructionAttachmentSources: sources, to: package)
            let reopened = try MacScopeDocumentPackage.openPackage(from: package)
            XCTAssertEqual(reopened.reconstructionState, state)
            let resaved = root.appendingPathComponent("LoopbackResaved.mscope")
            try MacScopeDocumentPackage.writePackage(reopened.manifest,
                attachmentsByBinaryID: reopened.attachmentsByBinaryID,
                reconstructionState: reopened.reconstructionState,
                reconstructionAttachmentSources: reopened.reconstructionAttachmentSources, to: resaved,
                instructionSidecarData: reopened.instructionSidecarData)
            let cold = try MacScopeDocumentPackage.openPackage(from: resaved)
            XCTAssertEqual(cold.reconstructionState, state)
            let acceptedRecord = try XCTUnwrap(sourceRecords.first {
                (try? JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload))?.revisionSHA256
                    == repaired.revisionSHA256 })
            let restored = try XCTUnwrap(cold.reconstructionState.evidence.first { $0.evidenceID == acceptedRecord.evidenceID })
            XCTAssertEqual(restored.payload, acceptedRecord.payload)
            XCTAssertEqual(try JSONDecoder().decode(ReconstructionSourceRevision.self, from: restored.payload).sourceUTF8,
                Data(ReconstructionSourceRepairFixture.repaired.utf8))
            succeeded = true
        } catch {
            print("RECON_LOOPBACK_FAILURE root=\(root.path) error=\(String(reflecting: error))")
            if let state = try? await owner.load(workspaceID: workspaceID),
               let bytes = try? ReconstructionCanonicalJSON.encode(state) {
                try? bytes.write(to: root.appendingPathComponent("failure-durable-state.json"))
            }
            await teardown()
            throw error
        }
    }
}

extension ReconstructionSourceRepairLoopbackTests {
    /// D13: the native decompiler fails closed for the second function (`_main`). Its decompile and
    /// comparison tasks complete on MacIR with backend=macir and the reason; the other function stays
    /// native, and the source job still completes with its final synthesis.
    func testNativeFailClosedOnSecondFunctionFallsBackToMacIRAndJobCompletes() async throws {
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-recon-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if succeeded && (testRun?.failureCount ?? 1) == 0 { try? FileManager.default.removeItem(at: root) } }
        let recorder = FailClosedRecorder()
        let builder = ReconstructionProductionComposition.unsealedHostJobSessionFactoryBuilderForTesting(
            nativeDecompilerRuntime: .productionShared,
            modelProducerContext: .init(
                macScopeBuildIdentity: ReconstructionSourceInferenceContract.sha256(Data("f2-fallback-debug-build".utf8)),
                macScopeSourceIdentity: ReconstructionSourceInferenceContract.sha256(Data("f2-fallback-debug-source".utf8)),
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                toolchainIdentity: "17A123"),
            nativeTaskDecompiler: { [recorder] in FailClosedForMainNativeDecompiler(inner: $0, recorder: recorder) })
        let broker = NSXPCShellBrokerTransport()
        let original = ReconstructionSourceOriginalSession(workflow: .init(transport: broker,
            toolAuthority: try .capture()), stageParent: root)
        let candidate: ReconstructionSourceOriginalSession.ImportCandidate
        do { candidate = try await original.prepare() }
        catch { await original.retire(); await broker.reset(); throw error }

        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let (_, owner) = try makeFallbackDatabaseOwner(path: root.appendingPathComponent("workspace.sqlite").path,
            workspaceID: workspaceID, attachmentVaultRootURL: root.appendingPathComponent("vault"))
        var liveSession: ReconstructionJobSession?
        func teardown() async {
            await liveSession?.retire()
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await original.retire(); await broker.reset(); await owner.revoke()
        }
        do {
            let imported = await ReconstructionCorpusImporter().ingest(
                selections: [.init(rootURL: candidate.executableURL, roles: [.primaryTarget])],
                projectID: projectID, cancellation: ReconstructionCancellation())
            let occurrence = try XCTUnwrap(imported.occurrences.first { $0.kind == .machOImage })
            let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID,
                contentIdentity: occurrence.contentIdentity)
            let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
                artifacts: imported.occurrences, relations: imported.relations,
                canonicalSHA256: imported.canonicalManifestSHA256)
            _ = try await owner.commitCorpus(workspaceID: workspaceID,
                mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                    successorManifest: manifest, attachmentSources: imported.attachmentSources))
            let committed = try await owner.commitInitialJob(workspaceID: workspaceID,
                mutation: .init(jobID: jobID, projectID: projectID,
                    selectedOccurrenceIDs: [occurrence.occurrenceID],
                    objective: "Scripted F2 fallback: native fails closed for _main; MacIR stands in.",
                    budget: try .init(maxRounds: 8, maxTasks: 256, maxEvidenceRecords: 512,
                        maxEncodedBytes: 8_388_608), focus: .artifact(artifact),
                    sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
            try await original.bind(projectID: projectID, jobID: jobID, importedArtifact: artifact)
            try await ReconstructionSourceOriginalSessionRegistry.shared.register(
                workspaceID: workspaceID, jobID: jobID, session: original)
            let inference = try ScriptedRepairInference()
            let store = WorkspaceStore(workspaceName: "Scripted fallback",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(),
                autosaveScheduler: nil, workspaceID: workspaceID)
            let session = try await builder(inference)(workspaceID, jobID, owner, store)
            liveSession = session
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                await session.retire()
            }
            defer { watchdog.cancel() }
            let finished = await session.start(authority: ReconstructionJobCommandAuthority(jobID: jobID,
                expectedJobState: .created, checkpointID: committed.checkpoint.checkpointID,
                checkpointRevision: committed.checkpoint.revision,
                corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256))
            let state = try await owner.load(workspaceID: workspaceID)
            try ReconstructionCanonicalJSON.encode(state).write(to: root.appendingPathComponent("durable-state.json"))
            let summary = try XCTUnwrap(ReconstructionJobStatusSummary.make(jobID: jobID, state: state))
            print("RECON_FALLBACK state=\(summary.state) reason=\(summary.terminalReason ?? "-") provenance=\(summary.decompileProvenance.map { "\($0.kind):\($0.symbol ?? "?"):\($0.backend):\($0.fallbackReason ?? "-")" })")
            XCTAssertTrue(finished)
            XCTAssertEqual(state.jobs.first { $0.jobID == jobID }?.state, .completed)
            let decompileTasks = state.tasks.filter { $0.identity.jobID == jobID
                && [.decompileNative, .compareDecompilers].contains($0.identity.kind) }
            XCTAssertEqual(decompileTasks.count, 4)
            XCTAssertTrue(decompileTasks.allSatisfy { $0.state == .completed })
            let failedAddresses = await recorder.failedAddresses
            XCTAssertEqual(failedAddresses.count, 1, "exactly one function (_main) fails closed")
            func address(_ task: ReconstructionTaskRecord) -> UInt64? {
                if case .function(let function)? = task.identity.subject { return function.startAddress }
                return nil
            }
            let mainTasks = decompileTasks.filter { address($0).map(failedAddresses.contains) == true }
            let otherTasks = decompileTasks.filter { address($0).map(failedAddresses.contains) != true }
            XCTAssertEqual(mainTasks.count, 2)
            XCTAssertEqual(otherTasks.count, 2)
            XCTAssertTrue(mainTasks.allSatisfy {
                $0.decompileBackend == .init(backend: "macir", fallbackReason: "native-failed: providerUnavailable")
            }, "\(mainTasks.map(\.decompileBackend))")
            XCTAssertTrue(otherTasks.allSatisfy { $0.decompileBackend == .nativeBackend }, "\(otherTasks.map(\.decompileBackend))")
            let synthesis = try XCTUnwrap(summary.finalSynthesis)
            XCTAssertEqual(synthesis.harnessPassed, 37)
            XCTAssertEqual(synthesis.decompileProvenance.filter { $0.backend == "macir" }.count, 2)
            XCTAssertEqual(synthesis.decompileProvenance.filter { $0.backend == "native" }.count, 2)
            await teardown()
            succeeded = true
        } catch {
            print("RECON_FALLBACK_FAILURE root=\(root.path) error=\(String(reflecting: error))")
            if let state = try? await owner.load(workspaceID: workspaceID),
               let bytes = try? ReconstructionCanonicalJSON.encode(state) {
                try? bytes.write(to: root.appendingPathComponent("failure-durable-state.json"))
            }
            await teardown()
            throw error
        }
    }
}

extension ReconstructionSourceRepairLoopbackTests {
    /// F3 job-level failure: the stand-in model proposes a revision that does not compile, the real
    /// broker runs clang on it, and the injected transport withholds the broker's process-absence
    /// confirmation for that failed phase (as if cleanup of the compiler process could not be
    /// observed). The failure is then not a recordable evaluation, the source task fails, and the
    /// job's terminal reason carries the concrete failure: phase, broker status/terminal/cleanup and
    /// the clang diagnostics excerpt. `reconstruction-jobs` reports it through scripting and MCP,
    /// with the durable wall-clock lifecycle.
    func testUncompilableRevisionFailsSourceTaskAndJobReasonCarriesConcreteFailure() async throws {
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-recon-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if succeeded && (testRun?.failureCount ?? 1) == 0 { try? FileManager.default.removeItem(at: root) } }
        let injected = CleanupUnconfirmedRecorder()
        let builder = ReconstructionProductionComposition.unsealedHostJobSessionFactoryBuilderForTesting(
            nativeDecompilerRuntime: .productionShared,
            modelProducerContext: .init(
                macScopeBuildIdentity: ReconstructionSourceInferenceContract.sha256(Data("f3-failure-debug-build".utf8)),
                macScopeSourceIdentity: ReconstructionSourceInferenceContract.sha256(Data("f3-failure-debug-source".utf8)),
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                toolchainIdentity: "17A123"),
            sourceTransport: { CleanupUnconfirmingSourceTransport(inner: $0, recorder: injected) })
        let broker = NSXPCShellBrokerTransport()
        let original = ReconstructionSourceOriginalSession(workflow: .init(transport: broker,
            toolAuthority: try .capture()), stageParent: root)
        let candidate: ReconstructionSourceOriginalSession.ImportCandidate
        do { candidate = try await original.prepare() }
        catch { await original.retire(); await broker.reset(); throw error }

        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let (_, owner) = try makeLoopbackDatabaseOwner(path: root.appendingPathComponent("workspace.sqlite").path,
            workspaceID: workspaceID, attachmentVaultRootURL: root.appendingPathComponent("vault"))
        var liveSession: ReconstructionJobSession?
        func teardown() async {
            await liveSession?.retire()
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await original.retire(); await broker.reset(); await owner.revoke()
        }
        do {
            let imported = await ReconstructionCorpusImporter().ingest(
                selections: [.init(rootURL: candidate.executableURL, roles: [.primaryTarget])],
                projectID: projectID, cancellation: ReconstructionCancellation())
            let occurrence = try XCTUnwrap(imported.occurrences.first { $0.kind == .machOImage })
            let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID,
                contentIdentity: occurrence.contentIdentity)
            let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
                artifacts: imported.occurrences, relations: imported.relations,
                canonicalSHA256: imported.canonicalManifestSHA256)
            _ = try await owner.commitCorpus(workspaceID: workspaceID,
                mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                    successorManifest: manifest, attachmentSources: imported.attachmentSources))
            let committed = try await owner.commitInitialJob(workspaceID: workspaceID,
                mutation: .init(jobID: jobID, projectID: projectID,
                    selectedOccurrenceIDs: [occurrence.occurrenceID],
                    objective: "Scripted F3 failure: the only revision does not compile and its failed phase cannot be recorded.",
                    budget: try .init(maxRounds: 8, maxTasks: 256, maxEvidenceRecords: 512,
                        maxEncodedBytes: 8_388_608), focus: .artifact(artifact),
                    sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
            try await original.bind(projectID: projectID, jobID: jobID, importedArtifact: artifact)
            try await ReconstructionSourceOriginalSessionRegistry.shared.register(
                workspaceID: workspaceID, jobID: jobID, session: original)
            let inference = try ScriptedRepairInference(fixedSource: Self.uncompilableSource)
            let store = WorkspaceStore(workspaceName: "Scripted failure",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(),
                autosaveScheduler: nil, workspaceID: workspaceID)
            let session = try await builder(inference)(workspaceID, jobID, owner, store)
            liveSession = session
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                await session.retire()
            }
            defer { watchdog.cancel() }
            _ = await session.start(authority: ReconstructionJobCommandAuthority(jobID: jobID,
                expectedJobState: .created, checkpointID: committed.checkpoint.checkpointID,
                checkpointRevision: committed.checkpoint.revision,
                corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256))
            let state = try await owner.load(workspaceID: workspaceID)
            let lifecycle = try await owner.lifecycle(workspaceID: workspaceID)
            try ReconstructionCanonicalJSON.encode(state).write(to: root.appendingPathComponent("durable-state.json"))
            let job = try XCTUnwrap(state.jobs.first { $0.jobID == jobID })
            let reason = job.terminalReason?.text ?? ""
            let injectedOperations = await injected.operations
            print("RECON_FAILURE state=\(job.state) injected=\(injectedOperations) sources=\(inference.sources.count) reason=\(reason)")
            XCTAssertEqual(job.state, .failed)
            XCTAssertEqual(inference.sources.count, 1, "one proposal, no successful repair")
            XCTAssertEqual(injectedOperations.count, 1, "exactly one failed revision phase lost its cleanup confirmation")
            let phase = try XCTUnwrap(injectedOperations.first)
            // Concrete terminal reason: the failing task kind, the phase, the broker's own status,
            // terminal and unconfirmed cleanup, and the compiler's diagnostics excerpt.
            XCTAssertTrue(reason.hasPrefix("A deterministic reconstruction task failed (executeSource): "), reason)
            XCTAssertTrue(reason.contains("\(phase) phase rejected"), reason)
            XCTAssertTrue(reason.contains("phase=\(phase)"), reason)
            XCTAssertTrue(reason.contains("terminal=exited("), reason)
            XCTAssertTrue(reason.contains("cleanup="), reason)
            XCTAssertTrue(reason.contains("diagnostics: "), reason)
            XCTAssertTrue(reason.contains("error"), "the clang diagnostic must reach the reason: \(reason)")
            let failedTasks = state.tasks.filter { $0.identity.jobID == jobID && $0.state == .failed }
            XCTAssertEqual(failedTasks.map(\.identity.kind), [.executeSource])
            let taskDiagnostic = try XCTUnwrap(failedTasks.first?.diagnostic?.text)
            XCTAssertTrue(reason.hasSuffix(taskDiagnostic), "job reason = task diagnostic: \(taskDiagnostic)")

            // reconstruction-jobs: summary, scripting function and MCP transport agree.
            let summary = try XCTUnwrap(ReconstructionJobStatusSummary.make(jobID: jobID, state: state, lifecycle: lifecycle))
            XCTAssertEqual(summary.state, "failed")
            XCTAssertEqual(summary.terminalReason, reason)
            XCTAssertEqual(summary.failedTasks.map(\.kind), ["executeSource"])
            XCTAssertEqual(summary.failedTasks.first?.diagnostic, taskDiagnostic)
            XCTAssertNotNil(summary.failedTasks.first?.lifecycle?.finishedAtMilliseconds)
            XCTAssertNil(summary.finalSynthesis)
            let jobTimes = try XCTUnwrap(summary.lifecycle)
            XCTAssertNotNil(jobTimes.startedAtMilliseconds)
            XCTAssertNotNil(jobTimes.finishedAtMilliseconds)
            XCTAssertEqual(summary.elapsedSource, .wallClock)
            XCTAssertEqual(summary.elapsedMilliseconds, jobTimes.wallClockElapsedMilliseconds)
            let mcpStore = WorkspaceStore(workspaceName: "Scripted failure MCP",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(),
                autosaveScheduler: nil, workspaceID: workspaceID)
            var publication = ReconstructionCommittedCorpus(state: state, attachmentSources: [])
            publication.lifecycle = lifecycle
            mcpStore.publishCommittedReconstructionCorpus(publication)
            let server = MCPServer(api: WorkspaceScriptingAPI(store: mcpStore))
            let request = ScriptValue.object(["jsonrpc": .string("2.0"), "id": .int(7), "method": .string("tools/call"),
                "params": .object(["name": .string("reconstruction-jobs"),
                    "arguments": .object(["job": .string(jobID.uuidString)])])])
            let responseData = await server.handleMessageAsync(try request.jsonData())
            let envelope = try ScriptValue.decode(try XCTUnwrap(responseData))
            XCTAssertNil(envelope["error"])
            let text = try XCTUnwrap(envelope["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            let reported = try XCTUnwrap(try ScriptValue.decode(Data(text.utf8)).arrayValue?.first)
            XCTAssertEqual(reported["state"]?.stringValue, "failed")
            XCTAssertEqual(reported["terminalReason"]?.stringValue, reason)
            XCTAssertEqual(reported["failedTasks"]?.arrayValue?.first?["diagnostic"]?.stringValue, taskDiagnostic)
            XCTAssertEqual(reported["elapsedSource"]?.stringValue, "wall-clock")
            XCTAssertEqual(reported["elapsedMilliseconds"]?.stringValue, summary.elapsedMilliseconds.map(String.init))
            XCTAssertEqual(ScriptValue.array([reported]), try WorkspaceScriptingAPI.reconstructionJobsStatus(
                .object(["job": .string(jobID.uuidString)]), state: state, lifecycle: lifecycle))
            await teardown()
            succeeded = true
        } catch {
            print("RECON_FAILURE_FAILURE root=\(root.path) error=\(String(reflecting: error))")
            if let state = try? await owner.load(workspaceID: workspaceID),
               let bytes = try? ReconstructionCanonicalJSON.encode(state) {
                try? bytes.write(to: root.appendingPathComponent("failure-durable-state.json"))
            }
            await teardown()
            throw error
        }
    }

    nonisolated static let uncompilableSource = "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x + ; }\n"
}

private actor CleanupUnconfirmedRecorder {
    private(set) var operations: [String] = []
    func record(_ operation: String) { operations.append(operation) }
}

/// Production broker for every request, except that a *failed* admitted-revision phase (nonzero
/// exit or broker failure) comes back with `observedProcessAbsent = false`: the broker could not
/// confirm the compiler process exited. Everything else in the response (status, terminal,
/// diagnostics) is the real broker's.
private actor CleanupUnconfirmingSourceTransport: MacScope.ShellBrokerXPCTransport {
    let inner: any MacScope.ShellBrokerXPCTransport
    let recorder: CleanupUnconfirmedRecorder
    init(inner: any MacScope.ShellBrokerXPCTransport, recorder: CleanupUnconfirmedRecorder) {
        self.inner = inner; self.recorder = recorder
    }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { try await inner.handshake() }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        try await inner.perform(request)
    }
    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        try await inner.prepareBrokerProcessReceipt()
    }
    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool {
        await inner.revalidateBrokerProcessReceipt(receipt)
    }
    func reset() async { await inner.reset() }
    func executeSource(_ request: MacScope.Phase2SourceExecutionRequest) async throws -> MacScope.Phase2SourceExecutionResponse {
        let response = try await inner.executeSource(request)
        guard request.sourceAuthority == .admittedRevision, response.status == .completed,
              let cleanup = response.cleanup,
              response.failure != nil || response.terminal != .init(kind: .exited, status: 0) else { return response }
        await recorder.record(request.operation.rawValue)
        return .init(requestID: response.requestID, sessionID: response.sessionID, operation: response.operation,
            status: response.status, failure: response.failure, terminal: response.terminal,
            diagnostics: response.diagnostics, peakGroupResidentBytes: response.peakGroupResidentBytes,
            sampledProcessIDs: response.sampledProcessIDs, elapsedSeconds: response.elapsedSeconds,
            cleanup: .init(sessionID: cleanup.sessionID, requestID: cleanup.requestID,
                processIdentifier: cleanup.processIdentifier, observedProcessAbsent: false, outcome: cleanup.outcome))
    }
}

/// Forces a native fail-closed (`providerUnavailable`) for `_main`; every other request reaches
/// the admitted production native adapter unchanged.
private actor FailClosedRecorder {
    private(set) var failedAddresses: Set<UInt64> = []
    func record(_ address: UInt64) { failedAddresses.insert(address) }
}

private actor FailClosedForMainNativeDecompiler: ReconstructionNativeTaskDecompiling {
    let inner: any ReconstructionNativeTaskDecompiling
    let recorder: FailClosedRecorder
    init(inner: any ReconstructionNativeTaskDecompiling, recorder: FailClosedRecorder) {
        self.inner = inner; self.recorder = recorder
    }
    func decompile(_ request: ReconstructionNativeDecompilationRequest,
        cancellation: ReconstructionCancellation) async -> ReconstructionNativeTaskResult {
        // Function coordinates carry no symbol hint; the projected analysis names the function.
        let name = request.projection.workspace.analysis(in: request.projection.imageSlot)?
            .functions.first { $0.id == request.projection.functionID }?.name
        if name == "_main" || name == "main" {
            await recorder.record(request.subject.startAddress)
            return .failed(.providerUnavailable)
        }
        return await inner.decompile(request, cancellation: cancellation)
    }
    func cancelOutstanding() async { await inner.cancelOutstanding() }
    func retire() async { await inner.retire() }
}

@MainActor
private func makeFallbackDatabaseOwner(path: String, workspaceID: UUID,
    attachmentVaultRootURL: URL) throws -> (Int64, ReconstructionDatabaseOwner) {
    try makeLoopbackDatabaseOwner(path: path, workspaceID: workspaceID, attachmentVaultRootURL: attachmentVaultRootURL)
}

/// Stand-in model: fixed fixture candidates, no tool selection, one cited synthesis. It cannot
/// choose oracle inputs, commands or acceptance; those remain with the production owners.
@MainActor
private final class ScriptedRepairInference: ReconstructionReadyInferenceCoordinating {
    private(set) var sources: [ReconstructionSourceRevisionRequest] = []
    private(set) var rounds: [ReconstructionInferenceRoundRequest] = []
    private(set) var finals: [ReconstructionFinalSynthesisRequest] = []
    let lease: Phase2ReadyInferenceLease
    /// F3: when set, every proposal is this text (no repair); otherwise broken, then repaired.
    let fixedSource: String?

    init(fixedSource: String? = nil) throws {
        self.fixedSource = fixedSource
        lease = .init(providerRevision: 1, configuration: try .init(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: "scripted-loopback-repair-fixture",
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000),
            observedModelInventorySHA256: ReconstructionSourceInferenceContract.sha256(Data("scripted-loopback-inventory".utf8)))
    }

    func proposeSourceRevision(request: ReconstructionSourceRevisionRequest)
        async -> ReconstructionReadySourceRevisionExecutionResult {
        guard sources.count < 2 else { return .invalidRequest }
        let text = fixedSource ?? (request.parentRevisionSHA256 == nil
            ? ReconstructionSourceRepairFixture.broken : ReconstructionSourceRepairFixture.repaired)
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: request.jobID,
            checkpointRevision: request.checkpointRevision, roundID: request.roundID, status: .completed)
        do {
            let authority = try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: terminal.requestID, request: .sourceRevision(request), terminalReceipt: terminal)
            sources.append(request)
            return .finished(lease: lease, requestAuthority: authority,
                outcome: .init(candidate: .init(profileID: request.profileID,
                    parentRevisionSHA256: request.parentRevisionSHA256, sourceText: text,
                    evidenceIDs: Array(request.context.evidenceIDs.prefix(64))),
                    usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal))
        } catch { return .invalidRequest }
    }

    func run(request: ReconstructionInferenceRoundRequest) async -> ReconstructionReadyInferenceExecutionResult { .invalidRequest }
    func synthesize(request: ReconstructionFinalSynthesisRequest) async -> ReconstructionReadyFinalSynthesisExecutionResult { .invalidRequest }

    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult {
        guard let objective, rounds.count < 8 else { return .invalidRequest }
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: request.jobID,
            checkpointRevision: request.checkpointRevision, roundID: request.roundID, status: .completed)
        do {
            let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: terminal.requestID,
                request: .roundR2(.init(protocolVersion: 9, objective: objective, request: request)), terminalReceipt: terminal)
            rounds.append(request)
            return .finished(lease: lease, requestAuthority: authority,
                outcome: .init(candidate: .init(jobID: request.jobID, checkpointRevision: request.checkpointRevision,
                    roundID: request.roundID, selectedHandleIDs: [], disposition: .sufficientEvidence, unresolvedGaps: []),
                    usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal))
        } catch { return .invalidRequest }
    }

    func synthesize(request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        guard let objective, finals.isEmpty else { return .invalidRequest }
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: request.jobID,
            checkpointRevision: request.checkpointRevision, roundID: nil, status: .completed)
        do {
            let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: terminal.requestID,
                request: .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: request)),
                terminalReceipt: terminal)
            finals.append(request)
            return .finished(lease: lease, requestAuthority: authority,
                outcome: .init(candidate: .init(kind: .synthesis,
                    text: "The broken wrapping revision failed the maximum-input case; its child repair saturates and matches the captured original.",
                    evidenceIDs: ReconstructionValidation.sortedUUIDs(request.acceptedEvidenceIDs)),
                    usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal))
        } catch { return .invalidRequest }
    }
}

/// Transfers the fresh SQLite connection to its actor owner exactly once.
@MainActor
private func makeLoopbackDatabaseOwner(path: String, workspaceID: UUID,
    attachmentVaultRootURL: URL) throws -> (Int64, ReconstructionDatabaseOwner) {
    let database = try WorkspaceDatabase(path: path)
    try database.applySchema()
    let workspace = try database.saveSnapshot(workspaceUUID: workspaceID,
        workspaceName: "Scripted loopback repair",
        snapshot: .init(binaries: [], analysisBySlot: [:]), now: Date())
    let workspaceRowID = try XCTUnwrap(workspace.id)
    return (workspaceRowID, ReconstructionDatabaseOwner(database: database,
        attachmentVaultRootURL: attachmentVaultRootURL))
}
