import XCTest
#if canImport(MacScope)
@testable import MacScope
#endif

final class MachOSignatureCoveragePresentationTests: XCTestCase {
    func testMixedContainerKeepsSignedAndUnsignedObservationsSliceBound() throws {
        let arm = MachOSignatureCoveragePresentation(
            imageName: "mixed", architecture: "arm64", selectedSliceIndex: 0,
            hasOtherContainerBytes: true, hasCodeSignature: true,
            machOSelectedSliceFact: try fact(index: 0))
        let intel = MachOSignatureCoveragePresentation(
            imageName: "mixed", architecture: "x86_64", selectedSliceIndex: 1,
            hasOtherContainerBytes: true, hasCodeSignature: false,
            machOSelectedSliceFact: try fact(index: 1))
        XCTAssertEqual(arm.source, "mixed · arm64 · universal slice 0 of 2")
        XCTAssertEqual(intel.source, "mixed · x86_64 · universal slice 1 of 2")
        XCTAssertTrue(arm.signature.contains("present in this slice"))
        XCTAssertTrue(intel.signature.contains("No embedded signature metadata"))
        XCTAssertEqual(arm.coverage, intel.coverage)
        XCTAssertTrue(arm.coverage.contains("Partial container coverage"))
        XCTAssertTrue(arm.coverage.contains("Other slices are unexamined"))
    }

    func testDefaultUniversalSelectionIsStillPartialWithoutExplicitIndex() throws {
        let value = MachOSignatureCoveragePresentation(
            imageName: "default", architecture: "arm64", selectedSliceIndex: nil,
            hasOtherContainerBytes: true, hasCodeSignature: true,
            machOSelectedSliceFact: try fact(index: 1))
        XCTAssertEqual(value.source, "default · arm64 · universal slice 1 of 2")
        XCTAssertTrue(value.coverage.contains("Partial container coverage"))
    }

    func testRetainedExplicitSelectionDoesNotBecomeWholeContainerCoverage() throws {
        let value = MachOSignatureCoveragePresentation(
            imageName: "restored", architecture: "x86_64", selectedSliceIndex: 1,
            hasOtherContainerBytes: nil, hasCodeSignature: false,
            machOSelectedSliceFact: try fact(index: 1))
        XCTAssertTrue(value.coverage.contains("Partial container coverage"))
    }

    func testMissingContainerWitnessIsExplicitlyUnknown() {
        let value = MachOSignatureCoveragePresentation(
            imageName: "legacy", architecture: "arm64", selectedSliceIndex: nil,
            hasOtherContainerBytes: nil, hasCodeSignature: true)
        XCTAssertTrue(value.coverage.contains("Container coverage is unavailable"))
        XCTAssertTrue(value.coverage.contains("any other slices are unexamined"))
    }

    func testThinMetadataDoesNotClaimValidityOrTrust() throws {
        for signed in [true, false] {
            let value = MachOSignatureCoveragePresentation(
                imageName: "thin", architecture: "arm64", selectedSliceIndex: nil,
                hasOtherContainerBytes: false, hasCodeSignature: signed,
                machOSelectedSliceFact: try .init(containerKind: .thin, sliceCount: 1,
                    selectedSliceIndex: 0, cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0))
            XCTAssertTrue(value.coverage.contains("loaded thin Mach-O slice"))
            XCTAssertTrue(value.coverage.contains("does not establish signature validity or trust"))
            XCTAssertFalse(value.coverage.contains("Partial"))
        }
    }

    func testLegacyIndexOrThinAttachmentDoesNotInventContainerFacts() {
        let indices: [Int?] = [nil, 0, 7]
        for index in indices {
            let value = MachOSignatureCoveragePresentation(
                imageName: "legacy", architecture: "arm64", selectedSliceIndex: index,
                hasOtherContainerBytes: false, hasCodeSignature: true)
            XCTAssertEqual(value.source, "legacy · arm64 · slice unknown")
            XCTAssertTrue(value.coverage.contains("Container coverage is unavailable"))
            XCTAssertFalse(value.coverage.contains("loaded thin"))
        }
    }

    func testSingleSliceUniversalRemainsUniversal() throws {
        let value = MachOSignatureCoveragePresentation(
            imageName: "single", architecture: "arm64", selectedSliceIndex: nil,
            hasOtherContainerBytes: false, hasCodeSignature: true,
            machOSelectedSliceFact: try .init(containerKind: .universal, sliceCount: 1,
                selectedSliceIndex: 0, cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0))
        XCTAssertEqual(value.source, "single · arm64 · universal slice 0 of 1")
        XCTAssertTrue(value.coverage.contains("single-slice universal"))
        XCTAssertFalse(value.coverage.contains("Other slices"))
    }

    private func fact(index: Int) throws -> MachOSelectedSliceFact {
        try .init(containerKind: .universal, sliceCount: 2, selectedSliceIndex: index,
                  cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0)
    }

}
