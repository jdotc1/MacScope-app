import Foundation
import XCTest
@testable import MacScope

/// Independently assembled A64 words exercise the production decoder and
/// general-vector builder. Oracle: retained Linux LLVM, not Apple validation.
final class S1VectorConditionTypeTests: XCTestCase {
    private let conditions: [(String, UInt32, UInt32, UInt32, UInt32, UInt32)] = [
        ("lt", 0x5400006b, 0x9a84b06e, 0x9a9fa7ee, 0x1a84b06e, 0x1a9fa7ee),
        ("lo", 0x54000063, 0x9a84306e, 0x9a9f27ee, 0x1a84306e, 0x1a9f27ee),
        ("le", 0x5400006d, 0x9a84d06e, 0x9a9fc7ee, 0x1a84d06e, 0x1a9fc7ee),
        ("ls", 0x54000069, 0x9a84906e, 0x9a9f87ee, 0x1a84906e, 0x1a9f87ee),
        ("gt", 0x5400006c, 0x9a84c06e, 0x9a9fd7ee, 0x1a84c06e, 0x1a9fd7ee),
        ("hi", 0x54000068, 0x9a84806e, 0x9a9f97ee, 0x1a84806e, 0x1a9f97ee),
        ("ge", 0x5400006a, 0x9a84a06e, 0x9a9fb7ee, 0x1a84a06e, 0x1a9fb7ee),
        ("hs", 0x54000062, 0x9a84206e, 0x9a9f37ee, 0x1a84206e, 0x1a9f37ee),
    ]

    func testWBranchesKeepSignedAndUnsignedHighBitSemantics() throws {
        try check(width: 32, consumer: "branch")
    }

    func testXBranchesKeepSignedAndUnsignedHighBitSemantics() throws {
        try check(width: 64, consumer: "branch")
    }

    func testWFlagsControlXSelectAndSetWithoutWideningComparison() throws {
        try check(width: 32, consumer: "csel")
        try check(width: 32, consumer: "cset")
    }

    func testXFlagsControlWSelectAndSetWithoutNarrowingComparison() throws {
        try check(width: 64, consumer: "csel")
        try check(width: 64, consumer: "cset")
    }

    private func check(width: Int, consumer: String) throws {
        for (suffix, branch, selectWFlags, setWFlags, selectXFlags, setXFlags) in conditions {
            // Cross-width moves expose the unsigned projection that requires
            // normalization. X flags compare a zero-extended W value against
            // a high-bit X value; W flags compare the low bits of an X write.
            let move: UInt32 = width == 32 ? 0xaa0103ec : 0x2a0103ec
            let compare: UInt32 = width == 32 ? 0x6b02019f : 0xeb02019f
            let conditionWord = consumer == "branch" ? branch
                : consumer == "csel" ? (width == 32 ? selectWFlags : selectXFlags)
                : (width == 32 ? setWFlags : setXFlags)
            // A reachable non-entry loop is required by generalVectorPlan.
            // Keep it after the tested operation so the evaluator executes
            // the real entry prefix without manufacturing loop-phi inputs.
            let words: [UInt32] = [move, 0x4f00e4e0, compare, conditionWord,
                                   0xd503201f, 0xb5ffffe5, 0xd65f03c0]
            let rows = decode(words)
            XCTAssertEqual(rows[3].mnemonic, consumer == "branch" ? "b.\(suffix)" : consumer)
            XCTAssertEqual(rows[2].operands, width == 32 ? "w12, w2" : "x12, x2")
            XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(rows))
            let function = MacIRBuilder().buildFunction(name: "condition_\(width)_\(consumer)_\(suffix)",
                startAddress: 0x1000, instructions: rows)
            XCTAssertTrue(function.instructions.contains { $0.source.address == 0x1004 && $0.neonImmediate != nil },
                          "the production general-vector path must claim the fixture")
            let backedge = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1014 })
            guard case let .conditionalBranch(_, _, _, target) = backedge.operation else {
                return XCTFail("the decoded CBNZ must retain its reachable loop backedge")
            }
            XCTAssertEqual(target, .immediate(0x1010))
            let condition = try XCTUnwrap(function.instructions.first { $0.source.address == 0x100c })
            let left: MacIRValue
            switch condition.operation {
            case let .conditionalBranch(_, value, _, _) where consumer == "branch": left = value
            case let .select(_, _, value, _, _, _) where consumer == "csel": left = value
            case let .compareToBool(_, _, value, _) where consumer == "cset": left = value
            default: return XCTFail("wrong condition operation: \(condition.operation)")
            }
            let unsigned = ["lo", "ls", "hi", "hs"].contains(suffix)
            guard case let .unary(cast, _) = left else {
                return XCTFail("comparison lost its explicit flag-setter width: \(left)")
            }
            XCTAssertEqual(cast, "(\(unsigned ? "uint" : "int")\(width)_t)",
                           "\(consumer) result width must not replace CMP width")

            let highBit: UInt64 = width == 32 ? 0x80000000 : 0x8000000000000000
            let highPair: (UInt64, UInt64) = width == 32 ? (highBit, 8) : (1, highBit)
            for (a, b) in [highPair, (UInt64(1), UInt64(8)), (UInt64(8), UInt64(8))] {
                var state = try A64MachineState(seeding: .init(gpr: nil, sp: nil, pc: nil,
                    nzcv: nil, fpcr: nil, fpsr: nil, vectors: nil, memory: nil))
                state.x[1] = a; state.x[2] = b; state.x[3] = 11; state.x[4] = 22
                var evaluator = MacIRConcreteEvaluator(function: function, state: state)
                try evaluator.run(function.instructions.filter { $0.source.address <= 0x100c })
                let expected = expectedCondition(suffix, width: width, a: a, b: b)
                if consumer == "branch" {
                    XCTAssertEqual(evaluator.nextPC != nil, expected, "\(width)-bit \(suffix): \(a), \(b)")
                } else {
                    let expectedValue: UInt64 = consumer == "cset" ? (expected ? 1 : 0) : (expected ? 11 : 22)
                    XCTAssertEqual(evaluator.state.x[14], expectedValue, "\(width)-bit \(consumer) \(suffix): \(a), \(b)")
                }
            }
        }
    }

    private func expectedCondition(_ suffix: String, width: Int, a: UInt64, b: UInt64) -> Bool {
        let ua = width == 32 ? UInt64(UInt32(truncatingIfNeeded: a)) : a
        let ub = width == 32 ? UInt64(UInt32(truncatingIfNeeded: b)) : b
        let sa = width == 32 ? Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a))) : Int64(bitPattern: a)
        let sb = width == 32 ? Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b))) : Int64(bitPattern: b)
        switch suffix {
        case "lt": return sa < sb
        case "le": return sa <= sb
        case "gt": return sa > sb
        case "ge": return sa >= sb
        case "lo": return ua < ub
        case "ls": return ua <= ub
        case "hi": return ua > ub
        case "hs": return ua >= ub
        default: preconditionFailure("fixture condition is not covered")
        }
    }

    private func decode(_ words: [UInt32]) -> [InstructionRow] {
        let bytes = words.reduce(into: Data()) { bytes, word in
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x1000, maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count)
        XCTAssertFalse(decoded.contains { ["unknown", "unavailable"].contains($0.mnemonic) })
        return decoded.map { .init(address: $0.address, bytes: $0.byteText,
            mnemonic: $0.mnemonic, operands: $0.operands, hasBreakpoint: false, comment: $0.comment) }
    }
}
