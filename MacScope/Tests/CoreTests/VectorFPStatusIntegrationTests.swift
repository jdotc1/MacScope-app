import Foundation
import XCTest
@testable import MacScope

final class VectorFPStatusIntegrationTests: XCTestCase {
    // Every109 unique retained FP word. Expected shape is independently retained
    // assembly evidence; each line cites its Arm2025-12 operation section.
    private let witnesses: [(String, String, String, MacIRVectorFP.Operation, Int, Int, Int, Bool, Int?)] = [
        ("21 68 61 0e", "fcvtn", "v1.2s, v1.2d", .narrow, 64, 32, 2, false, nil), // fcvtn_advsimd.xml#Operation
        ("42 68 61 0e", "fcvtn", "v2.2s, v2.2d", .narrow, 64, 32, 2, false, nil), // fcvtn_advsimd.xml#Operation
        ("42 d4 20 4e", "fadd", "v2.4s, v2.4s, v0.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("63 d4 20 4e", "fadd", "v3.4s, v3.4s, v0.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("44 cc 21 4e", "fmla", "v4.4s, v2.4s, v1.4s", .fusedMultiplyAdd, 32, 32, 4, false, nil), // fmla_advsimd_vec.xml#Operation
        ("01 d4 21 4e", "fadd", "v1.4s, v0.4s, v1.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("02 d4 21 4e", "fadd", "v2.4s, v0.4s, v1.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("21 d8 21 4e", "scvtf", "v1.4s, v1.4s", .fromSignedInteger, 32, 32, 4, false, nil), // scvtf_advsimd_int.xml#Operation
        ("42 d8 21 4e", "scvtf", "v2.4s, v2.4s", .fromSignedInteger, 32, 32, 4, false, nil), // scvtf_advsimd_int.xml#Operation
        ("a7 cc 22 4e", "fmla", "v7.4s, v5.4s, v2.4s", .fusedMultiplyAdd, 32, 32, 4, false, nil), // fmla_advsimd_vec.xml#Operation
        ("84 d4 22 4e", "fadd", "v4.4s, v4.4s, v2.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("23 d4 23 4e", "fadd", "v3.4s, v1.4s, v3.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("24 d4 23 4e", "fadd", "v4.4s, v1.4s, v3.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("40 d4 24 4e", "fadd", "v0.4s, v2.4s, v4.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("47 d4 24 4e", "fadd", "v7.4s, v2.4s, v4.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("e7 d4 24 4e", "fadd", "v7.4s, v7.4s, v4.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("56 cc 25 4e", "fmla", "v22.4s, v2.4s, v5.4s", .fusedMultiplyAdd, 32, 32, 4, false, nil), // fmla_advsimd_vec.xml#Operation
        ("62 d4 25 4e", "fadd", "v2.4s, v3.4s, v5.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("66 d4 25 4e", "fadd", "v6.4s, v3.4s, v5.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("d1 d4 25 4e", "fadd", "v17.4s, v6.4s, v5.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("25 d6 25 4e", "fadd", "v5.4s, v17.4s, v5.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("90 d4 26 4e", "fadd", "v16.4s, v4.4s, v6.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("64 d6 26 4e", "fadd", "v4.4s, v19.4s, v6.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("01 d4 27 4e", "fadd", "v1.4s, v0.4s, v7.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("90 d4 27 4e", "fadd", "v16.4s, v4.4s, v7.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("b0 d4 27 4e", "fadd", "v16.4s, v5.4s, v7.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("06 d6 27 4e", "fadd", "v6.4s, v16.4s, v7.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("75 cc 30 4e", "fmla", "v21.4s, v3.4s, v16.4s", .fusedMultiplyAdd, 32, 32, 4, false, nil), // fmla_advsimd_vec.xml#Operation
        ("47 d4 30 4e", "fadd", "v7.4s, v2.4s, v16.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("d0 d4 30 4e", "fadd", "v16.4s, v6.4s, v16.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("11 d6 31 4e", "fadd", "v17.4s, v16.4s, v17.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("33 d6 32 4e", "fadd", "v19.4s, v17.4s, v18.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("92 d6 32 4e", "fadd", "v18.4s, v20.4s, v18.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("f4 d4 33 4e", "fadd", "v20.4s, v7.4s, v19.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("92 d4 34 4e", "fadd", "v18.4s, v4.4s, v20.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("34 d6 35 4e", "fadd", "v20.4s, v17.4s, v21.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("a6 d4 36 4e", "fadd", "v6.4s, v5.4s, v22.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("b4 d4 36 4e", "fadd", "v20.4s, v5.4s, v22.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("a7 d6 37 4e", "fadd", "v7.4s, v21.4s, v23.4s", .add, 32, 32, 4, false, nil), // fadd_advsimd.xml#Operation
        ("02 68 61 4e", "fcvtn2", "v2.4s, v0.2d", .narrow, 64, 32, 2, true, nil), // fcvtn_advsimd.xml#Operation
        ("61 68 61 4e", "fcvtn2", "v1.4s, v3.2d", .narrow, 64, 32, 2, true, nil), // fcvtn_advsimd.xml#Operation
        ("42 b8 a1 4e", "fcvtzs", "v2.4s, v2.4s", .toSignedInteger, 32, 32, 4, false, nil), // fcvtzs_advsimd_int.xml#Operation
        ("63 b8 a1 4e", "fcvtzs", "v3.4s, v3.4s", .toSignedInteger, 32, 32, 4, false, nil), // fcvtzs_advsimd_int.xml#Operation
        ("00 d4 a1 4e", "fsub", "v0.4s, v0.4s, v1.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("44 d4 a1 4e", "fsub", "v4.4s, v2.4s, v1.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("21 d4 a3 4e", "fsub", "v1.4s, v1.4s, v3.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("40 d4 a4 4e", "fsub", "v0.4s, v2.4s, v4.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("42 d4 a4 4e", "fsub", "v2.4s, v2.4s, v4.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("63 d4 a5 4e", "fsub", "v3.4s, v3.4s, v5.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("c5 d4 a5 4e", "fsub", "v5.4s, v6.4s, v5.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("84 d4 a6 4e", "fsub", "v4.4s, v4.4s, v6.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("66 d6 a6 4e", "fsub", "v6.4s, v19.4s, v6.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("00 d4 a7 4e", "fsub", "v0.4s, v0.4s, v7.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("84 d4 a7 4e", "fsub", "v4.4s, v4.4s, v7.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("a5 d4 a7 4e", "fsub", "v5.4s, v5.4s, v7.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("42 d4 b0 4e", "fsub", "v2.4s, v2.4s, v16.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("b5 d4 b0 4e", "fsub", "v21.4s, v5.4s, v16.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("e6 d4 b0 4e", "fsub", "v6.4s, v7.4s, v16.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("31 d6 b2 4e", "fsub", "v17.4s, v17.4s, v18.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("e7 d4 b3 4e", "fsub", "v7.4s, v7.4s, v19.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("84 d4 b4 4e", "fsub", "v4.4s, v4.4s, v20.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("53 d6 b4 4e", "fsub", "v19.4s, v18.4s, v20.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("27 d6 b5 4e", "fsub", "v7.4s, v17.4s, v21.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("a5 d4 b6 4e", "fsub", "v5.4s, v5.4s, v22.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("b0 d6 b7 4e", "fsub", "v16.4s, v21.4s, v23.4s", .subtract, 32, 32, 4, false, nil), // fsub_advsimd.xml#Operation
        ("21 90 c0 4f", "fmul", "v1.2d, v1.2d, v0.d[0]", .multiply, 64, 64, 2, false, 0), // fmul_advsimd_elt.xml#Operation
        ("42 90 c0 4f", "fmul", "v2.2d, v2.2d, v0.d[0]", .multiply, 64, 64, 2, false, 0), // fmul_advsimd_elt.xml#Operation
        ("60 90 c0 4f", "fmul", "v0.2d, v3.2d, v0.d[0]", .multiply, 64, 64, 2, false, 0), // fmul_advsimd_elt.xml#Operation
        ("84 90 c0 4f", "fmul", "v4.2d, v4.2d, v0.d[0]", .multiply, 64, 64, 2, false, 0), // fmul_advsimd_elt.xml#Operation
        ("e7 dc 20 6e", "fmul", "v7.4s, v7.4s, v0.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("25 de 20 6e", "fmul", "v5.4s, v17.4s, v0.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("b5 de 21 6e", "fmul", "v21.4s, v21.4s, v1.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("42 dc 24 6e", "fmul", "v2.4s, v2.4s, v4.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("63 dc 25 6e", "fmul", "v3.4s, v3.4s, v5.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("84 dc 25 6e", "fmul", "v4.4s, v4.4s, v5.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("61 dc 26 6e", "fmul", "v1.4s, v3.4s, v6.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("84 dc 26 6e", "fmul", "v4.4s, v4.4s, v6.4s", .multiply, 32, 32, 4, false, nil), // fmul_advsimd_vec.xml#Operation
        ("80 fc 60 6e", "fdiv", "v0.2d, v4.2d, v0.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("60 fe 60 6e", "fdiv", "v0.2d, v19.2d, v0.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("21 d8 61 6e", "ucvtf", "v1.2d, v1.2d", .fromUnsignedInteger, 64, 64, 2, false, nil), // ucvtf_advsimd_int.xml#Operation
        ("42 d8 61 6e", "ucvtf", "v2.2d, v2.2d", .fromUnsignedInteger, 64, 64, 2, false, nil), // ucvtf_advsimd_int.xml#Operation
        ("63 d8 61 6e", "ucvtf", "v3.2d, v3.2d", .fromUnsignedInteger, 64, 64, 2, false, nil), // ucvtf_advsimd_int.xml#Operation
        ("84 d8 61 6e", "ucvtf", "v4.2d, v4.2d", .fromUnsignedInteger, 64, 64, 2, false, nil), // ucvtf_advsimd_int.xml#Operation
        ("81 fc 61 6e", "fdiv", "v1.2d, v4.2d, v1.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("61 fe 61 6e", "fdiv", "v1.2d, v19.2d, v1.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("82 fc 62 6e", "fdiv", "v2.2d, v4.2d, v2.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("62 fe 62 6e", "fdiv", "v2.2d, v19.2d, v2.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("00 dc 63 6e", "fmul", "v0.2d, v0.2d, v3.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("83 dc 63 6e", "fmul", "v3.2d, v4.2d, v3.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("83 fc 63 6e", "fdiv", "v3.2d, v4.2d, v3.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("63 fe 63 6e", "fdiv", "v3.2d, v19.2d, v3.2d", .divide, 64, 64, 2, false, nil), // fdiv_advsimd.xml#Operation
        ("00 dc 64 6e", "fmul", "v0.2d, v0.2d, v4.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("21 dc 64 6e", "fmul", "v1.2d, v1.2d, v4.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("42 dc 64 6e", "fmul", "v2.2d, v2.2d, v4.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("63 dc 64 6e", "fmul", "v3.2d, v3.2d, v4.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("00 dc 65 6e", "fmul", "v0.2d, v0.2d, v5.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("21 dc 65 6e", "fmul", "v1.2d, v1.2d, v5.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("42 dc 65 6e", "fmul", "v2.2d, v2.2d, v5.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("00 dc 66 6e", "fmul", "v0.2d, v0.2d, v6.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("42 dc 66 6e", "fmul", "v2.2d, v2.2d, v6.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("42 dc 67 6e", "fmul", "v2.2d, v2.2d, v7.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("83 dc 67 6e", "fmul", "v3.2d, v4.2d, v7.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("21 dc 70 6e", "fmul", "v1.2d, v1.2d, v16.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("83 dc 70 6e", "fmul", "v3.2d, v4.2d, v16.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("21 dc 71 6e", "fmul", "v1.2d, v1.2d, v17.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("00 dc 72 6e", "fmul", "v0.2d, v0.2d, v18.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("21 dc 72 6e", "fmul", "v1.2d, v1.2d, v18.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("42 dc 72 6e", "fmul", "v2.2d, v2.2d, v18.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
        ("63 dc 72 6e", "fmul", "v3.2d, v3.2d, v18.2d", .multiply, 64, 64, 2, false, nil), // fmul_advsimd_vec.xml#Operation
    ]
    private func row(_ bytes: String, _ mnemonic: String, _ operands: String, _ address: UInt64 = 0x1000) -> InstructionRow {
        .init(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil)
    }
    private func source(_ row: InstructionRow) -> MacIRSourceSpan {
        .init(address: row.address, byteText: row.bytes, mnemonic: row.mnemonic, operands: row.operands, comment: nil)
    }
    func testEveryRetainedEncodingHasTypedNormalNumericAndStatusOutputs() throws {
        XCTAssertEqual(witnesses.count, 109)
        for witness in witnesses {
            let input = row(witness.0, witness.1, witness.2)
            let span = source(input)
            let semantics = try XCTUnwrap(MacIRVectorFP(source: span), witness.2)
            XCTAssertEqual(semantics.operation, witness.3)
            XCTAssertEqual(semantics.inputBits, witness.4)
            XCTAssertEqual(semantics.resultBits, witness.5)
            XCTAssertEqual(semantics.laneCount, witness.6)
            XCTAssertEqual(semantics.highHalf, witness.7)
            XCTAssertEqual(semantics.selectedElement, witness.8)
            XCTAssertEqual(semantics.completion, .normalOnlyMayTrap)
            XCTAssertEqual(semantics.rounding, witness.1 == "fcvtzs" ? .instructionTowardZero : .fpcr)
            var state = BuilderState(parameters: [])
            state.permitsNEONBufferCarrier = true
            let control = MacIRValue.unknown("entry_fpcr")
            let status = MacIRValue.unknown("entry_fp_exceptions")
            let output = MacIRValue.register(name: "fpsr_exception_bits", version: 1)
            let effects = MacIRBuilder.liftVectorFP(semantics, source: span, state: &state,
                fpcr: control, exceptions: status, exceptionOutput: output)
            XCTAssertEqual(effects.count, 2)
            let numeric = try XCTUnwrap(effects[0].vectorFP)
            let flags = try XCTUnwrap(effects[1].vectorFPStatus)
            XCTAssertEqual(numeric, flags)
            XCTAssertEqual(numeric.fpcrInput, control)
            XCTAssertEqual(numeric.exceptionInput, status)
            XCTAssertEqual(numeric.exceptionOutput, output)
            XCTAssertEqual(numeric.semantics.exceptionMask, 0x9f)
            XCTAssertEqual(numeric.trapCondition.enableBitOffset, 8)
            XCTAssertEqual(numeric.trapCondition.exceptionMask, 0x9f)
            XCTAssertTrue(numeric.trapCondition.accessMayTrapIndependently)
            XCTAssertEqual(numeric.trapCondition.enableGate, "notSME_or_notStreaming_or_fullA64")
            XCTAssertNil(effects[0].scalarFP)
            XCTAssertNil(effects[0].fpBlockedEffect)
            guard case let .assign(destination, expression) = effects[1].operation else {
                return XCTFail("Expected explicit normal-completion exception-state assignment")
            }
            XCTAssertEqual(destination, output)
            XCTAssertEqual(expression, numeric.normalExceptionResult)
        }
    }
    func testOrdinaryAndExplicitSSABuildersUseTypedFPNotLegacyNearest() throws {
        let cases = [row("42 d4 20 4e", "fadd", "v2.4s, v2.4s, v0.4s"),
                     row("21 68 61 0e", "fcvtn", "v1.2s, v1.2d"),
                     row("61 68 61 4e", "fcvtn2", "v1.4s, v3.2d"),
                     row("21 90 c0 4f", "fmul", "v1.2d, v1.2d, v0.d[0]")]
        for input in cases {
            for ssa in [false, true] {
                // A call-site contract requires the real SSA fallback on this base;
                // bare indirect calls are also admitted by the vector region.
                let call = row("00 01 3f d6", "blr", "x8", 0x1004)
                let ret = row("c0 03 5f d6", "ret", "", ssa ? 0x1008 : 0x1004)
                let rows = ssa ? [input, call, ret] : [input, ret]
                let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                    .buildFunction(name: "vector_fp",
                        slotCallContracts: ssa ? [0x1004: .init(returnType: "void", parameters: [])] : [:],
                        instructions: rows)
                if ssa { XCTAssertTrue(function.ssaEnabled, "Must exercise actual SSA, not vector fastpath") }
                let numeric = try XCTUnwrap(function.instructions.first { $0.vectorFP != nil })
                XCTAssertNotNil(function.instructions.first { $0.vectorFPStatus != nil })
                XCTAssertNil(numeric.scalarFP)
                guard case .intrinsic = numeric.operation else { return XCTFail("Typed symbolic FP result expected") }
                if ssa {
                    let info = try XCTUnwrap(function.ssaInfo)
                    XCTAssertTrue(info.plan.definitions.contains { $0.cell == 99 && $0.bitWidth == 32 })
                    XCTAssertTrue(info.plan.definitions.contains { $0.cell == 100 && $0.bitWidth == 32 })
                    for instruction in function.instructions {
                        if case let .assign(destination, _) = instruction.operation,
                           case .immediate = destination { XCTFail("A projected SIMD half cannot assign to a constant") }
                    }
                }
            }
        }
    }
    func testFCVTZSRoundingAndNondefaultControlsStayExplicit() throws {
        let witness = try XCTUnwrap(witnesses.first { $0.1 == "fcvtzs" })
        let span = source(row(witness.0, witness.1, witness.2))
        let semantics = try XCTUnwrap(MacIRVectorFP(source: span))
        XCTAssertFalse(semantics.usesFPCRRounding)
        XCTAssertEqual(semantics.armPseudocode, "FPToFixed_ZERO_signed")
        for fpcr in [Int64(0), Int64(1 << 22), Int64(1 << 24)] {
            var state = BuilderState(parameters: [])
            let effects = MacIRBuilder.liftVectorFP(semantics, source: span, state: &state,
                fpcr: .immediate(fpcr), exceptions: .immediate(0),
                exceptionOutput: .register(name: "fpsr_exception_bits", version: 1))
            XCTAssertEqual(effects[0].vectorFP?.fpcrInput, .immediate(fpcr))
            XCTAssertEqual(effects[0].vectorFP?.semantics.rounding, .instructionTowardZero)
            // FPUnpack still consumes FZ/FIZ/AH: FZ can cause IDC, despite fixed ZERO rounding.
            XCTAssertNotNil(effects[1].vectorFPStatus)
        }
    }
    func testMixedScalarFPWriterPoisonsOnlyExceptionStateInSSA() throws {
        // Arm FPAdd and FPToFixedJS may update cumulative flags. The legacy
        // scalar numeric result contract does not implement those flag outputs.
        let scalar = row("20 28 22 1e", "fadd", "s0, s1, s2", 0x1004)
        let rows = [row("42 d4 20 4e", "fadd", "v2.4s, v2.4s, v0.4s"), scalar,
                    row("42 d4 20 4e", "fadd", "v2.4s, v2.4s, v0.4s", 0x1008),
                    row("00 01 3f d6", "blr", "x8", 0x100c),
                    row("c0 03 5f d6", "ret", "", 0x1010)]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "mixed_fp_state",
                slotCallContracts: [0x100c: .init(returnType: "void", parameters: [])], instructions: rows)
        XCTAssertTrue(function.ssaEnabled)
        let info = try XCTUnwrap(function.ssaInfo)
        let statusID = try XCTUnwrap(info.plan.rowWriteBindings[1][99])
        XCTAssertNil(info.plan.rowWriteBindings[1][100])
        XCTAssertNil(info.plan.rowWriteBindings[1][98])
        if case .refusal = info.plan.definitions[statusID].origin {} else {
            XCTFail("Legacy scalar flags must be explicitly unavailable")
        }
        let scalarEffects = function.instructions.filter { $0.source.address == 0x1004 }
        XCTAssertTrue(scalarEffects.contains { $0.scalarFP != nil })
        XCTAssertEqual(scalarEffects.compactMap { $0.fpArchitecturalClobber }, [.exceptions])
        let next = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 && $0.vectorFP != nil }?.vectorFP)
        if case .unknown = next.exceptionInput {} else { XCTFail("No stale flags across legacy scalar writer") }
        let ordinary = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: false)
            .buildFunction(name: "ordinary_mixed_fp_state", instructions: Array(rows.prefix(3)) + [
                row("c0 03 5f d6", "ret", "", 0x100c)])
        let ordinaryScalar = ordinary.instructions.filter { $0.source.address == scalar.address }
        XCTAssertTrue(ordinaryScalar.contains { $0.scalarFP != nil })
        // Scalar arithmetic excludes this branch-free fragment from the vector
        // region. The lexical fallback must not claim modeled vector FP state.
        XCTAssertFalse(ordinary.instructions.contains { $0.vectorFP != nil || $0.vectorFPStatus != nil })
        let ordinaryEffects = MacIRBuilder.ssaEffects(for: source(scalar))
        XCTAssertFalse(ordinaryEffects.writes.contains { $0.cell == 99 })
        let mixedEffects = MacIRBuilder.ssaEffects(for: source(scalar), tracksFPEnvironment: true)
        XCTAssertTrue(mixedEffects.writes.contains { $0.cell == 99 })
        let js = source(row("20 00 7e 1e", "fjcvtzs", "w0, d1"))
        XCTAssertTrue(MacIRBuilder.ssaEffects(for: js, tracksFPEnvironment: true).writes.contains { $0.cell == 99 })
        // Arm FPCompare: a signaling NaN may raise IOC even without a numeric destination.
        for (mnemonic, operands) in [("fcmp", "s0, s1"), ("fcmpe", "s0, s1"),
                                     ("fccmp", "s0, s1, #0, eq"), ("fccmpe", "s0, s1, #0, eq")] {
            let comparison = MacIRSourceSpan(address: 0x1020, byteText: "", mnemonic: mnemonic,
                operands: operands, comment: "Classifier-only status barrier, not encoding admission")
            XCTAssertTrue(MacIRBuilder.isLegacyFPStatusWriter(comparison))
            XCTAssertTrue(MacIRBuilder.ssaEffects(for: comparison, tracksFPEnvironment: true)
                .writes.contains { $0.cell == 99 })
        }
    }

    func testMalformedOrScalarEncodingDoesNotAcquireVectorSemantics() {
        XCTAssertNil(MacIRVectorFP(source: source(row("zz 42 d4 20 4e", "fadd", "v2.4s, v2.4s, v0.4s"))))
        XCTAssertNil(MacIRVectorFP(source: source(row("042 d4 20 4e", "fadd", "v2.4s, v2.4s, v0.4s"))))
        XCTAssertNil(MacIRVectorFP(source: source(row("00 00 00 00", "fadd", "v0.4s, v1.4s, v2.4s"))))
        XCTAssertNil(MacIRVectorFP(source: source(row("20 28 22 1e", "fadd", "s0, s1, s2"))))
        XCTAssertNotNil(MacIRBuilder.scalarFPSemantics(mnemonic: "fadd", operands: ["s0", "s1", "s2"]))
    }
}


extension VectorFPStatusIntegrationTests {
    // These authored vectors verify symbolic inputs and sticky accumulation from
    // supplied raised flags. Numeric results and arithmetic-derived flags remain
    // oracle expectations; the engine deliberately does not evaluate them.
    private func assertOracleState(_ family: String, inputs: [UInt64], fpcr: UInt32,
                                   raised: UInt32, expectedFPSR: UInt32,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let mnemonic = family == "fadd_f64" ? "fadd" : family
        let witness = try XCTUnwrap(witnesses.first {
            $0.1 == mnemonic && $0.8 == nil
        }, file: file, line: line)
        let template = try XCTUnwrap(MacIRVectorFP(source: source(row(witness.0, witness.1, witness.2))),
                                    file: file, line: line)
        // Use disjoint physical operands so the supplied inputs remain independent.
        var word = (template.encodedWord & ~UInt32(31 | (31 << 5))) | (1 << 5)
        if template.sources.count == 2 { word = (word & ~UInt32(31 << 16)) | (2 << 16) }
        if family == "fadd_f64" { word |= 1 << 22 }
        else if mnemonic != "fcvtn" && mnemonic != "fcvtn2" { word &= ~UInt32(1 << 22) }
        let data = Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
        let decoded = try XCTUnwrap(ARM64Decoder().decode(data, baseAddress: 0x1000,
                                                        maxInstructionCount: 1).first, file: file, line: line)
        let span = MacIRSourceSpan(address: decoded.address, byteText: decoded.byteText,
            mnemonic: decoded.mnemonic, operands: decoded.operands, comment: nil)
        let semantics = try XCTUnwrap(MacIRVectorFP(source: span), file: file, line: line)
        XCTAssertEqual(semantics.inputBits, mnemonic == "fcvtn" || mnemonic == "fcvtn2" || family == "fadd_f64" ? 64 : 32,
                       file: file, line: line)
        XCTAssertEqual(semantics.resultBits, family == "fadd_f64" ? 64 : 32, file: file, line: line)
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        let supplied = inputs.map { MacIRValue.immediate(Int64(bitPattern: $0)) }
        let sourceValues: [MacIRValue]
        if mnemonic == "fmla" { sourceValues = [supplied[1], supplied[2]] }
        else if mnemonic == "fcvtn" || mnemonic == "fcvtn2" {
            sourceValues = [.binaryExpression(op: "__ssa_join_vector_halves", left: supplied[0], right: supplied[1])]
        } else { sourceValues = supplied }
        var bindings: [Int: MacIRSSAState.Binding] = [:]
        func bind(_ register: String, _ value: MacIRValue) {
            let index = MacIRBuilder.vectorRegisterIndex(register)!
            for cell in [32 + index, 64 + index] {
                bindings[cell] = .init(value: value, bitWidth: 64, view: .bits,
                    origin: .instruction(0x0ffc), wholeVector: value)
            }
        }
        for (register, value) in zip(semantics.sources, sourceValues) { bind(register, value) }
        let old = mnemonic == "fmla" ? supplied[0] : MacIRValue.immediate(0x0123456789abcdef)
        if semantics.readsDestination { bind(semantics.destination, old) }
        state.ssa = .init(current: bindings, writes: [:], clobbers: [:])
        // Read before lift to include physical self-aliasing in the expected inputs.
        var expected = semantics.sources.map { state.readRegister($0) }
        if semantics.readsDestination { expected.append(state.readRegister(semantics.destination)) }
        XCTAssertEqual(expected, sourceValues + (semantics.readsDestination ? [old] : []), file: file, line: line)
        let effects = MacIRBuilder.liftVectorFP(semantics, source: span, state: &state,
            fpcr: .immediate(Int64(fpcr)), exceptions: .immediate(2),
            exceptionOutput: .register(name: "fpsr_exception_bits", version: 1))
        let numeric = try XCTUnwrap(effects.first?.vectorFP, file: file, line: line)
        XCTAssertEqual(numeric.arguments, expected, file: file, line: line)
        XCTAssertEqual(numeric.fpcrInput, .immediate(Int64(fpcr)), file: file, line: line)
        XCTAssertEqual(numeric.exceptionInput, .immediate(2), file: file, line: line)
        XCTAssertEqual(numeric.raisedExceptions, .unknown("fp_raised_exceptions"), file: file, line: line)
        XCTAssertEqual(numeric.semantics.completion, .normalOnlyMayTrap, file: file, line: line)
        XCTAssertEqual(effects.last?.vectorFPStatus, numeric, file: file, line: line)
        XCTAssertTrue(numeric.trapCondition.accessMayTrapIndependently, file: file, line: line)
        if mnemonic == "fmla" {
            XCTAssertEqual(semantics.operation, .fusedMultiplyAdd, file: file, line: line)
            XCTAssertEqual(semantics.fusedAddendArgumentIndex, 2, file: file, line: line)
            XCTAssertEqual(numeric.arguments.last, old, file: file, line: line)
        }
        if mnemonic == "fcvtn" || mnemonic == "fcvtn2" {
            XCTAssertEqual(semantics.resultPlacement, mnemonic == "fcvtn2" ? .preserveLow64 : .zeroHigh64,
                           file: file, line: line)
            XCTAssertEqual(semantics.resultBitOffset, mnemonic == "fcvtn2" ? 64 : 0, file: file, line: line)
        }
        XCTAssertEqual(semantics.rounding, mnemonic == "fcvtzs" ? .instructionTowardZero : .fpcr,
                       file: file, line: line)
        var status = MacIRFPState(fpcr: .constant(fpcr), fpsr: .constant(0x08000002))
        XCTAssertTrue(status.accumulateExceptions(.constant(raised), access: .permitted), file: file, line: line)
        XCTAssertEqual(status.fpsr, .constant(expectedFPSR), file: file, line: line)
    }
    func testOracleFaddRn() throws {
        try assertOracleState("fadd", inputs: [0x3f800000, 0x33800000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFaddPosinf() throws {
        try assertOracleState("fadd", inputs: [0x3f800000, 0x33800000], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFsubRn() throws {
        try assertOracleState("fsub", inputs: [0x3f800000, 0x33000000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFsubZero() throws {
        try assertOracleState("fsub", inputs: [0x3f800000, 0x33000000], fpcr: 0x00c00000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFmulRn() throws {
        try assertOracleState("fmul", inputs: [0x3f800001, 0x3f7fffff], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFmulPosinf() throws {
        try assertOracleState("fmul", inputs: [0x3f800001, 0x3f7fffff], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFdivRn() throws {
        try assertOracleState("fdiv", inputs: [0x3f800000, 0x40400000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFdivZero() throws {
        try assertOracleState("fdiv", inputs: [0x3f800000, 0x40400000], fpcr: 0x00c00000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFmlaRn() throws {
        try assertOracleState("fmla", inputs: [0x3f800000, 0x3f800000, 0x33800000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFmlaPosinf() throws {
        try assertOracleState("fmla", inputs: [0x3f800000, 0x3f800000, 0x33800000], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtnRn() throws {
        try assertOracleState("fcvtn", inputs: [0x3ff0000010000000, 0x4000000000000000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtnPosinf() throws {
        try assertOracleState("fcvtn", inputs: [0x3ff0000010000000, 0x4000000000000000], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtn2Rn() throws {
        try assertOracleState("fcvtn2", inputs: [0x3ff0000010000000, 0x4000000000000000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtn2Posinf() throws {
        try assertOracleState("fcvtn2", inputs: [0x3ff0000010000000, 0x4000000000000000], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleUcvtfRn() throws {
        try assertOracleState("ucvtf", inputs: [0x01000001], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleUcvtfPosinf() throws {
        try assertOracleState("ucvtf", inputs: [0x01000001], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleScvtfRn() throws {
        try assertOracleState("scvtf", inputs: [0xfeffffff], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleScvtfNeginf() throws {
        try assertOracleState("scvtf", inputs: [0xfeffffff], fpcr: 0x00800000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtzs1750X00000000() throws {
        try assertOracleState("fcvtzs", inputs: [0x3fe00000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtzs1750X00400000() throws {
        try assertOracleState("fcvtzs", inputs: [0x3fe00000], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtzsSubnormalFz0() throws {
        try assertOracleState("fcvtzs", inputs: [0x00000001], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFcvtzsSubnormalFz1() throws {
        try assertOracleState("fcvtzs", inputs: [0x00000001], fpcr: 0x01000000,
                              raised: 0x00000080, expectedFPSR: 0x08000082)
    }
    func testOracleFaddF64Rn() throws {
        try assertOracleState("fadd_f64", inputs: [0x3ff0000000000000, 0x3ca0000000000000], fpcr: 0x00000000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFaddF64Posinf() throws {
        try assertOracleState("fadd_f64", inputs: [0x3ff0000000000000, 0x3ca0000000000000], fpcr: 0x00400000,
                              raised: 0x00000010, expectedFPSR: 0x08000012)
    }
    func testOracleFmlaFusedCancellationRn() throws {
        try assertOracleState("fmla", inputs: [0xbf800000, 0x3f800001, 0x3f7ffffe], fpcr: 0x00000000,
                              raised: 0x00000000, expectedFPSR: 0x08000002)
    }
    func testOracleFmlaFusedCancellationRp() throws {
        try assertOracleState("fmla", inputs: [0xbf800000, 0x3f800001, 0x3f7ffffe], fpcr: 0x00400000,
                              raised: 0x00000000, expectedFPSR: 0x08000002)
    }
}
