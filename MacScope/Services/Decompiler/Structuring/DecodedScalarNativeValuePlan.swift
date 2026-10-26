import Foundation

/// Native source definitions and demanded joins over the unchanged decoded
/// certificate. Architectural registers are proof keys, never printed cells.
struct DecodedScalarNativeValuePlan {
    enum Item {
        case instruction(MacIRInstruction)
        case protectedOriginal(row: Int)
    }
    enum DeclarationOrigin {
        case source(row: Int, slot: Int)
        case join(block: Int, register: Int)
        case parallelCycle(CFGEdge)
    }
    struct Declaration {
        let storage: MacIRValue
        let type: String
        let initializer: MacIRValue?
        let origin: DeclarationOrigin
    }
    enum DefinitionID: Hashable {
        case entry(Int)
        case source(row: Int, slot: Int)
        case join(block: Int, register: Int)
    }
    struct UseBinding {
        let row: Int
        let ordinal: Int
        let register: DecodedScalarCFGPlan.GPR
        let definition: DefinitionID
        let value: MacIRValue
    }
    struct ConditionBinding {
        let consumerRow: Int
        let writerRow: Int?
        let definitions: Set<DefinitionID>
    }
    struct EdgeBinding {
        let edge: CFGEdge
        let register: Int
        let source: DefinitionID
        let destination: DefinitionID
    }
    struct DefinitionBinding {
        let definition: DefinitionID
        let register: DecodedScalarCFGPlan.GPR
        let value: MacIRValue
        let architecturalWidth: Int
        let nativeType: String
        let knownZeroHigh32: Bool
    }
    struct StorageBinding {
        let storage: MacIRValue
        let definitions: Set<DefinitionID>
        let type: String
        let mutable: Bool
    }

    let groups: [[Item]]
    let branchConditions: [Int: BranchCondition]
    let edgeCopies: [CFGEdge: [MacIRInstruction]]
    let declarations: [Declaration]
    let printedDeclarationValues: Set<MacIRValue>
    let valueTypes: [MacIRValue: String]
    let namedValues: Set<MacIRValue>
    let ownedRows: Set<Int>
    let useBindings: [UseBinding]
    let conditionBindings: [Int: ConditionBinding]
    let edgeBindings: [EdgeBinding]
    let definitionBindings: [DefinitionBinding]
    let storageBindings: [StorageBinding]
    private let originalFunction: MacIRFunction
    private let originalCFG: CFG

    var provedPositions: Set<RegionalProvedPosition> {
        let reads = Set(useBindings.map {
            RegionalProvedPosition(address: originalFunction.instructions[$0.row].source.address,
                register: $0.register.index, width: $0.register.width)
        })
        return reads.union(RegionalLexicalProof.flagPositions(
            function: originalFunction, cfg: originalCFG, provedReads: reads))
    }

    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        function == originalFunction && Self.sameCFG(cfg, originalCFG)
    }

    /// Preserve ownership in the actual renderer context before its type map
    /// is merged. Dormant bindings and overrides reserve names too; selecting
    /// an original source identity does not grant its spelling to another owner.
    func permitsNames(names: PseudocodeNameContext, renderedName: (MacIRValue) -> String) -> Bool {
        var owners: [String: MacIRValue] = [:]
        func record(_ name: String, owner: MacIRValue) -> Bool {
            guard Self.validName(name), owners[name] == nil || owners[name] == owner else { return false }
            owners[name] = owner
            return true
        }
        for parameter in originalFunction.parameters {
            guard let binding = parameter.bindingID,
                  record(parameter.name, owner: .argument(bindingID: binding)),
                  names.argumentTypes[binding] == nil || names.argumentTypes[binding] == parameter.type,
                  names.valueTypes[.argument(bindingID: binding)] == nil
                    || names.valueTypes[.argument(bindingID: binding)] == parameter.type else { return false }
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
        // Dormant original identities retain their name/type authority, but
        // do not impose that type on distinct freshly allocated source storage.
        for binding in originalFunction.nameBindings {
            let value: MacIRValue
            switch binding.target {
            case let .register(name, version): value = .register(name: name, version: version)
            case let .stackSlot(offset): value = .stackSlot(offset: offset)
            }
            guard record(binding.name, owner: value) else { return false }
            if let authoritative = binding.type, let certified = valueTypes[value],
               authoritative != certified { return false }
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
        for (value, type) in valueTypes {
            guard !unusedOverrides.contains(renderedName(value)),
                  names.valueTypes[value] == nil || names.valueTypes[value] == type else { return false }
        }
        return true
    }

    static func prove(function: MacIRFunction, cfg: CFG,
                      certifiedBy state: DecodedScalarCFGPlan,
                      renderedName: (MacIRValue) -> String,
                      // Include every actual-context formal/local/recovered
                      // name and all registerNameOverrides.values, even unused.
                      reservedNames: Set<String>,
                      authoritativeTypes: [MacIRValue: String],
                      lexicalProof: RegionalLexicalProof? = nil,
                      diagnosticFile: StaticString = #fileID,
                      diagnosticLine: UInt = #line) -> Self? {
        var diagnosticID: UUID? = nil
        var diagnosticSucceeded = false
        if let sink = RejectedCFGDiagnostics.sink {
            let id = UUID()
            diagnosticID = id
            sink(.nativeProofBegin(id: id, start: function.startAddress,
                file: String(describing: diagnosticFile), line: Int(diagnosticLine)))
        }
        defer {
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.nativeProofEnd(id: id, succeeded: diagnosticSucceeded))
            }
        }
        guard state.matches(function: function, cfg: cfg),
              state.certifiedRows.count == function.instructions.count,
              cfg.blocks.allSatisfy({ Set($0.successors).count == $0.successors.count }) else { return nil }
        guard lexicalProof == nil || lexicalProof?.function == function else { return nil }
        let result: Self? = withoutActuallyEscaping(renderedName) { naming in
            guard let result = Planner(function: function, cfg: cfg, state: state,
                renderedName: naming, reservedNames: reservedNames,
                authoritativeTypes: authoritativeTypes).make(),
                  lexicalProof?.isCovered(by: result.provedPositions) != false
                    else { return nil }
            return result
        }
        if RejectedCFGDiagnostics.sink != nil { diagnosticSucceeded = result != nil }
        return result
    }

    private static func sameCFG(_ left: CFG, _ right: CFG) -> Bool {
        left.blocks == right.blocks && left.entryIndex == right.entryIndex &&
        left.domTree == right.domTree && left.postDomTree == right.postDomTree &&
        left.loopHeaders == right.loopHeaders && left.backEdges == right.backEdges &&
        left.irreducibleBlocks == right.irreducibleBlocks &&
        left.blockByStartIndex == right.blockByStartIndex && left.hasUnresolvedTargets == right.hasUnresolvedTargets
    }

    private final class Planner {
        typealias Register = DecodedScalarCFGPlan.GPR
        typealias Row = DecodedScalarCFGPlan.Row
        typealias Operand = DecodedScalarCFGPlan.Operand
        typealias Address = DecodedScalarCFGPlan.Address
        struct Fact {
            let value: MacIRValue
            let width: Int
            let type: String
            let zeroHigh: Bool
        }
        struct Key: Hashable { let block: Int; let register: Int }
        struct Copy {
            let destination: MacIRValue
            let source: MacIRValue
            let type: String
        }
        let function: MacIRFunction
        let cfg: CFG
        let state: DecodedScalarCFGPlan
        let rows: [Row]
        let renderedName: (MacIRValue) -> String
        let authoritativeTypes: [MacIRValue: String]
        var usedValues: Set<MacIRValue>
        var usedNames: Set<String>
        var nextTemporary = 0
        var facts: [DefinitionID: Fact] = [:]
        var rowDefinitions: [[DefinitionID]] = []
        var entryCache: [Key: DefinitionID] = [:]
        var resolving: Set<Key> = []
        var phiInputs: [DefinitionID: [CFGEdge: DefinitionID]] = [:]
        var replacements: [DefinitionID: DefinitionID] = [:]
        var incomingDemand: [[UInt8]] = []
        var before: [[DefinitionID?]] = []
        var after: [[DefinitionID?]] = []
        var rowOwners: [Int] = []
        var conditionBindings: [Int: ConditionBinding] = [:]
        var interference: [DefinitionID: Set<DefinitionID>] = [:]
        var groups: [[Item]]
        var branchConditions: [Int: BranchCondition] = [:]
        var edgeCopies: [CFGEdge: [MacIRInstruction]] = [:]
        var edgeBindings: [EdgeBinding] = []
        var cycleDeclarations: [Declaration] = []
        var failed = false

        init(function: MacIRFunction, cfg: CFG, state: DecodedScalarCFGPlan,
             renderedName: @escaping (MacIRValue) -> String, reservedNames: Set<String>,
             authoritativeTypes: [MacIRValue: String]) {
            self.function = function; self.cfg = cfg; self.state = state
            self.rows = state.certifiedRows; self.renderedName = renderedName
            self.authoritativeTypes = authoritativeTypes
            usedValues = state.originalAtoms.union(authoritativeTypes.keys)
            usedNames = reservedNames.union(usedValues.map(renderedName))
            groups = Array(repeating: [], count: function.instructions.count)
        }

        func make(diagnosticFile: StaticString = #fileID,
                  diagnosticLine: UInt = #line) -> DecodedScalarNativeValuePlan? {
            var diagnosticID: UUID? = nil
            var diagnosticSucceeded = false
            if let sink = RejectedCFGDiagnostics.sink {
                let id = UUID()
                diagnosticID = id
                sink(.nativeAttempt(id: id, start: function.startAddress,
                    addresses: function.instructions.map { $0.source.address },
                    ranges: cfg.blocks.map(\.instructionRange),
                    predecessors: cfg.blocks.map(\.predecessors), successors: cfg.blocks.map(\.successors),
                    backEdges: Array(cfg.backEdges), parameters: function.parameters,
                    file: String(describing: diagnosticFile), line: Int(diagnosticLine)))
            }
            defer {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.nativeFacts(id: id, plannerCompleted: diagnosticSucceeded,
                        definitions: facts.mapValues {
                            .init(value: $0.value, width: $0.width, type: $0.type, zeroHigh: $0.zeroHigh)
                        }, edges: edgeBindings, phiInputs: phiInputs,
                        before: before, after: after, replacements: replacements))
                }
            }
            guard allocateDefinitions(), solveValues(), bindConditions(),
                  computeInterference(), coalesceJoins(), validateStorageInterference(),
                  validateConditionStability(), prepareRows(), prepareEdges(), !failed,
                  let certificate = declarationsAndTypes() else { return nil }
            let declarations = certificate.declarations
            let types = certificate.types
            let mutable = certificate.mutable
            let printed = requiredPrintedDeclarations(declarations, types: types, mutable: mutable)
            var named = Set(state.entries.map(\.value))
            declarations.forEach { named.insert($0.storage) }
            for group in groups {
                for item in group {
                    if case let .instruction(instruction) = item {
                        operationValues(instruction.operation).forEach { collectAtoms($0, into: &named) }
                    }
                }
            }
            for copies in edgeCopies.values {
                for instruction in copies {
                    operationValues(instruction.operation).forEach { collectAtoms($0, into: &named) }
                }
            }
            for condition in branchConditions.values {
                collectAtoms(condition.left, into: &named); collectAtoms(condition.right, into: &named)
            }
            guard validateNames(named) else { return nil }
            var uses: [UseBinding] = []
            for row in rows.indices {
                for (ordinal, register) in rows[row].reads.enumerated() where !register.isZero {
                    guard let id = before[row][register.index], let fact = facts[id] else { return nil }
                    uses.append(UseBinding(row: row, ordinal: ordinal, register: register,
                        definition: id, value: fact.value))
                    if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID,
                       let binding = uses.last {
                        sink(.nativeUse(id: id, binding: binding))
                    }
                }
            }
            var definitions: [DefinitionBinding] = []
            var byStorage: [MacIRValue: Set<DefinitionID>] = [:]
            for id in activeDefinitions().sorted(by: ordered) {
                guard let fact = facts[id], let register = register(of: id) else { return nil }
                definitions.append(DefinitionBinding(definition: id, register: register, value: fact.value,
                    architecturalWidth: fact.width, nativeType: fact.type, knownZeroHigh32: fact.zeroHigh))
                byStorage[fact.value, default: []].insert(id)
            }
            let storage = byStorage.keys.sorted { renderedName($0) < renderedName($1) }.compactMap { value -> StorageBinding? in
                guard let ids = byStorage[value], let id = ids.first, let fact = facts[id] else { return nil }
                return StorageBinding(storage: value, definitions: ids, type: fact.type, mutable: mutable.contains(value))
            }
            if RejectedCFGDiagnostics.sink != nil { diagnosticSucceeded = true }
            return DecodedScalarNativeValuePlan(groups: groups, branchConditions: branchConditions,
                edgeCopies: edgeCopies, declarations: declarations, printedDeclarationValues: printed,
                valueTypes: types, namedValues: named, ownedRows: Set(rows.indices), useBindings: uses,
                conditionBindings: conditionBindings, edgeBindings: edgeBindings,
                definitionBindings: definitions, storageBindings: storage,
                originalFunction: function, originalCFG: cfg)
        }

        func ordered(_ left: DefinitionID, _ right: DefinitionID) -> Bool {
            func key(_ id: DefinitionID) -> (Int, Int, Int) {
                switch id {
                case let .entry(register): return (0, register, 0)
                case let .source(row, slot): return (1, row, slot)
                case let .join(block, register): return (2, block, register)
                }
            }
            return key(left) < key(right)
        }
        func fresh() -> MacIRValue? {
            while nextTemporary < Int.max {
                let value = MacIRValue.temporary(nextTemporary)
                nextTemporary += 1
                let name = renderedName(value)
                if usedValues.contains(value) || usedNames.contains(name) { continue }
                guard validName(name) else { failed = true; return nil }
                usedValues.insert(value); usedNames.insert(name)
                return value
            }
            failed = true; return nil
        }
        func originalDestinations(_ operation: MacIROperation) -> [MacIRValue] {
            switch operation {
            case let .assign(destination, _), let .binary(destination, _, _, _),
                 let .load(destination, _): return [destination]
            case let .loadWriteback(destination, base, _, _, _): return [destination, base]
            case let .storeWriteback(_, base, _, _, _): return [base]
            case let .intrinsic(nil, "restore_pair", arguments): return Array(arguments.prefix(2))
            default: return []
            }
        }
        func compatible(_ value: MacIRValue, _ register: Register) -> Bool {
            guard case let .register(name, _) = value, let view = Register(name) else { return false }
            return view == register
        }
        func permitsSourceIdentity(_ value: MacIRValue, register: Register, type: String) -> Bool {
            guard compatible(value, register),
                  authoritativeTypes[value] == nil || authoritativeTypes[value] == type,
                  case let .register(name, version) = value else { return false }
            return function.nameBindings.allSatisfy { binding in
                guard binding.target == .register(name: name, version: version),
                      let authoritative = binding.type else { return true }
                return authoritative == type
            }
        }
        func allocateDefinitions() -> Bool {
            for entry in state.entries {
                guard facts[.entry(entry.register.index)] == nil,
                      entry.initializedMask == (entry.register.width == 32 ? 1 : 3) else { return false }
                facts[.entry(entry.register.index)] = Fact(value: entry.value, width: entry.register.width,
                    type: entry.type, zeroHigh: false)
            }
            var assigned: Set<MacIRValue> = []
            for row in rows.indices {
                let originals = originalDestinations(function.instructions[row].operation)
                var definitions: [DefinitionID] = []
                for (slot, register) in rows[row].writes.enumerated() {
                    guard !register.isZero else { return false }
                    // An unsigned narrow native RHS is an exact representation
                    // of the zero-extended architectural W result. All W/X uses
                    // below explicitly widen it; it cannot narrow a join.
                    let nativeWidth: Int
                    if case let .load(_, _, bytes, _) = rows[row], slot == 0 { nativeWidth = bytes * 8 }
                    else { nativeWidth = register.width }
                    let type = "uint\(nativeWidth)_t"
                    let value: MacIRValue
                    if slot < originals.count,
                       permitsSourceIdentity(originals[slot], register: register, type: type) {
                        value = originals[slot]
                    } else {
                        // An incompatible original binding keeps its dormant
                        // type/name. Only this exact source write receives new
                        // native storage; no architectural cell bank is made.
                        guard let temporary = fresh() else { return false }
                        value = temporary
                    }
                    guard assigned.insert(value).inserted,
                          !state.entries.contains(where: { $0.value == value }) else { return false }
                    let id = DefinitionID.source(row: row, slot: slot)
                    facts[id] = Fact(value: value, width: register.width, type: type,
                        zeroHigh: register.width == 32)
                    definitions.append(id)
                }
                rowDefinitions.append(definitions)
            }
            return !failed
        }
        func canonical(_ id: DefinitionID) -> DefinitionID {
            var current = id, seen: Set<DefinitionID> = []
            while let next = replacements[current] {
                guard seen.insert(current).inserted else { failed = true; return current }
                current = next
            }
            return current
        }
        func activeDefinitions() -> Set<DefinitionID> {
            Set(facts.keys.filter { id in
                if case .join = id { return canonical(id) == id && phiInputs[id] != nil }
                return true
            })
        }
        func activePhis(_ block: Int? = nil) -> Set<DefinitionID> {
            Set(phiInputs.keys.filter { id in
                guard canonical(id) == id, case let .join(owner, _) = id else { return false }
                return block == nil || block == owner
            })
        }
        func register(of id: DefinitionID) -> Register? {
            switch id {
            case let .entry(index): return state.entries.first { $0.register.index == index }?.register
            case let .source(row, slot): return rows[row].writes[slot]
            case let .join(_, index):
                guard let fact = facts[id] else { return nil }
                return Register("\(fact.width == 32 ? "w" : "x")\(index)")
            }
        }
        func computeDemand() {
            let empty = Array(repeating: UInt8(0), count: 30)
            incomingDemand = Array(repeating: empty, count: cfg.blocks.count)
            var changed = true
            while changed {
                changed = false
                for block in cfg.blocks.reversed() {
                    var current = empty
                    for successor in block.successors {
                        for register in 0..<30 { current[register] |= incomingDemand[successor][register] }
                    }
                    for row in block.instructionRange.reversed() {
                        for register in rows[row].writes { current[register.index] = 0 }
                        for register in rows[row].reads where !register.isZero {
                            current[register.index] |= register.width == 32 ? 1 : 3
                        }
                    }
                    if current != incomingDemand[block.index] { incomingDemand[block.index] = current; changed = true }
                }
            }
        }
        func exitValue(_ block: Int, register: Int) -> DefinitionID? {
            for row in cfg.blocks[block].instructionRange.reversed() {
                if let slot = rows[row].writes.firstIndex(where: { $0.index == register }) {
                    return rowDefinitions[row][slot]
                }
            }
            return entryValue(block, register: register)
        }
        func entryValue(_ block: Int, register: Int) -> DefinitionID? {
            let key = Key(block: block, register: register)
            if let id = entryCache[key] { return id }
            guard incomingDemand[block][register] != 0 else { return nil }
            if block == cfg.entryIndex {
                let id = DefinitionID.entry(register)
                guard facts[id] != nil else { return nil }
                entryCache[key] = id; return id
            }
            let predecessors = cfg.blocks[block].predecessors
            guard !predecessors.isEmpty else { return nil }
            if predecessors.count > 1 {
                let id = DefinitionID.join(block: block, register: register)
                guard let value = fresh() else { return nil }
                entryCache[key] = id
                let width = incomingDemand[block][register] == 1 ? 32 : 64
                facts[id] = Fact(value: value, width: width, type: "uint\(width)_t", zeroHigh: false)
                var inputs: [CFGEdge: DefinitionID] = [:]
                for predecessor in predecessors {
                    guard let input = exitValue(predecessor, register: register) else { failed = true; return nil }
                    inputs[CFGEdge(predecessor, block)] = input
                }
                phiInputs[id] = inputs
                return id
            }
            guard resolving.insert(key).inserted,
                  let id = exitValue(predecessors[0], register: register) else { failed = true; return nil }
            resolving.remove(key); entryCache[key] = id
            return id
        }
        func solveValues() -> Bool {
            rowOwners = Array(repeating: -1, count: rows.count)
            for block in cfg.blocks {
                for row in block.instructionRange {
                    guard rowOwners[row] == -1 else { return false }
                    rowOwners[row] = block.index
                }
            }
            guard rowOwners.allSatisfy({ $0 >= 0 }) else { return false }
            computeDemand()
            for block in cfg.blocks {
                for register in 0..<30 where incomingDemand[block.index][register] != 0 {
                    guard entryValue(block.index, register: register) != nil else { return false }
                }
            }
            var changed = true
            while changed {
                changed = false
                for id in phiInputs.keys.sorted(by: ordered) where canonical(id) == id {
                    guard let inputs = phiInputs[id] else { return false }
                    let others = Set(inputs.values.map(canonical).filter { $0 != id })
                    if others.count == 1, let only = others.first { replacements[id] = only; changed = true }
                    else if others.isEmpty { return false }
                }
            }
            before = Array(repeating: Array(repeating: nil, count: 30), count: rows.count)
            after = before
            for block in cfg.blocks {
                var current = (0..<30).map { entryCache[Key(block: block.index, register: $0)].map(canonical) }
                for row in block.instructionRange {
                    before[row] = current
                    for register in rows[row].reads where !register.isZero {
                        guard let id = current[register.index], let fact = facts[id],
                              register.width <= fact.width || fact.zeroHigh else { return false }
                    }
                    for (slot, register) in rows[row].writes.enumerated() {
                        current[register.index] = rowDefinitions[row][slot]
                    }
                    after[row] = current
                }
            }
            return !failed
        }
        func readDefinitions(_ row: Int) -> Set<DefinitionID> {
            Set(rows[row].reads.compactMap { $0.isZero ? nil : before[row][$0.index] })
        }
        func bindConditions() -> Bool {
            guard Set(state.conditionOrigins.keys) == Set(state.branchConditions.keys) else { return false }
            for row in state.conditionOrigins.keys.sorted() {
                guard let origin = state.conditionOrigins[row], origin.consumerRow == row else { return false }
                let definitions: Set<DefinitionID>
                if let writer = origin.writerRow {
                    guard writer < row, rowOwners[writer] == rowOwners[row] else { return false }
                    switch rows[writer] {
                    case .compare: definitions = readDefinitions(writer)
                    case .binary(_, "-", _, _, true):
                        guard ["eq", "ne"].contains(origin.condition), let output = rowDefinitions[writer].first else { return false }
                        definitions = [output]
                    default: return false
                    }
                } else {
                    guard case .zero = rows[row] else { return false }
                    definitions = readDefinitions(row)
                }
                conditionBindings[row] = ConditionBinding(consumerRow: row,
                    writerRow: origin.writerRow, definitions: definitions)
            }
            return true
        }

        /// Liveness is over semantic definitions, including the historical CMP
        /// operands at the branch consumer. Edge-specific phi RHSs are read
        /// before the simultaneous phi destinations, never as ordinary row uses.
        func computeInterference() -> Bool {
            let phis = activePhis()
            var rowUses: [Set<DefinitionID>] = rows.indices.map { readDefinitions($0) }
            for (row, binding) in conditionBindings { rowUses[row].formUnion(binding.definitions) }
            let rowDefs: [Set<DefinitionID>] = rowDefinitions.map { Set($0) }
            var liveIn = Array(repeating: Set<DefinitionID>(), count: cfg.blocks.count)
            func edgeLive(_ edge: CFGEdge) -> Set<DefinitionID> {
                var result = liveIn[edge.to].subtracting(activePhis(edge.to))
                for id in phis {
                    if let input = phiInputs[id]?[edge] { result.insert(canonical(input)) }
                }
                return result
            }
            var changed = true
            while changed {
                changed = false
                for block in cfg.blocks.reversed() {
                    var current: Set<DefinitionID> = []
                    for successor in block.successors { current.formUnion(edgeLive(CFGEdge(block.index, successor))) }
                    for row in block.instructionRange.reversed() {
                        current.subtract(rowDefs[row]); current.formUnion(rowUses[row])
                    }
                    current.subtract(activePhis(block.index))
                    if current != liveIn[block.index] { liveIn[block.index] = current; changed = true }
                }
            }
            func conflict(_ definition: DefinitionID, _ others: Set<DefinitionID>) {
                for other in others where other != definition {
                    interference[definition, default: []].insert(other)
                    interference[other, default: []].insert(definition)
                }
            }
            for block in cfg.blocks {
                var current: Set<DefinitionID> = []
                for successor in block.successors { current.formUnion(edgeLive(CFGEdge(block.index, successor))) }
                for row in block.instructionRange.reversed() {
                    for definition in rowDefs[row] { conflict(definition, current.union(rowDefs[row])) }
                    current.subtract(rowDefs[row]); current.formUnion(rowUses[row])
                }
                let incomingPhis = activePhis(block.index)
                for definition in incomingPhis { conflict(definition, current.union(incomingPhis)) }
            }
            return !failed
        }

        /// Only a live join and source definitions in its own same-register
        /// incoming web may share storage. Entry formals are never mutated.
        func coalesceJoins() -> Bool {
            let active = activeDefinitions()
            var representative = Dictionary(uniqueKeysWithValues: active.map { ($0, $0) })
            var members = Dictionary(uniqueKeysWithValues: active.map { ($0, Set([$0])) })
            for phi in activePhis().sorted(by: ordered) {
                guard let inputs = phiInputs[phi] else { return false }
                let orderedInputs = inputs.keys.sorted { a, b in
                    let aBack = cfg.backEdges.contains(a), bBack = cfg.backEdges.contains(b)
                    return aBack != bBack ? aBack : (a.from == b.from ? a.to < b.to : a.from < b.from)
                }
                for edge in orderedInputs {
                    guard let raw = inputs[edge] else { return false }
                    let input = canonical(raw)
                    guard case .source = input else { continue }
                    guard let left = representative[phi], let right = representative[input], left != right,
                          let a = members[left], let b = members[right],
                          let pf = facts[phi], let sf = facts[input], pf.type == sf.type, pf.width == sf.width,
                          register(of: phi)?.index == register(of: input)?.index else { continue }
                    if a.contains(where: { !(interference[$0] ?? []).isDisjoint(with: b) }) { continue }
                    let combined = a.union(b)
                    // Retain a genuine source identity, preferring the first
                    // selected (normally backedge) source for the whole web.
                    let owner: DefinitionID
                    if case .source = left { owner = left }
                    else { owner = right }
                    members.removeValue(forKey: left); members.removeValue(forKey: right)
                    members[owner] = combined
                    for id in combined { representative[id] = owner }
                }
            }
            for id in active {
                guard let owner = representative[id], let original = facts[id], let target = facts[owner],
                      original.type == target.type else { return false }
                facts[id] = Fact(value: target.value, width: original.width, type: original.type, zeroHigh: original.zeroHigh)
            }
            return true
        }
        func validateStorageInterference() -> Bool {
            for id in activeDefinitions() {
                guard let fact = facts[id] else { return false }
                for other in interference[id] ?? [] {
                    guard facts[other]?.value != fact.value else { return false }
                }
            }
            return true
        }
        func validateConditionStability() -> Bool {
            for binding in conditionBindings.values {
                guard let writer = binding.writerRow else { continue }
                let retained = Set(binding.definitions.compactMap { facts[$0]?.value })
                guard retained.count == Set(binding.definitions).count else { return false }
                for row in (writer + 1)..<binding.consumerRow {
                    for definition in rowDefinitions[row] {
                        guard let fact = facts[definition], !retained.contains(fact.value) else { return false }
                    }
                }
            }
            return true
        }

        func expression(_ op: String, _ left: MacIRValue, _ right: MacIRValue) -> MacIRValue {
            .binaryExpression(op: op, left: left, right: right)
        }
        func project(_ value: MacIRValue, _ width: Int) -> MacIRValue {
            let op = "(uint\(width)_t)"
            if case let .unary(existing, _) = value, existing == op { return value }
            return .unary(op: op, value: value)
        }
        func unsigned(_ id: DefinitionID, width: Int) -> MacIRValue? {
            guard let fact = facts[canonical(id)], width <= fact.width || fact.zeroHigh else { return nil }
            return fact.type == "uint\(width)_t" ? fact.value : project(fact.value, width)
        }
        func read(_ register: Register, row: Int) -> MacIRValue? {
            if register.isZero { return project(.immediate(0), register.width) }
            guard let id = before[row][register.index] else { return nil }
            return unsigned(id, width: register.width)
        }
        func operand(_ operand: Operand, row: Int, width: Int) -> MacIRValue? {
            switch operand {
            case let .register(register): return read(register, row: row)
            case let .immediate(value): return project(.immediate(value), width)
            }
        }
        func address(_ address: Address, row: Int) -> MacIRValue? {
            guard var result = read(address.base, row: row) else { return nil }
            if let index = address.index {
                guard let bits = read(index, row: row) else { return nil }
                var offset = index.width == 32 ? project(bits, 64) : bits
                if address.shift != 0 { offset = expression("<<", offset, .immediate(Int64(address.shift))) }
                result = expression("+", result, offset)
            }
            if address.displacement != 0 {
                result = expression("+", result, project(.immediate(address.displacement), 64))
            }
            return result
        }
        func destination(_ row: Int, _ slot: Int = 0) -> MacIRValue? {
            guard rowDefinitions[row].indices.contains(slot) else { return nil }
            return facts[rowDefinitions[row][slot]]?.value
        }
        func append(_ operation: MacIROperation, row: Int, memory: MacIRMemoryAccess? = nil) {
            groups[row].append(.instruction(MacIRInstruction(source: function.instructions[row].source,
                operation: operation, memoryAccess: memory)))
        }
        func assign(_ row: Int, value: MacIRValue, slot: Int = 0) -> Bool {
            guard let output = destination(row, slot), let fact = facts[rowDefinitions[row][slot]] else { return false }
            append(.assign(destination: output, source: project(value, fact.width)), row: row)
            return true
        }
        func signBit(_ width: Int) -> MacIRValue {
            width == 32 ? project(.immediate(0x8000_0000), 32)
                : expression("<<", project(.immediate(1), 64), .immediate(63))
        }
        func condition(_ row: Int) -> BranchCondition? {
            guard let origin = state.conditionOrigins[row] else { return nil }
            let left: MacIRValue, right: MacIRValue, op: String
            if let writer = origin.writerRow {
                switch rows[writer] {
                case let .compare(register, other):
                    guard var a = read(register, row: writer),
                          var b = operand(other, row: writer, width: register.width) else { return nil }
                    switch origin.condition {
                    case "eq": op = "=="
                    case "ne": op = "!="
                    case "lo": op = "<"
                    case "hs": op = ">="
                    case "lt", "gt":
                        // XOR by the same-width unsigned sign bit preserves
                        // signed ordering without implementation-defined casts.
                        let mask = signBit(register.width)
                        a = expression("^", a, mask); b = expression("^", b, mask)
                        op = origin.condition == "lt" ? "<" : ">"
                    default: return nil
                    }
                    left = a; right = b
                case let .binary(register, "-", _, _, true):
                    guard let id = rowDefinitions[writer].first,
                          let value = unsigned(id, width: register.width),
                          origin.condition == "eq" || origin.condition == "ne" else { return nil }
                    left = value; right = project(.immediate(0), register.width)
                    op = origin.condition == "eq" ? "==" : "!="
                default: return nil
                }
            } else {
                guard case let .zero(register, _) = rows[row], let value = read(register, row: row) else { return nil }
                left = value; right = project(.immediate(0), register.width); op = "=="
            }
            return BranchCondition(branchIndex: row, compareIndex: nil, left: left,
                condition: op, right: right, isZeroCheck: false)
        }
        func prepareRows() -> Bool {
            for row in rows.indices {
                switch rows[row] {
                case let .move(register, source):
                    guard let value = operand(source, row: row, width: register.width), assign(row, value: value) else { return false }
                case let .binary(register, op, left, right, _):
                    guard let a = operand(left, row: row, width: register.width),
                          let b = operand(right, row: row, width: register.width),
                          assign(row, value: expression(op, a, b)) else { return false }
                case let .signExtend(_, source):
                    guard let output = destination(row), let low = read(source, row: row) else { return false }
                    let wide = project(low, 64)
                    let high = MacIRValue.unary(op: "~", value: project(.immediate(0xffff_ffff), 64))
                    append(.select(destination: output, condition: "==",
                        left: expression("&", low, signBit(32)), right: .immediate(0),
                        trueValue: wide, falseValue: expression("|", wide, high)), row: row)
                case let .load(register, location, bytes, delta):
                    guard let output = destination(row), let pointer = address(location, row: row) else { return false }
                    append(.load(destination: output, address: pointer), row: row,
                        memory: MacIRMemoryAccess(byteWidth: bytes, extensionKind: bytes * 8 < register.width ? .zero : .none))
                    if let delta {
                        guard let base = read(location.base, row: row),
                              assign(row, value: expression("+", base, project(.immediate(delta), 64)), slot: 1) else { return false }
                    }
                case let .store(register, location, bytes, delta):
                    guard let data = read(register, row: row), let pointer = address(location, row: row) else { return false }
                    append(.store(source: project(data, bytes * 8), address: pointer), row: row,
                        memory: MacIRMemoryAccess(byteWidth: bytes))
                    if let delta {
                        guard let base = read(location.base, row: row),
                              assign(row, value: expression("+", base, project(.immediate(delta), 64))) else { return false }
                    }
                case let .pair(_, _, location):
                    guard let pointer = address(location, row: row), let first = destination(row), let second = destination(row, 1) else { return false }
                    // The certified grammar excludes base/destination aliases;
                    // same-register-only coalescing preserves that distinction.
                    append(.load(destination: first, address: pointer), row: row, memory: MacIRMemoryAccess(byteWidth: 8))
                    append(.load(destination: second, address: expression("+", pointer, project(.immediate(8), 64))),
                        row: row, memory: MacIRMemoryAccess(byteWidth: 8))
                case .conditional, .zero:
                    guard let predicate = condition(row) else { return false }
                    branchConditions[row] = predicate
                case .returned: groups[row].append(.protectedOriginal(row: row))
                case .compare, .jump: break
                }
            }
            return true
        }

        func prepareEdges() -> Bool {
            var pending: [CFGEdge: [Copy]] = [:]
            for id in activePhis().sorted(by: ordered) {
                guard let inputs = phiInputs[id], case let .join(block, register) = id, let target = facts[id],
                      Set(inputs.keys) == Set(cfg.blocks[block].predecessors.map { CFGEdge($0, block) }) else { return false }
                for edge in inputs.keys.sorted(by: { $0.from < $1.from }) {
                    guard let raw = inputs[edge], let last = cfg.blocks[edge.from].instructionRange.last else { return false }
                    let input = canonical(raw)
                    guard cfg.blocks[edge.from].successors.filter({ $0 == edge.to }).count == 1,
                          after[last][register] == input,
                          let bits = unsigned(input, width: target.width) else { return false }
                    edgeBindings.append(EdgeBinding(edge: edge, register: register, source: input, destination: id))
                    if target.value != bits {
                        pending[edge, default: []].append(Copy(destination: target.value, source: bits, type: target.type))
                    }
                }
            }
            for edge in pending.keys.sorted(by: { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }) {
                guard let copies = pending[edge], let lowered = parallel(copies, edge: edge) else { return false }
                edgeCopies[edge] = lowered
            }
            return true
        }
        func parallel(_ copies: [Copy], edge: CFGEdge) -> [MacIRInstruction]? {
            guard Set(copies.map(\.destination)).count == copies.count,
                  let row = cfg.blocks[edge.from].instructionRange.last else { return nil }
            var pending = copies, result: [MacIRInstruction] = []
            func emit(_ destination: MacIRValue, _ source: MacIRValue) {
                result.append(MacIRInstruction(source: function.instructions[row].source,
                    operation: .assign(destination: destination, source: source)))
            }
            while !pending.isEmpty {
                if let index = pending.indices.first(where: { index in
                    !pending.indices.contains { other in
                        other != index && atoms(pending[other].source).contains(pending[index].destination)
                    }
                }) {
                    let copy = pending.remove(at: index); emit(copy.destination, copy.source)
                } else {
                    guard let first = pending.first, let type = integerType(first.type), type.unsigned,
                          let temporary = fresh() else { return nil }
                    cycleDeclarations.append(Declaration(storage: temporary, type: first.type,
                        initializer: nil, origin: .parallelCycle(edge)))
                    emit(temporary, project(first.destination, type.width))
                    pending = pending.map { copy in
                        Copy(destination: copy.destination,
                            source: replacing(copy.source, old: first.destination, new: temporary), type: copy.type)
                    }
                }
            }
            return result
        }

        func declarationsAndTypes() -> (declarations: [Declaration], types: [MacIRValue: String], mutable: Set<MacIRValue>)? {
            var declarations: [Declaration] = [], types: [MacIRValue: String] = [:]
            var mutable = Set(cycleDeclarations.map(\.storage))
            for id in activeDefinitions().sorted(by: ordered) {
                guard let fact = facts[id] else { return nil }
                let origin: DeclarationOrigin
                switch id {
                case .entry: continue
                case let .source(row, slot): origin = .source(row: row, slot: slot)
                case let .join(block, register):
                    origin = .join(block: block, register: register); mutable.insert(fact.value)
                }
                if let existing = types[fact.value] { guard existing == fact.type else { return nil }; continue }
                types[fact.value] = fact.type
                declarations.append(Declaration(storage: fact.value, type: fact.type, initializer: nil, origin: origin))
            }
            for declaration in cycleDeclarations {
                guard types[declaration.storage] == nil else { return nil }
                types[declaration.storage] = declaration.type; declarations.append(declaration)
            }
            return (declarations, types, mutable)
        }
        func requiredPrintedDeclarations(_ declarations: [Declaration], types: [MacIRValue: String],
                                         mutable: Set<MacIRValue>) -> Set<MacIRValue> {
            var sites: [MacIRValue: [MacIRInstruction]] = [:]
            func record(_ instruction: MacIRInstruction) {
                let destination: MacIRValue?
                switch instruction.operation {
                case let .assign(value, _), let .load(value, _), let .select(value, _, _, _, _, _): destination = value
                default: destination = nil
                }
                if let destination { sites[destination, default: []].append(instruction) }
            }
            for group in groups { for item in group { if case let .instruction(instruction) = item { record(instruction) } } }
            for copies in edgeCopies.values { copies.forEach(record) }
            var printed = Set(declarations.map(\.storage)), pending: Set<MacIRValue> = []
            var known = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.value, $0.type) })
            for declaration in declarations {
                if !mutable.contains(declaration.storage), sites[declaration.storage]?.count == 1 { pending.insert(declaration.storage) }
                else { known[declaration.storage] = declaration.type }
            }
            var changed = true
            while changed {
                changed = false
                for value in pending.sorted(by: { renderedName($0) < renderedName($1) }) {
                    guard let site = sites[value]?.first, let type = types[value], let inferred = inferredRHS(site, known: known) else { continue }
                    if inferred == type { printed.remove(value) }
                    known[value] = type; pending.remove(value); changed = true
                }
            }
            return printed
        }
        func integerType(_ type: String) -> (width: Int, unsigned: Bool)? {
            for width in [8, 16, 32, 64] {
                if type == "uint\(width)_t" { return (width, true) }
                if type == "int\(width)_t" { return (width, false) }
            }
            return nil
        }
        func promoted(_ type: String) -> String? {
            guard let integer = integerType(type) else { return nil }
            return integer.width < 32 ? "int32_t" : type
        }
        func common(_ left: String, _ right: String) -> String? {
            guard let l = promoted(left), let r = promoted(right), let a = integerType(l), let b = integerType(r) else { return nil }
            if a.width == b.width { return "\(a.unsigned || b.unsigned ? "uint" : "int")\(a.width)_t" }
            return a.width > b.width ? l : r
        }
        func inferredValue(_ value: MacIRValue, known: [MacIRValue: String]) -> String? {
            switch value {
            case .register, .temporary, .argument: return known[value]
            case .signedBitfield: return nil
            case let .immediate(number):
                let magnitude = number.magnitude
                if magnitude <= UInt64(Int32.max) { return "int32_t" }
                if magnitude <= UInt64(UInt32.max) { return "uint32_t" }
                return magnitude <= UInt64(Int64.max) ? "int64_t" : "uint64_t"
            case let .unary(op, inner):
                guard let source = inferredValue(inner, known: known), integerType(source) != nil else { return nil }
                if op.hasPrefix("("), op.hasSuffix(")") {
                    let target = String(op.dropFirst().dropLast())
                    return integerType(target) == nil ? nil : target
                }
                return ["~", "-", "!"].contains(op) ? (op == "!" ? "int32_t" : promoted(source)) : nil
            case let .binaryExpression(op, left, right):
                guard let a = inferredValue(left, known: known), let b = inferredValue(right, known: known),
                      integerType(a) != nil, integerType(b) != nil else { return nil }
                if ["==", "!=", "<", "<=", ">", ">=", "&&", "||"].contains(op) { return "int32_t" }
                if ["<<", ">>"].contains(op) { return promoted(a) }
                return ["+", "-", "&", "|", "^"].contains(op) ? common(a, b) : nil
            default: return nil
            }
        }
        func inferredRHS(_ instruction: MacIRInstruction, known: [MacIRValue: String]) -> String? {
            switch instruction.operation {
            case let .assign(_, source): return inferredValue(source, known: known)
            case let .load(_, pointer):
                guard let access = instruction.memoryAccess,
                      let type = inferredValue(pointer, known: known), integerType(type)?.width == 64 else { return nil }
                // The caller additionally refuses context-dependent stack or
                // member sugar before relying on this native RHS certificate.
                return "\(access.extensionKind == .sign ? "int" : "uint")\(access.byteWidth * 8)_t"
            case let .select(_, _, left, right, yes, no):
                guard inferredValue(left, known: known) != nil, inferredValue(right, known: known) != nil,
                      let a = inferredValue(yes, known: known), let b = inferredValue(no, known: known) else { return nil }
                return common(a, b)
            default: return nil
            }
        }
        func operationValues(_ operation: MacIROperation) -> [MacIRValue] {
            switch operation {
            case let .assign(destination, source): return [destination, source]
            case let .load(destination, address): return [destination, address]
            case let .store(source, address): return [source, address]
            case let .select(destination, _, left, right, yes, no): return [destination, left, right, yes, no]
            default: return []
            }
        }
        func collectAtoms(_ value: MacIRValue, into result: inout Set<MacIRValue>) {
            switch value {
            case .register, .temporary, .argument: result.insert(value)
            case let .signedBitfield(node): collectAtoms(node.source, into: &result)
            case let .unary(_, inner), let .bitTest(inner, _): collectAtoms(inner, into: &result)
            case let .binaryExpression(_, left, right): collectAtoms(left, into: &result); collectAtoms(right, into: &result)
            default: break
            }
        }
        func atoms(_ value: MacIRValue) -> Set<MacIRValue> {
            var result: Set<MacIRValue> = []; collectAtoms(value, into: &result); return result
        }
        func replacing(_ value: MacIRValue, old: MacIRValue, new: MacIRValue) -> MacIRValue {
            if value == old { return new }
            switch value {
            case let .signedBitfield(node):
                return replacing(node.source, old: old, new: new) == node.source
                    ? value : .unknown("UNRESOLVED_SIGNED_BITFIELD_SOURCE_REWRITE")
            case let .unary(op, inner): return .unary(op: op, value: replacing(inner, old: old, new: new))
            case let .binaryExpression(op, left, right):
                return expression(op, replacing(left, old: old, new: new), replacing(right, old: old, new: new))
            default: return value
            }
        }
        func validateNames(_ named: Set<MacIRValue>) -> Bool {
            var owners: [String: MacIRValue] = [:]
            for entry in state.entries {
                let text = renderedName(entry.value)
                guard let parameter = function.parameters.first(where: { $0.bindingID == .gpr(entry.register.index) }),
                      text == parameter.name, validName(text), owners[text] == nil else { return false }
                owners[text] = entry.value
            }
            for value in named {
                let text = renderedName(value)
                guard validName(text), owners[text] == nil || owners[text] == value else { return false }
                owners[text] = value
            }
            return true
        }
        func validName(_ name: String) -> Bool {
            DecodedScalarNativeValuePlan.validName(name)
        }
    }

    private static func validName(_ name: String) -> Bool {
        let forbidden: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
            "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool",
            "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary",
            "_Noreturn", "_Static_assert", "_Thread_local", "alignas", "alignof", "constexpr",
            "false", "nullptr", "static_assert", "thread_local", "true", "typeof", "typeof_unqual",
            "_BitInt", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t"
        ]
        return !forbidden.contains(name) && name.range(of: #"\A[A-Za-z_][A-Za-z_0-9]*\z"#, options: .regularExpression) != nil
    }
}
