import Foundation

extension OrdinaryC {
    struct Access {
        var reads: Set<String> = []
        var writes: Set<String> = []
        var effects = 0
        func combined(_ other: Access, sequenced: Bool) throws -> Access {
            if !sequenced {
                guard writes.isDisjoint(with: other.reads.union(other.writes)),
                      other.writes.isDisjoint(with: reads), effects == 0 || other.effects == 0 else {
                    throw Failure.undefinedC("unsequenced conflicting scalar or memory effects")
                }
            }
            return .init(reads: reads.union(other.reads), writes: writes.union(other.writes), effects: effects + other.effects)
        }
    }
    struct Resolver {
        let contract: Contract
        let tokens: [Token]
        var symbols: [String: Symbol] = [:]
        var types: [Span: CType] = [:]
        var definitions: [String: [(Expression, [Int])]] = [:]
        var declared: [String: (CType, Int)] = [:]
        var callDefinitions: [String: Int] = [:]
        var reads: Set<String> = []
        var allExpressions: [Expression] = []
        var staticOrigins: [String: Set<Int>] = [:]
        var representationCasts: Set<Span> = []

        mutating func resolve(_ root: Statement) throws {
            for binding in contract.inputs {
                guard symbols[binding.name] == nil else { throw Failure.invalidContract("duplicate external name") }
                symbols[binding.name] = .init(type: binding.type, scope: 0, external: true, declared: true)
            }
            try gather(root)
            for (name, definition) in declared {
                guard symbols[name] == nil else { throw Failure.unsupportedSyntax("shadowed/colliding declaration \(name)") }
                symbols[name] = .init(type: definition.0, scope: definition.1, external: false, declared: true)
            }
            for (name, row) in callDefinitions {
                guard let call = contract.calls[row], definitions[name] == nil,
                      symbols[name].map({ $0.type == call.resultType && $0.declared && !$0.external }) ?? true else { throw Failure.invalidContract("call result has another defining site or wrong declared type") }
                if symbols[name] == nil { symbols[name] = .init(type: call.resultType, scope: 1, external: false, declared: false) }
                staticOrigins[name] = [row]
            }
            for (name, sites) in definitions where symbols[name] == nil {
                guard sites.count == 1 else { throw Failure.unsupportedSyntax("undeclared \(name) has \(sites.count) static defining sites") }
            }
            var pending = Set(definitions.keys.filter { symbols[$0] == nil })
            while !pending.isEmpty {
                var changed = false
                for name in pending.sorted() {
                    guard let definition = definitions[name]?.first else { throw Failure.invalidContract("missing definition") }
                    if let type = try infer(definition.0, allowUnknown: true) {
                        symbols[name] = .init(type: type, scope: 1, external: false, declared: false)
                        pending.remove(name); changed = true
                    }
                }
                guard changed else { throw Failure.unsupportedSyntax("unresolved/cyclic SSA types: \(pending.sorted())") }
            }
            for expression in allExpressions { _ = try infer(expression, allowUnknown: false); _ = try access(expression) }
            for expression in allExpressions { if try isRepresentationCast(expression) { representationCasts.insert(expression.span) } }
            let protectedCallableNames = Set(contract.calls.values.filter { $0.control == nil }.map(\.target))
            guard Set(symbols.keys).isDisjoint(with: protectedCallableNames) else { throw Failure.unsupportedSyntax("symbol collides with protected callable") }
            for row in contract.deadResults {
                guard let name = contract.calls[row]?.resultName else { throw Failure.invalidContract("dead result missing original binding") }
                guard !reads.contains(name) else { throw Failure.callAuthorityViolation("baseline-dead call row \(row) read anywhere in complete AST") }
            }
            // Independent static def-use closure. It transports permissions only;
            // neither this graph nor source tags can supply candidate bits.
            var changed = true
            while changed {
                changed = false
                for (name, sites) in definitions {
                    let origins = sites.reduce(into: Set<Int>()) { $0.formUnion(self.origins(of: $1.0)) }
                    let merged = staticOrigins[name, default: []].union(origins)
                    if merged != staticOrigins[name, default: []] { staticOrigins[name] = merged; changed = true }
                }
            }
            try validate(root)
        }
        mutating func gather(_ statement: Statement) throws {
            func scalar(_ lhs: Expression) -> String? { if case let .name(name) = lhs.node { return name }; return nil }
            switch statement.node {
            case let .compound(_, body): for child in body { try gather(child) }
            case let .declarations(type, names):
                for name in names {
                    guard declared[name] == nil, !Parser.reserved.contains(name), CType.named(name) == nil else { throw Failure.unsupportedSyntax("duplicate declaration \(name)") }
                    declared[name] = (type, statement.scopes.last ?? 1)
                }
            case let .declaration(type, name, initializer):
                guard declared[name] == nil, !Parser.reserved.contains(name), CType.named(name) == nil else { throw Failure.unsupportedSyntax("duplicate declaration \(name)") }
                declared[name] = (type, statement.scopes.last ?? 1)
                if let initializer { definitions[name, default: []].append((initializer, statement.scopes)); gather(initializer) }
            case let .assign(left, right):
                for (lhs, rhs) in zip(left, right) {
                    if let name = scalar(lhs) {
                        definitions[name, default: []].append((rhs, statement.scopes))
                    } else if case let .load(_, address) = lhs.node { gather(address); allExpressions.append(lhs) }
                    else { throw Failure.unsupportedSyntax("invalid assignment target") }
                    gather(rhs)
                }
            case let .update(expression): gather(expression)
            case let .conditional(e, yes, no): gather(e); try gather(yes); if let no { try gather(no) }
            case let .whileLoop(e, body): gather(e); try gather(body)
            case let .doLoop(body, e): try gather(body); gather(e)
            case let .forLoop(initial, e, step, body):
                if let initial { try gather(initial) }; if let e { gather(e) }
                if let step { try gather(step) }; try gather(body)
            case let .label(_, child): try gather(child)
            case let .call(row, result, control, arguments):
                if let result {
                    guard callDefinitions[result] == nil else { throw Failure.invalidContract("duplicated protected result definition") }
                    callDefinitions[result] = row
                }
                if let control { gather(control) }; arguments.forEach { gather($0) }
            case let .returned(e): if let e { gather(e) }
            case .empty, .breakLoop, .continueLoop, .jump, .unavailableReturn: break
            }
        }
        mutating func gather(_ expression: Expression) {
            allExpressions.append(expression)
            switch expression.node {
            case let .name(name): reads.insert(name)
            case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): gather(e)
            case let .binary(_, a, b): gather(a); gather(b)
            case let .select(c, a, b): gather(c); gather(a); gather(b)
            case let .helper(_, args): args.forEach { gather($0) }
            case let .update(name, _, _): reads.insert(name)
            case .literal: break
            }
        }
        mutating func infer(_ e: Expression, allowUnknown: Bool) throws -> CType? {
            if let type = types[e.span] { return type }
            let type: CType?
            switch e.node {
            case let .literal(value): type = value.type
            case let .name(name), let .update(name, _, _):
                type = symbols[name]?.type
                if type == nil && !allowUnknown { throw Failure.unsupportedSyntax("unresolved identifier \(name)") }
                if case .update = e.node, let symbol = symbols[name] {
                    guard symbol.declared, !symbol.external, !symbol.type.pointer else { throw Failure.unsupportedSyntax("update requires declared integer carrier") }
                }
            case let .cast(destination, operand):
                guard let source = try infer(operand, allowUnknown: allowUnknown) else { return nil }
                if destination.pointer {
                    guard destination.bytePointer, source.objectPointer || source.bytePointer else {
                        throw Failure.unsupportedSyntax("byte pointer cast requires proved object provenance")
                    }
                } else {
                    guard !source.pointer || destination == .u64 else { throw Failure.unsupportedSyntax("pointer requires explicit uint64 representation cast") }
                }
                type = destination
            case let .unary(op, operand):
                guard let source = try infer(operand, allowUnknown: allowUnknown) else { return nil }
                guard !source.pointer else { throw Failure.unsupportedSyntax("pointer unary arithmetic") }
                type = op == "!" ? .i32 : source.promoted
            case let .binary(op, a, b):
                guard let left = try infer(a, allowUnknown: allowUnknown), let right = try infer(b, allowUnknown: allowUnknown) else { return nil }
                if left.pointer || right.pointer {
                    guard left.bytePointer, !right.pointer, op == "+" || op == "-" else {
                        throw Failure.unsupportedSyntax("pointer arithmetic/comparison requires explicit representation cast")
                    }
                    type = left
                    break
                }
                if ["<", ">", "<=", ">=", "==", "!=", "&&", "||"].contains(op) { type = .i32 }
                else if op == "<<" || op == ">>" { type = left.promoted } // C shifts do NOT use binary UAC.
                else { type = try CType.common(left, right) }
            case let .select(condition, yes, no):
                guard try infer(condition, allowUnknown: allowUnknown) != nil,
                      let a = try infer(yes, allowUnknown: allowUnknown), let b = try infer(no, allowUnknown: allowUnknown) else { return nil }
                type = try CType.common(a, b)
            case let .load(loaded, address):
                guard let addressType = try infer(address, allowUnknown: allowUnknown) else { return nil }
                guard addressType.bytePointer || (!addressType.pointer && addressType.width == 64) else { throw Failure.unsupportedSyntax("memory requires explicit integer byte address") }
                type = loaded.unqualified
            case let .field(base, field):
                guard let baseType = try infer(base, allowUnknown: allowUnknown) else { return nil }
                guard let layout = contract.fields.first(where: { $0.owner == baseType.pointee && $0.name == field }) else {
                    throw Failure.unsupportedSyntax("unproven pointer field \(field)")
                }
                type = layout.type
            case let .helper(name, args):
                for arg in args {
                    guard let type = try infer(arg, allowUnknown: allowUnknown) else { return nil }
                    guard !type.pointer else { throw Failure.unsupportedSyntax("pointer helper argument") }
                }
                guard let address = tokens[e.span.first].source, let row = contract.rowsByAddress[address],
                      contract.helpers[row]?.contains(name) == true else { throw Failure.invalidContract("helper at unowned source site") }
                type = name == "__adrp" ? .u64 : .i32
            }
            if let type { types[e.span] = type }; return type
        }
        /// Recognize only the independently provable pure, bit-preserving
        /// unsigned-to-signed boundary encoding. This is representation transport,
        /// not permission to choose an unrelated pointer/value from opaque flags.
        func isRepresentationCast(_ e: Expression) throws -> Bool {
            guard case let .select(condition, positive, negative) = e.node,
                  case let .cast(signed, normalized) = positive.node, !signed.unsigned, !signed.pointer,
                  [32,64].contains(signed.width), let unsigned = types[normalized.span],
                  unsigned == CType(signed.width, true), try access(normalized).effects == 0,
                  case let .binary("-", minusOne, complemented) = negative.node,
                  case let .unary("-", one) = minusOne.node, case let .literal(oneValue) = one.node, oneValue.bits == 1,
                  case let .cast(negativeType, complementCast) = complemented.node, negativeType == signed,
                  case let .cast(complementType, complement) = complementCast.node, complementType == unsigned,
                  case let .unary("~", sameBits) = complement.node, sameExpression(normalized, sameBits),
                  case let .binary("==", masked, zero) = condition.node,
                  case let .literal(zeroValue) = zero.node, zeroValue.bits == 0,
                  case let .binary("&", tested, sign) = masked.node, sameExpression(tested, normalized),
                  let signValue = try constant(sign), signValue.bits == signed.sign else { return false }
            return true
        }
        private func constant(_ e: Expression) throws -> Value? {
            switch e.node {
            case let .literal(value): return value
            case let .cast(type, e): guard let value = try constant(e) else { return nil }; return try OrdinaryC.converted(value, to: type)
            case let .binary("<<", a, b):
                guard let a = try constant(a), let b = try constant(b) else { return nil }
                return try OrdinaryC.binary("<<", a, b)
            default: return nil
            }
        }
        private func sameExpression(_ a: Expression, _ b: Expression) -> Bool {
            switch (a.node, b.node) {
            case let (.literal(a), .literal(b)): return a == b
            case let (.name(a), .name(b)): return a == b
            case let (.cast(at, a), .cast(bt, b)): return at == bt && sameExpression(a,b)
            case let (.unary(ao,a), .unary(bo,b)): return ao == bo && sameExpression(a,b)
            case let (.binary(ao,al,ar), .binary(bo,bl,br)): return ao == bo && sameExpression(al,bl) && sameExpression(ar,br)
            default: return false
            }
        }
        func access(_ e: Expression) throws -> Access {
            switch e.node {
            case .literal: return .init()
            case let .name(name): return .init(reads: [name])
            case let .update(name, _, _): return .init(reads: [name], writes: [name], effects: 1)
            case let .unary(_, x), let .cast(_, x): return try access(x)
            case let .load(_, x), let .field(x, _): var result = try access(x); result.effects += 1; return result
            case let .binary(op, a, b): return try access(a).combined(access(b), sequenced: op == "&&" || op == "||")
            case let .select(c, a, b):
                let condition = try access(c), yes = try access(a), no = try access(b)
                return .init(reads: condition.reads.union(yes.reads).union(no.reads),
                    writes: condition.writes.union(yes.writes).union(no.writes), effects: condition.effects + max(yes.effects, no.effects))
            case let .helper(_, args): return try args.reduce(Access()) { try $0.combined(access($1), sequenced: false) }
            }
        }
        func origins(of e: Expression) -> Set<Int> {
            switch e.node {
            case let .name(name), let .update(name, _, _): return staticOrigins[name, default: []]
            case let .unary(_, e), let .cast(_, e): return origins(of: e)
            case let .binary(_, a, b): return origins(of: a).union(origins(of: b))
            case let .select(_, a, b): return origins(of: a).union(origins(of: b))
            case let .helper(_, args): return args.reduce(into: Set<Int>()) { $0.formUnion(origins(of: $1)) }
            // Address provenance is an address sink, not fetched data provenance.
            case .load, .field, .literal: return []
            }
        }
        func row(_ span: Span) throws -> Int {
            guard let address = tokens[span.first].source, let row = contract.rowsByAddress[address] else {
                throw Failure.invalidContract("missing source identity at token \(span.first)")
            }
            return row
        }
        func permit(_ e: Expression, role: Role, at span: Span? = nil) throws {
            let origins = origins(of: e)
            guard !origins.isEmpty else { return }
            let site = try row(span ?? e.span)
            for origin in origins {
                guard contract.permissions.contains(.init(callRow: origin, sinkRow: site, role: role)) else {
                    throw Failure.callAuthorityViolation("call row \(origin) acquired \(role) at source row \(site)")
                }
            }
        }
        func validateExpression(_ e: Expression, scopes: [Int]) throws {
            switch e.node {
            case let .name(name), let .update(name, _, _):
                guard let symbol = symbols[name], symbol.scope <= 1 || scopes.contains(symbol.scope) else {
                    throw Failure.unsupportedSyntax("out-of-scope identifier \(name)")
                }
            case let .cast(_, e), let .unary(_, e): try validateExpression(e, scopes: scopes)
            case let .binary(_, a, b): try validateExpression(a, scopes: scopes); try validateExpression(b, scopes: scopes)
            case let .select(c, a, b):
                if !representationCasts.contains(e.span) { try permit(c, role: .selectionCondition, at: e.span) }
                try validateExpression(c, scopes: scopes); try validateExpression(a, scopes: scopes); try validateExpression(b, scopes: scopes)
            case let .load(_, address): try permit(address, role: .memoryAddress, at: e.span); try validateExpression(address, scopes: scopes)
            case let .field(base, _): try permit(base, role: .memoryAddress, at: e.span); try validateExpression(base, scopes: scopes)
            case let .helper(_, args): for arg in args { try validateExpression(arg, scopes: scopes) }
            case .literal: break
            }
        }
        func validate(_ s: Statement) throws {
            switch s.node {
            case let .compound(_, body): for child in body { try validate(child) }
            case let .declaration(_, name, initializer):
                if let initializer {
                    try validateExpression(initializer, scopes: s.scopes)
                    guard try !access(initializer).writes.contains(name) else { throw Failure.undefinedC("initializer modifies its own target") }
                    if let source = types[initializer.span], source.pointer { throw Failure.unsupportedSyntax("implicit pointer-to-integer initializer") }
                }
            case let .assign(left, right):
                for (lhs, rhs) in zip(left, right) {
                    try validateExpression(rhs, scopes: s.scopes)
                    if case let .name(name) = lhs.node {
                        guard try !access(rhs).writes.contains(name) else { throw Failure.undefinedC("unsequenced assignment and RHS modification of \(name)") }
                        guard let symbol = symbols[name], !symbol.external,
                              symbol.scope <= 1 || s.scopes.contains(symbol.scope) else { throw Failure.unsupportedSyntax("assignment to external/out-of-scope symbol") }
                        if let source = types[rhs.span], source.pointer || symbol.type.pointer {
                            guard source == symbol.type else { throw Failure.unsupportedSyntax("implicit pointer/integer assignment") }
                        }
                    } else if case let .load(loaded, address) = lhs.node {
                        guard !loaded.constQualified, types[address.span]?.constQualified != true else {
                            throw Failure.unsupportedSyntax("store through const pointer")
                        }
                        try validateExpression(lhs, scopes: s.scopes); try permit(rhs, role: .memoryData, at: lhs.span)
                        guard types[rhs.span]?.pointer != true else { throw Failure.unsupportedSyntax("implicit pointer memory store") }
                        _ = try access(address).combined(access(rhs), sequenced: false)
                    }
                }
            case let .update(e): try validateExpression(e, scopes: s.scopes)
            case let .conditional(e, yes, no):
                try validateExpression(e, scopes: s.scopes); try permit(e, role: .branch)
                try validate(yes); if let no { try validate(no) }
            case let .whileLoop(e, body), let .doLoop(body, e):
                try validateExpression(e, scopes: s.scopes); try permit(e, role: .branch); try validate(body)
            case let .forLoop(initial, e, step, body):
                if let initial { try validate(initial) }; if let e { try validateExpression(e, scopes: s.scopes); try permit(e, role: .branch) }
                if let step { try validate(step) }; try validate(body)
            case let .label(_, child): try validate(child)
            case let .call(row, _, control, arguments):
                if let control { try validateExpression(control, scopes: s.scopes); try permit(control, role: .callee) }
                for (index, arg) in arguments.enumerated() { try validateExpression(arg, scopes: s.scopes); try permit(arg, role: .callArgument(index), at: s.span) }
                guard contract.calls[row] != nil else { throw Failure.invalidContract("unknown call") }
            case let .returned(e):
                guard !contract.noCallUnavailableTerminal else { throw Failure.invalidContract("nonnumeric terminal became a numeric/void return") }
                guard try row(s.span) == contract.terminalRow else { throw Failure.invalidContract("new terminal source site") }
                guard (e == nil) == (contract.returnType == nil) else { throw Failure.invalidContract("terminal arity changed") }
                if let e {
                    try validateExpression(e, scopes: s.scopes)
                    guard origins(of: e).isEmpty else { throw Failure.callAuthorityViolation("opaque return cannot acquire terminal role") }
                    guard case let .name(name) = e.node, name == contract.terminalName else { throw Failure.invalidContract("original terminal alias changed") }
                }
            case .unavailableReturn:
                guard contract.noCallUnavailableTerminal, try row(s.span) == contract.terminalRow else {
                    throw Failure.invalidContract("unpermitted nonnumeric terminal")
                }
            case .empty, .declarations, .breakLoop, .continueLoop, .jump: break
            }
        }
        func assignMemorySites(_ root: Statement) throws -> [Span: SourceSite] {
            var sites: [Span: SourceSite] = [:], counts: [Int: Int] = [:]
            func memory(_ e: Expression, loading: Bool) throws {
                let row = try self.row(e.span), ordinal = counts[row, default: 0]
                guard let expected = contract.memoryEffects[row], expected.indices.contains(ordinal) else { throw Failure.invalidContract("extra memory effect row \(row)") }
                let type: CType
                switch e.node {
                case let .load(t, _): type = t
                case .field: guard let t = types[e.span] else { throw Failure.invalidContract("unresolved field") }; type = t
                default: throw Failure.invalidContract("nonmemory effect")
                }
                guard expected[ordinal].loading == loading, expected[ordinal].bytes == type.width / 8 else {
                    throw Failure.invalidContract("memory width/order differs at row \(row), effect \(ordinal)")
                }
                sites[e.span] = .init(row: row, effectOrdinal: ordinal); counts[row] = ordinal + 1
            }
            func expr(_ e: Expression) throws {
                switch e.node {
                case let .load(_, a), let .field(a, _): try expr(a); try memory(e, loading: true)
                case let .unary(_, a), let .cast(_, a): try expr(a)
                case let .binary(_, a, b): try expr(a); try expr(b)
                case let .select(c, a, b): try expr(c); try expr(a); try expr(b)
                case let .helper(_, args): for a in args { try expr(a) }
                case .literal, .name, .update: break
                }
            }
            func walk(_ s: Statement) throws {
                switch s.node {
                case let .compound(_, body): for s in body { try walk(s) }
                case let .declaration(_, _, e), let .returned(e): if let e { try expr(e) }
                case let .assign(left, right):
                    // Captured RHS loads occur before frozen tuple stores.
                    for e in right { try expr(e) }
                    for e in left { if case let .load(_, a) = e.node { try expr(a); try memory(e, loading: false) } }
                case let .update(e): try expr(e)
                case let .conditional(e, a, b): try expr(e); try walk(a); if let b { try walk(b) }
                case let .whileLoop(e, b): try expr(e); try walk(b)
                case let .doLoop(b, e): try walk(b); try expr(e)
                case let .forLoop(i, e, step, b): if let i { try walk(i) }; if let e { try expr(e) }; try walk(b); if let step { try walk(step) }
                case let .label(_, s): try walk(s)
                case let .call(_, _, c, args): if let c { try expr(c) }; for a in args { try expr(a) }
                case .empty, .declarations, .breakLoop, .continueLoop, .jump, .unavailableReturn: break
                }
            }
            try walk(root)
            for (row, expected) in contract.memoryEffects where counts[row, default: 0] != expected.count {
                throw Failure.invalidContract("missing static memory effects at row \(row)")
            }
            return sites
        }
    }

    struct Compiler {
        var code: [Instruction] = []
        var labels: [String: Int] = [:]
        struct Loop { var breaks: [Int] = []; var continues: [Int] = [] }
        var loops: [Loop] = []
        @discardableResult mutating func append(_ s: Statement, _ node: Instruction.Node) -> Int {
            let index = code.count; code.append(.init(span: s.span, scopes: s.scopes, node: node)); return index
        }
        mutating func emit(_ s: Statement) throws {
            switch s.node {
            case let .compound(_, body): append(s, .nop); for child in body { try emit(child) }
            case .empty: append(s, .nop)
            case let .declaration(_, name, e): append(s, .declaration(name, e))
            case let .declarations(_, names): for name in names { append(s, .declaration(name, nil)) }
            case let .assign(left, right): append(s, .assign(left, right))
            case let .update(e): append(s, .update(e))
            case let .conditional(e, yes, no):
                let condition = append(s, .nop), yesStart = code.count
                try emit(yes); let leave = append(s, .nop), noStart = code.count
                if let no { try emit(no) }
                let end = code.count; code[condition].node = .branch(e, yesStart, noStart); code[leave].node = .jump(end)
            case let .whileLoop(e, body):
                let condition = append(s, .nop), bodyStart = code.count; loops.append(.init())
                try emit(body); append(s, .jump(condition)); let end = code.count
                try closeLoop(breakTarget: end, continueTarget: condition)
                code[condition].node = .branch(e, bodyStart, end)
            case let .doLoop(body, e):
                let bodyStart = code.count; loops.append(.init()); try emit(body)
                let condition = append(s, .nop), end = code.count
                code[condition].node = .branch(e, bodyStart, end)
                try closeLoop(breakTarget: end, continueTarget: condition)
            case let .forLoop(initial, e, step, body):
                if let initial { try emit(initial) }
                let condition = append(s, .nop), bodyStart = code.count; loops.append(.init())
                try emit(body); let stepStart = code.count
                if let step { try emit(step) }; append(s, .jump(condition)); let end = code.count
                if let e { code[condition].node = .branch(e, bodyStart, end) } else { code[condition].node = .jump(bodyStart) }
                try closeLoop(breakTarget: end, continueTarget: stepStart)
            case .breakLoop, .continueLoop:
                guard !loops.isEmpty else { throw Failure.unsupportedSyntax("break/continue outside loop") }
                let index = append(s, .nop)
                if case .breakLoop = s.node { loops[loops.count - 1].breaks.append(index) }
                else { loops[loops.count - 1].continues.append(index) }
            case let .jump(label): append(s, .unresolved(label))
            case let .label(label, body):
                guard labels.updateValue(code.count, forKey: label) == nil else { throw Failure.unsupportedSyntax("duplicate label \(label)") }
                try emit(body)
            case let .call(row, name, control, args): append(s, .call(row, name, control, args))
            case let .returned(e): append(s, .returned(e))
            case .unavailableReturn: append(s, .unavailableReturn)
            }
        }
        mutating func closeLoop(breakTarget: Int, continueTarget: Int) throws {
            guard let loop = loops.popLast() else { throw Failure.invalidContract("compiler loop stack") }
            for i in loop.breaks { code[i].node = .jump(breakTarget) }
            for i in loop.continues { code[i].node = .jump(continueTarget) }
        }
        mutating func finish() throws -> [Instruction] {
            for i in code.indices {
                if case let .unresolved(label) = code[i].node {
                    guard let target = labels[label] else { throw Failure.unsupportedSyntax("missing native label \(label)") }
                    code[i].node = .jump(target)
                }
            }
            return code
        }
    }
}
