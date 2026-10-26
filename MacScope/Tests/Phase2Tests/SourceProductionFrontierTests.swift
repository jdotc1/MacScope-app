import Foundation
import XCTest
@testable import MacScope

final class SourceProductionFrontierTests: XCTestCase {
    private struct Fixture {
        let jobID: UUID
        let function: ReconstructionFunctionCoordinate
        let tasks: [ReconstructionTaskRecord]
        let predecessor: UUID
    }

    private func task(jobID: UUID, kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?, dependencies: [UUID],
        contract: String, state: ReconstructionTaskState = .completed) throws -> ReconstructionTaskRecord {
        .init(identity: try .make(taskID: UUID(), jobID: jobID, kind: kind, subject: subject,
            dependencyTaskIDs: dependencies, operationContractIdentity: contract), state: state, diagnostic: nil)
    }

    private func fixture(final: Bool = false) throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: UUID())
        let jobID = foundation.job.jobID
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity)
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil,
                architecture: .arm64, machOIdentity: nil), analysisFingerprintSHA256: String(repeating: "a", count: 64),
            startAddress: 0x1000, endAddressExclusive: 0x1010, boundarySchemaVersion: 1,
            functionUUIDHint: nil, symbolHint: nil)
        let ingest = try task(jobID: jobID, kind: .ingest, subject: .artifact(artifact), dependencies: [],
            contract: "reconstruction.ingest.v1")
        let classify = try task(jobID: jobID, kind: .classify, subject: .artifact(artifact),
            dependencies: [ingest.identity.taskID], contract: "reconstruction.classify.v1")
        let discover = try task(jobID: jobID, kind: .discoverRelations, subject: .artifact(artifact),
            dependencies: [classify.identity.taskID], contract: "reconstruction.discoverRelations.v1")
        let retrieve = try task(jobID: jobID, kind: .retrieveEvidence, subject: nil,
            dependencies: [discover.identity.taskID], contract: ReconstructionProductionTaskContract.evidenceQuery)
        let model = try task(jobID: jobID, kind: .modelRound, subject: nil,
            dependencies: [retrieve.identity.taskID], contract: ReconstructionProductionTaskContract.modelRound)
        let checkpoint = try task(jobID: jobID, kind: .checkpoint, subject: nil,
            dependencies: [model.identity.taskID], contract: ReconstructionProductionTaskContract.checkpoint)
        var tasks = [ingest, classify, discover, retrieve, model, checkpoint]
        var predecessor = checkpoint.identity.taskID
        if final {
            let synthesis = try task(jobID: jobID, kind: .modelRound, subject: nil,
                dependencies: [predecessor], contract: ReconstructionProductionTaskContract.finalSynthesis)
            let finalCheckpoint = try task(jobID: jobID, kind: .checkpoint, subject: nil,
                dependencies: [synthesis.identity.taskID], contract: ReconstructionProductionTaskContract.checkpoint)
            tasks += [synthesis, finalCheckpoint]
            predecessor = finalCheckpoint.identity.taskID
        }
        return .init(jobID: jobID, function: function, tasks: tasks, predecessor: predecessor)
    }

    private func appended(_ fixture: Fixture) throws -> [ReconstructionTaskRecord] {
        fixture.tasks + (try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: fixture.jobID, function: fixture.function, predecessorCheckpointID: fixture.predecessor,
            tasks: fixture.tasks, maximumTasks: 32))
    }

    func testExistingOrdinaryAndFinalGraphsRemainValidWithoutSource() throws {
        for final in [false, true] {
            let value = try fixture(final: final)
            try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(value.tasks,
                jobID: value.jobID, maximumTasks: 32)
            XCTAssertTrue(try ReconstructionProductionRoundPlanBuilder.sourceRevisionFrontiers(in: value.tasks).isEmpty)
        }
    }

    func testExplicitSourceFrontierFollowsCompletedRegularOrFinalCheckpoint() throws {
        for final in [false, true] {
            let value = try fixture(final: final), tasks = try appended(value)
            let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: tasks))
            XCTAssertEqual(frontier.model.identity.subject, .function(value.function))
            XCTAssertEqual(frontier.model.identity.dependencyTaskIDs, [value.predecessor])
            XCTAssertEqual(frontier.checkpoint.identity.dependencyTaskIDs, [frontier.model.identity.taskID])
            XCTAssertNil(try ReconstructionProductionRoundPlanBuilder.pendingRegularModelFrontier(in: tasks))
            XCTAssertNil(try ReconstructionProductionRoundPlanBuilder.authorizedSourceRevisionFrontier(in: tasks))
            try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(tasks, jobID: value.jobID, maximumTasks: 32)
        }
    }

    func testRunningClaimIsDistinctFromPendingAndCompletionAllowsOnlyOneRevision() throws {
        let value = try fixture(), pending = try appended(value)
        let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: pending))
        let claimed = pending.map { record in
            record.identity.taskID == frontier.model.identity.taskID
                ? ReconstructionTaskRecord(identity: record.identity, state: .running, diagnostic: nil) : record
        }
        XCTAssertNotNil(try ReconstructionProductionRoundPlanBuilder.authorizedSourceRevisionFrontier(in: claimed))
        XCTAssertNil(try ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: claimed))
        try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(claimed, jobID: value.jobID, maximumTasks: 32)
        let completed = pending.map { ReconstructionTaskRecord(identity: $0.identity, state: .completed, diagnostic: nil) }
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: frontier.checkpoint.identity.taskID,
            tasks: completed, maximumTasks: 32))
        let evaluated = (completed + (try ReconstructionProductionRoundPlanBuilder.makeSourceExecutionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: frontier.checkpoint.identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.evaluate, tasks: completed, maximumTasks: 32)))
            .map { ReconstructionTaskRecord(identity: $0.identity, state: .completed, diagnostic: nil) }
        let evaluation = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.sourceExecutionFrontiers(in: evaluated).first)
        let revised = evaluated + (try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: evaluation.checkpoint.identity.taskID,
            tasks: evaluated, maximumTasks: 32))
        XCTAssertEqual(try ReconstructionProductionRoundPlanBuilder.sourceRevisionFrontiers(in: revised).count, 2)
        let terminal = revised.map { ReconstructionTaskRecord(identity: $0.identity, state: .completed, diagnostic: nil) }
        let second = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.sourceRevisionFrontiers(in: revised)
            .first { $0.model.state == .pending })
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: second.checkpoint.identity.taskID,
            tasks: terminal, maximumTasks: 32))
    }

    func testSourceAdmissionRejectsIncompletePredecessorForkAndExhaustedTaskBudget() throws {
        let value = try fixture(), tasks = try appended(value)
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: value.predecessor,
            tasks: tasks, maximumTasks: 32))
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: value.predecessor,
            tasks: value.tasks, maximumTasks: value.tasks.count + 1))
        let unfinished = value.tasks.map { record in
            record.identity.taskID == value.predecessor
                ? ReconstructionTaskRecord(identity: record.identity, state: .pending, diagnostic: nil) : record
        }
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.makeSourceRevisionLeafTasks(
            jobID: value.jobID, function: value.function, predecessorCheckpointID: value.predecessor,
            tasks: unfinished, maximumTasks: 32))
    }

    func testSourceContractRejectsUnscopedFunctionlessOrdinaryFallbackAndOrphanCheckpoint() throws {
        let value = try fixture(), tasks = try appended(value)
        let source = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: tasks))
        let invalidContracts: [(ReconstructionSubjectCoordinate?, String)] = [
            (nil, ReconstructionProductionTaskContract.sourceRevision),
            (.function(value.function), ReconstructionProductionTaskContract.modelRound),
        ]
        for (subject, contract) in invalidContracts {
            let changed = try tasks.map { record -> ReconstructionTaskRecord in
                guard record.identity.taskID == source.model.identity.taskID else { return record }
                return try .init(identity: .make(taskID: record.identity.taskID, jobID: value.jobID,
                    kind: .modelRound, subject: subject, dependencyTaskIDs: record.identity.dependencyTaskIDs,
                    operationContractIdentity: contract), state: .pending, diagnostic: nil)
            }
            XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
                changed, jobID: value.jobID, maximumTasks: 32))
        }
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            tasks.filter { $0.identity.taskID != source.checkpoint.identity.taskID }, jobID: value.jobID, maximumTasks: 32))
    }

    func testTerminalOwnerControlKeepsCancelledAndFailedSourceGraphsValid() throws {
        let value = try fixture(), pending = try appended(value)
        let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: pending))
        for terminal in [ReconstructionTaskState.cancelled, .failed] {
            let terminated = pending.map { record in
                [frontier.model.identity.taskID, frontier.checkpoint.identity.taskID].contains(record.identity.taskID)
                    ? ReconstructionTaskRecord(identity: record.identity, state: terminal, diagnostic: nil) : record
            }
            try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
                terminated, jobID: value.jobID, maximumTasks: 32)
            XCTAssertNil(try ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: terminated))
            XCTAssertNil(try ReconstructionProductionRoundPlanBuilder.authorizedSourceRevisionFrontier(in: terminated))
        }
    }

    func testCheckpointCannotCompleteBeforeSourceModel() throws {
        let value = try fixture(), pending = try appended(value)
        let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: pending))
        let forged = pending.map { record in
            record.identity.taskID == frontier.checkpoint.identity.taskID
                ? ReconstructionTaskRecord(identity: record.identity, state: .completed, diagnostic: nil) : record
        }
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            forged, jobID: value.jobID, maximumTasks: 32))
    }

    func testOrdinaryOrFinalSuccessorCannotEscapeSourcePhase() throws {
        let value = try fixture(), pending = try appended(value)
        let frontier = try XCTUnwrap(ReconstructionProductionRoundPlanBuilder.pendingSourceRevisionFrontier(in: pending))
        let completed = pending.map { ReconstructionTaskRecord(identity: $0.identity, state: .completed, diagnostic: nil) }
        let model = try task(jobID: value.jobID, kind: .modelRound, subject: nil,
            dependencies: [frontier.checkpoint.identity.taskID], contract: ReconstructionProductionTaskContract.finalSynthesis,
            state: .pending)
        let checkpoint = try task(jobID: value.jobID, kind: .checkpoint, subject: nil,
            dependencies: [model.identity.taskID], contract: ReconstructionProductionTaskContract.checkpoint, state: .pending)
        XCTAssertThrowsError(try ReconstructionProductionRoundPlanBuilder.validateDynamicTaskGraph(
            completed + [model, checkpoint], jobID: value.jobID, maximumTasks: 32))
    }
}
