import Foundation
import XCTest
@testable import MacScope

final class PatternInterpretationValidationTests: XCTestCase {
    func testMembershipPositive() throws { try accept(reply()) }

    func testMembershipNegative() {
        var value = reply()
        value.nodes[0].id = 2
        reject(value)
    }

    func testParentsPositive() throws { try accept(tree()) }

    func testParentsNegative() {
        var value = tree()
        value.nodes[1].parentID = 2
        reject(value)
    }

    func testTotalsPositive() throws { try accept(tree()) }

    func testTotalsNegative() {
        var value = tree()
        value.nodes[0].childCount = 0
        reject(value)
    }

    func testArrayLimitPositive() throws {
        var value = tree()
        value.nodes[0].kind = .array
        var input = request()
        input.maximumArrayChildren = 1
        try accept(value, request: input)
    }

    func testArrayLimitNegative() {
        var value = tree()
        value.nodes[0].kind = .array
        value.nodes[0].childCount = 2
        var child = value.nodes[1]
        child.id = 3
        value.nodes.append(child)
        var input = request()
        input.maximumArrayChildren = 1
        reject(value, request: input)
    }

    func testStringsPositive() throws {
        var value = reply()
        value.nodes[0].name = String(repeating: "a", count: 128)
        try accept(value)
    }

    func testStringsNegative() {
        var value = reply()
        value.nodes[0].name = String(repeating: "a", count: 129)
        reject(value)
    }

    func testBitSpanPositive() throws { try accept(bitReply()) }

    func testBitSpanNegative() {
        var value = bitReply()
        value.nodes[0].ranges[0].length = 1
        reject(value)
    }

    func testOutOfRangeClassificationPositive() throws {
        var value = reply()
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        value.nodes[0].ranges = []
        value.nodes[0].patternOffset = 2
        try accept(value)
    }

    func testOutOfRangeClassificationNegative() {
        var value = reply()
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        value.nodes[0].ranges = []
        reject(value)
    }

    func testOutOfRangeRejectsContainedEmptyAndBitSpans() {
        var value = reply()
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        value.nodes[0].ranges = []
        value.nodes[0].patternOffset = 2
        value.nodes[0].declaredSize = 0
        reject(value)
        value = bitReply()
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        value.nodes[0].ranges = []
        reject(value)
        value = emptyBitReply(offset: 0)
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        reject(value)
    }

    func testOutOfRangeAcceptsInvalidBitLocationAndOverflowingDeclaredSpan() throws {
        var value = emptyBitReply(offset: 1)
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        try accept(value)
        value = reply()
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        value.nodes[0].ranges = []
        value.nodes[0].patternOffset = UInt64.max
        value.nodes[0].declaredSize = UInt64.max
        try accept(value)
        value = bitReply()
        value.status = .partial
        value.nodes[0].backing = .outOfRange
        value.nodes[0].ranges = []
        value.nodes[0].bits?.count = UInt64.max
        try accept(value)
    }

    func testUnsupportedClassificationPositive() throws {
        var value = reply()
        value.status = .partial
        value.nodes[0].kind = .unsupported
        value.nodes[0].backing = .unsupported
        value.nodes[0].ranges = []
        try accept(value)
    }

    func testUnsupportedClassificationNegative() {
        var value = reply()
        value.nodes[0].kind = .unsupported
        value.nodes[0].backing = .synthetic
        value.nodes[0].sectionID = 1
        value.nodes[0].ranges = []
        reject(value)
        value.status = .partial
        reject(value)
        value.nodes[0].sectionID = 0
        value.nodes[0].backing = .outOfRange
        value.nodes[0].patternOffset = 2
        reject(value)
    }

    func testSyntheticSupportedFieldRemainsNonNavigable() throws {
        var value = reply()
        value.nodes[0].backing = .synthetic
        value.nodes[0].sectionID = 1
        value.nodes[0].ranges = []
        try accept(value)
    }

    func testEmptyBitEndLocationPositive() throws { try accept(emptyBitReply(offset: 0)) }

    func testEmptyBitEndLocationNegative() { reject(emptyBitReply(offset: 1)) }

    @MainActor
    func testFreshCapturePositive() throws {
        let input = request()
        let live = PatternInterpretationLiveCapture(currentKey: input.key,
                                                   activeRequestID: input.requestID, isCurrent: true)
        let validated = try ValidatedPatternInterpretation.decode(
            JSONEncoder().encode(reply()), for: input, liveCapture: { live })
        XCTAssertEqual(try validated.imageByteRanges(for: 1, liveCapture: { live }), [16..<17])
        XCTAssertEqual(try validated.fields(overlapping: 0, liveCapture: { live }).map(\.id), [1])
    }

    @MainActor
    func testFreshCaptureNegative() throws {
        let input = request()
        let bytes = try JSONEncoder().encode(reply())
        var live = PatternInterpretationLiveCapture(currentKey: input.key,
                                                   activeRequestID: input.requestID, isCurrent: true)
        let validated = try ValidatedPatternInterpretation.decode(bytes, for: input, liveCapture: { live })
        // A changed live byte can invalidate capture without changing its retained key.
        live.isCurrent = false
        assertStale { _ = try ValidatedPatternInterpretation.decode(bytes, for: input, liveCapture: { live }) }
        assertStale { _ = try validated.imageByteRanges(for: 1, liveCapture: { live }) }
        assertStale { _ = try validated.fields(overlapping: 0, liveCapture: { live }) }
        // Clearing request authority before cancellation also rejects same-key replay.
        live.isCurrent = true
        live.activeRequestID = nil
        assertStale { _ = try ValidatedPatternInterpretation.decode(bytes, for: input, liveCapture: { live }) }
        assertStale { _ = try validated.imageByteRanges(for: 1, liveCapture: { live }) }
        assertStale { _ = try validated.fields(overlapping: 0, liveCapture: { live }) }
        live.activeRequestID = UUID()
        assertStale { _ = try ValidatedPatternInterpretation.decode(bytes, for: input, liveCapture: { live }) }
        live.activeRequestID = input.requestID
        live.currentKey.byteSnapshotID = UUID()
        assertStale { _ = try ValidatedPatternInterpretation.decode(bytes, for: input, liveCapture: { live }) }
    }

    @MainActor
    func testPublicationRechecksLiveCaptureAfterStructuralValidation() throws {
        let input = request()
        let bytes = try JSONEncoder().encode(reply())
        var calls = 0
        assertStale {
            _ = try ValidatedPatternInterpretation.decode(bytes, for: input) {
                calls += 1
                return .init(currentKey: input.key, activeRequestID: input.requestID, isCurrent: calls == 1)
            }
        }
        XCTAssertEqual(calls, 2)
    }

    private func request() -> PatternInterpretationRequest {
        .init(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
              key: .init(imageIdentity: "image",
                         byteSnapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                         patternIdentity: "pattern", selectionImageOffset: 16, selectionByteCount: 2),
              bytes: Data([0, 0]), source: "u8 x @ 0;")
    }

    private func reply() -> PatternInterpretationReply {
        let input = request()
        return .init(schemaVersion: 1, engineCommit: "300d7388475dd7ffd04239dfc889b72fe08bae18",
                     requestID: input.requestID.uuidString, imageIdentity: input.key.imageIdentity,
                     patternIdentity: input.key.patternIdentity, byteSnapshotID: input.key.byteSnapshotID,
                     selectionImageOffset: input.key.selectionImageOffset, selectionByteCount: 2,
                     status: .completed,
                     nodes: [.init(id: 1, parentID: nil, depth: 0, kind: .unsigned, name: "x", typeName: "u8",
                                   sectionID: 0, patternOffset: 0, declaredSize: 1, backing: .file,
                                   ranges: [.init(selectionOffset: 0, length: 1)], bits: nil, value: "0",
                                   flags: [], childCount: 0, childrenTruncated: false)], diagnostics: [])
    }

    private func tree() -> PatternInterpretationReply {
        var value = reply()
        var child = value.nodes[0]
        value.nodes[0].kind = .struct
        value.nodes[0].childCount = 1
        child.id = 2
        child.parentID = 1
        child.depth = 1
        value.nodes.append(child)
        return value
    }

    private func bitReply() -> PatternInterpretationReply {
        var value = reply()
        value.nodes[0].kind = .bitfieldField
        value.nodes[0].declaredSize = 2
        value.nodes[0].ranges[0].length = 2
        value.nodes[0].bits = .init(offsetWithinFirstByte: 7, count: 2, numbering: .lsb0)
        return value
    }

    private func emptyBitReply(offset: UInt64) -> PatternInterpretationReply {
        var value = bitReply()
        value.nodes[0].backing = .empty
        value.nodes[0].patternOffset = 2
        value.nodes[0].declaredSize = 0
        value.nodes[0].ranges = []
        value.nodes[0].bits = .init(offsetWithinFirstByte: offset, count: 0, numbering: .lsb0)
        return value
    }

    private func accept(_ reply: PatternInterpretationReply,
                        request input: PatternInterpretationRequest? = nil) throws {
        _ = try ValidatedPatternInterpretation.decodeForWorker(JSONEncoder().encode(reply), for: input ?? request())
    }

    private func reject(_ reply: PatternInterpretationReply,
                        request input: PatternInterpretationRequest? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try accept(reply, request: input), file: file, line: line) { error in
            guard case PatternInterpretationError.malformedReply = error else {
                return XCTFail("Expected malformedReply, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertStale(_ operation: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case PatternInterpretationError.staleReply = error else {
                return XCTFail("Expected staleReply, got \(error)", file: file, line: line)
            }
        }
    }
}
