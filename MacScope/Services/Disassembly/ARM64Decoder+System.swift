import Foundation

extension ARM64Decoder {
    // MARK: - System & exception

    func decodeException(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let opc = (word >> 21) & 0x7
        let imm16 = UInt64((word >> 5) & 0xffff)
        let ll = word & 0x3
        // op2 (bits[4:2]) must be 000 for every exception-generating instruction.
        guard (word & 0x1c) == 0 else { return unknownInstruction(address, bytes, word) }
        let mnemonic: String?
        switch (opc, ll) {
        case (0b000, 0b01): mnemonic = "svc"
        case (0b000, 0b10): mnemonic = "hvc"
        case (0b000, 0b11): mnemonic = "smc"
        case (0b001, 0b00): mnemonic = "brk"
        case (0b010, 0b00): mnemonic = "hlt"
        case (0b101, 0b01): mnemonic = "dcps1"
        case (0b101, 0b10): mnemonic = "dcps2"
        case (0b101, 0b11): mnemonic = "dcps3"
        default: mnemonic = nil
        }
        guard let mnemonic else { return unknownInstruction(address, bytes, word) }
        if mnemonic.hasPrefix("dcps"), imm16 == 0 { return instruction(address, bytes, mnemonic, "") }
        return instruction(address, bytes, mnemonic, "#\(formatImmediate(imm16))")
    }

    func decodeSystem(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let l = (word >> 21) & 0x1
        let op0 = Int((word >> 19) & 0x3)
        let op1 = Int((word >> 16) & 0x7)
        let crn = Int((word >> 12) & 0xf)
        let crm = Int((word >> 8) & 0xf)
        let op2 = Int((word >> 5) & 0x7)
        let rt = Int(word & 0x1f)

        // Hints, barriers, and MSR (immediate) all use op0==0, Rt==31.
        if l == 0, op0 == 0, rt == 31 {
            // HINT space: op1=011 only. Other op1 values are MSR (register) to an implementation-defined
            // S0_<op1>_C2_C<m>_<op2> register (`d500201f` is not `nop`), which MacScope leaves unknown.
            if crn == 2, op1 == 3 {
                let hint = (crm << 3) | op2
                switch hint {
                case 0: return instruction(address, bytes, "nop", "")
                case 1: return instruction(address, bytes, "yield", "")
                case 2: return instruction(address, bytes, "wfe", "")
                case 3: return instruction(address, bytes, "wfi", "")
                case 4: return instruction(address, bytes, "sev", "")
                case 5: return instruction(address, bytes, "sevl", "")
                case 6: return instruction(address, bytes, "dgh", "")
                case 7: return instruction(address, bytes, "xpaclri", "")
                case 16: return instruction(address, bytes, "esb", "")
                case 17: return instruction(address, bytes, "psb", "csync")
                case 18: return instruction(address, bytes, "tsb", "csync")
                case 19: return instruction(address, bytes, "gcsb", "dsync")
                case 20: return instruction(address, bytes, "csdb", "")
                case 22: return instruction(address, bytes, "clrbhb", "")
                case 24: return instruction(address, bytes, "paciaz", "")
                case 25: return instruction(address, bytes, "paciasp", "")
                case 26: return instruction(address, bytes, "pacibz", "")
                case 27: return instruction(address, bytes, "pacibsp", "")
                case 28: return instruction(address, bytes, "autiaz", "")
                case 29: return instruction(address, bytes, "autiasp", "")
                case 30: return instruction(address, bytes, "autibz", "")
                case 31: return instruction(address, bytes, "autibsp", "")
                case 39: return instruction(address, bytes, "pacm", "")
                case 40: return instruction(address, bytes, "chkfeat", "x16")
                default: return instruction(address, bytes, "hint", "#\(formatImmediate(UInt64(hint)))")
                }
            }
            if crn == 3, op1 == 3 { // Barriers (op1=011; other op1 values are MSR to a system register).
                switch op2 {
                case 0b100: return instruction(address, bytes, "dsb", barrierOption(crm))
                case 0b101: return instruction(address, bytes, "dmb", barrierOption(crm))
                case 0b110: return instruction(address, bytes, "isb", crm == 0b1111 ? "" : barrierOption(crm))
                default: break
                }
            }
            if crn == 4 { // MSR (immediate) to a PSTATE field; op1:op2 (and CRm for ALLINT/PM/SVCR) select it.
                if op1 == 3, op2 == 3 { // MSR SVCRSM/SVCRZA/SVCRSMZA, #imm: the SMSTART/SMSTOP aliases.
                    switch crm {
                    case 0b0010: return instruction(address, bytes, "smstop", "sm")
                    case 0b0011: return instruction(address, bytes, "smstart", "sm")
                    case 0b0100: return instruction(address, bytes, "smstop", "za")
                    case 0b0101: return instruction(address, bytes, "smstart", "za")
                    case 0b0110: return instruction(address, bytes, "smstop", "")
                    case 0b0111: return instruction(address, bytes, "smstart", "")
                    default: return unknownInstruction(address, bytes, word)
                    }
                }
                // Unallocated op1:op2 pairs are MSR (register) to S0_<op1>_C4_C<m>_<op2>: unknown, never
                // a fabricated PSTATE write.
                guard let field = pstateField(op1: op1, op2: op2, crm: crm) else {
                    return unknownInstruction(address, bytes, word)
                }
                let immediate = field == "allint" || field == "pm" ? crm & 1 : crm
                return instruction(address, bytes, "msr", "\(field), #\(formatImmediate(UInt64(immediate)))")
            }
            return unknownInstruction(address, bytes, word)
        }

        // MRS / MSR (register): op0 in {2, 3}.
        if op0 == 2 || op0 == 3 {
            let sysreg = systemRegisterName(op0: op0, op1: op1, crn: crn, crm: crm, op2: op2)
            let xt = register(rt, is64Bit: true)
            let typedRegister = InstructionOperands.Operand.register(.init(index: rt, width: 64,
                role: rt == 31 ? .zero : .ordinary))
            let system = InstructionOperands.Operand.systemRegister(.init(
                encoding: UInt16((op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2), spelling: sysreg))
            if l == 1 { return instruction(address, bytes, "mrs", "\(xt), \(sysreg)",
                structuredOperands: .init(coverage: .complete, opcodeClass: "mrs", operands: [typedRegister, system])) }
            return instruction(address, bytes, "msr", "\(sysreg), \(xt)",
                structuredOperands: .init(coverage: .complete, opcodeClass: "msr", operands: [system, typedRegister]))
        }

        return unknownInstruction(address, bytes, word)
    }

    private func barrierOption(_ crm: Int) -> String {
        switch crm {
        case 0b0001: return "oshld"
        case 0b0010: return "oshst"
        case 0b0011: return "osh"
        case 0b0101: return "nshld"
        case 0b0110: return "nshst"
        case 0b0111: return "nsh"
        case 0b1001: return "ishld"
        case 0b1010: return "ishst"
        case 0b1011: return "ish"
        case 0b1101: return "ld"
        case 0b1110: return "st"
        case 0b1111: return "sy"
        default: return "#\(formatImmediate(UInt64(crm)))"
        }
    }

    /// PSTATE fields Apple LLVM 21 names for MSR (immediate); nil for unallocated op1:op2 pairs.
    /// CFINV/XAFLAG/AXFLAG (op1=0, op2=0...2) and TCO (op1=3, op2=4) are matched earlier by the
    /// MS-24 hook.
    private func pstateField(op1: Int, op2: Int, crm: Int) -> String? {
        switch (op1, op2) {
        case (0b000, 0b011): return "uao"
        case (0b000, 0b100): return "pan"
        case (0b000, 0b101): return "spsel"
        case (0b001, 0b000): return crm & 0b1110 == 0 ? "allint" : (crm & 0b1110 == 0b0010 ? "pm" : nil)
        case (0b011, 0b010): return "dit"
        case (0b011, 0b100): return "tco"
        case (0b011, 0b110): return "daifset"
        case (0b011, 0b111): return "daifclr"
        default: return nil
        }
    }

    private func systemRegisterName(op0: Int, op1: Int, crn: Int, crm: Int, op2: Int) -> String {
        switch (op0, op1, crn, crm, op2) {
        case (3, 3, 4, 2, 0): return "nzcv"
        case (3, 3, 4, 4, 0): return "fpcr"
        case (3, 3, 4, 4, 1): return "fpsr"
        case (3, 3, 13, 0, 2): return "tpidr_el0"
        case (3, 3, 13, 0, 3): return "tpidrro_el0"
        case (3, 0, 0, 0, 0): return "midr_el1"
        default: return "s\(op0)_\(op1)_c\(crn)_c\(crm)_\(op2)"
        }
    }
}
