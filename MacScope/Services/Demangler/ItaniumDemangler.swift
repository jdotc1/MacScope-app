import Foundation

/// Clean-room Itanium C++ ABI name demangler (the `_Z…` encoding produced by
/// clang/gcc). Written from scratch against the published Itanium C++ ABI
/// name-mangling grammar and validated against `c++filt` output locally.
///
/// This intentionally covers only the COMMON cases that show up in real
/// disassembly listings:
///   - free functions and nested (`N…E`) qualified names
///   - constructors / destructors
///   - top-level CV / ref qualifiers on member functions (`K`, `r`, `O`)
///   - builtin scalar types, pointers / references / const-qualified types
///   - the standard substitutions (`St`, `Ss`, `Si`, `So`, `Sa`, `Sb`) and
///     back-reference substitutions (`S_`, `S0_`, …)
///   - simple template argument lists (`I…E`) with type arguments and
///     literal (`L…E`) arguments
///   - function parameter lists
///
/// Anything outside that surface (expressions, vendor extensions, local
/// entities, ABI tags, exotic template arguments, etc.) causes the parser to
/// return `nil` so the caller can fall back to the raw mangled name. The rule
/// is correctness-over-coverage: we NEVER emit a guessed demangling.
enum ItaniumDemangler {
    /// Hard cap on the input length we will even attempt to demangle. Defends
    /// against adversarial symbols crafted to exhaust the stack or CPU.
    static let maxMangledLength = 8192

    /// Hard cap on recursion depth across `parseType` / `parseNestedName` /
    /// `parseTemplateArgs`. A hostile symbol like `_Z3foo` + 7000×`P` + `i`
    /// would otherwise recurse once per pointer and overflow the stack.
    static let maxRecursionDepth = 256

    /// Returns a readable demangling of an Itanium `_Z…` symbol, or `nil` if the
    /// name is not Itanium-mangled or uses a construct we do not fully model.
    static func demangle(_ symbol: String) -> String? {
        // Linker-emitted symbols frequently carry a leading underscore on the
        // Mach-O `_Z…` form (the assembler global-symbol prefix). The Itanium
        // encoding itself begins at `_Z`.
        // Reject pathologically long mangled names outright. A hostile binary
        // symbol must never be able to drive the parser into deep recursion or
        // quadratic work — real Itanium symbols are nowhere near this long.
        guard symbol.utf8.count <= maxMangledLength else { return nil }

        var input = symbol
        if input.hasPrefix("__Z") {
            input.removeFirst() // drop the extra Mach-O underscore
        }
        guard input.hasPrefix("_Z") else { return nil }

        var parser = Parser(Array(input.unicodeScalars))
        parser.advance(2) // consume "_Z"
        guard let result = parser.parseEncoding() else { return nil }
        // The entire mangled name must be consumed for us to trust the result.
        guard parser.isAtEnd else { return nil }
        return result
    }

    // MARK: - Parser

    /// Result of parsing a `<name>`.
    private struct NameResult {
        /// The rendered (possibly qualified) name, e.g. `foo::bar<int>`.
        var name: String
        /// Whether the name may stand alone as a bare (data) symbol with no
        /// following function type.
        var allowsBareName: Bool
        /// Trailing CV/ref qualifier string (e.g. " const") to append AFTER the
        /// parameter list.
        var cvSuffix: String
        /// Whether the TERMINAL component carried template arguments. When a
        /// templated terminal is followed by a bare-function-type, the Itanium
        /// encoding prefixes the parameter list with the function's RETURN type,
        /// which must be consumed and rendered (or dropped) separately.
        var terminalIsTemplateId: Bool
        /// Whether the terminal component is a constructor or destructor. Per the
        /// Itanium ABI a ctor/dtor has NO return type in its bare-function-type
        /// even when templated, so the return-type-prefix logic must be suppressed
        /// for it (otherwise the `void` params marker is eaten as a return type).
        var terminalIsCtorOrDtor: Bool = false
    }

    private struct Parser {
        private let chars: [Unicode.Scalar]
        private var pos: Int = 0
        /// Substitution table, in the order components are encountered.
        private var substitutions: [String] = []
        /// Current recursion depth across the mutually-recursive type/name
        /// parsers. Bounded by `maxRecursionDepth`.
        private var depth: Int = 0

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        var isAtEnd: Bool { pos >= chars.count }

        func peek() -> Unicode.Scalar? { pos < chars.count ? chars[pos] : nil }

        mutating func advance(_ n: Int = 1) { pos += n }

        mutating func consume(_ c: Unicode.Scalar) -> Bool {
            if peek() == c { pos += 1; return true }
            return false
        }

        // <encoding> ::= <name> <bare-function-type>
        //            ::= <name>
        mutating func parseEncoding() -> String? {
            guard let parsed = parseName() else { return nil }
            // If at end, this is a plain name with no function type. Only
            // qualified (nested) names are valid as bare data symbols; a plain
            // top-level unqualified name with nothing after it is malformed
            // (c++filt rejects `_Z3foo`).
            if isAtEnd {
                return parsed.allowsBareName ? parsed.name : nil
            }
            // Otherwise a bare-function-type follows: `<type>+`. Per the Itanium
            // ABI the leading type is the function's RETURN type ONLY when the
            // terminal name component is a template-id; otherwise every type is a
            // parameter.
            //
            // For a templated terminal we must consume that return type — and we
            // render it as a prefix, matching c++filt (`void foo::bar<int>()`).
            // For a non-templated terminal we drop the return type (there is
            // none) and parse straight into parameters.
            // A templated terminal leads with a return type — EXCEPT constructors
            // and destructors, which have no return type even when templated (the
            // leading `v`/type there is the first parameter, not a return type).
            var returnPrefix = ""
            if parsed.terminalIsTemplateId && !parsed.terminalIsCtorOrDtor {
                guard let ret = parseType() else { return nil }
                returnPrefix = ret + " "
            }
            guard let params = parseBareFunctionParams() else { return nil }
            guard isAtEnd else { return nil }
            return returnPrefix + parsed.name + params + parsed.cvSuffix
        }

        /// Parses a `<name>`. Returns the rendered name, whether it may stand
        /// alone as a bare (data) symbol with no function type, and any trailing
        /// CV/ref qualifier string (e.g. " const") to append AFTER parameters.
        mutating func parseName() -> NameResult? {
            guard let first = peek() else { return nil }
            if first == "N" {
                return parseNestedName()
            }
            if first == "S" {
                return parseUnscopedSubstitutionName()
            }
            if first == "Z" {
                // Local-scope name: not modelled.
                return nil
            }
            // <unscoped-name> ::= <unqualified-name>. A bare unqualified name is
            // not a valid standalone encoding; it must be followed by a
            // function type.
            guard let unqualified = parseUnqualifiedName(enclosing: nil) else { return nil }
            return NameResult(name: unqualified, allowsBareName: false,
                              cvSuffix: "", terminalIsTemplateId: false)
        }

        /// `<unscoped-name> ::= St <unqualified-name>` and the standalone
        /// `<substitution>` forms. A standard substitution such as `St` ("std")
        /// may be followed by an unqualified-name that scopes INTO it — e.g.
        /// `St9terminatev` is `std::terminate()`, NOT the bare name "std". We
        /// route the `<substitution> <unqualified-name>` shape through the same
        /// component machinery as a nested name so the scope renders correctly.
        mutating func parseUnscopedSubstitutionName() -> NameResult? {
            guard let sub = parseSubstitution() else { return nil }

            // If an unqualified-name / template-args follow, the substitution is
            // a SCOPE, not the whole name. Otherwise it stands alone (rare).
            guard let c = peek() else {
                return NameResult(name: sub, allowsBareName: true,
                                  cvSuffix: "", terminalIsTemplateId: false)
            }

            // A following bare-function-type would begin with a type letter; we
            // only treat the next token as a scoped child when it is an
            // unqualified-name lead (source-name digit, ctor/dtor, operator) or
            // template args. Anything else (e.g. a builtin type letter for the
            // function's parameters) means `sub` is itself the complete name.
            let startsChild = (c >= "0" && c <= "9") || c == "C" || c == "D"
                || c == "I" || isOperatorLead(c)
            guard startsChild else {
                return NameResult(name: sub, allowsBareName: true,
                                  cvSuffix: "", terminalIsTemplateId: false)
            }

            // The leading substitution itself is a substitution-table entry; the
            // child component re-registers the extended prefix (mangler
            // numbering). Mirror the nested-name prefix bookkeeping.
            var running = sub
            var terminalIsTemplateId = false

            if c == "I" {
                // Template args attach directly to the substitution scope, e.g.
                // `SaIiE` => std::allocator<int>. The resulting template-id is a
                // substitution candidate, so register it (a later S_/S0_ back-ref
                // into this template-id would otherwise resolve to the wrong slot).
                guard let args = parseTemplateArgs() else { return nil }
                running = sub + args
                addSubstitution(running)
                terminalIsTemplateId = true
            } else {
                guard let comp = parseUnqualifiedName(enclosing: running) else { return nil }
                addSubstitution(sub)
                running = sub + "::" + comp
                // A template-args clause may follow the child component.
                if peek() == "I" {
                    addSubstitution(running)
                    guard let args = parseTemplateArgs() else { return nil }
                    running += args
                    terminalIsTemplateId = true
                }
            }

            return NameResult(name: running, allowsBareName: true,
                              cvSuffix: "", terminalIsTemplateId: terminalIsTemplateId)
        }

        /// Whether a two-character operator-name begins at `c` (cheap prefilter;
        /// `parseOperatorName` does the real validation).
        private func isOperatorLead(_ c: Unicode.Scalar) -> Bool {
            guard pos + 1 < chars.count else { return false }
            let key = String(String.UnicodeScalarView(chars[pos..<(pos + 2)]))
            return Self.operators[key] != nil
        }

        // <nested-name> ::= N [<CV-qualifiers>] [<ref-qualifier>] <prefix> <unqualified-name> E
        mutating func parseNestedName() -> NameResult? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= ItaniumDemangler.maxRecursionDepth else { return nil }
            guard consume("N") else { return nil }
            var cvSuffix = ""
            // CV-qualifiers (only the ones that appear post-parameters).
            while let c = peek(), c == "r" || c == "V" || c == "K" {
                advance()
                switch c {
                case "K": cvSuffix = " const" + cvSuffix
                case "V": cvSuffix = " volatile" + cvSuffix
                case "r": cvSuffix = " restrict" + cvSuffix
                default: break
                }
            }
            // ref-qualifier
            if consume("R") { cvSuffix += " &" }
            else if consume("O") { cvSuffix += " &&" }

            // <prefix> <unqualified-name>
            //
            // Per the Itanium ABI, every PREFIX component of a nested-name is a
            // substitution candidate, but the FINAL unqualified-name is not
            // (the nested name as a whole becomes a substitution only when it is
            // consumed as a type — handled by the caller). To honour the exact
            // sequence ID numbering the mangler used, we add a substitution for
            // a component only once we know it is NOT the terminal one, i.e.
            // when we are about to append the next component.
            var components: [String] = []
            var running = ""
            var pendingSubstitution: String? = nil
            // Tracks whether the most-recently-parsed component carried template
            // args. When this holds true at the closing `E`, the terminal is a
            // template-id and a following bare-function-type leads with a return
            // type (handled by parseEncoding).
            var lastWasTemplateId = false
            // Tracks whether the most-recently-parsed component is a ctor/dtor.
            // A following template-args clause attaches to (and preserves) it.
            var lastWasCtorDtor = false
            while let c = peek(), c != "E" {
                // The previous component turned out to be a prefix (not the
                // terminal), so register it as a substitution now.
                if let pending = pendingSubstitution {
                    addSubstitution(pending)
                    pendingSubstitution = nil
                }

                // Substitution as the leading prefix component.
                if c == "S" {
                    guard components.isEmpty, let sub = parseSubstitution() else { return nil }
                    components = [sub]
                    running = sub
                    // A leading substitution is itself already in the table;
                    // mark it pending so a following component re-registers the
                    // extended prefix, matching mangler numbering.
                    pendingSubstitution = nil
                    lastWasTemplateId = false
                    lastWasCtorDtor = false
                    continue
                }
                // Template args attach to the prior component.
                if c == "I" {
                    guard let last = components.last,
                          let args = parseTemplateArgs() else { return nil }
                    let templated = last + args
                    components[components.count - 1] = templated
                    running = components.joined(separator: "::")
                    // A templated component is always a substitution candidate
                    // (even as a terminal, the template-id is substitutable).
                    pendingSubstitution = running
                    lastWasTemplateId = true
                    // The args attach to the prior component, preserving whether
                    // it was a ctor/dtor (a templated ctor still has no return type).
                    continue
                }
                let isCtorDtor = (c == "C" || c == "D")
                guard let comp = parseUnqualifiedName(enclosing: running) else { return nil }
                components.append(comp)
                running = components.joined(separator: "::")
                pendingSubstitution = running
                lastWasTemplateId = false
                lastWasCtorDtor = isCtorDtor
            }
            guard consume("E") else { return nil }
            // `pendingSubstitution` holds the terminal component, which is NOT
            // added here (the caller adds the whole name if used as a type).
            return NameResult(name: components.joined(separator: "::"),
                              allowsBareName: true, cvSuffix: cvSuffix,
                              terminalIsTemplateId: lastWasTemplateId,
                              terminalIsCtorOrDtor: lastWasCtorDtor)
        }

        // <unqualified-name> ::= <operator-name>
        //                    ::= <ctor-dtor-name>
        //                    ::= <source-name>
        mutating func parseUnqualifiedName(enclosing: String?) -> String? {
            guard let c = peek() else { return nil }
            if c.properties.numericType != nil || (c >= "0" && c <= "9") {
                return parseSourceName()
            }
            if c == "C" {
                // <ctor> ::= C1 | C2 | C3
                advance()
                guard let d = peek(), d == "1" || d == "2" || d == "3" else { return nil }
                advance()
                return lastComponent(of: enclosing)
            }
            if c == "D" {
                // <dtor> ::= D0 | D1 | D2
                advance()
                guard let d = peek(), d == "0" || d == "1" || d == "2" else { return nil }
                advance()
                guard let base = lastComponent(of: enclosing) else { return nil }
                return "~" + base
            }
            // operator-name
            if let op = parseOperatorName() { return op }
            return nil
        }

        private func lastComponent(of enclosing: String?) -> String? {
            guard let enclosing, !enclosing.isEmpty else { return nil }
            // Take the final ::-component, then strip its template-args clause.
            // CRITICAL: `::` also appears INSIDE template arguments (e.g.
            // `basic_ostream<char, std::char_traits<char>>`), so the split must
            // only break on `::` at template depth 0 — otherwise we would grab the
            // innermost template argument's name (`char_traits`) as the class name.
            let scalars = Array(enclosing.unicodeScalars)
            var angleDepth = 0
            var terminalStart = 0
            var i = 0
            while i < scalars.count {
                switch scalars[i] {
                case "<": angleDepth += 1
                case ">": if angleDepth > 0 { angleDepth -= 1 }
                case ":" where angleDepth == 0 && i + 1 < scalars.count && scalars[i + 1] == ":":
                    terminalStart = i + 2
                    i += 2
                    continue
                default: break
                }
                i += 1
            }
            // The terminal component runs from `terminalStart`; strip at its own
            // (depth-0) template-args clause.
            var base = ""
            var j = terminalStart
            while j < scalars.count, scalars[j] != "<" {
                base.unicodeScalars.append(scalars[j])
                j += 1
            }
            return base.isEmpty ? nil : base
        }

        // <source-name> ::= <positive length number> <identifier>
        mutating func parseSourceName() -> String? {
            guard let len = parseNumber(), len > 0 else { return nil }
            guard pos + len <= chars.count else { return nil }
            let slice = chars[pos..<(pos + len)]
            advance(len)
            return String(String.UnicodeScalarView(slice))
        }

        mutating func parseNumber() -> Int? {
            var digits = ""
            while let c = peek(), c >= "0", c <= "9" {
                digits.unicodeScalars.append(c)
                advance()
            }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }

        // MARK: Operators

        mutating func parseOperatorName() -> String? {
            guard pos + 1 < chars.count else { return nil }
            let key = String(String.UnicodeScalarView(chars[pos..<(pos + 2)]))
            guard let name = Self.operators[key] else { return nil }
            advance(2)
            return "operator" + name
        }

        private static let operators: [String: String] = [
            "nw": " new", "na": " new[]", "dl": " delete", "da": " delete[]",
            "pl": "+", "mi": "-", "ml": "*", "dv": "/", "rm": "%",
            "ps": "+", "ng": "-", "ad": "&", "de": "*",
            "an": "&", "or": "|", "eo": "^", "co": "~",
            "aS": "=", "pL": "+=", "mI": "-=", "mL": "*=", "dV": "/=", "rM": "%=",
            "aN": "&=", "oR": "|=", "eO": "^=", "ls": "<<", "rs": ">>",
            "lS": "<<=", "rS": ">>=", "eq": "==", "ne": "!=", "lt": "<",
            "gt": ">", "le": "<=", "ge": ">=", "nt": "!", "aa": "&&",
            "oo": "||", "pp": "++", "mm": "--", "cm": ",", "pm": "->*",
            "pt": "->", "cl": "()", "ix": "[]"
        ]

        // MARK: Substitutions

        private mutating func addSubstitution(_ s: String) {
            // The Itanium substitution table is POSITIONAL: seq-ids index entries
            // by their order of registration, so every component must occupy its
            // own slot. We must NOT skip an entry just because it equals the
            // previous one — doing so shifts every later seq-id and yields wrong
            // back-references. Always append.
            substitutions.append(s)
        }

        // <substitution> ::= S <seq-id> _ | S_ | St | Sa | Sb | Ss | Si | So | Sd
        mutating func parseSubstitution() -> String? {
            guard consume("S") else { return nil }
            guard let c = peek() else { return nil }
            // Standard abbreviations.
            if let std = Self.stdSubstitutions[c] {
                advance()
                return std
            }
            if c == "_" {
                advance()
                guard let first = substitutions.first else { return nil }
                return first
            }
            // S<base-36 seq-id>_
            if (c >= "0" && c <= "9") || (c >= "A" && c <= "Z") {
                var idStr = ""
                while let d = peek(), (d >= "0" && d <= "9") || (d >= "A" && d <= "Z") {
                    idStr.unicodeScalars.append(d)
                    advance()
                }
                guard consume("_") else { return nil }
                guard let seq = Int(idStr, radix: 36) else { return nil }
                // S_ is index 0, S0_ is index 1, etc.
                let index = seq + 1
                guard index < substitutions.count else { return nil }
                return substitutions[index]
            }
            return nil
        }

        private static let stdSubstitutions: [Unicode.Scalar: String] = [
            "t": "std",
            "a": "std::allocator",
            "b": "std::basic_string",
            "s": "std::string",
            "i": "std::istream",
            "o": "std::ostream",
            "d": "std::iostream"
        ]

        // MARK: Template arguments

        // <template-args> ::= I <template-arg>+ E
        mutating func parseTemplateArgs() -> String? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= ItaniumDemangler.maxRecursionDepth else { return nil }
            guard consume("I") else { return nil }
            var args: [String] = []
            while let c = peek(), c != "E" {
                if c == "L" {
                    guard let lit = parseExprPrimary() else { return nil }
                    args.append(lit)
                } else {
                    guard let t = parseType() else { return nil }
                    args.append(t)
                }
            }
            guard consume("E") else { return nil }
            guard !args.isEmpty else { return nil }
            return "<" + args.joined(separator: ", ") + ">"
        }

        // <expr-primary> ::= L <type> <value number> E   (literal)
        //                ::= L <mangled-name> E
        mutating func parseExprPrimary() -> String? {
            guard consume("L") else { return nil }
            // We only handle integer/boolean literals over builtin types.
            guard let c = peek() else { return nil }
            if c == "b" {
                advance()
                guard let n = parseNumber() else { return nil }
                guard consume("E") else { return nil }
                return n == 0 ? "false" : "true"
            }
            // Builtin integer type followed by a (possibly negative) value.
            guard let _ = Self.builtinTypes[c] else { return nil }
            advance()
            var value = ""
            if consume("n") { value = "-" }
            guard let n = parseNumber() else { return nil }
            value += String(n)
            guard consume("E") else { return nil }
            // Match c++filt's literal rendering: non-int integer literals carry a
            // C++ type suffix (`1l`, `4096ul`, `5ll`). `int` is unsuffixed.
            return value + (Self.literalSuffixes[c] ?? "")
        }

        /// C++ literal type suffixes for integer template-argument literals,
        /// keyed by the Itanium builtin-type letter (`int` is unsuffixed).
        private static let literalSuffixes: [Unicode.Scalar: String] = [
            "j": "u", "l": "l", "m": "ul", "x": "ll", "y": "ull"
        ]

        // MARK: Types

        // <bare-function-type> ::= <type>+   (parameter types; the leading one
        // for a free function is the return type only when templated — which we
        // already excluded, so here every type is a parameter).
        mutating func parseBareFunctionParams() -> String? {
            var params: [String] = []
            while !isAtEnd {
                guard let t = parseType() else { return nil }
                params.append(t)
            }
            // A single `void` parameter means "no parameters".
            if params == ["void"] { return "()" }
            return "(" + params.joined(separator: ", ") + ")"
        }

        mutating func parseType() -> String? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= ItaniumDemangler.maxRecursionDepth else { return nil }
            guard let c = peek() else { return nil }

            // Builtin types.
            if let builtin = Self.builtinTypes[c] {
                advance()
                return builtin
            }

            switch c {
            case "P": // pointer
                advance()
                guard let inner = parseType() else { return nil }
                let rendered = inner + "*"
                addSubstitution(rendered)
                return rendered
            case "R": // lvalue reference
                advance()
                guard let inner = parseType() else { return nil }
                let rendered = inner + "&"
                addSubstitution(rendered)
                return rendered
            case "O": // rvalue reference
                advance()
                guard let inner = parseType() else { return nil }
                let rendered = inner + "&&"
                addSubstitution(rendered)
                return rendered
            case "K": // const-qualified
                advance()
                guard let inner = parseType() else { return nil }
                let rendered = inner + " const"
                addSubstitution(rendered)
                return rendered
            case "V": // volatile-qualified
                advance()
                guard let inner = parseType() else { return nil }
                let rendered = inner + " volatile"
                addSubstitution(rendered)
                return rendered
            case "S": // substitution: an `St` scope (St13foo => std::foo) and/or templated
                guard let sub = parseSubstitution() else { return nil }
                var rendered = sub
                // In TYPE position a substitution scopes a following SOURCE-NAME only
                // via the literal `St` namespace abbreviation: `St13exception_ptr` is
                // the single type `std::exception_ptr` (the bug behind `operator
                // delete(void*, std, align_val_t)`). This must NOT extend to:
                //   - back-references (`S_3foo` is two types, not `X::foo`), nor
                //   - operator/ctor names: `m` is `unsigned long`, so `mm` after a
                //     substitution is two params, NOT `operator--` (a type can't be
                //     `std::operator--`).
                // So scope ONLY when the sub is the std namespace and a digit (source
                // -name length) follows. Template-args (`SaIcE`) still attach below.
                if sub == "std", let c2 = peek(), c2 >= "0", c2 <= "9" {
                    guard let comp = parseSourceName() else { return nil }
                    rendered = sub + "::" + comp
                    addSubstitution(rendered)
                }
                if peek() == "I" {
                    guard let args = parseTemplateArgs() else { return nil }
                    rendered += args
                    addSubstitution(rendered)
                }
                return rendered
            case "N": // nested name used as a type
                guard let nested = parseNestedName() else { return nil }
                addSubstitution(nested.name)
                return nested.name
            case "T": // template-parameter reference (T_, T0_, …)
                // We do not track the binding environment precisely, so we only
                // accept the bare `T_` form rendered opaquely is unsafe — bail.
                return nil
            default:
                // <class-enum-type> ::= <name>  (a length-prefixed source name)
                if c >= "0" && c <= "9" {
                    guard let name = parseSourceName() else { return nil }
                    addSubstitution(name)
                    return name
                }
                return nil
            }
        }

        private static let builtinTypes: [Unicode.Scalar: String] = [
            "v": "void", "b": "bool", "c": "char", "a": "signed char",
            "h": "unsigned char", "s": "short", "t": "unsigned short",
            "i": "int", "j": "unsigned int", "l": "long",
            "m": "unsigned long", "x": "long long", "y": "unsigned long long",
            "n": "__int128", "o": "unsigned __int128", "f": "float",
            "d": "double", "e": "long double", "w": "wchar_t"
        ]
    }
}
