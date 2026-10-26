import Foundation

extension ARM64Decoder {
    func decodeUnconditionalBranch(
        word: UInt32,
        bytes: [UInt8],
        address: UInt64,
        mnemonic: String
    ) -> DecodedInstruction {
        let immediate = signExtend(Int(word & 0x03ff_ffff), bitCount: 26) * 4
        return decodeBranchTarget(
            immediate,
            word: word,
            bytes: bytes,
            address: address,
            mnemonic: mnemonic,
            operandsPrefix: nil
        )
    }

    func decodeConditionalBranch(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let condition = Int(word & 0xf)
        let mnemonic = "b.\(conditionName(condition))"
        let immediate = signExtend(Int((word >> 5) & 0x7ffff), bitCount: 19) * 4
        return decodeBranchTarget(
            immediate,
            word: word,
            bytes: bytes,
            address: address,
            mnemonic: mnemonic,
            operandsPrefix: nil,
            condition: InstructionOperands.Condition(rawValue: conditionName(condition))
        )
    }

    func decodeCompareAndBranch(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isNonZero = (word & 0x0100_0000) != 0
        let source = Int(word & 0x1f)
        let immediate = signExtend(Int((word >> 5) & 0x7ffff), bitCount: 19) * 4
        return decodeBranchTarget(
            immediate,
            word: word,
            bytes: bytes,
            address: address,
            mnemonic: isNonZero ? "cbnz" : "cbz",
            operandsPrefix: register(source, is64Bit: is64Bit),
            typedPrefix: [.register(.init(index: source, width: is64Bit ? 64 : 32, role: source == 31 ? .zero : .ordinary))]
        )
    }

    func decodeTestAndBranch(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let is64Bit = (word & 0x8000_0000) != 0
        let isNonZero = (word & 0x0100_0000) != 0
        let source = Int(word & 0x1f)
        let bitNumber = Int((word >> 19) & 0x1f) | Int((word >> 26) & 0x20)
        let immediate = signExtend(Int((word >> 5) & 0x3fff), bitCount: 14) * 4
        return decodeBranchTarget(
            immediate,
            word: word,
            bytes: bytes,
            address: address,
            mnemonic: isNonZero ? "tbnz" : "tbz",
            operandsPrefix: "\(register(source, is64Bit: is64Bit)), #\(bitNumber)",
            typedPrefix: [.register(.init(index: source, width: is64Bit ? 64 : 32, role: source == 31 ? .zero : .ordinary)),
                          .immediate(.init(.unsigned(UInt64(bitNumber)), encodedWidth: 6, format: .decimal))]
        )
    }

    private func decodeBranchTarget(
        _ immediate: Int,
        word: UInt32,
        bytes: [UInt8],
        address: UInt64,
        mnemonic: String,
        operandsPrefix: String?,
        typedPrefix: [InstructionOperands.Operand] = [],
        condition: InstructionOperands.Condition? = nil
    ) -> DecodedInstruction {
        let reference = InstructionOperands.PCReference(baseAddress: address, displacement: Int64(immediate))
        var typedOperands = typedPrefix + [.pcRelative(reference)]
        if let condition { typedOperands.append(.condition(condition)) }
        let presentation = InstructionOperands.Presentation(mnemonic: condition == nil ? mnemonic : "b",
            conditionSuffixOperandIndex: condition == nil ? nil : typedOperands.count - 1)
        guard let target = addingSignedOffset(immediate, to: address) else {
            let operands = [operandsPrefix, "<address overflow>"].compactMap { $0 }.joined(separator: ", ")
            return instruction(
                address,
                bytes,
                mnemonic,
                operands,
                comment: "Branch target overflows the available address space",
                structuredOperands: .init(coverage: .partial, opcodeClass: condition == nil ? mnemonic : "b.cond",
                    operands: typedOperands, presentation: presentation,
                    legacyText: .init(mnemonic: mnemonic, operands: operands))
            )
        }

        let operands = [operandsPrefix, target.hexAddress].compactMap { $0 }.joined(separator: ", ")
        return instruction(address, bytes, mnemonic, operands, branchTarget: target,
            structuredOperands: .init(coverage: .complete, opcodeClass: condition == nil ? mnemonic : "b.cond",
                                      operands: typedOperands, presentation: presentation))
    }
}
