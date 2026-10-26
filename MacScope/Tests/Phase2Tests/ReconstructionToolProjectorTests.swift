import CryptoKit
import Foundation
import XCTest

@testable import MacScope

final class ReconstructionToolProjectorTests: XCTestCase {
    func testClosedProjectedPayloadEmitsOnlySafeEnvelopeKeysForEveryOperation() throws {
        // Refresh scheduling and model-authored source are not projected read payloads.
        for operation in MacScopeAnalysisCore.ReconstructionOperationID.allCases where operation != .analysisMacScopeRefresh && !operation.isDurableSourceOperation {
            let payload = try projectedPayload(
                operation, "decompiled text /private/tmp/input; SELECT * FROM transient"
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload.canonicalBytes) as? [String: Any]
            )
            let allowed = Set([
                "schemaVersion", "artifactCount", "functionCount", "evidenceCount",
                "records", "totalCount", "subject", "operationID", "canonicalSHA256",
                "byteCount", "pseudocode", "evidenceIDs", "frontierSHA256",
                "state", "checkpointRevision",
            ])
            XCTAssertTrue(Set(object.keys).isSubset(of: allowed))
            XCTAssertEqual(object["schemaVersion"] as? Int, 1)
            XCTAssertNil(object["path"])
            XCTAssertNil(object["sql"])
            XCTAssertNil(object["transientAuthority"])
        }
    }

    func testProjectedEvidenceRejectsOversizedMaterialBeforeFrontierHashing() throws {
        let subject = MacScopeAnalysisCore.ReconstructionSubjectCoordinate.artifact(
            MacScopeAnalysisCore.ReconstructionArtifactCoordinate(
                occurrenceID: .init(rawValue: UUID()),
                contentIdentity: try .init(
                    algorithm: .sha256,
                    digest: String(repeating: "8", count: 64),
                    byteCount: 1
                )
            )
        )
        XCTAssertThrowsError(try MacScope.ReconstructionProjectedEvidence(
            evidenceID: UUID(),
            subject: subject,
            operationID: .corpusSummary,
            payloadKind: .structuredJSON,
            payload: Data(repeating: 0x61, count: 1_048_577),
            facetDependencies: [],
            citations: [],
            supersedesEvidenceID: nil,
            diagnostic: nil
        )) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .invalidProjectedEvidence)
        }
    }

    func testProjectedReadItemRejectsOperationMismatchStructurally() throws {
        let subject = MacScopeAnalysisCore.ReconstructionSubjectCoordinate.artifact(
            MacScopeAnalysisCore.ReconstructionArtifactCoordinate(
                occurrenceID: .init(rawValue: UUID()),
                contentIdentity: try .init(
                    algorithm: .sha256,
                    digest: String(repeating: "9", count: 64),
                    byteCount: 1
                )
            )
        )
        XCTAssertThrowsError(try MacScope.ReconstructionProjectedReadItem(
            payload: projectedPayload(.corpusSummary, "1"),
            evidence: try .init(
                evidenceID: UUID(),
                subject: subject,
                operationID: .functionsPage,
                payloadKind: .structuredJSON,
                payload: jsonItem(1),
                facetDependencies: [],
                citations: [],
                supersedesEvidenceID: nil,
                diagnostic: nil
            )
        )) {
            XCTAssertEqual(
                $0 as? MacScope.ReconstructionToolBrokerError,
                .invalidProjectedReadItem
            )
        }
    }

    func testProjectedReadItemRequiresBoundedClosedPayload() {
        XCTAssertThrowsError(try MacScope.ReconstructionSummaryDTO(
            artifactCount: -1, functionCount: 0, evidenceCount: 0
        ))
    }

    func testEveryOperationRoutesOnlyToItsExpectedProjectorFamily() async throws {
        let expected: [(MacScopeAnalysisCore.ReconstructionOperationID, MacScope.ReconstructionToolProjectorFamily)] = [
            (.corpusSummary, .corpus),
            (.corpusArtifactsPage, .corpus),
            (.corpusArtifactDescribe, .corpus),
            (.corpusRelationsPage, .corpus),
            (.corpusSearch, .corpus),
            (.imagesPage, .imageFunction),
            (.functionsPage, .imageFunction),
            (.functionReview, .imageFunction),
            (.decompilerNative, .decompiler),
            (.decompilerMacScope, .decompiler),
            (.decompilerCompare, .decompiler),
            (.evidenceQuery, .evidence),
            (.evidenceGet, .evidence),
            (.gapsPage, .gaps),
            (.checkpointStatus, .checkpoint),
            (.analysisMacScopeRefresh, .decompiler),
        ]
        let projectors = makeProjectors()
        XCTAssertEqual(Set(projectors.map(\.family)).count, 6)

        for (operation, family) in expected {
            let matching = projectors.filter { $0.operations.contains(operation) }
            XCTAssertEqual(matching.count, 1, "operation \(operation.rawValue)")
            XCTAssertEqual(matching.first?.family, family)
        }
        XCTAssertEqual(
            Set(projectors.flatMap(\.operations)),
            Set(MacScopeAnalysisCore.ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation })
        )
    }

    func testEachProjectorFamilyHasBoundedOutcomeMatrix() async throws {
        let representatives: [(any MacScope.ReconstructionToolProjecting, MacScopeAnalysisCore.ReconstructionOperationID)] = [
            (MacScope.ReconstructionCorpusToolProjector(), .corpusArtifactsPage),
            (MacScope.ReconstructionImageFunctionToolProjector(), .functionsPage),
            (MacScope.ReconstructionDecompilerToolProjector(), .decompilerNative),
            (MacScope.ReconstructionEvidenceToolProjector(), .evidenceGet),
            (MacScope.ReconstructionGapsToolProjector(), .gapsPage),
            (MacScope.ReconstructionCheckpointToolProjector(), .checkpointStatus),
        ]

        for (projector, operation) in representatives {
            let successFixture = try makeFixture(items: [operation: [jsonItem(1)]])
            let success = try await projector.project(
                request: try envelope(operation, fixture: successFixture),
                input: successFixture.input
            )
            XCTAssertEqual(success.outcome, .success, "\(projector.family)")
            XCTAssertEqual(success.itemCount, 1)
            XCTAssertEqual(success.payloadSHA256, sha256(success.payload))

            let unavailableFixture = try makeFixture(items: [:])
            let unavailable = try await projector.project(
                request: try envelope(operation, fixture: unavailableFixture),
                input: unavailableFixture.input
            )
            XCTAssertEqual(unavailable.outcome, .unavailable, "\(projector.family)")

            let staleFixture = try makeFixture(items: [operation: [jsonItem(1)]], stale: [operation])
            let stale = try await projector.project(
                request: try envelope(operation, fixture: staleFixture),
                input: staleFixture.input
            )
            XCTAssertEqual(stale.outcome, .stale, "\(projector.family)")

            let truncatedFixture = try makeFixture(items: [operation: [jsonItem(1), jsonItem(2)]])
            let truncated = try await projector.project(
                request: try envelope(operation, fixture: truncatedFixture, maximumRecords: 1),
                input: truncatedFixture.input
            )
            XCTAssertEqual(truncated.outcome, .truncated, "\(projector.family)")
            XCTAssertEqual(truncated.itemCount, 1)
            XCTAssertNotNil(truncated.continuationRequest)
            XCTAssertEqual(truncated.continuationRequest?.offset, 1)

            let failedFixture = try makeFixture(items: [operation: [
                Data("{\"value\":\"\(String(repeating: "x", count: 256))\"}".utf8),
            ]])
            let failed = try await projector.project(
                request: try envelope(
                    operation,
                    fixture: failedFixture,
                    maximumEncodedBytes: 64
                ),
                input: failedFixture.input
            )
            if projector.family == .checkpoint {
                XCTAssertEqual(failed.outcome, .success, "\(projector.family)")
                XCTAssertNil(failed.diagnostic)
            } else {
                XCTAssertEqual(failed.outcome, .failed, "\(projector.family)")
                XCTAssertLessThanOrEqual(failed.diagnostic?.text.utf8.count ?? .max, 1_024)
                XCTAssertFalse(failed.diagnostic?.text.contains(NSHomeDirectory()) == true)
            }
        }
    }

    func testPagedProjectionUsesExactAppChosenBoundsAndDeterministicContinuation() async throws {
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.corpusArtifactsPage
        let fixture = try makeFixture(items: [operation: [jsonItem(1), jsonItem(2), jsonItem(3)]])
        let projector = MacScope.ReconstructionCorpusToolProjector()
        let request = try envelope(operation, fixture: fixture, maximumRecords: 2)
        let first = try await projector.project(request: request, input: fixture.input)
        let repeated = try await projector.project(request: request, input: fixture.input)

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.outcome, .truncated)
        XCTAssertEqual(first.itemCount, 2)
        let continuation = try XCTUnwrap(first.continuationRequest)
        XCTAssertEqual(continuation.operationID, operation)
        XCTAssertEqual(continuation.offset, 2)
        XCTAssertEqual(continuation.maximumRecords, 2)
        XCTAssertEqual(continuation.maximumEncodedBytes, request.maximumEncodedBytes)
    }

    func testNestedPageRecordsCannotBypassAppChosenRecordLimit() async throws {
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.functionsPage
        let fixture = try makeFixture(items: [
            operation: [Data(String(repeating: "p", count: 128).utf8)],
        ])
        let result = try await MacScope.ReconstructionImageFunctionToolProjector().project(
            request: try envelope(operation, fixture: fixture, maximumRecords: 1),
            input: fixture.input
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.itemCount, 0)
        XCTAssertNil(result.continuationRequest)
    }

    func testNestedEvidenceIDsCannotBypassAppChosenRecordLimit() async throws {
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.evidenceGet
        let fixture = try makeFixture(items: [
            operation: [Data(String(repeating: "e", count: 32).utf8)],
        ])
        let result = try await MacScope.ReconstructionEvidenceToolProjector().project(
            request: try envelope(operation, fixture: fixture, maximumRecords: 1),
            input: fixture.input
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.itemCount, 0)
        XCTAssertNil(result.continuationRequest)
    }

    func testEvidenceQueryUsesDeterministicRetrievalCompilerEnvelope() async throws {
        let fixture = try makeFixture(items: [:])
        let query = try MacScopeAnalysisCore.ReconstructionRetrievalQuery(
            corpusManifestSHA256: fixture.authority.corpusManifestSHA256,
            subject: nil,
            operationIDs: [.corpusSummary],
            classifications: [.acceptedCurrent],
            cursor: nil,
            maximumRecords: 8,
            maximumEncodedBytes: 16_384
        )
        let request = MacScopeAnalysisCore.ReconstructionToolRequest(
            operationID: .evidenceQuery,
            taskID: UUID(uuidString: "00000000-0000-4000-8000-00000000000C")!,
            subject: nil,
            retrievalQuery: query,
            offset: 0,
            maximumRecords: 8,
            maximumEncodedBytes: 16_384
        )
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request]
        ).first)
        let envelope = try MacScopeAnalysisCore.ReconstructionToolRegistry().decodeCanonicalRequest(handle)

        let result = try await MacScope.ReconstructionEvidenceToolProjector().project(
            request: envelope,
            input: fixture.input
        )

        XCTAssertEqual(result.outcome, .success)
        XCTAssertEqual(result.itemCount, 0)
        XCTAssertTrue(String(decoding: result.payload, as: UTF8.self).contains("evidenceFrontierSHA256"))
        XCTAssertEqual(result.payloadSHA256, sha256(result.payload))
    }

    func testProjectionPayloadByteBudgetProducesTruncationWithoutPartialJSON() async throws {
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.functionsPage
        let first = Data("{\"value\":\"\(String(repeating: "1", count: 128))\"}".utf8)
        let second = Data("{\"value\":\"\(String(repeating: "2", count: 128))\"}".utf8)
        let fixture = try makeFixture(items: [operation: [first, second]])
        let projector = MacScope.ReconstructionImageFunctionToolProjector()
        let roomy = try envelope(operation, fixture: fixture, maximumRecords: 4)
        let one = try await projector.project(
            request: roomy,
            input: fixture.input
        )
        let bounded = try envelope(
            operation,
            fixture: fixture,
            maximumRecords: 4,
            maximumEncodedBytes: max(256, one.payload.count - 1)
        )
        let result = try await projector.project(request: bounded, input: fixture.input)

        XCTAssertEqual(result.outcome, .truncated)
        XCTAssertLessThanOrEqual(result.payload.count, bounded.maximumEncodedBytes)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: result.payload))
        XCTAssertNotNil(result.continuationRequest)
    }

    func testOversizedFirstItemFailsClosedWithoutContinuationLoop() async throws {
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.functionsPage
        let oversized = Data("{\"value\":\"\(String(repeating: "x", count: 256))\"}".utf8)
        let fixture = try makeFixture(items: [operation: [oversized]])
        let request = try envelope(
            operation,
            fixture: fixture,
            maximumRecords: 1,
            maximumEncodedBytes: 256
        )
        let result = try await MacScope.ReconstructionImageFunctionToolProjector().project(
            request: request,
            input: fixture.input
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.continuationRequest)
        XCTAssertEqual(result.diagnostic?.text, "A projected item exceeds the app-owned byte budget.")
        XCTAssertLessThanOrEqual(result.diagnostic?.text.utf8.count ?? .max, 1_024)
    }

    func testPageStopsBeforeValidatingLaterItemAndContinuationFailsClosed() async throws {
        let operation = MacScopeAnalysisCore.ReconstructionOperationID.functionsPage
        let laterOversizedInvalidItem = Data(
            "{\"value\":\"\(String(repeating: "x", count: 256))\"}".utf8
        )
        let fixture = try makeFixture(items: [
            operation: [jsonItem(1), laterOversizedInvalidItem],
        ])
        let firstRequest = try envelope(
            operation,
            fixture: fixture,
            maximumRecords: 1,
            maximumEncodedBytes: 256
        )

        let first = try await MacScope.ReconstructionImageFunctionToolProjector().project(
            request: firstRequest,
            input: fixture.input
        )

        XCTAssertEqual(first.outcome, .truncated)
        XCTAssertEqual(first.itemCount, 1)
        let continuation = try XCTUnwrap(first.continuationRequest)
        let continuationHandle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [continuation]
        ).first)
        let continuationEnvelope = try MacScopeAnalysisCore.ReconstructionToolRegistry()
            .decodeCanonicalRequest(continuationHandle)
        let second = try await MacScope.ReconstructionImageFunctionToolProjector().project(
            request: continuationEnvelope,
            input: fixture.input
        )
        XCTAssertEqual(second.outcome, .failed)
        XCTAssertNil(second.continuationRequest)
    }

    func testProjectorInputRejectsPerItemAndAggregateOverBudgetData() throws {
        XCTAssertThrowsError(try makeFixture(items: [
            .decompilerNative: [Data(String(repeating: "x", count: 1_048_577).utf8)],
        ])) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .invalidProjectedPayload)
        }
        XCTAssertThrowsError(try makeFixture(items: [
            .decompilerNative: Array(
                repeating: Data(String(repeating: "x", count: 900_000).utf8),
                count: 5
            ),
        ])) {
            XCTAssertEqual($0 as? MacScope.ReconstructionToolBrokerError, .invalidProjectorInput)
        }
    }

    private func makeProjectors() -> [any MacScope.ReconstructionToolProjecting] {
        [
            MacScope.ReconstructionCorpusToolProjector(),
            MacScope.ReconstructionImageFunctionToolProjector(),
            MacScope.ReconstructionDecompilerToolProjector(),
            MacScope.ReconstructionEvidenceToolProjector(),
            MacScope.ReconstructionGapsToolProjector(),
            MacScope.ReconstructionCheckpointToolProjector(),
        ]
    }

    private func envelope(
        _ operation: MacScopeAnalysisCore.ReconstructionOperationID,
        fixture: Fixture,
        maximumRecords: Int = 16,
        maximumEncodedBytes: Int = 16_384
    ) throws -> MacScopeAnalysisCore.ReconstructionToolRequestEnvelope {
        let request = MacScopeAnalysisCore.ReconstructionToolRequest(
            operationID: operation,
            taskID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", operation.priority + 1))!,
            subject: nil,
            retrievalQuery: nil,
            offset: 0,
            maximumRecords: maximumRecords,
            maximumEncodedBytes: maximumEncodedBytes
        )
        let handle = try XCTUnwrap(MacScopeAnalysisCore.ReconstructionToolRegistry().mintHandles(
            authority: fixture.authority,
            requests: [request]
        ).first)
        return try MacScopeAnalysisCore.ReconstructionToolRegistry().decodeCanonicalRequest(handle)
    }

    private func makeFixture(
        items: [MacScopeAnalysisCore.ReconstructionOperationID: [Data]],
        stale: Set<MacScopeAnalysisCore.ReconstructionOperationID> = []
    ) throws -> Fixture {
        let jobID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let projectID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let corpusDigest = try MacScopeAnalysisCore.ReconstructionCanonicalJSON.sha256(
            of: TestProjectorCorpusManifestDigestPreimage(
                schemaVersion: MacScopeAnalysisCore.ReconstructionCorpusManifest.schemaVersion,
                reconstructionProjectID: projectID,
                artifacts: [],
                relations: []
            )
        )
        let manifest = try MacScopeAnalysisCore.ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [], relations: [], canonicalSHA256: corpusDigest
        )
        let frontier = try MacScope.ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: corpusDigest,
            records: [], projectedClassificationsByEvidenceID: [:],
            relations: [], gaps: [], checkpointRevisionsByID: [:]
        )
        let cut = try MacScope.ReconstructionEvidenceCut(
            corpusManifestSHA256: corpusDigest,
            records: [], relations: [], gaps: [], frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: [:], checkpointRevisionsByID: [:]
        )
        var exactProjectedItems: [MacScopeAnalysisCore.ReconstructionOperationID: [MacScope.ReconstructionProjectedReadItem]] = [:]
        for (operation, values) in items {
            exactProjectedItems[operation] = try values.map {
                try MacScope.ReconstructionProjectedReadItem(
                    payload: try projectedPayload(operation, String(decoding: $0, as: UTF8.self))
                )
            }
        }
        let producersByOperation = try Dictionary(uniqueKeysWithValues:
            MacScopeAnalysisCore.ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }.map { operation in
                let provisional = try MacScopeAnalysisCore.ReconstructionProducerIdentity(
                    macScopeBuildIdentity: "test-build",
                    macScopeSourceIdentity: "test-source",
                    operationIdentity: operation.rawValue,
                    registryIdentity: "reconstruction.v1",
                    protocolIdentity: "reconstruction.r1",
                    canonicalSHA256: String(repeating: "c", count: 64)
                )
                let digest = try MacScopeAnalysisCore.ReconstructionEvidenceIntegrity
                    .canonicalProducerSHA256(provisional)
                return (operation, try MacScopeAnalysisCore.ReconstructionProducerIdentity(
                    macScopeBuildIdentity: provisional.macScopeBuildIdentity,
                    macScopeSourceIdentity: provisional.macScopeSourceIdentity,
                    operationIdentity: provisional.operationIdentity,
                    registryIdentity: provisional.registryIdentity,
                    protocolIdentity: provisional.protocolIdentity,
                    canonicalSHA256: digest
                ))
            }
        )
        let tasks = try MacScopeAnalysisCore.ReconstructionOperationID.allCases.filter { !$0.isDurableSourceOperation }.map { operation in
            MacScopeAnalysisCore.ReconstructionTaskRecord(
                identity: try MacScopeAnalysisCore.ReconstructionTaskIdentity(
                    taskID: taskID(for: operation),
                    jobID: jobID,
                    kind: .retrieveEvidence,
                    subject: nil,
                    dependencyTaskIDs: [],
                    operationContractIdentity: operation.rawValue,
                    canonicalSHA256: String(repeating: "d", count: 64)
                ),
                state: .running,
                diagnostic: nil
            )
        }
        let projectionFrontier = try MacScope.ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: exactProjectedItems,
                staleOperations: stale,
                tasks: tasks,
                receipts: [],
                producersByOperation: producersByOperation,
                evidenceAuthorityCutsByOperation: [:]
            )
        let authority = try MacScopeAnalysisCore.ReconstructionToolAuthorityCut(
            jobID: jobID,
            checkpointRevision: 7,
            roundID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            corpusManifestSHA256: corpusDigest,
            evidenceFrontierSHA256: frontier,
            projectionFrontierSHA256: projectionFrontier
        )
        return Fixture(
            authority: authority,
            input: try MacScope.ReconstructionToolProjectorInput(
                authority: authority,
                corpusManifest: manifest,
                evidenceCut: cut,
                tasks: tasks,
                receipts: [],
                producersByOperation: producersByOperation,
                projectedItemsByOperation: exactProjectedItems,
                staleOperations: stale,
                evidenceAuthorityCutsByOperation: [:]
            )
        )
    }

    private func jsonItem(_ value: Int) -> Data {
        Data("{\"value\":\(value)}".utf8)
    }

    private func projectedPayload(
        _ operation: MacScopeAnalysisCore.ReconstructionOperationID,
        _ text: String
    ) throws -> MacScope.ReconstructionProjectedPayload {
        switch operation {
        case .corpusSummary:
            return .corpusSummary(try .init(
                artifactCount: text.utf8.count, functionCount: 0, evidenceCount: 0
            ))
        case .corpusArtifactsPage, .corpusRelationsPage, .corpusSearch,
             .imagesPage, .functionsPage, .gapsPage:
            let recordCount = min(4_096, max(1, text.utf8.count / 64))
            let records = try (0..<recordCount).map { _ in
                try MacScope.ReconstructionProjectedRecordDTO(
                    recordID: UUID(), operationID: operation,
                    byteCount: UInt64(text.utf8.count), canonicalSHA256: sha256(Data(text.utf8))
                )
            }
            let page = try MacScope.ReconstructionPageDTO(
                records: records, totalCount: records.count
            )
            switch operation {
            case .corpusArtifactsPage: return .corpusArtifactsPage(page)
            case .corpusRelationsPage: return .corpusRelationsPage(page)
            case .corpusSearch: return .corpusSearch(page)
            case .imagesPage: return .imagesPage(page)
            case .functionsPage: return .functionsPage(page)
            case .gapsPage: return .gapsPage(page)
            default: fatalError("exhaustive page operation")
            }
        case .corpusArtifactDescribe, .functionReview:
            let subject = MacScopeAnalysisCore.ReconstructionSubjectCoordinate.artifact(
                MacScopeAnalysisCore.ReconstructionArtifactCoordinate(
                    occurrenceID: .init(rawValue: UUID()),
                    contentIdentity: try .init(
                        algorithm: .sha256,
                        digest: sha256(Data(text.utf8)),
                        byteCount: UInt64(text.utf8.count)
                    )
                )
            )
            let detail = try MacScope.ReconstructionDetailDTO(
                subject: subject,
                operationID: operation, canonicalSHA256: sha256(Data(text.utf8)),
                byteCount: UInt64(text.utf8.count)
            )
            return operation == .corpusArtifactDescribe
                ? .corpusArtifactDescribe(detail) : .functionReview(detail)
        case .decompilerNative: return .decompilerNative(try .init(pseudocode: text))
        case .decompilerMacScope: return .decompilerMacScope(try .init(pseudocode: text))
        case .decompilerCompare: return .decompilerCompare(try .init(pseudocode: text))
        case .evidenceQuery:
            return .evidenceQuery(try .init(
                evidenceIDs: [], frontierSHA256: sha256(Data(text.utf8))
            ))
        case .evidenceGet:
            let evidenceCount = min(4_096, max(1, text.utf8.count / 16))
            let evidenceIDs = (0..<evidenceCount).map { index in
                UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012d",
                    index + 1
                ))!
            }
            return .evidenceGet(try .init(
                evidenceIDs: evidenceIDs, frontierSHA256: sha256(Data(text.utf8))
            ))
        case .checkpointStatus:
            return .checkpointStatus(.init(state: .running, checkpointRevision: 7))
        case .analysisMacScopeRefresh, .sourceRevision, .sourceOracle, .sourceEvaluate:
            throw MacScope.ReconstructionToolBrokerError.invalidProjectedReadItem
        }
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
}

private struct Fixture {
    let authority: MacScopeAnalysisCore.ReconstructionToolAuthorityCut
    let input: MacScope.ReconstructionToolProjectorInput
}

private struct TestProjectorCorpusManifestDigestPreimage: Encodable {
    let schemaVersion: Int
    let reconstructionProjectID: UUID
    let artifacts: [MacScopeAnalysisCore.ReconstructionArtifactOccurrenceRecord]
    let relations: [MacScopeAnalysisCore.ReconstructionArtifactRelationRecord]
}
