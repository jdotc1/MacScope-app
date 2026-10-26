import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// Deterministic inference only: import, analysis, planning, receipt admission,
/// coordinator commits and physical package I/O use the production owners.
@MainActor
enum ReconstructionJoinedWorkflowTestFixture {
    static func run(preanalyzedWorkspace: Bool = true) async throws {
        let root = TestWorkRoot.authority
            .appendingPathComponent("MacScope-JoinedWorkflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("authored-arm64")
        let tail = Data((0..<16).flatMap { _ in [UInt8(0x1f), 0x20, 0x03, 0xd5] })
        let bytes = MachOFixture.makeExecutableWithLoadCommandMetadata(mappedTail: tail).bytes
        try bytes.write(to: file)
        let projectID = UUID(), jobID = UUID(), workspaceID = UUID()
        let imported = await ReconstructionCorpusImporter().ingest(
            selections: [.init(rootURL: file, roles: [.primaryTarget])],
            projectID: projectID, cancellation: ReconstructionCancellation())
        XCTAssertTrue(imported.failures.isEmpty)
        let occurrence = try XCTUnwrap(imported.occurrences.first { $0.kind == .machOImage })
        XCTAssertEqual(occurrence.kind, .machOImage)
        XCTAssertFalse(occurrence.executableMode,
            "A non-executable Mach-O must still enter the static analysis workflow")
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: occurrence.occurrenceID,
            contentIdentity: occurrence.contentIdentity)
        let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
            artifacts: imported.occurrences, relations: imported.relations,
            canonicalSHA256: imported.canonicalManifestSHA256)
        let databasePath = root.appendingPathComponent("workspace.sqlite").path
        let database = try WorkspaceDatabase(path: databasePath)
        try database.applySchema()
        let workspace = try database.saveSnapshot(workspaceUUID: workspaceID,
            workspaceName: "Fresh joined workflow", snapshot: .init(binaries: [], analysisBySlot: [:]), now: Date())
        let workspaceRowID = try XCTUnwrap(workspace.id)
        // No seeded corpus, tasks, receipts, evidence or final result.
        if preanalyzedWorkspace {
            try database.replaceReconstructionState(workspaceID: workspaceID,
            state: .init(projects: [try .init(projectID: projectID, name: "Joined workflow",
                currentCorpusManifestSHA256: nil)], corpusManifests: [], evidence: [],
                evidenceRelations: [], evidenceGaps: [], jobs: [], tasks: [], checkpoints: [],
                toolReceipts: [], modelReceipts: []))
        }
        let vault = root.appendingPathComponent("vault")
        database.configureReconstructionAttachmentVault(rootURL: vault)
        if preanalyzedWorkspace {
            let sources = try database.publishDurableReconstructionAttachmentSources(
                imported.attachmentSources, for: manifest)
        // Bind the ordinary workspace image to the actual imported bytes before transferring
        // SQLite to its exclusive actor owner. This is real analysis, not seeded evidence.
        let baselineExecutor = try executor()
        let baseline = try await baselineExecutor.execute(.init(source: XCTUnwrap(sources.first),
            artifact: artifact, image: nil, functionID: nil, overrides: [:],
            imageAuthorityIntent: .initialLoad), cancellation: ReconstructionCancellation())
        let persisted = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceRowID))
        _ = try database.replaceWorkspaceState(workspaceID: workspaceRowID,
            workspaceName: "Joined workflow", snapshot: baseline.detached.workspace,
            selectedSidebarItemID: persisted.session.selectedSidebarItemID,
            selectedAddress: persisted.session.selectedAddress, selectedTool: persisted.session.selectedTool,
            editorMode: persisted.session.editorMode, isInspectorPresented: persisted.session.isInspectorPresented,
            sidebarSearchText: persisted.session.sidebarSearchText,
            focusedImageSlot: persisted.session.focusedImageSlot, now: Date())
            await baselineExecutor.retire()
        }
        let owner = ReconstructionDatabaseOwner(database: database, attachmentVaultRootURL: vault)
        var controllerForCleanup: ReconstructionProductionBatchExecutionController?
        do {
        _ = try await owner.commitCorpus(workspaceID: workspaceID,
            mutation: .init(projectID: projectID, expectedCurrentManifestSHA256: nil,
                successorManifest: manifest, attachmentSources: imported.attachmentSources))
        _ = try await owner.commitInitialJob(workspaceID: workspaceID,
            mutation: .init(jobID: jobID, projectID: projectID,
                selectedOccurrenceIDs: [occurrence.occurrenceID],
                objective: "Explain the selected authored function using refreshed MacScope evidence.",
                budget: try .init(maxRounds: 4, maxTasks: 128, maxEvidenceRecords: 512,
                    maxEncodedBytes: 4 * 1_024 * 1_024), focus: .artifact(artifact)))
        let initialState = try await owner.load(workspaceID: workspaceID)
        let loads = initialState.tasks.filter { $0.identity.kind == .loadBinary }
        XCTAssertEqual(loads.count, 1, "Imported Mach-O bytes require a real load task regardless of execute permission")
        XCTAssertEqual(loads.first?.identity.subject, .artifact(artifact))
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
                return ReconstructionBatchScheduler(durableJobID: jobID,
                    executor: ReconstructionBatchTaskExecutor(resolver: resolver,
                        headless: try executor(), native: native))
            }, retireJobAuthority: { await native.retire() })
        controllerForCleanup = controller
        let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
            macScopeBuildIdentity: digest("joined-test-build"), macScopeSourceIdentity: digest("joined-test-source"),
            operationIdentity: ReconstructionProductionTaskContract.modelRound,
            registryIdentity: "reconstruction.registry.v1",
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
            toolchainIdentity: "deterministic-test-inference"))
        let registry = ReconstructionProductionRoundBasisRegistry()
        let cut = ReconstructionProductionCommittedRoundCutProvider(workspaceID: workspaceID,
            owner: owner, batchExecutionBuilder: controller,
            preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                evidenceQueryProducer: author.makeToolProducer(operationID: .evidenceQuery),
                analysisRefreshProducer: author.makeToolProducer(operationID: .analysisMacScopeRefresh)),
            basisRegistry: registry, maximumConcurrentTasks: 1)
        let inference = try JoinedDeterministicInference()
        let planner = ReconstructionProductionJobRoundPlanner(
            materializer: ReconstructionProductionJobRoundMaterializer(cutProvider: cut,
                planBuilder: ReconstructionProductionRoundPlanBuilder(basisRegistry: registry, receiptAuthor: author)),
            inference: inference, projectors: [ReconstructionCheckpointToolProjector(),
                ReconstructionCorpusToolProjector(), ReconstructionDecompilerToolProjector(),
                ReconstructionEvidenceToolProjector(), ReconstructionGapsToolProjector(),
                ReconstructionImageFunctionToolProjector()])
        let publisher = JoinedStatusPublisher()
        let coordinator = ReconstructionJobCoordinator(persistence: persistence,
            planner: JoinedObservedRoundPlanner(planner: planner), publisher: publisher)
        await coordinator.start(jobID: jobID)
        let state = try await owner.load(workspaceID: workspaceID)
        let diagnostic = state.jobs.map { "job=\($0.jobID) state=\($0.state) reason=\($0.terminalReason?.text ?? "none")" }
            + state.tasks.map { "task=\($0.identity.taskID) kind=\($0.identity.kind) state=\($0.state) reason=\($0.diagnostic?.text ?? "none")" }
        XCTAssertEqual(state.jobs.first?.state, .completed, diagnostic.joined(separator: "\n"))
        XCTAssertEqual(inference.rounds.count, 2)
        XCTAssertEqual(inference.finals.count, 1)
        let first = try XCTUnwrap(inference.rounds.first)
        let later = try XCTUnwrap(inference.rounds.last)
        let refresh = try XCTUnwrap(state.tasks.first {
            $0.identity.kind == .decompileMacScope && $0.identity.dependencyTaskIDs.contains(where: { id in
                state.tasks.contains { $0.identity.taskID == id && $0.identity.kind == .checkpoint }
            })
        })
        XCTAssertEqual(refresh.state, .completed)
        let fresh = state.evidence.filter { $0.creatingTaskID == refresh.identity.taskID }
        XCTAssertFalse(fresh.isEmpty)
        XCTAssertTrue(fresh.allSatisfy { $0.classification == .acceptedCurrent })
        XCTAssertTrue(Set(fresh.map(\.evidenceID)).isDisjoint(with: Set(first.context.evidenceIDs)))
        XCTAssertTrue(Set(fresh.map(\.evidenceID)).isSubset(of: Set(later.context.evidenceIDs)))
        XCTAssertNotEqual(first.evidenceFrontierSHA256, later.evidenceFrontierSHA256)
        let laterRecords = try contextRecords(later.context)
        for record in fresh {
            let dispatched = try XCTUnwrap(laterRecords.first { $0.evidenceID == record.evidenceID })
            XCTAssertEqual(dispatched.payload, record.payload,
                "A later request must carry the refreshed fact bytes, not merely its evidence ID")
            XCTAssertEqual(dispatched.classification, .acceptedCurrent)
        }
        let result = try XCTUnwrap(state.finalResults.first)
        XCTAssertEqual(state.finalResults.count, 1)
        XCTAssertEqual(result.kind, .synthesis)
        XCTAssertEqual(result.payloadUTF8, Data(JoinedDeterministicInference.answer.utf8))
        XCTAssertFalse(result.citedEvidenceIDs.isEmpty)
        XCTAssertTrue(Set(fresh.map(\.evidenceID)).intersection(result.citedEvidenceIDs).count > 0)
        let receipt = try XCTUnwrap(state.modelReceipts.first { $0.receiptID == result.modelReceiptID })
        let checkpoint = try XCTUnwrap(state.checkpoints.first { $0.checkpointID == result.checkpointID })
        XCTAssertEqual(receipt.finalResultCommitment?.resultID, result.resultID)
        XCTAssertEqual(receipt.finalResultCommitment?.canonicalSHA256, result.canonicalSHA256)
        XCTAssertTrue(checkpoint.modelReceiptIDs.contains(receipt.receiptID))
        XCTAssertEqual(checkpoint.coordinatorState, .completed)
        let package = root.appendingPathComponent("Joined.mscope")
        let durableSources = try await owner.availableDurableAttachmentSources(workspaceID: workspaceID)
        await controller.retire(jobID: jobID)
        await owner.revoke()
        // Read physical SQLite through a new connection after owner quiescence; the
        // connection transferred into the owner is never accessed again by this actor.
        let reopenedDatabase = try WorkspaceDatabase(path: databasePath)
        let packageComponents = try reopenedDatabase.packageComponents(workspaceID: workspaceRowID,
            documentID: UUID(), inputCopyingDecision: .copyInputsIntoPackage,
            bookmarkResolutionDecision: .resolveStoredBookmarks, phase2ShellSession: nil)
        try MacScopeDocumentPackage.writePackage(packageComponents.manifest,
            attachmentsByBinaryID: packageComponents.attachmentsByBinaryID,
            reconstructionState: state, reconstructionAttachmentSources: durableSources, to: package)
        // Open physical package bytes after retiring the live owner, so memory cannot satisfy it.
        let reopened = try MacScopeDocumentPackage.openPackage(from: package)
        guard case .function(let finalFunction)? = refresh.identity.subject else {
            throw ReconstructionJobCoordinatorFailure.malformedOutput
        }
        let reopenedBinary = try XCTUnwrap(reopened.snapshot.binary(in: finalFunction.image.imageSlot))
        let reopenedAnalysis = try XCTUnwrap(reopened.snapshot.analysis(in: finalFunction.image.imageSlot))
        XCTAssertEqual(reopenedBinary.id, finalFunction.image.binaryID)
        XCTAssertEqual(reopenedBinary.slot, finalFunction.image.imageSlot)
        XCTAssertEqual(reopenedBinary.selectedSliceIndex, finalFunction.image.selectedSliceIndex)
        XCTAssertEqual(reopenedBinary.artifactIdentity, finalFunction.image.machOIdentity)
        XCTAssertEqual(reopenedAnalysis.analysisInputFingerprint?.overallSHA256,
            finalFunction.analysisFingerprintSHA256)
        XCTAssertEqual(reopenedAnalysis.analysisInputFingerprint?.binaryID, finalFunction.image.binaryID)
        XCTAssertEqual(reopenedAnalysis.analysisInputFingerprint?.imageBytesSHA256,
            SHA256.hash(data: reopenedAnalysis.imageBytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(reopened.reconstructionState.finalResults, [result])
        XCTAssertEqual(reopened.reconstructionState.modelReceipts.first { $0.receiptID == receipt.receiptID }, receipt)
        XCTAssertEqual(reopened.reconstructionState.checkpoints.first { $0.checkpointID == checkpoint.checkpointID }, checkpoint)
        XCTAssertEqual(reopened.reconstructionState.evidence.filter { result.citedEvidenceIDs.contains($0.evidenceID) },
            state.evidence.filter { result.citedEvidenceIDs.contains($0.evidenceID) })
        XCTAssertEqual(reopened.reconstructionAttachmentSources.map(\.contentIdentity), durableSources.map(\.contentIdentity))
        } catch {
            // This must settle before the outer defer removes the vault/root.
            await controllerForCleanup?.retire(jobID: jobID)
            await owner.revoke()
            throw error
        }
    }

    nonisolated private static func executor() throws -> ReconstructionHeadlessAnalysisExecutor {
        .init(pool: try ReconstructionAnalysisProviderPool(factory: ReconstructionDefaultAnalysisProviderFactory(),
            budget: .init(maximumActiveAnalyses: 1, estimatedResidentBytesPerAnalysis: 1, reservedHostBytes: 0)))
    }
    private static func contextRecords(_ context: ReconstructionRetrievedContext) throws
        -> [ReconstructionRetrievedEvidenceRecord] {
        struct Envelope: Decodable { let retrievalPacket: Data }
        struct Packet: Decodable { let records: [ReconstructionRetrievedEvidenceRecord] }
        let packet = try JSONDecoder().decode(Envelope.self, from: context.canonicalBytes)
        return try JSONDecoder().decode(Packet.self, from: packet.retrievalPacket).records
    }
    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private actor JoinedStatusPublisher: ReconstructionJobStatusPublishing {
    func publish(_ receipt: ReconstructionJobCommitReceipt) async {}
}

/// Observes the actual production planner boundary without altering plans or errors.
private actor JoinedObservedRoundPlanner: ReconstructionJobRoundPlanning {
    let planner: ReconstructionProductionJobRoundPlanner
    init(planner: ReconstructionProductionJobRoundPlanner) { self.planner = planner }
    func planRound(from snapshot: ReconstructionJobOrchestrationSnapshot) async throws -> ReconstructionJobCommitPlan {
        let tasks = snapshot.tasks.map { "\($0.identity.kind):\($0.state)" }.joined(separator: ",")
        print("JOINED_ROUND_ENTER revision=\(snapshot.checkpointRevision) state=\(snapshot.currentDurableJobState) tasks=\(tasks)")
        do {
            let plan = try await planner.planRound(from: snapshot)
            print("JOINED_ROUND_PLAN revision=\(plan.successorRevision) disposition=\(plan.disposition)")
            return plan
        } catch {
            print("JOINED_ROUND_ERROR revision=\(snapshot.checkpointRevision) state=\(snapshot.currentDurableJobState) error=\(error) tasks=\(tasks)")
            throw error
        }
    }
    func planRecovery(from snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]) async throws -> ReconstructionJobCommitPlan {
        try await planner.planRecovery(from: snapshot, transitions: transitions)
    }
    func planControl(from snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason) async throws -> ReconstructionJobCommitPlan {
        try await planner.planControl(from: snapshot, reason: reason)
    }
    func cancel(jobID: UUID) async { await planner.cancel(jobID: jobID) }
}

@MainActor
private final class JoinedDeterministicInference: ReconstructionReadyInferenceCoordinating {
    static let answer = "The selected authored function is supported by freshly committed MacScope analysis."
    private(set) var rounds: [ReconstructionInferenceRoundRequest] = []
    private(set) var finals: [ReconstructionFinalSynthesisRequest] = []
    let lease: Phase2ReadyInferenceLease
    init() throws {
        lease = .init(providerRevision: 1, configuration: try .init(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: "deterministic-joined-fixture",
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 60_000),
            observedModelInventorySHA256: ReconstructionJoinedWorkflowTestFixture.digest("fixture-inventory"))
    }
    func run(request: ReconstructionInferenceRoundRequest) async -> ReconstructionReadyInferenceExecutionResult { .invalidRequest }
    func synthesize(request: ReconstructionFinalSynthesisRequest) async -> ReconstructionReadyFinalSynthesisExecutionResult { .invalidRequest }
    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult {
        guard let objective, rounds.count < 2 else { return .invalidRequest }
        let isFirst = rounds.isEmpty
        guard !isFirst || request.handles.contains(where: { $0.operationID == .analysisMacScopeRefresh }) else {
            return .invalidRequest
        }
        let selected = isFirst ? request.handles.filter { $0.operationID == .analysisMacScopeRefresh }.prefix(1).map(\.handleID) : []
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: request.jobID,
            checkpointRevision: request.checkpointRevision, roundID: request.roundID, status: .completed)
        do {
            let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: terminal.requestID,
                request: .roundR2(.init(protocolVersion: 9, objective: objective, request: request)), terminalReceipt: terminal)
            rounds.append(request)
            return .finished(lease: lease, requestAuthority: authority,
                outcome: .init(candidate: .init(jobID: request.jobID, checkpointRevision: request.checkpointRevision,
                    roundID: request.roundID, selectedHandleIDs: selected,
                    disposition: isFirst ? .continue : .sufficientEvidence, unresolvedGaps: []),
                    usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal))
        } catch { return .invalidRequest }
    }
    func synthesize(request: ReconstructionFinalSynthesisRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        guard let objective, rounds.count == 2, finals.isEmpty else { return .invalidRequest }
        let terminal = ReconstructionTerminalReceipt(requestID: UUID(), jobID: request.jobID,
            checkpointRevision: request.checkpointRevision, roundID: nil, status: .completed)
        do {
            let authority = try ReconstructionModelTerminalRequestAuthority.make(expectedRequestID: terminal.requestID,
                request: .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: request)), terminalReceipt: terminal)
            finals.append(request)
            return .finished(lease: lease, requestAuthority: authority,
                outcome: .init(candidate: .init(kind: .synthesis, text: Self.answer,
                    // Retrieval context order is not the canonical UUID order required
                    // for a final candidate at receipt admission.
                    evidenceIDs: ReconstructionValidation.sortedUUIDs(request.acceptedEvidenceIDs)),
                    usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2), terminalReceipt: terminal))
        } catch { return .invalidRequest }
    }
}
