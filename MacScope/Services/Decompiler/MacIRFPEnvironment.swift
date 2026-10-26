import Foundation

/// Architectural effect metadata for one scalar A64 FADD. The numeric result
/// is defined by MacIROperation; the FPSR output is carried here as a symbolic
/// side effect, not as a definition in the general MacIR dataflow model.
/// FPCR is read without being written; FPSR accumulates the instruction's
/// exception bits on its input value.
///
/// This is symbolic decompiler IR. It does not execute the operation, infer
/// concrete FPCR/FPSR values, or claim support for enabled traps or other FP ops.
public struct MacIRFPEnvironmentEffect: Hashable, Sendable {
    public enum Operation: Hashable, Sendable { case add }
    public enum StatusUpdate: Hashable, Sendable { case stickyOROfRaisedExceptions }

    public let operation: Operation = .add
    public let statusUpdate: StatusUpdate = .stickyOROfRaisedExceptions
    public let type: MacIRScalarType
    public let left: MacIRValue
    public let right: MacIRValue
    public let numericResult: MacIRValue
    public let fpcrInput: MacIRValue
    public let fpsrInput: MacIRValue
    public let fpsrOutput: MacIRValue

    public var intrinsicName: String { "a64_fp_env_add_\(type.rawValue)" }

    public init(type: MacIRScalarType, left: MacIRValue, right: MacIRValue,
                numericResult: MacIRValue, fpcrInput: MacIRValue,
                fpsrInput: MacIRValue, fpsrOutput: MacIRValue) {
        precondition(type == .binary32 || type == .binary64)
        self.type = type
        self.left = left
        self.right = right
        self.numericResult = numericResult
        self.fpcrInput = fpcrInput
        self.fpsrInput = fpsrInput
        self.fpsrOutput = fpsrOutput
    }
}

/// A deliberately narrow entry point for environment-aware scalar FADD IR.
/// Other rows are refused, so the symbolic FPSR result cannot be silently
/// carried across an unmodeled state writer. Ordinary MacIRBuilder users keep
/// the existing default-FPCR numeric-only contract.
public enum MacIRFPEnvironmentLifter {
    public static func liftSingleFAdd<Row: DecompilerInstructionRow>(
        name: String, instruction row: Row,
        fpcrInput: MacIRValue = .register(name: "fpcr", version: 0),
        fpsrInput: MacIRValue = .register(name: "fpsr", version: 0)
    ) -> MacIRFunction? {
        guard row.mnemonic.lowercased() == "fadd" else { return nil }
        var function = MacIRBuilder().buildFunction(name: name, instructions: [row])
        guard function.instructions.count == 1,
              let descriptor = function.instructions[0].scalarFP,
              descriptor.operation == .add,
              case let .intrinsic(destination?, _, arguments) = function.instructions[0].operation,
              arguments.count == 2 else { return nil }

        let effect = MacIRFPEnvironmentEffect(
            type: descriptor.resultType, left: arguments[0], right: arguments[1],
            numericResult: destination,
            fpcrInput: fpcrInput,
            fpsrInput: fpsrInput,
            fpsrOutput: .register(name: "fpsr", version: 1)
        )
        function.instructions[0].operation = .intrinsic(
            destination: destination, name: effect.intrinsicName,
            arguments: [effect.left, effect.right, effect.fpcrInput, effect.fpsrInput]
        )
        // The original descriptor asserts FPCR=0 and has no FPSR output. It
        // cannot describe this stateful operation or be used by its evaluator.
        function.instructions[0].scalarFP = nil
        function.instructions[0].fpEnvironment = effect
        return function
    }
}

/// Makes the bounded FP environment effect visible in ordinary pseudocode for
/// an entire straight-line function made only of scalar FADD instructions and
/// an optional final RET. Other instructions may write FPCR/FPSR or change
/// control flow, so they keep the existing unsupported environment contract.
enum MacIRFPEnvironmentPseudocodeProjection {
    static func project(_ function: MacIRFunction) -> MacIRFunction {
        let instructions = function.instructions
        guard !instructions.isEmpty, instructions.count <= 16 else { return function }
        let hasReturn = instructions.last?.source.mnemonic == "ret"
        let addCount = instructions.count - (hasReturn ? 1 : 0)
        guard addCount > 0 else { return function }

        // A64 instructions occupy four bytes. Refuse gaps, repeated addresses,
        // and every unmodeled state writer before assigning FPSR versions.
        for index in instructions.indices {
            if index > 0 {
                guard instructions[index].source.address ==
                        instructions[index - 1].source.address &+ 4 else { return function }
            }
            if index == addCount { continue }
            let instruction = instructions[index]
            guard instruction.source.mnemonic == "fadd",
                  instruction.fpEnvironment == nil,
                  instruction.memoryAccess == nil,
                  instruction.returnTarget == nil,
                  let scalarFP = instruction.scalarFP,
                  scalarFP.operation == .add,
                  case let .intrinsic(destination?, _, arguments) = instruction.operation,
                  arguments.count == 2 else { return function }
        }

        var projected = function
        var repairedInstructions = projected.instructions
        for index in 0..<addCount {
            let instruction = repairedInstructions[index]
            guard let scalarFP = instruction.scalarFP,
                  case let .intrinsic(destination?, _, arguments) = instruction.operation else {
                return function
            }
            let effect = MacIRFPEnvironmentEffect(
                type: scalarFP.resultType,
                left: arguments[0], right: arguments[1], numericResult: destination,
                fpcrInput: .register(name: "fpcr", version: 0),
                fpsrInput: .register(name: "fpsr", version: index),
                fpsrOutput: .register(name: "fpsr", version: index + 1)
            )
            repairedInstructions[index].operation = .intrinsic(
                destination: destination, name: effect.intrinsicName,
                arguments: [effect.left, effect.right, effect.fpcrInput, effect.fpsrInput]
            )
            repairedInstructions[index].scalarFP = nil
            repairedInstructions[index].fpEnvironment = effect
        }
        projected.instructions = repairedInstructions
        return projected
    }
}

/// Bit knowledge, not a host floating-point value. Unknown bits are canonical zero
/// in `value` but MUST NOT be interpreted as known zero by a consumer.
public struct MacIRFPBits: Hashable, Sendable {
    public let value: UInt32
    public let known: UInt32
    public init(value: UInt32 = 0, known: UInt32 = 0) {
        self.value = value & known
        self.known = known
    }
    public static func constant(_ value: UInt32) -> Self { .init(value: value, known: .max) }
    public func field(mask: UInt32, shift: Int = 0) -> UInt32? {
        guard known & mask == mask else { return nil }
        return (value & mask) >> shift
    }
    public func joined(with other: Self) -> Self {
        let agreement = known & other.known & ~(value ^ other.value)
        return .init(value: value, known: agreement)
    }
    /// Exact three-valued OR. A known one dominates an unknown operand.
    public func stickyOR(_ other: Self, mask: UInt32) -> Self {
        let ones = (value | other.value) & mask
        let zeros = known & other.known & ~(value | other.value) & mask
        return .init(value: (value & ~mask) | ones,
                     known: (known & ~mask) | ones | zeros)
    }
}

/// Explicit implementation evidence; no feature set is inferred from absent context.
/// Both registers are 32-bit architectural state, zero-extended for MRS Xt.
public struct MacIRFPRegisterLayout: Hashable, Sendable {
    public let register: MacIRFPState.Register
    public let implemented: UInt32
    public let res0: UInt32
    public init?(register: MacIRFPState.Register, implemented: UInt32, res0: UInt32,
                 upper32AreRES0: Bool) {
        guard upper32AreRES0, implemented & res0 == 0, implemented | res0 == UInt32.max else { return nil }
        self.register = register
        self.implemented = implemented
        self.res0 = res0
    }
    public func normalized(_ bits: MacIRFPBits) -> MacIRFPBits {
        .init(value: bits.value & implemented, known: (bits.known & implemented) | res0)
    }
}

/// A bounded architectural state primitive. This does not admit FP arithmetic or
/// replace numeric-only scalar descriptors. No rounding mode is assumed at entry.
public struct MacIRFPState: Hashable, Sendable {
    public enum Rounding: UInt32, Hashable, Sendable {
        case nearestEven = 0, plusInfinity = 1, minusInfinity = 2, towardZero = 3
    }
    public enum Register: Hashable, Sendable { case fpcr, fpsr }
    public enum Access: Hashable, Sendable { case permitted, trapped, unknown }
    public static let exceptionMask: UInt32 = 0x9f // IOC,DZC,OFC,UFC,IXC,IDC
    public static let qcMask: UInt32 = 1 << 27
    public private(set) var fpcr: MacIRFPBits
    public private(set) var fpsr: MacIRFPBits
    public init(fpcr: MacIRFPBits = .init(), fpsr: MacIRFPBits = .init()) {
        self.fpcr = fpcr
        self.fpsr = fpsr
    }
    /// Raw FPCR fields only; effective behavior also depends on format/features.
    public var rounding: Rounding? {
        fpcr.field(mask: 3 << 22, shift: 22).flatMap(Rounding.init(rawValue:))
    }
    public var defaultNaN: Bool? { fpcr.field(mask: 1 << 25).map { $0 != 0 } }
    public var flushToZero: Bool? { fpcr.field(mask: 1 << 24).map { $0 != 0 } }
    public var flushHalfToZero: Bool? { fpcr.field(mask: 1 << 19).map { $0 != 0 } }
    public var alternateHalfPrecision: Bool? { fpcr.field(mask: 1 << 26).map { $0 != 0 } }
    // These are raw fields, not an assertion that FEAT_AFP exists or is active.
    public var alternateHandling: Bool? { fpcr.field(mask: 1 << 1).map { $0 != 0 } }
    public var flushInputsToZero: Bool? { fpcr.field(mask: 1).map { $0 != 0 } }
    public func joined(with other: Self) -> Self {
        .init(fpcr: fpcr.joined(with: other.fpcr), fpsr: fpsr.joined(with: other.fpsr))
    }
    /// No ABI-preserved FPCR fields or status flags are assumed by this primitive.
    public mutating func invalidateAtUnknownCallOrWriter() { self = .init() }

    /// The caller must prove instruction access and supply the raised-event bits
    /// from an exact operation. This method does not compute those events.
    /// Enabled or unknown exception enables are refused: trapping updates need
    /// separate exception routing, SME/FA64 and implementation-defined evidence.
    /// False refuses the transaction; callers must abort or poison before continuing.
    @discardableResult
    public mutating func accumulateExceptions(_ raised: MacIRFPBits, access: Access) -> Bool {
        guard access == .permitted,
              raised.known & ~Self.exceptionMask == ~Self.exceptionMask,
              raised.value & ~Self.exceptionMask == 0,
              fpcr.field(mask: Self.exceptionMask << 8) == 0 else { return false }
        fpsr = fpsr.stickyOR(raised, mask: Self.exceptionMask)
        return true
    }
    /// Saturation updates only QC; unlike MSR FPSR, a false event cannot clear QC.
    /// A false return refuses the transaction and must not be treated as success.
    @discardableResult
    public mutating func accumulateSaturation(_ saturated: Bool?, access: Access) -> Bool {
        guard access == .permitted else { return false }
        let event = MacIRFPBits(value: saturated == true ? Self.qcMask : 0,
                               known: saturated == nil ? ~Self.qcMask : .max)
        fpsr = fpsr.stickyOR(event, mask: Self.qcMask)
        return true
    }

    public struct Transfer: Hashable, Sendable {
        public enum Direction: Hashable, Sendable { case read, write }
        public let register: Register
        public let direction: Direction
        public let xt: Int
        /// Exact encoding, not mnemonic/operand-string authority.
        public init?(word: UInt32) {
            let base = word & ~UInt32(31)
            switch base {
            case 0xd53b4400: register = .fpcr; direction = .read
            case 0xd53b4420: register = .fpsr; direction = .read
            case 0xd51b4400: register = .fpcr; direction = .write
            case 0xd51b4420: register = .fpsr; direction = .write
            default: return nil
            }
            xt = Int(word & 31)
        }
    }
    public struct TransferEffect: Hashable, Sendable {
        public let transfer: Transfer
        public let before: MacIRFPState
        public let after: MacIRFPState
        /// Nil for writes and reads to XZR; a read never writes Wt or SP.
        public let gprValue: UInt64?
        public let gprKnown: UInt64?
    }
    /// Low 32 bits of Xt are used for MSR; XZR is known zero, not SP.
    /// `source` is required for ordinary Xt writes and is never defaulted to zero.
    /// Nil is a refused transaction, not an instruction with no effects. The caller
    /// must abort the row or poison state before continuing past an unmodeled row.
    public mutating func apply(_ transfer: Transfer, source: MacIRFPBits? = nil,
                               layout: MacIRFPRegisterLayout?, access: Access) -> TransferEffect? {
        guard access == .permitted, let layout, layout.register == transfer.register else { return nil }
        let before = self
        switch transfer.direction {
        case .read:
            let bits = layout.normalized(transfer.register == .fpcr ? fpcr : fpsr)
            return .init(transfer: transfer, before: before, after: self,
                         gprValue: transfer.xt == 31 ? nil : UInt64(bits.value),
                         gprKnown: transfer.xt == 31 ? nil : 0xffff_ffff_0000_0000 | UInt64(bits.known))
        case .write:
            guard let input = transfer.xt == 31 ? MacIRFPBits.constant(0) : source else { return nil }
            let bits = layout.normalized(input)
            if transfer.register == .fpcr { fpcr = bits } else { fpsr = bits }
            return .init(transfer: transfer, before: before, after: self, gprValue: nil, gprKnown: nil)
        }
    }
}

/// A typed refusal for malformed encodings or unsupported vector shapes.
/// Unknown FPCR controls and possible traps alone do not cause this refusal.
/// The requested family remains diagnostic when exact decoding is unavailable.
public struct MacIRFPBlockedEffect: Hashable, Sendable {
    public enum RequestedOperation: String, Hashable, Sendable {
        case fadd, fsub, fmul, fdiv, fmla, fcvtn, fcvtn2, fcvtzs, ucvtf, scvtf
    }
    public enum RequestedRounding: Hashable, Sendable {
        case fpcr, instructionTowardZero
    }
    public enum Blocker: Hashable, Sendable { case invalidEncodingOrUnsupportedShape }
    public let requestedOperation: RequestedOperation
    public let requestedRounding: RequestedRounding
    public let blocker: Blocker = .invalidEncodingOrUnsupportedShape
    public let fpcrInput: MacIRValue
    /// Six cumulative FP exception bits only; QC is exclusively SSA cell98.
    public let exceptionInput: MacIRValue
    public let raisedExceptions: MacIRValue = .unknown("fp_raised_exceptions")
    public let exceptionMask: UInt32 = 0x9f
    public let numericCompletionProven = false
    /// This expression applies ONLY if normal completion is separately proved.
    /// It is not committed on the unresolved trap/access branch.
    public var conditionalNormalExceptionResult: MacIRValue {
        .binaryExpression(op: "|", left: .binaryExpression(op: "&", left: exceptionInput, right: .immediate(0x9f)),
            right: .binaryExpression(op: "&", left: raisedExceptions, right: .immediate(0x9f)))
    }
    public init?(mnemonic: String, operands: String,
                 fpcrInput: MacIRValue = .unknown("fpcr_control"),
                 exceptionInput: MacIRValue = .unknown("fpsr_exception_bits")) {
        guard Self.requiresEnvironment(mnemonic: mnemonic, operands: operands),
              let operation = RequestedOperation(rawValue: mnemonic.lowercased()) else { return nil }
        requestedOperation = operation
        requestedRounding = operation == .fcvtzs ? .instructionTowardZero : .fpcr
        self.fpcrInput = fpcrInput
        self.exceptionInput = exceptionInput
    }
    public static func requiresEnvironment(mnemonic: String, operands: String) -> Bool {
        // The retained frontier consists of arranged vector forms. Legacy scalar
        // descriptors and the isolated symbolic FADD API are a separate contract.
        guard RequestedOperation(rawValue: mnemonic.lowercased()) != nil,
              let destination = operands.lowercased().split(separator: ",").first else { return false }
        let text = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("v") && text.contains(".")
    }
    /// Refuse whole register access until splitting QC/status and access policy
    /// is implemented; an exception-only cell must never masquerade as FPSR.
    public static func isStatusAccess(source: MacIRSourceSpan) -> Bool {
        guard ["mrs", "msr"].contains(source.mnemonic.lowercased()) else { return false }
        let tokens = source.operands.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return tokens.contains("fpsr") || tokens.contains("fpcr")
    }
}

/// Exact sticky-QC relation, backed by the lane descriptor's implemented predicate.
/// This is a separate definition, not an opaque claim about floating-point status.
public struct MacIRNEONQCEffect: Hashable, Sendable {
    public let lane: MacIRNEONLaneOp
    public let arguments: [MacIRValue]
    public let input: MacIRValue
    public let output: MacIRValue
    public init(lane: MacIRNEONLaneOp, arguments: [MacIRValue], input: MacIRValue, output: MacIRValue) {
        precondition(lane.setsQC)
        self.lane = lane; self.arguments = arguments; self.input = input; self.output = output
    }
    public func evaluate(inputQC: Bool?, n: MacIRNEONLaneOp.Vector, m: MacIRNEONLaneOp.Vector) -> Bool? {
        lane.saturates(n: n, m: m) ? true : inputQC
    }
    public func instruction(source: MacIRSourceSpan) -> MacIRInstruction {
        var result = MacIRInstruction(source: source,
            operation: .intrinsic(destination: output, name: "a64_neon_sticky_qc", arguments: [input] + arguments))
        result.neonQC = self
        return result
    }
}

/// Symbolic Advanced SIMD FP semantics on NORMAL COMPLETION, like a potentially
/// faulting load. This is not a host-FP evaluator. Unknown controls remain operands.
/// Arm 2025-12: FPAdd/FPSub/FPMul/FPDiv/FPMulAdd/FPConvert/FPToFixed/FixedToFP.
public struct MacIRVectorFP: Hashable, Sendable {
    public enum Operation: String, Hashable, Sendable {
        case add, subtract, multiply, divide, fusedMultiplyAdd, narrow
        case toSignedInteger, fromSignedInteger, fromUnsignedInteger
    }
    public enum Rounding: Hashable, Sendable { case fpcr, instructionTowardZero }
    public enum Completion: Hashable, Sendable { case normalOnlyMayTrap }
    public let operation: Operation
    public let rounding: Rounding
    public let completion: Completion = .normalOnlyMayTrap
    public let encodedWord: UInt32
    public let inputBits: Int
    public let resultBits: Int
    public let laneCount: Int
    public let highHalf: Bool
    public let destination: String
    public let sources: [String]
    public let selectedElement: Int?
    public enum ResultPlacement: Hashable, Sendable { case replace128, zeroHigh64, preserveLow64 }
    public enum InputDomain: Hashable, Sendable { case ieeeBinary, signedIntegerBits, unsignedIntegerBits }
    public var inputDomain: InputDomain {
        operation == .fromSignedInteger ? .signedIntegerBits
            : operation == .fromUnsignedInteger ? .unsignedIntegerBits : .ieeeBinary
    }
    public var resultPlacement: ResultPlacement {
        highHalf ? .preserveLow64 : laneCount * resultBits == 64 ? .zeroHigh64 : .replace128
    }
    public var resultBitOffset: Int { highHalf ? 64 : 0 }
    public var fusedAddendArgumentIndex: Int? { operation == .fusedMultiplyAdd ? 2 : nil }
    public var armPseudocode: String {
        switch operation {
        case .add: return "FPAdd"
        case .subtract: return "FPSub"
        case .multiply: return "FPMul"
        case .divide: return "FPDiv"
        case .fusedMultiplyAdd: return "FPMulAdd"
        case .narrow: return "FPConvert"
        case .toSignedInteger: return "FPToFixed_ZERO_signed"
        case .fromSignedInteger: return "FixedToFP_signed"
        case .fromUnsignedInteger: return "FixedToFP_unsigned"
        }
    }
    public var readsDestination: Bool { highHalf || operation == .fusedMultiplyAdd }
    public let exceptionMask: UInt32 = 0x9f
    public let exceptionEnableMask: UInt32 = 0x9f00
    /// FPToFixed uses instruction ZERO, but FPUnpack still observes FZ/FIZ/AH
    /// and may raise IDC/IOC. No numeric rounding assumption follows from this.
    public var usesFPCRRounding: Bool { rounding == .fpcr }
    public enum ControlField: Hashable, Sendable {
        case rounding, flushToZero, defaultNaN, alternateHandling, flushInputsToZero, exceptionEnables
    }
    /// Full FPCR remains the operand. This list makes the symbolic control
    /// dependency explicit; feature applicability is named by executionContext.
    public var controlFields: [ControlField] {
        var fields: [ControlField] = [.flushToZero, .alternateHandling, .exceptionEnables]
        if usesFPCRRounding { fields.append(.rounding) }
        if inputDomain == .ieeeBinary { fields.append(.flushInputsToZero) }
        if inputDomain == .ieeeBinary && operation != .toSignedInteger { fields.append(.defaultNaN) }
        return fields
    }
    /// Half-format/FZ16 behavior is not admitted by this binary32/64 boundary.
    public var intrinsicName: String { "a64_vector_fp_\(operation.rawValue)_\(inputBits)_\(resultBits)_\(laneCount)"
        + (highHalf ? "_high" : "_low") + (selectedElement.map { "_element\($0)" } ?? "") }

    public init?(source: MacIRSourceSpan) {
        let tokens = source.byteText.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 4, tokens.allSatisfy({ $0.count == 2 }) else { return nil }
        let bytes = tokens.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 4 else { return nil }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: source.address, maxInstructionCount: 1)
        func normalize(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
        guard decoded.count == 1, decoded[0].mnemonic == source.mnemonic.lowercased(),
              normalize(decoded[0].operands) == normalize(source.operands) else { return nil }
        let ops = MacIRBuilder.splitOperands(decoded[0].operands)
        func vector(_ text: String) -> (String, Int, Int)? {
            let parts = text.lowercased().split(separator: ".")
            guard parts.count == 2, let index = MacIRBuilder.vectorRegisterIndex(String(parts[0])),
                  parts[0] == "v\(index)" else { return nil }
            let shape = String(parts[1])
            guard let bits = ["2s":32,"4s":32,"2d":64][shape],
                  let lanes = Int(shape.dropLast()) else { return nil }
            return (String(parts[0]), bits, lanes)
        }
        guard let dest = ops.first.flatMap(vector), ops.count >= 2, let n = vector(ops[1]) else { return nil }
        let table: [String: Operation] = ["fadd":.add,"fsub":.subtract,"fmul":.multiply,"fdiv":.divide,
            "fmla":.fusedMultiplyAdd,"fcvtn":.narrow,"fcvtn2":.narrow,"fcvtzs":.toSignedInteger,
            "scvtf":.fromSignedInteger,"ucvtf":.fromUnsignedInteger]
        guard let kind = table[decoded[0].mnemonic] else { return nil }
        var inputs = [n.0]
        var element: Int?
        if [.add,.subtract,.multiply,.divide,.fusedMultiplyAdd].contains(kind) {
            guard ops.count == 3, dest.1 == n.1, dest.2 == n.2 else { return nil }
            if let m = vector(ops[2]) {
                guard m.1 == n.1, m.2 == n.2 else { return nil }
                inputs.append(m.0)
            } else {
                guard kind == .multiply || kind == .fusedMultiplyAdd,
                      let dot = ops[2].firstIndex(of: "."), let open = ops[2].firstIndex(of: "["),
                      ops[2].hasSuffix("]"), dot < open else { return nil }
                let name = String(ops[2][..<dot])
                let letter = String(ops[2][ops[2].index(after: dot)..<open])
                guard let index = MacIRBuilder.vectorRegisterIndex(name), name == "v\(index)",
                      ["s":32,"d":64][letter] == n.1,
                      let selected = Int(ops[2][ops[2].index(after: open)..<ops[2].index(before: ops[2].endIndex)]),
                      (0..<(128 / n.1)).contains(selected) else { return nil }
                inputs.append(name); element = selected
            }
        } else {
            guard ops.count == 2 else { return nil }
            if kind == .narrow {
                guard n.1 == 64, n.2 == 2, dest.1 == 32,
                      dest.2 == (decoded[0].mnemonic == "fcvtn2" ? 4 : 2) else { return nil }
            } else { guard dest.1 == n.1, dest.2 == n.2 else { return nil } }
        }
        operation = kind; rounding = kind == .toSignedInteger ? .instructionTowardZero : .fpcr
        encodedWord = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        inputBits = n.1; resultBits = dest.1; laneCount = kind == .narrow ? 2 : dest.2
        highHalf = decoded[0].mnemonic == "fcvtn2"
        destination = dest.0; sources = inputs; selectedElement = element
    }
}

/// Both outputs are conditional on normal completion. A trap can suppress the
/// destination; this metadata does not create a synthetic exception CFG edge.
public struct MacIRVectorFPEffect: Hashable, Sendable {
    public let semantics: MacIRVectorFP
    public let arguments: [MacIRValue]
    public let fpcrInput: MacIRValue
    public let executionContext: MacIRValue
    public let exceptionInput: MacIRValue
    public let exceptionOutput: MacIRValue
    public let numericOutput: MacIRValue
    /// Exact cumulative flags are not guessed from host arithmetic.
    public let raisedExceptions: MacIRValue = .unknown("fp_raised_exceptions")
    public var normalExceptionResult: MacIRValue {
        .binaryExpression(op: "|", left: .binaryExpression(op: "&", left: exceptionInput, right: .immediate(0x9f)),
            right: .binaryExpression(op: "&", left: raisedExceptions, right: .immediate(0x9f)))
    }
    /// For each raised IEEE exception, effective corresponding enable may trap.
    /// Effective enables additionally depend on named SME/FA64 execution context;
    /// access traps are possible independently of the IEEE exception enables.
    public struct TrapCondition: Hashable, Sendable {
        public let raisedExceptionBits: MacIRValue
        public let fpcr: MacIRValue
        public let executionContext: MacIRValue
        public let exceptionMask: UInt32 = 0x9f
        public let enableBitOffset = 8
        /// FPProcessException: enable AND (!FEAT_SME OR !PSTATE.SM OR FullA64).
        /// Access permission and implementation-defined immediate/deferred trap
        /// delivery are independent parts of the named execution context.
        public let enableGate = "notSME_or_notStreaming_or_fullA64"
        public let accessMayTrapIndependently = true
        public let immediateOrBeforeNextInstructionDelivery = true
    }
    public var trapCondition: TrapCondition {
        .init(raisedExceptionBits: raisedExceptions, fpcr: fpcrInput, executionContext: executionContext)
    }
    public let mayTrapOnAccessOrEnabledException = true
    public var numericArguments: [MacIRValue] { arguments + [fpcrInput, executionContext, exceptionInput] }
    public func replacingNumericOutput(_ output: MacIRValue) -> Self {
        .init(semantics: semantics, arguments: arguments, fpcrInput: fpcrInput,
              executionContext: executionContext, exceptionInput: exceptionInput,
              exceptionOutput: exceptionOutput, numericOutput: output)
    }
}

extension MacIRBuilder {
    static func liftVectorFP(_ semantics: MacIRVectorFP, source: MacIRSourceSpan,
                             state: inout BuilderState,
                             fpcr: MacIRValue, exceptions: MacIRValue,
                             exceptionOutput: MacIRValue,
                             executionContext: MacIRValue = .unknown("fp_access_features_sme")) -> [MacIRInstruction] {
        var arguments = semantics.sources.map { state.readRegister($0) }
        if semantics.readsDestination { arguments.append(state.readRegister(semantics.destination)) }
        let destination = state.writeRegister(semantics.destination)
        let effect = MacIRVectorFPEffect(semantics: semantics, arguments: arguments,
            fpcrInput: fpcr, executionContext: executionContext, exceptionInput: exceptions,
            exceptionOutput: exceptionOutput, numericOutput: destination)
        var numeric = MacIRInstruction(source: source, operation: .intrinsic(destination: destination,
            name: semantics.intrinsicName, arguments: effect.numericArguments))
        numeric.vectorFP = effect
        var status = MacIRInstruction(source: source,
            operation: .assign(destination: exceptionOutput, source: effect.normalExceptionResult))
        status.vectorFPStatus = effect
        return [numeric, status]
    }
}

public enum MacIRFPArchitecturalCell: String, Hashable, Sendable {
    case control = "__fpcr", executionContext = "__fp_execution_context"
    case exceptions = "__fpsr_exceptions", qc = "__neon_qc"
}
extension MacIRBuilder {
    /// Presentation of unknown state after calls or refused writers. SSA still
    /// owns cells98/99/100; ordinary regions use these explicit architectural cells.
    static func architecturalClobbers(source: MacIRSourceSpan, observesQC: Bool,
                                      tracksFP: Bool = true) -> [MacIRInstruction] {
        var cells: [MacIRFPArchitecturalCell] = tracksFP ? [.control, .executionContext, .exceptions] : []
        if observesQC { cells.append(.qc) }
        return cells.map { cell in
            var instruction = MacIRInstruction(source: source,
                operation: .assign(destination: .symbol(cell.rawValue), source: .unknown("architectural_state_clobber")))
            instruction.fpArchitecturalClobber = cell
            return instruction
        }
    }
}
