import Foundation

public protocol DecompilerInstructionRow {
    var address: UInt64 { get }
    var bytes: String { get }
    var mnemonic: String { get }
    var operands: String { get }
    var comment: String? { get }
    var structuredOperands: InstructionOperands? { get }
}

public extension DecompilerInstructionRow {
    var structuredOperands: InstructionOperands? { nil }
}

extension InstructionRow: DecompilerInstructionRow {}

/// A function-entry transfer is not a decoded machine predecessor. Keeping
/// the distinction typed lets value proofs visit every input while address
/// consumers explicitly require a real machine edge.
public enum MacIRPhiPredecessor: Hashable, Sendable {
    case functionEntry
    case machine(UInt64)

    public var machineAddress: UInt64? {
        guard case let .machine(address) = self else { return nil }
        return address
    }
}

public struct MacIRPhiEdgeIdentity: Hashable, Sendable {
    public var blockAddress: UInt64
    public var predecessor: MacIRPhiPredecessor
    public var destination: MacIRValue

    public var machineAddress: UInt64? { predecessor.machineAddress }

    public init(blockAddress: UInt64, predecessor: MacIRPhiPredecessor, destination: MacIRValue) {
        self.blockAddress = blockAddress
        self.predecessor = predecessor
        self.destination = destination
    }

    public init(blockAddress: UInt64, predecessorAddress: UInt64, destination: MacIRValue) {
        self.init(blockAddress: blockAddress, predecessor: .machine(predecessorAddress), destination: destination)
    }
}

/// Ordered semantic effects of an independently proven direct tail transfer.
/// The architectural source remains B; only the synthetic return is post-call.
public struct MacIRTailCallEffect: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case call, returnAfterCall }
    public let targetAddress: UInt64
    public let targetName: String
    public let phase: Phase

    init(targetAddress: UInt64, targetName: String, phase: Phase) {
        self.targetAddress = targetAddress
        self.targetName = targetName
        self.phase = phase
    }
}

public struct MacIRSourceSpan: Hashable, Sendable {
    public var address: UInt64
    public var byteText: String
    public var mnemonic: String
    public var operands: String
    public var comment: String?
    public var structuredOperands: InstructionOperands?
    public var syntheticPhiEdge: MacIRPhiEdgeIdentity? = nil
    public var tailCallEffect: MacIRTailCallEffect? = nil

    public init(
        address: UInt64,
        byteText: String,
        mnemonic: String,
        operands: String,
        comment: String? = nil,
        structuredOperands: InstructionOperands? = nil
    ) {
        self.address = address
        self.byteText = byteText
        self.mnemonic = mnemonic
        self.operands = operands
        self.comment = comment
        self.structuredOperands = structuredOperands
    }

    public var addressText: String {
        "0x" + String(address, radix: 16, uppercase: false).leftPadded(to: 16, with: "0")
    }

    public var assemblyText: String {
        operands.isEmpty ? mnemonic : "\(mnemonic) \(operands)"
    }
}

public enum MacIRValue: Hashable, Sendable, CustomStringConvertible {
    case register(name: String, version: Int)
    case argument(bindingID: MacIRParameterBindingID)
    /// One carrier of an authored source object. The row identity remains shared
    /// across all fragments; byte offsets are in source-object order.
    case argumentFragment(rowID: MacIRParameterRowID, byteOffset: Int, size: Int)
    indirect case abiComposite(type: String, fragments: [MacIRValue])
    case immediate(Int64)
    case stackSlot(offset: Int64)
    case symbol(String)
    case temporary(Int)
    indirect case bitTest(value: MacIRValue, bit: Int64)
    indirect case unary(op: String, value: MacIRValue)
    indirect case binaryExpression(op: String, left: MacIRValue, right: MacIRValue)
    indirect case signedBitfield(MacIRSignedBitfield)
    case unknown(String)

    public var description: String {
        switch self {
        case let .register(name, version):
            "\(name)_\(version)"
        case let .argument(bindingID):
            bindingID.placeholderName
        case let .argumentFragment(rowID, byteOffset, size):
            "abi_fragment(\(rowID.rawValue), \(byteOffset), \(size))"
        case let .abiComposite(type, fragments):
            "abi_compose<\(type)>(\(fragments.map(\.description).joined(separator: ", ")))"
        case let .immediate(value):
            value < 0 ? "-0x\(String(value.magnitude, radix: 16))" : "0x\(String(value, radix: 16))"
        case let .stackSlot(offset):
            offset == 0 ? "stack[0x0]" : "stack[\(MacIRValue.immediate(offset))]"
        case let .symbol(name):
            name
        case let .temporary(index):
            "tmp_\(index)"
        case let .bitTest(value, bit):
            "((\(value) >> \(MacIRValue.immediate(bit))) & 0x1)"
        case let .unary(op, value):
            "\(op)\(value)"
        case let .binaryExpression(op, left, right):
            "\(left) \(op) \(right)"
        case let .signedBitfield(field):
            field.render(sourceText: field.source.signedFieldExpressionText)
        case let .unknown(text):
            text.isEmpty ? "unknown" : text
        }
    }

}

/// An admitted signed operation stored as an unsigned, width-bounded bit pattern.
public struct MacIRSignedBitfield: Hashable, Sendable {
    public struct Origin: Hashable, Sendable {
        public let functionName: String
        public let functionStart: UInt64
        public let instructionAddress: UInt64
        public let mnemonic: String
        public let sourceRegister: String
        public let destinationRegister: String
        public let definition: MacIRValue
        public let definitionBits: Int
    }

    public let source: MacIRValue
    public let operandBits: Int
    public let sourceLSB: Int64
    public let fieldBits: Int64
    public let insertLSB: Int64
    public let origin: Origin

    init?(source: MacIRValue, operandBits: Int?, sourceLSB: Int64,
          fieldBits: Int64, insertLSB: Int64, origin: Origin?) {
        guard let origin, !origin.functionName.isEmpty,
              let operandBits, operandBits == 32 || operandBits == 64,
              let readView = MacIRBuilder.integerRegisterView(origin.sourceRegister),
              let writeView = MacIRBuilder.integerRegisterView(origin.destinationRegister),
              readView.width == operandBits, writeView.width == operandBits,
              origin.definitionBits == 32 || origin.definitionBits == 64,
              fieldBits >= 1, fieldBits <= operandBits,
              sourceLSB >= 0, sourceLSB < operandBits,
              insertLSB >= 0, insertLSB < operandBits,
              fieldBits <= Int64(operandBits) - sourceLSB,
              fieldBits <= Int64(operandBits) - insertLSB,
              (origin.mnemonic == "sbfx" && insertLSB == 0)
                || (origin.mnemonic == "sbfiz" && sourceLSB == 0) else { return nil }
        switch origin.definition {
        case let .register(name, version):
            guard version > 0,
                  let view = MacIRBuilder.integerRegisterView(name),
                  view.index == readView.index, view.width == origin.definitionBits else { return nil }
        case let .argument(binding):
            guard binding.kind == .gpr, binding.value == readView.index else { return nil }
        case .argumentFragment:
            break
        default:
            return nil
        }
        let projected: MacIRValue
        if origin.definitionBits == operandBits {
            projected = origin.definition
        } else if origin.definitionBits == 32 {
            projected = .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: origin.definition))
        } else {
            projected = .unary(op: "(uint32_t)", value: origin.definition)
        }
        guard source == projected else { return nil }
        self.source = source
        self.operandBits = operandBits
        self.sourceLSB = sourceLSB
        self.fieldBits = fieldBits
        self.insertLSB = insertLSB
        self.origin = origin
    }

    var helperName: String { "mscope_\(origin.mnemonic)_bits_u\(operandBits)" }

    func render(sourceText: String) -> String {
        let offset = origin.mnemonic == "sbfx" ? sourceLSB : insertLSB
        return "\(helperName)(\(sourceText), \(offset), \(fieldBits))"
    }

    /// Counts have already been validated by the only initializer.
    func evaluatedBits(sourceBits: UInt64) -> UInt64 {
        let storageMask = operandBits == 64 ? UInt64.max : UInt64(UInt32.max)
        let mask = fieldBits == operandBits ? storageMask : (UInt64(1) << fieldBits) - 1
        let field = ((sourceBits & storageMask) >> sourceLSB) & mask
        let fill = (field & (UInt64(1) << (fieldBits - 1))) == 0 ? 0 : storageMask & ~mask
        return ((field | fill) << insertLSB) & storageMask
    }

    /// C helper storage and all arithmetic remain unsigned, including the 32-bit path.
    var helperDefinition: String {
        let offset = origin.mnemonic == "sbfx" ? "r" : "l"
        let select = origin.mnemonic == "sbfx" ? "r" : "0"
        let insert = origin.mnemonic == "sbfiz" ? "l" : "0"
        let mask = operandBits == 64 ? "UINT64_MAX" : "UINT64_C(0xffffffff)"
        return """
        static inline uint\(operandBits)_t \(helperName)(uint\(operandBits)_t source, unsigned \(offset), unsigned w) {
            if (w == 0 || w > \(operandBits) || \(offset) >= \(operandBits) || w > \(operandBits) - \(offset)) __builtin_trap();
            const uint64_t storage = \(mask);
            const uint64_t mask = w == \(operandBits) ? storage : (UINT64_C(1) << w) - UINT64_C(1);
            const uint64_t field = (((uint64_t)source & storage) >> \(select)) & mask;
            const uint64_t fill = (field & (UINT64_C(1) << (w - 1))) ? (storage & ~mask) : UINT64_C(0);
            return (uint\(operandBits)_t)(((field | fill) << \(insert)) & storage);
        }
        """
    }

    static func helperDefinitions(in function: MacIRFunction) -> [String] {
        var helpers: [String: String] = [:]
        func collect(_ value: MacIRValue) {
            switch value {
            case let .signedBitfield(field):
                helpers[field.helperName] = field.helperDefinition
                collect(field.source)
            case let .unary(_, value), let .bitTest(value, _): collect(value)
            case let .binaryExpression(_, left, right): collect(left); collect(right)
            case let .abiComposite(_, fragments): fragments.forEach(collect)
            default: break
            }
        }
        for instruction in function.instructions {
            switch instruction.operation {
            case let .assign(_, source): collect(source)
            case let .binary(_, _, left, right), let .compareToBool(_, _, left, right):
                collect(left); collect(right)
            case let .load(_, address): collect(address)
            case let .store(source, address): collect(source); collect(address)
            case let .loadWriteback(_, _, source, _, _): collect(source)
            case let .storeWriteback(source, _, base, _, _): collect(source); collect(base)
            case let .stackSlotRead(_, slot, value): collect(slot); collect(value)
            case let .stackSlotPairRead(_, a, b, _, c, d): [a, b, c, d].forEach(collect)
            case let .call(frame, _): frame.bindingValues.forEach(collect)
            case let .conditionalBranch(_, left, right, target): [left, right, target].forEach(collect)
            case let .select(_, _, a, b, c, d): [a, b, c, d].forEach(collect)
            case let .returnValue(value): if let value { collect(value) }
            case let .intrinsic(_, _, arguments): arguments.forEach(collect)
            case let .switchDispatch(index, _, target):
                collect(index)
                if let target { collect(target) }
            case let .unknown(_, inputs, _, _): inputs.mayRead.forEach { collect($0.value) }
            }
        }
        for phi in function.phis { phi.incoming.forEach { collect($0.value) } }
        guard !helpers.isEmpty else { return [] }
        return ["#include <stdint.h>"] + helpers.keys.sorted().compactMap { helpers[$0] }
    }
}

private extension MacIRValue {
    var signedFieldExpressionText: String {
        switch self {
        case let .unary(op, value): "\(op)(\(value.signedFieldExpressionText))"
        case let .binaryExpression(op, left, right):
            "(\(left.signedFieldExpressionText)) \(op) (\(right.signedFieldExpressionText))"
        default: description
        }
    }
}

public struct MacIRParameterBindingID: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case gpr
        case simd
        case entryStack
    }

    public let kind: Kind
    public let value: Int

    private init(kind: Kind, value: Int) {
        self.kind = kind
        self.value = value
    }

    public static func gpr(_ index: Int) -> Self {
        precondition((0..<8).contains(index), "GPR parameter bindings are limited to x0...x7")
        return Self(kind: .gpr, value: index)
    }

    public static func simd(_ index: Int) -> Self {
        precondition((0..<8).contains(index), "SIMD parameter bindings are limited to v0...v7")
        return Self(kind: .simd, value: index)
    }

    public static func entryStack(byteOffset: Int) -> Self {
        precondition(byteOffset >= 0, "entry-stack parameter offsets cannot be negative")
        return Self(kind: .entryStack, value: byteOffset)
    }

    public var placeholderName: String {
        switch kind {
        case .gpr:
            "in_x\(value)"
        case .simd:
            "in_d\(value)"
        case .entryStack:
            "in_stack_\(value)"
        }
    }

}

public enum MacIRABIUnboundReason: Hashable, Sendable {
    case unsupportedType(String)
    case registerExhausted
    case dependentOnUnsupportedEarlierParameter
    case conflictingEvidence
    case unresolvedLegacy
}

public enum MacIRABIParameterLocation: Hashable, Sendable {
    case gpr(index: Int, carrierWidth: Int)
    case simd(index: Int, scalarWidth: Int)
    case entryStack(byteOffset: Int, size: Int, alignment: Int)
    case unbound(reason: MacIRABIUnboundReason)

    public var bindingID: MacIRParameterBindingID? {
        switch self {
        case let .gpr(index, carrierWidth):
            guard (0..<8).contains(index), carrierWidth == 32 || carrierWidth == 64 else { return nil }
            return .gpr(index)
        case let .simd(index, scalarWidth):
            guard (0..<8).contains(index), scalarWidth == 32 || scalarWidth == 64 else { return nil }
            return .simd(index)
        case let .entryStack(byteOffset, size, alignment):
            guard byteOffset >= 0,
                  size > 0,
                  alignment > 0,
                  alignment.isPowerOfTwo,
                  byteOffset.isMultiple(of: alignment) else { return nil }
            return .entryStack(byteOffset: byteOffset)
        case .unbound:
            return nil
        }
    }

    fileprivate var registerSpelling: String {
        switch self {
        case let .gpr(index, carrierWidth):
            "\(carrierWidth == 32 ? "w" : "x")\(index)"
        case let .simd(index, scalarWidth):
            "\(scalarWidth == 32 ? "s" : "d")\(index)"
        case let .entryStack(byteOffset, _, _):
            "entry_sp+\(byteOffset)"
        case .unbound:
            "unbound"
        }
    }

    fileprivate var defaultParameterName: String {
        switch self {
        case let .gpr(index, carrierWidth):
            "in_\(carrierWidth == 32 ? "w" : "x")\(index)"
        case let .simd(index, scalarWidth):
            "in_\(scalarWidth == 32 ? "s" : "d")\(index)"
        case let .entryStack(byteOffset, _, _):
            "in_stack_\(byteOffset)"
        case .unbound:
            "unbound"
        }
    }
}

public enum MacIRParameterEvidence: Hashable, Sendable {
    case heuristicEntryRead
    case knownCallTypeConstraint
    case authoritativeDebug
    case authoritativeUser
    case unresolvedLegacy
    case legacyTransient
}

public struct MacIRParameterRowID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "parameter row identity cannot be empty")
        self.rawValue = rawValue
    }

    public static func recovered(_ bindingID: MacIRParameterBindingID) -> Self {
        let kind: String
        switch bindingID.kind {
        case .gpr: kind = "gpr"
        case .simd: kind = "simd"
        case .entryStack: kind = "entry-stack"
        }
        return Self(rawValue: "recovered:\(kind):\(bindingID.value)")
    }
}

public struct MacIRFunctionParameter: Identifiable, Hashable, Sendable {
    public let id: MacIRParameterRowID

    /// Transitional WS-14 compatibility only. Phase B removes consumers that
    /// interpret this value as either source order or a physical register slot.
    public var index: Int
    public private(set) var bindingID: MacIRParameterBindingID?
    public var sourcePosition: Int?
    public private(set) var abiLocation: MacIRABIParameterLocation
    public private(set) var richLocation: DarwinARM64RichParameterLocation?
    public private(set) var register: String
    public var type: String
    public var name: String
    public var evidence: MacIRParameterEvidence

    public init?(
        id: MacIRParameterRowID,
        bindingID: MacIRParameterBindingID?,
        sourcePosition: Int?,
        abiLocation: MacIRABIParameterLocation,
        richLocation: DarwinARM64RichParameterLocation? = nil,
        type: String,
        name: String? = nil,
        evidence: MacIRParameterEvidence
    ) {
        switch abiLocation {
        case .gpr, .simd:
            guard let bindingID, abiLocation.bindingID == bindingID else { return nil }
        case .entryStack:
            guard abiLocation.bindingID != nil,
                  bindingID == nil || abiLocation.bindingID == bindingID else { return nil }
        case .unbound:
            guard bindingID == nil else { return nil }
        }
        if let richLocation {
            guard case let .composite(pieces) = richLocation,
                  case .unbound = abiLocation else { return nil }
            let doubleHFA = [2, 4].contains(pieces.count) &&
                pieces.enumerated().allSatisfy { index, piece in
                    guard case .simd(_, 64) = piece.register else { return false }
                    return piece.valueByteOffset == index * 8 && piece.size == 8
                }
            let integerStruct = (1...2).contains(pieces.count) &&
                pieces.enumerated().allSatisfy { ordinal, piece in
                    guard case let .gpr(_, width) = piece.register,
                          width == 32 || width == 64 else { return false }
                    return piece.valueByteOffset == ordinal * 8 &&
                        piece.size > 0 && piece.size <= 8 &&
                        (ordinal == 0 || pieces[0].size == 8)
                }
            guard doubleHFA || integerStruct,
                  Set(pieces.map { $0.register.physicalKey }).count == pieces.count else { return nil }
        }
        self.id = id
        self.index = -1
        self.bindingID = bindingID
        self.sourcePosition = sourcePosition
        self.abiLocation = abiLocation
        self.richLocation = richLocation
        self.register = abiLocation.registerSpelling
        self.type = type
        self.name = name
            ?? sourcePosition.map { "arg\($0)" }
            ?? abiLocation.defaultParameterName
        self.evidence = evidence
    }

    @discardableResult
    public mutating func rebind(
        bindingID: MacIRParameterBindingID?,
        abiLocation: MacIRABIParameterLocation
    ) -> Bool {
        let generatedName = sourcePosition.map { "arg\($0)" }
            ?? self.abiLocation.defaultParameterName
        let shouldRefreshGeneratedName = name == generatedName
        switch abiLocation {
        case .gpr, .simd:
            guard let bindingID, abiLocation.bindingID == bindingID else { return false }
        case .entryStack:
            guard abiLocation.bindingID != nil,
                  bindingID == nil || abiLocation.bindingID == bindingID else { return false }
        case .unbound:
            guard bindingID == nil else { return false }
        }
        self.bindingID = bindingID
        self.abiLocation = abiLocation
        self.richLocation = nil
        self.register = abiLocation.registerSpelling
        if shouldRefreshGeneratedName {
            name = sourcePosition.map { "arg\($0)" } ?? abiLocation.defaultParameterName
        }
        return true
    }

    public init(index: Int, register: String, type: String, name: String? = nil) {
        self.index = index
        self.richLocation = nil
        let normalized = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let registerIndex = Self.registerIndex(normalized, prefixes: ["x", "w"]),
           (0..<8).contains(registerIndex) {
            let width = normalized.hasPrefix("w") ? 32 : 64
            self.bindingID = .gpr(registerIndex)
            self.abiLocation = .gpr(index: registerIndex, carrierWidth: width)
        } else if let registerIndex = Self.registerIndex(normalized, prefixes: ["d", "s"]),
                  (0..<8).contains(registerIndex) {
            let width = normalized.hasPrefix("s") ? 32 : 64
            self.bindingID = .simd(registerIndex)
            self.abiLocation = .simd(index: registerIndex, scalarWidth: width)
        } else {
            self.bindingID = nil
            self.abiLocation = .unbound(reason: .unresolvedLegacy)
        }
        self.id = self.bindingID.map(MacIRParameterRowID.recovered)
            ?? MacIRParameterRowID(rawValue: "legacy:\(index):\(normalized)")
        self.sourcePosition = nil
        self.register = register
        self.type = type
        self.name = name ?? "arg\(index)"
        self.evidence = .legacyTransient
    }

    private static func registerIndex(_ register: String, prefixes: Set<Character>) -> Int? {
        guard let prefix = register.first,
              prefixes.contains(prefix),
              register.count > 1 else {
            return nil
        }
        let suffix = register.dropFirst()
        guard suffix.allSatisfy(\.isNumber), suffix == "0" || suffix.first != "0" else {
            return nil
        }
        return Int(suffix)
    }
}

public struct MacIRAuthoritativeParameterPlan: Hashable, Sendable {
    public let parameters: [MacIRFunctionParameter]
    public let isVariadic: Bool

    public init?(parameters: [MacIRFunctionParameter], isVariadic: Bool) {
        guard parameters.allSatisfy({
            $0.evidence == .authoritativeUser || $0.evidence == .authoritativeDebug
        }) else {
            return nil
        }
        let positions = parameters.compactMap(\.sourcePosition)
        guard positions.count == parameters.count,
              positions == Array(parameters.indices) else {
            return nil
        }

        let bindings = parameters.compactMap(\.bindingID)
        guard Set(bindings).count == bindings.count else { return nil }
        var carriers: Set<String> = []
        for parameter in parameters {
            if let rich = parameter.richLocation,
               case let .composite(pieces) = rich {
                for piece in pieces where !carriers.insert(piece.register.physicalKey).inserted { return nil }
            } else {
                switch parameter.abiLocation {
                case let .gpr(index, width):
                    guard carriers.insert(DarwinARM64RichRegister.gpr(index: index, carrierWidth: width).physicalKey).inserted else { return nil }
                case let .simd(index, width):
                    guard carriers.insert(DarwinARM64RichRegister.simd(index: index, registerWidth: width).physicalKey).inserted else { return nil }
                case .entryStack, .unbound:
                    break
                }
            }
        }
        guard Set(parameters.map(\.id)).count == parameters.count else { return nil }
        guard parameters.allSatisfy({ parameter in
            switch parameter.abiLocation {
            case .gpr, .simd:
                return parameter.bindingID == parameter.abiLocation.bindingID
            case .entryStack:
                return parameter.bindingID == nil
            case .unbound:
                return parameter.bindingID == nil
            }
        }) else {
            return nil
        }

        self.parameters = parameters
        self.isVariadic = isVariadic
    }
}

private extension Int {
    var isPowerOfTwo: Bool {
        self > 0 && (self & (self - 1)) == 0
    }
}

public struct MacIRCallParameter: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var register: String
    public var type: String
    public var name: String

    public init(index: Int, register: String, type: String, name: String? = nil) {
        self.index = index
        self.register = register
        self.type = type
        self.name = name ?? "arg\(index)"
    }
}

public struct MacIRCallSignature: Identifiable, Hashable, Sendable {
    public var id: String { target }
    public var target: String
    public var returnType: String
    public var parameters: [MacIRCallParameter]
    public var isVariadic: Bool
    public var source: String
    /// HOP-5c: the callee's header `format` attribute when it describes this signature's
    /// variadic tail (see `CallFormatAttribute.describesVariadicTail`).
    public var format: CallFormatAttribute?

    public init(
        target: String,
        returnType: String,
        parameters: [MacIRCallParameter] = [],
        isVariadic: Bool = false,
        source: String = "known-import",
        format: CallFormatAttribute? = nil
    ) {
        self.target = target
        self.returnType = returnType
        self.parameters = parameters
        self.isVariadic = isVariadic
        self.source = source
        self.format = format
    }

    public var returnsVoid: Bool {
        returnType == "void"
    }

    public var declarationText: String {
        var parameterTexts = parameters.map { "\($0.type) \($0.name)" }
        if isVariadic {
            parameterTexts.append("...")
        }
        let parameterList = parameterTexts.isEmpty ? "void" : parameterTexts.joined(separator: ", ")
        return "\(returnType) \(target)(\(parameterList))"
    }
}

public enum MacIRCallArgumentPhysicalKey: Hashable, Sendable {
    case gpr(index: Int)
    case simd(index: Int)
    case callStack(byteOffset: Int)
}

public enum MacIRCallArgumentLocation: Hashable, Sendable {
    case gpr(index: Int, carrierWidth: Int)
    case simd(index: Int, scalarWidth: Int)
    case callStack(byteOffset: Int, size: Int, alignment: Int)

    public init?(register: String) {
        let normalized = register.lowercased()
        guard normalized.count == 2,
              let prefix = normalized.first,
              let index = Int(normalized.dropFirst()),
              String(index) == String(normalized.dropFirst()),
              (0..<8).contains(index) else {
            return nil
        }
        switch prefix {
        case "x": self = .gpr(index: index, carrierWidth: 64)
        case "w": self = .gpr(index: index, carrierWidth: 32)
        case "d": self = .simd(index: index, scalarWidth: 64)
        case "s": self = .simd(index: index, scalarWidth: 32)
        default: return nil
        }
    }

    public var physicalKey: MacIRCallArgumentPhysicalKey? {
        switch self {
        case let .gpr(index, carrierWidth):
            guard (0..<8).contains(index), carrierWidth == 32 || carrierWidth == 64 else {
                return nil
            }
            return .gpr(index: index)
        case let .simd(index, scalarWidth):
            guard (0..<8).contains(index), scalarWidth == 32 || scalarWidth == 64 else {
                return nil
            }
            return .simd(index: index)
        case let .callStack(byteOffset, _, _):
            guard validatedStackRange != nil else { return nil }
            return .callStack(byteOffset: byteOffset)
        }
    }

    public var registerName: String? {
        guard physicalKey != nil else { return nil }
        return switch self {
        case let .gpr(index, carrierWidth):
            "\(carrierWidth == 32 ? "w" : "x")\(index)"
        case let .simd(index, scalarWidth):
            "\(scalarWidth == 32 ? "s" : "d")\(index)"
        case .callStack:
            nil
        }
    }

    fileprivate var validatedStackRange: Range<Int>? {
        guard case let .callStack(byteOffset, size, alignment) = self,
              byteOffset >= 0,
              size > 0,
              alignment.isPowerOfTwo,
              byteOffset.isMultiple(of: alignment) else {
            return nil
        }
        let (end, overflow) = byteOffset.addingReportingOverflow(size)
        guard !overflow else { return nil }
        return byteOffset..<end
    }
}

public enum MacIRCallArgumentRole: Hashable, Sendable {
    case fixed(sourcePosition: Int)
    case anonymousVariadic(tailOrdinal: Int)
    case unknown

    public var sourcePosition: Int? {
        guard case let .fixed(sourcePosition) = self else { return nil }
        return sourcePosition
    }

    public var tailOrdinal: Int? {
        guard case let .anonymousVariadic(tailOrdinal) = self else { return nil }
        return tailOrdinal
    }
}

public struct MacIRCallSelectorEvidence: Hashable, Sendable {
    public let name: String
    public let selrefAddress: UInt64

    public init?(name: String, selrefAddress: UInt64) {
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
                      || CharacterSet.newlines.contains(scalar)
                      || scalar == "\""
                      || scalar == "\\"
              }) else {
            return nil
        }
        self.name = name
        self.selrefAddress = selrefAddress
    }
}

public struct MacIRCallArgument: Hashable, Sendable {
    public let location: MacIRCallArgumentLocation
    public let role: MacIRCallArgumentRole
    public let value: MacIRValue
    public let selectorEvidence: MacIRCallSelectorEvidence?

    public init(
        location: MacIRCallArgumentLocation,
        role: MacIRCallArgumentRole,
        value: MacIRValue,
        selectorEvidence: MacIRCallSelectorEvidence? = nil
    ) {
        self.location = location
        self.role = role
        self.value = value
        self.selectorEvidence = selectorEvidence
    }

    public var sourcePosition: Int? { role.sourcePosition }
    public var tailOrdinal: Int? { role.tailOrdinal }
}

public struct MacIRCallArgumentObservationScope: Hashable, Sendable {
    private let gprIndices: Set<Int>
    private let scalarSIMDIndices: Set<Int>
    private let callStackRanges: [Range<Int>]

    public init?(
        gprIndices: Set<Int> = [],
        scalarSIMDIndices: Set<Int> = [],
        callStackRanges: [Range<Int>] = []
    ) {
        guard gprIndices.allSatisfy({ (0..<8).contains($0) }),
              scalarSIMDIndices.allSatisfy({ (0..<8).contains($0) }) else {
            return nil
        }
        let canonicalRanges = callStackRanges.sorted {
            $0.lowerBound != $1.lowerBound
                ? $0.lowerBound < $1.lowerBound
                : $0.upperBound < $1.upperBound
        }
        var previous: Range<Int>?
        for range in canonicalRanges {
            guard range.lowerBound >= 0, range.lowerBound < range.upperBound else {
                return nil
            }
            if let previous, range.lowerBound < previous.upperBound {
                return nil
            }
            previous = range
        }
        self.init(
            validatedGPRIndices: gprIndices,
            validatedScalarSIMDIndices: scalarSIMDIndices,
            validatedCallStackRanges: canonicalRanges
        )
    }

    private init(
        validatedGPRIndices: Set<Int>,
        validatedScalarSIMDIndices: Set<Int>,
        validatedCallStackRanges: [Range<Int>]
    ) {
        gprIndices = validatedGPRIndices
        scalarSIMDIndices = validatedScalarSIMDIndices
        callStackRanges = validatedCallStackRanges
    }

    public static let none = Self(
        validatedGPRIndices: [],
        validatedScalarSIMDIndices: [],
        validatedCallStackRanges: []
    )

    public func observes(_ location: MacIRCallArgumentLocation) -> Bool {
        guard let key = location.physicalKey else { return false }
        switch key {
        case let .gpr(index):
            return gprIndices.contains(index)
        case let .simd(index):
            return scalarSIMDIndices.contains(index)
        case .callStack:
            guard let argumentRange = location.validatedStackRange else { return false }
            return callStackRanges.contains {
                $0.lowerBound <= argumentRange.lowerBound
                    && argumentRange.upperBound <= $0.upperBound
            }
        }
    }

    var canonicalGPRIndicesForAudit: [Int] { gprIndices.sorted() }
    var canonicalScalarSIMDIndicesForAudit: [Int] { scalarSIMDIndices.sorted() }
    var canonicalCallStackRangesForAudit: [Range<Int>] { callStackRanges }
}

public struct MacIRCallArguments: Hashable, Sendable {
    private let canonicalArguments: [MacIRCallArgument]
    public let observationScope: MacIRCallArgumentObservationScope

    public init?(
        _ arguments: [MacIRCallArgument],
        observationScope: MacIRCallArgumentObservationScope = .none
    ) {
        var physicalKeys: Set<MacIRCallArgumentPhysicalKey> = []
        var fixedPositions: Set<Int> = []
        var tailOrdinals: Set<Int> = []
        var stackRanges: [Range<Int>] = []
        var hasUnknown = false
        var hasKnown = false

        for argument in arguments {
            guard let physicalKey = argument.location.physicalKey,
                  physicalKeys.insert(physicalKey).inserted else {
                return nil
            }
            if argument.selectorEvidence != nil {
                guard physicalKey == .gpr(index: 1),
                      argument.role == .fixed(sourcePosition: 1) else {
                    return nil
                }
            }
            switch argument.role {
            case let .fixed(sourcePosition):
                guard sourcePosition >= 0,
                      fixedPositions.insert(sourcePosition).inserted else {
                    return nil
                }
                hasKnown = true
            case let .anonymousVariadic(tailOrdinal):
                guard tailOrdinal >= 0,
                      tailOrdinals.insert(tailOrdinal).inserted,
                      observationScope.observes(argument.location) else {
                    return nil
                }
                hasKnown = true
            case .unknown:
                guard observationScope.observes(argument.location) else { return nil }
                hasUnknown = true
            }
            if let stackRange = argument.location.validatedStackRange {
                stackRanges.append(stackRange)
            }
        }
        guard !(hasUnknown && hasKnown) else { return nil }

        stackRanges.sort {
            $0.lowerBound != $1.lowerBound
                ? $0.lowerBound < $1.lowerBound
                : $0.upperBound < $1.upperBound
        }
        for index in stackRanges.indices.dropFirst() {
            guard stackRanges[index].lowerBound >= stackRanges[index - 1].upperBound else {
                return nil
            }
        }

        canonicalArguments = arguments.sorted(by: Self.isCanonicallyOrderedBefore)
        self.observationScope = observationScope
    }

    public var count: Int { canonicalArguments.count }
    public var isEmpty: Bool { canonicalArguments.isEmpty }

    public func argument(at key: MacIRCallArgumentPhysicalKey) -> MacIRCallArgument? {
        switch key {
        case let .gpr(index), let .simd(index):
            guard (0..<8).contains(index) else { return nil }
        case let .callStack(byteOffset):
            guard byteOffset >= 0 else { return nil }
        }
        return canonicalArguments.first { $0.location.physicalKey == key }
    }

    public func fixedArgument(at sourcePosition: Int) -> MacIRCallArgument? {
        guard sourcePosition >= 0 else { return nil }
        return canonicalArguments.first { $0.sourcePosition == sourcePosition }
    }

    public func denseFixedPrefixValues() -> [MacIRValue] {
        var values: [MacIRValue] = []
        for sourcePosition in 0..<canonicalArguments.count {
            guard let argument = fixedArgument(at: sourcePosition) else { break }
            values.append(argument.value)
        }
        return values
    }

    public func denseUnknownGPRPrefixValues() -> [MacIRValue]? {
        guard canonicalArguments.allSatisfy({ $0.role == .unknown }),
              canonicalArguments.allSatisfy({
                  if case .gpr = $0.location { return true }
                  return false
              }),
              observationScope.canonicalScalarSIMDIndicesForAudit.isEmpty,
              observationScope.canonicalCallStackRangesForAudit.isEmpty,
              observationScope.observes(.gpr(index: 0, carrierWidth: 64)) else {
            return nil
        }

        var values: [MacIRValue] = []
        for index in 0..<8 {
            let location = MacIRCallArgumentLocation.gpr(index: index, carrierWidth: 64)
            guard observationScope.observes(location),
                  let argument = argument(at: .gpr(index: index)) else {
                break
            }
            values.append(argument.value)
        }
        return values
    }

    func completeKnownVariadicValues(
        fixedCount: Int,
        expectedTailCount: Int
    ) -> [MacIRValue]? {
        guard fixedCount >= 0,
              expectedTailCount >= 0,
              !canonicalArguments.contains(where: { $0.role == .unknown }) else {
            return nil
        }
        let fixed = canonicalArguments.filter { $0.sourcePosition != nil }
        let tail = canonicalArguments.filter { $0.tailOrdinal != nil }
        guard fixed.count == fixedCount, tail.count == expectedTailCount else { return nil }

        var values: [MacIRValue] = []
        for sourcePosition in 0..<fixedCount {
            guard let argument = fixedArgument(at: sourcePosition) else { return nil }
            values.append(argument.value)
        }
        for tailOrdinal in 0..<expectedTailCount {
            guard let argument = tail.first(where: { $0.tailOrdinal == tailOrdinal }) else {
                return nil
            }
            values.append(argument.value)
        }
        return values
    }

    func forEachPhysicalArgument(
        _ body: (MacIRCallArgument) throws -> Void
    ) rethrows {
        for argument in canonicalArguments {
            try body(argument)
        }
    }

    var bindingValues: [MacIRValue] { canonicalArguments.map(\.value) }
    var canonicalPhysicalEntriesForAudit: [MacIRCallArgument] { canonicalArguments }

    private static func isCanonicallyOrderedBefore(
        _ lhs: MacIRCallArgument,
        _ rhs: MacIRCallArgument
    ) -> Bool {
        switch (lhs.location, rhs.location) {
        case let (.gpr(leftIndex, _), .gpr(rightIndex, _)):
            return leftIndex < rightIndex
        case (.gpr, _):
            return true
        case (_, .gpr):
            return false
        case let (.simd(leftIndex, _), .simd(rightIndex, _)):
            return leftIndex < rightIndex
        case (.simd, .callStack):
            return true
        case (.callStack, .simd):
            return false
        case let (
            .callStack(leftOffset, leftSize, leftAlignment),
            .callStack(rightOffset, rightSize, rightAlignment)
        ):
            if leftOffset != rightOffset { return leftOffset < rightOffset }
            if leftSize != rightSize { return leftSize < rightSize }
            return leftAlignment < rightAlignment
        }
    }
}

public enum MacIRCallControlInputRole: Hashable, Sendable {
    case indirectTarget
    case pointerAuthenticationModifier
}

public enum MacIRCallControlRegister: Hashable, Sendable {
    case gpr(index: Int)
    case stackPointer

    public init?(register: String) {
        let normalized = register.lowercased()
        if normalized == "sp" {
            self = .stackPointer
            return
        }
        guard normalized.first == "x",
              normalized.count > 1,
              let index = Int(normalized.dropFirst()),
              String(index) == String(normalized.dropFirst()),
              (0...30).contains(index) else {
            return nil
        }
        self = .gpr(index: index)
    }

    public var registerName: String? {
        switch self {
        case let .gpr(index):
            guard (0...30).contains(index) else { return nil }
            return "x\(index)"
        case .stackPointer:
            return "sp"
        }
    }

    public var argumentPhysicalKey: MacIRCallArgumentPhysicalKey? {
        guard case let .gpr(index) = self, (0..<8).contains(index) else { return nil }
        return .gpr(index: index)
    }
}

public struct MacIRCallControlInput: Hashable, Sendable {
    public let role: MacIRCallControlInputRole
    public let register: MacIRCallControlRegister
    public let value: MacIRValue

    public init(
        role: MacIRCallControlInputRole,
        register: MacIRCallControlRegister,
        value: MacIRValue
    ) {
        self.role = role
        self.register = register
        self.value = value
    }
}

public struct MacIRCallControlInputs: Hashable, Sendable {
    private let canonicalInputs: [MacIRCallControlInput]

    public init?(_ inputs: [MacIRCallControlInput]) {
        var roles: Set<MacIRCallControlInputRole> = []
        for input in inputs {
            guard input.register.registerName != nil,
                  roles.insert(input.role).inserted else {
                return nil
            }
            if input.role == .indirectTarget, input.register == .stackPointer {
                return nil
            }
        }
        guard !roles.contains(.pointerAuthenticationModifier)
                || roles.contains(.indirectTarget) else {
            return nil
        }
        if let target = inputs.first(where: { $0.role == .indirectTarget }),
           let modifier = inputs.first(where: { $0.role == .pointerAuthenticationModifier }),
           target.register == modifier.register,
           target.value != modifier.value {
            return nil
        }
        canonicalInputs = inputs.sorted {
            if $0.role == $1.role { return false }
            return $0.role == .indirectTarget
        }
    }

    private init(validatedInputs: [MacIRCallControlInput]) {
        canonicalInputs = validatedInputs
    }

    public static let none = Self(validatedInputs: [])

    public var indirectTarget: MacIRCallControlInput? {
        canonicalInputs.first { $0.role == .indirectTarget }
    }

    public var pointerAuthenticationModifier: MacIRCallControlInput? {
        canonicalInputs.first { $0.role == .pointerAuthenticationModifier }
    }

    public var excludedArgumentKeys: Set<MacIRCallArgumentPhysicalKey> {
        Set(canonicalInputs.compactMap(\.register.argumentPhysicalKey))
    }

    var bindingValues: [MacIRValue] { canonicalInputs.map(\.value) }
    var canonicalControlInputsForAudit: [MacIRCallControlInput] { canonicalInputs }
}

/// HOP-5c: a constant string the analysis resolved at a virtual address, as the builder may
/// see it materialized into a register (`adrp`+`add`, or `adr`).
public struct MacIRConstantString: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A NUL-terminated C string (`__TEXT,__cstring`, or any string the analysis resolved).
        case cString
        /// A constant `CFString`/`NSConstantString` object (`__DATA*,__cfstring`); the address
        /// is the object's, the text its contents.
        case cfString
    }

    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// HOP-5c: a call's variadic tail recovered from its constant format string. Recorded on the
/// frame so the tail's provenance (`formatString`), the format text and its address stay
/// auditable next to the arguments it justified.
public struct MacIRCallFormatStringEvidence: Hashable, Sendable {
    public static let provenance = "formatString"

    /// The callee's `format` attribute archetype (`printf`, `NSString`, ...).
    public let kind: String
    /// 0-based source position of the format parameter.
    public let formatSourcePosition: Int
    public let format: String
    public let formatAddress: UInt64
    public let formatStringKind: MacIRConstantString.Kind
    /// Promoted C types of the anonymous arguments, in order.
    public let argumentTypes: [String]

    public init(
        kind: String,
        formatSourcePosition: Int,
        format: String,
        formatAddress: UInt64,
        formatStringKind: MacIRConstantString.Kind,
        argumentTypes: [String]
    ) {
        self.kind = kind
        self.formatSourcePosition = formatSourcePosition
        self.format = format
        self.formatAddress = formatAddress
        self.formatStringKind = formatStringKind
        self.argumentTypes = argumentTypes
    }

    /// Apple arm64 variadic ABI: every anonymous argument is passed on the stack, never in
    /// x1-x7/v0-v7 (unlike AAPCS64), one 8-byte-aligned 8-byte slot per argument in order.
    public static func tailLocation(ordinal: Int) -> MacIRCallArgumentLocation {
        .callStack(
            byteOffset: ordinal * FormatStringParser.stackSlotSize,
            size: FormatStringParser.stackSlotSize,
            alignment: FormatStringParser.stackSlotSize
        )
    }

    /// The literal as it should read in pseudocode (`"%d\n"`, or `@"..."` for a CFString).
    public var renderedLiteral: String {
        var escaped = ""
        for scalar in format.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    escaped += String(format: "\\x%02x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return formatStringKind == .cfString ? "@\"\(escaped)\"" : "\"\(escaped)\""
    }
}

public enum MacIRCallTailCountEvidence: Hashable, Sendable {
    case objectiveCSelectorColonCount(Int)
    /// HOP-5c: the tail count and types come from the call's constant format string.
    case formatString(MacIRCallFormatStringEvidence)

    public var expectedTailCount: Int {
        switch self {
        case let .objectiveCSelectorColonCount(count):
            count
        case let .formatString(evidence):
            evidence.argumentTypes.count
        }
    }
}

public struct MacIRRichCallPiece: Hashable, Sendable {
    public let register: DarwinARM64RichRegister
    public let valueByteOffset: Int
    public let size: Int
    public let value: MacIRValue
}

private extension DarwinARM64RichRegister {
    var physicalKey: String {
        switch self {
        case let .gpr(index, _): "gpr:\(index)"
        case let .simd(index, _): "simd:\(index)"
        }
    }
}

/// One source argument owns every physical HFA carrier in source-object order.
public struct MacIRRichCallArgument: Hashable, Sendable {
    public let rowID: MacIRParameterRowID
    public let sourcePosition: Int
    public let type: String
    public let pieces: [MacIRRichCallPiece]

    public var value: MacIRValue {
        .abiComposite(type: type, fragments: pieces.map(\.value))
    }
}

public struct MacIRCallFrame: Hashable, Sendable {
    public let target: String
    public let knownSignature: MacIRCallSignature?
    /// A proven slot contract is not a resolved direct target.
    public let typedIndirectSignature: MacIRCallSignature?
    public let typedIndirectCalleeType: String?
    public let tailCountEvidence: MacIRCallTailCountEvidence?
    public let controlInputs: MacIRCallControlInputs
    public let arguments: MacIRCallArguments
    public let richArguments: [MacIRRichCallArgument]?
    public let indirectResultPointer: MacIRValue?
    /// Builder-proven positional prefix for calls without parameter authority.
    /// Nil preserves frames explicitly authored by other clients. Observations
    /// above this prefix remain in `arguments` for audit, not source arity.
    public let unknownArgumentCount: Int?
    // Validated presentation keys only; canonical values and call effects are unchanged.
    private var machineResolvedArgumentRegisters: Set<Int> = []
    private var machinePromotedArgumentRegisters: Set<Int> = []

    public var unprovenArgumentRegisters: [String] {
        guard let count = unknownArgumentCount else { return [] }
        return arguments.canonicalPhysicalEntriesForAudit.compactMap { argument in
            guard case let .gpr(index, _) = argument.location, index >= count,
                  !machineResolvedArgumentRegisters.contains(index) else { return nil }
            return "x\(index)"
        }
    }

    func applyingMachineUsage(_ usage: MacIRMachineCallUsage?,
                              expectedContext: MacIRMachineUsageContext?,
                              originalCaller: [MacIRSourceSpan],
                              callAddress: UInt64?) -> Self {
        guard machineResolvedArgumentRegisters.isEmpty, machinePromotedArgumentRegisters.isEmpty,
              let usage, usage.matches(expected: expectedContext, originalCaller: originalCaller),
              let callAddress, let row = originalCaller.first(where: { $0.address == callAddress }),
              let selection = usage.selection(at: callAddress, originalCall: row, frame: self) else { return self }
        var result = self
        result.machineResolvedArgumentRegisters = selection.resolved
        result.machinePromotedArgumentRegisters = selection.promoted
        return result
    }

    // Nil retains the old dense spelling; adding a value switches the entire list
    // to physical-keyed pseudocode, not a compacted source-parameter list.
    var machineRenderArguments: [MacIRCallArgument]? {
        guard !machinePromotedArgumentRegisters.isEmpty, let count = unknownArgumentCount else { return nil }
        let existing = (0..<count).compactMap { arguments.argument(at: .gpr(index: $0)) }
        let promoted = machinePromotedArgumentRegisters.sorted().compactMap { arguments.argument(at: .gpr(index: $0)) }
        guard existing.count == count, promoted.count == machinePromotedArgumentRegisters.count else { return nil }
        return (existing + promoted).sorted {
            guard case let .gpr(left, _) = $0.location, case let .gpr(right, _) = $1.location else { return false }
            return left < right
        }
    }

    public func unknownRenderValues() -> [MacIRValue] {
        guard let count = unknownArgumentCount else {
            return arguments.denseUnknownGPRPrefixValues() ?? []
        }
        return (0..<count).map { index in
            arguments.argument(at: .gpr(index: index))?.value ?? .unknown("x\(index)")
        }
    }

    public init?(
        target: String,
        knownSignature: MacIRCallSignature?,
        tailCountEvidence: MacIRCallTailCountEvidence? = nil,
        controlInputs: MacIRCallControlInputs,
        arguments: MacIRCallArguments,
        richArguments: [MacIRRichCallArgument]? = nil,
        indirectResultPointer: MacIRValue? = nil,
        typedIndirectSignature: MacIRCallSignature? = nil,
        typedIndirectCalleeType: String? = nil,
        unknownArgumentCount: Int? = nil
    ) {
        guard !target.isEmpty,
              target == target.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }

        if let indirectTarget = controlInputs.indirectTarget {
            guard knownSignature == nil,
                  let registerName = indirectTarget.register.registerName,
                  target == "(*\(registerName))" else {
                return nil
            }
        } else if Self.isComputedTarget(target) {
            return nil
        }

        if let signature = typedIndirectSignature {
            guard knownSignature == nil, controlInputs.indirectTarget != nil,
                  signature.target == target, signature.source == "header-derived-slot",
                  !signature.isVariadic, signature.format == nil,
                  tailCountEvidence == nil, richArguments == nil,
                  indirectResultPointer == nil,
                  let cast = typedIndirectCalleeType, !cast.isEmpty,
                  Self.hasCanonicalParameterLayout(signature.parameters) else { return nil }
        } else if typedIndirectCalleeType != nil { return nil }
        let entries = arguments.canonicalPhysicalEntriesForAudit
        if let signature = typedIndirectSignature {
            guard entries.count == signature.parameters.count,
                  signature.parameters.count <= 8,
                  signature.parameters.allSatisfy({ parameter in
                      guard let location = MacIRCallArgumentLocation(register: parameter.register),
                            case let .gpr(index, _) = location else { return false }
                      return index == parameter.index
                  }) else { return nil }
        }
        if let richArguments {
            guard knownSignature == nil, tailCountEvidence == nil, entries.isEmpty,
                  richArguments.map(\.sourcePosition) == Array(richArguments.indices),
                  Set(richArguments.map(\.rowID)).count == richArguments.count else { return nil }
            var carrierKeys: Set<String> = []
            for argument in richArguments {
                guard !argument.pieces.isEmpty,
                      argument.pieces.map(\.valueByteOffset) == argument.pieces.map(\.valueByteOffset).sorted(),
                      argument.pieces.first?.valueByteOffset == 0 else { return nil }
                var next = 0
                for piece in argument.pieces {
                    guard piece.size > 0, piece.valueByteOffset == next,
                          carrierKeys.insert(piece.register.physicalKey).inserted else { return nil }
                    next += piece.size
                }
            }
        }
        if let knownSignature = knownSignature ?? typedIndirectSignature {
            guard knownSignature.target == target,
                  Self.hasCanonicalParameterLayout(knownSignature.parameters),
                  entries.allSatisfy({ $0.role != .unknown }),
                  Self.rolesAreCompatible(
                      entries,
                      observationScope: arguments.observationScope,
                      with: knownSignature,
                      tailCountEvidence: tailCountEvidence
                  ) else {
                return nil
            }
        } else {
            guard tailCountEvidence == nil,
                  entries.allSatisfy({ $0.role == .unknown }) else {
                return nil
            }
        }

        // Explicit ABI arguments may share a control register; unknown observations may not.
        let excludedKeys = typedIndirectSignature == nil ? controlInputs.excludedArgumentKeys : []
        guard excludedKeys.isDisjoint(with: Set(
            entries.compactMap(\.location.physicalKey)
        )) else {
            return nil
        }
        let excludedGPRIndices = Set(excludedKeys.compactMap { key -> Int? in
            guard case let .gpr(index) = key else { return nil }
            return index
        })
        guard excludedGPRIndices.isDisjoint(
            with: Set(arguments.observationScope.canonicalGPRIndicesForAudit)
        ) else {
            return nil
        }
        if let count = unknownArgumentCount {
            guard (0...8).contains(count), knownSignature == nil,
                  typedIndirectSignature == nil, richArguments == nil else { return nil }
        }
        // Keep a redundant prefix canonical with existing explicitly authored
        // frames. Store an override only for forced gaps or omitted carriers.
        if let count = unknownArgumentCount,
           arguments.denseUnknownGPRPrefixValues()?.count == count,
           entries.count == count {
            self.unknownArgumentCount = nil
        } else {
            self.unknownArgumentCount = unknownArgumentCount
        }
        self.target = target
        self.knownSignature = knownSignature
        self.typedIndirectSignature = typedIndirectSignature
        self.typedIndirectCalleeType = typedIndirectCalleeType
        self.tailCountEvidence = tailCountEvidence
        self.controlInputs = controlInputs
        self.arguments = arguments
        self.richArguments = richArguments
        self.indirectResultPointer = indirectResultPointer
    }

    var bindingValues: [MacIRValue] {
        controlInputs.bindingValues + arguments.bindingValues
            + (richArguments?.flatMap { $0.pieces.map(\.value) } ?? [])
            + (indirectResultPointer.map { [$0] } ?? [])
    }

    public var expectedTailCount: Int? {
        tailCountEvidence?.expectedTailCount
    }

    func completeKnownVariadicRenderValues() -> [MacIRValue]? {
        guard let knownSignature, let expectedTailCount else { return nil }
        guard let rawValues = arguments.completeKnownVariadicValues(
            fixedCount: knownSignature.parameters.count,
            expectedTailCount: expectedTailCount
        ) else { return nil }
        return applyingFormatPresentation(to: applyingSelectorPresentation(to: rawValues))
    }

    func denseFixedRenderValues() -> [MacIRValue] {
        applyingSelectorPresentation(to: arguments.denseFixedPrefixValues())
    }

    /// HOP-5c: renders the resolved format argument as its string literal.
    private func applyingFormatPresentation(
        to rawValues: [MacIRValue]
    ) -> [MacIRValue] {
        guard case let .formatString(evidence) = tailCountEvidence,
              rawValues.indices.contains(evidence.formatSourcePosition) else {
            return rawValues
        }
        var renderedValues = rawValues
        renderedValues[evidence.formatSourcePosition] = .symbol(evidence.renderedLiteral)
        return renderedValues
    }

    private func applyingSelectorPresentation(
        to rawValues: [MacIRValue]
    ) -> [MacIRValue] {
        guard rawValues.indices.contains(1),
              let selectorArgument = arguments.fixedArgument(at: 1),
              selectorArgument.location == .gpr(index: 1, carrierWidth: 64),
              let selectorEvidence = selectorArgument.selectorEvidence else {
            return rawValues
        }
        var renderedValues = rawValues
        renderedValues[1] = .symbol("\"\(selectorEvidence.name)\"")
        return renderedValues
    }

    private static func isComputedTarget(_ target: String) -> Bool {
        target.hasPrefix("(*")
    }

    private static func hasCanonicalParameterLayout(
        _ parameters: [MacIRCallParameter]
    ) -> Bool {
        guard parameters.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
            return false
        }
        var physicalKeys: Set<MacIRCallArgumentPhysicalKey> = []
        for parameter in parameters {
            guard let location = MacIRCallArgumentLocation(register: parameter.register),
                  let key = location.physicalKey else {
                continue
            }
            guard physicalKeys.insert(key).inserted else { return false }
        }
        return true
    }

    private static func rolesAreCompatible(
        _ entries: [MacIRCallArgument],
        observationScope: MacIRCallArgumentObservationScope,
        with signature: MacIRCallSignature,
        tailCountEvidence: MacIRCallTailCountEvidence?
    ) -> Bool {
        let selectorEntries = entries.filter { $0.selectorEvidence != nil }
        let formatEvidence: MacIRCallFormatStringEvidence? = {
            guard case let .formatString(evidence) = tailCountEvidence else { return nil }
            return evidence
        }()
        if formatEvidence != nil {
            guard selectorEntries.isEmpty else { return false }
        } else {
            guard selectorEntries.isEmpty == (tailCountEvidence == nil) else {
                return false
            }
        }
        let parametersByIndex = Dictionary(
            uniqueKeysWithValues: signature.parameters.map { ($0.index, $0) }
        )
        for entry in entries {
            switch entry.role {
            case let .fixed(sourcePosition):
                guard let parameter = parametersByIndex[sourcePosition],
                      let expectedLocation = MacIRCallArgumentLocation(
                          register: parameter.register
                      ),
                      entry.location == expectedLocation else {
                    return false
                }
            case let .anonymousVariadic(tailOrdinal):
                // A selector colon count proves source arity, but it cannot prove that
                // one source argument occupies one 64-bit GPR (aggregates, SIMD values,
                // and stack arguments are counterexamples), so Objective-C tails stay
                // rejected. HOP-5c: a parsed constant format string proves both the
                // count and each promoted scalar type, and Apple arm64 passes every
                // anonymous argument in its own 8-byte stack slot, so the location of
                // tail ordinal `n` is fixed.
                guard let formatEvidence,
                      tailOrdinal < formatEvidence.argumentTypes.count,
                      entry.location == MacIRCallFormatStringEvidence.tailLocation(
                          ordinal: tailOrdinal
                      ) else {
                    return false
                }
            case .unknown:
                return false
            }
        }

        guard let tailCountEvidence else {
            return !entries.contains { $0.tailOrdinal != nil }
        }
        guard signature.isVariadic else { return false }

        switch tailCountEvidence {
        case let .formatString(evidence):
            let tailCount = entries.filter { $0.tailOrdinal != nil }.count
            guard let format = signature.format,
                  format.describesVariadicTail(fixedParameterCount: signature.parameters.count),
                  evidence.kind == format.kind,
                  evidence.formatSourcePosition == format.formatIndex - 1,
                  entries.contains(where: {
                      $0.role == .fixed(sourcePosition: evidence.formatSourcePosition)
                  }),
                  tailCount == evidence.argumentTypes.count,
                  observationScope.canonicalScalarSIMDIndicesForAudit.isEmpty,
                  observationScope.canonicalGPRIndicesForAudit.isEmpty else {
                return false
            }
            return true
        case let .objectiveCSelectorColonCount(count):
            guard count >= 0 else { return false }
            guard signature.target == "_objc_msgSend" || signature.target == "objc_msgSend",
                  signature.parameters.count == 2,
                  MacIRCallArgumentLocation(register: signature.parameters[0].register)
                      == .gpr(index: 0, carrierWidth: 64),
                  MacIRCallArgumentLocation(register: signature.parameters[1].register)
                      == .gpr(index: 1, carrierWidth: 64),
                  let selector = entries.first(where: {
                      $0.location.physicalKey == .gpr(index: 1)
                          && $0.role == .fixed(sourcePosition: 1)
                          && $0.selectorEvidence != nil
                  })?.selectorEvidence,
                  selector.name.unicodeScalars.filter({ $0 == ":" }).count == count,
                  observationScope == .none,
                  entries.allSatisfy({ $0.tailOrdinal == nil }) else {
                return false
            }
            return true
        }
    }
}

/// DP04 B2: the canonical stack storage a local occupies, in entry-SP coordinates.
public struct MacIRStackStorage: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable {
        case incomingArgument
        case savedRegister
        case candidateLocal
    }

    /// Versioned, deterministic identity (`macir-stack-v1:…`): function start, the
    /// storage region's entry-SP byte range, and the lifetime's defining store.
    public let identity: String
    /// The local's own bytes, relative to SP at function entry.
    public let entryRange: Range<Int64>
    /// The enclosing storage region's bytes, relative to SP at function entry.
    public let regionRange: Range<Int64>
    public let role: Role
    public let escapes: Bool

    /// DP04 C1: the durable key a user edit is stored under — the entry-SP byte range
    /// only (`"-24:-16"`). The lifetime anchor is deliberately excluded so an edit
    /// survives re-analysis; a key that matches no local is an orphan, never retargeted.
    public var authoringKey: String { Self.authoringKey(for: entryRange) }

    public static func authoringKey(for range: Range<Int64>) -> String {
        "\(range.lowerBound):\(range.upperBound)"
    }

    /// The entry-SP range an authoring key names; nil for a malformed or empty range.
    public static func entryRange(forAuthoringKey key: String) -> Range<Int64>? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int64(parts[0]), let upper = Int64(parts[1]),
              lower < upper else { return nil }
        let (extent, overflow) = upper.subtractingReportingOverflow(lower)
        guard !overflow, extent <= 4_096 else { return nil }
        return lower..<upper
    }
}

public struct MacIRLocalVariable: Identifiable, Hashable, Sendable {
    public var id: Int64 { offset }
    public var offset: Int64
    public var name: String
    public var type: String
    public var byteWidth: Int
    /// DP04 B2: region identity, when frame analysis proved it. Not part of
    /// equality or hashing, so offset-keyed callers and expectations are unchanged.
    public var stackStorage: MacIRStackStorage?
    /// The row that defined this local's current extent (the builder's offset
    /// coordinates are mapped to entry SP through it). Not part of equality.
    var definingAddress: UInt64?
    /// Memory-transfer element at that row, retained even when another pair
    /// element was promoted earlier. Not part of equality or hashing.
    var definingAccessIndex: Int?

    public init(offset: Int64, name: String? = nil, type: String, byteWidth: Int) {
        self.offset = offset
        self.name = name ?? Self.defaultName(forOffset: offset)
        self.type = type
        self.byteWidth = byteWidth
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offset == rhs.offset && lhs.name == rhs.name && lhs.type == rhs.type && lhs.byteWidth == rhs.byteWidth
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(offset)
        hasher.combine(name)
        hasher.combine(type)
        hasher.combine(byteWidth)
    }

    public static func defaultName(forOffset offset: Int64) -> String {
        let magnitude = String(abs(offset), radix: 16, uppercase: false)
        return offset < 0 ? "local_neg_\(magnitude)" : "local_\(magnitude)"
    }
}

public enum MacIRNameBindingKind: String, Hashable, Sendable {
    case stackLocal
    case registerTemporary
}

public enum MacIRNameBindingTarget: Hashable, Sendable {
    case stackSlot(offset: Int64)
    case register(name: String, version: Int)

    public var stableID: String {
        switch self {
        case let .stackSlot(offset):
            "stack:\(offset)"
        case let .register(name, version):
            "register:\(name.lowercased()):\(version)"
        }
    }
}

public struct MacIRNameBinding: Identifiable, Hashable, Sendable {
    public var id: String { target.stableID }
    public var target: MacIRNameBindingTarget
    public var name: String
    public var type: String?
    public var kind: MacIRNameBindingKind

    public init(
        target: MacIRNameBindingTarget,
        name: String,
        type: String? = nil,
        kind: MacIRNameBindingKind
    ) {
        self.target = target
        self.name = name
        self.type = type
        self.kind = kind
    }
}

public struct MacIRSwitchCase: Hashable, Sendable {
    public var value: Int64
    public var target: MacIRValue

    public init(value: Int64, target: MacIRValue) {
        self.value = value
        self.target = target
    }
}

public enum MacIROperation: Hashable, Sendable {
    case assign(destination: MacIRValue, source: MacIRValue)
    case binary(destination: MacIRValue, op: String, left: MacIRValue, right: MacIRValue)
    case load(destination: MacIRValue, address: MacIRValue)
    case store(source: MacIRValue, address: MacIRValue)
    case loadWriteback(
        destination: MacIRValue,
        baseDestination: MacIRValue,
        baseSource: MacIRValue,
        delta: Int64,
        preIndex: Bool
    )
    case storeWriteback(
        source: MacIRValue,
        baseDestination: MacIRValue,
        baseSource: MacIRValue,
        delta: Int64,
        preIndex: Bool
    )
    case stackSlotRead(destination: MacIRValue, slot: MacIRValue, value: MacIRValue)
    case stackSlotPairRead(
        firstDestination: MacIRValue,
        firstSlot: MacIRValue,
        firstValue: MacIRValue,
        secondDestination: MacIRValue,
        secondSlot: MacIRValue,
        secondValue: MacIRValue
    )
    case call(frame: MacIRCallFrame, result: MacIRValue?)
    case conditionalBranch(condition: String, left: MacIRValue, right: MacIRValue, target: MacIRValue)
    case select(
        destination: MacIRValue,
        condition: String,
        left: MacIRValue,
        right: MacIRValue,
        trueValue: MacIRValue,
        falseValue: MacIRValue
    )
    case compareToBool(destination: MacIRValue, condition: String, left: MacIRValue, right: MacIRValue)
    case returnValue(MacIRValue?)
    case intrinsic(destination: MacIRValue?, name: String, arguments: [MacIRValue])
    case switchDispatch(index: MacIRValue, cases: [MacIRSwitchCase], defaultTarget: MacIRValue?)
    /// An instruction the lifter cannot model. `destination` is non-nil only
    /// when the instruction definitely overwrites a scalar GPR: the builder
    /// claims that register (fresh SSA version) so downstream reads bind to
    /// the unknown's result instead of the stale prior version, and the
    /// printer renders the claim as `w0_1 = __unknown(...)`.
    ///
    /// `inputs` records what the instruction READS (HOP-2), bound at lift
    /// time to the SSA values the registers held just before it executed.
    ///
    /// Contract for every pass over MacIR (pruning, propagation, MemorySSA,
    /// phis, copy propagation, dead-code elimination, parameter recovery):
    /// - an `.unknown` is never removable;
    /// - it is a full memory clobber: it may read or write any memory;
    /// - no pass may treat a value as dead while it appears in
    ///   `inputs.mayRead` (or the NZCV flags while `inputs.mayReadNZCV`);
    /// - parameter recovery may use only `inputs.definiteRead`. May-reads
    ///   over-approximate (`ldaxr x0, [x1]` names `x0` but only writes it),
    ///   so counting them as entry reads would fabricate parameters.
    ///
    /// The printer does not render `inputs`; the text is unchanged.
    case unknown(destination: MacIRValue?, inputs: MacIRUnknownInputs, mnemonic: String, operands: String)
}

/// One register read by an unmodelled instruction.
public struct MacIRUnknownRead: Hashable, Sendable {
    /// Canonical lowercase register name: `fp`/`lr` become `x29`/`x30`,
    /// `wsp` becomes `sp`, and vector arrangement/lane suffixes are dropped
    /// (`v1.4s`, `v1.s[2]` -> `v1`).
    public var register: String
    /// The SSA value the register held immediately before the instruction.
    public var value: MacIRValue

    public init(register: String, value: MacIRValue) {
        self.register = register
        self.value = value
    }
}

/// The read sets of an `.unknown` MacIR node (HOP-2). Two sets, because
/// their consumers fail in opposite directions:
/// - `mayRead` is conservative, for liveness and dead-code safety: every
///   register the encoding could read — all register operands (memory-base
///   and index registers included), read-modify-write and partially
///   written destinations, and the instruction's implicit register reads —
///   minus only a first operand known to be write-only. Over-approximating
///   is safe here: it can only keep a value alive.
/// - `definiteRead` is precise, for parameter recovery: registers the
///   instruction certainly reads as source operands. Always a subset of
///   `mayRead`.
/// The NZCV flags have no SSA value in MacIR, so they are two booleans
/// with the same may/definite meaning; `definitelyReadsNZCV` implies
/// `mayReadNZCV`. Zero registers are never reads.
public struct MacIRUnknownInputs: Hashable, Sendable {
    public var mayRead: [MacIRUnknownRead]
    public var definiteRead: [MacIRUnknownRead]
    public var mayReadNZCV: Bool
    public var definitelyReadsNZCV: Bool

    public init(
        mayRead: [MacIRUnknownRead] = [],
        definiteRead: [MacIRUnknownRead] = [],
        mayReadNZCV: Bool = false,
        definitelyReadsNZCV: Bool = false
    ) {
        self.mayRead = mayRead
        self.definiteRead = definiteRead
        self.mayReadNZCV = mayReadNZCV || definitelyReadsNZCV
        self.definitelyReadsNZCV = definitelyReadsNZCV
    }

    /// No recorded reads (hand-built IR and tests only; the builder always
    /// records the instruction's reads).
    public static let none = MacIRUnknownInputs()

    public var mayReadRegisters: [String] { mayRead.map(\.register) }
    public var definiteReadRegisters: [String] { definiteRead.map(\.register) }
}

public extension MacIROperation {
    /// An unknown with no recorded reads.
    static func unknown(destination: MacIRValue?, mnemonic: String, operands: String) -> MacIROperation {
        .unknown(destination: destination, inputs: .none, mnemonic: mnemonic, operands: operands)
    }

    /// An unknown with no claimed destination (the instruction writes no
    /// scalar GPR, or its first operand is a read — stores, `swp*`, …) and
    /// no recorded reads.
    static func unknown(mnemonic: String, operands: String) -> MacIROperation {
        .unknown(destination: nil, inputs: .none, mnemonic: mnemonic, operands: operands)
    }

    /// The read sets of an `.unknown`; nil for every other operation.
    var unknownInputs: MacIRUnknownInputs? {
        guard case let .unknown(_, inputs, _, _) = self else { return nil }
        return inputs
    }
}

/// Scalar value domains for the default-FPCR A64 operations below. Floating-point
/// operands are numeric IEEE-754 values unless an explicit scalarSIMDBits carrier
/// bridges an integer bit pattern. `fmov` also performs a bit move.
public enum MacIRScalarType: String, Hashable, Sendable {
    case binary32 = "f32", binary64 = "f64"
    case signed32 = "i32", signed64 = "i64", unsigned32 = "u32", unsigned64 = "u64"
    public var bitWidth: Int { [.binary32, .signed32, .unsigned32].contains(self) ? 32 : 64 }
    public var isFloatingPoint: Bool { self == .binary32 || self == .binary64 }
    public var isSignedInteger: Bool { self == .signed32 || self == .signed64 }
    public var cType: String {
        switch self {
        case .binary32: "float"
        case .binary64: "double"
        case .signed32: "int32_t"
        case .signed64: "int64_t"
        case .unsigned32: "uint32_t"
        case .unsigned64: "uint64_t"
        }
    }
}

/// Numeric scalar FP semantics, independent of source assembly and native C casts.
/// Assumes FPCR=0: RN-even, no flush-to-zero and payload-preserving NaNs. `round`
/// and `toInteger` use their explicit rounding mode. Conversions to integer saturate
/// (NaN -> zero); fixed-point forms scale by 2^fractionalBits in that direction,
/// and fromInteger scales by 2^-fractionalBits. Binary32 arithmetic rounds once at
/// binary32 precision. Fused operations take n,m,a and round a + n*m once.
/// FMSUB flips n, FNMADD flips a and n, FNMSUB flips a before NaN processing.
/// NaN priority is a,n,m (signaling before quiet); quiet-NaN a plus inf*zero
/// produces canonical NaN. These are sign-bit transformations, not post-round negation.
/// FPSR/exception flags are NOT represented: inexact/invalid/
/// underflow/overflow status and trapping behavior cannot be inferred from this IR.
/// `raisesInexact` records FRINTX's distinction without inventing flag state.
/// The intrinsic operation owns destination/SSA operands; this descriptor owns their
/// numeric types and semantics. Preserve both when rewriting an instruction.
public struct MacIRScalarFP: Hashable, Sendable {
    public enum Operation: String, Hashable, Sendable {
        case add, subtract, multiply, divide, negate, absolute, squareRoot
        case maximum, minimum, maximumNumber, minimumNumber
        case fusedMultiplyAdd, fusedMultiplySubtract, negatedFusedMultiplyAdd, negatedFusedMultiplySubtract
        case round, convert, toInteger, fromInteger
        public var arity: Int {
            switch self {
            case .add, .subtract, .multiply, .divide, .maximum, .minimum, .maximumNumber, .minimumNumber: 2
            case .fusedMultiplyAdd, .fusedMultiplySubtract, .negatedFusedMultiplyAdd, .negatedFusedMultiplySubtract: 3
            default: 1
            }
        }
    }
    public enum Rounding: String, Hashable, Sendable {
        case nearestEven, plusInfinity, minusInfinity, towardZero, tiesAway
    }
    public enum IntegerCarrier: String, Hashable, Sendable { case gpr, scalarSIMDBits }
    /// Conversion integer bits may reside in a scalar S/D lane. The logical numeric
    /// type remains integer; the physical carrier is still a bit-preserving FP view.
    public let integerCarrier: IntegerCarrier
    public var storageResultType: MacIRScalarType {
        integerCarrier == .scalarSIMDBits && operation == .toInteger
            ? (resultType.bitWidth == 32 ? .binary32 : .binary64) : resultType
    }
    public let operation: Operation
    public let inputType: MacIRScalarType
    public let resultType: MacIRScalarType
    public let rounding: Rounding
    public let fractionalBits: Int
    public let raisesInexact: Bool

    public init(operation: Operation, inputType: MacIRScalarType, resultType: MacIRScalarType,
                rounding: Rounding = .nearestEven, fractionalBits: Int = 0, raisesInexact: Bool = false,
                integerCarrier: IntegerCarrier = .gpr) {
        precondition((0...64).contains(fractionalBits))
        self.integerCarrier = integerCarrier
        self.operation = operation
        self.inputType = inputType
        self.resultType = resultType
        self.rounding = rounding
        self.fractionalBits = fractionalBits
        self.raisesInexact = raisesInexact
    }

    /// Faithful fallback spelling for consumers that do not yet pretty-print FP.
    public var intrinsicName: String {
        "a64_fp_\(operation.rawValue)_\(inputType.rawValue)_\(resultType.rawValue)_\(rounding.rawValue)_\(fractionalBits)" + (raisesInexact ? "_exact" : "") + (integerCarrier == .scalarSIMDBits ? "_simdBits" : "")
    }
}

/// Architectural memory access, independent of the disassembly/source span.
/// A nil descriptor on legacy hand-built IR means the carrier's natural width.
/// Pair operations use byteWidth for EACH element and for their address stride.
public struct MacIRMemoryAccess: Hashable, Sendable {
    public enum ExtensionKind: Hashable, Sendable { case none, zero, sign }
    public var byteWidth: Int
    public var extensionKind: ExtensionKind

    public init(byteWidth: Int, extensionKind: ExtensionKind = .none) {
        precondition([1, 2, 4, 8, 16].contains(byteWidth))
        self.byteWidth = byteWidth
        self.extensionKind = extensionKind
    }
}

/// Fixed-width, non-saturating lane permutations. No memory, NZCV, FPCR or
/// FPSR effects. Every result defines all 128 physical bits; Q=0 clears high 64.
public struct MacIRNEONPermutation: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case zip1, zip2, uzp1, uzp2, trn1, trn2 }
    public let kind: Kind
    public let laneBytes: Int
    public let laneCount: Int
    public var activeBytes: Int { laneBytes * laneCount }
    public var intrinsicName: String { "neon_\(kind.rawValue)_\(laneCount)x\(laneBytes * 8)_zero_upper" }

    /// Each output lane names a lane in the concatenated (left,right) inputs.
    /// This typed routing is the semantics, not a mnemonic-only annotation.
    public var sourceLanes: [Int] {
        let n = laneCount
        let second = [Kind.zip2, .uzp2, .trn2].contains(kind) ? 1 : 0
        return (0..<n).map { i in
            switch kind {
            case .zip1, .zip2: return (i % 2) * n + second * (n / 2) + i / 2
            case .uzp1, .uzp2: return 2 * i + second
            case .trn1, .trn2: return (i % 2) * n + 2 * (i / 2) + second
            }
        }
    }
}

public struct MacIRInstruction: Identifiable, Hashable, Sendable {
    /// Architectural provenance stays unchanged when one instruction has several effects.
    public struct Identity: Hashable, Sendable {
        public let sourceAddress: UInt64
        public let effectOrdinal: Int

        public init(sourceAddress: UInt64, effectOrdinal: Int) {
            self.sourceAddress = sourceAddress
            self.effectOrdinal = effectOrdinal
        }
    }
    public var id: Identity {
        Identity(sourceAddress: source.address, effectOrdinal: neonWiderMultiChannelLane?.ordinal ?? neonWiderMultiChannelReplicate?.ordinal ?? neonWiderChannelMemory?.ordinal ?? neonMultiChannelLane?.ordinal ?? neonMultiChannelReplicate?.ordinal ?? neonFourChannelMemory?.ordinal ?? neonThreeChannelMemory?.ordinal ?? neonContiguousGroup?.ordinal ?? neonLaneMemory?.ordinal ?? neonBroadcastMemory?.ordinal ?? neonInterleavedMemory?.ordinal ?? neonStructureLaneMemory?.ordinal ?? neonBufferSequence?.ordinal ?? 0)
    }
    public var source: MacIRSourceSpan
    public var operation: MacIROperation
    /// Semantic access facts; consumers must preserve this field when rewriting instructions.
    public var memoryAccess: MacIRMemoryAccess?
    /// Control-transfer input for `ret Xn`; nil is the legacy link-register target.
    /// This is not the function's returned data value. Preserve it across rewrites.
    public var returnTarget: MacIRValue?
    public var scalarFP: MacIRScalarFP?
    /// Symbolic architectural side effect for the bounded environment-aware FP lift.
    /// This metadata does not add a second MacIROperation dataflow definition.
    /// Keep it with the instruction when an IR pass rewrites the numeric operation.
    public var fpEnvironment: MacIRFPEnvironmentEffect?
    /// Unresolved architectural FP controls/traps retain an unknown operation.
    public var fpBlockedEffect: MacIRFPBlockedEffect?
    public var neonQC: MacIRNEONQCEffect?
    public var neonQCIsSeparate = false
    public var vectorFP: MacIRVectorFPEffect?
    public var vectorFPStatus: MacIRVectorFPEffect?
    public var fpArchitecturalClobber: MacIRFPArchitecturalCell?
    /// Preserve this typed lane-routing descriptor across instruction rewrites.
    public var neonPermutation: MacIRNEONPermutation?
    public var neonLogical: MacIRNEONLogical?
    public var neonExtract: MacIRNEONExtract?
    public var neonTableLookup: MacIRNEONTableLookup?
    public var neonModular: MacIRNEONModular?
    public var neonComparison: MacIRNEONComparison?
    public var neonBufferMemory: MacIRNEONBufferMemory?
    public var neonBitView: MacIRNEONBitView?
    public var neonBufferSequence: MacIRNEONBufferSequenceStep?
    public var neonShiftInsert: MacIRNEONShiftInsert?
    public var neonMultiply: MacIRNEONMultiply?
    public var neonImmediate: MacIRNEONImmediate?
    public var neonReduction: MacIRNEONReduction?
    public var neonPacking: MacIRNEONPacking?
    public var neonLaneMemory: MacIRNEONLaneMemoryStep?
    public var neonWideningPairwise: MacIRNEONWideningPairwise?
    public var neonPredicate: MacIRNEONPredicate?
    public var neonShiftNarrow: MacIRNEONShiftNarrow?
    public var neonContiguousGroup: MacIRNEONContiguousGroupStep?
    public var neonMagnitudeClamp: MacIRNEONMagnitudeClamp?
    public var neonPairwise: MacIRNEONPairwise?
    public var neonBroadcastMemory: MacIRNEONBroadcastMemoryStep?
    public var neonBitCount: MacIRNEONBitCount?
    public var neonOrderConversion: MacIRNEONOrderConversion?
    public var neonInterleavedMemory: MacIRNEONInterleavedMemoryStep?
    public var neonStructureLaneMemory: MacIRNEONStructureLaneMemoryStep?
    public var neonIndexedMemory: MacIRNEONIndexedMemory?
    public var neonWideningAddSubtract: MacIRNEONWideningAddSubtract?
    public var neonSignedLongMultiply: MacIRNEONSignedLongMultiply?
    public var neonScalarShiftCompilerComposition: MacIRNEONScalarShiftCompilerComposition?
    public var neonScalarMaskSelection: MacIRNEONScalarMaskSelection?
    public var neonScalarIntegerComparison: MacIRNEONScalarIntegerComparison?
    public var neonLaneCoefficientProduct: MacIRNEONLaneCoefficientProduct?
    public var neonReplicatedIndexedProduct: MacIRNEONReplicatedIndexedProduct?
    public var neonWiderMultiChannelLane: MacIRNEONWiderMultiChannelLaneStep?
    public var neonWiderMultiChannelReplicate: MacIRNEONWiderMultiChannelReplicateStep?
    public var neonScalarVariableShift: MacIRNEONScalarVariableShift?
    public var neonWiderChannelMemory: MacIRNEONWiderChannelMemoryStep?
    public var neonMultiChannelLane: MacIRNEONMultiChannelLaneStep?
    public var neonMultiChannelReplicate: MacIRNEONMultiChannelReplicateStep?
    public var neonFourChannelMemory: MacIRNEONFourChannelMemoryStep?
    /// General per-row integer lane operation (D06 region composition).
    public var neonLaneOp: MacIRNEONLaneOp?
    public var neonThreeChannelMemory: MacIRNEONThreeChannelMemoryStep?
    public var neonByteMatrixAccumulate: MacIRNEONByteMatrixAccumulate?
    public var neonIndexedMixedByteDotProduct: MacIRNEONIndexedMixedByteDotProduct?
    public var neonMixedByteDotProduct: MacIRNEONMixedByteDotProduct?
    public var neonFullWidthShift: MacIRNEONFullWidthShift?
    public var neonRoundedShift: MacIRNEONRoundedShift?
    public var neonSelectedSignedMultiply: MacIRNEONSelectedSignedMultiply?
    public var neonSelectedWideningAccumulate: MacIRNEONSelectedWideningAccumulate?
    public var neonIndexedByteDotProduct: MacIRNEONIndexedByteDotProduct?
    public var neonByteDotProduct: MacIRNEONByteDotProduct?
    public var neonSelectedUnsignedMultiply: MacIRNEONSelectedUnsignedMultiply?
    public var neonBytePolynomialMultiply: MacIRNEONBytePolynomialMultiply?

    public init(source: MacIRSourceSpan, operation: MacIROperation, memoryAccess: MacIRMemoryAccess? = nil, returnTarget: MacIRValue? = nil, scalarFP: MacIRScalarFP? = nil, neonPermutation: MacIRNEONPermutation? = nil, neonLogical: MacIRNEONLogical? = nil, neonExtract: MacIRNEONExtract? = nil, neonTableLookup: MacIRNEONTableLookup? = nil, neonModular: MacIRNEONModular? = nil, neonComparison: MacIRNEONComparison? = nil, neonBufferMemory: MacIRNEONBufferMemory? = nil, neonBitView: MacIRNEONBitView? = nil, neonBufferSequence: MacIRNEONBufferSequenceStep? = nil, neonShiftInsert: MacIRNEONShiftInsert? = nil, neonMultiply: MacIRNEONMultiply? = nil, neonImmediate: MacIRNEONImmediate? = nil, neonReduction: MacIRNEONReduction? = nil, neonPacking: MacIRNEONPacking? = nil, neonIndexedMemory: MacIRNEONIndexedMemory? = nil, neonInterleavedMemory: MacIRNEONInterleavedMemoryStep? = nil, neonStructureLaneMemory: MacIRNEONStructureLaneMemoryStep? = nil, neonOrderConversion: MacIRNEONOrderConversion? = nil, neonBitCount: MacIRNEONBitCount? = nil, neonBroadcastMemory: MacIRNEONBroadcastMemoryStep? = nil, neonLaneMemory: MacIRNEONLaneMemoryStep? = nil, neonPairwise: MacIRNEONPairwise? = nil, neonMagnitudeClamp: MacIRNEONMagnitudeClamp? = nil, neonWideningPairwise: MacIRNEONWideningPairwise? = nil, neonPredicate: MacIRNEONPredicate? = nil, neonShiftNarrow: MacIRNEONShiftNarrow? = nil, neonContiguousGroup: MacIRNEONContiguousGroupStep? = nil, neonWideningAddSubtract: MacIRNEONWideningAddSubtract? = nil, neonSignedLongMultiply: MacIRNEONSignedLongMultiply? = nil, neonThreeChannelMemory: MacIRNEONThreeChannelMemoryStep? = nil, neonRoundedShift: MacIRNEONRoundedShift? = nil, neonSelectedSignedMultiply: MacIRNEONSelectedSignedMultiply? = nil, neonByteDotProduct: MacIRNEONByteDotProduct? = nil, neonSelectedUnsignedMultiply: MacIRNEONSelectedUnsignedMultiply? = nil, neonBytePolynomialMultiply: MacIRNEONBytePolynomialMultiply? = nil, neonIndexedByteDotProduct: MacIRNEONIndexedByteDotProduct? = nil, neonSelectedWideningAccumulate: MacIRNEONSelectedWideningAccumulate? = nil, neonFullWidthShift: MacIRNEONFullWidthShift? = nil, neonMixedByteDotProduct: MacIRNEONMixedByteDotProduct? = nil, neonByteMatrixAccumulate: MacIRNEONByteMatrixAccumulate? = nil, neonIndexedMixedByteDotProduct: MacIRNEONIndexedMixedByteDotProduct? = nil, neonScalarShiftCompilerComposition: MacIRNEONScalarShiftCompilerComposition? = nil, neonScalarMaskSelection: MacIRNEONScalarMaskSelection? = nil, neonScalarIntegerComparison: MacIRNEONScalarIntegerComparison? = nil, neonLaneCoefficientProduct: MacIRNEONLaneCoefficientProduct? = nil, neonReplicatedIndexedProduct: MacIRNEONReplicatedIndexedProduct? = nil, neonWiderMultiChannelLane: MacIRNEONWiderMultiChannelLaneStep? = nil, neonWiderMultiChannelReplicate: MacIRNEONWiderMultiChannelReplicateStep? = nil, neonScalarVariableShift: MacIRNEONScalarVariableShift? = nil, neonWiderChannelMemory: MacIRNEONWiderChannelMemoryStep? = nil, neonMultiChannelLane: MacIRNEONMultiChannelLaneStep? = nil, neonMultiChannelReplicate: MacIRNEONMultiChannelReplicateStep? = nil, neonFourChannelMemory: MacIRNEONFourChannelMemoryStep? = nil, neonLaneOp: MacIRNEONLaneOp? = nil) {
        self.source = source
        self.operation = operation
        self.memoryAccess = memoryAccess
        self.returnTarget = returnTarget
        if case .unknown = operation, MacIRVectorFP(source: source) == nil {
            self.fpBlockedEffect = MacIRFPBlockedEffect(mnemonic: source.mnemonic, operands: source.operands)
        } else { self.fpBlockedEffect = nil }
        self.scalarFP = self.fpBlockedEffect == nil ? scalarFP : nil
        self.fpEnvironment = nil
        self.neonQC = nil
        self.vectorFP = nil
        self.vectorFPStatus = nil
        self.fpArchitecturalClobber = nil
        self.neonPermutation = neonPermutation
        self.neonLogical = neonLogical
        self.neonExtract = neonExtract
        self.neonTableLookup = neonTableLookup
        self.neonModular = neonModular
        self.neonComparison = neonComparison
        self.neonBufferMemory = neonBufferMemory
        self.neonBitView = neonBitView
        self.neonBufferSequence = neonBufferSequence
        self.neonShiftInsert = neonShiftInsert
        self.neonMultiply = neonMultiply
        self.neonImmediate = neonImmediate
        self.neonReduction = neonReduction
        self.neonPacking = neonPacking
        self.neonLaneMemory = neonLaneMemory
        self.neonWideningPairwise = neonWideningPairwise
        self.neonPredicate = neonPredicate
        self.neonShiftNarrow = neonShiftNarrow
        self.neonContiguousGroup = neonContiguousGroup
        self.neonMagnitudeClamp = neonMagnitudeClamp
        self.neonPairwise = neonPairwise
        self.neonBroadcastMemory = neonBroadcastMemory
        self.neonBitCount = neonBitCount
        self.neonOrderConversion = neonOrderConversion
        self.neonInterleavedMemory = neonInterleavedMemory
        self.neonStructureLaneMemory = neonStructureLaneMemory
        self.neonIndexedMemory = neonIndexedMemory
        self.neonWideningAddSubtract = neonWideningAddSubtract
        self.neonSignedLongMultiply = neonSignedLongMultiply
        self.neonScalarShiftCompilerComposition = neonScalarShiftCompilerComposition
        self.neonScalarMaskSelection = neonScalarMaskSelection
        self.neonScalarIntegerComparison = neonScalarIntegerComparison
        self.neonLaneCoefficientProduct = neonLaneCoefficientProduct
        self.neonReplicatedIndexedProduct = neonReplicatedIndexedProduct
        self.neonWiderMultiChannelLane = neonWiderMultiChannelLane
        self.neonWiderMultiChannelReplicate = neonWiderMultiChannelReplicate
        self.neonScalarVariableShift = neonScalarVariableShift
        self.neonWiderChannelMemory = neonWiderChannelMemory
        self.neonMultiChannelLane = neonMultiChannelLane
        self.neonMultiChannelReplicate = neonMultiChannelReplicate
        self.neonFourChannelMemory = neonFourChannelMemory
        self.neonLaneOp = neonLaneOp
        self.neonThreeChannelMemory = neonThreeChannelMemory
        self.neonByteMatrixAccumulate = neonByteMatrixAccumulate
        self.neonIndexedMixedByteDotProduct = neonIndexedMixedByteDotProduct
        self.neonMixedByteDotProduct = neonMixedByteDotProduct
        self.neonFullWidthShift = neonFullWidthShift
        self.neonRoundedShift = neonRoundedShift
        self.neonSelectedSignedMultiply = neonSelectedSignedMultiply
        self.neonSelectedWideningAccumulate = neonSelectedWideningAccumulate
        self.neonIndexedByteDotProduct = neonIndexedByteDotProduct
        self.neonByteDotProduct = neonByteDotProduct
        self.neonSelectedUnsignedMultiply = neonSelectedUnsignedMultiply
        self.neonBytePolynomialMultiply = neonBytePolynomialMultiply
    }
}

/// A block-entry register definition. Inputs are identified by the actual
/// predecessor block terminator, so a loop backedge never inherits a value
/// merely because its instruction is later in the source listing.
public struct MacIRPhi: Hashable, Sendable {
    public enum ScalarView: String, Hashable, Sendable {
        case integer, binary32, binary64, bits64
    }
    public struct Incoming: Hashable, Sendable {
        public var predecessor: MacIRPhiPredecessor
        public var value: MacIRValue

        public var machineAddress: UInt64? { predecessor.machineAddress }

        public init(predecessor: MacIRPhiPredecessor, value: MacIRValue) {
            self.predecessor = predecessor
            self.value = value
        }

        public init(predecessorAddress: UInt64, value: MacIRValue) {
            self.init(predecessor: .machine(predecessorAddress), value: value)
        }
    }

    public var blockAddress: UInt64
    public var destination: MacIRValue
    public var bitWidth: Int
    public var scalarView: ScalarView
    public var cell: Int?
    public var incoming: [Incoming]

    public init(blockAddress: UInt64, destination: MacIRValue, bitWidth: Int,
                incoming: [Incoming], scalarView: ScalarView = .integer, cell: Int? = nil) {
        self.blockAddress = blockAddress
        self.destination = destination
        self.bitWidth = bitWidth
        self.scalarView = scalarView
        self.cell = cell
        self.incoming = incoming
    }
}

public struct MacIRFunction: Identifiable, Hashable, Sendable {
    public var id: UInt64 { startAddress }
    public var name: String
    public var startAddress: UInt64
    public var endAddress: UInt64?
    public var returnType: String
    /// True when the function never returns (user-authored — there is no inference
    /// source). Rendered as a `noreturn` annotation; defaults to false.
    public var isNoReturn: Bool
    public var isVariadic: Bool
    public var parameters: [MacIRFunctionParameter]
    public var localVariables: [MacIRLocalVariable]
    public var nameBindings: [MacIRNameBinding]
    public var stackFrameSize: Int64
    /// Maximum SP displacement below the entry SP, in bytes; header metadata only.
    public var maxStackDisplacement: Int64
    public var callTargets: [String]
    public var callSignatures: [MacIRCallSignature]
    public var returnValue: MacIRValue?
    public var instructions: [MacIRInstruction] {
        didSet {
            // Operand repairs preserve the graph used by lexical proof equality.
            // Ranges and transfers must still be invalidated when topology changes.
            if cfg != nil, !MacIRCFG.hasSameTopology(oldValue, instructions) {
                cfg = nil
                refusals = []
            }
        }
    }
    public var phis: [MacIRPhi]
    public var ssaEnabled = false
    var ssaInfo: MacIRSSAInfo? = nil
    var ssaOriginalInstructions: [MacIRInstruction]? = nil
    var ssaOriginalPhis: [MacIRPhi]? = nil
    /// A27: comparison rows whose result is fully captured by a flags-phi edge boolean.
    var ssaFlagPhiComparisons: Set<UInt64> = []
    /// A28: cmp and ccmp rows whose every NZCV reader lifted a condition.
    var ssaElidedChainRows: Set<UInt64> = []
    /// Derived control flow, built only when the explicit graph feature is enabled.
    public var cfg: MacIRCFG? = nil
    public var refusals: [MacIRRefusal] = []
    /// Non-semantic, in-memory evidence; equality and hashing never force a
    /// lexical twin. Copies share one immutable result after its first reader.
    @RegionalNonSemantic var reconciliationEvidence: RegionalReconciliationEvidence? = nil
    var reconciliationMarkers: [RegionalLexicalProof.Marker] {
        reconciliationEvidence?.resolve().markers ?? []
    }
    var nonMarkerDifference: Bool {
        get { reconciliationEvidence?.resolve().nonMarkerDifference ?? false }
        set {
            reconciliationEvidence = RegionalReconciliationEvidence(result: .init(
                markers: reconciliationMarkers, nonMarkerDifference: newValue))
        }
    }
    /// A rejected return lost its last phi use, but its control presentation stays.
    public private(set) var retainsPhiControlPresentation = false

    mutating func applyPhiResolution(_ resolution: ScalarCFGStatePlan.PhiResolution) {
        phis = resolution.phis
        retainsPhiControlPresentation = resolution.retainsControlPresentation
    }

    /// The function reads FPSR (`mrs`), so sticky QC updates are observable and
    /// printed; otherwise QC effects stay in the IR but are dead for printing.
    public var observesFPSR = false

    public init(
        name: String,
        startAddress: UInt64,
        endAddress: UInt64? = nil,
        returnType: String = "int64_t",
        isNoReturn: Bool = false,
        isVariadic: Bool = false,
        parameters: [MacIRFunctionParameter] = [],
        localVariables: [MacIRLocalVariable] = [],
        nameBindings: [MacIRNameBinding] = [],
        stackFrameSize: Int64 = 0,
        maxStackDisplacement: Int64 = 0,
        callTargets: [String] = [],
        callSignatures: [MacIRCallSignature] = [],
        returnValue: MacIRValue? = nil,
        instructions: [MacIRInstruction],
        phis: [MacIRPhi] = []
    ) {
        self.name = name
        self.startAddress = startAddress
        self.endAddress = endAddress
        self.returnType = returnType
        self.isNoReturn = isNoReturn
        self.isVariadic = isVariadic
        self.parameters = parameters
        self.localVariables = localVariables
        self.nameBindings = nameBindings
        self.stackFrameSize = stackFrameSize
        self.maxStackDisplacement = maxStackDisplacement
        self.callTargets = callTargets
        self.callSignatures = callSignatures
        self.returnValue = returnValue
        self.instructions = instructions
        self.phis = phis
    }
}

public enum MacIRParameterDeclarationMode: String, Hashable, Sendable {
    case ordinary
    case abiOnly = "abi-only"
}

public struct MacIRParameterBindingBodyUse: Hashable, Sendable {
    public var address: UInt64
    public var occurrence: Int

    public init(address: UInt64, occurrence: Int) {
        self.address = address
        self.occurrence = occurrence
    }
}

public struct MacIRDanglingParameterBindingBodyUse: Hashable, Sendable {
    public var binding: String
    public var use: MacIRParameterBindingBodyUse

    public init(binding: String, use: MacIRParameterBindingBodyUse) {
        self.binding = binding
        self.use = use
    }
}

public struct MacIRParameterBindingAuditRecord: Hashable, Sendable {
    public var function: String
    public var declarationMode: MacIRParameterDeclarationMode
    public var rowOrdinal: Int
    public var binding: String?
    public var sourcePosition: Int?
    public var location: String
    public var evidence: String
    public var name: String
    public var type: String
    public var bodyUses: [MacIRParameterBindingBodyUse]
}

public struct MacIRParameterBindingAudit: Hashable, Sendable {
    public static let schema = "parameter-binding-audit-v1"

    public var function: String
    public var address: UInt64
    public var declarationMode: MacIRParameterDeclarationMode
    public var records: [MacIRParameterBindingAuditRecord]
    public var danglingBodyUses: [MacIRDanglingParameterBindingBodyUse]
}

public extension MacIRFunction {
    /// Candidate-only structural audit. Body-use entries come from typed
    /// `.argument(bindingID:)` values in MacIR, never from pseudocode text or
    /// placeholder-name matching.
    func parameterBindingAudit() -> MacIRParameterBindingAudit {
        let positions = parameters.compactMap(\.sourcePosition)
        let hasOrdinaryDeclaration = !parameters.isEmpty
            && positions.count == parameters.count
            && Set(positions).count == positions.count
            && positions.sorted() == Array(parameters.indices)
        let declarationMode: MacIRParameterDeclarationMode = hasOrdinaryDeclaration
            ? .ordinary
            : .abiOnly

        let orderedParameters: [MacIRFunctionParameter]
        if hasOrdinaryDeclaration {
            orderedParameters = parameters.sorted {
                ($0.sourcePosition ?? Int.max) < ($1.sourcePosition ?? Int.max)
            }
        } else {
            orderedParameters = parameters.sorted {
                let left = ($0.bindingID?.auditText ?? "~", $0.abiLocation.auditText, $0.id.rawValue)
                let right = ($1.bindingID?.auditText ?? "~", $1.abiLocation.auditText, $1.id.rawValue)
                return left < right
            }
        }

        var usesByBinding: [MacIRParameterBindingID: [MacIRParameterBindingBodyUse]] = [:]
        var usesByRow: [MacIRParameterRowID: [MacIRParameterBindingBodyUse]] = [:]
        func record(_ references: [MacIRParameterReference], address: UInt64) {
            for (occurrence, reference) in references.enumerated() {
                let use = MacIRParameterBindingBodyUse(address: address, occurrence: occurrence)
                switch reference {
                case let .scalar(binding): usesByBinding[binding, default: []].append(use)
                case let .sourceRow(rowID): usesByRow[rowID, default: []].append(use)
                }
            }
        }
        for instruction in instructions {
            record(instruction.operation.parameterReferences
                + (instruction.returnTarget?.parameterReferences ?? []),
                address: instruction.source.address)
        }
        for phi in phis {
            record(phi.incoming.flatMap { $0.value.parameterReferences }, address: phi.blockAddress)
        }
        usesByBinding = usesByBinding.mapValues { uses in
            uses.sorted {
                ($0.address, $0.occurrence) < ($1.address, $1.occurrence)
            }
        }
        usesByRow = usesByRow.mapValues { uses in
            uses.sorted { ($0.address, $0.occurrence) < ($1.address, $1.occurrence) }
        }

        let declaredBindings = Set(orderedParameters.compactMap(\.bindingID))
        let danglingScalarUses = usesByBinding
            .filter { !declaredBindings.contains($0.key) }
            .flatMap { binding, uses in
                uses.map {
                    MacIRDanglingParameterBindingBodyUse(binding: binding.auditText, use: $0)
                }
            }
        let declaredRows = Set(orderedParameters.map(\.id))
        let danglingRowUses = usesByRow
            .filter { !declaredRows.contains($0.key) }
            .flatMap { row, uses in
                uses.map { MacIRDanglingParameterBindingBodyUse(binding: "source-row:\(row.rawValue)", use: $0) }
            }
        let danglingBodyUses = (danglingScalarUses + danglingRowUses)
            .sorted {
                ($0.use.address, $0.use.occurrence, $0.binding)
                    < ($1.use.address, $1.use.occurrence, $1.binding)
            }

        let records = orderedParameters.enumerated().map { rowOrdinal, parameter in
            MacIRParameterBindingAuditRecord(
                function: name,
                declarationMode: declarationMode,
                rowOrdinal: rowOrdinal,
                binding: parameter.bindingID?.auditText
                    ?? (parameter.richLocation == nil ? nil : "source-row:\(parameter.id.rawValue)"),
                sourcePosition: parameter.sourcePosition,
                location: parameter.richLocation?.auditText ?? parameter.abiLocation.auditText,
                evidence: parameter.evidence.auditText,
                name: parameter.name,
                type: parameter.type,
                bodyUses: parameter.bindingID.flatMap { usesByBinding[$0] }
                    ?? usesByRow[parameter.id] ?? []
            )
        }

        return MacIRParameterBindingAudit(
            function: name,
            address: startAddress,
            declarationMode: declarationMode,
            records: records,
            danglingBodyUses: danglingBodyUses
        )
    }
}

private extension MacIRParameterBindingID {
    var auditText: String {
        switch kind {
        case .gpr: "gpr:\(value)"
        case .simd: "simd:\(value)"
        case .entryStack: "entry-stack:\(value)"
        }
    }
}

private extension MacIRABIParameterLocation {
    var auditText: String {
        switch self {
        case let .gpr(index, carrierWidth):
            "\(carrierWidth == 32 ? "w" : "x")\(index)"
        case let .simd(index, scalarWidth):
            "\(scalarWidth == 32 ? "s" : "d")\(index)"
        case let .entryStack(byteOffset, size, alignment):
            "entry_sp+\(byteOffset)[\(size)/\(alignment)]"
        case let .unbound(reason):
            "unbound:\(reason.auditText)"
        }
    }
}

private extension DarwinARM64RichParameterLocation {
    var auditText: String {
        guard case let .composite(pieces) = self else { return "unbound:unsupported_type" }
        return pieces.map { piece in
            let register: String
            switch piece.register {
            case let .simd(index, width): register = "\(width == 64 ? "d" : "s")\(index)"
            case let .gpr(index, width): register = "\(width == 64 ? "x" : "w")\(index)"
            }
            return "\(register)@\(piece.valueByteOffset)+\(piece.size)"
        }.joined(separator: ",")
    }
}

private extension MacIRABIUnboundReason {
    var auditText: String {
        switch self {
        case .unsupportedType: "unsupported_type"
        case .registerExhausted: "register_exhausted"
        case .dependentOnUnsupportedEarlierParameter: "dependent_on_unsupported_earlier_parameter"
        case .conflictingEvidence: "conflicting_evidence"
        case .unresolvedLegacy: "unresolved_legacy"
        }
    }
}

private extension MacIRParameterEvidence {
    var auditText: String {
        switch self {
        case .heuristicEntryRead: "heuristic_entry_read"
        case .knownCallTypeConstraint: "known_call_type_constraint"
        case .authoritativeDebug: "authoritative_debug"
        case .authoritativeUser: "authoritative_user"
        case .unresolvedLegacy: "unresolved_legacy"
        case .legacyTransient: "legacy_transient"
        }
    }
}

private enum MacIRParameterReference {
    case scalar(MacIRParameterBindingID)
    case sourceRow(MacIRParameterRowID)
}

private extension MacIRValue {
    var parameterReferences: [MacIRParameterReference] {
        switch self {
        case let .argument(bindingID):
            [.scalar(bindingID)]
        case let .argumentFragment(rowID, _, _):
            [.sourceRow(rowID)]
        case let .abiComposite(_, fragments):
            fragments.flatMap(\.parameterReferences)
        case let .bitTest(value, _), let .unary(_, value):
            value.parameterReferences
        case let .binaryExpression(_, left, right):
            left.parameterReferences + right.parameterReferences
        case let .signedBitfield(field):
            field.source.parameterReferences
        case .register, .immediate, .stackSlot, .symbol, .temporary, .unknown:
            []
        }
    }
}

private extension MacIROperation {
    var parameterReferences: [MacIRParameterReference] {
        func references(_ values: [MacIRValue?]) -> [MacIRParameterReference] {
            values.compactMap { $0 }.flatMap(\.parameterReferences)
        }

        return switch self {
        case let .assign(destination, source):
            references([destination, source])
        case let .binary(destination, _, left, right):
            references([destination, left, right])
        case let .load(destination, address):
            references([destination, address])
        case let .store(source, address):
            references([source, address])
        case let .loadWriteback(destination, baseDestination, baseSource, _, _):
            references([destination, baseDestination, baseSource])
        case let .storeWriteback(source, baseDestination, baseSource, _, _):
            references([source, baseDestination, baseSource])
        case let .stackSlotRead(destination, slot, value):
            references([destination, slot, value])
        case let .stackSlotPairRead(
            firstDestination,
            firstSlot,
            firstValue,
            secondDestination,
            secondSlot,
            secondValue
        ):
            references([
                firstDestination, firstSlot, firstValue,
                secondDestination, secondSlot, secondValue,
            ])
        case let .call(frame, result):
            frame.bindingValues.flatMap(\.parameterReferences) + references([result])
        case let .conditionalBranch(_, left, right, target):
            references([left, right, target])
        case let .select(destination, _, left, right, trueValue, falseValue):
            references([destination, left, right, trueValue, falseValue])
        case let .compareToBool(destination, _, left, right):
            references([destination, left, right])
        case let .returnValue(value):
            references([value])
        case let .intrinsic(destination, _, arguments):
            references([destination]) + arguments.flatMap(\.parameterReferences)
        case let .switchDispatch(index, cases, defaultTarget):
            index.parameterReferences
                + cases.flatMap { $0.target.parameterReferences }
                + references([defaultTarget])
        case let .unknown(destination, inputs, _, _):
            // The use list carries the may-reads (HOP-2): conservative, so a
            // binding read only by an unmodelled instruction still has a use.
            references([destination]) + inputs.mayRead.flatMap(\.value.parameterReferences)
        }
    }
}

public enum PseudocodeLineKind: String, Hashable, Sendable {
    case signature
    case metadata
    case declaration
    case instruction
    case closingBrace
}

public enum PseudocodeTokenKind: String, Hashable, Sendable {
    case keyword
    case type
    case identifier
    case intrinsic
    case literal
    case punctuation
    case comment
    case unknown
}

public struct PseudocodeToken: Identifiable, Hashable, Sendable {
    public var id: String { "\(lineNumber):\(range.lowerBound)-\(range.upperBound):\(kind.rawValue)" }
    public var lineNumber: Int
    public var kind: PseudocodeTokenKind
    public var text: String
    public var range: Range<Int>
    public var sourceAddress: UInt64?

    public init(
        lineNumber: Int,
        kind: PseudocodeTokenKind,
        text: String,
        range: Range<Int>,
        sourceAddress: UInt64? = nil
    ) {
        self.lineNumber = lineNumber
        self.kind = kind
        self.text = text
        self.range = range
        self.sourceAddress = sourceAddress
    }
}

public struct PseudocodeLine: Identifiable, Hashable, Sendable {
    public var id: Int { lineNumber }
    public var lineNumber: Int
    public var kind: PseudocodeLineKind
    public var text: String
    public var source: MacIRSourceSpan?
    public var tokens: [PseudocodeToken]
    /// Coverage metadata names its refused source without claiming ownership
    /// of an architectural statement at that address.
    public var refusal: MacIRRefusal?

    public init(
        lineNumber: Int,
        kind: PseudocodeLineKind = .instruction,
        text: String,
        source: MacIRSourceSpan? = nil,
        tokens: [PseudocodeToken] = [],
        refusal: MacIRRefusal? = nil
    ) {
        self.lineNumber = lineNumber
        self.kind = kind
        self.text = text
        self.source = source
        self.tokens = tokens
        self.refusal = refusal
    }

    public var syntheticPhiEdge: MacIRPhiEdgeIdentity? { source?.syntheticPhiEdge }

    public var sourceAddress: UInt64? {
        refusal == nil && source?.syntheticPhiEdge == nil ? source?.address : nil
    }

    public var addressText: String? {
        source?.addressText
    }
}

public struct PseudocodeRegionNode: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case sequence
        case block
        case ifThen
        case ifThenElse
        case whileLoop
        case doWhileLoop
        case switchDispatch
        case gotoLeaf
    }

    public var kind: Kind
    public var startLine: Int
    public var endLine: Int
    public var condition: String?
    public var conditionSourceAddress: UInt64?
    public var children: [PseudocodeRegionNode]

    public init(
        kind: Kind,
        startLine: Int,
        endLine: Int,
        condition: String? = nil,
        conditionSourceAddress: UInt64? = nil,
        children: [PseudocodeRegionNode] = []
    ) {
        self.kind = kind
        self.startLine = startLine
        self.endLine = endLine
        self.condition = condition
        self.conditionSourceAddress = conditionSourceAddress
        self.children = children
    }
}

public enum PseudocodeStructureFallback: String, Hashable, Sendable {
    case gotoForm
    case sizeGate
    case unstructurableCFG
    case unsupportedRegion
}

/// A conservative lattice of recovered local-variable types, produced by
/// `LocalTypeInferencePass` from instruction-level evidence. Deliberately small:
/// it captures only the distinctions the inference pass can justify from a single
/// forward walk over the IR. `unknown` is the lattice bottom (no evidence /
/// irreconcilable conflict) and never overwrites an existing rendered type.
public enum InferredLocalType: Equatable, Sendable {
    case unknown
    case integer(bits: Int, signed: Bool)
    case pointer
    case bool
    case floatingPoint(bits: Int)
}

/// A single piece of type evidence for a slot or register. `confidence == true`
/// is a HARD fact (the encoding or a known signature names the type exactly:
/// sized loads `ldrsb`/`ldrb`, `sdiv`/`udiv`, `cset`, a matched call-arg type,
/// a cast intrinsic). `confidence == false` is SOFT (a width-only default such
/// as the `int64_t`/`int32_t` a plain `ldr`/`str` implies). `exactTypeString`,
/// when present, is the precise C spelling to render (e.g. `"size_t"` or
/// `"const char *"`) and overrides the lattice's default spelling so a refined
/// type never loses a more specific name than the lattice alone can express.
struct InferredLocalTypeFact: Equatable, Sendable {
    var lattice: InferredLocalType
    var confidence: Bool
    var exactTypeString: String?

    init(lattice: InferredLocalType, confidence: Bool, exactTypeString: String? = nil) {
        self.lattice = lattice
        self.confidence = confidence
        self.exactTypeString = exactTypeString
    }
}

/// Parses a rendered C type string into a lattice fact.
///
/// `confidence` is `true` for types whose spelling implies an explicit,
/// mnemonic-derived, or signature-derived origin (the sized integer widths,
/// `BOOL`, `size_t`, pointers, char). It is `false` only for the two width-only
/// defaults the builder emits when it has no positive signedness signal
/// (`int64_t`/`int32_t`), so those can be refined by a later hard fact without
/// ever being treated as authoritative themselves.
func typeStringToLattice(_ type: String) -> InferredLocalTypeFact {
    let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized {
    case "int8_t":
        return InferredLocalTypeFact(lattice: .integer(bits: 8, signed: true), confidence: true)
    case "uint8_t", "char":
        return InferredLocalTypeFact(lattice: .integer(bits: 8, signed: false), confidence: true, exactTypeString: normalized == "char" ? "char" : nil)
    case "int16_t":
        return InferredLocalTypeFact(lattice: .integer(bits: 16, signed: true), confidence: true)
    case "uint16_t":
        return InferredLocalTypeFact(lattice: .integer(bits: 16, signed: false), confidence: true)
    case "int32_t":
        // Width-only default: the builder emits this for a plain w-register spill
        // with no signedness signal. Soft, so a real signed/unsigned fact wins.
        return InferredLocalTypeFact(lattice: .integer(bits: 32, signed: true), confidence: false)
    case "uint32_t":
        return InferredLocalTypeFact(lattice: .integer(bits: 32, signed: false), confidence: true)
    case "int", "BOOL":
        // BOOL is a hard bool fact; `int` is a hard 32-bit signed fact.
        return normalized == "BOOL"
            ? InferredLocalTypeFact(lattice: .bool, confidence: true, exactTypeString: "BOOL")
            : InferredLocalTypeFact(lattice: .integer(bits: 32, signed: true), confidence: true, exactTypeString: "int")
    case "int64_t":
        // Width-only default for a plain x-register spill: soft.
        return InferredLocalTypeFact(lattice: .integer(bits: 64, signed: true), confidence: false)
    case "uint64_t":
        return InferredLocalTypeFact(lattice: .integer(bits: 64, signed: false), confidence: true)
    case "size_t":
        // size_t is conceptually a 64-bit unsigned integer, but its spelling must
        // be PRESERVED, so carry it as an exact string.
        return InferredLocalTypeFact(lattice: .integer(bits: 64, signed: false), confidence: true, exactTypeString: "size_t")
    case "float":
        return InferredLocalTypeFact(lattice: .floatingPoint(bits: 32), confidence: true, exactTypeString: "float")
    case "double":
        return InferredLocalTypeFact(lattice: .floatingPoint(bits: 64), confidence: true, exactTypeString: "double")
    default:
        if DarwinARM64ParameterBinder.normalizedDataPointer(normalized) != nil {
            // Only pointer spellings accepted by the strict shared declarator
            // grammar become hard facts. Preserve their exact authored spelling.
            return InferredLocalTypeFact(lattice: .pointer, confidence: true, exactTypeString: normalized)
        }
        return InferredLocalTypeFact(lattice: .unknown, confidence: false)
    }
}

/// Renders a lattice type back to its C spelling. Returns `nil` for `unknown`
/// (the caller keeps the existing string). `size_t` and explicit pointer/`char`
/// spellings are preserved through `exactTypeString` on the originating fact;
/// this bare-lattice form falls back to canonical spellings (`pointer` ->
/// `"void *"`, since no pointee tracking exists yet).
func latticeToTypeString(_ lattice: InferredLocalType) -> String? {
    switch lattice {
    case .unknown:
        return nil
    case let .integer(bits, signed):
        switch (bits, signed) {
        case (8, true): return "int8_t"
        case (8, false): return "uint8_t"
        case (16, true): return "int16_t"
        case (16, false): return "uint16_t"
        case (32, true): return "int32_t"
        case (32, false): return "uint32_t"
        case (64, true): return "int64_t"
        case (64, false): return "uint64_t"
        default: return signed ? "int64_t" : "uint64_t"
        }
    case .pointer:
        return "void *"
    case .bool:
        return "BOOL"
    case let .floatingPoint(bits):
        return bits <= 32 ? "float" : "double"
    }
}

public struct PseudocodeDocument: Hashable, Sendable {
    public var functionName: String
    public var entryAddress: UInt64
    public var returnType: String
    public var parameters: [MacIRFunctionParameter]
    public var localVariables: [MacIRLocalVariable]
    public var nameBindings: [MacIRNameBinding]
    public var stackFrameSize: Int64
    public var callTargets: [String]
    public var callSignatures: [MacIRCallSignature]
    public var lines: [PseudocodeLine]
    public var regionTree: PseudocodeRegionNode?
    public var structureFallback: PseudocodeStructureFallback?

    public init(
        functionName: String,
        entryAddress: UInt64 = 0,
        returnType: String = "int64_t",
        parameters: [MacIRFunctionParameter] = [],
        localVariables: [MacIRLocalVariable] = [],
        nameBindings: [MacIRNameBinding] = [],
        stackFrameSize: Int64 = 0,
        callTargets: [String] = [],
        callSignatures: [MacIRCallSignature] = [],
        lines: [PseudocodeLine],
        regionTree: PseudocodeRegionNode? = nil,
        structureFallback: PseudocodeStructureFallback? = nil
    ) {
        self.functionName = functionName
        self.entryAddress = entryAddress
        self.returnType = returnType
        self.parameters = parameters
        self.localVariables = localVariables
        self.nameBindings = nameBindings
        self.stackFrameSize = stackFrameSize
        self.callTargets = callTargets
        self.callSignatures = callSignatures
        self.lines = lines
        self.regionTree = regionTree
        self.structureFallback = structureFallback
    }

    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public func lines(sourcedAt address: UInt64) -> [PseudocodeLine] {
        lines.filter { $0.sourceAddress == address }
    }
}

// The proof describes physical incoming register use, never a source signature.
public struct MacIRMachineUsageContext: Hashable, Sendable {
    public let snapshotID: UUID
    public let imageID: UUID
    public let imageSlotRawValue: Int

    public init(snapshotID: UUID, imageID: UUID, imageSlotRawValue: Int) {
        self.snapshotID = snapshotID
        self.imageID = imageID
        self.imageSlotRawValue = imageSlotRawValue
    }
}

public struct MacIRMachineUsageBody: Hashable, Sendable {
    public let start: UInt64
    public let end: UInt64
    public let rows: [MacIRSourceSpan]

    public init(start: UInt64, end: UInt64, rows: [MacIRSourceSpan]) {
        self.start = start
        self.end = end
        self.rows = rows
    }
}

public struct MacIRMachineCallUsage: Hashable, Sendable {
    public let context: MacIRMachineUsageContext
    public let caller: MacIRMachineUsageBody
    // Private construction prevents a client from supplying a trusted raw mask.
    private let calls: [UInt64: Call]

    private struct Call: Hashable, Sendable {
        let originalCall: MacIRSourceSpan
        let callee: MacIRMachineUsageBody
        let incomingReads: UInt8
        let callerDefinitions: UInt8
    }

    private init(context: MacIRMachineUsageContext, caller: MacIRMachineUsageBody,
                 calls: [UInt64: Call]) {
        self.context = context
        self.caller = caller
        self.calls = calls
    }

    // Address-only selection for the snapshot adapter, never a usage-mask authority.
    static func directTargets(in caller: MacIRMachineUsageBody) -> Set<UInt64> {
        guard MachineUsageProof.validBody(caller) else { return [] }
        return Set(caller.rows.compactMap(MachineUsageProof.directBLTarget))
    }

    public static func prove(context: MacIRMachineUsageContext,
                             caller: MacIRMachineUsageBody,
                             callees: [MacIRMachineUsageBody]) -> Self? {
        guard context.imageSlotRawValue >= 0, MachineUsageProof.validBody(caller),
              callees.count <= 65536 else { return nil }
        let grouped = Dictionary(grouping: callees, by: \.start)
        let definitions = MachineUsageProof.callerDefinitions(caller) ?? [:]
        var summaries: [UInt64: UInt8] = [:]
        var refused: Set<UInt64> = []
        var calls: [UInt64: Call] = [:]
        for row in caller.rows where row.mnemonic.lowercased() == "bl" {
            guard !Task.isCancelled else { return nil }
            guard let target = MachineUsageProof.directBLTarget(row),
                  let matches = grouped[target], matches.count == 1,
                  let callee = matches.first,
                  !callees.contains(where: {
                      $0.start != callee.start && $0.start < callee.end && callee.start < $0.end
                  }),
                  !refused.contains(target) else { continue }
            let reads: UInt8
            if let cached = summaries[target] { reads = cached }
            else {
                guard let summary = MachineUsageProof.calleeReads(callee) else {
                    refused.insert(target)
                    continue
                }
                reads = summary
                summaries[target] = summary
            }
            calls[row.address] = Call(originalCall: row, callee: callee,
                                      incomingReads: reads,
                                      callerDefinitions: definitions[row.address] ?? 0)
        }
        guard !calls.isEmpty else { return nil }
        return Self(context: context, caller: caller, calls: calls)
    }

    // Caller and expected context are independent current inputs, not values read
    // back out of this envelope. The caller comparison precedes any frame use.
    func matches(expected: MacIRMachineUsageContext?, originalCaller: [MacIRSourceSpan]) -> Bool {
        expected == context && originalCaller == caller.rows
    }

    func selection(at address: UInt64, originalCall: MacIRSourceSpan,
                   frame: MacIRCallFrame) -> (resolved: Set<Int>, promoted: Set<Int>)? {
        guard frame.knownSignature == nil, frame.typedIndirectSignature == nil,
              frame.richArguments == nil, frame.controlInputs.indirectTarget == nil,
              !frame.unprovenArgumentRegisters.isEmpty,
              let call = calls[address], call.originalCall == originalCall,
              frame.target == originalCall.operands.trimmingCharacters(in: .whitespacesAndNewlines),
              MachineUsageProof.directBLTarget(originalCall) == call.callee.start else { return nil }
        var resolved: Set<Int> = []
        var promoted: Set<Int> = []
        for spelling in frame.unprovenArgumentRegisters {
            guard let index = Int(spelling.dropFirst()), (0..<8).contains(index) else { return nil }
            let bit = UInt8(1) << index
            if call.incomingReads & bit == 0 {
                resolved.insert(index)
            } else if call.callerDefinitions & bit != 0,
                      let argument = frame.arguments.argument(at: .gpr(index: index)),
                      MachineUsageProof.available(argument.value) {
                resolved.insert(index)
                promoted.insert(index)
            }
        }
        return resolved.isEmpty ? nil : (resolved, promoted)
    }
}

private enum MachineUsageProof {
    struct Effect {
        var reads: UInt8 = 0
        var writes: UInt8 = 0
        var saveOrAlias: UInt8 = 0
        var successors: [UInt64] = []
        var isCall = false
        var refusesCallee = false
    }

    static func available(_ value: MacIRValue) -> Bool {
        switch value {
        case .unknown: return false
        case let .unary(_, inner), let .bitTest(inner, _): return available(inner)
        case let .binaryExpression(_, left, right): return available(left) && available(right)
        case let .abiComposite(_, fragments): return fragments.allSatisfy(available)
        case let .signedBitfield(field): return available(field.source)
        default: return true
        }
    }

    static func validBody(_ body: MacIRMachineUsageBody) -> Bool {
        guard !body.rows.isEmpty, body.rows.count <= 4096,
              body.start < body.end, body.rows.first?.address == body.start,
              body.end - body.start == UInt64(body.rows.count) * 4 else { return false }
        return body.rows.enumerated().allSatisfy { index, row in
            row.address == body.start + UInt64(index) * 4 && row.syntheticPhiEdge == nil
        }
    }

    static func directBLTarget(_ row: MacIRSourceSpan) -> UInt64? {
        guard row.mnemonic.lowercased() == "bl" else { return nil }
        let parts = row.byteText.split(whereSeparator: { $0.isWhitespace })
        if parts.count == 4 {
            let bytes = parts.compactMap { $0.count == 2 ? UInt32($0, radix: 16) : nil }
            guard bytes.count == 4 else { return nil }
            let word = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
            guard word & 0xfc000000 == 0x94000000 else { return nil }
            var displacement = Int64(word & 0x03ffffff)
            if displacement & 0x02000000 != 0 { displacement -= 0x04000000 }
            displacement *= 4
            let target: UInt64
            if displacement < 0 {
                let delta = UInt64(-displacement)
                guard row.address >= delta else { return nil }
                target = row.address - delta
            } else {
                let sum = row.address.addingReportingOverflow(UInt64(displacement))
                guard !sum.overflow else { return nil }
                target = sum.partialValue
            }
            // A numeric operand that disagrees with bytes is stale, not a fallback.
            if let spelled = address(row.operands), spelled != target { return nil }
            return target
        }
        guard parts.isEmpty else { return nil }
        return address(row.operands)
    }

    static func address(_ text: String) -> UInt64? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasPrefix("0x"), !s.dropFirst(2).isEmpty,
              s.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { return nil }
        return UInt64(s.dropFirst(2), radix: 16)
    }

    static func calleeReads(_ body: MacIRMachineUsageBody) -> UInt8? {
        guard validBody(body) else { return nil }
        var work: [(UInt64, UInt8)] = [(body.start, 0xff)]
        var visited: [UInt64: Set<UInt8>] = [:]
        var result: UInt8 = 0
        var steps = 0
        while let (pc, alive) = work.popLast() {
            if visited[pc, default: []].contains(alive) { continue }
            visited[pc, default: []].insert(alive)
            steps += 1
            guard !Task.isCancelled, steps <= 131072, pc >= body.start, pc < body.end,
                  (pc - body.start).isMultiple(of: 4),
                  let effect = effect(body.rows[Int((pc - body.start) / 4)]),
                  !effect.isCall, !effect.refusesCallee,
                  effect.saveOrAlias & alive == 0 else { return nil }
            result |= effect.reads & alive
            let nextAlive = alive & ~effect.writes
            for successor in effect.successors {
                guard successor >= body.start, successor < body.end else { return nil }
                work.append((successor, nextAlive))
            }
        }
        return result
    }

    static func callerDefinitions(_ body: MacIRMachineUsageBody) -> [UInt64: UInt8]? {
        guard validBody(body) else { return nil }
        // Enumerate all reachable state masks: intersection of states at a PC is
        // the all-path must-definition set, including loop call-kill/redefinition.
        var work: [(UInt64, UInt8)] = [(body.start, 0)]
        var visited: [UInt64: Set<UInt8>] = [:]
        var result: [UInt64: UInt8] = [:]
        var steps = 0
        while let (pc, defined) = work.popLast() {
            if visited[pc, default: []].contains(defined) { continue }
            visited[pc, default: []].insert(defined)
            steps += 1
            guard !Task.isCancelled, steps <= 131072, pc >= body.start, pc < body.end,
                  (pc - body.start).isMultiple(of: 4),
                  let effect = effect(body.rows[Int((pc - body.start) / 4)]) else { return nil }
            result[pc] = result[pc].map { $0 & defined } ?? defined
            let next = effect.isCall ? UInt8(0) : defined | effect.writes
            for successor in effect.successors {
                guard successor >= body.start, successor < body.end else { return nil }
                work.append((successor, next))
            }
        }
        return result
    }

    private struct Register {
        let index: Int
        let width: Int
        var mask: UInt8 { (0..<8).contains(index) ? UInt8(1) << index : 0 }
        var isSP: Bool { index == 32 }
    }

    private static func register(_ spelling: String) -> Register? {
        let s = spelling.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "sp" { return Register(index: 32, width: 64) }
        if s == "wsp" { return Register(index: 32, width: 32) }
        if s == "xzr" { return Register(index: 31, width: 64) }
        if s == "wzr" { return Register(index: 31, width: 32) }
        guard let prefix = s.first, prefix == "x" || prefix == "w",
              let index = Int(s.dropFirst()), (0...30).contains(index),
              String(index) == String(s.dropFirst()) else { return nil }
        return Register(index: index, width: prefix == "x" ? 64 : 32)
    }

    private static func immediate(_ spelling: String) -> Int64? {
        var s = spelling.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        let negative = s.hasPrefix("-")
        if negative { s.removeFirst() }
        let value: UInt64?
        if s.hasPrefix("0x") { value = UInt64(s.dropFirst(2), radix: 16) }
        else { value = UInt64(s) }
        guard let value, value <= UInt64(Int64.max) else { return nil }
        return negative ? -Int64(value) : Int64(value)
    }

    private static func operands(_ text: String) -> [String]? {
        // A semicolon begins disassembler annotation, never an operand.
        let text = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "[" { depth += 1; if depth != 1 { return nil } }
            if character == "]" { depth -= 1; if depth != 0 { return nil } }
            if character == ",", depth == 0 {
                let part = current.trimmingCharacters(in: .whitespaces)
                guard !part.isEmpty else { return nil }
                result.append(part); current = ""
            } else { current.append(character) }
        }
        guard depth == 0 else { return nil }
        let part = current.trimmingCharacters(in: .whitespaces)
        if !part.isEmpty { result.append(part) }
        else if !result.isEmpty { return nil }
        return result
    }

    private static let conditions: Set<String> = [
        "eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc",
        "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"
    ]

    private static func modifier(_ spelling: String) -> Bool {
        let parts = spelling.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first,
              ["lsl", "lsr", "asr", "ror", "uxtb", "uxth", "uxtw", "uxtx",
               "sxtb", "sxth", "sxtw", "sxtx"].contains(String(first)) else { return false }
        if parts.count == 1 { return first.hasPrefix("uxt") || first.hasPrefix("sxt") }
        guard parts.count == 2, let amount = immediate(String(parts[1])) else { return false }
        return (0...63).contains(amount)
    }

    private static func shift(_ spelling: String, allowed: Set<String>, amounts: Range<Int64>) -> Bool {
        let parts = spelling.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, allowed.contains(String(parts[0])),
              let amount = immediate(String(parts[1])) else { return false }
        return amounts.contains(amount)
    }

    // Explicit scalar effect grammar, not generic register token inference.
    // Unsupported forms refuse; the parser never uses missing operands as zero.
    private static func effect(_ row: MacIRSourceSpan) -> Effect? {
        let mnemonic = row.mnemonic.lowercased()
        guard let parts = operands(row.operands) else { return nil }
        let next = row.address.addingReportingOverflow(4)
        guard !next.overflow else { return nil }
        var result = Effect(successors: [next.partialValue])
        func scalar(_ position: Int) -> Register? {
            parts.indices.contains(position) ? register(parts[position]) : nil
        }
        func source(_ position: Int) -> UInt8? {
            guard parts.indices.contains(position) else { return nil }
            if let reg = scalar(position) { return reg.mask }
            return immediate(parts[position]) == nil ? nil : 0
        }
        if mnemonic == "ret" {
            guard parts.count <= 1 else { return nil }
            result.successors = []
            if !parts.isEmpty {
                // RET through an arbitrary register is an unresolved indirect
                // transfer, not evidence that this callee terminates here.
                guard let reg = scalar(0), reg.width == 64, reg.index == 30 else { return nil }
            }
            return result
        }
        if mnemonic == "bl" || mnemonic == "blr" {
            guard parts.count == 1 else { return nil }
            if mnemonic == "blr" {
                guard let reg = scalar(0), reg.width == 64, reg.index < 31 else { return nil }
            }
            result.isCall = true
            return result
        }
        if mnemonic == "b" || mnemonic.hasPrefix("b.") {
            guard parts.count == 1, let target = address(parts[0]) else { return nil }
            if mnemonic != "b" {
                guard conditions.contains(String(mnemonic.dropFirst(2))) else { return nil }
                result.successors.append(target)
            } else { result.successors = [target] }
            return result
        }
        if ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) {
            let bitTest = mnemonic.hasPrefix("tb")
            guard parts.count == (bitTest ? 3 : 2), let reg = scalar(0), !reg.isSP,
                  let target = address(parts[parts.count - 1]) else { return nil }
            if bitTest {
                guard let bit = immediate(parts[1]), bit >= 0, bit < reg.width else { return nil }
            }
            result.reads = reg.mask; result.successors.append(target)
            return result
        }
        if mnemonic == "nop" { return parts.isEmpty ? result : nil }
        if ["adr", "adrp"].contains(mnemonic) {
            guard parts.count == 2, let dest = scalar(0), dest.width == 64,
                  dest.index < 31, immediate(parts[1]) != nil else { return nil }
            result.writes = dest.mask; if dest.index == 30 { result.refusesCallee = true }
            return result
        }
        if ["mov", "movz", "movn", "movk"].contains(mnemonic) {
            guard (2...3).contains(parts.count), let dest = scalar(0),
                  let read = source(1), parts.count == 2 || modifier(parts[2]) else { return nil }
            if mnemonic != "mov", scalar(1) != nil { return nil }
            if mnemonic == "mov", parts.count != 2 { return nil }
            if mnemonic != "mov" {
                guard !dest.isSP, let literal = immediate(parts[1]), (0...65535).contains(literal) else { return nil }
                if parts.count == 3 {
                    let shift = parts[2].lowercased().split(whereSeparator: { $0.isWhitespace })
                    guard shift.count == 2, shift[0] == "lsl", let amount = immediate(String(shift[1])),
                          amount >= 0, amount < dest.width, amount.isMultiple(of: 16) else { return nil }
                }
            }
            if mnemonic == "mov", let literal = immediate(parts[1]) {
                // Bounded MOV-immediate subset; do not pretend to validate all
                // logical-immediate aliases from arbitrary operand text.
                guard !dest.isSP, (-65536...65535).contains(literal) else { return nil }
            }
            if mnemonic == "mov", let src = scalar(1),
               (dest.isSP || src.isSP), (dest.index == 31 || src.index == 31) { return nil }
            result.reads = read
            if mnemonic == "movk" {
                result.reads |= dest.mask // A partial update cannot prove an unavailable whole cell.
            } else { result.writes = dest.mask; if dest.index == 30 { result.refusesCallee = true } }
            if dest.index == 30 { result.refusesCallee = true }
            if let src = scalar(1) {
                guard src.width == dest.width else { return nil }
                result.saveOrAlias = src.mask
                result.refusesCallee = result.refusesCallee || src.isSP || src.index == 29
            }
            return result
        }
        if ["cmp", "cmn", "tst"].contains(mnemonic) {
            guard (2...3).contains(parts.count), let left = scalar(0),
                  let right = source(1), parts.count == 2 || modifier(parts[2]) else { return nil }
            if let rhs = scalar(1) {
                guard !left.isSP, !rhs.isSP, left.width == rhs.width,
                      parts.count == 2 || shift(parts[2],
                        allowed: mnemonic == "tst" ? ["lsl", "lsr", "asr", "ror"] : ["lsl", "lsr", "asr"],
                        amounts: 0..<Int64(left.width)) else { return nil }
            } else {
                guard mnemonic != "tst", left.index != 31,
                      let value = immediate(parts[1]), (0...4095).contains(value),
                      parts.count == 2 || parts[2].lowercased() == "lsl #0" || parts[2].lowercased() == "lsl #12"
                else { return nil }
            }
            result.reads = left.mask | right
            return result
        }
        if ["sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw", "neg", "negs", "mvn"].contains(mnemonic) {
            guard parts.count == 2, let dest = scalar(0), let src = scalar(1),
                  !dest.isSP, !src.isSP else { return nil }
            if ["neg", "negs", "mvn"].contains(mnemonic) {
                guard dest.width == src.width else { return nil }
            } else {
                guard src.width == 32,
                      !["sxtw", "uxtw"].contains(mnemonic) || dest.width == 64 else { return nil }
            }
            result.reads = src.mask; result.writes = dest.mask; if dest.index == 30 { result.refusesCallee = true }
            result.refusesCallee = result.refusesCallee || src.index == 29
            // Extensions can be an unfollowed copy into saved storage.
            if ["sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw"].contains(mnemonic) {
                result.saveOrAlias = src.mask
            }
            return result
        }
        if ["csel", "csinc", "csinv", "csneg", "cinc", "cinv", "cneg", "cset", "csetm"].contains(mnemonic) {
            let count = ["cset", "csetm"].contains(mnemonic) ? 2
                : (["cinc", "cinv", "cneg"].contains(mnemonic) ? 3 : 4)
            guard parts.count == count, conditions.contains(parts[count - 1].lowercased()),
                  let dest = scalar(0), !dest.isSP else { return nil }
            for index in 1..<(count - 1) {
                guard let src = scalar(index), !src.isSP, src.width == dest.width else { return nil }
                result.reads |= src.mask
                if src.index == 29 { result.refusesCallee = true }
            }
            result.writes = dest.mask; if dest.index == 30 { result.refusesCallee = true }
            // A conditional copy is not a followed use of its saved value.
            if !["cset", "csetm"].contains(mnemonic) { result.saveOrAlias = result.reads }
            return result
        }
        if ["add", "adds", "sub", "subs", "and", "ands", "orr", "eor", "bic",
            "lsl", "lsr", "asr", "ror", "mul", "smull", "umull", "sdiv", "udiv",
            "madd", "msub", "smaddl", "umaddl"].contains(mnemonic) {
            let fused = ["madd", "msub", "smaddl", "umaddl"].contains(mnemonic)
            guard (3...4).contains(parts.count), let dest = scalar(0), let left = scalar(1),
                  let right = source(2) else { return nil }
            let multiply = ["mul", "smull", "umull", "sdiv", "udiv"].contains(mnemonic)
            if ["lsl", "lsr", "asr", "ror"].contains(mnemonic) {
                guard parts.count == 3, !dest.isSP, !left.isSP, dest.width == left.width else { return nil }
                if let shift = immediate(parts[2]) {
                    guard shift >= 0, shift < dest.width else { return nil }
                } else {
                    guard let rhs = scalar(2), !rhs.isSP, rhs.width == dest.width else { return nil }
                }
            }
            if fused || multiply {
                guard let rhs = scalar(2), !dest.isSP, !left.isSP, !rhs.isSP,
                      parts.count == (fused ? 4 : 3) else { return nil }
                let widening = ["smull", "umull", "smaddl", "umaddl"].contains(mnemonic)
                guard widening ? (dest.width == 64 && left.width == 32 && rhs.width == 32)
                    : (dest.width == left.width && left.width == rhs.width) else { return nil }
            }
            let additive = ["add", "adds", "sub", "subs"].contains(mnemonic)
            let logical = ["and", "ands", "orr", "eor", "bic"].contains(mnemonic)
            if additive || logical {
                guard dest.width == left.width else { return nil }
                if let rhs = scalar(2) {
                    // Extended-register forms are outside this bounded subset.
                    guard !dest.isSP, !left.isSP, !rhs.isSP, rhs.width == dest.width,
                          parts.count == 3 || shift(parts[3],
                            allowed: logical ? ["lsl", "lsr", "asr", "ror"] : ["lsl", "lsr", "asr"],
                            amounts: 0..<Int64(dest.width)) else { return nil }
                } else {
                    // Logical-immediate encodings require a different validator;
                    // refuse them rather than treating any literal as a write.
                    guard additive, left.index != 31,
                          !(dest.index == 31 && ["add", "sub"].contains(mnemonic)),
                          !(dest.isSP && ["adds", "subs"].contains(mnemonic)),
                          let literal = immediate(parts[2]), (0...4095).contains(literal),
                          parts.count == 3 || parts[3].lowercased() == "lsl #0" || parts[3].lowercased() == "lsl #12"
                    else { return nil }
                }
            }
            result.reads = left.mask | right
            // Do not launder a frame/stack pointer through an arithmetic or
            // logical alias and later mistake a save through it for usage.
            if !dest.isSP && ([left, scalar(2), scalar(3)].compactMap { $0 }
                .contains(where: { $0.isSP || $0.index == 29 })) {
                result.refusesCallee = true
            }
            if ["lsl", "lsr", "asr", "ror"].contains(mnemonic),
               immediate(parts[2]) == 0 || scalar(2)?.index == 31 {
                // Variable shift by architectural ZR is also a zero-shift copy.
                result.saveOrAlias |= left.mask
            }
            if fused {
                guard parts.count == 4, let addend = scalar(3) else { return nil }
                guard !addend.isSP, addend.width == dest.width else { return nil }
                result.reads |= addend.mask
                // Zero-product MADD/MSUB is an unfollowed copy of its addend,
                // including the widening forms. Never count a save as usage.
                if left.index == 31 || scalar(2)?.index == 31 {
                    result.saveOrAlias |= addend.mask
                }
            } else if parts.count == 4 {
                guard ["add", "adds", "sub", "subs", "and", "ands", "orr", "eor", "bic"].contains(mnemonic),
                      modifier(parts[3]) else { return nil }
            }
            result.writes = dest.mask; if dest.index == 30 { result.refusesCallee = true }
            if ["add", "adds", "sub", "subs"].contains(mnemonic),
               (left.isSP || left.index == 29), !dest.isSP {
                // Do not lose a stack alias and later count a save through it as
                // a semantic input use. This bounded callee rule follows none.
                result.refusesCallee = true
            }
            if ["add", "adds", "sub", "subs"].contains(mnemonic), immediate(parts[2]) == 0 {
                result.saveOrAlias = left.mask
                result.refusesCallee = result.refusesCallee || left.isSP || left.index == 29
            }
            let unshifted = parts.count == 3 || (parts.count == 4 &&
                parts[3].lowercased().split(whereSeparator: { $0.isWhitespace }).last
                    .flatMap { immediate(String($0)) } == 0)
            let rhs = scalar(2)
            // Shifting/extending the architectural zero register still copies
            // the left input for these operations, even with a nonzero shift.
            if ["orr", "eor", "add", "adds", "sub", "subs", "bic"].contains(mnemonic),
               rhs?.index == 31 {
                result.saveOrAlias |= left.mask
            }
            if unshifted {
                let zeroRight = rhs?.index == 31 || immediate(parts[2]) == 0
                if ["orr", "eor", "add", "adds"].contains(mnemonic), left.index == 31 {
                    result.saveOrAlias |= right
                }
                if ["orr", "eor", "add", "adds", "sub", "subs", "bic"].contains(mnemonic), zeroRight {
                    result.saveOrAlias |= left.mask
                }
                if ["orr", "and", "ands"].contains(mnemonic), rhs?.index == left.index {
                    result.saveOrAlias |= left.mask
                }
                if ["and", "ands"].contains(mnemonic), immediate(parts[2]) == -1 {
                    result.saveOrAlias |= left.mask
                }
            }
            return result
        }
        let loads: Set<String> = ["ldr", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldur", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw", "ldp", "ldpsw"]
        let stores: Set<String> = ["str", "strb", "strh", "stur", "sturb", "sturh", "stp"]
        if loads.contains(mnemonic) || stores.contains(mnemonic) {
            let pair = ["ldp", "ldpsw", "stp"].contains(mnemonic)
            let dataCount = pair ? 2 : 1
            guard parts.count == dataCount + 1 || parts.count == dataCount + 2 else { return nil }
            // Caller-only Q/D/S/B/H transfers have no GPR data destination, but
            // their validated memory base/writeback still has physical effects.
            // Do not admit vector callee summaries through this bounded grammar.
            var vectorData = false
            let data = (0..<dataCount).compactMap { index -> Register? in
                if let reg = scalar(index) { return reg }
                let spelling = parts[index].lowercased()
                guard let prefix = spelling.first,
                      ["q", "d", "s", "h", "b"].contains(String(prefix)),
                      let number = Int(spelling.dropFirst()), (0...31).contains(number),
                      String(number) == String(spelling.dropFirst()),
                      ["ldr", "str", "ldur", "stur", "ldp", "stp"].contains(mnemonic) else { return nil }
                if pair, !["q", "d", "s"].contains(String(prefix)) { return nil }
                vectorData = true
                let width = prefix == "q" ? 128 : prefix == "d" ? 64 : prefix == "s" ? 32 : prefix == "h" ? 16 : 8
                return Register(index: 33 + number, width: width)
            }
            guard data.count == dataCount, data.allSatisfy({ !$0.isSP }) else { return nil }
            if vectorData {
                guard data.allSatisfy({ $0.index >= 33 }) else { return nil }
                if pair, parts[0].first != parts[1].first { return nil }
                result.refusesCallee = true
            } else {
                if pair, data[0].width != data[1].width { return nil }
                if ["ldrb", "ldrh", "ldurb", "ldurh", "strb", "strh", "sturb", "sturh"].contains(mnemonic),
                   data[0].width != 32 { return nil }
                if ["ldrsw", "ldursw", "ldpsw"].contains(mnemonic), data[0].width != 64 { return nil }
            }
            var memory = parts[dataCount]
            let preIndex = memory.hasSuffix("!")
            if preIndex { memory.removeLast() }
            guard memory.hasPrefix("["), memory.hasSuffix("]"),
                  let fields = operands(String(memory.dropFirst().dropLast())),
                  (1...3).contains(fields.count), let base = register(fields[0]),
                  base.width == 64, base.index != 31 else { return nil }
            result.reads |= base.mask
            if fields.count >= 2 {
                if let index = register(fields[1]), !index.isSP { result.reads |= index.mask }
                else if immediate(fields[1]) == nil { return nil }
            }
            if fields.count == 3, !modifier(fields[2]) { return nil }
            if fields.count == 3, register(fields[1]) == nil { return nil }
            if fields.count >= 2, let index = register(fields[1]), index.width == 32 {
                guard fields.count == 3,
                      fields[2].lowercased().hasPrefix("uxtw") || fields[2].lowercased().hasPrefix("sxtw") else { return nil }
            }
            if pair, fields.count >= 2, immediate(fields[1]) == nil { return nil }
            let postIndex = parts.count == dataCount + 2
            guard !(preIndex && postIndex) else { return nil }
            if postIndex {
                guard fields.count == 1, immediate(parts[dataCount + 1]) != nil else { return nil }
            }
            if preIndex {
                guard fields.count == 2, immediate(fields[1]) != nil else { return nil }
            }
            let unscaled = mnemonic.hasPrefix("ldur") || mnemonic.hasPrefix("stur")
            let accessBytes: Int64
            if ["ldrb", "ldrsb", "ldurb", "ldursb", "strb", "sturb"].contains(mnemonic) { accessBytes = 1 }
            else if ["ldrh", "ldrsh", "ldurh", "ldursh", "strh", "sturh"].contains(mnemonic) { accessBytes = 2 }
            else if ["ldrsw", "ldursw", "ldpsw"].contains(mnemonic) { accessBytes = 4 }
            else { accessBytes = Int64(data[0].width / 8) }
            if unscaled, preIndex || postIndex || fields.count == 3 || (fields.count == 2 && register(fields[1]) != nil) {
                return nil
            }
            if fields.count >= 2, let offsetRegister = register(fields[1]) {
                guard !pair, !unscaled, !preIndex, !postIndex, !offsetRegister.isSP else { return nil }
                if fields.count == 2 {
                    guard offsetRegister.width == 64 else { return nil }
                } else {
                    let mod = fields[2].lowercased().split(whereSeparator: { $0.isWhitespace })
                    guard (1...2).contains(mod.count),
                          offsetRegister.width == 32 ? ["uxtw", "sxtw"].contains(String(mod[0]))
                            : ["lsl", "sxtx"].contains(String(mod[0])) else { return nil }
                    let amount = mod.count == 1 ? Int64(0) : immediate(String(mod[1]))
                    let scale = accessBytes == 16 ? Int64(4) : accessBytes == 8 ? 3 : accessBytes == 4 ? 2 : accessBytes == 2 ? 1 : 0
                    guard let amount, amount == 0 || amount == scale,
                          mod.count == 2 || mod[0] != "lsl" else { return nil }
                }
            } else {
                let offset = postIndex ? immediate(parts[dataCount + 1])
                    : fields.count == 2 ? immediate(fields[1]) : Int64(0)
                guard let offset else { return nil }
                if pair {
                    guard (-64 * accessBytes...63 * accessBytes).contains(offset), offset.isMultiple(of: accessBytes) else { return nil }
                } else if unscaled || preIndex || postIndex {
                    guard (-256...255).contains(offset) else { return nil }
                } else {
                    guard (0...4095 * accessBytes).contains(offset), offset.isMultiple(of: accessBytes) else { return nil }
                }
            }
            let dataMask = data.reduce(UInt8(0)) { $0 | $1.mask }
            // Constrained-unpredictable writeback overlap is not a proof.
            if (preIndex || postIndex), data.contains(where: { $0.index == base.index }) { return nil }
            if loads.contains(mnemonic) {
                if pair, data[0].index == data[1].index { return nil }
                result.writes |= dataMask
                if data.contains(where: { $0.index == 30 }) { result.refusesCallee = true }
            } else {
                result.reads |= dataMask
                if base.isSP || base.index == 29 { result.saveOrAlias |= dataMask }
            }
            if preIndex || postIndex {
                result.writes |= base.mask
                if base.index == 30 { result.refusesCallee = true }
            }
            return result
        }
        return nil
    }
}
