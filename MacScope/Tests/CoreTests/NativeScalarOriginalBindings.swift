import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Approved typed-original bridge. Literal source demand fixes the external ABI
/// roles; unchanged Builder metadata fixes original identity/name/type. Neither
/// candidate spelling nor reflected text determines a register, input or value.
/// SOURCE ONLY / NOT RUN. Candidate execution receives only `manifest` and the
/// fixed name/type/value projection, never this original binding table or IR.
enum NativeScalarOriginalBindings {
    typealias C = OrdinaryC
    typealias N = NativeScalarNoCallContract
    struct Input {
        let parameter: MacIRFunctionParameter
        let atom: MacIRValue
        let register: Int
        let initializedWidth: Int
        let type: C.CType
    }
    struct Bound {
        let inputs: [Input]
        let terminalAtom: MacIRValue?
        let manifest: N.FrozenManifest
        let inventory: NativeScalarSourceOwnership.Inventory

        /// The caller supplies scenario values for original physical entry roles.
        /// No source/reference result, SSA alias or missing variable is seeded.
        func candidateInputs(originalGPRValues: [Int: UInt64]) throws -> [String: C.Value] {
            guard Set(originalGPRValues.keys) == Set(inputs.map(\.register)) else {
                throw C.Failure.invalidContract("scenario must initialize exactly the original external GPR roles")
            }
            return Dictionary(uniqueKeysWithValues: inputs.map { input in
                (input.parameter.name, C.Value(originalGPRValues[input.register]!, input.type))
            })
        }
    }
    struct Register: Hashable { let index: Int; let width: Int }
    struct Access { let reads: [Register]; let writes: [Register] }

    static func make(_ fixture: NativeScalarFixture) throws -> Bound {
        let inventory = try NativeScalarSourceOwnership.make(fixture.capture)
        let accesses = try fixture.rows.map(literalAccess)
        let demand = entryDemand(source: inventory.source, accesses: accesses, reachable: inventory.reachableBlocks)
        var inputs: [Input] = []
        for parameter in fixture.originalParameters {
            guard let binding = parameter.bindingID, binding.kind == .gpr,
                  case let .gpr(register, width) = parameter.abiLocation,
                  register == binding.value, parameter.richLocation == nil,
                  [32, 64].contains(width), demand[register] == width,
                  let type = C.CType.named(parameter.type), type.width == width,
                  !parameter.id.rawValue.isEmpty, C.identifier(parameter.name) else {
                throw C.Failure.invalidContract("original typed parameter contradicts literal entry demand")
            }
            let atom = MacIRValue.argument(bindingID: binding)
            guard fixture.originalName(atom) == parameter.name else {
                throw C.Failure.invalidContract("original parameter display binding is missing or ambiguous")
            }
            inputs.append(.init(parameter: parameter, atom: atom, register: register, initializedWidth: width, type: type))
        }
        guard Set(inputs.map(\.register)).count == inputs.count,
              Set(inputs.compactMap { $0.parameter.bindingID }).count == inputs.count,
              Set(inputs.map(\.register)) == Set(demand.keys),
              Set(inputs.map { $0.parameter.id }).count == inputs.count,
              Set(inputs.map { $0.parameter.name }).count == inputs.count else {
            throw C.Failure.invalidContract("missing/duplicate original external input identity")
        }
        let envelope: N.EntryEnvelope
        if fixture.capture.signature.contains("/* ABI inputs: ") {
            guard fixture.originalParameters.contains(where: { $0.sourcePosition == nil }),
                  let open = fixture.capture.signature.range(of: "/* ABI inputs: "),
                  let close = fixture.capture.signature.range(of: " */", range: open.lowerBound..<fixture.capture.signature.endIndex) else {
                throw C.Failure.invalidContract("ABI-only header lacks original incomplete source-order evidence")
            }
            envelope = .frozenABIInputs(comment: String(fixture.capture.signature[open.lowerBound..<close.upperBound]))
        } else {
            guard fixture.originalParameters.enumerated().allSatisfy({ $0.element.sourcePosition == $0.offset }) else {
                throw C.Failure.invalidContract("formal header and original source positions disagree")
            }
            envelope = .declaredFormals
        }
        guard inventory.source.returns == [fixture.rows.count - 1],
              case let .returnValue(atom) = fixture.originalTerminal else {
            throw C.Failure.invalidContract("original terminal is not the complete captured RET")
        }
        let terminal: N.Terminal
        if atom == nil { terminal = .void }
        else if atom == .unknown("unresolved_return_contract") { terminal = .unavailableReturnContract }
        else { throw C.Failure.invalidContract("first nativeScalar slice does not invent a numeric return adapter") }
        let terminalPayload: String
        // The frozen capture predates the policy that missing return evidence never establishes void, so pair the unresolved kind with its fixed marker payload.
        if case .unavailableReturnContract = terminal { terminalPayload = "return unresolved_return_contract; // return" }
        else { terminalPayload = fixture.capture.terminalPayload }
        let manifest = N.FrozenManifest(signature: fixture.capture.signature,
            formals: inputs.map { .init(name: $0.parameter.name, type: $0.type) },
            sourceAddresses: fixture.rows.map(\.address), terminalRow: fixture.rows.count - 1,
            terminalPayload: terminalPayload, terminal: terminal,
            labelAddresses: Set(inventory.source.blocks.map { fixture.rows[$0.rows.lowerBound].address }),
            memoryEffects: inventory.memoryEffects, entryEnvelope: envelope)
        _ = try N.contract(manifest) // Validates exact frozen envelope; never candidate state.
        return .init(inputs: inputs, terminalAtom: atom, manifest: manifest, inventory: inventory)
    }

    /// This parser reads only immutable assembly text, never emitted C. The
    /// complete native operand envelope is retained separately; no missing
    /// structured operand is manufactured or added to a producer input.
    static func literalAccess(_ row: InstructionRow) throws -> Access {
        let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])([wx])([0-9]+|zr)(?![A-Za-z0-9_])"#)
        var registers: [Register] = []
        for match in pattern.matches(in: row.operands, range: NSRange(row.operands.startIndex..., in: row.operands)) {
            let width = String(row.operands[Range(match.range(at: 1), in: row.operands)!]) == "w" ? 32 : 64
            let literal = String(row.operands[Range(match.range(at: 2), in: row.operands)!])
            // This bounded original slice has no explicit zero-register data
            // operands. Refuse rather than drop its positional destination.
            guard literal != "zr" else { throw C.Failure.invalidContract("zero-register operand needs a separate positional source adapter") }
            guard let index = Int(literal), (0...30).contains(index) else { throw C.Failure.invalidContract("unsupported original register literal") }
            registers.append(.init(index: index, width: width))
        }
        let mnemonic = row.mnemonic
        if mnemonic == "ret" || mnemonic == "nop" || mnemonic == "b" || mnemonic.hasPrefix("b.") {
            return .init(reads: [], writes: [])
        }
        if ["cmp", "cbz", "cbnz"].contains(mnemonic) { return .init(reads: registers, writes: []) }
        if ["mov", "add", "sub", "subs", "sxtw", "lsl", "lsr"].contains(mnemonic) {
            guard let destination = registers.first else { throw C.Failure.invalidContract("missing scalar original destination") }
            return .init(reads: Array(registers.dropFirst()), writes: [destination])
        }
        let loading = ["ldr", "ldrb", "ldrh", "ldur", "ldurb", "ldurh", "ldp"].contains(mnemonic)
        let storing = ["str", "strb", "strh", "stur", "sturb", "sturh", "stp"].contains(mnemonic)
        guard loading || storing, let envelope = row.structuredOperands, envelope.coverage == .complete else {
            throw C.Failure.invalidContract("unsupported original access instruction")
        }
        let memories = envelope.operands.compactMap { operand -> InstructionOperands.Memory? in
            if case let .memory(memory) = operand { return memory }; return nil
        }
        guard memories.count == 1, let memory = memories.first, memory.base.bank == .general,
              memory.base.role == .ordinary, memory.base.width == 64 else {
            throw C.Failure.invalidContract("unsupported original memory address register")
        }
        let count = mnemonic == "ldp" || mnemonic == "stp" ? 2 : 1
        guard registers.count >= count + 1 else { throw C.Failure.invalidContract("incomplete literal memory operand registers") }
        let destinations = loading ? Array(registers.prefix(count)) : []
        var reads = loading ? Array(registers.dropFirst(count)) : registers
        // Retain reads-before-writeback; remove no source alias on a pair row.
        let base = Register(index: memory.base.index, width: 64)
        if !reads.contains(base) { throw C.Failure.invalidContract("literal/native memory base contradiction") }
        if let index = memory.index {
            guard reads.contains(.init(index: index.index, width: index.width)) else {
                throw C.Failure.invalidContract("literal/native memory index contradiction")
            }
        }
        // Explicit mutable local avoids accidental future edits appending a
        // writeback definition to the read list.
        reads = Array(reads)
        return .init(reads: reads, writes: destinations + (memory.writeback ? [base] : []))
    }

    private static func entryDemand(source: OrdinaryCSourceEdgeLedger.Source, accesses: [Access],
                                    reachable: Set<Int>) -> [Int: Int] {
        var incoming: [Int: [Int: Int]] = [:], changed = true
        while changed {
            changed = false
            for block in source.blocks.reversed() where reachable.contains(block.index) {
                var demand: [Int: Int] = [:]
                for successor in block.successors {
                    for (register, width) in incoming[successor, default: [:]] { demand[register] = max(demand[register, default: 0], width) }
                }
                for row in block.rows.reversed() {
                    // Any W write establishes all X bits (zero high half), so
                    // it kills a demand just as an X write does.
                    for definition in accesses[row].writes { demand.removeValue(forKey: definition.index) }
                    for read in accesses[row].reads { demand[read.index] = max(demand[read.index, default: 0], read.width) }
                }
                if incoming[block.index] != demand { incoming[block.index] = demand; changed = true }
            }
        }
        return incoming[0, default: [:]]
    }
}
