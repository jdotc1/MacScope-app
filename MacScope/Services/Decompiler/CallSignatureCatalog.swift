import Foundation

/// HOP-5c: a callee's `format` attribute as the SDK header declares it (`__printflike`,
/// `NS_FORMAT_FUNCTION`, `CF_FORMAT_FUNCTION`, ...). Indices are 1-based like the attribute;
/// `firstArgIndex` is 0 for a `va_list` consumer, which has no variadic tail to recover.
public struct CallFormatAttribute: Sendable, Hashable {
    /// The attribute's archetype as clang prints it (`printf`, `NSString`, `CFString`, `os_log`, ...).
    public var kind: String
    public var formatIndex: Int
    public var firstArgIndex: Int
    public init(kind: String, formatIndex: Int, firstArgIndex: Int) {
        self.kind = kind
        self.formatIndex = formatIndex
        self.firstArgIndex = firstArgIndex
    }

    /// Whether this attribute describes a variadic tail that starts right after the fixed
    /// parameters of a signature with `fixedParameterCount` named parameters.
    public func describesVariadicTail(fixedParameterCount: Int) -> Bool {
        formatIndex >= 1
            && formatIndex <= fixedParameterCount
            && firstArgIndex == fixedParameterCount + 1
    }
}

/// A declarative call-signature entry. Parameters are listed in SOURCE order and
/// carry no register — the catalog assigns registers via AAPCS (see assignRegisters).
public struct CallSignatureSpec: Sendable, Hashable {
    public struct Param: Sendable, Hashable {
        public var type: String
        public var name: String
        public init(type: String, name: String) { self.type = type; self.name = name }
    }
    public var canonicalName: String     // undecorated, no leading "_"
    public var returnType: String
    public var parameters: [Param]
    public var isVariadic: Bool
    /// HOP-5c: the header's `format` attribute, when the source records one (the SDK pack).
    public var format: CallFormatAttribute?
    public init(canonicalName: String, returnType: String,
                parameters: [Param] = [], isVariadic: Bool = false,
                format: CallFormatAttribute? = nil) {
        self.canonicalName = canonicalName
        self.returnType = returnType
        self.parameters = parameters
        self.isVariadic = isVariadic
        self.format = format
    }
}

/// Resolves a call target symbol to a fully materialized MacIRCallSignature.
/// Owns canonicalization (strip one leading "_") and register assignment.
public struct CallSignatureCatalog: Sendable {
    private let byCanonicalName: [String: CallSignatureSpec]
    /// HOP-5c: the first `format` attribute any spec records for a name. A hand-written seed
    /// (e.g. `printf`) shadows the pack's signature but carries no attribute; the pack's
    /// attribute is attached to the winning signature only when it describes that exact
    /// signature's variadic tail (same fixed arity, tail right after the fixed parameters).
    private let formatByCanonicalName: [String: CallFormatAttribute]

    /// Seeds win over later duplicates so runtime lookup is deterministic; the
    /// corpus test (Task 6) separately asserts the corpus never shadows a seed.
    public init(_ specs: [CallSignatureSpec]) {
        var map: [String: CallSignatureSpec] = [:]
        var formats: [String: CallFormatAttribute] = [:]
        for spec in specs {
            if map[spec.canonicalName] == nil {
                map[spec.canonicalName] = spec
            }
            if let format = spec.format, formats[spec.canonicalName] == nil {
                formats[spec.canonicalName] = format
            }
        }
        byCanonicalName = map
        formatByCanonicalName = formats
    }

    /// The format attribute that applies to the winning signature for `canonical`, if any.
    func formatAttribute(for spec: CallSignatureSpec) -> CallFormatAttribute? {
        guard spec.isVariadic,
              let format = spec.format ?? formatByCanonicalName[spec.canonicalName],
              format.describesVariadicTail(fixedParameterCount: spec.parameters.count) else {
            return nil
        }
        return format
    }

    public func signature(for target: String) -> MacIRCallSignature? {
        let symbol = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
        guard let spec = byCanonicalName[canonical] else { return nil }
        return MacIRCallSignature(
            target: symbol,
            returnType: spec.returnType,
            parameters: Self.assignRegisters(spec.parameters),
            isVariadic: spec.isVariadic,
            source: "known-import",
            format: formatAttribute(for: spec)
        )
    }

    /// AAPCS (AArch64) argument classification: integer/pointer args consume x/w
    /// registers by NGRN; float/double args consume the SIMD/FP file by NSRN.
    /// The two sequences are independent (do not interfere with each other).
    enum ArgClass: Sendable { case integer, float }

    static func typeClass(_ type: String) -> ArgClass {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "float", "double", "long double": return .float
        default: return .integer          // pointers/ints/size_t/etc. — safe default
        }
    }

    /// AAPCS64 result register for a header-verified return spelling.
    /// Unknown pointer-shaped spellings conservatively use x0.
    static func returnRegister(for type: String) -> String? {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "void" {
            return nil
        }
        switch typeClass(normalized) {
        case .float:
            return normalized == "float" ? "s0" : "d0"
        case .integer:
            return integerRegister(for: normalized, at: 0)
        }
    }

    /// AAPCS (AArch64) argument register assignment. Integer args consume x/w
    /// registers by a running counter (NGRN); float/double args consume d/s
    /// registers by an independent counter (NSRN). `index` is the source position.
    public static func assignRegisters(_ params: [CallSignatureSpec.Param]) -> [MacIRCallParameter] {
        var ngrn = 0   // next general (x/w) register
        var nsrn = 0   // next SIMD/FP (d/s) register
        return params.enumerated().map { position, p in
            let reg: String
            switch typeClass(p.type) {
            case .integer:
                reg = integerRegister(for: p.type, at: ngrn)
                ngrn += 1
            case .float:
                reg = (p.type.trimmingCharacters(in: .whitespaces) == "float") ? "s\(nsrn)" : "d\(nsrn)"
                nsrn += 1
            }
            return MacIRCallParameter(index: position, register: reg, type: p.type, name: p.name)
        }
    }

    static func integerRegister(for type: String, at n: Int) -> String {
        let width = integerWidth(type)
        return width > 0 && width <= 32 ? "w\(n)" : "x\(n)"
    }

    /// SDK-pinned widths for scalar spellings used by seed/corpus parameters and returns.
    /// Unrecognized pointer-shaped spellings return 0, which `integerRegister`
    /// conservatively maps to a 64-bit x register. New bare scalar typedefs must
    /// be added here with an SDK-backed width test.
    static func integerWidth(_ type: String) -> Int {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "int64_t", "uint64_t", "size_t", "ssize_t", "off_t", "long", "long int",
             "long long", "long long int", "unsigned long", "unsigned long long",
             "unsigned long long int", "clock_t", "pthread_key_t", "pthread_t", "time_t", "va_list",
             "void *", "const void *", "char *", "const char *", "id", "SEL":
            return 64
        case "int32_t", "uint32_t", "int", "unsigned int", "BOOL", "clockid_t", "dev_t",
             "gid_t", "pid_t", "sae_associd_t", "sae_connid_t", "socklen_t", "uid_t", "wchar_t":
            return 32
        case "uint16_t", "int16_t", "mode_t": return 16
        case "uint8_t", "int8_t", "char": return 8
        default: return 0
        }
    }
}

extension CallSignatureCatalog {
    /// The libc/runtime signatures migrated verbatim from the former
    /// MacIRBuilder.knownCallSignature switch (31 canonical cases; the two
    /// swift_retain/swift_release aliases become separate seeds, so 33 entries).
    /// Do not alter types/names/order — this is the byte-identical regression anchor.
    static let seeds: [CallSignatureSpec] = [
        CallSignatureSpec(canonicalName: "malloc", returnType: "void *",
                          parameters: [.init(type: "size_t", name: "size")]),
        CallSignatureSpec(canonicalName: "calloc", returnType: "void *",
                          parameters: [.init(type: "size_t", name: "count"),
                                       .init(type: "size_t", name: "size")]),
        CallSignatureSpec(canonicalName: "free", returnType: "void",
                          parameters: [.init(type: "void *", name: "ptr")]),
        CallSignatureSpec(canonicalName: "strlen", returnType: "size_t",
                          parameters: [.init(type: "const char *", name: "s")]),
        CallSignatureSpec(canonicalName: "strcmp", returnType: "int32_t",
                          parameters: [.init(type: "const char *", name: "lhs"),
                                       .init(type: "const char *", name: "rhs")]),
        CallSignatureSpec(canonicalName: "strncmp", returnType: "int32_t",
                          parameters: [.init(type: "const char *", name: "lhs"),
                                       .init(type: "const char *", name: "rhs"),
                                       .init(type: "size_t", name: "count")]),
        CallSignatureSpec(canonicalName: "memcpy", returnType: "void *",
                          parameters: [.init(type: "void *", name: "dst"),
                                       .init(type: "const void *", name: "src"),
                                       .init(type: "size_t", name: "count")]),
        CallSignatureSpec(canonicalName: "memset", returnType: "void *",
                          parameters: [.init(type: "void *", name: "dst"),
                                       .init(type: "int32_t", name: "value"),
                                       .init(type: "size_t", name: "count")]),
        CallSignatureSpec(canonicalName: "puts", returnType: "int32_t",
                          parameters: [.init(type: "const char *", name: "s")]),
        CallSignatureSpec(canonicalName: "printf", returnType: "int32_t",
                          parameters: [.init(type: "const char *", name: "format")],
                          isVariadic: true),
        CallSignatureSpec(canonicalName: "objc_msgSend", returnType: "id",
                          parameters: [.init(type: "id", name: "receiver"),
                                       .init(type: "SEL", name: "selector")],
                          isVariadic: true),
        CallSignatureSpec(canonicalName: "swift_retain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object")]),
        CallSignatureSpec(canonicalName: "swift_unknownObjectRetain", returnType: "void *",
                          parameters: [.init(type: "void *", name: "object")]),
        CallSignatureSpec(canonicalName: "swift_release", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
        CallSignatureSpec(canonicalName: "swift_unknownObjectRelease", returnType: "void",
                          parameters: [.init(type: "void *", name: "object")]),
        CallSignatureSpec(canonicalName: "memmove", returnType: "void *",
                          parameters: [.init(type: "void *", name: "dst"),
                                       .init(type: "const void *", name: "src"),
                                       .init(type: "size_t", name: "count")]),
        CallSignatureSpec(canonicalName: "realloc", returnType: "void *",
                          parameters: [.init(type: "void *", name: "ptr"),
                                       .init(type: "size_t", name: "size")]),
        CallSignatureSpec(canonicalName: "strncpy", returnType: "char *",
                          parameters: [.init(type: "char *", name: "dst"),
                                       .init(type: "const char *", name: "src"),
                                       .init(type: "size_t", name: "count")]),
        CallSignatureSpec(canonicalName: "strcpy", returnType: "char *",
                          parameters: [.init(type: "char *", name: "dst"),
                                       .init(type: "const char *", name: "src")]),
        CallSignatureSpec(canonicalName: "strcat", returnType: "char *",
                          parameters: [.init(type: "char *", name: "dst"),
                                       .init(type: "const char *", name: "src")]),
        CallSignatureSpec(canonicalName: "strncat", returnType: "char *",
                          parameters: [.init(type: "char *", name: "dst"),
                                       .init(type: "const char *", name: "src"),
                                       .init(type: "size_t", name: "count")]),
        CallSignatureSpec(canonicalName: "strchr", returnType: "char *",
                          parameters: [.init(type: "const char *", name: "s"),
                                       .init(type: "int32_t", name: "c")]),
        CallSignatureSpec(canonicalName: "strdup", returnType: "char *",
                          parameters: [.init(type: "const char *", name: "s")]),
        CallSignatureSpec(canonicalName: "fwrite", returnType: "size_t",
                          parameters: [.init(type: "const void *", name: "ptr"),
                                       .init(type: "size_t", name: "size"),
                                       .init(type: "size_t", name: "count"),
                                       .init(type: "void *", name: "stream")]),
        CallSignatureSpec(canonicalName: "fputs", returnType: "int32_t",
                          parameters: [.init(type: "const char *", name: "s"),
                                       .init(type: "void *", name: "stream")]),
        CallSignatureSpec(canonicalName: "snprintf", returnType: "int32_t",
                          parameters: [.init(type: "char *", name: "str"),
                                       .init(type: "size_t", name: "size"),
                                       .init(type: "const char *", name: "format")],
                          isVariadic: true),
        CallSignatureSpec(canonicalName: "asprintf", returnType: "int32_t",
                          parameters: [.init(type: "char **", name: "ret"),
                                       .init(type: "const char *", name: "format")],
                          isVariadic: true),
        CallSignatureSpec(canonicalName: "NSLog", returnType: "void",
                          parameters: [.init(type: "NSString *", name: "format")],
                          isVariadic: true),
        CallSignatureSpec(canonicalName: "objc_retain", returnType: "id",
                          parameters: [.init(type: "id", name: "obj")]),
        CallSignatureSpec(canonicalName: "objc_release", returnType: "void",
                          parameters: [.init(type: "id", name: "obj")]),
        CallSignatureSpec(canonicalName: "objc_autorelease", returnType: "id",
                          parameters: [.init(type: "id", name: "obj")]),
        CallSignatureSpec(canonicalName: "objc_retainAutoreleasedReturnValue", returnType: "id",
                          parameters: [.init(type: "id", name: "obj")]),
        CallSignatureSpec(canonicalName: "objc_msgSendSuper", returnType: "id",
                          parameters: [.init(type: "struct objc_super *", name: "super"),
                                       .init(type: "SEL", name: "selector")],
                          isVariadic: true),
    ]

    /// Hand-written seeds, corpus and runtime seeds first; the shipped SDK pack (HOP-5) last, so
    /// it only adds signatures and never shadows a hand-verified one.
    public static let standard = CallSignatureCatalog(standardSpecs())
}

extension CallSignatureCatalog {
    /// Knowledge-version identity of the standard catalog (hand-written seeds, header corpus,
    /// runtime seeds and the bundled SDK pack). Bump `version` whenever `standard` changes.
    static let knowledge = NavigatorKnowledgeDescriptor(
        id: "signatures.call-catalog",
        version: "2",
        applicability: .any
    )
}
