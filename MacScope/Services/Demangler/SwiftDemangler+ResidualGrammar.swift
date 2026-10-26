import Foundation

// A deliberately bounded postfix grammar for residual context-bearing symbols.
// Nodes retain identity through substitutions; rendering never changes parsed text.
// This is a clean-room complement to the older signature parser, not an oracle
// lookup: only complete, structurally typed stacks may produce an answer.
extension SwiftDemangler {
    /// Work budget shared by a top-level parser and every nested re-parse it spawns.
    final class Budget {
        /// Nil unless the caller requested structured symbol facts.
        var facts: SwiftSymbolFacts?
        var signatureTexts: (params: String, result: String)?
        var factsSource: String?
        func resetFacts() {
            if facts != nil { facts = SwiftSymbolFacts() }
            signatureTexts = nil
        }
        var wrapperDepth = 0
        // One cumulative operation budget for the original Parser and residual parser/rendering.
        // The separate pre-existing pack-conformance recognizer retains its own bounds.
        // Charging lookahead also bounds failed/speculative productions.
        var remainingWork = maxMangledLength * maxTypeDepth
        func charge(_ amount: Int = 1) -> Bool {
            guard amount >= 0, amount <= remainingWork else { exceeded = true; return false }
            remainingWork -= amount
            return true
        }
        /// Set once any cap above is hit. A parse that still succeeds keeps its result; a parse
        /// that fails with this set reports `tooComplexMarker` instead of nil.
        var exceeded = false
    }

    final class ResidualNode {
        enum Kind { case identifier, operatorName, module, localName, nominal, bound, parameter, dependent,
            empty, first, tuple, functionType, function, closure, variable, accessor,
            signature, requirement, extensionContext, conformance, wrapper, attribute, pack, expansion }
        let kind: Kind
        let text: String
        let children: [ResidualNode]
        let indices: [Int]
        let depth: Int
        var cachedRendering: String?
        init(_ kind: Kind, _ text: String = "", _ children: [ResidualNode] = [], _ indices: [Int] = []) {
            self.kind = kind; self.text = text; self.children = children; self.indices = indices
            depth = 1 + (children.map(\.depth).max() ?? 0)
        }
        var isType: Bool {
            switch kind { case .nominal, .bound, .parameter, .dependent, .tuple, .functionType, .pack, .expansion: return true
            default: return false }
        }
        var isContext: Bool {
            switch kind { case .identifier, .module, .nominal, .function, .closure, .extensionContext: return true
            default: return false }
        }
        var localContext: Bool {
            switch kind {
            case .function, .closure: return true
            case .nominal: return children.last?.kind == .localName || (children.first?.localContext ?? false)
            default: return false
            }
        }
    }

    struct ResidualParser {
        typealias Node = ResidualNode
        let chars: [Unicode.Scalar]
        let budget: Budget
        var pos = 0
        var stack: [Node] = []
        var substitutions: [Node] = []
        var words: [String] = []
        var failureProduction = "start"
        var failureCursor = 0
        var steps = 0
        var wrapperCount = 0
        init(_ payload: String, budget: Budget) { chars = Array(payload.unicodeScalars); self.budget = budget }
        func peek(_ n: Int = 0) -> Unicode.Scalar? {
            guard budget.charge() else { return nil }
            return pos + n < chars.count ? chars[pos + n] : nil
        }
        mutating func take(_ s: String) -> Bool {
            let c = Array(s.unicodeScalars)
            guard budget.charge(c.count) else { return false }
            guard pos + c.count <= chars.count, Array(chars[pos..<pos+c.count]) == c else { return false }
            pos += c.count; return true
        }
        mutating func number() -> Int? {
            let start = pos
            var n = 0
            while let c = peek(), c.value >= 48, c.value <= 57 {
                let d = Int(c.value - 48)
                guard n <= (maxMangledLength - d) / 10 else { return nil }
                n = n * 10 + d; pos += 1
            }
            return pos > start ? n : nil
        }
        mutating func index() -> Int? {
            if take("_") { return 0 }
            guard let n = number(), take("_") else { return nil }
            return n + 1
        }
        mutating func push(_ node: Node, substitute: Bool = false) -> Bool {
            guard budget.charge() else { return false }
            if node.kind == .wrapper {
                wrapperCount += 1
                guard wrapperCount <= maxWrapperDepth else { budget.exceeded = true; return false }
            }
            guard node.depth <= maxTypeDepth, stack.count < maxMangledLength,
                  substitutions.count < maxMangledLength else { budget.exceeded = true; return false }
            stack.append(node)
            if substitute { substitutions.append(node) }
            return true
        }
        mutating func popType(empty: Bool = false) -> Node? {
            guard let n = stack.last, n.isType || (empty && n.kind == .empty) else { return nil }
            stack.removeLast()
            return n.kind == .empty ? Node(.tuple) : n
        }
        mutating func popContext() -> Node? {
            guard let n = stack.last, n.isContext else { return nil }; stack.removeLast()
            return n.kind == .identifier ? Node(.module, n.text) : n
        }
        mutating func popName() -> Node? {
            guard let n = stack.last, n.kind == .identifier || n.kind == .localName || n.kind == .operatorName else { return nil }
            return stack.removeLast()
        }
        mutating func protocolType(implicit: Bool = true) -> Node? {
            if let n = stack.last, n.kind == .nominal, n.text == "P" { return stack.removeLast() }
            guard implicit, let name = popName(), name.kind == .identifier, let context = popContext() else { return nil }
            return Node(.nominal, "P", [context, name])
        }
        mutating func rememberWords(_ text: String) {
            let cs = Array(text.unicodeScalars)
            func upper(_ c: Unicode.Scalar) -> Bool { c.value >= 65 && c.value <= 90 }
            var start: Int?
            for i in 0...cs.count {
                let c: Unicode.Scalar = i < cs.count ? cs[i] : "\0"
                if let s = start, c == "_" || c == "\0" || (i > 0 && !upper(cs[i-1]) && upper(c)) {
                    if i-s >= 2, words.count < 128 { words.append(String(String.UnicodeScalarView(cs[s..<i]))) }
                    start = nil
                }
                if start == nil, c != "_", c != "\0", !(c.value >= 48 && c.value <= 57) { start = i }
            }
        }
        mutating func literalIdentifier() -> String? {
            guard peek() != "0", let n = number(), n > 0, n <= chars.count-pos else { return nil }
            let s = String(String.UnicodeScalarView(chars[pos..<pos+n])); pos += n
            // ASCII grammar subset, including macro unique names embedded as identifiers.
            guard s.unicodeScalars.allSatisfy({ $0.isIdentifierScalar || $0 == "$" }) else { return nil }
            rememberWords(s); return s
        }
        mutating func identifier() -> Bool {
            var text = ""
            if take("0") {
                // Punycode identifiers are outside this residual grammar.
                guard peek() != "0" else { return false }
                var continuing = true
                repeat {
                    while continuing, let c = peek(), (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) {
                        let upper = c.value <= 90, i = Int(c.value - (upper ? 65 : 97))
                        guard i < words.count else { return false }
                        pos += 1; text += words[i]
                        guard text.utf8.count <= maxRenderedLength else { budget.exceeded = true; return false }
                        if upper { continuing = false }
                    }
                    if take("0") { break }
                    guard let literal = literalIdentifier() else { return false }; text += literal
                } while continuing
            } else { guard let literal = literalIdentifier() else { return false }; text = literal }
            guard !text.isEmpty, text.utf8.count <= maxRenderedLength else { return false }
            return push(Node(.identifier, text), substitute: true)
        }
        func standard(_ tag: Unicode.Scalar) -> Node? {
            let names: [Unicode.Scalar: (String, String)] = ["i":("Int","V"), "u":("UInt","V"), "b":("Bool","V"), "S":("String","V"), "J":("Character","V"), "f":("Float","V"), "d":("Double","V"), "a":("Array","V"), "D":("Dictionary","V"), "q":("Optional","O"), "H":("Hashable","P"), "Q":("Equatable","P"), "l":("Collection","P"), "T":("Sequence","P")]
            guard let (name, kind) = names[tag] else { return nil }
            return Node(.nominal, kind, [Node(.module,"Swift"),Node(.identifier,name)])
        }
        mutating func substitution() -> Bool {
            if take("S") {
                if take("g") { guard let type = popType() else { return false }; return push(Node(.bound,"optional",[type]), substitute:true) }
                let count = number() ?? 1
                guard count > 0, count <= maxMangledLength, let tag = peek(), let n = standard(tag) else { return false }
                pos += 1
                for _ in 0..<count { if !push(n) { return false } }; return true
            }
            guard take("A") else { return false }
            let repeatCount = number() ?? 1
            guard repeatCount > 0, repeatCount <= maxMangledLength else { return false }
            while let c = peek() {
                let upper = c.value >= 65 && c.value <= 90, lower = c.value >= 97 && c.value <= 122
                guard upper || lower else { return false }
                let i = Int(c.value - (upper ? 65 : 97)); pos += 1
                guard i < substitutions.count else { return false }
                for _ in 0..<repeatCount { if !push(substitutions[i]) { return false } }
                if upper { return true }
                guard repeatCount == 1 else { return false }
            }
            return false
        }
        mutating func genericParameter(requirement: Bool = false) -> Node? {
            if requirement && take("z") { return Node(.parameter,"",[],[0,0]) }
            var depth = 0
            if take("d") { guard let d = index() else { return nil }; depth = d+1 }
            guard let i = index() else { return nil }
            return Node(.parameter,"",[],[depth, depth == 0 ? i+1 : i])
        }
        mutating func tuple() -> Bool {
            var elements: [Node] = []
            while let n = stack.last, n.kind != .first {
                guard let t = popType() else { return false }; elements.append(t)
            }
            guard stack.last?.kind == .first else { return false }; stack.removeLast()
            guard let first = popType() else { return false }; elements.append(first)
            return push(Node(.tuple,"",elements.reversed()))
        }
        mutating func signature(_ counts: [Int]) -> Bool {
            var requirements: [Node] = []
            while stack.last?.kind == .requirement { requirements.append(stack.removeLast()) }
            guard !counts.isEmpty, counts.allSatisfy({ $0 >= 0 && $0 <= 26 }) else { return false }
            return push(Node(.signature,"",requirements.reversed(),counts))
        }
        mutating func functionType(_ convention: String = "") -> Node? {
            var attributes: [Node] = []
            while stack.last?.kind == .attribute { attributes.append(stack.removeLast()) }
            attributes.reverse()
            let kinds = attributes.map(\.text)
            guard kinds == [] || kinds == ["async"] || kinds == ["throws"] || kinds == ["async", "throws"] else { return nil }
            guard let args = popType(empty:true), let result = popType(empty:true) else { return nil }
            return Node(.functionType,convention,[args,result] + attributes)
        }
        mutating func labels(for fn: Node) -> [Node]? {
            if stack.last?.kind == .empty { stack.removeLast(); return [] }
            let arg = fn.children[0], count = arg.kind == .tuple ? arg.children.count : 1
            if count == 0 { return [] }
            guard arg.kind == .tuple else { return nil }
            var labels: [Node] = []
            for _ in 0..<count { guard let n = popName(), n.kind == .identifier else { return nil }; labels.append(n) }
            return labels.reversed()
        }
        mutating func function(_ initializer: Bool = false) -> Bool {
            let sig = stack.last?.kind == .signature ? stack.removeLast() : nil
            let fn: Node
            if initializer { guard let f = popType(), f.kind == .functionType else { return false }; fn = f }
            else { guard let f = functionType() else { return false }; fn = f }
            guard let labels = labels(for:fn) else { return false }
            let name: Node
            if initializer { name = Node(.identifier,"init") }
            else { guard let n = popName() else { return false }; name = n }
            guard let context = popContext() else { return false }
            return push(Node(.function,"",[context,name,fn,Node(.tuple,"labels",labels)] + (sig.map { [$0] } ?? [])))
        }
        mutating func conformance() -> Node? {
            let sig = stack.last?.kind == .signature ? stack.removeLast() : nil
            guard let module = popContext(), module.kind == .module,
                  let proto = protocolType(), let type = popType() else { return nil }
            return Node(.conformance,"",[type,proto,module] + (sig.map { [$0] } ?? []))
        }
        mutating func wrap(_ phrase: String, _ n: Node) -> Bool {
            return push(Node(.wrapper,phrase,[n]))
        }
        mutating func parse() -> String? {
            while pos < chars.count {
                guard budget.charge(), !budget.exceeded else { return nil }
                steps += 1; failureCursor = pos
                guard steps <= maxMangledLength * 2 else { budget.exceeded = true; return nil }
                guard let next = peek() else { return nil }
                failureProduction = String(next)
                guard step() else { return nil }
            }
            guard !stack.isEmpty, stack.allSatisfy({ $0.kind != .attribute && $0.kind != .empty && $0.kind != .first && $0.kind != .signature && $0.kind != .requirement }) else { return nil }
            // Global sibling identifiers are legal, but every following declaration
            // remains an independent node, never concatenated before parsing.
            guard stack.count == 1 || stack.dropLast().allSatisfy({ $0.kind == .identifier || $0.kind == .nominal }) else { return nil }
            guard let last = stack.last, last.kind != .identifier && last.kind != .module && last.kind != .variable else { return nil }
            var output = ""
            for node in stack { guard let s = render(node) else { return nil }; output += s; if output.utf8.count > maxRenderedLength { budget.exceeded = true; return nil } }
            if budget.facts != nil {
                budget.facts = stack.reduce(SwiftSymbolFacts()) { facts, node in
                    let derived = symbolFacts(node)
                    return derived.isFunction ? derived : facts
                }
            }
            return output
        }

        /// Follow only entity wrappers; never descend into a function's context or parameter types.
        private func symbolFacts(_ node: Node) -> SwiftSymbolFacts {
            if node.kind == .wrapper {
                guard ["async function pointer to ", "partial apply forwarder for ", "static "].contains(node.text),
                      let child = node.children.first else { return SwiftSymbolFacts() }
                var facts = symbolFacts(child)
                guard facts.isFunction else { return SwiftSymbolFacts() }
                switch node.text {
                case "async function pointer to ": facts.isAsyncFunctionPointer = true
                case "partial apply forwarder for ": facts.isPartialApplyForwarder = true
                case "static ": facts.selfKind = .static
                default: break
                }
                return facts
            }
            guard node.kind == .function else { return SwiftSymbolFacts() }
            var facts = SwiftSymbolFacts()
            facts.isFunction = true
            let context = node.children[0], name = node.children[1], fn = node.children[2]
            facts.isGeneric = node.children.dropFirst(4).contains { $0.kind == .signature }
            let enclosing = context.kind == .extensionContext ? context.children[1] : context
            let nominal = enclosing.kind == .bound ? enclosing.children.first : enclosing
            if let nominal, nominal.kind == .nominal {
                facts.selfKind = .instance
                facts.selfNominalKind = SwiftSymbolFacts.nominalKind(nominal.text.unicodeScalars.first)
                facts.selfTypeIsGeneric = enclosing.cachedRendering?.contains("<") ?? false
            } else if enclosing.kind == .parameter || enclosing.kind == .dependent {
                facts.selfKind = .instance
                facts.selfNominalKind = .archetype
            }
            if name.kind == .identifier, name.text == "init" { facts.selfKind = .allocatingInit }
            for attribute in fn.children.dropFirst(2) where attribute.kind == .attribute {
                if attribute.text == "async" { facts.isAsync = true }
                if attribute.text == "throws" {
                    facts.isThrowing = true
                    facts.thrownType = attribute.children.first?.cachedRendering
                }
            }
            // Rendering has already succeeded for the complete tree, so every child is cached.
            let args = fn.children[0]
            let params = args.cachedRendering ?? ""
            let signature = (params: args.kind == .tuple ? params : "(" + params + ")",
                             result: fn.children[1].cachedRendering ?? "")
            facts.recordScalars(params: signature.params, result: signature.result)
            budget.signatureTexts = signature
            return facts
        }

        mutating func step() -> Bool {
            guard let c = peek() else { return false }
            if c.value >= 48 && c.value <= 57 { return identifier() }
            if c == "S" || c == "A" { return substitution() }
            pos += 1
            switch c {
            case "s":
                if stack.last?.kind == .variable { return push(Node(.accessor,"setter",[stack.removeLast()])) }
                return push(Node(.module,"Swift"))
            case "y": return push(Node(.empty))
            case "_": return push(Node(.first))
            case "x": return push(Node(.parameter,"",[],[0,0]))
            case "q": guard let p = genericParameter() else { return false }; return push(p)
            case "C", "V", "O", "P":
                guard let name = popName(), let context = popContext() else { return false }
                return push(Node(.nominal,String(c),[context,name]),substitute:true)
            case "L":
                guard let i = index(), let n = popName(), n.kind == .identifier || n.kind == .operatorName else { return false }
                return push(Node(.localName,n.text,[],[i+1]))
            case "G":
                var arguments: [Node] = []
                while stack.last?.kind != .empty { guard let t = popType() else { return false }; arguments.append(t) }
                guard stack.last?.kind == .empty else { return false }; stack.removeLast()
                guard let type = popType(), type.kind == .nominal, type.text == "V" || type.text == "C" || type.text == "O" else { return false }
                return push(Node(.bound,"",[type] + arguments.reversed()),substitute:true)
            case "t": return tuple()
            case "p":
                if stack.last?.kind == .variable { return take("MV") && wrap("property descriptor for ",stack.removeLast()) }
                guard stack.last?.kind == .empty else { return false }; stack.removeLast()
                return push(Node(.nominal,"any"))
            case "z":
                guard let t = popType() else { return false }; return push(Node(.bound,"inout",[t]))
            case "Y":
                if take("i") { guard let t = popType() else { return false }; return push(Node(.bound,"isolated",[t])) }
                if take("a") { return push(Node(.attribute,"async")) }
                if take("K") { guard let t = popType() else { return false }; return push(Node(.attribute,"throws",[t])) }
                return false
            case "K": return push(Node(.attribute,"throws"))
            case "c": guard let f = functionType() else { return false }; return push(f)
            case "X":
                let convention: String
                if take("E") { convention = "" } else if take("C") { convention = "@convention(c) " } else { return false }
                guard let f = functionType(convention) else { return false }; return push(f)
            case "F": return function()
            case "f":
                if take("C") { return function(true) }
                if take("U"), let i = index(), let fn = popType(), fn.kind == .functionType, let context = popContext() {
                    return push(Node(.closure,"",[context,fn],[i+1]))
                }
                return false
            case "v":
                guard let type = popType(), let name = popName(), let context = popContext() else { return false }
                return push(Node(.variable,"",[context,name,type]))
            case "g":
                guard let variable = stack.last, variable.kind == .variable else { return false }; stack.removeLast()
                return push(Node(.accessor,"getter",[variable]))
            case "Z":
                guard let n = stack.popLast(), n.kind == .function || n.kind == .accessor else { return false }
                return wrap("static ",n)
            case "o":
                guard take("i"), let n = popName(), n.kind == .identifier else { return false }
                let mapping: [Character: Character] = ["e":"=", "p":"+", "s":"-", "m":"*", "d":"/", "l":"<", "g":">", "n":"!", "a":"&", "o":"|", "x":"^", "r":"%", "t":"~", "q":"?"]
                var op = ""
                for c in n.text { guard let mapped = mapping[c] else { return false }; op.append(mapped) }
                return push(Node(.operatorName,op + " infix"))
            case "R":
                guard let param = genericParameter(requirement:true), let proto = protocolType() else { return false }
                return push(Node(.requirement,": ",[param,proto]))
            case "l": return signature([1])
            case "r":
                var counts: [Int] = []
                while !take("l") {
                    if take("_") { counts.append(1) }
                    else { guard let n = number(), take("_") else { return false }; counts.append(n+2) }
                    guard counts.count <= maxTypeDepth else { return false }
                }
                return signature(counts.isEmpty ? [0] : counts)
            case "E":
                let sig = stack.last?.kind == .signature ? stack.removeLast() : nil
                guard let module = popContext(), module.kind == .module, let type = popType() else { return false }
                return push(Node(.extensionContext,"",[module,type] + (sig.map { [$0] } ?? [])))
            case "Q":
                if take("p") {
                    guard let shape = popType(), let pattern = popType() else { return false }
                    return push(Node(.expansion,"",[pattern,shape]))
                }
                if take("P") {
                    var types: [Node] = []
                    while stack.last?.kind != .first { guard let t = popType() else { return false }; types.append(t) }
                    guard stack.last?.kind == .first else { return false }; stack.removeLast()
                    guard let t = popType() else { return false }; types.append(t)
                    return push(Node(.pack,"",types.reversed()))
                }
                if take("z") {
                    guard let name = popName(), name.kind == .identifier else { return false }
                    return push(Node(.dependent,"",[Node(.parameter,"",[],[0,0]),name]),substitute:true)
                }
                if take("Z") {
                    guard let name = popName(), name.kind == .identifier, stack.last?.kind == .first else { return false }; stack.removeLast()
                    guard let first = popName(), first.kind == .identifier else { return false }
                    let base = Node(.dependent,"",[Node(.parameter,"",[],[0,0]),first])
                    return push(Node(.dependent,"",[base,name]),substitute:true)
                }
                return false
            case "M":
                if take("c") { guard let n = conformance() else { return false }; return wrap("protocol conformance descriptor for ",n) }
                if take("K") {
                    guard let n = stack.popLast(), n.isType || (n.kind == .wrapper && n.text == "protocol conformance descriptor for ") else { return false }
                    return wrap("metadata instantiation cache for ",n)
                }
                if take("XX") { guard let n = popContext() else { return false }; return wrap("anonymous descriptor ",n) }
                let phrases: [(String,String)] = [("a","type metadata accessor for "),("f","full type metadata for "),("n","nominal type descriptor for "),("F","reflection metadata field descriptor ")]
                for (suffix,phrase) in phrases where take(suffix) {
                    guard let n = stack.popLast(), n.isType else { return false }
                    return wrap(phrase,n)
                }
                return false
            case "N": guard let n = popType() else { return false }; return wrap("type metadata for ",n)
            case "T":
                if take("u") { guard let n = stack.popLast(), n.kind == .function, stack.isEmpty else { return false }; return wrap("async function pointer to ",n) }
                if take("A") { guard let n = stack.popLast(), n.kind == .function, stack.isEmpty else { return false }; return wrap("partial apply forwarder for ",n) }
                if take("W") {
                    guard let witness = stack.popLast(), witness.kind == .function || witness.kind == .accessor || (witness.kind == .wrapper && witness.text == "static "),
                          let conformance = conformance() else { return false }
                    return push(Node(.wrapper,"witness",[witness,conformance]))
                }
                if take("n") {
                    guard let target = protocolType(implicit:false), stack.last?.kind == .first else { return false }; stack.removeLast()
                    guard let qualification = protocolType(implicit:false), let name = popName(), name.kind == .identifier, let owner = protocolType(implicit:false) else { return false }
                    return push(Node(.wrapper,"associated",[owner,qualification,name,target]))
                }
                return false
            case "W":
                if take("b") { guard let base = protocolType(), let c = conformance() else { return false }; return push(Node(.wrapper,"baseWitness",[base,c])) }
                if take("Oh") {
                    if stack.last?.kind == .signature { stack.removeLast() }
                    guard let type = popType() else { return false }; return wrap("outlined destroy of ",type)
                }
                return false
            default: return false
            }
        }
        private func optionalText(_ node: Node, _ text: String) -> String {
            let needsParens = node.kind == .functionType || node.kind == .expansion || (node.kind == .bound && !node.text.isEmpty && node.text != "optional")
            return (needsParens ? "(" + text + ")" : text) + "?"
        }
        /// Keep the dotted nominal path separate from its enclosing local context.
        /// A local-name discriminator itself establishes a local-context boundary.
        private func nominalParts(_ node: Node) -> (name: String, context: String?)? {
            guard node.kind == .nominal, node.children.count == 2,
                  let name = render(node.children[1]) else { return nil }
            let parent = node.children[0]
            if node.children[1].kind == .localName || parent.kind == .function || parent.kind == .closure || (parent.kind == .nominal && parent.children.last?.kind == .localName) {
                guard let context = render(parent) else { return nil }; return (name,context)
            }
            if parent.kind == .nominal, parent.localContext {
                guard let parts = nominalParts(parent) else { return nil }; return (parts.name + "." + name,parts.context)
            }
            guard let context = render(parent) else { return nil }; return (context + "." + name,nil)
        }
        private func qualify(_ context: Node, _ member: String, localName: Bool = false) -> String? {
            guard budget.charge(), let rendered = render(context) else { return nil }
            if localName { return member + " in " + rendered }
            if context.kind == .nominal, context.localContext, context.children.last?.kind != .localName {
                guard let parts = nominalParts(context) else { return nil }
                return parts.name + "." + member + (parts.context.map { " in " + $0 } ?? "")
            }
            return context.localContext ? member + " in " + rendered : rendered + "." + member
        }
        func render(_ node: Node) -> String? {
            if let cached = node.cachedRendering { return cached }
            guard node.depth <= maxTypeDepth else { budget.exceeded = true; return nil }
            var rendered: [String] = []
            var childBytes = 0
            for child in node.children {
                guard budget.charge(), let s = render(child) else { return nil }
                let bytes = s.utf8.count
                guard bytes <= maxRenderedLength - childBytes else { budget.exceeded = true; return nil }
                childBytes += bytes; rendered.append(s)
            }
            let s: String
            func parameterList(_ args: Node, _ text: String) -> String {
                args.kind == .tuple ? text : "(" + text + ")"
            }
            switch node.kind {
            case .identifier, .operatorName, .module: s = node.text
            case .localName: s = node.text + " #\(node.indices[0])"
            case .nominal:
                if node.text == "any" { s = "Any" }
                else if let parts = nominalParts(node) { s = parts.name + (parts.context.map { " in " + $0 } ?? "") }
                else { return nil }
            case .parameter:
                guard node.indices[1] < 26 else { return nil }
                s = String(UnicodeScalar(65+node.indices[1])!) + (node.indices[0] == 0 ? "" : String(node.indices[0]))
            case .dependent: s = rendered.joined(separator:".")
            case .bound:
                if node.text == "optional" { s = optionalText(node.children[0], rendered[0]) }
                else if !node.text.isEmpty { s = node.text + " " + rendered[0] }
                else if node.children[0].text == "V", node.children[0].children.first?.text == "Swift", node.children[0].children.last?.text == "Array", rendered.count == 2 { s = "[" + rendered[1] + "]" }
                else if node.children[0].text == "V", node.children[0].children.first?.text == "Swift", node.children[0].children.last?.text == "Dictionary", rendered.count == 3 { s = "[" + rendered[1] + " : " + rendered[2] + "]" }
                else if node.children[0].text == "O", node.children[0].children.first?.text == "Swift", node.children[0].children.last?.text == "Optional", rendered.count == 2 { s = optionalText(node.children[1],rendered[1]) }
                else { s = rendered[0] + (rendered.count == 1 ? "" : "<" + rendered.dropFirst().joined(separator:", ") + ">") }
            case .tuple: s = "(" + rendered.joined(separator:", ") + ")"
            case .attribute: s = node.text == "throws" && !rendered.isEmpty ? " throws(" + rendered[0] + ")" : " " + node.text
            case .functionType: s = node.text + parameterList(node.children[0],rendered[0]) + rendered.dropFirst(2).joined() + " -> " + rendered[1]
            case .function:
                let context = node.children[0], name = node.children[1], fn = node.children[2], args = fn.children[0]
                guard let result = render(fn.children[1]) else { return nil }
                let argNodes = args.kind == .tuple ? args.children : [args]
                let labels = node.children[3].children
                guard labels.isEmpty || labels.count == argNodes.count else { return nil }
                var params: [String] = []
                var paramBytes = 0
                for (i,arg) in argNodes.enumerated() {
                    guard let a = render(arg) else { return nil }
                    let text = (labels.isEmpty ? "" : labels[i].text + ": ") + a
                    guard text.utf8.count + 2 <= maxRenderedLength - paramBytes else { budget.exceeded = true; return nil }
                    paramBytes += text.utf8.count + 2; params.append(text)
                }
                let clause = rendered.count == 5 ? rendered[4] : ""
                let attrs = fn.children.dropFirst(2).compactMap { render($0) }.joined()
                let localNameGap = name.kind == .localName ? " " : ""
                let decl = rendered[1] + localNameGap + clause + "(" + params.joined(separator:", ") + ")" + attrs + " -> " + result
                guard let qualified = qualify(context,decl,localName:name.kind == .localName) else { return nil }; s = qualified
            case .closure: s = "closure #\(node.indices[0]) " + rendered[1] + " in " + rendered[0]
            case .variable:
                guard let qualified = qualify(node.children[0],rendered[1] + " : " + rendered[2],localName:node.children[1].kind == .localName) else { return nil }; s = qualified
            case .accessor:
                let v = node.children[0]
                guard v.kind == .variable, let context = render(v.children[0]), let name = render(v.children[1]), let type = render(v.children[2]) else { return nil }
                if v.children[1].kind == .localName { s = node.text + " of " + name + " : " + type + " in " + context }
                else {
                    let member = name + "." + node.text + " : " + type
                    guard let qualified = qualify(v.children[0],member) else { return nil }; s = qualified
                }
            case .signature:
                var clauses: [String] = []
                for (depth,count) in node.indices.enumerated() {
                    var params: [String] = []
                    for i in 0..<count { params.append(String(UnicodeScalar(65+i)!) + (depth == 0 ? "" : String(depth))) }
                    let requirements = depth == node.indices.count - 1 && !rendered.isEmpty ? " where " + rendered.joined(separator:", ") : ""
                    clauses.append("<" + params.joined(separator:", ") + requirements + ">")
                }
                s = clauses.joined()
            case .requirement: s = rendered[0] + node.text + rendered[1]
            case .extensionContext: s = "(extension in " + rendered[0] + "):" + rendered[1] + (rendered.count == 3 ? rendered[2] : "")
            case .conformance: s = (rendered.count == 4 ? rendered[3] + " " : "") + rendered[0] + " : " + rendered[1] + " in " + rendered[2]
            case .pack: s = "Pack{" + rendered.joined(separator:", ") + "}"
            case .expansion: s = "repeat " + rendered[0]
            case .wrapper:
                if node.text == "witness" { s = "protocol witness for " + rendered[0] + " in conformance " + rendered[1] }
                else if node.text == "baseWitness" { s = "base witness table accessor for " + rendered[0] + " in " + rendered[1] }
                else if node.text == "associated" { s = "associated conformance descriptor for " + rendered[0] + "." + rendered[1] + "." + rendered[2] + ": " + rendered[3] }
                else { s = node.text + rendered[0] }
            case .empty, .first: return nil
            }
            guard s.utf8.count <= maxRenderedLength else { budget.exceeded = true; return nil }
            node.cachedRendering = s
            return s
        }
    }
}


extension SwiftDemangler {
    /// The legacy runtime type-name profile has prefix nominal kinds and decimal
    /// lengths (leading zeroes permitted), unlike the modern postfix grammar.
    static func demangleResidualLegacyName(_ symbol: String) -> String? {
        guard symbol.hasPrefix("_Tt"), symbol.utf8.count <= maxMangledLength else { return nil }
        let chars = Array(symbol.unicodeScalars)
        var pos = 3, levels = 0
        while pos < chars.count, chars[pos] == "C" || chars[pos] == "V" {
            levels += 1; pos += 1
            guard levels <= maxTypeDepth else { return nil }
        }
        guard levels > 0 else { return nil }
        var names: [String] = []
        for _ in 0...levels {
            let start = pos
            while pos < chars.count, chars[pos].isASCIIDigit { pos += 1 }
            guard pos > start, let length = Int(String(String.UnicodeScalarView(chars[start..<pos]))),
                  length > 0, length <= chars.count-pos else { return nil }
            let name = chars[pos..<pos+length]
            guard name.allSatisfy(\.isIdentifierScalar) else { return nil }
            names.append(String(String.UnicodeScalarView(name))); pos += length
        }
        var result = names.joined(separator: ".")
        if pos < chars.count {
            let suffix = String(String.UnicodeScalarView(chars[pos...]))
            var escaped = ""
            for byte in suffix.utf8 {
                switch byte {
                case 34, 92: escaped += "\\" + String(UnicodeScalar(byte))
                case 32...126: escaped += String(UnicodeScalar(byte))
                default: escaped += String(format: "\\x%02X",byte)
                }
            }
            result += " with unmangled suffix \"" + escaped + "\""
        }
        return result.utf8.count <= maxRenderedLength ? result : nil
    }
}
