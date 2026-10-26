import XCTest
@testable import MacScope

final class FPStatusStateTests: XCTestCase {
    // Arm MRS/MSR (register), op0:op1:CRn:CRm:op2 = 3:3:4:4:{0,1}.
    // This synthetic layout exercises the mechanism, not a production CPU profile.
    private func full(_ register: MacIRFPState.Register) -> MacIRFPRegisterLayout {
        MacIRFPRegisterLayout(register: register, implemented: .max, res0: 0, upper32AreRES0: true)!
    }

    func testUnknownEntryAndAllRoundingFields() {
        let unknown = MacIRFPState()
        XCTAssertNil(unknown.rounding)
        XCTAssertNil(unknown.defaultNaN)
        XCTAssertNil(unknown.flushToZero)
        XCTAssertNil(unknown.flushHalfToZero)
        XCTAssertNil(unknown.alternateHandling)
        XCTAssertNil(unknown.flushInputsToZero)
        for raw in UInt32(0)...3 {
            let state = MacIRFPState(fpcr: .constant(raw << 22))
            XCTAssertEqual(state.rounding?.rawValue, raw)
        }
        let partial = MacIRFPState(fpcr: .init(value: 0, known: 1 << 22))
        XCTAssertNil(partial.rounding)
        let modes = MacIRFPState(fpcr: .constant((1 << 25) | (1 << 24) | (1 << 19) | 3))
        XCTAssertEqual(modes.defaultNaN, true)
        XCTAssertEqual(modes.flushToZero, true)
        XCTAssertEqual(modes.flushHalfToZero, true)
        XCTAssertEqual(modes.alternateHandling, true)
        XCTAssertEqual(modes.flushInputsToZero, true)
    }

    func testAllTransferEncodingsAndExpectedTypedEffects() throws {
        // MRS X2,FPCR: read32 zero extends to X2; state unchanged.
        // MRS X3,FPSR: identical width, independent status register.
        for (word, register, value) in [(UInt32(0xd53b4402), MacIRFPState.Register.fpcr, UInt32(0x1234)),
                                         (0xd53b4423, .fpsr, 0x800009f)] {
            var state = MacIRFPState(fpcr: .constant(0x1234), fpsr: .constant(0x800009f))
            let before = state
            let op = try XCTUnwrap(MacIRFPState.Transfer(word: word))
            let effect = try XCTUnwrap(state.apply(op, layout: full(op.register), access: .permitted))
            XCTAssertEqual(op.register, register)
            XCTAssertEqual(op.direction, .read)
            XCTAssertEqual(effect.gprValue, UInt64(value))
            XCTAssertEqual(effect.gprKnown, UInt64.max)
            XCTAssertEqual(effect.before, before)
            XCTAssertEqual(effect.after, before)
            XCTAssertEqual(state, before)
        }
        // MSR FPCR,X4 / MSR FPSR,X5 replace their own low32 state, not sticky-OR.
        for (word, register) in [(UInt32(0xd51b4404), MacIRFPState.Register.fpcr), (0xd51b4425, .fpsr)] {
            var state = MacIRFPState(fpcr: .constant(.max), fpsr: .constant(.max))
            let op = try XCTUnwrap(MacIRFPState.Transfer(word: word))
            let effect = try XCTUnwrap(state.apply(op, source: .constant(0), layout: full(op.register), access: .permitted))
            XCTAssertEqual(op.direction, .write)
            XCTAssertEqual(op.register, register)
            XCTAssertNil(effect.gprValue)
            XCTAssertEqual(register == .fpcr ? state.fpcr : state.fpsr, .constant(0))
            XCTAssertEqual(register == .fpcr ? state.fpsr : state.fpcr, .constant(.max))
        }
        XCTAssertNil(MacIRFPState.Transfer(word: 0xd53b4440)) // different sysreg
        XCTAssertNil(MacIRFPState.Transfer(word: 0x1e222820)) // FADD is NOT a state transfer
    }

    func testXZRReservedBitsAndMissingContextNeverBecomeDefaults() throws {
        var state = MacIRFPState()
        let write = try XCTUnwrap(MacIRFPState.Transfer(word: 0xd51b441f))
        XCTAssertNil(state.apply(write, layout: nil, access: .permitted))
        XCTAssertNil(state.apply(write, layout: full(.fpcr), access: .unknown))
        XCTAssertNil(state.apply(write, layout: full(.fpcr), access: .trapped))
        XCTAssertNil(state.apply(write, layout: full(.fpsr), access: .permitted))
        XCTAssertNil(MacIRFPRegisterLayout(register: .fpcr, implemented: .max, res0: 0, upper32AreRES0: false))
        XCTAssertEqual(state, MacIRFPState())
        _ = try XCTUnwrap(state.apply(write, layout: full(.fpcr), access: .permitted))
        XCTAssertEqual(state.fpcr, .constant(0))
        let readZR = try XCTUnwrap(MacIRFPState.Transfer(word: 0xd53b441f))
        XCTAssertNil(try XCTUnwrap(state.apply(readZR, layout: full(.fpcr), access: .permitted)).gprValue)
        var partial = MacIRFPState(fpcr: .init(value: 1, known: 1))
        let readX0 = try XCTUnwrap(MacIRFPState.Transfer(word: 0xd53b4400))
        let partialEffect = try XCTUnwrap(partial.apply(readX0, layout: full(.fpcr), access: .permitted))
        XCTAssertEqual(partialEffect.gprValue, 1)
        XCTAssertEqual(partialEffect.gprKnown, 0xffff_ffff_0000_0001)
        let ordinaryWrite = try XCTUnwrap(MacIRFPState.Transfer(word: 0xd51b4400))
        XCTAssertNil(state.apply(ordinaryWrite, layout: full(.fpcr), access: .permitted))
        let layout = try XCTUnwrap(MacIRFPRegisterLayout(register: .fpsr, implemented: 0x9f, res0: ~UInt32(0x9f), upper32AreRES0: true))
        XCTAssertEqual(layout.normalized(.init()).known, ~UInt32(0x9f))
        XCTAssertEqual(layout.normalized(.constant(.max)).value, 0x9f)
        XCTAssertNil(MacIRFPRegisterLayout(register: .fpcr, implemented: 1, res0: 1, upper32AreRES0: true))
        XCTAssertNil(MacIRFPRegisterLayout(register: .fpcr, implemented: 1, res0: 0, upper32AreRES0: true))
    }

    func testStickyFlagsQCAndExplicitMSRClearAreDifferent() throws {
        // FPProcessException: status[cumul] = 1 on the non-trapping path.
        var state = MacIRFPState(fpcr: .constant(0), fpsr: .constant(1 << 27))
        XCTAssertTrue(state.accumulateExceptions(.constant(0x9f), access: .permitted))
        XCTAssertEqual(state.fpsr, .constant(0x800009f))
        XCTAssertTrue(state.accumulateExceptions(.constant(0), access: .permitted))
        XCTAssertTrue(state.accumulateSaturation(false, access: .permitted))
        XCTAssertEqual(state.fpsr, .constant(0x800009f))
        let clear = try XCTUnwrap(MacIRFPState.Transfer(word: 0xd51b443f))
        _ = try XCTUnwrap(state.apply(clear, layout: full(.fpsr), access: .permitted))
        XCTAssertEqual(state.fpsr, .constant(0))
        XCTAssertTrue(state.accumulateSaturation(nil, access: .permitted))
        XCTAssertEqual(state.fpsr.known, ~MacIRFPState.qcMask)
        XCTAssertTrue(state.accumulateSaturation(true, access: .permitted))
        XCTAssertEqual(state.fpsr, .constant(1 << 27))
    }

    func testUnknownRaisedFlagsAndTrapEnablesRefuseWithoutMutation() {
        for control in [MacIRFPBits(), .constant(1 << 8), .constant(1 << 15)] {
            var state = MacIRFPState(fpcr: control, fpsr: .constant(0))
            let before = state
            XCTAssertFalse(state.accumulateExceptions(.constant(1), access: .permitted))
            XCTAssertEqual(state, before)
        }
        var state = MacIRFPState(fpcr: .constant(0), fpsr: .constant(0))
        XCTAssertFalse(state.accumulateExceptions(.constant(1 << 27), access: .permitted))
        XCTAssertFalse(state.accumulateExceptions(.constant(1), access: .unknown))
        XCTAssertTrue(state.accumulateExceptions(.init(known: ~MacIRFPState.exceptionMask), access: .permitted))
        XCTAssertEqual(state.fpsr.known, ~MacIRFPState.exceptionMask)
        XCTAssertTrue(state.accumulateExceptions(.constant(1), access: .permitted))
        XCTAssertEqual(state.fpsr.field(mask: 1), 1)
        XCTAssertNil(state.fpsr.field(mask: 2))
    }

    func testJoinAndCallPoisonHaveNoLexicalRecovery() {
        let left = MacIRFPState(fpcr: .constant(0), fpsr: .constant(1 << 27))
        let right = MacIRFPState(fpcr: .constant(1 << 22), fpsr: .constant(0))
        var join = left.joined(with: right)
        XCTAssertNil(join.rounding)
        XCTAssertNil(join.fpsr.field(mask: 1 << 27))
        XCTAssertEqual(join.fpsr.field(mask: 0x9f), 0)
        XCTAssertEqual(left.joined(with: .init()), .init()) // pending backedge
        join.invalidateAtUnknownCallOrWriter()
        XCTAssertEqual(join, .init())
    }
}
