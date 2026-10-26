import XCTest
@testable import MacScope

final class MacIRLiftingBreadthRound7Tests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "", comment: String? = nil) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func lift(_ rows: [InstructionRow], name: String = "_round7") -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func text(_ rows: [InstructionRow], name: String = "_round7") -> String {
        PseudocodePrinter().print(function: lift(rows, name: name)).text
    }

    func testCcmpRendersFlagEffectIntrinsicWithoutConsumer() {
        let rendered = text([
            row(0x1000, "cmp", "w0, #0x1"),
            row(0x1004, "ccmp", "w0, #0x2, #0x0, eq"),
            row(0x1008, "ret")
        ])

        XCTAssertTrue(rendered.contains("__conditional_compare_eq(arg0, 0x2, 0x0)"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ccmp\""), rendered)
    }

    func testBranchCompoundFusionSurvivesCcmpIntrinsic() {
        let rendered = text([
            row(0x100001fe0, "cmp", "w23, #0xd"),
            row(0x100001fe4, "ccmp", "w23, #0xa, #0x4, ne"),
            row(0x100001fe8, "b.eq", "0x100002000"),
            row(0x100001fec, "ret")
        ], name: "_ssh_branch")

        XCTAssertTrue(rendered.contains("if ((w23_0 == 0xd) || (w23_0 == 0xa))"), rendered)
        XCTAssertFalse(rendered.contains("__branch_eq"), rendered)
    }

    func testCsetConsumesStrictTripleCompound() {
        let rendered = text([
            row(0x2000, "cmp", "w23, #0xd"),
            row(0x2004, "ccmp", "w23, #0xa, #0x4, ne"),
            row(0x2008, "cset", "w8, eq"),
            row(0x200c, "ret")
        ], name: "_ssh_cset")

        XCTAssertTrue(rendered.contains("(w23_0 == 0xd) || (w23_0 == 0xa)"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"cset\""), rendered)
    }

    func testCselConsumesStrictTripleCompound() {
        let rendered = text([
            row(0x3000, "cmp", "w23, #0xd"),
            row(0x3004, "ccmp", "w23, #0xa, #0x4, ne"),
            row(0x3008, "csel", "w8, w9, w10, eq"),
            row(0x300c, "ret")
        ], name: "_ssh_csel")

        XCTAssertTrue(rendered.contains("(w23_0 == 0xd) || (w23_0 == 0xa)"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"csel\""), rendered)
    }

    func testNonAdjacentRecorderVetoesCompoundCset() {
        let rendered = text([
            row(0x4000, "tst", "w9, w8"),
            row(0x4004, "mov", "w8, #0x8000"),
            row(0x4008, "ccmp", "w10, w8, #0x0, ne"),
            row(0x400c, "cset", "w0, eq"),
            row(0x4010, "ret")
        ], name: "_zsh_non_adjacent")

        XCTAssertTrue(rendered.contains("__unknown(\"cset\""), rendered)
        XCTAssertFalse(rendered.contains("w10_0 == w8_1"), rendered)
    }

    func testThreeDeepCcmpChainVetoesCompoundCset() {
        let rendered = text([
            row(0x5000, "cmp", "w0, #0x1"),
            row(0x5004, "ccmp", "w1, #0x2, #0x0, ne"),
            row(0x5008, "ccmp", "w2, #0x3, #0x0, ne"),
            row(0x500c, "cset", "w3, eq"),
            row(0x5010, "ret")
        ], name: "_ccmp_chain")

        XCTAssertTrue(rendered.contains("__unknown(\"cset\""), rendered)
        XCTAssertFalse(rendered.contains("w2_0 == 0x3"), rendered)
    }

    func testMiAndPlConsumersDoNotCompoundFold() {
        for suffix in ["mi", "pl"] {
            let rendered = text([
                row(0x6000, "cmp", "w0, #0x1"),
                row(0x6004, "ccmp", "w1, #0x2, #0x0, ne"),
                row(0x6008, "cset", "w2, \(suffix)"),
                row(0x600c, "ret")
            ], name: "_ccmp_\(suffix)")

            XCTAssertTrue(rendered.contains("__unknown(\"cset\""), rendered)
            XCTAssertFalse(rendered.contains("w1_0 < 0x2"), rendered)
        }
    }

    func testLogicalResultEnvelopeStillVetoesUnsupportedGuard() {
        let rendered = text([
            row(0x7000, "tst", "w0, w1"),
            row(0x7004, "ccmp", "w2, #0x0, #0x0, lo"),
            row(0x7008, "b.eq", "0x8000"),
            row(0x700c, "ret")
        ], name: "_logical_veto")

        XCTAssertTrue(rendered.contains("__branch_eq(0x8000)"), rendered)
        XCTAssertFalse(rendered.contains("&&"), rendered)
    }

    func testOutOfRangeNzcvKeepsCcmpUnknown() {
        let rendered = text([
            row(0x8000, "cmp", "w0, #0x1"),
            row(0x8004, "ccmp", "w1, #0x2, #0x1f, ne"),
            row(0x8008, "ret")
        ], name: "_bad_nzcv")

        XCTAssertTrue(rendered.contains("__unknown(\"ccmp\""), rendered)
        XCTAssertFalse(rendered.contains("__conditional_compare_ne"), rendered)
    }

    func testCcmpPoisonFlagVetoesStaleComparisonAfterPendingClears() {
        let rendered = text([
            row(0x9000, "cmp", "w0, #0x1"),
            row(0x9004, "ccmp", "w0, #0x2, #0x0, eq"),
            row(0x9008, "nop"),
            row(0x900c, "cset", "w0, eq"),
            row(0x9010, "ret")
        ], name: "_poison")

        // NOP preserves NZCV in SSA; legacy still refuses the nonadjacent compound, never reusing CMP alone.
        if MacIRConfiguration.ssaEnabled {
            XCTAssertTrue(rendered.contains("(arg0 == 0x1) && (arg0 == 0x2)"), rendered)
            XCTAssertFalse(rendered.contains("__unknown(\"cset\""), rendered)
        } else {
            XCTAssertTrue(rendered.contains("__unknown(\"cset\""), rendered)
            XCTAssertFalse(rendered.contains("arg0 == 0x1"), rendered)
        }
    }

    func testCcmpIntrinsicDoesNotRequireAdjacentRecorder() {
        let rendered = text([
            row(0xa000, "mov", "w9, #0x4000"),
            row(0xa004, "ccmp", "w8, w9, #0x4, eq"),
            row(0xa008, "ret")
        ], name: "_no_recorder")

        // SSA-tolerant: the printer names the dead `mov w9` store `tmp0`, so do not pin a
        // register-name operand (the PROMPT's own house rule).
        XCTAssertTrue(rendered.contains("__conditional_compare_eq(w8_0,"), rendered)
        XCTAssertTrue(rendered.contains("0x4)"), rendered)
        XCTAssertFalse(rendered.contains("__unknown(\"ccmp\""), rendered)
    }

    func testCsnegCompoundKeepsNegationOnFalseArm() {
        let rendered = text([
            row(0xb000, "cmp", "w23, #0xd"),
            row(0xb004, "ccmp", "w23, #0xa, #0x4, ne"),
            row(0xb008, "csneg", "w8, w9, w10, eq"),
            row(0xb00c, "ret")
        ], name: "_csneg")

        XCTAssertTrue(rendered.contains("(w23_0 == 0xd) || (w23_0 == 0xa)"), rendered)
        XCTAssertTrue(rendered.contains("-(w10_0)"), rendered)
    }
}
