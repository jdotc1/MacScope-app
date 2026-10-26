import Foundation

/// Single-target resolution of indirect calls through memory slots (`ldr xN, [obj, #off];
/// blr xN`). A slot is a field path from a parameter: constant offsets, with a dereference
/// between consecutive components. A call through a slot resolves to a function only when
/// exactly one function address is ever stored there and nothing else might write it:
///
/// - **function-local:** the single store precedes the call's load in the same basic block,
///   with no call or unresolved store between them;
/// - **signature-typed:** the root parameter's declared type names a pointer to a type
///   (`struct T *`), and across every analyzed function that type's slot receives exactly
///   one function address; any unresolved or non-constant store through that type
///   poisons all its slots. Writers whose roots cannot be related to the declared
///   object, unknown effects and multiple potentially aliased roots also refuse typed
///   resolution; nominal type names alone are not a non-aliasing proof.
///   Direct callees with transitively visible analyzed bodies are covered by the
///   same writer inventory, with every non-call control-flow destination inside
///   its own analyzed body. Literal-SP writes wholly below entry SP are exempt
///   only when the entire function proves its frame address does not escape;
///   unknown IR or any non-exempt SP-derived value read defeats that proof.
///   Local barriers remain unchanged. All other calls
///   may mutate escaped objects, even with known argument or target types. The call
///   being resolved is excluded: its own effects occur after its target load.
///
/// Indexed (register-scaled) slots, multi-target slots and untyped cross-function paths are
/// refused, never guessed. Read-only analysis.
public enum MacIRIndirectTargetResolution {
    /// An untouched incoming x0 whose return contract has no authority yet.
    static let unresolvedReturnContractMarker = "unresolved_return_contract"

    /// Offsets from the root parameter; a dereference separates consecutive components.
    public struct FieldPath: Hashable, Sendable, CustomStringConvertible {
        public let parameter: Int
        public let components: [Int64]

        public var description: String {
            "x\(parameter)" + components.enumerated().map { index, offset in
                (index == 0 ? "" : "->") + (offset < 0 ? "-0x" + String(offset.magnitude, radix: 16) : "+0x" + String(offset, radix: 16))
            }.joined()
        }
    }

    public enum Scope: Hashable, Sendable {
        case function(UInt64)
        case type(String)
    }

    public struct Resolution: Hashable, Sendable {
        public let callAddress: UInt64
        public let functionStart: UInt64
        public let target: UInt64
        public let slot: FieldPath
        public let scope: Scope
    }

    public enum RefusalReason: String, Hashable, Sendable {
        /// The call target is not a load from a field path of a parameter.
        case noSlot
        /// Nothing stores a function address to the slot in scope.
        case noStore
        /// More than one function (or a non-function value) is stored to the slot.
        case multipleValues
        /// An unresolved or indexed store through the same root might write the slot.
        case poisoned
        /// The function-local store does not reach the call's load in one block.
        case notDominating
    }

    public struct Refusal: Hashable, Sendable {
        public let callAddress: UInt64
        public let functionStart: UInt64
        public let reason: RefusalReason
    }

    public struct Report: Hashable, Sendable {
        public let resolutions: [Resolution]
        public let refusals: [Refusal]
    }

    public static func resolve(functions: [MacIRFunction], functionStarts: Set<UInt64>) -> Report {
        let facts = functions.map { Facts(function: $0, functionStarts: functionStarts) }
        // Greatest fixpoint: closed recursive components remain visible; any
        // opaque edge removes its caller and then all transitive callers.
        var visible = Set(facts.filter { !$0.hasUnsupportedWrite && $0.hasClosedControlFlow }.map { $0.function.startAddress })
        while true {
            let rejected = Set(facts.filter {
                visible.contains($0.function.startAddress) && $0.hasPotentialCallWrite(excluding: nil, visible: visible)
            }.map { $0.function.startAddress })
            if rejected.isEmpty { break }
            visible.subtract(rejected)
        }
        // Typed slots: every stored value, image-wide, and the poisoned types.
        var typedStores: [TypedSlot: Set<StoredValue>] = [:]
        var poisonedTypes: Set<String> = []
        for fact in facts {
            for store in fact.stores {
                guard let type = fact.parameterTypes[store.path.parameter] else { continue }
                typedStores[TypedSlot(type: type, components: store.path.components), default: []].insert(store.value)
            }
            for parameter in fact.poisonedParameters {
                if let type = fact.parameterTypes[parameter] { poisonedTypes.insert(type) }
            }
        }
        var resolutions: [Resolution] = []
        var refusals: [Refusal] = []
        for fact in facts {
            for call in fact.calls {
                let start = fact.function.startAddress
                guard let path = call.path else {
                    refusals.append(.init(callAddress: call.address, functionStart: start, reason: .noSlot))
                    continue
                }
                // Function-local first.
                let local = fact.storesByPath[path] ?? []
                guard !fact.hasConflictingWrite(to: path) else {
                    refusals.append(.init(callAddress: call.address, functionStart: start, reason: .poisoned))
                    continue
                }
                if local.count == 1, let store = local.first, store.width == 8, case let .function(target) = store.value,
                   !fact.poisonedParameters.contains(path.parameter) {
                    if fact.reaches(store: store, call: call) {
                        resolutions.append(.init(callAddress: call.address, functionStart: start, target: target,
                                                 slot: path, scope: .function(start)))
                        continue
                    }
                }
                // A type name cannot repair a failed local reaching-value proof.
                if !local.isEmpty || fact.hasBarrierBeforeLoad(call) {
                    refusals.append(.init(callAddress: call.address, functionStart: start,
                                          reason: local.count > 1 ? .multipleValues : .notDominating))
                    continue
                }
                // Then signature-typed, provided every image-wide writer is separated.
                if let type = fact.parameterTypes[path.parameter] {
                    guard !poisonedTypes.contains(type), !facts.contains(where: { writer in
                        if writer.hasUnsupportedWrite { return true }
                        // Visible bodies have their stores in this same inventory.
                        // Opaque callees may mutate escaped objects. Exclude only
                        // the queried call, whose effects follow its target load.
                        if writer.hasPotentialCallWrite(excluding: writer.function.startAddress == start ? call.index : nil, visible: visible) {
                            return true
                        }
                        // Two entry pointers may denote shifted/overlapping storage;
                        // mapping both to a type must not erase their distinction.
                        if Set(writer.stores.map { $0.path.parameter }).count > 1 { return true }
                        return writer.stores.contains { store in
                            // Type names do not establish non-aliasing. A writer
                            // rooted outside this type can touch any of its slots.
                            guard writer.parameterTypes[store.path.parameter] == type else { return true }
                            let slot = FieldPath(parameter: store.path.parameter, components: path.components)
                            return !(store.path == slot && store.width == 8) && !store.isDisjoint(from: slot)
                        }
                    }) else {
                        refusals.append(.init(callAddress: call.address, functionStart: start, reason: .poisoned))
                        continue
                    }
                    let values = typedStores[TypedSlot(type: type, components: path.components)] ?? []
                    if values.count == 1, case let .function(target)? = values.first {
                        resolutions.append(.init(callAddress: call.address, functionStart: start, target: target,
                                                 slot: path, scope: .type(type)))
                    } else {
                        refusals.append(.init(callAddress: call.address, functionStart: start,
                                              reason: values.isEmpty ? .noStore : .multipleValues))
                    }
                    continue
                }
                let reason: RefusalReason = fact.poisonedParameters.contains(path.parameter) ? .poisoned
                    : local.isEmpty ? .noStore : local.count > 1 ? .multipleValues : .notDominating
                refusals.append(.init(callAddress: call.address, functionStart: start, reason: reason))
            }
        }
        return Report(resolutions: resolutions.sorted { $0.callAddress < $1.callAddress },
                      refusals: refusals.sorted { $0.callAddress < $1.callAddress })
    }

    /// Read-only explanation of the existing Facts predicates. Input order determines
    /// the first rejecting writer, exactly as in resolve(); no diagnostic feeds resolution.
    public struct FunctionPoison: Sendable, Codable {
        public let functionStart: UInt64
        public let visible: Bool
        public let firstRejectingReason: String?
        public let unknownIR: [UnknownIRSite]
        public let firstFrameEscape: FrameEscapeSite?
        public let hasNonFrameStore: Bool
        public let hasEscapedFrameWrite: Bool
    }

    public struct UnknownIRClass: Hashable, Sendable, Codable {
        public let operationKind: String
        /// `.unknown` retains a mnemonic/kind, not a separate reason field.
        public let kind: String
        public let mnemonic: String
    }

    public struct UnknownIRSite: Sendable, Codable {
        public let instructionIndex: Int
        public let address: UInt64
        public let classification: UnknownIRClass
        public let isFirst: Bool
    }

    public struct FrameEscapeSite: Sendable, Codable {
        public let instructionIndex: Int
        public let address: UInt64
        public let shape: String
        public let mnemonic: String
    }

    public struct UnknownIRClassSummary: Sendable, Codable {
        public let classification: UnknownIRClass
        public let instructions: Int
        public let functions: Int
        public let first: Int
        public let soleBlockerFunctions: [UInt64]
        public let flipIfModeled: [UInt64]
    }

    public struct TypedQueryPoison: Sendable, Codable {
        public let functionStart: UInt64
        public let callAddress: UInt64
        public let reason: String
        public let writerStart: UInt64?
    }

    public struct PoisonReport: Sendable, Codable {
        public let functions: [FunctionPoison]
        /// All refused parameter-typed slot queries (including pre-typed local vetoes).
        public let typedQueryRefusals: [TypedQueryPoison]
        /// Distinct writer functions transitively reaching each symbolic opaque callee.
        /// A writer can contribute to multiple symbols, independently of its first reason.
        public let importPoisonWriterCounts: [String: Int]
        public let unknownIRByClass: [UnknownIRClassSummary]
    }

    public static func poisonReport(functions: [MacIRFunction], functionStarts: Set<UInt64>) -> PoisonReport {
        let facts = functions.map { Facts(function: $0, functionStarts: functionStarts) }
        let byStart = Dictionary(facts.map { ($0.function.startAddress, $0) }, uniquingKeysWith: { first, _ in first })
        var visible = Set(facts.filter { !$0.hasUnsupportedWrite && $0.hasClosedControlFlow }.map { $0.function.startAddress })
        var reasons: [UInt64: String] = [:]
        for fact in facts {
            if fact.hasUnsupportedWrite { reasons[fact.function.startAddress] = fact.unsupportedWriteReason ?? "unknown IR" }
            else if !fact.hasClosedControlFlow { reasons[fact.function.startAddress] = "open control flow" }
        }
        // Synchronous rounds preserve the resolver's greatest fixpoint, including cycles.
        while true {
            let rejected = facts.filter {
                visible.contains($0.function.startAddress) && $0.hasPotentialCallWrite(excluding: nil, visible: visible)
            }
            if rejected.isEmpty { break }
            for fact in rejected {
                reasons[fact.function.startAddress] = callReason(fact, excluding: nil, visible: visible, reasons: reasons)
            }
            visible.subtract(rejected.map { $0.function.startAddress })
        }
        var importCounts: [String: Int] = [:]
        for fact in facts where !visible.contains(fact.function.startAddress) {
            var visited: Set<UInt64> = []
            var symbols: Set<String> = []
            func visit(_ start: UInt64) {
                guard visited.insert(start).inserted, let item = byStart[start] else { return }
                for reason in item.opaqueCalls.values where reason.hasPrefix("import: ") {
                    symbols.insert(String(reason.dropFirst(8)))
                }
                for target in item.analyzedCallees.values { visit(target) }
            }
            visit(fact.function.startAddress)
            for symbol in symbols { importCounts[symbol, default: 0] += 1 }
        }
        var refusals: [TypedQueryPoison] = []
        for fact in facts {
            for call in fact.calls {
                guard let path = call.path, let type = fact.parameterTypes[path.parameter] else { continue }
                let local = fact.storesByPath[path] ?? []
                var reason: String?
                var writerStart: UInt64?
                if fact.hasConflictingWrite(to: path) {
                    reason = fact.unsupportedWriteReason ?? "local conflicting write"
                    writerStart = fact.function.startAddress
                } else if local.count == 1, let store = local.first, store.width == 8,
                          case .function = store.value, !fact.poisonedParameters.contains(path.parameter),
                          fact.reaches(store: store, call: call) {
                    continue
                } else if !local.isEmpty || fact.hasBarrierBeforeLoad(call) {
                    reason = local.count > 1 ? "multiple values" : "not dominating"
                    writerStart = fact.function.startAddress
                } else {
                    // Poisoned types are checked before the image-wide writer predicate.
                    if let writer = facts.first(where: { writer in
                        writer.poisonedParameters.contains { writer.parameterTypes[$0] == type }
                    }) {
                        reason = "poisoned type"
                        writerStart = writer.function.startAddress
                    } else {
                        for writer in facts {
                            let excluded = writer.function.startAddress == fact.function.startAddress ? call.index : nil
                            if writer.hasUnsupportedWrite { reason = writer.unsupportedWriteReason ?? "unknown IR" }
                            else if writer.hasPotentialCallWrite(excluding: excluded, visible: visible) {
                                reason = callReason(writer, excluding: excluded, visible: visible, reasons: reasons)
                            } else if Set(writer.stores.map { $0.path.parameter }).count > 1 { reason = "multiple aliased roots" }
                            else if writer.stores.contains(where: { store in
                                guard writer.parameterTypes[store.path.parameter] == type else { return true }
                                let slot = FieldPath(parameter: store.path.parameter, components: path.components)
                                return !(store.path == slot && store.width == 8) && !store.isDisjoint(from: slot)
                            }) { reason = "unseparated store" }
                            if reason != nil { writerStart = writer.function.startAddress; break }
                        }
                    }
                    if reason == nil {
                        let values = Set(facts.flatMap { writer in writer.stores.filter {
                            writer.parameterTypes[$0.path.parameter] == type && $0.path.components == path.components
                        }.map(\.value) })
                        if values.count == 1, case .function? = values.first { continue }
                        reason = values.isEmpty ? "no store" : "multiple values"
                    }
                }
                refusals.append(TypedQueryPoison(functionStart: fact.function.startAddress, callAddress: call.address,
                    reason: reason ?? "no store", writerStart: writerStart))
            }
        }
        // Memory-only what-if over the already-built facts. Preserve closed-control-flow,
        // SP tracking, frame escape, stores and call edges: a memory contract proves
        // none of those. Only the selected class's unsupported-write veto is removed.
        let classes = Set(facts.flatMap { $0.unknownIR.map(\.classification) })
        let summaries = classes.map { classification in
            let containing = facts.filter { $0.unknownIR.contains { $0.classification == classification } }
            var modeledVisible = Set(facts.filter { fact in
                fact.hasClosedControlFlow && !fact.hasNonUnknownUnsupportedWrite
                    && fact.unknownIR.allSatisfy { $0.classification == classification }
            }.map { $0.function.startAddress })
            while true {
                let rejected = facts.filter {
                    modeledVisible.contains($0.function.startAddress)
                        && $0.hasPotentialCallWrite(excluding: nil, visible: modeledVisible)
                }.map { $0.function.startAddress }
                if rejected.isEmpty { break }
                modeledVisible.subtract(rejected)
            }
            return UnknownIRClassSummary(classification: classification,
                instructions: containing.reduce(0) { count, fact in
                    count + fact.unknownIR.filter { $0.classification == classification }.count
                }, functions: containing.count,
                first: containing.filter { $0.unknownIR.first?.classification == classification }.count,
                soleBlockerFunctions: containing.filter { fact in
                    !fact.hasNonFrameStore && !fact.hasEscapedFrameWrite
                        && fact.unknownIR.allSatisfy { $0.classification == classification }
                }.map { $0.function.startAddress }.sorted(),
                flipIfModeled: modeledVisible.subtracting(visible).sorted())
        }.sorted {
            if $0.functions != $1.functions { return $0.functions > $1.functions }
            if $0.instructions != $1.instructions { return $0.instructions > $1.instructions }
            let a = $0.classification, b = $1.classification
            if a.operationKind != b.operationKind { return a.operationKind < b.operationKind }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.mnemonic < b.mnemonic
        }
        return PoisonReport(functions: facts.map { FunctionPoison(functionStart: $0.function.startAddress,
            visible: visible.contains($0.function.startAddress), firstRejectingReason: reasons[$0.function.startAddress],
            unknownIR: $0.unknownIR, firstFrameEscape: $0.firstFrameEscape,
            hasNonFrameStore: $0.hasNonFrameStore, hasEscapedFrameWrite: $0.hasEscapedFrameWrite) },
            typedQueryRefusals: refusals, importPoisonWriterCounts: importCounts, unknownIRByClass: summaries)
    }

    private static func callReason(_ fact: Facts, excluding index: Int?, visible: Set<UInt64>,
                                   reasons: [UInt64: String]) -> String? {
        let indices = Set(fact.opaqueCalls.keys).union(fact.analyzedCallees.keys).sorted()
        for call in indices where call != index {
            if let opaque = fact.opaqueCalls[call] { return opaque }
            if let target = fact.analyzedCallees[call], !visible.contains(target) {
                return reasons[target] ?? "non-analyzed address"
            }
        }
        return nil
    }

    // MARK: - Per-function facts

    private struct TypedSlot: Hashable { let type: String; let components: [Int64] }

    enum StoredValue: Hashable { case function(UInt64), other }

    struct Store: Hashable {
        let path: FieldPath
        let value: StoredValue
        let index: Int
        let width: Int?

        /// Only ranges in the same direct object prove separation. Distinct
        /// parameters and dereferenced paths may alias, regardless of spelling/type.
        func isDisjoint(from slot: FieldPath) -> Bool {
            guard path.parameter == slot.parameter,
                  path.components.count == 1, slot.components.count == 1,
                  let width, width > 0 else { return false }
            let writeStart = path.components[0], slotStart = slot.components[0]
            let writeEnd = writeStart.addingReportingOverflow(Int64(width))
            let slotEnd = slotStart.addingReportingOverflow(8)
            guard !writeEnd.overflow, !slotEnd.overflow else { return false }
            return writeEnd.partialValue <= slotStart || slotEnd.partialValue <= writeStart
        }
    }
    struct Call: Hashable { let address: UInt64; let path: FieldPath?; let loadIndex: Int?; let index: Int }

    struct Facts {
        let function: MacIRFunction
        var parameterTypes: [Int: String] = [:]
        var stores: [Store] = []
        private(set) var storesByPath: [FieldPath: [Store]] = [:]
        var calls: [Call] = []
        var poisonedParameters: Set<Int> = []
        var hasUnsupportedWrite = false
        // Diagnostic only; never consulted by resolve().
        var unsupportedWriteReason: String?
        var unknownIR: [UnknownIRSite] = []
        var firstFrameEscape: FrameEscapeSite?
        var hasNonFrameStore = false
        var hasEscapedFrameWrite = false
        var hasNonUnknownUnsupportedWrite = false
        var opaqueCalls: [Int: String] = [:]
        var analyzedCallees: [Int: UInt64] { directCallees }
        let hasClosedControlFlow: Bool
        private var hasLocalUnsupportedWrite = false
        private var directCallees: [Int: UInt64] = [:]
        private var barrierIndices: [Int] = []
        private var callIndices: [Int] = []
        private var blockOfIndex: [Int: Int] = [:]

        init(function: MacIRFunction, functionStarts: Set<UInt64>) {
            self.function = function
            hasClosedControlFlow = Self.controlFlowStaysInBody(function)
            var paths: [MacIRValue: FieldPath] = [:]
            var constants: [MacIRValue: Int64] = [:]
            var loadedFrom: [MacIRValue: (path: FieldPath, index: Int)] = [:]
            /// Values computed from a root by non-constant arithmetic (an indexed address).
            var tainted: [MacIRValue: Int] = [:]
            for parameter in function.parameters {
                guard case let .gpr(index, _) = parameter.abiLocation else { continue }
                if let binding = parameter.bindingID { paths[.argument(bindingID: binding)] = FieldPath(parameter: index, components: [0]) }
                if let type = Self.pointeeTypeName(parameter.type) { parameterTypes[index] = type }
            }
            for index in 0 ..< 8 where paths.values.allSatisfy({ $0.parameter != index }) {
                paths[.register(name: "x\(index)", version: 0)] = FieldPath(parameter: index, components: [0])
            }
            func path(_ value: MacIRValue) -> FieldPath? {
                if let path = paths[value] { return path }
                if case let .binaryExpression(op, left, .immediate(k)) = value, op == "+" || op == "-",
                   let base = path(left) {
                    return Self.adding(k, subtract: op == "-", to: base)
                }
                return nil
            }
            func touchesRoot(_ value: MacIRValue) -> Int? {
                if let path = paths[value] { return path.parameter }
                if let parameter = tainted[value] { return parameter }
                switch value {
                case let .signedBitfield(node): return touchesRoot(node.source)
                case let .binaryExpression(_, left, right): return touchesRoot(left) ?? touchesRoot(right)
                case let .unary(_, inner): return touchesRoot(inner)
                default: return nil
                }
            }
            func constant(_ value: MacIRValue) -> Int64? {
                if case let .immediate(k) = value { return k }
                return constants[value]
            }
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            for (block, value) in cfg.blocks.enumerated() {
                for index in value.instructionRange { blockOfIndex[index] = block }
            }
            // No path joins or loop reasoning in this contract. Track only the
            // entry block when it cannot be re-entered; never regain lost SP authority.
            var spDelta: Int64? = cfg.blocks.first?.predecessors.isEmpty == true ? 0 : nil
            var frameWrites: Set<Int> = []
            var entrySP: [Int: Int64] = [:]
            for (index, instruction) in function.instructions.enumerated() {
                if blockOfIndex[index] != cfg.entryIndex { spDelta = nil }
                entrySP[index] = spDelta
                if Self.frameWrite(instruction, spDelta: spDelta) { frameWrites.insert(index) }
                spDelta = Self.updatedSP(instruction, current: spDelta)
            }
            // Escape is function-wide, including reads after a store or in another
            // block. No early frame write can escape this conservative veto.
            let candidateFrameWrites = frameWrites
            var escape: FrameEscapeSite?
            if Self.frameAddressEscapes(function, frameWrites: frameWrites, entrySP: entrySP, firstEscape: &escape) {
                frameWrites.removeAll()
                if !candidateFrameWrites.isEmpty { firstFrameEscape = escape }
            }
            func writeReason(_ index: Int) -> String {
                candidateFrameWrites.contains(index) ? "escaped frame" : "non-frame store"
            }
            for (index, instruction) in function.instructions.enumerated() {
                let frameWrite = frameWrites.contains(index)
                switch instruction.operation {
                case .intrinsic(_, "save_pair", _) where candidateFrameWrites.contains(index):
                    if !frameWrite { hasEscapedFrameWrite = true }
                case .store, .storeWriteback, .intrinsic(_, "save_pair_writeback", _):
                    if !candidateFrameWrites.contains(index) { hasNonFrameStore = true }
                    else if !frameWrite { hasEscapedFrameWrite = true }
                default: break
                }
                switch instruction.operation {
                case let .assign(destination, source):
                    if let p = path(source) { paths[destination] = p }
                    else if let parameter = touchesRoot(source) { tainted[destination] = parameter }
                    if let k = constant(source) { constants[destination] = k }
                case let .intrinsic(destination?, "adrp", arguments):
                    if let page = arguments.first.flatMap(constant) { constants[destination] = page }
                case let .binary(destination, op, left, .immediate(k)) where op == "+" || op == "-":
                    if let base = path(left) { paths[destination] = Self.adding(k, subtract: op == "-", to: base) }
                    else if let parameter = touchesRoot(left) { tainted[destination] = parameter }
                    if let base = constant(left) { constants[destination] = op == "+" ? base &+ k : base &- k }
                case let .binary(destination, _, left, right):
                    if let parameter = touchesRoot(left) ?? touchesRoot(right) { tainted[destination] = parameter }
                case let .load(destination, address):
                    if instruction.memoryAccess?.byteWidth == 8, let slot = path(address) {
                        paths[destination] = FieldPath(parameter: slot.parameter, components: slot.components + [0])
                        loadedFrom[destination] = (slot, index)
                    }
                case let .store(source, address):
                    if let slot = path(address) {
                        let stored: StoredValue = constant(source).flatMap { value in
                            value >= 0 && functionStarts.contains(UInt64(value)) ? .function(UInt64(value)) : nil
                        } ?? .other
                        let store = Store(path: slot, value: stored, index: index, width: instruction.memoryAccess?.byteWidth)
                        stores.append(store)
                        storesByPath[slot, default: []].append(store)
                    } else {
                        if let parameter = touchesRoot(address) { poisonedParameters.insert(parameter) }
                        if !frameWrite { unsupportedWriteReason = unsupportedWriteReason ?? writeReason(index) }
                        hasNonUnknownUnsupportedWrite = hasNonUnknownUnsupportedWrite || !frameWrite
                        hasUnsupportedWrite = hasUnsupportedWrite || !frameWrite
                        hasLocalUnsupportedWrite = true
                        barrierIndices.append(index)
                    }
                case let .storeWriteback(_, _, baseSource, _, _):
                    if !frameWrite { unsupportedWriteReason = unsupportedWriteReason ?? writeReason(index) }
                    hasNonUnknownUnsupportedWrite = hasNonUnknownUnsupportedWrite || !frameWrite
                    hasUnsupportedWrite = hasUnsupportedWrite || !frameWrite
                    hasLocalUnsupportedWrite = true
                    if let parameter = touchesRoot(baseSource) { poisonedParameters.insert(parameter) }
                    barrierIndices.append(index)
                case let .call(frame, _):
                    barrierIndices.append(index)
                    callIndices.append(index)
                    if frame.controlInputs.indirectTarget == nil,
                       let target = Self.directCallee(instruction.source), functionStarts.contains(target) {
                        directCallees[index] = target
                    } else if frame.controlInputs.indirectTarget != nil {
                        opaqueCalls[index] = "indirect call"
                    } else {
                        let name = frame.target
                        opaqueCalls[index] = name.hasPrefix("0x") || name.hasPrefix("sub_")
                            ? "non-analyzed address" : "import: " + name
                    }
                    if frame.target.hasPrefix("(*"), let target = frame.controlInputs.indirectTarget {
                        let loaded = loadedFrom[target.value]
                        calls.append(Call(address: instruction.source.address, path: loaded?.path,
                                          loadIndex: loaded?.index, index: index))
                    }
                    // A call can replace any pointer in an object path. The old
                    // loaded SSA value still exists, but no longer names a reload's
                    // object. Do not publish a later store under that stale path.
                    paths = paths.filter { $0.value.components.count == 1 }
                    loadedFrom.removeAll()
                case let .intrinsic(_, name, _) where Self.registerOnlyIntrinsics.contains(name)
                    && instruction.memoryAccess == nil:
                    // Explicit register/flags-only contracts neither clobber memory
                    // nor invalidate an already loaded object path.
                    break
                case let .intrinsic(_, name, _) where Self.stackIntrinsics.contains(name)
                    || Self.framePairAccess(instruction, spDelta: entrySP[index]):
                    // Preserve the old local clobber and path invalidation exactly.
                    if (name == "save_pair_writeback" || name == "save_pair") && !frameWrite {
                        unsupportedWriteReason = unsupportedWriteReason ?? writeReason(index)
                        hasNonUnknownUnsupportedWrite = true
                        hasUnsupportedWrite = true
                    }
                    hasLocalUnsupportedWrite = true
                    barrierIndices.append(index)
                    paths = paths.filter { $0.value.components.count == 1 }
                    loadedFrom.removeAll()
                case .unknown, .intrinsic:
                    // Unknown IR is a full memory clobber. Intrinsics without an
                    // explicit memory-effect contract cannot prove write separation.
                    let classification: UnknownIRClass
                    switch instruction.operation {
                    case let .unknown(_, _, kind, _):
                        classification = UnknownIRClass(operationKind: "unknown", kind: kind,
                            mnemonic: instruction.source.mnemonic)
                    case let .intrinsic(_, name, _):
                        classification = UnknownIRClass(operationKind: "intrinsic", kind: name,
                            mnemonic: instruction.source.mnemonic)
                    default: preconditionFailure("Only unknown/uncontracted intrinsic reaches this case")
                    }
                    unknownIR.append(UnknownIRSite(instructionIndex: index, address: instruction.source.address,
                        classification: classification, isFirst: unknownIR.isEmpty))
                    unsupportedWriteReason = unsupportedWriteReason ?? "unknown IR"
                    hasUnsupportedWrite = true
                    hasLocalUnsupportedWrite = true
                    barrierIndices.append(index)
                    paths = paths.filter { $0.value.components.count == 1 }
                    loadedFrom.removeAll()
                default:
                    break
                }
            }
        }

        func hasPotentialCallWrite(excluding index: Int?, visible: Set<UInt64>) -> Bool {
            callIndices.contains { call in
                call != index && !(directCallees[call].map { visible.contains($0) } ?? false)
            }
        }

        func hasConflictingWrite(to path: FieldPath) -> Bool {
            hasLocalUnsupportedWrite || stores.contains {
                !($0.path == path && $0.width == 8) && !$0.isDisjoint(from: path)
            }
        }

        func hasBarrierBeforeLoad(_ call: Call) -> Bool {
            guard let load = call.loadIndex else { return true }
            return barrierIndices.contains { $0 < load }
        }

        /// The store reaches the call's slot load within one block, with no call or
        /// unresolved store between them.
        func reaches(store: Store, call: Call) -> Bool {
            guard let load = call.loadIndex, store.index < load,
                  let block = blockOfIndex[store.index], blockOfIndex[load] == block else { return false }
            return !barrierIndices.contains { $0 > store.index && $0 < load }
        }

        /// Check every destination before the shrinking call fixpoint. CFGBuilder's
        /// resolved edge list deliberately omits unknown/external edges, so it is
        /// not sufficient evidence of closure. Returns use the ordinary ABI exit.
        private static func controlFlowStaysInBody(_ function: MacIRFunction) -> Bool {
            let addresses = Set(function.instructions.map { $0.source.address })
            guard !addresses.isEmpty else { return false }
            func isInternal(_ target: MacIRValue) -> Bool {
                guard let address = CFGBuilder.address(of: target) else { return false }
                return addresses.contains(address)
            }
            return function.instructions.allSatisfy { instruction in
                func hasFallthrough() -> Bool {
                    let next = instruction.source.address.addingReportingOverflow(4)
                    return !next.overflow && addresses.contains(next.partialValue)
                }
                switch instruction.operation {
                case let .conditionalBranch(_, _, _, target):
                    return isInternal(target) && hasFallthrough()
                case let .switchDispatch(_, cases, defaultTarget):
                    guard !cases.isEmpty, let defaultTarget else { return false }
                    return cases.allSatisfy { isInternal($0.target) } && isInternal(defaultTarget)
                case let .intrinsic(_, name, arguments) where name == "branch" || name.hasPrefix("branch_"):
                    guard name != "branch_register", arguments.count == 1,
                          let target = arguments.first, isInternal(target) else { return false }
                    return name == "branch" || hasFallthrough()
                case .returnValue:
                    return isABIReturn(instruction.source)
                case .unknown:
                    return false
                default:
                    // Calls are accounted for separately by the fixpoint. Other
                    // unknown intrinsics already have unsupported memory effects.
                    return true
                }
            }
        }

        /// The lifter's returnValue omits the actual RET control register.
        /// Nonstandard RET/exception returns cannot inherit an ABI-return contract.
        private static func isABIReturn(_ source: MacIRSourceSpan) -> Bool {
            let operands = source.operands.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch source.mnemonic.lowercased() {
            case "ret": return operands.isEmpty || operands == "x30" || operands == "lr"
            case "retaa", "retab": return operands.isEmpty
            default: return false
            }
        }

        private static func registerIdentity(_ value: MacIRValue) -> String? {
            guard case let .register(name, _) = value else { return nil }
            if name == "fp" { return "x29" }
            if name == "lr" { return "x30" }
            if name == "wsp" { return "sp" }
            if name.first == "w", Int(name.dropFirst()) != nil { return "x" + name.dropFirst() }
            if let first = name.first, "bhsdqv".contains(first), Int(name.dropFirst()) != nil {
                return "v" + name.dropFirst()
            }
            return name
        }

        private static func isFramePointer(_ value: MacIRValue) -> Bool {
            if case let .register(name, _) = value { return name == "x29" || name == "fp" }
            return false
        }

        private static func isFramePointerSetup(_ operation: MacIROperation) -> Bool {
            switch operation {
            case let .assign(destination, source):
                return isFramePointer(destination) && isSP(source)
            case let .binary(destination, "+", left, .immediate):
                return isFramePointer(destination) && isSP(left)
            default: return false
            }
        }

        /// The first non-exempt value read establishes escape. The two allowed
        /// alias producers are x29 setup and reloads of a saved frame record.
        /// Taint register identities across versions to conservatively cover joins.
        private static func frameAddressEscapes(_ function: MacIRFunction, frameWrites: Set<Int>,
                                                entrySP: [Int: Int64], firstEscape: inout FrameEscapeSite?) -> Bool {
            let derivedFP = function.instructions.contains { isFramePointerSetup($0.operation) }
            var derivedRegisters: Set<String> = derivedFP ? ["sp", "x29"] : ["sp"]
            func accessStart(_ instruction: MacIRInstruction, index: Int) -> Int64? {
                guard let delta = entrySP[index], let memory = spMemory(instruction) else { return nil }
                return adjustedSP(delta, by: memory.indexing == .postIndex ? 0 : memory.displacement)
            }
            // A permitted frame-record save can expose x29 through a later load.
            // Keep all possible saved locations, including overwritten records;
            // unknown load coordinates may alias any of them.
            let savedFrameAddresses: [Int64] = function.instructions.enumerated().compactMap { index, instruction in
                guard derivedFP, frameWrites.contains(index),
                      case let .intrinsic(_, name, args) = instruction.operation,
                      (name == "save_pair_writeback" || name == "save_pair"),
                      isFramePointer(args[0]) else { return nil }
                return accessStart(instruction, index: index)
            }
            func mayReloadFrame(_ instruction: MacIRInstruction, index: Int, element: Int = 0) -> Bool {
                guard !savedFrameAddresses.isEmpty else { return false }
                guard let start = accessStart(instruction, index: index),
                      let width = instruction.memoryAccess?.byteWidth, width > 0,
                      let elementStart = adjustedSP(start, by: element == 0 ? 0 : Int64(width)),
                      let end = adjustedSP(elementStart, by: Int64(width)) else { return true }
                return savedFrameAddresses.contains { saved in
                    guard let savedEnd = adjustedSP(saved, by: 8) else { return true }
                    return elementStart < savedEnd && saved < end
                }
            }
            func taint(_ destination: MacIRValue) {
                if let register = registerIdentity(destination) { derivedRegisters.insert(register) }
            }
            for (index, instruction) in function.instructions.enumerated() {
                switch instruction.operation {
                case let .load(destination, _), let .loadWriteback(destination, _, _, _, _),
                     let .stackSlotRead(destination, _, _):
                    if mayReloadFrame(instruction, index: index) { taint(destination) }
                case let .stackSlotPairRead(first, _, _, second, _, _):
                    if mayReloadFrame(instruction, index: index) { taint(first) }
                    if mayReloadFrame(instruction, index: index, element: 1) { taint(second) }
                case let .intrinsic(_, name, args) where
                    (name == "restore_pair_writeback" && args.count == 6)
                        || (name == "restore_pair" && (args.count == 3 || args.count == 4)):
                    if mayReloadFrame(instruction, index: index) { taint(args[0]) }
                    if mayReloadFrame(instruction, index: index, element: 1) { taint(args[1]) }
                default: break
                }
            }
            func readsFrame(_ value: MacIRValue) -> Bool {
                switch value {
                case .register:
                    return registerIdentity(value).map { derivedRegisters.contains($0) } ?? true
                case let .signedBitfield(node): return readsFrame(node.source)
                case let .binaryExpression(_, left, right): return readsFrame(left) || readsFrame(right)
                case let .unary(_, value), let .bitTest(value, _): return readsFrame(value)
                case let .abiComposite(_, fragments): return fragments.contains(where: readsFrame)
                case .unknown, .temporary, .stackSlot: return true
                case .argument, .argumentFragment, .immediate, .symbol: return false
                }
            }
            // The base may be SP/FP, but an index or any other value operand may not.
            func addressEscapes(_ address: MacIRValue) -> Bool {
                switch address {
                case .register, .stackSlot, .argument, .argumentFragment, .immediate, .symbol: return false
                case let .binaryExpression(op, base, offset) where op == "+" || op == "-":
                    return addressEscapes(base) || readsFrame(offset)
                default: return true
                }
            }
            for (index, instruction) in function.instructions.enumerated() {
                func escape(_ shape: String) -> Bool {
                    firstEscape = FrameEscapeSite(instructionIndex: index, address: instruction.source.address,
                        shape: shape, mnemonic: instruction.source.mnemonic)
                    return true
                }
                if isFramePointerSetup(instruction.operation) { continue }
                switch instruction.operation {
                case let .assign(_, source):
                    if readsFrame(source) { return escape("arithmetic/copy") }
                case let .binary(destination, op, left, right):
                    if isSP(destination), isSP(left), op == "+" || op == "-",
                       case .immediate = right { continue }
                    if readsFrame(left) || readsFrame(right) { return escape("arithmetic/copy") }
                case let .load(_, address):
                    if addressEscapes(address) { return escape("other") }
                case let .store(source, address):
                    if readsFrame(source) { return escape("stored as data") }
                    if addressEscapes(address) { return escape("other") }
                case let .loadWriteback(_, _, base, _, _):
                    if addressEscapes(base) { return escape("other") }
                case let .storeWriteback(source, _, base, _, _):
                    if readsFrame(source) { return escape("stored as data") }
                    if addressEscapes(base) { return escape("other") }
                case let .stackSlotRead(_, slot, _):
                    if addressEscapes(slot) { return escape("other") }
                case let .stackSlotPairRead(_, first, _, _, second, _):
                    if addressEscapes(first) || addressEscapes(second) { return escape("other") }
                case let .call(frame, _):
                    if frame.bindingValues.contains(where: readsFrame) { return escape("call binding") }
                case let .conditionalBranch(_, left, right, target):
                    if [left, right, target].contains(where: readsFrame) { return escape("compared/branched") }
                case let .select(_, _, left, right, yes, no):
                    if [left, right, yes, no].contains(where: readsFrame) { return escape("compared/branched") }
                case let .compareToBool(_, _, left, right):
                    if readsFrame(left) || readsFrame(right) { return escape("compared/branched") }
                case let .returnValue(value):
                    // The marker carries no return-expression evidence. Physical
                    // x0 taint must still be checked independently below.
                    let returnsFrame = value != .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
                        && value.map(readsFrame) == true
                    // Authenticated returns implicitly consume SP as a value;
                    // the generic returnValue node does not retain that read.
                    if instruction.source.mnemonic.lowercased() != "ret"
                        || !isABIReturn(instruction.source) || derivedRegisters.contains("x30")
                        || derivedRegisters.contains("x0") || returnsFrame { return escape("returned") }
                case let .switchDispatch(selector, _, _):
                    if readsFrame(selector) { return escape("compared/branched") }
                case let .intrinsic(destination, "adrp", arguments):
                    guard destination != nil, !arguments.contains(where: readsFrame) else { return escape("other") }
                case let .intrinsic(_, name, args) where registerOnlyIntrinsics.contains(name)
                    && instruction.memoryAccess == nil:
                    if args.contains(where: readsFrame) { return escape("arithmetic/copy") }
                case let .intrinsic(_, name, args) where stackIntrinsics.contains(name)
                    || name == "save_pair" || name == "restore_pair":
                    if stackIntrinsics.contains(name) {
                        guard updatedSP(instruction, current: 0) != nil else { return escape("other") }
                    } else {
                        guard framePairAccess(instruction, spDelta: entrySP[index]) else { return escape("other") }
                    }
                    if name == "save_pair_writeback" || name == "save_pair" {
                        // Only the x29/x30 frame-record save into the proven frame
                        // may read derived x29 as data. Restore operands 0/1 are
                        // destinations, so ldp's epilogue is deliberately not a read.
                        let savesLink: Bool
                        if case let .register(name, _) = args[1] { savesLink = name == "x30" || name == "lr" }
                        else { savesLink = false }
                        let frameRecord = frameWrites.contains(index) && isFramePointer(args[0]) && savesLink
                        if (readsFrame(args[0]) && !frameRecord) || readsFrame(args[1]) { return escape("stored as data") }
                    }
                case .unknown, .intrinsic:
                    return escape("other")
                }
            }
            return false
        }

        /// Audited emitted names from MacIRBuilder scalar/FP constructors and
        /// VectorLogical/VectorLanes/VectorCFG. SIMD variants are deliberately
        /// bounded to the U1 names plus the logical forms; new spellings stay
        /// uncontracted until added with an emission/no-memory fixture.
        /// No control-transfer, system, or memory intrinsic is admitted here.
        static let registerOnlyIntrinsics: Set<String> = [
            "a64_fp_add_f32_f32_nearestEven_0",
            "a64_fp_fromInteger_i32_f32_nearestEven_0",
            "a64_fp_fusedMultiplyAdd_f32_f32_nearestEven_0",
            "a64_fp_multiply_f32_f32_nearestEven_0",
            "a64_fp_negatedFusedMultiplySubtract_f32_f32_nearestEven_0",
            "a64_fp_subtract_f32_f32_nearestEven_0",
            "a64_fp_toInteger_f32_i32_towardZero_0",
            "a64_sdiv32",
            "a64_sdiv64",
            "a64_srem32",
            "a64_srem64",
            "a64_udiv32",
            "a64_udiv64",
            "a64_urem32",
            "a64_urem64",
            "clz",
            "compare",
            "conditional_compare_al",
            "conditional_compare_cc",
            "conditional_compare_cs",
            "conditional_compare_eq",
            "conditional_compare_ge",
            "conditional_compare_gt",
            "conditional_compare_hi",
            "conditional_compare_hs",
            "conditional_compare_le",
            "conditional_compare_lo",
            "conditional_compare_ls",
            "conditional_compare_lt",
            "conditional_compare_mi",
            "conditional_compare_ne",
            "conditional_compare_nv",
            "conditional_compare_pl",
            "conditional_compare_vc",
            "conditional_compare_vs",
            "crc32b",
            "crc32cb",
            "crc32ch",
            "crc32cw",
            "crc32cx",
            "crc32h",
            "crc32w",
            "crc32x",
            "fjcvtzs",
            "fmov",
            "neon_abs_8h",
            "neon_add_4h_zero_high64",
            "neon_add_4s",
            "neon_add_8h",
            "neon_and_16b_zero_upper",
            "neon_and_8b_zero_upper",
            "neon_bic_16b_zero_upper",
            "neon_bic_8b_zero_upper",
            "neon_cmeqz_8h",
            "neon_cmltz_8h",
            "neon_dup_4h_zero_high64",
            "neon_dup_4s",
            "neon_dup_8b_zero_high64",
            "neon_dup_8h",
            "neon_eor_16b_zero_upper",
            "neon_eor_8b_zero_upper",
            "neon_integer_constant",
            "neon_mla_4s",
            "neon_mla_8h",
            "neon_mul_4h_zero_high64",
            "neon_mul_4s",
            "neon_neg_8h",
            "neon_not_16b",
            "neon_orn_16b_zero_upper",
            "neon_orn_8b_zero_upper",
            "neon_orr_16b_zero_upper",
            "neon_orr_8b_zero_upper",
            "neon_rshrn2_16b_from_8h_shift2_keep_low64",
            "neon_rshrn2_16b_from_8h_shift4_keep_low64",
            "neon_rshrn2_8h_from_4s_shift11_keep_low64",
            "neon_rshrn2_8h_from_4s_shift15_keep_low64",
            "neon_rshrn2_8h_from_4s_shift2_keep_low64",
            "neon_rshrn_4h_from_4s_shift11_zero_high64",
            "neon_rshrn_4h_from_4s_shift15_zero_high64",
            "neon_rshrn_4h_from_4s_shift2_zero_high64",
            "neon_rshrn_8b_from_8h_shift2_zero_high64",
            "neon_rshrn_8b_from_8h_shift4_zero_high64",
            "neon_saddl2_4s_from_8h",
            "neon_saddl_4s_from_4h",
            "neon_saddw_4s_from_4s_4h",
            "neon_shl_4h_shift2_zero_high64",
            "neon_shl_8h_shift2",
            "neon_shrn2_16b_from_8h_shift2_keep_low64",
            "neon_shrn2_16b_from_8h_shift4_keep_low64",
            "neon_shrn2_8h_from_4s_shift15_keep_low64",
            "neon_shrn_4h_from_4s_shift15_zero_high64",
            "neon_shrn_8b_from_8h_shift1_zero_high64",
            "neon_shrn_8b_from_8h_shift2_zero_high64",
            "neon_shrn_8b_from_8h_shift4_zero_high64",
            "neon_smlal2_4s_from_8h_by_lane0",
            "neon_smlal2_4s_from_8h_by_lane1",
            "neon_smlal2_4s_from_8h_by_lane2",
            "neon_smlal2_4s_from_8h_by_lane3",
            "neon_smlal_4s_from_4h_by_lane0",
            "neon_smlal_4s_from_4h_by_lane1",
            "neon_smlal_4s_from_4h_by_lane2",
            "neon_smlal_4s_from_4h_by_lane3",
            "neon_smlsl2_4s_from_8h",
            "neon_smlsl_4s_from_4h",
            "neon_smlsl_4s_from_4h_by_lane0",
            "neon_smlsl_4s_from_4h_by_lane1",
            "neon_smlsl_4s_from_4h_by_lane2",
            "neon_smull2_4s_from_8h",
            "neon_smull2_4s_from_8h_by_lane0",
            "neon_smull2_4s_from_8h_by_lane1",
            "neon_smull2_4s_from_8h_by_lane2",
            "neon_smull2_4s_from_8h_by_lane3",
            "neon_smull_4s_from_4h",
            "neon_smull_4s_from_4h_by_lane0",
            "neon_smull_4s_from_4h_by_lane1",
            "neon_smull_4s_from_4h_by_lane2",
            "neon_smull_4s_from_4h_by_lane3",
            "neon_sqdmulh_8h_by_lane0",
            "neon_sqdmulh_8h_by_lane1",
            "neon_sqdmulh_8h_by_lane2",
            "neon_sqdmulh_8h_by_lane3",
            "neon_sqrdmulh_8h_by_lane2",
            "neon_sqrdmulh_8h_by_lane3",
            "neon_sqxtun2_16b_from_8h_keep_low64",
            "neon_sqxtun_8b_from_8h_zero_high64",
            "neon_srshr_8h_shift2",
            "neon_sshll2_2d_from_4s_shift0",
            "neon_sshll_2d_from_2s_shift0",
            "neon_sshll_4s_from_4h_shift13",
            "neon_ssubl2_4s_from_8h",
            "neon_ssubl_4s_from_4h",
            "neon_sub_4h_zero_high64",
            "neon_sub_4s",
            "neon_sub_8h",
            "neon_trn1_4s",
            "neon_trn1_8h",
            "neon_trn2_4s",
            "neon_trn2_8h",
            "neon_uaddw2_8h_from_8h_16b",
            "neon_uaddw_8h_from_8h_8b",
            "neon_umlal2_4s_from_8h",
            "neon_umlal2_8h_from_16b",
            "neon_umlal_4s_from_4h",
            "neon_umlsl2_4s_from_8h",
            "neon_umlsl_4s_from_4h",
            "neon_umull2_4s_from_8h",
            "neon_umull2_8h_from_16b",
            "neon_umull_4s_from_4h",
            "neon_umull_8h_from_8b",
            "neon_ushl_8h",
            "neon_ushll2_8h_from_16b_shift0",
            "neon_ushll_8h_from_8b_shift0",
            "neon_uzp1_16b",
            "neon_uzp1_8b_zero_high64",
            "neon_uzp1_8h",
            "neon_uzp2_8h",
            "neon_zip1_16b",
            "neon_zip1_4s",
            "neon_zip1_8b_zero_high64",
            "neon_zip2_4s",
            "neon_zip2_8b_zero_high64",
            "rbit",
            "rev",
            "rev16",
            "rev32",
            "smulh",
            "umulh",
        ]

        private static let stackIntrinsics: Set<String> = [
            "stack_alloc", "stack_free", "save_pair_writeback", "restore_pair_writeback",
        ]

        /// BL identity comes only from the little-endian instruction bytes. Names
        /// and sidecars (which may retain pre-symbolization text) are not authority.
        private static func directCallee(_ source: MacIRSourceSpan) -> UInt64? {
            let bytes = source.byteText.split(separator: " ")
            guard bytes.count == 4 else { return nil }
            var word: UInt32 = 0
            for (index, token) in bytes.enumerated() {
                guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
                word |= UInt32(byte) << (index * 8)
            }
            guard word & 0xfc00_0000 == 0x9400_0000 else { return nil }
            let offset = Int64(Int32(bitPattern: (word & 0x03ff_ffff) << 6) >> 6) * 4
            let result = offset < 0
                ? source.address.subtractingReportingOverflow(UInt64(-offset))
                : source.address.addingReportingOverflow(UInt64(offset))
            return result.overflow ? nil : result.partialValue
        }

        private static func isSP(_ value: MacIRValue) -> Bool {
            if case let .register(name, _) = value { return name == "sp" || name == "wsp" }
            return false
        }

        private static func adjustedSP(_ current: Int64?, by delta: Int64, subtract: Bool = false) -> Int64? {
            guard let current else { return nil }
            let result = subtract ? current.subtractingReportingOverflow(delta) : current.addingReportingOverflow(delta)
            return result.overflow ? nil : result.partialValue
        }

        private static func spMemory(_ instruction: MacIRInstruction) -> InstructionOperands.Memory? {
            guard let memory = MacIRBuilder.typedMemoryOperand(of: instruction.source),
                  MacIRBuilder.registerName(memory.base) == "sp", memory.index == nil,
                  memory.modifier == nil else { return nil }
            return memory
        }

        /// Non-writeback pairs must agree with typed SP addressing and fit below
        /// entry SP. This consumes existing tracking; it never restores lost SP authority.
        private static func framePairAccess(_ instruction: MacIRInstruction, spDelta: Int64?) -> Bool {
            guard case let .intrinsic(nil, name, args) = instruction.operation,
                  name == "save_pair" || name == "restore_pair",
                  args.count == 3 || args.count == 4,
                  let memory = spMemory(instruction), memory.indexing == .offset,
                  let spDelta, let width = instruction.memoryAccess?.byteWidth,
                  width > 0, width <= Int.max / 2 else { return false }
            let displacement: Int64
            switch args[2] {
            case let .stackSlot(offset): displacement = offset
            case let .register(name, _) where name == "sp" || name == "wsp": displacement = 0
            case let .binaryExpression(op, base, .immediate(offset)) where isSP(base):
                if op == "+" { displacement = offset }
                else if op == "-", offset != Int64.min { displacement = -offset }
                else { return false }
            default: return false
            }
            guard displacement == memory.displacement else { return false }
            if args.count == 4 {
                guard case let .stackSlot(second) = args[3],
                      adjustedSP(displacement, by: Int64(width)) == second else { return false }
            }
            guard let start = adjustedSP(spDelta, by: displacement), start < 0,
                  let end = adjustedSP(start, by: Int64(width * 2)) else { return false }
            return end <= 0
        }

        private static func frameWrite(_ instruction: MacIRInstruction, spDelta: Int64?) -> Bool {
            guard let memory = spMemory(instruction), let spDelta,
                  let width = instruction.memoryAccess?.byteWidth, width > 0 else { return false }
            let extent: Int
            switch instruction.operation {
            case .intrinsic(_, "save_pair", _):
                return framePairAccess(instruction, spDelta: spDelta)
            case let .store(_, address):
                // Builder stackSlot coordinates retain the literal SP displacement;
                // this contract adds the independently tracked entry-SP delta below.
                guard memory.indexing == .offset, case let .stackSlot(offset) = address,
                      offset == memory.displacement else { return false }
                extent = width
            case let .storeWriteback(_, _, base, delta, preIndex):
                guard isSP(base), memory.displacement == delta,
                      memory.indexing == (preIndex ? .preIndex : .postIndex) else { return false }
                extent = width
            case let .intrinsic(_, "save_pair_writeback", args):
                guard args.count == 6, isSP(args[2]), isSP(args[3]),
                      case let .immediate(delta) = args[4], case let .immediate(pre) = args[5],
                      pre == 0 || pre == 1, memory.displacement == delta,
                      memory.indexing == (pre == 1 ? .preIndex : .postIndex), width <= Int.max / 2 else { return false }
                extent = width * 2
            default: return false
            }
            // Pre-index uses the updated SP; post-index accesses the old SP.
            guard let start = adjustedSP(spDelta, by: memory.indexing == .postIndex ? 0 : memory.displacement),
                  start < 0, let end = adjustedSP(start, by: Int64(extent)) else { return false }
            return end <= 0
        }

        private static func updatedSP(_ instruction: MacIRInstruction, current: Int64?) -> Int64? {
            switch instruction.operation {
            case let .intrinsic(destination, name, args) where name == "stack_alloc" || name == "stack_free":
                guard let destination, isSP(destination), args.count == 1,
                      case let .immediate(amount) = args[0] else { return nil }
                return adjustedSP(current, by: amount, subtract: name == "stack_alloc")
            case let .intrinsic(_, name, args) where name == "save_pair_writeback" || name == "restore_pair_writeback":
                guard let memory = spMemory(instruction), args.count == 6,
                      isSP(args[2]), isSP(args[3]), case let .immediate(delta) = args[4],
                      case let .immediate(pre) = args[5], pre == 0 || pre == 1,
                      memory.displacement == delta,
                      memory.indexing == (pre == 1 ? .preIndex : .postIndex) else { return nil }
                return adjustedSP(current, by: delta)
            case let .storeWriteback(_, destination, base, delta, pre),
                 let .loadWriteback(_, destination, base, delta, pre):
                guard isSP(destination) else { return current }
                guard isSP(base), let memory = spMemory(instruction), memory.displacement == delta,
                      memory.indexing == (pre ? .preIndex : .postIndex) else { return nil }
                return adjustedSP(current, by: delta)
            case let .assign(destination, _), let .binary(destination, _, _, _),
                 let .load(destination, _), let .stackSlotRead(destination, _, _),
                 let .select(destination, _, _, _, _, _), let .compareToBool(destination, _, _, _):
                return isSP(destination) ? nil : current
            case let .stackSlotPairRead(first, _, _, second, _, _):
                return isSP(first) || isSP(second) ? nil : current
            case .unknown: return nil
            case let .intrinsic(destination, name, args) where name == "save_pair" || name == "restore_pair"
                || registerOnlyIntrinsics.contains(name):
                // Non-writeback pairs and the explicit register-only contracts do
                // not alter SP. Restore operands 0/1 are destinations; a spelled
                // sp/wsp destination still invalidates the entry-SP coordinate.
                if destination.map(isSP) == true { return nil }
                if name == "restore_pair", args.prefix(2).contains(where: isSP) { return nil }
                return current
            case let .intrinsic(destination, name, _):
                // Keep adrp's existing register-only constant behavior unchanged.
                return name == "adrp" && destination.map({ !isSP($0) }) == true ? current : nil
            default: return current
            }
        }

        static func adding(_ delta: Int64, subtract: Bool, to path: FieldPath) -> FieldPath? {
            var components = path.components
            let offset = components[components.count - 1]
            let result = subtract ? offset.subtractingReportingOverflow(delta) : offset.addingReportingOverflow(delta)
            guard !result.overflow else { return nil }
            components[components.count - 1] = result.partialValue
            return FieldPath(parameter: path.parameter, components: components)
        }

        /// `struct T *`, `T *` or `const T *` names T; scalars and multi-level pointers do not.
        static func pointeeTypeName(_ type: String) -> String? {
            let trimmed = type.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("*"), !trimmed.dropLast().trimmingCharacters(in: .whitespaces).hasSuffix("*") else {
                return nil
            }
            var words = trimmed.dropLast().split(separator: " ").map(String.init).filter { $0 != "const" && $0 != "volatile" }
            if words.first == "struct" || words.first == "union" { words.removeFirst() }
            guard words.count == 1, let name = words.first, PseudocodePrinter.isCIdentifier(name),
                  !scalarNames.contains(name) else { return nil }
            return name
        }

        private static let scalarNames: Set<String> = [
            "void", "char", "int", "short", "long", "float", "double", "bool", "_Bool",
            "int8_t", "uint8_t", "int16_t", "uint16_t", "int32_t", "uint32_t", "int64_t", "uint64_t",
            "size_t", "ssize_t", "intptr_t", "uintptr_t",
        ]
    }
}
