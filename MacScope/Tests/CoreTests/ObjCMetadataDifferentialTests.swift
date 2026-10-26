import XCTest
@testable import MacScope

final class ObjCMetadataDifferentialTests: XCTestCase {
    private let image = AppKitImageKey(imageID: "selected-main", imageGeneration: "gen-1",
                                       bundleGeneration: "bundle-1")
    private var slice: ObjCSliceProof {
        .init(selectedSliceSHA256: String(repeating: "d", count: 64), image: image,
              addressCoordinate: "preferred-mach-o-vm")
    }

    func testSameSliceReportsOnlyUniqueDonorFactWithoutPromotingIt() {
        let a = ObjCMethodFact(image: image, ownerClass: "A", selector: "x:",
                                isClassMethod: false, implementationVMAddress: 0x1000)
        let b = ObjCMethodFact(image: image, ownerClass: "A", selector: "y:",
                                isClassMethod: false, implementationVMAddress: 0x1100)
        let result = ObjCMetadataDifferential.compare(
            primary: .init(slice: slice, methods: [a]),
            donor: .init(slice: slice, methods: [a, b]))
        XCTAssertTrue(result.comparable)
        XCTAssertEqual(result.commonCount, 1)
        XCTAssertEqual(result.onlyInDonor, [b])
        XCTAssertTrue(result.onlyInMacScope.isEmpty)
    }

    func testDifferentSelectedSliceDigestRefusesToCompare() {
        let other = ObjCSliceProof(selectedSliceSHA256: String(repeating: "e", count: 64),
                                   image: image, addressCoordinate: "preferred-mach-o-vm")
        let result = ObjCMetadataDifferential.compare(
            primary: .init(slice: slice, methods: []), donor: .init(slice: other, methods: []))
        XCTAssertFalse(result.comparable)
        XCTAssertEqual(result.refusal, "slice-or-coordinate-mismatch")
    }

    func testAddressCoordinateMismatchRefusesToCompare() {
        let other = ObjCSliceProof(selectedSliceSHA256: slice.selectedSliceSHA256,
                                   image: image, addressCoordinate: "runtime-slid-vm")
        let result = ObjCMetadataDifferential.compare(
            primary: .init(slice: slice, methods: []), donor: .init(slice: other, methods: []))
        XCTAssertFalse(result.comparable)
    }
}
