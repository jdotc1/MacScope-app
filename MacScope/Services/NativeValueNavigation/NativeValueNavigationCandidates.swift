import Foundation

extension NativeValueNavigationIndex {
    func candidates(
        forTokenID tokenID: String,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> NativeValueNavigationCandidates {
        guard let token = tokens[tokenID] else { throw NativeValueNavigationFailure.unknownToken }
        var reached = Set<NativeValueNavigationLimit>()
        var scans = 0
        var storageIDs = Set<String>()
        var contextOperationIDs = Set<String>()
        var hasStorageReference = false

        func tick() throws -> Bool {
            if isCancelled() { throw CancellationError() }
            guard scans < limits.maximumCandidateScan else {
                reached.insert(.candidateScan)
                return false
            }
            scans += 1
            return true
        }
        func context(_ id: String) throws {
            guard operations[id] != nil else {
                throw NativeValueNavigationFailure.missingReference("token operation", id)
            }
            if contextOperationIDs.contains(id) { return }
            guard contextOperationIDs.count < limits.maximumContextOperations else {
                reached.insert(.contextOperations)
                return
            }
            contextOperationIDs.insert(id)
        }
        if token.entityReferences.count > limits.maximumTokenReferences {
            reached.insert(.tokenReferences)
        }
        let references = token.entityReferences.prefix(limits.maximumTokenReferences).sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id < $1.id
        }
        entityLoop: for reference in references {
            guard try tick() else { break }
            switch reference.kind {
            case .varnode:
                hasStorageReference = true
                guard varnodes[reference.id] != nil else {
                    throw NativeValueNavigationFailure.missingReference("token varnode", reference.id)
                }
                storageIDs.insert(reference.id)
            case .variable:
                hasStorageReference = true
                guard let variable = variables[reference.id] else {
                    throw NativeValueNavigationFailure.missingReference("token variable", reference.id)
                }
                for id in variable.storageVarnodeIDs {
                    guard try tick() else { break entityLoop }
                    storageIDs.insert(id)
                }
            case .operation:
                try context(reference.id)
            case .instruction:
                guard let instruction = instructions[reference.id] else {
                    throw NativeValueNavigationFailure.missingReference("token instruction", reference.id)
                }
                for id in instruction.operationIDs {
                    guard try tick() else { break entityLoop }
                    try context(id)
                    if reached.contains(.contextOperations) { break }
                }
            case .call:
                guard let call = calls[reference.id] else {
                    throw NativeValueNavigationFailure.missingReference("token call", reference.id)
                }
                try context(call.operationID)
            case .block, .region, .type:
                // Neither source overlap, a whole basic block, nor a matching name
                // proves that a particular SSA value belongs to this token.
                break
            }
        }

        var contextValues = Set<String>()
        var contextsByValue: [String: [String]] = [:]
        contextLoop: for id in contextOperationIDs.sorted() {
            guard try tick() else { break }
            guard let binding = bindings[id] else {
                throw NativeValueNavigationFailure.invalidBinding(id)
            }
            if let output = binding.outputSSAValueID {
                contextValues.insert(output)
                contextsByValue[output, default: []].append("Output of " + id)
            }
            for (offset, valueID) in binding.inputSSAValueIDs.enumerated() {
                guard try tick() else { break contextLoop }
                contextValues.insert(valueID)
                if contextsByValue[valueID, default: []].count < 8 {
                    contextsByValue[valueID, default: []].append("Input \(offset) of " + id)
                }
            }
        }
        var storageValues = Set<String>()
        storageLoop: for storageID in storageIDs.sorted() {
            for valueID in valuesByVarnode[storageID] ?? [] {
                guard try tick() else { break storageLoop }
                storageValues.insert(valueID)
            }
        }

        let candidates: Set<String>
        if hasStorageReference {
            candidates = contextOperationIDs.isEmpty
                ? storageValues : storageValues.intersection(contextValues)
        } else {
            candidates = contextValues
        }
        if candidates.count > limits.maximumCandidates { reached.insert(.candidateCount) }
        let selected = candidates.sorted().prefix(limits.maximumCandidates)
        let rows = selected.compactMap { valueID -> NativeValueNavigationCandidate? in
            guard let value = values[valueID], let varnode = varnodes[value.varnodeID] else { return nil }
            return .init(
                ssaValueID: valueID, varnodeID: value.varnodeID, kind: value.kind,
                registerName: varnode.registerName,
                variableNames: Array((variableNamesByVarnode[value.varnodeID] ?? []).prefix(8)),
                contexts: Array((contextsByValue[valueID] ?? []).prefix(8))
            )
        }
        let storageOnly = hasStorageReference && contextOperationIDs.isEmpty
        let explanation: String
        if rows.isEmpty {
            explanation = reached.isEmpty
                ? "The selected token has no identifiable SSA value in its recorded context."
                : "The bounded candidate scan did not identify a selectable value. No absent relationship is implied."
        } else if storageOnly {
            explanation = "These values share the token's recorded storage. Choose a value; the token does not identify an exact SSA version."
        } else {
            explanation = "Values linked by the token's entity references and recorded operation context."
        }
        return .init(
            tokenID: tokenID, candidates: rows, limitsReached: reached,
            usesStorageAssociationOnly: storageOnly, explanation: explanation
        )
    }
}
