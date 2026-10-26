import Foundation
import XCTest
@testable import MacScope

final class PayloadWireCodecLimitsTests: XCTestCase {
    func testRequestRawByteLimitIncludesBoundaryAndRejectsBeforeDecode() throws {
        let data = request()
        var limits = PayloadWireCodec.Limits.production
        limits.maximumRequestBytes = data.count
        XCTAssertEqual(try PayloadWireCodec(limits: limits).decodeRequest(data).overrides, [:])
        limits.maximumRequestBytes -= 1
        assertLimit("raw byte") { _ = try PayloadWireCodec(limits: limits).decodeRequest(data) }
        limits.maximumRequestBytes = 3
        assertLimit("raw byte") {
            _ = try PayloadWireCodec(limits: limits).decodeRequest(Data("null".utf8))
        }
    }

    func testReplyRawByteLimitIncludesBoundaryAndRejectsBeforeDecode() throws {
        let snapshot = fixture()
        let data = PayloadWireCodec().encodeReply(.success(snapshot))
        var limits = PayloadWireCodec.Limits.production
        limits.maximumReplyBytes = data.count
        XCTAssertEqual(try PayloadWireCodec(limits: limits).decodeReply(data).imageBytes, snapshot.imageBytes)
        limits.maximumReplyBytes -= 1
        assertLimit("raw byte") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
        limits.maximumReplyBytes = 3
        assertLimit("raw byte") {
            _ = try PayloadWireCodec(limits: limits).decodeReply(Data("null".utf8))
        }
    }

    func testWireRejectsAlternateTextEncodingsBeforeDecode() throws {
        let json = String(decoding: minimalRequest(), as: UTF8.self)
        let utf16 = try XCTUnwrap(json.data(using: .utf16LittleEndian))
        assertLimit("UTF-8 JSON") { _ = try PayloadWireCodec().decodeRequest(utf16) }
    }

    func testOverrideCountIsCheckedBeforeDictionaryProjection() throws {
        let overrides: [UInt64: AddressOverride] = [
            1: AddressOverride(customName: "first"),
            2: AddressOverride(customComment: "second"),
        ]
        let data = request(overrides: overrides)
        var limits = PayloadWireCodec.Limits.production
        limits.maximumOverrides = 2
        XCTAssertEqual(try PayloadWireCodec(limits: limits).decodeRequest(data).overrides, overrides)
        limits.maximumOverrides = 1
        assertLimit("override count") { _ = try PayloadWireCodec(limits: limits).decodeRequest(data) }
    }

    func testRequestAggregateValuesIncludeNestedOverrides() throws {
        // Root object, plus four keys and their four values, totals nine values.
        let empty = minimalRequest()
        var limits = PayloadWireCodec.Limits.production
        limits.maximumRequestValues = 9
        XCTAssertTrue(try PayloadWireCodec(limits: limits).decodeRequest(empty).overrides.isEmpty)
        let nested = request(overrides: [1: AddressOverride(registerNames: ["x0": "result"])])
        assertLimit("aggregate model value") {
            _ = try PayloadWireCodec(limits: limits).decodeRequest(nested)
        }
    }

    func testRequestStringBudgetsIncludeNestedOverrideStrings() throws {
        var limits = PayloadWireCodec.Limits.production
        // Keys, the six-byte path, and the UUID contain 71 encoded string bytes.
        limits.maximumRequestStringBytes = 71
        XCTAssertTrue(try PayloadWireCodec(limits: limits).decodeRequest(minimalRequest()).overrides.isEmpty)
        let nested = request(overrides: [1: AddressOverride(registerNames: ["x0": "result"])])
        assertLimit("string byte") { _ = try PayloadWireCodec(limits: limits).decodeRequest(nested) }

        limits = .production
        limits.maximumRequestSingleStringBytes = 36 // The UUID remains valid at its exact limit.
        XCTAssertTrue(try PayloadWireCodec(limits: limits).decodeRequest(minimalRequest()).overrides.isEmpty)
        let longer = request(overrides: [1: AddressOverride(customComment: String(repeating: "a", count: 37))])
        assertLimit("string byte") { _ = try PayloadWireCodec(limits: limits).decodeRequest(longer) }
    }

    func testReplyAggregateValuesAndNestingHaveInclusiveBoundaries() {
        // Three objects, three keys, and the version number: seven values at depth three.
        let data = PayloadWireCodec().encodeReply(.failure(AnalysisCancelled()))
        var limits = PayloadWireCodec.Limits.production
        limits.maximumReplyValues = 7
        limits.maximumNestingDepth = 3
        assertCancellation(data, limits: limits)
        limits.maximumReplyValues = 6
        assertLimit("aggregate model value") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
        limits.maximumReplyValues = 7
        limits.maximumNestingDepth = 2
        assertLimit("nesting depth") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
    }

    func testReplyStringBudgetHasInclusiveAggregateAndSingleStringBoundaries() {
        let data = PayloadWireCodec().encodeReply(.failure(AnalysisCancelled()))
        var limits = PayloadWireCodec.Limits.production
        // version + failure + cancelled = 7 + 7 + 9 bytes.
        limits.maximumReplyStringBytes = 23
        limits.maximumReplySingleStringBytes = 9
        assertCancellation(data, limits: limits)
        limits.maximumReplyStringBytes = 22
        assertLimit("string byte") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
        limits.maximumReplyStringBytes = 23
        limits.maximumReplySingleStringBytes = 8
        assertLimit("string byte") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
    }

    func testReplyModelBudgetRejectsNestedPayloadBeforeProjection() {
        let data = PayloadWireCodec().encodeReply(.success(fixture()))
        var limits = PayloadWireCodec.Limits.production
        limits.maximumReplyValues = 7
        assertLimit("aggregate model value") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
    }

    func testPinnedImageBudgetIsCheckedBeforeOpeningSource() {
        let snapshot = fixture()
        let range = AnalysisPinnedImageByteRange(offset: 0, byteCount: snapshot.imageBytes.count, sha256: "unused")
        let data = PayloadWireCodec().encodeReply(.success(snapshot), pinnedImageBytes: range)
        var limits = PayloadWireCodec.Limits.production
        limits.maximumPinnedImageBytes = snapshot.imageBytes.count - 1
        assertLimit("pinned image byte") { _ = try PayloadWireCodec(limits: limits).decodeReply(data) }
        limits.maximumPinnedImageBytes = snapshot.imageBytes.count
        XCTAssertThrowsError(try PayloadWireCodec(limits: limits).decodeReply(data)) {
            XCTAssertEqual($0 as? AnalysisPinnedImageBytesError, .pinnedSourceMissing)
        }
    }

    func testValidNestedRequestAndReplyPreserveContent() throws {
        let overrides: [UInt64: AddressOverride] = [
            0x1000: AddressOverride(customComment: "quotes \" and slash \\ and é", registerNames: ["x0": "result"]),
        ]
        let codec = PayloadWireCodec()
        XCTAssertEqual(try codec.decodeRequest(request(overrides: overrides)).overrides, overrides)
        let snapshot = fixture()
        let decoded = try codec.decodeReply(codec.encodeReply(.success(snapshot)))
        XCTAssertEqual(decoded.imageBytes, snapshot.imageBytes)
        XCTAssertEqual(decoded.hexBytes, snapshot.hexBytes)
        XCTAssertEqual(decoded.jumpTables, snapshot.jumpTables)
        XCTAssertEqual(decoded.objcSelectors, snapshot.objcSelectors)
    }

    private func minimalRequest() -> Data {
        Data(#"{"version":4,"path":"/tmp/a","overrides":[],"requestID":"00000000-0000-0000-0000-000000000001"}"#.utf8)
    }

    private func request(overrides: [UInt64: AddressOverride] = [:]) -> Data {
        PayloadWireCodec().encodeRequest(url: URL(fileURLWithPath: "/tmp/a"), requestedSliceIndex: nil,
                                         overrides: overrides, requestID: UUID())
    }

    private func fixture() -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [],
                                         hexBytes: Data([1, 2, 3]))
        snapshot.imageBytes = Data([1, 2, 3, 4])
        snapshot.jumpTables = [0x1000: [0x1004, 0x1008]]
        snapshot.objcSelectors = [0x2000: "a:\"b\\c"]
        return snapshot
    }

    private func assertCancellation(_ data: Data, limits: PayloadWireCodec.Limits,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PayloadWireCodec(limits: limits).decodeReply(data), file: file, line: line) {
            XCTAssertTrue($0 is AnalysisCancelled, "Unexpected error: \($0)", file: file, line: line)
        }
    }

    private func assertLimit(_ expected: String, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected a wire budget rejection, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(context.debugDescription.contains(expected), context.debugDescription, file: file, line: line)
        }
    }
}
