import Foundation
import XCTest
@testable import MacScope

/// Unit coverage for the shared checked-address-span helpers introduced by the
/// parser no-trap hardening (review BUG-003/BUG-008), plus the ARM64 decoder's
/// top-of-address-space behavior. The invariant across all of these: parser
/// -supplied address arithmetic never traps and never wraps to a plausible low
/// address — an unrepresentable result degrades to "absent".
final class AddressBoundsHardeningTests: XCTestCase {

    // MARK: - Range.validated

    func testValidatedSpanAcceptsOrdinaryAndExactTopOfAddressSpaceSpans() {
        XCTAssertEqual(Range<UInt64>.validated(start: 0x1000, size: 0x2000), 0x1000..<0x3000)
        // A span ending exactly at UInt64.max is representable and must survive.
        XCTAssertEqual(
            Range<UInt64>.validated(start: .max - 0x0FFF, size: 0x0FFF),
            (UInt64.max - 0x0FFF)..<UInt64.max
        )
        XCTAssertEqual(Range<UInt64>.validated(start: 0, size: .max), 0..<UInt64.max)
    }

    func testValidatedSpanRejectsZeroSizeAndOverflow() {
        XCTAssertNil(Range<UInt64>.validated(start: 0x1000, size: 0))
        // start + size == UInt64.max + 1 wraps to 0 — must be nil, not 0x...F000..<0x0.
        XCTAssertNil(Range<UInt64>.validated(start: .max - 0x0FFF, size: 0x1000))
        XCTAssertNil(Range<UInt64>.validated(start: .max, size: 1))
        XCTAssertNil(Range<UInt64>.validated(start: .max, size: .max))
    }

    // MARK: - UInt64.isContiguous / addressAfter

    func testInstructionAdjacencyIsCheckedNotWrapped() {
        XCTAssertTrue(UInt64(0x1000).isContiguous(to: 0x1004))
        XCTAssertFalse(UInt64(0x1000).isContiguous(to: 0x1008))
        // At the top of the address space `address + 4` used to trap; a wrapped
        // low "neighbor" must also never count as adjacent.
        XCTAssertFalse(UInt64.max.isContiguous(to: 3))
        XCTAssertFalse((UInt64.max - 3).isContiguous(to: 0))
        XCTAssertTrue((UInt64.max - 4).isContiguous(to: .max))
    }

    func testAddressAfterDegradesToNilAtTopOfAddressSpace() {
        XCTAssertEqual(UInt64(0x1000).addressAfter(), 0x1004)
        XCTAssertEqual((UInt64.max - 4).addressAfter(), .max)
        XCTAssertNil(UInt64.max.addressAfter())
        XCTAssertNil((UInt64.max - 3).addressAfter())
    }

    // MARK: - ARM64 decoder at the top of the address space (BUG-008)

    /// 16 bytes of NOPs based at `.max - 7`: only two instruction addresses
    /// (`.max - 7`, `.max - 3`) are representable; the sweep previously trapped
    /// computing the third. The decoder must return exactly the representable
    /// prefix and never emit a wrapped near-zero address.
    func testDecoderTruncatesToRepresentablePrefixNearAddressSpaceTop() {
        let nop: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]
        let bytes = Data(nop + nop + nop + nop)
        let decoded = ARM64Decoder().decode(bytes, baseAddress: .max - 7)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.map(\.address), [.max - 7, .max - 3])
        XCTAssertFalse(decoded.contains { $0.address < 0x1000 },
                       "no wrapped low address may ever be fabricated")
    }

    /// The final representable slot: a single instruction may sit at `.max - 3`
    /// (its own address is representable; only its successor is not).
    func testDecoderDecodesFinalRepresentableInstructionSlot() {
        let nop: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]
        let decoded = ARM64Decoder().decode(Data(nop + nop), baseAddress: .max - 3)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.address, .max - 3)
    }

    /// Ordinary decodes are unaffected by the representable-prefix clamp.
    func testDecoderOrdinaryBaseAddressIsUnaffected() {
        let nop: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]
        let decoded = ARM64Decoder().decode(Data(nop + nop + nop), baseAddress: 0x100003f00)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.address), [0x100003f00, 0x100003f04, 0x100003f08])
    }

    // MARK: - AnalysisDiagnosticsCollector with a wrapping section (BUG-003)

    private func row(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
    }

    /// A section whose `address + size` wraps past UInt64.max previously fed the
    /// `Range` precondition (`address..<(address &+ size)` with `upperBound <
    /// lowerBound`), a fatalError, straight from parsed section fields. The
    /// collector must instead drop the unusable section: an xref targeting the
    /// wrapped window is reported as landing in no section, never silently
    /// absorbed by a bogus low-address range, and the collector never traps.
    func testCollectorDropsOverflowingSectionRatherThanTrapping() {
        let overflowing = SectionSummary(
            id: UUID(), name: "__HOSTILE,__hostile",
            address: .max - 0x10, size: 0x1000, // wraps to 0x0FEF
            fileOffset: 0, isExecutable: false
        )
        let input = AnalysisDiagnosticsCollector.Input(
            instructions: [row(0x1000)],
            controlFlowEdges: [],
            xrefs: [XRef(id: UUID(), from: 0x1000, to: 0x0500, kind: XRefKind.data)],
            sections: [overflowing]
        )

        let diagnostics = AnalysisDiagnosticsCollector().collect(input)

        // The xref target 0x0500 lies inside the *wrapped* low window a bogus
        // range would have covered. With the section dropped it is in no section.
        XCTAssertTrue(
            diagnostics.contains { $0.address == 0x0500 },
            "an xref into the dropped section's wrapped window must be flagged, not absorbed"
        )
    }
}
