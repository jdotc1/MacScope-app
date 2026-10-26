import Foundation
import XCTest
@testable import MacScope

final class VectorScalarADDVAliasTests: XCTestCase {
    private func row(_ word: UInt32, _ operands: String, mnemonic: String = "addv") -> InstructionRow {
        let bytes = (0..<4).map { String(format: "%02x", (word >> ($0 * 8)) & 255) }.joined(separator: " ")
        return .init(address: 0x9000, bytes: bytes, mnemonic: mnemonic, operands: operands,
                     hasBreakpoint: false, comment: nil)
    }

    func testExactADDVWidthsAndReservedEncodings() throws {
        for (word, operands, bits, bytes) in [
            (UInt32(0x0e31ba10), "b16, v16.8b", 8, 8),
            (UInt32(0x4e31b820), "b0, v1.16b", 8, 16),
            (UInt32(0x0e71b820), "h0, v1.4h", 16, 8),
            (UInt32(0x4e71b820), "h0, v1.8h", 16, 16),
            (UInt32(0x4eb1b820), "s0, v1.4s", 32, 16)
        ] {
            let parsed = try XCTUnwrap(MacIRBuilder.scalarADDVCarrier(row(word, operands)))
            XCTAssertEqual(parsed.semantics.outputBits, bits)
            XCTAssertEqual(parsed.semantics.activeBytes, bytes)
            XCTAssertEqual(parsed.semantics.kind, .addv)
        }
        XCTAssertNil(MacIRBuilder.scalarADDVCarrier(row(0x0eb1b820, "s0, v1.2s")))
        XCTAssertNil(MacIRBuilder.scalarADDVCarrier(row(0x4ef1b820, "d0, v1.2d")))
        XCTAssertNil(MacIRBuilder.scalarADDVCarrier(row(0x4eb1b820, "s1, v1.4s")))
        XCTAssertNil(MacIRBuilder.scalarADDVCarrier(row(0x4eb1b820, "s0, v2.4s")))
        XCTAssertNil(MacIRBuilder.scalarADDVCarrier(row(0x4eb1b820, "d0, v1.4s")))
        XCTAssertNil(MacIRBuilder.scalarADDVCarrier(row(0x4eb1b820, "s0, v1.4s", mnemonic: "fadd")))
    }

    func testAliasedByteReductionReadsOldVAndClearsAllOtherBits() throws {
        var function = MacIRBuilder().buildFunction(name: "byte_reduce",
            instructions: [row(0x0e31ba10, "b16, v16.8b")])
        let instruction = try XCTUnwrap(function.instructions.first { $0.neonReduction != nil })
        guard case let .intrinsic(destination?, name, arguments) = instruction.operation else {
            return XCTFail("expected typed integer reduction")
        }
        XCTAssertEqual(name, "integer_horizontal_output")
        XCTAssertEqual(arguments, [.register(name: "v16", version: 0)])
        XCTAssertEqual(destination, .register(name: "v16", version: 1))
        let text = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: false, deadCodeElimination: false, nopElision: false, functionSizeGate: 1_024))
            .print(function: function).text
        XCTAssertTrue(text.contains("__neon_addv_8b_to_b_zero_upper"), text)
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        state.v[16] = .init(low: .max, high: .max)
        for index in function.instructions.indices {
            function.instructions[index].source.mnemonic = "redacted"
            function.instructions[index].source.operands = ""
        }
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.run(function.instructions)
        XCTAssertEqual(evaluator.state.v[16].low, 0xf8)
        XCTAssertEqual(evaluator.state.v[16].high, 0)
    }

    func testPhysicalViewsSnapshotAndCallClobberRemainDistinctFromFPTypes() {
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        state.permitsNEONScalarViewCarrier = true
        let callerValue = state.writeRegister("v0")
        XCTAssertEqual(state.readRegister("b0"), callerValue)
        let value = state.writeRegister("v8")
        let snapshot = state
        for prefix in ["b", "h", "s", "d", "q", "v"] {
            XCTAssertEqual(state.readRegister("\(prefix)8"), value)
        }
        state.invalidateGeneralVectorRegionAtCall(returning: nil)
        XCTAssertEqual(state.readRegister("d8"), value)
        XCTAssertEqual(state.readRegister("q8"), .unknown("unavailable_upper_v8"))
        XCTAssertEqual(state.readRegister("b0"), .unknown("unavailable_v0"))
        XCTAssertEqual(snapshot.readRegister("q8"), value)
        let replacement = state.writeRegister("v8")
        XCTAssertNotEqual(replacement, value)
        XCTAssertEqual(state.readRegister("q8"), replacement)
        XCTAssertEqual(snapshot.readRegister("q8"), value)
    }

    func testPartialINSUpdatesCarrierBeforeFollowingReduction() throws {
        let first = row(0x0e31ba10, "b16, v16.8b")
        let partial = InstructionRow(address: 0x9004, bytes: "", mnemonic: "ins",
            operands: "v16.b[1], w0", hasBreakpoint: false, comment: nil)
        let last = InstructionRow(address: 0x9008, bytes: first.bytes, mnemonic: "addv",
            operands: first.operands, hasBreakpoint: false, comment: nil)
        let function = MacIRBuilder().buildFunction(name: "refused_partial", instructions: [first, partial, last])
        let reduction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x9000 })
        guard case let .intrinsic(reduced?, _, _) = reduction.operation else {
            return XCTFail("expected initial reduction")
        }
        let insertion = try XCTUnwrap(function.instructions.first { $0.source.address == 0x9004 })
        XCTAssertEqual(insertion.neonBitView?.kind, .insertGPR)
        XCTAssertEqual(insertion.neonBitView?.elementBits, 8)
        XCTAssertEqual(insertion.neonBitView?.destinationLane, 1)
        guard case let .intrinsic(inserted?, _, inputs) = insertion.operation else {
            return XCTFail("expected typed partial insertion")
        }
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs.last, reduced)
        XCTAssertNotEqual(inserted, reduced)
        let consumer = try XCTUnwrap(function.instructions.first { $0.source.address == 0x9008 })
        guard case let .intrinsic(_, _, arguments) = consumer.operation else {
            return XCTFail("expected reduction after partial insertion")
        }
        XCTAssertEqual(arguments, [inserted])
    }

    func testExistingLaneLoadPreservesOnlyComplementOfWrittenLane() throws {
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        state.permitsNEONScalarViewCarrier = true
        let reduced = state.writeRegister("v16")
        let snapshot = state
        let old = state.readRegister("q16")
        let destination = state.writeRegister("v16")
        let lane = try XCTUnwrap(MacIRNEONLaneMemory(effect: .load, elementBytes: 1, laneIndex: 1,
            baseRegister: "x0", oldBase: .register(name: "x0", version: 0), oldVector: old,
            destination: destination, baseDestination: nil, frameSequence: 0, firstByteSequence: 0))
        XCTAssertEqual(lane.oldVector, reduced)
        XCTAssertEqual(lane.preservedVectorBytes, [0] + Array(2..<16))
        XCTAssertEqual(lane.vectorByteOffset, 1)
        XCTAssertEqual(snapshot.readRegister("q16"), reduced)
        XCTAssertEqual(state.readRegister("q16"), destination)
    }

    func testExternalFactsAndScalarFPStillRefuseRegion() {
        let reduction = row(0x4eb1b820, "s0, v1.4s")
        XCTAssertNil(MacIRBuilder().buildGeneralVectorRegion(name: "external", startAddress: 0x9000,
            rows: [reduction], initialState: BuilderState(parameters: []),
            hasExternalFacts: true, isVariadic: false))
        let fp = InstructionRow(address: 0x9004, bytes: "00 28 20 1e", mnemonic: "fadd",
            operands: "s0, s0, s0", hasBreakpoint: false, comment: nil)
        XCTAssertNil(MacIRBuilder().buildGeneralVectorRegion(name: "fp", startAddress: 0x9000,
            rows: [reduction, fp], initialState: BuilderState(parameters: []),
            hasExternalFacts: false, isVariadic: false))
    }
}
