import Foundation
import XCTest
@testable import MacScope

/// Two bounded witnesses share one object: duplicate executable section names and RVAs.
@MainActor
final class COFFWorkspaceCoordinateCompatibilityTests: XCTestCase {
    private func overlappingObject() -> Data {
        var bytes = Data(repeating: 0, count: 148)
        func put(_ value: UInt64, at offset: Int, count: Int) {
            for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func name(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() { bytes[offset + index] = byte }
        }
        put(0xaa64, at: 0, count: 2)
        put(2, at: 2, count: 2)
        put(108, at: 8, count: 4)
        put(2, at: 12, count: 4)
        for index in 0..<2 {
            let section = 20 + index * 40
            name(".text", at: section)
            put(4, at: section + 8, count: 4)
            put(0, at: section + 12, count: 4) // Both original RVAs are zero.
            put(4, at: section + 16, count: 4)
            put(UInt64(100 + index * 4), at: section + 20, count: 4)
            put(0x60000020, at: section + 36, count: 4)
            put(index == 0 ? 0xd65f03c0 : 0xd503201f, at: 100 + index * 4, count: 4) // ret / nop
            let symbol = 108 + index * 18
            name(index == 0 ? "first" : "second", at: symbol)
            put(UInt64(index + 1), at: symbol + 12, count: 2)
            put(0x20, at: symbol + 14, count: 2)
            put(2, at: symbol + 16, count: 1)
        }
        put(4, at: 144, count: 4)
        return bytes
    }

    private func directory() throws -> URL {
        let url = TestWorkRoot.scratch
            .appendingPathComponent("macscope-bug04-witnesses.noindex")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func roundTrip(_ snapshot: WorkspaceSnapshot, in directory: URL) throws -> WorkspaceSnapshot {
        let database = try WorkspaceDatabase(path: directory.appendingPathComponent("workspace.sqlite").path)
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceUUID: UUID(), workspaceName: "COFF compatibility",
            snapshot: snapshot, now: Date(timeIntervalSince1970: 1))
        return try XCTUnwrap(try database.loadSnapshot(workspaceID: try XCTUnwrap(saved.id)))
    }

    func testOverlappingObjectUsesStableSectionCoordinatesAndSavesLayoutMarker() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = overlappingObject()
        let url = directory.appendingPathComponent("overlap.obj")
        try bytes.write(to: url)
        let fresh = try AnalysisEngine().analyze(url: url)
        let binary = try XCTUnwrap(fresh.binary(in: .primary))
        let analysis = try XCTUnwrap(fresh.analysis(in: .primary))
        let starts: [UInt64] = [1 << 32, 2 << 32]
        XCTAssertEqual(binary.metadata.coffSectionLayoutVersion, 1)
        XCTAssertEqual(analysis.sections.map(\.address), starts)
        XCTAssertEqual(analysis.sections.map { $0.coffCoordinate?.sectionOrdinal }, [1, 2])
        XCTAssertEqual(analysis.sections.map { $0.coffCoordinate?.originalRVA }, [0, 0])
        XCTAssertEqual(analysis.functions.map(\.startAddress).sorted(), starts)
        XCTAssertEqual(analysis.functions.map(\.endAddress).sorted(), starts.map { $0 + 4 })
        XCTAssertEqual(analysis.instructions.filter { !$0.bytes.isEmpty }.map(\.address), starts)
        let mappings = FileAddressMapping.verifiedMappings(from: analysis.sections, payloadLength: bytes.count)
        for (index, address) in starts.enumerated() {
            XCTAssertEqual(RehydrationDerivedProducts.mappedBytes(in: bytes, sliceOffset: 0,
                at: address, count: 4, mappings: mappings), bytes.subdata(in: (100 + index * 4)..<(104 + index * 4)))
        }
        let saved = try roundTrip(fresh, in: directory)
        XCTAssertEqual(saved.binary(in: .primary)?.metadata.coffSectionLayoutVersion, 1)
        let store = WorkspaceStore(workspaceName: "new COFF", snapshot: saved,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        await store.rehydrateLoadedImagesSynchronouslyForTesting()
        XCTAssertEqual(store.snapshot.sections.map(\.address), starts)
        XCTAssertEqual(store.snapshot.functions, fresh.functions, "Save/reopen preserves function identity and bounds")
        XCTAssertEqual(store.snapshot.binary(in: .primary)?.metadata.coffSectionLayoutVersion, 1)
    }

    func testOldSavedWorkspaceRetainsCoordinatesAndAnnotationsUntilExplicitReanalyze() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = overlappingObject()
        let binary = BinaryImage(id: UUID(), name: "old.obj", path: "", kind: "COFF object", architecture: "arm64")
        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        analysis.functions = [.init(id: UUID(), name: "historical", startAddress: 0, endAddress: 4, confidence: 1)]
        analysis.instructions = [.init(address: 0, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
            hasBreakpoint: false, comment: "historical row")]
        let annotation = AddressOverride(customName: "historical_name", customComment: "keep original coordinate")
        var legacy = WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis])
        legacy.addressOverrides[.primary(0)] = annotation
        let saved = try roundTrip(legacy, in: directory)
        XCTAssertNil(saved.binary(in: .primary)?.metadata.coffSectionLayoutVersion)
        let store = WorkspaceStore(workspaceName: "old COFF", snapshot: saved,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        await store.rehydrateLoadedImagesSynchronouslyForTesting()
        XCTAssertEqual(store.snapshot.sections.map(\.address), [0, 0])
        XCTAssertEqual(store.snapshot.functions, saved.functions)
        XCTAssertEqual(store.snapshot.instructions, saved.instructions)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0)], annotation)
        XCTAssertNil(store.snapshot.binary(in: .primary)?.metadata.coffSectionLayoutVersion)
        // Automatic structural reflow retains the legacy layout; the user did not request migration.
        XCTAssertTrue(store.withSynchronousReanalysis { store.reanalyzeHonoringOverrides() })
        XCTAssertEqual(store.snapshot.sections.map(\.address), [0, 0])
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0)], annotation)
        XCTAssertEqual(store.snapshot.binary(in: .primary)?.metadata.coffSectionLayoutVersion, 0)
        // Only the explicit command seam requests layout 1; historical authoring stays at its address.
        XCTAssertTrue(store.withSynchronousReanalysis {
            store.reanalyzeHonoringOverrides(coffSectionLayoutVersion: 1)
        })
        XCTAssertEqual(store.snapshot.sections.map(\.address), [1 << 32, 2 << 32])
        XCTAssertEqual(store.snapshot.binary(in: .primary)?.metadata.coffSectionLayoutVersion, 1)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0)], annotation)
        // The same saved policy travels through the worker-only loader request.
        let codec = AnalysisRehydrateWireCodec()
        let request = AnalysisRehydrateRequest(imageBytes: bytes, requestedSliceIndex: nil,
            persisted: analysis, overrides: [:], coffSectionLayoutVersion: 0)
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(request)).coffSectionLayoutVersion, 0)
    }
}
