import Foundation
import XCTest
@testable import MacScope

final class REAResultReadProjectionTests: XCTestCase {
    private func fixture(value: String = String(repeating: "z", count: 40_000), workspaceID: UUID = UUID()) throws -> REAResultEvidence {
        let id = UUID(), hash = String(repeating: "a", count: 64)
        let authority = REAResultAuthority(workspaceID: workspaceID, imageSHA256: hash,
            snapshotID: UUID(), sourceGeneration: 1, resourceSHA256: hash, implementationIdentity: hash)
        let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "input": [:]])
        let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "implementationIdentity": hash, "ok": true,
            "result": ["value": value]])
        return try .init(requestID: id, operation: "nativeApplication", authority: authority,
                         requestJSON: request, responseJSON: response)
    }
    func testAppIssuedPagePlanRetainsHistoricalIdentityAndBoundedUnicodeOffsets() throws {
        let workspaceID = UUID()
        let historical = try fixture(value: String(repeating: "🙂é漢字", count: 20_000), workspaceID: workspaceID)
        let latest = try fixture(value: String(repeating: "n", count: 200_000), workspaceID: workspaceID)
        let store = try REAResultEvidenceStore(records: [historical, latest])
        let plan = try Phase2AssistantToolSelectionPlan(operations: [.workspaceSummary, .reaResultsList, .reaResultsGet],
            reaStore: store, reaWorkspaceID: workspaceID)
        XCTAssertEqual(plan.handles.count, Phase2InferenceLimits.assistantMaximum.maximumToolHandles)
        XCTAssertEqual(Set(plan.handles.map(\.handleID)).count, plan.handles.count)
        let historicalLater = try XCTUnwrap(plan.reaSelectors.values.first {
            $0.evidenceID == historical.evidenceID && $0.offset > 0
        })
        let page = try REAResultReadProjection.getText(store: store, workspaceID: workspaceID,
            activeAuthority: nil, evidenceID: historical.evidenceID,
            responseSHA256: try XCTUnwrap(historicalLater.responseSHA256), offset: historicalLater.offset,
            maximumBytes: 31_744)
        XCTAssertEqual(page.record.evidenceID, historical.evidenceID)
        XCTAssertEqual(Data(page.text.utf8), historical.responseJSON.subdata(in: page.offset..<(page.offset + page.text.utf8.count)))
        XCTAssertThrowsError(try REAResultReadProjection.getText(store: store, workspaceID: workspaceID,
            activeAuthority: nil, evidenceID: historical.evidenceID,
            responseSHA256: String(repeating: "0", count: 64), offset: historicalLater.offset, maximumBytes: 31_744))
        XCTAssertTrue(plan.reaPageCoverage.contains("complete records covered: 0/2"))
        XCTAssertTrue(plan.reaPageCoverage.contains("Unoffered pages are unavailable"))
        let tool = try XCTUnwrap(plan.projectedTools.first { $0.operationID == "rea.results.get" })
        XCTAssertEqual(Set(tool.acceptedHandleIDs), Set(plan.reaSelectors.keys))
    }

    func testRegisteredModelReadProjectsAcceptedEvidenceAndBindsExactPageSelector() throws {
        let record = try fixture(), store = try REAResultEvidenceStore(records: [record])
        let workspace = Phase2ReadWorkspaceIdentity(document: .init(instanceID: UUID()), instanceID: UUID())
        let precondition = Phase2ReadPrecondition(workspace: workspace, workspaceRevision: 1,
            strictWholeWorkspace: true, image: nil, dependencies: [])
        let current = Phase2ReadCurrentState(workspace: workspace, workspaceRevision: 1, image: nil, facetRevisions: [])
        let descriptor = try XCTUnwrap(TypedReadRegistry().descriptor(for: .reaResultsGet))
        let request = Phase2ReadRequest(requestID: UUID(), invocationID: UUID(), sequence: 1,
            proposingPrincipal: .model, descriptor: descriptor, subject: .workspace(workspace),
            precondition: precondition, limits: .maximum,
            reaResultRead: .init(evidenceID: record.evidenceID, responseSHA256: record.responseSHA256))
        guard case let .authorized(authorization) = TypedReadRegistry().authorize(request, authorizingPrincipal: .app) else {
            return XCTFail("REA exact page request must be app-authorizable")
        }
        let input = Phase2ReadProjectionInput(workspaceName: "REA", snapshot: .init(binaries: [], analysisBySlot: [:]),
            currentState: current, focusedImageSlot: nil, reaResultStore: store,
            reaWorkspaceID: record.authority.workspaceID, reaActiveAuthority: record.authority)
        let candidate = Phase2ReadProjector.project(authorization: authorization, input: input)
        guard case let .value(.object(fields)) = candidate.data,
              case let .text(text)? = fields.first(where: { $0.name == "acceptedREAResult" })?.value else {
            return XCTFail("REA model read must project accepted evidence")
        }
        let page = try JSONDecoder().decode(REAResultReadProjection.TextPage.self, from: Data(text.utf8))
        XCTAssertEqual(page.record.responseSHA256, record.responseSHA256)
        XCTAssertEqual(page.record.freshness, .current)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(Data(page.text.utf8), record.responseJSON.prefix(page.text.utf8.count))
        let missingSelector = Phase2ReadRequest(requestID: UUID(), invocationID: UUID(), sequence: 1,
            proposingPrincipal: .model, descriptor: descriptor, subject: .workspace(workspace),
            precondition: precondition, limits: .maximum)
        XCTAssertFalse(missingSelector.isValid)
        XCTAssertEqual(TypedReadRegistry().authorize(missingSelector, authorizingPrincipal: .app), .rejected(.unauthorized))
    }

    func testTextPagesKeepUnicodeScalarsAndCaptureSnapshotDoesNotMakeSourceStale() throws {
        let record = try fixture(value: "a🙂é漢字z"), store = try REAResultEvidenceStore(records: [record])
        let old = record.authority
        let recaptured = REAResultAuthority(workspaceID: old.workspaceID, imageSHA256: old.imageSHA256,
            snapshotID: UUID(), sourceGeneration: old.sourceGeneration,
            resourceSHA256: old.resourceSHA256, implementationIdentity: old.implementationIdentity)
        let emoji = try XCTUnwrap(record.responseJSON.range(of: Data("🙂".utf8))).lowerBound
        let first = try REAResultReadProjection.getText(store: store, workspaceID: old.workspaceID,
            activeAuthority: recaptured, evidenceID: record.evidenceID, responseSHA256: record.responseSHA256,
            offset: emoji - 1, maximumBytes: 3)
        XCTAssertEqual(first.text, "a")
        XCTAssertEqual(first.nextOffset, emoji)
        XCTAssertEqual(first.record.freshness, .current)
        XCTAssertEqual(first.record.snapshotID, old.snapshotID)
        let next = try REAResultReadProjection.getText(store: store, workspaceID: old.workspaceID,
            activeAuthority: recaptured, evidenceID: record.evidenceID, responseSHA256: record.responseSHA256,
            offset: emoji, maximumBytes: 4)
        XCTAssertEqual(next.text, "🙂")
        XCTAssertEqual(next.nextOffset, emoji + 4)
        XCTAssertThrowsError(try REAResultReadProjection.getText(store: store, workspaceID: old.workspaceID,
            activeAuthority: recaptured, evidenceID: record.evidenceID, responseSHA256: record.responseSHA256,
            offset: emoji + 1, maximumBytes: 4))
    }

    func testProjectionDistinguishesCurrentStaleAndUnknownWithoutDiscardingHistory() throws {
        let record = try fixture(), store = try REAResultEvidenceStore(records: [record])
        let old = record.authority
        let changed = REAResultAuthority(workspaceID: old.workspaceID, imageSHA256: old.imageSHA256,
            snapshotID: UUID(), sourceGeneration: 2, resourceSHA256: old.resourceSHA256,
            implementationIdentity: old.implementationIdentity)
        for (authority, expected) in [(Optional(old), REAResultReadProjection.Freshness.current),
                                       (Optional(changed), .stale), (nil, .unknown)] {
            let result = try REAResultReadProjection.list(store: store, workspaceID: old.workspaceID, activeAuthority: authority)
            XCTAssertEqual(result.records.count, 1)
            XCTAssertEqual(result.records.first?.freshness, expected)
            XCTAssertEqual(result.records.first?.responseSHA256, record.responseSHA256)
        }
    }
    func testDigestBoundPagesReassembleResponseAndStayBoundedWhenEncoded() throws {
        let record = try fixture(), store = try REAResultEvidenceStore(records: [record])
        var offset = 0, bytes = Data()
        repeat {
            let page = try REAResultReadProjection.get(store: store, workspaceID: record.authority.workspaceID,
                activeAuthority: nil, evidenceID: record.evidenceID, responseSHA256: record.responseSHA256,
                offset: offset, maximumBytes: REAResultReadProjection.maximumPageBytes)
            XCTAssertLessThan(try JSONEncoder().encode(page).count, 65_536)
            XCTAssertEqual(page.record.freshness, .unknown)
            bytes.append(page.bytes)
            guard let next = page.nextOffset else { break }
            offset = next
        } while true
        XCTAssertEqual(bytes, record.responseJSON)
        XCTAssertThrowsError(try REAResultReadProjection.get(store: store, workspaceID: record.authority.workspaceID,
            activeAuthority: nil, evidenceID: record.evidenceID, responseSHA256: String(repeating: "0", count: 64), offset: 0, maximumBytes: 1))
        XCTAssertThrowsError(try REAResultReadProjection.get(store: store, workspaceID: UUID(),
            activeAuthority: nil, evidenceID: record.evidenceID, responseSHA256: record.responseSHA256, offset: 0, maximumBytes: 1))
        XCTAssertThrowsError(try REAResultReadProjection.list(store: store, workspaceID: record.authority.workspaceID,
            activeAuthority: nil, maximumRecords: 33))
    }
}
