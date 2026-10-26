import Foundation
import XCTest
@testable import MacScope

/// Covers the two additions to the Find feature:
///   1. `SearchResultCursor` — Find-Next / Find-Previous stepping with wrap-around
///      over a stable, ordered result set, plus current-position tracking.
///   2. `BinarySearchService` hex search scanning ALL file-backed sections (via the
///      snapshot's section map + `imageBytes`), not just the decoded `__text`.
final class SearchStepAndSectionTests: XCTestCase {
    private let service = BinarySearchService()

    // MARK: - Helpers

    private func result(_ address: UInt64, _ kind: BinarySearchResult.Kind = .instruction, _ preview: String = "x") -> BinarySearchResult {
        BinarySearchResult(address: address, kind: kind, preview: preview)
    }

    private func instruction(_ address: UInt64, _ bytes: String, _ mnemonic: String = "x", _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func section(_ name: String, address: UInt64, size: UInt64, fileOffset: UInt64, isZeroFill: Bool = false) -> SectionSummary {
        SectionSummary(id: UUID(), name: name, address: address, size: size, fileOffset: fileOffset,
                       isExecutable: name == "__text", isZeroFill: isZeroFill)
    }

    private func snapshot(
        instructions: [InstructionRow] = [],
        sections: [SectionSummary] = [],
        imageBytes: Data = Data()
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [],
            functions: [],
            symbols: [],
            stringLiterals: [],
            instructions: instructions,
            xrefs: [],
            hexBytes: Data(),
            sections: sections,
            imageBytes: imageBytes
        )
    }

    // MARK: - Cursor: stepping + wrap

    func testNextStepsThroughResultsInOrder() {
        var cursor = SearchResultCursor(results: [result(0x10), result(0x20), result(0x30)])
        XCTAssertNil(cursor.current)            // unpositioned until first step
        XCTAssertEqual(cursor.next()?.address, 0x10)
        XCTAssertEqual(cursor.next()?.address, 0x20)
        XCTAssertEqual(cursor.next()?.address, 0x30)
        XCTAssertEqual(cursor.current?.address, 0x30)
    }

    func testNextWrapsFromLastToFirst() {
        var cursor = SearchResultCursor(results: [result(0x10), result(0x20)])
        cursor.next() // 0x10
        cursor.next() // 0x20
        XCTAssertEqual(cursor.next()?.address, 0x10) // wrap
    }

    func testPreviousStepsBackwardAndWrapsFromFirstToLast() {
        var cursor = SearchResultCursor(results: [result(0x10), result(0x20), result(0x30)])
        // From unpositioned, previous() selects the last.
        XCTAssertEqual(cursor.previous()?.address, 0x30)
        XCTAssertEqual(cursor.previous()?.address, 0x20)
        XCTAssertEqual(cursor.previous()?.address, 0x10)
        XCTAssertEqual(cursor.previous()?.address, 0x30) // wrap back to last
    }

    func testNextThenPreviousReturnsToPriorPosition() {
        var cursor = SearchResultCursor(results: [result(0x10), result(0x20), result(0x30)])
        cursor.next()      // 0x10
        cursor.next()      // 0x20
        cursor.previous()  // back to 0x10
        XCTAssertEqual(cursor.current?.address, 0x10)
    }

    func testEmptyCursorYieldsNothing() {
        var cursor = SearchResultCursor(results: [])
        XCTAssertTrue(cursor.isEmpty)
        XCTAssertNil(cursor.next())
        XCTAssertNil(cursor.previous())
        XCTAssertNil(cursor.current)
        XCTAssertNil(cursor.positionLabel)
    }

    func testSingleResultWrapsToItself() {
        var cursor = SearchResultCursor(results: [result(0x42)])
        XCTAssertEqual(cursor.next()?.address, 0x42)
        XCTAssertEqual(cursor.next()?.address, 0x42) // wrap onto itself
        XCTAssertEqual(cursor.previous()?.address, 0x42)
    }

    func testStartsPositionedOnSelectedAddress() {
        let cursor = SearchResultCursor(results: [result(0x10), result(0x20), result(0x30)], selecting: .primary(0x20))
        XCTAssertEqual(cursor.current?.address, 0x20)
        XCTAssertEqual(cursor.positionLabel, "2 of 3")
    }

    func testSelectingUnknownAddressLeavesCursorUnpositioned() {
        let cursor = SearchResultCursor(results: [result(0x10), result(0x20)], selecting: .primary(0x99))
        XCTAssertNil(cursor.current)
    }

    func testPositionLabelTracksStepping() {
        var cursor = SearchResultCursor(results: [result(0x10), result(0x20), result(0x30)])
        XCTAssertNil(cursor.positionLabel)
        cursor.next()
        XCTAssertEqual(cursor.positionLabel, "1 of 3")
        cursor.next()
        XCTAssertEqual(cursor.positionLabel, "2 of 3")
    }

    func testCursorPreservesServiceOrderingStably() {
        // The cursor must walk results in exactly the order handed to it (the service
        // already sorts by address); it must not re-order.
        let ordered = [result(0x30), result(0x10), result(0x20)]
        var cursor = SearchResultCursor(results: ordered)
        XCTAssertEqual(cursor.next()?.address, 0x30)
        XCTAssertEqual(cursor.next()?.address, 0x10)
        XCTAssertEqual(cursor.next()?.address, 0x20)
    }

    // MARK: - Hex search across all sections

    func testHexMatchFoundInNonTextDataSection() {
        // Two sections back-to-back in `imageBytes`:
        //   __text  @ VA 0x1000, file 0..4   -> bytes 90 90 90 90
        //   __const @ VA 0x4000, file 4..8   -> bytes de ad be ef
        let bytes = Data([0x90, 0x90, 0x90, 0x90, 0xde, 0xad, 0xbe, 0xef])
        let s = snapshot(
            instructions: [instruction(0x1000, "90 90 90 90")],
            sections: [
                section("__text", address: 0x1000, size: 4, fileOffset: 0),
                section("__const", address: 0x4000, size: 4, fileOffset: 4)
            ],
            imageBytes: bytes
        )
        // The decoded-__text path would NEVER find this — it lives only in __const.
        let hits = service.search(query: "de ad be ef", mode: .hex, in: s)
        XCTAssertEqual(hits.map(\.address), [0x4000])
        XCTAssertEqual(hits.first?.kind, .bytes)
    }

    func testHexMatchMappedToVirtualAddressWithinSection() {
        // Pattern in the middle of a data section maps to address + relative offset.
        let bytes = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        let s = snapshot(
            sections: [section("__data", address: 0x8000, size: 6, fileOffset: 0)],
            imageBytes: bytes
        )
        // "22 33" sits at section-relative offset 2 -> VA 0x8002.
        XCTAssertEqual(service.search(query: "2233", mode: .hex, in: s).map(\.address), [0x8002])
    }

    func testHexSearchAcrossMultipleSectionsSortedAndDeduped() {
        // The same byte pattern appears in two different sections; both are reported,
        // sorted by virtual address.
        let bytes = Data([0xAB, 0xCD, 0x00, 0xAB, 0xCD])
        let s = snapshot(
            sections: [
                section("__const", address: 0x5000, size: 2, fileOffset: 0),   // ab cd
                section("__data", address: 0x2000, size: 2, fileOffset: 3)     // ab cd
            ],
            imageBytes: bytes
        )
        XCTAssertEqual(service.search(query: "abcd", mode: .hex, in: s).map(\.address), [0x2000, 0x5000])
    }

    func testZeroFillSectionIsSkipped() {
        // A BSS section declares VA space but has no file bytes; it must not be scanned
        // (its fileOffset is a placeholder pointing at unrelated bytes).
        let bytes = Data([0xAA, 0xBB])
        let s = snapshot(
            sections: [
                section("__bss", address: 0x9000, size: 2, fileOffset: 0, isZeroFill: true),
                section("__data", address: 0x1000, size: 2, fileOffset: 0)
            ],
            imageBytes: bytes
        )
        // Only the real __data section (VA 0x1000) reports the match, not the BSS alias.
        XCTAssertEqual(service.search(query: "aabb", mode: .hex, in: s).map(\.address), [0x1000])
    }

    func testSectionScanIsNonOverlapping() {
        let bytes = Data([0xAA, 0xAA, 0xAA, 0xAA])
        let s = snapshot(
            sections: [section("__data", address: 0x3000, size: 4, fileOffset: 0)],
            imageBytes: bytes
        )
        XCTAssertEqual(service.search(query: "aaaa", mode: .hex, in: s).map(\.address), [0x3000, 0x3002])
    }

    func testSectionScanClampsToImageBytesTail() {
        // Section size overruns the captured `imageBytes`; the scan must clamp and not
        // crash or read past the end.
        let bytes = Data([0x01, 0x02])
        let s = snapshot(
            sections: [section("__data", address: 0x1000, size: 64, fileOffset: 0)],
            imageBytes: bytes
        )
        XCTAssertEqual(service.search(query: "0102", mode: .hex, in: s).map(\.address), [0x1000])
        XCTAssertTrue(service.search(query: "030405", mode: .hex, in: s).isEmpty)
    }

    func testFallsBackToInstructionStreamWhenNoSections() {
        // No sections/imageBytes (reloaded snapshot) -> the original decoded-stream
        // behavior, including cross-instruction-boundary matches.
        let s = snapshot(instructions: [
            instruction(0x1000, "05 00 00 94"),
            instruction(0x1004, "c0 03 5f d6")
        ])
        XCTAssertEqual(service.search(query: "05 00 00 94", mode: .hex, in: s).map(\.address), [0x1000])
        // 0x1003 (last byte of the first instr) + 0x1004 (first byte of the second).
        XCTAssertEqual(service.search(query: "94 c0", mode: .hex, in: s).map(\.address), [0x1003])
    }
}
