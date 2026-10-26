import XCTest
@testable import MacScope

final class CompareNegativeCarryTests: XCTestCase {
    private enum Failure: Error { case unexpectedValue, missingBranch }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
            hasBreakpoint: false, comment: nil)
    }

    private func branch(_ mnemonic: String = "cmn", operands: String, suffix: String,
                        address: UInt64, ssa: Bool) throws -> (String, MacIRValue, MacIRValue) {
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_compare_negative_carry", instructions: [
            row(address, mnemonic, operands), row(address + 4, "b." + suffix, "0x" + String(address + 0x20, radix: 16)),
            row(address + 8, "ret", ""), row(address + 0x20, "ret", "")
        ])
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == address + 4 })
        guard case let .conditionalBranch(condition, left, right, _) = instruction.operation else {
            throw Failure.missingBranch
        }
        return (condition, left, right)
    }

    private func value(_ expression: MacIRValue, a: UInt64, b: UInt64) throws -> UInt64 {
        switch expression {
        case let .register(name, _):
            switch name {
            case "x21", "w21": return name == "w21" ? a & 0xffff_ffff : a
            case "x27", "w27": return name == "w27" ? b & 0xffff_ffff : b
            default: throw Failure.unexpectedValue
            }
        case let .immediate(n): return UInt64(bitPattern: n)
        case let .unary(op, inner):
            let x = try value(inner, a: a, b: b)
            switch op {
            case "(uint64_t)": return x
            case "(uint32_t)": return x & 0xffff_ffff
            case "~": return ~x
            default: throw Failure.unexpectedValue
            }
        case let .binaryExpression("<<", left, right):
            return try value(left, a: a, b: b) << value(right, a: a, b: b)
        default: throw Failure.unexpectedValue
        }
    }

    func testBothRecordedSitesAndCarryAliasesAgainstOverflowOracle() throws {
        let samples: [(UInt64, UInt64)] = [
            (0, 0), (.max, 0), (0, .max), (1, .max), (.max, 1),
            (.max - 127, 1), (.max - 126, 1), (0, 1 << 57), (.max, 1 << 57)
        ]
        for ssa in [false, true] {
            for (address, operands, shift) in [
                (UInt64(0x46d30), "x21, x27", 0), (UInt64(0x46d98), "x21, x27, lsl #7", 7)
            ] {
                for suffix in ["lo", "cc", "hs", "cs"] {
                    let (op, left, right) = try branch(operands: operands, suffix: suffix, address: address, ssa: ssa)
                    let noCarry = suffix == "lo" || suffix == "cc"
                    XCTAssertEqual(op, noCarry ? "<=" : ">")
                    for (a, b) in samples {
                        let addend = b << shift
                        let carry = a.addingReportingOverflow(addend).overflow
                        let l = try value(left, a: a, b: b)
                        let r = try value(right, a: a, b: b)
                        XCTAssertEqual(noCarry ? l <= r : l > r, noCarry ? !carry : carry)
                    }
                }
            }
        }
    }

    func testWWidthProjectsShiftBeforeComplement() throws {
        let (op, left, right) = try branch(operands: "w21, w27, lsl #7", suffix: "lo", address: 0x1000, ssa: false)
        XCTAssertEqual(op, "<=")
        for (a, b) in [(UInt64(0), UInt64(1 << 25)), (0xffff_ffff, 0), (0xffff_ffff, 1)] {
            let addend = UInt32(truncatingIfNeeded: b << 7)
            let carry = UInt32(truncatingIfNeeded: a).addingReportingOverflow(addend).overflow
            XCTAssertEqual(try value(left, a: a, b: b) <= value(right, a: a, b: b), !carry)
        }
    }

    func testWZRLeftRetainsEncodedWidthForShiftedAddend() throws {
        for ssa in [false, true] {
            let (op, left, right) = try branch(operands: "wzr, w27, lsl #7", suffix: "lo", address: 0x1800, ssa: ssa)
            XCTAssertEqual(op, "<=")
            // The nonzero register value shifts to zero at W width, not X width.
            for b in [UInt64(1 << 25), UInt64.max, 0] {
                let l = try value(left, a: 0, b: b)
                let r = try value(right, a: 0, b: b)
                XCTAssertEqual(l, 0)
                XCTAssertEqual(r, UInt64(~UInt32(truncatingIfNeeded: b << 7)))
                XCTAssertTrue(l <= r)
            }
        }
    }

    func testSSACarryPresentationElidesOnlyExactComplementPredicates() throws {
        for operands in ["w21, #4", "x21, x27", "w21, w27, lsl #7", "wzr, w27, lsl #7"] {
            for suffix in ["lo", "cc", "hs", "cs"] {
                let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "carry_presentation", instructions: [
                    row(0x1000, "cmn", operands), row(0x1004, "b." + suffix, "0x1010"),
                    row(0x1008, "mov", "x0, #0"), row(0x100c, "ret", ""),
                    row(0x1010, "mov", "x0, #1"), row(0x1014, "ret", "")
                ])
                let printer = PseudocodePrinter(options: .default)
                func decision(_ candidate: MacIRFunction) -> CompareElisionDecision? {
                    printer.compareElisionDecision(function: candidate,
                        names: PseudocodeNameContext(function: candidate))[0]
                }
                XCTAssertEqual(decision(function), .elide, operands + " " + suffix)
                let document = printer.print(function: function)
                XCTAssertFalse(document.text.contains("__compare("), document.text)
                XCTAssertTrue(document.lines(sourcedAt: 0x1004).contains { $0.text.contains("~") }, document.text)
                guard case let .conditionalBranch(condition, left, right, target) = function.instructions[1].operation else {
                    return XCTFail("expected exact carry branch")
                }
                var changed = function
                changed.instructions[1].operation = .conditionalBranch(condition: condition,
                    left: left, right: .immediate(4), target: target)
                if case .keep = decision(changed) {} else { XCTFail("changed addend must retain compare") }
                changed.instructions[1].operation = .conditionalBranch(condition: condition == ">" ? ">=" : "<",
                    left: left, right: right, target: target)
                if case .keep = decision(changed) {} else { XCTFail("changed carry boundary must retain compare") }
                changed = function
                changed.instructions[1].source.mnemonic = "b.eq"
                if case .keep = decision(changed) {} else { XCTFail("noncarry source must retain compare") }
                changed = function
                changed.instructions[0].source.mnemonic = "cmp"
                if case .keep = decision(changed) {} else { XCTFail("non-CMN producer must retain compare") }
                changed = function
                changed.instructions[1].operation = .conditionalBranch(condition: condition,
                    left: left, right: .unary(op: "(uint16_t)", value: right), target: target)
                if case .keep = decision(changed) {} else { XCTFail("changed width must retain compare") }
                changed = function
                changed.ssaEnabled = false
                if case .keep = decision(changed) {} else { XCTFail("legacy decision must remain unchanged") }
            }
        }
    }

    private func containsUnary(_ expected: String, _ value: MacIRValue) -> Bool {
        switch value {
        case let .unary(op, inner): return op == expected || containsUnary(expected, inner)
        case let .binaryExpression(_, left, right): return containsUnary(expected, left) || containsUnary(expected, right)
        default: return false
        }
    }

    func testSignedCMNAndOrdinaryCMPRemainUnchanged() throws {
        for ssa in [false, true] {
            let (signedOp, _, signedRight) = try branch(operands: "x21, x27", suffix: "lt", address: 0x2000, ssa: ssa)
            XCTAssertEqual(signedOp, "<")
            XCTAssertTrue(containsUnary("-", signedRight))
            XCTAssertFalse(containsUnary("~", signedRight))
            let (cmpOp, _, cmpRight) = try branch("cmp", operands: "x21, x27", suffix: "lo", address: 0x3000, ssa: ssa)
            XCTAssertEqual(cmpOp, "<")
            XCTAssertFalse(containsUnary("~", cmpRight))
        }
    }
}
