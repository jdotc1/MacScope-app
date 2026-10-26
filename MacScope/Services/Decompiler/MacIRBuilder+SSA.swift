import Foundation

/// Completed definition identities retained for semantic consumers and audits.
struct MacIRSSAInfo: Hashable, Sendable {
    var plan: MacIRSSA.Plan
    var values: [Int: MacIRValue]
    var sourceAddresses: [UInt64]
    var stackOffsets: [Int: Int64] = [:]
    // Presentation-only provenance: only committed snapshot-NZCV phi targets.
    // Default preserves existing memberwise callers and grants no proof authority.
    var generatedNZCVPredicateTargets: Set<MacIRValue> = []
    fileprivate var boundedEntryCertificate: BoundedEntryLoopCertificate? = nil

    init(plan: MacIRSSA.Plan, values: [Int: MacIRValue], sourceAddresses: [UInt64],
         stackOffsets: [Int: Int64] = [:]) {
        self.plan = plan
        self.values = values
        self.sourceAddresses = sourceAddresses
        self.stackOffsets = stackOffsets
    }
}

/// A whole-emission seal, constructible only in this file after the ordinary
/// builder has emitted a byte/text-proved bounded loop. Public source spans or
/// mutable original-IR snapshots alone are not arithmetic authority.
fileprivate struct BoundedEntryLoopCertificate: Hashable, Sendable {
    let instructions: [MacIRInstruction]
    let phis: [MacIRPhi]
    let parameters: [MacIRFunctionParameter]
    let cfg: MacIRCFG?
    let plan: MacIRSSA.Plan
    let values: [Int: MacIRValue]
    let sourceAddresses: [UInt64]
    let startAddress: UInt64
    let endAddress: UInt64?
    let returnValue: MacIRValue?
    let returnType: String
    let isNoReturn: Bool
    let nameBindings: [MacIRNameBinding]

    init(function: MacIRFunction, info: MacIRSSAInfo) {
        instructions = function.instructions
        phis = function.phis
        parameters = function.parameters
        cfg = function.cfg
        plan = info.plan
        values = info.values
        sourceAddresses = info.sourceAddresses
        startAddress = function.startAddress
        endAddress = function.endAddress
        returnValue = function.returnValue
        returnType = function.returnType
        isNoReturn = function.isNoReturn
        nameBindings = function.nameBindings
    }

    func matches(_ function: MacIRFunction, info: MacIRSSAInfo) -> Bool {
        function.instructions == instructions && function.phis == phis && function.parameters == parameters
            && function.cfg == cfg && info.plan == plan && info.values == values
            && info.sourceAddresses == sourceAddresses && function.startAddress == startAddress
            && function.endAddress == endAddress && function.returnValue == returnValue
            && function.returnType == returnType && function.isNoReturn == isNoReturn
            && function.nameBindings == nameBindings
    }
}

extension MacIRBuilder {
    /// Derived graph-only representation, never a published machine source.
    /// Construction follows every byte/text/sidecar check for the closed class.
    private struct BoundedEntrySourceProof {
        let sources: [MacIRSourceSpan]
        let branchIndex: Int
        let target: UInt64

        var skeleton: [MacIRInstruction] {
            sources.enumerated().map { index, source in
                var scratch = source
                if index == branchIndex {
                    scratch.operands = "0x" + String(target, radix: 16)
                }
                return .init(source: scratch,
                    operation: .intrinsic(destination: nil, name: "nop", arguments: []))
            }
        }
    }

    private static func boundedEntryLoopGraphMatches(_ sources: [MacIRSourceSpan], graph: MacIRCFG) -> Bool {
        guard graph.entry == 0,
              graph.blocks.count == 2, graph.refusals.isEmpty,
              graph.blocks[0].predecessors == [0],
              Set(graph.blocks[0].successors) == Set([
                  MacIREdge(from: 0, to: 0, kind: .branch, label: nil),
                  MacIREdge(from: 0, to: 1, kind: .fallthrough, label: nil)]),
              graph.blocks[1].predecessors == [0],
              graph.blocks[1].successors == [MacIREdge(from: 1, to: nil, kind: .exit, label: nil)],
              graph.blocks[0].instructionRange == 0..<(sources.count - 1),
              graph.blocks[1].instructionRange == (sources.count - 1)..<sources.count,
              sources.first != nil else { return false }
        return true
    }

    /// A deliberately closed class, not a general cyclic-entry physical proof.
    /// No scratch edge is available until every original row has been checked.
    private static func boundedEntrySourceProof(_ sources: [MacIRSourceSpan]) -> BoundedEntrySourceProof? {
        guard (4...16).contains(sources.count), let first = sources.first,
              first.address != 0, first.address <= UInt64(Int64.max) else { return nil }
        func word(_ source: MacIRSourceSpan) -> UInt32? {
            let tokens = source.byteText.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count == 4 else { return nil }
            let bytes = tokens.compactMap { token -> UInt8? in
                guard token.utf8.count == 2, token.utf8.allSatisfy({
                    (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
                }) else { return nil }
                return UInt8(token, radix: 16)
            }
            guard bytes.count == 4 else { return nil }
            return bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        func typedMemoryAgrees(_ source: MacIRSourceSpan, data: Int, base: Int,
                               bytes: Int64, displacement: Int64, post: Bool, load: Bool) -> Bool {
            guard let typed = source.structuredOperands else { return true }
            guard typed.architecture == .arm64, typed.schemaVersion == 1,
                  typed.operands.count == 2, typed.presentation.omittedOperandIndices.isEmpty,
                  typed.presentation.conditionSuffixOperandIndex == nil,
                  case let .register(register) = typed.operands[0],
                  register == .init(index: data, width: 32),
                  case let .memory(memory) = typed.operands[1],
                  memory.base == .init(index: base, width: 64), memory.index == nil, memory.modifier == nil,
                  memory.indexing == (post ? .postIndex : .offset), memory.writeback == post,
                  memory.displacement == displacement else { return false }
            if let semantics = typed.semantics {
                guard semantics.memoryAccessWidth == Int(bytes * 8),
                      semantics.memoryAccess == (load ? .read : .write) else { return false }
            }
            return true
        }
        for (index, source) in sources.enumerated() {
            let (expected, overflow) = first.address.addingReportingOverflow(UInt64(index * 4))
            guard !overflow, source.address == expected, source.syntheticPhiEdge == nil,
                  let bits = word(source) else { return nil }
            // The closing branch's display may be symbolized after decoding.
            // Its complete sidecar is checked separately against the exact word.
            if index != sources.count - 2, let typed = source.structuredOperands {
                let isMemory = ["ldrb", "ldr", "strb", "strh"].contains(source.mnemonic.lowercased())
                let exactUnavailable = !isMemory && typed == InstructionOperands.unavailable(
                    mnemonic: source.mnemonic, operands: source.operands)
                if !exactUnavailable {
                    guard typed.architecture == .arm64, typed.schemaVersion == 1,
                          typed.rendersExactly(mnemonic: source.mnemonic, operands: source.operands) else { return nil }
                    if !isMemory {
                        guard !typed.operands.contains(where: { if case .memory = $0 { return true }; return false }),
                              typed.semantics?.memoryAccess == nil, typed.semantics?.memoryAccessWidth == nil else { return nil }
                    }
                }
            }
            let mnemonic = source.mnemonic.lowercased()
            let operands = splitOperands(source.operands.lowercased()).map { $0.replacingOccurrences(of: " ", with: "") }
            let rd = Int(bits & 31), rn = Int((bits >> 5) & 31), rm = Int((bits >> 16) & 31)
            if index == sources.count - 1 {
                guard bits == 0xd65f03c0, mnemonic == "ret", operands.isEmpty || operands == ["x30"] else { return nil }
                continue
            }
            if index == sources.count - 2 {
                guard bits & 0xff00001f == 0x54000001, mnemonic == "b.ne", operands.count == 1 else { return nil }
                let displacement = Int64(Int32(bitPattern: ((bits >> 5) & 0x7ffff) << 13) >> 13) * 4
                guard displacement == -Int64(index * 4) else { return nil }
                if let target = parseImmediate(operands[0]) {
                    guard target >= 0, UInt64(target) == first.address else { return nil }
                } else {
                    // Symbol text is display-only, never branch-address authority.
                    let symbol = operands[0]
                    guard symbol.hasPrefix("_"), symbol.utf8.allSatisfy({
                        (0x61...0x7a).contains($0) || (0x30...0x39).contains($0)
                            || $0 == 0x5f || $0 == 0x2e || $0 == 0x24
                    }) else { return nil }
                }
                if let typed = source.structuredOperands {
                    let expected = InstructionOperands(coverage: .complete, opcodeClass: "b.cond",
                        operands: [.pcRelative(.init(baseAddress: source.address, displacement: displacement)), .condition(.ne)],
                        presentation: .init(mnemonic: "b", conditionSuffixOperandIndex: 1))
                    guard typed == expected || typed == InstructionOperands.unavailable(
                        mnemonic: source.mnemonic, operands: source.operands) else { return nil }
                }
                continue
            }
            if bits & 0xffe0ffe0 == 0xaa0003e0 {
                guard rd < 29, rm < 29, mnemonic == "mov", operands == ["x\(rd)", "x\(rm)"] else { return nil }
                continue
            }
            guard rd < 29, rn < 29 else { return nil }
            let post = bits & 0xffe00c00
            if [UInt32(0x38400400), 0xb8400400, 0x38000400, 0x78000400].contains(post) {
                let load = post == 0x38400400 || post == 0xb8400400
                let width: Int64 = post == 0xb8400400 ? 4 : post == 0x78000400 ? 2 : 1
                let expectedMnemonic = load ? (width == 1 ? "ldrb" : "ldr") : (width == 1 ? "strb" : "strh")
                let displacement = Int64(Int32(bitPattern: ((bits >> 12) & 0x1ff) << 23) >> 23)
                guard mnemonic == expectedMnemonic, displacement == width, rd != rn,
                      operands.count == 3, operands[0] == "w\(rd)", operands[1] == "[x\(rn)]",
                      parseImmediate(operands[2]) == width else { return nil }
                guard typedMemoryAgrees(source, data: rd, base: rn, bytes: width,
                    displacement: width, post: true, load: load) else { return nil }
            } else if bits & 0xffc00000 == 0xb9400000 {
                let displacement = Int64((bits >> 10) & 0xfff) * 4
                guard mnemonic == "ldr", operands.count == 2, operands[0] == "w\(rd)",
                      operands[1].hasPrefix("[x\(rn),"), operands[1].hasSuffix("]") else { return nil }
                let memoryText = String(operands[1].dropFirst().dropLast()).split(separator: ",").map(String.init)
                guard memoryText.count == 2, memoryText[0] == "x\(rn)", parseImmediate(memoryText[1]) == displacement else { return nil }
                guard typedMemoryAgrees(source, data: rd, base: rn, bytes: 4,
                    displacement: displacement, post: false, load: true) else { return nil }
            } else if bits & 0xffe0fc00 == 0x1ac02000 || bits & 0xffe0fc00 == 0x1ac02400 {
                guard rm < 29, mnemonic == (bits & 0x400 == 0 ? "lsl" : "lsr"),
                      operands == ["w\(rd)", "w\(rn)", "w\(rm)"] else { return nil }
            } else if bits & 0x7fc00000 == 0x71000000 {
                let prefix = bits >> 31 == 0 ? "w" : "x"
                guard rd == rn, (bits >> 10) & 0xfff == 1, mnemonic == "subs",
                      operands.count == 3, operands[0] == "\(prefix)\(rd)", operands[1] == "\(prefix)\(rn)",
                      parseImmediate(operands[2]) == 1, index == sources.count - 3 else { return nil }
            } else if bits & 0xffe0fc00 == 0x8b000000 {
                guard rm < 29, mnemonic == "add", operands == ["x\(rd)", "x\(rn)", "x\(rm)"] else { return nil }
            } else { return nil }
        }
        // The only NZCV writer is the terminal decrement, so the branch cannot
        // consume an implicit, unproved entry flag value.
        guard let decrement = sources.dropLast(2).last, decrement.mnemonic.lowercased() == "subs" else { return nil }
        return BoundedEntrySourceProof(sources: sources, branchIndex: sources.count - 2,
                                       target: first.address)
    }

    static func boundedEntryParameters(_ parameters: [MacIRFunctionParameter]) -> Bool {
        var seen = Set<Int>()
        return parameters.allSatisfy { parameter in
            guard case let .gpr(index, width) = parameter.abiLocation,
                  (0..<8).contains(index), [32, 64].contains(width), parameter.richLocation == nil,
                  parameter.bindingID == .gpr(index), parameter.register == "\(width == 32 ? "w" : "x")\(index)",
                  seen.insert(index).inserted else { return false }
            let type = parameter.type.trimmingCharacters(in: .whitespacesAndNewlines)
            let integer32: Set<String> = ["int", "unsigned int", "int32_t", "uint32_t"]
            let integer64: Set<String> = ["long", "unsigned long", "long long", "unsigned long long", "int64_t", "uint64_t", "intptr_t", "uintptr_t", "size_t", "ssize_t"]
            let pointer = type.hasSuffix("*") && !type.contains("(") && !type.contains("[")
            return width == 32 ? integer32.contains(type) : integer64.contains(type) || pointer
        }
    }

    private static func boundedEntryState(_ state: BuilderState) -> Bool {
        guard boundedEntryParameters(state.parameters), state.ssa == nil,
              state.stackBaseOffsets.isEmpty, state.stackPointerAliasOffsetByGPR.isEmpty,
              state.stackSlotValues.isEmpty, state.currentEntryStackArgumentByScalarFPRegister.isEmpty,
              state.localVariablesByOffset.isEmpty, state.stackDepth == 0, state.stackDisplacement == 0,
              state.maxStackDepth == 0, state.maxStackDisplacement == 0,
              !state.hasUnknownStackPointerAdjustment, !state.hasExplicitStackWriteback,
              state.materializedImmediateByRegister.isEmpty, state.adrpPageBaseByRegister.isEmpty,
              state.currentIntegerDefinitionByIndex.isEmpty, state.registerVersions.isEmpty else { return false }
        var pristine = BuilderState()
        pristine.parameters = state.parameters
        return (0..<29).allSatisfy { index in
            ["w", "x"].allSatisfy { prefix in
                state.readRegister("\(prefix)\(index)") == pristine.readRegister("\(prefix)\(index)")
            }
        }
    }

    /// Revalidate presentation against retained machine sources and SSA identities.
    /// No synthetic row, machine-address sentinel, or regional-proof exemption.
    static func hasBoundedEntryLoopProof(_ function: MacIRFunction) -> Bool {
        guard function.ssaEnabled, !function.isVariadic, boundedEntryParameters(function.parameters),
              function.stackFrameSize == 0, function.maxStackDisplacement == 0,
              function.localVariables.isEmpty, function.callTargets.isEmpty,
              let info = function.ssaInfo, let certificate = info.boundedEntryCertificate,
              certificate.matches(function, info: info), let original = function.ssaOriginalInstructions,
              let originalPhis = function.ssaOriginalPhis,
              function.instructions == original, function.phis == originalPhis,
              Set(info.sourceAddresses).count == info.sourceAddresses.count else { return false }
        let grouped = Dictionary(grouping: original, by: { $0.source.address })
        guard Set(grouped.keys) == Set(info.sourceAddresses),
              original.allSatisfy({ $0.source.syntheticPhiEdge == nil }) else { return false }
        var sources: [MacIRSourceSpan] = []
        for address in info.sourceAddresses {
            guard let rows = grouped[address], let source = rows.first?.source,
                  rows.allSatisfy({ $0.source == source }) else { return false }
            sources.append(source)
        }
        guard let sourceProof = boundedEntrySourceProof(sources) else { return false }
        let skeleton = sourceProof.skeleton
        guard let graph = MacIRCFG.build(instructions: skeleton, jumpTables: [:], knownTailCallTargets: [:], authoredCallSignaturesByTarget: [:]),
              sources.first?.address == function.startAddress, boundedEntryLoopGraphMatches(sources, graph: graph),
              function.cfg == graph.reindexed(instructions: original),
              function.endAddress == nil || function.endAddress == sources.last?.address.addressAfter(),
              info.plan.rowReadBindings.count == sources.count,
              info.plan.rowWriteBindings.count == sources.count else { return false }
        let effects = sources.map { ssaEffects(for: $0) }
        guard effects.allSatisfy({ effect in
            effect.refusals.isEmpty && effect.reads.cells.allSatisfy { (0..<29).contains($0) || $0 == 96 || $0 == 97 || ($0 == 30 && effect.address == sources.last?.address) }
                && effect.writes.allSatisfy { ((0..<29).contains($0.cell) || $0.cell == 96 || $0.cell == 97)
                    && $0.origin == .instruction(effect.address) }
        }) else { return false }
        let definitions = info.plan.definitions
        guard definitions.enumerated().allSatisfy({ $0.offset == $0.element.id }),
              definitions.filter({ $0.origin == .entry }).count == 98,
              Set(definitions.filter({ $0.origin == .entry }).map(\.cell)) == Set(0..<98) else { return false }
        for row in effects.indices {
            guard Set(info.plan.rowReadBindings[row].keys) == Set(effects[row].reads.cells),
                  Set(info.plan.rowWriteBindings[row].keys) == Set(effects[row].writes.map(\.cell)) else { return false }
            for (cell, id) in info.plan.rowReadBindings[row] {
                guard definitions.indices.contains(id), definitions[id].cell == cell else { return false }
            }
            for (cell, id) in info.plan.rowWriteBindings[row] {
                guard definitions.indices.contains(id), definitions[id].cell == cell,
                      definitions[id].origin == .instruction(sources[row].address) else { return false }
            }
        }
        for definition in definitions {
            switch definition.origin {
            case .entry: break
            case let .instruction(address):
                guard let row = info.sourceAddresses.firstIndex(of: address),
                      info.plan.rowWriteBindings[row][definition.cell] == definition.id else { return false }
            case .phi: break // Removed trivial phis retain definition identity, never a row write.
            default: return false
            }
        }
        for phi in info.plan.phis {
            guard phi.block == graph.entry, (0..<29).contains(phi.cell) || phi.cell == 97,
                  phi.incoming.count == 2,
                  phi.incoming[0].predecessor == .functionEntry,
                  phi.incoming[1].predecessor == .machine(block: 0, address: sources[sources.count - 2].address),
                  info.plan.definitions.indices.contains(phi.incoming[0].definition) else { return false }
            let entry = info.plan.definitions[phi.incoming[0].definition]
            guard entry.origin == .entry, entry.cell == phi.cell,
                  info.values[entry.id] != nil else { return false }
        }
        guard function.phis.count == info.plan.phis.count else { return false }
        for (published, planned) in zip(function.phis, info.plan.phis) {
            guard published.blockAddress == function.startAddress, published.cell == planned.cell,
                  published.destination == info.values[planned.destination],
                  published.incoming.map(\.predecessor) == planned.incoming.map(\.publicPredecessor),
                  info.plan.definitions.indices.contains(planned.destination) else { return false }
            let destination = info.plan.definitions[planned.destination]
            guard published.bitWidth == destination.bitWidth, published.scalarView == .integer else { return false }
            for (incoming, slot) in zip(published.incoming, planned.incoming) {
                guard info.plan.definitions.indices.contains(slot.definition), let value = info.values[slot.definition] else { return false }
                let source = info.plan.definitions[slot.definition]
                let expected = source.bitWidth == 32 && destination.bitWidth == 64 && destination.cell < 32
                    ? MacIRValue.unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: value)) : value
                guard incoming.value == expected else { return false }
            }
        }
        var entryState = BuilderState()
        entryState.parameters = function.parameters
        for definition in info.plan.definitions where definition.origin == .entry && definition.cell < 29 {
            let name = "\(definition.bitWidth == 32 ? "w" : "x")\(definition.cell)"
            guard info.values[definition.id] == entryState.readRegister(name) else { return false }
        }
        return true
    }

    func buildSSAFunction<Row: DecompilerInstructionRow>(
        name: String, startAddress: UInt64?, endAddress: UInt64? = nil, rows suppliedRows: [Row], initialState: BuilderState,
        jumpTables: [UInt64: [UInt64]], recoveredSwitches: [UInt64: RecoveredSwitch],
        tailCalls: [UInt64: ProvenTailCall], isVariadic: Bool,
        slotCallContracts: [UInt64: FunctionPointerSignatureV1],
        slotCallSignatures: [UInt64: MacIRCallSignature],
        knownTailCallTargets: [UInt64: String]
    ) -> MacIRFunction? {
        let owningFunctionRange = suppliedRows.first.flatMap { first -> Range<UInt64>? in
            let lower = startAddress ?? first.address
            guard let last = suppliedRows.last,
                  let upper = endAddress ?? last.address.addressAfter(), lower < upper else { return nil }
            return lower..<upper
        }
        // The graph and every SSA row-indexed table must describe the same
        // owned rows, even when the decoder supplied adjacent function bytes.
        let rows = suppliedRows.filter { owningFunctionRange?.contains($0.address) ?? true }
        let sources = rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
            mnemonic: $0.mnemonic.lowercased(), operands: $0.operands,
            comment: $0.comment, structuredOperands: $0.structuredOperands) }
        func cancelledResult() -> MacIRFunction {
            Self.cancelledSSAFunction(name: name, startAddress: startAddress,
                                      sources: sources, parameters: initialState.parameters)
        }
        if ssaIsCancelled { return cancelledResult() }
        let sourceProof = Self.boundedEntrySourceProof(sources)
        let skeleton = sourceProof?.skeleton ?? sources.map {
            MacIRInstruction(source: $0, operation: .intrinsic(destination: nil, name: "nop", arguments: []))
        }
        var provenTailCallTargets: [UInt64: UInt64] = [:]
        for row in rows where tailCalls[row.address] != nil {
            if let target = MacIRTailCallProof.address(row.operands) {
                provenTailCallTargets[row.address] = target
            }
        }
        guard let graph = MacIRCFG.build(instructions: skeleton, jumpTables: jumpTables,
            knownTailCallTargets: knownTailCallTargets,
            provenTailCallTargets: provenTailCallTargets,
            authoredCallSignaturesByTarget: initialState.authoredCallSignaturesByTarget,
            owningFunctionRange: owningFunctionRange) else {
            return cancelledResult()
        }
        if graph.refusals.contains(where: {
            $0.reason == .jumpTableOutsideFunction && $0.scope == .function
        }) {
            return nil
        }
        let hasEntryBackedge = !graph.blocks.isEmpty && !graph.blocks[graph.entry].predecessors.isEmpty
        let boundedEntry = hasEntryBackedge && sourceProof != nil && !isVariadic && Self.boundedEntryState(initialState)
            && Self.boundedEntryLoopGraphMatches(sources, graph: graph)
        if hasEntryBackedge && !boundedEntry { return nil }
        let tracksFPEnvironment = sources.contains {
            MacIRFPBlockedEffect.requiresEnvironment(mnemonic: $0.mnemonic, operands: $0.operands)
                || MacIRFPBlockedEffect.isStatusAccess(source: $0)
        }
        let observesFPSR = sources.contains { $0.mnemonic == "mrs" && $0.operands.lowercased().contains("fpsr") }
        var omittedDirectResultAddresses: Set<UInt64> = []
        var callOutcomes: [Int: [BuilderState.SSACallOutcome: [Int: MacIRSSA.Write]]] = [:]
        var originalCallWrites: [Int: [Int: MacIRSSA.Write]] = [:]
        func resultWrites(_ registers: [String], target: String) -> [Int: MacIRSSA.Write] {
            var result: [Int: MacIRSSA.Write] = [:]
            for register in registers {
                guard let view = Self.ssaRegisterView(for: register) else { continue }
                for cell in view.cells {
                    result[cell] = .init(cell: cell, bitWidth: cell < 32 ? view.bitWidth : 64,
                        view: cell >= 64 ? .bits : view.view, origin: .callResult(target: target))
                }
            }
            return result
        }
        func registerName(_ register: DarwinARM64RichRegister) -> String {
            switch register {
            case let .gpr(index, width): return "\(width == 64 ? "x" : "w")\(index)"
            case let .simd(index, width): return "\(width == 64 ? "d" : "s")\(index)"
            }
        }
        let effects = sources.enumerated().map { rowIndex, source -> MacIRSSA.RowEffects in
            var effective = source
            if let tail = tailCalls[source.address] {
                effective.mnemonic = tail.callMnemonic
                effective.operands = tail.callOperands
                effective.structuredOperands = nil
            }
            let operands = Self.splitOperands(effective.operands)
            let operand = operands.first ?? ""
            let validCall = Self.hasValidReturningCallOperands(mnemonic: effective.mnemonic, operands: operands)
            let isDirect = effective.mnemonic == "bl" && validCall
            let isIndirect = ["blr", "blraa", "blrab", "blraaz", "blrabz"].contains(effective.mnemonic) && validCall
            let known = isDirect ? Self.knownCallSignature(for: operand) : nil
            let authored = isDirect ? initialState.authoredCallSignaturesByTarget[operand] : nil
            let scalar = isDirect ? initialState.authoredScalarCall(target: operand) : nil
            let richShape = isDirect ? initialState.authoredRichCallShape(target: operand) : nil
            let slotReturn = isIndirect ? slotCallSignatures[source.address]?.returnType : nil
            let returnType = scalar?.signature.returnType ?? richShape?.returnType ?? slotReturn ?? known?.returnType
            let voidOnly: Bool
            if isDirect, scalar == nil, known == nil, authored == nil,
               let contract = initialState.directCallVoidResultTargets[operand],
               contract.returnType == "void", case .unspecified = contract.parameterList,
               contract.variadicState == .unspecified {
                voidOnly = true
                omittedDirectResultAddresses.insert(source.address)
            } else { voidOnly = false }
            let call = SSAEffectsCallContext(target: operand,
                resultRegister: scalar?.resultRegister
                    ?? CallSignatureCatalog.returnRegister(for: returnType ?? "") ?? "x0",
                returnsValue: returnType != "void" && !voidOnly)
            var effect = Self.ssaEffects(for: effective, call: call, observesFPSR: observesFPSR,
                                         tracksFPEnvironment: tracksFPEnvironment)
            var outcomes: [BuilderState.SSACallOutcome: [Int: MacIRSSA.Write]] = [:]
            if isIndirect, slotReturn == "void" {
                outcomes = [.typedIndirect: [:], .fallback: resultWrites(["x0"], target: operand)]
            } else if let richShape {
                let primaryRegisters: [String]
                switch richShape.returnLocation {
                case let .single(register): primaryRegisters = [registerName(register)]
                case let .composite(pieces): primaryRegisters = pieces.map { registerName($0.register) }
                case .indirect: primaryRegisters = []
                default: primaryRegisters = []
                }
                let primary = resultWrites(primaryRegisters, target: operand)
                // The rich shape owns its complete returned-register footprint.
                // A scalar spelling guess must not leave a phantom X0 result for
                // an HFA or an indirect result-buffer call.
                for index in effect.writes.indices {
                    if case .callResult = effect.writes[index].origin {
                        let cell = effect.writes[index].cell
                        effect.writes[index] = .init(cell: cell, bitWidth: 64,
                            view: cell < 32 ? .integer : .bits, origin: .callClobber(source.address))
                    }
                }
                for (cell, write) in primary {
                    if let index = effect.writes.firstIndex(where: { $0.cell == cell }) { effect.writes[index] = write }
                    else { effect.writes.append(write) }
                }
                effect.writes.sort { $0.cell < $1.cell }
                let fallbackType = scalar?.signature.returnType ?? known?.returnType
                let fallback = fallbackType == "void" ? [:] : resultWrites([
                    scalar?.resultRegister ?? CallSignatureCatalog.returnRegister(for: fallbackType ?? "") ?? "x0"
                ], target: operand)
                // Same integer carrier is not a missing-result ambiguity. Leave
                // its established width behavior and downstream evidence intact.
                let sameCellsAndViews = Set(primary.keys) == Set(fallback.keys)
                    && primary.allSatisfy { fallback[$0.key]?.view == $0.value.view }
                if !sameCellsAndViews {
                    outcomes = [.authoredRich: primary, .fallback: fallback]
                }
            }
            if !outcomes.isEmpty {
                callOutcomes[rowIndex] = outcomes
                originalCallWrites[rowIndex] = Dictionary(uniqueKeysWithValues: effect.writes.compactMap {
                    if case .callResult = $0.origin { return ($0.cell, $0) }; return nil
                })
                let cells = Set(outcomes.values.flatMap { $0.keys })
                for cell in cells {
                    // Every alternative shares a physical ID. Clobber width/view
                    // is the conservative phi envelope, not the selected result's type.
                    let envelope = MacIRSSA.Write(cell: cell, bitWidth: 64,
                        view: cell < 32 ? .integer : .bits, origin: .callResult(target: operand))
                    if let index = effect.writes.firstIndex(where: { $0.cell == cell }) { effect.writes[index] = envelope }
                    else { effect.writes.append(envelope) }
                }
                effect.writes.sort { $0.cell < $1.cell }
            }
            return effect
        }
        let entryFacts = initialState.parameters.compactMap { parameter -> MacIRSSA.Write? in
            guard let view = Self.ssaRegisterView(for: parameter.register) else { return nil }
            return .init(cell: view.cell, bitWidth: view.cell < 32 ? view.bitWidth : 64,
                         view: view.view, origin: .entry)
        }
        var plan: MacIRSSA.Plan
        do {
            plan = try MacIRSSA.plan(cfg: graph, rows: effects, entry: entryFacts,
                cellCount: tracksFPEnvironment ? 101 : observesFPSR ? 99 : 98,
                permitsVirtualEntry: boundedEntry, cancelled: { ssaIsCancelled },
                beforeRenaming: ssaBeforeRenaming)
        } catch MacIRSSA.PlanningError.entryBlockHasPredecessor { return nil }
        catch { return cancelledResult() }
        if ssaIsCancelled { return cancelledResult() }

        var conditionalResultAddresses: [Int: UInt64] = [:]
        var preservedConditionalWrites: [Int: MacIRSSA.Write] = [:]
        for (row, outcomes) in callOutcomes {
            for cell in Set(outcomes.values.flatMap { $0.keys }) {
                guard let id = plan.rowWriteBindings[row][cell] else { continue }
                conditionalResultAddresses[id] = sources[row].address
                preservedConditionalWrites[id] = originalCallWrites[row]?[cell]
            }
        }
        var pendingConditionalResults = Set(conditionalResultAddresses.keys)
        var selectedConditionalResults: Set<Int> = []
        var reservedConditionalValues: [Int: [MacIRSSA.Write: MacIRValue]] = [:]
        var plannedCallOutcomes: [Int: [BuilderState.SSACallOutcome: [Int: MacIRSSAState.Binding]]] = [:]
        var values: [Int: MacIRValue] = [:]
        var wholeVectorByDefinition: [Int: MacIRValue] = [:]
        var versions: [Int: Int] = [:]
        func registerName(cell: Int, width: Int, view: MacIRSSA.ScalarView) -> String {
            if cell < 31 { return "\(width == 32 ? "w" : "x")\(cell)" }
            if cell == 31 { return "sp" }
            if cell < 64 {
                return "\(view == .float64 ? "d" : view == .float32 ? "s" : "v")\(cell - 32)"
            }
            if cell < 96 { return "vh\(cell - 64)" }
            return cell == 96 ? "nzcv" : cell == 97 ? "memory" : cell == 98 ? "qc"
                : cell == 99 ? "fpsr_exception_bits" : "fpcr_control"
        }
        let sourceByAddress = Dictionary(sources.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        func definitionRegisterName(_ definition: MacIRSSA.Definition) -> String {
            if case let .instruction(address) = definition.origin,
               let source = sourceByAddress[address] {
                let operands = Self.splitOperands(source.operands)
                let destinations = operands.prefix(["ldp", "ldpsw"].contains(source.mnemonic) ? 2 : 1)
                for operand in destinations {
                    let name = operand.lowercased()
                    guard let view = Self.ssaRegisterView(for: name), view.cell == definition.cell else { continue }
                    if name == "fp" || name == "lr" { return name }
                    if (32..<64).contains(definition.cell), definition.view == .bits,
                       view.bitWidth <= 64, !name.contains("["), !name.contains(".") {
                        return name
                    }
                }
            }
            return registerName(cell: definition.cell, width: definition.bitWidth, view: definition.view)
        }
        // Allocate ordinary row names in source order; phi names follow them.
        // Every physical cell shares one counter across all architectural views.
        let allocationOrder = plan.definitions.filter { if case .phi = $0.origin { return false }; return true }
            + plan.definitions.filter { if case .phi = $0.origin { return true }; return false }
        for definition in allocationOrder {
            let cell = definition.cell
            let register = definitionRegisterName(definition)
            if conditionalResultAddresses[definition.id] != nil {
                let clobberName = registerName(cell: cell, width: 64, view: cell < 32 ? .integer : .bits)
                values[definition.id] = .unknown("unavailable_\(clobberName)")
                if let write = preservedConditionalWrites[definition.id] {
                    versions[cell, default: 0] += 1
                    let name = registerName(cell: cell, width: write.bitWidth, view: write.view)
                    reservedConditionalValues[definition.id] = [write:
                        .register(name: name, version: versions[cell, default: 0])]
                }
                continue
            }
            switch definition.origin {
            case .entry:
                if (64..<96).contains(cell) {
                    values[definition.id] = .unary(op: "__ssa_high64",
                        value: .register(name: "v\(cell - 64)", version: 0))
                } else {
                    let entry = cell >= 99 ? MacIRValue.unknown(register)
                        : cell < 64 ? initialState.readRegister(register)
                        : .register(name: register, version: 0)
                    if (32..<64).contains(cell), definition.view == .bits,
                       case .register = entry {
                        values[definition.id] = .unary(op: "__ssa_low64", value: entry)
                    } else { values[definition.id] = entry }
                }
            case let .callClobber(address):
                // Reserve only the omitted result's display name. Its reaching
                // definition stays unavailable: no value or return authority is
                // created merely to keep later register names unchanged.
                if cell == 0, omittedDirectResultAddresses.contains(address) {
                    versions[cell, default: 0] += 1
                }
                values[definition.id] = .unknown("unavailable_\(register)")
            case .refusal:
                values[definition.id] = .unknown("unavailable_\(register)")
            default:
                versions[cell, default: 0] += 1
                values[definition.id] = .register(name: register, version: versions[cell, default: 0])
            }
        }
        // New alternative names follow all ordinary/phi names. Exact matching
        // primary shapes reuse their old identity; unused names are never displayed.
        for row in callOutcomes.keys.sorted() {
            guard let outcomes = callOutcomes[row] else { continue }
            for outcome in [BuilderState.SSACallOutcome.authoredRich, .typedIndirect, .fallback] {
                guard let writes = outcomes[outcome] else { continue }
                var bindings: [Int: MacIRSSAState.Binding] = [:]
                for cell in writes.keys.sorted() {
                    guard let write = writes[cell], let id = plan.rowWriteBindings[row][cell] else { continue }
                    let value: MacIRValue
                    if let existing = reservedConditionalValues[id]?[write] { value = existing }
                    else {
                        versions[cell, default: 0] += 1
                        value = .register(name: registerName(cell: cell, width: write.bitWidth, view: write.view),
                                          version: versions[cell, default: 0])
                        reservedConditionalValues[id, default: [:]][write] = value
                    }
                    bindings[cell] = .init(value: value, bitWidth: write.bitWidth, view: write.view,
                        origin: write.origin, hasCallArgumentEvidence: false)
                }
                plannedCallOutcomes[row, default: [:]][outcome] = bindings
            }
        }
        // Scalar and 64-bit vector writes define an architectural zero in the
        // upper half. Persist that constant on the definition itself so readers
        // observe the implicit write without adding another ordinary row.
        for (rowIndex, source) in sources.enumerated() {
            // These descriptors produce a full carrier, including Q0 zero upper bits.
            if Self.ssaVectorPermutation(source) != nil
                || Self.ssaIntegerLaneOperation(mnemonic: source.mnemonic, operands: source.operands) != nil
                || MacIRVectorFP(source: source) != nil { continue }
            let operands = Self.splitOperands(source.operands)
            let destinations = operands.prefix(["ldp", "ldpsw"].contains(source.mnemonic) ? 2 : 1)
            for operand in destinations {
                guard let view = Self.ssaRegisterView(for: operand), (32..<64).contains(view.cell),
                      view.bitWidth <= 64, !operand.contains("["),
                      plan.rowWriteBindings[rowIndex][view.cell] != nil,
                      let highID = plan.rowWriteBindings[rowIndex][view.cell + 32],
                      case .instruction = plan.definitions[highID].origin else { continue }
                values[highID] = .immediate(0)
            }
        }
        for (alias, target) in plan.aliases { values[alias] = values[plan.canonicalID(target)] }
        // Freeze disputed-cell argument/producer evidence as unavailable.
        // Selecting a result does not retroactively grant call-argument authority
        // through an already visited loop or nontrivial forward phi.
        var callAuthorityPlan = plan
        for (id, address) in conditionalResultAddresses {
            callAuthorityPlan.definitions[id].origin = .callClobber(address)
        }
        let unobservedCallArguments = Self.ssaUnobservedCallArgumentDefinitions(plan: callAuthorityPlan, values: values)
        func binding(_ id: Int) -> MacIRSSAState.Binding {
            let canonical = plan.canonicalID(id)
            let definition = plan.definitions[canonical]
            if pendingConditionalResults.contains(canonical), let address = conditionalResultAddresses[canonical] {
                let name = registerName(cell: definition.cell, width: 64,
                                        view: definition.cell < 32 ? .integer : .bits)
                return .init(value: .unknown("unavailable_\(name)"), bitWidth: 64,
                    view: definition.cell < 32 ? .integer : .bits,
                    origin: .callClobber(address), hasCallArgumentEvidence: false)
            }
            return .init(value: values[canonical] ?? .unknown("unbound_ssa"),
                bitWidth: definition.bitWidth, view: definition.view, origin: definition.origin,
                hasCallArgumentEvidence: selectedConditionalResults.contains(canonical)
                    || !unobservedCallArguments.contains(canonical),
                wholeVector: wholeVectorByDefinition[canonical])
        }
        let stackOffsets = Self.ssaStackOffsets(plan: plan, sources: sources, cancelled: { ssaIsCancelled })
        let localStackOffsets = Self.ssaStackOffsets(plan: plan, sources: sources, localsOnly: true, cancelled: { ssaIsCancelled })
        let pristineStack = Self.ssaPristineEntryStack(plan: plan, cfg: graph, sources: sources,
            offsets: stackOffsets, cancelled: { ssaIsCancelled })
        if ssaIsCancelled { return cancelledResult() }
        let phiGroups = Self.ssaPhiGroups(plan)
        // Block-independent: cell-0 phis that carry a real instruction write.
        let x0ProducerPhiDestinations = plan.phis.filter {
            $0.cell == 0 && Self.ssaHasInstructionProducer(forDefinition: $0.destination, plan: callAuthorityPlan, phiGroups: phiGroups)
        }.map(\.destination)
        let proof = Self.ssaReturnProducerProof(plan: plan, sources: sources, cfg: graph, phiGroups: phiGroups)
        var children = [[Int]](repeating: [], count: graph.blocks.count)
        for block in graph.blocks.indices where block != graph.entry && graph.idom[block] >= 0 {
            children[graph.idom[block]].append(block)
        }
        var order: [Int] = []
        var pending = graph.blocks.isEmpty ? [] : [graph.entry]
        while let block = pending.popLast() {
            order.append(block)
            pending.append(contentsOf: children[block].reversed())
        }
        order.append(contentsOf: graph.unreachable)
        // A27: a block holding a flags phi is processed after every forward
        // predecessor so each incoming comparison is recorded when it is read.
        // Back edges stay unestablished and keep the refusal.
        let flagPhiBlocks = Set(plan.phis.filter { $0.cell == 96 }.map(\.block))
        if !flagPhiBlocks.isEmpty {
            func dominates(_ a: Int, _ b: Int) -> Bool {
                var node = b
                while node >= 0 {
                    if node == a { return true }
                    if node == graph.entry { return false }
                    node = graph.idom[node]
                }
                return false
            }
            for _ in 0..<(graph.blocks.count + 1) {
                var moved = false
                for block in order where flagPhiBlocks.contains(block) {
                    guard let position = order.firstIndex(of: block) else { continue }
                    var span = [block]
                    var index = position + 1
                    while index < order.count, dominates(block, order[index]) { span.append(order[index]); index += 1 }
                    let spanSet = Set(span)
                    let forward = graph.blocks[block].predecessors.filter { !dominates(block, $0) }
                    guard let last = forward.compactMap({ order.firstIndex(of: $0) }).max(),
                          last > position, !spanSet.contains(order[last]) else { continue }
                    var rest = order.filter { !spanSet.contains($0) }
                    let insertAt = (rest.firstIndex(of: order[last]) ?? rest.count - 1) + 1
                    rest.insert(contentsOf: span, at: insertAt)
                    order = rest
                    moved = true
                    break
                }
                if !moved { break }
            }
        }
        // immutable machine-NZCV snapshots are independent of the
        // legacy lexical cache and survive flag-neutral loads/overwrites.
        var exactValueSnapshots: [Int: SSANZCVSnapshot] = [:]
        var exactValueMemo: [SSANZCVPredicateKey: SSANZCVPredicate] = [:]
        var exactValuePhis: [SSANZCVPredicateKey: MacIRPhi] = [:]
        var exactValueUnknownSources = Set<UInt64>()
        var exactValueKnownSources = Set<UInt64>()
        var exactValueCallResults = Set<Int>()
        var flagComparisonByDef: [Int: BuilderComparison] = [:]
        var flagPhis: [MacIRPhi] = []
        var flagPhiComparisons: Set<UInt64> = []
        var compoundChains: [CompoundChain] = []
        let flagPhiByDestination = Dictionary(plan.phis.filter { $0.cell == 96 }.map { ($0.destination, $0) },
                                              uniquingKeysWith: { first, _ in first })
        var outgoing: [Int: BuilderState] = [:]
        var output = [[MacIRInstruction]](repeating: [], count: rows.count)
        var refusals = plan.refusals
        var aggregate = initialState
        var captures: [UInt64: [(UInt64, String)]] = [:]
        for (dispatch, recovered) in recoveredSwitches {
            if let selector = recovered.selector {
                captures[selector.definitionAddress, default: []].append((dispatch, selector.register))
            }
        }
        var selectorValues: [UInt64: MacIRValue] = [:]
        for blockIndex in order {
            if ssaIsCancelled { return cancelledResult() }
            let block = graph.blocks[blockIndex]
            var state = outgoing[graph.idom[blockIndex]] ?? initialState
            let predecessors = block.predecessors.compactMap { outgoing[$0] }
            state.constructedCallArgumentGPRs = predecessors.count == block.predecessors.count && !predecessors.isEmpty
                ? predecessors.dropFirst().reduce(predecessors[0].constructedCallArgumentGPRs) {
                    $0.intersection($1.constructedCallArgumentGPRs)
                } : []
            let effectivePredecessorCount = block.predecessors.count + (boundedEntry && blockIndex == graph.entry ? 1 : 0)
            if effectivePredecessorCount != 1 {
                state.invalidateAllStackSlotValues()
                state.materializedImmediateByRegister.removeAll()
                state.adrpPageBaseByRegister.removeAll()
                state.stackPointerAliasOffsetByGPR.removeAll()
            }
            state.ssaFlagPhis = []
            state.ssaFlagPhiComparisons = []
            state.ssaCompoundChains = []
            state.flagsPhiContext = nil
            state.ssa = MacIRSSAState(current: plan.blockEntryBindings[blockIndex].mapValues(binding),
                                     writes: [:], clobbers: [:])
            state.resolvedX0PhiReturnProducers = Set(x0ProducerPhiDestinations.compactMap { values[$0] })
            let entrySP = plan.blockEntryBindings[blockIndex][31].flatMap { stackOffsets[$0] }
            state.ssa?.stackPointerOffset = entrySP
            state.entrySPIsExact = entrySP != nil
            if let offset = entrySP {
                state.stackDisplacement = offset < 0 && offset != Int64.min ? -offset : 0
            }
            if let sp = plan.blockEntryBindings[blockIndex][31], let offset = localStackOffsets[sp] {
                state.stackDepth = offset < 0 && offset != Int64.min ? -offset : 0
            }
            state.ssaReturnProducerProof = proof
            state.synchronizeSSARegisterState()
            state.lastAdjacentComparison = nil
            state.pendingConditionalCompare = nil
            // Preserve lexical fallthrough comparison context only when its
            // sole predecessor carries the same exact NZCV definition. Remote
            // branches keep their intrinsic and use the separate SSA binding.
            let lexicalComparisonPredecessor = block.predecessors.first.flatMap { predecessor -> Int? in
                guard effectivePredecessorCount == 1,
                      graph.blocks[predecessor].instructionRange.upperBound == block.instructionRange.lowerBound,
                      let incoming = plan.blockEntryBindings[blockIndex][96],
                      let outgoingFlags = plan.blockExitBindings[predecessor][96],
                      plan.canonicalID(incoming) == plan.canonicalID(outgoingFlags) else { return nil }
                return predecessor
            }
            state.lastComparison = lexicalComparisonPredecessor.flatMap { outgoing[$0]?.lastComparison }
            var arithmeticRewrite = MacIRArithmeticRewrite()
            for rowIndex in block.instructionRange {
                let source = sources[rowIndex]
                state.ssa?.entryStackMemoryIsPristine = pristineStack[rowIndex]
                state.flagsPhiContext = nil
                if let reaching = plan.rowReadBindings[rowIndex][96],
                   let phi = flagPhiByDestination[plan.canonicalID(reaching)] {
                    let incomings = phi.incoming.compactMap { edge -> (predecessorAddress: UInt64, comparison: BuilderComparison)? in
                        guard let address = edge.machineAddress else { return nil }
                        return flagComparisonByDef[plan.canonicalID(edge.definition)].map { (address, $0) }
                    }
                    if incomings.count == phi.incoming.count, graph.blocks[phi.block].predecessors.count == incomings.count {
                        state.flagsPhiContext = .init(blockAddress: graph.blocks[phi.block].startAddress,
                                                      rowAddress: source.address, incomings: incomings)
                    }
                }
                if let sp = plan.rowReadBindings[rowIndex][31] {
                    state.ssa?.stackPointerOffset = stackOffsets[sp]
                    state.entrySPIsExact = stackOffsets[sp] != nil
                }
                let planned = plan.rowWriteBindings[rowIndex].mapValues(binding)
                state.ssa?.writes = planned.filter { !$0.value.isUnavailable }
                state.ssa?.clobbers = planned.filter { $0.value.isUnavailable }
                state.ssaPlannedCallOutcomes = plannedCallOutcomes[rowIndex] ?? [:]
                state.ssaSelectedCallOutcome = nil
                // A call invalidates its result cell before assigning the result.
                if ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(source.mnemonic) {
                    for cell in Array(0...18) + [30] where state.ssa?.clobbers[cell] == nil {
                        state.ssa?.clobbers[cell] = MacIRSSAState.Binding(value: .unknown("unavailable_x\(cell)"),
                            bitWidth: 64, view: .integer, origin: .callClobber(source.address))
                    }
                }
                state.ssaReturnRefusal = plan.rowReadBindings[rowIndex][0].flatMap {
                    Self.ssaRefusalReason(forDefinition: $0, plan: plan, phiGroups: phiGroups)
                }
                state.provenSwitchSelectors = selectorValues
                let returnTarget = source.mnemonic == "ret" && !source.operands.isEmpty
                    ? Self.value(for: source.operands, state: state) : nil
                let exactVector = Self.ssaExactVector(source)
                let exactValueInputs = Set(plan.rowReadBindings[rowIndex]
                    .filter { (0..<96).contains($0.key) }.map(\.value))
                let exactValueSnapshot = Self.ssaNZCVSnapshot(source, state: state,
                    numericInputs: exactValueInputs,
                    reachingFlags: plan.rowReadBindings[rowIndex][96].map { plan.canonicalID($0) })
                state.ssaExactNumericInputsAvailable =
                    (Self.ssaExactSignedInsert(source) || Self.ssaExactIndexedQStore(source) != nil)
                    && Self.ssaNumericAncestryIsAvailable(roots: exactValueInputs,
                        plan: plan, sources: sources, graph: graph, actualUnknownSources: exactValueUnknownSources,
                        actualKnownSources: exactValueKnownSources,
                        actualCallResultDefinitions: exactValueCallResults)
                let exactValueSelect = Self.ssaSnapshotSelect(source)
                let exactValueBefore: BuilderState? = exactValueSelect == nil ? nil : state
                var emitted: [MacIRInstruction]
                if let widening = Self.neonWideningPairwise(source) {
                    emitted = [Self.liftNEONWideningPairwise(widening, source: source, state: &state)]
                } else if let permutation = Self.ssaVectorPermutation(source) {
                    // Inputs are read before the destination, including INS's preserved lanes.
                    var arguments = permutation.sources.map { state.readRegister($0) }
                    if permutation.readsDestination { arguments.append(state.readRegister(permutation.destination)) }
                    let destination = state.writeRegister(permutation.destination)
                    if let bitView = permutation.bitView, bitView.kind == .unsignedMoveElement {
                        state.recordValueType(bitView.elementBits == 64 ? "uint64_t" : "uint32_t", for: destination)
                    }
                    emitted = [.init(source: source,
                        operation: .intrinsic(destination: destination, name: permutation.intrinsicName, arguments: arguments),
                        neonExtract: permutation.extract, neonTableLookup: permutation.table,
                        neonBitView: permutation.bitView, neonReduction: permutation.reduction,
                        neonByteDotProduct: permutation.dot, neonLaneOp: permutation.lane)]
                } else if let exactVector, let exact = Self.liftSSAExactVector(exactVector, source: source, state: &state) {
                    emitted = exact
                } else if MacIRVectorFP(source: source) == nil,
                          Self.ssaIntegerLaneOperation(mnemonic: source.mnemonic, operands: source.operands) == nil,
                          Self.hasUnclaimedVectorOperand(source.operands),
                   // A43: a row whose vector registers the SSA plan models (cells >= 32 are the
                   // low/high vector halves) is claimed; only an unplanned vector row is refused. A memory
                   // transfer is never claimed here: its address, writeback and width stay with the owned
                   // vector-memory path, and a transfer that path rejects must still refuse.
                   !(!source.operands.contains("[")
                     && (plan.rowWriteBindings[rowIndex].keys.contains { $0 >= 32 }
                         || plan.rowReadBindings[rowIndex].keys.contains { $0 >= 32 })) {
                    emitted = [generalVectorRefusal(rows[rowIndex], state: &state)]
                } else if let fp = MacIRVectorFP(source: source),
                          let outputID = plan.rowWriteBindings[rowIndex][99], let output = values[outputID] {
                    let controls = plan.rowReadBindings[rowIndex][100].map { binding($0).value }
                        ?? .unknown("fpcr_control")
                    let status = plan.rowReadBindings[rowIndex][99].map { binding($0).value }
                        ?? .unknown("fpsr_exception_bits")
                    emitted = Self.liftVectorFP(fp, source: source, state: &state,
                        fpcr: controls, exceptions: status, exceptionOutput: output)
                } else if let lane = Self.ssaIntegerLaneOperation(mnemonic: source.mnemonic, operands: source.operands) {
                    let qcInput = plan.rowReadBindings[rowIndex][98].map { binding($0).value }
                    let operation = Self.liftNEONLane(lane, state: &state)
                    emitted = [.init(source: source, operation: operation, neonLaneOp: lane.semantics)]
                    if observesFPSR, lane.semantics.setsQC,
                       let input = qcInput, let outputID = plan.rowWriteBindings[rowIndex][98],
                       let output = values[outputID],
                       case let .intrinsic(_, _, arguments) = operation {
                        emitted[0].neonQCIsSeparate = true
                        emitted.append(MacIRNEONQCEffect(lane: lane.semantics, arguments: arguments,
                            input: input, output: output).instruction(source: source))
                    }
                } else if let immediate = Self.neonBitClearImmediate(mnemonic: source.mnemonic, operandText: source.operands) {
                    emitted = Self.liftNEONBitClearImmediate(immediate, source: source, state: &state)
                } else if let tail = tailCalls[source.address] {
                    var callSource = source
                    callSource.mnemonic = tail.callMnemonic
                    callSource.operands = tail.callOperands
                    callSource.structuredOperands = nil
                    let call = operation(for: callSource, state: &state,
                        slotCallContract: slotCallContracts[source.address],
                        slotCallSignature: slotCallSignatures[source.address])
                    if case .call = call {
                        let returned = state.authoritativeReturnLocation == nil && state.callerReturnWidth == nil
                            ? MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
                            : state.preferredReturnValue()
                        state.returnValue = returned
                        emitted = [.init(source: tail.source(source, phase: .call), operation: call),
                                   .init(source: tail.source(source, phase: .returnAfterCall), operation: .returnValue(returned))]
                    } else { emitted = [.init(source: source, operation: call)] }
                } else {
                    let lifted = operation(for: source, state: &state, recoveredSwitches: recoveredSwitches,
                        slotCallContract: slotCallContracts[source.address],
                        slotCallSignature: slotCallSignatures[source.address])
                    let operation: MacIROperation
                    if boundedEntry, let proof = sourceProof,
                       source.address == proof.sources[proof.branchIndex].address {
                        guard case let .conditionalBranch(condition, left, right, _) = lifted,
                              condition == "!=" else { return nil }
                        operation = .conditionalBranch(condition: condition, left: left, right: right,
                            target: .immediate(Int64(proof.target)))
                    } else { operation = lifted }
                    let typed = Self.explicitComparisonTypes(operation, source: source,
                        argumentBitWidths: state.argumentBitWidths, parameters: state.parameters,
                        projectSigned: true)
                    let operands = Self.splitOperands(source.operands)
                    let rewritten = arithmeticRewrite.rewrite(typed, mnemonic: source.mnemonic,
                        width: operands.first.flatMap(Self.scalarDataBitWidth),
                        operandWidths: operands.dropFirst().map(Self.scalarDataBitWidth),
                        address: source.address, allowSequence: state.remainderFoldingAllowed)
                    let persisted: MacIROperation
                    if source.mnemonic == "fmov", operands.count == 2,
                       operands[0].lowercased().hasPrefix("h"),
                       operands[1].hasPrefix("#"), let literal = Float16(operands[1].dropFirst()),
                       case let .assign(destination, _) = rewritten {
                        persisted = .assign(destination: destination, source: .immediate(Int64(literal.bitPattern)))
                    } else if source.mnemonic == "fmov", operands.count == 2,
                              let view = Self.ssaRegisterView(for: operands[0]),
                              (32..<64).contains(view.cell), view.bitWidth < 64,
                              case let .intrinsic(destination, name, arguments) = rewritten,
                              name == "fmov", let argument = arguments.first {
                        let mask = Int64((UInt64(1) << view.bitWidth) - 1)
                        persisted = .intrinsic(destination: destination, name: name, arguments: [
                            .binaryExpression(op: "&", left: argument, right: .immediate(mask))])
                    } else { persisted = rewritten }
                    emitted = [.init(source: source, operation: persisted,
                        memoryAccess: Self.memoryAccess(for: source), returnTarget: returnTarget,
                        scalarFP: Self.scalarFPSemantics(mnemonic: source.mnemonic, operands: operands))]
                }
                if MacIRFPBlockedEffect.requiresEnvironment(mnemonic: source.mnemonic, operands: source.operands),
                   MacIRVectorFP(source: source) == nil {
                    let fpcr = plan.rowReadBindings[rowIndex][100].map { binding($0).value }
                        ?? .unknown("fpcr_control")
                    let status = plan.rowReadBindings[rowIndex][99].map { binding($0).value }
                        ?? .unknown("fpsr_exception_bits")
                    emitted = emitted.map { instruction in
                        var copy = instruction
                        copy.scalarFP = nil
                        copy.fpBlockedEffect = .init(mnemonic: source.mnemonic, operands: source.operands,
                            fpcrInput: fpcr, exceptionInput: status)
                        return copy
                    }
                }
                // unknown-only transaction. Existing successful lifts
                // and all legacy output are unchanged; no partial phi memo escapes.
                if let select = exactValueSelect, let before = exactValueBefore,
                   emitted.count == 1, case .unknown = emitted[0].operation,
                   let flags = plan.rowReadBindings[rowIndex][96],
                   let transaction = Self.ssaNZCVPredicate(flags: flags, suffix: select.condition,
                    snapshots: exactValueSnapshots, plan: plan, graph: graph, sources: sources,
                    memo: exactValueMemo, phis: exactValuePhis,
                    occupiedValues: Set(values.values)
                        .union(initialState.registerNameBindingsByValue.keys)
                        .union(aggregate.registerNameBindingsByValue.keys)
                        .union(state.registerNameBindingsByValue.keys)
                        .union(flagPhis.map(\.destination))),
                   Self.ssaNumericAncestryIsAvailable(
                    roots: exactValueInputs.union(transaction.predicate.numericInputs), plan: plan,
                    sources: sources, graph: graph, actualUnknownSources: exactValueUnknownSources,
                        actualKnownSources: exactValueKnownSources,
                        actualCallResultDefinitions: exactValueCallResults) {
                    var recovered = before
                    if let operation = select.lift(predicate: transaction.predicate.value, state: &recovered) {
                        // Match operationCore's row-boundary cache clearing. Keep
                        // arithmeticRewrite's already-cleared adjacency, not its old state.
                        recovered.lastAdjacentComparison = nil
                        recovered.pendingConditionalCompare = nil
                        recovered.lastDivision = nil
                        state = recovered
                        emitted = [.init(source: source, operation: operation)]
                        let additions = transaction.phis.filter { exactValuePhis[$0.key] == nil }
                            .sorted { a, b in a.key.definition == b.key.definition
                                ? a.key.condition < b.key.condition : a.key.definition < b.key.definition }
                        flagPhis.append(contentsOf: additions.map(\.value))
                        exactValueMemo = transaction.memo
                        exactValuePhis = transaction.phis
                    }
                }
                let refusedRow = emitted.contains { if case .unknown = $0.operation { return true }; return false }
                if let outcomes = plannedCallOutcomes[rowIndex] {
                    let selected = state.ssaSelectedCallOutcome.flatMap { outcomes[$0] } ?? [:]
                    func resultLeaves(_ value: MacIRValue) -> [MacIRValue] {
                        if case let .abiComposite(_, fragments) = value { return fragments.flatMap(resultLeaves) }
                        return [value]
                    }
                    let actualResults = Set(emitted.flatMap { instruction -> [MacIRValue] in
                        guard case let .call(_, result) = instruction.operation, let result else { return [] }
                        return resultLeaves(result)
                    })
                    for cell in Set(outcomes.values.flatMap { $0.keys }) {
                        guard let id = plan.rowWriteBindings[rowIndex][cell],
                              pendingConditionalResults.remove(id) != nil else { continue }
                        if !refusedRow, let chosen = selected[cell], actualResults.contains(chosen.value),
                           state.ssa?.current[cell]?.value == chosen.value,
                           state.ssa?.current[cell]?.origin == chosen.origin {
                            plan.definitions[id].origin = chosen.origin
                            plan.definitions[id].bitWidth = chosen.bitWidth
                            plan.definitions[id].view = chosen.view
                            values[id] = chosen.value
                            // Keep slot-void fallback argument evidence conservative.
                            // Disputed direct outcomes may supply later direct uses,
                            // never a new proof for an already cached nontrivial phi.
                            if callOutcomes[rowIndex]?[.authoredRich] != nil { selectedConditionalResults.insert(id) }
                        } else {
                            let view: MacIRSSA.ScalarView = cell < 32 ? .integer : .bits
                            let name = registerName(cell: cell, width: 64, view: view)
                            plan.definitions[id].origin = .callClobber(source.address)
                            plan.definitions[id].bitWidth = 64
                            plan.definitions[id].view = view
                            values[id] = .unknown("unavailable_\(name)")
                            state.ssa?.current[cell] = binding(id)
                            state.ssa?.writes.removeValue(forKey: cell)
                        }
                    }
                }
                if refusedRow { exactValueUnknownSources.insert(source.address) }
                else {
                    exactValueKnownSources.insert(source.address)
                    // Only a matching, actually emitted call result may seed a
                    // later residual value; a future plan.callResult is not enough.
                    for id in plan.rowWriteBindings[rowIndex].values {
                        let canonical = plan.canonicalID(id)
                        guard case .callResult = plan.definitions[canonical].origin,
                              let expected = values[canonical] else { continue }
                        if emitted.contains(where: { instruction in
                            func contains(_ value: MacIRValue) -> Bool {
                                if value == expected { return true }
                                if case let .abiComposite(_, fragments) = value { return fragments.contains(where: contains) }
                                return false
                            }
                            if case let .call(_, result) = instruction.operation, let result { return contains(result) }
                            return false
                        }) { exactValueCallResults.insert(canonical) }
                    }
                }
                if refusedRow {
                    if !refusals.contains(where: { $0.scope == .row(source.address) }) {
                        refusals.append(.init(reason: .unknownEffects, scope: .row(source.address), detail: source.assemblyText))
                    }
                    let destinations = Set(emitted.flatMap { Self.ssaDestinations($0.operation) })
                    for (cell, id) in plan.rowWriteBindings[rowIndex] {
                        if case .refusal = plan.definitions[id].origin {
                            // Keep the classifier's more specific reason.
                        } else {
                            let reason = refusals.first { $0.scope == .row(source.address) }?.reason ?? .unknownEffects
                            plan.definitions[id].origin = .refusal(reason, source.address)
                        }
                        // A claimed unknown destination remains the very same
                        // definition. Only implicit writes need an opaque value.
                        // This prevents late discovery from orphaning a name.
                        if values[id].map({ destinations.contains($0) }) != true {
                            let name = registerName(cell: cell, width: plan.definitions[id].bitWidth,
                                                    view: plan.definitions[id].view)
                            values[id] = .unknown("unavailable_\(name)")
                        }
                    }
                    // Proof inputs (definitions, phis, bindings, aliases) are unchanged
                    // since the first computation, so its result is too.
                    state.ssaReturnProducerProof = proof
                } else {
                    // Retained wide operations produce one 128-bit temporary;
                    // the architectural plan persists two independently defined
                    // 64-bit cells. Split the actual result, never the old cells.
                    var operands = Self.ssaVectorPermutation(source).map { [$0.destination] }
                        ?? Self.splitOperands(source.operands)
                    // Lane descriptors always return all128 physical bits, even
                    // Q=0. Narrowing-2 forms read and preserve the old low64 bits.
                    if let lane = Self.ssaIntegerLaneOperation(mnemonic: source.mnemonic, operands: source.operands) {
                        operands.append(lane.destination)
                    }
                    if let fp = MacIRVectorFP(source: source) { operands.append(fp.destination) }
                    var splitCells: Set<Int> = []
                    for operand in operands {
                        // Exact vector rows already define individual physical halves.
                        guard exactVector == nil,
                              let view = Self.ssaRegisterView(for: operand), view.bitWidth == 128,
                              (32..<64).contains(view.cell), !splitCells.contains(view.cell),
                              let lowID = plan.rowWriteBindings[rowIndex][view.cell],
                              let highID = plan.rowWriteBindings[rowIndex][view.cell + 32],
                              let low = values[lowID], let high = values[highID],
                              emitted.contains(where: { Self.ssaDestinations($0.operation).contains(low) }),
                              case let .register(_, version) = low else { continue }
                        splitCells.insert(view.cell)
                        let whole = MacIRValue.register(name: "q\(view.cell - 32)", version: version)
                        wholeVectorByDefinition[plan.canonicalID(lowID)] = whole
                        wholeVectorByDefinition[plan.canonicalID(highID)] = whole
                        emitted = emitted.map { instruction in
                            var copy = instruction
                            copy.operation = Self.ssaReplacingDestination(low, with: whole, in: copy.operation)
                            if let fp = copy.vectorFP, fp.numericOutput == low {
                                copy.vectorFP = fp.replacingNumericOutput(whole)
                            }
                            if let fp = copy.vectorFPStatus, fp.numericOutput == low {
                                copy.vectorFPStatus = fp.replacingNumericOutput(whole)
                            }
                            return copy
                        }
                        emitted.append(.init(source: source, operation: .assign(destination: low,
                            source: .unary(op: "__ssa_low64", value: whole))))
                        emitted.append(.init(source: source, operation: .assign(destination: high,
                            source: .unary(op: "__ssa_high64", value: whole))))
                    }
                }
                if !refusedRow, let snapshot = exactValueSnapshot,
                   let id = plan.rowWriteBindings[rowIndex][96] {
                    exactValueSnapshots[plan.canonicalID(id)] = snapshot
                }
                if !refusedRow, let id = plan.rowWriteBindings[rowIndex][96],
                   let comparison = state.lastComparison, comparison.sourceAddress == source.address {
                    flagComparisonByDef[plan.canonicalID(id)] = comparison
                }
                state.flagsPhiContext = nil
                for (cell, id) in plan.rowWriteBindings[rowIndex] {
                    if let current = state.ssa?.current[cell], current.origin == plan.definitions[id].origin {
                        values[id] = current.value
                    }
                    // Implicit writes are first-class even when the row operation
                    // has no corresponding rendered destination.
                    state.ssa?.current[cell] = binding(id)
                }
                if refusedRow { state.synchronizeSSARegisterState() }
                if let sp = plan.rowWriteBindings[rowIndex][31] {
                    state.ssa?.stackPointerOffset = stackOffsets[sp]
                    state.entrySPIsExact = stackOffsets[sp] != nil
                }
                for capture in captures[source.address] ?? [] {
                    selectorValues[capture.0] = Self.value(for: capture.1, state: state)
                }
                if refusedRow || ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"].contains(source.mnemonic) {
                    emitted += Self.architecturalClobbers(source: source, observesQC: observesFPSR,
                        tracksFP: tracksFPEnvironment)
                } else if tracksFPEnvironment, Self.isLegacyFPStatusWriter(source) {
                    // This explicit unknown assignment corresponds to the opaque
                    // cell99 definition. Neither FPCR nor QC is clobbered here.
                    emitted += Self.architecturalClobbers(source: source, observesQC: false)
                        .filter { $0.fpArchitecturalClobber == .exceptions }
                }
                output[rowIndex] = emitted
            }
            outgoing[blockIndex] = state
            flagPhis.append(contentsOf: state.ssaFlagPhis)
            flagPhiComparisons.formUnion(state.ssaFlagPhiComparisons)
            compoundChains.append(contentsOf: state.ssaCompoundChains)
            for parameter in state.parameters {
                if let index = aggregate.parameters.firstIndex(where: { $0.id == parameter.id }) {
                    aggregate.parameters[index] = parameter
                } else { aggregate.parameters.append(parameter) }
            }
            aggregate.maxStackDepth = max(aggregate.maxStackDepth, state.maxStackDepth)
            aggregate.maxStackDisplacement = max(aggregate.maxStackDisplacement, state.maxStackDisplacement)
            aggregate.localVariablesByOffset.merge(state.localVariablesByOffset) { _, new in new }
            aggregate.registerNameBindingsByValue.merge(state.registerNameBindingsByValue) { _, new in new }
            for value in state.registerNameBindingOrder where !aggregate.registerNameBindingOrder.contains(value) {
                aggregate.registerNameBindingOrder.append(value)
            }
            for target in state.callTargets where !aggregate.callTargets.contains(target) { aggregate.callTargets.append(target) }
            aggregate.callSignaturesByTarget.merge(state.callSignaturesByTarget) { _, new in new }
            if let returnValue = state.returnValue {
                aggregate.returnValue = returnValue
            }
            if let returnType = state.returnType {
                aggregate.returnType = returnType
            }
        }
        func incomingValue(_ id: Int, destination: MacIRSSA.Definition) -> MacIRValue {
            let source = plan.definitions[plan.canonicalID(id)]
            let value = values[source.id] ?? .unknown("unbound_ssa")
            if source.bitWidth == 32 && destination.bitWidth == 64 && destination.cell < 32 {
                return .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: value))
            }
            if destination.view == .bits {
                if source.view == .float64 { return .unary(op: "__ssa_bitcast_u64", value: value) }
                if source.view == .float32 { return .unary(op: "__ssa_bitcast_u32", value: value) }
            }
            return value
        }
        let phis = plan.phis.map { phi -> MacIRPhi in
            let definition = plan.definitions[phi.destination]
            let view: MacIRPhi.ScalarView = definition.view == .float64 ? .binary64
                : definition.view == .float32 ? .binary32 : definition.view == .bits ? .bits64 : .integer
            return .init(blockAddress: graph.blocks[phi.block].startAddress,
                destination: values[phi.destination] ?? .unknown("unbound_ssa"), bitWidth: definition.bitWidth,
                incoming: phi.incoming.map { .init(predecessor: $0.publicPredecessor,
                    value: incomingValue($0.definition, destination: definition)) }, scalarView: view, cell: phi.cell)
        }
        guard pendingConditionalResults.isEmpty else { return nil }
        for (alias, target) in plan.aliases {
            let canonical = plan.canonicalID(target)
            values[alias] = values[canonical]
            plan.definitions[alias].bitWidth = plan.definitions[canonical].bitWidth
            plan.definitions[alias].view = plan.definitions[canonical].view
        }
        let instructions = output.flatMap { $0 }
        // Block-local states inherit their dominator's naming counter. Assign
        // function-wide temporary names only after the source-ordered rows exist,
        // so sibling blocks cannot reuse a name for different definitions.
        var temporarySourceRows: [MacIRValue: Int] = [:]
        for row in plan.rowWriteBindings.indices {
            for id in plan.rowWriteBindings[row].values {
                guard let value = values[id], temporarySourceRows[value] == nil else { continue }
                temporarySourceRows[value] = row
            }
        }
        let bindings = aggregate.recoveredNameBindings
        let temporaries = bindings.enumerated().filter { $0.element.kind == .registerTemporary }
            .sorted { left, right in
                func sourceRow(_ binding: MacIRNameBinding) -> Int {
                    guard case let .register(name, version) = binding.target else { return Int.max }
                    return temporarySourceRows[.register(name: name, version: version)] ?? Int.max
                }
                let lhs = sourceRow(left.element), rhs = sourceRow(right.element)
                return lhs == rhs ? left.offset < right.offset : lhs < rhs
            }
        let sourceOrderedBindings = bindings.filter { $0.kind != .registerTemporary }
            + temporaries.enumerated().map { index, item in
                var binding = item.element
                binding.name = "tmp\(index)"
                return binding
            }
        var result = MacIRFunction(name: name, startAddress: startAddress ?? sources.first?.address ?? 0,
            endAddress: endAddress ?? sources.last?.address.addressAfter(), returnType: aggregate.returnType ?? "int64_t",
            isVariadic: isVariadic, parameters: aggregate.parameters,
            localVariables: aggregate.recoveredLocalVariables, nameBindings: sourceOrderedBindings,
            stackFrameSize: aggregate.maxStackDepth, maxStackDisplacement: aggregate.maxStackDisplacement,
            callTargets: aggregate.callTargets, callSignatures: aggregate.recoveredCallSignatures,
            returnValue: aggregate.returnValue, instructions: instructions, phis: phis + flagPhis)
        result = Self.attachingStackStorage(to: LocalTypeInferencePass.infer(function: result), rows: rows)
        // Allocate predicate display names only after every formal/local/recovered
        // binding is known. Real bindings also reserve them for printer edge names.
        result.nameBindings.append(contentsOf: Self.ssaNZCVPredicateNameBindings(function: result,
            predicates: exactValuePhis.sorted { a, b in
                a.key.definition == b.key.definition ? a.key.condition < b.key.condition
                    : a.key.definition < b.key.definition
            }, additionalValues: Array(values.values)))
        result.cfg = graph.reindexed(instructions: result.instructions)
        plan.refusals = refusals
        result.refusals = refusals
        result.ssaEnabled = true
        result.observesFPSR = observesFPSR
        result.ssaInfo = MacIRSSAInfo(plan: plan, values: values, sourceAddresses: sources.map(\.address), stackOffsets: stackOffsets)
        result.ssaInfo?.generatedNZCVPredicateTargets = Set(exactValuePhis.values.map(\.destination))
        result.ssaOriginalInstructions = result.instructions
        result.ssaOriginalPhis = result.phis
        result.ssaFlagPhiComparisons = flagPhiComparisons
        result.ssaElidedChainRows = Self.ssaElidedChainRows(
            chains: compoundChains, plan: plan, sources: sources, output: output, flagPhiComparisons: flagPhiComparisons)
        if boundedEntry, let info = result.ssaInfo {
            guard result.instructions.count <= 64, result.phis.count <= 30,
                  info.plan.definitions.count <= 256, info.values.count <= 256 else { return nil }
            let certificate = BoundedEntryLoopCertificate(function: result, info: info)
            result.ssaInfo?.boundedEntryCertificate = certificate
            guard Self.hasBoundedEntryLoopProof(result) else { return nil }
        }
        // This is the publication point. No partially constructed metadata escapes.
        ssaBeforeFinalization?()
        return ssaIsCancelled ? cancelledResult() : result
    }

    static func cancelledSSAFunction(name: String, startAddress: UInt64?,
                                     sources: [MacIRSourceSpan], parameters: [MacIRFunctionParameter] = []) -> MacIRFunction {
        let instructions = sources.map { source -> MacIRInstruction in
            let reads = unknownInstructionReadSets(mnemonic: source.mnemonic, operands: splitOperands(source.operands))
            let bind = { (register: String) in MacIRUnknownRead(register: register, value: .unknown("cancelled_\(register)")) }
            let inputs = MacIRUnknownInputs(mayRead: reads.mayRead.map(bind), definiteRead: reads.definiteRead.map(bind),
                mayReadNZCV: reads.mayReadNZCV, definitelyReadsNZCV: reads.definitelyReadsNZCV)
            return .init(source: source, operation: .unknown(destination: nil, inputs: inputs,
                mnemonic: source.mnemonic, operands: source.operands))
        }
        var function = MacIRFunction(name: name, startAddress: startAddress ?? sources.first?.address ?? 0,
            parameters: parameters, instructions: instructions)
        function.refusals = [.init(reason: .cancelled, scope: .function, detail: nil)]
        function.ssaEnabled = true
        return function
    }
}

extension MacIRBuilder {
    /// A28: a cmp;ccmp chain is elided only when every reader of the NZCV values
    /// it defines rendered a lifted condition. Decided per chain on the SSA
    /// definitions of cell 96; any unlifted reader keeps both statements.
    static func ssaElidedChainRows(
        chains: [CompoundChain],
        plan: MacIRSSA.Plan,
        sources: [MacIRSourceSpan],
        output: [[MacIRInstruction]],
        flagPhiComparisons: Set<UInt64>
    ) -> Set<UInt64> {
        guard !chains.isEmpty else { return [] }
        let rowByAddress = Dictionary(sources.enumerated().map { ($0.element.address, $0.offset) },
                                      uniquingKeysWith: min)
        func lifted(_ row: Int) -> Bool {
            let operations = output[row].map(\.operation)
            guard !operations.isEmpty else { return false }
            return operations.allSatisfy { operation in
                switch operation {
                case .conditionalBranch, .select, .compareToBool: return true
                default: return false
                }
            }
        }
        var consumed: [CompoundChain: Bool] = [:]
        for chain in Set(chains) {
            consumed[chain] = true
        }
        // Every compound that consumed a given row must belong to a fully lifted chain.
        var rowVerdict: [UInt64: Bool] = [:]
        for chain in consumed.keys {
            guard let compareRow = rowByAddress[chain.compare],
                  let ccmpRow = rowByAddress[chain.conditionalCompare],
                  let compareDef = plan.rowWriteBindings[compareRow][96].map(plan.canonicalID),
                  let ccmpDef = plan.rowWriteBindings[ccmpRow][96].map(plan.canonicalID) else {
                rowVerdict[chain.compare] = false
                rowVerdict[chain.conditionalCompare] = false
                continue
            }
            var ok = true
            for row in sources.indices {
                guard let read = plan.rowReadBindings[row][96].map(plan.canonicalID) else { continue }
                if read == compareDef, row != ccmpRow, !lifted(row) { ok = false }
                if read == ccmpDef, !lifted(row) { ok = false }
            }
            for phi in plan.phis where phi.cell == 96 {
                for edge in phi.incoming {
                    let definition = plan.canonicalID(edge.definition)
                    if definition == ccmpDef { ok = false }
                    if definition == compareDef, !flagPhiComparisons.contains(chain.compare) { ok = false }
                }
            }
            rowVerdict[chain.compare] = (rowVerdict[chain.compare] ?? true) && ok
            rowVerdict[chain.conditionalCompare] = (rowVerdict[chain.conditionalCompare] ?? true) && ok
        }
        return Set(rowVerdict.filter(\.value).keys)
    }
}
