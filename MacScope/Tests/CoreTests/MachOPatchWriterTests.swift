import Foundation
import XCTest
@testable import MacScope

/// Verifies `MachOPatchWriter`: the pure "Save Patched Binary" engine that maps each
/// virtual-address byte patch back to its FILE OFFSET and produces a patched copy of the
/// original binary. The fixtures reuse `MachOFixture` (a real, parseable thin Mach-O) so the
/// VA→file-offset projection runs against the same segment table the loader builds.
final class MachOPatchWriterTests: XCTestCase {
    private let writer = MachOPatchWriter()

    // MARK: - Appended executable cave with a final signed __LINKEDIT

    func testSignedFinalLinkeditMovesBehindAppendedCaveAndBranchesFromOriginalText() throws {
        let fixture = Self.makeSignedExecutableWithCommandSlack()
        let cave = Data([0x1f, 0x20, 0x03, 0xd5, 0xc0, 0x03, 0x5f, 0xd6])
        let result = try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: fixture.bytes, patches: [:], caveBytes: cave,
            branchSourceAddress: fixture.baseAddress
        )
        XCTAssertEqual(result.fileOffset, 0xc000)
        XCTAssertEqual(result.virtualAddress, 0x1_0000_c000)
        XCTAssertEqual(result.byteCount, cave.count)
        XCTAssertEqual(result.branchSourceAddress, fixture.baseAddress)
        XCTAssertEqual(result.branchInstruction, 0x1400_2000)
        XCTAssertEqual(Array(result.data[fixture.codeOffset..<(fixture.codeOffset + 4)]),
                       [0x00, 0x20, 0x00, 0x14])
        XCTAssertEqual(Data(result.data[Int(result.fileOffset)..<(Int(result.fileOffset) + cave.count)]), cave)

        let parsed = try MachOParser().parse(result.data, options: MachOParseOptions(
            recoverStringLiterals: false, recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false, parseCodeSignature: false
        ))
        let link = try XCTUnwrap(parsed.segments.first(where: { $0.name == "__LINKEDIT" }))
        XCTAssertEqual(link.fileOffset, 0x1_0000)
        XCTAssertEqual(link.vmAddress, 0x1_0001_0000)
        XCTAssertEqual(parsed.virtualAddress(forFileOffset: result.fileOffset), result.virtualAddress)
        // LC_CODE_SIGNATURE is after the newly mapped code, at the end of the
        // relocated linkedit. Its bytes are retained but require re-signing.
        let signature = try XCTUnwrap(parsed.loadCommands.first(where: {
            $0.command == MachOConstants.loadCommandCodeSignature
        }))
        let signatureCommand = Int(signature.offset)
        XCTAssertEqual(Self.read32(result.data, at: signatureCommand + 8), 0x1_0000)
        XCTAssertEqual(Self.read32(result.data, at: signatureCommand + 12), 0x100)
        XCTAssertEqual(Data(result.data[0x1_0000..<0x1_0100]), Data(fixture.bytes[0x8000..<0x8100]))
        XCTAssertEqual(Data(result.data[0x8000..<0x8100]), Data(fixture.bytes[0x8000..<0x8100]))
        XCTAssertEqual(Data(result.data[(fixture.codeOffset + 4)..<(fixture.codeOffset + fixture.code.count)]),
                       Data(fixture.bytes[(fixture.codeOffset + 4)..<(fixture.codeOffset + fixture.code.count)]))
    }

    func testSignedCaveRefusesOccupiedCommandSlackAndOverlappingBranchPatch() throws {
        let fixture = Self.makeSignedExecutableWithCommandSlack()
        let cave = Data([0x1f, 0x20, 0x03, 0xd5])
        var occupied = fixture.bytes
        occupied[400] = 0xaa
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: occupied, patches: [:], caveBytes: cave
        )) { error in
            guard case .unsupportedLayout = error as? MachOPatchWriter.CaveWriteError else {
                return XCTFail("expected unsupportedLayout, got \(error)")
            }
        }
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: fixture.bytes,
            patches: [fixture.baseAddress + 2: BytePatch(bytes: [0x55])],
            caveBytes: cave, branchSourceAddress: fixture.baseAddress
        )) { error in
            XCTAssertEqual(error as? MachOPatchWriter.CaveWriteError, .conflictingBranchPatch)
        }
    }

    func testSignedCaveRefusesNonFinalSignatureAndUnknownOffsetCommand() throws {
        let fixture = Self.makeSignedExecutableWithCommandSlack()
        let cave = Data([0x1f, 0x20, 0x03, 0xd5])
        var signatureNotFinal = fixture.bytes
        Self.write32(0x80, into: &signatureNotFinal, at: 280 + 12)
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: signatureNotFinal, patches: [:], caveBytes: cave
        ))
        var unknownCommand = fixture.bytes
        Self.write32(0x7654_3210, into: &unknownCommand, at: 280)
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: unknownCommand, patches: [:], caveBytes: cave
        )) { error in
            guard case .unsupportedLayout = error as? MachOPatchWriter.CaveWriteError else {
                return XCTFail("expected unsupportedLayout, got \(error)")
            }
        }
    }

    func testSignedCavePreservesClassicDyldInfoAndRefusesMovedSegmentOrdinal() throws {
        var fixture = Self.makeSignedExecutableWithCommandSlack()
        // Insert classic dyld-info immediately after the UUID command. Its rebase
        // and bind programs address __TEXT (ordinal 0), which stays ordinal 0.
        Self.write32(6, into: &fixture.bytes, at: 16)
        Self.write32(336, into: &fixture.bytes, at: 20)
        Self.write64(0x200, into: &fixture.bytes, at: 208 + 48)
        Self.write32(0x8100, into: &fixture.bytes, at: 280 + 8)
        fixture.bytes.insert(contentsOf: repeatElement(0, count: 0x100), at: 0x8000)
        var command = Data()
        Self.append32(MachOConstants.loadCommandDyldInfoOnly, to: &command)
        Self.append32(48, to: &command)
        for value: UInt32 in [0x8000, 3, 0x8003, 3, 0, 0, 0, 0, 0, 0] {
            Self.append32(value, to: &command)
        }
        fixture.bytes.replaceSubrange(320..<368, with: command)
        fixture.bytes.replaceSubrange(0x8000..<0x8006,
                                      with: [0x20, 0x00, 0x00, 0x70, 0x00, 0x00])

        let cave = Data([0x1f, 0x20, 0x03, 0xd5])
        let output = try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: fixture.bytes, patches: [:], caveBytes: cave
        )
        let dyld = try XCTUnwrap(try MachOParser().parse(output.data).loadCommands.first(where: {
            $0.command == MachOConstants.loadCommandDyldInfoOnly
        }))
        XCTAssertEqual(Self.read32(output.data, at: Int(dyld.offset) + 8), 0x1_0000)
        XCTAssertEqual(Array(output.data[0x1_0000..<0x1_0006]),
                       [0x20, 0x00, 0x00, 0x70, 0x00, 0x00])

        // The old __LINKEDIT ordinal was 1. Inserting a cave before it changes
        // that ordinal, so the writer must refuse rather than silently rebind.
        fixture.bytes[0x8000] = 0x21
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: fixture.bytes, patches: [:], caveBytes: cave
        )) { error in
            guard case .unsupportedLayout(let reason) = error as? MachOPatchWriter.CaveWriteError else {
                return XCTFail("expected unsupportedLayout, got \(error)")
            }
            XCTAssertEqual(reason, "rebase targets relocated __LINKEDIT")
        }

        // The parser's merged export list omits the root's unnamed terminal.
        // Raw trie traversal still has to reject an address in moved __LINKEDIT.
        fixture.bytes[0x8000] = 0x20
        Self.write32(0x8006, into: &fixture.bytes, at: 320 + 40)
        Self.write32(6, into: &fixture.bytes, at: 320 + 44)
        fixture.bytes.replaceSubrange(0x8006..<0x800c,
                                      with: [4, 0, 0x80, 0x80, 0x02, 0])
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: fixture.bytes, patches: [:], caveBytes: cave
        )) { error in
            guard case .unsupportedLayout(let reason) = error as? MachOPatchWriter.CaveWriteError else {
                return XCTFail("expected unsupportedLayout, got \(error)")
            }
            XCTAssertEqual(reason, "export trie targets relocated __LINKEDIT")
        }
    }

    static func makeSignedExecutableWithCommandSlack() -> MachOFixture {
        var fixture = MachOFixture.makeExecutable()
        let oldOffset = fixture.codeOffset
        let textOffset = 0x4000
        fixture.bytes.insert(contentsOf: repeatElement(0, count: textOffset - oldOffset), at: oldOffset)
        let base: UInt64 = 0x1_0000_0000
        write64(0x8000, into: &fixture.bytes, at: 64) // __TEXT vmsize
        write64(UInt64(textOffset + fixture.code.count), into: &fixture.bytes, at: 80)
        write64(base + UInt64(textOffset), into: &fixture.bytes, at: 136)
        write32(UInt32(textOffset), into: &fixture.bytes, at: 152)
        write64(UInt64(textOffset), into: &fixture.bytes, at: 192) // LC_MAIN entryoff
        fixture.codeOffset = textOffset
        fixture.baseAddress = base + UInt64(textOffset)

        // The only new load commands are a final sectionless __LINKEDIT and
        // LC_CODE_SIGNATURE. The signature blob occupies the last 256 bytes.
        var linkCommand = Data()
        append32(MachOConstants.loadCommandSegment64, to: &linkCommand)
        append32(72, to: &linkCommand)
        appendName("__LINKEDIT", to: &linkCommand)
        append64(base + 0x8000, to: &linkCommand)
        append64(0x4000, to: &linkCommand)
        append64(0x8000, to: &linkCommand)
        append64(0x100, to: &linkCommand)
        append32(1, to: &linkCommand)
        append32(1, to: &linkCommand)
        append32(0, to: &linkCommand)
        append32(0, to: &linkCommand)
        fixture.bytes.replaceSubrange(208..<280, with: linkCommand)
        var signatureCommand = Data()
        append32(MachOConstants.loadCommandCodeSignature, to: &signatureCommand)
        append32(16, to: &signatureCommand)
        append32(0x8000, to: &signatureCommand)
        append32(0x100, to: &signatureCommand)
        fixture.bytes.replaceSubrange(280..<296, with: signatureCommand)
        var uuidCommand = Data()
        append32(MachOConstants.loadCommandUUID, to: &uuidCommand)
        append32(24, to: &uuidCommand)
        uuidCommand.append(contentsOf: (1...16).map(UInt8.init))
        fixture.bytes.replaceSubrange(296..<320, with: uuidCommand)
        write32(5, into: &fixture.bytes, at: 16)
        write32(288, into: &fixture.bytes, at: 20)
        fixture.bytes.append(contentsOf: repeatElement(0, count: 0x8000 - fixture.bytes.count))
        fixture.bytes.append(contentsOf: repeatElement(0x5a, count: 0x100))
        return fixture
    }

    private static func read32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        for index in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }

    private static func append64(_ value: UInt64, to data: inout Data) {
        for index in 0..<8 { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }

    private static func appendName(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
        data.append(contentsOf: repeatElement(0, count: 16 - value.utf8.count))
    }

    private static func write32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private static func write64(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    // MARK: - Core: bytes land at the right offset, everything else is untouched

    func testPatchWritesReplacementBytesAtTheMappedFileOffsetAndLeavesEverythingElseIdentical() throws {
        let fixture = MachOFixture.makeExecutable()
        // The fixture's first instruction sits at VA `baseAddress`, file offset `codeOffset`.
        // Patch it with the canonical ARM64 NOP and confirm the projection is exact.
        let patchBytes: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]
        let patches: [UInt64: BytePatch] = [fixture.baseAddress: BytePatch(bytes: patchBytes)]

        let patched = try writer.makePatchedData(originalData: fixture.bytes, patches: patches)

        // Same length — a patch never grows or shrinks the file.
        XCTAssertEqual(patched.count, fixture.bytes.count)

        // (a) The patched bytes are at the correct file offset.
        let start = fixture.codeOffset
        XCTAssertEqual(Array(patched[start..<(start + patchBytes.count)]), patchBytes)

        // (b) Every OTHER byte is identical to the original.
        let original = Array(fixture.bytes)
        let patchedArray = Array(patched)
        for index in 0..<original.count where !(start..<(start + patchBytes.count)).contains(index) {
            XCTAssertEqual(patchedArray[index], original[index], "byte at offset \(index) changed unexpectedly")
        }
    }

    func testPatchAtSecondInstructionMapsThroughTheSegmentOffset() throws {
        let fixture = MachOFixture.makeExecutable()
        // Second instruction: VA + 4, file offset codeOffset + 4. Confirms the projection is
        // `segment.fileOffset + (va - segment.vmAddress)`, not a hard-coded code-start.
        let address = fixture.baseAddress + 4
        let patchBytes: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd]
        let patched = try writer.makePatchedData(
            originalData: fixture.bytes,
            patches: [address: BytePatch(bytes: patchBytes)]
        )

        let start = fixture.codeOffset + 4
        XCTAssertEqual(Array(patched[start..<(start + 4)]), patchBytes)
        // The first instruction (offset codeOffset) is untouched.
        XCTAssertEqual(
            Array(patched[fixture.codeOffset..<(fixture.codeOffset + 4)]),
            Array(fixture.bytes[fixture.codeOffset..<(fixture.codeOffset + 4)])
        )
    }

    func testMultiplePatchesAreAllApplied() throws {
        let fixture = MachOFixture.makeExecutable()
        let first: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let second: [UInt8] = [0x05, 0x06, 0x07, 0x08]
        let patched = try writer.makePatchedData(
            originalData: fixture.bytes,
            patches: [
                fixture.baseAddress: BytePatch(bytes: first),
                fixture.baseAddress + 8: BytePatch(bytes: second)
            ]
        )

        XCTAssertEqual(Array(patched[fixture.codeOffset..<(fixture.codeOffset + 4)]), first)
        XCTAssertEqual(Array(patched[(fixture.codeOffset + 8)..<(fixture.codeOffset + 12)]), second)
        XCTAssertEqual(patched.count, fixture.bytes.count)
    }

    func testAShorterPatchOnlyOverwritesItsOwnBytes() throws {
        let fixture = MachOFixture.makeExecutable()
        // A 1-byte patch must touch exactly one byte; the following 3 bytes of the instruction
        // stay as the original encoding.
        let patched = try writer.makePatchedData(
            originalData: fixture.bytes,
            patches: [fixture.baseAddress: BytePatch(bytes: [0x99])]
        )
        XCTAssertEqual(patched[fixture.codeOffset], 0x99)
        for offset in 1..<4 {
            XCTAssertEqual(patched[fixture.codeOffset + offset], fixture.bytes[fixture.codeOffset + offset])
        }
    }

    // MARK: - No-op

    func testEmptyPatchMapReturnsByteIdenticalCopy() throws {
        let fixture = MachOFixture.makeExecutable()
        let patched = try writer.makePatchedData(originalData: fixture.bytes, patches: [:])
        XCTAssertEqual(patched, fixture.bytes)
    }

    func testDegenerateEmptyPatchIsIgnored() throws {
        let fixture = MachOFixture.makeExecutable()
        // A patch carrying no bytes prunes like a cleared override — output stays identical.
        let patched = try writer.makePatchedData(
            originalData: fixture.bytes,
            patches: [fixture.baseAddress: BytePatch(bytes: [])]
        )
        XCTAssertEqual(patched, fixture.bytes)
    }

    // MARK: - Conservative failure modes (no silent corruption)

    func testFatBinaryFailsWithTypedError() throws {
        let fixture = MachOFixture.makeUniversalExecutable()
        XCTAssertThrowsError(
            try writer.makePatchedData(
                originalData: fixture.bytes,
                patches: [fixture.baseAddress: BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])]
            )
        ) { error in
            XCTAssertEqual(error as? MachOPatchWriter.PatchWriteError, .fatBinaryUnsupported)
        }
    }

    func testUnmappedAddressFailsWithTypedError() throws {
        let fixture = MachOFixture.makeExecutable()
        // An address far above any segment's VM range maps to no file-backed segment.
        let unmapped: UInt64 = 0xdead_0000_0000
        XCTAssertThrowsError(
            try writer.makePatchedData(
                originalData: fixture.bytes,
                patches: [unmapped: BytePatch(bytes: [0x00])]
            )
        ) { error in
            XCTAssertEqual(error as? MachOPatchWriter.PatchWriteError, .addressNotMapped(address: unmapped))
        }
    }

    func testPatchOverrunningTheSegmentFileContentFailsWithTypedError() throws {
        let fixture = MachOFixture.makeExecutable()
        // The __TEXT segment's file content ends at codeOffset + code.count. A patch that
        // STARTS inside the last instruction but is longer than the bytes remaining to the
        // end of the segment's file content must be rejected (it would spill off the slice).
        let lastInstructionAddress = fixture.baseAddress + UInt64(fixture.code.count - 4)
        // 8-byte run starting 4 bytes before the segment's file end → overruns by 4.
        let tooLong = BytePatch(bytes: [UInt8](repeating: 0xee, count: 8))
        XCTAssertThrowsError(
            try writer.makePatchedData(
                originalData: fixture.bytes,
                patches: [lastInstructionAddress: tooLong]
            )
        ) { error in
            XCTAssertEqual(
                error as? MachOPatchWriter.PatchWriteError,
                .patchExceedsSegment(address: lastInstructionAddress, length: 8)
            )
        }
    }

    func testNonMachOInputFailsWithTypedError() throws {
        // A buffer that is neither fat nor a valid thin Mach-O (random bytes) fails cleanly.
        let garbage = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        XCTAssertThrowsError(
            try writer.makePatchedData(
                originalData: garbage,
                patches: [0x1000: BytePatch(bytes: [0x90])]
            )
        ) { error in
            guard case .notMachO = (error as? MachOPatchWriter.PatchWriteError) else {
                return XCTFail("expected .notMachO, got \(error)")
            }
        }
    }

    func testTruncatedBufferShorterThanMagicFailsWithTypedError() throws {
        let tiny = Data([0xcf, 0xfa]) // 2 bytes — shorter than a 4-byte magic.
        XCTAssertThrowsError(
            try writer.makePatchedData(originalData: tiny, patches: [:])
        ) { error in
            guard case .notMachO = (error as? MachOPatchWriter.PatchWriteError) else {
                return XCTFail("expected .notMachO, got \(error)")
            }
        }
    }

    // MARK: - Real binary (external ground truth)

    /// Patches a REAL thin Mach-O (an arm64e slice extracted from /bin/ls with `lipo`) at the
    /// first byte of its `__text` section, then independently re-reads the binary's segment
    /// table to confirm the writer wrote at the file offset the on-disk segment table says that
    /// VA maps to — and nowhere else. This guards the VA→file-offset projection against the real
    /// (not synthetic) segment layout, the "green != correct" check the synthetic fixture can't
    /// fully provide. Skips cleanly when `lipo`/`/bin/ls` are unavailable.
    func testRealThinBinaryPatchLandsAtSegmentDerivedFileOffset() throws {
        guard let thinURL = try Self.extractThinSlice() else {
            throw XCTSkip("Could not extract a thin Mach-O slice with lipo; skipping real-binary check.")
        }
        defer { try? FileManager.default.removeItem(at: thinURL) }

        let originalData = try Data(contentsOf: thinURL)
        // Independently parse the SAME bytes to recover the __text section's VA + file offset —
        // the ground truth the writer must match.
        let machO = try MachOParser().parse(originalData)
        let text = try XCTUnwrap(machO.executableTextSection, "no __text section")
        let targetVA = text.address
        let expectedFileOffset = Int(text.fileOffset)

        // Patch with the bitwise complement of the original 4 bytes so the patch is GUARANTEED to
        // differ at every byte (no coincidental match) regardless of the real binary's content.
        let originalAtText = Array(originalData[expectedFileOffset..<(expectedFileOffset + 4)])
        let patchBytes: [UInt8] = originalAtText.map { ~$0 }
        let patched = try writer.makePatchedData(
            originalData: originalData,
            patches: [targetVA: BytePatch(bytes: patchBytes)]
        )

        XCTAssertEqual(patched.count, originalData.count)
        // Patched bytes are exactly at the segment-derived file offset.
        XCTAssertEqual(Array(patched[expectedFileOffset..<(expectedFileOffset + 4)]), patchBytes)
        // Every other byte is identical.
        let original = Array(originalData)
        let patchedArray = Array(patched)
        var differingRanges = 0
        for index in 0..<original.count where patchedArray[index] != original[index] {
            XCTAssertTrue(
                (expectedFileOffset..<(expectedFileOffset + 4)).contains(index),
                "byte at offset \(index) changed but is outside the patch range"
            )
            differingRanges += 1
        }
        XCTAssertEqual(differingRanges, 4, "exactly the 4 patched bytes should differ")
    }

    /// Extracts a thin slice of `/bin/ls` to a temp file via `lipo -thin`, trying `arm64e` then
    /// `arm64` so the ground-truth check still runs on Apple-Silicon machines whose `/bin/ls`
    /// lacks an arm64e slice (and on Intel/CI). Returns nil only when the tool or input is
    /// genuinely unavailable, or no supported slice exists.
    private static func extractThinSlice() throws -> URL? {
        let source = "/bin/ls"
        guard FileManager.default.fileExists(atPath: source),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/lipo") else {
            return nil
        }
        for arch in ["arm64e", "arm64"] {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("macscope-patchwriter-\(UUID().uuidString)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
            process.arguments = [source, "-thin", arch, "-output", outputURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: outputURL.path) {
                return outputURL
            }
            try? FileManager.default.removeItem(at: outputURL)
        }
        return nil
    }

    // MARK: - Round-trip through the snapshot helper

    func testSnapshotAllPatchesFeedsTheWriterEndToEnd() throws {
        let fixture = MachOFixture.makeExecutable()
        // Build a snapshot carrying one byte patch, then drive the writer from `allPatches()`
        // exactly as the menu handler does.
        var override = AddressOverride()
        override.patch = BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])
        var snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            instructions: [],
            xrefs: [],
            hexBytes: Data()
        )
        snapshot.addressOverrides = [.primary(fixture.baseAddress): override]

        let patched = try writer.makePatchedData(
            originalData: fixture.bytes,
            patches: snapshot.patches(in: .primary)
        )
        XCTAssertEqual(
            Array(patched[fixture.codeOffset..<(fixture.codeOffset + 4)]),
            [0x1f, 0x20, 0x03, 0xd5]
        )
    }
}
