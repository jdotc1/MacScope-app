import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerFileBackedCaveTests: XCTestCase {
    private let slot = ImageSlot.primary
    private let entry: UInt64 = 0x10d0
    private let cave: UInt64 = 0x10f0

    func testPatchedBranchAndFileBackedCaveProduceBoundSparseRequest() throws {
        var (snapshot, functionID) = try fixture()
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x08, 0x00, 0x00, 0x14]) // b 0x10f0
        )
        snapshot.addressOverrides[ImageAddress(slot: slot, address: cave)] = .init(
            patch: BytePatch(bytes: [0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        let projection = try NativeDecompilerSnapshotBuilder.build(
            from: snapshot, imageSlot: slot, functionID: functionID,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )
        XCTAssertEqual(projection.function.codeRanges?.map { $0.startAddress.value }, [entry, cave])
        XCTAssertEqual(projection.function.codeRanges?.map { $0.endAddressExclusive.value },
                       [entry + 4, cave + 8])
        XCTAssertEqual(projection.function.endAddressExclusive.value, cave + 8)
        let bound = try NativeDecompilerRequestProjection(snapshotProjection: projection)
        XCTAssertEqual(bound.schemaVersion, NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion)
        let requestID = UUID()
        let envelope = bound.makeRequestEnvelope(requestID: requestID)
        let codec = NativeDecompilerWireCodec()
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(envelope, matching: requestID),
                                              matching: requestID), envelope)
        let caveRegion = try XCTUnwrap(projection.memoryRegions.first(where: {
            $0.startAddress.value <= cave &&
                cave + 8 <= $0.startAddress.value + UInt64($0.rawBytes.count)
        }))
        let slice = Int(cave - caveRegion.startAddress.value)..<Int(cave - caveRegion.startAddress.value + 8)
        XCTAssertEqual(caveRegion.rawBytes.subdata(in: slice), Data(repeating: 0, count: 8))
        XCTAssertEqual(caveRegion.effectiveBytes.subdata(in: slice),
                       Data([0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]))
        XCTAssertGreaterThanOrEqual(
            caveRegion.startAddress.value + UInt64(caveRegion.rawBytes.count),
            cave + 8 + NativeDecompilerSnapshotBuilder.decoderLookaheadBytes
        )
        XCTAssertFalse(caveRegion.appliedPatchIDs.isEmpty)
    }

    func testNextFunctionBoundaryIncludesInertTailPaddingWithoutAdmittingItAsCode() throws {
        var (snapshot, functionID) = try fixture()
        let binary = try XCTUnwrap(snapshot.binaries.first)
        snapshot.mutateAnalysis(in: slot) { analysis in
            // The real analysis engine records [start, next function start), so
            // alignment padding belongs to this nominal function extent.
            analysis.functions[0].endAddress = cave + 8
            analysis.analysisInputFingerprint = try? AnalysisFingerprintBuilder.fingerprint(
                binary: binary, analysis: analysis
            )
        }
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x08, 0x00, 0x00, 0x14])
        )
        XCTAssertThrowsError(try project(snapshot, functionID: functionID)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError,
                           .patchedControlFlowLeavesFunction)
        }
        snapshot.addressOverrides[ImageAddress(slot: slot, address: cave)] = .init(
            patch: BytePatch(bytes: [0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        let projection = try project(snapshot, functionID: functionID)
        XCTAssertEqual(projection.function.codeRanges?.map { $0.startAddress.value }, [entry, cave])
        XCTAssertEqual(projection.function.codeRanges?.map { $0.endAddressExclusive.value },
                       [entry + 4, cave + 8])
    }

    func testAdjacentPostReturnPaddingCanFormTheCave() throws {
        var (snapshot, functionID) = try fixture()
        let adjacentCave = entry + 4
        let binary = try XCTUnwrap(snapshot.binaries.first)
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.functions[0].endAddress = adjacentCave + 8
            analysis.analysisInputFingerprint = try? AnalysisFingerprintBuilder.fingerprint(
                binary: binary, analysis: analysis
            )
        }
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x01, 0x00, 0x00, 0x14]) // b +4
        )
        snapshot.addressOverrides[ImageAddress(slot: slot, address: adjacentCave)] = .init(
            patch: BytePatch(bytes: [0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        let projection = try project(snapshot, functionID: functionID)
        XCTAssertEqual(projection.function.codeRanges?.map { $0.startAddress.value },
                       [entry, adjacentCave])
        XCTAssertEqual(projection.function.codeRanges?.map { $0.endAddressExclusive.value },
                       [adjacentCave, adjacentCave + 8])
    }

    func testUndoRestoresContiguousRequestIdentity() throws {
        var (snapshot, functionID) = try fixture()
        let original = try NativeDecompilerRequestProjection(
            snapshotProjection: project(snapshot, functionID: functionID)
        )
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x08, 0x00, 0x00, 0x14])
        )
        snapshot.addressOverrides[ImageAddress(slot: slot, address: cave)] = .init(
            patch: BytePatch(bytes: [0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        let patched = try NativeDecompilerRequestProjection(
            snapshotProjection: project(snapshot, functionID: functionID)
        )
        XCTAssertEqual(patched.schemaVersion, NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion)
        XCTAssertNotEqual(patched.requestSHA256, original.requestSHA256)

        snapshot.addressOverrides.removeValue(forKey: ImageAddress(slot: slot, address: entry))
        snapshot.addressOverrides.removeValue(forKey: ImageAddress(slot: slot, address: cave))
        let restored = try NativeDecompilerRequestProjection(
            snapshotProjection: project(snapshot, functionID: functionID)
        )
        XCTAssertEqual(restored.schemaVersion, original.schemaVersion)
        XCTAssertEqual(restored.requestSHA256, original.requestSHA256)
    }

    func testCaveMustBePatchAuthoredAndOutsideCompetingFunction() throws {
        var (snapshot, functionID) = try fixture()
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x08, 0x00, 0x00, 0x14])
        )
        XCTAssertThrowsError(try project(snapshot, functionID: functionID)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError,
                           .patchedControlFlowLeavesFunction)
        }
        snapshot.addressOverrides[ImageAddress(slot: slot, address: cave)] = .init(
            patch: BytePatch(bytes: [0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.functions.append(.init(id: UUID(), name: "other", startAddress: cave,
                                            endAddress: cave + 8, confidence: 1))
            analysis.analysisInputFingerprint = nil
        }
        // Restore the fingerprint for the changed analysis; the competing function,
        // rather than stale input authority, must drive this refusal.
        let binary = try XCTUnwrap(snapshot.binaries.first)
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.analysisInputFingerprint = try? AnalysisFingerprintBuilder.fingerprint(
                binary: binary, analysis: analysis
            )
        }
        XCTAssertThrowsError(try project(snapshot, functionID: functionID)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError,
                           .patchedControlFlowLeavesFunction)
        }
    }

    func testCaveRefusesRelocationAndDeclaredInlineData() throws {
        var (snapshot, functionID) = try fixture()
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x08, 0x00, 0x00, 0x14])
        )
        snapshot.addressOverrides[ImageAddress(slot: slot, address: cave)] = .init(
            patch: BytePatch(bytes: [0xe0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        let binary = try XCTUnwrap(snapshot.binaries.first)
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.relocations = [RelocationSummary(
                id: UUID(), address: cave + 4, sectionName: "__TEXT,__text",
                typeCode: 2, typeName: nil, symbolName: nil, symbolIndex: nil,
                addend: nil, widthInBytes: 4
            )]
            analysis.analysisInputFingerprint = try? AnalysisFingerprintBuilder.fingerprint(
                binary: binary, analysis: analysis
            )
        }
        XCTAssertThrowsError(try project(snapshot, functionID: functionID)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError,
                           .intersectingRelocation)
        }
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.relocations.removeAll()
            analysis.codeDataRanges = [CodeDataRangeSummary(
                id: UUID(), address: cave, size: 8, kind: "data"
            )]
            analysis.analysisInputFingerprint = try? AnalysisFingerprintBuilder.fingerprint(
                binary: binary, analysis: analysis
            )
        }
        XCTAssertThrowsError(try project(snapshot, functionID: functionID)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError,
                           .patchedControlFlowLeavesFunction)
        }
    }

    func testCaveRefusesUnreachablePatchAuthoredWords() throws {
        var (snapshot, functionID) = try fixture()
        snapshot.addressOverrides[ImageAddress(slot: slot, address: entry)] = .init(
            patch: BytePatch(bytes: [0x08, 0x00, 0x00, 0x14])
        )
        snapshot.addressOverrides[ImageAddress(slot: slot, address: cave)] = .init(
            patch: BytePatch(bytes: [0xc0, 0x03, 0x5f, 0xd6, 0x1f, 0x20, 0x03, 0xd5])
        )
        XCTAssertThrowsError(try project(snapshot, functionID: functionID)) { error in
            XCTAssertEqual(error as? NativeDecompilerSnapshotProjectionError,
                           .patchedControlFlowLeavesFunction)
        }
    }

    private func project(_ snapshot: WorkspaceSnapshot, functionID: UUID) throws
        -> NativeDecompilerSnapshotProjection {
        try NativeDecompilerSnapshotBuilder.build(
            from: snapshot, imageSlot: slot, functionID: functionID,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )
    }

    private func fixture() throws -> (WorkspaceSnapshot, UUID) {
        let bytes = thinMachO()
        let loaded = try MachOBinaryLoader().load(
            bytes: bytes, sourceURL: URL(fileURLWithPath: "/nonexistent/file-backed-cave.macho")
        )
        let binary = BinaryImage(
            id: UUID(), name: loaded.name, path: loaded.path,
            kind: loaded.fileTypeName, architecture: loaded.architectureDisplayName,
            artifactIdentity: loaded.artifactIdentity,
            preferredSegmentLayout: loaded.preferredSegmentLayout,
            artifactIntegrityState: loaded.artifactIntegrityState,
            resolvedExecutablePath: loaded.resolvedExecutablePath, slot: slot
        )
        let functionID = UUID()
        var analysis = ImageAnalysis(
            functions: [.init(id: functionID, name: "entry", startAddress: entry,
                              endAddress: entry + 4, confidence: 1)],
            sections: loaded.sections.map {
                SectionSummary(id: UUID(), name: $0.name, address: $0.address,
                               size: $0.size, fileOffset: $0.fileOffset,
                               isExecutable: $0.isExecutable, isZeroFill: $0.isZeroFill)
            },
            identityEffectiveByteRanges: loaded.identityEffectiveByteRanges,
            imageBytes: loaded.bytes
        )
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary, analysis: analysis
        )
        return (WorkspaceSnapshot(binaries: [binary], analysisBySlot: [slot: analysis]), functionID)
    }

    private func thinMachO() -> Data {
        var bytes = Data()
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func u64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func name(_ value: String) {
            bytes.append(contentsOf: value.utf8)
            bytes.append(Data(count: 16 - value.utf8.count))
        }
        u32(0xfeedfacf); u32(UInt32(bitPattern: MachOConstants.cpuTypeARM64)); u32(0)
        u32(MachOConstants.fileTypeExecute); u32(2); u32(176); u32(0); u32(0)
        u32(MachOConstants.loadCommandSegment64); u32(152); name("__TEXT")
        u64(0x1000); u64(384); u64(0); u64(384); u32(5); u32(5); u32(1); u32(0)
        name("__text"); name("__TEXT"); u64(entry); u64(176); u32(208); u32(2)
        u32(0); u32(0)
        u32(MachOConstants.sectionAttributePureInstructions |
            MachOConstants.sectionAttributeSomeInstructions)
        u32(0); u32(0); u32(0)
        u32(MachOConstants.loadCommandUUID); u32(24)
        bytes.append(contentsOf: (1...16).map { UInt8($0) })
        bytes.append(Data(count: 208 - bytes.count))
        u32(0xd65f03c0) // original entry ret, replaced by branch
        bytes.append(Data(count: 384 - bytes.count)) // raw zero padding, cave and decoder lookahead
        return bytes
    }
}
