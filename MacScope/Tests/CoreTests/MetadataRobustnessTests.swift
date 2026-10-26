import Foundation
import XCTest
@testable import MacScope

/// HS-7 / HS-8 / HS-11 (string-analysis pass M2–M4, M6, M10, O1): bounded and graded walks over
/// untrusted Swift / Objective-C metadata, a demangler budget, and metadata → code annotation.
/// Every fixture is a small hand-laid image with identity VA == file offset.
final class MetadataRobustnessTests: XCTestCase {

    // MARK: - HS-7 Swift: context-parent walk is capped (cycle + depth)

    func testSwiftContextParentWalkStopsOnCycleAndOnDepthCap() {
        // Cycle: field type → symbolic ref → struct A; A.parent = B; B.parent = A.
        do {
            var b = Builder()
            let fieldName = b.cstring("loop")
            let aName = b.cstring("A"), bName = b.cstring("B"), hostName = b.cstring("Host")
            b.align(4)
            let mangled = b.count
            b.byte(0x01); let symPayload = b.relSlot(); b.byte(0)
            b.align(4)
            let a = b.count
            b.u32(17); let aParent = b.relSlot(); let aNameSlot = b.relSlot(); b.u32(0); b.u32(0)
            let bDesc = b.count
            b.u32(17); let bParent = b.relSlot(); let bNameSlot = b.relSlot(); b.u32(0); b.u32(0)
            let (sections, patchHost) = b.hostStruct(nameOffset: hostName, fieldName: fieldName, mangled: mangled)
            b.patchRel(symPayload, a)
            b.patchRel(aParent, bDesc); b.patchRel(bParent, a)
            b.patchRel(aNameSlot, aName); b.patchRel(bNameSlot, bName)
            patchHost(&b)

            let report = SwiftMetadataParser(data: Data(b.data), sections: sections(b)).parseTypesReport()
            XCTAssertEqual(report.types.first?.fields.first?.name, "loop")
            XCTAssertNil(report.types.first?.fields.first?.typeName, "a parent cycle never yields a type name")
            XCTAssertTrue(report.diagnostics.contains { $0.grade == .walkCapped && $0.message.contains("cycle") })
        }
        // Depth: a chain of 70 distinct struct parents never reaches a module.
        do {
            var b = Builder()
            let fieldName = b.cstring("deep")
            let linkName = b.cstring("L"), hostName = b.cstring("Host")
            b.align(4)
            let mangled = b.count
            b.byte(0x01); let symPayload = b.relSlot(); b.byte(0)
            b.align(4)
            var links: [(desc: Int, parent: Int, name: Int)] = []
            for _ in 0..<70 {
                let desc = b.count
                b.u32(17); let parent = b.relSlot(); let name = b.relSlot(); b.u32(0); b.u32(0)
                links.append((desc, parent, name))
            }
            let (sections, patchHost) = b.hostStruct(nameOffset: hostName, fieldName: fieldName, mangled: mangled)
            b.patchRel(symPayload, links[0].desc)
            for (index, link) in links.enumerated() {
                b.patchRel(link.name, linkName)
                if index + 1 < links.count { b.patchRel(link.parent, links[index + 1].desc) }
            }
            patchHost(&b)

            let report = SwiftMetadataParser(data: Data(b.data), sections: sections(b)).parseTypesReport()
            XCTAssertNil(report.types.first?.fields.first?.typeName)
            XCTAssertTrue(report.diagnostics.contains { $0.grade == .walkCapped && $0.message.contains("too many parents") })
        }
    }

    // MARK: - HS-7 Swift: an unreadable field record skips that item only

    func testSwiftUnreadableFieldRecordIsSkippedAndTheRestKept() {
        var b = Builder()
        let good = b.cstring("good"), typeName = b.cstring("Bag"), int = b.cstring("Si")
        b.align(4)
        let fd = b.count
        b.u32(0); b.u32(0); b.u16(0); b.u16(12); b.u32(2)
        b.u32(0); _ = b.relSlot(); let badName = b.relSlot()          // record 0: name dangles
        b.u32(0); let goodType = b.relSlot(); let goodName = b.relSlot()
        b.align(4)
        let td = b.count
        b.u32(17); b.u32(0); let tdName = b.relSlot(); b.u32(0); let tdFields = b.relSlot(); b.u32(2); b.u32(0)
        let tyv = b.count
        let entry = b.relSlot()
        b.patchRel(badName, b.count + 0x10_000)
        b.patchRel(goodType, int); b.patchRel(goodName, good)
        b.patchRel(tdName, typeName); b.patchRel(tdFields, fd); b.patchRel(entry, td)

        let report = SwiftMetadataParser(data: Data(b.data), sections: b.sections(typesAt: tyv, count: 1)).parseTypesReport()
        XCTAssertEqual(report.types.map(\.name), ["Bag"])
        XCTAssertEqual(report.types.first?.fields, [SwiftField(name: "good", typeName: "Int", mangledTypeName: "Si")])
        XCTAssertEqual(report.diagnostics.map(\.grade), [.skippedItem])
    }

    // MARK: - HS-7 Swift: an unreadable type descriptor abandons the list

    func testSwiftUnreadableTypeDescriptorAbandonsTheTypeList() {
        var b = Builder()
        let first = b.cstring("First"), third = b.cstring("Third")
        b.align(4)
        let td1 = b.count
        b.u32(17); b.u32(0); let n1 = b.relSlot(); b.u32(0); b.u32(0)
        let td3 = b.count
        b.u32(18); b.u32(0); let n3 = b.relSlot(); b.u32(0); b.u32(0)
        let tyv = b.count
        let e1 = b.relSlot(), e2 = b.relSlot(), e3 = b.relSlot()
        b.patchRel(n1, first); b.patchRel(n3, third)
        b.patchRel(e1, td1); b.patchRel(e2, b.count + 0x10_000); b.patchRel(e3, td3)

        let report = SwiftMetadataParser(data: Data(b.data), sections: b.sections(typesAt: tyv, count: 3)).parseTypesReport()
        XCTAssertEqual(report.types.map(\.name), ["First"], "entries after an unreadable descriptor are abandoned")
        XCTAssertEqual(report.diagnostics.map(\.grade), [.abandonedList])
        XCTAssertTrue(report.diagnostics[0].message.contains("Cannot read Swift type descriptor"))
    }

    // MARK: - HS-7 Swift: an unknown descriptor kind is labelled and kept

    func testSwiftUnknownDescriptorKindIsLabelledAndKept() {
        var b = Builder()
        let odd = b.cstring("Odd")
        b.align(4)
        let td = b.count
        b.u32(19); b.u32(0); let name = b.relSlot(); b.u32(0); b.u32(0)
        let tyv = b.count
        let entry = b.relSlot()
        b.patchRel(name, odd); b.patchRel(entry, td)

        let report = SwiftMetadataParser(data: Data(b.data), sections: b.sections(typesAt: tyv, count: 1)).parseTypesReport()
        XCTAssertNotNil(report.types.first?.descriptorAddress, "RX-02a: the descriptor address is kept")
        XCTAssertEqual(report.types.map { var type = $0; type.descriptorAddress = nil; return type },
                       [SwiftTypeDescriptor(kind: .unknown, name: "Odd", rawKind: 19)])
        XCTAssertEqual(report.diagnostics.map(\.grade), [.labelledUnknownKind])
        XCTAssertEqual(SwiftInterfaceRenderer.render(types: report.types), "/* Swift type with kind 19 */ Odd {\n}")
    }

    // MARK: - HS-7 ObjC: method entry skips, protocol definition abandons

    func testObjCUnreadableMethodIsSkippedButUnreadableProtocolAbandonsList() {
        var bytes = [UInt8](repeating: 0, count: 0x500)
        func put(_ o: Int, _ v: UInt64) { bytes.replaceSubrange(o..<o + 8, with: (0..<8).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
        func putU32(_ o: Int, _ v: UInt32) { bytes.replaceSubrange(o..<o + 4, with: (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
        func putStr(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count + 1, with: Array((s + "\u{0}").utf8)) }
        put(0x00, 0x1040)                 // classlist[0] -> class_t
        put(0x60, 0x1080)                 // class_t.data -> ro
        put(0x98, 0x1100)                 // ro.name
        put(0xa0, 0x1180)                 // ro.baseMethods -> method_list
        put(0xa8, 0x1280)                 // ro.baseProtocols -> protocol_list
        putStr(0x100, "Graded")
        putU32(0x180, 24); putU32(0x184, 2)
        put(0x188, 0x9_0000)              // method[0].name -> unmapped (unreadable)
        put(0x1a0, 0x1200); put(0x1a8, 0x1210); put(0x1b0, 0x1400)   // method[1] ok
        putStr(0x200, "kept"); putStr(0x210, "v16@0:8")
        put(0x280, 3)                     // protocol_list count = 3
        put(0x288, 0x1300)                // [0] -> protocol_t "First"
        put(0x290, 0x1340)                // [1] -> protocol_t whose name is unreadable
        put(0x298, 0x1300)                // [2] would be "First" again, but the list is abandoned
        put(0x308, 0x1380); putStr(0x380, "First")
        put(0x348, 0x9_0000)
        let sections = [
            ObjCClassParser.Section(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            ObjCClassParser.Section(address: 0x1008, fileOffset: 8, size: 0x4f8, name: "__objc_const"),
        ]
        var parser = ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: [:], bindNames: [:])
        let log = MetadataParseDiagnosticLog()
        parser.diagnosticLog = log
        let cls = parser.parseClasses().first

        XCTAssertEqual(cls?.instanceMethods.map(\.selector), ["kept"], "an unreadable method skips only itself")
        XCTAssertEqual(cls?.adoptedProtocols, ["First"], "an unreadable protocol abandons the rest of the list")
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.first { $0.grade == .skippedItem }?.address, 0x1188)
        XCTAssertTrue(log.entries.first { $0.grade == .skippedItem }?.message
            .hasPrefix("Cannot read method definition at 0x1188") == true)
        XCTAssertTrue(log.entries.first { $0.grade == .abandonedList }?.message
            .hasPrefix("Cannot read protocol definition at 0x1340 - abort") == true)
    }

    // MARK: - HS-8 demangler budget

    func testSwiftDemanglerBudgetReturnsTooComplexMarker() {
        func nested(_ depth: Int) -> String {
            "$s" + String(repeating: "Say", count: depth) + "Si" + String(repeating: "G", count: depth) + "N"
        }
        XCTAssertEqual(SwiftDemangler.demangle(nested(2)), "type metadata for [[Swift.Int]]")
        XCTAssertNotNil(SwiftDemangler.demangle(nested(SwiftDemangler.maxTypeDepth)), "the cap itself still demangles")
        // Past the type-depth cap: a marked result, promptly (this used to backtrack exponentially).
        let started = Date()
        XCTAssertEqual(SwiftDemangler.demangle(nested(300)), SwiftDemangler.tooComplexMarker)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // Nested suffix wrappers re-parse the prefix once per wrapper: capped, not recursed 3000 deep.
        XCTAssertEqual(SwiftDemangler.demangle("$s4main3FooVMa" + String(repeating: "Tm", count: 3_000)),
                       SwiftDemangler.tooComplexMarker)
        XCTAssertEqual(SwiftDemangler.demangle("$s4main3FooVMaTmTm"), "merged merged type metadata accessor for main.Foo")
        // Over the input cap: marked for a Swift symbol, plain nil for anything else.
        XCTAssertEqual(SwiftDemangler.demangle("$s" + String(repeating: "a", count: 9_000)), SwiftDemangler.tooComplexMarker)
        XCTAssertEqual(Demangler.displayName(for: "_$s" + String(repeating: "a", count: 9_000)), SwiftDemangler.tooComplexMarker)
        // Type-name decoding (metadata recovery) stays nil rather than adopting the marker.
        XCTAssertNil(SwiftDemangler.demangleType(String(repeating: "Say", count: 300) + "Si" + String(repeating: "G", count: 300)))
    }

    /// O1 coverage checklist: the trivially-missing Swift 5.8+/6.x entity wrappers, with output
    /// checked against `xcrun swift-demangle`.
    func testSwiftDemanglerBackDeploymentAndCoroutineWrappers() {
        XCTAssertEqual(SwiftDemangler.demangle("$s4main3fooyyFTwb"), "back deployment thunk for main.foo() -> ()")
        XCTAssertEqual(SwiftDemangler.demangle("$s4main3fooyyFTwB"), "back deployment fallback for main.foo() -> ()")
        XCTAssertEqual(SwiftDemangler.demangle("$s4main3fooyyFTwc"), "coro function pointer to main.foo() -> ()")
    }

    /// HS-13: `#_hasSymbol` query (`TwS`) and default override (`Twd`). Manglings are real `nm`
    /// output from a Swift 6.4 sample (`@_weakLinked import` + `#_hasSymbol`; an open class with
    /// `read`/`modify` coroutine accessors under `-enable-experimental-feature CoroutineAccessors`);
    /// expected text is `xcrun swift-demangle` output.
    func testSwiftDemanglerHasSymbolQueryAndDefaultOverride() {
        XCTAssertEqual(SwiftDemangler.demangle("$s3Lib4WeakVTwS"), "#_hasSymbol query for Lib.Weak")
        XCTAssertEqual(SwiftDemangler.demangle("$s3Lib6weakFnyyFTwS"), "#_hasSymbol query for Lib.weakFn() -> ()")
        XCTAssertEqual(SwiftDemangler.demangle("$s4User4BaseC1vSivr"), "User.Base.v.read : Swift.Int")
        XCTAssertEqual(SwiftDemangler.demangle("$s4User4BaseC1vSivx"), "User.Base.v.yielding_mutate : Swift.Int")
        XCTAssertEqual(SwiftDemangler.demangle("$s4User4BaseC1vSivxTwd"),
                       "default override of User.Base.v.yielding_mutate : Swift.Int")
        XCTAssertEqual(SwiftDemangler.demangle("$s4User4BaseC1vSivyTwd"),
                       "default override of User.Base.v.yielding_borrow : Swift.Int")
        XCTAssertEqual(SwiftDemangler.demangle("$s4User4BaseC1vSivxTwdTwc"),
                       "coro function pointer to default override of User.Base.v.yielding_mutate : Swift.Int")
    }

    /// HS-13: macro expansions. The `#Preview` unique name and the symbols nested in it are real
    /// `nm` output from a Swift 6.4 sample using `#Preview` and `@Observable`; the attached-role
    /// forms are hand-built manglings, each accepted by `xcrun swift-demangle`, whose output is the
    /// expected text throughout.
    func testSwiftDemanglerMacroExpansions() {
        let unique = "$s3Mac0014macswift_IwJBbfMX3_0_33_C955C6E98A0A9B9B54BACF9A08424418Ll7PreviewfMf_15PreviewRegistryfMu_"
        XCTAssertEqual(SwiftDemangler.demangle(unique),
                       "unique name #1 of PreviewRegistry in freestanding macro expansion #1 of Preview"
                       + "(in _C955C6E98A0A9B9B54BACF9A08424418) in module Mac file mac.swift line 4 column 1")
        XCTAssertEqual(SwiftDemangler.demangle("$s3Mac4filefMX3_0_7PreviewfMf_"),
                       "freestanding macro expansion #1 of Preview in module Mac file file line 4 column 1")
        XCTAssertEqual(SwiftDemangler.demangle("$s4main7MyMacrofMf_3tmpfMu0_"),
                       "unique name #2 of tmp in freestanding macro expansion #1 of MyMacro in main")
        let attached: [(String, String)] = [
            ("$s4main3FooV1x7MyMacrofMa_", "accessor macro @MyMacro expansion #1 of x in main.Foo"),
            ("$s4main3FooV1x7MyMacrofMr0_", "memberAttribute macro @MyMacro expansion #2 of x in main.Foo"),
            ("$s4main3FooV3bar7MyMacrofMm_", "member macro @MyMacro expansion #1 of bar in main.Foo"),
            ("$s4main3FooV1x7MyMacrofMp_", "peer macro @MyMacro expansion #1 of x in main.Foo"),
            ("$s4main3Foo7MyMacrofMc_", "conformance macro @MyMacro expansion #1 of Foo in main"),
            ("$s4main3Foo7MyMacrofMe_", "extension macro @MyMacro expansion #1 of Foo in main"),
            ("$s4main3foo7MyMacrofMq_", "preamble macro @MyMacro expansion #1 of foo in main"),
            ("$s4main3foo7MyMacrofMb_", "body macro @MyMacro expansion #1 of foo in main"),
            ("$s3Mac4filefMX3_0_1x7PreviewfMa_",
             "accessor macro @Preview expansion #1 of x in module Mac file file line 4 column 1"),
            ("$s4main3FooV1x7MyMacrofMp_3tmpfMu_",
             "unique name #1 of tmp in peer macro @MyMacro expansion #1 of x in main.Foo")
        ]
        for (symbol, expected) in attached {
            XCTAssertEqual(SwiftDemangler.demangle(symbol), expected, symbol)
        }
        // Entities declared inside an expansion use the unique name as a `$s…` identifier, which
        // swift-demangle prints verbatim.
        let registry = "$s3Mac101" + unique + "V"
        let inner = unique
        XCTAssertEqual(SwiftDemangler.demangle(registry + "Mn"), "nominal type descriptor for Mac." + inner)
        XCTAssertEqual(SwiftDemangler.demangle(registry + "N"), "type metadata for Mac." + inner)
        XCTAssertEqual(SwiftDemangler.demangle(registry + "4lineSivgZ"), "static Mac." + inner + ".line.getter : Swift.Int")
        XCTAssertEqual(SwiftDemangler.demangle(registry + "04makeS021DeveloperToolsSupport0S0VyKFZ"),
                       "static Mac." + inner + ".makePreview() throws -> DeveloperToolsSupport.Preview")
        // Malformed: wrong arity for the role, missing discriminator terminator, unknown role.
        XCTAssertNil(SwiftDemangler.demangle("$s4main7MyMacrofMa_"))
        XCTAssertNil(SwiftDemangler.demangle("$s4main7MyMacrofMf0"))
        XCTAssertNil(SwiftDemangler.demangle("$s4main7MyMacrofMz_"))
    }

    // MARK: - HS-11 metadata → code comments

    func testObjCImplementationCommentsNameUnsymbolledIMPsOnly() {
        let classes = [ObjCClass(
            name: "Widget", superclassName: "NSObject", adoptedProtocols: [],
            classMethods: [ObjCMethod(selector: "shared", typeEncoding: nil, isClassMethod: true, implementation: 0x2000)],
            instanceMethods: [
                ObjCMethod(selector: "draw", typeEncoding: nil, isClassMethod: false, implementation: 0x1000),
                ObjCMethod(selector: "named", typeEncoding: nil, isClassMethod: false, implementation: 0x3000),
                ObjCMethod(selector: "external", typeEncoding: nil, isClassMethod: false, implementation: nil),
            ],
            ivars: [], properties: [])]
        let categories = [ObjCCategory(
            name: "Extras", className: "NSString", classMethods: [],
            instanceMethods: [ObjCMethod(selector: "shout", typeEncoding: nil, isClassMethod: false, implementation: 0x4000)],
            adoptedProtocols: [], properties: [])]

        let comments = AnalysisEngine.objcImplementationComments(
            classes: classes, categories: categories, namedAddresses: [0x3000])
        XCTAssertEqual(comments, [
            0x1000: "Objective C implementation of -[Widget draw]",
            0x2000: "Objective C implementation of +[Widget shared]",
            0x4000: "Objective C implementation of -[NSString(Extras) shout]",
        ])
    }
}

// MARK: - Fixture builder

private struct Builder {
    var data: [UInt8] = []
    var count: Int { data.count }
    mutating func align(_ n: Int) { while data.count % n != 0 { data.append(0) } }
    mutating func byte(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xff)); data.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * i)) & 0xff)) } }
    mutating func cstring(_ s: String) -> Int { let off = data.count; data.append(contentsOf: Array(s.utf8)); data.append(0); return off }
    mutating func relSlot() -> Int { let off = data.count; u32(0); return off }
    mutating func patchRel(_ slot: Int, _ target: Int) {
        let bits = UInt32(bitPattern: Int32(target - slot))
        for i in 0..<4 { data[slot + i] = UInt8((bits >> (8 * i)) & 0xff) }
    }

    func sections(typesAt typesVA: Int, count: Int) -> [SwiftMetadataParser.Section] {
        [
            SwiftMetadataParser.Section(name: "__swift5_types", address: UInt64(typesVA), fileOffset: UInt64(typesVA),
                                        size: UInt64(count * 4)),
            SwiftMetadataParser.Section(name: "__const", address: 0, fileOffset: 0, size: UInt64(self.count)),
        ]
    }

    /// Appends a one-field host struct whose field's mangled type is at `mangled`, plus its
    /// `__swift5_types` entry. Returns a section factory and a patcher to run after the caller's
    /// own patches (the patcher only writes the host's own slots).
    mutating func hostStruct(nameOffset: Int, fieldName: Int, mangled: Int)
        -> (sections: (Builder) -> [SwiftMetadataParser.Section], patch: (inout Builder) -> Void) {
        align(4)
        let fd = count
        u32(0); u32(0); u16(0); u16(12); u32(1)
        u32(0); let recordType = relSlot(); let recordName = relSlot()
        align(4)
        let td = count
        u32(17); u32(0); let tdName = relSlot(); u32(0); let tdFields = relSlot(); u32(1); u32(0)
        let tyv = count
        let entry = relSlot()
        return ({ $0.sections(typesAt: tyv, count: 1) }, { b in
            b.patchRel(recordType, mangled); b.patchRel(recordName, fieldName)
            b.patchRel(tdName, nameOffset); b.patchRel(tdFields, fd); b.patchRel(entry, td)
        })
    }
}
