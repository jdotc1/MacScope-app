import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionProductionReceiptPlanAuthorTests: XCTestCase {
    func testByteBoundProductionReadsAdvanceOnlyPastDeliveredContext() async throws {
        // A durable basis must fit its whole encoded authority, including the evidence cut, within
        // `maxEncodedBytes`. The fixture therefore uses a 2 MiB job budget so the 128-record cut
        // (about 1.3 MiB) is admissible, while production still caps an ordinary read query at
        // 1 MiB. `unbounded` reproduces that pre-context-bound production tool query.
        let productionQueryByteCap = 1_048_576
        for (recordCount, paddingBytes, unboundedHasMore) in [(100, 6_000, false), (128, 6_500, true)] {
            let original = try await makeModelFixture()
            let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
            let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
                sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
                operation: .corpusArtifactDescribe, recordCount: recordCount,
                payloadPaddingBytes: paddingBytes, maximumEncodedBytes: 2_097_152)
            XCTAssertGreaterThan(basis.job.budget.maxEncodedBytes, UInt64(productionQueryByteCap))
            let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
            let fixture = Fixture(basis: basis, cut: cut(basis: basis, prepared: prepared, results: []),
                author: original.author, batchResultTaskID: nil)
            let delivered = try roundRequest(fixture).context
            let unbounded = try ReconstructionEvidenceReadAuthority.copy(prepared.retrievalQuery,
                cursor: nil, maximumEncodedBytes: min(Int(clamping: basis.job.budget.maxEncodedBytes),
                    productionQueryByteCap))
            let oldToolPacket = try ReconstructionRetrievalCompiler().compile(
                cut: basis.evidenceCut, query: unbounded)
            XCTAssertEqual(oldToolPacket.hasMore, unboundedHasMore)
            XCTAssertGreaterThan(oldToolPacket.records.count, delivered.evidenceIDs.count)
            let toolPacket = try ReconstructionRetrievalCompiler().compile(
                cut: basis.evidenceCut, query: prepared.retrievalQuery)
            XCTAssertEqual(toolPacket.records.map(\.evidenceID), delivered.evidenceIDs)
            XCTAssertTrue(toolPacket.hasMore)
            XCTAssertEqual(try ReconstructionContextCompiler().boundedQuery(cut: basis.evidenceCut,
                query: prepared.retrievalQuery, allowedGapSubjects: prepared.allowedGapSubjects,
                allowedGapCategories: prepared.allowedGapCategories), prepared.retrievalQuery)
            let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
                authority: prepared.authority, requests: prepared.requests).first)
            let outcome = inference(fixture: fixture, selectedHandleIDs: [handle.handleID], disposition: .continue)
            let inputs = try modelAuthorInputs(fixture: fixture, inference: outcome)
            let planner = ReconstructionProductionRoundPlanBuilder(
                basisRegistry: ReconstructionProductionRoundBasisRegistry(basis: basis, prepared: prepared),
                receiptAuthor: fixture.author)
            let plan = try await planner.makeCommitPlan(cut: fixture.cut,
                lease: lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
                inference: outcome, executions: [toolExecution(handle: handle, fixture: fixture)])
            let mutation = try XCTUnwrap(plan.mutation)
            XCTAssertEqual(mutation.toolReceipts.first?.evidenceReadAuthority?.readEvidenceIDs,
                delivered.evidenceIDs)
            let successor = try successorReadBasis(basis: basis, mutation: mutation)
            let next = try await refreshPreparedRound(successor, suppliesRefreshProducer: false)
            let nextContext = try ReconstructionContextCompiler().compile(cut: successor.evidenceCut,
                query: next.retrievalQuery, allowedGapSubjects: next.allowedGapSubjects,
                allowedGapCategories: next.allowedGapCategories)
            XCTAssertTrue(Set(delivered.evidenceIDs).isDisjoint(with: nextContext.evidenceIDs))
            XCTAssertEqual(delivered.evidenceIDs + nextContext.evidenceIDs,
                basis.evidenceCut.records.map(\.evidenceID))
            XCTAssertEqual(Set(delivered.evidenceIDs + nextContext.evidenceIDs),
                Set(basis.evidenceCut.records.map(\.evidenceID)))
        }
    }

    func testReadAuthorityRejectsUndeliveredTailWithTighterInjectedContextBudget() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 100, payloadPaddingBytes: 6_000)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let compiler = ReconstructionContextCompiler(maximumContextBytes: 300_000)
        let fixture = Fixture(basis: basis, cut: cut(basis: basis, prepared: prepared, results: []),
            author: author(contextCompiler: compiler), batchResultTaskID: nil)
        let delivered = try roundRequest(fixture, contextCompiler: compiler).context
        let packet = try ReconstructionRetrievalCompiler().compile(cut: basis.evidenceCut,
            query: prepared.retrievalQuery)
        XCTAssertGreaterThan(packet.records.count, delivered.evidenceIDs.count)
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority, requests: prepared.requests).first)
        let outcome = inference(fixture: fixture, selectedHandleIDs: [handle.handleID], disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: outcome, contextCompiler: compiler)
        await assertThrows(.invalidToolExecution) {
            _ = try await fixture.author.makeModelCommitPlan(cut: fixture.cut, basis: basis,
                basePlan: inputs.basePlan, lease: lease(providerRevision: 1),
                requestAuthority: inputs.requestAuthority, inference: outcome,
                executions: [toolExecution(handle: handle, fixture: fixture)])
        }
    }

    func testProductionCommitAndSuccessorRequestCarryPageTwoReadAuthority() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let basePrepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let initial = basePrepared.retrievalQuery
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: initial.corpusManifestSHA256, subject: initial.subject,
            operationIDs: initial.operationIDs, classifications: initial.classifications,
            cursor: nil, maximumRecords: 1, maximumEncodedBytes: initial.maximumEncodedBytes,
            focus: initial.focus)
        let request = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: try XCTUnwrap(basePrepared.requests.first).taskID, subject: nil,
            retrievalQuery: query, offset: 0, maximumRecords: query.maximumRecords,
            maximumEncodedBytes: query.maximumEncodedBytes)
        let prepared = ReconstructionPreparedModelRound(roundID: basePrepared.roundID,
            evidenceCut: basis.evidenceCut, retrievalQuery: query,
            allowedGapSubjects: basePrepared.allowedGapSubjects,
            allowedGapCategories: basePrepared.allowedGapCategories,
            authority: basePrepared.authority, requests: [request],
            projectorInput: basePrepared.projectorInput, objective: basePrepared.objective)
        let fixture = Fixture(basis: basis, cut: cut(basis: basis, prepared: prepared, results: []),
            author: original.author, batchResultTaskID: nil)
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority, requests: prepared.requests).first)
        let inference = inference(fixture: fixture, selectedHandleIDs: [handle.handleID],
            disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)
        let registry = ReconstructionProductionRoundBasisRegistry(basis: basis, prepared: prepared)
        let planner = ReconstructionProductionRoundPlanBuilder(basisRegistry: registry,
            receiptAuthor: fixture.author)
        let plan = try await planner.makeCommitPlan(cut: fixture.cut,
            lease: lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
            inference: inference, executions: [toolExecution(handle: handle, fixture: fixture)])
        let mutation = try XCTUnwrap(plan.mutation)
        let selectedRead = try XCTUnwrap(mutation.toolReceipts.first)
        XCTAssertNotNil(selectedRead.evidenceReadAuthority?.nextCursor)
        XCTAssertTrue(selectedRead.outputEvidenceIDs.isEmpty)
        XCTAssertTrue(mutation.evidence.isEmpty)
        let successor = try successorReadBasis(basis: basis, mutation: mutation)
        let next = try await refreshPreparedRound(successor, suppliesRefreshProducer: false)
        XCTAssertNotEqual(next.roundID, prepared.roundID)
        XCTAssertNotEqual(next.requests.first?.taskID, request.taskID)
        XCTAssertEqual(next.requests.first?.offset, 1)
        XCTAssertNotNil(next.retrievalQuery.cursor)
        let nextHandles = try ReconstructionToolRegistry().mintHandles(
            authority: next.authority, requests: next.requests)
        XCTAssertNotEqual(nextHandles.first?.handleID, handle.handleID)
        let capture = await SuccessorRequestCapture()
        let roundPlanner = ReconstructionProductionJobRoundPlanner(
            materializer: SuccessorCaptureMaterializer(prepared: next),
            inference: capture, projectors: [ReconstructionEvidenceToolProjector()])
        do {
            _ = try await roundPlanner.planRound(from: successor.snapshot)
            XCTFail("Capture provider should report busy after recording the actual request")
        } catch {
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .inferenceBusy)
        }
        let capturedValue = await capture.request
        let captured = try XCTUnwrap(capturedValue)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.context.evidenceIDs,
            [UUID(uuidString: "00000000-0000-0000-0000-000000009311")!])
        let readable = try ReconstructionReadablePromptProjection().project(captured,
            objective: .init(jobID: successor.job.jobID, text: successor.job.objective,
                sha256: successor.job.objectiveSHA256))
        XCTAssertTrue(readable.userText.contains("durable-current-1"))
        let encoded = try ReconstructionCanonicalJSON.encode(selectedRead)
        let reopened = try JSONDecoder().decode(ReconstructionToolReceipt.self, from: encoded)
        XCTAssertEqual(reopened, selectedRead)
        XCTAssertTrue(try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(reopened))
        for field in ["corpusManifestSHA256", "evidenceFrontierSHA256", "projectionFrontierSHA256"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var descriptor = try XCTUnwrap(object["evidenceReadAuthority"] as? [String: Any])
            var originalRequest = try XCTUnwrap(descriptor["request"] as? [String: Any])
            var authority = try XCTUnwrap(originalRequest["authority"] as? [String: Any])
            authority[field] = "malformed-digest"
            originalRequest["authority"] = authority
            descriptor["request"] = originalRequest
            object["evidenceReadAuthority"] = descriptor
            let invalidPackageReceipt = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(
                ReconstructionToolReceipt.self, from: invalidPackageReceipt))
        }
    }

    func testQualifiedReadResumesPageTwoAndRejectsTamperedContinuation() async throws {
        let fixture = try await makeModelFixture()
        let source = try XCTUnwrap(fixture.basis.tasks.first { $0.identity.kind == .ingest })
        let subject = try XCTUnwrap(source.identity.subject)
        let basis = try basisByAddingAcceptedCurrentEvidence(fixture.basis,
            sourceTaskID: source.identity.taskID, subject: subject,
            operation: .corpusArtifactDescribe, recordCount: 2)
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: basis.manifest.canonicalSHA256, subject: nil,
            operationIDs: [.corpusArtifactDescribe], classifications: [.acceptedCurrent],
            cursor: nil, maximumRecords: 1, maximumEncodedBytes: 65_536)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let request = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: try XCTUnwrap(prepared.requests.first).taskID, subject: nil,
            retrievalQuery: query, offset: 0, maximumRecords: 1, maximumEncodedBytes: 65_536)
        let registry = ReconstructionToolRegistry()
        let handle = try XCTUnwrap(registry.mintHandles(
            authority: prepared.authority, requests: [request]).first)
        let envelope = try registry.decodeCanonicalRequest(handle)
        let projection = try await ReconstructionEvidenceToolProjector().project(
            request: envelope, input: prepared.projectorInput)
        XCTAssertEqual(projection.outcome, .truncated)
        let read = try ReconstructionEvidenceReadAuthority.capture(
            request: envelope, result: projection, cut: basis.evidenceCut)
        let resumed = try read.successorQuery(cut: basis.evidenceCut, defaultQuery: query)
        let second = try ReconstructionRetrievalCompiler().compile(cut: basis.evidenceCut, query: resumed)
        XCTAssertEqual(second.records.map(\.evidenceID),
            [UUID(uuidString: "00000000-0000-0000-0000-000000009311")!])
        XCTAssertTrue(String(decoding: second.records[0].payload, as: UTF8.self)
            .contains("durable-current-1"))
        XCTAssertNotNil(resumed.cursor)
        let rebound = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: UUID(), subject: nil, retrievalQuery: resumed, offset: 1,
            maximumRecords: resumed.maximumRecords, maximumEncodedBytes: resumed.maximumEncodedBytes)
        let reboundHandle = try XCTUnwrap(registry.mintHandles(
            authority: prepared.authority, requests: [rebound]).first)
        XCTAssertNotEqual(reboundHandle.handleID, handle.handleID)
        XCTAssertNotEqual(try registry.decodeCanonicalRequest(reboundHandle).taskID, envelope.taskID)
        let forged = ReconstructionToolProjectionResult.success(payload: projection.payload, count: 1)
        XCTAssertThrowsError(try ReconstructionEvidenceReadAuthority.capture(
            request: envelope, result: forged, cut: basis.evidenceCut))
        let nextRequest = try XCTUnwrap(projection.continuationRequest)
        let siblingFocus = ReconstructionSubjectCoordinate.artifact(.init(
            occurrenceID: .init(rawValue: UUID()), contentIdentity: basis.manifest.artifacts[0].contentIdentity))
        let siblingQuery = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: query.corpusManifestSHA256, subject: nil,
            operationIDs: query.operationIDs, classifications: query.classifications,
            cursor: nextRequest.retrievalQuery?.cursor, maximumRecords: query.maximumRecords,
            maximumEncodedBytes: query.maximumEncodedBytes, focus: siblingFocus)
        let siblingContinuation = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: request.taskID, subject: nil, retrievalQuery: siblingQuery, offset: 1,
            maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
        let crossed = ReconstructionToolProjectionResult.truncated(payload: projection.payload,
            count: 1, continuationRequest: siblingContinuation)
        XCTAssertThrowsError(try ReconstructionEvidenceReadAuthority.capture(
            request: envelope, result: crossed, cut: basis.evidenceCut))
        let tampered = try ReconstructionEvidenceReadAuthority(request: envelope,
            packetSHA256: digest("e"), readEvidenceIDs: read.readEvidenceIDs, nextCursor: read.nextCursor)
        XCTAssertThrowsError(try tampered.successorQuery(cut: basis.evidenceCut, defaultQuery: query))
    }

    func testChangedEvidenceFrontierReissuesCurrentQueryWithoutOldCursor() async throws {
        let fixture = try await makeModelFixture()
        let source = try XCTUnwrap(fixture.basis.tasks.first { $0.identity.kind == .ingest })
        let subject = try XCTUnwrap(source.identity.subject)
        let basis = try basisByAddingAcceptedCurrentEvidence(fixture.basis,
            sourceTaskID: source.identity.taskID, subject: subject,
            operation: .corpusArtifactDescribe, recordCount: 2)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let original = try XCTUnwrap(prepared.requests.first)
        let query = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: basis.manifest.canonicalSHA256, subject: nil,
            operationIDs: original.retrievalQuery!.operationIDs,
            classifications: original.retrievalQuery!.classifications,
            cursor: nil, maximumRecords: 1, maximumEncodedBytes: 65_536)
        let request = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: original.taskID, subject: nil, retrievalQuery: query, offset: 0,
            maximumRecords: 1, maximumEncodedBytes: 65_536)
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority, requests: [request]).first)
        let envelope = try ReconstructionToolRegistry().decodeCanonicalRequest(handle)
        let result = try await ReconstructionEvidenceToolProjector().project(
            request: envelope, input: prepared.projectorInput)
        let read = try ReconstructionEvidenceReadAuthority.capture(
            request: envelope, result: result, cut: basis.evidenceCut)
        let changed = try basisByAddingAcceptedCurrentEvidence(fixture.basis,
            sourceTaskID: source.identity.taskID, subject: subject,
            operation: .corpusArtifactDescribe, recordCount: 1)
        XCTAssertNotEqual(changed.evidenceCut.frontierSHA256, basis.evidenceCut.frontierSHA256)
        let reissued = try read.successorQuery(cut: changed.evidenceCut, defaultQuery: query)
        XCTAssertEqual(reissued, query)
        XCTAssertNil(reissued.cursor)
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(
            cut: changed.evidenceCut,
            query: read.successorQuery(cut: basis.evidenceCut, defaultQuery: query)))
    }

    // MARK: - M3b successor pagination continuation

    func testFirstRoundWithoutQualifiedReadStartsAtOffsetZeroUnchanged() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        XCTAssertTrue(basis.toolReceipts.allSatisfy { $0.evidenceReadAuthority == nil })
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        XCTAssertEqual(prepared.readContinuation, .initial)
        XCTAssertNil(prepared.retrievalQuery.cursor)
        XCTAssertEqual(prepared.requests.map(\.operationID), [.evidenceQuery])
        let request = try XCTUnwrap(prepared.requests.first)
        XCTAssertEqual(request.offset, 0)
        XCTAssertEqual(request.retrievalQuery, prepared.retrievalQuery)
        XCTAssertEqual(Set(prepared.retrievalQuery.operationIDs), Set(MacScopeAnalysisCore.ReconstructionOperationID.allCases))
        XCTAssertEqual(Set(prepared.retrievalQuery.classifications), [.acceptedCurrent, .acceptedHistorical])
        XCTAssertEqual(prepared.retrievalQuery.maximumRecords,
            min(basis.job.budget.maxEvidenceRecords, 4_096))
        XCTAssertLessThanOrEqual(prepared.retrievalQuery.maximumEncodedBytes,
            min(Int(clamping: basis.job.budget.maxEncodedBytes), 1_048_576))
        let context = try roundRequest(Fixture(basis: basis,
            cut: cut(basis: basis, prepared: prepared, results: []),
            author: original.author, batchResultTaskID: nil)).context
        XCTAssertEqual(context.evidenceIDs, [evidenceID(0), evidenceID(1)])
    }

    func testSuccessorRoundCapturesPageTwoOnlyFactWithExplicitNextPageContinuation() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        let committed = try await commitSelectedRead(basis: basis, author: original.author,
            query: firstPage)
        let read = try XCTUnwrap(committed.read.evidenceReadAuthority)
        XCTAssertEqual(read.readEvidenceIDs, [evidenceID(0)])
        XCTAssertEqual(committed.read.terminalState, .truncated)
        let cursor = try XCTUnwrap(read.nextCursor)

        let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
        XCTAssertEqual(next.readContinuation, .nextPage(sourceReceiptID: committed.read.receiptID))
        XCTAssertEqual(next.retrievalQuery.cursor, cursor)
        XCTAssertEqual(next.retrievalQuery.maximumRecords, 1)
        let request = try XCTUnwrap(next.requests.first)
        XCTAssertEqual(request.offset, 1)
        XCTAssertEqual(request.retrievalQuery, next.retrievalQuery)
        XCTAssertNotEqual(request.taskID, committed.request.taskID)
        XCTAssertNoThrow(try ReconstructionToolRegistry().mintHandles(
            authority: next.authority, requests: next.requests))

        let captured = try await capturedSuccessorRequest(committed.successor, prepared: next)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.context.evidenceIDs, [evidenceID(1)])
        let readable = try ReconstructionReadablePromptProjection().project(captured,
            objective: .init(jobID: committed.successor.job.jobID,
                text: committed.successor.job.objective,
                sha256: committed.successor.job.objectiveSHA256))
        XCTAssertTrue(readable.userText.contains("durable-current-1"))
        XCTAssertFalse(readable.userText.contains("durable-current-0"))
    }

    func testChangedEvidenceBytesRestartSuccessorAtOffsetZeroWithExplicitReason() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let subject = try XCTUnwrap(source.identity.subject)
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: subject,
            operation: .corpusArtifactDescribe, recordCount: 2)
        // Same evidence identities and receipt, different committed payload bytes.
        let changedCut = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: subject,
            operation: .corpusArtifactDescribe, recordCount: 2, payloadPaddingBytes: 16).evidenceCut
        XCTAssertEqual(changedCut.records.map(\.evidenceID), basis.evidenceCut.records.map(\.evidenceID))
        XCTAssertNotEqual(changedCut.frontierSHA256, basis.evidenceCut.frontierSHA256)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        let committed = try await commitSelectedRead(basis: basis, author: original.author,
            query: firstPage, successorCut: changedCut)
        let staleCursor = try XCTUnwrap(committed.read.evidenceReadAuthority?.nextCursor)

        let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
        XCTAssertEqual(next.readContinuation, .restarted(sourceReceiptID: committed.read.receiptID,
            reason: .evidenceFrontierChanged))
        XCTAssertNil(next.retrievalQuery.cursor)
        XCTAssertEqual(next.requests.first?.offset, 0)
        XCTAssertNil(next.requests.first?.retrievalQuery?.cursor)
        // The stale cursor itself is never admissible against the changed cut or its authority.
        let replay = try ReconstructionEvidenceReadAuthority.copy(next.retrievalQuery, cursor: staleCursor)
        let nextTaskID = try XCTUnwrap(next.requests.first).taskID
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: changedCut, query: replay)) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
        }
        XCTAssertThrowsError(try ReconstructionToolRegistry().mintHandles(authority: next.authority,
            requests: [.init(operationID: .evidenceQuery, taskID: nextTaskID,
                subject: nil, retrievalQuery: replay, offset: 1, maximumRecords: replay.maximumRecords,
                maximumEncodedBytes: replay.maximumEncodedBytes)]))

        let captured = try await capturedSuccessorRequest(committed.successor, prepared: next)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.context.evidenceIDs.first, evidenceID(0))
    }

    func testCorpusByteChangeRejectsRetainedCursorWithExplicitReason() async throws {
        let fixture = try await makeModelFixture()
        let source = try XCTUnwrap(fixture.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(fixture.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let query = try ReconstructionEvidenceReadAuthority.copy(prepared.retrievalQuery,
            cursor: nil, maximumRecords: 1)
        let read = try await capturedRead(prepared: prepared, query: query, cut: basis.evidenceCut)
        let staleCursor = try XCTUnwrap(read.nextCursor)
        XCTAssertEqual(try read.resolveSuccessor(cut: basis.evidenceCut, defaultQuery: query).outcome,
            .nextPage)

        let old = basis.evidenceCut
        let changedManifest = digest("a")
        XCTAssertNotEqual(changedManifest, old.corpusManifestSHA256)
        let changedCut = try ReconstructionEvidenceCut(corpusManifestSHA256: changedManifest,
            records: old.records, relations: old.relations, gaps: old.gaps,
            frontierSHA256: ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: changedManifest, records: old.records,
                projectedClassificationsByEvidenceID: old.projectedClassificationsByEvidenceID,
                relations: old.relations, gaps: old.gaps,
                checkpointRevisionsByID: old.checkpointRevisionsByID),
            projectedClassificationsByEvidenceID: old.projectedClassificationsByEvidenceID,
            checkpointRevisionsByID: old.checkpointRevisionsByID)
        let changedDefault = try ReconstructionRetrievalQuery(corpusManifestSHA256: changedManifest,
            subject: nil, operationIDs: query.operationIDs, classifications: query.classifications,
            cursor: nil, maximumRecords: 1, maximumEncodedBytes: query.maximumEncodedBytes,
            focus: query.focus)
        let resolution = try read.resolveSuccessor(cut: changedCut, defaultQuery: changedDefault)
        XCTAssertEqual(resolution.outcome, .restarted(.corpusManifestChanged))
        XCTAssertEqual(resolution.query, changedDefault)
        XCTAssertNil(resolution.query.cursor)
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: changedCut,
            query: ReconstructionEvidenceReadAuthority.copy(changedDefault, cursor: staleCursor))) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
        }
    }

    func testSiblingSameAddressImageCursorIsRejected() async throws {
        let basis = try await makeRefreshOfferBasis(remainingTaskSlots: 3, recordCount: 2)
        guard case .function(let focused)? = basis.job.focus else {
            return XCTFail("Fixture must focus one exact function")
        }
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        XCTAssertEqual(prepared.retrievalQuery.focus, .function(focused))
        let query = try ReconstructionEvidenceReadAuthority.copy(prepared.retrievalQuery,
            cursor: nil, maximumRecords: 1)
        let read = try await capturedRead(prepared: prepared, query: query, cut: basis.evidenceCut)
        let cursor = try XCTUnwrap(read.nextCursor)
        XCTAssertEqual(try read.resolveSuccessor(cut: basis.evidenceCut, defaultQuery: query).outcome,
            .nextPage)

        // Another slice of the same artifact at the same virtual address is a different image.
        let siblingImage = ReconstructionImageBinding(
            binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                occurrenceID: focused.artifact.occurrenceID, selectedSliceIndex: 1),
            imageSlot: focused.image.imageSlot, selectedSliceIndex: 1,
            architecture: .x86_64, machOIdentity: nil)
        let sibling = try ReconstructionFunctionCoordinate(artifact: focused.artifact,
            image: siblingImage, analysisFingerprintSHA256: focused.analysisFingerprintSHA256,
            startAddress: focused.startAddress, endAddressExclusive: focused.endAddressExclusive,
            boundarySchemaVersion: focused.boundarySchemaVersion, functionUUIDHint: nil, symbolHint: nil)
        XCTAssertNotEqual(ReconstructionSubjectCoordinate.function(sibling), .function(focused))
        let siblingDefault = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: query.corpusManifestSHA256, subject: nil,
            operationIDs: query.operationIDs, classifications: query.classifications, cursor: nil,
            maximumRecords: 1, maximumEncodedBytes: query.maximumEncodedBytes, focus: .function(sibling))
        let resolution = try read.resolveSuccessor(cut: basis.evidenceCut, defaultQuery: siblingDefault)
        XCTAssertEqual(resolution.outcome, .restarted(.queryIdentityChanged))
        XCTAssertEqual(resolution.query, siblingDefault)
        XCTAssertNil(resolution.query.cursor)

        let forged = try ReconstructionEvidenceReadAuthority.copy(siblingDefault, cursor: cursor)
        let preparedTaskID = try XCTUnwrap(prepared.requests.first).taskID
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(
            cut: basis.evidenceCut, query: forged)) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
        }
        XCTAssertThrowsError(try ReconstructionToolRegistry().mintHandles(authority: prepared.authority,
            requests: [.init(operationID: .evidenceQuery, taskID: preparedTaskID,
                subject: nil, retrievalQuery: forged, offset: 1, maximumRecords: forged.maximumRecords,
                maximumEncodedBytes: forged.maximumEncodedBytes)]))
    }

    func testExhaustedQueryRetainsFinalPageWithExplicitEndOfCoverage() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        let pageOneCursor = try XCTUnwrap(ReconstructionRetrievalCompiler().compile(
            cut: basis.evidenceCut, query: firstPage).nextCursor)
        let finalPage = try ReconstructionEvidenceReadAuthority.copy(firstPage, cursor: pageOneCursor)
        let committed = try await commitSelectedRead(basis: basis, author: original.author,
            query: finalPage)
        let read = try XCTUnwrap(committed.read.evidenceReadAuthority)
        XCTAssertEqual(read.readEvidenceIDs, [evidenceID(1)])
        XCTAssertNil(read.nextCursor)
        XCTAssertEqual(committed.read.terminalState, .completed)

        let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
        XCTAssertEqual(next.readContinuation, .endOfCoverage(sourceReceiptID: committed.read.receiptID))
        // The final page is retained at its own cursor: no restart and no fabricated next page.
        XCTAssertEqual(next.retrievalQuery.cursor, pageOneCursor)
        XCTAssertEqual(next.requests.first?.offset, 1)
        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: committed.successor.evidenceCut, query: next.retrievalQuery)
        XCTAssertFalse(packet.hasMore)
        XCTAssertNil(packet.nextCursor)
        XCTAssertEqual(packet.records.map(\.evidenceID), [evidenceID(1)])

        let captured = try await capturedSuccessorRequest(committed.successor, prepared: next)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        // The model sees a bounded tail page, not a claim that this page is the whole cut.
        XCTAssertEqual(r2.request.context.evidenceIDs, [evidenceID(1)])
        XCTAssertNotEqual(Set(r2.request.context.evidenceIDs),
            Set(committed.successor.evidenceCut.records.map(\.evidenceID)))
    }

    // MARK: - M3b append-only cursor rebase

    func testAppendOnlyFrontierRebasesCursorToNextUndeliveredRecord() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        // A later-priority operation on the same subject sorts after every prior record.
        let appendedID = evidenceID(7)
        let committed = try await commitSelectedRead(basis: basis, author: original.author,
            query: firstPage, appending: AppendedEvidenceSpec(evidenceID: appendedID, operation: .corpusSearch,
                summary: "appended-after-cursor"))
        let read = try XCTUnwrap(committed.read.evidenceReadAuthority)
        XCTAssertEqual(read.readEvidenceIDs, [evidenceID(0)])
        let staleCursor = try XCTUnwrap(read.nextCursor)
        let successorCut = committed.successor.evidenceCut
        XCTAssertNotEqual(successorCut.frontierSHA256, basis.evidenceCut.frontierSHA256)
        XCTAssertEqual(Set(successorCut.records.map(\.evidenceID)),
            [evidenceID(0), evidenceID(1), appendedID])
        // The prior frontier is recomputed from committed rows and matches the read's fence.
        let priorCut = try XCTUnwrap(ReconstructionEvidenceReadAuthority.appendOnlyPriorCut(
            of: successorCut, jobID: basis.job.jobID,
            throughRevision: read.request.authority.checkpointRevision,
            priorFrontierSHA256: read.request.authority.evidenceFrontierSHA256))
        XCTAssertEqual(priorCut.frontierSHA256, basis.evidenceCut.frontierSHA256)
        XCTAssertEqual(priorCut.records, basis.evidenceCut.records)

        let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
        XCTAssertEqual(next.readContinuation, .rebased(sourceReceiptID: committed.read.receiptID,
            fromFrontierSHA256: basis.evidenceCut.frontierSHA256))
        let rebased = try XCTUnwrap(next.retrievalQuery.cursor)
        XCTAssertEqual(rebased.evidenceID, staleCursor.evidenceID)
        XCTAssertEqual(rebased.evidenceFrontierSHA256, successorCut.frontierSHA256)
        XCTAssertNotEqual(rebased, staleCursor)
        XCTAssertEqual(next.retrievalQuery.maximumRecords, 1)
        XCTAssertEqual(next.requests.first?.offset, 1)
        XCTAssertEqual(next.requests.first?.retrievalQuery, next.retrievalQuery)
        XCTAssertNoThrow(try ReconstructionToolRegistry().mintHandles(
            authority: next.authority, requests: next.requests))
        // The old cursor itself stays fenced to its own frontier.
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: successorCut,
            query: ReconstructionEvidenceReadAuthority.copy(next.retrievalQuery, cursor: staleCursor))) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
        }
        // Page two is the next undelivered prior record; the appended record follows it.
        let pageTwo = try ReconstructionRetrievalCompiler().compile(cut: successorCut,
            query: next.retrievalQuery)
        XCTAssertEqual(pageTwo.records.map(\.evidenceID), [evidenceID(1)])
        let pageThree = try ReconstructionRetrievalCompiler().compile(cut: successorCut,
            query: ReconstructionEvidenceReadAuthority.copy(next.retrievalQuery,
                cursor: XCTUnwrap(pageTwo.nextCursor)))
        XCTAssertEqual(pageThree.records.map(\.evidenceID), [appendedID])
        XCTAssertFalse(pageThree.hasMore)

        let captured = try await capturedSuccessorRequest(committed.successor, prepared: next)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.context.evidenceIDs, [evidenceID(1)])
        let readable = try ReconstructionReadablePromptProjection().project(captured,
            objective: .init(jobID: committed.successor.job.jobID,
                text: committed.successor.job.objective,
                sha256: committed.successor.job.objectiveSHA256))
        XCTAssertTrue(readable.userText.contains("durable-current-1"))
        XCTAssertFalse(readable.userText.contains("durable-current-0"))
    }

    func testExhaustedQueryRebasesOntoAppendedTail() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        let pageOneCursor = try XCTUnwrap(ReconstructionRetrievalCompiler().compile(
            cut: basis.evidenceCut, query: firstPage).nextCursor)
        let finalPage = try ReconstructionEvidenceReadAuthority.copy(firstPage, cursor: pageOneCursor)
        let appendedID = evidenceID(7)
        let committed = try await commitSelectedRead(basis: basis, author: original.author,
            query: finalPage, appending: AppendedEvidenceSpec(evidenceID: appendedID, operation: .corpusSearch,
                summary: "appended-tail"))
        let read = try XCTUnwrap(committed.read.evidenceReadAuthority)
        XCTAssertEqual(read.readEvidenceIDs, [evidenceID(1)])
        XCTAssertNil(read.nextCursor)

        let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
        XCTAssertEqual(next.readContinuation, .rebased(sourceReceiptID: committed.read.receiptID,
            fromFrontierSHA256: basis.evidenceCut.frontierSHA256))
        XCTAssertEqual(next.retrievalQuery.cursor?.evidenceID, evidenceID(1))
        let captured = try await capturedSuccessorRequest(committed.successor, prepared: next)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.context.evidenceIDs, [appendedID])
    }

    func testAppendedRecordSortingBeforeCursorRestartsWithoutSkipping() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        // Same subject and operation at a newer checkpoint revision sorts ahead of the cursor.
        let insertedID = evidenceID(7)
        let committed = try await commitSelectedRead(basis: basis, author: original.author,
            query: firstPage, appending: AppendedEvidenceSpec(evidenceID: insertedID,
                operation: .corpusArtifactDescribe, summary: "inserted-before-cursor"))
        let read = try XCTUnwrap(committed.read.evidenceReadAuthority)
        // The change is a proven append, yet continuing past the cursor would skip it.
        XCTAssertNotNil(try ReconstructionEvidenceReadAuthority.appendOnlyPriorCut(
            of: committed.successor.evidenceCut, jobID: basis.job.jobID,
            throughRevision: read.request.authority.checkpointRevision,
            priorFrontierSHA256: read.request.authority.evidenceFrontierSHA256))
        let order = try ReconstructionRetrievalCompiler().orderedPositions(
            cut: committed.successor.evidenceCut, query: firstPage)
        XCTAssertEqual(order.map(\.evidenceID), [insertedID, evidenceID(0), evidenceID(1)])

        let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
        XCTAssertEqual(next.readContinuation, .restarted(sourceReceiptID: committed.read.receiptID,
            reason: .evidenceInsertedBeforeCursor))
        XCTAssertNil(next.retrievalQuery.cursor)
        XCTAssertEqual(next.requests.first?.offset, 0)
        let captured = try await capturedSuccessorRequest(committed.successor, prepared: next)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.context.evidenceIDs, [insertedID, evidenceID(0), evidenceID(1)])
        let readable = try ReconstructionReadablePromptProjection().project(captured,
            objective: .init(jobID: committed.successor.job.jobID,
                text: committed.successor.job.objective,
                sha256: committed.successor.job.objectiveSHA256))
        XCTAssertTrue(readable.userText.contains("inserted-before-cursor"))
    }

    func testRemovalOrReclassificationAlongsideAppendRestartsWithFrontierChanged() async throws {
        let original = try await makeModelFixture()
        let source = try XCTUnwrap(original.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(original.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let initial = try await refreshPreparedRound(basis, suppliesRefreshProducer: false).retrievalQuery
        let firstPage = try ReconstructionEvidenceReadAuthority.copy(initial, cursor: nil, maximumRecords: 1)
        let removed = AppendedEvidenceSpec(evidenceID: evidenceID(7), operation: .corpusSearch,
            summary: "appended-after-removal", removing: [evidenceID(1)])
        let reclassified = AppendedEvidenceSpec(evidenceID: evidenceID(7), operation: .corpusSearch,
            summary: "appended-after-reclassification",
            reclassifying: [evidenceID(1): .acceptedHistorical])
        for spec in [removed, reclassified] {
            let committed = try await commitSelectedRead(basis: basis, author: original.author,
                query: firstPage, appending: spec)
            let read = try XCTUnwrap(committed.read.evidenceReadAuthority)
            let staleCursor = try XCTUnwrap(read.nextCursor)
            XCTAssertNil(try ReconstructionEvidenceReadAuthority.appendOnlyPriorCut(
                of: committed.successor.evidenceCut, jobID: basis.job.jobID,
                throughRevision: read.request.authority.checkpointRevision,
                priorFrontierSHA256: read.request.authority.evidenceFrontierSHA256))
            let next = try await refreshPreparedRound(committed.successor, suppliesRefreshProducer: false)
            XCTAssertEqual(next.readContinuation, .restarted(sourceReceiptID: committed.read.receiptID,
                reason: .evidenceFrontierChanged))
            XCTAssertNil(next.retrievalQuery.cursor)
            XCTAssertEqual(next.requests.first?.offset, 0)
            XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(
                cut: committed.successor.evidenceCut,
                query: ReconstructionEvidenceReadAuthority.copy(next.retrievalQuery, cursor: staleCursor))) {
                XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
            }
        }
    }

    func testCorpusChangeAlongsideAppendRestartsWithCorpusManifestChanged() async throws {
        let fixture = try await makeModelFixture()
        let source = try XCTUnwrap(fixture.basis.tasks.first { $0.identity.kind == .ingest })
        let basis = try basisByAddingAcceptedCurrentEvidence(fixture.basis,
            sourceTaskID: source.identity.taskID, subject: XCTUnwrap(source.identity.subject),
            operation: .corpusArtifactDescribe, recordCount: 2)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let query = try ReconstructionEvidenceReadAuthority.copy(prepared.retrievalQuery,
            cursor: nil, maximumRecords: 1)
        let read = try await capturedRead(prepared: prepared, query: query, cut: basis.evidenceCut)
        let staleCursor = try XCTUnwrap(read.nextCursor)
        let spec = AppendedEvidenceSpec(evidenceID: evidenceID(7), operation: .corpusSearch,
            summary: "appended-after-corpus-change")
        let revision = read.request.authority.checkpointRevision + 1
        // Control: the identical append under the unchanged corpus is rebased.
        let appendedCut = try cutByAppendingEvidence(basis.evidenceCut, spec: spec,
            checkpointID: UUID(), revision: revision)
        XCTAssertEqual(try read.resolveSuccessor(cut: appendedCut, defaultQuery: query).outcome,
            .rebased(fromFrontierSHA256: basis.evidenceCut.frontierSHA256))

        let changedManifest = digest("a")
        XCTAssertNotEqual(changedManifest, basis.evidenceCut.corpusManifestSHA256)
        let changedCut = try cutByAppendingEvidence(basis.evidenceCut, spec: spec,
            checkpointID: UUID(), revision: revision, corpusManifestSHA256: changedManifest)
        let changedDefault = try ReconstructionRetrievalQuery(corpusManifestSHA256: changedManifest,
            subject: nil, operationIDs: query.operationIDs, classifications: query.classifications,
            cursor: nil, maximumRecords: 1, maximumEncodedBytes: query.maximumEncodedBytes,
            focus: query.focus)
        let resolution = try read.resolveSuccessor(cut: changedCut, defaultQuery: changedDefault)
        XCTAssertEqual(resolution.outcome, .restarted(.corpusManifestChanged))
        XCTAssertEqual(resolution.query, changedDefault)
        XCTAssertNil(resolution.query.cursor)
        XCTAssertThrowsError(try ReconstructionRetrievalCompiler().compile(cut: changedCut,
            query: ReconstructionEvidenceReadAuthority.copy(changedDefault, cursor: staleCursor))) {
            XCTAssertEqual($0 as? ReconstructionRetrievalError, .cursorFenceMismatch)
        }
    }

    // MARK: - M3b transient native projection

    func testNativeOnlyFactAppearsTransientlyInCapturedR2Request() async throws {
        let fixture = try await makeNativeTransientBasis()
        let function = try XCTUnwrap(fixture.functions.first)
        let nativeTask = try XCTUnwrap(fixture.nativeTasks.first)
        let registry = ReconstructionTransientNativePublicationRegistry()
        let older = try await publishNative(registry, basis: fixture.basis, task: nativeTask,
            execution: nativeExecution(for: function, pseudocode: "int older(void) { return OLD_GENERATION_ONLY; }"))
        let newer = try await publishNative(registry, basis: fixture.basis, task: nativeTask,
            execution: nativeExecution(for: function, pseudocode: Self.nativeOnlyText))
        XCTAssertGreaterThan(newer.generation, older.generation)
        // The fact exists only in the admitted native result, never in committed evidence.
        XCTAssertFalse(fixture.basis.evidenceCut.records.contains {
            String(decoding: $0.payload, as: UTF8.self).contains(Self.nativeOnlyMarker)
        })

        let prepared = try await transientPreparedRound(fixture.basis, registry: registry)
        let transient = try XCTUnwrap(prepared.transientAnalysis)
        XCTAssertEqual(transient.jobID, fixture.basis.job.jobID)
        XCTAssertEqual(transient.checkpointRevision, fixture.basis.checkpoint.revision)
        XCTAssertEqual(transient.evidenceFrontierSHA256, fixture.basis.evidenceCut.frontierSHA256)
        let fact = try XCTUnwrap(transient.facts.first)
        XCTAssertEqual(transient.facts.count, 1)
        XCTAssertEqual(fact.subject, function)
        XCTAssertEqual(fact.sourceTaskID, nativeTask.identity.taskID)
        XCTAssertEqual(fact.publicationGeneration, newer.generation)
        XCTAssertEqual(fact.providerIdentitySHA256, newer.providerIdentitySHA256)
        XCTAssertEqual(fact.nativeRequestSHA256, newer.nativeRequestSHA256)
        XCTAssertEqual(fact.analysisInputFingerprintSHA256, function.analysisFingerprintSHA256)
        XCTAssertEqual(fact.pseudocode, Self.nativeOnlyText)
        XCTAssertLessThanOrEqual(transient.usedBytes, transient.budgetBytes)
        // The older publication of the same function is explicitly superseded, never shown.
        XCTAssertEqual(transient.omissions, [.init(subjectSHA256: try subjectSHA256(function),
            publicationGeneration: older.generation, reason: .stale)])

        let captured = try await capturedSuccessorRequest(fixture.basis, prepared: prepared)
        guard case .roundR2(let r2) = captured else { return XCTFail("Expected actual R2 request") }
        XCTAssertEqual(r2.request.transientAnalysis, transient)
        XCTAssertTrue(Set(r2.request.context.evidenceIDs).isDisjoint(with: transient.facts.map(\.factID)))
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let wire = try codec.encodeRoundRequestR2(r2, requestID: UUID())
        guard case .roundR2(_, let decoded) = try codec.decodeRequest(wire) else {
            return XCTFail("Expected R2 wire round trip")
        }
        XCTAssertEqual(decoded, r2)
        // R1 stays byte-identical and cannot carry transient semantics.
        XCTAssertThrowsError(try codec.encodeRoundRequest(r2.request, requestID: UUID()))

        let readable = try ReconstructionReadablePromptProjection().projectR2(captured)
        XCTAssertTrue(readable.userText.contains(Self.nativeOnlyMarker))
        XCTAssertFalse(readable.userText.contains("OLD_GENERATION_ONLY"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: readable.userJSON) as? [String: Any])
        let section = try XCTUnwrap(root["transientAnalysis"] as? [String: Any])
        XCTAssertEqual(section["status"] as? String, "transient-not-evidence")
        let projection = try XCTUnwrap(section["projection"] as? [String: Any])
        let facts = try XCTUnwrap(projection["facts"] as? [[String: Any]])
        XCTAssertEqual(facts.first?["transient"] as? Bool, true)
        XCTAssertEqual(facts.first?["citable"] as? Bool, false)
        let authority = try XCTUnwrap(root["authorityRequestProjection"] as? [String: Any])
        XCTAssertNil(authority["transientAnalysis"])
        let readableContext = try XCTUnwrap(root["readableContext"] as? [String: Any])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: readableContext),
            as: UTF8.self).contains(Self.nativeOnlyMarker))
    }

    func testStaleBytesNativeResultIsOmittedWithReason() async throws {
        let fixture = try await makeNativeTransientBasis()
        let function = try XCTUnwrap(fixture.functions.first)
        let nativeTask = try XCTUnwrap(fixture.nativeTasks.first)
        let registry = ReconstructionTransientNativePublicationRegistry()
        // Native output was produced over different bytes than the committed coordinate.
        let stale = try await publishNative(registry, basis: fixture.basis, task: nativeTask,
            execution: nativeExecution(for: function, pseudocode: Self.nativeOnlyText,
                analysisFingerprintSHA256: digest("e")))

        let prepared = try await transientPreparedRound(fixture.basis, registry: registry)
        let transient = try XCTUnwrap(prepared.transientAnalysis)
        XCTAssertTrue(transient.facts.isEmpty)
        XCTAssertEqual(transient.usedBytes, 0)
        XCTAssertEqual(transient.omissions, [.init(subjectSHA256: try subjectSHA256(function),
            publicationGeneration: stale.generation, reason: .stale)])
        let captured = try await capturedSuccessorRequest(fixture.basis, prepared: prepared)
        let readable = try ReconstructionReadablePromptProjection().projectR2(captured)
        XCTAssertFalse(readable.userText.contains(Self.nativeOnlyMarker))
        XCTAssertTrue(readable.userText.contains("\"reason\":\"stale\""))

        // A publication admitted against a different (later) cut is stale at this cut as well.
        let movedRegistry = ReconstructionTransientNativePublicationRegistry()
        let moved = try await publishNative(movedRegistry, basis: fixture.basis, task: nativeTask,
            execution: nativeExecution(for: function, pseudocode: Self.nativeOnlyText),
            checkpointRevision: fixture.basis.checkpoint.revision + 1)
        let movedPrepared = try await transientPreparedRound(fixture.basis, registry: movedRegistry)
        let movedTransient = try XCTUnwrap(movedPrepared.transientAnalysis)
        XCTAssertTrue(movedTransient.facts.isEmpty)
        XCTAssertEqual(movedTransient.omissions, [.init(subjectSHA256: try subjectSHA256(function),
            publicationGeneration: moved.generation, reason: .stale)])
    }

    func testSiblingSameAddressImageNativeResultIsRejected() async throws {
        let fixture = try await makeNativeTransientBasis()
        let function = try XCTUnwrap(fixture.functions.first)
        let siblingImage = ReconstructionImageBinding(
            binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                occurrenceID: function.artifact.occurrenceID, selectedSliceIndex: 1),
            imageSlot: function.image.imageSlot, selectedSliceIndex: 1,
            architecture: .x86_64, machOIdentity: nil)
        let sibling = try ReconstructionFunctionCoordinate(artifact: function.artifact,
            image: siblingImage, analysisFingerprintSHA256: function.analysisFingerprintSHA256,
            startAddress: function.startAddress, endAddressExclusive: function.endAddressExclusive,
            boundarySchemaVersion: function.boundarySchemaVersion, functionUUIDHint: nil, symbolHint: nil)
        XCTAssertNotEqual(sibling, function)
        let siblingTask = try task(id: UUID(), jobID: fixture.basis.job.jobID, kind: .decompileNative,
            subject: .function(sibling), dependencies: [], state: .completed)
        let registry = ReconstructionTransientNativePublicationRegistry()
        let published = try await publishNative(registry, basis: fixture.basis, task: siblingTask,
            execution: nativeExecution(for: sibling, pseudocode: Self.nativeOnlyText))

        let prepared = try await transientPreparedRound(fixture.basis, registry: registry)
        let transient = try XCTUnwrap(prepared.transientAnalysis)
        XCTAssertTrue(transient.facts.isEmpty)
        XCTAssertEqual(transient.omissions, [.init(subjectSHA256: try subjectSHA256(function),
            publicationGeneration: published.generation, reason: .mismatchedImage)])

        // A result for the exact task whose execution names another image is rejected too.
        let nativeTask = try XCTUnwrap(fixture.nativeTasks.first)
        let crossed = ReconstructionTransientNativePublicationRegistry()
        let crossedPublication = try await publishNative(crossed, basis: fixture.basis, task: nativeTask,
            execution: nativeExecution(for: function, pseudocode: Self.nativeOnlyText,
                functionID: ReconstructionReboundFunctionAuthority.expectedFunctionID(for: sibling)))
        let crossedPrepared = try await transientPreparedRound(fixture.basis, registry: crossed)
        let crossedTransient = try XCTUnwrap(crossedPrepared.transientAnalysis)
        XCTAssertTrue(crossedTransient.facts.isEmpty)
        XCTAssertEqual(crossedTransient.omissions, [.init(subjectSHA256: try subjectSHA256(function),
            publicationGeneration: crossedPublication.generation, reason: .mismatchedImage)])
        let captured = try await capturedSuccessorRequest(fixture.basis, prepared: crossedPrepared)
        XCTAssertFalse(try ReconstructionReadablePromptProjection().projectR2(captured)
            .userText.contains(Self.nativeOnlyMarker))
    }

    func testTransientBudgetOverflowRecordsDeterministicOmission() async throws {
        let fixture = try await makeNativeTransientBasis(functionCount: 2, focused: false)
        let large = String(repeating: "x", count: 6_000)
        func project(reversed: Bool) async throws -> ReconstructionTransientAnalysis {
            let registry = ReconstructionTransientNativePublicationRegistry()
            let pairs = Array(zip(fixture.functions, fixture.nativeTasks))
            for (function, task) in reversed ? Array(pairs.reversed()) : pairs {
                try await publishNative(registry, basis: fixture.basis, task: task,
                    execution: nativeExecution(for: function, pseudocode: "/* \(large) */"))
            }
            let prepared = try await transientPreparedRound(fixture.basis, registry: registry,
                budgetBytes: 9_000)
            return try XCTUnwrap(prepared.transientAnalysis)
        }
        let first = try await project(reversed: false)
        let again = try await project(reversed: false)
        let reversed = try await project(reversed: true)
        XCTAssertEqual(first, again)
        for transient in [first, reversed] {
            XCTAssertEqual(transient.budgetBytes, 9_000)
            XCTAssertLessThanOrEqual(transient.usedBytes, transient.budgetBytes)
            // Address order, not publication order, decides which fact fits.
            XCTAssertEqual(transient.facts.map(\.subject), [fixture.functions[0]])
            XCTAssertEqual(transient.omissions.map(\.reason), [.budget])
            XCTAssertEqual(transient.omissions.first?.subjectSHA256,
                try subjectSHA256(fixture.functions[1]))
        }
        // A maximal context leaves no transient budget; an empty one keeps the fixed ceiling.
        XCTAssertEqual(ReconstructionTransientNativeProjector.budgetBytes(
            contextCanonicalBytes: ReconstructionReadablePromptProjection.maximumCanonicalContextBytes), 0)
        XCTAssertEqual(ReconstructionTransientNativeProjector.budgetBytes(contextCanonicalBytes: 0),
            ReconstructionTransientAnalysis.maximumBudgetBytes)
        let starved = try await transientPreparedRound(fixture.basis,
            registry: ReconstructionTransientNativePublicationRegistry(), budgetBytes: 0)
        // Committed native tasks without an admitted publication are explicitly unavailable.
        XCTAssertEqual(try XCTUnwrap(starved.transientAnalysis).omissions.map(\.reason),
            [.unavailable, .unavailable])
    }

    func testFinalSynthesisCitingTransientNativeFactIsRejected() async throws {
        let fixture = try await makeNativeTransientBasis()
        let registry = ReconstructionTransientNativePublicationRegistry()
        try await publishNative(registry, basis: fixture.basis,
            task: try XCTUnwrap(fixture.nativeTasks.first),
            execution: nativeExecution(for: try XCTUnwrap(fixture.functions.first),
                pseudocode: Self.nativeOnlyText))
        let prepared = try await transientPreparedRound(fixture.basis, registry: registry)
        let factID = try XCTUnwrap(prepared.transientAnalysis?.facts.first?.factID)
        let context = try ReconstructionContextCompiler().compile(cut: fixture.basis.evidenceCut,
            query: prepared.retrievalQuery, allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories)
        XCTAssertFalse(context.evidenceIDs.contains(factID))
        let durable = try XCTUnwrap(context.evidenceIDs.first)
        let request = ReconstructionFinalSynthesisRequest(jobID: fixture.basis.job.jobID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: fixture.basis.evidenceCut.frontierSHA256,
            acceptedEvidenceIDs: context.evidenceIDs, context: context)
        let planAuthor = author()
        XCTAssertTrue(planAuthor.finalCandidateIsValid(.init(kind: .synthesis, text: "durable answer",
            evidenceIDs: [durable]), for: request))
        XCTAssertFalse(planAuthor.finalCandidateIsValid(.init(kind: .synthesis, text: "native answer",
            evidenceIDs: [factID]), for: request))
        XCTAssertFalse(planAuthor.finalCandidateIsValid(.init(kind: .synthesis, text: "mixed answer",
            evidenceIDs: ReconstructionValidation.sortedUUIDs([durable, factID])), for: request))
    }

    func testTransientNativeRoundCommitPersistsNoNativeBytes() async throws {
        let fixture = try await makeNativeTransientBasis()
        let registry = ReconstructionTransientNativePublicationRegistry()
        try await publishNative(registry, basis: fixture.basis,
            task: try XCTUnwrap(fixture.nativeTasks.first),
            execution: nativeExecution(for: try XCTUnwrap(fixture.functions.first),
                pseudocode: Self.nativeOnlyText))
        let before = await registry.publications(workspaceID: fixture.basis.workspaceID,
            jobID: fixture.basis.job.jobID)
        let prepared = try await transientPreparedRound(fixture.basis, registry: registry)
        let transient = try XCTUnwrap(prepared.transientAnalysis)
        XCTAssertEqual(prepared.evidenceCut, fixture.basis.evidenceCut)

        let commit = Fixture(basis: fixture.basis,
            cut: cut(basis: fixture.basis, prepared: prepared, results: []),
            author: author(), batchResultTaskID: nil)
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority, requests: prepared.requests).first)
        let outcome = inference(fixture: commit, selectedHandleIDs: [handle.handleID],
            disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: commit, inference: outcome)
        guard case .roundR2(let r2) = inputs.requestAuthority.request else {
            return XCTFail("Expected the R2 request that carried transient semantics")
        }
        XCTAssertEqual(r2.request.transientAnalysis, transient)
        let planner = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(basis: fixture.basis,
                prepared: prepared),
            receiptAuthor: commit.author)
        let plan = try await planner.makeCommitPlan(cut: commit.cut,
            lease: lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
            inference: outcome, executions: [toolExecution(handle: handle, fixture: commit)])
        let mutation = try XCTUnwrap(plan.mutation)
        // The durable mutation is the only database/package input: it binds the request digest
        // but carries no native text, fact identity or transient section.
        let encoder = JSONEncoder()
        var durable = Data()
        durable.append(try encoder.encode(mutation.evidence))
        durable.append(try encoder.encode(mutation.toolReceipts))
        durable.append(try encoder.encode(mutation.modelReceipts))
        durable.append(try encoder.encode(mutation.finalResults))
        durable.append(try encoder.encode(mutation.newTasks))
        durable.append(try encoder.encode(mutation.successorCheckpoint))
        let durableText = String(decoding: durable, as: UTF8.self)
        XCTAssertFalse(durableText.contains(Self.nativeOnlyMarker))
        XCTAssertFalse(durableText.contains(ReconstructionTransientAnalysis.domain))
        for fact in transient.facts {
            XCTAssertFalse(durableText.contains(fact.factID.uuidString))
            XCTAssertFalse(durableText.contains(fact.factID.uuidString.lowercased()))
            XCTAssertFalse(mutation.evidence.contains { $0.evidenceID == fact.factID })
        }
        XCTAssertTrue(mutation.evidence.allSatisfy {
            !String(decoding: $0.payload, as: UTF8.self).contains(Self.nativeOnlyMarker)
        })
        // Projection and commit planning leave the in-memory publications untouched.
        let after = await registry.publications(workspaceID: fixture.basis.workspaceID,
            jobID: fixture.basis.job.jobID)
        XCTAssertEqual(after, before)
    }

    func testLegacyToolReceiptEncodingAndDigestRemainUnextended() async throws {
        struct LegacyEncoding: Encodable {
            let receiptID: UUID
            let jobID: UUID
            let taskID: UUID
            let checkpointRevision: UInt64
            let requestIdentitySHA256: String
            let producer: ReconstructionProducerIdentity
            let terminalState: ReconstructionReceiptTerminalState
            let outputEvidenceIDs: [UUID]
            let diagnostic: ReconstructionDiagnostic?
            let canonicalSHA256: String?
            let schemaVersion: Int?
        }
        let fixture = try await makeModelFixture(resolvableGapAuthority: true)
        let receipt = try XCTUnwrap(fixture.basis.toolReceipts.first)
        let legacy = LegacyEncoding(receiptID: receipt.receiptID, jobID: receipt.jobID,
            taskID: receipt.taskID, checkpointRevision: receipt.checkpointRevision,
            requestIdentitySHA256: receipt.requestIdentitySHA256, producer: receipt.producer,
            terminalState: receipt.terminalState, outputEvidenceIDs: receipt.outputEvidenceIDs,
            diagnostic: receipt.diagnostic, canonicalSHA256: receipt.canonicalSHA256,
            schemaVersion: nil)
        let bytes = try ReconstructionCanonicalJSON.encode(legacy)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(receipt), bytes)
        XCTAssertEqual(try JSONDecoder().decode(ReconstructionToolReceipt.self, from: bytes), receipt)
        let preimage = LegacyEncoding(receiptID: receipt.receiptID, jobID: receipt.jobID,
            taskID: receipt.taskID, checkpointRevision: receipt.checkpointRevision,
            requestIdentitySHA256: receipt.requestIdentitySHA256, producer: receipt.producer,
            terminalState: receipt.terminalState, outputEvidenceIDs: receipt.outputEvidenceIDs,
            diagnostic: receipt.diagnostic, canonicalSHA256: nil, schemaVersion: 1)
        XCTAssertEqual(try ReconstructionCanonicalJSON.sha256(of: preimage), receipt.canonicalSHA256)
        XCTAssertNil(receipt.evidenceReadAuthority)
    }

    func testFirstBatchFunctionEvidenceMatchesRecapturedClassificationAndFrontier() async throws {
        let fixture = try await makeBatchFixture(functionBatch: true)
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(basis: fixture.basis,
                prepared: fixture.cut.prepared), receiptAuthor: fixture.author)
        let proposed = try await builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let plan = try XCTUnwrap(proposed)
        let mutation = try XCTUnwrap(plan.mutation)
        let evidence = try XCTUnwrap(mutation.evidence.first)
        guard case .function = evidence.subject else { return XCTFail("Expected exact function evidence") }
        XCTAssertNil(fixture.basis.freshnessAuthority.currentFacetFingerprints[evidence.subject])
        XCTAssertEqual(mutation.freshnessAuthority.currentFacetFingerprints[evidence.subject], [:])
        let projection = try ReconstructionEvidenceProjector().project(records: mutation.evidence,
            relations: [], authority: mutation.freshnessAuthority)
        XCTAssertEqual(projection.records.first?.classification, .acceptedCurrent)
        // Database recapture establishes explicit facet authority from committed exact subjects.
        let recaptured = try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256,
            currentArtifacts: fixture.basis.freshnessAuthority.currentArtifacts,
            currentImages: fixture.basis.freshnessAuthority.currentImages,
            currentFacetFingerprints: [evidence.subject: [:]])
        let recapturedProjection = try ReconstructionEvidenceProjector().project(
            records: mutation.evidence, relations: [], authority: recaptured)
        let classifications = Dictionary(uniqueKeysWithValues: recapturedProjection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256, records: mutation.evidence,
            projectedClassificationsByEvidenceID: classifications, relations: [], gaps: [],
            checkpointRevisionsByID: [mutation.successorCheckpoint.checkpointID: plan.successorRevision])
        XCTAssertEqual(frontier, mutation.successorCheckpoint.evidenceFrontierSHA256)
    }

    func testBatchFunctionEvidenceCannotOverwriteExistingFacetAuthority() async throws {
        let fixture = try await makeBatchFixture(functionBatch: true, functionFacets: ["authored": digest("f")])
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(basis: fixture.basis,
                prepared: fixture.cut.prepared), receiptAuthor: fixture.author)
        do {
            _ = try await builder.makePreInferenceCommitPlan(cut: fixture.cut)
            XCTFail("Empty-facet batch evidence must not overwrite existing semantic facet authority")
        } catch { /* The existing evidence acceptance/conflict boundary rejects this mismatch. */ }
    }

    func testFailedBatchFunctionDoesNotMintFacetAuthority() async throws {
        let fixture = try await makeBatchFixture(functionBatch: true)
        let original = try XCTUnwrap(fixture.cut.batchTerminalResults.first)
        let failed = ReconstructionTerminalTaskResult(jobID: original.jobID, taskID: original.taskID,
            checkpointID: original.checkpointID, checkpointRevision: original.checkpointRevision,
            corpusManifestSHA256: original.corpusManifestSHA256, outcome: .failed)
        let failedCut = cut(basis: fixture.basis, prepared: fixture.cut.prepared, results: [failed])
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(basis: fixture.basis,
                prepared: fixture.cut.prepared), receiptAuthor: fixture.author)
        let proposed = try await builder.makePreInferenceCommitPlan(cut: failedCut)
        let mutation = try XCTUnwrap(proposed?.mutation)
        XCTAssertTrue(mutation.freshnessAuthority.currentFacetFingerprints.isEmpty)
        XCTAssertTrue(mutation.evidence.isEmpty)
        XCTAssertTrue(mutation.evidence.allSatisfy { $0.classification != .acceptedCurrent })
    }

    func testPreparedFocusedRefreshOffersOneExactFunctionAndOrdinaryNilSubjectQuery() async throws {
        let basis = try await makeRefreshOfferBasis(remainingTaskSlots: 4)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: true)
        XCTAssertEqual(prepared.requests.map(\.operationID), [.evidenceQuery, .analysisMacScopeRefresh])
        let query = try XCTUnwrap(prepared.requests.first)
        let refresh = try XCTUnwrap(prepared.requests.last)
        XCTAssertNil(query.subject)
        XCTAssertNotNil(query.retrievalQuery)
        XCTAssertEqual(refresh.taskID, query.taskID)
        XCTAssertEqual(refresh.subject, basis.job.focus)
        XCTAssertNil(refresh.retrievalQuery)
        XCTAssertEqual(refresh.offset, 0)
        XCTAssertEqual(refresh.maximumRecords, 1)
        let handles = try ReconstructionToolRegistry().mintHandles(authority: prepared.authority,
            requests: prepared.requests)
        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles.last?.operationID, .analysisMacScopeRefresh)
        guard case .function(let function)? = refresh.subject else {
            return XCTFail("Prepared demand must bind the committed exact function")
        }
        let enumeration = try ReconstructionMacScopeAnalysisDemand.enumerationTask(
            for: function, tasks: basis.tasks, evidenceCut: basis.evidenceCut)
        XCTAssertEqual(enumeration.state, .completed)
        XCTAssertEqual(prepared.projectorInput.producersByOperation[.analysisMacScopeRefresh]?.operationIdentity,
            ReconstructionOperationID.analysisMacScopeRefresh.rawValue)
        let handle = try XCTUnwrap(handles.last)
        let executions = try await ReconstructionToolBroker(projectors: [ReconstructionDecompilerToolProjector()])
            .execute(selectedHandleIDs: [handle.handleID], offeredHandles: handles,
                input: prepared.projectorInput)
        let execution = try XCTUnwrap(executions.first)
        XCTAssertEqual(execution.result.outcome, .success)
        XCTAssertTrue(execution.acceptedEvidence.isEmpty)
        XCTAssertTrue(execution.receipt.outputEvidenceIDs.isEmpty)
        XCTAssertEqual(execution.result.payload,
            try ReconstructionMacScopeAnalysisDemand.acknowledgement(
                for: ReconstructionToolRegistry().decodeCanonicalRequest(handle)))
    }

    func testPreparedRefreshRequiresFourSlotsExplicitFocusAndOptionalProducer() async throws {
        for (slots, focus, producer, expected) in [
            (3, true, true, false), (4, true, true, true),
            (4, false, true, false), (4, true, false, false),
        ] {
            let basis = try await makeRefreshOfferBasis(remainingTaskSlots: slots, focused: focus)
            let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: producer)
            XCTAssertEqual(prepared.requests.contains { $0.operationID == .analysisMacScopeRefresh },
                expected, "slots=\(slots) focus=\(focus) producer=\(producer)")
            XCTAssertEqual(prepared.requests.filter { $0.operationID == .evidenceQuery }.count, 1)
        }
    }

    func testPreparedRefreshDoesNotOfferAnAlreadyScheduledExactFunctionAgain() async throws {
        let basis = try await makeRefreshOfferBasis(remainingTaskSlots: 4, alreadyScheduled: true)
        let prepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: true)
        XCTAssertEqual(prepared.requests.map(\.operationID), [.evidenceQuery])
    }

    func testRefreshDemandRejectsTamperedAcknowledgementAndFinalBypass() async throws {
        for disposition in [ReconstructionInferenceDisposition.continue, .blocked, .sufficientEvidence] {
            let fixture = try await makeModelFixture(refreshRequest: true)
            let handles = try ReconstructionToolRegistry().mintHandles(
                authority: fixture.cut.prepared.authority, requests: fixture.cut.prepared.requests)
            let handle = try XCTUnwrap(handles.first { $0.operationID == .analysisMacScopeRefresh })
            // Build ordinary receipt-free structural authority independently; the demand must
            // pass its own author boundary before it can augment that plan.
            let baseResponse = inference(fixture: fixture, selectedHandleIDs: [], disposition: disposition)
            let inputs = try modelAuthorInputs(fixture: fixture, inference: baseResponse)
            let response = inference(fixture: fixture, selectedHandleIDs: [handle.handleID],
                disposition: disposition)
            let execution = try toolExecution(handle: handle, fixture: fixture)
            await assertThrows(.invalidToolExecution) {
                try await fixture.author.makeModelCommitPlan(cut: fixture.cut, basis: fixture.basis,
                    basePlan: inputs.basePlan, lease: try self.lease(providerRevision: 1),
                    requestAuthority: inputs.requestAuthority, inference: response, executions: [execution])
            }
        }
    }

    func testPreparedObjectiveIsCapturedFromCommittedJobAndBoundToR2Receipt() async throws {
        let fixture = try await makeModelFixture()
        let objective = try XCTUnwrap(fixture.cut.prepared.objective)
        XCTAssertEqual(objective.jobID, fixture.basis.job.jobID)
        XCTAssertEqual(objective.text, fixture.basis.job.objective)
        XCTAssertEqual(objective.sha256, fixture.basis.job.objectiveSHA256)
        XCTAssertNil(objective.sourceProfileID)
        let response = inference(fixture: fixture, selectedHandleIDs: [], disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: response)
        guard case .roundR2(let request) = inputs.requestAuthority.request else {
            return XCTFail("Production preparation must create an R2 request authority.")
        }
        XCTAssertEqual(inputs.requestAuthority.requestIdentitySHA256,
            try ReconstructionCanonicalJSON.sha256(of: request))
        let plan = try await fixture.author.makeModelCommitPlan(
            cut: fixture.cut, basis: fixture.basis, basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
            inference: response, executions: []
        )
        XCTAssertEqual(plan.mutation?.modelReceipts.first?.producer.protocolIdentity,
            Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
    }

    func testFixedSourceSufficientEvidencePersistsCompletedR2Receipt() async throws {
        let profile = ReconstructionSourceExecutionTaskContract.profileID
        let fixture = try await makeModelFixture(sourceProfileID: profile)
        XCTAssertEqual(fixture.cut.prepared.objective?.sourceProfileID, profile)
        let response = inference(fixture: fixture, selectedHandleIDs: [], disposition: .sufficientEvidence)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: response)
        XCTAssertTrue(fixture.cut.prepared.sourceOracleRequested)
        XCTAssertNil(fixture.cut.prepared.sourceOracleFunction)
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(
                basis: fixture.basis, prepared: fixture.cut.prepared),
            receiptAuthor: fixture.author)
        // With no captured original target, production preserves the completed provider
        // receipt and pauses for evidence rather than scheduling a fabricated oracle.
        let plan = try await builder.makeCommitPlan(
            cut: fixture.cut, lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority, inference: response, executions: [])
        XCTAssertEqual(plan.disposition, .paused(.evidenceStalled))
        XCTAssertEqual(plan.mutation?.taskTransitions.count, 3)
        XCTAssertTrue(plan.mutation?.taskTransitions.allSatisfy {
            $0.successorState == .completed
        } == true)
        XCTAssertFalse(plan.mutation?.newTasks.contains { $0.identity.kind == .executeSource } == true)
        let receipt = try XCTUnwrap(plan.mutation?.modelReceipts.first)
        XCTAssertEqual(plan.mutation?.modelReceipts.count, 1)
        XCTAssertEqual(receipt.terminalState, .completed)
        XCTAssertEqual(receipt.receiptID, inputs.requestAuthority.expectedRequestID)
        XCTAssertEqual(receipt.requestIdentitySHA256, inputs.requestAuthority.requestIdentitySHA256)
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
    }

    func testFixedSourceCompletedProviderReceiptSurvivesAppValidationFailure() async throws {
        let fixture = try await makeModelFixture(
            sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        let response = inference(fixture: fixture, selectedHandleIDs: [], disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: response)
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(
                basis: fixture.basis, prepared: fixture.cut.prepared),
            receiptAuthor: fixture.author)
        let plan = try await builder.makeFailedModelPlan(
            cut: fixture.cut, lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority, reason: .malformedOutput)
        let receipt = try XCTUnwrap(plan.mutation?.modelReceipts.first)
        XCTAssertEqual(plan.disposition, .failed)
        XCTAssertEqual(receipt.terminalState, .completed)
        XCTAssertEqual(receipt.receiptID, inputs.requestAuthority.expectedRequestID)
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
    }

    func testFixedSourceFinalRequestPersistsReceiptWithDurableProfile() async throws {
        let profile = ReconstructionSourceExecutionTaskContract.profileID
        let fixture = try await makeFinalFixture(sourceProfileID: profile)
        let inputs = try finalAuthorInputs(fixture: fixture,
            candidate: ReconstructionFinalSynthesisCandidate(kind: .insufficientEvidence,
                text: "No accepted current evidence supports a synthesis.", evidenceIDs: []))
        guard case .finalSynthesisR2(let value) = inputs.requestAuthority.request else {
            return XCTFail("Expected a fixed-source R2 final request.")
        }
        XCTAssertEqual(value.objective.sourceProfileID, profile)
        let plan = try await fixture.author.makeFinalCommitPlan(
            cut: fixture.cut, basis: fixture.basis, basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
            synthesis: inputs.synthesis)
        let receipt = try XCTUnwrap(plan.mutation?.modelReceipts.first)
        XCTAssertEqual(receipt.requestIdentitySHA256, inputs.requestAuthority.requestIdentitySHA256)
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
    }

    func testReceiptRejectsMissingOrUncommittedSourceProfile() async throws {
        let profile = ReconstructionSourceExecutionTaskContract.profileID
        for durableProfile in [nil, profile] as [String?] {
            let fixture = try await makeModelFixture(sourceProfileID: durableProfile)
            let original = fixture.cut.prepared
            let forgedObjective = try ReconstructionRequestObjective(
                jobID: fixture.basis.job.jobID, text: fixture.basis.job.objective,
                sha256: fixture.basis.job.objectiveSHA256,
                sourceProfileID: durableProfile == nil ? profile : nil)
            let forged = ReconstructionPreparedModelRound(
                roundID: original.roundID, evidenceCut: original.evidenceCut,
                retrievalQuery: original.retrievalQuery, allowedGapSubjects: original.allowedGapSubjects,
                allowedGapCategories: original.allowedGapCategories, authority: original.authority,
                requests: original.requests, projectorInput: original.projectorInput,
                sourceOracleFunction: original.sourceOracleFunction,
                sourceOracleRequested: original.sourceOracleRequested, objective: forgedObjective,
                readContinuation: original.readContinuation, transientAnalysis: original.transientAnalysis)
            let substituted = Fixture(basis: fixture.basis,
                cut: cut(basis: fixture.basis, prepared: forged, results: []),
                author: fixture.author, batchResultTaskID: nil)
            let response = inference(fixture: substituted, selectedHandleIDs: [], disposition: .continue)
            let inputs = try modelAuthorInputs(fixture: substituted, inference: response)
            await assertThrows(.invalidCommittedAuthority) {
                _ = try await substituted.author.makeModelCommitPlan(
                    cut: substituted.cut, basis: substituted.basis, basePlan: inputs.basePlan,
                    lease: try lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
                    inference: response, executions: [])
            }
        }
    }

    func testReceiptRejectsTerminalAuthorityWithDifferentValidObjective() async throws {
        let fixture = try await makeModelFixture()
        let response = inference(fixture: fixture, selectedHandleIDs: [], disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: response)
        let alternateText = "A different bounded objective."
        let alternateObjective = try ReconstructionRequestObjective(
            jobID: fixture.basis.job.jobID, text: alternateText,
            sha256: SHA256.hash(data: Data(alternateText.utf8)).map { String(format: "%02x", $0) }.joined()
        )
        let substituted = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: response.terminalReceipt.requestID,
            request: .roundR2(.init(protocolVersion: 9, objective: alternateObjective,
                request: try roundRequest(fixture))),
            terminalReceipt: response.terminalReceipt
        )
        await assertThrows(.invalidTerminalReceipt) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut, basis: fixture.basis, basePlan: inputs.basePlan,
                lease: try lease(providerRevision: 1), requestAuthority: substituted,
                inference: response, executions: []
            )
        }
    }

    func testBatchPlanAddsCanonicalReceiptAndEvidenceWithoutChangingBaseGraph() async throws {
        let fixture = try await makeBatchFixture()
        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: fixture.basis,
            prepared: fixture.cut.prepared
        )
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry,
            receiptAuthor: fixture.author
        )

        let optionalPlan = try await builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let plan = try XCTUnwrap(optionalPlan)
        let mutation = try XCTUnwrap(plan.mutation)
        let resultTaskID = try XCTUnwrap(fixture.batchResultTaskID)

        XCTAssertEqual(mutation.taskTransitions.count, 1)
        XCTAssertEqual(mutation.taskTransitions[0].taskID, resultTaskID)
        XCTAssertEqual(mutation.taskTransitions[0].successorState, .completed)
        XCTAssertEqual(
            mutation.newTasks.map(\.identity.kind),
            [.retrieveEvidence, .modelRound, .checkpoint]
        )
        XCTAssertEqual(mutation.toolReceipts.count, 1)
        XCTAssertEqual(mutation.evidence.count, 1)
        let receipt = try XCTUnwrap(mutation.toolReceipts.first)
        let evidence = try XCTUnwrap(mutation.evidence.first)
        XCTAssertTrue(try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt))
        XCTAssertEqual(receipt.taskID, resultTaskID)
        XCTAssertEqual(receipt.checkpointRevision, fixture.basis.checkpoint.revision + 1)
        XCTAssertEqual(receipt.outputEvidenceIDs, [evidence.evidenceID])
        XCTAssertEqual(evidence.toolReceiptID, receipt.receiptID)
        XCTAssertNil(evidence.modelReceiptID)
        XCTAssertEqual(evidence.creatingCheckpointID, mutation.successorCheckpoint.checkpointID)
    }

    func testCompletedOracleBatchPublishesReceiptEvidenceAndSourceRevisionPair() async throws {
        let fixture = try await makeOracleBatchFixture()
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(
                basis: fixture.basis, prepared: fixture.cut.prepared),
            receiptAuthor: fixture.author)
        let optionalPlan = try await builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let plan = try XCTUnwrap(optionalPlan)
        let mutation = try XCTUnwrap(plan.mutation)
        let execution = try XCTUnwrap(fixture.cut.batchTerminalResults.first)
        guard case .oracle(let oracle)? = execution.sourceExecution else {
            return XCTFail("Expected a controlled correlated oracle terminal payload.")
        }
        let receipt = try XCTUnwrap(mutation.toolReceipts.first)
        let record = try XCTUnwrap(mutation.evidence.first)
        let oracleTask = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.taskID == execution.taskID
        })
        let completedOracleTask = ReconstructionTaskRecord(identity: oracleTask.identity,
            state: .completed, diagnostic: nil)
        XCTAssertEqual(fixture.basis.checkpoint.revision, 12)
        XCTAssertEqual(plan.successorRevision, 13)
        XCTAssertEqual(plan.disposition, .continue)
        XCTAssertEqual(mutation.taskTransitions.count, 2)
        XCTAssertTrue(mutation.taskTransitions.allSatisfy { $0.successorState == .completed })
        XCTAssertEqual(mutation.toolReceipts.count, 1)
        XCTAssertEqual(receipt.terminalState, .completed)
        XCTAssertEqual(receipt.taskID, execution.taskID)
        XCTAssertEqual(receipt.outputEvidenceIDs, [record.evidenceID])
        XCTAssertTrue(try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt))
        XCTAssertTrue(mutation.modelReceipts.isEmpty)
        XCTAssertEqual(record.operationID, ReconstructionSourceOracleEvidence.operationID)
        XCTAssertEqual(record.classification, .acceptedCurrent)
        XCTAssertEqual(record.creatingCheckpointID, mutation.successorCheckpoint.checkpointID)
        XCTAssertEqual(record.toolReceiptID, receipt.receiptID)
        XCTAssertEqual(try ReconstructionSourceOracleEvidence.validate(record: record, context: .init(
            authority: .init(projectID: oracle.projectID, jobID: oracle.jobID,
                function: oracle.function, execution: oracle.execution, evidenceIDs: oracle.evidenceIDs),
            task: completedOracleTask, checkpoint: mutation.successorCheckpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: receipt.requestIdentitySHA256,
            expectedProducer: receipt.producer, committedEvidenceCut: fixture.basis.evidenceCut.records)), oracle)
        XCTAssertEqual(oracle.inputs.count, 37)
        XCTAssertEqual(oracle.outputs, Array(repeating: 7, count: 37))
        XCTAssertEqual(mutation.newTasks.count, 2)
        let sourceModel = try XCTUnwrap(mutation.newTasks.first { $0.identity.kind == .modelRound })
        let checkpoint = try XCTUnwrap(mutation.newTasks.first { $0.identity.kind == .checkpoint })
        XCTAssertEqual(sourceModel.identity.operationContractIdentity,
            ReconstructionProductionTaskContract.sourceRevision)
        XCTAssertEqual(sourceModel.identity.subject, .function(oracle.function))
        let predecessor = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .checkpoint && $0.identity.dependencyTaskIDs == [execution.taskID]
        })
        XCTAssertEqual(sourceModel.identity.dependencyTaskIDs, [predecessor.identity.taskID])
        XCTAssertEqual(checkpoint.identity.dependencyTaskIDs, [sourceModel.identity.taskID])
        XCTAssertTrue(mutation.newTasks.allSatisfy { $0.state == .pending })
    }

    func testOracleBatchRejectsUnrelatedOrForgedCheckpointTransitions() async throws {
        let fixture = try await makeOracleBatchFixture()
        let basePlan = try await baseBatchPlan(fixture)
        let base = try XCTUnwrap(basePlan.mutation)
        let result = try XCTUnwrap(fixture.cut.batchTerminalResults.first)
        let paired = try XCTUnwrap(base.taskTransitions.first { $0.taskID != result.taskID })
        let unrelated = try XCTUnwrap(fixture.basis.tasks.first { $0.identity.kind == .retrieveEvidence })
        let forged: [ReconstructionTaskTransition] = [
            .init(taskID: unrelated.identity.taskID, expectedState: unrelated.state,
                successorState: .completed, diagnostic: nil),
            .init(taskID: paired.taskID, expectedState: .running,
                successorState: .completed, diagnostic: nil),
            .init(taskID: paired.taskID, expectedState: .pending,
                successorState: .blocked, diagnostic: .sanitizing("Forged blocked checkpoint.")),
            .init(taskID: paired.taskID, expectedState: .pending,
                successorState: .completed, diagnostic: .sanitizing("Forged diagnostic.")),
        ]
        for replacement in forged {
            let mutation = ReconstructionCheckpointMutation(jobID: base.jobID,
                expectedParentCheckpointID: base.expectedParentCheckpointID,
                expectedParentCheckpointSHA256: base.expectedParentCheckpointSHA256,
                expectedParentRevision: base.expectedParentRevision, evidence: base.evidence,
                evidenceRelations: base.evidenceRelations, evidenceGaps: base.evidenceGaps,
                toolReceipts: base.toolReceipts, modelReceipts: base.modelReceipts,
                finalResults: base.finalResults, newTasks: base.newTasks,
                taskTransitions: base.taskTransitions.map { $0.taskID == paired.taskID ? replacement : $0 },
                freshnessAuthority: base.freshnessAuthority, successorCheckpoint: base.successorCheckpoint,
                successorPauseContext: base.successorPauseContext, analysisImports: base.analysisImports)
            let forgedPlan = ReconstructionJobCommitPlan(successorRevision: basePlan.successorRevision,
                acceptedEvidenceCount: basePlan.acceptedEvidenceCount, disposition: basePlan.disposition,
                mutation: mutation)
            await assertThrows(.invalidBasePlan) {
                _ = try await fixture.author.makeBatchCommitPlan(
                    cut: fixture.cut, basis: fixture.basis, basePlan: forgedPlan)
            }
        }
    }

    func testBatchPlanRejectsTerminalResultFromAnotherCheckpoint() async throws {
        let fixture = try await makeBatchFixture()
        let basePlan = try await baseBatchPlan(fixture)
        let original = try XCTUnwrap(fixture.cut.batchTerminalResults.first)
        let foreign = ReconstructionTerminalTaskResult(
            jobID: original.jobID,
            taskID: original.taskID,
            checkpointID: UUID(),
            checkpointRevision: original.checkpointRevision,
            corpusManifestSHA256: original.corpusManifestSHA256,
            outcome: original.outcome
        )
        let cut = ReconstructionProductionCommittedRoundCut(
            snapshot: fixture.cut.snapshot,
            parentCheckpointID: fixture.cut.parentCheckpointID,
            parentCheckpointSHA256: fixture.cut.parentCheckpointSHA256,
            prepared: fixture.cut.prepared,
            batchTerminalResults: [foreign]
        )

        await assertThrows(.mismatchedTerminalResult) {
            _ = try await fixture.author.makeBatchCommitPlan(
                cut: cut,
                basis: fixture.basis,
                basePlan: basePlan
            )
        }
    }

    func testFailedBatchPlanPreservesBlockedSiblingAndAuthorsOnlyResultAuthority() async throws {
        let (fixture, blockedTaskID) = try await makeFailedBatchFixture()
        let resultTaskID = try XCTUnwrap(fixture.batchResultTaskID)
        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: fixture.basis,
            prepared: fixture.cut.prepared
        )
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry,
            receiptAuthor: fixture.author
        )

        let optionalPlan = try await builder.makePreInferenceCommitPlan(cut: fixture.cut)
        let plan = try XCTUnwrap(optionalPlan)
        let mutation = try XCTUnwrap(plan.mutation)

        XCTAssertEqual(plan.disposition, .failed)
        XCTAssertEqual(mutation.taskTransitions.count, 2)
        XCTAssertEqual(
            mutation.taskTransitions.first { $0.taskID == resultTaskID }?.successorState,
            .failed
        )
        XCTAssertEqual(
            mutation.taskTransitions.first { $0.taskID == blockedTaskID }?.successorState,
            .blocked
        )
        XCTAssertEqual(mutation.toolReceipts.map(\.taskID), [resultTaskID])
        XCTAssertTrue(mutation.evidence.isEmpty)
        XCTAssertFalse(mutation.toolReceipts.contains { $0.taskID == blockedTaskID })
        XCTAssertFalse(mutation.evidence.contains { $0.creatingTaskID == blockedTaskID })
    }

    func testModelPlanPreservesSelectedHandleIdentityAndIgnoresProviderRevision() async throws {
        let fixture = try await makeModelFixture()
        let handles = try ReconstructionToolRegistry().mintHandles(
            authority: fixture.cut.prepared.authority,
            requests: fixture.cut.prepared.requests
        )
        let selectedHandles = [try XCTUnwrap(handles.first)]
        XCTAssertEqual(handles.count, 1)
        let executions = try [toolExecution(handle: selectedHandles[0], fixture: fixture)]
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: selectedHandles.map(\.handleID),
            disposition: .continue
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)

        let first = try await fixture.author.makeModelCommitPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority,
            inference: inference,
            executions: executions
        )
        let second = try await fixture.author.makeModelCommitPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 999),
            requestAuthority: inputs.requestAuthority,
            inference: inference,
            executions: executions
        )

        let firstMutation = try XCTUnwrap(first.mutation)
        let secondMutation = try XCTUnwrap(second.mutation)
        let firstModel = try XCTUnwrap(firstMutation.modelReceipts.first)
        let secondModel = try XCTUnwrap(secondMutation.modelReceipts.first)
        XCTAssertEqual(firstModel, secondModel)
        XCTAssertEqual(
            firstModel.selectedHandleIDs,
            selectedHandles.map { $0.handleID.uuidString.lowercased() }
        )
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(firstModel))
        XCTAssertEqual(firstMutation.toolReceipts.count, 1)
        XCTAssertTrue(firstMutation.toolReceipts.allSatisfy {
            $0.checkpointRevision == fixture.basis.checkpoint.revision + 1
        })
        XCTAssertEqual(firstMutation.successorCheckpoint.modelReceiptIDs, [firstModel.receiptID])
        XCTAssertEqual(
            Set(firstMutation.successorCheckpoint.toolReceiptIDs),
            Set(executions.map(\.receipt.receiptID))
        )
        XCTAssertEqual(firstMutation.taskTransitions, inputs.basePlan.mutation?.taskTransitions)
    }

    func testModelPlanRejectsSelectedHandleWithoutTerminalExecution() async throws {
        let fixture = try await makeModelFixture()
        let handle = try XCTUnwrap(
            ReconstructionToolRegistry().mintHandles(
                authority: fixture.cut.prepared.authority,
                requests: fixture.cut.prepared.requests
            ).first
        )
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: [handle.handleID],
            disposition: .continue
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)

        await assertThrows(.invalidToolExecution) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: inputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: inputs.requestAuthority,
                inference: inference,
                executions: []
            )
        }
    }

    func testModelPlanRejectsMismatchedTerminalRound() async throws {
        let fixture = try await makeModelFixture()
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: fixture.basis.job.jobID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            roundID: fixture.cut.prepared.roundID,
            selectedHandleIDs: [],
            disposition: .continue,
            unresolvedGaps: []
        )
        let inference = ReconstructionInferenceExecutionResult(
            candidate: candidate,
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: .init(
                requestID: receiptID,
                jobID: fixture.basis.job.jobID,
                checkpointRevision: fixture.basis.checkpoint.revision,
                roundID: UUID(),
                status: .completed
            )
        )
        let validInference = self.inference(
            fixture: fixture,
            selectedHandleIDs: [],
            disposition: .continue
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: validInference)

        await assertThrows(.invalidTerminalReceipt) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: inputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: inputs.requestAuthority,
                inference: inference,
                executions: []
            )
        }
    }

    func testModelPlanRejectsCrossProductOfSeparatelyAllowedGapCoordinates() async throws {
        let fixture = try await makeModelFixture(crossedGapAuthority: true)
        XCTAssertEqual(fixture.basis.evidenceCut.gaps.count, 2)
        let gaps = fixture.basis.evidenceCut.gaps
        let firstSubject = "subject:\(try ReconstructionCanonicalJSON.sha256(of: gaps[0].subject))"
        let crossedCategory = gaps[1].operationID
        XCTAssertFalse(fixture.basis.evidenceCut.gaps.contains { gap in
            (try? ReconstructionCanonicalJSON.sha256(of: gap.subject))
                .map { "subject:\($0)" } == firstSubject
                && gap.operationID == crossedCategory
        })
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: [],
            disposition: .blocked,
            unresolvedGaps: [ReconstructionEvidenceGapDeclaration(
                subject: firstSubject,
                category: crossedCategory,
                reason: "The model crossed two independently allowed coordinates."
            )]
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)

        await assertThrows(.invalidGapDeclaration) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: inputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: inputs.requestAuthority,
                inference: inference,
                executions: []
            )
        }
    }

    func testModelPlanAuthorsResolvedGapFromExactRetrievedAcceptedCurrentEvidence() async throws {
        let fixture = try await makeModelFixture(resolvableGapAuthority: true)
        let handle = try XCTUnwrap(
            ReconstructionToolRegistry().mintHandles(
                authority: fixture.cut.prepared.authority,
                requests: fixture.cut.prepared.requests
            ).first
        )
        let gap = try XCTUnwrap(fixture.basis.evidenceCut.gaps.first)
        let evidence = try XCTUnwrap(fixture.basis.evidenceCut.records.first)
        let execution = try retrievedEvidenceExecution(
            handle: handle,
            fixture: fixture,
            resolvedGapIDs: [gap.gapID]
        )
        XCTAssertTrue(execution.acceptedEvidence.isEmpty)
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: [handle.handleID],
            disposition: .continue,
            resolvedGaps: [.init(
                gapID: gap.gapID,
                handleID: handle.handleID,
                evidenceID: evidence.evidenceID
            )]
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)

        let plan = try await fixture.author.makeModelCommitPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority,
            inference: inference,
            executions: [execution]
        )
        let relation = try XCTUnwrap(
            plan.mutation?.evidenceRelations.first { $0.kind == .resolvesGap }
        )
        XCTAssertEqual(relation.sourceEvidenceID, evidence.evidenceID)
        XCTAssertEqual(relation.targetEvidenceID, gap.gapID)
        XCTAssertTrue(plan.mutation?.evidence.isEmpty == true)
    }

    func testModelPlanRejectsResolvedGapWhenExecutionPacketDoesNotContainClaimedEvidence() async throws {
        let fixture = try await makeModelFixture(resolvableGapAuthority: true)
        let handle = try XCTUnwrap(
            ReconstructionToolRegistry().mintHandles(
                authority: fixture.cut.prepared.authority,
                requests: fixture.cut.prepared.requests
            ).first
        )
        let gap = try XCTUnwrap(fixture.basis.evidenceCut.gaps.first)
        let evidence = try XCTUnwrap(fixture.basis.evidenceCut.records.first)
        let valid = try retrievedEvidenceExecution(
            handle: handle,
            fixture: fixture,
            resolvedGapIDs: [gap.gapID]
        )

        // The authority-bound packet is exact and complete, but the claimed evidence is not in it.
        let absentEvidenceID = UUID(uuidString: "00000000-0000-0000-0000-000000009399")!
        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: fixture.cut.prepared.evidenceCut,
            query: fixture.cut.prepared.retrievalQuery
        )
        XCTAssertEqual(valid.result.payload, packet.canonicalBytes)
        XCTAssertFalse(packet.records.map(\.evidenceID).contains(absentEvidenceID))
        let absentClaim = inference(
            fixture: fixture,
            selectedHandleIDs: [handle.handleID],
            disposition: .continue,
            resolvedGaps: [.init(
                gapID: gap.gapID,
                handleID: handle.handleID,
                evidenceID: absentEvidenceID
            )]
        )
        let absentInputs = try modelAuthorInputs(fixture: fixture, inference: absentClaim)
        await assertThrows(.invalidGapResolution) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: absentInputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: absentInputs.requestAuthority,
                inference: absentClaim,
                executions: [valid]
            )
        }

        // A drifted execution packet that omits the claimed evidence is no longer the exact
        // authority-bound read, so tool reauthorization rejects it before any gap claim can be
        // credited from its contents.
        let drifted = ReconstructionToolExecution(
            handleID: valid.handleID,
            operationID: valid.operationID,
            result: .success(payload: Data("[]".utf8), count: 0),
            acceptedEvidence: [],
            receipt: valid.receipt,
            resolvedGapIDs: valid.resolvedGapIDs
        )
        let driftedClaim = inference(
            fixture: fixture,
            selectedHandleIDs: [handle.handleID],
            disposition: .continue,
            resolvedGaps: [.init(
                gapID: gap.gapID,
                handleID: handle.handleID,
                evidenceID: evidence.evidenceID
            )]
        )
        let driftedInputs = try modelAuthorInputs(fixture: fixture, inference: driftedClaim)

        await assertThrows(.invalidToolExecution) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: driftedInputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: driftedInputs.requestAuthority,
                inference: driftedClaim,
                executions: [drifted]
            )
        }
    }

    func testSufficientEvidenceAugmentsTheDurableBasePlan() async throws {
        let fixture = try await makeModelFixture()
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: [],
            disposition: .sufficientEvidence
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)

        let plan = try await fixture.author.makeModelCommitPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority,
            inference: inference,
            executions: []
        )
        XCTAssertEqual(plan.disposition, inputs.basePlan.disposition)
        XCTAssertEqual(plan.mutation?.newTasks, inputs.basePlan.mutation?.newTasks)
        XCTAssertEqual(plan.mutation?.taskTransitions, inputs.basePlan.mutation?.taskTransitions)
        XCTAssertEqual(plan.mutation?.modelReceipts.count, 1)
    }

    func testFinalSynthesisRejectsANonfinalPreparedCut() async throws {
        let fixture = try await makeModelFixture()
        let modelInference = inference(
            fixture: fixture,
            selectedHandleIDs: [],
            disposition: .continue
        )
        let modelInputs = try modelAuthorInputs(fixture: fixture, inference: modelInference)
        let round = try roundRequest(fixture)
        let finalRequest = ReconstructionFinalSynthesisRequest(
            jobID: round.jobID,
            checkpointRevision: round.checkpointRevision,
            corpusManifestSHA256: round.corpusManifestSHA256,
            evidenceFrontierSHA256: round.evidenceFrontierSHA256,
            acceptedEvidenceIDs: [],
            context: round.context
        )
        let synthesis = ReconstructionFinalSynthesisExecutionResult(
            candidate: ReconstructionFinalSynthesisCandidate(
                kind: .synthesis,
                text: "A terminal answer that currently has no durable record type.",
                evidenceIDs: []
            ),
            usage: .init(promptTokens: 2, completionTokens: 3, totalTokens: 5),
            terminalReceipt: ReconstructionTerminalReceipt(
                requestID: receiptID,
                jobID: fixture.basis.job.jobID,
                checkpointRevision: fixture.basis.checkpoint.revision,
                roundID: nil,
                status: .completed
            )
        )
        let authority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: synthesis.terminalReceipt.requestID,
            request: fixture.cut.prepared.objective.map {
                .finalSynthesisR2(.init(protocolVersion: 9, objective: $0, request: finalRequest))
            } ?? .finalSynthesis(finalRequest),
            terminalReceipt: synthesis.terminalReceipt
        )

        await assertThrows(.invalidCommittedAuthority) {
            _ = try await fixture.author.makeFinalCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: modelInputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: authority,
                synthesis: synthesis
            )
        }
    }

    func testFinalSynthesisAuthorsCanonicalDurableResultAndReceiptCommitment() async throws {
        let fixture = try await makeFinalFixture()
        let inputs = try finalAuthorInputs(
            fixture: fixture,
            candidate: ReconstructionFinalSynthesisCandidate(
                kind: .insufficientEvidence,
                text: "No accepted current evidence supports a synthesis.",
                evidenceIDs: []
            )
        )

        let plan = try await fixture.author.makeFinalCommitPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority,
            synthesis: inputs.synthesis
        )
        let mutation = try XCTUnwrap(plan.mutation)
        let result = try XCTUnwrap(mutation.finalResults.first)
        let receipt = try XCTUnwrap(mutation.modelReceipts.first)

        XCTAssertEqual(plan.disposition, .completed)
        XCTAssertEqual(result.kind, .insufficientEvidence)
        XCTAssertEqual(result.payloadUTF8, Data(inputs.synthesis.candidate.text.utf8))
        XCTAssertTrue(result.citedEvidenceIDs.isEmpty)
        XCTAssertEqual(
            result.producer.operationIdentity,
            ReconstructionProductionTaskContract.finalSynthesis
        )
        XCTAssertTrue(try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(result))
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
        XCTAssertEqual(
            receipt.finalResultCommitment,
            try ReconstructionFinalResultCommitment(
                resultID: result.resultID,
                canonicalSHA256: result.canonicalSHA256
            )
        )
        XCTAssertEqual(mutation.successorCheckpoint.modelReceiptIDs, [receipt.receiptID])
        XCTAssertEqual(receipt.receiptID, result.modelReceiptID)
    }

    func testFinalSynthesisKindShapeIsRevalidatedAtReceiptBoundary() async throws {
        let fixture = try await makeFinalFixture()
        let inputs = try finalAuthorInputs(
            fixture: fixture,
            candidate: ReconstructionFinalSynthesisCandidate(
                kind: .synthesis,
                text: "This cannot be a synthesis without a citation.",
                evidenceIDs: []
            )
        )

        await assertThrows(.invalidTerminalReceipt) {
            _ = try await fixture.author.makeFinalCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: inputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: inputs.requestAuthority,
                synthesis: inputs.synthesis
            )
        }
    }

    func testMalformedModelPersistsCompletedProviderReceiptWhenAppValidationFails() async throws {
        let fixture = try await makeModelFixture()
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: [],
            disposition: .continue
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(
                basis: fixture.basis,
                prepared: fixture.cut.prepared
            ),
            receiptAuthor: fixture.author
        )

        let plan = try await builder.makeFailedModelPlan(
            cut: fixture.cut,
            lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority,
            reason: .malformedOutput
        )
        let mutation = try XCTUnwrap(plan.mutation)
        let receipt = try XCTUnwrap(mutation.modelReceipts.first)
        XCTAssertEqual(plan.disposition, .failed)
        XCTAssertEqual(receipt.terminalState, .completed)
        XCTAssertEqual(receipt.receiptID, inputs.requestAuthority.expectedRequestID)
        XCTAssertTrue(try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt))
        XCTAssertEqual(
            mutation.taskTransitions.first { $0.taskID == receipt.taskID }?.successorState,
            .failed
        )
    }

    func testRetryableProviderFailurePersistsReasonAndLeavesRoundRetryable() async throws {
        let fixture = try await makeModelFixture()
        let response = inference(fixture: fixture, selectedHandleIDs: [], disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: response)
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(
                basis: fixture.basis, prepared: fixture.cut.prepared
            ), receiptAuthor: fixture.author
        )
        let plan = try await builder.makeFailedModelPlan(
            cut: fixture.cut, lease: try lease(providerRevision: 1),
            requestAuthority: inputs.requestAuthority,
            reason: .retryableProviderFailure("overallDeadlineExceeded")
        )
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(plan.disposition, .paused(.modelUnavailable))
        XCTAssertTrue(mutation.taskTransitions.allSatisfy { $0.successorState == .pending })
        XCTAssertEqual(mutation.modelReceipts.first?.diagnostic?.text,
            "Model request paused: overallDeadlineExceeded.")
    }

    func testBlockedModelWithoutGapDeclarationPausesInsteadOfFailing() async throws {
        let fixture = try await makeModelFixture()
        let response = inference(fixture: fixture, selectedHandleIDs: [], disposition: .blocked)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: response)
        let plan = try await fixture.author.makeModelCommitPlan(
            cut: fixture.cut, basis: fixture.basis, basePlan: inputs.basePlan,
            lease: try lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
            inference: response, executions: []
        )
        XCTAssertEqual(plan.disposition, .paused(.evidenceStalled))
    }

    func testRecoveryPlanReturnsExactParentLinkedMutation() async throws {
        let fixture = try await makeModelFixture()
        let retrieve = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .retrieveEvidence
        })
        let transition = ReconstructionTaskTransition(
            taskID: retrieve.identity.taskID,
            expectedState: .running,
            successorState: .pending,
            diagnostic: nil
        )

        let plan = try await fixture.author.makeRecoveryPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            transitions: [transition]
        )
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(plan.disposition, .continue)
        XCTAssertEqual(mutation.expectedParentCheckpointID, fixture.basis.checkpoint.checkpointID)
        XCTAssertEqual(
            mutation.expectedParentCheckpointSHA256,
            fixture.basis.checkpoint.canonicalSHA256
        )
        XCTAssertEqual(mutation.expectedParentRevision, fixture.basis.checkpoint.revision)
        XCTAssertEqual(mutation.taskTransitions, [transition])
        XCTAssertEqual(mutation.successorCheckpoint.revision, fixture.basis.checkpoint.revision + 1)
    }

    func testCheckpointRevisionMayAdvanceBeyondMaxRoundsBudget() async throws {
        let original = try await makeModelFixture()
        let basis = try basisAtRevisionOneWithMaxRoundsOne(original.basis)
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: try original.author.makeToolProducer(
                operationID: .evidenceQuery
            )
        ).makePreparedRound(from: basis)
        let committed = cut(basis: basis, prepared: prepared, results: [])
        let retrieve = try XCTUnwrap(basis.tasks.first {
            $0.identity.kind == .retrieveEvidence && $0.state == .running
        })
        let plan = try await original.author.makeRecoveryPlan(
            cut: committed,
            basis: basis,
            transitions: [.init(
                taskID: retrieve.identity.taskID,
                expectedState: .running,
                successorState: .pending,
                diagnostic: nil
            )]
        )

        XCTAssertEqual(basis.job.budget.maxRounds, 1)
        XCTAssertEqual(plan.successorRevision, 2)
        XCTAssertGreaterThan(plan.successorRevision, UInt64(basis.job.budget.maxRounds))
    }

    func testCancelPlanTransitionsEveryActiveTaskAndPersistsTerminalCheckpoint() async throws {
        let fixture = try await makeModelFixture()

        let plan = try await fixture.author.makeControlPlan(
            cut: fixture.cut,
            basis: fixture.basis,
            reason: .cancelled
        )
        let mutation = try XCTUnwrap(plan.mutation)
        XCTAssertEqual(plan.disposition, .cancelled)
        let activeIDs = Set(fixture.basis.tasks.compactMap { task in
            task.state == .pending || task.state == .running ? task.identity.taskID : nil
        })
        XCTAssertEqual(Set(mutation.taskTransitions.map(\.taskID)), activeIDs)
        XCTAssertTrue(mutation.taskTransitions.allSatisfy { $0.successorState == .cancelled })
        XCTAssertEqual(mutation.successorCheckpoint.coordinatorState, .cancelled)
        XCTAssertNotNil(mutation.successorCheckpoint.terminalReason)
    }

    func testModelTaskOperationDriftIsRejectedBeforeReceiptAuthoring() async throws {
        let fixture = try await makeModelFixture(
            contextOperationIdentity: "reconstruction.some-other-model-contract.v1"
        )
        let inference = inference(
            fixture: fixture,
            selectedHandleIDs: [],
            disposition: .continue
        )
        let inputs = try modelAuthorInputs(fixture: fixture, inference: inference)

        await assertThrows(.invalidTaskFrontier) {
            _ = try await fixture.author.makeModelCommitPlan(
                cut: fixture.cut,
                basis: fixture.basis,
                basePlan: inputs.basePlan,
                lease: try lease(providerRevision: 1),
                requestAuthority: inputs.requestAuthority,
                inference: inference,
                executions: []
            )
        }
    }

    // Mutation RED recipes:
    // 1. Remove the batch checkpoint-ID equality guard: the foreign-checkpoint case turns green.
    // 2. Sort or discard `selectedHandleIDs` before minting the model receipt: the reverse-order
    //    two-handle assertion fails.
    // 3. Add `providerRevision` to model configuration identity: the revision-stability case fails.
    // 4. Delete the sufficient-evidence refusal: the missing-final-leaf case fails.
    // 5. Remove the `modelProducerContext.operationIdentity == frontier.model.identity`
    //    operation-contract guard in `makeModelCommitPlan`: the operation-drift case turns green.
    // 6. Require result IDs to equal all base transition IDs: the failed-batch blocked-sibling
    //    case fails.
    // 7. Persist evidence for noncompleted terminals: the failed-batch no-fabrication assertion
    //    fails because failure would be promoted to accepted-current evidence.
    // 8. Remove the exact subject/category pair check while keeping the two independent allowlists:
    //    the crossed-gap declaration case fails.
    // 9. Swap a resolution claim's evidence ID, handle ID, or exact retrieval-packet membership:
    //    the wire/receipt resolution cases fail independently instead of inferring a source.
    // 10. Restore a successor-revision <= maxRounds check: the revision-vs-round-budget case fails.
    // 11. Reuse the regular model producer operation for final synthesis: the canonical final
    //     result test fails its exact task-contract producer assertion.
    // 12. Remove receipt-boundary final kind validation: the citation-free synthesis case turns
    //     green even though the worker's discriminated schema rejects that shape.
    // 13. Remove the exact-subject de-duplication before building `ReconstructionAuthorityCut`:
    //     the canonical batch augmentation fails with `invalidEvidence` before receipt persistence.
}

private extension ReconstructionProductionReceiptPlanAuthorTests {
    func successorReadBasis(basis: ReconstructionProductionRoundBasis,
        mutation: ReconstructionCheckpointMutation,
        evidenceCut changedCut: ReconstructionEvidenceCut? = nil) throws -> ReconstructionProductionRoundBasis {
        let evidenceCut = changedCut ?? basis.evidenceCut
        let transitions = Dictionary(uniqueKeysWithValues: mutation.taskTransitions.map { ($0.taskID, $0) })
        let tasks = basis.tasks.map { task in
            ReconstructionTaskRecord(identity: task.identity,
                state: transitions[task.identity.taskID]?.successorState ?? task.state,
                diagnostic: transitions[task.identity.taskID]?.diagnostic ?? task.diagnostic)
        } + mutation.newTasks.map {
            ReconstructionTaskRecord(identity: $0.identity,
                state: $0.identity.kind == .retrieveEvidence || $0.identity.kind == .modelRound
                    ? .running : $0.state, diagnostic: $0.diagnostic)
        }
        let toolReceipts = basis.toolReceipts + mutation.toolReceipts
        let modelReceipts = basis.modelReceipts + mutation.modelReceipts
        let completions = tasks.filter { $0.state == .completed }.map {
            ReconstructionProductionTaskCompletionAuthority(taskID: $0.identity.taskID,
                firstCompletedAtRevision: transitions[$0.identity.taskID] == nil
                    ? basis.checkpoint.revision : mutation.successorCheckpoint.revision)
        }
        let consecutive = try ReconstructionProductionModelRoundBudgetAuthority
            .consecutiveRoundsWithoutEvidence(jobID: basis.job.jobID, tasks: tasks,
                toolReceipts: toolReceipts, modelReceipts: modelReceipts,
                taskCompletionAuthorities: completions)
        let committed = mutation.successorCheckpoint
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: committed.checkpointID, jobID: committed.jobID,
            revision: committed.revision, parentCheckpointID: committed.parentCheckpointID,
            parentCheckpointSHA256: committed.parentCheckpointSHA256,
            corpusManifestSHA256: committed.corpusManifestSHA256,
            evidenceFrontierSHA256: changedCut?.frontierSHA256 ?? committed.evidenceFrontierSHA256,
            pendingTaskIDs: tasks.filter { $0.state == .pending }.map(\.identity.taskID),
            runningTaskIDs: tasks.filter { $0.state == .running }.map(\.identity.taskID),
            completedTaskIDs: tasks.filter { $0.state == .completed }.map(\.identity.taskID),
            failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: committed.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: committed.modelReceiptIDs, toolReceiptIDs: committed.toolReceiptIDs,
            coordinatorState: committed.coordinatorState, terminalReason: nil)
        let job = try ReconstructionJobRecord(jobID: basis.job.jobID,
            reconstructionProjectID: basis.job.reconstructionProjectID,
            objective: basis.job.objective, objectiveSHA256: basis.job.objectiveSHA256,
            creationCorpusManifestSHA256: basis.job.creationCorpusManifestSHA256,
            state: checkpoint.coordinatorState, currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil, budget: basis.job.budget, creationOrdinal: 1,
            focus: basis.job.focus)
        let snapshot = ReconstructionJobOrchestrationSnapshot(jobID: job.jobID,
            jobCreationOrder: 1, checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceCut.frontierSHA256,
            currentDurableJobState: job.state, pauseContext: nil,
            maximumRoundsWithoutEvidence: job.budget.maxRounds, tasks: tasks,
            terminalReceiptStatesByTaskID: [:],
            consecutiveModelRoundsWithoutEvidence: consecutive)
        return try ReconstructionProductionRoundBasis(workspaceID: basis.workspaceID,
            project: basis.project, manifest: basis.manifest, job: job, checkpoint: checkpoint,
            tasks: tasks, toolReceipts: toolReceipts, modelReceipts: modelReceipts,
            taskCompletionAuthorities: completions, attachmentSources: basis.attachmentSources,
            evidenceCut: evidenceCut, freshnessAuthority: basis.freshnessAuthority,
            snapshot: snapshot)
    }

    /// Commits one selected evidence read of `query` through the production plan builder and
    /// returns the successor basis built from that exact mutation.
    func commitSelectedRead(basis: ReconstructionProductionRoundBasis,
        author: ReconstructionProductionReceiptPlanAuthor, query: ReconstructionRetrievalQuery,
        successorCut: ReconstructionEvidenceCut? = nil,
        appending: AppendedEvidenceSpec? = nil) async throws
        -> (successor: ReconstructionProductionRoundBasis, read: ReconstructionToolReceipt,
            request: ReconstructionToolRequest) {
        let basePrepared = try await refreshPreparedRound(basis, suppliesRefreshProducer: false)
        let request = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: try XCTUnwrap(basePrepared.requests.first).taskID, subject: nil,
            retrievalQuery: query, offset: query.cursor == nil ? 0 : 1,
            maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
        let prepared = ReconstructionPreparedModelRound(roundID: basePrepared.roundID,
            evidenceCut: basis.evidenceCut, retrievalQuery: query,
            allowedGapSubjects: basePrepared.allowedGapSubjects,
            allowedGapCategories: basePrepared.allowedGapCategories,
            authority: basePrepared.authority, requests: [request],
            projectorInput: basePrepared.projectorInput, objective: basePrepared.objective)
        let fixture = Fixture(basis: basis, cut: cut(basis: basis, prepared: prepared, results: []),
            author: author, batchResultTaskID: nil)
        let handle = try XCTUnwrap(ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority, requests: prepared.requests).first)
        let outcome = inference(fixture: fixture, selectedHandleIDs: [handle.handleID],
            disposition: .continue)
        let inputs = try modelAuthorInputs(fixture: fixture, inference: outcome)
        let planner = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: ReconstructionProductionRoundBasisRegistry(basis: basis, prepared: prepared),
            receiptAuthor: fixture.author)
        let plan = try await planner.makeCommitPlan(cut: fixture.cut,
            lease: lease(providerRevision: 1), requestAuthority: inputs.requestAuthority,
            inference: outcome, executions: [toolExecution(handle: handle, fixture: fixture)])
        let mutation = try XCTUnwrap(plan.mutation)
        let read = try XCTUnwrap(mutation.toolReceipts.first)
        XCTAssertNotNil(read.evidenceReadAuthority)
        // Evidence appended by this job is created at the successor checkpoint's revision.
        let appendedCut = try appending.map {
            try cutByAppendingEvidence(basis.evidenceCut, spec: $0,
                checkpointID: mutation.successorCheckpoint.checkpointID,
                revision: mutation.successorCheckpoint.revision)
        }
        return (try successorReadBasis(basis: basis, mutation: mutation,
            evidenceCut: successorCut ?? appendedCut), read, request)
    }

    /// Returns `cut` with one accepted-current record appended at `checkpointID`/`revision`
    /// (modelled on the cut's first record), optionally removing or reclassifying prior records
    /// and optionally under a different corpus manifest.
    func cutByAppendingEvidence(_ cut: ReconstructionEvidenceCut, spec: AppendedEvidenceSpec,
        checkpointID: UUID, revision: UInt64,
        corpusManifestSHA256: String? = nil) throws -> ReconstructionEvidenceCut {
        let template = try XCTUnwrap(cut.records.first)
        let payload = Data("{\"summary\":\"\(spec.summary)\"}".utf8)
        let appended = try ReconstructionEvidenceRecord(
            evidenceID: spec.evidenceID, subject: template.subject,
            operationID: spec.operation.rawValue, payloadKind: .structuredJSON, payload: payload,
            payloadByteCount: UInt64(payload.count),
            payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            facetDependencies: [], producer: try toolProducer(operation: spec.operation),
            citations: [try ReconstructionEvidenceCitation(citationID: UUID(),
                sourceEvidenceID: nil, subject: template.subject, locator: "appended-source-task")],
            creatingJobID: template.creatingJobID, creatingTaskID: template.creatingTaskID,
            creatingCheckpointID: checkpointID, modelReceiptID: nil, toolReceiptID: nil,
            classification: .acceptedCurrent, supersedesEvidenceID: nil,
            supersededByEvidenceID: nil, diagnostic: nil)
        let records = cut.records.filter { !spec.removing.contains($0.evidenceID) } + [appended]
        var classifications = cut.projectedClassificationsByEvidenceID.filter {
            !spec.removing.contains($0.key)
        }
        for (evidenceID, classification) in spec.reclassifying {
            classifications[evidenceID] = classification
        }
        classifications[appended.evidenceID] = .acceptedCurrent
        let checkpointIDs = Set(records.map(\.creatingCheckpointID))
        var revisions = cut.checkpointRevisionsByID.filter { checkpointIDs.contains($0.key) }
        revisions[checkpointID] = revision
        let manifest = corpusManifestSHA256 ?? cut.corpusManifestSHA256
        return try ReconstructionEvidenceCut(corpusManifestSHA256: manifest, records: records,
            relations: cut.relations, gaps: cut.gaps,
            frontierSHA256: ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: manifest, records: records,
                projectedClassificationsByEvidenceID: classifications,
                relations: cut.relations, gaps: cut.gaps, checkpointRevisionsByID: revisions),
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: revisions)
    }

    /// Projects and captures one qualified read of `query` under the prepared round's authority.
    func capturedRead(prepared: ReconstructionPreparedModelRound,
        query: ReconstructionRetrievalQuery, cut: ReconstructionEvidenceCut) async throws
        -> ReconstructionEvidenceReadAuthority {
        let request = ReconstructionToolRequest(operationID: .evidenceQuery,
            taskID: try XCTUnwrap(prepared.requests.first).taskID, subject: nil,
            retrievalQuery: query, offset: query.cursor == nil ? 0 : 1,
            maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
        let registry = ReconstructionToolRegistry()
        let handle = try XCTUnwrap(registry.mintHandles(
            authority: prepared.authority, requests: [request]).first)
        let envelope = try registry.decodeCanonicalRequest(handle)
        let projection = try await ReconstructionEvidenceToolProjector().project(
            request: envelope, input: prepared.projectorInput)
        return try ReconstructionEvidenceReadAuthority.capture(
            request: envelope, result: projection, cut: cut)
    }

    /// Records the actual R2 request the production job-round planner hands to inference.
    func capturedSuccessorRequest(_ successor: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound) async throws -> ReconstructionAIWorkerRequest {
        let capture = await SuccessorRequestCapture()
        let roundPlanner = ReconstructionProductionJobRoundPlanner(
            materializer: SuccessorCaptureMaterializer(prepared: prepared),
            inference: capture, projectors: [ReconstructionEvidenceToolProjector()])
        do {
            _ = try await roundPlanner.planRound(from: successor.snapshot)
            XCTFail("Capture provider should report busy after recording the actual request")
        } catch {
            XCTAssertEqual(error as? ReconstructionJobCoordinatorFailure, .inferenceBusy)
        }
        let captured = await capture.request
        return try XCTUnwrap(captured)
    }

    func evidenceID(_ ordinal: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9301 + ordinal * 10))!
    }

    func refreshPreparedRound(_ basis: ReconstructionProductionRoundBasis,
        suppliesRefreshProducer: Bool) async throws -> ReconstructionPreparedModelRound {
        try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: toolProducer(operation: .evidenceQuery),
            analysisRefreshProducer: suppliesRefreshProducer
                ? toolProducer(operation: .analysisMacScopeRefresh) : nil).makePreparedRound(from: basis)
    }

    func makeRefreshOfferBasis(remainingTaskSlots: Int, focused: Bool = true,
        alreadyScheduled: Bool = false,
        recordCount: Int = 1) async throws -> ReconstructionProductionRoundBasis {
        let base = try await makeModelFixture().basis
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID())
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity)
        let image = ReconstructionImageBinding(binaryID: ReconstructionStableImageAuthority.stableBinaryID(
            occurrenceID: artifact.occurrenceID, selectedSliceIndex: nil), imageSlot: .primary,
            selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
        let function = try ReconstructionFunctionCoordinate(artifact: artifact, image: image,
            analysisFingerprintSHA256: digest("d"), startAddress: 0x1000,
            endAddressExclusive: 0x1010, boundarySchemaVersion: 1,
            functionUUIDHint: nil, symbolHint: nil)
        let coordinate = try ReconstructionImageCoordinate(artifact: artifact, image: image,
            analysisFingerprintSHA256: function.analysisFingerprintSHA256)
        let ingest = try XCTUnwrap(base.tasks.first { $0.identity.kind == .ingest })
        let checkpoint = try XCTUnwrap(base.tasks.first { $0.identity.kind == .checkpoint })
        let load = try task(id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID], state: .completed)
        let index = try task(id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
            subject: .image(coordinate), dependencies: [load.identity.taskID], state: .completed)
        let enumeration = try task(id: UUID(), jobID: foundation.job.jobID, kind: .enumerateFunctions,
            subject: .image(coordinate), dependencies: [index.identity.taskID], state: .completed)
        let source = try task(id: UUID(), jobID: foundation.job.jobID, kind: .decompileMacScope,
            subject: .function(function), dependencies: [enumeration.identity.taskID], state: .completed)
        var tasks = base.tasks + [load, index, enumeration, source]
        if alreadyScheduled {
            tasks.append(try task(id: UUID(), jobID: foundation.job.jobID, kind: .decompileMacScope,
                subject: .function(function), dependencies: [enumeration.identity.taskID, checkpoint.identity.taskID],
                state: .pending))
        }
        let basis = try makeBasis(foundation: foundation, tasks: tasks, currentImages: [coordinate],
            maximumTasks: tasks.count + remainingTaskSlots,
            focus: focused ? .function(function) : nil)
        return try basisByAddingAcceptedCurrentEvidence(basis, sourceTaskID: source.identity.taskID,
            subject: .function(function), operation: .decompilerMacScope, recordCount: recordCount)
    }

    static let receiptID = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
    var receiptID: UUID { Self.receiptID }

    struct Fixture {
        let basis: ReconstructionProductionRoundBasis
        let cut: ReconstructionProductionCommittedRoundCut
        let author: ReconstructionProductionReceiptPlanAuthor
        let batchResultTaskID: UUID?
    }

    func makeBatchFixture(functionBatch: Bool = false,
        functionFacets: [String: String]? = nil) async throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(),
            jobID: foundation.job.jobID,
            kind: .ingest,
            subject: .artifact(artifact),
            dependencies: [],
            state: .completed
        )
        let classify = try task(
            id: UUID(),
            jobID: foundation.job.jobID,
            kind: .classify,
            subject: .artifact(artifact),
            dependencies: [ingest.identity.taskID],
            state: .completed
        )
        let discover = try task(
            id: UUID(),
            jobID: foundation.job.jobID,
            kind: .discoverRelations,
            subject: .artifact(artifact),
            dependencies: [classify.identity.taskID],
            state: functionBatch ? .completed : .pending
        )
        var tasks = [ingest, classify, discover]
        var terminalTask = discover
        var projection: ReconstructionTransientAnalysisProjection?
        var currentImages: [ReconstructionImageCoordinate] = []
        var currentFacets: [ReconstructionSubjectCoordinate: [String: String]] = [:]
        if functionBatch {
            let image = ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
                selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
            let coordinate = try ReconstructionImageCoordinate(artifact: artifact, image: image,
                analysisFingerprintSHA256: digest("d"))
            let function = try ReconstructionFunctionCoordinate(artifact: artifact, image: image,
                analysisFingerprintSHA256: digest("d"), startAddress: 0x1000, endAddressExclusive: 0x1010,
                boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
            let load = try task(id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
                subject: .artifact(artifact), dependencies: [ingest.identity.taskID], state: .completed)
            let index = try task(id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
                subject: .image(coordinate), dependencies: [load.identity.taskID], state: .completed)
            let enumeration = try task(id: UUID(), jobID: foundation.job.jobID, kind: .enumerateFunctions,
                subject: .image(coordinate), dependencies: [index.identity.taskID], state: .completed)
            terminalTask = try task(id: UUID(), jobID: foundation.job.jobID, kind: .decompileMacScope,
                subject: .function(function), dependencies: [enumeration.identity.taskID], state: .pending)
            tasks += [load, index, enumeration, terminalTask]
            currentImages = [coordinate]
            if let functionFacets { currentFacets[.function(function)] = functionFacets }
            projection = try ReconstructionTransientAnalysisProjection(taskID: terminalTask.identity.taskID,
                taskKind: .decompileMacScope, artifact: artifact, image: image,
                analysisFingerprintSHA256: digest("d"), functionCatalog: [],
                function: .init(id: ReconstructionStableImageAuthority.stableFunctionID(image: image,
                    analysisFingerprintSHA256: digest("d"), startAddress: 0x1000, endAddressExclusive: 0x1010,
                    boundarySchemaVersion: 1), name: "entry", startAddress: 0x1000, endAddress: 0x1010,
                    confidence: 1), macScopePseudocode: "return 0;")
        }
        let basis = try makeBasis(
            foundation: foundation,
            tasks: tasks, currentImages: currentImages, currentFacetFingerprints: currentFacets
        )
        let prepared = try ReconstructionProductionPreparedRoundBuilder
            .makeDirectCommitDescriptor(from: basis)
        let result = ReconstructionTerminalTaskResult(
            jobID: basis.job.jobID,
            taskID: terminalTask.identity.taskID,
            checkpointID: basis.checkpoint.checkpointID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            outcome: .completed, analysisProjection: projection
        )
        return Fixture(
            basis: basis,
            cut: cut(basis: basis, prepared: prepared, results: [result]),
            author: author(),
            batchResultTaskID: terminalTask.identity.taskID
        )
    }

    func makeFailedBatchFixture() async throws -> (Fixture, UUID) {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .pending
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID], state: .pending
        )
        let basis = try makeBasis(foundation: foundation, tasks: [ingest, classify])
        let prepared = try ReconstructionProductionPreparedRoundBuilder
            .makeDirectCommitDescriptor(from: basis)
        let result = ReconstructionTerminalTaskResult(
            jobID: basis.job.jobID,
            taskID: ingest.identity.taskID,
            checkpointID: basis.checkpoint.checkpointID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            outcome: .failed
        )
        return (
            Fixture(
                basis: basis,
                cut: cut(basis: basis, prepared: prepared, results: [result]),
                author: author(),
                batchResultTaskID: ingest.identity.taskID
            ),
            classify.identity.taskID
        )
    }

    func makeModelFixture(
        contextOperationIdentity: String = "reconstruction.modelRound.v1",
        additionalToolRequest: Bool = false,
        crossedGapAuthority: Bool = false,
        resolvableGapAuthority: Bool = false,
        refreshRequest: Bool = false,
        sourceProfileID: String? = nil
    ) async throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let classify = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .classify,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID], state: .completed
        )
        let discover = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .discoverRelations,
            subject: .artifact(artifact), dependencies: [classify.identity.taskID], state: .completed
        )
        let retrieve = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .retrieveEvidence,
            subject: nil, dependencies: [discover.identity.taskID], state: .running
        )
        let model = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .modelRound,
            subject: nil, dependencies: [retrieve.identity.taskID], state: .running
        )
        let checkpoint = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .checkpoint,
            subject: nil, dependencies: [model.identity.taskID], state: .pending
        )
        var gaps: [ReconstructionEvidenceGap] = []
        var currentImages: [ReconstructionImageCoordinate] = []
        if crossedGapAuthority {
            let image = try ReconstructionImageCoordinate(
                artifact: artifact,
                image: ReconstructionImageBinding(
                    binaryID: ReconstructionStableImageAuthority.stableBinaryID(
                        occurrenceID: artifact.occurrenceID,
                        selectedSliceIndex: nil
                    ),
                    imageSlot: .primary,
                    selectedSliceIndex: nil,
                    architecture: .arm64,
                    machOIdentity: nil
                ),
                analysisFingerprintSHA256: digest("d")
            )
            gaps = [
                try gap(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000009201")!,
                    subject: .artifact(artifact),
                    operationID: .corpusSummary
                ),
                try gap(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000009202")!,
                    subject: .image(image),
                    operationID: .imagesPage
                ),
            ]
            currentImages = [image]
        } else if resolvableGapAuthority {
            gaps = [try gap(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000009203")!,
                subject: .artifact(artifact),
                operationID: .corpusArtifactDescribe
            )]
        }
        var basis = try makeBasis(
            foundation: foundation,
            tasks: [ingest, classify, discover, retrieve, model, checkpoint],
            gaps: gaps,
            currentImages: currentImages,
            sourceProfileID: sourceProfileID
        )
        if resolvableGapAuthority {
            basis = try basisByAddingAcceptedCurrentEvidence(
                basis,
                sourceTaskID: ingest.identity.taskID,
                subject: .artifact(artifact),
                operation: .corpusArtifactDescribe
            )
        }
        let receiptAuthor = author(operationIdentity: contextOperationIdentity)
        let basePrepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: try receiptAuthor.makeToolProducer(operationID: .evidenceQuery)
        )
            .makePreparedRound(from: basis)
        let prepared: ReconstructionPreparedModelRound
        if refreshRequest {
            let retrieveRequest = try XCTUnwrap(basePrepared.requests.first)
            let image = ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
                selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
            let function = try ReconstructionFunctionCoordinate(artifact: artifact, image: image,
                analysisFingerprintSHA256: digest("d"), startAddress: 0x1000,
                endAddressExclusive: 0x1010,
                boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
                functionUUIDHint: nil, symbolHint: nil)
            let request = ReconstructionToolRequest(operationID: .analysisMacScopeRefresh,
                taskID: retrieveRequest.taskID, subject: .function(function), retrievalQuery: nil,
                offset: 0, maximumRecords: 1, maximumEncodedBytes: 4_096)
            prepared = ReconstructionPreparedModelRound(roundID: basePrepared.roundID,
                evidenceCut: basePrepared.evidenceCut, retrievalQuery: basePrepared.retrievalQuery,
                allowedGapSubjects: basePrepared.allowedGapSubjects,
                allowedGapCategories: basePrepared.allowedGapCategories,
                authority: basePrepared.authority, requests: basePrepared.requests + [request],
                projectorInput: basePrepared.projectorInput,
                finalSynthesisRequest: basePrepared.finalSynthesisRequest,
                objective: basePrepared.objective)
        } else if additionalToolRequest {
            let retrieveRequest = try XCTUnwrap(basePrepared.requests.first)
            let checkpointRequest = ReconstructionToolRequest(
                operationID: .checkpointStatus,
                taskID: retrieveRequest.taskID,
                subject: nil,
                retrievalQuery: nil,
                offset: 0,
                maximumRecords: 1,
                maximumEncodedBytes: 64
            )
            prepared = ReconstructionPreparedModelRound(
                roundID: basePrepared.roundID,
                evidenceCut: basePrepared.evidenceCut,
                retrievalQuery: basePrepared.retrievalQuery,
                allowedGapSubjects: basePrepared.allowedGapSubjects,
                allowedGapCategories: basePrepared.allowedGapCategories,
                authority: basePrepared.authority,
                requests: basePrepared.requests + [checkpointRequest],
                projectorInput: basePrepared.projectorInput,
                finalSynthesisRequest: basePrepared.finalSynthesisRequest,
                objective: basePrepared.objective
            )
        } else {
            prepared = basePrepared
        }
        return Fixture(
            basis: basis,
            cut: cut(basis: basis, prepared: prepared, results: []),
            author: receiptAuthor,
            batchResultTaskID: nil
        )
    }

    /// Controlled 37-row observation; no native execution or model response is claimed by this fixture.
    /// Its terminal payload is admitted by the production oracle codec and published only by the
    /// production batch planner/receipt author under test.
    func makeOracleBatchFixture() async throws -> Fixture {
        let native = try await makeNativeTransientBasis()
        let base = native.basis
        let function = try XCTUnwrap(native.functions.first)
        var tasks = base.tasks.map { record in
            ReconstructionTaskRecord(identity: record.identity, state: .completed, diagnostic: nil)
        }
        let ordinaryModel = try XCTUnwrap(tasks.first { $0.identity.kind == .modelRound })
        let retrieve = try XCTUnwrap(tasks.first { $0.identity.kind == .retrieveEvidence })
        let ordinaryCheckpoint = try XCTUnwrap(tasks.first { $0.identity.kind == .checkpoint })
        let sourceTasks = try ReconstructionProductionRoundPlanBuilder.makeSourceExecutionLeafTasks(
            jobID: base.job.jobID, function: function,
            predecessorCheckpointID: ordinaryCheckpoint.identity.taskID,
            contract: ReconstructionSourceExecutionTaskContract.oracle, tasks: tasks,
            maximumTasks: base.job.budget.maxTasks)
        tasks += sourceTasks
        let modelReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: UUID(), jobID: base.job.jobID, taskID: ordinaryModel.identity.taskID,
            checkpointRevision: 10, requestIdentitySHA256: digest("e"),
            producer: ProductionSourceOwnerFixture.producer(ReconstructionProductionTaskContract.modelRound),
            terminalState: .completed, selectedHandleIDs: [], acceptedEvidenceIDs: [], diagnostic: nil)
        let parent = try ProductionSourceOwnerFixture.checkpoint(id: UUID(), revision: 11,
            parent: base.checkpoint, manifest: base.manifest, frontier: base.evidenceCut.frontierSHA256,
            tasks: tasks, modelReceipts: [modelReceipt], toolReceipts: base.toolReceipts, jobID: base.job.jobID)
        let checkpoint = try ProductionSourceOwnerFixture.checkpoint(id: UUID(), revision: 12,
            parent: parent, manifest: base.manifest, frontier: base.evidenceCut.frontierSHA256,
            tasks: tasks, modelReceipts: [modelReceipt], toolReceipts: base.toolReceipts, jobID: base.job.jobID)
        let job = try ReconstructionJobRecord(jobID: base.job.jobID,
            reconstructionProjectID: base.project.projectID, objective: base.job.objective,
            objectiveSHA256: base.job.objectiveSHA256,
            creationCorpusManifestSHA256: base.manifest.canonicalSHA256, state: .retrieving,
            currentCheckpointID: checkpoint.checkpointID, terminalReason: nil,
            budget: base.job.budget, creationOrdinal: try XCTUnwrap(base.job.creationOrdinal),
            focus: .artifact(function.artifact), sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        let completionAuthorities: [ReconstructionProductionTaskCompletionAuthority] = [
            .init(taskID: retrieve.identity.taskID, firstCompletedAtRevision: 10),
            .init(taskID: ordinaryModel.identity.taskID, firstCompletedAtRevision: 10)]
        let consecutive = try ReconstructionProductionModelRoundBudgetAuthority.consecutiveRoundsWithoutEvidence(
            jobID: job.jobID, tasks: tasks, toolReceipts: base.toolReceipts,
            modelReceipts: [modelReceipt], taskCompletionAuthorities: completionAuthorities)
        let snapshot = ReconstructionJobOrchestrationSnapshot(jobID: job.jobID,
            jobCreationOrder: try XCTUnwrap(job.creationOrdinal), checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: base.manifest.canonicalSHA256,
            checkpointEvidenceFrontierSHA256: base.evidenceCut.frontierSHA256,
            currentCorpusManifestSHA256: base.manifest.canonicalSHA256,
            evidenceFrontierSHA256: base.evidenceCut.frontierSHA256, currentDurableJobState: .retrieving,
            pauseContext: nil, maximumRoundsWithoutEvidence: job.budget.maxRounds, tasks: tasks,
            terminalReceiptStatesByTaskID: [ordinaryModel.identity.taskID: .completed],
            consecutiveModelRoundsWithoutEvidence: consecutive,
            terminalReceiptCheckpointRevisionsByTaskID: [ordinaryModel.identity.taskID: 10])
        let basis = try ReconstructionProductionRoundBasis(workspaceID: base.workspaceID,
            project: base.project, manifest: base.manifest, job: job, checkpoint: checkpoint,
            tasks: tasks, toolReceipts: base.toolReceipts, modelReceipts: [modelReceipt],
            taskCompletionAuthorities: completionAuthorities, attachmentSources: base.attachmentSources,
            evidenceCut: base.evidenceCut, freshnessAuthority: base.freshnessAuthority, snapshot: snapshot,
            checkpointHistory: [base.checkpoint, parent])
        let receiptAuthor = author()
        let producer = try receiptAuthor.makeSourceToolProducer(contract: ReconstructionSourceExecutionTaskContract.oracle)
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let oracle = try ReconstructionSourceOracleEvidence.admit(authority: .init(
            projectID: basis.project.projectID, jobID: job.jobID, function: function,
            execution: .init(originalImageSHA256: function.artifact.contentIdentity.digest,
                originalExecutableSHA256: function.artifact.contentIdentity.digest,
                originalSourceSHA256: digest("c"),
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: digest("d"), sdkIdentitySHA256: digest("e"),
                compileProfileSHA256: digest("f"), compileArgumentsSHA256: digest("a"),
                executionArgumentsSHA256: digest("b"), producerSHA256: producer.canonicalSHA256,
                standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8),
                sessionID: UUID(), requestID: UUID(), processIdentifier: 123,
                sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true),
            evidenceIDs: basis.evidenceCut.records.map(\.evidenceID)))
        let sourceTask = try XCTUnwrap(sourceTasks.first { $0.identity.kind == .executeSource })
        let result = ReconstructionTerminalTaskResult(jobID: job.jobID, taskID: sourceTask.identity.taskID,
            checkpointID: checkpoint.checkpointID, checkpointRevision: checkpoint.revision,
            corpusManifestSHA256: base.manifest.canonicalSHA256, outcome: .completed,
            sourceExecution: .oracle(oracle))
        let prepared = try ReconstructionProductionPreparedRoundBuilder.makeDirectCommitDescriptor(from: basis)
        return Fixture(basis: basis, cut: cut(basis: basis, prepared: prepared, results: [result]),
            author: receiptAuthor, batchResultTaskID: sourceTask.identity.taskID)
    }

    func makeFinalFixture(sourceProfileID: String? = nil) async throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID()
        )
        let artifact = ReconstructionArtifactCoordinate(
            occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity
        )
        let ingest = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .ingest,
            subject: .artifact(artifact), dependencies: [], state: .completed
        )
        let finalModel = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .modelRound,
            subject: nil, dependencies: [ingest.identity.taskID], state: .running,
            operationContractIdentity: ReconstructionProductionTaskContract.finalSynthesis
        )
        let checkpoint = try task(
            id: UUID(), jobID: foundation.job.jobID, kind: .checkpoint,
            subject: nil, dependencies: [finalModel.identity.taskID], state: .pending
        )
        let basis = try makeBasis(
            foundation: foundation,
            tasks: [ingest, finalModel, checkpoint],
            sourceProfileID: sourceProfileID
        )
        let receiptAuthor = author()
        let prepared = try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: try receiptAuthor.makeToolProducer(
                operationID: .evidenceQuery
            )
        ).makePreparedRound(from: basis)
        XCTAssertNotNil(prepared.finalSynthesisRequest)
        XCTAssertTrue(prepared.requests.isEmpty)
        return Fixture(
            basis: basis,
            cut: cut(basis: basis, prepared: prepared, results: []),
            author: receiptAuthor,
            batchResultTaskID: nil
        )
    }

    func finalAuthorInputs(
        fixture: Fixture,
        candidate: ReconstructionFinalSynthesisCandidate
    ) throws -> (
        basePlan: ReconstructionJobCommitPlan,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) {
        let request = try XCTUnwrap(fixture.cut.prepared.finalSynthesisRequest)
        let finalModel = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .modelRound
                && $0.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.finalSynthesis
        })
        let checkpointTask = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .checkpoint
                && $0.identity.dependencyTaskIDs == [finalModel.identity.taskID]
        })
        let successorRevision = fixture.basis.checkpoint.revision + 1
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: UUID(),
            jobID: fixture.basis.job.jobID,
            revision: successorRevision,
            parentCheckpointID: fixture.basis.checkpoint.checkpointID,
            parentCheckpointSHA256: fixture.basis.checkpoint.canonicalSHA256,
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: fixture.basis.evidenceCut.frontierSHA256,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: fixture.basis.tasks.map(\.identity.taskID),
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: fixture.basis.checkpoint
                .unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: fixture.basis.checkpoint.toolReceiptIDs,
            coordinatorState: .completed,
            terminalReason: nil
        )
        let transitions = [
            ReconstructionTaskTransition(
                taskID: finalModel.identity.taskID,
                expectedState: .running,
                successorState: .completed,
                diagnostic: nil
            ),
            ReconstructionTaskTransition(
                taskID: checkpointTask.identity.taskID,
                expectedState: .pending,
                successorState: .completed,
                diagnostic: nil
            ),
        ]
        let basePlan = ReconstructionJobCommitPlan(
            successorRevision: successorRevision,
            acceptedEvidenceCount: 0,
            disposition: .completed,
            mutation: ReconstructionCheckpointMutation(
                jobID: fixture.basis.job.jobID,
                expectedParentCheckpointID: fixture.basis.checkpoint.checkpointID,
                expectedParentCheckpointSHA256: fixture.basis.checkpoint.canonicalSHA256,
                expectedParentRevision: fixture.basis.checkpoint.revision,
                evidence: [],
                evidenceRelations: [],
                toolReceipts: [],
                modelReceipts: [],
                taskTransitions: transitions,
                freshnessAuthority: fixture.basis.freshnessAuthority,
                successorCheckpoint: successor
            )
        )
        let terminal = ReconstructionTerminalReceipt(
            requestID: receiptID,
            jobID: fixture.basis.job.jobID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            roundID: nil,
            status: .completed
        )
        let synthesis = ReconstructionFinalSynthesisExecutionResult(
            candidate: candidate,
            usage: .init(promptTokens: 2, completionTokens: 3, totalTokens: 5),
            terminalReceipt: terminal
        )
        return (
            basePlan,
            try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: terminal.requestID,
                request: fixture.cut.prepared.objective.map {
                    .finalSynthesisR2(.init(protocolVersion: 9, objective: $0, request: request))
                } ?? .finalSynthesis(request),
                terminalReceipt: terminal
            ),
            synthesis
        )
    }

    func baseBatchPlan(_ fixture: Fixture) async throws -> ReconstructionJobCommitPlan {
        let registry = ReconstructionProductionRoundBasisRegistry(
            basis: fixture.basis,
            prepared: fixture.cut.prepared
        )
        let builder = ReconstructionProductionRoundPlanBuilder(
            basisRegistry: registry,
            receiptAuthor: PassThroughReceiptAuthor()
        )
        let optionalPlan = try await builder.makePreInferenceCommitPlan(cut: fixture.cut)
        return try XCTUnwrap(optionalPlan)
    }

    func modelAuthorInputs(
        fixture: Fixture,
        inference: ReconstructionInferenceExecutionResult,
        contextCompiler: ReconstructionContextCompiler = .init()
    ) throws -> (
        basePlan: ReconstructionJobCommitPlan,
        requestAuthority: ReconstructionModelTerminalRequestAuthority
    ) {
        let request = try roundRequest(fixture, contextCompiler: contextCompiler)
        let authority = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: inference.terminalReceipt.requestID,
            request: fixture.cut.prepared.objective.map {
                .roundR2(.init(protocolVersion: 9, objective: $0, request: request))
            } ?? .round(request),
            terminalReceipt: inference.terminalReceipt
        )
        let successorRevision = fixture.basis.checkpoint.revision + 1
        let disposition: ReconstructionJobCoordinatorDisposition
        let coordinatorState: ReconstructionJobState
        let pauseContext: ReconstructionJobPauseContext?
        switch inference.candidate.disposition {
        case .continue, .sufficientEvidence:
            disposition = .continue
            coordinatorState = try XCTUnwrap(
                fixture.basis.snapshot.currentDurableActiveState
            )
            pauseContext = nil
        case .blocked:
            disposition = .paused(.evidenceStalled)
            coordinatorState = .paused
            pauseContext = try ReconstructionJobPauseContext(
                cause: .evidenceStalled,
                resumeTarget: try XCTUnwrap(
                    fixture.basis.snapshot.currentDurableActiveState
                )
            )
        }
        let successor = try ReconstructionCheckpoint.make(
            checkpointID: UUID(),
            jobID: fixture.basis.job.jobID,
            revision: successorRevision,
            parentCheckpointID: fixture.basis.checkpoint.checkpointID,
            parentCheckpointSHA256: fixture.basis.checkpoint.canonicalSHA256,
            corpusManifestSHA256: fixture.basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: fixture.basis.evidenceCut.frontierSHA256,
            pendingTaskIDs: fixture.basis.tasks.filter { $0.state == .pending }
                .map(\.identity.taskID),
            runningTaskIDs: fixture.basis.tasks.filter { $0.state == .running }
                .map(\.identity.taskID),
            completedTaskIDs: fixture.basis.tasks.filter { $0.state == .completed }
                .map(\.identity.taskID),
            failedTaskIDs: fixture.basis.tasks.filter {
                $0.state == .failed || $0.state == .cancelled
            }.map(\.identity.taskID),
            blockedTaskIDs: fixture.basis.tasks.filter { $0.state == .blocked }
                .map(\.identity.taskID),
            unresolvedEvidenceGapSHA256: fixture.basis.checkpoint
                .unresolvedEvidenceGapSHA256,
            modelReceiptIDs: fixture.basis.checkpoint.modelReceiptIDs,
            toolReceiptIDs: fixture.basis.checkpoint.toolReceiptIDs,
            coordinatorState: coordinatorState,
            terminalReason: nil
        )
        let mutation = ReconstructionCheckpointMutation(
            jobID: fixture.basis.job.jobID,
            expectedParentCheckpointID: fixture.basis.checkpoint.checkpointID,
            expectedParentCheckpointSHA256: fixture.basis.checkpoint.canonicalSHA256,
            expectedParentRevision: fixture.basis.checkpoint.revision,
            evidence: [],
            evidenceRelations: [],
            toolReceipts: [],
            modelReceipts: [],
            taskTransitions: [],
            freshnessAuthority: fixture.basis.freshnessAuthority,
            successorCheckpoint: successor,
            successorPauseContext: pauseContext
        )
        return (
            ReconstructionJobCommitPlan(
                successorRevision: successorRevision,
                acceptedEvidenceCount: 0,
                disposition: disposition,
                mutation: mutation
            ),
            authority
        )
    }

    func roundRequest(_ fixture: Fixture, contextCompiler: ReconstructionContextCompiler = .init())
        throws -> ReconstructionInferenceRoundRequest {
        let prepared = fixture.cut.prepared
        let context = try contextCompiler.compile(
            cut: prepared.evidenceCut,
            query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories
        )
        let handles = try ReconstructionToolRegistry().mintHandles(
            authority: prepared.authority,
            requests: prepared.requests
        )
        return ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: fixture.basis.job.jobID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            roundID: prepared.roundID,
            corpusManifestSHA256: prepared.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: prepared.authority.evidenceFrontierSHA256,
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
                .toolRegistry.identity.sha256,
            context: context,
            handles: handles.map {
                .init(handleID: $0.handleID, operationID: $0.operationID)
            },
            transientAnalysis: prepared.objective == nil ? nil : prepared.transientAnalysis
        )
    }

    func makeBasis(
        foundation: ReconstructionDatabaseTestFixtures.StateFixture,
        tasks: [ReconstructionTaskRecord],
        gaps: [ReconstructionEvidenceGap] = [],
        currentImages: [ReconstructionImageCoordinate] = [],
        currentFacetFingerprints: [ReconstructionSubjectCoordinate: [String: String]] = [:],
        maximumTasks: Int = 32,
        focus: ReconstructionSubjectCoordinate? = nil,
        sourceProfileID: String? = nil
    ) throws -> ReconstructionProductionRoundBasis {
        let manifest = foundation.manifest
        let evidenceFrontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: gaps,
            checkpointRevisionsByID: [:]
        )
        let evidenceCut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            relations: [],
            gaps: gaps,
            frontierSHA256: evidenceFrontier,
            projectedClassificationsByEvidenceID: [:],
            checkpointRevisionsByID: [:]
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: UUID(),
            jobID: foundation.job.jobID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceFrontier,
            pendingTaskIDs: tasks.filter { $0.state == .pending }.map(\.identity.taskID),
            runningTaskIDs: tasks.filter { $0.state == .running }.map(\.identity.taskID),
            completedTaskIDs: tasks.filter { $0.state == .completed }.map(\.identity.taskID),
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: try ReconstructionEvidenceGapFrontier
                .canonicalSHA256(for: gaps),
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
            creationCorpusManifestSHA256: manifest.canonicalSHA256,
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
            focus: focus,
            sourceProfileID: sourceProfileID
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: job.jobID,
            jobCreationOrder: 1,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceFrontier,
            currentDurableJobState: .retrieving,
            pauseContext: nil,
            maximumRoundsWithoutEvidence: 8,
            tasks: tasks,
            terminalReceiptStatesByTaskID: [:]
        )
        let artifacts = manifest.artifacts.map {
            ReconstructionArtifactCoordinate(
                occurrenceID: $0.occurrenceID,
                contentIdentity: $0.contentIdentity
            )
        }
        return try ReconstructionProductionRoundBasis(
            workspaceID: UUID(),
            project: foundation.project,
            manifest: manifest,
            job: job,
            checkpoint: checkpoint,
            tasks: tasks,
            toolReceipts: [],
            modelReceipts: [],
            attachmentSources: manifest.artifacts.map {
                ReconstructionAttachmentSource(
                    contentIdentity: $0.contentIdentity,
                    verifiedURL: URL(
                        fileURLWithPath: "/tmp/reconstruction-receipt-author-\($0.contentIdentity.digest)"
                    )
                )
            },
            evidenceCut: evidenceCut,
            freshnessAuthority: try ReconstructionFreshnessAuthority(
                corpusManifestSHA256: manifest.canonicalSHA256,
                currentArtifacts: artifacts,
                currentImages: currentImages,
                currentFacetFingerprints: currentFacetFingerprints
            ),
            snapshot: snapshot
        )
    }

    func cut(
        basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound,
        results: [ReconstructionTerminalTaskResult]
    ) -> ReconstructionProductionCommittedRoundCut {
        ReconstructionProductionCommittedRoundCut(
            snapshot: basis.snapshot,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            prepared: prepared,
            batchTerminalResults: results
        )
    }

    func author(
        operationIdentity: String = "reconstruction.modelRound.v1",
        contextCompiler: ReconstructionContextCompiler = .init()
    ) -> ReconstructionProductionReceiptPlanAuthor {
        ReconstructionProductionReceiptPlanAuthor(
            modelProducerContext: ReconstructionModelProducerIdentityContext(
                macScopeBuildIdentity: digest("a"),
                macScopeSourceIdentity: digest("b"),
                operationIdentity: operationIdentity,
                registryIdentity: Phase2ReconstructionProtocolArtifacts.make()
                    .toolRegistry.identity.sha256,
                protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2
                    .manifestDigest,
                toolchainIdentity: "17A123"
            ),
            contextCompiler: contextCompiler
        )
    }

    func inference(
        fixture: Fixture,
        selectedHandleIDs: [UUID],
        disposition: ReconstructionInferenceDisposition,
        unresolvedGaps: [ReconstructionEvidenceGapDeclaration] = [],
        resolvedGaps: [ReconstructionEvidenceGapResolutionClaim] = []
    ) -> ReconstructionInferenceExecutionResult {
        ReconstructionInferenceExecutionResult(
            candidate: ReconstructionInferenceRoundCandidate(
                jobID: fixture.basis.job.jobID,
                checkpointRevision: fixture.basis.checkpoint.revision,
                roundID: fixture.cut.prepared.roundID,
                selectedHandleIDs: selectedHandleIDs,
                disposition: disposition,
                unresolvedGaps: unresolvedGaps,
                resolvedGaps: resolvedGaps
            ),
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2),
            terminalReceipt: ReconstructionTerminalReceipt(
                requestID: receiptID,
                jobID: fixture.basis.job.jobID,
                checkpointRevision: fixture.basis.checkpoint.revision,
                roundID: fixture.cut.prepared.roundID,
                status: .completed
            )
        )
    }

    func lease(providerRevision: UInt64) throws -> Phase2ReadyInferenceLease {
        .init(
            providerRevision: providerRevision,
            configuration: try Phase2AIProviderConfiguration(
                profileID: UUID(uuidString: "00000000-0000-0000-0000-000000009100")!,
                generation: 7,
                endpointOrigin: "http://127.0.0.1:1234",
                model: "local-model",
                maximumTokens: 1_024,
                requestTimeoutMilliseconds: 10_000,
                resourceTimeoutMilliseconds: 60_000
            ),
            observedModelInventorySHA256: digest("c")
        )
    }

    func toolExecution(
        handle: MacScopeAnalysisCore.ReconstructionToolHandle,
        fixture: Fixture
    ) throws -> ReconstructionToolExecution {
        let retrieve = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .retrieveEvidence
        })
        let producer = try toolProducer(operation: handle.operationID)
        let result: ReconstructionToolProjectionResult
        if handle.operationID == .evidenceQuery {
            let envelope = try ReconstructionToolRegistry().decodeCanonicalRequest(handle)
            let query = try XCTUnwrap(envelope.retrievalQuery)
            let packet = try ReconstructionRetrievalCompiler().compile(
                cut: fixture.basis.evidenceCut, query: query)
            if let cursor = packet.nextCursor, packet.hasMore {
                let nextQuery = try ReconstructionRetrievalQuery(
                    corpusManifestSHA256: query.corpusManifestSHA256, subject: query.subject,
                    operationIDs: query.operationIDs, classifications: query.classifications,
                    cursor: cursor, maximumRecords: query.maximumRecords,
                    maximumEncodedBytes: query.maximumEncodedBytes, focus: query.focus)
                result = .truncated(payload: packet.canonicalBytes, count: packet.records.count,
                    continuationRequest: .init(operationID: .evidenceQuery, taskID: envelope.taskID,
                        subject: envelope.subject, retrievalQuery: nextQuery, offset: 1,
                        maximumRecords: nextQuery.maximumRecords,
                        maximumEncodedBytes: nextQuery.maximumEncodedBytes))
            } else {
                result = .success(payload: packet.canonicalBytes, count: packet.records.count)
            }
        } else { result = .success(payload: Data("[]".utf8), count: 0) }
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: handle.handleID,
            jobID: fixture.basis.job.jobID,
            taskID: retrieve.identity.taskID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            requestIdentitySHA256: handle.requestSHA256,
            producer: producer,
            terminalState: result.outcome == .truncated ? .truncated : .completed,
            outputEvidenceIDs: [],
            diagnostic: nil
        )
        return ReconstructionToolExecution(
            handleID: handle.handleID,
            operationID: handle.operationID,
            result: result,
            acceptedEvidence: [],
            receipt: receipt
        )
    }

    func retrievedEvidenceExecution(
        handle: MacScopeAnalysisCore.ReconstructionToolHandle,
        fixture: Fixture,
        resolvedGapIDs: [UUID]
    ) throws -> ReconstructionToolExecution {
        let retrieve = try XCTUnwrap(fixture.basis.tasks.first {
            $0.identity.kind == .retrieveEvidence && $0.state == .running
        })
        let packet = try ReconstructionRetrievalCompiler().compile(
            cut: fixture.cut.prepared.evidenceCut,
            query: fixture.cut.prepared.retrievalQuery
        )
        XCTAssertFalse(packet.hasMore)
        let producer = try toolProducer(operation: handle.operationID)
        let result = ReconstructionToolProjectionResult.success(
            payload: packet.canonicalBytes,
            count: packet.records.count
        )
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: handle.handleID,
            jobID: fixture.basis.job.jobID,
            taskID: retrieve.identity.taskID,
            checkpointRevision: fixture.basis.checkpoint.revision,
            requestIdentitySHA256: handle.requestSHA256,
            producer: producer,
            terminalState: .completed,
            outputEvidenceIDs: [],
            diagnostic: nil
        )
        return ReconstructionToolExecution(
            handleID: handle.handleID,
            operationID: handle.operationID,
            result: result,
            acceptedEvidence: [],
            receipt: receipt,
            resolvedGapIDs: resolvedGapIDs
        )
    }

    func basisByAddingAcceptedCurrentEvidence(
        _ basis: ReconstructionProductionRoundBasis,
        sourceTaskID: UUID,
        subject: ReconstructionSubjectCoordinate,
        operation: MacScopeAnalysisCore.ReconstructionOperationID,
        recordCount: Int = 1,
        payloadPaddingBytes: Int = 0,
        maximumEncodedBytes: UInt64? = nil
    ) throws -> ReconstructionProductionRoundBasis {
        let receiptID = UUID(uuidString: "00000000-0000-0000-0000-000000009302")!
        let job = try maximumEncodedBytes.map { maximumEncodedBytes in
            try ReconstructionJobRecord(
                jobID: basis.job.jobID,
                reconstructionProjectID: basis.job.reconstructionProjectID,
                objective: basis.job.objective,
                objectiveSHA256: basis.job.objectiveSHA256,
                creationCorpusManifestSHA256: basis.job.creationCorpusManifestSHA256,
                state: basis.job.state,
                currentCheckpointID: basis.job.currentCheckpointID,
                terminalReason: basis.job.terminalReason,
                budget: try ReconstructionJobBudget(
                    maxRounds: basis.job.budget.maxRounds,
                    maxTasks: basis.job.budget.maxTasks,
                    maxEvidenceRecords: basis.job.budget.maxEvidenceRecords,
                    maxEncodedBytes: maximumEncodedBytes
                ),
                creationOrdinal: try XCTUnwrap(basis.job.creationOrdinal),
                pauseContext: basis.job.pauseContext,
                focus: basis.job.focus,
                sourceProfileID: basis.job.sourceProfileID
            )
        } ?? basis.job
        let producer = try toolProducer(operation: operation)
        let records = try (0..<recordCount).map { index in
        let evidenceID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9301 + index * 10))!
        let summary = recordCount == 1 ? "durable-current" : "durable-current-\(index)"
        let payload = payloadPaddingBytes == 0
            ? Data("{\"summary\":\"\(summary)\"}".utf8)
            : Data("{\"summary\":\"\(summary)\",\"padding\":\"\(String(repeating: "x", count: payloadPaddingBytes))\"}".utf8)
        return try ReconstructionEvidenceRecord(
            evidenceID: evidenceID,
            subject: subject,
            operationID: operation.rawValue,
            payloadKind: .structuredJSON,
            payload: payload,
            payloadByteCount: UInt64(payload.count),
            payloadSHA256: SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }.joined(),
            facetDependencies: [],
            producer: producer,
            citations: [try ReconstructionEvidenceCitation(
                citationID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9303 + index * 10))!,
                sourceEvidenceID: nil,
                subject: subject,
                locator: "committed-source-task"
            )],
            creatingJobID: basis.job.jobID,
            creatingTaskID: sourceTaskID,
            creatingCheckpointID: basis.checkpoint.checkpointID,
            modelReceiptID: nil,
            toolReceiptID: receiptID,
            classification: .acceptedCurrent,
            supersedesEvidenceID: nil,
            supersededByEvidenceID: nil,
            diagnostic: nil
        )
        }
        let evidenceIDs = records.map(\.evidenceID)
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: receiptID,
            jobID: basis.job.jobID,
            taskID: sourceTaskID,
            checkpointRevision: basis.checkpoint.revision,
            requestIdentitySHA256: digest("e"),
            producer: producer,
            terminalState: .completed,
            outputEvidenceIDs: evidenceIDs,
            diagnostic: nil
        )
        let classifications = Dictionary(uniqueKeysWithValues: evidenceIDs.map { ($0, ReconstructionEvidenceClassification.acceptedCurrent) })
        let revisions = [basis.checkpoint.checkpointID: basis.checkpoint.revision]
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            records: records,
            projectedClassificationsByEvidenceID: classifications,
            relations: [],
            gaps: basis.evidenceCut.gaps,
            checkpointRevisionsByID: revisions
        )
        let cut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            records: records,
            relations: [],
            gaps: basis.evidenceCut.gaps,
            frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: revisions
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: basis.checkpoint.checkpointID,
            jobID: basis.job.jobID,
            revision: basis.checkpoint.revision,
            parentCheckpointID: basis.checkpoint.parentCheckpointID,
            parentCheckpointSHA256: basis.checkpoint.parentCheckpointSHA256,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: frontier,
            pendingTaskIDs: basis.checkpoint.pendingTaskIDs,
            runningTaskIDs: basis.checkpoint.runningTaskIDs,
            completedTaskIDs: basis.checkpoint.completedTaskIDs,
            failedTaskIDs: basis.checkpoint.failedTaskIDs,
            blockedTaskIDs: basis.checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: basis.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [receiptID],
            coordinatorState: basis.checkpoint.coordinatorState,
            terminalReason: nil
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: basis.snapshot.jobID,
            jobCreationOrder: basis.snapshot.jobCreationOrder,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: frontier,
            currentCorpusManifestSHA256: basis.snapshot.currentCorpusManifestSHA256,
            evidenceFrontierSHA256: frontier,
            currentDurableJobState: basis.snapshot.currentDurableJobState,
            pauseContext: basis.snapshot.pauseContext,
            maximumRoundsWithoutEvidence: basis.snapshot.maximumRoundsWithoutEvidence,
            tasks: basis.tasks,
            terminalReceiptStatesByTaskID: [sourceTaskID: .completed],
            consecutiveModelRoundsWithoutEvidence:
                basis.snapshot.consecutiveModelRoundsWithoutEvidence
        )
        return try ReconstructionProductionRoundBasis(
            workspaceID: basis.workspaceID,
            project: basis.project,
            manifest: basis.manifest,
            job: job,
            checkpoint: checkpoint,
            tasks: basis.tasks,
            toolReceipts: [receipt],
            modelReceipts: [],
            attachmentSources: basis.attachmentSources,
            evidenceCut: cut,
            freshnessAuthority: basis.freshnessAuthority,
            snapshot: snapshot
        )
    }

    func basisAtRevisionOneWithMaxRoundsOne(
        _ basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionProductionRoundBasis {
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: UUID(uuidString: "00000000-0000-0000-0000-000000009401")!,
            jobID: basis.job.jobID,
            revision: 1,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            corpusManifestSHA256: basis.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: basis.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: basis.checkpoint.pendingTaskIDs,
            runningTaskIDs: basis.checkpoint.runningTaskIDs,
            completedTaskIDs: basis.checkpoint.completedTaskIDs,
            failedTaskIDs: basis.checkpoint.failedTaskIDs,
            blockedTaskIDs: basis.checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: basis.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: basis.checkpoint.modelReceiptIDs,
            toolReceiptIDs: basis.checkpoint.toolReceiptIDs,
            coordinatorState: basis.checkpoint.coordinatorState,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: basis.job.jobID,
            reconstructionProjectID: basis.job.reconstructionProjectID,
            objective: basis.job.objective,
            objectiveSHA256: basis.job.objectiveSHA256,
            creationCorpusManifestSHA256: basis.job.creationCorpusManifestSHA256,
            state: basis.job.state,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: basis.job.terminalReason,
            budget: try ReconstructionJobBudget(
                maxRounds: 1,
                maxTasks: basis.job.budget.maxTasks,
                maxEvidenceRecords: basis.job.budget.maxEvidenceRecords,
                maxEncodedBytes: basis.job.budget.maxEncodedBytes
            ),
            creationOrdinal: try XCTUnwrap(basis.job.creationOrdinal),
            pauseContext: basis.job.pauseContext
        )
        let snapshot = ReconstructionJobOrchestrationSnapshot(
            jobID: basis.snapshot.jobID,
            jobCreationOrder: basis.snapshot.jobCreationOrder,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            checkpointCorpusManifestSHA256: checkpoint.corpusManifestSHA256,
            checkpointEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            currentCorpusManifestSHA256: basis.snapshot.currentCorpusManifestSHA256,
            evidenceFrontierSHA256: basis.snapshot.evidenceFrontierSHA256,
            currentDurableJobState: basis.snapshot.currentDurableJobState,
            pauseContext: basis.snapshot.pauseContext,
            maximumRoundsWithoutEvidence: 1,
            tasks: basis.tasks,
            terminalReceiptStatesByTaskID: basis.snapshot.terminalReceiptStatesByTaskID,
            consecutiveModelRoundsWithoutEvidence: 0
        )
        return try ReconstructionProductionRoundBasis(
            workspaceID: basis.workspaceID,
            project: basis.project,
            manifest: basis.manifest,
            job: job,
            checkpoint: checkpoint,
            tasks: basis.tasks,
            toolReceipts: basis.toolReceipts,
            modelReceipts: basis.modelReceipts,
            attachmentSources: basis.attachmentSources,
            evidenceCut: basis.evidenceCut,
            freshnessAuthority: basis.freshnessAuthority,
            snapshot: snapshot
        )
    }

    func toolProducer(
        operation: MacScopeAnalysisCore.ReconstructionOperationID
    ) throws -> ReconstructionProducerIdentity {
        let provisional = try ReconstructionProducerIdentity(
            macScopeBuildIdentity: digest("a"),
            macScopeSourceIdentity: digest("b"),
            operationIdentity: operation.rawValue,
            registryIdentity: Phase2ReconstructionProtocolArtifacts.make()
                .toolRegistry.identity.sha256,
            protocolIdentity: Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest,
            toolchainIdentity: "17A123",
            canonicalSHA256: digest("0")
        )
        return try ReconstructionProducerIdentity(
            schemaVersion: provisional.schemaVersion,
            macScopeBuildIdentity: provisional.macScopeBuildIdentity,
            macScopeSourceIdentity: provisional.macScopeSourceIdentity,
            operationIdentity: provisional.operationIdentity,
            registryIdentity: provisional.registryIdentity,
            protocolIdentity: provisional.protocolIdentity,
            nativeProviderIdentity: provisional.nativeProviderIdentity,
            nativeCapabilityIdentities: provisional.nativeCapabilityIdentities,
            modelKey: provisional.modelKey,
            endpointOrigin: provisional.endpointOrigin,
            observedModelInventorySHA256: provisional.observedModelInventorySHA256,
            observedConfigurationSHA256: provisional.observedConfigurationSHA256,
            toolchainIdentity: provisional.toolchainIdentity,
            canonicalSHA256: try ReconstructionEvidenceIntegrity
                .canonicalProducerSHA256(provisional)
        )
    }

    func gap(
        id: UUID,
        subject: ReconstructionSubjectCoordinate,
        operationID: MacScopeAnalysisCore.ReconstructionOperationID
    ) throws -> ReconstructionEvidenceGap {
        let provisional = try ReconstructionEvidenceGap(
            gapID: id,
            subject: subject,
            operationID: operationID.rawValue,
            reason: .sanitizing("Missing exact governed reconstruction evidence."),
            canonicalSHA256: digest("0")
        )
        return try ReconstructionEvidenceGap(
            gapID: provisional.gapID,
            subject: provisional.subject,
            operationID: provisional.operationID,
            reason: provisional.reason,
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalGapSHA256(provisional)
        )
    }

    func task(
        id: UUID,
        jobID: UUID,
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?,
        dependencies: [UUID],
        state: ReconstructionTaskState,
        operationContractIdentity explicitOperationContractIdentity: String? = nil
    ) throws -> ReconstructionTaskRecord {
        let operationContractIdentity = explicitOperationContractIdentity ?? {
            switch kind {
            case .retrieveEvidence:
                ReconstructionOperationID.evidenceQuery.rawValue
            default:
                "reconstruction.\(kind.rawValue).v1"
            }
        }()
        return ReconstructionTaskRecord(
            identity: try ReconstructionTaskIdentity.make(
                taskID: id,
                jobID: jobID,
                kind: kind,
                subject: subject,
                dependencyTaskIDs: dependencies,
                operationContractIdentity: operationContractIdentity
            ),
            state: state,
            diagnostic: nil
        )
    }

    func assertThrows(
        _ expected: ReconstructionProductionReceiptPlanAuthorError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ReconstructionProductionReceiptPlanAuthorError,
                expected,
                file: file,
                line: line
            )
        }
    }

    func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}

/// One record a later round of the same job appends to the evidence frontier.
private struct AppendedEvidenceSpec {
    let evidenceID: UUID
    let operation: MacScopeAnalysisCore.ReconstructionOperationID
    let summary: String
    var removing: Set<UUID> = []
    var reclassifying: [UUID: ReconstructionEvidenceClassification] = [:]
}

private struct PassThroughReceiptAuthor: ReconstructionProductionReceiptPlanAuthoring {
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
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }

    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }

    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
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

@MainActor
private final class SuccessorRequestCapture: ReconstructionReadyInferenceCoordinating {
    private(set) var request: ReconstructionAIWorkerRequest?
    func run(request: ReconstructionInferenceRoundRequest) async -> ReconstructionReadyInferenceExecutionResult {
        self.request = .round(request)
        return .busy
    }
    func run(request: ReconstructionInferenceRoundRequest,
        objective: ReconstructionRequestObjective?) async -> ReconstructionReadyInferenceExecutionResult {
        self.request = objective.map { .roundR2(.init(protocolVersion: 9, objective: $0, request: request)) }
            ?? .round(request)
        return .busy
    }
    func synthesize(request: ReconstructionFinalSynthesisRequest) async
        -> ReconstructionReadyFinalSynthesisExecutionResult { .busy }
}

private struct SuccessorCaptureMaterializer: ReconstructionJobRoundMaterializing {
    let prepared: ReconstructionPreparedModelRound
    func prepare(snapshot: ReconstructionJobOrchestrationSnapshot) async throws
        -> ReconstructionRoundPreparation { .model(prepared) }
    func discardPreparedRound(snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound) async {}
    func makeCommitPlan(snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func makeFailedModelPlan(snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func makeFinalCommitPlan(snapshot: ReconstructionJobOrchestrationSnapshot,
        prepared: ReconstructionPreparedModelRound, lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func makeRecoveryPlan(snapshot: ReconstructionJobOrchestrationSnapshot,
        transitions: [ReconstructionTaskTransition]) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func makeControlPlan(snapshot: ReconstructionJobOrchestrationSnapshot,
        reason: ReconstructionJobPauseReason) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
}

private extension ReconstructionProductionReceiptPlanAuthorTests {
    static let nativeOnlyMarker = "NATIVE_ONLY_FACT_7f3a"
    static let nativeOnlyText = "int entry(void) { return NATIVE_ONLY_FACT_7f3a(); }"

    struct NativeTransientFixture {
        let basis: ReconstructionProductionRoundBasis
        let functions: [ReconstructionFunctionCoordinate]
        let nativeTasks: [ReconstructionTaskRecord]
    }

    /// A focused committed basis whose functions each have one completed native task; the first
    /// also has one accepted-current MacScope record.
    func makeNativeTransientBasis(functionCount: Int = 1,
        focused: Bool = true) async throws -> NativeTransientFixture {
        let base = try await makeModelFixture().basis
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID())
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: foundation.occurrence.occurrenceID,
            contentIdentity: foundation.occurrence.contentIdentity)
        let image = ReconstructionImageBinding(binaryID: ReconstructionStableImageAuthority.stableBinaryID(
            occurrenceID: artifact.occurrenceID, selectedSliceIndex: nil), imageSlot: .primary,
            selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil)
        let coordinate = try ReconstructionImageCoordinate(artifact: artifact, image: image,
            analysisFingerprintSHA256: digest("d"))
        let ingest = try XCTUnwrap(base.tasks.first { $0.identity.kind == .ingest })
        let load = try task(id: UUID(), jobID: foundation.job.jobID, kind: .loadBinary,
            subject: .artifact(artifact), dependencies: [ingest.identity.taskID], state: .completed)
        let index = try task(id: UUID(), jobID: foundation.job.jobID, kind: .indexImage,
            subject: .image(coordinate), dependencies: [load.identity.taskID], state: .completed)
        let enumeration = try task(id: UUID(), jobID: foundation.job.jobID, kind: .enumerateFunctions,
            subject: .image(coordinate), dependencies: [index.identity.taskID], state: .completed)
        // Keep only the corpus prefix; the regular model frontier is rebuilt below so its
        // retrieve task depends on every batch leaf, exactly as the production planner emits it.
        var tasks = base.tasks.filter {
            [.ingest, .classify, .discoverRelations].contains($0.identity.kind)
        } + [load, index, enumeration]
        var functions: [ReconstructionFunctionCoordinate] = []
        var nativeTasks: [ReconstructionTaskRecord] = []
        var macScopeTask: ReconstructionTaskRecord?
        for ordinal in 0..<functionCount {
            let start = UInt64(0x1000 + ordinal * 0x100)
            let function = try ReconstructionFunctionCoordinate(artifact: artifact, image: image,
                analysisFingerprintSHA256: digest("d"), startAddress: start,
                endAddressExclusive: start + 0x10, boundarySchemaVersion: 1,
                functionUUIDHint: nil, symbolHint: nil)
            let native = try task(id: UUID(), jobID: foundation.job.jobID, kind: .decompileNative,
                subject: .function(function), dependencies: [enumeration.identity.taskID],
                state: .completed)
            if ordinal == 0 {
                let source = try task(id: UUID(), jobID: foundation.job.jobID, kind: .decompileMacScope,
                    subject: .function(function), dependencies: [enumeration.identity.taskID],
                    state: .completed)
                tasks.append(source)
                macScopeTask = source
            }
            tasks.append(native)
            functions.append(function)
            nativeTasks.append(native)
        }
        let discover = try XCTUnwrap(tasks.first { $0.identity.kind == .discoverRelations })
        let leaves = [discover.identity.taskID] + tasks.filter {
            $0.identity.kind == .decompileNative || $0.identity.kind == .decompileMacScope
        }.map(\.identity.taskID)
        let retrieve = try task(id: UUID(), jobID: foundation.job.jobID, kind: .retrieveEvidence,
            subject: nil, dependencies: leaves, state: .running)
        let model = try task(id: UUID(), jobID: foundation.job.jobID, kind: .modelRound,
            subject: nil, dependencies: [retrieve.identity.taskID], state: .running)
        let checkpoint = try task(id: UUID(), jobID: foundation.job.jobID, kind: .checkpoint,
            subject: nil, dependencies: [model.identity.taskID], state: .pending)
        tasks += [retrieve, model, checkpoint]
        let firstFunction = try XCTUnwrap(functions.first)
        let focus: ReconstructionSubjectCoordinate? = focused ? .function(firstFunction) : nil
        let basis = try makeBasis(foundation: foundation, tasks: tasks, currentImages: [coordinate],
            maximumTasks: tasks.count + 4, focus: focus)
        let source = try XCTUnwrap(macScopeTask)
        return NativeTransientFixture(
            basis: try basisByAddingAcceptedCurrentEvidence(basis,
                sourceTaskID: source.identity.taskID, subject: .function(firstFunction),
                operation: .decompilerMacScope),
            functions: functions, nativeTasks: nativeTasks)
    }

    func nativeExecution(
        for function: ReconstructionFunctionCoordinate,
        pseudocode: String,
        analysisFingerprintSHA256: String? = nil,
        functionID explicitFunctionID: UUID? = nil
    ) throws -> NativeDecompilerValidatedExecution {
        let functionID = try XCTUnwrap(explicitFunctionID
            ?? ReconstructionReboundFunctionAuthority.expectedFunctionID(for: function))
        let requestSHA256 = try ReconstructionCanonicalJSON.sha256(of: [pseudocode,
            function.startAddress.description, analysisFingerprintSHA256 ?? ""])
        let success = NativeDecompilerWireSuccess(
            availability: .init(available: true, reasonCode: "available",
                runtimeIdentity: .init(backendID: "native-decompiler", engineVersion: "12.1.2",
                    engineRevision: String(repeating: "1", count: 40), wrapperVersion: "dcp05c-v3",
                    wrapperRevision: String(repeating: "2", count: 40),
                    packageManifestSHA256: String(repeating: "3", count: 64),
                    packageTreeSHA256: String(repeating: "4", count: 64),
                    languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                    targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                    contextProfileSHA256: String(repeating: "5", count: 64)),
                capabilities: .init(nativeDecompilerHeritage: true, completeRegisterSSA: false,
                    memorySSA: false, recoveredVariables: false, recoveredTypes: false,
                    structuredControlFlow: true, tokenizedPseudocode: false,
                    imageQualifiedSourceRanges: true)),
            // Deterministic request identity: identical inputs must project identically.
            result: .init(requestID: try XCTUnwrap(UUID(uuidString: {
                    let hex = Array(requestSHA256.prefix(32))
                    return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
                        .map { String(hex[$0]) }.joined(separator: "-")
                }())), requestSHA256: requestSHA256,
                image: .init(imageID: "image:fixture",
                    uuid: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
                    preferredLoadAddress: .init(0x1000)),
                function: .init(functionID: functionID.uuidString.lowercased(), name: "entry",
                    entryAddress: .init(function.startAddress),
                    endAddressExclusive: .init(function.endAddressExclusive)),
                addressSpaces: [], types: [], instructions: [], varnodes: [], operations: [],
                blocks: [], edges: [], ssaValues: [], ssaBindings: [], phis: [],
                memoryVersions: [], memoryPhis: [], memoryEffects: [], variables: [], calls: [],
                regions: [], tokens: [],
                pseudocodeDocument: .init(text: pseudocode, language: "c",
                    isComplete: true, isTruncated: false),
                warnings: []))
        return NativeDecompilerValidatedExecution(requestSHA256: requestSHA256,
            analysisInputFingerprintSHA256: analysisFingerprintSHA256 ?? function.analysisFingerprintSHA256,
            imageSlot: function.image.imageSlot, functionID: functionID, success: success,
            source: .validatedCache)
    }

    @discardableResult
    func publishNative(_ registry: ReconstructionTransientNativePublicationRegistry,
        basis: ReconstructionProductionRoundBasis, task: ReconstructionTaskRecord,
        execution: NativeDecompilerValidatedExecution,
        checkpointRevision: UInt64? = nil) async throws
        -> ReconstructionTransientNativePublication {
        try await registry.publish(workspaceID: basis.workspaceID, task: task,
            success: .init(taskID: task.identity.taskID, checkpointID: basis.checkpoint.checkpointID,
                checkpointRevision: checkpointRevision ?? basis.checkpoint.revision,
                corpusManifestSHA256: basis.manifest.canonicalSHA256, execution: execution))
    }

    func transientPreparedRound(_ basis: ReconstructionProductionRoundBasis,
        registry: ReconstructionTransientNativePublicationRegistry,
        budgetBytes: Int? = nil) async throws -> ReconstructionPreparedModelRound {
        try await ReconstructionProductionPreparedRoundBuilder(
            evidenceQueryProducer: toolProducer(operation: .evidenceQuery),
            nativePublications: registry, transientBudgetBytes: budgetBytes
        ).makePreparedRound(from: basis)
    }

    func subjectSHA256(_ function: ReconstructionFunctionCoordinate) throws -> String {
        try ReconstructionCanonicalJSON.sha256(of: ReconstructionSubjectCoordinate.function(function))
    }
}
