import Foundation

/// Exact implementation identity for one accepted ARM64 instruction word.
enum ARM64AssemblyBackendIdentity: String, Sendable, Equatable {
    case macScopePrimary
    case swiftAssemblySourceFallback
}

/// Closed architecture identity supplied by exact loaded-artifact evidence.
enum ARM64AssemblyArchitecture: Sendable, Equatable {
    case arm64
    case arm64e

    /// Resolves the exact variant from authenticated Mach-O slice evidence when available.
    /// Non-Mach-O loaders may supply only an exact, unadorned architecture name. A decorated
    /// universal-slice display string without artifact evidence is deliberately insufficient.
    static func resolve(
        architectureDisplayName: String,
        artifactVariant: MachOSliceArchitectureVariant?
    ) -> Self? {
        if let artifactVariant {
            switch artifactVariant {
            case .arm64: return .arm64
            case .arm64e: return .arm64e
            case .x86_64, .x86_64h, .other: return nil
            }
        }
        switch architectureDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "arm64": return .arm64
        case "arm64e": return .arm64e
        default: return nil
        }
    }
}

struct ARM64AssemblyProduct: Sendable, Equatable {
    let bytes: [UInt8]
    let canonicalText: String
    let backend: ARM64AssemblyBackendIdentity
}

/// App-owned outcomes from MacScope's authoritative assembler.
enum ARM64PrimaryAssemblyOutcome: Sendable, Equatable {
    case success(ARM64AssemblyProduct)
    case unsupportedInstructionFamily(String)
    case rejected(String)
}

enum ARM64AssemblyRoutingFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case primaryRejected(String)
    case fallbackUnavailable
    case fallbackArchitectureUnavailable
    case addressSensitiveFallbackUnsupported
    case fallbackFailed
    case fallbackReturnedWrongByteCount(Int)
    case fallbackRoundTripWordMismatch
    case fallbackCanonicalTextMismatch
    case macScopeDecoderRejectedFallback
    case macScopeDecoderSemanticMismatch

    var description: String {
        switch self {
        case .primaryRejected(let reason):
            return reason
        case .fallbackUnavailable:
            return "the supplemental ARM64 assembler is unavailable"
        case .fallbackArchitectureUnavailable:
            return "the exact ARM64 architecture variant is unavailable"
        case .addressSensitiveFallbackUnsupported:
            return "absolute or ambiguous PC-relative operands are not accepted by the supplemental assembler"
        case .fallbackFailed:
            return "the supplemental ARM64 assembler rejected the instruction"
        case .fallbackReturnedWrongByteCount(let count):
            return "the supplemental assembler returned \(count) bytes for one ARM64 instruction"
        case .fallbackRoundTripWordMismatch:
            return "the supplemental assembler did not reproduce its canonical instruction word"
        case .fallbackCanonicalTextMismatch:
            return "the supplemental assembler returned incompatible instruction semantics"
        case .macScopeDecoderRejectedFallback:
            return "MacScope could not independently decode the supplemental instruction word"
        case .macScopeDecoderSemanticMismatch:
            return "MacScope decoded different semantics for the supplemental instruction word"
        }
    }
}

enum ARM64AssemblyBackendResult: Sendable, Equatable {
    case success(ARM64AssemblyProduct)
    case failure(ARM64AssemblyRoutingFailure)
}

protocol ARM64AssemblyPrimaryBackend: Sendable {
    func assemble(_ text: String, at address: UInt64) -> ARM64PrimaryAssemblyOutcome
}

/// Narrow direct-source seam. The concrete vendor adapter is intentionally separate from this
/// router so this boundary can be tested without importing or compiling third-party code.
protocol ARM64AssemblyFallbackBackend: Sendable {
    func assemble(
        _ text: String,
        architecture: ARM64AssemblyArchitecture
    ) throws -> [UInt8]

    func disassemble(
        _ bytes: [UInt8],
        architecture: ARM64AssemblyArchitecture
    ) throws -> String
}

struct MacScopeARM64AssemblyBackend: ARM64AssemblyPrimaryBackend {
    func assemble(_ text: String, at address: UInt64) -> ARM64PrimaryAssemblyOutcome {
        Self.classify(
            ARM64Assembler().assemble(text, at: address),
            requestedText: text,
            address: address
        )
    }

    static func classify(
        _ result: ARM64Assembler.Result,
        requestedText: String,
        address: UInt64
    ) -> ARM64PrimaryAssemblyOutcome {
        switch result {
        case .success(let bytes):
            let canonical = canonicalText(for: bytes, address: address) ?? requestedText
            return .success(ARM64AssemblyProduct(
                bytes: bytes,
                canonicalText: canonical,
                backend: .macScopePrimary
            ))
        case .failure(.unsupportedInstructionFamily(let mnemonic)):
            return .unsupportedInstructionFamily(mnemonic)
        case .failure(let diagnostic):
            return .rejected(boundedAppDiagnostic(diagnostic.description))
        }
    }

    private static func canonicalText(for bytes: [UInt8], address: UInt64) -> String? {
        guard bytes.count == 4 else { return nil }
        let decoded = ARM64Decoder().decode(
            Data(bytes),
            baseAddress: address,
            maxInstructionCount: 1
        )
        guard decoded.count == 1,
              decoded[0].mnemonic != "unknown",
              decoded[0].mnemonic != "unavailable" else {
            return nil
        }
        return decoded[0].operands.isEmpty
            ? decoded[0].mnemonic
            : "\(decoded[0].mnemonic) \(decoded[0].operands)"
    }

    /// MacScope owns these diagnostics, but their bounded fields can include user input. Normalize
    /// control characters and cap the presentation surface without changing classification.
    private static func boundedAppDiagnostic(_ diagnostic: String) -> String {
        let oneLine = diagnostic.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
        }
        return String(String(oneLine).prefix(512))
    }
}

/// MacScope remains authoritative. A supplemental source is consulted only for the new typed
/// unsupported-family outcome; every other primary diagnostic terminates routing immediately.
struct ARM64AssemblyRouter: Sendable {
    private let primary: any ARM64AssemblyPrimaryBackend
    private let fallback: (any ARM64AssemblyFallbackBackend)?

    init(
        primary: any ARM64AssemblyPrimaryBackend = MacScopeARM64AssemblyBackend(),
        fallback: (any ARM64AssemblyFallbackBackend)? = nil
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func assemble(
        _ text: String,
        at address: UInt64,
        architecture: ARM64AssemblyArchitecture?
    ) -> ARM64AssemblyBackendResult {
        switch primary.assemble(text, at: address) {
        case .success(let product):
            return .success(product)
        case .rejected(let reason):
            return .failure(.primaryRejected(reason))
        case .unsupportedInstructionFamily:
            break
        }

        guard Self.pcRelativeFallbackPolicy(for: text) != .reject else {
            return .failure(.addressSensitiveFallbackUnsupported)
        }
        guard let architecture else {
            return .failure(.fallbackArchitectureUnavailable)
        }
        guard let fallback else {
            return .failure(.fallbackUnavailable)
        }

        let bytes: [UInt8]
        do {
            bytes = try fallback.assemble(text, architecture: architecture)
        } catch {
            return .failure(.fallbackFailed)
        }
        guard bytes.count == 4 else {
            return .failure(.fallbackReturnedWrongByteCount(bytes.count))
        }

        let canonical: String
        do {
            canonical = try fallback.disassemble(bytes, architecture: architecture)
        } catch {
            return .failure(.fallbackFailed)
        }
        guard Self.instructionsAreCompatible(text, canonical) else {
            return .failure(.fallbackCanonicalTextMismatch)
        }

        let canonicalBytes: [UInt8]
        do {
            canonicalBytes = try fallback.assemble(canonical, architecture: architecture)
        } catch {
            return .failure(.fallbackFailed)
        }
        guard canonicalBytes.count == 4 else {
            return .failure(.fallbackReturnedWrongByteCount(canonicalBytes.count))
        }
        guard canonicalBytes == bytes else {
            return .failure(.fallbackRoundTripWordMismatch)
        }

        let decoded = ARM64Decoder().decode(
            Data(bytes),
            baseAddress: address,
            maxInstructionCount: 1
        )
        guard decoded.count == 1,
              decoded[0].mnemonic != "unknown",
              decoded[0].mnemonic != "unavailable" else {
            return .failure(.macScopeDecoderRejectedFallback)
        }
        let macScopeCanonical = decoded[0].operands.isEmpty
            ? decoded[0].mnemonic
            : "\(decoded[0].mnemonic) \(decoded[0].operands)"
        guard Self.instructionsAreCompatible(canonical, macScopeCanonical, at: address) else {
            return .failure(.macScopeDecoderSemanticMismatch)
        }

        return .success(ARM64AssemblyProduct(
            bytes: bytes,
            canonicalText: canonical,
            backend: .swiftAssemblySourceFallback
        ))
    }

    private enum PCRelativeFallbackPolicy: Equatable {
        case notPCRelative
        case explicitRelative
        case reject
    }

    /// The supplemental one-word API has no real-PC input. Admit a PC-relative request only when
    /// the target operand is an explicit numeric `#offset`; decimal/hex absolute targets, labels,
    /// symbols, and malformed or missing target operands all fail closed.
    private static func pcRelativeFallbackPolicy(for text: String) -> PCRelativeFallbackPolicy {
        guard let instruction = ParsedInstruction(text) else { return .notPCRelative }
        let targetIndex: Int?
        switch instruction.mnemonic {
        case "b", "bl":
            targetIndex = 0
        case let mnemonic where mnemonic.hasPrefix("b."):
            targetIndex = 0
        case "cbz", "cbnz":
            targetIndex = 1
        case "tbz", "tbnz":
            targetIndex = 2
        case "adr", "adrp":
            targetIndex = 1
        case "autiasppc", "autibsppc", "retaasppc", "retabsppc":
            // FEAT_PAuth_LR label forms: operand 0 is the PC-relative signing-site label.
            targetIndex = 0
        case "ldr", "ldrsw", "prfm":
            guard instruction.operands.count > 1,
                  !instruction.operands[1].trimmingCharacters(in: .whitespaces).hasPrefix("[") else {
                return .notPCRelative
            }
            targetIndex = 1
        default:
            targetIndex = nil
        }
        guard let targetIndex else { return .notPCRelative }
        guard instruction.operands.indices.contains(targetIndex) else { return .reject }
        return isExplicitNumericRelativeOffset(instruction.operands[targetIndex])
            ? .explicitRelative : .reject
    }

    private static func isExplicitNumericRelativeOffset(_ operand: String) -> Bool {
        var body = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard body.first == "#" else { return false }
        body.removeFirst()
        if body.first == "+" || body.first == "-" {
            body.removeFirst()
        }
        guard !body.isEmpty else { return false }
        if body.hasPrefix("0x") {
            body.removeFirst(2)
            return !body.isEmpty && body.allSatisfy(isASCIIHexDigit)
        }
        return body.allSatisfy(isASCIIDecimalDigit)
    }

    private struct ParsedInstruction {
        let mnemonic: String
        let operands: [String]

        init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let split = trimmed.firstIndex(where: { $0.isWhitespace })
            if let split {
                mnemonic = String(trimmed[..<split]).lowercased()
                let operandStart = trimmed[split...]
                    .drop(while: { $0.isWhitespace })
                operands = Self.splitOperands(String(operandStart)).map(Self.normalizeOperand)
            } else {
                mnemonic = trimmed.lowercased()
                operands = []
            }
        }

        private static func splitOperands(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var result: [String] = []
            var start = text.startIndex
            var squareDepth = 0
            var braceDepth = 0
            var parenthesisDepth = 0
            for index in text.indices {
                switch text[index] {
                case "[": squareDepth += 1
                case "]": squareDepth = max(0, squareDepth - 1)
                case "{": braceDepth += 1
                case "}": braceDepth = max(0, braceDepth - 1)
                case "(": parenthesisDepth += 1
                case ")": parenthesisDepth = max(0, parenthesisDepth - 1)
                case "," where squareDepth == 0 && braceDepth == 0 && parenthesisDepth == 0:
                    result.append(String(text[start..<index]))
                    start = text.index(after: index)
                default: break
                }
            }
            result.append(String(text[start...]))
            return result
        }

        private static func normalizeOperand(_ operand: String) -> String {
            let compact = operand.lowercased().filter { !$0.isWhitespace }
            return ARM64AssemblyRouter.canonicalizingImmediateTokens(in: compact)
        }
    }

    /// Exact mnemonic+operand equality is the default. The directional alias rules below are the
    /// complete admitted set and encode their implicit zero-register/source relationships.
    private static func instructionsAreCompatible(
        _ lhs: String,
        _ rhs: String,
        at address: UInt64? = nil
    ) -> Bool {
        guard let lhs = ParsedInstruction(lhs), let rhs = ParsedInstruction(rhs) else {
            return false
        }
        if lhs.mnemonic == rhs.mnemonic && lhs.operands == rhs.operands {
            return true
        }
        if aliasInstruction(lhs, expandsTo: rhs)
            || aliasInstruction(rhs, expandsTo: lhs)
        {
            return true
        }
        guard let address else { return false }
        return pcRelativeInstruction(lhs, decodesAs: rhs, at: address)
            || pcRelativeInstruction(rhs, decodesAs: lhs, at: address)
    }

    /// MacScope renders an independently decoded PC-relative word using its real absolute target,
    /// while the addressless supplemental assembler must render the admitted explicit `#offset`.
    /// Compare those two representations without ever treating an input absolute address as an
    /// offset. Every non-target operand remains exact and operand-position aware.
    private static func pcRelativeInstruction(
        _ relative: ParsedInstruction,
        decodesAs absolute: ParsedInstruction,
        at address: UInt64
    ) -> Bool {
        guard relative.mnemonic == absolute.mnemonic,
              relative.operands.count == absolute.operands.count,
              let targetIndex = pcRelativeTargetIndex(relative),
              relative.operands.indices.contains(targetIndex),
              absolute.operands.indices.contains(targetIndex),
              let offset = signedImmediate(relative.operands[targetIndex]),
              let decodedTarget = unsignedAddress(absolute.operands[targetIndex]),
              operandsMatchExceptTarget(relative.operands, absolute.operands, targetIndex: targetIndex)
        else {
            return false
        }

        let base = relative.mnemonic == "adrp" ? address & ~UInt64(0xfff) : address
        guard let expectedTarget = addingSignedOffset(offset, to: base) else { return false }
        return decodedTarget == expectedTarget
    }

    private static func pcRelativeTargetIndex(_ instruction: ParsedInstruction) -> Int? {
        switch instruction.mnemonic {
        case "b", "bl": return 0
        case let mnemonic where mnemonic.hasPrefix("b."): return 0
        case "cbz", "cbnz": return 1
        case "tbz", "tbnz": return 2
        case "adr", "adrp", "ldr", "ldrsw", "prfm": return 1
        case "autiasppc", "autibsppc", "retaasppc", "retabsppc": return 0
        default: return nil
        }
    }

    private static func operandsMatchExceptTarget(
        _ lhs: [String],
        _ rhs: [String],
        targetIndex: Int
    ) -> Bool {
        for index in lhs.indices where index != targetIndex {
            guard lhs[index] == rhs[index] else { return false }
        }
        return true
    }

    private static func signedImmediate(_ operand: String) -> Int64? {
        guard operand.first == "#" else { return nil }
        return Int64(operand.dropFirst())
    }

    private static func unsignedAddress(_ operand: String) -> UInt64? {
        if operand.hasPrefix("0x") {
            return UInt64(operand.dropFirst(2), radix: 16)
        }
        return UInt64(operand)
    }

    private static func addingSignedOffset(_ offset: Int64, to base: UInt64) -> UInt64? {
        if offset >= 0 {
            let (value, overflow) = base.addingReportingOverflow(UInt64(offset))
            return overflow ? nil : value
        }
        let magnitude = UInt64(offset.magnitude)
        guard magnitude <= base else { return nil }
        return base - magnitude
    }

    /// Canonicalize numeric immediate tokens without interpreting registers, labels, memory
    /// syntax, or other vendor grammar. This admits harmless decimal/hex formatting differences
    /// while preserving the complete operand structure.
    private static func canonicalizingImmediateTokens(in operand: String) -> String {
        var result = ""
        var index = operand.startIndex
        while index < operand.endIndex {
            guard operand[index] == "#" else {
                result.append(operand[index])
                index = operand.index(after: index)
                continue
            }

            let tokenStart = index
            var cursor = operand.index(after: index)
            if cursor < operand.endIndex, operand[cursor] == "+" || operand[cursor] == "-" {
                cursor = operand.index(after: cursor)
            }
            let digitsStart = cursor
            let radix: Int
            if operand[cursor...].hasPrefix("0x") {
                radix = 16
                cursor = operand.index(cursor, offsetBy: 2)
                while cursor < operand.endIndex, operand[cursor].isHexDigit {
                    cursor = operand.index(after: cursor)
                }
            } else {
                radix = 10
                while cursor < operand.endIndex, isASCIIDecimalDigit(operand[cursor]) {
                    cursor = operand.index(after: cursor)
                }
            }
            guard cursor > digitsStart else {
                result.append("#")
                index = operand.index(after: index)
                continue
            }

            let token = String(operand[operand.index(after: tokenStart)..<cursor])
            let negative = token.hasPrefix("-")
            var unsignedToken = token
            if unsignedToken.hasPrefix("+") || unsignedToken.hasPrefix("-") {
                unsignedToken.removeFirst()
            }
            if radix == 16 {
                unsignedToken.removeFirst(2)
            }
            guard let magnitude = UInt64(unsignedToken, radix: radix),
                  magnitude <= UInt64(Int64.max) + (negative ? UInt64(1) : UInt64(0))
            else {
                result += String(operand[tokenStart..<cursor])
                index = cursor
                continue
            }
            let value: Int64
            if negative, magnitude == UInt64(Int64.max) + 1 {
                value = Int64.min
            } else {
                value = negative ? -Int64(magnitude) : Int64(magnitude)
            }
            result += "#\(value)"
            index = cursor
        }
        return result
    }

    private static func isASCIIDecimalDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(value)
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(value)
            || (65...70).contains(value)
            || (97...102).contains(value)
    }

    private static func aliasInstruction(
        _ alias: ParsedInstruction,
        expandsTo base: ParsedInstruction
    ) -> Bool {
        switch (alias.mnemonic, base.mnemonic) {
        case ("cmp", "subs"), ("cmn", "adds"), ("tst", "ands"):
            guard alias.operands.count >= 2,
                  base.operands.count == alias.operands.count + 1,
                  isWidthMatchedZeroRegister(base.operands[0], comparedWith: alias.operands[0]) else {
                return false
            }
            return Array(base.operands.dropFirst()) == alias.operands

        case ("mov", "orr"), ("mvn", "orn"):
            guard alias.operands.count == 2,
                  base.operands.count == 3,
                  alias.operands[0] == base.operands[0],
                  alias.operands[1] == base.operands[2],
                  isWidthMatchedZeroRegister(base.operands[1], comparedWith: alias.operands[0]) else {
                return false
            }
            return true

        case ("neg", "sub"), ("negs", "subs"):
            guard alias.operands.count >= 2,
                  base.operands.count == alias.operands.count + 1,
                  alias.operands[0] == base.operands[0],
                  isWidthMatchedZeroRegister(base.operands[1], comparedWith: alias.operands[0]) else {
                return false
            }
            return Array(base.operands.dropFirst(2)) == Array(alias.operands.dropFirst())

        case ("mul", "madd"), ("mneg", "msub"):
            guard alias.operands.count == 3,
                  base.operands.count == 4,
                  Array(base.operands.prefix(3)) == alias.operands,
                  isWidthMatchedZeroRegister(base.operands[3], comparedWith: alias.operands[0]) else {
                return false
            }
            return true

        case ("ror", "extr"):
            guard alias.operands.count == 3,
                  base.operands.count == 4,
                  alias.operands[0] == base.operands[0],
                  alias.operands[1] == base.operands[1],
                  alias.operands[1] == base.operands[2],
                  alias.operands[2] == base.operands[3] else {
                return false
            }
            return true

        default:
            return false
        }
    }

    private static func isWidthMatchedZeroRegister(
        _ zeroRegister: String,
        comparedWith register: String
    ) -> Bool {
        if register.hasPrefix("x") || register == "sp" {
            return zeroRegister == "xzr"
        }
        if register.hasPrefix("w") || register == "wsp" {
            return zeroRegister == "wzr"
        }
        return false
    }
}
