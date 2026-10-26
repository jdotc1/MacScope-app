import Foundation
import ObjectiveC.runtime
import XCTest
@testable import MacScope

/// Real-binary oracle for the dyld shared-cache loader. `DyldSharedCacheParser` /
/// `DyldSharedCacheBinaryLoader` were once validated ONLY against self-built fixtures, which encode
/// the loader's own (classic) assumptions about the cache header and so cannot catch a wrong one
/// (self-mirror). This exercises the loader against the ACTUAL /System cache — and it caught a real
/// bug the 18 green fixtures hid: the loader recovered 0 images because it modeled a stale header.
///
/// RESOLVED (2026-06-27): the modern macOS split shared cache is now fully supported. The fix came
/// from decoding the real arm64e cache firsthand AND cross-checking Apple's authoritative
/// dyld_cache_format.h:
///   • the image array is the modern `imagesOffset/imagesCount` (u32) at 0x1C0/0x1C4 (the loader
///     had this offset as the sub-cache array; 0xE0 is `sharedRegionStart`, not imagesText@0x88);
///   • sub-cache discovery is the `subCacheArray` at 0x188/0x18C (79 sibling files, v2 56-byte
///     entries with a fileSuffix like ".01"/".79.dyldlinkedit");
///   • an image's bytes live in a sibling sub-cache file (libobjc's __TEXT is in `.01`), and its
///     __LINKEDIT (export trie etc.) in `.79.dyldlinkedit` — both resolved by VM address across the
///     stitched sub-cache files. The shared 1.6 GB __LINKEDIT / 960 MB string table are NOT copied;
///     exports come from the small per-image export trie (correctness over coverage).
/// This now asserts the FULL projection (real-cache header + image array + cross-sub-cache export
/// recovery). Skipped when no readable arm64e cache is present (CI / other hosts).
final class DyldSharedCacheRealBinaryTests: XCTestCase {

    private func locateCache() -> URL? {
        let candidates = [
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e",
            "/System/Library/dyld/dyld_shared_cache_arm64e",
        ]
        for path in candidates where FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func runtimeInstanceMethodTypeEncodings(for cls: AnyClass) -> [String: String] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [:] }
        defer { free(methods) }
        var encodings: [String: String] = [:]
        for index in 0..<Int(count) {
            let method = methods[index]
            let selector = String(cString: sel_getName(method_getName(method)))
            guard let typeEncoding = method_getTypeEncoding(method) else { continue }
            encodings[selector] = String(cString: typeEncoding)
        }
        return encodings
    }

    func testRealSharedCacheHeaderIsRecognized() throws {
        guard let cacheURL = locateCache() else {
            throw XCTSkip("no readable arm64e dyld shared cache on this host")
        }
        let bytes = try Data(contentsOf: cacheURL, options: [.mappedIfSafe])

        // The loader DOES correctly recognize the real cache's header + architecture.
        let header = try DyldSharedCacheParser().parseHeader(bytes)
        XCTAssertTrue(header.magicString.hasPrefix("dyld_v1"), "magic was \(header.magicString)")
        XCTAssertEqual(header.architecture, "arm64e")
        XCTAssertGreaterThan(header.mappingCount, 0, "the cache must declare at least one mapping")

        // Modern split-cache support (2026-06-27): the loader now reads the modern image array
        // (imagesOffset@0x1C0) and sub-cache descriptors (subCacheArray@0x188), so it recovers the
        // full image + sub-cache set from the real cache.
        XCTAssertGreaterThan(header.imagesCount, 0, "modern image array (imagesOffset@0x1C0) must recover images")
        XCTAssertGreaterThan(header.subCacheArrayCount, 0, "the split cache must declare sibling sub-caches")
        XCTAssertTrue(header.images.contains { $0.path == "/usr/lib/libobjc.A.dylib" },
                      "the image array must list /usr/lib/libobjc.A.dylib")

        // Full cross-sub-cache projection: libobjc's bytes live in a sibling sub-cache file, so this
        // exercises the on-disk sub-cache discovery + multi-file stitching end-to-end.
        let loaded = try DyldSharedCacheBinaryLoader(targetImagePath: "/usr/lib/libobjc.A.dylib").load(at: cacheURL)
        let names = Set(loaded.exports.map(\.name)).union(loaded.symbols.map(\.name))
        print("DYLD-REAL libobjc: cpuType=\(loaded.cpuType) sections=\(loaded.sections.count) "
            + "symbols=\(loaded.symbols.count) exports=\(loaded.exports.count) "
            + "hasClassGetName=\(names.contains("_class_getName"))")
        XCTAssertTrue(loaded.name.contains("libobjc"), "projected image name should reflect libobjc")
        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeARM64)
        XCTAssertGreaterThan(loaded.sections.count, 0, "projection must recover sections")
        XCTAssertNotNil(loaded.executableTextSection, "projection must recover the __text section")
        // Headline capability: a known export recovered from the cross-sub-cache export trie
        // (libobjc's __LINKEDIT lives in a sibling .dyldlinkedit file). swift/objc public API.
        XCTAssertTrue(names.contains("_class_getName"),
                      "the cross-sub-cache export trie must recover libobjc's _class_getName export")

        // ObjC class-dump of a CACHED dylib: the class metadata uses the
        // DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE pointer encoding and its name strings live in the
        // shared __OBJC_RO (not projected per-image), so this exercises the cache-pointer decode +
        // the on-demand shared-region reader. Ground truth = firsthand walk of libobjc's classlist.
        let classNames = Set(loaded.objcClasses.map(\.name))
        print("DYLD-REAL libobjc objc: classes=\(loaded.objcClasses.count) names=\(classNames.sorted())")
        for expected in ["Object", "Protocol", "__IncompleteProtocol", "__NSUnrecognizedTaggedPointer", "NSObject"] {
            XCTAssertTrue(classNames.contains(expected),
                          "cached-dylib ObjC class-dump must recover \(expected); got \(classNames.sorted())")
        }

        // Methods: the cache encodes relative-method-list selectors as offsets from the shared
        // selector base (__objc_scoffs), NOT field-relative — a names-only oracle hid that the first
        // cut decoded them to garbage. Assert the real selectors for Object's 12-byte direct-selector
        // list, the preoptimized NSObject list-of-lists, exact NSObject type encodings over the
        // runtime/parser intersection, and that NO recovered selector or type string is garbage.
        let objectClass = loaded.objcClasses.first { $0.name == "Object" }
        let objectSelectors = Set((objectClass?.instanceMethods ?? []).map(\.selector))
        print("DYLD-REAL libobjc Object methods: \(objectSelectors.sorted())")
        for sel in ["release", "retain", "autorelease"] {
            XCTAssertTrue(objectSelectors.contains(sel),
                          "Object's cache method list must recover '\(sel)'; got \(objectSelectors.sorted())")
        }
        let allSelectors = loaded.objcClasses.flatMap { $0.instanceMethods + $0.classMethods }.map(\.selector)
        for selector in allSelectors {
            XCTAssertTrue(selector.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e },
                          "recovered a non-printable/garbage selector \(Array(selector.utf8)) — cache method decode is wrong")
        }
        let allTypeEncodings = loaded.objcClasses.flatMap { $0.instanceMethods + $0.classMethods }.compactMap(\.typeEncoding)
        for typeEncoding in allTypeEncodings {
            XCTAssertTrue(typeEncoding.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e },
                          "recovered a non-printable/garbage type encoding \(Array(typeEncoding.utf8))")
        }

        let nsObject = try XCTUnwrap(loaded.objcClasses.first { $0.name == "NSObject" })
        XCTAssertGreaterThan(nsObject.instanceMethods.count, 200,
                             "NSObject's preoptimized list-of-lists should recover a large method set")
        // Two-tier encoding oracle. The method-types base (__objc_scoffs-derived) is
        // firsthand-verified only for the macOS 27 cache layout; the macOS 26 cache
        // resolves types offsets into the SELECTOR region (measured on CI). So:
        // - a non-nil recovered encoding must equal the live runtime EVERYWHERE
        //   (a mismatch is fabrication, never acceptable);
        // - nil (abstention) is tolerated only on pre-27 hosts, where the decoder's
        //   plausibility net rejects the mis-based strings. Encoding recovery for
        //   older cache layouts is the tracked cache-method-types follow-up.
        let typesBaseVerified = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let runtimeNSObjectTypes = runtimeInstanceMethodTypeEncodings(for: NSObject.self)
        var sharedEncodingComparisons = 0
        var abstentions = 0
        for method in nsObject.instanceMethods {
            guard let expected = runtimeNSObjectTypes[method.selector] else { continue }
            sharedEncodingComparisons += 1
            if let recovered = method.typeEncoding {
                XCTAssertEqual(recovered, expected,
                               "NSObject selector \(method.selector) type encoding must match the live ObjC runtime (fabrication)")
            } else if typesBaseVerified {
                XCTFail("NSObject selector \(method.selector) type encoding missing on a verified cache layout")
            } else {
                abstentions += 1
            }
        }
        print("DYLD-REAL libobjc NSObject methods: recovered=\(nsObject.instanceMethods.count) "
            + "runtimeIntersection=\(sharedEncodingComparisons) abstained=\(abstentions)")
        XCTAssertGreaterThan(sharedEncodingComparisons, 50,
                             "the type-encoding oracle should compare a broad NSObject method intersection")
    }
}
