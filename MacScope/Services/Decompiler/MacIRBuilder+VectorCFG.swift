import Foundation

extension MacIRBuilder {
    /// Reserve control-bearing post-index Q functions before the older
    /// whole-function vector gates can erase their branch and return rows.
    static func attemptsVectorControlRegion<Row: DecompilerInstructionRow>(_ rows: [Row]) -> Bool {
        let hasControl = rows.contains { row in
            let mnemonic = row.mnemonic.lowercased()
            return mnemonic == "cbz" || mnemonic == "cbnz" || mnemonic == "b.ne"
        }
        return hasControl && rows.contains { row in
            let mnemonic = row.mnemonic.lowercased()
            guard mnemonic == "ldr" || mnemonic == "str" else { return false }
            return encodedNEONBufferSequence(row) ||
                (row.operands.contains("q") && row.operands.contains("],"))
        }
    }

    /// A complete block is the commit unit. The admitted path stages all
    /// mutable data/effect state, including the memory sequence and arithmetic
    /// rewrite cursor. A rejected block contributes only unknown data effects
    /// while its original terminator is still lifted.
    func buildVectorControlRegion<Row: DecompilerInstructionRow>(
        name: String, startAddress: UInt64?, rows: [Row],
        initialState: BuilderState, hasExternalFacts: Bool
    ) -> MacIRFunction? {
        // Without its exact plan this lifter would refuse every row, branches
        // included; the general region or ordinary builder handles it instead.
        guard let plan = ScalarCFGStatePlan.admit(rows, hasExternalFacts: hasExternalFacts,
                                                   allowVectorLoop: true) else { return nil }
        var state = initialState
        state.permitsNEONBufferCarrier = true
        let entry = state
        var outgoing: [Int: BuilderState] = [:]
        var drafts: [ScalarCFGStatePlan.PhiDraft] = []
        var memorySequence = 0
        var arithmeticRewrite = MacIRArithmeticRewrite()
        var instructions: [MacIRInstruction] = []

        do {
            for block in plan.cfg.blocks {
                state = plan.incoming(for: block.index, entry: entry,
                                      outgoing: outgoing, phis: &drafts)
                state.permitsNEONBufferCarrier = true
                var stagedState = state
                var stagedMemorySequence = memorySequence
                var stagedRewrite = arithmeticRewrite
                var stagedEffects: [MacIRInstruction] = []
                var complete = true
                for rowIndex in block.instructionRange {
                    let row = rows[rowIndex]
                    let source = Self.vectorRegionSource(row)
                    switch source.mnemonic {
                    case "ldr", "str":
                        guard let parsed = Self.neonBufferSequence(row),
                              parsed.mode == .postIndex, parsed.delta == 16,
                              parsed.vectors.count == 1 else { complete = false; break }
                        let effects = Self.liftNEONBufferSequence(parsed, source: source,
                            firstMemorySequence: stagedMemorySequence, state: &stagedState)
                        guard effects.count == 2,
                              effects[0].neonBufferSequence?.ordinal == 0,
                              effects[1].neonBufferSequence?.ordinal == 1,
                              effects[0].neonBufferMemory != nil else {
                            complete = false; break
                        }
                        stagedMemorySequence += 1
                        stagedEffects.append(contentsOf: effects)
                    case "eor":
                        guard let logical = Self.neonLogical(mnemonic: source.mnemonic,
                                                              operandText: source.operands),
                              logical.kind == .eor, logical.width == .bytes16 else {
                            complete = false; break
                        }
                        let operands = Self.splitOperands(source.operands)
                        let operation = Self.liftNEONLogical(logical, operands: operands,
                                                              state: &stagedState)
                        stagedEffects.append(MacIRInstruction(source: source,
                            operation: operation, neonLogical: logical))
                    case "cbz", "cbnz", "b.ne", "b", "subs", "add", "mov", "nop", "ret":
                        let lifted = self.operationForVectorRegion(for: source, state: &stagedState)
                        let operands = Self.splitOperands(source.operands)
                        let operation = stagedRewrite.rewrite(lifted, mnemonic: source.mnemonic,
                            width: operands.first.flatMap(Self.scalarDataBitWidth),
                            operandWidths: operands.dropFirst().map(Self.scalarDataBitWidth),
                            address: source.address, allowSequence: false)
                        stagedEffects.append(MacIRInstruction(source: source,
                                                               operation: operation))
                    default:
                        complete = false
                    }
                    if !complete { break }
                }
                if complete {
                    state = stagedState
                    memorySequence = stagedMemorySequence
                    arithmeticRewrite = stagedRewrite
                    instructions.append(contentsOf: stagedEffects)
                } else {
                    // No speculative definitions, captures, transfer indices,
                    // or rewrite state survive a block-level refusal.
                    for rowIndex in block.instructionRange {
                        instructions.append(Self.vectorRegionRefusal(rows[rowIndex], state: &state))
                    }
                }
                outgoing[block.index] = state
            }
        }

        let phis = plan.resolvedPhis(drafts, rows: rows, outgoing: outgoing,
                                     instructions: instructions)
        return LocalTypeInferencePass.infer(function: MacIRFunction(
            name: name, startAddress: startAddress ?? rows.first?.address ?? 0,
            endAddress: rows.last.flatMap { $0.address.addressAfter() },
            returnType: state.returnType ?? "int64_t", parameters: state.parameters,
            localVariables: state.recoveredLocalVariables,
            nameBindings: state.recoveredNameBindings,
            stackFrameSize: state.maxStackDepth,
            maxStackDisplacement: state.maxStackDisplacement, callTargets: state.callTargets,
            callSignatures: state.recoveredCallSignatures,
            returnValue: state.returnValue, instructions: instructions, phis: phis))
    }

    private static func vectorRegionSource<Row: DecompilerInstructionRow>(_ row: Row) -> MacIRSourceSpan {
        MacIRSourceSpan(address: row.address, byteText: row.bytes,
                        mnemonic: row.mnemonic.lowercased(), operands: row.operands,
                        comment: row.comment, structuredOperands: row.structuredOperands)
    }

    private static func vectorRegionRefusal<Row: DecompilerInstructionRow>(
        _ row: Row, state: inout BuilderState
    ) -> MacIRInstruction {
        let source = vectorRegionSource(row)
        if ["cbz", "cbnz", "b.ne", "b"].contains(source.mnemonic) {
            let operands = splitOperands(source.operands)
            let targetText = operands.last ?? ""
            let rawTarget = targetText.hasPrefix("0x")
                ? UInt64(targetText.dropFirst(2), radix: 16) : UInt64(targetText)
            let target: MacIRValue = rawTarget.flatMap { $0 <= UInt64(Int64.max) ?
                .immediate(Int64($0)) : nil } ?? .unknown("unresolved_branch_target")
            let operation: MacIROperation
            switch source.mnemonic {
            case "cbz", "cbnz":
                let register = operands.first ?? ""
                operation = .conditionalBranch(
                    condition: source.mnemonic == "cbz" ? "==" : "!=",
                    left: state.readRegister(register), right: .immediate(0), target: target)
            case "b.ne":
                operation = .conditionalBranch(condition: "!=",
                    left: .unknown("unavailable_nzcv"), right: .immediate(0), target: target)
            default:
                operation = .intrinsic(destination: nil, name: "branch", arguments: [target])
            }
            return MacIRInstruction(source: source, operation: operation)
        }
        if source.mnemonic == "ret" {
            let operation = MacIROperation.returnValue(state.preferredReturnValue())
            state.returnValue = state.preferredReturnValue()
            return MacIRInstruction(source: source, operation: operation)
        }
        let operands = splitOperands(source.operands)
        let sets = unknownInstructionReadSets(mnemonic: source.mnemonic, operands: operands)
        let inputs = MacIRUnknownInputs(
            mayRead: sets.mayRead.map { MacIRUnknownRead(register: $0, value: state.readRegister($0)) },
            definiteRead: sets.definiteRead.map { MacIRUnknownRead(register: $0, value: state.readRegister($0)) },
            mayReadNZCV: sets.mayReadNZCV,
            definitelyReadsNZCV: sets.definitelyReadsNZCV)
        state.lastComparison = nil
        state.lastAdjacentComparison = nil
        state.pendingConditionalCompare = nil
        let first = operands.first?.split(separator: ".", maxSplits: 1).first.map(String.init)
        if let first, first.first == "x" || first.first == "w" {
            state.recordUnmodeledDefiniteWrite(for: first)
        } else if let first, first.first == "q" || first.first == "v" {
            let canonical = state.neonBufferCarrier(first)
            state.callUnavailableRegisterValues.insert(canonical)
            state.recordUnmodeledDefiniteWrite(for: canonical)
        }
        // Post-index candidates may also write the base. A rejected transfer
        // must not leave an earlier loop-iteration address available.
        if let open = source.operands.firstIndex(of: "["),
           let close = source.operands[open...].firstIndex(of: "]") {
            let base = String(source.operands[source.operands.index(after: open)..<close])
                .split(separator: ",", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if base.first == "x" { state.recordUnmodeledDefiniteWrite(for: base) }
        }
        return MacIRInstruction(source: source,
            operation: .unknown(destination: nil, inputs: inputs,
                                mnemonic: source.mnemonic, operands: source.operands))
    }
}

extension MacIRBuilder {
    /// A control-bearing vector transfer is assembled from independently
    /// decoded effects. This filter does not recognize a function body or a
    /// particular library: it only reserves mixed CFG/vector functions before
    /// the older whole-function vector routes claim them.
    static func attemptsGeneralVectorRegion<Row: DecompilerInstructionRow>(_ rows: [Row]) -> Bool {
        guard rows.contains(where: { $0.mnemonic.lowercased().hasPrefix("b.") ||
            ["cbz", "cbnz", "tbz", "tbnz", "br"].contains($0.mnemonic.lowercased()) }) else {
            return isBranchFreeVectorLeaf(rows)
        }
        if rows.contains(where: { encodedNEONIndexedMemory($0) })
            && rows.contains(where: { encodedNEONInterleavedMemory($0) }) { return true }
        // Post-index Q buffer loops keep the dedicated control-region lifter
        // only when its exact plan admits them.
        let controlRegionAdmits = attemptsVectorControlRegion(rows)
            && ScalarCFGStatePlan.admit(rows, hasExternalFacts: false, allowVectorLoop: true) != nil
        return !controlRegionAdmits && rows.contains(where: admitsGeneralVectorRow)
    }

    /// A branch-free leaf the region path may claim: RET only at the end, at
    /// least one admitted vector row, and every other row plain scalar memory
    /// or a move. Any scalar arithmetic, call, PC-relative or unsupported row
    /// keeps the function with the ordinary builder (its sequence rewrites and
    /// select lowering), as do purely scalar leaves.
    static func isBranchFreeVectorLeaf<Row: DecompilerInstructionRow>(_ rows: [Row]) -> Bool {
        // A trailing RET is optional: a branch-free fragment (for example a
        // single decoded row) has no control rows at all.
        let body = rows.last?.mnemonic.lowercased() == "ret" ? Array(rows.dropLast()) : rows
        guard !body.isEmpty else { return false }
        // Memory, moves and PC-relative address formation; no arithmetic.
        let scalarMemoryOrMove: Set<String> = ["ldr", "ldur", "str", "stur", "ldp", "stp",
                                               "ldrb", "ldrh", "strb", "strh", "ldurb", "ldurh",
                                               "sturb", "sturh", "ldrsw", "ldursw", "mov", "adrp", "adr",
                                               "mrs"]
        // Exact integer scalar-view writes may feed a bitwise FMOV consumer.
        // Neither contract admits general scalar-FP arithmetic.
        let hasScalarIntegerView = body.contains {
            scalarDupElementOperation(mnemonic: $0.mnemonic, operandText: $0.operands) != nil
                || scalarADDVCarrier($0) != nil
        }
        var sawVector = false
        // X registers holding an unmodified ADRP page: the only base an `add`
        // may use here, and only as the :lo12 half of the address pair.
        var adrpPages: Set<String> = []
        for row in body {
            if admitsGeneralVectorRow(row) { sawVector = true; continue }
            // An unsupported vector row is unknown on either path; the region
            // refuses it per row with full poisoning.
            if hasUnclaimedVectorOperand(row.operands) { continue }
            let mnemonic = row.mnemonic.lowercased()
            let operands = splitOperands(row.operands).map { $0.lowercased() }
            if mnemonic == "add", operands.count == 3, adrpPages.contains(operands[1]),
               operands[0].hasPrefix("x"), operands[2].hasPrefix("#"),
               let offset = parseImmediate(operands[2]), (0..<4096).contains(offset) {
                adrpPages.remove(operands[0])
                continue
            }
            let scalarDupMove = hasScalarIntegerView && mnemonic == "fmov" && isScalarDupLeafMove(operands)
            guard scalarMemoryOrMove.contains(mnemonic) || scalarDupMove else { return false }
            // Any other write to a tracked register ends its page provenance.
            if let destination = operands.first {
                adrpPages.remove(destination)
                if destination.hasPrefix("w") { adrpPages.remove("x" + destination.dropFirst()) }
            }
            if mnemonic == "adrp", let destination = operands.first, destination.hasPrefix("x") {
                adrpPages.insert(destination)
            }
        }
        return sawVector
    }

    /// Canonical same-width FMOV consumers already handled by the region.
    /// Exclude immediates, lanes, invalid register numbers and other scalar views.
    private static func isScalarDupLeafMove(_ operands: [String]) -> Bool {
        guard operands.count == 2,
              let first = operands[0].first, let second = operands[1].first,
              ["ws", "sw", "ss", "xd", "dx", "dd"].contains(String([first, second])) else { return false }
        return operands.allSatisfy { operand in
            guard let prefix = operand.first else { return false }
            return bitViewRegister(operand, prefixes: "wsxd", maximum: "wx".contains(prefix) ? 30 : 31) != nil
        }
    }

    /// One row the region transaction can lift with typed vector semantics.
    /// Admission is per row; the region plan decides whether the function's
    /// control flow is usable at all.
    static func admitsGeneralVectorRow<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        let mnemonic = row.mnemonic.lowercased()
        let permutation = ssaVectorPermutation(generalVectorSource(row))
        return permutation?.dot != nil || permutation?.reduction != nil
            || scalarADDVCarrier(row) != nil
            || neonWideningPairwise(generalVectorSource(row)) != nil
            || MacIRVectorFP(source: generalVectorSource(row)) != nil
            || encodedNEONIndexedMemory(row) || encodedNEONInterleavedMemory(row)
            || encodedNEONStructureLaneMemory(row)
            || neonCopy(mnemonic: mnemonic, operandText: row.operands) != nil
            || neonLaneOperation(mnemonic: mnemonic, operandText: row.operands) != nil
            || neonMoveImmediate(mnemonic: mnemonic, operandText: row.operands) != nil
            || neonBitClearImmediate(mnemonic: mnemonic, operandText: row.operands) != nil
            || neonPlainQMemory(mnemonic: mnemonic, operandText: row.operands) != nil
            || neonQWriteback(mnemonic: mnemonic, operandText: row.operands) != nil
            || isSPBasedQMemory(mnemonic: mnemonic, operandText: row.operands)
            || neonLogical(mnemonic: mnemonic, operandText: row.operands) != nil
    }

    func buildGeneralVectorRegion<Row: DecompilerInstructionRow>(
        name: String, startAddress: UInt64?, rows: [Row],
        initialState: BuilderState, jumpTables: [UInt64: [UInt64]] = [:],
        hasExternalFacts: Bool, isVariadic: Bool
    ) -> MacIRFunction? {
        // Without an admitted plan the ordinary builder keeps its scalar
        // lifting; the region path never makes a function worse wholesale.
        guard let switches = Self.generalVectorSwitches(rows, jumpTables: jumpTables),
              let plan = Self.generalVectorPlan(rows, hasExternalFacts: hasExternalFacts,
                                                switches: switches) else { return nil }
        let observesFPSR = rows.contains {
            $0.mnemonic.lowercased() == "mrs" && $0.operands.lowercased().contains("fpsr")
        }
        let tracksFP = rows.contains {
            MacIRFPBlockedEffect.requiresEnvironment(mnemonic: $0.mnemonic, operands: $0.operands)
                || MacIRFPBlockedEffect.isStatusAccess(source: Self.generalVectorSource($0))
        }
        var capturedSelectors: [UInt64: MacIRValue] = [:]
        var state = initialState
        state.permitsNEONBufferCarrier = true
        state.permitsNEONScalarViewCarrier = true
        let entry = state
        var outgoing: [Int: BuilderState] = [:]
        var drafts: [ScalarCFGStatePlan.PhiDraft] = []
        var memorySequence = 0
        var structureLaneSequence = 0
        var arithmeticRewrite = MacIRArithmeticRewrite()
        var instructions: [MacIRInstruction] = []

        do {
            for block in plan.cfg.blocks {
                state = plan.incoming(for: block.index, entry: entry,
                                      outgoing: outgoing, phis: &drafts)
                state.permitsNEONBufferCarrier = true
                state.permitsNEONScalarViewCarrier = true
                var staged = state
                var stagedSequence = memorySequence
                var stagedStructureLaneSequence = structureLaneSequence
                var stagedRewrite = arithmeticRewrite
                var effects: [MacIRInstruction] = []
                for index in block.instructionRange {
                    let row = rows[index]
                    let source = Self.generalVectorSource(row)
                    let stateEffectStart = effects.count
                    defer {
                        // A call or refused writer cannot preserve sticky facts
                        // in the architectural in-place status representation.
                        let barrier = effects.dropFirst(stateEffectStart).contains { instruction in
                            switch instruction.operation {
                            case .call, .unknown: return true
                            default: return false
                            }
                        }
                        if barrier {
                            effects.append(contentsOf: Self.architecturalClobbers(source: source,
                                observesQC: observesFPSR, tracksFP: tracksFP))
                        }
                    }
                    // Capture at the proven definition, not the BR register (which
                    // commonly overwrites the index). Admission proves dominance.
                    defer {
                        for (dispatch, site) in switches where site.selector.definitionAddress == row.address {
                            capturedSelectors[dispatch] = staged.readRegister(site.selector.register)
                        }
                    }
                    if let site = switches[row.address] {
                        effects.append(.init(source: source, operation: site.operation(
                            index: capturedSelectors[row.address] ?? .unknown("unavailable_switch_selector"))))
                        continue
                    }
                    // Each row is its own transaction: a refused row restores
                    // the state before it and becomes an unknown that poisons
                    // everything it could have written (registers, NZCV,
                    // writeback base, memory facts), as in the ordinary builder.
                    let rowStart = (state: staged, sequence: stagedSequence,
                                    structureLaneSequence: stagedStructureLaneSequence,
                                    rewrite: stagedRewrite, effects: effects.count)
                    var complete = true
                    if let permutation = Self.ssaVectorPermutation(source),
                       permutation.dot != nil || permutation.reduction != nil {
                        // The shared byte/text gate selects existing descriptors;
                        // snapshot every input before an overlapping destination.
                        var arguments = permutation.sources.map { staged.readRegister($0) }
                        if permutation.readsDestination { arguments.append(staged.readRegister(permutation.destination)) }
                        let destination = staged.writeRegister(permutation.destination)
                        effects.append(.init(source: source,
                            operation: .intrinsic(destination: destination,
                                name: permutation.intrinsicName, arguments: arguments),
                            neonReduction: permutation.reduction, neonByteDotProduct: permutation.dot))
                        continue
                    }
                    if let reduction = Self.scalarADDVCarrier(row) {
                        // Snapshot the input before an aliased full-V write. The
                        // existing reduction contract truncates the modular sum
                        // to the scalar width and clears all remaining V bits.
                        let input = staged.readRegister(reduction.source)
                        let destination = staged.writeRegister(reduction.destination)
                        effects.append(.init(source: source,
                            operation: .intrinsic(destination: destination,
                                name: "integer_horizontal_output", arguments: [input]),
                            neonReduction: reduction.semantics))
                        continue
                    }
                    if let fp = MacIRVectorFP(source: source) {
                        // Architectural in-place state: these are runtime inputs,
                        // never inferred constants or lexical CFG versions. The
                        // typed operation explicitly assumes normal completion.
                        let status = MacIRValue.register(name: "fpsr_exception_bits", version: 0)
                        effects.append(contentsOf: Self.liftVectorFP(fp, source: source,
                            state: &staged, fpcr: .unknown("architectural_fpcr"),
                            exceptions: status, exceptionOutput: status,
                            executionContext: .unknown("fp_access_features_sme")))
                        continue
                    }
                    // A malformed or unimplemented form cannot take a numeric-only
                    // route. Unknown controls alone never refuse a parsed FP row.
                    if MacIRFPBlockedEffect.requiresEnvironment(mnemonic: source.mnemonic, operands: source.operands)
                        || MacIRFPBlockedEffect.isStatusAccess(source: source) {
                        effects.append(generalVectorRefusal(row, state: &staged))
                        continue
                    }
                    if let copy = Self.neonCopy(mnemonic: source.mnemonic, operandText: source.operands) {
                        effects.append(Self.liftNEONCopy(copy, source: source, state: &staged))
                        continue
                    }
                    if let lane = Self.neonLaneOperation(mnemonic: source.mnemonic, operandText: source.operands) {
                        let operation = Self.liftNEONLane(lane, state: &staged)
                        var numeric = MacIRInstruction(source: source, operation: operation,
                                                       neonLaneOp: lane.semantics)
                        if lane.semantics.setsQC, observesFPSR, case let .intrinsic(_, _, arguments) = operation {
                            // Outside SSA this denotes one architectural in-place
                            // cell, not a fabricated lexical version across CFG joins.
                            numeric.neonQCIsSeparate = true
                            effects.append(numeric)
                            let qc = MacIRValue.register(name: "qc", version: 0)
                            effects.append(MacIRNEONQCEffect(lane: lane.semantics,
                                arguments: arguments, input: qc, output: qc).instruction(source: source))
                        } else { effects.append(numeric) }
                        continue
                    }
                    if source.mnemonic == "fmov", let width = Self.scalarViewMoveWidth(source.operands) {
                        // A B/H/S/D view move reads the low bits and zero-extends
                        // through the shared vN carrier; never a full-vector copy.
                        let operands = Self.splitOperands(source.operands)
                        if width == 0 { complete = false } else {
                            let value = staged.readRegister(operands[1])
                            let destination = staged.writeRegister(operands[0])
                            effects.append(.init(source: source, operation: .assign(destination: destination,
                                source: .unary(op: "(uint\(width)_t)", value: value))))
                        }
                        if !complete {
                            staged = rowStart.state
                            stagedSequence = rowStart.sequence
                            stagedStructureLaneSequence = rowStart.structureLaneSequence
                            stagedRewrite = rowStart.rewrite
                            effects.removeSubrange(rowStart.effects...)
                            effects.append(generalVectorRefusal(row, state: &staged))
                        }
                        continue
                    }
                    if let widening = Self.neonWideningPairwise(source) {
                        effects.append(Self.liftNEONWideningPairwise(widening, source: source, state: &staged))
                        continue
                    }
                    if let immediate = Self.neonBitClearImmediate(mnemonic: source.mnemonic, operandText: source.operands) {
                        effects.append(contentsOf: Self.liftNEONBitClearImmediate(immediate, source: source, state: &staged))
                        continue
                    }
                    if let constant = Self.neonMoveImmediate(mnemonic: source.mnemonic, operandText: source.operands) {
                        let destination = staged.writeRegister(constant.destination)
                        effects.append(.init(source: source, operation: .intrinsic(destination: destination,
                            name: "neon_integer_constant", arguments: []), neonImmediate: constant.semantics))
                        continue
                    }
                    if !Self.encodedNEONIndexedMemory(row),
                       let narrow = Self.neonPlainNarrowScalarStore(mnemonic: source.mnemonic,
                                                                   operandText: source.operands) {
                        let memory = narrow.memory
                        // Partial writes through a stack alias invalidate cached slots too.
                        staged.invalidateStackMemoryIfProvenAlias(memory.base)
                        let base = staged.readRegister(memory.base)
                        let address: MacIRValue = memory.offset == 0 ? base
                            : memory.offset > 0 ? .binaryExpression(op: "+", left: base, right: .immediate(memory.offset))
                            : .binaryExpression(op: "-", left: base, right: .immediate(-memory.offset))
                        effects.append(.init(source: source,
                            operation: .store(source: staged.readRegister(memory.vector), address: address),
                            memoryAccess: .init(byteWidth: narrow.byteWidth)))
                        continue
                    }
                    if let moving = Self.neonQWriteback(mnemonic: source.mnemonic, operandText: source.operands) {
                        // A Q store through a proven stack alias may overwrite cached slots.
                        if !moving.isLoad, staged.knownStackBaseOffset(for: moving.base) != nil {
                            staged.invalidateAllStackSlotValues()
                        }
                        let baseSource = staged.readRegister(moving.base)
                        let operation: MacIROperation = moving.isLoad
                            ? .loadWriteback(destination: staged.writeRegister(moving.vector),
                                             baseDestination: staged.writeRegister(moving.base),
                                             baseSource: baseSource, delta: moving.offset,
                                             preIndex: moving.writeback == .pre)
                            : .storeWriteback(source: staged.readRegister(moving.vector),
                                              baseDestination: staged.writeRegister(moving.base),
                                              baseSource: baseSource, delta: moving.offset,
                                              preIndex: moving.writeback == .pre)
                        effects.append(.init(source: source, operation: operation, memoryAccess: .init(byteWidth: 16)))
                        continue
                    }
                    if !Self.encodedNEONIndexedMemory(row),
                       let plain = Self.neonPlainQMemory(mnemonic: source.mnemonic, operandText: source.operands) {
                        // A Q store through a proven stack alias may overwrite cached slots.
                        if !plain.isLoad, staged.knownStackBaseOffset(for: plain.base) != nil {
                            staged.invalidateAllStackSlotValues()
                        }
                        let base = staged.readRegister(plain.base)
                        let address: MacIRValue = plain.offset == 0 ? base
                            : plain.offset > 0 ? .binaryExpression(op: "+", left: base, right: .immediate(plain.offset))
                            : .binaryExpression(op: "-", left: base, right: .immediate(-plain.offset))
                        let operation: MacIROperation
                        if let pair = plain.pair {
                            // Same pair representation as scalar LDP/STP; the
                            // 16-byte access types both elements.
                            operation = plain.isLoad
                                ? .intrinsic(destination: nil, name: "restore_pair", arguments: [
                                    staged.writeRegister(plain.vector), staged.writeRegister(pair), address])
                                : .intrinsic(destination: nil, name: "save_pair", arguments: [
                                    staged.readRegister(plain.vector), staged.readRegister(pair), address])
                        } else {
                            operation = plain.isLoad
                                ? .load(destination: staged.writeRegister(plain.vector), address: address)
                                : .store(source: staged.readRegister(plain.vector), address: address)
                        }
                        effects.append(.init(source: source, operation: operation, memoryAccess: .init(byteWidth: 16)))
                        continue
                    }
                    switch source.mnemonic {
                    case let mnemonic where ["ldr", "str"].contains(mnemonic)
                        && Self.encodedNEONIndexedMemory(row)
                        && !Self.isSPBasedQMemory(mnemonic: mnemonic, operandText: source.operands):
                        guard let parsed = Self.neonIndexedMemory(row),
                              let descriptor = MacIRNEONIndexedMemory(
                                effect: parsed.effect, baseRegister: parsed.base,
                                indexRegister: parsed.index,
                                base: staged.readRegister(parsed.base),
                                index: staged.readRegister(parsed.index),
                                indexExtension: parsed.extensionKind,
                                shift: parsed.shift, sequence: stagedSequence) else {
                            complete = false; break
                        }
                        let vector = staged.readRegister(parsed.vector)
                        let operation: MacIROperation = parsed.effect == .load
                            ? .load(destination: staged.writeRegister(parsed.vector),
                                    address: descriptor.address)
                            : .store(source: vector, address: descriptor.address)
                        effects.append(.init(source: source, operation: operation,
                            memoryAccess: .init(byteWidth: 16), neonIndexedMemory: descriptor))
                        stagedSequence += 16
                    case "ld1", "ld2", "ld3", "ld4", "st1", "st2", "st3", "st4":
                        if Self.encodedNEONStructureLaneMemory(row) {
                            guard let parsed = Self.neonStructureLaneMemory(row),
                                  stagedSequence <= Int.max - parsed.elementBytes * parsed.structureCount else {
                                complete = false; break
                            }
                            if parsed.effect == .store {
                                staged.invalidateStackMemoryIfProvenAlias(parsed.base)
                            }
                            let oldBase = staged.readRegister(parsed.base)
                            let oldVectors = parsed.vectors.map { staged.readRegister($0) }
                            let registerPost = parsed.incrementRegister.flatMap { name in
                                MacIRNEONContiguousRegisterPost(
                                    incrementRegister: name, oldIncrement: staged.readRegister(name))
                            }
                            guard parsed.incrementRegister == nil || registerPost != nil else {
                                complete = false; break
                            }
                            let destinations = parsed.effect == .load
                                ? parsed.vectors.map { staged.writeRegister($0) } : []
                            let baseDestination = parsed.postIndex
                                ? staged.writeRegister(parsed.base) : nil
                            guard let frame = MacIRNEONStructureLaneMemory(
                                effect: parsed.effect, elementBytes: parsed.elementBytes,
                                laneIndex: parsed.laneIndex, structureCount: parsed.structureCount,
                                baseRegister: parsed.base, oldBase: oldBase,
                                oldVectors: oldVectors, destinations: destinations,
                                baseDestination: baseDestination,
                                frameSequence: stagedStructureLaneSequence,
                                firstByteSequence: stagedSequence, registerPost: registerPost) else {
                                complete = false; break
                            }
                            for ordinal in 0..<frame.effectCount {
                                effects.append(.init(source: source, operation: frame.operation(ordinal),
                                    neonStructureLaneMemory: .init(frame: frame, ordinal: ordinal)))
                            }
                            stagedSequence += frame.byteCount
                            stagedStructureLaneSequence += 1
                            break
                        }
                        guard let parsed = Self.neonInterleavedMemory(row),
                              stagedSequence <= Int.max - parsed.activeBytes * parsed.vectors.count else {
                            complete = false; break
                        }
                        if parsed.effect == .store {
                            staged.invalidateStackMemoryIfProvenAlias(parsed.base)
                        }
                        let oldBase = staged.readRegister(parsed.base)
                        let registerPost = parsed.incrementRegister.flatMap { name in
                            MacIRNEONContiguousRegisterPost(
                                incrementRegister: name, oldIncrement: staged.readRegister(name))
                        }
                        guard parsed.incrementRegister == nil || registerPost != nil else {
                            complete = false; break
                        }
                        let vectors = parsed.effect == .store
                            ? parsed.vectors.map { staged.readRegister($0) }
                            : parsed.vectors.map { staged.writeRegister($0) }
                        let baseDestination = parsed.postIndex
                            ? staged.writeRegister(parsed.base) : nil
                        guard let frame = MacIRNEONInterleavedMemory(
                            effect: parsed.effect, activeBytes: parsed.activeBytes,
                            baseRegister: parsed.base, oldBase: oldBase,
                            vectors: vectors, baseDestination: baseDestination,
                            firstByteSequence: stagedSequence,
                            structureCount: parsed.structureCount,
                            elementBytes: parsed.elementBytes,
                            registerPost: registerPost) else {
                            complete = false; break
                        }
                        for ordinal in 0..<frame.effectCount {
                            effects.append(.init(source: source,
                                operation: frame.operation(ordinal),
                                neonInterleavedMemory: .init(frame: frame, ordinal: ordinal)))
                        }
                        stagedSequence += frame.byteCount
                    case "orr", "eor", "and", "bic", "orn", "eon":
                        guard let logical = Self.neonLogical(
                            mnemonic: source.mnemonic, operandText: source.operands) else {
                            complete = false; break
                        }
                        effects.append(.init(source: source,
                            operation: Self.liftNEONLogical(logical,
                                operands: Self.splitOperands(source.operands), state: &staged),
                            neonLogical: logical))
                    case let mnemonic where ["ldr", "str"].contains(mnemonic)
                        && source.operands.hasPrefix("q")
                        && !Self.isSPBasedQMemory(mnemonic: mnemonic, operandText: source.operands):
                        complete = false
                    default:
                        // Scalar addressing, flags and branches use the normal
                        // instruction semantics. A failed row is refused alone;
                        // none of its partial writes or memory ordinals commit.
                        var operation = Self.explicitComparisonTypes(
                            operationForVectorRegion(for: source, state: &staged),
                            source: source, argumentBitWidths: staged.argumentBitWidths,
                            parameters: staged.parameters)
                        if Self.isGeneralVectorIndirectCall(source.mnemonic) {
                            // A returning control row must emit a call, never a
                            // refused data row that accidentally falls through.
                            guard case .call = operation else { return nil }
                        }
                        if case .unknown = operation { complete = false; break }
                        if case let .call(frame, result) = operation {
                            staged.invalidateGeneralVectorRegionAtCall(returning: result)
                            if NoReturnCatalog.isNoReturn(frame.target) {
                                operation = .call(frame: frame, result: nil)
                            }
                        }
                        let operands = Self.splitOperands(source.operands)
                        let rewritten = stagedRewrite.rewrite(operation,
                            mnemonic: source.mnemonic,
                            width: operands.first.flatMap(Self.scalarDataBitWidth),
                            operandWidths: operands.dropFirst().map(Self.scalarDataBitWidth),
                            address: source.address, allowSequence: false)
                        // Carry the same row-level access facts as the
                        // ordinary builder, so a scalar load or pair keeps
                        // its width and renders as typed memory.
                        effects.append(.init(source: source, operation: rewritten,
                            memoryAccess: Self.memoryAccess(for: source),
                            scalarFP: Self.scalarFPSemantics(mnemonic: source.mnemonic,
                                                             operands: operands)))
                    }
                    if !complete {
                        staged = rowStart.state
                        stagedSequence = rowStart.sequence
                        stagedStructureLaneSequence = rowStart.structureLaneSequence
                        stagedRewrite = rowStart.rewrite
                        effects.removeSubrange(rowStart.effects...)
                        effects.append(generalVectorRefusal(row, state: &staged))
                    }
                }
                state = staged
                memorySequence = stagedSequence
                structureLaneSequence = stagedStructureLaneSequence
                arithmeticRewrite = stagedRewrite
                instructions.append(contentsOf: effects)
                outgoing[block.index] = state
            }
        }

        let phis = plan.resolvedPhis(drafts, rows: rows, outgoing: outgoing,
                                     instructions: instructions)
        // Pending backedges are now resolved. An unavailable target/modifier
        // must not masquerade as a preserved register through a loop phi.
        guard Self.generalVectorCallControlsRepresentable(instructions: instructions, phis: phis) else { return nil }
        // The last block may be an early no-return exit reached without the
        // stack frame or locals seen on another path. Function metadata comes
        // from every committed block, never from the final linear state alone.
        let observedStates = plan.cfg.blocks.compactMap { outgoing[$0.index] }
        var metadata = state
        metadata.maxStackDepth = observedStates.map(\.maxStackDepth).max() ?? state.maxStackDepth
        metadata.maxStackDisplacement = observedStates.map(\.maxStackDisplacement).max() ?? state.maxStackDisplacement
        var localsByOffset: [Int64: MacIRLocalVariable] = [:]
        var conflictingLocals: Set<Int64> = []
        for observed in observedStates {
            for local in observed.recoveredLocalVariables {
                if let previous = localsByOffset[local.offset], previous != local {
                    conflictingLocals.insert(local.offset)
                } else {
                    localsByOffset[local.offset] = local
                }
            }
        }
        for offset in conflictingLocals { localsByOffset.removeValue(forKey: offset) }
        metadata.localVariablesByOffset = localsByOffset
        var function = MacIRFunction(
            name: name, startAddress: startAddress ?? rows.first?.address ?? 0,
            endAddress: rows.last.flatMap { $0.address.addressAfter() },
            returnType: state.returnType ?? "int64_t", isVariadic: isVariadic,
            parameters: state.parameters,
            localVariables: metadata.recoveredLocalVariables,
            nameBindings: metadata.recoveredNameBindings,
            stackFrameSize: metadata.maxStackDepth,
            maxStackDisplacement: metadata.maxStackDisplacement, callTargets: state.callTargets,
            callSignatures: state.recoveredCallSignatures,
            returnValue: state.returnValue, instructions: instructions, phis: phis)
        // Sticky QC updates matter only if the function reads FPSR back.
        function.observesFPSR = observesFPSR
        return LocalTypeInferencePass.infer(function: function)
    }

    /// Bit width of an FMOV involving a B/H/S/D scalar view, nil if no view is
    /// involved, and 0 for forms the region refuses (immediates, mismatches).
    static func scalarViewMoveWidth(_ operandText: String) -> Int? {
        let operands = splitOperands(operandText).map { $0.lowercased() }
        func width(_ operand: String) -> (Int, Bool)? {
            guard let first = operand.first, let index = Int(operand.dropFirst()), operand == "\(first)\(index)" else { return nil }
            switch first {
            case "b": return (8, true)
            case "h": return (16, true)
            case "s": return (32, true)
            case "d": return (64, true)
            case "w": return index <= 30 ? (32, false) : nil
            case "x": return index <= 30 ? (64, false) : nil
            default: return nil
            }
        }
        guard operands.count == 2 else { return nil }
        let views = operands.compactMap(width)
        guard views.contains(where: { $0.1 }) else { return nil }
        guard views.count == 2, views[0].0 == views[1].0 else { return 0 }
        return views[0].0
    }

    private static func generalVectorSource<Row: DecompilerInstructionRow>(_ row: Row) -> MacIRSourceSpan {
        .init(address: row.address, byteText: row.bytes,
              mnemonic: row.mnemonic.lowercased(), operands: row.operands,
              comment: row.comment)
    }

    /// `incoming` considers 31 X registers, SP and 32 physical V registers at
    /// every real join. Bound the total predecessor-state cells it can compose,
    /// independently of the number or arrangement of natural-loop backedges.
    private static let generalVectorStateMergeCellLimit = 16_384

    private static func generalVectorStateMergeCellCount(_ cfg: CFG) -> Int? {
        let stateCellsPerPredecessor = 31 + 1 + 32
        var total = 0
        for block in cfg.blocks where block.index != cfg.entryIndex {
            let hasPendingBackedge = block.predecessors.contains {
                cfg.backEdges.contains(CFGEdge($0, block.index))
            }
            guard block.predecessors.count > 1 || hasPendingBackedge else { continue }
            let product = block.predecessors.count.multipliedReportingOverflow(
                by: stateCellsPerPredecessor)
            guard !product.overflow else { return nil }
            let sum = total.addingReportingOverflow(product.partialValue)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    private static func generalVectorPlan<Row: DecompilerInstructionRow>(
        _ rows: [Row], hasExternalFacts: Bool,
        switches: [UInt64: GeneralVectorSwitch] = [:]
    ) -> ScalarCFGStatePlan? {
        // A cost bound on per-block state merging, not a shape window.
        let finalIsNoReturnCall = rows.last.map { row in
            let operands = splitOperands(row.operands)
            return row.mnemonic.lowercased() == "bl" && operands.count == 1
                && NoReturnCatalog.isNoReturn(operands[0])
        } ?? false
        guard !hasExternalFacts, (1...1024).contains(rows.count),
              rows.last?.mnemonic.lowercased() == "ret" || finalIsNoReturnCall
                || isBranchFreeVectorLeaf(rows) else { return nil }
        let addresses = Set(rows.map(\.address))
        guard addresses.count == rows.count else { return nil }
        // An undecoded row has no operand text naming what it writes, so a
        // refusal could not poison its destination; never compose around it.
        guard !rows.contains(where: { ["unknown", "unavailable"].contains($0.mnemonic.lowercased()) })
        else { return nil }
        // These decoded saturating narrows are still refused as data rows. A
        // later FPSR read would observe their QC write, which the unknown row
        // cannot represent, so leave that function with the ordinary builder.
        let refusedQCNarrows: Set<String> = ["sqshrun", "sqrshrun", "uqshrn", "uqrshrn",
                                             "sqshrun2", "sqrshrun2", "uqshrn2", "uqrshrn2"]
        if rows.contains(where: { refusedQCNarrows.contains($0.mnemonic.lowercased()) }),
           rows.contains(where: { $0.mnemonic.lowercased() == "mrs"
               && $0.operands.lowercased().contains("fpsr") }) { return nil }
        var control: [MacIRInstruction] = []
        var referenced: Set<Int> = []
        var referencedVectors: Set<Int> = []
        let scalarViewRows: Set<String> = ["ldr", "ldur", "str", "stur", "ldp", "stp", "fmov"]
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let next = rows[index-1].address.addingReportingOverflow(4)
                guard !next.overflow, next.partialValue == row.address else { return nil }
            }
            let source = generalVectorSource(row)
            let operands = splitOperands(source.operands)
            let scalarDup = scalarDupElementOperation(mnemonic: source.mnemonic, operandText: source.operands)
            let scalarReduction = scalarADDVCarrier(row)
            if let scalarDup, let destination = vectorRegisterIndex(scalarDup.destination) {
                // B/H/S/D may be the only spelling of this destination in a
                // loop. It still requires a full-width V-register phi.
                referencedVectors.insert(destination)
            }
            if let scalarReduction, let destination = vectorRegisterIndex(scalarReduction.destination) {
                referencedVectors.insert(destination)
            }
            for token in source.operands.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let value = String(token).lowercased()
                guard let first = value.first, let number = Int(value.dropFirst()) else { continue }
                if first == "x" || first == "w", (0...30).contains(number) {
                    referenced.insert(number)
                }
                if first == "v" || first == "q", (0...31).contains(number) {
                    referencedVectors.insert(number)
                }
                // Exact scalar DUP and encoded integer ADDV extend the existing
                // memory/FMOV scalar-view contract; no mnemonic-wide exception.
                if "bhsd".contains(first), (0...31).contains(number),
                   !scalarViewRows.contains(source.mnemonic), scalarDup == nil,
                   scalarReduction == nil { return nil }
            }
            let operation: MacIROperation
            switch source.mnemonic {
            case "cbz", "cbnz":
                guard operands.count == 2, let target = generalVectorTarget(operands[1], addresses: addresses) else { return nil }
                operation = .conditionalBranch(
                    condition: source.mnemonic == "cbz" ? "==" : "!=",
                    left: .unknown("condition"), right: .immediate(0), target: target)
            case "tbz", "tbnz":
                // Test-bit branches are conditional edges like CBZ/CBNZ.
                guard operands.count == 3, let width = scalarDataBitWidth(operands[0]),
                      let bit = parseImmediate(operands[1]), bit >= 0, bit < width,
                      let target = generalVectorTarget(operands[2], addresses: addresses) else { return nil }
                operation = .conditionalBranch(condition: source.mnemonic == "tbz" ? "==" : "!=",
                    left: .unknown("bit_condition"), right: .immediate(0), target: target)
            case "br":
                guard let site = switches[row.address] else { return nil }
                operation = site.operation(index: .unknown("switch_selector"))
            case "b":
                guard operands.count == 1, let target = generalVectorTarget(operands[0], addresses: addresses) else { return nil }
                operation = .intrinsic(destination: nil, name: "branch", arguments: [target])
            case let mnemonic where mnemonic.hasPrefix("b."):
                guard operands.count == 1, let target = generalVectorTarget(operands[0], addresses: addresses) else { return nil }
                operation = .conditionalBranch(condition: "!=", left: .unknown("nzcv"),
                                               right: .immediate(0), target: target)
            case "ret":
                operation = .returnValue(nil)
            case "bl" where operands.count == 1 && NoReturnCatalog.isNoReturn(operands[0]):
                operation = .returnValue(nil)
            case let mnemonic where isGeneralVectorIndirectCall(mnemonic):
                guard hasValidReturningCallOperands(mnemonic: mnemonic, operands: operands) else { return nil }
                // Like returning BL, this is a fallthrough placeholder only.
                // Emission captures target/PAC controls before the ABI boundary.
                operation = .unknown(destination: nil, mnemonic: mnemonic, operands: source.operands)
            default:
                // Never turn any other unmodelled control transfer into fallthrough.
                // The five validated indirect-call forms are handled above.
                if source.mnemonic.hasPrefix("br") || (source.mnemonic.hasPrefix("bl") && source.mnemonic != "bl")
                    || source.mnemonic.hasPrefix("ret") || source.mnemonic.hasPrefix("eret")
                    || source.mnemonic.hasPrefix("bc.") || ["svc", "hvc", "smc", "hlt"].contains(source.mnemonic) {
                    return nil
                }
                operation = .unknown(destination: nil, mnemonic: source.mnemonic,
                                     operands: source.operands)
            }
            control.append(.init(source: source, operation: operation))
        }
        let cfg = CFGBuilder.buildCFG(instructions: control)
        guard let stateMergeCells = generalVectorStateMergeCellCount(cfg),
              !cfg.hasUnresolvedTargets, cfg.irreducibleBlocks.isEmpty,
              !cfg.backEdges.isEmpty || isBranchFreeVectorLeaf(rows)
                || (finalIsNoReturnCall && rows.contains(where: admitsGeneralVectorRow)),
              stateMergeCells <= generalVectorStateMergeCellLimit,
              cfg.backEdges.allSatisfy({ $0.to != cfg.entryIndex }),
              cfg.blocks.last?.endIndex == rows.count else { return nil }
        // The state composer emits blocks in source order. A later predecessor
        // is only representable by its pending-backedge phi mechanism, not by
        // assuming entry vector values on an arbitrary reverse-address DAG edge.
        if !switches.isEmpty {
            guard cfg.blocks.allSatisfy({ block in
                block.predecessors.allSatisfy { predecessor in
                    predecessor < block.index || cfg.backEdges.contains(CFGEdge(predecessor, block.index))
                }
            }) else { return nil }
        }
        for (dispatch, site) in switches {
            guard let definitionIndex = rows.firstIndex(where: { $0.address == site.selector.definitionAddress }),
                  let dispatchIndex = rows.firstIndex(where: { $0.address == dispatch }),
                  let definitionBlock = cfg.blocks.first(where: { $0.instructionRange.contains(definitionIndex) }),
                  let dispatchBlock = cfg.blocks.first(where: { $0.instructionRange.contains(dispatchIndex) }),
                  CFGBuilder.dominates(definitionBlock.index, dispatchBlock.index, domTree: cfg.domTree)
            else { return nil }
        }
        var reached: Set<Int> = [cfg.entryIndex]
        for _ in cfg.blocks { for block in cfg.blocks where reached.contains(block.index) {
            reached.formUnion(block.successors)
        } }
        guard reached.count == cfg.blocks.count else { return nil }
        var plan = ScalarCFGStatePlan(cfg: cfg,
            blockAtStart: Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.startIndex, $0.index) }),
            blockAtEnd: Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.endIndex-1, $0.index) }),
            conditionalForks: [:], referencedXRegisters: referenced.sorted())
        plan.referencedVRegisters = referencedVectors.sorted()
        // Rows that write SP: a data-processing destination or a memory writeback base.
        var spWriters: Set<Int> = []
        var modeledSPWritesOnly = true
        for (index, row) in rows.enumerated() {
            let operands = splitOperands(row.operands).map { $0.lowercased() }
            let mnemonic = row.mnemonic.lowercased()
            let storesOrCompares = mnemonic.hasPrefix("st") || ["cmp", "cmn", "tst"].contains(mnemonic)
            let writesSP = (["sp", "wsp"].contains(operands.first ?? "") && !storesOrCompares)
                || ["sp", "wsp"].contains(explicitMemoryWritebackBase(operands: operands) ?? "")
            if writesSP {
                // No optimistic recovery through unknown writes or width aliases.
                modeledSPWritesOnly = modeledSPWritesOnly && ["add", "sub"].contains(mnemonic)
                    && operands.count == 3 && operands[0] == "sp" && operands[1] == "sp"
                    && parseImmediate(operands[2]) != nil
            }
            if writesSP, let block = cfg.blocks.first(where: { $0.instructionRange.contains(index) }) {
                spWriters.insert(block.index)
            }
            if operands.contains(where: { $0 == "sp" || $0.contains("[sp") }) { plan.referencesSP = true }
        }
        plan.spWritingBlocks = spWriters
        plan.permitsPendingSPRecovery = modeledSPWritesOnly
        plan.spWritingLoopHeaders = ScalarCFGStatePlan.loopHeaders(in: cfg, containingAnyOf: spWriters)
        return plan
    }

    private static func generalVectorTarget(_ text: String, addresses: Set<UInt64>) -> MacIRValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("0x")
            ? UInt64(trimmed.dropFirst(2), radix: 16) : UInt64(trimmed)
        guard let value, value <= UInt64(Int64.max), addresses.contains(value) else { return nil }
        return .immediate(Int64(value))
    }

    func generalVectorRefusal<Row: DecompilerInstructionRow>(
        _ row: Row, state: inout BuilderState
    ) -> MacIRInstruction {
        let source = Self.generalVectorSource(row)
        if source.mnemonic == "ret" || source.mnemonic == "b" ||
           source.mnemonic.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(source.mnemonic) {
            let operation = operationForVectorRegion(for: source, state: &state)
            return .init(source: source, operation: operation)
        }
        let operands = Self.splitOperands(source.operands)
        let sets = Self.unknownInstructionReadSets(mnemonic: source.mnemonic, operands: operands)
        let bind = { (register: String) in MacIRUnknownRead(register: register,
                                                            value: state.readRegister(register)) }
        let inputs = MacIRUnknownInputs(mayRead: sets.mayRead.map(bind),
            definiteRead: sets.definiteRead.map(bind), mayReadNZCV: sets.mayReadNZCV,
            definitelyReadsNZCV: sets.definitelyReadsNZCV)
        var writes = Set(Self.argumentRegisterWrites(mnemonic: source.mnemonic,
                                                    operands: operands))
        // Unknown GPR forms must not keep a prior scalar definition live.
        // This is conservative invalidation, never a claimed SSA producer.
        if let destination = Self.firstOperandWriteForUnknown(mnemonic: source.mnemonic,
                                                              operands: operands) {
            writes.insert(destination)
        }
        if let base = Self.explicitMemoryWritebackBase(operands: operands) {
            writes.insert(base)
        }
        // Structure loads write every vector in their register list. A bad
        // textual list must not preserve the previous SSA values either.
        let structureLoads: Set<String> = ["ld1", "ld2", "ld3", "ld4"]
        if structureLoads.contains(source.mnemonic) {
            if let closing = source.operands.firstIndex(of: "}") {
                for token in source.operands[...closing].lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                    if let prefix = token.first, prefix == "v" || prefix == "q",
                       let index = Int(token.dropFirst()), (0...31).contains(index) {
                        writes.insert("v\(index)")
                    }
                }
            }
        }
        if let word = Self.neonBufferSequenceWord(row) {
            let base = Int((word >> 5) & 31)
            let structureMnemonics: Set<String> = ["ld1", "ld2", "ld3", "ld4",
                                                   "st1", "st2", "st3", "st4"]
            if structureMnemonics.contains(source.mnemonic),
               word & 0x0e000000 == 0x0c000000 {
                if word & 0x00800000 != 0 {
                    writes.insert(base == 31 ? "sp" : "x\(base)")
                }
                if structureLoads.contains(source.mnemonic) {
                    let first = Int(word & 31)
                    for offset in 0..<4 { writes.insert("v\((first + offset) % 32)") }
                }
            } else if Self.encodedNEONBufferSequence(row), base < 31 {
                let pair = word & 0xfe000000 == 0xac000000
                let writesBack = pair ? ((word >> 23) & 3) != 2
                                      : ((word >> 10) & 3) != 0
                if writesBack { writes.insert("x\(base)") }
            }
        }
        // A refused data row writes its first vector operand unless it is a
        // store, whose first operand is the value read.
        let writesMemory = Self.unmodeledMemoryWritePrefixes.contains(where: source.mnemonic.hasPrefix)
            || Self.isMemoryOperationMnemonic(source.mnemonic)
        if !writesMemory, let first = operands.first?.lowercased(),
           let index = Self.vectorRegisterIndex(first) {
            writes.insert("v\(index)")
        }
        // Memory: a refused store may alias any known stack value, so no
        // cached slot may forward past it. A proven stack target also ends
        // entry-SP provenance, as for the ordinary builder's unknown store.
        if writesMemory {
            if Self.unmodeledMemoryWriteTargetsProvenStack(mnemonic: source.mnemonic,
                                                           operands: operands, state: state) {
                state.invalidateEntrySPProvenance()
            }
            state.invalidateAllStackSlotValues()
        }
        for register in Set(writes.map { state.neonBufferCarrier($0) }).sorted() {
            state.recordUnmodeledDefiniteWrite(for: register)
            if Self.vectorRegisterIndex(register) != nil {
                // The generic unmodeled-write path tracks vector call captures,
                // but a refused vector definition must also hide the prior SSA value.
                state.callUnavailableRegisterValues.insert(register)
                state.unavailableRegisterValues.insert(register)
            }
        }
        state.lastComparison = nil
        state.lastAdjacentComparison = nil
        state.pendingConditionalCompare = nil
        state.sawConditionalCompareSinceComparison = true
        return .init(source: source, operation: .unknown(destination: nil,
            inputs: inputs, mnemonic: source.mnemonic, operands: source.operands))
    }
}

// Resolved control metadata is shared by planning and emission, so neither can
// silently omit a case edge admitted by the other.
extension MacIRBuilder {
    struct GeneralVectorSwitch {
        let selector: JumpTableSelectorProof
        let targets: [UInt64]
        let defaultTarget: UInt64?

        func operation(index: MacIRValue) -> MacIROperation {
            .switchDispatch(index: index, cases: targets.enumerated().map {
                MacIRSwitchCase(value: Int64($0.offset), target: .immediate(Int64($0.element)))
            }, defaultTarget: defaultTarget.map { .immediate(Int64($0)) })
        }
    }

    static func generalVectorSwitches<Row: DecompilerInstructionRow>(
        _ rows: [Row], jumpTables: [UInt64: [UInt64]]
    ) -> [UInt64: GeneralVectorSwitch]? {
        let addresses = Set(rows.map(\.address))
        var sites: [UInt64: GeneralVectorSwitch] = [:]
        for (index, row) in rows.enumerated() where row.mnemonic.lowercased() == "br" {
            let operands = splitOperands(row.operands)
            guard operands.count == 1, isRegister(operands[0]),
                  let targets = jumpTables[row.address], !targets.isEmpty,
                  let selector = JumpTableResolver.proveRegionSelector(rows: rows, dispatchIndex: index, jumpTables: jumpTables),
                  targets.count == selector.caseCount,
                  targets.allSatisfy({ addresses.contains($0) && $0 <= UInt64(Int64.max) })
            else { return nil }
            let defaultTarget: UInt64?
            switch selector.guardKind {
            case let .boundsBranch(target):
                guard let target, addresses.contains(target), target <= UInt64(Int64.max) else { return nil }
                defaultTarget = target
            case .clamp, .boundedRange: defaultTarget = nil
            }
            sites[row.address] = GeneralVectorSwitch(selector: selector, targets: targets,
                                                     defaultTarget: defaultTarget)
        }
        // The selector proof checks direct branches for guard bypasses. Include
        // all resolved indirect edges too, before using that proof in a region.
        for (dispatch, site) in sites {
            let guardAddress: UInt64
            switch site.selector.guardKind {
            case .boundsBranch, .boundedRange: guardAddress = site.selector.definitionAddress
            case .clamp:
                guard site.selector.definitionAddress >= 4 else { return nil }
                guardAddress = site.selector.definitionAddress - 4 // CMP before defining CSEL
            }
            for other in sites.values {
                if (other.targets + (other.defaultTarget.map { [$0] } ?? [])).contains(where: {
                    $0 > guardAddress && $0 <= dispatch
                }) { return nil }
            }
        }
        return sites
    }
}


extension MacIRBuilder {
    static func isGeneralVectorIndirectCall(_ mnemonic: String) -> Bool {
        ["blr", "blraa", "blrab", "blraaz", "blrabz"].contains(mnemonic)
    }

    /// Representation proof only: never resolves a target or supplies its type.
    /// Follow modeled definitions and completed phis so a copied unknown or a
    /// caller-clobbered backedge cannot become an authoritative control input.
    static func generalVectorCallControlsRepresentable(
        instructions: [MacIRInstruction], phis: [MacIRPhi]
    ) -> Bool {
        let controls = instructions.flatMap { instruction -> [MacIRValue] in
            guard case let .call(frame, _) = instruction.operation else { return [] }
            return frame.controlInputs.bindingValues
        }
        guard !controls.isEmpty else { return true } // Preserve the direct-BL path.
        var definitions: [MacIRValue: [MacIRValue]] = [:]
        func define(_ destination: MacIRValue, _ inputs: [MacIRValue]) {
            definitions[destination, default: []].append(contentsOf: inputs)
        }
        for phi in phis { define(phi.destination, phi.incoming.map(\.value)) }
        for instruction in instructions {
            switch instruction.operation {
            case let .assign(destination, source): define(destination, [source])
            case let .binary(destination, _, left, right): define(destination, [left, right])
            case let .load(destination, address): define(destination, [address])
            case let .loadWriteback(destination, base, source, _, _):
                define(destination, [source]); define(base, [source])
            case let .storeWriteback(_, base, source, _, _): define(base, [source])
            case let .stackSlotRead(destination, _, value): define(destination, [value])
            case let .stackSlotPairRead(first, _, firstValue, second, _, secondValue):
                define(first, [firstValue]); define(second, [secondValue])
            case let .select(destination, _, left, right, yes, no): define(destination, [left, right, yes, no])
            case let .compareToBool(destination, _, left, right): define(destination, [left, right])
            case let .intrinsic(destination?, _, inputs): define(destination, inputs)
            case let .call(_, result?): define(result, []) // A fresh opaque result, not a preserved caller value.
            case let .unknown(destination?, _, _, _): define(destination, [.unknown("unrepresentable_call_control")])
            default: break
            }
        }
        var visited: Set<MacIRValue> = []
        func represented(_ value: MacIRValue) -> Bool {
            if case .unknown = value { return false }
            if !visited.insert(value).inserted { return true }
            if let inputs = definitions[value] { return inputs.allSatisfy(represented) }
            switch value {
            case let .unary(_, inner), let .bitTest(inner, _): return represented(inner)
            case let .binaryExpression(_, left, right): return represented(left) && represented(right)
            case let .signedBitfield(field): return represented(field.source)
            case let .abiComposite(_, fragments): return fragments.allSatisfy(represented)
            case let .register(_, version): return version == 0
            case .temporary: return false
            default: return true
            }
        }
        return controls.allSatisfy(represented)
    }
}
