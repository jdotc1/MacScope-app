import Foundation
import XCTest
@testable import MacScope

final class ReconstructionModelReceiptGraphValidationTests: XCTestCase {
    private let retrieveTaskID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000001"
    )!
    private let modelTaskID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000002"
    )!
    private let checkpointTaskID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000003"
    )!
    private let checkpointID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000004"
    )!
    private let successorCheckpointID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000014"
    )!
    private let firstModelReceiptID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000005"
    )!
    private let secondModelReceiptID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000006"
    )!
    private let matchingToolReceiptID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000007"
    )!
    private let foreignToolReceiptID = UUID(
        uuidString: "77000000-0000-0000-0000-000000000008"
    )!

    func testCompletedOrdinaryModelWithZeroHandlesHasOneReceiptAndNeedsNoToolReceipt() throws {
        let state = try makeState(modelReceiptCount: 1)

        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
    }

    func testFailedModelDoesNotRequireATerminalReceipt() throws {
        let state = try makeState(modelState: .failed, modelReceiptCount: 0)

        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
    }

    func testCancelledModelDoesNotRequireATerminalReceipt() throws {
        let state = try makeState(modelState: .cancelled, modelReceiptCount: 0)

        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
    }

    func testBlockedModelDoesNotRequireATerminalReceipt() throws {
        let state = try makeState(modelState: .blocked, modelReceiptCount: 0)

        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
    }

    func testCompletedOrdinaryModelRejectsMissingReceipt() throws {
        let state = try makeState(modelReceiptCount: 0)

        try assertRejected(state, reason: "completed model task receipt binding")
    }

    func testModelTaskRejectsDuplicateReceipts() throws {
        let state = try makeState(modelReceiptCount: 2)

        try assertRejected(state, reason: "duplicate model receipt task binding")
    }

    func testSelectedHandleRejectsForeignToolReceipt() throws {
        let state = try makeState(
            selectedHandleIDs: [foreignToolReceiptID],
            toolReceiptIDs: [foreignToolReceiptID],
            toolReceiptTaskID: checkpointTaskID
        )

        try assertRejected(state, reason: "model selected handle receipt binding")
    }

    func testSelectedHandleAcceptsExactPairedRetrieveReceipt() throws {
        let state = try makeState(
            selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID]
        )

        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
    }

    func testSelectedRefreshAcknowledgmentAcceptsClosedSuccessorGraphAndPackageRoundTrip() throws {
        let state = try makeState(selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID],
            toolProducerOperation: ReconstructionOperationID.analysisMacScopeRefresh.rawValue,
            includeRefreshSuccessor: true)
        XCTAssertNoThrow(try ReconstructionPackageCodec.validateGraph(state))
        let encoded = try ReconstructionPackageCodec.encode(state)
        let decoded = try ReconstructionPackageCodec.decode(descriptor: encoded.descriptor,
            corpusData: encoded.corpusData, evidenceData: encoded.evidenceData,
            checkpointData: encoded.checkpointData)
        XCTAssertEqual(decoded.toolReceipts, state.toolReceipts)
    }

    func testSelectedRefreshAcknowledgmentRejectsMissingSuccessorGraph() throws {
        let state = try makeState(selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID],
            toolProducerOperation: ReconstructionOperationID.analysisMacScopeRefresh.rawValue)
        try assertRejected(state, reason: "model selected handle receipt binding")
    }

    func testSelectedRefreshAcknowledgmentRejectsFailedReceiptAndMismatchedEnumeration() throws {
        for wrongEnumeration in [false, true] {
            let state = try makeState(selectedHandleIDs: [matchingToolReceiptID],
                toolReceiptIDs: [matchingToolReceiptID],
                toolProducerOperation: ReconstructionOperationID.analysisMacScopeRefresh.rawValue,
                includeRefreshSuccessor: true, wrongRefreshEnumeration: wrongEnumeration,
                toolTerminalState: wrongEnumeration ? .completed : .failed)
            try assertRejected(state, reason: "model selected handle receipt binding")
        }
    }

    func testSelectedRefreshAcknowledgmentRejectsForeignTaskAndSemanticOutput() throws {
        let foreign = try makeState(selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID], toolReceiptTaskID: checkpointTaskID,
            toolProducerOperation: ReconstructionOperationID.analysisMacScopeRefresh.rawValue,
            includeRefreshSuccessor: true)
        try assertRejected(foreign, reason: "model selected handle receipt binding")
        let semantic = try makeState(selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID],
            toolProducerOperation: ReconstructionOperationID.analysisMacScopeRefresh.rawValue,
            includeRefreshSuccessor: true, toolOutputEvidenceIDs: [UUID()])
        // Isolate the binding seam: an unknown semantic output is independently rejected by
        // the package's evidence provenance check before this model-binding check.
        XCTAssertThrowsError(try validateModelBindings(semantic)) { error in
            XCTAssertEqual(error as? ReconstructionPackageValidationError,
                .stateGraphInvalid("model selected handle receipt binding"))
        }
    }

    func testSelectedRefreshBindingUsesHistoricalCheckpointAfterAnalysisCompletes() throws {
        let state = try makeState(selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID],
            toolProducerOperation: ReconstructionOperationID.analysisMacScopeRefresh.rawValue,
            includeRefreshSuccessor: true)
        let tasks = state.tasks.map { task in
            task.identity.kind == .decompileMacScope
                ? ReconstructionTaskRecord(identity: task.identity, state: .completed, diagnostic: nil) : task
        }
        XCTAssertNoThrow(try validateModelBindings(state, tasks: tasks))
    }

    private func validateModelBindings(_ state: ReconstructionWorkspaceState,
        tasks: [ReconstructionTaskRecord]? = nil) throws {
        let checkpoints = Dictionary(grouping: state.checkpoints, by: \.jobID).mapValues {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.revision, $0) })
        }
        try ReconstructionPackageCodec.validateModelTaskReceiptBindings(
            tasks: Dictionary(uniqueKeysWithValues: (tasks ?? state.tasks).map { ($0.identity.taskID, $0) }),
            checkpointsByJobID: checkpoints,
            toolReceipts: Dictionary(uniqueKeysWithValues: state.toolReceipts.map { ($0.receiptID, $0) }),
            modelReceipts: state.modelReceipts)
    }

    func testCompletedModelRejectsCanonicalReceiptWithWrongOperationIdentity() throws {
        let state = try makeState(
            modelProducerOperation: ReconstructionOperationID.checkpointStatus.rawValue
        )

        try assertRejected(state, reason: "completed model task receipt binding")
    }

    func testSelectedHandleRejectsCanonicalToolReceiptWithWrongOperationIdentity() throws {
        let state = try makeState(
            selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID],
            toolProducerOperation: ReconstructionOperationID.checkpointStatus.rawValue
        )

        try assertRejected(state, reason: "model selected handle receipt binding")
    }

    func testCompletedModelRejectsIncompletePairedRetrieveTask() throws {
        let state = try makeState(retrieveState: .pending)

        try assertRejected(state, reason: "ordinary model receipt commitment")
    }

    func testModelReceiptRejectsIntroductionAfterTaskFirstCompletedCheckpoint() throws {
        let state = try makeState(
            receiptRevision: 1,
            modelFirstCompletedRevision: 0
        )

        try assertRejected(state, reason: "model receipt task completion revision")
    }

    func testSelectedToolReceiptRejectsIntroductionAfterRetrieveFirstCompletedCheckpoint() throws {
        let state = try makeState(
            selectedHandleIDs: [matchingToolReceiptID],
            toolReceiptIDs: [matchingToolReceiptID],
            receiptRevision: 1,
            modelFirstCompletedRevision: 1,
            retrieveFirstCompletedRevision: 0
        )

        try assertRejected(state, reason: "tool receipt task completion revision")
    }

    func testOrdinaryModelRejectsFinalResultCommitment() throws {
        let state = try makeState(
            finalResultCommitment: try ReconstructionFinalResultCommitment(
                resultID: UUID(
                    uuidString: "77000000-0000-0000-0000-000000000009"
                )!,
                canonicalSHA256: digest("9")
            )
        )

        try assertRejected(state, reason: "ordinary model receipt commitment")
    }

    func testFinalModelRejectsReceiptWithoutFinalResultCommitment() throws {
        let state = try makeState(
            modelContract: "reconstruction.finalSynthesis.v1",
            finalResultCommitment: nil
        )

        try assertRejected(state, reason: "final model receipt commitment")
    }

    // Mutation RED recipes:
    // 1. Remove the completed-model receipt lookup guard: missing receipt turns GREEN.
    // 2. Replace receiptsByTaskID.updateValue with assignment: duplicate receipt turns GREEN.
    // 3. Resolve selected handles against any same-job receipt: foreign handle turns GREEN.
    // 4. Delete either producer-operation equality: its canonical wrong-operation test turns GREEN.
    // 5. Remove the paired retrieve completion check: incomplete-retrieve turns GREEN.
    // 6. Delete the ordinary/final commitment branches: both mismatch tests turn GREEN.
    // 7. Require a receipt for every model state: failed/cancelled/blocked positives turn RED.
    // 8. Delete either first-completed-revision equality: its late-introduction test turns GREEN.

    private func makeState(
        modelState: ReconstructionTaskState = .completed,
        modelContract: String = "reconstruction.modelRound.v1",
        modelReceiptCount: Int = 1,
        retrieveState: ReconstructionTaskState = .completed,
        selectedHandleIDs: [UUID] = [],
        toolReceiptIDs: [UUID] = [],
        toolReceiptTaskID: UUID? = nil,
        toolProducerOperation: String = ReconstructionOperationID.evidenceQuery.rawValue,
        modelProducerOperation: String? = nil,
        finalResultCommitment: ReconstructionFinalResultCommitment? = nil,
        receiptRevision: UInt64 = 0,
        modelFirstCompletedRevision: UInt64 = 0,
        retrieveFirstCompletedRevision: UInt64 = 0,
        includeRefreshSuccessor: Bool = false,
        wrongRefreshEnumeration: Bool = false,
        toolTerminalState: ReconstructionReceiptTerminalState = .completed,
        toolOutputEvidenceIDs: [UUID] = []
    ) throws -> ReconstructionWorkspaceState {
        precondition((0...2).contains(modelReceiptCount))
        precondition(receiptRevision <= 1)
        precondition(modelFirstCompletedRevision <= receiptRevision)
        precondition(retrieveFirstCompletedRevision <= receiptRevision)
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID(
                uuidString: "77000000-0000-0000-0000-000000000010"
            )!
        )
        let jobID = foundation.job.jobID
        let failure = ReconstructionDiagnostic.sanitizing("model receipt fixture failure")
        let retrieve = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: retrieveTaskID,
                jobID: jobID,
                kind: .retrieveEvidence,
                subject: nil,
                dependencyTaskIDs: [],
                operationContractIdentity: ReconstructionOperationID.evidenceQuery.rawValue
            ),
            state: retrieveState,
            diagnostic: retrieveState == .completed ? nil : failure
        )
        let model = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: modelTaskID,
                jobID: jobID,
                kind: .modelRound,
                subject: nil,
                dependencyTaskIDs: [retrieveTaskID],
                operationContractIdentity: modelContract
            ),
            state: modelState,
            diagnostic: (modelState == .failed || modelState == .cancelled) ? failure : nil
        )
        let checkpointTaskState: ReconstructionTaskState = modelState == .completed
            ? .completed
            : .blocked
        let checkpointTask = ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: checkpointTaskID,
                jobID: jobID,
                kind: .checkpoint,
                subject: nil,
                dependencyTaskIDs: [modelTaskID],
                operationContractIdentity: "reconstruction.checkpoint.v1"
            ),
            state: checkpointTaskState,
            diagnostic: checkpointTaskState == .blocked ? failure : nil
        )

        let toolReceipts = try toolReceiptIDs.map { receiptID in
            try ReconstructionReceiptAuthority.makeToolReceipt(
                receiptID: receiptID,
                jobID: jobID,
                taskID: toolReceiptTaskID ?? retrieveTaskID,
                checkpointRevision: receiptRevision,
                requestIdentitySHA256: digest("1"),
                producer: try ReconstructionDatabaseTestFixtures.makeProducer(
                    operationID: toolProducerOperation
                ),
                terminalState: toolTerminalState,
                outputEvidenceIDs: toolOutputEvidenceIDs,
                diagnostic: nil
            )
        }
        let receiptIDs = [firstModelReceiptID, secondModelReceiptID]
            .prefix(modelReceiptCount)
        let modelReceipts = try receiptIDs.map { receiptID in
            try ReconstructionReceiptAuthority.makeModelReceipt(
                receiptID: receiptID,
                jobID: jobID,
                taskID: modelTaskID,
                checkpointRevision: receiptRevision,
                requestIdentitySHA256: digest("2"),
                producer: try ReconstructionDatabaseTestFixtures.makeProducer(
                    operationID: modelProducerOperation ?? modelContract
                ),
                terminalState: .completed,
                selectedHandleIDs: selectedHandleIDs.map {
                    $0.uuidString.lowercased()
                },
                acceptedEvidenceIDs: [],
                diagnostic: nil,
                finalResultCommitment: finalResultCommitment
            )
        }
        let evidenceFrontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: foundation.manifest.canonicalSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: [],
            checkpointRevisionsByID: [:]
        )
        let terminal = modelState == .failed || modelState == .cancelled
        let jobState: ReconstructionJobState = switch modelState {
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        default:
            .retrieving
        }
        var tasks = [retrieve, model, checkpointTask]
        var refreshHistoricalStates: [(UUID, ReconstructionTaskState)] = []
        if includeRefreshSuccessor {
            let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
                contentIdentity: foundation.occurrence.contentIdentity)
            let image = ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
                selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
            let coordinate = try ReconstructionImageCoordinate(artifact: artifact, image: image,
                analysisFingerprintSHA256: digest(wrongRefreshEnumeration ? "e" : "d"))
            let function = try ReconstructionFunctionCoordinate(artifact: artifact, image: image,
                analysisFingerprintSHA256: digest("d"), startAddress: 0x1000, endAddressExclusive: 0x1010,
                boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
            func extra(_ kind: ReconstructionTaskKind, _ subject: ReconstructionSubjectCoordinate?,
                       _ dependencies: [UUID], _ contract: String,
                       _ state: ReconstructionTaskState = .pending) throws -> ReconstructionTaskRecord {
                ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(taskID: UUID(),
                    jobID: jobID, kind: kind, subject: subject, dependencyTaskIDs: dependencies,
                    operationContractIdentity: contract), state: state, diagnostic: nil)
            }
            let enumeration = try extra(.enumerateFunctions, .image(coordinate), [],
                "reconstruction.enumerateFunctions.v1", .completed)
            let refresh = try extra(.decompileMacScope, .function(function),
                [enumeration.identity.taskID, checkpointTaskID], "reconstruction.decompileMacScope.v1")
            let nextRetrieve = try extra(.retrieveEvidence, nil, [checkpointTaskID, refresh.identity.taskID],
                "reconstruction.evidence.query")
            let nextModel = try extra(.modelRound, nil, [nextRetrieve.identity.taskID], "reconstruction.modelRound.v1")
            let nextCheckpoint = try extra(.checkpoint, nil, [nextModel.identity.taskID], "reconstruction.checkpoint.v1")
            let extras = [enumeration, refresh, nextRetrieve, nextModel, nextCheckpoint]
            tasks += extras
            refreshHistoricalStates = extras.map { ($0.identity.taskID, $0.state) }
        }
        var checkpoints: [ReconstructionCheckpoint] = []
        for revision in 0...receiptRevision {
            let historicalRetrieveState: ReconstructionTaskState =
                retrieve.state == .completed && revision < retrieveFirstCompletedRevision
                ? .pending
                : retrieve.state
            let historicalModelState: ReconstructionTaskState =
                model.state == .completed && revision < modelFirstCompletedRevision
                ? .pending
                : model.state
            let historicalCheckpointState: ReconstructionTaskState =
                checkpointTask.state == .completed && revision < modelFirstCompletedRevision
                ? .pending
                : checkpointTask.state
            let historicalStates: [(UUID, ReconstructionTaskState)] = [
                (retrieveTaskID, historicalRetrieveState),
                (modelTaskID, historicalModelState),
                (checkpointTaskID, historicalCheckpointState),
            ] + refreshHistoricalStates
            let parent = checkpoints.last
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: revision == 0 ? checkpointID : successorCheckpointID,
                jobID: jobID,
                revision: revision,
                parentCheckpointID: parent?.checkpointID,
                parentCheckpointSHA256: parent?.canonicalSHA256,
                corpusManifestSHA256: foundation.manifest.canonicalSHA256,
                evidenceFrontierSHA256: evidenceFrontier,
                pendingTaskIDs: historicalStates.compactMap {
                    $0.1 == .pending ? $0.0 : nil
                },
                runningTaskIDs: historicalStates.compactMap {
                    $0.1 == .running ? $0.0 : nil
                },
                completedTaskIDs: historicalStates.compactMap {
                    $0.1 == .completed ? $0.0 : nil
                },
                failedTaskIDs: historicalStates.compactMap {
                    $0.1 == .failed || $0.1 == .cancelled ? $0.0 : nil
                },
                blockedTaskIDs: historicalStates.compactMap {
                    $0.1 == .blocked ? $0.0 : nil
                },
                unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                    .canonicalSHA256(for: []),
                modelReceiptIDs: revision >= receiptRevision
                    ? modelReceipts.map(\.receiptID)
                    : [],
                toolReceiptIDs: revision >= receiptRevision
                    ? toolReceipts.map(\.receiptID)
                    : [],
                coordinatorState: jobState,
                terminalReason: terminal ? failure : nil
            )
            checkpoints.append(checkpoint)
        }
        let checkpoint = try XCTUnwrap(checkpoints.last)
        let job = try ReconstructionJobRecord(
            jobID: jobID,
            reconstructionProjectID: foundation.project.projectID,
            objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.manifest.canonicalSHA256,
            state: jobState,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: terminal ? failure : nil,
            budget: foundation.job.budget,
            creationOrdinal: 1
        )
        return try ReconstructionWorkspaceState(
            projects: [foundation.project],
            corpusManifests: [foundation.manifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [job],
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts
        )
    }

    private func assertRejected(
        _ state: ReconstructionWorkspaceState,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try ReconstructionPackageCodec.validateGraph(state),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionPackageValidationError,
                .stateGraphInvalid(reason),
                file: file,
                line: line
            )
        }
    }

    private func digest(_ scalar: Character) -> String {
        String(repeating: String(scalar), count: 64)
    }
}
