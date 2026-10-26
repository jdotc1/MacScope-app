import XCTest
@testable import MacScope

/// Crafted-input regression tests for the binary-parser security hardening (security audit
/// F2/F3 + the consumer-inventory finding F4). A hostile thin Mach-O whose segment table carries
/// adversarial 64-bit range fields must produce a TYPED error or nil — never a process trap, an
/// out-of-bounds read, or a section-count resource-amplification DoS.
///
/// Note: finding F1 (parser-level rejection of an out-of-slice segment file range) was DEFERRED —
/// the dyld shared-cache loader legitimately parses images with cache-relative `fileOffset`s, so a
/// `fileOffset <= data.count` check would reject valid input. The two concrete trap consumers are
/// instead hardened independently (F2 in the writer, F4 in `MachOFile.virtualAddress`), which is
/// why these fixtures parse successfully and then exercise the hardened consumers.
final class MachOParserSecurityTests: XCTestCase {

    /// A minimal thin arm64 Mach-O with ONE `LC_SEGMENT_64` (no sections, no other commands)
    /// whose vm/file range fields are caller-controlled — the lever for the hostile fixtures.
    private func craftedThinMachO(
        vmAddress: UInt64, vmSize: UInt64, fileOffset: UInt64, fileSize: UInt64,
        trailingBytes: Int = 64
    ) -> Data {
        let segmentCommandSize = 72
        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)                                       // magic (MH_MAGIC_64)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))  // cputype
        bytes.appendUInt32LE(0)                                                // cpusubtype
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)                   // filetype
        bytes.appendUInt32LE(1)                                                // ncmds
        bytes.appendUInt32LE(UInt32(segmentCommandSize))                       // sizeofcmds
        bytes.appendUInt32LE(0)                                                // flags
        bytes.appendUInt32LE(0)                                                // reserved
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__HOSTILE", length: 16)
        bytes.appendUInt64LE(vmAddress)
        bytes.appendUInt64LE(vmSize)
        bytes.appendUInt64LE(fileOffset)
        bytes.appendUInt64LE(fileSize)
        bytes.appendUInt32LE(5)                                                // maxprot
        bytes.appendUInt32LE(5)                                                // initprot
        bytes.appendUInt32LE(0)                                                // nsects
        bytes.appendUInt32LE(0)                                                // flags
        if trailingBytes > 0 { bytes.append(Data(count: trailingBytes)) }
        return bytes
    }

    // MARK: - LC_FUNCTION_STARTS has an independent large-image budget

    private let functionStartOptions = MachOParseOptions(recoverStringLiterals: false,
        recoverObjectiveCMetadata: false, recoverSwiftMetadata: false, parseCodeSignature: false)

    private func craftedFunctionStarts(entryCount: Int) -> Data {
        let payloadOffset = 32 + 72 + 16
        let fileSize = UInt64(payloadOffset + entryCount + 1)
        var bytes = craftedThinMachO(vmAddress: 0x1_0000_0000, vmSize: fileSize,
            fileOffset: 0, fileSize: fileSize, trailingBytes: 0)
        var commandHeader = Data()
        commandHeader.appendUInt32LE(2)
        commandHeader.appendUInt32LE(72 + 16)
        bytes.replaceSubrange(16..<24, with: commandHeader)
        var segmentName = Data()
        segmentName.appendFixedCString("__TEXT", length: 16)
        bytes.replaceSubrange(40..<56, with: segmentName)
        bytes.appendUInt32LE(MachOConstants.loadCommandFunctionStarts)
        bytes.appendUInt32LE(16)
        bytes.appendUInt32LE(UInt32(payloadOffset))
        bytes.appendUInt32LE(UInt32(entryCount + 1))
        // Bulk construction avoids a per-entry Swift encoding loop, including at the cap.
        bytes.append(Data(repeating: 1, count: entryCount))
        bytes.append(0)
        return bytes
    }

    func testFunctionStartsParsesSixtyThousandEntries() throws {
        let file = try MachOParser().parse(craftedFunctionStarts(entryCount: 60_000),
            options: functionStartOptions)
        XCTAssertEqual(file.functionStarts.count, 60_000)
        XCTAssertEqual(file.functionStarts.last?.address, 0x1_0000_EA60)
    }

    func testFunctionStartsInventoryAcceptsSixtyThousandEntries() throws {
        let parsed = try MachOParser().parseWithFixupCoverage(
            craftedFunctionStarts(entryCount: 60_000), options: functionStartOptions)
        XCTAssertTrue(parsed.coverage.functionStartsInventoryIsComplete,
            "layout: \(parsed.coverage.refusalReasons); starts: \(parsed.coverage.functionStartsInventoryRefusalReasons)")
        XCTAssertEqual(parsed.coverage.decodedFunctionStartCount, 60_000)
    }

    func testFunctionStartsCrossCheckReportsMissingStartAboveOldLimit() throws {
        let file = try MachOParser().parse(craftedFunctionStarts(entryCount: 60_000),
            options: functionStartOptions)
        XCTAssertEqual(file.functionStarts.count, 60_000)
        let findings = MachOUnwindFunctionStarts.crossCheck(functionStarts: file.functionStarts,
            unwindOffsets: [60_000, 60_001], imageBase: 0x1_0000_0000)
        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.kind, .unwindFunctionStartNotInFunctionStarts)
        XCTAssertEqual(finding.value, 60_001)
        XCTAssertEqual(finding.address, 0x1_0000_EA61)
    }

    func testFunctionStartsStillTruncatesAtRecoveryLimit() throws {
        let limit = MachORecoveryLimits.maximumFunctionStarts
        // One parse, no inventory rescan or expected million-element array.
        let file = try MachOParser().parse(craftedFunctionStarts(entryCount: limit + 1),
            options: functionStartOptions)
        XCTAssertEqual(file.functionStarts.count, limit)
        XCTAssertEqual(file.functionStarts.last?.offsetFromImageBase, UInt64(limit))
        XCTAssertEqual(file.functionStarts.last?.address, 0x1_0000_0000 + UInt64(limit))
    }

    // MARK: - F2: MachOPatchWriter must not trap on hostile segment arithmetic

    /// Variant A — `Int(fileOffset)` would trap when the mapped offset exceeds Int.max.
    func testPatchWriterFileOffsetAboveIntMaxYieldsTypedErrorNotTrap() throws {
        let data = craftedThinMachO(vmAddress: 0x1000, vmSize: 0x10, fileOffset: .max, fileSize: 0x10)
        let patches: [UInt64: BytePatch] = [0x1000: BytePatch(bytes: [0xAA])]
        XCTAssertThrowsError(try MachOPatchWriter().makePatchedData(originalData: data, patches: patches)) { error in
            guard case MachOPatchWriter.PatchWriteError.fileOffsetOutOfRange = error else {
                return XCTFail("expected fileOffsetOutOfRange, got \(error)")
            }
        }
    }

    /// Variant B — `segment.fileOffset + offsetIntoSegment` would trap on UInt64 overflow.
    func testPatchWriterWrappingFileOffsetAdditionYieldsTypedErrorNotTrap() throws {
        let data = craftedThinMachO(vmAddress: 0x1000, vmSize: 0x10, fileOffset: .max, fileSize: 0x10)
        let patches: [UInt64: BytePatch] = [0x1001: BytePatch(bytes: [0xAA])] // offsetIntoSegment = 1
        // The overflowed mapping returns nil; the writer re-classifies it as a typed error.
        XCTAssertThrowsError(try MachOPatchWriter().makePatchedData(originalData: data, patches: patches)) { error in
            XCTAssertTrue(error is MachOPatchWriter.PatchWriteError, "expected a typed PatchWriteError, got \(error)")
        }
    }

    /// Variant C — `segment.vmAddress + segment.fileSize` would trap during the containment search.
    func testPatchWriterWrappingSegmentVMRangeYieldsTypedErrorNotTrap() throws {
        let data = craftedThinMachO(vmAddress: .max - 3, vmSize: 8, fileOffset: 0, fileSize: 8)
        let patches: [UInt64: BytePatch] = [UInt64.max - 3: BytePatch(bytes: [0xAA])]
        // The wrapping VM range is skipped, so the address maps to no segment.
        XCTAssertThrowsError(try MachOPatchWriter().makePatchedData(originalData: data, patches: patches)) { error in
            guard case MachOPatchWriter.PatchWriteError.addressNotMapped = error else {
                return XCTFail("expected addressNotMapped, got \(error)")
            }
        }
    }

    /// A valid patch through the normal fixture still applies byte-exact (no regression).
    func testPatchWriterStillAppliesValidPatchByteExact() throws {
        let fixture = MachOFixture.makeExecutable()
        let patched = try MachOPatchWriter().makePatchedData(
            originalData: fixture.bytes,
            patches: [fixture.baseAddress: BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])]
        )
        XCTAssertEqual(patched.count, fixture.bytes.count)
        XCTAssertEqual(Array(patched[fixture.codeOffset..<(fixture.codeOffset + 4)]), [0x1f, 0x20, 0x03, 0xd5])
    }

    // MARK: - F4: MachOFile.virtualAddress(forFileOffset:) must not trap on hostile segments

    func testVirtualAddressForFileOffsetDoesNotTrapOnWrappingSegmentFileRange() throws {
        // fileOffset + fileSize wraps UInt64 → the read-side mapping must skip the segment, not trap.
        let data = craftedThinMachO(vmAddress: 0x4000, vmSize: 2, fileOffset: .max, fileSize: 2)
        let machO = try MachOParser().parse(data)
        XCTAssertNil(machO.virtualAddress(forFileOffset: 0), "a wrapping segment file range must map to nil, never trap")
        XCTAssertNil(machO.virtualAddress(forFileOffset: .max))
    }

    func testVirtualAddressForFileOffsetDoesNotTrapOnWrappingVMBase() throws {
        // A valid file range but vmAddress + delta wraps UInt64 → must return nil, not trap.
        let data = craftedThinMachO(vmAddress: .max, vmSize: 16, fileOffset: 0, fileSize: 16)
        let machO = try MachOParser().parse(data)
        XCTAssertNil(machO.virtualAddress(forFileOffset: 8), "a wrapping vmAddress mapping must return nil, never trap")
    }

    // MARK: - F3: section-count resource-amplification DoS is bounded

    func testParserRejectsOverBudgetSectionCountBeforeAllocating() {
        // A STRUCTURALLY-VALID LC_SEGMENT_64 (cmdsize admits every declared section record) that
        // declares ONE section over the budget. The structural size check therefore PASSES, so only
        // the per-segment section-count cap can reject it — isolating the new guard. (The previous
        // 10M/cmdsize=72 fixture was ALSO caught by the pre-existing structural check, so it did not
        // prove the cap; this asserts the cap's specific error.)
        let overBudget = 65_537   // MachORecoveryLimits.maximumSections (64Ki, file-private) + 1
        let sectionRecordsBytes = overBudget * 80
        let cmdsize = UInt32(72 + sectionRecordsBytes)
        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(1)                      // ncmds
        bytes.appendUInt32LE(cmdsize)                // sizeofcmds (admits all records → structural check passes)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(cmdsize)                // cmdsize
        bytes.appendFixedCString("__DOS", length: 16)
        bytes.appendUInt64LE(0)                      // vmaddr
        bytes.appendUInt64LE(0)                      // vmsize
        bytes.appendUInt64LE(0)                      // fileoff
        bytes.appendUInt64LE(0)                      // filesize
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(UInt32(overBudget))     // nsects — one over the cap
        bytes.appendUInt32LE(0)
        bytes.append(Data(count: sectionRecordsBytes)) // the declared section records (zeroed)
        XCTAssertThrowsError(try MachOParser().parse(bytes)) { error in
            guard let parserError = error as? MachOParserError,
                  case .invalidLoadCommand(_, let reason) = parserError,
                  reason.contains("section count exceeds") else {
                return XCTFail("expected the section-count cap to fire (not the structural check), got \(error)")
            }
        }
    }
}

/// Self-contained little-endian byte builders for the crafted fixtures above (the equivalents in
/// MachOImportTests are `fileprivate` to that file).
private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendUInt64LE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendFixedCString(_ string: String, length: Int) {
        var field = Array(string.utf8.prefix(length))
        if field.count < length { field.append(contentsOf: Array(repeating: 0, count: length - field.count)) }
        append(contentsOf: field.prefix(length))
    }
}
