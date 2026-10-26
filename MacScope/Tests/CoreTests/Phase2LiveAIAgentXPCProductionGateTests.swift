import CryptoKit
import Darwin
import Foundation
import Security
import XCTest

@testable import MacScope

/// Signed embedded-XPC acceptance for the complete two-phase production loopback seam.
/// The fixture is a literal-loopback, test-owned process that accepts exactly two requests.
/// Its R2 mode additionally captures the complete dispatched bodies for readable-evidence proof.
final class Phase2LiveAIAgentXPCProductionGateTests: XCTestCase {
    /// The controlled model-authored defect then repair, fixed before objective identity is minted.
    static let controlledSourceRepairObjective = "Controlled source-repair experiment. Reconstruct the imported C sample using the supplied fixed profile and captured original. In a source revision request with no parentRevisionSHA256, deliberately propose unsigned wrapping increment, including wrap to zero at the maximum unsigned 32-bit input. This first proposal is an intentional diagnostic probe and must not be represented as accepted behavior. In a source revision request with a parentRevisionSHA256, read the actual prior evaluation diagnostic and repair the source to match the captured original, including saturation at the maximum input. Name exactly the supplied failed parent revision hash and cite supplied evidence. Do not change the oracle, profile or target. Once the repaired source has accepted evaluation, request no further tools or revisions, choose sufficientEvidence when asked for an ordinary round, and synthesize the observed mismatch and repair with evidence citations."

    /// Ordinary signed host only: no inference or live-test lifecycle controls.
    func testOptInOrdinaryNativeAdmissionForCapturedInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACSCOPE_RUN_ORDINARY_NATIVE_ADMISSION"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_ORDINARY_NATIVE_ADMISSION=1 for ordinary native admission diagnostics")
        }
        // Default: the checked-in reconstruction F target (the C sample), so no canary vault is load-bearing.
        let inputURL = environment["MACSCOPE_ORDINARY_NATIVE_INPUT"].map { URL(fileURLWithPath: $0) }
            ?? ReconstructionSourceRepairLoopbackTests.fixtureDirectory.appendingPathComponent("original-arm64")
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-ordinary-native-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var records: [[String: String]] = [["stage": "identity",
            "hostBundle": Bundle.main.bundleURL.path, "input": inputURL.path]]
        func record(_ value: [String: String]) throws {
            records.append(value)
            try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(
                to: root.appendingPathComponent("diagnostics.json"), options: .atomic)
        }
        print("ORDINARY_NATIVE_DIAGNOSTIC root=\(root.path) host=\(Bundle.main.bundleURL.path)")
        do {
            let identity = try await NativeDecompilerBundleRuntimeAuthorityProvider().attestRuntimeAuthority()
            try record(["stage": "hostAttestation", "status": "passed", "backend": identity.backendID,
                "packageTreeSHA256": identity.packageTreeSHA256])
            let size = try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size > 0, size <= 1_048_576 else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            let loaded = try MachOBinaryLoader().load(at: inputURL)
            try record(["stage": "loader", "status": "passed",
                "inputSHA256": signedDigest(loaded.bytes),
                "attestationCount": String(loaded.identityEffectiveByteRanges.count),
                "functionStartCount": String(loaded.functionStarts.count)])
            XCTAssertFalse(loaded.identityEffectiveByteRanges.isEmpty, "Actual loader authority is required")
            // Use the ordinary product analysis provider, preserving its real worker transfer.
            let provider = XPCAnalysisProvider(transport: NSXPCConnectionTransport(), codec: PayloadWireCodec())
            defer { provider.resetConnection() }
            let analysisTask = Task { try await provider.openBinary(url: inputURL,
                requestedSliceIndex: nil, overrides: [:], cancellation: .never) }
            let analysisWatchdog = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                analysisTask.cancel()
            }
            let workspace: WorkspaceSnapshot
            do { workspace = try await analysisTask.value }
            catch { analysisWatchdog.cancel(); throw error }
            analysisWatchdog.cancel()
            let binary = try XCTUnwrap(workspace.binaries.first)
            let analysis = try XCTUnwrap(workspace.analysis(in: binary.slot))
            try record(["stage": "analysis", "status": "passed",
                "attestationCount": String(analysis.identityEffectiveByteRanges.count),
                "functionCount": String(analysis.functions.count)])
            XCTAssertEqual(analysis.identityEffectiveByteRanges, loaded.identityEffectiveByteRanges)
            guard !analysis.functions.isEmpty, analysis.functions.count <= 8,
                  let fingerprint = analysis.analysisInputFingerprint else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            let runtime = NativeDecompilerRuntimeRegistry.productionShared
            let owner = UUID()
            for function in analysis.functions.sorted(by: { $0.startAddress < $1.startAddress }) {
                do {
                    let projection = try NativeDecompilerSnapshotBuilder.build(from: workspace,
                        imageSlot: binary.slot, functionID: function.id,
                        budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
                    try record(["stage": "projection", "status": "passed", "function": function.name,
                        "start": String(function.startAddress),
                        "requestSHA256": try NativeDecompilerRequestProjection(snapshotProjection: projection).requestSHA256])
                    let request = try NativeDecompilerProjectionRequest(workspace: workspace,
                        imageSlot: binary.slot, functionID: function.id,
                        analysisInputFingerprintSHA256: fingerprint.overallSHA256)
                    let task = Task { try await runtime.decompileForReconstruction(owner: owner,
                        request: request, cacheLookupPolicy: .allowValidatedCache) }
                    let watchdog = Task {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        task.cancel()
                    }
                    do {
                        let execution = try await task.value
                        watchdog.cancel()
                        // Output-size diagnostics: the budgeted estimate (model v3), the
                        // pre-v2 per-occurrence estimate, and two actual encodings of the
                        // admitted result (compact JSON as the validated cache stores it,
                        // and a binary property list as the reply carries it).
                        let result = execution.success.result
                        let plistEncoder = PropertyListEncoder()
                        plistEncoder.outputFormat = .binary
                        let stores = result.operations.filter { $0.opcode == .store }.count
                        if let expectedStores = ["_ay_c000ffef": 256, "_ay_c040ffef": 128,
                            "_ay_c080ffef": 64, "_ay_c0c0ffef": 32][function.name] {
                            XCTAssertEqual(stores, expectedStores, "Every original MOVA store must survive bounded presentation")
                        }
                        try record(["stage": "nativeAdmission", "status": "passed", "function": function.name,
                            "requestSHA256": execution.requestSHA256,
                            "instructions": String(result.instructions.count),
                            "operations": String(result.operations.count),
                            "stores": String(stores),
                            "warnings": result.warnings.map(\.code).joined(separator: ","),
                            "documentComplete": String(result.pseudocodeDocument?.isComplete ?? false),
                            "documentTruncated": String(result.pseudocodeDocument?.isTruncated ?? false),
                            "blocks": String(result.blocks.count),
                            "tokens": String(result.tokens.count),
                            "estimatedBytesV3": String(
                                NativeDecompilerWireSemanticValidator.estimatedStructuredResultBytes(result)),
                            "estimatedBytesLegacyV1": String(
                                NativeDecompilerWireSemanticValidator.estimatedStructuredResultBytes(
                                    result, legacyV1TextModel: true)),
                            "jsonBytes": String((try? JSONEncoder().encode(result).count) ?? -1),
                            "binaryPlistBytes": String((try? plistEncoder.encode(result).count) ?? -1)])
                    } catch { watchdog.cancel(); throw error }
                } catch {
                    try record(["stage": "functionFailure", "function": function.name,
                        "error": String(reflecting: error)])
                    XCTFail("Ordinary native function \(function.name) failed: \(String(reflecting: error)); artifact=\(root.path)")
                }
            }
            let snapshot = await runtime.processRuntimeSnapshotForTesting()
            try record(["stage": "runtime", "authority": String(describing: snapshot.authorityState),
                "admissionCount": String(snapshot.admissionRecords.count)])
            for observation in await runtime.observationSnapshot() {
                try record(["stage": "nativeObservation", "status": String(describing: observation.status),
                    "requestID": observation.requestID?.uuidString ?? "none",
                    "functionID": observation.function.functionID])
            }
        } catch {
            try? record(["stage": "failure", "error": String(reflecting: error)])
            XCTFail("Ordinary native admission failed: \(String(reflecting: error)); artifact=\(root.path)")
            throw error
        }
    }

    /// Actual model authors the controlled defect and its diagnostic-informed repair. The fixed
    /// objective is committed before hashing; every inference request is forwarded unchanged.
    @MainActor
    func testOptInMTPLXControlledModelAuthoredMismatchRepairPhysicallyReopens() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_SOURCE_REPAIR_CANARY"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_SOURCE_REPAIR_CANARY=1 for actual MTPLX repair proof")
        }
        let started = Date()
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-model-source-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let releaseURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
            "MACSCOPE_SOURCE_REPAIR_RELEASE_APP"] ?? Bundle.main.bundleURL.path)
        // Production verifies both the signing requirement and sealed Release provenance.
        // The Release product identity and test-host identity are deliberately recorded separately.
        let builder = try XCTUnwrap(ReconstructionProductionComposition.jobSessionFactoryBuilder(
            nativeDecompilerRuntime: .productionShared, appBundleURL: releaseURL))
        let releaseBytes = try Data(contentsOf: releaseURL.appendingPathComponent(
            "Contents/Resources/MacScopeBuildProvenance.json"))
        let release = try Phase2QualificationGateBuildProvenance.parseCanonical(releaseBytes)
        // Bind this run to the explicitly expected signed Release product authority.
        let expectedReleaseCommit = ProcessInfo.processInfo.environment[
            "MACSCOPE_SOURCE_REPAIR_EXPECTED_RELEASE_COMMIT"]
            ?? "0b7e30783098cf709688e1e55ac010b4b02be522"
        guard expectedReleaseCommit.utf8.count == 40,
              expectedReleaseCommit.utf8.allSatisfy({
                  (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
              }),
              release.gitHeadCommit == expectedReleaseCommit else {
            throw ReconstructionProductionCompositionError.productionProvenanceInvalid
        }
        let releaseBinding: [String: String] = [
            "expectedCommit": expectedReleaseCommit,
            "actualCommit": release.gitHeadCommit,
            "bundlePath": releaseURL.path,
        ]
        try ReconstructionCanonicalJSON.encode(releaseBinding).write(
            to: root.appendingPathComponent("release-product-binding.json"))
        try releaseBytes.write(to: root.appendingPathComponent("release-product-provenance.json"))
        let host = try JoinedLiveHostProvenance.read()
        let hostBytes = try Data(contentsOf: XCTUnwrap(Bundle.main.url(
            forResource: "MacScopeBuildProvenance", withExtension: "json")))
        try hostBytes.write(to: root.appendingPathComponent("test-host-provenance.json"))
        let broker = NSXPCShellBrokerTransport()
        let original = ReconstructionSourceOriginalSession(workflow: .init(transport: broker,
            toolAuthority: try .capture()), stageParent: root)
        addTeardownBlock {
            await original.retire()
            await broker.reset()
        }
        let candidate: ReconstructionSourceOriginalSession.ImportCandidate
        do { candidate = try await original.prepare() }
        catch {
            if let diagnostic = await original.preparationDiagnostic() {
                try? JoinedLiveSourceEventCaptureProvider.captureOriginal(diagnostic, root: root)
            }
            await original.retire(); await broker.reset(); throw error
        }
        if let diagnostic = await original.preparationDiagnostic() {
            try JoinedLiveSourceEventCaptureProvider.captureOriginal(diagnostic, root: root)
        }
        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let databasePath = root.appendingPathComponent("workspace.sqlite").path
        let (workspaceRowID, owner) = try makeSourceRepairDatabaseOwner(
            path: databasePath, workspaceID: workspaceID,
            attachmentVaultRootURL: root.appendingPathComponent("vault"))
        var liveSession: ReconstructionJobSession?
        addTeardownBlock {
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await owner.revoke()
        }
        let imported = await ReconstructionCorpusImporter().ingest(
            selections: [.init(rootURL: candidate.executableURL, roles: [.primaryTarget])],
            projectID: projectID, cancellation: ReconstructionCancellation())
        XCTAssertTrue(imported.failures.isEmpty)
        let occurrence = try XCTUnwrap(imported.occurrences.first { $0.kind == .machOImage })
        XCTAssertEqual(occurrence.contentIdentity.digest, candidate.executable.sha256)
        XCTAssertEqual(occurrence.contentIdentity.byteCount, UInt64(candidate.executable.byteCount))
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID,
            contentIdentity: occurrence.contentIdentity)
        let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
            artifacts: imported.occurrences, relations: imported.relations,
            canonicalSHA256: imported.canonicalManifestSHA256)
        _ = try await owner.commitCorpus(workspaceID: workspaceID,
            mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                successorManifest: manifest, attachmentSources: imported.attachmentSources))
        // A controlled model-authorship experiment, fixed before objective identity is minted.
        // No candidate bytes, inference messages or original/oracle outputs are substituted.
        let objective = Self.controlledSourceRepairObjective
        let committed = try await owner.commitInitialJob(workspaceID: workspaceID,
            mutation: .init(jobID: jobID, projectID: projectID,
                selectedOccurrenceIDs: [occurrence.occurrenceID], objective: objective,
                budget: try .init(maxRounds: 8, maxTasks: 256, maxEvidenceRecords: 512,
                    maxEncodedBytes: 8_388_608), focus: .artifact(artifact),
                sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
        try await original.bind(projectID: projectID, jobID: jobID, importedArtifact: artifact)
        try await ReconstructionSourceOriginalSessionRegistry.shared.register(
            workspaceID: workspaceID, jobID: jobID, session: original)
        let discovery = NSXPCAIWorkerModelDiscoveryTransport()
        let discoveryCodec = Phase2AIWorkerModelDiscoveryAppCodec()
        let discoveryID = UUID()
        let inventory: Phase2LocalModelInventory
        let configuration: Phase2AIProviderConfiguration
        do {
            let endpoint = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
                endpointOrigin: "http://127.0.0.1:8000", requestTimeoutMilliseconds: 900_000,
                resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
            let reply = try await discovery.discover(
                requestData: discoveryCodec.encodeRequest(endpoint: endpoint, requestID: discoveryID),
                requestID: discoveryID)
            guard case .success(let observed) = try discoveryCodec.decodeReply(reply,
                expectedRequestID: discoveryID, endpoint: endpoint) else {
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            inventory = observed
            await discovery.reset()
            XCTAssertEqual(inventory.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
            let selection = try Phase2LocalAISelection.authorize(endpoint: endpoint, inventory: inventory,
                modelKey: Phase2MTPLXQualityRuntimeExpectation.servedModelID, maximumTokens: 16_384)
            configuration = selection.configuration
        } catch {
            await discovery.reset()
            await original.retire()
            await broker.reset()
            await owner.revoke()
            throw error
        }
        let transport = NSXPCAIAgentTransport(configuration: configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        let provider = ReconstructionXPCInferenceProvider(transport: transport,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        // Source revisions use their own v10 worker connection, as production does.
        let sourceTransport = NSXPCAIAgentTransport(configuration: configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        let sourceProvider = ReconstructionXPCInferenceProvider(transport: sourceTransport,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        let inference = JoinedLiveSignedInference(provider: provider, sourceProvider: sourceProvider,
            configuration: configuration,
            inventorySHA256: Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory),
            maximumOrdinaryCalls: 8, captureRoot: root)
        do {
            let worker = try await transport.prepareWorkerProcessReceipt()
            let workerAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
            let observation = try workerAuthority.observe(receipt: worker)
            guard workerAuthority.accepts(receipt: worker, observation: observation) else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            let sourceWorker = try await sourceTransport.prepareWorkerProcessReceipt()
            let sourceWorkerAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest)
            guard sourceWorkerAuthority.accepts(receipt: sourceWorker,
                observation: try sourceWorkerAuthority.observe(receipt: sourceWorker)) else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            let processCapture: [String: Any] = ["pid": worker.processIdentifier,
                "connection": worker.connectionIdentity.uuidString,
                "profile": worker.profileID.uuidString, "generation": worker.configurationGeneration,
                "protocol": worker.protocolManifestDigest,
                "startSeconds": observation.startIdentity.seconds,
                "startMicroseconds": observation.startIdentity.microseconds,
                "executablePath": observation.executableIdentity.canonicalPath,
                "executableSHA256": observation.executableIdentity.sha256,
                "cdHash": observation.executableIdentity.cdHash,
                "model": configuration.model, "endpointOrigin": configuration.endpointOrigin,
                "maximumTokens": configuration.maximumTokens,
                "requestTimeoutMilliseconds": configuration.requestTimeoutMilliseconds,
                "resourceTimeoutMilliseconds": configuration.resourceTimeoutMilliseconds,
                "inventorySHA256": Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory)]
            try JSONSerialization.data(withJSONObject: processCapture, options: [.sortedKeys]).write(
                to: root.appendingPathComponent("worker-provider-process.json"))
            let store = WorkspaceStore(workspaceName: "Actual model mismatch and repair",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(),
                autosaveScheduler: nil, workspaceID: workspaceID)
            let session = try await builder(inference)(workspaceID, jobID, owner, store)
            liveSession = session
            // Existing transport has bounded request/resource deadlines; this whole-job watchdog
            // also retires the production session if the coordinator cannot reach a terminal cut.
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch { return }
                await session.retire()
            }
            defer { watchdog.cancel() }
            let authority = ReconstructionJobCommandAuthority(jobID: jobID, expectedJobState: .created,
                checkpointID: committed.checkpoint.checkpointID,
                checkpointRevision: committed.checkpoint.revision,
                corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256)
            let finished = await session.start(authority: authority)
            XCTAssertTrue(finished)
            let state = try await owner.load(workspaceID: workspaceID)
            try ReconstructionCanonicalJSON.encode(state).write(to: root.appendingPathComponent("durable-state.json"))
            XCTAssertEqual(state.jobs.first { $0.jobID == jobID }?.state, .completed)
            guard inference.sourceAttempts == 2, inference.sources.count == 2 else {
                XCTFail("Repair requires exactly two actual model-authored revisions; no repair proof if first is correct")
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            let sourceRecords = state.evidence.filter { $0.creatingJobID == jobID
                && $0.operationID == ReconstructionSourceRevisionEvidence.operationID }
            let evaluationRecords = state.evidence.filter { $0.creatingJobID == jobID
                && $0.operationID == ReconstructionSourceEvaluationEvidence.operationID }
            XCTAssertEqual(sourceRecords.count, 2)
            XCTAssertEqual(evaluationRecords.count, 2)
            let revisions = try sourceRecords.map { try JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload) }
            let evaluations = try evaluationRecords.map { try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: $0.payload) }
            let first = try XCTUnwrap(revisions.first { $0.parentRevisionSHA256 == nil })
            let repaired = try XCTUnwrap(revisions.first { $0.parentRevisionSHA256 == first.revisionSHA256 })
            let failed = try XCTUnwrap(evaluations.first { $0.revisionSHA256 == first.revisionSHA256 })
            let accepted = try XCTUnwrap(evaluations.first { $0.revisionSHA256 == repaired.revisionSHA256 })
            guard failed.capturedOutcome.status == .behaviorMismatch,
                  failed.capturedOutcome.mismatches == [.init(index: 4, input: UInt32.max,
                      expected: UInt32.max, actual: 0)] else {
                XCTFail("The actual first candidate must produce the maximum-input wrapping mismatch")
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            XCTAssertEqual(failed.capturedOutcome.observations.count, 37)
            XCTAssertEqual(accepted.capturedOutcome.status, .accepted)
            XCTAssertEqual(accepted.capturedOutcome.observations.count, 37)
            XCTAssertTrue(accepted.capturedOutcome.mismatches.isEmpty)
            XCTAssertEqual(inference.sources[0].request.parentRevisionSHA256, nil)
            XCTAssertEqual(inference.sources[1].request.parentRevisionSHA256, first.revisionSHA256)
            XCTAssertEqual(inference.sources[1].outcome.candidate.parentRevisionSHA256, first.revisionSHA256)
            let oracleRecord = try XCTUnwrap(state.evidence.first { $0.evidenceID == accepted.oracleEvidenceID })
            let oracle = try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(payload: oracleRecord.payload)
            XCTAssertEqual(oracle.inputs.count, 37)
            XCTAssertEqual(accepted.capturedOutcome.observations.map(\.input), oracle.inputs)
            XCTAssertEqual(accepted.capturedOutcome.observations.map(\.output), oracle.outputs)
            XCTAssertEqual(oracle.execution.originalImageSHA256, candidate.executable.sha256)
            XCTAssertEqual(failed.oracleEvidenceID, accepted.oracleEvidenceID)
            XCTAssertEqual(failed.oracleSuiteSHA256, oracle.suiteSHA256)
            XCTAssertEqual(accepted.oracleSuiteSHA256, oracle.suiteSHA256)
            for (index, revision) in [first, repaired].enumerated() {
                let call = inference.sources[index]
                XCTAssertEqual(call.request.objective.text, objective)
                XCTAssertEqual(call.request.objective.sha256, revision.objectiveSHA256)
                XCTAssertEqual(revision.objectiveSHA256, signedDigest(Data(objective.utf8)))
                let record = try XCTUnwrap(sourceRecords.first { $0.evidenceID == evaluations.first {
                    $0.revisionSHA256 == revision.revisionSHA256 }?.sourceEvidenceID })
                let binding = try XCTUnwrap(revision.requestBinding)
                XCTAssertEqual(binding.canonicalRequestBytes, try ReconstructionCanonicalJSON.encode(call.request))
                XCTAssertEqual(binding.requestSHA256, call.authority.requestIdentitySHA256)
                XCTAssertEqual(binding.taskID, call.request.taskID)
                XCTAssertEqual(revision.sourceUTF8, Data(call.outcome.candidate.sourceText.utf8))
                XCTAssertEqual(revision.sourceSHA256, call.outcome.candidate.sourceSHA256)
                XCTAssertEqual(revision.oracleSuiteSHA256, oracle.suiteSHA256)
                let receipt = try XCTUnwrap(state.modelReceipts.first { $0.receiptID == record.modelReceiptID })
                XCTAssertEqual(receipt.requestIdentitySHA256, call.authority.requestIdentitySHA256)
                XCTAssertEqual(receipt.acceptedEvidenceIDs, [record.evidenceID])
                XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
                let checkpoint = try XCTUnwrap(state.checkpoints.first { $0.checkpointID == record.creatingCheckpointID })
                XCTAssertTrue(checkpoint.modelReceiptIDs.contains(receipt.receiptID))
                XCTAssertTrue(checkpoint.completedTaskIDs.contains(call.request.taskID))
                let evaluation = try XCTUnwrap(evaluations.first { $0.revisionSHA256 == revision.revisionSHA256 })
                XCTAssertEqual(evaluation.sourceRequestSHA256, binding.requestSHA256)
                XCTAssertEqual(evaluation.sourcePayloadSHA256, record.payloadSHA256)
                XCTAssertEqual(evaluation.sourceSHA256, revision.sourceSHA256)
                XCTAssertEqual(evaluation.oraclePayloadSHA256, oracleRecord.payloadSHA256)
                XCTAssertTrue(evaluation.capturedOutcome.phases.allSatisfy { $0.cleanup?.observedProcessAbsent == true })
                let evaluationRecord = try XCTUnwrap(evaluationRecords.first {
                    $0.creatingTaskID == evaluation.taskID })
                let toolReceipt = try XCTUnwrap(state.toolReceipts.first {
                    $0.receiptID == evaluationRecord.toolReceiptID })
                XCTAssertTrue(try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(toolReceipt))
                XCTAssertEqual(toolReceipt.requestIdentitySHA256, evaluation.evaluationRequestSHA256)
                let evaluationCheckpoint = try XCTUnwrap(state.checkpoints.first {
                    $0.checkpointID == evaluationRecord.creatingCheckpointID })
                XCTAssertEqual(evaluationCheckpoint.revision, evaluation.checkpointRevision)
                XCTAssertTrue(evaluationCheckpoint.toolReceiptIDs.contains(toolReceipt.receiptID))
                XCTAssertTrue(evaluationCheckpoint.completedTaskIDs.contains(evaluation.taskID))
            }
            let failedPayload = try ReconstructionSourceEvaluationCodec.encode(failed)
            let failedRecord = try XCTUnwrap(evaluationRecords.first { $0.payload == failedPayload })
            XCTAssertTrue(inference.sources[1].request.context.evidenceIDs.contains(failedRecord.evidenceID))
            let repairContext = try JSONDecoder().decode(ReconstructionSourceContextCompiler.Envelope.self,
                from: inference.sources[1].request.context.canonicalBytes)
            XCTAssertEqual(repairContext.parent?.revisionSHA256, first.revisionSHA256)
            XCTAssertEqual(repairContext.parent?.sourceSHA256, first.sourceSHA256)
            XCTAssertEqual(repairContext.parent?.sourceText, String(data: first.sourceUTF8, encoding: .utf8))
            XCTAssertEqual(repairContext.oracle.evidenceID, oracleRecord.evidenceID)
            XCTAssertEqual(repairContext.oracle.payloadSHA256, oracleRecord.payloadSHA256)
            let diagnostic = try XCTUnwrap(repairContext.diagnostics.first {
                $0.evidenceID == failedRecord.evidenceID })
            XCTAssertEqual(diagnostic.payloadSHA256, failedRecord.payloadSHA256)
            XCTAssertEqual(diagnostic.revisionSHA256, first.revisionSHA256)
            XCTAssertEqual(diagnostic.sourceSHA256, first.sourceSHA256)
            XCTAssertTrue(diagnostic.diagnostic.contains(
                "input=4294967295 expected=4294967295 observed=0"))
            XCTAssertEqual(inference.finals.count, 1)
            XCTAssertEqual(state.finalResults.filter { $0.jobID == jobID }.count, 1)
            let final = try XCTUnwrap(state.finalResults.first { $0.jobID == jobID })
            let finalCall = try XCTUnwrap(inference.finals.first)
            XCTAssertEqual(final.kind, .synthesis)
            XCTAssertEqual(final.payloadUTF8, Data(finalCall.outcome.candidate.text.utf8))
            XCTAssertEqual(final.citedEvidenceIDs, finalCall.outcome.candidate.evidenceIDs)
            XCTAssertFalse(final.citedEvidenceIDs.isEmpty)
            XCTAssertTrue(try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(final))
            let workerCurrent = await transport.revalidateWorkerProcessReceipt(worker)
            XCTAssertTrue(workerCurrent)
            let sourceWorkerCurrent = await sourceTransport.revalidateWorkerProcessReceipt(sourceWorker)
            XCTAssertTrue(sourceWorkerCurrent)
            let sources = try await owner.availableDurableAttachmentSources(workspaceID: workspaceID)
            await session.retire()
            await provider.finishRequest(); await transport.reset()
            await sourceProvider.finishRequest(); await sourceTransport.reset()
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await broker.reset(); await owner.revoke()
            // The scoped initializer transferred the sole database reference to the owner;
            // revoke has now closed that authority before physically reopening its file.
            let reopenedDatabase = try WorkspaceDatabase(path: databasePath)
            let coldDatabaseState = try reopenedDatabase.loadReconstructionState(workspaceID: workspaceID)
            XCTAssertEqual(coldDatabaseState, state)
            let components = try reopenedDatabase.packageComponents(workspaceID: workspaceRowID, documentID: UUID(),
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
            let package = root.appendingPathComponent("ModelRepair.mscope")
            try MacScopeDocumentPackage.writePackage(components.manifest,
                attachmentsByBinaryID: components.attachmentsByBinaryID, reconstructionState: coldDatabaseState,
                reconstructionAttachmentSources: sources, to: package)
            let reopened = try MacScopeDocumentPackage.openPackage(from: package)
            XCTAssertEqual(reopened.reconstructionState, state)
            let resaved = root.appendingPathComponent("Resaved.mscope")
            try MacScopeDocumentPackage.writePackage(reopened.manifest,
                attachmentsByBinaryID: reopened.attachmentsByBinaryID,
                reconstructionState: reopened.reconstructionState,
                reconstructionAttachmentSources: reopened.reconstructionAttachmentSources, to: resaved)
            let cold = try MacScopeDocumentPackage.openPackage(from: resaved)
            XCTAssertEqual(cold.reconstructionState, state)
            for record in sourceRecords + evaluationRecords + [oracleRecord] {
                XCTAssertEqual(cold.reconstructionState.evidence.first { $0.evidenceID == record.evidenceID }?.payload,
                    record.payload)
            }
            print("MTPLX_SOURCE_REPAIR_RECEIPT host_source=\(host.gitHeadCommit) host_tree=\(host.gitHeadTree) release_bundle=\(releaseURL.path) expected_release_commit=\(expectedReleaseCommit) actual_release_commit=\(release.gitHeadCommit) model=\(configuration.model) job=\(jobID) failed_parent=\(first.revisionSHA256) repaired=\(repaired.revisionSHA256) accepted_evaluation=\(accepted.evaluationSHA256) oracle=\(oracle.suiteSHA256) package=\(package.path) seconds=\(Date().timeIntervalSince(started))")
        } catch {
            print("MTPLX_SOURCE_REPAIR_FAILURE job=\(jobID) root=\(root.path) error=\(error)")
            if let state = try? await owner.load(workspaceID: workspaceID),
               let bytes = try? ReconstructionCanonicalJSON.encode(state) {
                try? bytes.write(to: root.appendingPathComponent("failure-durable-state.json"))
            }
            await liveSession?.retire()
            await provider.finishRequest(); await transport.reset()
            await sourceProvider.finishRequest(); await sourceTransport.reset()
            await ReconstructionSourceOriginalSessionRegistry.shared.remove(workspaceID: workspaceID, jobID: jobID)
            await original.retire(); await broker.reset(); await owner.revoke()
            throw error
        }
    }

    /// Live MTPLX canary for the F1 repair loop on the checked-in C sample, on the dev-loop
    /// (unsealed Debug) host: the identical production job graph as
    /// `ReconstructionSourceRepairLoopbackTests`, with the scripted stand-in replaced by the real
    /// signed AI worker talking to the running MTPLX Quality runtime. The job runs to its own
    /// repair bound; the test records what happened and asserts only completion, 37/37 on the
    /// accepted revision and byte-exact Save/reopen. Artifacts stay in the retained root.
    @MainActor
    func testOptInMTPLXCSampleRepairLoopOnUnsealedHostPhysicallyReopens() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_CSAMPLE_REPAIR_LIVE"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_CSAMPLE_REPAIR_LIVE=1 for the live MTPLX C-sample repair canary")
        }
        let started = Date()
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-mtplx-csample-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // xcodebuild does not surface test stdout, so every receipt line also lands in the root.
        let receiptLog = root.appendingPathComponent("receipt-lines.txt")
        FileManager.default.createFile(atPath: receiptLog.path, contents: nil)
        func emit(_ line: String) {
            print(line)
            if let handle = try? FileHandle(forWritingTo: receiptLog) {
                handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
            }
        }
        emit("MTPLX_CSAMPLE_LIVE_ROOT \(root.path)")
        let hostBytes = try Data(contentsOf: XCTUnwrap(Bundle.main.url(
            forResource: "MacScopeBuildProvenance", withExtension: "json")))
        try hostBytes.write(to: root.appendingPathComponent("test-host-provenance.json"))
        // The Debug host's provenance leaves git and build-input fields null, so the identity a
        // Release would derive comes from the checkout under test and the Debug provenance bytes.
        let host = try LiveUnsealedHostIdentity.read(provenance: hostBytes)
        let builder = ReconstructionProductionComposition.unsealedHostJobSessionFactoryBuilderForTesting(
            nativeDecompilerRuntime: .productionShared,
            modelProducerContext: .init(macScopeBuildIdentity: host.buildIdentitySHA256,
                macScopeSourceIdentity: host.gitHeadTree,
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                toolchainIdentity: host.xcodeBuild))
        let broker = NSXPCShellBrokerTransport()
        let original = ReconstructionSourceOriginalSession(workflow: .init(transport: broker,
            toolAuthority: try .capture()), stageParent: root)
        let candidate: ReconstructionSourceOriginalSession.ImportCandidate
        do { candidate = try await original.prepare() }
        catch { await original.retire(); await broker.reset(); throw error }
        emit("MTPLX_CSAMPLE_LIVE_ORIGINAL sha256=\(candidate.executable.sha256) bytes=\(candidate.executable.byteCount) fixture=\(ReconstructionSourceRepairLoopbackTests.fixtureBinarySHA256)")
        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let databasePath = root.appendingPathComponent("workspace.sqlite").path
        let (workspaceRowID, owner) = try makeSourceRepairDatabaseOwner(
            path: databasePath, workspaceID: workspaceID,
            attachmentVaultRootURL: root.appendingPathComponent("vault"))
        var liveSession: ReconstructionJobSession?
        var transport: NSXPCAIAgentTransport?
        var provider: ReconstructionXPCInferenceProvider?
        var sourceTransport: NSXPCAIAgentTransport?
        var sourceProvider: ReconstructionXPCInferenceProvider?
        func teardown() async {
            await liveSession?.retire(); liveSession = nil
            await provider?.finishRequest(); await transport?.reset()
            await sourceProvider?.finishRequest(); await sourceTransport?.reset()
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
            let objective = Self.controlledSourceRepairObjective
            let committed = try await owner.commitInitialJob(workspaceID: workspaceID,
                mutation: .init(jobID: jobID, projectID: projectID,
                    selectedOccurrenceIDs: [occurrence.occurrenceID], objective: objective,
                    budget: try .init(maxRounds: 8, maxTasks: 256, maxEvidenceRecords: 512,
                        maxEncodedBytes: 8_388_608), focus: .artifact(artifact),
                    sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
            try await original.bind(projectID: projectID, jobID: jobID, importedArtifact: artifact)
            try await ReconstructionSourceOriginalSessionRegistry.shared.register(
                workspaceID: workspaceID, jobID: jobID, session: original)

            let discovery = NSXPCAIWorkerModelDiscoveryTransport()
            let discoveryCodec = Phase2AIWorkerModelDiscoveryAppCodec()
            let discoveryID = UUID()
            let endpoint = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
                endpointOrigin: "http://127.0.0.1:8000", requestTimeoutMilliseconds: 900_000,
                resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
            let reply = try await discovery.discover(
                requestData: discoveryCodec.encodeRequest(endpoint: endpoint, requestID: discoveryID),
                requestID: discoveryID)
            await discovery.reset()
            guard case .success(let inventory) = try discoveryCodec.decodeReply(reply,
                expectedRequestID: discoveryID, endpoint: endpoint) else {
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            XCTAssertEqual(inventory.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
            let inventorySHA256 = Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory)
            let configuration = try Phase2LocalAISelection.authorize(endpoint: endpoint, inventory: inventory,
                modelKey: Phase2MTPLXQualityRuntimeExpectation.servedModelID, maximumTokens: 16_384).configuration
            let liveTransport = NSXPCAIAgentTransport(configuration: configuration,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
            transport = liveTransport
            let liveProvider = ReconstructionXPCInferenceProvider(transport: liveTransport,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
            provider = liveProvider
            // Source revisions use their own v10 worker connection, as production does.
            let liveSourceTransport = NSXPCAIAgentTransport(configuration: configuration,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
            sourceTransport = liveSourceTransport
            let liveSourceProvider = ReconstructionXPCInferenceProvider(transport: liveSourceTransport,
                protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
            sourceProvider = liveSourceProvider
            let inference = JoinedLiveSignedInference(provider: liveProvider, sourceProvider: liveSourceProvider,
                configuration: configuration,
                inventorySHA256: inventorySHA256, maximumOrdinaryCalls: 8, captureRoot: root)
            let worker = try await liveTransport.prepareWorkerProcessReceipt()
            let workerAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
            let observation = try workerAuthority.observe(receipt: worker)
            XCTAssertTrue(workerAuthority.accepts(receipt: worker, observation: observation))
            let sourceWorker = try await liveSourceTransport.prepareWorkerProcessReceipt()
            let sourceWorkerAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest)
            let sourceObservation = try sourceWorkerAuthority.observe(receipt: sourceWorker)
            XCTAssertTrue(sourceWorkerAuthority.accepts(receipt: sourceWorker, observation: sourceObservation))
            let modelIdentity: [String: Any] = ["workerPID": worker.processIdentifier,
                "workerExecutableSHA256": observation.executableIdentity.sha256,
                "workerCDHash": observation.executableIdentity.cdHash,
                "protocol": worker.protocolManifestDigest,
                "sourceWorkerPID": sourceWorker.processIdentifier,
                "sourceWorkerCDHash": sourceObservation.executableIdentity.cdHash,
                "sourceProtocol": sourceWorker.protocolManifestDigest,
                "model": configuration.model, "endpointOrigin": configuration.endpointOrigin,
                "maximumTokens": configuration.maximumTokens,
                "inventorySHA256": inventorySHA256,
                "inventoryModels": inventory.models.map(\.key),
                "hostCommit": host.gitHeadCommit, "hostTree": host.gitHeadTree,
                "hostConfiguration": host.configuration, "hostXcodeBuild": host.xcodeBuild]
            try JSONSerialization.data(withJSONObject: modelIdentity, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appendingPathComponent("model-identity.json"))
            emit("MTPLX_CSAMPLE_LIVE_MODEL model=\(configuration.model) inventory=\(inventorySHA256) worker_cdhash=\(observation.executableIdentity.cdHash)")

            let store = WorkspaceStore(workspaceName: "Live MTPLX C-sample repair",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(),
                autosaveScheduler: nil, workspaceID: workspaceID)
            let session = try await builder(inference)(workspaceID, jobID, owner, store)
            liveSession = session
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
                await session.retire()
            }
            defer { watchdog.cancel() }
            let jobStarted = Date()
            let finished = await session.start(authority: ReconstructionJobCommandAuthority(jobID: jobID,
                expectedJobState: .created, checkpointID: committed.checkpoint.checkpointID,
                checkpointRevision: committed.checkpoint.revision,
                corpusManifestSHA256: committed.checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: committed.checkpoint.evidenceFrontierSHA256))
            let jobSeconds = Date().timeIntervalSince(jobStarted)
            let state = try await owner.load(workspaceID: workspaceID)
            try ReconstructionCanonicalJSON.encode(state).write(to: root.appendingPathComponent("durable-state.json"))
            let lifecycle = try await owner.lifecycle(workspaceID: workspaceID)
            let jobsStatus = try WorkspaceScriptingAPI.reconstructionJobsStatus(
                .object(["job": .string(jobID.uuidString)]), state: state, lifecycle: lifecycle)
            try jobsStatus.jsonData(prettyPrinted: true).write(to: root.appendingPathComponent("reconstruction-jobs.json"))
            let jobState = state.jobs.first { $0.jobID == jobID }?.state
            let summary = try ReconstructionJobStatusSummary.make(jobID: jobID, state: state, lifecycle: lifecycle)
            emit("MTPLX_CSAMPLE_LIVE_TERMINAL finished=\(finished) state=\(String(describing: jobState)) job_seconds=\(jobSeconds) elapsed=\(String(describing: summary?.elapsedMilliseconds)) elapsedSource=\(String(describing: summary?.elapsedSource)) sources=\(inference.sourceAttempts) rounds=\(inference.rounds.count) finals=\(inference.finals.count) tasks=\(state.tasks.filter { $0.identity.jobID == jobID }.map { "\($0.identity.kind):\($0.state)" })")

            let sourceRecords = state.evidence.filter { $0.creatingJobID == jobID
                && $0.operationID == ReconstructionSourceRevisionEvidence.operationID }
            let evaluationRecords = state.evidence.filter { $0.creatingJobID == jobID
                && $0.operationID == ReconstructionSourceEvaluationEvidence.operationID }
            let revisions = try sourceRecords.map { try JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload) }
            let evaluations = try evaluationRecords.map { try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: $0.payload) }
            for (record, revision) in zip(sourceRecords, revisions) {
                let evaluation = evaluations.first { $0.revisionSHA256 == revision.revisionSHA256 }
                try revision.sourceUTF8.write(to: root.appendingPathComponent("revision-\(revision.revisionSHA256.prefix(12)).c"))
                emit("MTPLX_CSAMPLE_LIVE_REVISION evidence=\(record.evidenceID) revision=\(revision.revisionSHA256) parent=\(revision.parentRevisionSHA256 ?? "none") source=\(revision.sourceSHA256) status=\(String(describing: evaluation?.capturedOutcome.status)) observations=\(evaluation?.capturedOutcome.observations.count ?? -1) mismatches=\(String(describing: evaluation?.capturedOutcome.mismatches)) evaluation=\(evaluation?.evaluationSHA256 ?? "none")")
            }
            try ReconstructionCanonicalJSON.encode(state.modelReceipts.filter { $0.jobID == jobID })
                .write(to: root.appendingPathComponent("model-receipts.json"))
            for receipt in state.modelReceipts where receipt.jobID == jobID {
                emit("MTPLX_CSAMPLE_LIVE_MODEL_RECEIPT receipt=\(receipt.receiptID) task=\(receipt.taskID) revision=\(receipt.checkpointRevision) terminal=\(receipt.terminalState) accepted=\(receipt.acceptedEvidenceIDs) sha256=\(receipt.canonicalSHA256)")
            }
            XCTAssertTrue(finished)
            XCTAssertEqual(jobState, .completed)
            let accepted = try XCTUnwrap(evaluations.first { $0.capturedOutcome.status == .accepted },
                "no accepted source revision within the production repair bound")
            XCTAssertEqual(accepted.capturedOutcome.observations.count, 37)
            XCTAssertTrue(accepted.capturedOutcome.mismatches.isEmpty)
            let acceptedRecord = try XCTUnwrap(sourceRecords.first {
                (try? JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload))?.revisionSHA256
                    == accepted.revisionSHA256 })

            // Durable Save, physical reopen, re-save and cold-open.
            let sources = try await owner.availableDurableAttachmentSources(workspaceID: workspaceID)
            await teardown()
            let reopenedDatabase = try WorkspaceDatabase(path: databasePath)
            let coldDatabaseState = try reopenedDatabase.loadReconstructionState(workspaceID: workspaceID)
            XCTAssertEqual(coldDatabaseState, state)
            let components = try reopenedDatabase.packageComponents(workspaceID: workspaceRowID, documentID: UUID(),
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
            let package = root.appendingPathComponent("LiveRepair.mscope")
            try MacScopeDocumentPackage.writePackage(components.manifest,
                attachmentsByBinaryID: components.attachmentsByBinaryID, reconstructionState: coldDatabaseState,
                reconstructionAttachmentSources: sources, to: package)
            let reopened = try MacScopeDocumentPackage.openPackage(from: package)
            let resaved = root.appendingPathComponent("LiveResaved.mscope")
            try MacScopeDocumentPackage.writePackage(reopened.manifest,
                attachmentsByBinaryID: reopened.attachmentsByBinaryID,
                reconstructionState: reopened.reconstructionState,
                reconstructionAttachmentSources: reopened.reconstructionAttachmentSources, to: resaved)
            let cold = try MacScopeDocumentPackage.openPackage(from: resaved)
            let stateBytes = try ReconstructionCanonicalJSON.encode(state)
            let reopenedExact = try ReconstructionCanonicalJSON.encode(reopened.reconstructionState) == stateBytes
            let coldExact = try ReconstructionCanonicalJSON.encode(cold.reconstructionState) == stateBytes
            let acceptedExact = cold.reconstructionState.evidence.first {
                $0.evidenceID == acceptedRecord.evidenceID }?.payload == acceptedRecord.payload
            XCTAssertEqual(reopened.reconstructionState, state)
            XCTAssertEqual(cold.reconstructionState, state)
            XCTAssertTrue(reopenedExact && coldExact && acceptedExact)
            emit("MTPLX_CSAMPLE_LIVE_RECEIPT host_source=\(host.gitHeadCommit) host_tree=\(host.gitHeadTree) model=\(configuration.model) job=\(jobID) accepted_revision=\(accepted.revisionSHA256) accepted_evaluation=\(accepted.evaluationSHA256) harness=\(accepted.capturedOutcome.observations.count)/37 reopen_exact=\(reopenedExact) cold_exact=\(coldExact) accepted_payload_exact=\(acceptedExact) package=\(package.path) total_seconds=\(Date().timeIntervalSince(started))")
        } catch {
            emit("MTPLX_CSAMPLE_LIVE_FAILURE job=\(jobID) root=\(root.path) seconds=\(Date().timeIntervalSince(started)) error=\(String(reflecting: error))")
            if let state = try? await owner.load(workspaceID: workspaceID),
               let bytes = try? ReconstructionCanonicalJSON.encode(state) {
                try? bytes.write(to: root.appendingPathComponent("failure-durable-state.json"))
            }
            await teardown()
            throw error
        }
    }

    /// Headless, no model: the joined live harness must send a source revision to a provider whose
    /// selected bundle is reconstructionSourceV10, as production does, not to its R2 round provider.
    /// The 2026-10-13 06:10 C-sample canary failed locally with protocolMismatch on exactly this.
    @MainActor
    func testJoinedLiveHarnessRoutesSourceRevisionToV10ProviderWithoutModel() async throws {
        let sha = { (text: String) in ReconstructionSourceInferenceContract.sha256(Data(text.utf8)) }
        let jobID = UUID()
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: sha("binary"), byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil,
                architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let contextBytes = Data("{}".utf8)
        let request = ReconstructionSourceRevisionRequest(
            protocolVersion: ReconstructionSourceRevisionRequest.protocolVersion,
            objective: try .init(jobID: jobID, text: "objective", sha256: sha("objective")),
            projectID: UUID(), jobID: jobID, taskID: UUID(), checkpointRevision: 1, roundID: UUID(),
            function: function, corpusManifestSHA256: sha("corpus"), evidenceFrontierSHA256: sha("frontier"),
            oracleSuiteSHA256: sha("oracle"), profileID: ReconstructionSourceInferenceContract.profileID,
            parentRevisionSHA256: nil,
            context: .init(canonicalBytes: contextBytes,
                canonicalSHA256: ReconstructionSourceInferenceContract.sha256(contextBytes), evidenceIDs: [UUID()]))
        try request.validate()
        XCTAssertEqual(try ReconstructionAIWorkerRequest.sourceRevision(request).protocolBundle,
            Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        let configuration = try Phase2AIProviderConfiguration(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            maximumTokens: 16_384, requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("joined-live-source-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        func propose(sourceBundle: Phase2AIWorkerProductionProtocolBundle) async throws
            -> (round: [String], source: [String], failure: String) {
            let captureRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: false)
            let roundTransport = JoinedLiveBundleRecordingTransport()
            let sourceTransport = JoinedLiveBundleRecordingTransport()
            let inference = JoinedLiveSignedInference(
                provider: ReconstructionXPCInferenceProvider(transport: roundTransport,
                    protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2),
                sourceProvider: ReconstructionXPCInferenceProvider(transport: sourceTransport,
                    protocolBundle: sourceBundle),
                configuration: configuration, inventorySHA256: sha("inventory"),
                maximumOrdinaryCalls: 1, captureRoot: captureRoot)
            let result = await inference.proposeSourceRevision(request: request)
            if case .finished = result { XCTFail("the recording transport never completes a request") }
            XCTAssertEqual(inference.sourceAttempts, 1)
            let failures = try FileManager.default.contentsOfDirectory(atPath: captureRoot.path)
                .filter { $0.hasPrefix("source-failure-") }
            XCTAssertEqual(failures.count, 1)
            let failure = try String(contentsOf: captureRoot.appendingPathComponent(try XCTUnwrap(failures.first)),
                encoding: .utf8)
            return (await roundTransport.dispatchedManifestDigests,
                await sourceTransport.dispatchedManifestDigests, failure)
        }

        // Fixed wiring: the source request reaches the v10 transport; the R2 transport sees nothing.
        let fixed = try await propose(sourceBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        XCTAssertEqual(fixed.source, [Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest])
        XCTAssertEqual(fixed.round, [])
        XCTAssertFalse(fixed.failure.contains("protocolMismatch"), fixed.failure)
        XCTAssertTrue(fixed.failure.contains(JoinedLiveBundleRecordingTransport.sentinel), fixed.failure)

        // Control, the 06:10 wiring: an R2-selected provider rejects the v10 request before dispatch.
        let r2 = try await propose(sourceBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        XCTAssertEqual(r2.source, [])
        XCTAssertEqual(r2.round, [])
        XCTAssertEqual(r2.failure, "protocolMismatch")
    }

    /// Complete ordinary imported job under the real coordinator. The adapter records actual
    /// signed MTPLX requests/outcomes; it cannot choose tools or manufacture final text.
    @MainActor
    func testOptInMTPLXImportedCoordinatorRefreshFinalPhysicallyReopens() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_LIVE_CANARY"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_LIVE_CANARY=1 for the exact Quality runtime")
        }
        let started = Date()
        let root = TestWorkRoot.authority
            .appendingPathComponent("macscope-joined-canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        // Keep the exact physical package for root-owned evidence review after execution.
        let source = root.appendingPathComponent("authored-arm64")
        let tail = Data((0..<16).flatMap { _ in [UInt8(0x1f), 0x20, 0x03, 0xd5] })
        try MachOFixture.makeExecutableWithLoadCommandMetadata(mappedTail: tail).bytes.write(to: source)
        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let imported = await ReconstructionCorpusImporter().ingest(
            selections: [.init(rootURL: source, roles: [.primaryTarget])],
            projectID: projectID, cancellation: ReconstructionCancellation())
        XCTAssertTrue(imported.failures.isEmpty)
        let occurrence = try XCTUnwrap(imported.occurrences.first { $0.kind == .machOImage })
        let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
            artifacts: imported.occurrences, relations: imported.relations,
            canonicalSHA256: imported.canonicalManifestSHA256)
        let databasePath = root.appendingPathComponent("workspace.sqlite").path
        let database = try WorkspaceDatabase(path: databasePath)
        try database.applySchema()
        let workspace = try database.saveSnapshot(workspaceUUID: workspaceID,
            workspaceName: "Fresh imported live workflow", snapshot: .init(binaries: [], analysisBySlot: [:]), now: Date())
        let workspaceRowID = try XCTUnwrap(workspace.id)
        let owner = ReconstructionDatabaseOwner(database: database,
            attachmentVaultRootURL: root.appendingPathComponent("vault"))
        _ = try await owner.commitCorpus(workspaceID: workspaceID,
            mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                successorManifest: manifest, attachmentSources: imported.attachmentSources))
        let objective = "Use the offered reconstruction.analysis.macscope.refresh handle exactly once in your first round and choose continue. This schedules fresh MacScope analysis of the exact offered authored function. Do not select other handles. In a later round containing the newly accepted MacScope evidence, select no handles and choose sufficientEvidence. Do not refresh again or invent gaps. In final synthesis explain only the supported behavior of this authored binary and cite the accepted evidence supplied with that request."
        _ = try await owner.commitInitialJob(workspaceID: workspaceID,
            mutation: .init(jobID: jobID, projectID: projectID,
                selectedOccurrenceIDs: [occurrence.occurrenceID], objective: objective,
                budget: try .init(maxRounds: 4, maxTasks: 128, maxEvidenceRecords: 512,
                    maxEncodedBytes: 4 * 1_024 * 1_024),
                focus: .artifact(.init(occurrenceID: occurrence.occurrenceID,
                    contentIdentity: occurrence.contentIdentity))))
        let persistence = ReconstructionDatabaseJobPersistence(workspaceID: workspaceID, owner: owner)
        let admission = try await ReconstructionNativeDecompilerAdmissionFactory(
            runtime: .productionShared, durable: persistence).admission(forDurableJobID: jobID)
        let native = ReconstructionNativeDecompilerAdapter(admission: admission)
        let controller = ReconstructionProductionBatchExecutionController(durableJobID: jobID,
            builder: { basis, _ in
                var images: [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding] = [:]
                for task in basis.tasks {
                    switch task.identity.subject {
                    case .image(let value): images[value.artifact.occurrenceID] = value.image
                    case .function(let value): images[value.artifact.occurrenceID] = value.image
                    default: break
                    }
                }
                let resolver = try ReconstructionHeadlessAnalysisRequestResolver(manifest: basis.manifest,
                    attachmentSources: basis.attachmentSources, imagesByOccurrence: images)
                let pool = try ReconstructionAnalysisProviderPool(factory: ReconstructionDefaultAnalysisProviderFactory(),
                    budget: .init(maximumActiveAnalyses: 1, estimatedResidentBytesPerAnalysis: 1, reservedHostBytes: 0))
                return ReconstructionBatchScheduler(durableJobID: jobID,
                    executor: RefreshLiveBatchTrace(executor: ReconstructionBatchTaskExecutor(resolver: resolver,
                        headless: ReconstructionHeadlessAnalysisExecutor(pool: pool), native: native)))
            }, retireJobAuthority: { await native.retire() })
        let discovery = NSXPCAIWorkerModelDiscoveryTransport()
        let discoveryCodec = Phase2AIWorkerModelDiscoveryAppCodec()
        let discoveryID = UUID()
        let inventory: Phase2LocalModelInventory
        let configuration: Phase2AIProviderConfiguration
        do {
            let endpoint = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
                endpointOrigin: "http://127.0.0.1:8000", requestTimeoutMilliseconds: 900_000,
                resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
            let reply = try await discovery.discover(
                requestData: discoveryCodec.encodeRequest(endpoint: endpoint, requestID: discoveryID),
                requestID: discoveryID)
            guard case .success(let observed) = try discoveryCodec.decodeReply(reply,
                expectedRequestID: discoveryID, endpoint: endpoint) else {
                throw ReconstructionJobCoordinatorFailure.modelUnavailable
            }
            inventory = observed
            await discovery.reset()
            XCTAssertEqual(inventory.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
            let selection = try Phase2LocalAISelection.authorize(endpoint: endpoint, inventory: inventory,
                modelKey: Phase2MTPLXQualityRuntimeExpectation.servedModelID, maximumTokens: 16_384)
            configuration = selection.configuration
        } catch {
            await discovery.reset()
            await controller.retire(jobID: jobID)
            await owner.revoke()
            throw error
        }
        let transport = NSXPCAIAgentTransport(configuration: configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        let provider = ReconstructionXPCInferenceProvider(transport: transport,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        // Ordinary imported job: no source revision is expected, but one would need the v10
        // provider. The transport connects lazily, so no worker connection opens unless one is sent.
        let sourceTransport = NSXPCAIAgentTransport(configuration: configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        let sourceProvider = ReconstructionXPCInferenceProvider(transport: sourceTransport,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        let inference = JoinedLiveSignedInference(provider: provider, sourceProvider: sourceProvider,
            configuration: configuration,
            inventorySHA256: Phase2LocalModelInventoryIdentity.canonicalSHA256(inventory),
            maximumOrdinaryCalls: 4, captureRoot: root)
        do {
            let workerReceipt = try await transport.prepareWorkerProcessReceipt()
            let processAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
            XCTAssertTrue(processAuthority.accepts(receipt: workerReceipt,
                observation: try processAuthority.observe(receipt: workerReceipt)))
            let provenance = try JoinedLiveHostProvenance.read()
            // Bound this authored-function canary's prompt independently of its durable job budget.
            let contextCompiler = ReconstructionContextCompiler(maximumContextBytes: 16_384)
            let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
                macScopeBuildIdentity: provenance.selectedBuildInputsSHA256,
                macScopeSourceIdentity: provenance.gitHeadTree,
                operationIdentity: ReconstructionProductionTaskContract.modelRound,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.makeR2().toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
                toolchainIdentity: provenance.xcodeBuild), contextCompiler: contextCompiler)
            let registry = ReconstructionProductionRoundBasisRegistry()
            let cut = ReconstructionProductionCommittedRoundCutProvider(workspaceID: workspaceID,
                owner: owner, batchExecutionBuilder: controller,
                preparedRoundBuilder: JoinedLiveBoundedPreparedRoundBuilder(
                    base: try ReconstructionProductionPreparedRoundBuilder(
                        evidenceQueryProducer: author.makeToolProducer(operationID: .evidenceQuery),
                        analysisRefreshProducer: author.makeToolProducer(operationID: .analysisMacScopeRefresh)),
                    contextCompiler: contextCompiler),
                basisRegistry: registry, maximumConcurrentTasks: 1)
            let planner = ReconstructionProductionJobRoundPlanner(
                materializer: ReconstructionProductionJobRoundMaterializer(cutProvider: cut,
                    planBuilder: ReconstructionProductionRoundPlanBuilder(basisRegistry: registry, receiptAuthor: author)),
                inference: inference, projectors: [ReconstructionCheckpointToolProjector(),
                    ReconstructionCorpusToolProjector(), ReconstructionDecompilerToolProjector(),
                    ReconstructionEvidenceToolProjector(), ReconstructionGapsToolProjector(),
                    ReconstructionImageFunctionToolProjector()], contextCompiler: contextCompiler)
            let publisher = JoinedLiveStatusPublisher()
            let coordinator = ReconstructionJobCoordinator(persistence: persistence, planner: planner, publisher: publisher)
            await coordinator.start(jobID: jobID)
            let state = try await owner.load(workspaceID: workspaceID)
            XCTAssertEqual(state.jobs.first { $0.jobID == jobID }?.state, .completed)
            let first = try XCTUnwrap(inference.rounds.first)
            let selectedRefresh = first.request.handles.filter {
                $0.operationID == .analysisMacScopeRefresh && first.outcome.candidate.selectedHandleIDs.contains($0.handleID)
            }
            XCTAssertEqual(selectedRefresh.count, 1)
            XCTAssertEqual(first.outcome.candidate.selectedHandleIDs, selectedRefresh.map(\.handleID))
            XCTAssertEqual(first.outcome.candidate.disposition, .continue)
            let refresh = try XCTUnwrap(state.tasks.first { task in
                task.identity.kind == .decompileMacScope && task.identity.dependencyTaskIDs.contains { id in
                    state.tasks.contains { $0.identity.taskID == id && $0.identity.kind == .checkpoint }
                }
            })
            XCTAssertEqual(refresh.state, .completed)
            guard case .function(let refreshedFunction)? = refresh.identity.subject else {
                throw ReconstructionJobCoordinatorFailure.malformedOutput
            }
            XCTAssertEqual(refreshedFunction.artifact.occurrenceID, occurrence.occurrenceID)
            XCTAssertEqual(refreshedFunction.artifact.contentIdentity, occurrence.contentIdentity)
            let fresh = state.evidence.filter { $0.creatingTaskID == refresh.identity.taskID }
            XCTAssertFalse(fresh.isEmpty)
            XCTAssertTrue(fresh.allSatisfy { $0.classification == .acceptedCurrent })
            XCTAssertTrue(Set(fresh.map(\.evidenceID)).isDisjoint(with: Set(first.request.context.evidenceIDs)))
            for record in fresh {
                let creatingCheckpoint = try XCTUnwrap(state.checkpoints.first {
                    $0.checkpointID == record.creatingCheckpointID
                })
                XCTAssertGreaterThan(creatingCheckpoint.revision, first.request.checkpointRevision + 1,
                    "The scheduling acknowledgment must not publish fresh semantic evidence")
            }
            let later = try XCTUnwrap(inference.rounds.dropFirst().first {
                Set(fresh.map(\.evidenceID)).isSubset(of: Set($0.request.context.evidenceIDs))
            })
            XCTAssertGreaterThan(later.request.checkpointRevision, first.request.checkpointRevision)
            XCTAssertNotEqual(later.request.evidenceFrontierSHA256, first.request.evidenceFrontierSHA256)
            let laterRecords = try JoinedLiveSignedInference.contextRecords(later.request.context)
            for record in fresh {
                let dispatched = try XCTUnwrap(laterRecords.first { $0.evidenceID == record.evidenceID })
                XCTAssertEqual(dispatched.payload, record.payload)
                XCTAssertEqual(dispatched.classification, .acceptedCurrent)
            }
            XCTAssertTrue(later.outcome.candidate.selectedHandleIDs.isEmpty)
            XCTAssertEqual(later.outcome.candidate.disposition, .sufficientEvidence)
            XCTAssertEqual(inference.finals.count, 1)
            let finalCall = try XCTUnwrap(inference.finals.first)
            let results = state.finalResults.filter { $0.jobID == jobID }
            XCTAssertEqual(results.count, 1)
            let result = try XCTUnwrap(results.first)
            // Insufficient evidence is durable terminal behavior, but does not pass grounded success.
            XCTAssertEqual(result.kind, .synthesis)
            XCTAssertEqual(result.payloadUTF8, Data(finalCall.outcome.candidate.text.utf8))
            XCTAssertEqual(result.payloadSHA256, signedDigest(result.payloadUTF8))
            XCTAssertEqual(result.payloadByteCount, UInt64(result.payloadUTF8.count))
            XCTAssertEqual(result.citedEvidenceIDs, finalCall.outcome.candidate.evidenceIDs)
            XCTAssertFalse(result.citedEvidenceIDs.isEmpty)
            XCTAssertFalse(Set(fresh.map(\.evidenceID)).intersection(result.citedEvidenceIDs).isEmpty)
            XCTAssertTrue(result.citedEvidenceIDs.allSatisfy { id in
                state.evidence.contains { $0.evidenceID == id && $0.classification == .acceptedCurrent }
            })
            XCTAssertTrue(try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(result))
            let receipt = try XCTUnwrap(state.modelReceipts.first { $0.receiptID == result.modelReceiptID })
            let checkpoint = try XCTUnwrap(state.checkpoints.first { $0.checkpointID == result.checkpointID })
            XCTAssertEqual(receipt.finalResultCommitment?.resultID, result.resultID)
            XCTAssertEqual(receipt.finalResultCommitment?.canonicalSHA256, result.canonicalSHA256)
            XCTAssertEqual(receipt.requestIdentitySHA256, finalCall.authority.requestIdentitySHA256)
            XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
            XCTAssertTrue(checkpoint.modelReceiptIDs.contains(receipt.receiptID))
            XCTAssertEqual(checkpoint.coordinatorState, .completed)
            let finalPublishedDisposition = await publisher.lastDisposition
            XCTAssertEqual(finalPublishedDisposition, .completed)
            let workerCurrent = await transport.revalidateWorkerProcessReceipt(workerReceipt)
            XCTAssertTrue(workerCurrent)
            let durableSources = try await owner.availableDurableAttachmentSources(workspaceID: workspaceID)
            await provider.finishRequest()
            await transport.reset()
            await sourceProvider.finishRequest()
            await sourceTransport.reset()
            await controller.retire(jobID: jobID)
            await owner.revoke()
            // Reopen physical SQLite after quiescence; never reuse the connection sent
            // to the database owner across the Swift concurrency boundary.
            let reopenedDatabase = try WorkspaceDatabase(path: databasePath)
            let components = try reopenedDatabase.packageComponents(workspaceID: workspaceRowID, documentID: UUID(),
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
            let package = root.appendingPathComponent("Joined.mscope")
            try MacScopeDocumentPackage.writePackage(components.manifest,
                attachmentsByBinaryID: components.attachmentsByBinaryID,
                reconstructionState: state, reconstructionAttachmentSources: durableSources, to: package)
            let reopened = try MacScopeDocumentPackage.openPackage(from: package)
            XCTAssertEqual(reopened.reconstructionState, state)
            XCTAssertEqual(reopened.reconstructionState.finalResults.filter { $0.jobID == jobID }, [result])
            let secondPackage = root.appendingPathComponent("Resaved.mscope")
            try MacScopeDocumentPackage.writePackage(reopened.manifest,
                attachmentsByBinaryID: reopened.attachmentsByBinaryID,
                reconstructionState: reopened.reconstructionState,
                reconstructionAttachmentSources: reopened.reconstructionAttachmentSources, to: secondPackage)
            XCTAssertEqual(try MacScopeDocumentPackage.openPackage(from: secondPackage).reconstructionState, state)
            for path in [ReconstructionPackageLayout.corpusManifestPath,
                ReconstructionPackageLayout.evidenceManifestPath, ReconstructionPackageLayout.checkpointManifestPath] {
                XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(path)),
                    try Data(contentsOf: secondPackage.appendingPathComponent(path)))
            }
            print("MTPLX_JOINED_RECEIPT source=\(provenance.gitHeadCommit) tree=\(provenance.gitHeadTree) configuration=\(provenance.configuration) model=\(configuration.model) job=\(jobID) refresh_task=\(refresh.identity.taskID) fresh_evidence=\(fresh.map(\.evidenceID)) result=\(result.resultID) result_sha256=\(result.canonicalSHA256) payload_sha256=\(result.payloadSHA256) citations=\(result.citedEvidenceIDs) receipt=\(receipt.receiptID) checkpoint=\(checkpoint.checkpointID) package=\(package.path) seconds=\(Date().timeIntervalSince(started))")
        } catch {
            print("MTPLX_JOINED_FAILURE job=\(jobID) root=\(root.path) seconds=\(Date().timeIntervalSince(started)) error=\(error)")
            await provider.finishRequest()
            await transport.reset()
            await sourceProvider.finishRequest()
            await sourceTransport.reset()
            await controller.retire(jobID: jobID)
            await owner.revoke()
            throw error
        }
    }

    /// Real authored Mach-O, production task/receipt planning and SQLite commits, and two
    /// actual signed-worker MTPLX requests. No candidate or analysis result is scripted.
    @MainActor
    func testOptInMTPLXModelSelectedRefreshCommitsFreshAnalysisBeforeNextInference() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_LIVE_CANARY"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_LIVE_CANARY=1 for the installed exact Quality runtime")
        }
        let catalog = try await Phase2NativeModelDiscoveryHTTPClient().discover(
            at: .init(validating: "http://127.0.0.1:8000"), provider: .mtplx)
        XCTAssertEqual(catalog.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
        let directory = TestWorkRoot.authority
            .appendingPathComponent("macscope-refresh-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("authored-arm64")
        // Actual mapped file bytes provide SLEIGH's decode lookahead without
        // changing __text, the entry point, or the selected function extent.
        let mappedTail = Data((0..<16).flatMap { _ in [UInt8(0x1f), 0x20, 0x03, 0xd5] })
        let bytes = MachOFixture.makeExecutableWithLoadCommandMetadata(mappedTail: mappedTail).bytes
        try bytes.write(to: file)
        let content = try ReconstructionContentIdentity(algorithm: .sha256,
            digest: signedDigest(bytes), byteCount: UInt64(bytes.count))
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: .init(rawValue: UUID()), contentIdentity: content, kind: .machOImage,
            roles: [.primaryTarget], executableMode: true, originalName: file.lastPathComponent,
            diagnostic: nil)
        let projectID = UUID(), jobID = UUID()
        let draft = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
            artifacts: [occurrence], relations: [], canonicalSHA256: gateDigest(1))
        let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
            artifacts: [occurrence], relations: [],
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft))
        let database = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        try database.database.replaceReconstructionState(workspaceID: database.workspaceUUID,
            state: .init(projects: [try .init(projectID: projectID,
                name: "Authored refresh canary", currentCorpusManifestSHA256: nil)],
                corpusManifests: [], evidence: [], evidenceRelations: [], evidenceGaps: [],
                jobs: [], tasks: [], checkpoints: [], toolReceipts: [], modelReceipts: []))
        let vaultRoot = directory.appendingPathComponent("vault", isDirectory: true)
        database.database.configureReconstructionAttachmentVault(rootURL: vaultRoot)
        let durableSources = try database.database.publishDurableReconstructionAttachmentSources(
            [.init(contentIdentity: content, verifiedURL: file)], for: manifest)
        // The durable checkpoint authority also fences the workspace's persisted image.
        // Establish that image from the actual vault bytes, rather than the preview snapshot
        // used solely to create the in-memory database's workspace row.
        let baselinePool = try ReconstructionAnalysisProviderPool(
            factory: ReconstructionDefaultAnalysisProviderFactory(),
            budget: .init(maximumActiveAnalyses: 1, estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0))
        let baselineExecutor = ReconstructionHeadlessAnalysisExecutor(pool: baselinePool)
        let baseline = try await baselineExecutor.execute(.init(
            source: try XCTUnwrap(durableSources.first),
            artifact: .init(occurrenceID: occurrence.occurrenceID, contentIdentity: content),
            image: nil, functionID: nil, overrides: [:], imageAuthorityIntent: .initialLoad),
            cancellation: ReconstructionCancellation())
        let persisted = try XCTUnwrap(database.database.loadWorkspaceState(workspaceID: database.workspaceRowID))
        _ = try database.database.replaceWorkspaceState(workspaceID: database.workspaceRowID,
            workspaceName: "Authored refresh canary", snapshot: baseline.detached.workspace,
            selectedSidebarItemID: persisted.session.selectedSidebarItemID,
            selectedAddress: persisted.session.selectedAddress, selectedTool: persisted.session.selectedTool,
            editorMode: persisted.session.editorMode, isInspectorPresented: persisted.session.isInspectorPresented,
            sidebarSearchText: persisted.session.sidebarSearchText,
            focusedImageSlot: persisted.session.focusedImageSlot, now: Date())
        await baselineExecutor.retire()
        // Transfer the SQLite connection only after baseline setup is complete. Subsequent
        // access is exclusively through the owner actor, including corpus publication.
        let owner = ReconstructionDatabaseOwner(database: database.database,
            attachmentVaultRootURL: vaultRoot)
        _ = try await owner.commitCorpus(workspaceID: database.workspaceUUID,
            mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                successorManifest: manifest, attachmentSources: [
                    .init(contentIdentity: content, verifiedURL: file)]))
        let objective = "Use the offered reconstruction.analysis.macscope.refresh handle exactly once in your first round and choose continue. This schedules a bounded fresh MacScope analysis of the exact offered function. Do not select other handles. Once the next round contains the newly accepted MacScope evidence, select no handles and choose sufficientEvidence. Do not refresh again or declare gaps. Explain only evidence from this authored binary."
        _ = try await owner.commitInitialJob(workspaceID: database.workspaceUUID,
            mutation: .init(jobID: jobID, projectID: projectID,
                selectedOccurrenceIDs: [occurrence.occurrenceID], objective: objective,
                budget: try .init(maxRounds: 4, maxTasks: 128, maxEvidenceRecords: 512,
                    maxEncodedBytes: 4 * 1_024 * 1_024),
                focus: .artifact(.init(occurrenceID: occurrence.occurrenceID,
                    contentIdentity: content))))
        let persistence = ReconstructionDatabaseJobPersistence(workspaceID: database.workspaceUUID,
            owner: owner)
        do {
            _ = try await NativeDecompilerBundleRuntimeAuthorityProvider().attestRuntimeAuthority()
            print("MTPLX_REFRESH_NATIVE bundle_authority=accepted")
        } catch {
            print("MTPLX_REFRESH_NATIVE bundle_authority_error=\(error)")
        }
        let admission = try await ReconstructionNativeDecompilerAdmissionFactory(
            runtime: .productionShared, durable: persistence).admission(forDurableJobID: jobID)
        let native = ReconstructionNativeDecompilerAdapter(admission: admission)
        let controller = ReconstructionProductionBatchExecutionController(durableJobID: jobID,
            builder: { basis, _ in
                var images: [ReconstructionArtifactOccurrenceID: ReconstructionImageBinding] = [:]
                for task in basis.tasks {
                    switch task.identity.subject {
                    case .image(let value): images[value.artifact.occurrenceID] = value.image
                    case .function(let value): images[value.artifact.occurrenceID] = value.image
                    default: break
                    }
                }
                let resolver = try ReconstructionHeadlessAnalysisRequestResolver(manifest: basis.manifest,
                    attachmentSources: basis.attachmentSources, imagesByOccurrence: images)
                let pool = try ReconstructionAnalysisProviderPool(
                    factory: ReconstructionDefaultAnalysisProviderFactory(),
                    budget: .init(maximumActiveAnalyses: 1, estimatedResidentBytesPerAnalysis: 1,
                        reservedHostBytes: 0))
                return ReconstructionBatchScheduler(durableJobID: jobID,
                    executor: RefreshLiveBatchTrace(executor: ReconstructionBatchTaskExecutor(resolver: resolver,
                        headless: ReconstructionHeadlessAnalysisExecutor(pool: pool), native: native)))
            }, retireJobAuthority: { await native.retire() })
        // Explicit qualification identity, not a claim that this Debug host is a Release app.
        let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
            macScopeBuildIdentity: gateDigest(3), macScopeSourceIdentity: gateDigest(4),
            operationIdentity: ReconstructionProductionTaskContract.modelRound,
            registryIdentity: "reconstruction.registry.v1",
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
            toolchainIdentity: "signed-live-test-host"))
        let registry = ReconstructionProductionRoundBasisRegistry()
        let cut = ReconstructionProductionCommittedRoundCutProvider(workspaceID: database.workspaceUUID,
            owner: owner, batchExecutionBuilder: controller,
            preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                evidenceQueryProducer: author.makeToolProducer(operationID: .evidenceQuery),
                analysisRefreshProducer: author.makeToolProducer(operationID: .analysisMacScopeRefresh)),
            basisRegistry: registry, maximumConcurrentTasks: 1)
        let configuration = try Phase2AIProviderConfiguration(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            maximumTokens: 16_384, requestTimeoutMilliseconds: 900_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
        let transport = NSXPCAIAgentTransport(configuration: configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        let provider = ReconstructionXPCInferenceProvider(transport: transport,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR2)
        let inference = RefreshLiveSignedInference(provider: provider, configuration: configuration)
        let planner = ReconstructionProductionJobRoundPlanner(
            materializer: ReconstructionProductionJobRoundMaterializer(cutProvider: cut,
                planBuilder: ReconstructionProductionRoundPlanBuilder(basisRegistry: registry,
                    receiptAuthor: author)), inference: inference, projectors: [
                ReconstructionCheckpointToolProjector(), ReconstructionCorpusToolProjector(),
                ReconstructionDecompilerToolProjector(), ReconstructionEvidenceToolProjector(),
                ReconstructionGapsToolProjector(), ReconstructionImageFunctionToolProjector()])
        do {
            let workerReceipt = try await transport.prepareWorkerProcessReceipt()
            let processAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
            XCTAssertTrue(processAuthority.accepts(receipt: workerReceipt,
                observation: try processAuthority.observe(receipt: workerReceipt)))
            var refreshTaskID: UUID?
            var baselineEvidenceIDs = Set<UUID>()
            for _ in 0..<40 {
                let snapshot = try await persistence.load(jobID: jobID)
                print("MTPLX_REFRESH_STAGE prepare revision=\(snapshot.checkpointRevision) state=\(snapshot.currentDurableJobState) evidence=\(snapshot.evidenceFrontierSHA256)")
                let plan = try await planner.planRound(from: snapshot)
                let mutation = try XCTUnwrap(plan.mutation)
                let calls = await inference.calls
                if calls.count == 1, refreshTaskID == nil {
                    let selected = calls[0].outcome.candidate.selectedHandleIDs
                    let selectedOperations = calls[0].request.handles.filter {
                        selected.contains($0.handleID)
                    }.map { $0.operationID.rawValue }
                    print("MTPLX_REFRESH_CANDIDATE round=1 disposition=\(calls[0].outcome.candidate.disposition) selected_operations=\(selectedOperations) unresolved_gaps=\(calls[0].outcome.candidate.unresolvedGaps.count) resolved_gaps=\(calls[0].outcome.candidate.resolvedGaps.count)")
                    let refresh = try XCTUnwrap(calls[0].request.handles.first {
                        $0.operationID.rawValue == "reconstruction.analysis.macscope.refresh"
                    })
                    XCTAssertEqual(selected, [refresh.handleID])
                    XCTAssertEqual(calls[0].outcome.candidate.disposition, .continue)
                    let task = try XCTUnwrap(mutation.newTasks.first { $0.identity.kind == .decompileMacScope })
                    guard case .function = task.identity.subject else {
                        throw ReconstructionJobCoordinatorFailure.malformedOutput
                    }
                    refreshTaskID = task.identity.taskID
                    XCTAssertTrue(mutation.evidence.isEmpty,
                        "Scheduling acknowledgment cannot fabricate semantic evidence")
                    baselineEvidenceIDs = Set(try await owner.load(workspaceID: database.workspaceUUID)
                        .evidence.map(\.evidenceID))
                }
                print("MTPLX_REFRESH_STAGE commit revision=\(plan.successorRevision) disposition=\(plan.disposition) evidence=\(mutation.evidence.count) new_tasks=\(mutation.newTasks.map(\.identity.kind)) transitions=\(mutation.taskTransitions.map { "\($0.taskID):\($0.expectedState)->\($0.successorState):\($0.diagnostic?.text ?? "")" })")
                _ = try await owner.commit(workspaceID: database.workspaceUUID, mutation: mutation)
                if calls.count == 2 {
                    let taskID = try XCTUnwrap(refreshTaskID)
                    let state = try await owner.load(workspaceID: database.workspaceUUID)
                    XCTAssertEqual(state.tasks.first { $0.identity.taskID == taskID }?.state, .completed)
                    let fresh = state.evidence.filter {
                        $0.creatingTaskID == taskID && !baselineEvidenceIDs.contains($0.evidenceID)
                    }
                    XCTAssertFalse(fresh.isEmpty)
                    XCTAssertTrue(fresh.allSatisfy { $0.classification == .acceptedCurrent })
                    XCTAssertTrue(Set(fresh.map(\.evidenceID)).isSubset(of: Set(calls[1].request.context.evidenceIDs)))
                    XCTAssertNotEqual(calls[0].request.evidenceFrontierSHA256,
                        calls[1].request.evidenceFrontierSHA256)
                    XCTAssertTrue(calls[1].outcome.candidate.selectedHandleIDs.isEmpty)
                    XCTAssertEqual(calls[1].outcome.candidate.disposition, .sufficientEvidence)
                    let workerStillCurrent = await transport.revalidateWorkerProcessReceipt(workerReceipt)
                    XCTAssertTrue(workerStillCurrent)
                    print("MTPLX_REFRESH_LIVE refresh_task=\(taskID) fresh_evidence=\(fresh.map(\.evidenceID)) first_revision=\(calls[0].request.checkpointRevision) next_revision=\(calls[1].request.checkpointRevision)")
                    await provider.finishRequest()
                    await transport.reset()
                    await controller.retire(jobID: jobID)
                    await owner.revoke()
                    return
                }
                switch plan.disposition {
                case .continue, .advancePhase: break
                default:
                    throw ReconstructionJobCoordinatorFailure.malformedOutput
                }
            }
            XCTFail("Bounded production loop did not reach two actual model requests")
            await provider.finishRequest()
            await transport.reset()
            await controller.retire(jobID: jobID)
            await owner.revoke()
        } catch {
            await provider.finishRequest()
            await transport.reset()
            await controller.retire(jobID: jobID)
            await owner.revoke()
            throw error
        }
    }

    /// Actual MTPLX inference, not the test-owned HTTP fixture used by the protocol gates below.
    func testOptInMTPLXSignedR2WorkerCompletesKnownEvidenceRoundAndSynthesis() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_LIVE_CANARY"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_LIVE_CANARY=1 for the installed exact Quality runtime")
        }
        let catalog = try await Phase2NativeModelDiscoveryHTTPClient().discover(
            at: .init(validating: "http://127.0.0.1:8000"), provider: .mtplx)
        XCTAssertEqual(catalog.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
        XCTAssertEqual(catalog.models.first?.loadedInstances.first?.configuration.contextLength, 65_536)
        let bundle = Phase2AIWorkerProductionProtocol.reconstructionR2
        let configuration = try Phase2AIProviderConfiguration(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            maximumTokens: 4_096, requestTimeoutMilliseconds: 300_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
        let transport = NSXPCAIAgentTransport(configuration: configuration, protocolBundle: bundle)
        let provider = ReconstructionXPCInferenceProvider(transport: transport, protocolBundle: bundle)
        do {
            let receipt = try await transport.prepareWorkerProcessReceipt()
            XCTAssertEqual(receipt.protocolManifestDigest, bundle.manifestDigest)
            let processAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
                expectedProtocolManifestDigest: bundle.manifestDigest)
            let initialProcess = try processAuthority.observe(receipt: receipt)
            XCTAssertTrue(processAuthority.accepts(receipt: receipt, observation: initialProcess))

            let jobID = UUID(), evidenceID = UUID()
            // Explicit synthetic evidence: no claim of a loaded binary, native analysis or model receipt.
            let context = try r2SignedContext(jobID: jobID, evidenceID: evidenceID)
            let text = "Explain only the supplied synthetic pseudocode return input + 1. State its result for input 7. Start the final synthesis text with a line exactly formatted Result: <integer>, substituting the computed integer. The evidence is sufficient; no tools or gaps are needed. Cite the supplied evidence ID."
            let objective = try ReconstructionRequestObjective(jobID: jobID, text: text,
                sha256: signedDigest(Data(text.utf8)))
            let round = ReconstructionInferenceRoundRequest(
                protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
                jobID: jobID, checkpointRevision: 7, roundID: UUID(),
                corpusManifestSHA256: gateDigest(1), evidenceFrontierSHA256: gateDigest(2),
                registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.makeR2().toolRegistry.identity.sha256,
                context: context, handles: [.init(handleID: UUID(), operationID: .evidenceQuery)])
            let roundRequestID = UUID()
            let boundRound = ReconstructionAIWorkerRequest.roundR2(.init(
                protocolVersion: 9, objective: objective, request: round))
            let projection = try ReconstructionReadablePromptProjection().projectR2(boundRound)
            XCTAssertTrue(projection.userText.contains("return input + 1;"))
            XCTAssertTrue(projection.userText.contains(evidenceID.uuidString))
            XCTAssertTrue(projection.userText.contains(objective.sha256))
            let outcome = try await ReconstructionInferenceRunner().run(requestID: roundRequestID,
                request: round, provider: provider, objective: objective)
            XCTAssertEqual(outcome.candidate.jobID, jobID)
            XCTAssertEqual(outcome.candidate.roundID, round.roundID)
            XCTAssertEqual(outcome.candidate.checkpointRevision, 7)
            XCTAssertEqual(outcome.candidate.disposition, .sufficientEvidence)
            XCTAssertTrue(outcome.candidate.selectedHandleIDs.isEmpty)
            XCTAssertTrue(outcome.candidate.unresolvedGaps.isEmpty)
            XCTAssertTrue(outcome.candidate.resolvedGaps.isEmpty)
            XCTAssertEqual(outcome.terminalReceipt.status, .completed)
            let roundAuthority = try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: roundRequestID, request: boundRound, terminalReceipt: outcome.terminalReceipt)
            XCTAssertEqual(roundAuthority.requestIdentitySHA256, projection.canonicalAuthorityRequestSHA256)
            await provider.cancel(requestID: roundRequestID)

            let final = ReconstructionFinalSynthesisRequest(jobID: jobID, checkpointRevision: 8,
                corpusManifestSHA256: gateDigest(1), evidenceFrontierSHA256: gateDigest(2),
                acceptedEvidenceIDs: [evidenceID], context: context)
            let finalRequestID = UUID()
            let synthesis = try await ReconstructionInferenceRunner().synthesize(requestID: finalRequestID,
                request: final, provider: provider, objective: objective)
            XCTAssertEqual(synthesis.candidate.kind, .synthesis)
            XCTAssertEqual(synthesis.candidate.evidenceIDs, [evidenceID])
            XCTAssertEqual(synthesis.candidate.text.split(separator: "\n").first.map(String.init),
                "Result: 8", "Known synthetic input 7 must produce exactly 8, not an incidental digit")
            XCTAssertEqual(synthesis.terminalReceipt.status, .completed)
            _ = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: finalRequestID,
                request: .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: final)),
                terminalReceipt: synthesis.terminalReceipt)
            let stillCurrent = await transport.revalidateWorkerProcessReceipt(receipt)
            XCTAssertTrue(stillCurrent)
            XCTAssertEqual(try processAuthority.observe(receipt: receipt), initialProcess)
            print("MTPLX_LIVE_R2 round_usage=\(outcome.usage) final_usage=\(synthesis.usage) evidence=\(evidenceID) answer=\(synthesis.candidate.text)")
            await provider.cancel(requestID: finalRequestID)
            await provider.finishRequest()
            await transport.reset()
        } catch {
            await provider.finishRequest()
            await transport.reset()
            throw error
        }
    }

    func testSignedR2WorkerDispatchesReadableObjectiveAndEvidenceThenAcceptsExactSemantics() async throws {
        let fixture = try await LiveChatFixture.start(mode: .reconstructionR2)
        defer { fixture.stopExactOwnedProcessIfNeeded() }
        let bundle = Phase2AIWorkerProductionProtocol.reconstructionR2
        let configuration = try Phase2AIProviderConfiguration(
            profileID: gateID(400), generation: 1,
            endpointOrigin: "http://127.0.0.1:\(fixture.port)", model: "test-reconstruction-r2-model",
            maximumTokens: 512, requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000, inferencePolicy: .init()
        )
        let transport = NSXPCAIAgentTransport(configuration: configuration, protocolBundle: bundle)
        let provider = ReconstructionXPCInferenceProvider(transport: transport, protocolBundle: bundle)
        let workerReceipt = try await transport.prepareWorkerProcessReceipt()
        XCTAssertEqual(workerReceipt.protocolManifestDigest, bundle.manifestDigest)
        let processAuthority = try Phase2LiveAIAgentWorkerProcessAuthority.resolveFromTestHost(
            expectedProtocolManifestDigest: bundle.manifestDigest
        )
        let initialProcess = try processAuthority.observe(receipt: workerReceipt)
        XCTAssertTrue(processAuthority.accepts(receipt: workerReceipt, observation: initialProcess))

        let jobID = gateID(401)
        let evidenceID = gateID(402)
        let handleID = gateID(403)
        let context = try r2SignedContext(jobID: jobID, evidenceID: evidenceID)
        let objectiveText = "Recover the exact arithmetic behavior: return input + 1; preserve α."
        let objective = try ReconstructionRequestObjective(jobID: jobID, text: objectiveText,
            sha256: signedDigest(Data(objectiveText.utf8)))
        let round = ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: jobID, checkpointRevision: 7, roundID: gateID(404),
            corpusManifestSHA256: gateDigest(1), evidenceFrontierSHA256: gateDigest(2),
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.makeR2().toolRegistry.identity.sha256,
            context: context, handles: [.init(handleID: handleID, operationID: .evidenceQuery)]
        )
        let roundRequestID = gateID(405)
        let outcome = try await ReconstructionInferenceRunner().run(
            requestID: roundRequestID, request: round, provider: provider, objective: objective
        )
        XCTAssertEqual(outcome.candidate.selectedHandleIDs, [handleID])
        XCTAssertEqual(outcome.candidate.disposition, .sufficientEvidence)
        XCTAssertEqual(outcome.candidate.jobID, jobID)
        XCTAssertEqual(outcome.candidate.roundID, round.roundID)
        XCTAssertEqual(outcome.candidate.checkpointRevision, 7)
        XCTAssertEqual(outcome.candidate.unresolvedGaps, [])
        XCTAssertEqual(outcome.candidate.resolvedGaps, [])
        XCTAssertEqual(outcome.usage, .init(promptTokens: 11, completionTokens: 5, totalTokens: 16))
        XCTAssertEqual(outcome.terminalReceipt.status, .completed)
        let boundRound = ReconstructionAIWorkerRequest.roundR2(.init(
            protocolVersion: 9, objective: objective, request: round))
        let roundAuthority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: roundRequestID, request: boundRound,
            terminalReceipt: outcome.terminalReceipt)
        await provider.cancel(requestID: roundRequestID)

        let final = ReconstructionFinalSynthesisRequest(jobID: jobID, checkpointRevision: 8,
            corpusManifestSHA256: gateDigest(1), evidenceFrontierSHA256: gateDigest(2),
            acceptedEvidenceIDs: [evidenceID], context: context)
        let finalRequestID = gateID(406)
        let synthesis = try await ReconstructionInferenceRunner().synthesize(
            requestID: finalRequestID, request: final, provider: provider, objective: objective
        )
        XCTAssertEqual(synthesis.candidate.kind, .synthesis)
        XCTAssertEqual(synthesis.candidate.text, "The supplied pseudocode returns input + 1.")
        XCTAssertEqual(synthesis.candidate.evidenceIDs, [evidenceID])
        XCTAssertEqual(synthesis.usage, .init(promptTokens: 13, completionTokens: 7, totalTokens: 20))
        XCTAssertEqual(synthesis.terminalReceipt.status, .completed)
        let finalAuthority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: finalRequestID,
            request: .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: final)),
            terminalReceipt: synthesis.terminalReceipt)
        let stillCurrent = await transport.revalidateWorkerProcessReceipt(workerReceipt)
        XCTAssertTrue(stillCurrent)
        XCTAssertEqual(try processAuthority.observe(receipt: workerReceipt), initialProcess)
        await provider.cancel(requestID: finalRequestID)
        await provider.finishRequest()

        let summary = try fixture.waitForExactCompletion()
        XCTAssertEqual(summary.requestCount, 2, "R2 must not retry or initiate another operation")
        XCTAssertEqual(summary.methods, ["POST", "POST"])
        XCTAssertEqual(summary.paths, ["/v1/chat/completions", "/v1/chat/completions"])
        XCTAssertEqual(summary.streams, [true, true])
        XCTAssertEqual(summary.hasTools, [false, false])
        XCTAssertEqual(summary.hasResponseFormat, [true, true])
        XCTAssertEqual(summary.requestBodies.count, 2)
        for (index, bytes) in summary.requestBodies.enumerated() {
            XCTAssertLessThanOrEqual(bytes.count, ReconstructionReadablePromptProjection.maximumEncodedProviderBodyBytes)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertNil(body["tools"])
            XCTAssertNil(body["tool_choice"])
            XCTAssertNil(body["parallel_tool_calls"])
            let metadata = try XCTUnwrap(body["metadata"] as? [String: String])
            XCTAssertEqual(metadata, ["cache_mode": "stateless"])
            XCTAssertEqual(body["generation_mode"] as? String, "mtp")
            XCTAssertNil(body["enable_thinking"], "MTPLX applies the model's own thinking setting")
            XCTAssertNil(body["reasoning_effort"], "MTPLX applies the model's own reasoning effort")
            XCTAssertNil(body["depth"])
            XCTAssertEqual(body["model"] as? String, configuration.model)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let text = try XCTUnwrap(messages.last?["content"] as? String)
            let user = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(user["domain"] as? String, "reconstruction.readable-prompt.r2.v1")
            XCTAssertEqual(user["requestProtocolVersion"] as? Int, 9)
            let capturedObjective = try XCTUnwrap(user["objective"] as? [String: Any])
            XCTAssertEqual(capturedObjective["jobID"] as? String, jobID.uuidString)
            XCTAssertEqual(capturedObjective["text"] as? String, objectiveText)
            XCTAssertEqual(capturedObjective["sha256"] as? String, objective.sha256)
            XCTAssertEqual(user["canonicalAuthorityRequestSHA256"] as? String,
                index == 0 ? roundAuthority.requestIdentitySHA256 : finalAuthority.requestIdentitySHA256)
            let request = try XCTUnwrap(user["authorityRequestProjection"] as? [String: Any])
            let projectedContext = try XCTUnwrap(request["context"] as? [String: Any])
            XCTAssertNil(projectedContext["canonicalBytes"])
            let readable = try XCTUnwrap(user["readableContext"] as? [String: Any])
            XCTAssertNil(readable["retrievalPacket"])
            let packet = try XCTUnwrap(readable["readableRetrievalPacket"] as? [String: Any])
            let rows = try XCTUnwrap(packet["records"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            let record = try XCTUnwrap(rows.first?["record"] as? [String: Any])
            XCTAssertEqual(record["evidenceID"] as? String, evidenceID.uuidString)
            XCTAssertNil(record["payload"])
            let payload = try XCTUnwrap(record["readablePayload"] as? [String: Any])
            XCTAssertEqual(payload["representation"] as? String, "json")
            let value = try XCTUnwrap(payload["value"] as? [String: Any])
            XCTAssertEqual(value["pseudocode"] as? String, "return input + 1;")
            if index == 0 {
                let handles = try XCTUnwrap(request["handles"] as? [[String: Any]])
                XCTAssertEqual(handles.count, 1)
                XCTAssertEqual(handles.first?["handleID"] as? String, handleID.uuidString)
                XCTAssertEqual(handles.first?["operationID"] as? String, ReconstructionOperationID.evidenceQuery.rawValue)
                let actions = try XCTUnwrap(user["offeredActions"] as? [[String: Any]])
                XCTAssertEqual(actions.count, 1)
                XCTAssertEqual(actions.first?["handleID"] as? String, handleID.uuidString)
                XCTAssertEqual(actions.first?["operationID"] as? String, ReconstructionOperationID.evidenceQuery.rawValue)
                XCTAssertEqual(actions.first?["selectionChannel"] as? String, "selected_handle_ids")
                XCTAssertEqual(actions.first?["execution"] as? String, "offeredForRead")
                XCTAssertFalse(try XCTUnwrap(actions.first?["description"] as? String).isEmpty)
            } else {
                XCTAssertNil(user["offeredActions"])
                XCTAssertEqual(request["acceptedEvidenceIDs"] as? [String], [evidenceID.uuidString])
            }
        }
        XCTAssertFalse(fixture.isRunning)
    }

    private func signedDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func r2SignedContext(jobID: UUID, evidenceID: UUID) throws -> ReconstructionRetrievedContext {
        let payload = Data(#"{"pseudocode":"return input + 1;"}"#.utf8)
        let producer = try ReconstructionProducerIdentity(macScopeBuildIdentity: "signed-test-fixture",
            macScopeSourceIdentity: "fixture-source", operationIdentity: ReconstructionOperationID.decompilerMacScope.rawValue,
            registryIdentity: "fixture-registry", protocolIdentity: "fixture-protocol", canonicalSHA256: gateDigest(3))
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: gateID(407)),
            contentIdentity: try .init(algorithm: .sha256, digest: gateDigest(4), byteCount: 8))
        let record = try ReconstructionEvidenceRecord(evidenceID: evidenceID, subject: .artifact(artifact),
            operationID: ReconstructionOperationID.decompilerMacScope.rawValue, payloadKind: .structuredJSON,
            payload: payload, payloadByteCount: UInt64(payload.count), payloadSHA256: signedDigest(payload),
            facetDependencies: [], producer: producer, citations: [], creatingJobID: jobID,
            creatingTaskID: gateID(408), creatingCheckpointID: gateID(409), modelReceiptID: nil,
            toolReceiptID: gateID(410), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let recordObject = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(record))
        let packet = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "domain": "reconstruction.evidence-retrieval-packet.v1",
            "corpusManifestSHA256": gateDigest(1), "evidenceFrontierSHA256": gateDigest(2),
            "queryIdentitySHA256": gateDigest(5), "hasMore": false,
            "records": [["record": recordObject, "classification": "acceptedCurrent", "checkpointRevision": 7]],
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 8, "domain": "reconstruction.context.v8",
            "corpusManifestSHA256": gateDigest(1), "evidenceFrontierSHA256": gateDigest(2),
            "retrievalPacket": packet.base64EncodedString(), "retrievalPacketSHA256": signedDigest(packet),
            "evidenceIDs": [evidenceID.uuidString], "allowedGapSubjects": [],
            "allowedGapCategories": [], "allowedGapIDs": [],
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        return .init(canonicalBytes: bytes, canonicalSHA256: signedDigest(bytes), evidenceIDs: [evidenceID])
    }

    func testSignedWorkerCompletesReconstructionRoundThenFinalSynthesisExactlyOnce() async throws {
        let fixture = try await LiveChatFixture.start(mode: .reconstruction)
        defer { fixture.stopExactOwnedProcessIfNeeded() }

        let configuration = try Phase2AIProviderConfiguration(
            profileID: gateID(300),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:\(fixture.port)",
            model: "test-reconstruction-model",
            maximumTokens: 512,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000, inferencePolicy: .init()
        )
        let transport = NSXPCAIAgentTransport(
            configuration: configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR1
        )
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let workerReceipt = try await transport.prepareWorkerProcessReceipt()
        XCTAssertGreaterThan(workerReceipt.processIdentifier, 1)
        XCTAssertEqual(
            workerReceipt.protocolManifestDigest,
            Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
        )
        let workerProcessAuthority = try Phase2LiveAIAgentWorkerProcessAuthority
            .resolveFromTestHost()
        let initialWorkerProcess = try workerProcessAuthority.observe(
            receipt: workerReceipt
        )
        XCTAssertTrue(
            workerProcessAuthority.accepts(
                receipt: workerReceipt,
                observation: initialWorkerProcess
            )
        )

        let contextBytes = Data(#"{"records":[]}"#.utf8)
        let context = ReconstructionRetrievedContext(
            canonicalBytes: contextBytes,
            canonicalSHA256:
                "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432",
            evidenceIDs: []
        )
        let jobID = gateID(301)
        let roundID = gateID(302)
        let handleID = gateID(303)
        let roundRequestID = gateID(304)
        let round = ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2AIWorkerProductionProtocol.reconstructionR1.inferenceVersion,
            jobID: jobID,
            checkpointRevision: 7,
            roundID: roundID,
            corpusManifestSHA256: gateDigest(1),
            evidenceFrontierSHA256: gateDigest(2),
            registryManifestSHA256:
                Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
            context: context,
            handles: [.init(handleID: handleID, operationID: .corpusSummary)]
        )
        let roundEvents = ReconstructionGateEventCollector()
        let roundReceipt = try await provider.runRound(
            requestID: roundRequestID,
            request: round
        ) { event in
            await roundEvents.append(event)
        }
        let capturedRoundEvents = await roundEvents.events
        XCTAssertEqual(capturedRoundEvents.count, 3)
        guard capturedRoundEvents.count == 3,
              case .roundCandidate(let roundCandidate) = capturedRoundEvents[0].body
        else { return XCTFail("reconstruction round must emit one candidate first") }
        XCTAssertEqual(roundCandidate.jobID, jobID)
        XCTAssertEqual(roundCandidate.checkpointRevision, 7)
        XCTAssertEqual(roundCandidate.roundID, roundID)
        XCTAssertEqual(roundCandidate.selectedHandleIDs, [handleID])
        XCTAssertEqual(roundCandidate.disposition, .sufficientEvidence)
        XCTAssertEqual(roundCandidate.unresolvedGaps, [])
        XCTAssertEqual(roundCandidate.resolvedGaps, [])
        XCTAssertEqual(
            capturedRoundEvents[1].body,
            .usage(.init(promptTokens: 11, completionTokens: 5, totalTokens: 16))
        )
        XCTAssertEqual(capturedRoundEvents[2].body, .completed)
        XCTAssertEqual(
            roundReceipt,
            .init(
                requestID: roundRequestID,
                jobID: jobID,
                checkpointRevision: 7,
                roundID: roundID,
                status: .completed
            )
        )

        // Completion is terminal for the round. Cleanup cancellation must neither retry the
        // round nor implicitly initiate final synthesis.
        await provider.cancel(requestID: roundRequestID)

        let finalRequestID = gateID(305)
        let final = ReconstructionFinalSynthesisRequest(
            jobID: jobID,
            checkpointRevision: 7,
            corpusManifestSHA256: gateDigest(1),
            evidenceFrontierSHA256: gateDigest(2),
            acceptedEvidenceIDs: [],
            context: context
        )
        let finalEvents = ReconstructionGateEventCollector()
        let finalReceipt = try await provider.runFinalSynthesis(
            requestID: finalRequestID,
            request: final
        ) { event in
            await finalEvents.append(event)
        }
        let capturedFinalEvents = await finalEvents.events
        XCTAssertEqual(capturedFinalEvents.count, 3)
        guard capturedFinalEvents.count == 3,
              case .finalCandidate(let finalCandidate) = capturedFinalEvents[0].body
        else { return XCTFail("reconstruction final synthesis must emit one candidate first") }
        XCTAssertEqual(finalCandidate.kind, .insufficientEvidence)
        XCTAssertEqual(finalCandidate.text, "No accepted reconstruction evidence was supplied.")
        XCTAssertEqual(finalCandidate.evidenceIDs, [])
        XCTAssertEqual(
            capturedFinalEvents[1].body,
            .usage(.init(promptTokens: 13, completionTokens: 7, totalTokens: 20))
        )
        XCTAssertEqual(capturedFinalEvents[2].body, .completed)
        XCTAssertEqual(
            finalReceipt,
            .init(
                requestID: finalRequestID,
                jobID: jobID,
                checkpointRevision: 7,
                roundID: nil,
                status: .completed
            )
        )

        let workerReceiptIsStillCurrent = await transport.revalidateWorkerProcessReceipt(
            workerReceipt
        )
        XCTAssertTrue(workerReceiptIsStillCurrent)
        let finalWorkerProcess = try workerProcessAuthority.observe(
            receipt: workerReceipt
        )
        XCTAssertEqual(finalWorkerProcess, initialWorkerProcess)
        XCTAssertTrue(
            workerProcessAuthority.accepts(
                receipt: workerReceipt,
                observation: finalWorkerProcess
            )
        )
        await provider.cancel(requestID: finalRequestID)
        await transport.reset()

        let summary = try fixture.waitForExactCompletion()
        XCTAssertEqual(summary.requestCount, 2, "neither reconstruction phase may retry")
        XCTAssertEqual(summary.paths, ["/v1/chat/completions", "/v1/chat/completions"])
        XCTAssertEqual(summary.hasTools, [true, false])
        XCTAssertEqual(summary.hasResponseFormat, [true, true])
        XCTAssertEqual(summary.hasTopP, [false, false], "MTPLX applies the model's own sampling")
        XCTAssertEqual(summary.hasTemperature, [false, false])
        XCTAssertEqual(summary.streams, [true, true])
        XCTAssertEqual(summary.methods, ["POST", "POST"])
        XCTAssertFalse(fixture.isRunning)
    }

    func testSignedWorkerCompletesSelectionThenSeparatelyInitiatedFinalizationExactlyOnce() async throws {
        let handshake = try await fetchLiveHandshake()
        XCTAssertEqual(
            handshake.wireProtocol,
            Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity
        )
        XCTAssertEqual(
            handshake.inferenceProtocol,
            Phase2AIWorkerProductionProtocol.assistantR4.inferenceIdentity
        )
        XCTAssertEqual(
            handshake.manifestIdentity,
            Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity
        )
        XCTAssertEqual(handshake.status, .ready)

        let fixture = try await LiveChatFixture.start()
        defer { fixture.stopExactOwnedProcessIfNeeded() }

        let configuration = try Phase2AIProviderConfiguration(
            profileID: gateID(100),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:\(fixture.port)",
            model: "test-model",
            maximumTokens: 512,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000, inferencePolicy: .init()
        )
        let transport = NSXPCAIAgentTransport(configuration: configuration)
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let context = try Phase2GroundedContextCompiler().compile(
            records: [],
            currentStateByEvidenceID: [:]
        )
        let handleID = gateID(200)

        let selection = makeRequest(
            phase: .toolSelection,
            requestID: gateID(10),
            context: context,
            toolHandles: [.init(handleID: handleID, operationID: .workspaceSummary)]
        )
        let selectionEvents = try await collect(provider: provider, request: selection)
        guard selectionEvents.count == 3 else {
            XCTFail("assistantR4 selection must emit one proposal, usage, then awaiting-tools")
            return
        }
        guard case .toolProposal(let proposal) = selectionEvents[0].body else {
            return XCTFail("selection must emit the validated proposal first")
        }
        XCTAssertEqual(proposal.callID.rawValue, "opaque/live-call-β")
        XCTAssertEqual(proposal.handleID, handleID)
        XCTAssertEqual(proposal.functionName, "macscope_workspace_summary_v1")
        XCTAssertEqual(proposal.operationID, .workspaceSummary)
        XCTAssertEqual(
            selectionEvents[1].body,
            .usage(Phase2ProviderUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)!)
        )
        XCTAssertEqual(selectionEvents[2].body, .awaitingTools)

        // Awaiting-tools is terminal for this request. A late cancellation is cleanup only and
        // must not retry selection, execute a read, or initiate finalization implicitly.
        await provider.cancel(requestID: selection.requestID)

        let finalization = makeRequest(
            phase: .finalization,
            requestID: gateID(11),
            context: context,
            toolHandles: []
        )
        let finalEvents = try await collect(provider: provider, request: finalization)
        guard finalEvents.count == 3 else {
            XCTFail("assistantR4 finalization must emit one candidate, usage, then completion")
            return
        }
        guard case .finalCandidate(let candidate) = finalEvents[0].body else {
            return XCTFail("finalization must emit one strict terminal candidate")
        }
        XCTAssertEqual(candidate.kind, .insufficientEvidence)
        XCTAssertEqual(candidate.text, "No grounded evidence was supplied.")
        XCTAssertEqual(candidate.evidenceIDs, [])
        XCTAssertEqual(
            finalEvents[1].body,
            .usage(Phase2ProviderUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)!)
        )
        XCTAssertEqual(finalEvents[2].body, .completed)

        await provider.cancel(requestID: finalization.requestID)
        await provider.resetConnection()

        let summary = try fixture.waitForExactCompletion()
        XCTAssertEqual(summary.requestCount, 2, "neither phase may retry")
        XCTAssertEqual(summary.paths, ["/v1/chat/completions", "/v1/chat/completions"])
        XCTAssertEqual(summary.hasTools, [true, true])
        XCTAssertEqual(summary.hasResponseFormat, [false, true])
        XCTAssertEqual(summary.hasTopP, [false, false], "MTPLX applies the model's own sampling")
        XCTAssertEqual(summary.methods, ["POST", "POST"])
        XCTAssertFalse(fixture.isRunning)
    }

    private func fetchLiveHandshake() async throws -> Phase2AIWorkerHandshake {
        let connection = NSXPCConnection(serviceName: "org.macscope.app.AIAgentWorker")
        let interface = NSXPCInterface(with: Phase2AIWorkerXPCProtocol.self)
        interface.setInterface(
            NSXPCInterface(with: Phase2AIWorkerEventSinkXPCProtocol.self),
            for: #selector(Phase2AIWorkerXPCProtocol.run(requestData:requestID:eventSink:)),
            argumentIndex: 2,
            ofReply: false
        )
        connection.remoteObjectInterface = interface
        connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let once = GateOneShot<Phase2AIWorkerHandshake>(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(.failure(error))
            }) as? Phase2AIWorkerXPCProtocol else {
                once.resume(.failure(LiveGateError.missingWorkerProxy))
                return
            }
            proxy.handshake { data in
                do {
                    once.resume(.success(try Phase2AIWorkerWireCodec().decodeHandshake(data)))
                } catch {
                    once.resume(.failure(error))
                }
            }
        }
    }

    private func collect(
        provider: AIAgentXPCInferenceProvider,
        request: Phase2InferenceRequest
    ) async throws -> [Phase2InferenceEvent] {
        let collector = GateEventCollector()
        try await provider.run(request: request) { event in
            await collector.append(event)
        }
        return await collector.events
    }

    private func makeRequest(
        phase: Phase2InferencePhase,
        requestID: UUID,
        context: Phase2GroundedContext,
        toolHandles: [Phase2InferenceToolHandle]
    ) -> Phase2InferenceRequest {
        let document = Phase2ReadDocumentIdentity(instanceID: gateID(1))
        return .init(
            protocolVersion: .init(
                rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
            ),
            phase: phase,
            sessionID: gateID(2),
            turnID: gateID(3),
            requestID: requestID,
            document: document,
            workspace: .init(document: document, instanceID: gateID(4)),
            lifecycleRevision: 5,
            userGoal: "Explain the selected function using only authorized evidence.",
            groundedContext: context,
            toolHandles: toolHandles,
            conversationContext: .init(turns: [], omittedTurnCount: 0),
            limits: .maximum
        )
    }
}

struct Phase2LiveAIAgentWorkerExecutableIdentity: Equatable, Sendable {
    let canonicalPath: String
    let sha256: String
    let cdHash: String

    var isWellFormed: Bool {
        !canonicalPath.isEmpty
            && canonicalPath.utf8.count <= 4_096
            && !canonicalPath.contains("\0")
            && canonicalPath.first == "/"
            && URL(fileURLWithPath: canonicalPath).standardizedFileURL.path
                == canonicalPath
            && phase2IsSHA256Hex(sha256)
            && [40, 64].contains(cdHash.utf8.count)
            && cdHash.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
    }
}

struct Phase2LiveAIAgentWorkerProcessObservation: Equatable, Sendable {
    /// Test-execution-only state. The PID and process-start identity are never serialized into
    /// the Gate F receipt, execution report, or any persisted workspace authority.
    let processIdentifier: Int32
    let startIdentity: Phase2QualificationProcessStartIdentity
    let executableIdentity: Phase2LiveAIAgentWorkerExecutableIdentity
    let signingRequirementAccepted: Bool
}

enum Phase2LiveAIAgentWorkerProcessIdentityBinding {
    static func accepts(
        receipt: AIAgentXPCWorkerProcessReceipt,
        expectedProtocolManifestDigest: String,
        expectedExecutableIdentity: Phase2LiveAIAgentWorkerExecutableIdentity,
        observation: Phase2LiveAIAgentWorkerProcessObservation
    ) -> Bool {
        receipt.processIdentifier > 1
            && receipt.processIdentifier == observation.processIdentifier
            && receipt.protocolManifestDigest == expectedProtocolManifestDigest
            && observation.startIdentity.isValid
            && observation.signingRequirementAccepted
            && expectedExecutableIdentity.isWellFormed
            && observation.executableIdentity == expectedExecutableIdentity
            && observation.executableIdentity.isWellFormed
    }
}

final class Phase2LiveAIAgentWorkerProcessAuthority: @unchecked Sendable {
    private static let appIdentifier = "org.macscope.app"
    private static let workerIdentifier = "org.macscope.app.AIAgentWorker"
    private static let workerBundleRelativePath =
        "Contents/XPCServices/AIAgentWorkerXPCService.xpc"
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)
    private static let considerExpirationFlag: UInt32 = 0x8000_0000
    private static let noNetworkAccessFlag: UInt32 = 0x2000_0000

    private let expectedProtocolManifestDigest: String
    private let expectedExecutableIdentity: Phase2LiveAIAgentWorkerExecutableIdentity
    private let workerRequirement: SecRequirement

    private init(
        expectedProtocolManifestDigest: String,
        expectedExecutableIdentity: Phase2LiveAIAgentWorkerExecutableIdentity,
        workerRequirement: SecRequirement
    ) {
        self.expectedProtocolManifestDigest = expectedProtocolManifestDigest
        self.expectedExecutableIdentity = expectedExecutableIdentity
        self.workerRequirement = workerRequirement
    }

    static func resolveFromTestHost(
        expectedProtocolManifestDigest: String = Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
    ) throws -> Self {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard appURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == appIdentifier
        else { throw Phase2LiveAIAgentWorkerProcessIdentityError.invalidTestHost }

        let lexicalWorkerBundleURL = appURL.appendingPathComponent(
            workerBundleRelativePath,
            isDirectory: true
        ).standardizedFileURL
        let workerBundleURL = lexicalWorkerBundleURL
            .resolvingSymlinksInPath().standardizedFileURL
        guard lexicalWorkerBundleURL.path == workerBundleURL.path,
              workerBundleURL.path.hasPrefix(appURL.path + "/"),
              let workerBundle = Bundle(url: workerBundleURL),
              workerBundle.bundleIdentifier == workerIdentifier,
              let lexicalExecutableURL = workerBundle.executableURL?.standardizedFileURL
        else { throw Phase2LiveAIAgentWorkerProcessIdentityError.invalidEmbeddedWorker }
        let executableURL = lexicalExecutableURL
            .resolvingSymlinksInPath().standardizedFileURL
        guard lexicalExecutableURL.path == executableURL.path,
              executableURL.lastPathComponent == "AIAgentWorkerXPCService",
              executableURL.path.hasPrefix(workerBundleURL.path + "/")
        else { throw Phase2LiveAIAgentWorkerProcessIdentityError.invalidEmbeddedWorker }

        let requirement = try makeWorkerRequirement()
        let staticCode = try makeStaticCode(at: workerBundleURL)
        try validateStaticCode(staticCode, requirement: requirement)
        let expectedIdentity = Phase2LiveAIAgentWorkerExecutableIdentity(
            canonicalPath: executableURL.path,
            sha256: try fileSHA256(executableURL),
            cdHash: try cdHash(of: staticCode)
        )
        guard expectedIdentity.isWellFormed else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.identityMismatch
        }
        return .init(
            expectedProtocolManifestDigest: expectedProtocolManifestDigest,
            expectedExecutableIdentity: expectedIdentity,
            workerRequirement: requirement
        )
    }

    func observe(
        receipt: AIAgentXPCWorkerProcessReceipt
    ) throws -> Phase2LiveAIAgentWorkerProcessObservation {
        let processIdentifier = receipt.processIdentifier
        let observer = Phase2QualificationLibprocProcessObserver()
        guard processIdentifier > 1,
              let beforePath = Self.processExecutablePath(processIdentifier),
              let beforeProcess = try observer.observation(
                processID: processIdentifier
              ),
              let middlePath = Self.processExecutablePath(processIdentifier),
              beforePath == middlePath,
              beforeProcess.processID == processIdentifier
        else { throw Phase2LiveAIAgentWorkerProcessIdentityError.processUnavailable }

        let dynamicCDHash = try authenticateDynamicProcess(processIdentifier)
        guard let afterProcess = try observer.observation(processID: processIdentifier),
              let afterPath = Self.processExecutablePath(processIdentifier),
              middlePath == afterPath,
              beforeProcess.hasSameIdentity(as: afterProcess)
        else { throw Phase2LiveAIAgentWorkerProcessIdentityError.processUnavailable }
        let observation = Phase2LiveAIAgentWorkerProcessObservation(
            processIdentifier: processIdentifier,
            startIdentity: afterProcess.startIdentity,
            executableIdentity: .init(
                canonicalPath: afterPath,
                sha256: afterProcess.executableIdentity.sha256,
                cdHash: dynamicCDHash
            ),
            signingRequirementAccepted: true
        )
        guard accepts(receipt: receipt, observation: observation) else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.identityMismatch
        }
        return observation
    }

    func accepts(
        receipt: AIAgentXPCWorkerProcessReceipt,
        observation: Phase2LiveAIAgentWorkerProcessObservation
    ) -> Bool {
        Phase2LiveAIAgentWorkerProcessIdentityBinding.accepts(
            receipt: receipt,
            expectedProtocolManifestDigest: expectedProtocolManifestDigest,
            expectedExecutableIdentity: expectedExecutableIdentity,
            observation: observation
        )
    }

    private func authenticateDynamicProcess(_ processIdentifier: Int32) throws -> String {
        var dynamicCode: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier),
        ] as CFDictionary
        let lookupStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        )
        guard lookupStatus == errSecSuccess, let dynamicCode else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(
                lookupStatus
            )
        }
        let dynamicFlags = SecCSFlags(
            rawValue: Self.considerExpirationFlag | Self.noNetworkAccessFlag
        )
        let dynamicStatus = SecCodeCheckValidityWithErrors(
            dynamicCode,
            dynamicFlags,
            workerRequirement,
            nil
        )
        guard dynamicStatus == errSecSuccess else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(
                dynamicStatus
            )
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(),
            &staticCode
        )
        guard staticStatus == errSecSuccess, let staticCode else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(
                staticStatus
            )
        }
        try Self.validateStaticCode(staticCode, requirement: workerRequirement)
        return try Self.cdHash(of: staticCode)
    }

    private static func makeWorkerRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            Phase2AIWorkerPeerRequirement.worker as CFString,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(status)
        }
        return requirement
    }

    private static func makeStaticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(status)
        }
        return code
    }

    private static func validateStaticCode(
        _ code: SecStaticCode,
        requirement: SecRequirement
    ) throws {
        let flags = SecCSFlags(
            rawValue:
                UInt32(kSecCSCheckAllArchitectures)
                | UInt32(kSecCSCheckNestedCode)
                | UInt32(kSecCSStrictValidate)
                | UInt32(kSecCSRestrictSymlinks)
                | UInt32(kSecCSRestrictSidebandData)
                | considerExpirationFlag
                | noNetworkAccessFlag
        )
        let status = SecStaticCodeCheckValidityWithErrors(
            code,
            flags,
            requirement,
            nil
        )
        guard status == errSecSuccess else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(status)
        }
    }

    private static func cdHash(of code: SecStaticCode) throws -> String {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information
        )
        guard status == errSecSuccess else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.securityFailure(status)
        }
        guard let values = information as? [String: Any],
              let value = values[kSecCodeInfoUnique as String] as? Data
        else {
            throw Phase2LiveAIAgentWorkerProcessIdentityError.identityMismatch
        }
        return value.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func processExecutablePath(_ processIdentifier: Int32) -> String? {
        var path = [CChar](repeating: 0, count: pathBufferSize)
        let count = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(processIdentifier, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0, Int(count) < path.count else { return nil }
        path[Int(count)] = 0
        let bytes = path.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        let lexical = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            .standardizedFileURL
        let canonical = lexical.resolvingSymlinksInPath().standardizedFileURL
        return lexical.path == canonical.path ? canonical.path : nil
    }
}

enum Phase2LiveAIAgentWorkerProcessIdentityError: Error, Equatable {
    case invalidTestHost
    case invalidEmbeddedWorker
    case processUnavailable
    case identityMismatch
    case securityFailure(OSStatus)
}

private actor GateEventCollector {
    private(set) var events: [Phase2InferenceEvent] = []
    func append(_ event: Phase2InferenceEvent) { events.append(event) }
}

private actor ReconstructionGateEventCollector {
    private(set) var events: [ReconstructionAIWorkerEvent] = []
    func append(_ event: ReconstructionAIWorkerEvent) { events.append(event) }
}

private enum LiveGateError: Error {
    case missingWorkerProxy
    case fixtureDidNotStart
    case fixtureDidNotExit
    case invalidFixtureSummary
}

private final class GateOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

private struct LiveChatFixtureSummary {
    let requestCount: Int
    let paths: [String]
    let hasTools: [Bool]
    let hasResponseFormat: [Bool]
    let hasTopP: [Bool]
    let hasTemperature: [Bool]
    let streams: [Bool]
    let methods: [String]
    let requestBodies: [Data]
}

private final class LiveChatFixture: @unchecked Sendable {
    enum Mode: String {
        case assistant
        case reconstruction
        case reconstructionR2
    }

    let port: Int
    private let process: Process
    private let ownedPID: Int32
    private let directory: URL
    private let summaryURL: URL

    var isRunning: Bool { process.isRunning }

    private init(port: Int, process: Process, directory: URL, summaryURL: URL) {
        self.port = port
        self.process = process
        ownedPID = process.processIdentifier
        self.directory = directory
        self.summaryURL = summaryURL
    }

    static func start(mode: Mode = .assistant) async throws -> LiveChatFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-live-ai-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("fixture.py")
        let portURL = directory.appendingPathComponent("port.txt")
        let summaryURL = directory.appendingPathComponent("summary.json")
        do {
            try Data(pythonFixture.utf8).write(to: scriptURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, portURL.path, summaryURL.path, mode.rawValue]
        // Never read; an unread pipe would block the fixture once ~64 KB of logging accumulates.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let ownedPID = process.processIdentifier
        guard ownedPID > 0 else {
            stopAndRemoveFixtureDirectory(process, ownedPID: ownedPID, directory: directory)
            throw LiveGateError.fixtureDidNotStart
        }

        do {
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if let data = try? Data(contentsOf: portURL),
                   let text = String(data: data, encoding: .utf8),
                   let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   (1...65_535).contains(port) {
                    return LiveChatFixture(
                        port: port,
                        process: process,
                        directory: directory,
                        summaryURL: summaryURL
                    )
                }
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            stopAndRemoveFixtureDirectory(process, ownedPID: ownedPID, directory: directory)
            throw error
        }
        stopAndRemoveFixtureDirectory(process, ownedPID: ownedPID, directory: directory)
        throw LiveGateError.fixtureDidNotStart
    }

    func waitForExactCompletion() throws -> LiveChatFixtureSummary {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning, process.terminationStatus == 0,
              let data = try? Data(contentsOf: summaryURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requests = object["requests"] as? [[String: Any]]
        else { throw LiveGateError.fixtureDidNotExit }
        let requestKeys: Set<String> = [
            "method", "path", "has_tools", "has_response_format", "has_top_p",
            "has_temperature", "stream", "includes_usage",
        ]
        guard requests.allSatisfy({ Set($0.keys) == requestKeys
            || Set($0.keys) == requestKeys.union(["request_body_base64"]) }) else {
            throw LiveGateError.invalidFixtureSummary
        }
        guard requests.allSatisfy({ $0["stream"] as? Bool == true
            && $0["includes_usage"] as? Bool == true }) else {
            throw LiveGateError.invalidFixtureSummary
        }
        let requestBodies: [Data] = try requests.compactMap { record in
            guard let encoded = record["request_body_base64"] as? String else { return nil }
            guard let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
                  bytes.count <= ReconstructionReadablePromptProjection.maximumEncodedProviderBodyBytes else {
                throw LiveGateError.invalidFixtureSummary
            }
            return bytes
        }
        return .init(
            requestCount: requests.count,
            paths: requests.compactMap { $0["path"] as? String },
            hasTools: requests.compactMap { $0["has_tools"] as? Bool },
            hasResponseFormat: requests.compactMap { $0["has_response_format"] as? Bool },
            hasTopP: requests.compactMap { $0["has_top_p"] as? Bool },
            hasTemperature: requests.compactMap { $0["has_temperature"] as? Bool },
            streams: requests.compactMap { $0["stream"] as? Bool },
            methods: requests.compactMap { $0["method"] as? String },
            requestBodies: requestBodies
        )
    }

    func stopExactOwnedProcessIfNeeded() {
        Self.stopAndRemoveFixtureDirectory(process, ownedPID: ownedPID, directory: directory)
    }

    private static func stopAndRemoveFixtureDirectory(
        _ process: Process, ownedPID: Int32, directory: URL
    ) {
        guard stopExactOwnedProcess(process, ownedPID: ownedPID) else {
            XCTFail("exact fixture cleanup did not complete; preserving diagnostics at \(directory.path)")
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    fileprivate static func stopExactOwnedProcess(_ process: Process, ownedPID: Int32) -> Bool {
        guard ownedPID > 0, process.processIdentifier == ownedPID else { return false }
        // Successful completion already observed termination. A second Foundation
        // waitUntilExit can strand a cooperative executor in its notification run loop.
        guard process.isRunning else { return true }
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // No PID-only escalation: an unresponsive fixture fails the gate, retains
        // its diagnostic directory, and never turns teardown into an unbounded wait.
        return !process.isRunning
    }

    private static let pythonFixture = #"""
import http.server
import base64
import json
import sys

port_path, summary_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
requests = []

def chunk(model, delta, finish):
    return {
        "id": "live-gate-stream",
        "object": "chat.completion.chunk",
        "created": 1,
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }

def usage(model):
    return {
        "id": "live-gate-stream",
        "object": "chat.completion.chunk",
        "created": 1,
        "model": model,
        "choices": [],
        "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10},
    }

def event(value):
    payload = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return ("data: " + payload + "\n\n").encode("utf-8")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length)
        body = json.loads(raw_body.decode("utf-8"))
        record = {
            "method": "POST",
            "path": self.path,
            "has_tools": "tools" in body,
            "has_response_format": "response_format" in body,
            "has_top_p": "top_p" in body,
            "has_temperature": "temperature" in body,
            "stream": body.get("stream") is True,
            "includes_usage": body.get("stream_options", {}).get("include_usage") is True,
        }
        if mode == "reconstructionR2":
            record["request_body_base64"] = base64.b64encode(raw_body).decode("ascii")
        requests.append(record)
        model = body["model"]

        if body.get("generation_mode") != "mtp" or "enable_thinking" in body or "reasoning_effort" in body or "depth" in body:
            stream = b"missing explicit MTPLX policy"
            status = 400
            content_type = "text/plain"
        elif mode == "assistant" and len(requests) == 1 and record["has_tools"] and not record["has_response_format"]:
            function = body["tools"][0]["function"]
            handle = function["parameters"]["properties"]["handle_id"]["enum"][0]
            arguments = json.dumps({"handle_id": handle}, separators=(",", ":"))
            stream = b"".join([
                event(chunk(model, {"tool_calls": [{
                    "index": 0,
                    "id": "opaque/live-call-β",
                    "type": "function",
                    "function": {"name": function["name"], "arguments": arguments},
                }]}, None)),
                event(chunk(model, {"tool_calls": []}, "tool_calls")),
                event(usage(model)),
                event("[DONE]"),
            ])
            status = 200
            content_type = "text/event-stream"
        elif mode == "assistant" and len(requests) == 2 and record["has_response_format"] and record["has_tools"]:
            final_value = json.dumps({
                "kind": "insufficient_evidence",
                "text": "",
                "evidence_ids": [],
                "reason": "No grounded evidence was supplied.",
            }, separators=(",", ":"))
            stream = b"".join([
                event(chunk(model, {"content": final_value}, None)),
                event(chunk(model, {}, "stop")),
                event(usage(model)),
                event("[DONE]"),
            ])
            status = 200
            content_type = "text/event-stream"
        elif mode in ("reconstruction", "reconstructionR2") and len(requests) in (1, 2) and record["has_response_format"] and record["stream"] and record["includes_usage"]:
            request_value = json.loads(body["messages"][1]["content"])
            round_channel_matches = record["has_tools"]
            final_channel_matches = not record["has_tools"]
            if mode == "reconstructionR2":
                readable = request_value
                request_value = request_value["authorityRequestProjection"]
                json_only = all(field not in body for field in ("tools", "tool_choice", "parallel_tool_calls"))
                r2_contract_matches = (json_only
                    and body.get("metadata") == {"cache_mode": "stateless"}
                    and readable.get("domain") == "reconstruction.readable-prompt.r2.v1"
                    and readable.get("requestProtocolVersion") == 9)
                actions = readable.get("offeredActions", [])
                handles = request_value.get("handles", [])
                round_channel_matches = (r2_contract_matches and bool(handles)
                    and len(actions) == len(handles)
                    and all(action.get("handleID") == handle["handleID"]
                        and action.get("operationID") == handle["operationID"]
                        and action.get("selectionChannel") == "selected_handle_ids"
                        and action.get("execution") == "offeredForRead"
                        and isinstance(action.get("description"), str)
                        and bool(action["description"])
                        for action, handle in zip(actions, handles)))
                final_channel_matches = r2_contract_matches and "offeredActions" not in readable
            if len(requests) == 1 and round_channel_matches:
                content = json.dumps({
                    "job_id": request_value["jobID"],
                    "checkpoint_revision": request_value["checkpointRevision"],
                    "round_id": request_value["roundID"],
                    "selected_handle_ids": [request_value["handles"][0]["handleID"]],
                    "disposition": "sufficientEvidence",
                    "unresolved_gaps": [],
                    "resolved_gaps": [],
                }, separators=(",", ":"))
                usage_value = {
                    "prompt_tokens": 11,
                    "completion_tokens": 5,
                    "total_tokens": 16,
                }
            elif len(requests) == 2 and final_channel_matches:
                content = json.dumps({
                    "kind": "synthesis" if mode == "reconstructionR2" else "insufficientEvidence",
                    "text": "The supplied pseudocode returns input + 1." if mode == "reconstructionR2" else "No accepted reconstruction evidence was supplied.",
                    "evidence_ids": request_value["acceptedEvidenceIDs"] if mode == "reconstructionR2" else [],
                }, separators=(",", ":"))
                usage_value = {
                    "prompt_tokens": 13,
                    "completion_tokens": 7,
                    "total_tokens": 20,
                }
            else:
                content = None
                usage_value = None
            if content is not None:
                usage_chunk = usage(model)
                usage_chunk["usage"] = usage_value
                stream = b"".join([
                    event(chunk(model, {"role": "assistant"}, None)),
                    event(chunk(model, {"content": content}, None)),
                    event(chunk(model, {}, "stop")),
                    event(usage_chunk),
                    event("[DONE]"),
                ])
                status = 200
                content_type = "text/event-stream"
            else:
                stream = b"unexpected reconstruction request"
                status = 400
                content_type = "text/plain"
        else:
            stream = b"unexpected request"
            status = 400
            content_type = "text/plain"

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(stream)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(stream)
        self.wfile.flush()

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_address[1]))
    port_file.flush()

for _ in range(2):
    server.handle_request()
server.server_close()
with open(summary_path, "w", encoding="utf-8") as summary_file:
    json.dump({"requests": requests}, summary_file, separators=(",", ":"))
"""#
}

/// Real-process coverage for cleanup, independent of the signed live-XPC service.
final class Phase2LiveChatFixtureCleanupTests: XCTestCase {
    func testAlreadyExitedChildReturnsPromptly() async throws {
        let probe = try LiveChatCleanupProbe(mode: .completed)
        defer { probe.releaseAndRemoveWhenExited() }
        XCTAssertFalse(probe.process.isRunning)
        let result = await cleanup(probe)
        XCTAssertTrue(result.stopped)
        XCTAssertLessThan(result.elapsed, 0.5)
    }

    func testRepeatedCleanupReturnsPromptly() async throws {
        let probe = try LiveChatCleanupProbe(mode: .cooperative)
        defer { probe.releaseAndRemoveWhenExited() }
        let first = await cleanup(probe)
        XCTAssertTrue(first.stopped)
        let second = await cleanup(probe)
        XCTAssertTrue(second.stopped)
        XCTAssertLessThan(second.elapsed, 0.5)
    }

    func testRunningCooperativeChildIsStopped() async throws {
        let probe = try LiveChatCleanupProbe(mode: .cooperative)
        defer { probe.releaseAndRemoveWhenExited() }
        XCTAssertTrue(probe.process.isRunning)
        let result = await cleanup(probe)
        XCTAssertTrue(result.stopped)
        XCTAssertFalse(probe.process.isRunning)
        XCTAssertLessThan(result.elapsed, 1.5)
    }

    func testTERMResistantChildReportsBoundedFailure() async throws {
        let probe = try LiveChatCleanupProbe(mode: .resistant)
        defer { probe.releaseAndRemoveWhenExited() }
        let result = await cleanup(probe)
        XCTAssertFalse(result.stopped)
        XCTAssertTrue(probe.process.isRunning)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.9)
        XCTAssertLessThan(result.elapsed, 1.5)
    }

    func testWrongPIDDoesNotSignalChild() async throws {
        let probe = try LiveChatCleanupProbe(mode: .cooperative)
        defer { probe.releaseAndRemoveWhenExited() }
        let result = await cleanup(probe, ownedPID: probe.ownedPID + 1)
        XCTAssertFalse(result.stopped)
        XCTAssertTrue(probe.process.isRunning)
        XCTAssertLessThan(result.elapsed, 0.5)
    }

    private func cleanup(
        _ probe: LiveChatCleanupProbe, ownedPID: Int32? = nil
    ) async -> (stopped: Bool, elapsed: Double) {
        await Task.detached {
            let started = DispatchTime.now().uptimeNanoseconds
            let stopped = LiveChatFixture.stopExactOwnedProcess(
                probe.process, ownedPID: ownedPID ?? probe.ownedPID
            )
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            return (stopped, elapsed)
        }.value
    }
}

private final class LiveChatCleanupProbe: @unchecked Sendable {
    enum Mode: String { case completed, cooperative, resistant }
    let process: Process
    let ownedPID: Int32
    private let directory: URL
    private let releaseURL: URL

    init(mode: Mode) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-live-chat-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readyURL = directory.appendingPathComponent("ready")
        releaseURL = directory.appendingPathComponent("release")
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", #"""
import pathlib, signal, sys, time
ready, release, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
if mode == "resistant":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
ready.write_text("ready")
deadline = time.monotonic() + 6
while mode != "completed" and time.monotonic() < deadline and not release.exists():
    time.sleep(0.005)
"""#, readyURL.path, releaseURL.path, mode.rawValue]
        // No undrained pipes: even a failing probe cannot block on output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        ownedPID = process.processIdentifier
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !FileManager.default.fileExists(atPath: readyURL.path),
              process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            releaseAndRemoveWhenExited()
            throw LiveGateError.fixtureDidNotStart
        }
        if mode == .completed {
            while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard !process.isRunning else {
                releaseAndRemoveWhenExited()
                throw LiveGateError.fixtureDidNotExit
            }
        }
    }

    func releaseAndRemoveWhenExited() {
        // Cooperative release also retires the deliberately TERM-resistant probe.
        // Its independent six-second lifetime bounds fallout if this test crashes.
        try? Data().write(to: releaseURL)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard !process.isRunning else {
            XCTFail("cleanup probe is still live; preserving \(directory.path)")
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RefreshLiveBatchTrace: ReconstructionBatchTaskExecuting {
    let executor: ReconstructionBatchTaskExecutor

    init(executor: ReconstructionBatchTaskExecutor) { self.executor = executor }

    func execute(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation) async -> ReconstructionTerminalTaskResult {
        let result = await executor.execute(task: task, authority: authority, cancellation: cancellation)
        let nativeStatus: String
        switch result.nativeResult {
        case .completed: nativeStatus = "completed"
        case .cancelled: nativeStatus = "cancelled"
        case .failed(let reason): nativeStatus = "failed:\(reason)"
        case nil: nativeStatus = "none"
        }
        print("MTPLX_REFRESH_BATCH revision=\(authority.checkpointRevision) kind=\(task.identity.kind) outcome=\(result.outcome) analysis=\(result.analysisProjection != nil) native=\(nativeStatus)")
        return result
    }

    func pause() async { await executor.pause() }
    func resume() async { await executor.resume() }
    func retire() async { await executor.retire() }
}

/// Qualification adapter around the same signed provider and runner as production. It only
/// records requests/outcomes; it cannot select a tool or manufacture a model candidate.
@MainActor
private final class RefreshLiveSignedInference: ReconstructionReadyInferenceCoordinating {
    struct Call: Sendable {
        let request: ReconstructionInferenceRoundRequest
        let outcome: ReconstructionInferenceExecutionResult
    }
    private let provider: ReconstructionXPCInferenceProvider
    private let configuration: Phase2AIProviderConfiguration
    private(set) var calls: [Call] = []

    init(provider: ReconstructionXPCInferenceProvider, configuration: Phase2AIProviderConfiguration) {
        self.provider = provider
        self.configuration = configuration
    }

    func run(request: ReconstructionInferenceRoundRequest) async -> ReconstructionReadyInferenceExecutionResult {
        .invalidRequest
    }

    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult {
        guard let objective, calls.count < 2 else { return .invalidRequest }
        let requestID = UUID()
        do {
            let outcome = try await ReconstructionInferenceRunner().run(requestID: requestID,
                request: request, provider: provider, objective: objective)
            let authority = try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID,
                request: .roundR2(.init(protocolVersion: 9, objective: objective, request: request)),
                terminalReceipt: outcome.terminalReceipt)
            calls.append(.init(request: request, outcome: outcome))
            await provider.cancel(requestID: requestID)
            // The catalog was discovered live by the test. This is a qualification lease,
            // explicitly separate from production settings/readiness-controller acceptance.
            let inventoryDigest = SHA256.hash(data: Data(configuration.model.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return .finished(lease: .init(providerRevision: 1, configuration: configuration,
                observedModelInventorySHA256: inventoryDigest), requestAuthority: authority,
                outcome: outcome)
        } catch {
            print("MTPLX_REFRESH_LIVE inference_failed=\(error)")
            return .failedWithoutTerminalAuthority(.providerFailure)
        }
    }

    func synthesize(request: ReconstructionFinalSynthesisRequest) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        .invalidRequest
    }
}

private actor JoinedLiveStatusPublisher: ReconstructionJobStatusPublishing {
    private(set) var lastDisposition: ReconstructionJobCoordinatorDisposition?
    func publish(_ receipt: ReconstructionJobCommitReceipt) async {
        lastDisposition = receipt.disposition
        print("MTPLX_JOINED_COMMIT revision=\(receipt.checkpointRevision) disposition=\(receipt.disposition)")
    }
}

/// Host provenance is observed from the signed test app's resource. Debug identity is retained
/// as Debug; this decoder never grants Release qualification eligibility.
private struct JoinedLiveHostProvenance: Decodable {
    let gitHeadCommit: String
    let gitHeadTree: String
    let selectedBuildInputsSHA256: String
    let xcodeBuild: String
    let configuration: String
    enum CodingKeys: String, CodingKey {
        case gitHeadCommit = "git_head_commit"
        case gitHeadTree = "git_head_tree"
        case selectedBuildInputsSHA256 = "selected_build_inputs_sha256"
        case xcodeBuild = "xcode_build"
        case configuration
    }
    static func read() throws -> Self {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "MacScopeBuildProvenance", withExtension: "json"))
        let data = try Data(contentsOf: url)
        guard data.count <= Phase2QualificationGateBuildProvenance.maximumBytes else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        XCTAssertEqual(result.gitHeadCommit.count, 40)
        XCTAssertEqual(result.gitHeadTree.count, 40)
        XCTAssertEqual(result.selectedBuildInputsSHA256.count, 64)
        return result
    }
}

/// Dev-loop (unsealed Debug) host identity for the live C-sample canary: git HEAD and tree of
/// the checkout under test (TEST_RUNNER_MACSCOPE_SOURCE_ROOT) and SHA-256 of the Debug
/// provenance bytes. Never Release qualification evidence.
private struct LiveUnsealedHostIdentity {
    let gitHeadCommit: String
    let gitHeadTree: String
    let buildIdentitySHA256: String
    let configuration: String
    let xcodeBuild: String
    static func read(provenance: Data) throws -> Self {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: provenance) as? [String: Any])
        let sourceRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["MACSCOPE_SOURCE_ROOT"],
            "dev_loop exports TEST_RUNNER_MACSCOPE_SOURCE_ROOT")
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", sourceRoot, "rev-parse", "HEAD", "HEAD^{tree}"]
        let pipe = Pipe()
        git.standardOutput = pipe
        try git.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        guard git.terminationStatus == 0, lines.count == 2, lines.allSatisfy({ $0.utf8.count == 40 }) else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        return .init(gitHeadCommit: lines[0], gitHeadTree: lines[1],
            buildIdentitySHA256: SHA256.hash(data: provenance).map { String(format: "%02x", $0) }.joined(),
            configuration: json["configuration"] as? String ?? "unknown",
            xcodeBuild: json["xcode_build"] as? String ?? "unknown")
    }
}

/// Test-only prompt budget for the tiny authored function. All records and payloads come from
/// the production cut/compiler; the durable budget, native execution, and acceptance stay intact.
private struct JoinedLiveBoundedPreparedRoundBuilder: ReconstructionProductionPreparedRoundBuilding {
    let base: ReconstructionProductionPreparedRoundBuilder
    let contextCompiler: ReconstructionContextCompiler

    func makePreparedRound(from basis: ReconstructionProductionRoundBasis) async throws
        -> ReconstructionPreparedModelRound {
        let prepared = try await base.makePreparedRound(from: basis)
        let original = prepared.retrievalQuery
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: original.corpusManifestSHA256, subject: original.subject,
            operationIDs: original.operationIDs, classifications: original.classifications,
            cursor: original.cursor, maximumRecords: min(original.maximumRecords, 8),
            maximumEncodedBytes: min(original.maximumEncodedBytes, 8_192), focus: original.focus)
        let context = try contextCompiler.compile(cut: prepared.evidenceCut, query: query,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories)
        let packet = try ReconstructionRetrievalCompiler().compile(cut: prepared.evidenceCut, query: query)
        // Never mark a tool page consumed if wire budgeting delivered only a smaller prefix.
        guard context.evidenceIDs == packet.records.map(\.evidenceID),
              context.canonicalBytes.count <= 16_384 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let requests = prepared.requests.map { request in
            guard request.operationID == .evidenceQuery else { return request }
            return ReconstructionToolRequest(operationID: request.operationID, taskID: request.taskID,
                subject: request.subject, retrievalQuery: query, offset: query.cursor == nil ? 0 : 1,
                maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
        }
        let finalRequest = prepared.finalSynthesisRequest.map { request in
            ReconstructionFinalSynthesisRequest(jobID: request.jobID,
                checkpointRevision: request.checkpointRevision,
                corpusManifestSHA256: request.corpusManifestSHA256,
                evidenceFrontierSHA256: request.evidenceFrontierSHA256,
                acceptedEvidenceIDs: context.evidenceIDs, context: context)
        }
        return ReconstructionPreparedModelRound(roundID: prepared.roundID,
            evidenceCut: prepared.evidenceCut, retrievalQuery: query,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories, authority: prepared.authority,
            requests: requests, projectorInput: prepared.projectorInput,
            finalSynthesisRequest: finalRequest, objective: prepared.objective)
    }
}

@MainActor
private final class JoinedLiveSignedInference: ReconstructionReadyInferenceCoordinating {
    struct SourceCall: Sendable {
        let request: ReconstructionSourceRevisionRequest
        let outcome: ReconstructionSourceRevisionExecutionResult
        let authority: ReconstructionModelTerminalRequestAuthority
    }
    struct RoundCall: Sendable {
        let request: ReconstructionInferenceRoundRequest
        let outcome: ReconstructionInferenceExecutionResult
        let authority: ReconstructionModelTerminalRequestAuthority
    }
    struct FinalCall: Sendable {
        let request: ReconstructionFinalSynthesisRequest
        let outcome: ReconstructionFinalSynthesisExecutionResult
        let authority: ReconstructionModelTerminalRequestAuthority
    }
    /// Ordinary rounds and final synthesis: the reconstructionR2 bundle.
    private let provider: ReconstructionXPCInferenceProvider
    /// Source revisions carry the reconstructionSourceV10 bundle (ReconstructionAIWorkerRequest
    /// .protocolBundle), and ReconstructionXPCInferenceProvider rejects any request whose bundle is
    /// not its selected one with protocolMismatch. Production therefore builds a separate source
    /// provider (Phase2ReadyInferenceCoordinator.reconstructionSourceProviderFactory); so does this.
    private let sourceProvider: ReconstructionXPCInferenceProvider
    private let lease: Phase2ReadyInferenceLease
    private let maximumOrdinaryCalls: Int
    private let captureRoot: URL
    private(set) var sources: [SourceCall] = []
    private(set) var sourceAttempts = 0
    private(set) var rounds: [RoundCall] = []
    private(set) var finals: [FinalCall] = []
    init(provider: ReconstructionXPCInferenceProvider, sourceProvider: ReconstructionXPCInferenceProvider,
        configuration: Phase2AIProviderConfiguration,
        inventorySHA256: String, maximumOrdinaryCalls: Int, captureRoot: URL) {
        self.provider = provider
        self.sourceProvider = sourceProvider
        lease = .init(providerRevision: 1, configuration: configuration,
            observedModelInventorySHA256: inventorySHA256)
        self.maximumOrdinaryCalls = maximumOrdinaryCalls
        self.captureRoot = captureRoot
    }
    func proposeSourceRevision(request: ReconstructionSourceRevisionRequest)
        async -> ReconstructionReadySourceRevisionExecutionResult {
        // Count attempts, including rejected outputs, so no hidden retry can manufacture proof.
        guard sourceAttempts < 2 else { return .invalidRequest }
        sourceAttempts += 1
        let requestID = UUID()
        do {
            try ReconstructionCanonicalJSON.encode(request).write(
                to: captureRoot.appendingPathComponent("source-request-\(requestID).json"))
            let outcome = try await ReconstructionInferenceRunner().runSourceRevision(
                requestID: requestID, request: request,
                provider: JoinedLiveSourceEventCaptureProvider(base: sourceProvider, root: captureRoot))
            let authority = try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID, request: .sourceRevision(request),
                terminalReceipt: outcome.terminalReceipt)
            sources.append(.init(request: request, outcome: outcome, authority: authority))
            try ReconstructionCanonicalJSON.encode(outcome.candidate).write(
                to: captureRoot.appendingPathComponent("source-candidate-\(requestID).json"))
            try ReconstructionCanonicalJSON.encode(outcome.terminalReceipt).write(
                to: captureRoot.appendingPathComponent("source-terminal-\(requestID).json"))
            try ReconstructionCanonicalJSON.encode(outcome.usage).write(
                to: captureRoot.appendingPathComponent("source-usage-\(requestID).json"))
            print("MTPLX_SOURCE_REPAIR_MODEL request=\(requestID) task=\(request.taskID) revision=\(request.checkpointRevision) parent=\(request.parentRevisionSHA256 ?? "none") source=\(outcome.candidate.sourceSHA256) request_sha256=\(authority.requestIdentitySHA256) usage=\(outcome.usage)")
            await sourceProvider.cancel(requestID: requestID)
            return .finished(lease: lease, requestAuthority: authority, outcome: outcome)
        } catch let failure as ReconstructionInferenceRunnerTerminalFailure {
            try? Data(String(describing: failure).utf8).write(
                to: captureRoot.appendingPathComponent("source-failure-\(requestID).txt"))
            try? ReconstructionCanonicalJSON.encode(failure.terminalReceipt).write(
                to: captureRoot.appendingPathComponent("source-terminal-\(requestID).json"))
            await sourceProvider.cancel(requestID: requestID)
            guard let authority = try? ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: requestID, request: .sourceRevision(request),
                terminalReceipt: failure.terminalReceipt) else {
                return .failedWithoutTerminalAuthority(failure.failure)
            }
            return .failedWithTerminalAuthority(lease: lease,
                requestAuthority: authority, failure: failure.failure)
        } catch {
            try? Data(String(describing: error).utf8).write(
                to: captureRoot.appendingPathComponent("source-failure-\(requestID).txt"))
            await sourceProvider.cancel(requestID: requestID)
            return .failedWithoutTerminalAuthority(.providerFailure)
        }
    }
    func run(request: ReconstructionInferenceRoundRequest) async -> ReconstructionReadyInferenceExecutionResult { .invalidRequest }
    func synthesize(request: ReconstructionFinalSynthesisRequest) async -> ReconstructionReadyFinalSynthesisExecutionResult { .invalidRequest }
    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult {
        guard let objective, rounds.count < maximumOrdinaryCalls else { return .invalidRequest }
        let requestID = UUID()
        do {
            try ReconstructionCanonicalJSON.encode(ReconstructionInferenceRoundRequestR2(
                protocolVersion: 9, objective: objective, request: request)).write(
                    to: captureRoot.appendingPathComponent("round-request-\(requestID).json"))
            let outcome = try await ReconstructionInferenceRunner().run(requestID: requestID,
                request: request, provider: provider, objective: objective)
            let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: requestID,
                request: .roundR2(.init(protocolVersion: 9, objective: objective, request: request)),
                terminalReceipt: outcome.terminalReceipt)
            rounds.append(.init(request: request, outcome: outcome, authority: authority))
            try ReconstructionCanonicalJSON.encode(outcome.candidate).write(
                to: captureRoot.appendingPathComponent("round-candidate-\(requestID).json"))
            try ReconstructionCanonicalJSON.encode(outcome.terminalReceipt).write(
                to: captureRoot.appendingPathComponent("round-terminal-\(requestID).json"))
            print("MTPLX_JOINED_MODEL phase=round request=\(requestID) revision=\(request.checkpointRevision) selected=\(outcome.candidate.selectedHandleIDs) disposition=\(outcome.candidate.disposition) usage=\(outcome.usage)")
            await provider.cancel(requestID: requestID)
            return .finished(lease: lease, requestAuthority: authority, outcome: outcome)
        } catch {
            print("MTPLX_JOINED_MODEL_FAILURE phase=round request=\(requestID) error=\(error)")
            await provider.cancel(requestID: requestID)
            return .failedWithoutTerminalAuthority(.providerFailure)
        }
    }
    func synthesize(request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        guard let objective, finals.isEmpty else { return .invalidRequest }
        let requestID = UUID()
        do {
            try ReconstructionCanonicalJSON.encode(ReconstructionFinalSynthesisRequestR2(
                protocolVersion: 9, objective: objective, request: request)).write(
                    to: captureRoot.appendingPathComponent("final-request-\(requestID).json"))
            let outcome = try await ReconstructionInferenceRunner().synthesize(requestID: requestID,
                request: request, provider: provider, objective: objective)
            let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: requestID,
                request: .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: request)),
                terminalReceipt: outcome.terminalReceipt)
            finals.append(.init(request: request, outcome: outcome, authority: authority))
            try ReconstructionCanonicalJSON.encode(outcome.candidate).write(
                to: captureRoot.appendingPathComponent("final-candidate-\(requestID).json"))
            try ReconstructionCanonicalJSON.encode(outcome.terminalReceipt).write(
                to: captureRoot.appendingPathComponent("final-terminal-\(requestID).json"))
            print("MTPLX_JOINED_MODEL phase=final request=\(requestID) revision=\(request.checkpointRevision) kind=\(outcome.candidate.kind) cited=\(outcome.candidate.evidenceIDs) usage=\(outcome.usage)")
            await provider.cancel(requestID: requestID)
            return .finished(lease: lease, requestAuthority: authority, outcome: outcome)
        } catch {
            print("MTPLX_JOINED_MODEL_FAILURE phase=final request=\(requestID) error=\(error)")
            await provider.cancel(requestID: requestID)
            return .failedWithoutTerminalAuthority(.providerFailure)
        }
    }
    static func contextRecords(_ context: ReconstructionRetrievedContext) throws -> [ReconstructionRetrievedEvidenceRecord] {
        struct Envelope: Decodable { let retrievalPacket: Data }
        struct Packet: Decodable { let records: [ReconstructionRetrievedEvidenceRecord] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: context.canonicalBytes)
        return try JSONDecoder().decode(Packet.self, from: envelope.retrievalPacket).records
    }
}

/// Transfer the fresh non-Sendable SQLite connection exactly once. Keeping initialization in
/// this scope prevents the main actor from retaining an alias after ownership moves to the actor.
@MainActor
private func makeSourceRepairDatabaseOwner(path: String, workspaceID: UUID,
    attachmentVaultRootURL: URL) throws -> (Int64, ReconstructionDatabaseOwner) {
    let database = try WorkspaceDatabase(path: path)
    try database.applySchema()
    let workspace = try database.saveSnapshot(workspaceUUID: workspaceID,
        workspaceName: "Actual model mismatch and repair",
        snapshot: .init(binaries: [], analysisBySlot: [:]), now: Date())
    let workspaceRowID = try XCTUnwrap(workspace.id)
    let owner = ReconstructionDatabaseOwner(database: database,
        attachmentVaultRootURL: attachmentVaultRootURL)
    return (workspaceRowID, owner)
}

/// Headless stand-in for the signed worker connection: records the protocol bundle each dispatch
/// was bound to, then fails it, so no model or worker process is ever involved.
private actor JoinedLiveBundleRecordingTransport: AIAgentXPCTerminalPreservingTransport {
    static let sentinel = "joined-live-recording-transport-dispatch"
    private(set) var dispatchedManifestDigests: [String] = []
    func run(requestID: UUID, requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        throw AIAgentXPCTransportError.unavailable(Self.sentinel)
    }
    func runPreservingTerminal(requestID: UUID, requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void) async throws -> AIAgentXPCTransportTerminal {
        throw AIAgentXPCTransportError.unavailable(Self.sentinel)
    }
    func runPreservingTerminal(requestID: UUID, requestData: Data,
        expectedProtocolBundle: Phase2AIWorkerProductionProtocolBundle, expectedPhase: Phase2AIWorkerWirePhase,
        receive: @escaping @Sendable (Data) async throws -> Void) async throws -> AIAgentXPCTransportTerminal {
        dispatchedManifestDigests.append(expectedProtocolBundle.manifestDigest)
        throw AIAgentXPCTransportError.unavailable(Self.sentinel)
    }
    func cancel(requestID: UUID) async {}
    func reset() async {}
    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt {
        throw AIAgentXPCTransportError.unavailable(Self.sentinel)
    }
    func revalidateWorkerProcessReceipt(_ receipt: AIAgentXPCWorkerProcessReceipt) async -> Bool { false }
}

/// Retains every decoded semantic source event before runner admission, including rejected
/// candidates. Forwarding preserves the request, event, sequence and terminal bytes/values.
private struct JoinedLiveSourceEventCaptureProvider: ReconstructionInferenceProviding {
    let base: ReconstructionXPCInferenceProvider
    let root: URL
    func runSourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await base.runSourceRevision(requestID: requestID, request: request, emit: { event in
            let stem = "source-event-\(event.requestID)-\(event.sequence)"
            let bytes: Data
            switch event.body {
            case .sourceCandidate(let value): bytes = try ReconstructionCanonicalJSON.encode(value)
            case .roundCandidate(let value): bytes = try ReconstructionCanonicalJSON.encode(value)
            case .finalCandidate(let value): bytes = try ReconstructionCanonicalJSON.encode(value)
            case .usage(let value): bytes = try ReconstructionCanonicalJSON.encode(value)
            case .completed: bytes = try ReconstructionCanonicalJSON.encode("completed")
            }
            try bytes.write(to: root.appendingPathComponent(stem + ".json"))
            try await emit(event)
        })
    }
    func runRound(requestID: UUID, request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await base.runRound(requestID: requestID, request: request, emit: emit)
    }
    func runFinalSynthesis(requestID: UUID, request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        try await base.runFinalSynthesis(requestID: requestID, request: request, emit: emit)
    }
    func cancel(requestID: UUID) async { await base.cancel(requestID: requestID) }
    static func captureOriginal(_ original: ReconstructionSourceExecutionWorkflow.PreparedOriginal,
        root: URL) throws {
        for phase in original.phases {
            let stem = "original-\(phase.request.requestID)"
            try ReconstructionCanonicalJSON.encode(phase.request).write(
                to: root.appendingPathComponent(stem + "-request.json"))
            if let response = phase.response {
                try ReconstructionCanonicalJSON.encode(response).write(
                    to: root.appendingPathComponent(stem + "-response.json"))
            }
            if let error = phase.transportError {
                try Data(error.utf8).write(to: root.appendingPathComponent(stem + "-error.txt"))
            }
        }
    }
}

private func gateID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func gateDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}

private extension NSLock {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
