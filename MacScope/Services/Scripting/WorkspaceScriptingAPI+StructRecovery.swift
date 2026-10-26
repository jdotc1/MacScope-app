import Foundation

/// DP04 D2: struct recovery for scripting/MCP. `recover-struct-candidate` is read-only;
/// `accept-struct-candidate` recomputes the candidate and commits only when its id still
/// matches (stale evidence rejects), through the existing type-authoring path.
extension WorkspaceScriptingAPI {
    nonisolated static let maximumStructRecoveryCallees = 16

    /// The candidate for parameter `parameter` (GPR index) of a primary-image function, with
    /// direct callees resolved by name inside the same image.
    nonisolated static func structCandidate(
        snapshot: WorkspaceSnapshot,
        function: FunctionSummary,
        parameter: Int
    ) -> StructLayoutCandidate {
        let slot = snapshot.primarySlot
        let printer = PseudocodePrinter()
        func build(_ function: FunctionSummary) -> MacIRFunction {
            printer.buildFunction(
                functionName: snapshot.displayName(at: function.startAddress, in: slot, default: function.name),
                startAddress: function.startAddress,
                jumpTables: snapshot.resolvedJumpTables(in: slot),
                objcSelectors: snapshot.analysis(in: slot)?.objcSelectors ?? [:],
                constantStrings: snapshot.constantStrings(in: slot),
                signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
                authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
                types: snapshot.typeDefinitions,
                instructions: snapshot.pseudocodeTarget(selectedAddress: function.startAddress, in: slot)?.instructions ?? []
            )
        }
        let functions = snapshot.analysis(in: slot)?.functions ?? []
        var built: [String: MacIRFunction] = [:]
        let resolver: MacIRStructUsageAnalysis.CalleeResolver = { target in
            if let cached = built[target] { return cached }
            guard built.count < maximumStructRecoveryCallees else { return nil }
            let matches = functions.filter {
                $0.name == target || snapshot.displayName(at: $0.startAddress, in: slot, default: $0.name) == target
            }
            guard matches.count == 1, let callee = matches.first else { return nil }
            let function = build(callee)
            built[target] = function
            return function
        }
        return MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: parameter), in: build(function),
                                                  callees: resolver)
    }

    nonisolated static func scriptValue(_ candidate: StructLayoutCandidate) -> ScriptValue {
        func field(_ field: StructLayoutCandidate.Field) -> ScriptValue {
            .object([
                "offset": .int(field.offset), "width": .int(Int64(field.byteWidth)),
                "roles": .array(field.roles.map { .string($0.rawValue) }),
                "evidence": .array(field.evidence.map { observation in
                    .object(["address": .hex(observation.sourceAddress),
                             "viaCalls": .array(observation.viaCalls.map(ScriptValue.string))])
                }),
            ])
        }
        return .object([
            "candidate": .string(candidate.candidateID),
            "root": .string(candidate.root.identity),
            "fields": .array(candidate.fields.map(field)),
            "conflicts": .array(candidate.conflicts.map { conflict in
                .object(["start": .int(conflict.range.lowerBound), "end": .int(conflict.range.upperBound),
                         "fields": .array(conflict.fields.map(field))])
            }),
            "unknownGaps": .array(candidate.unknownGaps.map { .object(["start": .int($0.lowerBound), "end": .int($0.upperBound)]) }),
            "extentLowerBound": .int(candidate.extentLowerBound),
            "needsRebase": .bool(candidate.needsRebase),
            "unresolvedAccesses": .array(candidate.unresolvedAccessAddresses.map(ScriptValue.hex)),
            "incomplete": .array(candidate.incompleteness.map(\.rawValue).sorted().map(ScriptValue.string)),
        ])
    }

    nonisolated static func refusalText(_ refusal: StructCandidateTypeAdapter.Refusal) -> String {
        switch refusal {
        case .invalidName: "name must be a C identifier"
        case .nameInUse: "a type with that name already exists"
        case .needsRebase: "the root is an interior pointer (negative offsets); it cannot describe an object"
        case let .unresolvedConflict(range):
            "choose exactly one field (offset, width) for the overlap \(range.lowerBound)..<\(range.upperBound)"
        case .noFields: "the candidate has no fields"
        case .layoutMismatch: "the C layout cannot reproduce the observed offsets"
        }
    }
}
