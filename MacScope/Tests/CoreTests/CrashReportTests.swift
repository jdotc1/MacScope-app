import Foundation
import XCTest
@testable import MacScope

final class CrashReportTests: XCTestCase {
    private let uuid = "12345678-1234-1234-1234-123456789ABC"

    private func payload(offset: String = "32", imageIndex: String = "0", base: String = "4294967296", size: String = "4096") -> String {
        """
        {"procName":"Fixture", "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
         "faultingThread":0,
         "threads":[{"queue":"main","frames":[{"imageIndex":\(imageIndex),"imageOffset":\(offset),"symbol":"reported_name"}]}],
         "usedImages":[{"name":"Fixture","uuid":"\(uuid)","base":\(base),"size":\(size)}]}
        """
    }

    private func parse(_ source: String) throws -> CrashReport { try CrashReport.parse(Data(source.utf8)) }

    private func context(uuid: String? = nil, base: UInt64 = 0x1000,
                         ranges: [Range<UInt64>] = [0x1000..<0x2000],
                         symbols: [CrashReportSymbol] = []) -> CrashReportImageContext {
        CrashReportImageContext(uuid: uuid ?? self.uuid, preferredBase: base,
            mappedRanges: ranges, symbols: symbols)
    }

    func testSingleObjectAndAppleMetadataEnvelopePreserveSourceIdentity() throws {
        for text in [payload(), "{\"app_name\":\"Metadata name\",\"bug_type\":\"309\"}\n" + payload()] {
            let report = try parse(text)
            XCTAssertEqual(report.processName, "Fixture")
            XCTAssertEqual(report.exceptionSummary, "EXC_BAD_ACCESS · SIGSEGV")
            XCTAssertEqual(report.threads[0].id, 0)
            XCTAssertEqual(report.threads[0].name, "main")
            XCTAssertTrue(report.threads[0].triggered)
            XCTAssertEqual(report.threads[0].frames[0].id, 0)
            XCTAssertEqual(report.threads[0].frames[0].reportedSymbol, "reported_name")
            XCTAssertEqual(report.images[0].base, 0x1_0000_0000)
        }
    }

    func testMalformedNumericTypesAndRangesAreRejected() {
        let cases = [payload(offset: "-1"), payload(offset: "1.5"), payload(offset: "true"),
                     payload(offset: "\"32\""), payload(offset: "18446744073709551616"),
                     payload(imageIndex: "-1"), payload(imageIndex: "false"),
                     payload(base: "18446744073709551615", size: "1"),
                     "[]", "{}", "{}\n{}", payload() + "{}"]
        for text in cases { XCTAssertThrowsError(try parse(text), text) }
    }

    func testInputAndCollectionLimitsAreEnforced() throws {
        XCTAssertThrowsError(try CrashReport.parse(Data(repeating: 32, count: 16 * 1_024 * 1_024 + 1)))
        let threads = Array(repeating: "{\"frames\":[]}", count: 1_025).joined(separator: ",")
        XCTAssertThrowsError(try parse("{\"threads\":[\(threads)],\"usedImages\":[]}"))
        let frames = Array(repeating: "{}", count: 100_001).joined(separator: ",")
        XCTAssertThrowsError(try parse("{\"threads\":[{\"frames\":[\(frames)]}],\"usedImages\":[]}"))
        let images = Array(repeating: "{\"base\":0,\"size\":1}", count: 20_001).joined(separator: ",")
        XCTAssertThrowsError(try parse("{\"threads\":[],\"usedImages\":[\(images)]}"))
    }

    func testASLRRebaseRequiresUUIDAndMappedAddress() throws {
        let report = try parse(payload())
        let frame = report.threads[0].frames[0]
        let resolved = report.resolve(frame, against: context(uuid: uuid.lowercased().replacingOccurrences(of: "-", with: "")))
        XCTAssertEqual(resolved.address, 0x1020)
        XCTAssertNil(resolved.symbol)
        XCTAssertNil(report.resolve(frame, against: context(uuid: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")).address)
        XCTAssertNil(report.resolve(frame, against: context(uuid: "not-a-uuid")).address)
        XCTAssertNil(report.resolve(frame, against: context(ranges: [0x1100..<0x1200])).address)
        XCTAssertNil(report.resolve(frame, against: nil).address)
        XCTAssertEqual(frame.reportedSymbol, "reported_name")
    }

    func testMissingOrOutOfBoundsImagesRemainReadableButNotNavigable() throws {
        let report = try parse(payload())
        let indices: [Int?] = [nil, -1, 1, Int.max]
        for index in indices {
            let frame = CrashReportFrame(id: 7, imageIndex: index, imageOffset: 32, reportedSymbol: "retained")
            let result = report.resolve(frame, against: context())
            XCTAssertNil(result.address)
            XCTAssertNotNil(result.diagnostic)
            XCTAssertEqual(frame.reportedSymbol, "retained")
        }
        let missingOffset = CrashReportFrame(id: 0, imageIndex: 0, imageOffset: nil, reportedSymbol: nil)
        XCTAssertNil(report.resolve(missingOffset, against: context()).address)
        let missing = try parse("{\"threads\":[{\"frames\":[{}]}],\"usedImages\":[]}")
        XCTAssertNil(missing.resolve(missing.threads[0].frames[0], against: context()).address)
    }

    func testRebaseOverflowAndReportedImageBoundsRefuseNavigation() throws {
        let report = try parse(payload())
        XCTAssertNil(report.resolve(report.threads[0].frames[0],
            against: context(base: UInt64.max - 16, ranges: [0..<UInt64.max])).address)
        let end = try parse(payload(offset: "4096"))
        XCTAssertNil(end.resolve(end.threads[0].frames[0], against: context()).address)
    }

    func testOnlyExactSymbolsOrContainingBoundedFunctionsResolve() throws {
        let report = try parse(payload())
        let frame = report.threads[0].frames[0]
        let preceding = CrashReportSymbol(name: "unbounded", address: 0x1000, endAddress: nil)
        XCTAssertNil(report.resolve(frame, against: context(symbols: [preceding])).symbol)
        let bounded = CrashReportSymbol(name: "function", address: 0x1010, endAddress: 0x1030)
        XCTAssertEqual(report.resolve(frame, against: context(symbols: [preceding, bounded])).symbol, "function")
        let exact = CrashReportSymbol(name: "exact", address: 0x1020, endAddress: nil)
        XCTAssertEqual(report.resolve(frame, against: context(symbols: [bounded, exact])).symbol, "exact")
        let ended = CrashReportSymbol(name: "ended", address: 0x1000, endAddress: 0x1020)
        XCTAssertNil(report.resolve(frame, against: context(symbols: [ended])).symbol)
    }
}
