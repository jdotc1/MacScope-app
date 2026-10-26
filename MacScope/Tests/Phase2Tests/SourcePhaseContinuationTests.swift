import Foundation
import XCTest
@testable import MacScope

final class SourcePhaseContinuationTests: XCTestCase {
    private typealias Planner = ReconstructionProductionRoundPlanBuilder

    func testCommittedOrdinaryRoundContinuesThroughPendingOracleExecution() throws {
        let base = try SourcePhaseTestFixture.baseline()
        let oracle = try Planner.makeSourceExecutionLeafTasks(jobID: SourcePhaseTestFixture.jobID,
            function: SourcePhaseTestFixture.function(), predecessorCheckpointID: SourcePhaseTestFixture.id(15),
            contract: ReconstructionSourceExecutionTaskContract.oracle, tasks: base, maximumTasks: 32)
        try assertForwardNormalization(tasks: base + oracle, receiptTaskID: SourcePhaseTestFixture.id(14))
    }

    func testOraclePublicationAndSourceReceiptEachPreserveForwardNormalization() throws {
        let base = try SourcePhaseTestFixture.baseline()
        let oracle = SourcePhaseTestFixture.completed(try Planner.makeSourceExecutionLeafTasks(
            jobID: SourcePhaseTestFixture.jobID, function: SourcePhaseTestFixture.function(),
            predecessorCheckpointID: SourcePhaseTestFixture.id(15), contract: ReconstructionSourceExecutionTaskContract.oracle,
            tasks: base, maximumTasks: 32))
        let source = try Planner.makeSourceRevisionLeafTasks(jobID: SourcePhaseTestFixture.jobID,
            function: SourcePhaseTestFixture.function(), predecessorCheckpointID: XCTUnwrap(oracle.last).identity.taskID,
            tasks: base + oracle, maximumTasks: 32)
        try assertForwardNormalization(tasks: base + oracle + source, receiptTaskID: XCTUnwrap(oracle.first).identity.taskID)
        let completedSource = SourcePhaseTestFixture.completed(source)
        let evaluation = try Planner.makeSourceExecutionLeafTasks(jobID: SourcePhaseTestFixture.jobID,
            function: SourcePhaseTestFixture.function(), predecessorCheckpointID: XCTUnwrap(source.last).identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.evaluate, tasks: base + oracle + completedSource, maximumTasks: 32)
        try assertForwardNormalization(tasks: base + oracle + completedSource + evaluation,
            receiptTaskID: XCTUnwrap(source.first).identity.taskID)
    }

    func testCompletedEvaluationContinuesIntoBoundedRepairWithoutReplayingSource() throws {
        var graph = try SourcePhaseTestFixture.baseline()
        let source = SourcePhaseTestFixture.completed(try Planner.makeSourceRevisionLeafTasks(
            jobID: SourcePhaseTestFixture.jobID, function: SourcePhaseTestFixture.function(),
            predecessorCheckpointID: SourcePhaseTestFixture.id(15), tasks: graph, maximumTasks: 32))
        graph += source
        let evaluation = SourcePhaseTestFixture.completed(try Planner.makeSourceExecutionLeafTasks(
            jobID: SourcePhaseTestFixture.jobID, function: SourcePhaseTestFixture.function(),
            predecessorCheckpointID: XCTUnwrap(source.last).identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.evaluate, tasks: graph, maximumTasks: 32))
        graph += evaluation
        let repair = try Planner.makeSourceRevisionLeafTasks(jobID: SourcePhaseTestFixture.jobID,
            function: SourcePhaseTestFixture.function(), predecessorCheckpointID: XCTUnwrap(evaluation.last).identity.taskID,
            tasks: graph, maximumTasks: 32)
        try assertForwardNormalization(tasks: graph + repair, receiptTaskID: XCTUnwrap(evaluation.first).identity.taskID)
    }

    func testCompletedTasksWithoutActualPredecessorReceiptCannotNormalize() throws {
        let base = try SourcePhaseTestFixture.baseline()
        let oracle = try Planner.makeSourceExecutionLeafTasks(jobID: SourcePhaseTestFixture.jobID,
            function: SourcePhaseTestFixture.function(), predecessorCheckpointID: SourcePhaseTestFixture.id(15),
            contract: ReconstructionSourceExecutionTaskContract.oracle, tasks: base, maximumTasks: 32)
        XCTAssertNil(try Planner.preExecutionPhase(from: SourcePhaseTestFixture.snapshot(tasks: base + oracle,
            state: .executingReads, receipts: [:])))
        XCTAssertThrowsError(try Planner.preExecutionPhase(from: SourcePhaseTestFixture.snapshot(tasks: base + oracle,
            state: .acceptingEvidence, receipts: [:])))
        XCTAssertThrowsError(try Planner.preExecutionPhase(from: SourcePhaseTestFixture.snapshot(tasks: base + oracle,
            state: .checkpointing, receipts: [SourcePhaseTestFixture.id(14): .failed])))
    }

    func testCompletedSourceJobDoesNotRequireAnotherPendingFrontier() throws {
        XCTAssertNil(try Planner.preExecutionPhase(from: SourcePhaseTestFixture.snapshot(
            tasks: SourcePhaseTestFixture.baseline(), state: .completed, receipts: [:])))
    }

    private func assertForwardNormalization(tasks: [ReconstructionTaskRecord], receiptTaskID: UUID) throws {
        try Planner.validateDynamicTaskGraph(tasks, jobID: SourcePhaseTestFixture.jobID, maximumTasks: 32)
        for (state, expected) in [(ReconstructionJobState.awaitingModel, ReconstructionJobState.executingReads),
                                 (.executingReads, .acceptingEvidence), (.acceptingEvidence, .checkpointing),
                                 (.checkpointing, .retrieving)] {
            XCTAssertEqual(try Planner.preExecutionPhase(from: SourcePhaseTestFixture.snapshot(
                tasks: tasks, state: state, receipts: [receiptTaskID: .completed])), expected)
        }
    }
}

struct SourcePhaseTestFixture {
    static let jobID = UUID(uuidString: "df000000-0000-0000-0000-000000000001")!
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "df000000-0000-0000-0000-%012d", n))! }
    static func function() throws -> ReconstructionFunctionCoordinate {
        let hash = String(repeating: "a", count: 64)
        return try .init(artifact: .init(occurrenceID: .init(rawValue: id(2)),
            contentIdentity: .init(algorithm: .sha256, digest: hash, byteCount: 32)),
            image: .init(binaryID: id(3), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: hash, startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
    }
    static func baseline() throws -> [ReconstructionTaskRecord] {
        let artifact = try function().artifact
        func task(_ n: Int, _ kind: ReconstructionTaskKind, _ dependencies: [UUID],
                  subject: ReconstructionSubjectCoordinate? = nil, contract: String? = nil) throws -> ReconstructionTaskRecord {
            .init(identity: try .make(taskID: id(n), jobID: jobID, kind: kind, subject: subject,
                dependencyTaskIDs: dependencies, operationContractIdentity: contract ?? "reconstruction.\(kind.rawValue).v1"),
                state: .completed, diagnostic: nil)
        }
        return try [task(10, .ingest, [], subject: .artifact(artifact)),
            task(11, .classify, [id(10)], subject: .artifact(artifact)),
            task(12, .discoverRelations, [id(11)], subject: .artifact(artifact)),
            task(13, .retrieveEvidence, [id(12)], contract: ReconstructionProductionTaskContract.evidenceQuery),
            task(14, .modelRound, [id(13)]), task(15, .checkpoint, [id(14)])]
    }
    static func completed(_ tasks: [ReconstructionTaskRecord]) -> [ReconstructionTaskRecord] {
        tasks.map { .init(identity: $0.identity, state: .completed, diagnostic: nil) }
    }
    static func snapshot(tasks: [ReconstructionTaskRecord], state: ReconstructionJobState,
                         receipts: [UUID: ReconstructionTaskState]) -> ReconstructionJobOrchestrationSnapshot {
        let hash = String(repeating: "a", count: 64)
        return .init(jobID: jobID, jobCreationOrder: 1, checkpointID: id(100), checkpointRevision: 5,
            checkpointCorpusManifestSHA256: hash, checkpointEvidenceFrontierSHA256: hash,
            currentCorpusManifestSHA256: hash, evidenceFrontierSHA256: hash, currentDurableJobState: state,
            pauseContext: nil, maximumRoundsWithoutEvidence: 8, tasks: tasks, terminalReceiptStatesByTaskID: receipts)
    }
}
