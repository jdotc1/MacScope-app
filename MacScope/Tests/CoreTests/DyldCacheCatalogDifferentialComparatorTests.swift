import XCTest
@testable import MacScope

final class DyldCacheCatalogDifferentialComparatorTests: XCTestCase {
    func testExactComparisonRequiresImagePathAndLoadAddress() {
        let provider = DyldCacheAnalysisTestFixtures.result(
            images: [DyldCacheAnalysisTestFixtures.imageRecord("/usr/lib/libA.dylib", 0x2000)]
        )
        let report = DyldCacheCatalogDifferentialComparator().compare(
            nativeImages: [DyldCacheImageIdentity(path: "/usr/lib/libA.dylib", loadAddress: 0x1000)],
            nativeMappings: [],
            provider: provider
        )

        XCTAssertEqual(report.state, .disagreement)
        XCTAssertEqual(report.nativeOnlyImages.map(\.loadAddress), [0x1000])
        XCTAssertEqual(report.supplementalOnlyImages.map(\.loadAddress), [0x2000])
    }

    func testExactComparisonRequiresMappingProtectionsAndSourceOwnership() {
        let provider = DyldCacheAnalysisTestFixtures.result(
            mappings: [DyldCacheAnalysisTestFixtures.mappingRecord(
                address: 0x1000,
                sourceFileIndex: 1,
                maximumProtection: 7,
                initialProtection: 5
            )]
        )
        let native = DyldCacheComparableMapping(
            address: 0x1000,
            size: 0x1000,
            fileOffset: 0x1000,
            sourceFileIndex: 0,
            maximumProtection: 5,
            initialProtection: 5,
            flags: 0
        )
        let report = DyldCacheCatalogDifferentialComparator().compare(
            nativeImages: [],
            nativeMappings: [native],
            provider: provider
        )

        XCTAssertEqual(report.state, .disagreement)
        XCTAssertEqual(report.nativeOnlyMappings, [native])
        XCTAssertEqual(report.supplementalOnlyMappings.count, 1)
    }

    func testDuplicateFactsAreInvalidInsteadOfSilentlyCollapsed() {
        let duplicate = DyldCacheAnalysisTestFixtures.imageRecord("/usr/lib/libA.dylib", 0x1000)
        let provider = DyldCacheAnalysisTestFixtures.result(images: [duplicate, duplicate])
        let report = DyldCacheCatalogDifferentialComparator().compare(
            nativeImages: [DyldCacheImageIdentity(path: duplicate.path, loadAddress: duplicate.loadAddress)],
            nativeMappings: [],
            provider: provider
        )

        XCTAssertEqual(report.state, .invalid)
        XCTAssertEqual(report.invalidReasons, [.duplicateSupplementalImage(
            DyldCacheImageIdentity(path: duplicate.path, loadAddress: duplicate.loadAddress)
        )])
    }

    func testSupplementalOnlyAndNativeOnlyAreDistinctClosedStates() {
        let supplemental = DyldCacheCatalogDifferentialComparator().compare(
            nativeImages: [],
            nativeMappings: [],
            provider: DyldCacheAnalysisTestFixtures.result(
                images: [DyldCacheAnalysisTestFixtures.imageRecord("/supplemental", 1)]
            )
        )
        XCTAssertEqual(supplemental.state, .supplementalOnly)

        let native = DyldCacheCatalogDifferentialComparator().compare(
            nativeImages: [DyldCacheImageIdentity(path: "/native", loadAddress: 2)],
            nativeMappings: [],
            provider: DyldCacheAnalysisTestFixtures.result()
        )
        XCTAssertEqual(native.state, .nativeOnly)
    }

    func testPartialProviderCoverageIsUncomparableNotAgreement() {
        let identity = DyldCacheImageIdentity(path: "/usr/lib/libA.dylib", loadAddress: 0x1000)
        let provider = DyldCacheAnalysisTestFixtures.result(
            images: [DyldCacheAnalysisTestFixtures.imageRecord(identity.path, identity.loadAddress)],
            catalogCoverage: .partial,
            completion: .partial
        )
        let report = DyldCacheCatalogDifferentialComparator().compare(
            nativeImages: [identity],
            nativeMappings: [],
            provider: provider
        )

        XCTAssertEqual(report.state, .uncomparable)
    }
}
