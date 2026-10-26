import Foundation
import XCTest
@testable import MacScope

final class VectorStatusStateRouteTests: XCTestCase {
    private func row(_ word: UInt32, _ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        let bytes = (0..<4).map { String(format: "%02x", UInt8(truncatingIfNeeded: word >> ($0 * 8))) }
            .joined(separator: " ")
        return InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
                              hasBreakpoint: false, comment: nil)
    }

    func testObservedOrdinaryQCUsesOneExplicitStickyEffect() throws {
        // Arm2025-12 sqshrn_advsimd.xml#Operation: SignedSatQ and FPSR.QC.
        // MRS only requests observation here; whole system-register access remains
        // outside this normal arithmetic contract and may independently be refused.
        let rows = [row(0x0f0b94e1, 0x1000, "sqshrn", "v1.8b, v7.8h, #5"),
                    row(0xd53b4420, 0x1004, "mrs", "x0, fpsr"),
                    row(0xd65f03c0, 0x1008, "ret", "")]
        let function = MacIRBuilder(ssaEnabled: false, ssaCancellation: { false })
            .buildFunction(name: "observed_qc", startAddress: 0x1000, instructions: rows)
        let numeric = try XCTUnwrap(function.instructions.first { $0.neonLaneOp != nil })
        XCTAssertTrue(numeric.neonQCIsSeparate)
        let effects = function.instructions.compactMap(\.neonQC)
        XCTAssertEqual(effects.count, 1)
        let effect = try XCTUnwrap(effects.first)
        XCTAssertEqual(effect.lane.kind, .sqshrn)
        XCTAssertEqual(effect.input, .register(name: "qc", version: 0))
        XCTAssertEqual(effect.output, effect.input) // Architectural in-place, not a CFG SSA claim.
        XCTAssertNil(effect.evaluate(inputQC: nil, n: (0, 0), m: (0, 0)))
        XCTAssertEqual(effect.evaluate(inputQC: true, n: (0, 0), m: (0, 0)), true)
        XCTAssertEqual(effect.evaluate(inputQC: nil, n: (.max >> 1, 0), m: (0, 0)), true)
    }

    func testUnobservedQCIsDeclaredButNotInventedAsZero() throws {
        let rows = [row(0x0f0b94e1, 0x1000, "sqshrn", "v1.8b, v7.8h, #5"),
                    row(0xd65f03c0, 0x1004, "ret", "")]
        let function = MacIRBuilder(ssaEnabled: false, ssaCancellation: { false })
            .buildFunction(name: "unobserved_qc", startAddress: 0x1000, instructions: rows)
        let numeric = try XCTUnwrap(function.instructions.first { $0.neonLaneOp != nil })
        XCTAssertEqual(numeric.neonLaneOp?.setsQC, true)
        XCTAssertFalse(numeric.neonQCIsSeparate)
        XCTAssertFalse(function.instructions.contains { $0.neonQC != nil })
        XCTAssertFalse(function.observesFPSR)
    }
    func testActualSSAQCDefinesBothHalvesAndClobbersExistingCell98AtCall() throws {
        for (word, mnemonic, operands, high) in [
            (UInt32(0x0f0b94e1), "sqshrn", "v1.8b, v7.8h, #5", false),
            (UInt32(0x4f0b9601), "sqshrn2", "v1.16b, v16.8h, #5", true)
        ] {
            // A call-site contract selects the actual SSA fallback on this base.
            let rows = [row(word, 0x1000, mnemonic, operands),
                        row(0xd53b4420, 0x1004, "mrs", "x0, fpsr"),
                        row(0xd63f0100, 0x1008, "blr", "x8"),
                        row(0xd65f03c0, 0x100c, "ret", "")]
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
                .buildFunction(name: "ssa_qc_halves", startAddress: 0x1000,
                    slotCallContracts: [0x1008: .init(returnType: "void", parameters: [])], instructions: rows)
            XCTAssertTrue(function.ssaEnabled)
            let info = try XCTUnwrap(function.ssaInfo)
            let lowID = try XCTUnwrap(info.plan.rowWriteBindings[0][33])
            let highID = try XCTUnwrap(info.plan.rowWriteBindings[0][65])
            let qcID = try XCTUnwrap(info.plan.rowWriteBindings[0][98])
            let numeric = try XCTUnwrap(function.instructions.first { $0.neonLaneOp != nil })
            XCTAssertEqual(numeric.neonLaneOp?.highHalf, high)
            XCTAssertTrue(numeric.neonQCIsSeparate)
            let qc = try XCTUnwrap(function.instructions.compactMap(\.neonQC).first)
            XCTAssertEqual(qc.output, info.values[qcID])
            for (id, projection) in [(lowID, "__ssa_low64"), (highID, "__ssa_high64")] {
                let value = try XCTUnwrap(info.values[id])
                XCTAssertTrue(function.instructions.contains {
                    guard case let .assign(destination, .unary(op, _)) = $0.operation else { return false }
                    return destination == value && op == projection
                })
                if case .immediate = value { XCTFail("A projected definition cannot be an immediate destination") }
            }
            let callQC = try XCTUnwrap(info.plan.rowWriteBindings[2][98])
            XCTAssertEqual(info.plan.definitions[callQC].origin, .callClobber(0x1008))
        }
    }

}
