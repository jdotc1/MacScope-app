import Foundation

/// A row's immutable definition plan and its value-semantic reaching bindings.
/// Allocation belongs to the dominator renamer; lifting never allocates SSA IDs.
struct MacIRSSAState {
    struct Binding {
        var value: MacIRValue
        var bitWidth: Int
        var view: MacIRSSA.ScalarView
        var origin: MacIRSSA.DefinitionOrigin
        var hasCallArgumentEvidence = true
        // Set only when this half was projected from a retained wide result.
        var wholeVector: MacIRValue? = nil

        var isUnavailable: Bool {
            switch origin {
            case .callClobber, .refusal: return true
            default: return false
            }
        }

        var isPhi: Bool {
            if case .phi = origin { return true }
            return false
        }
    }

    var current: [Int: Binding]
    var writes: [Int: Binding]
    var clobbers: [Int: Binding]
    var stackPointerOffset: Int64? = nil
    var entryStackMemoryIsPristine = true

    static func integerCell(for register: String) -> Int? {
        let name = register.lowercased()
        if name == "sp" || name == "wsp" { return 31 }
        if name == "fp" { return 29 }
        if name == "lr" { return 30 }
        return MacIRBuilder.integerRegisterView(name)?.index
    }

    static func cells(for register: String) -> [Int] {
        MacIRBuilder.ssaRegisterView(for: register)?.cells ?? []
    }
}

extension BuilderState {
    func ssaValue(for register: String) -> MacIRValue? {
        guard let ssa else { return nil }
        let name = register.lowercased()
        if let cell = MacIRSSAState.integerCell(for: name), let binding = ssa.current[cell] {
            if binding.isUnavailable {
                switch (binding.origin, binding.value) {
                case (.refusal, .register), (.refusal, .temporary):
                    // A late refusal can still explicitly define a named
                    // unknown result. Preserve that dataflow identity without
                    // granting return or call-argument authority to its value.
                    break
                default: return .unknown("unavailable_\(name)")
                }
            }
            if case .entry = binding.origin, case let .register(_, version) = binding.value {
                return .register(name: name, version: version)
            }
            let width = name.hasPrefix("w") ? 32 : 64
            guard width != binding.bitWidth else { return binding.value }
            if binding.bitWidth == 32 {
                return .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: binding.value))
            }
            return .unary(op: "(uint32_t)", value: binding.value)
        }
        guard let simd = MacIRBuilder.ssaRegisterView(for: name), (32..<96).contains(simd.cell),
              let low = ssa.current[simd.cell] else { return nil }
        if low.isUnavailable { return .unknown("unavailable_\(name)") }
        if simd.cells.count > 1 {
            guard let highCell = simd.cells.last, let high = ssa.current[highCell] else { return nil }
            if high.isUnavailable { return high.value }
            if let whole = low.wholeVector, high.wholeVector == whole { return whole }
            return .binaryExpression(op: "__ssa_join_vector_halves", left: Self.ssaBits(low), right: Self.ssaBits(high))
        }
        if name.hasPrefix("d") {
            if low.view == .float32, callUnavailableRegisterValues.contains(name) {
                return .unknown("unavailable_\(name)")
            }
            if low.view == .float64 { return low.value }
            return .unary(op: "__ssa_bitcast_f64", value: Self.ssaBits(low))
        }
        if name.hasPrefix("s") {
            if low.view == .float64, callUnavailableRegisterValues.contains(name) {
                return .unknown("unavailable_\(name)")
            }
            if low.view == .float32 { return low.value }
            return .unary(op: "__ssa_bitcast_f32", value: .unary(op: "(uint32_t)", value: Self.ssaBits(low)))
        }
        if name.hasPrefix("h") {
            return .binaryExpression(op: "&", left: Self.ssaBits(low), right: .immediate(0xffff))
        }
        return Self.ssaBits(low)
    }

    private static func ssaBits(_ binding: MacIRSSAState.Binding) -> MacIRValue {
        switch binding.view {
        case .float32: return .unary(op: "__ssa_bitcast_u32", value: binding.value)
        case .float64: return .unary(op: "__ssa_bitcast_u64", value: binding.value)
        default: return binding.value
        }
    }

    func ssaPlannedWrite(for register: String) -> MacIRSSAState.Binding? {
        guard let cell = MacIRSSAState.cells(for: register).first else { return nil }
        return ssa?.writes[cell]
    }

    mutating func installSSAWrite(for register: String) {
        guard var context = ssa else { return }
        for cell in MacIRSSAState.cells(for: register) {
            if let binding = context.writes[cell] { context.current[cell] = binding }
        }
        ssa = context
    }

    mutating func installSSAInvalidation(for register: String) {
        guard var context = ssa else { return }
        for cell in MacIRSSAState.cells(for: register) {
            if let binding = context.clobbers[cell] {
                context.current[cell] = binding
            } else if let binding = context.writes[cell], binding.isUnavailable {
                context.current[cell] = binding
            }
        }
        ssa = context
    }

    mutating func installSSACallClobbers() {
        guard var context = ssa else { return }
        for (cell, binding) in context.clobbers { context.current[cell] = binding }
        ssa = context
    }

    /// Call after installing a block/row entry map. Legacy helpers consulting
    /// physical integer state must observe the same definition as SSA reads.
    mutating func synchronizeSSARegisterState() {
        guard let context = ssa else { return }
        currentIntegerDefinitionByIndex.removeAll(keepingCapacity: true)
        for (cell, binding) in context.current where cell < 31 {
            if case .entry = binding.origin {
                // Entry values are not instruction-written ABI producers.
                registerVersions.removeValue(forKey: "x\(cell)")
                registerVersions.removeValue(forKey: "w\(cell)")
                unavailableRegisterValues.remove("x\(cell)")
                unavailableRegisterValues.remove("w\(cell)")
                continue
            }
            currentIntegerDefinitionByIndex[cell] = IntegerRegisterDefinition(
                value: binding.value, width: binding.bitWidth,
                isJoinedDefinition: binding.isPhi, isSyntheticReturnPhi: binding.isPhi)
            if binding.isUnavailable {
                unavailableRegisterValues.insert("x\(cell)")
                unavailableRegisterValues.insert("w\(cell)")
            } else {
                unavailableRegisterValues.remove("x\(cell)")
                unavailableRegisterValues.remove("w\(cell)")
            }
            if case let .register(name, version) = binding.value { registerVersions[name] = version }
        }
        if let result = context.current[0] {
            switch result.origin {
            case .entry:
                latestABIResultValue = nil
                hasUnmodeledABIResultWrite = false
            case .phi:
                latestABIResultValue = nil
                hasUnmodeledABIResultWrite = false
                if resolvedX0PhiReturnProducers.contains(result.value) {
                    shouldInferVoidReturn = false
                }
            case .callClobber, .refusal:
                latestABIResultValue = nil
                hasUnmodeledABIResultWrite = true
            default:
                latestABIResultValue = result.value
                hasUnmodeledABIResultWrite = false
                shouldInferVoidReturn = false
            }
        }
    }

    /// Entry-stack binding replaces a value without changing its definition ID.
    /// The runtime copies this substitution back to its ID-to-value dictionary.
    mutating func replaceSSAValue(for register: String, with value: MacIRValue) {
        guard var context = ssa else { return }
        for cell in MacIRSSAState.cells(for: register) {
            guard var binding = context.current[cell] else { continue }
            binding.value = value
            context.current[cell] = binding
        }
        ssa = context
    }
}


extension MacIRBuilder {
    /// A phi preserves reaching values, but cannot turn an unobserved entry
    /// cell or a call-clobbered value into evidence for an argument. Propagate
    /// those missing observations through phi edges without changing dataflow.
    static func ssaUnobservedCallArgumentDefinitions(
        plan: MacIRSSA.Plan, values: [Int: MacIRValue]
    ) -> Set<Int> {
        func isIncomingArgument(_ value: MacIRValue?) -> Bool {
            switch value {
            case .argument?, .argumentFragment?: return true
            case let .unary(_, value)?: return isIncomingArgument(value)
            default: return false
            }
        }
        var unobserved: Set<Int> = []
        for definition in plan.definitions {
            let id = plan.canonicalID(definition.id)
            guard id == definition.id else { continue }
            switch definition.origin {
            case .callClobber, .refusal:
                unobserved.insert(id)
            case .entry where !isIncomingArgument(values[id]):
                unobserved.insert(id)
            default:
                break
            }
        }
        var dependents: [Int: [Int]] = [:]
        for phi in plan.phis {
            let destination = plan.canonicalID(phi.destination)
            if phi.incoming.isEmpty { unobserved.insert(destination) }
            for incoming in phi.incoming {
                dependents[plan.canonicalID(incoming.definition), default: []].append(destination)
            }
        }
        var pending = Array(unobserved)
        while let id = pending.popLast() {
            for dependent in dependents[id] ?? [] where unobserved.insert(dependent).inserted {
                pending.append(dependent)
            }
        }
        return unobserved
    }

    /// A must fact relative to entry SP. Pending is the bottom of the lattice,
    /// so a neutral backedge can inherit an exact offset without lexical order.
    /// A conflicting predecessor or an unmodelled write permanently loses it.
    static func ssaStackOffsets(plan: MacIRSSA.Plan, sources: [MacIRSourceSpan],
                                localsOnly: Bool = false, cancelled: () -> Bool = { false }) -> [Int: Int64] {
        enum Fact: Equatable { case pending, exact(Int64), unknown }
        var facts = [Fact](repeating: .pending, count: plan.definitions.count)
        let rowByAddress = Dictionary(
            sources.enumerated().map { ($0.element.address, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let phis = Dictionary(uniqueKeysWithValues: plan.phis.map { ($0.destination, $0) })
        func fact(_ id: Int) -> Fact { facts[plan.canonicalID(id)] }
        func adding(_ delta: Int64, to input: Fact) -> Fact {
            guard case let .exact(offset) = input else { return input }
            let result = offset.addingReportingOverflow(delta)
            return result.overflow ? .unknown : .exact(result.partialValue)
        }
        func evaluate(_ definition: MacIRSSA.Definition) -> Fact {
            guard definition.cell < 32, definition.bitWidth == 64 else { return .unknown }
            switch definition.origin {
            case .entry: return definition.cell == 31 ? .exact(0) : .unknown
            case .callClobber, .callResult, .refusal: return .unknown
            case .phi:
                guard let phi = phis[definition.id] else { return .unknown }
                var result = Fact.pending
                for incoming in phi.incoming {
                    let next = fact(incoming.definition)
                    if next == .unknown { return .unknown }
                    if next == .pending { continue }
                    if result != .pending && result != next { return .unknown }
                    result = next
                }
                return result
            case let .instruction(address):
                guard let row = rowByAddress[address] else { return .unknown }
                let source = sources[row]
                let operands = splitOperands(source.operands).map { $0.lowercased() }
                func input(_ operand: String) -> Fact {
                    guard let view = ssaRegisterView(for: operand), view.bitWidth == 64,
                          let id = plan.rowReadBindings[row][view.cell] else { return .unknown }
                    return fact(id)
                }
                if operands.count == 2, source.mnemonic == "mov",
                   ssaCell(for: operands[0]) == definition.cell { return input(operands[1]) }
                if operands.count == 3, ["add", "sub"].contains(source.mnemonic),
                   ssaCell(for: operands[0]) == definition.cell,
                   let amount = parseImmediate(operands[2]) {
                    if source.mnemonic == "sub" && amount == Int64.min { return .unknown }
                    return adding(source.mnemonic == "sub" ? -amount : amount, to: input(operands[1]))
                }
                // Memory writeback defines its base simultaneously with any
                // transfer destinations, using the pre-instruction base value.
                guard let memoryIndex = operands.firstIndex(where: { $0.hasPrefix("[") }) else { return .unknown }
                let memory = operands[memoryIndex]
                let preIndex = memory.hasSuffix("!")
                let enclosed = preIndex ? String(memory.dropLast()) : memory
                guard enclosed.hasSuffix("]") else { return .unknown }
                let parts = splitOperands(String(enclosed.dropFirst().dropLast()))
                guard let base = parts.first, ssaCell(for: base) == definition.cell else { return .unknown }
                let delta: Int64?
                if preIndex, parts.count == 2 { delta = parseImmediate(parts[1]) }
                else if !preIndex, parts.count == 1, memoryIndex + 1 < operands.count {
                    delta = parseImmediate(operands[memoryIndex + 1])
                } else { delta = nil }
                guard let delta else { return .unknown }
                return adding(localsOnly ? 0 : delta, to: input(base))
            }
        }
        var changed = true
        while changed {
            if cancelled() { return [:] }
            changed = false
            for definition in plan.definitions {
                guard facts[definition.id] != .unknown else { continue }
                let candidate = evaluate(definition)
                let updated: Fact
                if case .exact = facts[definition.id], candidate != .pending,
                   candidate != facts[definition.id] { updated = .unknown }
                else if candidate == .pending { updated = facts[definition.id] }
                else { updated = candidate }
                if updated != facts[definition.id] { facts[definition.id] = updated; changed = true }
            }
        }
        return Dictionary(uniqueKeysWithValues: plan.definitions.compactMap { definition in
            guard case let .exact(offset) = fact(definition.id) else { return nil }
            return (definition.id, offset)
        })
    }
}


extension MacIRBuilder {
    static func ssaDestinations(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _),
             let .load(destination, _), let .stackSlotRead(destination, _, _),
             let .select(destination, _, _, _, _, _), let .compareToBool(destination, _, _, _):
            return [destination]
        case let .loadWriteback(destination, base, _, _, _): return [destination, base]
        case let .storeWriteback(_, base, _, _, _): return [base]
        case let .stackSlotPairRead(first, _, _, second, _, _): return [first, second]
        case let .call(_, result), let .intrinsic(result, _, _), let .unknown(result, _, _, _):
            return result.map { [$0] } ?? []
        default: return []
        }
    }

    static func ssaReplacingDestination(_ old: MacIRValue, with new: MacIRValue,
                                       in operation: MacIROperation) -> MacIROperation {
        func destination(_ value: MacIRValue) -> MacIRValue { value == old ? new : value }
        switch operation {
        case let .assign(d, s): return .assign(destination: destination(d), source: s)
        case let .binary(d, op, l, r): return .binary(destination: destination(d), op: op, left: l, right: r)
        case let .load(d, a): return .load(destination: destination(d), address: a)
        case let .loadWriteback(d, b, s, delta, pre):
            return .loadWriteback(destination: destination(d), baseDestination: destination(b),
                                  baseSource: s, delta: delta, preIndex: pre)
        case let .storeWriteback(s, b, base, delta, pre):
            return .storeWriteback(source: s, baseDestination: destination(b), baseSource: base, delta: delta, preIndex: pre)
        case let .stackSlotRead(d, slot, value):
            return .stackSlotRead(destination: destination(d), slot: slot, value: value)
        case let .stackSlotPairRead(a, aslot, av, b, bslot, bv):
            return .stackSlotPairRead(firstDestination: destination(a), firstSlot: aslot, firstValue: av,
                                     secondDestination: destination(b), secondSlot: bslot, secondValue: bv)
        case let .call(frame, result): return .call(frame: frame, result: result.map(destination))
        case let .select(d, c, l, r, t, f):
            return .select(destination: destination(d), condition: c, left: l, right: r, trueValue: t, falseValue: f)
        case let .compareToBool(d, c, l, r):
            return .compareToBool(destination: destination(d), condition: c, left: l, right: r)
        case let .intrinsic(d, name, args): return .intrinsic(destination: d.map(destination), name: name, arguments: args)
        case let .unknown(d, inputs, mnemonic, operands):
            return .unknown(destination: d.map(destination), inputs: inputs, mnemonic: mnemonic, operands: operands)
        default: return operation
        }
    }
}


extension MacIRBuilder {
    /// Entry arguments may be substituted only while no incoming path has
    /// overwritten their memory. Callee-save traffic wholly below entry SP is
    /// disjoint; other stores and opaque memory effects conservatively kill it.
    static func ssaPristineEntryStack(plan: MacIRSSA.Plan, cfg: MacIRCFG,
                                     sources: [MacIRSourceSpan], offsets: [Int: Int64],
                                     cancelled: () -> Bool = { false }) -> [Bool] {
        func preserves(_ row: Int) -> Bool {
            guard let memory = plan.rowWriteBindings[row][97] else { return true }
            guard case .instruction = plan.definitions[memory].origin else { return false }
            let source = sources[row]
            guard ["str", "stur", "strb", "strh", "sturb", "sturh", "stp"].contains(source.mnemonic),
                  let sp = plan.rowReadBindings[row][31], let base = offsets[sp] else { return false }
            let operands = splitOperands(source.operands).map { $0.lowercased() }
            guard let operand = operands.first(where: { $0.hasPrefix("[") }) else { return false }
            let bracket = operand.hasSuffix("!") ? String(operand.dropLast()) : operand
            guard bracket.hasSuffix("]") else { return false }
            let parts = splitOperands(String(bracket.dropFirst().dropLast()))
            guard parts.first == "sp", parts.count <= 2 else { return false }
            let displacement = parts.count == 1 ? Int64(0) : parts.last.flatMap(parseImmediate)
            guard let displacement, let first = operands.first, let view = ssaRegisterView(for: first) else { return false }
            let width = source.mnemonic.hasSuffix("b") ? 1 : source.mnemonic.hasSuffix("h") ? 2 : view.bitWidth / 8
            let count = source.mnemonic == "stp" ? 2 : 1
            let start = base.addingReportingOverflow(displacement)
            guard !start.overflow else { return false }
            let end = start.partialValue.addingReportingOverflow(Int64(width * count))
            return !end.overflow && end.partialValue <= 0
        }
        let keeps = sources.indices.map(preserves)
        var entries = [Bool](repeating: true, count: cfg.blocks.count)
        var exits = entries
        let unreachable = Set(cfg.unreachable)
        var changed = true
        while changed {
            if cancelled() { return [Bool](repeating: false, count: sources.count) }
            changed = false
            for block in cfg.blocks {
                let incoming = !unreachable.contains(block.index)
                    && (block.index == cfg.entry || block.predecessors.allSatisfy { exits[$0] })
                let outgoing = incoming && block.instructionRange.allSatisfy { keeps[$0] }
                if entries[block.index] != incoming || exits[block.index] != outgoing {
                    entries[block.index] = incoming; exits[block.index] = outgoing; changed = true
                }
            }
        }
        var result = [Bool](repeating: false, count: sources.count)
        for block in cfg.blocks {
            var pristine = entries[block.index]
            for row in block.instructionRange {
                result[row] = pristine
                pristine = pristine && keeps[row]
            }
        }
        return result
    }
}
