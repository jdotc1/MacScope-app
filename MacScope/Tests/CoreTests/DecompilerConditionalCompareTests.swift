import XCTest
@testable import MacScope

final class DecompilerConditionalCompareTests: XCTestCase {
    // Stack-local read-only fence encloses setup, body and teardown. No shared
    // snapshot state is needed when suites or test instances execute in parallel.
    override func invokeTest() {
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        defer {
            let after = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]
            XCTAssertTrue(before.isEqual(to: after),
                          "Mode tests must not change the application preference domain")
        }
        super.invokeTest()
    }


    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func print(_ name: String, _ rows: [InstructionRow]) -> PseudocodeDocument {
        let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
        return PseudocodePrinter().print(function: function)
    }

    func testConditionalCompareAndCompoundStructuresAndSuppressesSourceRows() {
        let document = print("_ccmp_and_raw", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "ccmp", "x1, #0x0, #0x0, ne"),
            row(0x1008, "b.eq", "0x1010", "body"),
            row(0x100c, "ret", ""),
            row(0x1010, "mov", "x0, #0x1", "then"),
            row(0x1014, "b", "0x100c"),
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(
            document.text,
            """
            int64_t _ccmp_and_raw(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                if ((arg0 != 0x0) && (x1_0 == 0x0)) { // body; conditional branch
                    x0_1 = 0x1; // then
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("__compare("))
        XCTAssertFalse(document.text.contains("__unknown(\"ccmp\""))
    }

    func testConditionalCompareInvertedCompoundUsesDeMorganOnce() {
        let document = print("_ccmp_and_inverted", [
            row(0x2000, "cmp", "x0, #0x0"),
            row(0x2004, "ccmp", "x1, #0x0, #0x0, ne"),
            row(0x2008, "b.eq", "0x2010", "skip"),
            row(0x200c, "mov", "x0, #0x1", "body"),
            row(0x2010, "ret", ""),
        ])

        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(
            document.text,
            """
            int64_t _ccmp_and_inverted(int64_t arg0) {
                // entry 0x0000000000002000; no stack frame; calls none
                if ((arg0 == 0x0) || (x1_0 != 0x0)) { // skip; conditional branch
                    x0_1 = 0x1; // body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertFalse(document.text.contains("&& (x1_0 == 0x0) == 0x0"))
        XCTAssertFalse(document.text.contains("!((arg0 != 0x0) && (x1_0 == 0x0))"))
    }

    func testConditionalCompareOrRegisterAndCcmnShapes() {
        let orDocument = print("_ccmp_or_raw", [
            row(0x3000, "cmp", "x0, #0x0"),
            row(0x3004, "ccmp", "x1, #0x5, #0x4, eq"),
            row(0x3008, "b.eq", "0x3010", "body"),
            row(0x300c, "ret", ""),
            row(0x3010, "mov", "x0, #0x1", "then"),
            row(0x3014, "b", "0x300c"),
        ])
        XCTAssertNil(orDocument.structureFallback)
        XCTAssertTrue(orDocument.text.contains("if ((arg0 != 0x0) || (x1_0 == 0x5))"))

        let registerDocument = print("_ccmp_register", [
            row(0x6000, "cmp", "x0, #0x0"),
            row(0x6004, "ccmp", "x1, x2, #0x0, ne"),
            row(0x6008, "b.eq", "0x6010", "body"),
            row(0x600c, "ret", ""),
            row(0x6010, "mov", "x0, #0x1", "then"),
            row(0x6014, "b", "0x600c"),
        ])
        XCTAssertNil(registerDocument.structureFallback)
        XCTAssertTrue(registerDocument.text.contains("if ((arg0 != 0x0) && (x1_0 == x2_0))"))

        let ccmnDocument = print("_ccmn_and", [
            row(0x7000, "cmp", "x0, #0x0"),
            row(0x7004, "ccmn", "x1, #0x1, #0x0, ne"),
            row(0x7008, "b.lt", "0x7010", "body"),
            row(0x700c, "ret", ""),
            row(0x7010, "mov", "x0, #0x1", "then"),
            row(0x7014, "b", "0x700c"),
        ])
        XCTAssertNil(ccmnDocument.structureFallback)
        // SSA projects the untyped x1 carrier to signed 64 bits; CCMN +1 tests N != V, not N alone.
        let ccmnSigned = "(((x1_0 & 0x8000000000000000) == 0 ? (int64_t)x1_0 : -1 - (int64_t)(uint64_t)~x1_0))"
        XCTAssertTrue(ccmnDocument.text.contains("if ((arg0 != 0x0) && (\(ccmnSigned) < -0x1))"), ccmnDocument.text)
    }

    func testConditionalCompareTermsKeepIndependentSignedness() {
        let signedUnsigned = print("_ccmp_signed_unsigned", [
            row(0x4000, "cmp", "x0, #-0x1"),
            row(0x4004, "ccmp", "x1, #0xa, #0x0, lt"),
            row(0x4008, "b.hs", "0x4010", "body"),
            row(0x400c, "ret", ""),
            row(0x4010, "mov", "x0, #0x1", "then"),
            row(0x4014, "b", "0x400c"),
        ])
        XCTAssertNil(signedUnsigned.structureFallback)
        // SSA's signed projection belongs only to the LT guard; HS keeps its independent unsigned operands.
        let signedArgument = MacIRConfiguration.ssaEnabled ? "((int64_t)(arg0))" : "arg0"
        XCTAssertTrue(signedUnsigned.text.contains("if ((\(signedArgument) < -0x1) && ((uint64_t)(x1_0) >= (uint64_t)(0xa)))"), signedUnsigned.text)

        let unsignedSigned = print("_ccmp_unsigned_signed", [
            row(0x5000, "cmp", "x0, #0x5"),
            row(0x5004, "ccmp", "x1, #-0x2, #0x0, lo"),
            row(0x5008, "b.lt", "0x5010", "body"),
            row(0x500c, "ret", ""),
            row(0x5010, "mov", "x0, #0x1", "then"),
            row(0x5014, "b", "0x500c"),
        ])
        XCTAssertNil(unsignedSigned.structureFallback)
        // The LO guard stays unsigned while SSA projects only the later signed LT term.
        let signedRegister = MacIRConfiguration.ssaEnabled
            ? "(((x1_0 & 0x8000000000000000) == 0 ? (int64_t)x1_0 : -1 - (int64_t)(uint64_t)~x1_0))"
            : "x1_0"
        XCTAssertTrue(unsignedSigned.text.contains("if (((uint64_t)(arg0) < (uint64_t)(0x5)) && (\(signedRegister) < -0x2))"), unsignedSigned.text)
    }

    func testConditionalCompareLoopHeaderDoesNotWidenLoopRecovery() {
        let document = print("_ccmp_loop_header_fallback", [
            row(0xe000, "cmp", "x0, #0x0"),
            row(0xe004, "ccmp", "x1, #0x0, #0x0, ne"),
            row(0xe008, "b.eq", "0xe014", "exit"),
            row(0xe00c, "nop", "", "body"),
            row(0xe010, "b", "0xe000", "back"),
            row(0xe014, "ret", ""),
        ])

        XCTAssertEqual(document.structureFallback, .unsupportedRegion)
        GotoLabelWellFormednessTests.assertGoto(document.text, target: 0xe014, condition: "(arg0 != 0x0) && (x1_0 == 0x0)")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        XCTAssertFalse(document.text.contains("while ("))
    }

    func testConditionalCompareNegativeSubsetFallsBack() {
        // Legacy (flag-off) expectation: under SSA (A26) rows between cmp/ccmp/branch
        // that are flag-neutral no longer block the compound; see
        // PendingComparisonFlagNeutralRowsTests.
        return MacIRConfiguration.$ssaOverride.withValue(false) {
            let cases: [(String, [InstructionRow], String)] = [
                ("chain", [
                    row(0x8000, "cmp", "x0, #0x0"),
                    row(0x8004, "ccmp", "x1, #0x0, #0x0, ne"),
                    row(0x8008, "ccmp", "x2, #0x0, #0x0, ne"),
                    row(0x800c, "b.eq", "0x8014", "skip"),
                    row(0x8010, "mov", "x0, #0x1", "body"),
                    row(0x8014, "ret", ""),
                ], "__conditional_compare_ne("),
                ("unlifted", [
                    row(0x8100, "adc", "x0, x1, x2"),
                    row(0x8104, "ccmp", "x3, #0x0, #0x0, ne"),
                    row(0x8108, "b.eq", "0x8110", "skip"),
                    row(0x810c, "mov", "x0, #0x1", "body"),
                    row(0x8110, "ret", ""),
                ], "__conditional_compare_ne("),
                ("al", [
                    row(0xb000, "cmp", "x0, #0x0"),
                    row(0xb004, "ccmp", "x1, #0x0, #0x0, al"),
                    row(0xb008, "b.eq", "0xb010", "skip"),
                    row(0xb00c, "mov", "x0, #0x1", "body"),
                    row(0xb010, "ret", ""),
                ], "__conditional_compare_al("),
                ("nv", [
                    row(0xb100, "cmp", "x0, #0x0"),
                    row(0xb104, "ccmp", "x1, #0x0, #0x0, nv"),
                    row(0xb108, "b.eq", "0xb110", "skip"),
                    row(0xb10c, "mov", "x0, #0x1", "body"),
                    row(0xb110, "ret", ""),
                ], "__conditional_compare_nv("),
                ("fp", [
                    row(0xc000, "fcmp", "d0, d1"),
                    row(0xc004, "fccmp", "d2, d3, #0x0, eq"),
                    row(0xc008, "b.eq", "0xc010", "skip"),
                    row(0xc00c, "mov", "x0, #0x1", "body"),
                    row(0xc010, "ret", ""),
                ], "__unknown(\"fccmp\", \"d2, d3, #0x0, eq\")"),
                ("tst-mi", [
                    row(0xd000, "tst", "x0, #0x8"),
                    row(0xd004, "ccmp", "x1, #0x0, #0x0, mi"),
                    row(0xd008, "b.eq", "0xd010", "skip"),
                    row(0xd00c, "mov", "x0, #0x1", "body"),
                    row(0xd010, "ret", ""),
                ], "__conditional_compare_mi("),
                ("mov-between-cmp-and-ccmp", [
                    row(0x9000, "cmp", "x0, #0x0"),
                    row(0x9004, "mov", "x3, #0x1", "live"),
                    row(0x9008, "ccmp", "x1, #0x0, #0x0, ne"),
                    row(0x900c, "b.eq", "0x9014", "skip"),
                    row(0x9010, "mov", "x0, #0x1", "body"),
                    row(0x9014, "ret", ""),
                ], "__conditional_compare_ne("),
                ("mov-between-ccmp-and-branch", [
                    row(0xa000, "cmp", "x0, #0x0"),
                    row(0xa004, "ccmp", "x1, #0x0, #0x0, ne"),
                    row(0xa008, "mov", "x3, #0x1", "live"),
                    row(0xa00c, "b.eq", "0xa014", "skip"),
                    row(0xa010, "mov", "x0, #0x1", "body"),
                    row(0xa014, "ret", ""),
                ], "__conditional_compare_ne("),
            ]

            // IR-7: the ccmp LINE renders a flag-effect intrinsic; `fccmp` is untouched. The point of
            // this test is unchanged: none of these seed a compound, so the region stays unsupported.
            for (name, rows, expectedText) in cases {
                let document = print("_ccmp_negative_\(name)", rows)
                XCTAssertEqual(document.structureFallback, .unsupportedRegion, name)
                XCTAssertTrue(document.text.contains(expectedText), "\(name): \(document.text)")
                XCTAssertFalse(document.text.contains("&&"), "\(name) must not compound-fold")
            }
        }
    }
}
