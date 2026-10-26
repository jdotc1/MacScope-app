import Foundation
import XCTest
@testable import MacScope

final class NEONDotReductionSemanticsTests: XCTestCase {
    typealias V = A64MachineState.V128

    // Literal encodings come from Arm A64 2025-12 register diagrams. No
    // assembler, decoder or architectural runner supplies the expected values.
    private func check(_ bytes: String, _ mnemonic: String, _ operands: String,
                       vectors: [Int: V], destination: Int = 0, gpr: Bool = false,
                       low: UInt64, high: UInt64 = 0,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let source = MacIRSourceSpan(address: 0x1000, byteText: bytes,
            mnemonic: mnemonic, operands: operands)
        let admitted = try XCTUnwrap(MacIRBuilder.ssaVectorPermutation(source), file: file, line: line)
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertTrue(effects.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(effects.writes.map { $0.cell }),
            gpr ? Set([destination]) : Set([32 + destination, 64 + destination]), file: file, line: line)
        XCTAssertFalse(effects.reads.contains(98), file: file, line: line)
        XCTAssertFalse(effects.reads.contains(99), file: file, line: line)
        for ssa in [false, true] {
            var rows = [InstructionRow(address: 0x1000, bytes: bytes, mnemonic: mnemonic,
                operands: operands, hasBreakpoint: false, comment: nil)]
            // Defeat the legacy vector-leaf fast path for the SSA case.
            if ssa {
                rows.append(.init(address: 0x1004, bytes: "29 05 00 91", mnemonic: "add",
                    operands: "x9, x9, #1", hasBreakpoint: false, comment: nil))
            }
            rows.append(.init(address: ssa ? 0x1008 : 0x1004, bytes: "c0 03 5f d6",
                mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil))
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "typed_vector_arithmetic", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ssa, file: file, line: line)
            let instruction = try XCTUnwrap(function.instructions.first {
                $0.source.address == 0x1000 && ($0.neonByteDotProduct != nil || $0.neonReduction != nil
                    || $0.neonBitView?.kind == .unsignedMoveElement)
            }, file: file, line: line)
            XCTAssertEqual(instruction.neonByteDotProduct, admitted.dot, file: file, line: line)
            XCTAssertEqual(instruction.neonReduction, admitted.reduction, file: file, line: line)
            XCTAssertEqual(instruction.neonBitView, admitted.bitView, file: file, line: line)
            if gpr {
                XCTAssertEqual(instruction.neonBitView?.kind, .unsignedMoveElement, file: file, line: line)
                XCTAssertNil(instruction.neonReduction, file: file, line: line)
                XCTAssertFalse(admitted.readsDestination, file: file, line: line)
                XCTAssertFalse(effects.reads.contains(destination), file: file, line: line)
                XCTAssertEqual(effects.writes.first?.view, .integer, file: file, line: line)
            }
            guard case let .intrinsic(result?, _, arguments) = instruction.operation else {
                return XCTFail("missing shared typed operation", file: file, line: line)
            }
            XCTAssertEqual(arguments.count, admitted.dot == nil ? 1 : 3, file: file, line: line)
            if gpr, (8...15).contains(destination), case let .register(name, version) = result {
                let binding = try XCTUnwrap(function.nameBindings.first {
                    $0.target == .register(name: name, version: version)
                }, file: file, line: line)
                XCTAssertEqual(binding.type, "uint64_t", file: file, line: line)
            }
            if admitted.sources.first == admitted.destination {
                XCTAssertNotEqual(arguments[0], result, file: file, line: line)
                if admitted.dot != nil {
                    XCTAssertEqual(arguments[0], arguments[2], file: file, line: line)
                }
            }
            var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
                from: Data("{}".utf8)))
            for (index, value) in vectors { state.v[index] = value }
            state.fpsr = 0x08000000
            // The narrow oracle accepts canonical vN carriers, not SSA join
            // expressions. Evaluate the SAME attached descriptor in an explicit
            // carrier fixture; this is not execution of the SSA function above.
            let fixture = MacIRFunction(name: "descriptor_fixture", startAddress: 0x1000, instructions: [])
            var evaluator = MacIRConcreteEvaluator(function: fixture, state: state)
            var inputs = admitted.sources.map { MacIRValue.register(name: $0, version: 0) }
            if admitted.readsDestination { inputs.append(.register(name: admitted.destination, version: 0)) }
            let operation = MacIROperation.intrinsic(
                destination: .register(name: admitted.destination, version: 1),
                name: admitted.intrinsicName, arguments: inputs)
            if let dot = instruction.neonByteDotProduct {
                try evaluator.executeNEONByteDotProduct(dot, operation: operation)
            } else if let bitView = instruction.neonBitView {
                try evaluator.executeNEONBitView(bitView, operation: operation)
            } else {
                try evaluator.executeNEONReduction(try XCTUnwrap(instruction.neonReduction), operation: operation)
            }
            if gpr {
                XCTAssertEqual(evaluator.state.x[destination], low, file: file, line: line)
                for (index, original) in vectors {
                    XCTAssertEqual(evaluator.state.v[index], original, file: file, line: line)
                }
            } else {
                XCTAssertEqual(evaluator.state.v[destination].low, low, file: file, line: line)
                XCTAssertEqual(evaluator.state.v[destination].high, high, file: file, line: line)
            }
            XCTAssertEqual(evaluator.state.fpsr, 0x08000000, file: file, line: line)
        }
    }

    // SDOT: SInt(bytes), four products per output, then add OLD32 modulo 2^32.
    func testSDOTSignedGroupsBothModes() throws {
        // [-1,-128,127,1] repeated four times per group, times1, plus[10,20,30,40].
        try check("20 94 82 4e", "sdot", "v0.4s, v1.16b, v2.16b", vectors: [
            0: V(low: 0x000000140000000a, high: 0x000000280000001e),
            1: V(low: 0x80808080ffffffff, high: 0x010101017f7f7f7f),
            2: V(low: 0x0101010101010101, high: 0x0101010101010101)],
            low: 0xfffffe1400000006, high: 0x0000002c0000021a)
    }
    func testSDOTMinimumProductWrapBothModes() throws {
        // 4*(-128)*(-128) + 0xffffffff = 0x0000ffff modulo32, not saturation.
        try check("20 94 82 4e", "sdot", "v0.4s, v1.16b, v2.16b", vectors: [
            0: V(low: .max, high: .max),
            1: V(low: 0x8080808080808080, high: 0x8080808080808080),
            2: V(low: 0x8080808080808080, high: 0x8080808080808080)],
            low: 0x0000ffff0000ffff, high: 0x0000ffff0000ffff)
    }
    func testSDOTAliasedAccumulatorBothModes() throws {
        // Vd==Vn: snapshot bytes1 and OLD32=0x01010101 before adding four.
        try check("21 94 82 4e", "sdot", "v1.4s, v1.16b, v2.16b", vectors: [
            1: V(low: 0x0101010101010101, high: 0x0101010101010101),
            2: V(low: 0x0101010101010101, high: 0x0101010101010101)], destination: 1,
            low: 0x0101010501010105, high: 0x0101010501010105)
    }
    func testUDOTUnsignedMaximumBothModes() throws {
        // 4*255*255=260100=0x3f804, not four signed products.
        try check("20 94 82 6e", "udot", "v0.4s, v1.16b, v2.16b", vectors: [
            1: V(low: .max, high: .max), 2: V(low: .max, high: .max)],
            low: 0x0003f8040003f804, high: 0x0003f8040003f804)
    }
    func testUDOTGroupOrderAndWrapBothModes() throws {
        // Group sums[4,8,12,16] plus 0xffffffff wrap independently to[3,7,11,15].
        try check("20 94 82 6e", "udot", "v0.4s, v1.16b, v2.16b", vectors: [
            0: V(low: .max, high: .max),
            1: V(low: 0x0202020201010101, high: 0x0404040403030303),
            2: V(low: 0x0101010101010101, high: 0x0101010101010101)],
            low: 0x0000000700000003, high: 0x0000000f0000000b)
    }
    func testUDOTAliasedAccumulatorBothModes() throws {
        // Vd==Vn: OLD32=0x01010101 plus4*255=1020, without cross-lane carry.
        try check("21 94 82 6e", "udot", "v1.4s, v1.16b, v2.16b", vectors: [
            1: V(low: 0x0101010101010101, high: 0x0101010101010101),
            2: V(low: .max, high: .max)], destination: 1,
            low: 0x010104fd010104fd, high: 0x010104fd010104fd)
    }
    // ADDV: IntReduce ADD followed by V{32}; every physical bit above31 is zero.
    func testADDVAllFourLanesBothModes() throws {
        try check("20 b8 b1 4e", "addv", "s0, v1.4s", vectors: [
            0: V(low: .max, high: .max), 1: V(low: 0x0000000200000001, high: 0x0000000400000003)], low: 10)
    }
    func testADDVModuloNotSaturationBothModes() throws {
        // Four 0xffffffff sum to 0x3fffffffc; retain low32.
        try check("20 b8 b1 4e", "addv", "s0, v1.4s", vectors: [1: V(low: .max, high: .max)], low: 0xfffffffc)
    }
    func testADDVAliasedSourceClearsUpperBothModes() throws {
        // 0x80000000 + 0x80000000 + 1 + 2 -> 3, including upper-source lanes.
        try check("21 b8 b1 4e", "addv", "s1, v1.4s", vectors: [
            1: V(low: 0x8000000080000000, high: 0x0000000200000001)], destination: 1, low: 3)
    }
    // UMAXV: UInt comparison of all four32-bit lanes, scalar result zero-extended.
    func testUMAXVUnsignedSignBoundaryBothModes() throws {
        try check("20 a8 b0 6e", "umaxv", "s0, v1.4s", vectors: [
            1: V(low: 0x800000007fffffff, high: 0x0000000100000000)], low: 0x80000000)
    }
    func testUMAXVLastLaneBothModes() throws {
        try check("20 a8 b0 6e", "umaxv", "s0, v1.4s", vectors: [
            0: V(low: .max, high: .max), 1: V(low: 0x0000000200000001, high: 0xffffffff00000003)], low: 0xffffffff)
    }
    func testUMAXVAliasedEqualLanesBothModes() throws {
        try check("21 a8 b0 6e", "umaxv", "s1, v1.4s", vectors: [
            1: V(low: 0x8765432187654321, high: 0x8765432187654321)], destination: 1, low: 0x87654321)
    }
    // UMOV: Xd=ZeroExtend(Vn.D[index],64); no modification to the source vector.
    func testUMOVUpperLaneBothModes() throws {
        try check("20 3c 18 4e", "umov", "x0, v1.d[1]", vectors: [
            1: V(low: 0x0123456789abcdef, high: 0xfedcba9876543210)], gpr: true, low: 0xfedcba9876543210)
    }
    func testUMOVLowerLaneBothModes() throws {
        try check("20 3c 08 4e", "umov", "x0, v1.d[0]", vectors: [
            1: V(low: 0x8000000000000001, high: .max)], gpr: true, low: 0x8000000000000001)
    }
    func testUMOVIndependentRegisterNamespacesBothModes() throws {
        try check("21 3c 18 4e", "umov", "x1, v1.d[1]", vectors: [
            1: V(low: .max, high: 0x0123456789abcdef)], destination: 1, gpr: true, low: 0x0123456789abcdef)
    }

    func testTypedArithmeticRequiresByteTextAgreement() {
        for (bytes, mnemonic, operands) in [
            ("20 94 82 4e", "udot", "v0.4s, v1.16b, v2.16b"),
            ("20 94 82 4e", "sdot", "v0.4s, v1.16b, v3.16b"),
            ("20 94 82 0e", "sdot", "v0.2s, v1.8b, v2.8b"),
            ("20 a8 b0 2e", "umaxv", "s0, v1.2s"),
            ("20 b8 b1 4e", "addv", "s1, v1.4s"),
            ("20 3c 18 4e", "umov", "x0, v1.d[0]"),
            ("3f 3c 18 4e", "umov", "sp, v1.d[1]")
        ] {
            XCTAssertNil(MacIRBuilder.ssaVectorPermutation(.init(address: 0x1000,
                byteText: bytes, mnemonic: mnemonic, operands: operands)))
        }
    }

    // Keep the original S1 regression untouched. These literal-row cases add
    // numerical lane expectations and both requested flag settings without
    // invoking the decoder. This loop selects the general region in both.
    func testUMOVXLoopRestoresTypedCopyAndAliasesBothFlags() throws {
        try checkLoopCopy(wide: true, bytes: "8e 3c 18 4e", operand: "x14, v4.d[1]",
            extracted: 0x0707070707070707, product: 0x1515151515151515)
    }

    func testUMOVWLoopKeepsTypedCopyAndZeroExtensionBothFlags() throws {
        try checkLoopCopy(wide: false, bytes: "8e 3c 14 0e", operand: "w14, v4.s[2]",
            extracted: 0x07070707, product: 0x15151515)
    }

    private func checkLoopCopy(wide: Bool, bytes: String, operand: String,
                               extracted: UInt64, product: UInt64) throws {
        let specifications = [
            ("e4 e4 00 4f", "movi", "v4.16b, #7"),
            ("2e 01 80 d2", "mov", "x14, #9"),
            ("6a 00 80 d2", "mov", "x10, #3"),
            (bytes, "umov", operand),
            ("cf 7d 0a 9b", "mul", "x15, x14, x10"),
            ("f0 03 0e 2a", "mov", "w16, w14"),
            ("1f 20 03 d5", "nop", ""),
            ("e5 ff ff b5", "cbnz", "x5, 0x1018"),
            ("c0 03 5f d6", "ret", "")
        ]
        let rows = specifications.enumerated().map { index, item in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: item.0,
                mnemonic: item.1, operands: item.2, hasBreakpoint: false, comment: nil)
        }
        for requestedSSA in [false, true] {
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: requestedSSA)
                .buildFunction(name: "typed_copy_loop", startAddress: 0x1000, instructions: rows)
            XCTAssertFalse(function.ssaEnabled, "the general vector region precedes SSA dispatch")
            let vector = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
            let extraction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x100c })
            let descriptor = try XCTUnwrap(extraction.neonBitView)
            XCTAssertEqual(descriptor.kind, .unsignedMoveElement)
            XCTAssertEqual(descriptor.elementBits, wide ? 64 : 32)
            XCTAssertEqual(descriptor.sourceLane, wide ? 1 : 2)
            XCTAssertFalse(descriptor.readsOldDestination)
            XCTAssertNil(extraction.neonReduction)
            guard case let .intrinsic(destination?, _, inputs) = extraction.operation,
                  case let .intrinsic(vectorDestination?, _, _) = vector.operation else {
                return XCTFail("missing typed MOVI or lane extraction")
            }
            XCTAssertEqual(inputs, [vectorDestination])
            let immediate = try XCTUnwrap(vector.neonImmediate)
            let value = descriptor.selectedBits(low: immediate.low, high: immediate.high)
            XCTAssertEqual(value, extracted)
            XCTAssertEqual(value &* 3, product)
            let multiply = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
            guard case let .binary(_, operation, left, _) = multiply.operation else {
                return XCTFail("missing multiply consumer")
            }
            XCTAssertEqual(operation, "*")
            XCTAssertEqual(left, wide ? destination : .unary(op: "(uint64_t)",
                value: .unary(op: "(uint32_t)", value: destination)))
            let narrow = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1014 })
            guard case let .assign(_, narrowValue) = narrow.operation else { return XCTFail("missing W-view consumer") }
            XCTAssertEqual(narrowValue, wide ? .unary(op: "(uint32_t)", value: destination) : destination)
        }
    }

    func testUMOVXRecordsUnsignedTypeInActualSSABothModes() throws {
        try check("8e 3c 18 4e", "umov", "x14, v4.d[1]", vectors: [
            4: V(low: 0x0123456789abcdef, high: 0xfedcba9876543210)],
            destination: 14, gpr: true, low: 0xfedcba9876543210)
    }

    func testUMOVTypedBridgeRejectsInvalidLaneAndDestination() {
        for (bytes, text) in [
            ("8e 3c 18 4e", "x14, v4.d[2]"),
            ("8e 3c 18 4e", "x31, v4.d[1]"),
            ("8e 3c 18 4e", "sp, v4.d[1]"),
            ("8e 3c 18 4e", "w14, v4.d[1]"),
            ("8e 3c 18 4e", "x15, v4.d[1]"),
            ("9f 3c 18 4e", "xzr, v4.d[1]"),
            ("8e 3c 14 0e", "w14, v4.s[2]")
        ] {
            XCTAssertNil(MacIRBuilder.ssaVectorPermutation(.init(address: 0x1000,
                byteText: bytes, mnemonic: "umov", operands: text)))
        }
        // Decoder aliases remain canonical UMOV/INS; do not reinterpret MOV
        // text or INS bytes as this deliberately narrow X<-D SSA bridge.
        for (bytes, mnemonic, text) in [
            ("8e 3c 18 4e", "mov", "x14, v4.d[1]"),
            ("20 1c 18 4e", "umov", "x14, v4.d[1]"),
            ("8e 3c 18 4e", "ins", "v0.d[1], x1")
        ] {
            XCTAssertNil(MacIRBuilder.ssaVectorPermutation(.init(address: 0x1000,
                byteText: bytes, mnemonic: mnemonic, operands: text)))
        }
        // These malformed operands also fail the legacy textual copy contract.
        // A byte/register mismatch alone is not a legacy text-parser promise.
        for text in ["x14, v4.d[2]", "x31, v4.d[1]", "sp, v4.d[1]", "w14, v4.d[1]"] {
            XCTAssertNil(MacIRBuilder.neonCopy(mnemonic: "umov", operandText: text))
        }
    }

    func testUMOVDoesNotBorrowINSPreservedDestinationRead() throws {
        let move = MacIRSourceSpan(address: 0x1000, byteText: "8e 3c 18 4e",
            mnemonic: "umov", operands: "x14, v4.d[1]")
        let insert = MacIRSourceSpan(address: 0x1004, byteText: "20 1c 18 4e",
            mnemonic: "ins", operands: "v0.d[1], x1")
        let extraction = try XCTUnwrap(MacIRBuilder.ssaVectorPermutation(move))
        let insertion = try XCTUnwrap(MacIRBuilder.ssaVectorPermutation(insert))
        XCTAssertFalse(extraction.readsDestination)
        XCTAssertTrue(insertion.readsDestination)
        XCTAssertEqual(MacIRBuilder.ssaEffects(for: move).readViews.keys.sorted(), [36, 68])
        XCTAssertEqual(MacIRBuilder.ssaEffects(for: insert).readViews.keys.sorted(), [1, 32, 64])
        let descriptor = try XCTUnwrap(insertion.bitView)
        let result = descriptor.vectorBits(sourceLow: 0x0123456789abcdef, sourceHigh: 0,
            oldLow: 0xfedcba9876543210, oldHigh: 0xffffffffffffffff)
        XCTAssertEqual(result.low, 0xfedcba9876543210)
        XCTAssertEqual(result.high, 0x0123456789abcdef)
    }

}
