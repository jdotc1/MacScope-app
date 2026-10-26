import Foundation
import XCTest
@testable import MacScope

/// Exercises the actual enumeration commit planner, including its model reserve and gaps.
final class ReconstructionProductionFocusedPlannerTests: XCTestCase {
    private enum FocusMode { case selected, sibling, stale, missing }

    func testSelectedLateFunctionReceivesAnalysisBeforeGeneralCoverageAtBudget() async throws {
        let fixture = try makeEnumerationFixture(maximumTasks: 16)
        let preparedPlan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let plan = try XCTUnwrap(preparedPlan)
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(mutation.newTasks.map(\.identity.kind), [
            .decompileNative, .decompileMacScope, .compareDecompilers,
            .decompileNative, .decompileMacScope, .compareDecompilers
        ])
        XCTAssertEqual(functionStarts(mutation.newTasks), [
            0x3000, 0x3000, 0x3000, 0x1000, 0x1000, 0x1000
        ])
        XCTAssertLessThanOrEqual(fixture.basis.tasks.count + mutation.newTasks.count, 16)
        XCTAssertTrue(mutation.taskTransitions.contains {
            $0.diagnostic?.text.contains("truncated by the task budget") == true
        })
    }

    func testUnfocusedAndSiblingImageKeepGeneralOrder() async throws {
        for mode in [FocusMode?.none, .some(.sibling)] {
            let fixture = try makeEnumerationFixture(maximumTasks: 16, focusMode: mode)
            let plan = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
            XCTAssertEqual(functionStarts(try XCTUnwrap(plan?.mutation).newTasks), [
                0x1000, 0x1000, 0x1000, 0x2000, 0x2000, 0x2000
            ])
        }
    }

    func testStaleAndMissingFocusedFunctionRejectEnumeration() async throws {
        for mode in [FocusMode.stale, .missing] {
            let fixture = try makeEnumerationFixture(maximumTasks: 16, focusMode: mode)
            do {
                _ = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
                XCTFail("Accepted stale or missing focused function: \(mode)")
            } catch {
                XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .invalidCommitPlan)
            }
        }
    }

    func testCorruptOmittedFunctionRejectsWholeCatalogBeforeBudget() async throws {
        let fixture = try makeEnumerationFixture(maximumTasks: 16, corruptOmittedID: true)
        do {
            _ = try await fixture.builder.makePreInferenceCommitPlan(cut: fixture.cut)
            XCTFail("Accepted an invalid function outside selected-first coverage")
        } catch {
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .invalidCommitPlan)
        }
    }

    private func functionStarts(_ tasks: [ReconstructionTaskRecord]) -> [UInt64] {
        tasks.compactMap {
            guard case .function(let coordinate)? = $0.identity.subject else { return nil }
            return coordinate.startAddress
        }
    }

    private struct Fixture {
        let basis: ReconstructionProductionRoundBasis
        let cut: ReconstructionProductionCommittedRoundCut
        let builder: ReconstructionProductionRoundPlanBuilder
        let registry: ReconstructionProductionRoundBasisRegistry
        let terminalTaskID: UUID
    }

    private func makeEnumerationFixture(
        maximumTasks: Int,
        committedFingerprint: String? = nil,
        resultFingerprint: String? = nil,
        focusMode: FocusMode? = .selected,
        corruptOmittedID: Bool = false
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
        let functions = [UInt64(0x1000), 0x2000, 0x3000].map { address in
            FunctionSummary(
                id: corruptOmittedID && address == 0x2000 ? UUID()
                    : ReconstructionStableImageAuthority.stableFunctionID(
                        image: imageBinding,
                        analysisFingerprintSHA256: resolvedResultFingerprint,
                        startAddress: address, endAddressExclusive: address + 0x10,
                        boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion),
                name: "function", startAddress: address, endAddress: address + 0x10,
                confidence: 1.0)
        }
        let focus: ReconstructionSubjectCoordinate?
        if let focusMode {
            let focusImage = focusMode == .sibling
                ? ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
                    selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
                : imageBinding
            let start: UInt64 = focusMode == .missing ? 0x4000 : 0x3000
            focus = .function(try ReconstructionFunctionCoordinate(
                artifact: artifact, image: focusImage,
                analysisFingerprintSHA256: focusMode == .stale ? digest("b") : resolvedResultFingerprint,
                startAddress: start, endAddressExclusive: start + 0x10,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
                functionUUIDHint: nil, symbolHint: nil))
        } else { focus = nil }
        let projection = try ReconstructionTransientAnalysisProjection(
            taskID: enumerate.identity.taskID,
            taskKind: .enumerateFunctions,
            artifact: artifact,
            image: imageBinding,
            analysisFingerprintSHA256: resolvedResultFingerprint,
            functionCatalog: functions,
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
            currentImages: committedImages,
            focus: focus
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
            receiptAuthor: FocusPassThroughReceiptPlanAuthor()
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

}

private struct FocusPassThroughReceiptPlanAuthor:
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

