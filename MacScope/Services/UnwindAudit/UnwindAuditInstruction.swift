import Foundation

struct UnwindAuditModelError: Error, Sendable {
    let code: String
    let message: String
    let address: UInt64?

    init(code: String, message: String, address: UInt64? = nil) {
        self.code = code
        self.message = message
        self.address = address
    }
}

/// A deliberately bounded effect adapter over the existing ARM64 decoder.
/// Exact encoding guards narrow the decoder's broader ISA support to modeled effects.
struct UnwindAuditInstruction: Hashable, Sendable {
    let address: UInt64
    let word: UInt32
    let kind: String
    var rd: Int = 0
    var rn: Int = 0
    var rt2: Int = 0
    var immediate: Int64 = 0
    var addressing: String = ""

    var changesSP: Bool {
        (["add", "sub"].contains(kind) && rd == 31)
            || (["stp", "ldp"].contains(kind) && rn == 31 && addressing != "offset")
    }

    var changesFP: Bool {
        (!["nop", "ret", "bl", "b", "bcond", "stp", "wstr"].contains(kind) && rd == 29)
            || (kind == "ldp" && (rd == 29 || rt2 == 29))
            || (["stp", "ldp"].contains(kind) && rn == 29 && addressing != "offset")
    }

    static func decode(data: Data, start: UInt64, maximum: Int) throws -> [Self] {
        guard start % 4 == 0, !data.isEmpty, data.count % 4 == 0 else {
            throw UnwindAuditModelError(code: "unaligned_function_range", message: "Function bytes must form a nonempty aligned ARM64 range", address: start)
        }
        guard maximum >= 0, data.count / 4 <= maximum else {
            throw UnwindAuditModelError(code: "function_instruction_limit", message: "Function exceeds the instruction limit", address: start)
        }
        let decoded = ARM64Decoder().decode(data, baseAddress: start, maxInstructionCount: maximum)
        guard decoded.count == data.count / 4 else {
            throw UnwindAuditModelError(code: "invalid_instruction_address", message: "Instruction addresses exceed the address space", address: start)
        }
        return try decoded.map(adapt)
    }

    private static func adapt(_ decoded: DecodedInstruction) throws -> Self {
        let address = decoded.address
        guard decoded.bytes.count == 4 else {
            throw UnwindAuditModelError(code: "invalid_instruction_word", message: "Instruction is not a complete word", address: address)
        }
        let word = decoded.bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        func effect(_ kind: String, _ rd: Int = 0, _ rn: Int = 0, _ rt2: Int = 0,
                    _ immediate: Int64 = 0, _ addressing: String = "") -> Self {
            Self(address: address, word: word, kind: kind, rd: rd, rn: rn,
                 rt2: rt2, immediate: immediate, addressing: addressing)
        }
        func fail(_ code: String, _ message: String) -> UnwindAuditModelError {
            UnwindAuditModelError(code: code, message: message, address: address)
        }
        let rd = Int(word & 31), rn = Int((word >> 5) & 31), rm = Int((word >> 16) & 31)
        if word == 0xd503201f { return effect("nop") }
        if word == 0xd65f03c0 { return effect("ret", 0, 30) }
        if [UInt32(0xd503233f), 0xd503237f, 0xd50323bf, 0xd50323ff, 0xd50320ff, 0xd65f0bff, 0xd65f0fff].contains(word) {
            throw fail("unsupported_pauth", "Pointer authentication is outside the integer model")
        }
        if word & 0xfc000000 == 0x94000000 || word & 0xfc000000 == 0x14000000 {
            guard decoded.branchTarget != nil else { throw fail("invalid_instruction_address", "Branch target overflows the address space") }
            return effect(word & 0x80000000 == 0 ? "b" : "bl", 0, 0, 0, signed(word & 0x03ffffff, bits: 26) * 4)
        }
        if word & 0xff000010 == 0x54000000 {
            let condition = Int(word & 15)
            guard condition < 14 else { throw fail("cfg_condition_not_modeled", "Only condition codes EQ through LE are supported") }
            guard decoded.branchTarget != nil else { throw fail("invalid_instruction_address", "Branch target overflows the address space") }
            return effect("bcond", 0, 0, 0, signed((word >> 5) & 0x7ffff, bits: 19) * 4, String(condition))
        }
        let pairForms: [UInt32: (String, String)] = [
            0xa9000000: ("stp", "offset"), 0xa9800000: ("stp", "pre"), 0xa8800000: ("stp", "post"),
            0xa9400000: ("ldp", "offset"), 0xa9c00000: ("ldp", "pre"), 0xa8c00000: ("ldp", "post")
        ]
        if let (kind, indexing) = pairForms[word & 0xffc00000] {
            let rt2 = Int((word >> 10) & 31)
            guard rn == 29 || rn == 31 else { throw fail("unsupported_memory_base", "Integer pair access must use SP or FP") }
            guard kind != "ldp" || rd != rt2 else { throw fail("ambiguous_pair_registers", "LDP destinations overlap") }
            guard indexing == "offset" || rn == 31 || (rn != rd && rn != rt2) else {
                throw fail("ambiguous_writeback", "Pair writeback overlaps a transferred register")
            }
            return effect(kind, rd, rn, rt2, signed((word >> 15) & 127, bits: 7) * 8, indexing)
        }
        let immediateForm = word & 0xff800000
        let immediate = Int64((word >> 10) & 0xfff) << (word & (1 << 22) == 0 ? 0 : 12)
        if immediateForm == 0x91000000 || immediateForm == 0xd1000000 {
            return effect(immediateForm == 0x91000000 ? "add" : "sub", rd, rn, 0, immediate)
        }
        if word & 0xffe0ffe0 == 0xaa0003e0 { return effect("mov", rd, rm) }
        if immediateForm == 0xd2800000 || immediateForm == 0x92800000 {
            let bits = UInt64((word >> 5) & 0xffff) << (Int((word >> 21) & 3) * 16)
            return effect(immediateForm == 0xd2800000 ? "movz" : "movn", rd, 0, 0, Int64(bitPattern: bits))
        }
        let immediateKinds: [UInt32: String] = [0x11000000: "wadd", 0x31000000: "wadds", 0x71000000: "wsubs", 0xb1000000: "xadds", 0xf1000000: "xsubs"]
        if let kind = immediateKinds[immediateForm] {
            guard rn != 31 && !(kind == "wadd" && rd == 31) else {
                throw fail("cfg_wsp_not_modeled", "Flag or W immediate arithmetic using SP is outside this subset")
            }
            return effect(kind, rd, rn, 0, immediate)
        }
        let shiftedKinds: [UInt32: String] = [0x2b000000: "wadds_reg", 0x6b000000: "wsubs_reg", 0xab000000: "xadds_reg", 0xeb000000: "xsubs_reg"]
        if let kind = shiftedKinds[word & 0xff200000] {
            let shift = Int((word >> 22) & 3), amount = Int64((word >> 10) & 63)
            guard shift != 3 && (!kind.hasPrefix("w") || amount < 32) else {
                throw fail("cfg_shift_not_modeled", "Reserved shift or W shift outside 0 through 31")
            }
            return effect(kind, rd, rn, rm, amount, ["lsl", "lsr", "asr"][shift])
        }
        let extendedKinds: [UInt32: String] = [0x2b200000: "wadds_ext", 0x6b200000: "wsubs_ext", 0xab200000: "xadds_ext", 0xeb200000: "xsubs_ext"]
        if let kind = extendedKinds[word & 0xffe00000] {
            let option = Int((word >> 13) & 7), amount = Int64((word >> 10) & 7)
            guard rn != 31 else { throw fail("cfg_extended_sp_not_modeled", "Extended arithmetic with SP source is outside this subset") }
            guard amount <= 4 && (!kind.hasPrefix("w") || (option != 3 && option != 7)) else {
                throw fail("cfg_extend_not_modeled", "Extension or shift is outside the bounded width subset")
            }
            return effect(kind, rd, rn, rm, amount, ["uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"][option])
        }
        if word & 0xffc00000 == 0xb9000000 || word & 0xffc00000 == 0xb9400000 {
            guard rn == 31 else { throw fail("cfg_memory_base_not_modeled", "W memory accesses require unsigned offset from SP") }
            return effect(word & 0x00400000 == 0 ? "wstr" : "wldr", rd, rn, 0, Int64((word >> 10) & 0xfff) * 4)
        }
        let selectForms: Set<UInt32> = [0x1a800000, 0x1a800400, 0x5a800000, 0x5a800400, 0x9a800000, 0x9a800400, 0xda800000, 0xda800400]
        if selectForms.contains(word & 0xffe00c00) {
            let condition = Int((word >> 12) & 15)
            guard condition < 14 else { throw fail("cfg_condition_not_modeled", "Only condition codes EQ through LE are supported") }
            let operation = ["csel", "csinc", "csinv", "csneg"][Int(((word >> 30) & 1) * 2 + ((word >> 10) & 1))]
            return effect((word & 0x80000000 == 0 ? "w" : "x") + operation, rd, rn, rm, 0, String(condition))
        }
        let carryForms: Set<UInt32> = [0x1a000000, 0x3a000000, 0x5a000000, 0x7a000000, 0x9a000000, 0xba000000, 0xda000000, 0xfa000000]
        if carryForms.contains(word & 0xffe0fc00) {
            let operation = ["adc", "adcs", "sbc", "sbcs"][Int((word >> 29) & 3)]
            return effect((word & 0x80000000 == 0 ? "w" : "x") + operation, rd, rn, rm)
        }
        let compareForms: Set<UInt32> = [0x3a400000, 0x3a400800, 0x7a400000, 0x7a400800, 0xba400000, 0xba400800, 0xfa400000, 0xfa400800]
        if compareForms.contains(word & 0xffe00c10) {
            let condition = Int((word >> 12) & 15)
            guard condition < 14 else { throw fail("cfg_condition_not_modeled", "Only condition codes EQ through LE are supported") }
            let kind = (word & 0x80000000 == 0 ? "w" : "x") + (word & 0x40000000 == 0 ? "ccmn" : "ccmp") + (word & 0x800 == 0 ? "_reg" : "_imm")
            return effect(kind, 31, rn, rm, Int64(word & 15), String(condition))
        }
        if word & 0x7c000000 == 0x14000000 || word & 0xfe000000 == 0xd6000000
            || word & 0x7e000000 == 0x34000000 || word & 0x7e000000 == 0x36000000 {
            throw fail("unsupported_control_flow", "Control-flow instruction is outside the bounded subset")
        }
        throw fail("unsupported_instruction", "Instruction \(String(format: "0x%08x", word)) has no modeled effects")
    }

    private static func signed(_ value: UInt32, bits: Int) -> Int64 {
        let value = Int64(value)
        return value & (Int64(1) << (bits - 1)) == 0 ? value : value - (Int64(1) << bits)
    }
}
