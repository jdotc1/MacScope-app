import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerPatchedPayloadTests: XCTestCase {
    func testOverlappingEditsMaterializeInAddressOrderWithoutChangingRawBytes() throws {
        let raw = Data((0..<24).map { UInt8($0) })[8..<24]
        let payload = try NativeDecompilerPatchedPayload(
            patches: [
                0x1003: .init(bytes: [0xaa, 0xbb]),
                0x1004: .init(bytes: [0xcc]),
            ],
            mappings: [.init(fileOffset: 8, size: 16, virtualAddress: 0x1000)],
            selectedSliceByteCount: 24
        )
        let region = try payload.region(
            rawBytes: raw, at: 0x1000, sliceRelativeFileOffset: 8
        )
        XCTAssertEqual(region.rawBytes, raw)
        XCTAssertEqual(region.effectiveBytes[region.effectiveBytes.startIndex + 3], 0xaa)
        XCTAssertEqual(region.effectiveBytes[region.effectiveBytes.startIndex + 4], 0xcc)
        XCTAssertEqual(region.appliedEditIndices, [0, 1])
        XCTAssertEqual(region.appliedFileRanges, [11..<13, 12..<13])
        XCTAssertEqual(raw[raw.startIndex + 4], 12)
    }

    func testAliasAndOutOfPayloadRefuseBeforeMaterialization() throws {
        let alias = [
            FileAddressMapping(fileOffset: 0, size: 8, virtualAddress: 0x1000),
            FileAddressMapping(fileOffset: 0, size: 8, virtualAddress: 0x2000),
        ]
        XCTAssertThrowsError(try NativeDecompilerPatchedPayload(
            patches: [0x1000: .init(bytes: [1])],
            mappings: alias, selectedSliceByteCount: 8
        )) { error in
            XCTAssertEqual(error as? BytePatchOverlay.Failure, .unmappedPatch(address: 0x1000))
        }

        XCTAssertThrowsError(try NativeDecompilerPatchedPayload(
            patches: [0x1004: .init(bytes: [1, 2, 3, 4])],
            mappings: [.init(fileOffset: 12, size: 8, virtualAddress: 0x1000)],
            selectedSliceByteCount: 16
        )) { error in
            XCTAssertEqual(error as? NativeDecompilerPatchedPayload.Failure, .outOfPayload)
        }
    }

    func testRegionMustMatchVerifiedFileOffset() throws {
        let payload = try NativeDecompilerPatchedPayload(
            patches: [0x1004: .init(bytes: [0xaa])],
            mappings: [.init(fileOffset: 8, size: 16, virtualAddress: 0x1000)],
            selectedSliceByteCount: 24
        )
        XCTAssertThrowsError(try payload.region(
            rawBytes: Data(repeating: 0, count: 8),
            at: 0x1000, sliceRelativeFileOffset: 9
        )) { error in
            XCTAssertEqual(error as? NativeDecompilerPatchedPayload.Failure, .regionMappingMismatch)
        }
    }
}
