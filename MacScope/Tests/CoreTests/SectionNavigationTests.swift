import Foundation
import XCTest
@testable import MacScope

/// Coverage for the pure navigation / procedure / section-scan helpers behind the
/// Next-Code/Data/Unexplored, Select/Truncate Procedure, and Transform-Section-to-
/// Strings commands.
final class SectionNavigationTests: XCTestCase {

    // MARK: - AddressNavigation

    func testNextCodeSkipsDataMarkedAddresses() {
        let instrs: [UInt64] = [0x1000, 0x1004, 0x1008]
        let data: Set<UInt64> = [0x1004]
        XCTAssertEqual(AddressNavigation.nextCode(after: nil, instructionAddresses: instrs, dataAddresses: data), 0x1000)
        // 0x1004 is data-marked, so the next CODE after 0x1000 is 0x1008.
        XCTAssertEqual(AddressNavigation.nextCode(after: 0x1000, instructionAddresses: instrs, dataAddresses: data), 0x1008)
        XCTAssertNil(AddressNavigation.nextCode(after: 0x1008, instructionAddresses: instrs, dataAddresses: data))
    }

    func testNextDataFindsLowestStrictlyGreater() {
        let data: Set<UInt64> = [0x2000, 0x2008]
        XCTAssertEqual(AddressNavigation.nextData(after: nil, dataAddresses: data), 0x2000)
        XCTAssertEqual(AddressNavigation.nextData(after: 0x2000, dataAddresses: data), 0x2008)
        XCTAssertNil(AddressNavigation.nextData(after: 0x2008, dataAddresses: data))
    }

    func testNextUnexploredReturnsFirstGapAfterInstructionExtent() {
        // A 4-byte instruction at 0x1000 covers [0x1000, 0x1004); 0x1004 is the first gap.
        let extents: [(address: UInt64, width: UInt64)] = [(0x1000, 4)]
        XCTAssertEqual(
            AddressNavigation.nextUnexplored(
                after: 0x1000, instructionExtents: extents, dataAddresses: [],
                coverageSpans: [(start: 0x1000, end: 0x1010)]
            ),
            0x1004
        )
        // No loaded coverage -> nil.
        XCTAssertNil(AddressNavigation.nextUnexplored(
            after: 0x1000, instructionExtents: extents, dataAddresses: [], coverageSpans: []
        ))
    }

    // MARK: - ProcedureRange

    private func fn(_ start: UInt64, _ end: UInt64) -> FunctionSummary {
        FunctionSummary(id: UUID(), name: "f", startAddress: start, endAddress: end, confidence: 1.0)
    }

    func testEnclosingFunctionAndSelectRange() {
        let fns = [fn(0x1000, 0x1010)]
        XCTAssertEqual(ProcedureRange.enclosingFunction(for: 0x1008, functions: fns)?.startAddress, 0x1000)
        XCTAssertEqual(ProcedureRange.selectRange(for: 0x1008, functions: fns),
                       ProcedureRange.Range(start: 0x1000, end: 0x1010))
    }

    func testTruncatedBoundsValidatesRange() {
        let fns = [fn(0x1000, 0x1010)]
        XCTAssertEqual(ProcedureRange.truncatedBounds(at: 0x1008, functions: fns),
                       ProcedureRange.Range(start: 0x1000, end: 0x1008))
        XCTAssertNil(ProcedureRange.truncatedBounds(at: 0x1000, functions: fns), "at the start is degenerate")
        XCTAssertNil(ProcedureRange.truncatedBounds(at: 0x1010, functions: fns), "at the end has nothing to truncate")
    }

    // MARK: - SectionStringScanner

    func testSectionStringScannerFindsNulTerminatedRuns() {
        let bytes = Data([0x48, 0x69, 0x00, 0x59, 0x6f, 0x00]) // "Hi\0Yo\0"
        let spans = SectionStringScanner.scan(bytes: bytes, baseAddress: 0x4000, minimumLength: 2)
        XCTAssertEqual(spans.map(\.value), ["Hi", "Yo"])
        XCTAssertEqual(spans.first?.address, 0x4000)
        XCTAssertEqual(spans.last?.address, 0x4003)
    }

    // MARK: - nextStart / previousStart (Next/Previous Procedure + Section)

    func testNextStartReturnsLowestStrictlyGreater() {
        let starts: [UInt64] = [0x3000, 0x1000, 0x2000] // unsorted on purpose
        XCTAssertEqual(AddressNavigation.nextStart(after: 0x1000, in: starts), 0x2000)
        XCTAssertEqual(AddressNavigation.nextStart(after: 0x2000, in: starts), 0x3000)
        XCTAssertNil(AddressNavigation.nextStart(after: 0x3000, in: starts))        // no later start
        XCTAssertEqual(AddressNavigation.nextStart(after: nil, in: starts), 0x1000) // nil -> first
    }

    func testPreviousStartReturnsHighestStrictlyLess() {
        let starts: [UInt64] = [0x3000, 0x1000, 0x2000]
        XCTAssertEqual(AddressNavigation.previousStart(before: 0x3000, in: starts), 0x2000)
        XCTAssertEqual(AddressNavigation.previousStart(before: 0x2000, in: starts), 0x1000)
        XCTAssertNil(AddressNavigation.previousStart(before: 0x1000, in: starts))        // no earlier start
        XCTAssertEqual(AddressNavigation.previousStart(before: nil, in: starts), 0x3000) // nil -> last
    }

    // MARK: - XRefStepCursor (Next/Previous XREF)

    func testXRefCursorCyclesReferrersWithWrap() {
        var cursor = XRefStepCursor(anchor: 0x3000, froms: [0x2100, 0x1100, 0x1100]) // unsorted + dup
        XCTAssertEqual(cursor.froms, [0x1100, 0x2100]) // sorted + de-duplicated
        XCTAssertEqual(cursor.next(), 0x1100)
        XCTAssertEqual(cursor.next(), 0x2100)
        XCTAssertEqual(cursor.next(), 0x1100) // wraps
        XCTAssertEqual(cursor.previous(), 0x2100) // wraps back
        XCTAssertTrue(cursor.covers(0x3000)) // the anchor
        XCTAssertTrue(cursor.covers(0x1100)) // a referrer
        XCTAssertFalse(cursor.covers(0x9999))
    }

    func testEmptyXRefCursorHasNoCurrent() {
        var cursor = XRefStepCursor(anchor: 0x3000, froms: [])
        XCTAssertTrue(cursor.isEmpty)
        XCTAssertNil(cursor.next())
        XCTAssertNil(cursor.current)
    }
}
