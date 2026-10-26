import Foundation

/// The deliberately small data-pointer grammar shared by strict ABI binding,
/// argument type inference, and struct-field rendering. `pointeeWords` has only
/// base cv-qualifiers removed; pointer qualifiers and star count are represented
/// separately so `T **` can never be mistaken for a direct `T *` field base.
struct DarwinARM64NormalizedDataPointer: Sendable {
    let pointeeWords: [String]
    let indirectionLevel: Int

    var catalogStructName: String? {
        guard indirectionLevel == 1 else { return nil }
        if pointeeWords.count == 2, pointeeWords[0] == "struct" {
            return pointeeWords[1]
        }
        if pointeeWords.count == 1 {
            // Opaque typedef pointers such as `Foo *` may name a catalog struct.
            // Scalar words harmlessly miss the catalog lookup at the call site.
            return pointeeWords[0]
        }
        return nil
    }
}

/// Strict source-order binding for the scalar subset of the Darwin arm64 ABI.
///
/// This binder is deliberately independent from `CallSignatureCatalog`: the
/// latter has a permissive unknown-type fallback that is useful for legacy call
/// display, while an authoritative function declaration must abstain rather
/// than attach a source row to the wrong incoming value.
public enum DarwinARM64ParameterBinder: Sendable {
    public static func bind(
        parameterTypes: [String],
        isVariadic: Bool = false
    ) -> [MacIRABIParameterLocation] {
        // An ellipsis is not a named formal and therefore consumes no cursor.
        // Retaining this argument makes that contract explicit at call sites.
        _ = isVariadic

        var nextGPR = 0
        var nextSIMD = 0
        var nextStackByteOffset = 0
        var classificationIsPoisoned = false

        return parameterTypes.map { originalType in
            guard !classificationIsPoisoned else {
                return .unbound(reason: .dependentOnUnsupportedEarlierParameter)
            }

            guard let scalar = classify(originalType) else {
                classificationIsPoisoned = true
                return .unbound(reason: .unsupportedType(originalType))
            }

            switch scalar.bank {
            case .gpr:
                if nextGPR < 8 {
                    defer { nextGPR += 1 }
                    return .gpr(index: nextGPR, carrierWidth: scalar.registerWidth)
                }
            case .simd:
                if nextSIMD < 8 {
                    defer { nextSIMD += 1 }
                    return .simd(index: nextSIMD, scalarWidth: scalar.registerWidth)
                }
            }

            nextStackByteOffset = aligned(nextStackByteOffset, to: scalar.alignment)
            let location = MacIRABIParameterLocation.entryStack(
                byteOffset: nextStackByteOffset,
                size: scalar.size,
                alignment: scalar.alignment
            )
            nextStackByteOffset += scalar.size
            return location
        }
    }

    /// Whether a legacy persisted type is proven to consume the Darwin GPR
    /// scalar channel. Persistence migration uses this narrow boolean instead of
    /// maintaining a second type grammar: integer scalars and data pointers may
    /// migrate, while FP, malformed, contradictory, and unsupported spellings
    /// remain quarantined.
    static func isSupportedLegacyGPRScalar(_ type: String) -> Bool {
        guard let scalar = classify(type) else { return false }
        if case .gpr = scalar.bank { return true }
        return false
    }

    private enum RegisterBank: Sendable {
        case gpr
        case simd
    }

    private struct ScalarLayout: Sendable {
        var bank: RegisterBank
        var registerWidth: Int
        var size: Int
        var alignment: Int

        static func integer(size: Int) -> Self {
            Self(
                bank: .gpr,
                registerWidth: size <= 4 ? 32 : 64,
                size: size,
                alignment: size
            )
        }

        static func floating(size: Int) -> Self {
            Self(
                bank: .simd,
                registerWidth: size * 8,
                size: size,
                alignment: size
            )
        }
    }

    private enum PointerToken {
        case word(String)
        case star
    }

    private static let cvQualifiers: Set<String> = ["const", "volatile"]
    private static let pointerQualifiers: Set<String> = [
        "const", "volatile", "restrict", "__restrict", "__restrict__",
    ]
    private static let reservedKeywords: Set<String> = [
        // C language keywords.
        "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic",
        "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local",
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "inline", "int", "long", "register", "restrict", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while",

        // C++ keywords that must not be mistaken for opaque C typedef names.
        "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor", "bool",
        "catch", "char8_t", "char16_t", "char32_t", "class", "compl", "concept",
        "const_cast", "consteval", "constexpr", "constinit", "co_await", "co_return",
        "co_yield", "decltype", "delete", "dynamic_cast", "explicit", "export",
        "false", "friend", "mutable", "namespace", "new", "noexcept", "not",
        "not_eq", "nullptr", "operator", "or", "or_eq", "private", "protected",
        "public", "reinterpret_cast", "requires", "static_assert", "static_cast",
        "template", "this", "thread_local", "throw", "true", "try", "typeid",
        "typename", "using", "virtual", "wchar_t", "xor", "xor_eq",
    ]

    private static func classify(_ type: String) -> ScalarLayout? {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if normalizedDataPointer(trimmed) != nil {
            return .integer(size: 8)
        }

        guard let words = plainWords(trimmed) else { return nil }
        return classifyScalarWords(words)
    }

    private static func classifyScalarWords(_ words: [String]) -> ScalarLayout? {
        let unqualified = words.filter { !cvQualifiers.contains($0) }
        guard !unqualified.isEmpty else { return nil }

        switch unqualified {
        case ["float"]:
            return .floating(size: 4)
        case ["double"], ["long", "double"]:
            // `long double` is an IEEE-754 binary64 value in the Darwin arm64 ABI.
            return .floating(size: 8)
        default:
            break
        }

        if unqualified.count == 1,
           let size = knownIntegerTypedefSize(unqualified[0]) {
            return .integer(size: size)
        }

        guard let size = fundamentalIntegerSize(unqualified) else { return nil }
        return .integer(size: size)
    }

    private static func knownIntegerTypedefSize(_ type: String) -> Int? {
        switch type {
        case "_Bool", "bool", "BOOL", "int8_t", "uint8_t":
            1
        case "int16_t", "uint16_t", "unichar":
            2
        case "mode_t":
            2
        case "int32_t", "uint32_t", "wchar_t", "pid_t", "uid_t", "gid_t", "socklen_t":
            4
        case "int64_t", "uint64_t", "intmax_t", "uintmax_t", "intptr_t", "uintptr_t",
             "ptrdiff_t", "size_t", "ssize_t", "off_t", "NSInteger", "NSUInteger",
             "time_t", "clock_t":
            8
        default:
            nil
        }
    }

    /// Recognizes only C fundamental integer spellings. Word order is flexible
    /// where C permits it (`unsigned long` and `long unsigned`), but duplicate or
    /// contradictory specifiers fail closed.
    private static func fundamentalIntegerSize(_ words: [String]) -> Int? {
        var signedCount = 0
        var unsignedCount = 0
        var charCount = 0
        var shortCount = 0
        var intCount = 0
        var longCount = 0

        for word in words {
            switch word {
            case "signed": signedCount += 1
            case "unsigned": unsignedCount += 1
            case "char": charCount += 1
            case "short": shortCount += 1
            case "int": intCount += 1
            case "long": longCount += 1
            default: return nil
            }
        }

        guard signedCount <= 1,
              unsignedCount <= 1,
              signedCount + unsignedCount <= 1,
              charCount <= 1,
              shortCount <= 1,
              intCount <= 1,
              longCount <= 2 else {
            return nil
        }

        if charCount == 1 {
            guard shortCount == 0, intCount == 0, longCount == 0 else { return nil }
            return 1
        }

        if shortCount == 1 {
            guard charCount == 0, longCount == 0 else { return nil }
            return 2
        }

        if longCount > 0 {
            guard charCount == 0, shortCount == 0 else { return nil }
            return 8
        }

        guard intCount == 1 || signedCount == 1 || unsignedCount == 1 else { return nil }
        return 4
    }

    /// Accepts data-pointer abstract type spellings only. Function declarators,
    /// arrays, references, blocks, and words after a pointer qualifier are
    /// rejected instead of being guessed from the presence of `*`.
    static func normalizedDataPointer(_ type: String) -> DarwinARM64NormalizedDataPointer? {
        guard let tokens = pointerTokens(type),
              let firstStar = tokens.firstIndex(where: {
                  if case .star = $0 { return true }
                  return false
              }) else {
            return nil
        }

        let baseTokens = tokens[..<firstStar]
        let baseWords = baseTokens.compactMap { token -> String? in
            guard case let .word(word) = token else { return nil }
            return word
        }
        guard baseWords.count == baseTokens.count,
              isProvablePointeeType(baseWords) else {
            return nil
        }

        var indirectionLevel = 0
        for token in tokens[firstStar...] {
            switch token {
            case .star:
                indirectionLevel += 1
                continue
            case let .word(word):
                guard pointerQualifiers.contains(word) else { return nil }
            }
        }
        return DarwinARM64NormalizedDataPointer(
            pointeeWords: baseWords.filter { !cvQualifiers.contains($0) },
            indirectionLevel: indirectionLevel
        )
    }

    private static func isProvablePointeeType(_ words: [String]) -> Bool {
        let aggregateKeywords: Set<String> = ["struct", "union", "enum"]
        if let keywordIndex = words.firstIndex(where: aggregateKeywords.contains) {
            guard words[..<keywordIndex].allSatisfy(cvQualifiers.contains),
                  words.indices.contains(keywordIndex + 1) else {
                return false
            }

            let tagIndex = keywordIndex + 1
            let tag = words[tagIndex]
            guard isIdentifier(tag),
                  !reservedKeywords.contains(tag),
                  !pointerQualifiers.contains(tag) else {
                return false
            }

            let suffixStart = tagIndex + 1
            return words[suffixStart...].allSatisfy(cvQualifiers.contains)
        }

        let unqualified = words.filter { !cvQualifiers.contains($0) }
        guard !unqualified.isEmpty else { return false }

        if unqualified == ["void"] || classifyScalarWords(unqualified) != nil {
            return true
        }

        // A single well-formed identifier is a provable pointer carrier even
        // when its pointee typedef is opaque to the decompiler.
        return unqualified.count == 1
            && isIdentifier(unqualified[0])
            && !reservedKeywords.contains(unqualified[0])
            && !pointerQualifiers.contains(unqualified[0])
    }

    private static func plainWords(_ type: String) -> [String]? {
        let words = type.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.allSatisfy(isIdentifier) else { return nil }
        return words
    }

    private static func pointerTokens(_ type: String) -> [PointerToken]? {
        var tokens: [PointerToken] = []
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(.word(word))
            word.removeAll(keepingCapacity: true)
        }

        for character in type {
            if character.isWhitespace {
                flushWord()
            } else if character == "*" {
                flushWord()
                tokens.append(.star)
            } else if character == "_" || character.isLetter || (character.isNumber && !word.isEmpty) {
                word.append(character)
            } else {
                return nil
            }
        }
        flushWord()
        return tokens.isEmpty ? nil : tokens
    }

    private static func isIdentifier(_ word: String) -> Bool {
        guard let first = word.first,
              first == "_" || first.isLetter else {
            return false
        }
        return word.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func aligned(_ offset: Int, to alignment: Int) -> Int {
        let remainder = offset % alignment
        return remainder == 0 ? offset : offset + alignment - remainder
    }
}

// MARK: - Binder-only rich ABI model (deliberately not a MacIR API)

/// The resolver classifies shape, but obtains size/alignment from the Type Atlas
/// layout engine. No register-allocation policy belongs in the resolver.
public protocol DarwinARM64TypeLayoutResolving: Sendable {
    func resolveLayout(ofType type: String) -> DarwinARM64TypeLayout?
}

public struct DarwinARM64TypeLayout: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case integer, floating, shortVector, aggregate }
    public enum HomogeneousBase: Equatable, Sendable {
        case floating(byteSize: Int)
        case shortVector(byteSize: Int)

        public var byteSize: Int {
            switch self {
            case let .floating(size), let .shortVector(size): size
            }
        }
    }
    public struct HomogeneousAggregate: Equatable, Sendable {
        public let base: HomogeneousBase
        public let memberOffsets: [Int]
        public var count: Int { memberOffsets.count }
        public init(base: HomogeneousBase, memberOffsets: [Int]) {
            self.base = base
            self.memberOffsets = memberOffsets
        }
    }
    public let kind: Kind
    public let size: Int
    public let alignment: Int
    public let homogeneous: HomogeneousAggregate?
    public init(kind: Kind, size: Int, alignment: Int, homogeneous: HomogeneousAggregate? = nil) {
        self.kind = kind
        self.size = size
        self.alignment = alignment
        self.homogeneous = homogeneous
    }
}

public enum DarwinARM64RichRegister: Hashable, Sendable {
    case gpr(index: Int, carrierWidth: Int)
    case simd(index: Int, registerWidth: Int)
}

/// Value ranges are in increasing source-object memory order, independent of
/// carrier width. A final GPR chunk can contain fewer than eight value bytes.
public struct DarwinARM64RichParameterPiece: Hashable, Sendable {
    public let register: DarwinARM64RichRegister
    public let valueByteOffset: Int
    public let size: Int
    public init(register: DarwinARM64RichRegister, valueByteOffset: Int, size: Int) {
        self.register = register
        self.valueByteOffset = valueByteOffset
        self.size = size
    }
}

public enum DarwinARM64RichPointerCarrier: Hashable, Sendable {
    case gpr(index: Int)
    case entryStack(byteOffset: Int)
}

public enum DarwinARM64RichParameterLocation: Hashable, Sendable {
    case gpr(index: Int, carrierWidth: Int)
    case simd(index: Int, registerWidth: Int)
    case entryStack(byteOffset: Int, size: Int, alignment: Int)
    case composite(pieces: [DarwinARM64RichParameterPiece])
    case indirect(pointer: DarwinARM64RichPointerCarrier, pointeeSize: Int, pointeeAlignment: Int)
    case unbound(reason: MacIRABIUnboundReason)
}

public enum DarwinARM64RichReturnLocation: Hashable, Sendable {
    case void
    case single(DarwinARM64RichRegister)
    case composite(pieces: [DarwinARM64RichParameterPiece])
    /// x8 supplies the caller's result buffer on entry; it is not a returned x8 value.
    case indirect(resultPointerRegister: Int, pointeeSize: Int, pointeeAlignment: Int)
    case unbound(reason: MacIRABIUnboundReason)
}

extension DarwinARM64ParameterBinder {
    /// Admission for direct non-HFA structs passed in dense GPRs (integer and
    /// mixed integer/FP leaves). A plain aggregate layout alone is insufficient:
    /// the leaf gate excludes pointer-bearing and uncertain aggregates.
    static func isSupportedDirectGPRStruct(
        _ type: String,
        pieces: [DarwinARM64RichParameterPiece],
        resolver: any DarwinARM64TypeLayoutResolving
    ) -> Bool {
        guard let atlas = resolver as? TypeAtlasDarwinARM64LayoutResolver,
              atlas.isDirectGPRStruct(type),
              let layout = atlas.resolveLayout(ofType: type),
              pieces.count == (layout.size + 7) / 8,
              (1...2).contains(pieces.count),
              case let .gpr(first, _) = pieces[0].register else { return false }
        return pieces.enumerated().allSatisfy { ordinal, piece in
            guard case let .gpr(index, width) = piece.register,
                  (0..<8).contains(index), index == first + ordinal,
                  (width == 64 || (layout.size <= 4 && width == 32)) else { return false }
            return piece.valueByteOffset == ordinal * 8 &&
                piece.size == min(8, layout.size - ordinal * 8)
        }
    }

    /// Source-order named formals only. Anonymous variadic actuals and their
    /// default promotions remain outside this API, just as with `bind`.
    /// The legacy `bind` intentionally continues to abstain on all richer shapes.
    public static func bindRich(
        parameterTypes: [String],
        isVariadic: Bool = false,
        resolver: any DarwinARM64TypeLayoutResolving = TypeAtlasDarwinARM64LayoutResolver()
    ) -> [DarwinARM64RichParameterLocation] {
        _ = isVariadic
        var gpr = 0
        var simd = 0
        var stack = 0
        var poisoned = false

        func stackLocation(size: Int, alignment: Int) -> DarwinARM64RichParameterLocation? {
            let remainder = stack % alignment
            let (offset, overflow) = stack.addingReportingOverflow(remainder == 0 ? 0 : alignment - remainder)
            let (end, endOverflow) = offset.addingReportingOverflow(size)
            guard !overflow, !endOverflow else { return nil }
            stack = end
            return .entryStack(byteOffset: offset, size: size, alignment: alignment)
        }

        return parameterTypes.map { type in
            guard !poisoned else { return .unbound(reason: .dependentOnUnsupportedEarlierParameter) }
            func unsupported() -> DarwinARM64RichParameterLocation {
                poisoned = true
                return .unbound(reason: .unsupportedType(type))
            }
            guard let layout = richLayout(type, resolver: resolver) else { return unsupported() }
            if let homogeneous = layout.homogeneous {
                if simd + homogeneous.count <= 8 {
                    let pieces = homogeneous.memberOffsets.enumerated().map { member, offset in
                        DarwinARM64RichParameterPiece(register: .simd(index: simd + member, registerWidth: homogeneous.base.byteSize * 8),
                                                       valueByteOffset: offset, size: homogeneous.base.byteSize)
                    }
                    simd += homogeneous.count
                    return .composite(pieces: pieces)
                }
                simd = 8 // no later scalar or smaller HFA may back-fill a hole
                return stackLocation(size: layout.size, alignment: homogeneous.base.byteSize) ?? unsupported()
            }
            switch layout.kind {
            case .floating, .shortVector:
                if simd < 8 {
                    defer { simd += 1 }
                    return .simd(index: simd, registerWidth: layout.size * 8)
                }
                return stackLocation(size: layout.size, alignment: layout.alignment) ?? unsupported()
            case .integer where layout.size <= 8:
                if gpr < 8 {
                    defer { gpr += 1 }
                    return .gpr(index: gpr, carrierWidth: layout.size <= 4 ? 32 : 64)
                }
                // Apple compact named scalar stack slots, without generic 8-byte padding.
                return stackLocation(size: layout.size, alignment: layout.alignment) ?? unsupported()
            case .integer:
                if gpr + 2 <= 8 {
                    let pieces = integerPieces(size: 16, firstGPR: gpr)
                    gpr += 2 // Darwin permits an odd starting GPR for int128.
                    return .composite(pieces: pieces)
                }
                gpr = 8
                return stackLocation(size: 16, alignment: 16) ?? unsupported()
            case .aggregate:
                if layout.size > 16 {
                    let pointer: DarwinARM64RichPointerCarrier
                    if gpr < 8 {
                        pointer = .gpr(index: gpr)
                        gpr += 1
                    } else {
                        guard let slot = stackLocation(size: 8, alignment: 8),
                              case let .entryStack(offset, _, _) = slot else { return unsupported() }
                        pointer = .entryStack(byteOffset: offset)
                    }
                    return .indirect(pointer: pointer, pointeeSize: layout.size, pointeeAlignment: layout.alignment)
                }
                let chunks = (layout.size + 7) / 8
                if gpr + chunks <= 8 {
                    let pieces = integerPieces(size: layout.size, firstGPR: gpr)
                    gpr += chunks
                    return .composite(pieces: pieces)
                }
                gpr = 8 // composite spills as a whole; never split registers and stack
                return stackLocation(size: chunks * 8, alignment: 8) ?? unsupported()
            }
        }
    }

    public static func returnLocation(
        for type: String,
        resolver: any DarwinARM64TypeLayoutResolving = TypeAtlasDarwinARM64LayoutResolver()
    ) -> DarwinARM64RichReturnLocation {
        if type.trimmingCharacters(in: .whitespacesAndNewlines) == "void" { return .void }
        guard let layout = richLayout(type, resolver: resolver) else { return .unbound(reason: .unsupportedType(type)) }
        if let homogeneous = layout.homogeneous {
            return .composite(pieces: homogeneous.memberOffsets.enumerated().map { member, offset in
                DarwinARM64RichParameterPiece(register: .simd(index: member, registerWidth: homogeneous.base.byteSize * 8),
                                               valueByteOffset: offset, size: homogeneous.base.byteSize)
            })
        }
        switch layout.kind {
        case .floating, .shortVector:
            return .single(.simd(index: 0, registerWidth: layout.size * 8))
        case .integer where layout.size <= 8:
            return .single(.gpr(index: 0, carrierWidth: layout.size <= 4 ? 32 : 64))
        case .integer:
            return .composite(pieces: integerPieces(size: 16, firstGPR: 0))
        case .aggregate where layout.size <= 16:
            return .composite(pieces: integerPieces(size: layout.size, firstGPR: 0, carrierWidth: layout.size <= 4 ? 32 : 64))
        case .aggregate:
            return .indirect(resultPointerRegister: 8, pointeeSize: layout.size, pointeeAlignment: layout.alignment)
        }
    }

    private static func integerPieces(size: Int, firstGPR: Int, carrierWidth: Int = 64) -> [DarwinARM64RichParameterPiece] {
        stride(from: 0, to: size, by: 8).map { offset in
            DarwinARM64RichParameterPiece(register: .gpr(index: firstGPR + offset / 8, carrierWidth: carrierWidth),
                                           valueByteOffset: offset, size: min(8, size - offset))
        }
    }

    private static func richLayout(_ type: String, resolver: any DarwinARM64TypeLayoutResolving) -> DarwinARM64TypeLayout? {
        let layout: DarwinARM64TypeLayout
        // Preserve the complete existing scalar grammar (including SDK scalar aliases).
        if let scalar = classify(type) {
            layout = DarwinARM64TypeLayout(kind: scalar.bank == .gpr ? .integer : .floating,
                                           size: scalar.size, alignment: scalar.alignment)
        } else if let resolved = resolver.resolveLayout(ofType: type) {
            layout = resolved
        } else {
            return nil
        }
        // Do not trust malformed custom resolvers with cursor arithmetic or carrier widths.
        guard layout.size > 0, layout.alignment > 0,
              layout.alignment.nonzeroBitCount == 1 else { return nil }
        if let homogeneous = layout.homogeneous {
            guard layout.kind == .aggregate, (1...4).contains(homogeneous.count) else { return nil }
            switch homogeneous.base {
            case let .floating(size): guard [4, 8].contains(size) else { return nil }
            case let .shortVector(size): guard [8, 16].contains(size) else { return nil }
            }
            let size = homogeneous.base.byteSize
            guard layout.size == size * homogeneous.count, layout.alignment <= size,
                  homogeneous.memberOffsets == (0..<homogeneous.count).map({ $0 * size }) else { return nil }
        } else {
            switch layout.kind {
            case .integer: guard [1, 2, 4, 8, 16].contains(layout.size), layout.alignment == layout.size else { return nil }
            case .floating: guard [4, 8].contains(layout.size), layout.alignment == layout.size else { return nil }
            case .shortVector: guard [8, 16].contains(layout.size), layout.alignment == layout.size else { return nil }
            case .aggregate:
                // No call-oracle case establishes ordinary 16-byte-aligned composites.
                // HVA is separately verified above; don't guess this other ABI category.
                guard layout.alignment < 16, layout.size.isMultiple(of: layout.alignment) else { return nil }
            }
        }
        return layout
    }
}
