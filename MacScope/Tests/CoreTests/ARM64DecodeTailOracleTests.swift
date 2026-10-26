import Foundation
import XCTest
@testable import MacScope

/// Adversarial oracle verification of ARM64 decode-tail coverage.
/// The DP05 cases below additionally retain Arm-adjudicated LLVM MC disagreements.
/// Other expected renderings are the canonical AArch64 form of what `clang -arch arm64` + `otool -tvVj`
/// produced for these words (otool's `.dot` surface syntax translated to canonical, e.g.
/// otool `shl.8h v0, v1, #0xa` -> `shl v0.8h, v1.8h, #0xa`). Independent of the package's own tests.
final class ARM64DecodeTailOracleTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        var data = Data()
        data.append(UInt8(word & 0xff)); data.append(UInt8((word >> 8) & 0xff))
        data.append(UInt8((word >> 16) & 0xff)); data.append(UInt8((word >> 24) & 0xff))
        let r = ARM64Decoder().decode(data, baseAddress: 0x1_0000_0000, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    func testLRCPCDecodesMatchOtool() {
        // otool: 0000000000000000	f8bfc020	ldapr	x0, [x1]
        XCTAssertEqual(text(0xf8bf_c020), "ldapr x0, [x1]")
        // otool: 0000000000000000	b8bfc062	ldapr	w2, [x3]
        XCTAssertEqual(text(0xb8bf_c062), "ldapr w2, [x3]")
        // otool: 0000000000000000	38bfc0a4	ldaprb	w4, [x5]
        XCTAssertEqual(text(0x38bf_c0a4), "ldaprb w4, [x5]")
        // otool: 0000000000000000	78bfc0e6	ldaprh	w6, [x7]
        XCTAssertEqual(text(0x78bf_c0e6), "ldaprh w6, [x7]")
        // otool: 0000000000000000	d95f0128	ldapur	x8, [x9, #-0x10]
        XCTAssertEqual(text(0xd95f_0128), "ldapur x8, [x9, #-0x10]")
        // otool: 0000000000000000	9940c16a	ldapur	w10, [x11, #0xc]
        XCTAssertEqual(text(0x9940_c16a), "ldapur w10, [x11, #0xc]")
        // otool: 0000000000000000	195f01ac	ldapurb	w12, [x13, #-0x10]
        XCTAssertEqual(text(0x195f_01ac), "ldapurb w12, [x13, #-0x10]")
        // otool: 0000000000000000	594101ee	ldapurh	w14, [x15, #0x10]
        XCTAssertEqual(text(0x5941_01ee), "ldapurh w14, [x15, #0x10]")
        // otool: 0000000000000000	19df0230	ldapursb	w16, [x17, #-0x10]
        XCTAssertEqual(text(0x19df_0230), "ldapursb w16, [x17, #-0x10]")
        // otool: 0000000000000000	19810272	ldapursb	x18, [x19, #0x10]
        XCTAssertEqual(text(0x1981_0272), "ldapursb x18, [x19, #0x10]")
        // otool: 0000000000000000	59df02b4	ldapursh	w20, [x21, #-0x10]
        XCTAssertEqual(text(0x59df_02b4), "ldapursh w20, [x21, #-0x10]")
        // otool: 0000000000000000	598102f6	ldapursh	x22, [x23, #0x10]
        XCTAssertEqual(text(0x5981_02f6), "ldapursh x22, [x23, #0x10]")
        // otool: 0000000000000000	999f0338	ldapursw	x24, [x25, #-0x10]
        XCTAssertEqual(text(0x999f_0338), "ldapursw x24, [x25, #-0x10]")
        // otool: 0000000000000000	d91f037a	stlur	x26, [x27, #-0x10]
        XCTAssertEqual(text(0xd91f_037a), "stlur x26, [x27, #-0x10]")
        // otool: 0000000000000000	990143bc	stlur	w28, [x29, #0x14]
        XCTAssertEqual(text(0x9901_43bc), "stlur w28, [x29, #0x14]")
        // otool: 0000000000000000	191f03fe	stlurb	w30, [sp, #-0x10]
        XCTAssertEqual(text(0x191f_03fe), "stlurb w30, [sp, #-0x10]")
        // otool: 0000000000000000	59010020	stlurh	w0, [x1, #0x10]
        XCTAssertEqual(text(0x5901_0020), "stlurh w0, [x1, #0x10]")
    }

    func testScalarIntegerFPConvertDecodesMatchOtool() {
        // otool: 0000000000000000	1e220020	scvtf	s0, w1
        XCTAssertEqual(text(0x1e22_0020), "scvtf s0, w1")
        // otool: 0000000000000000	1e02c020	scvtf	s0, w1, #0x10
        XCTAssertEqual(text(0x1e02_c020), "scvtf s0, w1, #0x10")
        // otool: 0000000000000000	1e2300a4	ucvtf	s4, w5
        XCTAssertEqual(text(0x1e23_00a4), "ucvtf s4, w5")
        // otool: 0000000000000000	9e43c2f6	ucvtf	d22, x23, #0x10
        XCTAssertEqual(text(0x9e43_c2f6), "ucvtf d22, x23, #0x10")
        // otool: 0000000000000000	1e380128	fcvtzs	w8, s9
        XCTAssertEqual(text(0x1e38_0128), "fcvtzs w8, s9")
        // otool: 0000000000000000	9e58c062	fcvtzs	x2, d3, #0x10
        XCTAssertEqual(text(0x9e58_c062), "fcvtzs x2, d3, #0x10")
        // otool: 0000000000000000	9e7901ee	fcvtzu	x14, d15
        XCTAssertEqual(text(0x9e79_01ee), "fcvtzu x14, d15")
        // otool: 0000000000000000	9e59a3fe	fcvtzu	x30, d31, #0x18
        XCTAssertEqual(text(0x9e59_a3fe), "fcvtzu x30, d31, #0x18")
    }

    func testSIMDShiftImmediateDecodesMatchOtool() {
        // otool: 0000000000000000	4f1a5420	shl.8h	v0, v1, #0xa
        XCTAssertEqual(text(0x4f1a_5420), "shl v0.8h, v1.8h, #0xa")
        // otool: 0000000000000000	4f300462	sshr.4s	v2, v3, #0x10
        XCTAssertEqual(text(0x4f30_0462), "sshr v2.4s, v3.4s, #0x10")
        // otool: 0000000000000000	6f3004a4	ushr.4s	v4, v5, #0x10
        XCTAssertEqual(text(0x6f30_04a4), "ushr v4.4s, v5.4s, #0x10")
        // otool: 0000000000000000	4f3024e6	srshr.4s	v6, v7, #0x10
        XCTAssertEqual(text(0x4f30_24e6), "srshr v6.4s, v7.4s, #0x10")
        // otool: 0000000000000000	6f302528	urshr.4s	v8, v9, #0x10
        XCTAssertEqual(text(0x6f30_2528), "urshr v8.4s, v9.4s, #0x10")
        // otool: 0000000000000000	0f1aa56a	sshll.4s	v10, v11, #0xa
        XCTAssertEqual(text(0x0f1a_a56a), "sshll v10.4s, v11.4h, #0xa")
        // otool: 0000000000000000	4f1aa5ac	sshll2.4s	v12, v13, #0xa
        XCTAssertEqual(text(0x4f1a_a5ac), "sshll2 v12.4s, v13.8h, #0xa")
        // otool: 0000000000000000	2f1aa5ee	ushll.4s	v14, v15, #0xa
        XCTAssertEqual(text(0x2f1a_a5ee), "ushll v14.4s, v15.4h, #0xa")
        // otool: 0000000000000000	6f1aa630	ushll2.4s	v16, v17, #0xa
        XCTAssertEqual(text(0x6f1a_a630), "ushll2 v16.4s, v17.8h, #0xa")
        // otool: 0000000000000000	0f168672	shrn.4h	v18, v19, #0xa
        XCTAssertEqual(text(0x0f16_8672), "shrn v18.4h, v19.4s, #0xa")
        // otool: 0000000000000000	4f1686b4	shrn2.8h	v20, v21, #0xa
        XCTAssertEqual(text(0x4f16_86b4), "shrn2 v20.8h, v21.4s, #0xa")
        // otool: 0000000000000000	6f1a56f6	sli.8h	v22, v23, #0xa
        XCTAssertEqual(text(0x6f1a_56f6), "sli v22.8h, v23.8h, #0xa")
        // otool: 0000000000000000	6f304738	sri.4s	v24, v25, #0x10
        XCTAssertEqual(text(0x6f30_4738), "sri v24.4s, v25.4s, #0x10")
    }

    func testSIMDCompareZeroAndAcrossLanesDecodesMatchOtool() {
        // otool: 0000000000000000	4ea09820	cmeq.4s	v0, v1, #0
        XCTAssertEqual(text(0x4ea0_9820), "cmeq v0.4s, v1.4s, #0")
        // otool: 0000000000000000	6ea08820	cmge.4s	v0, v1, #0
        XCTAssertEqual(text(0x6ea0_8820), "cmge v0.4s, v1.4s, #0")
        // otool: 0000000000000000	4ea08820	cmgt.4s	v0, v1, #0
        XCTAssertEqual(text(0x4ea0_8820), "cmgt v0.4s, v1.4s, #0")
        // otool: 0000000000000000	6ea09820	cmle.4s	v0, v1, #0
        XCTAssertEqual(text(0x6ea0_9820), "cmle v0.4s, v1.4s, #0")
        // otool: 0000000000000000	4ea0a820	cmlt.4s	v0, v1, #0
        XCTAssertEqual(text(0x4ea0_a820), "cmlt v0.4s, v1.4s, #0")
        // otool: 0000000000000000	0e31b820	addv.8b	b0, v1
        XCTAssertEqual(text(0x0e31_b820), "addv b0, v1.8b")
        // otool: 0000000000000000	2e31a820	uminv.8b	b0, v1
        XCTAssertEqual(text(0x2e31_a820), "uminv b0, v1.8b")
        // otool: 0000000000000000	2e30a820	umaxv.8b	b0, v1
        XCTAssertEqual(text(0x2e30_a820), "umaxv b0, v1.8b")
        // otool: 0000000000000000	0e31a820	sminv.8b	b0, v1
        XCTAssertEqual(text(0x0e31_a820), "sminv b0, v1.8b")
        // otool: 0000000000000000	0e30a820	smaxv.8b	b0, v1
        XCTAssertEqual(text(0x0e30_a820), "smaxv b0, v1.8b")
        // otool: 0000000000000000	2e303820	uaddlv.8b	h0, v1
        XCTAssertEqual(text(0x2e30_3820), "uaddlv h0, v1.8b")
        // otool: 0000000000000000	0e303820	saddlv.8b	h0, v1
        XCTAssertEqual(text(0x0e30_3820), "saddlv h0, v1.8b")
    }

    func testSHA512TailDecodesMatchOtool() {
        // otool: 0000000000000000	cec08020	sha512su0.2d	v0, v1
        XCTAssertEqual(text(0xcec0_8020), "sha512su0 v0.2d, v1.2d")
        // otool: 0000000000000000	ce628820	sha512su1.2d	v0, v1, v2
        XCTAssertEqual(text(0xce62_8820), "sha512su1 v0.2d, v1.2d, v2.2d")
        // otool: 0000000000000000	ce628020	sha512h.2d	q0, q1, v2
        XCTAssertEqual(text(0xce62_8020), "sha512h q0, q1, v2.2d")
        // otool: 0000000000000000	ce628420	sha512h2.2d	q0, q1, v2
        XCTAssertEqual(text(0xce62_8420), "sha512h2 q0, q1, v2.2d")
    }

    /// Dispatch-shadowing guard: the new hooks sit near existing LSE/load-store/SIMD/crypto hooks,
    /// so a too-broad mask would swallow valid existing decodes. Confirm neighbors still decode right.
    func testNewHooksDoNotShadowExistingDecodes() {
        // otool: 0000000000000000	b8e20083	ldaddal	w2, w3, [x4]
        XCTAssertEqual(text(0xb8e2_0083), "ldaddal w2, w3, [x4]")
        // otool: 0000000000000000	b8404020	ldur	w0, [x1, #0x4]
        XCTAssertEqual(text(0xb840_4020), "ldur w0, [x1, #4]")
        // otool: 0000000000000000	4f000420	movi.4s	v0, #0x1
        XCTAssertEqual(text(0x4f00_0420), "movi v0.4s, #1")
        // otool: 0000000000000000	4ea28420	add.4s	v0, v1, v2
        XCTAssertEqual(text(0x4ea2_8420), "add v0.4s, v1.4s, v2.4s")
        // otool: 0000000000000000	4e22d420	fadd.4s	v0, v1, v2
        XCTAssertEqual(text(0x4e22_d420), "fadd v0.4s, v1.4s, v2.4s")
        // otool: 0000000000000000	4e080c20	dup.2d	v0, x1
        XCTAssertEqual(text(0x4e08_0c20), "dup v0.2d, x1")
        // otool: 0000000000000000	0e220020	saddl.8h	v0, v1, v2
        XCTAssertEqual(text(0x0e22_0020), "saddl v0.8h, v1.8b, v2.8b")
        // otool: 0000000000000000	ce220020	bcax.16b	v0, v1, v2, v0
        XCTAssertEqual(text(0xce22_0020), "bcax v0.16b, v1.16b, v2.16b, v0.16b")
    }

    /// Regression: the STLUR/LDAPUR dispatch mask must NOT shadow the data-processing 3-source group
    /// (bits[29:24]=011011 — madd/msub/mneg/…). The original mask dropped bit25, so 5 `msub`s in
    /// /bin/ls decoded as `stlur` — caught by the reference-output golden differential, NOT by the
    /// package's own neighbor guards. otool ground truth pinned here so the fix holds hermetically
    /// (without the git-ignored golden captures).
    func testStlurMaskDoesNotShadowDataProcessingThreeSource() {
        // otool: 9b09a148  msub  x8, x10, x9, x8   (the exact /bin/ls instruction that was shadowed)
        XCTAssertEqual(text(0x9b09_a148), "msub x8, x10, x9, x8")
        // otool: 9b0afd6b  mneg  x11, x11, x10
        XCTAssertEqual(text(0x9b0a_fd6b), "mneg x11, x11, x10")
    }

    /// Load/store exclusive + ordered family (ARM C3.2.6) — the atomic/lock primitives. Every
    /// rendering is verbatim `otool -arch arm64 -tv` on a clang-assembled corpus. Shares the
    /// bits[29:24]=0x08 space with CAS/CASP (decoded separately); the whole non-CAS family was
    /// `unknown` before.
    func testLoadStoreExclusiveAndOrderedDecodeMatchOtool() {
        // Ordered non-exclusive: ldar/stlr + byte/half.
        XCTAssertEqual(text(0xc8df_fc20), "ldar x0, [x1]")
        XCTAssertEqual(text(0x08df_fc20), "ldarb w0, [x1]")
        XCTAssertEqual(text(0x48df_fc20), "ldarh w0, [x1]")
        XCTAssertEqual(text(0xc89f_fc20), "stlr x0, [x1]")
        XCTAssertEqual(text(0x089f_fc20), "stlrb w0, [x1]")
        XCTAssertEqual(text(0x489f_fc20), "stlrh w0, [x1]")
        // LOR ordered: stllr/ldlar.
        XCTAssertEqual(text(0xc89f_7c20), "stllr x0, [x1]")
        XCTAssertEqual(text(0xc8df_7c20), "ldlar x0, [x1]")
        // Exclusive single: ldxr/stxr/ldaxr/stlxr (+ a byte variant). Store carries the status Ws.
        XCTAssertEqual(text(0xc85f_7c20), "ldxr x0, [x1]")
        XCTAssertEqual(text(0xc802_7c20), "stxr w2, x0, [x1]")
        XCTAssertEqual(text(0xc85f_fc20), "ldaxr x0, [x1]")
        XCTAssertEqual(text(0xc802_fc20), "stlxr w2, x0, [x1]")
        XCTAssertEqual(text(0x085f_fc20), "ldaxrb w0, [x1]")
        XCTAssertEqual(text(0x0802_fc20), "stlxrb w2, w0, [x1]")
        // Exclusive pair: ldxp/stxp/ldaxp/stlxp (second transfer reg Rt2).
        XCTAssertEqual(text(0xc87f_0440), "ldxp x0, x1, [x2]")
        XCTAssertEqual(text(0xc824_0440), "stxp w4, x0, x1, [x2]")
        XCTAssertEqual(text(0xc87f_8440), "ldaxp x0, x1, [x2]")
        XCTAssertEqual(text(0xc824_8440), "stlxp w4, x0, x1, [x2]")
    }

    func testThreeDifferentIntegerAndRoundingNarrowMatchAppleObjdump() {
        // Real libjpeg-turbo `_jsimd_h2v1_fancy_upsample_neon` words; Apple
        // llvm-objdump: umull.8h v2, v4, v0 / umlal2.8h v2, v4, v1 /
        // umull2.8h v16, v5, v1 / rshrn.8b v16, v3, #0x2 / rshrn2.16b v16, v2, #0x2.
        XCTAssertEqual(text(0x2e20_c082), "umull v2.8h, v4.8b, v0.8b")
        XCTAssertEqual(text(0x6e21_8082), "umlal2 v2.8h, v4.16b, v1.16b")
        XCTAssertEqual(text(0x6e21_c0b0), "umull2 v16.8h, v5.16b, v1.16b")
        XCTAssertEqual(text(0x0f0e_8c70), "rshrn v16.8b, v3.8h, #2")
        XCTAssertEqual(text(0x4f0e_8c50), "rshrn2 v16.16b, v2.8h, #2")
        // One word per integer three-different entry, Q=0 and Q=1; mnemonic
        // and destination arrangement from Apple llvm-objdump (e.g. addhn.8b).
        let table: [(UInt32, String)] = [
            (0x0e22_0020, "saddl v0.8h, v1.8b, v2.8b"),
            (0x4e22_0020, "saddl2 v0.8h, v1.16b, v2.16b"),
            (0x0e22_1020, "saddw v0.8h, v1.8h, v2.8b"),
            (0x4e22_1020, "saddw2 v0.8h, v1.8h, v2.16b"),
            (0x0e22_2020, "ssubl v0.8h, v1.8b, v2.8b"),
            (0x4e22_2020, "ssubl2 v0.8h, v1.16b, v2.16b"),
            (0x0e22_3020, "ssubw v0.8h, v1.8h, v2.8b"),
            (0x4e22_3020, "ssubw2 v0.8h, v1.8h, v2.16b"),
            (0x0e22_4020, "addhn v0.8b, v1.8h, v2.8h"),
            (0x4e22_4020, "addhn2 v0.16b, v1.8h, v2.8h"),
            (0x0e22_5020, "sabal v0.8h, v1.8b, v2.8b"),
            (0x4e22_5020, "sabal2 v0.8h, v1.16b, v2.16b"),
            (0x0e22_6020, "subhn v0.8b, v1.8h, v2.8h"),
            (0x4e22_6020, "subhn2 v0.16b, v1.8h, v2.8h"),
            (0x0e22_7020, "sabdl v0.8h, v1.8b, v2.8b"),
            (0x4e22_7020, "sabdl2 v0.8h, v1.16b, v2.16b"),
            (0x0e22_8020, "smlal v0.8h, v1.8b, v2.8b"),
            (0x4e22_8020, "smlal2 v0.8h, v1.16b, v2.16b"),
            (0x0e22_a020, "smlsl v0.8h, v1.8b, v2.8b"),
            (0x4e22_a020, "smlsl2 v0.8h, v1.16b, v2.16b"),
            (0x0e22_c020, "smull v0.8h, v1.8b, v2.8b"),
            (0x4e22_c020, "smull2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_0020, "uaddl v0.8h, v1.8b, v2.8b"),
            (0x6e22_0020, "uaddl2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_1020, "uaddw v0.8h, v1.8h, v2.8b"),
            (0x6e22_1020, "uaddw2 v0.8h, v1.8h, v2.16b"),
            (0x2e22_2020, "usubl v0.8h, v1.8b, v2.8b"),
            (0x6e22_2020, "usubl2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_3020, "usubw v0.8h, v1.8h, v2.8b"),
            (0x6e22_3020, "usubw2 v0.8h, v1.8h, v2.16b"),
            (0x2e22_4020, "raddhn v0.8b, v1.8h, v2.8h"),
            (0x6e22_4020, "raddhn2 v0.16b, v1.8h, v2.8h"),
            (0x2e22_5020, "uabal v0.8h, v1.8b, v2.8b"),
            (0x6e22_5020, "uabal2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_6020, "rsubhn v0.8b, v1.8h, v2.8h"),
            (0x6e22_6020, "rsubhn2 v0.16b, v1.8h, v2.8h"),
            (0x2e22_7020, "uabdl v0.8h, v1.8b, v2.8b"),
            (0x6e22_7020, "uabdl2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_8020, "umlal v0.8h, v1.8b, v2.8b"),
            (0x6e22_8020, "umlal2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_a020, "umlsl v0.8h, v1.8b, v2.8b"),
            (0x6e22_a020, "umlsl2 v0.8h, v1.16b, v2.16b"),
            (0x2e22_c020, "umull v0.8h, v1.8b, v2.8b"),
            (0x6e22_c020, "umull2 v0.8h, v1.16b, v2.16b")
        ]
        for (word, expected) in table {
            XCTAssertEqual(text(word), expected, String(format: "%08x", word))
        }
        // Saturating doubling and polynomial forms stay conservative.
        XCTAssertEqual(text(0x0e22_9020).split(separator: " ").first, "unknown") // sqdmlal
        XCTAssertEqual(text(0x0e22_e020).split(separator: " ").first, "unknown") // pmull
    }

    func testRejectModifiedImmediateReservedO2() {
        // DP05-C02: dot DP05 Arm-adjudicated LLVM MC minimized disagreements.
        XCTAssertEqual(text(0x0f00_0c00), "unknown 0x0f000c00", "DP05-C02 0x0f000c00")
        XCTAssertEqual(text(0x0f00_2c00), "unknown 0x0f002c00", "DP05-C02 0x0f002c00")
        XCTAssertEqual(text(0x0f00_6c00), "unknown 0x0f006c00", "DP05-C02 0x0f006c00")
        XCTAssertEqual(text(0x0f00_8c00), "unknown 0x0f008c00", "DP05-C02 0x0f008c00")
        XCTAssertEqual(text(0x0f00_ac00), "unknown 0x0f00ac00", "DP05-C02 0x0f00ac00")
        XCTAssertEqual(text(0x2f00_0c00), "unknown 0x2f000c00", "DP05-C02 0x2f000c00")
        XCTAssertEqual(text(0x2f00_2c00), "unknown 0x2f002c00", "DP05-C02 0x2f002c00")
        XCTAssertEqual(text(0x2f00_6c00), "unknown 0x2f006c00", "DP05-C02 0x2f006c00")
        XCTAssertEqual(text(0x2f00_8c00), "unknown 0x2f008c00", "DP05-C02 0x2f008c00")
        XCTAssertEqual(text(0x2f00_ac00), "unknown 0x2f00ac00", "DP05-C02 0x2f00ac00")
        XCTAssertEqual(text(0x4f00_2c00), "unknown 0x4f002c00", "DP05-C02 0x4f002c00")
        XCTAssertEqual(text(0x4f00_4c00), "unknown 0x4f004c00", "DP05-C02 0x4f004c00")
        XCTAssertEqual(text(0x4f00_6c00), "unknown 0x4f006c00", "DP05-C02 0x4f006c00")
        XCTAssertEqual(text(0x4f00_ac00), "unknown 0x4f00ac00", "DP05-C02 0x4f00ac00")
        XCTAssertEqual(text(0x4f00_ec00), "unknown 0x4f00ec00", "DP05-C02 0x4f00ec00")
        XCTAssertEqual(text(0x6f00_2c00), "unknown 0x6f002c00", "DP05-C02 0x6f002c00")
        XCTAssertEqual(text(0x6f00_4c00), "unknown 0x6f004c00", "DP05-C02 0x6f004c00")
        XCTAssertEqual(text(0x6f00_6c00), "unknown 0x6f006c00", "DP05-C02 0x6f006c00")
        XCTAssertEqual(text(0x6f00_ac00), "unknown 0x6f00ac00", "DP05-C02 0x6f00ac00")
        XCTAssertEqual(text(0x6f00_ec00), "unknown 0x6f00ec00", "DP05-C02 0x6f00ec00")
        // Paired allocated encoding: o2=0 remains a valid immediate.
        XCTAssertEqual(text(0x0f00_0400), "movi v0.2s, #0")
    }

    func testDecodeScalarMOVIByteMask() {
        // DP05-C07: dot DP05 Arm-adjudicated LLVM MC minimized disagreements.
        XCTAssertEqual(text(0x2f00_e400), "movi d0, #0", "DP05-C07 0x2f00e400")
        XCTAssertEqual(text(0x2f00_e41f), "movi d31, #0", "DP05-C07 0x2f00e41f")
        XCTAssertEqual(text(0x2f00_e420), "movi d0, #0xff", "DP05-C07 0x2f00e420")
        XCTAssertEqual(text(0x2f00_e43f), "movi d31, #0xff", "DP05-C07 0x2f00e43f")
        XCTAssertEqual(text(0x2f04_e400), "movi d0, #0xff00000000000000", "DP05-C07 0x2f04e400")
        XCTAssertEqual(text(0x2f04_e41f), "movi d31, #0xff00000000000000", "DP05-C07 0x2f04e41f")
        XCTAssertEqual(text(0x2f07_e7e0), "movi d0, #0xffffffffffffffff", "DP05-C07 0x2f07e7e0")
        XCTAssertEqual(text(0x2f07_e7ff), "movi d31, #0xffffffffffffffff", "DP05-C07 0x2f07e7ff")
        // Q=1 keeps the vector destination and the same expanded byte mask.
        XCTAssertEqual(text(0x6f00_e420), "movi v0.2d, #0xff")
    }

    func testDecodeModifiedImmediateMSL() {
        // DP05-C08: dot DP05 Arm-adjudicated LLVM MC minimized disagreements.
        XCTAssertEqual(text(0x0f00_c400), "movi v0.2s, #0, msl #8", "DP05-C08 0x0f00c400")
        XCTAssertEqual(text(0x0f00_d400), "movi v0.2s, #0, msl #16", "DP05-C08 0x0f00d400")
        XCTAssertEqual(text(0x2f00_c400), "mvni v0.2s, #0, msl #8", "DP05-C08 0x2f00c400")
        XCTAssertEqual(text(0x2f00_d400), "mvni v0.2s, #0, msl #16", "DP05-C08 0x2f00d400")
        XCTAssertEqual(text(0x4f00_c400), "movi v0.4s, #0, msl #8", "DP05-C08 0x4f00c400")
        XCTAssertEqual(text(0x4f00_d400), "movi v0.4s, #0, msl #16", "DP05-C08 0x4f00d400")
        XCTAssertEqual(text(0x6f00_c400), "mvni v0.4s, #0, msl #8", "DP05-C08 0x6f00c400")
        XCTAssertEqual(text(0x6f00_d400), "mvni v0.4s, #0, msl #16", "DP05-C08 0x6f00d400")
        // Nonzero immediate and high destination pin operand extraction.
        XCTAssertEqual(text(0x4f00_c63f), "movi v31.4s, #0x11, msl #8")
        XCTAssertEqual(text(0x6f00_d63f), "mvni v31.4s, #0x11, msl #16")
        // o2 remains reserved for the newly supported MSL and scalar forms.
        XCTAssertEqual(text(0x4f00_ce3f), "unknown 0x4f00ce3f")
        XCTAssertEqual(text(0x2f00_ec20), "unknown 0x2f00ec20")
    }
}
