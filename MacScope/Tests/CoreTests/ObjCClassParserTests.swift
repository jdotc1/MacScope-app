import XCTest
@testable import MacScope

/// The ObjC class-structure walker, validated deterministically against a synthetic Mach-O
/// image (no real binary, no fixups — raw pointers are vmaddrs). Exercises classlist →
/// `class_t` → `class_ro_t` → name, the `data` low-bit masking, vmaddr→fileOffset mapping, and
/// C-string reading. The chained-fixup path is exercised by the real-binary integration test.
final class ObjCClassParserTests: XCTestCase {

    private func leU64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }

    func testParsesClassNameAndRootSuperclassFromSyntheticImage() {
        // Base vmaddr 0x1000 ↔ file offset 0. Layout (file offsets):
        //   0x000 classlist[0] -> class_t @0x1040
        //   0x040 class_t: isa(0x40) super(0x48)=0 cache(0x50,0x58) data(0x60)->class_ro @0x1080
        //   0x080 class_ro: flags/start/size/reserved(16B), ivarLayout(0x90), name(0x98)->"Widget" @0x1100
        //   0x100 "Widget\0"
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ offset: Int, _ value: UInt64) { bytes.replaceSubrange(offset..<offset + 8, with: leU64(value)) }
        put(0x00, 0x1040)                 // classlist[0]
        put(0x60, 0x1080 | 0x3)           // class_t.data with FAST-flag low bits set (must be masked off)
        put(0x98, 0x1100)                 // class_ro.name
        bytes.replaceSubrange(0x100..<0x107, with: Array("Widget\u{0}".utf8))

        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x2f8, name: "__objc_const"),
        ]
        let parser = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:])
        let classes = parser.parseClasses()

        XCTAssertEqual(classes.count, 1)
        XCTAssertEqual(classes.first?.name, "Widget")
        XCTAssertNil(classes.first?.superclassName, "a class with a null superclass is a root class")
    }

    func testResolvesBoundSuperclassNameFromSymbol() {
        // Same single class, but its superclass pointer is a BIND to _OBJC_CLASS_$_NSObject.
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ offset: Int, _ value: UInt64) { bytes.replaceSubrange(offset..<offset + 8, with: leU64(value)) }
        put(0x00, 0x1040)
        put(0x60, 0x1080)
        put(0x98, 0x1100)
        bytes.replaceSubrange(0x100..<0x104, with: Array("Foo\u{0}".utf8))

        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x2f8, name: "__objc_const"),
        ]
        // The superclass field lives at class_t + 8 = 0x1048; bind it to the external class symbol.
        let parser = ObjCClassParser(
            data: Data(bytes), sections: sections,
            rebaseTargets: [:], bindNames: [0x1048: "_OBJC_CLASS_$_NSObject"]
        )
        let classes = parser.parseClasses()
        XCTAssertEqual(classes.first?.name, "Foo")
        XCTAssertEqual(classes.first?.superclassName, "NSObject")
    }

    func testParseBudgetBoundsTheClassWalk() {
        // A classlist of 20 entries, all pointing to ONE valid class. Without a budget every entry is
        // parsed; with a small budget the walk stops early. This is the guard that bounds an untrusted
        // dyld-cache image's ObjC walk — the whole-cache reader removes the natural file-size bound, so
        // a hostile classlist/member count could otherwise fan out unboundedly.
        let entryCount = 20
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ offset: Int, _ value: UInt64) { bytes.replaceSubrange(offset..<offset + 8, with: leU64(value)) }
        for i in 0..<entryCount { put(i * 8, 0x2000) }   // every classlist entry -> the same class_t @0x2000
        put(0x220, 0x2040)                                // class_t.data (@+32) -> class_ro @0x2040
        put(0x258, 0x2080)                                // class_ro.name (@+24) -> "Widget" @0x2080
        bytes.replaceSubrange(0x280..<0x287, with: Array("Widget\u{0}".utf8))

        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: UInt64(entryCount * 8), name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x2000, fileOffset: 0x200, size: 0x100, name: "__objc_const"),
        ]
        func recovered(budget: ObjCClassParser.ParseBudget?) -> Int {
            ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:],
                            cachePointerBase: nil, cacheReadBytes: nil, parseBudget: budget).parseClasses().count
        }
        XCTAssertEqual(recovered(budget: nil), 20, "no budget parses every classlist entry")
        XCTAssertEqual(recovered(budget: ObjCClassParser.ParseBudget(5)), 5,
                       "a budget of 5 must stop the class walk after 5 entries")
    }

    func testDecodesSharedCacheChainedPointers() {
        // A dyld-cache image's ObjC pointers are DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE rebases:
        // target = cachePointerBase + (raw & 0x3FFFFFFFF). The high bits (auth/next metadata) MUST be
        // masked off — a naive raw read sends every pointer out of range and recovers nothing.
        var bytes = [UInt8](repeating: 0, count: 0x200)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        let meta: UInt64 = 0x0010_0000_0000_0000   // high metadata bits (above bit 34) that must be ignored
        put(0x00, meta | 0x40)            // classlist[0]  -> base + 0x40  = class_t @0x1040
        put(0x60, meta | 0x80)            // class_t.data  -> base + 0x80  = class_ro @0x1080
        put(0x98, meta | 0x100)           // class_ro.name -> base + 0x100 = "Widget" @0x1100
        bytes.replaceSubrange(0x100..<0x107, with: Array("Widget\u{0}".utf8))
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x1f8, name: "__objc_const"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:],
                                  cachePointerBase: 0x1000).parseClasses().first
        XCTAssertEqual(cls?.name, "Widget", "cache-chained pointers must decode to base + (raw & 0x3FFFFFFFF)")
    }

    func testDecodesCacheDirectSelectorMethod() {
        // In a cache image a small list with `relativeMethodSelectorsAreDirect` encodes each `name` as
        // an UNSIGNED offset from the shared selector base (__objc_scoffs[1]) — NOT a field-relative
        // delta (which lands in code = garbage, the bug the adversarial review caught).
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        let meta: UInt64 = 0x0010_0000_0000_0000
        put(0x00, meta | 0x40)            // classlist[0]        -> class_t @0x1040
        put(0x60, meta | 0x80)            // class_t.data        -> class_ro @0x1080
        put(0x98, meta | 0x200)           // class_ro.name       -> "Cache" @0x1200
        put(0xa0, meta | 0x100)           // class_ro.baseMethods-> method_list @0x1100
        putU32(0x100, 0xC000_000C)        // small + relativeMethodSelectorsAreDirect (0x40000000) + entsize 12
        putU32(0x104, 1)                  // count
        putU32(0x108, 0x10)               // entry[0].name = UNSIGNED offset from selector base
        putStr(0x190, "ping")             // selector @ selBase(0x1180) + 0x10 = 0x1190
        putStr(0x200, "Cache")            // class name @0x1200
        put(0x308, meta | 0x180)          // __objc_scoffs[1] -> selector base @0x1180
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x2f8, name: "__objc_const"),
            ObjCClassParser.Section(address: 0x1300, fileOffset: 0x300, size: 16, name: "__objc_scoffs"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:],
                                  cachePointerBase: 0x1000).parseClasses().first
        XCTAssertEqual(cls?.name, "Cache")
        XCTAssertEqual(cls?.instanceMethods.map(\.selector), ["ping"],
                       "a cache direct-selector method's name is an offset from __objc_scoffs[1], not field-relative")
    }

    // MARK: - Method lists (synthetic)

    private func leU32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }

    /// Absolute/big method list (24-byte pointer triples) — the format plutil's arm64e slice does
    /// NOT use, so it gets no real-binary coverage otherwise.
    func testParsesBigAbsoluteMethodList() {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        // base VA 0x1000 ↔ fo 0. classlist[0]->class_t@0x1040; ro@0x1080; baseMethods->mlist@0x1180.
        put(0x00, 0x1040)                 // classlist[0]
        put(0x60, 0x1080)                 // class_t.data (VA 0x1060) -> ro
        put(0x98, 0x1100)                 // ro.name (VA 0x1098)
        put(0xa0, 0x1180)                 // ro.baseMethods (VA 0x10a0) -> method_list
        putStr(0x100, "Gadget")           // VA 0x1100
        putU32(0x180, 24)                 // method_list entsize_and_flags (VA 0x1180): big, 24
        putU32(0x184, 1)                  // count
        put(0x188, 0x1200)               // entry[0].name -> "doThing"
        put(0x190, 0x1210)               // entry[0].types -> "v16@0:8"
        put(0x198, 0x1300)               // entry[0].imp (not surfaced)
        putStr(0x200, "doThing")          // VA 0x1200
        putStr(0x210, "v16@0:8")          // VA 0x1210
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x3f8, name: "__objc_const"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.name, "Gadget")
        // The IMP (3rd method_t pointer, +16) is now captured — here it resolves to VA 0x1300.
        XCTAssertEqual(cls?.instanceMethods, [ObjCMethod(selector: "doThing", typeEncoding: "v16@0:8", isClassMethod: false, implementation: 0x1300)])
        XCTAssertEqual(cls?.classMethods, [])
    }

    /// A method whose selector decodes to non-printable bytes (what a mis-decoded cache method-list
    /// pointer yields — it lands in code) MUST be dropped, never surfaced as a mojibake selector in
    /// the class-dump. Locks the `isPlausibleSelector` net (otherwise only the CI-skipped real-cache
    /// oracle exercises it — the green≠correct trap the adversarial review caught).
    func testGarbageSelectorMethodIsDropped() {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040)                 // classlist[0] -> class_t@0x1040
        put(0x60, 0x1080)                 // class_t.data -> ro@0x1080
        put(0x98, 0x1100)                 // ro.name -> "Gadget"
        put(0xa0, 0x1180)                 // ro.baseMethods -> method_list@0x1180
        putStr(0x100, "Gadget")
        putU32(0x180, 24)                 // big method list, entsize 24
        putU32(0x184, 1)                  // count 1
        put(0x188, 0x1200)               // entry[0].name -> the (garbage) selector bytes
        put(0x190, 0x1210)               // entry[0].types
        bytes.replaceSubrange(0x200..<0x205, with: [0x01, 0x02, 0x03, 0x04, 0x00]) // non-printable "selector"
        putStr(0x210, "v16@0:8")
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x3f8, name: "__objc_const"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.name, "Gadget", "the class itself is still recovered")
        XCTAssertEqual(cls?.instanceMethods, [], "a non-printable selector must be dropped, never surfaced as garbage")
    }

    /// Relative/small method list (12-byte int32 triples) with selref indirection for `name` and a
    /// NEGATIVE relative offset for `types` — locks the signed field-relative arithmetic + the
    /// __objc_selrefs hop deterministically (plutil proves it end-to-end through real fixups).
    func testParsesSmallRelativeMethodListWithSelrefAndNegativeOffset() {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040)                 // classlist[0] -> class_t @0x1040
        put(0x60, 0x1080)                 // class_t.data -> ro @0x1080
        put(0x98, 0x1100)                 // ro.name -> "Sprocket"
        put(0xa0, 0x1180)                 // ro.baseMethods -> mlist @0x1180
        putStr(0x10, "@16@0:8")           // types string at VA 0x1010 (target of a NEGATIVE offset)
        putStr(0x100, "Sprocket")         // VA 0x1100
        putU32(0x180, 0x8000_000C)        // mlist entsize_and_flags: small flag + entsize 12
        putU32(0x184, 1)                  // count
        // entry @ VA 0x1188 (fo 0x188): name int32@+0, types int32@+4, imp int32@+8.
        putU32(0x188, 0x0000_00F8)        // name: 0x1188 + 0xF8 = 0x1280 (selref slot)
        putU32(0x18c, UInt32(bitPattern: Int32(0x1010 - 0x118c))) // types: 0x118c + (-0x17C) = 0x1010
        putU32(0x190, 0)                  // imp (not surfaced)
        put(0x280, 0x12C0)               // selref slot (VA 0x1280) -> selector string @0x12C0
        putStr(0x2C0, "frob:")            // selector string at VA 0x12C0
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x278, name: "__objc_const"),
            ObjCClassParser.Section(address: 0x1280, fileOffset: 0x280, size: 8, name: "__objc_selrefs"),
            ObjCClassParser.Section(address: 0x1288, fileOffset: 0x288, size: 0x178, name: "__objc_methname"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.name, "Sprocket")
        XCTAssertEqual(cls?.instanceMethods, [ObjCMethod(selector: "frob:", typeEncoding: "@16@0:8", isClassMethod: false)])
    }

    // MARK: - Method lists (hardening / malformed input)

    /// Crash gate: a `baseMethods` that resolves to a near-UInt64.max address, with a section that
    /// maps it and a plausible header + large count, must NOT trap Swift's checked arithmetic
    /// (entry-stride / field adds). Before the overflow guards this trapped (SIGILL).
    func testDoesNotTrapOnOverflowingMethodListAddress() {
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        let listVA: UInt64 = 0xFFFF_FFFF_FFFF_F000
        put(0x00, 0x1040)                 // classlist[0] -> class_t
        put(0x60, 0x1080)                 // class_t.data -> ro
        put(0x98, 0x1100)                 // ro.name -> "Edge"
        put(0xa0, listVA)                 // ro.baseMethods -> near-max address
        putStr(0x100, "Edge")
        putU32(0x180, 24)                 // method_list header in the high section: big, entsize 24
        putU32(0x184, 300)                // a large count that drives the entry stride to overflow
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x178, name: "__objc_const"),
            ObjCClassParser.Section(address: listVA, fileOffset: 0x180, size: 0x80, name: "__huge"),
        ]
        let classes = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses()
        XCTAssertEqual(classes.first?.name, "Edge")           // parsed without trapping
        XCTAssertLessThanOrEqual(classes.first?.instanceMethods.count ?? 0, 300)
    }

    /// Crash gate for the selector-reference section test: an attacker-controlled relative `name`
    /// target (here an INT32_MIN delta wraps it high) that lands in a `__objc_selrefs` section whose
    /// `address + size` overflows UInt64 must not trap. Before the fix this trapped in
    /// `isSelectorReference`'s `address + size`.
    func testDoesNotTrapOnOverflowingSelrefSection() {
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040); put(0x60, 0x1080); put(0x98, 0x1100); put(0xa0, 0x1180)
        putStr(0x100, "SelEdge")
        putU32(0x180, 0x8000_000C); putU32(0x184, 1)         // small, count 1
        putU32(0x188, 0x8000_0000)        // name delta INT32_MIN -> wraps target to ~0xFFFFFFFF80001188
        putU32(0x18c, 0)                  // types delta 0
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x1f8, name: "__objc_const"),
            // address + size overflows UInt64; the name target lands inside it.
            ObjCClassParser.Section(address: 0xFFFF_FFFF_8000_1000, fileOffset: 0x200, size: 0x8000_0000, name: "__objc_selrefs"),
        ]
        let classes = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses()
        XCTAssertEqual(classes.first?.name, "SelEdge")        // parsed without trapping
        XCTAssertEqual(classes.first?.instanceMethods, [])     // the malformed method is skipped
    }

    /// A method list whose `entsize` is neither 12 (small) nor 24 (big) is malformed (or a tagged
    /// list-of-lists we don't decode) — the walker bails rather than striding by a bogus size.
    func testRejectsMethodListWithMalformedEntrySize() {
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040); put(0x60, 0x1080); put(0x98, 0x1100); put(0xa0, 0x1180)
        putStr(0x100, "Bad")
        putU32(0x180, 16)                 // entsize 16 — not 24 (big) → reject
        putU32(0x184, 4)
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x2f8, name: "__objc_const"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.name, "Bad")
        XCTAssertEqual(cls?.instanceMethods, [], "a malformed entsize yields no methods, not misaligned garbage")
    }

    /// A small method with a zero `types` delta means "no encoding" (the field points at itself);
    /// surface nil rather than reading the delta bytes back as a garbage string. Also exercises the
    /// DIRECT-name path (no __objc_selrefs section → name resolves straight to the string).
    func testSmallMethodWithZeroTypesDeltaHasNilEncoding() {
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040); put(0x60, 0x1080); put(0x98, 0x1100); put(0xa0, 0x1180)
        putStr(0x100, "Thing")
        putU32(0x180, 0x8000_000C); putU32(0x184, 1)         // small, count 1
        putU32(0x188, 0x78)               // name: 0x1188 + 0x78 = 0x1200 (direct string, no selref)
        putU32(0x18c, 0)                  // types delta 0 -> nil encoding
        putStr(0x200, "doIt")
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x1f8, name: "__objc_const"),
            ObjCClassParser.Section(address: 0x1200, fileOffset: 0x200, size: 0x40, name: "__objc_methname"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.instanceMethods, [ObjCMethod(selector: "doIt", typeEncoding: nil, isClassMethod: false)])
    }

    // MARK: - Ivars / properties / protocols (synthetic)

    /// ivar_list_t (entsize 32: name@8, type@16) and property_list_t (entsize 16: name@0,
    /// attributes@8) — both entsize_list_tt like methods, walked from class_ro_t.ivars@48 /
    /// baseProperties@64.
    func testParsesIvarAndPropertyLists() {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: leU32(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040)                 // classlist[0] -> class_t
        put(0x60, 0x1080)                 // class_t.data -> ro
        put(0x98, 0x1100)                 // ro.name -> "Gizmo"
        put(0xb0, 0x1180)                 // ro.ivars (VA 0x10b0 = ro+48) -> ivar_list
        put(0xc0, 0x1280)                 // ro.baseProperties (VA 0x10c0 = ro+64) -> property_list
        putStr(0x100, "Gizmo")
        putU32(0x180, 32); putU32(0x184, 1)                   // ivar_list: entsize 32, count 1
        put(0x190, 0x1200)               // ivar_t.name (VA 0x1190 = entry+8) -> "_count"
        put(0x198, 0x1210)               // ivar_t.type (VA 0x1198 = entry+16) -> "q"
        putStr(0x200, "_count"); putStr(0x210, "q")
        putU32(0x280, 16); putU32(0x284, 1)                   // property_list: entsize 16, count 1
        put(0x288, 0x1300)               // property_t.name (VA 0x1288 = entry+0) -> "title"
        put(0x290, 0x1310)               // property_t.attributes (entry+8) -> attrs
        putStr(0x300, "title"); putStr(0x310, "T@\"NSString\",N")
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x3f8, name: "__objc_const"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.ivars, [ObjCIvar(name: "_count", typeEncoding: "q")])
        XCTAssertEqual(cls?.properties, [ObjCProperty(name: "title", attributes: "T@\"NSString\",N")])
    }

    func testProtocolObjectsAreBoundedAndIndependentOfClasses() {
        var bytes = [UInt8](repeating: 0, count: 256)
        func put(_ offset: Int, _ value: UInt64) { bytes.replaceSubrange(offset..<offset + 8, with: leU64(value)) }
        put(0, 32); put(8, 32); put(16, UInt64.max - 4)
        put(40, 128); put(96, 72) // protocol name pointer and size
        bytes.replaceSubrange(128..<135, with: Array("Lonely\0".utf8))
        let parser = ObjCClassParser(data: Data(bytes), sections: [
            .init(address: 0, fileOffset: 0, size: 24, name: "__objc_protolist"),
            .init(address: 24, fileOffset: 24, size: 232, name: "__objc_const"),
        ], rebaseTargets: [:], bindNames: [:])
        XCTAssertTrue(parser.parseClasses().isEmpty)
        XCTAssertEqual(parser.parseProtocols().map(\.name), ["Lonely"])
        bytes[96] = 64 // truncated protocol prefix is not a valid object
        var malformed = parser; malformed.data = Data(bytes)
        XCTAssertTrue(malformed.parseProtocols().isEmpty)
    }

    /// protocol_list_t is NOT an entsize list: uintptr count@0, then 8-byte protocol_t pointers;
    /// protocol_t.name@8. Covers both an in-image protocol_t and an external BIND (_OBJC_PROTOCOL_$_).
    func testParsesProtocolListInImageAndBind() {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040)                 // classlist[0] -> class_t
        put(0x60, 0x1080)                 // class_t.data -> ro
        put(0x98, 0x1100)                 // ro.name -> "Proto"
        put(0xa8, 0x1180)                 // ro.baseProtocols (VA 0x10a8 = ro+40) -> protocol_list
        putStr(0x100, "Proto")
        put(0x180, 2)                     // protocol_list_t.count (uintptr, 8 bytes) = 2
        put(0x188, 0x1200)               // list[0] -> in-image protocol_t @0x1200
        // list[1] (VA 0x1190) is a BIND to _OBJC_PROTOCOL_$_NSCopying (set via bindNames below)
        put(0x208, 0x1300)               // protocol_t.name (VA 0x1208 = proto+8) -> "NSCoding"
        putStr(0x300, "NSCoding")
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x3f8, name: "__objc_const"),
        ]
        let parser = ObjCClassParser(
            data: Data(bytes), sections: sections,
            rebaseTargets: [:], bindNames: [0x1190: "_OBJC_PROTOCOL_$_NSCopying"]
        )
        XCTAssertEqual(parser.parseClasses().first?.adoptedProtocols, ["NSCoding", "NSCopying"])
    }

    /// Crash gate for the protocol walk: a baseProtocols that resolves to a near-UInt64.max
    /// address with a section mapping it and a large count must not trap the slot-address
    /// arithmetic (listAddress + 8 + index*8).
    func testDoesNotTrapOnOverflowingProtocolList() {
        var bytes = [UInt8](repeating: 0, count: 0x300)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: leU64(v)) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        let listVA: UInt64 = 0xFFFF_FFFF_FFFF_F000
        put(0x00, 0x1040)                 // classlist[0] -> class_t
        put(0x60, 0x1080)                 // class_t.data -> ro
        put(0x98, 0x1100)                 // ro.name -> "ProtoEdge"
        put(0xa8, listVA)                 // ro.baseProtocols (ro+40) -> near-max address
        putStr(0x100, "ProtoEdge")
        put(0x180, 700)                   // protocol_list_t.count (uintptr) — large, drives slot overflow
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x178, name: "__objc_const"),
            ObjCClassParser.Section(address: listVA, fileOffset: 0x180, size: 0x80, name: "__huge"),
        ]
        let cls = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:]).parseClasses().first
        XCTAssertEqual(cls?.name, "ProtoEdge")            // parsed without trapping
        XCTAssertEqual(cls?.adoptedProtocols, [])          // garbage entries resolve to nothing
    }

    /// Real-binary protocol oracle (otool ground truth): /usr/libexec/usbnotificationagent's
    /// USBNotificationAgentCenter adopts UNUserNotificationCenterDelegate, with ivars + properties.
    func testRecoversProtocolsFromRealBinary() throws {
        let path = "/usr/libexec/usbnotificationagent"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("\(path) absent") }
        let machO = try MachOParser().parse(try Data(contentsOf: URL(fileURLWithPath: path)))
        let classes = machO.objectiveCMetadata.classes
        let allProtocols = Set(classes.flatMap(\.adoptedProtocols))
        XCTAssertTrue(allProtocols.contains("UNUserNotificationCenterDelegate"),
                      "recovered protocols: \(allProtocols.sorted())")
        if let center = classes.first(where: { $0.name == "USBNotificationAgentCenter" }) {
            XCTAssertTrue(center.adoptedProtocols.contains("UNUserNotificationCenterDelegate"))
            XCTAssertTrue(center.ivars.contains { $0.name == "_bundle" }, "ivars: \(center.ivars.map(\.name))")
            XCTAssertTrue(center.properties.contains { $0.name == "bundle" }, "properties: \(center.properties.map(\.name))")
        }
    }

    // MARK: - Real-binary integration (chained fixups, arm64e)

    /// End-to-end on a real system binary: `/usr/bin/plutil` defines exactly three ObjC classes
    /// (otool -ov ground truth: PLUMutableArray, PLUMutableDictionary, PLUContext). This drives
    /// the full Mach-O path — fat-slice selection, chained-fixup resolution, and the class walk.
    func testRecoversClassesFromRealBinaryPlutil() throws {
        let path = "/usr/bin/plutil"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(path) is not present on this host")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let machO = try MachOParser().parse(data)
        let classes = machO.objectiveCMetadata.classes
        let names = Set(classes.map(\.name))
        XCTAssertEqual(
            names,
            ["PLUMutableArray", "PLUMutableDictionary", "PLUContext"],
            "recovered class names did not match otool ground truth: \(names.sorted())"
        )

        func encoding(_ className: String, _ selector: String, isClass: Bool) -> String? {
            let cls = classes.first { $0.name == className }
            let list = isClass ? cls?.classMethods : cls?.instanceMethods
            return list?.first { $0.selector == selector }?.typeEncoding
        }
        func array(_ name: String) -> ObjCClass? { classes.first { $0.name == name } }

        // Instance (-) methods, relative/small + selref + exact type encodings (otool ground truth).
        XCTAssertEqual(array("PLUMutableArray")?.instanceMethods.count, 11)
        XCTAssertEqual(encoding("PLUMutableArray", "count", isClass: false), "Q16@0:8")
        XCTAssertEqual(encoding("PLUMutableArray", "initWithCapacity:", isClass: false), "@24@0:8Q16")
        XCTAssertEqual(encoding("PLUContext", "execute", isClass: false), "B16@0:8")

        // Class (+) methods, recovered through the metaclass isa hop.
        XCTAssertTrue(array("PLUMutableArray")?.classMethods.isEmpty ?? false, "PLUMutableArray defines no + methods")
        XCTAssertEqual(encoding("PLUMutableDictionary", "dictionaryWithObjects:forKeys:count:", isClass: true), "@40@0:8r^@16r^@24Q32")
        XCTAssertEqual(encoding("PLUContext", "contextWithArguments:outputFileHandle:errorFileHandle:", isClass: true), "@40@0:8@16@24@32")

        // Ivars (name + type encoding) and properties (name + raw attribute string), otool ground truth.
        let context = array("PLUContext")
        XCTAssertEqual(context?.ivars.count, 11)
        XCTAssertEqual(context?.ivars.first { $0.name == "_append" }?.typeEncoding, "B")
        XCTAssertEqual(context?.ivars.first { $0.name == "_command" }?.typeEncoding, "Q")
        XCTAssertEqual(context?.ivars.first { $0.name == "_format" }?.typeEncoding, "@\"NSString\"")
        XCTAssertEqual(array("PLUMutableDictionary")?.ivars.first { $0.name == "_internalDict" }?.typeEncoding, "@\"NSMutableDictionary\"")
        XCTAssertEqual(context?.properties.count, 11)
        XCTAssertEqual(context?.properties.first { $0.name == "outputFileHandle" }?.attributes, "T@\"NSFileHandle\",&,V_outputFileHandle")
        XCTAssertEqual(context?.properties.first { $0.name == "command" }?.attributes, "TQ,V_command")
        XCTAssertEqual(context?.properties.first { $0.name == "append" }?.attributes, "TB,V_append")
    }
}
