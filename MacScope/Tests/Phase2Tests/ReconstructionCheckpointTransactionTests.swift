import Foundation
import XCTest
@testable import MacScope

final class ReconstructionCheckpointTransactionTests: XCTestCase {
    func testCheckpointMutationCommitsWholeFrontierAtomically() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let mutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)

        let committed = try fixture.database.commitReconstructionCheckpoint(
            workspaceID: fixture.workspaceUUID,
            mutation: mutation
        )

        XCTAssertEqual(committed.checkpoint, mutation.successorCheckpoint)
        XCTAssertEqual(committed.idempotentToolReceiptIDs, [])
        XCTAssertEqual(committed.idempotentModelReceiptIDs, [])
        let state = try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID)
        XCTAssertEqual(state.evidence.map(\.evidenceID), [
            ReconstructionDatabaseTestFixtures.evidenceOneUUID,
            ReconstructionDatabaseTestFixtures.evidenceTwoUUID,
        ])
        XCTAssertEqual(state.evidenceRelations, mutation.evidenceRelations)
        XCTAssertEqual(state.toolReceipts, mutation.toolReceipts)
        XCTAssertEqual(state.modelReceipts, mutation.modelReceipts)
        XCTAssertEqual(state.tasks.first?.state, .completed)
        XCTAssertEqual(state.jobs.first?.currentCheckpointID, mutation.successorCheckpoint.checkpointID)
        XCTAssertEqual(state.checkpoints.last, mutation.successorCheckpoint)
    }

    func testFailureAtEachMutationBoundaryLeavesPriorCheckpointAuthoritative() throws {
        enum FailureCase: CaseIterable {
            case evidenceCitation
            case evidenceRelation
            case toolReceipt
            case taskTransition
            case successorCheckpoint
        }

        for failureCase in FailureCase.allCases {
            let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: fixture.binaryID
            )
            try fixture.database.replaceReconstructionState(
                workspaceID: fixture.workspaceUUID,
                state: foundation.state
            )
            let mutation = try ReconstructionDatabaseTestFixtures.makeMutation(
                from: foundation,
                unknownCitationSource: failureCase == .evidenceCitation,
                unknownRelationTarget: failureCase == .evidenceRelation,
                unknownToolTask: failureCase == .toolReceipt,
                transitionExpectedState: failureCase == .taskTransition ? .running : .pending,
                wrongParentDigest: failureCase == .successorCheckpoint
            )

            XCTAssertThrowsError(
                try fixture.database.commitReconstructionCheckpoint(
                    workspaceID: fixture.workspaceUUID,
                    mutation: mutation
                ),
                "Expected \(failureCase) mutation to fail"
            )

            XCTAssertEqual(
                try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
                foundation.state,
                "\(failureCase) left partial reconstruction rows"
            )
        }
    }

    func testInjectedFailureAfterEverySQLMutationPhaseRollsBackExactProjection() throws {
        for phase in WorkspaceDatabase.ReconstructionMutationPhase.allCases {
            let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: fixture.binaryID
            )
            try fixture.database.replaceReconstructionState(
                workspaceID: fixture.workspaceUUID,
                state: foundation.state
            )
            let beforeProjection = try fixture.database.reconstructionProjectionSnapshotForTesting(
                workspaceID: fixture.workspaceUUID
            )
            let mutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
            fixture.database.setReconstructionMutationFailureForTesting(after: phase)

            XCTAssertThrowsError(
                try fixture.database.commitReconstructionCheckpoint(
                    workspaceID: fixture.workspaceUUID,
                    mutation: mutation
                ),
                "Expected injected failure after \(phase.rawValue)"
            ) { error in
                XCTAssertEqual(
                    error as? WorkspaceDatabase.DatabaseError,
                    .reconstructionInjectedFailure(phase.rawValue)
                )
            }

            XCTAssertEqual(
                try fixture.database.reconstructionProjectionSnapshotForTesting(
                    workspaceID: fixture.workspaceUUID
                ),
                beforeProjection,
                "\(phase.rawValue) changed the persisted projection"
            )
            XCTAssertEqual(
                try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
                foundation.state,
                "\(phase.rawValue) changed the authoritative checkpoint"
            )
        }
    }

    func testExactCompletedReceiptReplayIsIdempotentButMismatchedIdentityFailsClosed() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let firstMutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        _ = try fixture.database.commitReconstructionCheckpoint(
            workspaceID: fixture.workspaceUUID,
            mutation: firstMutation
        )
        let committedState = try fixture.database.loadReconstructionState(
            workspaceID: fixture.workspaceUUID
        )
        let exactReceipt = try XCTUnwrap(committedState.toolReceipts.first)
        let replay = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: committedState,
            receipt: exactReceipt
        )

        let replayed = try fixture.database.commitReconstructionCheckpoint(
            workspaceID: fixture.workspaceUUID,
            mutation: replay
        )

        XCTAssertEqual(replayed.idempotentToolReceiptIDs, [exactReceipt.receiptID])
        XCTAssertEqual(
            try fixture.database.scalarIntForTesting(
                "SELECT COUNT(*) FROM reconstruction_tool_receipts;"
            ),
            1
        )

        let afterReplay = try fixture.database.loadReconstructionState(
            workspaceID: fixture.workspaceUUID
        )
        let mismatchedReceipt = try ReconstructionToolReceipt(
            receiptID: exactReceipt.receiptID,
            jobID: exactReceipt.jobID,
            taskID: exactReceipt.taskID,
            checkpointRevision: exactReceipt.checkpointRevision,
            requestIdentitySHA256: exactReceipt.requestIdentitySHA256,
            producer: exactReceipt.producer,
            terminalState: exactReceipt.terminalState,
            outputEvidenceIDs: exactReceipt.outputEvidenceIDs,
            diagnostic: exactReceipt.diagnostic,
            canonicalSHA256: ReconstructionDatabaseTestFixtures.digest("4")
        )
        let mismatchedReplay = try ReconstructionDatabaseTestFixtures.makeReplayMutation(
            from: afterReplay,
            receipt: mismatchedReceipt
        )

        XCTAssertThrowsError(
            try fixture.database.commitReconstructionCheckpoint(
                workspaceID: fixture.workspaceUUID,
                mutation: mismatchedReplay
            )
        ) { error in
            guard case WorkspaceDatabase.DatabaseError.reconstructionIdentityConflict = error else {
                return XCTFail("Expected reconstructionIdentityConflict, got \(error)")
            }
        }
        XCTAssertEqual(
            try fixture.database.loadReconstructionState(workspaceID: fixture.workspaceUUID),
            afterReplay
        )
    }

    func testDatabaseAuthoritativeCheckpointReplayExportsAndReopensAsVersion3() throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let firstMutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        _ = try fixture.database.commitReconstructionCheckpoint(
            workspaceID: fixture.workspaceUUID,
            mutation: firstMutation
        )
        let committed = try fixture.database.loadReconstructionState(
            workspaceID: fixture.workspaceUUID
        )
        let receipt = try XCTUnwrap(committed.toolReceipts.first)
        _ = try fixture.database.commitReconstructionCheckpoint(
            workspaceID: fixture.workspaceUUID,
            mutation: try ReconstructionDatabaseTestFixtures.makeReplayMutation(
                from: committed,
                receipt: receipt
            )
        )
        let replayed = try fixture.database.loadReconstructionState(
            workspaceID: fixture.workspaceUUID
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReconstructionCheckpointReplay-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceURL = root.appendingPathComponent("test")
        try Data("test".utf8).write(to: sourceURL)
        let packageURL = root.appendingPathComponent("Replay.mscope", isDirectory: true)
        let manifest = WorkspacePackageManifest(
            documentID: UUID(),
            workspaceUUID: fixture.workspaceUUID,
            workspaceName: "Replay",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )

        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [:],
            reconstructionState: replayed,
            reconstructionAttachmentSources: [
                ReconstructionAttachmentSource(
                    contentIdentity: foundation.occurrence.contentIdentity,
                    verifiedURL: sourceURL
                ),
            ],
            to: packageURL
        )
        let reopened = try MacScopeDocumentPackage.openPackage(from: packageURL)

        XCTAssertEqual(reopened.manifest.formatVersion, 4)
        XCTAssertEqual(reopened.manifest.analysisFormatVersion, 3)
        XCTAssertEqual(reopened.reconstructionState, replayed)
        XCTAssertEqual(reopened.reconstructionAttachmentSources.map(\.contentIdentity), [
            foundation.occurrence.contentIdentity,
        ])
    }

    func testDatabaseOwnerSerializesSameParentCommitsSoOnlyOneAdvances() async throws {
        let fixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: fixture.binaryID
        )
        try fixture.database.replaceReconstructionState(
            workspaceID: fixture.workspaceUUID,
            state: foundation.state
        )
        let mutation = try ReconstructionDatabaseTestFixtures.makeMutation(from: foundation)
        let owner = ReconstructionDatabaseOwner(database: fixture.database)

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await owner.commit(mutation)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(outcomes.filter { !$0 }.count, 1)
        let state = try await owner.load(workspaceID: fixture.workspaceUUID)
        XCTAssertEqual(state.checkpoints.count, 2)
        XCTAssertEqual(state.jobs.first?.currentCheckpointID, mutation.successorCheckpoint.checkpointID)
    }
}
