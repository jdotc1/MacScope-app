import Foundation

extension MacIRBuilder {
    static func neonLogical(mnemonic: String, operandText: String) -> MacIRNEONLogical? {
        // Keep empty components so malformed commas cannot become admitted operands.
        let operands = operandText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return neonLogical(mnemonic: mnemonic, operands: operands)
    }

    static func neonLogical(mnemonic: String, operands: [String]) -> MacIRNEONLogical? {
        guard let kind = MacIRNEONLogical.Kind(rawValue: mnemonic), operands.count == 3 else { return nil }
        let parts = operands.map { $0.split(separator: ".", omittingEmptySubsequences: false) }
        guard parts.allSatisfy({ $0.count == 2 }),
              parts.allSatisfy({ part in
                  let name = String(part[0])
                  guard name.hasPrefix("v"), let index = vectorRegisterIndex(name) else { return false }
                  return name == "v\(index)"
              }),
              parts[0][1] == parts[1][1], parts[0][1] == parts[2][1] else { return nil }
        let width: MacIRNEONLogical.Width
        switch parts[0][1] { case "8b": width = .bytes8; case "16b": width = .bytes16; default: return nil }
        return .init(kind: kind, width: width)
    }

    static func liftNEONLogical(_ semantics: MacIRNEONLogical, operands: [String], state: inout BuilderState) -> MacIROperation {
        let names = operands.map { String($0.split(separator: ".")[0]) }
        // Capture ALL read versions, including the destination mask/merge value,
        // before writeRegister. Equal names intentionally retain equal SSA inputs.
        var arguments = [state.readRegister(names[1]), state.readRegister(names[2])]
        if semantics.readsDestination { arguments.append(state.readRegister(names[0])) }
        let destination = state.writeRegister(names[0])
        return .intrinsic(destination: destination, name: semantics.intrinsicName, arguments: arguments)
    }
}

extension MacIRBuilder {
    /// Exact per-row INS, UMOV, TBL/TBX and EXT; no adjacent-row or function matcher.
    /// ARM ISA_A64 2025-12: INS_advsimd_elt, INS_advsimd_gen,
    /// UMOV_advsimd, TBL_advsimd, TBX_advsimd and EXT_advsimd, Operation sections.
    enum NEONCopyOperands {
        case insert(destination: String, source: String, semantics: MacIRNEONBitView)
        case unsignedMove(destination: String, source: String, semantics: MacIRNEONBitView)
        case table(destination: String, tables: [String], index: String, semantics: MacIRNEONTableLookup)
        case extract(destination: String, n: String, m: String, semantics: MacIRNEONExtract)
    }

    private static func copyVector(_ text: String) -> (name: String, arrangement: String)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = vectorRegisterIndex(String(parts[0])),
              parts[0] == "v\(index)" else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func copyElement(_ text: String) -> (name: String, bits: Int, index: Int)? {
        guard let vector = copyVector(text), let open = vector.arrangement.firstIndex(of: "["),
              vector.arrangement.hasSuffix("]"),
              let bits = ["b": 8, "h": 16, "s": 32, "d": 64][String(vector.arrangement[..<open])],
              let index = Int(vector.arrangement[vector.arrangement.index(after: open)..<vector.arrangement.index(before: vector.arrangement.endIndex)]),
              vector.arrangement == "\([8: "b", 16: "h", 32: "s", 64: "d"][bits]!)[\(index)]",
              (0..<(128 / bits)).contains(index) else { return nil }
        return (vector.name, bits, index)
    }

    static func neonCopy(mnemonic: String, operandText: String) -> NEONCopyOperands? {
        let text = operandText.lowercased()
        let operands = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if mnemonic == "umov" {
            guard operands.count == 2, let source = copyElement(operands[1]) else { return nil }
            let prefix = source.bits == 64 ? "x" : "w"
            let register = operands[0]
            let validGPR = register == prefix + "zr" || (Int(register.dropFirst()).map {
                (0...30).contains($0) && register == "\(prefix)\($0)"
            } ?? false)
            guard validGPR, let semantics = MacIRNEONBitView(kind: .unsignedMoveElement,
                elementBits: source.bits, sourceLane: source.index) else { return nil }
            return .unsignedMove(destination: register, source: source.name, semantics: semantics)
        }
        if mnemonic == "ins" {
            guard operands.count == 2, let destination = copyElement(operands[0]) else { return nil }
            if let source = copyElement(operands[1]), source.bits == destination.bits,
               let semantics = MacIRNEONBitView(kind: .insertElement, elementBits: destination.bits,
                   sourceLane: source.index, destinationLane: destination.index) {
                return .insert(destination: destination.name, source: source.name, semantics: semantics)
            }
            let prefix = destination.bits == 64 ? "x" : "w"
            let register = operands[1]
            let validGPR = register == prefix + "zr" || (Int(register.dropFirst()).map {
                (0...30).contains($0) && register == "\(prefix)\($0)"
            } ?? false)
            guard validGPR, let semantics = MacIRNEONBitView(kind: .insertGPR,
                elementBits: destination.bits, destinationLane: destination.index) else { return nil }
            return .insert(destination: destination.name, source: register, semantics: semantics)
        }
        if mnemonic == "ext" {
            guard operands.count == 4, let destination = copyVector(operands[0]),
                  let n = copyVector(operands[1]), let m = copyVector(operands[2]),
                  n.arrangement == destination.arrangement, m.arrangement == destination.arrangement,
                  let bytes = ["8b": 8, "16b": 16][destination.arrangement],
                  operands[3].hasPrefix("#") else { return nil }
            let immediate = operands[3].dropFirst()
            let offset = immediate.hasPrefix("0x") ? Int(immediate.dropFirst(2), radix: 16) : Int(immediate)
            guard let offset, let semantics = MacIRNEONExtract(
                width: bytes == 8 ? .bytes8 : .bytes16, byteOffset: offset) else { return nil }
            return .extract(destination: destination.name, n: n.name, m: m.name, semantics: semantics)
        }
        if mnemonic == "tbl" || mnemonic == "tbx" {
            guard let open = text.firstIndex(of: "{"), let close = text.firstIndex(of: "}"), open < close,
                  !text[text.index(after: open)...].contains("{"),
                  !text[text.index(after: close)...].contains("}") else { return nil }
            let before = text[..<open].split(separator: ",", omittingEmptySubsequences: false)
            let after = text[text.index(after: close)...].split(separator: ",", omittingEmptySubsequences: false)
            guard before.count == 2, before[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  after.count == 2, after[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let destination = copyVector(before[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let index = copyVector(after[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  destination.arrangement == index.arrangement,
                  let bytes = ["8b": 8, "16b": 16][destination.arrangement] else { return nil }
            let tableText = text[text.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
            let tables = tableText.compactMap { copyVector($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard tables.count == tableText.count, (1...4).contains(tables.count),
                  tables.allSatisfy({ $0.arrangement == "16b" }),
                  let first = vectorRegisterIndex(tables[0].name),
                  tables.enumerated().allSatisfy({ $0.element.name == "v\((first + $0.offset) % 32)" }),
                  let semantics = MacIRNEONTableLookup(kind: mnemonic == "tbl" ? .tbl : .tbx,
                    width: bytes == 8 ? .bytes8 : .bytes16, tableCount: tables.count) else { return nil }
            return .table(destination: destination.name, tables: tables.map(\.name), index: index.name, semantics: semantics)
        }
        return nil
    }

    static func liftNEONCopy(_ parsed: NEONCopyOperands, source: MacIRSourceSpan,
                             state: inout BuilderState) -> MacIRInstruction {
        // Snapshot all aliases before writeRegister, including old Vd for INS/TBX.
        switch parsed {
        case let .unsignedMove(destination, input, semantics):
            let arguments = [state.readRegister(input)]
            // Wd writes install a32-bit physical integer definition. Later Xd
            // reads therefore zero-extend, never preserve a stale upper half.
            let result = state.writeRegister(destination)
            state.recordValueType(semantics.elementBits == 64 ? "uint64_t" : "uint32_t", for: result)
            return .init(source: source, operation: .intrinsic(destination: result,
                name: semantics.intrinsicName, arguments: arguments), neonBitView: semantics)
        case let .insert(destination, input, semantics):
            let arguments = [state.readRegister(input), state.readRegister(destination)]
            return .init(source: source, operation: .intrinsic(destination: state.writeRegister(destination),
                name: semantics.intrinsicName, arguments: arguments), neonBitView: semantics)
        case let .table(destination, tables, index, semantics):
            var arguments = tables.map { state.readRegister($0) }
            arguments.append(state.readRegister(index))
            if semantics.kind == .tbx { arguments.append(state.readRegister(destination)) }
            return .init(source: source, operation: .intrinsic(destination: state.writeRegister(destination),
                name: semantics.intrinsicName, arguments: arguments), neonTableLookup: semantics)
        case let .extract(destination, n, m, semantics):
            let arguments = [state.readRegister(n), state.readRegister(m)]
            return .init(source: source, operation: .intrinsic(destination: state.writeRegister(destination),
                name: semantics.intrinsicName, arguments: arguments), neonExtract: semantics)
        }
    }
}


extension MacIRBuilder {
    struct NEONBitClearImmediate {
        let destination: String
        let mask: MacIRNEONImmediate
    }

    /// BIC (vector, immediate) is a read/modify/write, not scalar BIC's three
    /// register operands. This bounded repair admits the 128-bit forms only;
    /// 64-bit forms require separate width-aware low-half carrier handling.
    static func neonBitClearImmediate(mnemonic: String, operandText: String) -> NEONBitClearImmediate? {
        guard mnemonic == "bic" else { return nil }
        let operands = operandText.lowercased().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard operands.count == 2 || operands.count == 3 else { return nil }
        let parts = operands[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = vectorRegisterIndex(String(parts[0])),
              parts[0] == "v\(index)",
              let shape = ["8h": (16, 16), "4s": (32, 16)][String(parts[1])],
              operands[1].hasPrefix("#") else { return nil }
        let literal = String(operands[1].dropFirst())
        let immediate = literal.hasPrefix("0x")
            ? UInt64(literal.dropFirst(2), radix: 16) : UInt64(literal)
        guard let immediate, immediate <= 255 else { return nil }
        var shift = 0
        if operands.count == 3 {
            let fields = operands[2].split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0] == "lsl", fields[1].hasPrefix("#"),
                  let parsed = Int(fields[1].dropFirst()) else { return nil }
            shift = parsed
        }
        guard let mask = MacIRNEONImmediate(kind: .movi, laneBits: shape.0,
            activeBytes: shape.1, immediate: immediate, shift: shift) else { return nil }
        return .init(destination: "q\(index)", mask: mask)
    }

    static func liftNEONBitClearImmediate(_ immediate: NEONBitClearImmediate,
        source: MacIRSourceSpan, state: inout BuilderState) -> [MacIRInstruction] {
        // Q names retain both halves in SSA and normalize to the existing V
        // carrier in vector regions. Capture the old value before its new DEF.
        let old = state.readRegister(immediate.destination)
        let mask: MacIRValue = .register(name: "vector_mask_\(String(source.address, radix: 16))", version: 0)
        let destination = state.writeRegister(immediate.destination)
        let logical = MacIRNEONLogical(kind: .bic,
            width: immediate.mask.activeBytes == 16 ? .bytes16 : .bytes8)
        state.recordValueType("__uint128_t", for: mask)
        return [
            .init(source: source, operation: .intrinsic(destination: mask,
                name: "neon_integer_constant", arguments: []), neonImmediate: immediate.mask),
            .init(source: source, operation: .intrinsic(destination: destination,
                name: logical.intrinsicName, arguments: [old, mask]), neonLogical: logical)
        ]
    }
}
