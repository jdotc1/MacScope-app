import Foundation
import XCTest
@testable import MacScope

final class BinarySearchServiceTests: XCTestCase {
    func testHexSearchUsesEffectiveBytesBeforeAndAfterDerivedPayloadRemoval() {
        var fresh = sectionSnapshot(sections: [section(".text", address: 0x1000, size: 4, fileOffset: 0)],
                                    imageBytes: Data([0x11, 0x22, 0x33, 0x44]))
        fresh.instructions = [instruction(0x1000, "11 22 33 44", "test", "")]
        var override = AddressOverride()
        override.patch = BytePatch(bytes: [0xaa, 0xbb])
        fresh.addressOverrides[ImageAddress(slot: .primary, address: 0x1001)] = override
        var reloaded = fresh
        reloaded.imageBytes = Data()
        reloaded.sections = []
        let before = service.search(query: "aa bb", mode: .hex, in: fresh)
        let after = service.search(query: "aa bb", mode: .hex, in: reloaded)
        XCTAssertEqual(before.map(\.address), [0x1001])
        XCTAssertEqual(after, before)
        XCTAssertTrue(service.search(query: "22 33", mode: .hex, in: fresh).isEmpty)
        XCTAssertTrue(service.search(query: "22 33", mode: .hex, in: reloaded).isEmpty)
    }

    func testReloadHexSearchDoesNotMatchAcrossAddressGap() {
        let input = snapshot(instructions: [instruction(0x1000, "aa", "test", ""),
                                            instruction(0x2000, "bb", "test", "")])
        XCTAssertTrue(service.search(query: "aa bb", mode: .hex, in: input).isEmpty)
    }

    func testHexSearchRetainsImageQualifiedPatchInProjection() {
        let slot = ImageSlot(rawValue: 2)
        let binary = BinaryImage(id: UUID(), name: "fixture", path: "/fixture", kind: "Mach-O",
                                 architecture: "arm64", slot: slot)
        var input = sectionSnapshot(sections: [section(".text", address: 0x1000, size: 4, fileOffset: 0)],
                                    imageBytes: Data([0x11, 0x22, 0x33, 0x44]))
        input.binaries = [binary]
        let analysis = input.analysisBySlot[.primary]
        input.analysisBySlot = [:]
        input.analysisBySlot[slot] = analysis
        var override = AddressOverride()
        override.patch = BytePatch(bytes: [0xaa, 0xbb])
        input.addressOverrides[ImageAddress(slot: slot, address: 0x1001)] = override
        let hits = service.search(query: "aa bb", mode: .hex, in: input)
        XCTAssertEqual(hits.map(\.address), [0x1001])
        XCTAssertEqual(hits.map(\.imageSlot), [slot])
    }
    private let service = BinarySearchService()

    private func snapshot(
        instructions: [InstructionRow] = [],
        strings: [StringLiteralSummary] = [],
        symbols: [SymbolSummary] = [],
        functions: [FunctionSummary] = []
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [],
            functions: functions,
            symbols: symbols,
            stringLiterals: strings,
            instructions: instructions,
            xrefs: [],
            hexBytes: Data()
        )
    }

    private func instruction(_ address: UInt64, _ bytes: String, _ mnemonic: String, _ operands: String, comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func sample() -> WorkspaceSnapshot {
        snapshot(
            instructions: [
                instruction(0x1000, "e0 03 01 aa", "mov", "x0, x1"),
                instruction(0x1004, "05 00 00 94", "bl", "_helper", comment: "call helper"),
                instruction(0x1008, "c0 03 5f d6", "ret", "")
            ],
            strings: [StringLiteralSummary(id: UUID(), value: "Hello, world", address: 0x2000, sourceSection: "__cstring", byteLength: 13)],
            symbols: [SymbolSummary(id: UUID(), name: "_helper", address: 0x1004, kind: "function", libraryName: nil)],
            functions: [
                FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x100c, confidence: 0.9),
                FunctionSummary(id: UUID(), name: "sub_100c", startAddress: 0x100c, endAddress: 0x1010, confidence: 0.5)
            ]
        )
    }

    // MARK: - Text

    func testTextSearchAcrossListingStringsAndSymbols() {
        let s = sample()
        XCTAssertEqual(service.search(query: "mov", mode: .text, in: s).map(\.address), [0x1000])
        XCTAssertEqual(service.search(query: "ret", mode: .text, in: s).map(\.address), [0x1008])
        // String literal, case-insensitive.
        let strHit = service.search(query: "WORLD", mode: .text, in: s)
        XCTAssertEqual(strHit.map(\.address), [0x2000])
        XCTAssertEqual(strHit.first?.kind, .string)
        // Function name.
        XCTAssertEqual(service.search(query: "_main", mode: .text, in: s).first?.kind, .function)
        // Comment is searchable.
        XCTAssertEqual(service.search(query: "call helper", mode: .text, in: s).map(\.address), [0x1004])
    }

    func testTextSearchEmptyQueryReturnsNothing() {
        XCTAssertTrue(service.search(query: "   ", mode: .text, in: sample()).isEmpty)
    }

    func testResultsAreSortedByAddressAndDeduplicated() {
        // "helper" matches the bl operands, the comment, AND the symbol — all at
        // 0x1004 but as distinct kinds; the instruction surface should not double-emit.
        let hits = service.search(query: "helper", mode: .text, in: sample())
        XCTAssertEqual(hits.map(\.address).sorted(), hits.map(\.address)) // sorted
        let instructionHits = hits.filter { $0.kind == .instruction }
        XCTAssertEqual(instructionHits.count, 1)
        XCTAssertTrue(hits.contains { $0.kind == .symbol })
    }

    // MARK: - Regex

    func testRegexSearch() {
        let s = sample()
        XCTAssertEqual(service.search(query: "^bl\\b", mode: .regex, in: s).map(\.address), [0x1004])
        XCTAssertEqual(service.search(query: "H.llo", mode: .regex, in: s).map(\.address), [0x2000])
    }

    func testInvalidRegexReturnsNoResultsAndValidationMessage() {
        XCTAssertTrue(service.search(query: "(unclosed", mode: .regex, in: sample()).isEmpty)
        XCTAssertNotNil(service.validate(query: "(unclosed", mode: .regex))
        XCTAssertNil(service.validate(query: "valid.*", mode: .regex))
    }

    // MARK: - Hex

    func testHexSearchFindsBytePatternAtAddress() {
        let s = sample()
        XCTAssertEqual(service.search(query: "05 00 00 94", mode: .hex, in: s).map(\.address), [0x1004])
        XCTAssertEqual(service.search(query: "c0035fd6", mode: .hex, in: s).map(\.address), [0x1008])
        XCTAssertTrue(service.search(query: "48 89 e5", mode: .hex, in: s).isEmpty)
    }

    func testHexSearchMatchesAcrossInstructionBoundaries() {
        // 0x1007 is the last byte (0x94) of the bl; 0x1008 is the first (0xc0) of ret.
        XCTAssertEqual(service.search(query: "94 c0", mode: .hex, in: sample()).map(\.address), [0x1007])
    }

    func testHexPatternParsing() {
        XCTAssertEqual(BinarySearchService.parseHexPattern("48 89 e5"), [0x48, 0x89, 0xE5])
        XCTAssertEqual(BinarySearchService.parseHexPattern("4889e5"), [0x48, 0x89, 0xE5])
        XCTAssertEqual(BinarySearchService.parseHexPattern("0x48 0x89"), [0x48, 0x89])
        XCTAssertNil(BinarySearchService.parseHexPattern("abc"))   // odd nibble count
        XCTAssertNil(BinarySearchService.parseHexPattern(""))      // empty
        XCTAssertNil(BinarySearchService.parseHexPattern("zz"))    // non-hex
    }

    func testOddHexQueryIsRejectedWithValidationMessage() {
        XCTAssertTrue(service.search(query: "abc", mode: .hex, in: sample()).isEmpty)
        XCTAssertNotNil(service.validate(query: "abc", mode: .hex))
        XCTAssertNil(service.validate(query: "48 89", mode: .hex))
    }

    func testHexMatchesAreNonOverlapping() {
        // Four 0xAA bytes in one instruction: "aa aa" should match at offsets 0 and 2,
        // not 0/1/2 (non-overlapping advance).
        let s = snapshot(instructions: [instruction(0x4000, "aa aa aa aa", "x", "")])
        XCTAssertEqual(service.search(query: "aaaa", mode: .hex, in: s).map(\.address), [0x4000, 0x4002])
    }

    // MARK: - Section hex scan (PE virtualSize over-read guard)

    private func section(
        _ name: String,
        address: UInt64,
        size: UInt64,
        fileOffset: UInt64,
        isZeroFill: Bool = false
    ) -> SectionSummary {
        SectionSummary(
            id: UUID(),
            name: name,
            address: address,
            size: size,
            fileOffset: fileOffset,
            isExecutable: false,
            isZeroFill: isZeroFill
        )
    }

    private func sectionSnapshot(sections: [SectionSummary], imageBytes: Data) -> WorkspaceSnapshot {
        var s = snapshot()
        s.sections = sections
        s.imageBytes = imageBytes
        return s
    }

    /// Regression for the PE over-read bug: a section whose declared `size`
    /// (virtualSize) is LARGER than its real on-file bytes must NOT sweep past the
    /// next section's `fileOffset` into the next section's raw bytes — otherwise a
    /// pattern living in section #2 gets aliased onto section #1's virtual address.
    func testSectionHexScanDoesNotOverReadPastNextSectionRawBytes() {
        // imageBytes layout (file offsets):
        //   [0..4)   section ".text" real raw bytes      -> 11 22 33 44
        //   [4..8)   section ".data" real raw bytes      -> de ad be ef   (unique pattern)
        // ".text" declares size = 8 (virtualSize), 4 bytes LARGER than its 4 raw bytes,
        // so a naive [fileOffset, fileOffset+size) window would over-read into ".data".
        let imageBytes = Data([0x11, 0x22, 0x33, 0x44, 0xDE, 0xAD, 0xBE, 0xEF])
        let text = section(".text", address: 0x1000, size: 8, fileOffset: 0)   // virtualSize > raw
        let data = section(".data", address: 0x2000, size: 4, fileOffset: 4)
        let s = sectionSnapshot(sections: [text, data], imageBytes: imageBytes)

        // The unique pattern is reported at ".data"'s VA (0x2000), NOT aliased into
        // ".text" (which would be 0x1004 — text.address + the over-read offset).
        let hits = service.search(query: "de ad be ef", mode: .hex, in: s)
        XCTAssertEqual(hits.map(\.address), [0x2000])
        XCTAssertFalse(hits.contains { $0.address == 0x1004 })

        // And the over-read tail of ".text" must produce NO spurious match: searching
        // for ".data"'s first two bytes must not report a hit inside ".text".
        let tailHits = service.search(query: "de ad", mode: .hex, in: s)
        XCTAssertEqual(tailHits.map(\.address), [0x2000])
        XCTAssertFalse(tailHits.contains { $0.address >= 0x1000 && $0.address < 0x2000 })
    }

    /// A pattern that lives within ".text"'s real raw bytes is still found at its
    /// own VA — the clamp must not suppress legitimate in-section matches.
    func testSectionHexScanFindsPatternInItsOwnSection() {
        let imageBytes = Data([0x11, 0x22, 0x33, 0x44, 0xDE, 0xAD, 0xBE, 0xEF])
        let text = section(".text", address: 0x1000, size: 8, fileOffset: 0)
        let data = section(".data", address: 0x2000, size: 4, fileOffset: 4)
        let s = sectionSnapshot(sections: [text, data], imageBytes: imageBytes)
        XCTAssertEqual(service.search(query: "22 33", mode: .hex, in: s).map(\.address), [0x1001])
    }

    /// Zero-fill (BSS) sections have no file bytes and must be skipped entirely —
    /// they neither get scanned nor bound a neighbor's window.
    func testSectionHexScanSkipsZeroFillSections() {
        // .bss is zero-fill with a placeholder fileOffset; it must not be scanned.
        let imageBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let text = section(".text", address: 0x1000, size: 4, fileOffset: 0)
        let bss = section(".bss", address: 0x3000, size: 4, fileOffset: 0, isZeroFill: true)
        let s = sectionSnapshot(sections: [text, bss], imageBytes: imageBytes)
        // Found in .text only; .bss produces no (aliased) hit at 0x3000.
        let hits = service.search(query: "de ad be ef", mode: .hex, in: s)
        XCTAssertEqual(hits.map(\.address), [0x1000])
    }

    // MARK: - Limit

    func testResultsAreCappedAtTheLimit() {
        let many = (0..<(BinarySearchService.defaultLimit + 100)).map { i in
            instruction(0x1000 + UInt64(i) * 4, "1f 20 03 d5", "nop", "")
        }
        let s = snapshot(instructions: many)
        let hits = service.search(query: "nop", mode: .text, in: s)
        XCTAssertEqual(hits.count, BinarySearchService.defaultLimit)
        XCTAssertEqual(hits.first?.address, 0x1000) // sorted, first window
        // The pre-cap total is reported so the UI can say "N matches, showing first L".
        let outcome = service.searchWithCount(query: "nop", mode: .text, in: s)
        XCTAssertEqual(outcome.results.count, BinarySearchService.defaultLimit)
        XCTAssertEqual(outcome.total, BinarySearchService.defaultLimit + 100)
    }
}
