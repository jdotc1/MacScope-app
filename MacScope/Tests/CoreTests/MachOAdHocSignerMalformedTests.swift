import Foundation
import XCTest
@testable import MacScope

/// Crafted bytes only: these regressions require no compiler, signing tool, or executable launch.
final class MachOAdHocSignerMalformedTests: XCTestCase {
    private func put<T: FixedWidthInteger>(_ value: T, in bytes: inout Data, at offset: Int) {
        for index in 0 ..< MemoryLayout<T>.size {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private func header(commands: UInt32, size: UInt32) -> Data {
        var bytes = Data(repeating: 0, count: 32)
        put(UInt32(0xfeed_facf), in: &bytes, at: 0)
        put(UInt32(0x0100_000c), in: &bytes, at: 4)
        put(UInt32(2), in: &bytes, at: 12) // MH_EXECUTE
        put(commands, in: &bytes, at: 16)
        put(size, in: &bytes, at: 20)
        return bytes
    }

    private func signatureCommand(size: UInt32 = 16) -> Data {
        var bytes = Data(repeating: 0, count: Int(size))
        put(UInt32(0x1d), in: &bytes, at: 0) // LC_CODE_SIGNATURE
        put(size, in: &bytes, at: 4)
        return bytes
    }

    private func segment(_ name: String, offset: UInt64, size: UInt64) -> Data {
        var bytes = Data(repeating: 0, count: 72)
        put(UInt32(0x19), in: &bytes, at: 0) // LC_SEGMENT_64
        put(UInt32(72), in: &bytes, at: 4)
        bytes.replaceSubrange(8 ..< 8 + name.utf8.count, with: name.utf8)
        put(offset, in: &bytes, at: 40)
        put(size, in: &bytes, at: 48)
        return bytes
    }

    private func layout(linkeditOffset: UInt64, linkeditSize: UInt64) -> Data {
        var signature = signatureCommand()
        put(UInt32(192), in: &signature, at: 8)
        return header(commands: 3, size: 160)
            + segment("__TEXT", offset: 0, size: 192)
            + segment("__LINKEDIT", offset: linkeditOffset, size: linkeditSize)
            + signature
    }

    func testShortCodeSignatureCommandRefuses() {
        let bytes = header(commands: 1, size: 8) + signatureCommand(size: 8)
        XCTAssertThrowsError(try MachOAdHocSigner.resign(bytes)) {
            XCTAssertEqual($0 as? MachOAdHocSigner.Refusal, .malformedSignature)
        }
    }

    func testUnrepresentableLinkeditOffsetRefuses() {
        XCTAssertThrowsError(try MachOAdHocSigner.resign(
            layout(linkeditOffset: 0xffff_ffff_ffff_fff0, linkeditSize: 16))) {
            XCTAssertEqual($0 as? MachOAdHocSigner.Refusal, .layoutOverflow)
        }
    }

    func testUnrepresentableLinkeditSizeRefuses() {
        XCTAssertThrowsError(try MachOAdHocSigner.resign(
            layout(linkeditOffset: 0, linkeditSize: UInt64.max))) {
            XCTAssertEqual($0 as? MachOAdHocSigner.Refusal, .layoutOverflow)
        }
    }

    func testLinkeditEndOverflowRefuses() {
        XCTAssertThrowsError(try MachOAdHocSigner.resign(
            layout(linkeditOffset: UInt64(Int.max) - 15, linkeditSize: 16))) {
            XCTAssertEqual($0 as? MachOAdHocSigner.Refusal, .layoutOverflow)
        }
    }

    func testCommandScannerReportsPresenceWithoutVerifyingSignature() {
        XCTAssertFalse(MachOAdHocSigner.hasCodeSignatureCommand(header(commands: 0, size: 0)))
        XCTAssertTrue(MachOAdHocSigner.hasCodeSignatureCommand(
            header(commands: 1, size: 16) + signatureCommand()))
    }

    func testCommandScannerRejectsMalformedBounds() {
        var invalidMagic = header(commands: 1, size: 16) + signatureCommand()
        put(UInt32(0), in: &invalidMagic, at: 0)
        let malformed = [
            Data(), invalidMagic,
            header(commands: 1, size: 8) + signatureCommand(size: 8),
            header(commands: 1, size: 8) + signatureCommand(), // outside sizeofcmds
            header(commands: 1, size: 16) + signatureCommand(size: 8), // outside buffer
            header(commands: 2, size: 16) + signatureCommand(), // missing second command
            header(commands: 1, size: 8) + Data(repeating: 0, count: 8), // cmdsize < 8
        ]
        for bytes in malformed {
            XCTAssertFalse(MachOAdHocSigner.hasCodeSignatureCommand(bytes))
        }
    }

    func testResignRejectsCommandOutsideDeclaredRegion() {
        let bytes = header(commands: 1, size: 8) + signatureCommand()
        XCTAssertThrowsError(try MachOAdHocSigner.resign(bytes)) {
            XCTAssertEqual($0 as? MachOAdHocSigner.Refusal, .malformedSignature)
        }
    }

    func testUnchangedUnsignedExportReportsUnsignedAndPreservesBytes() throws {
        let bytes = MachOFixture.makeExecutable().bytes
        let identity = PreparedMachOPatchExport.Identity(
            imageOwnerID: UUID(), slotRawValue: 0, origin: .thinFile,
            selectedSliceSHA256: PreparedMachOPatchExport.sha256(bytes),
            selectedSliceByteCount: bytes.count)
        let prepared = try PreparedMachOPatchExport.prepare(rawBytes: bytes, identity: identity, patches: [:])
        XCTAssertFalse(prepared.bytesChanged)
        XCTAssertEqual(prepared.signing, .unsigned(reason: "the input has no code signature"))
        XCTAssertTrue(WorkspaceScriptingAPI.isUnsigned(prepared.signing))
        XCTAssertEqual(try prepared.data(ifStillOwnedBy: identity, currentPatches: [:]), bytes)
    }

    func testUnchangedSignatureSummaryDoesNotClaimVerification() {
        XCTAssertTrue(PreparedMachOPatchExport.Signing.unchanged.summary.contains("not re-verified"))
    }
}
