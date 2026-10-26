import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionRetrievalCompilerTests: XCTestCase {
    func testSourceBaseReservesOnlyEligibleCurrentIDsWithinContextBudget() throws {
        let artifact = try retrievalArtifact(occurrence: 1)
        let checkpoint = retrievalID(810)
        let observation = try retrievalEvidence(id: retrievalID(40), subject: .artifact(artifact),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue,
            checkpointID: checkpoint)
        let sourceOnly = try (0..<8).map { index in
            try retrievalEvidence(id: retrievalID(41 + index), subject: .artifact(artifact),
                operationID: "reconstruction.source.oracle", checkpointID: checkpoint)
        }
        let records = [observation] + sourceOnly
        let cut = try retrievalCut(records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues:
                records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [checkpoint: 1])
        let query = try retrievalQuery(operations: [.corpusSummary], classifications: [.acceptedCurrent],
            maximumRecords: 4_096)
        let compiler = ReconstructionContextCompiler(
            maximumContextBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes)

        let bounded = try compiler.boundedQuery(cut: cut, query: query,
            allowedGapSubjects: [], allowedGapCategories: [])
        let packet = try ReconstructionRetrievalCompiler().compileSourceBase(cut: cut, query: bounded)
        let context = try compiler.compileSourceBase(cut: cut, query: query)
        XCTAssertEqual(packet.records.map(\.evidenceID), [observation.evidenceID])
        XCTAssertFalse(packet.hasMore)
        XCTAssertNil(packet.recordTooLarge)
        XCTAssertEqual(context.evidenceIDs, [observation.evidenceID])
        XCTAssertLessThanOrEqual(context.canonicalBytes.count,
            ReconstructionSourceContextCompiler.maximumBaseContextBytes)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: context.canonicalBytes) as? [String: Any])
        XCTAssertEqual(envelope["evidenceFrontierSHA256"] as? String, cut.frontierSHA256)
    }

    func testSourceBaseSelectsOrdinaryEvidenceWhileRetainingCompleteCutFence() throws {
        let artifact = try retrievalArtifact(occurrence: 1)
        let checkpoint = retrievalID(801)
        let ordinary = try retrievalEvidence(id: retrievalID(20), subject: .artifact(artifact),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue, checkpointID: checkpoint)
        // These rows exercise evidence selection only; they are not admitted source evidence.
        // Dedicated source-context tests separately validate the real canonical source payloads.
        let operations = ["reconstruction.source.oracle", "reconstruction.source.revision",
            "reconstruction.source.evaluate", "reconstruction.source.build", "reconstruction.source.behavior"]
        let source = try operations.enumerated().map { index, operation in
            try retrievalEvidence(id: retrievalID(30 + index), subject: .artifact(artifact),
                operationID: operation, checkpointID: checkpoint)
        }
        let records = [ordinary] + source
        let cut = try retrievalCut(records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [checkpoint: 1])
        let query = try retrievalQuery(operations: MacScopeAnalysisCore.ReconstructionOperationID.allCases,
            classifications: [.acceptedCurrent], maximumRecords: 1)
        let packet = try ReconstructionRetrievalCompiler().compileSourceBase(cut: cut, query: query)
        XCTAssertEqual(packet.records.map(\.evidenceID), [ordinary.evidenceID])
        XCTAssertFalse(packet.hasMore)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: packet.canonicalBytes) as? [String: Any])
        XCTAssertEqual(object["evidenceFrontierSHA256"] as? String, cut.frontierSHA256)
        let ordinaryCut = try retrievalCut(records: [ordinary],
            projectedClassifications: [ordinary.evidenceID: .acceptedCurrent], checkpointRevisions: [checkpoint: 1])
        XCTAssertNotEqual(ordinaryCut.frontierSHA256, cut.frontierSHA256)
        let ordinaryOnlyQuery = try retrievalQuery(operations: [.corpusSummary], classifications: [.acceptedCurrent])
        let ordinaryPacket = try ReconstructionRetrievalCompiler().compile(cut: cut, query: ordinaryOnlyQuery)
        XCTAssertEqual(ordinaryPacket.records.map(\.evidenceID), [ordinary.evidenceID])
        let context = try ReconstructionContextCompiler().compileSourceBase(cut: cut, query: query)
        XCTAssertEqual(context.evidenceIDs, [ordinary.evidenceID])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: context.canonicalBytes) as? [String: Any])
        XCTAssertEqual(envelope["evidenceFrontierSHA256"] as? String, cut.frontierSHA256)
    }

    func testSourceBasePreservesUnknownRejectionAndValidatesExcludedPayloads() throws {
        let artifact = try retrievalArtifact(occurrence: 1)
        let checkpoint = retrievalID(801)
        let query = try retrievalQuery(operations: [.corpusSummary], classifications: [.acceptedCurrent])
        let unknown = try retrievalEvidence(id: retrievalID(30), subject: .artifact(artifact),
            operationID: "reconstruction.source.unregistered", checkpointID: checkpoint)
        let unknownCut = try retrievalCut(records: [unknown],
            projectedClassifications: [unknown.evidenceID: .acceptedCurrent], checkpointRevisions: [checkpoint: 1])
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compileSourceBase(cut: unknownCut, query: query)) { error in
            XCTAssertEqual(error as? ReconstructionRetrievalError, .unknownOperation(unknown.operationID))
        }
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: unknownCut, query: query)) { error in
            XCTAssertEqual(error as? ReconstructionRetrievalError, .unknownOperation(unknown.operationID))
        }
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().orderedPositions(cut: unknownCut, query: query)) { error in
            XCTAssertEqual(error as? ReconstructionRetrievalError, .unknownOperation(unknown.operationID))
        }
        let corrupt = try retrievalEvidence(id: retrievalID(31), subject: .artifact(artifact),
            operationID: "reconstruction.source.oracle", checkpointID: checkpoint, payloadSHA256: retrievalDigest("0"))
        let corruptCut = try retrievalCut(records: [corrupt],
            projectedClassifications: [corrupt.evidenceID: .acceptedCurrent], checkpointRevisions: [checkpoint: 1])
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compileSourceBase(cut: corruptCut, query: query)) { error in
            XCTAssertEqual(error as? ReconstructionRetrievalError, .invalidProjectionInput)
        }
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: corruptCut, query: query)) { error in
            XCTAssertEqual(error as? ReconstructionRetrievalError, .invalidProjectionInput)
        }
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().orderedPositions(cut: corruptCut, query: query)) { error in
            XCTAssertEqual(error as? ReconstructionRetrievalError, .invalidProjectionInput)
        }
    }

    func testOrdinaryJobPagesWithinFocusAfterSiblingSourceJobPublishesOracleAndEvaluation() throws {
        let artifact = try retrievalArtifact(occurrence: 70)
        let siblingArtifact = try retrievalArtifact(occurrence: 71)
        let function = try retrievalFunction(artifact: artifact, start: 0x1000)
        let siblingFunction = try retrievalFunction(artifact: siblingArtifact, start: 0x1000)
        let ordinaryCheckpoint = retrievalID(850), sourceCheckpoint = retrievalID(851)
        let ordinaryJob = retrievalID(920), sourceJob = retrievalID(921)
        let first = try retrievalEvidence(id: retrievalID(90), subject: .function(function),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.functionReview.rawValue,
            checkpointID: ordinaryCheckpoint, jobID: ordinaryJob)
        let second = try retrievalEvidence(id: retrievalID(91), subject: .function(function),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.functionReview.rawValue,
            checkpointID: ordinaryCheckpoint, jobID: ordinaryJob)
        let outsideFocus = try retrievalEvidence(id: retrievalID(92), subject: .function(siblingFunction),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.functionReview.rawValue,
            checkpointID: sourceCheckpoint, jobID: sourceJob)
        // Selection fixtures do not claim source semantic admission. Include source rows both
        // inside and outside focus: neither may poison reads or acquire ordinary selection.
        let sourceRows = try ["reconstruction.source.oracle", "reconstruction.source.revision",
            "reconstruction.source.evaluate"].enumerated().map { index, operation in
            try retrievalEvidence(id: retrievalID(93 + index),
                subject: .function(index == 0 ? function : siblingFunction), operationID: operation,
                checkpointID: sourceCheckpoint, jobID: sourceJob)
        }
        let records = [second, outsideFocus] + sourceRows + [first]
        let cut = try retrievalCut(records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [ordinaryCheckpoint: 4, sourceCheckpoint: 3])
        let query = try retrievalQuery(operations: MacScopeAnalysisCore.ReconstructionOperationID.allCases,
            classifications: [.acceptedCurrent], maximumRecords: 1, focus: .artifact(artifact))
        let compiler = ReconstructionRetrievalCompiler()
        let page1 = try compiler.compile(cut: cut, query: query)
        let cursor = try XCTUnwrap(page1.nextCursor)
        let page2 = try compiler.compile(cut: cut, query: retrievalQuery(
            operations: query.operationIDs, classifications: query.classifications,
            cursor: cursor, maximumRecords: 1, focus: query.focus))
        XCTAssertEqual(page1.records.map(\.evidenceID), [first.evidenceID])
        XCTAssertEqual(page2.records.map(\.evidenceID), [second.evidenceID])
        XCTAssertTrue(page1.hasMore)
        XCTAssertFalse(page2.hasMore)
        XCTAssertNil(page2.nextCursor)
        XCTAssertEqual(cursor.evidenceFrontierSHA256, cut.frontierSHA256)
        XCTAssertEqual(try compiler.orderedPositions(cut: cut, query: query).map(\.evidenceID),
            [first.evidenceID, second.evidenceID])
        let context = try ReconstructionContextCompiler().compile(cut: cut, query: query,
            allowedGapSubjects: [], allowedGapCategories: [])
        XCTAssertEqual(context.evidenceIDs, [first.evidenceID])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: context.canonicalBytes) as? [String: Any])
        XCTAssertEqual(envelope["evidenceFrontierSHA256"] as? String, cut.frontierSHA256)
        let all = try compiler.compile(cut: cut, query: retrievalQuery(
            operations: query.operationIDs, classifications: query.classifications))
        XCTAssertEqual(Set(all.records.map(\.evidenceID)), Set([first.evidenceID, second.evidenceID, outsideFocus.evidenceID]))
    }

    func testArtifactFocusIncludesDescendantsAndExcludesOtherOccurrence() throws {
        let artifact = try retrievalArtifact(occurrence: 1)
        let otherArtifact = try retrievalArtifact(occurrence: 2)
        let function = try retrievalFunction(artifact: artifact, start: 0x1000)
        let checkpoint = retrievalID(801)
        let subjects: [ReconstructionSubjectCoordinate] = [
            .artifact(artifact), .image(try retrievalImage(artifact: artifact)),
            .function(function), .artifact(otherArtifact),
            .function(try retrievalFunction(artifact: otherArtifact, start: 0x1000)),
        ]
        let records = try subjects.enumerated().map { index, subject in
            try retrievalEvidence(id: retrievalID(20 + index), subject: subject,
                operationID: MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue,
                checkpointID: checkpoint)
        }
        let focusedGap = try retrievalGap(id: retrievalID(90), subject: .function(function),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.functionReview.rawValue)
        let foreignGap = try retrievalGap(id: retrievalID(91), subject: .artifact(otherArtifact),
            operationID: MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue)
        let cut = try retrievalCut(records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues:
                records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [checkpoint: 1], gaps: [focusedGap, foreignGap])
        let query = try retrievalQuery(operations: [.corpusSummary],
            classifications: [.acceptedCurrent], focus: .artifact(artifact))
        let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        XCTAssertEqual(Set(packet.records.map(\.evidenceID)), Set(records.prefix(3).map(\.evidenceID)))
        let exact = try retrievalQuery(subject: .function(function), operations: [.corpusSummary],
            classifications: [.acceptedCurrent], focus: .artifact(artifact))
        XCTAssertEqual(try ReconstructionRetrievalCompiler().compile(cut: cut, query: exact)
            .records.map(\.evidenceID), [records[2].evidenceID])
        let context = try ReconstructionContextCompiler().compile(cut: cut, query: query,
            allowedGapSubjects: [], allowedGapCategories: [])
        XCTAssertEqual(Set(context.evidenceIDs), Set(records.prefix(3).map(\.evidenceID)))
        XCTAssertEqual(context.allowedGapIDs, [focusedGap.gapID])
    }

    func testFunctionFocusIsExactAndHintsDoNotChangeFocusIdentity() throws {
        let artifact = try retrievalArtifact(occurrence: 1)
        let function = try retrievalFunction(artifact: artifact, start: 0x1000)
        let hinted = try retrievalFunction(artifact: artifact, start: 0x1000,
            functionUUIDHint: retrievalID(950), symbolHint: "renamed")
        let query = try retrievalQuery(operations: [.functionReview],
            classifications: [.acceptedCurrent], focus: .function(function))
        XCTAssertTrue(query.includes(subject: .function(hinted)))
        XCTAssertFalse(query.includes(subject: .artifact(artifact)))
        XCTAssertFalse(query.includes(subject: .image(try retrievalImage(artifact: artifact))))
        XCTAssertFalse(query.includes(subject: .function(
            try retrievalFunction(artifact: artifact, start: 0x2000))))
        let changedBoundary = try ReconstructionFunctionCoordinate(
            artifact: function.artifact, image: function.image,
            analysisFingerprintSHA256: function.analysisFingerprintSHA256,
            startAddress: function.startAddress, endAddressExclusive: function.endAddressExclusive + 4,
            boundarySchemaVersion: function.boundarySchemaVersion,
            functionUUIDHint: nil, symbolHint: nil)
        XCTAssertFalse(query.includes(subject: .function(changedBoundary)))
        let hintedQuery = try retrievalQuery(operations: [.functionReview],
            classifications: [.acceptedCurrent], focus: .function(hinted))
        XCTAssertEqual(try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(query),
            try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(hintedQuery))
        XCTAssertThrowsError(try retrievalQuery(operations: [.functionReview],
            classifications: [.acceptedCurrent], focus: .image(try retrievalImage(artifact: artifact))))
    }

    func testAbsentFocusPreservesLegacyCanonicalQueryAndIdentity() throws {
        struct LegacyQuery: Encodable {
            let corpusManifestSHA256: String
            let subject: ReconstructionDurableSubject?
            let operationIDs: [MacScopeAnalysisCore.ReconstructionOperationID]
            let classifications: [ReconstructionEvidenceClassification]
            let cursor: ReconstructionRetrievalCursor?
            let maximumRecords: Int
            let maximumEncodedBytes: Int
        }
        struct LegacyIdentity: Encodable {
            let schemaVersion = 1
            let domain = "reconstruction.evidence-retrieval-query.v1"
            let subject: ReconstructionDurableSubject?
            let operationIDs: [String]
            let classifications: [String]
        }
        let query = try retrievalQuery(operations: [.functionReview], classifications: [.acceptedCurrent])
        let legacy = LegacyQuery(corpusManifestSHA256: query.corpusManifestSHA256,
            subject: query.subject, operationIDs: query.operationIDs,
            classifications: query.classifications, cursor: query.cursor,
            maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
        let bytes = try ReconstructionCanonicalJSON.encode(legacy)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(query), bytes)
        XCTAssertEqual(try JSONDecoder().decode(ReconstructionRetrievalQuery.self, from: bytes), query)
        let identity = LegacyIdentity(subject: query.subject,
            operationIDs: query.operationIDs.map(\.rawValue),
            classifications: query.classifications.map(\.rawValue))
        XCTAssertEqual(try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(query),
            try ReconstructionCanonicalJSON.sha256(of: identity))
    }

    func testFocusBindsCursorAndSurvivesPaginationAndContextBudgetCopy() throws {
        let artifact = try retrievalArtifact(occurrence: 1)
        let checkpoint = retrievalID(801)
        let records = try (0..<3).map { index in
            try retrievalEvidence(id: retrievalID(20 + index),
                subject: .function(try retrievalFunction(artifact: artifact,
                    start: UInt64(0x1000 + index * 0x100))),
                operationID: MacScopeAnalysisCore.ReconstructionOperationID.functionReview.rawValue,
                checkpointID: checkpoint)
        }
        let cut = try retrievalCut(records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues:
                records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [checkpoint: 1])
        let query = try retrievalQuery(operations: [.functionReview], classifications: [.acceptedCurrent],
            maximumRecords: 1, focus: .artifact(artifact))
        let first = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(cursor.queryIdentitySHA256,
            try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(query))
        let resumed = try retrievalQuery(operations: [.functionReview], classifications: [.acceptedCurrent],
            cursor: cursor, maximumRecords: 1, focus: query.focus)
        let second = try ReconstructionRetrievalCompiler().compile(cut: cut, query: resumed)
        XCTAssertEqual(second.records.count, 1)
        XCTAssertNotEqual(first.records[0].evidenceID, second.records[0].evidenceID)
        let widened = try retrievalQuery(operations: [.functionReview], classifications: [.acceptedCurrent],
            cursor: cursor, maximumRecords: 1)
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: cut, query: widened)) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
        }
        let context = try ReconstructionContextCompiler().compile(cut: cut, query: resumed,
            allowedGapSubjects: [], allowedGapCategories: [])
        XCTAssertEqual(context.evidenceIDs, second.records.map(\.evidenceID))
    }

    func testEvidenceProjectorContinuationRetainsArtifactFocus() async throws {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: UUID())
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity)
        let checkpoint = retrievalID(801)
        let records = try (0..<2).map { index in
            try retrievalEvidence(id: retrievalID(20 + index), subject: .artifact(artifact),
                operationID: MacScopeAnalysisCore.ReconstructionOperationID.corpusSummary.rawValue,
                checkpointID: checkpoint)
        }
        let cut = try retrievalCut(corpusDigest: foundation.manifest.canonicalSHA256, records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues:
                records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [checkpoint: 1])
        let projectionDigest = try ReconstructionToolProjectorInput.canonicalProjectionFrontierSHA256(
            projectedItemsByOperation: [:], staleOperations: [], tasks: [], receipts: [],
            producersByOperation: [:], evidenceAuthorityCutsByOperation: [:])
        let authority = try ReconstructionToolAuthorityCut(jobID: foundation.job.jobID,
            checkpointRevision: 1, roundID: UUID(),
            corpusManifestSHA256: cut.corpusManifestSHA256, evidenceFrontierSHA256: cut.frontierSHA256,
            projectionFrontierSHA256: projectionDigest)
        let input = try ReconstructionToolProjectorInput(authority: authority,
            corpusManifest: foundation.manifest, evidenceCut: cut, tasks: [], receipts: [],
            producersByOperation: [:], projectedItemsByOperation: [:], staleOperations: [],
            evidenceAuthorityCutsByOperation: [:])
        let query = try retrievalQuery(corpusDigest: cut.corpusManifestSHA256,
            operations: [.corpusSummary], classifications: [.acceptedCurrent],
            maximumRecords: 1, focus: .artifact(artifact))
        let request = ReconstructionToolRequest(operationID: .evidenceQuery, taskID: UUID(),
            subject: nil, retrievalQuery: query, offset: 0,
            maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: authority, requests: [request]).first)
        let envelope = try ReconstructionToolRegistry().decodeCanonicalRequest(handle)
        let result = try await ReconstructionEvidenceToolProjector().project(request: envelope, input: input)
        XCTAssertEqual(result.outcome, .truncated)
        let continuation = try XCTUnwrap(result.continuationRequest)
        XCTAssertEqual(continuation.retrievalQuery?.focus, query.focus)
        XCTAssertNil(continuation.subject)
        let nextHandle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: authority, requests: [continuation]).first)
        let nextEnvelope = try ReconstructionToolRegistry().decodeCanonicalRequest(nextHandle)
        let next = try await ReconstructionEvidenceToolProjector().project(request: nextEnvelope, input: input)
        XCTAssertEqual(next.outcome, .success)
        XCTAssertEqual(next.itemCount, 1)
    }

    func testOrderingUsesEveryFrozenOrderingKeyInSequence() throws {
        let artifactA = try retrievalArtifact(occurrence: 1)
        let artifactB = try retrievalArtifact(occurrence: 2)
        let imageA = try retrievalImage(artifact: artifactA)
        let functionA = try retrievalFunction(artifact: artifactA, start: 0x1000)
        let functionB = try retrievalFunction(artifact: artifactB, start: 0x1000)
        let checkpointRevision1 = retrievalID(801)
        let checkpointRevision2 = retrievalID(802)
        let lowPriority = retrievalOperation("reconstruction.corpus.summary")
        let highPriority = retrievalOperation("reconstruction.evidence.get")

        let currentFunctionRevision2UUID4 = try retrievalEvidence(
            id: retrievalID(4),
            subject: .function(functionA),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision2
        )
        let currentFunctionRevision2UUID5 = try retrievalEvidence(
            id: retrievalID(5),
            subject: .function(functionA),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision2
        )
        let currentFunctionRevision1 = try retrievalEvidence(
            id: retrievalID(3),
            subject: .function(functionA),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision1
        )
        let currentFunctionCanonicalB = try retrievalEvidence(
            id: retrievalID(6),
            subject: .function(functionB),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision2
        )
        let currentFunctionHigherOperation = try retrievalEvidence(
            id: retrievalID(7),
            subject: .function(functionA),
            operationID: highPriority.rawValue,
            checkpointID: checkpointRevision2
        )
        let currentImage = try retrievalEvidence(
            id: retrievalID(8),
            subject: .image(imageA),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision2
        )
        let currentArtifact = try retrievalEvidence(
            id: retrievalID(9),
            subject: .artifact(artifactA),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision2
        )
        let historicalFunction = try retrievalEvidence(
            id: retrievalID(1),
            subject: .function(functionA),
            operationID: lowPriority.rawValue,
            checkpointID: checkpointRevision2,
            classification: .acceptedHistorical
        )
        let records = [
            historicalFunction,
            currentArtifact,
            currentImage,
            currentFunctionHigherOperation,
            currentFunctionCanonicalB,
            currentFunctionRevision1,
            currentFunctionRevision2UUID5,
            currentFunctionRevision2UUID4,
        ]
        let cut = try retrievalCut(
            records: records,
            projectedClassifications: [
                historicalFunction.evidenceID: .acceptedHistorical,
                currentArtifact.evidenceID: .acceptedCurrent,
                currentImage.evidenceID: .acceptedCurrent,
                currentFunctionHigherOperation.evidenceID: .acceptedCurrent,
                currentFunctionCanonicalB.evidenceID: .acceptedCurrent,
                currentFunctionRevision1.evidenceID: .acceptedCurrent,
                currentFunctionRevision2UUID5.evidenceID: .acceptedCurrent,
                currentFunctionRevision2UUID4.evidenceID: .acceptedCurrent,
            ],
            checkpointRevisions: [
                checkpointRevision1: 1,
                checkpointRevision2: 2,
            ]
        )
        let query = try retrievalQuery(
            operations: [lowPriority, highPriority],
            classifications: [.acceptedCurrent, .acceptedHistorical]
        )

        let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)

        XCTAssertEqual(
            packet.records.map(\.evidenceID),
            [
                retrievalID(4),
                retrievalID(5),
                retrievalID(3),
                retrievalID(6),
                retrievalID(7),
                retrievalID(8),
                retrievalID(9),
                retrievalID(1),
            ]
        )
    }

    func testFunctionHintsDoNotOverrideEvidenceUUIDTieBreaker() throws {
        let artifact = try retrievalArtifact(occurrence: 4_001)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(8_001)
        let lowerUUID = try retrievalEvidence(
            id: retrievalID(12_001),
            subject: .function(try retrievalFunction(
                artifact: artifact,
                start: 0x1000,
                functionUUIDHint: retrievalID(12_102),
                symbolHint: "z_last"
            )),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let higherUUID = try retrievalEvidence(
            id: retrievalID(12_002),
            subject: .function(try retrievalFunction(
                artifact: artifact,
                start: 0x1000,
                functionUUIDHint: retrievalID(12_101),
                symbolHint: "a_first"
            )),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let records = [higherUUID, lowerUUID]

        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: try retrievalCut(
                records: records,
                projectedClassifications: Dictionary(uniqueKeysWithValues: records.map {
                    ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
                }),
                checkpointRevisions: [checkpoint: 4]
            ),
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent]
            )
        )

        XCTAssertEqual(
            packet.records.map(\.evidenceID),
            [lowerUUID.evidenceID, higherUUID.evidenceID]
        )
    }

    func testFunctionHintsDoNotChangeQueryPacketIdentityOrCursorResume() throws {
        let artifact = try retrievalArtifact(occurrence: 4_002)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(8_002)
        let originalSubject = try retrievalFunction(
            artifact: artifact,
            start: 0x2000,
            functionUUIDHint: retrievalID(12_201),
            symbolHint: "_original"
        )
        let renamedSubject = try retrievalFunction(
            artifact: artifact,
            start: 0x2000,
            functionUUIDHint: retrievalID(12_202),
            symbolHint: "_renamed"
        )
        XCTAssertEqual(originalSubject, renamedSubject)

        let records = try [12_011, 12_012].map { evidenceID in
            try retrievalEvidence(
                id: retrievalID(evidenceID),
                subject: .function(originalSubject),
                operationID: operation.rawValue,
                checkpointID: checkpoint
            )
        }
        let cut = try retrievalCut(
            records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map {
                ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
            }),
            checkpointRevisions: [checkpoint: 5]
        )
        let compiler = ReconstructionRetrievalCompiler()
        let originalPage = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                subject: .function(originalSubject),
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 1
            )
        )
        let renamedPage = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                subject: .function(renamedSubject),
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 1
            )
        )

        XCTAssertEqual(originalPage.canonicalBytes, renamedPage.canonicalBytes)
        XCTAssertEqual(originalPage.canonicalSHA256, renamedPage.canonicalSHA256)
        let resumed = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                subject: .function(renamedSubject),
                operations: [operation],
                classifications: [.acceptedCurrent],
                cursor: try XCTUnwrap(originalPage.nextCursor),
                maximumRecords: 1
            )
        )
        XCTAssertEqual(resumed.records.map(\.evidenceID), [records[1].evidenceID])
    }

    func testFunctionHintsDoNotChangeCursorStructuralSubjectHash() throws {
        let artifact = try retrievalArtifact(occurrence: 4_003)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(8_003)
        let originalSubject = try retrievalFunction(
            artifact: artifact,
            start: 0x3000,
            functionUUIDHint: retrievalID(12_301),
            symbolHint: "_original"
        )
        let renamedSubject = try retrievalFunction(
            artifact: artifact,
            start: 0x3000,
            functionUUIDHint: retrievalID(12_302),
            symbolHint: "_renamed"
        )

        func firstCursor(for subject: ReconstructionFunctionCoordinate) throws
            -> ReconstructionRetrievalCursor {
            let records = try [12_021, 12_022].map { evidenceID in
                try retrievalEvidence(
                    id: retrievalID(evidenceID),
                    subject: .function(subject),
                    operationID: operation.rawValue,
                    checkpointID: checkpoint
                )
            }
            let packet = try ReconstructionRetrievalCompiler().compile(
                cut: try retrievalCut(
                    records: records,
                    projectedClassifications: Dictionary(uniqueKeysWithValues: records.map {
                        ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
                    }),
                    checkpointRevisions: [checkpoint: 6]
                ),
                query: try retrievalQuery(
                    operations: [operation],
                    classifications: [.acceptedCurrent],
                    maximumRecords: 1
                )
            )
            return try XCTUnwrap(packet.nextCursor)
        }

        XCTAssertEqual(
            try firstCursor(for: originalSubject).canonicalSubjectIdentity,
            try firstCursor(for: renamedSubject).canonicalSubjectIdentity
        )
    }

    func testQueryFiltersExactSubjectOperationAndClassification() throws {
        let artifact = try retrievalArtifact(occurrence: 10)
        let function = try retrievalFunction(artifact: artifact, start: 0x1000)
        let otherFunction = try retrievalFunction(artifact: artifact, start: 0x2000)
        let review = retrievalOperation("reconstruction.function.review")
        let compare = retrievalOperation("reconstruction.decompiler.compare")
        let checkpoint = retrievalID(820)
        let matching = try retrievalEvidence(
            id: retrievalID(21),
            subject: .function(function),
            operationID: review.rawValue,
            checkpointID: checkpoint
        )
        let wrongSubject = try retrievalEvidence(
            id: retrievalID(22),
            subject: .function(otherFunction),
            operationID: review.rawValue,
            checkpointID: checkpoint
        )
        let wrongOperation = try retrievalEvidence(
            id: retrievalID(23),
            subject: .function(function),
            operationID: compare.rawValue,
            checkpointID: checkpoint
        )
        let wrongClassification = try retrievalEvidence(
            id: retrievalID(24),
            subject: .function(function),
            operationID: review.rawValue,
            checkpointID: checkpoint,
            classification: .acceptedHistorical
        )
        let cut = try retrievalCut(
            records: [wrongClassification, wrongOperation, wrongSubject, matching],
            projectedClassifications: [
                matching.evidenceID: .acceptedCurrent,
                wrongSubject.evidenceID: .acceptedCurrent,
                wrongOperation.evidenceID: .acceptedCurrent,
                wrongClassification.evidenceID: .acceptedHistorical,
            ],
            checkpointRevisions: [checkpoint: 7]
        )
        let query = try retrievalQuery(
            subject: .function(function),
            operations: [review],
            classifications: [.acceptedCurrent]
        )

        let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)

        XCTAssertEqual(packet.records.map(\.evidenceID), [retrievalID(21)])
        XCTAssertFalse(packet.hasMore)
        XCTAssertNil(packet.nextCursor)
    }

    func testPaginationResumesWithoutDuplicatesOrSkipsAcrossInputReordering() throws {
        let artifact = try retrievalArtifact(occurrence: 20)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(830)
        let first = try retrievalEvidence(
            id: retrievalID(31),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let second = try retrievalEvidence(
            id: retrievalID(32),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let third = try retrievalEvidence(
            id: retrievalID(33),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let classifications: [UUID: ReconstructionEvidenceClassification] = [
            first.evidenceID: .acceptedCurrent,
            second.evidenceID: .acceptedCurrent,
            third.evidenceID: .acceptedCurrent,
        ]
        let revisions = [checkpoint: UInt64(9)]
        let firstCut = try retrievalCut(
            records: [third, first, second],
            projectedClassifications: classifications,
            checkpointRevisions: revisions
        )
        let firstQuery = try retrievalQuery(
            operations: [operation],
            classifications: [.acceptedCurrent],
            maximumRecords: 1
        )
        let compiler = ReconstructionRetrievalCompiler()

        let page1 = try compiler.compile(cut: firstCut, query: firstQuery)
        let cursor1 = try XCTUnwrap(page1.nextCursor)
        let reorderedCut = try retrievalCut(
            records: [second, third, first],
            projectedClassifications: classifications,
            checkpointRevisions: revisions
        )
        let page2 = try compiler.compile(
            cut: reorderedCut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                cursor: cursor1,
                maximumRecords: 1
            )
        )
        let cursor2 = try XCTUnwrap(page2.nextCursor)
        let page3 = try compiler.compile(
            cut: firstCut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                cursor: cursor2,
                maximumRecords: 1
            )
        )

        XCTAssertEqual(page1.records.map(\.evidenceID), [retrievalID(31)])
        XCTAssertEqual(page2.records.map(\.evidenceID), [retrievalID(32)])
        XCTAssertEqual(page3.records.map(\.evidenceID), [retrievalID(33)])
        XCTAssertEqual(
            Set((page1.records + page2.records + page3.records).map(\.evidenceID)).count,
            3
        )
        XCTAssertFalse(page3.hasMore)
        XCTAssertNil(page3.nextCursor)
    }

    func testCursorFencesCorpusDigestAndQueryFilterIdentity() throws {
        let artifact = try retrievalArtifact(occurrence: 30)
        let review = retrievalOperation("reconstruction.function.review")
        let compare = retrievalOperation("reconstruction.decompiler.compare")
        let checkpoint = retrievalID(840)
        let records = [
            try retrievalEvidence(
                id: retrievalID(41),
                subject: .artifact(artifact),
                operationID: review.rawValue,
                checkpointID: checkpoint
            ),
            try retrievalEvidence(
                id: retrievalID(42),
                subject: .artifact(artifact),
                operationID: review.rawValue,
                checkpointID: checkpoint
            ),
        ]
        let classifications: [UUID: ReconstructionEvidenceClassification] = Dictionary(
            uniqueKeysWithValues: records.map { ($0.evidenceID, .acceptedCurrent) }
        )
        let cut = try retrievalCut(
            records: records,
            projectedClassifications: classifications,
            checkpointRevisions: [checkpoint: 4]
        )
        let compiler = ReconstructionRetrievalCompiler()
        let page = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [review],
                classifications: [.acceptedCurrent],
                maximumRecords: 1
            )
        )
        let cursor = try XCTUnwrap(page.nextCursor)

        XCTAssertThrowsError(
            try compiler.compile(
                cut: cut,
                query: try retrievalQuery(
                    operations: [compare],
                    classifications: [.acceptedCurrent],
                    cursor: cursor,
                    maximumRecords: 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionRetrievalError,
                ReconstructionRetrievalError.cursorFenceMismatch
            )
        }

        let replacementCorpusCut = try retrievalCut(
            corpusDigest: retrievalDigest("b"),
            records: records,
            projectedClassifications: classifications,
            checkpointRevisions: [checkpoint: 4]
        )
        XCTAssertThrowsError(
            try compiler.compile(
                cut: replacementCorpusCut,
                query: try retrievalQuery(
                    corpusDigest: retrievalDigest("b"),
                    operations: [review],
                    classifications: [.acceptedCurrent],
                    cursor: cursor,
                    maximumRecords: 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionRetrievalError,
                ReconstructionRetrievalError.cursorFenceMismatch
            )
        }
    }

    func testCursorRejectsForgedEvidenceIDOrOrderingKeyInsideValidFences() throws {
        let artifact = try retrievalArtifact(occurrence: 31)
        let operation = retrievalOperation("reconstruction.function.review")
        let checkpoint = retrievalID(841)
        let first = try retrievalEvidence(
            id: retrievalID(43),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let second = try retrievalEvidence(
            id: retrievalID(44),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let cut = try retrievalCut(
            records: [second, first],
            projectedClassifications: [
                first.evidenceID: .acceptedCurrent,
                second.evidenceID: .acceptedCurrent,
            ],
            checkpointRevisions: [checkpoint: 4]
        )
        let compiler = ReconstructionRetrievalCompiler()
        let firstPage = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 1
            )
        )
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let forgedEvidenceID = ReconstructionRetrievalCursor(
            schemaVersion: cursor.schemaVersion,
            corpusManifestSHA256: cursor.corpusManifestSHA256,
            evidenceFrontierSHA256: cursor.evidenceFrontierSHA256,
            queryIdentitySHA256: cursor.queryIdentitySHA256,
            currentBucket: cursor.currentBucket,
            subjectSpecificity: cursor.subjectSpecificity,
            operationPriority: cursor.operationPriority,
            canonicalSubjectIdentity: cursor.canonicalSubjectIdentity,
            checkpointRevision: cursor.checkpointRevision,
            evidenceID: retrievalID(999_999)
        )
        let forgedRevision = ReconstructionRetrievalCursor(
            schemaVersion: cursor.schemaVersion,
            corpusManifestSHA256: cursor.corpusManifestSHA256,
            evidenceFrontierSHA256: cursor.evidenceFrontierSHA256,
            queryIdentitySHA256: cursor.queryIdentitySHA256,
            currentBucket: cursor.currentBucket,
            subjectSpecificity: cursor.subjectSpecificity,
            operationPriority: cursor.operationPriority,
            canonicalSubjectIdentity: cursor.canonicalSubjectIdentity,
            checkpointRevision: cursor.checkpointRevision + 1,
            evidenceID: cursor.evidenceID
        )

        for forgedCursor in [forgedEvidenceID, forgedRevision] {
            XCTAssertThrowsError(
                try compiler.compile(
                    cut: cut,
                    query: try retrievalQuery(
                        operations: [operation],
                        classifications: [.acceptedCurrent],
                        cursor: forgedCursor,
                        maximumRecords: 1
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionRetrievalError,
                    ReconstructionRetrievalError.cursorFenceMismatch
                )
            }
        }
    }

    func testQueryAcceptsPackageCeilingsAndRejectsUnboundedBudgets() throws {
        let operation = retrievalOperation("reconstruction.evidence.query")

        XCTAssertNoThrow(
            try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 100_000,
                maximumEncodedBytes: 64 * 1_024 * 1_024
            )
        )

        for excessiveRecordCount in [100_001, Int.max] {
            XCTAssertThrowsError(
                try retrievalQuery(
                    operations: [operation],
                    classifications: [.acceptedCurrent],
                    maximumRecords: excessiveRecordCount,
                    maximumEncodedBytes: 1_000_000
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionRetrievalError,
                    ReconstructionRetrievalError.invalidQuery
                )
            }
        }

        for excessiveByteCount in [64 * 1_024 * 1_024 + 1, Int.max] {
            XCTAssertThrowsError(
                try retrievalQuery(
                    operations: [operation],
                    classifications: [.acceptedCurrent],
                    maximumRecords: 100,
                    maximumEncodedBytes: excessiveByteCount
                )
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionRetrievalError,
                    ReconstructionRetrievalError.invalidQuery
                )
            }
        }
    }

    func testDecodedQueryCannotBypassBudgetOrFilterValidation() throws {
        let operation = retrievalOperation("reconstruction.evidence.query")
        let valid = try retrievalQuery(
            operations: [operation],
            classifications: [.acceptedCurrent]
        )
        let encoded = try JSONEncoder().encode(valid)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let hostileMutations: [(String, (inout [String: Any]) -> Void)] = [
            ("negative record budget", { $0["maximumRecords"] = -1 }),
            ("oversized byte budget", {
                $0["maximumEncodedBytes"] = 64 * 1_024 * 1_024 + 1
            }),
            ("duplicate operation filter", {
                $0["operationIDs"] = [operation.rawValue, operation.rawValue]
            }),
            ("duplicate classification filter", {
                $0["classifications"] = [
                    ReconstructionEvidenceClassification.acceptedCurrent.rawValue,
                    ReconstructionEvidenceClassification.acceptedCurrent.rawValue,
                ]
            }),
        ]

        for (name, mutate) in hostileMutations {
            var hostile = object
            mutate(&hostile)
            let data = try JSONSerialization.data(withJSONObject: hostile)
            XCTAssertThrowsError(
                try JSONDecoder().decode(ReconstructionRetrievalQuery.self, from: data),
                name
            ) {
                XCTAssertEqual($0 as? ReconstructionRetrievalError, .invalidQuery, name)
            }
        }
    }

    func testDecodedProjectionInputRevalidatesFrontierMapsAndCanonicalRecordOrder() throws {
        let artifact = try retrievalArtifact(occurrence: 35)
        let operation = retrievalOperation("reconstruction.evidence.query")
        let checkpoint = retrievalID(845)
        let first = try retrievalEvidence(
            id: retrievalID(45),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let second = try retrievalEvidence(
            id: retrievalID(46),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let cut = try retrievalCut(
            records: [second, first],
            projectedClassifications: [
                first.evidenceID: .acceptedCurrent,
                second.evidenceID: .acceptedCurrent,
            ],
            checkpointRevisions: [checkpoint: 8]
        )
        let input = try ReconstructionRetrievalProjectionInput(cut: cut)
        let encoded = try JSONEncoder().encode(input)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        let reorderedRecords = try XCTUnwrap(object["records"] as? [[String: Any]]).reversed()
        object["records"] = Array(reorderedRecords)
        let reorderedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            ReconstructionRetrievalProjectionInput.self,
            from: reorderedData
        )
        XCTAssertEqual(decoded.records.map(\.evidenceID), [first.evidenceID, second.evidenceID])

        var duplicateRecords = object
        let records = try XCTUnwrap(duplicateRecords["records"] as? [[String: Any]])
        duplicateRecords["records"] = [records[0], records[0]]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReconstructionRetrievalProjectionInput.self,
                from: JSONSerialization.data(withJSONObject: duplicateRecords)
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .invalidProjectionInput)
        }

        var incompleteCheckpointMap = object
        incompleteCheckpointMap["checkpointRevisionsByID"] = []
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReconstructionRetrievalProjectionInput.self,
                from: JSONSerialization.data(withJSONObject: incompleteCheckpointMap)
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .invalidProjectionInput)
        }

        var forgedFrontier = object
        forgedFrontier["evidenceFrontierSHA256"] = retrievalDigest("0")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ReconstructionRetrievalProjectionInput.self,
                from: JSONSerialization.data(withJSONObject: forgedFrontier)
            )
        ) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .invalidProjectionInput)
        }
    }

    func testDecodedProjectionInputRejectsPayloadIntegrityMismatch() throws {
        let artifact = try retrievalArtifact(occurrence: 37)
        let operation = retrievalOperation("reconstruction.evidence.query")
        let checkpoint = retrievalID(849)
        let record = try retrievalEvidence(
            id: retrievalID(50),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let cut = try retrievalCut(
            records: [record],
            projectedClassifications: [record.evidenceID: .acceptedCurrent],
            checkpointRevisions: [checkpoint: 8]
        )
        let input = try ReconstructionRetrievalProjectionInput(cut: cut)
        let encoded = try JSONEncoder().encode(input)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let hostileMutations: [(String, (inout [String: Any]) -> Void)] = [
            ("payload byte count", { $0["payloadByteCount"] = 999_999 }),
            ("payload digest", { $0["payloadSHA256"] = retrievalDigest("0") }),
            ("payload bytes", { $0["payload"] = Data("forged payload".utf8).base64EncodedString() }),
        ]

        for (name, mutateRecord) in hostileMutations {
            var hostile = object
            var records = try XCTUnwrap(hostile["records"] as? [[String: Any]])
            mutateRecord(&records[0])
            hostile["records"] = records
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ReconstructionRetrievalProjectionInput.self,
                    from: JSONSerialization.data(withJSONObject: hostile)
                ),
                name
            ) {
                XCTAssertEqual($0 as? ReconstructionRetrievalError, .invalidProjectionInput)
            }
        }
    }

    func testDecodedProjectionInputRejectsForgedRelationEndpointsWithCanonicalFrontier() throws {
        let artifact = try retrievalArtifact(occurrence: 4_010)
        let operation = retrievalOperation("reconstruction.evidence.query")
        let checkpoint = retrievalID(8_010)
        let record = try retrievalEvidence(
            id: retrievalID(12_401),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let gap = try retrievalGap(
            id: retrievalID(12_402),
            subject: record.subject,
            operationID: operation.rawValue
        )
        let cases: [(String, [ReconstructionEvidenceRelation], [ReconstructionEvidenceGap])] = [
            (
                "missing evidence endpoint",
                [ReconstructionEvidenceRelation(
                    relationID: retrievalID(12_403),
                    kind: .derivedFrom,
                    sourceEvidenceID: record.evidenceID,
                    targetEvidenceID: retrievalID(12_499)
                )],
                []
            ),
            (
                "missing gap endpoint",
                [ReconstructionEvidenceRelation(
                    relationID: retrievalID(12_404),
                    kind: .resolvesGap,
                    sourceEvidenceID: record.evidenceID,
                    targetEvidenceID: retrievalID(12_498)
                )],
                [gap]
            ),
        ]

        for (name, relations, gaps) in cases {
            let projected = [
                record.evidenceID: ReconstructionEvidenceClassification.acceptedCurrent,
            ]
            let revisions = [checkpoint: UInt64(7)]
            let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: retrievalDigest("a"),
                records: [record],
                projectedClassificationsByEvidenceID: projected,
                relations: relations,
                gaps: gaps,
                checkpointRevisionsByID: revisions
            )
            let encoded = try JSONEncoder().encode(RetrievalProjectionInputEnvelope(
                corpusManifestSHA256: retrievalDigest("a"),
                evidenceFrontierSHA256: frontier,
                records: [record],
                projectedClassificationsByEvidenceID: projected,
                checkpointRevisionsByID: revisions,
                relations: relations,
                gaps: gaps
            ))

            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ReconstructionRetrievalProjectionInput.self,
                    from: encoded
                ),
                name
            ) {
                XCTAssertEqual($0 as? ReconstructionRetrievalError, .invalidProjectionInput, name)
            }
        }
    }

    func testCursorFenceRejectsEveryChangedEvidenceFrontierComponent() throws {
        let artifact = try retrievalArtifact(occurrence: 36)
        let operation = retrievalOperation("reconstruction.evidence.query")
        let checkpoint = retrievalID(846)
        let first = try retrievalEvidence(
            id: retrievalID(47),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let second = try retrievalEvidence(
            id: retrievalID(48),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let classifications: [UUID: ReconstructionEvidenceClassification] = [
            first.evidenceID: .acceptedCurrent,
            second.evidenceID: .acceptedCurrent,
        ]
        let baseCut = try retrievalCut(
            records: [first, second],
            projectedClassifications: classifications,
            checkpointRevisions: [checkpoint: 8]
        )
        let compiler = ReconstructionRetrievalCompiler()
        let page = try compiler.compile(
            cut: baseCut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent, .acceptedHistorical],
                maximumRecords: 1
            )
        )
        let cursor = try XCTUnwrap(page.nextCursor)
        let changedIdentity = try retrievalEvidence(
            id: retrievalID(49),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let changedPayloadDigest = try retrievalEvidence(
            id: second.evidenceID,
            subject: second.subject,
            operationID: operation.rawValue,
            checkpointID: checkpoint,
            payload: Data("changed retrieval evidence".utf8)
        )
        let changedTerminalClassification = try retrievalEvidence(
            id: second.evidenceID,
            subject: second.subject,
            operationID: operation.rawValue,
            checkpointID: checkpoint,
            classification: .acceptedHistorical
        )
        let relation = ReconstructionEvidenceRelation(
            relationID: retrievalID(847),
            kind: .supports,
            sourceEvidenceID: first.evidenceID,
            targetEvidenceID: second.evidenceID
        )
        let gap = try retrievalGap(
            id: retrievalID(848),
            subject: .artifact(artifact),
            operationID: operation.rawValue
        )
        let changedCuts: [(String, ReconstructionEvidenceCut)] = [
            ("record identity", try retrievalCut(
                records: [first, changedIdentity],
                projectedClassifications: [
                    first.evidenceID: .acceptedCurrent,
                    changedIdentity.evidenceID: .acceptedCurrent,
                ],
                checkpointRevisions: [checkpoint: 8]
            )),
            ("record digest", try retrievalCut(
                records: [first, changedPayloadDigest],
                projectedClassifications: classifications,
                checkpointRevisions: [checkpoint: 8]
            )),
            ("terminal classification", try retrievalCut(
                records: [first, changedTerminalClassification],
                projectedClassifications: classifications,
                checkpointRevisions: [checkpoint: 8]
            )),
            ("projected classification", try retrievalCut(
                records: [first, second],
                projectedClassifications: [
                    first.evidenceID: .acceptedCurrent,
                    second.evidenceID: .acceptedHistorical,
                ],
                checkpointRevisions: [checkpoint: 8]
            )),
            ("relation", try retrievalCut(
                records: [first, second],
                projectedClassifications: classifications,
                checkpointRevisions: [checkpoint: 8],
                relations: [relation]
            )),
            ("gap", try retrievalCut(
                records: [first, second],
                projectedClassifications: classifications,
                checkpointRevisions: [checkpoint: 8],
                gaps: [gap]
            )),
            ("checkpoint revision", try retrievalCut(
                records: [first, second],
                projectedClassifications: classifications,
                checkpointRevisions: [checkpoint: 9]
            )),
        ]

        for (name, changedCut) in changedCuts {
            XCTAssertNotEqual(baseCut.frontierSHA256, changedCut.frontierSHA256, name)
            XCTAssertThrowsError(
                try compiler.compile(
                    cut: changedCut,
                    query: try retrievalQuery(
                        operations: [operation],
                        classifications: [.acceptedCurrent, .acceptedHistorical],
                        cursor: cursor,
                        maximumRecords: 1
                    )
                ),
                name
            ) {
                XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch, name)
            }
        }
    }

    func testSameCutAndQueryProduceByteIdenticalCanonicalPacketAndDigest() throws {
        let artifact = try retrievalArtifact(occurrence: 40)
        let operation = retrievalOperation("reconstruction.corpus.artifact.describe")
        let checkpoint = retrievalID(850)
        let first = try retrievalEvidence(
            id: retrievalID(51),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let second = try retrievalEvidence(
            id: retrievalID(52),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let classifications: [UUID: ReconstructionEvidenceClassification] = [
            first.evidenceID: .acceptedCurrent,
            second.evidenceID: .acceptedCurrent,
        ]
        let revisions = [checkpoint: UInt64(12)]
        let query = try retrievalQuery(
            operations: [operation],
            classifications: [.acceptedCurrent]
        )
        let compiler = ReconstructionRetrievalCompiler()

        let forward = try compiler.compile(
            cut: try retrievalCut(
                records: [first, second],
                projectedClassifications: classifications,
                checkpointRevisions: revisions
            ),
            query: query
        )
        let reversed = try compiler.compile(
            cut: try retrievalCut(
                records: [second, first],
                projectedClassifications: classifications,
                checkpointRevisions: revisions
            ),
            query: query
        )

        XCTAssertEqual(forward.records.map(\.evidenceID), [retrievalID(51), retrievalID(52)])
        XCTAssertEqual(forward.canonicalBytes, reversed.canonicalBytes)
        XCTAssertEqual(forward.canonicalSHA256, reversed.canonicalSHA256)
        XCTAssertEqual(forward.encodedByteCount, forward.canonicalBytes.count)
        XCTAssertEqual(forward.canonicalSHA256, retrievalSHA256(forward.canonicalBytes))
    }

    func testRecordBudgetStopsAtWholeRecordAndReturnsResumeCursor() throws {
        let artifact = try retrievalArtifact(occurrence: 50)
        let operation = retrievalOperation("reconstruction.evidence.query")
        let checkpoint = retrievalID(860)
        let first = try retrievalEvidence(
            id: retrievalID(61),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let second = try retrievalEvidence(
            id: retrievalID(62),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let cut = try retrievalCut(
            records: [second, first],
            projectedClassifications: [
                first.evidenceID: .acceptedCurrent,
                second.evidenceID: .acceptedCurrent,
            ],
            checkpointRevisions: [checkpoint: 3]
        )

        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 1,
                maximumEncodedBytes: 1_000_000
            )
        )

        XCTAssertEqual(packet.records.map(\.evidenceID), [retrievalID(61)])
        XCTAssertTrue(packet.hasMore)
        XCTAssertNotNil(packet.nextCursor)
    }

    func testByteBudgetNeverPartiallyEmitsIdentityBearingRecord() throws {
        let artifact = try retrievalArtifact(occurrence: 60)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(870)
        let small = try retrievalEvidence(
            id: retrievalID(71),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint,
            payload: Data("small".utf8)
        )
        let oversized = try retrievalEvidence(
            id: retrievalID(72),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint,
            payload: Data(repeating: 0x61, count: 8_192)
        )
        let cut = try retrievalCut(
            records: [oversized, small],
            projectedClassifications: [
                small.evidenceID: .acceptedCurrent,
                oversized.evidenceID: .acceptedCurrent,
            ],
            checkpointRevisions: [checkpoint: 5]
        )

        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 10,
                maximumEncodedBytes: 4_096
            )
        )

        XCTAssertEqual(packet.records.map(\.evidenceID), [retrievalID(71)])
        XCTAssertEqual(packet.records.first?.payload, Data("small".utf8))
        XCTAssertLessThanOrEqual(packet.encodedByteCount, 4_096)
        XCTAssertTrue(packet.hasMore)
        XCTAssertNotNil(packet.nextCursor)
    }

    /// T27 matrix-0351 extra-query defect. Root cause: a first page held one record plus a
    /// continuation and the next record alone exceeded the page cap (retained DB: 9C4666A8 6,947 B
    /// delivered, BFD581EB 9,859 B next, fixed-source cap 8,192 B), so every continuation threw
    /// `recordExceedsByteBudget` and paging could not progress. Lead ruling: such a record travels
    /// alone on a page flagged `oversizePage` up to 64 KiB; above that the page carries a typed
    /// `recordTooLarge` marker (id, size) and no records. Never skipped silently, never truncated,
    /// and the continuation always moves past the record.
    func testContinuationPastOversizedRecordMakesProgressMatrix0351() throws {
        let artifact = try retrievalArtifact(occurrence: 61)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(871)
        let small = try retrievalEvidence(id: retrievalID(81), subject: .artifact(artifact),
            operationID: operation.rawValue, checkpointID: checkpoint, payload: Data("small".utf8))
        let oversized = try retrievalEvidence(id: retrievalID(82), subject: .artifact(artifact),
            operationID: operation.rawValue, checkpointID: checkpoint, payload: Data(repeating: 0x61, count: 8_192))
        let huge = try retrievalEvidence(id: retrievalID(83), subject: .artifact(artifact),
            operationID: operation.rawValue, checkpointID: checkpoint, payload: Data(repeating: 0x62, count: 70_000))
        let tail = try retrievalEvidence(id: retrievalID(84), subject: .artifact(artifact),
            operationID: operation.rawValue, checkpointID: checkpoint, payload: Data("tail".utf8))
        let records = [oversized, small, huge, tail]
        let cut = try retrievalCut(records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map { ($0.evidenceID, .acceptedCurrent) }),
            checkpointRevisions: [checkpoint: 5])
        func page(_ cursor: ReconstructionRetrievalCursor?) throws -> ReconstructionRetrievalPacket {
            try ReconstructionRetrievalCompiler().compile(cut: cut, query: try retrievalQuery(
                operations: [operation], classifications: [.acceptedCurrent], cursor: cursor,
                maximumRecords: 8, maximumEncodedBytes: 4_096))
        }
        // Walk the whole chain; it must terminate and deliver or mark every record exactly once.
        var cursor: ReconstructionRetrievalCursor?
        var delivered: [UUID] = [], oversizePages: [UUID] = [], markers: [ReconstructionRetrievalRecordTooLarge] = []
        for _ in 0..<records.count + 1 {
            let packet = try page(cursor)
            delivered += packet.records.map(\.evidenceID)
            if packet.oversizePage {
                XCTAssertEqual(packet.records.count, 1)
                XCTAssertGreaterThan(packet.encodedByteCount, 4_096)
                XCTAssertLessThanOrEqual(packet.encodedByteCount, ReconstructionRetrievalPacket.oversizePageHardCapBytes)
                XCTAssertTrue(packet.canonicalBytes.range(of: Data("\"oversizePage\":true".utf8)) != nil)
                oversizePages += packet.records.map(\.evidenceID)
            } else {
                XCTAssertLessThanOrEqual(packet.encodedByteCount, 4_096)
            }
            if let marker = packet.recordTooLarge {
                XCTAssertTrue(packet.records.isEmpty)
                XCTAssertTrue(packet.canonicalBytes.range(of: Data("recordTooLarge".utf8)) != nil)
                markers.append(marker)
            }
            XCTAssertEqual(packet.hasMore, packet.nextCursor != nil)
            if let next = packet.nextCursor {
                XCTAssertNotEqual(next, cursor, "continuation must make progress")
                cursor = next
            } else { cursor = nil; break }
        }
        XCTAssertNil(cursor, "paging must terminate")
        XCTAssertEqual(oversizePages, [retrievalID(82)])
        XCTAssertEqual(markers.map(\.evidenceID), [retrievalID(83)])
        XCTAssertGreaterThan(markers.first?.encodedByteCount ?? 0, ReconstructionRetrievalPacket.oversizePageHardCapBytes)
        XCTAssertEqual(Set(delivered + markers.map(\.evidenceID)), Set(records.map(\.evidenceID)))
        XCTAssertEqual(delivered.count + markers.count, records.count)
        // The oversize page carries the complete, untruncated record.
        let packets = try [page(nil)]
        XCTAssertEqual(packets.first?.records.map(\.evidenceID), [retrievalID(81)])
        // The same continuation now compiles through the context compiler.
        let afterSmall = try XCTUnwrap(packets.first?.nextCursor)
        let context = try ReconstructionContextCompiler().compile(cut: cut, query: try retrievalQuery(
            operations: [operation], classifications: [.acceptedCurrent], cursor: afterSmall,
            maximumRecords: 8, maximumEncodedBytes: 4_096), allowedGapSubjects: [], allowedGapCategories: [])
        XCTAssertEqual(context.evidenceIDs, [retrievalID(82)])
        let oversizeRecord = try XCTUnwrap(try page(afterSmall).records.first)
        XCTAssertEqual(oversizeRecord.record.payload, oversized.payload)
    }

    func testByteBudgetSelectionReportsActualPacketAndRecordEncodingWork() throws {
        let artifact = try retrievalArtifact(occurrence: 65)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(875)
        let records = try (0..<256).map { index in
            try retrievalEvidence(
                id: retrievalID(10_000 + index),
                subject: .artifact(artifact),
                operationID: operation.rawValue,
                checkpointID: checkpoint,
                payload: Data(repeating: UInt8(index % 251), count: 256)
            )
        }
        let classifications = Dictionary(uniqueKeysWithValues: records.map {
            ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
        })
        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: try retrievalCut(
                records: Array(records.reversed()),
                projectedClassifications: classifications,
                checkpointRevisions: [checkpoint: 11]
            ),
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: records.count,
                maximumEncodedBytes: 32 * 1_024
            )
        )

        XCTAssertFalse(packet.records.isEmpty)
        XCTAssertLessThan(packet.records.count, records.count)
        XCTAssertTrue(packet.hasMore)
        XCTAssertEqual(packet.nextCursor?.evidenceID, packet.records.last?.evidenceID)
        XCTAssertLessThanOrEqual(packet.encodedByteCount, 32 * 1_024)
        XCTAssertEqual(
            packet.selectionEncodingPassCount,
            packet.selectionRecordAccountingCount + 2
        )
        XCTAssertLessThan(packet.selectionRecordAccountingCount, records.count)
    }

    func testTinyExactByteBudgetAccountsOnlyAcceptedPrefixPlusFirstRejectedRecord() throws {
        let artifact = try retrievalArtifact(occurrence: 651)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(8_751)
        let records = try (0..<2_048).map { index in
            try retrievalEvidence(
                id: retrievalID(30_000 + index),
                subject: .artifact(artifact),
                operationID: operation.rawValue,
                checkpointID: checkpoint,
                payload: Data(repeating: UInt8(index % 251), count: 128)
            )
        }
        let cut = try retrievalCut(
            records: Array(records.reversed()),
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map {
                ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
            }),
            checkpointRevisions: [checkpoint: 13]
        )
        let compiler = ReconstructionRetrievalCompiler()
        let exactOneRecordPacket = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 1,
                maximumEncodedBytes: 1_000_000
            )
        )

        let constrained = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: records.count,
                maximumEncodedBytes: exactOneRecordPacket.encodedByteCount
            )
        )

        XCTAssertEqual(constrained.records.map(\.evidenceID), [records[0].evidenceID])
        XCTAssertEqual(constrained.canonicalBytes, exactOneRecordPacket.canonicalBytes)
        XCTAssertEqual(constrained.canonicalSHA256, exactOneRecordPacket.canonicalSHA256)
        XCTAssertEqual(constrained.nextCursor, exactOneRecordPacket.nextCursor)
        XCTAssertEqual(constrained.nextCursor?.canonicalSubjectIdentity.count, SHA256.byteCount)
        XCTAssertTrue(constrained.hasMore)
        XCTAssertEqual(constrained.encodedByteCount, exactOneRecordPacket.encodedByteCount)
        XCTAssertEqual(constrained.selectionEncodingPassCount, 4)
        XCTAssertEqual(constrained.selectionRecordAccountingCount, 2)
        XCTAssertLessThan(
            constrained.selectionRecordAccountingCount,
            records.count / 100,
            "Tiny packet budgets must not size the complete candidate prefix"
        )
    }

    func testLongToShortSubjectCursorBoundaryDoesNotUnderfillByteBudget() throws {
        let functionArtifact = try retrievalArtifact(occurrence: 66)
        let artifactA = try retrievalArtifact(occurrence: 67)
        let artifactB = try retrievalArtifact(occurrence: 68)
        let artifactC = try retrievalArtifact(occurrence: 69)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(876)
        let shortFunction = try retrievalFunction(
            artifact: functionArtifact,
            start: 0x1000
        )
        let longFunction = try retrievalFunction(
            artifact: functionArtifact,
            start: 0x2000,
            symbolHint: String(repeating: "long-subject-", count: 2_048)
        )
        let records = [
            try retrievalEvidence(
                id: retrievalID(10_300),
                subject: .function(shortFunction),
                operationID: operation.rawValue,
                checkpointID: checkpoint
            ),
            try retrievalEvidence(
                id: retrievalID(10_301),
                subject: .function(longFunction),
                operationID: operation.rawValue,
                checkpointID: checkpoint
            ),
            try retrievalEvidence(
                id: retrievalID(10_302),
                subject: .artifact(artifactA),
                operationID: operation.rawValue,
                checkpointID: checkpoint
            ),
            try retrievalEvidence(
                id: retrievalID(10_303),
                subject: .artifact(artifactB),
                operationID: operation.rawValue,
                checkpointID: checkpoint
            ),
            try retrievalEvidence(
                id: retrievalID(10_304),
                subject: .artifact(artifactC),
                operationID: operation.rawValue,
                checkpointID: checkpoint
            ),
        ]
        let cut = try retrievalCut(
            records: Array(records.reversed()),
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map {
                ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
            }),
            checkpointRevisions: [checkpoint: 12]
        )
        let compiler = ReconstructionRetrievalCompiler()
        let threeRecordPacket = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 3,
                maximumEncodedBytes: 1_000_000
            )
        )
        let fourRecordPacket = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 4,
                maximumEncodedBytes: 1_000_000
            )
        )
        XCTAssertGreaterThan(
            fourRecordPacket.encodedByteCount,
            threeRecordPacket.encodedByteCount
        )

        let constrained = try compiler.compile(
            cut: cut,
            query: try retrievalQuery(
                operations: [operation],
                classifications: [.acceptedCurrent],
                maximumRecords: 4,
                maximumEncodedBytes: threeRecordPacket.encodedByteCount
            )
        )

        XCTAssertEqual(
            constrained.records.map(\.evidenceID),
            records.prefix(3).map(\.evidenceID)
        )
        XCTAssertEqual(constrained.canonicalBytes, threeRecordPacket.canonicalBytes)
        XCTAssertEqual(constrained.nextCursor?.evidenceID, records[2].evidenceID)
        XCTAssertTrue(constrained.hasMore)
        XCTAssertEqual(
            constrained.selectionEncodingPassCount,
            constrained.selectionRecordAccountingCount + 2
        )
    }

    func testCancelledCompilationThrowsCancellationErrorBeforePublishingPacket() async throws {
        let artifact = try retrievalArtifact(occurrence: 70)
        let operation = retrievalOperation("reconstruction.evidence.query")
        let checkpoint = retrievalID(880)
        let record = try retrievalEvidence(
            id: retrievalID(81),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let cut = try retrievalCut(
            records: [record],
            projectedClassifications: [record.evidenceID: .acceptedCurrent],
            checkpointRevisions: [checkpoint: 1]
        )
        let query = try retrievalQuery(
            operations: [operation],
            classifications: [.acceptedCurrent]
        )
        let task = Task.detached { () throws -> ReconstructionRetrievalPacket in
            while !Task.isCancelled { await Task.yield() }
            return try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        }

        task.cancel()
        switch await task.result {
        case .success:
            XCTFail("A cancelled retrieval must not publish a packet")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unexpected cancellation error: \(error)")
        }
    }

    func testContextBudgetIncludesBase64AndCompleteFinalWireEnvelope() throws {
        let artifact = try retrievalArtifact(occurrence: 82)
        let operation = retrievalOperation("reconstruction.evidence.get")
        let checkpoint = retrievalID(892)
        let records = try (0..<64).map { index in
            try retrievalEvidence(
                id: retrievalID(20_000 + index),
                subject: .artifact(artifact),
                operationID: operation.rawValue,
                checkpointID: checkpoint,
                payload: Data(repeating: UInt8(index), count: 16_384)
            )
        }
        let cut = try retrievalCut(
            records: records,
            projectedClassifications: Dictionary(uniqueKeysWithValues: records.map {
                ($0.evidenceID, ReconstructionEvidenceClassification.acceptedCurrent)
            }),
            checkpointRevisions: [checkpoint: 1]
        )
        let query = try retrievalQuery(
            operations: [operation], classifications: [.acceptedCurrent],
            maximumRecords: 65_536, maximumEncodedBytes: 1_048_576
        )
        let context = try ReconstructionContextCompiler().compile(
            cut: cut, query: query, allowedGapSubjects: [], allowedGapCategories: []
        )
        XCTAssertFalse(context.evidenceIDs.isEmpty)
        XCTAssertLessThan(context.evidenceIDs.count, records.count)
        XCTAssertLessThanOrEqual(context.canonicalBytes.count, 1_048_576)
        let request = ReconstructionFinalSynthesisRequest(
            jobID: retrievalID(950), checkpointRevision: 1,
            corpusManifestSHA256: cut.corpusManifestSHA256,
            evidenceFrontierSHA256: cut.frontierSHA256,
            acceptedEvidenceIDs: context.evidenceIDs, context: context
        )
        let wire = try Phase2ReconstructionAIWorkerWireCodec().encodeFinalRequest(
            request, requestID: retrievalID(951)
        )
        XCTAssertLessThanOrEqual(wire.count, Phase2ReconstructionAIWorkerWireCodec.maximumEnvelopeBytes)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: context.canonicalBytes)
            as? [String: Any])
        let encodedPacket = try XCTUnwrap(envelope["retrievalPacket"] as? String)
        let packetBytes = try XCTUnwrap(Data(base64Encoded: encodedPacket))
        let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: packetBytes)
            as? [String: Any])
        XCTAssertEqual(packet["hasMore"] as? Bool, true)
        XCTAssertNotNil(packet["nextCursor"])
    }

    func testValueOnlyCutCompilesOffMainActorWithoutWorkspaceOrPathAuthority() async throws {
        let artifact = try retrievalArtifact(occurrence: 80)
        let operation = retrievalOperation("reconstruction.corpus.summary")
        let checkpoint = retrievalID(890)
        let record = try retrievalEvidence(
            id: retrievalID(91),
            subject: .artifact(artifact),
            operationID: operation.rawValue,
            checkpointID: checkpoint
        )
        let cut = try retrievalCut(
            records: [record],
            projectedClassifications: [record.evidenceID: .acceptedCurrent],
            checkpointRevisions: [checkpoint: 1]
        )
        let query = try retrievalQuery(
            operations: [operation],
            classifications: [.acceptedCurrent]
        )

        let packet = try await Task.detached {
            try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        }.value

        XCTAssertEqual(packet.records.map(\.evidenceID), [retrievalID(91)])
        XCTAssertFalse(packet.canonicalBytes.isEmpty)
    }
}

private func retrievalCut(
    corpusDigest: String = retrievalDigest("a"),
    records: [ReconstructionEvidenceRecord],
    projectedClassifications: [UUID: ReconstructionEvidenceClassification],
    checkpointRevisions: [UUID: UInt64],
    relations: [ReconstructionEvidenceRelation] = [],
    gaps: [ReconstructionEvidenceGap] = []
) throws -> ReconstructionEvidenceCut {
    let frontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
        corpusManifestSHA256: corpusDigest,
        records: records,
        projectedClassificationsByEvidenceID: projectedClassifications,
        relations: relations,
        gaps: gaps,
        checkpointRevisionsByID: checkpointRevisions
    )
    return try ReconstructionEvidenceCut(
        corpusManifestSHA256: corpusDigest,
        records: records,
        relations: relations,
        gaps: gaps,
        frontierSHA256: frontierSHA256,
        projectedClassificationsByEvidenceID: projectedClassifications,
        checkpointRevisionsByID: checkpointRevisions
    )
}

private func retrievalQuery(
    corpusDigest: String = retrievalDigest("a"),
    subject: ReconstructionDurableSubject? = nil,
    operations: [MacScopeAnalysisCore.ReconstructionOperationID],
    classifications: [ReconstructionEvidenceClassification],
    cursor: ReconstructionRetrievalCursor? = nil,
    maximumRecords: Int = 100,
    maximumEncodedBytes: Int = 1_000_000,
    focus: ReconstructionSubjectCoordinate? = nil
) throws -> ReconstructionRetrievalQuery {
    try ReconstructionRetrievalQuery(
        corpusManifestSHA256: corpusDigest,
        subject: subject,
        operationIDs: operations,
        classifications: classifications,
        cursor: cursor,
        maximumRecords: maximumRecords,
        maximumEncodedBytes: maximumEncodedBytes,
        focus: focus
    )
}

private func retrievalOperation(_ rawValue: String) -> MacScopeAnalysisCore.ReconstructionOperationID {
    guard let operation = MacScopeAnalysisCore.ReconstructionOperationID(rawValue: rawValue) else {
        XCTFail("Missing frozen reconstruction operation: \(rawValue)")
        fatalError("Missing frozen reconstruction operation")
    }
    return operation
}

private func retrievalArtifact(occurrence value: Int) throws -> ReconstructionArtifactCoordinate {
    ReconstructionArtifactCoordinate(
        occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: retrievalID(value)),
        contentIdentity: try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: retrievalDigest("c"),
            byteCount: 128
        )
    )
}

private func retrievalImage(
    artifact: ReconstructionArtifactCoordinate
) throws -> ReconstructionImageCoordinate {
    try ReconstructionImageCoordinate(
        artifact: artifact,
        image: retrievalImageBinding(),
        analysisFingerprintSHA256: retrievalDigest("d")
    )
}

private func retrievalFunction(
    artifact: ReconstructionArtifactCoordinate,
    start: UInt64,
    functionUUIDHint: UUID? = nil,
    symbolHint: String? = nil
) throws -> ReconstructionFunctionCoordinate {
    try ReconstructionFunctionCoordinate(
        artifact: artifact,
        image: retrievalImageBinding(),
        analysisFingerprintSHA256: retrievalDigest("d"),
        startAddress: start,
        endAddressExclusive: start + 0x40,
        boundarySchemaVersion: 1,
        functionUUIDHint: functionUUIDHint,
        symbolHint: symbolHint
    )
}

private struct RetrievalProjectionInputEnvelope: Encodable {
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let records: [ReconstructionEvidenceRecord]
    let projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification]
    let checkpointRevisionsByID: [UUID: UInt64]
    let relations: [ReconstructionEvidenceRelation]
    let gaps: [ReconstructionEvidenceGap]
}

private func retrievalImageBinding() -> ReconstructionImageBinding {
    ReconstructionImageBinding(
        binaryID: retrievalID(900),
        imageSlot: ImageSlot(rawValue: 1),
        selectedSliceIndex: 0,
        architecture: .arm64,
        machOIdentity: nil
    )
}

private func retrievalEvidence(
    id evidenceID: UUID,
    subject: ReconstructionSubjectCoordinate,
    operationID: String,
    checkpointID: UUID,
    classification: ReconstructionEvidenceClassification = .acceptedCurrent,
    payload: Data = Data("retrieval evidence".utf8),
    payloadSHA256: String? = nil,
    jobID: UUID = retrievalID(910)
) throws -> ReconstructionEvidenceRecord {
    try ReconstructionEvidenceRecord(
        evidenceID: evidenceID,
        subject: subject,
        operationID: operationID,
        payloadKind: .structuredJSON,
        payload: payload,
        payloadByteCount: UInt64(payload.count),
        payloadSHA256: payloadSHA256 ?? retrievalSHA256(payload),
        facetDependencies: [],
        producer: try ReconstructionProducerIdentity(
            macScopeBuildIdentity: "build-v1",
            macScopeSourceIdentity: "source-v1",
            operationIdentity: "\(operationID)@1",
            registryIdentity: "reconstruction.v1",
            protocolIdentity: "reconstructionR1",
            canonicalSHA256: retrievalDigest("b")
        ),
        citations: [],
        creatingJobID: jobID,
        creatingTaskID: retrievalID(911),
        creatingCheckpointID: checkpointID,
        modelReceiptID: nil,
        toolReceiptID: retrievalID(913),
        classification: classification,
        supersedesEvidenceID: nil,
        supersededByEvidenceID: nil,
        diagnostic: nil
    )
}

private func retrievalGap(
    id gapID: UUID,
    subject: ReconstructionSubjectCoordinate,
    operationID: String
) throws -> ReconstructionEvidenceGap {
    try ReconstructionEvidenceGap(
        gapID: gapID,
        subject: subject,
        operationID: operationID,
        reason: .sanitizing("missing evidence"),
        canonicalSHA256: retrievalDigest("9")
    )
}

private func retrievalDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func retrievalID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func retrievalSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
