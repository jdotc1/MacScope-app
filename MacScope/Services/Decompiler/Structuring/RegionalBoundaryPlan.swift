import Foundation

/// One immutable reconciliation result, computed at most once across function
/// copies. Equality-only producer replays never request it. The lock also keeps
/// concurrent readers from lifting duplicate twins; producer inputs are released
/// as soon as the marker/difference result has been published.
final class RegionalReconciliationEvidence: @unchecked Sendable {
    struct Result: Sendable {
        let markers: [RegionalLexicalProof.Marker]
        let nonMarkerDifference: Bool
    }

    private let lock = NSLock()
    private var result: Result?
    private var produce: (@Sendable () -> Result)?

    init(result: Result) {
        self.result = result
    }

    init(produce: @escaping @Sendable () -> Result) {
        self.produce = produce
    }

    func resolve() -> Result {
        lock.lock()
        defer { lock.unlock() }
        if let result { return result }
        guard let produce else {
            // No missing producer may turn into lexical admission.
            return Result(markers: [], nonMarkerDifference: true)
        }
        let resolved = produce()
        result = resolved
        self.produce = nil
        return resolved
    }
}

/// A read cell certified at an original source address, including its width.
struct RegionalProvedPosition: Hashable, Sendable {
    let address: UInt64
    let register: Int
    let width: Int
}

/// Transient evidence never participates in semantic equality or hashing.
/// MacIRFunction is not Codable; this wrapper supplies no persistence conformance.
@propertyWrapper
struct RegionalNonSemantic<Value: Sendable>: Hashable, Sendable {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// A candidate reconstructed solely from operand records. Deferred construction
/// releases producer inputs and the lexical twin after recording their difference.
/// Planners must cover every record before this candidate can reach emission.
struct RegionalLexicalProof: Sendable {
    struct Marker: Sendable {
        let instruction: Int
        let operand: String
        let position: RegionalProvedPosition
        let lexicalValue: MacIRValue
    }

    let function: MacIRFunction
    let markers: [Marker]

    static func record(reconciled: inout MacIRFunction, lexical: MacIRFunction) {
        var difference = Difference()
        var repaired = reconciled
        var repairedInstructions = repaired.instructions
        var nonMarkerDifference = reconciled.instructions.count != lexical.instructions.count
        for index in reconciled.instructions.indices where lexical.instructions.indices.contains(index) {
            let original = reconciled.instructions[index]
            let twin = lexical.instructions[index]
            difference.row = index
            difference.address = original.source.address
            difference.mnemonic = original.source.mnemonic
            difference.operands = original.source.operands
            if let operation = difference.operation(original.operation, twin.operation) {
                repairedInstructions[index].operation = operation
                if repairedInstructions[index] != twin {
                    nonMarkerDifference = true
                }
            } else {
                nonMarkerDifference = true
            }
        }
        repaired.instructions = repairedInstructions
        reconciled.reconciliationEvidence = RegionalReconciliationEvidence(result: .init(
            markers: difference.markers, nonMarkerDifference: nonMarkerDifference || repaired != lexical))
    }

    init?(reconciled: MacIRFunction) {
        guard !reconciled.nonMarkerDifference, !reconciled.reconciliationMarkers.isEmpty else { return nil }
        var difference = Difference()
        difference.replay = reconciled.reconciliationMarkers
        var repaired = reconciled
        var repairedInstructions = repaired.instructions
        for index in reconciled.instructions.indices {
            let original = reconciled.instructions[index]
            difference.row = index
            difference.address = original.source.address
            difference.mnemonic = original.source.mnemonic
            difference.operands = original.source.operands
            guard let operation = difference.operation(original.operation, original.operation) else { return nil }
            repairedInstructions[index].operation = operation
        }
        guard difference.markers.count == reconciled.reconciliationMarkers.count else { return nil }
        repaired.instructions = repairedInstructions
        function = repaired
        markers = difference.markers
    }

    /// Apply the same post-processing to both candidates, then retain only the
    /// new operand records. A prior non-marker difference can never be erased.
    static func projecting(_ original: MacIRFunction,
                           using transform: (MacIRFunction) -> MacIRFunction) -> MacIRFunction {
        var result = transform(original)
        guard !original.nonMarkerDifference else {
            result.nonMarkerDifference = true
            return result
        }
        guard !original.reconciliationMarkers.isEmpty else { return result }
        guard let proof = Self(reconciled: original) else {
            result.nonMarkerDifference = true
            return result
        }
        record(reconciled: &result, lexical: transform(proof.function))
        return result
    }

    func isCovered(by positions: Set<RegionalProvedPosition>) -> Bool {
        !function.nonMarkerDifference && Set(markers.map(\.position)).isSubset(of: positions)
    }

    /// Extend an existing decoded read proof through a unique NZCV owner.
    /// Unsupported rows, calls and memory effects are barriers: the CFG has no
    /// exception-edge representation, so potentially exceptional paths are not
    /// assumed to preserve ownership. This is stronger than consumer inventory.
    static func flagPositions(function: MacIRFunction, cfg: CFG,
                              provedReads: Set<RegionalProvedPosition>) -> Set<RegionalProvedPosition> {
        let records = function.reconciliationMarkers
        let instructions = function.instructions
        let consumers = records.filter { marker in
            instructions.indices.contains(marker.instruction)
                && instructions[marker.instruction].source.mnemonic.hasPrefix("b.")
        }
        guard !function.nonMarkerDifference, !consumers.isEmpty else { return [] }
        let transparent: Set<String> = ["mov", "adr", "adrp", "add", "sub", "and", "orr", "eor",
            "mul", "msub", "lsl", "lsr", "sxtw", "b", "cbz", "cbnz", "tbz", "tbnz"]
        let barriers = Set(instructions.indices.filter { index in
            let instruction = instructions[index]
            let mnemonic = instruction.source.mnemonic
            return instruction.memoryAccess != nil
                || (!transparent.contains(mnemonic) && !mnemonic.hasPrefix("b."))
        })
        guard let origins = RegionalSingleCMPConditionPlan.analyze(
            rowCount: instructions.count, cfg: cfg, writerRows: barriers) else { return [] }
        let recordsByRow = Dictionary(grouping: records, by: \.instruction)
        struct Chain {
            let width: Int
            let writers: [Int]
        }
        var proven: [Int: Chain] = [:]
        var declined = Set<Int>()
        var visiting = Set<Int>()
        func chain(endingAt writer: Int) -> Chain? {
            if let result = proven[writer] { return result }
            guard !declined.contains(writer), visiting.insert(writer).inserted else { return nil }
            defer { visiting.remove(writer) }
            let instruction = instructions[writer]
            let mnemonic = instruction.source.mnemonic
            let conditional = mnemonic == "ccmp" || mnemonic == "ccmn"
            let arithmetic = mnemonic == "adds" || mnemonic == "subs"
            let parts = MacIRBuilder.splitOperands(instruction.source.operands)
            guard instruction.memoryAccess == nil,
                  conditional || arithmetic || ["cmp", "cmn", "tst"].contains(mnemonic),
                  parts.count == (conditional ? 4 : arithmetic ? 3 : 2),
                  let first = RegionalBoundaryPlan.Register(parts[0]) else {
                declined.insert(writer); return nil
            }
            let inputs = arithmetic ? Array(parts.dropFirst()) : Array(parts.prefix(2))
            for input in inputs {
                if let register = RegionalBoundaryPlan.Register(input) {
                    guard register.width == first.width,
                          register.index == 31 || provedReads.contains(RegionalProvedPosition(
                            address: instruction.source.address, register: register.index,
                            width: register.width)) else {
                        declined.insert(writer); return nil
                    }
                } else if MacIRBuilder.parseImmediate(input) == nil {
                    declined.insert(writer); return nil
                }
            }
            var writers = [writer]
            if conditional {
                guard let prior = origins.uniqueWriterWithoutInterveningWriter(before: writer),
                      let inherited = chain(endingAt: prior), inherited.width == first.width else {
                    declined.insert(writer); return nil
                }
                writers += inherited.writers
            }
            let result = Chain(width: first.width, writers: writers)
            proven[writer] = result
            return result
        }
        var result = Set<RegionalProvedPosition>()
        var refused = Set<RegionalProvedPosition>()
        for marker in consumers {
            guard let owner = origins.uniqueWriterWithoutInterveningWriter(before: marker.instruction),
                  let proof = chain(endingAt: owner), proof.width == marker.position.width,
                  proof.writers.contains(where: { writer in
                      (recordsByRow[writer] ?? []).contains(where: { read in
                          read.position.register == marker.position.register
                              && read.position.width == marker.position.width
                              && read.lexicalValue == marker.lexicalValue
                              && provedReads.contains(read.position)
                      })
                  }) else {
                refused.insert(marker.position)
                continue
            }
            result.insert(marker.position)
        }
        return result.subtracting(refused)
    }

    private struct Difference {
        var row = 0
        var address: UInt64 = 0
        var mnemonic = ""
        var operands = ""
        var markers: [Marker] = []
        var replay: [Marker]?

        mutating func value(_ original: MacIRValue, _ twin: MacIRValue, _ path: String) -> MacIRValue? {
            if let replay {
                if let marker = replay.first(where: { $0.instruction == row && $0.operand == path }) {
                    let position = marker.position
                    guard position.address == address,
                          original == .unknown("unavailable_\(position.width == 32 ? "w" : "x")\(position.register)") else { return nil }
                    markers.append(marker)
                    return marker.lexicalValue
                }
            } else if original == twin { return original }
            if replay == nil, case let .unknown(name) = original, name.hasPrefix("unavailable_") {
                let register = String(name.dropFirst("unavailable_".count))
                guard let view = MacIRBuilder.integerRegisterView(register), view.index < 30,
                      register == "\(view.width == 32 ? "w" : "x")\(view.index)",
                      !containsStackSlot(twin) else { return nil }
                markers.append(Marker(instruction: row, operand: path,
                    position: RegionalProvedPosition(address: address, register: view.index, width: view.width),
                    lexicalValue: twin))
                return twin
            }
            switch (original, twin) {
            case (.signedBitfield, _), (_, .signedBitfield):
                return original == twin ? original : nil
            case let (.unary(op, inner), .unary(other, replacement)) where op == other:
                guard let result = value(inner, replacement, path + ".value") else { return nil }
                return .unary(op: op, value: result)
            case let (.binaryExpression(op, left, right), .binaryExpression(other, lhs, rhs)) where op == other:
                guard let left = value(left, lhs, path + ".left"),
                      let right = value(right, rhs, path + ".right") else { return nil }
                return .binaryExpression(op: op, left: left, right: right)
            case let (.bitTest(inner, bit), .bitTest(replacement, other)) where bit == other:
                guard let result = value(inner, replacement, path + ".value") else { return nil }
                return .bitTest(value: result, bit: bit)
            default: return original == twin ? original : nil
            }
        }

        func containsStackSlot(_ value: MacIRValue) -> Bool {
            switch value {
            case .stackSlot: return true
            case let .signedBitfield(node): return containsStackSlot(node.source)
            case let .unary(_, inner), let .bitTest(inner, _): return containsStackSlot(inner)
            case let .binaryExpression(_, left, right): return containsStackSlot(left) || containsStackSlot(right)
            case let .abiComposite(_, fragments): return fragments.contains(where: containsStackSlot)
            default: return false
            }
        }

        mutating func operation(_ original: MacIROperation, _ twin: MacIROperation) -> MacIROperation? {
            if original == twin && replay == nil { return original }
            switch (original, twin) {
            case let (.assign(destination, source), .assign(other, replacement)) where destination == other:
                guard let source = value(source, replacement, "source") else { return nil }
                return .assign(destination: destination, source: source)
            case let (.binary(destination, op, left, right), .binary(other, otherOp, lhs, rhs))
                where destination == other && op == otherOp:
                guard let left = value(left, lhs, "left"), let right = value(right, rhs, "right") else { return nil }
                return .binary(destination: destination, op: op, left: left, right: right)
            case let (.load(destination, address), .load(other, replacement)) where destination == other:
                guard let address = value(address, replacement, "address") else { return nil }
                return .load(destination: destination, address: address)
            case let (.store(source, address), .store(replacement, otherAddress)):
                guard let source = value(source, replacement, "source"),
                      let address = value(address, otherAddress, "address") else { return nil }
                return .store(source: source, address: address)
            case let (.loadWriteback(destination, base, source, delta, pre),
                      .loadWriteback(other, otherBase, replacement, otherDelta, otherPre))
                where destination == other && base == otherBase && delta == otherDelta && pre == otherPre:
                guard let source = value(source, replacement, "baseSource") else { return nil }
                return .loadWriteback(destination: destination, baseDestination: base,
                    baseSource: source, delta: delta, preIndex: pre)
            case let (.storeWriteback(source, base, address, delta, pre),
                      .storeWriteback(replacement, otherBase, otherAddress, otherDelta, otherPre))
                where base == otherBase && delta == otherDelta && pre == otherPre:
                guard let source = value(source, replacement, "source"),
                      let address = value(address, otherAddress, "baseSource") else { return nil }
                return .storeWriteback(source: source, baseDestination: base,
                    baseSource: address, delta: delta, preIndex: pre)
            case let (.conditionalBranch(condition, left, right, target),
                      .conditionalBranch(other, lhs, rhs, otherTarget)) where condition == other && target == otherTarget:
                guard let left = value(left, lhs, "left"), let right = value(right, rhs, "right") else { return nil }
                return .conditionalBranch(condition: condition, left: left, right: right, target: target)
            case let (.select(destination, condition, left, right, yes, no),
                      .select(other, otherCondition, otherLeft, otherRight, otherYes, otherNo))
                where destination == other && condition == otherCondition && left == otherLeft && right == otherRight:
                // Only the selected data operands are direct reads here. Flag
                // expressions may describe an older register state.
                guard let yes = value(yes, otherYes, "trueValue"),
                      let no = value(no, otherNo, "falseValue") else { return nil }
                return .select(destination: destination, condition: condition, left: left,
                    right: right, trueValue: yes, falseValue: no)
            case let (.intrinsic(destination, name, arguments), .intrinsic(other, otherName, replacements))
                where destination == other && name == otherName && arguments.count == replacements.count:
                let inputs: Set<Int>
                switch name {
                case "compare" where destination == nil && arguments.count == 2
                    && ["cmp", "cmn", "tst"].contains(mnemonic): inputs = [0, 1]
                case let operation where ["ccmp", "ccmn"].contains(mnemonic):
                    let parts = MacIRBuilder.splitOperands(operands)
                    let conditions: Set<String> = ["eq", "ne", "hs", "cs", "lo", "cc", "mi", "pl",
                        "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]
                    guard destination == nil, arguments.count == 3, parts.count == 4,
                          let left = RegionalBoundaryPlan.Register(parts[0]),
                          (RegionalBoundaryPlan.Register(parts[1])?.width == left.width
                            || MacIRBuilder.parseImmediate(parts[1]) != nil),
                          let nzcv = MacIRBuilder.parseImmediate(parts[2]), (0..<16).contains(nzcv),
                          conditions.contains(parts[3]), operation == "conditional_compare_\(parts[3])",
                          arguments[2] == .immediate(nzcv), replacements[2] == arguments[2] else { return nil }
                    inputs = [0, 1]
                case "restore_pair" where destination == nil && arguments.count == 3: inputs = [2]
                case "save_pair" where destination == nil && arguments.count == 3: inputs = [0, 1, 2]
                case let operation where ["a64_sdiv32", "a64_udiv32"].contains(operation)
                    && destination != nil && arguments.count == 2: inputs = [0, 1]
                default: return original == twin ? original : nil
                }
                var repaired = arguments
                for index in arguments.indices {
                    if inputs.contains(index) {
                        guard let replacement = value(arguments[index], replacements[index], "arguments[\(index)]") else { return nil }
                        repaired[index] = replacement
                    } else if arguments[index] != replacements[index] { return nil }
                }
                return .intrinsic(destination: destination, name: name, arguments: repaired)
            default:
                // Calls, returns, other intrinsics, stack cache operations, typed
                // switches and unsupported effects require complete equality.
                return original == twin ? original : nil
            }
        }
    }
}

/// Event-local bridges between decoded physical cells and the unchanged opaque
/// operations. This is deliberately not a substitution map for legacy SSA.
struct RegionalBoundaryPlan {
    struct Register: Hashable {
        let index: Int
        let width: Int
        var isZero: Bool { index == 31 }

        init(index: Int, width: Int) { self.index = index; self.width = width }
        init?(_ text: String) {
            guard let prefix = text.first, prefix == "x" || prefix == "w" else { return nil }
            width = prefix == "x" ? 64 : 32
            if text == "xzr" || text == "wzr" { index = 31; return }
            guard let number = Int(text.dropFirst()), (0..<30).contains(number),
                  text == "\(prefix)\(number)" else { return nil }
            index = number
        }
    }

    struct Entry {
        let register: Register
        let value: MacIRValue
        let type: String
        let pointerBits: Bool
    }
    struct Alias: Hashable {
        let value: MacIRValue
        let register: Register
        let type: String

        /// A persisted architectural view is an observation of its SSA storage,
        /// never a destination that may be declared or assigned.
        var projectedStorage: MacIRValue? {
            switch value {
            case let .unary("(uint32_t)", storage): return storage
            case let .unary("(uint64_t)", .unary("(uint32_t)", storage)): return storage
            default: return nil
            }
        }
    }
    struct Call {
        let row: Int
        let original: MacIRInstruction
        let frame: MacIRCallFrame
        let inputs: [Alias]
        let result: Alias?
        /// Current pre-event cells, never entry snapshots or historical atoms.
        var retainedRegisters: Set<Int> = []
        // Default-off native bridge. These remain original materialized aliases;
        // the typed call retains its own canonical W-to-X argument projection.
        var nativeFixedIntegerInputs = false
        var nativeZeroExtendedInputs: Set<MacIRValue> = []
    }
    struct Terminal {
        let row: Int
        let exportRow: Int
        let alias: Alias
    }
    enum EventKind {
        case entryImport, callInputMaterialization, existingOpaqueResultImport
        case retainedSnapshotRelation, terminalObservationExport
    }
    struct Event {
        let kind: EventKind
        let row: Int
        let atom: MacIRValue?
        let register: Register
    }

    let entries: [Entry]
    var calls: [Int: Call]
    let terminal: Terminal?
    let exteriorRows: Set<Int>
    let terminalRows: Set<Int>
    let prefixEnd: Int
    /// First restore of the unique terminal interval, not a lexical suffix.
    let suffixStart: Int
    let aliases: [Alias]
    let originalAtoms: Set<MacIRValue>
    private let originalFunction: MacIRFunction
    /// Only declarations already admitted by this plan may enter native replay.
    private let nativeCallSignatures: [String: MacIRCallSignature]

    var aliasValues: Set<MacIRValue> { Set(aliases.map(\.value)) }
    var callRows: Set<Int> { Set(calls.keys) }
    var originalRows: Set<Int> { exteriorRows.union(callRows) }
    var events: [Event] {
        var result = entries.map { Event(kind: .entryImport, row: 0,
            atom: $0.value, register: $0.register) }
        for index in calls.keys.sorted() {
            guard let call = calls[index] else { continue }
            result += call.inputs.map { Event(kind: .callInputMaterialization,
                row: index, atom: $0.value, register: $0.register) }
            if let output = call.result {
                result.append(Event(kind: .existingOpaqueResultImport,
                    row: index, atom: output.value, register: output.register))
            }
            result += call.retainedRegisters.sorted().map {
                Event(kind: .retainedSnapshotRelation, row: index, atom: nil,
                    register: Register(index: $0, width: 64))
            }
        }
        if let terminal {
            result.append(Event(kind: .terminalObservationExport, row: terminal.exportRow,
                atom: terminal.alias.value, register: terminal.alias.register))
        }
        return result
    }

    func matches(function: MacIRFunction) -> Bool { originalFunction == function }

    enum FlagConsumer: Hashable {
        case control(Int)
        case value(MacIRValue)
    }

    /// A printed definition is not result-use authority. Follow only known
    /// original read operands through pure value definitions to an observable
    /// consumer. The printer additionally witnesses each edge in the original
    /// sourced text. Dead copies, declaration names and defining LHSs do not
    /// establish a use; unsupported operations do not establish one either.
    func hasOriginalObservableUse(of value: MacIRValue,
                                  flagConsumers: [Int: Set<FlagConsumer>],
                                  readWitness: (Int, MacIRValue?) -> Bool) -> Bool {
        var pending = [value]
        var visited: Set<MacIRValue> = []
        while let atom = pending.popLast() {
            guard visited.insert(atom).inserted else { continue }
            if originalFunction.ssaEnabled {
                for phi in originalFunction.phis where (phi.cell ?? 0) < 96 {
                    var incomingAtoms: Set<MacIRValue> = []
                    phi.incoming.forEach { Self.collectAtoms($0.value, into: &incomingAtoms) }
                    if incomingAtoms.contains(atom) { pending.append(phi.destination) }
                }
            }
            for (index, instruction) in originalFunction.instructions.enumerated() {
                let inputs: [MacIRValue]
                let outputs: [MacIRValue]
                let observable: Bool
                switch instruction.operation {
                case let .assign(destination, source):
                    inputs = [source]; outputs = [destination]; observable = false
                case let .binary(destination, _, left, right):
                    inputs = [left, right]; outputs = [destination]; observable = false
                case let .select(destination, _, left, right, yes, no):
                    inputs = [left, right, yes, no]; outputs = [destination]; observable = false
                case let .compareToBool(destination, _, left, right):
                    inputs = [left, right]; outputs = [destination]; observable = false
                case let .load(_, address):
                    inputs = [address]; outputs = []; observable = true
                case let .store(source, address):
                    inputs = [source, address]; outputs = []; observable = true
                case let .loadWriteback(_, _, base, _, _):
                    inputs = [base]; outputs = []; observable = true
                case let .storeWriteback(source, _, base, _, _):
                    inputs = [source, base]; outputs = []; observable = true
                case let .call(frame, _):
                    inputs = frame.bindingValues; outputs = []; observable = true
                case let .conditionalBranch(_, left, right, target):
                    inputs = [left, right, target]; outputs = []; observable = true
                case let .returnValue(returned):
                    inputs = returned.map { [$0] } ?? []; outputs = []; observable = true
                case let .intrinsic(nil, "compare", arguments) where flagConsumers[index] != nil:
                    // The original printed NZCV effect already consumes these
                    // values. Bridge only certified flag reads before a kill,
                    // then require their original printed observable use. A
                    // compare followed by only a dead select is insufficient.
                    let consumers = flagConsumers[index] ?? []
                    inputs = arguments
                    outputs = consumers.compactMap {
                        if case let .value(value) = $0 { return value }; return nil
                    }
                    observable = consumers.contains {
                        if case let .control(row) = $0 { return readWitness(row, nil) }; return false
                    }
                default:
                    continue
                }
                var reads: Set<MacIRValue> = []
                inputs.forEach { Self.collectAtoms($0, into: &reads) }
                guard reads.contains(atom), readWitness(index, atom) else { continue }
                if observable { return true }
                for output in outputs {
                    switch output {
                    case .register, .temporary: pending.append(output)
                    default: break
                    }
                }
            }
        }
        return false
    }

    static func prove(function: MacIRFunction, cfg: CFG) -> Self? {
        prove(function: function, cfg: cfg, admitNativeFixedIntegerCalls: false)
    }

    static func prove(function: MacIRFunction, cfg: CFG,
                      admitNativeFixedIntegerCalls: Bool) -> Self? {
        let rows = function.instructions
        guard !rows.isEmpty, !function.isVariadic, !function.isNoReturn,
              !function.observesFPSR, (function.phis.isEmpty || function.ssaEnabled),
              function.localVariables.isEmpty,
              (function.callSignatures.isEmpty || (admitNativeFixedIntegerCalls && !function.ssaEnabled)),
              Set(function.parameters.map(\.name)).count == function.parameters.count,
              Set(function.parameters.map(\.id)).count == function.parameters.count,
              Set(function.parameters.compactMap(\.bindingID)).count == function.parameters.count,
              !cfg.blocks.isEmpty, cfg.entryIndex == 0,
              cfg.blocks[0].predecessors.isEmpty else { return nil }

        if function.ssaEnabled {
            let addresses = Dictionary(uniqueKeysWithValues: cfg.blocks.map {
                (rows[$0.startIndex].source.address, $0.index)
            })
            guard Set(function.phis.map(\.destination)).count == function.phis.count,
                  function.phis.allSatisfy({ phi in
                      guard let block = addresses[phi.blockAddress] else { return false }
                      let predecessors = cfg.blocks[block].predecessors.map {
                          rows[cfg.blocks[$0].endIndex - 1].source.address
                      }
                      return phi.incoming.map(\.machineAddress) == predecessors.map { Optional($0) }
                  }) else { return nil }
        }
        // The typed CFG terminal, not source-stream order, owns return authority.
        // Cold blocks after this interval remain ordinary body blocks.
        let returns = rows.indices.filter {
            if case .returnValue = rows[$0].operation { return true }; return false
        }
        guard returns.count == 1, let returnRow = returns.first,
              rows.indices.filter({ rows[$0].source.mnemonic == "ret" }) == returns,
              rows[returnRow].source.operands.isEmpty,
              case let .returnValue(returned) = rows[returnRow].operation,
              returned == function.returnValue else { return nil }
        let returnBlocks = cfg.blocks.filter { $0.instructionRange.contains(returnRow) }
        guard returnBlocks.count == 1, let returnBlock = returnBlocks.first,
              returnBlock.endIndex == returnRow + 1,
              returnBlock.successors.isEmpty else { return nil }

        var entries: [Entry] = []
        for parameter in function.parameters {
            guard parameter.richLocation == nil,
                  case let .gpr(index, width) = parameter.abiLocation,
                  (0..<8).contains(index), [32, 64].contains(width),
                  parameter.bindingID == .gpr(index),
                  let register = Register(parameter.register), register.index == index,
                  register.width == width else { return nil }
            let integer = (width == 32 ? ["int32_t", "uint32_t"] : ["int64_t", "uint64_t"])
                .contains(parameter.type)
            let authoritative = parameter.evidence == .authoritativeUser || parameter.evidence == .authoritativeDebug
            // This bridge is explicitly for the existing AArch64 GPR/64 pointer
            // representation. It supplies no field, pointee, or callee semantics.
            let pointer = width == 64 && authoritative && supportedPointer(parameter.type)
            guard integer || pointer else { return nil }
            entries.append(Entry(register: register, value: .argument(bindingID: .gpr(index)),
                type: parameter.type, pointerBits: pointer))
        }

        var prefixEnd = 0
        while prefixEnd < rows.count, isStackPair(rows[prefixEnd], load: false) { prefixEnd += 1 }
        if prefixEnd < rows.count, isFrameSetup(rows[prefixEnd]) { prefixEnd += 1 }
        var suffixStart = returnRow
        while suffixStart > prefixEnd, isStackPair(rows[suffixStart - 1], load: true) { suffixStart -= 1 }
        guard prefixEnd < suffixStart,
              prefixEnd <= cfg.blocks[0].endIndex,
              returnBlock.startIndex <= suffixStart,
              !cfg.blocks.contains(where: { $0.startIndex > suffixStart && $0.startIndex <= returnRow }) else {
            return nil
        }
        // No incoming edge may enter after the first restore, including RET.
        // The ordinary physical plan still validates bytes and complete CFG.
        let exterior = Set(0..<prefixEnd).union(suffixStart...returnRow)
        let terminalRows = Set([returnRow])
        var terminal: Terminal?
        if let returned {
            guard function.returnType == "int64_t" || function.returnType == "int32_t",
                  let alias = alias(returned, register: nil, function: function),
                  alias.register.index == 0 else { return nil }
            terminal = Terminal(row: returnRow, exportRow: suffixStart, alias: alias)
        } else {
            guard function.returnType == "void" else { return nil }
        }

        var calls: [Int: Call] = [:]
        var nativeSignatures: [String: MacIRCallSignature] = [:]
        var aliasesByValue: [MacIRValue: Alias] = [:]
        if let terminal { aliasesByValue[terminal.alias.value] = terminal.alias }
        for index in rows.indices where !exterior.contains(index) {
            let instruction = rows[index]
            if case let .call(frame, result) = instruction.operation {
                guard ["bl", "blr"].contains(instruction.source.mnemonic),
                      frame.tailCountEvidence == nil,
                      frame.richArguments == nil, frame.indirectResultPointer == nil,
                      instruction.memoryAccess == nil else { return nil }
                let native: NativeFixedIntegerInputs?
                if let signature = frame.knownSignature {
                    guard admitNativeFixedIntegerCalls,
                          instruction.source.mnemonic == "bl",
                          let admitted = nativeFixedIntegerCallInputs(frame: frame, result: result,
                              function: function) else { return nil }
                    if let prior = nativeSignatures[signature.target], prior != signature { return nil }
                    nativeSignatures[signature.target] = signature
                    native = admitted
                } else {
                    guard frame.arguments.observationScope.canonicalGPRIndicesForAudit == Array(0..<8),
                          frame.arguments.observationScope.canonicalScalarSIMDIndicesForAudit.isEmpty,
                          frame.arguments.observationScope.canonicalCallStackRangesForAudit.isEmpty else { return nil }
                    native = nil
                }
                var inputs: [Alias] = native?.inputs ?? []
                let controls = frame.controlInputs.canonicalControlInputsForAudit
                if instruction.source.mnemonic == "blr" {
                    guard controls.count == 1, let control = controls.first,
                          control.role == .indirectTarget,
                          let registerName = control.register.registerName,
                          let register = Register(registerName), register.width == 64, !register.isZero else { return nil }
                    guard instruction.source.operands == registerName,
                          frame.target == "(*\(registerName))" else {
                        RegionalRefusalRecorder.contradict("call-indirect-target")
                        return nil
                    }
                    guard let input = alias(control.value, register: register, function: function) else { return nil }
                    inputs.append(input)
                } else {
                    // The original symbolic identity is preserved; encoded PC
                    // agreement is checked independently by the physical plan.
                    guard controls.isEmpty else { return nil }
                    guard instruction.source.operands == frame.target else {
                        RegionalRefusalRecorder.contradict("call-symbolic-target")
                        return nil
                    }
                }
                for argument in native == nil ? frame.arguments.canonicalPhysicalEntriesForAudit : [] {
                    guard argument.role == .unknown, argument.selectorEvidence == nil,
                          case let .gpr(register, width) = argument.location,
                          (0..<8).contains(register), [32, 64].contains(width),
                          let input = alias(argument.value,
                            register: Register(index: register, width: width), function: function) else { return nil }
                    inputs.append(input)
                }
                let output: Alias?
                if let result {
                    guard let proved = alias(result, register: Register(index: 0, width: 64),
                        function: function) else {
                        RegionalRefusalRecorder.contradict("call-result-alias")
                        return nil
                    }
                    output = proved
                } else {
                    output = nil // A statement-only call never acquires a result.
                }
                for binding in inputs + (output.map { [$0] } ?? []) {
                    if let prior = aliasesByValue[binding.value], prior != binding {
                        RegionalRefusalRecorder.contradict("call-alias-rebound")
                        return nil
                    }
                    aliasesByValue[binding.value] = binding
                }
                guard Set(inputs.map(\.value)).count == inputs.count else { return nil }
                var call = Call(row: index, original: instruction, frame: frame,
                    inputs: inputs, result: output)
                call.nativeFixedIntegerInputs = native != nil
                call.nativeZeroExtendedInputs = native?.zeroExtended ?? []
                calls[index] = call
            }
        }
        guard Set(function.callSignatures) == Set(nativeSignatures.values),
              function.callSignatures.count == nativeSignatures.count else { return nil }
        guard !calls.isEmpty else {
            RegionalRefusalRecorder.inapplicable("no-calls")
            return nil
        }

        // A retained exterior operation may not observe a rebound historical
        // alias. All other retained consumers are the registered call roles or
        // the one terminal role. Replaced scalar consumers have no old authority.
        let materialized = Set(aliasesByValue.keys)
        var originalAtoms: Set<MacIRValue> = []
        for (index, instruction) in rows.enumerated() {
            guard let values = values(instruction.operation) else { return nil }
            var atoms: Set<MacIRValue> = []
            values.forEach { collectAtoms($0, into: &atoms) }
            originalAtoms.formUnion(atoms)
            if exterior.contains(index), !terminalRows.contains(index),
               !atoms.isDisjoint(with: materialized) {
                RegionalRefusalRecorder.contradict("exterior-observes-rebound-alias")
                return nil
            }
        }
        entries.forEach { originalAtoms.insert($0.value) }
        if function.ssaEnabled {
            for phi in function.phis where (phi.cell ?? 0) < 96 {
                collectAtoms(phi.destination, into: &originalAtoms)
                phi.incoming.forEach { collectAtoms($0.value, into: &originalAtoms) }
            }
        }
        return Self(entries: entries, calls: calls, terminal: terminal,
            exteriorRows: exterior, terminalRows: terminalRows, prefixEnd: prefixEnd,
            suffixStart: suffixStart,
            aliases: aliasesByValue.values.sorted { $0.value.description < $1.value.description },
            originalAtoms: originalAtoms, originalFunction: function,
            nativeCallSignatures: nativeSignatures)
    }

    private struct NativeFixedIntegerInputs {
        let inputs: [Alias]
        let zeroExtended: Set<MacIRValue>
    }

    /// Shape admission only. The physical plan must additionally prove each
    /// alias is the current same-block decoded load, before publishing a plan.
    /// This is not a general known-call or declaration-reconstruction route.
    private static func nativeFixedIntegerCallInputs(frame: MacIRCallFrame,
        result: MacIRValue?, function: MacIRFunction) -> NativeFixedIntegerInputs? {
        guard !function.ssaEnabled, let signature = frame.knownSignature,
              signature.source == "authored-declaration", signature.target == frame.target,
              !signature.isVariadic, signature.format == nil,
              signature.returnType == "int64_t", signature.parameters.count == 2,
              signature.parameters.enumerated().allSatisfy({ index, parameter in
                  parameter.index == index && parameter.register == "x\(index)" && parameter.type == "int64_t"
              }),
              frame.typedIndirectSignature == nil, frame.typedIndirectCalleeType == nil,
              frame.tailCountEvidence == nil, frame.richArguments == nil,
              frame.indirectResultPointer == nil, frame.unknownArgumentCount == nil,
              frame.controlInputs.canonicalControlInputsForAudit.isEmpty,
              frame.arguments.observationScope == .none,
              let result, alias(result, register: Register(index: 0, width: 64), function: function) != nil else { return nil }
        let arguments = frame.arguments.canonicalPhysicalEntriesForAudit
        guard arguments.count == 2 else { return nil }
        var inputs: [Alias] = [], zeroExtended: Set<MacIRValue> = []
        for (index, argument) in arguments.enumerated() {
            guard argument.role == .fixed(sourcePosition: index), argument.selectorEvidence == nil,
                  argument.location == .gpr(index: index, carrierWidth: 64) else { return nil }
            let storage: MacIRValue, width: Int
            if case let .unary("(uint64_t)", .unary("(uint32_t)", value)) = argument.value {
                guard index == 0 else { return nil }
                storage = value; width = 32
                zeroExtended.insert(value)
            } else {
                storage = argument.value; width = 64
            }
            guard let input = alias(storage, register: Register(index: index, width: width),
                function: function) else { return nil }
            inputs.append(input)
        }
        return NativeFixedIntegerInputs(inputs: inputs, zeroExtended: zeroExtended)
    }

    /// Replay the declarations of this exact admitted native boundary, not an
    /// arbitrary signature map. Full producer equality remains mandatory.
    func producerCorrespondence(typedSwitches: [Int: RegionalTypedSwitchPlan] = [:],
                                lexicalProof: RegionalLexicalProof? = nil) -> Bool {
        if nativeCallSignatures.isEmpty {
            return Self.producerCorrespondence(originalFunction,
                typedSwitches: typedSwitches, lexicalProof: lexicalProof)
        }
        guard !originalFunction.ssaEnabled,
              Set(originalFunction.callSignatures) == Set(nativeCallSignatures.values),
              originalFunction.callSignatures.count == nativeCallSignatures.count else { return false }
        let authored = nativeCallSignatures.mapValues { signature in
            FunctionSignatureOverride(returnType: signature.returnType,
                args: signature.parameters.map {
                    ArgOverride(index: $0.index, name: $0.name, type: $0.type)
                })
        }
        return Self.producerCorrespondence(originalFunction, typedSwitches: typedSwitches,
            lexicalProof: lexicalProof, authoredCallSignaturesByTarget: authored)
    }

    /// Replay only the supported already-applied declaration authority. When
    /// typedSwitches is nonempty, case-derived tables are a MODEL-RELATIVE input
    /// projection, not recovered original jump-table context or table-byte proof.
    /// The independent certificate establishes selector/current-cell agreement;
    /// replay cannot establish it. Full result equality compares every output
    /// field, including all unchanged typed switch operations and sidecars.
    static func producerCorrespondence(_ function: MacIRFunction,
        typedSwitches: [Int: RegionalTypedSwitchPlan] = [:],
        lexicalProof: RegionalLexicalProof? = nil) -> Bool {
        producerCorrespondence(function, typedSwitches: typedSwitches,
            lexicalProof: lexicalProof, authoredCallSignaturesByTarget: [:])
    }

    private static func producerCorrespondence(_ function: MacIRFunction,
        typedSwitches: [Int: RegionalTypedSwitchPlan], lexicalProof: RegionalLexicalProof?,
        authoredCallSignaturesByTarget: [String: FunctionSignatureOverride]) -> Bool {
        if function.ssaEnabled {
            let agrees = function.ssaOriginalInstructions == function.instructions
                && function.ssaOriginalPhis == function.phis
            if !agrees { RegionalRefusalRecorder.contradict("ssa-original-record-disagrees") }
            return agrees
        }
        // Build-time records were derived with the actual producer inputs.
        // Post-processing preserves their exact difference contract.
        if let lexicalProof {
            return lexicalProof.function == function
        }
        guard let modelRelativeTables = RegionalTypedSwitchPlan.modelRelativeJumpTables(
            function: function, plans: typedSwitches) else { return false }
        let authoritative = function.parameters.contains {
            $0.evidence == .authoritativeUser || $0.evidence == .authoritativeDebug
        }
        let rows = function.instructions.map { SourceRow(source: $0.source) }
        if authoritative {
            guard let plan = MacIRAuthoritativeParameterPlan(parameters: function.parameters,
                isVariadic: function.isVariadic) else { return false }
            let location: DarwinARM64RichReturnLocation
            switch function.returnType {
            case "void": location = .void
            case "int64_t", "uint64_t": location = .single(.gpr(index: 0, carrierWidth: 64))
            case "int32_t", "uint32_t": location = .single(.gpr(index: 0, carrierWidth: 32))
            default: return false
            }
            var replay = MacIRBuilder().buildFunction(name: function.name,
                startAddress: function.startAddress, jumpTables: modelRelativeTables, authoritativeParameterPlan: plan,
                authoritativeReturnLocation: location, authoritativeReturnType: function.returnType,
                authoredCallSignaturesByTarget: authoredCallSignaturesByTarget, instructions: rows)
            // Exact declaration replay of PseudocodePrinter.applying(_:to:)
            // (pinned source lines 3002-3006), called by buildFunction after
            // the same authoritative lift (lines 2877-2879). Builder alone
            // does not install this declaration. No other field is normalized.
            replay.returnType = function.returnType
            return replay == function
        }
        return MacIRBuilder().buildFunction(name: function.name, startAddress: function.startAddress,
            jumpTables: modelRelativeTables,
            authoredCallSignaturesByTarget: authoredCallSignaturesByTarget, instructions: rows) == function
    }

    private struct SourceRow: DecompilerInstructionRow {
        let source: MacIRSourceSpan
        var address: UInt64 { source.address }
        var bytes: String { source.byteText }
        var mnemonic: String { source.mnemonic }
        var operands: String { source.operands }
        var comment: String? { source.comment }
        var structuredOperands: InstructionOperands? { source.structuredOperands }
    }

    private static func supportedPointer(_ type: String) -> Bool {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == type, trimmed.hasSuffix("*"),
              !trimmed.contains("("), !trimmed.contains(")"), !trimmed.contains("["),
              !trimmed.contains("\n"), !trimmed.contains(";") else { return false }
        return trimmed.dropLast().contains(where: { $0.isLetter })
    }

    private static func alias(_ value: MacIRValue, register required: Register?,
                              function: MacIRFunction) -> Alias? {
        if function.ssaEnabled {
            let storage: MacIRValue?
            let projectedWidth: Int
            switch value {
            case let .unary("(uint32_t)", underlying):
                storage = underlying; projectedWidth = 32
            case let .unary("(uint64_t)", .unary("(uint32_t)", underlying)):
                storage = underlying; projectedWidth = 64
            default:
                storage = nil; projectedWidth = 0
            }
            if let storage {
                guard case let .register(name, _) = storage,
                      let original = Register(name),
                      let phi = function.phis.first(where: { $0.destination == storage }),
                      phi.cell == original.index, phi.scalarView == .integer,
                      phi.bitWidth == original.width,
                      projectedWidth == 32 || phi.bitWidth == 32 else { return nil }
                let projected = Register(index: original.index, width: projectedWidth)
                guard required == nil || required == projected else { return nil }
                return Alias(value: value, register: projected, type: "int\(projectedWidth)_t")
            }
        }
        // A literal formal would require an unchanged-entry witness. Do not
        // materialize it by assigning to or shadowing the formal.
        guard case let .register(name, version) = value,
              (version > 0 || (function.ssaEnabled && function.phis.contains { $0.destination == value })),
              let register = Register(name), !register.isZero,
              required == nil || required == register else { return nil }
        let type = register.width == 32 ? "int32_t" : "int64_t"
        let bindings = function.nameBindings.filter { $0.target == .register(name: name, version: version) }
        guard bindings.count <= 1, bindings.first?.type == nil || bindings.first?.type == type else { return nil }
        return Alias(value: value, register: register, type: type)
    }

    private static func isStackPair(_ instruction: MacIRInstruction, load: Bool) -> Bool {
        let source = instruction.source
        guard source.mnemonic == (load ? "ldp" : "stp") else { return false }
        let operands = MacIRBuilder.splitOperands(source.operands)
        guard (3...4).contains(operands.count),
              operands[2].hasPrefix("[sp"),
              let first = exteriorRegister(operands[0]), let second = exteriorRegister(operands[1]),
              first != second, (!load || (first != 0 && second != 0)),
              case let .intrinsic(nil, name, _) = instruction.operation,
              (load ? ["restore_pair", "restore_pair_writeback"] : ["save_pair", "save_pair_writeback"])
                .contains(name),
              instruction.memoryAccess == MacIRMemoryAccess(byteWidth: 8, extensionKind: .none) else { return false }
        return true
    }
    private static func exteriorRegister(_ name: String) -> Int? {
        guard name.hasPrefix("x"), let index = Int(name.dropFirst()),
              (0...30).contains(index), name == "x\(index)" else { return nil }
        return index
    }
    private static func isFrameSetup(_ instruction: MacIRInstruction) -> Bool {
        let operands = MacIRBuilder.splitOperands(instruction.source.operands)
        guard instruction.source.mnemonic == "add", operands.count == 3,
              operands[0] == "x29", operands[1] == "sp",
              MacIRBuilder.parseImmediate(operands[2]) != nil,
              case .binary = instruction.operation, instruction.memoryAccess == nil else { return false }
        return true
    }

    static func values(_ operation: MacIROperation) -> [MacIRValue]? {
        switch operation {
        case let .assign(destination, source): return [destination, source]
        case let .binary(destination, _, left, right): return [destination, left, right]
        case let .load(destination, address): return [destination, address]
        case let .store(source, address): return [source, address]
        case let .loadWriteback(destination, baseDestination, baseSource, _, _): return [destination, baseDestination, baseSource]
        case let .storeWriteback(source, baseDestination, baseSource, _, _): return [source, baseDestination, baseSource]
        case let .call(frame, result): return frame.bindingValues + (result.map { [$0] } ?? [])
        case let .conditionalBranch(_, left, right, target): return [left, right, target]
        case let .select(destination, _, left, right, yes, no): return [destination, left, right, yes, no]
        case let .compareToBool(destination, _, left, right): return [destination, left, right]
        case let .returnValue(value): return value.map { [$0] } ?? []
        case let .switchDispatch(selector, cases, defaultTarget):
            // Inventory only. Control labels do not become observable data-use
            // authority; hasOriginalObservableUse deliberately stays unchanged.
            return [selector] + cases.map(\.target) + (defaultTarget.map { [$0] } ?? [])
        case let .intrinsic(destination, _, arguments): return (destination.map { [$0] } ?? []) + arguments
        case let .unknown(destination, inputs, _, _):
            return (destination.map { [$0] } ?? []) + inputs.mayRead.map(\.value) + inputs.definiteRead.map(\.value)
        default: return nil
        }
    }
    static func collectAtoms(_ value: MacIRValue, into result: inout Set<MacIRValue>) {
        switch value {
        case .register, .argument, .temporary: result.insert(value)
        case let .signedBitfield(node): collectAtoms(node.source, into: &result)
        case let .unary(_, value), let .bitTest(value, _): collectAtoms(value, into: &result)
        case let .binaryExpression(_, left, right):
            collectAtoms(left, into: &result); collectAtoms(right, into: &result)
        default: break
        }
    }
}
