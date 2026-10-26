import XCTest
@testable import MacScope

/// Regression fixtures for dyld-cache ObjC method-list forms that do not appear in ordinary Mach-O
/// test binaries: preoptimized list-of-lists plus cache direct-selector type encodings.
final class ObjCCacheMethodListTests: XCTestCase {

    private let base: UInt64 = 0x1000
    private let meta: UInt64 = 0x0010_0000_0000_0000

    private func leU32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func leU64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func commonSections() -> [ObjCClassParser.Section] {
        [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x5f8, name: "__objc_const"),
            ObjCClassParser.Section(address: 0x1600, fileOffset: 0x600, size: 16, name: "__objc_scoffs"),
        ]
    }

    private func putU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes.replaceSubrange(offset..<offset + 4, with: leU32(value))
    }

    private func putU64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        bytes.replaceSubrange(offset..<offset + 8, with: leU64(value))
    }

    private func putString(_ bytes: inout [UInt8], _ offset: Int, _ string: String) {
        bytes.replaceSubrange(offset..<offset + string.utf8.count + 1, with: Array((string + "\u{0}").utf8))
    }

    private func putCachePointer(_ bytes: inout [UInt8], _ offset: Int, target: UInt64) {
        putU64(&bytes, offset, meta | (target - base))
    }

    private func putRelativeListEntry(_ bytes: inout [UInt8], entryAddress: UInt64, target: UInt64, imageIndex: UInt16) {
        let signedOffset = Int64(bitPattern: target) - Int64(bitPattern: entryAddress)
        let rawOffset = UInt64(bitPattern: signedOffset) & 0x0000_FFFF_FFFF_FFFF
        putU64(&bytes, Int(entryAddress - base), (rawOffset << 16) | UInt64(imageIndex))
    }

    private func seedCacheClass(_ bytes: inout [UInt8], methodsPointer: UInt64) {
        putCachePointer(&bytes, 0x00, target: 0x1040)        // classlist[0] -> class_t
        putCachePointer(&bytes, 0x60, target: 0x1080)        // class_t.data -> class_ro_t
        putCachePointer(&bytes, 0x98, target: 0x1300)        // class_ro_t.name -> "CacheList"
        putCachePointer(&bytes, 0xa0, target: methodsPointer) // class_ro_t.baseMethods
        putString(&bytes, 0x300, "CacheList")
        putU64(&bytes, 0x608, meta | 0x400)                 // __objc_scoffs[1] -> selector base 0x1400
    }

    private func parse(_ bytes: [UInt8]) -> ObjCClass? {
        ObjCClassParser(data: Data(bytes), sections: commonSections(), rebaseTargets: [:], bindNames: [:],
                        cachePointerBase: base, cacheReadBytes: nil,
                        parseBudget: ObjCClassParser.ParseBudget(1_000)).parseClasses().first
    }

    func testWalksRelativeListListAndDecodesCacheTypeEncodingsFromSelectorBase() {
        var bytes = [UInt8](repeating: 0, count: 0x700)
        seedCacheClass(&bytes, methodsPointer: 0x1181)       // low PointerUnion bit is masked off

        putU32(&bytes, 0x180, 8)                             // relative_list_list_t header
        putU32(&bytes, 0x184, 2)
        putRelativeListEntry(&bytes, entryAddress: 0x1188, target: 0x1200, imageIndex: 1)
        putRelativeListEntry(&bytes, entryAddress: 0x1190, target: 0x1240, imageIndex: 2)

        putU32(&bytes, 0x200, 0xC000_000C)                   // small + direct selectors + entsize 12
        putU32(&bytes, 0x204, 1)
        putU32(&bytes, 0x208, 0x20)                          // selector base + 0x20 -> alpha
        putU32(&bytes, 0x20c, 0x50)                          // selector base + 0x50 -> @16@0:8

        putU32(&bytes, 0x240, 0xC000_000C)
        putU32(&bytes, 0x244, 1)
        putU32(&bytes, 0x248, 0x30)                          // selector base + 0x30 -> beta:
        putU32(&bytes, 0x24c, 0x60)                          // selector base + 0x60 -> v24@0:8@16

        putString(&bytes, 0x420, "alpha")
        putString(&bytes, 0x430, "beta:")
        putString(&bytes, 0x450, "@16@0:8")
        putString(&bytes, 0x460, "v24@0:8@16")

        XCTAssertEqual(parse(bytes)?.instanceMethods, [
            ObjCMethod(selector: "alpha", typeEncoding: "@16@0:8", isClassMethod: false),
            ObjCMethod(selector: "beta:", typeEncoding: "v24@0:8@16", isClassMethod: false),
        ])
    }

    func testNestedRelativeListListDoesNotRecurse() {
        var bytes = [UInt8](repeating: 0, count: 0x700)
        seedCacheClass(&bytes, methodsPointer: 0x1181)

        putU32(&bytes, 0x180, 8)
        putU32(&bytes, 0x184, 1)
        putRelativeListEntry(&bytes, entryAddress: 0x1188, target: 0x1200, imageIndex: 1)
        putU32(&bytes, 0x200, 8)                             // nested list-of-lists header
        putU32(&bytes, 0x204, 1)
        putRelativeListEntry(&bytes, entryAddress: 0x1208, target: 0x1240, imageIndex: 1)

        XCTAssertEqual(parse(bytes)?.instanceMethods, [],
                       "nested entsize-8 targets are rejected through allowListOfLists: false")
    }

    func testImplausibleCacheTypeEncodingIsAbsentNotSurfaced() {
        var bytes = [UInt8](repeating: 0, count: 0x700)
        seedCacheClass(&bytes, methodsPointer: 0x1181)

        putU32(&bytes, 0x180, 8)
        putU32(&bytes, 0x184, 1)
        putRelativeListEntry(&bytes, entryAddress: 0x1188, target: 0x1200, imageIndex: 1)
        putU32(&bytes, 0x200, 0xC000_000C)
        putU32(&bytes, 0x204, 1)
        putU32(&bytes, 0x208, 0x20)
        putU32(&bytes, 0x20c, 0x50)
        putString(&bytes, 0x420, "validSelector")
        putString(&bytes, 0x450, "zNotATypeEncoding")

        XCTAssertEqual(parse(bytes)?.instanceMethods, [
            ObjCMethod(selector: "validSelector", typeEncoding: nil, isClassMethod: false),
        ])
    }
}
