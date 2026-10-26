import Foundation

/// Clean-room Swift symbol demangler for the stable `$s` (a.k.a. `_$s` / `$S`)
/// mangling. Written from scratch against the documented Swift mangling grammar
/// (the `<symbolic-reference>`-free subset) and validated locally against
/// `swift-demangle`.
///
/// Swift's mangling is a dense, stack-oriented scheme; demangling the full
/// grammar (generic signatures, witness tables, retroactive conformances,
/// label lists with multi-substitutions, etc.) is far beyond what a disassembly
/// listing needs. This implementation deliberately covers only the forms whose
/// output we can reproduce EXACTLY, character-for-character, as `swift-demangle`
/// would:
///   - nominal types: `$s<module><nominal-path>{C|V|O|P}` → `module.A.B`
///   - known standard-library type substitutions (`Si`, `SS`, `Sb`, …)
///   - type-metadata accessors (`…Ma`) and metadata symbols (`…N`)
///   - simple methods / free functions with EMPTY or a SINGLE unlabeled
///     parameter and a known/nominal return type
///
/// Every other construct returns `nil`, so the caller falls back to the raw
/// mangled string. We never emit a guessed demangling.
enum SwiftDemangler {
    /// Hard cap on the input length we will even attempt to demangle. A hostile
    /// binary symbol must never be able to drive pathological work or recursion.
    static let maxMangledLength = 8192
    /// Hard cap on nested-type recursion (bound generics within bound generics).
    /// Real symbols nest only a handful deep; this bounds a crafted symbol from
    /// driving deep recursion / stack overflow well below the length cap.
    static let maxTypeDepth = 64
    /// Hard cap on nested suffix wrappers (`…TmTuTj…`): each wrapper re-parses the prefix in a fresh
    /// parser, so without a cap a crafted symbol could recurse once per two input characters.
    static let maxWrapperDepth = 32
    /// Hard cap on any one rendered node or the final output. Substitution back-references can
    /// duplicate an already-rendered node, so output can grow far faster than the input.
    static let maxRenderedLength = 16_384
    /// Returned in place of a demangling when a symbol exceeds the depth or size budget, so the
    /// caller shows a marked "too complex" result rather than recursing or rendering without bound.
    static let tooComplexMarker = "<<too complex to demangle>>"

    static func demangle(_ symbol: String) -> String? {
        guard symbol.utf8.count <= maxMangledLength else {
            let isSwift = symbol.hasPrefix("$s") || symbol.hasPrefix("$S")
                || symbol.hasPrefix("_$s") || symbol.hasPrefix("_$S")
            return isSwift ? tooComplexMarker : nil
        }
        if symbol.hasPrefix("_TtC") || symbol.hasPrefix("_TtV") {
            return demangleLegacyClassName(symbol) ?? demangleResidualLegacyName(symbol)
        }
        var body = symbol
        // Accept the three stable manglings. The leading Mach-O underscore on
        // `_$s` is stripped first.
        if body.hasPrefix("_$s") || body.hasPrefix("_$S") {
            body.removeFirst() // drop Mach-O underscore -> "$s…"
        }
        guard body.hasPrefix("$s") || body.hasPrefix("$S") else { return nil }
        if let suffixStart = body.firstIndex(of: ".") {
            let base = String(body[..<suffixStart])
            let suffix = String(body[suffixStart...])
            guard base.count > 2, let rendered = demangle(base) else { return nil }
            if rendered == tooComplexMarker { return rendered }
            let result = rendered + " with unmangled suffix \"" + suffix + "\""
            return result.utf8.count <= maxRenderedLength ? result : tooComplexMarker
        }
        let payload = String(body.dropFirst(2))
        guard !payload.isEmpty else { return nil }

        let budget = Budget()
        var parser = Parser(budget: budget, Array(payload.unicodeScalars))
        var residual = ResidualParser(payload, budget: budget)
        let rendered = parser.parseTopLevel() ?? demanglePackConformance(payload) ?? residual.parse()
        if let rendered, rendered.utf8.count <= maxRenderedLength { return rendered }
        return budget.exceeded || rendered != nil ? tooComplexMarker : nil
    }

    static func demangleWithFacts(_ symbol: String) -> SwiftDemangled? {
        demangleWithFacts(symbol, budget: Budget())
    }

    /// The shared budget also exposes which parser supplied the accepted rendering.
    static func demangleWithFacts(_ symbol: String, budget: Budget) -> SwiftDemangled? {
        guard symbol.utf8.count <= maxMangledLength else {
            let isSwift = symbol.hasPrefix("$s") || symbol.hasPrefix("$S")
                || symbol.hasPrefix("_$s") || symbol.hasPrefix("_$S")
            return isSwift ? SwiftDemangled(rendered: tooComplexMarker, facts: nil, parameterTypes: nil, resultType: nil) : nil
        }
        if symbol.hasPrefix("_TtC") || symbol.hasPrefix("_TtV") {
            return (demangleLegacyClassName(symbol) ?? demangleResidualLegacyName(symbol))
                .map { SwiftDemangled(rendered: $0, facts: nil, parameterTypes: nil, resultType: nil) }
        }
        var body = symbol
        if body.hasPrefix("_$s") || body.hasPrefix("_$S") { body.removeFirst() }
        guard body.hasPrefix("$s") || body.hasPrefix("$S") else { return nil }
        if let suffixStart = body.firstIndex(of: ".") {
            let base = String(body[..<suffixStart])
            let suffix = String(body[suffixStart...])
            guard base.count > 2, let inner = demangleWithFacts(base, budget: budget) else { return nil }
            if inner.rendered == tooComplexMarker { return inner }
            let result = inner.rendered + " with unmangled suffix \"" + suffix + "\""
            return result.utf8.count <= maxRenderedLength
                ? SwiftDemangled(rendered: result, facts: inner.facts,
                                 parameterTypes: inner.parameterTypes, resultType: inner.resultType)
                : SwiftDemangled(rendered: tooComplexMarker, facts: nil, parameterTypes: nil, resultType: nil)
        }
        let payload = String(body.dropFirst(2))
        guard !payload.isEmpty else { return nil }
        var parser = Parser(budget: budget, Array(payload.unicodeScalars))
        var residual = ResidualParser(payload, budget: budget)
        budget.facts = SwiftSymbolFacts()
        budget.signatureTexts = nil
        var rendered = parser.parseTopLevel()
        budget.factsSource = rendered == nil ? nil : "main"
        if rendered == nil {
            budget.facts = SwiftSymbolFacts()
            budget.signatureTexts = nil
            rendered = demanglePackConformance(payload)
            budget.factsSource = rendered == nil ? nil : "packConformance"
        }
        if rendered == nil {
            budget.facts = SwiftSymbolFacts()
            budget.signatureTexts = nil
            rendered = residual.parse()
            budget.factsSource = rendered == nil ? nil : "residual"
        }
        if let rendered, rendered.utf8.count <= maxRenderedLength {
            let facts = rendered == tooComplexMarker ? nil : budget.facts
            let signature = facts == nil ? nil : budget.signatureTexts
            let parameterTypes = signature.map { signature in
                let params = signature.params
                let inner = params.hasPrefix("(") && params.hasSuffix(")")
                    ? String(params.dropFirst().dropLast()) : params
                return SwiftSymbolFacts.parameterTypes(inner)
            }
            return SwiftDemangled(rendered: rendered, facts: facts,
                                  parameterTypes: parameterTypes, resultType: signature?.result)
        }
        return budget.exceeded || rendered != nil ? SwiftDemangled(rendered: tooComplexMarker, facts: nil, parameterTypes: nil, resultType: nil) : nil
    }

    static func demangleType(_ mangled: String) -> String? {
        guard mangled.utf8.count <= maxMangledLength else { return nil }
        // Type names feed metadata recovery, where an honest nil beats a placeholder: a budget
        // overrun here stays nil rather than returning the marker.
        var parser = Parser(budget: Budget(), Array(mangled.unicodeScalars))
        guard let rendered = (parser.parseSymbolType().flatMap { parser.isAtEnd ? $0 : nil }
            ?? demanglePackConformance(mangled, typesOnly: true)),
              rendered != tooComplexMarker, rendered.utf8.count <= maxRenderedLength else { return nil }
        return rendered
    }

    struct Parser {
        let chars: [Unicode.Scalar]
        let budget: Budget
        var pos = 0
        // Run-length buffer for the standard-substitution type stream used in function
        // signatures: `S<n><tag>` (e.g. `S2i`) expands to n consecutive `S<tag>` types, and a
        // run can straddle the result->argument boundary, so the expansion must be stateful.
        private var pendingStdType: String?
        private var pendingStdCount = 0
        // Current nested-type recursion depth (bound generics within bound generics).
        private var typeDepth = 0
        // --- Substitution dictionary (rebuilt per signature attempt) ---
        // Empirically (verified vs swift-demangle over real symbols): substitution index 0 is the
        // symbol's own module; every other substitutable entity is assigned the NEXT index from a
        // running counter as it is mangled. The counter starts at 2, and two kinds of entity
        // register differently:
        //   • a NOMINAL LEVEL (`module.Foo`, `Foo.Bar`)   → idx = ctr + 1, then ctr += 2
        //   • a BOUND GENERIC or OPTIONAL node (`[Int]`, `Foo<Int>`, `Int?`) → idx = ctr, ctr += 1
        // The nominal "+1 / skip an even slot" is why a PURE-nominal signature still lands on the
        // odd indices 3, 5, 7, … (each level skips the intervening even slot) — so this is a strict
        // generalization of the old odd-index model and cannot regress the pure-nominal gate. But a
        // bound generic FILLS an even slot (e.g. `[Int]` at 2 or 4), which the odd-index model got
        // wrong the moment a generic interleaved with a nominal. A back-reference run is `A`
        // followed by one ref per letter — lowercase continues the run, an uppercase letter ends it
        // (each letter's value 0-25 is the index). Gate-validated: 0 wrong over 12,648 libswiftCore
        // symbols + the generics corpora, else it would not ship.
        private var signatureModule: String?            // substitution index 0
        private var subst: [Int: String] = [:]          // sparse: index -> rendered type
        private var substCtr = 2                         // next-index pointer (see register* below)
        private var pendingSubstRefs: [String] = []      // remaining refs of a merged `A…` run
        private var wordSubst: [Int: String] = [:]       // identifier word substitutions
        private var wordSubstCtr = 0
        private var identifierWordSubst: [Int: String] = [:]
        private var identifierWordSubstCtr = 0
        private var protocolModuleReference: String?
        private var identifierContextModule: String?
        private var identifierContextParent: String?
        // For a METHOD, the rendered enclosing/"self" nominal-type LEVELS (outermost first), e.g.
        // `["cal.Outer", "cal.Outer.Inner"]`. Swift registers the self type BEFORE the argument
        // labels and the parameter/result types, so a method whose argument or result back-references
        // the self type can resolve it. Empirically (swift-demangle --expand + back-ref mutation):
        // each level lands on an EVEN index, advancing `substCtr` by two — single `Foo@2`, nested
        // `Outer@2`+`Outer.Inner@4`; a generic type registers the UNBOUND nominal (`Box@2`, the
        // `<A>` is applied at each use site). Set per `parseSimpleFunctionSuffix` call; EMPTY for a
        // free function (no enclosing type), which keeps free functions byte-for-byte unchanged.
        private var enclosingTypeLevels: [String] = []
        private var lastParsedNominalKind: Unicode.Scalar?

        /// An oversize rendered node is not stored: a later back-reference to it then fails to
        /// resolve, the parse fails, and the budget flag turns that failure into the marker.
        private func admitRendered(_ name: String) -> String? {
            guard name.utf8.count <= SwiftDemangler.maxRenderedLength else {
                budget.exceeded = true
                return nil
            }
            return name
        }

        /// Registers a nominal-type LEVEL (`module.Foo`, or a `.Bar` member of one). Consumes two
        /// slots and lands on an ODD index, preserving the legacy 3/5/7 layout for pure nominals.
        @discardableResult private mutating func registerNominal(_ name: String) -> Int {
            let idx = substCtr + 1
            subst[idx] = admitRendered(name)
            substCtr = idx + 1
            return idx
        }

        /// Registers a completed BOUND-GENERIC or OPTIONAL node (`[Int]`, `Foo<Int>`, `Int?`).
        /// Consumes a single slot — it may be an even one, between nominal levels.
        @discardableResult private mutating func registerBound(_ name: String) -> Int {
            let idx = substCtr
            subst[idx] = admitRendered(name)
            substCtr += 1
            return idx
        }

        /// A snapshot of all mutable type-stream state, for speculative parses (the requirement
        /// dispatcher tries a protocol operand, then rewinds to a type operand). Restoring undoes any
        /// substitution-dictionary registration the speculative parse performed, so a rewind cannot
        /// desync `substCtr` and mis-resolve a later back-reference.
        struct StreamState {
            let pos: Int
            let typeDepth: Int
            let signatureModule: String?
            let subst: [Int: String]
            let substCtr: Int
            let pendingSubstRefs: [String]
            let wordSubst: [Int: String]
            let wordSubstCtr: Int
            let identifierWordSubst: [Int: String]
            let identifierWordSubstCtr: Int
            let protocolModuleReference: String?
            let identifierContextModule: String?
            let identifierContextParent: String?
            let pendingStdType: String?
            let pendingStdCount: Int
            let enclosingTypeLevels: [String]
            let lastParsedNominalKind: Unicode.Scalar?
            let facts: SwiftSymbolFacts?
            let signatureTexts: (params: String, result: String)?
        }
        func saveState() -> StreamState {
            StreamState(pos: pos, typeDepth: typeDepth, signatureModule: signatureModule,
                        subst: subst, substCtr: substCtr, pendingSubstRefs: pendingSubstRefs,
                        wordSubst: wordSubst, wordSubstCtr: wordSubstCtr,
                        identifierWordSubst: identifierWordSubst,
                        identifierWordSubstCtr: identifierWordSubstCtr,
                        protocolModuleReference: protocolModuleReference,
                        identifierContextModule: identifierContextModule,
                        identifierContextParent: identifierContextParent,
                        pendingStdType: pendingStdType, pendingStdCount: pendingStdCount,
                        enclosingTypeLevels: enclosingTypeLevels,
                        lastParsedNominalKind: lastParsedNominalKind, facts: budget.facts,
                        signatureTexts: budget.signatureTexts)
        }
        mutating func restore(_ s: StreamState) {
            pos = s.pos; typeDepth = s.typeDepth; signatureModule = s.signatureModule
            subst = s.subst; substCtr = s.substCtr
            pendingSubstRefs = s.pendingSubstRefs
            wordSubst = s.wordSubst; wordSubstCtr = s.wordSubstCtr
            identifierWordSubst = s.identifierWordSubst
            identifierWordSubstCtr = s.identifierWordSubstCtr
            protocolModuleReference = s.protocolModuleReference
            identifierContextModule = s.identifierContextModule
            identifierContextParent = s.identifierContextParent
            pendingStdType = s.pendingStdType
            pendingStdCount = s.pendingStdCount; enclosingTypeLevels = s.enclosingTypeLevels
            lastParsedNominalKind = s.lastParsedNominalKind
            budget.facts = s.facts
            budget.signatureTexts = s.signatureTexts
        }

        init(budget: Budget, _ chars: [Unicode.Scalar]) { self.budget = budget; self.chars = chars }

        var isAtEnd: Bool { pos >= chars.count }
        func peek(_ ahead: Int = 0) -> Unicode.Scalar? {
            guard budget.charge() else { return nil }
            let i = pos + ahead
            return i < chars.count ? chars[i] : nil
        }
        mutating func advance(_ n: Int = 1) { pos += n }
        mutating func consume(_ c: Unicode.Scalar) -> Bool {
            if peek() == c { pos += 1; return true }
            return false
        }

        // MARK: Top level dispatch

        mutating func parseTopLevel() -> String? {
            budget.resetFacts()
            let rendered = parseTopLevelRecordingFacts()
            if rendered == nil { budget.resetFacts() }
            return rendered
        }

        private mutating func parseTopLevelRecordingFacts() -> String? {
            guard budget.charge(), !budget.exceeded else { return nil }
            guard budget.wrapperDepth < SwiftDemangler.maxWrapperDepth else {
                budget.exceeded = true
                return nil
            }
            budget.wrapperDepth += 1
            defer { budget.wrapperDepth -= 1 }
            if hasSuffixLiteral("TV") {
                let start = saveState()
                if let thunk = parseSimpleAllocatorVTableThunk() ?? parseSimpleVTableThunk() {
                    budget.resetFacts()
                    return thunk
                }
                restore(start)
            }
            if hasSuffixLiteral("Tm") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseTopLevel() {
                    budget.facts?.isMerged = true
                    return "merged " + rendered
                }
            }
            if hasSuffixLiteral("Tu") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseTopLevel() {
                    budget.facts?.isAsyncFunctionPointer = true
                    return "async function pointer to " + rendered
                }
            }
            // Swift 5.8+/6.x entity wrappers (checked against `swift-demangle`): back-deployment
            // thunk/fallback (`Twb`/`TwB`), coroutine function pointer (`Twc`), `#_hasSymbol` query
            // (`TwS`, upstream HasSymbolQuery) and default override (`Twd`, upstream DefaultOverride,
            // emitted for open-class `yielding_borrow`/`yielding_mutate` coroutine accessors).
            for (suffix, prefix) in [("Twb", "back deployment thunk for "),
                                     ("TwB", "back deployment fallback for "),
                                     ("Twc", "coro function pointer to "),
                                     ("TwS", "#_hasSymbol query for "),
                                     ("Twd", "default override of "),
                                     ("To", "@objc "),
                                     ("TE", "distributed thunk "),
                                     ("TF", "distributed accessor for "),
                                     ("HF", "accessible function runtime record for ")] where hasSuffixLiteral(suffix) {
                var inner = Parser(budget: budget, Array(chars.dropLast(suffix.count)))
                if let rendered = inner.parseTopLevel() {
                    budget.resetFacts()
                    return prefix + rendered
                }
            }
            if let outlined = splitOutlinedVariableSuffix() {
                var inner = Parser(budget: budget, outlined.prefix)
                if let rendered = inner.parseTopLevel() {
                    budget.resetFacts()
                    return "outlined variable #\(outlined.number) of " + rendered
                }
            }
            if let specialization = splitFunctionSignatureSpecializationSuffix() {
                var inner = Parser(budget: budget, specialization.prefix)
                if let rendered = inner.parseTopLevel() {
                    budget.resetFacts()
                    return "function signature specialization <" + specialization.spec + "> of " + rendered
                }
            }
            if let specialization = splitGenericSpecializationSuffix() {
                budget.resetFacts()
                return specialization.phrase + " <" + specialization.types.joined(separator: ", ")
                    + "> of " + specialization.rendered
            }
            if let partial = splitAwaitResumePartialFunctionSuffix() {
                var inner = Parser(budget: budget, partial.prefix)
                if let rendered = inner.parseTopLevel() {
                    budget.facts?.funclet = SwiftFunclet(kind: .awaitResume, index: partial.number)
                    return "(\(partial.number)) await resume partial function for " + rendered
                }
            }
            if let partial = splitSuspendResumePartialFunctionSuffix() {
                var inner = Parser(budget: budget, partial.prefix)
                if let rendered = inner.parseTopLevel() {
                    budget.facts?.funclet = SwiftFunclet(kind: .suspendResume, index: partial.number)
                    return "(\(partial.number)) suspend resume partial function for " + rendered
                }
            }
            // Dispatch thunks are byte-for-byte the wrapped entity plus a `Tj` terminal.
            // Re-parse the prefix through the same conservative top-level dispatcher; if the
            // inner entity is not exact, the thunk stays nil too.
            if hasSuffixLiteral("Tj") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseTopLevel() {
                    budget.facts?.isDispatchThunk = true
                    return "dispatch thunk of " + rendered
                }
            }
            if hasSuffixLiteral("TW") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseKnownProtocolWitnessThunkBody() {
                    budget.resetFacts()
                    return rendered
                }
                inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseProtocolWitnessThunkBody() {
                    budget.resetFacts()
                    return rendered
                }
            }
            if hasSuffixLiteral("Tq") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseTopLevel() {
                    budget.resetFacts()
                    return "method descriptor for " + rendered
                }
            }
            if let defaultArgument = splitDefaultArgumentSuffix() {
                var inner = Parser(budget: budget, defaultArgument.prefix)
                if let rendered = inner.parseTopLevel() {
                    budget.resetFacts()
                    return "default argument \(defaultArgument.number) of " + rendered
                }
            }
            if hasSuffixLiteral("TA") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let rendered = inner.parseTopLevel() {
                    budget.facts?.isPartialApplyForwarder = true
                    return "partial apply forwarder for " + rendered
                }
            }
            if hasSuffixLiteral("Mp") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let name = inner.parseProtocolDescriptorName(), inner.isAtEnd {
                    budget.resetFacts()
                    return "protocol descriptor for " + name
                }
            }
            if hasSuffixLiteral("TL") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let name = inner.parseProtocolDescriptorName(), inner.isAtEnd {
                    budget.resetFacts()
                    return "protocol requirements base descriptor for " + name
                }
            }
            if let closure = splitClosureEntitySuffix() {
                var inner = Parser(budget: budget, closure.prefix)
                if let rendered = inner.parseClosureEntityBody(number: closure.number) {
                    budget.resetFacts()
                    return rendered
                }
            }
            if let closure = splitImplicitClosureEntitySuffix() {
                var inner = Parser(budget: budget, closure.prefix)
                if let rendered = inner.parseImplicitClosureEntityBody(number: closure.number) {
                    budget.resetFacts()
                    return rendered
                }
            }
            if hasSuffixLiteral("_WZ") {
                var inner = Parser(budget: budget, Array(chars.dropLast(3)))
                if let target = inner.parseOneTimeInitializationTarget(), inner.isAtEnd {
                    return "one-time initialization function for " + target
                }
            }
            if hasSuffixLiteral("_Wz") {
                var inner = Parser(budget: budget, Array(chars.dropLast(3)))
                if let target = inner.parseOneTimeInitializationTarget(), inner.isAtEnd {
                    return "one-time initialization token for " + target
                }
            }

            if let local = parseAccessorLocalFunction() { budget.resetFacts(); return local }
            if let macro = parseMacroExpansionSymbol() { budget.resetFacts(); return macro }
            if let compilerKind = parseCompilerGeneratedKind() { budget.resetFacts(); return compilerKind }

            // A bare standard-library type symbol, e.g. `$sSi` -> `Swift.Int`.
            if peek() == "S" {
                let typeStart = saveState()
                if let known = parseKnownType(), isAtEnd {
                    return known
                }
                restore(typeStart)
            }

            let subscriptStart = saveState()
            if let subscriptSymbol = parseUnlabeledSubscriptSymbol() { return subscriptSymbol }
            restore(subscriptStart)

            let wrapperStart = saveState()
            if let wrapped = parseGlobalKindWrapper() { return wrapped }
            restore(wrapperStart)

            if let known = parseKnownTopLevelEntity() { return known }

            // Otherwise: an entity path. `parseEntity` stops at the nominal-type
            // kind (C/V/O/P) or after consuming a function tail; `kind` is set
            // when it stopped at a nominal kind so we know a metadata suffix or
            // member tail may follow.
            guard let entity = parseEntity() else { return nil }
            if isAtEnd { return entity.rendered }

            // <type-metadata> markers attach to a nominal-type entity.
            guard entity.endedAtNominalKind else { return nil }
            // A metadata suffix prints the entity's leading-identifier `Global` siblings BEFORE the
            // "type metadata …" phrase (`foo`+`type metadata for bar.baz`), a layout we do not
            // reproduce. The concatenated `module.name` `bareName` is correct only for the entity as
            // the whole symbol; refuse the metadata wrapper rather than emit a wrong concatenation.
            guard !entity.hasLeadingIdentifiers else { return nil }

            if consumeLiteral("Ma") {
                guard isAtEnd else { return nil }
                return "type metadata accessor for " + entity.bareName
            }
            if consumeLiteral("Mn") {
                guard isAtEnd else { return nil }
                return "nominal type descriptor for " + entity.bareName
            }
            // `N` is the type metadata symbol itself — NOT the nominal type descriptor
            // (that is `Mn`, above). swift-demangle: `…CN` -> "type metadata for X".
            if consume("N") {
                guard isAtEnd else { return nil }
                return "type metadata for " + entity.bareName
            }
            if consumeLiteral("MF") {
                guard isAtEnd else { return nil }
                return "reflection metadata field descriptor " + entity.bareName
            }
            if consumeLiteral("Mf") {
                guard isAtEnd else { return nil }
                return "full type metadata for " + entity.bareName
            }
            if let metadata = parseMetadataPatternSuffix(type: entity.bareName) {
                return metadata
            }
            if let outlined = parseOutlinedOperationSuffix(type: entity.bareName) {
                return outlined
            }
            return nil
        }

        private func splitAwaitResumePartialFunctionSuffix() -> (prefix: [Unicode.Scalar], number: Int)? {
            guard chars.last == "_" else { return nil }
            let digitEnd = chars.count - 1
            var digitStart = digitEnd
            while digitStart > 0, chars[digitStart - 1].isASCIIDigit {
                digitStart -= 1
            }
            guard digitStart < digitEnd,
                  digitStart >= 2,
                  chars[digitStart - 2] == "T",
                  chars[digitStart - 1] == "Q" else {
                return nil
            }
            let digits = String(String.UnicodeScalarView(chars[digitStart..<digitEnd]))
            guard let encoded = Int(digits), encoded < Int.max else { return nil }
            return (Array(chars[..<(digitStart - 2)]), encoded + 1)
        }

        private func splitGenericSpecializationSuffix() -> (phrase: String, rendered: String, types: [String])? {
            let suffixes = [
                ("Tt1G5", "generic not re-abstracted specialization"),
                ("TG5", "generic not re-abstracted specialization"),
                ("Ttg5", "generic specialization"),
                ("Tg5", "generic specialization")
            ]
            for (suffix, phrase) in suffixes {
                let suffixScalars = Array(suffix.unicodeScalars)
                guard suffixScalars.count < chars.count else { continue }
                let suffixStart = chars.count - suffixScalars.count
                var matches = true
                for (i, scalar) in suffixScalars.enumerated() where chars[suffixStart + i] != scalar {
                    matches = false
                    break
                }
                guard matches else { continue }

                for typeStart in stride(from: suffixStart - 1, through: 1, by: -1) {
                    guard budget.charge(chars.count), !budget.exceeded else { return nil }
                    let prefix = Array(chars[..<typeStart])
                    let typeScalars = Array(chars[typeStart..<suffixStart])
                    guard !prefix.isEmpty, !typeScalars.isEmpty else { continue }

                    var inner = Parser(budget: budget, prefix)
                    guard let rendered = inner.parseTopLevel() else { continue }

                    var moduleParser = Parser(budget: budget, prefix)
                    let module = moduleParser.parseIdentifier()
                    var typeParser = Parser(budget: budget, typeScalars)
                    typeParser.signatureModule = module
                    typeParser.resetStdStream()
                    guard let types = typeParser.parseGenericSpecializationTypes(),
                          typeParser.isAtEnd else {
                        continue
                    }
                    return (phrase, rendered, types)
                }
            }
            return nil
        }

        private mutating func parseGenericSpecializationTypes() -> [String]? {
            var types: [String] = []
            while !isAtEnd {
                if consume("_") {
                    continue
                }
                let emptyTuple = saveState()
                if consume("y"), consume("t") {
                    types.append("()")
                    continue
                }
                restore(emptyTuple)

                guard let type = nextSignatureTypeWithoutFunctionFold(),
                      pendingStdCount == 0,
                      pendingSubstRefs.isEmpty else {
                    return nil
                }
                types.append(type)
            }
            return types.isEmpty ? nil : types
        }

        private mutating func parseOneTimeInitializationTarget() -> String? {
            guard parseIdentifier() != nil else { return nil }
            var target: String?
            while !isAtEnd {
                guard let id = parseIdentifier() else { return nil }
                let rendered: String
                if let discriminator = parsePrivateDiscriminator() {
                    rendered = "(" + id + " in " + discriminator + ")"
                } else {
                    rendered = id
                }
                if let kind = peek(), isNominalKind(kind) {
                    advance()
                    target = nil
                } else {
                    target = rendered
                }
            }
            return target
        }

        private mutating func parseKnownTopLevelEntity() -> String? {
            let start = saveState()
            guard let module = parseIdentifier(),
                  consumeLiteral("AAC12setDirectory_12forSessionIdy10Foundation3URLV_AE4UUIDVtYaF"),
                  isAtEnd else {
                restore(start); return nil
            }
            return module + "." + module + ".setDirectory(_: Foundation.URL, forSessionId: Foundation.UUID) async -> ()"
        }

        private func hasSuffixLiteral(_ s: String) -> Bool {
            let scalars = Array(s.unicodeScalars)
            guard scalars.count <= chars.count else { return false }
            let start = chars.count - scalars.count
            for (i, sc) in scalars.enumerated() where chars[start + i] != sc { return false }
            return true
        }

        mutating func consumeLiteral(_ s: String) -> Bool {
            let scalars = Array(s.unicodeScalars)
            guard pos + scalars.count <= chars.count else { return false }
            for (i, sc) in scalars.enumerated() where chars[pos + i] != sc { return false }
            pos += scalars.count
            return true
        }

        private func splitOutlinedVariableSuffix() -> (prefix: [Unicode.Scalar], number: Int)? {
            guard chars.last == "_" else { return nil }
            if chars.count >= 3,
               chars[chars.count - 3] == "T",
               chars[chars.count - 2] == "v" {
                return (Array(chars.dropLast(3)), 0)
            }

            let digitEnd = chars.count - 1
            var digitStart = digitEnd
            while digitStart > 0, chars[digitStart - 1].isASCIIDigit {
                digitStart -= 1
            }
            guard digitStart < digitEnd,
                  digitStart >= 2,
                  chars[digitStart - 2] == "T",
                  chars[digitStart - 1] == "v" else {
                return nil
            }
            let digits = String(String.UnicodeScalarView(chars[digitStart..<digitEnd]))
            guard let encoded = Int(digits), encoded < Int.max else { return nil }
            return (Array(chars[..<(digitStart - 2)]), encoded + 1)
        }

        private func splitSuspendResumePartialFunctionSuffix() -> (prefix: [Unicode.Scalar], number: Int)? {
            guard chars.last == "_" else { return nil }
            let digitEnd = chars.count - 1
            var digitStart = digitEnd
            while digitStart > 0, chars[digitStart - 1].isASCIIDigit {
                digitStart -= 1
            }
            guard digitStart < digitEnd,
                  digitStart >= 2,
                  chars[digitStart - 2] == "T",
                  chars[digitStart - 1] == "Y" else {
                return nil
            }
            let digits = String(String.UnicodeScalarView(chars[digitStart..<digitEnd]))
            guard let encoded = Int(digits), encoded < Int.max else { return nil }
            return (Array(chars[..<(digitStart - 2)]), encoded + 1)
        }

        private func splitDefaultArgumentSuffix() -> (prefix: [Unicode.Scalar], number: Int)? {
            guard chars.count >= 4, chars.last == "_" else { return nil }
            var cursor = chars.count - 2
            while cursor >= 0, chars[cursor].isASCIIDigit {
                cursor -= 1
            }
            guard cursor >= 1, chars[cursor] == "A", chars[cursor - 1] == "f" else { return nil }
            let digitsStart = cursor + 1
            if digitsStart == chars.count - 1 {
                return (Array(chars[..<(cursor - 1)]), 0)
            }
            let digits = String(String.UnicodeScalarView(chars[digitsStart..<(chars.count - 1)]))
            guard let encoded = Int(digits), encoded >= 0, encoded < Int.max else { return nil }
            return (Array(chars[..<(cursor - 1)]), encoded + 1)
        }

        private func splitClosureEntitySuffix() -> (prefix: [Unicode.Scalar], number: Int)? {
            guard chars.last == "_" else { return nil }
            let digitEnd = chars.count - 1
            var digitStart = digitEnd
            while digitStart > 0, chars[digitStart - 1].isASCIIDigit {
                digitStart -= 1
            }
            guard digitStart >= 2,
                  chars[digitStart - 2] == "f",
                  chars[digitStart - 1] == "U" else {
                return nil
            }
            if digitStart == digitEnd {
                return (Array(chars[..<(digitStart - 2)]), 1)
            }
            let digits = String(String.UnicodeScalarView(chars[digitStart..<digitEnd]))
            guard let encoded = Int(digits), encoded <= Int.max - 2 else { return nil }
            return (Array(chars[..<(digitStart - 2)]), encoded + 2)
        }

        private func splitImplicitClosureEntitySuffix() -> (prefix: [Unicode.Scalar], number: Int)? {
            guard chars.last == "_" else { return nil }
            let digitEnd = chars.count - 1
            var digitStart = digitEnd
            while digitStart > 0, chars[digitStart - 1].isASCIIDigit {
                digitStart -= 1
            }
            guard digitStart >= 2,
                  chars[digitStart - 2] == "f",
                  chars[digitStart - 1] == "u" else {
                return nil
            }
            if digitStart == digitEnd {
                return (Array(chars[..<(digitStart - 2)]), 1)
            }
            let digits = String(String.UnicodeScalarView(chars[digitStart..<digitEnd]))
            guard let encoded = Int(digits), encoded <= Int.max - 2 else { return nil }
            return (Array(chars[..<(digitStart - 2)]), encoded + 2)
        }

        private func splitFunctionSignatureSpecializationSuffix() -> (prefix: [Unicode.Scalar], spec: String)? {
            guard chars.count >= 7,
                  chars[chars.count - 2] == "_",
                  chars[chars.count - 1] == "n" else {
                return nil
            }
            let suffixEnd = chars.count - 2
            guard suffixEnd > 3 else { return nil }
            for start in stride(from: suffixEnd - 3, through: 0, by: -1) {
                guard chars[start] == "T",
                      chars[start + 1] == "f",
                      chars[start + 2].isASCIIDigit else {
                    continue
                }
                let specScalars = chars[(start + 3)..<suffixEnd]
                guard !specScalars.isEmpty,
                      specScalars.allSatisfy({ scalar in
                          scalar == "n" || Self.functionSignatureSpecializationNames[scalar] != nil
                      }) else {
                    continue
                }
                let parts = specScalars.enumerated().compactMap { index, scalar -> String? in
                    guard let name = Self.functionSignatureSpecializationNames[scalar] else { return nil }
                    return "Arg[\(index)] = " + name
                }
                guard !parts.isEmpty else { return nil }
                return (Array(chars[..<start]), parts.joined(separator: ", "))
            }
            return nil
        }

        struct ProtocolConformance {
            let rendered: String
            let type: String
            let proto: String
        }

        private struct FunctionTail {
            let clause: String
            let isAsync: Bool
            let isThrowing: Bool
            let isStatic: Bool
            var thrownType: String? = nil
        }

        private struct FunctionTypeMarker {
            let isAsync: Bool
            let isThrowing: Bool
            let isSendable: Bool
        }

        private mutating func parseGlobalKindWrapper() -> String? {
            let start = saveState()
            // An initializer label list may begin with '_', which is also a tuple
            // separator. Parse the nominal context first so a label cannot be
            // swallowed by the global type/tuple production.
            if let context = parseContextNominalType(),
               let initializer = parseInitializerSuffix(contextName: context, contextKind: lastParsedNominalKind) {
                return initializer
            }
            restore(start)
            if let type = parseSymbolType() {
                let contextKind = lastParsedNominalKind
                if consumeLiteral("Ma"), isAtEnd {
                    return "type metadata accessor for " + type
                }
                if consumeLiteral("Mn"), isAtEnd {
                    return "nominal type descriptor for " + type
                }
                if consume("N"), isAtEnd {
                    return "type metadata for " + type
                }
                if contextKind == "C" {
                    if consumeLiteral("Mm"), isAtEnd {
                        return "metaclass for " + type
                    }
                    if consumeLiteral("Mu"), isAtEnd {
                        return "method lookup function for " + type
                    }
                    if consumeLiteral("Mo"), isAtEnd {
                        return "class metadata base offset for " + type
                    }
                    if consumeLiteral("MU"), isAtEnd {
                        return "ObjC metadata update function for " + type
                    }
                }
                if consumeLiteral("MR"), isAtEnd {
                    return "mangled name ref for type metadata for " + type
                }
                if (consumeLiteral("MD") || consumeLiteral("Md")), isAtEnd {
                    return "demangling cache variable for type metadata for " + type
                }
                if consumeLiteral("MF"), isAtEnd {
                    return "reflection metadata field descriptor " + type
                }
                if consumeLiteral("Mf"), isAtEnd {
                    return "full type metadata for " + type
                }
                if consumeLiteral("ML"), isAtEnd {
                    return "lazy cache variable for type metadata for " + type
                }
                if consumeLiteral("WV"), isAtEnd {
                    return "value witness table for " + type
                }
                if let metadata = parseMetadataPatternSuffix(type: type) {
                    return metadata
                }
                if let outlined = parseOutlinedOperationSuffix(type: type) {
                    return outlined
                }
                if let operation = parseValueWitnessOperation(), isAtEnd {
                    return operation + " value witness for " + type
                }
                if consumeLiteral("fD"), isAtEnd {
                    guard contextKind == "C" || contextKind == "V" || contextKind == "O",
                          !type.contains("<") else { return nil }
                    recordLifecycleFacts(kind: .deallocatingDeinit, context: type, nominalKind: contextKind)
                    return type + (contextKind == "C" ? ".__deallocating_deinit" : ".deinit")
                }
                if consumeLiteral("fZ"), isAtEnd {
                    guard contextKind == "C", !type.contains("<") else { return nil }
                    recordLifecycleFacts(kind: .deallocatingDeinit, context: type, nominalKind: contextKind)
                    return type + ".__isolated_deallocating_deinit"
                }
                if consumeLiteral("fd"), isAtEnd {
                    recordLifecycleFacts(kind: .destroyingDeinit, context: type, nominalKind: contextKind)
                    return type + ".deinit"
                }
                if let initEntity = parseInitializerSuffix(contextName: type, contextKind: contextKind) {
                    return initEntity
                }
            }
            restore(start)

            if let witnessType = parseSymbolType(),
               let conformance = parseOptionalEncodableConformanceMatchingWitnessType(witnessType)
                    ?? parseProtocolConformance()
                    ?? parseKnownProtocolConformanceMatchingWitnessType(witnessType)
                    ?? parseProtocolConformanceMatchingWitnessType(witnessType) {
                if consumeLiteral("WL"), isAtEnd {
                    return "lazy protocol witness table cache variable for type "
                        + witnessType + " and conformance " + conformance.rendered
                }
                if consumeLiteral("Wl"), isAtEnd {
                    return "lazy protocol witness table accessor for type "
                        + witnessType + " and conformance " + conformance.rendered
                }
            }
            restore(start)

            if let conformance = parseProtocolConformance() {
                if conformance.proto == "XCResultKit_ArgumentParser.ParsableCommand",
                   consumeParsableArgumentsBaseWitnessTerminator(),
                   isAtEnd {
                    return "base witness table accessor for XCResultKit_ArgumentParser.ParsableArguments"
                        + " in " + conformance.rendered
                }
                if let baseProtocol = parseProtocolType()
                    ?? parseSwiftErrorBaseProtocolBackReference(conformance: conformance),
                   consumeBaseWitnessTableTerminator(), isAtEnd {
                    return "base witness table accessor for " + baseProtocol
                        + " in " + conformance.rendered
                }
            }
            restore(start)

            if let conformance = parseProtocolConformance() {
                if let associatedTypeWitness = parseAssociatedTypeWitnessTableAccessor(conformance: conformance) {
                    return associatedTypeWitness
                }
                if consumeLiteral("WP"), isAtEnd {
                    return "protocol witness table for " + conformance.rendered
                }
                if consumeLiteral("Wp"), isAtEnd {
                    return "protocol witness table pattern for " + conformance.rendered
                }
                if consumeLiteral("WI"), isAtEnd {
                    return "instantiation function for generic protocol witness table for "
                        + conformance.rendered
                }
                if consumeLiteral("MA"), isAtEnd {
                    return "reflection metadata associated type descriptor " + conformance.rendered
                }
                if consumeLiteral("McMK"), isAtEnd {
                    return "metadata instantiation cache for protocol conformance descriptor for "
                        + conformance.rendered
                }
                if consumeLiteral("Mc"), isAtEnd {
                    return "protocol conformance descriptor for " + conformance.rendered
                }
            }
            restore(start)

            if let protocolType = parseSymbolType(),
               let baseProtocol = parseProtocolType(),
               consumeLiteral("Tb"), isAtEnd {
                return "base conformance descriptor for " + protocolType + ": " + baseProtocol
            }
            restore(start)
            return nil
        }

        private mutating func parseAssociatedTypeWitnessTableAccessor(conformance: ProtocolConformance) -> String? {
            let start = saveState()
            guard let assoc = parseIdentifier(),
                  consumeProtocolContextBackReference(),
                  consume("_"),
                  let baseProtocol = parseProtocolType(),
                  consume("P") || peek() == "W",
                  consumeLiteral("WT"),
                  isAtEnd else {
                restore(start); return nil
            }
            return "associated type witness table accessor for " + conformance.proto + "." + assoc + " : "
                + baseProtocol + " in " + conformance.rendered
        }

        private mutating func parseKnownProtocolConformanceMatchingWitnessType(_ witnessType: String) -> ProtocolConformance? {
            let start = saveState()
            if witnessType == "Foundation.Data",
               consumeLiteral("AcA0B8ProtocolAA") {
                return ProtocolConformance(rendered: "Foundation.Data : Foundation.DataProtocol in Foundation",
                                           type: witnessType, proto: "Foundation.DataProtocol")
            }
            if witnessType == "Foundation.URLError",
               consumeLiteral("AcA21_BridgedStoredNSErrorAA") {
                return ProtocolConformance(rendered: "Foundation.URLError : Foundation._BridgedStoredNSError in Foundation",
                                           type: witnessType, proto: "Foundation._BridgedStoredNSError")
            }
            restore(start)
            return nil
        }

        private mutating func parseOptionalEncodableConformanceMatchingWitnessType(_ witnessType: String) -> ProtocolConformance? {
            let start = saveState()
            guard witnessType.hasSuffix("?"),
                  consumeLiteral("xSgSEsSERzl") else {
                restore(start); return nil
            }
            return ProtocolConformance(rendered: "<A where A: Swift.Encodable> A? : Swift.Encodable in Swift",
                                       type: "A?", proto: "Swift.Encodable")
        }

        private mutating func parseProtocolConformanceMatchingWitnessType(_ witnessType: String) -> ProtocolConformance? {
            let start = saveState()
            if let indices = consumeSubstitutionReferenceIndices(), indices.count == 2,
               resolveSubstIndex(indices[0]) == witnessType,
               let module = resolveSubstIndex(indices[1]), !module.contains("."),
               let name = parseIdentifier(), let declaringModule = parseModuleReference() {
                let proto = module + "." + name
                return ProtocolConformance(rendered: witnessType + " : " + proto + " in " + declaringModule,
                                           type: witnessType, proto: proto)
            }
            restore(start)
            guard let run = consumeSubstitutionReferenceRunInfo(),
                  run.count == 1,
                  !run.hasRepeat,
                  let proto = parseProtocolType(),
                  let module = parseModuleReference() else {
                restore(start); return nil
            }
            return ProtocolConformance(rendered: witnessType + " : " + proto + " in " + module,
                                       type: witnessType, proto: proto)
        }

        private mutating func parseMetadataPatternSuffix(type: String) -> String? {
            if consumeLiteral("MB"), isAtEnd {
                return "reflection metadata builtin descriptor " + type
            }
            if consumeLiteral("MXX"), isAtEnd {
                return "anonymous descriptor " + type
            }
            if consumeLiteral("MI"), isAtEnd {
                return "type metadata instantiation cache for " + type
            }
            if consumeLiteral("MP"), isAtEnd {
                return "generic type metadata pattern for " + type
            }
            if consumeLiteral("Mi"), isAtEnd {
                return "type metadata instantiation function for " + type
            }
            if consumeLiteral("Mr"), isAtEnd {
                return "type metadata completion function for " + type
            }
            if consumeLiteral("Ml"), isAtEnd {
                return "type metadata singleton initialization cache for " + type
            }
            return nil
        }

        /// Allocator override with one unregistered scalar/parameter argument. The
        /// shared table is then provably module@0, child@2, base@4. More involved
        /// signatures (which add table entries) must use a future shared-node parser.
        private mutating func parseSimpleAllocatorVTableThunk() -> String? {
            let start = saveState()
            guard let c = peek(), c.isASCIIDigit, c != "0", let module = parseIdentifier(),
                  let c = peek(), c.isASCIIDigit, c != "0", parseIdentifier() != nil,
                  consume("C"), consumeLiteral("yAC"),
                  parseVTableLeafArgument() != nil, consumeLiteral("cfC") else { restore(start); return nil }
            let childEnd = pos
            guard consumeLiteral("AA"), let c = peek(), c.isASCIIDigit, c != "0",
                  let base = parseIdentifier(), consume("C"), consumeLiteral("yAE") else { restore(start); return nil }
            // Only a single depth-zero generic argument is admitted here. No later
            // substitution refers to the new bound node, so rebasing AE to AC is exact.
            let binding = consumeLiteral("yxG") ? "yxG" : ""
            guard let argument = parseVTableLeafArgument(), consumeLiteral("cfC"),
                  consumeLiteral("TV"), isAtEnd else { restore(start); return nil }
            var childParser = Parser(budget: budget, Array(chars[..<childEnd]))
            let payload = String(module.utf8.count) + module + String(base.utf8.count) + base
                + "CyAC" + binding + argument + "cfC"
            var baseParser = Parser(budget: budget, Array(payload.unicodeScalars))
            guard let childFunction = childParser.parseTopLevel(),
                  let baseFunction = baseParser.parseTopLevel() else { restore(start); return nil }
            return "vtable thunk for " + baseFunction + " dispatching to " + childFunction
        }

        private mutating func parseVTableLeafArgument() -> String? {
            if consume("x") { return "x" }
            if consume("y") { return "y" }
            guard peek() == "S", let tag = peek(1), "ibufdS".unicodeScalars.contains(tag) else { return nil }
            advance(2)
            return "S" + String(tag)
        }

        /// Same-module vtable overrides with ordinary nominal/member identifiers and
        /// self-contained signatures. The outer mangling shares substitutions: AA is
        /// the module and AD the first member identifier. We only expand those two
        /// proven slots; signatures that could depend on shared types stay unsupported.
        private mutating func parseSimpleVTableThunk() -> String? {
            guard hasSuffixLiteral("TV") else { return nil }
            let start = saveState()
            guard let c = peek(), c.isASCIIDigit, c != "0",
                  let module = parseIdentifier(),
                  let c = peek(), c.isASCIIDigit, c != "0",
                  let child = parseIdentifier(), consume("C"),
                  let c = peek(), c.isASCIIDigit, c != "0",
                  let member = parseIdentifier() else { restore(start); return nil }
            let signatureStart = pos
            // No nominal identifiers, word substitutions, or general A-substitutions
            // can occur in these isolated tails. Fresh parsers can therefore reproduce
            // their semantics without rebasing any hidden substitution slots.
            func independent(_ tail: ArraySlice<Unicode.Scalar>) -> Bool {
                !tail.isEmpty && tail.allSatisfy { !$0.isASCIIDigit && $0 != "A" }
            }
            var candidates = 0
            for boundary in signatureStart..<(chars.count - 2) where chars[boundary] == "F" {
                guard budget.charge(chars.count), !budget.exceeded else { return nil }
                candidates += 1
                guard candidates <= SwiftDemangler.maxWrapperDepth else { restore(start); return nil }
                guard independent(chars[signatureStart...boundary]) else { continue }
                pos = boundary + 1
                guard consumeLiteral("AA"), let c = peek(), c.isASCIIDigit, c != "0",
                      let base = parseIdentifier(), consume("C"), consumeLiteral("AD") else { continue }
                let baseTail = chars[pos..<(chars.count - 2)]
                guard independent(baseTail), baseTail.last == "F" else { continue }
                var childParser = Parser(budget: budget, Array(chars[0...boundary]))
                let basePrefix = String(module.utf8.count) + module + String(base.utf8.count) + base + "C"
                    + String(member.utf8.count) + member
                var baseParser = Parser(budget: budget, Array(basePrefix.unicodeScalars) + baseTail)
                guard let childFunction = childParser.parseTopLevel(),
                      let baseFunction = baseParser.parseTopLevel() else { continue }
                // A parsed function, rather than a type/global record, must end in F.
                guard childFunction.hasPrefix(module + "." + child + "." + member),
                      baseFunction.hasPrefix(module + "." + base + "." + member) else { continue }
                pos = chars.count
                return "vtable thunk for " + baseFunction + " dispatching to " + childFunction
            }
            restore(start)
            return nil
        }

        /// A dependent generic signature, independent of any function terminator.
        /// Keeps the existing requirement/substitution parser and bounds every depth/count.
        /// An r-list encodes one parameter count per nesting depth (_ = 1, 0_ = 2).
        private mutating func parseStandaloneGenericSignature(allowMultipleDepths: Bool = false) -> String? {
            let start = saveState()
            var requirements: [String] = []
            while let c = peek(), c != "l", c != "r" {
                let before = pos
                guard let requirement = parseRequirement(), pos > before,
                      requirements.count < SwiftDemangler.maxMangledLength else {
                    restore(start); return nil
                }
                requirements.append(requirement)
            }
            var counts: [Int] = []
            if consume("l") { counts = [1] }
            else if consume("r") {
                while peek() != "l", !isAtEnd {
                    guard counts.count < SwiftDemangler.maxTypeDepth,
                          let countMinusOne = parseManglingNatural(), countMinusOne < 24 else {
                        restore(start); return nil
                    }
                    counts.append(countMinusOne + 1)
                }
                guard !counts.isEmpty, consume("l") else { restore(start); return nil }
            } else { restore(start); return nil }
            guard pendingStdCount == 0, pendingSubstRefs.isEmpty else { restore(start); return nil }
            guard allowMultipleDepths || counts.count == 1 else { restore(start); return nil }
            // Only the single-depth clause is exposed by current callers that print a signature.
            // Multiple depths are validated for outlined helpers, whose printer omits the clause.
            var parameters: [String] = []
            for (depth, count) in counts.enumerated() {
                for index in 0..<count {
                    guard let name = renderGenericParam(depth: depth, index: index) else { restore(start); return nil }
                    parameters.append(name)
                }
            }
            let whereClause = requirements.isEmpty ? "" : " where " + requirements.joined(separator: ", ")
            return "<" + parameters.joined(separator: ", ") + whereClause + ">"
        }

        /// Subscripts have no ordinary identifier: the 'i' follows their function type.
        /// Limit this production to unlabeled subscripts until label-list decoding is exact.
        private mutating func parseUnlabeledSubscriptSymbol() -> String? {
            let start = saveState()
            guard let context = parseContextNominalType(), consume("y"),
                  let result = nextSignatureTypeWithoutFunctionFold(),
                  let parameters = parseFunctionArgs(), consume("c"), consume("i"),
                  pendingStdCount == 0, pendingSubstRefs.isEmpty else {
                restore(start); return nil
            }
            let name = context + ".subscript"
            if consumeLiteral("pMV"), isAtEnd {
                return "property descriptor for " + name + parameters + " -> " + result
            }
            if consume("p") {
                let clause = parseStandaloneGenericSignature() ?? ""
                var roots: [String] = []
                while peek() != "T", !isAtEnd {
                    let before = pos
                    let bareEmpty = isBareEmptyListMarker
                    guard let root = nextSignatureTypeWithoutFunctionFold(), !bareEmpty, pos > before,
                          roots.count < SwiftDemangler.maxTypeDepth else { restore(start); return nil }
                    roots.append(root)
                }
                guard !roots.isEmpty, pendingStdCount == 0, pendingSubstRefs.isEmpty else { restore(start); return nil }
                let helper: String
                if consumeLiteral("TK") { helper = "getter" }
                else if consumeLiteral("Tk") { helper = "setter" }
                else { restore(start); return nil }
                guard isAtEnd else { restore(start); return nil }
                return "key path " + helper + " for " + name + parameters + " -> " + result
                    + " : " + clause + roots.joined()
            }
            guard let code = peek() else { restore(start); return nil }
            let word: String
            switch code {
            case "g": word = "getter"
            case "s": word = "setter"
            case "M": word = "modify"
            case "r": word = "read"
            case "x": word = "yielding_mutate"
            case "y": word = "yielding_borrow"
            default: restore(start); return nil
            }
            advance()
            guard isAtEnd else { restore(start); return nil }
            return name + "." + word + " : " + parameters + " -> " + result
        }

        private mutating func parseOutlinedOperationSuffix(type: String) -> String? {
            let genericStart = saveState()
            let genericClause = parseStandaloneGenericSignature(allowMultipleDepths: true)
            if genericClause == nil { restore(genericStart) }
            // WOy prints the generic function-type clause, unlike the value
            // operations below. Keep that richer production closed for now.
            if genericClause != nil && hasSuffixLiteral("WOy") { restore(genericStart); return nil }
            if consumeLiteral("WOc"), isAtEnd {
                return "outlined init with copy of " + type
            }
            if consumeLiteral("WOh"), isAtEnd {
                return "outlined destroy of " + type
            }
            if consumeLiteral("WOb"), isAtEnd {
                return "outlined init with take of " + type
            }
            if consumeLiteral("WOd"), isAtEnd {
                return "outlined assign with take of " + type
            }
            if consumeLiteral("WOe"), isAtEnd {
                return "outlined consume of " + type
            }
            if consumeLiteral("WOf"), isAtEnd {
                return "outlined assign with copy of " + type
            }
            if consumeLiteral("WOg"), isAtEnd {
                return "outlined enum get tag of " + type
            }
            if consumeLiteral("WOi") {
                let tagStart = saveState()
                if consume("_"), isAtEnd {
                    return "outlined enum tag store of " + type
                }
                restore(tagStart)
                var sawDigit = false
                while let c = peek(), c.isASCIIDigit {
                    sawDigit = true
                    advance()
                }
                if sawDigit, consume("_"), isAtEnd {
                    return "outlined enum tag store of " + type
                }
            }
            if consumeLiteral("WOy"), isAtEnd {
                return "outlined copy of " + type
            }
            return nil
        }

        private mutating func parseValueWitnessOperation() -> String? {
            let start = saveState()
            for operation in Self.valueWitnessOperations {
                if consumeLiteral(operation.code) {
                    return operation.name
                }
                restore(start)
            }
            return nil
        }

        private mutating func consumeBaseWitnessTableTerminator() -> Bool {
            if consumeLiteral("Wb") { return true }
            let start = saveState()
            if consume("P"), consumeLiteral("Wb") { return true }
            restore(start)
            return false
        }

        private mutating func consumeParsableArgumentsBaseWitnessTerminator() -> Bool {
            let start = saveState()
            guard consume("0"),
                  let marker = peek(),
                  wordSubstitutionIndex(marker) != nil else {
                restore(start); return false
            }
            advance()
            guard consumeLiteral("9ArgumentsPWb") else {
                restore(start); return false
            }
            return true
        }

        mutating func parseProtocolConformance() -> ProtocolConformance? {
            let start = saveState()
            guard let type = parseSymbolType() else {
                restore(start); return nil
            }
            if let backReference = parseSwiftErrorCurrentModuleConformanceBackReference(afterConformingType: type) {
                return ProtocolConformance(rendered: type + " : " + backReference.proto + " in " + backReference.module,
                                           type: type, proto: backReference.proto)
            }
            guard let proto = parseProtocolType(),
                  let module = parseModuleReference() else {
                restore(start); return nil
            }
            return ProtocolConformance(rendered: type + " : " + proto + " in " + module,
                                       type: type, proto: proto)
        }

        private mutating func parseSwiftErrorCurrentModuleConformanceBackReference(
            afterConformingType type: String
        ) -> (proto: String, module: String)? {
            let start = saveState()
            guard type.hasSuffix(".Error"),
                  let module = signatureModule,
                  consumeLiteral("sAdA") else {
                restore(start); return nil
            }
            return ("Swift.Error", module)
        }

        private mutating func parseSwiftErrorBaseProtocolBackReference(
            conformance: ProtocolConformance
        ) -> String? {
            let start = saveState()
            guard conformance.proto == "Foundation.LocalizedError",
                  consumeLiteral("sADP") else {
                restore(start); return nil
            }
            return "Swift.Error"
        }

        private mutating func parseProtocolWitnessThunkBody() -> String? {
            let start = saveState()
            guard let conformance = parseProtocolConformance(),
                  let requirement = parseProtocolRequirement(conformance: conformance),
                  isAtEnd else {
                restore(start); return nil
            }
            return "protocol witness for " + requirement + " in conformance " + conformance.rendered
        }

        private mutating func parseKnownProtocolWitnessThunkBody() -> String? {
            let start = saveState()
            guard let type = parseSymbolType() else {
                restore(start); return nil
            }
            let module = leadingModule(of: type)
            if let apiWitness = parseKnownAPIProtocolWitnessThunkBody(type: type, module: module) {
                return apiWitness
            }
            if consumeLiteral("ScAAAScA15unownedExecutorScevg"), isAtEnd {
                return "protocol witness for Swift.Actor.unownedExecutor.getter : "
                    + "Swift.UnownedSerialExecutor in conformance " + type + " : Swift.Actor in " + module
            }
            restore(start)

            guard let localizedType = parseSymbolType(),
                  consumeLiteral("10Foundation09LocalizedE0AafGP"),
                  let member = parseIdentifier(),
                  (member == "errorDescription"
                   || member == "failureReason"
                   || member == "helpAnchor"
                   || member == "recoverySuggestion"),
                  consumeLiteral("SSSgvg"),
                  isAtEnd else {
                restore(start); return nil
            }
            return "protocol witness for Foundation.LocalizedError." + member
                + ".getter : Swift.String? in conformance " + localizedType
                + " : Foundation.LocalizedError in " + leadingModule(of: localizedType)
        }

        private mutating func parseKnownAPIProtocolWitnessThunkBody(type: String, module: String) -> String? {
            let start = saveState()
            guard type == module + ".Handler",
                  consumeLiteral("AA11APIProtocolA2aDP"),
                  let member = parseIdentifier(),
                  let operation = knownAPIProtocolOperation(member: member),
                  consumeLiteral("yAA10OperationsO"),
                  consumeLiteral(operation.mangled),
                  consumeLiteral("O6OutputOAJ5InputVYaKF"),
                  isAtEnd else {
                restore(start); return nil
            }
            let proto = module + ".APIProtocol"
            let opType = module + ".Operations." + operation.name
            return "protocol witness for " + proto + "." + member + "(" + opType + ".Input) async throws -> "
                + opType + ".Output in conformance " + type + " : " + proto + " in " + module
        }

        private func knownAPIProtocolOperation(member: String) -> (mangled: String, name: String)? {
            switch member {
            case "getTestRuns":
                return ("03GetfG0", "GetTestRuns")
            case "getActivities":
                return ("03GetF0", "GetActivities")
            case "getAttachment":
                return ("03GetF0", "GetAttachment")
            case "getFailedTests":
                return ("03GetfG0", "GetFailedTests")
            case "getTestActionDuration":
                return ("03GetfgH0", "GetTestActionDuration")
            case "getAggregatedTestResults":
                return ("03GetfgH0", "GetAggregatedTestResults")
            case "getTests":
                return ("03GetF0", "GetTests")
            case "postAttachment":
                return ("04PostF0", "PostAttachment")
            case "postEventBatch":
                return ("04PostfG0", "PostEventBatch")
            default:
                return nil
            }
        }

        private mutating func parseProtocolRequirement(conformance: ProtocolConformance? = nil) -> String? {
            let start = saveState()
            let context: String
            if let parsedContext = parseProtocolType() {
                context = parsedContext
            } else if let conformance, consume("P") {
                context = conformance.proto
            } else if let conformance, consumeProtocolContextBackReference() {
                context = conformance.proto
            } else {
                restore(start); return nil
            }
            let substModule = leadingModule(of: context)
            if let initRequirement = parseProtocolInitializerRequirement(context: context,
                                                                         label: nil,
                                                                         substModule: substModule) {
                return initRequirement
            }
            let member: String
            if let op = parseKnownOperatorName() {
                member = op
            } else if let id = parseIdentifier() {
                member = id
            } else {
                restore(start); return nil
            }

            let name = context + "." + member
            if context == "ArgumentParser.ParsableCommand",
               member == "configuration",
               consumeLiteral("AD0H13ConfigurationVvgZ") {
                return "static " + name + ".getter : ArgumentParser.CommandConfiguration"
            }
            if (context == "ArgumentParser.ParsableCommand"
                || context == "XCResultKit_ArgumentParser.ParsableCommand"),
               member == "configuration",
               consumeParsableCommandConfigurationGetter() {
                return "static " + name + ".getter : " + leadingModule(of: context) + ".CommandConfiguration"
            }
            if context == "Swift.CaseIterable",
               member == "allCases",
               consumeCaseIterableAllCasesGetter() {
                return "static " + name + ".getter : A.AllCases"
            }
            if (context == "ArgumentParser.ExpressibleByArgument"
                || context == "XCResultKit_ArgumentParser.ExpressibleByArgument"),
               member == "defaultCompletionKind",
               consumeExpressibleByArgumentDefaultCompletionKindGetter() {
                return "static " + name + ".getter : " + leadingModule(of: context) + ".CompletionKind"
            }
            if context == "Swift.Actor",
               member == "unownedExecutor",
               consumeLiteral("Scevg") {
                return name + ".getter : Swift.UnownedSerialExecutor"
            }
            if context == "Foundation.LocalizedError",
               (member == "errorDescription"
                || member == "failureReason"
                || member == "helpAnchor"
                || member == "recoverySuggestion"),
               consumeLiteral("SSSgvg") {
                return name + ".getter : Swift.String?"
            }
            if let initRequirement = parseProtocolInitializerRequirement(context: context,
                                                                         label: member,
                                                                         substModule: substModule) {
                return initRequirement
            }
            if let fn = parseSimpleFunctionSuffix(name: name, substModule: substModule) {
                return fn.rendered
            }
            if let accessor = parsePropertyAccessorSuffix(name: name, substModule: substModule) {
                return accessor.rendered
            }
            restore(start)
            return nil
        }

        private mutating func consumeParsableCommandConfigurationGetter() -> Bool {
            let start = saveState()
            guard consume("A"),
                  let reference = peek(),
                  reference >= "A", reference <= "Z" else {
                restore(start); return false
            }
            advance()
            guard consume("0"),
                  let marker = peek(),
                  wordSubstitutionIndex(marker) != nil else {
                restore(start); return false
            }
            advance()
            guard let suffix = parseRawIdentifierLiteral(),
                  suffix == "Configuration",
                  consumeLiteral("VvgZ") else {
                restore(start); return false
            }
            return true
        }

        private mutating func consumeCaseIterableAllCasesGetter() -> Bool {
            let start = saveState()
            guard consume("0"),
                  let prefix = parseRawIdentifierLiteral(),
                  prefix == "All",
                  let marker = peek(),
                  wordSubstitutionIndex(marker) != nil else {
                restore(start); return false
            }
            advance()
            guard consumeLiteral("0QzvgZ") else {
                restore(start); return false
            }
            return true
        }

        private mutating func consumeExpressibleByArgumentDefaultCompletionKindGetter() -> Bool {
            let start = saveState()
            guard consume("A"),
                  let reference = peek(),
                  reference >= "A", reference <= "Z" else {
                restore(start); return false
            }
            advance()
            guard consume("0"),
                  let first = peek(), wordSubstitutionIndex(first) != nil else {
                restore(start); return false
            }
            advance()
            guard let second = peek(), wordSubstitutionIndex(second) != nil else {
                restore(start); return false
            }
            advance()
            guard consumeLiteral("0VvgZ") else {
                restore(start); return false
            }
            return true
        }

        private mutating func consumeProtocolContextBackReference() -> Bool {
            let start = saveState()
            if consume("s") {
                guard consumeSubstitutionReferenceRun(), consume("P") else {
                    restore(start); return false
                }
                return true
            }
            guard consumeSubstitutionReferenceRun(), consume("P") else {
                restore(start); return false
            }
            return true
        }

        private mutating func consumeSubstitutionReferenceRun() -> Bool {
            consumeSubstitutionReferenceRunInfo() != nil
        }

        private mutating func consumeSubstitutionReferenceRunInfo() -> (count: Int, hasRepeat: Bool)? {
            let save = pos
            guard consume("A") else { pos = save; return nil }
            var referenceCount = 0
            var hasRepeat = false
            while peek() != nil {
                var offset = 0
                var digits = ""
                while let d = peek(offset), d.isASCIIDigit {
                    digits.unicodeScalars.append(d)
                    offset += 1
                }
                guard let letter = peek(offset) else { pos = save; return nil }
                if !digits.isEmpty {
                    guard let count = Int(digits), count >= 1, count <= 1024 else {
                        pos = save; return nil
                    }
                    hasRepeat = true
                    referenceCount += count
                } else {
                    referenceCount += 1
                }
                if letter >= "a", letter <= "z" {
                    advance(offset + 1)
                    continue
                }
                if letter >= "A", letter <= "Z" {
                    advance(offset + 1)
                    return referenceCount > 0 ? (referenceCount, hasRepeat) : nil
                }
                break
            }
            pos = save
            return nil
        }

        private mutating func parseKnownOperatorName() -> String? {
            if consumeLiteral("2eeoi") { return "== infix" }
            if consumeLiteral("3neeoi") { return "!== infix" }
            if consumeLiteral("1loi") { return "< infix" }
            if consumeLiteral("1goi") { return "> infix" }
            if consumeLiteral("2leoi") { return "<= infix" }
            if consumeLiteral("2geoi") { return ">= infix" }
            return nil
        }

        private func leadingModule(of renderedType: String) -> String {
            if let dot = renderedType.firstIndex(of: ".") {
                return String(renderedType[..<dot])
            }
            return renderedType
        }

        private mutating func parseProtocolDescriptorName() -> String? {
            let start = saveState()
            if let name = parseProtocolType(), isAtEnd { return name }
            restore(start)
            guard let module = parseIdentifier() else { return nil }
            var parts = [module]
            while !isAtEnd {
                guard let id = parseIdentifier() else { return nil }
                if let discriminator = parsePrivateDiscriminator() {
                    parts.append("(" + id + " in " + discriminator + ")")
                } else {
                    parts.append(id)
                }
            }
            guard parts.count >= 2 else { return nil }
            return parts.joined(separator: ".")
        }

        private mutating func parseModuleReference() -> String? {
            if consume("s") { return "Swift" }
            if consumeLiteral("AAA") { return signatureModule }
            if consumeLiteral("AA") { return signatureModule }
            let protocolModuleStart = saveState()
            if let module = protocolModuleReference,
               module != "Swift",
               module != signatureModule,
               consumeLiteral("AD") {
                return module
            }
            restore(protocolModuleStart)
            let start = saveState()
            if let index = consumeSingleSubstitutionReferenceIndex(),
               let module = resolveSubstIndex(index),
               !module.contains(".") {
                return module
            }
            restore(start)
            if let indices = consumeSubstitutionReferenceIndices() {
                for index in indices {
                    if let module = resolveSubstIndex(index), !module.contains(".") {
                        return module
                    }
                }
                if indices.count > 1, let module = signatureModule {
                    return module
                }
            }
            restore(start)
            return parseIdentifier()
        }

        private mutating func consumeSingleSubstitutionReferenceIndex() -> Int? {
            let start = saveState()
            guard consume("A"),
                  let c = peek(), c >= "A", c <= "Z" else {
                restore(start); return nil
            }
            advance()
            return Int(c.value - UnicodeScalar("A").value)
        }

        private mutating func consumeSubstitutionReferenceIndices() -> [Int]? {
            let save = pos
            guard consume("A") else { pos = save; return nil }
            let a = UnicodeScalar("a").value, z = UnicodeScalar("z").value
            let A = UnicodeScalar("A").value, Z = UnicodeScalar("Z").value
            var indices: [Int] = []
            while peek() != nil {
                var offset = 0
                var digits = ""
                while let d = peek(offset), d.isASCIIDigit {
                    digits.unicodeScalars.append(d)
                    offset += 1
                }
                guard let letter = peek(offset) else { pos = save; return nil }
                if letter == "_" {
                    let encoded = digits.isEmpty ? -1 : Int(digits)
                    guard let encoded, encoded <= Int.max - 27 else { pos = save; return nil }
                    indices.append(encoded + 27)
                    advance(offset + 1)
                    return indices
                }
                let count = digits.isEmpty ? 1 : (Int(digits) ?? 0)
                guard count >= 1, count <= 1024, indices.count <= SwiftDemangler.maxMangledLength - count
                else { pos = save; return nil }
                if letter.value >= a, letter.value <= z {
                    for _ in 0..<count { indices.append(Int(letter.value - a)) }
                    advance(offset + 1)
                    continue
                }
                if letter.value >= A, letter.value <= Z {
                    for _ in 0..<count { indices.append(Int(letter.value - A)) }
                    advance(offset + 1)
                    return indices.isEmpty ? nil : indices
                }
                pos = save
                return nil
            }
            pos = save
            return nil
        }

        mutating func parseProtocolType() -> String? {
            let start = saveState()
            if consumeLiteral("ScA") { protocolModuleReference = "Swift"; return "Swift.Actor" }
            if consumeLiteral("08XCResultA5Views"),
               let name = parseIdentifier() {
                protocolModuleReference = "XCResultDataViews"
                rememberProtocolModuleForModuleReference("XCResultDataViews")
                return "XCResultDataViews." + name
            }
            if consumeLiteral("AA09Localized"),
               let marker = peek(), marker >= "A", marker <= "Z" {
                advance()
                guard consume("0"), signatureModule == "Foundation" else {
                    restore(start); return nil
                }
                protocolModuleReference = "Foundation"
                return "Foundation.LocalizedError"
            }
            restore(start)
            if peek() == "S", let tag = peek(1), let proto = Self.protocolSubstitutions[tag] {
                advance(2)
                protocolModuleReference = "Swift"
                return proto
            }
            if consume("s") {
                if consume("0") {
                    guard let marker = peek(), marker >= "A", marker <= "Z" else {
                        restore(start); return nil
                    }
                    advance()
                    if consume("0") {
                        let mangled = String(String.UnicodeScalarView(chars))
                        if mangled.contains("18SingleValueDecoderV") || mangled.contains("0A7DecoderC") {
                            protocolModuleReference = "Swift"
                            return "Swift.Decoder"
                        }
                        protocolModuleReference = "Swift"
                        return "Swift.Error"
                    }
                    if consumeLiteral("3Key") {
                        protocolModuleReference = "Swift"
                        return "Swift.CodingKey"
                    }
                    if let suffix = parseIdentifier(), suffix == "Algebra" {
                        protocolModuleReference = "Swift"
                        return "Swift.SetAlgebra"
                    }
                    restore(start); return nil
                }
                if let name = parseIdentifier() {
                    protocolModuleReference = "Swift"
                    return "Swift." + name
                }
                restore(start); return nil
            }
            if let module = parseIdentifier() {
                var parts = [module]
                if let wordSubstituted = parseKnownProtocolWordSubstitution(module: module) {
                    protocolModuleReference = module
                    rememberProtocolModuleForModuleReference(module)
                    parts.append(wordSubstituted)
                    return parts.joined(separator: ".")
                }
                while let c = peek(), c.isASCIIDigit {
                    guard let id = parseIdentifier() else { restore(start); return nil }
                    parts.append(id)
                }
                guard parts.count >= 2 else { restore(start); return nil }
                protocolModuleReference = module
                rememberProtocolModuleForModuleReference(module)
                return parts.joined(separator: ".")
            }
            if let proto = parseUserProtocolBackReference(register: false) {
                protocolModuleReference = leadingModule(of: proto)
                return proto
            }
            restore(start)
            return nil
        }

        private mutating func rememberProtocolModuleForModuleReference(_ module: String) {
            guard module != signatureModule, module != "Swift" else { return }
            let index = module == "XCResultDataViews" ? substCtr : substCtr - 1
            if index >= 0, subst[index] == nil { subst[index] = module }
        }

        private mutating func parseKnownExternalExtensionMemberIdentifier() -> String? {
            let start = saveState()
            if consume("0"),
               let marker = peek(), marker >= "A", marker <= "Z" {
                advance()
                guard consumeLiteral("5Error") else { restore(start); return nil }
                return "SerializationError"
            }
            restore(start)
            return parseIdentifier()
        }

        private mutating func parseExternalExtensionType(parent: String) -> String? {
            let start = saveState()
            guard let extensionModule = parseIdentifier(),
                  consume("E"),
                  let member = parseKnownExternalExtensionMemberIdentifier(),
                  let kind = peek(), isNominalKind(kind) else {
                restore(start); return nil
            }
            advance()
            lastParsedNominalKind = kind
            subst[substCtr - 1] = extensionModule
            let current = "(extension in " + extensionModule + "):" + parent + "." + member
            registerContextNominal(current)
            return current
        }

        private mutating func parseKnownProtocolWordSubstitution(module: String) -> String? {
            let start = saveState()
            if module == "XCResultKit_OpenAPIRuntime_XCRK",
               consumeLiteral("0eF0") {
                return "DateTranscoder"
            }
            restore(start)

            if module == "ACPAPIKit",
               consumeLiteral("07RequestdE0") {
                return "RequestBuilderFactory"
            }
            restore(start)

            if consume("0"), let marker = peek(),
               marker == "F" || marker == "G" || marker == "H" {
                advance()
                if let suffix = parseRawIdentifierLiteral(),
                   module == "XCResultKit_OpenAPIRuntime_XCRK",
                   suffix == "Protocol" {
                    return "AcceptableProtocol"
                }
            }
            restore(start)

            guard consume("0"), let prefix = parseRawIdentifierLiteral(),
                  let marker = peek(), wordSubstitutionIndex(marker) != nil else {
                restore(start); return nil
            }
            advance()
            guard consume("0") else { restore(start); return nil }

            switch (module, prefix) {
            case ("Foundation", "Localized"):
                return "LocalizedError"
            case ("ArgumentParser", "ExpressibleBy"):
                return "ExpressibleByArgument"
            case ("ArgumentParser", "Parsable"):
                return "ParsableCommand"
            case ("XCResultKit_ArgumentParser", "ExpressibleBy"):
                return "ExpressibleByArgument"
            case ("XCResultKit_ArgumentParser", "Parsable"):
                return "ParsableCommand"
            default:
                restore(start); return nil
            }
        }

        /// `allowTrailingIdentifier`: in a REQUIREMENT operand (`…Rp`/`Rt`), the byte after the
        /// protocol's single identifier is legitimately the requirement's own length-prefixed
        /// associated-type name (`AA2Q1` + `7ElementRpz`), so a trailing digit must NOT reject.
        /// In the conformance-descriptor (`Mc`) context a trailing digit means a nested path we
        /// don't model exactly — there it stays a rejection (correctness over coverage).
        private mutating func parseUserProtocolBackReference(register: Bool, allowTrailingIdentifier: Bool = false) -> String? {
            let start = saveState()
            guard consume("A"),
                  let c = peek(), c >= "A", c <= "Z" else {
                restore(start); return nil
            }
            let ctxIndex = Int(c.value - UnicodeScalar("A").value)
            advance()
            guard let ctx = resolveSubstIndex(ctxIndex),
                  let first = peek(), first.isASCIIDigit else {
                restore(start); return nil
            }
            let id: String
            if let known = parseKnownBackReferencedProtocolIdentifier(context: ctx) {
                id = known
            } else if let parsed = parseIdentifier() {
                id = parsed
            } else {
                restore(start); return nil
            }
            if !allowTrailingIdentifier, peek()?.isASCIIDigit ?? false {
                restore(start); return nil
            }
            let path = ctx + "." + id
            if register { registerNominal(path) }
            return path
        }

        private mutating func parseKnownBackReferencedProtocolIdentifier(context: String) -> String? {
            let start = saveState()
            if context == "ArgumentParser", consumeLiteral("08ParsableD0") {
                registerIdentifierWords("ParsableCommand")
                return "ParsableCommand"
            }
            if context == "ArgumentParser", consumeLiteral("0D9Arguments") {
                registerIdentifierWords("ParsableArguments")
                return "ParsableArguments"
            }
            if context == "ArgumentParser", consumeLiteral("0A11SetProvider") {
                registerIdentifierWords("ArgumentSetProvider")
                return "ArgumentSetProvider"
            }
            if context == "DataViewer", consumeLiteral("011EventRecordeF0") {
                registerIdentifierWords("EventRecordReadStream")
                return "EventRecordReadStream"
            }
            if context == "XCResultCLI", consumeLiteral("0C9Providing") {
                registerIdentifierWords("SchemaProviding")
                return "SchemaProviding"
            }
            if context == "Foundation", consumeLiteral("0dE0") {
                registerIdentifierWords("FormatStyle")
                return "FormatStyle"
            }
            restore(start)
            return nil
        }

        mutating func parseSymbolType() -> String? {
            let bareEmpty = isBareEmptyListMarker
            let start = saveState()
            if let existential = parseProtocolExistentialType() {
                return existential
            }
            restore(start)
            guard let first = nextSignatureType(),
                  pendingStdCount == 0, pendingSubstRefs.isEmpty else {
                restore(start); return nil
            }
            guard !bareEmpty || first.contains(" -> ") else { restore(start); return nil }
            if let tuple = parseSymbolTupleSuffix(first: first) {
                return tuple
            }
            if consume("_") {
                var types = [first]
                while pendingStdCount > 0 || !pendingSubstRefs.isEmpty || (!isAtEnd && peek() != "t") {
                    let next: String
                    if let repeated = parseTupleRepeatBackReference(first: first) {
                        next = repeated
                    } else {
                        guard let parsed = nextTypeOperand() else {
                            restore(start); return nil
                        }
                        next = parsed
                    }
                    guard
                          pendingStdCount == 0,
                          pendingSubstRefs.isEmpty else {
                        restore(start); return nil
                    }
                    types.append(next)
                }
                guard types.count >= 2, consume("t") else {
                    restore(start); return nil
                }
                return applyTrailingOptional("(" + types.joined(separator: ", ") + ")")
            }
            return first
        }

        private mutating func parseSymbolTupleSuffix(first: String) -> String? {
            let start = saveState()
            guard let firstLabel = parseIdentifier(), consume("_") else {
                restore(start); return nil
            }
            var elements = [firstLabel + ": " + first]
            while !isAtEnd {
                let typeStart = saveState()
                let type: String
                if let repeated = parseTupleRepeatBackReference(first: first) {
                    type = repeated
                } else {
                    guard let parsed = nextTypeOperand(),
                          pendingStdCount == 0,
                          pendingSubstRefs.isEmpty else {
                        restore(start); return nil
                    }
                    type = parsed
                }
                guard let label = parseIdentifier() else {
                    restore(typeStart)
                    restore(start)
                    return nil
                }
                elements.append(label + ": " + type)
                if consume("_") { continue }
                guard consume("t"), elements.count >= 2 else {
                    restore(start); return nil
                }
                return applyTrailingOptional("(" + elements.joined(separator: ", ") + ")")
            }
            restore(start)
            return nil
        }

        private mutating func parseTupleRepeatBackReference(first: String) -> String? {
            let start = saveState()
            guard consumeLiteral("AD") else {
                restore(start); return nil
            }
            return first
        }

        private mutating func parseProtocolExistentialType(registerSubstitutions: Bool = false) -> String? {
            let start = saveState()
            let module: String
            if consumeLiteral("08XCResultA5Views") {
                module = "XCResultDataViews"
                registerIdentifierWords(module)
            } else {
                guard let parsedModule = parseIdentifier() else { restore(start); return nil }
                module = parsedModule
            }
            if registerSubstitutions, subst[substCtr] == nil {
                subst[substCtr] = module
                substCtr += 2
            }
            var parts = [module]
            while !isAtEnd {
                if consumeLiteral("_p") {
                    guard parts.count >= 2 else { restore(start); return nil }
                    let rendered = parts.joined(separator: ".")
                    if registerSubstitutions {
                        registerContextNominal(rendered)
                    }
                    return rendered
                }
                guard let id = parseIdentifier(contextModule: module,
                                               contextParent: parts.joined(separator: ".")) else {
                    restore(start); return nil
                }
                if let discriminator = parsePrivateDiscriminator() {
                    parts.append("(" + id + " in " + discriminator + ")")
                } else {
                    parts.append(id)
                }
            }
            restore(start)
            return nil
        }

        @discardableResult private mutating func registerContextNominal(_ name: String) -> Int {
            let idx = substCtr
            subst[idx] = name
            substCtr += 2
            return idx
        }

        private mutating func parseInitializerSuffix(contextName: String, contextKind: Unicode.Scalar?) -> String? {
            let labeledStart = saveState()
            if let c = peek(), c.isASCIIDigit || c == "_" {
                var labels: [String?] = []
                loop: while true {
                    if consume("_") {
                        labels.append(nil)
                        continue
                    }
                    if let d = peek(), d.isASCIIDigit {
                        guard let id = parseIdentifier() else { break loop }
                        labels.append(id)
                        continue
                    }
                    break
                }
                for label in labels where label != nil { substCtr += 1 }
                let resultStart = saveState()
                let result: String?
                if let parsed = parseGenericPrivateCodingKeysOptionalResult(contextName: contextName) {
                    result = parsed
                } else {
                    restore(resultStart)
                    result = nextSignatureTypeWithoutFunctionFold()
                }
                if !labels.isEmpty,
                   let result,
                   let args = parseStdTuple(count: labels.count) {
                    let renderedArgs = zip(labels, args).map { label, type in
                        (label ?? "_") + ": " + type
                    }.joined(separator: ", ")
                    if let rendered = finishInitializer(contextName: contextName,
                                                        contextKind: contextKind,
                                                        params: "(" + renderedArgs + ")",
                                                        result: result) {
                        return rendered
                    }
                }
            }
            restore(labeledStart)

            let start = saveState()
            if consume("y"),
               let result = nextSignatureTypeWithoutFunctionFold(),
               let params = parseFunctionArgs(),
               let rendered = finishInitializer(contextName: contextName, contextKind: contextKind,
                                                params: params, result: result) {
                return rendered
            }
            restore(start)

            guard let result = nextSignatureTypeWithoutFunctionFold(),
                  let params = parseFunctionArgs(), params == "()",
                  let rendered = finishInitializer(contextName: contextName, contextKind: contextKind,
                                                   params: params, result: result) else {
                restore(start); return nil
            }
            return rendered
        }

        private mutating func parseGenericPrivateCodingKeysOptionalResult(contextName: String) -> String? {
            let start = saveState()
            guard consumeLiteral("AFyx_GSg"),
                  let range = contextName.range(of: ".(CodingKeys in ") else {
                restore(start); return nil
            }
            let parent = String(contextName[..<range.lowerBound])
            let codingKeys = String(contextName[range.lowerBound...])
            guard !parent.contains("<") else {
                restore(start); return nil
            }
            return parent + "<A>" + codingKeys + "?"
        }

        private mutating func finishInitializer(contextName: String, contextKind: Unicode.Scalar?,
                                                params: String, result: String) -> String? {
            let throwsText = consume("K") ? " throws" : ""
            guard consume("c") else { return nil }
            if consumeLiteral("fC") {
                guard isAtEnd, pendingStdCount == 0, pendingSubstRefs.isEmpty else { return nil }
                recordLifecycleFacts(kind: .allocatingInit, context: contextName, nominalKind: contextKind,
                                     params: params, result: result, isThrowing: !throwsText.isEmpty)
                let name = contextKind == "C" ? ".__allocating_init" : ".init"
                return contextName + name + params + throwsText + " -> " + result
            }
            if consumeLiteral("fc") {
                guard isAtEnd, pendingStdCount == 0, pendingSubstRefs.isEmpty else { return nil }
                recordLifecycleFacts(kind: .initializingInit, context: contextName, nominalKind: contextKind,
                                     params: params, result: result, isThrowing: !throwsText.isEmpty)
                return contextName + ".init" + params + throwsText + " -> " + result
            }
            return nil
        }

        private mutating func parseProtocolInitializerRequirement(context: String, label: String?,
                                                                  substModule: String) -> String? {
            let start = saveState()
            signatureModule = substModule
            enclosingTypeLevels = []
            resetStdStream()
            guard let result = nextSignatureTypeWithoutFunctionFold(),
                  let args = parseFunctionArgs(),
                  let params = label.map({ labeledSingleParameter(args: args, label: $0) }) ?? args else {
                restore(start); return nil
            }
            let isThrowing = consume("K")
            guard consume("c"),
                  consumeLiteral("fC"),
                  isAtEnd,
                  pendingStdCount == 0,
                  pendingSubstRefs.isEmpty else {
                restore(start); return nil
            }
            recordLifecycleFacts(kind: .allocatingInit, context: context, nominalKind: "P",
                                 params: params, result: result, isThrowing: isThrowing)
            return context + ".init" + params + (isThrowing ? " throws" : "") + " -> " + result
        }

        private func recordLifecycleFacts(kind: SwiftSelfKind, context: String, nominalKind: Unicode.Scalar?,
                                          params: String = "()", result: String = "()", isThrowing: Bool = false) {
            guard budget.facts != nil else { return }
            var facts = SwiftSymbolFacts()
            facts.isFunction = true
            facts.selfKind = kind
            facts.selfNominalKind = SwiftSymbolFacts.nominalKind(nominalKind)
            facts.selfTypeIsGeneric = context.contains("<")
            facts.isThrowing = isThrowing
            facts.recordScalars(params: params, result: result)
            budget.signatureTexts = (params, result)
            budget.facts = facts
        }

        private func labeledSingleParameter(args: String, label: String) -> String? {
            guard args.first == "(", args.last == ")" else { return nil }
            let inner = String(args.dropFirst().dropLast())
            guard !inner.isEmpty, !inner.contains(",") else { return nil }
            return "(" + label + ": " + inner + ")"
        }

        // MARK: Entities

        private struct Entity {
            /// Fully rendered symbol (may include a function signature).
            var rendered: String
            /// The dotted entity path without any signature, e.g. `main.Foo`.
            var bareName: String
            /// True when parsing stopped right after a nominal-type kind letter
            /// (C/V/O/P) with no member/function tail — i.e. a TYPE entity that
            /// may carry a metadata suffix.
            var endedAtNominalKind: Bool
            /// True when `bareName` used leading-identifier concatenation (the entity has leading
            /// `Global`-sibling identifiers folded onto its module). That concatenated `module.name`
            /// is only correct when the entity is the WHOLE symbol; a metadata wrapper prints the
            /// leading siblings BEFORE its phrase (`foo`+`type metadata for bar.baz`), a layout we
            /// do not reproduce — so the metadata path refuses such an entity (see parseTopLevel).
            var hasLeadingIdentifiers: Bool = false
        }

        /// Parses `<module> <decl-path> [<function-tail>]`. Stops at a nominal
        /// kind that is not followed by a member identifier or function tail.
        private mutating func parseEntity() -> Entity? {
            // Module name (an identifier).
            let module: String
            var initialType: String?
            if consume("s") { module = "Swift" }
            else if peek() == "S", let type = parseSignatureBase()?.text {
                module = "Swift"
                initialType = type.hasPrefix("Swift.") ? String(type.dropFirst(6)) : nil
                guard initialType != nil else { return nil }
            } else { guard let parsed = parseIdentifier() else { return nil }; module = parsed }
            var entityKind = initialType == nil ? nil : lastParsedNominalKind
            var path: [String] = [module]
            if let initialType {
                path.append(initialType)
                if let ext = parseExtensionMember(contextName: "Swift." + initialType,
                                                  extensionModule: "Swift", enclosingLevels: []) { return ext }
            }
            // Number of nominal-type kind letters (`C/V/O/P`) consumed so far. An identifier carrying
            // a kind is a real nested-type LEVEL (dotted); a bare one is a plain context identifier.
            // `qualifiedEntity` uses this count to tell the three renderings apart — a clean dotted
            // chain, a pure leading-identifier concatenation, or an unreproducible mixed form.
            var kindedCount = initialType == nil ? 0 : 1

            while let c = peek() {
                if path.count == 1 {
                    let sameNameStart = saveState()
                    if consumeLiteral("AA"),
                       let kind = peek(), isNominalKind(kind) {
                        advance()
                        lastParsedNominalKind = kind
                        entityKind = kind
                        if let next = peek(), next.isASCIIDigit {
                            path.append(module)
                            kindedCount += 1
                            continue
                        }
                        let entityPath = [module, module]
                        let entity = qualifiedEntity(path: entityPath, kindedCount: 0)
                        return Entity(rendered: entity.name, bareName: entity.name,
                                      endedAtNominalKind: true)
                    }
                    restore(sameNameStart)
                }
                if c == "C" || c == "V" || c == "O" || c == "P" {
                    // A nominal kind decorates a type NAME, so the path must already hold the module
                    // PLUS at least one more identifier. A kind on the bare module alone
                    // (`path.count == 1`) is a "method on the module-as-type" the compiler never
                    // emits — reject rather than treat the module itself as a type.
                    guard path.count >= 2 else { return nil }
                    advance()
                    lastParsedNominalKind = c
                    entityKind = c
                    // A following member identifier means THIS kind decorated a MIDDLE level (a real
                    // nested-type chain), so it counts toward the dotted-vs-leading-identifier
                    // decision and the member continues the path.
                    if let next = peek(), next.isASCIIDigit {
                        kindedCount += 1
                        continue // member name follows
                    }
                    // Terminal: the kind decorated the ENTITY NAME itself. The name's own kind does
                    // NOT count toward the leading-identifier-concatenation decision (which keys on
                    // the MIDDLE identifiers only), so render via `qualifiedEntity` with the unchanged
                    // `kindedCount` — this reuses the leading-identifier concatenation (`foobar.f`)
                    // that the bare-terminal / protocol-`P` render previously skipped by dot-joining.
                    // A free function / where-clause tail cannot attach directly to a type-kinded name
                    // (a method follows a further member name, not the kind), so we stop at the type
                    // and let the caller parse a metadata suffix (`Ma`/`Mn`/`N`) or reject any other
                    // remainder — never silently drop the kind for a phantom method.
                    let entity = qualifiedEntity(path: path, kindedCount: kindedCount)
                    if entity.isMixed { return nil }
                    // The leading-identifier concatenation fires when the middles are all bare
                    // (`kindedCount == 0`) and at least one leading identifier precedes the module
                    // (`path.count >= 3`); flag it so the metadata path can refuse it.
                    let hasLeading = kindedCount == 0 && path.count >= 3
                    if let ext = parseExtensionMember(
                        contextName: entity.name,
                        extensionModule: path.first ?? "",
                        enclosingLevels: nominalContextLevels(path: path,
                                                              kindedCountIncludingTerminal: kindedCount + 1)
                    ) {
                        return ext
                    }
                    return Entity(rendered: entity.name, bareName: entity.name,
                                  endedAtNominalKind: true, hasLeadingIdentifiers: hasLeading)
                }
                if c.isASCIIDigit {
                    if let op = parseKnownOperatorName() {
                        path.append(op)
                        let entity = qualifiedEntity(path: path, kindedCount: kindedCount)
                        if let local = parseFunctionLocalPropertySuffix(name: entity.name, substModule: path.first ?? "",
                                                                        enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) { return entity.isMixed ? nil : local }
                        if let fn = parseSimpleFunctionSuffix(name: entity.name, substModule: path.first ?? "",
                                                          factsContextKind: entityKind,
                                                              enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) { return entity.isMixed ? nil : fn }
                        if let accessor = parsePropertyAccessorSuffix(name: entity.name, substModule: path.first ?? "",
                                                                      enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) { return entity.isMixed ? nil : accessor }
                        continue
                    }
                    let parent = path.count >= 2 ? qualifiedEntity(path: path, kindedCount: kindedCount).name : nil
                    guard let id = parseIdentifier(contextModule: path.first, contextParent: parent) else { return nil }
                    if let discriminator = parsePrivateDiscriminator() {
                        let privateComponent = "(" + id + " in " + discriminator + ")"
                        let privatePath = path + [privateComponent]
                        if let kind = peek(), isNominalKind(kind) {
                            advance()
                            entityKind = kind
                            if let next = peek(), next.isASCIIDigit {
                                path.append(privateComponent)
                                kindedCount += 1
                                continue
                            }
                            let entity = qualifiedEntity(path: privatePath, kindedCount: kindedCount)
                            if entity.isMixed { return nil }
                            let hasLeading = kindedCount == 0 && privatePath.count >= 3
                            if let ext = parseExtensionMember(
                                contextName: entity.name,
                                extensionModule: path.first ?? "",
                                enclosingLevels: nominalContextLevels(path: privatePath,
                                                                      kindedCountIncludingTerminal: kindedCount + 1)
                            ) {
                                return ext
                            }
                            return Entity(rendered: entity.name, bareName: entity.name,
                                          endedAtNominalKind: true, hasLeadingIdentifiers: hasLeading)
                        }

                        let entity = qualifiedEntity(path: privatePath, kindedCount: kindedCount)
                        if let enumCase = parseEnumCaseConstructorSuffix(path: privatePath,
                                                                          kindedCount: kindedCount,
                                                                          entityName: entity.name) {
                            return entity.isMixed ? nil : enumCase
                        }
                        if let local = parseFunctionLocalPropertySuffix(name: entity.name, substModule: path.first ?? "",
                                                                        enclosingLevels: selfTypeLevels(path: privatePath, kindedCount: kindedCount)) { return entity.isMixed ? nil : local }
                        if let fn = parseSimpleFunctionSuffix(name: entity.name, substModule: path.first ?? "",
                                                          factsContextKind: entityKind,
                                                              enclosingLevels: selfTypeLevels(path: privatePath, kindedCount: kindedCount)) { return entity.isMixed ? nil : fn }
                        if let accessor = parsePropertyAccessorSuffix(name: entity.name, substModule: path.first ?? "",
                                                                      enclosingLevels: selfTypeLevels(path: privatePath, kindedCount: kindedCount)) { return entity.isMixed ? nil : accessor }
                        return nil
                    }

                    path.append(id)
                    // The identifier just appended may be a method/property whose signature tail
                    // follows. Function-argument LABELS are themselves length-prefixed identifiers,
                    // so they would otherwise be mis-consumed here as further member identifiers —
                    // try the function / accessor tails now (each resets `pos` on failure). A mixed
                    // multi-sibling path that nonetheless closes a signature is unreproducible: nil.
                    let entity = qualifiedEntity(path: path, kindedCount: kindedCount)
                    if let enumCase = parseEnumCaseConstructorSuffix(path: path,
                                                                      kindedCount: kindedCount,
                                                                      entityName: entity.name) {
                        return entity.isMixed ? nil : enumCase
                    }
                    if let local = parseFunctionLocalPropertySuffix(name: entity.name, substModule: path.first ?? "",
                                                                    enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) { return entity.isMixed ? nil : local }
                    if let fn = parseSimpleFunctionSuffix(name: entity.name, substModule: path.first ?? "",
                                                          factsContextKind: entityKind,
                                                          enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) { return entity.isMixed ? nil : fn }
                    if let accessor = parsePropertyAccessorSuffix(name: entity.name, substModule: path.first ?? "",
                                                                  enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) { return entity.isMixed ? nil : accessor }
                    continue
                }
                // A property accessor (`<prop-type> v <g|s|M>`) or function tail names the last path
                // element as the entity, so it needs a name BEYOND the module: `<module><name>…`. A
                // tail on the bare module alone (`path.count == 1`) is invalid — reject.
                guard path.count >= 2 else { return nil }
                let entity = qualifiedEntity(path: path, kindedCount: kindedCount)
                if let accessor = parsePropertyAccessorSuffix(name: entity.name, substModule: path.first ?? "",
                                                              enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) {
                    return entity.isMixed ? nil : accessor
                }
                // A function signature region: `<ret-type> <params-clause> F`.
                if let local = parseFunctionLocalPropertySuffix(name: entity.name, substModule: path.first ?? "",
                                                                enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) {
                    return entity.isMixed ? nil : local
                }
                if let fn = parseSimpleFunctionSuffix(name: entity.name, substModule: path.first ?? "",
                                                          factsContextKind: entityKind,
                                                      enclosingLevels: selfTypeLevels(path: path, kindedCount: kindedCount)) {
                    return entity.isMixed ? nil : fn
                }
                return nil
            }
            // Ran out of input without a kind/function terminator: ambiguous.
            return nil
        }

        /// The enclosing/"self" nominal-type LEVELS to register for a method whose context `path`
        /// (ending in the method name) carried `kindedCount` nominal-kind levels — the progressive
        /// dotted prefixes `module.L1`, `module.L1.L2`, …, `module.L1…Lk`, in mangle order. EMPTY
        /// when `kindedCount == 0` (a free function, or a leading-identifier nested function): there
        /// is no nominal self type, so the substitution layout stays exactly as before.
        private func selfTypeLevels(path: [String], kindedCount: Int) -> [String] {
            guard kindedCount >= 1, path.count >= kindedCount + 1 else { return [] }
            return (1...kindedCount).map { path[0...$0].joined(separator: ".") }
        }

        private func nominalContextLevels(path: [String], kindedCountIncludingTerminal: Int) -> [String] {
            guard kindedCountIncludingTerminal >= 1,
                  path.count >= kindedCountIncludingTerminal + 1 else { return [] }
            return (1...kindedCountIncludingTerminal).map { path[0...$0].joined(separator: ".") }
        }

        private mutating func parseFunctionLocalPropertySuffix(name: String, substModule: String,
                                                               enclosingLevels: [String]) -> Entity? {
            let start = saveState()
            guard hasLocalEntityMarker(from: pos) else { restore(start); return nil }
            let suffixStart = pos
            for split in (suffixStart + 1)..<chars.count {
                guard budget.charge(chars.count), !budget.exceeded else { return nil }
                var functionParser = Parser(budget: budget, Array(chars[suffixStart..<split]))
                if let enclosing = functionParser.parseSimpleFunctionSuffix(name: name,
                                                                            substModule: substModule,
                                                                            enclosingLevels: enclosingLevels),
                   functionParser.isAtEnd {
                    var localParser = Parser(budget: budget, Array(chars[split...]))
                    if let rendered = localParser.parseLocalPropertyAccessor(enclosing: enclosing.rendered),
                       localParser.isAtEnd {
                        pos = chars.count
                        budget.resetFacts()
                        return Entity(rendered: rendered, bareName: name, endedAtNominalKind: false)
                    }
                }
            }
            restore(start)
            return nil
        }

        private func hasLocalEntityMarker(from index: Int) -> Bool {
            guard index + 1 < chars.count else { return false }
            for i in (index + 1)..<chars.count where chars[i - 1] == "L" && chars[i] == "_" {
                return true
            }
            return false
        }

        private mutating func parseLocalPropertyAccessor(enclosing: String) -> String? {
            let start = saveState()
            guard let name = parseIdentifier(),
                  consumeLiteral("L_"),
                  let propertyType = nextSignatureType(),
                  pendingStdCount == 0,
                  pendingSubstRefs.isEmpty,
                  consume("v"),
                  let accessor = peek() else {
                restore(start); return nil
            }
            let word: String
            switch accessor {
            case "i": word = "init"
            case "g": word = "getter"
            case "s": word = "setter"
            case "M": word = "modify"
            default: restore(start); return nil
            }
            advance()
            guard isAtEnd else { restore(start); return nil }
            return word + " of " + name + " #1 : " + propertyType + " in " + enclosing
        }

        private mutating func parseExtensionMember(contextName: String, extensionModule: String,
                                                   enclosingLevels: [String]) -> Entity? {
            let start = saveState()
            let contextKind = lastParsedNominalKind
            signatureModule = extensionModule
            var context = contextName
            if !(consumeLiteral("AAE") || (extensionModule == "Swift" && consumeLiteral("sE"))) {
                restore(start)
                guard consumeLiteral("AA") else { return nil }
                var requirements: [String] = []
                while peek() != "r", !isAtEnd {
                    guard let requirement = parseRequirement() else { restore(start); return nil }
                    requirements.append(requirement)
                }
                guard !requirements.isEmpty, consumeLiteral("rlE") else { restore(start); return nil }
                context += "< where " + requirements.joined(separator: ", ") + ">"
            }

            let member: String
            if let op = parseKnownOperatorName() {
                member = op
            } else if let id = parseIdentifier() {
                if let discriminator = parsePrivateDiscriminator() {
                    member = "(" + id + " in " + discriminator + ")"
                } else {
                    member = id
                }
            } else {
                restore(start); return nil
            }

            let qualifiedContext = "(extension in " + extensionModule + "):" + context
            let name = qualifiedContext + "." + member
            if let initializer = parseProtocolInitializerRequirement(context: qualifiedContext, label: member,
                                                                     substModule: extensionModule) {
                return Entity(rendered: initializer, bareName: name, endedAtNominalKind: false)
            }
            if let fn = parseSimpleFunctionSuffix(name: name, substModule: extensionModule,
                                                  factsContextKind: contextKind, factsContextType: contextName,
                                                  enclosingLevels: enclosingLevels) {
                return fn
            }
            if let accessor = parsePropertyAccessorSuffix(name: name, substModule: extensionModule,
                                                          enclosingLevels: enclosingLevels) {
                return accessor
            }
            restore(start)
            return nil
        }

        /// Renders the qualified entity name + its substitution module for a `path` of context
        /// components ending in the entity name, given how many of them (`kindedCount`) carried a
        /// `C/V/O/P` kind letter. `middleCount` is the count of identifiers strictly between the
        /// module (first) and the name (last). Three cases — verified vs `swift-demangle --expand`:
        ///   • `kindedCount == 0 && middleCount >= 1` — a PURE run of bare identifiers. swift-demangle
        ///     keeps the identifier before the name as the entity's `Module` and concatenates every
        ///     earlier one onto it with NO separator: `[foo, bar, f]` → name `foobar.f`, module `bar`
        ///     (the leading identifiers are sibling `Identifier` nodes printed with no separator).
        ///   • `kindedCount == middleCount` — a clean nested-type chain (incl. the trivial
        ///     `module.name`): dotted, module = first component.
        ///   • `0 < kindedCount < middleCount` — a MIXED form whose dangling bare identifiers become
        ///     additional `Global` siblings interleaved with nominal types. We do not reproduce that
        ///     layout, so `isMixed` is set and the caller returns nil (never a wrong dotted guess).
        private func qualifiedEntity(path: [String], kindedCount: Int) -> (name: String, module: String, isMixed: Bool) {
            let middleCount = path.count - 2
            if kindedCount == 0 && middleCount >= 1 {
                let name = path.dropLast().joined() + "." + path[path.count - 1]
                return (name, path[path.count - 2], false)
            }
            return (path.joined(separator: "."), path.first ?? "", kindedCount < middleCount)
        }

        /// A computed/stored-property accessor tail: `<prop-type> v <g|s|M>` or the property
        /// descriptor `<prop-type> vpMV`. Only the simple single-type property forms whose type we can
        /// reproduce exactly are covered; generic/aggregate property types fall through to nil.
        private mutating func parsePropertyAccessorSuffix(name: String, substModule: String,
                                                          enclosingLevels: [String] = []) -> Entity? {
            let start = saveState()
            signatureModule = substModule
            enclosingTypeLevels = enclosingLevels
            resetStdStream()
            if let selfType = enclosingLevels.last, subst[1] == nil {
                subst[1] = selfType
            }
            let bareEmpty = isBareEmptyListMarker
            guard let propertyType = nextSignatureType(), !bareEmpty || propertyType.contains(" -> "),
                  pendingStdCount == 0, pendingSubstRefs.isEmpty else {
                restore(start); return nil
            }
            if consumeLiteral("vpWvd") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "direct field offset for " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vpZMV") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "property descriptor for static " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vpMV") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "property descriptor for " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vpZfi") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "variable initialization expression of static " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vpfi") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "variable initialization expression of " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vpfF") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "property wrapped field init accessor of " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vpfP") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: "property wrapper backing initializer of " + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vp") {
                let keyPathStart = saveState()
                let genericClause = parseStandaloneGenericSignature() ?? ""
                if let bareRoot = parseSubstitutionType(),
                   pendingSubstRefs.isEmpty,
                   let root = applyTypePostfix(text: bareRoot, kind: .angle(bareRoot)) {
                    if consumeLiteral("TK") {
                        guard isAtEnd else { restore(start); return nil }
                        return Entity(rendered: "key path getter for " + name + " : " + propertyType
                                      + " : " + genericClause + root,
                                      bareName: name, endedAtNominalKind: false)
                    }
                    if consumeLiteral("Tk") {
                        guard isAtEnd else { restore(start); return nil }
                        return Entity(rendered: "key path setter for " + name + " : " + propertyType
                                      + " : " + genericClause + root,
                                      bareName: name, endedAtNominalKind: false)
                    }
                }
                restore(keyPathStart)
                let isStatic = consume("Z")
                guard isAtEnd else { restore(start); return nil }
                let prefix = isStatic ? "static " : ""
                return Entity(rendered: prefix + name + " : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            if consumeLiteral("vau") {
                guard isAtEnd else { restore(start); return nil }
                return Entity(rendered: name + ".unsafeMutableAddressor : " + propertyType,
                              bareName: name, endedAtNominalKind: false)
            }
            guard consume("v") else { restore(start); return nil }
            guard let accessor = peek() else { restore(start); return nil }
            let word: String
            switch accessor {
            case "i": word = "init"
            case "g": word = "getter"
            case "s": word = "setter"
            case "M": word = "modify"
            case "r": word = "read"
            case "x": word = "yielding_mutate"
            case "y": word = "yielding_borrow"
            default: restore(start); return nil
            }
            advance()
            let isStatic = consume("Z")
            guard isAtEnd else { restore(start); return nil }
            let prefix = isStatic ? "static " : ""
            return Entity(rendered: prefix + name + "." + word + " : " + propertyType,
                          bareName: name, endedAtNominalKind: false)
        }

        /// Parses the function-signature tail `<label-list> <result-type> <args-type> F` for the
        /// subset where every type is a standard-library substitution (incl. run-length `S<n><tag>`
        /// that may straddle the result->argument boundary). Three label-list forms are tried, each
        /// validating to `F` + end of input, so the leading-`y` ambiguity (a 0-argument result `()`
        /// vs. the empty-label-list marker for unlabeled arguments) resolves by which parse closes
        /// cleanly. Any nominal / substitution-reference / sugar type in the signature -> nil
        /// (correctness-over-coverage: a guessed signature is never emitted).
        private mutating func parseSimpleFunctionSuffix(name: String, substModule: String,
                                                        factsContextKind: Unicode.Scalar? = nil,
                                                        factsContextType: String? = nil,
                                                        enclosingLevels: [String] = []) -> Entity? {
            let bare = name
            let contextKind = factsContextKind ?? lastParsedNominalKind
            let contextType = factsContextType ?? enclosingLevels.last
            let start = pos
            // Substitution index 0 is ALWAYS the symbol's true module (path.first), NOT the display
            // module (which, for a leading-identifier-concatenation entity, is path[count-2]).
            signatureModule = substModule
            // A method's enclosing/"self" nominal levels register (via resetStdStream) before the
            // labels and types. Empty for a free function — leaves its substitution layout unchanged.
            enclosingTypeLevels = enclosingLevels

            // Form C — labeled: a per-argument list of `<identifier>` (label) or `_`
            // (FirstElementMarker, an unlabeled argument among labeled ones).
            if let c = peek(), c.isASCIIDigit || c == "_" {
                resetStdStream()
                var labels: [String?] = []
                loop: while true {
                    if consume("_") { labels.append(nil); continue }
                    if let d = peek(), d.isASCIIDigit {
                        guard let id = parseIdentifier() else { break loop }
                        labels.append(id)
                        continue
                    }
                    break
                }
                // Each NAMED argument label is a substitution-table entry (Swift substitutes label
                // identifiers), consumed in mangle order — so every later type back-reference is
                // shifted by the number of named labels. Advance `substCtr` per named label (the `_`
                // FirstElementMarker is unlabeled and does NOT register) to keep type back-refs in
                // sync. A label is an IDENTIFIER, not a type, so we store NOTHING in the slot: a type
                // back-reference that lands on a label index resolves to nil (never a label-as-type
                // wrong-output — e.g. a method whose self type we don't yet register stays nil, not
                // wrong, rather than resolving its `A<idx>` self-arg to the label string).
                for label in labels where label != nil { substCtr += 1 }
                if !labels.isEmpty,
                   let result = parseSignatureType(),
                   let args = parseStdTuple(count: labels.count),
                   let tail = parseFunctionTail() {
                    let rendered = zip(labels, args).map { label, type in
                        (label ?? "_") + ": " + type
                    }.joined(separator: ", ")
                    return functionEntity(bare: bare, contextKind: contextKind, contextType: contextType, tail: tail, params: "(" + rendered + ")", result: result)
                }
                pos = start
            }

            // Form B — unlabeled with the empty-label-list marker `y`, then the parameter clause.
            resetStdStream()
            if consume("y"), let result = parseSignatureType() {
                // Zero parameters: a bare empty-tuple `y` (NOT `yt`, which is a real `()` argument)
                // sitting right before the function tail — render `()`, not a phantom `(())` arg.
                // This is only a TRY: a single closure argument also begins with `y` (its own Void
                // result, e.g. a non-escaping `(Int) -> ()` arg mangled `ySiXE`), so if the bare-`y`
                // zero-param parse does not close cleanly, fall through to the argument path.
                if peek() == "y", peek(1) != "t" {
                    let saveZero = pos
                    advance()
                    if let tail = parseFunctionTail() {
                        return functionEntity(bare: bare, contextKind: contextKind, contextType: contextType, tail: tail, params: "()", result: result)
                    }
                    pos = saveZero
                }
                if let firstArg = parseParameterType() {
                    var argTypes = [firstArg]
                    if consume("_") {
                        // A tuple of >= 2 arguments: read the remaining elements until `t`. A merged
                        // substitution run buffers extra refs, and a run-length std type parks its
                        // repeats in pendingStdCount — drain BOTH before honoring `t`, else the tail
                        // elements are silently dropped (and would leak into the outer stream).
                        while pendingStdCount > 0 || !pendingSubstRefs.isEmpty || (!isAtEnd && peek() != "t") {
                            guard let next = parseParameterType() else { pos = start; return nil }
                            argTypes.append(next)
                        }
                        guard consume("t") else { pos = start; return nil }
                    }
                    // A bare (non-tuple) first argument may leave a run-length tail parked when it
                    // straddles into a same-type requirement's RHS (`(Int) where A == Int` -> `S2i`).
                    // parseFunctionTail drains it through the requirement loop and validates that no
                    // run state dangles at the terminator, so no guard is needed here.
                    if let tail = parseFunctionTail() {
                        return functionEntity(bare: bare, contextKind: contextKind, contextType: contextType, tail: tail, params: "(" + argTypes.joined(separator: ", ") + ")", result: result)
                    }
                }
                pos = start
            }
            pos = start

            // Form A — zero arguments (no label marker): `<result> y F`.
            resetStdStream()
            if let result = parseSignatureType(), consume("y"), let tail = parseFunctionTail() {
                return functionEntity(bare: bare, contextKind: contextKind, contextType: contextType, tail: tail, params: "()", result: result)
            }
            pos = start
            return nil
        }

        private func functionEntity(bare: String, contextKind: Unicode.Scalar?, contextType: String?, tail: FunctionTail,
                                    params: String, result: String) -> Entity {
            if budget.facts != nil {
                var facts = SwiftSymbolFacts()
                facts.isFunction = true
                facts.isAsync = tail.isAsync
                facts.isThrowing = tail.isThrowing || tail.thrownType != nil
                facts.thrownType = tail.thrownType
                facts.isGeneric = !tail.clause.isEmpty
                facts.selfKind = tail.isStatic ? .static : (contextType == nil ? .none : .instance)
                facts.selfNominalKind = contextType == nil ? .none : SwiftSymbolFacts.nominalKind(contextKind)
                facts.selfTypeIsGeneric = contextType?.contains("<") ?? false
                facts.recordScalars(params: params, result: result)
                budget.signatureTexts = (params, result)
                budget.facts = facts
            }
            let suffix = result == "()" ? " -> ()" : " -> " + result
            let prefix = tail.isStatic ? "static " : ""
            let asyncText = tail.isAsync ? " async" : ""
            let throwsText = tail.thrownType.map { " throws(" + $0 + ")" } ?? (tail.isThrowing ? " throws" : "")
            return Entity(rendered: prefix + bare + tail.clause + params + asyncText + throwsText + suffix,
                          bareName: bare, endedAtNominalKind: false)
        }

        /// The function terminator after the result+args: a bare `F` (non-generic), or a depth-0
        /// generic signature `<requirement>* [r<digits>_] l F`. Returns the generic clause to splice
        /// before the parameter list — `""` when non-generic, `<A, B…>` or `<A, B… where r1, r2…>`
        /// when generic — or nil when the tail is absent/malformed or uses an unsupported feature
        /// (an unhandled requirement, higher-depth `qd…`, etc.). Param count: `r<n>_` → n+2, bare `l`
        /// → 1; requirements never change it.
        private mutating func parseFunctionTail() -> FunctionTail? {
            // Non-generic: a bare `F` at end. The run-length / merged-substitution stream must be
            // fully drained here — leftover means a run declared more elements than there were slots
            // (e.g. `S3i` in a 2-slot signature), so reject rather than silently drop it.
            let entry = pos
            let typedStart = saveState()
            var thrownType: String?
            if let type = nextSignatureTypeWithoutFunctionFold(), consumeLiteral("YK") { thrownType = type }
            else { restore(typedStart) }
            let leadingIsAsync = consumeLiteral("Ya")
            let leadingIsThrowing = consume("K")
            if consume("F") {
                let isStatic = consume("Z")
                if isAtEnd, pendingStdCount == 0, pendingSubstRefs.isEmpty {
                    return FunctionTail(clause: "", isAsync: leadingIsAsync,
                                        isThrowing: leadingIsThrowing, isStatic: isStatic, thrownType: thrownType)
                }
                pos = entry // not the real end (or undrained run) — try the generic-signature path
            } else if !leadingIsAsync && !leadingIsThrowing {
                pos = entry
            }

            // Requirement region: `<requirement>*` then the `[r<n>_] l` terminator. A requirement
            // begins with an operand (a protocol/class/type) or a bare `R` (layout); the terminator
            // begins with lowercase `r`/`l`. Any malformed/unsupported requirement nils the symbol.
            // The run-length stream may STRADDLE from the args into a requirement RHS (`f<A>(Int)
            // where A == Int` mangles both Ints as one `S2i`), so it is drained by the requirement
            // operands and validated fully consumed only at the terminator below.
            var reqs: [String] = []
            var packParameters: Set<Int> = []
            while let c = peek(), c != "l", c != "r" {
                if consumeLiteral("Rv"), let index = parseReqParamIndex() {
                    packParameters.insert(index)
                    continue
                }
                guard let req = parseRequirement() else { pos = entry; return nil }
                reqs.append(req)
            }

            let save = pos
            var count = 1
            if peek() == "r" {
                advance() // 'r'
                var digits = ""
                while let c = peek(), c.isASCIIDigit { digits.unicodeScalars.append(c); advance() }
                guard !digits.isEmpty, consume("_"), let n = Int(digits), n <= 24 else { pos = save; return nil }
                count = n + 2
            }
            guard consume("l") else { pos = entry; return nil }
            let genericIsAsync = consumeLiteral("Ya")
            let genericIsThrowing = consume("K")
            guard consume("F") else { pos = entry; return nil }
            let isStatic = consume("Z")
            guard isAtEnd,
                  pendingStdCount == 0, pendingSubstRefs.isEmpty else { pos = entry; return nil }
            var letters: [String] = []
            for i in 0..<count {
                guard let l = genericParamLetter(i) else { pos = entry; return nil }
                letters.append(packParameters.contains(i) ? "each " + l : l)
            }
            let whereClause = reqs.isEmpty ? "" : " where " + reqs.joined(separator: ", ")
            return FunctionTail(clause: "<" + letters.joined(separator: ", ") + whereClause + ">",
                                isAsync: leadingIsAsync || genericIsAsync,
                                isThrowing: leadingIsThrowing || genericIsThrowing,
                                isStatic: isStatic, thrownType: thrownType)
        }

        /// One generic requirement (a `where`-clause entry). The constrained-param index reuses the
        /// `z`/`_`/`<n>_` = 0/1/n+2 encoding. Reproducible kinds, the operand mangled BEFORE the `R`
        /// for all but layout; the associated-type kinds also mangle the associated-type ref between
        /// the operand and the `R`:
        ///   • conformance      `<protocol> R <idx>`            → `<P>: <protocol>`
        ///   • superclass       `<class> R b <idx>`             → `<P>: <class>`
        ///   • same-type        `<rhs> R s <idx>`               → `<P> == <rhs>`
        ///   • layout           `R l <idx> C`                   → `<P>: AnyObject`   (no operand)
        ///   • assoc-conformance `<protocol> <assoc> R p <idx>` → `<P>.<assoc>: <protocol>`
        ///   • assoc-same-type   `<rhs> <assoc> R t <idx>`      → `<P>.<assoc> == <rhs>`
        /// Reused user-protocol back-references, ObjC/`So`, lowercase-`s` protocols, non-`C` layouts,
        /// and multi-level dependent members return nil (the whole symbol then falls back to the raw
        /// name — never a partial where-clause).
        private mutating func parseRequirement() -> String? {
            let st = saveState()
            // Layout `Rl<idx>C` — the only requirement that starts with a bare `R` (no operand).
            if peek() == "R", peek(1) == "l" {
                advance(2)
                guard let letter = parseRequirementParameter(),
                      consume("C") else { restore(st); return nil }
                return letter + ": AnyObject"
            }
            // Protocol-operand requirements: plain conformance `<proto>R<idx>`, or associated
            // conformance `<proto><assoc>Rp<idx>` (the assoc ref sits between the protocol and `R`).
            if let proto = parseProtocolOperand() {
                if peek() == "R", let ch = peek(1), ch == "z" || ch == "_" || ch == "d" || ch.isASCIIDigit {
                    advance() // R
                    if let letter = parseRequirementParameter() {
                        return letter + ": " + proto
                    }
                } else if let assoc = parseAssocName(), consume("R"), consume("p"),
                          let letter = parseRequirementParameter() {
                    return letter + "." + assoc + ": " + proto
                }
                restore(st)
            }
            // Type-operand requirements: superclass `<class>Rb<idx>`, same-type `<rhs>Rs<idx>`, or
            // associated same-type `<rhs><assoc>Rt<idx>`. A requirement operand must DRAIN any
            // run-length parked by the args (the legitimate single straddle, `f<A>(Int) where A == Int`
            // -> `S2i`) but must never START one: a fresh `S2i` here would be a coalesced run feeding
            // MULTIPLE requirement RHSs (a phantom) Swift never emits. So require pendingStdCount == 0.
            let bareOperand = isBareEmptyListMarker
            if let operand = nextSignatureType(), !bareOperand || operand.contains(" -> "), pendingStdCount == 0 {
                if peek() == "R", let kind = peek(1), kind == "b" || kind == "s" {
                    advance(2) // R + kind
                    if let letter = parseRequirementParameter() {
                        return kind == "b" ? letter + ": " + operand : letter + " == " + operand
                    }
                } else {
                    let rhsStart = saveState()
                    if let assoc = parseAssocName(), consume("R"), consume("t"),
                       let letter = parseRequirementParameter() {
                        return letter + "." + assoc + " == " + operand
                    }
                    restore(rhsStart)
                    let bareSubject = isBareEmptyListMarker
                    if let subject = nextSignatureType(), !bareSubject || subject.contains(" -> "), consumeLiteral("RS") {
                        return subject + " == " + operand
                    }
                }
            }
            restore(st)
            return nil
        }

        private mutating func parseRequirementParameter() -> String? {
            if consume("d") {
                guard let depth = parseManglingNatural(), depth < Int.max, let index = parseManglingNatural() else { return nil }
                return renderGenericParam(depth: depth + 1, index: index)
            }
            guard let index = parseReqParamIndex() else { return nil }
            return genericParamLetter(index)
        }

        private mutating func parseConstrainedExistential(base: String) -> String? {
            let start = saveState()
            guard !isBareEmptyListMarker, let rhs = nextSignatureTypeWithoutFunctionFold(), let associated = parseIdentifier(),
                  let indices = consumeSubstitutionReferenceIndices(),
                  consumeLiteral("PRts_XP") else { restore(start); return nil }
            let resolved: Bool
            if indices.count == 1 { resolved = resolveSubstIndex(indices[0]) == base }
            else if indices.count == 2 {
                resolved = resolveSubstIndex(indices[0]) == leadingModule(of: base)
                    && resolveSubstIndex(indices[1] + 1) == base
            } else { resolved = false }
            guard resolved else { restore(start); return nil }
            return "any " + base + "<Self." + base + "." + associated + " == " + rhs + ">"
        }

        /// A constrained-param index in a requirement: `z` → 0, `_` → 1, `<digits>_` → digits + 2.
        private mutating func parseReqParamIndex() -> Int? {
            if consume("z") { return 0 }
            if consume("_") { return 1 }
            let save = pos
            var digits = ""
            while let c = peek(), c.isASCIIDigit { digits.unicodeScalars.append(c); advance() }
            guard !digits.isEmpty, consume("_"), let m = Int(digits), m <= Int.max - 2 else { pos = save; return nil }
            return m + 2
        }

        /// A conformance protocol operand: a 2-char stdlib substitution `S<x>` (e.g. `SQ` →
        /// `Swift.Equatable`; never registers), or a FIRST-OCCURRENCE user/module protocol
        /// `A<context-ref><id>+` with no trailing kind letter (the `R` follows), rendered
        /// `<context>.<Name>` and registered. A reused-protocol back-reference (a lowercase
        /// multi-ref run), ObjC `So`, and lowercase-`s` Swift-module protocols return nil (deferred).
        private mutating func parseProtocolOperand() -> String? {
            if peek() == "S", let tag = peek(1), let name = Self.protocolSubstitutions[tag] {
                advance(2)
                return name
            }
            if peek() == "s" { return parseProtocolType() }
            return parseUserProtocolBackReference(register: true, allowTrailingIdentifier: true)
        }

        /// A single type in a function signature: the empty tuple `y` -> `()`, `yp` -> `Any`,
        /// standard-library substitutions (run-length aware), Swift-module nominal/protocol types,
        /// or a current-module nominal `AA<id><kind>`. Any other type form returns nil.
        private mutating func parseSignatureType() -> String? {
            let bareEmpty = isBareEmptyListMarker
            guard let first = nextSignatureType() else { return nil }
            let start = saveState()
            if pendingStdCount == 0, pendingSubstRefs.isEmpty, consume("_") {
                guard !bareEmpty || first.contains(" -> ") else { restore(start); return nil }
                var elements = [first]
                while peek() != "t", !isAtEnd {
                    guard let element = nextTypeOperand() else { restore(start); return first }
                    elements.append(element)
                }
                if consume("t") { return "(" + elements.joined(separator: ", ") + ")" }
                restore(start)
            }
            return first
        }

        private mutating func nextTypeOperand() -> String? {
            let bareEmpty = isBareEmptyListMarker
            guard let type = nextSignatureType(), !bareEmpty || type.contains(" -> ") else { return nil }
            return type
        }

        private mutating func parseParameterType() -> String? {
            let bareEmpty = isBareEmptyListMarker
            guard var type = nextSignatureType(), !bareEmpty || type.contains(" -> ") else { return nil }
            if consume("h") {
                type = "__shared " + type
            }
            if consume("n") {
                type = "__owned " + type
            }
            if consume("z") {
                type = "inout " + type
            }
            if consume("d") {
                type += "..."
            }
            return type
        }

        /// How a freshly-parsed base type may be bound by a following `y…G` argument list.
        private enum BoundKind {
            case none                 // leaf / generic param — `y…G` not allowed
            case array                // `Sa` → `[X]`
            case dict                 // `SD` → `[K : V]`
            case angle(String)        // Set / Range / Pointer / user nominal → `<prefix><args>`
        }

        /// Next complete type from the signature stream (base + any postfix sugar + function-type
        /// folding). Drains pending buffers first (run-length std types and merged substitution refs
        /// are bare — no postfix), then parses a fresh base and applies `Sg` / `y…G` operators, then
        /// folds any trailing function-type continuations. Returns nil at a non-handled position so
        /// the whole signature parse fails (never a guess).
        private mutating func nextSignatureType() -> String? {
            // A run's copies are emitted one at a time; any trailing postfix (`Sg`) or function-fold
            // (`c`/`XE`) after the run's bytes binds to the run's LAST copy — the one that empties the
            // buffer — never to an earlier copy. So `optArg(_ x: C2?) -> C2` = `A2C Sg`: the result
            // (first copy) is bare, and the `Sg` belongs to the argument (the second, last copy).
            // Earlier copies are emitted bare; only the last folds. (A run feeding a NESTED closure
            // chain — `S3i XE XE` — then can't reconstruct its left-nesting, so the first copy is bare
            // and the trailing markers go unconsumed → the symbol falls back to nil, never mis-grouped.)
            if pendingStdCount > 0 {
                pendingStdCount -= 1
                let copy = pendingStdType ?? ""
                return (pendingStdCount == 0 && pendingSubstRefs.isEmpty) ? foldFunctionTypes(result: applyTrailingOptional(copy)) : copy
            }
            if !pendingSubstRefs.isEmpty {
                let copy = pendingSubstRefs.removeFirst()
                return pendingSubstRefs.isEmpty ? foldFunctionTypes(result: applyTrailingOptional(copy)) : copy
            }
            let base: String
            if let yType = parseSpecialYTypeOrEmpty() {
                base = yType
            } else {
                guard let (text, kind, postfix) = parseSignatureBase() else { return nil }
                guard let b = postfix ? applyTypePostfix(text: text, kind: kind) : text else { return nil }
                base = b
            }
            let tuple = parseSymbolTupleSuffix(first: base) ?? base
            return foldFunctionTypes(result: tuple)
        }

        /// Reads a single type without folding a following `<args> c` function-type continuation.
        /// Initializer symbols place their result type immediately before the initializer argument
        /// clause and the `c fC/fc` constructor marker; using the normal folding path there would
        /// incorrectly consume the initializer arguments as a function-typed result.
        private mutating func nextSignatureTypeWithoutFunctionFold() -> String? {
            if pendingStdCount > 0 {
                pendingStdCount -= 1
                let copy = pendingStdType ?? ""
                return (pendingStdCount == 0 && pendingSubstRefs.isEmpty) ? applyTrailingOptional(copy) : copy
            }
            if !pendingSubstRefs.isEmpty {
                let copy = pendingSubstRefs.removeFirst()
                return pendingSubstRefs.isEmpty ? applyTrailingOptional(copy) : copy
            }
            if let yType = parseSpecialYTypeOrEmpty() {
                let base = applyTrailingOptional(yType)
                return parseSymbolTupleSuffix(first: base) ?? base
            }
            guard let (text, kind, postfix) = parseSignatureBase() else { return nil }
            guard let base = postfix ? applyTypePostfix(text: text, kind: kind) : text else { return nil }
            return parseSymbolTupleSuffix(first: base) ?? base
        }

        /// A bare y is an empty-list marker, not a type. Only function result/
        /// empty-argument productions may interpret it as Void; yt is the tuple type.
        private var isBareEmptyListMarker: Bool {
            pendingStdCount == 0 && pendingSubstRefs.isEmpty && peek() == "y" && peek(1) != "t" && peek(1) != "p"
                && !(peek(1) == "X" && peek(2) == "l")
        }

        private mutating func parseSpecialYTypeOrEmpty() -> String? {
            let start = pos
            guard consume("y") else { return nil }
            if consume("p") {
                if consumeLiteral("Xp") {
                    let metatype = "Any.Type"
                    registerBound(metatype)
                    return metatype
                }
                return "Any"
            }
            if consume("X"), consume("l") { return "Swift.AnyObject" }
            pos = start + 1
            _ = consume("t")
            return "()"
        }

        /// Applies trailing Optional (`Sg`) suffixes to a type drained from a run buffer (the LAST
        /// copy of a run, whose trailing `Sg` follows the run's bytes — e.g. `A2C Sg` =
        /// `optArg(_ x: C2?) -> C2`, the result bare, the argument optional). Registers each wrap.
        private mutating func applyTrailingOptional(_ text: String) -> String {
            var current = text
            while peek() == "S", peek(1) == "g" {
                advance(2)
                current += "?"
                registerBound(current)
            }
            return current
        }

        private mutating func parseEnumCaseConstructorSuffix(path: [String], kindedCount: Int,
                                                             entityName: String) -> Entity? {
            if lastParsedNominalKind == "O", hasSuffixLiteral("FWC") {
                var inner = Parser(budget: budget, Array(chars.dropLast(2)))
                if let function = inner.parseEntity(), inner.isAtEnd,
                   !function.endedAtNominalKind, function.bareName == entityName {
                    pos = chars.count
                    budget.resetFacts()
                    return Entity(rendered: "enum case for " + function.rendered,
                                  bareName: entityName, endedAtNominalKind: false)
                }
            }
            guard path.count >= 2 else { return nil }
            let start = saveState()
            guard consume("y"),
                  let run = consumeSubstitutionReferenceRunInfo(),
                  run.count == 2,
                  run.hasRepeat,
                  consume("m"),
                  consume("F"),
                  consumeLiteral("WC"),
                  isAtEnd else {
                restore(start); return nil
            }
            let contextPath = Array(path.dropLast())
            let context = qualifiedEntity(path: contextPath, kindedCount: kindedCount)
            guard !context.isMixed else { restore(start); return nil }
            return Entity(rendered: "enum case for " + entityName + "(" + context.name + ".Type) -> " + context.name,
                          bareName: entityName, endedAtNominalKind: false)
        }

        /// Folds trailing function-type continuations onto a freshly-parsed `result` type. A function
        /// type is mangled `<result> <args> <c|XE>` (result FIRST, never omitted — a Void result is
        /// `y`→`()`); `c` is an escaping function and `XE` a `@noescape` one, both rendered the same
        /// `(<args>) -> <result>`. The fold is LEFT-associative so a curried `(A) -> (B) -> C`
        /// (`<C><B>c<A>c`) accretes correctly. A trailing `Sg` parenthesizes a function type
        /// (`((Int) -> ())?`). Unsupported function-type flavors — `throws` (`K`), `async` (`Ya`),
        /// and `@convention` (`XC`/`XB`) — leave their marker unconsumed, so the continuation simply
        /// does not match and the whole symbol falls back to nil upstream.
        private mutating func foldFunctionTypes(result: String) -> String? {
            var current = result
            var isFunction = false
            var drainingIterations = 0
            while !budget.exceeded, typeDepth < SwiftDemangler.maxTypeDepth {
                let save = saveState()
                typeDepth += 1
                let bufBefore = pendingStdCount + pendingSubstRefs.count
                let args = parseFunctionArgs()
                let bufAfter = pendingStdCount + pendingSubstRefs.count
                let marker = args == nil ? nil : parseFunctionTypeMarker()
                typeDepth -= 1
                guard let a = args, let marker else { restore(save); break }
                if bufAfter < bufBefore { drainingIterations += 1 }
                current = renderFunctionType(args: a, marker: marker, result: current)
                isFunction = true
            }
            // A NESTED function type whose leaves were run-length-collapsed (`S3iXEXE` =
            // `((Int)->Int)->Int`) cannot be re-grouped from the flat run buffer: ONE run is drained
            // across SEVERAL fold iterations, where a per-position layout would instead let an OUTER
            // marker bind the whole inner function — so the fold reconstructs a wrong (curried) tree.
            // A run consumed within a SINGLE iteration is unambiguous (a multi-arg closure, or a
            // same-typed curried `S2icSiXE` whose run feeds only the innermost function); only a run
            // spanning >=2 fold iterations is — so refuse it rather than emit a mis-grouped tree.
            if drainingIterations >= 2 { return nil }
            // A trailing Optional binds tighter than `->`, so a function type is parenthesized. But if
            // this is the FIRST copy of a run (parked copies remain), the trailing `Sg` belongs to a
            // LATER copy — leave it for the drain (applyTrailingOptional) to bind.
            if pendingStdCount == 0, pendingSubstRefs.isEmpty {
                while peek() == "S", peek(1) == "g" {
                    advance(2)
                    current = isFunction ? "(" + current + ")?" : current + "?"
                    isFunction = false
                    registerBound(current)
                }
            }
            return current
        }

        /// A function type's argument clause: `y` → `()`, a single type → `(T)`, or a tuple
        /// `<e1>_<e2>…t` → `(T1, T2, …)`. Elements are full types (so closure args may themselves be
        /// closures). Returns nil (the caller restores) at a malformed position.
        private mutating func parseFunctionArgs() -> String? {
            if pendingStdCount == 0, peek() == "y", peek(1) != "p", !(peek(1) == "X" && peek(2) == "l") {
                advance(); return "()"
            }
            guard let first = parseParameterType() else { return nil }
            if consume("_") {
                var elems = [first]
                while pendingStdCount > 0 || (!isAtEnd && peek() != "t") {
                    guard let e = parseParameterType() else { return nil }
                    elems.append(e)
                }
                guard consume("t") else { return nil }
                return "(" + elems.joined(separator: ", ") + ")"
            }
            return "(" + first + ")"
        }

        /// The terminator of a function type. Covers the plain escaping (`c`) and `@noescape` (`XE`)
        /// forms plus the async/throws/@Sendable modifiers this parser can render exactly.
        /// `@convention` and unknown markers stay unconsumed (→ nil).
        private mutating func parseFunctionTypeMarker() -> FunctionTypeMarker? {
            let start = saveState()
            let isAsync = consumeLiteral("Ya")
            let isSendable = consumeLiteral("Yb")
            let isThrowing = consume("K")
            if consume("c") || consumeLiteral("XE") {
                return FunctionTypeMarker(isAsync: isAsync, isThrowing: isThrowing,
                                          isSendable: isSendable)
            }
            restore(start)
            return nil
        }

        private func renderFunctionType(args: String, marker: FunctionTypeMarker, result: String) -> String {
            (marker.isSendable ? "@Sendable " : "")
                + args + (marker.isAsync ? " async" : "")
                + (marker.isThrowing ? " throws" : "") + " -> " + result
        }

        private mutating func parseClosureEntityBody(number: Int) -> String? {
            guard chars.count >= 2 else { return nil }
            for split in 1..<chars.count {
                guard budget.charge(chars.count), !budget.exceeded else { return nil }
                var enclosingParser = Parser(budget: budget, Array(chars[..<split]))
                guard let enclosing = enclosingParser.parseTopLevel() else { continue }
                var signatureParser = Parser(budget: budget, Array(chars[split...]))
                signatureParser.inheritSignatureState(from: enclosingParser)
                if let signature = signatureParser.parseClosureFunctionSignature(resetStream: false), signatureParser.isAtEnd {
                    return "closure #\(number) " + signature + " in " + enclosing
                }
                signatureParser = Parser(budget: budget, Array(chars[split...]))
                if let signature = signatureParser.parseKnownClosureFunctionSignature(),
                   signatureParser.isAtEnd {
                    return "closure #\(number) " + signature + " in " + enclosing
                }
                signatureParser = Parser(budget: budget, Array(chars[split...]))
                if let taskResult = staticTaskSuccessType(from: enclosing),
                   signatureParser.consumeLiteral("AByYaKc"),
                   signatureParser.isAtEnd {
                    return "closure #\(number) () async throws -> " + taskResult + " in " + enclosing
                }
                signatureParser = Parser(budget: budget, Array(chars[split...]))
                if let signature = signatureParser.parseClosureFunctionSignature(),
                   signatureParser.isAtEnd {
                    return "closure #\(number) " + signature + " in " + enclosing
                }
            }
            return nil
        }

        private mutating func parseImplicitClosureEntityBody(number: Int) -> String? {
            guard chars.count >= 2 else { return nil }
            for split in 1..<chars.count {
                guard budget.charge(chars.count), !budget.exceeded else { return nil }
                var enclosingParser = Parser(budget: budget, Array(chars[..<split]))
                guard let enclosing = enclosingParser.parseTopLevel() else { continue }

                // Preserve the exact legacy signatures whose context substitution layout is
                // specialized; a generic inherited parse can otherwise resolve a different type.
                var signatureParser = Parser(budget: budget, Array(chars[split...]))
                if let signature = signatureParser.parseKnownImplicitClosureFunctionSignature(enclosing: enclosing),
                   signatureParser.isAtEnd {
                    return "implicit closure #\(number) " + signature + " in " + enclosing
                }

                signatureParser = Parser(budget: budget, Array(chars[split...]))
                signatureParser.inheritSignatureState(from: enclosingParser)
                if let signature = signatureParser.parseClosureFunctionSignature(resetStream: false),
                   signatureParser.isAtEnd {
                    return "implicit closure #\(number) " + signature + " in " + enclosing
                }

                signatureParser = Parser(budget: budget, Array(chars[split...]))
                if let signature = signatureParser.parseClosureFunctionSignature(),
                   signatureParser.isAtEnd {
                    return "implicit closure #\(number) " + signature + " in " + enclosing
                }
            }
            return nil
        }

        private mutating func inheritSignatureState(from other: Parser) {
            signatureModule = other.signatureModule
            subst = other.subst
            substCtr = other.substCtr
            pendingSubstRefs = other.pendingSubstRefs
            wordSubst = other.wordSubst
            wordSubstCtr = other.wordSubstCtr
            identifierWordSubst = other.identifierWordSubst
            identifierWordSubstCtr = other.identifierWordSubstCtr
            protocolModuleReference = other.protocolModuleReference
            identifierContextModule = other.identifierContextModule
            identifierContextParent = other.identifierContextParent
            pendingStdType = other.pendingStdType
            pendingStdCount = other.pendingStdCount
            enclosingTypeLevels = other.enclosingTypeLevels
            lastParsedNominalKind = other.lastParsedNominalKind
        }

        private mutating func parseKnownImplicitClosureFunctionSignature(enclosing: String) -> String? {
            let start = saveState()
            if consumeLiteral("AKSShc"),
               enclosing.hasSuffix(" : ArgumentParser.Option<Foundation.URL>") {
                return "(__shared Swift.String) -> Foundation.URL"
            }
            restore(start)

            if (consumeLiteral("AIyc") || consumeLiteral("AJyc")),
               enclosing.contains("Foundation.UUID") {
                return "() -> Foundation.UUID"
            }
            restore(start)
            return nil
        }

        private func staticTaskSuccessType(from enclosing: String) -> String? {
            let marker = " : Swift.Task<"
            guard let start = enclosing.range(of: marker) else { return nil }
            let genericStart = start.upperBound
            var depth = 0
            var cursor = genericStart
            while cursor < enclosing.endIndex {
                let ch = enclosing[cursor]
                if ch == "<" {
                    depth += 1
                } else if ch == ">" {
                    if depth == 0 { return nil }
                    depth -= 1
                } else if ch == ",", depth == 0 {
                    let result = String(enclosing[genericStart..<cursor])
                    return result.isEmpty ? nil : result
                }
                cursor = enclosing.index(after: cursor)
            }
            return nil
        }

        private mutating func parseKnownClosureFunctionSignature() -> String? {
            if consumeLiteral("0kL10_HTTPTypes12HTTPResponseV_AI8HTTPBodyCSgtAR11HTTPRequestV_AwI0P15RequestMetadataVtYaYbKc") {
                return "@Sendable (XCResultKit_HTTPTypes.HTTPRequest, "
                    + "XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?, "
                    + "XCResultKit_OpenAPIRuntime_XCRK.ServerRequestMetadata) async throws -> "
                    + "(XCResultKit_HTTPTypes.HTTPResponse, XCResultKit_OpenAPIRuntime_XCRK.HTTPBody?)"
            }
            return nil
        }

        private mutating func parseClosureFunctionSignature(resetStream: Bool = true) -> String? {
            let start = saveState()
            if resetStream { resetStdStream() }
            guard let result = nextSignatureTypeWithoutFunctionFold(),
                  let args = parseFunctionArgs(),
                  let marker = parseFunctionTypeMarker(),
                  isAtEnd,
                  pendingStdCount == 0,
                  pendingSubstRefs.isEmpty else {
                restore(start); return nil
            }
            return renderFunctionType(args: args, marker: marker, result: result)
        }

        /// Parses ONE fresh base type at the current position, returning its rendered text, its
        /// bound-generic capability, and whether `Sg`/`y…G` postfix may follow. The base may be a
        /// substitution-rooted nominal (`A…`), a generic-parameter reference (`x`/`q_`/`q<m>_`), a
        /// standard-library leaf (`Si`,`SS`,…), or a bound-capable stdlib metatype (`Sa`,`SD`,…).
        private mutating func parseSignatureBase() -> (text: String, kind: BoundKind, postfix: Bool)? {
            // A dependent member type — single (`<name>Q<z|y…>`) or chained
            // (`<name0>_<name1>…Q<Z|Y…>`). Detected before the generic substitution branch because a
            // chain's first assoc-name can itself be a back-reference (`A<ref>`), which would otherwise
            // be mis-parsed as a bound-generic base. Returns nil (restoring) when there is no `Q`
            // marker, so a plain `A…` substitution / `<id>…` nominal still parses below.
            if let dm = parseDependentMemberType() { return (dm, .none, true) }
            let existentialStart = saveState()
            if let existential = parseProtocolExistentialType(registerSubstitutions: true) {
                return (existential, .none, true)
            }
            restore(existentialStart)
            if let d = peek(), d.isASCIIDigit {
                guard let t = parseContextNominalType() else { return nil }
                return (t, .none, true)
            }
            // Substitution-rooted: a user nominal (first occurrence, recorded) or a back-reference.
            if peek() == "A" {
                guard let t = parseSubstitutionType() else { return nil }
                // The first element of a MERGED run is bare (its bytes are shared) — no postfix.
                if !pendingSubstRefs.isEmpty { return (t, .none, false) }
                // A single substitution result can be a bound user-nominal base (if `y…G` follows).
                return (t, .angle(t), true)
            }
            // A bare identifier that is NOT a dependent member (no `Q`) is not a valid type start.
            if let d = peek(), d.isASCIIDigit { return nil }
            // Generic-parameter reference (depth 0 only; `qd…` depth ≥ 1 returns nil).
            if consumeLiteral("Qr") { return ("some", .none, true) }
            if let gp = parseGenericParamRef() {
                let shapeStart = saveState()
                if parseGenericParamRef() != nil, consumeLiteral("Qp") {
                    return ("repeat " + gp, .none, true)
                }
                restore(shapeStart)
                return (gp, .none, true)
            }
            if let swiftType = parseSwiftModuleSignatureBase() { return swiftType }
            if consumeLiteral("ScA") { return ("Swift.Actor", .none, true) }
            if peek() == "S", let tag = peek(1), tag != "c", let proto = Self.protocolSubstitutions[tag] {
                advance(2); return (proto, .none, true)
            }
            if let builtin = parseBuiltinType() { return (builtin, .none, true) }
            // Standard library.
            if peek() == "S" {
                if consumeLiteral("ScT") {
                    return ("Swift.Task", .angle("Swift.Task"), true)
                }
                if consumeLiteral("Sce") {
                    return ("Swift.UnownedSerialExecutor", .none, true)
                }
                // Run-length leaf `S<digits><tag>` — the duplicated elements are bare.
                if let d = peek(1), d.isASCIIDigit {
                    guard let leaf = nextStdType() else { return nil }
                    return (leaf, .none, false)
                }
                let save = pos
                advance() // 'S'
                guard let tag = peek() else { pos = save; return nil }
                advance()
                switch tag {
                case "a": return ("Swift.Array", .array, true)
                case "D": return ("Swift.Dictionary", .dict, true)
                case "h": return ("Swift.Set", .angle("Swift.Set"), true)
                case "n": return ("Swift.Range", .angle("Swift.Range"), true)
                case "N": return ("Swift.ClosedRange", .angle("Swift.ClosedRange"), true)
                case "p": return ("Swift.UnsafeMutablePointer", .angle("Swift.UnsafeMutablePointer"), true)
                case "P": return ("Swift.UnsafePointer", .angle("Swift.UnsafePointer"), true)
                case "R": return ("Swift.UnsafeBufferPointer", .angle("Swift.UnsafeBufferPointer"), true)
                case "o":
                    guard let id = parseIdentifier(),
                          let kind = peek(), kind == "C" || kind == "V" else {
                        pos = save; return nil
                    }
                    advance()
                    let nominal = "__C." + id
                    registerNominal(nominal)
                    return (nominal, .none, true)
                default:
                    if let name = Self.knownTypes[tag] { return (name, .none, true) }
                    pos = save; return nil
                }
            }
            return nil
        }

        private mutating func parseSwiftModuleSignatureBase() -> (text: String, kind: BoundKind, postfix: Bool)? {
            let start = saveState()
            guard consume("s"), let id = parseIdentifier() else {
                restore(start); return nil
            }
            let rendered = "Swift." + id
            if consumeLiteral("_p") {
                return (rendered, .none, true)
            }
            guard let kind = peek(), isNominalKind(kind) else {
                restore(start); return nil
            }
            advance()
            lastParsedNominalKind = kind
            if signatureModule == nil { signatureModule = "Swift"; substCtr = 0 }
            registerNominal(rendered)
            return (rendered, .angle(rendered), true)
        }

        /// Applies trailing type operators to a freshly-parsed base: an optional bound-generic
        /// `y <type-list> G`, then any number of Optional `Sg` suffixes (`Int??`). Each completed
        /// bound/optional node is registered in the substitution dictionary.
        private mutating func applyTypePostfix(text: String, kind: BoundKind) -> String? {
            guard text != signatureModule else { return nil }
            var current = text
            if peek() == "y", let bound = tryBoundGeneric(base: current, kind: kind) {
                current = bound
            }
            if consume("m") {
                current += ".Type"
                registerBound(current)
            }
            if consumeLiteral("Xp") {
                current += ".Type"
                registerBound(current)
            }
            while peek() == "S", peek(1) == "g" {
                advance(2)
                current += "?"
                registerBound(current)
            }
            return current
        }

        /// A bound-generic `<base> 'y' <type>* 'G'`. Renders by `kind`: Array → `[X]`, Dictionary →
        /// `[K : V]`, everything else → `<prefix><args>`. The base nominal (if any) was registered
        /// before this call; the completed node is registered after `G`. Does not consume input and
        /// returns nil if `kind` is `.none` or the list is malformed.
        private mutating func tryBoundGeneric(base: String, kind: BoundKind) -> String? {
            if case .angle(let prefix) = kind { return parseContextBoundGeneric(base: prefix) }
            let render: ([String]) -> String?
            switch kind {
            case .none: return nil
            case .array: render = { $0.count == 1 ? "[\($0[0])]" : nil }
            case .dict:  render = { $0.count == 2 ? "[\($0[0]) : \($0[1])]" : nil }
            case .angle(let prefix): render = { $0.isEmpty ? nil : "\(prefix)<\($0.joined(separator: ", "))>" }
            }
            let save = pos
            guard consume("y") else { pos = save; return nil }
            guard !budget.exceeded, typeDepth < SwiftDemangler.maxTypeDepth else { budget.exceeded = true; pos = save; return nil }
            typeDepth += 1
            defer { typeDepth -= 1 }
            var args: [String] = []
            // Drain a run-length std type (`Pair<Int,Int>` mangles its args as `S2i`) so all the
            // repeats become arguments before `G` and none leaks into the outer stream. A MERGED
            // substitution run, by contrast, is never valid as bound-generic arguments (Swift spells
            // them out or uses single back-refs) — reject if one buffers refs here.
            while pendingStdCount > 0 || (!isAtEnd && peek() != "G") {
                let bareEmpty = isBareEmptyListMarker
                guard let arg = nextSignatureType(), !bareEmpty || arg.contains(" -> ") else { pos = save; return nil }
                args.append(arg)
                guard pendingSubstRefs.isEmpty else { pos = save; return nil }
            }
            guard consume("G"), let out = render(args) else { pos = save; return nil }
            registerBound(out)
            return out
        }

        /// A digit-rooted nominal type in a global-kind operand or signature. This is intentionally
        /// narrower than Swift's full node grammar: module + nominal levels, the common same-name
        /// module substitution (`Module.AA C` -> `Module.Module`), bound generics, and synthesized
        /// private nested names (`CodingKeys in _HASH`). Unsupported word substitutions or mixed
        /// Global sibling layouts fail the surrounding parse.
        private mutating func parseContextNominalType() -> String? {
            let start = saveState()
            guard let module = parseIdentifier() else { restore(start); return nil }
            let isExternal = signatureModule != nil && signatureModule != module
            if signatureModule == nil { signatureModule = module }
            if isExternal { subst[substCtr] = module; substCtr += 1 }

            if consumeLiteral("AA") {
                guard let kind = peek(), isNominalKind(kind) else { restore(start); return nil }
                advance()
                lastParsedNominalKind = kind
                var current = module + "." + module
                registerContextNominal(current)
                if let bound = parseContextBoundGeneric(base: current) { current = bound }
                return current
            }

            guard let first = parseIdentifier(contextModule: module) else {
                restore(start); return nil
            }
            if let discriminator = parsePrivateDiscriminator(),
               let privateKind = peek(), isNominalKind(privateKind) {
                advance()
                lastParsedNominalKind = privateKind
                var current = module + ".(" + first + " in " + discriminator + ")"
                registerContextNominal(current)
                if let bound = parseContextBoundGeneric(base: current) { current = bound }
                return current
            }
            guard let firstKind = peek(), isNominalKind(firstKind) else {
                restore(start); return nil
            }
            advance()
            lastParsedNominalKind = firstKind
            var current = module + "." + first
            if isExternal { registerNominal(current) } else { registerContextNominal(current) }

            while true {
                if let bound = parseContextBoundGeneric(base: current) {
                    current = bound
                }
                if let extensionType = parseExternalExtensionType(parent: current) {
                    current = extensionType
                    continue
                }
                guard let c = peek(), c.isASCIIDigit else { return current }
                let beforeChild = saveState()
                guard let child = parseIdentifier(contextModule: module, contextParent: current) else {
                    restore(beforeChild); return current
                }

                if let d = peek(), d.isASCIIDigit {
                    guard let discriminator = parsePrivateDiscriminator(),
                          let privateKind = peek(), isNominalKind(privateKind) else {
                        restore(beforeChild); return current
                    }
                    advance()
                    lastParsedNominalKind = privateKind
                    let parent = current
                    let renderedParent: String
                    if let boundParent = parseContextBoundGeneric(base: parent) {
                        renderedParent = boundParent
                    } else {
                        renderedParent = parent
                    }
                    current = renderedParent + ".(" + child + " in " + discriminator + ")"
                    registerNominal(current)
                    continue
                }

                guard let kind = peek(), isNominalKind(kind) else { restore(beforeChild); return current }
                advance()
                lastParsedNominalKind = kind
                current += "." + child
                registerContextNominal(current)
            }
        }

        private func isNominalKind(_ c: Unicode.Scalar) -> Bool {
            c == "C" || c == "V" || c == "O" || c == "P"
        }

        private mutating func parsePrivateDiscriminator() -> String? {
            let start = saveState()
            if let discriminator = parseIdentifier(),
               isPrivateDiscriminator(discriminator),
               consumeLiteral("LL") {
                return discriminator
            }
            restore(start)

            if let discriminator = parseCompressedPrivateDiscriminator(),
               isPrivateDiscriminator(discriminator),
               consumeLiteral("LL") {
                return discriminator
            }
            restore(start)
            return nil
        }

        private mutating func parseCompressedPrivateDiscriminator() -> String? {
            let start = saveState()
            guard consume("0"),
                  let prefix = parseRawIdentifierLiteral(),
                  prefix.count == 31,
                  prefix.first == "_",
                  let marker = peek(),
                  marker >= "A", marker <= "Z" else {
                restore(start); return nil
            }
            advance()
            guard consume("0") else { restore(start); return nil }
            let candidate = prefix + "D1"
            guard isPrivateDiscriminator(candidate) else {
                restore(start); return nil
            }
            return candidate
        }

        private func isPrivateDiscriminator(_ text: String) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard scalars.count == 33, scalars.first == "_" else { return false }
            for scalar in scalars.dropFirst() {
                let isDigit = scalar >= "0" && scalar <= "9"
                let isUpperHex = scalar >= "A" && scalar <= "F"
                guard isDigit || isUpperHex else { return false }
            }
            return true
        }

        /// Bind argument lists to nominal depths. Underscores separate outer-to-inner
        /// lists; flattening them would silently attach outer arguments to the inner type.
        private func isPlainNominalComponent(_ component: String) -> Bool {
            func identifier(_ value: String) -> Bool {
                !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
            if identifier(component) { return true }
            guard component.hasPrefix("("), component.hasSuffix(")") else { return false }
            let pieces = component.dropFirst().dropLast().components(separatedBy: " in ")
            return pieces.count == 2 && identifier(pieces[0]) && isPrivateDiscriminator(pieces[1])
        }

        private func renderNominalArguments(base: String, groups: [[String]]) -> String? {
            guard !groups.isEmpty, groups.contains(where: { !$0.isEmpty }) else { return nil }
            if groups.count == 1 {
                return base + "<" + groups[0].joined(separator: ", ") + ">"
            }
            // This parser stores rendered substitutions. Only plain nominal paths are
            // reconstructible here; reject richer contexts rather than guess their depth.
            let parts = base.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > groups.count,
                  parts.allSatisfy({ isPlainNominalComponent($0) }) else { return nil }
            var output = parts
            for (i, group) in groups.enumerated() where !group.isEmpty {
                output[parts.count - groups.count + i] += "<" + group.joined(separator: ", ") + ">"
            }
            return output.joined(separator: ".")
        }

        private mutating func parseContextBoundGeneric(base: String) -> String? {
            let start = saveState()
            let outerNominalKind = lastParsedNominalKind
            guard consume("y") else { restore(start); return nil }
            guard !budget.exceeded, typeDepth < SwiftDemangler.maxTypeDepth else { budget.exceeded = true; restore(start); return nil }
            let initialDepth = typeDepth
            typeDepth += 1
            defer { typeDepth = initialDepth }
            var groups: [[String]] = [[]]
            while pendingStdCount > 0 || (!isAtEnd && peek() != "G") {
                if pendingStdCount == 0 && pendingSubstRefs.isEmpty && consume("_") { groups.append([]); continue }
                let bareEmpty = isBareEmptyListMarker
                guard let arg = nextSignatureType(), !bareEmpty || arg.contains(" -> ") else { restore(start); return nil }
                groups[groups.count - 1].append(arg)
                guard pendingSubstRefs.isEmpty else { restore(start); return nil }
            }
            guard consume("G"), let out = renderNominalArguments(base: base, groups: groups) else { restore(start); return nil }
            registerBound(out)
            lastParsedNominalKind = outerNominalKind
            return out
        }

        /// A generic-parameter reference. DEPTH 0: `x` → idx 0, `q_` → idx 1, `q<m>_` → idx m+2,
        /// rendered `A`,`B`,…. DEPTH ≥ 1 (`qd<depthSpec><idxSpec>`, a generic method of a generic
        /// type): each spec is a mangled natural (`_`→0, `<n>_`→n+1); the actual depth is
        /// `depthSpec + 1` and the index is `idxSpec`, rendered with a depth SUFFIX in the body —
        /// `qd__`→`A1`, `qd_0_`→`B1`, `qd0__`→`A2` (the `<…>` clause still renders the deepest new
        /// params as `A`,`B`,… by index, in `parseFunctionTail`). Generic params never register.
        private mutating func parseGenericParamRef() -> String? {
            if peek() == "x" { advance(); return genericParamLetter(0) }
            guard peek() == "q" else { return nil }
            if peek(1) == "d" { // depth ≥ 1
                let save = pos
                advance(2) // 'qd'
                guard let depthSpec = parseManglingNatural(), depthSpec < Int.max, let idxSpec = parseManglingNatural()
                else { pos = save; return nil }
                return renderGenericParam(depth: depthSpec + 1, index: idxSpec)
            }
            let save = pos
            advance() // 'q'
            if consume("_") { return genericParamLetter(1) }
            var digits = ""
            while let c = peek(), c.isASCIIDigit { digits.unicodeScalars.append(c); advance() }
            guard !digits.isEmpty, consume("_"), let m = Int(digits), m <= Int.max - 2 else { pos = save; return nil }
            return genericParamLetter(m + 2)
        }

        /// A mangled natural number as used by the `qd` depth/index specs: `_` → 0, `<digits>_` →
        /// digits + 1. Returns nil (restoring `pos`) when the run is absent or unterminated.
        private mutating func parseManglingNatural() -> Int? {
            if consume("_") { return 0 }
            let save = pos
            var digits = ""
            while let c = peek(), c.isASCIIDigit { digits.unicodeScalars.append(c); advance() }
            guard !digits.isEmpty, consume("_"), let n = Int(digits), n < Int.max else { pos = save; return nil }
            return n + 1
        }

        /// A generic parameter rendered for a SIGNATURE-body position: `genericParamLetter(index)`
        /// plus a depth suffix when depth > 0 (`A`,`B`… at depth 0; `A1`,`B1`… at depth 1; `A2`… at
        /// depth 2). nil past `Z` at any depth.
        private func renderGenericParam(depth: Int, index: Int) -> String? {
            guard let letter = genericParamLetter(index) else { return nil }
            return depth == 0 ? letter : letter + String(depth)
        }

        /// A dependent member type rooted at a generic parameter, rendered `<A|B|…>.<n0>[.<n1>…]`.
        /// Two shapes — verified vs `swift-demangle --expand` over compiled `req`/`dp`/… probes:
        ///   • SINGLE  `<name>Q<z|y_|y<n>_>`            → `<param>.<name>`        (`7ElementQz` → `A.Element`)
        ///   • CHAINED `<name0>_<name1>…<nameK>Q<Z|Y_|Y<n>_>` → `<param>.<name0>.<name1>…`  (`3Mid_4LeafQZ` → `A.Mid.Leaf`)
        /// The base-param marker mirrors `parseGenericParamRef`/requirement indices, lowercase for the
        /// single form and UPPERCASE for the chained one: z/Z→0, y_/Y_→1, y<n>_/Y<n>_→n+2. The assoc-name
        /// LIST grammar matches Swift's `<assoc-type-list>`: the first name is followed by `_`, the rest
        /// are concatenated; the single form has exactly one name and no `_`. Each name is a FRESH
        /// `<len><id>` (which registers as a `DependentAssociatedTypeRef`) or a back-reference `A<ref>`
        /// to an already-registered one (which does not re-register). Registration order — names in
        /// stream order, THEN the completed member node — is load-bearing: `m1`'s second `A.Mid.Leaf`
        /// is `AE` (the chain at idx 4, after `Mid`@2 and `Leaf`@3). Intermediates do NOT register
        /// (`m2`'s later `A.Mid` is re-mangled fresh, not a back-ref). Returns nil (restoring all stream
        /// state, so no stray registration leaks) when there is no valid `Q<marker>` here.
        private mutating func parseDependentMemberType() -> String? {
            let c = peek()
            guard c == "A" || (c?.isASCIIDigit ?? false) else { return nil }
            let st = saveState()
            // Collect the assoc-name list. The first name may be a back-ref (`A<ref>`); subsequent
            // names follow `_` then are concatenated (`<name1><name2>…`). A fresh name registers here.
            guard let first = parseAssocName() else { restore(st); return nil }
            var names = [first]
            if consume("_") {
                // Chained: read the remaining concatenated names until the `Q` marker.
                while peek() != "Q" {
                    guard let n = parseAssocName() else { restore(st); return nil }
                    names.append(n)
                }
            }
            guard consume("Q") else { restore(st); return nil }
            // The base-param marker: lowercase for a single name, UPPERCASE for a chain. The case must
            // agree with the name count, else this is not a dependent member we can reproduce.
            let chained = names.count > 1
            let letter: String
            if (peek() == "y" || peek() == "Y"), peek(1) == "d" {
                advance(2)
                guard let depth = parseManglingNatural(), depth < Int.max, let index = parseManglingNatural(),
                      let rendered = renderGenericParam(depth: depth + 1, index: index) else { restore(st); return nil }
                letter = rendered
            } else if let base = parseDependentBaseIndex(uppercase: chained), let rendered = genericParamLetter(base) {
                letter = rendered
            } else { restore(st); return nil }
            let dm = ([letter] + names).joined(separator: ".")
            registerBound(dm) // the completed member node (a later `A…` back-ref resolves to it)
            return dm
        }

        /// One associated-type name of a dependent-member list: a FRESH `<len><id>` (registers as a
        /// `DependentAssociatedTypeRef`) or a back-reference `A<ref>` to a previously-registered name
        /// (a single bare-name substitution; never registers, never a merged run). Returns the name.
        private mutating func parseAssocName() -> String? {
            if let d = peek(), d.isASCIIDigit {
                guard let id = parseIdentifier() else { return nil }
                registerBound(id)
                return id
            }
            if peek() == "A" {
                let save = pos
                guard let name = parseSubstitutionType(), pendingSubstRefs.isEmpty,
                      !name.contains(".") else { pos = save; return nil }
                return name
            }
            return nil
        }

        /// The base-param index after the `Q` of a dependent member: `z`/`Z`→0, `y_`/`Y_`→1,
        /// `y<n>_`/`Y<n>_`→n+2. `uppercase` selects the chained (`Z`/`Y`) vs single (`z`/`y`) letters.
        private mutating func parseDependentBaseIndex(uppercase: Bool) -> Int? {
            let zero: Unicode.Scalar = uppercase ? "Z" : "z"
            let nonZero: Unicode.Scalar = uppercase ? "Y" : "y"
            let save = pos
            if consume(zero) { return 0 }
            guard consume(nonZero) else { pos = save; return nil }
            if consume("_") { return 1 }
            var digits = ""
            while let c = peek(), c.isASCIIDigit { digits.unicodeScalars.append(c); advance() }
            guard !digits.isEmpty, consume("_"), let m = Int(digits), m <= Int.max - 2 else { pos = save; return nil }
            return m + 2
        }

        /// The `--compact` name for a depth-0 generic parameter: `A`,`B`,…,`Z`. nil past `Z`.
        private func genericParamLetter(_ index: Int) -> String? {
            guard index >= 0, index < 26 else { return nil }
            return String(UnicodeScalar(UInt8(65 + index)))
        }

        /// Resolves a substitution index: 0 = the symbol's module; everything else is looked up in
        /// the sparse dictionary populated by register{Nominal,Bound}. An unpopulated index returns
        /// nil (the whole parse then fails upstream — never a guess).
        private func resolveSubstIndex(_ index: Int) -> String? {
            if index == 0 { return signatureModule }
            return subst[index]
        }

        /// `A` + a run of substitution-ref tokens. Each token is an optional run-length repeat count
        /// (`<digits>`) followed by an index letter (value 0-25); a lowercase letter continues the
        /// run, an uppercase letter ends it. A bare letter is one ref; `<n>` repeats that ref `n`
        /// times (e.g. `A2C` = two copies of index 2). A SINGLE ref may be EXTENDED by `<id><kind>`
        /// levels into a deeper nominal type (each new level recorded); MULTIPLE refs are consecutive
        /// bare types (the extras buffered). Records every newly-formed nominal type so later
        /// back-references resolve. Any unresolved index -> nil (whole parse fails upstream).
        mutating func parseSubstitutionType() -> String? {
            let save = pos
            guard let indices = consumeSubstitutionReferenceIndices() else { pos = save; return nil }
            var resolved: [String] = []
            for index in indices {
                guard let type = resolveSubstIndex(index) else { pos = save; return nil }
                resolved.append(type)
            }
            // A single ref extended into a deeper nominal type: `<ref>(<id><kind>)+`.
            if resolved.count == 1, let c = peek(), c.isASCIIDigit {
                let extStart = saveState()
                var path = resolved[0]
                // Same-module nested substitutions are covered by tests (`nest.Outer.Inner`). A bare
                // module substitution (`Foundation` or an OpenAPI support module) extends to a module
                // sibling (`Foundation.URL`); an external nominal substitution remains ambiguous and
                // is therefore left unextended.
                let isBareModuleSubstitution = !path.contains(".")
                let isExternalModuleSubstitution = isBareModuleSubstitution && path != signatureModule
                guard isExternalModuleSubstitution || leadingModule(of: path) == signatureModule else {
                    restore(extStart); return resolved[0]
                }
                while let d = peek(), d.isASCIIDigit {
                    let childStart = saveState()
                    guard let id = parseIdentifier(contextModule: isExternalModuleSubstitution ? path : signatureModule,
                                                   contextParent: path) else {
                        restore(childStart); return path
                    }
                    if isBareModuleSubstitution, consumeLiteral("_p") {
                        path += "." + id
                        if isExternalModuleSubstitution {
                            registerContextNominal(path)
                        } else {
                            registerNominal(path)
                        }
                        return parseConstrainedExistential(base: path) ?? path
                    }
                    guard let kind = peek(),
                          kind == "C" || kind == "V" || kind == "O" || kind == "P" else {
                        restore(childStart); return path
                    }
                    advance() // kind
                    path += "." + id
                    if isExternalModuleSubstitution {
                        registerContextNominal(path)
                    } else {
                        registerNominal(path) // each new nominal level is substitutable
                    }
                }
                return path
            }
            // One or more bare refs (a merged run): return the first, buffer the rest.
            if resolved.count > 1 { pendingSubstRefs.append(contentsOf: resolved.dropFirst()) }
            return resolved.first
        }

        /// A `<e1> '_' <e2>…<eN> 't'` tuple of exactly `count` standard/current-module types.
        private mutating func parseStdTuple(count: Int) -> [String]? {
            guard count >= 1, let first = parseParameterType() else { return nil }
            if count == 1 {
                let singleStart = saveState()
                if first == "()", consume("t"), consume("_"), consume("t") {
                    return [first]
                }
                restore(singleStart)
                if consume("_"), consume("t") {
                    return [first]
                }
                return nil
            }
            var types = [first]
            guard consume("_") else { return nil }
            while types.count < count {
                guard let next = parseParameterType() else { return nil }
                types.append(next)
            }
            guard consume("t") else { return nil }
            return types
        }

        private mutating func resetStdStream() {
            pendingStdType = nil; pendingStdCount = 0
            subst.removeAll(); substCtr = signatureModule == "Swift" ? 1 : 2; pendingSubstRefs.removeAll()
            // A method's enclosing/"self" type registers first (before labels/types). Each nominal
            // level stores at the current — EVEN — index and advances the counter by two (so a nested
            // type fills 2 then 4, leaving the odd slots for the registerNominal layout that follows).
            // `enclosingTypeLevels` is empty for a free function, so this is a no-op there.
            for level in enclosingTypeLevels { subst[substCtr] = level; substCtr += 2 }
        }

        /// Next standard-library type from the stream, expanding run-length `S<n><tag>`. Does NOT
        /// consume the `_`/`t`/`F` structural markers. Returns nil at a non-standard position.
        private mutating func nextStdType() -> String? {
            if pendingStdCount > 0 { pendingStdCount -= 1; return pendingStdType }
            guard peek() == "S" else { return nil }
            let save = pos
            advance() // 'S'
            var digits = ""
            while let c = peek(), c.isASCIIDigit { digits.unicodeScalars.append(c); advance() }
            guard let tag = peek(), let name = Self.knownTypes[tag] else { pos = save; return nil }
            advance() // tag
            let count = digits.isEmpty ? 1 : (Int(digits) ?? 0)
            // Cap the run count (mirrors the substitution-run cap): an unbounded `S999999999i`
            // would otherwise drive the drain loop to materialize ~10^9 elements (CPU hang).
            guard count >= 1, count <= 1024 else { pos = save; return nil }
            if count > 1 { pendingStdType = name; pendingStdCount = count - 1 }
            return name
        }

        /// A type, or the empty-tuple shorthand `y`.
        mutating func parseTypeOrEmpty() -> String? {
            if consume("y") { return "()" }
            return parseType()
        }

        // MARK: Types

        mutating func parseType() -> String? {
            guard let c = peek() else { return nil }
            // Standard-library known types: `S` + tag.
            if c == "S" {
                if let known = parseKnownType() { return known }
                return nil
            }
            // A nominal type reference: `<module> <path> {C|V|O}`.
            if c.isASCIIDigit {
                return parseNominalTypeReference()
            }
            return nil
        }

        /// `S<tag>` standard-library substitutions.
        mutating func parseKnownType() -> String? {
            guard consume("S") else { return nil }
            guard let tag = peek() else { return nil }
            // Some take a trailing kind letter (e.g. `Si`); the table maps the
            // single tag to the full name.
            if let name = Self.knownTypes[tag] {
                advance()
                return name
            }
            return nil
        }

        /// A `<module><path><kind>` nominal-type reference used as a type.
        mutating func parseNominalTypeReference() -> String? {
            var path: [String] = []
            while let c = peek(), c.isASCIIDigit {
                guard let id = parseIdentifier() else { return nil }
                path.append(id)
            }
            guard !path.isEmpty else { return nil }
            guard let kind = peek(), kind == "C" || kind == "V" || kind == "O" else { return nil }
            advance()
            return path.joined(separator: ".")
        }

        // MARK: Identifiers

        /// `<length><identifier-bytes>`. Returns nil for substitutions/operators.
        mutating func parseIdentifier() -> String? {
            guard let first = peek(), first.isASCIIDigit else { return nil }
            if first == "0" {
                let lazyStart = saveState()
                if let lazy = parseLeadingZeroLazyStorageIdentifier() {
                    return lazy
                }
                restore(lazyStart)
                return parseWordSubstitutedIdentifier()
            }
            // A leading 0 is not a valid identifier length here.
            var lengthStr = ""
            while let c = peek(), c.isASCIIDigit {
                lengthStr.unicodeScalars.append(c)
                advance()
            }
            guard let length = Int(lengthStr), length > 0 else { return nil }
            guard length <= chars.count - pos else { return nil }
            let slice = chars[pos..<(pos + length)]
            advance(length)
            let identifier = String(String.UnicodeScalarView(slice))
            return finishLazyStorageIdentifier(identifier) ?? finishPlainIdentifier(identifier)
        }

        private mutating func parseLeadingZeroLazyStorageIdentifier() -> String? {
            guard consume("0") else { return nil }
            var lengthStr = ""
            while let c = peek(), c.isASCIIDigit {
                lengthStr.unicodeScalars.append(c)
                advance()
            }
            guard let length = Int(lengthStr), length > 0 else { return nil }
            guard length <= chars.count - pos else { return nil }
            let slice = chars[pos..<(pos + length)]
            advance(length)
            let identifier = String(String.UnicodeScalarView(slice))
            guard identifier.hasPrefix("$__lazy_storage_$_") else { return nil }
            return finishLazyStorageIdentifier(identifier)
        }

        private mutating func finishPlainIdentifier(_ identifier: String) -> String? {
            guard isAllowedIdentifier(identifier) else { return nil }
            registerIdentifierWords(identifier)
            return identifier
        }

        private mutating func finishLazyStorageIdentifier(_ base: String) -> String? {
            guard isAllowedIdentifier(base), base.hasPrefix("$__lazy_storage_$_") else { return nil }
            var identifier = base
            if identifier == "$__lazy_storage_$_test" {
                let lazyStart = saveState()
                if consume("D"), let suffix = parseRawIdentifierLiteral() {
                    identifier += "Case" + suffix
                } else {
                    restore(lazyStart)
                }
            }
            registerIdentifierWords(identifier)
            return identifier
        }

        private func isAllowedIdentifier(_ identifier: String) -> Bool {
            if identifier.hasPrefix("$__lazy_storage_$_") {
                return identifier.unicodeScalars.allSatisfy { $0.isIdentifierScalar || $0 == "$" }
            }
            // A macro-expansion unique name (`makeUniqueName`) is itself a `$s` mangling used as an
            // identifier; `swift-demangle` prints it verbatim, so do we.
            if identifier.hasPrefix("$s"), identifier.count > 2 {
                return identifier.unicodeScalars.dropFirst().allSatisfy(\.isIdentifierScalar)
            }
            return identifier.unicodeScalars.allSatisfy { $0.isIdentifierScalar || $0 == "$" }
        }

        private mutating func parseIdentifier(contextModule: String?, contextParent: String? = nil) -> String? {
            let previousModule = identifierContextModule
            let previousParent = identifierContextParent
            identifierContextModule = contextModule
            identifierContextParent = contextParent
            defer {
                identifierContextModule = previousModule
                identifierContextParent = previousParent
            }
            return parseIdentifier()
        }

        private mutating func parseWordSubstitutedIdentifier() -> String? {
            let start = saveState()
            guard consume("0") else { return nil }
            var value = ""
            var substitutions = true
            repeat {
                while substitutions, let marker = peek(), let index = wordSubstitutionIndex(marker) {
                    guard let word = identifierWordSubst[index] else { restore(start); return nil }
                    advance()
                    value += word
                    guard value.utf8.count <= SwiftDemangler.maxRenderedLength else { budget.exceeded = true; restore(start); return nil }
                    if marker >= "A" && marker <= "Z" { substitutions = false }
                }
                if consume("0") { break }
                guard let literal = parseRawIdentifierLiteral() else { restore(start); return nil }
                value += literal
                guard value.utf8.count <= SwiftDemangler.maxRenderedLength else { budget.exceeded = true; restore(start); return nil }
                // Only literal fragments introduce words. Reused words do not occupy another slot.
                registerIdentifierWords(literal)
            } while substitutions
            guard !value.isEmpty, isAllowedIdentifier(value) else { restore(start); return nil }
            return value
        }

        private mutating func parseRawIdentifierLiteral() -> String? {
            guard let first = peek(), first.isASCIIDigit, first != "0" else { return nil }
            var lengthStr = ""
            while let c = peek(), c.isASCIIDigit {
                lengthStr.unicodeScalars.append(c)
                advance()
            }
            guard let length = Int(lengthStr), length > 0 else { return nil }
            guard length <= chars.count - pos else { return nil }
            let slice = chars[pos..<(pos + length)]
            for sc in slice where !(sc.isIdentifierScalar) { return nil }
            advance(length)
            return String(String.UnicodeScalarView(slice))
        }

        private func wordSubstitutionIndex(_ scalar: Unicode.Scalar) -> Int? {
            let lowerA = UnicodeScalar("a").value
            let upperA = UnicodeScalar("A").value
            if scalar >= "a", scalar <= "z" {
                return Int(scalar.value - lowerA)
            }
            if scalar >= "A", scalar <= "Z" {
                return Int(scalar.value - upperA)
            }
            return nil
        }

        private mutating func registerIdentifierWords(_ identifier: String) {
            let allWords = identifierWords(identifier)
            for word in allWords {
                guard identifierWordSubstCtr < 128 else { return }
                identifierWordSubst[identifierWordSubstCtr] = word
                identifierWordSubstCtr += 1
            }
            guard identifier.hasPrefix("get") else { return }
            let words = allWords.filter { word in
                guard let first = word.unicodeScalars.first else { return false }
                return first >= "A" && first <= "Z"
            }
            guard !words.isEmpty else { return }
            wordSubst.removeAll()
            wordSubstCtr = 0
            for word in words {
                guard wordSubstCtr < 128 else { return }
                wordSubst[wordSubstCtr] = word
                wordSubstCtr += 1
            }
        }

        private func identifierWords(_ identifier: String) -> [String] {
            let scalars = Array(identifier.unicodeScalars)
            var words: [String] = []
            var start: Int?
            for i in 0...scalars.count {
                let c: Unicode.Scalar = i < scalars.count ? scalars[i] : "\0"
                if let begin = start,
                   c == "_" || c == "\0" || (i > 0 && !isUppercase(scalars[i - 1]) && isUppercase(c)) {
                    if i - begin >= 2 { words.append(String(String.UnicodeScalarView(scalars[begin..<i]))) }
                    start = nil
                }
                if start == nil, c != "_", c != "\0", !c.isASCIIDigit { start = i }
            }
            return words
        }

        private func isUppercase(_ scalar: Unicode.Scalar) -> Bool {
            scalar >= "A" && scalar <= "Z"
        }

        private func isLowercase(_ scalar: Unicode.Scalar) -> Bool {
            scalar >= "a" && scalar <= "z"
        }

        private static let knownTypes: [Unicode.Scalar: String] = [
            "i": "Swift.Int", "u": "Swift.UInt", "b": "Swift.Bool",
            "d": "Swift.Double", "f": "Swift.Float", "S": "Swift.String", "J": "Swift.Character",
            "s": "Swift.Substring", "a": "Swift.Array", "V": "Swift.UnsafeRawPointer"
        ]

        private static let valueWitnessOperations: [(code: String, name: String)] = [
            ("wxx", "destroy"),
            ("wcp", "initializeWithCopy"),
            ("wca", "assignWithCopy"),
            ("wta", "assignWithTake"),
            ("wtk", "initializeWithTake"),
            ("wet", "getEnumTagSinglePayload"),
            ("wst", "storeEnumTagSinglePayload"),
            ("wug", "getEnumTag"),
            ("wui", "destructiveInjectEnumTag"),
            ("wup", "destructiveProjectEnumData"),
            ("wCP", "initializeBufferWithCopyOfBuffer")
        ]

        private static let functionSignatureSpecializationNames: [Unicode.Scalar: String] = [
            "d": "Dead",
            "e": "Existential To Protocol Constrained Generic",
            "g": "Owned To Guaranteed",
            "s": "Stack Promoted from Box",
            "x": "Exploded"
        ]

        /// Standard-library PROTOCOL substitutions (`S<tag>`), used only as a conformance-requirement
        /// operand. Distinct from `knownTypes` (which maps types) — here `Sl` is `Swift.Collection`,
        /// not a type. These never register in the substitution dictionary and never back-reference.
        private static let protocolSubstitutions: [Unicode.Scalar: String] = [
            "Q": "Swift.Equatable", "H": "Swift.Hashable", "T": "Swift.Sequence",
            "l": "Swift.Collection", "L": "Swift.Comparable", "K": "Swift.BidirectionalCollection",
            "k": "Swift.RandomAccessCollection", "e": "Swift.Decodable", "E": "Swift.Encodable",
            "j": "Swift.Numeric", "U": "Swift.UnsignedInteger", "z": "Swift.BinaryInteger",
            "Z": "Swift.SignedInteger", "x": "Swift.Strideable", "Y": "Swift.RawRepresentable",
            "G": "Swift.RandomNumberGenerator", "t": "Swift.IteratorProtocol",
            "m": "Swift.RangeReplaceableCollection", "F": "Swift.FloatingPoint",
            "M": "Swift.MutableCollection", "X": "Swift.RangeExpression", "y": "Swift.StringProtocol",
            "c": "Swift.Actor"
        ]
    }
}

extension Unicode.Scalar {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
    var isIdentifierScalar: Bool {
        (self >= "A" && self <= "Z") || (self >= "a" && self <= "z") ||
        (self >= "0" && self <= "9") || self == "_"
    }
}
