import Foundation
@testable import MacScope

/// Concrete A64 machine state for one oracle fixture: the oracle's modeled state and nothing else.
struct A64MachineState: Equatable {
    struct V128: Equatable { var low: UInt64; var high: UInt64 }

    static let defaultPC: UInt64 = 0x40_0100
    static let defaultSP: UInt64 = 0x50_0200

    var x = [UInt64](repeating: 0, count: 31)
    var sp: UInt64 = defaultSP
    var pc: UInt64 = defaultPC
    /// NZCV as bits 3...0 = N, Z, C, V.
    var nzcv: UInt8 = 0
    var fpcr: UInt32 = 0
    var fpsr: UInt32 = 0
    var v = [V128](repeating: V128(low: 0, high: 0), count: 32)
    /// Sparse little-endian memory; absent bytes are zero (the oracle maps its data page zeroed).
    var memory: [UInt64: UInt8] = [:]

    var n: Bool { nzcv & 0b1000 != 0 }
    var z: Bool { nzcv & 0b0100 != 0 }
    var c: Bool { nzcv & 0b0010 != 0 }
    var flagV: Bool { nzcv & 0b0001 != 0 }

    static func nzcv(_ text: String) -> UInt8? {
        guard text.count == 4, text.allSatisfy({ $0 == "0" || $0 == "1" }) else { return nil }
        return UInt8(text, radix: 2)
    }

    /// The seeded input state, per the oracle's `defaults`.
    init(seeding inputs: A64OracleVector.State) throws {
        for (name, text) in inputs.gpr ?? [:] {
            guard let index = Self.gprIndex(name), let value = A64OracleHex.uint64(text) else {
                throw MacIRConcreteEvaluator.Failure.harness("bad GPR input \(name)=\(text)")
            }
            x[index] = value
        }
        if let text = inputs.sp { sp = try Self.require(A64OracleHex.uint64(text), "SP") }
        if let text = inputs.pc { pc = try Self.require(A64OracleHex.uint64(text), "PC") }
        if let text = inputs.nzcv { nzcv = try Self.require(Self.nzcv(text), "NZCV") }
        if let text = inputs.fpcr { fpcr = UInt32(truncatingIfNeeded: try Self.require(A64OracleHex.uint64(text), "FPCR")) }
        if let text = inputs.fpsr { fpsr = UInt32(truncatingIfNeeded: try Self.require(A64OracleHex.uint64(text), "FPSR")) }
        for (name, text) in inputs.vectors ?? [:] {
            guard let index = Self.vectorIndex(name), let value = A64OracleHex.uint128(text) else {
                throw MacIRConcreteEvaluator.Failure.harness("bad V input \(name)=\(text)")
            }
            v[index] = V128(low: value.low, high: value.high)
        }
        for range in inputs.memory ?? [] {
            guard let base = A64OracleHex.uint64(range.address), let bytes = A64OracleHex.bytes(range.bytes) else {
                throw MacIRConcreteEvaluator.Failure.harness("bad memory input at \(range.address)")
            }
            for (offset, byte) in bytes.enumerated() where byte != 0 { memory[base &+ UInt64(offset)] = byte }
        }
    }

    private static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw MacIRConcreteEvaluator.Failure.harness("bad \(what) input") }
        return value
    }

    static func gprIndex(_ name: String) -> Int? {
        guard name.first == "X" || name.first == "x", let index = Int(name.dropFirst()), (0...30).contains(index) else { return nil }
        return index
    }

    static func vectorIndex(_ name: String) -> Int? {
        guard name.first == "V" || name.first == "v", let index = Int(name.dropFirst()), (0...31).contains(index) else { return nil }
        return index
    }

    func byte(at address: UInt64) -> UInt8 { memory[address] ?? 0 }

    mutating func setByte(_ value: UInt8, at address: UInt64) {
        if value == 0 { memory.removeValue(forKey: address) } else { memory[address] = value }
    }
}

/// Evaluates lifted MacIR concretely over an `A64MachineState`, under one explicit reading of
/// MacIR: the C the printer renders. Integer values are two's-complement C integers of their
/// register width (`xN` → `int64_t`, `wN` → `int32_t`, bound arguments → their declared type),
/// immediates are `int64_t`, and `>>`, `/` and the relational operators follow the operand types,
/// so an unsigned A64 operation lifted without an unsigned cast evaluates as signed. Loads and
/// stores use the explicit memory-access descriptor, or their legacy carrier width. C undefined
/// behavior (division by zero, out-of-range shifts or FP→integer conversions) is reported, not
/// guessed. `alternateSignedness` flips every signed/unsigned decision, which lets the harness
/// tell "wrong" from "faithful but signedness-ambiguous".
struct MacIRConcreteEvaluator {
    enum Failure: Error, Equatable {
        /// The lifter emitted `.unknown` (or an `unknown` value) the result depends on.
        case unlifted(String)
        /// Valid MacIR this evaluator does not model (flags-only, vector lanes, other FPCR…).
        case unsupported(String)
        /// The C the IR denotes is undefined for this input (A64 itself is defined).
        case undefined(String)
        /// The fixture itself could not be read.
        case harness(String)
    }

    enum Kind: Equatable { case signed, unsigned, float }

    /// One C value: up to 64 significant bits plus the high half of a 128-bit vector value.
    struct Scalar: Equatable {
        var bits: UInt64
        var width: Int
        var kind: Kind
        var high: UInt64 = 0

        static func int(_ bits: UInt64, width: Int, signed: Bool) -> Scalar {
            Scalar(bits: bits & mask(width), width: width, kind: signed ? .signed : .unsigned)
        }

        var signedValue: Int64 {
            Int64(bitPattern: width >= 64 ? bits : (bits & Scalar.mask(width)) ^ Scalar.signBit(width) &- Scalar.signBit(width))
        }

        static func mask(_ width: Int) -> UInt64 { width >= 64 ? .max : (UInt64(1) << UInt64(width)) - 1 }
        static func signBit(_ width: Int) -> UInt64 { UInt64(1) << UInt64(max(1, min(width, 64)) - 1) }
    }

    let function: MacIRFunction
    var state: A64MachineState
    let entrySP: UInt64
    /// Raw entry values, not interpreted Scalars: callers may set alternateSignedness after init.
    /// Only formal arguments read this snapshot; architectural/SSA/memory reads stay live.
    private let argumentEntryState: A64MachineState
    /// Split SIMD cells are 64-bit bit carriers even when named vN/vhN.
    /// Only persisted SSA definitions establish this meaning; ordinary vector
    /// registers keep their existing full-width behavior.
    private let ssaBitHalfCells: [MacIRValue: Int]
    /// Architectural writes persisted as SSA constants have no rendered row.
    /// Their instruction origin determines when the physical state changes.
    private let ssaZeroedHighCells: [UInt64: Set<Int>]
    var alternateSignedness = false
    /// Overrides the natural access width of loads and stores, as (bytes, sign-extend).
    var accessOverride: (bytes: Int, signExtend: Bool)?

    private var currentMemoryAccess: MacIRMemoryAccess?
    private var currentScalarFP: MacIRScalarFP?

    private(set) var ssa: [MacIRValue: Scalar] = [:]
    private(set) var writtenGPRs: Set<Int> = []
    private(set) var writtenVectors: Set<Int> = []
    private(set) var usedFloatingPoint = false
    private(set) var nextPC: UInt64?

    init(function: MacIRFunction, state: A64MachineState) {
        self.function = function
        self.state = state
        self.entrySP = state.sp
        self.argumentEntryState = state
        var bitHalfCells: [MacIRValue: Int] = [:]
        var zeroedHighCells: [UInt64: Set<Int>] = [:]
        if let info = function.ssaInfo {
            for (id, value) in info.values {
                let definition = info.plan.definitions[info.plan.canonicalID(id)]
                if (64..<96).contains(definition.cell), value == .immediate(0),
                   case let .instruction(address) = definition.origin {
                    zeroedHighCells[address, default: []].insert(definition.cell)
                }
                guard case .register = value else { continue }
                if (32..<96).contains(definition.cell), definition.view == .bits {
                    bitHalfCells[value] = definition.cell
                }
            }
        }
        self.ssaBitHalfCells = bitHalfCells
        self.ssaZeroedHighCells = zeroedHighCells
    }

    // MARK: Running

    mutating func run(_ instructions: [MacIRInstruction]) throws {
        guard !function.phis.contains(where: { phi in
            phi.incoming.contains { $0.predecessor == .functionEntry }
        }) else {
            throw Failure.unsupported("virtual function-entry phi execution is not modeled")
        }
        try validateNEONScalarIntegerComparison(instructions)
        let channelTableComposition = try validateNEONChannelTableComposition(instructions)
        try validateNEONScalarVariableShift(instructions)
        if channelTableComposition == nil { try validateNEONFourChannelMemory(instructions) }
        try validateNEONIndexedMixedByteDotProduct(instructions)
        try validateNEONMixedByteDotProduct(instructions)
        try validateNEONFullWidthShift(instructions)
        try validateNEONSelectedWideningAccumulate(instructions)
        try validateNEONIndexedByteDotProduct(instructions)
        let roundedNarrowBuffer = try validateNEONRoundedNarrowBuffer(instructions)
        let rgbLogicalBuffer = try validateNEONRGBLogicalBuffer(instructions)
        try validateNEONBytePolynomialMultiply(instructions)
        try validateNEONSelectedUnsignedMultiply(instructions)
        try validateNEONByteDotProduct(instructions)
        try validateNEONSelectedSignedMultiply(instructions)
        if roundedNarrowBuffer == nil { try validateNEONRoundedShift(instructions) }
        try validateNEONContiguousRegisterPost(instructions)
        if rgbLogicalBuffer == nil { try validateNEONThreeChannelMemory(instructions) }
        let productPairwiseBuffer = try validateNEONProductPairwiseBuffer(instructions)
        let groupWidenNarrow = try validateNEONGroupWidenNarrow(instructions)
        if productPairwiseBuffer == nil { try validateNEONSignedLongMultiply(instructions) }
        try validateNEONWideningAddSubtract(instructions)
        if groupWidenNarrow == nil {
            try validateNEONContiguousGroup(instructions)
            if roundedNarrowBuffer == nil { try validateNEONShiftNarrow(instructions) }
        }
        try validateNEONPredicate(instructions)
        if groupWidenNarrow == nil && productPairwiseBuffer == nil {
            try validateNEONWideningPairwise(instructions)
        }
        try validateNEONMagnitudeClamp(instructions)
        try validateNEONPairwise(instructions)
        let laneBroadcastBuffer = try validateNEONLaneBroadcastBuffer(instructions)
        if laneBroadcastBuffer == nil {
            try validateNEONLaneMemory(instructions)
            try validateNEONBroadcastMemory(instructions)
        }
        let conversionBuffer = try validateNEONConversionBuffer(instructions)
        try validateNEONBitCount(instructions)
        if !conversionBuffer { try validateNEONOrderConversion(instructions) }
        try validateNEONInterleavedMemory(instructions)
        try validateNEONStructureLaneMemory(instructions)
        if !conversionBuffer { try validateNEONIndexedMemory(instructions) }
        for instruction in instructions { try validateNEONPackingMetadata(instruction) }
        try validateNEONMixedBuffer(instructions)
        for instruction in instructions { try validateNEONReductionMetadata(instruction) }
        for instruction in instructions { try validateNEONImmediateMetadata(instruction) }
        for instruction in instructions { try validateNEONMultiplyMetadata(instruction) }
        for instruction in instructions { try validateNEONShiftInsertMetadata(instruction) }
        var nextBufferMemorySequence = 0
        var consumedUntil = 0
        for (position, instruction) in instructions.enumerated() {
            if position < consumedUntil { continue }
            state.pc = instruction.source.address
            nextPC = nil
            currentMemoryAccess = instruction.memoryAccess
            currentScalarFP = instruction.scalarFP
            if let comparison = instruction.neonScalarIntegerComparison {
                try executeNEONScalarIntegerComparison(comparison, operation: instruction.operation)
            } else if let marker = instruction.neonScalarShiftCompilerComposition, marker.kind == .insert {
                try executeNEONScalarShiftCompilerComposition(marker, instruction: instruction)
            } else if let step = instruction.neonWiderMultiChannelLane {
                try executeNEONWiderMultiChannelLane(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let step = instruction.neonWiderMultiChannelReplicate {
                try executeNEONWiderMultiChannelReplicate(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let shift = instruction.neonScalarVariableShift {
                try executeNEONScalarVariableShift(shift, operation: instruction.operation)
            } else if let step = instruction.neonWiderChannelMemory {
                try executeNEONWiderChannelMemory(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let step = instruction.neonMultiChannelLane {
                try executeNEONMultiChannelLane(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let step = instruction.neonMultiChannelReplicate {
                try executeNEONMultiChannelReplicate(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let step = instruction.neonFourChannelMemory {
                try executeNEONFourChannelMemory(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let matrix = instruction.neonByteMatrixAccumulate {
                try executeNEONByteMatrixAccumulate(matrix, operation: instruction.operation)
            } else if let indexedMixed = instruction.neonIndexedMixedByteDotProduct {
                try executeNEONIndexedMixedByteDotProduct(indexedMixed, operation: instruction.operation)
            } else if let mixedDot = instruction.neonMixedByteDotProduct {
                try executeNEONMixedByteDotProduct(mixedDot, operation: instruction.operation)
            } else if let shift = instruction.neonFullWidthShift {
                try executeNEONFullWidthShift(shift, operation: instruction.operation)
            } else if let selectedAccumulate = instruction.neonSelectedWideningAccumulate {
                try executeNEONSelectedWideningAccumulate(selectedAccumulate, operation: instruction.operation)
            } else if let indexedDot = instruction.neonIndexedByteDotProduct {
                try executeNEONIndexedByteDotProduct(indexedDot, operation: instruction.operation)
            } else if let polynomial = instruction.neonBytePolynomialMultiply {
                try executeNEONBytePolynomialMultiply(polynomial, operation: instruction.operation)
            } else if let selected = instruction.neonSelectedUnsignedMultiply {
                try executeNEONSelectedUnsignedMultiply(selected, operation: instruction.operation)
            } else if let dot = instruction.neonByteDotProduct {
                try executeNEONByteDotProduct(dot, operation: instruction.operation)
            } else if let selected = instruction.neonSelectedSignedMultiply {
                try executeNEONSelectedSignedMultiply(selected, operation: instruction.operation)
            } else if let rounded = instruction.neonRoundedShift {
                try executeNEONRoundedShift(rounded, operation: instruction.operation)
            } else if let step = instruction.neonThreeChannelMemory {
                try executeNEONThreeChannelMemory(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let product = instruction.neonSignedLongMultiply {
                try executeNEONSignedLongMultiply(product, operation: instruction.operation)
            } else if let widening = instruction.neonWideningAddSubtract {
                try executeNEONWideningAddSubtract(widening, operation: instruction.operation)
            } else if let step = instruction.neonContiguousGroup {
                try executeNEONContiguousGroup(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let narrow = instruction.neonShiftNarrow {
                try executeNEONShiftNarrow(narrow, operation: instruction.operation)
            } else if let predicate = instruction.neonPredicate {
                try executeNEONPredicate(predicate, operation: instruction.operation)
            } else if let widening = instruction.neonWideningPairwise {
                try executeNEONWideningPairwise(widening, operation: instruction.operation)
            } else if let magnitude = instruction.neonMagnitudeClamp {
                try executeNEONMagnitudeClamp(magnitude, operation: instruction.operation)
            } else if let pairwise = instruction.neonPairwise {
                try executeNEONPairwise(pairwise, operation: instruction.operation)
            } else if let step = instruction.neonLaneMemory {
                try executeNEONLaneMemory(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let step = instruction.neonBroadcastMemory {
                guard step.frame.sequence == nextBufferMemorySequence else { throw Failure.unsupported("broadcast transfer order") }
                try executeNEONBroadcastMemory(step.frame)
                nextBufferMemorySequence += 1
                consumedUntil = position + step.frame.effectCount
            } else if let count = instruction.neonBitCount {
                try executeNEONBitCount(count, operation: instruction.operation)
            } else if let conversion = instruction.neonOrderConversion {
                try executeNEONOrderConversion(conversion, operation: instruction.operation)
            } else if let step = instruction.neonInterleavedMemory {
                try executeNEONInterleavedMemory(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let step = instruction.neonStructureLaneMemory {
                try executeNEONStructureLaneMemory(step.frame)
                consumedUntil = position + step.frame.effectCount
            } else if let indexed = instruction.neonIndexedMemory {
                guard indexed.sequence == nextBufferMemorySequence else { throw Failure.unsupported("NEON indexed effect order") }
                try executeNEONIndexedMemory(indexed, operation: instruction.operation, memoryAccess: instruction.memoryAccess)
                nextBufferMemorySequence += 1
            } else if let step = instruction.neonBufferSequence {
                nextBufferMemorySequence += try executeNEONBufferSequence(instructions, start: position, nextMemorySequence: nextBufferMemorySequence)
                consumedUntil = position + step.sequence.effectCount
            } else if let bitView = instruction.neonBitView {
                try executeNEONBitView(bitView, operation: instruction.operation)
            } else if let memory = instruction.neonBufferMemory {
                guard memory.sequence == nextBufferMemorySequence else { throw Failure.unsupported("NEON buffer effect order") }
                try executeNEONBufferMemory(memory, operation: instruction.operation, memoryAccess: instruction.memoryAccess)
                nextBufferMemorySequence += 1
            } else if let packing = instruction.neonPacking {
                try executeNEONPacking(packing, operation: instruction.operation)
            } else if let reduction = instruction.neonReduction {
                try executeNEONReduction(reduction, operation: instruction.operation)
            } else if let immediate = instruction.neonImmediate {
                try executeNEONImmediate(immediate, operation: instruction.operation)
            } else if let multiply = instruction.neonMultiply {
                try executeNEONMultiply(multiply, operation: instruction.operation)
            } else if let shiftInsert = instruction.neonShiftInsert {
                try executeNEONShiftInsert(shiftInsert, operation: instruction.operation)
            } else if let comparison = instruction.neonComparison {
                try executeNEONComparison(comparison, operation: instruction.operation)
            } else if let modular = instruction.neonModular {
                try executeNEONModular(modular, operation: instruction.operation)
            } else if let table = instruction.neonTableLookup {
                try executeNEONTableLookup(table, operation: instruction.operation)
            } else if let extract = instruction.neonExtract {
                try executeNEONExtract(extract, operation: instruction.operation)
            } else if let logical = instruction.neonLogical {
                try executeNEONLogical(logical, operation: instruction.operation)
            } else if let lane = instruction.neonLaneOp {
                try executeNEONLaneOp(lane, operation: instruction.operation)
            } else if let permutation = instruction.neonPermutation {
                try executeNEONPermutation(permutation, operation: instruction.operation)
            } else {
                try execute(instruction.operation)
            }
            applySSAImplicitWrites(at: instruction.source.address)
            if case .returnValue = instruction.operation, let target = instruction.returnTarget {
                nextPC = try evaluate(target).bits
            }
            state.pc = nextPC ?? instruction.source.address &+ 4
        }
        if usedFloatingPoint, state.fpcr != 0 {
            throw Failure.unsupported("non-default FPCR \(String(state.fpcr, radix: 16))")
        }
    }

    /// Execute a bounded scalar function in PC order. The ordinary oracle runner
    /// intentionally walks its supplied instruction list once; branch and loop
    /// fixtures need this separate path so a taken edge cannot execute the
    /// untaken textual arm. The builder still owns every value and branch target.
    mutating func runScalarCFG(_ instructions: [MacIRInstruction], maximumSteps: Int = 64) throws {
        guard !function.phis.contains(where: { phi in
            phi.incoming.contains { $0.predecessor == .functionEntry }
        }) else {
            throw Failure.unsupported("virtual function-entry phi execution is not modeled")
        }
        guard (1...4_096).contains(maximumSteps), let entry = instructions.first else {
            throw Failure.harness("invalid scalar CFG step bound or empty function")
        }
        let byAddress = Dictionary(grouping: instructions.indices, by: { instructions[$0].source.address })
        guard byAddress.count == instructions.count else {
            throw Failure.harness("duplicate scalar CFG instruction address")
        }
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        guard !cfg.hasUnresolvedTargets else {
            throw Failure.harness("unresolved scalar CFG target")
        }
        let blockByRow = Dictionary(uniqueKeysWithValues: cfg.blocks.flatMap { block in
            block.instructionRange.map { ($0, block.index) }
        })
        let phisByAddress = Dictionary(grouping: function.phis, by: \.blockAddress)

        var pc = entry.source.address
        var previousBlock: Int?
        for _ in 0..<maximumSteps {
            guard let index = byAddress[pc]?.first else {
                throw Failure.harness("scalar CFG left the decoded function at 0x\(String(pc, radix: 16))")
            }
            let instruction = instructions[index]
            guard let blockIndex = blockByRow[index] else {
                throw Failure.harness("unmapped scalar CFG row")
            }
            if index == cfg.blocks[blockIndex].startIndex,
               let predecessor = previousBlock,
               let phis = phisByAddress[pc] {
                let predecessorAddress = instructions[cfg.blocks[predecessor].endIndex - 1].source.address
                let selected = try phis.map { phi -> (MacIRValue, Scalar) in
                    guard let incoming = phi.incoming.first(where: {
                        $0.machineAddress == predecessorAddress
                    }) else {
                        throw Failure.harness("missing scalar phi predecessor")
                    }
                    return (phi.destination, try evaluate(incoming.value))
                }
                for (destination, value) in selected { try write(destination, value) }
            }
            switch instruction.operation {
            case .assign, .binary, .conditionalBranch, .returnValue, .select, .intrinsic:
                break
            default:
                throw Failure.unsupported("non-scalar CFG operation at 0x\(String(pc, radix: 16))")
            }
            state.pc = pc
            nextPC = nil
            currentMemoryAccess = instruction.memoryAccess
            currentScalarFP = instruction.scalarFP
            try execute(instruction.operation)
            applySSAImplicitWrites(at: instruction.source.address)
            if case .returnValue = instruction.operation {
                state.pc = nextPC ?? state.x[30]
                return
            }
            previousBlock = blockIndex
            pc = nextPC ?? (pc &+ 4)
        }
        throw Failure.harness("scalar CFG exceeded \(maximumSteps) instruction steps")
    }

    /// Test-only CFG consumer for the owned Q load/EOR/store loop. A post-index
    /// transfer is one architectural row with two ordered MacIR effects. Keep
    /// those effects together when constructing the CFG and when executing it.
    mutating func runOwnedVectorLoopCFG(_ instructions: [MacIRInstruction], maximumSteps: Int = 128) throws {
        guard !function.phis.contains(where: { phi in
            phi.incoming.contains { $0.predecessor == .functionEntry }
        }) else {
            throw Failure.unsupported("virtual function-entry phi execution is not modeled")
        }
        guard (1...4_096).contains(maximumSteps), let entry = instructions.first else {
            throw Failure.harness("invalid vector CFG step bound or empty function")
        }
        let groups = Dictionary(grouping: instructions.indices, by: { instructions[$0].source.address })
        let rows = groups.values.compactMap { indices -> MacIRInstruction? in
            guard let first = indices.min() else { return nil }
            return instructions[first]
        }.sorted { $0.source.address < $1.source.address }
        guard rows.count == groups.count, rows.count == 8 else {
            throw Failure.harness("owned vector CFG must contain eight decoded rows")
        }
        let cfg = CFGBuilder.buildCFG(instructions: rows)
        guard !cfg.hasUnresolvedTargets else { throw Failure.harness("unresolved vector CFG target") }
        let rowByAddress = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.source.address, $0.offset) })
        let blockByRow = Dictionary(uniqueKeysWithValues: cfg.blocks.flatMap { block in
            block.instructionRange.map { ($0, block.index) }
        })
        let phisByAddress = Dictionary(grouping: function.phis, by: \.blockAddress)
        var pc = entry.source.address
        var previousBlock: Int?
        var nextMemorySequence = 0
        for _ in 0..<maximumSteps {
            guard let rowIndex = rowByAddress[pc], let indices = groups[pc]?.sorted(),
                  let first = indices.first, let blockIndex = blockByRow[rowIndex] else {
                throw Failure.harness("vector CFG left decoded function at 0x\(String(pc, radix: 16))")
            }
            let instruction = instructions[first]
            if rowIndex == cfg.blocks[blockIndex].startIndex,
               let predecessor = previousBlock,
               let phis = phisByAddress[pc] {
                let predecessorAddress = rows[cfg.blocks[predecessor].endIndex - 1].source.address
                let selected = try phis.map { phi -> (MacIRValue, Scalar) in
                    guard let incoming = phi.incoming.first(where: { $0.machineAddress == predecessorAddress }) else {
                        throw Failure.harness("missing vector CFG phi predecessor")
                    }
                    return (phi.destination, try evaluate(incoming.value))
                }
                for (destination, value) in selected { try write(destination, value) }
            }
            state.pc = pc
            nextPC = nil
            currentMemoryAccess = instruction.memoryAccess
            currentScalarFP = instruction.scalarFP
            if let step = instruction.neonBufferSequence {
                guard step.ordinal == 0, indices.count == step.sequence.effectCount,
                      indices == Array(first..<(first + step.sequence.effectCount)) else {
                    throw Failure.unsupported("vector CFG sequence effects are not contiguous")
                }
                nextMemorySequence += try executeNEONBufferSequence(
                    instructions, start: first, nextMemorySequence: nextMemorySequence)
            } else if let logical = instruction.neonLogical {
                guard indices.count == 1 else { throw Failure.unsupported("duplicate vector logical row") }
                try executeNEONLogical(logical, operation: instruction.operation)
            } else if let lane = instruction.neonLaneOp {
                guard indices.count == 1 else { throw Failure.unsupported("duplicate vector lane row") }
                try executeNEONLaneOp(lane, operation: instruction.operation)
            } else {
                guard indices.count == 1 else { throw Failure.unsupported("duplicate scalar vector-CFG row") }
                switch instruction.operation {
                case .assign, .binary, .conditionalBranch, .returnValue, .select, .intrinsic:
                    try execute(instruction.operation)
                default:
                    throw Failure.unsupported("unmodeled vector CFG operation at 0x\(String(pc, radix: 16))")
                }
            }
            applySSAImplicitWrites(at: instruction.source.address)
            if case .returnValue = instruction.operation {
                state.pc = nextPC ?? state.x[30]
                return
            }
            previousBlock = blockIndex
            let following = nextPC ?? (pc &+ 4)
            if following <= pc { nextMemorySequence = 0 }
            pc = following
        }
        throw Failure.harness("vector CFG exceeded \(maximumSteps) instruction steps")
    }

    private mutating func applySSAImplicitWrites(at address: UInt64) {
        for cell in ssaZeroedHighCells[address] ?? [] {
            let index = cell - 64
            state.v[index].high = 0
            writtenVectors.insert(index)
        }
    }

    private mutating func execute(_ operation: MacIROperation) throws {
        switch operation {
        case let .assign(destination, source):
            try write(destination, try evaluate(source))
        case let .binary(destination, op, left, right):
            try write(destination, try binary(op, try evaluate(left), try evaluate(right)))
        case let .load(destination, address):
            try write(destination, try load(into: destination, at: try address64(address)))
        case let .store(source, address):
            try store(try evaluate(source), at: try address64(address), sourceValue: source)
        case let .loadWriteback(destination, baseDestination, baseSource, delta, preIndex):
            let base = try evaluate(baseSource).bits
            let updated = base &+ UInt64(bitPattern: delta)
            let loaded = try load(into: destination, at: preIndex ? updated : base)
            try write(destination, loaded)
            try write(baseDestination, .int(updated, width: 64, signed: true))
        case let .storeWriteback(source, baseDestination, baseSource, delta, preIndex):
            let base = try evaluate(baseSource).bits
            let updated = base &+ UInt64(bitPattern: delta)
            try store(try evaluate(source), at: preIndex ? updated : base, sourceValue: source)
            try write(baseDestination, .int(updated, width: 64, signed: true))
        case let .stackSlotRead(destination, _, value):
            try write(destination, try evaluate(value))
        case let .stackSlotPairRead(firstDestination, _, firstValue, secondDestination, _, secondValue):
            let first = try evaluate(firstValue)
            let second = try evaluate(secondValue)
            try write(firstDestination, first)
            try write(secondDestination, second)
        case let .conditionalBranch(condition, left, right, target):
            if try compare(condition, try evaluate(left), try evaluate(right)) {
                nextPC = try evaluate(target).bits
            }
        case let .select(destination, condition, left, right, trueValue, falseValue):
            let taken = try compare(condition, try evaluate(left), try evaluate(right))
            try write(destination, try evaluate(taken ? trueValue : falseValue))
        case let .compareToBool(destination, condition, left, right):
            let result = try compare(condition, try evaluate(left), try evaluate(right))
            try write(destination, .int(result ? 1 : 0, width: 32, signed: true))
        case .returnValue:
            nextPC = state.x[30]
        case let .intrinsic(destination, name, arguments):
            try intrinsic(name, destination: destination, arguments: arguments)
        case let .unknown(_, _, mnemonic, operands):
            throw Failure.unlifted("\(mnemonic) \(operands)")
        case let .call(frame, _):
            // Only the branch-with-link itself: PC to the target, X30 to the return address.
            // The callee's effects (MacIR's result and clobber model) are outside one instruction.
            let target: UInt64
            let spelled = frame.target.hasPrefix("(*") && frame.target.hasSuffix(")")
                ? String(frame.target.dropFirst(2).dropLast()) : frame.target
            if let address = A64OracleHex.uint64(spelled.lowercased()) ?? UInt64(spelled) {
                target = address
            } else if Self.location(spelled) != nil {
                target = try readRegister(spelled).bits
            } else {
                throw Failure.unsupported("call to \(frame.target)")
            }
            state.x[30] = state.pc &+ 4
            writtenGPRs.insert(30)
            nextPC = target
        case .switchDispatch:
            throw Failure.unsupported("switchDispatch")
        }
    }

    // MARK: Values

    private enum Location {
        case gpr(index: Int, width: Int)
        case zero(width: Int)
        case stackPointer
        case fp(index: Int, width: Int)
    }

    private static func location(_ name: String) -> Location? {
        let name = name.lowercased()
        switch name {
        case "sp", "wsp": return .stackPointer
        case "xzr": return .zero(width: 64)
        case "wzr": return .zero(width: 32)
        case "fp": return .gpr(index: 29, width: 64)
        case "lr": return .gpr(index: 30, width: 64)
        default: break
        }
        guard let prefix = name.first, let index = Int(name.dropFirst()) else { return nil }
        switch prefix {
        case "x" where (0...30).contains(index): return .gpr(index: index, width: 64)
        case "w" where (0...30).contains(index): return .gpr(index: index, width: 32)
        case "b" where (0...31).contains(index): return .fp(index: index, width: 8)
        case "h" where (0...31).contains(index): return .fp(index: index, width: 16)
        case "s" where (0...31).contains(index): return .fp(index: index, width: 32)
        case "d" where (0...31).contains(index): return .fp(index: index, width: 64)
        case "q" where (0...31).contains(index): return .fp(index: index, width: 128)
        // The D06 region path names the whole 128-bit register through its vN carrier.
        case "v" where (0...31).contains(index): return .fp(index: index, width: 128)
        default: return nil
        }
    }

    /// The declared C type of a parameter, as (width, kind).
    private static func cType(_ type: String) -> (width: Int, kind: Kind)? {
        let type = type.trimmingCharacters(in: .whitespaces)
        switch type {
        case "int64_t", "long", "long long", "intptr_t", "ssize_t", "ptrdiff_t": return (64, .signed)
        case "uint64_t", "unsigned long", "size_t", "uintptr_t": return (64, .unsigned)
        case "int32_t", "int": return (32, .signed)
        case "uint32_t", "unsigned int", "unsigned": return (32, .unsigned)
        case "int16_t", "short": return (16, .signed)
        case "uint16_t", "unsigned short": return (16, .unsigned)
        case "int8_t", "char", "signed char": return (8, .signed)
        case "uint8_t", "unsigned char", "BOOL", "bool": return (8, .unsigned)
        case "double": return (64, .float)
        case "float": return (32, .float)
        case "_Float16", "__fp16", "half": return (16, .float)
        default: return type.hasSuffix("*") ? (64, .unsigned) : nil
        }
    }

    private func readRegister(_ name: String) throws -> Scalar {
        switch Self.location(name) {
        case let .gpr(index, width)?:
            return .int(state.x[index], width: width, signed: alternate(.signed) == .signed)
        case let .zero(width)?:
            return .int(0, width: width, signed: alternate(.signed) == .signed)
        case .stackPointer?:
            return .int(state.sp, width: 64, signed: false)
        case let .fp(index, width)?:
            let value = state.v[index]
            if width == 128 { return Scalar(bits: value.low, width: 128, kind: .unsigned, high: value.high) }
            if width == 8 { return .int(value.low, width: 8, signed: false) }
            return Scalar(bits: value.low & Scalar.mask(width), width: width, kind: .float)
        case nil:
            throw Failure.unsupported("register \(name)")
        }
    }

    mutating func evaluate(_ value: MacIRValue) throws -> Scalar {
        switch value {
        case let .immediate(raw):
            return .int(UInt64(bitPattern: raw), width: 64, signed: alternate(.signed) == .signed)
        case let .register(name, version):
            if version == 0 {
                if let cell = ssaBitHalfCells[value] {
                    let vector = state.v[(cell - 32) % 32]
                    return .int(cell < 64 ? vector.low : vector.high, width: 64, signed: false)
                }
                return try readRegister(name)
            }
            guard let known = ssa[value] else { throw Failure.unsupported("read of unwritten \(value)") }
            return known
        case let .argument(bindingID):
            return try argument(bindingID)
        case .argumentFragment, .abiComposite:
            // The scalar oracle has no aggregate ABI model. It must abstain
            // instead of treating a fragment as an independent source input.
            throw Failure.unsupported("rich aggregate ABI value")
        case let .stackSlot(offset):
            return .int(entrySP &+ UInt64(bitPattern: offset), width: 64, signed: false)
        case let .temporary(index):
            guard let known = ssa[value] else { throw Failure.unsupported("read of unwritten tmp_\(index)") }
            return known
        case let .bitTest(inner, bit):
            let scalar = try evaluate(inner)
            guard bit >= 0, bit < 64 else { throw Failure.unsupported("bit test \(bit)") }
            return .int((scalar.bits >> UInt64(bit)) & 1, width: 32, signed: true)
        case let .unary(op, inner):
            return try unary(op, try evaluate(inner))
        case let .binaryExpression(op, left, right) where op == MacIRBuilder.signedProjectionOperator:
            // MacIRBuilder+SemanticLifting.swift (signedProjection): the marker is the signed W-bit view of
            // its operand, W carried by the right operand either bare or inside the partner context. The
            // printer renders it as `(intW_t)e` or the defined two's-complement transport (both the signed
            // low W bits); the partner only steers that rendering and is never evaluated.
            let width: Int
            switch right {
            case let .immediate(raw):
                width = Int(raw)
            case let .binaryExpression(context, .immediate(raw), _) where context == MacIRBuilder.projectionContextOperator:
                width = Int(raw)
            default:
                throw Failure.unsupported("signed projection context \(right)")
            }
            guard width == 32 || width == 64 else { throw Failure.unsupported("signed projection width \(width)") }
            return .int(try evaluate(left).bits, width: width, signed: true)
        case let .binaryExpression(op, left, right):
            return try binary(op, try evaluate(left), try evaluate(right))
        case let .signedBitfield(field):
            let source = try evaluate(field.source)
            guard source.kind != .float, source.width <= 64 else {
                throw Failure.unsupported("noninteger signed field source")
            }
            return .int(field.evaluatedBits(sourceBits: source.bits), width: field.operandBits, signed: false)
        case let .symbol(name):
            // FP immediates (`fmov d0, #1.5`) lift as their decimal spelling.
            if let literal = Double(name) {
                usedFloatingPoint = true
                return Scalar(bits: literal.bitPattern, width: 64, kind: .float)
            }
            throw Failure.unsupported("symbol \(name)")
        case let .unknown(text):
            throw Failure.unlifted("value \(text)")
        }
    }

    private func argument(_ bindingID: MacIRParameterBindingID) throws -> Scalar {
        let matches = function.parameters.filter { $0.bindingID == bindingID }
        guard let parameter = matches.first else {
            throw Failure.unsupported("unbound argument \(bindingID.placeholderName)")
        }
        guard matches.count == 1,
              function.parameters.filter({ $0.id == parameter.id }).count == 1 else {
            throw Failure.unsupported("ambiguous argument identity \(bindingID.placeholderName)")
        }
        guard parameter.abiLocation.bindingID == bindingID,
              let declared = Self.cType(parameter.type) else {
            throw Failure.unsupported("argument binding/type \(bindingID.placeholderName)")
        }
        switch parameter.abiLocation {
        case let .gpr(index, carrierWidth):
            let width = min(declared.width, carrierWidth)
            if declared.kind == .float { throw Failure.unsupported("float in GPR argument") }
            return .int(argumentEntryState.x[index], width: width, signed: alternate(declared.kind) == .signed)
        case let .simd(index, scalarWidth):
            guard declared.kind == .float, declared.width == scalarWidth else {
                throw Failure.unsupported("non-scalar or mismatched SIMD argument")
            }
            return Scalar(bits: argumentEntryState.v[index].low & Scalar.mask(scalarWidth), width: scalarWidth, kind: .float)
        case let .entryStack(byteOffset, size, _):
            guard size <= 8, declared.width <= size * 8 else {
                throw Failure.unsupported("non-scalar or undersized stack argument")
            }
            var bits: UInt64 = 0
            for offset in 0..<size {
                let address = entrySP &+ UInt64(byteOffset) &+ UInt64(offset)
                bits |= UInt64(argumentEntryState.byte(at: address)) << UInt64(offset * 8)
            }
            let width = declared.width
            if declared.kind == .float {
                return Scalar(bits: bits & Scalar.mask(width), width: width, kind: .float)
            }
            return .int(bits, width: width, signed: alternate(declared.kind) == .signed)
        case .unbound:
            throw Failure.unsupported("unbound parameter")
        }
    }

    private func alternate(_ kind: Kind) -> Kind {
        guard alternateSignedness else { return kind }
        switch kind {
        case .signed: return .unsigned
        case .unsigned: return .signed
        case .float: return .float
        }
    }

    private mutating func address64(_ value: MacIRValue) throws -> UInt64 {
        let scalar = try evaluate(value)
        guard scalar.kind != .float else { throw Failure.unsupported("float address") }
        return scalar.width >= 64 ? scalar.bits : UInt64(bitPattern: scalar.kind == .signed ? scalar.signedValue : Int64(scalar.bits))
    }

    /// Typed fixed-width vector write only. No scalar/vector alias inference.
    mutating func writeNEONRegister(_ destination: MacIRValue, _ value: Scalar) throws {
        guard case let .register(name, _) = destination,
              let index = A64MachineState.vectorIndex(name), name == "v\(index)", value.width == 128 else {
            throw Failure.unsupported("NEON register destination")
        }
        state.v[index] = .init(low: value.bits, high: value.high)
        ssa[destination] = value
        writtenVectors.insert(index)
    }

    // MARK: Writes

    mutating func write(_ destination: MacIRValue, _ value: Scalar) throws {
        if let cell = ssaBitHalfCells[destination] {
            let index = (cell - 32) % 32
            let bits = value.bits & Scalar.mask(value.width)
            let stored = Scalar(bits: bits, width: 64, kind: .unsigned)
            if cell < 64 { state.v[index].low = bits }
            else { state.v[index].high = bits }
            ssa[destination] = stored
            writtenVectors.insert(index)
            return
        }
        switch destination {
        case let .register(name, _):
            let converted: Scalar
            switch Self.location(name) {
            case let .gpr(index, width)?:
                converted = try convert(value, toWidth: width, kind: alternate(.signed))
                state.x[index] = width == 32 ? converted.bits & 0xffff_ffff : converted.bits
                writtenGPRs.insert(index)
            case let .zero(width)?:
                converted = try convert(value, toWidth: width, kind: alternate(.signed)) // discarded
            case .stackPointer?:
                converted = try convert(value, toWidth: 64, kind: .unsigned)
                state.sp = converted.bits
            case let .fp(index, width)?:
                if width == 128 {
                    converted = Scalar(bits: value.bits, width: 128, kind: .unsigned, high: value.width == 128 ? value.high : 0)
                    state.v[index] = .init(low: converted.bits, high: converted.high)
                } else if width == 8 {
                    converted = try convert(value, toWidth: 8, kind: .unsigned)
                    state.v[index] = .init(low: converted.bits, high: 0)
                } else {
                    converted = try convert(value, toWidth: width, kind: .float)
                    state.v[index] = .init(low: converted.bits & Scalar.mask(width), high: 0)
                }
                writtenVectors.insert(index)
            case nil:
                throw Failure.unsupported("write to \(name)")
            }
            ssa[destination] = converted
        case .temporary:
            ssa[destination] = value
        default:
            throw Failure.unsupported("write to \(destination)")
        }
    }

    // MARK: Memory

    private func accessWidth(for value: MacIRValue) -> Int? {
        if let access = currentMemoryAccess { return access.byteWidth }
        if let override = accessOverride { return override.bytes }
        guard case let .register(name, _) = value else { return nil }
        switch Self.location(name) {
        case let .gpr(_, width)?, let .zero(width)?: return width / 8
        case let .fp(_, width)?: return width / 8
        case .stackPointer?: return 8
        case nil: return nil
        }
    }

    private func load(into destination: MacIRValue, at address: UInt64) throws -> Scalar {
        guard let bytes = accessWidth(for: destination) else { throw Failure.unsupported("load into \(destination)") }
        var low: UInt64 = 0
        var high: UInt64 = 0
        for offset in 0..<bytes {
            let byte = UInt64(state.byte(at: address &+ UInt64(offset)))
            if offset < 8 { low |= byte << UInt64(offset * 8) } else { high |= byte << UInt64((offset - 8) * 8) }
        }
        guard case let .register(name, _) = destination else { throw Failure.unsupported("load destination") }
        switch Self.location(name) {
        case let .gpr(_, width)?, let .zero(width)?:
            if (currentMemoryAccess.map { $0.extensionKind == .sign } ?? accessOverride?.signExtend ?? false), bytes < 8 {
                let loaded = Scalar.int(low, width: bytes * 8, signed: true)
                return .int(UInt64(bitPattern: loaded.signedValue), width: width, signed: alternate(.signed) == .signed)
            }
            return .int(low, width: width, signed: alternate(.signed) == .signed)
        case let .fp(_, width)?:
            if width == 128 { return Scalar(bits: low, width: 128, kind: .unsigned, high: high) }
            return Scalar(bits: low, width: width, kind: width == 8 ? .unsigned : .float)
        default:
            return .int(low, width: 64, signed: false)
        }
    }

    private mutating func store(_ value: Scalar, at address: UInt64, sourceValue: MacIRValue) throws {
        let bytes = accessWidth(for: sourceValue) ?? (value.width == 128 ? 16 : max(1, value.width / 8))
        for offset in 0..<bytes {
            let byte = offset < 8 ? UInt8(truncatingIfNeeded: value.bits >> UInt64(offset * 8))
                : UInt8(truncatingIfNeeded: value.high >> UInt64((offset - 8) * 8))
            state.setByte(byte, at: address &+ UInt64(offset))
        }
    }

    // MARK: C arithmetic

    private func promoted(_ value: Scalar) -> Scalar {
        guard value.kind != .float, value.width < 32 else { return value }
        let signed = value.kind == .signed
        let widened = signed ? UInt64(bitPattern: value.signedValue) : value.bits
        return .int(widened, width: 32, signed: true)
    }

    /// The usual arithmetic conversions, applied to two integer operands.
    private func common(_ left: Scalar, _ right: Scalar) -> (Scalar, Scalar) {
        let left = promoted(left)
        let right = promoted(right)
        let width = max(left.width, right.width)
        let signed: Bool
        if left.width == right.width {
            signed = left.kind == .signed && right.kind == .signed
        } else {
            let wider = left.width > right.width ? left : right
            signed = wider.kind == .signed
        }
        return (extend(left, to: width, signed: signed), extend(right, to: width, signed: signed))
    }

    private func extend(_ value: Scalar, to width: Int, signed: Bool) -> Scalar {
        let raw = value.kind == .signed ? UInt64(bitPattern: value.signedValue) : value.bits
        return .int(raw, width: width, signed: signed)
    }

    private func convert(_ value: Scalar, toWidth width: Int, kind: Kind) throws -> Scalar {
        if kind == .float {
            if value.kind == .float { return try floatConvert(value, toWidth: width) }
            return try intToFloat(value, width: width)
        }
        if value.kind == .float { return try floatToInt(value, width: width, signed: kind == .signed) }
        let raw = value.kind == .signed ? UInt64(bitPattern: value.signedValue) : value.bits
        return .int(raw, width: width, signed: kind == .signed)
    }

    private func isSigned(_ value: Scalar) -> Bool { value.kind == .signed }

    private mutating func unary(_ op: String, _ value: Scalar) throws -> Scalar {
        switch op {
        case "__ssa_low64", "__ssa_high64":
            guard value.width == 128 else {
                throw Failure.unsupported("vector half extraction requires a 128-bit value")
            }
            return Scalar(bits: op == "__ssa_low64" ? value.bits : value.high,
                          width: 64, kind: .unsigned)
        case "__ssa_bitcast_f32", "__ssa_bitcast_f64":
            let width = op == "__ssa_bitcast_f32" ? 32 : 64
            usedFloatingPoint = true
            return Scalar(bits: value.bits & Scalar.mask(width), width: width, kind: .float)
        case "__ssa_bitcast_u32", "__ssa_bitcast_u64":
            let width = op == "__ssa_bitcast_u32" ? 32 : 64
            return Scalar(bits: value.bits & Scalar.mask(width), width: width, kind: .unsigned)
        default:
            break
        }
        if op.hasPrefix("(") && op.hasSuffix(")") {
            let typeName = String(op.dropFirst().dropLast())
            guard let target = Self.cType(typeName) else { throw Failure.unsupported("cast \(op)") }
            if target.kind == .float { usedFloatingPoint = true }
            return try convert(value, toWidth: target.width, kind: alternate(target.kind))
        }
        if value.kind == .float {
            usedFloatingPoint = true
            switch op {
            case "-": return Scalar(bits: value.bits ^ Scalar.signBit(value.width), width: value.width, kind: .float)
            default: throw Failure.unsupported("float unary \(op)")
            }
        }
        let operand = promoted(value)
        switch op {
        case "-": return .int(0 &- operand.bits, width: operand.width, signed: isSigned(operand))
        case "~": return .int(~operand.bits, width: operand.width, signed: isSigned(operand))
        case "!": return .int(operand.bits == 0 ? 1 : 0, width: 32, signed: true)
        default: throw Failure.unsupported("unary \(op)")
        }
    }

    mutating func binary(_ op: String, _ left: Scalar, _ right: Scalar) throws -> Scalar {
        if op == "__ssa_join_vector_halves" {
            return Scalar(bits: left.bits, width: 128, kind: .unsigned, high: right.bits)
        }
        if left.kind == .float || right.kind == .float {
            return try floatBinary(op, left, right)
        }
        switch op {
        case "<<", ">>":
            let value = promoted(left)
            let amount = promoted(right)
            let count = amount.kind == .signed ? amount.signedValue : Int64(bitPattern: amount.bits)
            guard count >= 0, count < Int64(value.width) else {
                throw Failure.undefined("shift by \(count) of a \(value.width)-bit value")
            }
            if op == "<<" { return .int(value.bits << UInt64(count), width: value.width, signed: isSigned(value)) }
            if isSigned(value) {
                return .int(UInt64(bitPattern: value.signedValue >> count), width: value.width, signed: true)
            }
            return .int(value.bits >> UInt64(count), width: value.width, signed: false)
        case "&&", "||":
            let l = promoted(left).bits != 0
            let r = promoted(right).bits != 0
            return .int((op == "&&" ? l && r : l || r) ? 1 : 0, width: 32, signed: true)
        case "==", "!=", "<", "<=", ">", ">=":
            return .int(try compare(op, left, right) ? 1 : 0, width: 32, signed: true)
        default:
            break
        }
        let (l, r) = common(left, right)
        let signed = isSigned(l)
        switch op {
        case "+": return .int(l.bits &+ r.bits, width: l.width, signed: signed)
        case "-": return .int(l.bits &- r.bits, width: l.width, signed: signed)
        case "*": return .int(l.bits &* r.bits, width: l.width, signed: signed)
        case "&": return .int(l.bits & r.bits, width: l.width, signed: signed)
        case "|": return .int(l.bits | r.bits, width: l.width, signed: signed)
        case "^": return .int(l.bits ^ r.bits, width: l.width, signed: signed)
        case "/", "%":
            guard r.bits != 0 else { throw Failure.undefined("division by zero") }
            if signed {
                let a = l.signedValue, b = r.signedValue
                let minimum = Int64(bitPattern: Scalar.signBit(l.width) | (l.width < 64 ? ~Scalar.mask(l.width) : 0))
                if a == minimum, b == -1 { throw Failure.undefined("signed division overflow") }
                return .int(UInt64(bitPattern: op == "/" ? a / b : a % b), width: l.width, signed: true)
            }
            return .int(op == "/" ? l.bits / r.bits : l.bits % r.bits, width: l.width, signed: false)
        default:
            throw Failure.unsupported("binary \(op)")
        }
    }

    func compare(_ condition: String, _ left: Scalar, _ right: Scalar) throws -> Bool {
        if left.kind == .float || right.kind == .float {
            let a = try asDouble(left), b = try asDouble(right)
            switch condition {
            case "==": return a == b
            case "!=": return a != b
            case "<": return a < b
            case "<=": return a <= b
            case ">": return a > b
            case ">=": return a >= b
            default: throw Failure.unsupported("float condition \(condition)")
            }
        }
        let (l, r) = common(left, right)
        if isSigned(l) {
            let a = l.signedValue, b = r.signedValue
            switch condition {
            case "==": return a == b
            case "!=": return a != b
            case "<": return a < b
            case "<=": return a <= b
            case ">": return a > b
            case ">=": return a >= b
            default: throw Failure.unsupported("condition \(condition)")
            }
        }
        let a = l.bits, b = r.bits
        switch condition {
        case "==": return a == b
        case "!=": return a != b
        case "<": return a < b
        case "<=": return a <= b
        case ">": return a > b
        case ">=": return a >= b
        default: throw Failure.unsupported("condition \(condition)")
        }
    }

    // MARK: Floating point (host IEEE arithmetic, FPCR default profile only)

    private func asDouble(_ value: Scalar) throws -> Double {
        switch (value.kind, value.width) {
        case (.float, 64): return Double(bitPattern: value.bits)
        case (.float, 32): return Double(Float(bitPattern: UInt32(truncatingIfNeeded: value.bits)))
        case (.float, 16): return Double(Float16(bitPattern: UInt16(truncatingIfNeeded: value.bits)))
        case (.signed, _): return Double(promoted(value).signedValue)
        case (.unsigned, _): return Double(value.bits)
        default: throw Failure.unsupported("float width \(value.width)")
        }
    }

    private func floatConvert(_ value: Scalar, toWidth width: Int) throws -> Scalar {
        if value.width == width { return value }
        // Narrowing goes through the exact source type, so one rounding happens (no double rounding
        // through Double for half precision except from double, which the hardware also does once).
        switch (value.width, width) {
        case (32, 64): return Scalar(bits: Double(Float(bitPattern: UInt32(truncatingIfNeeded: value.bits))).bitPattern, width: 64, kind: .float)
        case (16, 64): return Scalar(bits: Double(Float16(bitPattern: UInt16(truncatingIfNeeded: value.bits))).bitPattern, width: 64, kind: .float)
        case (16, 32): return Scalar(bits: UInt64(Float(Float16(bitPattern: UInt16(truncatingIfNeeded: value.bits))).bitPattern), width: 32, kind: .float)
        case (64, 32): return Scalar(bits: UInt64(Float(Double(bitPattern: value.bits)).bitPattern), width: 32, kind: .float)
        case (64, 16): return Scalar(bits: UInt64(Float16(Double(bitPattern: value.bits)).bitPattern), width: 16, kind: .float)
        case (32, 16): return Scalar(bits: UInt64(Float16(Float(bitPattern: UInt32(truncatingIfNeeded: value.bits))).bitPattern), width: 16, kind: .float)
        default: throw Failure.unsupported("float conversion \(value.width)→\(width)")
        }
    }

    private func intToFloat(_ value: Scalar, width: Int) throws -> Scalar {
        let integer = promoted(value)
        switch width {
        case 64:
            let result = isSigned(integer) ? Double(integer.signedValue) : Double(integer.bits)
            return Scalar(bits: result.bitPattern, width: 64, kind: .float)
        case 32:
            let result = isSigned(integer) ? Float(integer.signedValue) : Float(integer.bits)
            return Scalar(bits: UInt64(result.bitPattern), width: 32, kind: .float)
        case 16:
            let result = isSigned(integer) ? Float16(integer.signedValue) : Float16(integer.bits)
            return Scalar(bits: UInt64(result.bitPattern), width: 16, kind: .float)
        default:
            throw Failure.unsupported("int→float width \(width)")
        }
    }

    private func floatToInt(_ value: Scalar, width: Int, signed: Bool) throws -> Scalar {
        let real = try asDouble(value)
        guard real.isFinite else { throw Failure.undefined("conversion of \(real) to an integer") }
        let truncated = real.rounded(.towardZero)
        if signed {
            let limit = Double(sign: .plus, exponent: width - 1, significand: 1)
            guard truncated >= -limit, truncated < limit else { throw Failure.undefined("out-of-range float→int\(width)") }
            return .int(UInt64(bitPattern: Int64(truncated)), width: width, signed: true)
        }
        let limit = Double(sign: .plus, exponent: width, significand: 1)
        guard truncated > -1, truncated < limit else { throw Failure.undefined("out-of-range float→uint\(width)") }
        return .int(UInt64(truncated), width: width, signed: false)
    }

    private mutating func floatBinary(_ op: String, _ left: Scalar, _ right: Scalar) throws -> Scalar {
        usedFloatingPoint = true
        if ["==", "!=", "<", "<=", ">", ">="].contains(op) {
            return .int(try compare(op, left, right) ? 1 : 0, width: 32, signed: true)
        }
        let width = max(left.kind == .float ? left.width : 0, right.kind == .float ? right.width : 0)
        let l = try convert(left, toWidth: width, kind: .float)
        let r = try convert(right, toWidth: width, kind: .float)
        func apply<F: BinaryFloatingPoint>(_ a: F, _ b: F) throws -> F {
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return a / b
            default: throw Failure.unsupported("float binary \(op)")
            }
        }
        switch width {
        case 64:
            return Scalar(bits: try apply(Double(bitPattern: l.bits), Double(bitPattern: r.bits)).bitPattern, width: 64, kind: .float)
        case 32:
            let result = try apply(Float(bitPattern: UInt32(truncatingIfNeeded: l.bits)), Float(bitPattern: UInt32(truncatingIfNeeded: r.bits)))
            return Scalar(bits: UInt64(result.bitPattern), width: 32, kind: .float)
        case 16:
            let result = try apply(Float16(bitPattern: UInt16(truncatingIfNeeded: l.bits)), Float16(bitPattern: UInt16(truncatingIfNeeded: r.bits)))
            return Scalar(bits: UInt64(result.bitPattern), width: 16, kind: .float)
        default:
            throw Failure.unsupported("float width \(width)")
        }
    }

    // MARK: Intrinsics

    private static func conditionHolds(_ suffix: String, _ state: A64MachineState) -> Bool? {
        switch suffix {
        case "eq": return state.z
        case "ne": return !state.z
        case "cs", "hs": return state.c
        case "cc", "lo": return !state.c
        case "mi": return state.n
        case "pl": return !state.n
        case "vs": return state.flagV
        case "vc": return !state.flagV
        case "hi": return state.c && !state.z
        case "ls": return !(state.c && !state.z)
        case "ge": return state.n == state.flagV
        case "lt": return state.n != state.flagV
        case "gt": return !state.z && state.n == state.flagV
        case "le": return !(!state.z && state.n == state.flagV)
        case "al", "nv": return true
        default: return nil
        }
    }

    private mutating func intrinsic(_ name: String, destination: MacIRValue?, arguments: [MacIRValue]) throws {
        if let semantics = currentScalarFP {
            guard semantics.intrinsicName == name, let destination else { throw Failure.unsupported("scalar FP descriptor/intrinsic mismatch") }
            usedFloatingPoint = true
            var values: [Scalar] = []
            for value in arguments { values.append(try evaluate(value)) }
            if semantics.integerCarrier == .scalarSIMDBits, semantics.operation == .fromInteger {
                values = values.map { .int($0.bits, width: semantics.inputType.bitWidth, signed: semantics.inputType.isSignedInteger) }
            }
            var result = try A64ScalarFPEvaluator.evaluate(semantics, arguments: values)
            if semantics.integerCarrier == .scalarSIMDBits, semantics.operation == .toInteger {
                // Store integer bits in the S/D view, never numerically int->float.
                result = Scalar(bits: result.bits, width: result.width, kind: .float)
            }
            try write(destination, result)
            return
        }
        func argument(_ index: Int) throws -> Scalar {
            guard arguments.indices.contains(index) else { throw Failure.unsupported("\(name) arity") }
            return try evaluate(arguments[index])
        }
        func destinationWidth() throws -> Int {
            guard case let .register(registerName, _)? = destination else {
                throw Failure.unsupported("\(name) destination")
            }
            switch Self.location(registerName) {
            case let .gpr(_, width)?, let .zero(width)?: return width
            default: throw Failure.unsupported("\(name) destination")
            }
        }
        switch name {
        case "a64_sdiv32", "a64_sdiv64", "a64_udiv32", "a64_udiv64",
             "a64_srem32", "a64_srem64", "a64_urem32", "a64_urem64":
            guard let destination else { throw Failure.unsupported("division destination") }
            let width = name.hasSuffix("32") ? 32 : 64
            let signed = name.hasPrefix("a64_s")
            let remainder = name.contains("rem")
            let a = try Scalar.int(argument(0).bits, width: width, signed: signed)
            let b = try Scalar.int(argument(1).bits, width: width, signed: signed)
            let result: UInt64
            if b.bits == 0 { result = remainder ? a.bits : 0 }
            else if signed {
                let minimum = Scalar.int(Scalar.signBit(width), width: width, signed: true).signedValue
                if a.signedValue == minimum && b.signedValue == -1 { result = remainder ? 0 : a.bits }
                else { result = UInt64(bitPattern: remainder ? a.signedValue % b.signedValue : a.signedValue / b.signedValue) }
            } else { result = remainder ? a.bits % b.bits : a.bits / b.bits }
            try write(destination, .int(result, width: width, signed: signed))
        case "nop", "compare":
            return
        case _ where name.hasPrefix("conditional_compare_"):
            return // NZCV only; MacIR has no flag state.
        case "branch":
            nextPC = try argument(0).bits
        case "branch_register":
            nextPC = try argument(0).bits
        case _ where name.hasPrefix("branch_"):
            guard let holds = Self.conditionHolds(String(name.dropFirst("branch_".count)), state) else {
                throw Failure.unsupported(name)
            }
            if holds { nextPC = try argument(0).bits }
        case "stack_alloc":
            state.sp = state.sp &- (try argument(0).bits)
            if let destination { try write(destination, .int(state.sp, width: 64, signed: false)) }
        case "stack_free":
            state.sp = state.sp &+ (try argument(0).bits)
            if let destination { try write(destination, .int(state.sp, width: 64, signed: false)) }
        case "adrp":
            guard let destination else { throw Failure.unsupported("adrp destination") }
            try write(destination, .int(try argument(0).bits, width: 64, signed: false))
        case "fmov":
            guard let destination else { throw Failure.unsupported("fmov destination") }
            let source = try argument(0)
            // A bit move, never a value conversion: an FP destination takes its own width of low
            // bits (`fmov h0, w1` keeps bits 15:0); a GPR destination takes the source bits
            // zero-extended (`fmov w0, h1`).
            if case let .register(registerName, _) = destination, case let .fp(_, width)? = Self.location(registerName) {
                try write(destination, Scalar(bits: source.bits & Scalar.mask(width), width: width, kind: width == 128 ? .unsigned : .float,
                                              high: width == 128 ? source.high : 0))
            } else {
                try write(destination, Scalar(bits: source.bits & Scalar.mask(source.width), width: source.width, kind: .unsigned))
            }
        case "save_pair_writeback", "restore_pair_writeback":
            guard arguments.count == 6, let width = accessWidth(for: arguments[0]) else {
                throw Failure.unsupported("pair writeback arity/width")
            }
            let base = try argument(2).bits
            let updated = base &+ (try argument(4).bits)
            let address = try argument(5).bits == 0 ? base : updated
            if name == "save_pair_writeback" {
                let first = try argument(0), second = try argument(1)
                try store(first, at: address, sourceValue: arguments[0])
                try store(second, at: address &+ UInt64(width), sourceValue: arguments[1])
            } else {
                let first = try load(into: arguments[0], at: address)
                let second = try load(into: arguments[1], at: address &+ UInt64(width))
                try write(arguments[0], first)
                try write(arguments[1], second)
            }
            try write(arguments[3], .int(updated, width: 64, signed: false))
        case "save_pair":
            let first = try argument(0), second = try argument(1)
            let address = try address64(arguments.count > 2 ? arguments[2] : .immediate(0))
            let width = accessWidth(for: arguments[0]) ?? max(1, first.width / 8)
            try store(first, at: address, sourceValue: arguments[0])
            try store(second, at: address &+ UInt64(width), sourceValue: arguments[1])
        case "restore_pair":
            guard arguments.count >= 3 else { throw Failure.unsupported("restore_pair arity") }
            let address = try address64(arguments[2])
            guard let width = accessWidth(for: arguments[0]) else { throw Failure.unsupported("restore_pair width") }
            let first = try load(into: arguments[0], at: address)
            let second = try load(into: arguments[1], at: address &+ UInt64(width))
            try write(arguments[0], first)
            try write(arguments[1], second)
        case "clz", "rbit", "rev", "rev16", "rev32":
            guard let destination else { throw Failure.unsupported("\(name) destination") }
            let width = try destinationWidth()
            let source = try argument(0).bits & Scalar.mask(width)
            let result: UInt64
            switch name {
            case "clz": result = UInt64(width == 64 ? source.leadingZeroBitCount : UInt32(truncatingIfNeeded: source).leadingZeroBitCount)
            case "rbit": result = width == 64 ? Self.reverseBits(source) : UInt64(Self.reverseBits(UInt64(UInt32(truncatingIfNeeded: source)) << 32))
            case "rev": result = width == 64 ? source.byteSwapped : UInt64(UInt32(truncatingIfNeeded: source).byteSwapped)
            case "rev16": result = Self.reverseWithin(source, chunkBytes: 2, width: width)
            default:
                guard width == 64 else { throw Failure.unsupported("rev32 on 32-bit") }
                result = Self.reverseWithin(source, chunkBytes: 4, width: 64)
            }
            try write(destination, .int(result, width: width, signed: true))
        case "smulh", "umulh":
            guard let destination else { throw Failure.unsupported("\(name) destination") }
            let l = try argument(0).bits, r = try argument(1).bits
            let high: UInt64
            if name == "smulh" {
                high = UInt64(bitPattern: Int64(bitPattern: l).multipliedFullWidth(by: Int64(bitPattern: r)).high)
            } else {
                high = l.multipliedFullWidth(by: r).high
            }
            try write(destination, .int(high, width: 64, signed: true))
        case "crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch", "crc32cw", "crc32cx":
            guard let destination else { throw Failure.unsupported("\(name) destination") }
            let polynomial: UInt32 = name.hasPrefix("crc32c") ? 0x82F6_3B78 : 0xEDB8_8320
            let bytes: Int
            switch name.last {
            case "b": bytes = 1
            case "h": bytes = 2
            case "w": bytes = 4
            default: bytes = 8
            }
            var crc = UInt32(truncatingIfNeeded: try argument(0).bits)
            let data = try argument(1).bits
            for index in 0..<bytes {
                crc ^= UInt32(UInt8(truncatingIfNeeded: data >> UInt64(index * 8)))
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ polynomial : crc >> 1 }
            }
            try write(destination, .int(UInt64(crc), width: 32, signed: true))
        default:
            throw Failure.unsupported("intrinsic \(name)")
        }
    }

    private static func reverseBits(_ value: UInt64) -> UInt64 {
        var input = value, output: UInt64 = 0
        for _ in 0..<64 { output = (output << 1) | (input & 1); input >>= 1 }
        return output
    }

    private static func reverseWithin(_ value: UInt64, chunkBytes: Int, width: Int) -> UInt64 {
        var result: UInt64 = 0
        let chunkBits = chunkBytes * 8
        for chunk in stride(from: 0, to: width, by: chunkBits) {
            var piece = (value >> UInt64(chunk)) & Scalar.mask(chunkBits)
            var swapped: UInt64 = 0
            for _ in 0..<chunkBytes { swapped = (swapped << 8) | (piece & 0xff); piece >>= 8 }
            result |= swapped << UInt64(chunk)
        }
        return result
    }
}
