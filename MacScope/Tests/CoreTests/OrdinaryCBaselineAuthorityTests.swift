import Foundation
import XCTest

/// New bounded controls grounded in the retained jinit upsampler. The executable
/// refusal selector renders that complete decoder-faithful fixture once and
/// reuses its actual lines/contract for every mutation. No candidate/source
/// machine runs here; these are lexical controls, not numerical equivalence.
final class OrdinaryCBaselineAuthorityTests: XCTestCase {
    private typealias C = OrdinaryC

    func testQuotedAndCommentedBaselineNamesDoNotCreateResultReads() throws {
        let baseline = RegionalCallSeed.jinit.baselineText
        // Exact frozen results: row21 x0_2 is dead; row35 x0_4 is live via
        // its retained-pointer copy, memory-data store and three memory-address
        // operands (six total tokens, including its definition).
        let decoys = #"""
        __unknown("x0_2 x0_4", "escaped \" x0_2");
        diagnostic('x0_2');
        // x0_2 x0_4
        /* x0_2
           x0_4 */
        x0_2_suffix = 0;
        """#
        let original = try C.baselineAuthorityIdentifierCounts(baseline)
        let masked = try C.baselineAuthorityIdentifierCounts(baseline + "\n" + decoys)
        XCTAssertEqual(original["x0_2"], 1, "only the defining occurrence, no baseline read")
        XCTAssertEqual(original["x0_4"], 6, "definition plus the five frozen allocation-result reads")
        XCTAssertEqual(masked["x0_2"], original["x0_2"], "quoted/comment spelling cannot grant live-result authority")
        XCTAssertEqual(masked["x0_4"], original["x0_4"])
        XCTAssertNil(masked["$literal"], "masked literal is not an identifier")
        let actualRead = try C.baselineAuthorityIdentifierCounts(baseline + "\n" + decoys + "\nlexical_probe = x0_2;")
        XCTAssertEqual(actualRead["x0_2"], 2, "a genuine identifier read must not be hidden with the decoys")
    }

    func testMalformedFrozenBaselineInventoryFailsClosed() {
        let baseline = RegionalCallSeed.jinit.baselineText
        for suffix in ["\n/* x0_2", "\n__unknown(\"x0_2"] {
            do {
                _ = try C.baselineAuthorityIdentifierCounts(baseline + suffix)
                XCTFail("malformed historical lexical inventory must not yield authority counts")
            } catch let failure as C.Failure {
                guard case .invalidContract = failure else { return XCTFail("wrong baseline failure category: \(failure)") }
            } catch { XCTFail("unexpected infrastructure failure: \(error)") }
        }
    }

    func testExecutableQuotedLiteralsRemainRejected() throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(.jinit)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        let contract = try C.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.baselineText, callRows: fixture.callRows)
        let original = C.lines(fixture.document)
        guard let last = original.last, case .closingBrace = last.envelope, last.text == "}" else {
            throw C.Failure.invalidContract("real candidate function envelope missing")
        }
        XCTAssertEqual(contract.calls[21]?.resultName, "x0_2")
        XCTAssertTrue(contract.deadResults.contains(21))
        XCTAssertEqual(contract.calls[35]?.resultName, "x0_4")
        XCTAssertFalse(contract.deadResults.contains(35))
        for body in ["if (false) { int64_t lexical_probe = \"x0_2\"; }",
                     "if (false) { int64_t lexical_probe = 'x'; }",
                     "if (false) { lexical_probe = __unknown(\"cset\", \"w14, eq\"); }"] {
            var changed = original
            changed.insert(.init(text: body, source: nil, envelope: .body), at: changed.count - 1)
            do {
                _ = try C.Program(lines: changed, contract: contract)
                XCTFail("baseline masking must never admit executable quoted syntax")
            } catch let failure as C.Failure {
                guard case let .unsupportedSyntax(reason) = failure,
                      reason.contains("unsupported executable literal") else {
                    return XCTFail("wrong executable refusal: \(failure)")
                }
            } catch { XCTFail("unexpected infrastructure failure: \(error)") }
        }
    }
}
