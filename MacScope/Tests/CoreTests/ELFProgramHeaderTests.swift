import XCTest
@testable import MacScope

final class ELFProgramHeaderTests: XCTestCase {
    func testSectionlessELFProjectsOnlyFileBackedLoadAuthority() throws {
        let bytes = makeELF64Sectionless()
        let loaded = try ELFBinaryLoader.parse(
            bytes: bytes,
            name: "sectionless",
            path: "/tmp/sectionless"
        )

        XCTAssertEqual(loaded.sections.map(\.name), ["PT_LOAD[0]", "PT_LOAD[1]"])
        XCTAssertEqual(loaded.sections.map(\.fileSize), [1, 6])
        XCTAssertEqual(loaded.executableTextSection?.address, 0x400000)
        XCTAssertEqual(loaded.entryPointAddress, 0x400000)
        XCTAssertEqual(loaded.functionStarts, [0x400000])
        XCTAssertTrue(loaded.symbols.isEmpty)
        XCTAssertTrue(loaded.imports.isEmpty)
        XCTAssertTrue(loaded.indirectSymbols.isEmpty)
        XCTAssertTrue(loaded.exports.isEmpty)
        XCTAssertTrue(loaded.relocations.isEmpty)
        XCTAssertNil(loaded.metadata.uuid, "GNU build ID must never occupy the Mach-O UUID field")
        XCTAssertEqual(
            loaded.metadata.elfGNUBuildID,
            "00112233445566778899aabbccddeeff"
        )

        let catalog = try ELFProgramHeaderParser.parse(bytes)
        let facts = ELFProgramHeaderBinaryProjection.metadataFacts(catalog: catalog)
        XCTAssertEqual(facts.buildID, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(facts.platformName, "Linux")
        XCTAssertEqual(facts.minimumOSVersion, "6.1.2")
        XCTAssertFalse(facts.hasConflictingBuildIDs)
    }

    func testAnalysisNeverDecodesPTLoadZeroFillOrFollowingFileBytes() throws {
        let bytes = makeELF64Sectionless()
        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: "bounded", path: "/tmp/bounded")
        let section = try XCTUnwrap(loaded.executableTextSection)

        XCTAssertEqual(section.size, 0x100)
        XCTAssertEqual(section.fileSize, 1)
        XCTAssertNotNil(AnalysisEngine.fileBackedBytes(
            in: loaded,
            section: section,
            relativeOffset: 0,
            count: 1
        ))
        XCTAssertNil(AnalysisEngine.fileBackedBytes(
            in: loaded,
            section: section,
            relativeOffset: 1,
            count: 1
        ))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeSectionlessELF-\(UUID().uuidString)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try AnalysisEngine().analyze(url: url)
        XCTAssertEqual(snapshot.instructions.map(\.address), [0x400000])
        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "ret")
    }

    func testEntryMustBeInsideFileBackedExecutableLoad() throws {
        var nonExecutable = makeELF64Sectionless()
        nonExecutable.elfReplaceU32(at: 64 + 4, with: 4)
        XCTAssertNil(try ELFBinaryLoader.parse(
            bytes: nonExecutable,
            name: "nonexec",
            path: "/tmp/nonexec"
        ).entryPointAddress)

        var zeroFillTail = makeELF64Sectionless()
        zeroFillTail.elfReplaceU64(at: 24, with: 0x400040)
        let loaded = try ELFBinaryLoader.parse(
            bytes: zeroFillTail,
            name: "tail",
            path: "/tmp/tail"
        )
        XCTAssertNil(loaded.entryPointAddress)
        XCTAssertTrue(loaded.functionStarts.isEmpty)
    }

    func testSectionedELFRemainsPrimaryWhenOptionalProgramHeadersAreMalformed() throws {
        var bytes = makeELF64Sectioned()
        bytes.elfReplaceU16(at: 54, with: 1) // invalid e_phentsize for optional enrichment

        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: "sectioned", path: "/tmp/sectioned")
        XCTAssertEqual(loaded.sections.map(\.name), ["", ".text", ".shstrtab"])
        XCTAssertEqual(loaded.executableTextSection?.address, 0x400000)
        XCTAssertEqual(loaded.entryPointAddress, 0x400000)
        XCTAssertNil(loaded.metadata.elfGNUBuildID)
    }

    func testSectionedELFEnrichesMetadataFromValidGNUBuildIDNote() throws {
        let loaded = try ELFBinaryLoader.parse(
            bytes: makeELF64Sectioned(),
            name: "sectioned-build-id",
            path: "/tmp/sectioned-build-id"
        )

        XCTAssertEqual(loaded.sections.map(\.name), ["", ".text", ".shstrtab"])
        XCTAssertNil(loaded.metadata.uuid, "GNU build ID must never occupy the Mach-O UUID field")
        XCTAssertEqual(
            loaded.metadata.elfGNUBuildID,
            "00112233445566778899aabbccddeeff"
        )
    }

    func testProgramHeaderTableAndRangeFailuresAreTyped() {
        var declaredHeaderPastEOF = makeELF64Sectionless()
        declaredHeaderPastEOF.elfReplaceU16(at: 52, with: UInt16(declaredHeaderPastEOF.count + 1))
        assertProgramHeaderFailure(declaredHeaderPastEOF, .truncated("declared ELF header"))

        var overlapsDeclaredHeader = makeELF64Sectionless()
        overlapsDeclaredHeader.elfReplaceU16(at: 52, with: 128)
        assertProgramHeaderFailure(
            overlapsDeclaredHeader,
            .malformed("program-header table overlaps the ELF header")
        )

        var zeroOffset = makeELF64Sectionless()
        zeroOffset.elfReplaceU64(at: 32, with: 0)
        assertProgramHeaderFailure(zeroOffset, .malformed("nonzero e_phnum with zero e_phoff"))

        var undersizedEntry = makeELF64Sectionless()
        undersizedEntry.elfReplaceU16(at: 54, with: 55)
        assertProgramHeaderFailure(undersizedEntry, .malformed("e_phentsize is smaller than the ABI record"))

        var overlapsHeader = makeELF64Sectionless()
        overlapsHeader.elfReplaceU64(at: 32, with: 8)
        assertProgramHeaderFailure(overlapsHeader, .malformed("program-header table overlaps the ELF header"))

        let truncated = Data(makeELF64Sectionless().prefix(80))
        assertProgramHeaderFailure(truncated, .truncated("program-header table"))

        var extendedCount = makeELF64Sectionless()
        extendedCount.elfReplaceU16(at: 56, with: 0xffff)
        assertProgramHeaderFailure(extendedCount, .unsupported("extended e_phnum (PN_XNUM)"))

        var excessiveCount = makeELF64Sectionless()
        excessiveCount.elfReplaceU16(
            at: 56,
            with: UInt16(ELFProgramHeaderParser.Limits.production.maximumProgramHeaders + 1)
        )
        assertProgramHeaderFailure(excessiveCount, .malformed("program-header count exceeds bound"))
    }

    func testLoadSegmentArithmeticAlignmentAndOverlapFailClosed() {
        var filesz = makeELF64Sectionless()
        filesz.elfReplaceU64(at: 64 + 32, with: 0x101)
        filesz.elfReplaceU64(at: 64 + 40, with: 0x100)
        assertProgramHeaderFailure(filesz, .malformed("PT_LOAD p_filesz exceeds p_memsz"))

        var virtualOverflow = makeELF64Sectionless()
        virtualOverflow.elfReplaceU64(at: 64 + 16, with: UInt64.max - 7)
        virtualOverflow.elfReplaceU64(at: 64 + 40, with: 16)
        virtualOverflow.elfReplaceU64(at: 64 + 48, with: 1)
        assertProgramHeaderFailure(virtualOverflow, .malformed("program-header virtual range overflow"))

        var badPower = makeELF64Sectionless()
        badPower.elfReplaceU64(at: 64 + 48, with: 3)
        assertProgramHeaderFailure(badPower, .malformed("p_align is not a power of two"))

        var badCongruence = makeELF64Sectionless()
        badCongruence.elfReplaceU64(at: 64 + 8, with: 0x1001)
        assertProgramHeaderFailure(badCongruence, .malformed("PT_LOAD offset/address alignment mismatch"))

        var overlap = makeELF64Sectionless()
        overlap.elfReplaceU64(at: 64 + 56 + 16, with: 0x400080)
        // Keep the mutated segment's file range inside the fixture and congruent with
        // p_vaddr modulo p_align, so this mutation reaches the virtual-overlap guard.
        overlap.elfReplaceU64(at: 64 + 56 + 8, with: 0x1080)
        assertProgramHeaderFailure(overlap, .unsupported("overlapping PT_LOAD virtual ranges"))
    }

    func testNoteParserUsesAggregateBudgetsAndCanonicalNames() throws {
        let bytes = makeELF64Sectionless()
        let strict = ELFProgramHeaderParser.Limits(
            maximumProgramHeaders: 16,
            maximumProgramHeaderTableBytes: 4_096,
            maximumNotes: 1,
            maximumNoteNameBytes: 32,
            maximumSingleNotePayloadBytes: 64,
            maximumTotalNotePayloadBytes: 64,
            maximumTotalNoteRegionBytes: 4_096
        )
        XCTAssertThrowsError(try ELFProgramHeaderParser.parse(bytes, limits: strict)) { error in
            XCTAssertEqual(error as? ELFProgramHeaderError, .malformed("note count exceeds bound"))
        }

        var nonCanonical = bytes
        let noteOffset = 64 + 56 * 3
        nonCanonical.elfReplaceU32(at: noteOffset, with: 8)
        nonCanonical.replaceSubrange(
            (noteOffset + 12)..<(noteOffset + 20),
            with: Array("GNU\0EVIL".utf8)
        )
        XCTAssertThrowsError(try ELFProgramHeaderParser.parse(nonCanonical)) { error in
            XCTAssertEqual(error as? ELFProgramHeaderError, .malformed("ELF note name is not canonical UTF-8"))
        }
    }

    func testRepeatedNoteRegionsConsumeAggregateBudget() {
        let bytes = makeELF64Sectionless(repeatedNoteHeaders: 3)
        let strict = ELFProgramHeaderParser.Limits(
            maximumProgramHeaders: 16,
            maximumProgramHeaderTableBytes: 4_096,
            maximumNotes: 32,
            maximumNoteNameBytes: 1_024,
            maximumSingleNotePayloadBytes: 1_024,
            maximumTotalNotePayloadBytes: 4_096,
            maximumTotalNoteRegionBytes: 100
        )
        XCTAssertThrowsError(try ELFProgramHeaderParser.parse(bytes, limits: strict)) { error in
            XCTAssertEqual(error as? ELFProgramHeaderError, .malformed("aggregate PT_NOTE bytes exceed bound"))
        }
    }

    func testConflictingGNUBuildIDsNeverChooseBySourceOrder() throws {
        let first = try ELFProgramHeaderParser.parse(makeELF64Sectionless(conflictingBuildID: false))
        let conflicting = try ELFProgramHeaderParser.parse(makeELF64Sectionless(conflictingBuildID: true))
        let baselineFacts = ELFProgramHeaderBinaryProjection.metadataFacts(catalog: first)
        let conflictFacts = ELFProgramHeaderBinaryProjection.metadataFacts(catalog: conflicting)

        XCTAssertEqual(baselineFacts.buildID, "00112233445566778899aabbccddeeff")
        XCTAssertNil(conflictFacts.buildID)
        XCTAssertTrue(conflictFacts.hasConflictingBuildIDs)
        XCTAssertNil(
            try ELFProgramHeaderBinaryProjection.makeLoadedBinary(
                catalog: conflicting,
                bytes: makeELF64Sectionless(conflictingBuildID: true),
                name: "conflict",
                path: "/tmp/conflict"
            ).metadata.elfGNUBuildID,
            "conflicting build IDs must not select a source-order winner"
        )
    }

    func testStringProjectionEnforcesAggregateInputAndOutputBudgets() throws {
        let bytes = makeELF64Sectionless()
        let catalog = try ELFProgramHeaderParser.parse(bytes)
        XCTAssertThrowsError(try ELFProgramHeaderBinaryProjection.stringLiterals(
            catalog: catalog,
            bytes: bytes,
            limits: .init(
                maximumTotalScannedBytes: 5,
                maximumStringCount: 16,
                maximumTotalStringBytes: 128,
                maximumStringBytes: 64
            )
        )) { error in
            XCTAssertEqual(error as? ELFProgramHeaderError, .malformed("aggregate PT_LOAD string scan exceeds bound"))
        }

        XCTAssertThrowsError(try ELFProgramHeaderBinaryProjection.stringLiterals(
            catalog: catalog,
            bytes: bytes,
            limits: .init(
                maximumTotalScannedBytes: 64,
                maximumStringCount: 0,
                maximumTotalStringBytes: 128,
                maximumStringBytes: 64
            )
        )) { error in
            XCTAssertEqual(error as? ELFProgramHeaderError, .malformed("string literal count exceeds bound"))
        }
    }

    func testELF32BigEndianProgramHeaderDecodes() throws {
        let catalog = try ELFProgramHeaderParser.parse(makeELF32BigEndian())
        XCTAssertFalse(catalog.is64Bit)
        XCTAssertTrue(catalog.isBigEndian)
        XCTAssertEqual(catalog.machine, 40)
        XCTAssertEqual(catalog.entryPoint, 0x1000)
        XCTAssertEqual(catalog.records.first?.virtualAddress, 0x1000)
        XCTAssertEqual(catalog.records.first?.fileSize, 4)
    }

    private func assertProgramHeaderFailure(
        _ bytes: Data,
        _ expected: ELFProgramHeaderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ELFProgramHeaderParser.parse(bytes), file: file, line: line) { error in
            XCTAssertEqual(error as? ELFProgramHeaderError, expected, file: file, line: line)
        }
    }

    private func makeELF64Sectionless(
        repeatedNoteHeaders: Int = 1,
        conflictingBuildID: Bool = false
    ) -> Data {
        let phoff = 64
        let noteHeaderCount = repeatedNoteHeaders
        let phnum = 2 + noteHeaderCount
        let noteOffset = phoff + 56 * phnum
        let codeOffset = 0x1000
        let dataOffset = 0x2000
        var data = Data(repeating: 0, count: dataOffset + 64)
        writeELF64Header(&data, phoff: phoff, phnum: phnum, sectionOffset: 0, sectionCount: 0, shstrIndex: 0)

        appendProgramHeader64(
            &data, at: phoff, type: 1, flags: 5, offset: UInt64(codeOffset),
            address: 0x400000, fileSize: 1, memorySize: 0x100, alignment: 0x1000
        )
        appendProgramHeader64(
            &data, at: phoff + 56, type: 1, flags: 4, offset: UInt64(dataOffset),
            address: 0x402000, fileSize: 6, memorySize: 0x80, alignment: 0x1000
        )

        var notes = Data()
        appendNote(&notes, name: Array("GNU\0".utf8), type: 3,
                   descriptor: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        if conflictingBuildID {
            appendNote(&notes, name: Array("GNU\0".utf8), type: 3,
                       descriptor: [0xff, 0xee, 0xdd, 0xcc])
        }
        var abi = Data()
        abi.elfAppendU32(0); abi.elfAppendU32(6); abi.elfAppendU32(1); abi.elfAppendU32(2)
        appendNote(&notes, name: Array("GNU\0".utf8), type: 1, descriptor: Array(abi))
        data.replaceSubrange(noteOffset..<(noteOffset + notes.count), with: notes)
        for index in 0..<noteHeaderCount {
            appendProgramHeader64(
                &data, at: phoff + 56 * (2 + index), type: 4, flags: 4,
                offset: UInt64(noteOffset), address: 0,
                fileSize: UInt64(notes.count), memorySize: UInt64(notes.count), alignment: 4
            )
        }
        data[codeOffset] = 0xc3 // x86_64 ret; bytes after p_filesz are not code authority.
        data.replaceSubrange(dataOffset..<(dataOffset + 6), with: Array("hello\0".utf8))
        return data
    }

    private func makeELF64Sectioned() -> Data {
        let phoff = 64
        let codeOffset = 0x1000
        let namesOffset = 0x2000
        let noteOffset = 0x2020
        let sectionOffset = 0x2100
        let names = Array("\0.text\0.shstrtab\0".utf8)
        var notes = Data()
        appendNote(
            &notes,
            name: Array("GNU\0".utf8),
            type: 3,
            descriptor: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                         0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        )
        var data = Data(repeating: 0, count: sectionOffset + 64 * 3)
        writeELF64Header(
            &data,
            phoff: phoff,
            phnum: 2,
            sectionOffset: sectionOffset,
            sectionCount: 3,
            shstrIndex: 2
        )
        appendProgramHeader64(
            &data, at: phoff, type: 1, flags: 5, offset: UInt64(codeOffset),
            address: 0x400000, fileSize: 1, memorySize: 1, alignment: 0x1000
        )
        appendProgramHeader64(
            &data, at: phoff + 56, type: 4, flags: 4, offset: UInt64(noteOffset),
            address: 0, fileSize: UInt64(notes.count), memorySize: UInt64(notes.count), alignment: 4
        )
        data[codeOffset] = 0xc3
        data.replaceSubrange(namesOffset..<(namesOffset + names.count), with: names)
        data.replaceSubrange(noteOffset..<(noteOffset + notes.count), with: notes)
        appendSectionHeader64(
            &data, at: sectionOffset + 64, name: 1, type: 1, flags: 4,
            address: 0x400000, fileOffset: UInt64(codeOffset), size: 1
        )
        appendSectionHeader64(
            &data, at: sectionOffset + 128, name: 7, type: 3, flags: 0,
            address: 0, fileOffset: UInt64(namesOffset), size: UInt64(names.count)
        )
        return data
    }

    private func writeELF64Header(
        _ data: inout Data,
        phoff: Int,
        phnum: Int,
        sectionOffset: Int,
        sectionCount: Int,
        shstrIndex: Int
    ) {
        data.replaceSubrange(0..<16, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8))
        data.elfReplaceU16(at: 16, with: 2)
        data.elfReplaceU16(at: 18, with: 62)
        data.elfReplaceU32(at: 20, with: 1)
        data.elfReplaceU64(at: 24, with: 0x400000)
        data.elfReplaceU64(at: 32, with: UInt64(phoff))
        data.elfReplaceU64(at: 40, with: UInt64(sectionOffset))
        data.elfReplaceU16(at: 52, with: 64)
        data.elfReplaceU16(at: 54, with: 56)
        data.elfReplaceU16(at: 56, with: UInt16(phnum))
        data.elfReplaceU16(at: 58, with: 64)
        data.elfReplaceU16(at: 60, with: UInt16(sectionCount))
        data.elfReplaceU16(at: 62, with: UInt16(shstrIndex))
    }

    private func appendProgramHeader64(
        _ data: inout Data,
        at offset: Int,
        type: UInt32,
        flags: UInt32,
        offset fileOffset: UInt64,
        address: UInt64,
        fileSize: UInt64,
        memorySize: UInt64,
        alignment: UInt64
    ) {
        data.elfReplaceU32(at: offset, with: type)
        data.elfReplaceU32(at: offset + 4, with: flags)
        data.elfReplaceU64(at: offset + 8, with: fileOffset)
        data.elfReplaceU64(at: offset + 16, with: address)
        data.elfReplaceU64(at: offset + 24, with: address)
        data.elfReplaceU64(at: offset + 32, with: fileSize)
        data.elfReplaceU64(at: offset + 40, with: memorySize)
        data.elfReplaceU64(at: offset + 48, with: alignment)
    }

    private func appendSectionHeader64(
        _ data: inout Data,
        at offset: Int,
        name: UInt32,
        type: UInt32,
        flags: UInt64,
        address: UInt64,
        fileOffset: UInt64,
        size: UInt64
    ) {
        data.elfReplaceU32(at: offset, with: name)
        data.elfReplaceU32(at: offset + 4, with: type)
        data.elfReplaceU64(at: offset + 8, with: flags)
        data.elfReplaceU64(at: offset + 16, with: address)
        data.elfReplaceU64(at: offset + 24, with: fileOffset)
        data.elfReplaceU64(at: offset + 32, with: size)
        data.elfReplaceU64(at: offset + 56, with: 1)
    }

    private func appendNote(
        _ data: inout Data,
        name: [UInt8],
        type: UInt32,
        descriptor: [UInt8]
    ) {
        data.elfAppendU32(UInt32(name.count))
        data.elfAppendU32(UInt32(descriptor.count))
        data.elfAppendU32(type)
        data.append(contentsOf: name)
        while !data.count.isMultiple(of: 4) { data.append(0) }
        data.append(contentsOf: descriptor)
        while !data.count.isMultiple(of: 4) { data.append(0) }
    }

    private func makeELF32BigEndian() -> Data {
        var data = Data(repeating: 0, count: 88)
        data.replaceSubrange(0..<16, with: [0x7f, 0x45, 0x4c, 0x46, 1, 2, 1, 0] + [UInt8](repeating: 0, count: 8))
        data.elfReplaceU16BE(at: 16, with: 2)
        data.elfReplaceU16BE(at: 18, with: 40)
        data.elfReplaceU32BE(at: 20, with: 1)
        data.elfReplaceU32BE(at: 24, with: 0x1000)
        data.elfReplaceU32BE(at: 28, with: 52)
        data.elfReplaceU32BE(at: 32, with: 0)
        data.elfReplaceU16BE(at: 40, with: 52)
        data.elfReplaceU16BE(at: 42, with: 32)
        data.elfReplaceU16BE(at: 44, with: 1)
        data.elfReplaceU16BE(at: 46, with: 0)
        data.elfReplaceU16BE(at: 48, with: 0)
        data.elfReplaceU16BE(at: 50, with: 0)
        data.elfReplaceU32BE(at: 52, with: 1)
        data.elfReplaceU32BE(at: 56, with: 84)
        data.elfReplaceU32BE(at: 60, with: 0x1000)
        data.elfReplaceU32BE(at: 64, with: 0x1000)
        data.elfReplaceU32BE(at: 68, with: 4)
        data.elfReplaceU32BE(at: 72, with: 4)
        data.elfReplaceU32BE(at: 76, with: 5)
        data.elfReplaceU32BE(at: 80, with: 4)
        return data
    }
}

private extension Data {
    mutating func elfReplaceU16(at offset: Int, with value: UInt16) {
        replaceSubrange(offset..<(offset + 2), with: [UInt8(value & 0xff), UInt8(value >> 8)])
    }

    mutating func elfReplaceU32(at offset: Int, with value: UInt32) {
        replaceSubrange(offset..<(offset + 4), with: (0..<4).map {
            UInt8(truncatingIfNeeded: value >> (8 * $0))
        })
    }

    mutating func elfReplaceU64(at offset: Int, with value: UInt64) {
        replaceSubrange(offset..<(offset + 8), with: (0..<8).map {
            UInt8(truncatingIfNeeded: value >> (8 * $0))
        })
    }

    mutating func elfAppendU32(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    mutating func elfReplaceU16BE(at offset: Int, with value: UInt16) {
        replaceSubrange(offset..<(offset + 2), with: [UInt8(value >> 8), UInt8(value & 0xff)])
    }

    mutating func elfReplaceU32BE(at offset: Int, with value: UInt32) {
        replaceSubrange(offset..<(offset + 4), with: (0..<4).reversed().map {
            UInt8(truncatingIfNeeded: value >> (8 * $0))
        })
    }
}
