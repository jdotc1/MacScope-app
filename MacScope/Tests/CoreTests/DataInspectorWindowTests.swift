import Foundation
import XCTest
@testable import MacScope

/// The inspector's Data section reads the selection's own bytes through the section table, past
/// the leading 4 KiB window and on images whose first instruction isn't at file offset 0
/// (Tier 2 GUI finding: it said "outside the loaded bytes" past 4 KiB, and decoded header
/// bytes for in-window selections on real binaries).
final class DataInspectorWindowTests: XCTestCase {
    private let base: UInt64 = 0x1_0000_0000
    private let textOffset = 0x700

    /// A 64 KiB image whose __text starts at file offset 0x700 (a header before it), every byte its
    /// own offset mod 251.
    private func snapshot() -> WorkspaceSnapshot {
        let bytes = Data((0..<65_536).map { UInt8($0 % 251) })
        let textAddress = base + UInt64(textOffset)
        return WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "img", path: "", kind: "fixture", architecture: "arm64")],
            functions: [],
            instructions: [InstructionRow(address: textAddress, bytes: "1f2003d5", mnemonic: "nop", operands: "",
                                          hasBreakpoint: false, comment: nil)],
            xrefs: [],
            hexBytes: Data(bytes.prefix(WorkspaceSnapshot.hexViewByteWindow)),
            sections: [SectionSummary(id: UUID(), name: "__text", address: textAddress, size: UInt64(65_536 - textOffset),
                                      fileOffset: UInt64(textOffset), isExecutable: true)],
            imageBytes: bytes
        )
    }

    private func reading(at address: UInt64, in snapshot: WorkspaceSnapshot) -> DataInspectorReading {
        let window = DataInspectorReading.window(at: address, length: 32, read: snapshot.hexByteReader(in: .primary))
        return DataInspectorReading(bytes: window ?? Data(), baseAddress: address, selectedAddress: address,
                                    hasLoadedBytes: true)
    }

    func testTheSelectionsOwnBytesAreReadInsideAndPastTheLeadingWindow() throws {
        let snapshot = snapshot()
        for fileOffset in [textOffset, textOffset + 0x10, 0x3000, 0xFF00] {
            let address = base + UInt64(fileOffset)
            let reading = reading(at: address, in: snapshot)
            XCTAssertTrue(reading.isResolvable, "0x\(String(fileOffset, radix: 16))")
            XCTAssertEqual(reading.bytes.first, UInt8(fileOffset % 251), "0x\(String(fileOffset, radix: 16)) reads its own byte")
        }
    }

    func testTheWindowShrinksAtTheEndOfTheMappedRangeAndIsNilOutsideIt() {
        let snapshot = snapshot()
        let read = snapshot.hexByteReader(in: .primary)
        XCTAssertEqual(DataInspectorReading.window(at: base + 65_536 - 3, length: 32, read: read)?.count, 2)
        XCTAssertEqual(DataInspectorReading.window(at: base + 65_536 - 8, length: 32, read: read)?.count, 8)
        XCTAssertNil(DataInspectorReading.window(at: base + 0x20_0000, length: 32, read: read))
        let outside = reading(at: base + 0x20_0000, in: snapshot)
        XCTAssertFalse(outside.isResolvable)
        XCTAssertEqual(outside.availabilityNote, "Selection is outside the loaded bytes.")
        XCTAssertEqual(DataInspectorReading(bytes: Data(), baseAddress: nil, selectedAddress: nil).availabilityNote,
                       "No bytes are loaded for the current target.")
    }
}
