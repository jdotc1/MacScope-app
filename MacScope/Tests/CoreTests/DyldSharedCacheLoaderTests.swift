import Foundation
import XCTest
@testable import MacScope

/// Crafted-bytes tests for the dyld shared cache loader, mirroring the MachOImportTests
/// fixture style: a minimal cache (header + 1 mapping + 1 image whose path resolves to a
/// tiny embedded arm64 Mach-O) drives the locate + project + load path, plus malformed
/// refusals (bad magic, out-of-range mapping/image offsets, address-not-in-any-mapping).
final class DyldSharedCacheLoaderTests: XCTestCase {
    func testCacheTextWithRewrittenHeaderReceivesAttestation() throws {
        let bytes = DyldTextAuthorityFixture.make()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        let text = try XCTUnwrap(loaded.identityEffectiveByteRanges.first { $0.segmentName == "__TEXT" })
        XCTAssertEqual(text.startAddress, DyldTextAuthorityFixture.base)
        XCTAssertEqual(text.byteCount, 0x1000)
        XCTAssertEqual(text.initialProtections, 5)
        let readOnly = try XCTUnwrap(loaded.identityEffectiveByteRanges.first { $0.segmentName == "__OBJC_RO" })
        XCTAssertEqual(readOnly.initialProtections, 1)
        XCTAssertEqual(readOnly.byteCount, 0x1000)
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheLinkeditPayloadUnavailable" })
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheSignatureValidityUnavailable" })
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(bytes)
        let reader = parser.makeMultiFileReader(mainBytes: bytes, header: header, subCacheDatas: [:])
        let projected = try parser.projectImageWithCoverage(XCTUnwrap(header.images.first), using: reader, header: header)
        let region = try XCTUnwrap(projected.headerRegion)
        XCTAssertEqual(region.originalByteCount, 32 + 152 + 72 + 24 + 80 + 16)
        XCTAssertGreaterThan(region.originalByteCount, 32 + UInt64(try LittleEndianReader(loaded.bytes).u32(20)))
        XCTAssertNotEqual(region.writtenBytes, bytes.subdata(in: 0x1000..<(0x1000 + region.writtenBytes.count)))
        let snapshot = try AnalysisEngine(loader: UnavailableCacheFixtureLoader(binary: loaded))
            .analyze(url: URL(fileURLWithPath: "/tmp/cache"), selection: .automatic)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let function = try XCTUnwrap(snapshot.functions.first { $0.startAddress == DyldTextAuthorityFixture.base + 0x800 })
        let native = try NativeDecompilerSnapshotBuilder.build(from: snapshot, imageSlot: binary.slot,
            functionID: function.id, budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
        XCTAssertEqual(native.function.entryAddress.value, function.startAddress)
        XCTAssertTrue(native.memoryRegions.allSatisfy { $0.rawBytes == $0.effectiveBytes })
    }

    func testTextBytesAfterHeaderMismatchWithholdsAttestation() throws {
        let bytes = DyldTextAuthorityFixture.make()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(bytes)
        let reader = parser.makeMultiFileReader(mainBytes: bytes, header: header, subCacheDatas: [:])
        let projection = try parser.projectImageWithCoverage(XCTUnwrap(header.images.first), using: reader, header: header)
        // The normal projector copies code exactly. Pair its artifact with a cache
        // whose code byte differs to exercise the equality refusal directly.
        var changedCache = bytes
        changedCache[0x1800] ^= 1
        let changedReader = parser.makeMultiFileReader(mainBytes: changedCache, header: header, subCacheDatas: [:])
        let ranges = DyldSharedCacheBinaryLoader.cacheIdentityRanges(for: loaded,
            machO: try MachOParser().parse(loaded.bytes), reader: changedReader, projection: projection)
        XCTAssertFalse(ranges.contains { $0.segmentName == "__TEXT" })
        XCTAssertEqual(ranges.map(\.segmentName), ["__OBJC_RO"])
    }

    func testChangedProjectedHeaderWithholdsAttestation() throws {
        let bytes = DyldTextAuthorityFixture.make()
        var loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(bytes)
        let reader = parser.makeMultiFileReader(mainBytes: bytes, header: header, subCacheDatas: [:])
        let projection = try parser.projectImageWithCoverage(XCTUnwrap(header.images.first), using: reader, header: header)
        let machO = try MachOParser().parse(loaded.bytes)
        loaded.bytes[28] ^= 1
        let ranges = DyldSharedCacheBinaryLoader.cacheIdentityRanges(for: loaded,
            machO: machO, reader: reader, projection: projection)
        XCTAssertFalse(ranges.contains { $0.segmentName == "__TEXT" })
    }

    func testSlideSlotInsideTextWithholdsAttestation() throws {
        let bytes = DyldTextAuthorityFixture.make(textSlideSlot: true)
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        XCTAssertFalse(loaded.identityEffectiveByteRanges.contains { $0.segmentName == "__TEXT" })
        XCTAssertEqual(loaded.identityEffectiveByteRanges.map(\.segmentName), ["__OBJC_RO"])
    }

    func testFunctionVariantFixupsWithholdAllAttestations() throws {
        let bytes = DyldTextAuthorityFixture.make(fixupCommand: 0x38, fixupSize: 8)
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
        XCTAssertTrue(loaded.loaderFindings.contains {
            $0.code == "cacheLinkeditPayloadUnavailable" && $0.message.contains("38 was omitted")
        })
    }

    func testEmptyVariantFixupsAndCoveredChainedFixupsPreserveAttestations() throws {
        for (command, size) in [(UInt32(0x38), UInt32(0)), (UInt32(0x80000034), UInt32(8))] {
            let bytes = DyldTextAuthorityFixture.make(fixupCommand: command, fixupSize: size)
            let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
            XCTAssertEqual(loaded.identityEffectiveByteRanges.map(\.segmentName), ["__TEXT", "__OBJC_RO"])
        }
        var uncovered = DyldTextAuthorityFixture.make(fixupCommand: 0x80000034, fixupSize: 8)
        uncovered.replaceUInt32LE(at: 0x13c, with: 0)
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(uncovered, name: "cache", path: "/tmp/cache")
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
    }

    func testLiveCacheSingleImageTextAdmitsNativeFunction() throws {
        let url = URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e")
        let imagePath = "/usr/lib/system/libsystem_blocks.dylib"
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Host arm64e cache is absent.") }
        let loaded: LoadedBinary
        do {
            loaded = try DyldSharedCacheBinaryLoader(targetImagePath: imagePath).load(at: url)
        } catch DyldSharedCacheError.imageNotFound {
            throw XCTSkip("The named libsystem_blocks image is absent.")
        }
        var evidence = ["Image: \(imagePath)"]
        evidence += loaded.identityEffectiveByteRanges.map {
            "Attestation: \($0.segmentName) protections=\($0.initialProtections) start=0x\(String($0.startAddress, radix: 16)) bytes=\($0.byteCount)"
        }
        evidence += loaded.loaderFindings.map { "Finding: \($0.code): \($0.message)" }
        defer {
            let text = evidence.joined(separator: "\n")
            print(text)
            let attachment = XCTAttachment(string: text)
            attachment.name = "Single-image native authority"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let text = try XCTUnwrap(loaded.identityEffectiveByteRanges.first { $0.segmentName == "__TEXT" },
            "No __TEXT attestation; findings: \(loaded.loaderFindings)")
        let snapshot = try AnalysisEngine(loader: UnavailableCacheFixtureLoader(binary: loaded))
            .analyze(url: url, selection: .automatic)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let function = try XCTUnwrap(snapshot.functions.first {
            $0.startAddress >= text.startAddress && $0.startAddress < text.endAddressExclusive
        }, "Analysis produced no function in attested __TEXT.")
        evidence.append("Function: \(function.name) at 0x\(String(function.startAddress, radix: 16))")
        let native = try NativeDecompilerSnapshotBuilder.build(from: snapshot, imageSlot: binary.slot,
            functionID: function.id, budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
        XCTAssertEqual(native.function.entryAddress.value, function.startAddress)
        evidence.append("Builder admitted the selected function.")
    }

    func testCacheImmutableCodeAttestationAdmitsNativeFunction() throws {
        let bytes = DyldNativeAuthorityFixture.make()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        XCTAssertEqual(loaded.identityEffectiveByteRanges.map(\.segmentName), ["__TEXT_EXEC"])
        let snapshot = try AnalysisEngine(loader: UnavailableCacheFixtureLoader(binary: loaded))
            .analyze(url: URL(fileURLWithPath: "/tmp/cache"), selection: .automatic)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let function = try XCTUnwrap(snapshot.functions.first { $0.startAddress == DyldNativeAuthorityFixture.base + 0x1000 })
        let projection = try NativeDecompilerSnapshotBuilder.build(from: snapshot, imageSlot: binary.slot,
            functionID: function.id, budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
        XCTAssertEqual(projection.function.entryAddress.value, function.startAddress)
        XCTAssertFalse(projection.memoryRegions.isEmpty)
        XCTAssertTrue(projection.memoryRegions.allSatisfy { $0.rawBytes == $0.effectiveBytes })
    }

    func testUnknownSlideFormatWithholdsNativeAuthority() throws {
        let bytes = DyldNativeAuthorityFixture.make(slideVersion: 99)
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
        let snapshot = try AnalysisEngine(loader: UnavailableCacheFixtureLoader(binary: loaded))
            .analyze(url: URL(fileURLWithPath: "/tmp/cache"), selection: .automatic)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let function = try XCTUnwrap(snapshot.functions.first { $0.startAddress == DyldNativeAuthorityFixture.base + 0x1000 })
        XCTAssertThrowsError(try NativeDecompilerSnapshotBuilder.build(from: snapshot, imageSlot: binary.slot,
            functionID: function.id, budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError, .effectiveLoadImageAuthorityUnavailable)
        }
    }

    func testCacheSlidePointerUsesMappingVersionAndAuthTarget() throws {
        for version in [UInt32(3), 5] {
            let fixture = DyldCallFixture.make(slideVersion: version, pointerToSelected: true, diversity: 0x1234, key: 2)
            let parser = DyldSharedCacheParser()
            let header = try parser.parseHeader(fixture.bytes)
            let reader = parser.makeMultiFileReader(mainBytes: fixture.bytes, header: header, subCacheDatas: [:])
            let page = reader.slidePage(containing: fixture.slot)
            XCTAssertNil(page.unavailableReason)
            let pointer = try XCTUnwrap(page.pointers[fixture.slot])
            XCTAssertEqual(pointer.version, version)
            XCTAssertEqual(pointer.target, fixture.call)
            XCTAssertNotEqual(pointer.rawValue, pointer.target)
            XCTAssertEqual(pointer.authentication?.diversity, 0x1234)
            XCTAssertEqual(pointer.authentication?.key, 2)
            XCTAssertEqual(pointer.authentication?.addressDiversity, true)
            XCTAssertTrue(try fixture.load().codePointerTargets.contains(fixture.call))
        }
    }

    func testUnknownSlideFormatStaysUnavailable() throws {
        let fixture = DyldCallFixture.make(slideVersion: 99, pointerToSelected: true)
        let loaded = try fixture.load()
        XCTAssertTrue(loaded.codePointerTargets.isEmpty)
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheSlideInfoUnavailable" })
        var malformed = DyldCallFixture.make(pointerToSelected: true)
        // A valid first pointer followed by an out-of-page link invalidates the whole page.
        malformed.bytes.replaceUInt64LE(at: 0x1f80, with: (UInt64(1) << 63) | (0x7ff << 52) | 0x800)
        XCTAssertTrue(try malformed.load().codePointerTargets.isEmpty)
    }


    func testCacheProjectionPreservesSwiftMetadataAndFindings() throws {
        let fixture = DyldMetadataFixture.make()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(fixture, name: "cache", path: "/tmp/cache")
        XCTAssertEqual(loaded.swiftTypes.map(\.name), ["Pair"])
        XCTAssertEqual(loaded.swiftConformances.map(\.typeName), ["Pair"])
        XCTAssertEqual(loaded.swiftConformances.map(\.protocolName), ["Marker"])
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "metadataAbandonedList" })
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheLinkeditPayloadUnavailable" })
        XCTAssertEqual(loaded.machOMetadata?.dependentDylibs.map(\.path), ["/usr/lib/libOther.dylib"])
        XCTAssertTrue(loaded.codePointerTargets.isEmpty)
        XCTAssertEqual(loaded.relocations.count, 1)
        XCTAssertEqual(loaded.relocations.first?.address, DyldMetadataFixture.base + 0x800)
        XCTAssertEqual(loaded.relocations.first?.widthInBytes, 4)
    }

    func testCacheProjectionNeverClaimsOriginalSignatureForRewrittenBytes() throws {
        let fixture = DyldMetadataFixture.make()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(fixture, name: "cache", path: "/tmp/cache")
        XCTAssertNil(loaded.machOMetadata?.codeSignature)
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheSignatureValidityUnavailable" })
        let parsed = try MachOParser().parse(loaded.bytes)
        let omitted: Set<UInt32> = [0x1d, 0x80000034, 0x1e, 0x2b, 0x2e, 0x36, 0x37, 0x38, 0x16, 0x31]
        XCTAssertTrue(parsed.loadCommands.allSatisfy { !omitted.contains($0.command) })
        let unavailable = loaded.loaderFindings.filter { $0.code == "cacheLinkeditPayloadUnavailable" }
        XCTAssertEqual(unavailable.count, omitted.count)
        XCTAssertTrue(unavailable.allSatisfy { $0.address == DyldMetadataFixture.base })
        let reader = LittleEndianReader(loaded.bytes)
        XCTAssertEqual(try reader.u32(16), UInt32(parsed.loadCommands.count))
        var end = 32
        for command in parsed.loadCommands {
            XCTAssertEqual(Int(command.offset), end)
            end += Int(try reader.u32(end + 4))
        }
        XCTAssertEqual(try reader.u32(20), UInt32(end - 32))
        XCTAssertLessThan(try reader.u32(20), try LittleEndianReader(fixture).u32(0x1014))
        XCTAssertEqual(loaded.machOMetadata?.dependentDylibs.map(\.path), ["/usr/lib/libOther.dylib"])
    }

    func testCacheSmallMethodRetainsProvenImplementationAddress() throws {
        let fixture = DyldMetadataFixture.make()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(fixture, name: "cache", path: "/tmp/cache")
        let method = try XCTUnwrap(loaded.objcClasses.first?.instanceMethods.first)
        XCTAssertEqual(method.selector, "run")
        XCTAssertEqual(method.implementation, DyldMetadataFixture.base + 0x800)
        var unavailable = fixture
        unavailable.replaceUInt32LE(at: 0x200 + 28, with: 3)
        let nonExecutable = try DyldSharedCacheBinaryLoader().loadFromBytes(unavailable, name: "cache", path: "/tmp/cache")
        XCTAssertNil(nonExecutable.objcClasses.first?.instanceMethods.first?.implementation)
        var missing = fixture
        missing.replaceUInt32LE(at: 0x1000 + 0x990, with: 0x100000)
        let unmapped = try DyldSharedCacheBinaryLoader().loadFromBytes(missing, name: "cache", path: "/tmp/cache")
        XCTAssertNil(unmapped.objcClasses.first?.instanceMethods.first?.implementation)
    }

    func testV1SiblingSuffixMatchesReaderKey() throws {
        var fixture = DyldSplitCacheFixture.make()
        // This genuine v1 header still has enough trailing bytes to fit a v2 record.
        fixture.mainBytes.replaceSubrange(0x1A0..<0x1C0, with: fixture.mainBytes[0x200..<0x220])
        fixture.mainBytes.replaceUInt32LE(at: 16, with: 0x1A0)
        let header = try DyldSharedCacheParser().parseHeader(fixture.mainBytes)
        XCTAssertFalse(header.usesV2SubCacheEntries)
        XCTAssertEqual(header.subCacheEntries.map(\.fileSuffix), [".1"])
        let directory = try makeDyldTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("cache")
        try fixture.mainBytes.write(to: main)
        try fixture.symbolsBytes.write(to: URL(fileURLWithPath: main.path + ".1"))
        let loaded = try DyldSharedCacheBinaryLoader().load(at: main)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "_splitEntry" })
    }

    func testSiblingUUIDMismatchCannotSupplyImageBytes() throws {
        var fixture = DyldSplitCacheFixture.make()
        fixture.symbolsBytes[0x58] ^= 1
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(fixture.mainBytes)
        let reader = parser.makeMultiFileReader(mainBytes: fixture.mainBytes, header: header,
            subCacheDatas: [".symbols": fixture.symbolsBytes])
        XCTAssertNil(reader.readBytes(at: fixture.linkeditVMAddress, length: 1))
        XCTAssertThrowsError(try DyldSharedCacheBinaryLoader().loadFromBytes(
            fixture.mainBytes, name: "cache", path: "/tmp/cache",
            subCacheDatas: [".symbols": fixture.symbolsBytes])) { error in
            XCTAssertEqual(error as? DyldSharedCacheError, .siblingUUIDMismatch(".symbols"))
        }
    }

    func testOverlappingMappingsAreTypedRefusal() throws {
        var fixture = DyldSplitCacheFixture.make()
        fixture.symbolsBytes.replaceUInt64LE(at: 0x200, with: fixture.imageVMAddress + 8)
        XCTAssertThrowsError(try DyldSharedCacheBinaryLoader().loadFromBytes(
            fixture.mainBytes, name: "cache", path: "/tmp/cache",
            subCacheDatas: [".symbols": fixture.symbolsBytes])) { error in
            XCTAssertEqual(error as? DyldSharedCacheError, .overlappingMappings(fixture.imageVMAddress + 8))
        }
        var main = DyldCacheFixture.makeSingleImageCache().bytes
        main.replaceUInt32LE(at: 20, with: 2)
        main.replaceSubrange(0x220..<0x240, with: main[0x200..<0x220])
        XCTAssertThrowsError(try DyldSharedCacheParser().parseHeader(main)) { error in
            guard case .overlappingMappings = error as? DyldSharedCacheError else {
                return XCTFail("Expected typed overlap refusal")
            }
        }
    }

    func testUnavailableSegmentCannotAliasHeaderBytes() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        for size in [DyldSharedCacheParser.maxProjectedSegmentBytes + 1, UInt64(fixture.bytes.count)] {
            var bytes = fixture.bytes
            bytes.replaceUInt64LE(at: fixture.imageFileOffset + 32 + 48, with: size)
            let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
            let section = try XCTUnwrap(loaded.sections.first { $0.name == "__TEXT,__text" })
            XCTAssertEqual(section.address, fixture.textVMAddress)
            XCTAssertEqual(section.size, UInt64(fixture.code.count))
            XCTAssertEqual(section.fileSize, 0)
            XCTAssertGreaterThanOrEqual(section.fileOffset, UInt64(loaded.bytes.count))
            XCTAssertNil(loaded.executableTextSection)
            XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheSegmentBytesUnavailable" })
            XCTAssertEqual(loaded.artifactIntegrityState, .unavailable)
            let snapshot = try AnalysisEngine(loader: UnavailableCacheFixtureLoader(binary: loaded))
                .analyze(url: URL(fileURLWithPath: "/tmp/cache"), selection: .automatic)
            XCTAssertFalse(snapshot.instructions.contains { !$0.bytes.isEmpty })
        }
    }

    // MARK: - Happy path

    func testParsesHeaderMappingsAndImages() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let header = try DyldSharedCacheParser().parseHeader(fixture.bytes)

        XCTAssertTrue(header.magicString.hasPrefix("dyld_v1"))
        XCTAssertEqual(header.architecture, "arm64e")
        XCTAssertEqual(header.mappings.count, 1)
        XCTAssertEqual(header.images.count, 1)
        XCTAssertEqual(header.images.first?.path, "/usr/lib/libFixture.dylib")
        XCTAssertEqual(header.images.first?.address, fixture.imageVMAddress)
        XCTAssertEqual(header.subCacheArrayCount, 0)
    }

    func testResolvesCacheAddressToFileOffsetViaMappings() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let header = try DyldSharedCacheParser().parseHeader(fixture.bytes)

        let resolved = DyldSharedCacheParser.fileOffset(
            for: fixture.imageVMAddress,
            mappings: header.mappings
        )
        XCTAssertEqual(resolved, UInt64(fixture.imageFileOffset))
    }

    func testLocatesImageBySuffixAndProjectsLoadedBinary() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let loader = DyldSharedCacheBinaryLoader(targetImagePath: "libFixture.dylib")
        let loaded = try loader.loadFromBytes(fixture.bytes, name: "dyld_shared_cache_arm64e", path: "/tmp/cache")

        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(loaded.name, "libFixture.dylib")
        XCTAssertTrue(loaded.path.contains("/usr/lib/libFixture.dylib"))
        // The projected image exposes its __TEXT,__text section + the embedded code.
        let text = try XCTUnwrap(loaded.executableTextSection)
        XCTAssertEqual(text.name, "__TEXT,__text")
        XCTAssertEqual(text.address, fixture.textVMAddress)
        XCTAssertTrue(text.isExecutable)
        // The text section's bytes survived the projection (its file offset addresses the
        // embedded code in the projected blob).
        let start = Int(text.fileOffset)
        XCTAssertLessThanOrEqual(start + fixture.code.count, loaded.bytes.count)
        let recovered = loaded.bytes.subdata(in: start ..< start + fixture.code.count)
        XCTAssertEqual(recovered, fixture.code)
    }

    func testProjectsDataInCodeRangesFromCachedMachOImage() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache(includeDataInCode: true)
        let loaded = try DyldSharedCacheBinaryLoader(targetImagePath: "libFixture.dylib")
            .loadFromBytes(fixture.bytes, name: "dyld_shared_cache_arm64e", path: "/tmp/cache")

        XCTAssertEqual(loaded.codeDataRanges, [
            BinaryCodeDataRange(
                address: fixture.textVMAddress + 4,
                size: 4,
                kind: "data"
            ),
        ])
    }

    func testProjectsMachOCPUSubtypeFromCachedImage() throws {
        let arm64eSubtype: Int32 = 2
        let fixture = DyldCacheFixture.makeSingleImageCache(cpuSubtype: arm64eSubtype)

        let loaded = try DyldSharedCacheBinaryLoader()
            .loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")

        XCTAssertEqual(loaded.cpuSubtype, arm64eSubtype)
    }

    func testProjectedImageCarriesVerifiedReconstructedArtifactIdentity() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache(cpuSubtype: 2)
        let loaded = try DyldSharedCacheBinaryLoader()
            .loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")
        let artifact = try XCTUnwrap(loaded.artifactIdentity)

        XCTAssertEqual(loaded.artifactIntegrityState, .verified)
        XCTAssertNotNil(loaded.preferredSegmentLayout)
        XCTAssertEqual(artifact.rawCPUType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(artifact.rawCPUSubtype, 2)
        XCTAssertEqual(artifact.architectureVariant, .arm64e)
        XCTAssertEqual(artifact.selectedSliceByteCount, UInt64(loaded.bytes.count))

        let independentlyParsed = try MachOParser().parse(loaded.bytes)
        let independentlyReconstructed = try XCTUnwrap(
            MachOSliceArtifactReconstructor.reconstructOrMarkUnavailableForAnonymousObject(
                machO: independentlyParsed,
                selectedSliceBytes: loaded.bytes
            )
        )
        XCTAssertEqual(artifact, independentlyReconstructed.identity)
        XCTAssertEqual(loaded.preferredSegmentLayout, independentlyReconstructed.preferredSegmentLayout)
    }

    func testDefaultTargetProjectsFirstImage() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let loaded = try DyldSharedCacheBinaryLoader()
            .loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")
        XCTAssertEqual(loaded.name, "libFixture.dylib")
        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeARM64)
    }

    func testRecoversSymbolsFromProjectedImage() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let loaded = try DyldSharedCacheBinaryLoader()
            .loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")
        XCTAssertTrue(
            loaded.symbols.contains { $0.name == "_fixtureEntry" },
            "expected projected image to expose its embedded symbol, got \(loaded.symbols.map(\.name))"
        )
    }

    func testRouterRoutesDyldCacheMagicToCacheLoader() throws {
        // The router sniffs the "dyld_v1" prefix and must NOT misroute it to Mach-O.
        let fixture = DyldCacheFixture.makeSingleImageCache()
        XCTAssertTrue(DyldSharedCacheParser.isDyldSharedCache(fixture.bytes))
        XCTAssertFalse(ELFBinaryLoader.isELF(fixture.bytes))
    }

    // MARK: - Malformed refusals (hardening)

    func testRejectsBadMagic() {
        var bytes = DyldCacheFixture.makeSingleImageCache().bytes
        bytes[0] = 0x00 // corrupt the 'd' of "dyld_v1"
        XCTAssertThrowsError(try DyldSharedCacheParser().parseHeader(bytes)) { error in
            XCTAssertEqual(error as? DyldSharedCacheError, .notADyldCache)
        }
    }

    func testRejectsOutOfRangeMappingArray() {
        var bytes = DyldCacheFixture.makeSingleImageCache().bytes
        // mappingOffset @16 -> push it past the end of the file.
        bytes.replaceUInt32LE(at: 16, with: UInt32(bytes.count + 0x1000))
        XCTAssertThrowsError(try DyldSharedCacheParser().parseHeader(bytes)) { error in
            guard case DyldSharedCacheError.truncated = error as! DyldSharedCacheError else {
                return XCTFail("Expected .truncated, got \(error)")
            }
        }
    }

    func testRejectsMappingFileRangeBeyondFile() {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        var bytes = fixture.bytes
        // The mapping's `size` @ (mappingOffset + 8): blow it up past the file.
        let sizeOffset = fixture.mappingOffset + 8
        bytes.replaceUInt64LE(at: sizeOffset, with: UInt64(bytes.count) + 0x1_0000)
        XCTAssertThrowsError(try DyldSharedCacheParser().parseHeader(bytes)) { error in
            guard case DyldSharedCacheError.malformed = error as! DyldSharedCacheError else {
                return XCTFail("Expected .malformed, got \(error)")
            }
        }
    }

    func testRejectsOutOfRangeImageArray() {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        var bytes = fixture.bytes
        // imagesOffset @24 -> past the end so neither the classic nor the text array is
        // in range.
        bytes.replaceUInt32LE(at: 24, with: UInt32(bytes.count + 0x1000))
        XCTAssertThrowsError(try DyldSharedCacheParser().parseHeader(bytes)) { error in
            guard case DyldSharedCacheError.truncated = error as! DyldSharedCacheError else {
                return XCTFail("Expected .truncated, got \(error)")
            }
        }
    }

    func testAddressNotInAnyMappingDegradesToSubCacheOnly() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        var bytes = fixture.bytes
        // Move the image's mach_header address far outside the single mapping's VM range,
        // simulating an image whose bytes live in a sub-cache file.
        bytes.replaceUInt64LE(at: fixture.imageRecordOffset, with: 0x7FFF_0000_0000)
        let loaded = DyldSharedCacheBinaryLoader()
        XCTAssertThrowsError(try loaded.loadFromBytes(bytes, name: "cache", path: "/tmp/cache")) { error in
            guard case DyldSharedCacheError.subCacheOnly = error as! DyldSharedCacheError else {
                return XCTFail("Expected .subCacheOnly, got \(error)")
            }
        }
    }

    func testMissingTargetImageThrowsImageNotFound() {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let loader = DyldSharedCacheBinaryLoader(targetImagePath: "/does/not/exist.dylib")
        XCTAssertThrowsError(try loader.loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")) { error in
            guard case DyldSharedCacheError.imageNotFound = error as! DyldSharedCacheError else {
                return XCTFail("Expected .imageNotFound, got \(error)")
            }
        }
    }

    // MARK: - Sub-cache stitching (multi-file)

    func testParsesSubCacheEntryArray() throws {
        let fixture = DyldSplitCacheFixture.make()
        let header = try DyldSharedCacheParser().parseHeader(fixture.mainBytes)
        XCTAssertEqual(header.subCacheArrayCount, 1)
        XCTAssertEqual(header.subCacheEntries.count, 1)
        XCTAssertEqual(header.subCacheEntries.first?.fileSuffix, ".symbols")
    }

    func testMultiFileReaderMapsCrossFileAddress() throws {
        let fixture = DyldSplitCacheFixture.make()
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(fixture.mainBytes)
        let reader = parser.makeMultiFileReader(
            mainBytes: fixture.mainBytes,
            header: header,
            subCacheDatas: [".symbols": fixture.symbolsBytes]
        )
        // The image header is in the MAIN file.
        let imageResolved = try XCTUnwrap(reader.resolve(fixture.imageVMAddress))
        XCTAssertEqual(imageResolved.file.suffix, "")
        // The __LINKEDIT VM address is mapped ONLY by the .symbols sibling.
        let linkeditResolved = try XCTUnwrap(reader.resolve(fixture.linkeditVMAddress))
        XCTAssertEqual(linkeditResolved.file.suffix, ".symbols")
    }

    func testFixedReadBytesRequiresWholeContainingMapping() {
        let mapping = DyldCacheMapping(address: 0x1000, size: 0x40, fileOffset: 0x10,
                                       maxProtection: 5, initialProtection: 5)
        let adjacent = DyldCacheMapping(address: 0x1040, size: 0x40, fileOffset: 0x50,
                                        maxProtection: 5, initialProtection: 5)
        let bytes = Data(repeating: 0xAB, count: 256)
        for mappings in [[mapping], [mapping, adjacent]] {
            let reader = MultiFileCacheReader(files: [.init(suffix: "", bytes: bytes, mappings: mappings)])
            XCTAssertEqual(reader.readBytes(at: 0x1030, length: 16), Data(repeating: 0xAB, count: 16))
            XCTAssertNil(reader.readBytes(at: 0x1030, length: 17), "No file-tail or adjacent-mapping bleed")
            XCTAssertNil(reader.readBytes(at: 0x1030, length: UInt64.max))
        }
        let sibling = MultiFileCacheReader(files: [
            .init(suffix: "", bytes: bytes, mappings: [mapping]),
            .init(suffix: ".1", bytes: Data(repeating: 0xCD, count: 256), mappings: [adjacent])
        ])
        XCTAssertNil(sibling.readBytes(at: 0x1030, length: 17), "Cannot continue into a sibling")
        XCTAssertEqual(sibling.readBytes(at: 0x1040, length: 1), Data([0xCD]))
        XCTAssertNil(sibling.readBytes(at: 0x9999, length: 1))
        XCTAssertEqual(sibling.readBytes(at: 0x9999, length: 0), Data())
    }

    func testFixedReadBytesRejectsBackingFileAndAddressOverflow() {
        let truncated = DyldCacheMapping(address: 0x1000, size: 0x40, fileOffset: 0x10,
                                         maxProtection: 5, initialProtection: 5)
        let reader = MultiFileCacheReader(files: [.init(suffix: "", bytes: Data(repeating: 0xAB, count: 0x40),
                                                        mappings: [truncated])])
        XCTAssertEqual(reader.readBytes(at: 0x102f, length: 1), Data([0xAB]))
        XCTAssertNil(reader.readBytes(at: 0x102f, length: 2))
        let overflowingOffset = DyldCacheMapping(address: 0x1000, size: 0x40, fileOffset: UInt64.max - 8,
                                                maxProtection: 5, initialProtection: 5)
        let overflowingAddress = DyldCacheMapping(address: UInt64.max - 8, size: 16, fileOffset: 0,
                                                 maxProtection: 5, initialProtection: 5)
        let malformed = MultiFileCacheReader(files: [.init(suffix: "", bytes: Data(repeating: 0xCD, count: 256),
                                                           mappings: [overflowingOffset, overflowingAddress])])
        XCTAssertNil(malformed.readBytes(at: 0x1010, length: 1), "File offset must not wrap into valid bytes")
        XCTAssertNil(malformed.readBytes(at: UInt64.max - 1, length: 4), "VM range must not wrap")
    }

    func testReadBytesClampedStopsAtMappingEnd() {
        // One mapping: VM [0x1000, 0x1040) -> file [0x10, 0x50); the backing file extends well past
        // 0x50. A variable-length read near the mapping edge must clamp to the MAPPING, not spill into
        // the file bytes past it (the over-read the adversarial review found, which could yield a
        // wrong/overlong __OBJC_RO string).
        let bytes = Data(repeating: 0xAB, count: 256)
        let mapping = DyldCacheMapping(address: 0x1000, size: 0x40, fileOffset: 0x10,
                                       maxProtection: 5, initialProtection: 5)
        let reader = MultiFileCacheReader(files: [.init(suffix: "", bytes: bytes, mappings: [mapping])])
        // 16 bytes remain in the mapping at VM 0x1030; a 100-byte request must clamp to 16.
        XCTAssertEqual(reader.readBytesClamped(at: 0x1030, maxLength: 100)?.count, 16,
                       "readBytesClamped must clamp to the containing mapping, not the backing file")
        // A request below the remaining mapping length returns exactly that many.
        XCTAssertEqual(reader.readBytesClamped(at: 0x1030, maxLength: 8)?.count, 8)
        // An unmapped address returns nil (never traps).
        XCTAssertNil(reader.readBytesClamped(at: 0x9999, maxLength: 4))
    }

    func testProjectImageRecoversSymbolsFromSiblingSubCache() throws {
        let fixture = DyldSplitCacheFixture.make()
        let loader = DyldSharedCacheBinaryLoader(targetImagePath: "libSplit.dylib")
        let loaded = try loader.loadFromBytes(
            fixture.mainBytes,
            name: "dyld_shared_cache_arm64e",
            path: "/tmp/cache",
            subCacheDatas: [".symbols": fixture.symbolsBytes]
        )
        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertTrue(
            loaded.symbols.contains { $0.name == "_splitEntry" },
            "expected the symbol from the .symbols sub-cache __LINKEDIT, got \(loaded.symbols.map(\.name))"
        )
    }

    func testMissingSiblingSubCacheDegradesToTypedError() throws {
        // The image header itself lives in the sibling here; without the sibling the
        // address is unmapped and we surface the typed .subCacheOnly error (never a crash).
        let fixture = DyldSplitCacheFixture.makeImageInSibling()
        let loader = DyldSharedCacheBinaryLoader(targetImagePath: "libSplit.dylib")
        XCTAssertThrowsError(
            try loader.loadFromBytes(fixture.mainBytes, name: "cache", path: "/tmp/cache", subCacheDatas: [:])
        ) { error in
            guard case DyldSharedCacheError.subCacheOnly = error as! DyldSharedCacheError else {
                return XCTFail("Expected .subCacheOnly, got \(error)")
            }
        }
    }

    func testMalformedSiblingIsSkippedNotCrashing() throws {
        let fixture = DyldSplitCacheFixture.make()
        // A garbage sibling (not a dyld cache) must be skipped during reader construction;
        // because the __LINKEDIT then resolves nowhere, the symbol is simply absent — but
        // the projection still succeeds and never traps.
        let garbage = Data(repeating: 0xAB, count: 256)
        let loader = DyldSharedCacheBinaryLoader(targetImagePath: "libSplit.dylib")
        let loaded = try loader.loadFromBytes(
            fixture.mainBytes,
            name: "cache",
            path: "/tmp/cache",
            subCacheDatas: [".symbols": garbage]
        )
        XCTAssertFalse(loaded.symbols.contains { $0.name == "_splitEntry" })
    }

    func testOnDiskSplitCacheUsesAdmittedSibling() throws {
        let fixture = DyldSplitCacheFixture.make()
        let directory = try makeDyldTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.mainBytes.write(to: mainURL, options: .atomic)
        try fixture.symbolsBytes.write(
            to: URL(fileURLWithPath: mainURL.path + ".symbols"),
            options: .atomic
        )

        let loaded = try DyldSharedCacheBinaryLoader(targetImagePath: "libSplit.dylib")
            .load(at: mainURL)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "_splitEntry" })
    }

    func testOnDiskLoaderRejectsUnsafeDeclaredSiblingSuffixes() throws {
        let fixture = DyldSplitCacheFixture.make()
        for suffix in ["../foreign", "/absolute", ".1\\foreign"] {
            let directory = try makeDyldTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
            try replacingSubcacheSuffix(in: fixture.mainBytes, with: suffix)
                .write(to: mainURL, options: .atomic)

            XCTAssertThrowsError(try DyldSharedCacheBinaryLoader().load(at: mainURL)) { error in
                XCTAssertEqual(
                    error as? DyldSharedCacheError,
                    .malformed("unsafe sub-cache suffix '\(suffix)'")
                )
            }
        }
    }

    func testOnDiskLoaderRejectsSymlinkAndNonregularSources() throws {
        let fixture = DyldSplitCacheFixture.make()

        do {
            let directory = try makeDyldTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let realMain = directory.appendingPathComponent("real-cache")
            let linkedMain = directory.appendingPathComponent("linked-cache")
            try fixture.mainBytes.write(to: realMain, options: .atomic)
            try FileManager.default.createSymbolicLink(at: linkedMain, withDestinationURL: realMain)
            XCTAssertThrowsError(try DyldSharedCacheBinaryLoader().load(at: linkedMain)) { error in
                XCTAssertEqual(
                    error as? DyldSharedCacheError,
                    .malformed("main cache is not a regular file")
                )
            }
        }

        do {
            let directory = try makeDyldTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
            let siblingURL = URL(fileURLWithPath: mainURL.path + ".symbols")
            try fixture.mainBytes.write(to: mainURL, options: .atomic)
            try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: false)
            XCTAssertThrowsError(try DyldSharedCacheBinaryLoader().load(at: mainURL)) { error in
                XCTAssertEqual(
                    error as? DyldSharedCacheError,
                    .malformed("sub-cache '.symbols' is not a regular file")
                )
            }
        }
    }

    func testOnDiskLoaderEnforcesPerFileAndAggregateSourceBudgets() throws {
        let fixture = DyldSplitCacheFixture.make()
        let directory = try makeDyldTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.mainBytes.write(to: mainURL, options: .atomic)
        try fixture.symbolsBytes.write(
            to: URL(fileURLWithPath: mainURL.path + ".symbols"),
            options: .atomic
        )

        XCTAssertThrowsError(try DyldSharedCacheBinaryLoader(
            perFileByteLimit: UInt64(fixture.mainBytes.count - 1),
            aggregateByteLimit: UInt64.max
        ).load(at: mainURL)) { error in
            XCTAssertEqual(
                error as? DyldSharedCacheError,
                .malformed("main cache exceeds source byte budget")
            )
        }

        XCTAssertThrowsError(try DyldSharedCacheBinaryLoader(
            perFileByteLimit: UInt64(max(fixture.mainBytes.count, fixture.symbolsBytes.count)),
            aggregateByteLimit: UInt64(fixture.mainBytes.count + fixture.symbolsBytes.count - 1)
        ).load(at: mainURL)) { error in
            XCTAssertEqual(
                error as? DyldSharedCacheError,
                .malformed("aggregate cache sources exceed byte budget")
            )
        }
    }

    func testDescriptorBoundAdmissionRejectsPathReplacement() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeDyldTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)
        var replacement = fixture.bytes
        replacement[replacement.count - 1] ^= 0xff
        try replacement.write(to: mainURL, options: .atomic)

        XCTAssertThrowsError(try DyldSharedCacheBinaryLoader.admittedData(
            at: mainURL,
            expectedIdentity: identity,
            maximumBytes: UInt64(fixture.bytes.count)
        )) { error in
            XCTAssertEqual(
                error as? DyldSharedCacheError,
                .malformed("cache source changed during admission")
            )
        }
    }

    func testRejectsImageWhoseHeaderIsNotMachO() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        var bytes = fixture.bytes
        // Corrupt the embedded image's mach_header magic.
        bytes.replaceUInt32LE(at: fixture.imageFileOffset, with: 0xdead_beef)
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(bytes)
        let image = try parser.locateImage(path: "libFixture.dylib", in: header)
        XCTAssertThrowsError(try parser.projectImage(image, from: bytes, header: header)) { error in
            guard case DyldSharedCacheError.unsupportedImageMagic = error as! DyldSharedCacheError else {
                return XCTFail("Expected .unsupportedImageMagic, got \(error)")
            }
        }
    }

    private func makeDyldTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-DyldLoader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func replacingSubcacheSuffix(in original: Data, with suffix: String) throws -> Data {
        var bytes = original
        let header = try DyldSharedCacheParser().parseHeader(bytes)
        let suffixOffset = Int(header.subCacheArrayOffset) + 24
        let suffixBytes = Array(suffix.utf8)
        precondition(suffixBytes.count < 32)
        bytes.replaceSubrange(suffixOffset..<(suffixOffset + 32), with: repeatElement(0, count: 32))
        bytes.replaceSubrange(suffixOffset..<(suffixOffset + suffixBytes.count), with: suffixBytes)
        return bytes
    }
}

// MARK: - Fixture

/// Builds a minimal but well-formed single-image dyld shared cache in memory. Layout:
///
///   [0x000) dyld_cache_header (classic field block)
///   [mappingOffset) one dyld_cache_mapping_info (covers the image VM region)
///   [imagesOffset)  one dyld_cache_image_info
///   [pathOffset)    "/usr/lib/libFixture.dylib\0"
///   [imageFileOffset) embedded thin arm64 Mach-O (header + __TEXT seg + LC_SYMTAB)
///
/// The single mapping maps `imageVMAddress -> imageFileOffset`, so the locator resolves
/// the image header back to its file bytes and the projector slices it out.
/// Tiny selected image containing one method, Swift type/conformance and relocation.
enum DyldMetadataFixture {
    static let base: UInt64 = 0x1_8000_0000

    static func make() -> Data {
        var data = Data(repeating: 0, count: 0x3000)
        func u32(_ offset: Int, _ value: UInt32) { data.replaceUInt32LE(at: offset, with: value) }
        func u64(_ offset: Int, _ value: UInt64) { data.replaceUInt64LE(at: offset, with: value) }
        func string(_ offset: Int, _ value: String) {
            data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
        }
        func rel(_ field: Int, _ target: Int) {
            u32(0x1000 + field, UInt32(bitPattern: Int32(target - field)))
        }
        string(0, "dyld_v1  arm64e")
        u32(16, 0x200); u32(20, 1); u32(24, 0x240); u32(28, 1)
        u64(0xe0, base)
        u64(0x200, base); u64(0x208, 0x2000); u64(0x210, 0x1000)
        u32(0x218, 5); u32(0x21c, 5)
        u64(0x240, base); u32(0x258, 0x280); string(0x280, "/usr/lib/libMetadata.dylib")
        let sections: [(String, Int, Int, UInt32)] = [
            ("__text", 0x800, 16, 0x80000400), ("__const", 0x900, 0x600, 0),
            ("__swift5_types", 0xf00, 8, 0), ("__swift5_proto", 0xf10, 4, 0),
            ("__objc_classlist", 0xf20, 8, 0), ("__objc_scoffs", 0xf30, 16, 0)
        ]
        let segmentSize = 72 + sections.count * 80
        let commandsSize = segmentSize + 48 + 9 * 16 + 40
        u32(0x1000, 0xfeedfacf); u32(0x1004, 0x0100000c); u32(0x100c, 6)
        u32(0x1010, 12); u32(0x1014, UInt32(commandsSize))
        let segment = 0x1020
        u32(segment, 0x19); u32(segment + 4, UInt32(segmentSize)); string(segment + 8, "__TEXT")
        u64(segment + 24, base); u64(segment + 32, 0x2000)
        u64(segment + 40, 0x1000); u64(segment + 48, 0x2000)
        u32(segment + 56, 5); u32(segment + 60, 5); u32(segment + 64, UInt32(sections.count))
        for (index, section) in sections.enumerated() {
            let record = segment + 72 + index * 80
            string(record, section.0); string(record + 16, "__TEXT")
            u64(record + 32, base + UInt64(section.1)); u64(record + 40, UInt64(section.2))
            u32(record + 48, UInt32(0x1000 + section.1)); u32(record + 52, 2)
            u32(record + 64, section.3)
            if index == 0 { u32(record + 56, 0x1e10); u32(record + 60, 1) }
        }
        var command = segment + segmentSize
        u32(command, 0xc); u32(command + 4, 48); u32(command + 8, 24)
        string(command + 24, "/usr/lib/libOther.dylib")
        command += 48
        for kind in [UInt32(0x1d), 0x80000034, 0x1e, 0x2b, 0x2e, 0x36, 0x37, 0x38, 0x16] {
            u32(command, kind); u32(command + 4, 16); u32(command + 8, 0x1e00); u32(command + 12, 8)
            command += 16
        }
        u32(command, 0x31); u32(command + 4, 40)
        u64(command + 24, 0x1e00); u64(command + 32, 8)
        u32(0x1800, 0xd65f03c0); u32(0x1804, 0xd503201f)
        u32(0x1808, 0xd503201f); u32(0x180c, 0xd65f03c0)
        u64(0x1920, 0x940); u64(0x1958, 0xb00); u64(0x1960, 0x980)
        u32(0x1980, 0xc000000c); u32(0x1984, 1)
        u32(0x1988, 0x20); u32(0x198c, 0x30); rel(0x990, 0x800)
        u32(0x1a00, 17); rel(0xa08, 0xa80)
        u32(0x1a20, 3); rel(0xa28, 0xa90)
        rel(0xa40, 0xa20); rel(0xa44, 0xa00)
        string(0x1a80, "Pair"); string(0x1a90, "Marker")
        string(0x1b00, "Sample"); string(0x1b20, "run"); string(0x1b30, "v16@0:8")
        u32(0x1e10, 0); u32(0x1e14, (2 << 25) | 1)
        rel(0xf00, 0xa00); u32(0x1f04, 0x7ffffffc); rel(0xf10, 0xa40)
        u64(0x1f20, 0x900); u64(0x1f38, 0xb00)
        // Bind the existing ObjC pointer fields to a complete v5 page chain.
        u32(0x138, 0x300); u32(0x13c, 1)
        u64(0x300, base); u64(0x308, 0x2000); u64(0x310, 0x1000)
        u64(0x318, 0x400); u64(0x320, 28); u32(0x330, 5); u32(0x334, 5)
        u32(0x400, 5); u32(0x404, 4096); u32(0x408, 2); u64(0x410, base)
        data[0x418] = 0x20; data[0x419] = 9; data[0x41a] = 0xff; data[0x41b] = 0xff
        u64(0x1920, 0x940 | (7 << 52)); u64(0x1958, 0xb00 | (1 << 52))
        u64(0x1960, 0x980 | (184 << 52)); u64(0x1f20, 0x900 | (3 << 52))
        return data
    }
}

struct DyldCacheFixture {
    var bytes: Data
    var mappingOffset: Int
    var imagesOffset: Int
    var imageRecordOffset: Int   // start of the dyld_cache_image_info record
    var imageFileOffset: Int     // file offset of the embedded Mach-O header
    var imageVMAddress: UInt64   // VM address of the embedded Mach-O header
    var textVMAddress: UInt64
    var code: Data

    static func makeSingleImageCache(
        cpuSubtype: Int32 = 0,
        includeDataInCode: Bool = false
    ) -> DyldCacheFixture {
        // arm64 `ret` x4 then a couple of nops so there's recoverable code.
        let code = Data([
            0xc0, 0x03, 0x5f, 0xd6, // ret
            0x1f, 0x20, 0x03, 0xd5, // nop
            0x1f, 0x20, 0x03, 0xd5, // nop
            0xc0, 0x03, 0x5f, 0xd6  // ret
        ])

        let headerSize = 0x200          // generous classic header block
        let mappingOffset = headerSize
        let mappingSize = 32
        let imagesOffset = mappingOffset + mappingSize
        let imageRecordSize = 32
        let pathOffset = imagesOffset + imageRecordSize
        let path = "/usr/lib/libFixture.dylib"

        // Embedded Mach-O is laid out from `imageFileOffset`. Its single __TEXT segment's
        // fileoff must be a CACHE file offset (it points at the embedded Mach-O header,
        // i.e. imageFileOffset), since segments in a real cache are file-relative.
        let machOHeaderSize = 32
        let segmentCommandSize = 72 + 80
        let symtabCommandSize = 24
        let dataInCodeCommandSize = includeDataInCode ? 16 : 0
        let loadCommandsSize = segmentCommandSize + symtabCommandSize + dataInCodeCommandSize
        let imageInternalCodeOffset = machOHeaderSize + loadCommandsSize  // offset of code WITHIN the image
        let symbolTableInternalOffset = imageInternalCodeOffset + code.count
        let stringTableInternalOffset = symbolTableInternalOffset + 16    // one nlist_64 (16 bytes)
        let stringTable = makeStringTable()
        let dataInCodeInternalOffset = stringTableInternalOffset + stringTable.count
        let imageTotalSize = dataInCodeInternalOffset + (includeDataInCode ? 8 : 0)

        // Round the image file offset up a little so it starts after the path string.
        var imageFileOffset = pathOffset + path.utf8.count + 1
        imageFileOffset = (imageFileOffset + 0xF) & ~0xF // 16-byte align

        let imageVMAddress: UInt64 = 0x1_8000_0000
        let textVMAddress = imageVMAddress + UInt64(imageInternalCodeOffset)
        let segmentVMAddress = imageVMAddress
        let segmentVMSize = UInt64(imageTotalSize)

        // The mapping covers [imageVMAddress, +span) -> [imageFileOffset, +span). The
        // file-backed span must stay within the file, so it is exactly the image size.
        let span = UInt64(imageTotalSize)

        var bytes = Data()

        // --- dyld_cache_header ---
        bytes.appendFixedCStringLocal("dyld_v1  arm64e", length: 16) // magic @0
        bytes.appendUInt32LE(UInt32(mappingOffset))   // @16 mappingOffset
        bytes.appendUInt32LE(1)                        // @20 mappingCount
        bytes.appendUInt32LE(UInt32(imagesOffset))     // @24 imagesOffset
        bytes.appendUInt32LE(1)                        // @28 imagesCount
        // Pad the rest of the header block with zeros (dyldBaseAddress, codeSig, etc.).
        bytes.appendPaddingLocal(to: headerSize)

        // --- mapping_info @mappingOffset ---
        precondition(bytes.count == mappingOffset)
        bytes.appendUInt64LE(imageVMAddress)           // address
        bytes.appendUInt64LE(span)                      // size
        bytes.appendUInt64LE(UInt64(imageFileOffset))  // fileOffset
        bytes.appendUInt32LE(5)                          // maxProt (r-x)
        bytes.appendUInt32LE(5)                          // initProt

        // --- image_info @imagesOffset ---
        precondition(bytes.count == imagesOffset)
        let imageRecordOffset = bytes.count
        bytes.appendUInt64LE(imageVMAddress)           // address
        bytes.appendUInt64LE(0)                         // modTime
        bytes.appendUInt64LE(0)                         // inode
        bytes.appendUInt32LE(UInt32(pathOffset))       // pathFileOffset
        bytes.appendUInt32LE(0)                         // pad

        // --- path string @pathOffset ---
        precondition(bytes.count == pathOffset)
        bytes.appendNullTerminatedStringLocal(path)

        // Pad up to the (aligned) image file offset.
        bytes.appendPaddingLocal(to: imageFileOffset)

        // --- embedded thin arm64 Mach-O @imageFileOffset ---
        precondition(bytes.count == imageFileOffset)
        let segmentFileOffsetInCache = UInt64(imageFileOffset)
        let codeFileOffsetInCache = UInt64(imageFileOffset + imageInternalCodeOffset)
        let symtabFileOffsetInCache = UInt64(imageFileOffset + symbolTableInternalOffset)
        let strtabFileOffsetInCache = UInt64(imageFileOffset + stringTableInternalOffset)

        // mach_header_64
        bytes.appendUInt32LE(0xfeedfacf)                          // magic
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(UInt32(bitPattern: cpuSubtype))      // cpusubtype
        bytes.appendUInt32LE(MachOConstants.fileTypeDylib)        // filetype
        bytes.appendUInt32LE(includeDataInCode ? 3 : 2)           // ncmds
        bytes.appendUInt32LE(UInt32(loadCommandsSize))           // sizeofcmds
        bytes.appendUInt32LE(0)                                   // flags
        bytes.appendUInt32LE(0)                                   // reserved

        // LC_SEGMENT_64 __TEXT (covers the whole image, fileoff = cache file offset)
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCStringLocal("__TEXT", length: 16)
        bytes.appendUInt64LE(segmentVMAddress)                   // vmaddr
        bytes.appendUInt64LE(segmentVMSize)                      // vmsize
        bytes.appendUInt64LE(segmentFileOffsetInCache)          // fileoff (cache-relative)
        bytes.appendUInt64LE(UInt64(imageTotalSize))            // filesize
        bytes.appendUInt32LE(5)                                  // maxprot
        bytes.appendUInt32LE(5)                                  // initprot
        bytes.appendUInt32LE(1)                                  // nsects
        bytes.appendUInt32LE(0)                                  // flags
        // section __text
        bytes.appendFixedCStringLocal("__text", length: 16)
        bytes.appendFixedCStringLocal("__TEXT", length: 16)
        bytes.appendUInt64LE(textVMAddress)                     // addr
        bytes.appendUInt64LE(UInt64(code.count))               // size
        bytes.appendUInt32LE(UInt32(codeFileOffsetInCache))    // offset (cache-relative)
        bytes.appendUInt32LE(2)                                 // align
        bytes.appendUInt32LE(0)                                 // reloff
        bytes.appendUInt32LE(0)                                 // nreloc
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )                                                       // flags
        bytes.appendUInt32LE(0)                                 // reserved1
        bytes.appendUInt32LE(0)                                 // reserved2
        bytes.appendUInt32LE(0)                                 // reserved3

        // LC_SYMTAB
        bytes.appendUInt32LE(MachOConstants.loadCommandSymtab)
        bytes.appendUInt32LE(UInt32(symtabCommandSize))
        bytes.appendUInt32LE(UInt32(symtabFileOffsetInCache))  // symoff (cache-relative)
        bytes.appendUInt32LE(1)                                 // nsyms
        bytes.appendUInt32LE(UInt32(strtabFileOffsetInCache))  // stroff (cache-relative)
        bytes.appendUInt32LE(UInt32(stringTable.count))        // strsize

        if includeDataInCode {
            bytes.appendUInt32LE(MachOConstants.loadCommandDataInCode)
            bytes.appendUInt32LE(UInt32(dataInCodeCommandSize))
            bytes.appendUInt32LE(UInt32(imageFileOffset + dataInCodeInternalOffset))
            bytes.appendUInt32LE(8)
        }

        // code
        precondition(bytes.count == Int(codeFileOffsetInCache))
        bytes.append(code)

        // symbol table: one nlist_64 -> "_fixtureEntry" at textVMAddress.
        precondition(bytes.count == Int(symtabFileOffsetInCache))
        bytes.appendUInt32LE(1)                                 // n_strx (1 = skip leading NUL)
        bytes.append(0x0f)                                     // n_type: N_SECT | N_EXT
        bytes.append(1)                                        // n_sect
        bytes.appendUInt16LE(0)                                // n_desc
        bytes.appendUInt64LE(textVMAddress)                   // n_value

        // string table
        precondition(bytes.count == Int(strtabFileOffsetInCache))
        bytes.append(stringTable)

        if includeDataInCode {
            precondition(bytes.count == imageFileOffset + dataInCodeInternalOffset)
            bytes.appendUInt32LE(UInt32(codeFileOffsetInCache + 4))
            bytes.appendUInt16LE(4)
            bytes.appendUInt16LE(MachOConstants.dataInCodeKindData)
        }

        return DyldCacheFixture(
            bytes: bytes,
            mappingOffset: mappingOffset,
            imagesOffset: imagesOffset,
            imageRecordOffset: imageRecordOffset,
            imageFileOffset: imageFileOffset,
            imageVMAddress: imageVMAddress,
            textVMAddress: textVMAddress,
            code: code
        )
    }

    private static func makeStringTable() -> Data {
        var table = Data()
        table.append(0)                                  // leading NUL
        table.append(contentsOf: "_fixtureEntry".utf8)
        table.append(0)
        return table
    }
}

// MARK: - Split (multi-sub-cache) fixture

/// Builds a SPLIT dyld shared cache: a main file holding the image's mach_header + __TEXT,
/// plus a `.symbols` sibling sub-cache holding the shared __LINKEDIT (the symtab + strtab).
/// The image's __LINKEDIT segment's VM range is mapped ONLY by the sibling, so recovering
/// the symbol "_splitEntry" requires stitching the two files via the MultiFileCacheReader.
///
/// `makeImageInSibling()` is a degraded variant where the image's mach_header itself is
/// mapped only by the (unprovided) sibling, exercising the typed `.subCacheOnly` refusal.
struct DyldSplitCacheFixture {
    var mainBytes: Data
    var symbolsBytes: Data
    var imageVMAddress: UInt64
    var linkeditVMAddress: UInt64

    static func make() -> DyldSplitCacheFixture {
        build(imageMappedInMain: true)
    }

    static func makeImageInSibling() -> DyldSplitCacheFixture {
        build(imageMappedInMain: false)
    }

    /// arm64 code (ret/nop/nop/ret) embedded in the image __TEXT.
    private static let code = Data([
        0xc0, 0x03, 0x5f, 0xd6,
        0x1f, 0x20, 0x03, 0xd5,
        0x1f, 0x20, 0x03, 0xd5,
        0xc0, 0x03, 0x5f, 0xd6
    ])

    private static func makeStringTable() -> Data {
        var table = Data()
        table.append(0)
        table.append(contentsOf: "_splitEntry".utf8)
        table.append(0)
        return table
    }

    // swiftlint:disable:next function_body_length
    private static func build(imageMappedInMain: Bool) -> DyldSplitCacheFixture {
        let headerSize = 0x200
        let mappingOffset = headerSize
        let mappingSize = 32
        let imagesOffset = mappingOffset + mappingSize
        let imageRecordSize = 32
        let pathOffset = imagesOffset + imageRecordSize
        let path = "/usr/lib/libSplit.dylib"

        // Sub-cache entry array placed after the path string (v2: 56-byte entry).
        var subCacheArrayOffset = pathOffset + path.utf8.count + 1
        subCacheArrayOffset = (subCacheArrayOffset + 0x7) & ~0x7

        // --- image Mach-O layout (within the image) ---
        let machOHeaderSize = 32
        let textSegCmdSize = 72 + 80          // segment + 1 section
        let linkeditSegCmdSize = 72           // segment, no sections
        let symtabCmdSize = 24
        let loadCommandsSize = textSegCmdSize + linkeditSegCmdSize + symtabCmdSize
        let codeInternalOffset = machOHeaderSize + loadCommandsSize
        let textSegInternalSize = codeInternalOffset + code.count

        // The embedded Mach-O starts here in the MAIN file (after the sub-cache array).
        var imageFileOffset = subCacheArrayOffset + 56
        imageFileOffset = (imageFileOffset + 0xF) & ~0xF

        let imageVMAddress: UInt64 = 0x1_8000_0000
        let textVMAddress = imageVMAddress + UInt64(codeInternalOffset)

        // __LINKEDIT lives in its OWN VM range, far from the image, mapped by the sibling.
        let linkeditVMAddress: UInt64 = 0x2_0000_0000
        let stringTable = makeStringTable()
        let linkeditSize = 16 + stringTable.count  // one nlist_64 + strtab
        // The image's __LINKEDIT segment fileoff is a (synthetic) cache file offset that the
        // symtab offsets index into; the actual bytes are resolved by VM address.
        let linkeditCacheFileOffset: UInt64 = 0x10_0000
        let symoff = linkeditCacheFileOffset
        let stroff = linkeditCacheFileOffset + 16

        // The main mapping covers the image's __TEXT bytes.
        let textSpan = UInt64(textSegInternalSize)
        // When imageMappedInMain is false, push the main mapping's VM base elsewhere so the
        // image header address is NOT covered by the main file.
        let mainMapVMBase = imageMappedInMain ? imageVMAddress : (imageVMAddress + 0x10_0000_0000)

        var bytes = Data()
        // dyld_cache_header
        bytes.appendFixedCStringLocal("dyld_v1  arm64e", length: 16)
        bytes.appendUInt32LE(UInt32(mappingOffset))   // @16
        bytes.appendUInt32LE(1)                        // @20 mappingCount
        bytes.appendUInt32LE(UInt32(imagesOffset))     // @24
        bytes.appendUInt32LE(1)                        // @28 imagesCount
        bytes.appendPaddingLocal(to: 0x188)
        bytes.appendUInt32LE(UInt32(subCacheArrayOffset)) // @0x188 subCacheArrayOffset
        bytes.appendUInt32LE(1)                            // @0x18C subCacheArrayCount
        bytes.appendPaddingLocal(to: headerSize)

        // mapping_info: cover [mainMapVMBase, +textSpan) -> [imageFileOffset, +textSpan)
        precondition(bytes.count == mappingOffset)
        bytes.appendUInt64LE(mainMapVMBase)
        bytes.appendUInt64LE(textSpan)
        bytes.appendUInt64LE(UInt64(imageFileOffset))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)

        // image_info
        precondition(bytes.count == imagesOffset)
        bytes.appendUInt64LE(imageVMAddress)
        bytes.appendUInt64LE(0)
        bytes.appendUInt64LE(0)
        bytes.appendUInt32LE(UInt32(pathOffset))
        bytes.appendUInt32LE(0)

        // path
        precondition(bytes.count == pathOffset)
        bytes.appendNullTerminatedStringLocal(path)

        // sub-cache entry array (v2: uuid[16] + cacheVMOffset(u64) + fileSuffix[32])
        bytes.appendPaddingLocal(to: subCacheArrayOffset)
        bytes.append(contentsOf: repeatElement(UInt8(0xAB), count: 16)) // uuid
        bytes.appendUInt64LE(linkeditVMAddress - imageVMAddress)        // cacheVMOffset
        bytes.appendFixedCStringLocal(".symbols", length: 32)          // fileSuffix

        // embedded Mach-O
        bytes.appendPaddingLocal(to: imageFileOffset)
        precondition(bytes.count == imageFileOffset)
        let segTextFileOffsetInCache = UInt64(imageFileOffset)
        let codeFileOffsetInCache = UInt64(imageFileOffset + codeInternalOffset)

        // mach_header_64 (ncmds = 3)
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeDylib)
        bytes.appendUInt32LE(3)                                   // ncmds
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        // LC_SEGMENT_64 __TEXT
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(textSegCmdSize))
        bytes.appendFixedCStringLocal("__TEXT", length: 16)
        bytes.appendUInt64LE(imageVMAddress)                     // vmaddr
        bytes.appendUInt64LE(textSpan)                            // vmsize
        bytes.appendUInt64LE(segTextFileOffsetInCache)           // fileoff (cache-relative)
        bytes.appendUInt64LE(textSpan)                            // filesize
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)                                  // nsects
        bytes.appendUInt32LE(0)
        // section __text
        bytes.appendFixedCStringLocal("__text", length: 16)
        bytes.appendFixedCStringLocal("__TEXT", length: 16)
        bytes.appendUInt64LE(textVMAddress)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeFileOffsetInCache))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        // LC_SEGMENT_64 __LINKEDIT (no sections); bytes live in the sibling by vmaddr.
        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(linkeditSegCmdSize))
        bytes.appendFixedCStringLocal("__LINKEDIT", length: 16)
        bytes.appendUInt64LE(linkeditVMAddress)                  // vmaddr
        bytes.appendUInt64LE(UInt64(linkeditSize))               // vmsize
        bytes.appendUInt64LE(linkeditCacheFileOffset)            // fileoff (cache-relative)
        bytes.appendUInt64LE(UInt64(linkeditSize))               // filesize
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)                                  // nsects
        bytes.appendUInt32LE(0)

        // LC_SYMTAB (symoff/stroff index the __LINKEDIT region)
        bytes.appendUInt32LE(MachOConstants.loadCommandSymtab)
        bytes.appendUInt32LE(UInt32(symtabCmdSize))
        bytes.appendUInt32LE(UInt32(symoff))
        bytes.appendUInt32LE(1)                                  // nsyms
        bytes.appendUInt32LE(UInt32(stroff))
        bytes.appendUInt32LE(UInt32(stringTable.count))

        // code
        precondition(bytes.count == Int(codeFileOffsetInCache))
        bytes.append(code)

        // --- sibling .symbols sub-cache ---
        // Its own dyld header + 1 mapping covering the __LINKEDIT VM range, with the
        // symtab + strtab bytes placed at the mapped file offset.
        var sibling = Data()
        let sibHeaderSize = 0x200
        let sibMappingOffset = sibHeaderSize
        let sibLinkeditFileOffset = sibMappingOffset + 32
        sibling.appendFixedCStringLocal("dyld_v1  arm64e", length: 16)
        sibling.appendUInt32LE(UInt32(sibMappingOffset)) // @16
        sibling.appendUInt32LE(1)                         // @20 mappingCount
        sibling.appendUInt32LE(0)                         // @24 imagesOffset (none)
        sibling.appendUInt32LE(0)                         // @28 imagesCount
        sibling.appendPaddingLocal(to: sibHeaderSize)
        sibling.replaceSubrange(0x58..<0x68, with: repeatElement(UInt8(0xAB), count: 16))
        // mapping: [linkeditVMAddress, +linkeditSize) -> [sibLinkeditFileOffset, +linkeditSize)
        precondition(sibling.count == sibMappingOffset)
        sibling.appendUInt64LE(linkeditVMAddress)
        sibling.appendUInt64LE(UInt64(linkeditSize))
        sibling.appendUInt64LE(UInt64(sibLinkeditFileOffset))
        sibling.appendUInt32LE(1)
        sibling.appendUInt32LE(1)
        // __LINKEDIT payload: nlist_64 (_splitEntry @ textVMAddress) + string table.
        precondition(sibling.count == sibLinkeditFileOffset)
        sibling.appendUInt32LE(1)            // n_strx (skip leading NUL)
        sibling.append(0x0f)                 // n_type N_SECT|N_EXT
        sibling.append(1)                    // n_sect
        sibling.appendUInt16LE(0)            // n_desc
        sibling.appendUInt64LE(textVMAddress)
        sibling.append(stringTable)

        return DyldSplitCacheFixture(
            mainBytes: bytes,
            symbolsBytes: sibling,
            imageVMAddress: imageVMAddress,
            linkeditVMAddress: linkeditVMAddress
        )
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (8 * UInt64(i))) & 0xff)) }
    }

    mutating func replaceUInt32LE(at offset: Int, with value: UInt32) {
        let base = startIndex + offset
        self[base] = UInt8(value & 0xff)
        self[base + 1] = UInt8((value >> 8) & 0xff)
        self[base + 2] = UInt8((value >> 16) & 0xff)
        self[base + 3] = UInt8((value >> 24) & 0xff)
    }

    mutating func replaceUInt64LE(at offset: Int, with value: UInt64) {
        let base = startIndex + offset
        for i in 0..<8 { self[base + i] = UInt8((value >> (8 * UInt64(i))) & 0xff) }
    }

    mutating func appendFixedCStringLocal(_ string: String, length: Int) {
        let raw = Array(string.utf8.prefix(length))
        append(contentsOf: raw)
        append(contentsOf: repeatElement(UInt8(0), count: Swift.max(0, length - raw.count)))
    }

    mutating func appendNullTerminatedStringLocal(_ string: String) {
        append(contentsOf: string.utf8)
        append(0)
    }

    mutating func appendPaddingLocal(to targetCount: Int) {
        precondition(count <= targetCount, "fixture overran target \(targetCount) at \(count)")
        append(contentsOf: repeatElement(UInt8(0), count: targetCount - count))
    }
}

private struct UnavailableCacheFixtureLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}


/// Header metadata is rewritten; the separate immutable executable segment is unchanged.
private enum DyldNativeAuthorityFixture {
    static let base: UInt64 = 0x1_8000_0000
    static func make(slideVersion: UInt32 = 5) -> Data {
        var data = Data(repeating: 0, count: 0x3000)
        func u32(_ offset: Int, _ value: UInt32) { data.replaceUInt32LE(at: offset, with: value) }
        func u64(_ offset: Int, _ value: UInt64) { data.replaceUInt64LE(at: offset, with: value) }
        func string(_ offset: Int, _ value: String) {
            data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
        }
        string(0, "dyld_v1  arm64e")
        u32(16, 0x200); u32(20, 1); u32(24, 0x240); u32(28, 1); u64(0xe0, base)
        u64(0x200, base); u64(0x208, 0x2000); u64(0x210, 0x1000)
        u32(0x218, 5); u32(0x21c, 5)
        u64(0x240, base); u32(0x258, 0x280); string(0x280, "/usr/lib/libNativeFixture.dylib")
        u32(0x138, 0x300); u32(0x13c, 1)
        u64(0x300, base); u64(0x308, 0x2000); u64(0x310, 0x1000)
        u64(0x318, 0x400); u64(0x320, 28); u32(0x330, 5); u32(0x334, 5)
        u32(0x400, slideVersion); u32(0x404, 4096); u32(0x408, 2); u64(0x410, base)
        u32(0x418, 0xffffffff)
        u32(0x1000, 0xfeedfacf); u32(0x1004, 0x0100000c); u32(0x100c, 6)
        u32(0x1010, 3); u32(0x1014, 72 + 152 + 24)
        for index in 0..<2 {
            let command = 0x1020 + index * 72
            u32(command, 0x19); u32(command + 4, index == 0 ? 72 : 152)
            string(command + 8, index == 0 ? "__TEXT" : "__TEXT_EXEC")
            u64(command + 24, base + UInt64(index) * 0x1000); u64(command + 32, 0x1000)
            u64(command + 40, UInt64(0x1000 + index * 0x1000)); u64(command + 48, 0x1000)
            u32(command + 56, index == 0 ? 1 : 5); u32(command + 60, index == 0 ? 1 : 5)
            if index == 1 {
                u32(command + 64, 1)
                let section = command + 72
                string(section, "__text"); string(section + 16, "__TEXT_EXEC")
                u64(section + 32, base + 0x1000); u64(section + 40, 8)
                u32(section + 48, 0x2000); u32(section + 52, 2); u32(section + 64, 0x80000400)
            }
        }
        let uuid = 0x1020 + 72 + 152
        u32(uuid, 0x1b); u32(uuid + 4, 24)
        data.replaceSubrange((uuid + 8)..<(uuid + 24), with: repeatElement(UInt8(0x22), count: 16))
        u32(0x2000, 0xd65f03c0); u32(0x2004, 0xd503201f)
        return data
    }
}

/// Executable header segment plus a non-executable immutable segment. Both pages
/// carry complete slide evidence; omitted metadata still produces normal findings.
private enum DyldTextAuthorityFixture {
    static let base: UInt64 = 0x1_8000_0000
    static func make(textSlideSlot: Bool = false, fixupCommand: UInt32? = nil, fixupSize: UInt32 = 0) -> Data {
        var data = Data(repeating: 0, count: 0x3000)
        func u32(_ offset: Int, _ value: UInt32) { data.replaceUInt32LE(at: offset, with: value) }
        func u64(_ offset: Int, _ value: UInt64) { data.replaceUInt64LE(at: offset, with: value) }
        func string(_ offset: Int, _ value: String) {
            data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
        }
        string(0, "dyld_v1  arm64e")
        u32(16, 0x200); u32(20, 2); u32(24, 0x250); u32(28, 1); u64(0xe0, base)
        u64(0x250, base); u32(0x268, 0x280); string(0x280, "/usr/lib/libTextFixture.dylib")
        u32(0x138, 0x300); u32(0x13c, 2)
        for index in 0..<2 {
            let mapping = 0x200 + index * 32
            let slide = 0x300 + index * 56
            let protection: UInt32 = index == 0 ? 5 : 1
            for record in [mapping, slide] {
                u64(record, base + UInt64(index) * 0x1000)
                u64(record + 8, 0x1000); u64(record + 16, UInt64(0x1000 + index * 0x1000))
            }
            u32(mapping + 24, protection); u32(mapping + 28, protection)
            u32(slide + 48, protection); u32(slide + 52, protection)
            u64(slide + 24, UInt64(0x400 + index * 32)); u64(slide + 32, 26)
            let info = 0x400 + index * 32
            u32(info, 5); u32(info + 4, 4096); u32(info + 8, 1); u64(info + 16, base)
            u32(info + 24, index == 0 && textSlideSlot ? 0x900 : 0xffff)
        }
        u32(0x1000, 0xfeedfacf); u32(0x1004, 0x0100000c); u32(0x100c, 6)
        u32(0x1010, fixupCommand == nil ? 5 : 6)
        let baseCommandBytes: UInt32 = 152 + 72 + 24 + 80 + 16
        let fixupCommandBytes: UInt32 = fixupCommand == nil ? 0 : 16
        u32(0x1014, baseCommandBytes + fixupCommandBytes)
        var command = 0x1020
        for index in 0..<2 {
            let size: UInt32 = index == 0 ? 152 : 72
            let protection: UInt32 = index == 0 ? 5 : 1
            u32(command, 0x19); u32(command + 4, size)
            string(command + 8, index == 0 ? "__TEXT" : "__OBJC_RO")
            u64(command + 24, base + UInt64(index) * 0x1000); u64(command + 32, 0x1000)
            u64(command + 40, UInt64(0x1000 + index * 0x1000)); u64(command + 48, 0x1000)
            u32(command + 56, protection); u32(command + 60, protection)
            if index == 0 {
                u32(command + 64, 1)
                let section = command + 72
                string(section, "__text"); string(section + 16, "__TEXT")
                u64(section + 32, base + 0x800); u64(section + 40, 8)
                u32(section + 48, 0x1800); u32(section + 52, 2); u32(section + 64, 0x80000400)
            }
            command += Int(size)
        }
        u32(command, 0x1b); u32(command + 4, 24)
        data.replaceSubrange((command + 8)..<(command + 24), with: repeatElement(UInt8(0x33), count: 16))
        command += 24
        u32(command, 0xb); u32(command + 4, 80); u32(command + 56, 0x2000); u32(command + 60, 1)
        command += 80
        u32(command, 0x1d); u32(command + 4, 16); u32(command + 8, 0x2100); u32(command + 12, 8)
        command += 16
        if let fixupCommand {
            u32(command, fixupCommand); u32(command + 4, 16)
            u32(command + 8, 0x2200); u32(command + 12, fixupSize)
        }
        u32(0x1800, 0xd65f03c0); u32(0x1804, 0xd503201f)
        if textSlideSlot { u64(0x1900, 0x800) }
        return data
    }
}
