import Foundation

/// Test-only contract plumbing, not a capture loader or a source interpreter.
/// SOURCE_ONLY / NOT_RUN. No cohort fixture or fresh-baseline authority is
/// established here. A later fixture loader must bind these independently
/// frozen facts to the exact original capture and current-main baseline document.
/// Candidate text and candidate product plans must never create this manifest.
enum NativeScalarNoCallContract {
    typealias C = OrdinaryC

    struct Formal {
        let name: String
        let type: C.CType
    }
    enum Terminal {
        case void
        case value(name: String, type: C.CType)
        case unavailableReturnContract
    }
    enum EntryEnvelope {
        case declaredFormals
        // Exact metadata bytes from fresh baseline. Names/types/ABI permissions come
        // from the separate original typed input binding, not this comment.
        case frozenABIInputs(comment: String)
    }
    struct FrozenManifest {
        let signature: String
        let formals: [Formal]
        let sourceAddresses: [UInt64]
        let terminalRow: Int
        let terminalPayload: String
        let terminal: Terminal
        let labelAddresses: Set<UInt64>
        let memoryEffects: [Int: [C.MemoryEffect]]
        var entryEnvelope: EntryEnvelope = .declaredFormals
    }

    /// Only scalar formal declarations are supported in this prerequisite.
    /// Unknown signature types fail instead of acquiring guessed ABI bindings.
    private static func spelling(_ type: C.CType) throws -> String {
        guard !type.pointer, [8, 16, 32, 64].contains(type.width) else {
            throw C.Failure.unsupportedSyntax("no-call contract requires an exact scalar formal type")
        }
        return "\(type.unsigned ? "u" : "")int\(type.width)_t"
    }
    private static func validName(_ name: String) -> Bool {
        C.identifier(name) && !C.Parser.reserved.contains(name) && C.CType.named(name) == nil
            && name != "unresolved_return_contract"
    }
    private static func validateSignature(_ manifest: FrozenManifest) throws {
        let tokens = try C.lex(manifest.signature).map(\.text)
        guard tokens.count >= 5, tokens[0] == "void" || C.CType.named(tokens[0]) != nil,
              validName(tokens[1]), tokens[2] == "(",
              Array(tokens.suffix(2)) == [")", "{"] else {
            throw C.Failure.unsupportedSyntax("unmodeled no-call signature")
        }
        guard Set(manifest.formals.map(\.name)).count == manifest.formals.count else {
            throw C.Failure.invalidContract("duplicate frozen formal name")
        }
        var parameters: [String] = []
        for (ordinal, formal) in manifest.formals.enumerated() {
            guard validName(formal.name) else { throw C.Failure.invalidContract("invalid frozen formal name") }
            if ordinal != 0 { parameters.append(",") }
            parameters += [try spelling(formal.type), formal.name]
        }
        let actual = Array(tokens.dropFirst(3).dropLast(2))
        switch manifest.entryEnvelope {
        case .declaredFormals:
            guard actual == parameters || (manifest.formals.isEmpty && actual == ["void"]) else {
                throw C.Failure.invalidContract("frozen input declarations differ from exact signature")
            }
        case let .frozenABIInputs(comment):
            guard !manifest.formals.isEmpty, actual.isEmpty,
                  comment.hasPrefix("/* ABI inputs: "), comment.hasSuffix(" */"),
                  try C.lex(comment).isEmpty,
                  manifest.signature == "\(tokens[0]) \(tokens[1])(\(comment)) {" else {
                throw C.Failure.invalidContract("changed frozen ABI-only input envelope")
            }
        }
        if case let .value(_, type) = manifest.terminal {
            guard tokens[0] == (try spelling(type)) else {
                throw C.Failure.invalidContract("numeric terminal representation differs from signature")
            }
        }
        // A baseline's bare return is preserved even if its recovered header
        // says int64_t. It is a void observation, not fabricated return bits.
    }

    static func contract(_ manifest: FrozenManifest) throws -> C.Contract {
        try validateSignature(manifest)
        let addresses = manifest.sourceAddresses
        guard !addresses.isEmpty, Set(addresses).count == addresses.count,
              addresses.allSatisfy({ $0 & 3 == 0 }),
              zip(addresses, addresses.dropFirst()).allSatisfy({ pair in
                  let next = pair.0.addingReportingOverflow(4)
                  return !next.overflow && next.partialValue == pair.1
              }), addresses.indices.contains(manifest.terminalRow),
              manifest.labelAddresses.isSubset(of: Set(addresses)) else {
            throw C.Failure.invalidContract("incomplete original no-call row identity")
        }
        for (row, effects) in manifest.memoryEffects {
            guard addresses.indices.contains(row), row != manifest.terminalRow,
                  !effects.isEmpty, effects.allSatisfy({ [1, 2, 4, 8].contains($0.bytes) }) else {
                throw C.Failure.invalidContract("invalid frozen no-call memory effect")
            }
        }
        let terminalName: String?, returnType: C.CType?, expectedTerminal: [String], unavailable: Bool
        switch manifest.terminal {
        case .void:
            terminalName = nil; returnType = nil; expectedTerminal = ["return", ";"]
            unavailable = false
        case let .value(name, type):
            guard validName(name), name != "unresolved_return_contract" else {
                throw C.Failure.invalidContract("unavailable return cannot become a numeric terminal")
            }
            terminalName = name; returnType = type; expectedTerminal = ["return", name, ";"]
            unavailable = false
        case .unavailableReturnContract:
            terminalName = nil; returnType = nil; expectedTerminal = ["return", "unresolved_return_contract", ";"]
            unavailable = true
        }
        guard try C.lex(manifest.terminalPayload).map(\.text) == expectedTerminal else {
            throw C.Failure.invalidContract("terminal payload is not the frozen supported observation")
        }
        return .init(signature: manifest.signature,
            inputs: manifest.formals.enumerated().map { ordinal, formal in
                // This is only the formal ordinal required by the legacy Input
                // record, never an architectural-register binding. This adapter
                // has no register-dictionary-to-scenario conversion.
                .init(name: formal.name, type: formal.type, entrySlot: ordinal)
            }, fields: [], calls: [:], exterior: [:],
            terminalRow: manifest.terminalRow, terminalPayload: manifest.terminalPayload,
            terminalName: terminalName, returnType: returnType,
            rowsByAddress: Dictionary(uniqueKeysWithValues: addresses.enumerated().map { ($0.element, $0.offset) }),
            allowedLabels: Set(manifest.labelAddresses.map { "L_" + String($0, radix: 16) }),
            memoryEffects: manifest.memoryEffects, helpers: [:], deadResults: [], permissions: [],
            noCallUnavailableTerminal: unavailable)
    }

    static func program(lines: [C.TextLine], manifest: FrozenManifest) throws -> C.Program {
        // Empty exterior/call/helper maps are intentional: no reconstructed
        // tuple, protected-call escape hatch, or executable helper is admitted.
        let frozen = try contract(manifest)
        let parsed = try C.Program(lines: lines, contract: frozen)
        guard frozen.noCallUnavailableTerminal || !parsed.tokens.contains(where: { $0.text == "unresolved_return_contract" }) else {
            throw C.Failure.invalidContract("unavailable marker used outside its nonnumeric terminal contract")
        }
        return parsed
    }
    static func scenario(name: String, inputs: [String: C.Value], memory: [UInt64: UInt8],
                         manifest: FrozenManifest) throws -> C.Scenario {
        _ = try contract(manifest)
        guard Set(inputs.keys) == Set(manifest.formals.map(\.name)) else {
            throw C.Failure.invalidContract("only exact frozen formal inputs may be initialized")
        }
        for formal in manifest.formals {
            guard let value = inputs[formal.name], value.type == formal.type, value.origins.isEmpty else {
                throw C.Failure.invalidContract("no-call input representation/provenance mismatch")
            }
        }
        return .init(name: name, inputs: inputs, memory: memory, responses: [])
    }

    /// Terminal comparison is outside expression evaluation. This checks only
    /// the observation kind/representation, never manufactures return bits.
    static func requireTerminal(_ result: C.Result, manifest: FrozenManifest) throws {
        guard result.returned, !result.reachedRegionBoundary, result.consumedResponses == 0 else {
            throw C.Failure.semanticMismatch("no-call observation did not reach its protected terminal")
        }
        switch manifest.terminal {
        case .void:
            guard result.terminal == nil, result.unavailableTerminal == nil else {
                throw C.Failure.semanticMismatch("bare return acquired a value or unavailable marker")
            }
        case let .value(_, type):
            guard let value = result.terminal, value.type == type, result.unavailableTerminal == nil else {
                throw C.Failure.semanticMismatch("numeric return lost its frozen representation")
            }
        case .unavailableReturnContract:
            guard result.terminal == nil, result.unavailableTerminal == .unresolvedReturnContract else {
                throw C.Failure.semanticMismatch("unavailable return became numeric/void")
            }
        }
    }
}
