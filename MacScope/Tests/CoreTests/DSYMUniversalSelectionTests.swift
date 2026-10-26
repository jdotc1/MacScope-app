import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// Roadmap M7 — UUID-directed universal dSYM selection. Every fixture is a synthetic, in-memory
/// DWARF Mach-O (LC_UUID + `__DWARF,__debug_info/__debug_abbrev` carrying one named subprogram),
/// optionally wrapped in a fat/fat64 container or placed in a `.dSYM` bundle, so each slice's
/// recovered function name proves exactly which slice the importer read. No toolchain needed.
final class DSYMUniversalSelectionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-dsym-universal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private static let arm64 = MachOConstants.cpuTypeARM64
    private static let x86 = MachOConstants.cpuTypeX86_64
    private static let arm64eSubtype = Int32(bitPattern: 0x8000_0002) // PTRAUTH ABI | ARM64E
    private static let x86AllSubtype: Int32 = 3

    private static let uuidA = [UInt8](repeating: 0xaa, count: 16)
    private static let uuidB = [UInt8](repeating: 0xbb, count: 16)
    private static let uuidC = [UInt8](repeating: 0xcc, count: 16)
    private static func string(_ uuid: [UInt8]) -> String { MachOUUID(bytes: uuid).stringValue }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Universal selection

    /// arm64 first, x86_64 second, arm64e third; the loaded image's UUID is the x86_64 slice's.
    /// The importer must read slice 1 — not slice 0, not the host-preferred arm64 slice.
    func testFatDSYMUsesSecondSliceWhenItsUUIDMatches() throws {
        let x86Slice = DSYMSliceFixture.thin(cpuType: Self.x86, cpuSubtype: Self.x86AllSubtype,
                                             uuid: Self.uuidB, function: "x86_only_fn", lowPC: 0x2000)
        let container = DSYMSliceFixture.fat([
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidA, function: "arm64_only_fn", lowPC: 0x1000),
            x86Slice,
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: Self.arm64eSubtype,
                                  uuid: Self.uuidC, function: "arm64e_only_fn", lowPC: 0x3000),
        ])
        let url = try write(container, named: "universal")

        let result = try DSYMImportService().importDebugSymbols(
            at: url, expectedUUID: Self.string(Self.uuidB).uppercased()
        )

        XCTAssertEqual(result.functions.map(\.name), ["x86_only_fn"])
        XCTAssertEqual(result.functions.map(\.address), [0x2000])
        XCTAssertEqual(result.matchedUUID, Self.string(Self.uuidB))
        XCTAssertEqual(result.matchedSliceArchitecture, "x86_64")
        let seal = try XCTUnwrap(result.debugArtifactSeal)
        XCTAssertEqual(seal.selectedMachOSHA256, Self.sha256(x86Slice))
        XCTAssertEqual(seal.selectedMachOByteCount, UInt64(x86Slice.count))
    }

    func testFat64DSYMSelectsSliceByUUID() throws {
        let container = DSYMSliceFixture.fat([
            DSYMSliceFixture.thin(cpuType: Self.x86, cpuSubtype: Self.x86AllSubtype,
                                  uuid: Self.uuidA, function: "x86_only_fn", lowPC: 0x1000),
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidB, function: "arm64_only_fn", lowPC: 0x2000),
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: Self.arm64eSubtype,
                                  uuid: Self.uuidC, function: "arm64e_only_fn", lowPC: 0x3000),
        ], is64Bit: true)
        let url = try write(container, named: "universal64")

        let result = try DSYMImportService().importDebugSymbols(at: url, expectedUUID: Self.string(Self.uuidC))

        XCTAssertEqual(result.functions.map(\.name), ["arm64e_only_fn"])
        XCTAssertEqual(result.matchedSliceArchitecture, "arm64e")
    }

    func testFatDSYMWithNoMatchingSliceReportsEverySliceUUID() throws {
        let container = DSYMSliceFixture.fat([
            DSYMSliceFixture.thin(cpuType: Self.x86, cpuSubtype: Self.x86AllSubtype,
                                  uuid: Self.uuidA, function: "x86_only_fn", lowPC: 0x1000),
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidB, function: "arm64_only_fn", lowPC: 0x2000),
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: Self.arm64eSubtype,
                                  uuid: Self.uuidC, function: "arm64e_only_fn", lowPC: 0x3000),
        ])
        let url = try write(container, named: "universal")
        let expected = "11111111-2222-3333-4444-555555555555"

        XCTAssertThrowsError(try DSYMImportService().importDebugSymbols(at: url, expectedUUID: expected)) { error in
            guard case let .uuidMismatch(reportedExpected, candidates) = error as? DSYMImportError else {
                return XCTFail("expected .uuidMismatch, got \(error)")
            }
            XCTAssertEqual(reportedExpected, expected)
            XCTAssertEqual(candidates, [
                DSYMSliceIdentity(fileName: "universal", sliceIndex: 0, architecture: "x86_64",
                                  uuid: Self.string(Self.uuidA), failure: nil),
                DSYMSliceIdentity(fileName: "universal", sliceIndex: 1, architecture: "arm64",
                                  uuid: Self.string(Self.uuidB), failure: nil),
                DSYMSliceIdentity(fileName: "universal", sliceIndex: 2, architecture: "arm64e",
                                  uuid: Self.string(Self.uuidC), failure: nil),
            ])
            let message = (error as? DSYMImportError)?.errorDescription ?? ""
            for uuid in [Self.uuidA, Self.uuidB, Self.uuidC] {
                XCTAssertTrue(message.contains(Self.string(uuid)), "message must list \(Self.string(uuid)): \(message)")
            }
        }
    }

    /// arm64e (first) and arm64 share CPU_TYPE_ARM64. Arch-family selection would read the first
    /// ARM64 slice; UUID selection must read whichever slice actually carries the UUID.
    func testArm64eAndArm64SlicesAreNotConflatedWhenUUIDsDiffer() throws {
        let container = DSYMSliceFixture.fat([
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: Self.arm64eSubtype,
                                  uuid: Self.uuidA, function: "arm64e_only_fn", lowPC: 0x1000),
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidB, function: "arm64_only_fn", lowPC: 0x2000),
        ])
        let url = try write(container, named: "arm64-family")
        let service = DSYMImportService()

        let plain = try service.importDebugSymbols(at: url, expectedUUID: Self.string(Self.uuidB))
        XCTAssertEqual(plain.functions.map(\.name), ["arm64_only_fn"])
        XCTAssertEqual(plain.matchedSliceArchitecture, "arm64")

        let authenticated = try service.importDebugSymbols(at: url, expectedUUID: Self.string(Self.uuidA))
        XCTAssertEqual(authenticated.functions.map(\.name), ["arm64e_only_fn"])
        XCTAssertEqual(authenticated.matchedSliceArchitecture, "arm64e")
    }

    /// A fat record claiming arm64e over a slice whose own header is plain arm64 is a lying
    /// container; that slice is never used even when its LC_UUID matches.
    func testSliceWhoseHeaderDisagreesWithFatRecordIsRejected() throws {
        let arm64Slice = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                               uuid: Self.uuidA, function: "arm64_only_fn", lowPC: 0x1000)
        let container = DSYMSliceFixture.fat([arm64Slice], recordSubtypes: [Self.arm64eSubtype])
        let url = try write(container, named: "lying")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "disagrees")
    }

    // MARK: - Malformed universal containers

    func testFatSliceOffsetBeyondFileIsExplicitError() throws {
        let slice = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "f", lowPC: 0x1000)
        var container = DSYMSliceFixture.fat([slice])
        DSYMSliceFixture.patchFat32Record(&container, index: 0, offset: 0x10_0000)
        let url = try write(container, named: "beyond")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "outside the file")
    }

    func testFatSliceSizeOverflowIsExplicitError() throws {
        let slice = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "f", lowPC: 0x1000)
        var container = DSYMSliceFixture.fat([slice], is64Bit: true)
        DSYMSliceFixture.patchFat64Record(&container, index: 0, size: .max)
        let url = try write(container, named: "overflow")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "slice 0")
    }

    func testFatHugeArchitectureCountIsExplicitError() throws {
        let slice = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "f", lowPC: 0x1000)
        var container = DSYMSliceFixture.fat([slice])
        DSYMSliceFixture.patchBE32(&container, at: 4, 0xffff_ffff)
        let url = try write(container, named: "huge-count")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "architecture count")
    }

    func testFatOverlappingSlicesAreExplicitError() throws {
        let first = DSYMSliceFixture.thin(cpuType: Self.x86, cpuSubtype: Self.x86AllSubtype,
                                          uuid: Self.uuidA, function: "x", lowPC: 0x1000)
        let second = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                           uuid: Self.uuidB, function: "a", lowPC: 0x2000)
        var container = DSYMSliceFixture.fat([first, second])
        // Point slice 1 at slice 0's bytes (still aligned and in-file): aliasing, not a new slice.
        DSYMSliceFixture.patchFat32Record(&container, index: 1, offset: UInt32(DSYMSliceFixture.sliceAlignment))
        let url = try write(container, named: "overlap")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "overlap")
    }

    func testFatSliceOverlappingHeaderIsExplicitError() throws {
        let slice = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "f", lowPC: 0x1000)
        var container = DSYMSliceFixture.fat([slice])
        DSYMSliceFixture.patchFat32Record(&container, index: 0, offset: 0, alignment: 0)
        let url = try write(container, named: "header-overlap")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "fat header")
    }

    func testFatMisalignedSliceIsExplicitError() throws {
        let slice = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "f", lowPC: 0x1000)
        var container = DSYMSliceFixture.fat([slice])
        DSYMSliceFixture.patchFat32Record(&container, index: 0, alignment: 14) // 0x1000 is not 16K-aligned
        let url = try write(container, named: "misaligned")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "aligned")
    }

    func testFatDuplicateArchitectureIsExplicitError() throws {
        let container = DSYMSliceFixture.fat([
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidA, function: "a", lowPC: 0x1000),
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidB, function: "b", lowPC: 0x2000),
        ])
        let url = try write(container, named: "duplicate")

        assertNotMachO(url, expectedUUID: Self.string(Self.uuidA), mentioning: "duplicates")
    }

    func testStrictUniversalSlicesReturnsNilForThinMachO() throws {
        let thin = DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                         uuid: Self.uuidA, function: "f", lowPC: 0x1000)
        XCTAssertNil(try MachOParser().strictUniversalSlices(in: thin))
        XCTAssertNil(try MachOParser().strictUniversalSlices(in: Data([0xca])))
    }

    // MARK: - .dSYM bundle directories

    func testBundleWithTwoDWARFFilesSelectsFileByUUID() throws {
        let bundle = try makeBundle(files: [
            "Alpha": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                           uuid: Self.uuidA, function: "alpha_fn", lowPC: 0x1000),
            "Beta": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidB, function: "beta_fn", lowPC: 0x2000),
        ])

        let result = try DSYMImportService().importDebugSymbols(at: bundle, expectedUUID: Self.string(Self.uuidB))

        XCTAssertEqual(result.functions.map(\.name), ["beta_fn"])
        XCTAssertEqual(result.dwarfURL.lastPathComponent, "Beta")
    }

    func testBundleSelectsSliceInsideUniversalDWARFFileByUUID() throws {
        let bundle = try makeBundle(files: [
            "Alpha": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                           uuid: Self.uuidA, function: "alpha_fn", lowPC: 0x1000),
            "Beta": DSYMSliceFixture.fat([
                DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                      uuid: Self.uuidB, function: "beta_arm64_fn", lowPC: 0x2000),
                DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: Self.arm64eSubtype,
                                      uuid: Self.uuidC, function: "beta_arm64e_fn", lowPC: 0x3000),
            ]),
        ])

        let result = try DSYMImportService().importDebugSymbols(at: bundle, expectedUUID: Self.string(Self.uuidC))

        XCTAssertEqual(result.functions.map(\.name), ["beta_arm64e_fn"])
        XCTAssertEqual(result.dwarfURL.lastPathComponent, "Beta")
        XCTAssertEqual(result.matchedSliceArchitecture, "arm64e")
    }

    func testBundleMismatchListsSlicesAcrossAllFiles() throws {
        let bundle = try makeBundle(files: [
            "Alpha": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                           uuid: Self.uuidA, function: "alpha_fn", lowPC: 0x1000),
            "Beta": DSYMSliceFixture.thin(cpuType: Self.x86, cpuSubtype: Self.x86AllSubtype,
                                          uuid: Self.uuidB, function: "beta_fn", lowPC: 0x2000),
        ])
        let expected = "11111111-2222-3333-4444-555555555555"

        XCTAssertThrowsError(try DSYMImportService().importDebugSymbols(at: bundle, expectedUUID: expected)) { error in
            guard case let .uuidMismatch(_, candidates) = error as? DSYMImportError else {
                return XCTFail("expected .uuidMismatch, got \(error)")
            }
            XCTAssertEqual(candidates.map(\.fileName), ["Alpha", "Beta"])
            XCTAssertEqual(candidates.map(\.uuid), [Self.string(Self.uuidA), Self.string(Self.uuidB)])
        }
    }

    func testBundleWithTwoFilesCarryingSameUUIDIsAmbiguous() throws {
        let bundle = try makeBundle(files: [
            "Alpha": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                           uuid: Self.uuidA, function: "alpha_fn", lowPC: 0x1000),
            "Beta": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "beta_fn", lowPC: 0x2000),
        ])

        XCTAssertThrowsError(try DSYMImportService().importDebugSymbols(at: bundle, expectedUUID: Self.string(Self.uuidA))) { error in
            guard case let .ambiguousUUIDMatch(uuid, candidates) = error as? DSYMImportError else {
                return XCTFail("expected .ambiguousUUIDMatch, got \(error)")
            }
            XCTAssertEqual(uuid, Self.string(Self.uuidA))
            XCTAssertEqual(candidates.map(\.fileName), ["Alpha", "Beta"])
        }
    }

    /// A malformed sibling file cannot block the valid, UUID-matching one.
    func testBundleMalformedSiblingDoesNotBlockMatchingFile() throws {
        var broken = DSYMSliceFixture.fat([
            DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                  uuid: Self.uuidB, function: "broken_fn", lowPC: 0x1000),
        ])
        DSYMSliceFixture.patchFat32Record(&broken, index: 0, offset: 0x10_0000)
        let bundle = try makeBundle(files: [
            "Alpha": broken,
            "Beta": DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                          uuid: Self.uuidA, function: "beta_fn", lowPC: 0x2000),
        ])

        let result = try DSYMImportService().importDebugSymbols(at: bundle, expectedUUID: Self.string(Self.uuidA))
        XCTAssertEqual(result.functions.map(\.name), ["beta_fn"])
    }

    // MARK: - Thin behaviour unchanged

    func testThinDSYMMatchAndMismatchBehaviourUnchanged() throws {
        let url = try write(DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                                  uuid: Self.uuidA, function: "thin_fn", lowPC: 0x1000),
                            named: "thin")
        let service = DSYMImportService()

        let result = try service.importDebugSymbols(at: url, expectedUUID: Self.string(Self.uuidA))
        XCTAssertEqual(result.functions.map(\.name), ["thin_fn"])
        XCTAssertEqual(result.dwarfURL, url)
        XCTAssertEqual(result.matchedSliceArchitecture, "arm64")

        let wrong = "00000000-0000-0000-0000-000000000000"
        XCTAssertThrowsError(try service.importDebugSymbols(at: url, expectedUUID: wrong)) { error in
            XCTAssertEqual(error as? DSYMImportError, .uuidMismatch(expected: wrong, candidates: [
                DSYMSliceIdentity(fileName: "thin", sliceIndex: nil, architecture: "arm64",
                                  uuid: Self.string(Self.uuidA), failure: nil),
            ]))
            XCTAssertTrue((error as? DSYMImportError)?.errorDescription?
                .contains("dSYM UUID: \(Self.string(Self.uuidA))") == true)
        }
    }

    func testThinDSYMWithoutUUIDStillReportsMissingDSYMUUID() throws {
        let url = try write(DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                                  uuid: nil, function: "thin_fn", lowPC: 0x1000),
                            named: "no-uuid")
        XCTAssertThrowsError(try DSYMImportService().importDebugSymbols(
            at: url, expectedUUID: Self.string(Self.uuidA)
        )) { error in
            XCTAssertEqual(error as? DSYMImportError, .missingDSYMUUID)
        }
    }

    // MARK: - HS-9: the image's own LC_UUID gates every apply

    /// A caller-pinned UUID (scripting `uuid`, store `expectedUUID`) selects the dSYM slice, but
    /// the target image's own LC_UUID must still agree before any name lands on it. Before HS-9
    /// the override applied a dSYM to an image whose LC_UUID differed.
    @MainActor
    func testUUIDOverrideCannotApplyDSYMToImageWithDifferentLCUUID() throws {
        let url = try write(DSYMSliceFixture.thin(cpuType: Self.arm64, cpuSubtype: 0,
                                                  uuid: Self.uuidA, function: "thin_fn", lowPC: 0x1000),
                            named: "override")
        let dsymUUID = Self.string(Self.uuidA)
        let imageUUID = Self.string(Self.uuidB).uppercased()

        let result = try DSYMImportService().importDebugSymbols(at: url, expectedUUID: dsymUUID)
        XCTAssertThrowsError(try result.requireMatchingImage(uuid: imageUUID)) { error in
            XCTAssertEqual(error as? DSYMImportError,
                           .imageUUIDMismatch(imageUUID: imageUUID, dsymUUID: dsymUUID))
            let message = (error as? DSYMImportError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains(imageUUID) && message.contains(dsymUUID), message)
        }
        XCTAssertNoThrow(try result.requireMatchingImage(uuid: dsymUUID.uppercased()), "case-insensitive match")
        XCTAssertNoThrow(try result.requireMatchingImage(uuid: nil), "no LC_UUID: the caller's UUID is the gate")

        var binary = BinaryImage(id: UUID(), name: "img", path: "/tmp/img", kind: "executable",
                                 architecture: "arm64", slot: .primary)
        binary.metadata.uuid = imageUUID
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(id: UUID(), name: "before", startAddress: 0x1000,
                                              endAddress: 0x1004, confidence: 1)]
        let store = WorkspaceStore(
            workspaceName: "HS-9",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.importDebugSymbols(at: url, expectedUUID: dsymUUID)
        let storeError = try XCTUnwrap(store.debugSymbolsImportError, "override must be refused")
        XCTAssertTrue(storeError.contains(imageUUID) && storeError.contains(dsymUUID), storeError)
        XCTAssertNil(store.snapshot.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)]?.customName)
    }

    // MARK: - Helpers

    private func assertNotMachO(
        _ url: URL,
        expectedUUID: String,
        mentioning fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try DSYMImportService().importDebugSymbols(at: url, expectedUUID: expectedUUID),
                             file: file, line: line) { error in
            guard case let .notMachO(reason) = error as? DSYMImportError else {
                return XCTFail("expected .notMachO, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(fragment), "reason \"\(reason)\" should mention \"\(fragment)\"",
                          file: file, line: line)
        }
    }

    private func makeBundle(files: [String: Data]) throws -> URL {
        let bundle = scratch.appendingPathComponent("Fixture-\(UUID().uuidString).dSYM", isDirectory: true)
        let dwarf = bundle.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
        for (name, bytes) in files {
            try bytes.write(to: dwarf.appendingPathComponent(name))
        }
        return bundle
    }
}

// MARK: - Synthetic DWARF Mach-O / fat builders

private enum DSYMSliceFixture {
    static let sliceAlignment = 0x1000
    static let alignmentExponent: UInt32 = 12

    /// A thin MH_DSYM with an optional LC_UUID and a `__DWARF` segment holding a v4
    /// `.debug_info`/`.debug_abbrev` pair that names one subprogram at `lowPC`.
    static func thin(cpuType: Int32, cpuSubtype: Int32, uuid: [UInt8]?, function: String, lowPC: UInt64) -> Data {
        // [1] DW_TAG_subprogram, no children, {DW_AT_name DW_FORM_string, DW_AT_low_pc DW_FORM_addr}
        let abbrev: [UInt8] = [0x01, 0x2e, 0x00, 0x03, 0x08, 0x11, 0x01, 0x00, 0x00, 0x00]
        var die: [UInt8] = [0x01]
        die.append(contentsOf: Array(function.utf8))
        die.append(0x00)
        die.append(contentsOf: le64(lowPC))
        var unitBody: [UInt8] = [0x04, 0x00]          // version 4
        unitBody.append(contentsOf: le32(0))          // debug_abbrev_offset
        unitBody.append(0x08)                         // address_size
        unitBody.append(contentsOf: die)
        unitBody.append(0x00)                         // null DIE
        let info = le32(UInt32(unitBody.count)) + unitBody

        let uuidCommandSize = uuid == nil ? 0 : 24
        let segmentCommandSize = 72 + 2 * 80
        let sizeOfCommands = uuidCommandSize + segmentCommandSize
        let payloadStart = 32 + sizeOfCommands
        let infoOffset = payloadStart
        let abbrevOffset = infoOffset + info.count
        let payloadSize = info.count + abbrev.count

        var out: [UInt8] = []
        out += le32(MachOConstants.machMagic64)
        out += le32(UInt32(bitPattern: cpuType))
        out += le32(UInt32(bitPattern: cpuSubtype))
        out += le32(0xa)                               // MH_DSYM
        out += le32(uuid == nil ? 1 : 2)
        out += le32(UInt32(sizeOfCommands))
        out += le32(0)
        out += le32(0)
        if let uuid {
            out += le32(MachOConstants.loadCommandUUID)
            out += le32(24)
            out += uuid
        }
        out += le32(MachOConstants.loadCommandSegment64)
        out += le32(UInt32(segmentCommandSize))
        out += name16("__DWARF")
        out += le64(0)                                 // vmaddr
        out += le64(UInt64(payloadSize))               // vmsize
        out += le64(UInt64(payloadStart))              // fileoff
        out += le64(UInt64(payloadSize))               // filesize
        out += le32(7)
        out += le32(3)
        out += le32(2)                                 // nsects
        out += le32(0)
        out += section("__debug_info", size: info.count, offset: infoOffset)
        out += section("__debug_abbrev", size: abbrev.count, offset: abbrevOffset)
        precondition(out.count == payloadStart)
        out += info
        out += abbrev
        return Data(out)
    }

    /// A lipo-shaped fat (or fat64) container: slices at 4 KiB-aligned offsets after the table,
    /// each record's alignment 2^12. `recordSubtypes` overrides the fat records' cpusubtype
    /// (default: copied from each slice's own header, as lipo does).
    static func fat(_ slices: [Data], is64Bit: Bool = false, recordSubtypes: [Int32]? = nil) -> Data {
        let recordSize = is64Bit ? 32 : 20
        var offsets: [Int] = []
        var cursor = align(8 + slices.count * recordSize)
        for slice in slices {
            offsets.append(cursor)
            cursor = align(cursor + slice.count)
        }
        var data = Data()
        appendBE32(is64Bit ? MachOConstants.fatMagic64 : MachOConstants.fatMagic, to: &data)
        appendBE32(UInt32(slices.count), to: &data)
        for (index, slice) in slices.enumerated() {
            let headerCPUType = readLE32(slice, at: 4)
            let headerCPUSubtype = readLE32(slice, at: 8)
            let recordSubtype = recordSubtypes.map { UInt32(bitPattern: $0[index]) } ?? headerCPUSubtype
            appendBE32(headerCPUType, to: &data)
            appendBE32(recordSubtype, to: &data)
            if is64Bit {
                appendBE64(UInt64(offsets[index]), to: &data)
                appendBE64(UInt64(slice.count), to: &data)
                appendBE32(alignmentExponent, to: &data)
                appendBE32(0, to: &data)               // reserved
            } else {
                appendBE32(UInt32(offsets[index]), to: &data)
                appendBE32(UInt32(slice.count), to: &data)
                appendBE32(alignmentExponent, to: &data)
            }
        }
        for (index, slice) in slices.enumerated() {
            data.append(Data(repeating: 0, count: offsets[index] - data.count))
            data.append(slice)
        }
        return data
    }

    static func patchFat32Record(_ data: inout Data, index: Int, offset: UInt32? = nil, alignment: UInt32? = nil) {
        let base = 8 + index * 20
        if let offset { patchBE32(&data, at: base + 8, offset) }
        if let alignment { patchBE32(&data, at: base + 16, alignment) }
    }

    static func patchFat64Record(_ data: inout Data, index: Int, size: UInt64) {
        let base = 8 + index * 32
        for byte in 0..<8 {
            data[base + 16 + byte] = UInt8(truncatingIfNeeded: size >> UInt64(56 - 8 * byte))
        }
    }

    static func patchBE32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        for byte in 0..<4 {
            data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * byte))
        }
    }

    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << UInt32(8 * $1) }
    }

    private static func align(_ value: Int) -> Int {
        (value + sliceAlignment - 1) / sliceAlignment * sliceAlignment
    }

    private static func section(_ name: String, size: Int, offset: Int) -> [UInt8] {
        var record: [UInt8] = []
        record += name16(name)
        record += name16("__DWARF")
        record += le64(0)                              // addr
        record += le64(UInt64(size))
        record += le32(UInt32(offset))
        record += le32(0)                              // align
        record += le32(0)                              // reloff
        record += le32(0)                              // nreloc
        record += le32(0)                              // flags
        record += le32(0)
        record += le32(0)
        record += le32(0)
        return record
    }

    private static func name16(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8.prefix(16))
        return bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(8 * $0)) }
    }

    private static func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * $0)) }
    }

    private static func appendBE32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * $0)) })
    }

    private static func appendBE64(_ value: UInt64, to data: inout Data) {
        data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * $0)) })
    }
}
