import Foundation

enum SwiftSelfKind: String, Equatable {
    case none, instance, `static`, allocatingInit, initializingInit, deallocatingDeinit, destroyingDeinit
}

enum SwiftSelfNominalKind: String, Equatable {
    case none, `class`, `struct`, `enum`, `protocol`, archetype, unknown
}

enum SwiftFuncletKind: String, Equatable {
    case awaitResume, suspendResume
}

struct SwiftFunclet: Equatable {
    var kind: SwiftFuncletKind
    var index: Int          // the number printed in "(n) … partial function for", so 1-based
}

/// What the demangler knows about a function symbol from its mangling alone.
/// Every field defaults to "not known / not present"; a symbol that renders but is not a
/// function (a type, a descriptor, metadata) carries the all-default value.
struct SwiftSymbolFacts: Equatable {
    var isFunction = false
    var isAsync = false
    var isThrowing = false
    var thrownType: String? = nil        // rendered type text of a typed throw; nil for untyped `throws`
    var isGeneric = false                // the entity itself has a generic signature (a `<…>` clause)
    var isPartialApplyForwarder = false  // `TA`
    var isDispatchThunk = false          // `Tj`
    var isAsyncFunctionPointer = false   // `Tu`
    var isReabstractionThunk = false     // `TR`; not currently supplied by the parser
    var isMerged = false                 // `Tm`
    var funclet: SwiftFunclet? = nil     // `TQn_` / `TYn_`
    var selfKind: SwiftSelfKind = .none
    var selfNominalKind: SwiftSelfNominalKind = .none
    var selfTypeIsGeneric = false        // the self type's own nominal is generic (`<…>` on the type, not the method)
    var isMutating: Bool? = nil          // never derivable from a mangling; always nil here
    var hasNonScalarParameter = false    // classified by recordScalars(params:result:) below
    var hasNonScalarReturn = false
}

/// A rendering with its facts. `facts` is nil only where no facts were recorded: the
/// too-complex marker and the legacy `_TtC`/`_TtV` names.
struct SwiftDemangled: Equatable {
    let rendered: String
    let facts: SwiftSymbolFacts?
    let parameterTypes: [String]?
    let resultType: String?
}

extension SwiftSymbolFacts {
    static func nominalKind(_ kind: Unicode.Scalar?) -> SwiftSelfNominalKind {
        switch kind {
        case "C": return .class
        case "V": return .struct
        case "O": return .enum
        case "P": return .protocol
        case "x", "q": return .archetype
        default: return .unknown
        }
    }

    mutating func recordScalars(params: String, result: String) {
        let inner = params.hasPrefix("(") && params.hasSuffix(")")
            ? String(params.dropFirst().dropLast()) : params
        hasNonScalarParameter = Self.parameterTypes(inner).contains { !Self.isScalar($0) }
        hasNonScalarReturn = !Self.isScalar(result)
    }

    static func parameterTypes(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var depth = 0
        var start = text.startIndex
        var types: [String] = []
        var previous: Character?
        for index in text.indices {
            let c = text[index]
            if c == ",", depth == 0 {
                types.append(String(text[start..<index]))
                start = text.index(after: index)
            } else if c == "(" || c == "[" || c == "<" { depth += 1 }
            else if c == ")" || c == "]" || (c == ">" && previous != "-") { depth -= 1 }
            previous = c
        }
        types.append(String(text[start...]))
        return types.map { parameter in
            let trimmed = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
            // Labels are outside the type, before any nesting or function arrow.
            var depth = 0
            for index in trimmed.indices {
                let c = trimmed[index]
                if c == ":", depth == 0 {
                    return String(trimmed[trimmed.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if c == "(" || c == "[" || c == "<" { depth += 1 }
                if c == ")" || c == "]" || c == ">" { depth -= 1 }
            }
            return trimmed
        }
    }

    private static func isScalar(_ type: String) -> Bool {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars: Set<String> = [
            "Swift.Int", "Swift.UInt", "Swift.Int8", "Swift.Int16", "Swift.Int32", "Swift.Int64",
            "Swift.UInt8", "Swift.UInt16", "Swift.UInt32", "Swift.UInt64", "Swift.Bool", "Swift.Float",
            "Swift.Double", "Swift.Float16", "Swift.Float80", "Swift.Character", "Swift.Unicode.Scalar",
            "Swift.Never", "Swift.Void", "()", "Swift.OpaquePointer", "Swift.UnsafeRawPointer",
            "Swift.UnsafeMutableRawPointer", "Swift.AnyObject", "Swift.AnyClass", "Swift.Int.Type",
            "Builtin.Word", "Builtin.RawPointer", "Builtin.NativeObject"
        ]
        if scalars.contains(type) { return true }
        if type.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\.Unsafe(Mutable)?Pointer<.*>$"#,
                      options: .regularExpression) != nil { return true }
        var depth = 0
        var previous: Character?
        for c in type {
            if c == ">", previous == "-", depth == 0 { return true }
            if c == "(" || c == "[" || c == "<" { depth += 1 }
            else if c == ")" || c == "]" || (c == ">" && previous != "-") { depth -= 1 }
            previous = c
        }
        return false
    }
}
