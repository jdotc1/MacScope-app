import XCTest
@testable import MacScope

/// WS-5: reopening a saved workspace must restore the derived products that were dropped on save.
/// The headline guarantee is `reopen == fresh analysis` for the byte-derived products, achieved by
/// re-running only the loader over the persisted `imageBytes` (never re-decoding). Products that ARE
/// persisted (functions/instructions/xrefs/basicBlocks/controlFlowEdges/…) are preserved untouched.
final class RehydrationTests: XCTestCase {
    private let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")

    func testRehydrateReproducesFreshByteDerivedProductsAndPreservesTheRest() throws {
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls not readable")
        }
        let engine = AnalysisEngine()
        let fresh = try engine.analyze(url: systemBinaryURL, requestedSliceIndex: nil,
                                       overrides: [:], cancellation: .never)
        let freshImg = try XCTUnwrap(fresh.analysis(in: fresh.primarySlot))

        // Simulate a reloaded image: the persisted products remain; the byte-derived products that
        // save drops are empty. (basicBlocks / controlFlowEdges ARE persisted → NOT stripped.)
        var stripped = freshImg
        stripped.sections = []
        stripped.relocations = []
        stripped.machOMetadata = nil
        stripped.jumpTables = [:]
        stripped.objcSelectors = [:]
        stripped.objcClasses = []
        stripped.objcCategories = []
        stripped.swiftTypes = []
        stripped.swiftConformances = []
        stripped.diagnostics = []

        let rehy = try engine.rehydrate(imageBytes: freshImg.imageBytes, requestedSliceIndex: nil,
                                        preserving: stripped, cancellation: .never)

        // Re-derived byte-derived products equal a fresh analysis. `SectionSummary` is Identifiable
        // with a synthesized UUID (incidental SwiftUI identity, not cross-referenced), so compare by
        // content — the reopen==fresh guarantee is about the derived data, not the row UUID.
        func sectionKey(_ s: SectionSummary) -> String {
            "\(s.name)|\(s.address)|\(s.size)|\(s.fileOffset)|\(s.isExecutable)|\(s.isZeroFill)|\(String(describing: s.fileSize))"
        }
        XCTAssertEqual(rehy.sections.map(sectionKey), freshImg.sections.map(sectionKey))
        XCTAssertEqual(rehy.relocations, freshImg.relocations)
        XCTAssertEqual(rehy.machOMetadata, freshImg.machOMetadata)
        XCTAssertEqual(rehy.jumpTables, freshImg.jumpTables)
        XCTAssertEqual(rehy.objcSelectors, freshImg.objcSelectors)
        XCTAssertEqual(rehy.objcClasses, freshImg.objcClasses)
        XCTAssertEqual(rehy.objcCategories, freshImg.objcCategories)
        XCTAssertEqual(rehy.swiftTypes, freshImg.swiftTypes)
        XCTAssertEqual(rehy.swiftConformances, freshImg.swiftConformances)
        XCTAssertEqual(rehy.diagnostics, freshImg.diagnostics)
        XCTAssertFalse(rehy.sections.isEmpty, "the /bin/ls fixture must yield sections")

        // Persisted products are preserved exactly.
        XCTAssertEqual(rehy.functions, stripped.functions)
        XCTAssertEqual(rehy.instructions, stripped.instructions)
        XCTAssertEqual(rehy.xrefs, stripped.xrefs)
        XCTAssertEqual(rehy.controlFlowEdges, stripped.controlFlowEdges)
        XCTAssertEqual(rehy.basicBlocks, stripped.basicBlocks)
    }

    /// Rehydration is reachable through the `AnalysisProviding` seam (the store holds `any
    /// AnalysisProviding`), and dispatches to the engine's concrete method for the in-process engine.
    func testRehydrateThroughProviderSeam() throws {
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls not readable")
        }
        let provider: any AnalysisProviding = AnalysisEngine()
        let fresh = try provider.analyze(url: systemBinaryURL, requestedSliceIndex: nil,
                                         overrides: [:], cancellation: .never)
        let img = try XCTUnwrap(fresh.analysis(in: fresh.primarySlot))
        var stripped = img
        stripped.sections = []
        stripped.machOMetadata = nil
        let rehy = try provider.rehydrate(imageBytes: img.imageBytes, requestedSliceIndex: nil,
                                          preserving: stripped, cancellation: .never)
        XCTAssertFalse(rehy.sections.isEmpty)
        XCTAssertEqual(rehy.machOMetadata, img.machOMetadata)
    }
}
