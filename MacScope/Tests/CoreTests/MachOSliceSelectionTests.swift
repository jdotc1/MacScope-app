import Foundation
import XCTest
@testable import MacScope

/// Unit tests for the pure fat/universal slice-selection logic (`MachOSliceSelector`)
/// and the open-time loader-options dialog model (`LoaderOptionsModel`). Both are
/// headless — no file I/O or SwiftUI — so the selection/default rules are pinned here.
final class MachOSliceSelectionTests: XCTestCase {

    // MARK: - Loader-observed selection facts

    func testThinFactDoesNotEchoIgnoredRequest() throws {
        let fixture = MachOFixture.makeExecutable(cpuSubtype: 2)
        let loaded = try MachOBinaryLoader(requestedSliceIndex: 7).load(
            bytes: fixture.bytes, sourceURL: URL(fileURLWithPath: "/fixture/thin"))
        let fact = try XCTUnwrap(loaded.machOSelectedSliceFact)
        XCTAssertEqual(fact.containerKind, .thin)
        XCTAssertEqual(fact.sliceCount, 1)
        XCTAssertEqual(fact.selectedSliceIndex, 0)
        XCTAssertEqual(fact.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(fact.cpuSubtype, 2)
        XCTAssertNil(fact.universalSliceIndex)
    }

    func testUniversalDefaultFactRecordsActualNonzeroChoice() throws {
        let loaded = try MachOBinaryLoader().load(
            bytes: MachOFixture.makeUniversalDualExecutable().bytes,
            sourceURL: URL(fileURLWithPath: "/fixture/universal"))
        let fact = try XCTUnwrap(loaded.machOSelectedSliceFact)
        XCTAssertEqual(fact.containerKind, .universal)
        XCTAssertEqual(fact.sliceCount, 2)
        XCTAssertEqual(fact.selectedSliceIndex, 1)
        XCTAssertEqual(fact.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertEqual(fact.cpuSubtype, loaded.cpuSubtype)
    }

    func testUniversalExplicitFactRecordsActualCPU() throws {
        let loaded = try MachOBinaryLoader(requestedSliceIndex: 0).load(
            bytes: MachOFixture.makeUniversalDualExecutable().bytes,
            sourceURL: URL(fileURLWithPath: "/fixture/universal"))
        let fact = try XCTUnwrap(loaded.machOSelectedSliceFact)
        XCTAssertEqual(fact.containerKind, .universal)
        XCTAssertEqual(fact.sliceCount, 2)
        XCTAssertEqual(fact.selectedSliceIndex, 0)
        XCTAssertEqual(fact.cpuType, MachOConstants.cpuTypeX86_64)
        // Header subtype, not a guess from the architecture label or fat table.
        XCTAssertEqual(fact.cpuSubtype, loaded.cpuSubtype)
    }

    func testSelectionFactSurvivesEngineWorkerPayload() throws {
        let url = try writeTemporaryFile(named: "FactUniversal",
            contents: MachOFixture.makeUniversalDualExecutable().bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = try AnalysisEngine().analyze(url: url)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        XCTAssertEqual(binary.selectedSliceIndex, 1)
        XCTAssertEqual(binary.machOSelectedSliceFact?.selectedSliceIndex, 1)
        let payload = AnalysisPayloadCodec.payload(from: snapshot)
        let transferred = try JSONDecoder().decode(AnalysisResultPayload.self,
            from: JSONEncoder().encode(payload))
        let received = AnalysisPayloadCodec.snapshot(from: transferred)
        XCTAssertEqual(received.binaries.first?.machOSelectedSliceFact, binary.machOSelectedSliceFact)
    }

    func testLegacyBinaryDecodeNeverInventsSelectionFact() throws {
        for legacyIndex in [nil, 0, 7] as [Int?] {
            let original = BinaryImage(id: UUID(), name: "legacy", path: "/fixture/legacy",
                kind: "Mach-O executable", architecture: "arm64", selectedSliceIndex: legacyIndex)
            let data = try JSONEncoder().encode(original)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(fields["machOSelectedSliceFact"])
            let decoded = try JSONDecoder().decode(BinaryImage.self, from: data)
            XCTAssertNil(decoded.machOSelectedSliceFact)
            XCTAssertEqual(decoded.selectedSliceIndex, legacyIndex)
            XCTAssertEqual(decoded.captureOrigin, .other)
        }
    }

    func testSelectionFactRejectsMalformedShape() throws {
        for (kind, count, index) in [
            (MachOSelectedSliceFact.ContainerKind.thin, 2, 0),
            (.thin, 1, 1), (.universal, 0, 0), (.universal, 2, -1), (.universal, 2, 2)
        ] {
            let json: [String: Any] = ["containerKind": kind.rawValue, "sliceCount": count,
                "selectedSliceIndex": index, "cpuType": 12, "cpuSubtype": 0]
            XCTAssertThrowsError(try JSONDecoder().decode(MachOSelectedSliceFact.self,
                from: JSONSerialization.data(withJSONObject: json)))
        }
        let singleton = try MachOSelectedSliceFact(containerKind: .universal, sliceCount: 1,
            selectedSliceIndex: 0, cpuType: 12, cpuSubtype: 0)
        XCTAssertEqual(singleton.containerKind, .universal)
    }

    // MARK: - Fixtures

    private func slice(_ index: Int, cpuType: Int32, offset: UInt64 = 0, size: UInt64 = 0x1000) -> MachOUniversalSlice {
        MachOUniversalSlice(index: index, cpuType: cpuType, cpuSubtype: 0, offset: offset, size: size, alignment: 0)
    }

    // MARK: - MachOSliceSelector

    func testSelectorDefaultsToArm64WhenPresent() throws {
        let slices = [
            slice(0, cpuType: MachOConstants.cpuTypeX86_64),
            slice(1, cpuType: MachOConstants.cpuTypeARM64)
        ]
        XCTAssertEqual(try MachOSliceSelector.selectedIndex(in: slices), 1)
    }

    func testSelectorFallsBackToX86WhenNoArm64() throws {
        let slices = [
            slice(0, cpuType: 0x0100_0018), // arm64_32 / unrelated
            slice(1, cpuType: MachOConstants.cpuTypeX86_64)
        ]
        XCTAssertEqual(try MachOSliceSelector.selectedIndex(in: slices), 1)
    }

    func testSelectorFallsBackToFirstWhenNeitherHostNorX86() throws {
        let slices = [
            slice(0, cpuType: 0x0000_0012), // PowerPC-ish placeholder
            slice(1, cpuType: 0x0000_0007)  // i386-ish placeholder
        ]
        XCTAssertEqual(try MachOSliceSelector.selectedIndex(in: slices), 0)
    }

    func testSelectorHonorsInRangeExplicitRequest() throws {
        let slices = [
            slice(0, cpuType: MachOConstants.cpuTypeX86_64),
            slice(1, cpuType: MachOConstants.cpuTypeARM64)
        ]
        // Explicit request overrides the arm64 default.
        XCTAssertEqual(try MachOSliceSelector.selectedIndex(in: slices, requestedIndex: 0), 0)
    }

    func testSelectorThrowsForOutOfRangeExplicitRequest() {
        let slices = [slice(0, cpuType: MachOConstants.cpuTypeARM64)]
        XCTAssertThrowsError(try MachOSliceSelector.selectedIndex(in: slices, requestedIndex: 7)) { error in
            XCTAssertEqual(error as? MachOSliceSelector.SelectionError, .requestedIndexOutOfRange(7))
        }
    }

    func testSelectorThrowsForEmptySliceList() {
        XCTAssertThrowsError(try MachOSliceSelector.selectedIndex(in: [])) { error in
            XCTAssertEqual(error as? MachOSliceSelector.SelectionError, .noSlices)
        }
    }

    func testSelectorResolvesSelectedSlice() throws {
        let slices = [
            slice(0, cpuType: MachOConstants.cpuTypeX86_64, offset: 0x40),
            slice(1, cpuType: MachOConstants.cpuTypeARM64, offset: 0x4000)
        ]
        let selected = try MachOSliceSelector.selectedSlice(in: slices)
        XCTAssertEqual(selected.index, 1)
        XCTAssertEqual(selected.offset, 0x4000)
    }

    // MARK: - LoaderOptionsModel

    private func option(_ index: Int, arch: String, offset: UInt64 = 0, size: UInt64 = 0x1000) -> LoaderSliceOption {
        LoaderSliceOption(index: index, architectureName: arch, offset: offset, size: size)
    }

    func testLoaderModelThinBinaryNeedsNoChoice() {
        let model = LoaderOptionsModel(fileName: "thin", formatDescription: "Mach-O executable, arm64", slices: [])
        XCTAssertFalse(model.requiresChoice)
        XCTAssertFalse(model.isUniversal)
        XCTAssertNil(model.selectedSliceIndex)
        XCTAssertNil(model.requestedSliceIndexForLoad)
    }

    func testLoaderModelUniversalRequiresChoiceAndDefaultsToArm64() {
        let model = LoaderOptionsModel(
            fileName: "fat",
            formatDescription: "Universal Mach-O executable — 2 slices",
            slices: [option(0, arch: "x86_64"), option(1, arch: "arm64")]
        )
        XCTAssertTrue(model.requiresChoice)
        XCTAssertTrue(model.isUniversal)
        // Default mirrors the loader rule: arm64 preferred.
        XCTAssertEqual(model.selectedSliceIndex, 1)
        XCTAssertEqual(model.requestedSliceIndexForLoad, 1)
    }

    func testLoaderModelHonorsExplicitDefaultIndexWhenInRange() {
        let model = LoaderOptionsModel(
            fileName: "fat",
            formatDescription: "Universal",
            slices: [option(0, arch: "x86_64"), option(1, arch: "arm64")],
            defaultSelectedIndex: 0
        )
        XCTAssertEqual(model.selectedSliceIndex, 0)
    }

    func testLoaderModelSelectChangesSelectionOnlyForValidIndex() {
        var model = LoaderOptionsModel(
            fileName: "fat",
            formatDescription: "Universal",
            slices: [option(0, arch: "x86_64"), option(1, arch: "arm64")]
        )
        model.select(index: 0)
        XCTAssertEqual(model.selectedSliceIndex, 0)
        // Out-of-range pick is ignored — selection stays put.
        model.select(index: 9)
        XCTAssertEqual(model.selectedSliceIndex, 0)
    }

    func testLoaderModelSingleSliceUniversalDoesNotRequireChoice() {
        let model = LoaderOptionsModel(
            fileName: "fat",
            formatDescription: "Universal",
            slices: [option(0, arch: "arm64")]
        )
        XCTAssertFalse(model.requiresChoice)
        XCTAssertTrue(model.isUniversal)
        XCTAssertEqual(model.selectedSliceIndex, 0)
    }

    // MARK: - LoaderOptionsInspector (end-to-end against fixture bytes)

    func testInspectorReportsUniversalSlicesForFatBinary() throws {
        let fixture = MachOFixture.makeUniversalDualExecutable()
        let url = try writeTemporaryFile(named: "FixtureFat", contents: fixture.bytes)

        let model = LoaderOptionsInspector().inspect(url: url)
        XCTAssertTrue(model.requiresChoice)
        XCTAssertEqual(model.slices.map(\.architectureName), ["x86_64", "arm64"])
        XCTAssertEqual(model.selectedSliceIndex, 1) // arm64 default
    }

    /// /usr/bin/vim ships x86_64 + arm64e + arm64e.x1; both arm64-family slices used to be
    /// labelled "arm64". The fat entries carry the PAC capability byte (0x80) like the real file.
    func testInspectorLabelsArm64eSubtypeSlicesDistinctly() throws {
        let slice = MachOFixture.makeExecutable(cpuType: MachOConstants.cpuTypeARM64).bytes
        let bytes = MachOFixture.makeFatContainer([
            (MachOConstants.cpuTypeARM64, 0x8000_0002, slice),
            (MachOConstants.cpuTypeARM64, 0x8000_000c, slice)
        ])
        let url = try writeTemporaryFile(named: "FixtureArm64eFat", contents: bytes)

        let model = LoaderOptionsInspector().inspect(url: url)
        XCTAssertEqual(model.slices.map(\.architectureName), ["arm64e", "arm64e.x1"])
        XCTAssertNotNil(model.selectedSliceIndex)
    }

    func testUniversalSliceArchitectureNameUsesMaskedSubtype() {
        func name(_ type: Int32, _ subtype: UInt32) -> String {
            MachOUniversalSlice(index: 0, cpuType: type, cpuSubtype: Int32(bitPattern: subtype),
                                offset: 0, size: 0, alignment: 0).architectureName
        }
        XCTAssertEqual(name(MachOConstants.cpuTypeARM64, 0), "arm64")
        XCTAssertEqual(name(MachOConstants.cpuTypeARM64, 0x8000_0002), "arm64e")
        XCTAssertEqual(name(MachOConstants.cpuTypeARM64, 0x8000_000c), "arm64e.x1")
        XCTAssertEqual(name(MachOConstants.cpuTypeARM64, 7), "arm64 (subtype 7)")
        XCTAssertEqual(name(MachOConstants.cpuTypeX86_64, 3), "x86_64")
        XCTAssertEqual(name(MachOConstants.cpuTypeX86_64, 8), "x86_64h")
        XCTAssertEqual(LoaderOptionsModel.defaultSliceIndex(for: [
            option(0, arch: "x86_64"), option(1, arch: "arm64e.x1")
        ]), 1)
    }

    func testInspectorReportsThinForSingleArchBinary() throws {
        let fixture = MachOFixture.makeExecutable()
        let url = try writeTemporaryFile(named: "FixtureThin", contents: fixture.bytes)

        let model = LoaderOptionsInspector().inspect(url: url)
        XCTAssertFalse(model.requiresChoice)
        XCTAssertFalse(model.isUniversal)
        XCTAssertTrue(model.slices.isEmpty)
    }

    private func writeTemporaryFile(named name: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }
}
