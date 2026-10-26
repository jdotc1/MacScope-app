import Foundation
import XCTest
@testable import MacScope

@MainActor
final class CalleeWitnessFullHeaderTests: XCTestCase {
    private static var loadedFull: CalleeWitnessHeaders.Loaded?

    // One shared fixture import gives the import-count and refusal assertions
    // the same declaration population without loading a binary.
    private func fullFixture() throws -> CalleeWitnessHeaders.Loaded {
        if let loaded = Self.loadedFull { return loaded }
        let source = try CalleeWitnessHeaders.preprocessed(headerSet: .full)
        let parsed = CTypeHeaderParser.parse(source)
        var analysis = ImageAnalysis()
        for (index, name) in Set(parsed.prototypes.map(\.name)).sorted().enumerated() {
            let address = UInt64(0x1000 + index * 4)
            analysis.exports.append(ExportSummary(id: UUID(), name: "_" + name,
                address: address, source: "export trie", terminalFlags: 0))
            analysis.functions.append(FunctionSummary(id: UUID(), name: name,
                startAddress: address, endAddress: address + 4, confidence: 1))
        }
        let snapshot = WorkspaceSnapshot(binaries: [BinaryImage(id: UUID(),
            name: "synthetic", path: "/synthetic", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis])
        let loaded = try CalleeWitnessHeaders.load(into: snapshot, headerSet: .full,
                                                  preprocessedSource: source)
        Self.loadedFull = loaded
        return loaded
    }

    func testFullDeclarationsImportExpectedPrototypePopulation() throws {
        let loaded = try fullFixture()
        // Includes other architectures. Real-image truth coverage is measured
        // separately and is bounded by 269/289 before importer refusals.
        XCTAssertGreaterThanOrEqual(loaded.summary.importedPrototypeCount, 269)
        XCTAssertEqual(loaded.summary.importedPrototypeCount, loaded.parsedPrototypeCount)
        let snapshot = loaded.snapshot
        let functions = try XCTUnwrap(snapshot.analysis(in: .primary)).functions
        let signatures = Dictionary(uniqueKeysWithValues: functions.compactMap { function in
            snapshot.importedPrototypes[.primary(function.startAddress)].map { (function.name, $0) }
        })
        for name in ["jpeg_fdct_islow", "jpeg_get_small", "jpeg_make_d_derived_tbl",
                     "jpeg_make_c_derived_tbl", "jsimd_h1v2_fancy_upsample",
                     "jsimd_set_fdct_islow", "jsimd_fdct_islow_neon"] {
            XCTAssertNotNil(signatures[name], name)
        }
        XCTAssertEqual(signatures["jsimd_h1v2_fancy_upsample"]?.returnType, "void")
        XCTAssertEqual(signatures["jsimd_set_h1v2_fancy_upsample"]?.returnType, "uint32_t")
        XCTAssertNil(signatures["jpeg12_fdct_islow"], "A precision-12 DCT context is not loaded")
    }

    func testFullDeclarationsSkippedPrototypeList() throws {
        let loaded = try fullFixture()
        // Source syntax deliberately remains intact: register parameters,
        // freq[] and inline pointer-to-function-pointer parameters are refused
        // by the bounded importer. No parser behavior is changed here.
        let names = ["jpeg_fill_bit_buffer", "jpeg_gen_optimal_table", "jpeg_huff_decode",
                     "jsimd_set_encode_mcu_AC_first_prepare", "jsimd_set_encode_mcu_AC_refine_prepare"]
        let expected = names.map { "Skipped function prototype `\($0)`: unresolved or unsupported declaration." }
        XCTAssertEqual(loaded.summary.skippedPrototypeCount, expected.count)
        XCTAssertEqual(loaded.skippedPrototypes.sorted(), expected.sorted())
    }

    func testHeaderSetSelectorPreservesDefaultEnvironment() throws {
        let selected = try CalleeWitnessHeaders.HeaderSet.selected(environment: [:])
        XCTAssertEqual(selected, .standard)
        XCTAssertEqual(selected.headerNames, ["jpeglib.h", "jmorecfg.h", "jpegint.h"])
        XCTAssertEqual(selected.prelude, "#include \"public-layout.c\"\n#include \"jpegint.h\"\n")
        XCTAssertEqual(try CalleeWitnessHeaders.HeaderSet.selected(
            environment: ["MACSCOPE_LIBJPEG_HEADER_SET": "default"]), .standard)
        XCTAssertEqual(try CalleeWitnessHeaders.HeaderSet.selected(
            environment: ["MACSCOPE_LIBJPEG_HEADER_SET": "full"]), .full)
        XCTAssertThrowsError(try CalleeWitnessHeaders.HeaderSet.selected(
            environment: ["MACSCOPE_LIBJPEG_HEADER_SET": "typo"]))
    }
}
