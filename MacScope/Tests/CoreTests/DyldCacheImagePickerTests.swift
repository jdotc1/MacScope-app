import Foundation
import XCTest
@testable import MacScope

/// The open-time dyld shared cache image picker: list projection (named, deduplicated, sorted),
/// filtering, selection → `BinaryLoadSelection`, the selector's Codable/wire round trip, the
/// router reaching the cache loader with the chosen image, and the persisted display path
/// resolving back to the same cache + install name. Uses the crafted single-image cache fixture;
/// no system cache is read.
final class DyldCacheImagePickerTests: XCTestCase {

    // MARK: - List and model

    func testPickerOptionsKeepNamedImagesOnceSortedByInstallName() {
        let images = [
            DyldCacheImage(address: 0x3000, pathFileOffset: 0, path: "/usr/lib/libz.1.dylib"),
            DyldCacheImage(address: 0x1000, pathFileOffset: 0, path: ""),
            DyldCacheImage(address: 0x2000, pathFileOffset: 0, path: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"),
            DyldCacheImage(address: 0x4000, pathFileOffset: 0, path: "/usr/lib/libz.1.dylib"),
            DyldCacheImage(address: 0x5000, pathFileOffset: 0, path: "/usr/lib/libSystem.B.dylib"),
        ]
        let options = LoaderCacheImageOption.pickerOptions(from: images)
        XCTAssertEqual(options.map(\.installName), [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/usr/lib/libSystem.B.dylib",
            "/usr/lib/libz.1.dylib",
        ])
        XCTAssertEqual(options.last?.address, 0x3000, "first occurrence of a duplicate install name wins")
        XCTAssertEqual(options.first?.fileName, "AppKit")
        XCTAssertEqual(options[1].directory, "/usr/lib")
    }

    func testFilterIsCaseInsensitiveSubstringAndEmptyQueryKeepsAll() {
        let options = LoaderCacheImageOption.pickerOptions(from: [
            DyldCacheImage(address: 1, pathFileOffset: 0, path: "/usr/lib/libobjc.A.dylib"),
            DyldCacheImage(address: 2, pathFileOffset: 0, path: "/System/Library/Frameworks/Foundation.framework/Foundation"),
        ])
        XCTAssertEqual(LoaderCacheImageOption.filter(options, query: "  ").count, 2)
        XCTAssertEqual(LoaderCacheImageOption.filter(options, query: "OBJC").map(\.fileName), ["libobjc.A.dylib"])
        XCTAssertTrue(LoaderCacheImageOption.filter(options, query: "UIKit").isEmpty)
    }

    func testMultiImageCacheRequiresAChoiceAndLoadsTheChosenImage() {
        let options = LoaderCacheImageOption.pickerOptions(from: [
            DyldCacheImage(address: 1, pathFileOffset: 0, path: "/usr/lib/libA.dylib"),
            DyldCacheImage(address: 2, pathFileOffset: 0, path: "/usr/lib/libB.dylib"),
        ])
        var model = LoaderOptionsModel(fileName: "cache", formatDescription: "dyld", slices: [], cacheImages: options)
        XCTAssertTrue(model.requiresChoice)
        XCTAssertTrue(model.isDyldSharedCache)
        XCTAssertNil(model.selectedCacheImage, "no default image: the picker replaces the first-image rule")
        XCTAssertFalse(model.canOpen)

        model.selectCacheImage(installName: "/usr/lib/libNotInCache.dylib")
        XCTAssertNil(model.selectedCacheImage, "unknown install names are ignored")

        model.selectCacheImage(installName: "/usr/lib/libB.dylib")
        XCTAssertTrue(model.canOpen)
        XCTAssertEqual(model.binaryLoadSelectionForLoad, .dyldCacheImage("/usr/lib/libB.dylib"))
        XCTAssertNil(model.binaryLoadSelectionForLoad.requestedMachOSliceIndex)
    }

    // MARK: - Selector encoding

    func testSelectionRoundTripsThroughCodableAndRejectsConflicts() throws {
        let selection = BinaryLoadSelection.dyldCacheImage("/usr/lib/libFixture.dylib")
        let decoded = try JSONDecoder().decode(BinaryLoadSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(decoded, selection)

        let legacy = try JSONDecoder().decode(BinaryLoadSelection.self, from: Data(#"{"requestedMachOSliceIndex":1}"#.utf8))
        XCTAssertNil(legacy.dyldCacheImagePath, "older records without the key still decode")

        let conflicting = Data(#"{"requestedMachOSliceIndex":0,"dyldCacheImagePath":"/usr/lib/libA.dylib"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BinaryLoadSelection.self, from: conflicting)) {
            XCTAssertEqual($0 as? BinaryLoadSelectionError, .conflictingSelectors)
        }
        let empty = Data(#"{"dyldCacheImagePath":""}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BinaryLoadSelection.self, from: empty)) {
            XCTAssertEqual($0 as? BinaryLoadSelectionError, .invalidDyldCacheImagePath)
        }
    }

    func testWireEnvelopeCarriesTheCacheImage() throws {
        let codec = PayloadWireCodec()
        let selection = BinaryLoadSelection.dyldCacheImage("/usr/lib/libFixture.dylib")
        let data = codec.encodeRequest(url: URL(fileURLWithPath: "/tmp/cache"), selection: selection,
                                       overrides: [:], requestID: UUID())
        XCTAssertEqual(try codec.decodeRequest(data).selection, selection)
    }

    // MARK: - Loading the chosen image

    func testRouterLoadsTheSelectedImageAndRefusesAnUnknownOne() throws {
        let cacheURL = try writeFixtureCache()
        let loaded = try BinaryLoaderRouter(selection: .dyldCacheImage("/usr/lib/libFixture.dylib")).load(at: cacheURL)
        XCTAssertEqual(loaded.name, "libFixture.dylib")
        XCTAssertEqual(loaded.path, "\(cacheURL.path)(/usr/lib/libFixture.dylib)")

        XCTAssertThrowsError(
            try BinaryLoaderRouter(selection: .dyldCacheImage("/usr/lib/libMissing.dylib")).load(at: cacheURL)
        ) { error in
            guard case DyldSharedCacheError.imageNotFound = error else {
                return XCTFail("expected imageNotFound, got \(error)")
            }
        }
    }

    func testInspectorListsCacheImagesAndASingleImageOpensWithoutAChoice() throws {
        let cacheURL = try writeFixtureCache()
        let model = LoaderOptionsInspector().inspect(url: cacheURL)
        XCTAssertEqual(model.cacheImages.map(\.installName), ["/usr/lib/libFixture.dylib"])
        XCTAssertTrue(model.formatDescription.hasPrefix("dyld shared cache (arm64e)"))
        XCTAssertFalse(model.requiresChoice)
        XCTAssertEqual(model.binaryLoadSelectionForLoad, .dyldCacheImage("/usr/lib/libFixture.dylib"))
    }

    // MARK: - Persisted choice

    func testProjectionDisplayPathResolvesToTheSameCacheAndImage() throws {
        let cacheURL = try writeFixtureCache()
        let loaded = try BinaryLoaderRouter(selection: .dyldCacheImage("libFixture.dylib")).load(at: cacheURL)
        let image = BinaryImage(id: UUID(), name: loaded.name, path: loaded.path, kind: "dylib", architecture: "arm64")
        let resolved = try XCTUnwrap(image.dyldCacheProjectionSelection)
        XCTAssertEqual(resolved.cacheURL.path, cacheURL.path)
        XCTAssertEqual(resolved.installName, "/usr/lib/libFixture.dylib")

        let notACache = BinaryImage(id: UUID(), name: "x", path: "/tmp/nowhere(/usr/lib/libA.dylib)",
                                    kind: "dylib", architecture: "arm64")
        XCTAssertNil(notACache.dyldCacheProjectionSelection)
    }

    @MainActor
    func testReanalysisWithoutCapturedBytesReprojectsThePickedImage() throws {
        let cacheURL = try writeFixtureCache()
        let path = "\(cacheURL.path)(/usr/lib/libFixture.dylib)"
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "libFixture.dylib", path: path, kind: "dylib", architecture: "arm64")],
            analysisBySlot: [:]
        )
        let store = WorkspaceStore(workspaceName: "Cache", snapshot: snapshot, engine: AnalysisEngine())
        let source = try XCTUnwrap(store.reanalysisSource(in: .primary))
        XCTAssertEqual(source.url.path, cacheURL.path)
        XCTAssertEqual(source.selection, .dyldCacheImage("/usr/lib/libFixture.dylib"))
        XCTAssertFalse(source.isRecovered)
    }

    // MARK: - Fixture

    private func writeFixtureCache() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-DyldPicker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try DyldCacheFixture.makeSingleImageCache().bytes.write(to: url)
        return url
    }
}
