import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceExecutionFrontierTests: XCTestCase {
    private typealias Planner = ReconstructionProductionRoundPlanBuilder
    private let jobID = UUID(uuidString: "cf000000-0000-0000-0000-000000000001")!
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "cf000000-0000-0000-0000-%012d", n))! }
    private func function() throws -> ReconstructionFunctionCoordinate {
        let hash = String(repeating: "a", count: 64)
        return try .init(artifact: .init(occurrenceID: .init(rawValue: id(2)),
            contentIdentity: .init(algorithm: .sha256, digest: hash, byteCount: 32)),
            image: .init(binaryID: id(3), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: hash, startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
    }
    private func task(_ n: Int, kind: ReconstructionTaskKind, subject: ReconstructionSubjectCoordinate? = nil,
                      dependencies: [UUID], state: ReconstructionTaskState = .completed,
                      contract: String? = nil) throws -> ReconstructionTaskRecord {
        .init(identity: try .make(taskID: id(n), jobID: jobID, kind: kind, subject: subject,
            dependencyTaskIDs: dependencies, operationContractIdentity: contract ?? "reconstruction.\(kind.rawValue).v1"),
            state: state, diagnostic: nil)
    }
    private func baseline() throws -> [ReconstructionTaskRecord] {
        let artifact = try function().artifact
        return try [task(10, kind: .ingest, subject: .artifact(artifact), dependencies: []),
            task(11, kind: .classify, subject: .artifact(artifact), dependencies: [id(10)]),
            task(12, kind: .discoverRelations, subject: .artifact(artifact), dependencies: [id(11)]),
            task(13, kind: .retrieveEvidence, dependencies: [id(12)], contract: ReconstructionProductionTaskContract.evidenceQuery),
            task(14, kind: .modelRound, dependencies: [id(13)]),
            task(15, kind: .checkpoint, dependencies: [id(14)])]
    }
    private func completed(_ tasks: [ReconstructionTaskRecord]) -> [ReconstructionTaskRecord] {
        tasks.map { .init(identity: $0.identity, state: .completed, diagnostic: nil) }
    }
    private func validate(_ tasks: [ReconstructionTaskRecord]) throws {
        try Planner.validateDynamicTaskGraph(tasks, jobID: jobID, maximumTasks: 32)
    }
    private func appendExecution(to tasks: [ReconstructionTaskRecord], predecessor: UUID,
                                 contract: String) throws -> [ReconstructionTaskRecord] {
        try Planner.makeSourceExecutionLeafTasks(jobID: jobID, function: function(),
            predecessorCheckpointID: predecessor, contract: contract, tasks: tasks, maximumTasks: 32)
    }
    private func appendSource(to tasks: [ReconstructionTaskRecord], predecessor: UUID) throws -> [ReconstructionTaskRecord] {
        try Planner.makeSourceRevisionLeafTasks(jobID: jobID, function: function(),
            predecessorCheckpointID: predecessor, tasks: tasks, maximumTasks: 32)
    }
    private func sourceGraph() throws -> [ReconstructionTaskRecord] {
        let base = try baseline()
        let oracle = completed(try appendExecution(to: base, predecessor: id(15), contract: ReconstructionSourceExecutionTaskContract.oracle))
        let withOracle = base + oracle
        let source = completed(try appendSource(to: withOracle, predecessor: XCTUnwrap(oracle.last).identity.taskID))
        return withOracle + source
    }

    func testExecutionFactoryCreatesExactlyOnePendingTaskAndPairedCheckpoint() throws {
        let base = try sourceGraph()
        let predecessor = try XCTUnwrap(base.last).identity.taskID
        let created = try appendExecution(to: base, predecessor: predecessor, contract: ReconstructionSourceExecutionTaskContract.evaluate)
        XCTAssertEqual(created.count, 2)
        let execution = try XCTUnwrap(created.first)
        let checkpoint = try XCTUnwrap(created.last)
        XCTAssertEqual(execution.identity.kind, .executeSource)
        XCTAssertEqual(execution.identity.subject, .function(try function()))
        XCTAssertEqual(execution.identity.dependencyTaskIDs, [predecessor])
        XCTAssertEqual(execution.identity.operationContractIdentity, ReconstructionSourceExecutionTaskContract.evaluate)
        XCTAssertEqual(checkpoint.identity.kind, .checkpoint)
        XCTAssertEqual(checkpoint.identity.dependencyTaskIDs, [execution.identity.taskID])
        XCTAssertNil(checkpoint.identity.subject)
        XCTAssertTrue(created.allSatisfy { $0.state == .pending })
        try validate(base + created)
        XCTAssertThrowsError(try Planner.makeSourceExecutionLeafTasks(jobID: jobID, function: function(),
            predecessorCheckpointID: predecessor, contract: ReconstructionSourceExecutionTaskContract.evaluate,
            tasks: base, maximumTasks: base.count + 1))
    }

    func testCompleteOracleSourceEvaluationRepairEvaluationChainIsAllowedAndThirdSourceRejected() throws {
        var graph = try sourceGraph()
        let firstEvaluation = completed(try appendExecution(to: graph, predecessor: XCTUnwrap(graph.last).identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.evaluate))
        graph += firstEvaluation
        let repair = completed(try appendSource(to: graph, predecessor: XCTUnwrap(firstEvaluation.last).identity.taskID))
        graph += repair
        let secondEvaluation = completed(try appendExecution(to: graph, predecessor: XCTUnwrap(repair.last).identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.evaluate))
        graph += secondEvaluation
        try validate(graph)
        XCTAssertEqual(try Planner.sourceRevisionFrontiers(in: graph).count, 2)
        XCTAssertEqual(try Planner.sourceExecutionFrontiers(in: graph).count, 3)
        XCTAssertThrowsError(try appendSource(to: graph, predecessor: XCTUnwrap(secondEvaluation.last).identity.taskID))
    }

    func testSourceCannotSkipEvaluationOrRepeatOracle() throws {
        let graph = try sourceGraph()
        let predecessor = try XCTUnwrap(graph.last).identity.taskID
        XCTAssertThrowsError(try appendSource(to: graph, predecessor: predecessor))
        XCTAssertThrowsError(try appendExecution(to: graph, predecessor: predecessor, contract: ReconstructionSourceExecutionTaskContract.oracle))
        let directRepair = try [task(50, kind: .modelRound, subject: .function(function()), dependencies: [predecessor], state: .pending,
            contract: ReconstructionProductionTaskContract.sourceRevision),
            task(51, kind: .checkpoint, dependencies: [id(50)], state: .pending)]
        XCTAssertThrowsError(try validate(graph + directRepair))
    }

    func testEvaluationBeforeSourceAndRepeatedOracleAreRejectedByFactoryAndGraph() throws {
        let base = try baseline()
        XCTAssertThrowsError(try appendExecution(to: base, predecessor: id(15), contract: ReconstructionSourceExecutionTaskContract.evaluate))
        let premature = try [task(50, kind: .executeSource, subject: .function(function()), dependencies: [id(15)], state: .pending,
            contract: ReconstructionSourceExecutionTaskContract.evaluate),
            task(51, kind: .checkpoint, dependencies: [id(50)], state: .pending)]
        XCTAssertThrowsError(try validate(base + premature))
        let oracle = completed(try appendExecution(to: base, predecessor: id(15), contract: ReconstructionSourceExecutionTaskContract.oracle))
        let graph = base + oracle
        let predecessor = try XCTUnwrap(oracle.last).identity.taskID
        XCTAssertThrowsError(try appendExecution(to: graph, predecessor: predecessor, contract: ReconstructionSourceExecutionTaskContract.oracle))
        let repeated = try [task(52, kind: .executeSource, subject: .function(function()), dependencies: [predecessor], state: .pending,
            contract: ReconstructionSourceExecutionTaskContract.oracle),
            task(53, kind: .checkpoint, dependencies: [id(52)], state: .pending)]
        XCTAssertThrowsError(try validate(graph + repeated))
    }

    func testExecutionCannotEscapeBackToOrdinaryModelRound() throws {
        let base = try baseline()
        let oracle = completed(try appendExecution(to: base, predecessor: id(15), contract: ReconstructionSourceExecutionTaskContract.oracle))
        let predecessor = try XCTUnwrap(oracle.last).identity.taskID
        let ordinary = try [task(50, kind: .retrieveEvidence, dependencies: [predecessor], state: .pending,
            contract: ReconstructionProductionTaskContract.evidenceQuery),
            task(51, kind: .modelRound, dependencies: [id(50)], state: .pending),
            task(52, kind: .checkpoint, dependencies: [id(51)], state: .pending)]
        XCTAssertThrowsError(try validate(base + oracle + ordinary))
    }

    func testFailedAndCancelledExecutionRequireBlockedPairedCheckpoint() throws {
        let base = try sourceGraph()
        let created = try appendExecution(to: base, predecessor: XCTUnwrap(base.last).identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.evaluate)
        for state in [ReconstructionTaskState.failed, .cancelled] {
            let execution = ReconstructionTaskRecord(identity: created[0].identity, state: state, diagnostic: nil)
            let blocked = ReconstructionTaskRecord(identity: created[1].identity, state: .blocked, diagnostic: nil)
            try validate(base + [execution, blocked])
            XCTAssertThrowsError(try validate(base + [execution, created[1]]))
        }
    }
}
