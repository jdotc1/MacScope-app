import Foundation
import XCTest
@testable import MacScope

final class SwiftDemanglerResidualGrammarTests: XCTestCase {
    private struct Row: Decodable { let id: String; let mangled: String; let expected: String? }
    private func rows(_ name: String) throws -> [Row] {
        let directory = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftDemanglerResidualGrammar")
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }
    func testAll49OriginalResidualsAreExact() throws {
        let fixture = try rows("residual-49.json")
        XCTAssertEqual(fixture.count, 49)
        for row in fixture { XCTAssertEqual(SwiftDemangler.demangle(row.mangled), row.expected, row.id + ": " + row.mangled) }
    }
    func testIndependentCompilerGeneratedContexts() throws {
        let fixture = try rows("independent-compiled.json")
        XCTAssertEqual(fixture.count, 128)
        for row in fixture { XCTAssertEqual(SwiftDemangler.demangle(row.mangled), row.expected, row.id + ": " + row.mangled) }
    }
    func testMalformedAndUnprovedStructuralCombinationsFailClosed() throws {
        for row in try rows("hardening-counterexamples.json") {
            let actual = SwiftDemangler.demangle(row.mangled)
            XCTAssertTrue(actual == nil || actual == row.expected, row.id + ": " + row.mangled + " => " + (actual ?? "nil"))
        }
        XCTAssertNil(SwiftDemangler.demangle("$s13OracleClasses5Base0C5valuexv"))
    }
    func testIndependentReviewCounterexamplesNeverMisrender() throws {
        for row in try rows("review-counterexamples.json") {
            let actual = SwiftDemangler.demangle(row.mangled)
            XCTAssertTrue(actual == nil || actual == row.expected, row.id + ": " + row.mangled + " => " + (actual ?? "nil"))
        }
    }
    func testStructuralIdentityAndLocalBoundaryRendering() {
        let pairs = [
            ("$sSqyxG", "A?"),
            ("$ss5ArrayCyxG", "Swift.Array<A>"),
            ("$s1M1fyxxr__lF", "M.f<A><A1>(A) -> A"),
            ("$s1M1fyxxrlF", "M.f<>(A) -> A"),
            ("$s1M1fyyF1TV1UV", "T.U in M.f() -> ()"),
            ("$s1M1fyyF1TL_V1XV", "X in T #1 in M.f() -> ()"),
            ("$s1M1fyyF1TV1XyyF", "T.X() -> () in M.f() -> ()"),
            ("$s1M1XL_Sivg", "getter of X #1 : Swift.Int in M"),
            ("$sxxQpSg", "(repeat A)?")
        ]
        for (mangled, expected) in pairs { XCTAssertEqual(SwiftDemangler.demangle(mangled), expected, mangled) }
        for mangled in ["$s1AL_Qz", "$s1AL__1BQZ", "$s1poi1TV", "$s1M1fyS2iKKF", "$s1M1fyS2iKYaF"] {
            XCTAssertNil(SwiftDemangler.demangle(mangled), mangled)
        }
    }
    func testSharedWorkBudgetCannotResetAtFallback() {
        let budget = SwiftDemangler.Budget()
        budget.remainingWork = 0
        var original = SwiftDemangler.Parser(budget: budget, Array("4Test3FooV".unicodeScalars))
        XCTAssertNil(original.parseTopLevel())
        var residual = SwiftDemangler.ResidualParser("4Test3FooV", budget: budget)
        XCTAssertNil(residual.parse())
        XCTAssertTrue(budget.exceeded)
        XCTAssertEqual(budget.remainingWork, 0)
    }
    func testSharedNodeExpansionChecksBeforeJoining() {
        let budget = SwiftDemangler.Budget()
        let parser = SwiftDemangler.ResidualParser("", budget: budget)
        let shared = SwiftDemangler.ResidualNode(.identifier, String(repeating: "a", count: SwiftDemangler.maxRenderedLength))
        let expansion = SwiftDemangler.ResidualNode(.tuple, "", Array(repeating: shared, count: SwiftDemangler.maxMangledLength))
        XCTAssertNil(parser.render(expansion))
        XCTAssertTrue(budget.exceeded)
    }
    func testEveryWrapperCreationUsesSharedParserCap() {
        let budget = SwiftDemangler.Budget()
        var parser = SwiftDemangler.ResidualParser("", budget: budget)
        let leaf = SwiftDemangler.ResidualNode(.parameter, "", [], [0,0])
        for _ in 0..<SwiftDemangler.maxWrapperDepth {
            XCTAssertTrue(parser.push(SwiftDemangler.ResidualNode(.wrapper, "associated", [leaf])))
        }
        XCTAssertFalse(parser.push(SwiftDemangler.ResidualNode(.wrapper, "witness", [leaf])))
        XCTAssertTrue(budget.exceeded)
    }
    func testStructuralDepthCap() {
        let budget = SwiftDemangler.Budget()
        var parser = SwiftDemangler.ResidualParser("", budget: budget)
        var node = SwiftDemangler.ResidualNode(.parameter, "", [], [0,0])
        for _ in 1..<SwiftDemangler.maxTypeDepth { node = SwiftDemangler.ResidualNode(.bound, "optional", [node]) }
        XCTAssertTrue(parser.push(node))
        XCTAssertFalse(parser.push(SwiftDemangler.ResidualNode(.bound, "optional", [node])))
        XCTAssertTrue(budget.exceeded)
    }
    func testPinnedCapsAndASCIIIdentifierBoundary() {
        XCTAssertEqual(SwiftDemangler.maxMangledLength, 8192)
        XCTAssertEqual(SwiftDemangler.maxTypeDepth, 64)
        XCTAssertEqual(SwiftDemangler.maxWrapperDepth, 32)
        XCTAssertEqual(SwiftDemangler.maxRenderedLength, 16384)
        XCTAssertEqual(SwiftDemangler.demangle("$s" + String(repeating: "x", count: 8191)), SwiftDemangler.tooComplexMarker)
        for text in ["$s4Café3FooV", "$s5Café3FooV", "$s3雪3FooV", "$s1雪3FooV", "$s4Test1éV", "_TtC5Café3Foo"] {
            XCTAssertNil(SwiftDemangler.demangle(text), text)
        }
    }
    func testLegacySuffixEscapingAndTruncations() {
        XCTAssertEqual(SwiftDemangler.demangle("_TtV04Test03Foo"), "Test.Foo")
        XCTAssertEqual(SwiftDemangler.demangle("_TtV4Test3Foo\""), "Test.Foo with unmangled suffix \"\\\"\"")
        for text in ["_TtV", "_TtV4Test", "_TtV4Test3Fo", "_TtC00Test3Foo"] { XCTAssertNil(SwiftDemangler.demangle(text), text) }
    }
}
