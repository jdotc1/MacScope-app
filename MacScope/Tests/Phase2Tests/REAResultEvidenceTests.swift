import XCTest
@testable import MacScope

final class REAResultEvidenceTests: XCTestCase {
    private func fixture(requestBytes: Int = 0, responseBytes: Int = 70_000) throws -> REAResultEvidence {
        let requestID = UUID()
        let identity = String(repeating: "a", count: 64)
        let authority = REAResultAuthority(workspaceID: UUID(), imageSHA256: identity,
            snapshotID: UUID(), sourceGeneration: 4, resourceSHA256: String(repeating: "b", count: 64),
            implementationIdentity: identity)
        let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "requestID": requestID.uuidString, "operation": "nativeApplication", "input": ["captured": String(repeating: "x", count: requestBytes)]])
        let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "requestID": requestID.uuidString, "operation": "nativeApplication",
            "implementationIdentity": identity, "ok": true,
            "result": ["captured": String(repeating: "x", count: responseBytes)]])
        return try REAResultEvidence(requestID: requestID, operation: "nativeApplication",
            authority: authority, requestJSON: request, responseJSON: response)
    }

    func testAcceptedHistoryRoundTripsAndBoundedReadsReassembleExactResponse() throws {
        let evidence = try fixture()
        var store = try REAResultEvidenceStore()
        try store.publish(evidence, activeAuthority: evidence.authority)
        let reopened = try JSONDecoder().decode(REAResultEvidenceStore.self, from: JSONEncoder().encode(store))
        XCTAssertEqual(reopened, store)
        var bytes = Data()
        var offset = 0
        repeat {
            let page = try reopened.read(evidenceID: evidence.evidenceID,
                responseSHA256: evidence.responseSHA256, offset: offset, maximumBytes: 4096)
            XCTAssertLessThanOrEqual(page.bytes.count, 4096)
            XCTAssertEqual(page.totalBytes, evidence.responseJSON.count)
            bytes.append(page.bytes)
            guard let next = page.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while true
        XCTAssertEqual(bytes, evidence.responseJSON)
        XCTAssertEqual(REAResultEvidence.digest(bytes), evidence.responseSHA256)
    }

    func testSourceReplacementRetainsHistoryAndRejectsLatePublication() throws {
        let evidence = try fixture()
        var store = try REAResultEvidenceStore()
        try store.publish(evidence, activeAuthority: evidence.authority)
        let old = evidence.authority
        let changed = REAResultAuthority(workspaceID: old.workspaceID, imageSHA256: old.imageSHA256,
            snapshotID: UUID(), sourceGeneration: old.sourceGeneration + 1,
            resourceSHA256: old.resourceSHA256, implementationIdentity: old.implementationIdentity)
        XCTAssertFalse(store.isCurrent(evidence, activeAuthority: changed))
        let baseline = store
        XCTAssertThrowsError(try store.publish(evidence, activeAuthority: changed))
        XCTAssertEqual(store, baseline)
        XCTAssertEqual(store.records, [evidence])
    }

    func testForgedPersistedDigestUnknownOperationAndUnboundedReadRejected() throws {
        let evidence = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        object["responseSHA256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try JSONDecoder().decode(REAResultEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try REAResultEvidence(requestID: evidence.requestID, operation: "unknown",
            authority: evidence.authority, requestJSON: evidence.requestJSON, responseJSON: evidence.responseJSON))
        let store = try REAResultEvidenceStore(records: [evidence])
        XCTAssertThrowsError(try store.read(evidenceID: evidence.evidenceID,
            responseSHA256: evidence.responseSHA256, offset: 0, maximumBytes: 65_537))
        XCTAssertThrowsError(try store.read(evidenceID: evidence.evidenceID,
            responseSHA256: String(repeating: "0", count: 64), offset: 0, maximumBytes: 1))
    }

    func testPublicationEvictsOldestAtRecordCapacityAndSurvivingCitationsRemainExact() throws {
        let records = try (0..<REAResultEvidenceStore.maximumRecords).map { _ in try fixture(responseBytes: 1) }
        var store = try REAResultEvidenceStore(records: records)
        let newest = try fixture(responseBytes: 1)
        try store.publish(newest, activeAuthority: newest.authority)
        XCTAssertEqual(store.records, Array(records.dropFirst()) + [newest])
        XCTAssertThrowsError(try store.read(evidenceID: records[0].evidenceID,
            responseSHA256: records[0].responseSHA256, offset: 0, maximumBytes: 1)) { error in
                XCTAssertEqual(error as? REAResultEvidenceError, .unavailable)
        }
        let surviving = records[1]
        XCTAssertEqual(try store.read(evidenceID: surviving.evidenceID,
            responseSHA256: surviving.responseSHA256, offset: 0, maximumBytes: 65_536).bytes, surviving.responseJSON)
        XCTAssertEqual(try JSONDecoder().decode(REAResultEvidenceStore.self,
            from: JSONEncoder().encode(store)).records, store.records)
    }

    func testEncodedByteCapacityEvictsBeforeRecordCountLimit() throws {
        let first = try fixture(requestBytes: 5 * 1_024 * 1_024, responseBytes: 5 * 1_024 * 1_024)
        let second = try fixture(requestBytes: 5 * 1_024 * 1_024, responseBytes: 5 * 1_024 * 1_024)
        var store = try REAResultEvidenceStore(records: [first])
        try store.publish(second, activeAuthority: second.authority)
        XCTAssertEqual(store.records, [second])
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(store).count, REAResultEvidenceStore.maximumEncodedBytes)
    }

    func testOversizedSingleResultFailsAtomicallyAndLaterSmallResultStillPublishes() throws {
        let original = try fixture(responseBytes: 1)
        var store = try REAResultEvidenceStore(records: [original])
        let tooLarge = try fixture(requestBytes: 12 * 1_024 * 1_024, responseBytes: 7 * 1_024 * 1_024)
        XCTAssertFalse(try REAResultEvidenceStore.canRetainLargestResponse(requestJSON: tooLarge.requestJSON))
        XCTAssertThrowsError(try store.publish(tooLarge, activeAuthority: tooLarge.authority)) { error in
            XCTAssertEqual(error as? REAResultEvidenceError, .bounds)
        }
        XCTAssertEqual(store.records, [original])
        let later = try fixture(responseBytes: 1)
        XCTAssertTrue(try REAResultEvidenceStore.canRetainLargestResponse(requestJSON: later.requestJSON))
        try store.publish(later, activeAuthority: later.authority)
        XCTAssertEqual(store.records, [original, later])
    }
}
