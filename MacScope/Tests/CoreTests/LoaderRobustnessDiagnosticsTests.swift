import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// HS-4 / HS-5 (string-analysis pass L1–L3, M1): every chained-fixup case the walker does not
/// handle, and ObjC metadata from a shared-cache extraction, must surface as a typed per-image
/// finding instead of a silently misread pointer, garbage names, or empty results.
final class LoaderRobustnessDiagnosticsTests: XCTestCase {
    // Offsets inside the MachOFixture chained-fixups payload (see makeExecutableWithChainedFixupChain).
    private let fixupsVersionOffset = 0
    private let symbolsFormatOffset = 24
    private let pageStartOffset = 66

    private func findings(_ fixture: MachOFixture) throws -> [MachOLoaderFinding] {
        try MachOParser().parse(fixture.bytes).loaderFindings
    }

    private func writeUInt16LE(_ bytes: inout Data, at offset: Int, value: UInt16) {
        bytes[bytes.startIndex + offset] = UInt8(value & 0xff)
        bytes[bytes.startIndex + offset + 1] = UInt8(value >> 8)
    }

    private func writeUInt32LE(_ bytes: inout Data, at offset: Int, value: UInt32) {
        for i in 0..<4 { bytes[bytes.startIndex + offset + i] = UInt8((value >> (8 * i)) & 0xff) }
    }

    private func readUInt32LE(_ bytes: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { value, i in
            value | (UInt32(bytes[bytes.startIndex + offset + i]) << (8 * i))
        }
    }

    // MARK: - Baseline: supported formats stay silent and unchanged

    func testSupportedChainsProduceNoFindings() throws {
        for format: UInt16 in [2, 6, 1, 9, 12] {
            let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: format)
            let machO = try MachOParser().parse(fixture.bytes)
            XCTAssertEqual(machO.loaderFindings, [], "format \(format)")
            XCTAssertEqual(machO.dyldChainedFixups?.fixups.count, 2, "format \(format)")
        }
    }

    // MARK: - HS-4 chained fixups

    func testUnknownFixupsVersionIsRefused() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, payload in
            self.writeUInt32LE(&bytes, at: payload + self.fixupsVersionOffset, value: 1)
        }
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsUnknownVersion])
        XCTAssertEqual(machO.loaderFindings.first?.value, 1)
        XCTAssertEqual(machO.dyldChainedFixups?.fixups, [])
    }

    func testUnhandledPointerFormatIsNamedPerSegment() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: 3) // DYLD_CHAINED_PTR_32
        let machO = try MachOParser().parse(fixture.bytes)
        let finding = try XCTUnwrap(machO.loaderFindings.first)
        XCTAssertEqual(machO.loaderFindings.count, 1)
        XCTAssertEqual(finding.kind, .chainedFixupsUnhandledPointerFormat)
        XCTAssertEqual(finding.value, 3)
        XCTAssertEqual(finding.address, fixture.chainedBindAddress) // the __DATA segment base
        XCTAssertTrue(finding.message.contains("DYLD_CHAINED_PTR_32"))
        XCTAssertEqual(machO.dyldChainedFixups?.fixups, [])
    }

    func testUnhandledImportFormatIsRefused() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(importsFormat: 7)
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsUnhandledImportFormat])
        XCTAssertEqual(machO.loaderFindings.first?.value, 7)
        XCTAssertEqual(machO.dyldChainedFixups?.imports, [])
    }

    func testOutOfRangeChainedImportNameIsRefused() throws {
        // CP16 mutation-000008: name_offset escapes the chained payload.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, payload in
            let importsOffset = Int(self.readUInt32LE(bytes, at: payload + 8))
            self.writeUInt32LE(&bytes, at: payload + importsOffset,
                               value: (UInt32(0x7f_ffff) << 9) | 1)
        }
        let machO = try MachOParser().parse(fixture.bytes)
        let chained = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsImportNameOutOfRange])
        XCTAssertEqual(chained.imports, [])
        XCTAssertNil(chained.fixups.first(where: \.isBind)?.boundSymbolName)
    }

    func testUnterminatedChainedImportNameIsRefused() throws {
        // Point the import at the final symbol-pool string, then replace its only trailing NUL.
        // A bounded decoder must not turn the payload suffix into an import name.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, payload in
            let symbolsStart = payload + Int(self.readUInt32LE(bytes, at: payload + 12))
            let finalName = Array("_ordinal65536".utf8)
            let nameStart = bytes.count - finalName.count - 1
            XCTAssertEqual(Array(bytes[nameStart..<(bytes.count - 1)]), finalName)
            XCTAssertEqual(bytes[bytes.count - 1], 0)
            let nameOffset = UInt32(nameStart - symbolsStart)
            let importsOffset = Int(self.readUInt32LE(bytes, at: payload + 8))
            self.writeUInt32LE(&bytes, at: payload + importsOffset,
                               value: (nameOffset << 9) | 1)
            bytes[bytes.count - 1] = 0x58
        }
        let machO = try MachOParser().parse(fixture.bytes)
        let chained = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsImportNameUnterminated])
        XCTAssertEqual(chained.imports, [])
        XCTAssertNil(chained.fixups.first(where: \.isBind)?.boundSymbolName)
    }

    func testChainedImportAddend64ReservedBitsAreRefused() throws {
        // CP16 mutation-000368: reserved bits 17...31 cannot become import authority.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(
            importsFormat: MachOConstants.dyldChainedImportAddend64
        ) { bytes, payload in
            let importsOffset = Int(self.readUInt32LE(bytes, at: payload + 8))
            MachOFixture.writeUInt64LE(&bytes, at: payload + importsOffset,
                                       value: 1 | (UInt64(1) << 17) | (UInt64(1) << 32))
        }
        let machO = try MachOParser().parse(fixture.bytes)
        let chained = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsImportReservedBits])
        XCTAssertEqual(chained.imports, [])
        XCTAssertNil(chained.fixups.first(where: \.isBind)?.boundSymbolName)
    }

    func testCompressedImportNamesAreRefusedNotDecodedAsGarbage() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, payload in
            self.writeUInt32LE(&bytes, at: payload + self.symbolsFormatOffset,
                               value: MachOConstants.dyldChainedSymbolsZlibCompressed)
        }
        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsCompressedImportNames])
        XCTAssertTrue(machO.loaderFindings[0].message.contains("zlib-compressed import names"))
        XCTAssertTrue(machO.loaderFindings[0].message.contains("symbols_format 1"))
        XCTAssertEqual(fixups.imports, [])
        // The bind is still located but carries no (garbage) name.
        let bind = try XCTUnwrap(fixups.fixups.first(where: \.isBind))
        XCTAssertNil(bind.boundSymbolName)
    }

    /// A START_MULTI index past the starts_in_segment (no overflow list) is refused, never read as
    /// an offset.
    func testStartMultiPageIsRefusedNotWalkedAsOffset() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, payload in
            self.writeUInt16LE(&bytes, at: payload + self.pageStartOffset, value: 0x8001)
        }
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsStartMultiUnhandled])
        XCTAssertEqual(machO.loaderFindings.first?.value, 0x8001)
        XCTAssertTrue(machO.loaderFindings.first?.message.contains("Malformed DYLD_CHAINED_PTR_START_MULTI") == true)
        XCTAssertEqual(machO.dyldChainedFixups?.fixups, [])
    }

    // MARK: - HS-4b START_MULTI pages

    /// page_start[0] = START_MULTI | 1 -> chain_starts at page_start[1...]: {0, 8 | START_LAST}.
    /// The bind entry ends its own chain (next = 0), so each fixup is reached only through its
    /// own listed start, as dyld walks it.
    private func startMultiFixture(overflow: [UInt16], pageStart: UInt16 = 0x8001) -> MachOFixture {
        MachOFixture.makeExecutableWithChainedFixupChain(pageStartOverflow: overflow) { bytes, payload in
            self.writeUInt16LE(&bytes, at: payload + self.pageStartOffset, value: pageStart)
            let offset = MachOFixture.chainDataStart(in: bytes)
            MachOFixture.writeUInt64LE(&bytes, at: offset, value: UInt64(1) << 63) // BIND ordinal 0, next 0
        }
    }

    func testStartMultiPageWalksEveryListedStart() throws {
        let fixture = startMultiFixture(overflow: [0x0000, 0x8008])
        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(machO.loaderFindings, [])
        XCTAssertEqual(fixups.fixups.map(\.address), [fixture.chainedBindAddress, fixture.chainedRebaseAddress])
        XCTAssertEqual(fixups.fixups.first(where: \.isBind)?.boundSymbolName, "_puts")
        XCTAssertEqual(fixups.rebaseCount, 1)
    }

    func testStartMultiListWithoutStartLastIsRefused() throws {
        let fixture = startMultiFixture(overflow: [0x0000, 0x0008])
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsStartMultiUnhandled])
        XCTAssertEqual(machO.dyldChainedFixups?.fixups, [])
    }

    func testStartMultiIndexIntoPerPageStartsIsRefused() throws {
        let fixture = startMultiFixture(overflow: [0x0000, 0x8008], pageStart: 0x8000)
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsStartMultiUnhandled])
        XCTAssertEqual(machO.loaderFindings.first?.value, 0x8000)
        XCTAssertEqual(machO.dyldChainedFixups?.fixups, [])
    }

    func testChainDeltaLeavingTheSegmentEndsChainWithFinding() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, _ in
            let offset = MachOFixture.chainDataStart(in: bytes)
            // BIND with next = 0x100 (stride 4 => +1024 bytes): far past the 16-byte segment.
            MachOFixture.writeUInt64LE(&bytes, at: offset, value: (UInt64(1) << 63) | (UInt64(0x100) << 51))
        }
        let machO = try MachOParser().parse(fixture.bytes)
        let fixups = try XCTUnwrap(machO.dyldChainedFixups)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsChainDeltaMismatch])
        XCTAssertEqual(machO.loaderFindings.first?.value, 0x400)
        // The valid entry before the bad delta is kept; nothing is read past it.
        XCTAssertEqual(fixups.fixups.map(\.address), [fixture.chainedBindAddress])
    }

    func testUnrepresentableRebaseIsNamed() throws {
        // 64_OFFSET rebase whose base + target + high8 does not fit 64 bits.
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(
            imageBase: 0xffff_fff0_0000_0000,
            pointerFormat: 6,
            rebaseRawOverride: 0xf_ffff_ffff | (UInt64(0xff) << 36)
        )
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsUnhandledRebase])
        XCTAssertEqual(machO.loaderFindings.first?.address, fixture.chainedRebaseAddress)
        XCTAssertEqual(machO.dyldChainedFixups?.rebaseCount, 0)
    }

    func testBindOrdinalOutOfRangeIsNamed() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain { bytes, _ in
            let offset = MachOFixture.chainDataStart(in: bytes)
            let raw = MachOFixture.readUInt64LE(bytes, at: offset)
            MachOFixture.writeUInt64LE(&bytes, at: offset, value: raw | 7)
        }
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.chainedFixupsBindOrdinalOutOfRange])
        XCTAssertEqual(machO.loaderFindings.first?.value, 7)
        XCTAssertEqual(machO.loaderFindings.first?.address, fixture.chainedBindAddress)
    }

    /// End to end: a typed finding reaches the per-image Problems-panel path with its own kind.
    func testFindingFlowsThroughLoaderIntoDiagnosticsCollector() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(pointerFormat: 3)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ChainedPtr32")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try fixture.bytes.write(to: url)

        let loaded = try MachOBinaryLoader().load(at: url)
        XCTAssertEqual(loaded.loaderFindings.map(\.code), ["chainedFixupsUnhandledPointerFormat"])
        let diagnostics = AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            loaderFindings: loaded.loaderFindings
        ))
        let row = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(row.kind, .unsupportedLoaderStructure)
        XCTAssertEqual(row.provenance, .loader)
        XCTAssertEqual(row.severity, .warning)
        XCTAssertTrue(row.message.contains("DYLD_CHAINED_PTR_32"), row.message)
    }

    // MARK: - HS-5 ObjC metadata from a dyld-shared-cache extraction

    func testObjCReferencesOutsideImageAreDiagnosedAsSharedCacheExtraction() throws {
        // The selref rebase targets 0x7_0000_0000, far outside this small image (as a selector
        // in the cache's shared pool would be after manual extraction).
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(
            rebaseRawOverride: 0x7_0000_0000,
            objectiveCReferenceSection: true
        )
        let machO = try MachOParser().parse(fixture.bytes)
        let finding = try XCTUnwrap(machO.loaderFindings.first)
        XCTAssertEqual(machO.loaderFindings.map(\.kind), [.objcMetadataFromSharedCacheExtraction])
        XCTAssertEqual(finding.address, fixture.chainedRebaseAddress)
        XCTAssertTrue(finding.message.contains("extracted from the dyld shared cache"), finding.message)

        let row = try XCTUnwrap(AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            loaderFindings: machO.loaderFindings.map(MachOBinaryLoader.loaderFinding)
        )).first)
        XCTAssertEqual(row.kind, .objcMetadataUnavailable)
    }

    func testInImageObjCReferencesAreNotDiagnosed() throws {
        let fixture = MachOFixture.makeExecutableWithChainedFixupChain(objectiveCReferenceSection: true)
        let machO = try MachOParser().parse(fixture.bytes)
        XCTAssertFalse(machO.objectiveCMetadata.selectorReferences.isEmpty)
        XCTAssertEqual(machO.loaderFindings, [])
    }

    // MARK: - HS-5b one real image extracted from the macOS dyld shared cache (opt-in)

    /// Opt-in: absolute path to the HS-5b extracted image (docs/testing/DYLD_CACHE_EXTRACTED_FIXTURE.md).
    /// Through xcodebuild / Scripts/dev_loop.sh pass it as `TEST_RUNNER_MACSCOPE_DYLD_CACHE_EXTRACTED_IMAGE`.
    static let extractedImageEnvironmentKey = "MACSCOPE_DYLD_CACHE_EXTRACTED_IMAGE"
    /// ServiceManagement projected from the macOS 27.2 (26B5101f) arm64e shared cache.
    static let extractedImageSHA256 = "3e2e89bbc08f74b8deac04cd9086361908136bc271eaec8953c9cd64edb08b1d"
    static let extractedImageSize = 52_960

    func testRealSharedCacheExtractedImageIsDiagnosedNotMisread() throws {
        guard let rawPath = ProcessInfo.processInfo.environment[Self.extractedImageEnvironmentKey] else {
            throw XCTSkip("Set \(Self.extractedImageEnvironmentKey) (TEST_RUNNER_ prefix via xcodebuild) "
                + "to run the HS-5b real extracted-image check.")
        }
        guard rawPath.hasPrefix("/") else {
            return XCTFail("\(Self.extractedImageEnvironmentKey) must be an absolute path, got \(rawPath)")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: rawPath))
        // Admission: the pinned bytes, or nothing below means anything.
        XCTAssertEqual(bytes.count, Self.extractedImageSize)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.extractedImageSHA256 else {
            return XCTFail("extracted image sha256 \(digest) != pinned \(Self.extractedImageSHA256)")
        }

        let machO = try MachOParser().parse(bytes)
        let metadata = machO.objectiveCMetadata
        let resolvable = (metadata.selectorReferences + metadata.classReferences + metadata.superclassReferences)
            .filter { $0.targetAddress != 0 }
        XCTAssertFalse(resolvable.isEmpty, "the image carries __objc_selrefs; references must be read")

        let objcFindings = machO.loaderFindings.filter { $0.kind == .objcMetadataFromSharedCacheExtraction }
        XCTAssertEqual(objcFindings.count, 1, "loader findings: \(machO.loaderFindings.map(\.message))")
        let finding = try XCTUnwrap(objcFindings.first)
        XCTAssertTrue(finding.message.contains("extracted from the dyld shared cache"), finding.message)
        XCTAssertGreaterThanOrEqual(Int(try XCTUnwrap(finding.value)) * 2, resolvable.count)

        let rows = AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            loaderFindings: machO.loaderFindings.map(MachOBinaryLoader.loaderFinding)
        ))
        XCTAssertTrue(rows.contains { $0.kind == .objcMetadataUnavailable }, "\(rows.map(\.message))")
    }

    // MARK: - HS-12 LC_FUNCTION_STARTS vs unwind-derived starts

    /// Two 16-byte functions; `__unwind_info` names both (one regular page, one compressed page),
    /// LC_FUNCTION_STARTS lists only the first. The second start is reported as a per-image
    /// finding that reaches the Problems-panel path, and is NOT added to the function starts.
    func testUnwindStartMissingFromFunctionStartsIsReportedNotApplied() throws {
        let imageBase: UInt64 = 0x1_0000_0000
        let disagreeing = try MachOParser().parse(Self.unwindCrossCheckImage(listSecondStart: false))
        let codeOffset = UInt64(Self.unwindFixtureCodeOffset)
        XCTAssertEqual(disagreeing.functionStarts.map(\.offsetFromImageBase), [codeOffset],
                       "the cross-check must never change LC_FUNCTION_STARTS-derived starts")
        let finding = try XCTUnwrap(disagreeing.loaderFindings.first)
        XCTAssertEqual(disagreeing.loaderFindings.map(\.kind), [.unwindFunctionStartNotInFunctionStarts])
        XCTAssertEqual(finding.address, imageBase + codeOffset + 16)
        XCTAssertEqual(finding.value, codeOffset + 16)

        let row = try XCTUnwrap(AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            loaderFindings: disagreeing.loaderFindings.map(MachOBinaryLoader.loaderFinding)
        )).first)
        XCTAssertEqual(row.kind, .functionStartsDisagreement)
        XCTAssertEqual(row.provenance, .loader)
        XCTAssertEqual(row.severity, .warning)
        XCTAssertTrue(row.message.contains(String(imageBase + codeOffset + 16, radix: 16)), row.message)

        let agreeing = try MachOParser().parse(Self.unwindCrossCheckImage(listSecondStart: true))
        XCTAssertEqual(agreeing.functionStarts.map(\.offsetFromImageBase), [codeOffset, codeOffset + 16])
        XCTAssertEqual(agreeing.loaderFindings, [], "agreeing sources produce no finding")
    }

    private static let unwindFixtureCodeOffset = 32 + 72 + 80 * 2 + 16 + 24

    /// arm64 MH_EXECUTE: __TEXT{__text, __unwind_info} + LC_FUNCTION_STARTS + LC_MAIN.
    private static func unwindCrossCheckImage(listSecondStart: Bool) -> Data {
        var out = Data()
        func u16(_ value: UInt16) { out.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)]) }
        func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
        func u64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8((value >> UInt64(shift)) & 0xff)) } }
        func name(_ value: String) { out.append(contentsOf: Array(value.utf8) + [UInt8](repeating: 0, count: 16 - value.utf8.count)) }
        func uleb(_ value: Int, into data: inout Data) {
            var remaining = value
            repeat {
                var byte = UInt8(remaining & 0x7f)
                remaining >>= 7
                if remaining != 0 { byte |= 0x80 }
                data.append(byte)
            } while remaining != 0
        }

        let imageBase: UInt64 = 0x1_0000_0000
        let codeOffset = unwindFixtureCodeOffset
        let nop: [UInt8] = [0x1f, 0x20, 0x03, 0xd5]
        let ret: [UInt8] = [0xc0, 0x03, 0x5f, 0xd6]
        let function = nop + nop + nop + ret
        let code = Data(function + function)

        // __unwind_info: header, 3 first-level entries (regular page, compressed page, sentinel).
        var unwind = Data()
        swap(&out, &unwind)
        for word: UInt32 in [1, 28, 0, 28, 0, 28, 3] { u32(word) }
        u32(UInt32(codeOffset)); u32(64); u32(0)
        u32(UInt32(codeOffset + 16)); u32(80); u32(0)
        u32(UInt32(codeOffset + 32)); u32(0); u32(0)
        u32(2); u16(8); u16(1); u32(UInt32(codeOffset)); u32(0x0400_0000)   // regular page @64
        u32(3); u16(12); u16(1); u16(0); u16(0); u32(0)                      // compressed page @80
        swap(&out, &unwind)
        precondition(unwind.count == 96)

        var starts = Data()
        uleb(codeOffset, into: &starts)
        if listSecondStart { uleb(16, into: &starts) }
        starts.append(0)

        let unwindOffset = codeOffset + code.count
        let startsOffset = unwindOffset + unwind.count
        let fileSize = startsOffset + starts.count

        u32(0xfeedfacf); u32(UInt32(bitPattern: MachOConstants.cpuTypeARM64)); u32(0)
        u32(MachOConstants.fileTypeExecute); u32(3); u32(UInt32(codeOffset - 32)); u32(0); u32(0)

        u32(MachOConstants.loadCommandSegment64); u32(72 + 80 * 2); name("__TEXT")
        u64(imageBase); u64(UInt64(fileSize)); u64(0); u64(UInt64(fileSize)); u32(5); u32(5); u32(2); u32(0)
        name("__text"); name("__TEXT"); u64(imageBase + UInt64(codeOffset)); u64(UInt64(code.count))
        u32(UInt32(codeOffset)); u32(2); u32(0); u32(0)
        u32(MachOConstants.sectionAttributePureInstructions | MachOConstants.sectionAttributeSomeInstructions)
        u32(0); u32(0); u32(0)
        name("__unwind_info"); name("__TEXT"); u64(imageBase + UInt64(unwindOffset)); u64(UInt64(unwind.count))
        u32(UInt32(unwindOffset)); u32(2); u32(0); u32(0); u32(0); u32(0); u32(0); u32(0)

        u32(MachOConstants.loadCommandFunctionStarts); u32(16); u32(UInt32(startsOffset)); u32(UInt32(starts.count))
        u32(MachOConstants.loadCommandMain); u32(24); u64(UInt64(codeOffset)); u64(0)

        precondition(out.count == codeOffset)
        out.append(code)
        out.append(unwind)
        out.append(starts)
        precondition(out.count == fileSize)
        return out
    }
}
