import Foundation
import XCTest
@testable import MacScope

final class S1VectorUnknownGPRDestinationTests: XCTestCase {
    func testTypedUMOVXReplacesBothViewsBeforeMultiply() throws {
        try checkUMOV(word: 0x4e183c8e, operand: "x14, v4.d[1]")
    }

    func testTypedUMOVWReplacesBothViewsBeforeMultiply() throws {
        try checkUMOV(word: 0x0e143c8e, operand: "w14, v4.s[2]")
    }

    func testGenericUnknownGPRDestinationsDoNotRequireMnemonicWhitelist() {
        for register in ["x19", "w23"] {
            var state = BuilderState()
            let previous = state.writeRegister(register)
            state.recordMaterializedImmediate(9, for: register)
            let refused = MacIRBuilder().generalVectorRefusal(
                row("unmodeled_transfer", "\(register), x8"), state: &state)
            guard case let .unknown(destination, _, _, _) = refused.operation else {
                return XCTFail("unmodeled operation must remain unknown")
            }
            XCTAssertNil(destination, "invalidation is not a fabricated producer")
            let index = String(register.dropFirst())
            XCTAssertEqual(state.readRegister("x\(index)"), .unknown("unavailable_x\(index)"))
            XCTAssertEqual(state.readRegister("w\(index)"), .unknown("unavailable_w\(index)"))
            XCTAssertNotEqual(state.readRegister(register), previous)
            XCTAssertNil(state.materializedImmediate(for: register))
        }
    }

    func testRefusalKeepsReadAndControlInputsAndStoreEffectsWithoutFakeProducer() throws {
        var state = BuilderState()
        let previous = state.writeRegister("x14")
        let compare = MacIRBuilder().generalVectorRefusal(row("cmp", "x14, x8"), state: &state)
        guard case let .unknown(compareDestination, compareInputs, _, _) = compare.operation else {
            return XCTFail("directly refused CMP must remain an unknown read")
        }
        XCTAssertNil(compareDestination)
        XCTAssertTrue(compareInputs.mayRead.contains { $0.register == "x14" && $0.value == previous })
        XCTAssertEqual(state.readRegister("x14"), previous, "a comparison is not a register write")

        let branch = MacIRBuilder().generalVectorRefusal(row("cbz", "x14, 0x1008"), state: &state)
        guard case let .conditionalBranch(_, left, _, _) = branch.operation else {
            return XCTFail("control refusal must keep its normal branch operation")
        }
        XCTAssertEqual(left, previous)
        XCTAssertEqual(state.readRegister("x14"), previous)

        state.stackSlotValues[0] = .init(value: .immediate(42), byteWidth: 8, carrierKind: .integer)
        let store = MacIRBuilder().generalVectorRefusal(row("st64b", "x14, [x8]"), state: &state)
        guard case let .unknown(storeDestination, storeInputs, _, _) = store.operation else {
            return XCTFail("unsupported store must remain unknown")
        }
        XCTAssertNil(storeDestination, "a conservative invalidation must not claim the store source as a result")
        XCTAssertTrue(storeInputs.mayRead.contains { $0.register == "x14" && $0.value == previous },
                      "unknown reads must be bound before invalidation")
        XCTAssertTrue(state.stackSlotValues.isEmpty, "a refused store must still invalidate cached memory")
    }

    private func checkUMOV(word: UInt32, operand: String) throws {
        // Independently assembled with retained Linux LLVM, not Apple-native
        // validation. A decoded MOVI plus a reachable non-entry loop admit
        // the production region path; the tested rows precede that loop.
        let words: [UInt32] = [0x4f00e4e4, 0xd280012e, 0xd280006a, word,
                              0x9b0a7dcf, 0x2a0e03f0, 0xd503201f, 0xb5ffffe5, 0xd65f03c0]
        let bytes = words.reduce(into: Data()) { bytes, word in
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x1000, maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count)
        XCTAssertEqual(decoded[3].mnemonic, "umov")
        XCTAssertEqual(decoded[3].operands, operand)
        XCTAssertFalse(decoded.contains { ["unknown", "unavailable"].contains($0.mnemonic) })
        let rows = decoded.map { InstructionRow(address: $0.address, bytes: $0.byteText,
            mnemonic: $0.mnemonic, operands: $0.operands, hasBreakpoint: false, comment: $0.comment) }
        XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(rows))
        let function = MacIRBuilder().buildFunction(name: "typed_lane_extract",
            startAddress: 0x1000, instructions: rows)
        let vector = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
        XCTAssertNotNil(vector.neonImmediate, "the production general-vector path must claim the fixture")
        let backedge = try XCTUnwrap(function.instructions.first { $0.source.address == 0x101c })
        guard case let .conditionalBranch(_, _, _, target) = backedge.operation else {
            return XCTFail("the decoded CBNZ must retain its reachable loop backedge")
        }
        XCTAssertEqual(target, .immediate(0x1018))
        let extraction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x100c })
        let isWide = operand.hasPrefix("x")
        XCTAssertEqual(extraction.neonBitView?.kind, .unsignedMoveElement)
        XCTAssertEqual(extraction.neonBitView?.elementBits, isWide ? 64 : 32)
        XCTAssertEqual(extraction.neonBitView?.sourceLane, isWide ? 1 : 2)
        guard case let .intrinsic(destination?, _, inputs) = extraction.operation,
              case let .intrinsic(vectorDestination?, _, _) = vector.operation else {
            return XCTFail("UMOV must extract from the modeled vector definition")
        }
        guard case .register = destination else { return XCTFail("UMOV must define a fresh register") }
        guard case let .register(name, _) = try XCTUnwrap(inputs.first) else {
            return XCTFail("UMOV must read the current vector source")
        }
        XCTAssertEqual(name, "v4")
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs, [vectorDestination])
        let wideValue: MacIRValue = isWide ? destination : .unary(op: "(uint64_t)",
            value: .unary(op: "(uint32_t)", value: destination))
        let narrowValue: MacIRValue = isWide ? .unary(op: "(uint32_t)", value: destination) : destination
        let multiply = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
        guard case let .binary(_, operation, left, _) = multiply.operation else {
            return XCTFail("MUL must keep its modeled scalar operation: \(multiply.operation)")
        }
        XCTAssertEqual(operation, "*")
        XCTAssertEqual(left, wideValue, "MUL must consume the lane extraction rather than the old MOV")
        let narrowRead = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1014 })
        guard case let .assign(_, value) = narrowRead.operation else {
            return XCTFail("expected the W-view read after UMOV")
        }
        XCTAssertEqual(value, narrowValue, "the W view must read the new lane extraction")
    }

    private func row(_ mnemonic: String, _ operands: String) -> InstructionRow {
        .init(address: 0x1000, bytes: "", mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil)
    }
}
