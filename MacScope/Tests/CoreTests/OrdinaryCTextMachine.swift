import Foundation

extension OrdinaryC {
    struct ByteWrite: Equatable { let address: UInt64; let bytes: Int; let bits: UInt64 }
    struct Carrier: Equatable { let register: Int; let width: Int; let bits: UInt64 }
    struct OpaqueResponse {
        let row: Int
        let result: UInt64
        let writes: [ByteWrite]
        let expectedArguments: [UInt64]?
        let expectedControl: [UInt64]?
    }
    struct CallEvent: Equatable {
        let row: Int
        let occurrence: Int
        let target: String
        let control: [Carrier]
        let arguments: [Carrier]
        let result: UInt64
        let writes: [ByteWrite]
    }
    enum Event: Equatable {
        case load(SourceSite, Int, UInt64, Int, UInt64)
        case store(SourceSite, Int, UInt64, Int, UInt64)
        case call(CallEvent)
    }
    struct Scenario {
        let name: String
        let inputs: [String: Value]
        let memory: [UInt64: UInt8]
        let responses: [OpaqueResponse]
    }
    struct Commit { let span: Span; let sourceRow: Int?; let name: String; let value: Value }
    struct Transfer { let span: Span; let sourceRow: Int?; let taken: Bool?; let destination: Int }
    struct Evaluation { let span: Span; let sourceRow: Int?; let value: Value }
    struct BoundRegion {
        let entryPC: Int
        let stopPC: Int
        let incoming: [String: Value]
        let allowedPCs: Set<Int>
    }
    enum UnavailableTerminal: Equatable { case unresolvedReturnContract }
    struct Result {
        var memory: [UInt64: UInt8]
        var events: [Event] = []
        var commits: [Commit] = []
        var evaluations: [Evaluation] = []
        var transfers: [Transfer] = []
        var returned = false
        var reachedRegionBoundary = false
        var terminal: Value?
        var unavailableTerminal: UnavailableTerminal?
        var consumedResponses = 0
    }
    static func converted(_ value: Value, to target: CType) throws -> Value {
        if value.type == target { return value }
        if value.type.pointer {
            if target.bytePointer {
                guard value.type.objectPointer || value.type.bytePointer, let address = value.objectAddress else {
                    throw Failure.undefinedC("byte pointer cast requires proved object provenance")
                }
                return .init(value.bits, target, origins: value.origins, objectAddress: address)
            }
            guard target == .u64 else { throw Failure.undefinedC("unapproved pointer conversion") }
            return .init(value.bits, target, origins: value.origins)
        }
        guard !target.pointer else { throw Failure.undefinedC("integer to pointer conversion") }
        if target.unsigned { return .init(value.extended, target, origins: value.origins) }
        if value.negative {
            if target.width < 64 {
                let minimum = -(Int64(1) << (target.width - 1))
                guard value.signed >= minimum else { throw Failure.undefinedC("out-of-range signed narrowing") }
            }
        } else {
            guard value.bits <= target.maximumSigned else { throw Failure.undefinedC("unsigned/signed conversion not representable") }
        }
        return .init(value.extended, target, origins: value.origins)
    }
    static func signedResult(_ result: Int64, type: CType, origins: Set<Origin>) throws -> Value {
        if type.width < 64 {
            let min = -(Int64(1) << (type.width - 1)), max = (Int64(1) << (type.width - 1)) - 1
            guard result >= min, result <= max else { throw Failure.undefinedC("signed arithmetic overflow") }
        }
        return .init(UInt64(bitPattern: result), type, origins: origins)
    }
    static func binary(_ op: String, _ a: Value, _ b: Value) throws -> Value {
        if a.type.pointer || b.type.pointer {
            guard a.type.bytePointer, !b.type.pointer, op == "+" || op == "-",
                  let address = a.objectAddress, b.negative || b.bits <= UInt64(Int64.max) else {
                throw Failure.undefinedC("pointer arithmetic")
            }
            let delta = b.signed
            let offset = op == "+" ? address.offset.addingReportingOverflow(delta) : address.offset.subtractingReportingOverflow(delta)
            guard !offset.overflow else { throw Failure.undefinedC("byte pointer offset overflow") }
            let effective: (partialValue: UInt64, overflow: Bool)
            if offset.partialValue >= 0 {
                effective = address.base.addingReportingOverflow(UInt64(offset.partialValue))
            } else {
                effective = address.base.subtractingReportingOverflow(offset.partialValue.magnitude)
            }
            guard !effective.overflow else { throw Failure.undefinedC("byte pointer address overflow") }
            return .init(effective.partialValue, a.type, origins: a.origins.union(b.origins),
                         objectAddress: .init(base: address.base, owner: address.owner, offset: offset.partialValue))
        }
        let origins = a.origins.union(b.origins)
        if op == "<<" || op == ">>" {
            let left = try converted(a, to: a.type.promoted), right = try converted(b, to: b.type.promoted)
            guard !right.negative, right.bits < UInt64(left.type.width) else { throw Failure.undefinedC("shift count outside promoted-left width") }
            let count = Int(right.bits)
            if op == ">>" {
                guard !left.negative else { throw Failure.undefinedC("negative signed right shift is not a portable C observation") }
                return .init(left.bits >> count, left.type, origins: origins)
            }
            if left.type.unsigned { return .init(left.bits << count, left.type, origins: origins) }
            guard !left.negative, left.bits <= (left.type.maximumSigned >> count) else { throw Failure.undefinedC("negative/overflowing signed shift") }
            return .init(left.bits << count, left.type, origins: origins)
        }
        let type = try CType.common(a.type, b.type)
        let a = try converted(a, to: type), b = try converted(b, to: type)
        if ["==", "!=", "<", "<=", ">", ">="].contains(op) {
            let equal = a.bits == b.bits
            let less = type.unsigned ? a.bits < b.bits : a.signed < b.signed
            let yes: Bool
            switch op {
            case "==": yes = equal
            case "!=": yes = !equal
            case "<": yes = less
            case "<=": yes = less || equal
            case ">": yes = !less && !equal
            default: yes = !less
            }
            return .init(yes ? 1 : 0, .i32, origins: origins)
        }
        if op == "&" { return .init(a.bits & b.bits, type, origins: origins) }
        if op == "|" { return .init(a.bits | b.bits, type, origins: origins) }
        if op == "^" { return .init(a.bits ^ b.bits, type, origins: origins) }
        if type.unsigned {
            switch op {
            case "+": return .init(a.bits &+ b.bits, type, origins: origins)
            case "-": return .init(a.bits &- b.bits, type, origins: origins)
            case "*": return .init(a.bits &* b.bits, type, origins: origins)
            default: throw Failure.unsupportedSyntax("unsupported unsigned operator \(op)")
            }
        }
        let operation: (partialValue: Int64, overflow: Bool)
        switch op {
        case "+": operation = a.signed.addingReportingOverflow(b.signed)
        case "-": operation = a.signed.subtractingReportingOverflow(b.signed)
        case "*": operation = a.signed.multipliedReportingOverflow(by: b.signed)
        default: throw Failure.unsupportedSyntax("unsupported signed operator \(op)")
        }
        guard !operation.overflow else { throw Failure.undefinedC("signed64 arithmetic overflow") }
        return try signedResult(operation.partialValue, type: type, origins: origins)
    }
    struct Machine {
        let program: Program
        let scenario: Scenario
        var values: [String: Value]
        var memoryOrigins: [UInt64: Set<Origin>] = [:]
        var result: Result
        var effectOccurrences: [SourceSite: Int] = [:]
        var callOccurrences: [Int: Int] = [:]
        var scopes: [Int] = []
        private var historicalByteMap64 = false
        init(program: Program, scenario: Scenario) throws {
            self.program = program; self.scenario = scenario
            guard Set(scenario.inputs.keys) == Set(program.contract.inputs.map(\.name)) else { throw Failure.invalidContract("external-input map differs from frozen manifest") }
            for binding in program.contract.inputs {
                guard let value = scenario.inputs[binding.name], value.type == binding.type, value.origins.isEmpty else {
                    throw Failure.invalidContract("wrong external representation or forged call provenance")
                }
            }
            values = scenario.inputs; result = .init(memory: scenario.memory)
        }
        /// Separate retained architectural byte-map model, never C-definedness.
        /// The factory token binds the exact source/program; no alternate width
        /// ledger, arbitrary Program argument or refusal fallback is accepted.
        init(historicalByteMap: NativeScalarSourceOwnership.HistoricalByteMapProgram,
             scenario: Scenario) throws {
            try historicalByteMap.requireRetainedScenario(scenario)
            try self.init(program: historicalByteMap.program, scenario: scenario)
            historicalByteMap64 = true
        }
        func run(fuel: Int = 100_000) throws -> Result { var machine = self; return try machine.execute(fuel: fuel) }
        func run(region: BoundRegion, fuel: Int = 100_000) throws -> Result {
            var machine = self
            guard program.code.indices.contains(region.entryPC), program.code.indices.contains(region.stopPC),
                  region.allowedPCs.contains(region.entryPC), scenario.responses.isEmpty else { throw Failure.invalidContract("invalid scoped boundary/script") }
            for (name, value) in region.incoming {
                guard let symbol = program.symbols[name], !symbol.external, symbol.type == value.type,
                      value.origins.isEmpty else { throw Failure.invalidContract("unproven regional incoming representation") }
                machine.values[name] = value
            }
            machine.scopes = program.code[region.entryPC].scopes
            return try machine.execute(fuel: fuel, region: region)
        }
        func sourceRow(_ span: Span) -> Int? { try? program.row(at: span) }
        func read(_ name: String) throws -> Value {
            guard let value = values[name] else { throw Failure.uninitializedRead(name) }; return value
        }
        mutating func commit(_ name: String, _ value: Value, span: Span) throws {
            guard let symbol = program.symbols[name], !symbol.external else { throw Failure.invalidContract("invalid assignment target \(name)") }
            let converted: Value
            do { converted = try OrdinaryC.converted(value, to: symbol.type) } catch Failure.undefinedC(let reason) {
                let line = program.tokens.indices.contains(span.first) ? program.tokens[span.first].line : 0
                throw Failure.undefinedC("\(reason) [assigning 0x\(String(value.bits, radix: 16)) of \(value.type) to \(name) of \(symbol.type) at output line \(line): \(program.lines.indices.contains(line - 1) ? program.lines[line - 1].text : "")]")
            }
            values[name] = converted
            result.commits.append(.init(span: span, sourceRow: sourceRow(span), name: name, value: converted))
        }
        func permit(_ value: Value, role: Role, span: Span) throws {
            guard !value.origins.isEmpty else { return }
            let row = try program.row(at: span)
            for origin in value.origins {
                guard program.contract.permissions.contains(.init(callRow: origin.row, sinkRow: row, role: role)) else {
                    throw Failure.callAuthorityViolation("dynamic call \(origin.row)#\(origin.occurrence) used as \(role) at \(row)")
                }
                // An occurrence remains a value, never a magic reference to the
                // latest static call. Ordered event comparison exposes stale use.
            }
        }
        func spanAddresses(_ address: UInt64, bytes: Int) throws -> [UInt64] {
            if historicalByteMap64 {
                guard [1, 2, 4, 8].contains(bytes) else { throw Failure.invalidContract("invalid retained byte-map access width") }
                let addresses = (0..<bytes).map { address &+ UInt64($0) }
                // This stronger boundary applies to every byte-map access,
                // including ordinary-looking spans and stores. No implicit
                // allocation may expand the externally fixed byte map.
                guard addresses.allSatisfy({ result.memory[$0] != nil }) else {
                    throw Failure.invalidContract("retained byte-map access touches an unspecified byte")
                }
                return addresses
            }
            guard [1, 2, 4, 8].contains(bytes), address <= UInt64.max - UInt64(bytes - 1) else {
                throw Failure.undefinedC("memory span overflows address space")
            }
            return (0..<bytes).map { address + UInt64($0) }
        }
        mutating func load(_ address: Value, type: CType, span: Span) throws -> Value {
            guard !address.type.pointer || (address.type.bytePointer && address.objectAddress != nil) else {
                throw Failure.undefinedC("load address lacks object provenance")
            }
            try permit(address, role: .memoryAddress, span: span)
            guard let site = program.memorySites[span] else { throw Failure.invalidContract("unowned load") }
            let addresses = try spanAddresses(address.bits, bytes: type.width / 8)
            var bits: UInt64 = 0, origins: Set<Origin> = []
            for (index, position) in addresses.enumerated() {
                guard let byte = result.memory[position] else { throw Failure.uninitializedRead("byte 0x\(String(position, radix: 16))") }
                bits |= UInt64(byte) << (index * 8); origins.formUnion(memoryOrigins[position, default: []])
            }
            let occurrence = effectOccurrences[site, default: 0]; effectOccurrences[site] = occurrence + 1
            result.events.append(.load(site, occurrence, address.bits, type.width / 8, bits))
            return .init(bits, type.unqualified, origins: origins)
        }
        mutating func store(_ address: Value, _ value: Value, type: CType, span: Span) throws {
            try permit(address, role: .memoryAddress, span: span); try permit(value, role: .memoryData, span: span)
            guard let site = program.memorySites[span] else { throw Failure.invalidContract("unowned store") }
            let value = try OrdinaryC.converted(value, to: type)
            let addresses = try spanAddresses(address.bits, bytes: type.width / 8)
            for (index, position) in addresses.enumerated() {
                result.memory[position] = UInt8(truncatingIfNeeded: value.bits >> (index * 8)); memoryOrigins[position] = value.origins
            }
            let occurrence = effectOccurrences[site, default: 0]; effectOccurrences[site] = occurrence + 1
            result.events.append(.store(site, occurrence, address.bits, type.width / 8, value.bits))
        }
        mutating func evaluate(_ e: Expression) throws -> Value {
            let value = try evaluateNode(e)
            result.evaluations.append(.init(span: e.span, sourceRow: sourceRow(e.span), value: value))
            return value
        }
        private mutating func evaluateNode(_ e: Expression) throws -> Value {
            switch e.node {
            case let .literal(value): return value
            case let .name(name): return try read(name)
            case let .cast(type, operand): return try OrdinaryC.converted(evaluate(operand), to: type)
            case let .unary(op, operand):
                let old = try evaluate(operand), value = try OrdinaryC.converted(old, to: old.type.promoted)
                switch op {
                case "+": return value
                case "!": return .init(value.bits == 0 ? 1 : 0, .i32, origins: value.origins)
                case "~": return .init(~value.bits, value.type, origins: value.origins)
                case "-":
                    if value.type.unsigned { return .init(0 &- value.bits, value.type, origins: value.origins) }
                    guard value.bits != value.type.sign else { throw Failure.undefinedC("negation of signed minimum") }
                    return try OrdinaryC.signedResult(-value.signed, type: value.type, origins: value.origins)
                default: throw Failure.unsupportedSyntax("unknown unary operator")
                }
            case let .binary(op, left, right):
                let a = try evaluate(left)
                if op == "&&" || op == "||" {
                    if op == "&&" && a.bits == 0 { return .init(0, .i32, origins: a.origins) }
                    if op == "||" && a.bits != 0 { return .init(1, .i32, origins: a.origins) }
                    let b = try evaluate(right)
                    return .init(b.bits != 0 ? 1 : 0, .i32, origins: a.origins.union(b.origins))
                }
                let b = try evaluate(right); return try OrdinaryC.binary(op, a, b)
            case let .select(condition, yes, no):
                let value = try evaluate(condition)
                if !program.representationCasts.contains(e.span) { try permit(value, role: .selectionCondition, span: e.span) }
                guard let type = program.expressionTypes[e.span] else { throw Failure.invalidContract("ternary type unresolved") }
                // Selected data carries only its own data origins. Condition
                // provenance was checked as a separate selection sink above.
                return try OrdinaryC.converted(evaluate(value.bits != 0 ? yes : no), to: type)
            case let .load(type, address): let value = try evaluate(address); return try load(value, type: type, span: e.span)
            case let .field(base, name):
                let base = try evaluate(base)
                guard let field = program.contract.fields.first(where: { $0.owner == base.type.pointee && $0.name == name }),
                      base.bits <= UInt64.max - field.offset else { throw Failure.undefinedC("invalid field base/span") }
                let address = Value(base.bits + field.offset, .u64, origins: base.origins)
                return try load(address, type: field.type, span: e.span)
            case let .helper(name, args):
                if name == "__adrp" { return try OrdinaryC.converted(evaluate(args[0]), to: .u64) }
                let a = try evaluate(args[0]), b = try evaluate(args[1])
                let left = Int32(bitPattern: UInt32(truncatingIfNeeded: a.bits)), right = Int32(bitPattern: UInt32(truncatingIfNeeded: b.bits))
                let quotient: Int32 = right == 0 ? 0 : left == .min && right == -1 ? .min : left / right
                return .init(UInt64(UInt32(bitPattern: quotient)), .i32, origins: a.origins.union(b.origins))
            case let .update(name, step, prefix):
                let old = try read(name), computed = try OrdinaryC.binary(step > 0 ? "+" : "-", old, .init(1, .i32))
                let new = try OrdinaryC.converted(computed, to: old.type)
                try commit(name, new, span: e.span); return prefix ? new : old
            }
        }
        mutating func opaque(row: Int, destination: String?, control: Expression?, arguments: [Expression], span: Span) throws {
            guard let call = program.contract.calls[row], result.consumedResponses < scenario.responses.count else { throw Failure.scriptMismatch("unscripted call row \(row)") }
            let response = scenario.responses[result.consumedResponses]
            guard response.row == row else { throw Failure.scriptMismatch("expected \(response.row), executed \(row)") }
            var controls: [Carrier] = [], carriers: [Carrier] = []
            if let control, let role = call.control {
                let value = try evaluate(control); try permit(value, role: .callee, span: span)
                controls.append(.init(register: role.register, width: role.width, bits: value.bits))
            }
            for (index, expression) in arguments.enumerated() {
                let value = try evaluate(expression); try permit(value, role: .callArgument(index), span: span)
                let role = call.arguments[index], mask: UInt64 = role.width == 64 ? .max : 0xffff_ffff
                carriers.append(.init(register: role.register, width: role.width, bits: value.bits & mask))
            }
            if let expected = response.expectedArguments, expected != carriers.map(\.bits) { throw Failure.scriptMismatch("candidate call arguments at row \(row)") }
            if let expected = response.expectedControl, expected != controls.map(\.bits) { throw Failure.scriptMismatch("candidate callee at row \(row)") }
            let occurrence = callOccurrences[row, default: 0]; callOccurrences[row] = occurrence + 1
            for write in response.writes {
                for (index, position) in try spanAddresses(write.address, bytes: write.bytes).enumerated() {
                    result.memory[position] = UInt8(truncatingIfNeeded: write.bits >> (index * 8))
                    memoryOrigins.removeValue(forKey: position)
                }
            }
            if let destination { try commit(destination, .init(response.result, call.resultType, origins: [.init(row: row, occurrence: occurrence)]), span: span) }
            result.events.append(.call(.init(row: row, occurrence: occurrence, target: call.target, control: controls,
                arguments: carriers, result: response.result, writes: response.writes)))
            result.consumedResponses += 1
        }
        mutating func execute(fuel initialFuel: Int, region: BoundRegion? = nil,
            beforeInstruction: ((Int, [Transfer]) throws -> Bool)? = nil) throws -> Result {
            guard !historicalByteMap64 || region == nil else {
                throw Failure.invalidContract("historical byte-map requires complete entry, not a local-state region")
            }
            guard region == nil || beforeInstruction == nil else {
                throw Failure.invalidContract("full-entry trace hook cannot be combined with local-state region execution")
            }
            var pc = region?.entryPC ?? 0, fuel = initialFuel
            while program.code.indices.contains(pc) {
                // Observation-only: no candidate values or mutable state are
                // passed out. The caller must prove its own mapped boundary;
                // this early return grants no terminal/region success tag.
                if try beforeInstruction?(pc, result.transfers) == true { return result }
                if let region {
                    if pc == region.stopPC { result.reachedRegionBoundary = true; return result }
                    guard region.allowedPCs.contains(pc) else { throw Failure.invalidContract("regional CFG escape at parsed PC \(pc)") }
                }
                guard fuel > 0 else { throw Failure.fuelExhausted }; fuel -= 1
                let instruction = program.code[pc]
                let entered = instruction.scopes.filter { !scopes.contains($0) }
                for (name, symbol) in program.symbols where symbol.declared && !symbol.external && entered.contains(symbol.scope) {
                    values.removeValue(forKey: name)
                }
                scopes = instruction.scopes
                switch instruction.node {
                case .nop: break
                case let .declaration(name, initializer):
                    values.removeValue(forKey: name)
                    if let initializer { let value = try evaluate(initializer); try commit(name, value, span: instruction.span) }
                case let .assign(left, right):
                    // Only exact frozen tuple statements reach this with count>1.
                    // Capture every RHS and LHS address before committing, then
                    // execute destinations in printed order. Ordinary edge-copy
                    // statements each execute separately and are NEVER parallel.
                    let captured = try right.map { try evaluate($0) }
                    var addresses: [Int: Value] = [:]
                    for (index, lhs) in left.enumerated() { if case let .load(_, expression) = lhs.node { addresses[index] = try evaluate(expression) } }
                    for (index, lhs) in left.enumerated() {
                        switch lhs.node {
                        case let .name(name): try commit(name, captured[index], span: lhs.span)
                        case let .load(type, _):
                            guard let address = addresses[index] else { throw Failure.invalidContract("missing captured destination") }
                            try store(address, captured[index], type: type, span: lhs.span)
                        default: throw Failure.unsupportedSyntax("invalid destination")
                        }
                    }
                case let .update(e): _ = try evaluate(e)
                case let .branch(e, yes, no):
                    let value = try evaluate(e); try permit(value, role: .branch, span: e.span)
                    let target = value.bits != 0 ? yes : no
                    result.transfers.append(.init(span: e.span, sourceRow: sourceRow(e.span), taken: value.bits != 0, destination: target))
                    pc = target; continue
                case let .jump(target):
                    result.transfers.append(.init(span: instruction.span, sourceRow: sourceRow(instruction.span), taken: nil, destination: target))
                    pc = target; continue
                case .unresolved: throw Failure.invalidContract("unresolved compiled goto")
                case let .call(row, destination, control, args):
                    guard region == nil else { throw Failure.invalidContract("call outside no-K regional boundary") }
                    try opaque(row: row, destination: destination, control: control, arguments: args, span: instruction.span)
                case let .returned(expression):
                    guard !program.contract.noCallUnavailableTerminal else { throw Failure.invalidContract("nonnumeric terminal lost its dedicated instruction") }
                    guard region == nil else { throw Failure.invalidContract("regional witness reached whole-function return") }
                    if let expression {
                        let value = try evaluate(expression)
                        guard value.origins.isEmpty, let type = program.contract.returnType else { throw Failure.callAuthorityViolation("opaque result became original terminal") }
                        result.terminal = try OrdinaryC.converted(value, to: type)
                    }
                    guard result.consumedResponses == scenario.responses.count else { throw Failure.scriptMismatch("unused scripted responses") }
                    result.returned = true; return result
                case .unavailableReturn:
                    guard region == nil, program.contract.noCallUnavailableTerminal,
                          sourceRow(instruction.span) == program.contract.terminalRow,
                          scenario.responses.isEmpty, result.terminal == nil else {
                        throw Failure.invalidContract("invalid no-call nonnumeric terminal execution")
                    }
                    result.unavailableTerminal = .unresolvedReturnContract
                    result.returned = true; return result
                }
                pc += 1
            }
            throw Failure.undefinedC("fell out of function without original terminal")
        }
    }
}
