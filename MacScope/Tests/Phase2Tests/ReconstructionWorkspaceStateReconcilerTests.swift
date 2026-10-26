import CryptoKit
import XCTest

@testable import MacScope

final class ReconstructionWorkspaceStateReconcilerTests: XCTestCase {
    func testSeedsPackageOnlyWhenDurableAuthorityIsExplicitlyAbsent() throws {
        let fixture = try foundation()
        let package = try cut(state: fixture.state)

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: package,
            durable: .absent(binding: package.binding)
        )

        guard case .seedPackage(let resolution) = decision else {
            return XCTFail("Expected package seed, got \(decision)")
        }
        XCTAssertEqual(resolution.state, fixture.state)
        XCTAssertEqual(resolution.requiredContentAvailability.count, 1)
        XCTAssertTrue(resolution.requiredContentAvailability[0].isAvailableFromPackage)
        XCTAssertFalse(resolution.requiredContentAvailability[0].isAvailableFromDurable)
    }

    func testEqualCanonicalStatesRemainEqual() throws {
        let fixture = try foundation()
        let package = try cut(state: fixture.state)
        let durable = try cut(state: fixture.state)

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: package,
            durable: .present(cut: durable, corpusBasis: .untrusted)
        )

        guard case .equal(let resolution) = decision else {
            return XCTFail("Expected equal state, got \(decision)")
        }
        XCTAssertEqual(resolution.state, fixture.state)
        XCTAssertTrue(resolution.requiredContentAvailability.allSatisfy {
            $0.isAvailableFromPackage && $0.isAvailableFromDurable
        })
    }

    func testUsesDurableCheckpointDescendantWithExactParentIdentityAndSHA() throws {
        let fixture = try foundation()
        let durableState = try checkpointDescendant(
            of: fixture,
            checkpointID: Self.checkpointOneID
        )

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: try cut(state: fixture.state),
            durable: .present(
                cut: try cut(state: durableState),
                corpusBasis: .trustedSamePathAppOwned
            )
        )

        guard case .useDurableDescendant(let resolution) = decision else {
            return XCTFail("Expected durable descendant, got \(decision)")
        }
        XCTAssertEqual(resolution.state, durableState)
        XCTAssertEqual(resolution.state.checkpoints.map(\.revision), [0, 1])
    }

    func testUsesTrustedDurableCorpusDescendantAndUnionsValueOnlyAvailability() throws {
        let fixture = try foundation()
        let successor = try corpusDescendant(of: fixture)
        let baseIdentity = try XCTUnwrap(
            ReconstructionPackageCodec.contentRecords(in: fixture.state).first?.contentIdentity
        )
        let successorIdentities = try ReconstructionPackageCodec.contentRecords(in: successor)
            .map(\.contentIdentity)
        let newIdentity = try XCTUnwrap(successorIdentities.first { $0 != baseIdentity })
        let package = try cut(state: fixture.state, unavailable: [])
        let durable = try cut(state: successor, unavailable: [baseIdentity])

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: package,
            durable: .present(cut: durable, corpusBasis: .trustedSamePathAppOwned)
        )

        guard case .useDurableDescendant(let resolution) = decision else {
            return XCTFail("Expected trusted corpus descendant, got \(decision)")
        }
        XCTAssertEqual(resolution.state, successor)
        let availability = Dictionary(uniqueKeysWithValues:
            resolution.requiredContentAvailability.map { ($0.contentIdentity, $0) }
        )
        XCTAssertEqual(availability[baseIdentity]?.isAvailableFromPackage, true)
        XCTAssertEqual(availability[baseIdentity]?.isAvailableFromDurable, false)
        XCTAssertEqual(availability[newIdentity]?.isAvailableFromPackage, false)
        XCTAssertEqual(availability[newIdentity]?.isAvailableFromDurable, true)
    }

    func testFastForwardsDurableWhenPackageIsCheckpointDescendant() throws {
        let fixture = try foundation()
        let packageState = try checkpointDescendant(
            of: fixture,
            checkpointID: Self.checkpointOneID
        )

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: try cut(state: packageState),
            durable: .present(
                cut: try cut(state: fixture.state),
                corpusBasis: .trustedSamePathAppOwned
            )
        )

        guard case .fastForwardDurableFromPackage(let resolution) = decision else {
            return XCTFail("Expected durable fast-forward, got \(decision)")
        }
        XCTAssertEqual(resolution.state, packageState)
    }

    func testRefusesSiblingCheckpointForkDivergence() throws {
        let fixture = try foundation()
        let package = try checkpointDescendant(
            of: fixture,
            checkpointID: Self.checkpointOneID
        )
        let durable = try checkpointDescendant(
            of: fixture,
            checkpointID: Self.checkpointTwoID
        )

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: try cut(state: package),
            durable: .present(
                cut: try cut(state: durable),
                corpusBasis: .trustedSamePathAppOwned
            )
        )

        XCTAssertEqual(
            decision,
            .conflict(.checkpointAncestryDiverged(fixture.job.jobID))
        )
    }

    func testRefusesImmutableJobIdentityDrift() throws {
        let fixture = try foundation()
        let descendant = try checkpointDescendant(
            of: fixture,
            checkpointID: Self.checkpointOneID
        )
        let drifted = try stateWithDriftedJob(descendant)

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: try cut(state: fixture.state),
            durable: .present(
                cut: try cut(state: drifted),
                corpusBasis: .trustedSamePathAppOwned
            )
        )

        XCTAssertEqual(
            decision,
            .conflict(.immutableRecordDrift(
                .job,
                fixture.job.jobID.uuidString.lowercased()
            ))
        )
    }

    func testRefusesCheckpointDescendantWithIllegalJobStateRegression() throws {
        let fixture = try foundation()
        let regressed = try stateWithIllegalJobStateRegression(fixture)

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: try cut(state: fixture.state),
            durable: .present(
                cut: try cut(state: regressed),
                corpusBasis: .trustedSamePathAppOwned
            )
        )

        XCTAssertEqual(
            decision,
            .conflict(.jobStateRegression(fixture.job.jobID))
        )
    }

    func testRefusesSameDocumentIdentifiersAtDifferentCanonicalPaths() throws {
        let fixture = try foundation()
        let package = try cut(state: fixture.state, path: "/tmp/One.mscope")
        let durable = try cut(state: fixture.state, path: "/tmp/Two.mscope")

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: package,
            durable: .present(cut: durable, corpusBasis: .trustedSamePathAppOwned)
        )

        XCTAssertEqual(decision, .conflict(.canonicalPackagePathMismatch))
    }

    func testRefusesWhenRequiredSourceIsUnavailableOnEverySide() throws {
        let fixture = try foundation()
        let identity = try XCTUnwrap(
            ReconstructionPackageCodec.contentRecords(in: fixture.state).first?.contentIdentity
        )
        let package = try cut(state: fixture.state, unavailable: [identity])

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: package,
            durable: .absent(binding: package.binding)
        )

        XCTAssertEqual(decision, .conflict(.missingRequiredSource(identity)))
    }

    func testRefusesCorpusAdvanceWithoutTrustedSamePathDurableBasis() throws {
        let fixture = try foundation()
        let successor = try corpusDescendant(of: fixture)

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: try cut(state: fixture.state),
            durable: .present(
                cut: try cut(state: successor),
                corpusBasis: .untrusted
            )
        )

        XCTAssertEqual(
            decision,
            .conflict(.untrustedCorpusAncestry(fixture.project.projectID))
        )
    }

    private static let workspaceBinaryID = UUID(
        uuidString: "39000000-0000-0000-0000-000000000001"
    )!
    private static let workspaceID = UUID(
        uuidString: "39000000-0000-0000-0000-000000000002"
    )!
    private static let documentID = UUID(
        uuidString: "39000000-0000-0000-0000-000000000003"
    )!
    private static let checkpointOneID = UUID(
        uuidString: "39000000-0000-0000-0000-000000000004"
    )!
    private static let checkpointTwoID = UUID(
        uuidString: "39000000-0000-0000-0000-000000000005"
    )!
    private static let successorOccurrenceID = UUID(
        uuidString: "39000000-0000-0000-0000-000000000006"
    )!

    private func foundation() throws -> ReconstructionDatabaseTestFixtures.StateFixture {
        try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: Self.workspaceBinaryID
        )
    }

    private func cut(
        state: ReconstructionWorkspaceState,
        path: String = "/tmp/Reconciliation.mscope",
        unavailable: Set<ReconstructionContentIdentity> = []
    ) throws -> ReconstructionWorkspaceStateCut {
        let availability = try ReconstructionPackageCodec.contentRecords(in: state).map {
            ReconstructionWorkspaceContentAvailability(
                contentIdentity: $0.contentIdentity,
                isAvailable: !unavailable.contains($0.contentIdentity)
            )
        }
        return ReconstructionWorkspaceStateCut(
            binding: ReconstructionWorkspaceStateBinding(
                workspaceID: Self.workspaceID,
                documentID: Self.documentID,
                canonicalPackagePath: path
            ),
            state: state,
            contentAvailability: availability
        )
    }

    private func checkpointDescendant(
        of fixture: ReconstructionDatabaseTestFixtures.StateFixture,
        checkpointID: UUID
    ) throws -> ReconstructionWorkspaceState {
        let completedTask = ReconstructionTaskRecord(
            identity: fixture.task.identity,
            state: .completed,
            diagnostic: nil
        )
        let successorCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: checkpointID,
            jobID: fixture.job.jobID,
            revision: fixture.checkpoint.revision + 1,
            parentCheckpointID: fixture.checkpoint.checkpointID,
            parentCheckpointSHA256: fixture.checkpoint.canonicalSHA256,
            corpusManifestSHA256: fixture.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: fixture.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [fixture.task.identity.taskID],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: fixture.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .completed,
            terminalReason: nil
        )
        let successorJob = try ReconstructionJobRecord(
            jobID: fixture.job.jobID,
            reconstructionProjectID: fixture.job.reconstructionProjectID,
            objective: fixture.job.objective,
            objectiveSHA256: fixture.job.objectiveSHA256,
            creationCorpusManifestSHA256: fixture.job.creationCorpusManifestSHA256,
            state: .completed,
            currentCheckpointID: successorCheckpoint.checkpointID,
            terminalReason: nil,
            budget: fixture.job.budget,
            creationOrdinal: try XCTUnwrap(fixture.job.creationOrdinal)
        )
        return try ReconstructionWorkspaceState(
            projects: fixture.state.projects,
            corpusManifests: fixture.state.corpusManifests,
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: [successorJob],
            tasks: [completedTask],
            checkpoints: [fixture.checkpoint, successorCheckpoint],
            toolReceipts: fixture.state.toolReceipts,
            modelReceipts: fixture.state.modelReceipts
        )
    }

    private func corpusDescendant(
        of fixture: ReconstructionDatabaseTestFixtures.StateFixture
    ) throws -> ReconstructionWorkspaceState {
        let bytes = Data("durable-only-source".utf8)
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: Self.sha256(bytes),
            byteCount: UInt64(bytes.count)
        )
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(
                rawValue: Self.successorOccurrenceID
            ),
            contentIdentity: identity,
            kind: .source,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "durable-only.swift",
            diagnostic: nil
        )
        let artifacts = fixture.manifest.artifacts + [occurrence]
        let draft = try ReconstructionCorpusManifest(
            reconstructionProjectID: fixture.project.projectID,
            artifacts: artifacts,
            relations: fixture.manifest.relations,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: fixture.project.projectID,
            artifacts: artifacts,
            relations: fixture.manifest.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
        )
        let project = try ReconstructionProjectRecord(
            projectID: fixture.project.projectID,
            name: fixture.project.name,
            currentCorpusManifestSHA256: manifest.canonicalSHA256
        )
        return try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [fixture.manifest, manifest],
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: fixture.state.jobs,
            tasks: fixture.state.tasks,
            checkpoints: fixture.state.checkpoints,
            toolReceipts: fixture.state.toolReceipts,
            modelReceipts: fixture.state.modelReceipts
        )
    }

    private func stateWithIllegalJobStateRegression(
        _ fixture: ReconstructionDatabaseTestFixtures.StateFixture
    ) throws -> ReconstructionWorkspaceState {
        let successorCheckpoint = try ReconstructionCheckpoint.make(
            checkpointID: Self.checkpointOneID,
            jobID: fixture.job.jobID,
            revision: fixture.checkpoint.revision + 1,
            parentCheckpointID: fixture.checkpoint.checkpointID,
            parentCheckpointSHA256: fixture.checkpoint.canonicalSHA256,
            corpusManifestSHA256: fixture.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: fixture.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [fixture.task.identity.taskID],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: fixture.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .indexing,
            terminalReason: nil
        )
        let regressedJob = try ReconstructionJobRecord(
            jobID: fixture.job.jobID,
            reconstructionProjectID: fixture.job.reconstructionProjectID,
            objective: fixture.job.objective,
            objectiveSHA256: fixture.job.objectiveSHA256,
            creationCorpusManifestSHA256: fixture.job.creationCorpusManifestSHA256,
            state: .indexing,
            currentCheckpointID: successorCheckpoint.checkpointID,
            terminalReason: nil,
            budget: fixture.job.budget,
            creationOrdinal: try XCTUnwrap(fixture.job.creationOrdinal)
        )
        return try ReconstructionWorkspaceState(
            projects: fixture.state.projects,
            corpusManifests: fixture.state.corpusManifests,
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: [regressedJob],
            tasks: fixture.state.tasks,
            checkpoints: [fixture.checkpoint, successorCheckpoint],
            toolReceipts: fixture.state.toolReceipts,
            modelReceipts: fixture.state.modelReceipts
        )
    }

    private func stateWithDriftedJob(
        _ state: ReconstructionWorkspaceState
    ) throws -> ReconstructionWorkspaceState {
        let original = try XCTUnwrap(state.jobs.first)
        let objective = "A different objective under the same durable job ID"
        let job = try ReconstructionJobRecord(
            jobID: original.jobID,
            reconstructionProjectID: original.reconstructionProjectID,
            objective: objective,
            objectiveSHA256: Self.sha256(Data(objective.utf8)),
            creationCorpusManifestSHA256: original.creationCorpusManifestSHA256,
            state: original.state,
            currentCheckpointID: original.currentCheckpointID,
            terminalReason: original.terminalReason,
            budget: original.budget,
            creationOrdinal: try XCTUnwrap(original.creationOrdinal),
            pauseContext: original.pauseContext
        )
        return try ReconstructionWorkspaceState(
            projects: state.projects,
            corpusManifests: state.corpusManifests,
            evidence: state.evidence,
            evidenceRelations: state.evidenceRelations,
            evidenceGaps: state.evidenceGaps,
            jobs: [job],
            tasks: state.tasks,
            checkpoints: state.checkpoints,
            toolReceipts: state.toolReceipts,
            modelReceipts: state.modelReceipts
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
