import Foundation

/// Per-row Advanced SIMD lifting for the D06 general region path. Each row is
/// admitted alone from its decoded mnemonic and exact operand arrangements;
/// nothing here depends on neighbouring rows or on a function's shape.
extension MacIRBuilder {
    struct NEONWideningPairwiseOperands {
        let destination: String
        let source: String
        let semantics: MacIRNEONWideningPairwise
    }

    /// One exact accumulating byte-pair form. The retained descriptor owns
    /// arithmetic; encoded registers and arrangements must agree with the text.
    static func neonWideningPairwise(_ source: MacIRSourceSpan) -> NEONWideningPairwiseOperands? {
        guard source.mnemonic.lowercased() == "uadalp" else { return nil }
        let tokens = source.byteText.split(separator: " ")
        guard tokens.count == 4 else { return nil }
        var word: UInt32 = 0
        for (index, token) in tokens.enumerated() {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
            word |= UInt32(byte) << (index * 8)
        }
        // Q=1, U=1, size=00: UADALP Vd.8H, Vn.16B. Neither Q=0 nor
        // another lane width borrows this admission from a similar spelling.
        guard word & 0xfffffc00 == 0x6e206800 else { return nil }
        let destination = "v\(word & 31)"
        let input = "v\((word >> 5) & 31)"
        let operands = source.operands.lowercased().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard operands == [destination + ".8h", input + ".16b"],
              let semantics = MacIRNEONWideningPairwise(kind: .uadalp, sourceElementBytes: 1,
                                                       activeBytes: 16) else { return nil }
        return .init(destination: destination, source: input, semantics: semantics)
    }

    /// Snapshot both inputs before installing the new destination, including
    /// Vd == Vn. The existing descriptor's argument order is narrow, then old Vd.
    static func liftNEONWideningPairwise(_ parsed: NEONWideningPairwiseOperands,
        source: MacIRSourceSpan, state: inout BuilderState) -> MacIRInstruction {
        let input = state.readRegister(parsed.source)
        let oldDestination = state.readRegister(parsed.destination)
        let destination = state.writeRegister(parsed.destination)
        return .init(source: source,
            operation: .intrinsic(destination: destination, name: "integer_widening_pairwise",
                                  arguments: [input, oldDestination]),
            neonWideningPairwise: parsed.semantics)
    }

    struct NEONLaneOperands: Equatable {
        let semantics: MacIRNEONLaneOp
        /// v-register names: destination, then sources in argument order.
        let destination: String
        let sources: [String]
    }

    private static func laneVector(_ operand: String) -> (name: String, arrangement: String)? {
        let parts = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = vectorRegisterIndex(String(parts[0])),
              String(parts[0]) == "v\(index)" else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// `vN.t[i]` → the register, lane width and index.
    private static func laneElement(_ operand: String) -> (register: String, bits: Int, index: Int)? {
        let text = operand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let dot = text.firstIndex(of: "."), let open = text.firstIndex(of: "["), text.hasSuffix("]"),
              dot < open else { return nil }
        let register = String(text[..<dot])
        guard let vIndex = vectorRegisterIndex(register), register == "v\(vIndex)",
              let bits = ["b": 8, "h": 16, "s": 32, "d": 64][String(text[text.index(after: dot)..<open])],
              let index = Int(text[text.index(after: open)..<text.index(before: text.endIndex)]),
              (0..<(128 / bits)).contains(index) else { return nil }
        return (register, bits, index)
    }

    private static func laneArrangement(_ bits: Int, bytes: Int) -> String {
        "\(bytes * 8 / bits)\([8: "b", 16: "h", 32: "s", 64: "d"][bits]!)"
    }

    private static func laneShiftImmediate(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = trimmed.dropFirst()
        let value = body.hasPrefix("0x") ? Int(body.dropFirst(2), radix: 16) : Int(body)
        return value
    }

    static func neonLaneOperation(mnemonic rawMnemonic: String, operandText: String) -> NEONLaneOperands? {
        let mnemonic = rawMnemonic.lowercased()
        let operands = operandText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Immediate shifts are unary lane operations, not variable shifts.
        let immediateShifts: [String: MacIRNEONLaneOp.Kind] = [
            "shl": .shl, "srshr": .srshr, "sqshlu": .sqshlu, "ushr": .ushr, "sshr": .sshr,
            "urshr": .urshr, "usra": .usra, "ssra": .ssra, "ursra": .ursra,
            "srsra": .srsra, "sri": .sri]
        if let kind = immediateShifts[mnemonic] {
            guard operands.count == 3, let destination = laneVector(operands[0]),
                  let source = laneVector(operands[1]), destination.arrangement == source.arrangement,
                  let shift = laneShiftImmediate(operands[2]) else { return nil }
            let table: [String: (Int, Int)] = ["8b": (8, 8), "16b": (8, 16), "4h": (16, 8), "8h": (16, 16),
                                               "2s": (32, 8), "4s": (32, 16), "2d": (64, 16)]
            guard let (bits, bytes) = table[destination.arrangement],
                  let semantics = MacIRNEONLaneOp(kind: kind,
                                                  isSigned: false, laneBits: bits, highHalf: false,
                                                  activeBytes: bytes, shift: shift) else { return nil }
            return .init(semantics: semantics, destination: destination.name, sources: [source.name])
        }

        // Same-width forms: the register arrangement selects lane width.
        // By-element forms: `Vd.T, Vn.T, Vm.<e>[k]` with the element size of T.
        let byElement: [String: MacIRNEONLaneOp.Kind] = ["sqdmulh": .sqdmulh, "sqrdmulh": .sqrdmulh,
                                                         "mul": .mul, "mla": .mla, "mls": .mls]
        // `dup Vd.T, Vn.t[i]` and the scalar `mov|dup Bd|Hd|Sd|Dd, Vn.t[i]`:
        // broadcast (or move) one lane of a vector.
        if mnemonic == "dup" || mnemonic == "mov", operands.count == 2,
           let element = laneElement(operands[1]) {
            let laneBits = element.bits
            let vectorBytes: [String: Int] = ["8b": 8, "16b": 16, "4h": 8, "8h": 16, "2s": 8, "4s": 16, "2d": 16]
            if mnemonic == "dup", let destination = laneVector(operands[0]),
               let bytes = vectorBytes[destination.arrangement],
               ["b": 8, "h": 16, "s": 32, "d": 64][String(destination.arrangement.suffix(1))] == laneBits,
               let semantics = MacIRNEONLaneOp(kind: .dup, isSigned: false, laneBits: laneBits,
                                               highHalf: false, activeBytes: bytes, elementIndex: element.index) {
                return .init(semantics: semantics, destination: destination.name, sources: [element.register])
            }
            let scalar = operands[0].trimmingCharacters(in: .whitespaces).lowercased()
            if let prefix = scalar.first, let index = Int(scalar.dropFirst()), (0...31).contains(index),
               scalar == "\(prefix)\(index)",
               ["b": 8, "h": 16, "s": 32, "d": 64][String(prefix)] == laneBits,
               let semantics = MacIRNEONLaneOp(kind: .dup, isSigned: false, laneBits: laneBits,
                                               highHalf: false, activeBytes: laneBits / 8,
                                               elementIndex: element.index) {
                return .init(semantics: semantics, destination: "v\(index)", sources: [element.register])
            }
        }
        // Scalar saturating forms: `sq(r)dmulh Hd|Sd, Hn|Sn, Hm|Sm|Vm.t[i]` and
        // `sqxtun Bd|Hd|Sd, Hn|Sn|Dn`; one lane, the rest of Vd zeroed.
        func scalarRegister(_ operand: String) -> (letter: Character, index: Int)? {
            let text = operand.trimmingCharacters(in: .whitespaces).lowercased()
            guard let letter = text.first, "bhsd".contains(letter), let index = Int(text.dropFirst()),
                  (0...31).contains(index), text == "\(letter)\(index)" else { return nil }
            return (letter, index)
        }
        let scalarBits: [Character: Int] = ["b": 8, "h": 16, "s": 32, "d": 64]
        if ["sqdmulh", "sqrdmulh"].contains(mnemonic), operands.count == 3,
           let d = scalarRegister(operands[0]), let n = scalarRegister(operands[1]), d.letter == n.letter,
           let bits = scalarBits[d.letter] {
            let kind: MacIRNEONLaneOp.Kind = mnemonic == "sqdmulh" ? .sqdmulh : .sqrdmulh
            if let m = scalarRegister(operands[2]), m.letter == d.letter,
               let semantics = MacIRNEONLaneOp(kind: kind, isSigned: false, laneBits: bits,
                                               highHalf: false, activeBytes: bits / 8) {
                return .init(semantics: semantics, destination: "v\(d.index)", sources: ["v\(n.index)", "v\(m.index)"])
            }
            if let element = laneElement(operands[2]), element.bits == bits,
               let semantics = MacIRNEONLaneOp(kind: kind, isSigned: false, laneBits: bits, highHalf: false,
                                               activeBytes: bits / 8, elementIndex: element.index) {
                return .init(semantics: semantics, destination: "v\(d.index)", sources: ["v\(n.index)", element.register])
            }
        }
        if mnemonic == "sqxtun", operands.count == 2,
           let d = scalarRegister(operands[0]), let n = scalarRegister(operands[1]),
           let bits = scalarBits[d.letter], scalarBits[n.letter] == bits * 2,
           let semantics = MacIRNEONLaneOp(kind: .sqxtun, isSigned: false, laneBits: bits,
                                           highHalf: false, activeBytes: bits / 8) {
            return .init(semantics: semantics, destination: "v\(d.index)", sources: ["v\(n.index)"])
        }
        // `dup Vd.T, Wn|Xn`: broadcast a general register's low lane bits.
        if mnemonic == "dup", operands.count == 2, let destination = laneVector(operands[0]) {
            let gpr = operands[1].lowercased()
            let table: [String: (Int, Int)] = ["8b": (8, 8), "16b": (8, 16), "4h": (16, 8), "8h": (16, 16),
                                               "2s": (32, 8), "4s": (32, 16), "2d": (64, 16)]
            guard let (bits, bytes) = table[destination.arrangement],
                  let prefix = gpr.first, prefix == (bits == 64 ? "x" : "w"),
                  let index = Int(gpr.dropFirst()), (0...30).contains(index), gpr == "\(prefix)\(index)",
                  let semantics = MacIRNEONLaneOp(kind: .dup, isSigned: false, laneBits: bits,
                                                  highHalf: false, activeBytes: bytes) else { return nil }
            return .init(semantics: semantics, destination: destination.name, sources: [gpr])
        }
        if let kind = byElement[mnemonic], operands.count == 3,
           let destination = laneVector(operands[0]), let source = laneVector(operands[1]),
           destination.arrangement == source.arrangement {
            let element = operands[2].lowercased()
            if let dot = element.firstIndex(of: "."), let open = element.firstIndex(of: "["),
               element.hasSuffix("]") {
                let register = String(element[..<dot])
                let letter = String(element[element.index(after: dot)..<open])
                let indexText = element[element.index(after: open)..<element.index(before: element.endIndex)]
                let table: [String: (Int, Int, String)] = ["4h": (16, 8, "h"), "8h": (16, 16, "h"),
                                                          "2s": (32, 8, "s"), "4s": (32, 16, "s")]
                guard let vIndex = vectorRegisterIndex(register), register == "v\(vIndex)",
                      let (bits, bytes, expected) = table[destination.arrangement], letter == expected,
                      bits != 16 || vIndex < 16,
                      let lane = Int(indexText),
                      let semantics = MacIRNEONLaneOp(kind: kind, isSigned: false, laneBits: bits,
                                                      highHalf: false, activeBytes: bytes, elementIndex: lane)
                else { return nil }
                return .init(semantics: semantics, destination: destination.name, sources: [source.name, register])
            }
        }
        let sameWidth: [String: MacIRNEONLaneOp.Kind] = ["add": .add, "sub": .sub, "mvn": .not, "not": .not, "sqdmulh": .sqdmulh, "sqrdmulh": .sqrdmulh,
                                                         "mul": .mul, "mla": .mla, "mls": .mls, "addp": .addp, "bif": .bif,
                                                         "cmeq": .cmeq, "cmgt": .cmgt, "cmge": .cmge,
                                                         "cmhi": .cmhi, "cmhs": .cmhs, "cmtst": .cmtst,
                                                         "neg": .neg, "abs": .abs, "ushl": .ushl, "sshl": .sshl,
                                                         "uzp1": .uzp1, "uzp2": .uzp2, "zip1": .zip1, "zip2": .zip2,
                                                         "trn1": .trn1, "trn2": .trn2]
        let compareZero: [String: MacIRNEONLaneOp.Kind] = ["cmeq": .cmeqz, "cmge": .cmgez, "cmgt": .cmgtz,
                                                           "cmle": .cmlez, "cmlt": .cmltz]
        // Compare-with-zero forms end in a literal `#0`; otherwise use the register form.
        let zeroCompare = compareZero[mnemonic].flatMap { kind in
            operands.count == 3 && ["#0", "#0x0"].contains(operands[2].lowercased()) ? kind : nil
        }
        if let kind = zeroCompare ?? sameWidth[mnemonic] {
            let semanticsSources = MacIRNEONLaneOp(kind: kind, isSigned: false, laneBits: 8, highHalf: false,
                                                   activeBytes: 16)?.sourceCount ?? 2
            let count = semanticsSources + 1
            guard operands.count == count + (zeroCompare != nil ? 1 : 0) else { return nil }
            let vectors = operands.prefix(count).compactMap(laneVector)
            guard vectors.count == count, Set(vectors.map(\.arrangement)).count == 1 else { return nil }
            let table: [String: (Int, Int)] = ["8b": (8, 8), "16b": (8, 16), "4h": (16, 8), "8h": (16, 16),
                                               "2s": (32, 8), "4s": (32, 16), "2d": (64, 16)]
            guard let (bits, bytes) = table[vectors[0].arrangement],
                  let semantics = MacIRNEONLaneOp(kind: kind, isSigned: false, laneBits: bits,
                                                  highHalf: false, activeBytes: bytes) else { return nil }
            return .init(semantics: semantics, destination: vectors[0].name, sources: vectors.dropFirst().map(\.name))
        }

        var base = mnemonic
        let highHalf = base.hasSuffix("2")
        if highHalf { base.removeLast() }
        var isSigned = false
        let kind: MacIRNEONLaneOp.Kind
        if let binaryNarrow = MacIRNEONLaneOp.Kind(rawValue: base),
           binaryNarrow.shape == .binaryNarrow {
            kind = binaryNarrow
        } else if ["shrn", "rshrn", "sqshrn", "sqrshrn", "sqxtun", "xtn"].contains(base) {
            guard let parsed = MacIRNEONLaneOp.Kind(rawValue: base) else { return nil }
            kind = parsed
        } else if base == "uxtl" || base == "sxtl" {
            isSigned = base.first == "s"; kind = .shll
        } else {
            guard let first = base.first, first == "s" || first == "u",
                  let parsed = MacIRNEONLaneOp.Kind(rawValue: base == "sshll" || base == "ushll"
                      ? "shll" : String(base.dropFirst())),
                  parsed.shape != .same, parsed.shape != .narrow, parsed.shape != .binaryNarrow else { return nil }
            isSigned = first == "s"; kind = parsed
        }

        // Indexed long multiply: Q selects only Vn's half. Vm's selected
        // element is always indexed across all 128 bits, independently of Q.
        if [.mull, .mlal, .mlsl].contains(kind), operands.count == 3,
           operands[2].contains("[") {
            guard let destination = laneVector(operands[0]), let source = laneVector(operands[1]) else { return nil }
            let element = operands[2].lowercased()
            guard let dot = element.firstIndex(of: "."), let open = element.firstIndex(of: "["),
                  dot < open, element.hasSuffix("]") else { return nil }
            let register = String(element[..<dot])
            let letter = String(element[element.index(after: dot)..<open])
            let indexText = element[element.index(after: open)..<element.index(before: element.endIndex)]
            guard let registerIndex = vectorRegisterIndex(register), register == "v\(registerIndex)",
                  let bits = ["h": 16, "s": 32][letter], bits != 16 || registerIndex < 16,
                  let index = Int(indexText), String(index) == indexText,
                  destination.arrangement == laneArrangement(bits * 2, bytes: 16),
                  source.arrangement == laneArrangement(bits, bytes: highHalf ? 16 : 8),
                  let semantics = MacIRNEONLaneOp(kind: kind, isSigned: isSigned, laneBits: bits,
                                                  highHalf: highHalf, elementIndex: index) else { return nil }
            return .init(semantics: semantics, destination: destination.name, sources: [source.name, register])
        }

        let vectorCount: Int
        switch kind.shape {
        case .long, .wide, .binaryNarrow: vectorCount = 3
        case .shiftLong, .narrow: vectorCount = 2
        case .same: return nil
        }
        let hasShift = (kind.shape == .narrow && kind != .sqxtun && kind != .xtn)
            || (kind == .shll && !(base == "uxtl" || base == "sxtl"))
        guard operands.count == vectorCount + (hasShift ? 1 : 0) else { return nil }
        let vectors = operands.prefix(vectorCount).compactMap(laneVector)
        guard vectors.count == vectorCount else { return nil }
        let shift = hasShift ? laneShiftImmediate(operands[vectorCount]) : 0
        guard let shift else { return nil }

        // Narrow lane width comes from the destination (narrow forms) or the
        // narrow source; every other arrangement must then match exactly.
        let narrowBytes = highHalf ? 16 : 8
        let candidates = [8, 16, 32]
        guard let laneBits = candidates.first(where: { bits in
            let narrow = laneArrangement(bits, bytes: narrowBytes)
            let wide = laneArrangement(bits * 2, bytes: 16)
            switch kind.shape {
            case .long: return vectors.map(\.arrangement) == [wide, narrow, narrow]
            case .wide: return vectors.map(\.arrangement) == [wide, wide, narrow]
            case .shiftLong: return vectors.map(\.arrangement) == [wide, narrow]
            case .narrow: return vectors.map(\.arrangement) == [narrow, wide]
            case .binaryNarrow: return vectors.map(\.arrangement) == [narrow, wide, wide]
            case .same: return false
            }
        }), let semantics = MacIRNEONLaneOp(kind: kind, isSigned: isSigned, laneBits: laneBits,
                                            highHalf: highHalf, shift: shift) else { return nil }
        return .init(semantics: semantics, destination: vectors[0].name, sources: vectors.dropFirst().map(\.name))
    }

    /// The scalar DUP-element subset whose B/H/S/D destination shares Vd.
    /// Do not use all lane operations here: scalar saturating forms remain
    /// outside the general region's scalar-view admission contract.
    static func scalarDupElementOperation(mnemonic: String, operandText: String) -> NEONLaneOperands? {
        guard mnemonic.lowercased() == "mov" || mnemonic.lowercased() == "dup",
              let parsed = neonLaneOperation(mnemonic: mnemonic, operandText: operandText),
              parsed.semantics.kind == .dup,
              parsed.semantics.activeBytes * 8 == parsed.semantics.laneBits,
              let index = parsed.semantics.elementIndex,
              parsed.sources.count == 1 else { return nil }
        let operands = operandText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard operands.count == 2, let letter = operands[0].first,
              "bhsd".contains(letter),
              let destination = bitViewRegister(operands[0], prefixes: "bhsd", maximum: 31),
              parsed.destination == "v\(destination)",
              operands[1] == "\(parsed.sources[0]).\(letter)[\(index)]" else { return nil }
        return parsed
    }

    static func liftNEONLane(_ parsed: NEONLaneOperands, state: inout BuilderState) -> MacIROperation {
        // Every input, including the old destination, is read before the write;
        // equal names intentionally keep equal SSA inputs.
        var arguments = parsed.sources.map { state.readRegister($0) }
        if parsed.semantics.readsDestination { arguments.append(state.readRegister(parsed.destination)) }
        let destination = state.writeRegister(parsed.destination)
        return .intrinsic(destination: destination, name: parsed.semantics.intrinsicName, arguments: arguments)
    }

    /// MOVI/MVNI modified immediates share one typed vector constant; MSL is not LSL.
    static func neonMoveImmediate(mnemonic: String, operandText: String) -> (destination: String, semantics: MacIRNEONImmediate)? {
        let lowered = mnemonic.lowercased()
        guard lowered == "movi" || lowered == "mvni" else { return nil }
        let operands = operandText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard (2...3).contains(operands.count), let vector = laneVector(operands[0]) else { return nil }
        let table: [String: (Int, Int)] = ["8b": (8, 8), "16b": (8, 16), "4h": (16, 8), "8h": (16, 16),
                                           "2s": (32, 8), "4s": (32, 16), "2d": (64, 16)]
        guard let (bits, bytes) = table[vector.arrangement] else { return nil }
        let immediateText = operands[1].trimmingCharacters(in: .whitespaces)
        guard immediateText.hasPrefix("#") else { return nil }
        let body = immediateText.dropFirst()
        guard let immediate = body.hasPrefix("0x") ? UInt64(body.dropFirst(2), radix: 16) : UInt64(body) else { return nil }
        var shift = 0
        var shiftingOnes = false
        if operands.count == 3 {
            let parts = operands[2].split(separator: " ")
            guard parts.count == 2, ["lsl", "msl"].contains(parts[0]),
                  let amount = laneShiftImmediate(String(parts[1])) else { return nil }
            shift = amount
            shiftingOnes = parts[0] == "msl"
        }
        guard let semantics = MacIRNEONImmediate(kind: lowered == "mvni" ? .mvni : .movi,
                                                 laneBits: bits, activeBytes: bytes,
                                                 immediate: immediate, shift: shift, shiftingOnes: shiftingOnes) else { return nil }
        return (vector.name, semantics)
    }

    struct NEONPlainQMemory: Equatable {
        let isLoad: Bool
        let vector: String
        let base: String
        let offset: Int64
        /// Second Q register of an `ldp`/`stp` pair, at `offset + 16`.
        var pair: String? = nil
        /// Single-register writeback: pre-index (`[Xn, #imm]!`) or post-index
        /// (`[Xn], #imm`). The base is updated by `offset`; X bases only.
        var writeback: Writeback? = nil
        enum Writeback: Equatable { case pre, post }
    }

    /// Exact B/H stores use the same full V carrier as scalar DUP. Keep this
    /// local to the vector region rather than widening ordinary register parsing.
    /// Only immediate-offset X-base STR/STUR forms are supported; SP, indexed,
    /// literal, pair and writeback forms stay on their existing paths.
    static func neonPlainNarrowScalarStore(mnemonic: String, operandText: String)
        -> (memory: NEONPlainQMemory, byteWidth: Int)? {
        let lowered = mnemonic.lowercased()
        guard lowered == "str" || lowered == "stur",
              let comma = operandText.firstIndex(of: ",") else { return nil }
        let scalar = operandText[..<comma].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = scalar.first, prefix == "b" || prefix == "h",
              let index = Int(scalar.dropFirst()), (0...31).contains(index),
              scalar == "\(prefix)\(index)" else { return nil }
        let width = prefix == "b" ? 1 : 2
        // Reject repeated signs before the shared parser's signed conversion:
        // malformed text must not turn into another offset or overflow negation.
        let address = operandText[operandText.index(after: comma)...]
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.hasPrefix("["), address.hasSuffix("]") else { return nil }
        let fields = address.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(fields.count) else { return nil }
        if fields.count == 2 {
            guard fields[1].hasPrefix("#") else { return nil }
            var digits = Substring(fields[1].dropFirst())
            if digits.hasPrefix("-") { digits = digits.dropFirst() }
            let hexadecimal = digits.hasPrefix("0x")
            if hexadecimal { digits = digits.dropFirst(2) }
            let alphabet = hexadecimal ? "0123456789abcdef" : "0123456789"
            guard !digits.isEmpty, digits.allSatisfy({ alphabet.contains($0) }) else { return nil }
        }
        // Canonical adaptation reuses the exact plain-Q address parser only;
        // the emitted store keeps its actual one- or two-byte memory width.
        let adapted = "q\(index)" + operandText[comma...]
        guard let memory = neonPlainQMemory(mnemonic: lowered, operandText: adapted),
              !memory.isLoad, memory.pair == nil, memory.writeback == nil else { return nil }
        if lowered == "str" {
            guard memory.offset >= 0, memory.offset <= Int64(4095 * width),
                  memory.offset % Int64(width) == 0 else { return nil }
        } else {
            guard (-256...255).contains(memory.offset) else { return nil }
        }
        return (memory, width)
    }

    /// `ldr/str Qt, [Xn, #imm]!` and `ldr/str Qt, [Xn], #imm` (X base, not SP).
    static func neonQWriteback(mnemonic: String, operandText: String) -> NEONPlainQMemory? {
        let lowered = mnemonic.lowercased()
        guard lowered == "ldr" || lowered == "str" else { return nil }
        let parts = operandText.lowercased().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[0].hasPrefix("q"), let index = Int(parts[0].dropFirst()),
              (0...31).contains(index), parts[0] == "q\(index)" else { return nil }
        func immediate(_ text: String) -> Int64? {
            guard text.hasPrefix("#") else { return nil }
            var body = Substring(text.dropFirst())
            let negative = body.hasPrefix("-")
            if negative { body = body.dropFirst() }
            guard let magnitude = body.hasPrefix("0x") ? Int64(body.dropFirst(2), radix: 16) : Int64(body) else { return nil }
            return negative ? -magnitude : magnitude
        }
        func xBase(_ text: Substring) -> String? {
            let base = String(text)
            guard base.hasPrefix("x"), let n = Int(base.dropFirst()), (0...30).contains(n), base == "x\(n)" else { return nil }
            return base
        }
        let isLoad = lowered == "ldr"
        if parts[1].hasPrefix("["), parts[2].hasSuffix("]!") {
            guard let base = xBase(parts[1].dropFirst()), let offset = immediate(String(parts[2].dropLast(2))) else { return nil }
            return .init(isLoad: isLoad, vector: "v\(index)", base: base, offset: offset, writeback: .pre)
        }
        if parts[1].hasPrefix("["), parts[1].hasSuffix("]"), !parts[2].contains("[") {
            guard let base = xBase(parts[1].dropFirst().dropLast()), let offset = immediate(parts[2]) else { return nil }
            return .init(isLoad: isLoad, vector: "v\(index)", base: base, offset: offset, writeback: .post)
        }
        return nil
    }

    /// Q-register memory addressed off SP in any form (offset, pre/post-index,
    /// register-indexed, pairs). These belong to the stack model, so the region
    /// lifts them through the ordinary builder's per-row memory semantics.
    static func isSPBasedQMemory(mnemonic: String, operandText: String) -> Bool {
        guard ["ldr", "ldur", "str", "stur", "ldp", "stp"].contains(mnemonic.lowercased()) else { return false }
        let text = operandText.lowercased()
        guard let first = text.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("q"), let index = Int(first.dropFirst()), (0...31).contains(index) else { return false }
        return text.contains("[sp]") || text.contains("[sp,")
    }

    /// `ldr/ldur/str/stur Qt, [Xn{, #imm}]` without writeback. Literal, indexed,
    /// pre- and post-index forms are not admitted here.
    static func neonPlainQMemory(mnemonic: String, operandText: String) -> NEONPlainQMemory? {
        let lowered = mnemonic.lowercased()
        guard ["ldr", "ldur", "str", "stur", "ldp", "stp"].contains(lowered) else { return nil }
        let isPair = lowered == "ldp" || lowered == "stp"
        var text = Substring(operandText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard text.hasSuffix("]"), !text.contains("!") else { return nil }
        func qRegister() -> Int? {
            guard let comma = text.firstIndex(of: ",") else { return nil }
            let register = text[..<comma].trimmingCharacters(in: .whitespaces)
            text = text[text.index(after: comma)...]
            guard register.hasPrefix("q"), let index = Int(register.dropFirst()), (0...31).contains(index),
                  register == "q\(index)" else { return nil }
            return index
        }
        guard let index = qRegister() else { return nil }
        let second = isPair ? qRegister() : nil
        if isPair, second == nil { return nil }
        let memory = text.trimmingCharacters(in: .whitespaces)
        guard memory.hasPrefix("[") else { return nil }
        let inner = memory.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // An SP-based Q load reads memory without changing stack facts. SP-based
        // stores stay with the stack model, which tracks and invalidates slots.
        let isLoad = lowered.hasPrefix("ld")
        guard (1...2).contains(inner.count),
              (inner[0] == "sp" && isLoad) || (inner[0].hasPrefix("x")
                && Int(inner[0].dropFirst()).map({ (0...30).contains($0) && inner[0] == "x\($0)" }) == true)
        else { return nil }
        var offset: Int64 = 0
        if inner.count == 2 {
            guard inner[1].hasPrefix("#") else { return nil }
            var body = Substring(inner[1].dropFirst())
            let negative = body.hasPrefix("-")
            if negative { body = body.dropFirst() }
            guard let magnitude = body.hasPrefix("0x") ? Int64(body.dropFirst(2), radix: 16) : Int64(body) else { return nil }
            offset = negative ? -magnitude : magnitude
        }
        return .init(isLoad: lowered.hasPrefix("ld"), vector: "v\(index)", base: inner[0], offset: offset,
                     pair: second.map { "v\($0)" })
    }
}

extension MacIRBuilder {
    /// A byte/text-agreeing SSA admission, reusing the existing typed lane operations.
    /// Encoding and Operation: Arm A64 2025-09 ins_advsimd_{elt,gen},
    /// dup_advsimd_{elt,gen}, tbl_advsimd, ext_advsimd,
    /// {trn1,trn2,zip1,zip2,uzp1,uzp2}_advsimd.xml.
    struct SSAVectorPermutation {
        let destination: String
        let sources: [String]
        let canonicalOperands: String
        let mnemonic: String
        var lane: MacIRNEONLaneOp? = nil
        var bitView: MacIRNEONBitView? = nil
        var extract: MacIRNEONExtract? = nil
        var table: MacIRNEONTableLookup? = nil
        var dot: MacIRNEONByteDotProduct? = nil
        var reduction: MacIRNEONReduction? = nil
        var readsDestination: Bool { bitView?.readsOldDestination == true || dot != nil }
        var intrinsicName: String {
            if dot != nil { return "byte_dot_accumulate" }
            if reduction != nil { return "integer_horizontal_output" }
            return lane?.intrinsicName ?? bitView?.intrinsicName ?? extract?.intrinsicName ?? table!.intrinsicName
        }
    }

    static func ssaVectorPermutation(_ source: MacIRSourceSpan) -> SSAVectorPermutation? {
        let tokens = source.byteText.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 4, tokens.allSatisfy({ $0.count == 2 }),
              tokens.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }
        let bytes = tokens.compactMap { UInt8($0, radix: 16) }
        let word = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        let d = Int(word & 31), n = Int((word >> 5) & 31), m = Int((word >> 16) & 31)
        let active = (word & 0x40000000) == 0 ? 8 : 16
        let vd = "v\(d)", vn = "v\(n)", vm = "v\(m)"
        var parsed: SSAVectorPermutation?
        func make(_ mnemonic: String, _ operands: String, _ sources: [String]) -> SSAVectorPermutation {
            .init(destination: vd, sources: sources, canonicalOperands: operands, mnemonic: mnemonic)
        }
        // Existing arithmetic descriptors remain the sole numeric models.
        // Arm 2025-12 SDOT/UDOT: each S lane accumulates four byte products.
        if word & 0xdfe0fc00 == 0x4e809400 {
            let kind: MacIRNEONByteDotProduct.Kind = word & 0x20000000 == 0 ? .sdot : .udot
            let operands = "\(vd).4s, \(vn).16b, \(vm).16b"
            guard source.mnemonic.lowercased() == kind.rawValue,
                  source.operands.lowercased().filter({ !$0.isWhitespace })
                    == operands.filter({ !$0.isWhitespace }),
                  let descriptor = MacIRNEONByteDotProduct(kind: kind, activeBytes: 16) else { return nil }
            var operation = make(kind.rawValue, operands, [vn, vm])
            operation.dot = descriptor
            return operation
        }
        // X<-D UMOV uses the existing typed copy model, not a reduction.
        // Keep this SSA bridge byte/text exact; the general region retains
        // neonCopy's existing textual contract and alias-aware emission.
        if word & 0xffeffc00 == 0x4e083c00 {
            let lane = Int((word >> 20) & 1)
            let operands = "x\(d), \(vn).d[\(lane)]"
            guard d < 31, source.mnemonic.lowercased() == "umov",
                  source.operands.lowercased().filter({ !$0.isWhitespace })
                    == operands.filter({ !$0.isWhitespace }),
                  case let .unsignedMove(destination, input, semantics)? =
                    neonCopy(mnemonic: "umov", operandText: operands) else { return nil }
            var operation = SSAVectorPermutation(destination: destination,
                sources: [input], canonicalOperands: operands, mnemonic: "umov")
            operation.bitView = semantics
            return operation
        }
        if let carrier = integerReductionCarrier(word: word, mnemonic: source.mnemonic,
                                                  operandText: source.operands) {
            var operation = SSAVectorPermutation(destination: carrier.destination,
                sources: [carrier.source], canonicalOperands: source.operands,
                mnemonic: source.mnemonic.lowercased())
            operation.reduction = carrier.semantics
            return operation
        }
        let insertVector = word & 0xffe08400 == 0x6e000400
        let insertGPR = word & 0xffe0fc00 == 0x4e001c00
        let duplicateVector = word & 0xbfe0fc00 == 0x0e000400
        let duplicateGPR = word & 0xbfe0fc00 == 0x0e000c00
        if insertVector || insertGPR || duplicateVector || duplicateGPR {
            let imm5 = Int((word >> 16) & 31)
            guard imm5 != 0 else { return nil }
            let size = imm5.trailingZeroBitCount
            guard size <= 3 else { return nil }
            let bits = 8 << size, destinationLane = imm5 >> (size + 1)
            let letter = ["b", "h", "s", "d"][size]
            if insertVector || insertGPR {
                let sourceLane = insertVector ? Int((word >> 11) & 15) >> size : 0
                // Arm Decode explicitly ignores imm4 bits below size.
                guard let descriptor = MacIRNEONBitView(kind: insertGPR ? .insertGPR : .insertElement, elementBits: bits,
                          sourceLane: sourceLane, destinationLane: destinationLane) else { return nil }
                let register = insertVector ? vn : n == 31 ? (bits == 64 ? "xzr" : "wzr") : "\(bits == 64 ? "x" : "w")\(n)"
                let operand = insertVector ? "\(register).\(letter)[\(sourceLane)]" : register
                parsed = make("ins", "\(vd).\(letter)[\(destinationLane)], \(operand)", [register])
                parsed?.bitView = descriptor
            } else {
                guard bits != 64 || active == 16 else { return nil }
                // Arm Decode explicitly ignores imm5 bits above size for DUP general.
                let register = duplicateVector ? vn : n == 31 ? (bits == 64 ? "xzr" : "wzr") : "\(bits == 64 ? "x" : "w")\(n)"
                let operand = duplicateVector ? "\(register).\(letter)[\(destinationLane)]" : register
                guard let descriptor = MacIRNEONLaneOp(kind: .dup, isSigned: false, laneBits: bits,
                    highHalf: false, activeBytes: active, elementIndex: duplicateVector ? destinationLane : nil) else { return nil }
                parsed = make("dup", "\(vd).\(active * 8 / bits)\(letter), \(operand)", [register])
                parsed?.lane = descriptor
            }
        } else if word & 0xbfe09c00 == 0x0e000000 {
            let count = Int((word >> 13) & 3) + 1
            let registers = (0..<count).map { "v\((n + $0) % 32)" }
            let list = registers.map { "\($0).16b" }.joined(separator: ", ")
            parsed = make("tbl", "\(vd).\(active)b, {\(list)}, \(vm).\(active)b", registers + [vm])
            parsed?.table = MacIRNEONTableLookup(kind: .tbl, width: active == 8 ? .bytes8 : .bytes16, tableCount: count)
        } else if word & 0xbfe08400 == 0x2e000000 {
            let offset = Int((word >> 11) & 15)
            guard let descriptor = MacIRNEONExtract(width: active == 8 ? .bytes8 : .bytes16, byteOffset: offset) else { return nil }
            parsed = make("ext", "\(vd).\(active)b, \(vn).\(active)b, \(vm).\(active)b, #\(offset)", [vn, vm])
            parsed?.extract = descriptor
        } else {
            let kinds: [UInt32: MacIRNEONLaneOp.Kind] = [0x0e002800: .trn1, 0x0e006800: .trn2,
                0x0e003800: .zip1, 0x0e007800: .zip2, 0x0e001800: .uzp1, 0x0e005800: .uzp2]
            guard let kind = kinds[word & 0xbf20fc00] else { return nil }
            let size = Int((word >> 22) & 3), bits = 8 << size
            guard bits != 64 || active == 16,
                  let descriptor = MacIRNEONLaneOp(kind: kind, isSigned: false, laneBits: bits,
                    highHalf: false, activeBytes: active) else { return nil }
            let arrangement = "\(active * 8 / bits)\(["b", "h", "s", "d"][size])"
            parsed = make(kind.rawValue, "\(vd).\(arrangement), \(vn).\(arrangement), \(vm).\(arrangement)", [vn, vm])
            parsed?.lane = descriptor
        }
        guard let parsed else { return nil }
        func normalized(_ text: String) -> String {
            text.lowercased().filter { !$0.isWhitespace }
        }
        var text = source.operands.lowercased()
        // Canonical decimal/hex immediate spellings describe the same EXT offset.
        if parsed.mnemonic == "ext", let hash = text.lastIndex(of: "#") {
            let body = text[text.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("0x"), let value = Int(body.dropFirst(2), radix: 16) {
                text = String(text[...hash]) + String(value)
            }
        }
        guard source.mnemonic.lowercased() == parsed.mnemonic,
              normalized(text) == normalized(parsed.canonicalOperands) else { return nil }
        return parsed
    }
}
