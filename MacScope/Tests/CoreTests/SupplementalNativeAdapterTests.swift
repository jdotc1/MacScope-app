import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// The nine roadmap-v2 draft tests (reference-code/macOS-adapters) for MS-15's
/// `PreparedMachOPatchExport` and the RX `SupplementalNavigationAdapter`. `MachOFixture.makeExecutable()`
/// is the existing CoreTests thin Mach-O fixture used by MachOPatchWriterTests.
final class SupplementalNativeAdapterTests: XCTestCase {
    // MARK: Navigation (mappings must come from snapshot.imageByteMappings(in: explicitSlot))

    func testMappedSpanUsesExistingAuthority() throws {
        let span = try ByteExtent(offset: 16, count: 4, payloadSize: 32)
        let mappings = [FileAddressMapping(fileOffset: 16, size: 16, virtualAddress: 0x1000)]
        XCTAssertEqual(SupplementalNavigationAdapter.target(for: span, mappings: mappings),
                       .virtualAddress(start: 0x1000, byteCount: 4))
    }
    func testHeaderWithoutMappingRemainsPayloadOnly() throws {
        let span = try ByteExtent(offset: 0, count: 4, payloadSize: 32)
        let mappings = [FileAddressMapping(fileOffset: 16, size: 16, virtualAddress: 0x1000)]
        XCTAssertEqual(SupplementalNavigationAdapter.target(for: span, mappings: mappings),
                       .payloadOnly(offset: 0, byteCount: 4))
    }
    func testInteriorAliasCannotBeHiddenByAgreeingEndpoints() throws {
        let span = try ByteExtent(offset: 16, count: 12, payloadSize: 32)
        let mappings = [FileAddressMapping(fileOffset: 16, size: 16, virtualAddress: 0x1000),
                        FileAddressMapping(fileOffset: 20, size: 2, virtualAddress: 0x9000)]
        XCTAssertEqual(SupplementalNavigationAdapter.target(for: span, mappings: mappings),
                       .payloadOnly(offset: 16, byteCount: 12))
    }
    func testCrossMappingSpanIsNotInventedAsOneRange() throws {
        let span = try ByteExtent(offset: 16, count: 8, payloadSize: 32)
        let mappings = [FileAddressMapping(fileOffset: 16, size: 4, virtualAddress: 0x1000),
                        FileAddressMapping(fileOffset: 20, size: 4, virtualAddress: 0x1004)]
        XCTAssertEqual(SupplementalNavigationAdapter.target(for: span, mappings: mappings),
                       .payloadOnly(offset: 16, byteCount: 8))
    }

    // MARK: Prepared patched export (MS-15)

    func testPreparedExportPatchesCapturedBytesExactly() throws {
        let fixture = MachOFixture.makeExecutable()
        let patches = [fixture.baseAddress: BytePatch.arm64NOP]
        let prepared = try PreparedMachOPatchExport.prepare(
            rawBytes: fixture.bytes, identity: identity(for: fixture.bytes), patches: patches)
        let output = try prepared.data(ifStillOwnedBy: identity(for: fixture.bytes), currentPatches: patches)
        XCTAssertTrue(prepared.bytesChanged)
        XCTAssertEqual(Array(output[fixture.codeOffset..<(fixture.codeOffset + 4)]), BytePatch.arm64NOP.bytes)
        var expected = Array(fixture.bytes)
        expected.replaceSubrange(fixture.codeOffset..<(fixture.codeOffset + 4), with: BytePatch.arm64NOP.bytes)
        XCTAssertEqual(Array(output), expected)
    }
    func testPreparedExportRejectsChangedBytesBeforeParser() throws {
        let fixture = MachOFixture.makeExecutable()
        var replaced = fixture.bytes
        replaced[fixture.codeOffset] ^= 0xff
        XCTAssertThrowsError(try PreparedMachOPatchExport.prepare(
            rawBytes: replaced, identity: identity(for: fixture.bytes), patches: [:])) {
            XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError, .byteIdentityMismatch)
        }
    }
    func testPreparedExportRefusesSliceAndDyldProjection() throws {
        let fixture = MachOFixture.makeExecutable()
        for origin in [PreparedMachOPatchExport.Origin.universalSlice, .dyldCacheProjection, .other] {
            XCTAssertThrowsError(try PreparedMachOPatchExport.prepare(
                rawBytes: fixture.bytes, identity: identity(for: fixture.bytes, origin: origin), patches: [:])) {
                XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError, .unsupportedOrigin(origin))
            }
        }
    }
    func testPatchEditAfterPreparationIsStale() throws {
        let fixture = MachOFixture.makeExecutable()
        let patches = [fixture.baseAddress: BytePatch.arm64NOP]
        let prepared = try PreparedMachOPatchExport.prepare(
            rawBytes: fixture.bytes, identity: identity(for: fixture.bytes), patches: patches)
        var edited = patches
        edited[fixture.baseAddress + 4] = BytePatch.arm64NOP
        XCTAssertThrowsError(try prepared.data(ifStillOwnedBy: identity(for: fixture.bytes), currentPatches: edited)) {
            XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError, .staleInvestigation)
        }
    }
    func testPatchDigestIgnoresEmptyPatchesAndOrder() {
        let a: [UInt64: BytePatch] = [0x10: .arm64NOP, 0x20: BytePatch(bytes: [1])]
        let b: [UInt64: BytePatch] = [0x20: BytePatch(bytes: [1]), 0x10: .arm64NOP, 0x30: BytePatch(bytes: [])]
        XCTAssertEqual(PreparedMachOPatchExport.canonicalPatchDigest(a), PreparedMachOPatchExport.canonicalPatchDigest(b))
    }

    private func identity(for bytes: Data, origin: PreparedMachOPatchExport.Origin = .thinFile)
        -> PreparedMachOPatchExport.Identity {
        .init(imageOwnerID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, slotRawValue: 0,
              origin: origin,
              selectedSliceSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
              selectedSliceByteCount: bytes.count)
    }
}
