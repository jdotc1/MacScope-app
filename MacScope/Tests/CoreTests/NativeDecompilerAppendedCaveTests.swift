import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerAppendedCaveTests: XCTestCase {
    private let slot = ImageSlot.primary

    @MainActor
    func testSignedAppendedCaveBindsNativeSparseRequestAndExport() throws {
        let fixture = MachOPatchWriterTests.makeSignedExecutableWithCommandSlack()
        let loaded = try MachOBinaryLoader().load(
            bytes: fixture.bytes, sourceURL: URL(fileURLWithPath: "/nonexistent/signed-cave.macho")
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
            functions: [.init(id: functionID, name: "entry", startAddress: fixture.baseAddress,
                              endAddress: fixture.baseAddress + 4, confidence: 1)],
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
        var snapshot = WorkspaceSnapshot(binaries: [binary], analysisBySlot: [slot: analysis])
        let rawProjection = try NativeDecompilerSnapshotBuilder.build(
            from: snapshot, imageSlot: slot, functionID: functionID,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )
        let authored = AppendedExecutableCaveAuthoring(
            ownerBinaryID: binary.id, functionID: functionID,
            selectedSliceSHA256: try XCTUnwrap(binary.artifactIdentity).selectedSliceSHA256,
            branchSourceAddress: fixture.baseAddress,
            codeBytes: Data([0x20, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        let store = WorkspaceStore(
            workspaceName: "Signed append", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        let script = WorkspaceScriptingAPI(store: store)
        let authoredResult = try script.execute("append-code-cave", arguments: .object([
            "functionAddress": .string("0x" + String(fixture.baseAddress, radix: 16)),
            "branchAddress": .string("0x" + String(fixture.baseAddress, radix: 16)),
            "bytes": .string("20 00 80 52 c0 03 5f d6")
        ]))
        XCTAssertEqual(authoredResult["ok"]?.boolValue, true)
        snapshot = store.snapshot
        XCTAssertEqual(snapshot.addressOverrides[
            ImageAddress(slot: slot, address: fixture.baseAddress)
        ]?.appendedExecutableCave, authored)
        let projection = try NativeDecompilerSnapshotBuilder.build(
            from: snapshot, imageSlot: slot, functionID: functionID,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )
        let bound = try NativeDecompilerRequestProjection(snapshotProjection: projection)
        let rawBound = try NativeDecompilerRequestProjection(snapshotProjection: rawProjection)
        XCTAssertEqual(bound.schemaVersion, NativeDecompilerWireRequestEnvelope.sparseCodeSchemaVersion)
        XCTAssertNotEqual(bound.requestSHA256, rawBound.requestSHA256)
        let caveRange = try XCTUnwrap(projection.function.codeRanges?.last)
        XCTAssertEqual(caveRange.startAddress.value, 0x1_0000_c000)
        XCTAssertEqual(caveRange.endAddressExclusive.value, 0x1_0000_c008)
        let appended = try XCTUnwrap(projection.memoryRegions.first(where: { $0.name == "__MSCAVE" }))
        XCTAssertEqual(appended.rawBytes.prefix(8), Data(repeating: 0, count: 8))
        XCTAssertEqual(appended.effectiveBytes.prefix(8), authored.codeBytes)
        XCTAssertGreaterThanOrEqual(appended.effectiveBytes.count, authored.codeBytes.count + 64)
        let requestID = UUID()
        let envelope = bound.makeRequestEnvelope(requestID: requestID)
        let codec = NativeDecompilerWireCodec()
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(envelope, matching: requestID),
                                              matching: requestID), envelope)

        let capture = try store.capturePatchedBinaryExport(in: slot)
        let exported = try capture.prepare()
        let bytes = try store.finishPatchedBinaryExport(exported, in: slot)
        XCTAssertEqual(bytes.subdata(in: 0xc000 ..< 0xc008), authored.codeBytes)
        // A persisted cave recipe is only valid while its function-entry anchor remains current.
        // A stale package/analysis must neither start a new export nor finish an open Save panel.
        let anchoredSnapshot = store.snapshot
        var unanchored = anchoredSnapshot
        var changedAnalysis = try XCTUnwrap(unanchored.analysisBySlot[slot])
        changedAnalysis.functions = []
        unanchored.analysisBySlot[slot] = changedAnalysis
        store.snapshot = unanchored
        XCTAssertThrowsError(try store.capturePatchedBinaryExport(in: slot)) {
            XCTAssertEqual($0 as? PatchedBinaryExportError, .invalidAppendedCaveAnchor)
        }
        XCTAssertThrowsError(try store.finishPatchedBinaryExport(exported, in: slot)) {
            XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError, .staleInvestigation)
        }
        let orphanCleared = try script.execute("append-code-cave", arguments: .object([
            "functionAddress": .string("0x" + String(fixture.baseAddress, radix: 16)),
            "clear": .bool(true)
        ]))
        XCTAssertEqual(orphanCleared["ok"]?.boolValue, true)
        XCTAssertNil(store.snapshot.addressOverrides[
            ImageAddress(slot: slot, address: fixture.baseAddress)
        ]?.appendedExecutableCave)
        store.snapshot = anchoredSnapshot
        let cleared = try script.execute("append-code-cave", arguments: .object([
            "functionAddress": .string("0x" + String(fixture.baseAddress, radix: 16)),
            "clear": .bool(true)
        ]))
        XCTAssertEqual(cleared["ok"]?.boolValue, true)
        XCTAssertThrowsError(try store.finishPatchedBinaryExport(exported, in: slot)) {
            XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError, .staleInvestigation)
        }
    }
}
