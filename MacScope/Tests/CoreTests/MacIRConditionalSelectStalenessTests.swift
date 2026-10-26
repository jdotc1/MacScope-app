import XCTest
@testable import MacScope

final class MacIRConditionalSelectStalenessTests: XCTestCase {
    private func row(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String = "",
        comment: String? = nil
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func lift(_ rows: [InstructionRow], name: String = "_cs_staleness") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ function: MacIRFunction) -> String {
        PseudocodePrinter().print(function: function).text
    }

    private func renderedLine(
        in function: MacIRFunction,
        at address: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let lines = PseudocodePrinter().print(function: function).lines(sourcedAt: address)
        XCTAssertEqual(lines.count, 1, file: file, line: line)
        return try XCTUnwrap(lines.first?.text, file: file, line: line)
    }

    private func assertHonestUnknown(
        _ function: MacIRFunction,
        at address: UInt64,
        mnemonic: String,
        staleNeedle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rendered = text(function)
        let lineText = try renderedLine(in: function, at: address, file: file, line: line)
        XCTAssertTrue(lineText.contains("__unknown(\"\(mnemonic)\""), rendered, file: file, line: line)
        XCTAssertFalse(lineText.contains(staleNeedle), rendered, file: file, line: line)
    }

    // Post-IR-7: this is a STRICT +4/+4 triple, so the cset no longer falls back to an honest
    // __unknown — it lifts the CORRECT compound `(w8 == 0x2f) || (w8 == 0x0)`. The CS-1
    // invariant is unchanged and still pinned: the bare STALE single predicate must never be
    // emitted. (Hand-derived from the NZCV table: #0x4 sets Z, guard `ne`, consumer `eq`.)
    func testCsetAfterConditionalCompareLiftsCompoundNotStalePredicate() throws {
        let function = lift([
            row(0x1000_2308, "cmp", "w8, #0x2f"),
            row(0x1000_230c, "ccmp", "w8, #0x0, #0x4, ne"),
            row(0x1000_2310, "cset", "w22, eq", comment: "materialize compound predicate"),
            row(0x1000_2314, "ret")
        ], name: "_zsh_cset_stale")
        let lineText = try renderedLine(in: function, at: 0x1000_2310)

        XCTAssertTrue(lineText.contains("0x2f"), lineText)
        XCTAssertTrue(lineText.contains("0x0"), lineText)
        XCTAssertTrue(lineText.contains("||"), lineText)
        // the stale single-comparison lift must NOT be what we emit
        XCTAssertFalse(lineText.hasSuffix("= w8_0 == 0x2f; // materialize compound predicate; compare to bool"), lineText)
    }

    // Post-IR-7: strict triple -> csel lifts the compound as its select condition.
    func testCselAfterConditionalCompareLiftsCompoundNotStalePredicate() throws {
        let function = lift([
            row(0x1000_2400, "cmp", "w8, #0x2f"),
            row(0x1000_2404, "ccmp", "w8, #0x0, #0x4, ne"),
            row(0x1000_2408, "csel", "w9, w10, w11, eq", comment: "select compound predicate"),
            row(0x1000_240c, "ret")
        ], name: "_csel_stale")
        let lineText = try renderedLine(in: function, at: 0x1000_2408)

        XCTAssertTrue(lineText.contains("||"), lineText)
        XCTAssertTrue(lineText.contains("0x2f") && lineText.contains("0x0"), lineText)
        XCTAssertTrue(lineText.contains("?"), lineText)   // still a select
        XCTAssertFalse(lineText.contains("__unknown"), lineText)
    }

    func testCanonicalConditionalSelectAliasesAfterConditionalCompareLiftCompound() throws {
        let cases: [(name: String, mnemonic: String, operands: String)] = [
            ("cinc", "cinc", "w9, w10, eq"),
            ("cneg", "cneg", "w9, w10, eq"),
            ("csetm", "csetm", "w9, eq")
        ]

        for entry in cases {
            let function = lift([
                row(0x1000_2500, "cmp", "w8, #0x2f"),
                row(0x1000_2504, "ccmp", "w8, #0x0, #0x4, ne"),
                row(0x1000_2508, entry.mnemonic, entry.operands, comment: "alias compound predicate"),
                row(0x1000_250c, "ret")
            ], name: "_alias_stale_\(entry.name)")

            // Post-IR-7: strict triple -> the canonical alias lifts the compound. NOTE the
            // canonicalization INVERTS the suffix (`cinc …,eq` -> `csinc …,ne`), so the faithful
            // compound is the De Morgan dual `(w8 != 0x2f) && (w8 != 0x0)` rather than the `||`
            // form the direct `cset` produces. Both are correct; accept either connective.
            let lineText = try renderedLine(in: function, at: 0x1000_2508)
            XCTAssertTrue(lineText.contains("&&") || lineText.contains("||"), "\(entry.name): \(lineText)")
            XCTAssertTrue(lineText.contains("0x2f") && lineText.contains("0x0"), "\(entry.name): \(lineText)")
            XCTAssertFalse(lineText.contains("__unknown"), "\(entry.name): \(lineText)")
        }
    }

    func testPlainCompareCsetStillLiftsPredicate() throws {
        let function = lift([
            row(0x1000_2600, "cmp", "w0, #0x2f"),
            row(0x1000_2604, "cset", "w0, eq", comment: "materialize plain predicate"),
            row(0x1000_2608, "ret")
        ], name: "_plain_cmp_cset")
        let rendered = text(function)
        let lineText = try renderedLine(in: function, at: 0x1000_2604)

        // Pins the REAL pipeline render: the standalone __compare intrinsic line is elided by
        // the printer's pre-existing dead-store pass once the cset materializes the predicate
        // (the in-sandbox authoring harness rendered without that elision — driver-corrected).
        XCTAssertEqual(
            rendered,
            """
            BOOL _plain_cmp_cset(int32_t arg0) {
                // entry 0x0000000010002600; no stack frame; calls none
                w0_1 = arg0 == 0x2f; // materialize plain predicate; compare to bool
                return w0_1; // return
            }
            """
        )
        XCTAssertTrue(lineText.contains(" = arg0 == 0x2f; // materialize plain predicate; compare to bool"), rendered)
        XCTAssertFalse(lineText.contains("__unknown(\"cset\""), rendered)
    }

    func testPlainCompareAfterConditionalCompareResetsStalenessFlag() throws {
        let function = lift([
            row(0x1000_2700, "cmp", "w8, #0x2f"),
            row(0x1000_2704, "ccmp", "w8, #0x0, #0x4, ne"),
            row(0x1000_2708, "cset", "w22, eq", comment: "compound predicate"),
            row(0x1000_270c, "cmp", "w0, #0x7"),
            row(0x1000_2710, "cset", "w0, eq", comment: "fresh predicate"),
            row(0x1000_2714, "ret")
        ], name: "_cset_reset")
        let rendered = text(function)
        let resetLine = try renderedLine(in: function, at: 0x1000_2710)

        // Post-IR-7 the first cset (a strict triple) lifts the compound rather than falling back.
        let compoundLine = try renderedLine(in: function, at: 0x1000_2708)
        XCTAssertTrue(compoundLine.contains("||"), compoundLine)
        // THE POINT OF THIS TEST: the later plain `cmp` resets the staleness flag, so the second
        // cset lifts its own FRESH predicate — not the compound, not the stale one.
        XCTAssertTrue(resetLine.contains(" = arg0 == 0x7; // fresh predicate; compare to bool"), rendered)
        XCTAssertFalse(resetLine.contains("__unknown(\"cset\""), rendered)
    }

    func testFloatingPointComparePoisonPreventsStaleCsetLift() throws {
        let function = lift([
            row(0x1000_2800, "cmp", "w8, #0x2"),
            row(0x1000_2804, "fcmp", "d0, d1"),
            row(0x1000_2808, "cset", "w9, eq", comment: "stale integer predicate"),
            row(0x1000_280c, "ret")
        ], name: "_fcmp_poison")

        try assertHonestUnknown(function, at: 0x1000_2808, mnemonic: "cset", staleNeedle: "== 0x2")
    }

    // Post-IR-6 (round 6) the logical/extended flag-setters `ands`/`tst-reg`/`cmp-3op` LIFT and
    // record a FRESH comparison instead of poisoning, so the cset now lifts THAT fresh predicate
    // — never the stale `cmp w8,#2`. The staleness invariant is preserved (cset must not read the
    // earlier cmp); only the mechanism changed from honest-`__unknown` to a correct fresh lift.
    func testFlagSettingLogicalLiftsFreshComparisonNotStale() throws {
        let function = lift([
            row(0x1000_2900, "cmp", "w8, #0x2"),
            row(0x1000_2904, "ands", "w10, w11, w12"),
            row(0x1000_2908, "cset", "w9, eq", comment: "fresh logical predicate"),
            row(0x1000_290c, "ret")
        ], name: "_ands_fresh")
        let t = text(function)
        XCTAssertFalse(t.contains("__unknown(\"cset\""), t)   // ands recorded fresh → cset lifts
        XCTAssertFalse(t.contains("== 0x2"), t)               // NOT the stale cmp w8,#2
        XCTAssertTrue(t.contains("(w11_0 & w12_0) == 0x0"), t)  // the fresh ands (a&b)==0
    }

    func testRegisterRegisterTstLiftsFreshComparisonNotStale() throws {
        let function = lift([
            row(0x1000_2a00, "cmp", "w8, #0x2"),
            row(0x1000_2a04, "tst", "w10, w11"),
            row(0x1000_2a08, "cset", "w9, eq", comment: "fresh logical predicate"),
            row(0x1000_2a0c, "ret")
        ], name: "_tst_reg_fresh")
        let t = text(function)
        XCTAssertFalse(t.contains("__unknown(\"cset\""), t)
        XCTAssertFalse(t.contains("== 0x2"), t)
        XCTAssertTrue(t.contains("(int32_t)((uint32_t)(w10_0) & w11_0) == 0x0"), t)
    }

    func testExtendedCompareLiftsFreshComparisonNotStale() throws {
        let function = lift([
            row(0x1000_2b00, "cmp", "w8, #0x2"),
            row(0x1000_2b04, "cmp", "x0, w9, sxtw"),
            row(0x1000_2b08, "cset", "w9, eq", comment: "fresh extended predicate"),
            row(0x1000_2b0c, "ret")
        ], name: "_cmp_extended_fresh")
        let t = text(function)
        XCTAssertFalse(t.contains("__unknown(\"cset\""), t)
        XCTAssertFalse(t.contains("== 0x2"), t)               // NOT the stale cmp w8,#2
        XCTAssertTrue(t.contains("(int32_t)"), t)             // the fresh sxtw-extended compare
    }

    func testSubsAndAddsStillRecordFreshComparisons() throws {
        let subs = lift([
            row(0x1000_2c00, "subs", "w8, w9, #0x1"),
            row(0x1000_2c04, "cset", "w10, eq", comment: "subs predicate"),
            row(0x1000_2c08, "ret")
        ], name: "_subs_recorder")
        let adds = lift([
            row(0x1000_2d00, "adds", "w8, w9, #0x0"),
            row(0x1000_2d04, "cset", "w10, eq", comment: "adds predicate"),
            row(0x1000_2d08, "ret")
        ], name: "_adds_recorder")
        let subsText = text(subs)
        let addsText = text(adds)
        let subsLine = try renderedLine(in: subs, at: 0x1000_2c04)
        let addsLine = try renderedLine(in: adds, at: 0x1000_2d04)

        XCTAssertTrue(subsLine.contains("== 0x1; // subs predicate; compare to bool"), subsText)
        XCTAssertTrue(addsLine.contains("== 0x0; // adds predicate; compare to bool"), addsText)
        XCTAssertFalse(subsLine.contains("__unknown(\"cset\""), subsText)
        XCTAssertFalse(addsLine.contains("__unknown(\"cset\""), addsText)
    }
}
