import XCTest
@testable import MacScope

/// Tests for the clean-room C++/Swift symbol demangler. Every expected value
/// here was cross-checked locally against `c++filt` (Itanium) and
/// `swift-demangle` (Swift); the demangler must reproduce them exactly.
final class DemanglerTests: XCTestCase {

    /// Compiled Swift 6.4 sample symbols, including local metadata and undefined references.
    /// Expectations are the oracle's display representation, captured alongside its expanded tree.
    func testSwiftCompiledLanguageConformance() throws {
        struct Fixture: Decodable {
            struct Symbol: Decodable { let mangled: String; let expected: String }
            let schemaVersion: Int
            let sampleKinds: [String]
            let symbols: [Symbol]
        }
        let url = TestSourceRoot.url.appendingPathComponent("Scripts/demangler-conformance/Symbols.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.symbols.count, 433)
        XCTAssertEqual(Set(fixture.symbols.map(\.mangled)).count, fixture.symbols.count)
        XCTAssertEqual(fixture.sampleKinds.count, 17)
        for symbol in fixture.symbols {
            XCTAssertEqual(SwiftDemangler.demangle(symbol.mangled), symbol.expected, symbol.mangled)
        }
    }

    func testSwiftIdentifierExpansionBudgetAndMalformedReferences() {
        let word = String(repeating: "ab", count: 1024)
        let oversized = "$s2048" + word + "0" + String(repeating: "a", count: 9) + "A0V"
        XCTAssertEqual(SwiftDemangler.demangle(oversized), SwiftDemangler.tooComplexMarker)
        for symbol in ["$s11Distributed0Z5ActorMp", "$s4Test0a", "$s4Test0A", "$s4Test0A0Vjunk"] {
            XCTAssertNil(SwiftDemangler.demangle(symbol), symbol)
        }
    }

    /// Xcode 27.2 / Swift 6.4 emitted these metadata symbols from a bounded two-module
    /// sample: PackLib declares `P`, `Item`, `Pack<each T: P>`; PackUser retroactively
    /// conforms Item to P and returns `Pack<Item>.self` / `Pack<Item, Item>.self`.
    /// Expected strings and the HX/HC tree were captured with swift-demangle --expand.
    func testSwiftPackProtocolConformanceMetadata() {
        let one = "$s7PackLib0A0VyAA4ItemV_QPAeA1P0A4UseryHC_HXg_G"
        let two = "$s7PackLib0A0VyAA4ItemV_AEQPAeA1P0A4UseryHC_AeafGyHCHXg_G"
        XCTAssertEqual(SwiftDemangler.demangle(one + "Md"),
                       "demangling cache variable for type metadata for PackLib.Pack<Pack{PackLib.Item}>")
        XCTAssertEqual(SwiftDemangler.demangle(two + "MR"),
                       "mangled name ref for type metadata for PackLib.Pack<Pack{PackLib.Item, PackLib.Item}>")
        XCTAssertEqual(SwiftDemangler.demangle(two + "Md"),
                       "demangling cache variable for type metadata for PackLib.Pack<Pack{PackLib.Item, PackLib.Item}>")
        XCTAssertEqual(SwiftDemangler.demangleType(String(two.dropFirst(2))),
                       "PackLib.Pack<Pack{PackLib.Item, PackLib.Item}>")
    }

    /// Minimal grammar boundary vectors, independently decoded by swift-demangle --expand.
    /// These are synthetic grammar vectors, not claimed as compiler-emitted symbols.
    func testSwiftPackProtocolConformanceLists() {
        XCTAssertEqual(SwiftDemangler.demangle("$syHX"), "pack protocol conformance ")
        XCTAssertEqual(SwiftDemangler.demangle("$syHX_yHXHX"),
                       "pack protocol conformance (pack protocol conformance , pack protocol conformance )")
        XCTAssertEqual(SwiftDemangler.demangle("$s7PackLib4ItemVAA1P8PackUseryHC_HX"),
                       "pack protocol conformance (concrete protocol conformance PackLib.Item to "
                       + "protocol conformance ref (retroactive) PackLib.PPackUser)")
    }

    func testSwiftPackProtocolConformanceRejectsMalformedOperands() {
        for symbol in ["$sHX", "$s7PackLib4ItemV_HX", "$syHXHX", "$syHXg",
                       "$syHXjunk", "$s7PackLib4ItemVAA1P8PackUserHC_HX",
                       "$s7PackLib0A0VyAA4ItemV_QPAeA1P0A4UseryHC_HXg_GMdjunk"] {
            XCTAssertNil(SwiftDemangler.demangle(symbol), symbol)
        }
    }

    func testSwiftPackProtocolConformanceTypeBoundaryAndIdentifierWords() {
        XCTAssertNil(SwiftDemangler.demangleType("yHX"))
        XCTAssertNil(SwiftDemangler.demangleType("yHXg_"))
        // Synthetic word-substitution boundary, checked against swift-demangle: digits stay
        // inside an identifier word, so C names Item2 (not Item).
        XCTAssertEqual(SwiftDemangler.demangle("$s7PackLib10Item2ThingVAA1P0C4UseryHC_HX"),
                       "pack protocol conformance (concrete protocol conformance PackLib.Item2Thing to "
                       + "protocol conformance ref (retroactive) PackLib.PItem2User)")
    }

    func testSwiftPackProtocolConformanceDepthBudget() {
        let deeplyNested = "yHX" + String(repeating: "_HX", count: SwiftDemangler.maxTypeDepth + 1)
        XCTAssertEqual(SwiftDemangler.demangle("$s" + deeplyNested), SwiftDemangler.tooComplexMarker)
        XCTAssertNil(SwiftDemangler.demangleType(deeplyNested))
    }

    /// Hostile numeric fields are grammar boundary vectors, not compiler-emitted samples.
    func testSwiftPackNaturalCountOverflowBoundaries() {
        for value in [Int.max - 27, Int.max - 26, Int.max] {
            XCTAssertNil(SwiftDemangler.demangle("$syHXA\(value)_"))
            XCTAssertNil(SwiftDemangler.demangle("$syHXA\(value)A"))
            XCTAssertNil(SwiftDemangler.demangle("$syHX\(value)X"))
            if value < Int.max {
                XCTAssertEqual(SwiftDemangler.demangle("$syHXg\(value)_"),
                               "retroactive conformance @\(value + 1) pack protocol conformance ")
            } else {
                XCTAssertNil(SwiftDemangler.demangle("$syHXg\(value)_"))
            }
        }
        XCTAssertNil(SwiftDemangler.demangle("$syHXA9223372036854775807_"))
    }

    func testSwiftNumericIdentifierOverflowBoundaries() {
        for value in [Int.max - 1, Int.max] {
            for prefix in ["$s", "$s0", "$s4Test0A"] {
                XCTAssertNil(SwiftDemangler.demangle(prefix + "\(value)X"))
            }
        }
    }

    func testSwiftGenericNaturalOverflowBoundaries() {
        for value in [Int.max - 1, Int.max] {
            for type in ["q\(value)_", "qd\(value)__", "qd_\(value)_",
                         "7ElementQy\(value)_", "7ElementQyd\(value)__"] {
                XCTAssertNil(SwiftDemangler.demangleType(type), type)
            }
            XCTAssertNil(SwiftDemangler.demangle("$s4Test1fyyxr\(value)_lF"))
            XCTAssertNil(SwiftDemangler.demangle("$s4Test1fyyxSQR\(value)_lF"))
            XCTAssertNil(SwiftDemangler.demangle("$s4Test1fyyxSQRd\(value)__lF"))
        }
    }

    func testSwiftSubstitutionAggregateAllocationBound() {
        let run = "A" + String(repeating: "1024a", count: 8) + "B"
        var parser = SwiftDemangler.Parser(budget: SwiftDemangler.Budget(), Array(run.unicodeScalars))
        XCTAssertNil(parser.parseSubstitutionType())
    }

    func testSwiftWrapperNaturalOverflowBoundaries() {
        for suffix in ["TQ", "TY", "Tv", "fA", "fU", "fu"] {
            XCTAssertNil(SwiftDemangler.demangle("$s4Test1fyyF" + suffix + "\(Int.max)_"), suffix)
        }
        for suffix in ["fU", "fu"] {
            XCTAssertNil(SwiftDemangler.demangle("$s4Test1fyyF" + suffix + "\(Int.max - 1)_"), suffix)
        }
    }

    private struct FollowupFixture: Decodable {
        struct Symbol: Decodable { let mangled: String; let expected: String; let kind: String }
        struct Section: Decodable {
            let name: String
            let address: UInt64
            let fileOffset: UInt64
            let size: UInt64
            let bytes: Data
        }
        let schemaVersion: Int
        let symbols: [Symbol]
        let sections: [Section]
    }

    private func followupFixture() throws -> FollowupFixture {
        let url = TestSourceRoot.url.appendingPathComponent("Scripts/demangler-conformance/Followup.json")
        let fixture = try JSONDecoder().decode(FollowupFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schemaVersion, 1)
        return fixture
    }

    func testSwiftCompiledFollowupSubstitutions() throws {
        let rows = try followupFixture().symbols.filter { $0.kind == "stable-substitution" }
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.contains { $0.mangled.contains("A6_A0_") })
        for row in rows {
            XCTAssertEqual(Demangler.mangledToReadable(row.mangled), row.expected, row.mangled)
        }
    }

    func testSwiftCompiledLegacyRuntimeClassNames() throws {
        let rows = try followupFixture().symbols.filter { $0.kind == "legacy-runtime-class" }
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(Demangler.mangledToReadable(row.mangled), row.expected, row.mangled)
        }
    }

    func testSwiftLegacyRuntimeNamesRejectUnsupportedAndMalformedGrammar() {
        // Legacy runtime names accept decimal leading zeroes and an unmangled suffix.
        XCTAssertEqual(Demangler.mangledToReadable("_TtC4Test3FooJunk"),
                       "Test.Foo with unmangled suffix \"Junk\"")
        XCTAssertEqual(Demangler.mangledToReadable("_TtC04Test3Foo"), "Test.Foo")
        XCTAssertEqual(Demangler.mangledToReadable("_TtC4Test03Foo"), "Test.Foo")
        for value in ["_TtC", "_TtC4Test", "_TtCC4Test3Foo",
                      "_TtC9223372036854775807X", "_TF4Test3foofT_T_", "_TtV4Test3Foo"] {
            XCTAssertNil(Demangler.mangledToReadable(value), value)
        }
    }

    func testSwiftExtendedSubstitutionRejectsOutOfRangeIndices() throws {
        let row = try XCTUnwrap(followupFixture().symbols.first { $0.mangled.contains("A6_A0_") })
        for value in [Int.max - 27, Int.max - 26, Int.max] {
            let hostile = row.mangled.replacingOccurrences(of: "A6_", with: "A\(value)_")
            XCTAssertNil(SwiftDemangler.demangle(hostile), hostile)
        }
    }

    private func followupMetadata(invalidateReferences: Bool) throws -> [SwiftTypeDescriptor] {
        let fixture = try followupFixture()
        let count = try XCTUnwrap(fixture.sections.map { $0.fileOffset + $0.size }.max())
        XCTAssertLessThan(count, 1024 * 1024)
        var data = Data(repeating: 0, count: Int(count))
        for section in fixture.sections {
            XCTAssertEqual(UInt64(section.bytes.count), section.size)
            data.replaceSubrange(Int(section.fileOffset)..<Int(section.fileOffset + section.size), with: section.bytes)
            if invalidateReferences, section.name == "__swift5_typeref" {
                var offset = Int(section.fileOffset)
                let end = offset + Int(section.size)
                while offset < end {
                    if data[offset] == 1, offset + 4 < end {
                        // Mutate only the relative displacement in a copy of compiler-emitted bytes.
                        data.replaceSubrange((offset + 1)..<(offset + 5), with: [0xff, 0xff, 0xff, 0x7f])
                        offset += 5
                    } else { offset += 1 }
                }
            }
        }
        let sections = fixture.sections.map {
            SwiftMetadataParser.Section(name: $0.name, address: $0.address, fileOffset: $0.fileOffset, size: $0.size)
        }
        return SwiftMetadataParser(data: data, sections: sections).parseTypes()
    }

    func testSwiftCompiledBinaryRelativeSymbolicReferences() throws {
        let types = try followupMetadata(invalidateReferences: false)
        let container = try XCTUnwrap(types.first { $0.name == "Container" })
        XCTAssertEqual(container.fields.map(\.name), ["one", "many", "optional"])
        XCTAssertEqual(container.fields.map(\.typeName), ["Leaf", "[Leaf]", "Leaf?"])
        XCTAssertTrue(container.fields.allSatisfy { $0.mangledTypeName?.contains("…") == true })
        let concrete = try XCTUnwrap(types.first { $0.name == "Concrete" })
        XCTAssertEqual(concrete.fields.first?.typeName, "Box<Leaf>")
    }

    func testSwiftCompiledSymbolicReferencesOutsideImageStayUnknown() throws {
        let types = try followupMetadata(invalidateReferences: true)
        let container = try XCTUnwrap(types.first { $0.name == "Container" })
        XCTAssertEqual(container.fields.count, 3)
        XCTAssertTrue(container.fields.allSatisfy { $0.typeName == nil })
        XCTAssertTrue(container.fields.allSatisfy { $0.mangledTypeName?.contains("…") == true })
    }

    // MARK: - Itanium C++

    func testItaniumFreeFunctions() {
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooi"), "foo(int)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3foov"), "foo()")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3addii"), "add(int, int)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z4funcPKc"), "func(char const*)")
    }

    func testItaniumBuiltinScalarTypes() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barEbcsil"),
                       "foo::bar(bool, char, short, int, long)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barExyfd"),
                       "foo::bar(long long, unsigned long long, float, double)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooj"), "foo(unsigned int)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3foom"), "foo(unsigned long)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooh"), "foo(unsigned char)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooa"), "foo(signed char)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3foot"), "foo(unsigned short)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3foow"), "foo(wchar_t)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3foob"), "foo(bool)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooc"), "foo(char)")
    }

    func testItaniumNestedNames() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barEv"), "foo::bar()")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barEi"), "foo::bar(int)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZNK3foo3barEv"), "foo::bar() const")
    }

    func testItaniumCtorDtor() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN1A1BC1Ev"), "A::B::B()")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN1A1BD1Ev"), "A::B::~B()")
    }

    func testItaniumPointersAndReferences() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barEPKcRi"),
                       "foo::bar(char const*, int&)")
    }

    func testItaniumSubstitutions() {
        // S_ refers to the first substitution component (`foo`).
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barENS_3bazE"),
                       "foo::bar(foo::baz)")
        // S0_ / S1_ back-references walk the substitution table in order.
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barENS_3bazENS0_3quxE"),
                       "foo::bar(foo::baz, foo::baz::qux)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barENS_3bazENS_3quxE"),
                       "foo::bar(foo::baz, foo::qux)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN1N1A1fEPNS_1BE"),
                       "N::A::f(N::B*)")
    }

    func testItaniumStdSubstitutions() {
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooSs"), "foo(std::string)")
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooRKSs"),
                       "foo(std::string const&)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZNSt6vectorIiSaIiEE9push_backEOi"),
                       "std::vector<int, std::allocator<int>>::push_back(int&&)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backEOi"),
                       "std::__1::vector<int, std::__1::allocator<int>>::push_back(int&&)")
    }

    func testItaniumTemplateLiteralArgs() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3fooILi3EE3barEv"),
                       "foo<3>::bar()")
    }

    func testItaniumMachOLeadingUnderscore() {
        // Mach-O global symbols carry an extra leading underscore.
        XCTAssertEqual(Demangler.mangledToReadable("__Z3fooi"), "foo(int)")
    }

    func testItaniumRejectsUncoveredForms() {
        // Local-scope entity (Z…E) — not modelled.
        XCTAssertNil(Demangler.mangledToReadable("_ZZ4mainE3fooi"))
        // Template type-parameter reference — not modelled.
        XCTAssertNil(Demangler.mangledToReadable("_Z1fIiEvT_"))
        // Truncated / garbage.
        XCTAssertNil(Demangler.mangledToReadable("_Z3foo"))
        XCTAssertNil(Demangler.mangledToReadable("_Z"))
    }

    // MARK: - Swift

    func testSwiftNominalTypes() {
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooC"), "main.Foo")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooV"), "main.Foo")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooO"), "main.Foo")
    }

    func testSwiftStdlibKnownTypes() {
        XCTAssertEqual(Demangler.mangledToReadable("$sSi"), "Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$sSS"), "Swift.String")
        XCTAssertEqual(Demangler.mangledToReadable("$sSb"), "Swift.Bool")
        XCTAssertEqual(Demangler.mangledToReadable("$sSd"), "Swift.Double")
        XCTAssertEqual(Demangler.mangledToReadable("$sSf"), "Swift.Float")
        XCTAssertEqual(Demangler.mangledToReadable("$sSu"), "Swift.UInt")
    }

    func testSwiftFunctions() {
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooC3baryyF"),
                       "main.Foo.bar() -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3baryyF"),
                       "main.bar() -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3fooSiyF"),
                       "main.foo() -> Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3fooyySiF"),
                       "main.foo(Swift.Int) -> ()")
    }

    func testSwiftMetadataAccessor() {
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooCMa"),
                       "type metadata accessor for main.Foo")
    }

    /// `N` is the type-metadata symbol; the nominal type descriptor is `Mn`. These were
    /// conflated (every `…N` demangled to the wrong "nominal type descriptor"). Ground
    /// truth: `swift-demangle`.
    func testSwiftTypeMetadataAndNominalDescriptor() {
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooCN"), "type metadata for main.Foo")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooVN"), "type metadata for main.Foo")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooCMn"),
                       "nominal type descriptor for main.Foo")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAACN"),
                       "type metadata for DataViewer.DataViewer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAACMn"),
                       "nominal type descriptor for DataViewer.DataViewer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAACMm"),
                       "metaclass for DataViewer.DataViewer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAACMu"),
                       "method lookup function for DataViewer.DataViewer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAACMo"),
                       "class metadata base offset for DataViewer.DataViewer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer11TransformerCMU"),
                       "ObjC metadata update function for DataViewer.Transformer")
    }

    /// Property accessors `<type>v<g|s|M>` — the single highest-frequency app symbol family
    /// (every stored property emits several). Ground truth: `swift-demangle`.
    func testSwiftPropertyAccessors() {
        XCTAssertEqual(Demangler.mangledToReadable("$s3app5ModelV4nameSSvg"),
                       "app.Model.name.getter : Swift.String")
        XCTAssertEqual(Demangler.mangledToReadable("$s3app5ModelV4nameSSvs"),
                       "app.Model.name.setter : Swift.String")
        XCTAssertEqual(Demangler.mangledToReadable("$s3app5ModelV4nameSSvM"),
                       "app.Model.name.modify : Swift.String")
        XCTAssertEqual(Demangler.mangledToReadable("$s3app5ModelV5countSivg"),
                       "app.Model.count.getter : Swift.Int")
        // A property accessor on a class (C) reads the same way.
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooC3barSivs"),
                       "main.Foo.bar.setter : Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib8CLIErrorO16errorDescriptionSSSgvg"),
                       "ACPToolLib.CLIError.errorDescription.getter : Swift.String?")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAAC3url10Foundation3URLVvg"),
                       "DataViewer.DataViewer.url.getter : Foundation.URL")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewerAAC7handlerAA7HandlerCvg"),
                       "DataViewer.DataViewer.handler.getter : DataViewer.Handler")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV011multiDeviceI10IdentifierSSSgvg"),
                       "DataViewer.Components.Schemas.ActivityTreeItem.multiDeviceDeviceIdentifier.getter : Swift.String?")
    }

    func testSwiftConformanceDescriptorWrappers() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV14ArgumentParser15ParsableCommandAAMc"),
            "protocol conformance descriptor for ACPToolLib.RemoveToken : ArgumentParser.ParsableCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser11HelpCommandVAA08ParsableD0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ArgumentParser.HelpCommand : ArgumentParser.ParsableCommand in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxG14ArgumentParser17ParsableArgumentsAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxGSeAAMc"),
            "protocol conformance descriptor for ACPToolLib.AuthOptions<A> : Swift.Decodable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxG14ArgumentParser17ParsableArgumentsAAWp"),
            "protocol witness table pattern for ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOs0D0AAMc"),
            "protocol conformance descriptor for ACPToolLib.APIRequestError : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOs0D0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ACPToolLib.APIRequestError : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s13XCResultTypes06ResultB5ErrorOs0D0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultTypes.ResultTypesError : Swift.Error in XCResultTypes"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s15XCResultStorage012ResultBundleB0VSEAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultStorage.ResultBundleStorage : Swift.Encodable in XCResultStorage"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO5ErrorOsAdAMc"),
            "protocol conformance descriptor for ACPToolLib.TokenManagement.Error : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO5ErrorOsAdAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ACPToolLib.TokenManagement.Error : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib16APIResponseErrorV10Foundation09LocalizedD0AAMc"),
            "protocol conformance descriptor for ACPToolLib.APIResponseError : Foundation.LocalizedError in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib8AuthTypeO14ArgumentParser013ExpressibleByE0AAMc"),
            "protocol conformance descriptor for ACPToolLib.AuthType : ArgumentParser.ExpressibleByArgument in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO21AcceptableContentTypeO31XCResultKit_OpenAPIRuntime_XCRK0G8ProtocolAAMc"),
            "protocol conformance descriptor for DataViewer.Operations.GetTestRuns.AcceptableContentType : XCResultKit_OpenAPIRuntime_XCRK.AcceptableProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO21AcceptableContentTypeO31XCResultKit_OpenAPIRuntime_XCRK0G8ProtocolAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.Operations.GetTestRuns.AcceptableContentType : XCResultKit_OpenAPIRuntime_XCRK.AcceptableProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerCScAAAMc"),
            "protocol conformance descriptor for DataViewer.Transformer : Swift.Actor in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerCScAAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.Transformer : Swift.Actor in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13AttributeListV08XCResultA5Views13DatabaseValueAAMc"),
            "protocol conformance descriptor for DataViewer.AttributeList : XCResultDataViews.DatabaseValue in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13AttributeListV08XCResultA5Views13DatabaseValueAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.AttributeList : XCResultDataViews.DatabaseValue in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13RecordWrapperV08XCResultA5Views20DatabaseSerializableAAMc"),
            "protocol conformance descriptor for DataViewer.RecordWrapper : XCResultDataViews.DatabaseSerializable in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13RecordWrapperV08XCResultA5Views20DatabaseSerializableAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.RecordWrapper : XCResultDataViews.DatabaseSerializable in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamC0cdeF5ErrorOSHAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.FileBackedReadStream.FileBackedReadStreamError : Swift.Hashable in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI10ActivitiesV0A18Kit_ArgumentParser15ParsableCommandAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultCLI.Activities : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer32ISO8601MicrosecondDateTranscoderV31XCResultKit_OpenAPIRuntime_XCRK0eF0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.ISO8601MicrosecondDateTranscoder : XCResultKit_OpenAPIRuntime_XCRK.DateTranscoder in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer7HandlerC18HTTPTransportUtils011HTTPServiceC0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for DataViewer.Handler : HTTPTransportUtils.HTTPServiceHandler in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13ExportMetricsV10CodingKeys031_02D582F67D1E1D5718BD1D8F4247F5I0LLOSHAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultCLI.ExportMetrics.(CodingKeys in _02D582F67D1E1D5718BD1D8F4247F5D1) : Swift.Hashable in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13ExportMetricsV16TestManifestInfo031_02D582F67D1E1D5718BD1D8F4247F5J0LLV10CodingKeysOSHAAMc"),
            "protocol conformance descriptor for XCResultCLI.ExportMetrics.(TestManifestInfo in _02D582F67D1E1D5718BD1D8F4247F5D1).CodingKeys : Swift.Hashable in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13ExportMetricsV16TestManifestInfo031_02D582F67D1E1D5718BD1D8F4247F5J0LLV10CodingKeysOSHAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultCLI.ExportMetrics.(TestManifestInfo in _02D582F67D1E1D5718BD1D8F4247F5D1).CodingKeys : Swift.Hashable in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0B5ErrorOs0C0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ArgumentParser.ParserError : Swift.Error in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A7DecoderCs0C0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ArgumentParser.ArgumentDecoder : Swift.Decoder in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s15XCResultStorage0B5ErrorOs0C0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultStorage.StorageError : Swift.Error in XCResultStorage"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser18SingleValueDecoderVs0E0AAMc"),
            "protocol conformance descriptor for ArgumentParser.SingleValueDecoder : Swift.Decoder in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandP14ArgumentParser08ParsableD0Tb"),
            "base conformance descriptor for ACPToolLib.CKToolCommand: ArgumentParser.ParsableCommand"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation14LocalizedErrorPs0C0Tb"),
            "base conformance descriptor for Foundation.LocalizedError: Swift.Error"
        )
    }

    func testSwiftUserProtocolConformanceDescriptorWrappers() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenVAA13CKToolCommandAAMc"),
            "protocol conformance descriptor for ACPToolLib.RemoveToken : ACPToolLib.CKToolCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenVAA13CKToolCommandAAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for ACPToolLib.RemoveToken : ACPToolLib.CKToolCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13StandardError33_A739266C6FF80344D3E43DAE21F03727LLVs16TextOutputStreamAAMc"),
            "protocol conformance descriptor for ACPToolLib.(StandardError in _A739266C6FF80344D3E43DAE21F03727) : Swift.TextOutputStream in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib24APIRequestBuilderFactoryC9ACPAPIKit07RequestdE0AAMc"),
            "protocol conformance descriptor for ACPToolLib.APIRequestBuilderFactory : ACPAPIKit.RequestBuilderFactory in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib24APIRequestBuilderFactoryC9ACPAPIKit07RequestdE0AAWP"),
            "protocol witness table for ACPToolLib.APIRequestBuilderFactory : ACPAPIKit.RequestBuilderFactory in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamCAA011EventRecordeF0AAMc"),
            "protocol conformance descriptor for DataViewer.FileBackedReadStream : DataViewer.EventRecordReadStream in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamCAA011EventRecordeF0AAWP"),
            "protocol witness table for DataViewer.FileBackedReadStream : DataViewer.EventRecordReadStream in DataViewer"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13Schema_v0_0_0VAA0C9ProvidingAAMc"),
            "protocol conformance descriptor for XCResultCLI.Schema_v0_0_0 : XCResultCLI.SchemaProviding in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13Schema_v0_0_0VAA0C9ProvidingAAWP"),
            "protocol witness table for XCResultCLI.Schema_v0_0_0 : XCResultCLI.SchemaProviding in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation24FloatingPointFormatStyleVyxGAA0dE0AAMc"),
            "protocol conformance descriptor for Foundation.FloatingPointFormatStyle<A> : Foundation.FormatStyle in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI11RootCommandV0A18Kit_ArgumentParser08ParsableD0AAMc"),
            "protocol conformance descriptor for XCResultCLI.RootCommand : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI11RootCommandV0A18Kit_ArgumentParser08ParsableD0AAMcMK"),
            "metadata instantiation cache for protocol conformance descriptor for XCResultCLI.RootCommand : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV17XCResultDataViews13DatabaseValueADMc"),
            "protocol conformance descriptor for Foundation.URL : XCResultDataViews.DatabaseValue in XCResultDataViews"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV17XCResultDataViews13DatabaseValueADWP"),
            "protocol witness table for Foundation.URL : XCResultDataViews.DatabaseValue in XCResultDataViews"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4DataV21XCSchemaSerialization18SchemaSerializableADMc"),
            "protocol conformance descriptor for Foundation.Data : XCSchemaSerialization.SchemaSerializable in XCSchemaSerialization"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4DataV21XCSchemaSerialization18SchemaSerializableADWP"),
            "protocol witness table for Foundation.Data : XCSchemaSerialization.SchemaSerializable in XCSchemaSerialization"
        )
    }

    func testSwiftLazyWitnessTableWrappers() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenVAC14ArgumentParser15ParsableCommandAAWl"),
            "lazy protocol witness table accessor for type ACPToolLib.RemoveToken and conformance ACPToolLib.RemoveToken : ArgumentParser.ParsableCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyAA11ResetSchemaVGACyxG14ArgumentParser17ParsableArgumentsAAWL"),
            "lazy protocol witness table cache variable for type ACPToolLib.AuthOptions<ACPToolLib.ResetSchema> and conformance ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOACs0D0AAWL"),
            "lazy protocol witness table cache variable for type ACPToolLib.APIRequestError and conformance ACPToolLib.APIRequestError : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOACs0D0AAWl"),
            "lazy protocol witness table accessor for type ACPToolLib.APIRequestError and conformance ACPToolLib.APIRequestError : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO5ErrorOAEsAdAWL"),
            "lazy protocol witness table cache variable for type ACPToolLib.TokenManagement.Error and conformance ACPToolLib.TokenManagement.Error : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO5ErrorOAEsAdAWl"),
            "lazy protocol witness table accessor for type ACPToolLib.TokenManagement.Error and conformance ACPToolLib.TokenManagement.Error : Swift.Error in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI15DifferentialDTOVSgxSgSEsSERzlWL"),
            "lazy protocol witness table cache variable for type XCResultCLI.DifferentialDTO? and conformance <A where A: Swift.Encodable> A? : Swift.Encodable in Swift"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI15DifferentialDTOVSgxSgSEsSERzlWl"),
            "lazy protocol witness table accessor for type XCResultCLI.DifferentialDTO? and conformance <A where A: Swift.Encodable> A? : Swift.Encodable in Swift"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13StandardError33_A739266C6FF80344D3E43DAE21F03727LLVADs16TextOutputStreamAAWL"),
            "lazy protocol witness table cache variable for type ACPToolLib.(StandardError in _A739266C6FF80344D3E43DAE21F03727) and conformance ACPToolLib.(StandardError in _A739266C6FF80344D3E43DAE21F03727) : Swift.TextOutputStream in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13StandardError33_A739266C6FF80344D3E43DAE21F03727LLVADs16TextOutputStreamAAWl"),
            "lazy protocol witness table accessor for type ACPToolLib.(StandardError in _A739266C6FF80344D3E43DAE21F03727) and conformance ACPToolLib.(StandardError in _A739266C6FF80344D3E43DAE21F03727) : Swift.TextOutputStream in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser18SingleValueDecoderVACs0E0AAWL"),
            "lazy protocol witness table cache variable for type ArgumentParser.SingleValueDecoder and conformance ArgumentParser.SingleValueDecoder : Swift.Decoder in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO21AcceptableContentTypeOAG31XCResultKit_OpenAPIRuntime_XCRK0G8ProtocolAAWL"),
            "lazy protocol witness table cache variable for type DataViewer.Operations.GetTestRuns.AcceptableContentType and conformance DataViewer.Operations.GetTestRuns.AcceptableContentType : XCResultKit_OpenAPIRuntime_XCRK.AcceptableProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO21AcceptableContentTypeOAG31XCResultKit_OpenAPIRuntime_XCRK0G8ProtocolAAWl"),
            "lazy protocol witness table accessor for type DataViewer.Operations.GetTestRuns.AcceptableContentType and conformance DataViewer.Operations.GetTestRuns.AcceptableContentType : XCResultKit_OpenAPIRuntime_XCRK.AcceptableProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerCACScAAAWL"),
            "lazy protocol witness table cache variable for type DataViewer.Transformer and conformance DataViewer.Transformer : Swift.Actor in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13AttributeListVAC08XCResultA5Views13DatabaseValueAAWL"),
            "lazy protocol witness table cache variable for type DataViewer.AttributeList and conformance DataViewer.AttributeList : XCResultDataViews.DatabaseValue in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13RecordWrapperVAC08XCResultA5Views20DatabaseSerializableAAWL"),
            "lazy protocol witness table cache variable for type DataViewer.RecordWrapper and conformance DataViewer.RecordWrapper : XCResultDataViews.DatabaseSerializable in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamC0cdeF5ErrorOAESQAAWL"),
            "lazy protocol witness table cache variable for type DataViewer.FileBackedReadStream.FileBackedReadStreamError and conformance DataViewer.FileBackedReadStream.FileBackedReadStreamError : Swift.Equatable in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4DataVAcA0B8ProtocolAAWL"),
            "lazy protocol witness table cache variable for type Foundation.Data and conformance Foundation.Data : Foundation.DataProtocol in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation24FloatingPointFormatStyleVySdGACyxGAA0dE0AAWL"),
            "lazy protocol witness table cache variable for type Foundation.FloatingPointFormatStyle<Swift.Double> and conformance Foundation.FloatingPointFormatStyle<A> : Foundation.FormatStyle in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation24FloatingPointFormatStyleVySdGACyxGAA0dE0AAWl"),
            "lazy protocol witness table accessor for type Foundation.FloatingPointFormatStyle<Swift.Double> and conformance Foundation.FloatingPointFormatStyle<A> : Foundation.FormatStyle in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation8URLErrorVAcA21_BridgedStoredNSErrorAAWL"),
            "lazy protocol witness table cache variable for type Foundation.URLError and conformance Foundation.URLError : Foundation._BridgedStoredNSError in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation8URLErrorVAcA21_BridgedStoredNSErrorAAWl"),
            "lazy protocol witness table accessor for type Foundation.URLError and conformance Foundation.URLError : Foundation._BridgedStoredNSError in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation8URLErrorVAcA21_BridgedStoredNSErrorAAWlTm"),
            "merged lazy protocol witness table accessor for type Foundation.URLError and conformance Foundation.URLError : Foundation._BridgedStoredNSError in Foundation"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI11RootCommandVAC0A18Kit_ArgumentParser08ParsableD0AAWL"),
            "lazy protocol witness table cache variable for type XCResultCLI.RootCommand and conformance XCResultCLI.RootCommand : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI11RootCommandVAC0A18Kit_ArgumentParser08ParsableD0AAWlTm"),
            "merged lazy protocol witness table accessor for type XCResultCLI.RootCommand and conformance XCResultCLI.RootCommand : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13ExportMetricsV10CodingKeys031_02D582F67D1E1D5718BD1D8F4247F5I0LLOAFSQAAWL"),
            "lazy protocol witness table cache variable for type XCResultCLI.ExportMetrics.(CodingKeys in _02D582F67D1E1D5718BD1D8F4247F5D1) and conformance XCResultCLI.ExportMetrics.(CodingKeys in _02D582F67D1E1D5718BD1D8F4247F5D1) : Swift.Equatable in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13ExportMetricsV16TestManifestInfo031_02D582F67D1E1D5718BD1D8F4247F5J0LLV10CodingKeysOAHSQAAWL"),
            "lazy protocol witness table cache variable for type XCResultCLI.ExportMetrics.(TestManifestInfo in _02D582F67D1E1D5718BD1D8F4247F5D1).CodingKeys and conformance XCResultCLI.ExportMetrics.(TestManifestInfo in _02D582F67D1E1D5718BD1D8F4247F5D1).CodingKeys : Swift.Equatable in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV14ArgumentParser15ParsableCommandAAWP"),
            "protocol witness table for ACPToolLib.RemoveToken : ArgumentParser.ParsableCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxG14ArgumentParser17ParsableArgumentsAAWI"),
            "instantiation function for generic protocol witness table for ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
    }

    func testSwiftMergedAndAsyncPointerWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11TeamOptionsVwCPTm"),
            "merged initializeBufferWithCopyOfBuffer value witness for ACPToolLib.TeamOptions"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyAA11ResetSchemaVGACyxG14ArgumentParser17ParsableArgumentsAAWlTm"),
            "merged lazy protocol witness table accessor for type ACPToolLib.AuthOptions<ACPToolLib.ResetSchema> and conformance ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolP13getActivitiesyAA10OperationsO03GetE0O6OutputOAH5InputVYaKFTjTu"),
            "async function pointer to dispatch thunk of DataViewer.APIProtocol.getActivities(DataViewer.Operations.GetActivities.Input) async throws -> DataViewer.Operations.GetActivities.Output"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer7HandlerCAA11APIProtocolA2aDP11getTestRunsyAA10OperationsO03GetfG0O6OutputOAJ5InputVYaKFTWTu"),
            "async function pointer to protocol witness for DataViewer.APIProtocol.getTestRuns(DataViewer.Operations.GetTestRuns.Input) async throws -> DataViewer.Operations.GetTestRuns.Output in conformance DataViewer.Handler : DataViewer.APIProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC12setDirectory_12forSessionIdy10Foundation3URLV_AE4UUIDVtYaFTu"),
            "async function pointer to DataViewer.DataViewer.setDirectory(_: Foundation.URL, forSessionId: Foundation.UUID) async -> ()"
        )
    }

    func testSwiftAwaitResumePartialFunctionWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolP11getTestRunsyAA10OperationsO03GeteF0O6OutputOAH5InputVYaKFTjTQ0_"),
            "(1) await resume partial function for dispatch thunk of DataViewer.APIProtocol.getTestRuns(DataViewer.Operations.GetTestRuns.Input) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer7HandlerCAA11APIProtocolA2aDP11getTestRunsyAA10OperationsO03GetfG0O6OutputOAJ5InputVYaKFTWTQ0_"),
            "(1) await resume partial function for protocol witness for DataViewer.APIProtocol.getTestRuns(DataViewer.Operations.GetTestRuns.Input) async throws -> DataViewer.Operations.GetTestRuns.Output in conformance DataViewer.Handler : DataViewer.APIProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE11getTestRuns5query7headersAA10OperationsO03GeteF0O6OutputOAJ5InputV5QueryV_AN7HeadersVtYaKFTQ1_"),
            "(2) await resume partial function for (extension in DataViewer):DataViewer.APIProtocol.getTestRuns(query: DataViewer.Operations.GetTestRuns.Input.Query, headers: DataViewer.Operations.GetTestRuns.Input.Headers) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
    }

    func testSwiftSuspendResumePartialFunctionWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC12setDirectory_12forSessionIdy10Foundation3URLV_AE4UUIDVtYaFTY0_"),
            "(1) suspend resume partial function for DataViewer.DataViewer.setDirectory(_: Foundation.URL, forSessionId: Foundation.UUID) async -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE11getTestRuns5query7headersAA10OperationsO03GeteF0O6OutputOAJ5InputV5QueryV_AN7HeadersVtYaKFTY0_"),
            "(1) suspend resume partial function for (extension in DataViewer):DataViewer.APIProtocol.getTestRuns(query: DataViewer.Operations.GetTestRuns.Input.Query, headers: DataViewer.Operations.GetTestRuns.Input.Headers) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE11getTestRuns5query7headersAA10OperationsO03GeteF0O6OutputOAJ5InputV5QueryV_AN7HeadersVtYaKFTY2_"),
            "(3) suspend resume partial function for (extension in DataViewer):DataViewer.APIProtocol.getTestRuns(query: DataViewer.Operations.GetTestRuns.Input.Query, headers: DataViewer.Operations.GetTestRuns.Input.Headers) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
    }

    func testSwiftOutlinedVariableWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVACyxGycfCTv_"),
            "outlined variable #0 of ACPToolLib.AuthOptions.init() -> ACPToolLib.AuthOptions<A>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13ConfirmPromptO13confirmAction_8canForceSbSS_SbtKFZTv_"),
            "outlined variable #0 of static ACPToolLib.ConfirmPrompt.confirmAction(_: Swift.String, canForce: Swift.Bool) throws -> Swift.Bool"
        )
    }

    func testSwiftTypeMetadataNameReferenceWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyAA11ResetSchemaVGMR"),
            "mangled name ref for type metadata for ACPToolLib.AuthOptions<ACPToolLib.ResetSchema>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyAA11ResetSchemaVGMd"),
            "demangling cache variable for type metadata for ACPToolLib.AuthOptions<ACPToolLib.ResetSchema>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer18EnvironmentWrapperVSgMR"),
            "mangled name ref for type metadata for DataViewer.EnvironmentWrapper?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer18EnvironmentWrapperVSgMd"),
            "demangling cache variable for type metadata for DataViewer.EnvironmentWrapper?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO6OutputO_AGtMR"),
            "mangled name ref for type metadata for (DataViewer.Operations.GetTestRuns.Output, DataViewer.Operations.GetTestRuns.Output)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO6OutputO_AGtMd"),
            "demangling cache variable for type metadata for (DataViewer.Operations.GetTestRuns.Output, DataViewer.Operations.GetTestRuns.Output)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV3key_31XCResultKit_ResultDataPublisher6RecordV7OutcomeO5valuetMR"),
            "mangled name ref for type metadata for (key: Foundation.URL, value: XCResultKit_ResultDataPublisher.Record.Outcome)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV3key_31XCResultKit_ResultDataPublisher6RecordV7OutcomeO5valuetMd"),
            "demangling cache variable for type metadata for (key: Foundation.URL, value: XCResultKit_ResultDataPublisher.Record.Outcome)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLVSg_ADtMR"),
            "mangled name ref for type metadata for (Foundation.URL?, Foundation.URL?)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLVSg_ADtMd"),
            "demangling cache variable for type metadata for (Foundation.URL?, Foundation.URL?)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4UUIDV3key_21ResultsServiceAdaptor17ResultTreeTrackerC0G4Node33_0069DF75BAC54E799CB4D64000DB1A10LLV5valuetMR"),
            "mangled name ref for type metadata for (key: Foundation.UUID, value: ResultsServiceAdaptor.ResultTreeTracker.(ResultNode in _0069DF75BAC54E799CB4D64000DB1A10))"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4UUIDV3key_21ResultsServiceAdaptor17ResultTreeTrackerC0G4Node33_0069DF75BAC54E799CB4D64000DB1A10LLV5valuetMd"),
            "demangling cache variable for type metadata for (key: Foundation.UUID, value: ResultsServiceAdaptor.ResultTreeTracker.(ResultNode in _0069DF75BAC54E799CB4D64000DB1A10))"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation14LocalizedError_pMR"),
            "mangled name ref for type metadata for Foundation.LocalizedError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation14LocalizedError_pMd"),
            "demangling cache variable for type metadata for Foundation.LocalizedError"
        )
    }

    func testSwiftMetadataPatternWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOMXX"),
            "anonymous descriptor ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOMI"),
            "type metadata instantiation cache for ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOMP"),
            "generic type metadata pattern for ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOMi"),
            "type metadata instantiation function for ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib12CreateRecordVMr"),
            "type metadata completion function for ACPToolLib.CreateRecord"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib12CreateRecordVMl"),
            "type metadata singleton initialization cache for ACPToolLib.CreateRecord"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13ExportMetricsV16TestManifestInfo031_02D582F67D1E1D5718BD1D8F4247F5J0LLV10CodingKeysOMa"),
            "type metadata accessor for XCResultCLI.ExportMetrics.(TestManifestInfo in _02D582F67D1E1D5718BD1D8F4247F5D1).CodingKeys"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI14InternalExportV0D4TypeOMa"),
            "type metadata accessor for XCResultCLI.InternalExport.ExportType"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI17FormatDescriptionV03GetC0OMa"),
            "type metadata accessor for XCResultCLI.FormatDescription.GetFormat"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI17FormatDescriptionV4DiffV0C0OMa"),
            "type metadata accessor for XCResultCLI.FormatDescription.Diff.Format"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI3LogV0C4TypeOMa"),
            "type metadata accessor for XCResultCLI.Log.LogType"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11RCPUserCode04UserB8RegistryCMa"),
            "type metadata accessor for RCPUserCode.UserCodeRegistry"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s13XCResultTypes06ResultB5ErrorOMa"),
            "type metadata accessor for XCResultTypes.ResultTypesError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s15XCResultStorage012ResultBundleB0VMa"),
            "type metadata accessor for XCResultStorage.ResultBundleStorage"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser14CompletionKindV0D0OMa"),
            "type metadata accessor for ArgumentParser.CompletionKind.Kind"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10RealityKit6EntityC0A10FoundationE12WriteOptionsV15TextureFileSizeOMa"),
            "type metadata accessor for (extension in RealityFoundation):RealityKit.Entity.WriteOptions.TextureFileSize"
        )
    }

    func testSwiftOutlinedOperationWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib14ValidateSchemaVWOc"),
            "outlined init with copy of ACPToolLib.ValidateSchema"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib14ValidateSchemaVWOh"),
            "outlined destroy of ACPToolLib.ValidateSchema"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOWOe"),
            "outlined consume of ACPToolLib.APIRequestError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOWOy"),
            "outlined copy of ACPToolLib.APIRequestError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLVSg_ADtWOhTm"),
            "merged outlined destroy of (Foundation.URL?, Foundation.URL?)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13RecordWrapperVWOb"),
            "outlined init with take of DataViewer.RecordWrapper"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4DateVSgWOd"),
            "outlined assign with take of Foundation.Date?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation4UUIDVSgWOfTm"),
            "merged outlined assign with copy of Foundation.UUID?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI15DifferentialDTOVSgWOi0_"),
            "outlined enum tag store of XCResultCLI.DifferentialDTO?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI25LongestTestRunsInsightDTOVSgWOg"),
            "outlined enum get tag of XCResultCLI.LongestTestRunsInsightDTO?"
        )
    }

    func testSwiftOneTimeInitializationWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib6ConfigO9isUATMode_WZ"),
            "one-time initialization function for isUATMode"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib6ConfigO9isUATMode_Wz"),
            "one-time initialization token for isUATMode"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO11jsonDecoder33_CE97A694DE5FA682360A96716DFDBC11LL_Wz"),
            "one-time initialization token for (jsonDecoder in _CE97A694DE5FA682360A96716DFDBC11)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO11jsonEncoder33_CE97A694DE5FA682360A96716DFDBC11LL_WZTm"),
            "merged one-time initialization function for (jsonEncoder in _CE97A694DE5FA682360A96716DFDBC11)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib18FlexibleDateParserO15standardFormats33_F54AE3F30DD11B87A7FF15C64494C5EFLL_WZTv_"),
            "outlined variable #0 of one-time initialization function for (standardFormats in _F54AE3F30DD11B87A7FF15C64494C5EF)"
        )
    }

    func testSwiftFunctionSignatureSpecializationWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenVACycfCTf4d_n"),
            "function signature specialization <Arg[0] = Dead> of ACPToolLib.RemoveToken.init() -> ACPToolLib.RemoveToken"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13ConfirmPromptO13confirmAction_8canForceSbSS_SbtKFZTf4nnd_n"),
            "function signature specialization <Arg[2] = Dead> of static ACPToolLib.ConfirmPrompt.confirmAction(_: Swift.String, canForce: Swift.Bool) throws -> Swift.Bool"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV4fromACs7Decoder_p_tKcfCTf4nd_n"),
            "function signature specialization <Arg[1] = Dead> of ACPToolLib.RemoveToken.init(from: Swift.Decoder) throws -> ACPToolLib.RemoveToken"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV10CodingKeys33_1FFE9B4CF854528740D623195E5E1F69LLO11stringValueAFSgSS_tcfCTf4nd_n"),
            "function signature specialization <Arg[1] = Dead> of ACPToolLib.RemoveToken.(CodingKeys in _1FFE9B4CF854528740D623195E5E1F69).init(stringValue: Swift.String) -> ACPToolLib.RemoveToken.(CodingKeys in _1FFE9B4CF854528740D623195E5E1F69)?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLO8intValueAFyx_GSgSi_tcfCTf4dd_n"),
            "function signature specialization <Arg[0] = Dead, Arg[1] = Dead> of ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084).init(intValue: Swift.Int) -> ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13ConfirmPromptO13confirmAction_8canForceSbSS_SbtKFZ9errorTextL_SSvg"),
            "getter of errorText #1 : Swift.String in static ACPToolLib.ConfirmPrompt.confirmAction(_: Swift.String, canForce: Swift.Bool) throws -> Swift.Bool"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer18FailedTestCaseRunsV3sql7contextSSyt_tFZTf4d_n"),
            "function signature specialization <Arg[0] = Dead> of static DataViewer.FailedTestCaseRuns.sql(context: ()) -> Swift.String"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI6ExportV6ObjectV0C4TypeO8rawValueAGSgSS_tcfCTf4nd_n"),
            "function signature specialization <Arg[1] = Dead> of XCResultCLI.Export.Object.ExportType.init(rawValue: Swift.String) -> XCResultCLI.Export.Object.ExportType?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A3SetV16debugDescriptionSSvgTf4x_n"),
            "function signature specialization <Arg[0] = Exploded> of ArgumentParser.ArgumentSet.debugDescription.getter : Swift.String"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13ConfirmPromptO13confirmAction_8canForceSbSS_SbtKFZ9errorTextL_SSvgTf0sn_n"),
            "function signature specialization <Arg[0] = Stack Promoted from Box> of getter of errorText #1 : Swift.String in static ACPToolLib.ConfirmPrompt.confirmAction(_: Swift.String, canForce: Swift.Bool) throws -> Swift.Bool"
        )
    }

    func testSwiftGenericSpecializationWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandPAAE4exit4withys5Error_p_tKFAA12ExportSchemaV_Tg5"),
            "generic specialization <ACPToolLib.ExportSchema> of (extension in ACPToolLib):ACPToolLib.CKToolCommand.exit(with: Swift.Error) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandPAAE4exit4withys5Error_p_tKFAA12ExportSchemaV_Tg5Tm"),
            "merged generic specialization <ACPToolLib.ExportSchema> of (extension in ACPToolLib):ACPToolLib.CKToolCommand.exit(with: Swift.Error) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandPAAE4exit4withys5Error_p_tKFAA11RemoveTokenV_Tg5Tf4nd_nTm"),
            "merged function signature specialization <Arg[1] = Dead> of generic specialization <ACPToolLib.RemoveToken> of (extension in ACPToolLib):ACPToolLib.CKToolCommand.exit(with: Swift.Error) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandPAAE4exit4withys5Error_p_tKFAA12ExportSchemaV_TG5"),
            "generic not re-abstracted specialization <ACPToolLib.ExportSchema> of (extension in ACPToolLib):ACPToolLib.CKToolCommand.exit(with: Swift.Error) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandPAAE4exit4withys5Error_p_tKFAA12ExportSchemaV_Tt1G5"),
            "generic not re-abstracted specialization <ACPToolLib.ExportSchema> of (extension in ACPToolLib):ACPToolLib.CKToolCommand.exit(with: Swift.Error) throws -> ()"
        )
    }

    func testSwiftUnmangledSuffixWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib8KeychainC14removePassword7service7accountySS_SStKFyyKXEfU_TA.1"),
            "partial apply forwarder for closure #1 () throws -> () in ACPToolLib.Keychain.removePassword(service: Swift.String, account: Swift.String) throws -> () with unmangled suffix \".1\""
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO10FailedTestV14failureMessageSSvM.resume.0"),
            "DataViewer.Components.Schemas.FailedTest.failureMessage.modify : Swift.String with unmangled suffix \".resume.0\""
        )
    }

    func testSwiftPrivateContextDiscriminators() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLO"),
            "ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLO11stringValueSSvg"),
            "ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084).stringValue.getter : Swift.String"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLO4hash4intoys6HasherVz_tF"),
            "ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084).hash(into: inout Swift.Hasher) -> ()"
        )
    }

    func testSwiftReflectionMetadataFieldDescriptorWrapper() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVMF"),
            "reflection metadata field descriptor ACPToolLib.AuthOptions"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15APIRequestErrorOMB"),
            "reflection metadata builtin descriptor ACPToolLib.APIRequestError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s13XCResultTypes06ResultB5ErrorOMB"),
            "reflection metadata builtin descriptor XCResultTypes.ResultTypesError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOMF"),
            "reflection metadata field descriptor ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommand_pMF"),
            "reflection metadata field descriptor ACPToolLib.CKToolCommand"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation15ContiguousBytes_pML"),
            "lazy cache variable for type metadata for Foundation.ContiguousBytes"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation15ContiguousBytes_pMa"),
            "type metadata accessor for Foundation.ContiguousBytes"
        )
    }

    func testSwiftValueWitnessWrappers() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVwxx"),
            "destroy value witness for ACPToolLib.AuthOptions"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVwcp"),
            "initializeWithCopy value witness for ACPToolLib.AuthOptions"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVwCP"),
            "initializeBufferWithCopyOfBuffer value witness for ACPToolLib.AuthOptions"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib12CreateRecordVwtk"),
            "initializeWithTake value witness for ACPToolLib.CreateRecord"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOwet"),
            "getEnumTagSinglePayload value witness for ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOWV"),
            "value witness table for ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)"
        )
    }

    func testSwiftDescriptorAndBaseWitnessTableWrappers() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO10FailedTestV10CodingKeysO11stringValueSSvpMV"),
            "property descriptor for DataViewer.Components.Schemas.FailedTest.CodingKeys.stringValue : Swift.String"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV13configuration14ArgumentParser20CommandConfigurationVvpZ"),
            "static ACPToolLib.RemoveToken.configuration : ArgumentParser.CommandConfiguration"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV13configuration14ArgumentParser20CommandConfigurationVvpZMV"),
            "property descriptor for static ACPToolLib.RemoveToken.configuration : ArgumentParser.CommandConfiguration"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolVersionO04fullD0SSvgZ"),
            "static ACPToolLib.CKToolVersion.fullVersion.getter : Swift.String"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolVersionO04fullD0SSvpZMV"),
            "property descriptor for static ACPToolLib.CKToolVersion.fullVersion : Swift.String"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolVersionO05buildD0SSvau"),
            "ACPToolLib.CKToolVersion.buildVersion.unsafeMutableAddressor : Swift.String"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolVersionO05majorD0SSvau"),
            "ACPToolLib.CKToolVersion.majorVersion.unsafeMutableAddressor : Swift.String"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib6ConfigO18authTokenPathAsURL10Foundation0H0VvpZ"),
            "static ACPToolLib.Config.authTokenPathAsURL : Foundation.URL"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenVAA13CKToolCommandAAMA"),
            "reflection metadata associated type descriptor ACPToolLib.RemoveToken : ACPToolLib.CKToolCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11ResetSchemaVAA13CKToolCommandAAMA"),
            "reflection metadata associated type descriptor ACPToolLib.ResetSchema : ACPToolLib.CKToolCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV5_type33_1FFE9B4CF854528740D623195E5E1F69LL14ArgumentParser6OptionVyAA8AuthTypeOGvpfi"),
            "variable initialization expression of ACPToolLib.RemoveToken.(_type in _1FFE9B4CF854528740D623195E5E1F69) : ArgumentParser.Option<ACPToolLib.AuthType>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV6methodAA0D16ManagementMethodOvpfP"),
            "property wrapper backing initializer of ACPToolLib.RemoveToken.method : ACPToolLib.TokenManagementMethod"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib21TokenManagementMethodOs12CaseIterableAA8AllCasessADP_SlWT"),
            "associated type witness table accessor for Swift.CaseIterable.AllCases : Swift.Collection in ACPToolLib.TokenManagementMethod : Swift.CaseIterable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityItemTypeOs12CaseIterableAA8AllCasessAHP_SlWT"),
            "associated type witness table accessor for Swift.CaseIterable.AllCases : Swift.Collection in DataViewer.Components.Schemas.ActivityItemType : Swift.CaseIterable in DataViewer"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib21TokenManagementMethodOs12CaseIterableAAsADP8allCases03AllI0QzvgZTW"),
            "protocol witness for static Swift.CaseIterable.allCases.getter : A.AllCases in conformance ACPToolLib.TokenManagementMethod : Swift.CaseIterable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib21TokenManagementMethodOs12CaseIterableAAsADP8allCases03AllI0QzvgZTWTv_"),
            "outlined variable #0 of protocol witness for static Swift.CaseIterable.allCases.getter : A.AllCases in conformance ACPToolLib.TokenManagementMethod : Swift.CaseIterable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib21TokenManagementMethodO14ArgumentParser013ExpressibleByF0AadEP21defaultCompletionKindAD0kL0VvgZTW"),
            "protocol witness for static ArgumentParser.ExpressibleByArgument.defaultCompletionKind.getter : ArgumentParser.CompletionKind in conformance ACPToolLib.TokenManagementMethod : ArgumentParser.ExpressibleByArgument in ACPToolLib"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI10ActivitiesV0A18Kit_ArgumentParser15ParsableCommandAadEP13configurationAD0H13ConfigurationVvgZTW"),
            "protocol witness for static XCResultKit_ArgumentParser.ParsableCommand.configuration.getter : XCResultKit_ArgumentParser.CommandConfiguration in conformance XCResultCLI.Activities : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser4NameOSLAASL1loiySbx_xtFZTW"),
            "protocol witness for static Swift.Comparable.< infix(A, A) -> Swift.Bool in conformance ArgumentParser.Name : Swift.Comparable in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser26SingleValueParsingStrategyOSHAASH04hashD0SivgTW"),
            "protocol witness for Swift.Hashable.hashValue.getter : Swift.Int in conformance ArgumentParser.SingleValueParsingStrategy : Swift.Hashable in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser26SingleValueParsingStrategyOSHAASH08_rawHashD04seedS2i_tFTW"),
            "protocol witness for Swift.Hashable._rawHashValue(seed: Swift.Int) -> Swift.Int in conformance ArgumentParser.SingleValueParsingStrategy : Swift.Hashable in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI17FormatDescriptionV03GetC0O0A18Kit_ArgumentParser013ExpressibleByG0AafGP012defaultValueD0SSvgTW"),
            "protocol witness for XCResultKit_ArgumentParser.ExpressibleByArgument.defaultValueDescription.getter : Swift.String in conformance XCResultCLI.FormatDescription.GetFormat : XCResultKit_ArgumentParser.ExpressibleByArgument in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV10CodingKeys33_1FFE9B4CF854528740D623195E5E1F69LLOMf"),
            "full type metadata for ACPToolLib.RemoveToken.(CodingKeys in _1FFE9B4CF854528740D623195E5E1F69)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_Gs0E3KeyAAs23CustomStringConvertiblePWb"),
            "base witness table accessor for Swift.CustomStringConvertible in ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.CodingKey in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_GSHAASQWb"),
            "base witness table accessor for Swift.Equatable in ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.Hashable in ACPToolLib"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib16APIResponseErrorV10Foundation09LocalizedD0AAs0D0PWb"),
            "base witness table accessor for Swift.Error in ACPToolLib.APIResponseError : Foundation.LocalizedError in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15TokenManagementO5ErrorO10Foundation09LocalizedE0AAsADPWb"),
            "base witness table accessor for Swift.Error in ACPToolLib.TokenManagement.Error : Foundation.LocalizedError in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV21XCSchemaSerializationE0D5ErrorOMn"),
            "nominal type descriptor for (extension in XCSchemaSerialization):Foundation.URL.SerializationError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV21XCSchemaSerializationE0D5ErrorOAA09LocalizedE0ADs0E0PWb"),
            "base witness table accessor for Swift.Error in (extension in XCSchemaSerialization):Foundation.URL.SerializationError : Foundation.LocalizedError in XCSchemaSerialization"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation8TimeZoneV21XCSchemaSerializationE0E5ErrorOMn"),
            "nominal type descriptor for (extension in XCSchemaSerialization):Foundation.TimeZone.SerializationError"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation8TimeZoneV21XCSchemaSerializationE0E5ErrorOAA09LocalizedF0ADs0F0PWb"),
            "base witness table accessor for Swift.Error in (extension in XCSchemaSerialization):Foundation.TimeZone.SerializationError : Foundation.LocalizedError in XCSchemaSerialization"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO21AcceptableContentTypeO31XCResultKit_OpenAPIRuntime_XCRK0G8ProtocolAASHWb"),
            "base witness table accessor for Swift.Hashable in DataViewer.Operations.GetTestRuns.AcceptableContentType : XCResultKit_OpenAPIRuntime_XCRK.AcceptableProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO21AcceptableContentTypeO31XCResultKit_OpenAPIRuntime_XCRK0G8ProtocolAASYWb"),
            "base witness table accessor for Swift.RawRepresentable in DataViewer.Operations.GetTestRuns.AcceptableContentType : XCResultKit_OpenAPIRuntime_XCRK.AcceptableProtocol in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamC0cdeF5ErrorOSHAASQWb"),
            "base witness table accessor for Swift.Equatable in DataViewer.FileBackedReadStream.FileBackedReadStreamError : Swift.Hashable in DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI10ActivitiesV0A18Kit_ArgumentParser15ParsableCommandAaD0G9ArgumentsPWb"),
            "base witness table accessor for XCResultKit_ArgumentParser.ParsableArguments in XCResultCLI.Activities : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI10GetMetricsV0A18Kit_ArgumentParser15ParsableCommandAaD0H9ArgumentsPWb"),
            "base witness table accessor for XCResultKit_ArgumentParser.ParsableArguments in XCResultCLI.GetMetrics : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI17FormatDescriptionV11InternalGetV0A18Kit_ArgumentParser15ParsableCommandAaF0J9ArgumentsPWb"),
            "base witness table accessor for XCResultKit_ArgumentParser.ParsableArguments in XCResultCLI.FormatDescription.InternalGet : XCResultKit_ArgumentParser.ParsableCommand in XCResultCLI"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE16registerHandlers2on9serverURL13configuration11middlewaresy31XCResultKit_OpenAPIRuntime_XCRK15ServerTransport_p_10Foundation0H0VAI13ConfigurationVSayAI0P10Middleware_pGtKF"),
            "(extension in DataViewer):DataViewer.APIProtocol.registerHandlers(on: XCResultKit_OpenAPIRuntime_XCRK.ServerTransport, serverURL: Foundation.URL, configuration: XCResultKit_OpenAPIRuntime_XCRK.Configuration, middlewares: [XCResultKit_OpenAPIRuntime_XCRK.ServerMiddleware]) throws -> ()"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer7HandlerC16registerHandlers4withy31XCResultKit_OpenAPIRuntime_XCRK15ServerTransport_p_tKF"),
            "DataViewer.Handler.registerHandlers(with: XCResultKit_OpenAPIRuntime_XCRK.ServerTransport) throws -> ()"
        )
    }

    func testSwiftOpenAPIRegisterHandlersClosureWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE16registerHandlers2on9serverURL13configuration11middlewaresy31XCResultKit_OpenAPIRuntime_XCRK15ServerTransport_p_10Foundation0H0VAI13ConfigurationVSayAI0P10Middleware_pGtKF0kL10_HTTPTypes12HTTPResponseV_AI8HTTPBodyCSgtAR11HTTPRequestV_AwI0P15RequestMetadataVtYaYbKcfU0_"),
            "closure #2 @Sendable (XCResultKit_HTTPTypes.HTTPRequest, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?, XCResultKit_OpenAPIRuntime_XCRK.ServerRequestMetadata) async throws -> (XCResultKit_HTTPTypes.HTTPResponse, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?) in (extension in DataViewer):DataViewer.APIProtocol.registerHandlers(on: XCResultKit_OpenAPIRuntime_XCRK.ServerTransport, serverURL: Foundation.URL, configuration: XCResultKit_OpenAPIRuntime_XCRK.Configuration, middlewares: [XCResultKit_OpenAPIRuntime_XCRK.ServerMiddleware]) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE16registerHandlers2on9serverURL13configuration11middlewaresy31XCResultKit_OpenAPIRuntime_XCRK15ServerTransport_p_10Foundation0H0VAI13ConfigurationVSayAI0P10Middleware_pGtKF0kL10_HTTPTypes12HTTPResponseV_AI8HTTPBodyCSgtAR11HTTPRequestV_AwI0P15RequestMetadataVtYaYbKcfU0_AA7HandlerC_Tg5TA"),
            "partial apply forwarder for generic specialization <DataViewer.Handler> of closure #2 @Sendable (XCResultKit_HTTPTypes.HTTPRequest, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?, XCResultKit_OpenAPIRuntime_XCRK.ServerRequestMetadata) async throws -> (XCResultKit_HTTPTypes.HTTPResponse, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?) in (extension in DataViewer):DataViewer.APIProtocol.registerHandlers(on: XCResultKit_OpenAPIRuntime_XCRK.ServerTransport, serverURL: Foundation.URL, configuration: XCResultKit_OpenAPIRuntime_XCRK.Configuration, middlewares: [XCResultKit_OpenAPIRuntime_XCRK.ServerMiddleware]) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14DataController11APIProtocolPAAE16registerHandlers2on9serverURL13configuration11middlewaresy31XCResultKit_OpenAPIRuntime_XCRK15ServerTransport_p_10Foundation0H0VAI13ConfigurationVSayAI0P10Middleware_pGtKF0kL10_HTTPTypes12HTTPResponseV_AI8HTTPBodyCSgtAR11HTTPRequestV_AwI0P15RequestMetadataVtYaYbKcfU_TA"),
            "partial apply forwarder for closure #1 @Sendable (XCResultKit_HTTPTypes.HTTPRequest, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?, XCResultKit_OpenAPIRuntime_XCRK.ServerRequestMetadata) async throws -> (XCResultKit_HTTPTypes.HTTPResponse, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?) in (extension in DataController):DataController.APIProtocol.registerHandlers(on: XCResultKit_OpenAPIRuntime_XCRK.ServerTransport, serverURL: Foundation.URL, configuration: XCResultKit_OpenAPIRuntime_XCRK.Configuration, middlewares: [XCResultKit_OpenAPIRuntime_XCRK.ServerMiddleware]) throws -> ()"
        )
    }

    func testSwiftImplicitClosureWrappers() {
        // Ground truth: swift-demangle via uncovered_dump.tsv.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib12ImportSchemaV5_file33_A4DC42538D14667349C79BA3856179F2LL14ArgumentParser6OptionVy10Foundation3URLVGvpfiAKSShcfu_"),
            "implicit closure #1 (__shared Swift.String) -> Foundation.URL in variable initialization expression of ACPToolLib.ImportSchema.(_file in _A4DC42538D14667349C79BA3856179F2) : ArgumentParser.Option<Foundation.URL>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerC36convertRecordsToActivityTreeResponse_6cursor13testCaseRunId6isDoneAA10ComponentsO7SchemasO0ghI0VSay018XCResultKit_ResultA9Publisher6RecordVG_S2SSbtFSSycfu0_Tm"),
            "merged implicit closure #2 () -> Swift.String in DataViewer.Transformer.convertRecordsToActivityTreeResponse(_: [XCResultKit_ResultDataPublisher.Record], cursor: Swift.String, testCaseRunId: Swift.String, isDone: Swift.Bool) -> DataViewer.Components.Schemas.ActivityTreeResponse"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14DataController12MessageStoreC11deleteBatch33_F78A2AAC07F7EB054AA62607CD2A3504LL_3forySi_10Foundation4UUIDVtKFAIycfu0_TA"),
            "partial apply forwarder for implicit closure #2 () -> Foundation.UUID in DataController.MessageStore.(deleteBatch in _F78A2AAC07F7EB054AA62607CD2A3504)(_: Swift.Int, for: Foundation.UUID) throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s15XCResultStorage18ResultBundleReaderC12fromSnapshotyyp21XCSchemaSerialization18SchemaSerializable_pKFypXpycfu_TA"),
            "partial apply forwarder for implicit closure #1 () -> Any.Type in XCResultStorage.ResultBundleReader.fromSnapshot(XCSchemaSerialization.SchemaSerializable) throws -> Any"
        )
    }

    func testSwiftEnumCaseWrapper() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO10FailedTestV10CodingKeysO14failureMessageyA2ImFWC"),
            "enum case for DataViewer.Components.Schemas.FailedTest.CodingKeys.failureMessage(DataViewer.Components.Schemas.FailedTest.CodingKeys.Type) -> DataViewer.Components.Schemas.FailedTest.CodingKeys"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV10CodingKeysO011multiDeviceK10IdentifieryA2ImFWC"),
            "enum case for DataViewer.Components.Schemas.ActivityTreeItem.CodingKeys.multiDeviceDeviceIdentifier(DataViewer.Components.Schemas.ActivityTreeItem.CodingKeys.Type) -> DataViewer.Components.Schemas.ActivityTreeItem.CodingKeys"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO17TestCasesResponseV10CodingKeysO04testF0yA2ImFWC"),
            "enum case for DataViewer.Components.Schemas.TestCasesResponse.CodingKeys.testCases(DataViewer.Components.Schemas.TestCasesResponse.CodingKeys.Type) -> DataViewer.Components.Schemas.TestCasesResponse.CodingKeys"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO19FailedTestsResponseV10CodingKeysO06failedF0yA2ImFWC"),
            "enum case for DataViewer.Components.Schemas.FailedTestsResponse.CodingKeys.failedTests(DataViewer.Components.Schemas.FailedTestsResponse.CodingKeys.Type) -> DataViewer.Components.Schemas.FailedTestsResponse.CodingKeys"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation8CalendarV9ComponentO3dayyA2EmFWC"),
            "enum case for Foundation.Calendar.Component.day(Foundation.Calendar.Component.Type) -> Foundation.Calendar.Component"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV13DirectoryHintO02isC0yA2EmFWC"),
            "enum case for Foundation.URL.DirectoryHint.isDirectory(Foundation.URL.DirectoryHint.Type) -> Foundation.URL.DirectoryHint"
        )
    }

    func testSwiftMethodDescriptorWrapper() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15URLSessionStoreCACycfCTq"),
            "method descriptor for ACPToolLib.URLSessionStore.__allocating_init() -> ACPToolLib.URLSessionStore"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolP11getTestRunsyAA10OperationsO03GeteF0O6OutputOAH5InputVYaKFTq"),
            "method descriptor for DataViewer.APIProtocol.getTestRuns(DataViewer.Operations.GetTestRuns.Input) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
    }

    func testSwiftProtocolDescriptorWrappers() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib13CKToolCommandMp"),
            "protocol descriptor for ACPToolLib.CKToolCommand"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolTL"),
            "protocol requirements base descriptor for DataViewer.APIProtocol"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI14StatisticsItem33_A26C9E221B7CA36FE4F2117EA0BB2925LLMp"),
            "protocol descriptor for XCResultCLI.(StatisticsItem in _A26C9E221B7CA36FE4F2117EA0BB2925)"
        )
    }

    func testSwiftDirectFieldOffsetWrapper() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15URLSessionStoreC5store33_8BF6332344D06B706DA0091D22264614LLSDySSSo12NSURLSessionCGvpWvd"),
            "direct field offset for ACPToolLib.URLSessionStore.(store in _8BF6332344D06B706DA0091D22264614) : [Swift.String : __C.NSURLSession]"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI17TestCaseViewModelC022$__lazy_storage_$_testD11Description33_A8A4EBC065A47521EBACA7A1ED3E9445LLSSSgvpWvd"),
            "direct field offset for XCResultCLI.TestCaseViewModel.($__lazy_storage_$_testCaseDescription in _A8A4EBC065A47521EBACA7A1ED3E9445) : Swift.String?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI17TestCaseViewModelC31$__lazy_storage_$_hasActivities33_A8A4EBC065A47521EBACA7A1ED3E9445LLSbSgvpWvd"),
            "direct field offset for XCResultCLI.TestCaseViewModel.($__lazy_storage_$_hasActivities in _A8A4EBC065A47521EBACA7A1ED3E9445) : Swift.Bool?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamC4file33_70E422EC46D7405A99DACEDE475B55FFLLSpySo7__sFILEVGvpWvd"),
            "direct field offset for DataViewer.FileBackedReadStream.(file in _70E422EC46D7405A99DACEDE475B55FF) : Swift.UnsafeMutablePointer<__C.__sFILE>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib17APIRequestBuilderC12sessionStore33_FDF3AEB594F5AD95E1B345C77DA5CC1ELLAA010URLSessionF0CvpWvd"),
            "direct field offset for ACPToolLib.APIRequestBuilder.(sessionStore in _FDF3AEB594F5AD95E1B345C77DA5CC1E) : ACPToolLib.URLSessionStore"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib8KeychainC5queue33_F24716125FCA50D7A95B58C64BD0783ELLSo012OS_dispatch_D0CvpWvd"),
            "direct field offset for ACPToolLib.Keychain.(queue in _F24716125FCA50D7A95B58C64BD0783E) : __C.OS_dispatch_queue"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC3url10Foundation3URLVvpMV"),
            "property descriptor for DataViewer.DataViewer.url : Foundation.URL"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC7handlerAA7HandlerCvpWvd"),
            "direct field offset for DataViewer.DataViewer.handler : DataViewer.Handler"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV011multiDeviceI10IdentifierSSSgvpMV"),
            "property descriptor for DataViewer.Components.Schemas.ActivityTreeItem.multiDeviceDeviceIdentifier : Swift.String?"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV13executionModeAE0e9ExecutionI0OSgvpMV"),
            "property descriptor for DataViewer.Components.Schemas.ActivityTreeItem.executionMode : DataViewer.Components.Schemas.ActivityExecutionMode?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV5_typeAE0eG4TypeOvpMV"),
            "property descriptor for DataViewer.Components.Schemas.ActivityTreeItem._type : DataViewer.Components.Schemas.ActivityItemType"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO20TestCaseRunsResponseV4runsSayAE0eF3RunVGvpMV"),
            "property descriptor for DataViewer.Components.Schemas.TestCaseRunsResponse.runs : [DataViewer.Components.Schemas.TestCaseRun]"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO5InputV7HeadersV6acceptSay31XCResultKit_OpenAPIRuntime_XCRK23AcceptHeaderContentTypeVyAE010AcceptableqR0OGGvpMV"),
            "property descriptor for DataViewer.Operations.GetTestRuns.Input.Headers.accept : [XCResultKit_OpenAPIRuntime_XCRK.AcceptHeaderContentType<DataViewer.Operations.GetTestRuns.AcceptableContentType>]"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14DataController10OperationsO14PostAttachmentO5InputV7HeadersV6acceptSay31XCResultKit_OpenAPIRuntime_XCRK23AcceptHeaderContentTypeVyAE010AcceptablepQ0OGGvpMV"),
            "property descriptor for DataController.Operations.PostAttachment.Input.Headers.accept : [XCResultKit_OpenAPIRuntime_XCRK.AcceptHeaderContentType<DataController.Operations.PostAttachment.AcceptableContentType>]"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14DataController10OperationsO14PostEventBatchO6OutputO10badRequestAG03BadI0VvpMV"),
            "property descriptor for DataController.Operations.PostEventBatch.Output.badRequest : DataController.Operations.PostEventBatch.Output.BadRequest"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerC15unownedExecutorScevpMV"),
            "property descriptor for DataViewer.Transformer.unownedExecutor : Swift.UnownedSerialExecutor"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A0V12wrappedValuexvpMV"),
            "property descriptor for ArgumentParser.Argument.wrappedValue : A"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A4HelpV8abstractSSvM.resume.0"),
            "ArgumentParser.ArgumentHelp.abstract.modify : Swift.String with unmangled suffix \".resume.0\""
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A7DecoderC16nextCommandIndexSivpWvd"),
            "direct field offset for ArgumentParser.ArgumentDecoder.nextCommandIndex : Swift.Int"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV011multiDeviceI10IdentifierSSSgvpAGTK"),
            "key path getter for DataViewer.Components.Schemas.ActivityTreeItem.multiDeviceDeviceIdentifier : Swift.String? : DataViewer.Components.Schemas.ActivityTreeItem"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO16ActivityTreeItemV011multiDeviceI10IdentifierSSSgvpAGTk"),
            "key path setter for DataViewer.Components.Schemas.ActivityTreeItem.multiDeviceDeviceIdentifier : Swift.String? : DataViewer.Components.Schemas.ActivityTreeItem"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s15XCResultStorage18ResultBundleReaderC10convertersSayAA22SerializationConverter_pGvg"),
            "XCResultStorage.ResultBundleReader.converters.getter : [XCResultStorage.SerializationConverter]"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s15XCResultStorage18ResultBundleReaderC10convertersSayAA22SerializationConverter_pGvpWvd"),
            "direct field offset for XCResultStorage.ResultBundleReader.converters : [XCResultStorage.SerializationConverter]"
        )
    }

    func testSwiftStaticFunctionTail() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer10ComponentsO7SchemasO10FailedTestV2eeoiySbAG_AGtFZ"),
            "static DataViewer.Components.Schemas.FailedTest.== infix(DataViewer.Components.Schemas.FailedTest, DataViewer.Components.Schemas.FailedTest) -> Swift.Bool"
        )
    }

    func testSwiftStaticSelfPropertyAccessors() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC5localABvgZ"),
            "static DataViewer.DataViewer.local.getter : DataViewer.DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC5localABvpZMV"),
            "property descriptor for static DataViewer.DataViewer.local : DataViewer.DataViewer"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC5localABvgZTu"),
            "async function pointer to static DataViewer.DataViewer.local.getter : DataViewer.DataViewer"
        )
    }

    func testSwiftTaskPrivateStaticPropertyAndClosureWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC9localTask33_FC1F129190A6C68A1C5A1438BA3C6606LLScTyABs5Error_pGvpZ"),
            "static DataViewer.DataViewer.(localTask in _FC1F129190A6C68A1C5A1438BA3C6606) : Swift.Task<DataViewer.DataViewer, Swift.Error>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC9localTask33_FC1F129190A6C68A1C5A1438BA3C6606LLScTyABs5Error_pGvpZfiAByYaKcfU_"),
            "closure #1 () async throws -> DataViewer.DataViewer in variable initialization expression of static DataViewer.DataViewer.(localTask in _FC1F129190A6C68A1C5A1438BA3C6606) : Swift.Task<DataViewer.DataViewer, Swift.Error>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC9localTask33_FC1F129190A6C68A1C5A1438BA3C6606LLScTyABs5Error_pGvpZfiAByYaKcfU_TA"),
            "partial apply forwarder for closure #1 () async throws -> DataViewer.DataViewer in variable initialization expression of static DataViewer.DataViewer.(localTask in _FC1F129190A6C68A1C5A1438BA3C6606) : Swift.Task<DataViewer.DataViewer, Swift.Error>"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC9localTask33_FC1F129190A6C68A1C5A1438BA3C6606LLScTyABs5Error_pGvpZfiAByYaKcfU_TATQ0_"),
            "(1) await resume partial function for partial apply forwarder for closure #1 () async throws -> DataViewer.DataViewer in variable initialization expression of static DataViewer.DataViewer.(localTask in _FC1F129190A6C68A1C5A1438BA3C6606) : Swift.Task<DataViewer.DataViewer, Swift.Error>"
        )
    }

    func testSwiftProtocolWitnessThunks() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_GSHAASH4hash4intoys6HasherVz_tFTW"),
            "protocol witness for Swift.Hashable.hash(into: inout Swift.Hasher) -> () in conformance ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.Hashable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_GSHAASH9hashValueSivgTW"),
            "protocol witness for Swift.Hashable.hashValue.getter : Swift.Int in conformance ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.Hashable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_GSQAASQ2eeoiySbx_xtFZTW"),
            "protocol witness for static Swift.Equatable.== infix(A, A) -> Swift.Bool in conformance ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.Equatable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib21TokenManagementMethodOSYAASY8rawValue03RawG0QzvgTW"),
            "protocol witness for Swift.RawRepresentable.rawValue.getter : A.RawValue in conformance ACPToolLib.TokenManagementMethod : Swift.RawRepresentable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib21TokenManagementMethodOSYAASY8rawValuexSg03RawG0Qz_tcfCTW"),
            "protocol witness for Swift.RawRepresentable.init(rawValue: A.RawValue) -> A? in conformance ACPToolLib.TokenManagementMethod : Swift.RawRepresentable in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer7HandlerCAA11APIProtocolA2aDP11getTestRunsyAA10OperationsO03GetfG0O6OutputOAJ5InputVYaKFTW"),
            "protocol witness for DataViewer.APIProtocol.getTestRuns(DataViewer.Operations.GetTestRuns.Input) async throws -> DataViewer.Operations.GetTestRuns.Output in conformance DataViewer.Handler : DataViewer.APIProtocol in DataViewer"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s11XCResultCLI13Schema_v0_0_0VAA0C9ProvidingA2aDP10getMetricsSSvgTW"),
            "protocol witness for XCResultCLI.SchemaProviding.getMetrics.getter : Swift.String in conformance XCResultCLI.Schema_v0_0_0 : XCResultCLI.SchemaProviding in XCResultCLI"
        )
    }

    func testSwiftProtocolWitnessThunkBackReferenceRequirements() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_Gs0E3KeyAAsAHP11stringValueSSvgTW"),
            "protocol witness for Swift.CodingKey.stringValue.getter : Swift.String in conformance ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.CodingKey in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_Gs23CustomStringConvertibleAAsAHP11descriptionSSvgTW"),
            "protocol witness for Swift.CustomStringConvertible.description.getter : Swift.String in conformance ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.CustomStringConvertible in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxG14ArgumentParser17ParsableArgumentsAaeFP11_errorLabelSSvgZTW"),
            "protocol witness for static ArgumentParser.ParsableArguments._errorLabel.getter : Swift.String in conformance ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV14ArgumentParser15ParsableCommandAadEP3runyyKFTW"),
            "protocol witness for ArgumentParser.ParsableCommand.run() throws -> () in conformance ACPToolLib.RemoveToken : ArgumentParser.ParsableCommand in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxG14ArgumentParser17ParsableArgumentsAaeFPxycfCTW"),
            "protocol witness for ArgumentParser.ParsableArguments.init() -> A in conformance ACPToolLib.AuthOptions<A> : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV14ArgumentParser17ParsableArgumentsAadEPxycfCTW"),
            "protocol witness for ArgumentParser.ParsableArguments.init() -> A in conformance ACPToolLib.RemoveToken : ArgumentParser.ParsableArguments in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV14ArgumentParser15ParsableCommandAadEP13configurationAD0H13ConfigurationVvgZTW"),
            "protocol witness for static ArgumentParser.ParsableCommand.configuration.getter : ArgumentParser.CommandConfiguration in conformance ACPToolLib.RemoveToken : ArgumentParser.ParsableCommand in ACPToolLib"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer7HandlerCScAAAScA15unownedExecutorScevgTW"),
            "protocol witness for Swift.Actor.unownedExecutor.getter : Swift.UnownedSerialExecutor in conformance DataViewer.Handler : Swift.Actor in DataViewer"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14DataController12MessageStoreC0cD5ErrorO10Foundation09LocalizedE0AafGP16errorDescriptionSSSgvgTW"),
            "protocol witness for Foundation.LocalizedError.errorDescription.getter : Swift.String? in conformance DataController.MessageStore.MessageStoreError : Foundation.LocalizedError in DataController"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14DataController12MessageStoreC0cD5ErrorO10Foundation09LocalizedE0AafGP13failureReasonSSSgvgTW"),
            "protocol witness for Foundation.LocalizedError.failureReason.getter : Swift.String? in conformance DataController.MessageStore.MessageStoreError : Foundation.LocalizedError in DataController"
        )
    }

    func testSwiftProtocolWitnessThunkOwnedParameters() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A10DefinitionV4HelpV7OptionsVs10SetAlgebraAAsAHP5unionyxxnFTW"),
            "protocol witness for Swift.SetAlgebra.union(__owned A) -> A in conformance ArgumentParser.ArgumentDefinition.Help.Options : Swift.SetAlgebra in ArgumentParser"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s14ArgumentParser0A10DefinitionV4HelpV7OptionsVs10SetAlgebraAAsAHP9formUnionyyxnFTW"),
            "protocol witness for Swift.SetAlgebra.formUnion(__owned A) -> () in conformance ArgumentParser.ArgumentDefinition.Help.Options : Swift.SetAlgebra in ArgumentParser"
        )
    }

    func testSwiftProtocolWitnessThunkInitializerRequirement() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLOyx_Gs0E3KeyAAsAHP11stringValuexSgSS_tcfCTW"),
            "protocol witness for Swift.CodingKey.init(stringValue: Swift.String) -> A? in conformance ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084) : Swift.CodingKey in ACPToolLib"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVyxGSeAASe4fromxs7Decoder_p_tKcfCTW"),
            "protocol witness for Swift.Decodable.init(from: Swift.Decoder) throws -> A in conformance ACPToolLib.AuthOptions<A> : Swift.Decodable in ACPToolLib"
        )
    }

    func testSwiftVariadicParameters() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib10printError_9separator10terminatoryypd_S2StF"),
            "ACPToolLib.printError(_: Any..., separator: Swift.String, terminator: Swift.String) -> ()"
        )
    }

    func testSwiftSharedParameterConventionAndMetatype() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation12CharacterSetV12charactersInACSSh_tcfC"),
            "Foundation.CharacterSet.init(charactersIn: __shared Swift.String) -> Foundation.CharacterSet"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation3URLV15fileURLWithPath11isDirectoryACSSh_SbtcfC"),
            "Foundation.URL.init(fileURLWithPath: __shared Swift.String, isDirectory: Swift.Bool) -> Foundation.URL"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10Foundation13URLComponentsV3url23resolvingAgainstBaseURLACSgAA0G0Vh_SbtcfC"),
            "Foundation.URLComponents.init(url: __shared Foundation.URL, resolvingAgainstBaseURL: Swift.Bool) -> Foundation.URLComponents?"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib24APIRequestBuilderFactoryC015getNonDecodableD09ACPAPIKit07RequestD0CyxGmylF"),
            "ACPToolLib.APIRequestBuilderFactory.getNonDecodableBuilder<A>() -> ACPAPIKit.RequestBuilder<A>.Type"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer13RecordWrapperV7columnsSDySS08XCResultA5Views13DatabaseValue_pXpGvpZ"),
            "static DataViewer.RecordWrapper.columns : [Swift.String : XCResultDataViews.DatabaseValue.Type]"
        )
    }

    func testSwiftInitDeinitAndDispatchThunkWrappers() {
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsVACyxGycfC"),
                       "ACPToolLib.AuthOptions.init() -> ACPToolLib.AuthOptions<A>")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV4fromACs7Decoder_p_tKcfC"),
                       "ACPToolLib.RemoveToken.init(from: Swift.Decoder) throws -> ACPToolLib.RemoveToken")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib11RemoveTokenV10CodingKeys33_1FFE9B4CF854528740D623195E5E1F69LLO11stringValueAFSgSS_tcfC"),
                       "ACPToolLib.RemoveToken.(CodingKeys in _1FFE9B4CF854528740D623195E5E1F69).init(stringValue: Swift.String) -> ACPToolLib.RemoveToken.(CodingKeys in _1FFE9B4CF854528740D623195E5E1F69)?")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLO11stringValueAFyx_GSgSS_tcfC"),
                       "ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084).init(stringValue: Swift.String) -> ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)?")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV10CodingKeys33_BF98BAE60DAD5B7FEF0E8674CB5B3084LLO8intValueAFyx_GSgSi_tcfC"),
                       "ACPToolLib.AuthOptions.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084).init(intValue: Swift.Int) -> ACPToolLib.AuthOptions<A>.(CodingKeys in _BF98BAE60DAD5B7FEF0E8674CB5B3084)?")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer7HandlerCACycfC"),
                       "DataViewer.Handler.__allocating_init() -> DataViewer.Handler")
        // Ground truth: swift-demangle.
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer11TransformerC16resultsStreamURL14refreshCadenceAC10Foundation0F0V_SdtKcfC"),
                       "DataViewer.Transformer.__allocating_init(resultsStreamURL: Foundation.URL, refreshCadence: Swift.Double) throws -> DataViewer.Transformer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer11TransformerC16resultsStreamURL14refreshCadenceAC10Foundation0F0V_SdtKcfCTj"),
                       "dispatch thunk of DataViewer.Transformer.__allocating_init(resultsStreamURL: Foundation.URL, refreshCadence: Swift.Double) throws -> DataViewer.Transformer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer11TransformerC16resultsStreamURL14refreshCadenceAC10Foundation0F0V_SdtKcfCTq"),
                       "method descriptor for DataViewer.Transformer.__allocating_init(resultsStreamURL: Foundation.URL, refreshCadence: Swift.Double) throws -> DataViewer.Transformer")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer10OperationsO11GetTestRunsO5InputV7HeadersV6acceptAISay31XCResultKit_OpenAPIRuntime_XCRK23AcceptHeaderContentTypeVyAE010AcceptableqR0OGG_tcfC"),
                       "DataViewer.Operations.GetTestRuns.Input.Headers.init(accept: [XCResultKit_OpenAPIRuntime_XCRK.AcceptHeaderContentType<DataViewer.Operations.GetTestRuns.AcceptableContentType>]) -> DataViewer.Operations.GetTestRuns.Input.Headers")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10ACPToolLib15URLSessionStoreCACycfc"),
                       "ACPToolLib.URLSessionStore.init() -> ACPToolLib.URLSessionStore")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamCfd"),
                       "DataViewer.FileBackedReadStream.deinit")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamCfD"),
                       "DataViewer.FileBackedReadStream.__deallocating_deinit")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer21EventRecordReadStreamPyx10Foundation3URLVKcfCTj"),
                       "dispatch thunk of DataViewer.EventRecordReadStream.init(Foundation.URL) throws -> A")
    }

    func testSwiftAsyncThrowsDispatchThunkWrapper() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolP11getTestRunsyAA10OperationsO03GeteF0O6OutputOAH5InputVYaKFTj"),
            "dispatch thunk of DataViewer.APIProtocol.getTestRuns(DataViewer.Operations.GetTestRuns.Input) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
    }

    func testSwiftMachOLeadingUnderscore() {
        XCTAssertEqual(Demangler.mangledToReadable("_$s4main3FooC"), "main.Foo")
    }

    /// A leading run of consecutive BARE identifiers (no `C/V/O/P` kind letter) is not a dotted
    /// path: swift-demangle parses the last identifier before the entity name as the entity's
    /// `Module` and every earlier identifier as a leading `Identifier` context that CONCATENATES
    /// onto the module with NO separator. So `3foo3bar1f…` is `foobar.f` (the function `f` in
    /// module `bar`, prefixed by context `foo`), NOT `foo.bar.f` — a real `foo.bar.f` carries a
    /// `V` kind letter (`3foo3barV1f…`). Ground truth: `swift-demangle --compact`.
    func testSwiftLeadingIdentifierConcatenation() {
        // Function with a one-leading-context module (the canonical reproducer).
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar1fyS2iF"),
                       "foobar.f(Swift.Int) -> Swift.Int")
        // Property accessor with a one-leading-context module.
        XCTAssertEqual(Demangler.mangledToReadable("$s2ab3def4nameSSvg"),
                       "abdef.name.getter : Swift.String")
        // The kind-lettered counterparts are genuine nominal types and stay dotted (no regression).
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3barV1fyS2iF"),
                       "foo.bar.f(Swift.Int) -> Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$s2ab3defV4nameSSvg"),
                       "ab.def.name.getter : Swift.String")
        // More than one leading context concatenates left-to-right with no separators.
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar3baz1fyS2iF"),
                       "foobarbaz.f(Swift.Int) -> Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$s2ab3def3ghi4nameSSvg"),
                       "abdefghi.name.getter : Swift.String")
        // Mixed forms retain independent `Global` siblings before concatenating their renderings.
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3barV3baz1fyS2iF"),
                       "foo.barbaz.f(Swift.Int) -> Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar3bazV1fyS2iF"),
                       "foobar.baz.f(Swift.Int) -> Swift.Int")
    }

    /// Multi-argument functions (labeled, unlabeled, mixed) whose parameter/return types are all
    /// standard-library substitutions — incl. run-length `S<n><tag>` runs that span the
    /// result->argument boundary. Ground truth: `swift-demangle`.
    func testSwiftMultiArgumentFunctions() {
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3FooC3addyS2i_SitF"),
                       "main.Foo.add(Swift.Int, Swift.Int) -> Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main5HelloV5world4nameSSSS_tF"),
                       "main.Hello.world(name: Swift.String) -> Swift.String")
        XCTAssertEqual(Demangler.mangledToReadable("$s3fns1AV10twoLabeled1a1bSbSi_SStF"),
                       "fns.A.twoLabeled(a: Swift.Int, b: Swift.String) -> Swift.Bool")
        XCTAssertEqual(Demangler.mangledToReadable("$s5probe1m1a1b1cS2i_S2itF"),
                       "probe.m(a: Swift.Int, b: Swift.Int, c: Swift.Int) -> Swift.Int")
        // Mixed labeled + unlabeled (the `_` FirstElementMarker renders as `_:`).
        XCTAssertEqual(Demangler.mangledToReadable("$s3fns1AV5mixed_4withySi_SStF"),
                       "fns.A.mixed(_: Swift.Int, with: Swift.String) -> ()")
    }

    /// Labeled tuple result types compose through entity wrappers. Ground truth:
    /// `swift-demangle` over the frozen corpus symbols.
    func testSwiftLabeledTupleResultTypes() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerC10newRecords5since11forceUpdateSay018XCResultKit_ResultA9Publisher6RecordVG7records_SS6cursortSSSg_SbtF"),
            "DataViewer.Transformer.newRecords(since: Swift.String?, forceUpdate: Swift.Bool) -> (records: [XCResultKit_ResultDataPublisher.Record], cursor: Swift.String)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerC10newRecords5since11forceUpdateSay018XCResultKit_ResultA9Publisher6RecordVG7records_SS6cursortSSSg_SbtFTj"),
            "dispatch thunk of DataViewer.Transformer.newRecords(since: Swift.String?, forceUpdate: Swift.Bool) -> (records: [XCResultKit_ResultDataPublisher.Record], cursor: Swift.String)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerC10newRecords5since11forceUpdateSay018XCResultKit_ResultA9Publisher6RecordVG7records_SS6cursortSSSg_SbtFTq"),
            "method descriptor for DataViewer.Transformer.newRecords(since: Swift.String?, forceUpdate: Swift.Bool) -> (records: [XCResultKit_ResultDataPublisher.Record], cursor: Swift.String)"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11TransformerC10newRecords5since11forceUpdateSay018XCResultKit_ResultA9Publisher6RecordVG7records_SS6cursortSSSg_SbtFfA0_"),
            "default argument 1 of DataViewer.Transformer.newRecords(since: Swift.String?, forceUpdate: Swift.Bool) -> (records: [XCResultKit_ResultDataPublisher.Record], cursor: Swift.String)"
        )
    }

    /// A terminal underscore on this base identifier encodes the first `_:` argument label. Ground
    /// truth: `swift-demangle` over the frozen corpus symbol.
    func testSwiftTrailingUnderscoreFirstArgumentLabel() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewerAAC12setDirectory_12forSessionIdy10Foundation3URLV_AE4UUIDVtYaF"),
            "DataViewer.DataViewer.setDirectory(_: Foundation.URL, forSessionId: Foundation.UUID) async -> ()"
        )
    }

    /// Nominal types in a signature via the substitution dictionary: index 0 = the symbol's module;
    /// distinct nominal types land at the odd indices 3, 5, 7…; a merged run `A<letters>` is one ref
    /// per letter (lowercase continues, uppercase ends). Verified vs `swift-demangle` and a 0-wrong
    /// gate over ~27k real symbols.
    func testSwiftNominalSubstitutionsInSignature() {
        // Single occurrence (module ref, index 0).
        XCTAssertEqual(Demangler.mangledToReadable("$s5subst2a4yyAA1TVF"),
                       "subst.a4(subst.T) -> ()")
        // Back-reference to a repeated type (recorded at index 3).
        XCTAssertEqual(Demangler.mangledToReadable("$s5subst2a1yAA1TVADF"),
                       "subst.a1(subst.T) -> subst.T")
        XCTAssertEqual(Demangler.mangledToReadable("$s5subst2a2yAA1TVAD_ADtF"),
                       "subst.a2(subst.T, subst.T) -> subst.T")
        // Nested type (Outer at 3, Outer.Inner at 5) with a back-ref to the outer.
        XCTAssertEqual(Demangler.mangledToReadable("$s4nest2n2yyAA5OuterV_AD5InnerVADtF"),
                       "nest.n2(nest.Outer, nest.Outer.Inner, nest.Outer) -> ()")
        // A merged substitution run `AdfH` = indices 3, 5, 7 (T, U, W).
        XCTAssertEqual(Demangler.mangledToReadable("$s4sub31qyyAA1TV_AA1UVAA1WVAdfHtF"),
                       "sub3.q(sub3.T, sub3.U, sub3.W, sub3.T, sub3.U, sub3.W) -> ()")
    }

    /// Bound-generic STANDARD-library types and their `--compact` sugar: Array `[T]`, Dictionary
    /// `[K : V]` (spaces around the colon), Set `Swift.Set<T>` (NOT bracketed), and Optional `T?`
    /// (the `Sg` suffix, which stacks). All inputs are real compiled symbols, verified vs
    /// `swift-demangle` and a 0-wrong gate over ~27k symbols.
    func testSwiftBoundGenericStdlibTypes() {
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a1ySaySiGSiF"),
                       "gen_corpus.a1(Swift.Int) -> [Swift.Int]")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a6SaySaySiGGyF"),
                       "gen_corpus.a6() -> [[Swift.Int]]")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a3ySiSgSiF"),
                       "gen_corpus.a3(Swift.Int) -> Swift.Int?")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a7SaySiSgGyF"),
                       "gen_corpus.a7() -> [Swift.Int?]")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a8SaySiGSgyF"),
                       "gen_corpus.a8() -> [Swift.Int]?")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a4SDySSSiGyF"),
                       "gen_corpus.a4() -> [Swift.String : Swift.Int]")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a5ShySiGyF"),
                       "gen_corpus.a5() -> Swift.Set<Swift.Int>")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2a9SDySSSaySiGGyF"),
                       "gen_corpus.a9() -> [Swift.String : [Swift.Int]]")
        // Stacked Optional (`Int???`) and a Set nested in a Set.
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy7deepOptySiSgSgSgSiF"),
                       "heavy.deepOpt(Swift.Int) -> Swift.Int???")
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy9setOfSetsShyShySiGGyF"),
                       "heavy.setOfSets() -> Swift.Set<Swift.Set<Swift.Int>>")
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy9arrOfDictSaySDySSSiGGyF"),
                       "heavy.arrOfDict() -> [[Swift.String : Swift.Int]]")
    }

    /// Bound generics over a USER nominal render `Module.Name<args>` (explicit angle brackets, never
    /// sugared). Exercises the substitution-counter model: the base nominal registers BEFORE its
    /// args and the completed bound node AFTER `G`, so nested/back-referenced occurrences resolve.
    func testSwiftBoundGenericUserTypes() {
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2b1AA3BoxVySiGyF"),
                       "gen_corpus.b1() -> gen_corpus.Box<Swift.Int>")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2b2AA4PairVySiSSGyF"),
                       "gen_corpus.b2() -> gen_corpus.Pair<Swift.Int, Swift.String>")
        // Nested user generic: inner `AD` back-refs the outer Box base (registered before its args).
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2b3AA3BoxVyADySiGGyF"),
                       "gen_corpus.b3() -> gen_corpus.Box<gen_corpus.Box<Swift.Int>>")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2b4AA3BoxVySaySiGGyF"),
                       "gen_corpus.b4() -> gen_corpus.Box<[Swift.Int]>")
        // `AE` back-refs the completed `Box<Int>` node (even substitution slot).
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2b5yAA3BoxVySiGAEF"),
                       "gen_corpus.b5(gen_corpus.Box<Swift.Int>) -> gen_corpus.Box<Swift.Int>")
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy9nodeChainAA4NodeCySaySiGGSgyF"),
                       "heavy.nodeChain() -> heavy.Node<[Swift.Int]>?")
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy8wrapDictySDySSSaySiGGSgADF"),
                       "heavy.wrapDict([Swift.String : [Swift.Int]]) -> [Swift.String : [Swift.Int]]?")
    }

    /// Unconstrained (requirement-free) depth-0 generic FUNCTIONS: param refs `x`/`q_`/`q<m>_`
    /// render positionally as `A`,`B`,…, and the trailing `[r<n>_] l` signature produces the
    /// `<A, B, …>` clause spliced before the parameter list. Composes with the type sugar.
    func testSwiftDepth0GenericFunctions() {
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2c1yxxlF"),
                       "gen_corpus.c1<A>(A) -> A")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2c2yxx_q_tr0_lF"),
                       "gen_corpus.c2<A, B>(A, B) -> A")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2c4ySayxGxlF"),
                       "gen_corpus.c4<A>(A) -> [A]")
        XCTAssertEqual(Demangler.mangledToReadable("$s10gen_corpus2c5yxSgxlF"),
                       "gen_corpus.c5<A>(A) -> A?")
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy7flattenySayxGSayACGlF"),
                       "heavy.flatten<A>([[A]]) -> [A]")
        XCTAssertEqual(Demangler.mangledToReadable("$s5heavy5boxeryAA4RepoVyxGxlF"),
                       "heavy.boxer<A>(A) -> heavy.Repo<A>")
    }

    /// Run-length substitution back-reference `A<n><Letter>` = `n` copies of the indexed type
    /// (e.g. `A2C` = two of index 2), for both a stdlib bound generic and a user nominal.
    func testSwiftRunLengthSubstitutionBackRef() {
        XCTAssertEqual(Demangler.mangledToReadable("$s2rl4rep3yySaySiG_A2CtF"),
                       "rl.rep3([Swift.Int], [Swift.Int], [Swift.Int]) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s2rl3mixyyAA2C1V_A2DtF"),
                       "rl.mix(rl.C1, rl.C1, rl.C1) -> ()")
    }

    /// Generic REQUIREMENTS (`where`-clauses): conformance (`<P> R <idx>`), superclass (`Rb`),
    /// same-type (`Rs`), and layout/AnyObject (`Rl…C`), rendered `<params where r1, r2, …>` in
    /// mangle order with `:` for conformance/superclass/AnyObject and ` == ` for same-type. All
    /// inputs are real compiled symbols, oracle-verified and 0-wrong-gated.
    func testSwiftGenericRequirements() {
        // Conformance: stdlib protocol(s), one and several params.
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a1ySbx_xtSQRzlF"),
                       "rstress.a1<A where A: Swift.Equatable>(A, A) -> Swift.Bool")
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a2yyx_q_tSHRzSLR_r0_lF"),
                       "rstress.a2<A, B where A: Swift.Hashable, B: Swift.Comparable>(A, B) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2b5yyx_q_q0_tSQRzSQR_SQR0_r1_lF"),
                       "rstress.b5<A, B, C where A: Swift.Equatable, B: Swift.Equatable, C: Swift.Equatable>(A, B, C) -> ()")
        // Conformance: first-occurrence USER protocols (distinct protocols are not back-references).
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a3yyxAA8DrawableRzlF"),
                       "rstress.a3<A where A: rstress.Drawable>(A) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a4yyx_q_tAA8DrawableRzAA5NamedR_r0_lF"),
                       "rstress.a4<A, B where A: rstress.Drawable, B: rstress.Named>(A, B) -> ()")
        // Superclass `Rb` renders ':' (not '=='), plain and bound-generic-returning.
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a7yxxAA6WidgetCRbzlF"),
                       "rstress.a7<A where A: rstress.Widget>(A) -> A")
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2c2yAA4RepoVyxGxAA6WidgetCRbzlF"),
                       "rstress.c2<A where A: rstress.Widget>(A) -> rstress.Repo<A>")
        // Layout/AnyObject — bare `AnyObject`, alone and mixed with a conformance.
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a8yyxRlzClF"),
                       "rstress.a8<A where A: AnyObject>(A) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2a9yyxRlzCAA8DrawableRzlF"),
                       "rstress.a9<A where A: AnyObject, A: rstress.Drawable>(A) -> ()")
        // Same-type: concrete RHS (the run-length `S2i` straddles arg -> requirement RHS) and
        // param-to-param (canonicalized lower-index LHS).
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2b1yyS2iRszlF"),
                       "rstress.b1<A where A == Swift.Int>(Swift.Int) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress2b2yyx_xtq_Rszr0_lF"),
                       "rstress.b2<A, B where A == B>(A, A) -> ()")
        // Mixed conformance + a concrete trailing parameter.
        XCTAssertEqual(Demangler.mangledToReadable("$s7rstress3mixyyx_q_SitSQRzSHR_r0_lF"),
                       "rstress.mix<A, B where A: Swift.Equatable, B: Swift.Hashable>(A, B, Swift.Int) -> ()")
        // Substitution index 0 in a conformance operand resolves to the TRUE module, even when the
        // entity name uses leading-identifier concatenation (display module 'f3' != real module 'x').
        XCTAssertEqual(Demangler.mangledToReadable("$s1x2f32f3yyxAA7MyProtoRzlF"),
                       "xf3.f3<A where A: x.MyProto>(A) -> ()")
    }

    /// Associated-type / dependent-member requirements and types. A dependent member `<assoc>Q<base>`
    /// renders `<A|B|…>.<assoc>` (base encoding `z`/`y_`/`y<n>_` = 0/1/n+2), composes with `Sg`/bound
    /// generics, and registers in the substitution dictionary (assoc-ref then member) so reused
    /// occurrences resolve as back-references. Requirement kinds: `Rp` associated-conformance
    /// (`A.Element: P`) and `Rt` associated-same-type (`A.Element == T`, T concrete or another
    /// dependent member). All inputs are compiled-probe symbols, oracle-verified and 0-wrong-gated.
    func testSwiftAssociatedTypeRequirements() {
        // Dependent-member RETURN type, with `Sg` Optional, base param 0 (`Qz`).
        XCTAssertEqual(Demangler.mangledToReadable("$s3req2e1y7ElementQzSgxSTRzlF"),
                       "req.e1<A where A: Swift.Sequence>(A) -> A.Element?")
        // Base param 1 (`Qy_`) and a distinct associated-type name.
        XCTAssertEqual(Demangler.mangledToReadable("$s2at2r2y7ElementQy_x_q_tSTR_r0_lF"),
                       "at.r2<A, B where B: Swift.Sequence>(A, B) -> B.Element")
        XCTAssertEqual(Demangler.mangledToReadable("$s2at2r5y11SubSequenceQzxSlRzlF"),
                       "at.r5<A where A: Swift.Collection>(A) -> A.SubSequence")
        // Dependent member inside a bound generic, and a back-reference (`AD`) to a repeat occurrence.
        XCTAssertEqual(Demangler.mangledToReadable("$s2at3r10ySay7ElementQzGxSTRzlF"),
                       "at.r10<A where A: Swift.Sequence>(A) -> [A.Element]")
        XCTAssertEqual(Demangler.mangledToReadable("$s3ats2d1yyx_7ElementQzADtSTRzlF"),
                       "ats.d1<A where A: Swift.Sequence>(A, A.Element, A.Element) -> ()")
        // `Rt` associated same-type: concrete RHS, and param-to-param (`AC` reuses the assoc-ref).
        XCTAssertEqual(Demangler.mangledToReadable("$s3req2e2ySixSlRzSi7ElementRtzlF"),
                       "req.e2<A where A: Swift.Collection, A.Element == Swift.Int>(A) -> Swift.Int")
        XCTAssertEqual(Demangler.mangledToReadable("$s2at2r7yyx_q_tSTRzSTR_7ElementQy_ACRtzr0_lF"),
                       "at.r7<A, B where A: Swift.Sequence, B: Swift.Sequence, A.Element == B.Element>(A, B) -> ()")
        // `Rp` associated conformance: stdlib protocol and user protocol.
        XCTAssertEqual(Demangler.mangledToReadable("$s2at2r9yyxSTRzSQ7ElementRpzlF"),
                       "at.r9<A where A: Swift.Sequence, A.Element: Swift.Equatable>(A) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s2at2r8yyxSlRzAA2Q17ElementRpzlF"),
                       "at.r8<A where A: Swift.Collection, A.Element: at.Q1>(A) -> ()")
    }

    /// Reused user-protocol substitutions retain the complete where-clause. Malformed run-length
    /// and greedy-operand shapes rejected by swift-demangle still return nil.
    func testSwiftRejectsUnsupportedRequirements() {
        // <A, B where A: clean.P, B: clean.P>  — the second P is a reused-protocol back-ref `AaC`.
        XCTAssertEqual(Demangler.mangledToReadable("$s5clean5conf2yyx_q_tAA1PRzAaCR_r0_lF"),
                       "clean.conf2<A, B where A: clean.P, B: clean.P>(A, B) -> ()")
        // Adversarial: a run-length `S2i` must not OVER-DRAIN into multiple phantom same-type
        // requirements with zero arguments (the straddle is at most one element). swift-demangle
        // rejects this; the demangler must too.
        XCTAssertNil(Demangler.mangledToReadable("$s1x2f5yyS2iRszRszlF"))
        // Adversarial: a same-type/superclass operand whose length-prefixed identifier would swallow
        // the requirement's own `R`/kind bytes (a greedy multi-level protocol read) — must be nil.
        XCTAssertNil(Demangler.mangledToReadable("$s1x2m2yyx_q_SitAA4Base5RbzSHR_SiRs0_r1_lF"))
    }

    /// Regression coverage for the adversarial-review findings (the run-length / merged-substitution
    /// buffer-drain family). These are buffer-state bugs an earlier corpus under-sampled; all inputs
    /// are oracle-verified, and the nil cases are inputs swift-demangle itself rejects.
    func testSwiftRunLengthBufferDrainRegressions() {
        // A run-length std type as the LAST tuple element must fully drain (was dropping the tail).
        XCTAssertEqual(Demangler.mangledToReadable("$s3run4rfn3yySi_S2itF"),
                       "run.rfn3(Swift.Int, Swift.Int, Swift.Int) -> ()")
        // Run-length inside a BOUND-GENERIC arg list (`Pair<Int,Int>` mangles its args as `S2i`).
        XCTAssertEqual(Demangler.mangledToReadable("$s5g5min2h1yyAA4PairVyS2iGF"),
                       "g5min.h1(g5min.Pair<Swift.Int, Swift.Int>) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s6g5min22k2yyAA4TripVyS3iGF"),
                       "g5min2.k2(g5min2.Trip<Swift.Int, Swift.Int, Swift.Int>) -> ()")
        // Zero parameters: a trailing empty-tuple `y` is `()`, not a phantom `(())` argument.
        XCTAssertEqual(Demangler.mangledToReadable("$s4gens5f0genyxSgylF"),
                       "gens.f0gen<A>() -> A?")
        XCTAssertEqual(Demangler.mangledToReadable("$s4gens2f1yyylF"),
                       "gens.f1<A>() -> ()")
        // An over-long run (`S3i` in a 2-slot signature) is invalid — swift-demangle rejects it, so
        // a leftover run count must force nil, never a silently-truncated demangling.
        XCTAssertNil(Demangler.mangledToReadable("$s1x1CC1myS3iF"))
        // A merged substitution run is not valid as bound-generic arguments — must be nil.
        XCTAssertNil(Demangler.mangledToReadable("$s1x2f5_1rAA3BoxVySSGShyA2ASiG_SnySiGtF"))
        // A pathological run-length count must return nil promptly (no unbounded expansion / hang).
        XCTAssertNil(Demangler.mangledToReadable("$s4gens4fmixyyx_S999999999i_tlF"))
    }

    /// Each NAMED argument label occupies a substitution slot, so a type back-reference in a LABELED
    /// function is shifted by the label count — without accounting for that the back-refs resolve
    /// off-by-N (a wrong type, or nil). The label slot itself holds no type, so a back-reference that
    /// lands on it stays nil (never a label-as-type guess). Oracle: swift-demangle.
    func testSwiftLabeledFunctionSubstitutionShift() {
        // Labeled function, back-ref `AG` to a user bound generic (Box<A>) past the labels.
        XCTAssertEqual(Demangler.mangledToReadable("$s2ut2e13box5otherAA3BoxVyxGAG_AGtlF"),
                       "ut.e1<A>(box: ut.Box<A>, other: ut.Box<A>) -> ut.Box<A>")
        // Labeled function, back-ref `AE` to a stdlib bound generic ([A]).
        XCTAssertEqual(Demangler.mangledToReadable("$s2ut2e35first6secondySayxG_AEtlF"),
                       "ut.e3<A>(first: [A], second: [A]) -> ()")
        // Two labels + a Dictionary-of-Array return whose inner [B] is back-referenced as the args.
        XCTAssertEqual(Demangler.mangledToReadable("$s4lbl21k1a1bSDyxSayq_GGAE_AEtSHRzr0_lF"),
                       "lbl2.k<A, B where A: Swift.Hashable>(a: [B], b: [B]) -> [A : [B]]")
    }

    /// A METHOD's enclosing ("self") type registers in the substitution table BEFORE the argument
    /// labels and the parameter/result types, so a method whose argument or result back-references
    /// the self type resolves it. Empirically (`swift-demangle --expand` + back-ref index mutation):
    /// each enclosing nominal LEVEL stores at an even index and advances the counter by two —
    /// single-level `Foo@2`, nested `Outer@2` + `Outer.Inner@4`, generic registers the UNBOUND
    /// nominal (`Box@2`, the `<A>` applied at the use site). Free functions have no enclosing type
    /// and are unaffected. All expected values are oracle-verified (`swift-demangle --compact`) and
    /// 0-wrong-gated; a self type we cannot reproduce stays nil, never a wrong guess.
    func testSwiftMethodSelfTypeSubstitution() {
        // The task reproducers (compiled / stdlib symbols).
        XCTAssertEqual(Demangler.mangledToReadable("$s12CoreGraphics7CGFloatV6isLess4thanSbAC_tF"),
                       "CoreGraphics.CGFloat.isLess(than: CoreGraphics.CGFloat) -> Swift.Bool")
        XCTAssertEqual(Demangler.mangledToReadable("$s12CoreGraphics7CGFloatV8advanced2byA2C_tF"),
                       "CoreGraphics.CGFloat.advanced(by: CoreGraphics.CGFloat) -> CoreGraphics.CGFloat")
        XCTAssertEqual(Demangler.mangledToReadable("$s4self3FooV2m1yyACF"),
                       "self.Foo.m1(self.Foo) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s4self3FooV2m41p1qyAC_ACtF"),
                       "self.Foo.m4(p: self.Foo, q: self.Foo) -> ()")
        // Nested type: both enclosing levels register — `Outer@2`, `Outer.Inner@4`.
        XCTAssertEqual(Demangler.mangledToReadable("$s3cal5OuterV5InnerV2miyyAEF"),
                       "cal.Outer.Inner.mi(cal.Outer.Inner) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s3cal5OuterV5InnerV2moyyACF"),
                       "cal.Outer.Inner.mo(cal.Outer) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s3cal5OuterV5InnerV4both1i1oyAE_ACtF"),
                       "cal.Outer.Inner.both(i: cal.Outer.Inner, o: cal.Outer) -> ()")
        // Generic type: the UNBOUND `cal.Box` registers at 2; the `<A>` binding is applied per use.
        XCTAssertEqual(Demangler.mangledToReadable("$s3cal3BoxV2mbyyACyxGF"),
                       "cal.Box.mb(cal.Box<A>) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s3cal3BoxV3retACyxGyF"),
                       "cal.Box.ret() -> cal.Box<A>")
        // A fresh post-self nominal lands past the self slots: `Host@2`(ctr→4) → first `A1`
        // registerNominal@5, so the second `A1` back-references `AF`(5).
        XCTAssertEqual(Demangler.mangledToReadable("$s2ix4HostV8twoOtheryyAA2A1V_AFtF"),
                       "ix.Host.twoOther(ix.A1, ix.A1) -> ()")
        // Labels register AFTER the self type: `Host@2`(ctr→4) + 2 labels (ctr→6) → `A1`@7 (`AH`).
        XCTAssertEqual(Demangler.mangledToReadable("$s2ix4HostV6lblTwo1a1byAA2A1V_AHtF"),
                       "ix.Host.lblTwo(a: ix.A1, b: ix.A1) -> ()")
        // NON-REGRESSION: a free function has no enclosing type — labels still register at 2,3 and
        // the first nominal at 5 (`AF`), exactly as before the self-type change.
        XCTAssertEqual(Demangler.mangledToReadable("$s3cal5free21p1qyAA5PlainV_AFtF"),
                       "cal.free2(p: cal.Plain, q: cal.Plain) -> ()")
    }

    /// DEPTH-≥1 generic params (`qd<depthSpec><idxSpec>`) — a generic method of a generic type. The
    /// body renders an outer-context param with a depth SUFFIX (`A1` at depth 1, `A2` at depth 2)
    /// while the deepest (method's own) params render `A`,`B`,… and the `<…>` clause lists them by
    /// index with no suffix — so the same param can read `A` in the clause but `A1` in the body.
    /// All inputs are compiled-probe symbols, oracle-verified and 0-wrong-gated.
    func testSwiftGenericDepth() {
        // The canonical case: method param (depth1 `qd__`) + enclosing type param (depth0 `x`).
        XCTAssertEqual(Demangler.mangledToReadable("$s9gen_probe5OuterV5inneryqd__x_qd__tlF"),
                       "gen_probe.Outer.inner<A>(A, A1) -> A1")
        // Method param only.
        XCTAssertEqual(Demangler.mangledToReadable("$s5depth5OuterV2m2yqd__qd__lF"),
                       "depth.Outer.m2<A>(A1) -> A1")
        // Two method params (depth1 idx0,1 → A1, B1) alongside the type param.
        XCTAssertEqual(Demangler.mangledToReadable("$s5depth5OuterV2m4yyqd___qd_0_xtr0_lF"),
                       "depth.Outer.m4<A, B>(A1, B1, A) -> ()")
        // Three method params (depth1 idx0,1,2 → A1, B1, C1).
        XCTAssertEqual(Demangler.mangledToReadable("$s6depth25OuterV4manyyyqd___qd_0_qd_1_xtr1_lF"),
                       "depth2.Outer.many<A, B, C>(A1, B1, C1, A) -> ()")
        // Two enclosing type params (B = depth0 idx1).
        XCTAssertEqual(Demangler.mangledToReadable("$s5depth4PairV3selyqd__qd___xq_tlF"),
                       "depth.Pair.sel<A>(A1, A, B) -> A1")
        // DEPTH 2: a method of a generic type nested in a generic type (`qd0__` → A2).
        XCTAssertEqual(Demangler.mangledToReadable("$s6depth25OuterV5InnerV4deepyyqd0___qd__xtlF"),
                       "depth2.Outer.Inner.deep<A>(A2, A1, A) -> ()")
    }

    /// CHAINED dependent-member types (the `QZ`/`QY_`/`QY<n>_` form, ≥2 associated-type names). The
    /// name list mangles `<name0>_<name1>…<nameK>` (only the FIRST name is `_`-separated, the rest are
    /// concatenated); the base-param marker is the UPPERCASE counterpart of the single form (`Z`/`Y`
    /// vs `z`/`y`), `Z`→param0, `Y_`→param1, `Y<n>_`→param n+2. Each name registers in stream order,
    /// then the completed chained member registers (a later `A…` back-ref resolves to it); intermediate
    /// levels do NOT register. All inputs are compiled-probe symbols, oracle-verified and 0-wrong-gated.
    func testSwiftChainedDependentMembers() {
        // 2-level `A.Inner.Item` (was the prior nil case) and a longer/param-varying set.
        XCTAssertEqual(Demangler.mangledToReadable("$s3ml28twolevely5Inner_4ItemQZxAA7WrapperRzlF"),
                       "ml2.twolevel<A where A: ml2.Wrapper>(A) -> A.Inner.Item")
        // 2-level `A.Mid.Leaf` and 3-level `A.Mid.Leaf.Tip` (base param 0, `QZ`).
        XCTAssertEqual(Demangler.mangledToReadable("$s2dp2d2y3Mid_4LeafQZSgxAA2L1RzlF"),
                       "dp.d2<A where A: dp.L1>(A) -> A.Mid.Leaf?")
        XCTAssertEqual(Demangler.mangledToReadable("$s2dp2d1y3Mid_4Leaf3TipQZSgxAA2L1RzlF"),
                       "dp.d1<A where A: dp.L1>(A) -> A.Mid.Leaf.Tip?")
        // 4-level (confirms only the first name carries `_`): `A.N2.N3.N4.N5`.
        XCTAssertEqual(Demangler.mangledToReadable("$s1k2q1y2N2_2N32N42N5QZSgxAA2K1RzlF"),
                       "k.q1<A where A: k.K1>(A) -> A.N2.N3.N4.N5?")
        // Chained on NON-first param: `B.Element.Stride` (`QY_`) and `C.Element.Stride` (`QY0_`).
        XCTAssertEqual(Demangler.mangledToReadable("$s2ch2g2y7Element_6StrideQY_Sgx_q_tSTRzSTR_SxACRp_r0_lF"),
                       "ch.g2<A, B where A: Swift.Sequence, B: Swift.Sequence, B.Element: Swift.Strideable>(A, B) -> B.Element.Stride?")
        XCTAssertEqual(Demangler.mangledToReadable("$s2c22h1y7Element_6StrideQY0_Sgx_q_q0_tSTRzSTR_STR0_SxACRp0_r1_lF"),
                       "c2.h1<A, B, C where A: Swift.Sequence, B: Swift.Sequence, C: Swift.Sequence, C.Element: Swift.Strideable>(A, B, C) -> C.Element.Stride?")
        // Back-reference INTERACTIONS: the chained member reused (`AE`); a chain whose first assoc-name
        // is itself a back-ref (`AC_4LeafQZ` after an earlier `3MidQz` registered `Mid`); a chain
        // followed by single members reusing a name registered DURING the chain (`AC`/`AD`).
        XCTAssertEqual(Demangler.mangledToReadable("$s2cm2m1yyx_3Mid_4LeafQZAEtAA2R1RzlF"),
                       "cm.m1<A where A: cm.R1>(A, A.Mid.Leaf, A.Mid.Leaf) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s3iso2j2yyx_3MidQzAC_4LeafQZtAA2O1RzlF"),
                       "iso.j2<A where A: iso.O1>(A, A.Mid, A.Mid.Leaf) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s2cn2m2yyx_3Mid_4LeafQZACQztAA2R3RzlF"),
                       "cn.m2<A where A: cn.R3>(A, A.Mid.Leaf, A.Mid) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s2lf2n1yyx_3Mid_4LeafQZADQztAA2S1RzlF"),
                       "lf.n1<A where A: lf.S1>(A, A.Mid.Leaf, A.Leaf) -> ()")
        // A merged substitution run preserves the member and the following chain's base name.
        XCTAssertEqual(Demangler.mangledToReadable("$s2ix2i1yyx_3MidQzAdC_4LeafQZtAA2N1RzlF"),
                       "ix.i1<A where A: ix.N1>(A, A.Mid, A.Mid, A.Mid.Leaf) -> ()")
    }

    /// Function/closure TYPES (`c` escaping, `XE` @noescape) render `(<args>) -> <result>` and
    /// compose with currying, tuples, Optionals (parenthesized), arrays, and nesting. Verified vs
    /// `swift-demangle --compact` (compiled-probe corpus, 0-wrong-gated incl. libswiftCore identical).
    func testSwiftClosures() {
        // The canonical reproducer (was the `testSwiftRejectsUncoveredForms` nil case).
        XCTAssertEqual(Demangler.mangledToReadable("$s3app11makeClosureSSSicyF"),
                       "app.makeClosure() -> (Swift.Int) -> Swift.String")
        // Closure as a return, multi-arg, and curried (`(A) -> (B) -> C`).
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c2SbSi_SStcyF"),
                       "clo.c2() -> (Swift.Int, Swift.String) -> Swift.Bool")
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c5SbSScSicyF"),
                       "clo.c5() -> (Swift.Int) -> (Swift.String) -> Swift.Bool")
        // Non-escaping closure PARAM (`XE`) — the single-arg form whose leading `y` is its Void
        // result — and an escaping one (`c`).
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c3yyySiXEF"),
                       "clo.c3((Swift.Int) -> ()) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c4yySSSicF"),
                       "clo.c4((Swift.Int) -> Swift.String) -> ()")
        // Two closure params, optional-of-closure (parenthesized), and array-of-closures.
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c6yySiyXE_ySSXEtF"),
                       "clo.c6(() -> Swift.Int, (Swift.String) -> ()) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c7ySicSgyF"),
                       "clo.c7() -> ((Swift.Int) -> ())?")
        XCTAssertEqual(Demangler.mangledToReadable("$s3clo2c9SaySSSicGyF"),
                       "clo.c9() -> [(Swift.Int) -> Swift.String]")
    }

    func testSwiftClosureEntitiesAndPartialApplyForwarders() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib11AuthOptionsV8validateyyKFSSSgyKXEfU_"),
            "closure #1 () throws -> Swift.String? in ACPToolLib.AuthOptions.validate() throws -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib15URLSessionStoreC10addSession_2idySo12NSURLSessionC_SStFyyXEfU_TA"),
            "partial apply forwarder for closure #1 () -> () in ACPToolLib.URLSessionStore.addSession(_: __C.NSURLSession, id: Swift.String) -> ()"
        )
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib17APIRequestBuilderC7executeyySo17OS_dispatch_queueC_ys6ResultOy9ACPAPIKit8ResponseCyxGs5Error_pGctFyyYbcfU0_"),
            "closure #2 @Sendable () -> () in ACPToolLib.APIRequestBuilder.execute(__C.OS_dispatch_queue, (Swift.Result<ACPAPIKit.Response<A>, Swift.Error>) -> ()) -> ()"
        )
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10ACPToolLib17APIRequestBuilderC7executeyySo17OS_dispatch_queueC_ys6ResultOy9ACPAPIKit8ResponseCyxGs5Error_pGctFyyYbcfU0_TA"),
            "partial apply forwarder for closure #2 @Sendable () -> () in ACPToolLib.APIRequestBuilder.execute(__C.OS_dispatch_queue, (Swift.Result<ACPAPIKit.Response<A>, Swift.Error>) -> ()) -> ()"
        )
    }

    /// When a result and an argument share a base type, Swift coalesces both into ONE run (`A2C` /
    /// `S2i`) and a trailing `Sg` follows the run's bytes — it binds to the run's LAST copy (the
    /// argument), NOT the first-emitted copy (the result). Earlier this swapped which operand was
    /// optional. Oracle: swift-demangle.
    func testSwiftTrailingOptionalOnRunTail() {
        XCTAssertEqual(Demangler.mangledToReadable("$s7corpus22C2C6optArgyA2CSgF"),
                       "corpus2.C2.optArg(corpus2.C2?) -> corpus2.C2")
        XCTAssertEqual(Demangler.mangledToReadable("$s7corpus22C2C6dblOptyA2CSgSgF"),
                       "corpus2.C2.dblOpt(corpus2.C2??) -> corpus2.C2")
        XCTAssertEqual(Demangler.mangledToReadable("$s7corpus22C2C6twoOptyA2CSg_AEtF"),
                       "corpus2.C2.twoOpt(corpus2.C2?, corpus2.C2?) -> corpus2.C2")
        // Same defect via a run-length leaf straddling into a same-type requirement RHS.
        XCTAssertEqual(Demangler.mangledToReadable("$s1c2h2yS2iSgACRszlF"),
                       "c.h2<A where A == Swift.Int?>(Swift.Int?) -> Swift.Int")
        // A same-typed curried function feeds the run into the innermost function.
        XCTAssertEqual(Demangler.mangledToReadable("$s2cn7curriedyyS2icSiXEF"),
                       "cn.curried((Swift.Int) -> (Swift.Int) -> Swift.Int) -> ()")
        // Typed function nodes preserve nested higher-order shape for repeated and distinct types.
        XCTAssertEqual(Demangler.mangledToReadable("$s2cn6nestedyyS3iXEXEF"),
                       "cn.nested(((Swift.Int) -> Swift.Int) -> Swift.Int) -> ()")
        XCTAssertEqual(Demangler.mangledToReadable("$s2cn7nestStryySiSbSSXEXEF"),
                       "cn.nestStr(((Swift.String) -> Swift.Bool) -> Swift.Int) -> ()")
    }

    func testSwiftDefaultArgumentWrappers() {
        // Ground truth: swift-demangle.
        XCTAssertEqual(
            Demangler.mangledToReadable("_$s10DataViewer11APIProtocolPAAE11getTestRuns5query7headersAA10OperationsO03GeteF0O6OutputOAJ5InputV5QueryV_AN7HeadersVtYaKFfA0_"),
            "default argument 1 of (extension in DataViewer):DataViewer.APIProtocol.getTestRuns(query: DataViewer.Operations.GetTestRuns.Input.Query, headers: DataViewer.Operations.GetTestRuns.Input.Headers) async throws -> DataViewer.Operations.GetTestRuns.Output"
        )
    }

    func testSwiftRejectsUncoveredForms() {
        // Both throwing and C-convention closures retain their exact function attributes.
        XCTAssertEqual(Demangler.mangledToReadable("$s4clo22t1SSSiKcyF"),
                       "clo2.t1() -> (Swift.Int) throws -> Swift.String")
        XCTAssertEqual(Demangler.mangledToReadable("$s4clo22t3yyySiXCF"),
                       "clo2.t3(@convention(c) (Swift.Int) -> ()) -> ()")
        // Garbage.
        XCTAssertNil(Demangler.mangledToReadable("$s"))
        XCTAssertNil(Demangler.mangledToReadable("$sZZZ"))
    }

    /// `parseEntity` over-acceptance cluster (an adversarial review confirmed these as wrong-output
    /// vs `swift-demangle --compact`). Each is a structurally-impossible symbol a real compiler never
    /// emits but a hostile binary could carry; per correctness-over-coverage the demangler must match
    /// the oracle byte-for-byte or return nil — never a wrong dotted/partial guess.

    /// #1 — A nominal-kind (`C/V/O/P`)-terminated path of bare un-kinded leading identifiers must
    /// apply the SAME leading-identifier concatenation as the function path (commit 536d4bae1): the
    /// identifier before the entity name is its `Module` and earlier ones concatenate onto it with NO
    /// separator. `$s3foo3bar1fP` is `foobar.f` (module `bar`, leading context `foo`), NOT the dotted
    /// `foo.bar.f`. `--expand` shows a leading `Identifier "foo"` sibling of a `Protocol` whose
    /// `Module` is `bar`. (Previously rendered the wrong `foo.bar.f`.)
    func testSwiftLeadingIdentifierConcatenationOnNominalKindTerminal() {
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar1fP"), "foobar.f")
        // The same concatenation holds for every nominal kind letter on the terminal name.
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar1fC"), "foobar.f")
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar1fV"), "foobar.f")
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar1fO"), "foobar.f")
        // Two leading contexts concatenate left-to-right.
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3bar3baz1fP"), "foobarbaz.f")
        // Single-leading is just the module (no concatenation) and stays dotted.
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo1fP"), "foo.f")
        // A kinded middle is a genuine nested type and stays a clean dotted chain (no regression).
        XCTAssertEqual(Demangler.mangledToReadable("$s3foo3barV1fP"), "foo.bar.f")
    }

    /// #2 — A `C/V/O` nominal-kind letter applied directly to the bare MODULE identifier
    /// (`path.count == 1` at the kind) is a method on the "module-as-type", which the compiler never
    /// emits. `$s1zC5plainyS2iF` (`z.plain(Int) -> Int`) must be nil, not a wrong demangling.
    func testSwiftRejectsNominalKindOnBareModule() {
        XCTAssertNil(Demangler.mangledToReadable("$s1zC5plainyS2iF"))
        XCTAssertNil(Demangler.mangledToReadable("$s1zV5plainyS2iF"))
        // Even with no function tail, a kind on a single-identifier path is invalid.
        XCTAssertNil(Demangler.mangledToReadable("$s4mainC"))
    }

    /// #3 — A free generic-function tail attaching directly to a `C/V/O/P`-kinded NAME silently DROPS
    /// the kind. A real method comes after a further member name, not the kind itself, so a type-kinded
    /// name cannot carry a free function signature. `$s1x2f1OyyxlF` (`x.f1<A>(A) -> ()`) must be nil.
    func testSwiftRejectsFunctionTailOnNominalKindName() {
        XCTAssertNil(Demangler.mangledToReadable("$s1x2f1OyyxlF"))
        // The where-clause-bearing variant likewise.
        XCTAssertNil(Demangler.mangledToReadable("$s1x2f1OyyxSQRzlF"))
    }

    /// #4 — A function tail on a MODULE-ONLY path (`path.count == 1`, no entity name) is invalid: a
    /// valid function needs at least `<module><name>`. `$s2f5yyxlF` (`f5<A>(A) -> ()`) must be nil.
    func testSwiftRejectsFunctionTailOnModuleOnlyPath() {
        XCTAssertNil(Demangler.mangledToReadable("$s2f5yyxlF"))
        // The where-clause-bearing variant likewise.
        XCTAssertNil(Demangler.mangledToReadable("$s2f5yyxRlzClF"))
    }

    // MARK: - Front door

    func testNonMangledNamesReturnNil() {
        XCTAssertNil(Demangler.mangledToReadable("main"))
        XCTAssertNil(Demangler.mangledToReadable("_main"))
        XCTAssertNil(Demangler.mangledToReadable("sub_100003f00"))
        XCTAssertNil(Demangler.mangledToReadable(""))
    }

    func testDisplayNameFallsBackToRaw() {
        XCTAssertEqual(Demangler.displayName(for: "main"), "main")
        XCTAssertEqual(Demangler.displayName(for: "_Z3fooi"), "foo(int)")
        // An unsupported mangled form falls back to the raw mangled string.
        XCTAssertEqual(Demangler.displayName(for: "_Z1fIiEvT_"), "_Z1fIiEvT_")
    }

    // MARK: - Adversarial-review regression fixes

    /// Fix 1: `St` followed by an <unqualified-name> must scope INTO `std`, not
    /// return the bare substitution as a complete name. Previously
    /// `_ZSt9terminatev` demangled to a bogus "std(terminate, void)".
    /// Ground truth: `c++filt`.
    func testItaniumStdScopedUnqualifiedName() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZSt9terminatev"),
                       "std::terminate()")
        XCTAssertEqual(Demangler.mangledToReadable("_ZSt19__throw_logic_errorPKc"),
                       "std::__throw_logic_error(char const*)")
    }

    /// Fix 2: a nested templated TERMINAL component carries a return type in its
    /// bare-function-type; it must be consumed and rendered as a prefix, not
    /// emitted as a phantom parameter. Previously `_ZN3foo3barIiEEvv` rendered
    /// "foo::bar<int>(void, void)". Ground truth: `c++filt`.
    func testItaniumTemplatedTerminalReturnType() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barIiEEvv"),
                       "void foo::bar<int>()")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barIiEEiv"),
                       "int foo::bar<int>()")
        // A non-templated terminal must still drop no return type and render its
        // single argument correctly (guards against over-eager consumption).
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barEi"),
                       "foo::bar(int)")
    }

    /// Fix 4: the substitution table is positional; removing the adjacent-
    /// duplicate dedup must keep every prefix in its own slot so back-references
    /// resolve correctly. `_Z1fPiPiPlS0_` -> the S0_ back-ref is `int*` (the 2nd
    /// substitution slot), giving a trailing `int*`. Ground truth: `c++filt`.
    func testItaniumPositionalSubstitutionTable() {
        XCTAssertEqual(Demangler.mangledToReadable("_Z1fPiPiPlS0_"),
                       "f(int*, int*, long*, int*)")
    }

    /// Fix 3: adversarial deep nesting and pathologically long names must NEVER
    /// crash (stack overflow); the parser returns nil past its depth/length
    /// bounds and the caller falls back to the raw name.
    func testItaniumDeepNestingDoesNotCrash() {
        // `_Z3foo` + 7000 pointers + `i`: would overflow the stack without a
        // recursion bound. Must return nil (uncovered/too deep), not crash.
        let hostile = "_Z3foo" + String(repeating: "P", count: 7000) + "i"
        XCTAssertNil(Demangler.mangledToReadable(hostile))
        // Falls back to the raw string via the display path without crashing.
        XCTAssertEqual(Demangler.displayName(for: hostile), hostile)
    }

    func testItaniumOverlongInputRejected() {
        // A name longer than the hard cap is rejected outright.
        let overlong = "_Z" + String(repeating: "a", count: 20000)
        XCTAssertNil(Demangler.mangledToReadable(overlong))
        XCTAssertEqual(Demangler.displayName(for: overlong), overlong)
    }

    func testSwiftOverlongInputRejected() {
        // HS-8: an over-budget Swift symbol renders as the explicit marker, never as
        // raw mangled text or a partial demangling (see MetadataRobustnessTests).
        let overlong = "$s" + String(repeating: "0", count: 20000)
        XCTAssertEqual(Demangler.mangledToReadable(overlong), SwiftDemangler.tooComplexMarker)
        XCTAssertEqual(Demangler.displayName(for: overlong), SwiftDemangler.tooComplexMarker)
    }

    // MARK: - Second-round adversarial-review regressions

    /// Fix A: a ctor/dtor of a TEMPLATED class must name the class itself, not
    /// the innermost template-argument (the `::` inside `char_traits<char>` must
    /// not be mistaken for the scope separator).
    func testItaniumDtorOfTemplatedClassNamesTheClass() {
        XCTAssertEqual(
            Demangler.mangledToReadable("_ZNSt3__113basic_ostreamIcNS_11char_traitsIcEEED2Ev"),
            "std::__1::basic_ostream<char, std::__1::char_traits<char>>::~basic_ostream()")
        XCTAssertEqual(
            Demangler.mangledToReadable("_ZNSt3__16vectorIiNS_9allocatorIiEEED2Ev"),
            "std::__1::vector<int, std::__1::allocator<int>>::~vector()")
    }

    /// Fix B: a standard substitution used as a TYPE/parameter scopes into std::
    /// — it is one type (`std::align_val_t`), not `std` plus a phantom parameter.
    /// These global `operator new`/`operator delete` symbols are extremely common.
    func testItaniumStandardSubstitutionAsParameterScopesIntoStd() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZdlPvSt11align_val_t"),
                       "operator delete(void*, std::align_val_t)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZnwmRKSt9nothrow_t"),
                       "operator new(unsigned long, std::nothrow_t const&)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZnwmSt11align_val_tRKSt9nothrow_t"),
                       "operator new(unsigned long, std::align_val_t, std::nothrow_t const&)")
        XCTAssertEqual(Demangler.mangledToReadable("_ZSt17rethrow_exceptionSt13exception_ptr"),
                       "std::rethrow_exception(std::exception_ptr)")
    }

    /// Fix C: a templated CONSTRUCTOR/DESTRUCTOR has no return type even though
    /// its terminal carries template args — the leading `v` is the (void)
    /// parameter list, not a `void` return prefix. Contrast with a templated
    /// free function, which DOES lead with a return type.
    func testItaniumTemplatedCtorHasNoReturnTypePrefix() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3FooC1IiEEv"), "Foo::Foo<int>()")
        // Contrast: a templated free/member function still renders its return type.
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barIiEEvv"), "void foo::bar<int>()")
    }

    /// Regression for the over-broad type-position scoping introduced by fix B:
    /// `m` is `unsigned long`, so `mm` after a (back-ref) substitution is TWO
    /// parameters, NOT `operator--`. Only the literal `St` namespace + a
    /// source-name scopes in type position; a back-reference never does.
    func testItaniumSubstitutionFollowedByUnsignedLongParamsNotOperator() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN1A1fERS_mm"),
                       "A::f(A&, unsigned long, unsigned long)")
        XCTAssertEqual(
            Demangler.mangledToReadable(
                "_ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendERKS5_mm"),
            "std::__1::basic_string<char, std::__1::char_traits<char>, std::__1::allocator<char>>"
                + "::append(std::__1::basic_string<char, std::__1::char_traits<char>, "
                + "std::__1::allocator<char>> const&, unsigned long, unsigned long)")
    }

    /// Fix (cosmetic): non-int integer template literals carry their C++ type
    /// suffix, matching c++filt (`4096ul`/`1l`, not `4096`/`1`); plain `int`
    /// stays unsuffixed.
    func testItaniumTemplateLiteralTypeSuffix() {
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barILm4096EEEvv"), "void foo::bar<4096ul>()")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barILl1ELl1000EEEvv"), "void foo::bar<1l, 1000l>()")
        XCTAssertEqual(Demangler.mangledToReadable("_ZN3foo3barILi5EEEvv"), "void foo::bar<5>()")
    }

    /// Swift demangler corpus (2026-10-13): `fD` is `__deallocating_deinit` only for a class; a
    /// noncopyable struct or enum prints its plain `deinit` (Swift 6.2 swift-demangle, NodePrinter).
    func testDeallocatorIsDeallocatingDeinitOnlyForClasses() {
        XCTAssertEqual(Demangler.mangledToReadable("$s14OracleFeatures5TokenVfD"), "OracleFeatures.Token.deinit")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main4KindOfD"), "main.Kind.deinit")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main5OuterV5InnerVfD"), "main.Outer.Inner.deinit")
        XCTAssertEqual(Demangler.mangledToReadable("$s13OracleClasses6Child0CfD"), "OracleClasses.Child0.__deallocating_deinit")
        XCTAssertEqual(Demangler.mangledToReadable("$s14OracleFeatures9WorkActorCfD"), "OracleFeatures.WorkActor.__deallocating_deinit")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main6StructV5InnerCfD"), "main.Struct.Inner.__deallocating_deinit")
        // Wrappers: the Mach-O underscore and an unmangled suffix keep the kind.
        XCTAssertEqual(Demangler.mangledToReadable("_$s14OracleFeatures5TokenVfD"), "OracleFeatures.Token.deinit")
        XCTAssertEqual(Demangler.mangledToReadable("_$s10DataViewer20FileBackedReadStreamCfD"),
                       "DataViewer.FileBackedReadStream.__deallocating_deinit")
        XCTAssertEqual(Demangler.mangledToReadable("$s14OracleFeatures5TokenVfD.cold.1"),
                       "OracleFeatures.Token.deinit with unmangled suffix \".cold.1\"")
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3BoxCfD.cold.1"),
                       "main.Box.__deallocating_deinit with unmangled suffix \".cold.1\"")
        // `fd` (non-deallocating deinit) is unchanged.
        XCTAssertEqual(Demangler.mangledToReadable("$s4main3BoxCfd"), "main.Box.deinit")
    }

    /// Swift demangler corpus (2026-10-13): `MD` is Swift's canonical demangling-cache suffix, in
    /// ordinary metadata and after a pack conformance; the Apple-dialect `Md`/`MR` stay accepted.
    func testCanonicalUppercaseMDDemanglingCacheVariable() {
        XCTAssertEqual(Demangler.mangledToReadable("$sSaySiGMD"), "demangling cache variable for type metadata for [Swift.Int]")
        XCTAssertEqual(Demangler.mangledToReadable("$s14OracleFeatures6LoggedVySiGMD"),
                       "demangling cache variable for type metadata for OracleFeatures.Logged<Swift.Int>")
        XCTAssertEqual(Demangler.mangledToReadable("$s13OraclePackLib0B0VyAA4ItemV_QPAeA1P0aB4UseryHC_HXg_GMD"),
                       "demangling cache variable for type metadata for OraclePackLib.Pack<Pack{OraclePackLib.Item}>")
        XCTAssertEqual(Demangler.mangledToReadable("$s13OraclePackLib0B0VyAA4ItemV_AEQPAeA1P0aB4UseryHC_AeafGyHCHXg_GMD"),
                       "demangling cache variable for type metadata for OraclePackLib.Pack<Pack{OraclePackLib.Item, OraclePackLib.Item}>")
        XCTAssertEqual(Demangler.mangledToReadable("$s18ConformanceSamples3BoxVySiGMd"),
                       "demangling cache variable for type metadata for ConformanceSamples.Box<Swift.Int>")
        XCTAssertEqual(Demangler.mangledToReadable("$s18ConformanceSamples3BoxVySiGMR"),
                       "mangled name ref for type metadata for ConformanceSamples.Box<Swift.Int>")
        XCTAssertNil(Demangler.mangledToReadable("$sSaySiGMDx"), "MD must end the symbol")
    }
}
