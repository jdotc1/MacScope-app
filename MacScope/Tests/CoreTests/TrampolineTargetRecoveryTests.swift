import Foundation
import XCTest
@testable import MacScope

final class TrampolineTargetRecoveryTests: XCTestCase {
    private let base: UInt64 = 0x1000

    private func instruction(
        _ offset: UInt64,
        _ mnemonic: String,
        _ flow: InstructionFlow,
        target: UInt64? = nil
    ) -> DecodedInstruction {
        DecodedInstruction(
            address: base + offset,
            bytes: [0, 0, 0, 0],
            mnemonic: mnemonic,
            operands: "",
            branchTarget: target,
            comment: nil,
            flow: flow
        )
    }

    func testRecoversTerminatorPrecededDirectJumpTarget() {
        let target = base + 0x14
        let instructions = [
            instruction(0x00, "b", .jump, target: target),
            instruction(0x04, "ret", .return),
            instruction(0x08, "nop", .normal),
            instruction(0x10, "ret", .return),
            instruction(0x14, "mov", .normal)
        ]

        let recovered = AnalysisEngine().recoverTrampolineTargets(
            from: instructions,
            knownStarts: [base],
            codeStart: base,
            codeEnd: base + 0x18,
            decodedInstructionAddresses: Set(instructions.map(\.address)),
            dataAddresses: []
        )

        XCTAssertEqual(recovered, [target])
    }

    func testRejectsTargetNotImmediatelyPrecededByTerminator() {
        let target = base + 0x10
        let instructions = [
            instruction(0x00, "b", .jump, target: target),
            instruction(0x0c, "mov", .normal),
            instruction(0x10, "ret", .return)
        ]

        let recovered = AnalysisEngine().recoverTrampolineTargets(
            from: instructions,
            knownStarts: [base],
            codeStart: base,
            codeEnd: base + 0x14,
            decodedInstructionAddresses: Set(instructions.map(\.address)),
            dataAddresses: []
        )

        XCTAssertTrue(recovered.isEmpty)
    }

    func testRejectsDataMarkedOutOfTextUndecodedAndAlreadyKnownTargets() {
        let dataTarget = base + 0x14
        let outOfTextTarget = base + 0x44
        let undecodedTarget = base + 0x30
        let knownTarget = base + 0x38
        let instructions = [
            instruction(0x00, "b", .jump, target: dataTarget),
            instruction(0x04, "b", .jump, target: outOfTextTarget),
            instruction(0x08, "b", .jump, target: undecodedTarget),
            instruction(0x0c, "b", .jump, target: knownTarget),
            instruction(0x10, "ret", .return),
            instruction(0x14, "mov", .normal),
            instruction(0x20, "ret", .return),
            instruction(0x2c, "ret", .return),
            instruction(0x30, "mov", .normal),
            instruction(0x34, "ret", .return),
            instruction(0x38, "mov", .normal),
            instruction(0x40, "ret", .return),
            instruction(0x44, "mov", .normal)
        ]
        let decodedAddresses = Set(instructions.map(\.address)).subtracting([undecodedTarget])

        let recovered = AnalysisEngine().recoverTrampolineTargets(
            from: instructions,
            knownStarts: [base, base + 0x04, base + 0x08, base + 0x0c, knownTarget],
            codeStart: base,
            codeEnd: base + 0x40,
            decodedInstructionAddresses: decodedAddresses,
            dataAddresses: [dataTarget]
        )

        XCTAssertTrue(recovered.isEmpty)
    }

    func testOnlyUnconditionalDirectJumpAtKnownStartIsATrampoline() {
        let target = base + 0x20
        let instructions = [
            instruction(0x00, "mov", .normal, target: target),
            instruction(0x04, "b.eq", .conditionalJump, target: target),
            instruction(0x08, "br", .indirectJump, target: target),
            instruction(0x1c, "ret", .return),
            instruction(0x20, "mov", .normal)
        ]

        let recovered = AnalysisEngine().recoverTrampolineTargets(
            from: instructions,
            knownStarts: [base, base + 0x04, base + 0x08],
            codeStart: base,
            codeEnd: base + 0x24,
            decodedInstructionAddresses: Set(instructions.map(\.address)),
            dataAddresses: []
        )

        XCTAssertTrue(recovered.isEmpty)
    }
}
