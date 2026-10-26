import Foundation
import XCTest
@testable import MacScope

/// DOT-02 only: new patterns and refusal gates, not the accepted lifter corpus.
final class MacIRArithmeticRewriteTests: XCTestCase {
    private func build(_ text: [(String, String)], gap: Int? = nil) -> MacIRFunction {
        let rows = text.enumerated().map { i, pair in
            InstructionRow(address: 0x1000 + UInt64(i * 4 + (gap == i ? 4 : 0)), bytes: "",
                           mnemonic: pair.0, operands: pair.1, hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder().buildFunction(name: "dot02", instructions: rows)
    }
    private func reciprocal(_ divisor: Int64, shift: Int, magicLow: Int = 43691, magicHigh: Int = 43690) -> [(String, String)] {
        [("mov", "w8, #\(magicLow)"), ("movk", "w8, #\(magicHigh), lsl #16"),
         ("umull", "x8, w0, w8"), ("lsr", "x0, x8, #\(shift)")]
    }
    private func isQuotient(_ operation: MacIROperation, divisor: Int64) -> Bool {
        guard case let .assign(_, .unary("(uint64_t)", .binaryExpression("/", .unary("(uint32_t)", _), .unary("(uint32_t)", .immediate(d))))) = operation else { return false }
        return d == divisor
    }
    func testCompilerReciprocalDivisionShapes() {
        for (divisor, shift, low, high) in [(Int64(3), 33, 43691, 43690), (5, 34, 52429, 52428), (10, 35, 52429, 52428)] {
            let f = build(reciprocal(divisor, shift: shift, magicLow: low, magicHigh: high))
            XCTAssertEqual(f.instructions.count, 4)
            XCTAssertTrue(isQuotient(f.instructions[3].operation, divisor: divisor))
            guard case .binary(_, "*", _, _) = f.instructions[2].operation else { return XCTFail("Producer must remain") }
        }
    }
    func testSequenceRefusals() {
        let valid = reciprocal(3, shift: 33)
        var variants: [[(String, String)]] = []
        variants.append(reciprocal(3, shift: 33, magicLow: 43690)) // off-by-one magic
        variants.append(reciprocal(3, shift: 34)) // wrong final shift
        var wrongUse = valid; wrongUse[3] = ("lsr", "x0, x9, #33"); variants.append(wrongUse)
        var wrongWidth = valid; wrongWidth[3] = ("lsr", "w0, w8, #1"); variants.append(wrongWidth)
        var signed = valid; signed[2] = ("smull", "x8, w0, w8"); variants.append(signed)
        var gap = valid; gap.insert(("nop", ""), at: 3); variants.append(gap)
        variants.append([("b", "0x1004")] + valid)
        variants.append([("bl", "_unknown_target")] + valid)
        variants.append(valid + [("cbz", "w1, 0x1000")])
        for (i, rows) in variants.enumerated() {
            XCTAssertFalse(build(rows).instructions.contains { isQuotient($0.operation, divisor: 3) }, "refusal \(i)")
        }
        XCTAssertFalse(build(valid, gap: 3).instructions.contains { isQuotient($0.operation, divisor: 3) })
    }
    func testSignPairPreservesSSAAndWToXProjection() {
        let f = build([("lsl", "w0, w0, #24"), ("asr", "w0, w0, #24"), ("mov", "x3, x0")])
        XCTAssertEqual(f.instructions.count, 3)
        guard case let .assign(destination, .unary("(int32_t)", .unary("(int8_t)", input))) = f.instructions[1].operation,
              case .argument = input,
              case let .assign(_, .unary("(uint64_t)", .unary("(uint32_t)", read))) = f.instructions[2].operation else {
            return XCTFail("Missing typed sign extension or W-to-X projection")
        }
        XCTAssertEqual(destination, read)
        for rows in [ [("lsl", "w2, w0, #24"), ("asr", "w3, w1, #24")],
                      [("lsl", "w2, w0, #24"), ("asr", "w3, w2, #23")],
                      [("lsl", "w2, w0, #24"), ("asr", "x3, x2, #24")],
                      [("lsl", "w2, w0, #24"), ("nop", ""), ("asr", "w3, w2, #24")] ] {
            guard case .binary(_, ">>", _, _) = build(rows).instructions.last!.operation else { return XCTFail("Unsafe sign pair admitted") }
        }
    }
    func testBoundaryAndRefusalAdmission() {
        let destination = MacIRValue.register(name: "w2", version: 1)
        let input = MacIRValue.register(name: "w0", version: 0)
        func candidate(_ mnemonic: String, _ width: Int?, _ widths: [Int?], _ op: MacIROperation) -> MacIROperation {
            var pass = MacIRArithmeticRewrite()
            return pass.rewrite(op, mnemonic: mnemonic, width: width, operandWidths: widths, address: 0x1000, allowSequence: true)
        }
        for (mnemonic, width, sourceWidth, shift, cast) in [
            ("asr", 32, 32, Int64(3), "(int32_t)"),
            ("lsr", 32, 32, 0, "(uint32_t)"), ("lsr", 32, 32, 32, "(uint32_t)"),
            ("lsr", 64, 64, 63, "(uint64_t)"), ("lsr", 32, 64, 3, "(uint32_t)"),
            ("lsr", 32, 32, -1, "(uint32_t)"), ("lsr", 16, 16, 3, "(uint16_t)") ] {
            let op = MacIROperation.binary(destination: destination, op: ">>", left: .unary(op: cast, value: input), right: .immediate(shift))
            XCTAssertEqual(candidate(mnemonic, width, [sourceWidth, nil], op), op)
        }
        for (mnemonic, mask) in [("and", Int64(0)), ("and", 6), ("and", -1), ("ands", 7), ("and", Int64.max)] {
            let op = MacIROperation.binary(destination: destination, op: "&", left: input, right: .immediate(mask))
            XCTAssertEqual(candidate(mnemonic, 32, [32, nil], op), op)
        }
        for input in [MacIRValue.unknown("opaque"), .stackSlot(offset: 0), .symbol("global")] {
            let op = MacIROperation.binary(destination: destination, op: "&", left: input, right: .immediate(7))
            XCTAssertEqual(candidate("and", 32, [32, nil], op), op)
        }
        let shifted = MacIROperation.binary(destination: destination, op: ">>", left: .unary(op: "(uint32_t)", value: input), right: .immediate(31))
        // Standalone unsigned shifts stay bitwise.
        XCTAssertEqual(candidate("lsr", 32, [32, nil], shifted), shifted)
        let masked = MacIROperation.binary(destination: destination, op: "&", left: input, right: .immediate(0xff))
        XCTAssertEqual(candidate("and", 32, [32, nil], masked), masked)
    }
}
