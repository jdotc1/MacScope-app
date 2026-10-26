import XCTest
@testable import MacScope

/// Source-reasoned vectors; not an execution receipt.
final class ScalarUnmodeledModelTests: XCTestCase {
    private func lift(_ mnemonic: String, _ operands: String, _ bytes: String,
                      state: inout BuilderState) -> MacIROperation {
        MacIRBuilder().operation(for: .init(address: 0x1000, byteText: bytes,
            mnemonic: mnemonic, operands: operands), state: &state)
    }

    func testRetainedEncodingVectorsReachNewIRRoutes() {
        let vectors = [
            ("tst", "x11, #0x8080808080808080", "7f c1 01 f2"),
            ("tst", "x9, #0x8000000000000000", "3f 01 41 f2"),
            ("tst", "w25, w24, asr #1", "3f 07 98 6a"),
            ("add", "w11, w11, w14, sxth", "6b a1 2e 0b"),
            ("sub", "w6, w6, w5, sxth", "c6 a0 25 4b")
        ]
        for (mnemonic, operands, bytes) in vectors {
            var state = BuilderState()
            let operation = lift(mnemonic, operands, bytes, state: &state)
            switch operation {
            case .intrinsic where mnemonic == "tst": break
            case .assign where mnemonic == "add" || mnemonic == "sub": break
            default: XCTFail("retained encoding did not reach its semantic route")
            }
        }
    }

    func testHighBitTSTPreservesSigned64ResultAndLogicalFlags() throws {
        for mask: UInt64 in [0x8080808080808080, 0x8000000000000000] {
            var state = BuilderState()
            let input = state.readRegister("x11")
            let operation = lift("tst", "x11, #0x" + String(mask, radix: 16), "", state: &state)
            let expected = MacIRValue.unary(op: "(int64_t)", value:
                .binaryExpression(op: "&", left: .unary(op: "(uint64_t)", value: input),
                    right: .unary(op: "(uint64_t)", value: .immediate(Int64(bitPattern: mask)))))
            guard case let .intrinsic(destination, name, arguments) = operation else { return XCTFail("TST was not lifted") }
            XCTAssertNil(destination)
            XCTAssertEqual(name, "compare")
            XCTAssertEqual(arguments, [expected, .immediate(0)])
            let flags = try XCTUnwrap(state.lastComparison)
            XCTAssertEqual(flags.left, expected)
            XCTAssertEqual(flags.right, .immediate(0))
            guard case .logicalResult = flags.flagsKind else { return XCTFail("C/V must be logical zero, not subtraction carry") }
        }
    }

    func testShiftedTSTUsesSignedASRThen32BitLogicalResult() throws {
        var state = BuilderState()
        let left = state.readRegister("w25"), right = state.readRegister("w24")
        _ = lift("tst", "w25, w24, asr #1", "", state: &state)
        let shifted = MacIRValue.binaryExpression(op: ">>", left: .unary(op: "(int32_t)", value: right), right: .immediate(1))
        let expected = MacIRValue.unary(op: "(int32_t)", value: .binaryExpression(op: "&",
            left: .unary(op: "(uint32_t)", value: left), right: .unary(op: "(uint32_t)", value: shifted)))
        XCTAssertEqual(try XCTUnwrap(state.lastComparison).left, expected)
    }

    func testWSXTHAddAndSubNarrowBeforeShiftAndWrapDestination() {
        for mnemonic in ["add", "sub"] {
            for amount in [0, 4] {
                var state = BuilderState()
                let left = state.readRegister("w11"), right = state.readRegister("w14")
                let operation = lift(mnemonic, "w11, w11, w14, sxth #\(amount)", "", state: &state)
                let extended = MacIRValue.unary(op: "(uint32_t)", value: .unary(op: "(int16_t)", value: right))
                let shifted: MacIRValue = amount == 0 ? extended : .binaryExpression(op: "<<", left: extended, right: .immediate(Int64(amount)))
                let expected = MacIRValue.unary(op: "(uint32_t)", value: .binaryExpression(op: mnemonic == "add" ? "+" : "-",
                    left: .unary(op: "(uint32_t)", value: left), right: shifted))
                guard case let .assign(_, result) = operation else { return XCTFail("W extension was not lifted") }
                XCTAssertEqual(result, expected)
                XCTAssertNil(state.lastComparison)
            }
        }
    }

    func testInvalidShiftBoundsAndWidthRemainUnknown() {
        for operands in ["w25, w24, asr #32", "w25, x24, asr #1", "w25, w24, asr #-1"] {
            var state = BuilderState()
            guard case .unknown = lift("tst", operands, "", state: &state) else { return XCTFail("invalid TST accepted") }
        }
        for operands in ["w11, w11, w14, sxth #5", "wzr, w11, w14, sxth", "w11, wzr, w14, sxth"] {
            var state = BuilderState()
            guard case .unknown = lift("add", operands, "", state: &state) else { return XCTFail("invalid extension accepted") }
        }
    }
}
