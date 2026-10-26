import Foundation

/// Callee facts supplied by the call resolver. A missing signature does not
/// borrow the enclosing function's return type or invent argument types.
struct SSAEffectsCallContext {
    var target: String? = nil
    var argumentRegisters: [String]? = nil
    var resultRegister: String? = nil
    var returnsValue: Bool = true
}

extension MacIRBuilder {
    struct SSARegisterView {
        var cell: Int
        var bitWidth: Int
        var view: MacIRSSA.ScalarView
        var cells: [Int]
    }

    /// Physical alias mapping. Lane operands select their containing half;
    /// whole Q/V operands read both halves. The width is the requested view,
    /// whereas an SSA SIMD definition always describes a 64-bit physical half.
    static func ssaRegisterView(for register: String) -> SSARegisterView? {
        let name = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "sp" || name == "wsp" {
            return .init(cell: 31, bitWidth: name == "sp" ? 64 : 32, view: .integer, cells: [31])
        }
        if name == "fp" { return .init(cell: 29, bitWidth: 64, view: .integer, cells: [29]) }
        if name == "lr" { return .init(cell: 30, bitWidth: 64, view: .integer, cells: [30]) }
        if name == "nzcv" { return .init(cell: 96, bitWidth: 4, view: .flags, cells: [96]) }
        if let integer = integerRegisterView(name) {
            return .init(cell: integer.index, bitWidth: integer.width, view: .integer, cells: [integer.index])
        }
        guard let simd = BuilderState.simdViewWidth(name) else { return nil }
        let low = 32 + simd.index
        if let bracket = name.firstIndex(of: "["), name.hasSuffix("]"),
           let dot = name.firstIndex(of: "."), dot < bracket {
            let element = name[name.index(after: dot)..<bracket]
            let widths = ["b": 8, "h": 16, "s": 32, "d": 64]
            guard let width = widths[String(element)],
                  let lane = Int(name[name.index(after: bracket)..<name.index(before: name.endIndex)]),
                  (0..<(128 / width)).contains(lane) else { return nil }
            let cell = low + (lane * width >= 64 ? 32 : 0)
            return .init(cell: cell, bitWidth: width, view: .bits, cells: [cell])
        }
        var width = simd.width
        if let dot = name.firstIndex(of: ".") {
            let arrangement = name[name.index(after: dot)...]
            let countText = arrangement.prefix(while: \.isNumber)
            if let count = Int(countText), let kind = arrangement.last,
               let elementWidth = [Character("b"): 8, "h": 16, "s": 32, "d": 64][kind] {
                guard count <= 16, count > 0, countText.count + 1 == arrangement.count,
                      [64, 128].contains(count * elementWidth) else { return nil }
                width = count * elementWidth
            } else { return nil }
        }
        let view: MacIRSSA.ScalarView = name.first == "d" ? .float64 : name.first == "s" ? .float32 : .bits
        return .init(cell: low, bitWidth: width, view: view,
                     cells: width > 64 ? [low, low + 32] : [low])
    }

    static func ssaCell(for register: String) -> Int? { ssaRegisterView(for: register)?.cell }

    static func ssaEffects(
        for source: MacIRSourceSpan,
        call: SSAEffectsCallContext? = nil,
        observesFPSR: Bool = false,
        tracksFPEnvironment: Bool = false
    ) -> MacIRSSA.RowEffects {
        if let widening = neonWideningPairwise(source) {
            // The accumulator is a read as well as a definition. Both physical
            // halves survive; this full-width operation never implies zero-high.
            let reads = Set([widening.source, widening.destination].flatMap {
                ssaRegisterView(for: $0)?.cells ?? []
            })
            let writes = (ssaRegisterView(for: widening.destination)?.cells ?? []).map {
                MacIRSSA.Write(cell: $0, bitWidth: 64, view: .bits, origin: .instruction(source.address))
            }
            return .init(address: source.address, reads: .init(reads), writes: writes,
                readViews: Dictionary(uniqueKeysWithValues: reads.map { ($0, .bits) }), refusals: [])
        }
        if let permutation = ssaVectorPermutation(source) {
            let sourceRegisters = permutation.sources + (permutation.readsDestination ? [permutation.destination] : [])
            var cells = Set<Int>()
            for name in sourceRegisters {
                for cell in ssaRegisterView(for: name)?.cells ?? [] { cells.insert(cell) }
            }
            let definitions = (ssaRegisterView(for: permutation.destination)?.cells ?? []).map {
                MacIRSSA.Write(cell: $0, bitWidth: 64, view: $0 < 32 ? .integer : .bits,
                               origin: .instruction(source.address))
            }
            return .init(address: source.address, reads: .init(Array(cells)), writes: definitions,
                         readViews: Dictionary(uniqueKeysWithValues: cells.map { ($0, $0 < 32 ? .integer : .bits) }), refusals: [])
        }
        if let exact = ssaExactVector(source) {
            return ssaExactVectorEffects(exact, address: source.address)
        }
        // the byte/text-agreed scalar forms have exact source/NZCV
        // reads and no invented FP environment or destination read.
        if let select = ssaSnapshotSelect(source) { return select.effects(address: source.address) }
        let mnemonic = source.mnemonic.lowercased()
        let operands = splitOperands(source.operands).map { $0.lowercased() }
        let address = source.address
        let vectorFP = MacIRVectorFP(source: source)
        let targetedFP = MacIRFPBlockedEffect.requiresEnvironment(mnemonic: mnemonic, operands: source.operands)
        let blockedFP = targetedFP && vectorFP == nil
        let statusAccess = MacIRFPBlockedEffect.isStatusAccess(source: source)
        let tracksEnvironment = tracksFPEnvironment || targetedFP || statusAccess
        let fp = blockedFP ? nil : scalarFPSemantics(mnemonic: mnemonic, operands: operands)
        let lane = ssaIntegerLaneOperation(mnemonic: mnemonic, operands: source.operands)
        // Preserve the established saturating effect route; only newly admitted
        // nonsaturating descriptors replace conservative tokenized effects.
        let exactIntegerEffects = lane.map { !$0.semantics.setsQC } ?? false
        let isCall = ssaCallMnemonics.contains(mnemonic)
        let isReturn = ssaReturnMnemonics.contains(mnemonic)
        let writesUpperOnly = ssaUpperHalfNarrowMnemonics.contains(mnemonic)
        let isKnown = fp != nil || vectorFP != nil || lane != nil || ssaKnownMnemonics.contains(mnemonic)
            || mnemonic.hasPrefix("b.")
            || modernTransparentPACIntrinsicNames.contains(mnemonic)
        let validCall = !isCall || hasValidReturningCallOperands(mnemonic: mnemonic, operands: operands)
        let refused = !isKnown || !validCall || blockedFP || statusAccess
        var reads = MacIRSSA.CellSet([])
        var readViews: [Int: MacIRSSA.ScalarView] = [:]
        var writes: [Int: MacIRSSA.Write] = [:]
        var refusals: [MacIRRefusal] = []
        let refusalReason: MacIRRefusal.Reason = mnemonic.isEmpty || mnemonic == "udf"
            ? .undecodableRow : .unknownEffects
        let instructionOrigin: MacIRSSA.DefinitionOrigin = refused
            ? .refusal(refusalReason, address) : .instruction(address)

        func mergeView(_ view: MacIRSSA.ScalarView, into cell: Int) {
            if let prior = readViews[cell], prior != view { readViews[cell] = .bits }
            else { readViews[cell] = view }
        }
        func readCell(_ cell: Int, view: MacIRSSA.ScalarView) {
            reads.insert(cell)
            mergeView(view, into: cell)
        }
        func readRegister(_ name: String, view override: MacIRSSA.ScalarView? = nil) {
            guard let register = ssaRegisterView(for: name) else { return }
            for cell in register.cells {
                readCell(cell, view: cell >= 64 && cell < 96 ? .bits : override ?? register.view)
            }
        }
        func writeCell(_ cell: Int, width: Int, view: MacIRSSA.ScalarView,
                       origin: MacIRSSA.DefinitionOrigin? = nil) {
            writes[cell] = .init(cell: cell, bitWidth: width, view: view, origin: origin ?? instructionOrigin)
        }
        func writeRegister(_ name: String, view override: MacIRSSA.ScalarView? = nil) {
            guard let register = ssaRegisterView(for: name) else { return }
            if writesUpperOnly, name == operands.first, (32..<64).contains(register.cell) {
                writeCell(register.cell + 32, width: 64, view: .bits)
                return
            }
            for cell in register.cells {
                let simd = (32..<96).contains(cell)
                writeCell(cell, width: simd ? 64 : register.bitWidth,
                          view: cell >= 64 && cell < 96 ? .bits : override ?? register.view)
            }
            // Scalar and 64-bit vector destinations clear the upper half.
            // Lane writes preserve the other bits instead of clearing them.
            if (32..<64).contains(register.cell), !name.contains("[") {
                writeCell(register.cell + 32, width: 64, view: .bits)
            }
        }

        // The unknown-input table retains reads of read/modify/write targets,
        // memory indexes, register lists and implicit PAC operands. Its may-read
        // set is conservative for liveness, not a claim about source parameters.
        let unknownReads = unknownInstructionReadSets(mnemonic: mnemonic, operands: operands)
        func readOperandRegister(_ name: String) {
            let exactViews = operands.enumerated().compactMap { index, operand -> String? in
                guard !operand.hasPrefix("["), let view = ssaRegisterView(for: operand),
                      (32..<96).contains(view.cell),
                      operand == name || operand.hasPrefix(name + ".") else { return nil }
                if index == 0, ssaWriteOnlyDestinationMnemonics.contains(mnemonic) || fp != nil { return nil }
                if index == 1, ["ldp", "ldpsw"].contains(mnemonic) { return nil }
                return operand
            }
            if exactViews.isEmpty { readRegister(name) }
            else {
                for operand in exactViews {
                    if writesUpperOnly, operand == operands.first, let cell = ssaCell(for: operand) {
                        readCell(cell, view: .bits)
                    } else { readRegister(operand) }
                }
            }
        }
        for name in unknownReads.mayRead where !exactIntegerEffects {
            // The shared unknown-instruction table treats LDP's second operand
            // conservatively; the modeled pair load definitely only writes it.
            if ["ldp", "ldpsw"].contains(mnemonic), operands.count >= 3,
               unknownOperandRegisterReads(operands[1]).contains(name),
               !operands.dropFirst(2).contains(where: { unknownOperandRegisterReads($0).contains(name) }) { continue }
            readOperandRegister(name)
        }
        for name in argumentRegisterReads(mnemonic: mnemonic, operands: operands) where !exactIntegerEffects { readOperandRegister(name) }
        // Preserve lane precision where the tokenizer intentionally canonicalizes
        // a whole register. Partial writes also consume the old containing half.
        for operand in operands where !exactIntegerEffects && operand.contains("[") && !operand.hasPrefix("[") {
            if let view = ssaRegisterView(for: operand) {
                for cell in view.cells { readCell(cell, view: .bits) }
            }
        }
        if let immediate = neonBitClearImmediate(mnemonic: mnemonic, operandText: source.operands) {
            readRegister(immediate.destination, view: .bits)
            writeRegister(immediate.destination, view: .bits)
        }
        if !exactIntegerEffects, unknownReads.mayReadNZCV { readCell(96, view: .flags) }
        if isReturn {
            readCell(0, view: .integer)
            if operands.isEmpty { readCell(30, view: .integer) }
        }

        var registerWrites = argumentRegisterWrites(mnemonic: mnemonic, operands: operands)
        if let writeback = explicitMemoryWritebackBase(operands: operands) {
            registerWrites.append(writeback)
            readRegister(writeback)
        }
        // These unsupported families have definite destinations. Read-first
        // stores, atomics and branches never acquire a guessed first-operand DEF.
        if refused, unknownClaimsFirstOperandWrite(mnemonic: mnemonic),
           let destination = firstOperandWriteForUnknown(mnemonic: mnemonic, operands: operands) {
            registerWrites.append(destination)
        }
        for name in registerWrites where !exactIntegerEffects {
            // An untyped load into D/S is a payload transfer. Its destination
            // spelling alone does not establish a numeric floating-point value.
            let loadedSIMD = mnemonic.hasPrefix("ld")
                && ssaCell(for: name).map { (32..<96).contains($0) } == true
            writeRegister(name, view: loadedSIMD ? .bits : nil)
        }

        // The transparent PAC intrinsic does not model the signed/authenticated
        // pointer value. Its implicit X17 write must still kill the pre-PAC
        // binding; only a refusal-origin definition is installed as a clobber.
        if modernTransparentPACIntrinsicNames.contains(mnemonic) {
            for name in modernPACRegisterWrites(mnemonic: mnemonic) {
                // Implicit pointer/modifier reads are physical 64-bit GPRs.
                // X15 is definite for 171615 and conditional on FEAT_PAuth_LR /
                // PSTATE.PACM for 1716. Without that context retain the may-read
                // union; this does not model PAC semantics or write a modifier.
                readRegister(name)
                readRegister("x16")
                readRegister("x15")
                guard let register = ssaRegisterView(for: name) else { continue }
                writeCell(register.cell, width: register.bitWidth, view: register.view,
                          origin: .refusal(.unknownEffects, address))
            }
        }

        if let lane {
            for register in lane.sources { readRegister(register, view: .bits) }
            if lane.semantics.readsDestination { readRegister(lane.destination, view: .bits) }
            writeRegister(lane.destination, view: .bits)
        }
        if let vectorFP {
            for register in vectorFP.sources { readRegister(register, view: .bits) }
            if vectorFP.readsDestination { readRegister(vectorFP.destination, view: .bits) }
            // Full128 descriptor: high-half forms copy the old low64, Q=0 zeros high64.
            writeRegister(vectorFP.destination, view: .bits)
        }
        if blockedFP, let destination = operands.first { writeRegister(destination, view: .bits) }
        if tracksEnvironment {
            if targetedFP { readCell(100, view: .bits); readCell(99, view: .bits) }
            if vectorFP != nil { writeCell(99, width: 32, view: .bits) }
            if Self.isLegacyFPStatusWriter(source) {
                // Numeric-only scalar semantics do not define cumulative flags.
                // Preserve their existing result contract, but never carry stale
                // exception facts through a mixed vector/scalar FP function.
                writeCell(99, width: 32, view: .bits, origin: .refusal(.unknownEffects, address))
            }
            if statusAccess {
                let register = operands.contains("fpcr") ? 100 : 99
                if mnemonic == "mrs" { readCell(register, view: .bits) }
                if mnemonic == "msr" { writeCell(register, width: 32, view: .bits) }
            }
            // Unresolved FP completion, calls and arbitrary refused rows cannot
            // preserve a stale exception/control fact. QC remains separate98.
            if blockedFP || isCall || refused {
                writeCell(99, width: 32, view: .bits,
                    origin: isCall ? .callClobber(address) : .refusal(.unknownEffects, address))
                if !blockedFP {
                    writeCell(100, width: 32, view: .bits,
                        origin: isCall ? .callClobber(address) : .refusal(.unknownEffects, address))
                }
            }
        }

        // The shared register tokenizer omits H registers. Model the exact
        // scalar move operands here without changing the legacy effects route.
        if mnemonic == "fmov", operands.count == 2,
           isFmovScalarGPRFPBitMove(operands) || isFmovScalarFPFPMove(operands) {
            readRegister(operands[1])
            writeRegister(operands[0])
        }
        if mnemonic == "fmov", operands.count == 2,
           isFmovScalarFPRegister(operands[0]),
           operands[1].hasPrefix("#"), Double(operands[1].dropFirst()) != nil {
            writeRegister(operands[0])
        }

        if let fp {
            let resultView = ssaScalarView(fp.resultType)
            let inputView = ssaScalarView(fp.inputType)
            if let destination = operands.first {
                writeRegister(destination, view: fp.integerCarrier == .scalarSIMDBits && fp.operation == .toInteger ? .bits : resultView)
            }
            for operand in operands.dropFirst().prefix(fp.operation.arity) {
                guard let register = ssaRegisterView(for: operand) else { continue }
                let semanticView: MacIRSSA.ScalarView = fp.integerCarrier == .scalarSIMDBits && fp.operation == .fromInteger ? .bits : inputView
                for cell in register.cells { readViews[cell] = semanticView }
            }
        } else if mnemonic == "fmov", operands.count == 2,
                  isFmovScalarGPRFPBitMove(operands) {
            // A GPR/SIMD bit move supplies no evidence that its bits are numeric FP.
            writeRegister(operands[0], view: ssaCell(for: operands[0]).map { (32..<96).contains($0) } == true ? .bits : .integer)
            if let cell = ssaCell(for: operands[1]), (32..<96).contains(cell) { readViews[cell] = .bits }
        }

        if writesNZCVFlags(mnemonic) || isConditionalCompareInstruction(mnemonic)
            || ["rmif", "setf8", "setf16", "cfinv", "axflag", "xaflag"].contains(mnemonic)
            || (mnemonic == "msr" && operands.first == "nzcv") {
            writeCell(96, width: 4, view: .flags)
        }
        let memoryOperand = operands.contains { $0.hasPrefix("[") }
        let writesMemory = unmodeledMemoryWritePrefixes.contains(where: mnemonic.hasPrefix)
        if memoryOperand || writesMemory || mnemonic.hasPrefix("ld") { readCell(97, view: .memoryEpoch) }
        if writesMemory { writeCell(97, width: 64, view: .memoryEpoch) }

        if isCall, validCall {
            for name in call?.argumentRegisters ?? (0..<8).map({ "x\($0)" }) { readRegister(name) }
            readCell(97, view: .memoryEpoch)
            let clobber = MacIRSSA.DefinitionOrigin.callClobber(address)
            for cell in Array(0...18) + [30] { writeCell(cell, width: 64, view: .integer, origin: clobber) }
            writeCell(96, width: 4, view: .flags, origin: clobber)
            // AAPCS64 2025Q1 section 6.1.2: FPSR.QC is not preserved by calls.
            // Keep an observed QC dependency explicit without inventing its value.
            if observesFPSR { writeCell(98, width: 1, view: .qc, origin: clobber) }
            writeCell(97, width: 64, view: .memoryEpoch, origin: .instruction(address))
            for index in 0..<32 {
                if !(8...15).contains(index) { writeCell(32 + index, width: 64, view: .bits, origin: clobber) }
                writeCell(64 + index, width: 64, view: .bits, origin: clobber)
            }
            if call?.returnsValue != false {
                let result = ssaRegisterView(for: call?.resultRegister ?? "x0")
                    ?? SSARegisterView(cell: 0, bitWidth: 64, view: .integer, cells: [0])
                for cell in result.cells {
                    writeCell(cell, width: cell < 32 ? result.bitWidth : 64, view: result.view,
                              origin: .callResult(target: call?.target))
                }
            }
        }

        if observesFPSR {
            if refused && !blockedFP && !statusAccess && !isCall {
                writeCell(98, width: 1, view: .qc, origin: .refusal(.unknownEffects, address))
            }
            if mnemonic == "mrs", operands.contains("fpsr") { readCell(98, view: .qc) }
            if mnemonic == "msr", operands.first == "fpsr" {
                writeCell(98, width: 1, view: .qc)
            } else if ssaQCWriterPrefixes.contains(where: mnemonic.hasPrefix) {
                readCell(98, view: .qc)
                writeCell(98, width: 1, view: .qc)
            }
        }
        if refused {
            // An undecodable word has no trustworthy destination spelling.
            // Later exact lane rows must not inherit pre-word SIMD facts.
            if mnemonic.isEmpty || ["unknown", "unavailable", "udf"].contains(mnemonic) {
                for cell in 32..<96 {
                    writeCell(cell, width: 64, view: .bits,
                        origin: .refusal(refusalReason, address))
                }
            }
            let detail = validCall ? "unsupported machine mnemonic \(mnemonic)" : "invalid call operands for \(mnemonic)"
            refusals.append(.init(reason: refusalReason, scope: .row(address), detail: detail))
            readCell(97, view: .memoryEpoch)
            writeCell(96, width: 4, view: .flags)
            writeCell(97, width: 64, view: .memoryEpoch)
        }
        return .init(address: address, reads: reads, writes: writes.keys.sorted().compactMap { writes[$0] },
                     readViews: readViews, refusals: refusals)
    }

    static func isLegacyFPStatusWriter(_ source: MacIRSourceSpan) -> Bool {
        let mnemonic = source.mnemonic.lowercased()
        // FPCompare may raise IOC for signaling NaNs; FCCMP also has a
        // conditional compare path. Conservatively discard status knowledge.
        return ["fjcvtzs", "fcmp", "fcmpe", "fccmp", "fccmpe"].contains(mnemonic)
            || scalarFPSemantics(mnemonic: mnemonic,
            operands: splitOperands(source.operands).map { $0.lowercased() }) != nil
    }

    /// Exact lane descriptors own both effects and emission. Preserve the shared
    /// saturating route and its single sticky QC cell; add no second QC model.
    static func ssaIntegerLaneOperation(mnemonic: String, operands: String) -> NEONLaneOperands? {
        if let lane = scalarDupElementOperation(mnemonic: mnemonic, operandText: operands) { return lane }
        if let lane = ssaSaturatingLaneOperation(mnemonic: mnemonic, operands: operands) { return lane }
        // Arm A64 Operation: add_advsimd, sub_advsimd, smull_advsimd_vec,
        // smull_advsimd_elt, saddl_advsimd, ssubl_advsimd, shl_advsimd,
        // sshr_advsimd, ssra_advsimd, srsra_advsimd, subhn_advsimd,
        // smlsl_advsimd_vec, smlsl_advsimd_elt, raddhn_advsimd, rshrn_advsimd.
        // The same validated descriptor owns effects, emission and evaluation.
        // Default mode keeps the existing legacy descriptor path unchanged;
        // SSA admits the remaining high-narrow forms through that same path.
        guard ["smlal", "smlal2", "ushll", "ushll2", "sshll", "sshll2",
               "cmlt", "abs", "rshrn", "cmtst", "ushl", "addhn", "addhn2",
               "smlsl", "smlsl2", "shrn2", "raddhn", "raddhn2", "rshrn2", "add", "sub", "smull", "smull2",
               "saddl", "saddl2", "ssubl", "ssubl2", "shl", "sshr", "ssra",
               "srsra", "subhn", "subhn2", "cmeq", "cmhi", "addp", "xtn"].contains(mnemonic),
              let first = splitOperands(operands).first, first.contains(".") else { return nil }
        guard let parsed = neonLaneOperation(mnemonic: mnemonic, operandText: operands) else { return nil }
        // Keep these additional admissions at the retained exact arrangements.
        switch mnemonic {
        case "cmeq":
            guard parsed.semantics.kind == .cmeq, parsed.semantics.laneBits == 32,
                  parsed.semantics.activeBytes == 16 else { return nil }
        case "cmhi":
            guard parsed.semantics.laneBits == 16, parsed.semantics.activeBytes == 16 else { return nil }
        case "addp":
            guard parsed.semantics.laneBits == 8, parsed.semantics.activeBytes == 16 else { return nil }
        case "xtn":
            guard parsed.semantics.laneBits == 8, !parsed.semantics.highHalf else { return nil }
        default: break
        }
        return parsed
    }

    static func ssaSaturatingLaneOperation(mnemonic: String, operands: String) -> NEONLaneOperands? {
        guard ["sqshlu", "sqdmulh", "sqshrn", "sqshrn2", "sqrshrn", "sqrshrn2", "sqxtun", "sqxtun2"].contains(mnemonic),
              let first = splitOperands(operands).first, first.contains("."),
              let lane = neonLaneOperation(mnemonic: mnemonic, operandText: operands),
              lane.semantics.setsQC else { return nil }
        return lane
    }

    private static func ssaScalarView(_ type: MacIRScalarType) -> MacIRSSA.ScalarView {
        switch type {
        case .binary32: .float32
        case .binary64: .float64
        case .signed32, .signed64, .unsigned32, .unsigned64: .integer
        }
    }

    private static let ssaCallMnemonics: Set<String> = ["bl", "blr", "blraa", "blrab", "blraaz", "blrabz"]
    private static let ssaReturnMnemonics: Set<String> = [
        "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab",
    ]
    private static let ssaQCWriterPrefixes = ["sq", "uq", "suqadd", "usqadd"]
    private static let ssaWriteOnlyDestinationMnemonics: Set<String> = [
        "mov", "movz", "movn", "fmov", "ldr", "ldur", "ldp", "ldpsw", "add", "sub", "adds", "subs",
        "and", "ands", "orr", "eor", "mul", "neg", "negs", "mvn", "bic", "bics", "orn", "eon",
        "lsl", "lsr", "asr", "ror", "ubfx", "sbfx", "ubfiz", "sbfiz", "extr", "madd", "msub", "mneg",
        "umull", "smull", "umaddl", "smaddl", "smsubl", "umsubl", "smulh", "umulh",
    ]
    private static let ssaUpperHalfNarrowMnemonics: Set<String> = [
        "xtn2", "sqxtn2", "uqxtn2", "sqxtun2", "shrn2", "rshrn2", "sqshrn2", "sqrshrn2",
        "uqshrn2", "uqrshrn2", "sqshrun2", "sqrshrun2",
    ]
    private static let ssaKnownMnemonics: Set<String> = [
        "mov", "movz", "movn", "movk", "fmov", "add", "sub", "adds", "subs", "and", "ands", "orr", "eor",
        "mul", "sdiv", "udiv", "neg", "negs", "mvn", "bic", "bics", "orn", "eon", "lsl", "lsr", "asr", "ror",
        "ubfx", "sbfx", "ubfiz", "sbfiz", "bfi", "bfxil", "extr", "madd", "msub", "mneg", "umull", "smull",
        "umaddl", "smaddl", "smsubl", "umsubl", "smulh", "umulh", "adr", "adrp", "sxtb", "sxth", "sxtw",
        "uxtb", "uxth", "uxtw", "clz", "rbit", "rev", "rev16", "rev32", "cmp", "cmn", "tst", "ccmp", "ccmn",
        "ldr", "ldur", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldurb", "ldurh", "ldursb", "ldursh", "ldursw",
        "str", "stur", "strb", "strh", "sturb", "sturh", "stp", "ldp", "ldpsw",
        "bl", "blr", "blraa", "blrab", "blraaz", "blrabz", "br", "braa", "brab", "braaz", "brabz", "b",
        "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "eret", "eretaa", "eretab",
        "cbz", "cbnz", "tbz", "tbnz", "csel", "csinc", "csinv", "csneg", "cinc", "cinv", "cneg", "cset", "csetm",
        "nop", "brk", "pacibsp", "paciasp", "autibsp", "autiasp", "paciza", "pacizb", "pacia", "pacib",
        "autiza", "autizb", "autia", "autib", "xpaclri", "xpacd", "xpaci", "fjcvtzs",
        "crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch", "crc32cw", "crc32cx",
    ]
}

extension MacIRBuilder {
    /// Byte/text agreement is the admission boundary, shared by planning and
    /// emission. This is independent of function shape and the region lifter.
    enum SSAExactVector {
        // reuse the existing non-SP indexed memory descriptor.
        case indexedStore(NEONIndexedOperands)
        case immediate(register: Int, value: MacIRNEONImmediate)
        case memory(vectors: [String], base: String, offset: Int64,
                    writeback: Bool, preIndex: Bool, load: Bool)
    }

    static func ssaExactVector(_ source: MacIRSourceSpan) -> SSAExactVector? {
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return nil }
        var word: UInt32 = 0
        for (index, token) in tokens.enumerated() {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
            word |= UInt32(byte) << (index * 8)
        }
        let mnemonic = source.mnemonic.lowercased()
        if let indexed = ssaExactIndexedQStore(source) { return .indexedStore(indexed) }
        if ["movi", "mvni"].contains(mnemonic), word & 0x9ff80c00 == 0x0f000400,
           let parsed = neonMoveImmediate(mnemonic: mnemonic, operandText: source.operands) {
            let q = word & 0x40000000 != 0
            let op = word & 0x20000000 != 0
            let cmode = Int((word >> 12) & 15)
            let imm8 = UInt64(((word >> 16) & 7) << 5 | ((word >> 5) & 31))
            let bits: Int, shift: Int, immediate: UInt64
            let shiftingOnes = cmode == 12 || cmode == 13
            let kind: MacIRNEONImmediate.Kind = op && cmode != 14 ? .mvni : .movi
            guard mnemonic == kind.rawValue else { return nil }
            if shiftingOnes {
                // Cmode 1100/1101 shifts in 8/16 ones before optional inversion.
                bits = 32; shift = cmode == 12 ? 8 : 16; immediate = imm8
            } else if !op && cmode == 14 {
                bits = 8; shift = 0; immediate = imm8
            } else if !op && cmode <= 10 && cmode.isMultiple(of: 2) {
                bits = cmode < 8 ? 32 : 16
                shift = (cmode < 8 ? cmode / 2 : (cmode - 8) / 2) * 8
                immediate = imm8
            } else if op && cmode == 14 && q {
                bits = 64; shift = 0
                var expanded: UInt64 = 0
                for byte in 0..<8 where imm8 & (UInt64(1) << byte) != 0 {
                    expanded |= UInt64(255) << (byte * 8)
                }
                immediate = expanded
            } else { return nil } // Scalar D, logical and FP modified immediates stay refused.
            guard let value = MacIRNEONImmediate(kind: kind, laneBits: bits,
                activeBytes: q ? 16 : 8, immediate: immediate, shift: shift, shiftingOnes: shiftingOnes),
                parsed.destination == "v\(word & 31)", parsed.semantics == value else { return nil }
            return .immediate(register: Int(word & 31), value: value)
        }

        let baseIndex = Int((word >> 5) & 31)
        // SP uses the same physical SSA cell and exact address/writeback path.
        let base = baseIndex == 31 ? "sp" : "x\(baseIndex)"
        var vectors = ["q\(word & 31)"]
        let load = word & 0x00400000 != 0
        let offset: Int64, expectedMnemonic: String, writeback: Bool, preIndex: Bool
        if word & 0xff800000 == 0x3d800000 {
            expectedMnemonic = load ? "ldr" : "str"; offset = Int64((word >> 10) & 4095) * 16
            writeback = false; preIndex = false
        } else if word & 0xffa00000 == 0x3c800000 {
            let mode = (word >> 10) & 3
            guard mode != 2 else { return nil }
            let raw = Int64((word >> 12) & 511)
            offset = raw >= 256 ? raw - 512 : raw
            expectedMnemonic = load ? (mode == 0 ? "ldur" : "ldr") : (mode == 0 ? "stur" : "str")
            writeback = mode != 0; preIndex = mode == 3
        } else if word & 0xfe000000 == 0xac000000 {
            let mode = (word >> 23) & 3
            guard mode != 0 else { return nil } // Non-temporal pairs stay outside admission.
            let raw = Int64((word >> 15) & 127)
            offset = (raw >= 64 ? raw - 128 : raw) * 16
            vectors.append("q\((word >> 10) & 31)")
            guard !load || vectors[0] != vectors[1] else { return nil } // Constrained-unpredictable LDP.
            expectedMnemonic = load ? "ldp" : "stp"; writeback = mode != 2; preIndex = mode == 3
        } else { return nil } // Register-index and other memory forms stay refused.
        guard mnemonic == expectedMnemonic,
              exactVectorMemoryText(source.operands, vectors: vectors, base: base,
                  offset: offset, writeback: writeback, preIndex: preIndex) else { return nil }
        return .memory(vectors: vectors, base: base, offset: offset,
                      writeback: writeback, preIndex: preIndex, load: load)
    }

    private static func exactVectorMemoryText(_ text: String, vectors: [String], base: String,
                                             offset: Int64, writeback: Bool, preIndex: Bool) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        let prefix = vectors.joined(separator: ",") + ",["
        guard compact.hasPrefix(prefix) else { return false }
        let address = String(compact.dropFirst(prefix.count))
        func immediate(_ text: Substring) -> Int64? {
            guard text.hasPrefix("#") else { return nil }
            var digits = text.dropFirst()
            let negative = digits.hasPrefix("-")
            if negative { digits = digits.dropFirst() }
            let hex = digits.hasPrefix("0x")
            if hex { digits = digits.dropFirst(2) }
            let alphabet = hex ? "0123456789abcdef" : "0123456789"
            guard !digits.isEmpty, digits.allSatisfy({ alphabet.contains($0) }),
                  let value = Int64(digits, radix: hex ? 16 : 10) else { return nil }
            return negative ? -value : value
        }
        if writeback && !preIndex {
            let prefix = base + "],"
            return address.hasPrefix(prefix) && immediate(address.dropFirst(prefix.count)) == offset
        }
        let suffix = preIndex ? "]!" : "]"
        guard address.hasSuffix(suffix) else { return false }
        let parts = address.dropLast(suffix.count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.first == Substring(base) else { return false }
        if parts.count == 1 { return !writeback && offset == 0 }
        return parts.count == 2 && immediate(parts[1]) == offset
    }

    static func ssaExactVectorEffects(_ exact: SSAExactVector, address: UInt64) -> MacIRSSA.RowEffects {
        var reads = MacIRSSA.CellSet([])
        var views: [Int: MacIRSSA.ScalarView] = [:]
        var writes: [MacIRSSA.Write] = []
        func read(_ cell: Int, _ view: MacIRSSA.ScalarView) { reads.insert(cell); views[cell] = view }
        func write(_ cell: Int, _ view: MacIRSSA.ScalarView) {
            writes.append(.init(cell: cell, bitWidth: 64, view: view, origin: .instruction(address)))
        }
        switch exact {
        case let .indexedStore(indexed):
            // Both payload halves and both address registers precede the store;
            // only the existing memory epoch is defined, never Vd/base/index.
            read(ssaCell(for: indexed.base)!, .integer)
            read(ssaCell(for: indexed.index)!, .integer)
            let vector = Int(indexed.vector.dropFirst())!
            read(32 + vector, .bits); read(64 + vector, .bits)
            read(97, .memoryEpoch); write(97, .memoryEpoch)
        case let .immediate(register, _):
            write(32 + register, .bits); write(64 + register, .bits)
        case let .memory(vectors, base, _, writeback, _, load):
            let cell = ssaCell(for: base)!
            read(cell, .integer); read(97, .memoryEpoch)
            if !load { write(97, .memoryEpoch) }
            for vector in vectors {
                let index = Int(vector.dropFirst())!
                if load {
                    write(32 + index, .bits); write(64 + index, .bits)
                } else {
                    read(32 + index, .bits); read(64 + index, .bits)
                }
            }
            if writeback { write(cell, .integer) }
        }
        return .init(address: address, reads: reads, writes: writes.sorted { $0.cell < $1.cell },
                     readViews: views, refusals: [])
    }

    static func liftSSAExactVector(_ exact: SSAExactVector, source: MacIRSourceSpan,
                                   state: inout BuilderState) -> [MacIRInstruction]? {
        switch exact {
        case let .indexedStore(indexed):
            guard state.ssaExactNumericInputsAvailable,
                  let base = state.ssaValue(for: indexed.base),
                  let index = state.ssaValue(for: indexed.index),
                  let vector = state.ssaValue(for: indexed.vector),
                  isPureValue(base), isPureValue(index), isPureValue(vector),
                  let memory = MacIRNEONIndexedMemory(effect: .store,
                    baseRegister: indexed.base, indexRegister: indexed.index,
                    base: base, index: index, indexExtension: .lsl, shift: 0, sequence: 0) else { return nil }
            // Capture payload/address before invalidating possibly aliased stack
            // values. No writeback or strong fault/atomicity claim is introduced.
            state.invalidateAllStackSlotValues()
            return [.init(source: source, operation: .store(source: vector, address: memory.address),
                          memoryAccess: .init(byteWidth: 16), neonIndexedMemory: memory)]
        case let .immediate(register, value):
            guard let low = state.ssa?.writes[32 + register]?.value,
                  let high = state.ssa?.writes[64 + register]?.value else { return nil }
            // Definitions are the two physical halves, not an opaque intrinsic.
            // A 64-bit arrangement's high definition is already the constant zero.
            _ = state.writeRegister("v\(register)")
            var result = [MacIRInstruction(source: source, operation: .assign(destination: low,
                source: .immediate(Int64(bitPattern: value.low))))]
            if high != .immediate(0) {
                result.append(.init(source: source, operation: .assign(destination: high,
                    source: .immediate(Int64(bitPattern: value.high)))))
            }
            return result
        case let .memory(vectors, base, offset, writeback, preIndex, load):
            // Validate every destination before installing any write or changing state.
            var destinations: [(low: MacIRValue, high: MacIRValue, whole: MacIRValue)] = []
            if load {
                for vector in vectors {
                    let index = Int(vector.dropFirst())!
                    guard let low = state.ssa?.writes[32 + index]?.value,
                          let high = state.ssa?.writes[64 + index]?.value,
                          case let .register(_, version) = low else { return nil }
                    destinations.append((low, high, .register(name: vector, version: version)))
                }
            }
            let oldBase = state.readRegister(base)
            let values = load ? [] : vectors.map { state.readRegister($0) }
            func adding(_ delta: Int64) -> MacIRValue {
                if delta == 0 { return oldBase }
                return .binaryExpression(op: "+", left: oldBase, right: .immediate(delta))
            }
            // Even an uncertain alias cannot preserve a cached stack value.
            if !load { state.invalidateAllStackSlotValues() }
            let firstOffset = writeback && !preIndex ? 0 : offset
            var result: [MacIRInstruction] = []
            for (index, vector) in vectors.enumerated() {
                let address = adding(firstOffset + Int64(index * 16))
                if load {
                    let destination = destinations[index]
                    _ = state.writeRegister(vector)
                    result.append(.init(source: source, operation: .load(destination: destination.whole,
                        address: address), memoryAccess: .init(byteWidth: 16)))
                    result.append(.init(source: source, operation: .assign(destination: destination.low,
                        source: .unary(op: "__ssa_low64", value: destination.whole))))
                    result.append(.init(source: source, operation: .assign(destination: destination.high,
                        source: .unary(op: "__ssa_high64", value: destination.whole))))
                } else {
                    result.append(.init(source: source, operation: .store(source: values[index],
                        address: address), memoryAccess: .init(byteWidth: 16)))
                }
            }
            if writeback {
                let destination = state.writeRegister(base)
                if base == "sp" {
                    state.recordExplicitStackWriteback(base)
                    state.recordStackDisplacement(delta: offset)
                }
                result.append(.init(source: source,
                    operation: .assign(destination: destination, source: adding(offset))))
            }
            return result
        }
    }
}

// exact residual forms. Helpers stay in this already compiled source.
extension MacIRBuilder {
    struct SSASnapshotSelect {
        enum Kind { case csel, csinc, cset, fcsel }
        let kind: Kind
        let destination: String
        let sources: [String]
        let condition: String
        let width: Int

        var isFP: Bool { if case .fcsel = kind { return true }; return false }

        func effects(address: UInt64) -> MacIRSSA.RowEffects {
            var cells = Set([96])
            var views: [Int: MacIRSSA.ScalarView] = [96: .flags]
            for source in sources {
                guard let view = MacIRBuilder.ssaRegisterView(for: source) else { continue }
                cells.insert(view.cell); views[view.cell] = isFP ? .float32 : .integer
            }
            let cell = MacIRBuilder.ssaCell(for: destination)!
            var writes = [MacIRSSA.Write(cell: cell, bitWidth: isFP ? 64 : width,
                view: isFP ? .float32 : .integer, origin: .instruction(address))]
            if isFP { writes.append(.init(cell: cell + 32, bitWidth: 64, view: .bits, origin: .instruction(address))) }
            return .init(address: address, reads: .init(cells), writes: writes, readViews: views, refusals: [])
        }

        // FCSEL inputs here are raw low32 bits. Integer inputs are exact GPR
        // views; all W results are zero-extended by the existing physical plan.
        func valueOperation(destination: MacIRValue, predicate: MacIRValue,
                            inputs: [MacIRValue]) -> MacIROperation? {
            guard inputs.count == sources.count else { return nil }
            if case .cset = kind {
                return .compareToBool(destination: destination, condition: "!=", left: predicate, right: .immediate(0))
            }
            let yes: MacIRValue, no: MacIRValue
            switch kind {
            case .csinc:
                yes = MacIRBuilder.ssaUnsignedProjection(inputs[0], width: 32)
                no = .immediate(1) // WZR + 1 modulo32, not the old destination.
            case .csel:
                yes = MacIRBuilder.ssaUnsignedProjection(inputs[0], width: 64)
                no = MacIRBuilder.ssaUnsignedProjection(inputs[1], width: 64)
            case .fcsel:
                // Arm2025-12 fcsel_float.xml:302–308 selects V bits and writes
                // scalar Vd (zeroing the rest). No FPCR, FPSR, rounding or QC.
                yes = .unary(op: "__ssa_bitcast_f32", value: MacIRBuilder.ssaUnsignedProjection(inputs[0], width: 32))
                no = .unary(op: "__ssa_bitcast_f32", value: MacIRBuilder.ssaUnsignedProjection(inputs[1], width: 32))
            case .cset: return nil
            }
            return .select(destination: destination, condition: "!=", left: predicate, right: .immediate(0),
                           trueValue: yes, falseValue: no)
        }

        func lift(predicate: MacIRValue, state: inout BuilderState) -> MacIROperation? {
            guard let context = state.ssa,
                  let cell = MacIRBuilder.ssaCell(for: destination),
                  let write = context.writes[cell], !write.isUnavailable else { return nil }
            var inputs: [MacIRValue] = []
            for source in sources {
                // Never fall back to a fabricated entry carrier when a planned
                // input is missing or an alias was clobbered by a returning call.
                guard let value = state.ssaValue(for: source), MacIRBuilder.isPureValue(value) else { return nil }
                inputs.append(isFP ? .unary(op: "__ssa_bitcast_u32", value: value) : value)
            }
            let result = state.writeRegister(destination)
            state.recordValueType(isFP ? "float" : width == 32 ? "uint32_t" : "uint64_t", for: result)
            return valueOperation(destination: result, predicate: predicate, inputs: inputs)
        }
    }

    static func ssaInstructionWord(_ source: MacIRSourceSpan) -> UInt32? {
        let tokens = source.byteText.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 4 else { return nil }
        var word: UInt32 = 0
        for (index, token) in tokens.enumerated() {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
            word |= UInt32(byte) << (index * 8)
        }
        return word
    }

    static func ssaUnsignedProjection(_ value: MacIRValue, width: Int) -> MacIRValue {
        .unary(op: "(uint\(width)_t)", value: value)
    }

    static func ssaSnapshotSelect(_ source: MacIRSourceSpan) -> SSASnapshotSelect? {
        guard ["csel", "csinc", "cset", "fcsel"].contains(source.mnemonic.lowercased()), let word = ssaInstructionWord(source) else { return nil }
        let d = Int(word & 31), n = Int((word >> 5) & 31), m = Int((word >> 16) & 31)
        let text = source.operands.lowercased().filter { !$0.isWhitespace }
        switch source.mnemonic.lowercased() {
        case "csel" where word & 0xffe0fc00 == 0x9a800000 && d < 31 && n < 31 && m < 31:
            guard text == "x\(d),x\(n),x\(m),eq" else { return nil }
            return .init(kind: .csel, destination: "x\(d)", sources: ["x\(n)", "x\(m)"], condition: "eq", width: 64)
        case "csinc" where word & 0xfffffc00 == 0x1a9f1400 && d < 31 && n < 31:
            guard text == "w\(d),w\(n),wzr,ne" else { return nil }
            return .init(kind: .csinc, destination: "w\(d)", sources: ["w\(n)"], condition: "ne", width: 32)
        case "cset" where word & 0xffffffe0 == 0x1a9f07e0 && d < 31:
            guard text == "w\(d),ne" else { return nil }
            return .init(kind: .cset, destination: "w\(d)", sources: [], condition: "ne", width: 32)
        case "fcsel" where word & 0xffe0fc00 == 0x1e200c00:
            guard text == "s\(d),s\(n),s\(m),eq" else { return nil }
            return .init(kind: .fcsel, destination: "s\(d)", sources: ["s\(n)", "s\(m)"], condition: "eq", width: 32)
        default: return nil
        }
    }

    static func ssaExactSignedInsert(_ source: MacIRSourceSpan) -> Bool {
        guard source.mnemonic.lowercased() == "sbfiz", let word = ssaInstructionWord(source),
              word & 0xfffffc00 == 0x937f7c00 else { return false }
        let d = Int(word & 31), n = Int((word >> 5) & 31), operands = splitOperands(source.operands.lowercased())
        return d < 31 && n < 31 && operands.count == 4 && operands[0] == "x\(d)" && operands[1] == "x\(n)"
            && parseImmediate(operands[2]) == 1 && parseImmediate(operands[3]) == 32
    }

    private struct SSAIndexedStoreSourceRow: DecompilerInstructionRow {
        let source: MacIRSourceSpan
        var address: UInt64 { source.address }
        var bytes: String { source.byteText }
        var mnemonic: String { source.mnemonic.lowercased() }
        var operands: String { source.operands }
        var comment: String? { source.comment }
        var structuredOperands: InstructionOperands? { source.structuredOperands }
    }

    static func ssaExactIndexedQStore(_ source: MacIRSourceSpan) -> NEONIndexedOperands? {
        guard source.mnemonic.lowercased() == "str",
              let parsed = neonIndexedMemory(SSAIndexedStoreSourceRow(source: source)),
              parsed.effect == .store, parsed.extensionKind == .lsl, parsed.shift == 0,
              parsed.index != "xzr" else { return nil }
        return parsed
    }

    struct SSANZCVSnapshot {
        let left: MacIRValue
        let right: MacIRValue
        let width: Int
        let guardDefinition: Int?
        let guardCondition: String?
        let fallback: UInt8?
        let numericInputs: Set<Int>
    }

    static func ssaNZCVSnapshot(_ source: MacIRSourceSpan, state: BuilderState,
                                      numericInputs: Set<Int>, reachingFlags: Int?) -> SSANZCVSnapshot? {
        guard ["cmp", "ccmp"].contains(source.mnemonic.lowercased()),
              state.ssa != nil, let word = ssaInstructionWord(source) else { return nil }
        let operands = splitOperands(source.operands.lowercased())
        let width = word & 0x80000000 == 0 ? 32 : 64
        let prefix = width == 32 ? "w" : "x"
        let n = Int((word >> 5) & 31), m = Int((word >> 16) & 31)
        func register(_ index: Int) -> String { index == 31 ? prefix + "zr" : prefix + String(index) }
        func captured(_ spelling: String) -> MacIRValue? {
            if spelling == "wzr" || spelling == "xzr" { return .immediate(0) }
            guard let value = state.ssaValue(for: spelling), isPureValue(value) else { return nil }
            return value
        }
        if source.mnemonic.lowercased() == "cmp", word & 0x7fe0fc1f == 0x6b00001f,
           operands == [register(n), register(m)], let left = captured(register(n)), let right = captured(register(m)) {
            return .init(left: left, right: right, width: width, guardDefinition: nil,
                         guardCondition: nil, fallback: nil, numericInputs: numericInputs)
        }
        if source.mnemonic.lowercased() == "cmp", word & 0x7f80001f == 0x7100001f, n < 31 {
            let shift = word & 0x00400000 == 0 ? 0 : 12
            let raw = Int64((word >> 10) & 4095), immediate = raw << shift
            let validImmediate = operands.count == 2 && parseImmediate(operands[1]) == immediate
                || operands.count == 3 && shift == 12 && parseImmediate(operands[1]) == raw
                    && operands[2].filter({ !$0.isWhitespace }) == "lsl#12"
            guard validImmediate, operands[0] == register(n), let left = captured(register(n)) else { return nil }
            return .init(left: left, right: .immediate(immediate), width: width, guardDefinition: nil,
                         guardCondition: nil, fallback: nil, numericInputs: numericInputs)
        }
        if source.mnemonic.lowercased() == "ccmp", word & 0x7fe00410 == 0x7a400000, operands.count == 4 {
            let conditions = ["eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"]
            let suffix = conditions[Int((word >> 12) & 15)]
            let spelled = operands[3] == "cs" ? "hs" : operands[3] == "cc" ? "lo" : operands[3]
            let immediate = word & 0x800 != 0
            let second = immediate ? "#\(m)" : register(m)
            let rightValue: MacIRValue? = immediate ? .immediate(Int64(m)) : captured(second)
            guard ssaNZCVConditionHolds(suffix, nzcv: 0) != nil,
                  operands[0] == register(n), spelled == suffix,
                  parseImmediate(operands[2]) == Int64(word & 15), let reachingFlags,
                  (immediate ? parseImmediate(operands[1]) == Int64(m) : operands[1] == second),
                  let left = captured(register(n)), let right = rightValue else { return nil }
            return .init(left: left, right: right, width: width, guardDefinition: reachingFlags,
                         guardCondition: suffix, fallback: UInt8(word & 15), numericInputs: numericInputs)
        }
        return nil
    }

    // Only these subtraction conditions are supported. In particular MI/PL
    // test N, not signed ordering, and remain refused rather than approximated.
    static func ssaNZCVConditionHolds(_ suffix: String, nzcv: UInt8) -> Bool? {
        let n = nzcv & 8 != 0, z = nzcv & 4 != 0, c = nzcv & 2 != 0, v = nzcv & 1 != 0
        switch suffix {
        case "eq": return z
        case "ne": return !z
        case "hs", "cs": return c
        case "lo", "cc": return !c
        case "hi": return c && !z
        case "ls": return !c || z
        case "ge": return n == v
        case "lt": return n != v
        case "gt": return !z && n == v
        case "le": return z || n != v
        default: return nil
        }
    }

    static func ssaNZCVSubtractionCondition(_ snapshot: SSANZCVSnapshot,
                                                  suffix: String) -> MacIRValue? {
        let relation: String
        switch suffix {
        case "eq": relation = "=="
        case "ne": relation = "!="
        case "hs", "cs", "ge": relation = ">="
        case "lo", "cc", "lt": relation = "<"
        case "hi", "gt": relation = ">"
        case "ls", "le": relation = "<="
        default: return nil
        }
        let left = ssaUnsignedProjection(snapshot.left, width: snapshot.width)
        let right = ssaUnsignedProjection(snapshot.right, width: snapshot.width)
        if ["ge", "lt", "gt", "le"].contains(suffix) {
            return .binaryExpression(op: relation,
                left: signedProjection(left, width: snapshot.width, partner: right),
                right: signedProjection(right, width: snapshot.width, partner: left))
        }
        return .binaryExpression(op: relation, left: left, right: right)
    }

    struct SSANZCVPredicateKey: Hashable {
        let definition: Int
        let condition: String
    }
    struct SSANZCVPredicate {
        let value: MacIRValue
        let numericInputs: Set<Int>
    }
    struct SSANZCVPredicateTransaction {
        let predicate: SSANZCVPredicate
        let memo: [SSANZCVPredicateKey: SSANZCVPredicate]
        let phis: [SSANZCVPredicateKey: MacIRPhi]
    }

    static func ssaNZCVCCMPCondition(guardValue: MacIRValue, term: MacIRValue,
                                     fallbackHolds: Bool) -> MacIRValue {
        // Both terms are pure Booleans. Fold only the immediate NZCV branch;
        // the caller retains all numeric roots even when the text gets shorter.
        fallbackHolds
            ? .binaryExpression(op: "||", left: .unary(op: "!", value: guardValue), right: term)
            : .binaryExpression(op: "&&", left: guardValue, right: term)
    }

    static func ssaNZCVPredicateValue(key: SSANZCVPredicateKey,
                                      occupiedValues: Set<MacIRValue>) -> MacIRValue {
        // Register overrides are version-agnostic: change the raw stem, not
        // just its SSA version, when any existing version occupies that stem.
        let occupied = Set(occupiedValues.compactMap { value -> String? in
            if case let .register(name, _) = value { return name.lowercased() }
            return nil
        })
        let base = "__mscope_nzcv_d\(key.definition)_\(key.condition)"
        var name = base, suffix = 0
        while occupied.contains(name) { suffix += 1; name = "\(base)_\(suffix)" }
        return .register(name: name, version: 0)
    }

    static func ssaNZCVPredicate(flags: Int, suffix: String,
        snapshots: [Int: SSANZCVSnapshot], plan: MacIRSSA.Plan, graph: MacIRCFG,
        sources: [MacIRSourceSpan], memo: [SSANZCVPredicateKey: SSANZCVPredicate],
        phis: [SSANZCVPredicateKey: MacIRPhi],
        occupiedValues: Set<MacIRValue>) -> SSANZCVPredicateTransaction? {
        // Every speculative memo/name/phi is local. The caller commits only
        // after all incoming predicates AND the payload/lift have succeeded.
        var localMemo = memo, localPhis = phis, active = Set<SSANZCVPredicateKey>()
        let flagPhis = Dictionary(plan.phis.filter { $0.cell == 96 }.map { (plan.canonicalID($0.destination), $0) },
                                 uniquingKeysWith: { first, _ in first })
        func resolve(_ definition: Int, _ condition: String) -> SSANZCVPredicate? {
            guard ssaNZCVConditionHolds(condition, nzcv: 0) != nil,
                  plan.definitions.indices.contains(definition) else { return nil }
            let id = plan.canonicalID(definition), key = SSANZCVPredicateKey(definition: id, condition: condition)
            // Deep or cyclic flag provenance stays refused instead of growing
            // the Swift call stack with unbounded hostile instruction chains.
            guard !active.contains(key), active.count < 64,
                  active.count <= plan.definitions.count else { return nil }
            if let found = localMemo[key] { return found }
            active.insert(key); defer { active.remove(key) }
            let result: SSANZCVPredicate
            if let snapshot = snapshots[id], let term = ssaNZCVSubtractionCondition(snapshot, suffix: condition) {
                if let incoming = snapshot.guardDefinition, let guardSuffix = snapshot.guardCondition,
                   let fallback = snapshot.fallback {
                    guard let guardTerm = resolve(incoming, guardSuffix),
                          let fallbackHolds = ssaNZCVConditionHolds(condition, nzcv: fallback) else { return nil }
                    result = .init(value: ssaNZCVCCMPCondition(guardValue: guardTerm.value,
                                        term: term, fallbackHolds: fallbackHolds),
                                   numericInputs: snapshot.numericInputs.union(guardTerm.numericInputs))
                } else {
                    result = .init(value: term, numericInputs: snapshot.numericInputs)
                }
            } else if let phi = flagPhis[id] {
                // Snapshot predicates require actual decoded predecessor edges;
                // a bounded function-entry input is not a machine flag producer.
                let machineInputs = phi.incoming.compactMap { edge -> (block: Int, address: UInt64, definition: Int)? in
                    guard case let .machine(block, address) = edge.predecessor else { return nil }
                    return (block, address, edge.definition)
                }
                guard graph.blocks.indices.contains(phi.block), !phi.incoming.isEmpty,
                      machineInputs.count == phi.incoming.count,
                      machineInputs.count == graph.blocks[phi.block].predecessors.count,
                      Set(machineInputs.map(\.block)) == Set(graph.blocks[phi.block].predecessors) else { return nil }
                var incoming: [MacIRPhi.Incoming] = [], roots = Set<Int>()
                for edge in machineInputs {
                    guard graph.blocks.indices.contains(edge.block),
                          let last = graph.blocks[edge.block].instructionRange.last,
                          sources.indices.contains(last), sources[last].address == edge.address,
                          let term = resolve(edge.definition, condition) else { return nil }
                    incoming.append(.init(predecessorAddress: edge.address, value: term.value))
                    roots.formUnion(term.numericInputs)
                }
                let name = ssaNZCVPredicateValue(key: key,
                    occupiedValues: occupiedValues.union(localPhis.values.map(\.destination)))
                localPhis[key] = .init(blockAddress: graph.blocks[phi.block].startAddress,
                    destination: name, bitWidth: 32, incoming: incoming)
                result = .init(value: name, numericInputs: roots)
            } else { return nil }
            localMemo[key] = result
            return result
        }
        guard let predicate = resolve(flags, suffix) else { return nil }
        return .init(predicate: predicate, memo: localMemo, phis: localPhis)
    }

    // A future plan definition is not evidence that its emitter will succeed.
    // Only these byte/text-exact, unconditional existing routes may close a
    // backedge before its source row has actually emitted a non-unknown value.
    static func ssaGuaranteedFutureNumericProducer(_ source: MacIRSourceSpan) -> Bool {
        guard let word = ssaInstructionWord(source) else { return false }
        let operands = splitOperands(source.operands.lowercased())
        let width = word & 0x80000000 == 0 ? 32 : 64, prefix = word & 0x80000000 == 0 ? "w" : "x"
        let d = Int(word & 31), n = Int((word >> 5) & 31), m = Int((word >> 16) & 31)
        if source.mnemonic.lowercased() == "mov", word & 0x7fe0ffe0 == 0x2a0003e0, d < 31 {
            let input = m == 31 ? prefix + "zr" : prefix + String(m)
            return operands == [prefix + String(d), input]
        }
        if source.mnemonic.lowercased() == "add", word & 0x7fc00000 == 0x11000000, d < 31, n < 31 {
            return operands.count == 3 && operands[0] == prefix + String(d) && operands[1] == prefix + String(n)
                && operands[2].hasPrefix("#") && parseImmediate(operands[2]) == Int64((word >> 10) & 4095)
                && scalarDataBitWidth(operands[0]) == width
        }
        if source.mnemonic.lowercased() == "add", word & 0xff20fc00 == 0x4e208400 {
            let size = Int((word >> 22) & 3)
            guard size <= 1,
                  let lane = ssaIntegerLaneOperation(mnemonic: "add", operands: source.operands),
                  lane.semantics.kind == .add, lane.semantics.activeBytes == 16,
                  lane.semantics.laneBits == (size == 0 ? 8 : 16) else { return false }
            let shape = size == 0 ? "16b" : "8h"
            return operands == ["v\(d).\(shape)", "v\(n).\(shape)", "v\(m).\(shape)"]
        }
        if case .immediate? = ssaExactVector(source) { return true }
        return false
    }

    /// A symbolic numeric-dependency check, not a constant-value or return proof.
    /// Calls/refused producers poison every phi path. Order-only memory epochs
    /// cannot poison a fresh load whose real numeric address inputs are usable.
    static func ssaNumericAncestryIsAvailable(roots: Set<Int>, plan: MacIRSSA.Plan,
        sources: [MacIRSourceSpan], graph: MacIRCFG, actualUnknownSources: Set<UInt64>,
        actualKnownSources: Set<UInt64> = [], actualCallResultDefinitions: Set<Int> = []) -> Bool {
        let sourceRows = Dictionary(sources.enumerated().map { ($0.element.address, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })
        let phis = Dictionary(plan.phis.map { (plan.canonicalID($0.destination), $0) },
                              uniquingKeysWith: { first, _ in first })
        let producerRows = Dictionary(plan.rowWriteBindings.enumerated().flatMap { row, writes in
            writes.values.map { (plan.canonicalID($0), row) }
        }, uniquingKeysWith: { first, _ in first })
        var adjacency: [Int: [Int]] = [:], seeds = Set<Int>(), pending = Array(roots)
        while let original = pending.popLast() {
            guard plan.definitions.indices.contains(original) else { return false }
            let id = plan.canonicalID(original)
            guard plan.definitions.indices.contains(id) else { return false }
            if adjacency[id] != nil { continue }
            guard adjacency.count < plan.definitions.count else { return false }
            let dependencies: [Int]
            switch plan.definitions[id].origin {
            case .callClobber, .refusal: return false
            case .entry: dependencies = []; seeds.insert(id)
            case .callResult:
                // A planned result is not an emitted call. No future call or
                // failed call may seed a backedge through a later MOV.
                guard let row = producerRows[id], sources.indices.contains(row),
                      actualKnownSources.contains(sources[row].address),
                      !actualUnknownSources.contains(sources[row].address),
                      actualCallResultDefinitions.contains(id) else { return false }
                dependencies = []; seeds.insert(id)
            case let .instruction(address):
                guard !actualUnknownSources.contains(address), let row = sourceRows[address],
                      plan.rowReadBindings.indices.contains(row),
                      actualKnownSources.contains(address) || ssaGuaranteedFutureNumericProducer(sources[row]) else { return false }
                dependencies = plan.rowReadBindings[row].filter { (0..<96).contains($0.key) }.map(\.value)
                if dependencies.isEmpty { seeds.insert(id) }
            case let .phi(block):
                guard let phi = phis[id], phi.block == block, graph.blocks.indices.contains(block),
                      !phi.incoming.isEmpty else { return false }
                let machineBlocks = phi.incoming.compactMap { edge -> Int? in
                    guard case let .machine(block, _) = edge.predecessor else { return nil }
                    return block
                }
                // Keep the existing machine-edge proof closed; virtual entry is
                // separately certified and does not authorize this numeric path.
                guard machineBlocks.count == phi.incoming.count,
                      machineBlocks.count == graph.blocks[block].predecessors.count,
                      Set(machineBlocks) == Set(graph.blocks[block].predecessors) else { return false }
                dependencies = phi.incoming.map(\.definition)
            }
            var canonical: [Int] = []
            for dependency in dependencies {
                guard plan.definitions.indices.contains(dependency) else { return false }
                canonical.append(plan.canonicalID(dependency))
            }
            adjacency[id] = canonical; pending.append(contentsOf: canonical)
        }
        // Iterative Kosaraju keeps recursion independent of function size.
        var visited = Set<Int>(), order: [Int] = [], reverse: [Int: [Int]] = [:]
        for (node, dependencies) in adjacency {
            for dependency in dependencies { reverse[dependency, default: []].append(node) }
        }
        for root in adjacency.keys.sorted() where !visited.contains(root) {
            var stack: [(Int, Bool)] = [(root, false)]
            while let (node, finished) = stack.popLast() {
                if finished { order.append(node); continue }
                guard visited.insert(node).inserted else { continue }
                stack.append((node, true))
                for dependency in adjacency[node] ?? [] where !visited.contains(dependency) { stack.append((dependency, false)) }
            }
        }
        var component: [Int: Int] = [:], members: [[Int]] = []
        for root in order.reversed() where component[root] == nil {
            let index = members.count; members.append([])
            var stack = [root]
            while let node = stack.popLast() {
                guard component[node] == nil else { continue }
                component[node] = index; members[index].append(node)
                stack.append(contentsOf: reverse[node] ?? [])
            }
        }
        for (index, nodes) in members.enumerated() {
            let cyclic = nodes.count > 1 || nodes.contains { adjacency[$0]?.contains($0) == true }
            if cyclic {
                let anchored = nodes.contains { node in
                    seeds.contains(node) || (adjacency[node] ?? []).contains { component[$0] != index }
                }
                if !anchored { return false }
            }
        }
        return true
    }

    static func ssaNZCVPredicateNameBindings(function: MacIRFunction,
        predicates: [(key: SSANZCVPredicateKey, value: MacIRPhi)],
        additionalValues: [MacIRValue] = []) -> [MacIRNameBinding] {
        let proposals = predicates.sorted { a, b in
            a.key.definition == b.key.definition ? a.key.condition < b.key.condition : a.key.definition < b.key.definition
        }.compactMap { key, phi -> (target: MacIRNameBindingTarget, stem: String)? in
            guard case let .register(register, version) = phi.destination else { return nil }
            return (.register(name: register, version: version), "nzcv_predicate_d\(key.definition)_\(key.condition)")
        }
        return ssaNZCVAllocatedNameBindings(function: function, proposals: proposals,
            additionalValues: additionalValues, reservedDisplayNames: [])
    }

    static func ssaNZCVPrintedPredicateNameBindings(function: MacIRFunction,
        registerNameOverrides: [String: String], callTargetRenames: [String: String]) -> [MacIRNameBinding] {
        guard let info = function.ssaInfo, !info.generatedNZCVPredicateTargets.isEmpty else { return [] }
        let targets = info.generatedNZCVPredicateTargets.intersection(function.phis.map(\.destination))
        let typedTargets = Set(targets.compactMap { value -> MacIRNameBindingTarget? in
            if case let .register(name, version) = value { return .register(name: name, version: version) }
            return nil
        })
        let proposals = function.nameBindings.filter { typedTargets.contains($0.target) }
            .map { (target: $0.target, stem: $0.name) }
        // Exclude only explicit, committed generated targets. Generic authored
        // bindings with any similar spelling remain occupied, never reclassified.
        var inventory = function
        inventory.nameBindings.removeAll { typedTargets.contains($0.target) }
        return ssaNZCVAllocatedNameBindings(function: inventory, proposals: proposals,
            additionalValues: Array(info.values.values),
            reservedDisplayNames: Array(registerNameOverrides.values) + Array(callTargetRenames.values))
    }

    private static func ssaNZCVAllocatedNameBindings(function: MacIRFunction,
        proposals: [(target: MacIRNameBindingTarget, stem: String)],
        additionalValues: [MacIRValue], reservedDisplayNames: [String]) -> [MacIRNameBinding] {
        guard !proposals.isEmpty else { return [] }
        var occupied = Set<String>()
        func reserve(_ text: String) {
            occupied.insert(text)
            // Extra reservation, not a rewrite of authored text. The printer's
            // ordinary formal/local/binding paths use raw names, not a sanitizer.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalized = String(trimmed.unicodeScalars.map { scalar -> Character in
                let n = scalar.value
                return n == 95 || (48...57).contains(n) || (65...90).contains(n) || (97...122).contains(n)
                    ? Character(String(scalar)) : "_"
            })
            if let first = normalized.utf8.first, (48...57).contains(first) { normalized = "_" + normalized }
            occupied.insert(normalized)
        }
        [function.name].forEach(reserve)
        function.callTargets.forEach(reserve)
        function.parameters.map(\.name).forEach(reserve)
        function.localVariables.map(\.name).forEach(reserve)
        function.nameBindings.map(\.name).forEach(reserve)
        reservedDisplayNames.forEach(reserve)
        var pending = additionalValues
        if let value = function.returnValue { pending.append(value) }
        for binding in function.nameBindings {
            if case let .register(name, version) = binding.target { pending.append(.register(name: name, version: version)) }
        }
        for phi in function.phis { pending.append(phi.destination); pending.append(contentsOf: phi.incoming.map(\.value)) }
        // Inventory every operation case, including the stack-value and unknown
        // forms omitted by narrower semantic-use collectors. This grants no use proof.
        for instruction in function.instructions {
            if let target = instruction.returnTarget { pending.append(target) }
            switch instruction.operation {
            case let .assign(a, b), let .load(a, b), let .store(a, b): pending += [a, b]
            case let .binary(a, op, b, c), let .compareToBool(a, op, b, c): reserve(op); pending += [a, b, c]
            case let .loadWriteback(a, b, c, _, _), let .storeWriteback(a, b, c, _, _),
                 let .stackSlotRead(a, b, c): pending += [a, b, c]
            case let .stackSlotPairRead(a, b, c, d, e, f): pending += [a, b, c, d, e, f]
            case let .call(frame, result):
                reserve(frame.target); pending += frame.bindingValues
                if let result { pending.append(result) }
            case let .conditionalBranch(op, a, b, c): reserve(op); pending += [a, b, c]
            case let .select(a, op, b, c, d, e): reserve(op); pending += [a, b, c, d, e]
            case let .returnValue(value): if let value { pending.append(value) }
            case let .intrinsic(destination, name, arguments):
                reserve(name); pending += arguments
                if let destination { pending.append(destination) }
            case let .switchDispatch(index, cases, defaultTarget):
                pending.append(index); pending += cases.map(\.target)
                if let defaultTarget { pending.append(defaultTarget) }
            case let .unknown(destination, inputs, _, _):
                if let destination { pending.append(destination) }
                pending += inputs.mayRead.map(\.value) + inputs.definiteRead.map(\.value)
            }
        }
        // Explicitly cover every printable value case. In particular an unknown
        // text or an ABI composite can contain names invisible to collectAtoms.
        while let value = pending.popLast() {
            switch value {
            case let .register(name, _): reserve(name); reserve(value.description)
            case let .symbol(name), let .unknown(name): reserve(name)
            case let .abiComposite(type, fragments): reserve(type); pending += fragments
            case let .bitTest(inner, _): pending.append(inner)
            case let .unary(op, inner): reserve(op); pending.append(inner)
            case let .binaryExpression(op, left, right): reserve(op); pending += [left, right]
            case let .signedBitfield(field): reserve(field.helperName); pending.append(field.source)
            case .argument, .argumentFragment, .immediate, .stackSlot, .temporary: reserve(value.description)
            }
        }
        var result: [MacIRNameBinding] = []
        for (target, base) in proposals {
            var name = base, suffix = 0
            while occupied.contains(name) { suffix += 1; name = "\(base)_\(suffix)" }
            reserve(name)
            result.append(.init(target: target, name: name, type: "int32_t", kind: .registerTemporary))
        }
        return result
    }
}
