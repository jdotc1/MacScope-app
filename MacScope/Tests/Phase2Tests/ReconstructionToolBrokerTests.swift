import CryptoKit
import Foundation
import XCTest

@testable import MacScope

final class ReconstructionToolBrokerTests: XCTestCase {
    func testRefreshDemandRejectsReadShapedRequestAndMissingFunction() throws {
        let fixture = try makeFixture()
        let read = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: taskID(for: .corpusSummary).uuidString)]
        ).first)
        XCTAssertThrowsError(try ReconstructionMacScopeAnalysisDemand.acknowledgement(
            for: ReconstructionToolRegistry().decodeCanonicalRequest(read)))
        XCTAssertThrowsError(try ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [.init(operationID: .analysisMacScopeRefresh,
                taskID: taskID(for: .evidenceQuery), subject: nil, retrievalQuery: nil,
                offset: 0, maximumRecords: 1, maximumEncodedBytes: 16_384)]))
    }

    func testFocusedEvidencePacketMembershipIsCheckedBeforeReceiptSuccess() async throws {
        struct Packet: Encodable {
            let schemaVersion = 1
            let domain = "reconstruction.evidence-retrieval-packet.v1"
            let corpusManifestSHA256: String
            let evidenceFrontierSHA256: String
            let queryIdentitySHA256: String
            let records: [ReconstructionRetrievedEvidenceRecord]
            let hasMore = false
        }
        let fixture = try makeFixture()
        let focus = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256,
                digest: String(repeating: "a", count: 64), byteCount: 4))
        let foreign = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: focus.contentIdentity)
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
            subject: nil, operationIDs: [.corpusSummary], classifications: [.acceptedCurrent],
            cursor: nil, maximumRecords: 8, maximumEncodedBytes: 16_384,
            focus: .artifact(focus))
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [.init(operationID: .evidenceQuery, taskID: taskID(for: .evidenceQuery),
                subject: nil, retrievalQuery: query, offset: 0, maximumRecords: 8,
                maximumEncodedBytes: 16_384)]).first)
        let producer = try XCTUnwrap(fixture.input.producersByOperation[.corpusSummary])
        for (artifact, expectedOutcome) in [(focus, ReconstructionToolProjectionOutcome.success),
                                            (foreign, ReconstructionToolProjectionOutcome.failed)] {
            let payload = Data("{}".utf8)
            let record = try ReconstructionEvidenceRecord(evidenceID: UUID(),
                subject: .artifact(artifact), operationID: MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue,
                payloadKind: .structuredJSON, payload: payload, payloadByteCount: UInt64(payload.count),
                payloadSHA256: sha256(payload), facetDependencies: [], producer: producer,
                citations: [], creatingJobID: fixture.authority.jobID,
                creatingTaskID: taskID(for: .corpusSummary), creatingCheckpointID: UUID(),
                modelReceiptID: nil, toolReceiptID: UUID(), classification: .acceptedCurrent,
                supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
            let packet = Packet(corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
                evidenceFrontierSHA256: fixture.authority.evidenceFrontierSHA256,
                queryIdentitySHA256: try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(query),
                records: [.init(record: record, classification: .acceptedCurrent, checkpointRevision: 7)])
            let projector = CountingProjector(family: .evidence, operations: [.evidenceQuery],
                result: .success(payload: try ReconstructionCanonicalJSON.encode(packet), count: 1))
            let executions = try await ReconstructionToolBroker(projectors: [projector])
                .execute(selectedHandleIDs: [handle.handleID], offeredHandles: [handle],
                    input: fixture.input)
            let execution = try XCTUnwrap(executions.first)
            XCTAssertEqual(execution.result.outcome, expectedOutcome)
        }
    }

    func testProjectionFrontierChangesForEveryGatingInputClass() throws {
        let fixture = try makeFixture()
        let baseline = fixture.authority.projectionFrontierSHA256
        let task = try XCTUnwrap(fixture.input.tasks.first)
        let changedTask = MacScopeAnalysisCore.ReconstructionTaskRecord(
            identity: task.identity,
            state: .completed,
            diagnostic: nil
        )
        let provisionalChangedProducer = try makeProducer(
            operation: .corpusSummary,
            buildIdentity: "changed-build",
            canonicalSHA256: String(repeating: "a", count: 64)
        )
        let changedProducer = try makeProducer(
            operation: .corpusSummary,
            buildIdentity: "changed-build",
            canonicalSHA256: MacScopeAnalysisCore.ReconstructionEvidenceIntegrity
                .canonicalProducerSHA256(provisionalChangedProducer)
        )
        let changedTasks = fixture.input.tasks.map {
            $0.identity.taskID == task.identity.taskID ? changedTask : $0
        }
        var changedProducers = fixture.input.producersByOperation
        changedProducers[.corpusSummary] = changedProducer
        let taskDigest = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: fixture.input.projectedItemsByOperation,
                staleOperations: fixture.input.staleOperations,
                tasks: changedTasks, receipts: fixture.input.receipts,
                producersByOperation: fixture.input.producersByOperation,
                evidenceAuthorityCutsByOperation: fixture.input.evidenceAuthorityCutsByOperation
            )
        let producerDigest = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: fixture.input.projectedItemsByOperation,
                staleOperations: fixture.input.staleOperations,
                tasks: fixture.input.tasks, receipts: fixture.input.receipts,
                producersByOperation: changedProducers,
                evidenceAuthorityCutsByOperation: fixture.input.evidenceAuthorityCutsByOperation
            )
        XCTAssertNotEqual(taskDigest, baseline)
        XCTAssertNotEqual(producerDigest, baseline)
    }

    func testRegistryHandleIdentityChangesWithProjectionFrontier() throws {
        let fixture = try makeFixture()
        let request = request(
            .corpusSummary,
            task: taskID(for: .corpusSummary).uuidString
        )
        let changedAuthority = try MacScopeAnalysisCore.ReconstructionToolAuthorityCut(
            jobID: fixture.authority.jobID,
            checkpointRevision: fixture.authority.checkpointRevision,
            roundID: fixture.authority.roundID,
            corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: fixture.authority.evidenceFrontierSHA256,
            projectionFrontierSHA256: String(repeating: "f", count: 64)
        )

        let original = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request]
        ).first)
        let changed = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: changedAuthority,
            requests: [request]
        ).first)

        XCTAssertNotEqual(original.canonicalRequest, changed.canonicalRequest)
        XCTAssertNotEqual(original.handleID, changed.handleID)
    }

    func testRegistryRequiresEvidenceQueryOnlyForEvidenceQueryOperation() throws {
        let fixture = try makeFixture()
        let query = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
            subject: nil,
            operationIDs: [.corpusSummary],
            classifications: [.acceptedCurrent],
            cursor: nil,
            maximumRecords: 8,
            maximumEncodedBytes: 16_384
        )
        let registry = MacScopeAnalysisCore.ReconstructionToolRegistry()

        XCTAssertThrowsError(try registry.mintHandles(
            authority: fixture.authority,
            requests: [.init(
                operationID: .evidenceQuery,
                taskID: taskID(for: .evidenceQuery),
                subject: nil,
                retrievalQuery: nil,
                offset: 0,
                maximumRecords: 8,
                maximumEncodedBytes: 16_384
            )]
        ))
        XCTAssertThrowsError(try registry.mintHandles(
            authority: fixture.authority,
            requests: [.init(
                operationID: .corpusSummary,
                taskID: taskID(for: .corpusSummary),
                subject: nil,
                retrievalQuery: query,
                offset: 0,
                maximumRecords: 8,
                maximumEncodedBytes: 16_384
            )]
        ))
    }

    func testRegistryBindsEvidenceQuerySubjectCursorFrontierAndOffset() throws {
        let fixture = try makeFixture()
        let subject = try testArtifactSubject(99)
        let cursor = MacScopeAnalysisCore.ReconstructionRetrievalCursor(
            schemaVersion: 1,
            corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: fixture.authority.evidenceFrontierSHA256,
            queryIdentitySHA256: String(repeating: "a", count: 64),
            currentBucket: 0,
            subjectSpecificity: 0,
            operationPriority: 0,
            canonicalSubjectIdentity: Data(repeating: 0, count: 32),
            checkpointRevision: 7,
            evidenceID: UUID()
        )
        let query = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
            subject: subject,
            operationIDs: [.corpusSummary],
            classifications: [.acceptedCurrent],
            cursor: cursor,
            maximumRecords: 8,
            maximumEncodedBytes: 16_384
        )
        let registry = MacScopeAnalysisCore.ReconstructionToolRegistry()

        for (requestSubject, offset) in [(nil, 1), (subject, 0)] {
            XCTAssertThrowsError(try registry.mintHandles(
                authority: fixture.authority,
                requests: [.init(
                    operationID: .evidenceQuery,
                    taskID: taskID(for: .evidenceQuery),
                    subject: requestSubject,
                    retrievalQuery: query,
                    offset: offset,
                    maximumRecords: 8,
                    maximumEncodedBytes: 16_384
                )]
            ))
        }
    }

    func testRegistryQueryIdentityMatchesRetrievalCompilerCursor() async throws {
        let fixture = try makeEvidenceBrokerFixture()
        let second = try replacingEvidenceID(fixture.candidate, evidenceID: UUID())
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusArtifactDescribe],
            result: .success(
                payload: Data("[]".utf8),
                count: 0,
                evidenceCandidates: [fixture.candidate, second]
            )
        )
        let accepted = try await MacScope.ReconstructionToolBroker(
            projectors: [projector]
        ).execute(
            selectedHandleIDs: [fixture.handle.handleID],
            offeredHandles: [fixture.handle],
            input: fixture.input
        ).flatMap(\.acceptedEvidence)
        let checkpointID = try XCTUnwrap(accepted.first?.creatingCheckpointID)
        let classifications = Dictionary(uniqueKeysWithValues: accepted.map {
            ($0.evidenceID, MacScopeAnalysisCore.ReconstructionEvidenceClassification.acceptedCurrent)
        })
        let frontier = try MacScope.ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: fixture.input.corpusManifest.canonicalSHA256,
            records: accepted,
            projectedClassificationsByEvidenceID: classifications,
            relations: [], gaps: [], checkpointRevisionsByID: [checkpointID: 7]
        )
        let cut = try MacScope.ReconstructionEvidenceCut(
            corpusManifestSHA256: fixture.input.corpusManifest.canonicalSHA256,
            records: accepted, relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: [checkpointID: 7]
        )
        let query = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: fixture.input.corpusManifest.canonicalSHA256,
            subject: fixture.candidate.subject,
            operationIDs: [.corpusArtifactDescribe],
            classifications: [.acceptedCurrent], cursor: nil,
            maximumRecords: 1, maximumEncodedBytes: 16_384
        )
        let packet = try MacScope.ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        XCTAssertEqual(
            try XCTUnwrap(packet.nextCursor).queryIdentitySHA256,
            try MacScopeAnalysisCore.ReconstructionToolRegistry
                .canonicalRetrievalQueryIdentitySHA256(query)
        )

        let baseCursor = try XCTUnwrap(packet.nextCursor)
        let mismatchedBase = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: cut.corpusManifestSHA256,
            subject: fixture.candidate.subject,
            operationIDs: [.functionsPage],
            classifications: [.acceptedCurrent], cursor: nil,
            maximumRecords: 1, maximumEncodedBytes: 16_384
        )
        let mismatchedCursor = MacScopeAnalysisCore.ReconstructionRetrievalCursor(
            schemaVersion: baseCursor.schemaVersion,
            corpusManifestSHA256: baseCursor.corpusManifestSHA256,
            evidenceFrontierSHA256: baseCursor.evidenceFrontierSHA256,
            queryIdentitySHA256: try MacScopeAnalysisCore.ReconstructionToolRegistry
                .canonicalRetrievalQueryIdentitySHA256(mismatchedBase),
            currentBucket: baseCursor.currentBucket,
            subjectSpecificity: baseCursor.subjectSpecificity,
            operationPriority: baseCursor.operationPriority,
            canonicalSubjectIdentity: baseCursor.canonicalSubjectIdentity,
            checkpointRevision: baseCursor.checkpointRevision,
            evidenceID: baseCursor.evidenceID
        )
        let mismatchedQuery = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: cut.corpusManifestSHA256,
            subject: fixture.candidate.subject,
            operationIDs: [.functionsPage],
            classifications: [.acceptedCurrent], cursor: mismatchedCursor,
            maximumRecords: 1, maximumEncodedBytes: 16_384
        )
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.evidenceQuery
        let producerSeed = try makeProducer(
            operation: operation, buildIdentity: "test-build",
            canonicalSHA256: String(repeating: "a", count: 64)
        )
        let producer = try makeProducer(
            operation: operation, buildIdentity: "test-build",
            canonicalSHA256: MacScopeAnalysisCore.ReconstructionEvidenceIntegrity
                .canonicalProducerSHA256(producerSeed)
        )
        let task = MacScopeAnalysisCore.ReconstructionTaskRecord(
            identity: try .init(
                taskID: taskID(for: operation), jobID: fixture.input.authority.jobID,
                kind: .retrieveEvidence, subject: fixture.candidate.subject,
                dependencyTaskIDs: [], operationContractIdentity: operation.rawValue,
                canonicalSHA256: String(repeating: "d", count: 64)
            ), state: .running, diagnostic: nil
        )
        let projectionFrontier = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: [:], staleOperations: [], tasks: [task],
                receipts: [], producersByOperation: [operation: producer],
                evidenceAuthorityCutsByOperation: [:]
            )
        let authority = try MacScopeAnalysisCore.ReconstructionToolAuthorityCut(
            jobID: fixture.input.authority.jobID, checkpointRevision: 7,
            roundID: fixture.input.authority.roundID,
            corpusManifestSHA256: cut.corpusManifestSHA256,
            evidenceFrontierSHA256: cut.frontierSHA256,
            projectionFrontierSHA256: projectionFrontier
        )
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: authority,
            requests: [.init(
                operationID: operation, taskID: task.identity.taskID,
                subject: fixture.candidate.subject, retrievalQuery: mismatchedQuery,
                offset: 1, maximumRecords: 1, maximumEncodedBytes: 16_384
            )]
        ).first)
        let input = try MacScope.ReconstructionToolProjectorInput(
            authority: authority, corpusManifest: fixture.input.corpusManifest,
            evidenceCut: cut, tasks: [task], receipts: [],
            producersByOperation: [operation: producer], projectedItemsByOperation: [:],
            staleOperations: [], evidenceAuthorityCutsByOperation: [:]
        )
        let counting = CountingProjector(family: .evidence, operations: [operation])
        do {
            _ = try await MacScope.ReconstructionToolBroker(projectors: [counting]).execute(
                selectedHandleIDs: [handle.handleID], offeredHandles: [handle], input: input
            )
            XCTFail("Expected query/filter cursor rejection")
        } catch {
            XCTAssertEqual(error as? MacScope.ReconstructionToolBrokerError, .invalidEvidenceCursor)
        }
        let invocationCount = await counting.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testProjectorInputRejectsChangedProjectionUnderSameAuthority() throws {
        let fixture = try makeFixture()
        let changed = try MacScope.ReconstructionProjectedReadItem(
            payload: .corpusSummary(try .init(
                artifactCount: 2, functionCount: 0, evidenceCount: 0
            ))
        )
        XCTAssertThrowsError(try MacScope.ReconstructionToolProjectorInput(
            authority: fixture.authority,
            corpusManifest: fixture.input.corpusManifest,
            evidenceCut: fixture.input.evidenceCut,
            tasks: fixture.input.tasks,
            receipts: fixture.input.receipts,
            producersByOperation: fixture.input.producersByOperation,
            projectedItemsByOperation: [.corpusSummary: [changed]],
            staleOperations: fixture.input.staleOperations,
            evidenceAuthorityCutsByOperation: fixture.input.evidenceAuthorityCutsByOperation
        )) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .staleProjection)
        }
    }

    func testAuthenticTerminalReceiptRejectsReplayBeforeProjection() async throws {
        let fixture = try makeFixture()
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: taskID(for: .corpusSummary).uuidString)]
        ).first)
        let firstProjector = CountingProjector(family: .corpus, operations: [.corpusSummary])
        let first = try await MacScope.ReconstructionToolBroker(
            projectors: [firstProjector]
        ).execute(
            selectedHandleIDs: [handle.handleID],
            offeredHandles: [handle],
            input: fixture.input
        )
        XCTAssertThrowsError(try MacScope.ReconstructionToolProjectorInput(
            authority: fixture.authority,
            corpusManifest: fixture.input.corpusManifest,
            evidenceCut: fixture.input.evidenceCut,
            tasks: fixture.input.tasks,
            receipts: [try XCTUnwrap(first.first?.receipt)],
            producersByOperation: fixture.input.producersByOperation,
            projectedItemsByOperation: fixture.input.projectedItemsByOperation,
            staleOperations: fixture.input.staleOperations,
            evidenceAuthorityCutsByOperation: fixture.input.evidenceAuthorityCutsByOperation
        )) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .staleProjection)
        }
    }

    func testTaskMustBeRunningEvidenceRetrievalBeforeProjection() async throws {
        let fixture = try makeFixture()
        let original = try XCTUnwrap(fixture.input.tasks.first {
            $0.identity.taskID == taskID(for: .corpusSummary)
        })
        let invalidTasks = [
            MacScopeAnalysisCore.ReconstructionTaskRecord(
                identity: original.identity,
                state: .completed,
                diagnostic: nil
            ),
            MacScopeAnalysisCore.ReconstructionTaskRecord(
                identity: try .init(
                    taskID: original.identity.taskID,
                    jobID: original.identity.jobID,
                    kind: .modelRound,
                    subject: original.identity.subject,
                    dependencyTaskIDs: [],
                    operationContractIdentity: original.identity.operationContractIdentity,
                    canonicalSHA256: original.identity.canonicalSHA256
                ),
                state: .running,
                diagnostic: nil
            ),
        ]
        for invalidTask in invalidTasks {
            XCTAssertThrowsError(try MacScope.ReconstructionToolProjectorInput(
                authority: fixture.authority,
                corpusManifest: fixture.input.corpusManifest,
                evidenceCut: fixture.input.evidenceCut,
                tasks: fixture.input.tasks.map {
                    $0.identity.taskID == invalidTask.identity.taskID ? invalidTask : $0
                },
                receipts: [],
                producersByOperation: fixture.input.producersByOperation,
                projectedItemsByOperation: fixture.input.projectedItemsByOperation,
                staleOperations: fixture.input.staleOperations,
                evidenceAuthorityCutsByOperation: fixture.input.evidenceAuthorityCutsByOperation
            )) {
                XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .staleProjection)
            }
        }
    }

    func testIndependentAppCatalogFreezesAllOperationMetadata() {
        XCTAssertEqual(MacScopeAnalysisCore.ReconstructionAppToolCatalog.registryID, "reconstruction.v1")
        XCTAssertEqual(MacScopeAnalysisCore.ReconstructionAppToolCatalog.schemaSetID, "reconstruction.v1.schemas")
        XCTAssertEqual(
            MacScopeAnalysisCore.ReconstructionAppToolCatalog.entries.map(\.operationID),
            MacScopeAnalysisCore.ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }
        )
        XCTAssertEqual(Set(MacScopeAnalysisCore.ReconstructionAppToolCatalog.entries.map(\.functionName)).count, 16)
        XCTAssertTrue(MacScopeAnalysisCore.ReconstructionAppToolCatalog.entries.allSatisfy {
            $0.functionName == "macscope_\($0.operationID.rawValue.replacingOccurrences(of: ".", with: "_"))_v1"
                && !$0.description.isEmpty
        })
    }

    func testSourceRevisionCannotMintAnOrdinaryToolHandle() throws {
        let fixture = try makeFixture()
        for operation in [MacScopeAnalysisCore.ReconstructionOperationID.sourceRevision, .sourceOracle, .sourceEvaluate] {
            XCTAssertNil(MacScopeAnalysisCore.ReconstructionAppToolCatalog.entries.first { $0.operationID == operation })
            XCTAssertThrowsError(try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
                authority: fixture.authority,
                requests: [request(operation, task: "00000000-0000-4000-8000-000000000011")]
            )) {
                XCTAssertEqual($0 as? MacScopeAnalysisCore.ReconstructionToolRegistryError, .invalidRequest)
            }
        }
    }

    func testRegistryMintsDeterministicCompleteHandlesInCatalogOrder() throws {
        let fixture = try makeFixture()
        let requests = [
            request(.checkpointStatus, task: "00000000-0000-4000-8000-00000000000F"),
            request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001"),
        ]

        let first = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: requests
        )
        let second = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: Array(requests.reversed())
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map { $0.operationID.rawValue }, [
            "reconstruction.corpus.summary", "reconstruction.checkpoint.status",
        ])
        XCTAssertTrue(first.allSatisfy { $0.requestSHA256 == sha256($0.canonicalRequest) })
        XCTAssertTrue(first.allSatisfy { isCanonicalLowercaseSHA256($0.requestSHA256) })
        XCTAssertEqual(first.map(\.jobID), [fixture.authority.jobID, fixture.authority.jobID])
        XCTAssertEqual(first.map(\.checkpointRevision), [7, 7])
        XCTAssertEqual(first.map(\.roundID), [fixture.authority.roundID, fixture.authority.roundID])
        XCTAssertNotEqual(first[0].handleID, first[1].handleID)
    }

    func testRegistryRejectsDuplicateOperationsAndInvalidBoundsBeforeExposure() throws {
        let fixture = try makeFixture()
        let registry = MacScopeAnalysisCore.ReconstructionToolRegistry()
        XCTAssertThrowsError(try registry.mintHandles(
            authority: fixture.authority,
            requests: [
                request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001"),
                request(.corpusSummary, task: "00000000-0000-4000-8000-000000000002"),
            ]
        )) {
            XCTAssertEqual($0 as? MacScopeAnalysisCore.ReconstructionToolRegistryError, .duplicateOperation)
        }
        XCTAssertThrowsError(try registry.mintHandles(
            authority: fixture.authority,
            requests: [MacScopeAnalysisCore.ReconstructionToolRequest(
                operationID: .corpusSummary,
                taskID: UUID(),
                subject: nil,
                retrievalQuery: nil,
                offset: 0,
                maximumRecords: 0,
                maximumEncodedBytes: 1_024
            )]
        )) {
            XCTAssertEqual($0 as? MacScopeAnalysisCore.ReconstructionToolRegistryError, .invalidRequest)
        }
        XCTAssertNoThrow(try registry.mintHandles(
            authority: fixture.authority,
            requests: [.init(
                operationID: .corpusSummary,
                taskID: taskID(for: .corpusSummary),
                subject: nil,
                retrievalQuery: nil,
                offset: 100_000,
                maximumRecords: 1,
                maximumEncodedBytes: 64
            )]
        ))
        XCTAssertThrowsError(try registry.mintHandles(
            authority: fixture.authority,
            requests: [.init(
                operationID: .corpusSummary,
                taskID: taskID(for: .corpusSummary),
                subject: nil,
                retrievalQuery: nil,
                offset: 100_001,
                maximumRecords: 1,
                maximumEncodedBytes: 64
            )]
        )) {
            XCTAssertEqual($0 as? MacScopeAnalysisCore.ReconstructionToolRegistryError, .invalidRequest)
        }
    }

    func testRegistryRejectsRetrievalQueryForAnotherCorpusBeforeExposure() throws {
        let fixture = try makeFixture()
        let staleQuery = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: String(repeating: "b", count: 64),
            subject: nil,
            operationIDs: [.corpusSummary],
            classifications: [.acceptedCurrent],
            cursor: nil,
            maximumRecords: 8,
            maximumEncodedBytes: 16_384
        )
        XCTAssertThrowsError(try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [.init(
                operationID: .evidenceQuery,
                taskID: taskID(for: .evidenceQuery),
                subject: nil,
                retrievalQuery: staleQuery,
                offset: 0,
                maximumRecords: 8,
                maximumEncodedBytes: 16_384
            )]
        )) {
            XCTAssertEqual($0 as? MacScopeAnalysisCore.ReconstructionToolRegistryError, .invalidRequest)
        }
    }

    func testEveryInvalidSelectionClassExecutesZeroProjectors() async throws {
        let fixture = try makeFixture()
        let registry = MacScopeAnalysisCore.ReconstructionToolRegistry()
        let handles = try registry.mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001")]
        )
        let valid = try XCTUnwrap(handles.first)

        let unknown = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!
        try await assertRejectedWithoutProjection(
            selected: [unknown], handles: handles, input: fixture.input, expected: .unknownHandle
        )
        try await assertRejectedWithoutProjection(
            selected: [valid.handleID, valid.handleID], handles: handles,
            input: fixture.input, expected: .duplicateHandle
        )

        var badBytes = valid.canonicalRequest
        badBytes.append(0x20)
        let malformed = copy(valid, canonicalRequest: badBytes)
        try await assertRejectedWithoutProjection(
            selected: [malformed.handleID], handles: [malformed], input: fixture.input,
            expected: .nonCanonicalRequest
        )
        let badDigest = copy(valid, requestSHA256: String(repeating: "A", count: 64))
        try await assertRejectedWithoutProjection(
            selected: [badDigest.handleID], handles: [badDigest], input: fixture.input,
            expected: .invalidRequestDigest
        )
        let other = try makeFixture(corpusDigest: String(repeating: "b", count: 64))
        try await assertRejectedWithoutProjection(
            selected: [valid.handleID], handles: handles, input: other.input,
            expected: .staleCorpus
        )
        let crossJob = copy(valid, jobID: UUID())
        try await assertRejectedWithoutProjection(
            selected: [crossJob.handleID], handles: [crossJob], input: fixture.input,
            expected: .crossJob
        )
        let crossCheckpoint = copy(valid, checkpointRevision: 8)
        try await assertRejectedWithoutProjection(
            selected: [crossCheckpoint.handleID], handles: [crossCheckpoint], input: fixture.input,
            expected: .crossCheckpoint
        )
        let crossRound = copy(valid, roundID: UUID())
        try await assertRejectedWithoutProjection(
            selected: [crossRound.handleID], handles: [crossRound], input: fixture.input,
            expected: .crossRound
        )
        let duplicateOperation = MacScopeAnalysisCore.ReconstructionToolHandle(
            handleID: UUID(uuidString: "EEEEEEEE-EEEE-4EEE-AEEE-EEEEEEEEEEEE")!,
            operationID: valid.operationID,
            canonicalRequest: valid.canonicalRequest,
            requestSHA256: valid.requestSHA256,
            jobID: valid.jobID,
            checkpointRevision: valid.checkpointRevision,
            roundID: valid.roundID
        )
        try await assertRejectedWithoutProjection(
            selected: [valid.handleID, duplicateOperation.handleID],
            handles: [valid, duplicateOperation], input: fixture.input,
            expected: .duplicateOperation
        )

        let forgedID = copy(valid, handleID: UUID())
        try await assertRejectedWithoutProjection(
            selected: [forgedID.handleID], handles: [forgedID], input: fixture.input,
            expected: .invalidHandleIdentity
        )
    }

    func testWholeSelectionRouteAndTaskPreflightExecutesZeroProjectors() async throws {
        let fixture = try makeFixture()
        let handles = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [
                request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001"),
                request(.checkpointStatus, task: taskID(for: .checkpointStatus).uuidString),
            ]
        )
        let corpus = CountingProjector(family: .corpus, operations: [.corpusSummary])
        let broker = MacScope.ReconstructionToolBroker(projectors: [corpus])
        do {
            _ = try await broker.execute(
                selectedHandleIDs: handles.map(\.handleID),
                offeredHandles: handles,
                input: fixture.input
            )
            XCTFail("Expected route rejection")
        } catch {
            XCTAssertEqual(error as? MacScope.ReconstructionToolBrokerError, .invalidProjectorRoute)
        }
        let routeInvocationCount = await corpus.invocationCount
        XCTAssertEqual(routeInvocationCount, 0)

        let missingTask = try makeFixture(includeTasks: false)
        let missingTaskHandle = try XCTUnwrap(
            MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
                authority: missingTask.authority,
                requests: [request(
                    .corpusSummary,
                    task: "00000000-0000-4000-8000-000000000001"
                )]
            ).first
        )
        try await assertRejectedWithoutProjection(
            selected: [missingTaskHandle.handleID],
            handles: [missingTaskHandle],
            input: missingTask.input,
            expected: .unknownTask
        )
        let crossJobTask = try makeFixture(taskJobID: UUID())
        let crossJobHandle = try XCTUnwrap(
            MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
                authority: crossJobTask.authority,
                requests: [request(
                    .corpusSummary,
                    task: "00000000-0000-4000-8000-000000000001"
                )]
            ).first
        )
        try await assertRejectedWithoutProjection(
            selected: [crossJobHandle.handleID],
            handles: [crossJobHandle],
            input: crossJobTask.input,
            expected: .crossJobTask
        )
    }

    func testInvalidProducerIsRejectedBeforeProjectorCanRun() async throws {
        let projector = CountingProjector(family: .corpus, operations: [.corpusSummary])
        XCTAssertThrowsError(try makeFixture(validProducer: false)) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .invalidProducer)
        }
        XCTAssertThrowsError(try makeFixture(producerBuildIdentity: NSHomeDirectory())) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .invalidProducer)
        }
        let invocationCount = await projector.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testZeroSelectionReturnsNoResultsAndDoesNotInvokeProjectors() async throws {
        let fixture = try makeFixture()
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusSummary]
        )
        let broker = MacScope.ReconstructionToolBroker(projectors: [projector])
        let results = try await broker.execute(
            selectedHandleIDs: [],
            offeredHandles: [],
            input: fixture.input
        )

        XCTAssertEqual(results, [])
        let invocationCount = await projector.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testValidSelectionRoutesOnceAndReturnsTerminalResultAndReceipt() async throws {
        let fixture = try makeFixture()
        let handles = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001")]
        )
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusSummary],
            result: .success(payload: Data(#"{"summary":"ok"}"#.utf8), count: 1)
        )
        let broker = MacScope.ReconstructionToolBroker(projectors: [projector])
        let executions = try await broker.execute(
            selectedHandleIDs: handles.map(\.handleID),
            offeredHandles: handles,
            input: fixture.input
        )

        let invocationCount = await projector.invocationCount
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(executions.count, 1)
        XCTAssertEqual(executions[0].result.outcome, .success)
        XCTAssertEqual(executions[0].result.payloadSHA256, sha256(executions[0].result.payload))
        XCTAssertEqual(executions[0].receipt.jobID, fixture.authority.jobID)
        XCTAssertEqual(executions[0].receipt.checkpointRevision, 7)
        XCTAssertEqual(executions[0].receipt.terminalState, .completed)
        XCTAssertEqual(
            executions[0].receipt.producer.operationIdentity,
            executions[0].operationID.rawValue
        )
        let receipt = executions[0].receipt
        XCTAssertEqual(
            receipt.canonicalSHA256,
            try MacScopeAnalysisCore.ReconstructionCanonicalJSON.sha256(of: TestToolReceiptDigestPreimage(
                schemaVersion: MacScopeAnalysisCore.ReconstructionToolReceipt.schemaVersion,
                receiptID: receipt.receiptID,
                jobID: receipt.jobID,
                taskID: receipt.taskID,
                checkpointRevision: receipt.checkpointRevision,
                requestIdentitySHA256: receipt.requestIdentitySHA256,
                producer: receipt.producer,
                terminalState: receipt.terminalState,
                outputEvidenceIDs: receipt.outputEvidenceIDs,
                diagnostic: receipt.diagnostic
            ))
        )
    }

    func testSelectionOrderIsCanonicalAcrossProviderOrdering() async throws {
        let fixture = try makeFixture()
        let handles = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [
                request(.checkpointStatus, task: taskID(for: .checkpointStatus).uuidString),
                request(.corpusSummary, task: taskID(for: .corpusSummary).uuidString),
            ]
        )
        let broker = MacScope.ReconstructionToolBroker(projectors: [
            CountingProjector(family: .corpus, operations: [.corpusSummary]),
            CountingProjector(family: .checkpoint, operations: [.checkpointStatus]),
        ])

        let forward = try await broker.execute(
            selectedHandleIDs: handles.map(\.handleID),
            offeredHandles: handles,
            input: fixture.input
        )
        let reversed = try await broker.execute(
            selectedHandleIDs: handles.reversed().map(\.handleID),
            offeredHandles: Array(handles.reversed()),
            input: fixture.input
        )

        XCTAssertEqual(forward.map(\.operationID), [.corpusSummary, .checkpointStatus])
        XCTAssertEqual(reversed.map(\.operationID), forward.map(\.operationID))
        XCTAssertEqual(reversed.map(\.receipt), forward.map(\.receipt))
    }

    func testBrokerFailsClosedOnInvalidProjectorResult() async throws {
        let fixture = try makeFixture()
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: taskID(for: .corpusSummary).uuidString)]
        ).first)
        let payload = Data(#"{"summary":"ok"}"#.utf8)
        let empty = Data("[]".utf8)
        let invalidResults = [
            MacScope.ReconstructionToolProjectionResult(
                outcome: .success,
                payload: payload,
                payloadSHA256: String(repeating: "0", count: 64),
                itemCount: 1,
                diagnostic: nil,
                continuationRequest: nil
            ),
            MacScope.ReconstructionToolProjectionResult(
                outcome: .success,
                payload: empty,
                payloadSHA256: sha256(empty),
                itemCount: 17,
                diagnostic: nil,
                continuationRequest: nil
            ),
            MacScope.ReconstructionToolProjectionResult(
                outcome: .truncated,
                payload: payload,
                payloadSHA256: sha256(payload),
                itemCount: 1,
                diagnostic: nil,
                continuationRequest: nil
            ),
            MacScope.ReconstructionToolProjectionResult(
                outcome: .unavailable,
                payload: payload,
                payloadSHA256: sha256(payload),
                itemCount: 1,
                diagnostic: .sanitizing("Unavailable."),
                continuationRequest: nil
            ),
        ]
        for invalid in invalidResults {
            let executions = try await MacScope.ReconstructionToolBroker(projectors: [
                CountingProjector(family: .corpus, operations: [.corpusSummary], result: invalid),
            ]).execute(
                selectedHandleIDs: [handle.handleID],
                offeredHandles: [handle],
                input: fixture.input
            )
            let execution = try XCTUnwrap(executions.first)

            XCTAssertEqual(execution.result.outcome, .failed)
            XCTAssertEqual(
                execution.result.diagnostic?.text,
                "Read projector returned an invalid result."
            )
            XCTAssertTrue(execution.acceptedEvidence.isEmpty)
            XCTAssertTrue(execution.receipt.outputEvidenceIDs.isEmpty)
        }
    }

    func testSelectionTaskAndManifestBoundsRejectBeforeProjection() async throws {
        let fixture = try makeFixture()
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: taskID(for: .corpusSummary).uuidString)]
        ).first)
        try await assertRejectedWithoutProjection(
            selected: (0..<(MacScopeAnalysisCore.ReconstructionOperationID.allCases.count + 1)).map { _ in UUID() },
            handles: [handle],
            input: fixture.input,
            expected: .invalidSelectionBounds
        )
        try await assertRejectedWithoutProjection(
            selected: [handle.handleID],
            handles: Array(repeating: handle, count: MacScopeAnalysisCore.ReconstructionOperationID.allCases.count + 1),
            input: fixture.input,
            expected: .invalidSelectionBounds
        )
        XCTAssertThrowsError(try makeFixture(duplicateTask: true)) {
            XCTAssertEqual(
                $0 as? MacScope.ReconstructionToolBrokerError,
                .duplicateTask
            )
        }
        XCTAssertThrowsError(try makeFixture(validManifestDigest: false)) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .invalidCorpusManifest)
        }
    }

    func testRequestSubjectMustMatchTaskSubjectBeforeProjection() async throws {
        let fixture = try makeFixture()
        let subject = try testArtifactSubject(90)
        let request = MacScopeAnalysisCore.ReconstructionToolRequest(
            operationID: .corpusSummary,
            taskID: taskID(for: .corpusSummary),
            subject: subject,
            retrievalQuery: nil,
            offset: 0,
            maximumRecords: 1,
            maximumEncodedBytes: 64
        )
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request]
        ).first)
        try await assertRejectedWithoutProjection(
            selected: [handle.handleID],
            handles: [handle],
            input: fixture.input,
            expected: .taskSubjectMismatch
        )
    }

    func testCancellationPropagatesWithoutFabricatingFailureResult() async throws {
        let fixture = try makeFixture()
        let handles = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001")]
        )
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusSummary],
            cancellation: true
        )
        let broker = MacScope.ReconstructionToolBroker(projectors: [projector])

        do {
            _ = try await broker.execute(
                selectedHandleIDs: handles.map(\.handleID),
                offeredHandles: handles,
                input: fixture.input
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let invocationCount = await projector.invocationCount
            XCTAssertEqual(invocationCount, 1)
        }
    }

    func testProjectorFailureUsesGenericBoundedDiagnostic() async throws {
        let fixture = try makeFixture()
        let handles = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request(.corpusSummary, task: "00000000-0000-4000-8000-000000000001")]
        )
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusSummary],
            failureText: "private failure at \(NSHomeDirectory())/secret.bin"
        )
        let executions = try await MacScope.ReconstructionToolBroker(
            projectors: [projector]
        ).execute(
            selectedHandleIDs: handles.map(\.handleID),
            offeredHandles: handles,
            input: fixture.input
        )
        let execution = try XCTUnwrap(executions.first)

        XCTAssertEqual(execution.result.outcome, .failed)
        XCTAssertEqual(execution.result.diagnostic?.text, "Read projector failed.")
        XCTAssertFalse(execution.result.diagnostic?.text.contains(NSHomeDirectory()) == true)
        XCTAssertLessThanOrEqual(execution.result.diagnostic?.text.utf8.count ?? .max, 1_024)
    }

    func testEvidenceCandidatesAreAcceptedAtomicallyBeforeReceiptConstruction() async throws {
        let fixture = try makeEvidenceBrokerFixture()
        let acceptedProjector = CountingProjector(
            family: .corpus,
            operations: [.corpusArtifactDescribe],
            result: .success(
                payload: Data(#"[{"value":1}]"#.utf8),
                count: 1,
                evidenceCandidates: [fixture.candidate]
            )
        )
        let acceptedExecutions = try await MacScope.ReconstructionToolBroker(
            projectors: [acceptedProjector]
        ).execute(
            selectedHandleIDs: [fixture.handle.handleID],
            offeredHandles: [fixture.handle],
            input: fixture.input
        )
        let accepted = try XCTUnwrap(acceptedExecutions.first)

        XCTAssertEqual(accepted.result.outcome, .success)
        XCTAssertEqual(accepted.acceptedEvidence.map(\.evidenceID), [fixture.candidate.evidenceID])
        XCTAssertEqual(accepted.receipt.outputEvidenceIDs, [fixture.candidate.evidenceID])

        let rejectingProjector = CountingProjector(
            family: .corpus,
            operations: [.corpusArtifactDescribe],
            result: .success(
                payload: Data(#"[{"value":1}]"#.utf8),
                count: 1,
                evidenceCandidates: [fixture.candidate, fixture.hostileCandidate]
            )
        )
        let rejectedExecutions = try await MacScope.ReconstructionToolBroker(
            projectors: [rejectingProjector]
        ).execute(
            selectedHandleIDs: [fixture.handle.handleID],
            offeredHandles: [fixture.handle],
            input: fixture.input
        )
        let rejected = try XCTUnwrap(rejectedExecutions.first)

        XCTAssertEqual(rejected.result.outcome, .failed)
        XCTAssertEqual(rejected.result.diagnostic?.text, "Projected evidence failed validation.")
        XCTAssertTrue(rejected.acceptedEvidence.isEmpty)
        XCTAssertTrue(rejected.receipt.outputEvidenceIDs.isEmpty)
        XCTAssertEqual(rejected.receipt.terminalState, .failed)
    }

    func testBuiltInCorpusProjectorCarriesBoundEvidenceThroughRealAcceptor() async throws {
        let fixture = try makeEvidenceBrokerFixture()
        let executions = try await MacScope.ReconstructionToolBroker(
            projectors: [MacScope.ReconstructionCorpusToolProjector()]
        ).execute(
            selectedHandleIDs: [fixture.handle.handleID],
            offeredHandles: [fixture.handle],
            input: fixture.input
        )
        let execution = try XCTUnwrap(executions.first)
        XCTAssertEqual(execution.result.outcome, .success)
        XCTAssertEqual(execution.acceptedEvidence.map(\.evidenceID), [fixture.candidate.evidenceID])
        XCTAssertEqual(execution.receipt.outputEvidenceIDs, [fixture.candidate.evidenceID])
    }

    func testGlobalEvidenceAdmissionRejectsCrossOperationIdentityAndSupersessionConflicts() async throws {
        let fixture = try makeEvidenceBrokerFixture()
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.functionReview
        let taskID = taskID(for: operation)
        let subject = fixture.candidate.subject
        let provisional = try makeProducer(
            operation: operation,
            buildIdentity: "test-build",
            canonicalSHA256: String(repeating: "c", count: 64)
        )
        let producer = try makeProducer(
            operation: operation,
            buildIdentity: "test-build",
            canonicalSHA256: MacScopeAnalysisCore.ReconstructionEvidenceIntegrity
                .canonicalProducerSHA256(provisional)
        )
        let secondRequest = MacScopeAnalysisCore.ReconstructionToolRequest(
            operationID: operation,
            taskID: taskID,
            subject: subject,
            retrievalQuery: nil,
            offset: 0,
            maximumRecords: 8,
            maximumEncodedBytes: 16_384
        )
        let secondTask = MacScopeAnalysisCore.ReconstructionTaskRecord(
            identity: try .init(
                taskID: taskID,
                jobID: fixture.input.authority.jobID,
                kind: .retrieveEvidence,
                subject: subject,
                dependencyTaskIDs: [],
                operationContractIdentity: operation.rawValue,
                canonicalSHA256: String(repeating: "d", count: 64)
            ),
            state: .running,
            diagnostic: nil
        )
        let originalCut = try XCTUnwrap(
            fixture.input.evidenceAuthorityCutsByOperation[.corpusArtifactDescribe]
        )
        let preliminarySecondCut = MacScope.ReconstructionAuthorityCut(
            corpusManifest: originalCut.corpusManifest,
            authoritativeSubjects: originalCut.authoritativeSubjects,
            facetFingerprints: originalCut.facetFingerprints,
            creatingJobID: originalCut.creatingJobID,
            creatingTaskID: taskID,
            creatingCheckpointID: originalCut.creatingCheckpointID,
            checkpointRevision: originalCut.checkpointRevision,
            operationID: operation,
            toolReceiptID: nil,
            modelReceiptID: nil,
            producer: producer,
            evidence: originalCut.evidence
        )
        let combinedTasks = fixture.input.tasks + [secondTask]
        let combinedProducers = fixture.input.producersByOperation.merging([operation: producer]) {
            current, _ in current
        }
        let preliminaryCuts = fixture.input.evidenceAuthorityCutsByOperation
            .merging([operation: preliminarySecondCut]) { current, _ in current }
        let projectionFrontier = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: fixture.input.projectedItemsByOperation,
                staleOperations: fixture.input.staleOperations,
                tasks: combinedTasks,
                receipts: [],
                producersByOperation: combinedProducers,
                evidenceAuthorityCutsByOperation: preliminaryCuts
            )
        let authority = try MacScopeAnalysisCore.ReconstructionToolAuthorityCut(
            jobID: fixture.input.authority.jobID,
            checkpointRevision: fixture.input.authority.checkpointRevision,
            roundID: fixture.input.authority.roundID,
            corpusManifestSHA256: fixture.input.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: fixture.input.authority.evidenceFrontierSHA256,
            projectionFrontierSHA256: projectionFrontier
        )
        let firstRequest = try MacScopeAnalysisCore.ReconstructionToolRegistry()
            .decodeCanonicalRequest(fixture.handle).request
        let handles = try MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: authority,
            requests: [firstRequest, secondRequest]
        )
        let firstHandle = try XCTUnwrap(handles.first { $0.operationID == .corpusArtifactDescribe })
        let secondHandle = try XCTUnwrap(handles.first { $0.operationID == operation })
        let firstCut = copy(originalCut, toolReceiptID: firstHandle.handleID)
        let secondCut = copy(preliminarySecondCut, toolReceiptID: secondHandle.handleID)
        let input = try MacScope.ReconstructionToolProjectorInput(
            authority: authority,
            corpusManifest: fixture.input.corpusManifest,
            evidenceCut: fixture.input.evidenceCut,
            tasks: combinedTasks,
            receipts: [],
            producersByOperation: combinedProducers,
            projectedItemsByOperation: fixture.input.projectedItemsByOperation,
            staleOperations: fixture.input.staleOperations,
            evidenceAuthorityCutsByOperation: [
                .corpusArtifactDescribe: firstCut,
                operation: secondCut,
            ]
        )
        func secondCandidate(
            evidenceID: UUID,
            supersedes: UUID?
        ) throws -> MacScope.ReconstructionEvidenceCandidate {
            try .init(
                evidenceID: evidenceID,
                subject: subject,
                operationID: operation,
                payloadKind: fixture.candidate.payloadKind,
                payload: fixture.candidate.payload,
                payloadByteCount: fixture.candidate.payloadByteCount,
                payloadSHA256: fixture.candidate.payloadSHA256,
                facetDependencies: [],
                producer: producer,
                citations: fixture.candidate.citations,
                creatingJobID: authority.jobID,
                creatingTaskID: taskID,
                creatingCheckpointID: originalCut.creatingCheckpointID,
                modelReceiptID: nil,
                toolReceiptID: secondHandle.handleID,
                supersedesEvidenceID: supersedes,
                diagnostic: nil
            )
        }
        let predecessor = UUID()
        let scenarios: [(MacScope.ReconstructionEvidenceCandidate,
                         MacScope.ReconstructionEvidenceCandidate,
                         MacScope.ReconstructionToolBrokerError)] = [
            (try replacingToolReceipt(fixture.candidate, receiptID: firstHandle.handleID),
             try secondCandidate(evidenceID: fixture.candidate.evidenceID, supersedes: nil),
             .duplicateEvidenceID),
            (try replacingSupersession(
                replacingToolReceipt(fixture.candidate, receiptID: firstHandle.handleID),
                predecessor: predecessor
            ),
             try secondCandidate(evidenceID: UUID(), supersedes: predecessor),
             .conflictingSupersession),
        ]
        for (firstCandidate, secondCandidate, expected) in scenarios {
            let firstProjector = CountingProjector(
                family: .corpus,
                operations: [.corpusArtifactDescribe],
                result: .success(payload: Data("[]".utf8), count: 0,
                                 evidenceCandidates: [firstCandidate])
            )
            let secondProjector = CountingProjector(
                family: .imageFunction,
                operations: [operation],
                result: .success(payload: Data("[]".utf8), count: 0,
                                 evidenceCandidates: [secondCandidate])
            )
            do {
                _ = try await MacScope.ReconstructionToolBroker(
                    projectors: [firstProjector, secondProjector]
                ).execute(
                    selectedHandleIDs: [firstHandle.handleID, secondHandle.handleID],
                    offeredHandles: [firstHandle, secondHandle],
                    input: input
                )
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? MacScope.ReconstructionToolBrokerError, expected)
            }
            let firstInvocationCount = await firstProjector.invocationCount
            let secondInvocationCount = await secondProjector.invocationCount
            XCTAssertEqual(firstInvocationCount, 1)
            XCTAssertEqual(secondInvocationCount, 1)
        }
    }

    func testDuplicateCandidateIDsRejectBeforeEvidenceAcceptorRuns() async throws {
        let fixture = try makeEvidenceBrokerFixture()
        let countingAcceptor = CountingEvidenceAcceptor()
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusArtifactDescribe],
            result: .success(
                payload: Data("[]".utf8),
                count: 0,
                evidenceCandidates: Array(repeating: fixture.candidate, count: 6)
            )
        )
        do {
            _ = try await MacScope.ReconstructionToolBroker(
                projectors: [projector], evidenceAcceptor: countingAcceptor
            ).execute(
                selectedHandleIDs: [fixture.handle.handleID],
                offeredHandles: [fixture.handle], input: fixture.input
            )
            XCTFail("Expected duplicate evidence rejection")
        } catch {
            XCTAssertEqual(error as? MacScope.ReconstructionToolBrokerError, .duplicateEvidenceID)
        }
        XCTAssertEqual(countingAcceptor.invocationCount, 0)
    }

    func testCanonicalAcceptedEvidenceBytesAreBoundedAfterRealAcceptance() async throws {
        let fixture = try makeEvidenceBrokerFixture(maximumEncodedBytes: 512)
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusArtifactDescribe],
            result: .success(
                payload: Data(#"[{"value":1}]"#.utf8),
                count: 1,
                evidenceCandidates: [fixture.candidate]
            )
        )
        let executions = try await MacScope.ReconstructionToolBroker(
            projectors: [projector]
        ).execute(
            selectedHandleIDs: [fixture.handle.handleID],
            offeredHandles: [fixture.handle],
            input: fixture.input
        )
        let execution = try XCTUnwrap(executions.first)
        XCTAssertEqual(execution.result.outcome, .failed)
        XCTAssertEqual(execution.result.diagnostic?.text, "Projected evidence failed validation.")
        XCTAssertTrue(execution.acceptedEvidence.isEmpty)
        XCTAssertTrue(execution.receipt.outputEvidenceIDs.isEmpty)
    }

    func testProjectorInputRejectsAuthorityCutCountsAboveDurableCeiling() throws {
        let fixture = try makeEvidenceBrokerFixture()
        let validCut = try XCTUnwrap(
            fixture.input.evidenceAuthorityCutsByOperation[.corpusArtifactDescribe]
        )
        let subject = try XCTUnwrap(validCut.authoritativeSubjects.first)

        let overSubjectCut = copy(
            validCut,
            authoritativeSubjects: Array(repeating: subject, count: 100_001)
        )
        assertInvalidAuthorityCut(overSubjectCut, fixture: fixture)

        let overFacetCut = copy(
            validCut,
            facetFingerprints: Dictionary(uniqueKeysWithValues: (0...100_000).map {
                ("facet-\($0)", String(repeating: "a", count: 64))
            })
        )
        assertInvalidAuthorityCut(overFacetCut, fixture: fixture)
    }

    private func assertRejectedWithoutProjection(
        selected: [UUID],
        handles: [MacScopeAnalysisCore.ReconstructionToolHandle],
        input: MacScope.ReconstructionToolProjectorInput,
        expected: MacScope.ReconstructionToolBrokerError
    ) async throws {
        let projector = CountingProjector(
            family: .corpus,
            operations: [.corpusSummary]
        )
        let broker = MacScope.ReconstructionToolBroker(projectors: [projector])
        do {
            _ = try await broker.execute(
                selectedHandleIDs: selected,
                offeredHandles: handles,
                input: input
            )
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? MacScope.ReconstructionToolBrokerError, expected)
        }
        let invocationCount = await projector.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    private func replacingSupersession(
        _ candidate: MacScope.ReconstructionEvidenceCandidate,
        predecessor: UUID
    ) throws -> MacScope.ReconstructionEvidenceCandidate {
        try .init(
            evidenceID: candidate.evidenceID,
            subject: candidate.subject,
            operationID: candidate.operationID,
            payloadKind: candidate.payloadKind,
            payload: candidate.payload,
            payloadByteCount: candidate.payloadByteCount,
            payloadSHA256: candidate.payloadSHA256,
            facetDependencies: candidate.facetDependencies,
            producer: candidate.producer,
            citations: candidate.citations,
            creatingJobID: candidate.creatingJobID,
            creatingTaskID: candidate.creatingTaskID,
            creatingCheckpointID: candidate.creatingCheckpointID,
            modelReceiptID: candidate.modelReceiptID,
            toolReceiptID: candidate.toolReceiptID,
            supersedesEvidenceID: predecessor,
            diagnostic: candidate.diagnostic
        )
    }

    private func replacingToolReceipt(
        _ candidate: MacScope.ReconstructionEvidenceCandidate,
        receiptID: UUID
    ) throws -> MacScope.ReconstructionEvidenceCandidate {
        try .init(
            evidenceID: candidate.evidenceID,
            subject: candidate.subject,
            operationID: candidate.operationID,
            payloadKind: candidate.payloadKind,
            payload: candidate.payload,
            payloadByteCount: candidate.payloadByteCount,
            payloadSHA256: candidate.payloadSHA256,
            facetDependencies: candidate.facetDependencies,
            producer: candidate.producer,
            citations: candidate.citations,
            creatingJobID: candidate.creatingJobID,
            creatingTaskID: candidate.creatingTaskID,
            creatingCheckpointID: candidate.creatingCheckpointID,
            modelReceiptID: candidate.modelReceiptID,
            toolReceiptID: receiptID,
            supersedesEvidenceID: candidate.supersedesEvidenceID,
            diagnostic: candidate.diagnostic
        )
    }

    private func replacingEvidenceID(
        _ candidate: MacScope.ReconstructionEvidenceCandidate,
        evidenceID: UUID
    ) throws -> MacScope.ReconstructionEvidenceCandidate {
        try .init(
            evidenceID: evidenceID,
            subject: candidate.subject,
            operationID: candidate.operationID,
            payloadKind: candidate.payloadKind,
            payload: candidate.payload,
            payloadByteCount: candidate.payloadByteCount,
            payloadSHA256: candidate.payloadSHA256,
            facetDependencies: candidate.facetDependencies,
            producer: candidate.producer,
            citations: candidate.citations,
            creatingJobID: candidate.creatingJobID,
            creatingTaskID: candidate.creatingTaskID,
            creatingCheckpointID: candidate.creatingCheckpointID,
            modelReceiptID: candidate.modelReceiptID,
            toolReceiptID: candidate.toolReceiptID,
            supersedesEvidenceID: candidate.supersedesEvidenceID,
            diagnostic: candidate.diagnostic
        )
    }

    private func assertInvalidAuthorityCut(
        _ cut: MacScope.ReconstructionAuthorityCut,
        fixture: EvidenceBrokerFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MacScope.ReconstructionToolProjectorInput(
            authority: fixture.input.authority,
            corpusManifest: fixture.input.corpusManifest,
            evidenceCut: fixture.input.evidenceCut,
            tasks: fixture.input.tasks,
            receipts: fixture.input.receipts,
            producersByOperation: fixture.input.producersByOperation,
            projectedItemsByOperation: fixture.input.projectedItemsByOperation,
            staleOperations: fixture.input.staleOperations,
            evidenceAuthorityCutsByOperation: [.corpusArtifactDescribe: cut]
        ), file: file, line: line) {
            XCTAssertEqual(
                $0 as? MacScope.ReconstructionToolBrokerError,
                .invalidEvidenceAuthorityCut,
                file: file,
                line: line
            )
        }
    }

    private func makeFixture(
        corpusDigest: String = String(repeating: "a", count: 64),
        includeTasks: Bool = true,
        taskJobID: UUID? = nil,
        validProducer: Bool = true,
        producerBuildIdentity: String = "test-build",
        duplicateTask: Bool = false,
        validManifestDigest: Bool = true
    ) throws -> (
        authority: MacScopeAnalysisCore.ReconstructionToolAuthorityCut,
        input: MacScope.ReconstructionToolProjectorInput
    ) {
        let jobID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let roundID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let projectID = corpusDigest == String(repeating: "a", count: 64)
            ? UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
            : UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let manifestPreimage = TestCorpusManifestDigestPreimage(
            schemaVersion: MacScopeAnalysisCore.ReconstructionCorpusManifest.schemaVersion,
            reconstructionProjectID: projectID,
            artifacts: [],
            relations: []
        )
        let canonicalManifestSHA256 = try MacScopeAnalysisCore.ReconstructionCanonicalJSON
            .sha256(of: manifestPreimage)
        let storedManifestSHA256 = validManifestDigest
            ? canonicalManifestSHA256
            : String(repeating: "a", count: 64)
        let manifest = try MacScopeAnalysisCore.ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [],
            relations: [],
            canonicalSHA256: storedManifestSHA256
        )
        let frontier = try MacScope.ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: storedManifestSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: [],
            checkpointRevisionsByID: [:]
        )
        let cut = try MacScope.ReconstructionEvidenceCut(
            corpusManifestSHA256: storedManifestSHA256,
            records: [],
            relations: [],
            gaps: [],
            frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: [:],
            checkpointRevisionsByID: [:]
        )
        let projectedItems: [MacScopeAnalysisCore.ReconstructionOperationID: [MacScope.ReconstructionProjectedReadItem]] = [
            .corpusSummary: [try .init(
                payload: .corpusSummary(try .init(
                    artifactCount: 1, functionCount: 0, evidenceCount: 0
                ))
            )],
        ]
        let producersByOperation = try Dictionary(uniqueKeysWithValues:
            MacScopeAnalysisCore.ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }.map { operation in
                let provisional = try makeProducer(
                    operation: operation,
                    buildIdentity: producerBuildIdentity,
                    canonicalSHA256: String(repeating: "c", count: 64)
                )
                let digest = try MacScopeAnalysisCore.ReconstructionEvidenceIntegrity
                    .canonicalProducerSHA256(provisional)
                return (operation, try makeProducer(
                    operation: operation,
                    buildIdentity: producerBuildIdentity,
                    canonicalSHA256: validProducer || operation != .corpusSummary
                        ? digest
                        : String(repeating: "c", count: 64)
                ))
            }
        )
        var tasks = includeTasks ? try MacScopeAnalysisCore.ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }.map { operation in
            MacScopeAnalysisCore.ReconstructionTaskRecord(
                identity: try MacScopeAnalysisCore.ReconstructionTaskIdentity(
                    taskID: taskID(for: operation),
                    jobID: taskJobID ?? jobID,
                    kind: .retrieveEvidence,
                    subject: nil,
                    dependencyTaskIDs: [],
                    operationContractIdentity: operation.rawValue,
                    canonicalSHA256: String(repeating: "d", count: 64)
                ),
                state: .running,
                diagnostic: nil
            )
        } : []
        if duplicateTask, let first = tasks.first { tasks.append(first) }
        let projectionFrontier = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: projectedItems,
                staleOperations: [],
                tasks: tasks,
                receipts: [],
                producersByOperation: producersByOperation,
                evidenceAuthorityCutsByOperation: [:]
            )
        let authority = try MacScopeAnalysisCore.ReconstructionToolAuthorityCut(
            jobID: jobID,
            checkpointRevision: 7,
            roundID: roundID,
            corpusManifestSHA256: storedManifestSHA256,
            evidenceFrontierSHA256: frontier,
            projectionFrontierSHA256: projectionFrontier
        )
        let input = try MacScope.ReconstructionToolProjectorInput(
            authority: authority,
            corpusManifest: manifest,
            evidenceCut: cut,
            tasks: tasks,
            receipts: [],
            producersByOperation: producersByOperation,
            projectedItemsByOperation: projectedItems,
            staleOperations: [],
            evidenceAuthorityCutsByOperation: [:]
        )
        return (authority, input)
    }

    private func makeEvidenceBrokerFixture(
        maximumEncodedBytes: Int = 16_384
    ) throws -> EvidenceBrokerFixture {
        let jobID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let roundID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let checkpointID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let taskID = taskID(for: .corpusArtifactDescribe)
        let content = try MacScopeAnalysisCore.ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: String(repeating: "a", count: 64),
            byteCount: 4_096
        )
        let coordinate = MacScopeAnalysisCore.ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID(uuidString: "51000000-0000-4000-8000-000000000003")!),
            contentIdentity: content
        )
        let subject = MacScopeAnalysisCore.ReconstructionSubjectCoordinate.artifact(coordinate)
        let occurrence = try MacScopeAnalysisCore.ReconstructionArtifactOccurrenceRecord(
            occurrenceID: coordinate.occurrenceID,
            contentIdentity: content,
            kind: .objectFile,
            roles: [.primaryTarget],
            executableMode: false,
            originalName: "fixture.o",
            diagnostic: nil
        )
        let projectID = UUID(uuidString: "51000000-0000-4000-8000-000000000004")!
        let manifestPreimage = TestCorpusManifestDigestPreimage(
            schemaVersion: MacScopeAnalysisCore.ReconstructionCorpusManifest.schemaVersion,
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: []
        )
        let manifest = try MacScopeAnalysisCore.ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: [],
            canonicalSHA256: MacScopeAnalysisCore.ReconstructionCanonicalJSON.sha256(of: manifestPreimage)
        )
        let frontier = try MacScope.ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: [],
            checkpointRevisionsByID: [:]
        )
        let evidenceCut = try MacScope.ReconstructionEvidenceCut(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            relations: [],
            gaps: [],
            frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: [:],
            checkpointRevisionsByID: [:]
        )
        let citation = try MacScopeAnalysisCore.ReconstructionEvidenceCitation(
            citationID: UUID(uuidString: "51000000-0000-4000-8000-000000000002")!,
            sourceEvidenceID: nil,
            subject: subject,
            locator: nil
        )
        let payload = Data(#"{"value":1}"#.utf8)
        let evidenceID = UUID(uuidString: "51000000-0000-4000-8000-000000000001")!
        let projectedItems: [MacScopeAnalysisCore.ReconstructionOperationID: [MacScope.ReconstructionProjectedReadItem]] = [
            .corpusArtifactDescribe: [try .init(
                payload: .corpusArtifactDescribe(try .init(
                    subject: subject,
                    operationID: .corpusArtifactDescribe,
                    canonicalSHA256: sha256(payload),
                    byteCount: UInt64(payload.count)
                )),
                evidence: try .init(
                    evidenceID: evidenceID,
                    subject: subject,
                    operationID: .corpusArtifactDescribe,
                    payloadKind: .structuredJSON,
                    payload: payload,
                    facetDependencies: [],
                    citations: [citation],
                    supersedesEvidenceID: nil,
                    diagnostic: nil
                )
            )],
        ]
        let provisionalProducer = try makeProducer(
            operation: .corpusArtifactDescribe,
            buildIdentity: "test-build",
            canonicalSHA256: String(repeating: "c", count: 64)
        )
        let producer = try makeProducer(
            operation: .corpusArtifactDescribe,
            buildIdentity: "test-build",
            canonicalSHA256: MacScopeAnalysisCore.ReconstructionEvidenceIntegrity
                .canonicalProducerSHA256(provisionalProducer)
        )
        let task = MacScopeAnalysisCore.ReconstructionTaskRecord(
            identity: try .init(
                taskID: taskID,
                jobID: jobID,
                kind: .retrieveEvidence,
                subject: subject,
                dependencyTaskIDs: [],
                operationContractIdentity: MacScopeAnalysisCore.ReconstructionOperationID
                    .corpusArtifactDescribe.rawValue,
                canonicalSHA256: String(repeating: "d", count: 64)
            ),
            state: .running,
            diagnostic: nil
        )
        let preliminaryCut = MacScope.ReconstructionAuthorityCut(
            corpusManifest: manifest,
            authoritativeSubjects: [subject],
            facetFingerprints: [:],
            creatingJobID: jobID,
            creatingTaskID: taskID,
            creatingCheckpointID: checkpointID,
            checkpointRevision: 7,
            operationID: .corpusArtifactDescribe,
            toolReceiptID: nil,
            modelReceiptID: nil,
            producer: producer,
            evidence: []
        )
        let projectionFrontier = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: projectedItems,
                staleOperations: [],
                tasks: [task],
                receipts: [],
                producersByOperation: [.corpusArtifactDescribe: producer],
                evidenceAuthorityCutsByOperation: [.corpusArtifactDescribe: preliminaryCut]
            )
        let authority = try MacScopeAnalysisCore.ReconstructionToolAuthorityCut(
            jobID: jobID,
            checkpointRevision: 7,
            roundID: roundID,
            corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier,
            projectionFrontierSHA256: projectionFrontier
        )
        let request = MacScopeAnalysisCore.ReconstructionToolRequest(
            operationID: .corpusArtifactDescribe,
            taskID: taskID,
            subject: subject,
            retrievalQuery: nil,
            offset: 0,
            maximumRecords: 8,
            maximumEncodedBytes: maximumEncodedBytes
        )
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: authority,
            requests: [request]
        ).first)
        func candidate(
            evidenceID candidateEvidenceID: UUID = evidenceID,
            digest: String
        ) throws -> MacScope.ReconstructionEvidenceCandidate {
            try MacScope.ReconstructionEvidenceCandidate(
                evidenceID: candidateEvidenceID,
                subject: subject,
                operationID: .corpusArtifactDescribe,
                payloadKind: .structuredJSON,
                payload: payload,
                payloadByteCount: UInt64(payload.count),
                payloadSHA256: digest,
                facetDependencies: [],
                producer: producer,
                citations: [citation],
                creatingJobID: jobID,
                creatingTaskID: taskID,
                creatingCheckpointID: checkpointID,
                modelReceiptID: nil,
                toolReceiptID: handle.handleID,
                supersedesEvidenceID: nil,
                diagnostic: nil
            )
        }
        let authorityCut = MacScope.ReconstructionAuthorityCut(
            corpusManifest: manifest,
            authoritativeSubjects: [subject],
            facetFingerprints: [:],
            creatingJobID: jobID,
            creatingTaskID: taskID,
            creatingCheckpointID: checkpointID,
            checkpointRevision: 7,
            operationID: .corpusArtifactDescribe,
            toolReceiptID: handle.handleID,
            modelReceiptID: nil,
            producer: producer,
            evidence: []
        )
        let input = try MacScope.ReconstructionToolProjectorInput(
            authority: authority,
            corpusManifest: manifest,
            evidenceCut: evidenceCut,
            tasks: [task],
            receipts: [],
            producersByOperation: [.corpusArtifactDescribe: producer],
            projectedItemsByOperation: projectedItems,
            staleOperations: [],
            evidenceAuthorityCutsByOperation: [.corpusArtifactDescribe: authorityCut]
        )
        return EvidenceBrokerFixture(
            handle: handle,
            input: input,
            candidate: try candidate(digest: sha256(payload)),
            hostileCandidate: try candidate(
                evidenceID: UUID(uuidString: "51000000-0000-4000-8000-000000000099")!,
                digest: String(repeating: "0", count: 64)
            )
        )
    }

    private func request(
        _ operation: MacScopeAnalysisCore.ReconstructionOperationID,
        task taskID: String
    ) -> MacScopeAnalysisCore.ReconstructionToolRequest {
        MacScopeAnalysisCore.ReconstructionToolRequest(
            operationID: operation,
            taskID: UUID(uuidString: taskID)!,
            subject: nil,
            retrievalQuery: nil,
            offset: 0,
            maximumRecords: 16,
            maximumEncodedBytes: 16_384
        )
    }

    private func copy(
        _ handle: MacScopeAnalysisCore.ReconstructionToolHandle,
        handleID: UUID? = nil,
        canonicalRequest: Data? = nil,
        requestSHA256: String? = nil,
        jobID: UUID? = nil,
        checkpointRevision: UInt64? = nil,
        roundID: UUID? = nil
    ) -> MacScopeAnalysisCore.ReconstructionToolHandle {
        .init(
            handleID: handleID ?? handle.handleID,
            operationID: handle.operationID,
            canonicalRequest: canonicalRequest ?? handle.canonicalRequest,
            requestSHA256: requestSHA256 ?? handle.requestSHA256,
            jobID: jobID ?? handle.jobID,
            checkpointRevision: checkpointRevision ?? handle.checkpointRevision,
            roundID: roundID ?? handle.roundID
        )
    }

    private func copy(
        _ cut: MacScope.ReconstructionAuthorityCut,
        authoritativeSubjects: [MacScopeAnalysisCore.ReconstructionSubjectCoordinate]? = nil,
        facetFingerprints: [String: String]? = nil,
        toolReceiptID: UUID? = nil
    ) -> MacScope.ReconstructionAuthorityCut {
        .init(
            corpusManifest: cut.corpusManifest,
            authoritativeSubjects: authoritativeSubjects ?? cut.authoritativeSubjects,
            facetFingerprints: facetFingerprints ?? cut.facetFingerprints,
            creatingJobID: cut.creatingJobID,
            creatingTaskID: cut.creatingTaskID,
            creatingCheckpointID: cut.creatingCheckpointID,
            checkpointRevision: cut.checkpointRevision,
            operationID: cut.operationID,
            toolReceiptID: toolReceiptID ?? cut.toolReceiptID,
            modelReceiptID: cut.modelReceiptID,
            producer: cut.producer,
            evidence: cut.evidence
        )
    }

    private func taskID(for operation: MacScopeAnalysisCore.ReconstructionOperationID) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%012d",
            operation.priority + 1
        ))!
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeProducer(
        operation: MacScopeAnalysisCore.ReconstructionOperationID,
        buildIdentity: String,
        canonicalSHA256: String
    ) throws -> MacScopeAnalysisCore.ReconstructionProducerIdentity {
        try MacScopeAnalysisCore.ReconstructionProducerIdentity(
            macScopeBuildIdentity: buildIdentity,
            macScopeSourceIdentity: "test-source",
            operationIdentity: operation.rawValue,
            registryIdentity: "reconstruction.v1",
            protocolIdentity: "reconstruction.r1",
            canonicalSHA256: canonicalSHA256
        )
    }

    private func testArtifactSubject(_ value: Int) throws -> MacScopeAnalysisCore.ReconstructionSubjectCoordinate {
        .artifact(MacScopeAnalysisCore.ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID(uuidString: String(
                format: "90000000-0000-4000-8000-%012d",
                value
            ))!),
            contentIdentity: try .init(
                algorithm: .sha256,
                digest: String(repeating: "9", count: 64),
                byteCount: 1
            )
        ))
    }

    private func isCanonicalLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private actor CountingProjector: MacScope.ReconstructionToolProjecting {
    nonisolated let family: MacScope.ReconstructionToolProjectorFamily
    nonisolated let operations: Set<MacScopeAnalysisCore.ReconstructionOperationID>
    private(set) var invocationCount = 0
    private let result: MacScope.ReconstructionToolProjectionResult
    private let cancellation: Bool
    private let failureText: String?

    init(
        family: MacScope.ReconstructionToolProjectorFamily,
        operations: Set<MacScopeAnalysisCore.ReconstructionOperationID>,
        result: MacScope.ReconstructionToolProjectionResult = .unavailable("not available"),
        cancellation: Bool = false,
        failureText: String? = nil
    ) {
        self.family = family
        self.operations = operations
        self.result = result
        self.cancellation = cancellation
        self.failureText = failureText
    }

    func project(
        request: MacScopeAnalysisCore.ReconstructionToolRequestEnvelope,
        input: MacScope.ReconstructionToolProjectorInput
    ) async throws -> MacScope.ReconstructionToolProjectionResult {
        invocationCount += 1
        if cancellation { throw CancellationError() }
        if let failureText { throw CountingProjectorFailure(text: failureText) }
        return result
    }
}

private struct CountingProjectorFailure: Error {
    let text: String
}

private struct TestCorpusManifestDigestPreimage: Encodable {
    let schemaVersion: Int
    let reconstructionProjectID: UUID
    let artifacts: [MacScopeAnalysisCore.ReconstructionArtifactOccurrenceRecord]
    let relations: [MacScopeAnalysisCore.ReconstructionArtifactRelationRecord]
}

private struct TestToolReceiptDigestPreimage: Encodable {
    let schemaVersion: Int
    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: MacScopeAnalysisCore.ReconstructionProducerIdentity
    let terminalState: MacScopeAnalysisCore.ReconstructionReceiptTerminalState
    let outputEvidenceIDs: [UUID]
    let diagnostic: MacScopeAnalysisCore.ReconstructionDiagnostic?
}

private struct EvidenceBrokerFixture {
    let handle: MacScopeAnalysisCore.ReconstructionToolHandle
    let input: MacScope.ReconstructionToolProjectorInput
    let candidate: MacScope.ReconstructionEvidenceCandidate
    let hostileCandidate: MacScope.ReconstructionEvidenceCandidate
}

private final class CountingEvidenceAcceptor: MacScope.ReconstructionEvidenceAccepting,
    @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.withLock { count }
    }

    func validate(
        _ candidate: MacScope.ReconstructionEvidenceCandidate,
        against cut: MacScope.ReconstructionAuthorityCut
    ) throws -> MacScopeAnalysisCore.ReconstructionEvidenceRecord {
        lock.withLock { count += 1 }
        throw CountingEvidenceAcceptorError.unexpectedInvocation
    }
}

private enum CountingEvidenceAcceptorError: Error {
    case unexpectedInvocation
}
