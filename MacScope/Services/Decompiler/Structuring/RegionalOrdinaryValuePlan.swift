import Foundation

/// A source-indexed emission overlay. Physical registers are proof keys only;
/// printed storage belongs to an original definition or a live incoming merge.
/// The original function, row envelopes and CFG are never rewritten.
struct RegionalOrdinaryValuePlan {
    enum Item {
        case instruction(MacIRInstruction)
        case protectedOriginal(row: Int)
    }
    enum DeclarationOrigin {
        case source(row: Int, slot: Int)
        case join(block: Int, register: Int)
        case boundaryAlias
        case parallelCycle(CFGEdge)
        case boundaryCycle(row: Int)
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
        case callResult(Int)
        case join(block: Int, register: Int)
    }
    struct UseBinding {
        let row: Int
        let ordinal: Int
        let register: RegionalBoundaryPlan.Register
        let definition: DefinitionID
        let value: MacIRValue
    }
    struct BoundaryAliasLifetime {
        let row: Int
        let writtenAliases: Set<MacIRValue>
        let invalidatedCurrentDefinitions: Set<DefinitionID>
        let survivingLiveDefinitions: Set<DefinitionID>
        let resultDefinition: DefinitionID?
    }
    struct SourceAliasLifetime {
        let row: Int
        let writtenAlias: MacIRValue
        let definition: DefinitionID
        let invalidatedCurrentDefinitions: Set<DefinitionID>
        let survivingDefinitions: Set<DefinitionID>
        /// A full-width signed interpretation of the same eight loaded bytes,
        /// not a changed source opcode, extension, address or access order.
        let fullWidthSignedLoad: Bool
    }
    struct ConditionBinding {
        let consumerRow: Int
        let writerRows: Set<Int>
        let definitions: Set<DefinitionID>
    }
    struct EdgeBinding {
        let edge: CFGEdge
        let register: Int
        let source: DefinitionID
        let destination: DefinitionID
    }

    let groups: [[Item]]
    let branchConditions: [Int: BranchCondition]
    let switches: [Int: MacIROperation]
    let edgeCopies: [CFGEdge: [MacIRInstruction]]
    let declarations: [Declaration]
    /// All declarations remain type/name certificates. Only storage which
    /// cannot use the native single-definition RHS convention is printed.
    let printedDeclarationValues: Set<MacIRValue>
    let valueTypes: [MacIRValue: String]
    let namedValues: Set<MacIRValue>
    let ownedRows: Set<Int>
    let useBindings: [UseBinding]
    let edgeBindings: [EdgeBinding]
    let conditionBindings: [Int: ConditionBinding]
    let boundaryAliasLifetimes: [BoundaryAliasLifetime]
    let sourceAliasLifetimes: [SourceAliasLifetime]
    private let originalFunction: MacIRFunction
    private let originalCFG: CFG

    /// Available only after the reaching-definition/phi walk, width checks,
    /// alias lifetimes and edge-copy proof have all succeeded.
    var provedPositions: Set<RegionalProvedPosition> {
        let reads = Set(useBindings.map {
            RegionalProvedPosition(address: originalFunction.instructions[$0.row].source.address,
                register: $0.register.index, width: $0.register.width)
        })
        return reads.union(RegionalLexicalProof.flagPositions(
            function: originalFunction, cfg: originalCFG, provedReads: reads))
    }

    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        function == originalFunction && cfg.blocks == originalCFG.blocks &&
            cfg.entryIndex == originalCFG.entryIndex && cfg.domTree == originalCFG.domTree &&
            cfg.postDomTree == originalCFG.postDomTree && cfg.loopHeaders == originalCFG.loopHeaders &&
            cfg.backEdges == originalCFG.backEdges && cfg.irreducibleBlocks == originalCFG.irreducibleBlocks &&
            cfg.blockByStartIndex == originalCFG.blockByStartIndex &&
            cfg.hasUnresolvedTargets == originalCFG.hasUnresolvedTargets
    }

    static func prove(function: MacIRFunction, cfg: CFG,
                      certifiedBy physical: RegionalPhysicalStatePlan,
                      lexicalProof: RegionalLexicalProof? = nil,
                      diagnosticFile: StaticString = #fileID,
                      diagnosticLine: UInt = #line) -> Self? {
        // The outer gates can decline a completed planner. Record this actual
        // outcome separately; planner completion never claims admission.
        var diagnosticID: UUID? = nil
        var diagnosticSucceeded = false
        if let sink = RejectedCFGDiagnostics.sink {
            let id = UUID()
            diagnosticID = id
            sink(.ordinaryProofBegin(id: id, start: function.startAddress,
                file: String(describing: diagnosticFile), line: Int(diagnosticLine)))
        }
        defer {
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.ordinaryProofEnd(id: id, succeeded: diagnosticSucceeded))
            }
        }
        guard physical.matches(function: function, cfg: cfg),
              physical.certifiedRows.count == function.instructions.count,
              physical.liveIncoming.count == cfg.blocks.count,
              physical.liveAfter.count == function.instructions.count else { return nil }
        guard lexicalProof == nil || lexicalProof?.function == function,
              let result = Planner(function: function, cfg: cfg, physical: physical).make(),
              physical.permitsJoinedAddressUses(result),
              lexicalProof?.isCovered(by: result.provedPositions) != false
                else { return nil }
        if RejectedCFGDiagnostics.sink != nil { diagnosticSucceeded = true }
        return result
    }

    private final class Planner {
        typealias Register = RegionalBoundaryPlan.Register
        typealias Row = RegionalPhysicalStatePlan.Row
        typealias Operand = RegionalPhysicalStatePlan.Operand
        typealias Address = RegionalPhysicalStatePlan.Address
        struct Fact {
            let value: MacIRValue
            let width: Int
            let type: String
            /// W definitions have zero high bits; a narrow entry need not.
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
        let physical: RegionalPhysicalStatePlan
        let rows: [Row]
        var facts: [DefinitionID: Fact] = [:]
        var rowDefinitions: [[DefinitionID]] = []
        var entryCache: [Key: DefinitionID] = [:]
        var unavailableEntries: Set<Key> = []
        var resolvingEntries: Set<Key> = []
        var phiInputs: [DefinitionID: [CFGEdge: DefinitionID]] = [:]
        var replacement: [DefinitionID: DefinitionID] = [:]
        var before: [[DefinitionID?]] = []
        var after: [[DefinitionID?]] = []
        var rowOwners: [Int] = []
        var declarations: [Declaration] = []
        var declarationValues: Set<MacIRValue> = []
        var assignedValues: Set<MacIRValue> = []
        var usedValues: Set<MacIRValue>
        var nextTemporary: Int
        var groups: [[Item]]
        var branchConditions: [Int: BranchCondition] = [:]
        var switches: [Int: MacIROperation] = [:]
        var edgeCopies: [CFGEdge: [MacIRInstruction]] = [:]
        var useBindings: [UseBinding] = []
        var edgeBindings: [EdgeBinding] = []
        var conditionWriters: [Int: Set<Int>] = [:]
        var conditionDefinitions: [Int: Set<DefinitionID>] = [:]
        var boundaryAliasLifetimes: [BoundaryAliasLifetime] = []
        var sourceAliases: [Int: DefinitionID] = [:]
        var signedLoadAliases: Set<Int> = []
        var sourceAliasLifetimes: [SourceAliasLifetime] = []
        var flagAnalysis: RegionalSingleCMPConditionPlan.Analysis?
        var incomingDemand: [[UInt8]] = []
        var afterDemand: [[UInt8]] = []
        var additionalReads: [Int: Register] = [:]
        var failed = false

        init(function: MacIRFunction, cfg: CFG, physical: RegionalPhysicalStatePlan) {
            self.function = function; self.cfg = cfg; self.physical = physical
            rows = physical.certifiedRows
            usedValues = physical.boundaries.originalAtoms
            nextTemporary = (physical.boundaries.originalAtoms.compactMap { value -> Int? in
                if case let .temporary(index) = value { return index }; return nil
            }.max() ?? -1) + 1
            groups = Array(repeating: [], count: function.instructions.count)
        }

        func make(diagnosticFile: StaticString = #fileID,
                  diagnosticLine: UInt = #line) -> RegionalOrdinaryValuePlan? {
            // Copy the actual planner ledger even on early failure. A partial
            // ledger is never a successful plan and cannot grant admission.
            var diagnosticID: UUID? = nil
            var diagnosticSucceeded = false
            if let sink = RejectedCFGDiagnostics.sink {
                let id = UUID()
                diagnosticID = id
                sink(.ordinaryAttempt(id: id, start: function.startAddress,
                    addresses: function.instructions.map { $0.source.address },
                    parameters: function.parameters,
                    file: String(describing: diagnosticFile), line: Int(diagnosticLine)))
            }
            defer {
                if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                    sink(.ordinaryFacts(id: id, plannerCompleted: diagnosticSucceeded,
                        definitions: facts.mapValues {
                            .init(value: $0.value, width: $0.width, type: $0.type, zeroHigh: $0.zeroHigh)
                        }, uses: useBindings, edges: edgeBindings, phiInputs: phiInputs,
                        before: before, after: after, replacements: replacement))
                }
            }
            guard allocateDefinitions(), solveValues(), proveSourceAliasLifetimes(), proveBoundaryAliasLifetimes(),
                  prepareRows(), prepareEdges(), !failed else { return nil }
            // Only live, nontrivial merges survive. Removed provisional phis
            // have no declarations, copy instructions or emitted identifiers.
            let activePhis = Set(phiInputs.keys.filter { canonical($0) == $0 })
            declarations.removeAll { declaration in
                if case let .join(block, register) = declaration.origin {
                    return !activePhis.contains(.join(block: block, register: register))
                }
                return false
            }
            var types: [MacIRValue: String] = [:]
            for declaration in declarations {
                guard types[declaration.storage] == nil || types[declaration.storage] == declaration.type else { return nil }
                types[declaration.storage] = declaration.type
            }
            let printedDeclarations = requiredPrintedDeclarations(types: types)
            var named = physical.boundaries.originalAtoms
            for declaration in declarations { named.insert(declaration.storage) }
            for group in groups {
                for item in group {
                    if case let .instruction(instruction) = item {
                        guard let values = RegionalBoundaryPlan.values(instruction.operation) else { return nil }
                        values.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &named) }
                    }
                }
            }
            for instructions in edgeCopies.values {
                for instruction in instructions {
                    guard let values = RegionalBoundaryPlan.values(instruction.operation) else { return nil }
                    values.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &named) }
                }
            }
            var conditions: [Int: ConditionBinding] = [:]
            for (consumer, writers) in conditionWriters {
                conditions[consumer] = ConditionBinding(consumerRow: consumer,
                    writerRows: writers, definitions: conditionDefinitions[consumer] ?? [])
            }
            if RejectedCFGDiagnostics.sink != nil { diagnosticSucceeded = true }
            return RegionalOrdinaryValuePlan(groups: groups, branchConditions: branchConditions,
                switches: switches, edgeCopies: edgeCopies, declarations: declarations,
                printedDeclarationValues: printedDeclarations,
                valueTypes: types, namedValues: named, ownedRows: Set(rows.indices),
                useBindings: useBindings, edgeBindings: edgeBindings,
                conditionBindings: conditions, boundaryAliasLifetimes: boundaryAliasLifetimes,
                sourceAliasLifetimes: sourceAliasLifetimes,
                originalFunction: function, originalCFG: cfg)
        }

        func declare(_ value: MacIRValue, type: String, origin: DeclarationOrigin) {
            guard declarationValues.insert(value).inserted else {
                if declarations.first(where: { $0.storage == value })?.type != type { failed = true }
                return
            }
            declarations.append(Declaration(storage: value, type: type, initializer: nil, origin: origin))
        }
        struct PrintedDefinition {
            let instruction: MacIRInstruction?
            let protectedType: String?
        }
        /// Count prepared instructions, exact protected assignments and edge
        /// copies, not source-row definitions (one row may emit several writes).
        /// A missing/unknown RHS retains its declaration. Joins and cycle
        /// temporaries always retain explicit mutable storage.
        func requiredPrintedDeclarations(types: [MacIRValue: String]) -> Set<MacIRValue> {
            var sites: [MacIRValue: [PrintedDefinition]] = [:]
            func record(_ instruction: MacIRInstruction) {
                var destinations = originalDestinations(instruction.operation)
                if case let .intrinsic(nil, name, arguments) = instruction.operation,
                   arguments.count == 6 {
                    if name == "restore_pair_writeback" { destinations = Array(arguments.prefix(2)) + [arguments[3]] }
                    if name == "save_pair_writeback" { destinations = [arguments[3]] }
                }
                for destination in destinations {
                    sites[destination, default: []].append(PrintedDefinition(instruction: instruction, protectedType: nil))
                }
            }
            for group in groups {
                for item in group {
                    switch item {
                    case let .instruction(instruction): record(instruction)
                    case let .protectedOriginal(row):
                        if let call = physical.boundaries.calls[row] {
                            if let result = call.result {
                                sites[result.value, default: []].append(PrintedDefinition(instruction: nil, protectedType: result.type))
                            }
                        } else { record(function.instructions[row]) }
                    }
                }
            }
            for instructions in edgeCopies.values { instructions.forEach(record) }
            var printed = Set(declarations.map(\.storage))
            var pending: Set<MacIRValue> = []
            var known: [MacIRValue: String] = [:]
            for entry in physical.boundaries.entries { known[entry.value] = entry.type }
            for declaration in declarations {
                switch declaration.origin {
                case .source, .boundaryAlias:
                    if sites[declaration.storage]?.count == 1 { pending.insert(declaration.storage); continue }
                case .join, .parallelCycle, .boundaryCycle: break
                }
                known[declaration.storage] = declaration.type
            }
            // Resolve from formals, required carriers and frozen call results.
            // Do not use a candidate's own certificate as its inferred RHS type:
            // unresolved/cyclic single-definition dependencies remain declared.
            var changed = true
            while changed {
                changed = false
                for value in pending.sorted(by: { $0.description < $1.description }) {
                    guard let site = sites[value]?.first, let certified = types[value] else { continue }
                    let inferred = site.protectedType ?? site.instruction.flatMap { inferredRHS($0, known: known) }
                    guard let inferred else { continue }
                    if inferred == certified { printed.remove(value) }
                    known[value] = certified // Otherwise its declaration stays.
                    pending.remove(value); changed = true
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
        func promotedType(_ type: String) -> String? {
            guard let integer = integerType(type) else { return nil }
            return integer.width < 32 ? "int32_t" : type
        }
        func commonType(_ left: String, _ right: String) -> String? {
            guard let l = promotedType(left), let r = promotedType(right),
                  let a = integerType(l), let b = integerType(r) else { return nil }
            if a.width == b.width { return "\(a.unsigned || b.unsigned ? "uint" : "int")\(a.width)_t" }
            return a.width > b.width ? l : r
        }
        func inferredValue(_ value: MacIRValue, known: [MacIRValue: String]) -> String? {
            switch value {
            case .register, .temporary, .argument: return known[value]
            case .signedBitfield: return nil
            case let .immediate(number):
                // Native literals are hexadecimal, including the magnitude of
                // a negative spelling. Unary minus does not change that type.
                let magnitude = number.magnitude
                if magnitude <= UInt64(Int32.max) { return "int32_t" }
                if magnitude <= UInt64(UInt32.max) { return "uint32_t" }
                return magnitude <= UInt64(Int64.max) ? "int64_t" : "uint64_t"
            case let .unary(op, value):
                guard let source = inferredValue(value, known: known) else { return nil }
                if op.hasPrefix("("), op.hasSuffix(")") {
                    let target = String(op.dropFirst().dropLast())
                    guard integerType(target) != nil,
                          integerType(source) != nil || (source.hasSuffix("*") && target == "uint64_t") else { return nil }
                    return target
                }
                guard ["~", "-", "!"].contains(op), let promoted = promotedType(source) else { return nil }
                return op == "!" ? "int32_t" : promoted
            case let .binaryExpression(op, left, right):
                guard let a = inferredValue(left, known: known), let b = inferredValue(right, known: known),
                      integerType(a) != nil, integerType(b) != nil else { return nil }
                if ["==", "!=", "<", "<=", ">", ">=", "&&", "||"].contains(op) { return "int32_t" }
                if op == "<<" || op == ">>" { return promotedType(a) }
                guard ["+", "-", "*", "&", "|", "^"].contains(op) else { return nil }
                return commonType(a, b)
            default: return nil
            }
        }
        func inferredRHS(_ instruction: MacIRInstruction, known: [MacIRValue: String]) -> String? {
            switch instruction.operation {
            case let .assign(_, source): return inferredValue(source, known: known)
            case let .binary(_, op, left, right): return inferredValue(expression(op, left, right), known: known)
            case let .load(_, address):
                guard let access = instruction.memoryAccess, [1, 2, 4, 8].contains(access.byteWidth),
                      let addressType = inferredValue(address, known: known),
                      integerType(addressType)?.width == 64 else { return nil }
                // Existing native rendering uses the per-access integer type;
                // a bare, nonextending eight-byte dereference is uint64_t.
                return "\(access.extensionKind == .sign ? "int" : "uint")\(access.byteWidth * 8)_t"
            case let .select(_, _, left, right, yes, no):
                guard inferredValue(left, known: known) != nil, inferredValue(right, known: known) != nil,
                      let a = inferredValue(yes, known: known), let b = inferredValue(no, known: known) else { return nil }
                return commonType(a, b)
            case let .compareToBool(_, _, left, right):
                guard inferredValue(left, known: known) != nil, inferredValue(right, known: known) != nil else { return nil }
                return "int32_t"
            case let .intrinsic(_, name, arguments):
                guard arguments.allSatisfy({ inferredValue($0, known: known) != nil }) else { return nil }
                if name == "a64_sdiv32" { return "int32_t" }
                if name == "a64_udiv32" { return "uint32_t" }
                return nil
            default: return nil
            }
        }
        func fresh() -> MacIRValue {
            while usedValues.contains(.temporary(nextTemporary)) { nextTemporary += 1 }
            let result = MacIRValue.temporary(nextTemporary)
            nextTemporary += 1; usedValues.insert(result)
            return result
        }
        func originalDestinations(_ operation: MacIROperation) -> [MacIRValue] {
            switch operation {
            case let .assign(destination, _), let .binary(destination, _, _, _),
                 let .load(destination, _), let .select(destination, _, _, _, _, _),
                 let .compareToBool(destination, _, _, _): return [destination]
            case let .loadWriteback(destination, base, _, _, _): return [destination, base]
            case let .storeWriteback(_, base, _, _, _): return [base]
            case let .intrinsic(destination?, _, _): return [destination]
            case let .intrinsic(nil, name, arguments) where name == "restore_pair":
                return Array(arguments.prefix(2))
            default: return []
            }
        }
        func compatible(_ value: MacIRValue, register: Register) -> Bool {
            guard case let .register(name, _) = value,
                  let view = Register(name) else { return false }
            return view == register
        }
        func permitsSignedLoadAlias(_ alias: RegionalBoundaryPlan.Alias, row: Int) -> Bool {
            guard alias.type == "int64_t", alias.register.width == 64,
                  case let .load(register, _, bytes: 8, signed: false, delta: nil) = rows[row],
                  register == alias.register,
                  case let .load(destination, _) = function.instructions[row].operation,
                  destination == alias.value,
                  function.instructions[row].memoryAccess == MacIRMemoryAccess(byteWidth: 8),
                  physical.boundaries.terminal?.alias.value != alias.value else { return false }
            var found = false
            for call in physical.boundaries.calls.values {
                guard call.result?.value != alias.value else { return false }
                for input in call.inputs where input.value == alias.value {
                    let controls = call.frame.controlInputs.canonicalControlInputsForAudit
                    guard input == alias, controls.count == 1,
                          controls[0].role == .indirectTarget, controls[0].value == alias.value,
                          !call.frame.arguments.canonicalPhysicalEntriesForAudit.contains(where: { $0.value == alias.value }) else { return false }
                    found = true
                }
            }
            return found
        }
        func allocateDefinitions() -> Bool {
            for entry in physical.boundaries.entries {
                facts[.entry(entry.register.index)] = Fact(value: entry.value, width: entry.register.width,
                    type: entry.type, zeroHigh: false)
            }
            let aliases = Dictionary(uniqueKeysWithValues: physical.boundaries.aliases.map { ($0.value, $0) })
            // Dead protected results still own their original assignment. They
            // deliberately have no Fact, so assignedValues alone is not an
            // ownership check against reusing that spelling at a source row.
            let originalResultValues = Set(physical.boundaries.calls.values.compactMap { $0.result?.value })
            for alias in physical.boundaries.aliases where alias.projectedStorage == nil {
                declare(alias.value, type: alias.type, origin: .boundaryAlias)
            }
            for index in rows.indices {
                if let call = physical.boundaries.calls[index] {
                    if let result = call.result, physical.liveCallResultRows.contains(index) {
                        let id = DefinitionID.callResult(index)
                        guard assignedValues.insert(result.value).inserted else { return false }
                        facts[id] = Fact(value: result.value, width: result.register.width,
                            type: result.type, zeroHigh: false)
                        rowDefinitions.append([id])
                    } else { rowDefinitions.append([]) }
                    continue
                }
                let destinations = originalDestinations(function.instructions[index].operation)
                var definitions: [DefinitionID] = []
                for (slot, register) in rows[index].writes.enumerated() {
                    guard !register.isZero else { return false }
                    let id = DefinitionID.source(row: index, slot: slot)
                    var value = slot < destinations.count && compatible(destinations[slot], register: register)
                        ? destinations[slot] : fresh()
                    var type = "uint\(register.width)_t"
                    if case .load(_, _, _, true, _) = rows[index], slot == 0 { type = "int64_t" }
                    if let alias = aliases[value] {
                        // A representable literal can occupy its protected signed
                        // alias without a second representation conversion.
                        if case let .move(_, .immediate(literal)) = rows[index], literal >= 0,
                           register.width == 64 || literal <= Int64(Int32.max) {
                            type = alias.type
                        } else if case let .move(_, .register(source, shift)) = rows[index],
                                  shift == 0, source.width == register.width,
                                  case let .assign(original, _) = function.instructions[index].operation,
                                  original == value, alias.register == register {
                            // Keep this source definition and perform its signed
                            // representation conversion here, not in a new copy
                            // at the later call. The earlier alias write receives
                            // its own lifetime proof below.
                            type = alias.type
                        } else if slot == 0, permitsSignedLoadAlias(alias, row: index) {
                            type = alias.type
                            signedLoadAliases.insert(index)
                        } else { value = fresh() }
                    }
                    guard assignedValues.insert(value).inserted else { return false }
                    facts[id] = Fact(value: value, width: register.width, type: type,
                        zeroHigh: register.width == 32)
                    declare(value, type: type, origin: .source(row: index, slot: slot))
                    if aliases[value] != nil {
                        guard !originalResultValues.contains(value), sourceAliases[index] == nil else { return false }
                        sourceAliases[index] = id
                    }
                    definitions.append(id)
                }
                rowDefinitions.append(definitions)
            }
            return !failed
        }

        func canonical(_ id: DefinitionID) -> DefinitionID {
            var result = id, seen: Set<DefinitionID> = []
            while let next = replacement[result] {
                guard seen.insert(result).inserted else { failed = true; return result }
                result = next
            }
            return result
        }
        func exitValue(_ block: Int, register: Int) -> DefinitionID? {
            for row in cfg.blocks[block].instructionRange.reversed() {
                if let slot = rows[row].writes.firstIndex(where: { $0.index == register }) {
                    guard slot < rowDefinitions[row].count else { return nil }
                    return rowDefinitions[row][slot]
                }
                if rows[row].isCall && register <= 18 { return nil }
            }
            return entryValue(block, register: register)
        }
        func entryValue(_ block: Int, register: Int) -> DefinitionID? {
            let key = Key(block: block, register: register)
            if let value = entryCache[key] { return value }
            if unavailableEntries.contains(key) { return nil }
            if block == cfg.entryIndex {
                let id = DefinitionID.entry(register)
                guard facts[id] != nil else { unavailableEntries.insert(key); return nil }
                entryCache[key] = id; return id
            }
            let predecessors = cfg.blocks[block].predecessors
            guard !predecessors.isEmpty else { failed = true; return nil }
            if predecessors.count > 1 && incomingDemand[block][register] != 0 {
                let id = DefinitionID.join(block: block, register: register)
                entryCache[key] = id
                let persisted = function.ssaEnabled ? function.phis.first {
                    $0.blockAddress == function.instructions[cfg.blocks[block].startIndex].source.address
                        && $0.cell == register
                } : nil
                let value = persisted?.destination ?? fresh()
                let width = persisted?.bitWidth ?? (incomingDemand[block][register] == 1 ? 32 : 64)
                let type = persisted == nil ? "uint\(width)_t" : "int\(width)_t"
                facts[id] = Fact(value: value, width: width, type: type, zeroHigh: function.ssaEnabled && width == 32)
                declare(value, type: type, origin: .join(block: block, register: register))
                var inputs: [CFGEdge: DefinitionID] = [:]
                for predecessor in predecessors {
                    guard let input = exitValue(predecessor, register: register) else { failed = true; return nil }
                    inputs[CFGEdge(predecessor, block)] = input
                }
                phiInputs[id] = inputs
                return id
            }
            // A non-live input is not demanded or given speculative storage.
            guard incomingDemand[block][register] != 0 else { unavailableEntries.insert(key); return nil }
            guard predecessors.count == 1, resolvingEntries.insert(key).inserted,
                  let value = exitValue(predecessors[0], register: register) else { failed = true; return nil }
            resolvingEntries.remove(key); entryCache[key] = value
            return value
        }
        func solveValues() -> Bool {
            rowOwners = Array(repeating: -1, count: rows.count)
            for block in cfg.blocks {
                for row in block.instructionRange {
                    guard rowOwners[row] == -1 else { return false }
                    rowOwners[row] = block.index
                }
            }
            let writers = Set(rows.indices.filter { rows[$0].writesFlags || rows[$0].isCall })
            flagAnalysis = RegionalSingleCMPConditionPlan.analyze(rowCount: rows.count, cfg: cfg, writerRows: writers)
            guard let analysis = flagAnalysis else { return false }
            // A shared CSEL can consume the value represented by several CMP
            // origins. Demand that value at the consumer, not a boolean phi.
            // The no-clobber/equivalence proof is repeated by mergedCompare.
            for row in rows.indices {
                guard case .select = rows[row], !analysis.hasUnknownOrigin[row],
                      analysis.reachingWriterRows[row].count > 1,
                      let writer = analysis.reachingWriterRows[row].first,
                      case let .compare(register, .immediate(immediate), addition: false) = rows[writer],
                      !register.isZero,
                      analysis.reachingWriterRows[row].allSatisfy({ origin in
                          if case let .compare(other, .immediate(value), addition: false) = rows[origin] {
                              return other == register && value == immediate
                          }
                          return false
                      }) else { continue }
                additionalReads[row] = register
            }
            computeIncomingDemand()
            for block in cfg.blocks {
                for register in 0..<30 where incomingDemand[block.index][register] != 0 {
                    guard entryValue(block.index, register: register) != nil else { return false }
                }
            }
            var changed = true
            while changed {
                changed = false
                let ordered = phiInputs.keys.sorted { left, right in
                    guard case let .join(lb, lr) = left, case let .join(rb, rr) = right else { return false }
                    return lb == rb ? lr < rr : lb < rb
                }
                for id in ordered where canonical(id) == id {
                    guard let inputs = phiInputs[id] else { return false }
                    let others = Set(inputs.values.map(canonical).filter { $0 != id })
                    if others.count == 1, let only = others.first {
                        replacement[id] = only; changed = true
                    } else if others.isEmpty { return false }
                }
            }
            before = Array(repeating: Array(repeating: nil, count: 30), count: rows.count)
            after = before
            for block in cfg.blocks {
                var current = (0..<30).map { entryCache[Key(block: block.index, register: $0)].map(canonical) }
                for row in block.instructionRange {
                    before[row] = current
                    for (ordinal, register) in rows[row].reads.enumerated() where !register.isZero {
                        guard let id = current[register.index], let fact = facts[id],
                              register.width <= fact.width || fact.zeroHigh else { return false }
                        useBindings.append(UseBinding(row: row, ordinal: ordinal,
                            register: register, definition: id, value: fact.value))
                    }
                    if let register = additionalReads[row], !register.isZero {
                        guard let id = current[register.index], let fact = facts[id],
                              register.width <= fact.width || fact.zeroHigh else { return false }
                        useBindings.append(UseBinding(row: row, ordinal: rows[row].reads.count,
                            register: register, definition: id, value: fact.value))
                    }
                    if let terminal = physical.boundaries.terminal, terminal.exportRow == row {
                        let register = terminal.alias.register
                        guard let id = current[register.index], let fact = facts[id],
                              register.width <= fact.width || fact.zeroHigh else { return false }
                        useBindings.append(UseBinding(row: row, ordinal: rows[row].reads.count,
                            register: register, definition: id, value: fact.value))
                    }
                    if rows[row].isCall { for register in 0...18 { current[register] = nil } }
                    for (slot, register) in rows[row].writes.enumerated() {
                        current[register.index] = slot < rowDefinitions[row].count ? canonical(rowDefinitions[row][slot]) : nil
                    }
                    after[row] = current
                }
            }
            return !failed && rowOwners.allSatisfy { $0 >= 0 } && flagAnalysis != nil
        }

        func computeIncomingDemand() {
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
                        for register in rows[row].writes where !register.isZero { current[register.index] = 0 }
                        if rows[row].isCall { for register in 0...18 { current[register] = 0 } }
                        var reads = rows[row].reads
                        if let extra = additionalReads[row] { reads.append(extra) }
                        if let terminal = physical.boundaries.terminal, terminal.exportRow == row {
                            reads.append(terminal.alias.register)
                        }
                        for register in reads where !register.isZero {
                            current[register.index] |= register.width == 32 ? 1 : 3
                        }
                    }
                    if current != incomingDemand[block.index] { incomingDemand[block.index] = current; changed = true }
                }
            }
            afterDemand = Array(repeating: empty, count: rows.count)
            for block in cfg.blocks {
                var current = empty
                for successor in block.successors {
                    for register in 0..<30 { current[register] |= incomingDemand[successor][register] }
                }
                for row in block.instructionRange.reversed() {
                    afterDemand[row] = current
                    for register in rows[row].writes where !register.isZero { current[register.index] = 0 }
                    if rows[row].isCall { for register in 0...18 { current[register] = 0 } }
                    var reads = rows[row].reads
                    if let extra = additionalReads[row] { reads.append(extra) }
                    if let terminal = physical.boundaries.terminal, terminal.exportRow == row { reads.append(terminal.alias.register) }
                    for register in reads where !register.isZero { current[register.index] |= register.width == 32 ? 1 : 3 }
                }
            }
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
            if fact.type == "uint\(width)_t" { return fact.value }
            return project(fact.value, width)
        }
        func read(_ register: Register, row: Int) -> MacIRValue? {
            if register.isZero { return project(.immediate(0), register.width) }
            guard before.indices.contains(row), let id = before[row][register.index] else { return nil }
            return unsigned(id, width: register.width)
        }
        func operand(_ value: Operand, row: Int, width: Int) -> MacIRValue? {
            switch value {
            case let .immediate(value): return project(.immediate(value), width)
            case let .register(register, shift):
                guard let value = read(register, row: row) else { return nil }
                return shift == 0 ? value : project(expression("<<", value, .immediate(Int64(shift))), width)
            }
        }
        func address(_ address: Address, row: Int) -> MacIRValue? {
            guard var value = read(address.base, row: row) else { return nil }
            if let index = address.index {
                guard var offset = read(index, row: row) else { return nil }
                // A W index is extended before the byte offset shift.
                if index.width == 32 { offset = project(offset, 64) }
                if address.shift != 0 { offset = expression("<<", offset, .immediate(Int64(address.shift))) }
                value = expression("+", value, offset)
            }
            if address.displacement != 0 { value = expression("+", value, .immediate(address.displacement)) }
            return value
        }
        func destination(_ row: Int, _ slot: Int = 0) -> MacIRValue? {
            guard slot < rowDefinitions[row].count else { return nil }
            return facts[canonical(rowDefinitions[row][slot])]?.value
        }
        func append(_ operation: MacIROperation, row: Int, memory: MacIRMemoryAccess? = nil) {
            groups[row].append(.instruction(MacIRInstruction(source: function.instructions[row].source,
                operation: operation, memoryAccess: memory)))
        }
        func signedOperation(destination: MacIRValue, bits: MacIRValue, width: Int) -> MacIROperation {
            let sign = signBit(width)
            let normalized = project(bits, width)
            let nonnegative = expression("&", normalized, sign)
            let positive = MacIRValue.unary(op: "(int\(width)_t)", value: normalized)
            let complement = project(.unary(op: "~", value: normalized), width)
            let negative = expression("-", .immediate(-1), .unary(op: "(int\(width)_t)", value: complement))
            return .select(destination: destination, condition: "==", left: nonnegative, right: .immediate(0),
                trueValue: positive, falseValue: negative)
        }
        func signBit(_ width: Int) -> MacIRValue {
            width == 32 ? project(.immediate(0x8000_0000), 32)
                : expression("<<", project(.immediate(1), 64), .immediate(63))
        }
        func assign(_ row: Int, value: MacIRValue, slot: Int = 0) -> Bool {
            guard let output = destination(row, slot),
                  slot < rows[row].writes.count,
                  let fact = facts[canonical(rowDefinitions[row][slot])] else { return false }
            if fact.type.hasPrefix("int") {
                if case let .move(_, .immediate(literal)) = rows[row] {
                    append(.assign(destination: output, source: .immediate(literal)), row: row)
                } else { append(signedOperation(destination: output, bits: value, width: fact.width), row: row) }
            } else {
                append(.assign(destination: output, source: project(value, fact.width)), row: row)
            }
            return true
        }
        func prepareRows() -> Bool {
            for row in rows.indices {
                if let call = physical.boundaries.calls[row] {
                    guard prepareCall(call) else { return false }
                    continue
                }
                if physical.boundaries.exteriorRows.contains(row) {
                    if let terminal = physical.boundaries.terminal, terminal.exportRow == row {
                        guard let bits = read(terminal.alias.register, row: row),
                              let id = before[row][terminal.alias.register.index], let fact = facts[id] else { return false }
                        if terminal.alias.projectedStorage != nil {
                            guard observesProjection(terminal.alias, fact: fact) else { return false }
                        } else if fact.value != terminal.alias.value || fact.type != terminal.alias.type {
                            append(signedOperation(destination: terminal.alias.value, bits: bits,
                                width: terminal.alias.register.width), row: row)
                        }
                    }
                    groups[row].append(.protectedOriginal(row: row))
                    continue
                }
                switch rows[row] {
                case .original, .call: return false
                case let .move(register, value):
                    guard let value = operand(value, row: row, width: register.width), assign(row, value: value) else { return false }
                case let .binary(register, op, left, right, _):
                    guard let a = operand(left, row: row, width: register.width),
                          let b = operand(right, row: row, width: register.width),
                          assign(row, value: expression(op, a, b)) else { return false }
                case let .variableLeftShift(_, left, right):
                    guard let a = read(left, row: row), let b = read(right, row: row),
                          assign(row, value: expression("<<", a, expression("&", b, .immediate(63)))) else { return false }
                case let .multiplySubtract(_, first, second, addend):
                    guard let a = read(first, row: row), let b = read(second, row: row), let c = read(addend, row: row),
                          assign(row, value: expression("-", c, expression("*", a, b))) else { return false }
                case let .divide(register, left, right, signed):
                    let name = "a64_\(signed ? "sdiv" : "udiv")\(register.width)"
                    guard case let .intrinsic(originalDestination?, originalName, originalArguments) = function.instructions[row].operation,
                          originalName == name, originalArguments.count == 2,
                          compatible(originalDestination, register: register),
                          let output = destination(row), let a = read(left, row: row), let b = read(right, row: row) else { return false }
                    append(.intrinsic(destination: output, name: name, arguments: [a, b]), row: row)
                case let .extend(_, source):
                    guard let output = destination(row), let low = read(source, row: row) else { return false }
                    let wide = project(low, 64)
                    let highMask = MacIRValue.unary(op: "~", value: project(.immediate(0xffff_ffff), 64))
                    append(.select(destination: output, condition: "==",
                        left: expression("&", low, signBit(32)), right: .immediate(0),
                        trueValue: wide, falseValue: expression("|", wide, highMask)), row: row)
                case let .load(register, location, bytes, signed, delta):
                    guard let output = destination(row), let locationValue = address(location, row: row) else { return false }
                    let access = MacIRMemoryAccess(byteWidth: bytes,
                        extensionKind: signed || signedLoadAliases.contains(row)
                            ? .sign : (bytes * 8 < register.width ? .zero : .none))
                    append(.load(destination: output, address: locationValue), row: row, memory: access)
                    if let delta {
                        guard let base = read(location.base, row: row),
                              assign(row, value: expression("+", base, .immediate(delta)), slot: 1) else { return false }
                    }
                case let .store(register, location, bytes, delta):
                    guard let data = read(register, row: row), let locationValue = address(location, row: row) else { return false }
                    append(.store(source: project(data, bytes * 8), address: locationValue), row: row,
                        memory: MacIRMemoryAccess(byteWidth: bytes))
                    if let delta {
                        guard let base = read(location.base, row: row),
                              assign(row, value: expression("+", base, .immediate(delta))) else { return false }
                    }
                case let .pair(first, second, location, load):
                    guard let firstAddress = address(location, row: row) else { return false }
                    let width = first.width / 8
                    let secondAddress = expression("+", firstAddress, .immediate(Int64(width)))
                    let access = MacIRMemoryAccess(byteWidth: width)
                    if load {
                        guard let a = destination(row), let b = destination(row, 1) else { return false }
                        append(.load(destination: a, address: firstAddress), row: row, memory: access)
                        append(.load(destination: b, address: secondAddress), row: row, memory: access)
                    } else {
                        guard let a = read(first, row: row), let b = read(second, row: row) else { return false }
                        append(.store(source: a, address: firstAddress), row: row, memory: access)
                        append(.store(source: b, address: secondAddress), row: row, memory: access)
                    }
                case let .select(_, yes, no, condition):
                    guard let output = destination(row), let a = read(yes, row: row), let b = read(no, row: row),
                          let predicate = predicate(before: row, condition: condition, visiting: []) else { return false }
                    append(.select(destination: output, condition: "!=", left: predicate, right: .immediate(0),
                        trueValue: a, falseValue: b), row: row)
                case let .set(_, condition):
                    guard let output = destination(row),
                          let predicate = predicate(before: row, condition: condition, visiting: []) else { return false }
                    append(.compareToBool(destination: output, condition: "!=", left: predicate, right: .immediate(0)), row: row)
                case let .conditional(condition, _):
                    guard let predicate = predicate(before: row, condition: condition, visiting: []) else { return false }
                    branchConditions[row] = branch(row, predicate: predicate)
                case let .zero(register, nonzero, _):
                    guard let value = read(register, row: row) else { return false }
                    branchConditions[row] = BranchCondition(branchIndex: row, compareIndex: nil,
                        left: value, condition: nonzero ? "!=" : "==", right: .immediate(0), isZeroCheck: false)
                case let .dispatch(_, selector):
                    guard physical.switches[row] != nil,
                          case let .switchDispatch(_, cases, defaultTarget) = function.instructions[row].operation,
                          let current = read(selector, row: row) else { return false }
                    switches[row] = .switchDispatch(index: current, cases: cases, defaultTarget: defaultTarget)
                case .compare, .conditionalCompare, .test, .jump:
                    break // Zero printed statements, one original source owner.
                }
            }
            return !failed
        }
        func branch(_ row: Int, predicate: MacIRValue) -> BranchCondition {
            if case let .binaryExpression(op, left, right) = predicate,
               ["==", "!=", "<", "<=", ">", ">="].contains(op) {
                return BranchCondition(branchIndex: row, compareIndex: nil,
                    left: left, condition: op, right: right, isZeroCheck: false)
            }
            return BranchCondition(branchIndex: row, compareIndex: nil,
                left: predicate, condition: "!=", right: .immediate(0), isZeroCheck: false)
        }

        func sourceAliasWrites(at row: Int) -> Set<MacIRValue> {
            guard let id = sourceAliases[row], let fact = facts[id] else { return [] }
            return [fact.value]
        }
        /// Reusing an original alias at a source row moves its representation
        /// write earlier than event materialization. Prove that actual write,
        /// not just the later call: no other outgoing current fact may retain
        /// the overwritten storage, even if that fact is presently dead.
        func proveSourceAliasLifetimes() -> Bool {
            for row in sourceAliases.keys.sorted() {
                guard let id = sourceAliases[row], let fact = facts[id],
                      case let .source(owner, slot) = id, owner == row,
                      rows[row].writes.count == 1, slot == 0,
                      after[row][rows[row].writes[0].index] == id else { return false }
                let overwritten = Set(before[row].compactMap { old -> DefinitionID? in
                    guard let old, facts[old]?.value == fact.value else { return nil }
                    return old
                })
                var survivors: Set<DefinitionID> = []
                for current in after[row].compactMap({ $0 }) where current != id {
                    guard let other = facts[current], other.value != fact.value else { return false }
                    survivors.insert(current)
                }
                guard overwritten.isDisjoint(with: survivors) else { return false }
                sourceAliasLifetimes.append(SourceAliasLifetime(row: row, writtenAlias: fact.value,
                    definition: id, invalidatedCurrentDefinitions: overwritten,
                    survivingDefinitions: survivors, fullWidthSignedLoad: signedLoadAliases.contains(row)))
            }
            return !failed
        }
        func boundaryWrites(at row: Int) -> Set<MacIRValue> {
            var result: Set<MacIRValue> = []
            if let call = physical.boundaries.calls[row] {
                for alias in call.inputs {
                    guard let id = before[row][alias.register.index], let fact = facts[id] else {
                        failed = true; continue
                    }
                    if alias.projectedStorage != nil {
                        if !observesProjection(alias, fact: fact) { failed = true }
                    } else if fact.value != alias.value || fact.type != alias.type || fact.width != alias.register.width {
                        result.insert(alias.value)
                    }
                }
                if let output = call.result { result.insert(output.value) }
            }
            if let terminal = physical.boundaries.terminal, terminal.exportRow == row,
               let id = before[row][terminal.alias.register.index], let fact = facts[id] {
                if terminal.alias.projectedStorage != nil {
                    if !observesProjection(terminal.alias, fact: fact) { failed = true }
                } else if fact.value != terminal.alias.value || fact.type != terminal.alias.type {
                    result.insert(terminal.alias.value)
                }
            }
            return result
        }
        /// A protected textual alias is mutable at an event. Its original SSA
        /// spelling is not a lifetime proof. Check each concrete event write
        /// against retained live values before allowing that alias as a fact.
        func proveBoundaryAliasLifetimes() -> Bool {
            for row in physical.boundaries.calls.keys.sorted() {
                let writes = boundaryWrites(at: row)
                let overwritten = Set(before[row].compactMap { id -> DefinitionID? in
                    guard let id, let fact = facts[id], writes.contains(fact.value) else { return nil }
                    return id
                })
                var survivors: Set<DefinitionID> = []
                for register in 0..<30 {
                    guard let id = after[row][register], let fact = facts[id] else {
                        if afterDemand[row][register] != 0 { return false }
                        continue
                    }
                    if id == .callResult(row) { continue } // This event owns the new value.
                    // Reject even a presently dead retained fact rather than
                    // leaving an overwritten alias in the outgoing map.
                    guard !writes.contains(fact.value) else { return false }
                    if afterDemand[row][register] != 0 { survivors.insert(id) }
                }
                guard overwritten.isDisjoint(with: survivors) else { return false }
                let result = physical.liveCallResultRows.contains(row) ? DefinitionID.callResult(row) : nil
                boundaryAliasLifetimes.append(BoundaryAliasLifetime(row: row, writtenAliases: writes,
                    invalidatedCurrentDefinitions: overwritten, survivingLiveDefinitions: survivors,
                    resultDefinition: result))
            }
            return !failed
        }
        func prepareCall(_ call: RegionalBoundaryPlan.Call) -> Bool {
            var copies: [Copy] = []
            for alias in call.inputs {
                guard let id = before[call.row][alias.register.index], let fact = facts[id],
                      let bits = read(alias.register, row: call.row) else { return false }
                if call.nativeZeroExtendedInputs.contains(alias.value) {
                    guard !function.ssaEnabled, fact.width == 32, fact.zeroHigh,
                          case let .source(owner, slot) = id,
                          rows.indices.contains(owner), rows[owner].writes.indices.contains(slot),
                          rows[owner].writes[slot] == alias.register,
                          case let .load(destination, _) = function.instructions[owner].operation,
                          destination == alias.value else { return false }
                }
                if alias.projectedStorage != nil {
                    guard observesProjection(alias, fact: fact) else { return false }
                    continue
                }
                if fact.value == alias.value && fact.type == alias.type && fact.width == alias.register.width { continue }
                copies.append(Copy(destination: alias.value, source: bits, type: alias.type))
            }
            guard let instructions = parallel(copies, row: call.row, edge: nil) else { return false }
            groups[call.row] += instructions.map(Item.instruction)
            groups[call.row].append(.protectedOriginal(row: call.row))
            // The unchanged statement defines an existing result. No statement
            // imports a dead result, and a nil result never obtains a fact.
            return call.result != nil || rowDefinitions[call.row].isEmpty
        }

        func observesProjection(_ alias: RegionalBoundaryPlan.Alias, fact: Fact) -> Bool {
            guard function.ssaEnabled, let storage = alias.projectedStorage,
                  fact.value == storage,
                  let phi = function.phis.first(where: { $0.destination == storage }),
                  phi.cell == alias.register.index, phi.bitWidth == fact.width,
                  phi.scalarView == .integer else { return false }
            return alias.register.width == 32 || (fact.width == 32 && fact.zeroHigh)
        }

        func prepareEdges() -> Bool {
            // A declaration alone is not a producer. Persisted edge operands
            // must name storage still defined by this emission overlay.
            let capturedStorage = Set(facts.compactMap { id, fact in
                canonical(id) == id ? fact.value : nil
            })
            var pending: [CFGEdge: [Copy]] = [:]
            let ordered = phiInputs.keys.sorted { left, right in
                guard case let .join(lb, lr) = left, case let .join(rb, rr) = right else { return false }
                return lb == rb ? lr < rr : lb < rb
            }
            for id in ordered where canonical(id) == id {
                guard let inputs = phiInputs[id], case let .join(block, register) = id, let target = facts[id],
                      Set(inputs.keys) == Set(cfg.blocks[block].predecessors.map { CFGEdge($0, block) }) else { return false }
                for edge in inputs.keys.sorted(by: { $0.from < $1.from }) {
                    guard let rawInput = inputs[edge] else { return false }
                    let input = canonical(rawInput)
                    guard cfg.blocks[edge.from].successors.filter({ $0 == edge.to }).count == 1,
                          cfg.blocks[edge.to].predecessors.filter({ $0 == edge.from }).count == 1,
                          let last = cfg.blocks[edge.from].instructionRange.last,
                          after[last][register] == input else { return false }
                    let bits: MacIRValue
                    if function.ssaEnabled {
                        guard let phi = function.phis.first(where: { $0.destination == target.value }),
                              let incoming = phi.incoming.first(where: {
                                  $0.machineAddress == function.instructions[last].source.address
                              }), atoms(incoming.value).isSubset(of: capturedStorage) else { return false }
                        bits = incoming.value
                    } else {
                        guard let projected = unsigned(input, width: target.width) else { return false }
                        bits = projected
                    }
                    edgeBindings.append(EdgeBinding(edge: edge, register: register, source: input, destination: id))
                    if input != id { pending[edge, default: []].append(Copy(destination: target.value, source: bits, type: target.type)) }
                }
            }
            for edge in pending.keys.sorted(by: { $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from }) {
                guard let row = cfg.blocks[edge.from].instructionRange.last,
                      let copies = pending[edge], let instructions = parallel(copies, row: row, edge: edge) else { return false }
                edgeCopies[edge] = instructions
            }
            return true
        }
        func atoms(_ value: MacIRValue) -> Set<MacIRValue> {
            var result: Set<MacIRValue> = []
            RegionalBoundaryPlan.collectAtoms(value, into: &result)
            return result
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
            case let .bitTest(value, bit): return .bitTest(value: replacing(value, old: old, new: new), bit: bit)
            default: return value
            }
        }
        /// Lower one parallel assignment at its exact event/edge. Replacement
        /// here is confined to this copy list, never to original SSA uses.
        func parallel(_ copies: [Copy], row: Int, edge: CFGEdge?) -> [MacIRInstruction]? {
            guard Set(copies.map(\.destination)).count == copies.count else { return nil }
            var pending = copies.filter { $0.destination != $0.source }
            var result: [MacIRInstruction] = []
            func emit(_ operation: MacIROperation) {
                var source = function.instructions[row].source
                if function.ssaEnabled, let edge {
                    let destination = originalDestinations(operation).first
                    let phi = function.phis.first { $0.destination == destination }
                        ?? function.phis.first {
                            $0.blockAddress == function.instructions[cfg.blocks[edge.to].startIndex].source.address
                        }
                    if let phi {
                        source = MacIRSourceSpan(address: phi.blockAddress, byteText: "", mnemonic: "phi", operands: "")
                        source.syntheticPhiEdge = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                            predecessorAddress: function.instructions[row].source.address, destination: phi.destination)
                    }
                }
                result.append(MacIRInstruction(source: source, operation: operation))
            }
            while !pending.isEmpty {
                if let next = pending.indices.first(where: { index in
                    !pending.indices.contains { other in other != index && atoms(pending[other].source).contains(pending[index].destination) }
                }) {
                    let copy = pending.remove(at: next)
                    if !(function.ssaEnabled && edge != nil) && (copy.type == "int32_t" || copy.type == "int64_t") {
                        emit(signedOperation(destination: copy.destination, bits: copy.source,
                            width: copy.type == "int32_t" ? 32 : 64))
                    } else { emit(.assign(destination: copy.destination, source: copy.source)) }
                } else {
                    guard let first = pending.first else { return nil }
                    let width = first.type.contains("32") ? 32 : 64
                    let temporary = fresh()
                    declare(temporary, type: "uint\(width)_t", origin: edge.map(DeclarationOrigin.parallelCycle) ?? .boundaryCycle(row: row))
                    emit(.assign(destination: temporary, source: project(first.destination, width)))
                    pending = pending.map { copy in
                        Copy(destination: copy.destination,
                            source: replacing(copy.source, old: first.destination, new: temporary), type: copy.type)
                    }
                }
            }
            return result
        }

        func successors(_ row: Int) -> [Int] {
            let block = cfg.blocks[rowOwners[row]]
            return row + 1 < block.endIndex ? [row + 1] : block.successors.map { cfg.blocks[$0].startIndex }
        }
        func canReach(_ consumer: Int) -> Set<Int> {
            var predecessors = Array(repeating: [Int](), count: rows.count)
            for row in rows.indices { for next in successors(row) { predecessors[next].append(row) } }
            var result: Set<Int> = [consumer], pending = [consumer]
            while let row = pending.popLast() {
                for previous in predecessors[row] where result.insert(previous).inserted { pending.append(previous) }
            }
            return result
        }
        /// A source definition is immutable within a source visit. A loop may
        /// execute it again, and a de-SSA incoming carrier may be overwritten on
        /// an edge. Neither is silently treated as an immutable flag snapshot.
        func stable(_ definitions: Set<DefinitionID>, from writer: Int, to consumer: Int) -> Bool {
            let reachable = canReach(consumer)
            var pending = successors(writer).filter { reachable.contains($0) }, visited: Set<Int> = []
            while let row = pending.popLast() {
                guard visited.insert(row).inserted else { continue }
                let block = rowOwners[row]
                let aliasWrites = row == consumer ? Set<MacIRValue>()
                    : boundaryWrites(at: row).union(sourceAliasWrites(at: row))
                for definition in definitions {
                    if let fact = facts[canonical(definition)], aliasWrites.contains(fact.value) { return false }
                    switch canonical(definition) {
                    case let .join(owner, _) where owner == block && cfg.blocks[block].startIndex == row:
                        return false
                    case let .source(owner, _) where owner == row && row != consumer:
                        return false
                    case let .callResult(owner) where owner == row && row != consumer:
                        return false
                    default: break
                    }
                }
                if row != consumer { pending += successors(row).filter { reachable.contains($0) } }
            }
            return true
        }
        func readDefinitions(_ writer: Int) -> Set<DefinitionID> {
            Set(rows[writer].reads.compactMap { $0.isZero ? nil : before[writer][$0.index] })
        }
        func comparePredicate(_ condition: String, left: MacIRValue, right: MacIRValue, width: Int) -> MacIRValue? {
            let op: String
            switch condition {
            case "eq": op = "=="
            case "ne": op = "!="
            case "hs", "cs": op = ">="
            case "lo", "cc": op = "<"
            case "hi": op = ">"
            case "ls": op = "<="
            case "ge", "lt", "gt", "le":
                let signedOps = ["ge": ">=", "lt": "<", "gt": ">", "le": "<="]
                guard let signedOp = signedOps[condition] else { return nil }
                let bit = signBit(width)
                return expression(signedOp, expression("^", left, bit), expression("^", right, bit))
            default: return nil
            }
            return expression(op, left, right)
        }
        func predicate(before consumer: Int, condition: String, visiting: Set<Int>, ultimate: Int? = nil) -> MacIRValue? {
            let target = ultimate ?? consumer
            guard let analysis = flagAnalysis, !analysis.hasUnknownOrigin[consumer],
                  !visiting.contains(consumer) else { return nil }
            let origins = analysis.reachingWriterRows[consumer]
            if origins.count > 1 {
                // This is a value-merge proof for an original CSEL, not an
                // opaque-condition bridge or a generic synthetic flag phi.
                guard ultimate == nil, case .select = rows[consumer] else { return nil }
                return mergedCompare(origins, consumer: consumer, condition: condition)
            }
            guard let writer = origins.first, writer != consumer, !rows[writer].isCall,
                  let unique = analysis.uniqueWriterWithoutInterveningWriter(before: consumer), unique == writer else { return nil }
            if let certifiedWriter = physical.singleCMPBranches[consumer], certifiedWriter != writer { return nil }
            var visiting = visiting; visiting.insert(consumer)
            conditionWriters[target, default: []].insert(writer)
            conditionDefinitions[target, default: []].formUnion(readDefinitions(writer))
            switch rows[writer] {
            case let .compare(register, operandValue, addition):
                guard stable(readDefinitions(writer), from: writer, to: target),
                      let left = read(register, row: writer),
                      let right = operand(operandValue, row: writer, width: register.width) else { return nil }
                if addition {
                    guard case let .immediate(amount) = operandValue, amount > 0,
                          condition == "hs" || condition == "cs" || condition == "lo" || condition == "cc" else { return nil }
                    let threshold = project(.immediate(-amount), register.width)
                    return expression(condition == "hs" || condition == "cs" ? ">=" : "<", left, threshold)
                }
                return comparePredicate(condition, left: left, right: right, width: register.width)
            case let .binary(register, _, _, _, true):
                guard condition == "eq" || condition == "ne", let id = rowDefinitions[writer].first,
                      stable([id], from: writer, to: target), let result = unsigned(id, width: register.width) else { return nil }
                conditionDefinitions[target, default: []].insert(canonical(id))
                return expression(condition == "eq" ? "==" : "!=", result, .immediate(0))
            case let .test(register, operandValue):
                guard condition == "eq" || condition == "ne", stable(readDefinitions(writer), from: writer, to: target),
                      let left = read(register, row: writer), let right = operand(operandValue, row: writer, width: register.width) else { return nil }
                return expression(condition == "eq" ? "==" : "!=", expression("&", left, right), .immediate(0))
            case let .conditionalCompare(register, operandValue, nzcv, gate, addition):
                guard nzcv == 0, gate == "eq", condition == "eq" || condition == "ne",
                      stable(readDefinitions(writer), from: writer, to: target),
                      let prior = predicate(before: writer, condition: "eq", visiting: visiting, ultimate: target),
                      let left = read(register, row: writer), let right = operand(operandValue, row: writer, width: register.width) else { return nil }
                let comparison = addition
                    ? expression("==", project(expression("+", left, right), register.width), .immediate(0))
                    : expression("==", left, right)
                let equal = expression("&&", prior, comparison)
                return condition == "eq" ? equal : .unary(op: "!", value: equal)
            default: return nil
            }
        }
        func mergedCompare(_ origins: Set<Int>, consumer: Int, condition: String) -> MacIRValue? {
            guard let first = origins.first,
                  case let .compare(register, .immediate(immediate), addition: false) = rows[first],
                  !register.isZero else { return nil }
            let reachable = canReach(consumer)
            for writer in origins {
                guard case let .compare(other, .immediate(otherImmediate), addition: false) = rows[writer],
                      register == other, immediate == otherImmediate else { return nil }
                var pending = successors(writer).filter { reachable.contains($0) }, visited: Set<Int> = []
                while let row = pending.popLast() {
                    guard visited.insert(row).inserted else { continue }
                    if row == consumer { continue }
                    guard !rows[row].isCall, !rows[row].writesFlags,
                          !rows[row].writes.contains(where: { $0.index == register.index }) else { return nil }
                    pending += successors(row).filter { reachable.contains($0) }
                }
            }
            guard let left = read(register, row: consumer), let id = before[consumer][register.index] else { return nil }
            conditionWriters[consumer, default: []].formUnion(origins)
            conditionDefinitions[consumer, default: []].insert(id)
            return comparePredicate(condition, left: left, right: project(.immediate(immediate), register.width), width: register.width)
        }
    }
}
