import XCTest
@testable import MacScope

final class SwiftDemanglerCP5GrammarTests: XCTestCase {
    func testNominalDeallocatorKindAndWrappers() {
        let rows = [("$s4Test5TokenVfD", "Test.Token.deinit"),
                    ("$s4Test4FlagOfD", "Test.Flag.deinit"),
                    ("$s4Test3BoxCfD", "Test.Box.__deallocating_deinit")]
        for (name, expected) in rows {
            XCTAssertEqual(SwiftDemangler.demangle(name), expected)
            XCTAssertEqual(SwiftDemangler.demangle(name + "Tj"), "dispatch thunk of " + expected)
            XCTAssertNil(SwiftDemangler.demangle(String(name.dropLast())))
            XCTAssertNil(SwiftDemangler.demangle(name + "junk"))
        }
    }
    func testBoundGenericDestructorIsRejected() {
        for kind in ["C", "V", "O"] {
            XCTAssertNil(SwiftDemangler.demangle("$s4Test3Box" + kind + "yAA5TokenVGfD"))
        }
    }
    func testCanonicalMetadataCacheAndCompatibilityAliases() {
        for (type, rendered) in [("$s4Test3FooV", "Test.Foo"), ("$sSaySiG", "[Swift.Int]"), ("$sx", "A")] {
            XCTAssertEqual(SwiftDemangler.demangle(type + "MD"), "demangling cache variable for type metadata for " + rendered)
            XCTAssertEqual(SwiftDemangler.demangle(type + "Md"), "demangling cache variable for type metadata for " + rendered)
            XCTAssertEqual(SwiftDemangler.demangle(type + "MR"), "mangled name ref for type metadata for " + rendered)
            XCTAssertNil(SwiftDemangler.demangle(type + "M"))
            XCTAssertNil(SwiftDemangler.demangle(type + "MDjunk"))
        }
    }
    func testCanonicalPackMetadataCacheAndMalformedSuffix() {
        let type = "$s7PackLib0A0VyAA4ItemV_QPAeA1P0A4UseryHC_HXg_G"
        let expected = "demangling cache variable for type metadata for PackLib.Pack<Pack{PackLib.Item}>"
        XCTAssertEqual(SwiftDemangler.demangle(type + "MD"), expected)
        XCTAssertEqual(SwiftDemangler.demangle(type + "Md"), expected)
        XCTAssertNil(SwiftDemangler.demangle(type + "M"))
        XCTAssertNil(SwiftDemangler.demangle(type + "MDjunk"))
    }
    func testNewProductionExamples() {
        let cases: [(String, String)] = [
            ("$s11OracleEnums7Choice0O5emptyyACyxGAEmSHRzs8SendableRzlFWC", "enum case for OracleEnums.Choice0.empty<A where A: Swift.Hashable, A: Swift.Sendable>(OracleEnums.Choice0<A>.Type) -> OracleEnums.Choice0<A>"),
            ("$s11OracleEnums7Choice0O6NestedVyAEyx_qd__Gqd__cfC", "OracleEnums.Choice0.Nested.init(A1) -> OracleEnums.Choice0<A>.Nested<A1>"),
            ("$s11OracleEnums7Choice0O6NestedVyx_qd__GSHRzs8SendableRzr__lWOc", "outlined init with copy of OracleEnums.Choice0<A>.Nested<A1>"),
            ("$s11OracleEnums7Choice0O6NestedVyx_qd__GSHRzs8SendableRzr__lWOh", "outlined destroy of OracleEnums.Choice0<A>.Nested<A1>"),
            ("$s11OracleEnums7Choice0OyxGSHRzs8SendableRzlWOb", "outlined init with take of OracleEnums.Choice0<A>"),
            ("$s13OracleClasses5Base0C5valuexvplACyxGTK", "key path getter for OracleClasses.Base0.value : A : <A>OracleClasses.Base0<A>"),
            ("$s13OracleClasses5Base0C5valuexvplACyxGTk", "key path setter for OracleClasses.Base0.value : A : <A>OracleClasses.Base0<A>"),
            ("$s13OracleClasses6Child0C3getSiyFAA5Base0CADxyFTV", "vtable thunk for OracleClasses.Base0.get() -> A dispatching to OracleClasses.Child0.get() -> Swift.Int"),
            ("$s13OraclePackLib0B0VyAA4ItemV_AEQPAeA1P0aB4UseryHC_AeafGyHCHXg_GMD", "demangling cache variable for type metadata for OraclePackLib.Pack<Pack{OraclePackLib.Item, OraclePackLib.Item}>"),
            ("$s14OracleFeatures5TokenVfD", "OracleFeatures.Token.deinit"),
            ("$s14OracleGenerics7Record0V_5count5maybeACyxGx_SixSgtcfcfA0_", "default argument 1 of OracleGenerics.Record0.init(_: A, count: Swift.Int, maybe: A?) -> OracleGenerics.Record0<A>"),
            ("$s14OracleGenerics7Record0VyxSiciM", "OracleGenerics.Record0.subscript.modify : (Swift.Int) -> A"),
            ("$s14OracleGenerics7Record0VyxSicig", "OracleGenerics.Record0.subscript.getter : (Swift.Int) -> A"),
            ("$s14OracleGenerics7Record0VyxSicipMV", "property descriptor for OracleGenerics.Record0.subscript(Swift.Int) -> A"),
            ("$s14OracleGenerics7Record0VyxSicis", "OracleGenerics.Record0.subscript.setter : (Swift.Int) -> A"),
            ("$sxSgSHRzs8SendableRzlWOd", "outlined assign with take of A?"),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(SwiftDemangler.demangle(name), expected, name)
            XCTAssertNil(SwiftDemangler.demangle(name + "junk"), name)
        }
    }
    func testDepthAndLengthLimitsRemainBounded() {
        XCTAssertEqual(SwiftDemangler.demangle("$s" + String(repeating: "x", count: 8193)), SwiftDemangler.tooComplexMarker)
        XCTAssertEqual(SwiftDemangler.demangle("$s4Test3FooV" + String(repeating: "Tm", count: 40)), SwiftDemangler.tooComplexMarker)
        let nested = "$s" + String(repeating: "Say", count: 80) + "Si" + String(repeating: "G", count: 80) + "MD"
        XCTAssertEqual(SwiftDemangler.demangle(nested), SwiftDemangler.tooComplexMarker)
    }
    func testStandardRepeatDrainsBeforeGenericDepthSeparator() {
        XCTAssertEqual(SwiftDemangler.demangle("$s4Test3BoxV3InnVyS2i_xGMD"),
                       "demangling cache variable for type metadata for Test.Box<Swift.Int, Swift.Int>.Inn<A>")
    }
    func testSubscriptKeyPathCannotUseBareEmptyListAsRoot() {
        XCTAssertNil(SwiftDemangler.demangle("$s4Test3BoxVyxSicipyTK"))
        XCTAssertNil(SwiftDemangler.demangle("$s4Test3BoxVyxSicipyTk"))
    }

    func testGenericRequirementCannotUseBareEmptyListAsType() {
        XCTAssertNil(SwiftDemangler.demangle("$sxyRszlWOc"))
        XCTAssertNil(SwiftDemangler.demangle("$s4Test3BoxV3fooxvpyRszlACyxGTK"))
        XCTAssertNil(SwiftDemangler.demangle("$sxyxRSlWOc"))
        XCTAssertNil(SwiftDemangler.demangle("$sxxyRSlWOc"))
    }

    func testTupleTypeElementsCannotUseBareEmptyListMarker() {
        XCTAssertNil(SwiftDemangler.demangle("$sSi_ySStMD"))
        XCTAssertNil(SwiftDemangler.demangle("$sSi1a_y1btMD"))
    }

}
