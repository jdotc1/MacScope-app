import Darwin
import Foundation
import XCTest
@testable import MacScope

private struct FirstLoadAdmissionNoNative: ReconstructionNativeTaskDecompiling {
    func decompile(_ request: ReconstructionNativeDecompilationRequest,
                   cancellation: ReconstructionCancellation) async -> ReconstructionNativeTaskResult {
        .failed(.authorityMismatch)
    }
    func cancelOutstanding() async {}
    func retire() async {}
}

/// Keeps real source analysis and receipt creation, but models a coherent worker metadata
/// downgrade. The DB must prove the Mach-O format from bytes rather than trust nil identities.
private struct FirstLoadAdmissionDowngradedHeadless: ReconstructionHeadlessAnalysisExecuting {
    let base: any ReconstructionHeadlessAnalysisExecuting
    var downgradesIdentity = true
    var forgesArchitecture = false
    func execute(_ request: ReconstructionHeadlessAnalysisRequest,
        cancellation: ReconstructionCancellation) async throws -> ReconstructionHeadlessAnalysisResult {
        let result: ReconstructionHeadlessAnalysisResult
        do {
            result = try await base.execute(request, cancellation: cancellation)
        } catch {
            XCTFail("First-load headless execution failed: \(type(of: error)): \(error)")
            throw error
        }
        guard downgradesIdentity || forgesArchitecture else { return result }
        let detached = result.detached
        var workspace = detached.workspace
        guard let original = workspace.binaries.first,
              var analysis = workspace.analysis(in: original.slot) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        let binary = BinaryImage(id: original.id, name: original.name, path: original.path,
            kind: original.kind, architecture: forgesArchitecture ? "arm64e" : original.architecture,
            metadata: original.metadata, selectedSliceIndex: original.selectedSliceIndex,
            artifactIdentity: downgradesIdentity ? nil : original.artifactIdentity,
            preferredSegmentLayout: downgradesIdentity ? nil : original.preferredSegmentLayout,
            artifactIntegrityState: downgradesIdentity ? .unavailable : original.artifactIntegrityState,
            slot: original.slot)
        workspace.binaries = [binary]
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        analysis.analysisInputFingerprint = fingerprint
        workspace.replaceAnalysis(analysis, in: original.slot)
        let image = ReconstructionImageBinding(binaryID: detached.image.binaryID,
            imageSlot: detached.image.imageSlot, selectedSliceIndex: detached.image.selectedSliceIndex,
            architecture: forgesArchitecture ? .arm64e : detached.image.architecture,
            machOIdentity: downgradesIdentity ? nil : detached.image.machOIdentity)
        return .init(detached: .init(artifact: detached.artifact, image: image, workspace: workspace,
            analysisInputFingerprintSHA256: fingerprint.overallSHA256), projection: nil)
    }
    func pause() async { await base.pause() }
    func resume() async { await base.resume() }
    func retire() async { await base.retire() }
}

final class ReconstructionDatabaseOwnerMutationTests: XCTestCase {
    func testFirstLoadCheckpointPublishesVerifiedOrdinaryImageWithoutPreanalysis() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario()
        defer { scenario.sourceFixture.remove() }
        let committed = try await scenario.owner.commit(
            workspaceID: scenario.workspaceID, mutation: scenario.mutation
        )
        XCTAssertEqual(committed.checkpoint.checkpointID, scenario.mutation.successorCheckpoint.checkpointID)
        await scenario.owner.revoke()
        let persisted = try loadFirstLoadSnapshot(scenario)
        let image = try XCTUnwrap(persisted.binaries.first)
        let authority = try XCTUnwrap(scenario.mutation.freshnessAuthority.currentImages.first)
        XCTAssertEqual(image.id, authority.image.binaryID)
        XCTAssertEqual(image.slot, authority.image.imageSlot)
        let analysis = try XCTUnwrap(persisted.analysis(in: image.slot))
        XCTAssertEqual(analysis.analysisInputFingerprint?.overallSHA256, authority.analysisFingerprintSHA256)
        XCTAssertEqual(analysis.imageBytes, try Data(contentsOf: scenario.sourceFixture.source.verifiedURL))
        XCTAssertFalse(analysis.functions.isEmpty)
    }

    func testFirstLoadCheckpointRejectsMissingAdmissionWithoutCreatingImage() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario()
        defer { scenario.sourceFixture.remove() }
        try await assertLoadAdmissionRejected(scenario,
            mutation: replacingAnalysisImports(scenario.mutation, with: []))
    }

    func testFirstLoadCheckpointRejectsAdmissionForUnperformedTask() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario()
        defer { scenario.sourceFixture.remove() }
        let original = try XCTUnwrap(scenario.mutation.analysisImports.first)
        let impostor = ReconstructionLoadedImageAdmission(taskID: UUID(), snapshot: original.snapshot)
        try await assertLoadAdmissionRejected(scenario,
            mutation: replacingAnalysisImports(scenario.mutation, with: [impostor]))
    }

    func testFirstLoadCheckpointRejectsChangedBytesDespiteClaimedFingerprint() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario()
        defer { scenario.sourceFixture.remove() }
        let original = try XCTUnwrap(scenario.mutation.analysisImports.first)
        var workspace = original.snapshot.workspace
        workspace.mutateAnalysis(in: original.snapshot.image.imageSlot) {
            $0.imageBytes[0] ^= 0xff
        }
        let changed = ReconstructionLoadedImageAdmission(taskID: original.taskID, snapshot: .init(
            artifact: original.snapshot.artifact, image: original.snapshot.image,
            workspace: workspace,
            analysisInputFingerprintSHA256: original.snapshot.analysisInputFingerprintSHA256))
        try await assertLoadAdmissionRejected(scenario,
            mutation: replacingAnalysisImports(scenario.mutation, with: [changed]))
    }

    func testFirstLoadCheckpointRejectsPrimarySlotCollisionWithoutReplacingUserImage() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario(preexistingImage: true)
        defer { scenario.sourceFixture.remove() }
        try await assertLoadAdmissionRejected(scenario, mutation: scenario.mutation)
    }

    func testFirstLoadCheckpointRejectsCoherentNilMachOIdentityDowngrade() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario(downgradedFormatIdentity: true)
        defer { scenario.sourceFixture.remove() }
        let admission = try XCTUnwrap(scenario.mutation.analysisImports.first)
        XCTAssertNil(admission.snapshot.image.machOIdentity)
        XCTAssertEqual(admission.snapshot.workspace.binaries.first?.artifactIntegrityState, .unavailable)
        try await assertLoadAdmissionRejected(scenario, mutation: scenario.mutation)
    }

    func testFirstLoadCheckpointRejectsCoherentARM64EClaimForARM64Bytes() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario(forgedArchitecture: true)
        defer { scenario.sourceFixture.remove() }
        let admission = try XCTUnwrap(scenario.mutation.analysisImports.first)
        XCTAssertEqual(admission.snapshot.image.architecture, .arm64e)
        XCTAssertEqual(admission.snapshot.image.machOIdentity?.architectureVariant, .arm64)
        try await assertLoadAdmissionRejected(scenario, mutation: scenario.mutation)
    }

    func testFirstLoadImageInsertionRollsBackWithRejectedCheckpointFrontier() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario()
        defer { scenario.sourceFixture.remove() }
        let current = try await scenario.owner.load(workspaceID: scenario.workspaceID)
        let invalid = try Self.checkpointMutation(scenario.mutation,
            currentEvidenceGaps: current.evidenceGaps,
            evidenceGaps: scenario.mutation.evidenceGaps,
            unresolvedEvidenceGapSHA256: String(repeating: "0", count: 64))
        try await assertLoadAdmissionRejected(scenario, mutation: replacingAnalysisImports(
            invalid, with: scenario.mutation.analysisImports))
    }

    func testFirstLoadCheckpointReusesExactlyPersistedImageWithoutDuplicateRows() async throws {
        let scenario = try await makeFirstLoadAdmissionScenario()
        defer { scenario.sourceFixture.remove() }
        let admission = try XCTUnwrap(scenario.mutation.analysisImports.first)
        await scenario.owner.revoke()
        do {
        let database = try WorkspaceDatabase(path: scenario.databaseURL.path)
        let persisted = try XCTUnwrap(database.loadWorkspaceState(workspaceID: scenario.workspaceRowID))
        _ = try database.replaceWorkspaceState(workspaceID: scenario.workspaceRowID,
            workspaceName: persisted.workspace.name, snapshot: admission.snapshot.workspace,
            selectedSidebarItemID: persisted.session.selectedSidebarItemID,
            selectedAddress: persisted.session.selectedAddress, selectedTool: persisted.session.selectedTool,
            editorMode: persisted.session.editorMode, isInspectorPresented: persisted.session.isInspectorPresented,
            sidebarSearchText: persisted.session.sidebarSearchText,
            focusedImageSlot: persisted.session.focusedImageSlot, now: Date())
        }
        let owner = try openFirstLoadOwner(scenario)
        _ = try await owner.commit(workspaceID: scenario.workspaceID, mutation: scenario.mutation)
        await owner.revoke()
        let snapshot = try loadFirstLoadSnapshot(scenario)
        XCTAssertEqual(snapshot.binaries.map(\.id), [admission.snapshot.image.binaryID])
        XCTAssertEqual(snapshot.analysis(in: admission.snapshot.image.imageSlot)?.imageBytes,
            admission.snapshot.workspace.analysis(in: admission.snapshot.image.imageSlot)?.imageBytes)
    }

    private func replacingAnalysisImports(_ base: ReconstructionCheckpointMutation,
        with imports: [ReconstructionLoadedImageAdmission]) -> ReconstructionCheckpointMutation {
        .init(jobID: base.jobID, expectedParentCheckpointID: base.expectedParentCheckpointID,
            expectedParentCheckpointSHA256: base.expectedParentCheckpointSHA256,
            expectedParentRevision: base.expectedParentRevision, evidence: base.evidence,
            evidenceRelations: base.evidenceRelations, evidenceGaps: base.evidenceGaps,
            toolReceipts: base.toolReceipts, modelReceipts: base.modelReceipts,
            finalResults: base.finalResults, newTasks: base.newTasks, taskTransitions: base.taskTransitions,
            freshnessAuthority: base.freshnessAuthority, successorCheckpoint: base.successorCheckpoint,
            successorPauseContext: base.successorPauseContext, analysisImports: imports)
    }

    private func assertLoadAdmissionRejected(_ scenario: FirstLoadAdmissionScenario,
        mutation: ReconstructionCheckpointMutation) async throws {
        let before = try await scenario.owner.load(workspaceID: scenario.workspaceID)
        await scenario.owner.revoke()
        let beforeSnapshot = try loadFirstLoadSnapshot(scenario)
        let owner = try openFirstLoadOwner(scenario)
        do {
            _ = try await owner.commit(workspaceID: scenario.workspaceID, mutation: mutation)
            XCTFail("Invalid load admission must not commit image or checkpoint")
        } catch {
            XCTAssertTrue(error is WorkspaceDatabase.DatabaseError)
        }
        let after = try await owner.load(workspaceID: scenario.workspaceID)
        XCTAssertEqual(after, before)
        await owner.revoke()
        let afterSnapshot = try loadFirstLoadSnapshot(scenario)
        XCTAssertEqual(afterSnapshot.binaries, beforeSnapshot.binaries)
        for binary in beforeSnapshot.binaries {
            XCTAssertEqual(afterSnapshot.analysis(in: binary.slot)?.imageBytes,
                beforeSnapshot.analysis(in: binary.slot)?.imageBytes)
        }
    }

    private struct FirstLoadAdmissionScenario {
        let databaseURL: URL
        let owner: ReconstructionDatabaseOwner
        let workspaceID: UUID
        let workspaceRowID: Int64
        let mutation: ReconstructionCheckpointMutation
        let sourceFixture: ReconstructionRealHeadlessTestFixture
    }

    /// Read connections are created only after the exclusive owner's quiescent revocation.
    private func loadFirstLoadSnapshot(_ scenario: FirstLoadAdmissionScenario) throws -> WorkspaceSnapshot {
        let database = try WorkspaceDatabase(path: scenario.databaseURL.path)
        return try XCTUnwrap(database.loadSnapshot(workspaceID: scenario.workspaceRowID))
    }

    private func openFirstLoadOwner(_ scenario: FirstLoadAdmissionScenario) throws -> ReconstructionDatabaseOwner {
        ReconstructionDatabaseOwner(database: try WorkspaceDatabase(path: scenario.databaseURL.path))
    }

    private func makeFirstLoadAdmissionScenario(preexistingImage: Bool = false,
        downgradedFormatIdentity: Bool = false, forgedArchitecture: Bool = false) async throws -> FirstLoadAdmissionScenario {
        let source = try ReconstructionRealHeadlessTestFixture.make()
        var transfersSource = false
        defer { if !transfersSource { source.remove() } }
        let databaseURL = source.directoryURL.appendingPathComponent("workspace.sqlite")
        let database = try WorkspaceDatabase(path: databaseURL.path)
        try database.applySchema()
        let workspaceID = UUID()
        let workspace = try database.saveSnapshot(workspaceUUID: workspaceID,
            workspaceName: "Fresh load admission", snapshot: preexistingImage
                ? AnalysisEngine.previewSnapshot() : .init(binaries: [], analysisBySlot: [:]))
        let workspaceRowID = try XCTUnwrap(workspace.id)
        let projectID = UUID()
        let imported = await ReconstructionCorpusImporter().ingest(
            selections: [.init(rootURL: source.source.verifiedURL, roles: [.primaryTarget])],
            projectID: projectID, cancellation: ReconstructionCancellation())
        XCTAssertTrue(imported.failures.isEmpty)
        let importedTarget = try XCTUnwrap(imported.occurrences.first)
        XCTAssertEqual(importedTarget.kind, .machOImage)
        XCTAssertFalse(importedTarget.executableMode,
            "Static Mach-O admission must not depend on filesystem execute permission")
        let manifest = try ReconstructionCorpusManifest(reconstructionProjectID: projectID,
            artifacts: imported.occurrences, relations: imported.relations,
            canonicalSHA256: imported.canonicalManifestSHA256)
        let owner = ReconstructionDatabaseOwner(database: database)
        _ = try await owner.commitCorpus(workspaceID: workspaceID, mutation: .init(projectID: projectID,
            expectedCurrentManifestSHA256: nil, successorManifest: manifest,
            attachmentSources: imported.attachmentSources))
        let jobID = UUID()
        _ = try await owner.commitInitialJob(workspaceID: workspaceID, mutation: .init(
            jobID: jobID, projectID: projectID, selectedOccurrenceIDs: imported.occurrences.map(\.occurrenceID),
            objective: "Load the selected target", budget: .init(maxRounds: 4, maxTasks: 128,
                maxEvidenceRecords: 512, maxEncodedBytes: 4 * 1_024 * 1_024)))
        let initialState = try await owner.load(workspaceID: workspaceID)
        XCTAssertTrue(initialState.tasks.contains {
            $0.identity.jobID == jobID && $0.identity.kind == .loadBinary
        }, "A classified non-executable Mach-O must receive a static load task")
        let controller = ReconstructionProductionBatchExecutionController(durableJobID: jobID,
            builder: { basis, _ in
                // Replacing a scheduler pauses its executor. Each candidate must therefore
                // own a fresh analysis pool instead of sharing the predecessor's paused pool.
                let baseHeadless = ReconstructionHeadlessAnalysisExecutor(
                    pool: try ReconstructionAnalysisProviderPool(
                        factory: ReconstructionDefaultAnalysisProviderFactory(),
                        budget: .init(maximumActiveAnalyses: 1,
                            estimatedResidentBytesPerAnalysis: 1, reservedHostBytes: 0)))
                let headless = FirstLoadAdmissionDowngradedHeadless(base: baseHeadless,
                    downgradesIdentity: downgradedFormatIdentity,
                    forgesArchitecture: forgedArchitecture)
                let resolver = try ReconstructionHeadlessAnalysisRequestResolver(manifest: basis.manifest,
                    attachmentSources: basis.attachmentSources, imagesByOccurrence: [:])
                return ReconstructionBatchScheduler(durableJobID: jobID,
                    executor: ReconstructionBatchTaskExecutor(resolver: resolver, headless: headless,
                        native: FirstLoadAdmissionNoNative()))
            }, retireJobAuthority: {})
        let author = ReconstructionProductionReceiptPlanAuthor(modelProducerContext: .init(
            macScopeBuildIdentity: String(repeating: "a", count: 64),
            macScopeSourceIdentity: String(repeating: "b", count: 64),
            operationIdentity: ReconstructionProductionTaskContract.modelRound,
            registryIdentity: "reconstruction.registry.v1",
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
            toolchainIdentity: "load-admission-test"))
        let registry = ReconstructionProductionRoundBasisRegistry()
        let cuts = ReconstructionProductionCommittedRoundCutProvider(workspaceID: workspaceID, owner: owner,
            batchExecutionBuilder: controller, preparedRoundBuilder: try ReconstructionProductionPreparedRoundBuilder(
                evidenceQueryProducer: author.makeToolProducer(operationID: .evidenceQuery)),
            basisRegistry: registry, maximumConcurrentTasks: 1)
        let planBuilder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry, receiptAuthor: author)
        let materializer = ReconstructionProductionJobRoundMaterializer(
            cutProvider: cuts, planBuilder: planBuilder)
        let persistence = ReconstructionDatabaseJobPersistence(workspaceID: workspaceID, owner: owner)
        for _ in 0..<16 {
            let snapshot = try await persistence.load(jobID: jobID)
            let mutation: ReconstructionCheckpointMutation
            do {
                guard case .commit(let plan) = try await materializer.prepare(snapshot: snapshot),
                      let authored = plan.mutation else {
                    throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
                }
                mutation = authored
            } catch {
                XCTFail("First-load materializer failed at revision \(snapshot.checkpointRevision), state \(snapshot.currentDurableJobState), tasks \(snapshot.tasks.map { "\($0.identity.kind):\($0.state)" }); error \(error)")
                throw error
            }
            if !mutation.freshnessAuthority.currentImages.isEmpty {
                await controller.retire(jobID: jobID)
                transfersSource = true
                return .init(databaseURL: databaseURL, owner: owner, workspaceID: workspaceID,
                    workspaceRowID: workspaceRowID, mutation: mutation, sourceFixture: source)
            }
            _ = try await owner.commit(workspaceID: workspaceID, mutation: mutation)
        }
        await controller.retire(jobID: jobID)
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }

    func testOwnerLoadPreservesCancellationError() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let workspaceUUID = fixture.workspaceUUID
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceUUID,
            state: foundation.state
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)

        let error = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await owner.load(workspaceID: workspaceUUID)
                return nil
            } catch {
                return error
            }
        }.value

        XCTAssertTrue(error is CancellationError, "Load erased the structured cancellation")
    }

    func testCheckpointFreshnessAuthorityProjectsGapResolutionWithoutRewritingDurableEvidence()
        async throws {
        func commitProjection(
            includesCurrentAnalysis: Bool
        ) async throws -> (
            persisted: ReconstructionWorkspaceState,
            committed: ReconstructionCommittedCheckpoint,
            projectedClassification: ReconstructionEvidenceClassification,
            gap: ReconstructionEvidenceGap
        ) {
            let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: fixture.binaryID,
                evidenceSubjectUsesImageBinding: true
            )
            let workspaceID = fixture.workspaceUUID
            try fixture.database.replaceReconstructionState(
                workspaceID: workspaceID,
                state: foundation.state
            )
            let owner = ReconstructionDatabaseOwner(database: fixture.database)
            _ = try await owner.commit(
                try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
            )
            let persisted = try await owner.load(
                workspaceID: workspaceID
            )
            let gap = try XCTUnwrap(persisted.evidenceGaps.first)
            let resolver = try XCTUnwrap(persisted.evidence.first)
            let resolution = ReconstructionEvidenceRelation(
                relationID: UUID(uuidString: "38000000-0000-0000-0000-000000000057")!,
                kind: .resolvesGap,
                sourceEvidenceID: resolver.evidenceID,
                targetEvidenceID: gap.gapID
            )
            let authority = try ReconstructionDatabaseTestFixtures.makeFreshnessAuthority(
                from: foundation,
                includesCurrentAnalysis: includesCurrentAnalysis
            )
            let projection = try ReconstructionEvidenceProjector().project(
                records: persisted.evidence,
                relations: persisted.evidenceRelations + [resolution],
                authority: authority
            )
            let projectedClassification = try XCTUnwrap(
                projection.records.first(where: { $0.record.evidenceID == resolver.evidenceID })
            ).classification
            let receipt = try XCTUnwrap(persisted.toolReceipts.first)
            let committed = try await owner.commit(
                try ReconstructionDatabaseTestFixtures.makeReplayMutation(
                    from: persisted,
                    receipt: receipt,
                    freshnessAuthority: authority,
                    evidenceRelations: [resolution]
                )
            )
            return (persisted, committed, projectedClassification, gap)
        }

        let exact = try await commitProjection(includesCurrentAnalysis: true)
        let stale = try await commitProjection(includesCurrentAnalysis: false)

        XCTAssertEqual(exact.projectedClassification, .acceptedCurrent)
        XCTAssertEqual(
            exact.committed.checkpoint.unresolvedEvidenceGapSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [])
        )
        XCTAssertEqual(stale.projectedClassification, .staleAnalysis)
        XCTAssertEqual(
            stale.committed.checkpoint.unresolvedEvidenceGapSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [stale.gap])
        )
        XCTAssertEqual(exact.committed.state.evidence, exact.persisted.evidence)
        XCTAssertEqual(stale.committed.state.evidence, stale.persisted.evidence)
        XCTAssertEqual(
            Set(stale.committed.state.evidence.map(\.classification)),
            [.acceptedCurrent],
            "Freshness projection must not rewrite the durable terminal classification"
        )
    }

    func testCorpusCommitAdvancesOnlyExpectedProjectAndRetainsManifestHistory() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [scenario.source]
        )
        let expectedProjects = try scenario.beforeState.projects.map { project in
            guard project.projectID == Self.targetProjectID else { return project }
            return try ReconstructionProjectRecord(
                projectID: project.projectID,
                schemaVersion: project.schemaVersion,
                name: project.name,
                currentCorpusManifestSHA256: scenario.successorManifest.canonicalSHA256
            )
        }
        let expectedState = try ReconstructionWorkspaceState(
            schemaVersion: scenario.beforeState.schemaVersion,
            projects: expectedProjects,
            corpusManifests: scenario.beforeState.corpusManifests
                + [scenario.successorManifest],
            evidence: scenario.beforeState.evidence,
            evidenceRelations: scenario.beforeState.evidenceRelations,
            evidenceGaps: scenario.beforeState.evidenceGaps,
            jobs: scenario.beforeState.jobs,
            tasks: scenario.beforeState.tasks,
            checkpoints: scenario.beforeState.checkpoints,
            toolReceipts: scenario.beforeState.toolReceipts,
            modelReceipts: scenario.beforeState.modelReceipts
        )

        let committed = try await scenario.owner.commitCorpus(
            workspaceID: scenario.workspaceUUID,
            mutation: mutation
        )

        XCTAssertEqual(committed.state, expectedState)
        let persistedState = try await scenario.owner.load(workspaceID: scenario.workspaceUUID)
        XCTAssertEqual(persistedState, expectedState)
        let committedSource = try XCTUnwrap(committed.attachmentSources.first)
        XCTAssertEqual(committed.attachmentSources.count, 1)
        XCTAssertEqual(committedSource.contentIdentity, scenario.source.contentIdentity)
        XCTAssertNotEqual(committedSource.verifiedURL, scenario.source.verifiedURL)
        XCTAssertEqual(committed.commitSequence, 1)
    }

    func testCorpusCommitPublishesCrashDurableVaultSourceBeforeDatabaseState() async throws {
        let vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReconstructionDurableVault-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: vaultRoot) }
        let scenario = try Self.makeCorpusScenario(attachmentVaultRootURL: vaultRoot)
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [scenario.source]
        )

        let committed = try await scenario.owner.commitCorpus(
            workspaceID: scenario.workspaceUUID,
            mutation: mutation
        )
        let durableSource = try XCTUnwrap(committed.attachmentSources.first)
        XCTAssertNotEqual(durableSource.verifiedURL, scenario.source.verifiedURL)
        XCTAssertTrue(durableSource.verifiedURL.path.hasPrefix(vaultRoot.path + "/"))

        try FileManager.default.removeItem(at: scenario.source.verifiedURL)
        let recovered = try await scenario.owner.availableDurableAttachmentSources(
            workspaceID: scenario.workspaceUUID
        )

        XCTAssertEqual(recovered.map(\.contentIdentity), [scenario.source.contentIdentity])
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(recovered.first).verifiedURL),
            scenario.successorBytes
        )
    }

    func testCorpusCommitRejectsSymbolicLinkSourceWithoutFollowingIt() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let symlinkURL = scenario.temporaryRoot.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: scenario.source.verifiedURL
        )
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: scenario.source.contentIdentity,
                    verifiedURL: symlinkURL
                ),
            ]
        )

        let error = try await assertCorpusCommitRejected(mutation, in: scenario)

        XCTAssertEqual(
            error as? WorkspaceDatabase.DatabaseError,
            .reconstructionAttachmentSourcesUnavailable
        )
    }

    func testCorpusCommitRejectsHardLinkedSource() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let hardLinkURL = scenario.temporaryRoot.appendingPathComponent("source-hard-link")
        try FileManager.default.linkItem(
            at: scenario.source.verifiedURL,
            to: hardLinkURL
        )
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: scenario.source.contentIdentity,
                    verifiedURL: hardLinkURL
                ),
            ]
        )

        let error = try await assertCorpusCommitRejected(mutation, in: scenario)

        XCTAssertEqual(
            error as? WorkspaceDatabase.DatabaseError,
            .reconstructionAttachmentSourcesUnavailable
        )
    }

    func testCorpusCommitRejectsFIFOWithoutWaitingForAWriter() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let fifoURL = scenario.temporaryRoot.appendingPathComponent("source-fifo")
        let status = fifoURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, 0o600) } ?? -1
        }
        XCTAssertEqual(status, 0)
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: scenario.source.contentIdentity,
                    verifiedURL: fifoURL
                ),
            ]
        )

        let error = try await assertCorpusCommitRejected(mutation, in: scenario)

        XCTAssertEqual(
            error as? WorkspaceDatabase.DatabaseError,
            .reconstructionAttachmentSourcesUnavailable
        )
    }

    func testOwnerCommitSequenceOrdersCorpusBeforeCheckpoint() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let corpus = try await scenario.owner.commitCorpus(
            workspaceID: scenario.workspaceUUID,
            mutation: ReconstructionCorpusMutation(
                projectID: Self.targetProjectID,
                expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
                successorManifest: scenario.successorManifest,
                attachmentSources: [scenario.source]
            )
        )
        let receipt = try XCTUnwrap(corpus.state.toolReceipts.first)
        let checkpoint = try await scenario.owner.commit(
            workspaceID: scenario.workspaceUUID,
            mutation: try ReconstructionDatabaseTestFixtures.makeReplayMutation(
                from: corpus.state,
                receipt: receipt
            )
        )

        XCTAssertEqual(corpus.commitSequence, 1)
        XCTAssertEqual(checkpoint.commitSequence, 2)
    }

    func testCheckpointFrontierExcludesGapOwnedByAnotherProject() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let corpus = try await scenario.owner.commitCorpus(
            workspaceID: scenario.workspaceUUID,
            mutation: ReconstructionCorpusMutation(
                projectID: Self.targetProjectID,
                expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
                successorManifest: scenario.successorManifest,
                attachmentSources: [scenario.source]
            )
        )
        let receipt = try XCTUnwrap(corpus.state.toolReceipts.first)
        let mutation = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: corpus.state,
            receipt: receipt
        )

        let committed = try await scenario.owner.commit(
            workspaceID: scenario.workspaceUUID,
            mutation: mutation
        )

        let creatingProjectGap = try XCTUnwrap(
            corpus.state.evidenceGaps.first { $0.gapID == ReconstructionDatabaseTestFixtures.gapUUID }
        )
        XCTAssertEqual(
            committed.checkpoint.unresolvedEvidenceGapSHA256,
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [creatingProjectGap])
        )
    }

    func testCheckpointCommitRejectsRelationToGapOwnedByAnotherProject() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let corpus = try await scenario.owner.commitCorpus(
            workspaceID: scenario.workspaceUUID,
            mutation: ReconstructionCorpusMutation(
                projectID: Self.targetProjectID,
                expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
                successorManifest: scenario.successorManifest,
                attachmentSources: [scenario.source]
            )
        )
        let receipt = try XCTUnwrap(corpus.state.toolReceipts.first)
        let sourceEvidence = try XCTUnwrap(corpus.state.evidence.first)
        let foreignGap = try XCTUnwrap(
            corpus.state.evidenceGaps.first { $0.gapID == Self.foreignGapID }
        )
        let relation = ReconstructionEvidenceRelation(
            relationID: UUID(uuidString: "38000000-0000-0000-0000-000000000104")!,
            kind: .resolvesGap,
            sourceEvidenceID: sourceEvidence.evidenceID,
            targetEvidenceID: foreignGap.gapID
        )
        let mutation = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: corpus.state,
            receipt: receipt,
            evidenceRelations: [relation]
        )

        var rejection: Error?
        do {
            _ = try await scenario.owner.commit(
                workspaceID: scenario.workspaceUUID,
                mutation: mutation
            )
        } catch {
            rejection = error
        }

        XCTAssertEqual(
            rejection as? WorkspaceDatabase.DatabaseError,
            .reconstructionStateInvalid(
                "package-v3 graph: evidence relation project ownership"
            )
        )
    }

    func testCheckpointCommitRejectsFreshnessCapturedBeforePersistedAnalysisChanged()
        async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID,
            evidenceSubjectUsesImageBinding: true
        )
        let workspaceID = fixture.workspaceUUID
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceID,
            state: foundation.state
        )
        let mutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        try ReconstructionDatabaseTestFixtures.replacePersistedAnalysisFingerprint(
            in: fixture,
            overallSHA256: ReconstructionDatabaseTestFixtures.digest("9")
        )
        let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)

        var rejection: Error?
        do {
            _ = try await owner.commit(mutation)
        } catch {
            rejection = error
        }

        XCTAssertEqual(
            rejection as? WorkspaceDatabase.DatabaseError,
            .reconstructionCheckpointConflict("workspace analysis authority changed")
        )
        let persistedState = try await owner.load(workspaceID: workspaceID)
        XCTAssertEqual(persistedState, foundation.state)
        let afterProjection = try await owner.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        XCTAssertEqual(afterProjection, beforeProjection)
    }

    func testCorpusCommitExpectedTokenConflictRollsBackWithoutPublishingSources() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: ReconstructionDatabaseTestFixtures.digest("f"),
            successorManifest: scenario.successorManifest,
            attachmentSources: [scenario.source]
        )

        _ = try await assertCorpusCommitRejected(mutation, in: scenario)
    }

    func testCorpusCommitInjectedPersistenceFailureRollsBackWithoutPublishingSources() async throws {
        let scenario = try Self.makeCorpusScenario(failureAfter: .insertedProjects)
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [scenario.source]
        )
        let error = try await assertCorpusCommitRejected(mutation, in: scenario)

        XCTAssertEqual(
            error as? WorkspaceDatabase.DatabaseError,
            .reconstructionInjectedFailure(
                WorkspaceDatabase.ReconstructionMutationPhase.insertedProjects.rawValue
            )
        )
    }

    func testCorpusCommitRejectsMismatchedCanonicalManifestDigestBeforeReplacement() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let invalidManifest = try ReconstructionCorpusManifest(
            schemaVersion: scenario.successorManifest.schemaVersion,
            reconstructionProjectID: scenario.successorManifest.reconstructionProjectID,
            artifacts: scenario.successorManifest.artifacts,
            relations: scenario.successorManifest.relations,
            canonicalSHA256: ReconstructionDatabaseTestFixtures.digest("d")
        )
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: invalidManifest,
            attachmentSources: [scenario.source]
        )

        _ = try await assertCorpusCommitRejected(mutation, in: scenario)
    }

    func testCorpusCommitRejectsSourceWhoseBytesDoNotMatchClaimedContent() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        try Data("tampered after catalog creation".utf8).write(
            to: scenario.source.verifiedURL
        )
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: scenario.successorManifest,
            attachmentSources: [scenario.source]
        )

        _ = try await assertCorpusCommitRejected(mutation, in: scenario)
    }

    func testCorpusCommitRejectsReusedOccurrenceIDWithChangedContent() async throws {
        let scenario = try Self.makeCorpusScenario()
        defer { try? FileManager.default.removeItem(at: scenario.temporaryRoot) }
        let reusedOccurrence = try Self.makeOccurrence(
            bytes: Data("successor target corpus".utf8),
            occurrenceID: Self.currentTargetOccurrenceID
        )
        let invalidManifest = try Self.makeManifest(artifacts: [reusedOccurrence])
        let mutation = ReconstructionCorpusMutation(
            projectID: Self.targetProjectID,
            expectedCurrentManifestSHA256: scenario.currentManifest.canonicalSHA256,
            successorManifest: invalidManifest,
            attachmentSources: [scenario.source]
        )

        _ = try await assertCorpusCommitRejected(mutation, in: scenario)
    }

    func testCheckpointCommitAppendsEvidenceAndFreshGapInOneFrontier() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        let workspaceID = fixture.workspaceUUID
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceID,
            state: foundation.state
        )
        let baseMutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        let freshGap = try Self.makeFreshGap(from: foundation)
        let mutation = try Self.checkpointMutation(
            baseMutation,
            currentEvidenceGaps: foundation.state.evidenceGaps,
            evidenceGaps: [freshGap]
        )
        let richState = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID
        )
        let expectedState = try ReconstructionWorkspaceState(
            schemaVersion: richState.schemaVersion,
            projects: richState.projects,
            corpusManifests: richState.corpusManifests,
            evidence: richState.evidence,
            evidenceRelations: richState.evidenceRelations,
            evidenceGaps: richState.evidenceGaps + [freshGap],
            jobs: richState.jobs,
            tasks: richState.tasks,
            checkpoints: richState.checkpoints.map {
                $0.checkpointID == mutation.successorCheckpoint.checkpointID
                    ? mutation.successorCheckpoint
                    : $0
            },
            toolReceipts: richState.toolReceipts,
            modelReceipts: richState.modelReceipts
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)

        let committed = try await owner.commit(mutation)

        XCTAssertEqual(committed.checkpoint, mutation.successorCheckpoint)
        let persistedState = try await owner.load(workspaceID: workspaceID)
        XCTAssertEqual(persistedState, expectedState)
    }

    func testCheckpointCommitWithExistingGapIDRollsBackEntireMutation() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        let workspaceID = fixture.workspaceUUID
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceID,
            state: foundation.state
        )
        let baseMutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        let mutation = try Self.checkpointMutation(
            baseMutation,
            currentEvidenceGaps: foundation.state.evidenceGaps,
            evidenceGaps: [
                try Self.makeFreshGap(from: foundation),
                try XCTUnwrap(foundation.state.evidenceGaps.first),
            ],
            unresolvedEvidenceGapSHA256: baseMutation.successorCheckpoint
                .unresolvedEvidenceGapSHA256
        )

        let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)
        try await assertCheckpointCommitRejected(
            mutation,
            owner: owner,
            workspaceID: workspaceID,
            beforeProjection: beforeProjection,
            expectedState: foundation.state
        )
    }

    func testCheckpointCommitRejectsUnknownFreshGapOperationAtomically() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let freshGap = try Self.makeFreshGap(
            from: foundation,
            operationID: "reconstruction.unknown-operation.v1"
        )
        let mutation = try Self.checkpointMutation(
            try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
            currentEvidenceGaps: foundation.state.evidenceGaps,
            evidenceGaps: [freshGap],
            unresolvedEvidenceGapSHA256: ReconstructionDatabaseTestFixtures.digest("0")
        )

        let workspaceID = fixture.workspaceUUID
        let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)
        try await assertCheckpointCommitRejected(
            mutation,
            owner: owner,
            workspaceID: workspaceID,
            beforeProjection: beforeProjection,
            expectedState: foundation.state
        )
    }

    func testCheckpointCommitRejectsMismatchedCompleteGapFrontierAtomically() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let freshGap = try Self.makeFreshGap(from: foundation)
        let incorrectFrontier = ReconstructionDatabaseTestFixtures.digest("0")
        XCTAssertNotEqual(
            try ReconstructionEvidenceGapFrontier.canonicalSHA256(
                for: foundation.state.evidenceGaps + [freshGap]
            ),
            incorrectFrontier
        )
        let mutation = try Self.checkpointMutation(
            try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
            currentEvidenceGaps: foundation.state.evidenceGaps,
            evidenceGaps: [freshGap],
            unresolvedEvidenceGapSHA256: incorrectFrontier
        )

        let workspaceID = fixture.workspaceUUID
        let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)
        try await assertCheckpointCommitRejected(
            mutation,
            owner: owner,
            workspaceID: workspaceID,
            beforeProjection: beforeProjection,
            expectedState: foundation.state
        )
    }

    func testCheckpointCommitPersistsPauseContextAndResumeClearsItAtomically() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        let workspaceID = fixture.workspaceUUID
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceID,
            state: foundation.state
        )
        let context = try ReconstructionJobPauseContext(
            cause: .modelUnavailable,
            resumeTarget: .retrieving
        )
        let pauseMutation = try Self.checkpointMutation(
            ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
            coordinatorState: .paused,
            successorPauseContext: context
        )
        let paused = try fixture.database.commitReconstructionCheckpoint(
            workspaceID: workspaceID,
            mutation: pauseMutation
        )

        XCTAssertEqual(paused.state.jobs.first?.state, .paused)
        XCTAssertEqual(paused.state.jobs.first?.pauseContext, context)
        let reloadedPaused = try fixture.database.loadReconstructionState(workspaceID: workspaceID)
        XCTAssertEqual(reloadedPaused.jobs.first?.pauseContext, context)
        let encodedPause = try ReconstructionPackageCodec.encode(paused.state)
        let checkpointObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedPause.checkpointData) as? [String: Any]
        )
        let encodedJobs = try XCTUnwrap(checkpointObject["jobs"] as? [[String: Any]])
        XCTAssertNotNil(encodedJobs.first?["pauseContext"])

        let pausedJob = try XCTUnwrap(paused.state.jobs.first)
        let forgedContext = try ReconstructionJobPauseContext(
            cause: context.cause,
            resumeTarget: .awaitingModel
        )
        let forgedJob = try ReconstructionJobRecord(
            jobID: pausedJob.jobID,
            reconstructionProjectID: pausedJob.reconstructionProjectID,
            objective: pausedJob.objective,
            objectiveSHA256: pausedJob.objectiveSHA256,
            creationCorpusManifestSHA256: pausedJob.creationCorpusManifestSHA256,
            state: pausedJob.state,
            currentCheckpointID: pausedJob.currentCheckpointID,
            terminalReason: pausedJob.terminalReason,
            budget: pausedJob.budget,
            creationOrdinal: try XCTUnwrap(pausedJob.creationOrdinal),
            pauseContext: forgedContext
        )
        let forgedState = try ReconstructionWorkspaceState(
            projects: paused.state.projects,
            corpusManifests: paused.state.corpusManifests,
            evidence: paused.state.evidence,
            evidenceRelations: paused.state.evidenceRelations,
            evidenceGaps: paused.state.evidenceGaps,
            jobs: [forgedJob],
            tasks: paused.state.tasks,
            checkpoints: paused.state.checkpoints,
            toolReceipts: paused.state.toolReceipts,
            modelReceipts: paused.state.modelReceipts
        )
        XCTAssertThrowsError(
            try fixture.database.replaceReconstructionState(
                workspaceID: workspaceID,
                state: forgedState
            )
        )

        var hostileCheckpointObject = checkpointObject
        var hostileJobs = encodedJobs
        var hostileJob = try XCTUnwrap(hostileJobs.first)
        var hostilePauseContext = try XCTUnwrap(
            hostileJob["pauseContext"] as? [String: Any]
        )
        hostilePauseContext["resumeTarget"] = ReconstructionJobState.awaitingModel.rawValue
        hostileJob["pauseContext"] = hostilePauseContext
        hostileJobs[0] = hostileJob
        hostileCheckpointObject["jobs"] = hostileJobs
        let hostileCheckpointData = try JSONSerialization.data(
            withJSONObject: hostileCheckpointObject,
            options: [.sortedKeys]
        )
        let hostileDescriptor = try ReconstructionPackageDescriptor(
            corpusManifestPath: encodedPause.descriptor.corpusManifestPath,
            evidenceManifestPath: encodedPause.descriptor.evidenceManifestPath,
            checkpointManifestPath: encodedPause.descriptor.checkpointManifestPath,
            corpusManifestSHA256: encodedPause.descriptor.corpusManifestSHA256,
            evidenceManifestSHA256: encodedPause.descriptor.evidenceManifestSHA256,
            checkpointManifestSHA256: ReconstructionPackageFixture.digest(hostileCheckpointData)
        )
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.decode(
                descriptor: hostileDescriptor,
                corpusData: encodedPause.corpusData,
                evidenceData: encodedPause.evidenceData,
                checkpointData: hostileCheckpointData
            )
        )

        let receipt = try XCTUnwrap(paused.state.toolReceipts.first)
        let resumeMutation = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: paused.state,
            receipt: receipt
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)
        let resumed = try await owner.commit(resumeMutation)

        XCTAssertEqual(resumed.state.jobs.first?.state, .retrieving)
        XCTAssertNil(resumed.state.jobs.first?.pauseContext)
        let reloadedResumed = try await owner.load(workspaceID: workspaceID)
        XCTAssertNil(reloadedResumed.jobs.first?.pauseContext)
    }

    func testCheckpointCommitRejectsMissingPauseContextAndPausedContextRewriteAtomically()
        async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        let workspaceID = fixture.workspaceUUID
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceID,
            state: foundation.state
        )
        let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)
        let missingContext = try Self.checkpointMutation(
            ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
            coordinatorState: .paused,
            successorPauseContext: nil
        )

        try await assertCheckpointCommitRejected(
            missingContext,
            owner: owner,
            workspaceID: workspaceID,
            beforeProjection: beforeProjection,
            expectedState: foundation.state,
            expectedError: .reconstructionCheckpointConflict(
                "job state or pause context transition"
            )
        )

        let durableContext = try ReconstructionJobPauseContext(
            cause: .inferenceBusy,
            resumeTarget: .retrieving
        )
        let paused = try await owner.commit(
            Self.checkpointMutation(
                ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
                coordinatorState: .paused,
                successorPauseContext: durableContext
            )
        )
        let receipt = try XCTUnwrap(paused.state.toolReceipts.first)
        let rewriteBase = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: paused.state,
            receipt: receipt
        )
        let rewrite = try Self.checkpointMutation(
            rewriteBase,
            coordinatorState: .paused,
            successorPauseContext: try ReconstructionJobPauseContext(
                cause: .evidenceStalled,
                resumeTarget: .retrieving
            )
        )
        let pausedProjection = try await owner.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )

        try await assertCheckpointCommitRejected(
            rewrite,
            owner: owner,
            workspaceID: workspaceID,
            beforeProjection: pausedProjection,
            expectedState: paused.state,
            expectedError: .reconstructionCheckpointConflict(
                "job state or pause context transition"
            )
        )
    }

    func testCheckpointCommitRejectsResumeToTransientSuccessorInsteadOfDurableTargetAtomically()
        async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        let workspaceID = fixture.workspaceUUID
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceID,
            state: foundation.state
        )
        let owner = ReconstructionDatabaseOwner(database: fixture.database)
        let durableContext = try ReconstructionJobPauseContext(
            cause: .frontierMismatch,
            resumeTarget: .retrieving
        )
        let paused = try await owner.commit(
            Self.checkpointMutation(
                ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
                coordinatorState: .paused,
                successorPauseContext: durableContext
            )
        )
        let receipt = try XCTUnwrap(paused.state.toolReceipts.first)
        let transientResume = try Self.checkpointMutation(
            ReconstructionDatabaseTestFixtures.makeReplayMutation(
                from: paused.state,
                receipt: receipt
            ),
            coordinatorState: .awaitingModel,
            successorPauseContext: nil
        )
        let beforeProjection = try await owner.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )

        try await assertCheckpointCommitRejected(
            transientResume,
            owner: owner,
            workspaceID: workspaceID,
            beforeProjection: beforeProjection,
            expectedState: paused.state,
            expectedError: .reconstructionCheckpointConflict(
                "job state or pause context transition"
            )
        )
    }

    func testPausedCheckpointMayCancelOrFailOnlyWhileClearingPauseContextAtomically()
        async throws {
        for terminalState in [ReconstructionJobState.cancelled, .failed] {
            let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: fixture.binaryID
            )
            let workspaceID = fixture.workspaceUUID
            try fixture.database.replaceReconstructionState(
                workspaceID: workspaceID,
                state: foundation.state
            )
            let durableContext = try ReconstructionJobPauseContext(
                cause: .pausedByUser,
                resumeTarget: .retrieving
            )
            let owner = ReconstructionDatabaseOwner(database: fixture.database)
            let paused = try await owner.commit(
                Self.checkpointMutation(
                    ReconstructionDatabaseTestFixtures.makeMutation(from: foundation),
                    coordinatorState: .paused,
                    successorPauseContext: durableContext
                )
            )
            let receipt = try XCTUnwrap(paused.state.toolReceipts.first)
            let terminalReason = ReconstructionDiagnostic.sanitizing(
                terminalState == .cancelled
                    ? "Reconstruction job was cancelled."
                    : "Reconstruction job failed."
            )
            let terminalBase = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
                from: paused.state,
                receipt: receipt
            )
            let lingeringContext = try Self.checkpointMutation(
                terminalBase,
                coordinatorState: terminalState,
                terminalReason: terminalReason,
                successorPauseContext: durableContext
            )
            let pausedProjection = try await owner.reconstructionProjectionSnapshotForTesting(
                workspaceID: workspaceID
            )
            try await assertCheckpointCommitRejected(
                lingeringContext,
                owner: owner,
                workspaceID: workspaceID,
                beforeProjection: pausedProjection,
                expectedState: paused.state,
                expectedError: .reconstructionCheckpointConflict(
                    "job state or pause context transition"
                )
            )

            let terminal = try await owner.commit(Self.checkpointMutation(
                terminalBase,
                coordinatorState: terminalState,
                terminalReason: terminalReason,
                successorPauseContext: nil
            ))

            XCTAssertEqual(terminal.state.jobs.first?.state, terminalState)
            XCTAssertEqual(terminal.state.jobs.first?.terminalReason, terminalReason)
            XCTAssertNil(terminal.state.jobs.first?.pauseContext)
            let reloaded = try await owner.load(workspaceID: workspaceID)
            XCTAssertEqual(reloaded.jobs.first?.state, terminalState)
            XCTAssertNil(reloaded.jobs.first?.pauseContext)
        }
    }

    private func assertCorpusCommitRejected(
        _ mutation: ReconstructionCorpusMutation,
        in scenario: CorpusScenario
    ) async throws -> Error {
        let beforeProjection = try await scenario.owner
            .reconstructionProjectionSnapshotForTesting(workspaceID: scenario.workspaceUUID)
        var publishedSources: [ReconstructionAttachmentSource]?
        var rejection: Error?
        do {
            publishedSources = try await scenario.owner.commitCorpus(
                workspaceID: scenario.workspaceUUID,
                mutation: mutation
            ).attachmentSources
        } catch {
            rejection = error
        }

        XCTAssertNotNil(rejection, "Invalid corpus mutation unexpectedly committed")
        XCTAssertNil(publishedSources, "Rejected mutation returned a committed source catalog")
        let persistedState = try await scenario.owner.load(workspaceID: scenario.workspaceUUID)
        let persistedProjection = try await scenario.owner
            .reconstructionProjectionSnapshotForTesting(workspaceID: scenario.workspaceUUID)
        XCTAssertEqual(persistedState, scenario.beforeState)
        XCTAssertEqual(persistedProjection, beforeProjection)
        return try XCTUnwrap(rejection)
    }

    private func assertCheckpointCommitRejected(
        _ mutation: ReconstructionCheckpointMutation,
        owner: ReconstructionDatabaseOwner,
        workspaceID: UUID,
        beforeProjection: [String],
        expectedState: ReconstructionWorkspaceState,
        expectedError: WorkspaceDatabase.DatabaseError? = nil
    ) async throws {
        var rejection: Error?
        do {
            _ = try await owner.commit(mutation)
        } catch {
            rejection = error
        }

        XCTAssertNotNil(rejection, "Invalid checkpoint mutation unexpectedly committed")
        if let expectedError {
            XCTAssertEqual(rejection as? WorkspaceDatabase.DatabaseError, expectedError)
        }
        let persistedState = try await owner.load(workspaceID: workspaceID)
        let persistedProjection = try await owner.reconstructionProjectionSnapshotForTesting(
            workspaceID: workspaceID
        )
        XCTAssertEqual(persistedState, expectedState)
        XCTAssertEqual(persistedProjection, beforeProjection)
    }

    private static func checkpointMutation(
        _ base: ReconstructionCheckpointMutation,
        currentEvidenceGaps: [ReconstructionEvidenceGap],
        evidenceGaps: [ReconstructionEvidenceGap],
        evidenceRelations suppliedEvidenceRelations: [ReconstructionEvidenceRelation]? = nil,
        freshnessAuthority suppliedFreshnessAuthority: ReconstructionFreshnessAuthority? = nil,
        unresolvedEvidenceGapSHA256: String? = nil
    ) throws -> ReconstructionCheckpointMutation {
        let successor = base.successorCheckpoint
        let freshnessAuthority = suppliedFreshnessAuthority ?? base.freshnessAuthority
        let evidenceRelations = suppliedEvidenceRelations ?? base.evidenceRelations
        let allGaps = currentEvidenceGaps + evidenceGaps
        let projection = try ReconstructionEvidenceProjector().project(
            records: base.evidence,
            relations: evidenceRelations,
            authority: freshnessAuthority
        )
        let projectedClassifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        let gapFrontierSHA256: String
        if let unresolvedEvidenceGapSHA256 {
            gapFrontierSHA256 = unresolvedEvidenceGapSHA256
        } else {
            gapFrontierSHA256 = try ReconstructionGapProjector().project(
                gaps: allGaps,
                records: base.evidence,
                relations: evidenceRelations,
                projectedClassificationsByEvidenceID: projectedClassifications
            ).unresolvedGapFrontierSHA256
        }
        let evidenceFrontierSHA256 = (try? ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: successor.corpusManifestSHA256,
            records: base.evidence,
            projectedClassificationsByEvidenceID: projectedClassifications,
            relations: evidenceRelations,
            gaps: allGaps,
            checkpointRevisionsByID: [successor.checkpointID: successor.revision]
        )) ?? successor.evidenceFrontierSHA256
        let updatedSuccessor = try ReconstructionCheckpoint.make(
            checkpointID: successor.checkpointID,
            schemaVersion: successor.schemaVersion,
            jobID: successor.jobID,
            revision: successor.revision,
            parentCheckpointID: successor.parentCheckpointID,
            parentCheckpointSHA256: successor.parentCheckpointSHA256,
            corpusManifestSHA256: successor.corpusManifestSHA256,
            evidenceFrontierSHA256: evidenceFrontierSHA256,
            pendingTaskIDs: successor.pendingTaskIDs,
            runningTaskIDs: successor.runningTaskIDs,
            completedTaskIDs: successor.completedTaskIDs,
            failedTaskIDs: successor.failedTaskIDs,
            blockedTaskIDs: successor.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: gapFrontierSHA256,
            modelReceiptIDs: successor.modelReceiptIDs,
            toolReceiptIDs: successor.toolReceiptIDs,
            coordinatorState: successor.coordinatorState,
            terminalReason: successor.terminalReason
        )
        return ReconstructionCheckpointMutation(
            jobID: base.jobID,
            expectedParentCheckpointID: base.expectedParentCheckpointID,
            expectedParentCheckpointSHA256: base.expectedParentCheckpointSHA256,
            expectedParentRevision: base.expectedParentRevision,
            evidence: base.evidence,
            evidenceRelations: evidenceRelations,
            evidenceGaps: evidenceGaps,
            toolReceipts: base.toolReceipts,
            modelReceipts: base.modelReceipts,
            newTasks: base.newTasks,
            taskTransitions: base.taskTransitions,
            freshnessAuthority: freshnessAuthority,
            successorCheckpoint: updatedSuccessor,
            successorPauseContext: base.successorPauseContext
        )
    }

    private static func checkpointMutation(
        _ base: ReconstructionCheckpointMutation,
        coordinatorState: ReconstructionJobState,
        terminalReason: ReconstructionDiagnostic? = nil,
        successorPauseContext: ReconstructionJobPauseContext?
    ) throws -> ReconstructionCheckpointMutation {
        let checkpoint = base.successorCheckpoint
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: checkpoint.checkpointID,
            schemaVersion: checkpoint.schemaVersion,
            jobID: checkpoint.jobID,
            revision: checkpoint.revision,
            parentCheckpointID: checkpoint.parentCheckpointID,
            parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: checkpoint.pendingTaskIDs,
            runningTaskIDs: checkpoint.runningTaskIDs,
            completedTaskIDs: checkpoint.completedTaskIDs,
            failedTaskIDs: checkpoint.failedTaskIDs,
            blockedTaskIDs: checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: checkpoint.modelReceiptIDs,
            toolReceiptIDs: checkpoint.toolReceiptIDs,
            coordinatorState: coordinatorState,
            terminalReason: terminalReason
        )
        return ReconstructionCheckpointMutation(
            jobID: base.jobID,
            expectedParentCheckpointID: base.expectedParentCheckpointID,
            expectedParentCheckpointSHA256: base.expectedParentCheckpointSHA256,
            expectedParentRevision: base.expectedParentRevision,
            evidence: base.evidence,
            evidenceRelations: base.evidenceRelations,
            evidenceGaps: base.evidenceGaps,
            toolReceipts: base.toolReceipts,
            modelReceipts: base.modelReceipts,
            newTasks: base.newTasks,
            taskTransitions: base.taskTransitions,
            freshnessAuthority: base.freshnessAuthority,
            successorCheckpoint: successor,
            successorPauseContext: successorPauseContext
        )
    }

    private static func makeFreshGap(
        from foundation: ReconstructionDatabaseTestFixtures.StateFixture,
        operationID: String = ReconstructionOperationID.evidenceQuery.rawValue
    ) throws -> ReconstructionEvidenceGap {
        try ReconstructionDatabaseTestFixtures.makeGap(
            gapID: UUID(uuidString: "38000000-0000-0000-0000-000000000055")!,
            subject: try XCTUnwrap(foundation.task.identity.subject),
            operationID: operationID,
            reason: .sanitizing("newly unresolved evidence")
        )
    }

    private struct CorpusScenario {
        let owner: ReconstructionDatabaseOwner
        let workspaceUUID: UUID
        let beforeState: ReconstructionWorkspaceState
        let currentManifest: ReconstructionCorpusManifest
        let successorManifest: ReconstructionCorpusManifest
        let source: ReconstructionAttachmentSource
        let successorBytes: Data
        let temporaryRoot: URL
    }

    private static let targetProjectID = UUID(
        uuidString: "38000000-0000-0000-0000-000000000100"
    )!
    private static let currentTargetOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: UUID(uuidString: "38000000-0000-0000-0000-000000000101")!
    )
    private static let successorTargetOccurrenceID = ReconstructionArtifactOccurrenceID(
        rawValue: UUID(uuidString: "38000000-0000-0000-0000-000000000102")!
    )
    private static let foreignGapID = UUID(
        uuidString: "38000000-0000-0000-0000-000000000103"
    )!

    private static func makeCorpusScenario(
        failureAfter mutationPhase: WorkspaceDatabase.ReconstructionMutationPhase? = nil,
        attachmentVaultRootURL: URL? = nil
    ) throws -> CorpusScenario {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let workspaceUUID = fixture.workspaceUUID
        let unrelatedState = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: fixture.binaryID
        )
        let currentBytes = Data("prior target corpus".utf8)
        let successorBytes = Data("successor target corpus".utf8)
        let currentOccurrence = try makeOccurrence(
            bytes: currentBytes,
            occurrenceID: currentTargetOccurrenceID
        )
        let successorOccurrence = try makeOccurrence(
            bytes: successorBytes,
            occurrenceID: successorTargetOccurrenceID
        )
        let currentManifest = try makeManifest(artifacts: [currentOccurrence])
        let successorManifest = try makeManifest(artifacts: [successorOccurrence])
        let targetProject = try ReconstructionProjectRecord(
            projectID: targetProjectID,
            name: "Target Project",
            currentCorpusManifestSHA256: currentManifest.canonicalSHA256
        )
        let foreignGap = try ReconstructionDatabaseTestFixtures.makeGap(
            gapID: foreignGapID,
            subject: .artifact(
                ReconstructionArtifactCoordinate(
                    occurrenceID: currentTargetOccurrenceID,
                    contentIdentity: currentOccurrence.contentIdentity
                )
            ),
            operationID: ReconstructionOperationID.evidenceQuery.rawValue,
            reason: .sanitizing("foreign project gap")
        )
        let beforeState = try ReconstructionWorkspaceState(
            schemaVersion: unrelatedState.schemaVersion,
            projects: unrelatedState.projects + [targetProject],
            corpusManifests: unrelatedState.corpusManifests + [currentManifest],
            evidence: unrelatedState.evidence,
            evidenceRelations: unrelatedState.evidenceRelations,
            evidenceGaps: unrelatedState.evidenceGaps + [foreignGap],
            jobs: unrelatedState.jobs,
            tasks: unrelatedState.tasks,
            checkpoints: unrelatedState.checkpoints,
            toolReceipts: unrelatedState.toolReceipts,
            modelReceipts: unrelatedState.modelReceipts
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: workspaceUUID,
            state: beforeState
        )
        fixture.database.setReconstructionMutationFailureForTesting(after: mutationPhase)

        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReconstructionCorpusCommit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        let sourceURL = temporaryRoot.appendingPathComponent("target.c")
        try successorBytes.write(to: sourceURL)
        return CorpusScenario(
            owner: ReconstructionDatabaseOwner(
                database: fixture.database,
                attachmentVaultRootURL: attachmentVaultRootURL
            ),
            workspaceUUID: workspaceUUID,
            beforeState: beforeState,
            currentManifest: currentManifest,
            successorManifest: successorManifest,
            source: ReconstructionAttachmentSource(
                contentIdentity: successorOccurrence.contentIdentity,
                verifiedURL: sourceURL
            ),
            successorBytes: successorBytes,
            temporaryRoot: temporaryRoot
        )
    }

    private static func makeOccurrence(
        bytes: Data,
        occurrenceID: ReconstructionArtifactOccurrenceID
    ) throws -> ReconstructionArtifactOccurrenceRecord {
        try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: occurrenceID,
            contentIdentity: try ReconstructionContentIdentity(
                algorithm: .sha256,
                digest: ReconstructionDatabaseTestFixtures.sha256(bytes),
                byteCount: UInt64(bytes.count)
            ),
            kind: .source,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "target.c",
            diagnostic: nil
        )
    }

    private static func makeManifest(
        artifacts: [ReconstructionArtifactOccurrenceRecord]
    ) throws -> ReconstructionCorpusManifest {
        let normalized = try ReconstructionCorpusManifest(
            reconstructionProjectID: targetProjectID,
            artifacts: artifacts,
            relations: [],
            canonicalSHA256: ReconstructionDatabaseTestFixtures.digest("0")
        )
        let canonicalSHA256 = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            of: normalized
        )
        return try ReconstructionCorpusManifest(
            schemaVersion: normalized.schemaVersion,
            reconstructionProjectID: normalized.reconstructionProjectID,
            artifacts: normalized.artifacts,
            relations: normalized.relations,
            canonicalSHA256: canonicalSHA256
        )
    }
}
