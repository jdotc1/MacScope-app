import Foundation
import XCTest
@testable import MacScope

final class SwiftSymbolFactsTests: XCTestCase {
    private struct Witnesses: Decodable {
        let schemaVersion: Int
        let rows: [Row]
    }
    private struct Row: Decodable {
        let id: String
        let mangled: String
        let text: String?
        let textRule: String
        let facts: Facts?
    }
    private struct Facts: Decodable {
        let value: SwiftSymbolFacts
        private enum CodingKeys: String, CodingKey {
            case isFunction, isAsync, isThrowing, thrownType, isGeneric
            case isPartialApplyForwarder, isDispatchThunk, isAsyncFunctionPointer
            case isReabstractionThunk, isMerged, funclet, selfKind, selfNominalKind
            case selfTypeIsGeneric, isMutating, hasNonScalarParameter, hasNonScalarReturn
        }
        private struct Funclet: Decodable { let kind: String; let index: Int }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func enumeration<T: RawRepresentable>(_ type: T.Type, _ key: CodingKeys) throws -> T where T.RawValue == String {
                let raw = try c.decode(String.self, forKey: key)
                guard let result = T(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid enum value: " + raw)
                }
                return result
            }
            var f = SwiftSymbolFacts()
            f.isFunction = try c.decode(Bool.self, forKey: .isFunction)
            f.isAsync = try c.decode(Bool.self, forKey: .isAsync)
            f.isThrowing = try c.decode(Bool.self, forKey: .isThrowing)
            f.thrownType = try c.decodeIfPresent(String.self, forKey: .thrownType)
            f.isGeneric = try c.decode(Bool.self, forKey: .isGeneric)
            f.isPartialApplyForwarder = try c.decode(Bool.self, forKey: .isPartialApplyForwarder)
            f.isDispatchThunk = try c.decode(Bool.self, forKey: .isDispatchThunk)
            f.isAsyncFunctionPointer = try c.decode(Bool.self, forKey: .isAsyncFunctionPointer)
            f.isReabstractionThunk = try c.decode(Bool.self, forKey: .isReabstractionThunk)
            f.isMerged = try c.decode(Bool.self, forKey: .isMerged)
            if let encoded = try c.decodeIfPresent(Funclet.self, forKey: .funclet) {
                guard let kind = SwiftFuncletKind(rawValue: encoded.kind) else {
                    throw DecodingError.dataCorruptedError(forKey: .funclet, in: c, debugDescription: "Invalid funclet kind")
                }
                f.funclet = SwiftFunclet(kind: kind, index: encoded.index)
            }
            f.selfKind = try enumeration(SwiftSelfKind.self, .selfKind)
            f.selfNominalKind = try enumeration(SwiftSelfNominalKind.self, .selfNominalKind)
            f.selfTypeIsGeneric = try c.decode(Bool.self, forKey: .selfTypeIsGeneric)
            f.isMutating = try c.decodeIfPresent(Bool.self, forKey: .isMutating)
            f.hasNonScalarParameter = try c.decode(Bool.self, forKey: .hasNonScalarParameter)
            f.hasNonScalarReturn = try c.decode(Bool.self, forKey: .hasNonScalarReturn)
            value = f
        }
    }
    private func witnesses() throws -> Witnesses {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftSymbolFacts/symbol-facts-witnesses.json")
        return try JSONDecoder().decode(Witnesses.self, from: Data(contentsOf: url))
    }
    func testWitnessTableShape() throws {
        let table = try witnesses()
        XCTAssertEqual(table.schemaVersion, 1)
        XCTAssertEqual(table.rows.count, 124)
        for (rule, count) in [("exact", 31), ("nilOrExact", 17), ("nil", 76)] {
            XCTAssertEqual(table.rows.filter { $0.textRule == rule }.count, count)
        }
        for row in table.rows { XCTAssertEqual(row.facts == nil, row.textRule == "nil", row.id + ": " + row.mangled) }
    }
    func testEveryWitnessRendersAsExpected() throws {
        for row in try witnesses().rows {
            let budget = SwiftDemangler.Budget()
            let out = SwiftDemangler.demangleWithFacts(row.mangled, budget: budget)
            if row.textRule != "nil" {
                print("Symbol facts source: " + row.id + " | " + (out == nil ? "nil" : budget.factsSource ?? "nil"))
            }
            let message = row.id + ": " + row.mangled
            switch row.textRule {
            case "nil": XCTAssertNil(out, message)
            case "exact": XCTAssertEqual(out?.rendered, row.text, message)
            case "nilOrExact": XCTAssertTrue(out == nil || out?.rendered == row.text, message + " => " + (out?.rendered ?? "nil"))
            default: XCTFail("Unknown text rule: " + row.textRule)
            }
            if let out, out.rendered != SwiftDemangler.tooComplexMarker {
                XCTAssertEqual(out.facts, row.facts?.value, message)
            }
        }
    }
    func testRenderedTextMatchesDemangle() throws {
        for row in try witnesses().rows {
            XCTAssertEqual(SwiftDemangler.demangleWithFacts(row.mangled)?.rendered,
                           SwiftDemangler.demangle(row.mangled), row.id + ": " + row.mangled)
        }
    }
    func testFactsAreNilOnlyForMarkerAndLegacyNames() {
        XCTAssertNil(SwiftDemangler.demangleWithFacts("_TtC4Main3Foo")?.facts)
        let overlong = SwiftDemangler.demangleWithFacts("$s" + String(repeating: "A", count: 9000))
        XCTAssertEqual(overlong?.rendered, SwiftDemangler.tooComplexMarker)
        XCTAssertNil(overlong?.facts)
        XCTAssertNotNil(SwiftDemangler.demangleWithFacts("$s4Main3FooC3baryyF")?.facts)
    }
    func testSignatureTypesAreExposedWithoutLabels() throws {
        let rows: [(String, [String], String)] = [
            ("$s4Main3FooC3baryS2iF", ["Swift.Int"], "Swift.Int"),
            ("$s4Main3FooC3bar5valueySi_tF", ["Swift.Int"], "()"),
            ("$s4Main3FooC3bar5valueySPySPySiGG_tF", ["Swift.UnsafePointer<Swift.UnsafePointer<Swift.Int>>"], "()")
        ]
        for (symbol, parameters, result) in rows {
            let parsed = try XCTUnwrap(SwiftDemangler.demangleWithFacts(symbol), symbol)
            XCTAssertEqual(parsed.parameterTypes, parameters, symbol)
            XCTAssertEqual(parsed.resultType, result, symbol)
        }
        let nonFunction = try XCTUnwrap(SwiftDemangler.demangleWithFacts("$s4Main3FooC"))
        XCTAssertNil(nonFunction.parameterTypes)
        XCTAssertNil(nonFunction.resultType)
        let legacy = try XCTUnwrap(SwiftDemangler.demangleWithFacts("_TtC4Main3Foo"))
        XCTAssertNil(legacy.parameterTypes)
        XCTAssertNil(legacy.resultType)
    }
    func testBacktrackingRestoresSignatureTexts() {
        let budget = SwiftDemangler.Budget()
        budget.facts = SwiftSymbolFacts()
        var parser = SwiftDemangler.Parser(budget: budget, Array("4Main3FooC3baryS2iF".unicodeScalars))
        let start = parser.saveState()
        XCTAssertEqual(parser.parseTopLevel(), "Main.Foo.bar(Swift.Int) -> Swift.Int")
        XCTAssertEqual(budget.signatureTexts?.params, "(Swift.Int)")
        XCTAssertEqual(budget.signatureTexts?.result, "Swift.Int")
        parser.restore(start)
        XCTAssertEqual(parser.pos, 0)
        XCTAssertEqual(budget.facts, SwiftSymbolFacts())
        XCTAssertNil(budget.signatureTexts)
    }
    func testConventionWitnessSignatureSpellings() throws {
        let rows: [(String, String, [String], String, Bool, Bool)] = [
            ("$s4Main3FooC3baryS2iF", "Main.Foo.bar(Swift.Int) -> Swift.Int", ["Swift.Int"], "Swift.Int", false, false),
            ("$s4Main3FooC3baryS2iYaF", "Main.Foo.bar(Swift.Int) async -> Swift.Int", ["Swift.Int"], "Swift.Int", false, false),
            ("$s4Main3FooC3baryySSF", "Main.Foo.bar(Swift.String) -> ()", ["Swift.String"], "()", true, false),
            ("$s4Main3FooC3baryySJF", "Main.Foo.bar(Swift.Character) -> ()", ["Swift.Character"], "()", false, false),
            ("$s4Main3FooC3baryycyF", "Main.Foo.bar() -> () -> ()", [], "() -> ()", false, false)
        ]
        for (symbol, text, parameters, result, aggregateParameter, aggregateResult) in rows {
            let parsed = try XCTUnwrap(SwiftDemangler.demangleWithFacts(symbol), symbol)
            XCTAssertEqual(parsed.rendered, text, symbol)
            XCTAssertEqual(parsed.parameterTypes, parameters, symbol)
            XCTAssertEqual(parsed.resultType, result, symbol)
            XCTAssertEqual(parsed.facts?.hasNonScalarParameter, aggregateParameter, symbol)
            XCTAssertEqual(parsed.facts?.hasNonScalarReturn, aggregateResult, symbol)
        }
    }
    func testIsolatedDeallocatingDeinitRenders() {
        XCTAssertEqual(SwiftDemangler.demangle("$s4Main3FooCfZ"), "Main.Foo.__isolated_deallocating_deinit")
        XCTAssertNil(SwiftDemangler.demangle("$s4Main3FooVfZ"))
    }
    func testUnmangledSuffixKeepsInnerFacts() {
        let base = SwiftDemangler.demangleWithFacts("$s4Main3FooC3baryyF")
        let suffixed = SwiftDemangler.demangleWithFacts("$s4Main3FooC3baryyF.cold.1")
        XCTAssertTrue(suffixed?.rendered.hasSuffix(" with unmangled suffix \".cold.1\"") == true)
        XCTAssertEqual(suffixed?.facts, base?.facts)
        XCTAssertEqual(suffixed?.parameterTypes, base?.parameterTypes)
        XCTAssertEqual(suffixed?.resultType, base?.resultType)
    }
}
