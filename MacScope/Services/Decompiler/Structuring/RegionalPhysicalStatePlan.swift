import Foundation

/// A decoded, current-physical-state certificate around unchanged opaque calls.
/// Old SSA atoms occur only in the explicit boundary ledger. This certificate
/// does not infer a callee signature or prove independent machine-callee ABI.
struct RegionalPhysicalStatePlan {
    struct Declaration {
        let storage: MacIRValue
        let type: String
        let initializer: MacIRValue?
    }
    indirect enum Effect {
        case assign(destination: MacIRValue, value: MacIRValue)
        case load(destination: MacIRValue, address: MacIRValue, byteWidth: Int)
        case store(value: MacIRValue, address: MacIRValue, byteWidth: Int)
        case conditional(predicate: MacIRValue, then: [Effect], otherwise: [Effect])
        /// Exactly this source row's unchanged call/exterior/return payload.
        case original(row: Int)
    }

    /// Control routing may consume only the original typed operation after the
    /// local selector/current-cell certificate and all physical-state gates.
    struct SwitchDispatch {
        let originalOperation: MacIROperation
        let selector: MacIRValue
        let successorBlocks: [Int]
        /// Original dominating B.HI, retained from the exact typed selector proof.
        let guardRow: Int
    }

    let declarations: [Declaration]
    let groups: [[Effect]]
    let branchConditions: [Int: BranchCondition]
    let switches: [Int: SwitchDispatch]
    /// Exact opaque EQ branch row -> unique original CMP writer row.
    let singleCMPBranches: [Int: Int]
    let namedValues: Set<MacIRValue>
    let boundaries: RegionalBoundaryPlan
    let backedgeCarriers: [CFGEdge: Set<Int>]
    /// Every first physical read matters, even a copy whose destination is
    /// subsequently dead. This conservative set covers transitive consumers.
    let liveCallResultRows: Set<Int>
    /// Immutable decoded roles and liveness, available only after every original
    /// byte, boundary, CFG, initialized-read and result-authority gate succeeds.
    let certifiedRows: [Row]
    let liveIncoming: [[UInt8]]
    let liveAfter: [[UInt8]]
    let provedPositions: Set<RegionalProvedPosition>
    private let originalFlagConsumers: [Int: Set<RegionalBoundaryPlan.FlagConsumer>]
    private let joinedObservableUses: JoinedObservableUses?
    private let originalFunction: MacIRFunction
    private var reconciledFunction: MacIRFunction? = nil
    private let originalCFG: CFG

    func matches(function: MacIRFunction, cfg: CFG) -> Bool {
        (function == originalFunction || function == reconciledFunction) && Self.sameCFG(cfg, originalCFG)
    }

    /// Classified form of `prove`: `.success`, or why it declined (`.inapplicable` for a shape the
    /// proof does not model, `.contradiction` when independent physical evidence disagrees with
    /// the function's own call/branch/edge records). Attempts combine as success, then
    /// contradiction, then inapplicable.
    static func proveClassified(function: MacIRFunction, cfg: CFG,
                                lexicalProof: RegionalLexicalProof? = nil,
                                attemptLexical: Bool = true) -> Result<Self, RegionalRefusal> {
        RegionalRefusalRecorder.classify {
            prove(function: function, cfg: cfg, lexicalProof: lexicalProof, attemptLexical: attemptLexical)
        }
    }

    static func prove(function: MacIRFunction, cfg: CFG,
                      lexicalProof: RegionalLexicalProof? = nil,
                      attemptLexical: Bool = true) -> Self? {
        if attemptLexical, lexicalProof == nil,
           let proof = RegionalLexicalProof(reconciled: function),
           var result = prove(function: proof.function, cfg: cfg, lexicalProof: proof,
                              attemptLexical: false) {
            result.reconciledFunction = function
            return result
        }
        // A declined lexical candidate does not disable the prior row proof.
        if let prior = proveRows(function: function, cfg: cfg, lexicalProof: lexicalProof,
                                 admitTypedSelectorReads: false) { return prior }
        guard lexicalProof == nil else { return nil }
        let hasSwitch = function.instructions.contains {
            if case .switchDispatch = $0.operation { return true }; return false
        }
        // These independent certificates never change lexical replay or grant
        // the prior proof any additional authority.
        if hasSwitch, let selector = proveRows(function: function, cfg: cfg, lexicalProof: nil,
                admitTypedSelectorReads: true) { return selector }
        guard function.instructions.contains(where: {
            switch $0.operation {
            case .unknown(_, _, "csel", _), .store(.unknown, _): return true
            default: return false
            }
        }) else { return nil }
        return proveRows(function: function, cfg: cfg, lexicalProof: nil,
                         admitTypedSelectorReads: hasSwitch, admitJoinedOrigins: true)
    }

    private static func proveRows(function: MacIRFunction, cfg: CFG,
                                  lexicalProof: RegionalLexicalProof?,
                                  admitTypedSelectorReads: Bool,
                                  admitJoinedOrigins: Bool = false,
                                  diagnosticFile: StaticString = #fileID,
                                  diagnosticLine: UInt = #line) -> Self? {
        // Observe this original attempt, including declined attempts, without
        // running a second proof or changing its optional-returning route.
        var diagnosticID: UUID? = nil
        var diagnosticSucceeded = false
        if let sink = RejectedCFGDiagnostics.sink {
            let id = UUID()
            diagnosticID = id
            sink(.physicalAttempt(id: id, start: function.startAddress,
                addresses: function.instructions.map { $0.source.address },
                ranges: cfg.blocks.map(\.instructionRange),
                predecessors: cfg.blocks.map(\.predecessors), successors: cfg.blocks.map(\.successors),
                backEdges: Array(cfg.backEdges), file: String(describing: diagnosticFile), line: Int(diagnosticLine)))
        }
        defer {
            if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
                sink(.physicalEnd(id: id, succeeded: diagnosticSucceeded))
            }
        }
        let instructions = function.instructions
        guard instructions.first?.source.address == function.startAddress,
              !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              sameCFG(cfg, CFGBuilder.buildCFG(instructions: instructions)),
              var boundaries = RegionalBoundaryPlan.prove(function: function, cfg: cfg,
                  admitNativeFixedIntegerCalls: !function.ssaEnabled) else { return nil }
        guard let rows = decodedRows(function: function, boundaries: boundaries),
              nativeFixedIntegerInputsAreCurrent(function: function, cfg: cfg,
                  rows: rows, boundaries: boundaries) else { return nil }
        if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
            sink(.physicalRows(id: id, rows: rows))
        }
        var selectorReads: [Int: TypedSelectorRead] = [:]
        if admitTypedSelectorReads {
            guard let context = typedSelectorReadContext(function: function, cfg: cfg,
                rows: rows, boundaries: boundaries) else { return nil }
            for marker in function.reconciliationMarkers where marker.operand == "left" {
                if let certificate = context.certificate(at: marker.instruction) {
                    selectorReads[marker.instruction] = certificate
                }
            }
            guard !selectorReads.isEmpty else { return nil }
        }
        guard Set(instructions.map { $0.source.address }).count == instructions.count,
              let typedSwitches = RegionalTypedSwitchPlan.prove(function: function, cfg: cfg,
                selectorReads: selectorReads, knownRegisterWrites: { index in
                    guard rows.indices.contains(index), !rows[index].isCall,
                          !boundaries.exteriorRows.contains(index) else { return nil }
                    return Set(rows[index].writes.filter { !$0.isZero }.map(\.index))
                }),
              typedSwitches.values.allSatisfy({ $0.matches(function: function, cfg: cfg) }) else { return nil }
        guard proveEdges(rows, instructions: instructions, cfg: cfg, switches: typedSwitches) else { return nil }
        guard boundaries.producerCorrespondence(typedSwitches: typedSwitches,
                lexicalProof: lexicalProof) else { return nil }
        var switches: [Int: SwitchDispatch] = [:]
        for (index, certificate) in typedSwitches {
            guard rows.indices.contains(index), case let .dispatch(_, selector) = rows[index],
                  selector == certificate.selectorRegister else {
                RegionalRefusalRecorder.contradict("switch-selector-register")
                return nil
            }
            // Preserve the existing bounds authority through ordinary control planning.
            switches[index] = SwitchDispatch(originalOperation: instructions[index].operation,
                selector: read(selector), successorBlocks: certificate.successors,
                guardRow: certificate.guardRow)
        }

        // Only an exact opaque EQ marker may bridge to a single CFG CMP.
        // Other unresolved conditions retain refusal. The helper supplies flow
        // facts, not source/IR authority: all canonical gates above still apply.
        let opaqueConditions = rows.indices.filter { index in
            guard case .conditional = rows[index] else { return false }
            if case .intrinsic = instructions[index].operation { return true }
            return false
        }
        var singleCMPBranches: [Int: Int] = [:]
        if !opaqueConditions.isEmpty {
            let writers = Set(rows.indices.filter { rows[$0].writesFlags || rows[$0].isCall })
            guard let origins = RegionalSingleCMPConditionPlan.analyze(
                rowCount: rows.count, cfg: cfg, writerRows: writers) else { return nil }
            for branch in opaqueConditions {
                guard case .conditional("eq", _) = rows[branch],
                      let compare = origins.uniqueWriterWithoutInterveningWriter(before: branch),
                      case .compare(_, _, addition: false) = rows[compare],
                      instructions[compare].source.mnemonic == "cmp" else { return nil }
                singleCMPBranches[branch] = compare
            }
        }

        var entryMasks = Array(repeating: UInt8(0), count: 31)
        var initializers: [Int: MacIRValue] = [:]
        for entry in boundaries.entries {
            entryMasks[entry.register.index] = entry.register.width == 32 ? 1 : 3
            initializers[entry.register.index] = commit(entry.value, width: entry.register.width)
        }
        guard initializedReads(rows, cfg: cfg, entryMasks: entryMasks, terminal: boundaries.terminal) else { return nil }
        // These cells have decoded reads and initialized-width path proofs.
        // Inherited flag reads require the separate unique-owner proof below.
        var provedPositions = Set(rows.enumerated().flatMap { index, row in
            row.reads.filter { !$0.isZero }.map {
                RegionalProvedPosition(address: instructions[index].source.address, register: $0.index, width: $0.width)
            }
        })
        provedPositions.formUnion(RegionalLexicalProof.flagPositions(
            function: function, cfg: cfg, provedReads: provedPositions))
        guard lexicalProof?.isCovered(by: provedPositions) != false else { return nil }
        let live = liveness(rows, cfg: cfg, terminal: boundaries.terminal)
        let liveCallResults = Set(boundaries.calls.values.compactMap { call -> Int? in
            call.result != nil && live.after[call.row][0] != 0 ? call.row : nil
        })
        let originalFlagConsumers = flagConsumerOrigins(rows, instructions: instructions, cfg: cfg)
        let joinedUses = admitJoinedOrigins
            ? joinedObservableUses(function: function, cfg: cfg, rows: rows, boundaries: boundaries) : nil
        if admitJoinedOrigins {
            for block in cfg.blocks where block.predecessors.count > 1 {
                let row = block.startIndex
                if case .store(.unknown, _) = instructions[row].operation,
                   case let .store(value, _, _, _) = rows[row], value.index == 0,
                   joinedUses?.storeDefinitions[row] == nil { return nil }
            }
        }
        guard liveCallResults.allSatisfy({ row in
            guard let result = boundaries.calls[row]?.result else { return false }
            return boundaries.hasOriginalObservableUse(of: result.value,
                flagConsumers: originalFlagConsumers, readWitness: { _, _ in true })
                || joinedUses?.consumersByCall[row] != nil
        }) else {
            RegionalRefusalRecorder.contradict("live-call-result-unobserved")
            return nil
        }
        guard terminalOriginsPreserved(rows, cfg: cfg, boundaries: boundaries) else { return nil }
        for index in boundaries.calls.keys {
            guard var call = boundaries.calls[index] else { return nil }
            call.retainedRegisters = Set((19..<30).filter { live.after[index][$0] != 0 })
            boundaries.calls[index] = call
        }

        let registers = Set(rows.flatMap { $0.reads + $0.writes }.filter { !$0.isZero }.map(\.index))
            .union(boundaries.entries.map { $0.register.index })
            .union(boundaries.terminal.map { [$0.alias.register.index] } ?? []).sorted()
        var declarations = registers.map {
            Declaration(storage: cell($0), type: "uint64_t", initializer: initializers[$0])
        }
        declarations += ["n", "z", "c", "v"].map {
            Declaration(storage: flag($0), type: "uint64_t", initializer: nil)
        }
        declarations += boundaries.aliases.map { Declaration(storage: $0.value, type: $0.type, initializer: nil) }
        var groups: [[Effect]] = []
        var branchConditions: [Int: BranchCondition] = [:]
        var comparisonSnapshots: [Int: (left: MacIRValue, right: MacIRValue, width: Int)] = [:]
        let bridgedWriters = Set(singleCMPBranches.values)
        for (index, row) in rows.enumerated() {
            var emitter = RowEmitter(row: index)
            var effects: [Effect]
            if let call = boundaries.calls[index] {
                effects = emitter.call(call)
            } else if boundaries.exteriorRows.contains(index) {
                effects = []
                if let terminal = boundaries.terminal, terminal.exportRow == index {
                    effects += emitter.signedAlias(terminal.alias.value,
                        bits: read(terminal.alias.register), width: terminal.alias.register.width)
                }
                effects.append(.original(row: index))
            } else {
                effects = emitter.effects(row)
            }
            if bridgedWriters.contains(index) {
                guard case .compare(_, _, addition: false) = row,
                      let operands = emitter.comparisonOperands else { return nil }
                comparisonSnapshots[index] = operands
            }
            declarations += emitter.declarations
            groups.append(effects)
            let predicate: MacIRValue?
            switch row {
            case let .conditional(condition, _): predicate = conditionValue(condition)
            case let .zero(register, nonzero, _): predicate = binary(nonzero ? "!=" : "==", read(register), .immediate(0))
            default: predicate = nil
            }
            if let predicate {
                branchConditions[index] = BranchCondition(branchIndex: index, compareIndex: nil,
                    left: predicate, condition: "!=", right: .immediate(0), isZeroCheck: false)
            }
        }
        // Resolve after every source group exists: the dominating CMP need
        // not precede the branch in lexical address order. Keep CMP effects and
        // their snapshots at that writer, never reread mutable current operands.
        for (branch, compare) in singleCMPBranches {
            guard let operands = comparisonSnapshots[compare] else { return nil }
            branchConditions[branch] = BranchCondition(branchIndex: branch, compareIndex: nil,
                left: project(operands.left, operands.width), condition: "==",
                right: project(operands.right, operands.width), isZeroCheck: false)
        }
        guard Set(declarations.map(\.storage)).count == declarations.count else { return nil }
        var named = boundaries.originalAtoms
        for declaration in declarations {
            named.insert(declaration.storage)
            if let value = declaration.initializer { RegionalBoundaryPlan.collectAtoms(value, into: &named) }
        }
        var carriers: [CFGEdge: Set<Int>] = [:]
        for edge in cfg.backEdges {
            carriers[edge] = Set((0..<30).filter { live.incoming[edge.to][$0] != 0 })
        }
        if let sink = RejectedCFGDiagnostics.sink, let id = diagnosticID {
            diagnosticSucceeded = true
            sink(.physicalCertificate(id: id, provedPositions: provedPositions,
                liveIncoming: live.incoming, liveAfter: live.after))
        }
        return Self(declarations: declarations, groups: groups, branchConditions: branchConditions, switches: switches,
            singleCMPBranches: singleCMPBranches,
            namedValues: named, boundaries: boundaries, backedgeCarriers: carriers,
            liveCallResultRows: liveCallResults,
            certifiedRows: rows, liveIncoming: live.incoming, liveAfter: live.after,
            provedPositions: provedPositions,
            originalFlagConsumers: originalFlagConsumers, joinedObservableUses: joinedUses,
            originalFunction: function, originalCFG: cfg)
    }

    /// A canonical cast cannot prove the high half of the machine X register.
    /// Require the last same-cell write before the call to be the exact decoded
    /// local load whose original destination is the retained alias. A W load
    /// writes zero high bits architecturally; any later X write/call or CFG input
    /// fails this bounded bridge instead of borrowing an old W spelling.
    private static func nativeFixedIntegerInputsAreCurrent(function: MacIRFunction, cfg: CFG,
        rows: [Row], boundaries: RegionalBoundaryPlan) -> Bool {
        for call in boundaries.calls.values where call.nativeFixedIntegerInputs {
            guard !function.ssaEnabled, call.inputs.count == 2,
                  let block = cfg.blocks.first(where: { $0.instructionRange.contains(call.row) }) else { return false }
            for input in call.inputs {
                var found = false
                for row in (block.startIndex..<call.row).reversed() {
                    if rows[row].isCall { return false }
                    guard let slot = rows[row].writes.firstIndex(where: { $0.index == input.register.index }) else { continue }
                    guard slot == 0, rows[row].writes[slot] == input.register,
                          case let .load(register, _, _, _, _) = rows[row], register == input.register,
                          case let .load(destination, _) = function.instructions[row].operation,
                          destination == input.value,
                          !call.nativeZeroExtendedInputs.contains(input.value) || register.width == 32 else { return false }
                    found = true
                    break
                }
                guard found else { return false }
            }
        }
        return true
    }

    /// Printed uses must agree with the original IR inputs, not merely mention
    /// a result's spelling somewhere in a declaration or call assignment.
    func permitsPrintedResultUses(readWitness: (Int, MacIRValue?) -> Bool,
                                  sourceWitness: (Int) -> Bool) -> Bool {
        liveCallResultRows.allSatisfy { row in
            guard let result = boundaries.calls[row]?.result else { return false }
            if boundaries.hasOriginalObservableUse(of: result.value,
                flagConsumers: originalFlagConsumers, readWitness: readWitness) { return true }
            guard let consumers = joinedObservableUses?.consumersByCall[row], !consumers.isEmpty else { return false }
            return consumers.allSatisfy(sourceWitness)
        }
    }

    /// Exact decoded source admission, shared with the independent selector
    /// context so a negative certificate test cannot pass on a source mismatch.
    private static func decodedRows(function: MacIRFunction,
                                    boundaries: RegionalBoundaryPlan) -> [Row]? {
        let instructions = function.instructions
        var rows: [Row] = []
        for (index, instruction) in instructions.enumerated() {
            guard instruction == MacIRInstruction(source: instruction.source, operation: instruction.operation,
                    memoryAccess: instruction.memoryAccess, returnTarget: instruction.returnTarget),
                  instruction.returnTarget == nil,
                  index == 0 || instructions[index - 1].source.address.isContiguous(to: instruction.source.address),
                  canonicalEvidence(instruction, call: boundaries.calls[index]) else { return nil }
            if boundaries.exteriorRows.contains(index) {
                rows.append(.original)
            } else if let call = boundaries.calls[index] {
                rows.append(.call(call.inputs.map(\.register), hasResult: call.result != nil))
            } else if case let .switchDispatch(selector, _, _) = instruction.operation {
                // Parsing is not admission: every such row must subsequently
                // obtain an exact typed-control/current-cell certificate.
                let parts = MacIRBuilder.splitOperands(instruction.source.operands)
                guard instruction.source.mnemonic == "br", parts.count == 1,
                      let target = Register(parts[0]), target.width == 64, !target.isZero,
                      case let .register(name, _) = selector, let index = Register(name),
                      index.width == 32, !index.isZero, instruction.memoryAccess == nil else { return nil }
                rows.append(.dispatch(target: target, selector: index))
            } else {
                guard let row = parse(instruction.source) else { return nil }
                guard memoryAgrees(row, instruction.memoryAccess) else {
                    RegionalRefusalRecorder.contradict("memory-access-disagrees")
                    return nil
                }
                rows.append(row)
            }
        }
        return rows
    }

    private static func isWidth32MarkerValue(_ value: MacIRValue, register: Register) -> Bool {
        switch value {
        case let .register(name, version):
            return version >= 0 && Register(name) == register
        case let .unary("(uint32_t)", .register(name, version)):
            guard let source = Register(name) else { return false }
            return version >= 0 && source.index == register.index && [32, 64].contains(source.width)
        default: return false
        }
    }

    struct TypedSelectorRead {
        let row: Int
        let reachingWritersByPredecessor: [Int: Set<Int>]
        fileprivate let position: RegionalProvedPosition
        fileprivate let lexicalValue: MacIRValue
        fileprivate let originalFunction: MacIRFunction
        fileprivate let originalCFG: CFG

        func accepts(function: MacIRFunction, cfg: CFG, row: Int,
                     operand: MacIRValue, register: Register) -> Bool {
            guard self.row == row, function == originalFunction,
                  RegionalPhysicalStatePlan.sameCFG(cfg, originalCFG), register.width == 32,
                  register.index == position.register,
                  function.instructions.indices.contains(row),
                  function.instructions[row].source.address == position.address,
                  operand == .unknown("unavailable_w\(register.index)") else { return false }
            // Function equality intentionally ignores transient evidence. Bind
            // this token to the exact recorded operand as well as semantic IR.
            let markers = function.reconciliationMarkers.filter {
                $0.instruction == row && $0.operand == "left"
            }
            guard markers.count == 1, let marker = markers.first,
                  marker.position == position, marker.lexicalValue == lexicalValue,
                  RegionalPhysicalStatePlan.isWidth32MarkerValue(marker.lexicalValue,
                      register: register) else { return false }
            return true
        }
    }

    /// Construction establishes canonical decoded rows and initialized reads.
    /// The certificate still has to prove each predecessor's exact load role.
    struct TypedSelectorReadContext {
        fileprivate let function: MacIRFunction
        fileprivate let cfg: CFG
        fileprivate let rows: [Row]

        private struct ReadRole: Equatable {
            let base: Register
            let index: Register?
            let shift: Int
            let displacement: Int64
        }

        func certificate(at row: Int) -> TypedSelectorRead? {
            let instructions = function.instructions
            guard rows.indices.contains(row), instructions.indices.contains(row),
                  case let .binary(destination, "-", input, _) = instructions[row].operation,
                  case let .register(name, _) = destination,
                  let register = Register(name), register.width == 32, !register.isZero,
                  input == .unknown("unavailable_w\(register.index)"),
                  case let .binary(decodedDestination, "-", .register(decodedRead, shift: 0), _, flags: false) = rows[row],
                  decodedDestination == register, decodedRead == register else { return nil }
            let markers = function.reconciliationMarkers.filter {
                $0.instruction == row && $0.operand == "left"
            }
            guard markers.count == 1, let marker = markers.first,
                  RegionalPhysicalStatePlan.isWidth32MarkerValue(marker.lexicalValue,
                      register: register),
                  marker.position == RegionalProvedPosition(address: instructions[row].source.address,
                      register: register.index, width: 32),
                  let block = cfg.blocks.first(where: { $0.instructionRange.contains(row) }),
                  row == block.startIndex, !block.predecessors.isEmpty else { return nil }

            func role(of writer: Int) -> ReadRole? {
                switch rows[writer] {
                case let .load(destination, address, bytes: 4, signed: false, delta: nil):
                    guard destination == register else { return nil }
                    return ReadRole(base: address.base, index: address.index,
                        shift: address.shift, displacement: address.displacement)
                case let .pair(first, second, address, load: true):
                    guard first.width == 32, second.width == 32,
                          first == register || second == register else { return nil }
                    let offset = address.displacement.addingReportingOverflow(second == register ? 4 : 0)
                    guard !offset.overflow else { return nil }
                    return ReadRole(base: address.base, index: address.index,
                        shift: address.shift, displacement: offset.partialValue)
                default: return nil
                }
            }
            var visiting = Set<Int>()
            var resolved: [Int: Set<Int>] = [:]
            func reaching(atEndOf blockIndex: Int) -> Set<Int>? {
                guard cfg.blocks.indices.contains(blockIndex) else { return nil }
                if let known = resolved[blockIndex] { return known }
                guard visiting.insert(blockIndex).inserted else { return nil }
                defer { visiting.remove(blockIndex) }
                let predecessor = cfg.blocks[blockIndex]
                for index in predecessor.instructionRange.reversed() {
                    guard rows.indices.contains(index) else { return nil }
                    let current = rows[index]
                    // An exterior row has no decoded write-set authority. Calls
                    // are conservative barriers even for preserved registers.
                    if current.isCall { return nil }
                    if case .original = current { return nil }
                    if current.writes.contains(where: { $0.index == register.index }) {
                        guard role(of: index) != nil else { return nil }
                        let found: Set<Int> = [index]
                        resolved[blockIndex] = found
                        return found
                    }
                }
                guard blockIndex != cfg.entryIndex, !predecessor.predecessors.isEmpty else { return nil }
                var found = Set<Int>()
                for incoming in predecessor.predecessors {
                    guard let writers = reaching(atEndOf: incoming), !writers.isEmpty else { return nil }
                    found.formUnion(writers)
                }
                resolved[blockIndex] = found
                return found
            }
            var perEdge: [Int: Set<Int>] = [:]
            var commonRole: ReadRole?
            for predecessor in block.predecessors {
                guard let writers = reaching(atEndOf: predecessor), !writers.isEmpty else { return nil }
                for writer in writers {
                    guard let currentRole = role(of: writer) else { return nil }
                    if let commonRole { guard commonRole == currentRole else { return nil } }
                    else { commonRole = currentRole }
                }
                perEdge[predecessor] = writers
            }
            guard commonRole != nil, perEdge.count == block.predecessors.count else { return nil }
            return TypedSelectorRead(row: row, reachingWritersByPredecessor: perEdge,
                position: marker.position, lexicalValue: marker.lexicalValue,
                originalFunction: function, originalCFG: cfg)
        }
    }

    static func typedSelectorReadContext(function: MacIRFunction, cfg: CFG) -> TypedSelectorReadContext? {
        guard let boundaries = RegionalBoundaryPlan.prove(function: function, cfg: cfg),
              let rows = decodedRows(function: function, boundaries: boundaries) else { return nil }
        return typedSelectorReadContext(function: function, cfg: cfg, rows: rows, boundaries: boundaries)
    }

    private static func typedSelectorReadContext(function: MacIRFunction, cfg: CFG,
        rows: [Row], boundaries: RegionalBoundaryPlan) -> TypedSelectorReadContext? {
        guard function.instructions.first?.source.address == function.startAddress,
              rows.count == function.instructions.count, !cfg.hasUnresolvedTargets,
              cfg.irreducibleBlocks.isEmpty,
              sameCFG(cfg, CFGBuilder.buildCFG(instructions: function.instructions)) else { return nil }
        var entryMasks = Array(repeating: UInt8(0), count: 31)
        for entry in boundaries.entries {
            entryMasks[entry.register.index] = entry.register.width == 32 ? 1 : 3
        }
        guard initializedReads(rows, cfg: cfg, entryMasks: entryMasks,
                               terminal: boundaries.terminal) else { return nil }
        return TypedSelectorReadContext(function: function, cfg: cfg, rows: rows)
    }

    typealias Register = RegionalBoundaryPlan.Register
    enum Operand {
        case register(Register, shift: Int)
        case immediate(Int64)
        var reads: [Register] {
            if case let .register(register, _) = self { return [register] }
            return []
        }
        var value: MacIRValue {
            switch self {
            case let .register(register, shift):
                let value = RegionalPhysicalStatePlan.read(register)
                return shift == 0 ? value : RegionalPhysicalStatePlan.binary("<<", value, .immediate(Int64(shift)))
            case let .immediate(value): return RegionalPhysicalStatePlan.project(.immediate(value), 64)
            }
        }
    }
    struct Address {
        let base: Register
        let index: Register?
        let shift: Int
        let displacement: Int64
        var reads: [Register] { [base] + (index.map { [$0] } ?? []) }
        var value: MacIRValue {
            var value = RegionalPhysicalStatePlan.read(base)
            if let index {
                var offset = RegionalPhysicalStatePlan.read(index)
                if shift != 0 { offset = RegionalPhysicalStatePlan.binary("<<", offset, .immediate(Int64(shift))) }
                value = RegionalPhysicalStatePlan.binary("+", value, offset)
            }
            if displacement != 0 {
                value = RegionalPhysicalStatePlan.binary("+", value,
                    RegionalPhysicalStatePlan.project(.immediate(displacement), 64))
            }
            return RegionalPhysicalStatePlan.project(value, 64)
        }
    }
    enum Row {
        case original
        case call([Register], hasResult: Bool)
        case load(Register, Address, bytes: Int, signed: Bool, delta: Int64?)
        case store(Register, Address, bytes: Int, delta: Int64?)
        case pair(Register, Register, Address, load: Bool)
        case move(Register, Operand)
        case binary(Register, String, Operand, Operand, flags: Bool)
        case variableLeftShift(Register, Register, Register)
        case test(Register, Operand)
        case multiplySubtract(Register, Register, Register, Register)
        case divide(Register, Register, Register, signed: Bool)
        case extend(Register, Register)
        case compare(Register, Operand, addition: Bool)
        case conditionalCompare(Register, Operand, nzcv: Int, condition: String, addition: Bool)
        case select(Register, Register, Register, condition: String)
        case set(Register, condition: String)
        case conditional(String, UInt64)
        case zero(Register, nonzero: Bool, UInt64)
        case jump(UInt64)
        case dispatch(target: Register, selector: Register)

        var reads: [Register] {
            switch self {
            case .original, .conditional, .jump: return []
            case let .call(inputs, _): return inputs
            case let .load(_, address, _, _, _), let .pair(_, _, address, true): return address.reads
            case let .store(value, address, _, _): return [value] + address.reads
            case let .pair(first, second, address, false): return [first, second] + address.reads
            case let .move(_, value): return value.reads
            case let .binary(_, _, left, right, _): return left.reads + right.reads
            case let .variableLeftShift(_, left, right): return [left, right]
            case let .test(left, right): return [left] + right.reads
            case let .dispatch(target, selector): return [target, selector]
            case let .multiplySubtract(_, first, second, addend): return [first, second, addend]
            case let .divide(_, left, right, _): return [left, right]
            case let .extend(_, value): return [value]
            case let .compare(left, right, _), let .conditionalCompare(left, right, _, _, _): return [left] + right.reads
            case let .select(_, yes, no, _): return [yes, no]
            case .set: return []
            case let .zero(value, _, _): return [value]
            }
        }
        var writes: [Register] {
            switch self {
            case let .load(destination, address, _, _, delta): return [destination] + (delta == nil ? [] : [address.base])
            case let .store(_, address, _, delta): return delta == nil ? [] : [address.base]
            case let .pair(first, second, _, true): return [first, second]
            case let .move(destination, _), let .binary(destination, _, _, _, _),
                 let .variableLeftShift(destination, _, _),
                 let .multiplySubtract(destination, _, _, _), let .divide(destination, _, _, _),
                 let .extend(destination, _), let .select(destination, _, _, _), let .set(destination, _): return [destination]
            case let .call(_, hasResult): return hasResult ? [Register(index: 0, width: 64)] : []
            default: return []
            }
        }
        var readsFlags: Bool {
            switch self { case .conditionalCompare, .select, .set, .conditional: return true; default: return false }
        }
        var writesFlags: Bool {
            switch self { case .compare, .conditionalCompare, .test, .binary(_, _, _, _, true): return true; default: return false }
        }
        var isCall: Bool { if case .call = self { return true }; return false }
        var isControl: Bool {
            switch self { case .conditional, .zero, .jump, .dispatch: return true; default: return false }
        }
    }

    private static func parse(_ source: MacIRSourceSpan) -> Row? {
        let parts = MacIRBuilder.splitOperands(source.operands)
        switch source.mnemonic {
        case "ldr", "ldur", "ldrb", "ldurb", "ldrh", "ldurh", "ldrsw", "ldursw":
            guard (2...3).contains(parts.count), let destination = Register(parts[0]), !destination.isZero,
                  let address = address(parts[1]) else { return nil }
            let signed = source.mnemonic.hasSuffix("sw")
            let bytes = signed ? 4 : source.mnemonic.hasSuffix("b") ? 1 : source.mnemonic.hasSuffix("h") ? 2 : destination.width / 8
            guard (!signed || destination.width == 64), (bytes >= 4 || destination.width == 32) else { return nil }
            var delta: Int64?
            if parts.count == 3 {
                guard !source.mnemonic.hasPrefix("ldur"), address.index == nil, address.displacement == 0,
                      address.base.index != destination.index,
                      let value = MacIRBuilder.parseImmediate(parts[2]) else { return nil }
                delta = value
            }
            return .load(destination, address, bytes: bytes, signed: signed, delta: delta)
        case "str", "stur", "strb", "sturb", "strh", "sturh":
            guard (2...3).contains(parts.count), let value = Register(parts[0]),
                  let address = address(parts[1]) else { return nil }
            let bytes = source.mnemonic.hasSuffix("b") ? 1 : source.mnemonic.hasSuffix("h") ? 2 : value.width / 8
            guard bytes >= 4 || value.width == 32 else { return nil }
            var delta: Int64?
            if parts.count == 3 {
                // Architectural writeback/source overlap is constrained
                // unpredictable, including W/X aliases of the same index.
                guard !source.mnemonic.hasPrefix("stur"), address.index == nil, address.displacement == 0,
                      value.isZero || value.index != address.base.index,
                      let amount = MacIRBuilder.parseImmediate(parts[2]) else { return nil }
                delta = amount
            }
            return .store(value, address, bytes: bytes, delta: delta)
        case "ldp", "stp":
            guard parts.count == 3, let first = Register(parts[0]), let second = Register(parts[1]),
                  first.width == second.width, let address = address(parts[2]), address.index == nil else { return nil }
            let load = source.mnemonic == "ldp"
            guard !load || (!first.isZero && !second.isZero && first.index != second.index) else { return nil }
            return .pair(first, second, address, load: load)
        case "mov":
            guard parts.count == 2, let destination = Register(parts[0]), !destination.isZero,
                  let value = operand(parts[1], width: destination.width) else { return nil }
            return .move(destination, value)
        case "adrp", "adr":
            guard parts.count == 2, let destination = Register(parts[0]), destination.width == 64,
                  !destination.isZero, let address = target(parts[1]),
                  (source.mnemonic != "adrp" || address & 4095 == 0),
                  address <= UInt64(Int64.max) else { return nil }
            return .move(destination, .immediate(Int64(address)))
        case "add", "sub", "adds", "subs", "and", "orr", "eor", "mul", "lsl", "lsr":
            guard (3...4).contains(parts.count), let destination = Register(parts[0]), !destination.isZero,
                  let left = Register(parts[1]), left.width == destination.width,
                  var right = operand(parts[2], width: destination.width) else { return nil }
            let operations = ["add": "+", "adds": "+", "sub": "-", "subs": "-", "and": "&",
                              "orr": "|", "eor": "^", "mul": "*", "lsl": "<<", "lsr": ">>"]
            guard let operation = operations[source.mnemonic] else { return nil }
            if parts.count == 4 {
                guard ["add", "sub", "and", "orr", "eor"].contains(source.mnemonic),
                      case let .register(register, _) = right,
                      let shift = shift(parts[3], width: register.width) else { return nil }
                right = .register(register, shift: shift)
            }
            if source.mnemonic == "lsl", destination.width == 64, parts.count == 3,
               case let .register(amount, shift: 0) = right {
                return .variableLeftShift(destination, left, amount)
            }
            if source.mnemonic == "lsl" || source.mnemonic == "lsr" {
                guard case let .immediate(amount) = right, (0..<Int64(destination.width)).contains(amount) else { return nil }
            }
            return .binary(destination, operation, .register(left, shift: 0), right,
                flags: source.mnemonic == "adds" || source.mnemonic == "subs")
        case "msub":
            guard parts.count == 4, let destination = Register(parts[0]), !destination.isZero,
                  let first = Register(parts[1]), let second = Register(parts[2]), let addend = Register(parts[3]),
                  [first, second, addend].allSatisfy({ $0.width == destination.width }) else { return nil }
            return .multiplySubtract(destination, first, second, addend)
        case "sdiv", "udiv":
            guard parts.count == 3, let destination = Register(parts[0]), !destination.isZero,
                  destination.width == 32, let left = Register(parts[1]), let right = Register(parts[2]),
                  left.width == 32, right.width == 32 else { return nil }
            return .divide(destination, left, right, signed: source.mnemonic == "sdiv")
        case "sxtw":
            guard parts.count == 2, let destination = Register(parts[0]), destination.width == 64,
                  !destination.isZero, let value = Register(parts[1]), value.width == 32 else { return nil }
            return .extend(destination, value)
        case "cmp", "cmn":
            guard parts.count == 2, let left = Register(parts[0]),
                  let right = operand(parts[1], width: left.width) else { return nil }
            return .compare(left, right, addition: source.mnemonic == "cmn")
        case "tst":
            guard parts.count == 2, let left = Register(parts[0]), left.width == 64,
                  let right = operand(parts[1], width: left.width) else { return nil }
            return .test(left, right)
        case "ccmp", "ccmn":
            guard parts.count == 4, let left = Register(parts[0]),
                  let right = operand(parts[1], width: left.width),
                  let nzcv = MacIRBuilder.parseImmediate(parts[2]), (0..<16).contains(nzcv),
                  conditionValue(parts[3]) != nil else { return nil }
            return .conditionalCompare(left, right, nzcv: Int(nzcv), condition: parts[3],
                                       addition: source.mnemonic == "ccmn")
        case "csel":
            guard parts.count == 4, let destination = Register(parts[0]), !destination.isZero,
                  let yes = Register(parts[1]), let no = Register(parts[2]),
                  yes.width == destination.width, no.width == destination.width,
                  conditionValue(parts[3]) != nil else { return nil }
            return .select(destination, yes, no, condition: parts[3])
        case "cset":
            guard parts.count == 2, let destination = Register(parts[0]), !destination.isZero,
                  conditionValue(parts[1]) != nil else { return nil }
            return .set(destination, condition: parts[1])
        case "cbz", "cbnz":
            guard parts.count == 2, let value = Register(parts[0]), let target = target(parts[1]) else { return nil }
            return .zero(value, nonzero: source.mnemonic == "cbnz", target)
        case "b":
            guard parts.count == 1, let target = target(parts[0]) else { return nil }
            return .jump(target)
        default:
            guard source.mnemonic.hasPrefix("b."), parts.count == 1,
                  let target = target(parts[0]) else { return nil }
            let condition = String(source.mnemonic.dropFirst(2))
            guard conditionValue(condition) != nil else { return nil }
            return .conditional(condition, target)
        }
    }

    private static func operand(_ text: String, width: Int) -> Operand? {
        if let register = Register(text), register.width == width { return .register(register, shift: 0) }
        if let immediate = MacIRBuilder.parseImmediate(text), immediate != Int64.min { return .immediate(immediate) }
        return nil
    }
    private static func shift(_ text: String, width: Int) -> Int? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, parts[0] == "lsl", let amount = MacIRBuilder.parseImmediate(String(parts[1])),
              (0..<Int64(width)).contains(amount) else { return nil }
        return Int(amount)
    }
    private static func address(_ text: String) -> Address? {
        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        let parts = MacIRBuilder.splitOperands(String(text.dropFirst().dropLast()))
        guard (1...3).contains(parts.count), let base = parts.first.flatMap(Register.init),
              base.width == 64, !base.isZero else { return nil }
        if parts.count == 1 { return Address(base: base, index: nil, shift: 0, displacement: 0) }
        if parts.count == 2, let offset = MacIRBuilder.parseImmediate(parts[1]), offset != Int64.min {
            return Address(base: base, index: nil, shift: 0, displacement: offset)
        }
        guard let index = Register(parts[1]) else { return nil }
        if parts.count == 2, index.width == 64 { return Address(base: base, index: index, shift: 0, displacement: 0) }
        guard parts.count == 3 else { return nil }
        let modifier = parts[2].split(separator: " ").map(String.init)
        guard (1...2).contains(modifier.count),
              (modifier[0] == "lsl" && index.width == 64) || (modifier[0] == "uxtw" && index.width == 32) else { return nil }
        let amount: Int64
        if modifier.count == 1 { amount = 0 }
        else { guard let parsed = MacIRBuilder.parseImmediate(modifier[1]) else { return nil }; amount = parsed }
        guard (0..<64).contains(amount) else { return nil }
        return Address(base: base, index: index, shift: Int(amount), displacement: 0)
    }
    private static func target(_ text: String) -> UInt64? {
        text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
    private static func memoryAgrees(_ row: Row, _ access: MacIRMemoryAccess?) -> Bool {
        switch row {
        case let .load(_, _, width, signed, _):
            let kind: MacIRMemoryAccess.ExtensionKind = signed ? .sign : width < 4 ? .zero : .none
            return access == MacIRMemoryAccess(byteWidth: width, extensionKind: kind)
        case let .store(_, _, width, _): return access == MacIRMemoryAccess(byteWidth: width, extensionKind: .none)
        case let .pair(first, _, _, _): return access == MacIRMemoryAccess(byteWidth: first.width / 8, extensionKind: .none)
        default: return access == nil
        }
    }

    private static func canonicalEvidence(_ instruction: MacIRInstruction,
                                           call: RegionalBoundaryPlan.Call?) -> Bool {
        let source = instruction.source
        guard let envelope = source.structuredOperands else { return false }
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return false }
        var bytes: [UInt8] = []
        for token in tokens {
            guard token.utf8.count == 2, token.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let byte = UInt8(token, radix: 16) else { return false }
            bytes.append(byte)
        }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: source.address, maxInstructionCount: 1)
        guard decoded.count == 1, let row = decoded.first, row.address == source.address,
              row.bytes == bytes, row.mnemonic == source.mnemonic else { return false }
        guard row.structuredOperands == envelope else {
            RegionalRefusalRecorder.contradict("operand-envelope-disagrees-with-bytes")
            return false
        }
        if let call, source.mnemonic == "bl" {
            guard envelope.coverage == .complete,
                  envelope.rendersExactly(mnemonic: row.mnemonic, operands: row.operands),
                  call.frame.controlInputs.canonicalControlInputsForAudit.isEmpty else { return false }
            guard source.operands == call.frame.target else {
                RegionalRefusalRecorder.contradict("call-symbolic-target")
                return false
            }
            if let supplied = target(source.operands) {
                guard target(row.operands) == supplied else {
                    RegionalRefusalRecorder.contradict("call-decoded-displacement")
                    return false
                }
                return true
            }
            // Same symbolic opaque target, separately verified numeric envelope.
            // No unavailable symbol-to-address mapping is asserted here.
            return true
        }
        guard row.operands == source.operands else { return false }
        switch envelope.coverage {
        case .complete: return envelope.rendersExactly(mnemonic: source.mnemonic, operands: source.operands)
        case .unavailable: return envelope == .unavailable(mnemonic: source.mnemonic, operands: source.operands)
        case .partial: return false
        }
    }

    private static func proveEdges(_ rows: [Row], instructions: [MacIRInstruction], cfg: CFG,
                                   switches: [Int: RegionalTypedSwitchPlan]) -> Bool {
        var byAddress: [UInt64: Int] = [:]
        for block in cfg.blocks {
            guard rows.indices.contains(block.startIndex), block.endIndex <= rows.count,
                  block.endIndex > block.startIndex,
                  byAddress.updateValue(block.index, forKey: instructions[block.startIndex].source.address) == nil else { return false }
        }
        var visited: Set<Int> = []
        var pending = [cfg.entryIndex]
        while let block = pending.popLast() {
            guard cfg.blocks.indices.contains(block) else { return false }
            if visited.insert(block).inserted { pending += cfg.blocks[block].successors }
        }
        guard visited.count == cfg.blocks.count else { return false }
        for block in cfg.blocks {
            guard !block.instructionRange.dropLast().contains(where: { rows[$0].isControl }) else { return false }
            let last = block.endIndex - 1
            let expected: [Int]
            switch rows[last] {
            case .dispatch:
                guard let certificate = switches[last] else { return false }
                expected = certificate.successors
            case let .conditional(_, target), let .zero(_, _, target):
                guard let taken = byAddress[target], let fallthroughBlock = cfg.blockByStartIndex[block.endIndex],
                      taken != fallthroughBlock else { return false }
                let operation = instructions[last].operation
                let exactTarget = MacIRValue.immediate(Int64(bitPattern: target))
                if case let .conditionalBranch(_, _, _, typedTarget) = operation {
                    guard typedTarget == exactTarget else {
                        RegionalRefusalRecorder.contradict("branch-target-disagrees")
                        return false
                    }
                } else {
                    // Parsing this exact marker is not admission: the caller
                    // separately proves its unique, unclobbered CFG CMP writer.
                    guard case .conditional("eq", _) = rows[last],
                          case let .intrinsic(nil, "branch_eq", arguments) = operation,
                          arguments == [exactTarget] else {
                        RegionalRefusalRecorder.contradict("branch-marker-target-disagrees")
                        return false
                    }
                }
                expected = [taken, fallthroughBlock]
            case let .jump(target):
                guard let targetBlock = byAddress[target],
                      case let .intrinsic(nil, "branch", arguments) = instructions[last].operation,
                      arguments == [.immediate(Int64(bitPattern: target))] else {
                    RegionalRefusalRecorder.contradict("jump-target-disagrees")
                    return false
                }
                expected = [targetBlock]
            default:
                if case .returnValue = instructions[last].operation { expected = [] }
                else {
                    guard let next = cfg.blockByStartIndex[block.endIndex] else { return false }
                    expected = [next]
                }
            }
            guard block.successors == expected else {
                RegionalRefusalRecorder.contradict("block-successors-disagree")
                return false
            }
        }
        return true
    }

    private static func readMasks(_ row: Row, index: Int,
                                  terminal: RegionalBoundaryPlan.Terminal?) -> [UInt8] {
        var result = Array(repeating: UInt8(0), count: 31)
        for register in row.reads where !register.isZero {
            result[register.index] |= register.width == 32 ? 1 : 3
        }
        if row.readsFlags { result[30] = 3 }
        if let terminal, terminal.exportRow == index {
            result[terminal.alias.register.index] |= terminal.alias.register.width == 32 ? 1 : 3
        }
        return result
    }
    private static func transfer(_ row: Row, _ incoming: [UInt8]) -> [UInt8] {
        var result = incoming
        if row.isCall {
            for register in 0...18 { result[register] = 0 }
            result[30] = 0
        }
        for register in row.writes where !register.isZero { result[register.index] = 3 }
        if row.writesFlags { result[30] = 3 }
        return result
    }
    private static func initializedReads(_ rows: [Row], cfg: CFG, entryMasks: [UInt8],
                                         terminal: RegionalBoundaryPlan.Terminal?) -> Bool {
        let top = Array(repeating: UInt8(3), count: 31)
        var incoming = Array(repeating: top, count: cfg.blocks.count)
        var outgoing = incoming
        var changed = true
        while changed {
            changed = false
            for block in cfg.blocks {
                var input = block.index == cfg.entryIndex ? entryMasks : top
                if block.index != cfg.entryIndex {
                    guard !block.predecessors.isEmpty else { return false }
                    for predecessor in block.predecessors {
                        guard outgoing.indices.contains(predecessor) else { return false }
                        for register in input.indices { input[register] &= outgoing[predecessor][register] }
                    }
                }
                var output = input
                for index in block.instructionRange { output = transfer(rows[index], output) }
                if input != incoming[block.index] || output != outgoing[block.index] {
                    incoming[block.index] = input; outgoing[block.index] = output; changed = true
                }
            }
        }
        for block in cfg.blocks {
            var available = incoming[block.index]
            for index in block.instructionRange {
                let reads = readMasks(rows[index], index: index, terminal: terminal)
                for register in available.indices where available[register] & reads[register] != reads[register] {
                    RegionalRefusalRecorder.contradict("read-of-uninitialized-register")
                    return false
                }
                available = transfer(rows[index], available)
            }
        }
        return true
    }
    private struct Liveness {
        let incoming: [[UInt8]]
        let after: [[UInt8]]
    }

    private enum TerminalOrigin: Hashable {
        case call(Int)
        case unsupported
    }

    /// Existing printed compare effects can have predecessor-correct decoded
    /// readers even when the old sequential IR records a different writer in a
    /// shared CSEL. Only actual flag readers reached before overwrite/call are
    /// bridged; their original output must still reach a printed observable use.
    private static func flagConsumerOrigins(_ rows: [Row], instructions: [MacIRInstruction], cfg: CFG)
        -> [Int: Set<RegionalBoundaryPlan.FlagConsumer>] {
        var successors = Array(repeating: [Int](), count: rows.count)
        for block in cfg.blocks {
            for index in block.instructionRange {
                successors[index] = index + 1 < block.endIndex ? [index + 1]
                    : block.successors.map { cfg.blocks[$0].startIndex }
            }
        }
        var result: [Int: Set<RegionalBoundaryPlan.FlagConsumer>] = [:]
        for writer in rows.indices {
            guard case .compare = rows[writer],
                  case .intrinsic(nil, "compare", _) = instructions[writer].operation else { continue }
            var pending = successors[writer]
            var visited: Set<Int> = []
            var consumers: Set<RegionalBoundaryPlan.FlagConsumer> = []
            while let index = pending.popLast() {
                guard visited.insert(index).inserted else { continue }
                switch (rows[index], instructions[index].operation) {
                case (.conditional, .conditionalBranch):
                    consumers.insert(.control(index))
                case let (.select, .select(destination, _, _, _, _, _)),
                     let (.set, .compareToBool(destination, _, _, _)):
                    consumers.insert(.value(destination))
                default: break
                }
                if !rows[index].writesFlags && !rows[index].isCall {
                    pending.append(contentsOf: successors[index])
                }
            }
            if !consumers.isEmpty { result[writer] = consumers }
        }
        return result
    }

    /// Additional observation authority is bound to an original store and all
    /// incoming edges. It never supplies a terminal role or changes call payloads.
    struct JoinedObservableUses {
        let selectWriters: [Int: [Int: Int]]
        let storeDefinitions: [Int: [Int: Set<Int>]]
        let loopAddressDefinitions: [Int: [Int: Set<Int>]]
        fileprivate let consumersByCall: [Int: Set<Int>]
    }

    /// Discharge deferred address ownership with the existing value/phi proof.
    /// A union of reaching writers alone cannot name a loop-carried value.
    func permitsJoinedAddressUses(_ values: RegionalOrdinaryValuePlan) -> Bool {
        guard let joinedObservableUses else { return true }
        for (row, registers) in joinedObservableUses.loopAddressDefinitions {
            for (register, expectedWriters) in registers {
                let uses = values.useBindings.filter { $0.row == row && $0.register.index == register }
                guard uses.count == 1, let use = uses.first, use.register.width == 64,
                      case let .join(header, cell) = use.definition, cell == register,
                      originalCFG.loopHeaders.contains(header) else { return false }
                var pending = [use.definition], seen = Set<RegionalOrdinaryValuePlan.DefinitionID>()
                var writers = Set<Int>()
                while let definition = pending.popLast() {
                    guard seen.insert(definition).inserted else { continue }
                    switch definition {
                    case let .source(source, slot):
                        guard certifiedRows.indices.contains(source),
                              certifiedRows[source].writes.indices.contains(slot),
                              certifiedRows[source].writes[slot] == Register(index: register, width: 64)
                        else { return false }
                        writers.insert(source)
                    case let .join(block, cell):
                        guard cell == register else { return false }
                        let edges = values.edgeBindings.filter { $0.destination == definition && $0.register == register }
                        guard Set(edges.map { $0.edge.from }) == Set(originalCFG.blocks[block].predecessors)
                        else { return false }
                        pending += edges.map(\.source)
                    default: return false
                    }
                }
                guard writers == expectedWriters else { return false }
            }
        }
        return true
    }

    static func joinedObservableUses(function: MacIRFunction, cfg: CFG) -> JoinedObservableUses? {
        guard sameCFG(cfg, CFGBuilder.buildCFG(instructions: function.instructions)),
              !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              let boundary = RegionalBoundaryPlan.prove(function: function, cfg: cfg),
              let rows = decodedRows(function: function, boundaries: boundary),
              RegionalBoundaryPlan.producerCorrespondence(function) else { return nil }
        var entryMasks = Array(repeating: UInt8(0), count: 31)
        for entry in boundary.entries {
            entryMasks[entry.register.index] = entry.register.width == 32 ? 1 : 3
        }
        guard initializedReads(rows, cfg: cfg, entryMasks: entryMasks, terminal: boundary.terminal) else { return nil }
        return joinedObservableUses(function: function, cfg: cfg, rows: rows, boundaries: boundary)
    }

    private static func joinedObservableUses(function: MacIRFunction, cfg: CFG, rows: [Row],
                                             boundaries: RegionalBoundaryPlan) -> JoinedObservableUses? {
        let instructions = function.instructions
        var previous = Array(repeating: [Int](), count: rows.count)
        for block in cfg.blocks {
            for row in block.instructionRange {
                previous[row] = row > block.startIndex ? [row - 1]
                    : block.predecessors.map { cfg.blocks[$0].endIndex - 1 }
            }
        }
        // Match the lexical flag proof's exception policy. CFG carries no
        // exception edges, so memory and unsupported/exterior effects are
        // ownership barriers even when they do not explicitly write NZCV.
        let transparent: Set<String> = ["mov", "adr", "adrp", "add", "sub", "and", "orr", "eor",
            "mul", "msub", "lsl", "lsr", "sxtw", "b", "cbz", "cbnz", "tbz", "tbnz"]
        let flagRows = Set(rows.indices.filter { row in
            let instruction = instructions[row], mnemonic = instruction.source.mnemonic
            if case .original = rows[row] { return true }
            return rows[row].writesFlags || rows[row].isCall || instruction.memoryAccess != nil
                || (!transparent.contains(mnemonic) && !mnemonic.hasPrefix("b."))
        })
        guard let flags = RegionalSingleCMPConditionPlan.analyze(rowCount: rows.count,
                cfg: cfg, writerRows: flagRows) else { return nil }

        // First decoded definitions, independently for each incoming edge.
        // Initialized-read proof has already checked every path and width.
        // Calls stop volatile reads; preserved cells retain their existing
        // boundary contract. Exterior rows confer no decoded write authority.
        func definitions(_ register: Register, through ends: [Int]) -> Set<Int>? {
            if register.isZero { return [] }
            var pending = ends, seen = Set<Int>(), result = Set<Int>()
            while let row = pending.popLast() {
                guard rows.indices.contains(row) else { return nil }
                guard seen.insert(row).inserted else { continue }
                if case .original = rows[row] { return nil }
                if rows[row].writes.contains(where: { $0.index == register.index }) {
                    result.insert(row)
                    continue
                }
                if rows[row].isCall && register.index <= 18 { return nil }
                guard !previous[row].isEmpty else { return nil }
                pending += previous[row]
            }
            return result.isEmpty ? nil : result
        }
        func roles(_ registers: [Register], through end: Int) -> Bool {
            registers.allSatisfy { definitions($0, through: [end]) != nil }
        }
        func exactWidth(_ register: Register, writers: Set<Int>) -> Bool {
            !writers.isEmpty && writers.allSatisfy { writer in
                rows[writer].writes.filter { $0.index == register.index } == [register]
            }
        }
        func originalStore(_ row: Int, register: Register, selected: MacIRValue? = nil) -> Bool {
            guard case let .store(value, _, bytes, delta) = rows[row], value == register,
                  delta == nil, bytes * 8 == register.width,
                  case let .store(source, _) = instructions[row].operation else { return false }
            if let selected {
                var atoms = Set<MacIRValue>()
                RegionalBoundaryPlan.collectAtoms(source, into: &atoms)
                return atoms.contains(selected)
            }
            return source == .unknown("unavailable_\(register.width == 32 ? "w" : "x")\(register.index)")
        }
        var selectWriters: [Int: [Int: Int]] = [:]
        var storeDefinitions: [Int: [Int: Set<Int>]] = [:]
        var loopAddressDefinitions: [Int: [Int: Set<Int>]] = [:]
        var consumers: [Int: Set<Int>] = [:]
        for block in cfg.blocks where block.predecessors.count > 1 {
            let row = block.startIndex
            if case let .select(destination, yes, no, _) = rows[row],
               case let .unknown(optionalDestination, _, "csel", _) = instructions[row].operation,
               let originalDestination = optionalDestination, !destination.isZero,
               destination.width == yes.width, destination.width == no.width {
                // Only an existing typed store of this exact original result
                // can supply observation authority. Dead selects stay dead.
                var store: Int?
                for consumer in (row + 1)..<block.endIndex {
                    if originalStore(consumer, register: destination, selected: originalDestination) {
                        store = consumer; break
                    }
                    if rows[consumer].isCall || rows[consumer].writes.contains(where: {
                        $0.index == destination.index
                    }) { break }
                }
                guard let store else { continue }
                var perEdge: [Int: Int] = [:], calls = Set<Int>()
                var expectedRegister: Register?, expectedImmediate: Int64?
                var valid = true
                for predecessor in block.predecessors {
                    let end = cfg.blocks[predecessor].endIndex - 1
                    guard !flagRows.contains(end),
                          let writer = flags.uniqueWriterWithoutInterveningWriter(before: end),
                          case let .compare(register, .immediate(immediate), addition: false) = rows[writer],
                          !register.isZero, instructions[writer].source.mnemonic == "cmp",
                          case let .intrinsic(nil, "compare", arguments) = instructions[writer].operation,
                          arguments.count == 2,
                          roles([yes, no], through: end),
                          let origins = definitions(register, through: previous[writer]), !origins.isEmpty else {
                        valid = false; break
                    }
                    if let expectedRegister, let expectedImmediate {
                        guard register == expectedRegister, immediate == expectedImmediate else { valid = false; break }
                    } else { expectedRegister = register; expectedImmediate = immediate }
                    // Preserve the compared data role all the way to this edge,
                    // not merely the NZCV writer's identity.
                    guard let atEdge = definitions(register, through: [end]), atEdge == origins else {
                        valid = false; break
                    }
                    var originalReads = Set<MacIRValue>()
                    arguments.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &originalReads) }
                    for origin in origins where rows[origin].isCall {
                        guard register.index == 0, let result = boundaries.calls[origin]?.result,
                              originalReads.contains(result.value) else { valid = false; break }
                        calls.insert(origin)
                    }
                    guard valid else { break }
                    perEdge[predecessor] = writer
                }
                guard valid, perEdge.count == block.predecessors.count else { continue }
                selectWriters[row] = perEdge
                for call in calls { consumers[call, default: []].formUnion([row, store]) }
            } else if case let .store(value, address, _, _) = rows[row],
                      originalStore(row, register: value) {
                var perEdge: [Int: Set<Int>] = [:], calls = Set<Int>(), valid = true
                var loopAddresses: [Int: Set<Int>] = [:]
                for predecessor in block.predecessors {
                    let end = cfg.blocks[predecessor].endIndex - 1
                    guard let origins = definitions(value, through: [end]), origins.count == 1,
                          exactWidth(value, writers: origins) else {
                        valid = false; break
                    }
                    // As in the existing flag proof, no exception edges are
                    // modelled by this CFG. This is not an unwind-path proof.
                    for register in address.reads {
                        guard let writers = definitions(register, through: [end]),
                              exactWidth(register, writers: writers) else { valid = false; break }
                        if writers.count > 1 {
                            guard register == address.index, register.width == 64,
                                  loopAddresses[register.index] == nil || loopAddresses[register.index] == writers
                            else { valid = false; break }
                            loopAddresses[register.index] = writers
                        } else if loopAddresses[register.index] != nil { valid = false; break }
                    }
                    guard valid else { break }
                    for origin in origins where rows[origin].isCall {
                        // The original decoded store is the post-call physical
                        // read. Reaching definitions exclude an intervening
                        // overwrite; this grants no signature or return role.
                        guard value.index == 0, boundaries.calls[origin]?.result != nil else {
                            valid = false; break
                        }
                        calls.insert(origin)
                    }
                    guard valid else { break }
                    perEdge[predecessor] = origins
                }
                guard valid, perEdge.count == block.predecessors.count, !calls.isEmpty else { continue }
                storeDefinitions[row] = perEdge
                loopAddressDefinitions[row] = loopAddresses
                for call in calls { consumers[call, default: []].insert(row) }
            }
        }
        guard !consumers.isEmpty else { return nil }
        return JoinedObservableUses(selectWriters: selectWriters, storeDefinitions: storeDefinitions,
                                    loopAddressDefinitions: loopAddressDefinitions,
                                    consumersByCall: consumers)
    }

    /// Restricted explicit-data-origin proof, not return-value equivalence or
    /// control-dependence noninterference. Only constants, register copies and
    /// extensions preserve a known origin here. Unproved arithmetic, loads,
    /// selects and address writebacks remain unsupported, never empty.
    private static func terminalOriginsPreserved(_ rows: [Row], cfg: CFG,
                                                 boundaries: RegionalBoundaryPlan) -> Bool {
        guard let terminal = boundaries.terminal else { return true }
        typealias State = [Set<TerminalOrigin>]
        let empty: State = Array(repeating: [], count: 30)
        let unknown: Set<TerminalOrigin> = [.unsupported]
        let entry: State = Array(repeating: unknown, count: 30)
        func readOrigins(_ register: Register, _ input: State) -> Set<TerminalOrigin> {
            register.isZero ? [] : input[register.index]
        }
        func transferOrigins(_ row: Row, index: Int, _ input: State) -> State {
            var output = input
            if row.isCall {
                for register in 0...18 { output[register] = unknown }
            }
            for register in row.writes where !register.isZero { output[register.index] = unknown }
            switch row {
            case let .call(_, hasResult):
                if hasResult { output[0] = [.call(index)] }
            case let .move(destination, operand) where !destination.isZero:
                switch operand {
                case .immediate: output[destination.index] = []
                case let .register(source, _): output[destination.index] = readOrigins(source, input)
                }
            case let .extend(destination, source) where !destination.isZero:
                output[destination.index] = readOrigins(source, input)
            default: break
            }
            return output
        }
        var incoming = Array(repeating: empty, count: cfg.blocks.count)
        var outgoing = incoming
        var changed = true
        while changed {
            changed = false
            for block in cfg.blocks {
                var input = block.index == cfg.entryIndex ? entry : empty
                for predecessor in block.predecessors {
                    for register in input.indices { input[register].formUnion(outgoing[predecessor][register]) }
                }
                var output = input
                for index in block.instructionRange { output = transferOrigins(rows[index], index: index, output) }
                if input != incoming[block.index] || output != outgoing[block.index] {
                    incoming[block.index] = input; outgoing[block.index] = output; changed = true
                }
            }
        }
        guard let block = cfg.blocks.first(where: { $0.instructionRange.contains(terminal.exportRow) }) else {
            return false
        }
        var atExport = incoming[block.index]
        for index in block.startIndex..<terminal.exportRow {
            atExport = transferOrigins(rows[index], index: index, atExport)
        }
        return atExport[terminal.alias.register.index].allSatisfy { origin in
            guard case let .call(row) = origin else { return false }
            return boundaries.calls[row]?.result?.value == terminal.alias.value
        }
    }
    private static func liveness(_ rows: [Row], cfg: CFG,
                                  terminal: RegionalBoundaryPlan.Terminal?) -> Liveness {
        let empty = Array(repeating: UInt8(0), count: 31)
        var incoming = Array(repeating: empty, count: cfg.blocks.count)
        var outgoing = incoming
        func backwards(_ row: Row, index: Int, from output: [UInt8]) -> [UInt8] {
            var input = output
            for register in row.writes where !register.isZero { input[register.index] = 0 }
            if row.writesFlags { input[30] = 0 }
            if row.isCall {
                for register in 0...18 { input[register] = 0 }
                input[30] = 0
            }
            let reads = readMasks(row, index: index, terminal: terminal)
            for register in input.indices { input[register] |= reads[register] }
            return input
        }
        var changed = true
        while changed {
            changed = false
            for block in cfg.blocks.reversed() {
                var output = empty
                for successor in block.successors {
                    for register in output.indices { output[register] |= incoming[successor][register] }
                }
                var input = output
                for index in block.instructionRange.reversed() { input = backwards(rows[index], index: index, from: input) }
                if input != incoming[block.index] || output != outgoing[block.index] {
                    incoming[block.index] = input; outgoing[block.index] = output; changed = true
                }
            }
        }
        var after = Array(repeating: empty, count: rows.count)
        for block in cfg.blocks {
            var current = outgoing[block.index]
            for index in block.instructionRange.reversed() {
                after[index] = current
                current = backwards(rows[index], index: index, from: current)
            }
        }
        return Liveness(incoming: incoming, after: after)
    }

    private static func cell(_ register: Int) -> MacIRValue { .register(name: "rgn_regional_r\(register)", version: 0) }
    private static func flag(_ name: String) -> MacIRValue { .register(name: "rgn_regional_\(name)", version: 0) }
    private static func project(_ value: MacIRValue, _ width: Int) -> MacIRValue { .unary(op: "(uint\(width)_t)", value: value) }
    private static func commit(_ value: MacIRValue, width: Int) -> MacIRValue { project(project(value, width), 64) }
    private static func read(_ register: Register) -> MacIRValue {
        commit(register.isZero ? .immediate(0) : cell(register.index), width: register.width)
    }
    private static func binary(_ op: String, _ left: MacIRValue, _ right: MacIRValue) -> MacIRValue {
        .binaryExpression(op: op, left: left, right: right)
    }
    private static func not(_ value: MacIRValue) -> MacIRValue { .unary(op: "~", value: value) }
    private static func highBit(_ value: MacIRValue, width: Int) -> MacIRValue {
        binary("&", binary(">>", project(value, 64), .immediate(Int64(width - 1))), .immediate(1))
    }
    private static func conditionValue(_ condition: String) -> MacIRValue? {
        let n = flag("n"), z = flag("z"), c = flag("c"), v = flag("v")
        switch condition {
        case "eq": return binary("!=", z, .immediate(0))
        case "ne": return binary("==", z, .immediate(0))
        case "hs", "cs": return binary("!=", c, .immediate(0))
        case "lo", "cc": return binary("==", c, .immediate(0))
        case "mi": return binary("!=", n, .immediate(0))
        case "pl": return binary("==", n, .immediate(0))
        case "vs": return binary("!=", v, .immediate(0))
        case "vc": return binary("==", v, .immediate(0))
        case "hi": return binary("&&", binary("!=", c, .immediate(0)), binary("==", z, .immediate(0)))
        case "ls": return binary("||", binary("==", c, .immediate(0)), binary("!=", z, .immediate(0)))
        case "ge": return binary("==", n, v)
        case "lt": return binary("!=", n, v)
        case "gt": return binary("&&", binary("==", z, .immediate(0)), binary("==", n, v))
        case "le": return binary("||", binary("!=", z, .immediate(0)), binary("!=", n, v))
        default: return nil
        }
    }
    private static func sameCFG(_ left: CFG, _ right: CFG) -> Bool {
        left.blocks == right.blocks && left.entryIndex == right.entryIndex &&
        left.domTree == right.domTree && left.postDomTree == right.postDomTree &&
        left.loopHeaders == right.loopHeaders && left.backEdges == right.backEdges &&
        left.irreducibleBlocks == right.irreducibleBlocks &&
        left.blockByStartIndex == right.blockByStartIndex && left.hasUnresolvedTargets == right.hasUnresolvedTargets
    }

    private struct RowEmitter {
        private typealias P = RegionalPhysicalStatePlan
        let row: Int
        var declarations: [Declaration] = []
        var comparisonOperands: (left: MacIRValue, right: MacIRValue, width: Int)?
        private var nextTemporary = 0

        init(row: Int) { self.row = row }
        mutating func temporary() -> MacIRValue {
            let value = MacIRValue.register(name: "rgn_regional_t\(row)_\(nextTemporary)", version: 0)
            nextTemporary += 1
            declarations.append(Declaration(storage: value, type: "uint64_t", initializer: nil))
            return value
        }
        mutating func snapshot(_ value: MacIRValue, into effects: inout [Effect]) -> MacIRValue {
            let result = temporary()
            effects.append(.assign(destination: result, value: P.project(value, 64)))
            return result
        }

        /// Conversion is defined for every source bit pattern. The only signed
        /// casts are of nonnegative values within the selected signed range.
        mutating func signedAlias(_ destination: MacIRValue, bits: MacIRValue, width: Int) -> [Effect] {
            var effects: [Effect] = []
            let value = snapshot(P.commit(bits, width: width), into: &effects)
            let nonnegative = P.binary("==", P.highBit(value, width: width), .immediate(0))
            let positive = MacIRValue.unary(op: "(int\(width)_t)", value: P.project(value, width))
            let complement = P.project(P.not(value), width)
            let negative = P.binary("-", .immediate(-1), .unary(op: "(int\(width)_t)", value: complement))
            effects.append(.conditional(predicate: nonnegative,
                then: [.assign(destination: destination, value: positive)],
                otherwise: [.assign(destination: destination, value: negative)]))
            return effects
        }

        mutating func call(_ call: RegionalBoundaryPlan.Call) -> [Effect] {
            var effects: [Effect] = []
            var retained: [(Int, MacIRValue)] = []
            for register in call.retainedRegisters.sorted() {
                retained.append((register, snapshot(P.cell(register), into: &effects)))
            }
            // Capture every input before any original identity is rebound.
            var inputs: [(RegionalBoundaryPlan.Alias, MacIRValue)] = []
            for input in call.inputs {
                inputs.append((input, snapshot(P.read(input.register), into: &effects)))
            }
            for (input, value) in inputs {
                effects += signedAlias(input.value, bits: value, width: input.register.width)
            }
            effects.append(.original(row: call.row))
            // No result means no forwarding, even if an older X0 cell existed.
            if let result = call.result {
                effects.append(.assign(destination: P.cell(0), value: P.project(result.value, 64)))
            }
            for (register, value) in retained {
                effects.append(.assign(destination: P.cell(register), value: value))
            }
            return effects
        }

        mutating func flags(left: MacIRValue, right: MacIRValue, width: Int,
                            addition: Bool, destination: Register? = nil) -> [Effect] {
            var effects: [Effect] = []
            let a = snapshot(P.commit(left, width: width), into: &effects)
            let b = snapshot(P.commit(right, width: width), into: &effects)
            comparisonOperands = (a, b, width)
            let result = snapshot(P.commit(P.binary(addition ? "+" : "-", a, b), width: width), into: &effects)
            if let destination {
                effects.append(.assign(destination: P.cell(destination.index), value: result))
            }
            let differentInputs = P.binary("^", a, b)
            let changedSign = P.binary("^", a, result)
            let overflow = P.binary("&", addition ? P.not(differentInputs) : differentInputs, changedSign)
            effects += [
                .assign(destination: P.flag("n"), value: P.highBit(result, width: width)),
                .assign(destination: P.flag("z"), value: P.binary("==", result, .immediate(0))),
                .assign(destination: P.flag("c"), value: addition ? P.binary("<", result, a) : P.binary(">=", a, b)),
                .assign(destination: P.flag("v"), value: P.highBit(overflow, width: width))
            ]
            return effects
        }

        mutating func signExtend(_ value: MacIRValue, destination: MacIRValue) -> [Effect] {
            let low = P.commit(value, width: 32)
            let upperMask = P.not(P.project(.immediate(0xffff_ffff), 64))
            return [.conditional(predicate: P.binary("==", P.highBit(low, width: 32), .immediate(0)),
                then: [.assign(destination: destination, value: low)],
                otherwise: [.assign(destination: destination, value: P.binary("|", low, upperMask))])]
        }

        mutating func effects(_ row: Row) -> [Effect] {
            switch row {
            case .original, .call, .conditional, .zero, .jump, .dispatch:
                return [] // Original payloads and control are owned separately.
            case let .move(destination, value):
                return [.assign(destination: P.cell(destination.index), value: P.commit(value.value, width: destination.width))]
            case let .binary(destination, operation, left, right, changesFlags):
                if changesFlags {
                    return flags(left: left.value, right: right.value, width: destination.width,
                        addition: operation == "+", destination: destination)
                }
                let expression = P.binary(operation, P.commit(left.value, width: destination.width),
                    P.commit(right.value, width: destination.width))
                return [.assign(destination: P.cell(destination.index), value: P.commit(expression, width: destination.width))]
            case let .variableLeftShift(destination, left, right):
                let count = P.binary("&", P.read(right), .immediate(63))
                let shifted = P.binary("<<", P.read(left), count)
                return [.assign(destination: P.cell(destination.index), value: P.commit(shifted, width: 64))]
            case let .test(left, right):
                var effects: [Effect] = []
                let result = snapshot(P.commit(P.binary("&", P.read(left), right.value), width: left.width), into: &effects)
                effects += [
                    .assign(destination: P.flag("n"), value: P.highBit(result, width: left.width)),
                    .assign(destination: P.flag("z"), value: P.binary("==", result, .immediate(0))),
                    .assign(destination: P.flag("c"), value: .immediate(0)),
                    .assign(destination: P.flag("v"), value: .immediate(0))
                ]
                return effects
            case let .compare(left, right, addition):
                return flags(left: P.read(left), right: right.value, width: left.width, addition: addition)
            case let .conditionalCompare(left, right, nzcv, condition, addition):
                let compared = flags(left: P.read(left), right: right.value, width: left.width, addition: addition)
                let literal = ["n", "z", "c", "v"].enumerated().map { ordinal, name in
                    Effect.assign(destination: P.flag(name), value: .immediate(Int64((nzcv >> (3 - ordinal)) & 1)))
                }
                return [.conditional(predicate: P.conditionValue(condition)!, then: compared, otherwise: literal)]
            case let .set(destination, condition):
                return [.assign(destination: P.cell(destination.index),
                    value: P.commit(P.conditionValue(condition)!, width: destination.width))]
            case let .select(destination, yes, no, condition):
                return [.conditional(predicate: P.conditionValue(condition)!,
                    then: [.assign(destination: P.cell(destination.index), value: P.commit(P.read(yes), width: destination.width))],
                    otherwise: [.assign(destination: P.cell(destination.index), value: P.commit(P.read(no), width: destination.width))])]
            case let .extend(destination, source):
                var effects: [Effect] = []
                let value = snapshot(P.read(source), into: &effects)
                effects += signExtend(value, destination: P.cell(destination.index))
                return effects
            case let .multiplySubtract(destination, first, second, addend):
                var effects: [Effect] = []
                let a = snapshot(P.read(first), into: &effects)
                let b = snapshot(P.read(second), into: &effects)
                let c = snapshot(P.read(addend), into: &effects)
                effects.append(.assign(destination: P.cell(destination.index),
                    value: P.commit(P.binary("-", c, P.binary("*", a, b)), width: destination.width)))
                return effects
            case let .divide(destination, left, right, signed):
                var effects: [Effect] = []
                let a = snapshot(P.read(left), into: &effects)
                let b = snapshot(P.read(right), into: &effects)
                let output = P.cell(destination.index)
                var quotientEffects: [Effect] = []
                if signed {
                    let magnitudeA = temporary(), magnitudeB = temporary(), quotient = temporary()
                    for (source, magnitude) in [(a, magnitudeA), (b, magnitudeB)] {
                        quotientEffects.append(.conditional(predicate: P.binary("!=", P.highBit(source, width: 32), .immediate(0)),
                            then: [.assign(destination: magnitude, value: P.commit(P.binary("-", P.project(.immediate(0), 64), source), width: 32))],
                            otherwise: [.assign(destination: magnitude, value: source)]))
                    }
                    quotientEffects.append(.assign(destination: quotient, value: P.binary("/", magnitudeA, magnitudeB)))
                    quotientEffects.append(.conditional(predicate: P.binary("!=", P.highBit(a, width: 32), P.highBit(b, width: 32)),
                        then: [.assign(destination: output, value: P.commit(P.binary("-", P.project(.immediate(0), 64), quotient), width: 32))],
                        otherwise: [.assign(destination: output, value: P.commit(quotient, width: 32))]))
                } else {
                    quotientEffects = [.assign(destination: output, value: P.commit(P.binary("/", a, b), width: 32))]
                }
                effects.append(.conditional(predicate: P.binary("==", b, .immediate(0)),
                    then: [.assign(destination: output, value: P.project(.immediate(0), 64))], otherwise: quotientEffects))
                return effects
            case let .load(destination, address, bytes, signed, delta):
                var effects: [Effect] = []
                let location = snapshot(address.value, into: &effects)
                let loaded = temporary()
                effects.append(.load(destination: loaded, address: location, byteWidth: bytes))
                if signed { effects += signExtend(loaded, destination: P.cell(destination.index)) }
                else { effects.append(.assign(destination: P.cell(destination.index), value: P.commit(loaded, width: destination.width))) }
                if let delta { effects.append(writeback(address.base, old: location, delta: delta)) }
                return effects
            case let .store(value, address, bytes, delta):
                var effects: [Effect] = []
                let location = snapshot(address.value, into: &effects)
                let data = snapshot(P.read(value), into: &effects)
                effects.append(.store(value: P.project(data, bytes * 8), address: location, byteWidth: bytes))
                if let delta { effects.append(writeback(address.base, old: location, delta: delta)) }
                return effects
            case let .pair(first, second, address, load):
                var effects: [Effect] = []
                let location = snapshot(address.value, into: &effects)
                let secondLocation = P.project(P.binary("+", location, P.project(.immediate(Int64(first.width / 8)), 64)), 64)
                if load {
                    let firstValue = temporary(), secondValue = temporary()
                    effects += [.load(destination: firstValue, address: location, byteWidth: first.width / 8),
                        .load(destination: secondValue, address: secondLocation, byteWidth: second.width / 8),
                        .assign(destination: P.cell(first.index), value: P.commit(firstValue, width: first.width)),
                        .assign(destination: P.cell(second.index), value: P.commit(secondValue, width: second.width))]
                } else {
                    let firstValue = snapshot(P.read(first), into: &effects)
                    let secondValue = snapshot(P.read(second), into: &effects)
                    effects += [.store(value: P.project(firstValue, first.width), address: location, byteWidth: first.width / 8),
                        .store(value: P.project(secondValue, second.width), address: secondLocation, byteWidth: second.width / 8)]
                }
                return effects
            }
        }
        private func writeback(_ base: Register, old: MacIRValue, delta: Int64) -> Effect {
            .assign(destination: P.cell(base.index), value: P.project(P.binary("+", old,
                P.project(.immediate(delta), 64)), 64))
        }
    }
}
