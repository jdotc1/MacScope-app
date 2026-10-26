import Foundation

/// Imported-header authority only. This pass deliberately does not treat legacy
/// linear IR versions as SSA/reaching-definition evidence. Its type facts follow
/// physical registers along every supported forward CFG edge instead.
public enum SlotTypedPrototypeBinding {
    public struct Refusal: Codable, Sendable {
        public var functionStart: UInt64
        public var address: UInt64?
        public var target: UInt64?
        public var reason: String
    }
    public struct CallProof: Codable, Sendable {
        public var functionStart: UInt64
        public var callAddress: UInt64
        public var loadAddress: UInt64
        public var rootFunctionStart: UInt64
        public var rootParameterIndex: Int
        public var rootType: String
        public var rootRegister: String
        public var rootCopyAddresses: [UInt64]
        public var pointerChase: [String]
        public var physicalProof: String
        public var canonicalContract: String
        public var abiProof: String
        public var callInstruction: String
    }
    public struct Report: Sendable {
        public var callContracts: [UInt64: FunctionPointerSignatureV1] = [:]
        public var callSignatures: [UInt64: MacIRCallSignature] = [:]
        public var callProofRows: [CallProof] = []
        public var refusals: [Refusal] = []
        public var census: [String: Int] = [:]
        public init() {}
    }
    private struct Root: Equatable {
        var function: UInt64
        var parameter: Int
        var type: String
        var register: String
        var copies: [UInt64] = []
    }
    private struct Pointer: Equatable {
        var root: Root
        var owner: String
        var chase: [String] = []
        var definition: UInt64? = nil
        var isRoot: Bool { chase.isEmpty }
    }
    private struct Callable: Equatable {
        var pointer: Pointer
        var slot: String
        var fieldName: String
        var load: UInt64
        var signature: FunctionPointerSignatureV1
    }
    private enum Fact: Equatable {
        case pointer(Pointer)
        case callable(Callable)
        case literal(UInt64, UInt64)
        case page(UInt64, UInt64)
        var persistent: Bool {
            if case let .pointer(pointer) = self { return pointer.isRoot }
            return false
        }
    }
    private struct Store {
        var function: UInt64
        var address: UInt64
        var target: UInt64
        var slot: String
        var signature: FunctionPointerSignatureV1
    }

    /// No slot-callee escape certificate is available in this producer.
    /// Caller-return closure must not be repurposed to exempt literal slot stores.
    static func analyze(
        builtFunctions: [MacIRFunction], originalInstructions: [InstructionRow],
        functionStarts: Set<UInt64>,
        importedPrototypes: [UInt64: FunctionSignatureOverride],
        effectiveSignatures: [UInt64: FunctionSignatureOverride],
        types: [TypeDefinition],
        headerLayoutDefinitions: [TypeDefinition] = [],
        includeSlotTails: Bool = MacIRConfiguration.returnContractEnabled
    ) -> Report {
        var report = Report()
        let currentCatalog = Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let duplicateTypes = Set(Dictionary(grouping: types, by: \.name).filter { $0.value.count != 1 }.keys)
        if !duplicateTypes.isEmpty {
            report.refusals.append(.init(functionStart: 0, address: nil, target: nil, reason: "ambiguous_type_catalog"))
            report.census["ambiguous_type_catalog"] = duplicateTypes.count
            return report
        }
        let authority = headerCatalog(current: currentCatalog, evidence: headerLayoutDefinitions)
        let catalog = authority.catalog
        report.census["header_exact_dependency_closed_types"] = catalog.count
        for (name, reason) in authority.refusals.sorted(by: { $0.key < $1.key }) {
            report.refusals.append(.init(functionStart: 0, address: nil, target: nil, reason: reason + ":" + name))
            report.census[reason, default: 0] += 1
        }
        if headerLayoutDefinitions.isEmpty {
            report.census["missing_header_layout_evidence"] = 1
            report.census["raw_indirect_sites"] = originalInstructions.filter { isIndirect($0.mnemonic.lowercased()) }.count
            report.refusals.append(.init(functionStart: 0, address: nil, target: nil, reason: "missing_header_layout_evidence"))
            return report
        }
        let originals = Dictionary(grouping: originalInstructions, by: \.address)
        // Match filter + stable address sort, including original order at ties.
        let sortedInstructions = originalInstructions.enumerated().sorted {
            if $0.element.address != $1.element.address { return $0.element.address < $1.element.address }
            return $0.offset < $1.offset
        }.map(\.element)
        func instructionLowerBound(_ address: UInt64) -> Int {
            var lower = 0
            var upper = sortedInstructions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sortedInstructions[middle].address < address { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }
        let starts = functionStarts.sorted()
        var stores: [Store] = []
        var poisoned: Set<String> = []
        var callSlots: [UInt64: String] = [:]
        var functionSites: [UInt64: [UInt64]] = [:]
        func refuse(_ function: UInt64, _ address: UInt64?, _ reason: String, target: UInt64? = nil) {
            report.refusals.append(.init(functionStart: function, address: address, target: target, reason: reason))
            report.census[reason, default: 0] += 1
        }
        for function in builtFunctions.sorted(by: { $0.startAddress < $1.startAddress }) {
            let start = function.startAddress
            let end = function.endAddress ?? starts.first(where: { $0 > start }) ?? ((function.instructions.map { $0.source.address }.max() ?? start) + 4)
            let lower = instructionLowerBound(start)
            let upper = end > start ? instructionLowerBound(end) : lower
            let rows = Array(sortedInstructions[lower..<upper])
            let sites = rows.filter { isIndirect($0.mnemonic.lowercased()) }.map(\.address)
            functionSites[start] = sites
            report.census["raw_indirect_sites", default: 0] += sites.count
            guard originals[start]?.count == 1, !rows.isEmpty,
                  rows.allSatisfy({ originals[$0.address]?.count == 1 && $0.byteWidth == 4 }) else {
                refuse(start, nil, "incomplete_function_instruction_inventory"); continue
            }
            let byAddress = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
            var successors: [UInt64: [UInt64]] = [:]
            var reachable: Set<UInt64> = []
            var pending = [start]
            var cfgValid = true
            while let address = pending.popLast() {
                guard reachable.insert(address).inserted else { continue }
                guard let row = byAddress[address], let edges = edges(row, end: end) else { cfgValid = false; continue }
                successors[address] = edges
                for next in edges {
                    if next <= address || byAddress[next] == nil { cfgValid = false }
                    else { pending.append(next) }
                }
            }
            // This includes entry reexecution, loops, and acyclic backwards
            // layouts. No complete image-wide escape claim is made by this pass.
            guard let imported = importedPrototypes[start],
                  case let .authoritative(parameters) = imported.parameterList else {
                if !sites.isEmpty { refuse(start, nil, "no_imported_H1_parameter_root") }
                continue
            }
            guard let effective = effectiveSignatures[start],
                  case let .authoritative(effectiveParameters) = effective.parameterList,
                  effectiveParameters.count == parameters.count,
                  zip(parameters, effectiveParameters).allSatisfy({ pair in
                      guard let importedType = canonicalType(pair.0.type, catalog: catalog),
                            let effectiveType = canonicalType(pair.1.type, catalog: catalog) else { return false }
                      return importedType == effectiveType
                  }),
                  effective.variadicState == imported.variadicState else {
                refuse(start, nil, "effective_parameter_authority_disagrees_with_H1"); continue
            }
            let bindings = DarwinARM64ParameterBinder.bindRich(parameterTypes: parameters.map(\.type),
                resolver: TypeAtlasDarwinARM64LayoutResolver(catalog: catalog))
            var initial: [Int: Fact] = [:]
            for (index, parameter) in parameters.enumerated() {
                guard index < bindings.count, case let .gpr(register, width) = bindings[index], width == 64,
                      let owner = structName(parameter.type, catalog: catalog), !duplicateTypes.contains(owner) else { continue }
                initial[register] = .pointer(.init(root: .init(function: start, parameter: index, type: parameter.type,
                    register: "x\(register)"), owner: owner))
            }
            // Keep the established forward mode intact. Non-forward functions
            // get a separate, bounded immutable-carrier proof, never optimistic
            // propagation around a loop using legacy linear IR versions.
            var invariantPlan: InvariantPlan?
            if !cfgValid {
                invariantPlan = invariantCarrierPlan(rows: rows, start: start, end: end, functionStarts: functionStarts, roots: initial)
                guard let plan = invariantPlan else {
                    refuse(start, nil, "unsupported_nonforward_or_incomplete_cfg")
                    continue
                }
                successors = plan.successors
                reachable = plan.reachable
                report.census["invariant_carrier_functions", default: 0] += 1
            }
            var incoming: [UInt64: [[Int: Fact]]] = [start: [initial]]
            // The fallback lifter also visits unreachable/alternate blocks in
            // address order. Require its linear carrier history to agree with
            // the all-path physical proof, not merely a plausible version ID.
            func linearClean(_ register: Int, after definition: UInt64?, before address: UInt64) -> Bool {
                for prior in rows where prior.address < address && (definition == nil || prior.address > definition!) {
                    let operands = MacIRBuilder.splitOperands(prior.operands).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                    guard let changed = writes(prior.mnemonic.lowercased(), operands), !changed.contains(register) else { return false }
                }
                return true
            }
            let tailFrames = includeSlotTails ? provenTailFrames(rows: rows, start: start, successors: successors, reachable: reachable) : []
            let irGroups = Dictionary(grouping: function.instructions, by: { $0.source.address })
            var predecessors: [UInt64: Int] = [:]
            for address in reachable { for next in successors[address] ?? [] { predecessors[next, default: 0] += 1 } }
            for row in rows where reachable.contains(row.address) {
                if let plan = invariantPlan, plan.leaders.contains(row.address) {
                    // Absolutely no loaded/chased/callable/literal edge state.
                    incoming[row.address] = [row.address == start ? initial : (plan.seeds[row.address] ?? [:])]
                }
                guard let candidates = incoming[row.address], !candidates.isEmpty else { continue }
                var state = candidates[0].filter { key, value in candidates.dropFirst().allSatisfy { $0[key] == value } }
                let mnemonic = row.mnemonic.lowercased()
                let operands = MacIRBuilder.splitOperands(row.operands).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                let old = state
                guard let writes = writes(mnemonic, operands) else {
                    state.removeAll()
                    refuse(start, row.address, "unknown_physical_write_footprint")
                    for next in successors[row.address] ?? [] { incoming[next, default: []].append(state) }
                    continue
                }
                for register in writes { state.removeValue(forKey: register) }
                if mnemonic == "mov", operands.count == 2,
                   let destination = xRegister(operands[0]), let source = xRegister(operands[1]),
                   case let .pointer(originalPointer)? = old[source], originalPointer.isRoot,
                   linearClean(source, after: originalPointer.definition, before: row.address) {
                    var pointer = originalPointer
                    pointer.root.copies.append(row.address)
                    pointer.definition = row.address
                    state[destination] = .pointer(pointer)
                } else if mnemonic == "adr", operands.count == 2,
                          let destination = xRegister(operands[0]), let target = number(operands[1]), target >= 0 {
                    state[destination] = .literal(UInt64(target), row.address)
                } else if mnemonic == "adrp", operands.count == 2,
                          let destination = xRegister(operands[0]), let target = number(operands[1]), target >= 0 {
                    state[destination] = .page(UInt64(target), row.address)
                } else if mnemonic == "add", operands.count == 3,
                          let destination = xRegister(operands[0]), let source = xRegister(operands[1]),
                          case let .page(page, origin)? = old[source], let offset = number(operands[2]), offset >= 0,
                          UInt64(offset) <= UInt64.max - page {
                    state[destination] = .literal(page + UInt64(offset), origin)
                } else if mnemonic == "ldr", operands.count == 2, let destination = xRegister(operands[0]),
                          let memory = memory(operands[1]), case let .pointer(pointer)? = old[memory.0],
                          linearClean(memory.0, after: pointer.definition, before: row.address),
                          let field = field(pointer.owner, offset: memory.1, catalog: catalog) {
                    if let signature = field.functionPointerSignatureV1,
                       let key = canonical(signature, catalog: catalog) {
                        let slot = "\(pointer.owner)+\(memory.1):\(key)"
                        state[destination] = .callable(.init(pointer: pointer, slot: slot, fieldName: field.name, load: row.address, signature: signature))
                    } else if field.functionPointerSignatureV1 == nil,
                              field.declaratorSemanticsV1 != .functionPointerCarrier,
                              let owner = structName(field.type, catalog: catalog), !duplicateTypes.contains(owner) {
                        var chased = pointer
                        chased.chase.append("\(pointer.owner)+\(memory.1).\(field.name)@\(row.address)")
                        chased.owner = owner
                        chased.definition = row.address
                        state[destination] = .pointer(chased)
                    }
                } else if mnemonic == "str", operands.count == 2, let memory = memory(operands[1]),
                          case let .pointer(pointer)? = old[memory.0],
                          linearClean(memory.0, after: pointer.definition, before: row.address),
                          let field = field(pointer.owner, offset: memory.1, catalog: catalog),
                          let signature = field.functionPointerSignatureV1, let key = canonical(signature, catalog: catalog) {
                    let slot = "\(pointer.owner)+\(memory.1):\(key)"
                    if let register = xRegister(operands[0]), case let .literal(target, _)? = old[register], functionStarts.contains(target) {
                        stores.append(.init(function: start, address: row.address, target: target, slot: slot, signature: signature))
                    } else if operands[0] != "xzr" {
                        // No target signature can be checked for an unknown writer.
                        poisoned.insert(slot)
                        refuse(start, row.address, "unclassified_slot_writer")
                    }
                }
                if isIndirect(mnemonic) {
                    let slotTail = includeSlotTails && mnemonic == "br"
                    guard (mnemonic == "blr" || slotTail), operands.count == 1,
                          let register = xRegister(operands[0]),
                          case let .callable(callable)? = old[register],
                          linearClean(register, after: callable.load, before: row.address),
                          let key = canonical(callable.signature, catalog: catalog) else {
                        refuse(start, row.address, slotTail ? "br_not_proven_tail" : "unproved_or_unsupported_indirect_contract")
                        for next in successors[row.address] ?? [] { incoming[next, default: []].append(state.filter { $0.value.persistent }) }
                        continue
                    }
                    let signature: MacIRCallSignature
                    if slotTail {
                        guard tailFrames.contains(row.address), successors[row.address]?.isEmpty == true,
                              let declared = callSignature(contract: callable.signature, target: operands[0], types: types) else {
                            refuse(start, row.address, "br_not_proven_tail"); continue
                        }
                        signature = declared
                    } else {
                        guard let effects = irGroups[row.address], effects.count == 1,
                              case let .call(frame, _) = effects[0].operation,
                              frame.controlInputs.indirectTarget != nil,
                              let declared = callSignature(contract: callable.signature, target: frame.target, types: types) else {
                            refuse(start, row.address, "unproved_or_unsupported_indirect_contract")
                            for next in successors[row.address] ?? [] { incoming[next, default: []].append(state.filter { $0.value.persistent }) }
                            continue
                        }
                        signature = declared
                    }
                    report.callContracts[row.address] = callable.signature
                    if !slotTail { report.callSignatures[row.address] = signature }
                    callSlots[row.address] = callable.slot
                    report.callProofRows.append(.init(functionStart: start, callAddress: row.address, loadAddress: callable.load,
                        rootFunctionStart: callable.pointer.root.function, rootParameterIndex: callable.pointer.root.parameter,
                        rootType: callable.pointer.root.type, rootRegister: callable.pointer.root.register,
                        rootCopyAddresses: callable.pointer.root.copies,
                        pointerChase: callable.pointer.chase + ["\(callable.slot)@\(callable.load)"] + (slotTail ? ["field=\(callable.fieldName)"] : []),
                        physicalProof: "retained header definitions exactly match current catalog ignoring UUID only; complete catalog dependency closure; " +
                            (invariantPlan == nil ? "all forward paths agree on unique full-width physical reaching definition" :
                                "acyclic entry prefix or dominating immutable physical root carrier; whole-function write inventory with only terminal stack-LDP/RET exception; no unresolved CFG edges; fresh block-local loads") +
                            (slotTail ? "; terminal BR; entry SP and entry LR proven; immediate typed-field LDR excludes indexed dispatch" : "") +
                            "; W/X aliases and AAPCS64 call clobbers applied; legacy address-order linearClean checked; captured target retained",
                        canonicalContract: key, abiProof: "fixed scalar GPR parameters and supported scalar/void return; DarwinARM64ParameterBinder",
                        callInstruction: "\(row.mnemonic) \(row.operands) [\(row.bytes)]"))
                }
                let edges = successors[row.address] ?? []
                let barrier = mnemonic == "bl" || mnemonic == "blr" || mnemonic == "b" || mnemonic.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
                if barrier { state = state.filter { $0.value.persistent } }
                for next in edges {
                    var outgoing = state
                    if predecessors[next, default: 0] > 1 { outgoing = outgoing.filter { $0.value.persistent } }
                    incoming[next, default: []].append(outgoing)
                }
            }
        }
        for store in stores {
            if let existing = effectiveSignatures[store.target], !agrees(existing, with: store.signature, catalog: catalog) {
                poisoned.insert(store.slot)
                refuse(store.function, store.address, "effective_callee_contract_conflict", target: store.target)
            }
        }
        for (_, group) in Dictionary(grouping: stores, by: \.target) {
            let contracts = Set(group.compactMap { canonical($0.signature, catalog: catalog) })
            if contracts.count != 1 {
                for store in group {
                    poisoned.insert(store.slot)
                    refuse(store.function, store.address, "conflicting_recursive_slot_contracts", target: store.target)
                }
            }
        }
        for (address, slot) in callSlots where poisoned.contains(slot) {
            report.callContracts.removeValue(forKey: address)
            report.callSignatures.removeValue(forKey: address)
            if let proof = report.callProofRows.first(where: { $0.callAddress == address }) {
                refuse(proof.functionStart, address, "poisoned_slot_contract")
            }
        }
        // Generic nil/untyped footprint isolation. Raw sites include indirect
        // transfers the first-pass lifter might not have represented as calls.
        for (function, sites) in functionSites where sites.contains(where: { report.callContracts[$0] == nil }) {
            for address in sites where report.callContracts[address] != nil {
                report.callContracts.removeValue(forKey: address)
                report.callSignatures.removeValue(forKey: address)
                refuse(function, address, "mixed_untyped_indirect_footprint")
            }
        }
        // Capture before mutating another field of the value-type report; a
        // closure reading report here would overlap Swift's exclusive write.
        let admittedCallAddresses = Set(report.callContracts.keys)
        report.callProofRows.removeAll { !admittedCallAddresses.contains($0.callAddress) }
        // No optimistic empty certificate: original code inventory, all address
        // uses and non-code encodings need a separate slot-specific certificate.
        // This initial implementation collects candidates but does not claim one.
        for store in stores {
            refuse(store.function, store.address, "incomplete_noncode_escape_inventory", target: store.target)
        }
        report.census["literal_slot_store_candidates"] = stores.count
        report.census["admitted_call_contracts"] = report.callContracts.count
        report.census["derived_callee_signatures"] = 0 // No slot-specific escape certificate is available.
        report.census["built_functions"] = builtFunctions.count
        report.census["function_starts"] = functionStarts.count
        if Set(builtFunctions.map(\.startAddress)) != functionStarts {
            report.census["incomplete_function_inventory", default: 0] += 1
        }
        return report
    }

    private struct TailFrame: Equatable {
        var sp: Int64 = 0
        var fp: Int64? = nil
        var entryLR = true
        var savedLR: Set<Int64> = []
    }

    /// Separate physical frame proof. It never changes the builder's BR IR.
    /// Unsupported edges, stack arithmetic or write footprints refuse the tail.
    private static func provenTailFrames(rows: [InstructionRow], start: UInt64,
        successors: [UInt64: [UInt64]], reachable: Set<UInt64>) -> Set<UInt64> {
        guard successors.allSatisfy({ address, next in next.allSatisfy { $0 > address } }) else { return [] }
        var incoming: [UInt64: [TailFrame?]] = [start: [TailFrame()]]
        var proven: Set<UInt64> = []
        for row in rows where reachable.contains(row.address) {
            guard let candidates = incoming[row.address], let first = candidates.first else { continue }
            var state = candidates.allSatisfy { $0 == first } ? first : nil
            let mnemonic = row.mnemonic.lowercased()
            let operands = MacIRBuilder.splitOperands(row.operands).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            if mnemonic == "br", let frame = state, frame.sp == 0, frame.entryLR {
                proven.insert(row.address)
            }
            if var frame = state {
                let before = frame
                if let changed = writes(mnemonic, operands) {
                    if changed.contains(30) { frame.entryLR = false }
                    if changed.contains(29) { frame.fp = nil }
                    if ["add", "sub"].contains(mnemonic), operands.count == 3, operands[0] == "sp" {
                        let base = operands[1] == "sp" ? before.sp : (operands[1] == "x29" ? before.fp : nil)
                        if let base, let amount = number(operands[2]) {
                            let result = mnemonic == "add" ? base.addingReportingOverflow(amount) : base.subtractingReportingOverflow(amount)
                            if result.overflow { state = nil } else { frame.sp = result.partialValue }
                        } else { state = nil }
                    } else if mnemonic == "mov", operands == ["x29", "sp"] {
                        frame.fp = before.sp
                    } else if mnemonic == "mov", operands == ["sp", "x29"], let fp = before.fp {
                        frame.sp = fp
                    } else if operands.first == "sp" || operands.first == "wsp" {
                        state = nil
                    }
                    let memoryIndex = ["stp", "ldp"].contains(mnemonic) ? 2 : 1
                    if ["str", "stur", "stp", "ldr", "ldur", "ldp", "strb", "strh", "sturb", "sturh", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw"].contains(mnemonic), operands.count > memoryIndex {
                        let text = operands[memoryIndex]
                        let pre = text.hasSuffix("!")
                        let bracket = pre ? String(text.dropLast()) : text
                        let parts = bracket.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        let base = parts.first == "sp" ? before.sp : (parts.first == "x29" ? before.fp : nil)
                        let post = operands.count == memoryIndex + 2
                        let load = mnemonic.hasPrefix("ld")
                        if let base, parts.count <= 2, let offset = parts.count == 1 ? 0 : number(parts[1]) {
                            let sum = base.addingReportingOverflow(offset)
                            if sum.overflow { state = nil }
                            else {
                                let address = sum.partialValue
                                let widths = operands.prefix(memoryIndex).map { operand -> Int64 in
                                    if mnemonic.hasSuffix("b") { return 1 }
                                    if mnemonic.hasSuffix("h") { return 2 }
                                    if mnemonic.hasSuffix("sw") { return 4 }
                                    if operand.hasPrefix("x") || operand.hasPrefix("d") { return 8 }
                                    if operand.hasPrefix("q") { return 16 }
                                    return mnemonic.hasSuffix("b") ? 1 : (mnemonic.hasSuffix("h") ? 2 : 4)
                                }
                                var cursor = address
                                for (index, width) in widths.enumerated() {
                                    let next = cursor.addingReportingOverflow(width)
                                    if next.overflow { state = nil; break }
                                    if load {
                                        if operands[index] == "x30" { frame.entryLR = width == 8 && before.savedLR.contains(cursor) }
                                    } else {
                                        frame.savedLR = frame.savedLR.filter { $0 <= Int64.max - 8 && !($0 < next.partialValue && $0 + 8 > cursor) }
                                        if operands[index] == "x30", before.entryLR { frame.savedLR.insert(cursor) }
                                    }
                                    cursor = next.partialValue
                                }
                                if pre || post {
                                    guard parts.first == "sp", let delta = post ? number(operands[memoryIndex + 1]) : offset else {
                                        state = nil
                                        for next in successors[row.address] ?? [] { incoming[next, default: []].append(nil) }
                                        continue
                                    }
                                    let updated = before.sp.addingReportingOverflow(delta)
                                    if updated.overflow { state = nil } else { frame.sp = updated.partialValue }
                                }
                            }
                        } else if parts.first == "sp" || parts.first == "x29" {
                            state = nil
                        } else if !load {
                            // An unproved store may alias an LR save slot.
                            frame.savedLR.removeAll()
                        }
                    }
                    if state != nil { state = frame }
                } else { state = nil }
            }
            for next in successors[row.address] ?? [] { incoming[next, default: []].append(state) }
        }
        return proven
    }

    private struct InvariantPlan {
        var successors: [UInt64: [UInt64]]
        var reachable: Set<UInt64>
        var leaders: Set<UInt64>
        var seeds: [UInt64: [Int: Fact]]
    }

    /// This is deliberately not general reaching-definition inference. Only one
    /// direct MOV from an unchanged H1 entry carrier, in the acyclic entry prefix,
    /// can create an invariant. All physical writes in the entire decoded body
    /// are examined, including unreachable blocks and W aliases. Loaded memory
    /// values are never invariants. A restore exception must be an exact modeled
    /// stack LDP immediately followed by ordinary RET, with no path back.
    private static func invariantCarrierPlan(rows: [InstructionRow], start: UInt64, end: UInt64,
                                             functionStarts: Set<UInt64>, roots: [Int: Fact]) -> InvariantPlan? {
        guard !Task.isCancelled else { return nil }
        let byAddress = Dictionary(uniqueKeysWithValues: rows.map { ($0.address, $0) })
        var writers: [Int: [UInt64]] = [:]
        for row in rows {
            guard !Task.isCancelled else { return nil }
            let operands = MacIRBuilder.splitOperands(row.operands).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            guard let changed = writes(row.mnemonic.lowercased(), operands) else { return nil }
            for register in changed { writers[register, default: []].append(row.address) }
        }
        var successors: [UInt64: [UInt64]] = [:]
        var reachable: Set<UInt64> = []
        var pending = [start]
        var leaders: Set<UInt64> = [start]
        while let address = pending.popLast() {
            guard !Task.isCancelled else { return nil }
            guard reachable.insert(address).inserted else { continue }
            guard let row = byAddress[address] else { return nil }
            let mnemonic = row.mnemonic.lowercased()
            let operands = MacIRBuilder.splitOperands(row.operands)
            // In particular BR and authenticated indirect jumps are NOT exits
            // with proven successors. This mode refuses them, even at epilogues.
            if isIndirect(mnemonic) && mnemonic != "blr" { return nil }
            guard let next = edges(row, end: end) else { return nil }
            if next.isEmpty {
                let ordinaryReturn = mnemonic == "ret" && (operands.isEmpty || operands == ["x30"])
                let directTail = mnemonic == "b" && operands.count == 1 &&
                    (number(operands[0]).map { $0 >= 0 && UInt64($0) >= end } ?? false)
                let finalDirectCall = mnemonic == "bl" && operands.count == 1 &&
                    (number(operands[0]).map { $0 >= 0 } ?? false) &&
                    row.address + 4 == end && end != start && functionStarts.contains(end)
                guard ordinaryReturn || directTail || finalDirectCall else { return nil }
                if finalDirectCall {
                    // Planner-local extent terminal only, never a noreturn fact.
                    // Branches may reach this BL, but none may escape past it.
                    // Check the whole body, including unreachable dispatches.
                    for instruction in rows {
                        let operation = instruction.mnemonic.lowercased()
                        if isIndirect(operation) && operation != "blr" { return nil }
                        if operation == "b" || operation.hasPrefix("b.") ||
                            ["cbz", "cbnz", "tbz", "tbnz"].contains(operation) {
                            guard let operand = MacIRBuilder.splitOperands(instruction.operands).last,
                                  let target = number(operand), target >= 0, UInt64(target) < end else { return nil }
                        }
                    }
                }
            }
            successors[address] = next
            let branch = mnemonic == "b" || mnemonic.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic)
            for target in next {
                guard target != start, byAddress[target] != nil else { return nil }
                if branch { leaders.insert(target) }
                pending.append(target)
            }
        }
        var predecessors: [UInt64: Set<UInt64>] = [:]
        for (address, next) in successors {
            guard !Task.isCancelled else { return nil }
            for target in next { predecessors[target, default: []].insert(address) }
        }
        for (target, previous) in predecessors where previous.count > 1 { leaders.insert(target) }
        func descendants(_ origin: UInt64) -> Set<UInt64>? {
            var seen: Set<UInt64> = []
            var work = successors[origin] ?? []
            while let next = work.popLast() {
                guard !Task.isCancelled else { return nil }
                guard seen.insert(next).inserted else { continue }
                work += successors[next] ?? []
            }
            return seen
        }
        // Exact dominance query using linear space: an already-reachable
        // leader is dominated iff removing the definition makes it unreachable.
        // No per-instruction dominator matrix or convergence loop is allocated.
        func reachableExcluding(_ excluded: UInt64) -> Set<UInt64>? {
            var seen: Set<UInt64> = []
            var work = [start]
            while let address = work.popLast() {
                guard !Task.isCancelled else { return nil }
                guard address != excluded, seen.insert(address).inserted else { continue }
                work += successors[address] ?? []
            }
            return seen
        }
        // Follow the actual CFG, never an instruction-count epilogue pattern.
        // Every successor must be another modeled stack restore/deallocation or
        // ordinary RET. Branches, calls, cycles and missing edges refuse.
        func terminalRestore(_ row: InstructionRow) -> Bool {
            func stackRestore(_ instruction: InstructionRow) -> Bool {
                let operands = MacIRBuilder.splitOperands(instruction.operands).map {
                    $0.lowercased().trimmingCharacters(in: .whitespaces)
                }
                guard instruction.mnemonic.lowercased() == "ldp", operands.count >= 3,
                      xRegister(operands[0]) != nil, xRegister(operands[1]) != nil,
                      let memory = physicalMemory(operands, at: 2), memory.base == nil,
                      memory.immediate, writes("ldp", operands) != nil else { return false }
                return true
            }
            guard stackRestore(row) else { return false }
            var pending = [row.address]
            var seen: Set<UInt64> = []
            while let address = pending.popLast() {
                guard !Task.isCancelled, seen.insert(address).inserted,
                      let instruction = byAddress[address], let next = successors[address] else { return false }
                let mnemonic = instruction.mnemonic.lowercased()
                let operands = MacIRBuilder.splitOperands(instruction.operands).map {
                    $0.lowercased().trimmingCharacters(in: .whitespaces)
                }
                if mnemonic == "ret" {
                    guard operands.isEmpty || operands == ["x30"], next.isEmpty else { return false }
                    continue
                }
                let deallocation = mnemonic == "add" && operands.count == 3 &&
                    operands[0] == "sp" && operands[1] == "sp" &&
                    (number(operands[2]).map { $0 > 0 && $0 % 16 == 0 } ?? false)
                guard stackRestore(instruction) || deallocation, next.count == 1 else { return false }
                pending.append(contentsOf: next)
            }
            return true
        }
        var terminalRestores: Set<UInt64> = []
        for row in rows {
            guard !Task.isCancelled else { return nil }
            if terminalRestore(row) { terminalRestores.insert(row.address) }
        }
        var nonRestoreWriters: [Int: [UInt64]] = [:]
        var firstWrite: [Int: UInt64] = [:]
        for (register, addresses) in writers {
            guard !Task.isCancelled else { return nil }
            firstWrite[register] = addresses.min()
            nonRestoreWriters[register] = addresses.filter { !terminalRestores.contains($0) }
        }
        var invariants: [(register: Int, definition: UInt64, fact: Fact)] = []
        for row in rows {
            guard !Task.isCancelled else { return nil }
            guard reachable.contains(row.address) else { break }
            let mnemonic = row.mnemonic.lowercased()
            if mnemonic == "b" || mnemonic.hasPrefix("b.") || mnemonic == "bl" || isIndirect(mnemonic) ||
                ["cbz", "cbnz", "tbz", "tbnz", "ret", "retaa", "retab"].contains(mnemonic) { break }
            let operands = MacIRBuilder.splitOperands(row.operands).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            guard mnemonic == "mov", operands.count == 2,
                  let destination = xRegister(operands[0]), let source = xRegister(operands[1]), destination != source,
                  case let .pointer(root)? = roots[source], root.isRoot,
                  nonRestoreWriters[destination] == [row.address],
                  firstWrite[source].map({ $0 >= row.address }) ?? true else { continue }
            // Global unique-write and unchanged-source gates precede graph
            // traversal, bounding expensive queries by physical carrier count.
            guard let after = descendants(row.address) else { return nil }
            guard !after.contains(row.address) else { continue }
            var pointer = root
            pointer.root.copies.append(row.address)
            pointer.definition = row.address
            invariants.append((destination, row.address, .pointer(pointer)))
        }
        // A second non-restore definition of one physical carrier already
        // fails the write inventory. Assert that bound before graph queries.
        guard !invariants.isEmpty, invariants.count <= 31,
              Set(invariants.map { $0.register }).count == invariants.count else { return nil }
        var seeds: [UInt64: [Int: Fact]] = [:]
        for invariant in invariants {
            guard let bypass = reachableExcluding(invariant.definition) else { return nil }
            for leader in leaders where leader != start && leader != invariant.definition && !bypass.contains(leader) {
                guard !Task.isCancelled else { return nil }
                seeds[leader, default: [:]][invariant.register] = invariant.fact
            }
        }
        return .init(successors: successors, reachable: reachable, leaders: leaders, seeds: seeds)
    }

    public static func callSignature(contract: FunctionPointerSignatureV1, target: String,
                                     types: [TypeDefinition]) -> MacIRCallSignature? {
        guard !contract.isVariadic, !contract.hasUnspecifiedParameters else { return nil }
        let catalog = Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard catalog.count == types.count, canonical(contract, catalog: catalog) != nil else { return nil }
        let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog: catalog)
        let abiTypes = contract.parameters.map { parameter -> String in
            callback(parameter.type, explicit: parameter.functionPointerSignatureV1, catalog: catalog) != nil ? "void *" : parameter.type
        }
        guard abiTypes.allSatisfy({ resolver.resolveLayout(ofType: $0)?.kind == .integer }),
              contract.returnType == "void" || (resolver.resolveLayout(ofType: contract.returnType).map { $0.kind == .integer && (1...8).contains($0.size) } ?? false) else { return nil }
        let bindings = DarwinARM64ParameterBinder.bindRich(parameterTypes: abiTypes, resolver: resolver)
        var parameters: [MacIRCallParameter] = []
        for (index, parameter) in contract.parameters.enumerated() {
            guard case let .gpr(register, width) = bindings[index], width == 32 || width == 64 else { return nil }
            parameters.append(.init(index: index, register: "\(width == 32 ? "w" : "x")\(register)",
                type: parameter.type, name: parameter.name))
        }
        return .init(target: target, returnType: contract.returnType, parameters: parameters,
                     isVariadic: false, source: "header-derived-slot")
    }

    /// Greatest fixed point of locally exact header matches. Dependencies are
    /// gathered before filtering, so a removed node cannot become an apparently
    /// primitive type. Cyclic records survive only if every reachable dependency
    /// survives; there is no optimistic DFS visiting/memo shortcut.
    private static func headerCatalog(current: [String: TypeDefinition], evidence: [TypeDefinition])
        -> (catalog: [String: TypeDefinition], refusals: [String: String]) {
        let groups = Dictionary(grouping: evidence, by: \.name)
        let universe = Set(current.keys).union(groups.keys)
        var candidates: Set<String> = []
        var dependencies: [String: Set<String>] = [:]
        var refusals: [String: String] = [:]
        func names(_ type: String) -> Set<String> {
            Set(type.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)).intersection(universe)
        }
        func signatureDependencies(_ signature: FunctionPointerSignatureV1, depth: Int) -> Set<String>? {
            guard depth < 64 else { return nil }
            var result = names(signature.returnType)
            for parameter in signature.parameters {
                result.formUnion(names(parameter.type))
                if let nested = parameter.functionPointerSignatureV1 {
                    guard let child = signatureDependencies(nested, depth: depth + 1) else { return nil }
                    result.formUnion(child)
                }
            }
            return result
        }
        func fieldDependencies(_ field: FieldDef, depth: Int) -> Set<String>? {
            guard depth < 64, field.isAtomic != true, field.layoutIsUnknown != true,
                  !field.type.split(whereSeparator: { !$0.isLetter && $0 != "_" }).contains("_Atomic") else { return nil }
            var result = names(field.type)
            if let alignment = field.minimumAlignmentType { result.formUnion(names(alignment)) }
            if let signature = field.functionPointerSignatureV1 {
                guard let child = signatureDependencies(signature, depth: depth + 1) else { return nil }
                result.formUnion(child)
            }
            for inline in field.inlineFields {
                guard let child = fieldDependencies(inline, depth: depth + 1) else { return nil }
                result.formUnion(child)
            }
            return result
        }
        for (name, definition) in current {
            guard let matches = groups[name], matches.count == 1, var header = matches.first else {
                refusals[name] = groups[name] == nil ? "header_definition_absent" : "header_definition_ambiguous"
                continue
            }
            header.id = definition.id
            guard header == definition, definition.inferenceProvenance == nil else {
                refusals[name] = "header_definition_mismatch_or_inferred"; continue
            }
            var required: Set<String> = []
            var valid = true
            for field in definition.fields {
                guard let child = fieldDependencies(field, depth: 0) else { valid = false; break }
                required.formUnion(child)
            }
            guard valid else { refusals[name] = "unsupported_header_layout_dependency"; continue }
            candidates.insert(name)
            dependencies[name] = required
        }
        while true {
            let removed = candidates.filter { !(dependencies[$0] ?? []).isSubset(of: candidates) }
            guard !removed.isEmpty else { break }
            for name in removed {
                candidates.remove(name)
                refusals[name] = "header_dependency_not_proven"
            }
        }
        return (current.filter { candidates.contains($0.key) }, refusals)
    }

    /// The persisted catalog does not carry a positive header-origin marker.
    /// This secondary veto rejects known inferred/atomic definitions. Analyze
    /// separately requires retained exact header evidence through headerCatalog;
    /// the public ABI conversion helper consumes an already-proven contract and
    /// does not independently manufacture that origin authority.
    private static func hasCatalogAuthority(_ type: String, catalog: [String: TypeDefinition],
                                            visiting: Set<String> = []) -> Bool {
        let words = type.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        guard !words.contains(where: { $0 == "_Atomic" || $0 == "atomic" }) else { return false }
        for name in Set(words) {
            guard let definition = catalog[name] else { continue }
            guard definition.inferenceProvenance == nil else { return false }
            if definition.kind == .typedef {
                guard !visiting.contains(name), definition.fields.count == 1,
                      let field = definition.fields.first, field.isAtomic != true,
                      field.layoutIsUnknown != true,
                      hasCatalogAuthority(field.type, catalog: catalog, visiting: visiting.union([name])) else { return false }
            }
        }
        return true
    }

    private static func callback(_ type: String, explicit: FunctionPointerSignatureV1?,
                                 catalog: [String: TypeDefinition], visiting: Set<String> = []) -> FunctionPointerSignatureV1? {
        guard hasCatalogAuthority(type, catalog: catalog) else { return nil }
        if let explicit { return explicit }
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visiting.contains(name), let definition = catalog[name], definition.kind == .typedef,
              let field = definition.fields.first else { return nil }
        return callback(field.type, explicit: field.functionPointerSignatureV1, catalog: catalog, visiting: visiting.union([name]))
    }
    private static func canonical(_ signature: FunctionPointerSignatureV1, catalog: [String: TypeDefinition], depth: Int = 0) -> String? {
        guard depth < 64, hasCatalogAuthority(signature.returnType, catalog: catalog),
              let result = canonicalType(signature.returnType, catalog: catalog) else { return nil }
        var parameters: [String] = []
        for parameter in signature.parameters {
            guard hasCatalogAuthority(parameter.type, catalog: catalog) else { return nil }
            if let nested = callback(parameter.type, explicit: parameter.functionPointerSignatureV1, catalog: catalog) {
                guard let key = canonical(nested, catalog: catalog, depth: depth + 1) else { return nil }
                parameters.append("callback{\(key)}")
            } else {
                guard let key = canonicalType(parameter.type, catalog: catalog) else { return nil }
                parameters.append(key)
            }
        }
        return "\(result)(\(parameters.joined(separator: ",")));unspecified=\(signature.hasUnspecifiedParameters);variadic=\(signature.isVariadic)"
    }
    private static func canonicalType(_ type: String, catalog: [String: TypeDefinition], visiting: Set<String> = []) -> String? {
        let name = type.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty, !visiting.contains(name), hasCatalogAuthority(name, catalog: catalog) else { return nil }
        if let definition = catalog[name], definition.kind == .typedef, let field = definition.fields.first {
            // Callback aliases are handled recursively by canonical(parameter). A
            // callback return/opaque type here is unsupported, avoiding alias cycles.
            if field.functionPointerSignatureV1 != nil { return nil }
            return canonicalType(field.type, catalog: catalog, visiting: visiting.union([name]))
        }
        let aliases = ["int": "int32_t", "signed int": "int32_t", "unsigned int": "uint32_t", "long": "int64_t", "long int": "int64_t", "unsigned long": "uint64_t", "long long": "int64_t", "unsigned long long": "uint64_t"]
        return aliases[name] ?? name.replacingOccurrences(of: " *", with: "*").replacingOccurrences(of: "* ", with: "*")
    }
    private static func agrees(_ existing: FunctionSignatureOverride, with signature: FunctionPointerSignatureV1,
                               catalog: [String: TypeDefinition]) -> Bool {
        guard case let .authoritative(arguments) = existing.parameterList,
              existing.noReturnState != .noReturn, let result = existing.returnType,
              existing.variadicState != .unspecified else { return false }
        let other = FunctionPointerSignatureV1(returnType: result,
            parameters: arguments.map { .init(name: $0.name, type: $0.type) },
            isVariadic: existing.variadicState == .variadic)
        guard let left = canonical(other, catalog: catalog), let right = canonical(signature, catalog: catalog) else { return false }
        return left == right
    }
    private static func structName(_ type: String, catalog: [String: TypeDefinition], visiting: Set<String> = []) -> String? {
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visiting.contains(name), hasCatalogAuthority(name, catalog: catalog) else { return nil }
        if let definition = catalog[name], definition.kind == .typedef, let target = definition.fields.first?.type {
            return structName(target, catalog: catalog, visiting: visiting.union([name]))
        }
        guard let normalized = DarwinARM64ParameterBinder.normalizedDataPointer(name),
              let candidate = normalized.catalogStructName, let definition = catalog[candidate],
              definition.kind == .struct, definition.inferenceProvenance == nil else { return nil }
        return candidate
    }
    private static func field(_ owner: String, offset: Int64, catalog: [String: TypeDefinition]) -> FieldDef? {
        guard offset >= 0, let definition = catalog[owner], definition.inferenceProvenance == nil,
              TypeAtlasDarwinARM64LayoutResolver(catalog: catalog).resolveLayout(ofType: "struct " + owner) != nil else { return nil }
        let members = definition.memberLayout(in: catalog).filter { Int64($0.offset) == offset }
        guard members.count == 1, let member = members.first,
              member.field.bitWidth == nil, member.field.layoutIsUnknown != true,
              member.field.isAtomic != true,
              member.field.declaratorSemanticsV1 != .pointerToArrayCarrier,
              member.field.declaratorSemanticsV1 != .arrayOfFunctionPointerCarrier,
              hasCatalogAuthority(member.field.type, catalog: catalog),
              TypeDefinition.size(ofType: member.field.type, in: catalog) == 8 else { return nil }
        return member.field
    }
    private static func number(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if value.hasPrefix("0x") { return Int64(value.dropFirst(2), radix: 16) }
        if value.hasPrefix("-0x"), let magnitude = Int64(value.dropFirst(3), radix: 16) { return -magnitude }
        return Int64(value)
    }
    private static func xRegister(_ text: String) -> Int? {
        guard text.first == "x", let index = Int(text.dropFirst()), (0...30).contains(index) else { return nil }
        return index
    }
    private static func register(_ text: String) -> Int? {
        guard text.first == "x" || text.first == "w", let index = Int(text.dropFirst()), (0...30).contains(index) else { return nil }
        return index
    }
    private static func memory(_ operand: String) -> (Int, Int64)? {
        guard operand.first == "[", operand.last == "]" else { return nil }
        let parts = operand.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 1 || parts.count == 2, let base = xRegister(parts[0]) else { return nil }
        guard let offset = parts.count == 1 ? 0 : number(parts[1]) else { return nil }
        return (base, offset)
    }
    private static func isIndirect(_ mnemonic: String) -> Bool {
        ["blr", "blraa", "blrab", "blraaz", "blrabz", "br", "braa", "brab", "braaz", "brabz"].contains(mnemonic)
    }
    private static func edges(_ row: InstructionRow, end: UInt64) -> [UInt64]? {
        let mnemonic = row.mnemonic.lowercased()
        let operands = MacIRBuilder.splitOperands(row.operands)
        if ["ret", "retaa", "retab", "br", "braa", "brab", "braaz", "brabz"].contains(mnemonic) { return [] }
        if mnemonic == "b" {
            guard operands.count == 1, let target = number(operands[0]), target >= 0 else { return nil }
            return UInt64(target) >= end ? [] : [UInt64(target)]
        }
        if mnemonic.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) {
            guard let last = operands.last, let target = number(last), target >= 0, row.address + 4 < end else { return nil }
            return [row.address + 4, UInt64(target)]
        }
        return row.address + 4 < end ? [row.address + 4] : []
    }
    /// Parse the address form separately from its data operands. SP has no GPR
    /// alias; pre/post indexing on any X base writes that physical register.
    private static func physicalMemory(_ operands: [String], at index: Int)
        -> (base: Int?, writeback: Bool, immediate: Bool)? {
        guard operands.count == index + 1 || operands.count == index + 2 else { return nil }
        let operand = operands[index]
        let pre = operand.hasSuffix("!")
        let bracket = pre ? String(operand.dropLast()) : operand
        guard bracket.first == "[", bracket.last == "]" else { return nil }
        let parts = bracket.dropFirst().dropLast().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = parts.first, first == "sp" || xRegister(first) != nil,
              (1...3).contains(parts.count) else { return nil }
        let immediate = parts.count == 1 || (parts.count == 2 && number(parts[1]) != nil)
        if !immediate {
            guard parts.count >= 2, register(parts[1]) != nil else { return nil }
            if parts.count == 3 {
                let shift = parts[2].split(separator: " ").map(String.init)
                guard let kind = shift.first, ["lsl", "uxtw", "sxtw", "sxtx"].contains(kind),
                      shift.count == 1 || (shift.count == 2 && number(shift[1]) != nil) else { return nil }
            }
        }
        let post = operands.count == index + 2
        guard !(pre && post), (!pre || immediate),
              !post || (parts.count == 1 && number(operands[index + 1]) != nil) else { return nil }
        return (xRegister(first), pre || post, immediate)
    }
    private static func vectorRegister(_ operand: String) -> Bool {
        let parts = operand.split(separator: ".").map(String.init)
        guard let name = parts.first, let prefix = name.first,
              let index = Int(name.dropFirst()), (0...31).contains(index) else { return false }
        if "bhsdq".contains(prefix) { return parts.count == 1 }
        return prefix == "v" && parts.count == 2 &&
            ["8b", "16b", "4h", "8h", "2s", "4s", "1d", "2d"].contains(parts[1])
    }
    /// Exact modeled opcode families only. An unknown footprint kills every fact.
    private static func writes(_ mnemonic: String, _ operands: [String]) -> Set<Int>? {
        if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic) { return Set(0...18).union([30]) }
        if ["nop", "ret", "retaa", "retab", "b", "br", "braa", "brab", "braaz", "brabz", "cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "fcmpe", "cbz", "cbnz", "tbz", "tbnz"].contains(mnemonic) || mnemonic.hasPrefix("b.") { return [] }
        // These SIMD families have only FP/vector destinations. Do not classify
        // arbitrary SIMD-looking opcodes as harmless (FMOV can write W/X).
        if ["movi", "cmeq", "mvn", "umaxv"].contains(mnemonic),
           let first = operands.first, vectorRegister(first) {
            if mnemonic == "movi" { return operands.count >= 2 && operands[1].hasPrefix("#") ? [] : nil }
            guard operands.count == (mnemonic == "cmeq" ? 3 : 2),
                  operands.dropFirst().allSatisfy({ vectorRegister($0) }) else { return nil }
            return []
        }
        if mnemonic == "fmov", operands.count == 2 {
            if let destination = register(operands[0]), vectorRegister(operands[1]) { return [destination] }
            if vectorRegister(operands[0]), vectorRegister(operands[1]) || register(operands[1]) != nil || operands[1].hasPrefix("#") { return [] }
            return nil
        }
        let single = ["mov", "movz", "movn", "movk", "adr", "adrp", "add", "adds", "sub", "subs", "and", "ands", "orr", "eor", "bic", "orn", "eon", "lsl", "lsr", "asr", "ror", "mul", "madd", "msub", "udiv", "sdiv", "neg", "negs", "mvn", "csel", "csinc", "csinv", "csneg", "cset", "csetm", "uxtb", "uxth", "sxtb", "sxth", "sxtw", "ubfx", "ubfiz", "sbfx", "bfi", "bfxil", "clz", "rbit", "rev", "rev16", "rev32"]
        if single.contains(mnemonic), let first = operands.first {
            if first == "sp" || first == "wsp" || first == "xzr" || first == "wzr" { return [] }
            return register(first).map { [$0] }
        }
        let loads = ["ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw", "ldp"]
        let stores = ["str", "stur", "strb", "strh", "sturb", "sturh", "stp"]
        if loads.contains(mnemonic) || stores.contains(mnemonic) {
            let count = mnemonic == "ldp" || mnemonic == "stp" ? 2 : 1
            guard operands.count > count, let memory = physicalMemory(operands, at: count) else { return nil }
            var changed: Set<Int> = []
            for operand in operands.prefix(count) {
                if let register = register(operand) {
                    if loads.contains(mnemonic) { changed.insert(register) }
                } else if operand != "xzr" && operand != "wzr" && !vectorRegister(operand) { return nil }
            }
            if memory.writeback, let base = memory.base { changed.insert(base) }
            return changed
        }
        return nil
    }
}
