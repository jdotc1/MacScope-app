import Foundation

public struct ReturnContract: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case void, value(ReturnShape), noReturn, unresolved(Reason)
    }
    public enum ReturnShape: Sendable, Hashable {
        case gpr(width: Int, type: String?)
        case fpr(width: Int, type: String?)
        case hfa(count: Int, element: String)
        case gprPair(type: String)
        case indirect(type: String)
    }
    public enum Tier: Int, Sendable, Comparable {
        case header = 0, derived = 1, closedWorld = 2
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    public enum Reason: String, Sendable, CaseIterable {
        case directOnlyPrivate = "direct_only_private", openWorld = "open_world"
        case callerUnproven = "caller_unproven", producerOnly = "producer_only"
        case contractWithoutProducer = "contract_without_producer", conflict
        case slotVetoed = "slot_vetoed", imageGuard = "image_guard"
        case cycleUnbroken = "cycle_unbroken", notLifted = "not_lifted"
    }
    public let kind: Kind
    public let tier: Tier?
    public let evidence: [Evidence]
    public let classification: String? = nil
}

public struct Evidence: Sendable, Hashable {
    public enum Source: String, Sendable { case header, catalog, slotSignature, consumer, tailCall, noReturn, discard, producer, imageFact }
    public let source: Source
    public let at: UInt64?
    public let detail: String
}

public struct CallSiteContract: Sendable, Hashable {
    public struct RawRead: Codable, Hashable, Sendable {
        public let readingPC: UInt64
        public let path: [UInt64]
    }
    public enum Target: Sendable, Hashable { case direct(UInt64), `import`(String), slot(UInt64), unknown }
    public enum Consumption: Sendable, Hashable {
        case read(width: Int, type: String?), flowsToReturn, discarded, unknown
    }
    public let address: UInt64
    public let target: Target
    public let consumption: Consumption
    public let isTailCall: Bool
    public let typeDisputed: Bool
    public let consumerTypes: [String]
    public let rawReads: [RawRead]
    public init(address: UInt64, target: Target, consumption: Consumption, isTailCall: Bool,
                typeDisputed: Bool = false, consumerTypes: [String] = [], rawReads: [RawRead] = []) {
        self.address = address; self.target = target; self.consumption = consumption
        self.isTailCall = isTailCall; self.typeDisputed = typeDisputed; self.consumerTypes = consumerTypes.sorted(); self.rawReads = rawReads
    }
}

public struct ImageFacts: Sendable {
    public let functionStarts: Set<UInt64>
    public let exported: Set<UInt64>
    public let entry: UInt64?
    public let addressTaken: Set<UInt64>
    public let tableTargets: Set<UInt64>
    public let closedWorldGuards: [String: Bool]
    public let imageComplete: Bool
    public let assumptions: [String] = ["no interprocedural register allocation"]
    public init(functionStarts: Set<UInt64>, exported: Set<UInt64> = [], entry: UInt64? = nil,
                addressTaken: Set<UInt64> = [], tableTargets: Set<UInt64> = [],
                closedWorldGuards: [String: Bool] = [:], imageComplete: Bool = false) {
        self.functionStarts = functionStarts; self.exported = exported; self.entry = entry
        self.addressTaken = addressTaken; self.tableTargets = tableTargets
        self.closedWorldGuards = closedWorldGuards; self.imageComplete = imageComplete
    }
}

/// Immutable image-wide contracts. The internal cell preserves disputed type
/// information even though its public presentation deliberately omits the type.
struct ReturnContractTable: Sendable {
    struct Key: Hashable, Sendable { let snapshotID: UUID; let slot: ImageSlot }
    struct RawReadOnlyValue: Codable, Sendable {
        struct ReadSite: Codable, Hashable, Sendable { let caller: UInt64; let callSite: UInt64; let rawReads: [CallSiteContract.RawRead] }
        let address: UInt64
        let name: String
        let readSites: [ReadSite]
    }
    struct MixedVoidTailReturn: Codable, Sendable {
        let address: UInt64
        let name: String
        let voidTailTargets: [UInt64]
        let plainReturnSites: [UInt64]
    }
    struct UnliftedCallerEntry: Codable, Sendable {
        let address: UInt64
        let name: String
        let callers: [UInt64]
    }
    struct Report: Codable, Sendable {
        let byKind: [String: Int]
        let byTier: [String: Int]
        let byReason: [String: Int]
        let capExceeded: Bool
        let contractChanges: Int
        let rawReadOnlyValues: [RawReadOnlyValue]
        let assumptions: [String]
        let mixedVoidTailReturns: [MixedVoidTailReturn]
        let unliftedCallerEntries: [UnliftedCallerEntry]
    }
    struct LocalFacts: Sendable {
        var name: String = ""
        var header: ReturnContract? = nil
        var producers: Set<BuilderState.ReturnContractProducer> = []
        var exits: Set<BuilderState.ReturnContractExit> = []
        var hasX0Parameter = false
        var lifted = true
        var slotVetoes: [String] = []
        var closedWorldVoid = false
        var requiresImageGuard = false
        var sources: [MacIRSourceSpan] = []
        var resolvedTargets: [UInt64: UInt64] = [:]
        var noReturnSites: Set<UInt64> = []
        var callSignatures: [String: FunctionSignatureOverride] = [:]
        var slotTailSites: Set<UInt64> = []
    }
    enum Cell: Hashable, Sendable {
        case pending, void, noReturn, observed(Int), value(ReturnContract.ReturnShape, typeDisputed: Bool), conflict
        init(_ kind: ReturnContract.Kind) {
            switch kind {
            case .void: self = .void
            case .noReturn: self = .noReturn
            case let .value(shape): self = .value(shape, typeDisputed: false)
            case .unresolved(.conflict): self = .conflict
            case .unresolved: self = .pending
            }
        }
        var kind: ReturnContract.Kind? {
            switch self {
            case .pending: return nil
            case .void: return .void
            case .noReturn: return .noReturn
            case let .observed(width): return .value(.gpr(width: width, type: nil))
            case let .value(shape, _): return .value(shape)
            case .conflict: return .unresolved(.conflict)
            }
        }
        func disagrees(with other: Cell) -> Bool {
            let joined = joined(other)
            if joined == .conflict { return self != .conflict }
            guard case let .value(shape, _) = self, case let .value(_, disputed) = joined, disputed else { return false }
            switch shape {
            case let .gpr(_, type), let .fpr(_, type): return type != nil
            default: return false
            }
        }
        func joined(_ other: Cell) -> Cell {
            if self == other || other == .pending { return self }
            if self == .pending { return other }
            // Register observations cannot contradict declared shapes. Keep
            // their provenance while facts propagate so later declarations
            // refine them without a transient, terminal width conflict.
            if case let .observed(a) = self, case let .observed(b) = other { return .observed(max(a, b)) }
            if case .observed = self, case .value = other { return other }
            if case .value = self, case .observed = other { return self }
            if case let .value(a, disputedA) = self, case let .value(b, disputedB) = other {
                func scalar(_ aw: Int, _ at: String?, _ bw: Int, _ bt: String?, fpr: Bool) -> Cell {
                    guard aw == bw else { return .conflict }
                    let disputed = disputedA || disputedB || (at != nil && bt != nil && at != bt)
                    let type = disputed ? nil : (at ?? bt)
                    return .value(fpr ? .fpr(width: aw, type: type) : .gpr(width: aw, type: type), typeDisputed: disputed)
                }
                switch (a, b) {
                case let (.gpr(aw, at), .gpr(bw, bt)): return scalar(aw, at, bw, bt, fpr: false)
                case let (.fpr(aw, at), .fpr(bw, bt)): return scalar(aw, at, bw, bt, fpr: true)
                default: return a == b ? self : .conflict
                }
            }
            return .conflict
        }
    }
    private struct ProducerShape: Hashable {
        let target: UInt64
        let cell: Cell
    }
    let key: Key
    let imageFacts: ImageFacts
    let entries: [UInt64: ReturnContract]
    let callSites: [UInt64: [CallSiteContract]]
    let report: Report
    var importedContracts: [String: ReturnContract] = [:]
    var slotContracts: [UInt64: ReturnContract] = [:]
    func contract(forFunctionAt start: UInt64) -> ReturnContract? { entries[start] }
    func contract(forDirectCallTo target: CallSiteContract.Target) -> ReturnContract? {
        switch target {
        case let .direct(start): return entries[start]
        case let .import(name): return importedContracts[name]
        case let .slot(address): return slotContracts[address]
        case .unknown: return nil
        }
    }

    /// The producer walker already understands terminal trap boundaries. Use
    /// those only as local sentinels for separately proven slot transfers, then
    /// classify their exits by slot site. No IR or function-start fact changes.
    private static func producerFacts(_ facts: LocalFacts, entry: UInt64,
        noReturnSites: Set<UInt64>, knownStarts: Set<UInt64>) -> BuilderState.ReturnContractProducerFacts {
        let sources = facts.sources.map { original -> MacIRSourceSpan in
            guard facts.slotTailSites.contains(original.address), original.mnemonic == "br" else { return original }
            var terminal = original
            terminal.mnemonic = "brk"
            terminal.operands = "#0"
            return terminal
        }
        let proof = BuilderState.returnContractProducerFacts(sources: sources, entry: entry,
            signatures: facts.callSignatures, resolvedTargetsByCallSite: facts.resolvedTargets,
            noReturnCallSites: noReturnSites, knownFunctionStarts: knownStarts.subtracting(facts.slotTailSites))
        let exits = Set(proof.exits.map { exit -> BuilderState.ReturnContractExit in
            if case let .trap(address) = exit, facts.slotTailSites.contains(address) { return .tailCall(address) }
            return exit
        })
        return .init(producers: proof.producers, exits: exits, reachableAddresses: proof.reachableAddresses)
    }

    static func build(key: Key, imageFacts: ImageFacts, localFacts: [UInt64: LocalFacts],
                      callSites: [UInt64: [CallSiteContract]], reverseSeeding: Bool = false,
                      externalContracts: [UInt64: ReturnContract] = [:]) -> Self {
        let starts = imageFacts.functionStarts.sorted()
        var sites = callSites.mapValues { $0.sorted { $0.address < $1.address } }
        var resolvedFacts = localFacts
        // Close structural no-return facts before admitting reads from call
        // continuations. A read after a proven terminal call is unreachable.
        var terminal = Set(externalContracts.compactMap { $0.value.kind == .noReturn ? $0.key : nil })
        terminal.formUnion(starts.filter { localFacts[$0]?.header?.kind == .noReturn })
        var pendingTerminal = Set(starts)
        while let start = pendingTerminal.min() {
            pendingTerminal.remove(start)
            var facts = resolvedFacts[start] ?? LocalFacts(lifted: false)
            if !facts.sources.isEmpty {
                let noReturnSites = Set((sites[start] ?? []).compactMap { site -> UInt64? in
                    if case let .direct(target) = site.target, terminal.contains(target) { return site.address }; return nil
                }).union(facts.noReturnSites)
                let proof = producerFacts(facts, entry: start, noReturnSites: noReturnSites,
                    knownStarts: imageFacts.functionStarts.union(externalContracts.keys))
                facts.producers = Set(proof.producers.values.flatMap { $0 }); facts.exits = proof.exits
                if !proof.reachableAddresses.isEmpty {
                    sites[start] = sites[start]?.filter { proof.reachableAddresses.contains($0.address) }
                }
                resolvedFacts[start] = facts
            }
            let proven = !facts.exits.isEmpty && facts.exits.allSatisfy { exit in
                switch exit {
                case .noReturnCall, .trap, .infiniteLoop: return true
                case let .tailCall(target): return terminal.contains(target)
                case .unknown, .returnInstruction: return false
                }
            }
            if proven && terminal.insert(start).inserted { pendingTerminal.formUnion(starts) }
        }
        var graph: [UInt64: Set<UInt64>] = [:], incoming: [UInt64: [(UInt64, CallSiteContract)]] = [:]
        for caller in starts {
            for site in sites[caller] ?? [] {
                if case let .direct(target) = site.target, imageFacts.functionStarts.contains(target) {
                    graph[caller, default: []].insert(target)
                    incoming[target, default: []].append((caller, site))
                }
            }
        }
        let order = componentOrder(starts: starts, graph: graph)
        let ordered = reverseSeeding ? Array(order.reversed()) : order
        let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
        var own = Dictionary(uniqueKeysWithValues: starts.map { ($0, resolvedFacts[$0]?.header.map { Cell($0.kind) } ?? (terminal.contains($0) ? .noReturn : .pending)) })
        for (address, contract) in externalContracts where own[address] == nil { own[address] = Cell(contract.kind) }
        var consumption: [UInt64: Cell] = [:]
        var queued = Set(starts)
        var changes = terminal.intersection(starts).filter { resolvedFacts[$0]?.header == nil }.count
        var capExceeded = false
        var finalFacts = resolvedFacts
        func isPrivate(_ start: UInt64) -> Bool {
            !imageFacts.exported.contains(start) && imageFacts.entry != start
                && !imageFacts.addressTaken.contains(start) && !imageFacts.tableTargets.contains(start)
                && !(incoming[start] ?? []).isEmpty
        }
        func dependencies(_ start: UInt64) -> Set<UInt64> {
            Set((incoming[start] ?? []).map { $0.0 }).union(graph[start] ?? [])
        }
        // Consumption depends only on local reads, immutable authority and
        // forwarding edges. Close it before shape constraints so raw interim
        // widths cannot become permanent constraints before declarations arrive.
        while let start = queued.min(by: { rank[$0, default: 0] < rank[$1, default: 0] }) {
            queued.remove(start)
            var consumed = consumption[start] ?? .pending
            for (caller, site) in incoming[start] ?? [] {
                switch site.consumption {
                case let .read(width, type):
                    if !terminal.contains(start) {
                        let fact: Cell = type == nil && !site.typeDisputed && site.consumerTypes.isEmpty
                            ? .observed(width)
                            : .value(.gpr(width: width, type: site.typeDisputed ? nil : type), typeDisputed: site.typeDisputed)
                        consumed = consumed.joined(fact)
                    }
                case .flowsToReturn:
                    let authority = resolvedFacts[caller]?.header?.kind
                    if authority != .void && authority != .noReturn && !terminal.contains(caller) {
                        if let authority, case .value = authority {
                            consumed = consumed.joined(Cell(authority))
                        } else {
                            consumed = consumed.joined(consumption[caller] ?? .pending)
                        }
                    }
                case .discarded, .unknown: break
                }
            }
            let consumptionChanged = consumption[start, default: .pending] != consumed
            consumption[start] = consumed
            if consumptionChanged {
                changes += 1
                queued.formUnion(graph[start] ?? [])
                if changes > 8 * starts.count { queued.insert(start); capExceeded = true; break }
            }
        }
        var producerShapes: [UInt64: Set<ProducerShape>] = [:]
        var shapeQueue = Set(starts)
        while let start = shapeQueue.min(by: { rank[$0, default: 0] < rank[$1, default: 0] }) {
            shapeQueue.remove(start)
            var constraints = producerShapes[start] ?? []
            let facts = resolvedFacts[start] ?? LocalFacts(lifted: false)
            let targets = Set(facts.exits.compactMap { exit -> UInt64? in
                if case let .tailCall(target) = exit { return target }; return nil
            }).union(facts.producers.compactMap { producer -> UInt64? in
                if case let .calleeResult(target) = producer { return target }; return nil
            })
            for target in targets {
                let authority = resolvedFacts[target]?.header ?? externalContracts[target]
                if let authority {
                    if case .value = authority.kind {
                        constraints.insert(ProducerShape(target: target, cell: Cell(authority.kind)))
                    }
                } else if !terminal.contains(target) {
                    let consumed = consumption[target] ?? .pending
                    switch consumed {
                    case .value, .observed:
                        constraints.insert(ProducerShape(target: target, cell: consumed))
                    default: break
                    }
                    for inherited in producerShapes[target] ?? [] {
                        constraints.insert(ProducerShape(target: target, cell: inherited.cell))
                    }
                }
            }
            if constraints != producerShapes[start, default: []] {
                producerShapes[start] = constraints
                shapeQueue.formUnion((incoming[start] ?? []).map { $0.0 })
            }
        }
        func derived(_ start: UInt64, facts: LocalFacts) -> Cell {
            if terminal.contains(start) { return .noReturn }
            var result = consumption[start] ?? .pending
            // A producer can refine a raw observation or an undeclared type,
            // but it cannot contradict the consumer's declared width or type.
            let producer = (producerShapes[start] ?? []).reduce(Cell.pending) { $0.joined($1.cell) }
            switch (result, producer) {
            case (.observed, .value(.gpr(_, _), _)):
                result = producer
            case let (.value(.gpr(width, nil), false), .value(.gpr(producerWidth, type), disputed))
                where width == producerWidth:
                result = .value(.gpr(width: width, type: type), typeDisputed: disputed)
            default: break
            }
            // Only an all-void set of returning tail exits establishes void.
            // RET, unresolved and value exits leave this rule silent.
            let returning = facts.exits.filter { exit in
                switch exit {
                case .noReturnCall, .trap, .infiniteLoop: return false
                case let .tailCall(target): return !terminal.contains(target)
                default: return true
                }
            }
            if !returning.isEmpty && returning.allSatisfy({ exit in
                if case let .tailCall(target) = exit { return own[target] == .void }
                return false
            }) { result = result.joined(.void) }
            return result
        }
        if !capExceeded { queued = Set(starts) }
        while !capExceeded, let start = queued.min(by: { rank[$0, default: 0] < rank[$1, default: 0] }) {
            queued.remove(start)
            var facts = resolvedFacts[start] ?? LocalFacts(lifted: false)
            if !facts.sources.isEmpty {
                let terminalSites = Set((sites[start] ?? []).compactMap { site -> UInt64? in
                    if case let .direct(target) = site.target, own[target] == .noReturn { return site.address }; return nil
                })
                if !terminalSites.isEmpty {
                    let proof = producerFacts(facts, entry: start, noReturnSites: terminalSites.union(facts.noReturnSites),
                        knownStarts: imageFacts.functionStarts.union(externalContracts.keys))
                    facts.producers = Set(proof.producers.values.flatMap { $0 }); facts.exits = proof.exits
                }
            }
            finalFacts[start] = facts
            let proposed = derived(start, facts: facts)
            let old = own[start] ?? .pending
            let next = facts.header == nil ? old.joined(proposed) : old
            if next != old {
                own[start] = next; changes += 1
                queued.formUnion(dependencies(start))
                if changes > 8 * starts.count { queued.insert(start); capExceeded = true; break }
            }
        }
        func pendingFlowCycle(_ start: UInt64) -> Bool {
            var pending = [start], visited: Set<UInt64> = []
            while let node = pending.popLast() {
                guard visited.insert(node).inserted else { continue }
                for (caller, site) in incoming[node] ?? []
                    where site.consumption == .flowsToReturn && own[caller] == .pending {
                    if caller == start { return true }
                    pending.append(caller)
                }
            }
            return false
        }
        var entries: [UInt64: ReturnContract] = [:]
        for start in starts {
            let facts = finalFacts[start] ?? LocalFacts(lifted: false)
            let cell = own[start] ?? .pending
            var evidence = facts.header?.evidence ?? []
            for (caller, site) in (incoming[start] ?? []).sorted(by: { ($0.0, $0.1.address) < ($1.0, $1.1.address) }) {
                evidence.append(Evidence(source: site.consumption == .discarded || (site.consumption == .flowsToReturn && own[caller] == .void) ? .discard : .consumer,
                    at: site.address, detail: "caller=\(caller) \(site.consumption) types=\(site.consumerTypes.joined(separator: ","))"))
            }
            for veto in facts.slotVetoes.sorted() { evidence.append(.init(source: .slotSignature, at: start, detail: veto)) }
            for assumption in imageFacts.assumptions {
                evidence.append(.init(source: .imageFact, at: nil, detail: "assumption: \(assumption)"))
            }
            for guardName in imageFacts.closedWorldGuards.keys.sorted() where imageFacts.closedWorldGuards[guardName] == false {
                evidence.append(.init(source: .imageFact, at: nil, detail: guardName))
            }
            let candidate = derived(start, facts: facts)
            if let header = facts.header, Cell(header.kind).disagrees(with: candidate) {
                evidence.append(.init(source: .imageFact, at: start, detail: "conflict: derived evidence disagrees with immutable authority"))
            }
            for exit in facts.exits.sorted(by: { String(describing: $0) < String(describing: $1) }) {
                switch exit {
                case let .tailCall(target): evidence.append(.init(source: .tailCall, at: start, detail: "target=\(target)"))
                case .noReturnCall, .trap, .infiniteLoop: evidence.append(.init(source: .noReturn, at: start, detail: String(describing: exit)))
                default: break
                }
            }
            for constraint in (producerShapes[start] ?? []).sorted(by: {
                ($0.target, String(describing: $0.cell)) < ($1.target, String(describing: $1.cell))
            }) {
                evidence.append(.init(source: .producer, at: start,
                    detail: "callee-result target=\(constraint.target) shape=\(constraint.cell)"))
            }
            for producer in facts.producers.sorted(by: { String(describing: $0) < String(describing: $1) }) {
                evidence.append(.init(source: .producer, at: start, detail: String(describing: producer)))
            }
            var kind = facts.header?.kind ?? cell.kind
            var tier: ReturnContract.Tier? = facts.header?.tier ?? (kind == nil ? nil : .derived)
            if kind == nil && facts.closedWorldVoid && imageFacts.imageComplete {
                // Exhaustive caller discard proves non-observation, not the
                // callee's declared return type. Preserve the certificate as
                // diagnostic evidence only, including legacy injected facts.
                evidence.append(.init(source: .discard, at: start,
                    detail: "closed-world discard does not establish a void return type"))
            }
            if kind == nil {
                let reason: ReturnContract.Reason
                if !facts.lifted { reason = .notLifted }
                else if facts.requiresImageGuard && !imageFacts.imageComplete { reason = .imageGuard }
                else if !isPrivate(start) { reason = .openWorld }
                else if (incoming[start] ?? []).contains(where: { $0.1.consumption == .unknown }) { reason = .callerUnproven }
                else if !facts.slotVetoes.isEmpty { reason = .slotVetoed }
                else if pendingFlowCycle(start) { reason = .cycleUnbroken }
                else if facts.producers.contains(where: { $0 != .unknown }) || !(producerShapes[start] ?? []).isEmpty { reason = .producerOnly }
                else { reason = .directOnlyPrivate }
                kind = .unresolved(reason)
            }
            if case .value = kind {
                // Edge predicates supply producer evidence, never return type
                // authority. A narrow zero test cannot establish the upper bits
                // of a wider result, and an untyped read cannot invent a type.
                let guardedZeroGap = facts.producers.contains { producer in
                    guard case let .guardedZero(provenWidth) = producer else { return false }
                    guard MacIRConfiguration.returnContractEnabled,
                          case let .value(.gpr(width, type)) = kind,
                          type != nil, [32, 64].contains(width), width <= provenWidth else { return true }
                    return false
                }
                let producerGap = guardedZeroGap || facts.producers.contains(.unknown)
                    || (facts.producers.contains(.passthroughParameter) && !facts.hasX0Parameter)
                    || (facts.producers.isEmpty && facts.exits.contains(where: { if case .returnInstruction = $0 { return true }; return false }))
                if tier == .header {
                    if (!facts.lifted || producerGap) && !facts.producers.contains(.unknown) {
                        evidence.append(.init(source: .producer, at: start, detail: "unknown"))
                    }
                } else if !facts.lifted { kind = .unresolved(.notLifted) }
                else if producerGap { kind = .unresolved(.contractWithoutProducer) }
            }
            if capExceeded && queued.contains(start) { kind = .unresolved(.cycleUnbroken) }
            if case .unresolved = kind { tier = nil }
            entries[start] = ReturnContract(kind: kind ?? .unresolved(.notLifted), tier: tier, evidence: evidence)
        }
        // Keep image privacy separate from unavailable direct-caller evidence.
        // All entries are assigned first so caller reasons are order-independent.
        let unliftedCallers = Set(entries.compactMap { address, entry in
            entry.kind == .unresolved(.notLifted) ? address : nil
        })
        for start in starts where isPrivate(start) {
            let callers = incoming[start] ?? []
            guard !callers.isEmpty, callers.allSatisfy({ unliftedCallers.contains($0.0) }),
                  let entry = entries[start], case let .unresolved(reason) = entry.kind,
                  [.directOnlyPrivate, .producerOnly, .slotVetoed].contains(reason) else { continue }
            entries[start] = ReturnContract(kind: .unresolved(.callerUnproven), tier: nil, evidence: entry.evidence)
        }
        var kinds: [String: Int] = [:], tiers: [String: Int] = [:], reasons: [String: Int] = [:]
        for entry in entries.values {
            let name: String
            switch entry.kind {
            case .void: name = "void"
            case .value: name = "value"
            case .noReturn: name = "noReturn"
            case let .unresolved(reason): name = "unresolved"; reasons[reason.rawValue, default: 0] += 1
            }
            kinds[name, default: 0] += 1
            tiers[entry.tier.map { String($0.rawValue) } ?? "unresolved", default: 0] += 1
        }
        let rawReadOnlyValues = starts.compactMap { start -> RawReadOnlyValue? in
            guard entries[start]?.tier == .derived, case .value = entries[start]?.kind,
                  case .observed = consumption[start] else { return nil }
            var pending = [start], visited: Set<UInt64> = [], reads: Set<RawReadOnlyValue.ReadSite> = []
            while let node = pending.popLast() {
                guard visited.insert(node).inserted else { continue }
                for (caller, site) in incoming[node] ?? [] {
                    switch site.consumption {
                    case .read(_, nil) where !site.typeDisputed && site.consumerTypes.isEmpty:
                        reads.insert(.init(caller: caller, callSite: site.address, rawReads: site.rawReads))
                    case .flowsToReturn where resolvedFacts[caller]?.header == nil:
                        pending.append(caller)
                    default: break
                    }
                }
            }
            return RawReadOnlyValue(address: start, name: resolvedFacts[start]?.name ?? "",
                readSites: reads.sorted { ($0.caller, $0.callSite) < ($1.caller, $1.callSite) })
        }
        let mixedVoidTailReturns = starts.compactMap { start -> MixedVoidTailReturn? in
            let facts = finalFacts[start] ?? LocalFacts(lifted: false)
            let returns = facts.exits.compactMap { exit -> UInt64? in
                if case let .returnInstruction(address) = exit { return address }; return nil
            }.sorted()
            guard !returns.isEmpty else { return nil }
            let directTargets = Set((sites[start] ?? []).compactMap { site -> UInt64? in
                guard site.isTailCall, case let .direct(target) = site.target else { return nil }
                return target
            })
            var voidTargets: Set<UInt64> = []
            for exit in facts.exits {
                switch exit {
                case let .tailCall(target):
                    guard let contract = entries[target] ?? externalContracts[target] else { return nil }
                    switch contract.kind {
                    case .void:
                        guard contract.tier == .header || contract.tier == .derived else { return nil }
                        if directTargets.contains(target) { voidTargets.insert(target) }
                    case .noReturn: break
                    case .value, .unresolved: return nil
                    }
                case .unknown: return nil
                case .returnInstruction, .noReturnCall, .trap, .infiniteLoop: break
                }
            }
            guard !voidTargets.isEmpty else { return nil }
            return MixedVoidTailReturn(address: start, name: facts.name,
                voidTailTargets: voidTargets.sorted(), plainReturnSites: returns)
        }
        let unliftedCallerEntries = starts.compactMap { start -> UnliftedCallerEntry? in
            let callers = incoming[start] ?? []
            guard entries[start]?.kind == .unresolved(.callerUnproven), isPrivate(start),
                  !callers.isEmpty, callers.allSatisfy({ unliftedCallers.contains($0.0) }) else { return nil }
            return UnliftedCallerEntry(address: start, name: finalFacts[start]?.name ?? "",
                callers: Set(callers.map { $0.0 }).sorted())
        }
        return Self(key: key, imageFacts: imageFacts, entries: entries, callSites: sites,
            report: Report(byKind: kinds, byTier: tiers, byReason: reasons, capExceeded: capExceeded,
                contractChanges: changes, rawReadOnlyValues: rawReadOnlyValues, assumptions: imageFacts.assumptions,
                mixedVoidTailReturns: mixedVoidTailReturns, unliftedCallerEntries: unliftedCallerEntries))
    }

    /// Tarjan components followed by deterministic topological ordering.
    private static func componentOrder(starts: [UInt64], graph: [UInt64: Set<UInt64>]) -> [UInt64] {
        var next = 0, indices: [UInt64: Int] = [:], low: [UInt64: Int] = [:]
        var stack: [UInt64] = [], active: Set<UInt64> = [], components: [[UInt64]] = []
        func visit(_ node: UInt64) {
            indices[node] = next; low[node] = next; next += 1; stack.append(node); active.insert(node)
            for child in (graph[node] ?? []).sorted() {
                if indices[child] == nil { visit(child); low[node] = min(low[node]!, low[child]!) }
                else if active.contains(child) { low[node] = min(low[node]!, indices[child]!) }
            }
            if low[node] == indices[node] {
                var component: [UInt64] = []
                while let member = stack.popLast() {
                    active.remove(member); component.append(member)
                    if member == node { break }
                }
                components.append(component.sorted())
            }
        }
        for start in starts where indices[start] == nil { visit(start) }
        var owner: [UInt64: Int] = [:]
        for (index, component) in components.enumerated() { for node in component { owner[node] = index } }
        var edges: [Int: Set<Int>] = [:], degree = Array(repeating: 0, count: components.count)
        for (node, targets) in graph {
            for target in targets {
                guard let a = owner[node], let b = owner[target], a != b else { continue }
                if edges[a, default: []].insert(b).inserted { degree[b] += 1 }
            }
        }
        var ready = Set(degree.indices.filter { degree[$0] == 0 }), result: [UInt64] = []
        while let index = ready.min(by: { components[$0][0] < components[$1][0] }) {
            ready.remove(index); result += components[index]
            for child in edges[index] ?? [] { degree[child] -= 1; if degree[child] == 0 { ready.insert(child) } }
        }
        return result
    }
}

extension ReturnContractTable {
    private static func targetAddress(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }

    static func headerContract(type: String, noReturn: Bool = false, source: Evidence.Source = .header,
                               at: UInt64? = nil, types: [TypeDefinition] = []) -> ReturnContract {
        let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog:
            Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        let kind: ReturnContract.Kind
        if noReturn { kind = .noReturn }
        else {
            switch DarwinARM64ParameterBinder.returnLocation(for: type, resolver: resolver) {
            case .void: kind = .void
            case let .single(.gpr(_, width)): kind = .value(.gpr(width: width, type: type))
            case let .single(.simd(_, width)): kind = .value(.fpr(width: width, type: type))
            case let .composite(pieces):
                if [2, 4].contains(pieces.count), pieces.allSatisfy({
                    if case .simd(_, 64) = $0.register { return $0.size == 8 }; return false
                }) { kind = .value(.hfa(count: pieces.count, element: "double")) }
                else if DarwinARM64ParameterBinder.isSupportedDirectGPRStruct(type, pieces: pieces, resolver: resolver) {
                    kind = .value(.gprPair(type: type))
                } else { kind = .unresolved(.contractWithoutProducer) }
            case .indirect: kind = .value(.indirect(type: type))
            case .unbound: kind = .unresolved(.contractWithoutProducer)
            }
        }
        return ReturnContract(kind: kind, tier: { if case .unresolved = kind { return nil }; return .header }(),
            evidence: [.init(source: source, at: at, detail: type)])
    }

    static func collect(key: Key, analysis: ImageAnalysis, functions: [MacIRFunction],
                        signatures: [UInt64: FunctionSignatureOverride], types: [TypeDefinition],
                        callerWidths: [UInt64: MacIRCallerReturnEvidence.Width],
                        slots: MacIRSlotReturnAuthority.Report,
                        indirect: MacIRIndirectTargetResolution.Report,
                        slotCalls: [UInt64: FunctionPointerSignatureV1] = [:],
                        authoredCalls: [String: FunctionSignatureOverride] = [:],
                        reverseSeeding: Bool = false) -> Self {
        let closed = MacIRCallerReturnEvidence.collectClosedWorld(analysis: analysis, functions: functions,
            effectiveSignatures: signatures, includeImageFacts: true)
        let image = MacIRCallerReturnEvidence.buildImageFacts(analysis: analysis, functions: functions,
            effectiveSignatures: signatures, legacyReport: closed)
        var resolved: [UInt64: CallSiteContract.Target] = [:]
        let groupedResolutions = Dictionary(grouping: indirect.resolutions, by: \.callAddress)
        for (address, matches) in groupedResolutions {
            let targets = Set(matches.map(\.target))
            if targets.count == 1, let target = targets.first { resolved[address] = .direct(target) }
        }
        for address in slotCalls.keys where resolved[address] == nil { resolved[address] = .slot(address) }
        let slotTailsEnabled = MacIRConfiguration.returnContractEnabled
        let brAddresses = Set(functions.flatMap(\.instructions).filter { $0.source.mnemonic.lowercased() == "br" }.map { $0.source.address })
        let slotTailSites = slotTailsEnabled ? brAddresses.intersection(slotCalls.keys) : []
        if !slotTailsEnabled { for address in brAddresses { resolved.removeValue(forKey: address) } }
        var external: [UInt64: ReturnContract] = [:], imports: [String: ReturnContract] = [:]
        let declaredSlots = slotCalls.filter { !brAddresses.contains($0.key) || slotTailSites.contains($0.key) }.mapValues {
            headerContract(type: $0.returnType, source: .slotSignature, types: types)
        }
        for address in slotTailSites { external[address] = declaredSlots[address] }
        let stubs = Dictionary(grouping: analysis.indirectSymbols.filter { $0.symbolName != nil }, by: \.address)
        for function in functions {
            for instruction in function.instructions {
                guard ["bl", "b"].contains(instruction.source.mnemonic),
                      let target = targetAddress(instruction.source.operands),
                      !image.functionStarts.contains(target), let matches = stubs[target], matches.count == 1,
                      let name = matches[0].symbolName else { continue }
                resolved[instruction.source.address] = .import(name)
                if let signature = CallSignatureCatalog.standard.signature(for: name) {
                    let contract = headerContract(type: signature.returnType,
                        noReturn: NoReturnCatalog.isNoReturn(name) || CallSignaturePack.bundledNoReturnCanonicalNames.contains(NoReturnCatalog.canonicalName(for: name)),
                        source: .catalog, at: target, types: types)
                    external[target] = contract; imports[name] = contract
                }
            }
        }
        let sites = MacIRCallerReturnEvidence.collectCallSites(functions: functions, resolvedTargets: resolved,
            callerWidths: callerWidths, slotTailSites: slotTailSites)
        var local: [UInt64: LocalFacts] = [:]
        let groups = Dictionary(grouping: functions, by: \.startAddress)
        for start in image.functionStarts {
            guard let matches = groups[start], matches.count == 1, let function = matches.first else {
                local[start] = LocalFacts(lifted: false); continue
            }
            var header: ReturnContract?
            if let signature = signatures[start], signature.returnType != nil || signature.noReturnState == .noReturn {
                header = headerContract(type: signature.returnType ?? "void", noReturn: signature.noReturnState == .noReturn, at: start, types: types)
            }
            var targetAddresses: [UInt64: UInt64] = [:], noReturnSites: Set<UInt64> = []
            for site in sites[start] ?? [] {
                switch site.target {
                case let .direct(target): targetAddresses[site.address] = target
                case let .import(name):
                    if imports[name]?.kind == .noReturn { noReturnSites.insert(site.address) }
                case .slot, .unknown: break
                }
            }
            let sources = function.instructions.map(\.source)
            let functionSlotTails = slotTailSites.intersection(sources.map(\.address))
            let proof = producerFacts(LocalFacts(sources: sources, resolvedTargets: targetAddresses,
                noReturnSites: noReturnSites, callSignatures: authoredCalls, slotTailSites: functionSlotTails),
                entry: start, noReturnSites: noReturnSites, knownStarts: image.functionStarts.union(external.keys))
            local[start] = LocalFacts(name: function.name, header: header, producers: Set(proof.producers.values.flatMap { $0 }),
                exits: proof.exits, hasX0Parameter: function.parameters.contains { $0.bindingID == .gpr(0) },
                lifted: !function.instructions.contains { if case .unknown = $0.operation { return true }; return false },
                slotVetoes: slots.entries.first { $0.target == start }?.vetoReasons ?? [],
                closedWorldVoid: closed.contracts[start] != nil,
                requiresImageGuard: closed.contracts[start] != nil,
                sources: sources, resolvedTargets: targetAddresses, noReturnSites: noReturnSites,
                callSignatures: authoredCalls, slotTailSites: functionSlotTails)
        }
        var table = build(key: key, imageFacts: image, localFacts: local, callSites: sites,
            reverseSeeding: reverseSeeding, externalContracts: external)
        table.importedContracts = imports
        table.slotContracts = declaredSlots
        return table
    }
}
