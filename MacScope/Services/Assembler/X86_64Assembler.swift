import Foundation

/// Package-01 x86-64 assembler: legacy integer core, AT&T syntax.
///
/// The implementation is intentionally split into a small parser, register/memory
/// model, and opcode emitters. Later VEX/EVEX/SIMD packages can extend dispatch
/// without replacing the ModRM/SIB/REX plumbing.
struct X86_64Assembler {

    enum Result: Equatable {
        case success([UInt8])
        case failure(Diagnostic)
    }

    enum Diagnostic: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownMnemonic(String)
        case wrongOperandCount(mnemonic: String, expected: String)
        case badOperand(String)
        case badRegister(String)
        case immediateOutOfRange(String)
        case offsetOutOfRange(String)
        case ambiguousWidth(mnemonic: String)
        case notEncodable(String)

        var description: String {
            switch self {
            case .empty: return "empty instruction"
            case .unknownMnemonic(let mnemonic): return "unknown mnemonic '\(mnemonic)'"
            case .wrongOperandCount(let mnemonic, let expected): return "'\(mnemonic)' expects \(expected)"
            case .badOperand(let operand): return "bad operand '\(operand)'"
            case .badRegister(let register): return "bad register '\(register)'"
            case .immediateOutOfRange(let value): return "immediate out of range: \(value)"
            case .offsetOutOfRange(let value): return "offset out of range: \(value)"
            case .ambiguousWidth(let mnemonic): return "'\(mnemonic)' requires a size suffix when no register operand determines the width"
            case .notEncodable(let value): return "not encodable: \(value)"
            }
        }
    }

    /// Assemble one instruction placed at `address` (address is reserved for
    /// future direct RIP-relative target syntaxes; package 01 encodes literal
    /// `disp(%rip)` displacements).
    func assemble(_ text: String, at address: UInt64 = 0) -> Result {
        do {
            let line = Self.stripComment(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return .failure(.empty) }
            let (mnemonic, operandText) = Self.split(line)
            guard !mnemonic.isEmpty else { return .failure(.empty) }
            let operands = try Self.splitOperands(operandText).map(Self.parseOperand)
            return .success(try encode(mnemonic: mnemonic.lowercased(), operands: operands, address: address))
        } catch let diagnostic as Diagnostic {
            return .failure(diagnostic)
        } catch {
            return .failure(.notEncodable("internal error"))
        }
    }

    // MARK: - Dispatch

    private func encode(mnemonic: String, operands: [Operand], address: UInt64) throws -> [UInt8] {
        if mnemonic == "ret" || mnemonic == "retq" {
            guard operands.isEmpty else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "no operands") }
            return [0xC3]
        }
        if mnemonic == "leave" {
            guard operands.isEmpty else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "no operands") }
            return [0xC9]
        }
        if mnemonic == "nop" {
            guard operands.isEmpty else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "no operands") }
            return [0x90]
        }
        if mnemonic == "call" || mnemonic == "callq" {
            return try encodeBranchOrIndirect("call", operands, directOpcode: 0xE8, group: 2)
        }
        if mnemonic == "jmp" || mnemonic == "jmpq" {
            return try encodeBranchOrIndirect("jmp", operands, directOpcode: 0xE9, group: 4)
        }
        if let condition = Self.conditionCode(for: mnemonic) {
            return try encodeConditionalBranch(mnemonic, operands, condition: condition)
        }

        if mnemonic == "movabsq" {
            return try encodeMovabs(operands)
        }
        if Self.evexScalarThreeOperandOpcodes[mnemonic] != nil,
           shouldUseEVEXScalarThreeOperand(mnemonic, operands) {
            return try encodeEVEXScalarThreeOperand(mnemonic, operands)
        }
        if Self.vexScalarThreeOperandOpcodes[mnemonic] != nil {
            return try encodeVEXScalarThreeOperand(mnemonic, operands)
        }
        if Self.vexScalarMoveOpcodes[mnemonic] != nil {
            return try encodeVEXScalarMove(mnemonic, operands)
        }
        if Self.vexScalarCompareOpcodes[mnemonic] != nil {
            return try encodeVEXScalarCompare(mnemonic, operands)
        }
        if Self.vectorShuffleImmediateOpcodes[mnemonic] != nil {
            if operands.first?.isImmediate == true {
                return try encodeVectorShuffleImmediate(mnemonic, operands)
            }
            if Self.evexThreeOperandOpcodes[mnemonic] == nil,
               Self.vexThreeOperandOpcodes[mnemonic] == nil {
                return try encodeVectorShuffleImmediate(mnemonic, operands)
            }
        }
        if Self.packedShiftImmediateOpcodes[mnemonic] != nil,
           operands.first?.isImmediate == true {
            return try encodePackedShiftImmediate(mnemonic, operands)
        }
        if Self.evexPackedShiftCountOpcodes[mnemonic] != nil ||
           Self.vexPackedShiftCountOpcodes[mnemonic] != nil {
            return try encodePackedShiftByXMMCount(mnemonic, operands)
        }
        if Self.evexThreeOperandOpcodes[mnemonic] != nil,
           shouldUseEVEXThreeOperand(mnemonic, operands) {
            return try encodeEVEXThreeOperand(mnemonic, operands)
        }
        if Self.evexTernaryLogicOpcodes[mnemonic] != nil {
            return try encodeEVEXTernaryLogic(mnemonic, operands)
        }
        if Self.vexThreeOperandOpcodes[mnemonic] != nil {
            return try encodeVEXThreeOperand(mnemonic, operands)
        }
        if Self.evexMoveOpcodes[mnemonic] != nil,
           shouldUseEVEXMove(mnemonic, operands) {
            return try encodeEVEXMove(mnemonic, operands)
        }
        if Self.evexBroadcastOpcodes[mnemonic] != nil ||
           Self.evexGPRBroadcastOpcodes[mnemonic] != nil ||
           Self.evexSubvectorBroadcastOpcodes[mnemonic] != nil {
            return try encodeBroadcast(mnemonic, operands)
        }
        if Self.vexMoveOpcodes[mnemonic] != nil {
            return try encodeVEXMove(mnemonic, operands)
        }

        let parsed = try Self.parseMnemonic(mnemonic)
        let width = try Self.resolveWidth(parsed, mnemonic: mnemonic, operands: operands)
        let canonicalizeAccumulatorImmediate = !parsed.hasExplicitWidth
        switch parsed.base {
        case "mov":
            return try encodeMov(mnemonic, operands, width: width)
        case "lea":
            return try encodeLea(mnemonic, operands, width: width)
        case "add", "sub", "and", "or", "xor", "cmp", "test":
            return try encodeALU(parsed.base, mnemonic: mnemonic, operands: operands, width: width, canonicalizeAccumulatorImmediate: canonicalizeAccumulatorImmediate)
        case "inc", "dec":
            return try encodeGroupUnary(parsed.base, mnemonic: mnemonic, operands: operands, width: width, opcode: width == .byte ? 0xFE : 0xFF, group: parsed.base == "inc" ? 0 : 1)
        case "neg", "not":
            return try encodeGroupUnary(parsed.base, mnemonic: mnemonic, operands: operands, width: width, opcode: width == .byte ? 0xF6 : 0xF7, group: parsed.base == "not" ? 2 : 3)
        case "push":
            return try encodePush(mnemonic, operands, width: width)
        case "pop":
            return try encodePop(mnemonic, operands, width: width)
        case "shl", "shr", "sar":
            return try encodeShift(parsed.base, mnemonic: mnemonic, operands: operands, width: width)
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    // MARK: - Instruction families

    private func encodeVEXScalarThreeOperand(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.vexScalarThreeOperandOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "src2, src1, destination")
        }
        let src1 = try xmmRegister(operands[1], mnemonic: mnemonic)
        let dst = try xmmRegister(operands[2], mnemonic: mnemonic)
        let rm = try vectorRMOperand(operands[0], vectorWidth: .xmm, mnemonic: mnemonic)
        return try emitVEX(spec: spec, vectorWidth: .xmm, vvvv: src1.index, reg: dst, rm: rm)
    }

    private func encodeVEXScalarMove(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.vexScalarMoveOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        if operands.count == 3 {
            let src2 = try xmmRegister(operands[0], mnemonic: mnemonic)
            let src1 = try xmmRegister(operands[1], mnemonic: mnemonic)
            let dst = try xmmRegister(operands[2], mnemonic: mnemonic)
            if src2.index >= 8, dst.index < 8, spec.store.canUseTwoByteVEX {
                return try emitVEX(spec: spec.store, vectorWidth: .xmm, vvvv: src1.index, reg: src2, rm: .register(dst))
            }
            return try emitVEX(spec: spec.load, vectorWidth: .xmm, vvvv: src1.index, reg: dst, rm: .register(src2))
        }

        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination or src2, src1, destination")
        }

        if case .memory(let mem) = operands[0] {
            let dst = try xmmRegister(operands[1], mnemonic: mnemonic)
            return try emitVEX(spec: spec.load, vectorWidth: .xmm, vvvv: 0, reg: dst, rm: .memory(mem))
        }

        if case .memory(let mem) = operands[1] {
            let src = try xmmRegister(operands[0], mnemonic: mnemonic)
            return try emitVEX(spec: spec.store, vectorWidth: .xmm, vvvv: 0, reg: src, rm: .memory(mem))
        }

        throw Diagnostic.badOperand(operands.map(\.text).joined(separator: ", "))
    }

    private func encodeVEXScalarCompare(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.vexScalarCompareOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination")
        }
        let dst = try xmmRegister(operands[1], mnemonic: mnemonic)
        let rm = try vectorRMOperand(operands[0], vectorWidth: .xmm, mnemonic: mnemonic)
        return try emitVEX(spec: spec, vectorWidth: .xmm, vvvv: 0, reg: dst, rm: rm)
    }

    private func shouldUseEVEXScalarThreeOperand(_ mnemonic: String, _ operands: [Operand]) -> Bool {
        guard Self.evexScalarThreeOperandOpcodes[mnemonic] != nil else { return false }
        if !operands.isEmpty, case .evexRounding = operands[0] {
            return true
        }
        if operands.contains(where: Self.hasEVEXDecoration) {
            return true
        }
        for operand in operands {
            if case .register(let reg) = Self.baseOperand(operand),
               reg.vectorWidth == .xmm,
               reg.index >= 16 {
                return true
            }
        }
        return false
    }

    private func encodeEVEXScalarThreeOperand(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.evexScalarThreeOperandOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        var operandStart = 0
        var rounding: EVEXRounding?
        if !operands.isEmpty, case .evexRounding(let control) = operands[0] {
            rounding = control
            operandStart = 1
        }

        guard operands.count - operandStart == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "src2, src1, destination")
        }

        if let rounding {
            guard spec.roundingPolicy.accepts(rounding) else {
                throw Diagnostic.badOperand(rounding.text)
            }
        }

        let src2Index = operandStart
        let src1Index = operandStart + 1
        let dstIndex = operandStart + 2
        let (src2Operand, src2Decoration) = Self.evexParts(operands[src2Index])
        let (src1Operand, src1Decoration) = Self.evexParts(operands[src1Index])
        let (dstOperand, dstDecoration) = Self.evexParts(operands[dstIndex])

        guard src2Decoration.isEmpty else { throw Diagnostic.badOperand(operands[src2Index].text) }
        guard src1Decoration.isEmpty else { throw Diagnostic.badOperand(operands[src1Index].text) }
        guard dstDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[dstIndex].text) }

        let src1 = try xmmRegister(src1Operand, mnemonic: mnemonic)
        let dst = try xmmRegister(dstOperand, mnemonic: mnemonic)
        let rm = try vectorRMOperand(src2Operand, vectorWidth: .xmm, mnemonic: mnemonic)
        if rounding != nil, case .memory = rm {
            throw Diagnostic.badOperand(operands[src2Index].text)
        }

        let mask = dstDecoration.mask ?? 0
        let zeroing = dstDecoration.zeroing && mask != 0
        return try emitEVEX(
            spec: spec.evex,
            vectorWidth: .xmm,
            vvvvv: src1.index,
            reg: dst,
            rm: rm,
            mask: mask,
            zeroing: zeroing,
            broadcast: false,
            rounding: rounding,
            tupleScale: spec.evex.elementBytes
        )
    }

    private func encodeVEXThreeOperand(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.vexThreeOperandOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "src2, src1, destination")
        }
        guard case .register(var src1) = operands[1] else {
            throw Diagnostic.badOperand(operands[1].text)
        }
        guard case .register(let dst) = operands[2] else {
            throw Diagnostic.badOperand(operands[2].text)
        }
        let vectorWidth = try commonVectorWidth(src1, dst, mnemonic: mnemonic)
        var src2 = operands[0]
        if spec.commutative,
           case .register(let src2Reg) = src2,
           src2Reg.vectorWidth == vectorWidth,
           src2Reg.index >= 8,
           src1.index < 8,
           spec.canUseTwoByteVEX {
            src2 = .register(src1)
            src1 = src2Reg
        }
        let rm = try vectorRMOperand(src2, vectorWidth: vectorWidth, mnemonic: mnemonic)
        try validateCrossLanePermuteVectorWidth(mnemonic, vectorWidth: vectorWidth)
        return try emitVEX(spec: spec, vectorWidth: vectorWidth, vvvv: src1.index, reg: dst, rm: rm)
    }

    private func shouldUseEVEXThreeOperand(_ mnemonic: String, _ operands: [Operand]) -> Bool {
        guard Self.evexThreeOperandOpcodes[mnemonic] != nil else { return false }
        guard Self.vexThreeOperandOpcodes[mnemonic] != nil else { return true }
        if operands.contains(where: Self.hasEVEXDecoration) {
            return true
        }
        for operand in operands {
            if case .register(let reg) = Self.baseOperand(operand),
               let vectorWidth = reg.vectorWidth,
               (vectorWidth == .zmm || reg.index >= 16) {
                return true
            }
        }
        return false
    }

    private func encodeEVEXThreeOperand(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.evexThreeOperandOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "src2, src1, destination")
        }

        let (src2Operand, src2Decoration) = Self.evexParts(operands[0])
        let (src1Operand, src1Decoration) = Self.evexParts(operands[1])
        let (dstOperand, dstDecoration) = Self.evexParts(operands[2])

        guard src1Decoration.isEmpty else { throw Diagnostic.badOperand(operands[1].text) }
        guard src2Decoration.mask == nil, !src2Decoration.zeroing else { throw Diagnostic.badOperand(operands[0].text) }
        guard dstDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[2].text) }

        guard case .register(let src1) = src1Operand else { throw Diagnostic.badOperand(operands[1].text) }
        guard case .register(let dst) = dstOperand else { throw Diagnostic.badOperand(operands[2].text) }
        let vectorWidth = try commonVectorWidth(src1, dst, mnemonic: mnemonic)

        if let broadcast = src2Decoration.broadcast {
            guard case .memory = src2Operand else { throw Diagnostic.badOperand(operands[0].text) }
            guard spec.allowBroadcast else { throw Diagnostic.badOperand(operands[0].text) }
            guard broadcast == vectorWidth.byteCount / spec.elementBytes else {
                throw Diagnostic.badOperand(operands[0].text)
            }
        }

        let rm = try vectorRMOperand(src2Operand, vectorWidth: vectorWidth, mnemonic: mnemonic)
        try validateCrossLanePermuteVectorWidth(mnemonic, vectorWidth: vectorWidth)
        let mask = dstDecoration.mask ?? 0
        let zeroing = dstDecoration.zeroing && mask != 0
        return try emitEVEX(
            spec: spec,
            vectorWidth: vectorWidth,
            vvvvv: src1.index,
            reg: dst,
            rm: rm,
            mask: mask,
            zeroing: zeroing,
            broadcast: src2Decoration.broadcast != nil
        )
    }

    private func validateCrossLanePermuteVectorWidth(_ mnemonic: String, vectorWidth: VectorWidth) throws {
        guard Self.yMMOrZMMOnlyPermuteMnemonics.contains(mnemonic) else { return }
        guard vectorWidth != .xmm else {
            throw Diagnostic.notEncodable("\(mnemonic) requires ymm or zmm operands")
        }
    }

    private func encodeEVEXTernaryLogic(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.evexTernaryLogicOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 4 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "imm8, src3, src2, destination")
        }
        guard case .immediate(let immediate) = operands[0] else {
            throw Diagnostic.badOperand(operands[0].text)
        }

        let (src3Operand, src3Decoration) = Self.evexParts(operands[1])
        let (src2Operand, src2Decoration) = Self.evexParts(operands[2])
        let (dstOperand, dstDecoration) = Self.evexParts(operands[3])

        guard src2Decoration.isEmpty else { throw Diagnostic.badOperand(operands[2].text) }
        guard src3Decoration.mask == nil, !src3Decoration.zeroing else { throw Diagnostic.badOperand(operands[1].text) }
        guard dstDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[3].text) }
        guard case .register(let src2) = src2Operand else { throw Diagnostic.badOperand(operands[2].text) }
        guard case .register(let dst) = dstOperand else { throw Diagnostic.badOperand(operands[3].text) }

        let vectorWidth = try commonVectorWidth(src2, dst, mnemonic: mnemonic)
        if let broadcast = src3Decoration.broadcast {
            guard case .memory = src3Operand else { throw Diagnostic.badOperand(operands[1].text) }
            guard spec.allowBroadcast else { throw Diagnostic.badOperand(operands[1].text) }
            guard broadcast == vectorWidth.byteCount / spec.elementBytes else {
                throw Diagnostic.badOperand(operands[1].text)
            }
        }

        let imm8 = try immediate.byteValue(width: 1)
        let rm = try vectorRMOperand(src3Operand, vectorWidth: vectorWidth, mnemonic: mnemonic)
        let mask = dstDecoration.mask ?? 0
        let zeroing = dstDecoration.zeroing && mask != 0
        let encoded = try emitEVEX(
            spec: spec,
            vectorWidth: vectorWidth,
            vvvvv: src2.index,
            reg: dst,
            rm: rm,
            mask: mask,
            zeroing: zeroing,
            broadcast: src3Decoration.broadcast != nil
        )
        return encoded + [imm8]
    }

    private func encodeVectorShuffleImmediate(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.vectorShuffleImmediateOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "imm8, source, destination")
        }
        guard case .immediate(let immediate) = operands[0] else {
            throw Diagnostic.badOperand(operands[0].text)
        }

        let (sourceOperand, sourceDecoration) = Self.evexParts(operands[1])
        let (destinationOperand, destinationDecoration) = Self.evexParts(operands[2])
        guard sourceDecoration.mask == nil, !sourceDecoration.zeroing else { throw Diagnostic.badOperand(operands[1].text) }
        guard destinationDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[2].text) }
        guard case .register(let destination) = destinationOperand, let vectorWidth = destination.vectorWidth else {
            throw Diagnostic.badOperand(operands[2].text)
        }
        try validateCrossLanePermuteImmediateVectorWidth(mnemonic, vectorWidth: vectorWidth)

        if let broadcast = sourceDecoration.broadcast {
            guard case .memory = sourceOperand else { throw Diagnostic.badOperand(operands[1].text) }
            guard spec.evex.allowBroadcast else { throw Diagnostic.badOperand(operands[1].text) }
            guard broadcast == vectorWidth.byteCount / spec.evex.elementBytes else {
                throw Diagnostic.badOperand(operands[1].text)
            }
        }

        let imm8 = try immediate.byteValue(width: 1)
        if shouldUseEVEXVectorShuffleImmediate(mnemonic, operands: operands) {
            let rm = try vectorRMOperand(sourceOperand, vectorWidth: vectorWidth, mnemonic: mnemonic)
            let mask = destinationDecoration.mask ?? 0
            let zeroing = destinationDecoration.zeroing && mask != 0
            return try emitEVEXVectorImmediate(
                spec: spec.evex,
                vectorWidth: vectorWidth,
                reg: destination,
                rm: rm,
                mask: mask,
                zeroing: zeroing,
                broadcast: sourceDecoration.broadcast != nil,
                imm8: imm8
            )
        }

        guard sourceDecoration.isEmpty else { throw Diagnostic.badOperand(operands[1].text) }
        guard destinationDecoration.isEmpty else { throw Diagnostic.badOperand(operands[2].text) }
        let rm = try vectorRMOperand(sourceOperand, vectorWidth: vectorWidth, mnemonic: mnemonic)
        return try emitVEXVectorImmediate(
            spec: spec.vex,
            vectorWidth: vectorWidth,
            reg: destination,
            rm: rm,
            imm8: imm8
        )
    }

    private func validateCrossLanePermuteImmediateVectorWidth(_ mnemonic: String, vectorWidth: VectorWidth) throws {
        guard Self.crossLanePermuteImmediateMnemonics.contains(mnemonic) else { return }
        guard vectorWidth != .xmm else {
            throw Diagnostic.notEncodable("\(mnemonic) immediate form requires ymm or zmm operands")
        }
    }

    private func shouldUseEVEXVectorShuffleImmediate(_ mnemonic: String, operands: [Operand]) -> Bool {
        guard Self.vectorShuffleImmediateOpcodes[mnemonic] != nil else { return false }
        if operands.contains(where: Self.hasEVEXDecoration) {
            return true
        }
        for operand in operands {
            if case .register(let reg) = Self.baseOperand(operand),
               let vectorWidth = reg.vectorWidth,
               (vectorWidth == .zmm || reg.index >= 16) {
                return true
            }
        }
        return false
    }

    private func encodePackedShiftByXMMCount(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard operands.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "xmm-count, source, destination")
        }

        let (countOperand, countDecoration) = Self.evexParts(operands[0])
        let (sourceOperand, sourceDecoration) = Self.evexParts(operands[1])
        let (destinationOperand, destinationDecoration) = Self.evexParts(operands[2])

        guard countDecoration.isEmpty else { throw Diagnostic.badOperand(operands[0].text) }
        guard sourceDecoration.isEmpty else { throw Diagnostic.badOperand(operands[1].text) }
        guard destinationDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[2].text) }

        let count = try xmmRegister(countOperand, mnemonic: mnemonic)
        guard case .register(let source) = sourceOperand else { throw Diagnostic.badOperand(operands[1].text) }
        guard case .register(let destination) = destinationOperand else { throw Diagnostic.badOperand(operands[2].text) }
        let vectorWidth = try commonVectorWidth(source, destination, mnemonic: mnemonic)

        if shouldUseEVEXPackedShift(mnemonic, operands: operands) {
            guard let spec = Self.evexPackedShiftCountOpcodes[mnemonic] else {
                throw Diagnostic.notEncodable("\(mnemonic) requires VEX but EVEX was selected")
            }
            let mask = destinationDecoration.mask ?? 0
            let zeroing = destinationDecoration.zeroing && mask != 0
            return try emitEVEX(
                spec: spec,
                vectorWidth: vectorWidth,
                vvvvv: source.index,
                reg: destination,
                rm: .register(count),
                mask: mask,
                zeroing: zeroing,
                broadcast: false
            )
        }

        guard destinationDecoration.isEmpty else { throw Diagnostic.badOperand(operands[2].text) }
        guard let spec = Self.vexPackedShiftCountOpcodes[mnemonic] else {
            throw Diagnostic.notEncodable("\(mnemonic) requires EVEX")
        }
        return try emitVEX(spec: spec, vectorWidth: vectorWidth, vvvv: source.index, reg: destination, rm: .register(count))
    }

    private func encodePackedShiftImmediate(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard operands.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "imm8, source, destination")
        }
        guard case .immediate(let immediate) = operands[0] else {
            throw Diagnostic.badOperand(operands[0].text)
        }

        let (sourceOperand, sourceDecoration) = Self.evexParts(operands[1])
        let (destinationOperand, destinationDecoration) = Self.evexParts(operands[2])
        guard sourceDecoration.mask == nil, !sourceDecoration.zeroing else { throw Diagnostic.badOperand(operands[1].text) }
        guard destinationDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[2].text) }
        guard case .register(let destination) = destinationOperand, let vectorWidth = destination.vectorWidth else {
            throw Diagnostic.badOperand(operands[2].text)
        }
        if let broadcast = sourceDecoration.broadcast {
            guard case .memory = sourceOperand else { throw Diagnostic.badOperand(operands[1].text) }
            guard let spec = Self.packedShiftImmediateOpcodes[mnemonic], spec.allowBroadcast else {
                throw Diagnostic.badOperand(operands[1].text)
            }
            guard broadcast == vectorWidth.byteCount / spec.evex.elementBytes else {
                throw Diagnostic.badOperand(operands[1].text)
            }
        }

        let imm8 = try immediate.byteValue(width: 1)

        if shouldUseEVEXPackedShift(mnemonic, operands: operands) {
            guard let spec = Self.packedShiftImmediateOpcodes[mnemonic] else {
                throw Diagnostic.unknownMnemonic(mnemonic)
            }
            let rm = try vectorRMOperand(sourceOperand, vectorWidth: vectorWidth, mnemonic: mnemonic)
            let mask = destinationDecoration.mask ?? 0
            let zeroing = destinationDecoration.zeroing && mask != 0
            return try emitEVEXShiftImmediate(
                spec: spec.evex,
                vectorWidth: vectorWidth,
                vvvvv: destination.index,
                rm: rm,
                group: spec.group,
                mask: mask,
                zeroing: zeroing,
                broadcast: sourceDecoration.broadcast != nil,
                imm8: imm8
            )
        }

        guard sourceDecoration.isEmpty else { throw Diagnostic.badOperand(operands[1].text) }
        guard destinationDecoration.isEmpty else { throw Diagnostic.badOperand(operands[2].text) }
        guard let shiftSpec = Self.packedShiftImmediateOpcodes[mnemonic],
              let spec = shiftSpec.vex else {
            throw Diagnostic.notEncodable("\(mnemonic) requires EVEX")
        }
        let rm = try vectorRMOperand(sourceOperand, vectorWidth: vectorWidth, mnemonic: mnemonic)
        return try emitVEXShiftImmediate(
            spec: spec,
            vectorWidth: vectorWidth,
            vvvv: destination.index,
            rm: rm,
            group: shiftSpec.group,
            imm8: imm8
        )
    }

    private func shouldUseEVEXPackedShift(_ mnemonic: String, operands: [Operand]) -> Bool {
        guard Self.evexPackedShiftCountOpcodes[mnemonic] != nil ||
              Self.packedShiftImmediateOpcodes[mnemonic] != nil else { return false }
        let hasVEX = Self.vexPackedShiftCountOpcodes[mnemonic] != nil ||
            Self.packedShiftImmediateOpcodes[mnemonic]?.vex != nil
        guard hasVEX else { return true }
        if Self.packedShiftImmediateOpcodes[mnemonic] != nil,
           operands.count > 1,
           case .memory = Self.baseOperand(operands[1]) {
            return true
        }
        if operands.contains(where: Self.hasEVEXDecoration) {
            return true
        }
        for operand in operands {
            if case .register(let reg) = Self.baseOperand(operand),
               let vectorWidth = reg.vectorWidth,
               (vectorWidth == .zmm || reg.index >= 16) {
                return true
            }
        }
        return false
    }

    private func shouldUseEVEXMove(_ mnemonic: String, _ operands: [Operand]) -> Bool {
        guard Self.evexMoveOpcodes[mnemonic] != nil else { return false }
        guard Self.vexMoveOpcodes[mnemonic] != nil else { return true }
        if operands.contains(where: Self.hasEVEXDecoration) {
            return true
        }
        for operand in operands {
            if case .register(let reg) = Self.baseOperand(operand),
               let vectorWidth = reg.vectorWidth,
               (vectorWidth == .zmm || reg.index >= 16) {
                return true
            }
        }
        return false
    }

    private func encodeEVEXMove(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.evexMoveOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination")
        }

        let (source, sourceDecoration) = Self.evexParts(operands[0])
        let (destination, destinationDecoration) = Self.evexParts(operands[1])
        guard sourceDecoration.isEmpty else { throw Diagnostic.badOperand(operands[0].text) }
        guard destinationDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[1].text) }

        if case .register(let dst) = destination, let vectorWidth = dst.vectorWidth {
            let rm = try vectorRMOperand(source, vectorWidth: vectorWidth, mnemonic: mnemonic)
            let mask = destinationDecoration.mask ?? 0
            let zeroing = destinationDecoration.zeroing && mask != 0
            return try emitEVEX(
                spec: spec.load,
                vectorWidth: vectorWidth,
                vvvvv: 0,
                reg: dst,
                rm: rm,
                mask: mask,
                zeroing: zeroing,
                broadcast: false,
                tupleScale: vectorWidth.byteCount
            )
        }

        if case .memory(let mem) = destination {
            guard !destinationDecoration.zeroing else { throw Diagnostic.badOperand(operands[1].text) }
            guard case .register(let src) = source, let vectorWidth = src.vectorWidth else {
                throw Diagnostic.badOperand(operands[0].text)
            }
            let mask = destinationDecoration.mask ?? 0
            return try emitEVEX(
                spec: spec.store,
                vectorWidth: vectorWidth,
                vvvvv: 0,
                reg: src,
                rm: .memory(mem),
                mask: mask,
                zeroing: false,
                broadcast: false,
                tupleScale: vectorWidth.byteCount
            )
        }

        throw Diagnostic.badOperand(operands.map(\.text).joined(separator: ", "))
    }

    private func encodeBroadcast(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination")
        }

        let (source, sourceDecoration) = Self.evexParts(operands[0])
        let (destination, destinationDecoration) = Self.evexParts(operands[1])
        guard sourceDecoration.isEmpty else { throw Diagnostic.badOperand(operands[0].text) }
        guard destinationDecoration.broadcast == nil else { throw Diagnostic.badOperand(operands[1].text) }
        guard case .register(let dst) = destination, let vectorWidth = dst.vectorWidth else {
            throw Diagnostic.badOperand(operands[1].text)
        }

        switch source {
        case .register(let src):
            if let spec = Self.evexGPRBroadcastOpcodes[mnemonic], src.width == spec.sourceWidth {
                try requireBroadcastDestination(vectorWidth, minBytes: spec.minVectorBytes, mnemonic: mnemonic, operand: operands[1])
                return try emitEVEXBroadcast(spec.evex, vectorWidth: vectorWidth, dst: dst, rm: .register(src), decoration: destinationDecoration, tupleScale: spec.tupleScale)
            }
            guard let spec = Self.evexBroadcastOpcodes[mnemonic], src.vectorWidth == .xmm else {
                throw Diagnostic.badOperand(operands[0].text)
            }
            try requireBroadcastDestination(vectorWidth, minBytes: spec.minVectorBytes, mnemonic: mnemonic, operand: operands[1])
            if shouldUseVEXBroadcast(mnemonic, vectorWidth: vectorWidth, dst: dst, source: .register(src), decoration: destinationDecoration) {
                return try encodeVEXBroadcast(mnemonic, vectorWidth: vectorWidth, dst: dst, source: .register(src))
            }
            return try emitEVEXBroadcast(spec.evex, vectorWidth: vectorWidth, dst: dst, rm: .register(src), decoration: destinationDecoration, tupleScale: spec.tupleScale)

        case .memory(let mem):
            if let spec = Self.evexSubvectorBroadcastOpcodes[mnemonic] {
                try requireBroadcastDestination(vectorWidth, minBytes: spec.minVectorBytes, mnemonic: mnemonic, operand: operands[1])
                return try emitEVEXBroadcast(spec.evex, vectorWidth: vectorWidth, dst: dst, rm: .memory(mem), decoration: destinationDecoration, tupleScale: spec.tupleScale)
            }
            guard let spec = Self.evexBroadcastOpcodes[mnemonic] else {
                throw Diagnostic.badOperand(operands[0].text)
            }
            try requireBroadcastDestination(vectorWidth, minBytes: spec.minVectorBytes, mnemonic: mnemonic, operand: operands[1])
            if shouldUseVEXBroadcast(mnemonic, vectorWidth: vectorWidth, dst: dst, source: .memory(mem), decoration: destinationDecoration) {
                return try encodeVEXBroadcast(mnemonic, vectorWidth: vectorWidth, dst: dst, source: .memory(mem))
            }
            return try emitEVEXBroadcast(spec.evex, vectorWidth: vectorWidth, dst: dst, rm: .memory(mem), decoration: destinationDecoration, tupleScale: spec.tupleScale)

        default:
            throw Diagnostic.badOperand(operands[0].text)
        }
    }

    private func requireBroadcastDestination(_ vectorWidth: VectorWidth, minBytes: Int, mnemonic: String, operand: Operand) throws {
        guard vectorWidth.byteCount >= minBytes else {
            throw Diagnostic.badRegister("\(operand.text) is not valid for \(mnemonic)")
        }
    }

    private func emitEVEXBroadcast(
        _ spec: EVEXOpcodeSpec,
        vectorWidth: VectorWidth,
        dst: Register,
        rm: RMOperand,
        decoration: EVEXDecoration,
        tupleScale: Int
    ) throws -> [UInt8] {
        let mask = decoration.mask ?? 0
        let zeroing = decoration.zeroing && mask != 0
        return try emitEVEX(
            spec: spec,
            vectorWidth: vectorWidth,
            vvvvv: 0,
            reg: dst,
            rm: rm,
            mask: mask,
            zeroing: zeroing,
            broadcast: false,
            tupleScale: tupleScale
        )
    }

    private func shouldUseVEXBroadcast(
        _ mnemonic: String,
        vectorWidth: VectorWidth,
        dst: Register,
        source: RMOperand,
        decoration: EVEXDecoration
    ) -> Bool {
        guard let spec = Self.vexBroadcastOpcodes[mnemonic] else { return false }
        guard decoration.isEmpty else { return false }
        guard vectorWidth.byteCount >= spec.minVectorBytes, vectorWidth != .zmm, dst.index < 16 else {
            return false
        }
        if case .register(let src) = source {
            return src.vectorWidth == .xmm && src.index < 16
        }
        return true
    }

    private func encodeVEXBroadcast(_ mnemonic: String, vectorWidth: VectorWidth, dst: Register, source: RMOperand) throws -> [UInt8] {
        guard let spec = Self.vexBroadcastOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return try emitVEX(spec: spec.vex, vectorWidth: vectorWidth, vvvv: 0, reg: dst, rm: source)
    }

    private func encodeVEXMove(_ mnemonic: String, _ operands: [Operand]) throws -> [UInt8] {
        guard let spec = Self.vexMoveOpcodes[mnemonic] else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination")
        }

        if case .register(let dst) = operands[1], let vectorWidth = dst.vectorWidth {
            if case .register(let src) = operands[0],
               src.vectorWidth == vectorWidth,
               src.index >= 8,
               dst.index < 8,
               spec.store.canUseTwoByteVEX {
                return try emitVEX(spec: spec.store, vectorWidth: vectorWidth, vvvv: 0, reg: src, rm: .register(dst))
            }
            let rm = try vectorRMOperand(operands[0], vectorWidth: vectorWidth, mnemonic: mnemonic)
            return try emitVEX(spec: spec.load, vectorWidth: vectorWidth, vvvv: 0, reg: dst, rm: rm)
        }

        if case .register(let src) = operands[0],
           let vectorWidth = src.vectorWidth,
           case .memory(let mem) = operands[1] {
            return try emitVEX(spec: spec.store, vectorWidth: vectorWidth, vvvv: 0, reg: src, rm: .memory(mem))
        }

        throw Diagnostic.badOperand(operands.map(\.text).joined(separator: ", "))
    }

    private func xmmRegister(_ operand: Operand, mnemonic: String) throws -> Register {
        guard case .register(let reg) = operand else {
            throw Diagnostic.badOperand(operand.text)
        }
        guard reg.vectorWidth == .xmm else {
            throw Diagnostic.badRegister("%\(reg.name) is not an xmm register for \(mnemonic)")
        }
        return reg
    }

    private func commonVectorWidth(_ lhs: Register, _ rhs: Register, mnemonic: String) throws -> VectorWidth {
        guard let lhsWidth = lhs.vectorWidth else {
            throw Diagnostic.badRegister("%\(lhs.name) is not a vector register for \(mnemonic)")
        }
        guard let rhsWidth = rhs.vectorWidth else {
            throw Diagnostic.badRegister("%\(rhs.name) is not a vector register for \(mnemonic)")
        }
        guard lhsWidth == rhsWidth else {
            throw Diagnostic.badRegister("%\(rhs.name) does not match %\(lhs.name)'s vector width")
        }
        return lhsWidth
    }

    private func vectorRMOperand(_ operand: Operand, vectorWidth: VectorWidth, mnemonic: String) throws -> RMOperand {
        switch operand {
        case .register(let reg):
            guard reg.vectorWidth == vectorWidth else {
                throw Diagnostic.badRegister("%\(reg.name) does not match \(mnemonic)'s \(vectorWidth.registerPrefix)-width form")
            }
            return .register(reg)
        case .memory(let mem):
            return .memory(mem)
        default:
            throw Diagnostic.badOperand(operand.text)
        }
    }

    private static func evexParts(_ operand: Operand) -> (Operand, EVEXDecoration) {
        if case .decorated(let base, let decoration) = operand {
            return (base, decoration)
        }
        return (operand, EVEXDecoration())
    }

    private static func baseOperand(_ operand: Operand) -> Operand {
        evexParts(operand).0
    }

    private static func hasEVEXDecoration(_ operand: Operand) -> Bool {
        !evexParts(operand).1.isEmpty
    }

    private func emitVEX(spec: VEXOpcodeSpec, vectorWidth: VectorWidth, vvvv: Int, reg: Register, rm: RMOperand) throws -> [UInt8] {
        guard vectorWidth != .zmm else {
            throw Diagnostic.notEncodable("zmm operands require EVEX")
        }
        guard vvvv < 16 else {
            throw Diagnostic.notEncodable("VEX cannot encode vector register \(vvvv)")
        }
        let encoded = try encodeVEXModRM(regField: reg.index, rm: rm)
        let prefix = Self.vexPrefix(
            map: spec.map,
            pp: spec.pp,
            w: spec.w,
            vectorLength256: vectorWidth == .ymm,
            vvvv: vvvv,
            r: encoded.r,
            x: encoded.x,
            b: encoded.b
        )
        return prefix + [spec.opcode] + encoded.bytes
    }

    private func emitEVEX(
        spec: EVEXOpcodeSpec,
        vectorWidth: VectorWidth,
        vvvvv: Int,
        reg: Register,
        rm: RMOperand,
        mask: Int,
        zeroing: Bool,
        broadcast: Bool,
        rounding: EVEXRounding? = nil,
        tupleScale: Int? = nil
    ) throws -> [UInt8] {
        guard (0..<32).contains(vvvvv), (0..<32).contains(reg.index) else {
            throw Diagnostic.notEncodable("EVEX vector register index out of range")
        }
        guard (0...7).contains(mask) else {
            throw Diagnostic.badOperand("{%k\(mask)}")
        }
        let disp8Scale = tupleScale ?? Self.evexTupleScale(vectorWidth: vectorWidth, elementBytes: spec.elementBytes, broadcast: broadcast)
        let encoded = try encodeEVEXModRM(regField: reg.index, rm: rm, disp8Scale: disp8Scale)
        let prefix = Self.evexPrefix(
            map: spec.map,
            pp: spec.pp,
            w: spec.w,
            vectorWidth: vectorWidth,
            vvvvv: vvvvv,
            r: encoded.r,
            x: encoded.x,
            b: encoded.b,
            rPrime: encoded.rPrime,
            mask: mask,
            zeroing: zeroing,
            broadcast: broadcast,
            rounding: rounding
        )
        return prefix + [spec.opcode] + encoded.bytes
    }

    private func emitVEXVectorImmediate(
        spec: VEXOpcodeSpec,
        vectorWidth: VectorWidth,
        reg: Register,
        rm: RMOperand,
        imm8: UInt8
    ) throws -> [UInt8] {
        guard vectorWidth != .zmm else {
            throw Diagnostic.notEncodable("zmm operands require EVEX")
        }
        let encoded = try encodeVEXModRM(regField: reg.index, rm: rm)
        let prefix = Self.vexPrefix(
            map: spec.map,
            pp: spec.pp,
            w: spec.w,
            vectorLength256: vectorWidth == .ymm,
            vvvv: 0,
            r: encoded.r,
            x: encoded.x,
            b: encoded.b
        )
        return prefix + [spec.opcode] + encoded.bytes + [imm8]
    }

    private func emitEVEXVectorImmediate(
        spec: EVEXOpcodeSpec,
        vectorWidth: VectorWidth,
        reg: Register,
        rm: RMOperand,
        mask: Int,
        zeroing: Bool,
        broadcast: Bool,
        imm8: UInt8
    ) throws -> [UInt8] {
        let encoded = try emitEVEX(
            spec: spec,
            vectorWidth: vectorWidth,
            vvvvv: 0,
            reg: reg,
            rm: rm,
            mask: mask,
            zeroing: zeroing,
            broadcast: broadcast
        )
        return encoded + [imm8]
    }

    private func emitVEXShiftImmediate(
        spec: VEXOpcodeSpec,
        vectorWidth: VectorWidth,
        vvvv: Int,
        rm: RMOperand,
        group: Int,
        imm8: UInt8
    ) throws -> [UInt8] {
        guard vectorWidth != .zmm else {
            throw Diagnostic.notEncodable("zmm operands require EVEX")
        }
        guard (0...7).contains(group) else {
            throw Diagnostic.notEncodable("invalid shift opcode extension /\(group)")
        }
        guard vvvv < 16 else {
            throw Diagnostic.notEncodable("VEX cannot encode vector register \(vvvv)")
        }
        let encoded = try encodeVEXModRM(regField: group, rm: rm)
        let prefix = Self.vexPrefix(
            map: spec.map,
            pp: spec.pp,
            w: spec.w,
            vectorLength256: vectorWidth == .ymm,
            vvvv: vvvv,
            r: encoded.r,
            x: encoded.x,
            b: encoded.b
        )
        return prefix + [spec.opcode] + encoded.bytes + [imm8]
    }

    private func emitEVEXShiftImmediate(
        spec: EVEXOpcodeSpec,
        vectorWidth: VectorWidth,
        vvvvv: Int,
        rm: RMOperand,
        group: Int,
        mask: Int,
        zeroing: Bool,
        broadcast: Bool,
        imm8: UInt8
    ) throws -> [UInt8] {
        guard (0..<32).contains(vvvvv) else {
            throw Diagnostic.notEncodable("EVEX vector register index out of range")
        }
        guard (0...7).contains(group) else {
            throw Diagnostic.notEncodable("invalid shift opcode extension /\(group)")
        }
        guard (0...7).contains(mask) else {
            throw Diagnostic.badOperand("{%k\(mask)}")
        }
        let encoded = try encodeEVEXModRM(regField: group, rm: rm, disp8Scale: vectorWidth.byteCount)
        let prefix = Self.evexPrefix(
            map: spec.map,
            pp: spec.pp,
            w: spec.w,
            vectorWidth: vectorWidth,
            vvvvv: vvvvv,
            r: encoded.r,
            x: encoded.x,
            b: encoded.b,
            rPrime: encoded.rPrime,
            mask: mask,
            zeroing: zeroing,
            broadcast: broadcast
        )
        return prefix + [spec.opcode] + encoded.bytes + [imm8]
    }

    private func encodeMov(_ mnemonic: String, _ operands: [Operand], width: Width) throws -> [UInt8] {
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination")
        }
        let source = operands[0]
        let destination = operands[1]

        if case .immediate(let imm) = source, case .register(let reg) = destination {
            try require(reg, width: width, mnemonic: mnemonic)
            return try encodeMovImmediate(imm, to: reg, width: width)
        }

        if case .register(let src) = source, case .register(let dst) = destination {
            try require(src, width: width, mnemonic: mnemonic)
            try require(dst, width: width, mnemonic: mnemonic)
            let opcode: UInt8 = width == .byte ? 0x88 : 0x89
            return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: src, rm: .register(dst))
        }

        if case .memory(let mem) = source, case .register(let dst) = destination {
            try require(dst, width: width, mnemonic: mnemonic)
            let opcode: UInt8 = width == .byte ? 0x8A : 0x8B
            return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: dst, rm: .memory(mem))
        }

        if case .register(let src) = source, case .memory(let mem) = destination {
            try require(src, width: width, mnemonic: mnemonic)
            let opcode: UInt8 = width == .byte ? 0x88 : 0x89
            return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: src, rm: .memory(mem))
        }

        throw Diagnostic.badOperand("\(source.text), \(destination.text)")
    }

    private func encodeMovImmediate(_ imm: Immediate, to reg: Register, width: Width) throws -> [UInt8] {
        var rex = REX()
        rex.b = reg.index >= 8
        rex.force = reg.forceREXForByteOperand
        let prefix = width == .word ? [UInt8(0x66)] : []

        switch width {
        case .byte:
            let value = try imm.byteValue(width: 1)
            return finish(prefixes: prefix, rex: rex, opcode: [0xB0 | UInt8(reg.low3)], body: [value])
        case .word:
            let value = try imm.littleEndianBytes(width: 2, context: "movw")
            return finish(prefixes: prefix, rex: rex, opcode: [0xB8 | UInt8(reg.low3)], body: value)
        case .dword:
            let value = try imm.littleEndianBytes(width: 4, context: "movl")
            return finish(prefixes: prefix, rex: rex, opcode: [0xB8 | UInt8(reg.low3)], body: value)
        case .qword:
            rex.w = true
            guard imm.fitsSigned(bits: 32) else {
                throw Diagnostic.immediateOutOfRange("movq immediate requires sign-extended imm32; use movabsq for imm64")
            }
            let rm = try encodeModRM(regField: 0, rm: .register(reg), width: .qword, rex: &rex)
            return finish(prefixes: [], rex: rex, opcode: [0xC7], body: rm.bytes + imm.signedLittleEndianBytes(width: 4))
        }
    }

    private func encodeMovabs(_ operands: [Operand]) throws -> [UInt8] {
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: "movabsq", expected: "immediate, qword register")
        }
        guard case .immediate(let imm) = operands[0], case .register(let reg) = operands[1] else {
            throw Diagnostic.badOperand(operands.map(\.text).joined(separator: ", "))
        }
        try require(reg, width: .qword, mnemonic: "movabsq")
        var rex = REX()
        rex.w = true
        rex.b = reg.index >= 8
        return finish(prefixes: [], rex: rex, opcode: [0xB8 | UInt8(reg.low3)], body: imm.bitsLittleEndianBytes(width: 8))
    }

    private func encodeLea(_ mnemonic: String, _ operands: [Operand], width: Width) throws -> [UInt8] {
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "memory, register")
        }
        guard width != .byte else { throw Diagnostic.notEncodable("lea has no byte form") }
        guard case .memory(let mem) = operands[0], case .register(let dst) = operands[1] else {
            throw Diagnostic.badOperand(operands.map(\.text).joined(separator: ", "))
        }
        try require(dst, width: width, mnemonic: mnemonic)
        return try emitModRM(opcode: 0x8D, width: width, rexW: width == .qword, reg: dst, rm: .memory(mem))
    }

    private func encodeALU(_ op: String, mnemonic: String, operands: [Operand], width: Width, canonicalizeAccumulatorImmediate: Bool = false) throws -> [UInt8] {
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "source, destination")
        }
        let source = operands[0]
        let destination = operands[1]

        if case .immediate(let imm) = source {
            return try encodeALUImmediate(op, mnemonic: mnemonic, imm: imm, destination: destination, width: width, canonicalizeAccumulatorImmediate: canonicalizeAccumulatorImmediate)
        }

        if case .register(let src) = source, case .register(let dst) = destination {
            try require(src, width: width, mnemonic: mnemonic)
            try require(dst, width: width, mnemonic: mnemonic)
            if op == "test" {
                let opcode: UInt8 = width == .byte ? 0x84 : 0x85
                return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: src, rm: .register(dst))
            }
            let opcode = try Self.aluOpcode(op, byte: width == .byte, direction: .store)
            return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: src, rm: .register(dst))
        }

        if case .memory(let mem) = source, case .register(let dst) = destination {
            try require(dst, width: width, mnemonic: mnemonic)
            if op == "test" {
                let opcode: UInt8 = width == .byte ? 0x84 : 0x85
                return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: dst, rm: .memory(mem))
            }
            let opcode = try Self.aluOpcode(op, byte: width == .byte, direction: .load)
            return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: dst, rm: .memory(mem))
        }

        if case .register(let src) = source, case .memory(let mem) = destination {
            try require(src, width: width, mnemonic: mnemonic)
            if op == "test" {
                let opcode: UInt8 = width == .byte ? 0x84 : 0x85
                return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: src, rm: .memory(mem))
            }
            let opcode = try Self.aluOpcode(op, byte: width == .byte, direction: .store)
            return try emitModRM(opcode: opcode, width: width, rexW: width == .qword, reg: src, rm: .memory(mem))
        }

        throw Diagnostic.badOperand("\(source.text), \(destination.text)")
    }

    private func encodeALUImmediate(_ op: String, mnemonic: String, imm: Immediate, destination: Operand, width: Width, canonicalizeAccumulatorImmediate: Bool = false) throws -> [UInt8] {
        if op == "test" {
            if canonicalizeAccumulatorImmediate, case .register(let reg) = destination, reg.index == 0 {
                try require(reg, width: width, mnemonic: mnemonic)
                let immWidth = width == .byte ? 1 : (width == .word ? 2 : 4)
                let immBytes = try imm.immediateBytesForOperand(width: width, immWidth: immWidth, signedExtended: false, context: mnemonic)
                var rex = REX()
                rex.w = width == .qword
                rex.b = reg.index >= 8
                rex.force = width == .byte && reg.forceREXForByteOperand
                let prefixes = width == .word ? [UInt8(0x66)] : []
                return finish(prefixes: prefixes, rex: rex, opcode: [width == .byte ? 0xA8 : 0xA9], body: immBytes)
            }
            let opcode: UInt8 = width == .byte ? 0xF6 : 0xF7
            let immWidth = width == .byte ? 1 : (width == .word ? 2 : 4)
            let immBytes = try imm.immediateBytesForOperand(width: width, immWidth: immWidth, signedExtended: false, context: mnemonic)
            return try emitGroup(opcode: opcode, group: 0, width: width, rexW: width == .qword, rmOperand: destination, immediate: immBytes)
        }

        if case .register(let reg) = destination {
            try require(reg, width: width, mnemonic: mnemonic)
            if canonicalizeAccumulatorImmediate, reg.index == 0, width == .byte {
                return finish(prefixes: [], rex: REX(), opcode: [try Self.aluAccumulatorOpcode(op, byte: true)], body: [try imm.byteValue(width: 1)])
            }
            if width != .byte, reg.index == 0, !imm.fitsSigned(bits: 8) {
                let immWidth = width == .word ? 2 : 4
                let immBytes = try imm.immediateBytesForOperand(width: width, immWidth: immWidth, signedExtended: width == .qword, context: mnemonic)
                var rex = REX()
                rex.w = width == .qword
                let prefixes = width == .word ? [UInt8(0x66)] : []
                return finish(prefixes: prefixes, rex: rex, opcode: [try Self.aluAccumulatorOpcode(op, byte: false)], body: immBytes)
            }
        } else if case .memory = destination {
            // fall through to group 1
        } else {
            throw Diagnostic.badOperand(destination.text)
        }

        let group = try Self.aluGroupIndex(op)
        let opcode: UInt8
        let immBytes: [UInt8]
        if width == .byte {
            opcode = 0x80
            immBytes = [try imm.byteValue(width: 1)]
        } else if imm.fitsSigned(bits: 8) {
            opcode = 0x83
            immBytes = [try imm.signedByte()]
        } else {
            opcode = 0x81
            let immWidth = width == .word ? 2 : 4
            immBytes = try imm.immediateBytesForOperand(width: width, immWidth: immWidth, signedExtended: width == .qword, context: mnemonic)
        }
        return try emitGroup(opcode: opcode, group: group, width: width, rexW: width == .qword, rmOperand: destination, immediate: immBytes)
    }

    private func encodeGroupUnary(_ op: String, mnemonic: String, operands: [Operand], width: Width, opcode: UInt8, group: Int) throws -> [UInt8] {
        guard operands.count == 1 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 register or memory operand")
        }
        if case .register(let reg) = operands[0] {
            try require(reg, width: width, mnemonic: mnemonic)
        } else if case .memory = operands[0] {
            // memory width comes from the suffix
        } else {
            throw Diagnostic.badOperand(operands[0].text)
        }
        return try emitGroup(opcode: opcode, group: group, width: width, rexW: width == .qword, rmOperand: operands[0], immediate: [])
    }

    private func encodePush(_ mnemonic: String, _ operands: [Operand], width: Width) throws -> [UInt8] {
        guard width == .qword else { throw Diagnostic.notEncodable("push is qword-only in package 01") }
        guard operands.count == 1 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 register or immediate") }
        switch operands[0] {
        case .register(let reg):
            try require(reg, width: .qword, mnemonic: mnemonic)
            var rex = REX()
            rex.b = reg.index >= 8
            return finish(prefixes: [], rex: rex, opcode: [0x50 | UInt8(reg.low3)], body: [])
        case .immediate(let imm):
            if imm.fitsSigned(bits: 8) {
                return [0x6A, try imm.signedByte()]
            }
            guard imm.fitsSigned(bits: 32) else {
                throw Diagnostic.immediateOutOfRange("pushq immediate requires sign-extended imm32")
            }
            return [0x68] + imm.signedLittleEndianBytes(width: 4)
        default:
            throw Diagnostic.badOperand(operands[0].text)
        }
    }

    private func encodePop(_ mnemonic: String, _ operands: [Operand], width: Width) throws -> [UInt8] {
        guard width == .qword else { throw Diagnostic.notEncodable("pop is qword-only in package 01") }
        guard operands.count == 1 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 register") }
        guard case .register(let reg) = operands[0] else { throw Diagnostic.badOperand(operands[0].text) }
        try require(reg, width: .qword, mnemonic: mnemonic)
        var rex = REX()
        rex.b = reg.index >= 8
        return finish(prefixes: [], rex: rex, opcode: [0x58 | UInt8(reg.low3)], body: [])
    }

    private func encodeIndirectBranch(_ mnemonic: String, _ operands: [Operand], group: Int) throws -> [UInt8] {
        guard operands.count == 1 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 indirect register or memory operand")
        }
        guard case .indirect(let target, _) = operands[0] else {
            throw Diagnostic.badOperand("direct \(mnemonic) is deferred to package 02")
        }
        if case .register(let reg) = target {
            try require(reg, width: .qword, mnemonic: mnemonic)
        } else if case .memory = target {
            // group 5 call/jmp uses qword r/m in long mode.
        } else {
            throw Diagnostic.badOperand(target.text)
        }
        return try emitGroup(opcode: 0xFF, group: group, width: .qword, rexW: false, rmOperand: target, immediate: [])
    }

    private func encodeBranchOrIndirect(_ mnemonic: String, _ operands: [Operand], directOpcode: UInt8, group: Int) throws -> [UInt8] {
        guard operands.count == 1 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 direct displacement or indirect register or memory operand")
        }
        if let displacement = Self.directBranchDisplacement(operands[0]) {
            return try encodeRel32Branch(opcode: [directOpcode], displacement: displacement, operandText: operands[0].text)
        }
        guard case .indirect = operands[0] else {
            throw Diagnostic.badOperand("\(mnemonic) direct targets require a bare rel32 displacement; indirect targets require '*'")
        }
        return try encodeIndirectBranch(mnemonic, operands, group: group)
    }

    private func encodeConditionalBranch(_ mnemonic: String, _ operands: [Operand], condition: UInt8) throws -> [UInt8] {
        guard operands.count == 1 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 direct displacement")
        }
        guard let displacement = Self.directBranchDisplacement(operands[0]) else {
            throw Diagnostic.badOperand(operands.first?.text ?? mnemonic)
        }
        return try encodeRel32Branch(opcode: [0x0F, 0x80 | condition], displacement: displacement, operandText: operands[0].text)
    }

    private func encodeRel32Branch(opcode: [UInt8], displacement: Int64, operandText: String) throws -> [UInt8] {
        opcode + (try Self.rel32Bytes(displacement, operandText: operandText))
    }

    private func encodeShift(_ op: String, mnemonic: String, operands: [Operand], width: Width) throws -> [UInt8] {
        guard operands.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "count, register or memory operand")
        }
        let target = operands[1]
        if case .register(let reg) = target {
            try require(reg, width: width, mnemonic: mnemonic)
        } else if case .memory = target {
            // memory width comes from suffix
        } else {
            throw Diagnostic.badOperand(target.text)
        }

        let group: Int
        switch op {
        case "shl": group = 4
        case "shr": group = 5
        case "sar": group = 7
        default: throw Diagnostic.unknownMnemonic(op)
        }

        switch operands[0] {
        case .immediate(let imm):
            let count = try imm.byteValue(width: 1)
            if count == 1 {
                return try emitGroup(opcode: width == .byte ? 0xD0 : 0xD1, group: group, width: width, rexW: width == .qword, rmOperand: target, immediate: [])
            }
            return try emitGroup(opcode: width == .byte ? 0xC0 : 0xC1, group: group, width: width, rexW: width == .qword, rmOperand: target, immediate: [count])
        case .register(let reg):
            guard reg.name == "cl" else { throw Diagnostic.badRegister("%\(reg.name) (shift count must be %cl)") }
            return try emitGroup(opcode: width == .byte ? 0xD2 : 0xD3, group: group, width: width, rexW: width == .qword, rmOperand: target, immediate: [])
        default:
            throw Diagnostic.badOperand(operands[0].text)
        }
    }

    // MARK: - ModRM / SIB / REX

    private enum Direction { case store, load }

    private func emitModRM(opcode: UInt8, width: Width, rexW: Bool, reg: Register, rm: RMOperand) throws -> [UInt8] {
        var rex = REX()
        rex.w = rexW
        rex.r = reg.index >= 8
        rex.force = width == .byte && reg.forceREXForByteOperand
        let encoded = try encodeModRM(regField: reg.index, rm: rm, width: width, rex: &rex)
        let prefixes = width == .word ? [UInt8(0x66)] : []
        return finish(prefixes: prefixes, rex: rex, opcode: [opcode], body: encoded.bytes)
    }

    private func emitGroup(opcode: UInt8, group: Int, width: Width, rexW: Bool, rmOperand: Operand, immediate: [UInt8]) throws -> [UInt8] {
        let rm: RMOperand
        switch rmOperand {
        case .register(let reg):
            try require(reg, width: width, mnemonic: "group")
            rm = .register(reg)
        case .memory(let mem):
            rm = .memory(mem)
        default:
            throw Diagnostic.badOperand(rmOperand.text)
        }

        var rex = REX()
        rex.w = rexW
        let encoded = try encodeModRM(regField: group, rm: rm, width: width, rex: &rex)
        let prefixes = width == .word ? [UInt8(0x66)] : []
        return finish(prefixes: prefixes, rex: rex, opcode: [opcode], body: encoded.bytes + immediate)
    }

    private struct EncodedModRM {
        var bytes: [UInt8]
    }

    private struct EncodedVEXModRM {
        var bytes: [UInt8]
        var r: Bool
        var x: Bool
        var b: Bool
    }

    private struct EncodedEVEXModRM {
        var bytes: [UInt8]
        var r: Bool
        var x: Bool
        var b: Bool
        var rPrime: Bool
    }

    private func encodeVEXModRM(regField: Int, rm: RMOperand) throws -> EncodedVEXModRM {
        guard (0..<16).contains(regField) else {
            throw Diagnostic.notEncodable("VEX cannot encode vector register \(regField)")
        }
        if case .register(let reg) = rm, reg.index >= 16 {
            throw Diagnostic.notEncodable("VEX cannot encode vector register \(reg.index)")
        }
        var extensions = REX()
        extensions.r = regField >= 8
        let encoded = try encodeModRM(regField: regField, rm: rm, width: .qword, rex: &extensions)
        return EncodedVEXModRM(bytes: encoded.bytes, r: extensions.r, x: extensions.x, b: extensions.b)
    }

    private func encodeEVEXModRM(regField: Int, rm: RMOperand, disp8Scale: Int) throws -> EncodedEVEXModRM {
        guard (0..<32).contains(regField) else {
            throw Diagnostic.notEncodable("EVEX vector register index out of range")
        }
        var extensions = REX()
        extensions.r = (regField & 0x08) != 0
        let rPrime = (regField & 0x10) != 0

        switch rm {
        case .register(let reg):
            guard (0..<32).contains(reg.index) else {
                throw Diagnostic.notEncodable("EVEX vector register index out of range")
            }
            extensions.b = (reg.index & 0x08) != 0
            extensions.x = (reg.index & 0x10) != 0
            let modrm = UInt8(0b11_000_000 | ((regField & 0x7) << 3) | reg.low3)
            return EncodedEVEXModRM(bytes: [modrm], r: extensions.r, x: extensions.x, b: extensions.b, rPrime: rPrime)
        case .memory:
            let encoded = try encodeModRM(regField: regField, rm: rm, width: .qword, rex: &extensions, disp8Scale: disp8Scale)
            return EncodedEVEXModRM(bytes: encoded.bytes, r: extensions.r, x: extensions.x, b: extensions.b, rPrime: rPrime)
        }
    }

    private func encodeModRM(regField: Int, rm: RMOperand, width: Width, rex: inout REX, disp8Scale: Int = 1) throws -> EncodedModRM {
        switch rm {
        case .register(let reg):
            rex.b = rex.b || reg.index >= 8
            rex.force = rex.force || (width == .byte && reg.forceREXForByteOperand)
            try checkHighByteREX(reg, rex: rex)
            let modrm = UInt8(0b11_000_000 | ((regField & 0x7) << 3) | reg.low3)
            return EncodedModRM(bytes: [modrm])
        case .memory(let mem):
            return try encodeMemoryModRM(regField: regField, memory: mem, rex: &rex, disp8Scale: disp8Scale)
        }
    }

    private func encodeMemoryModRM(regField: Int, memory: Memory, rex: inout REX, disp8Scale: Int = 1) throws -> EncodedModRM {
        if memory.ripRelative {
            guard memory.base == nil, memory.index == nil else {
                throw Diagnostic.badOperand(memory.text)
            }
            guard memory.displacementFits32 else { throw Diagnostic.offsetOutOfRange(memory.text) }
            let modrm = UInt8(((regField & 0x7) << 3) | 0x05)
            return EncodedModRM(bytes: [modrm] + Self.int32Bytes(memory.displacement))
        }

        if let base = memory.base {
            rex.b = rex.b || base.index >= 8
        }
        if let index = memory.index {
            rex.x = rex.x || index.index >= 8
            if index.index == 4 {
                throw Diagnostic.notEncodable("%rsp cannot be used as an index register")
            }
        }

        let needsSIB = memory.index != nil || memory.base?.low3 == 4 || memory.base == nil
        let disp = memory.displacement
        let baseLow = memory.base?.low3

        let mod: Int
        let dispBytes: [UInt8]
        if memory.base == nil {
            mod = 0
            guard memory.displacementFits32 else { throw Diagnostic.offsetOutOfRange(memory.text) }
            dispBytes = Self.int32Bytes(disp)
        } else if disp == 0 && baseLow != 5 {
            mod = 0
            dispBytes = []
        } else if let compressed = Self.compressedDisp8(disp, scale: disp8Scale) {
            mod = 1
            dispBytes = [UInt8(bitPattern: compressed)]
        } else {
            mod = 2
            guard memory.displacementFits32 else { throw Diagnostic.offsetOutOfRange(memory.text) }
            dispBytes = Self.int32Bytes(disp)
        }

        let rmField = needsSIB ? 4 : (baseLow ?? 5)
        var bytes = [UInt8((mod << 6) | ((regField & 0x7) << 3) | rmField)]

        if needsSIB {
            let scaleBits: Int
            switch memory.scale {
            case 1: scaleBits = 0
            case 2: scaleBits = 1
            case 4: scaleBits = 2
            case 8: scaleBits = 3
            default: throw Diagnostic.badOperand(memory.text)
            }
            let indexField = memory.index?.low3 ?? 4
            let baseField = memory.base?.low3 ?? 5
            bytes.append(UInt8((scaleBits << 6) | (indexField << 3) | baseField))
        }
        bytes += dispBytes
        return EncodedModRM(bytes: bytes)
    }

    private func finish(prefixes: [UInt8], rex: REX, opcode: [UInt8], body: [UInt8]) -> [UInt8] {
        var bytes = prefixes
        if let rexByte = rex.byte {
            bytes.append(rexByte)
        }
        bytes += opcode
        bytes += body
        return bytes
    }

    private func require(_ reg: Register, width: Width, mnemonic: String) throws {
        guard reg.width == width else {
            throw Diagnostic.badRegister("%\(reg.name) does not match \(mnemonic)'s \(width.suffix)-width form")
        }
    }

    private func checkHighByteREX(_ reg: Register, rex: REX) throws {
        if reg.highByte, rex.needsEmission {
            throw Diagnostic.notEncodable("high-byte registers cannot be encoded with a REX prefix")
        }
    }

    // MARK: - Parser

    private enum ParsedMnemonic {
        case sized(base: String, width: Width?)

        var base: String {
            switch self {
            case .sized(let base, _): return base
            }
        }

        var explicitWidth: Width? {
            switch self {
            case .sized(_, let width): return width
            }
        }

        var hasExplicitWidth: Bool {
            explicitWidth != nil
        }
    }

    private static func parseMnemonic(_ mnemonic: String) throws -> ParsedMnemonic {
        let suffixWidth: [Character: Width] = ["b": .byte, "w": .word, "l": .dword, "q": .qword]
        let sized = Self.sizedMnemonicBases
        if let last = mnemonic.last, let width = suffixWidth[last] {
            let base = String(mnemonic.dropLast())
            if sized.contains(base) {
                return .sized(base: base, width: width)
            }
        }
        guard sized.contains(mnemonic) else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return .sized(base: mnemonic, width: nil)
    }

    private static func resolveWidth(_ parsed: ParsedMnemonic, mnemonic: String, operands: [Operand]) throws -> Width {
        if let explicitWidth = parsed.explicitWidth {
            return explicitWidth
        }
        switch parsed.base {
        case "push", "pop":
            return .qword
        default:
            guard let inferred = inferredRegisterWidth(from: operands) else {
                throw Diagnostic.ambiguousWidth(mnemonic: mnemonic)
            }
            return inferred
        }
    }

    private static func inferredRegisterWidth(from operands: [Operand]) -> Width? {
        for operand in operands.reversed() {
            if let width = registerWidth(in: operand) {
                return width
            }
        }
        return nil
    }

    private static func registerWidth(in operand: Operand) -> Width? {
        switch operand {
        case .register(let reg):
            return reg.width
        case .indirect(let target, _):
            return registerWidth(in: target)
        case .decorated(let target, _):
            return registerWidth(in: target)
        case .immediate, .memory, .evexRounding:
            return nil
        }
    }

    private static func split(_ text: String) -> (String, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (trimmed, "")
        }
        let mnemonic = String(trimmed[..<firstSpace])
        let operands = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (mnemonic, operands)
    }

    private static func stripComment(_ text: String) -> String {
        var inParen = 0
        var previous: Character?
        for index in text.indices {
            let ch = text[index]
            if ch == "(" { inParen += 1 }
            if ch == ")" { inParen = max(0, inParen - 1) }
            if ch == "#", inParen == 0, (previous == nil || previous == " " || previous == "\t") {
                return String(text[..<index])
            }
            previous = ch
        }
        return text
    }

    private static func splitOperands(_ text: String) throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var operands: [String] = []
        var start = trimmed.startIndex
        var depth = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let ch = trimmed[index]
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 {
                operands.append(String(trimmed[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = trimmed.index(after: index)
            }
            index = trimmed.index(after: index)
        }
        operands.append(String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        guard depth == 0, operands.allSatisfy({ !$0.isEmpty }) else {
            throw Diagnostic.badOperand(text)
        }
        return operands
    }

    private static func parseOperand(_ raw: String) throws -> Operand {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rounding = EVEXRounding(text: text) {
            return .evexRounding(rounding)
        }
        let (baseText, decoration) = try splitEVEXDecorations(text)
        let operand = try parsePlainOperand(baseText)
        if decoration.isNoOpZeroingOnly {
            return operand
        }
        if !decoration.isEmpty {
            return .decorated(operand, decoration)
        }
        return operand
    }

    private static func parsePlainOperand(_ text: String) throws -> Operand {
        if text.hasPrefix("*") {
            let inner = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return .indirect(try parseOperand(inner), text: text)
        }
        if text.hasPrefix("$") {
            return .immediate(try parseImmediate(String(text.dropFirst()), original: text))
        }
        if text.hasPrefix("%") {
            return .register(try parseRegister(text))
        }
        if text.contains("(") || text.contains(")") || parseBareNumber(text) != nil {
            return .memory(try parseMemory(text))
        }
        throw Diagnostic.badOperand(text)
    }

    private static func splitEVEXDecorations(_ text: String) throws -> (String, EVEXDecoration) {
        var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var decoration = EVEXDecoration()

        while base.hasSuffix("}") {
            guard let open = base.lastIndex(of: "{") else { throw Diagnostic.badOperand(text) }
            let close = base.index(before: base.endIndex)
            let token = String(base[base.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if token == "z" {
                decoration.zeroing = true
            } else if token.hasPrefix("%k"), let mask = Int(token.dropFirst(2)), (0...7).contains(mask) {
                guard decoration.mask == nil else { throw Diagnostic.badOperand(text) }
                decoration.mask = mask
            } else if token.hasPrefix("1to"), let count = Int(token.dropFirst(3)), count > 0 {
                guard decoration.broadcast == nil else { throw Diagnostic.badOperand(text) }
                decoration.broadcast = count
            } else {
                throw Diagnostic.badOperand(text)
            }
            base = String(base[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !base.isEmpty, !base.contains("{"), !base.contains("}") else {
            throw Diagnostic.badOperand(text)
        }
        return (base, decoration)
    }

    private static func parseMemory(_ text: String) throws -> Memory {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "(") else {
            guard let disp = parseBareNumber(trimmed) else { throw Diagnostic.badOperand(text) }
            return Memory(text: text, displacement: disp, base: nil, index: nil, scale: 1, ripRelative: false)
        }
        guard let close = trimmed.lastIndex(of: ")"), close == trimmed.index(before: trimmed.endIndex), open < close else {
            throw Diagnostic.badOperand(text)
        }

        let dispText = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let displacement: Int64
        if dispText.isEmpty {
            displacement = 0
        } else if let parsed = parseBareNumber(dispText) {
            displacement = parsed
        } else {
            throw Diagnostic.badOperand(text)
        }
        let inner = String(trimmed[trimmed.index(after: open)..<close])
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (1...3).contains(parts.count) else { throw Diagnostic.badOperand(text) }

        var base: Register?
        var index: Register?
        var scale = 1
        var ripRelative = false

        if !parts[0].isEmpty {
            if parts[0].lowercased() == "%rip" {
                ripRelative = true
            } else {
                let reg = try parseRegister(parts[0])
                guard reg.width == .qword else { throw Diagnostic.badRegister(parts[0]) }
                base = reg
            }
        }

        if parts.count >= 2, !parts[1].isEmpty {
            let reg = try parseRegister(parts[1])
            guard reg.width == .qword else { throw Diagnostic.badRegister(parts[1]) }
            index = reg
        }
        if parts.count == 3, !parts[2].isEmpty {
            guard let parsed = Int(parts[2]), [1, 2, 4, 8].contains(parsed) else {
                throw Diagnostic.badOperand(text)
            }
            scale = parsed
        }
        if ripRelative, (index != nil || parts.count > 1) {
            throw Diagnostic.badOperand(text)
        }

        return Memory(text: text, displacement: displacement, base: base, index: index, scale: scale, ripRelative: ripRelative)
    }

    private static func parseRegister(_ token: String) throws -> Register {
        let name = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.hasPrefix("%") else { throw Diagnostic.badRegister(token) }
        let bare = String(name.dropFirst())
        if let reg = registerByName[bare] {
            return reg
        }
        throw Diagnostic.badRegister(token)
    }

    private static func parseImmediate(_ token: String, original: String) throws -> Immediate {
        guard let parsed = parseNumberToken(token) else {
            throw Diagnostic.badOperand(original)
        }
        return Immediate(text: original, negative: parsed.negative, magnitude: parsed.magnitude, bits: parsed.bits)
    }

    private static func parseBareNumber(_ token: String) -> Int64? {
        guard let parsed = parseNumberToken(token) else { return nil }
        if parsed.negative {
            guard parsed.magnitude <= UInt64(Int64.max) + 1 else { return nil }
            if parsed.magnitude == UInt64(Int64.max) + 1 { return Int64.min }
            return -Int64(parsed.magnitude)
        }
        guard parsed.magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(parsed.magnitude)
    }

    private static func parseNumberToken(_ token: String) -> (negative: Bool, magnitude: UInt64, bits: UInt64)? {
        var s = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("+") {
            s.removeFirst()
        } else if s.hasPrefix("-") {
            negative = true
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }
        let radix: Int
        if s.hasPrefix("0x") {
            radix = 16
            s.removeFirst(2)
        } else {
            radix = 10
        }
        guard let magnitude = UInt64(s, radix: radix) else { return nil }
        let bits: UInt64
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            if magnitude == UInt64(Int64.max) + 1 {
                bits = UInt64(bitPattern: Int64.min)
            } else {
                bits = UInt64(bitPattern: -Int64(magnitude))
            }
        } else {
            bits = magnitude
        }
        return (negative, magnitude, bits)
    }

    // MARK: - Tables

    private static func aluBase(_ op: String) throws -> UInt8 {
        switch op {
        case "add": return 0x00
        case "or": return 0x08
        case "and": return 0x20
        case "sub": return 0x28
        case "xor": return 0x30
        case "cmp": return 0x38
        default: throw Diagnostic.unknownMnemonic(op)
        }
    }

    private static func aluOpcode(_ op: String, byte: Bool, direction: Direction) throws -> UInt8 {
        let base = try aluBase(op)
        switch (byte, direction) {
        case (true, .store): return base
        case (false, .store): return base + 1
        case (true, .load): return base + 2
        case (false, .load): return base + 3
        }
    }

    private static func aluAccumulatorOpcode(_ op: String, byte: Bool) throws -> UInt8 {
        try aluBase(op) + (byte ? 4 : 5)
    }

    private static func aluGroupIndex(_ op: String) throws -> Int {
        switch op {
        case "add": return 0
        case "or": return 1
        case "and": return 4
        case "sub": return 5
        case "xor": return 6
        case "cmp": return 7
        default: throw Diagnostic.unknownMnemonic(op)
        }
    }

    private static func conditionCode(for mnemonic: String) -> UInt8? {
        switch mnemonic {
        case "jo": return 0x0
        case "jno": return 0x1
        case "jb", "jc", "jnae": return 0x2
        case "jae", "jnb", "jnc": return 0x3
        case "je", "jz": return 0x4
        case "jne", "jnz": return 0x5
        case "jbe", "jna": return 0x6
        case "ja", "jnbe": return 0x7
        case "js": return 0x8
        case "jns": return 0x9
        case "jp", "jpe": return 0xA
        case "jnp", "jpo": return 0xB
        case "jl", "jnge": return 0xC
        case "jge", "jnl": return 0xD
        case "jle", "jng": return 0xE
        case "jg", "jnle": return 0xF
        default: return nil
        }
    }

    private static let sizedMnemonicBases: Set<String> = [
        "mov", "lea", "add", "sub", "and", "or", "xor", "cmp", "test",
        "inc", "dec", "neg", "not", "push", "pop", "shl", "shr", "sar",
    ]

    private static let qwordNames = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
    private static let dwordNames = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"]
    private static let wordNames = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"]
    private static let byteNames = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"]

    private static let registerByName: [String: Register] = {
        var result: [String: Register] = [:]
        for i in 0..<16 {
            result[qwordNames[i]] = Register(name: qwordNames[i], index: i, width: .qword, highByte: false)
            result[dwordNames[i]] = Register(name: dwordNames[i], index: i, width: .dword, highByte: false)
            result[wordNames[i]] = Register(name: wordNames[i], index: i, width: .word, highByte: false)
            result[byteNames[i]] = Register(name: byteNames[i], index: i, width: .byte, highByte: false)
        }
        for i in 0..<32 {
            result["xmm\(i)"] = Register(name: "xmm\(i)", index: i, highByte: false, vectorWidth: .xmm)
            result["ymm\(i)"] = Register(name: "ymm\(i)", index: i, highByte: false, vectorWidth: .ymm)
            result["zmm\(i)"] = Register(name: "zmm\(i)", index: i, highByte: false, vectorWidth: .zmm)
        }
        result["ah"] = Register(name: "ah", index: 4, width: .byte, highByte: true)
        result["ch"] = Register(name: "ch", index: 5, width: .byte, highByte: true)
        result["dh"] = Register(name: "dh", index: 6, width: .byte, highByte: true)
        result["bh"] = Register(name: "bh", index: 7, width: .byte, highByte: true)
        return result
    }()

    private static let vexScalarThreeOperandOpcodes: [String: VEXOpcodeSpec] = [
        "vaddss": .init(map: .map0F, pp: .f3, opcode: 0x58),
        "vaddsd": .init(map: .map0F, pp: .f2, opcode: 0x58),
        "vsubss": .init(map: .map0F, pp: .f3, opcode: 0x5C),
        "vsubsd": .init(map: .map0F, pp: .f2, opcode: 0x5C),
        "vmulss": .init(map: .map0F, pp: .f3, opcode: 0x59),
        "vmulsd": .init(map: .map0F, pp: .f2, opcode: 0x59),
        "vdivss": .init(map: .map0F, pp: .f3, opcode: 0x5E),
        "vdivsd": .init(map: .map0F, pp: .f2, opcode: 0x5E),
        "vminss": .init(map: .map0F, pp: .f3, opcode: 0x5D),
        "vminsd": .init(map: .map0F, pp: .f2, opcode: 0x5D),
        "vmaxss": .init(map: .map0F, pp: .f3, opcode: 0x5F),
        "vmaxsd": .init(map: .map0F, pp: .f2, opcode: 0x5F),
        "vsqrtss": .init(map: .map0F, pp: .f3, opcode: 0x51),
        "vsqrtsd": .init(map: .map0F, pp: .f2, opcode: 0x51),
        "vcvtss2sd": .init(map: .map0F, pp: .f3, opcode: 0x5A),
        "vcvtsd2ss": .init(map: .map0F, pp: .f2, opcode: 0x5A),

        "vfmadd132ss": .init(map: .map0F38, pp: .p66, opcode: 0x99),
        "vfmadd132sd": .init(map: .map0F38, pp: .p66, opcode: 0x99, w: true),
        "vfmadd213ss": .init(map: .map0F38, pp: .p66, opcode: 0xA9),
        "vfmadd213sd": .init(map: .map0F38, pp: .p66, opcode: 0xA9, w: true),
        "vfmadd231ss": .init(map: .map0F38, pp: .p66, opcode: 0xB9),
        "vfmadd231sd": .init(map: .map0F38, pp: .p66, opcode: 0xB9, w: true),
        "vfmsub132ss": .init(map: .map0F38, pp: .p66, opcode: 0x9B),
        "vfmsub132sd": .init(map: .map0F38, pp: .p66, opcode: 0x9B, w: true),
        "vfmsub213ss": .init(map: .map0F38, pp: .p66, opcode: 0xAB),
        "vfmsub213sd": .init(map: .map0F38, pp: .p66, opcode: 0xAB, w: true),
        "vfmsub231ss": .init(map: .map0F38, pp: .p66, opcode: 0xBB),
        "vfmsub231sd": .init(map: .map0F38, pp: .p66, opcode: 0xBB, w: true),
        "vfnmadd132ss": .init(map: .map0F38, pp: .p66, opcode: 0x9D),
        "vfnmadd132sd": .init(map: .map0F38, pp: .p66, opcode: 0x9D, w: true),
        "vfnmadd213ss": .init(map: .map0F38, pp: .p66, opcode: 0xAD),
        "vfnmadd213sd": .init(map: .map0F38, pp: .p66, opcode: 0xAD, w: true),
        "vfnmadd231ss": .init(map: .map0F38, pp: .p66, opcode: 0xBD),
        "vfnmadd231sd": .init(map: .map0F38, pp: .p66, opcode: 0xBD, w: true),
        "vfnmsub132ss": .init(map: .map0F38, pp: .p66, opcode: 0x9F),
        "vfnmsub132sd": .init(map: .map0F38, pp: .p66, opcode: 0x9F, w: true),
        "vfnmsub213ss": .init(map: .map0F38, pp: .p66, opcode: 0xAF),
        "vfnmsub213sd": .init(map: .map0F38, pp: .p66, opcode: 0xAF, w: true),
        "vfnmsub231ss": .init(map: .map0F38, pp: .p66, opcode: 0xBF),
        "vfnmsub231sd": .init(map: .map0F38, pp: .p66, opcode: 0xBF, w: true),
    ]

    private static let vexScalarMoveOpcodes: [String: VEXMoveOpcodeSpec] = [
        "vmovss": .init(load: .init(map: .map0F, pp: .f3, opcode: 0x10), store: .init(map: .map0F, pp: .f3, opcode: 0x11)),
        "vmovsd": .init(load: .init(map: .map0F, pp: .f2, opcode: 0x10), store: .init(map: .map0F, pp: .f2, opcode: 0x11)),
    ]

    private static let vexScalarCompareOpcodes: [String: VEXOpcodeSpec] = [
        "vucomiss": .init(map: .map0F, pp: .none, opcode: 0x2E),
        "vucomisd": .init(map: .map0F, pp: .p66, opcode: 0x2E),
        "vcomiss": .init(map: .map0F, pp: .none, opcode: 0x2F),
        "vcomisd": .init(map: .map0F, pp: .p66, opcode: 0x2F),
    ]

    private static let evexScalarThreeOperandOpcodes: [String: EVEXScalarOpcodeSpec] = [
        "vaddss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x58, elementBytes: 4), roundingPolicy: .rounding),
        "vaddsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x58, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vsubss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x5C, elementBytes: 4), roundingPolicy: .rounding),
        "vsubsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x5C, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vmulss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x59, elementBytes: 4), roundingPolicy: .rounding),
        "vmulsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x59, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vdivss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x5E, elementBytes: 4), roundingPolicy: .rounding),
        "vdivsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x5E, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vminss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x5D, elementBytes: 4), roundingPolicy: .saeOnly),
        "vminsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x5D, w: true, elementBytes: 8), roundingPolicy: .saeOnly),
        "vmaxss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x5F, elementBytes: 4), roundingPolicy: .saeOnly),
        "vmaxsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x5F, w: true, elementBytes: 8), roundingPolicy: .saeOnly),
        "vsqrtss": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x51, elementBytes: 4), roundingPolicy: .rounding),
        "vsqrtsd": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x51, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vcvtss2sd": .init(evex: .init(map: .map0F, pp: .f3, opcode: 0x5A, elementBytes: 4), roundingPolicy: .saeOnly),
        "vcvtsd2ss": .init(evex: .init(map: .map0F, pp: .f2, opcode: 0x5A, w: true, elementBytes: 8), roundingPolicy: .rounding),

        "vfmadd132ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x99, elementBytes: 4), roundingPolicy: .rounding),
        "vfmadd132sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x99, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfmadd213ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xA9, elementBytes: 4), roundingPolicy: .rounding),
        "vfmadd213sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xA9, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfmadd231ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xB9, elementBytes: 4), roundingPolicy: .rounding),
        "vfmadd231sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xB9, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfmsub132ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x9B, elementBytes: 4), roundingPolicy: .rounding),
        "vfmsub132sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x9B, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfmsub213ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xAB, elementBytes: 4), roundingPolicy: .rounding),
        "vfmsub213sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xAB, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfmsub231ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xBB, elementBytes: 4), roundingPolicy: .rounding),
        "vfmsub231sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xBB, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfnmadd132ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x9D, elementBytes: 4), roundingPolicy: .rounding),
        "vfnmadd132sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x9D, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfnmadd213ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xAD, elementBytes: 4), roundingPolicy: .rounding),
        "vfnmadd213sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xAD, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfnmadd231ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xBD, elementBytes: 4), roundingPolicy: .rounding),
        "vfnmadd231sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xBD, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfnmsub132ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x9F, elementBytes: 4), roundingPolicy: .rounding),
        "vfnmsub132sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x9F, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfnmsub213ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xAF, elementBytes: 4), roundingPolicy: .rounding),
        "vfnmsub213sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xAF, w: true, elementBytes: 8), roundingPolicy: .rounding),
        "vfnmsub231ss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xBF, elementBytes: 4), roundingPolicy: .rounding),
        "vfnmsub231sd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0xBF, w: true, elementBytes: 8), roundingPolicy: .rounding),
    ]

    private static let vexThreeOperandOpcodes: [String: VEXOpcodeSpec] = [
        "vaddps": .init(map: .map0F, pp: .none, opcode: 0x58, commutative: true),
        "vaddpd": .init(map: .map0F, pp: .p66, opcode: 0x58, commutative: true),
        "vsubps": .init(map: .map0F, pp: .none, opcode: 0x5C),
        "vsubpd": .init(map: .map0F, pp: .p66, opcode: 0x5C),
        "vmulps": .init(map: .map0F, pp: .none, opcode: 0x59, commutative: true),
        "vmulpd": .init(map: .map0F, pp: .p66, opcode: 0x59, commutative: true),
        "vdivps": .init(map: .map0F, pp: .none, opcode: 0x5E),
        "vdivpd": .init(map: .map0F, pp: .p66, opcode: 0x5E),
        "vminps": .init(map: .map0F, pp: .none, opcode: 0x5D),
        "vminpd": .init(map: .map0F, pp: .p66, opcode: 0x5D),
        "vmaxps": .init(map: .map0F, pp: .none, opcode: 0x5F),
        "vmaxpd": .init(map: .map0F, pp: .p66, opcode: 0x5F),

        "vandps": .init(map: .map0F, pp: .none, opcode: 0x54, commutative: true),
        "vandpd": .init(map: .map0F, pp: .p66, opcode: 0x54, commutative: true),
        "vandnps": .init(map: .map0F, pp: .none, opcode: 0x55),
        "vandnpd": .init(map: .map0F, pp: .p66, opcode: 0x55),
        "vorps": .init(map: .map0F, pp: .none, opcode: 0x56, commutative: true),
        "vorpd": .init(map: .map0F, pp: .p66, opcode: 0x56, commutative: true),
        "vxorps": .init(map: .map0F, pp: .none, opcode: 0x57, commutative: true),
        "vxorpd": .init(map: .map0F, pp: .p66, opcode: 0x57, commutative: true),

        "vpunpcklbw": .init(map: .map0F, pp: .p66, opcode: 0x60),
        "vpunpcklwd": .init(map: .map0F, pp: .p66, opcode: 0x61),
        "vpunpckldq": .init(map: .map0F, pp: .p66, opcode: 0x62),
        "vpacksswb": .init(map: .map0F, pp: .p66, opcode: 0x63),
        "vpackuswb": .init(map: .map0F, pp: .p66, opcode: 0x67),
        "vpunpckhbw": .init(map: .map0F, pp: .p66, opcode: 0x68),
        "vpunpckhwd": .init(map: .map0F, pp: .p66, opcode: 0x69),
        "vpunpckhdq": .init(map: .map0F, pp: .p66, opcode: 0x6A),
        "vpackssdw": .init(map: .map0F, pp: .p66, opcode: 0x6B),
        "vpunpcklqdq": .init(map: .map0F, pp: .p66, opcode: 0x6C),
        "vpunpckhqdq": .init(map: .map0F, pp: .p66, opcode: 0x6D),
        "vpcmpgtb": .init(map: .map0F, pp: .p66, opcode: 0x64),
        "vpcmpgtw": .init(map: .map0F, pp: .p66, opcode: 0x65),
        "vpcmpgtd": .init(map: .map0F, pp: .p66, opcode: 0x66),
        "vpcmpeqb": .init(map: .map0F, pp: .p66, opcode: 0x74, commutative: true),
        "vpcmpeqw": .init(map: .map0F, pp: .p66, opcode: 0x75, commutative: true),
        "vpcmpeqd": .init(map: .map0F, pp: .p66, opcode: 0x76, commutative: true),
        "vpaddq": .init(map: .map0F, pp: .p66, opcode: 0xD4, commutative: true),
        "vpand": .init(map: .map0F, pp: .p66, opcode: 0xDB, commutative: true),
        "vpandn": .init(map: .map0F, pp: .p66, opcode: 0xDF),
        "vpor": .init(map: .map0F, pp: .p66, opcode: 0xEB, commutative: true),
        "vpxor": .init(map: .map0F, pp: .p66, opcode: 0xEF, commutative: true),
        "vpmullw": .init(map: .map0F, pp: .p66, opcode: 0xD5, commutative: true),
        "vpminub": .init(map: .map0F, pp: .p66, opcode: 0xDA, commutative: true),
        "vpmaxub": .init(map: .map0F, pp: .p66, opcode: 0xDE, commutative: true),
        "vpmulhuw": .init(map: .map0F, pp: .p66, opcode: 0xE4, commutative: true),
        "vpmulhw": .init(map: .map0F, pp: .p66, opcode: 0xE5, commutative: true),
        "vpminsw": .init(map: .map0F, pp: .p66, opcode: 0xEA, commutative: true),
        "vpmaxsw": .init(map: .map0F, pp: .p66, opcode: 0xEE, commutative: true),
        "vpmuludq": .init(map: .map0F, pp: .p66, opcode: 0xF4, commutative: true),
        "vpsubb": .init(map: .map0F, pp: .p66, opcode: 0xF8),
        "vpsubw": .init(map: .map0F, pp: .p66, opcode: 0xF9),
        "vpsubd": .init(map: .map0F, pp: .p66, opcode: 0xFA),
        "vpsubq": .init(map: .map0F, pp: .p66, opcode: 0xFB),
        "vpaddb": .init(map: .map0F, pp: .p66, opcode: 0xFC, commutative: true),
        "vpaddw": .init(map: .map0F, pp: .p66, opcode: 0xFD, commutative: true),
        "vpaddd": .init(map: .map0F, pp: .p66, opcode: 0xFE, commutative: true),

        "vpmulhrsw": .init(map: .map0F38, pp: .p66, opcode: 0x0B),
        "vpshufb": .init(map: .map0F38, pp: .p66, opcode: 0x00),
        "vpmuldq": .init(map: .map0F38, pp: .p66, opcode: 0x28),
        "vpackusdw": .init(map: .map0F38, pp: .p66, opcode: 0x2B),
        "vpminsb": .init(map: .map0F38, pp: .p66, opcode: 0x38),
        "vpminsd": .init(map: .map0F38, pp: .p66, opcode: 0x39),
        "vpminuw": .init(map: .map0F38, pp: .p66, opcode: 0x3A),
        "vpminud": .init(map: .map0F38, pp: .p66, opcode: 0x3B),
        "vpmaxsb": .init(map: .map0F38, pp: .p66, opcode: 0x3C),
        "vpmaxsd": .init(map: .map0F38, pp: .p66, opcode: 0x3D),
        "vpmaxuw": .init(map: .map0F38, pp: .p66, opcode: 0x3E),
        "vpmaxud": .init(map: .map0F38, pp: .p66, opcode: 0x3F),
        "vpmulld": .init(map: .map0F38, pp: .p66, opcode: 0x40),
        "vpsrlvd": .init(map: .map0F38, pp: .p66, opcode: 0x45),
        "vpsrlvq": .init(map: .map0F38, pp: .p66, opcode: 0x45, w: true),
        "vpsravd": .init(map: .map0F38, pp: .p66, opcode: 0x46),
        "vpsllvd": .init(map: .map0F38, pp: .p66, opcode: 0x47),
        "vpsllvq": .init(map: .map0F38, pp: .p66, opcode: 0x47, w: true),
        "vpermps": .init(map: .map0F38, pp: .p66, opcode: 0x16),
        "vpermd": .init(map: .map0F38, pp: .p66, opcode: 0x36),
    ]

    private static let evexThreeOperandOpcodes: [String: EVEXOpcodeSpec] = [
        "vaddps": .init(map: .map0F, pp: .none, opcode: 0x58, elementBytes: 4),
        "vaddpd": .init(map: .map0F, pp: .p66, opcode: 0x58, w: true, elementBytes: 8),
        "vsubps": .init(map: .map0F, pp: .none, opcode: 0x5C, elementBytes: 4),
        "vsubpd": .init(map: .map0F, pp: .p66, opcode: 0x5C, w: true, elementBytes: 8),
        "vmulps": .init(map: .map0F, pp: .none, opcode: 0x59, elementBytes: 4),
        "vmulpd": .init(map: .map0F, pp: .p66, opcode: 0x59, w: true, elementBytes: 8),
        "vdivps": .init(map: .map0F, pp: .none, opcode: 0x5E, elementBytes: 4),
        "vdivpd": .init(map: .map0F, pp: .p66, opcode: 0x5E, w: true, elementBytes: 8),
        "vminps": .init(map: .map0F, pp: .none, opcode: 0x5D, elementBytes: 4),
        "vminpd": .init(map: .map0F, pp: .p66, opcode: 0x5D, w: true, elementBytes: 8),
        "vmaxps": .init(map: .map0F, pp: .none, opcode: 0x5F, elementBytes: 4),
        "vmaxpd": .init(map: .map0F, pp: .p66, opcode: 0x5F, w: true, elementBytes: 8),

        "vpunpcklbw": .init(map: .map0F, pp: .p66, opcode: 0x60, elementBytes: 1, allowBroadcast: false),
        "vpunpcklwd": .init(map: .map0F, pp: .p66, opcode: 0x61, elementBytes: 2, allowBroadcast: false),
        "vpunpckldq": .init(map: .map0F, pp: .p66, opcode: 0x62, elementBytes: 4),
        "vpacksswb": .init(map: .map0F, pp: .p66, opcode: 0x63, elementBytes: 2, allowBroadcast: false),
        "vpackuswb": .init(map: .map0F, pp: .p66, opcode: 0x67, elementBytes: 2, allowBroadcast: false),
        "vpunpckhbw": .init(map: .map0F, pp: .p66, opcode: 0x68, elementBytes: 1, allowBroadcast: false),
        "vpunpckhwd": .init(map: .map0F, pp: .p66, opcode: 0x69, elementBytes: 2, allowBroadcast: false),
        "vpunpckhdq": .init(map: .map0F, pp: .p66, opcode: 0x6A, elementBytes: 4),
        "vpackssdw": .init(map: .map0F, pp: .p66, opcode: 0x6B, elementBytes: 4),
        "vpunpcklqdq": .init(map: .map0F, pp: .p66, opcode: 0x6C, w: true, elementBytes: 8),
        "vpunpckhqdq": .init(map: .map0F, pp: .p66, opcode: 0x6D, w: true, elementBytes: 8),

        "vpaddd": .init(map: .map0F, pp: .p66, opcode: 0xFE, elementBytes: 4),
        "vpaddq": .init(map: .map0F, pp: .p66, opcode: 0xD4, w: true, elementBytes: 8),
        "vpsubd": .init(map: .map0F, pp: .p66, opcode: 0xFA, elementBytes: 4),
        "vpsubq": .init(map: .map0F, pp: .p66, opcode: 0xFB, w: true, elementBytes: 8),
        "vpandd": .init(map: .map0F, pp: .p66, opcode: 0xDB, elementBytes: 4),
        "vpandq": .init(map: .map0F, pp: .p66, opcode: 0xDB, w: true, elementBytes: 8),
        "vpord": .init(map: .map0F, pp: .p66, opcode: 0xEB, elementBytes: 4),
        "vporq": .init(map: .map0F, pp: .p66, opcode: 0xEB, w: true, elementBytes: 8),
        "vpxord": .init(map: .map0F, pp: .p66, opcode: 0xEF, elementBytes: 4),
        "vpxorq": .init(map: .map0F, pp: .p66, opcode: 0xEF, w: true, elementBytes: 8),
        "vpmullw": .init(map: .map0F, pp: .p66, opcode: 0xD5, elementBytes: 2),
        "vpminub": .init(map: .map0F, pp: .p66, opcode: 0xDA, elementBytes: 1),
        "vpmaxub": .init(map: .map0F, pp: .p66, opcode: 0xDE, elementBytes: 1),
        "vpmulhuw": .init(map: .map0F, pp: .p66, opcode: 0xE4, elementBytes: 2),
        "vpmulhw": .init(map: .map0F, pp: .p66, opcode: 0xE5, elementBytes: 2),
        "vpminsw": .init(map: .map0F, pp: .p66, opcode: 0xEA, elementBytes: 2),
        "vpmaxsw": .init(map: .map0F, pp: .p66, opcode: 0xEE, elementBytes: 2),
        "vpmuludq": .init(map: .map0F, pp: .p66, opcode: 0xF4, w: true, elementBytes: 8),
        "vpshufb": .init(map: .map0F38, pp: .p66, opcode: 0x00, elementBytes: 1, allowBroadcast: false),
        "vpmulhrsw": .init(map: .map0F38, pp: .p66, opcode: 0x0B, elementBytes: 2),
        "vpmuldq": .init(map: .map0F38, pp: .p66, opcode: 0x28, w: true, elementBytes: 8),
        "vpackusdw": .init(map: .map0F38, pp: .p66, opcode: 0x2B, elementBytes: 4),
        "vpminsb": .init(map: .map0F38, pp: .p66, opcode: 0x38, elementBytes: 1),
        "vpminsd": .init(map: .map0F38, pp: .p66, opcode: 0x39, elementBytes: 4),
        "vpminsq": .init(map: .map0F38, pp: .p66, opcode: 0x39, w: true, elementBytes: 8),
        "vpminuw": .init(map: .map0F38, pp: .p66, opcode: 0x3A, elementBytes: 2),
        "vpminud": .init(map: .map0F38, pp: .p66, opcode: 0x3B, elementBytes: 4),
        "vpminuq": .init(map: .map0F38, pp: .p66, opcode: 0x3B, w: true, elementBytes: 8),
        "vpmaxsb": .init(map: .map0F38, pp: .p66, opcode: 0x3C, elementBytes: 1),
        "vpmaxsd": .init(map: .map0F38, pp: .p66, opcode: 0x3D, elementBytes: 4),
        "vpmaxsq": .init(map: .map0F38, pp: .p66, opcode: 0x3D, w: true, elementBytes: 8),
        "vpmaxuw": .init(map: .map0F38, pp: .p66, opcode: 0x3E, elementBytes: 2),
        "vpmaxud": .init(map: .map0F38, pp: .p66, opcode: 0x3F, elementBytes: 4),
        "vpmaxuq": .init(map: .map0F38, pp: .p66, opcode: 0x3F, w: true, elementBytes: 8),
        "vpmulld": .init(map: .map0F38, pp: .p66, opcode: 0x40, elementBytes: 4),
        "vpsrlvd": .init(map: .map0F38, pp: .p66, opcode: 0x45, elementBytes: 4),
        "vpsrlvq": .init(map: .map0F38, pp: .p66, opcode: 0x45, w: true, elementBytes: 8),
        "vpsravd": .init(map: .map0F38, pp: .p66, opcode: 0x46, elementBytes: 4),
        "vpsravq": .init(map: .map0F38, pp: .p66, opcode: 0x46, w: true, elementBytes: 8),
        "vpsllvd": .init(map: .map0F38, pp: .p66, opcode: 0x47, elementBytes: 4),
        "vpsllvq": .init(map: .map0F38, pp: .p66, opcode: 0x47, w: true, elementBytes: 8),
        "vpsrlvw": .init(map: .map0F38, pp: .p66, opcode: 0x10, w: true, elementBytes: 2, allowBroadcast: false),
        "vpsravw": .init(map: .map0F38, pp: .p66, opcode: 0x11, w: true, elementBytes: 2, allowBroadcast: false),
        "vpsllvw": .init(map: .map0F38, pp: .p66, opcode: 0x12, w: true, elementBytes: 2, allowBroadcast: false),
        "vpermps": .init(map: .map0F38, pp: .p66, opcode: 0x16, elementBytes: 4),
        "vpermpd": .init(map: .map0F38, pp: .p66, opcode: 0x16, w: true, elementBytes: 8),
        "vpermd": .init(map: .map0F38, pp: .p66, opcode: 0x36, elementBytes: 4),
        "vpermq": .init(map: .map0F38, pp: .p66, opcode: 0x36, w: true, elementBytes: 8),
        "vpblendmd": .init(map: .map0F38, pp: .p66, opcode: 0x64, elementBytes: 4),
        "vpblendmq": .init(map: .map0F38, pp: .p66, opcode: 0x64, w: true, elementBytes: 8),
        "vblendmps": .init(map: .map0F38, pp: .p66, opcode: 0x65, elementBytes: 4),
        "vblendmpd": .init(map: .map0F38, pp: .p66, opcode: 0x65, w: true, elementBytes: 8),
        "vpblendmb": .init(map: .map0F38, pp: .p66, opcode: 0x66, elementBytes: 1, allowBroadcast: false),
        "vpblendmw": .init(map: .map0F38, pp: .p66, opcode: 0x66, w: true, elementBytes: 2, allowBroadcast: false),
        "vpermi2b": .init(map: .map0F38, pp: .p66, opcode: 0x75, elementBytes: 1, allowBroadcast: false),
        "vpermi2w": .init(map: .map0F38, pp: .p66, opcode: 0x75, w: true, elementBytes: 2, allowBroadcast: false),
        "vpermi2d": .init(map: .map0F38, pp: .p66, opcode: 0x76, elementBytes: 4),
        "vpermi2q": .init(map: .map0F38, pp: .p66, opcode: 0x76, w: true, elementBytes: 8),
        "vpermi2ps": .init(map: .map0F38, pp: .p66, opcode: 0x77, elementBytes: 4),
        "vpermi2pd": .init(map: .map0F38, pp: .p66, opcode: 0x77, w: true, elementBytes: 8),
        "vpermt2b": .init(map: .map0F38, pp: .p66, opcode: 0x7D, elementBytes: 1, allowBroadcast: false),
        "vpermt2w": .init(map: .map0F38, pp: .p66, opcode: 0x7D, w: true, elementBytes: 2, allowBroadcast: false),
        "vpermt2d": .init(map: .map0F38, pp: .p66, opcode: 0x7E, elementBytes: 4),
        "vpermt2q": .init(map: .map0F38, pp: .p66, opcode: 0x7E, w: true, elementBytes: 8),
        "vpermt2ps": .init(map: .map0F38, pp: .p66, opcode: 0x7F, elementBytes: 4),
        "vpermt2pd": .init(map: .map0F38, pp: .p66, opcode: 0x7F, w: true, elementBytes: 8),
        "vpermb": .init(map: .map0F38, pp: .p66, opcode: 0x8D, elementBytes: 1, allowBroadcast: false),
        "vpermw": .init(map: .map0F38, pp: .p66, opcode: 0x8D, w: true, elementBytes: 2, allowBroadcast: false),
    ]

    private static let evexTernaryLogicOpcodes: [String: EVEXOpcodeSpec] = [
        "vpternlogd": .init(map: .map0F3A, pp: .p66, opcode: 0x25, elementBytes: 4),
        "vpternlogq": .init(map: .map0F3A, pp: .p66, opcode: 0x25, w: true, elementBytes: 8),
    ]

    private static let vectorShuffleImmediateOpcodes: [String: VectorShuffleImmediateOpcodeSpec] = [
        "vpshufd": .init(
            vex: .init(map: .map0F, pp: .p66, opcode: 0x70),
            evex: .init(map: .map0F, pp: .p66, opcode: 0x70, elementBytes: 4)
        ),
        "vpshufhw": .init(
            vex: .init(map: .map0F, pp: .f3, opcode: 0x70),
            evex: .init(map: .map0F, pp: .f3, opcode: 0x70, elementBytes: 2, allowBroadcast: false)
        ),
        "vpshuflw": .init(
            vex: .init(map: .map0F, pp: .f2, opcode: 0x70),
            evex: .init(map: .map0F, pp: .f2, opcode: 0x70, elementBytes: 2, allowBroadcast: false)
        ),
        "vpermq": .init(
            vex: .init(map: .map0F3A, pp: .p66, opcode: 0x00, w: true),
            evex: .init(map: .map0F3A, pp: .p66, opcode: 0x00, w: true, elementBytes: 8)
        ),
        "vpermpd": .init(
            vex: .init(map: .map0F3A, pp: .p66, opcode: 0x01, w: true),
            evex: .init(map: .map0F3A, pp: .p66, opcode: 0x01, w: true, elementBytes: 8)
        ),
    ]

    private static let yMMOrZMMOnlyPermuteMnemonics: Set<String> = [
        "vpermd", "vpermq", "vpermps", "vpermpd",
    ]

    private static let crossLanePermuteImmediateMnemonics: Set<String> = [
        "vpermq", "vpermpd",
    ]

    private static let vexPackedShiftCountOpcodes: [String: VEXOpcodeSpec] = [
        "vpsrlw": .init(map: .map0F, pp: .p66, opcode: 0xD1),
        "vpsrld": .init(map: .map0F, pp: .p66, opcode: 0xD2),
        "vpsrlq": .init(map: .map0F, pp: .p66, opcode: 0xD3),
        "vpsraw": .init(map: .map0F, pp: .p66, opcode: 0xE1),
        "vpsrad": .init(map: .map0F, pp: .p66, opcode: 0xE2),
        "vpsllw": .init(map: .map0F, pp: .p66, opcode: 0xF1),
        "vpslld": .init(map: .map0F, pp: .p66, opcode: 0xF2),
        "vpsllq": .init(map: .map0F, pp: .p66, opcode: 0xF3),
    ]

    private static let evexPackedShiftCountOpcodes: [String: EVEXOpcodeSpec] = [
        "vpsrlw": .init(map: .map0F, pp: .p66, opcode: 0xD1, elementBytes: 2),
        "vpsrld": .init(map: .map0F, pp: .p66, opcode: 0xD2, elementBytes: 4),
        "vpsrlq": .init(map: .map0F, pp: .p66, opcode: 0xD3, w: true, elementBytes: 8),
        "vpsraw": .init(map: .map0F, pp: .p66, opcode: 0xE1, elementBytes: 2),
        "vpsrad": .init(map: .map0F, pp: .p66, opcode: 0xE2, elementBytes: 4),
        "vpsraq": .init(map: .map0F, pp: .p66, opcode: 0xE2, w: true, elementBytes: 8),
        "vpsllw": .init(map: .map0F, pp: .p66, opcode: 0xF1, elementBytes: 2),
        "vpslld": .init(map: .map0F, pp: .p66, opcode: 0xF2, elementBytes: 4),
        "vpsllq": .init(map: .map0F, pp: .p66, opcode: 0xF3, w: true, elementBytes: 8),
    ]

    private static let packedShiftImmediateOpcodes: [String: PackedShiftImmediateOpcodeSpec] = [
        "vpsrlw": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x71),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x71, elementBytes: 2),
                         group: 2, allowBroadcast: false),
        "vpsrld": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x72),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x72, elementBytes: 4),
                         group: 2),
        "vpsrlq": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x73),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x73, w: true, elementBytes: 8),
                         group: 2),
        "vpsraw": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x71),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x71, elementBytes: 2),
                         group: 4, allowBroadcast: false),
        "vpsrad": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x72),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x72, elementBytes: 4),
                         group: 4),
        "vpsraq": .init(vex: nil,
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x72, w: true, elementBytes: 8),
                         group: 4),
        "vpsllw": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x71),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x71, elementBytes: 2),
                         group: 6, allowBroadcast: false),
        "vpslld": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x72),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x72, elementBytes: 4),
                         group: 6),
        "vpsllq": .init(vex: .init(map: .map0F, pp: .p66, opcode: 0x73),
                         evex: .init(map: .map0F, pp: .p66, opcode: 0x73, w: true, elementBytes: 8),
                         group: 6),
    ]

    private static let evexMoveOpcodes: [String: EVEXMoveOpcodeSpec] = [
        "vmovups": .init(load: .init(map: .map0F, pp: .none, opcode: 0x10, elementBytes: 4),
                         store: .init(map: .map0F, pp: .none, opcode: 0x11, elementBytes: 4)),
        "vmovupd": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x10, w: true, elementBytes: 8),
                         store: .init(map: .map0F, pp: .p66, opcode: 0x11, w: true, elementBytes: 8)),
        "vmovaps": .init(load: .init(map: .map0F, pp: .none, opcode: 0x28, elementBytes: 4),
                         store: .init(map: .map0F, pp: .none, opcode: 0x29, elementBytes: 4)),
        "vmovapd": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x28, w: true, elementBytes: 8),
                         store: .init(map: .map0F, pp: .p66, opcode: 0x29, w: true, elementBytes: 8)),
        "vmovdqa32": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x6F, elementBytes: 4),
                           store: .init(map: .map0F, pp: .p66, opcode: 0x7F, elementBytes: 4)),
        "vmovdqa64": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x6F, w: true, elementBytes: 8),
                           store: .init(map: .map0F, pp: .p66, opcode: 0x7F, w: true, elementBytes: 8)),
        "vmovdqu8": .init(load: .init(map: .map0F, pp: .f2, opcode: 0x6F, elementBytes: 1),
                          store: .init(map: .map0F, pp: .f2, opcode: 0x7F, elementBytes: 1)),
        "vmovdqu16": .init(load: .init(map: .map0F, pp: .f2, opcode: 0x6F, w: true, elementBytes: 2),
                           store: .init(map: .map0F, pp: .f2, opcode: 0x7F, w: true, elementBytes: 2)),
        "vmovdqu32": .init(load: .init(map: .map0F, pp: .f3, opcode: 0x6F, elementBytes: 4),
                           store: .init(map: .map0F, pp: .f3, opcode: 0x7F, elementBytes: 4)),
        "vmovdqu64": .init(load: .init(map: .map0F, pp: .f3, opcode: 0x6F, w: true, elementBytes: 8),
                           store: .init(map: .map0F, pp: .f3, opcode: 0x7F, w: true, elementBytes: 8)),
    ]

    private static let evexBroadcastOpcodes: [String: EVEXBroadcastOpcodeSpec] = [
        "vbroadcastss": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x18, elementBytes: 4), tupleScale: 4),
        "vbroadcastsd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x19, w: true, elementBytes: 8), tupleScale: 8, minVectorBytes: 32),
        "vpbroadcastb": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x78, elementBytes: 1), tupleScale: 1),
        "vpbroadcastw": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x79, elementBytes: 2), tupleScale: 2),
        "vpbroadcastd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x58, elementBytes: 4), tupleScale: 4),
        "vpbroadcastq": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x59, w: true, elementBytes: 8), tupleScale: 8),
    ]

    private static let evexGPRBroadcastOpcodes: [String: EVEXGPRBroadcastOpcodeSpec] = [
        "vpbroadcastb": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x7A, elementBytes: 4), sourceWidth: .dword, tupleScale: 4),
        "vpbroadcastw": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x7B, elementBytes: 4), sourceWidth: .dword, tupleScale: 4),
        "vpbroadcastd": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x7C, elementBytes: 4), sourceWidth: .dword, tupleScale: 4),
        "vpbroadcastq": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x7C, w: true, elementBytes: 8), sourceWidth: .qword, tupleScale: 8),
    ]

    private static let evexSubvectorBroadcastOpcodes: [String: EVEXBroadcastOpcodeSpec] = [
        "vbroadcastf32x4": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x1A, elementBytes: 16), tupleScale: 16, minVectorBytes: 32),
        "vbroadcastf64x2": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x1A, w: true, elementBytes: 16), tupleScale: 16, minVectorBytes: 32),
        "vbroadcastf32x8": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x1B, elementBytes: 32), tupleScale: 32, minVectorBytes: 64),
        "vbroadcastf64x4": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x1B, w: true, elementBytes: 32), tupleScale: 32, minVectorBytes: 64),
        "vbroadcasti32x4": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x5A, elementBytes: 16), tupleScale: 16, minVectorBytes: 32),
        "vbroadcasti64x2": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x5A, w: true, elementBytes: 16), tupleScale: 16, minVectorBytes: 32),
        "vbroadcasti32x8": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x5B, elementBytes: 32), tupleScale: 32, minVectorBytes: 64),
        "vbroadcasti64x4": .init(evex: .init(map: .map0F38, pp: .p66, opcode: 0x5B, w: true, elementBytes: 32), tupleScale: 32, minVectorBytes: 64),
    ]

    private static let vexBroadcastOpcodes: [String: VEXBroadcastOpcodeSpec] = [
        "vbroadcastss": .init(vex: .init(map: .map0F38, pp: .p66, opcode: 0x18)),
        "vbroadcastsd": .init(vex: .init(map: .map0F38, pp: .p66, opcode: 0x19), minVectorBytes: 32),
        "vpbroadcastb": .init(vex: .init(map: .map0F38, pp: .p66, opcode: 0x78)),
        "vpbroadcastw": .init(vex: .init(map: .map0F38, pp: .p66, opcode: 0x79)),
        "vpbroadcastd": .init(vex: .init(map: .map0F38, pp: .p66, opcode: 0x58)),
        "vpbroadcastq": .init(vex: .init(map: .map0F38, pp: .p66, opcode: 0x59)),
    ]

    private static let vexMoveOpcodes: [String: VEXMoveOpcodeSpec] = [
        "vmovups": .init(load: .init(map: .map0F, pp: .none, opcode: 0x10), store: .init(map: .map0F, pp: .none, opcode: 0x11)),
        "vmovupd": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x10), store: .init(map: .map0F, pp: .p66, opcode: 0x11)),
        "vmovaps": .init(load: .init(map: .map0F, pp: .none, opcode: 0x28), store: .init(map: .map0F, pp: .none, opcode: 0x29)),
        "vmovapd": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x28), store: .init(map: .map0F, pp: .p66, opcode: 0x29)),
        "vmovdqa": .init(load: .init(map: .map0F, pp: .p66, opcode: 0x6F), store: .init(map: .map0F, pp: .p66, opcode: 0x7F)),
        "vmovdqu": .init(load: .init(map: .map0F, pp: .f3, opcode: 0x6F), store: .init(map: .map0F, pp: .f3, opcode: 0x7F)),
    ]

    // MARK: - Models / numeric helpers

    private enum VectorWidth: Equatable {
        case xmm, ymm, zmm

        var registerPrefix: String {
            switch self {
            case .xmm: return "xmm"
            case .ymm: return "ymm"
            case .zmm: return "zmm"
            }
        }

        var byteCount: Int {
            switch self {
            case .xmm: return 16
            case .ymm: return 32
            case .zmm: return 64
            }
        }

        var evexLL: UInt8 {
            switch self {
            case .xmm: return 0
            case .ymm: return 1
            case .zmm: return 2
            }
        }
    }

    private enum VEXMap: UInt8 {
        case map0F = 0x01
        case map0F38 = 0x02
        case map0F3A = 0x03
    }

    private enum VEXPP: UInt8 {
        case none = 0x00
        case p66 = 0x01
        case f3 = 0x02
        case f2 = 0x03
    }

    private struct VEXOpcodeSpec {
        var map: VEXMap
        var pp: VEXPP
        var opcode: UInt8
        var w = false
        var commutative = false

        var canUseTwoByteVEX: Bool {
            map == .map0F && !w
        }
    }

    private struct EVEXOpcodeSpec {
        var map: VEXMap
        var pp: VEXPP
        var opcode: UInt8
        var w = false
        var elementBytes: Int
        var allowBroadcast = true
    }

    private enum EVEXScalarRoundingPolicy {
        case rounding
        case saeOnly

        func accepts(_ rounding: EVEXRounding) -> Bool {
            switch (self, rounding) {
            case (.rounding, .rnSae), (.rounding, .rdSae), (.rounding, .ruSae), (.rounding, .rzSae):
                return true
            case (.saeOnly, .sae):
                return true
            default:
                return false
            }
        }
    }

    private struct EVEXScalarOpcodeSpec {
        var evex: EVEXOpcodeSpec
        var roundingPolicy: EVEXScalarRoundingPolicy
    }

    private struct VEXMoveOpcodeSpec {
        var load: VEXOpcodeSpec
        var store: VEXOpcodeSpec
    }

    private struct EVEXMoveOpcodeSpec {
        var load: EVEXOpcodeSpec
        var store: EVEXOpcodeSpec
    }

    private struct EVEXBroadcastOpcodeSpec {
        var evex: EVEXOpcodeSpec
        var tupleScale: Int
        var minVectorBytes = 16
    }

    private struct PackedShiftImmediateOpcodeSpec {
        var vex: VEXOpcodeSpec?
        var evex: EVEXOpcodeSpec
        var group: Int
        var allowBroadcast = true
    }

    private struct VectorShuffleImmediateOpcodeSpec {
        var vex: VEXOpcodeSpec
        var evex: EVEXOpcodeSpec
    }

    private struct EVEXGPRBroadcastOpcodeSpec {
        var evex: EVEXOpcodeSpec
        var sourceWidth: Width
        var tupleScale: Int
        var minVectorBytes = 16
    }

    private struct VEXBroadcastOpcodeSpec {
        var vex: VEXOpcodeSpec
        var minVectorBytes = 16
    }

    private enum Width {
        case byte, word, dword, qword

        var suffix: String {
            switch self {
            case .byte: return "b"
            case .word: return "w"
            case .dword: return "l"
            case .qword: return "q"
            }
        }

        var byteCount: Int {
            switch self {
            case .byte: return 1
            case .word: return 2
            case .dword: return 4
            case .qword: return 8
            }
        }
    }

    private struct Register: Equatable {
        var name: String
        var index: Int
        var width: Width? = nil
        var highByte: Bool
        var vectorWidth: VectorWidth? = nil

        var low3: Int { index & 0x7 }

        var forceREXForByteOperand: Bool {
            width == .byte && !highByte && index >= 4
        }
    }

    private struct Memory {
        var text: String
        var displacement: Int64
        var base: Register?
        var index: Register?
        var scale: Int
        var ripRelative: Bool

        var displacementFits32: Bool {
            displacement >= Int64(Int32.min) && displacement <= Int64(Int32.max)
        }

        var isBareDisplacement: Bool {
            base == nil && index == nil && !ripRelative && !text.contains("(") && !text.contains(")")
        }
    }

    private struct Immediate {
        var text: String
        var negative: Bool
        var magnitude: UInt64
        var bits: UInt64

        func fitsSigned(bits bitCount: Int) -> Bool {
            if negative {
                let limit = UInt64(1) << UInt64(bitCount - 1)
                return magnitude <= limit
            }
            let limit = (UInt64(1) << UInt64(bitCount - 1)) - 1
            return magnitude <= limit
        }

        func fitsUnsigned(bits bitCount: Int) -> Bool {
            if negative { return false }
            if bitCount == 64 { return true }
            return magnitude <= ((UInt64(1) << UInt64(bitCount)) - 1)
        }

        func byteValue(width: Int) throws -> UInt8 {
            let bitCount = width * 8
            let ok = negative ? fitsSigned(bits: bitCount) : fitsUnsigned(bits: bitCount)
            guard ok else { throw Diagnostic.immediateOutOfRange(text) }
            return UInt8(bits & 0xff)
        }

        func signedByte() throws -> UInt8 {
            guard fitsSigned(bits: 8) else { throw Diagnostic.immediateOutOfRange(text) }
            return UInt8(bits & 0xff)
        }

        func littleEndianBytes(width: Int, context: String) throws -> [UInt8] {
            let bitCount = width * 8
            let ok = negative ? fitsSigned(bits: bitCount) : fitsUnsigned(bits: bitCount)
            guard ok else { throw Diagnostic.immediateOutOfRange("\(context) \(text)") }
            return bitsLittleEndianBytes(width: width)
        }

        func signedLittleEndianBytes(width: Int) -> [UInt8] {
            bitsLittleEndianBytes(width: width)
        }

        func bitsLittleEndianBytes(width: Int) -> [UInt8] {
            (0..<width).map { UInt8((bits >> UInt64($0 * 8)) & 0xff) }
        }

        func immediateBytesForOperand(width: Width, immWidth: Int, signedExtended: Bool, context: String) throws -> [UInt8] {
            if signedExtended {
                guard fitsSigned(bits: immWidth * 8) else {
                    throw Diagnostic.immediateOutOfRange("\(context) \(text)")
                }
                return bitsLittleEndianBytes(width: immWidth)
            }
            if width == .qword {
                guard fitsSigned(bits: immWidth * 8) else {
                    throw Diagnostic.immediateOutOfRange("\(context) \(text)")
                }
                return bitsLittleEndianBytes(width: immWidth)
            }
            return try littleEndianBytes(width: immWidth, context: context)
        }
    }

    private struct EVEXDecoration: Equatable {
        var mask: Int?
        var zeroing = false
        var broadcast: Int?

        var isEmpty: Bool {
            mask == nil && !zeroing && broadcast == nil
        }

        var isNoOpZeroingOnly: Bool {
            mask == nil && zeroing && broadcast == nil
        }
    }

    private enum EVEXRounding: Equatable {
        case rnSae
        case rdSae
        case ruSae
        case rzSae
        case sae

        init?(text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
            let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            switch inner {
            case "rn-sae": self = .rnSae
            case "rd-sae": self = .rdSae
            case "ru-sae": self = .ruSae
            case "rz-sae": self = .rzSae
            case "sae": self = .sae
            default: return nil
            }
        }

        var text: String {
            switch self {
            case .rnSae: return "{rn-sae}"
            case .rdSae: return "{rd-sae}"
            case .ruSae: return "{ru-sae}"
            case .rzSae: return "{rz-sae}"
            case .sae: return "{sae}"
            }
        }

        var evexLL: UInt8 {
            switch self {
            case .rnSae, .sae: return 0
            case .rdSae: return 1
            case .ruSae: return 2
            case .rzSae: return 3
            }
        }
    }

    private enum Operand {
        case register(Register)
        case immediate(Immediate)
        case memory(Memory)
        case evexRounding(EVEXRounding)
        indirect case indirect(Operand, text: String)
        indirect case decorated(Operand, EVEXDecoration)

        var text: String {
            switch self {
            case .register(let reg): return "%\(reg.name)"
            case .immediate(let imm): return imm.text
            case .memory(let mem): return mem.text
            case .evexRounding(let rounding): return rounding.text
            case .indirect(_, let text): return text
            case .decorated(let operand, let decoration):
                var suffix = ""
                if let broadcast = decoration.broadcast {
                    suffix += "{1to\(broadcast)}"
                }
                if let mask = decoration.mask {
                    suffix += " {%k\(mask)}"
                }
                if decoration.zeroing {
                    suffix += " {z}"
                }
                return operand.text + suffix
            }
        }

        var isImmediate: Bool {
            if case .immediate = self { return true }
            return false
        }
    }

    private enum RMOperand {
        case register(Register)
        case memory(Memory)
    }

    private struct REX {
        var w = false
        var r = false
        var x = false
        var b = false
        var force = false

        var needsEmission: Bool { w || r || x || b || force }

        var byte: UInt8? {
            guard needsEmission else { return nil }
            return 0x40
                | (w ? 0x08 : 0)
                | (r ? 0x04 : 0)
                | (x ? 0x02 : 0)
                | (b ? 0x01 : 0)
        }
    }

    private static func int32Bytes(_ value: Int64) -> [UInt8] {
        let bits = UInt32(bitPattern: Int32(value))
        return [
            UInt8(bits & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff),
        ]
    }

    private static func rel32Bytes(_ value: Int64, operandText: String) throws -> [UInt8] {
        let bits: UInt32
        if value < 0 {
            guard value >= Int64(Int32.min) else {
                throw Diagnostic.offsetOutOfRange(operandText)
            }
            bits = UInt32(bitPattern: Int32(value))
        } else {
            guard value <= Int64(UInt32.max) else {
                throw Diagnostic.offsetOutOfRange(operandText)
            }
            bits = UInt32(value)
        }
        return [
            UInt8(bits & 0xff),
            UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff),
            UInt8((bits >> 24) & 0xff),
        ]
    }

    private static func directBranchDisplacement(_ operand: Operand) -> Int64? {
        guard case .memory(let memory) = operand, memory.isBareDisplacement else {
            return nil
        }
        return memory.displacement
    }

    private static func fitsInt8(_ value: Int64) -> Bool {
        value >= Int64(Int8.min) && value <= Int64(Int8.max)
    }

    private static func compressedDisp8(_ value: Int64, scale: Int) -> Int8? {
        guard scale > 0 else { return nil }
        guard value % Int64(scale) == 0 else { return nil }
        let scaled = value / Int64(scale)
        guard fitsInt8(scaled) else { return nil }
        return Int8(scaled)
    }

    private static func evexTupleScale(vectorWidth: VectorWidth, elementBytes: Int, broadcast: Bool) -> Int {
        if broadcast && elementBytes >= 4 { return elementBytes }
        return vectorWidth.byteCount
    }

    private static func vexPrefix(
        map: VEXMap,
        pp: VEXPP,
        w: Bool,
        vectorLength256: Bool,
        vvvv: Int,
        r: Bool,
        x: Bool,
        b: Bool
    ) -> [UInt8] {
        let encodedV = UInt8((vvvv ^ 0x0F) & 0x0F) << 3
        let l = vectorLength256 ? UInt8(0x04) : UInt8(0)
        if map == .map0F, !w, !x, !b {
            let rBit = r ? UInt8(0) : UInt8(0x80)
            return [0xC5, rBit | encodedV | l | pp.rawValue]
        }

        let rxBMap = (r ? UInt8(0) : UInt8(0x80))
            | (x ? UInt8(0) : UInt8(0x40))
            | (b ? UInt8(0) : UInt8(0x20))
            | map.rawValue
        let wvlpp = (w ? UInt8(0x80) : UInt8(0)) | encodedV | l | pp.rawValue
        return [0xC4, rxBMap, wvlpp]
    }

    private static func evexPrefix(
        map: VEXMap,
        pp: VEXPP,
        w: Bool,
        vectorWidth: VectorWidth,
        vvvvv: Int,
        r: Bool,
        x: Bool,
        b: Bool,
        rPrime: Bool,
        mask: Int,
        zeroing: Bool,
        broadcast: Bool,
        rounding: EVEXRounding? = nil
    ) -> [UInt8] {
        let p0 = (r ? UInt8(0) : UInt8(0x80))
            | (x ? UInt8(0) : UInt8(0x40))
            | (b ? UInt8(0) : UInt8(0x20))
            | (rPrime ? UInt8(0) : UInt8(0x10))
            | map.rawValue
        let encodedVLow = UInt8(((vvvvv & 0x0F) ^ 0x0F) << 3)
        let p1 = (w ? UInt8(0x80) : UInt8(0)) | encodedVLow | 0x04 | pp.rawValue
        let encodedVPrime = (vvvvv & 0x10) != 0 ? UInt8(0) : UInt8(0x08)
        let ll = rounding?.evexLL ?? vectorWidth.evexLL
        let p2 = (zeroing ? UInt8(0x80) : UInt8(0))
            | (ll << 5)
            | ((broadcast || rounding != nil) ? UInt8(0x10) : UInt8(0))
            | encodedVPrime
            | UInt8(mask & 0x07)
        return [0x62, p0, p1, p2]
    }
}
