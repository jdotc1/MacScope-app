import Foundation
@testable import MacScope

/// C2 measures displayed data flow, using an independently constructed machine graph.
/// Unavailable machine semantics are coverage refusals, never a zero-defect result.
enum C2DataflowCensus {
    struct Finding: Codable, Hashable {
        let function: String
        let start: UInt64
        let kind: String
        let variable: String
        let line: String
        let useAddress: UInt64
        let definitionAddress: UInt64
        let reachingDefinitions: [UInt64]
        let controlAddresses: [UInt64]

        var csvRow: String {
            [function, hex(start), kind, variable, line, hex(useAddress), hex(definitionAddress),
             reachingDefinitions.map(hex).joined(separator: ";"),
             controlAddresses.map(hex).joined(separator: ";")].map(csv).joined(separator: ",")
        }
    }

    /// Diagnostic IDs use native MacIRValue equality, never displayed spelling.
    /// Their scope is this function snapshot; diagnosticText is explanatory only.
    struct PhiNativeValue: Codable, Equatable {
        let id: Int
        let diagnosticText: String
        let displayName: String
    }
    struct PhiPrintedLine: Codable, Equatable {
        let number: Int
        let text: String
    }
    struct PhiIncomingDiagnostic: Codable, Equatable {
        let predecessorAddress: UInt64?
        let predecessorKind: String?
        let valueID: Int
        let matchingSyntheticEdgeLineSeen: Bool
        let matchingSyntheticDestinationAssignmentSeen: Bool
        let censusCopyRequirementSatisfied: Bool
        let matchingSyntheticLines: [PhiPrintedLine]
    }
    struct PhiEdgeDiagnostic: Codable, Equatable {
        let functionStart: UInt64
        let ssaEnabled: Bool
        let phiIndex: Int?
        let joinAddress: UInt64
        let cell: Int?
        let predecessorAddress: UInt64?
        let predecessorKind: String?
        let destinationValueID: Int
        let incomingValueID: Int
        let allIncoming: [PhiIncomingDiagnostic]
        let values: [PhiNativeValue]
        let sameDisplayValueIDs: [Int]
        let destinationDefinitionAddresses: [UInt64]
        let destinationUseAddresses: [UInt64]
        let retainedByComparisonPresentation: Bool
        let matchingSyntheticEdgeLineSeen: Bool
        let matchingSyntheticDestinationAssignmentSeen: Bool
        let censusCopyRequirementSatisfied: Bool
        let matchingSyntheticLines: [PhiPrintedLine]
    }

    /// Observe the already-rendered document; do not print, rebuild a graph, or
    /// change admission. The exact phi/incoming are supplied by the refusing loop.
    /// The presentation liveness bit uses the same comparison projection and phi
    /// filter as the printer, not a displayed-name guess.
    static func phiEdgeDiagnostic(function: MacIRFunction, document: PseudocodeDocument,
                                  printer: PseudocodePrinter, names: PseudocodeNameContext,
                                  phi: MacIRPhi, incoming: MacIRPhi.Incoming) -> PhiEdgeDiagnostic {
        var nativeValues: [MacIRValue] = []
        var ids: [MacIRValue: Int] = [:]
        @discardableResult func intern(_ value: MacIRValue) -> Int {
            if let id = ids[value] { return id }
            let id = nativeValues.count
            ids[value] = id
            nativeValues.append(value)
            return id
        }
        func collect(_ value: MacIRValue) {
            intern(value)
            for leaf in leaves(value) { intern(leaf) }
        }
        // Fixed source order gives stable IDs without serializing hash values or
        // iterating a Set/Dictionary. Equal native values share an ID across roles.
        for candidate in function.phis {
            collect(candidate.destination)
            for edge in candidate.incoming { collect(edge.value) }
        }
        var definitionAddresses: [UInt64] = []
        var useAddresses: [UInt64] = []
        for instruction in function.instructions {
            let effect = effects(instruction.operation)
            effect.definitions.forEach(collect)
            effect.uses.forEach { collect($0.value) }
            var inputs = effect.uses.map(\.value)
            // The census role table intentionally hides unknown inputs and
            // transfer targets; diagnostics retain these presentation roots too.
            switch instruction.operation {
            case let .unknown(_, operands, _, _):
                inputs += operands.mayRead.map(\.value) + operands.definiteRead.map(\.value)
            case let .conditionalBranch(_, _, _, target): inputs.append(target)
            case let .switchDispatch(_, cases, defaultTarget):
                inputs += cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
            default: break
            }
            inputs.forEach(collect)
            if let target = instruction.returnTarget { inputs.append(target); collect(target) }
            if let fp = instruction.fpEnvironment {
                let environment = [fp.left, fp.right, fp.numericResult,
                                   fp.fpcrInput, fp.fpsrInput, fp.fpsrOutput]
                inputs += environment
                environment.forEach(collect)
            }
            if effect.definitions.contains(phi.destination) {
                definitionAddresses.append(instruction.source.address)
            }
            if inputs.contains(where: { $0 == phi.destination || leaves($0).contains(phi.destination) }) {
                useAddresses.append(instruction.source.address)
            }
        }
        if let returned = function.returnValue { collect(returned) }
        for line in document.lines {
            if let edge = line.syntheticPhiEdge { collect(edge.destination) }
        }
        let destinationID = intern(phi.destination)
        let incomingID = intern(incoming.value)
        let destinationName = printer.valueText(for: phi.destination, names: names)
        let identity = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
            predecessor: incoming.predecessor, destination: phi.destination)
        func censusCopyRequirement(predecessor: MacIRPhiPredecessor) -> Bool {
            // This observational diagnostic cannot certify the virtual edge's
            // original binding and entry-phase proof; that audit is separate.
            guard predecessor != .functionEntry else { return false }
            let edge = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                predecessor: predecessor, destination: phi.destination)
            return document.lines.contains { line in
                guard line.kind == .instruction else { return false }
                let belongs = function.ssaEnabled
                    ? line.syntheticPhiEdge == edge : line.sourceAddress == predecessor.machineAddress
                guard belongs else { return false }
                let text = code(line.text)
                return function.ssaEnabled
                    ? text.contains("\(destinationName) = ")
                    : text.contains("\(destinationName) = __edge_")
            }
        }
        // Declarations and comments are not copies. A tagged label/snapshot is
        // recorded separately from the destination-assignment predicate.
        let matched = document.lines.filter { $0.kind == .instruction && $0.syntheticPhiEdge == identity }
        // Include non-refused incoming edges too: otherwise a partly emitted
        // join would lose the evidence on the sides that passed the census.
        // Materialize every value ID before freezing the value table.
        let allIncoming = phi.incoming.map { edge -> PhiIncomingDiagnostic in
            let edgeID = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                predecessor: edge.predecessor, destination: phi.destination)
            let lines = document.lines.filter { $0.kind == .instruction && $0.syntheticPhiEdge == edgeID }
            return .init(predecessorAddress: edge.machineAddress,
                predecessorKind: edge.predecessor == .functionEntry ? "functionEntry" : "machine", valueID: intern(edge.value),
                matchingSyntheticEdgeLineSeen: !lines.isEmpty,
                matchingSyntheticDestinationAssignmentSeen: lines.contains {
                    code($0.text).contains("\(destinationName) = ")
                }, censusCopyRequirementSatisfied: censusCopyRequirement(predecessor: edge.predecessor),
                matchingSyntheticLines: lines.map { .init(number: $0.lineNumber, text: $0.text) })
        }
        let values = nativeValues.enumerated().map { id, value in
            PhiNativeValue(id: id, diagnosticText: String(reflecting: value),
                displayName: printer.valueText(for: value, names: names))
        }
        let presentation = PseudocodePrinter.ssaComparisonPresentation(of: function)
        return .init(functionStart: function.startAddress, ssaEnabled: function.ssaEnabled,
            phiIndex: function.phis.firstIndex(of: phi), joinAddress: phi.blockAddress,
            cell: phi.cell, predecessorAddress: incoming.machineAddress,
            predecessorKind: incoming.predecessor == .functionEntry ? "functionEntry" : "machine",
            destinationValueID: destinationID, incomingValueID: incomingID, allIncoming: allIncoming, values: values,
            sameDisplayValueIDs: values.filter { $0.displayName == destinationName }.map(\.id),
            destinationDefinitionAddresses: definitionAddresses, destinationUseAddresses: useAddresses,
            retainedByComparisonPresentation: PseudocodePrinter.presentationPhis(presentation).contains(phi),
            matchingSyntheticEdgeLineSeen: !matched.isEmpty,
            matchingSyntheticDestinationAssignmentSeen: matched.contains {
                code($0.text).contains("\(destinationName) = ")
            }, censusCopyRequirementSatisfied: censusCopyRequirement(predecessor: incoming.predecessor),
            matchingSyntheticLines: matched.map { .init(number: $0.lineNumber, text: $0.text) })
    }

    // Diagnostic vocabulary, not admission predicates. Reserved categories do not
    // imply that an extension terminal currently emits them. Pre-extension failures
    // remain oldGateFailed; guardID retains the original failing gate separately.
    enum GuardedConjunct: String, Codable, CaseIterable {
        case reachingNZCVNotUnique = "reaching-NZCV-not-unique"
        case producerNotDominating = "producer-not-dominating"
        case armDefinitionAmbiguous = "arm-definition-ambiguous"
        case registerViewMismatch = "register-view-mismatch"
        case cyclicGraph = "cyclic-graph"
        case unsupportedShape = "unsupported-shape"
        case oldGateFailed = "old-gate-failed"

        var reason: String { "guarded select arm needs path-predicate proof: " + rawValue }

        init?(reason: String) {
            let prefix = "guarded select arm needs path-predicate proof: "
            guard reason.hasPrefix(prefix) else { return nil }
            self.init(rawValue: String(reason.dropFirst(prefix.count)))
        }
    }

    struct GuardedFailure: Codable, Equatable {
        let conjunct: GuardedConjunct
        let guardID: String
        let sourceFile: String
        let sourceLine: Int
    }

    struct RefusalDetail: Codable, Equatable {
        let reason: String
        let instructionAddress: UInt64?
        let mnemonic: String?
        let register: String?
        let valueName: String?
        let displayedLineNumber: Int?
        var phiEdgeDiagnostic: PhiEdgeDiagnostic? = nil
        var guardedFailure: GuardedFailure? = nil
    }

    struct Analysis {
        var rows: [Finding]
        var skippedReason: String?
        var refusalDetails: [RefusalDetail]
        var indirectBranchSites: [UInt64]
        var detectorSkippedReason: String? = nil
        var lifterRefusals: [MacIRRefusal] = []
    }

    static let entryBackedgeReason = "entry block has an in-graph predecessor"

    /// Keep producer refusals and the detector's independent coverage limits distinct.
    /// A refused entry backedge deliberately has no printed annotation.
    static func lifterRefusalClass(_ refusal: MacIRRefusal) -> String {
        if refusal.scope == .function, refusal.detail == entryBackedgeReason {
            return entryBackedgeReason
        }
        return "lifter " + refusal.reason.rawValue
    }

    static func lifterRefusals(in function: MacIRFunction) -> [MacIRRefusal] {
        let entryRefusals = function.refusals.filter {
            $0.scope == .function && $0.detail == entryBackedgeReason
        }
        guard function.ssaEnabled || !entryRefusals.isEmpty else { return [] }
        var refusals = function.refusals
        var seen = Set(refusals)
        let functionReasons = Set(refusals.filter { $0.scope == .function }.map(\.reason))
        let coveredRows = Set(refusals.compactMap { refusal -> MacIRRefusal? in
            switch refusal.scope {
            case let .row(address), let .cell(_, address):
                return .init(reason: refusal.reason, scope: .row(address), detail: nil)
            default: return nil
            }
        })
        if let info = function.ssaInfo {
            for definition in info.plan.definitions {
                guard case let .refusal(reason, address) = definition.origin else { continue }
                guard !functionReasons.contains(reason),
                      !coveredRows.contains(.init(reason: reason, scope: .row(address), detail: nil)) else { continue }
                let refusal = MacIRRefusal(reason: reason,
                    scope: .cell(definition.cell, address), detail: nil)
                if seen.insert(refusal).inserted { refusals.append(refusal) }
            }
        }
        return refusals
    }

    static let csvHeader = "function,start,kind,printed_variable,printed_line,use_address,printed_definition_address,machine_reaching_definitions,loop_or_join_addresses"

    private enum Role { case ordinary, flags, guarded, callArgument, projection }
    private struct Use {
        var value: MacIRValue
        var role: Role = .ordinary
    }
    private struct Effects {
        var definitions: [MacIRValue] = []
        var uses: [Use] = []
    }

    static func analyze(function: MacIRFunction, document: PseudocodeDocument,
                        machine: [MacIRSourceSpan], printer: PseudocodePrinter,
                        names: PseudocodeNameContext, ssaAccountingEnabled: Bool = false) -> Analysis {
        let effectsByInstruction = function.instructions.map { effects($0.operation) }
        let partialBank = Set((8...15).map { "v\($0)" })
        func isDOnlyValue(_ value: MacIRValue) -> Bool {
            switch value {
            case let .register(name, _):
                guard let bank = C2MachineFlow.canonicalRegister(name), partialBank.contains(bank) else { return true }
                return name == "d" + bank.dropFirst()
            case let .argument(binding):
                if case .simd = binding.kind { return !(8...15).contains(binding.value) }
                return true
            default:
                // Unproven wrappers, fragments and composites cannot grant a bank
                // projection. This deliberately prefers refusal to width inference.
                return leaves(value).allSatisfy { leaf in
                    switch leaf {
                    case let .register(name, _):
                        return C2MachineFlow.canonicalRegister(name).map { !partialBank.contains($0) } ?? true
                    case let .argument(binding):
                        if case .simd = binding.kind { return !(8...15).contains(binding.value) }
                        return true
                    case .argumentFragment: return false
                    default: return true
                    }
                }
            }
        }
        func isLow64Read(_ value: MacIRValue) -> Bool {
            if case let .unary(op, inner) = value {
                if ["__bitcast_f64", "__ssa_bitcast_f64"].contains(op) {
                    return isLow64Read(inner)
                }
                if ["__low64", "__ssa_low64"].contains(op),
                   case let .register(name, _) = inner,
                   let bank = C2MachineFlow.canonicalRegister(name), partialBank.contains(bank) {
                    // The explicit low-slice operator, not the v spelling, supplies
                    // width. A raw vector or a high-slice operator still refuses.
                    return name == bank || name == "d" + bank.dropFirst()
                }
            }
            return isDOnlyValue(value)
        }
        let dOnlyIR = zip(function.instructions, effectsByInstruction).allSatisfy { instruction, effect in
            guard effect.definitions.allSatisfy(isDOnlyValue) else { return false }
            return effect.uses.allSatisfy { use in
                if use.role == .projection {
                    // Effects intentionally strip the operator for reaching queries;
                    // recover it from the original assignment before granting width.
                    guard case let .assign(_, source) = instruction.operation else { return false }
                    return isLow64Read(source)
                }
                return isLow64Read(use.value)
            }
        } && function.phis.allSatisfy { phi in
            guard isDOnlyValue(phi.destination), phi.incoming.allSatisfy({ isLow64Read($0.value) }) else { return false }
            let values = [phi.destination] + phi.incoming.map(\.value)
            let touchesBank = values.flatMap(leaves).contains { leaf in
                if case let .register(name, _) = leaf {
                    return C2MachineFlow.canonicalRegister(name).map { partialBank.contains($0) } ?? false
                }
                return false
            }
            return !touchesBank || phi.bitWidth == 64
        }
        let flow = C2MachineFlow(rows: machine, permitDOnlyCallProjection: dOnlyIR)
        let reportedLifterRefusals = ssaAccountingEnabled ? lifterRefusals(in: function) : []
        func analysis(rows: [Finding], detectorReason: String?, details: [RefusalDetail]) -> Analysis {
            let combined: String?
            if ssaAccountingEnabled {
                var allReasons = Set(reportedLifterRefusals.map(lifterRefusalClass))
                if let detectorReason { allReasons.insert(detectorReason) }
                combined = allReasons.isEmpty ? nil : allReasons.sorted().joined(separator: "; ")
            } else {
                combined = detectorReason
            }
            return Analysis(rows: rows, skippedReason: combined,
                refusalDetails: details, indirectBranchSites: flow.indirectBranchSites,
                detectorSkippedReason: detectorReason, lifterRefusals: reportedLifterRefusals)
        }
        func unboundRefusal(_ reason: String) -> Analysis {
            analysis(rows: [], detectorReason: reason,
                details: [RefusalDetail(reason: reason, instructionAddress: nil,
                    mnemonic: nil, register: nil, valueName: nil, displayedLineNumber: nil)])
        }
        if let error = flow.error { return unboundRefusal(error) }
        guard !machine.isEmpty else { return unboundRefusal("no machine instructions") }
        if function.phis.contains(where: { $0.incoming.contains { $0.predecessor == .functionEntry } }),
           !MacIRBuilder.hasBoundedEntryLoopProof(function) {
            return unboundRefusal("virtual phi lacks bounded entry-loop proof")
        }
        let indexByAddress = Dictionary(uniqueKeysWithValues: machine.enumerated().map { ($0.element.address, $0.offset) })
        let instructions = function.instructions
        // A proven tail transfer expands to call + return at one machine address.
        // Keep raw B control-only in the independent machine graph. Admit only
        // the matching call result at the later synthetic effect, never an input.
        let tailResultDefinitions = postTailCallResultDefinitions(function: function, machine: machine)
        // exact code bytes and original Unicode token membership; no iteration of caches.
        var codeByText: [[UInt8]: String] = [:]
        var identifiersByText: [[UInt8]: Set<String>] = [:]
        func cachedCode(_ text: String) -> String {
            let key = Array(text.utf8)
            if let cached = codeByText[key] { return cached }
            let result = code(text)
            codeByText[key] = result
            return result
        }
        func cachedIdentifiers(in text: String) -> Set<String> {
            let key = Array(text.utf8)
            if let cached = identifiersByText[key] { return cached }
            let result = Set(text.split {
                !$0.isLetter && !$0.isNumber && $0 != "_"
            }.map(String.init))
            identifiersByText[key] = result
            return result
        }
        func cachedContainsIdentifier(_ name: String, in text: String) -> Bool {
            !name.isEmpty && cachedIdentifiers(in: text).contains(name)
        }

        // cache only directly pure leaf names, with full typed identity plus raw spelling.
        // Immutable printer/names are the enclosing cache namespace; no cross-call reuse.
        var namesByValue: [NameCacheKey: String] = [:]
        func cachedName(_ value: MacIRValue) -> String {
            guard let key = nameCacheKey(value) else {
                return printer.valueText(for: value, names: names)
            }
            if let cached = namesByValue[key] { return cached }
            let result = printer.valueText(for: value, names: names)
            namesByValue[key] = result
            return result
        }

        // array ordinal identifies the complete frozen operation, not just its address.
        // Cache only assign/return/stack reads of eligible leaves; other operations retain every original call.
        var renderedByInstruction: [Int: String] = [:]
        func cachedOperation(at ordinal: Int) -> String {
            let operation = instructions[ordinal].operation
            let eligible: Bool
            switch operation {
            case let .assign(destination, source):
                eligible = nameCacheKey(destination) != nil && nameCacheKey(source) != nil
            case let .returnValue(value):
                eligible = value.map { nameCacheKey($0) != nil } ?? true
            case let .stackSlotRead(destination, slot, value):
                eligible = [destination, slot, value].allSatisfy { nameCacheKey($0) != nil }
            case let .stackSlotPairRead(a, slotA, valueA, b, slotB, valueB):
                eligible = [a, slotA, valueA, b, slotB, valueB].allSatisfy { nameCacheKey($0) != nil }
            default:
                eligible = false
            }
            guard eligible else { return printer.render(operation: operation, names: names) }
            if let cached = renderedByInstruction[ordinal] { return cached }
            let result = printer.render(operation: operation, names: names)
            renderedByInstruction[ordinal] = result
            return result
        }
        var definitions: [MacIRValue: UInt64] = [:]
        var ambiguousDefinitions = Set<MacIRValue>()
        for (instruction, effects) in zip(instructions, effectsByInstruction) {
            for definition in effects.definitions.flatMap(leaves) {
                if let old = definitions[definition], old != instruction.source.address {
                    ambiguousDefinitions.insert(definition)
                }
                definitions[definition] = instruction.source.address
            }
        }
        let phis = Dictionary(function.phis.map { ($0.destination, $0) }, uniquingKeysWith: { first, _ in first })
        let codeLines = document.lines.filter { $0.kind == .instruction }
        let linesByAddress = Dictionary(grouping: codeLines, by: { $0.sourceAddress })
        var linesByPhiEdge: [MacIRPhiEdgeIdentity: [PseudocodeLine]] = [:]
        var printedIdentifiers = Set<String>()
        // retain line order and membership, including duplicate lines.
        if function.ssaEnabled {
            for line in codeLines {
                if let edge = line.syntheticPhiEdge { linesByPhiEdge[edge, default: []].append(line) }
                printedIdentifiers.formUnion(cachedIdentifiers(in: cachedCode(line.text)))
            }
        }
        let forHeaders = codeLines.filter { cachedCode($0.text).trimmingCharacters(in: .whitespaces).hasPrefix("for (") }
        let printedLoops = loopRanges(document.lines)
        let machineLoops = flow.backedges.map { edge in
            (edge.from, edge.to, flow.naturalLoop(from: edge.from, to: edge.to))
        }
        var reasons = Set<String>()
        var refusalDetails: [RefusalDetail] = []
        var findings = Set<Finding>()

        // Name collisions can intentionally merge SSA identities. Such a display is not
        // proof of a stale variable merely because its underlying versions differ.
        // identical names, direct-first matching and ordered for-header filtering.
        var valuesByName: [String: Set<MacIRValue>] = [:]
        for value in Set(definitions.keys).union(phis.keys) {
            valuesByName[cachedName(value), default: []].insert(value)
        }

        func printedLines(for instruction: MacIRInstruction, ordinal: Int, value: MacIRValue) -> [PseudocodeLine] {
            let name = cachedName(value)
            let isIdentifier = name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\z"#,
                                          options: .regularExpression) != nil
            func matchesValue(in text: String) -> Bool {
                isIdentifier ? cachedContainsIdentifier(name, in: text) : text.contains(name)
            }
            let direct = (linesByAddress[instruction.source.address] ?? [])
                .filter { matchesValue(in: cachedCode($0.text)) }
            if !direct.isEmpty { return direct }
            // A for-header moves the original initializer and step into the header.
            // Match the complete typed operation, retaining its original use address.
            let rendered = cachedOperation(at: ordinal)
            return forHeaders.filter {
                cachedCode($0.text).contains(rendered) && matchesValue(in: cachedCode($0.text))
            }
        }

        func definition(of value: MacIRValue) -> UInt64? {
            if let address = definitions[value] { return address }
            switch value {
            case .argument: return 0
            case let .register(_, version) where version == 0: return 0
            default: return nil
            }
        }

        func physicalRegister(_ value: MacIRValue) -> String? {
            switch value {
            case let .register(name, _): return C2MachineFlow.canonicalRegister(name)
            case let .argument(binding):
                switch binding.kind {
                case .gpr: return "x\(binding.value)"
                case .simd: return "v\(binding.value)"
                case .entryStack: return nil
                }
            default: return nil
            }
        }

        func recordRefusal(_ reason: String, at index: Int?, value: MacIRValue? = nil,
                           line: PseudocodeLine? = nil, phiEdgeDiagnostic: PhiEdgeDiagnostic? = nil, guardedFailure: GuardedFailure? = nil) {
            let source = index.map { machine[$0] }
            refusalDetails.append(RefusalDetail(reason: reason, instructionAddress: source?.address,
                mnemonic: source?.mnemonic, register: value.flatMap(physicalRegister),
                valueName: value.map { cachedName($0) },
                displayedLineNumber: line?.lineNumber, phiEdgeDiagnostic: phiEdgeDiagnostic, guardedFailure: guardedFailure))
        }

        // Census-only immutable graph cache. Compute at most once per function,
        // and only if an exact guarded use needs the conditional extension.
        var cachedGuardedArmOrder: [Int]?
        var didComputeGuardedArmOrder = false
        func acyclicGuardedArmOrder() -> [Int]? {
            if didComputeGuardedArmOrder { return cachedGuardedArmOrder }
            didComputeGuardedArmOrder = true
            var indegree = Dictionary(uniqueKeysWithValues: flow.reachable.map { node in
                (node, flow.predecessors[node].filter { flow.reachable.contains($0) }.count)
            })
            var pending = flow.reachable.filter { indegree[$0] == 0 }.sorted()
            var order: [Int] = []
            while let node = pending.popLast() {
                order.append(node)
                for successor in flow.successors[node] where flow.reachable.contains(successor) {
                    indegree[successor, default: 0] -= 1
                    if indegree[successor] == 0 { pending.append(successor) }
                }
            }
            guard order.count == flow.reachable.count else { return nil }
            cachedGuardedArmOrder = order
            return order
        }

        // One all-path arm proof, extended in place. Machine operand text binds
        // shape only; reaching definitions and dominance below supply authority.
        // Arm 2025-12: CSEL/CSINC/CSINV/CSNEG Operation; CINC/CNEG ArmAlias;
        // CMP/SUBS, TST/ANDS/BICS Operation and ConditionHolds shared pseudocode.
        func guardedArmHasPathProof(_ instruction: MacIRInstruction, at index: Int,
                                    value: MacIRValue, register: String,
                                    conditionalAvailability: inout Bool,
                                    failure: inout GuardedFailure) -> Bool {
            // Stamp only an existing terminal failure, never a retained feasible
            // edge or a speculative all-path failure that the extension can recover.
            func refuse(_ conjunct: GuardedConjunct, _ guardID: String,
                        file: String = #fileID, line: Int = #line) -> Bool {
                failure = GuardedFailure(conjunct: conjunct, guardID: guardID,
                                         sourceFile: file, sourceLine: line)
                return false
            }
            func operands(_ source: MacIRSourceSpan) -> [String] {
                source.operands.lowercased().split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            }
            func width(_ spelling: String) -> Int? {
                guard let first = spelling.first, first == "w" || first == "x",
                      let number = Int(spelling.dropFirst()), (0...30).contains(number)
                else { return nil }
                return first == "w" ? 32 : 64
            }
            func immediate(_ spelling: String) -> Int64? {
                guard spelling.hasPrefix("#") else { return nil }
                let text = String(spelling.dropFirst())
                if text.hasPrefix("0x") {
                    return UInt64(text.dropFirst(2), radix: 16).map { Int64(bitPattern: $0) }
                }
                return Int64(text)
            }
            func available(_ operand: MacIRValue, register: String, at use: Int) -> Bool {
                guard phis[operand] == nil, !ambiguousDefinitions.contains(operand),
                      let address = definition(of: operand),
                      flow.before[use][register] == Set([address]) else { return false }
                if address == 0 { return true }
                guard let producer = indexByAddress[address], producer != use else { return false }
                return flow.dominates(producer, use)
            }
            // Admit an exact register view, not an arbitrary expression with a
            // matching leaf. A W truncation is explicit; no inferred X extension.
            func readLeaf(_ operand: MacIRValue, spelling: String) -> MacIRValue? {
                guard let bits = width(spelling),
                      let physical = C2MachineFlow.canonicalRegister(spelling) else { return nil }
                switch operand {
                case let .register(name, _) where name == spelling: return operand
                case let .argument(binding) where bits == 64:
                    if case .gpr = binding.kind, "x\(binding.value)" == physical { return operand }
                    return nil
                case let .unary(op, leaf) where bits == 32 && op == "(uint32_t)":
                    switch leaf {
                    case let .register(name, _) where name == physical || name == spelling: return leaf
                    case let .argument(binding):
                        if case .gpr = binding.kind, "x\(binding.value)" == physical { return leaf }
                        return nil
                    default: return nil
                    }
                default: return nil
                }
            }
            // Arm-only rule: an exact nested zero-extension can denote an X read
            // only when this very SSA definition was a modeled same-register W
            // immediate MOV. Arm AArch64 register semantics zero X[63:32] on a W
            // destination write. Later existing availability/path checks still
            // prove that definition reaches this arm; no predicate view is relaxed.
            func readArmLeaf(_ operand: MacIRValue, spelling: String) -> MacIRValue? {
                if let leaf = readLeaf(operand, spelling: spelling) { return leaf }
                guard width(spelling) == 64,
                      case let .unary(outer, inner) = operand, outer == "(uint64_t)",
                      case let .unary(projection, leaf) = inner, projection == "(uint32_t)",
                      case let .register(name, _) = leaf,
                      let physical = C2MachineFlow.canonicalRegister(spelling),
                      name == physical || name == "w" + String(physical.dropFirst()),
                      phis[leaf] == nil, !ambiguousDefinitions.contains(leaf),
                      let address = definitions[leaf], let producer = indexByAddress[address],
                      flow.writes[producer] == Set([physical]),
                      machine[producer].mnemonic.lowercased() == "mov" else { return nil }
                let writer = operands(machine[producer])
                guard writer.count == 2, writer[0] == "w" + String(physical.dropFirst()),
                      let literal = immediate(writer[1]), literal >= 0,
                      literal <= Int64(UInt32.max) else { return nil }
                return leaf
            }
            func matchesInput(_ operand: MacIRValue, spelling: String, bits: Int, at use: Int,
                              projectedLow32: Bool = false) -> Bool {
                if let number = immediate(spelling) { return operand == .immediate(number) }
                // Only an already-checked whole-operand int32/uint32 projection
                // makes the upper X bits irrelevant. Reuse exact W-view binding;
                // do not relax arm views, logical predicates or provenance.
                let view = projectedLow32 && bits == 32
                    ? MacIRValue.unary(op: "(uint32_t)", value: operand) : operand
                guard width(spelling) == bits,
                      let leaf = readLeaf(operand, spelling: spelling) ?? readLeaf(view, spelling: spelling),
                      let physical = physicalRegister(leaf), flow.reads[use].contains(physical)
                else { return false }
                return available(leaf, register: physical, at: use)
            }
            // Ordered predicates must carry interpretation explicitly. Plain '<'
            // does not distinguish signed LT from unsigned LO in native select IR.
            func unproject(_ operand: MacIRValue, bits: Int, signed: Bool?) -> MacIRValue? {
                guard let signed else { return operand }
                let cast = signed ? "(int\(bits)_t)" : "(uint\(bits)_t)"
                if case let .unary(op, inner) = operand, op == cast { return inner }
                if case let .immediate(number) = operand {
                    if signed {
                        if bits == 64 || (number >= Int64(Int32.min) && number <= Int64(Int32.max)) { return operand }
                    } else if number >= 0 && (bits == 64 || number <= Int64(UInt32.max)) { return operand }
                }
                return nil
            }
            guard case let .select(destination, condition, left, right, yes, no) = instruction.operation,
                  flow.reads[index].contains("nzcv"),
                  let flags = flow.before[index]["nzcv"], flags.count == 1,
                  let flagAddress = flags.first, let flagIndex = indexByAddress[flagAddress],
                  flagIndex != index, flow.dominates(flagIndex, index) else { return refuse(.oldGateFailed, "old.select-nzcv") }
            let mnemonic = machine[index].mnemonic.lowercased()
            let alias = mnemonic == "cinc" || mnemonic == "cneg"
            let canonical = mnemonic == "cinc" ? "csinc" : (mnemonic == "cneg" ? "csneg" : mnemonic)
            guard ["csel", "csinc", "csinv", "csneg"].contains(canonical) else { return refuse(.oldGateFailed, "old.select-mnemonic") }
            let selection = operands(machine[index])
            guard selection.count == (alias ? 3 : 4), let bits = width(selection[0]),
                  readLeaf(destination, spelling: selection[0]) != nil,
                  width(selection[1]) == bits,
                  alias || width(selection[2]) == bits else { return refuse(.oldGateFailed, "old.select-view") }
            let invert = ["eq":"ne", "ne":"eq", "lt":"ge", "ge":"lt", "le":"gt", "gt":"le",
                          "lo":"hs", "cc":"cs", "hs":"lo", "cs":"cc", "hi":"ls", "ls":"hi"]
            let spelledCondition = selection[selection.count - 1]
            guard let canonicalCondition = alias ? invert[spelledCondition] : Optional(spelledCondition) else { return refuse(.oldGateFailed, "old.alias-condition") }
            let relations = ["eq":"==", "ne":"!=", "lt":"<", "le":"<=", "gt":">", "ge":">=",
                             "lo":"<", "cc":"<", "hs":">=", "cs":">=", "hi":">", "ls":"<="]
            guard relations[canonicalCondition] == condition else { return refuse(.oldGateFailed, "old.condition-relation") }
            let signed: Bool? = ["lt", "le", "gt", "ge"].contains(canonicalCondition) ? true
                : (["lo", "cc", "hs", "cs", "hi", "ls"].contains(canonicalCondition) ? false : nil)
            let noRead: MacIRValue
            switch (canonical, no) {
            case ("csel", _): noRead = no
            case let ("csinc", .binaryExpression(op, operand, increment))
                where op == "+" && increment == .immediate(1): noRead = operand
            case let ("csinv", .unary(op, operand)) where op == "~": noRead = operand
            case let ("csneg", .unary(op, operand)) where op == "-": noRead = operand
            default: return refuse(.oldGateFailed, "old.false-arm-shape")
            }
            let noSpelling = alias ? selection[1] : selection[2]
            guard let yesLeaf = readArmLeaf(yes, spelling: selection[1])
            else { return refuse(.oldGateFailed, "old.arm-binding.yes-leaf") }
            guard let noLeaf = readArmLeaf(noRead, spelling: noSpelling)
            else { return refuse(.oldGateFailed, "old.arm-binding.no-leaf") }
            guard !alias || yes == noRead
            else { return refuse(.oldGateFailed, "old.arm-binding.alias-equal") }
            guard value == yesLeaf || value == noLeaf
            else { return refuse(.oldGateFailed, "old.arm-binding.value-member") }
            let producer = machine[flagIndex].mnemonic.lowercased()
            let producerOperands = operands(machine[flagIndex])
            let lhsSpelling: String
            let rhsSpelling: String
            switch producer {
            case "cmp", "tst":
                guard producerOperands.count == 2 else { return refuse(.oldGateFailed, "old.compare-operands") }
                lhsSpelling = producerOperands[0]; rhsSpelling = producerOperands[1]
            case "subs", "ands", "bics":
                guard producerOperands.count == 3,
                      width(producerOperands[0]) == bits || producerOperands[0] == (bits == 32 ? "wzr" : "xzr")
                else { return refuse(.oldGateFailed, "old.logical-operands") }
                lhsSpelling = producerOperands[1]; rhsSpelling = producerOperands[2]
            default: return refuse(.oldGateFailed, "old.flag-producer") // CCMP chains and unavailable producers remain refused.
            }
            guard width(lhsSpelling) == bits,
                  immediate(rhsSpelling) != nil || width(rhsSpelling) == bits,
                  let predicateLeft = unproject(left, bits: bits, signed: signed),
                  let predicateRight = unproject(right, bits: bits, signed: signed) else { return refuse(.oldGateFailed, "old.predicate-projection") }
            if producer == "cmp" || producer == "subs" {
                // unproject above checked BOTH complete ordered operands. CMP/SUBS
                // ConditionHolds compares low32 with the declared signedness; even
                // signed overflow is represented by N xor V, not a wide subtraction.
                let projectedLow32 = bits == 32 && signed != nil
                guard matchesInput(predicateLeft, spelling: lhsSpelling, bits: bits, at: flagIndex,
                                   projectedLow32: projectedLow32),
                      matchesInput(predicateRight, spelling: rhsSpelling, bits: bits, at: flagIndex,
                                   projectedLow32: projectedLow32)
                else { return refuse(.oldGateFailed, "old.compare-inputs") }
            } else {
                // Logical flag writers clear C and V. Signed comparison of the
                // width-correct logical result with zero is valid; unsigned
                // relational comparison is NOT the same condition and is refused.
                guard signed != false, predicateRight == .immediate(0),
                      producer != "bics" || immediate(rhsSpelling) == nil else { return refuse(.oldGateFailed, "old.logical-predicate") }
                if case let .bitTest(operand, bit) = predicateLeft {
                    guard producer == "tst", signed == nil, bit >= 0, bit < Int64(bits),
                          let mask = immediate(rhsSpelling), UInt64(bitPattern: mask) == UInt64(1) << UInt64(bit),
                          matchesInput(operand, spelling: lhsSpelling, bits: bits, at: flagIndex) else { return refuse(.oldGateFailed, "old.bit-test") }
                } else {
                    guard case let .binaryExpression(op, a, b) = predicateLeft, op == "&",
                          matchesInput(a, spelling: lhsSpelling, bits: bits, at: flagIndex) else { return refuse(.oldGateFailed, "old.logical-left") }
                    let logicalRight: MacIRValue
                    if producer == "bics" {
                        guard case let .unary(inversion, operand) = b, inversion == "~" else { return refuse(.oldGateFailed, "old.logical-inversion") }
                        logicalRight = operand
                    } else { logicalRight = b }
                    guard matchesInput(logicalRight, spelling: rhsSpelling, bits: bits, at: flagIndex) else { return refuse(.oldGateFailed, "old.logical-right") }
                }
            }
            // Census-only: keep the existing all-path proof unchanged. A conditional
            // proof below replaces only this use's unconditional dominance query.
            guard flow.reads[index].contains(register) else { return refuse(.oldGateFailed, "old.arm-machine-read") }
            if available(value, register: register, at: index) { return true }
            guard phis[value] == nil, !ambiguousDefinitions.contains(value),
                  (valuesByName[printer.valueText(for: value, names: names)]?.count ?? 0) <= 1
            else { return refuse(.armDefinitionAmbiguous, "extension.arm-identity") }
            guard let expected = definition(of: value)
            else { return refuse(.armDefinitionAmbiguous, "extension.arm-definition") }
            guard expected == 0 || indexByAddress[expected] != nil
            else { return refuse(.unsupportedShape, "extension.arm-producer-address") }

            func normalized(_ condition: String) -> String {
                condition == "cc" ? "lo" : (condition == "cs" ? "hs" : condition)
            }
            let selectedCondition = normalized(canonicalCondition)
            // No arithmetic inference: correlate only the very same NZCV definition
            // and condition (or its complement). Other branches retain both edges.
            func feasible(_ predecessor: Int, _ successor: Int, trueArm: Bool) -> Bool {
                let source = machine[predecessor]
                let mnemonic = source.mnemonic.lowercased()
                guard mnemonic.hasPrefix("b."),
                      flow.before[predecessor]["nzcv"] == Set([flagAddress]),
                      flow.reads[predecessor].contains("nzcv"),
                      predecessor != flagIndex, flow.dominates(flagIndex, predecessor)
                else { return true }
                let branchCondition = normalized(String(mnemonic.dropFirst(2)))
                let same = branchCondition == selectedCondition
                let opposite = invert[branchCondition].map(normalized) == selectedCondition
                guard same || opposite else { return true }
                let targetText = source.operands.trimmingCharacters(in: .whitespaces).lowercased()
                let digits = targetText.hasPrefix("0x") ? String(targetText.dropFirst(2)) : targetText
                guard let target = UInt64(digits, radix: 16),
                      let targetIndex = indexByAddress[target],
                      predecessor + 1 < machine.count,
                      targetIndex != predecessor + 1,
                      Set(flow.successors[predecessor]) == Set([targetIndex, predecessor + 1])
                else { return true }
                let taken = same ? trueArm : !trueArm
                return successor == (taken ? targetIndex : predecessor + 1)
            }
            // Repeated executions of one NZCV address are not one predicate value.
            guard let order = acyclicGuardedArmOrder() else { return refuse(.cyclicGraph, "extension.acyclic-order") }
            func proved(_ trueArm: Bool) -> Bool {
                var conditionalReachable = Set<Int>()
                var pending = [0]
                while let node = pending.popLast() {
                    guard conditionalReachable.insert(node).inserted else { continue }
                    pending.append(contentsOf: flow.successors[node].filter {
                        feasible(node, $0, trueArm: trueArm)
                    })
                }
                guard conditionalReachable.contains(index) else {
                    return refuse(.unsupportedShape, trueArm ? "extension.true-arm-reachable" : "extension.false-arm-reachable")
                }
                var safeBefore: [Int: Bool] = [:]
                for node in order where conditionalReachable.contains(node) {
                    let predecessors = flow.predecessors[node].filter {
                        conditionalReachable.contains($0) && feasible($0, node, trueArm: trueArm)
                    }
                    // Empty pruned paths are not proof. The entry value is an
                    // explicit obligation, not an assumed physical-register input.
                    if predecessors.isEmpty {
                        safeBefore[node] = node == 0 && expected == 0
                    } else {
                        safeBefore[node] = predecessors.allSatisfy { predecessor in
                            if flow.writes[predecessor].contains(register) {
                                return machine[predecessor].address == expected
                            }
                            return safeBefore[predecessor] == true
                        }
                    }
                }
                if safeBefore[index] == true { return true }
                return refuse(.armDefinitionAmbiguous, trueArm ? "extension.true-arm-definition" : "extension.false-arm-definition")
            }
            // A leaf shared by both arms must satisfy both polarities independently.
            guard (value != yesLeaf || proved(true)),
                  (value != noLeaf || proved(false)) else { return false }
            conditionalAvailability = true
            return true
        }

        func inspect(_ value: MacIRValue, at useIndex: Int, afterInstruction: Bool,
                     tailResultDefinition: Bool = false, printedLine: PseudocodeLine, edgeTarget: UInt64? = nil, functionEntry: Bool = false) {
            guard flow.reachable.contains(useIndex), let register = physicalRegister(value) else { return }
            let name = cachedName(value)
            guard !ambiguousDefinitions.contains(value), (valuesByName[name]?.count ?? 0) <= 1 else {
                reasons.insert("ambiguous displayed definition: \(name)")
                recordRefusal("ambiguous displayed definition: \(name)", at: useIndex, value: value, line: printedLine)
                return
            }
            if phis[value] != nil {
                // Every incoming value is audited separately at its selected edge below.
                return
            }
            guard let defAddress = definition(of: value) else {
                reasons.insert("missing SSA definition: \(name)")
                recordRefusal("missing SSA definition: \(name)", at: useIndex, value: value, line: printedLine)
                return
            }
            var reaching: Set<UInt64> = functionEntry ? [0] : (flow.before[useIndex][register] ?? [0])
            if afterInstruction, flow.writes[useIndex].contains(register) || tailResultDefinition {
                reaching = [machine[useIndex].address]
            }
            let defIndex = indexByAddress[defAddress]
            let dominates: Bool
            if defAddress == 0 {
                dominates = true
            } else if let defIndex {
                dominates = flow.dominates(defIndex, useIndex)
                    && (defIndex != useIndex || afterInstruction)
            } else {
                reasons.insert("SSA definition has no machine address: \(name)")
                recordRefusal("SSA definition has no machine address: \(name)", at: useIndex, value: value, line: printedLine)
                return
            }

            // J requires a sibling/bypassed definition, not merely another physical
            // register write while an intentional SSA snapshot remains live.
            if !dominates, reaching.contains(where: { $0 != defAddress }) {
                let joins = flow.joinDominators(of: useIndex).map { machine[$0].address }
                findings.insert(Finding(function: function.name, start: function.startAddress,
                    kind: "J", variable: name, line: printedLine.text,
                    useAddress: machine[useIndex].address, definitionAddress: defAddress,
                    reachingDefinitions: reaching.sorted(),
                    controlAddresses: edgeTarget.map { [$0] } ?? (joins.isEmpty ? [machine[useIndex].address] : joins)))
                return
            }

            // The external predecessor executes before the first machine row,
            // not inside a later iteration of the original entry-header loop.
            if functionEntry { return }
            for (backedge, header, loop) in machineLoops where loop.contains(useIndex) {
                // If this definition executes in the loop before this use, each iteration
                // recomputes the displayed variable. That ordinary SSA spelling is correct.
                if let defIndex, loop.contains(defIndex), dominates { continue }
                guard printedLoops.contains(where: { $0.contains(printedLine.lineNumber) }),
                      reaching.contains(where: { address in
                          guard address != defAddress, let index = indexByAddress[address] else { return false }
                          return loop.contains(index)
                      }) else { continue }
                // A generated phi has an explicit edge assignment into its destination;
                // it was handled above. Ordinary definitions use distinct displayed names.
                findings.insert(Finding(function: function.name, start: function.startAddress,
                    kind: "L", variable: name, line: printedLine.text,
                    useAddress: machine[useIndex].address, definitionAddress: defAddress,
                    reachingDefinitions: reaching.sorted(),
                    controlAddresses: [machine[header].address, machine[backedge].address]))
            }
        }

        // CCMP reads incoming NZCV to choose between subtraction flags and the
        // immediate fallback. A printed predicate may therefore read an earlier
        // CMP/CMN input, not an explicit operand of the final CCMP.
        // Follow architectural NZCV definitions, never a predicate's shape.
        func conditionalFlagInput(_ value: MacIRValue, register: String,
                                  finalProducer: Int, consumer: Int) -> Int? {
            guard case let .register(rawName, _) = value,
                  ["w", "x"].contains(String(rawName.prefix(1))),
                  !ambiguousDefinitions.contains(value), phis[value] == nil,
                  let valueDefinition = definition(of: value),
                  flow.dominates(finalProducer, consumer), finalProducer != consumer else { return nil }
            var current = finalProducer
            var visited = Set<Int>()
            while visited.insert(current).inserted {
                let row = machine[current]
                let operands = row.operands.lowercased().split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                // Only integer CCMP, whose conditional input is architecturally NZCV.
                // AL/NV are unconditional and cannot justify following old flags.
                guard row.mnemonic.lowercased() == "ccmp", operands.count == 4,
                      ["eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl", "vs", "vc",
                       "hi", "ls", "ge", "lt", "gt", "le"].contains(operands[3]),
                      flow.reads[current].contains("nzcv"),
                      let incoming = flow.before[current]["nzcv"], incoming.count == 1,
                      let address = incoming.first, let previous = indexByAddress[address],
                      previous != current, flow.dominates(previous, current) else { return nil }
                let producer = machine[previous].mnemonic.lowercased()
                // This is an input-origin proof only. No result projections,
                // copy substitution, truncation or signed/zero extension is inferred.
                let inputTokens = machine[previous].operands.lowercased().split(separator: ",")
                    .prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
                if ["cmp", "cmn", "ccmp"].contains(producer),
                   inputTokens.contains(rawName.lowercased()),
                   flow.reads[previous].contains(register),
                   flow.before[previous][register] == Set([valueDefinition]) {
                    if valueDefinition == 0 { return previous }
                    guard let definitionIndex = indexByAddress[valueDefinition],
                          definitionIndex != previous,
                          flow.dominates(definitionIndex, previous) else { return nil }
                    return previous
                }
                current = previous
            }
            return nil // Cyclic, unavailable or nonconditional flag provenance.
        }

        // zip enumeration preserves instruction/effect order and repeated uses.
        let callArgumentRegisters = Set((0...8).map { "x\($0)" } + (0...7).map { "v\($0)" })
        for (ordinal, pair) in zip(instructions, effectsByInstruction).enumerated() {
            let (instruction, effects) = pair
            guard let index = indexByAddress[instruction.source.address], flow.reachable.contains(index) else { continue }
            if case let .intrinsic(nil, intrinsic, arguments) = instruction.operation,
               !["compare", "save_pair", "restore_pair", "save_pair_writeback", "restore_pair_writeback",
                 "stack_alloc", "stack_free", "nop", "bti", "paciasp", "pacibsp", "autiasp", "autibsp", "xpaclri"].contains(intrinsic),
               intrinsic != "branch", !intrinsic.hasPrefix("branch_"),
               arguments.flatMap(leaves).contains(where: { physicalRegister($0) != nil }),
               !declaredIntrinsicOperandRoles(instruction) {
                reasons.insert("unsupported intrinsic operand roles: \(intrinsic)")
                recordRefusal("unsupported intrinsic operand roles: \(intrinsic)", at: index)
                continue
            }
            for use in effects.uses {
                for value in leaves(use.value) {
                    guard let register = physicalRegister(value) else {
                        switch value {
                        case let .unknown(name):
                            if let line = printedLines(for: instruction, ordinal: ordinal, value: value).first {
                                reasons.insert("unknown-use: \(name)")
                                recordRefusal("unknown-use: \(name)", at: index, value: value, line: line)
                            }
                        case .temporary, .argumentFragment:
                            if let line = printedLines(for: instruction, ordinal: ordinal, value: value).first {
                                reasons.insert("printed temporary or argument fragment has no physical-register mapping")
                                recordRefusal("printed temporary or argument fragment has no physical-register mapping",
                                    at: index, value: value, line: line)
                            }
                        case .immediate, .symbol, .stackSlot:
                            break // Literals and addresses are real values without register flow.
                        case .argument:
                            break // Only entry-stack bindings have no physical register above.
                        case .register:
                            break // Zero or noncanonical registers have no physical-register flow.
                        case .abiComposite, .bitTest, .unary, .binaryExpression, .signedBitfield:
                            break // leaves(_:) recursively expands composite values below.
                        }
                        continue
                    }
                    let lines = printedLines(for: instruction, ordinal: ordinal, value: value)
                    guard !lines.isEmpty else { continue } // Elided/hidden operands are not printed uses.
                    // Printed ABI arguments are reads before the call's clobbers.
                    // Control operands retain their independent machine-read evidence.
                    let machineReads = use.role == .callArgument
                        && (["bl", "blr"].contains(machine[index].mnemonic.lowercased())
                            || (instruction.source.tailCallEffect?.phase == .call
                                && tailResultDefinitions[instruction.source.address] != nil))
                        ? callArgumentRegisters : flow.reads[index]
                    // Census-only: a conditional arm proof discharges this exact leaf,
                    // not another arm or any ordinary use of the same SSA identity.
                    var conditionalAvailability = false
                    var guardedFailure = GuardedFailure(conjunct: .oldGateFailed,
                        guardID: "old.entry", sourceFile: #fileID, sourceLine: #line)
                    if use.role == .guarded,
                       !guardedArmHasPathProof(instruction, at: index, value: value, register: register,
                                              conditionalAvailability: &conditionalAvailability, failure: &guardedFailure) {
                        // Conditional-only availability still needs a path-sensitive proof;
                        // unsupported predicates and ambiguous producers remain refusals.
                        reasons.insert("guarded select arm needs path-predicate proof")
                        // Keep the function-level reason above unchanged. Exactly one
                        // detailed row replaces each original guarded refusal row.
                        recordRefusal(guardedFailure.conjunct.reason, at: index, value: value,
                                      line: lines.first, guardedFailure: guardedFailure)
                        // Observe this original refusal occurrence; do not retry its predicate.
                        C2ProofDiagnostics.guardedSink?(.init(sourceRow: index,
                            address: instruction.source.address, mnemonic: instruction.source.mnemonic,
                            operands: instruction.source.operands, value: value, file: #fileID, line: #line))
                        continue
                    }
                    if conditionalAvailability { continue }
                    var useIndex = index
                    var afterInstruction = false
                    let isTailResult: Bool
                    if case .returnValue = instruction.operation,
                       instruction.source.tailCallEffect?.phase == .returnAfterCall,
                       tailResultDefinitions[instruction.source.address] == value {
                        isTailResult = true
                        afterInstruction = true
                    } else { isTailResult = false }
                    if isTailResult {
                        // The paired call defines this exact result before this effect.
                    } else if use.role == .projection, definitions[value] == instruction.source.address,
                       flow.writes[index].contains(register) {
                        // A destination view reads the whole value produced by this
                        // instruction, after its write, rather than its machine inputs.
                        afterInstruction = true
                    } else if use.role == .flags && flow.reads[index].contains("nzcv") {
                        let flagDefinitions = flow.before[index]["nzcv"] ?? []
                        guard flagDefinitions.count == 1, let flagAddress = flagDefinitions.first,
                              let flagIndex = indexByAddress[flagAddress] else {
                            reasons.insert("predicate has multiple or unavailable flag producers")
                            recordRefusal("predicate has multiple or unavailable flag producers",
                                at: index, value: value, line: lines.first)
                            continue
                        }
                        // The predicate can restate either a flag-setting instruction's
                        // inputs (CMP/SUBS) or its result (ANDS). Respect that distinction.
                        useIndex = flagIndex
                        afterInstruction = definitions[value] == flagAddress
                        let direct = flow.reads[flagIndex].contains(register) ||
                            (afterInstruction && flow.writes[flagIndex].contains(register))
                        if !direct, let earlier = conditionalFlagInput(value, register: register,
                            finalProducer: flagIndex, consumer: index) {
                            useIndex = earlier
                            afterInstruction = false
                        }
                        guard direct || useIndex != flagIndex else {
                            reasons.insert("predicate operand provenance is not a direct flag-producer input")
                            recordRefusal("predicate operand provenance is not a direct flag-producer input",
                                at: flagIndex, value: value, line: lines.first)
                            continue
                        }
                    } else if !machineReads.contains(register)
                    && !(use.role == .callArgument && use.value == value
                         && (flow.before[index][register] ?? [0]) == Set([0])
                         && Self.isBoundTypedTailParameterRead(value, instruction: instruction,
                              machine: machine[index], function: function)) {
                        // A typed return names ABI result storage rather than RET's link
                        // target. Stack-value propagation is not machine-read evidence.
                        if case .returnValue = instruction.operation,
                           register == "x0" || register == "v0" {
                            // Evaluated at the return before any transfer.
                        } else {
                            reasons.insert("printed operand is not a direct machine read")
                            recordRefusal("printed operand is not a direct machine read", at: index, value: value, line: lines.first)
                            continue
                        }
                    }
                    for line in lines {
                        inspect(value, at: useIndex, afterInstruction: afterInstruction,
                            tailResultDefinition: isTailResult, printedLine: line)
                    }
                }
            }
        }

        // Audit the virtual predecessor independently of flow.before[0], whose
        // meet includes real backedges. No synthetic machine row is introduced.
        func auditFunctionEntry(_ phi: MacIRPhi, incoming: MacIRPhi.Incoming) {
            func refuse(_ reason: String) {
                reasons.insert(reason)
                recordRefusal(reason, at: 0, value: incoming.value,
                    phiEdgeDiagnostic: Self.phiEdgeDiagnostic(function: function, document: document,
                        printer: printer, names: names, phi: phi, incoming: incoming))
            }
            guard function.ssaEnabled, MacIRBuilder.hasBoundedEntryLoopProof(function),
                  phi.blockAddress == function.startAddress,
                  machine.first?.address == function.startAddress,
                  phi.incoming.filter({ $0.predecessor == .functionEntry }).count == 1,
                  let cell = phi.cell, (0...30).contains(cell),
                  let info = function.ssaInfo,
                  let planned = info.plan.phis.first(where: {
                      $0.cell == cell && info.values[$0.destination] == phi.destination
                  }),
                  let seed = planned.incoming.first(where: { $0.predecessor == .functionEntry }),
                  info.plan.definitions.indices.contains(seed.definition),
                  info.plan.definitions[seed.definition].cell == cell,
                  info.plan.definitions[seed.definition].origin == .entry,
                  let entryValue = info.values[seed.definition],
                  incoming.value == (info.plan.definitions[seed.definition].bitWidth == 32 && phi.bitWidth == 64
                      ? MacIRValue.unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: entryValue))
                      : entryValue),
                  !leaves(incoming.value).isEmpty,
                  leaves(incoming.value).allSatisfy({
                      definition(of: $0) == 0 && physicalRegister($0) == "x\(cell)"
                          && !ambiguousDefinitions.contains($0)
                  }) else {
                refuse("virtual phi lacks original same-cell entry binding proof"); return
            }
            let identity = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                predecessor: .functionEntry, destination: phi.destination)
            let edgeLines = linesByPhiEdge[identity] ?? []
            let destination = printer.valueText(for: phi.destination, names: names)
            let input = printer.valueText(for: incoming.value, names: names)
            let firstMachineLine = codeLines.filter { $0.sourceAddress != nil }.map(\.lineNumber).min()
            let assignments = edgeLines.filter {
                code($0.text).trimmingCharacters(in: .whitespaces).hasPrefix("\(destination) = ")
            }
            guard edgeLines.count == 2, assignments.count == 1,
                  let write = assignments.first, let firstMachineLine,
                  edgeLines.allSatisfy({ $0.lineNumber < firstMachineLine }),
                  let snapshotLine = edgeLines.first(where: { $0.lineNumber != write.lineNumber }),
                  snapshotLine.lineNumber < write.lineNumber else {
                refuse("virtual phi has no once-only pre-entry copy schedule"); return
            }
            let writeText = code(write.text).trimmingCharacters(in: .whitespaces)
            let prefix = "\(destination) = "
            guard writeText.hasSuffix(";") else {
                refuse("virtual phi destination assignment is not exact"); return
            }
            let snapshot = String(writeText.dropFirst(prefix.count).dropLast())
            guard snapshot.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil,
                  snapshot != destination else {
                refuse("virtual phi snapshot is not a distinct identifier"); return
            }
            let snapshotText = code(snapshotLine.text).trimmingCharacters(in: .whitespaces)
            let bare = "\(snapshot) = \(input);"
            let types = ["int\(phi.bitWidth)_t", "uint\(phi.bitWidth)_t"]
            let exactTypedSnapshot = types.contains { snapshotText == "\($0) \(bare)" }
            let exactDeclaredSnapshot = snapshotText == bare && document.lines.contains { line in
                line.kind == .declaration && line.syntheticPhiEdge == identity
                    && line.lineNumber < snapshotLine.lineNumber
                    && types.contains { code(line.text).trimmingCharacters(in: .whitespaces) == "\($0) \(snapshot);" }
            }
            // All entry snapshots must precede every entry destination write.
            let entryDestinations = Set(function.phis.filter {
                $0.incoming.contains { $0.predecessor == .functionEntry }
            }.map { printer.valueText(for: $0.destination, names: names) })
            let firstEntryWrite = codeLines.filter { line in
                guard line.syntheticPhiEdge?.predecessor == .functionEntry else { return false }
                let text = code(line.text).trimmingCharacters(in: .whitespaces)
                return entryDestinations.contains { text.hasPrefix("\($0) = ") }
            }.map(\.lineNumber).min()
            guard exactTypedSnapshot || exactDeclaredSnapshot,
                  let firstEntryWrite, snapshotLine.lineNumber < firstEntryWrite else {
                refuse("virtual phi lacks exact typed parallel entry snapshots"); return
            }
            for value in leaves(incoming.value) {
                inspect(value, at: 0, afterInstruction: false, printedLine: snapshotLine,
                    edgeTarget: phi.blockAddress, functionEntry: true)
            }
        }

        // Phi copies execute on their predecessor edge, after its terminating
        // instruction; all right-hand sides are snapshots before destinations change.
        for phi in function.phis {
            let destinationName = cachedName(phi.destination)
            if function.ssaEnabled, !printedIdentifiers.contains(destinationName) { continue }
            for incoming in phi.incoming {
                if incoming.predecessor == .functionEntry {
                    auditFunctionEntry(phi, incoming: incoming)
                    continue
                }
                guard let predecessorAddress = incoming.machineAddress,
                      let index = indexByAddress[predecessorAddress],
                      let target = indexByAddress[phi.blockAddress], flow.successors[index].contains(target) else {
                    reasons.insert("phi predecessor is not a machine edge to its join")
                    recordRefusal("phi predecessor is not a machine edge to its join",
                        at: incoming.machineAddress.flatMap { indexByAddress[$0] }, value: incoming.value)
                    continue
                }
                let identity = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                    predecessor: incoming.predecessor, destination: phi.destination)
                let edgeLines = function.ssaEnabled
                    ? linesByPhiEdge[identity] ?? []
                    : linesByAddress[predecessorAddress] ?? []
                guard edgeLines.contains(where: {
                    let text = cachedCode($0.text)
                    return function.ssaEnabled
                        ? text.contains("\(destinationName) = ")
                        : text.contains("\(destinationName) = __edge_")
                }) else {
                    reasons.insert("phi has no emitted predecessor edge copy")
                    recordRefusal("phi has no emitted predecessor edge copy", at: index, value: incoming.value,
                        phiEdgeDiagnostic: Self.phiEdgeDiagnostic(function: function, document: document,
                            printer: printer, names: names, phi: phi, incoming: incoming))
                    continue
                }
                for value in leaves(incoming.value) {
                    let name = cachedName(value)
                    guard let line = edgeLines.first(where: {
                        let text = cachedCode($0.text)
                        if function.ssaEnabled {
                            guard let assignment = text.range(of: " = ") else { return false }
                            return cachedContainsIdentifier(name, in: String(text[assignment.upperBound...]))
                        }
                        return text.contains("const ") && text.contains("__edge_") && cachedContainsIdentifier(name, in: text)
                    }) else { continue }
                    inspect(value, at: index, afterInstruction: true, printedLine: line, edgeTarget: phi.blockAddress)
                }
            }
        }
        let sorted = findings.sorted {
            ($0.useAddress, $0.kind, $0.variable, $0.definitionAddress, $0.line, $0.controlAddresses.description)
                < ($1.useAddress, $1.kind, $1.variable, $1.definitionAddress, $1.line, $1.controlAddresses.description)
        }
        return analysis(rows: sorted, detectorReason: reasons.isEmpty ? nil : reasons.sorted().joined(separator: "; "),
            details: refusalDetails)
    }

    /// Operand roles from A64 2025-12 CCMP (register/immediate), CCMN and
    /// ST2 (multiple structures), Operation sections. This declares reads;
    /// it does not certify a conditional predicate or remove later audits.
    private static func declaredIntrinsicOperandRoles(_ instruction: MacIRInstruction) -> Bool {
        guard case let .intrinsic(nil, name, arguments) = instruction.operation else { return false }
        let mnemonic = instruction.source.mnemonic.lowercased()
        if name.hasPrefix("conditional_compare_") {
            let operands = instruction.source.operands.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            let conditions: Set<String> = ["eq", "ne", "cs", "hs", "cc", "lo", "mi", "pl",
                                           "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"]
            guard ["ccmp", "ccmn"].contains(mnemonic), operands.count == 4,
                  conditions.contains(operands[3]), name == "conditional_compare_\(operands[3])",
                  arguments.count == 3, case let .immediate(nzcv) = arguments[2],
                  (0...15).contains(nzcv) else { return false }
            // Arguments 0 and 1 are comparison inputs; argument 2 is fallback
            // NZCV, not a register definition. Incoming flags are independently
            // audited through the flag-producer provenance path.
            return true
        }
        if name == "neon_structure_lane_store",
           let step = instruction.neonStructureLaneMemory,
           step.frame.effect == .store,
           mnemonic == "st\(step.frame.structureCount)",
           step.ordinal >= 0, step.ordinal < step.frame.structureCount,
           step.frame.matches(instruction.operation, ordinal: step.ordinal) {
            // Each selected-element payload reads captured oldBase and one
            // old physical vector. No vector is defined by a store. The
            // separately emitted assign owns any delayed base writeback.
            return true
        }
        if name == "neon_structure_store", mnemonic == "st2",
           let step = instruction.neonInterleavedMemory,
           step.frame.effect == .store, step.frame.structureCount == 2,
           step.ordinal >= 0, step.ordinal < step.frame.groupCount,
           step.frame.matches(instruction.operation, ordinal: step.ordinal) {
            // Typed store arguments are oldBase and the selected source vector.
            // Writeback is its own assign effect, never a destination here.
            return true
        }
        return false
    }

    /// Validate the ordered boundary against raw rows and the existing frame
    /// proof. The target identity certificate comes only from provenTailCalls;
    /// metadata alone, an arbitrary B, or a same-address ordinary call is not enough.
    static func postTailCallResultDefinitions(function: MacIRFunction,
                                              machine: [MacIRSourceSpan]) -> [UInt64: MacIRValue] {
        guard function.instructions.contains(where: { $0.source.tailCallEffect?.phase == .returnAfterCall }),
              !machine.isEmpty, Set(machine.map(\.address)).count == machine.count else { return [:] }
        let proofRows = machine.map { MacIRBuilder.TailCallParameterRow(address: $0.address,
            bytes: $0.byteText, mnemonic: $0.mnemonic, operands: $0.operands,
            comment: $0.comment, structuredOperands: $0.structuredOperands) }
        let effects = Dictionary(grouping: function.instructions, by: { $0.source.address })
        let switches = Set(function.instructions.compactMap { instruction -> UInt64? in
            if case .switchDispatch = instruction.operation { return instruction.source.address }
            return nil
        })
        var result: [UInt64: MacIRValue] = [:]
        for row in machine {
            guard row.mnemonic.lowercased() == "b", let pair = effects[row.address], pair.count == 2,
                  let call = pair.first, let returned = pair.last,
                  let callEffect = call.source.tailCallEffect, callEffect.phase == .call,
                  let returnEffect = returned.source.tailCallEffect, returnEffect.phase == .returnAfterCall,
                  callEffect.targetAddress == returnEffect.targetAddress,
                  callEffect.targetName == returnEffect.targetName,
                  call.source.mnemonic.lowercased() == "b", returned.source.mnemonic.lowercased() == "b",
                  call.source.operands == row.operands, returned.source.operands == row.operands,
                  MacIRTailCallProof.address(row.operands) == callEffect.targetAddress,
                  case let .call(frame, value?) = call.operation,
                  frame.controlInputs == .none, frame.target == callEffect.targetName,
                  case let .returnValue(returnValue?) = returned.operation,
                  leaves(returnValue).contains(value),
                  case let .register(name, _) = value,
                  let register = C2MachineFlow.canonicalRegister(name), ["x0", "v0"].contains(register) else { continue }
            if let operands = row.structuredOperands {
                guard operands.coverage == .complete, operands.operands.count == 1,
                      case let .pcRelative(reference) = operands.operands[0],
                      reference.target == callEffect.targetAddress else { continue }
            }
            // Recheck frame, duplicate-site and memory-sidecar gates on raw rows.
            // Discovered target identity remains the producer's certificate, not
            // a claim that machine instructions independently reveal symbols.
            guard MacIRBuilder.provenTailCalls(rows: proofRows, entry: function.startAddress,
                knownTargets: [callEffect.targetAddress: callEffect.targetName],
                recoveredSwitches: switches,
                pathCompleteEnabled: function.ssaEnabled && MacIRConfiguration.returnContractEnabled
            )[row.address]?.targetAddress == callEffect.targetAddress else { continue }
            result[row.address] = value
        }
        return result
    }

    private static func effects(_ operation: MacIROperation) -> Effects {
        func ordinary(_ values: [MacIRValue]) -> [Use] { values.map { Use(value: $0) } }
        switch operation {
        case let .assign(d, s):
            if case let .unary(name, value) = s,
               ["__low64", "__high64", "__ssa_low64", "__ssa_high64"].contains(name) {
                return Effects(definitions: [d], uses: [Use(value: value, role: .projection)])
            }
            return Effects(definitions: [d], uses: ordinary([s]))
        case let .binary(d, _, l, r): return Effects(definitions: [d], uses: ordinary([l, r]))
        case let .load(d, a): return Effects(definitions: [d], uses: ordinary([a]))
        case let .store(s, a): return Effects(uses: ordinary([s, a]))
        case let .loadWriteback(d, base, old, _, _): return Effects(definitions: [d, base], uses: ordinary([old]))
        case let .storeWriteback(s, base, old, _, _): return Effects(definitions: [base], uses: ordinary([s, old]))
        case let .stackSlotRead(d, slot, value): return Effects(definitions: [d], uses: ordinary([slot, value]))
        case let .stackSlotPairRead(a, slotA, valueA, b, slotB, valueB):
            return Effects(definitions: [a, b], uses: ordinary([slotA, valueA, slotB, valueB]))
        case let .call(frame, result):
            let controls = frame.controlInputs.bindingValues
            return Effects(definitions: result.map { [$0] } ?? [],
                uses: ordinary(controls) + frame.bindingValues.dropFirst(controls.count).map {
                    Use(value: $0, role: .callArgument)
                })
        case let .conditionalBranch(_, l, r, _): return Effects(uses: [Use(value: l, role: .flags), Use(value: r, role: .flags)])
        case let .select(d, _, l, r, yes, no):
            return Effects(definitions: [d], uses: [Use(value: l, role: .flags), Use(value: r, role: .flags),
                Use(value: yes, role: .guarded), Use(value: no, role: .guarded)])
        case let .compareToBool(d, _, l, r): return Effects(definitions: [d], uses: [Use(value: l, role: .flags), Use(value: r, role: .flags)])
        case let .returnValue(value): return Effects(uses: ordinary(value.map { [$0] } ?? []))
        case let .switchDispatch(index, _, _): return Effects(uses: ordinary([index]))
        case let .unknown(d, _, _, _): return Effects(definitions: d.map { [$0] } ?? []) // inputs are deliberately not printed
        case let .intrinsic(d, name, arguments):
            switch name {
            case "restore_pair": return Effects(definitions: Array(arguments.prefix(2)), uses: ordinary(Array(arguments.dropFirst(2))))
            case "restore_pair_writeback" where arguments.count == 6:
                return Effects(definitions: [arguments[0], arguments[1], arguments[3]], uses: ordinary([arguments[2]]))
            case "save_pair_writeback" where arguments.count == 6:
                return Effects(definitions: [arguments[3]], uses: ordinary(Array(arguments.prefix(3))))
            default: return Effects(definitions: d.map { [$0] } ?? [], uses: ordinary(arguments))
            }
        }
    }

    /// A retained SSA tail certificate can establish the ABI read that the
    /// original B spelling does not enumerate. Names never supply identity.
    /// This admits only an unchanged whole formal argument in the same GPR view.
    static func isBoundTypedTailParameterRead(
        _ value: MacIRValue, instruction: MacIRInstruction,
        machine: MacIRSourceSpan, function: MacIRFunction
    ) -> Bool {
        guard function.ssaEnabled, function.returnType == "void", !function.isVariadic,
              machine.tailCallEffect == nil, machine.mnemonic.lowercased() == "b",
              case let .argument(binding) = value, binding.kind == .gpr,
              case let .call(frame, result) = instruction.operation, result == nil,
              let signature = frame.knownSignature, signature.target == frame.target,
              signature.returnsVoid, !signature.isVariadic,
              frame.controlInputs == .none, frame.typedIndirectSignature == nil,
              frame.richArguments == nil, frame.indirectResultPointer == nil,
              let argument = frame.arguments.argument(at: .gpr(index: binding.value)),
              argument.value == value, case let .fixed(position) = argument.role,
              case let .gpr(index, width) = argument.location, index == binding.value,
              let info = function.ssaInfo, let original = function.ssaOriginalInstructions,
              original.contains(instruction), let graph = function.cfg else { return false }
        let callPhase = instruction.source.tailCallEffect
        var rawCallSource = instruction.source
        rawCallSource.tailCallEffect = nil
        guard rawCallSource == machine else { return false }
        if let callPhase {
            guard callPhase.phase == .call, callPhase.targetName == frame.target,
                  MacIRTailCallProof.address(machine.operands) == callPhase.targetAddress
            else { return false }
        }
        let parameters = function.parameters.filter { $0.bindingID == binding }
        let callParameters = signature.parameters.filter { $0.index == position }
        guard parameters.count == 1, callParameters.count == 1,
              case let .gpr(formalIndex, formalWidth) = parameters[0].abiLocation,
              formalIndex == index, formalWidth == width,
              MacIRCallArgumentLocation(register: callParameters[0].register) == argument.location
        else { return false }

        // Preserve the actual entry definition, not merely a same-spelled formal.
        let sourceRows = info.sourceAddresses.indices.filter { info.sourceAddresses[$0] == machine.address }
        guard sourceRows.count == 1, let row = sourceRows.first,
              info.plan.rowReadBindings.indices.contains(row),
              let read = info.plan.rowReadBindings[row][index],
              info.plan.definitions.indices.contains(read) else { return false }
        let definition = info.plan.canonicalID(read)
        guard info.plan.definitions.indices.contains(definition),
              info.plan.definitions[definition].cell == index,
              info.plan.definitions[definition].bitWidth == width,
              info.plan.definitions[definition].view == .integer,
              info.plan.definitions[definition].origin == .entry,
              info.values[definition] == value else { return false }

        // Only the retained product-proven tail terminator is authority here;
        // a B with call-shaped text or an ordinary external edge is insufficient.
        let callIndices = function.instructions.indices.filter { function.instructions[$0] == instruction }
        guard callIndices.count == 1, let callIndex = callIndices.first else { return false }
        let blocks = graph.blocks.filter { $0.instructionRange.contains(callIndex) }
        guard blocks.count == 1, let block = blocks.first,
              graph.terminators.indices.contains(block.index),
              case let .tail(target) = graph.terminators[block.index],
              block.successors == [.init(from: block.index, to: nil, kind: .tail, label: nil)],
              let last = block.instructionRange.last, function.instructions.indices.contains(last),
              function.instructions[last].operation == .returnValue(nil) else { return false }
        var rawReturnSource = function.instructions[last].source
        switch (callPhase, rawReturnSource.tailCallEffect) {
        case (nil, nil):
            break
        case let (.some(call), .some(returned)):
            guard returned.phase == .returnAfterCall,
                  returned.targetAddress == call.targetAddress,
                  returned.targetName == call.targetName else { return false }
        default:
            return false
        }
        rawReturnSource.tailCallEffect = nil
        guard rawReturnSource == machine else { return false }
        let operands = MacIRBuilder.splitOperands(machine.operands)
        guard operands.count == 1 else { return false }
        // Use the same numeric-only parser as the retained product certificate.
        // It accepts the product's optional # prefix, never a symbol/display name.
        return MacIRTailCallProof.address(operands[0]) == target
    }

    // typed identity never merges different UTF-8 spellings of equivalent Unicode.
    private struct NameCacheKey: Hashable {
        let value: MacIRValue
        let spelling: [UInt8]
    }

    private static func nameCacheKey(_ value: MacIRValue) -> NameCacheKey? {
        switch value {
        case let .register(name, _), let .symbol(name), let .unknown(name):
            return NameCacheKey(value: value, spelling: Array(name.utf8))
        case .argument, .immediate, .stackSlot, .temporary:
            return NameCacheKey(value: value, spelling: [])
        default:
            return nil
        }
    }

    // identical depth-first left-to-right leaf sequence, including every duplicate.
    // the unchanged signed-bitfield source. This traversal invokes no printer at all.
    // No leaf sorting, deduplication or name substitution.
    private static func leaves(_ value: MacIRValue) -> [MacIRValue] {
        var result: [MacIRValue] = []
        func appendLeaves(_ value: MacIRValue) {
            switch value {
            case let .signedBitfield(field): appendLeaves(field.source)
            case let .unary(_, inner), let .bitTest(inner, _): appendLeaves(inner)
            case let .binaryExpression(_, left, right):
                appendLeaves(left)
                appendLeaves(right)
            case let .abiComposite(_, fragments):
                for fragment in fragments { appendLeaves(fragment) }
            default: result.append(value)
            }
        }
        appendLeaves(value)
        return result
    }

    /// Only presentation structure is read from text; all values and def sites come from IR.
    private static func loopRanges(_ lines: [PseudocodeLine]) -> [ClosedRange<Int>] {
        var scopes: [(start: Int, loop: Bool)] = []
        var result: [ClosedRange<Int>] = []
        var labels: [String: Int] = [:]
        let labelPattern = try! NSRegularExpression(pattern: #"^\s*([A-Za-z_][A-Za-z_0-9]*|0x[0-9a-fA-F]+):\s*$"#)
        let gotoPattern = try! NSRegularExpression(pattern: #"\bgoto\s+([A-Za-z_][A-Za-z_0-9]*|0x[0-9a-fA-F]+)\s*;"#)
        for line in lines {
            let text = code(line.text).trimmingCharacters(in: .whitespaces)
            let range = NSRange(text.startIndex..., in: text)
            if let match = labelPattern.firstMatch(in: text, range: range), let nameRange = Range(match.range(at: 1), in: text) {
                labels[String(text[nameRange])] = line.lineNumber
            }
            for match in gotoPattern.matches(in: text, range: range) {
                if let nameRange = Range(match.range(at: 1), in: text), let start = labels[String(text[nameRange])], start < line.lineNumber {
                    result.append(start...line.lineNumber)
                }
            }
            let isLoop = text.hasPrefix("do {") || text.hasPrefix("while (") || text.hasPrefix("for (")
            // Strings and comments may contain braces (notably __unknown operands).
            // They are excluded before scanning scope delimiters.
            var quoted = false, escaped = false
            for character in text {
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                    continue
                }
                if character == "\"" { quoted = true; continue }
                if character == "}", let scope = scopes.popLast(), scope.loop {
                    result.append(scope.start...line.lineNumber)
                }
                if character == "{" { scopes.append((line.lineNumber, isLoop)) }
            }
        }
        return result
    }

    private static func code(_ text: String) -> String {
        // Printer annotations use //; no semantic facts are inferred from them.
        text.components(separatedBy: " // ").first ?? text
    }
    private static func containsIdentifier(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains { $0 == name }
    }
    private static func hex(_ address: UInt64) -> String { "0x" + String(address, radix: 16) }
    private static func csv(_ field: String) -> String { "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

// Test-target serialization only. These observations never feed census admission.
// Preserve occurrence order and original value identities, not rendered spellings.
enum C2ProofDiagnostics {
    typealias Object = [String: Any]
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RejectedCFGDiagnostics.Event] = []
        private var phases: [String] = []
        private var refusals: [GuardedRefusal] = []
        func appendGuarded(_ refusal: GuardedRefusal) {
            lock.lock(); defer { lock.unlock() }
            refusals.append(refusal)
        }
        func guarded() -> [GuardedRefusal] {
            lock.lock(); defer { lock.unlock() }
            return refusals
        }
        func ledger() -> [Object] {
            lock.lock(); let copy = events; let copiedPhases = phases; lock.unlock()
            var builds: [String] = []
            var physical: [String] = []
            var ordinaryProofs: [String] = []
            var planners: [String] = []
            var nativeProofs: [String] = []
            var nativePlanners: [String] = []
            var classifications: [String] = []
            var rows: [String: Object] = [:]
            return copy.enumerated().map { index, captured in
                var record = C2ProofDiagnostics.event(captured)
                record["sequence"] = index
                record["phase"] = copiedPhases[index]
                // Begin belongs to the newly entered context; end still belongs
                // to that context, never to its parent after the pop.
                switch captured {
                case let .buildBegin(id, _, _): builds.append(id.uuidString)
                case let .physicalAttempt(id, _, _, _, _, _, _, _, _): physical.append(id.uuidString)
                case let .ordinaryProofBegin(id, _, _, _): ordinaryProofs.append(id.uuidString)
                case let .ordinaryAttempt(id, _, _, _, _, _): planners.append(id.uuidString)
                case let .nativeProofBegin(id, _, _, _): nativeProofs.append(id.uuidString)
                case let .nativeAttempt(id, _, _, _, _, _, _, _, _, _): nativePlanners.append(id.uuidString)
                case let .classificationBegin(id, _, _): classifications.append(id.uuidString)
                case let .rowBegin(id, row, address): rows[id.uuidString] = ["row": row, "address": C2ProofDiagnostics.hex(address)]
                default: break
                }
                record["owningBuildID"] = builds.last.map { $0 as Any }
                record["owningPhysicalAttemptID"] = physical.last.map { $0 as Any }
                record["owningOrdinaryProofID"] = ordinaryProofs.last.map { $0 as Any }
                record["owningOrdinaryPlannerID"] = planners.last.map { $0 as Any }
                record["owningNativeProofID"] = nativeProofs.last.map { $0 as Any }
                record["owningNativePlannerID"] = nativePlanners.last.map { $0 as Any }
                record["owningClassificationID"] = classifications.last.map { $0 as Any }
                if let build = builds.last {
                    record["owningRow"] = rows[build].map { $0 as Any } ?? NSNull()
                } else { record["contextStatus"] = "no-build-context" }
                func pop(_ id: UUID, _ stack: inout [String], _ kind: String) {
                    if stack.last == id.uuidString { stack.removeLast() }
                    else { record["contextStatus"] = "unbalanced-" + kind }
                }
                switch captured {
                case let .buildEnd(id): pop(id, &builds, "build"); rows.removeValue(forKey: id.uuidString)
                case let .physicalEnd(id, _): pop(id, &physical, "physical")
                case let .ordinaryProofEnd(id, _): pop(id, &ordinaryProofs, "ordinary-proof")
                case let .ordinaryFacts(id, _, _, _, _, _, _, _, _): pop(id, &planners, "ordinary-planner")
                case let .nativeProofEnd(id, _): pop(id, &nativeProofs, "native-proof")
                case let .nativeFacts(id, _, _, _, _, _, _, _): pop(id, &nativePlanners, "native-planner")
                case let .classificationEnd(id, _): pop(id, &classifications, "classification")
                case let .rowEnd(id, _): rows.removeValue(forKey: id.uuidString)
                default: break
                }
                return record
            }
        }
        func append(_ event: RejectedCFGDiagnostics.Event) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
            phases.append(C2ProofDiagnostics.phase)
        }
        func captured() -> [RejectedCFGDiagnostics.Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    static func hex(_ address: UInt64) -> String { "0x" + String(address, radix: 16) }
    static func binding(_ binding: MacIRParameterBindingID) -> Object {
        let kind: String
        switch binding.kind {
        case .gpr: kind = "gpr"
        case .simd: kind = "simd"
        case .entryStack: kind = "entryStack"
        }
        return ["kind": kind, "value": binding.value]
    }
    static func value(_ value: MacIRValue, depth: Int = 0) -> Object {
        guard depth < 128 else { return ["tag": "captureIncomplete", "reason": "value-depth-limit"] }
        switch value {
        case let .register(name, version): return ["tag": "register", "name": name, "version": version]
        case let .argument(id): return ["tag": "argument", "binding": binding(id)]
        case let .argumentFragment(row, offset, size):
            return ["tag": "argumentFragment", "rowID": row.rawValue, "byteOffset": offset, "size": size]
        case let .abiComposite(type, fragments):
            return ["tag": "abiComposite", "type": type, "fragments": fragments.map { self.value($0, depth: depth + 1) }]
        // Decimal strings retain all signed 64-bit values in readers using IEEE doubles.
        case let .immediate(n): return ["tag": "immediate", "value": String(n)]
        case let .stackSlot(n): return ["tag": "stackSlot", "offset": String(n)]
        case let .symbol(s): return ["tag": "symbol", "name": s]
        case let .temporary(n): return ["tag": "temporary", "index": n]
        case let .unknown(s): return ["tag": "unknown", "text": s]
        case let .bitTest(v, bit): return ["tag": "bitTest", "value": self.value(v, depth: depth + 1), "bit": String(bit)]
        case let .unary(op, v): return ["tag": "unary", "op": op, "value": self.value(v, depth: depth + 1)]
        case let .binaryExpression(op, l, r):
            return ["tag": "binaryExpression", "op": op, "left": self.value(l, depth: depth + 1), "right": self.value(r, depth: depth + 1)]
        case let .signedBitfield(f):
            return ["tag": "signedBitfield", "source": self.value(f.source, depth: depth + 1), "operandBits": f.operandBits,
                "sourceLSB": String(f.sourceLSB), "fieldBits": String(f.fieldBits), "insertLSB": String(f.insertLSB),
                "origin": ["function": f.origin.functionName, "start": hex(f.origin.functionStart),
                    "address": hex(f.origin.instructionAddress), "mnemonic": f.origin.mnemonic,
                    "sourceRegister": f.origin.sourceRegister, "destinationRegister": f.origin.destinationRegister,
                    "definition": self.value(f.origin.definition, depth: depth + 1), "definitionBits": f.origin.definitionBits]]
        }
    }
    static func snapshot(_ s: RejectedCFGDiagnostics.Snapshot) -> Object {
        ["value": value(s.value), "width": s.width, "isJoinedDefinition": s.isJoinedDefinition, "isSyntheticReturnPhi": s.isSyntheticReturnPhi]
    }
    static func definition(_ id: RegionalOrdinaryValuePlan.DefinitionID) -> Object {
        switch id {
        case let .entry(register): return ["tag": "entry", "register": register]
        case let .source(row, slot): return ["tag": "source", "row": row, "slot": slot]
        case let .callResult(row): return ["tag": "callResult", "row": row]
        case let .join(block, register): return ["tag": "join", "block": block, "register": register]
        }
    }
    // Native IDs belong to a different proof namespace from regional ordinary IDs.
    static func nativeDefinition(_ id: DecodedScalarNativeValuePlan.DefinitionID) -> Object {
        var result: Object
        switch id {
        case let .entry(register): result = ["tag": "entry", "register": register]
        case let .source(row, slot): result = ["tag": "source", "row": row, "slot": slot]
        case let .join(block, register): result = ["tag": "join", "block": block, "register": register]
        }
        result["namespace"] = "decodedScalarNative"
        return result
    }
    static func nativeDefinitionKey(_ id: DecodedScalarNativeValuePlan.DefinitionID) -> String {
        switch id {
        case let .entry(register): return "entry:\(register)"
        case let .source(row, slot): return "source:\(row):\(slot)"
        case let .join(block, register): return "join:\(block):\(register)"
        }
    }
    static func nativeRegister(_ r: DecodedScalarCFGPlan.GPR) -> Object { ["index": r.index, "width": r.width] }

    static func definitionKey(_ id: RegionalOrdinaryValuePlan.DefinitionID) -> String {
        switch id {
        case let .entry(r): return "entry:\(r)"
        case let .source(r, s): return "source:\(r):\(s)"
        case let .callResult(r): return "callResult:\(r)"
        case let .join(b, r): return "join:\(b):\(r)"
        }
    }
    static func edge(_ edge: CFGEdge) -> Object { ["from": edge.from, "to": edge.to] }
    static func register(_ r: RegionalBoundaryPlan.Register) -> Object {
        ["index": r.index, "width": r.width]
    }
    static func operand(_ operand: RegionalPhysicalStatePlan.Operand) -> Object {
        switch operand {
        case let .register(r, shift): return ["tag": "register", "register": register(r), "shift": shift]
        case let .immediate(v): return ["tag": "immediate", "value": String(v)]
        }
    }
    static func address(_ a: RegionalPhysicalStatePlan.Address) -> Object {
        ["base": register(a.base), "index": a.index.map { register($0) as Any } ?? NSNull(),
            "shift": a.shift, "displacement": String(a.displacement)]
    }
    static func physicalRow(_ row: RegionalPhysicalStatePlan.Row) -> Object {
        switch row {
        case .original: return ["tag": "original"]
        case let .call(inputs, result): return ["tag": "call", "inputs": inputs.map(register), "hasResult": result]
        case let .load(r, a, bytes, signed, delta): return ["tag": "load", "destination": register(r),
            "address": address(a), "bytes": bytes, "signed": signed, "delta": delta.map { String($0) as Any } ?? NSNull()]
        case let .store(r, a, bytes, delta): return ["tag": "store", "source": register(r),
            "address": address(a), "bytes": bytes, "delta": delta.map { String($0) as Any } ?? NSNull()]
        case let .pair(a, b, addr, load): return ["tag": "pair", "first": register(a), "second": register(b), "address": address(addr), "load": load]
        case let .move(r, op): return ["tag": "move", "destination": register(r), "operand": operand(op)]
        case let .binary(r, op, l, rhs, flags): return ["tag": "binary", "destination": register(r), "op": op, "left": operand(l), "right": operand(rhs), "flags": flags]
        case let .variableLeftShift(d, l, r): return ["tag": "variableLeftShift", "destination": register(d), "left": register(l), "right": register(r)]
        case let .test(l, r): return ["tag": "test", "left": register(l), "right": operand(r)]
        case let .multiplySubtract(d, a, b, c): return ["tag": "multiplySubtract", "destination": register(d), "first": register(a), "second": register(b), "addend": register(c)]
        case let .divide(d, l, r, signed): return ["tag": "divide", "destination": register(d), "left": register(l), "right": register(r), "signed": signed]
        case let .extend(d, r): return ["tag": "extend", "destination": register(d), "source": register(r)]
        case let .compare(l, r, addition): return ["tag": "compare", "left": register(l), "right": operand(r), "addition": addition]
        case let .conditionalCompare(l, r, nzcv, condition, addition): return ["tag": "conditionalCompare", "left": register(l), "right": operand(r), "nzcv": nzcv, "condition": condition, "addition": addition]
        case let .select(d, yes, no, condition): return ["tag": "select", "destination": register(d), "trueRegister": register(yes), "falseRegister": register(no), "condition": condition]
        case let .set(d, condition): return ["tag": "set", "destination": register(d), "condition": condition]
        case let .conditional(condition, target): return ["tag": "conditional", "condition": condition, "target": hex(target)]
        case let .zero(r, nonzero, target): return ["tag": "zero", "register": register(r), "nonzero": nonzero, "target": hex(target)]
        case let .jump(target): return ["tag": "jump", "target": hex(target)]
        case let .dispatch(target, selector): return ["tag": "dispatch", "target": register(target), "selector": register(selector)]
        }
    }
    static func parameter(_ p: MacIRFunctionParameter) -> Object {
        let location: Object
        switch p.abiLocation {
        case let .gpr(index, width): location = ["tag": "gpr", "index": index, "carrierWidth": width]
        case let .simd(index, width): location = ["tag": "simd", "index": index, "scalarWidth": width]
        case let .entryStack(offset, size, alignment): location = ["tag": "entryStack", "byteOffset": offset, "size": size, "alignment": alignment]
        case .unbound: location = ["tag": "unbound", "status": "not-produced-for-entry-proof"]
        }
        return ["rowID": p.id.rawValue, "binding": p.bindingID.map { binding($0) as Any } ?? NSNull(),
            "abiLocation": location, "register": p.register, "type": p.type,
            "richLocationStatus": p.richLocation == nil ? "absent" : "not-exported"]
    }

    static func event(_ event: RejectedCFGDiagnostics.Event) -> Object {
        switch event {
        case let .plan(id, addresses, ranges, successors, predecessors, precedingRows, effects, entries, incoming, callRows, unenumerated):
            return ["kind": "plan", "planID": id.uuidString, "addresses": addresses.map(hex),
                "blocks": ranges.enumerated().map { i, range -> Object in
                    ["index": i, "startRow": range.lowerBound, "endRowExclusive": range.upperBound,
                     "successors": successors[i], "predecessors": predecessors[i]] },
                "precedingRows": precedingRows, "effects": effects,
                "entryProducers": entries.keys.sorted().map { row -> Object in
                    let entry = entries[row]!
                    return ["row": row, "unavailable": entry.unavailable.sorted(), "nonlexical": entry.nonlexical,
                        "producers": entry.producers.keys.sorted().map { cell -> Object in
                            ["cell": cell, "producer": entry.producers[cell]!] }]
                }, "incoming": incoming.map { $0.map { $0 as Any } ?? NSNull() },
                "callRows": callRows.sorted(), "hasUnenumeratedTransfer": unenumerated]
        case let .modeled(id, row): return ["kind": "modeled", "planID": id.uuidString, "row": row]
        case let .snapshot(id, row, cell, definition):
            return ["kind": "snapshot", "planID": id.uuidString, "producerRow": row, "cell": cell, "definition": snapshot(definition)]
        case let .missingSnapshot(id, row, cell, producer):
            return ["kind": "missingSnapshot", "planID": id.uuidString, "row": row, "cell": cell, "producer": producer]
        case let .comparison(id, row, cell, producer, snap, current, repair):
            return ["kind": "comparison", "planID": id.uuidString, "row": row, "cell": cell, "producer": producer,
                "snapshot": snapshot(snap), "current": current.map { snapshot($0) as Any } ?? NSNull(), "needsRepair": repair]
        case let .preservationVisit(id, row, cell, producer, prior, outcome, modeled, writes, predecessors):
            return ["kind": "preservationVisit", "planID": id.uuidString, "row": row, "cell": cell, "producer": producer,
                "prior": prior, "outcome": outcome, "alreadyModeled": modeled.map { $0 as Any } ?? NSNull(), "writesCell": writes.map { $0 as Any } ?? NSNull(), "predecessors": predecessors.map { $0 as Any } ?? NSNull()]
        case let .preservationResult(id, row, cell, producer, preserved):
            return ["kind": "preservationResult", "planID": id.uuidString, "row": row, "cell": cell,
                "producer": producer, "preserved": preserved]
        case let .restored(id, row, cell, definition):
            return ["kind": "restored", "planID": id.uuidString, "row": row, "cell": cell, "definition": snapshot(definition)]
        case let .physicalAttempt(id, start, addresses, ranges, predecessors, successors, backEdges, file, line):
            return ["kind": "physicalAttempt", "attemptID": id.uuidString, "start": hex(start), "addresses": addresses.map(hex),
                "blocks": ranges.enumerated().map { i, r -> Object in
                    ["index": i, "startRow": r.lowerBound, "endRowExclusive": r.upperBound,
                        "predecessors": predecessors[i], "successors": successors[i]] },
                "backEdges": backEdges.map(edge), "file": file, "line": line]
        case let .physicalRows(id, rows):
            return ["kind": "physicalRows", "attemptID": id.uuidString, "rows": rows.map(physicalRow)]
        case let .physicalCertificate(id, positions, incoming, after):
            return ["kind": "physicalCertificate", "attemptID": id.uuidString,
                "provedPositions": positions.sorted { ($0.address, $0.register, $0.width) < ($1.address, $1.register, $1.width) }.map {
                    ["address": hex($0.address), "register": $0.register, "width": $0.width] as Object },
                "liveIncoming": incoming, "liveAfter": after]
        case let .physicalEnd(id, succeeded):
            return ["kind": "physicalEnd", "attemptID": id.uuidString, "succeeded": succeeded,
                "regionalRefusalStatus": "not-produced-by-optional-return"]
        case let .ordinaryProofBegin(id, start, file, line):
            return ["kind": "ordinaryProofBegin", "attemptID": id.uuidString, "start": hex(start), "file": file, "line": line]
        case let .ordinaryProofEnd(id, succeeded):
            return ["kind": "ordinaryProofEnd", "attemptID": id.uuidString, "succeeded": succeeded]
        case let .ordinaryAttempt(id, start, addresses, parameters, file, line):
            return ["kind": "ordinaryAttempt", "attemptID": id.uuidString, "start": hex(start),
                "addresses": addresses.map(hex), "parameters": parameters.map(parameter), "file": file, "line": line]
        case let .ordinaryFacts(id, plannerCompleted, definitions, uses, edges, phiInputs, before, after, replacements):
            return ["kind": "ordinaryFacts", "attemptID": id.uuidString, "plannerCompleted": plannerCompleted,
                "definitions": definitions.keys.sorted { definitionKey($0) < definitionKey($1) }.map { key -> Object in
                    let fact = definitions[key]!
                    return ["id": definition(key), "value": value(fact.value), "width": fact.width, "type": fact.type, "zeroHigh": fact.zeroHigh]
                },
                "uses": uses.map { use -> Object in ["row": use.row, "ordinal": use.ordinal,
                    "register": register(use.register), "definition": definition(use.definition), "value": value(use.value)] },
                "edges": edges.map { e -> Object in ["edge": edge(e.edge), "register": e.register,
                    "source": definition(e.source), "destination": definition(e.destination)] },
                "phiInputs": phiInputs.keys.sorted { definitionKey($0) < definitionKey($1) }.map { join -> Object in
                    ["join": definition(join), "inputs": phiInputs[join]!.keys.sorted { ($0.from, $0.to) < ($1.from, $1.to) }.map { e -> Object in
                        ["edge": edge(e), "definition": definition(phiInputs[join]![e]!)] }] },
                "before": before.map { $0.map { $0.map { definition($0) as Any } ?? NSNull() } },
                "after": after.map { $0.map { $0.map { definition($0) as Any } ?? NSNull() } },
                "replacements": replacements.keys.sorted { definitionKey($0) < definitionKey($1) }.map { key -> Object in
                    ["from": definition(key), "to": definition(replacements[key]!)] },
                "entryBindingProvenance": "ordinary-use-binding", "readTimeSelectionStatus": "not-produced"]
        case let .nativeProofBegin(id, start, file, line):
            return ["kind": "nativeProofBegin", "attemptID": id.uuidString, "start": hex(start), "file": file, "line": line]
        case let .nativeProofEnd(id, succeeded):
            return ["kind": "nativeProofEnd", "attemptID": id.uuidString, "succeeded": succeeded]
        case let .nativeAttempt(id, start, addresses, ranges, predecessors, successors, backEdges, parameters, file, line):
            return ["kind": "nativeAttempt", "attemptID": id.uuidString, "start": hex(start),
                "addresses": addresses.map(hex), "ranges": ranges.map { ["lowerBound": $0.lowerBound, "upperBound": $0.upperBound] },
                "predecessors": predecessors, "successors": successors, "backEdges": backEdges.map(edge),
                "parameters": parameters.map(parameter), "file": file, "line": line]
        case let .nativeUse(id, use):
            return ["kind": "nativeUse", "attemptID": id.uuidString, "row": use.row, "ordinal": use.ordinal,
                "register": nativeRegister(use.register), "definition": nativeDefinition(use.definition), "value": value(use.value)]
        case let .nativeFacts(id, plannerCompleted, definitions, edges, phiInputs, before, after, replacements):
            return ["kind": "nativeFacts", "attemptID": id.uuidString, "plannerCompleted": plannerCompleted,
                "definitions": definitions.keys.sorted { nativeDefinitionKey($0) < nativeDefinitionKey($1) }.map { key -> Object in
                    let fact = definitions[key]!
                    return ["id": nativeDefinition(key), "value": value(fact.value), "width": fact.width, "type": fact.type, "zeroHigh": fact.zeroHigh]
                },
                "edges": edges.map { e -> Object in ["edge": edge(e.edge), "register": e.register,
                    "source": nativeDefinition(e.source), "destination": nativeDefinition(e.destination)] },
                "phiInputs": phiInputs.keys.sorted { nativeDefinitionKey($0) < nativeDefinitionKey($1) }.map { join -> Object in
                    ["join": nativeDefinition(join), "inputs": phiInputs[join]!.keys.sorted { ($0.from, $0.to) < ($1.from, $1.to) }.map { e -> Object in
                        ["edge": edge(e), "definition": nativeDefinition(phiInputs[join]![e]!)] }] },
                "before": before.map { $0.map { $0.map { nativeDefinition($0) as Any } ?? NSNull() } },
                "after": after.map { $0.map { $0.map { nativeDefinition($0) as Any } ?? NSNull() } },
                "replacements": replacements.keys.sorted { nativeDefinitionKey($0) < nativeDefinitionKey($1) }.map { key -> Object in
                    ["from": nativeDefinition(key), "to": nativeDefinition(replacements[key]!)] },
                "entryBindingProvenance": "native-use-binding", "readTimeSelectionStatus": "not-produced"]
        case let .guardObserved(kind, name, recorded, file, line):
            return ["kind": "guardObserved", "guardKind": kind, "guard": name, "recorded": recorded, "file": file, "line": line]
        case let .buildBegin(id, name, start):
            return ["kind": "buildBegin", "buildID": id.uuidString, "function": name, "start": hex(start)]
        case let .buildEnd(id): return ["kind": "buildEnd", "buildID": id.uuidString]
        case let .rowBegin(id, row, address): return ["kind": "rowBegin", "buildID": id.uuidString, "row": row, "address": hex(address)]
        case let .rowEnd(id, row): return ["kind": "rowEnd", "buildID": id.uuidString, "row": row]
        case let .entryRead(r, p, sourceWidth, requestedWidth, projected, file, line):
            return ["kind": "entryRead", "register": r, "parameter": parameter(p),
                "sourceWidth": sourceWidth.map { $0 as Any } ?? NSNull(),
                "requestedWidth": requestedWidth.map { $0 as Any } ?? NSNull(),
                "projectedValue": value(projected), "file": file, "line": line]
        case let .classificationBegin(id, file, line):
            return ["kind": "classificationBegin", "attemptID": id.uuidString, "file": file, "line": line]
        case let .classificationEnd(id, refusal):
            var result: Object = ["kind": "classificationEnd", "attemptID": id.uuidString]
            if let refusal {
                result["refusal"] = ["case": refusal.isContradiction ? "contradiction" : "inapplicable", "guard": refusal.guardName]
            } else { result["refusal"] = NSNull() }
            return result
        }
    }

    // Paths are explicit associated-value names/indices, never inferred from text.
    static func operands(_ operation: MacIROperation) -> [(String, MacIRValue)] {
        switch operation {
        case let .assign(_, source): return [("source", source)]
        case let .binary(_, _, l, r), let .compareToBool(_, _, l, r): return [("left", l), ("right", r)]
        case let .load(_, address): return [("address", address)]
        case let .store(source, address): return [("source", source), ("address", address)]
        case let .loadWriteback(_, _, old, _, _): return [("baseSource", old)]
        case let .storeWriteback(source, _, old, _, _): return [("source", source), ("baseSource", old)]
        case let .stackSlotRead(_, slot, v): return [("slot", slot), ("value", v)]
        case let .stackSlotPairRead(_, a, b, _, c, d):
            return [("firstSlot", a), ("firstValue", b), ("secondSlot", c), ("secondValue", d)]
        case let .call(frame, _): return frame.bindingValues.enumerated().map { ("bindingValues[\($0.offset)]", $0.element) }
        case let .conditionalBranch(_, l, r, target): return [("left", l), ("right", r), ("target", target)]
        case let .select(_, _, l, r, yes, no): return [("left", l), ("right", r), ("trueValue", yes), ("falseValue", no)]
        case let .returnValue(v): return v.map { [("returnValue", $0)] } ?? []
        case let .switchDispatch(index, cases, target):
            return [("index", index)] + cases.enumerated().map { ("cases[\($0.offset)].target", $0.element.target) }
                + (target.map { [("defaultTarget", $0)] } ?? [])
        case let .unknown(_, inputs, _, _): return inputs.mayRead.enumerated().map { ("mayRead[\($0.offset)].value", $0.element.value) }
        case let .intrinsic(_, name, arguments):
            let indices: [Int]
            if name == "restore_pair" { indices = Array(arguments.indices.dropFirst(2)) }
            else if name == "restore_pair_writeback", arguments.count == 6 { indices = [2] }
            else if name == "save_pair_writeback", arguments.count == 6 { indices = [0, 1, 2] }
            else { indices = Array(arguments.indices) }
            return indices.map { ("arguments[\($0)]", arguments[$0]) }
        }
    }
    static func unavailable(_ v: MacIRValue, path: [String]) -> [Object] {
        var pending: [(MacIRValue, [String])] = [(v, path)]
        var result: [Object] = []
        while let (current, currentPath) = pending.popLast() {
            switch current {
            case let .unknown(text) where text.hasPrefix("unavailable_"):
                result.append(["operandPath": currentPath, "value": value(current)])
            case let .unary(_, inner), let .bitTest(inner, _): pending.append((inner, currentPath + ["value"]))
            case let .signedBitfield(f): pending.append((f.source, currentPath + ["source"]))
            case let .binaryExpression(_, l, r):
                pending.append((r, currentPath + ["right"]))
                pending.append((l, currentPath + ["left"]))
            case let .abiComposite(_, fragments):
                for index in fragments.indices.reversed() {
                    pending.append((fragments[index], currentPath + ["fragments", String(index)]))
                }
            default: break
            }
        }
        return result
    }
    struct GuardedRefusal: Sendable {
        let sourceRow: Int
        let address: UInt64
        let mnemonic: String
        let operands: String
        let value: MacIRValue
        let file: String
        let line: Int
    }
    @TaskLocal static var phase = "unscoped"
    @TaskLocal static var guardedSink: (@Sendable (GuardedRefusal) -> Void)?

    /// Both modes execute the caller's original closure exactly once.
    static func withCollector<T>(_ collector: Collector?, phase: String, _ body: () throws -> T) rethrows -> T {
        let sink: (@Sendable (RejectedCFGDiagnostics.Event) -> Void)? = collector.map { c in { @Sendable event in c.append(event) } }
        let guarded: (@Sendable (GuardedRefusal) -> Void)? = collector.map { c in { @Sendable refusal in c.appendGuarded(refusal) } }
        return try $phase.withValue(phase) {
            try RejectedCFGDiagnostics.$sink.withValue(sink) {
                try $guardedSink.withValue(guarded, operation: body)
            }
        }
    }
    enum ExportError: Error { case incompleteCapture, valueDepthLimit }
    static func containsIncompleteValue(_ object: Any) -> Bool {
        var pending: [Any] = [object]
        while let next = pending.popLast() {
            if let dictionary = next as? Object {
                if dictionary["tag"] as? String == "captureIncomplete" { return true }
                pending.append(contentsOf: dictionary.values)
            } else if let array = next as? [Any] { pending.append(contentsOf: array) }
        }
        return false
    }
    /// Export qualification is isolated from the original analysis result.
    /// Preserve the first failure and never retry/overwrite a partial stream.
    final class Writer {
        private(set) var failureReason: String?
        func recordFailure(_ error: Error) {
            if failureReason == nil { failureReason = String(describing: error) }
        }
        func emit(_ exported: Export, writeCoverage: (Data) throws -> Void,
                  writeRecord: (Data) throws -> Void) {
            guard failureReason == nil else { return }
            do {
                try writeCoverage(C2ProofDiagnostics.jsonLine(exported.coverage))
                for record in exported.records { try writeRecord(C2ProofDiagnostics.jsonLine(record)) }
            } catch { recordFailure(error) }
        }
    }
    struct Export {
        let records: [Object]
        let coverage: Object
    }
    static func captureStatus(_ ledger: [Object]) -> String {
        var pending: [String: Int] = [:]
        let starts: [String: (String, String)] = ["buildBegin": ("build", "buildID"),
            "physicalAttempt": ("physical", "attemptID"), "ordinaryProofBegin": ("ordinaryProof", "attemptID"),
            "nativeProofBegin": ("nativeProof", "attemptID"), "nativeAttempt": ("nativePlanner", "attemptID"),
            "ordinaryAttempt": ("ordinaryPlanner", "attemptID"), "classificationBegin": ("classification", "attemptID"),
            "rowBegin": ("row", "buildID")]
        let ends: [String: (String, String)] = ["buildEnd": ("build", "buildID"),
            "physicalEnd": ("physical", "attemptID"), "ordinaryProofEnd": ("ordinaryProof", "attemptID"),
            "nativeProofEnd": ("nativeProof", "attemptID"), "nativeFacts": ("nativePlanner", "attemptID"),
            "ordinaryFacts": ("ordinaryPlanner", "attemptID"), "classificationEnd": ("classification", "attemptID"),
            "rowEnd": ("row", "buildID")]
        for event in ledger {
            if (event["contextStatus"] as? String)?.hasPrefix("unbalanced-") == true { return "incomplete" }
            guard let kind = event["kind"] as? String else { return "incomplete" }
            let start = starts[kind]
            guard let pair = start ?? ends[kind] else { continue }
            guard let id = event[pair.1] as? String else { return "incomplete" }
            var key = pair.0 + ":" + id
            if pair.0 == "row" {
                guard let row = event["row"] as? Int else { return "incomplete" }
                key += ":" + String(row)
            }
            pending[key, default: 0] += start == nil ? -1 : 1
            if pending[key, default: 0] < 0 { return "incomplete" }
        }
        return pending.values.allSatisfy { $0 == 0 } ? "complete" : "incomplete"
    }
    static func export(function: MacIRFunction, machine: [MacIRSourceSpan],
                       result: C2DataflowCensus.Analysis, collector: Collector,
                       sourceHead: String, flags: Object, functionOrdinal: Int = 0) throws -> Export {
        let ledger = collector.ledger()
        let guarded = collector.guarded()
        let status = captureStatus(ledger)
        guard status == "complete" else { throw ExportError.incompleteCapture }
        let findings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.rows))
        let original: Object = ["skippedReason": result.skippedReason.map { $0 as Any } ?? NSNull(), "findings": findings]
        let common: Object = ["schemaVersion": 1, "function": function.name, "start": hex(function.startAddress),
            "captureStatus": status, "factsRef": ["file": "c2-proof-coverage.jsonl", "functionOrdinal": functionOrdinal,
                "function": function.name, "start": hex(function.startAddress), "field": "facts",
                "firstSequence": 0, "sequenceCount": ledger.count]]
        var records: [Object] = []
        func row(_ index: Int, _ address: UInt64) -> Object {
            let matches = machine.indices.filter { machine[$0].address == address }
            return ["irIndex": index, "address": hex(address), "sourceRows": matches,
                "sourceRowStatus": matches.count == 1 ? "exact" : "ambiguous-or-absent",
                "registerStatus": "see-original-binding-ledger-no-marker-inference"]
        }
        for (index, instruction) in function.instructions.enumerated() {
            for (path, operand) in operands(instruction.operation) {
                for leaf in unavailable(operand, path: [path]) {
                    var record = common
                    record["recordKind"] = "unavailableUse"
                    record["occurrenceID"] = records.count
                    record["row"] = row(index, instruction.source.address)
                    record["operand"] = leaf
                    records.append(record)
                }
            }
        }
        // Phi input occurrences have edge identity, not a guessed instruction owner.
        for (phiIndex, phi) in function.phis.enumerated() {
            for (inputIndex, incoming) in phi.incoming.enumerated() {
                for leaf in unavailable(incoming.value, path: ["phis", String(phiIndex), "incoming", String(inputIndex), "value"]) {
                    var record = common
                    record["recordKind"] = "unavailableUse"
                    record["occurrenceID"] = records.count
                    record["row"] = ["status": incoming.machineAddress == nil ? "function-entry" : "phi-edge",
                        "joinAddress": hex(phi.blockAddress),
                        "predecessorAddress": incoming.machineAddress.map { hex($0) as Any } ?? NSNull()]
                    record["operand"] = leaf
                    records.append(record)
                }
            }
        }
        let unavailableCount = records.count
        for (index, refusal) in guarded.enumerated() {
            var record = common
            record["recordKind"] = "guardedSelectRefusal"
            record["occurrenceID"] = index
            record["row"] = ["sourceRow": refusal.sourceRow, "address": hex(refusal.address),
                "irIndexStatus": "not-produced-by-census-site", "mnemonic": refusal.mnemonic, "operands": refusal.operands]
            record["value"] = value(refusal.value)
            record["refusal"] = ["reason": "guarded select arm needs path-predicate proof",
                "regionalRefusalStatus": "not-produced-by-census", "file": refusal.file, "line": refusal.line]
            records.append(record)
        }
        let kinds = Set(ledger.compactMap { $0["kind"] as? String })
        func groupStatus(_ kind: String) -> String { kinds.contains(kind) ? "captured" : "not-produced" }
        let groups: Object = ["entryProducers": groupStatus("plan"), "producerSnapshots": groupStatus("snapshot"),
            "preservation": groupStatus("preservationResult"), "rowBindings": (ledger.contains { ["ordinaryFacts", "nativeFacts", "nativeUse"].contains($0["kind"] as? String ?? "") } ? "captured" : "not-produced"),
            "rejectedCertificate": groupStatus("physicalAttempt"), "entryBinding": groupStatus("entryRead"),
            "loopEdges": (ledger.contains { ["ordinaryFacts", "nativeFacts", "nativeUse"].contains($0["kind"] as? String ?? "") } ? "captured" : "not-produced")]
        let coverage: Object = ["schemaVersion": 1, "function": function.name, "start": hex(function.startAddress),
            "captureStatus": status, "sourceHead": sourceHead, "flags": flags,
            "functionOrdinal": functionOrdinal,
            "recordCount": records.count, "unavailableUseCount": unavailableCount,
            "guardedSelectRefusalCount": guarded.count, "groups": groups, "originalCensus": original,
            // Zero records still retain all original attempted proofs for this function.
            "facts": ledger]
        // Qualify every payload, including guarded values outside the event ledger.
        guard !containsIncompleteValue(coverage), !containsIncompleteValue(records) else {
            throw ExportError.valueDepthLimit
        }
        return Export(records: records, coverage: coverage)
    }

    static func jsonLine(_ record: Object) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0a)
        return data
    }
}
