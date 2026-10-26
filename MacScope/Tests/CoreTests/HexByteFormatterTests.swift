import XCTest
@testable import MacScope

/// `HexByteFormatter.spacedHex` replaces the `bytes.map { String(format: "%02x", $0) }.joined(...)`
/// idiom on the hot decode path. Its contract is BYTE-IDENTICAL output, so the listing/golden text
/// never changes — only the speed. These tests pin that identity against the very idiom it replaces.
final class HexByteFormatterTests: XCTestCase {
    /// The reference: the exact expression `spacedHex` is optimizing.
    private func reference(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func testMatchesReferenceForEdgeCases() {
        for bytes: [UInt8] in [[], [0x00], [0xff], [0x01], [0x0f], [0xa9], [0xfd, 0x7b, 0xbf, 0xa9]] {
            XCTAssertEqual(HexByteFormatter.spacedHex(bytes), reference(bytes), "mismatch for \(bytes)")
        }
    }

    /// Every single byte value 0x00...0xff formats identically (catches any nibble/zero-pad slip).
    func testMatchesReferenceForAllByteValues() {
        for value in UInt8.min...UInt8.max {
            XCTAssertEqual(HexByteFormatter.spacedHex([value]), reference([value]))
        }
    }

    /// Multi-byte sequences across lengths (the separator placement is the easy thing to get wrong).
    func testMatchesReferenceForVariousLengths() {
        var rolling: [UInt8] = []
        for index in 0..<300 {
            rolling.append(UInt8(truncatingIfNeeded: index &* 37 &+ 13))
            XCTAssertEqual(HexByteFormatter.spacedHex(rolling), reference(rolling),
                           "mismatch at length \(rolling.count)")
        }
    }
}
