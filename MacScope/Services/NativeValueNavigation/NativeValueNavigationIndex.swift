import Foundation

/// A transient index of the existing MacScope wire result. Every stored semantic
/// record is an existing NativeDecompilerWire type, not a new canonical IR.
/// Construct only after native wire/runtime admission. The extra checks below
/// protect query invariants and avoid trapping Dictionary(uniqueKeysWithValues:).
struct NativeValueNavigationIndex: Sendable {
    let requestID: UUID
    let requestSHA256: String
    let image: NativeDecompilerWireImageIdentity
    let function: NativeDecompilerWireFunctionIdentity
    let limits: NativeValueNavigationLimits
    let values: [String: NativeDecompilerWireSSAValueRecord]
    let varnodes: [String: NativeDecompilerWireVarnodeRecord]
    let operations: [String: NativeDecompilerWireOperationRecord]
    let bindings: [String: NativeDecompilerWireSSABindingRecord]
    let phis: [String: NativeDecompilerWirePhiRecord]
    let variables: [String: NativeDecompilerWireVariableRecord]
    let calls: [String: NativeDecompilerWireCallRecord]
    let instructions: [String: NativeDecompilerWireInstructionRecord]
    let tokens: [String: NativeDecompilerWirePseudocodeTokenRecord]
    let valuesByVarnode: [String: [String]]
    let variableNamesByVarnode: [String: [String]]
    let usesByValue: [String: [NativeValueNavigationUse]]
    let phiOperationIDs: [String: String]
    let callOperationIDs: Set<String>
    let memoryOperationIDs: Set<String>

    init(
        result: NativeDecompilerWireStructuredResult,
        limits: NativeValueNavigationLimits = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        try limits.validate()
        guard !result.ssaValues.isEmpty, !result.ssaBindings.isEmpty else {
            throw NativeValueNavigationFailure.noStructuredValues
        }
        guard result.operations.count <= limits.maximumOperations else {
            throw NativeValueNavigationFailure.indexLimit("operations")
        }
        guard result.ssaValues.count <= limits.maximumValues else {
            throw NativeValueNavigationFailure.indexLimit("SSA values")
        }
        var budget = NativeValueNavigationBuildBudget(limits: limits, isCancelled: isCancelled)
        let values = try Self.table(result.ssaValues, id: \.id, kind: "SSA value", budget: &budget)
        let varnodes = try Self.table(result.varnodes, id: \.id, kind: "varnode", budget: &budget)
        let operations = try Self.table(result.operations, id: \.id, kind: "operation", budget: &budget)
        let bindings = try Self.table(result.ssaBindings, id: \.operationID, kind: "SSA binding", budget: &budget)
        let phis = try Self.table(result.phis, id: \.id, kind: "phi", budget: &budget)
        let variables = try Self.table(result.variables, id: \.id, kind: "variable", budget: &budget)
        let calls = try Self.table(result.calls, id: \.id, kind: "call", budget: &budget)
        let instructions = try Self.table(result.instructions, id: \.id, kind: "instruction", budget: &budget)
        let tokens = try Self.table(result.tokens, id: \.id, kind: "token", budget: &budget)
        let blocks = try Self.table(result.blocks, id: \.id, kind: "block", budget: &budget)
        let edges = try Self.table(result.edges, id: \.id, kind: "edge", budget: &budget)
        _ = try Self.table(result.memoryEffects, id: \.id, kind: "memory effect", budget: &budget)

        guard result.function.entryAddress.value < result.function.endAddressExclusive.value else {
            throw NativeValueNavigationFailure.invalidSourceRange("function")
        }
        if let ranges = result.function.codeRanges {
            guard !ranges.isEmpty else {
                throw NativeValueNavigationFailure.invalidSourceRange("empty function codeRanges")
            }
            try budget.addReferences(ranges.count)
            var previousEnd: UInt64?
            for range in ranges {
                let start = range.startAddress.value
                let end = range.endAddressExclusive.value
                guard start < end,
                      start >= result.function.entryAddress.value,
                      end <= result.function.endAddressExclusive.value,
                      previousEnd.map({ $0 <= start }) ?? true else {
                    throw NativeValueNavigationFailure.invalidSourceRange("function codeRanges")
                }
                previousEnd = end
            }
        }

        var valuesByVarnode: [String: [String]] = [:]
        for value in result.ssaValues {
            try budget.addReferences()
            guard varnodes[value.varnodeID] != nil else {
                throw NativeValueNavigationFailure.missingReference("varnode", value.varnodeID)
            }
            valuesByVarnode[value.varnodeID, default: []].append(value.id)
            switch value.kind {
            case .operationResult:
                guard let id = value.definingOperationID,
                      value.definingPhiID == nil,
                      operations[id] != nil,
                      bindings[id]?.outputSSAValueID == value.id else {
                    throw NativeValueNavigationFailure.invalidBinding(value.id)
                }
            case .phiResult:
                guard let id = value.definingPhiID,
                      value.definingOperationID == nil,
                      phis[id]?.outputSSAValueID == value.id else {
                    throw NativeValueNavigationFailure.invalidBinding(value.id)
                }
            case .functionEntry, .constant, .annotation:
                guard value.definingOperationID == nil, value.definingPhiID == nil else {
                    throw NativeValueNavigationFailure.invalidBinding(value.id)
                }
            }
        }
        for key in valuesByVarnode.keys.sorted() {
            valuesByVarnode[key]?.sort()
        }

        var variableNamesByVarnode: [String: [String]] = [:]
        for variable in result.variables {
            try budget.addReferences(variable.storageVarnodeIDs.count)
            for id in variable.storageVarnodeIDs {
                guard varnodes[id] != nil else {
                    throw NativeValueNavigationFailure.missingReference("variable storage", id)
                }
                variableNamesByVarnode[id, default: []].append(variable.name)
            }
        }
        for key in variableNamesByVarnode.keys.sorted() {
            variableNamesByVarnode[key] = Array(Set(variableNamesByVarnode[key] ?? [])).sorted()
        }

        var phiOperationIDs: [String: String] = [:]
        var phiByOutput: [String: String] = [:]
        for phi in result.phis {
            try budget.addReferences(1 + phi.incoming.count)
            guard phiByOutput.updateValue(phi.id, forKey: phi.outputSSAValueID) == nil,
                  let value = values[phi.outputSSAValueID],
                  value.kind == .phiResult, value.definingPhiID == phi.id,
                  value.varnodeID == phi.varnodeID,
                  blocks[phi.blockID] != nil, !phi.incoming.isEmpty else {
                throw NativeValueNavigationFailure.invalidBinding(phi.id)
            }
            for incoming in phi.incoming {
                guard values[incoming.ssaValueID] != nil else {
                    throw NativeValueNavigationFailure.missingReference("phi input", incoming.ssaValueID)
                }
                if let blockID = incoming.sourceBlockID, blocks[blockID] == nil {
                    throw NativeValueNavigationFailure.missingReference("phi predecessor", blockID)
                }
                if let edgeID = incoming.edgeID {
                    guard let edge = edges[edgeID],
                          edge.sourceBlockID == incoming.sourceBlockID,
                          edge.targetBlockID == phi.blockID else {
                        throw NativeValueNavigationFailure.invalidBinding(phi.id)
                    }
                }
            }
        }

        var uses: [String: [NativeValueNavigationUse]] = [:]
        for operation in result.operations {
            try budget.addReferences(operation.inputVarnodeIDs.count + operation.sourceRanges.count + 1)
            guard blocks[operation.blockID] != nil,
                  let binding = bindings[operation.id],
                  binding.inputSSAValueIDs.count == operation.inputVarnodeIDs.count else {
                throw NativeValueNavigationFailure.invalidBinding(operation.id)
            }
            for range in operation.sourceRanges {
                guard Self.admits(range: range, imageID: result.image.imageID, function: result.function) else {
                    throw NativeValueNavigationFailure.invalidSourceRange(operation.id)
                }
            }
            for (index, id) in binding.inputSSAValueIDs.enumerated() {
                guard let value = values[id], value.varnodeID == operation.inputVarnodeIDs[index] else {
                    throw NativeValueNavigationFailure.invalidBinding(operation.id)
                }
            }
            if let id = binding.outputSSAValueID {
                guard let value = values[id], value.varnodeID == operation.outputVarnodeID else {
                    throw NativeValueNavigationFailure.invalidBinding(operation.id)
                }
            } else if operation.outputVarnodeID != nil {
                throw NativeValueNavigationFailure.invalidBinding(operation.id)
            }

            if operation.opcode == .multiequal {
                guard let output = binding.outputSSAValueID,
                      let phiID = phiByOutput[output],
                      let phi = phis[phiID],
                      phi.blockID == operation.blockID,
                      phi.incoming.map(\.ssaValueID) == binding.inputSSAValueIDs,
                      phiOperationIDs.updateValue(operation.id, forKey: phiID) == nil else {
                    throw NativeValueNavigationFailure.invalidBinding(operation.id)
                }
                // The explicit phi below preserves predecessor/edge labels and replaces
                // the unqualified MULTIEQUAL operand occurrences. Do not double count.
                continue
            }
            for (inputIndex, valueID) in binding.inputSSAValueIDs.enumerated() {
                uses[valueID, default: []].append(.init(
                    site: .operation(operation.id), inputIndex: inputIndex,
                    outputValueID: binding.outputSSAValueID,
                    predecessorBlockID: nil, incomingEdgeID: nil
                ))
            }
        }
        // A dangling extra binding is invalid even if no query would visit it.
        for binding in result.ssaBindings where operations[binding.operationID] == nil {
            throw NativeValueNavigationFailure.missingReference("binding operation", binding.operationID)
        }
        for phi in result.phis {
            for (inputIndex, incoming) in phi.incoming.enumerated() {
                uses[incoming.ssaValueID, default: []].append(.init(
                    site: .phi(phi.id), inputIndex: inputIndex,
                    outputValueID: phi.outputSSAValueID,
                    predecessorBlockID: incoming.sourceBlockID, incomingEdgeID: incoming.edgeID
                ))
            }
        }

        var callOperationIDs = Set<String>()
        for call in result.calls {
            try budget.addReferences()
            guard operations[call.operationID] != nil else {
                throw NativeValueNavigationFailure.missingReference("call operation", call.operationID)
            }
            callOperationIDs.insert(call.operationID)
        }
        var memoryOperationIDs = Set<String>()
        for effect in result.memoryEffects {
            try budget.addReferences()
            guard operations[effect.operationID] != nil else {
                throw NativeValueNavigationFailure.missingReference("memory operation", effect.operationID)
            }
            memoryOperationIDs.insert(effect.operationID)
        }
        for instruction in result.instructions {
            try budget.addReferences(instruction.operationIDs.count)
            for id in instruction.operationIDs where operations[id] == nil {
                throw NativeValueNavigationFailure.missingReference("instruction operation", id)
            }
        }
        // Account for variable/token reference arrays before candidate enumeration.
        for token in result.tokens {
            try budget.addReferences(token.entityReferences.count + token.sourceRanges.count)
        }

        func order(_ site: NativeValueNavigationSite) -> (UInt64, String) {
            switch site {
            case let .operation(id): return (operations[id]?.sequence.value ?? .max, "operation:" + id)
            case let .phi(id):
                let operationID = phiOperationIDs[id] ?? ""
                return (operations[operationID]?.sequence.value ?? .max, "phi:" + id)
            }
        }
        for key in uses.keys.sorted() {
            try budget.checkCancellation()
            uses[key]?.sort {
                let left = order($0.site), right = order($1.site)
                if left.0 != right.0 { return left.0 < right.0 }
                if left.1 != right.1 { return left.1 < right.1 }
                return $0.inputIndex < $1.inputIndex
            }
        }

        self.requestID = result.requestID
        self.requestSHA256 = result.requestSHA256
        self.image = result.image
        self.function = result.function
        self.limits = limits
        self.values = values
        self.varnodes = varnodes
        self.operations = operations
        self.bindings = bindings
        self.phis = phis
        self.variables = variables
        self.calls = calls
        self.instructions = instructions
        self.tokens = tokens
        self.valuesByVarnode = valuesByVarnode
        self.variableNamesByVarnode = variableNamesByVarnode
        self.usesByValue = uses
        self.phiOperationIDs = phiOperationIDs
        self.callOperationIDs = callOperationIDs
        self.memoryOperationIDs = memoryOperationIDs
    }

    private static func table<Record>(
        _ records: [Record], id: KeyPath<Record, String>, kind: String,
        budget: inout NativeValueNavigationBuildBudget
    ) throws -> [String: Record] {
        try budget.addRecords(records.count)
        var result: [String: Record] = [:]
        result.reserveCapacity(records.count)
        for record in records {
            try budget.checkCancellation()
            let key = record[keyPath: id]
            guard !key.isEmpty, result.updateValue(record, forKey: key) == nil else {
                throw NativeValueNavigationFailure.duplicateRecord(kind, key)
            }
        }
        return result
    }

    static func admits(
        range: NativeDecompilerWireSourceRange,
        imageID: String, function: NativeDecompilerWireFunctionIdentity
    ) -> Bool {
        let start = range.startAddress.value, end = range.endAddressExclusive.value
        guard range.imageID == imageID, start < end,
              start >= function.entryAddress.value,
              end <= function.endAddressExclusive.value else { return false }
        if let extents = function.codeRanges {
            // Adjacent exact extents may cover one source range; a true gap may not.
            var cursor = start
            for extent in extents {
                guard extent.startAddress.value <= cursor else { return false }
                if extent.endAddressExclusive.value > cursor {
                    cursor = extent.endAddressExclusive.value
                    if cursor >= end { return true }
                }
            }
            return false
        }
        return true
    }

    func sourceRanges(for site: NativeValueNavigationSite) -> [NativeDecompilerWireSourceRange] {
        let raw: [NativeDecompilerWireSourceRange]
        switch site {
        case let .operation(id): raw = operations[id]?.sourceRanges ?? []
        case let .phi(id): raw = operations[phiOperationIDs[id] ?? ""]?.sourceRanges ?? []
        }
        struct RangeKey: Hashable { let imageID: String; let start: UInt64; let end: UInt64 }
        var seen = Set<RangeKey>()
        var unique: [NativeDecompilerWireSourceRange] = []
        // Work is bounded before deduplication/sorting; callers disclose omitted ranges.
        for range in raw.prefix(limits.maximumSourceRanges) {
            let key = RangeKey(imageID: range.imageID, start: range.startAddress.value, end: range.endAddressExclusive.value)
            if seen.insert(key).inserted { unique.append(range) }
        }
        return unique.sorted {
            if $0.startAddress.value != $1.startAddress.value {
                return $0.startAddress.value < $1.startAddress.value
            }
            return $0.endAddressExclusive.value < $1.endAddressExclusive.value
        }
    }

    func hasOmittedSourceRanges(for site: NativeValueNavigationSite) -> Bool {
        switch site {
        case let .operation(id):
            return (operations[id]?.sourceRanges.count ?? 0) > limits.maximumSourceRanges
        case let .phi(id):
            return (operations[phiOperationIDs[id] ?? ""]?.sourceRanges.count ?? 0) > limits.maximumSourceRanges
        }
    }

    func siteLabel(_ site: NativeValueNavigationSite) -> String {
        switch site {
        case let .operation(id): "\(operations[id]?.opcode.rawValue ?? "operation") · \(id)"
        case let .phi(id): "phi · \(id)"
        }
    }

    /// Does not traverse MemorySSA or infer aliasing. Even a populated memory
    /// partition alone is not evidence that this LOAD reads a particular STORE.
    func boundary(for operation: NativeDecompilerWireOperationRecord)
        -> (NativeValueNavigationBoundaryKind, String)? {
        if operation.authenticationEffect.kind != .none {
            return (.authentication, "An authentication effect is recorded. This query does not interpret its value transformation.")
        }
        if callOperationIDs.contains(operation.id) || operation.opcode == .call || operation.opcode == .callind {
            return (.call, "A call consumes or defines this value. Callee data flow and call effects are not traversed.")
        }
        if memoryOperationIDs.contains(operation.id) || operation.opcode == .load || operation.opcode == .store {
            return (.memory, "A memory access is recorded. Address dependencies are not treated as the contents of memory; aliases are not inferred.")
        }
        switch operation.opcode {
        case .callother, .indirect, .constantPoolReference, .new, .segmentOperation:
            return (.opaqueOperation, "This operation has effects this query does not model. The recorded site remains visible.")
        default: return nil
        }
    }
}
