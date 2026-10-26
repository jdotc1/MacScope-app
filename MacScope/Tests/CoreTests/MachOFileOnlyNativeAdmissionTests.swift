import Foundation
import XCTest
@testable import MacScope

/// Exercise the real loader-issued attestation before projecting native memory. These bytes
/// are a parser fixture, not an executable launched by the test or a synthetic attestation.
final class MachOFileOnlyNativeAdmissionTests: XCTestCase {
    func testLoaderAndNativeBuilderAdmitFileOnlyAddressInsideMappedText() throws {
        let fixture = makeFixture()
        try withFixtureURL(bytes: fixture.bytes) { url in
            let loaded = try MachOBinaryLoader().load(at: url)
            XCTAssertEqual(loaded.artifactIntegrityState, .verified)
            XCTAssertEqual(loaded.preferredSegmentLayout?.records.map(\.name), ["__TEXT", "__DWARF"])
            XCTAssertEqual(loaded.preferredSegmentLayout?.records.last?.preferredVMSize, 0)
            let attestation = try XCTUnwrap(loaded.identityEffectiveByteRanges.first)
            XCTAssertEqual(loaded.identityEffectiveByteRanges.count, 1)
            XCTAssertEqual(attestation.segmentName, "__TEXT")
            XCTAssertEqual(attestation.startAddress, 0x1000)
            XCTAssertEqual(attestation.endAddressExclusive, 0x1100)
            XCTAssertEqual(attestation.rawBytesSHA256,
                AnalysisFingerprintBuilder.sha256Hex(fixture.bytes.subdata(in: 0..<256)))
            XCTAssertFalse(loaded.identityEffectiveByteRanges.contains { $0.segmentName == "__DWARF" })

            let projection = try build(loaded: loaded, fixture: fixture)
            XCTAssertEqual(projection.image.preferredLoadAddress.value, 0x1000)
            XCTAssertEqual(projection.function.entryAddress.value, fixture.functionStart)
            XCTAssertEqual(projection.function.endAddressExclusive.value, fixture.functionStart + 8)
            XCTAssertEqual(projection.memoryRegions.map(\.name), ["__TEXT", "__TEXT"])
            XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value },
                [fixture.functionStart, fixture.functionStart + 8])
            XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 40])
            let deliveredBytes = projection.memoryRegions.reduce(into: Data()) { $0.append($1.rawBytes) }
            XCTAssertEqual(deliveredBytes, fixture.bytes.subdata(in: 208..<256))
            XCTAssertFalse(deliveredBytes.contains(0xCD), "The file-only tail must not become VM bytes")
            XCTAssertNoThrow(try MacScope.NativeDecompilerRequestProjection(snapshotProjection: projection))
        }
    }

    func testFileOnlyFileOverlapCannotAuthorizeNativeBytes() throws {
        let fixture = makeFixture(dwarfFileOffset: 248)
        try withFixtureURL(bytes: fixture.bytes) { url in
            let loaded = try MachOBinaryLoader().load(at: url)
            XCTAssertEqual(loaded.artifactIntegrityState, .verified)
            XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
            XCTAssertThrowsError(try build(loaded: loaded, fixture: fixture)) { error in
                XCTAssertEqual(error as? MacScope.NativeDecompilerSnapshotProjectionError, .overlappingSegmentLayout)
            }
        }
    }

    func testMappedVirtualOverlapStillCannotAuthorizeNativeBytes() throws {
        let fixture = makeFixture(dwarfVMSize: 16)
        try withFixtureURL(bytes: fixture.bytes) { url in
            let loaded = try MachOBinaryLoader().load(at: url)
            XCTAssertEqual(loaded.artifactIntegrityState, .verified)
            XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
            XCTAssertThrowsError(try build(loaded: loaded, fixture: fixture)) { error in
                XCTAssertEqual(error as? MacScope.NativeDecompilerSnapshotProjectionError, .overlappingSegmentLayout)
            }
        }
    }

    func testFileOnlyFileSpanOverflowAndSliceOverrunRemainTypedFailures() throws {
        for (fixture, expected) in [
            (makeFixture(dwarfFileOffset: UInt64.max),
                MacScopeAnalysisCore.MachOSliceArtifactValidationError.invalidSegmentFileSpan(name: "__DWARF")),
            (makeFixture(dwarfFileSize: 32),
                MacScopeAnalysisCore.MachOSliceArtifactValidationError.segmentFileSpanOutsideSlice(name: "__DWARF")),
        ] {
            try withFixtureURL(bytes: fixture.bytes) { url in
                XCTAssertThrowsError(try MachOBinaryLoader().load(at: url)) { error in
                    XCTAssertEqual(error as? MacScopeAnalysisCore.MachOSliceArtifactValidationError, expected)
                }
            }
        }
    }
}

private extension MachOFileOnlyNativeAdmissionTests {
    struct Fixture {
        let bytes: Data
        let functionStart: UInt64 = 0x10D0
    }

    func build(loaded: MacScopeAnalysisCore.LoadedBinary, fixture: Fixture) throws
        -> MacScope.NativeDecompilerSnapshotProjection {
        let slot = MacScopeAnalysisCore.ImageSlot.primary
        let binary = MacScopeAnalysisCore.BinaryImage(id: UUID(), name: loaded.name, path: loaded.path,
            kind: loaded.fileTypeName, architecture: loaded.architectureDisplayName,
            artifactIdentity: loaded.artifactIdentity, preferredSegmentLayout: loaded.preferredSegmentLayout,
            artifactIntegrityState: loaded.artifactIntegrityState,
            resolvedExecutablePath: loaded.resolvedExecutablePath, slot: slot)
        let function = MacScopeAnalysisCore.FunctionSummary(id: UUID(), name: "fixture_entry",
            startAddress: fixture.functionStart, endAddress: fixture.functionStart + 8, confidence: 1)
        var analysis = MacScopeAnalysisCore.ImageAnalysis(functions: [function],
            identityEffectiveByteRanges: loaded.identityEffectiveByteRanges, imageBytes: loaded.bytes)
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        return try NativeDecompilerSnapshotBuilder.build(
            from: MacScopeAnalysisCore.WorkspaceSnapshot(binaries: [binary], analysisBySlot: [slot: analysis]),
            imageSlot: slot, functionID: function.id, budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
    }

    func withFixtureURL(bytes: Data, body: (URL) throws -> Void) throws {
        let directory = TestWorkRoot.scratchURL("macscope-m2-file-only-test-runs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file-only-fixture.macho")
        try bytes.write(to: url)
        try body(url)
    }

    func makeFixture(dwarfVMSize: UInt64 = 0, dwarfFileOffset: UInt64 = 256,
                     dwarfFileSize: UInt64 = 16) -> Fixture {
        var bytes = Data()
        func append32(_ value: UInt32) {
            Swift.withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func append64(_ value: UInt64) {
            Swift.withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func segment(_ name: String, vmStart: UInt64, vmSize: UInt64,
                     fileOffset: UInt64, fileSize: UInt64, protections: UInt32) {
            append32(MachOConstants.loadCommandSegment64)
            append32(72)
            let nameBytes = Data(name.utf8)
            bytes.append(nameBytes)
            bytes.append(Data(count: 16 - nameBytes.count))
            append64(vmStart)
            append64(vmSize)
            append64(fileOffset)
            append64(fileSize)
            append32(protections) // maxprot
            append32(protections) // initprot
            append32(0) // nsects
            append32(0) // flags
        }
        append32(0xFEEDFACF)
        append32(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        append32(0)
        append32(MachOConstants.fileTypeExecute)
        append32(3)
        append32(72 + 72 + 24)
        append32(0)
        append32(0)
        segment("__TEXT", vmStart: 0x1000, vmSize: 256, fileOffset: 0, fileSize: 256, protections: 5)
        // Empty VM extent strictly inside __TEXT; the physical file bytes remain disjoint.
        segment("__DWARF", vmStart: 0x10E0, vmSize: dwarfVMSize,
            fileOffset: dwarfFileOffset, fileSize: dwarfFileSize, protections: 1)
        append32(MachOConstants.loadCommandUUID)
        append32(24)
        bytes.append(contentsOf: (1...16).map { UInt8($0) })
        bytes.append(Data(count: 208 - bytes.count))
        append32(0xD503201F) // nop
        append32(0xD65F03C0) // ret
        bytes.append(Data(count: 256 - bytes.count))
        bytes.append(Data(repeating: 0xCD, count: 16))
        return .init(bytes: bytes)
    }
}
