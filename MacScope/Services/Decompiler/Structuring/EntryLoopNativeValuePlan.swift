import Foundation

/// A native-SSA projection of the unchanged entry-loop admission certificate.
/// A recurrence may reuse only its own final original definition. This is not
/// another physical-register bank, and it does not emit scalar text.
struct EntryLoopNativeValuePlan {
    struct DefinitionID: Hashable {
        let row: Int
        let slot: Int
    }
    struct EffectID: Hashable {
        let row: Int
        let ordinal: Int
    }
    /// Operands are evaluated in the read phase, before this effect's commit.
    struct ReadPhase: Hashable {
        let effect: EffectID
        let operand: Int
    }
    struct Declaration {
        let storage: MacIRValue
        let type: String
        let initializer: MacIRValue
    }
    struct RecurrenceCertificate {
        let register: Int
        let width: Int
        let storage: MacIRValue
        let definition: DefinitionID
        let finalWrite: EffectID
        let entryReads: [ReadPhase]
        let finalReads: [ReadPhase]
        let observedByCondition: Bool
        let observedByTerminal: Bool
        /// The omitted copy is storage <- (exact unsigned storage type)storage.
        let elidedIdentitySource: MacIRValue
    }

    let declarations: [Declaration]
    /// One ordered scalar-effect group for each admitted original body row.
    /// Source provenance is unchanged; the emitter owns each group once and
    /// attaches its original comment once, not once per derived scalar effect.
    let groups: [[MacIRInstruction]]
    let condition: String
    let conditionValue: MacIRValue
    let branch: MacIRInstruction
    let terminal: MacIRInstruction
    let namedValues: Set<MacIRValue>
    let valueTypes: [MacIRValue: String]
    let sourceDefinitions: [MacIRValue: DefinitionID]
    let recurrenceCertificates: [RecurrenceCertificate]
    let provedPositions: Set<RegionalProvedPosition>
    private let originalFunction: MacIRFunction

    static func prove(function: MacIRFunction, cfg: CFG,
                      lexicalProof: RegionalLexicalProof? = nil,
                      attemptLexical: Bool = true) -> Self? {
        if attemptLexical, lexicalProof == nil,
           let proof = RegionalLexicalProof(reconciled: function),
           let result = prove(function: proof.function, cfg: cfg, lexicalProof: proof,
                              attemptLexical: false) {
            return result
        }
        // A declined lexical candidate does not disable the prior row proof.

        // Keep all decoded, operand, CFG, width, read-before-write and terminal
        // admission in its existing owner. Never infer a return contract here.
        guard let carry = EntryLoopCarryPlan.prove(function: function, cfg: cfg, lexicalProof: lexicalProof,
                                                    attemptLexical: false),
              carry.body.count == function.instructions.count - 2 else { return nil }
        var definitions: [MacIRValue: DefinitionID] = [:]
        var originalAtoms: Set<MacIRValue> = []
        for (row, original) in function.instructions.enumerated() {
            guard let operands = values(original.operation) else { return nil }
            operands.forEach { collectAtoms($0, into: &originalAtoms) }
            if row < carry.body.count {
                let writes = destinations(original.operation)
                guard writes == destinations(carry.body[row].operation),
                      original.source == carry.body[row].source else { return nil }
                for (slot, value) in writes.enumerated() {
                    guard definitions.updateValue(DefinitionID(row: row, slot: slot), forKey: value) == nil else { return nil }
                }
            }
        }

        // Split first, while the admission's entry cells and original SSA
        // definitions are still distinct. That lets the proof distinguish an
        // old-iteration read from a newly committed final-definition read.
        var symbolic: [[MacIRInstruction]] = []
        for instruction in carry.body {
            guard let group = scalarEffects(instruction), !group.isEmpty else { return nil }
            symbolic.append(group)
        }
        var writePhases: [MacIRValue: EffectID] = [:]
        var readPhases: [MacIRValue: [ReadPhase]] = [:]
        for (row, group) in symbolic.enumerated() {
            for (ordinal, instruction) in group.enumerated() {
                let effect = EffectID(row: row, ordinal: ordinal)
                guard let reads = inputs(instruction.operation) else { return nil }
                for (operand, input) in reads.enumerated() {
                    var atoms: Set<MacIRValue> = []
                    collectAtoms(input, into: &atoms)
                    for atom in atoms {
                        readPhases[atom, default: []].append(ReadPhase(effect: effect, operand: operand))
                    }
                }
                for destination in destinations(instruction.operation) {
                    guard definitions[destination] != nil,
                          writePhases.updateValue(effect, forKey: destination) == nil else { return nil }
                }
            }
        }
        guard Set(writePhases.keys) == Set(definitions.keys) else { return nil }

        var replacements: [MacIRValue: MacIRValue] = [:]
        var declarations: [Declaration] = []
        var certificates: [RecurrenceCertificate] = []
        var types: [MacIRValue: String] = [:]
        var conditionAtoms: Set<MacIRValue> = [], terminalAtoms: Set<MacIRValue> = []
        collectAtoms(carry.conditionValue, into: &conditionAtoms)
        guard let terminalValues = values(carry.terminal.operation) else { return nil }
        terminalValues.forEach { collectAtoms($0, into: &terminalAtoms) }
        for carrier in carry.carriers {
            let type = "uint\(carrier.width)_t"
            guard [32, 64].contains(carrier.width),
                  case let .unary(cast, final) = carrier.backedge, cast == "(\(type))",
                  case let .register(name, version) = final, version > 0,
                  let view = MacIRBuilder.integerRegisterView(name),
                  view.index == carrier.register, view.width == carrier.width,
                  let definition = definitions[final], let commit = writePhases[final],
                  definition.row == commit.row,
                  types[final] == nil, !originalAtoms.contains(carrier.storage),
                  !conditionAtoms.contains(carrier.storage), !terminalAtoms.contains(carrier.storage),
                  let oldReads = readPhases[carrier.storage], !oldReads.isEmpty,
                  oldReads.allSatisfy({ precedesOrIs($0.effect, commit) }),
                  // No historical original SSA read may observe the entry
                  // initializer. Same-effect reads are old-value reads only
                  // when they were explicitly bound to the entry cell above.
                  (readPhases[final] ?? []).allSatisfy({ precedes(commit, $0.effect) }) else { return nil }
            var entryAtoms: Set<MacIRValue> = []
            collectAtoms(carrier.entry, into: &entryAtoms)
            guard entryAtoms.isDisjoint(with: Set(definitions.keys)),
                  !entryAtoms.contains(carrier.storage),
                  function.nameBindings.allSatisfy({ binding in
                      guard binding.target == .register(name: name, version: version),
                            let authoritativeType = binding.type else { return true }
                      return authoritativeType == type
                  }) else { return nil }
            replacements[carrier.storage] = final
            types[final] = type
            declarations.append(Declaration(storage: final, type: type, initializer: carrier.entry))
            certificates.append(RecurrenceCertificate(register: carrier.register, width: carrier.width,
                storage: final, definition: definition, finalWrite: commit,
                entryReads: oldReads, finalReads: readPhases[final] ?? [],
                observedByCondition: conditionAtoms.contains(final),
                observedByTerminal: terminalAtoms.contains(final), elidedIdentitySource: carrier.backedge))
        }
        guard replacements.count == carry.carriers.count,
              Set(replacements.values).count == replacements.count else { return nil }
        let entryCells = Set(replacements.keys)
        var groups: [[MacIRInstruction]] = []
        var named = originalAtoms
        for group in symbolic {
            var prepared: [MacIRInstruction] = []
            for instruction in group {
                guard let changed = replaceReads(instruction, replacements: replacements),
                      let operands = values(changed.operation) else { return nil }
                operands.forEach { collectAtoms($0, into: &named) }
                prepared.append(changed)
            }
            groups.append(prepared)
        }
        // All copies are identity copies of an exactly typed final definition.
        // Refuse rather than invent a schedule for any remaining nonidentity
        // copy or initializer depending on mutable projected storage.
        for declaration in declarations {
            var atoms: Set<MacIRValue> = []
            collectAtoms(declaration.initializer, into: &atoms)
            guard atoms.isDisjoint(with: entryCells), atoms.isDisjoint(with: Set(types.keys)) else { return nil }
            named.formUnion(atoms)
        }
        guard named.isDisjoint(with: entryCells), conditionAtoms.isDisjoint(with: entryCells),
              terminalAtoms.isDisjoint(with: entryCells),
              certificates.allSatisfy({ certificate in
                  types[certificate.storage] == "uint\(certificate.width)_t"
                    && certificate.elidedIdentitySource == EntryLoopCarryPlan.project(certificate.storage, certificate.width)
              }) else { return nil }
        return Self(declarations: declarations, groups: groups, condition: carry.condition,
            conditionValue: carry.conditionValue, branch: carry.branch, terminal: carry.terminal,
            namedValues: named, valueTypes: types, sourceDefinitions: definitions,
            recurrenceCertificates: certificates, provedPositions: carry.provedPositions, originalFunction: function)
    }

    /// Names are checked in their actual native rendering context, including
    /// unused formals and dormant recovered/override/local reservations.
    func permitsNames(names: PseudocodeNameContext, renderedName: (MacIRValue) -> String) -> Bool {
        var owners: [String: MacIRValue] = [:]
        func record(_ name: String, owner: MacIRValue) -> Bool {
            guard Self.validName(name), owners[name] == nil || owners[name] == owner else { return false }
            owners[name] = owner
            return true
        }
        for parameter in originalFunction.parameters {
            guard let binding = parameter.bindingID,
                  record(parameter.name, owner: .argument(bindingID: binding)) else { return false }
        }
        for (binding, name) in names.argumentNames {
            guard record(name, owner: .argument(bindingID: binding)) else { return false }
        }
        for value in namedValues {
            guard record(renderedName(value), owner: value) else { return false }
        }
        for (offset, local) in names.localsByOffset {
            guard record(local.name, owner: .stackSlot(offset: offset)) else { return false }
        }
        for binding in originalFunction.nameBindings {
            let value: MacIRValue
            switch binding.target {
            case let .register(name, version): value = .register(name: name, version: version)
            case let .stackSlot(offset): value = .stackSlot(offset: offset)
            }
            guard record(binding.name, owner: value) else { return false }
        }
        for (target, name) in names.registerNamesByValue {
            guard case let .register(register, version) = target,
                  record(name, owner: .register(name: register, version: version)) else { return false }
        }
        var unusedOverrides: Set<String> = []
        for (register, name) in names.registerNameOverrides {
            let matches = namedValues.filter { value in
                guard case let .register(candidate, _) = value else { return false }
                if candidate == register { return true }
                guard let a = MacIRBuilder.integerRegisterView(candidate),
                      let b = MacIRBuilder.integerRegisterView(register) else { return false }
                return a.index == b.index
            }
            guard Self.validName(name) else { return false }
            if matches.count == 1, let owner = matches.first {
                guard record(name, owner: owner) else { return false }
            } else if !matches.isEmpty { return false }
            else {
                guard owners[name] == nil, unusedOverrides.insert(name).inserted else { return false }
            }
        }
        for declaration in declarations {
            guard !unusedOverrides.contains(renderedName(declaration.storage)),
                  names.valueTypes[declaration.storage] == nil
                    || names.valueTypes[declaration.storage] == declaration.type else { return false }
        }
        return true
    }

    private static func precedes(_ left: EffectID, _ right: EffectID) -> Bool {
        left.row < right.row || (left.row == right.row && left.ordinal < right.ordinal)
    }
    private static func precedesOrIs(_ left: EffectID, _ right: EffectID) -> Bool {
        left == right || precedes(left, right)
    }
    private static func scalarEffects(_ instruction: MacIRInstruction) -> [MacIRInstruction]? {
        // The native renderer delegates unsigned eight-byte accesses to its
        // legacy unsized dereference. That is not a typed scalar projection of
        // these integer addresses. Leave that unrelated case to the original
        // fallback instead of inventing a sign sidecar or a memory emitter.
        if let access = instruction.memoryAccess,
           access.byteWidth == 8, access.extensionKind == .none { return nil }
        func update(_ destination: MacIRValue, _ source: MacIRValue, _ delta: Int64) -> MacIRInstruction {
            MacIRInstruction(source: instruction.source, operation: .assign(destination: destination,
                source: EntryLoopCarryPlan.project(.binaryExpression(op: "+",
                    left: EntryLoopCarryPlan.project(source, 64),
                    right: EntryLoopCarryPlan.project(.immediate(delta), 64)), 64)))
        }
        switch instruction.operation {
        case let .loadWriteback(destination, baseDestination, baseSource, delta, preIndex):
            guard let access = instruction.memoryAccess else { return nil }
            var baseAtoms: Set<MacIRValue> = []
            collectAtoms(baseSource, into: &baseAtoms)
            // A post-index load must not destroy an input needed by the later
            // base commit. Admission additionally proves physical nonaliasing.
            guard destination != baseDestination, !baseAtoms.contains(destination) else { return nil }
            let commit = update(baseDestination, baseSource, delta)
            let address = preIndex ? EntryLoopCarryPlan.project(baseDestination, 64) : baseSource
            let load = MacIRInstruction(source: instruction.source,
                operation: .load(destination: destination, address: address), memoryAccess: access)
            return preIndex ? [commit, load] : [load, commit]
        case let .storeWriteback(source, baseDestination, baseSource, delta, preIndex):
            guard let access = instruction.memoryAccess else { return nil }
            var sourceAtoms: Set<MacIRValue> = []
            collectAtoms(source, into: &sourceAtoms)
            // Pre-index commits its address first. Its later payload read must
            // remain immutable across that commit, not a renamed base alias.
            guard !sourceAtoms.contains(baseDestination) else { return nil }
            let commit = update(baseDestination, baseSource, delta)
            let address = preIndex ? EntryLoopCarryPlan.project(baseDestination, 64) : baseSource
            let store = MacIRInstruction(source: instruction.source,
                operation: .store(source: source, address: address), memoryAccess: access)
            return preIndex ? [commit, store] : [store, commit]
        case .assign, .load, .store:
            return [instruction]
        default: return nil
        }
    }
    private static func replaceReads(_ instruction: MacIRInstruction,
                                     replacements: [MacIRValue: MacIRValue]) -> MacIRInstruction? {
        func mapped(_ value: MacIRValue) -> MacIRValue {
            if let replacement = replacements[value] { return replacement }
            switch value {
            case let .signedBitfield(node):
                return mapped(node.source) == node.source ? value : .unknown("UNRESOLVED_SIGNED_BITFIELD_SOURCE_REWRITE")
            case let .unary(op, inner): return .unary(op: op, value: mapped(inner))
            case let .binaryExpression(op, left, right):
                return .binaryExpression(op: op, left: mapped(left), right: mapped(right))
            case let .bitTest(inner, bit): return .bitTest(value: mapped(inner), bit: bit)
            default: return value
            }
        }
        var result = instruction
        switch instruction.operation {
        case let .assign(destination, source): result.operation = .assign(destination: destination, source: mapped(source))
        case let .load(destination, address): result.operation = .load(destination: destination, address: mapped(address))
        case let .store(source, address): result.operation = .store(source: mapped(source), address: mapped(address))
        default: return nil
        }
        return result
    }
    private static func destinations(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(destination, _), let .binary(destination, _, _, _), let .load(destination, _): return [destination]
        case let .loadWriteback(destination, baseDestination, _, _, _): return [destination, baseDestination]
        case let .storeWriteback(_, baseDestination, _, _, _): return [baseDestination]
        default: return []
        }
    }
    private static func inputs(_ operation: MacIROperation) -> [MacIRValue]? {
        switch operation {
        case let .assign(_, source): return [source]
        case let .binary(_, _, left, right): return [left, right]
        case let .load(_, address): return [address]
        case let .store(source, address): return [source, address]
        case let .loadWriteback(_, _, base, _, _): return [base]
        case let .storeWriteback(source, _, base, _, _): return [source, base]
        case let .conditionalBranch(_, left, right, target): return [left, right, target]
        case let .returnValue(value): return value.map { [$0] } ?? []
        default: return nil
        }
    }
    private static func values(_ operation: MacIROperation) -> [MacIRValue]? {
        inputs(operation).map { destinations(operation) + $0 }
    }
    private static func collectAtoms(_ value: MacIRValue, into result: inout Set<MacIRValue>) {
        switch value {
        case .register, .argument, .temporary: result.insert(value)
        case let .signedBitfield(node): collectAtoms(node.source, into: &result)
        case let .unary(_, inner), let .bitTest(inner, _): collectAtoms(inner, into: &result)
        case let .binaryExpression(_, left, right):
            collectAtoms(left, into: &result); collectAtoms(right, into: &result)
        default: break
        }
    }
    private static func validName(_ name: String) -> Bool {
        let forbidden: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
            "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
            "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary",
            "_Noreturn", "_Static_assert", "_Thread_local", "alignas", "alignof", "bool",
            "constexpr", "false", "nullptr", "static_assert", "thread_local", "true", "typeof",
            "typeof_unqual", "_BitInt", "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t", "unresolved_return_contract"
        ]
        return !forbidden.contains(name)
            && name.range(of: #"\A[A-Za-z_][A-Za-z_0-9]*\z"#, options: .regularExpression) != nil
    }
}
