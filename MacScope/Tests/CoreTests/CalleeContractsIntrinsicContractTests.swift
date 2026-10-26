import Foundation
import XCTest
@testable import MacScope

final class CalleeContractsIntrinsicContractTests: XCTestCase {
    private func lift(_ words: [UInt32]) -> MacIRFunction {
        let bytes = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let rows = ARM64Decoder(validateStructuredOperands: true).decode(bytes, baseAddress: 0x1000)
            .map { InstructionRow(decoded: $0) }
        return PseudocodePrinter().buildFunction(functionName: "fixture", startAddress: 0x1000, instructions: rows)
    }

    private func fact(_ function: MacIRFunction) throws -> MacIRIndirectTargetResolution.FunctionPoison {
        try XCTUnwrap(MacIRIndirectTargetResolution.poisonReport(functions: [function],
            functionStarts: [function.startAddress]).functions.first)
    }

    func testFramePairsAndRegisterArithmeticBecomeVisible() throws {
        // stp fp,lr,[sp,#-16]!; mov fp,sp; stp x20,x19,[sp,#-16];
        // ldp x20,x19,[sp,#-16]; cmp x0,x1; csel x2,x3,x4,eq; udiv x5,x6,x7; ret
        let function = lift([0xa9bf7bfd, 0x910003fd, 0xa93f4ff4, 0xa97f4ff4,
                             0xeb01001f, 0x9a840062, 0x9ac708c5, 0xd65f03c0])
        XCTAssertTrue(function.instructions.contains { if case .intrinsic(_, "save_pair", _) = $0.operation { return true }; return false })
        XCTAssertTrue(function.instructions.contains { if case .intrinsic(_, "restore_pair", _) = $0.operation { return true }; return false })
        let result = try fact(function)
        XCTAssertTrue(result.visible, "\(result)")
        XCTAssertTrue(result.unknownIR.isEmpty)
        XCTAssertNil(result.firstFrameEscape)
    }

    func testProvenRestorePairIsFrameRead() throws {
        // No preceding save: the lifter must retain the restore_pair intrinsic.
        let function = lift([0xd10083ff, 0xa9414ff4, 0xd65f03c0])
        XCTAssertTrue(function.instructions.contains { if case .intrinsic(_, "restore_pair", _) = $0.operation { return true }; return false })
        XCTAssertTrue(try fact(function).visible)
    }

    func testSavingFrameAddressStillEscapes() throws {
        // sub sp,sp,#32; add x8,sp,#8; stp x8,x9,[sp,#16]; ret
        let result = try fact(lift([0xd10083ff, 0x910023e8, 0xa90127e8, 0xd65f03c0]))
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.hasEscapedFrameWrite)
        XCTAssertEqual(result.firstFrameEscape?.shape, "arithmetic/copy")
    }

    func testReturningFrameOffsetStillEscapes() throws {
        // stp fp,lr,[sp,#-32]!; mov fp,sp; add x0,sp,#16; ret
        let result = try fact(lift([0xa9be7bfd, 0x910003fd, 0x910043e0, 0xd65f03c0]))
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.hasEscapedFrameWrite)
        XCTAssertEqual(result.firstRejectingReason, "escaped frame")
        // The first escape is the address calculation, before the return.
        XCTAssertEqual(result.firstFrameEscape?.shape, "arithmetic/copy")
    }

    func testReturningSPCopyStillEscapes() throws {
        // stp fp,lr,[sp,#-32]!; mov fp,sp; mov x0,sp; ret
        let result = try fact(lift([0xa9be7bfd, 0x910003fd, 0x910003e0, 0xd65f03c0]))
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.hasEscapedFrameWrite)
        XCTAssertEqual(result.firstRejectingReason, "escaped frame")
        XCTAssertEqual(result.firstFrameEscape?.shape, "arithmetic/copy")
    }

    func testReturningReloadedFrameRecordStillEscapes() throws {
        // stp fp,lr,[sp,#-32]!; mov fp,sp; ldr x0,[sp]; ret
        let result = try fact(lift([0xa9be7bfd, 0x910003fd, 0xf94003e0, 0xd65f03c0]))
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.hasEscapedFrameWrite)
        XCTAssertEqual(result.firstRejectingReason, "escaped frame")
        XCTAssertEqual(result.firstFrameEscape?.shape, "returned")
    }

    func testOtherUnknownReturnAndNestedMarkerStillEscape() throws {
        let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        for value in [MacIRValue.unknown("other_unknown"), .unary(op: "-", value: marker)] {
            var function = lift([0xa9be7bfd, 0x910003fd, 0xd65f03c0])
            function.instructions[2].operation = .returnValue(value)
            let result = try fact(function)
            XCTAssertFalse(result.visible)
            XCTAssertTrue(result.hasEscapedFrameWrite)
            XCTAssertEqual(result.firstFrameEscape?.shape, "returned")
        }
    }

    func testUnresolvedReturnMarkerInCompareStillEscapes() throws {
        var function = lift([0xa9be7bfd, 0x910003fd, 0xeb01001f, 0xd65f03c0])
        function.instructions[2].operation = .intrinsic(destination: nil, name: "compare",
            arguments: [.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker), .immediate(0)])
        let result = try fact(function)
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.hasEscapedFrameWrite)
        XCTAssertEqual(result.firstFrameEscape?.shape, "arithmetic/copy")
    }

    func testRegisterOnlyIntrinsicReadingFrameStillEscapes() throws {
        var function = lift([0xa9bf7bfd, 0x910003fd, 0xeb0003bf, 0xd65f03c0]) // cmp fp,x0
        // Keep an explicit register identity, independent of parameter rewriting.
        function.instructions[2].operation = .intrinsic(destination: nil, name: "compare",
            arguments: [.register(name: "x29", version: 1), .immediate(0)])
        let result = try fact(function)
        XCTAssertFalse(result.visible)
        XCTAssertEqual(result.firstFrameEscape?.shape, "arithmetic/copy")
        XCTAssertTrue(result.unknownIR.isEmpty)
    }

    func testControlMemoryUnknownAndFutureIntrinsicsStayClosed() throws {
        let operations: [MacIROperation] = [
            .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1004)]),
            .intrinsic(destination: nil, name: "branch_register", arguments: [.register(name: "x9", version: 0)]),
            .intrinsic(destination: nil, name: "neon_structure_store", arguments: []),
            .unknown(destination: nil, mnemonic: "opaque", operands: ""),
            .intrinsic(destination: nil, name: "future_register_operation", arguments: [])
        ]
        for operation in operations {
            var function = lift([0xd503201f, 0xd65f03c0])
            function.instructions[0].operation = operation
            let result = try fact(function)
            XCTAssertFalse(result.visible, "\(operation)")
            XCTAssertEqual(result.unknownIR.count, 1, "\(operation)")
        }
    }

    func testNonSPPairStaysUnknown() throws {
        let result = try fact(lift([0xa9000801, 0xd65f03c0])) // stp x1,x2,[x0]
        XCTAssertFalse(result.visible)
        XCTAssertEqual(result.unknownIR.first?.classification.kind, "save_pair")
    }

    func testPairAfterLostSPAuthorityStaysUnknown() throws {
        // An opaque operation still drops entry-SP authority before the pair.
        var function = lift([0xd10083ff, 0xd503201f, 0xa9014ff4, 0xd65f03c0])
        function.instructions[1].operation = .unknown(destination: nil, mnemonic: "opaque", operands: "")
        let result = try fact(function)
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.unknownIR.contains { $0.classification.kind == "save_pair" })
    }

    func testPairAfterAllowlistedCompareIsProvenFrameWrite() throws {
        // sub sp,sp,#32; cmp x0,x1; stp x20,x19,[sp,#16]; ret
        let result = try fact(lift([0xd10083ff, 0xeb01001f, 0xa9014ff4, 0xd65f03c0]))
        XCTAssertTrue(result.visible, "\(result)")
        XCTAssertTrue(result.unknownIR.isEmpty)
        XCTAssertFalse(result.hasNonFrameStore)
        XCTAssertFalse(result.hasEscapedFrameWrite)
    }

    func testRestorePairWithSPDestinationLosesSPAuthority() throws {
        // Express the defensive sp/wsp spelling directly in the IR: an encoded
        // LDP destination register 31 is XZR, not SP.
        for spelling in ["sp", "wsp"] {
            var function = lift([0xd10083ff, 0xa9414ff4, 0xa9014ff4, 0xd65f03c0])
            guard case let .intrinsic(destination, "restore_pair", original) = function.instructions[1].operation else {
                return XCTFail("Expected a lifted non-writeback restore_pair")
            }
            var arguments = original
            arguments[0] = .register(name: spelling, version: 1)
            function.instructions[1].operation = .intrinsic(destination: destination,
                name: "restore_pair", arguments: arguments)
            let result = try fact(function)
            XCTAssertFalse(result.visible, spelling)
            XCTAssertTrue(result.unknownIR.contains { $0.classification.kind == "save_pair" }, spelling)
        }
    }

    func testWritebackRestorePairStillUpdatesSPCoordinate() throws {
        // sub sp,sp,#32; ldp x20,x19,[sp],#32; stp x20,x19,[sp,#16]; ret
        // The restore returns SP to entry SP; the following save is outside the
        // proven frame. Treating writeback as unchanged would admit it instead.
        let function = lift([0xd10083ff, 0xa8c24ff4, 0xa9014ff4, 0xd65f03c0])
        XCTAssertTrue(function.instructions.contains {
            if case .intrinsic(_, "restore_pair_writeback", _) = $0.operation { return true }
            return false
        })
        let result = try fact(function)
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.unknownIR.contains { $0.classification.kind == "save_pair" })
    }
    func testRegisterContractRejectsMemoryMetadata() throws {
        var function = lift([0xeb01001f, 0xd65f03c0])
        function.instructions[0].memoryAccess = MacIRMemoryAccess(byteWidth: 8)
        let result = try fact(function)
        XCTAssertFalse(result.visible)
        XCTAssertEqual(result.unknownIR.first?.classification.kind, "compare")
    }

    func testRegisterOnlyIntrinsicDoesNotCreateLocalMemoryBarrier() {
        let assembly = [("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"),
            ("str", "x9, [x0, #0x18]"), ("cmp", "x1, x2"),
            ("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", "")]
        let rows = assembly.enumerated().map { index, row in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: row.0,
                operands: row.1, hasBreakpoint: false, comment: nil)
        }
        let function = PseudocodePrinter().buildFunction(functionName: "local", startAddress: 0x1000, instructions: rows)
        let report = MacIRIndirectTargetResolution.resolve(functions: [function], functionStarts: [0x9040])
        XCTAssertEqual(report.resolutions.first?.target, 0x9040)
        XCTAssertTrue(report.refusals.isEmpty)
    }

    func testEveryAllowlistedNameIsEmittedWithoutMemoryAccess() throws {
        let fixtures: [(String, [(String, String)])] = [
            ("a64_fp_add_f32_f32_nearestEven_0", [("fadd", "s0, s1, s2")]),
            ("a64_fp_fromInteger_i32_f32_nearestEven_0", [("scvtf", "s0, w1")]),
            ("a64_fp_fusedMultiplyAdd_f32_f32_nearestEven_0", [("fmadd", "s0, s1, s2, s3")]),
            ("a64_fp_multiply_f32_f32_nearestEven_0", [("fmul", "s0, s1, s2")]),
            ("a64_fp_negatedFusedMultiplySubtract_f32_f32_nearestEven_0", [("fnmsub", "s0, s1, s2, s3")]),
            ("a64_fp_subtract_f32_f32_nearestEven_0", [("fsub", "s0, s1, s2")]),
            ("a64_fp_toInteger_f32_i32_towardZero_0", [("fcvtzs", "w0, s1")]),
            ("a64_sdiv32", [("sdiv", "w0, w1, w2")]),
            ("a64_sdiv64", [("sdiv", "x0, x1, x2")]),
            ("a64_srem32", [("sdiv", "w3, w1, w2"), ("msub", "w0, w3, w2, w1")]),
            ("a64_srem64", [("sdiv", "x3, x1, x2"), ("msub", "x0, x3, x2, x1")]),
            ("a64_udiv32", [("udiv", "w0, w1, w2")]),
            ("a64_udiv64", [("udiv", "x0, x1, x2")]),
            ("a64_urem32", [("udiv", "w3, w1, w2"), ("msub", "w0, w3, w2, w1")]),
            ("a64_urem64", [("udiv", "x3, x1, x2"), ("msub", "x0, x3, x2, x1")]),
            ("clz", [("clz", "x0, x1")]),
            ("compare", [("cmp", "x1, x2")]),
            ("conditional_compare_al", [("ccmp", "x1, x2, #0, al")]),
            ("conditional_compare_cc", [("ccmp", "x1, x2, #0, cc")]),
            ("conditional_compare_cs", [("ccmp", "x1, x2, #0, cs")]),
            ("conditional_compare_eq", [("ccmp", "x1, x2, #0, eq")]),
            ("conditional_compare_ge", [("ccmp", "x1, x2, #0, ge")]),
            ("conditional_compare_gt", [("ccmp", "x1, x2, #0, gt")]),
            ("conditional_compare_hi", [("ccmp", "x1, x2, #0, hi")]),
            ("conditional_compare_hs", [("ccmp", "x1, x2, #0, hs")]),
            ("conditional_compare_le", [("ccmp", "x1, x2, #0, le")]),
            ("conditional_compare_lo", [("ccmp", "x1, x2, #0, lo")]),
            ("conditional_compare_ls", [("ccmp", "x1, x2, #0, ls")]),
            ("conditional_compare_lt", [("ccmp", "x1, x2, #0, lt")]),
            ("conditional_compare_mi", [("ccmp", "x1, x2, #0, mi")]),
            ("conditional_compare_ne", [("ccmp", "x1, x2, #0, ne")]),
            ("conditional_compare_nv", [("ccmp", "x1, x2, #0, nv")]),
            ("conditional_compare_pl", [("ccmp", "x1, x2, #0, pl")]),
            ("conditional_compare_vc", [("ccmp", "x1, x2, #0, vc")]),
            ("conditional_compare_vs", [("ccmp", "x1, x2, #0, vs")]),
            ("crc32b", [("crc32b", "w0, w1, w2")]),
            ("crc32cb", [("crc32cb", "w0, w1, w2")]),
            ("crc32ch", [("crc32ch", "w0, w1, w2")]),
            ("crc32cw", [("crc32cw", "w0, w1, w2")]),
            ("crc32cx", [("crc32cx", "w0, w1, x2")]),
            ("crc32h", [("crc32h", "w0, w1, w2")]),
            ("crc32w", [("crc32w", "w0, w1, w2")]),
            ("crc32x", [("crc32x", "w0, w1, x2")]),
            ("fjcvtzs", [("fjcvtzs", "w0, d1")]),
            ("fmov", [("fmov", "x0, d1")]),
            ("neon_abs_8h", [("abs", "v0.8h, v1.8h")]),
            ("neon_add_4h_zero_high64", [("add", "v0.4h, v1.4h, v2.4h")]),
            ("neon_add_4s", [("add", "v0.4s, v1.4s, v2.4s")]),
            ("neon_add_8h", [("add", "v0.8h, v1.8h, v2.8h")]),
            ("neon_and_16b_zero_upper", [("and", "v0.16b, v1.16b, v2.16b")]),
            ("neon_and_8b_zero_upper", [("and", "v0.8b, v1.8b, v2.8b")]),
            ("neon_bic_16b_zero_upper", [("bic", "v0.16b, v1.16b, v2.16b")]),
            ("neon_bic_8b_zero_upper", [("bic", "v0.8b, v1.8b, v2.8b")]),
            ("neon_cmeqz_8h", [("cmeq", "v0.8h, v1.8h, #0")]),
            ("neon_cmltz_8h", [("cmlt", "v0.8h, v1.8h, #0")]),
            ("neon_dup_4h_zero_high64", [("dup", "v0.4h, w1")]),
            ("neon_dup_4s", [("dup", "v0.4s, w1")]),
            ("neon_dup_8b_zero_high64", [("dup", "v0.8b, w1")]),
            ("neon_dup_8h", [("dup", "v0.8h, w1")]),
            ("neon_eor_16b_zero_upper", [("eor", "v0.16b, v1.16b, v2.16b")]),
            ("neon_eor_8b_zero_upper", [("eor", "v0.8b, v1.8b, v2.8b")]),
            ("neon_integer_constant", [("movi", "v0.16b, #1")]),
            ("neon_mla_4s", [("mla", "v0.4s, v1.4s, v2.4s")]),
            ("neon_mla_8h", [("mla", "v0.8h, v1.8h, v2.8h")]),
            ("neon_mul_4h_zero_high64", [("mul", "v0.4h, v1.4h, v2.4h")]),
            ("neon_mul_4s", [("mul", "v0.4s, v1.4s, v2.4s")]),
            ("neon_neg_8h", [("neg", "v0.8h, v1.8h")]),
            ("neon_not_16b", [("mvn", "v0.16b, v1.16b")]),
            ("neon_orn_16b_zero_upper", [("orn", "v0.16b, v1.16b, v2.16b")]),
            ("neon_orn_8b_zero_upper", [("orn", "v0.8b, v1.8b, v2.8b")]),
            ("neon_orr_16b_zero_upper", [("orr", "v0.16b, v1.16b, v2.16b")]),
            ("neon_orr_8b_zero_upper", [("orr", "v0.8b, v1.8b, v2.8b")]),
            ("neon_rshrn2_16b_from_8h_shift2_keep_low64", [("rshrn2", "v0.16b, v1.8h, #2")]),
            ("neon_rshrn2_16b_from_8h_shift4_keep_low64", [("rshrn2", "v0.16b, v1.8h, #4")]),
            ("neon_rshrn2_8h_from_4s_shift11_keep_low64", [("rshrn2", "v0.8h, v1.4s, #11")]),
            ("neon_rshrn2_8h_from_4s_shift15_keep_low64", [("rshrn2", "v0.8h, v1.4s, #15")]),
            ("neon_rshrn2_8h_from_4s_shift2_keep_low64", [("rshrn2", "v0.8h, v1.4s, #2")]),
            ("neon_rshrn_4h_from_4s_shift11_zero_high64", [("rshrn", "v0.4h, v1.4s, #11")]),
            ("neon_rshrn_4h_from_4s_shift15_zero_high64", [("rshrn", "v0.4h, v1.4s, #15")]),
            ("neon_rshrn_4h_from_4s_shift2_zero_high64", [("rshrn", "v0.4h, v1.4s, #2")]),
            ("neon_rshrn_8b_from_8h_shift2_zero_high64", [("rshrn", "v0.8b, v1.8h, #2")]),
            ("neon_rshrn_8b_from_8h_shift4_zero_high64", [("rshrn", "v0.8b, v1.8h, #4")]),
            ("neon_saddl2_4s_from_8h", [("saddl2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_saddl_4s_from_4h", [("saddl", "v0.4s, v1.4h, v2.4h")]),
            ("neon_saddw_4s_from_4s_4h", [("saddw", "v0.4s, v1.4s, v2.4h")]),
            ("neon_shl_4h_shift2_zero_high64", [("shl", "v0.4h, v1.4h, #2")]),
            ("neon_shl_8h_shift2", [("shl", "v0.8h, v1.8h, #2")]),
            ("neon_shrn2_16b_from_8h_shift2_keep_low64", [("shrn2", "v0.16b, v1.8h, #2")]),
            ("neon_shrn2_16b_from_8h_shift4_keep_low64", [("shrn2", "v0.16b, v1.8h, #4")]),
            ("neon_shrn2_8h_from_4s_shift15_keep_low64", [("shrn2", "v0.8h, v1.4s, #15")]),
            ("neon_shrn_4h_from_4s_shift15_zero_high64", [("shrn", "v0.4h, v1.4s, #15")]),
            ("neon_shrn_8b_from_8h_shift1_zero_high64", [("shrn", "v0.8b, v1.8h, #1")]),
            ("neon_shrn_8b_from_8h_shift2_zero_high64", [("shrn", "v0.8b, v1.8h, #2")]),
            ("neon_shrn_8b_from_8h_shift4_zero_high64", [("shrn", "v0.8b, v1.8h, #4")]),
            ("neon_smlal2_4s_from_8h_by_lane0", [("smlal2", "v0.4s, v1.8h, v2.h[0]")]),
            ("neon_smlal2_4s_from_8h_by_lane1", [("smlal2", "v0.4s, v1.8h, v2.h[1]")]),
            ("neon_smlal2_4s_from_8h_by_lane2", [("smlal2", "v0.4s, v1.8h, v2.h[2]")]),
            ("neon_smlal2_4s_from_8h_by_lane3", [("smlal2", "v0.4s, v1.8h, v2.h[3]")]),
            ("neon_smlal_4s_from_4h_by_lane0", [("smlal", "v0.4s, v1.4h, v2.h[0]")]),
            ("neon_smlal_4s_from_4h_by_lane1", [("smlal", "v0.4s, v1.4h, v2.h[1]")]),
            ("neon_smlal_4s_from_4h_by_lane2", [("smlal", "v0.4s, v1.4h, v2.h[2]")]),
            ("neon_smlal_4s_from_4h_by_lane3", [("smlal", "v0.4s, v1.4h, v2.h[3]")]),
            ("neon_smlsl2_4s_from_8h", [("smlsl2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_smlsl_4s_from_4h", [("smlsl", "v0.4s, v1.4h, v2.4h")]),
            ("neon_smlsl_4s_from_4h_by_lane0", [("smlsl", "v0.4s, v1.4h, v2.h[0]")]),
            ("neon_smlsl_4s_from_4h_by_lane1", [("smlsl", "v0.4s, v1.4h, v2.h[1]")]),
            ("neon_smlsl_4s_from_4h_by_lane2", [("smlsl", "v0.4s, v1.4h, v2.h[2]")]),
            ("neon_smull2_4s_from_8h", [("smull2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_smull2_4s_from_8h_by_lane0", [("smull2", "v0.4s, v1.8h, v2.h[0]")]),
            ("neon_smull2_4s_from_8h_by_lane1", [("smull2", "v0.4s, v1.8h, v2.h[1]")]),
            ("neon_smull2_4s_from_8h_by_lane2", [("smull2", "v0.4s, v1.8h, v2.h[2]")]),
            ("neon_smull2_4s_from_8h_by_lane3", [("smull2", "v0.4s, v1.8h, v2.h[3]")]),
            ("neon_smull_4s_from_4h", [("smull", "v0.4s, v1.4h, v2.4h")]),
            ("neon_smull_4s_from_4h_by_lane0", [("smull", "v0.4s, v1.4h, v2.h[0]")]),
            ("neon_smull_4s_from_4h_by_lane1", [("smull", "v0.4s, v1.4h, v2.h[1]")]),
            ("neon_smull_4s_from_4h_by_lane2", [("smull", "v0.4s, v1.4h, v2.h[2]")]),
            ("neon_smull_4s_from_4h_by_lane3", [("smull", "v0.4s, v1.4h, v2.h[3]")]),
            ("neon_sqdmulh_8h_by_lane0", [("sqdmulh", "v0.8h, v1.8h, v2.h[0]")]),
            ("neon_sqdmulh_8h_by_lane1", [("sqdmulh", "v0.8h, v1.8h, v2.h[1]")]),
            ("neon_sqdmulh_8h_by_lane2", [("sqdmulh", "v0.8h, v1.8h, v2.h[2]")]),
            ("neon_sqdmulh_8h_by_lane3", [("sqdmulh", "v0.8h, v1.8h, v2.h[3]")]),
            ("neon_sqrdmulh_8h_by_lane2", [("sqrdmulh", "v0.8h, v1.8h, v2.h[2]")]),
            ("neon_sqrdmulh_8h_by_lane3", [("sqrdmulh", "v0.8h, v1.8h, v2.h[3]")]),
            ("neon_sqxtun2_16b_from_8h_keep_low64", [("sqxtun2", "v0.16b, v1.8h")]),
            ("neon_sqxtun_8b_from_8h_zero_high64", [("sqxtun", "v0.8b, v1.8h")]),
            ("neon_srshr_8h_shift2", [("srshr", "v0.8h, v1.8h, #2")]),
            ("neon_sshll2_2d_from_4s_shift0", [("sshll2", "v0.2d, v1.4s, #0")]),
            ("neon_sshll_2d_from_2s_shift0", [("sshll", "v0.2d, v1.2s, #0")]),
            ("neon_sshll_4s_from_4h_shift13", [("sshll", "v0.4s, v1.4h, #13")]),
            ("neon_ssubl2_4s_from_8h", [("ssubl2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_ssubl_4s_from_4h", [("ssubl", "v0.4s, v1.4h, v2.4h")]),
            ("neon_sub_4h_zero_high64", [("sub", "v0.4h, v1.4h, v2.4h")]),
            ("neon_sub_4s", [("sub", "v0.4s, v1.4s, v2.4s")]),
            ("neon_sub_8h", [("sub", "v0.8h, v1.8h, v2.8h")]),
            ("neon_trn1_4s", [("trn1", "v0.4s, v1.4s, v2.4s")]),
            ("neon_trn1_8h", [("trn1", "v0.8h, v1.8h, v2.8h")]),
            ("neon_trn2_4s", [("trn2", "v0.4s, v1.4s, v2.4s")]),
            ("neon_trn2_8h", [("trn2", "v0.8h, v1.8h, v2.8h")]),
            ("neon_uaddw2_8h_from_8h_16b", [("uaddw2", "v0.8h, v1.8h, v2.16b")]),
            ("neon_uaddw_8h_from_8h_8b", [("uaddw", "v0.8h, v1.8h, v2.8b")]),
            ("neon_umlal2_4s_from_8h", [("umlal2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_umlal2_8h_from_16b", [("umlal2", "v0.8h, v1.16b, v2.16b")]),
            ("neon_umlal_4s_from_4h", [("umlal", "v0.4s, v1.4h, v2.4h")]),
            ("neon_umlsl2_4s_from_8h", [("umlsl2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_umlsl_4s_from_4h", [("umlsl", "v0.4s, v1.4h, v2.4h")]),
            ("neon_umull2_4s_from_8h", [("umull2", "v0.4s, v1.8h, v2.8h")]),
            ("neon_umull2_8h_from_16b", [("umull2", "v0.8h, v1.16b, v2.16b")]),
            ("neon_umull_4s_from_4h", [("umull", "v0.4s, v1.4h, v2.4h")]),
            ("neon_umull_8h_from_8b", [("umull", "v0.8h, v1.8b, v2.8b")]),
            ("neon_ushl_8h", [("ushl", "v0.8h, v1.8h, v2.8h")]),
            ("neon_ushll2_8h_from_16b_shift0", [("ushll2", "v0.8h, v1.16b, #0")]),
            ("neon_ushll_8h_from_8b_shift0", [("ushll", "v0.8h, v1.8b, #0")]),
            ("neon_uzp1_16b", [("uzp1", "v0.16b, v1.16b, v2.16b")]),
            ("neon_uzp1_8b_zero_high64", [("uzp1", "v0.8b, v1.8b, v2.8b")]),
            ("neon_uzp1_8h", [("uzp1", "v0.8h, v1.8h, v2.8h")]),
            ("neon_uzp2_8h", [("uzp2", "v0.8h, v1.8h, v2.8h")]),
            ("neon_zip1_16b", [("zip1", "v0.16b, v1.16b, v2.16b")]),
            ("neon_zip1_4s", [("zip1", "v0.4s, v1.4s, v2.4s")]),
            ("neon_zip1_8b_zero_high64", [("zip1", "v0.8b, v1.8b, v2.8b")]),
            ("neon_zip2_4s", [("zip2", "v0.4s, v1.4s, v2.4s")]),
            ("neon_zip2_8b_zero_high64", [("zip2", "v0.8b, v1.8b, v2.8b")]),
            ("rbit", [("rbit", "x0, x1")]),
            ("rev", [("rev", "x0, x1")]),
            ("rev16", [("rev16", "x0, x1")]),
            ("rev32", [("rev32", "x0, x1")]),
            ("smulh", [("smulh", "x0, x1, x2")]),
            ("umulh", [("umulh", "x0, x1, x2")]),
        ]
        XCTAssertEqual(Set(fixtures.map { $0.0 }), MacIRIndirectTargetResolution.Facts.registerOnlyIntrinsics)
        for (name, assembly) in fixtures {
            let rows = (assembly + [("ret", "")]).enumerated().map { index, pair in
                InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                    operands: pair.1, hasBreakpoint: false, comment: nil)
            }
            let function = PseudocodePrinter().buildFunction(functionName: "emission", startAddress: 0x1000,
                instructions: rows)
            let emitted = function.instructions.filter {
                if case let .intrinsic(_, actual, _) = $0.operation { return actual == name }
                return false
            }
            XCTAssertFalse(emitted.isEmpty, "No lifter emission for \(name): \(assembly)")
            for instruction in emitted {
                XCTAssertNil(instruction.memoryAccess, name)
                let isolated = MacIRFunction(name: "isolated", startAddress: instruction.source.address,
                    instructions: [instruction])
                let facts = MacIRIndirectTargetResolution.Facts(function: isolated, functionStarts: [])
                XCTAssertFalse(facts.hasUnsupportedWrite, name)
                XCTAssertFalse(facts.hasConflictingWrite(to: .init(parameter: 0, components: [0])), name)
            }
        }
    }

}
