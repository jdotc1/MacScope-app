import Foundation

extension WorkspaceScriptingAPI {
    /// Recovery runs only on an owned snapshot worker for async/attached callers. The legacy
    /// synchronous registry remains available to CLI callers, with the same in-budget shape.
    nonisolated static func boundedStackLocals(
        arguments: ScriptValue, snapshot: WorkspaceSnapshot, checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        let slot = snapshot.primarySlot
        var budget = SnapshotAnalysisReadBudget()
        try budget.prepare(snapshot, checkpoint: checkpoint)
        let function = try boundedSnapshotFunction(arguments, snapshot: snapshot, checkpoint: checkpoint)
        let rows = snapshot.pseudocodeTarget(selectedAddress: function.startAddress, in: slot)?.instructions ?? []
        try budget.admitFunction(rows.count)
        try checkpoint()
        let edits = snapshot.stackLocalOverrides(forProcedureAt: function.startAddress, in: slot)
        let irFunction = PseudocodePrinter().buildFunction(
            functionName: snapshot.displayName(at: function.startAddress, in: slot, default: function.name),
            startAddress: function.startAddress,
            jumpTables: snapshot.resolvedJumpTables(in: slot),
            objcSelectors: snapshot.analysis(in: slot)?.objcSelectors ?? [:],
            constantStrings: snapshot.constantStrings(in: slot),
            signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
            authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
            types: snapshot.typeDefinitions,
            instructions: rows
        )
        try checkpoint()
        try budget.take(irFunction.localVariables.count)
        var recovered: [String: ScriptValue] = [:]
        for local in irFunction.localVariables {
            try checkpoint()
            try budget.text(local.name); try budget.text(local.type)
            guard let storage = local.stackStorage else { continue }
            recovered[storage.authoringKey] = .object([
                "name": .string(local.name), "type": .string(local.type),
                "role": .string(storage.role.rawValue), "escapes": .bool(storage.escapes),
            ])
        }
        // A register rename applies to every occurrence (x and w views); it is an orphan
        // when the function's rows never name that register.
        var referenced = Set<String>()
        for row in irFunction.instructions {
            try checkpoint()
            for token in row.source.operands.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                guard let first = token.first, first == "x" || first == "w",
                      let index = Int(token.dropFirst()), (0...30).contains(index) else { continue }
                referenced.insert("x\(index)")
            }
        }
        let registerNames = snapshot.registerNameOverrides(forProcedureAt: function.startAddress, in: slot)
        try checkpoint()
        return .object([
            "address": .hex(function.startAddress),
            "recovered": .object(recovered),
            "registers": .object(registerNames.reduce(into: [:]) { result, entry in
                let key = entry.key.hasPrefix("w") ? "x" + entry.key.dropFirst() : entry.key
                result[entry.key] = .object(["name": .string(entry.value), "orphan": .bool(!referenced.contains(key))])
            }),
            "edits": .object(edits.reduce(into: [:]) { result, entry in
                result[entry.key] = .object([
                    "name": entry.value.name.map(ScriptValue.string) ?? .null,
                    "type": entry.value.typeName.map(ScriptValue.string) ?? .null,
                    "orphan": .bool(recovered[entry.key] == nil),
                ])
            }),
        ])
    }

    nonisolated static func boundedStructCandidate(
        arguments: ScriptValue, snapshot: WorkspaceSnapshot, checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        var budget = SnapshotAnalysisReadBudget()
        try budget.prepare(snapshot, checkpoint: checkpoint)
        let function = try boundedSnapshotFunction(arguments, snapshot: snapshot, checkpoint: checkpoint)
        guard let parameter = arguments["parameter"]?.intValue, (0...7).contains(parameter) else {
            throw ScriptingError.invalidArgument("parameter must be a GPR argument index 0...7")
        }
        let slot = snapshot.primarySlot
        let printer = PseudocodePrinter()
        func build(_ function: FunctionSummary) throws -> MacIRFunction {
            try checkpoint()
            let rows = snapshot.pseudocodeTarget(selectedAddress: function.startAddress, in: slot)?.instructions ?? []
            try budget.admitFunction(rows.count)
            let built = printer.buildFunction(
                functionName: snapshot.displayName(at: function.startAddress, in: slot, default: function.name),
                startAddress: function.startAddress,
                jumpTables: snapshot.resolvedJumpTables(in: slot),
                objcSelectors: snapshot.analysis(in: slot)?.objcSelectors ?? [:],
                constantStrings: snapshot.constantStrings(in: slot),
                signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
                authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
                types: snapshot.typeDefinitions, instructions: rows)
            try checkpoint()
            return built
        }
        let functions = snapshot.analysis(in: slot)?.functions ?? []
        var built: [String: MacIRFunction] = [:]
        var failure: Error?
        let root = try build(function)
        let candidate = MacIRStructUsageAnalysis.candidate(
            for: .parameter(gprIndex: Int(parameter)), in: root, callees: { target in
                guard failure == nil else { return nil }
                do {
                    try checkpoint()
                    if let cached = built[target] { return cached }
                    guard built.count < maximumStructRecoveryCallees else { return nil }
                    // Bound repeated unsuccessful name searches as well as successful lifts.
                    try budget.take(functions.count)
                    var match: FunctionSummary?
                    for (index, candidate) in functions.enumerated() {
                        if index % checkpointInterval == 0 { try checkpoint() }
                        guard candidate.name == target || snapshot.displayName(
                            at: candidate.startAddress, in: slot, default: candidate.name) == target else { continue }
                        guard match == nil else { return nil }
                        match = candidate
                    }
                    guard let match else { return nil }
                    let function = try build(match)
                    built[target] = function
                    return function
                } catch { failure = error; return nil }
            })
        if let failure { throw failure }
        try checkpoint()
        let result = scriptValue(candidate)
        try checkpoint()
        return result
    }
}
