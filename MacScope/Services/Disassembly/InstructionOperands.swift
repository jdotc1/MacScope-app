import Foundation

/// Versioned decode facts. Display spelling is separate from opcode identity and access semantics.
/// A complete envelope is a bounded claim about these operands, not about ISA-wide coverage.
public struct InstructionOperands: Hashable, Codable, Sendable {
    public enum Architecture: String, Hashable, Codable, Sendable { case arm64, x86_64 }
    public enum Coverage: String, Hashable, Codable, Sendable { case complete, partial, unavailable }
    public enum NumberFormat: String, Hashable, Codable, Sendable {
        case automatic, decimal, hexadecimal, hexAddress
    }

    public struct LegacyText: Hashable, Codable, Sendable {
        public let mnemonic: String
        public let operands: String
        public init(mnemonic: String, operands: String) {
            self.mnemonic = mnemonic; self.operands = operands
        }
    }

    public struct VectorArrangement: Hashable, Codable, Sendable {
        public let elementWidth: Int
        /// Nil denotes an element view, for example V3.H[2].
        public let laneCount: Int?
        public init(elementWidth: Int, laneCount: Int? = nil) {
            self.elementWidth = elementWidth; self.laneCount = laneCount
        }
    }

    public struct Register: Hashable, Codable, Sendable {
        public enum Bank: String, Hashable, Codable, Sendable { case general, simd }
        public enum Role: String, Hashable, Codable, Sendable { case ordinary, stackPointer, zero }
        public let bank: Bank
        public let index: Int
        public let width: Int
        public let role: Role
        public let arrangement: VectorArrangement?
        public let lane: Int?
        public init(bank: Bank = .general, index: Int, width: Int, role: Role = .ordinary,
                    arrangement: VectorArrangement? = nil, lane: Int? = nil) {
            self.bank = bank; self.index = index; self.width = width; self.role = role
            self.arrangement = arrangement; self.lane = lane
        }
    }

    public struct Immediate: Hashable, Codable, Sendable {
        public enum Value: Hashable, Codable, Sendable {
            case signed(Int64)
            case unsigned(UInt64)
            /// IEEE bits retain negative zero and avoid lossy JSON floating-point transport.
            case floatingPoint(bitPattern: UInt64, width: Int)
        }
        public let value: Value
        public let encodedWidth: Int?
        /// Optional original encoded bits/shift, distinct from an expanded alias value.
        public let encodedValue: UInt64?
        public let encodedShift: Int?
        public let format: NumberFormat?
        public init(_ value: Value, encodedWidth: Int? = nil, encodedValue: UInt64? = nil,
                    encodedShift: Int? = nil, format: NumberFormat? = nil) {
            self.value = value; self.encodedWidth = encodedWidth; self.encodedValue = encodedValue
            self.encodedShift = encodedShift; self.format = format
        }
    }

    public struct RegisterModifier: Hashable, Codable, Sendable {
        public enum Kind: String, Hashable, Codable, Sendable {
            case lsl, lsr, asr, ror, msl, uxtb, uxth, uxtw, uxtx, sxtb, sxth, sxtw, sxtx
        }
        public let kind: Kind
        /// Alias spelling does not replace the encoded extension kind.
        public let presentationKind: Kind?
        public let amount: Int?
        /// An extension may be printed without its zero amount; LSL #0 may be absent entirely.
        public let omitZeroAmount: Bool
        public let omitWhenZero: Bool
        public init(_ kind: Kind, amount: Int? = nil, omitZeroAmount: Bool = false,
                    omitWhenZero: Bool = false, presentationKind: Kind? = nil) {
            self.presentationKind = presentationKind
            self.kind = kind; self.amount = amount; self.omitZeroAmount = omitZeroAmount
            self.omitWhenZero = omitWhenZero
        }
    }

    public struct Memory: Hashable, Codable, Sendable {
        public enum Indexing: String, Hashable, Codable, Sendable { case offset, preIndex, postIndex }
        public let base: Register
        public let index: Register?
        public let modifier: RegisterModifier?
        public let displacement: Int64
        public let indexing: Indexing
        public let writeback: Bool
        public let displacementFormat: NumberFormat?
        public init(base: Register, index: Register? = nil, modifier: RegisterModifier? = nil,
                    displacement: Int64 = 0, indexing: Indexing = .offset, writeback: Bool = false,
                    displacementFormat: NumberFormat? = nil) {
            self.base = base; self.index = index; self.modifier = modifier
            self.displacement = displacement; self.indexing = indexing; self.writeback = writeback
            self.displacementFormat = displacementFormat
        }
    }

    public struct PCReference: Hashable, Codable, Sendable {
        public let baseAddress: UInt64
        public let displacement: Int64
        public let pageRelative: Bool
        public let format: NumberFormat
        public init(baseAddress: UInt64, displacement: Int64, pageRelative: Bool = false,
                    format: NumberFormat = .hexAddress) {
            self.baseAddress = baseAddress; self.displacement = displacement
            self.pageRelative = pageRelative; self.format = format
        }
        /// Recomputed after Codable transport: no stored or wrapped target can become authority.
        public var target: UInt64? {
            let base = pageRelative ? baseAddress & ~UInt64(0xfff) : baseAddress
            let result = displacement < 0
                ? base.subtractingReportingOverflow(displacement.magnitude)
                : base.addingReportingOverflow(UInt64(displacement))
            return result.overflow ? nil : result.partialValue
        }
        public var diagnostic: String? { target == nil ? "PC-relative target exceeds UInt64 address range" : nil }
    }

    public enum Condition: String, Hashable, Codable, Sendable {
        case eq, ne, hs, lo, mi, pl, vs, vc, hi, ls, ge, lt, gt, le, al, nv
    }
    public struct SystemRegister: Hashable, Codable, Sendable {
        /// op0:2, op1:3, CRn:4, CRm:4, op2:3, packed in that order.
        public let encoding: UInt16
        public let spelling: String?
        public init(encoding: UInt16, spelling: String? = nil) {
            self.encoding = encoding; self.spelling = spelling
        }
    }
    public struct Option: Hashable, Codable, Sendable {
        public enum Kind: String, Hashable, Codable, Sendable { case barrier, prefetch }
        public let kind: Kind
        public let value: UInt8
        public let spelling: String?
        public init(_ kind: Kind, value: UInt8, spelling: String? = nil) {
            self.kind = kind; self.value = value; self.spelling = spelling
        }
    }
    public enum Operand: Hashable, Codable, Sendable {
        case register(Register)
        case immediate(Immediate)
        case modifiedRegister(Register, RegisterModifier)
        case modifiedImmediate(Immediate, RegisterModifier)
        case memory(Memory)
        case registerList([Register])
        case pcRelative(PCReference)
        case condition(Condition)
        case systemRegister(SystemRegister)
        case option(Option)
        /// Unsupported text never qualifies as complete typed coverage.
        case opaque(String)
    }

    public struct Presentation: Hashable, Codable, Sendable {
        public let mnemonic: String?
        public let alias: String?
        public let numberFormat: NumberFormat
        public let omittedOperandIndices: [Int]
        public let omitZeroOffset: Bool
        public let registerListBraces: Bool
        public let conditionSuffixOperandIndex: Int?
        public init(mnemonic: String? = nil, alias: String? = nil, numberFormat: NumberFormat = .automatic,
                    omittedOperandIndices: [Int] = [], omitZeroOffset: Bool = true,
                    registerListBraces: Bool = true, conditionSuffixOperandIndex: Int? = nil) {
            self.mnemonic = mnemonic; self.alias = alias; self.numberFormat = numberFormat
            self.omittedOperandIndices = omittedOperandIndices; self.omitZeroOffset = omitZeroOffset
            self.registerListBraces = registerListBraces
            self.conditionSuffixOperandIndex = conditionSuffixOperandIndex
        }
    }
    public struct Semantics: Hashable, Codable, Sendable {
        public enum MemoryAccess: String, Hashable, Codable, Sendable { case read, write, readWrite }
        /// Width in bits of each memory access, independent of destination register or inferred type.
        public let memoryAccessWidth: Int?
        public let memoryAccess: MemoryAccess?
        public init(memoryAccessWidth: Int? = nil, memoryAccess: MemoryAccess? = nil) {
            self.memoryAccessWidth = memoryAccessWidth; self.memoryAccess = memoryAccess
        }
    }

    public let architecture: Architecture
    public let schemaVersion: Int
    public let coverage: Coverage
    public let opcodeClass: String?
    public let operands: [Operand]
    public let presentation: Presentation
    public let semantics: Semantics?
    public let legacyText: LegacyText?
    public init(architecture: Architecture = .arm64, schemaVersion: Int = 1, coverage: Coverage,
                opcodeClass: String? = nil, operands: [Operand] = [],
                presentation: Presentation = .init(), semantics: Semantics? = nil,
                legacyText: LegacyText? = nil) {
        self.architecture = architecture; self.schemaVersion = schemaVersion; self.coverage = coverage
        self.opcodeClass = opcodeClass; self.operands = operands; self.presentation = presentation
        self.semantics = semantics; self.legacyText = legacyText
    }
    public static func unavailable(mnemonic: String, operands: String,
                                   architecture: Architecture = .arm64) -> Self {
        .init(architecture: architecture, coverage: .unavailable, operands: [.opaque(operands)],
              presentation: .init(mnemonic: mnemonic),
              legacyText: .init(mnemonic: mnemonic, operands: operands))
    }
}
