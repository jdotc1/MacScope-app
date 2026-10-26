import Foundation

/// A source/typed-value certificate for an entry self-loop and its sole RET.
/// This is an emission-local reconstruction, not a change to the linear lifter.
/// Every read is checked by architectural operand role before any row writes.
struct EntryLoopCarryPlan {
    struct Carrier {
        let register: Int
        let width: Int
        let storage: MacIRValue
        let entry: MacIRValue
        let backedge: MacIRValue
    }

    let carriers: [Carrier]
    let body: [MacIRInstruction]
    let branch: MacIRInstruction
    let terminal: MacIRInstruction
    let condition: String
    let conditionValue: MacIRValue
    let namedValues: Set<MacIRValue>
    let provedPositions: Set<RegionalProvedPosition>

    static func prove(function: MacIRFunction, cfg: CFG,
                      lexicalProof: RegionalLexicalProof? = nil,
                      attemptLexical: Bool = true) -> Self? {
        if attemptLexical, lexicalProof == nil,
           let proof = RegionalLexicalProof(reconciled: function),
           let result = prove(function: proof.function, cfg: cfg, lexicalProof: proof,
                              attemptLexical: false) {
            return result
        }
        // A declined lexical candidate does not disable the prior row proof.

        guard lexicalProof == nil || lexicalProof?.function == function else { return nil }
        let rows = function.instructions
        // Virtual entry is admitted only by the immutable whole-emission seal.
        // Its memory epoch is bookkeeping, never a concrete recurrence carrier.
        let sealedEntry = !function.phis.isEmpty && function.ssaEnabled
            && MacIRBuilder.hasBoundedEntryLoopProof(function)
        guard function.phis.isEmpty || sealedEntry else { return nil }
        var entryPhis: [Int: MacIRPhi] = [:]
        for phi in function.phis {
            guard phi.blockAddress == function.startAddress,
                  phi.incoming.count == 2,
                  phi.incoming[0].predecessor == .functionEntry,
                  phi.incoming[1].machineAddress == rows.dropLast().last?.source.address,
                  let cell = phi.cell else { return nil }
            if cell == 97 { continue } // Exact epoch identities are covered by the seal.
            guard (0..<29).contains(cell), [32, 64].contains(phi.bitWidth),
                  phi.scalarView == .integer,
                  case let .register(name, _) = phi.destination,
                  let view = GPR(name), view.index == cell, view.width == phi.bitWidth,
                  entryPhis.updateValue(phi, forKey: cell) == nil else { return nil }
        }
        guard !function.isVariadic, !function.isNoReturn,
              function.stackFrameSize == 0, function.localVariables.isEmpty,
              Set(function.parameters.map(\.name)).count == function.parameters.count,
              Set(function.parameters.compactMap(\.bindingID)).count == function.parameters.count,
              function.parameters.allSatisfy({ parameter in
                  guard case .gpr = parameter.abiLocation else { return false }
                  return parameter.richLocation == nil
              }),
              rows.count >= 3, rows.first?.source.address == function.startAddress,
              cfg.blocks.count == 2, cfg.entryIndex == 0,
              !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              cfg.backEdges == Set([CFGEdge(0, 0)]),
              cfg.blocks[0].startIndex == 0, cfg.blocks[0].endIndex == rows.count - 1,
              Set(cfg.blocks[0].successors) == [0, 1], cfg.blocks[0].successors.count == 2,
              cfg.blocks[0].predecessors == [0],
              cfg.blocks[1].startIndex == rows.count - 1, cfg.blocks[1].endIndex == rows.count,
              cfg.blocks[1].predecessors == [0], cfg.blocks[1].successors.isEmpty else { return nil }
        for (index, row) in rows.enumerated() {
            // Reject multi-effect and other semantic sidecars: rewriting an
            // operation must not leave a hidden FP/vector operand unrepaired.
            guard row == MacIRInstruction(source: row.source, operation: row.operation,
                                          memoryAccess: row.memoryAccess, returnTarget: row.returnTarget),
                  index == 0 || rows[index - 1].source.address.isContiguous(to: row.source.address),
                  sealedEntry || canonicalOperandEvidence(row.source) else { return nil }
        }
        let branch = rows[rows.count - 2], terminal = rows[rows.count - 1]
        let subtraction = rows[rows.count - 3]
        guard ["b.ne", "b.eq"].contains(branch.source.mnemonic),
              branch.memoryAccess == nil, branch.returnTarget == nil,
              case let .conditionalBranch(condition, left, right, target) = branch.operation,
              condition == (branch.source.mnemonic == "b.ne" ? "!=" : "=="),
              target == .immediate(Int64(bitPattern: function.startAddress)),
              MacIRBuilder.splitOperands(branch.source.operands).count == 1,
              sealedEntry || MacIRBuilder.parseImmediate(branch.source.operands) == Int64(bitPattern: function.startAddress),
              subtraction.source.mnemonic == "subs",
              case let .binary(result, "-", subLeft, subRight) = subtraction.operation,
              left == subLeft, right == subRight,
              terminal.source.mnemonic == "ret", terminal.source.operands.isEmpty,
              terminal.returnTarget == nil, terminal.memoryAccess == nil,
              case let .returnValue(returned) = terminal.operation else { return nil }
        let originalBody = Array(rows.dropLast(2))
        guard originalBody.dropLast().allSatisfy({ $0.source.mnemonic != "subs" }) else { return nil }
        var first = Ledger(function: function, entryPhis: entryPhis)
        guard (try? first.scan(originalBody)) != nil,
              first.validReturn(returned),
              let counter = MacIRBuilder.splitOperands(subtraction.source.operands).first.flatMap(GPR.init) else { return nil }
        let carried = first.entries.keys.filter { first.written.contains($0) }.sorted()
        guard !sealedEntry || Set(carried) == Set(entryPhis.keys) else { return nil }
        var overrides: [Int: MacIRValue] = [:]
        var carriers: [Carrier] = []
        for register in carried {
            guard let width = first.widths[register], let entry = first.entries[register],
                  let final = first.original[register], first.definitions.contains(final) else { return nil }
            let initial: MacIRValue
            if let phi = entryPhis[register] {
                guard phi.bitWidth == width, phi.destination == entry,
                      phi.incoming[1].value == final else { return nil }
                initial = phi.incoming[0].value
            } else {
                initial = entry
            }
            let storage = MacIRValue.register(name: "rgn_loop_r\(register)", version: 0)
            guard !first.atoms.contains(storage) else { return nil }
            overrides[register] = storage
            carriers.append(Carrier(register: register, width: width, storage: storage,
                                    entry: project(initial, width), backedge: project(final, width)))
        }
        var second = Ledger(function: function, entryPhis: entryPhis, overrides: overrides)
        guard let rewritten = try? second.scan(originalBody),
              first.original == second.original, first.entries == second.entries,
              first.written == second.written,
              first.provedPositions == second.provedPositions else { return nil }
        var provedPositions = first.provedPositions
        // The exact branch operands above are the adjacent SUBS operands,
        // already checked in the read phase before the counter is written.
        for position in first.provedPositions where position.address == subtraction.source.address {
            provedPositions.insert(RegionalProvedPosition(address: branch.source.address,
                register: position.register, width: position.width))
        }
        guard lexicalProof?.isCovered(by: provedPositions) != false else { return nil }
        // All copies consume materialized original SSA definitions. No RHS can
        // observe a previous copy to a mutable header carrier.
        var names = first.atoms.union(second.atoms)
        carriers.forEach { names.insert($0.storage) }
        if let returned { collectAtoms(returned, into: &names) }
        return Self(carriers: carriers, body: rewritten, branch: branch, terminal: terminal,
                    condition: condition, conditionValue: project(result, counter.width),
                    namedValues: names, provedPositions: provedPositions)
    }

    static func project(_ value: MacIRValue, _ width: Int) -> MacIRValue {
        let op = "(uint\(width)_t)"
        if case let .unary(existing, _) = value, existing == op { return value }
        return .unary(op: op, value: value)
    }

    private static func canonicalOperandEvidence(_ source: MacIRSourceSpan) -> Bool {
        guard let sidecar = source.structuredOperands else { return true }
        // An unavailable envelope is not contradictory evidence, but it must
        // be exactly what the encoded instruction and shipped decoder produce.
        // Complete envelopes need this check too: presentation can hide extra
        // operands, a different opcode, or conflicting memory semantics.
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return false }
        var bytes: [UInt8] = []
        for token in tokens {
            guard token.utf8.count == 2,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let byte = UInt8(token, radix: 16) else { return false }
            bytes.append(byte)
        }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: source.address, maxInstructionCount: 1)
        guard decoded.count == 1, let instruction = decoded.first,
              instruction.mnemonic == source.mnemonic, instruction.operands == source.operands,
              instruction.structuredOperands == sidecar else { return false }
        switch sidecar.coverage {
        case .complete:
            return sidecar.rendersExactly(mnemonic: source.mnemonic, operands: source.operands)
        case .unavailable:
            return sidecar == .unavailable(mnemonic: source.mnemonic, operands: source.operands)
        case .partial:
            return false
        }
    }

    private static func collectAtoms(_ value: MacIRValue, into result: inout Set<MacIRValue>) {
        switch value {
        case .register, .argument, .temporary: result.insert(value)
        case let .signedBitfield(node): collectAtoms(node.source, into: &result)
        case let .unary(_, inner), let .bitTest(inner, _): collectAtoms(inner, into: &result)
        case let .binaryExpression(_, left, right):
            collectAtoms(left, into: &result); collectAtoms(right, into: &result)
        default: break
        }
    }

    private struct GPR {
        let index: Int
        let width: Int
        let name: String
        init?(_ token: String) {
            let name = token.lowercased()
            guard let view = MacIRBuilder.integerRegisterView(name), view.index < 30,
                  name == "\(view.width == 32 ? "w" : "x")\(view.index)" else { return nil }
            self.index = view.index; self.width = view.width; self.name = name
        }
    }

    private enum Refusal: Error { case unproved }

    private struct Ledger {
        let function: MacIRFunction
        var entryPhis: [Int: MacIRPhi] = [:]
        var overrides: [Int: MacIRValue] = [:]
        var original: [Int: MacIRValue] = [:]
        var mapped: [Int: MacIRValue] = [:]
        var entries: [Int: MacIRValue] = [:]
        var widths: [Int: Int] = [:]
        var written: Set<Int> = []
        var definitions: Set<MacIRValue> = []
        var atoms: Set<MacIRValue> = []
        var provedPositions: Set<RegionalProvedPosition> = []
        var sourceAddress: UInt64 = 0

        mutating func scan(_ rows: [MacIRInstruction]) throws -> [MacIRInstruction] {
            try rows.map { try transfer($0) }
        }

        private mutating func view(_ register: GPR) throws {
            if let width = widths[register.index], width != register.width { throw Refusal.unproved }
            widths[register.index] = register.width
        }

        private func entryEvidence(_ value: MacIRValue, register: GPR) -> Bool {
            if let phi = entryPhis[register.index] {
                return phi.bitWidth == register.width && value == phi.destination
            }
            if register.index >= 8 {
                return value == .register(name: register.name, version: 0)
            }
            let binding = MacIRParameterBindingID.gpr(register.index)
            let parameters = function.parameters.filter { $0.bindingID == binding }
            if parameters.isEmpty { return value == .register(name: register.name, version: 0) }
            guard parameters.count == 1, let parameter = parameters.first,
                  parameter.richLocation == nil,
                  case let .gpr(index, width) = parameter.abiLocation, index == register.index,
                  [32, 64].contains(width),
                  parameter.type.contains("*") || ["int8_t", "uint8_t", "int16_t", "uint16_t",
                      "int32_t", "uint32_t", "int64_t", "uint64_t", "int", "unsigned int",
                      "long", "unsigned long", "size_t", "intptr_t", "uintptr_t"].contains(parameter.type) else { return false }
            let argument = MacIRValue.argument(bindingID: binding)
            let expected: MacIRValue
            if width == register.width { expected = argument }
            else if width == 32 { expected = Self.widen32(argument) }
            else { expected = EntryLoopCarryPlan.project(argument, 32) }
            return value == expected
        }

        private static func widen32(_ value: MacIRValue) -> MacIRValue {
            .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: value))
        }

        private mutating func read(_ token: String, _ actual: MacIRValue,
                                   width: Int? = nil) throws -> MacIRValue {
            if let immediate = MacIRBuilder.parseImmediate(token) {
                guard actual == .immediate(immediate) else { throw Refusal.unproved }
                return actual
            }
            if token == "wzr" || token == "xzr" {
                guard actual == .immediate(0), width == nil || width == (token == "wzr" ? 32 : 64) else { throw Refusal.unproved }
                return actual
            }
            guard let register = GPR(token), width == nil || width == register.width else { throw Refusal.unproved }
            try view(register)
            if let expected = original[register.index] {
                guard actual == expected else { throw Refusal.unproved }
            } else {
                guard entryEvidence(actual, register: register) else { throw Refusal.unproved }
                entries[register.index] = actual
                original[register.index] = actual
                mapped[register.index] = overrides[register.index] ?? actual
            }
            EntryLoopCarryPlan.collectAtoms(actual, into: &atoms)
            guard let replacement = mapped[register.index] else { throw Refusal.unproved }
            provedPositions.insert(RegionalProvedPosition(address: sourceAddress,
                register: register.index, width: register.width))
            EntryLoopCarryPlan.collectAtoms(replacement, into: &atoms)
            return EntryLoopCarryPlan.project(replacement, register.width)
        }

        private mutating func write(_ token: String, _ actual: MacIRValue) throws {
            guard let register = GPR(token), case let .register(name, version) = actual,
                  name == register.name, version > 0, !definitions.contains(actual) else { throw Refusal.unproved }
            try view(register)
            definitions.insert(actual); atoms.insert(actual); written.insert(register.index)
            original[register.index] = actual; mapped[register.index] = actual
        }

        private mutating func memory(_ operand: String, _ actual: MacIRValue) throws -> MacIRValue {
            guard operand.hasPrefix("["), operand.hasSuffix("]") else { throw Refusal.unproved }
            let parts = MacIRBuilder.splitOperands(String(operand.dropFirst().dropLast()))
            guard parts.count == 1 || parts.count == 2, let base = parts.first.flatMap(GPR.init),
                  base.width == 64 else { throw Refusal.unproved }
            let displacement: Int64
            if parts.count == 2 {
                guard let value = MacIRBuilder.parseImmediate(parts[1]) else { throw Refusal.unproved }
                displacement = value
            } else { displacement = 0 }
            let oldBase: MacIRValue
            if displacement == 0 { oldBase = actual }
            else {
                guard case let .binaryExpression("+", left, right) = actual,
                      right == .immediate(displacement) else { throw Refusal.unproved }
                oldBase = left
            }
            let newBase = try read(base.name, oldBase, width: 64)
            return displacement == 0 ? newBase : .binaryExpression(op: "+", left: newBase,
                right: EntryLoopCarryPlan.project(.immediate(displacement), 64))
        }

        private mutating func transfer(_ row: MacIRInstruction) throws -> MacIRInstruction {
            sourceAddress = row.source.address
            let mnemonic = row.source.mnemonic
            let operands = MacIRBuilder.splitOperands(row.source.operands)
            guard row.returnTarget == nil else { throw Refusal.unproved }
            var changed = row
            let operators = ["add": "+", "sub": "-", "subs": "-", "and": "&", "orr": "|", "eor": "^", "mul": "*"]
            if let op = operators[mnemonic] {
                guard row.memoryAccess == nil, operands.count == 3, let destination = GPR(operands[0]),
                      case let .binary(value, actualOp, left, right) = row.operation, actualOp == op else { throw Refusal.unproved }
                let lhs = try read(operands[1], left, width: destination.width)
                let rhs = try read(operands[2], right, width: destination.width)
                try write(operands[0], value)
                changed.operation = .assign(destination: value, source: EntryLoopCarryPlan.project(
                    .binaryExpression(op: op, left: EntryLoopCarryPlan.project(lhs, destination.width),
                                      right: EntryLoopCarryPlan.project(rhs, destination.width)), destination.width))
            } else if mnemonic == "mov" {
                guard row.memoryAccess == nil, operands.count == 2, let destination = GPR(operands[0]),
                      case let .assign(value, source) = row.operation else { throw Refusal.unproved }
                let input = try read(operands[1], source, width: destination.width)
                try write(operands[0], value)
                changed.operation = .assign(destination: value, source: EntryLoopCarryPlan.project(input, destination.width))
            } else if mnemonic == "lsl" || mnemonic == "lsr" {
                guard row.memoryAccess == nil, operands.count == 3, let destination = GPR(operands[0]),
                      case let .binary(value, op, left, right) = row.operation,
                      op == (mnemonic == "lsl" ? "<<" : ">>"),
                      case let .unary(cast, source) = left, cast == "(uint\(destination.width)_t)" else { throw Refusal.unproved }
                let input = try read(operands[1], source, width: destination.width)
                let amount: MacIRValue
                if let immediate = MacIRBuilder.parseImmediate(operands[2]) {
                    guard (0..<Int64(destination.width)).contains(immediate), right == .immediate(immediate) else { throw Refusal.unproved }
                    amount = right
                } else {
                    guard case let .binaryExpression("&", rawAmount, mask) = right,
                          mask == .immediate(Int64(destination.width - 1)) else { throw Refusal.unproved }
                    let mappedAmount = try read(operands[2], rawAmount, width: destination.width)
                    amount = .binaryExpression(op: "&", left: mappedAmount, right: mask)
                }
                try write(operands[0], value)
                changed.operation = .assign(destination: value, source: EntryLoopCarryPlan.project(
                    .binaryExpression(op: op, left: EntryLoopCarryPlan.project(input, destination.width), right: amount), destination.width))
            } else if ["ldr", "ldrb", "ldrh", "str", "strb", "strh"].contains(mnemonic) {
                guard let data = operands.first.flatMap(GPR.init),
                      row.memoryAccess != nil, row.memoryAccess == MacIRBuilder.memoryAccess(for: row.source),
                      ["ldr", "str"].contains(mnemonic) || data.width == 32 else { throw Refusal.unproved }
                if let writeback = MacIRBuilder.scalarWritebackAddress(operands: operands) {
                    guard let base = GPR(writeback.base), base.width == 64, base.index != data.index else { throw Refusal.unproved }
                    if mnemonic.hasPrefix("ld") {
                        guard case let .loadWriteback(value, baseValue, oldBase, delta, preIndex) = row.operation,
                              delta == writeback.delta, preIndex == writeback.preIndex else { throw Refusal.unproved }
                        let newBase = try read(base.name, oldBase, width: 64)
                        try write(data.name, value); try write(base.name, baseValue)
                        changed.operation = .loadWriteback(destination: value, baseDestination: baseValue,
                            baseSource: newBase, delta: delta, preIndex: preIndex)
                    } else {
                        guard case let .storeWriteback(source, baseValue, oldBase, delta, preIndex) = row.operation,
                              delta == writeback.delta, preIndex == writeback.preIndex else { throw Refusal.unproved }
                        let newSource = try read(data.name, source, width: data.width)
                        let newBase = try read(base.name, oldBase, width: 64)
                        try write(base.name, baseValue)
                        changed.operation = .storeWriteback(source: newSource, baseDestination: baseValue,
                            baseSource: newBase, delta: delta, preIndex: preIndex)
                    }
                } else {
                    guard operands.count == 2 else { throw Refusal.unproved }
                    if mnemonic.hasPrefix("ld") {
                        guard case let .load(value, address) = row.operation else { throw Refusal.unproved }
                        let newAddress = try memory(operands[1], address)
                        try write(data.name, value)
                        changed.operation = .load(destination: value, address: newAddress)
                    } else {
                        guard case let .store(source, address) = row.operation else { throw Refusal.unproved }
                        let newSource = try read(data.name, source, width: data.width)
                        let newAddress = try memory(operands[1], address)
                        changed.operation = .store(source: newSource, address: newAddress)
                    }
                }
            } else { throw Refusal.unproved }
            return changed
        }

        func validReturn(_ value: MacIRValue?) -> Bool {
            guard let value else { return true }
            if value == .unknown("unresolved_return_contract") { return true }
            if let final = original[0], let width = widths[0] {
                return value == final || (width == 32 && value == Self.widen32(final))
                    || (width == 64 && value == EntryLoopCarryPlan.project(final, 32))
            }
            // An unchanged incoming x0 may be an evidenced return contract, but
            // an incoming x1 or a retired body definition cannot claim it.
            return GPR("x0").map { entryEvidence(value, register: $0) } ?? false
        }
    }
}
