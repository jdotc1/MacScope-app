import Foundation

/// Renders the bounded typed vocabulary. Complete envelopes never consult legacy operand text.
/// Nil means the claimed complete form is invalid/unsupported; it must not acquire text-derived semantics.
enum ARM64OperandRenderer {
    struct Rendered: Equatable, Sendable {
        let mnemonic: String
        let operands: String
    }
    typealias Model = InstructionOperands

    static func render(_ value: Model, legacyMnemonic: String, legacyOperands: String) -> Rendered? {
        guard value.coverage == .complete else {
            return Rendered(mnemonic: value.legacyText?.mnemonic ?? legacyMnemonic,
                            operands: value.legacyText?.operands ?? legacyOperands)
        }
        guard value.architecture == .arm64, value.schemaVersion == 1,
              var mnemonic = value.presentation.alias ?? value.presentation.mnemonic ?? value.opcodeClass,
              !mnemonic.isEmpty, !mnemonic.contains(where: { $0.isWhitespace }),
              value.presentation.omittedOperandIndices.allSatisfy({ value.operands.indices.contains($0) })
        else { return nil }
        if let width = value.semantics?.memoryAccessWidth, width <= 0 { return nil }

        var omitted = Set(value.presentation.omittedOperandIndices)
        if let suffix = value.presentation.conditionSuffixOperandIndex {
            guard value.operands.indices.contains(suffix), case let .condition(condition) = value.operands[suffix]
            else { return nil }
            mnemonic += "." + condition.rawValue
            omitted.insert(suffix)
        }
        var rendered: [String] = []
        for (index, operand) in value.operands.enumerated() {
            // Validate implicit operands too; omission is presentation, never authority to admit opaque data.
            guard let text = render(operand, presentation: value.presentation) else { return nil }
            if !omitted.contains(index) { rendered.append(text) }
        }
        return Rendered(mnemonic: mnemonic, operands: rendered.joined(separator: ", "))
    }

    private static func render(_ operand: Model.Operand, presentation: Model.Presentation) -> String? {
        switch operand {
        case let .register(register): return render(register)
        case let .immediate(immediate): return render(immediate, format: presentation.numberFormat)
        case let .modifiedRegister(register, modifier):
            guard modifier.kind != .msl, let registerText = render(register),
                  let modifierText = render(modifier) else { return nil }
            return registerText + (modifierText.isEmpty ? "" : ", " + modifierText)
        case let .modifiedImmediate(immediate, modifier):
            guard modifier.kind == .lsl || modifier.kind == .msl,
                  let immediateText = render(immediate, format: presentation.numberFormat),
                  let modifierText = render(modifier) else { return nil }
            return immediateText + (modifierText.isEmpty ? "" : ", " + modifierText)
        case let .memory(memory): return render(memory, presentation: presentation)
        case let .registerList(registers):
            guard !registers.isEmpty, registers.count <= 32 else { return nil }
            if let lane = registers[0].lane {
                // A structure lane belongs to every listed element, but ARM64 prints it once
                // after the braces. The same Register still renders Vn.T[i] outside a list.
                guard presentation.registerListBraces,
                      registers.allSatisfy({ $0.bank == .simd && $0.lane == lane &&
                          $0.width == registers[0].width && $0.arrangement == registers[0].arrangement })
                else { return nil }
                let texts = registers.compactMap { render($0, omitLane: true) }
                guard texts.count == registers.count else { return nil }
                return "{" + texts.joined(separator: ", ") + "}[\(lane)]"
            }
            guard registers.allSatisfy({ $0.lane == nil }) else { return nil }
            let texts = registers.compactMap { render($0) }
            guard texts.count == registers.count else { return nil }
            let list = texts.joined(separator: ", ")
            return presentation.registerListBraces ? "{" + list + "}" : list
        case let .pcRelative(reference):
            guard let target = reference.target else { return nil }
            return unsigned(target, format: reference.format)
        case let .condition(condition): return condition.rawValue
        case let .systemRegister(register):
            if let spelling = register.spelling {
                guard !spelling.isEmpty, !spelling.contains(where: { $0.isWhitespace }) else { return nil }
                return spelling
            }
            let bits = register.encoding
            return "s\((bits >> 14) & 3)_\((bits >> 11) & 7)_c\((bits >> 7) & 15)_c\((bits >> 3) & 15)_\(bits & 7)"
        case let .option(option):
            guard option.value <= (option.kind == .barrier ? 15 : 31) else { return nil }
            if let spelling = option.spelling {
                guard !spelling.isEmpty, !spelling.contains(where: { $0.isWhitespace }) else { return nil }
                return spelling
            }
            return "#" + unsigned(UInt64(option.value), format: presentation.numberFormat)
        case .opaque: return nil
        }
    }

    private static func render(_ register: Model.Register, omitLane: Bool = false) -> String? {
        guard (0...31).contains(register.index) else { return nil }
        switch register.bank {
        case .general:
            guard [32, 64].contains(register.width), register.arrangement == nil, register.lane == nil else { return nil }
            if register.index == 31 {
                switch register.role {
                case .stackPointer: return register.width == 64 ? "sp" : "wsp"
                case .zero: return register.width == 64 ? "xzr" : "wzr"
                case .ordinary: return nil
                }
            }
            guard register.role == .ordinary else { return nil }
            return "\(register.width == 64 ? "x" : "w")\(register.index)"
        case .simd:
            guard register.role == .ordinary else { return nil }
            let letters = [8: "b", 16: "h", 32: "s", 64: "d", 128: "q"]
            guard let scalar = letters[register.width] else { return nil }
            guard let arrangement = register.arrangement else {
                guard register.lane == nil else { return nil }
                return "\(scalar)\(register.index)"
            }
            guard [64, 128].contains(register.width), [8, 16, 32, 64].contains(arrangement.elementWidth),
                  let element = letters[arrangement.elementWidth] else { return nil }
            if let count = arrangement.laneCount {
                guard count > 0, count <= 16, count * arrangement.elementWidth == register.width,
                      register.lane == nil else { return nil }
                return "v\(register.index).\(count)\(element)"
            }
            guard let lane = register.lane, lane >= 0, lane < register.width / arrangement.elementWidth else { return nil }
            return "v\(register.index).\(element)" + (omitLane ? "" : "[\(lane)]")
        }
    }

    private static func render(_ immediate: Model.Immediate, format: Model.NumberFormat) -> String? {
        if let width = immediate.encodedWidth, !(1...64).contains(width) { return nil }
        if let shift = immediate.encodedShift, !(0...63).contains(shift) { return nil }
        if let bits = immediate.encodedValue, let width = immediate.encodedWidth,
           width < 64, bits >> UInt64(width) != 0 { return nil }
        let format = immediate.format ?? format
        switch immediate.value {
        case let .signed(value): return "#" + signed(value, format: format)
        case let .unsigned(value): return "#" + unsigned(value, format: format)
        case let .floatingPoint(bits, width):
            let value: Double
            switch width {
            case 16:
                guard bits <= UInt64(UInt16.max) else { return nil }
                value = Double(Float16(bitPattern: UInt16(bits)))
            case 32:
                guard bits <= UInt64(UInt32.max) else { return nil }
                value = Double(Float(bitPattern: UInt32(bits)))
            case 64: value = Double(bitPattern: bits)
            default: return nil
            }
            guard value.isFinite else { return nil }
            return "#" + String(value)
        }
    }

    private static func render(_ modifier: Model.RegisterModifier) -> String? {
        if let amount = modifier.amount, !(0...63).contains(amount) { return nil }
        if [.lsl, .lsr, .asr, .ror, .msl].contains(modifier.kind), modifier.amount == nil { return nil }
        if modifier.amount == 0 && modifier.omitWhenZero { return "" }
        let suffix: String
        if let amount = modifier.amount, !(amount == 0 && modifier.omitZeroAmount) {
            suffix = " #\(amount)"
        } else { suffix = "" }
        return (modifier.presentationKind ?? modifier.kind).rawValue + suffix
    }

    private static func render(_ memory: Model.Memory, presentation: Model.Presentation) -> String? {
        guard memory.base.bank == .general, memory.base.width == 64, memory.base.role != .zero,
              let base = render(memory.base),
              memory.writeback == (memory.indexing != .offset) else { return nil }
        let offset = "#" + signed(memory.displacement, format: memory.displacementFormat ?? presentation.numberFormat)
        let addressOperand: String
        if let index = memory.index {
            guard memory.displacement == 0, index.bank == .general, index.role != .stackPointer,
                  memory.indexing != .preIndex, let register = render(index) else { return nil }
            if memory.indexing == .postIndex {
                guard index.width == 64, memory.modifier == nil else { return nil }
                addressOperand = register
            } else if let modifier = memory.modifier {
                guard [.lsl, .uxtw, .sxtw, .sxtx].contains(modifier.kind),
                      index.width == ([.uxtw, .sxtw].contains(modifier.kind) ? 32 : 64),
                      (modifier.amount ?? 0) <= 4,
                      let modifierText = render(modifier) else { return nil }
                addressOperand = register + (modifierText.isEmpty ? "" : ", " + modifierText)
            } else {
                guard index.width == 64 else { return nil }
                addressOperand = register
            }
        } else {
            guard memory.modifier == nil else { return nil }
            addressOperand = offset
        }
        switch memory.indexing {
        case .offset:
            if memory.index == nil, memory.displacement == 0, presentation.omitZeroOffset { return "[\(base)]" }
            return "[\(base), \(addressOperand)]"
        case .preIndex: return "[\(base), \(addressOperand)]!"
        case .postIndex: return "[\(base)], \(addressOperand)"
        }
    }

    private static func unsigned(_ value: UInt64, format: Model.NumberFormat) -> String {
        switch format {
        case .automatic: return value < 10 ? String(value) : "0x" + String(value, radix: 16)
        case .decimal: return String(value)
        case .hexadecimal: return "0x" + String(value, radix: 16)
        case .hexAddress: return String(format: "0x%016llx", value)
        }
    }
    private static func signed(_ value: Int64, format: Model.NumberFormat) -> String {
        // The decoder's negative immediate convention is hex, including Int64.min without overflow.
        if format == .decimal { return String(value) }
        return value < 0 ? "-0x" + String(value.magnitude, radix: 16) : unsigned(UInt64(value), format: format)
    }
}
