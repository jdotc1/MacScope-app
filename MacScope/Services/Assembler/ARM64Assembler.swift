import Foundation

/// A clean-room ARM64 assembler: the inverse of `ARM64Decoder`. It parses one
/// assembly instruction string (in exactly the textual form the decoder emits)
/// and produces its 4-byte little-endian machine encoding, OR a precise
/// diagnostic. It NEVER returns wrong bytes — every operand is range-checked and
/// any unrepresentable request becomes an `.failure`, so the patch-bytes /
/// assemble workflow can trust a `.success` result absolutely.
///
/// Coverage targets the high-frequency integer ISA the decoder renders, so that
/// `ARM64Decoder.decode(assemble(text))` round-trips the canonical text:
///   - move wide: mov (movz/movn folding), movk, movz, movn
///   - add/sub/adds/subs (immediate + shifted register) + cmp/cmn/neg aliases
///   - and/orr/eor/ands (logical immediate via inverse DecodeBitMasks, and
///     shifted register) + tst/mov(register)/mvn aliases
///   - branches: b, b.<cond>, bl, cbz/cbnz, tbz/tbnz, ret, br, blr (+ PC-relative
///     offsets, accepting both absolute `0x…` targets and `#±offset` forms)
///   - load/store: ldr/str and sized/signed variants, in unsigned-offset,
///     unscaled (ldur/stur), pre/post-indexed, and register-offset forms
///   - nop/hint and the common system hints.
struct ARM64Assembler {

    /// The result of assembling one instruction.
    enum Result: Equatable, Sendable {
        case success([UInt8])           // exactly 4 bytes, little-endian
        case failure(Diagnostic)
    }

    /// A precise, human-readable reason an instruction could not be encoded.
    enum Diagnostic: Error, Equatable, Sendable, CustomStringConvertible {
        case empty
        /// The parsed mnemonic names an instruction family for which MacScope has no encoder.
        /// This is the only primary outcome that may consult a supplemental assembler.
        case unsupportedInstructionFamily(String)
        case unknownMnemonic(String)
        case wrongOperandCount(mnemonic: String, expected: String)
        case badOperand(String)
        case badRegister(String)
        case registerWidthMismatch(String)
        case immediateOutOfRange(String)
        case offsetOutOfRange(String)
        case notEncodable(String)

        var description: String {
            switch self {
            case .empty: return "empty instruction"
            case .unsupportedInstructionFamily(let m): return "unsupported instruction family '\(m)'"
            case .unknownMnemonic(let m): return "unknown mnemonic '\(m)'"
            case .wrongOperandCount(let m, let e): return "'\(m)' expects \(e)"
            case .badOperand(let s): return "bad operand '\(s)'"
            case .badRegister(let s): return "bad register '\(s)'"
            case .registerWidthMismatch(let s): return "register width mismatch: \(s)"
            case .immediateOutOfRange(let s): return "immediate out of range: \(s)"
            case .offsetOutOfRange(let s): return "branch/offset out of range: \(s)"
            case .notEncodable(let s): return "not encodable: \(s)"
            }
        }
    }

    /// Assembles `text` placed at `address` (the address is only consulted for
    /// PC-relative forms whose operand is given as an absolute target).
    func assemble(_ text: String, at address: UInt64 = 0) -> Result {
        let (mnemonic, operandText) = Self.split(text)
        guard !mnemonic.isEmpty else { return .failure(.empty) }
        let ops = Self.splitOperands(operandText)

        do {
            let word = try encode(mnemonic: mnemonic, operands: ops, address: address)
            return .success([
                UInt8(word & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 24) & 0xff),
            ])
        } catch let diagnostic as Diagnostic {
            return .failure(diagnostic)
        } catch {
            return .failure(.notEncodable("internal error"))
        }
    }

    // MARK: - Dispatch

    private func encode(mnemonic: String, operands ops: [String], address: UInt64) throws -> UInt32 {
        switch mnemonic {
        case "nop", "yield", "wfe", "wfi", "sev", "sevl", "dgh",
             "xpaclri", "paciaz", "paciasp", "pacibz", "pacibsp",
             "autiaz", "autiasp", "autibz", "autibsp":
            return try encodeHint(mnemonic, ops)
        case "hint":
            return try encodeHintImmediate(ops)

        case "ret", "br", "blr":
            return try encodeRegisterBranch(mnemonic, ops)

        case "b", "bl":
            return try encodeUnconditionalBranch(mnemonic, ops, address: address)

        case "cbz", "cbnz":
            return try encodeCompareBranch(mnemonic, ops, address: address)

        case "tbz", "tbnz":
            return try encodeTestBranch(mnemonic, ops, address: address)

        case "mov":
            return try encodeMov(ops)
        case "movz", "movn", "movk":
            return try encodeMoveWide(mnemonic, ops)

        case "add", "sub":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDThreeSameVector(mnemonic, ops)
            }
            return try encodeAddSub(mnemonic, ops)
        case "adds", "subs":
            return try encodeAddSub(mnemonic, ops)
        case "cmp", "cmn":
            return try encodeCompareAlias(mnemonic, ops)
        case "neg", "negs":
            if mnemonic == "neg", Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDTwoRegMiscVector(mnemonic, ops)
            }
            return try encodeNegAlias(mnemonic, ops)

        case "and", "orr", "eor", "bic", "orn":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDThreeSameVector(mnemonic, ops)
            }
            return try encodeLogical(mnemonic, ops)
        case "ands", "eor2", "eon", "bics":
            return try encodeLogical(mnemonic, ops)
        case "mvn":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDTwoRegMiscVector(mnemonic, ops)
            }
            return try encodeMvn(ops)
        case "tst":
            return try encodeTst(ops)

        case "ldr", "str", "ldrb", "strb", "ldrh", "strh",
             "ldrsb", "ldrsh", "ldrsw",
             "ldur", "stur", "ldurb", "sturb", "ldurh", "sturh",
             "ldursb", "ldursh", "ldursw":
            return try encodeLoadStore(mnemonic, ops)

        case "ld1", "ld2", "ld3", "ld4",
             "st1", "st2", "st3", "st4":
            return try encodeSIMDLoadStoreStructure(mnemonic, ops)

        case "ld1r", "ld2r", "ld3r", "ld4r":
            return try encodeSIMDLoadReplicateStructure(mnemonic, ops)

        case "fmov":
            return try encodeFmov(ops)
        case "fadd", "fsub", "fmul", "fdiv", "fnmul",
             "fmax", "fmin", "fmaxnm", "fminnm":
            if mnemonic == "fmul", Self.isSIMDIndexedElementForm(ops) {
                return try encodeSIMDByElementVector(mnemonic, ops)
            }
            return try encodeFloatingPointTwoSource(mnemonic, ops)
        case "faddp", "fmaxp", "fminp", "fmaxnmp", "fminnmp":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDThreeSameVector(mnemonic, ops)
            }
            return try encodeSIMDScalarPairwise(mnemonic, ops)
        case "fmla", "fmls", "fmulx":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDByElementVector(mnemonic, ops)
        case "fabs", "fneg", "fsqrt":
            return try encodeFloatingPointOneSource(mnemonic, ops)
        case "frinta", "frintn", "frintp", "frintm", "frintz", "frintx", "frinti":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDTwoRegMiscVector(mnemonic, ops)
            }
            return try encodeFloatingPointOneSource(mnemonic, ops)
        case "fmadd", "fmsub", "fnmadd", "fnmsub":
            return try encodeFloatingPointThreeSource(mnemonic, ops)
        case "fcmp", "fcmpe":
            return try encodeFloatingPointCompare(mnemonic, ops)
        case "fcvt":
            return try encodeFloatingPointConvert(ops)
        case "scvtf", "ucvtf", "fcvtzs", "fcvtzu":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDTwoRegMiscVector(mnemonic, ops)
            }
            return try encodeFloatingPointIntegerConversion(mnemonic, ops)
        case "fcvtas", "fcvtau", "fcvtms", "fcvtmu",
             "fcvtns", "fcvtnu", "fcvtps", "fcvtpu":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDTwoRegMiscVector(mnemonic, ops)
        case "fcvtl", "fcvtl2", "fcvtn", "fcvtn2", "fcvtxn", "fcvtxn2":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDFPConvertWidenNarrowVector(mnemonic, ops)
        case "fcsel":
            return try encodeFloatingPointConditionalSelect(ops)

        case "abs", "not", "cnt", "rbit", "rev16", "rev32", "rev64",
             "cls", "clz", "cmle", "cmlt",
             "sqabs", "sqneg", "suqadd", "usqadd":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDTwoRegMiscVector(mnemonic, ops)

        case "saddlp", "uaddlp", "sadalp", "uadalp":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDLongPairwiseVector(mnemonic, ops)

        case "xtn", "xtn2",
             "sqxtn", "sqxtn2", "uqxtn", "uqxtn2",
             "sqxtun", "sqxtun2":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDExtractNarrowVector(mnemonic, ops)

        case "cmeq", "cmgt", "cmge":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            if Self.isSIMDCompareZeroImmediateForm(ops) {
                return try encodeSIMDTwoRegMiscVector(mnemonic, ops)
            }
            return try encodeSIMDThreeSameVector(mnemonic, ops)

        case "addp":
            if Self.isSIMDVectorOperandCandidate(ops.first) {
                return try encodeSIMDThreeSameVector(mnemonic, ops)
            }
            return try encodeSIMDScalarPairwise(mnemonic, ops)

        case "mul",
             "cmhi", "cmhs",
             "smax", "smin", "umax", "umin",
             "smaxp", "sminp", "umaxp", "uminp",
             "sqadd", "uqadd", "sqsub", "uqsub",
             "sshl", "ushl", "mla", "mls":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            if Self.isSIMDIndexedElementForm(ops) {
                return try encodeSIMDByElementVector(mnemonic, ops)
            }
            return try encodeSIMDThreeSameVector(mnemonic, ops)

        case "sqdmulh", "sqrdmulh":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDByElementVector(mnemonic, ops)

        case "sqdmull", "sqdmull2", "smull", "smull2", "umull", "umull2", "smlal", "smlal2", "umlsl", "umlsl2":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            if Self.isSIMDIndexedElementForm(ops) {
                return try encodeSIMDByElementVector(mnemonic, ops)
            }
            return try encodeSIMDThreeDifferentVector(mnemonic, ops)

        case "saddl", "saddl2", "uaddl", "uaddl2", "ssubl", "ssubl2", "usubl", "usubl2",
             "saddw", "saddw2", "uaddw", "uaddw2", "ssubw", "ssubw2", "usubw", "usubw2",
             "sabdl", "sabdl2", "uabdl", "uabdl2", "sabal", "sabal2", "uabal", "uabal2",
             "umlal", "umlal2", "smlsl", "smlsl2",
             "sqdmlal", "sqdmlal2", "sqdmlsl", "sqdmlsl2",
             "pmull", "pmull2":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            if Self.isSIMDIndexedElementForm(ops) {
                return try encodeSIMDByElementVector(mnemonic, ops)
            }
            return try encodeSIMDThreeDifferentVector(mnemonic, ops)

        case "shl", "sshr", "ushr", "srshr", "urshr",
             "ssra", "usra", "srsra", "ursra",
             "sli", "sri", "sqshl", "uqshl", "sqshlu":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDShiftImmediateVector(mnemonic, ops)

        case "shrn", "shrn2", "rshrn", "rshrn2",
             "sqshrn", "sqshrn2", "uqshrn", "uqshrn2",
             "sqrshrn", "sqrshrn2", "uqrshrn", "uqrshrn2",
             "sqshrun", "sqshrun2", "sqrshrun", "sqrshrun2":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDShiftRightNarrowVector(mnemonic, ops)

        case "addv",
             "smaxv", "sminv", "umaxv", "uminv",
             "saddlv", "uaddlv",
             "fmaxv", "fminv", "fmaxnmv", "fminnmv":
            return try encodeSIMDAcrossLanes(mnemonic, ops)

        case "zip1", "zip2", "uzp1", "uzp2", "trn1", "trn2":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDPermuteVector(mnemonic, ops)

        case "ext":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDExtVector(mnemonic, ops)

        case "tbl", "tbx":
            guard Self.isSIMDVectorOperandCandidate(ops.first) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            return try encodeSIMDTableLookupVector(mnemonic, ops)

        default:
            if mnemonic.hasPrefix("b.") {
                return try encodeConditionalBranch(mnemonic, ops, address: address)
            }
            throw Diagnostic.unsupportedInstructionFamily(mnemonic)
        }
    }

    // MARK: - Hints / system

    private func encodeHint(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.isEmpty else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "no operands") }
        let hint: Int
        switch mnemonic {
        case "nop": hint = 0
        case "yield": hint = 1
        case "wfe": hint = 2
        case "wfi": hint = 3
        case "sev": hint = 4
        case "sevl": hint = 5
        case "dgh": hint = 6
        case "xpaclri": hint = 7
        case "paciaz": hint = 24
        case "paciasp": hint = 25
        case "pacibz": hint = 26
        case "pacibsp": hint = 27
        case "autiaz": hint = 28
        case "autiasp": hint = 29
        case "autibz": hint = 30
        case "autibsp": hint = 31
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return hintWord(hint)
    }

    private func encodeHintImmediate(_ ops: [String]) throws -> UInt32 {
        guard ops.count == 1 else { throw Diagnostic.wrongOperandCount(mnemonic: "hint", expected: "1 operand") }
        let value = try parseImmediate(ops[0])
        guard value >= 0, value <= 127 else { throw Diagnostic.immediateOutOfRange("hint #\(value) must be 0..127") }
        return hintWord(Int(value))
    }

    /// Builds the `d503____` system-hint word from a 7-bit hint number.
    private func hintWord(_ hint: Int) -> UInt32 {
        let crm = UInt32((hint >> 3) & 0xf)
        let op2 = UInt32(hint & 0x7)
        return 0xd503_201f & ~(0xf << 8) & ~(0x7 << 5) | (crm << 8) | (op2 << 5)
    }

    // MARK: - Register branches (ret / br / blr)

    private func encodeRegisterBranch(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        let rn: Int
        if mnemonic == "ret" {
            switch ops.count {
            case 0: rn = 30
            case 1:
                let reg = try parseRegister(ops[0])
                guard reg.is64 else { throw Diagnostic.registerWidthMismatch("ret needs an X register") }
                rn = reg.index
            default:
                throw Diagnostic.wrongOperandCount(mnemonic: "ret", expected: "0 or 1 register")
            }
            return 0xd65f_0000 | (UInt32(rn) << 5)
        }

        guard ops.count == 1 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 register") }
        let reg = try parseRegister(ops[0])
        guard reg.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) needs an X register") }
        let base: UInt32 = mnemonic == "br" ? 0xd61f_0000 : 0xd63f_0000
        return base | (UInt32(reg.index) << 5)
    }

    // MARK: - Branch targets

    /// Resolves a branch operand (absolute `0x…` target, decimal address, or a
    /// `#±offset`) into a byte offset from `address`. Used by b/bl/cbz/tbz/b.cond.
    private func branchOffset(_ token: String, address: UInt64) throws -> Int {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            return Int(try parseImmediate(trimmed))
        }
        // Absolute target.
        let target = try parseUnsignedAddress(trimmed)
        let delta = Int64(bitPattern: target &- address)
        return Int(delta)
    }

    private func encodeUnconditionalBranch(_ mnemonic: String, _ ops: [String], address: UInt64) throws -> UInt32 {
        guard ops.count == 1 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 target") }
        let offset = try branchOffset(ops[0], address: address)
        let imm = try encodeBranchImm(offset, bits: 26)
        let base: UInt32 = mnemonic == "bl" ? 0x9400_0000 : 0x1400_0000
        return base | imm
    }

    private func encodeConditionalBranch(_ mnemonic: String, _ ops: [String], address: UInt64) throws -> UInt32 {
        guard ops.count == 1 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "1 target") }
        let condName = String(mnemonic.dropFirst(2))
        guard let cond = Self.conditionCode(condName) else { throw Diagnostic.unknownMnemonic(mnemonic) }
        let offset = try branchOffset(ops[0], address: address)
        let imm = try encodeBranchImm(offset, bits: 19)
        return 0x5400_0000 | (imm << 5) | UInt32(cond)
    }

    private func encodeCompareBranch(_ mnemonic: String, _ ops: [String], address: UInt64) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "register, target") }
        let reg = try parseRegister(ops[0])
        let offset = try branchOffset(ops[1], address: address)
        let imm = try encodeBranchImm(offset, bits: 19)
        var word: UInt32 = 0x3400_0000
        if reg.is64 { word |= 0x8000_0000 }
        if mnemonic == "cbnz" { word |= 0x0100_0000 }
        return word | (imm << 5) | UInt32(reg.index)
    }

    private func encodeTestBranch(_ mnemonic: String, _ ops: [String], address: UInt64) throws -> UInt32 {
        guard ops.count == 3 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "register, #bit, target") }
        let reg = try parseRegister(ops[0])
        let bit = try parseImmediate(ops[1])
        let maxBit = reg.is64 ? 63 : 31
        guard bit >= 0, bit <= Int64(maxBit) else { throw Diagnostic.immediateOutOfRange("bit #\(bit) must be 0..\(maxBit)") }
        let offset = try branchOffset(ops[2], address: address)
        // tbz/tbnz reach ±32 KiB (14-bit scaled).
        let imm = try encodeBranchImm(offset, bits: 14)
        var word: UInt32 = 0x3600_0000
        if (bit & 0x20) != 0 { word |= 0x8000_0000 } // b5
        if mnemonic == "tbnz" { word |= 0x0100_0000 }
        word |= UInt32(bit & 0x1f) << 19          // b40
        word |= imm << 5
        word |= UInt32(reg.index)
        return word
    }

    /// Scales/sign-checks a byte offset into the `bits`-wide branch immediate
    /// field (offset is always a multiple of 4, the instruction word size).
    private func encodeBranchImm(_ offset: Int, bits: Int) throws -> UInt32 {
        guard offset % 4 == 0 else { throw Diagnostic.offsetOutOfRange("offset \(offset) not 4-byte aligned") }
        let scaled = offset / 4
        let minV = -(1 << (bits - 1))
        let maxV = (1 << (bits - 1)) - 1
        guard scaled >= minV, scaled <= maxV else {
            throw Diagnostic.offsetOutOfRange("offset \(offset) exceeds ±\((1 << (bits - 1)) * 4) range")
        }
        return UInt32(scaled & ((1 << bits) - 1))
    }

    // MARK: - Move wide

    private func encodeMov(_ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: "mov", expected: "Rd, (Rm | #imm)") }

        // MOV (to/from SP): `mov Xd|sp, Xn|sp` is the `ADD Rd, Rn, #0` alias — reg 31 is SP here,
        // not xzr, so it must NOT go through the ORR register-move path. Round-trips the decoder's
        // mov-to/from-SP alias back to the original add-immediate bytes.
        if isStackPointer(ops[0]) || isStackPointer(ops[1]) {
            let rd = try parseRegister(ops[0], allowSP: true)
            let rn = try parseRegister(ops[1], allowSP: true)
            guard rd.is64 == rn.is64 else { throw Diagnostic.registerWidthMismatch("mov Rd, sp width mismatch") }
            var word: UInt32 = rd.is64 ? 0x9100_0000 : 0x1100_0000 // ADD immediate, imm12=0, sh=0
            word |= UInt32(rn.index) << 5
            word |= UInt32(rd.index)
            return word
        }

        let rd = try parseRegister(ops[0])

        // mov Rd, Rm  -> ORR Rd, ZR, Rm (register move).
        if let rm = try? parseRegister(ops[1]) {
            guard rm.is64 == rd.is64 else { throw Diagnostic.registerWidthMismatch("mov Rd, Rm width mismatch") }
            var word: UInt32 = 0x2a00_0000 // ORR shifted register, opc=01
            if rd.is64 { word |= 0x8000_0000 }
            word |= 0x1f << 5                       // Rn = ZR
            word |= UInt32(rm.index) << 16          // Rm
            word |= UInt32(rd.index)
            return word
        }

        // mov Rd, #imm  -> prefer MOVZ, then MOVN, then ORR(immediate) like the
        // decoder's alias choice. We just need SOME encoding the decoder folds
        // back to `mov`; MOVZ/MOVN cover the move-wide-expressible values and ORR
        // covers the bitmask-expressible remainder.
        let value = try parseImmediateWidth(ops[1], is64: rd.is64)
        let width = rd.is64 ? 64 : 32
        let mask: UInt64 = rd.is64 ? ~0 : 0xffff_ffff
        let v = value & mask

        if let shift = moveZeroShift(v, width: width) {
            return moveWideWord(opc: 0b10, rd: rd, imm16: UInt16((v >> UInt64(shift)) & 0xffff), shift: shift)
        }
        let inverted = (~v) & mask
        if let shift = moveZeroShift(inverted, width: width) {
            return moveWideWord(opc: 0b00, rd: rd, imm16: UInt16((inverted >> UInt64(shift)) & 0xffff), shift: shift)
        }
        // Fall back to ORR(immediate) bitmask if expressible.
        if let (n, immr, imms) = encodeBitMasks(v, width: width) {
            var word: UInt32 = 0x3200_0000 // ORR immediate, opc=01
            if rd.is64 { word |= 0x8000_0000 }
            word |= n << 22
            word |= UInt32(immr) << 16
            word |= UInt32(imms) << 10
            word |= 0x1f << 5                       // Rn = ZR
            word |= UInt32(rd.index)
            return word
        }
        throw Diagnostic.notEncodable("mov #\(String(format: "0x%llx", v)) is not move-wide or bitmask expressible")
    }

    private func encodeMoveWide(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count >= 2, ops.count <= 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Rd, #imm [, lsl #shift]")
        }
        let rd = try parseRegister(ops[0])
        let raw = try parseImmediate(ops[1])
        var shift = 0
        if ops.count == 3 {
            shift = try parseShiftAmount(ops[2], allowedTypes: ["lsl"])
        }
        let maxShift = rd.is64 ? 48 : 16
        guard shift == 0 || shift == 16 || shift == 32 || shift == 48, shift <= maxShift else {
            throw Diagnostic.immediateOutOfRange("lsl #\(shift) invalid for \(mnemonic)")
        }
        guard raw >= 0, raw <= 0xffff else {
            throw Diagnostic.immediateOutOfRange("\(mnemonic) immediate must be a 16-bit value")
        }
        let opc: UInt32
        switch mnemonic {
        case "movn": opc = 0b00
        case "movz": opc = 0b10
        case "movk": opc = 0b11
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return moveWideWord(opc: opc, rd: rd, imm16: UInt16(raw), shift: shift)
    }

    private func moveWideWord(opc: UInt32, rd: Register, imm16: UInt16, shift: Int) -> UInt32 {
        var word: UInt32 = 0x1280_0000
        if rd.is64 { word |= 0x8000_0000 }
        word |= opc << 29
        word |= UInt32(shift / 16) << 21
        word |= UInt32(imm16) << 5
        word |= UInt32(rd.index)
        return word
    }

    /// Returns the halfword shift (0/16/32/48) if `value` is a single 16-bit
    /// field on a halfword boundary (MOVZ-expressible), else nil.
    private func moveZeroShift(_ value: UInt64, width: Int) -> Int? {
        if value == 0 { return 0 }
        var shift = 0
        while shift < width {
            let field = UInt64(0xffff) << UInt64(shift)
            if (value & ~field) == 0 { return shift }
            shift += 16
        }
        return nil
    }

    // MARK: - Add / Sub (immediate + shifted register)

    private func encodeAddSub(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count >= 3 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Rd, Rn, (Rm | #imm) [, shift]") }
        let setsFlags = mnemonic.hasSuffix("s")
        let isSub = mnemonic.hasPrefix("sub")
        let rd = try parseRegister(ops[0], allowSP: !setsFlags)
        let rn = try parseRegister(ops[1], allowSP: true)
        guard rd.is64 == rn.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) operand widths differ") }

        if ops[2].hasPrefix("#") {
            return try encodeAddSubImmediate(rd: rd, rn: rn, imm: ops[2], extraShift: ops.count > 3 ? ops[3] : nil,
                                             isSub: isSub, setsFlags: setsFlags)
        }
        let rm = try parseRegister(ops[2])
        guard rm.is64 == rd.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) operand widths differ") }
        let shift = ops.count > 3 ? try parseShiftSpec(ops[3], allowedTypes: ["lsl", "lsr", "asr"], width: rd.is64 ? 64 : 32) : (0, 0)
        return addSubShiftedWord(rd: rd, rn: rn, rm: rm, shiftType: UInt32(shift.0), amount: UInt32(shift.1),
                                 isSub: isSub, setsFlags: setsFlags)
    }

    private func encodeAddSubImmediate(rd: Register, rn: Register, imm: String, extraShift: String?,
                                       isSub: Bool, setsFlags: Bool) throws -> UInt32 {
        var value = try parseImmediate(imm)
        var shift12 = false
        if let extra = extraShift {
            let amount = try parseShiftAmount(extra, allowedTypes: ["lsl"])
            guard amount == 0 || amount == 12 else { throw Diagnostic.immediateOutOfRange("add/sub shift must be lsl #0 or #12") }
            shift12 = amount == 12
        }
        // The decoder folds the shift into the value, so accept an unshifted value
        // that happens to be a multiple of 4096 fitting 12 bits when shifted.
        if !shift12, value > 0xfff, value <= 0xfff_fff, value % 4096 == 0 {
            value >>= 12
            shift12 = true
        }
        guard value >= 0, value <= 0xfff else { throw Diagnostic.immediateOutOfRange("add/sub immediate must be 12-bit (optionally lsl #12)") }
        var word: UInt32 = 0x1100_0000
        if rd.is64 { word |= 0x8000_0000 }
        if isSub { word |= 0x4000_0000 }
        if setsFlags { word |= 0x2000_0000 }
        if shift12 { word |= 0x0040_0000 }
        word |= UInt32(value & 0xfff) << 10
        word |= UInt32(rn.index) << 5
        word |= UInt32(rd.index)
        return word
    }

    private func addSubShiftedWord(rd: Register, rn: Register, rm: Register, shiftType: UInt32, amount: UInt32,
                                   isSub: Bool, setsFlags: Bool) -> UInt32 {
        var word: UInt32 = 0x0b00_0000
        if rd.is64 { word |= 0x8000_0000 }
        if isSub { word |= 0x4000_0000 }
        if setsFlags { word |= 0x2000_0000 }
        word |= shiftType << 22
        word |= UInt32(rm.index) << 16
        word |= amount << 10
        word |= UInt32(rn.index) << 5
        word |= UInt32(rd.index)
        return word
    }

    private func encodeCompareAlias(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        // cmp Rn, X  == subs ZR, Rn, X ; cmn == adds ZR, Rn, X
        guard ops.count >= 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Rn, (Rm | #imm)") }
        let isSub = mnemonic == "cmp"
        let rn = try parseRegister(ops[0], allowSP: true)
        let zr = Register(index: 31, is64: rn.is64)
        if ops[1].hasPrefix("#") {
            return try encodeAddSubImmediate(rd: zr, rn: rn, imm: ops[1], extraShift: ops.count > 2 ? ops[2] : nil,
                                             isSub: isSub, setsFlags: true)
        }
        let rm = try parseRegister(ops[1])
        guard rm.is64 == rn.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) operand widths differ") }
        let shift = ops.count > 2 ? try parseShiftSpec(ops[2], allowedTypes: ["lsl", "lsr", "asr"], width: rn.is64 ? 64 : 32) : (0, 0)
        return addSubShiftedWord(rd: zr, rn: rn, rm: rm, shiftType: UInt32(shift.0), amount: UInt32(shift.1),
                                 isSub: isSub, setsFlags: true)
    }

    private func encodeNegAlias(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        // neg Rd, Rm == sub Rd, ZR, Rm ; negs == subs Rd, ZR, Rm
        guard ops.count >= 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Rd, Rm [, shift]") }
        let rd = try parseRegister(ops[0])
        let zr = Register(index: 31, is64: rd.is64)
        let rm = try parseRegister(ops[1])
        guard rm.is64 == rd.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) operand widths differ") }
        let shift = ops.count > 2 ? try parseShiftSpec(ops[2], allowedTypes: ["lsl", "lsr", "asr"], width: rd.is64 ? 64 : 32) : (0, 0)
        return addSubShiftedWord(rd: rd, rn: zr, rm: rm, shiftType: UInt32(shift.0), amount: UInt32(shift.1),
                                 isSub: true, setsFlags: mnemonic == "negs")
    }

    // MARK: - Logical

    /// opc/negate for the shifted-register and immediate logical encodings.
    private func logicalOpcNegate(_ mnemonic: String) -> (opc: UInt32, negate: UInt32)? {
        switch mnemonic {
        case "and": return (0b00, 0)
        case "bic": return (0b00, 1)
        case "orr": return (0b01, 0)
        case "orn": return (0b01, 1)
        case "eor": return (0b10, 0)
        case "eon": return (0b10, 1)
        case "ands": return (0b11, 0)
        case "bics": return (0b11, 1)
        default: return nil
        }
    }

    private func encodeLogical(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard let (opc, negate) = logicalOpcNegate(mnemonic) else { throw Diagnostic.unknownMnemonic(mnemonic) }
        guard ops.count >= 3 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Rd, Rn, (Rm | #imm) [, shift]") }
        // Immediate forms exist only for and/orr/eor/ands (negate==0).
        if ops[2].hasPrefix("#") {
            guard negate == 0 else { throw Diagnostic.notEncodable("\(mnemonic) has no immediate form") }
            let rd = try parseRegister(ops[0], allowSP: mnemonic != "ands")
            let rn = try parseRegister(ops[1])
            guard rd.is64 == rn.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) operand widths differ") }
            let value = try parseImmediateWidth(ops[2], is64: rd.is64)
            return try logicalImmediateWord(opc: opc, rd: rd, rn: rn, value: value)
        }
        let rd = try parseRegister(ops[0])
        let rn = try parseRegister(ops[1])
        let rm = try parseRegister(ops[2])
        guard rd.is64 == rn.is64, rd.is64 == rm.is64 else { throw Diagnostic.registerWidthMismatch("\(mnemonic) operand widths differ") }
        let shift = ops.count > 3 ? try parseShiftSpec(ops[3], allowedTypes: ["lsl", "lsr", "asr", "ror"], width: rd.is64 ? 64 : 32) : (0, 0)
        return logicalShiftedWord(opc: opc, negate: negate, rd: rd, rn: rn, rm: rm,
                                  shiftType: UInt32(shift.0), amount: UInt32(shift.1))
    }

    private func encodeMvn(_ ops: [String]) throws -> UInt32 {
        // mvn Rd, Rm == orn Rd, ZR, Rm
        guard ops.count >= 2 else { throw Diagnostic.wrongOperandCount(mnemonic: "mvn", expected: "Rd, Rm [, shift]") }
        let rd = try parseRegister(ops[0])
        let rm = try parseRegister(ops[1])
        guard rd.is64 == rm.is64 else { throw Diagnostic.registerWidthMismatch("mvn operand widths differ") }
        let zr = Register(index: 31, is64: rd.is64)
        let shift = ops.count > 2 ? try parseShiftSpec(ops[2], allowedTypes: ["lsl", "lsr", "asr", "ror"], width: rd.is64 ? 64 : 32) : (0, 0)
        return logicalShiftedWord(opc: 0b01, negate: 1, rd: rd, rn: zr, rm: rm,
                                  shiftType: UInt32(shift.0), amount: UInt32(shift.1))
    }

    private func encodeTst(_ ops: [String]) throws -> UInt32 {
        // tst Rn, X == ands ZR, Rn, X
        guard ops.count >= 2 else { throw Diagnostic.wrongOperandCount(mnemonic: "tst", expected: "Rn, (Rm | #imm) [, shift]") }
        let rn = try parseRegister(ops[0])
        let zr = Register(index: 31, is64: rn.is64)
        if ops[1].hasPrefix("#") {
            let value = try parseImmediateWidth(ops[1], is64: rn.is64)
            return try logicalImmediateWord(opc: 0b11, rd: zr, rn: rn, value: value)
        }
        let rm = try parseRegister(ops[1])
        guard rm.is64 == rn.is64 else { throw Diagnostic.registerWidthMismatch("tst operand widths differ") }
        let shift = ops.count > 2 ? try parseShiftSpec(ops[2], allowedTypes: ["lsl", "lsr", "asr", "ror"], width: rn.is64 ? 64 : 32) : (0, 0)
        return logicalShiftedWord(opc: 0b11, negate: 0, rd: zr, rn: rn, rm: rm,
                                  shiftType: UInt32(shift.0), amount: UInt32(shift.1))
    }

    private func logicalShiftedWord(opc: UInt32, negate: UInt32, rd: Register, rn: Register, rm: Register,
                                    shiftType: UInt32, amount: UInt32) -> UInt32 {
        var word: UInt32 = 0x0a00_0000
        if rd.is64 { word |= 0x8000_0000 }
        word |= opc << 29
        word |= shiftType << 22
        word |= negate << 21
        word |= UInt32(rm.index) << 16
        word |= amount << 10
        word |= UInt32(rn.index) << 5
        word |= UInt32(rd.index)
        return word
    }

    private func logicalImmediateWord(opc: UInt32, rd: Register, rn: Register, value: UInt64) throws -> UInt32 {
        let width = rd.is64 ? 64 : 32
        guard let (n, immr, imms) = encodeBitMasks(value, width: width) else {
            throw Diagnostic.notEncodable("\(String(format: "0x%llx", value)) is not a valid logical-immediate bitmask")
        }
        var word: UInt32 = 0x1200_0000
        if rd.is64 { word |= 0x8000_0000 }
        word |= opc << 29
        word |= n << 22
        word |= UInt32(immr) << 16
        word |= UInt32(imms) << 10
        word |= UInt32(rn.index) << 5
        word |= UInt32(rd.index)
        return word
    }

    // MARK: - Load / store

    private struct LoadStoreForm {
        var size: UInt32
        var opc: UInt32
        var destIs64: Bool
        var scaleLog2: Int
        var isUnscaled: Bool
    }

    private func loadStoreForm(_ mnemonic: String) -> LoadStoreForm? {
        switch mnemonic {
        case "strb":   return .init(size: 0, opc: 0, destIs64: false, scaleLog2: 0, isUnscaled: false)
        case "ldrb":   return .init(size: 0, opc: 1, destIs64: false, scaleLog2: 0, isUnscaled: false)
        case "ldrsb":  return .init(size: 0, opc: 2, destIs64: true,  scaleLog2: 0, isUnscaled: false)
        case "strh":   return .init(size: 1, opc: 0, destIs64: false, scaleLog2: 1, isUnscaled: false)
        case "ldrh":   return .init(size: 1, opc: 1, destIs64: false, scaleLog2: 1, isUnscaled: false)
        case "ldrsh":  return .init(size: 1, opc: 2, destIs64: true,  scaleLog2: 1, isUnscaled: false)
        case "ldrsw":  return .init(size: 2, opc: 2, destIs64: true,  scaleLog2: 2, isUnscaled: false)
        case "sturb":  return .init(size: 0, opc: 0, destIs64: false, scaleLog2: 0, isUnscaled: true)
        case "ldurb":  return .init(size: 0, opc: 1, destIs64: false, scaleLog2: 0, isUnscaled: true)
        case "ldursb": return .init(size: 0, opc: 2, destIs64: true,  scaleLog2: 0, isUnscaled: true)
        case "sturh":  return .init(size: 1, opc: 0, destIs64: false, scaleLog2: 1, isUnscaled: true)
        case "ldurh":  return .init(size: 1, opc: 1, destIs64: false, scaleLog2: 1, isUnscaled: true)
        case "ldursh": return .init(size: 1, opc: 2, destIs64: true,  scaleLog2: 1, isUnscaled: true)
        case "ldursw": return .init(size: 2, opc: 2, destIs64: true,  scaleLog2: 2, isUnscaled: true)
        default: return nil
        }
    }

    /// Resolves str/ldr/ldur/stur whose width is determined by the destination
    /// register (w-form -> 32-bit, x-form -> 64-bit).
    private func sizedLoadStoreForm(_ mnemonic: String, destIs64: Bool) -> LoadStoreForm? {
        let isLoad = mnemonic.hasPrefix("ld")
        let unscaled = mnemonic == "ldur" || mnemonic == "stur"
        let opc: UInt32 = isLoad ? 1 : 0
        if destIs64 {
            return .init(size: 3, opc: opc, destIs64: true, scaleLog2: 3, isUnscaled: unscaled)
        }
        return .init(size: 2, opc: opc, destIs64: false, scaleLog2: 2, isUnscaled: unscaled)
    }

    private func encodeLoadStore(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count >= 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Rt, [Xn, ...]") }
        let rt = try parseRegister(ops[0])

        let form: LoadStoreForm
        if mnemonic == "ldr" || mnemonic == "str" || mnemonic == "ldur" || mnemonic == "stur" {
            guard let f = sizedLoadStoreForm(mnemonic, destIs64: rt.is64) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            form = f
        } else {
            guard let f = loadStoreForm(mnemonic) else { throw Diagnostic.unknownMnemonic(mnemonic) }
            form = f
            // The Rt width is fixed by the mnemonic; reject a contradictory reg.
            if rt.is64 != f.destIs64 { throw Diagnostic.registerWidthMismatch("\(mnemonic) needs a \(f.destIs64 ? "X" : "W") register") }
        }

        // The memory operand is everything after the first comma; re-join because
        // splitOperands keeps bracket groups together but pre/post forms split.
        let mem = try parseMemoryOperand(Array(ops.dropFirst()))
        return try encodeLoadStoreWord(form: form, rt: rt, mem: mem)
    }

    private enum MemoryOperand {
        case unsignedOffset(base: Register, offset: Int)          // [Xn, #imm] or [Xn]
        case preIndexed(base: Register, offset: Int)              // [Xn, #imm]!
        case postIndexed(base: Register, offset: Int)             // [Xn], #imm
        case postIndexedRegister(base: Register, index: Register) // [Xn], Xm
        case registerOffset(base: Register, index: Register, extend: String?, amount: Int?) // [Xn, Rm{, ext{ #amt}}]
    }

    private func parseMemoryOperand(_ tokens: [String]) throws -> MemoryOperand {
        guard let first = tokens.first else { throw Diagnostic.badOperand("missing memory operand") }
        // Post-indexed prints as `[Xn], #imm` -> two tokens: "[Xn]" and "#imm".
        if first.hasPrefix("[") && first.hasSuffix("]") && !first.contains(",") {
            let base = try parseRegister(String(first.dropFirst().dropLast()), allowSP: true)
            guard base.is64 else { throw Diagnostic.registerWidthMismatch("base register must be X/SP") }
            if tokens.count == 1 {
                return .unsignedOffset(base: base, offset: 0)
            }
            guard tokens.count == 2 else { throw Diagnostic.badOperand("malformed post-indexed operand") }
            let postIndex = tokens[1].trimmingCharacters(in: .whitespaces)
            if postIndex.hasPrefix("#") {
                let offset = Int(try parseImmediate(postIndex))
                return .postIndexed(base: base, offset: offset)
            }
            if let offset = try? Int(parseImmediate(postIndex)) {
                return .postIndexed(base: base, offset: offset)
            }
            let index = try parseRegister(postIndex)
            guard index.is64 else { throw Diagnostic.registerWidthMismatch("post-index register must be X") }
            return .postIndexedRegister(base: base, index: index)
        }

        // Otherwise the whole memory operand is a single bracketed token (possibly
        // ending with `!`). Rejoin tokens that were split inside the brackets.
        let joined = tokens.joined(separator: ", ")
        var inner = joined
        var preIndexed = false
        guard inner.hasPrefix("[") else { throw Diagnostic.badOperand("expected '[' in memory operand") }
        if inner.hasSuffix("]!") {
            preIndexed = true
            inner = String(inner.dropFirst().dropLast(2))
        } else if inner.hasSuffix("]") {
            inner = String(inner.dropFirst().dropLast())
        } else {
            throw Diagnostic.badOperand("unterminated memory operand '\(joined)'")
        }

        let parts = Self.splitOperands(inner)
        guard let baseTok = parts.first else { throw Diagnostic.badOperand("empty memory operand") }
        let base = try parseRegister(baseTok, allowSP: true)
        guard base.is64 else { throw Diagnostic.registerWidthMismatch("base register must be X/SP") }

        if parts.count == 1 {
            return preIndexed ? .preIndexed(base: base, offset: 0) : .unsignedOffset(base: base, offset: 0)
        }

        // Second part is either #imm or an index register.
        if parts[1].hasPrefix("#") {
            let offset = Int(try parseImmediate(parts[1]))
            return preIndexed ? .preIndexed(base: base, offset: offset) : .unsignedOffset(base: base, offset: offset)
        }

        // Register offset: [Xn, Rm {, ext {#amt}}].
        guard !preIndexed else { throw Diagnostic.badOperand("register offset cannot be pre-indexed") }
        let index = try parseRegister(parts[1])
        var extend: String? = nil
        var amount: Int? = nil
        if parts.count >= 3 {
            let extendTokens = parts[2].split(separator: " ").map(String.init)
            extend = extendTokens.first.map { $0.lowercased() }
            if extendTokens.count >= 2 {
                amount = Int(try parseImmediate(extendTokens[1]))
            }
        }
        return .registerOffset(base: base, index: index, extend: extend, amount: amount)
    }

    private func encodeLoadStoreWord(form: LoadStoreForm, rt: Register, mem: MemoryOperand) throws -> UInt32 {
        let base: UInt32 = 0x3800_0000 | (form.size << 30) | (form.opc << 22)

        switch mem {
        case .unsignedOffset(let baseReg, let offset):
            if offset == 0 {
                // Prefer the unscaled (ldur/stur) spelling only when the decoder
                // would emit it; for the canonical scaled forms, offset 0 uses the
                // unsigned-immediate encoding (bit24=1).
                if form.isUnscaled {
                    return base | (UInt32(baseReg.index) << 5) | UInt32(rt.index)
                }
                return base | 0x0100_0000 | (UInt32(baseReg.index) << 5) | UInt32(rt.index)
            }
            if form.isUnscaled {
                guard offset >= -256, offset <= 255 else { throw Diagnostic.offsetOutOfRange("unscaled offset \(offset) must be -256..255") }
                let imm9 = UInt32(offset & 0x1ff)
                return base | (imm9 << 12) | (UInt32(baseReg.index) << 5) | UInt32(rt.index)
            }
            // Scaled unsigned offset.
            guard offset >= 0 else { throw Diagnostic.offsetOutOfRange("scaled offset must be non-negative; use ldur/stur for negative") }
            let scale = 1 << form.scaleLog2
            guard offset % scale == 0 else { throw Diagnostic.offsetOutOfRange("offset \(offset) not a multiple of \(scale)") }
            let scaled = offset / scale
            guard scaled <= 0xfff else { throw Diagnostic.offsetOutOfRange("offset \(offset) exceeds scaled 12-bit range") }
            return base | 0x0100_0000 | (UInt32(scaled) << 10) | (UInt32(baseReg.index) << 5) | UInt32(rt.index)

        case .preIndexed(let baseReg, let offset):
            guard !form.isUnscaled else { throw Diagnostic.notEncodable("pre-indexed form not valid for ldur/stur") }
            guard offset >= -256, offset <= 255 else { throw Diagnostic.offsetOutOfRange("pre-indexed offset \(offset) must be -256..255") }
            let imm9 = UInt32(offset & 0x1ff)
            return base | (imm9 << 12) | 0x0000_0c00 | (UInt32(baseReg.index) << 5) | UInt32(rt.index)

        case .postIndexed(let baseReg, let offset):
            guard !form.isUnscaled else { throw Diagnostic.notEncodable("post-indexed form not valid for ldur/stur") }
            guard offset >= -256, offset <= 255 else { throw Diagnostic.offsetOutOfRange("post-indexed offset \(offset) must be -256..255") }
            let imm9 = UInt32(offset & 0x1ff)
            return base | (imm9 << 12) | 0x0000_0400 | (UInt32(baseReg.index) << 5) | UInt32(rt.index)

        case .postIndexedRegister:
            throw Diagnostic.notEncodable("register post-index form not valid for \(form.isUnscaled ? "ldur/stur" : "scalar load/store")")

        case .registerOffset(let baseReg, let index, let extend, let amount):
            guard !form.isUnscaled else { throw Diagnostic.notEncodable("register-offset form not valid for ldur/stur") }
            let option: UInt32
            switch (extend ?? (index.is64 ? "lsl" : "uxtw")) {
            case "uxtw": option = 0b010
            case "lsl": option = 0b011
            case "sxtw": option = 0b110
            case "sxtx": option = 0b111
            default: throw Diagnostic.badOperand("bad index extend '\(extend ?? "")'")
            }
            // option[0] selects the index width: 0 -> W (uxtw/sxtw), 1 -> X (lsl/sxtx).
            let indexShouldBe64 = (option & 0x1) != 0
            guard index.is64 == indexShouldBe64 else { throw Diagnostic.registerWidthMismatch("index register width does not match extend") }
            var sBit: UInt32 = 0
            if let amount = amount {
                guard amount == form.scaleLog2 else { throw Diagnostic.immediateOutOfRange("index shift must be #\(form.scaleLog2)") }
                sBit = 1
            }
            return base | 0x0020_0000 | (option << 13) | (UInt32(index.index) << 16) | (sBit << 12)
                | 0x0000_0800 | (UInt32(baseReg.index) << 5) | UInt32(rt.index)
        }
    }

    // MARK: - Advanced SIMD three-same (vector)

    private struct SIMDThreeSameVectorForm {
        var u: UInt32
        var opcode: UInt32
        var legalArrangements: Set<String>
        var encodedSizeOverride: UInt32? = nil
    }

    private static let simdAllIntegerArrangements: Set<String> = ["8b", "16b", "4h", "8h", "2s", "4s", "2d"]
    private static let simdNoDoubleArrangements: Set<String> = ["8b", "16b", "4h", "8h", "2s", "4s"]
    private static let simdByteArrangements: Set<String> = ["8b", "16b"]
    private static let simdFPPairwiseArrangements: Set<String> = ["2s", "4s", "2d"]
    private static let simdFP16PairwiseArrangements: Set<String> = ["4h", "8h"]
    private static let simdFPPairwiseMnemonics: Set<String> = ["faddp", "fmaxp", "fminp", "fmaxnmp", "fminnmp"]

    // MARK: - Advanced SIMD structure load/store

    private struct SIMDStructureLane: Equatable {
        var name: String
        var size: UInt32
        var index: Int
    }

    private struct SIMDStructureRegisterList: Equatable {
        var firstIndex: Int
        var count: Int
        var arrangement: SIMDVectorArrangement?
        var lane: SIMDStructureLane?
    }

    private struct SIMDStructureLaneRegister: Equatable {
        var index: Int
        var name: String
        var size: UInt32
    }

    private static let simdStructureArrangementNames: Set<String> = [
        "8b", "16b", "4h", "8h", "2s", "4s", "1d", "2d",
    ]

    private func encodeSIMDLoadStoreStructure(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count >= 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "{Vt.<T>[, ...]}, [Xn]{, #imm|Xm}")
        }

        let list = try parseSIMDStructureRegisterList(ops[0])
        let mem = try parseMemoryOperand(Array(ops.dropFirst()))
        if list.lane != nil {
            return try encodeSIMDLoadStoreSingleStructure(mnemonic, list: list, mem: mem)
        }
        return try encodeSIMDLoadStoreMultipleStructure(mnemonic, list: list, mem: mem)
    }

    private func encodeSIMDLoadReplicateStructure(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count >= 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "{Vt.<T>[, ...]}, [Xn]{, #imm|Xm}")
        }
        let expectedCount = try simdStructureMnemonicCount(mnemonic)
        let list = try parseSIMDStructureRegisterList(ops[0])
        guard list.lane == nil, let arrangement = list.arrangement else {
            throw Diagnostic.badOperand("\(mnemonic) requires a vector arrangement list without a lane")
        }
        guard list.count == expectedCount else {
            throw Diagnostic.notEncodable("\(mnemonic) requires exactly \(expectedCount) consecutive register\(expectedCount == 1 ? "" : "s")")
        }

        let mem = try parseMemoryOperand(Array(ops.dropFirst()))
        let stride = (1 << Int(arrangement.size)) * list.count
        let address = try encodeSIMDStructureAddress(mem, stride: stride, mnemonic: mnemonic)
        let countMinusOne = expectedCount - 1
        let rFlag = UInt32(countMinusOne & 0x1)
        let opcode3 = UInt32((0b11 << 1) | ((countMinusOne >> 1) & 0x1))

        return 0x0d00_0000
            | (arrangement.q << 30)
            | (address.postIndex << 23)
            | (1 << 22)
            | (rFlag << 21)
            | (address.rm << 16)
            | (opcode3 << 13)
            | (arrangement.size << 10)
            | (address.rn << 5)
            | UInt32(list.firstIndex)
    }

    private func encodeSIMDLoadStoreMultipleStructure(
        _ mnemonic: String,
        list: SIMDStructureRegisterList,
        mem: MemoryOperand
    ) throws -> UInt32 {
        guard let arrangement = list.arrangement else {
            throw Diagnostic.badOperand("\(mnemonic) requires a vector arrangement list")
        }
        let mnemonicCount = try simdStructureMnemonicCount(mnemonic)
        if mnemonicCount == 1 {
            guard (1...4).contains(list.count) else {
                throw Diagnostic.notEncodable("\(mnemonic) supports 1..4 consecutive registers")
            }
        } else {
            guard list.count == mnemonicCount else {
                throw Diagnostic.notEncodable("\(mnemonic) requires exactly \(mnemonicCount) consecutive registers")
            }
        }
        if arrangement.name == "1d", mnemonicCount != 1 {
            throw Diagnostic.notEncodable(".1d is legal only for ld1/st1")
        }
        guard let opcode = simdLoadStoreMultipleOpcode(mnemonicCount: mnemonicCount, listCount: list.count) else {
            throw Diagnostic.notEncodable("\(mnemonic) cannot encode a \(list.count)-register structure list")
        }

        let stride = (arrangement.q == 1 ? 16 : 8) * list.count
        let address = try encodeSIMDStructureAddress(mem, stride: stride, mnemonic: mnemonic)
        let isLoad: UInt32 = mnemonic.hasPrefix("ld") ? 1 : 0

        return 0x0c00_0000
            | (arrangement.q << 30)
            | (address.postIndex << 23)
            | (isLoad << 22)
            | (address.rm << 16)
            | (opcode << 12)
            | (arrangement.size << 10)
            | (address.rn << 5)
            | UInt32(list.firstIndex)
    }

    private func encodeSIMDLoadStoreSingleStructure(
        _ mnemonic: String,
        list: SIMDStructureRegisterList,
        mem: MemoryOperand
    ) throws -> UInt32 {
        guard let lane = list.lane else {
            throw Diagnostic.badOperand("\(mnemonic) requires a lane-indexed register list")
        }
        let expectedCount = try simdStructureMnemonicCount(mnemonic)
        guard list.count == expectedCount else {
            throw Diagnostic.notEncodable("\(mnemonic) lane form requires exactly \(expectedCount) consecutive register\(expectedCount == 1 ? "" : "s")")
        }

        let laneEncoding = try simdStructureLaneEncoding(lane)
        let stride = (1 << Int(lane.size)) * list.count
        let address = try encodeSIMDStructureAddress(mem, stride: stride, mnemonic: mnemonic)
        let countMinusOne = expectedCount - 1
        let rFlag = UInt32(countMinusOne & 0x1)
        let opcode3 = UInt32((Int(laneEncoding.scale) << 1) | ((countMinusOne >> 1) & 0x1))
        let isLoad: UInt32 = mnemonic.hasPrefix("ld") ? 1 : 0

        return 0x0d00_0000
            | (laneEncoding.q << 30)
            | (address.postIndex << 23)
            | (isLoad << 22)
            | (rFlag << 21)
            | (address.rm << 16)
            | (opcode3 << 13)
            | (laneEncoding.s << 12)
            | (laneEncoding.sizebits << 10)
            | (address.rn << 5)
            | UInt32(list.firstIndex)
    }

    private func simdStructureMnemonicCount(_ mnemonic: String) throws -> Int {
        let lower = mnemonic.lowercased()
        let digits = lower.dropFirst(2).prefix { $0.isNumber }
        guard let count = Int(digits), (1...4).contains(count) else {
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return count
    }

    private func simdLoadStoreMultipleOpcode(mnemonicCount: Int, listCount: Int) -> UInt32? {
        switch (mnemonicCount, listCount) {
        case (4, 4): return 0x0
        case (1, 4): return 0x2
        case (3, 3): return 0x4
        case (1, 3): return 0x6
        case (1, 1): return 0x7
        case (2, 2): return 0x8
        case (1, 2): return 0xa
        default: return nil
        }
    }

    private func encodeSIMDStructureAddress(
        _ mem: MemoryOperand,
        stride: Int,
        mnemonic: String
    ) throws -> (rn: UInt32, rm: UInt32, postIndex: UInt32) {
        switch mem {
        case .unsignedOffset(let base, let offset):
            guard offset == 0 else {
                throw Diagnostic.notEncodable("\(mnemonic) does not support unsigned-offset addressing")
            }
            return (UInt32(base.index), 0, 0)

        case .postIndexed(let base, let offset):
            guard offset == stride else {
                throw Diagnostic.offsetOutOfRange("\(mnemonic) post-index immediate must be #\(stride)")
            }
            return (UInt32(base.index), 31, 1)

        case .postIndexedRegister(let base, let index):
            guard index.is64 else { throw Diagnostic.registerWidthMismatch("post-index register must be X") }
            guard index.index != 31 else {
                throw Diagnostic.badRegister("post-index register must be X0-X30; Rm=31 encodes the implicit immediate stride")
            }
            return (UInt32(base.index), UInt32(index.index), 1)

        case .preIndexed:
            throw Diagnostic.notEncodable("\(mnemonic) does not support pre-indexed addressing")

        case .registerOffset:
            throw Diagnostic.notEncodable("\(mnemonic) register post-index must be written as [Xn], Xm")
        }
    }

    private func simdStructureLaneEncoding(_ lane: SIMDStructureLane) throws -> (scale: UInt32, q: UInt32, s: UInt32, sizebits: UInt32) {
        let maxLanes = 16 >> Int(lane.size)
        guard lane.index >= 0, lane.index < maxLanes else {
            throw Diagnostic.immediateOutOfRange("lane index \(lane.index) for .\(lane.name) must be 0..\(maxLanes - 1)")
        }

        switch lane.size {
        case 0:
            return (
                scale: 0b00,
                q: UInt32((lane.index >> 3) & 0x1),
                s: UInt32((lane.index >> 2) & 0x1),
                sizebits: UInt32(lane.index & 0x3)
            )
        case 1:
            return (
                scale: 0b01,
                q: UInt32((lane.index >> 2) & 0x1),
                s: UInt32((lane.index >> 1) & 0x1),
                sizebits: UInt32((lane.index & 0x1) << 1)
            )
        case 2:
            return (
                scale: 0b10,
                q: UInt32((lane.index >> 1) & 0x1),
                s: UInt32(lane.index & 0x1),
                sizebits: 0
            )
        case 3:
            return (
                scale: 0b10,
                q: UInt32(lane.index & 0x1),
                s: 0,
                sizebits: 1
            )
        default:
            throw Diagnostic.badOperand("unsupported lane .\(lane.name)")
        }
    }

    private func parseSIMDStructureRegisterList(_ token: String) throws -> SIMDStructureRegisterList {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("{"), let closeBrace = t.firstIndex(of: "}") else {
            throw Diagnostic.badOperand("expected {Vt.<T>[, ...]}")
        }
        let afterBrace = t.index(after: closeBrace)
        let suffix = String(t[afterBrace...]).trimmingCharacters(in: .whitespaces)
        let laneIndex: Int?
        if suffix.isEmpty {
            laneIndex = nil
        } else {
            guard suffix.hasPrefix("["), suffix.hasSuffix("]") else {
                throw Diagnostic.badOperand("malformed structure lane suffix '\(suffix)'")
            }
            let rawIndex = try parseImmediate(String(suffix.dropFirst().dropLast()))
            guard rawIndex >= 0, rawIndex <= Int64(Int.max) else {
                throw Diagnostic.immediateOutOfRange("lane index \(rawIndex) is out of range")
            }
            laneIndex = Int(rawIndex)
        }

        let inner = String(t[t.index(after: t.startIndex)..<closeBrace]).trimmingCharacters(in: .whitespaces)
        let entries = Self.splitOperands(inner)
        guard !entries.isEmpty else {
            throw Diagnostic.notEncodable("structure register list requires 1..4 registers")
        }
        if laneIndex != nil {
            return try parseSIMDStructureLaneList(entries, laneIndex: laneIndex!)
        }
        return try parseSIMDStructureArrangementList(entries)
    }

    private func parseSIMDStructureArrangementList(_ entries: [String]) throws -> SIMDStructureRegisterList {
        if entries.count == 1, entries[0].contains("-") {
            let pair = entries[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw Diagnostic.badOperand("malformed structure register range") }
            let first = try parseSIMDVectorRegister(String(pair[0]), allowOneDouble: true)
            let last = try parseSIMDVectorRegister(String(pair[1]), allowOneDouble: true)
            try validateStructureArrangement(first.arrangement)
            guard first.arrangement == last.arrangement else {
                throw Diagnostic.registerWidthMismatch("structure range endpoints must use the same arrangement")
            }
            let count = Self.simdWrappingRegisterCount(from: first.index, through: last.index)
            guard (1...4).contains(count) else {
                throw Diagnostic.notEncodable("structure register list requires 1..4 registers")
            }
            return .init(firstIndex: first.index, count: count, arrangement: first.arrangement, lane: nil)
        }

        var registers: [SIMDVectorRegister] = []
        registers.reserveCapacity(entries.count)
        for entry in entries {
            guard !entry.contains("-") else { throw Diagnostic.badOperand("range syntax cannot be mixed with explicit list entries") }
            let reg = try parseSIMDVectorRegister(entry, allowOneDouble: true)
            try validateStructureArrangement(reg.arrangement)
            registers.append(reg)
        }
        guard (1...4).contains(registers.count) else {
            throw Diagnostic.notEncodable("structure register list requires 1..4 registers")
        }
        let first = registers[0]
        for (offset, reg) in registers.enumerated() {
            guard reg.arrangement == first.arrangement else {
                throw Diagnostic.registerWidthMismatch("structure registers must use the same arrangement")
            }
            let expected = (first.index + offset) & 0x1f
            guard reg.index == expected else {
                throw Diagnostic.notEncodable("structure registers must be consecutive, wrapping after v31")
            }
        }
        return .init(firstIndex: first.index, count: registers.count, arrangement: first.arrangement, lane: nil)
    }

    private func parseSIMDStructureLaneList(_ entries: [String], laneIndex: Int) throws -> SIMDStructureRegisterList {
        if entries.count == 1, entries[0].contains("-") {
            let pair = entries[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw Diagnostic.badOperand("malformed structure lane register range") }
            let first = try parseSIMDStructureLaneRegister(String(pair[0]))
            let last = try parseSIMDStructureLaneRegister(String(pair[1]))
            guard first.size == last.size else {
                throw Diagnostic.registerWidthMismatch("structure lane range endpoints must use the same element")
            }
            let count = Self.simdWrappingRegisterCount(from: first.index, through: last.index)
            guard (1...4).contains(count) else {
                throw Diagnostic.notEncodable("structure register list requires 1..4 registers")
            }
            let lane = try validatedSIMDStructureLane(name: first.name, size: first.size, index: laneIndex)
            return .init(firstIndex: first.index, count: count, arrangement: nil, lane: lane)
        }

        var registers: [SIMDStructureLaneRegister] = []
        registers.reserveCapacity(entries.count)
        for entry in entries {
            guard !entry.contains("-") else { throw Diagnostic.badOperand("range syntax cannot be mixed with explicit list entries") }
            registers.append(try parseSIMDStructureLaneRegister(entry))
        }
        guard (1...4).contains(registers.count) else {
            throw Diagnostic.notEncodable("structure register list requires 1..4 registers")
        }
        let first = registers[0]
        for (offset, reg) in registers.enumerated() {
            guard reg.size == first.size else {
                throw Diagnostic.registerWidthMismatch("structure lane registers must use the same element")
            }
            let expected = (first.index + offset) & 0x1f
            guard reg.index == expected else {
                throw Diagnostic.notEncodable("structure registers must be consecutive, wrapping after v31")
            }
        }
        let lane = try validatedSIMDStructureLane(name: first.name, size: first.size, index: laneIndex)
        return .init(firstIndex: first.index, count: registers.count, arrangement: nil, lane: lane)
    }

    private func validateStructureArrangement(_ arrangement: SIMDVectorArrangement) throws {
        guard Self.simdStructureArrangementNames.contains(arrangement.name) else {
            throw Diagnostic.badOperand("unsupported structure arrangement '\(arrangement.name)'")
        }
    }

    private func validatedSIMDStructureLane(name: String, size: UInt32, index: Int) throws -> SIMDStructureLane {
        let lane = SIMDStructureLane(name: name, size: size, index: index)
        _ = try simdStructureLaneEncoding(lane)
        return lane
    }

    private func parseSIMDStructureLaneRegister(_ token: String) throws -> SIMDStructureLaneRegister {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let registerPart = parts.first, let elementPart = parts.last else {
            throw Diagnostic.badRegister(token)
        }
        guard registerPart.first == "v",
              let index = Int(registerPart.dropFirst()),
              index >= 0,
              index <= 31 else {
            throw Diagnostic.badRegister(token)
        }
        let name = String(elementPart)
        let size: UInt32
        switch name {
        case "b": size = 0
        case "h": size = 1
        case "s": size = 2
        case "d": size = 3
        default:
            throw Diagnostic.badOperand("unsupported structure lane .\(name)")
        }
        return .init(index: index, name: name, size: size)
    }

    private static func simdWrappingRegisterCount(from first: Int, through last: Int) -> Int {
        ((last - first) & 0x1f) + 1
    }

    // MARK: - Advanced SIMD permute / extract / table lookup

    private func encodeSIMDPermuteVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<T>, Vn.<T>, Vm.<T>")
        }

        let vd = try parseSIMDVectorRegister(ops[0], allowOneDouble: true)
        let vn = try parseSIMDVectorRegister(ops[1], allowOneDouble: true)
        let vm = try parseSIMDVectorRegister(ops[2], allowOneDouble: true)
        guard vd.arrangement == vn.arrangement, vd.arrangement == vm.arrangement else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
        }
        guard !(vd.arrangement.size == 3 && vd.arrangement.q == 0) else {
            throw Diagnostic.notEncodable("\(mnemonic) does not support .1d")
        }

        let opcode: UInt32
        switch mnemonic {
        case "uzp1": opcode = 0x06
        case "uzp2": opcode = 0x16
        case "trn1": opcode = 0x0a
        case "trn2": opcode = 0x1a
        case "zip1": opcode = 0x0e
        case "zip2": opcode = 0x1e
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        return 0x0e00_0800
            | (vd.arrangement.q << 30)
            | (vd.arrangement.size << 22)
            | (UInt32(vm.index) << 16)
            | (opcode << 10)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func encodeSIMDExtVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 4 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<T>, Vn.<T>, Vm.<T>, #index")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let vm = try parseSIMDVectorRegister(ops[2])
        guard vd.arrangement == vn.arrangement, vd.arrangement == vm.arrangement else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
        }
        guard Self.simdByteArrangements.contains(vd.arrangement.name) else {
            throw Diagnostic.notEncodable("\(mnemonic) supports only .8b or .16b")
        }

        let rawIndex = try parseImmediate(ops[3])
        let maxIndex: Int64 = vd.arrangement.q == 0 ? 7 : 15
        guard rawIndex >= 0, rawIndex <= maxIndex else {
            throw Diagnostic.immediateOutOfRange("\(mnemonic) .\(vd.arrangement.name) index #\(rawIndex) must be 0..\(maxIndex)")
        }
        let imm4 = UInt32(rawIndex)

        return 0x2e00_0000
            | (vd.arrangement.q << 30)
            | (UInt32(vm.index) << 16)
            | (imm4 << 11)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func encodeSIMDTableLookupVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<Ta>, {Vn.16b[, ...]}, Vm.<Ta>")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let table = try parseSIMDTableRegisterList(ops[1], mnemonic: mnemonic)
        let vm = try parseSIMDVectorRegister(ops[2])
        guard Self.simdByteArrangements.contains(vd.arrangement.name) else {
            throw Diagnostic.notEncodable("\(mnemonic) supports only .8b or .16b")
        }
        guard vm.arrangement == vd.arrangement else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) index vector must match destination arrangement")
        }

        let op: UInt32 = mnemonic == "tbx" ? 1 : 0
        let len = UInt32(table.count - 1)

        return 0x0e00_0000
            | (vd.arrangement.q << 30)
            | (UInt32(vm.index) << 16)
            | (len << 13)
            | (op << 12)
            | (UInt32(table.firstIndex) << 5)
            | UInt32(vd.index)
    }

    private func parseSIMDTableRegisterList(_ token: String, mnemonic: String) throws -> (firstIndex: Int, count: Int) {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("{"), t.hasSuffix("}") else {
            throw Diagnostic.badOperand("expected {Vn.16b[, ...]}")
        }

        let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let entries = Self.splitOperands(inner)
        guard entries.count >= 1, entries.count <= 4 else {
            throw Diagnostic.notEncodable("\(mnemonic) table requires 1..4 registers")
        }

        var registers: [SIMDVectorRegister] = []
        registers.reserveCapacity(entries.count)
        for entry in entries {
            let reg = try parseSIMDVectorRegister(entry)
            guard reg.arrangement.name == "16b" else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) table registers must be .16b")
            }
            registers.append(reg)
        }

        let first = registers[0].index
        for (offset, reg) in registers.enumerated() {
            let expected = (first + offset) & 0x1f
            guard reg.index == expected else {
                throw Diagnostic.notEncodable("\(mnemonic) table registers must be consecutive, wrapping after v31")
            }
        }

        return (firstIndex: first, count: registers.count)
    }

    private static func isSIMDCompareZeroImmediateForm(_ ops: [String]) -> Bool {
        guard ops.count == 3 else { return false }
        return ops[2].trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    private func encodeSIMDThreeSameVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<T>, Vn.<T>, Vm.<T>")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let vm = try parseSIMDVectorRegister(ops[2])
        guard vd.arrangement == vn.arrangement, vd.arrangement == vm.arrangement else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
        }

        if Self.simdFPPairwiseMnemonics.contains(mnemonic),
           Self.simdFP16PairwiseArrangements.contains(vd.arrangement.name) {
            return try encodeSIMDThreeSameFP16PairwiseVector(mnemonic, vd: vd, vn: vn, vm: vm)
        }

        let form = try simdThreeSameVectorForm(mnemonic, arrangement: vd.arrangement)
        let encodedSize = form.encodedSizeOverride ?? vd.arrangement.size

        return 0x0e20_0400
            | (vd.arrangement.q << 30)
            | (form.u << 29)
            | (encodedSize << 22)
            | (UInt32(vm.index) << 16)
            | (form.opcode << 11)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func encodeSIMDThreeSameFP16PairwiseVector(
        _ mnemonic: String,
        vd: SIMDVectorRegister,
        vn: SIMDVectorRegister,
        vm: SIMDVectorRegister
    ) throws -> UInt32 {
        let a: UInt32
        let opcode: UInt32
        switch mnemonic {
        case "fmaxnmp":
            a = 0
            opcode = 0x0
        case "fminnmp":
            a = 1
            opcode = 0x0
        case "faddp":
            a = 0
            opcode = 0x2
        case "fmaxp":
            a = 0
            opcode = 0x6
        case "fminp":
            a = 1
            opcode = 0x6
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        return 0x0e40_0400
            | (vd.arrangement.q << 30)
            | (1 << 29)
            | (a << 23)
            | (UInt32(vm.index) << 16)
            | (opcode << 11)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdThreeSameVectorForm(_ mnemonic: String, arrangement: SIMDVectorArrangement) throws -> SIMDThreeSameVectorForm {
        let form: SIMDThreeSameVectorForm
        switch mnemonic {
        case "add": form = .init(u: 0, opcode: 0b10000, legalArrangements: Self.simdAllIntegerArrangements)
        case "sub": form = .init(u: 1, opcode: 0b10000, legalArrangements: Self.simdAllIntegerArrangements)
        case "mul": form = .init(u: 0, opcode: 0b10011, legalArrangements: Self.simdNoDoubleArrangements)

        case "and": form = .init(u: 0, opcode: 0b00011, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 0)
        case "bic": form = .init(u: 0, opcode: 0b00011, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 1)
        case "orr": form = .init(u: 0, opcode: 0b00011, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 2)
        case "orn": form = .init(u: 0, opcode: 0b00011, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 3)
        case "eor": form = .init(u: 1, opcode: 0b00011, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 0)

        case "cmgt": form = .init(u: 0, opcode: 0b00110, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmhi": form = .init(u: 1, opcode: 0b00110, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmge": form = .init(u: 0, opcode: 0b00111, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmhs": form = .init(u: 1, opcode: 0b00111, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmeq": form = .init(u: 1, opcode: 0b10001, legalArrangements: Self.simdAllIntegerArrangements)

        case "smax": form = .init(u: 0, opcode: 0b01100, legalArrangements: Self.simdNoDoubleArrangements)
        case "umax": form = .init(u: 1, opcode: 0b01100, legalArrangements: Self.simdNoDoubleArrangements)
        case "smin": form = .init(u: 0, opcode: 0b01101, legalArrangements: Self.simdNoDoubleArrangements)
        case "umin": form = .init(u: 1, opcode: 0b01101, legalArrangements: Self.simdNoDoubleArrangements)
        case "smaxp": form = .init(u: 0, opcode: 0b10100, legalArrangements: Self.simdNoDoubleArrangements)
        case "umaxp": form = .init(u: 1, opcode: 0b10100, legalArrangements: Self.simdNoDoubleArrangements)
        case "sminp": form = .init(u: 0, opcode: 0b10101, legalArrangements: Self.simdNoDoubleArrangements)
        case "uminp": form = .init(u: 1, opcode: 0b10101, legalArrangements: Self.simdNoDoubleArrangements)

        case "sqadd": form = .init(u: 0, opcode: 0b00001, legalArrangements: Self.simdAllIntegerArrangements)
        case "uqadd": form = .init(u: 1, opcode: 0b00001, legalArrangements: Self.simdAllIntegerArrangements)
        case "sqsub": form = .init(u: 0, opcode: 0b00101, legalArrangements: Self.simdAllIntegerArrangements)
        case "uqsub": form = .init(u: 1, opcode: 0b00101, legalArrangements: Self.simdAllIntegerArrangements)
        case "sshl": form = .init(u: 0, opcode: 0b01000, legalArrangements: Self.simdAllIntegerArrangements)
        case "ushl": form = .init(u: 1, opcode: 0b01000, legalArrangements: Self.simdAllIntegerArrangements)
        case "mla": form = .init(u: 0, opcode: 0b10010, legalArrangements: Self.simdNoDoubleArrangements)
        case "mls": form = .init(u: 1, opcode: 0b10010, legalArrangements: Self.simdNoDoubleArrangements)
        case "addp": form = .init(u: 0, opcode: 0b10111, legalArrangements: Self.simdAllIntegerArrangements)
        case "fmaxnmp": form = Self.simdThreeSameFPPairwiseForm(arrangement: arrangement, a: 0, opcode: 0b11000)
        case "fminnmp": form = Self.simdThreeSameFPPairwiseForm(arrangement: arrangement, a: 1, opcode: 0b11000)
        case "faddp": form = Self.simdThreeSameFPPairwiseForm(arrangement: arrangement, a: 0, opcode: 0b11010)
        case "fmaxp": form = Self.simdThreeSameFPPairwiseForm(arrangement: arrangement, a: 0, opcode: 0b11110)
        case "fminp": form = Self.simdThreeSameFPPairwiseForm(arrangement: arrangement, a: 1, opcode: 0b11110)

        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        guard form.legalArrangements.contains(arrangement.name) else {
            throw Diagnostic.notEncodable("\(mnemonic) does not support .\(arrangement.name)")
        }
        return form
    }

    private static func simdThreeSameFPPairwiseForm(
        arrangement: SIMDVectorArrangement,
        a: UInt32,
        opcode: UInt32
    ) -> SIMDThreeSameVectorForm {
        let sz: UInt32 = arrangement.name == "2d" ? 1 : 0
        return .init(
            u: 1,
            opcode: opcode,
            legalArrangements: simdFPPairwiseArrangements,
            encodedSizeOverride: (a << 1) | sz
        )
    }

    // MARK: - Advanced SIMD two-register miscellaneous (integer vector)

    private struct SIMDTwoRegMiscVectorForm {
        var u: UInt32
        var opcode: UInt32
        var legalArrangements: Set<String>
        var encodedSizeOverride: UInt32? = nil
    }

    private struct SIMDFPConvertWidenNarrowVectorForm {
        var q: UInt32
        var u: UInt32
        var size: UInt32
        var opcode: UInt32
    }

    private struct SIMDLongPairwiseVectorForm {
        var u: UInt32
        var opcode: UInt32
    }

    private static let simdCompareZeroMnemonics: Set<String> = ["cmeq", "cmgt", "cmge", "cmle", "cmlt"]
    private static let simdFPTwoRegMiscArrangements: Set<String> = ["2s", "4s", "2d"]

    private func encodeSIMDLongPairwiseVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<Tb>, Vn.<Ta>")
        }

        let vd = try parseSIMDVectorRegister(ops[0], allowOneDouble: true)
        let vn = try parseSIMDVectorRegister(ops[1])
        guard let expectedDestination = Self.simdLongPairwiseDestination(for: vn.arrangement) else {
            throw Diagnostic.notEncodable("\(mnemonic) does not support .\(vn.arrangement.name)")
        }
        guard vd.arrangement == expectedDestination else {
            throw Diagnostic.registerWidthMismatch(
                "\(mnemonic) source .\(vn.arrangement.name) requires destination .\(expectedDestination.name)"
            )
        }

        let form: SIMDLongPairwiseVectorForm
        switch mnemonic {
        case "saddlp": form = .init(u: 0, opcode: 0x02)
        case "uaddlp": form = .init(u: 1, opcode: 0x02)
        case "sadalp": form = .init(u: 0, opcode: 0x06)
        case "uadalp": form = .init(u: 1, opcode: 0x06)
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        return 0x0e20_0800
            | (vn.arrangement.q << 30)
            | (form.u << 29)
            | (vn.arrangement.size << 22)
            | (form.opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private static func simdLongPairwiseDestination(for source: SIMDVectorArrangement) -> SIMDVectorArrangement? {
        switch source.name {
        case "8b": return .init(name: "4h", size: 1, q: 0)
        case "16b": return .init(name: "8h", size: 1, q: 1)
        case "4h": return .init(name: "2s", size: 2, q: 0)
        case "8h": return .init(name: "4s", size: 2, q: 1)
        case "2s": return .init(name: "1d", size: 3, q: 0)
        case "4s": return .init(name: "2d", size: 3, q: 1)
        default: return nil
        }
    }

    private func encodeSIMDTwoRegMiscVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        let compareZero = Self.simdCompareZeroMnemonics.contains(mnemonic)
        let expected = compareZero ? "Vd.<T>, Vn.<T>, #0" : "Vd.<T>, Vn.<T>"
        guard ops.count == (compareZero ? 3 : 2) else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: expected)
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        guard vd.arrangement == vn.arrangement else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
        }

        if compareZero {
            let zero = try parseImmediate(ops[2])
            guard zero == 0 else {
                throw Diagnostic.notEncodable("\(mnemonic) only accepts #0 as an immediate")
            }
        }

        let form = try simdTwoRegMiscVectorForm(mnemonic, arrangement: vd.arrangement)
        let encodedSize = form.encodedSizeOverride ?? vd.arrangement.size

        return 0x0e20_0800
            | (vd.arrangement.q << 30)
            | (form.u << 29)
            | (encodedSize << 22)
            | (form.opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func encodeSIMDFPConvertWidenNarrowVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<Tb>, Vn.<Ta>")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let form = try simdFPConvertWidenNarrowVectorForm(mnemonic, destination: vd.arrangement, source: vn.arrangement)

        return 0x0e20_0800
            | (form.q << 30)
            | (form.u << 29)
            | (form.size << 22)
            | (form.opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdTwoRegMiscVectorForm(_ mnemonic: String, arrangement: SIMDVectorArrangement) throws -> SIMDTwoRegMiscVectorForm {
        let form: SIMDTwoRegMiscVectorForm
        switch mnemonic {
        case "rev64": form = .init(u: 0, opcode: 0x00, legalArrangements: Self.simdNoDoubleArrangements)
        case "rev32": form = .init(u: 1, opcode: 0x00, legalArrangements: ["8b", "16b", "4h", "8h"])
        case "rev16": form = .init(u: 0, opcode: 0x01, legalArrangements: Self.simdByteArrangements)
        case "suqadd": form = .init(u: 0, opcode: 0x03, legalArrangements: Self.simdAllIntegerArrangements)
        case "usqadd": form = .init(u: 1, opcode: 0x03, legalArrangements: Self.simdAllIntegerArrangements)
        case "cls": form = .init(u: 0, opcode: 0x04, legalArrangements: Self.simdNoDoubleArrangements)
        case "clz": form = .init(u: 1, opcode: 0x04, legalArrangements: Self.simdNoDoubleArrangements)
        case "cnt": form = .init(u: 0, opcode: 0x05, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 0)
        case "not", "mvn": form = .init(u: 1, opcode: 0x05, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 0)
        case "rbit": form = .init(u: 1, opcode: 0x05, legalArrangements: Self.simdByteArrangements, encodedSizeOverride: 1)
        case "sqabs": form = .init(u: 0, opcode: 0x07, legalArrangements: Self.simdAllIntegerArrangements)
        case "sqneg": form = .init(u: 1, opcode: 0x07, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmgt": form = .init(u: 0, opcode: 0x08, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmge": form = .init(u: 1, opcode: 0x08, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmeq": form = .init(u: 0, opcode: 0x09, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmle": form = .init(u: 1, opcode: 0x09, legalArrangements: Self.simdAllIntegerArrangements)
        case "cmlt": form = .init(u: 0, opcode: 0x0a, legalArrangements: Self.simdAllIntegerArrangements)
        case "abs": form = .init(u: 0, opcode: 0x0b, legalArrangements: Self.simdAllIntegerArrangements)
        case "neg": form = .init(u: 1, opcode: 0x0b, legalArrangements: Self.simdAllIntegerArrangements)
        case "frintn": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x18, bit23: 0)
        case "frintp": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x18, bit23: 1)
        case "frinta": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x18, bit23: 0)
        case "frintm": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x19, bit23: 0)
        case "frintz": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x19, bit23: 1)
        case "frintx": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x19, bit23: 0)
        case "frinti": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x19, bit23: 1)
        case "fcvtns": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x1a, bit23: 0)
        case "fcvtps": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x1a, bit23: 1)
        case "fcvtnu": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x1a, bit23: 0)
        case "fcvtpu": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x1a, bit23: 1)
        case "fcvtms": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x1b, bit23: 0)
        case "fcvtzs": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x1b, bit23: 1)
        case "fcvtmu": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x1b, bit23: 0)
        case "fcvtzu": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x1b, bit23: 1)
        case "fcvtas": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x1c, bit23: 0)
        case "fcvtau": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x1c, bit23: 0)
        case "scvtf": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 0, opcode: 0x1d, bit23: 0)
        case "ucvtf": form = Self.simdTwoRegMiscFPForm(arrangement: arrangement, u: 1, opcode: 0x1d, bit23: 0)
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        guard form.legalArrangements.contains(arrangement.name) else {
            throw Diagnostic.notEncodable("\(mnemonic) does not support .\(arrangement.name)")
        }
        return form
    }

    private static func simdTwoRegMiscFPForm(
        arrangement: SIMDVectorArrangement,
        u: UInt32,
        opcode: UInt32,
        bit23: UInt32
    ) -> SIMDTwoRegMiscVectorForm {
        let sz: UInt32 = arrangement.name == "2d" ? 1 : 0
        return .init(
            u: u,
            opcode: opcode,
            legalArrangements: simdFPTwoRegMiscArrangements,
            encodedSizeOverride: (bit23 << 1) | sz
        )
    }

    private func simdFPConvertWidenNarrowVectorForm(
        _ mnemonic: String,
        destination: SIMDVectorArrangement,
        source: SIMDVectorArrangement
    ) throws -> SIMDFPConvertWidenNarrowVectorForm {
        let q: UInt32
        let u: UInt32
        let opcode: UInt32
        let pairs: [(source: String, destination: String, size: UInt32)]

        switch mnemonic {
        case "fcvtl":
            q = 0; u = 0; opcode = 0x17
            pairs = [("4h", "4s", 0), ("2s", "2d", 1)]
        case "fcvtl2":
            q = 1; u = 0; opcode = 0x17
            pairs = [("8h", "4s", 0), ("4s", "2d", 1)]
        case "fcvtn":
            q = 0; u = 0; opcode = 0x16
            pairs = [("4s", "4h", 0), ("2d", "2s", 1)]
        case "fcvtn2":
            q = 1; u = 0; opcode = 0x16
            pairs = [("4s", "8h", 0), ("2d", "4s", 1)]
        case "fcvtxn":
            q = 0; u = 1; opcode = 0x16
            pairs = [("2d", "2s", 1)]
        case "fcvtxn2":
            q = 1; u = 1; opcode = 0x16
            pairs = [("2d", "4s", 1)]
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        guard let pair = pairs.first(where: { $0.source == source.name }) else {
            throw Diagnostic.notEncodable("\(mnemonic) does not support source .\(source.name)")
        }
        guard destination.name == pair.destination else {
            throw Diagnostic.registerWidthMismatch(
                "\(mnemonic) source .\(source.name) requires destination .\(pair.destination)"
            )
        }

        return .init(q: q, u: u, size: pair.size, opcode: opcode)
    }

    // MARK: - Advanced SIMD three-different (vector)

    private enum SIMDThreeDifferentVectorKind {
        case long
        case wide
        case saturatingDoublingLong
        case polynomialMultiplyLong
    }

    private struct SIMDThreeDifferentVectorForm {
        var u: UInt32
        var opcode: UInt32
        var kind: SIMDThreeDifferentVectorKind
    }

    private func encodeSIMDThreeDifferentVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<Ta>, Vn.<Tb>, Vm.<Tb>")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let vm = try parseSIMDVectorRegister(ops[2])
        let highHalf = mnemonic.hasSuffix("2")
        let baseMnemonic = highHalf ? String(mnemonic.dropLast()) : mnemonic
        let form = try simdThreeDifferentVectorForm(baseMnemonic)
        let sourceSize = vm.arrangement.size

        guard sourceSize < 3 else {
            throw Diagnostic.notEncodable("\(mnemonic) supports only .b/.h/.s source elements")
        }
        if form.kind == .saturatingDoublingLong, sourceSize == 0 {
            throw Diagnostic.notEncodable("\(mnemonic) supports .h or .s source elements")
        }
        if form.kind == .polynomialMultiplyLong, sourceSize != 0 {
            throw Diagnostic.notEncodable("\(mnemonic) supports only .b source elements")
        }

        let expectedWide = try simdWidenedDestinationArrangementName(mnemonic: mnemonic, sourceSize: sourceSize)
        let expectedNarrow = try simdLongWideningSourceArrangementName(
            mnemonic: mnemonic,
            sourceSize: sourceSize,
            highHalf: highHalf
        )

        guard vd.arrangement.name == expectedWide else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) destination must be .\(expectedWide)")
        }

        switch form.kind {
        case .wide:
            guard vn.arrangement.name == expectedWide else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires Vn.\(expectedWide)")
            }
            guard vm.arrangement.name == expectedNarrow else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires Vm.\(expectedNarrow)")
            }

        case .long, .saturatingDoublingLong, .polynomialMultiplyLong:
            guard vn.arrangement.name == expectedNarrow else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires Vn.\(expectedNarrow)")
            }
            guard vm.arrangement.name == expectedNarrow else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires Vm.\(expectedNarrow)")
            }
        }

        return 0x0e20_0000
            | ((highHalf ? UInt32(1) : UInt32(0)) << 30)
            | (form.u << 29)
            | (sourceSize << 22)
            | (UInt32(vm.index) << 16)
            | (form.opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdThreeDifferentVectorForm(_ mnemonic: String) throws -> SIMDThreeDifferentVectorForm {
        switch mnemonic {
        case "saddl": return .init(u: 0, opcode: 0x0, kind: .long)
        case "uaddl": return .init(u: 1, opcode: 0x0, kind: .long)
        case "ssubl": return .init(u: 0, opcode: 0x2, kind: .long)
        case "usubl": return .init(u: 1, opcode: 0x2, kind: .long)

        case "saddw": return .init(u: 0, opcode: 0x1, kind: .wide)
        case "uaddw": return .init(u: 1, opcode: 0x1, kind: .wide)
        case "ssubw": return .init(u: 0, opcode: 0x3, kind: .wide)
        case "usubw": return .init(u: 1, opcode: 0x3, kind: .wide)

        case "sabal": return .init(u: 0, opcode: 0x5, kind: .long)
        case "uabal": return .init(u: 1, opcode: 0x5, kind: .long)
        case "sabdl": return .init(u: 0, opcode: 0x7, kind: .long)
        case "uabdl": return .init(u: 1, opcode: 0x7, kind: .long)

        case "smlal": return .init(u: 0, opcode: 0x8, kind: .long)
        case "umlal": return .init(u: 1, opcode: 0x8, kind: .long)
        case "smlsl": return .init(u: 0, opcode: 0xa, kind: .long)
        case "umlsl": return .init(u: 1, opcode: 0xa, kind: .long)
        case "smull": return .init(u: 0, opcode: 0xc, kind: .long)
        case "umull": return .init(u: 1, opcode: 0xc, kind: .long)

        case "sqdmlal": return .init(u: 0, opcode: 0x9, kind: .saturatingDoublingLong)
        case "sqdmlsl": return .init(u: 0, opcode: 0xb, kind: .saturatingDoublingLong)
        case "sqdmull": return .init(u: 0, opcode: 0xd, kind: .saturatingDoublingLong)

        case "pmull": return .init(u: 0, opcode: 0xe, kind: .polynomialMultiplyLong)

        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    private func simdWidenedDestinationArrangementName(mnemonic: String, sourceSize: UInt32) throws -> String {
        switch sourceSize {
        case 0: return "8h"
        case 1: return "4s"
        case 2: return "2d"
        default:
            throw Diagnostic.notEncodable("\(mnemonic) supports only .b/.h/.s source elements")
        }
    }

    private func simdLongWideningSourceArrangementName(
        mnemonic: String,
        sourceSize: UInt32,
        highHalf: Bool
    ) throws -> String {
        switch (sourceSize, highHalf) {
        case (0, false): return "8b"
        case (0, true): return "16b"
        case (1, false): return "4h"
        case (1, true): return "8h"
        case (2, false): return "2s"
        case (2, true): return "4s"
        default:
            throw Diagnostic.notEncodable("\(mnemonic) supports only .b/.h/.s source elements")
        }
    }

    // MARK: - Advanced SIMD narrowing (vector)

    private struct SIMDNarrowingShape {
        var encodedSize: UInt32
        var narrowElementBits: Int
    }

    private struct SIMDExtractNarrowVectorForm {
        var u: UInt32
        var opcode: UInt32
    }

    private struct SIMDShiftRightNarrowVectorForm {
        var u: UInt32
        var opcode: UInt32
    }

    private func encodeSIMDExtractNarrowVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<Tb>, Vn.<Ta>")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let highHalf = mnemonic.hasSuffix("2")
        let baseMnemonic = highHalf ? String(mnemonic.dropLast()) : mnemonic
        let shape = try simdNarrowingShape(mnemonic: mnemonic, destination: vd.arrangement, source: vn.arrangement, highHalf: highHalf)
        let form = try simdExtractNarrowVectorForm(baseMnemonic)

        return 0x0e20_0800
            | (vd.arrangement.q << 30)
            | (form.u << 29)
            | (shape.encodedSize << 22)
            | (form.opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdExtractNarrowVectorForm(_ mnemonic: String) throws -> SIMDExtractNarrowVectorForm {
        switch mnemonic {
        case "xtn": return .init(u: 0, opcode: 0x12)
        case "sqxtun": return .init(u: 1, opcode: 0x12)
        case "sqxtn": return .init(u: 0, opcode: 0x14)
        case "uqxtn": return .init(u: 1, opcode: 0x14)
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    private func encodeSIMDShiftRightNarrowVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<Tb>, Vn.<Ta>, #shift")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let highHalf = mnemonic.hasSuffix("2")
        let baseMnemonic = highHalf ? String(mnemonic.dropLast()) : mnemonic
        let shape = try simdNarrowingShape(mnemonic: mnemonic, destination: vd.arrangement, source: vn.arrangement, highHalf: highHalf)

        let rawShift = try parseImmediate(ops[2])
        guard rawShift >= 0, rawShift <= Int64(Int.max) else {
            throw Diagnostic.immediateOutOfRange("\(mnemonic) shift #\(rawShift) is out of range")
        }
        let shift = Int(rawShift)
        guard shift > 0, shift <= shape.narrowElementBits else {
            throw Diagnostic.immediateOutOfRange("\(mnemonic) .\(vd.arrangement.name) shift #\(shift) must be 1..\(shape.narrowElementBits)")
        }

        let encodedImmediate = (2 * shape.narrowElementBits) - shift
        let form = try simdShiftRightNarrowVectorForm(baseMnemonic)

        return 0x0f00_0400
            | (vd.arrangement.q << 30)
            | (form.u << 29)
            | (UInt32((encodedImmediate >> 3) & 0xf) << 19)
            | (UInt32(encodedImmediate & 0x7) << 16)
            | (form.opcode << 11)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdShiftRightNarrowVectorForm(_ mnemonic: String) throws -> SIMDShiftRightNarrowVectorForm {
        switch mnemonic {
        case "shrn": return .init(u: 0, opcode: 0x10)
        case "rshrn": return .init(u: 0, opcode: 0x11)
        case "sqshrun": return .init(u: 1, opcode: 0x10)
        case "sqrshrun": return .init(u: 1, opcode: 0x11)
        case "sqshrn": return .init(u: 0, opcode: 0x12)
        case "uqshrn": return .init(u: 1, opcode: 0x12)
        case "sqrshrn": return .init(u: 0, opcode: 0x13)
        case "uqrshrn": return .init(u: 1, opcode: 0x13)
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    private func simdNarrowingShape(
        mnemonic: String,
        destination: SIMDVectorArrangement,
        source: SIMDVectorArrangement,
        highHalf: Bool
    ) throws -> SIMDNarrowingShape {
        guard destination.size <= 2 else {
            throw Diagnostic.notEncodable("\(mnemonic) supports only .b/.h/.s narrow destinations")
        }

        let expectedDestinationQ: UInt32 = highHalf ? 1 : 0
        guard destination.q == expectedDestinationQ else {
            let expected = highHalf ? "128-bit destination arrangement" : "64-bit destination arrangement"
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires a \(expected)")
        }

        guard source.q == 1, source.size == destination.size + 1 else {
            let expectedSource = Self.simdNarrowingSourceArrangementName(destinationSize: destination.size)
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires Vn.\(expectedSource) with destination elements half the source width")
        }

        return .init(encodedSize: destination.size, narrowElementBits: 8 << Int(destination.size))
    }

    private static func simdNarrowingSourceArrangementName(destinationSize: UInt32) -> String {
        switch destinationSize {
        case 0: return "8h"
        case 1: return "4s"
        case 2: return "2d"
        default: return "?"
        }
    }

    // MARK: - Advanced SIMD shift-by-immediate (vector, same-width)

    private enum SIMDShiftImmediateDirection {
        case left
        case right
    }

    private struct SIMDShiftImmediateForm {
        var u: UInt32
        var opcode: UInt32
        var direction: SIMDShiftImmediateDirection
    }

    private func encodeSIMDShiftImmediateVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<T>, Vn.<T>, #shift")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        guard vd.arrangement == vn.arrangement else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
        }

        let rawShift = try parseImmediate(ops[2])
        guard rawShift >= 0, rawShift <= Int64(Int.max) else {
            throw Diagnostic.immediateOutOfRange("\(mnemonic) shift #\(rawShift) is out of range")
        }

        let form = try simdShiftImmediateForm(mnemonic)
        let encodedImmediate = try simdShiftImmediateField(
            mnemonic: mnemonic,
            arrangement: vd.arrangement,
            direction: form.direction,
            shift: Int(rawShift)
        )

        return 0x0f00_0400
            | (vd.arrangement.q << 30)
            | (form.u << 29)
            | (encodedImmediate.immh << 19)
            | (encodedImmediate.immb << 16)
            | (form.opcode << 11)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdShiftImmediateForm(_ mnemonic: String) throws -> SIMDShiftImmediateForm {
        switch mnemonic {
        case "sshr": return .init(u: 0, opcode: 0b00000, direction: .right)
        case "ushr": return .init(u: 1, opcode: 0b00000, direction: .right)
        case "ssra": return .init(u: 0, opcode: 0b00010, direction: .right)
        case "usra": return .init(u: 1, opcode: 0b00010, direction: .right)
        case "srshr": return .init(u: 0, opcode: 0b00100, direction: .right)
        case "urshr": return .init(u: 1, opcode: 0b00100, direction: .right)
        case "srsra": return .init(u: 0, opcode: 0b00110, direction: .right)
        case "ursra": return .init(u: 1, opcode: 0b00110, direction: .right)
        case "sri": return .init(u: 1, opcode: 0b01000, direction: .right)
        case "shl": return .init(u: 0, opcode: 0b01010, direction: .left)
        case "sli": return .init(u: 1, opcode: 0b01010, direction: .left)
        case "sqshlu": return .init(u: 1, opcode: 0b01100, direction: .left)
        case "sqshl": return .init(u: 0, opcode: 0b01110, direction: .left)
        case "uqshl": return .init(u: 1, opcode: 0b01110, direction: .left)
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    private func simdShiftImmediateField(
        mnemonic: String,
        arrangement: SIMDVectorArrangement,
        direction: SIMDShiftImmediateDirection,
        shift: Int
    ) throws -> (immh: UInt32, immb: UInt32) {
        let elementBits = 8 << Int(arrangement.size)
        let encoded: Int
        switch direction {
        case .left:
            guard shift >= 0, shift < elementBits else {
                throw Diagnostic.immediateOutOfRange("\(mnemonic) .\(arrangement.name) shift #\(shift) must be 0..\(elementBits - 1)")
            }
            encoded = elementBits + shift
        case .right:
            guard shift > 0, shift <= elementBits else {
                throw Diagnostic.immediateOutOfRange("\(mnemonic) .\(arrangement.name) shift #\(shift) must be 1..\(elementBits)")
            }
            encoded = (2 * elementBits) - shift
        }

        return (UInt32((encoded >> 3) & 0xf), UInt32(encoded & 0x7))
    }

    // MARK: - Advanced SIMD across-lanes reductions

    private struct SIMDAcrossLanesForm {
        var u: UInt32
        var encodedSize: UInt32
        var opcode: UInt32
        var destinationSize: UInt32
        var legalArrangements: Set<String>
    }

    private static let simdReductionIntegerArrangements: Set<String> = ["8b", "16b", "4h", "8h", "4s"]
    private static let simdReductionFPArrangements: Set<String> = ["4h", "8h", "4s"]

    private func encodeSIMDAcrossLanes(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Sd, Vn.<T>")
        }

        let rd = try parseSIMDScalarRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let form = try simdAcrossLanesForm(mnemonic, source: vn.arrangement)
        guard rd.size == form.destinationSize else {
            let expected = Self.simdScalarPrefix(size: form.destinationSize)
            let article = Self.simdScalarRegisterArticle(size: form.destinationSize)
            throw Diagnostic.registerWidthMismatch("\(mnemonic) .\(vn.arrangement.name) destination must use \(article) \(expected)-register")
        }

        return 0x0e30_0800
            | (vn.arrangement.q << 30)
            | (form.u << 29)
            | (form.encodedSize << 22)
            | (form.opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(rd.index)
    }

    private func simdAcrossLanesForm(_ mnemonic: String, source: SIMDVectorArrangement) throws -> SIMDAcrossLanesForm {
        let form: SIMDAcrossLanesForm
        switch mnemonic {
        case "addv":
            form = .init(u: 0, encodedSize: source.size, opcode: 0x1b, destinationSize: source.size, legalArrangements: Self.simdReductionIntegerArrangements)
        case "smaxv":
            form = .init(u: 0, encodedSize: source.size, opcode: 0x0a, destinationSize: source.size, legalArrangements: Self.simdReductionIntegerArrangements)
        case "sminv":
            form = .init(u: 0, encodedSize: source.size, opcode: 0x1a, destinationSize: source.size, legalArrangements: Self.simdReductionIntegerArrangements)
        case "umaxv":
            form = .init(u: 1, encodedSize: source.size, opcode: 0x0a, destinationSize: source.size, legalArrangements: Self.simdReductionIntegerArrangements)
        case "uminv":
            form = .init(u: 1, encodedSize: source.size, opcode: 0x1a, destinationSize: source.size, legalArrangements: Self.simdReductionIntegerArrangements)
        case "saddlv":
            form = .init(u: 0, encodedSize: source.size, opcode: 0x03, destinationSize: source.size + 1, legalArrangements: Self.simdReductionIntegerArrangements)
        case "uaddlv":
            form = .init(u: 1, encodedSize: source.size, opcode: 0x03, destinationSize: source.size + 1, legalArrangements: Self.simdReductionIntegerArrangements)
        case "fmaxv":
            form = try simdAcrossLanesFPForm(mnemonic, source: source, encodedSize: 0, opcode: 0x0f)
        case "fminv":
            form = try simdAcrossLanesFPForm(mnemonic, source: source, encodedSize: 2, opcode: 0x0f)
        case "fmaxnmv":
            form = try simdAcrossLanesFPForm(mnemonic, source: source, encodedSize: 0, opcode: 0x0c)
        case "fminnmv":
            form = try simdAcrossLanesFPForm(mnemonic, source: source, encodedSize: 2, opcode: 0x0c)
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }

        guard form.legalArrangements.contains(source.name) else {
            throw Diagnostic.notEncodable("\(mnemonic) does not support .\(source.name)")
        }
        return form
    }

    private func simdAcrossLanesFPForm(
        _ mnemonic: String,
        source: SIMDVectorArrangement,
        encodedSize: UInt32,
        opcode: UInt32
    ) throws -> SIMDAcrossLanesForm {
        guard source.name == "4h" || source.name == "8h" || source.name == "4s" else {
            return .init(u: 0, encodedSize: encodedSize, opcode: opcode, destinationSize: source.size, legalArrangements: Self.simdReductionFPArrangements)
        }
        let u: UInt32 = source.size == 1 ? 0 : 1
        return .init(u: u, encodedSize: encodedSize, opcode: opcode, destinationSize: source.size, legalArrangements: Self.simdReductionFPArrangements)
    }

    // MARK: - Advanced SIMD by-element (vector)

    private enum SIMDByElementVectorKind {
        case integerSame
        case widening(highHalf: Bool)
        case floatingPoint
    }

    private struct SIMDByElementVectorForm {
        var u: UInt32
        var opcode: UInt32
        var kind: SIMDByElementVectorKind
    }

    private static let simdByElementIntegerArrangements: Set<String> = ["4h", "8h", "2s", "4s"]
    private static let simdByElementFPArrangements: Set<String> = ["2s", "4s", "2d"]

    private func encodeSIMDByElementVector(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Vd.<T>, Vn.<T>, Vm.<Ts>[index]")
        }

        let vd = try parseSIMDVectorRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])
        let element = try parseSIMDIndexedElement(ops[2])
        let form = try simdByElementVectorForm(mnemonic)

        let q: UInt32
        let encodedSize: UInt32
        switch form.kind {
        case .integerSame:
            guard vd.arrangement == vn.arrangement else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
            }
            guard Self.simdByElementIntegerArrangements.contains(vd.arrangement.name) else {
                throw Diagnostic.notEncodable("\(mnemonic) does not support .\(vd.arrangement.name)")
            }
            guard element.size == vd.arrangement.size else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) lane .\(element.name) must match .\(vd.arrangement.name)")
            }
            q = vd.arrangement.q
            encodedSize = vd.arrangement.size

        case .widening(let highHalf):
            let expectedDestination: String
            let expectedSource: String
            switch vn.arrangement.size {
            case 1:
                expectedDestination = "4s"
                expectedSource = highHalf ? "8h" : "4h"
            case 2:
                expectedDestination = "2d"
                expectedSource = highHalf ? "4s" : "2s"
            default:
                throw Diagnostic.notEncodable("\(mnemonic) supports .h or .s source elements")
            }
            guard vn.arrangement.name == expectedSource else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires Vn.\(expectedSource)")
            }
            guard vd.arrangement.name == expectedDestination else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) destination must be .\(expectedDestination)")
            }
            guard element.size == vn.arrangement.size else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) lane .\(element.name) must match .\(vn.arrangement.name)")
            }
            q = vn.arrangement.q
            encodedSize = vn.arrangement.size

        case .floatingPoint:
            guard vd.arrangement == vn.arrangement else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching vector arrangements")
            }
            guard Self.simdByElementFPArrangements.contains(vd.arrangement.name) else {
                throw Diagnostic.notEncodable("\(mnemonic) does not support .\(vd.arrangement.name)")
            }
            guard element.size == vd.arrangement.size else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) lane .\(element.name) must match .\(vd.arrangement.name)")
            }
            q = vd.arrangement.q
            encodedSize = vd.arrangement.size
        }

        let lane = try simdByElementLaneFields(mnemonic: mnemonic, element: element)
        guard lane.size == encodedSize else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) lane .\(element.name) must match vector arrangement")
        }

        return 0x0f00_0000
            | (q << 30)
            | (form.u << 29)
            | (encodedSize << 22)
            | (lane.l << 21)
            | (lane.m << 20)
            | (lane.rm4 << 16)
            | (form.opcode << 12)
            | (lane.h << 11)
            | (UInt32(vn.index) << 5)
            | UInt32(vd.index)
    }

    private func simdByElementVectorForm(_ mnemonic: String) throws -> SIMDByElementVectorForm {
        switch mnemonic {
        case "mul": return .init(u: 0, opcode: 0b1000, kind: .integerSame)
        case "mla": return .init(u: 1, opcode: 0b0000, kind: .integerSame)
        case "mls": return .init(u: 1, opcode: 0b0100, kind: .integerSame)
        case "sqdmulh": return .init(u: 0, opcode: 0b1100, kind: .integerSame)
        case "sqrdmulh": return .init(u: 0, opcode: 0b1101, kind: .integerSame)

        case "smull": return .init(u: 0, opcode: 0b1010, kind: .widening(highHalf: false))
        case "smull2": return .init(u: 0, opcode: 0b1010, kind: .widening(highHalf: true))
        case "umull": return .init(u: 1, opcode: 0b1010, kind: .widening(highHalf: false))
        case "umull2": return .init(u: 1, opcode: 0b1010, kind: .widening(highHalf: true))
        case "sqdmull": return .init(u: 0, opcode: 0b1011, kind: .widening(highHalf: false))
        case "sqdmull2": return .init(u: 0, opcode: 0b1011, kind: .widening(highHalf: true))
        case "smlal": return .init(u: 0, opcode: 0b0010, kind: .widening(highHalf: false))
        case "smlal2": return .init(u: 0, opcode: 0b0010, kind: .widening(highHalf: true))
        case "umlal": return .init(u: 1, opcode: 0b0010, kind: .widening(highHalf: false))
        case "umlal2": return .init(u: 1, opcode: 0b0010, kind: .widening(highHalf: true))
        case "sqdmlal": return .init(u: 0, opcode: 0b0011, kind: .widening(highHalf: false))
        case "sqdmlal2": return .init(u: 0, opcode: 0b0011, kind: .widening(highHalf: true))
        case "smlsl": return .init(u: 0, opcode: 0b0110, kind: .widening(highHalf: false))
        case "smlsl2": return .init(u: 0, opcode: 0b0110, kind: .widening(highHalf: true))
        case "umlsl": return .init(u: 1, opcode: 0b0110, kind: .widening(highHalf: false))
        case "umlsl2": return .init(u: 1, opcode: 0b0110, kind: .widening(highHalf: true))
        case "sqdmlsl": return .init(u: 0, opcode: 0b0111, kind: .widening(highHalf: false))
        case "sqdmlsl2": return .init(u: 0, opcode: 0b0111, kind: .widening(highHalf: true))

        case "fmla": return .init(u: 0, opcode: 0b0001, kind: .floatingPoint)
        case "fmls": return .init(u: 0, opcode: 0b0101, kind: .floatingPoint)
        case "fmul": return .init(u: 0, opcode: 0b1001, kind: .floatingPoint)
        case "fmulx": return .init(u: 1, opcode: 0b1001, kind: .floatingPoint)

        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    private func simdByElementLaneFields(
        mnemonic: String,
        element: SIMDIndexedElement
    ) throws -> (size: UInt32, h: UInt32, l: UInt32, m: UInt32, rm4: UInt32) {
        switch element.size {
        case 1:
            guard element.index >= 0, element.index <= 7 else {
                throw Diagnostic.immediateOutOfRange("\(mnemonic) .h lane index \(element.index) must be 0..7")
            }
            guard element.register <= 15 else {
                throw Diagnostic.notEncodable("\(mnemonic) .h element register must be v0-v15")
            }
            return (
                1,
                UInt32((element.index >> 2) & 0x1),
                UInt32((element.index >> 1) & 0x1),
                UInt32(element.index & 0x1),
                UInt32(element.register)
            )

        case 2:
            guard element.index >= 0, element.index <= 3 else {
                throw Diagnostic.immediateOutOfRange("\(mnemonic) .s lane index \(element.index) must be 0..3")
            }
            return (
                2,
                UInt32((element.index >> 1) & 0x1),
                UInt32(element.index & 0x1),
                UInt32((element.register >> 4) & 0x1),
                UInt32(element.register & 0xf)
            )

        case 3:
            guard element.index >= 0, element.index <= 1 else {
                throw Diagnostic.immediateOutOfRange("\(mnemonic) .d lane index \(element.index) must be 0..1")
            }
            return (
                3,
                UInt32(element.index & 0x1),
                0,
                UInt32((element.register >> 4) & 0x1),
                UInt32(element.register & 0xf)
            )

        default:
            throw Diagnostic.badOperand("unsupported indexed element .\(element.name)")
        }
    }

    // MARK: - Advanced SIMD scalar pairwise

    private func encodeSIMDScalarPairwise(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else {
            throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "Sd, Vn.<T>")
        }

        let rd = try parseFPRegister(ops[0])
        let vn = try parseSIMDVectorRegister(ops[1])

        let u: UInt32
        let a: UInt32
        let bit22: UInt32
        let opcode: UInt32
        let sourceArrangement: String

        if mnemonic == "addp" {
            guard rd.precision == .d else {
                throw Diagnostic.registerWidthMismatch("addp scalar destination must be a d-register")
            }
            u = 0
            a = 1
            bit22 = 1
            opcode = 0x1b
            sourceArrangement = "2d"
        } else {
            switch rd.precision {
            case .h:
                u = 0
                bit22 = 0
                sourceArrangement = "2h"
            case .s:
                u = 1
                bit22 = 0
                sourceArrangement = "2s"
            case .d:
                u = 1
                bit22 = 1
                sourceArrangement = "2d"
            }

            switch mnemonic {
            case "fmaxnmp":
                a = 0
                opcode = 0x0c
            case "fminnmp":
                a = 1
                opcode = 0x0c
            case "faddp":
                a = 0
                opcode = 0x0d
            case "fmaxp":
                a = 0
                opcode = 0x0f
            case "fminp":
                a = 1
                opcode = 0x0f
            default:
                throw Diagnostic.unknownMnemonic(mnemonic)
            }
        }

        guard vn.arrangement.name == sourceArrangement else {
            throw Diagnostic.registerWidthMismatch(
                "\(mnemonic) \(Self.fpPrecisionName(rd.precision)) destination requires source .\(sourceArrangement)"
            )
        }

        return 0x5e30_0800
            | (u << 29)
            | (a << 23)
            | (bit22 << 22)
            | (opcode << 12)
            | (UInt32(vn.index) << 5)
            | UInt32(rd.index)
    }

    private static func fpPrecisionName(_ precision: FPPrecision) -> String {
        switch precision {
        case .h: return "h"
        case .s: return "s"
        case .d: return "d"
        }
    }

    // MARK: - Scalar floating-point

    private func encodeFmov(_ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: "fmov", expected: "2 operands") }

        if let rd = try? parseFPRegister(ops[0]) {
            if let rn = try? parseFPRegister(ops[1]) {
                guard rd.precision == rn.precision else {
                    throw Diagnostic.registerWidthMismatch("fmov requires matching FP register precision")
                }
                return encodeFPOneSource(ftype: rd.precision.ftype, opcode: 0b000000, rd: rd.index, rn: rn.index)
            }

            if ops[1].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                let imm8 = try encodeFloatingPointModifiedImmediate(ops[1])
                return 0x1e20_1000
                    | (rd.precision.ftype << 22)
                    | (UInt32(imm8) << 13)
                    | UInt32(rd.index)
            }

            let rn = try parseGeneralRegister(ops[1])
            try validateFmovGeneralRegister(rn, token: ops[1], matches: rd)
            return encodeFPIntegerConversionWord(
                sf: rn.is64,
                ftype: rd.precision.ftype,
                rmode: 0b00,
                opcode: 0b111,
                rd: rd.index,
                rn: rn.index
            )
        }

        let rd = try parseGeneralRegister(ops[0])
        let rn = try parseFPRegister(ops[1])
        try validateFmovGeneralRegister(rd, token: ops[0], matches: rn)
        return encodeFPIntegerConversionWord(
            sf: rd.is64,
            ftype: rn.precision.ftype,
            rmode: 0b00,
            opcode: 0b110,
            rd: rd.index,
            rn: rn.index
        )
    }

    private func encodeFloatingPointOneSource(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "2 operands") }
        let rd = try parseFPRegister(ops[0])
        let rn = try parseFPRegister(ops[1])
        guard rd.precision == rn.precision else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching FP register precision")
        }
        let opcode: UInt32
        switch mnemonic {
        case "fabs": opcode = 0b000001
        case "fneg": opcode = 0b000010
        case "fsqrt": opcode = 0b000011
        case "frintn": opcode = 0b001000
        case "frintp": opcode = 0b001001
        case "frintm": opcode = 0b001010
        case "frintz": opcode = 0b001011
        case "frinta": opcode = 0b001100
        case "frintx": opcode = 0b001110
        case "frinti": opcode = 0b001111
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return encodeFPOneSource(ftype: rd.precision.ftype, opcode: opcode, rd: rd.index, rn: rn.index)
    }

    private func encodeFloatingPointConvert(_ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: "fcvt", expected: "2 operands") }
        let rd = try parseFPRegister(ops[0])
        let rn = try parseFPRegister(ops[1])
        guard rd.precision != rn.precision else {
            throw Diagnostic.registerWidthMismatch("fcvt requires different FP register precisions")
        }
        let opcode = UInt32(0b000100) | rd.precision.ftype
        return encodeFPOneSource(ftype: rn.precision.ftype, opcode: opcode, rd: rd.index, rn: rn.index)
    }

    private func encodeFloatingPointTwoSource(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 3 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "3 operands") }
        let rd = try parseFPRegister(ops[0])
        let rn = try parseFPRegister(ops[1])
        let rm = try parseFPRegister(ops[2])
        guard rd.precision == rn.precision, rd.precision == rm.precision else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching FP register precision")
        }
        let opcode: UInt32
        switch mnemonic {
        case "fmul": opcode = 0b0000
        case "fdiv": opcode = 0b0001
        case "fadd": opcode = 0b0010
        case "fsub": opcode = 0b0011
        case "fmax": opcode = 0b0100
        case "fmin": opcode = 0b0101
        case "fmaxnm": opcode = 0b0110
        case "fminnm": opcode = 0b0111
        case "fnmul": opcode = 0b1000
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return 0x1e20_0800
            | (rd.precision.ftype << 22)
            | (UInt32(rm.index) << 16)
            | (opcode << 12)
            | (UInt32(rn.index) << 5)
            | UInt32(rd.index)
    }

    private func encodeFloatingPointThreeSource(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 4 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "4 operands") }
        let rd = try parseFPRegister(ops[0])
        let rn = try parseFPRegister(ops[1])
        let rm = try parseFPRegister(ops[2])
        let ra = try parseFPRegister(ops[3])
        guard rd.precision == rn.precision, rd.precision == rm.precision, rd.precision == ra.precision else {
            throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching FP register precision")
        }
        let o1: UInt32
        let o0: UInt32
        switch mnemonic {
        case "fmadd": (o1, o0) = (0, 0)
        case "fmsub": (o1, o0) = (0, 1)
        case "fnmadd": (o1, o0) = (1, 0)
        case "fnmsub": (o1, o0) = (1, 1)
        default: throw Diagnostic.unknownMnemonic(mnemonic)
        }
        return 0x1f00_0000
            | (rd.precision.ftype << 22)
            | (o1 << 21)
            | (UInt32(rm.index) << 16)
            | (o0 << 15)
            | (UInt32(ra.index) << 10)
            | (UInt32(rn.index) << 5)
            | UInt32(rd.index)
    }

    private func encodeFloatingPointCompare(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "2 operands") }
        let rn = try parseFPRegister(ops[0])
        var rm = 0
        var opcode2: UInt32 = mnemonic == "fcmpe" ? 0x10 : 0
        if let rmRegister = try? parseFPRegister(ops[1]) {
            guard rn.precision == rmRegister.precision else {
                throw Diagnostic.registerWidthMismatch("\(mnemonic) requires matching FP register precision")
            }
            rm = rmRegister.index
        } else {
            let zero = try parseFloatingPointDecimal(ops[1])
            guard zero == 0.0 else { throw Diagnostic.notEncodable("\(mnemonic) only accepts #0.0 as an immediate") }
            opcode2 |= 0x08
        }
        return 0x1e20_2000
            | (rn.precision.ftype << 22)
            | (UInt32(rm) << 16)
            | (UInt32(rn.index) << 5)
            | opcode2
    }

    private func encodeFloatingPointIntegerConversion(_ mnemonic: String, _ ops: [String]) throws -> UInt32 {
        guard ops.count == 2 else { throw Diagnostic.wrongOperandCount(mnemonic: mnemonic, expected: "2 operands") }
        switch mnemonic {
        case "scvtf", "ucvtf":
            let rd = try parseFPRegister(ops[0])
            let rn = try parseGeneralRegister(ops[1])
            return encodeFPIntegerConversionWord(
                sf: rn.is64,
                ftype: rd.precision.ftype,
                rmode: 0b00,
                opcode: mnemonic == "scvtf" ? 0b010 : 0b011,
                rd: rd.index,
                rn: rn.index
            )
        case "fcvtzs", "fcvtzu":
            let rd = try parseGeneralRegister(ops[0])
            let rn = try parseFPRegister(ops[1])
            return encodeFPIntegerConversionWord(
                sf: rd.is64,
                ftype: rn.precision.ftype,
                rmode: 0b11,
                opcode: mnemonic == "fcvtzs" ? 0b000 : 0b001,
                rd: rd.index,
                rn: rn.index
            )
        default:
            throw Diagnostic.unknownMnemonic(mnemonic)
        }
    }

    private func encodeFloatingPointConditionalSelect(_ ops: [String]) throws -> UInt32 {
        guard ops.count == 4 else { throw Diagnostic.wrongOperandCount(mnemonic: "fcsel", expected: "4 operands") }
        let rd = try parseFPRegister(ops[0])
        let rn = try parseFPRegister(ops[1])
        let rm = try parseFPRegister(ops[2])
        guard rd.precision == rn.precision, rd.precision == rm.precision else {
            throw Diagnostic.registerWidthMismatch("fcsel requires matching FP register precision")
        }
        guard let condition = Self.conditionCode(ops[3]) else { throw Diagnostic.badOperand("bad condition '\(ops[3])'") }
        return 0x1e20_0c00
            | (rd.precision.ftype << 22)
            | (UInt32(rm.index) << 16)
            | (UInt32(condition) << 12)
            | (UInt32(rn.index) << 5)
            | UInt32(rd.index)
    }

    private func encodeFPOneSource(ftype: UInt32, opcode: UInt32, rd: Int, rn: Int) -> UInt32 {
        0x1e20_4000
            | (ftype << 22)
            | (opcode << 15)
            | (UInt32(rn) << 5)
            | UInt32(rd)
    }

    private func encodeFPIntegerConversionWord(sf: Bool, ftype: UInt32, rmode: UInt32, opcode: UInt32, rd: Int, rn: Int) -> UInt32 {
        0x1e20_0000
            | (sf ? 0x8000_0000 : 0)
            | (ftype << 22)
            | (rmode << 19)
            | (opcode << 16)
            | (UInt32(rn) << 5)
            | UInt32(rd)
    }

    // MARK: - Register / immediate / shift parsing

    struct Register: Equatable {
        var index: Int      // 0..31 (31 = ZR or SP depending on form)
        var is64: Bool
    }

    private enum FPPrecision: Equatable {
        case h
        case s
        case d

        var ftype: UInt32 {
            switch self {
            case .s: return 0b00
            case .d: return 0b01
            case .h: return 0b11
            }
        }
    }

    private struct FPRegister: Equatable {
        var index: Int
        var precision: FPPrecision
    }

    private struct SIMDVectorArrangement: Equatable {
        var name: String
        var size: UInt32
        var q: UInt32
    }

    private struct SIMDVectorRegister: Equatable {
        var index: Int
        var arrangement: SIMDVectorArrangement
    }

    private struct SIMDScalarRegister: Equatable {
        var index: Int
        var size: UInt32
    }

    private struct SIMDIndexedElement: Equatable {
        var register: Int
        var name: String
        var size: UInt32
        var index: Int
    }

    private static func isSIMDVectorOperandCandidate(_ token: String?) -> Bool {
        guard let token else { return false }
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("v") && t.contains(".")
    }

    private static func isSIMDIndexedElementForm(_ ops: [String]) -> Bool {
        guard ops.count == 3 else { return false }
        let t = ops[2].trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("v") && t.contains(".") && t.contains("[") && t.hasSuffix("]")
    }

    private static func simdScalarPrefix(size: UInt32) -> String {
        switch size {
        case 0: return "b"
        case 1: return "h"
        case 2: return "s"
        case 3: return "d"
        default: return "?"
        }
    }

    private static func simdScalarRegisterArticle(size: UInt32) -> String {
        switch size {
        case 1, 2: return "an"
        default: return "a"
        }
    }

    /// True when the operand names the stack pointer (`sp`/`wsp`) — distinct from `xzr`/`wzr`,
    /// which share register index 31 but are NOT the stack pointer.
    private func isStackPointer(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        return t == "sp" || t == "wsp"
    }

    private func parseRegister(_ token: String, allowSP: Bool = false) throws -> Register {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "sp": return Register(index: 31, is64: true)
        case "wsp": return Register(index: 31, is64: false)
        case "xzr": return Register(index: 31, is64: true)
        case "wzr": return Register(index: 31, is64: false)
        default: break
        }
        guard let first = t.first, first == "x" || first == "w" else {
            throw Diagnostic.badRegister(token)
        }
        let is64 = first == "x"
        guard let index = Int(t.dropFirst()), index >= 0, index <= 30 else {
            throw Diagnostic.badRegister(token)
        }
        _ = allowSP
        return Register(index: index, is64: is64)
    }

    private func parseGeneralRegister(_ token: String) throws -> Register {
        let reg = try parseRegister(token)
        guard !isStackPointer(token) else { throw Diagnostic.badRegister(token) }
        return reg
    }

    private func parseFPRegister(_ token: String) throws -> FPRegister {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = t.first else { throw Diagnostic.badRegister(token) }
        let precision: FPPrecision
        switch first {
        case "h": precision = .h
        case "s": precision = .s
        case "d": precision = .d
        default: throw Diagnostic.badRegister(token)
        }
        guard let index = Int(t.dropFirst()), index >= 0, index <= 31 else {
            throw Diagnostic.badRegister(token)
        }
        return FPRegister(index: index, precision: precision)
    }

    private func parseSIMDVectorRegister(_ token: String, allowOneDouble: Bool = false) throws -> SIMDVectorRegister {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let registerPart = parts.first, let arrangementPart = parts.last else {
            throw Diagnostic.badRegister(token)
        }
        guard registerPart.first == "v",
              let index = Int(registerPart.dropFirst()),
              index >= 0,
              index <= 31 else {
            throw Diagnostic.badRegister(token)
        }
        let arrangementName = String(arrangementPart)
        let arrangement: SIMDVectorArrangement
        switch arrangementName {
        case "8b": arrangement = .init(name: arrangementName, size: 0, q: 0)
        case "16b": arrangement = .init(name: arrangementName, size: 0, q: 1)
        case "2h": arrangement = .init(name: arrangementName, size: 1, q: 0)
        case "4h": arrangement = .init(name: arrangementName, size: 1, q: 0)
        case "8h": arrangement = .init(name: arrangementName, size: 1, q: 1)
        case "2s": arrangement = .init(name: arrangementName, size: 2, q: 0)
        case "4s": arrangement = .init(name: arrangementName, size: 2, q: 1)
        case "2d": arrangement = .init(name: arrangementName, size: 3, q: 1)
        case "1d" where allowOneDouble: arrangement = .init(name: arrangementName, size: 3, q: 0)
        default:
            throw Diagnostic.badOperand("unsupported vector arrangement '\(arrangementName)'")
        }
        return SIMDVectorRegister(index: index, arrangement: arrangement)
    }

    private func parseSIMDIndexedElement(_ token: String) throws -> SIMDIndexedElement {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard let dot = t.firstIndex(of: "."),
              let open = t.firstIndex(of: "["),
              t.hasSuffix("]"),
              dot < open else {
            throw Diagnostic.badOperand("expected Vm.<h|s|d>[index]")
        }

        let registerPart = t[..<dot]
        guard registerPart.first == "v",
              let register = Int(registerPart.dropFirst()),
              register >= 0,
              register <= 31 else {
            throw Diagnostic.badRegister(token)
        }

        let name = String(t[t.index(after: dot)..<open])
        let size: UInt32
        switch name {
        case "h": size = 1
        case "s": size = 2
        case "d": size = 3
        default:
            throw Diagnostic.badOperand("unsupported indexed element .\(name)")
        }

        let close = t.index(before: t.endIndex)
        let rawIndex = try parseImmediate(String(t[t.index(after: open)..<close]))
        guard rawIndex >= 0, rawIndex <= Int64(Int.max) else {
            throw Diagnostic.immediateOutOfRange("lane index \(rawIndex) is out of range")
        }

        return SIMDIndexedElement(register: register, name: name, size: size, index: Int(rawIndex))
    }

    private func parseSIMDScalarRegister(_ token: String) throws -> SIMDScalarRegister {
        let t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = t.first else { throw Diagnostic.badRegister(token) }
        let size: UInt32
        switch first {
        case "b": size = 0
        case "h": size = 1
        case "s": size = 2
        case "d": size = 3
        default: throw Diagnostic.badRegister(token)
        }
        guard let index = Int(t.dropFirst()), index >= 0, index <= 31 else {
            throw Diagnostic.badRegister(token)
        }
        return SIMDScalarRegister(index: index, size: size)
    }

    private func validateFmovGeneralRegister(_ reg: Register, token: String, matches fp: FPRegister) throws {
        guard !isStackPointer(token) else { throw Diagnostic.badRegister(token) }
        switch fp.precision {
        case .d:
            guard reg.is64 else { throw Diagnostic.registerWidthMismatch("fmov d-register bit moves require an X register") }
        case .s, .h:
            guard !reg.is64 else { throw Diagnostic.registerWidthMismatch("fmov h/s-register bit moves require a W register") }
        }
    }

    /// Parses a `#`-prefixed immediate. Accepts hex (`#0x..`), decimal, and a
    /// leading sign. Bare (non-`#`) numeric tokens are also accepted for
    /// flexibility. Returns a signed Int64.
    private func parseImmediate(_ token: String) throws -> Int64 {
        var t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t = String(t.dropFirst()) }
        guard !t.isEmpty else { throw Diagnostic.badOperand("empty immediate") }
        var negative = false
        if t.hasPrefix("-") { negative = true; t = String(t.dropFirst()) }
        else if t.hasPrefix("+") { t = String(t.dropFirst()) }

        let magnitude: UInt64
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            guard let v = UInt64(t.dropFirst(2), radix: 16) else { throw Diagnostic.badOperand("bad hex immediate '\(token)'") }
            magnitude = v
        } else {
            guard let v = UInt64(t, radix: 10) else { throw Diagnostic.badOperand("bad immediate '\(token)'") }
            magnitude = v
        }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { throw Diagnostic.immediateOutOfRange("immediate '\(token)' too large") }
            return Int64(bitPattern: ~magnitude &+ 1)
        }
        return Int64(bitPattern: magnitude)
    }

    /// Parses an immediate to its raw bit pattern at the given register width,
    /// masking negatives into the unsigned field (e.g. `#-1` at 32-bit -> 0xffffffff).
    private func parseImmediateWidth(_ token: String, is64: Bool) throws -> UInt64 {
        let signed = try parseImmediate(token)
        let bits = UInt64(bitPattern: signed)
        return is64 ? bits : (bits & 0xffff_ffff)
    }

    /// Parses an absolute address operand (`0x…` or decimal), for branch targets.
    private func parseUnsignedAddress(_ token: String) throws -> UInt64 {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") {
            guard let v = UInt64(t.dropFirst(2), radix: 16) else { throw Diagnostic.badOperand("bad address '\(token)'") }
            return v
        }
        guard let v = UInt64(t, radix: 10) else { throw Diagnostic.badOperand("bad address '\(token)'") }
        return v
    }

    private func parseFloatingPointDecimal(_ token: String) throws -> Decimal {
        var t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t = String(t.dropFirst()) }
        guard !t.isEmpty, let value = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) else {
            throw Diagnostic.badOperand("bad floating-point immediate '\(token)'")
        }
        return value
    }

    private func encodeFloatingPointModifiedImmediate(_ token: String) throws -> Int {
        let value = try parseFloatingPointDecimal(token)
        for imm8 in 0...255 where expandFloatingPointModifiedImmediateDecimal(imm8) == value {
            return imm8
        }
        throw Diagnostic.notEncodable("floating-point immediate '\(token)' is not representable")
    }

    private func expandFloatingPointModifiedImmediateDecimal(_ imm8: Int) -> Decimal {
        let sign = (imm8 >> 7) & 0x1
        let bit6 = (imm8 >> 6) & 0x1
        let expLow = (imm8 >> 4) & 0x3
        let frac = imm8 & 0xf
        let exponent = bit6 == 1 ? (expLow - 3) : (expLow + 1)
        var value = Decimal(16 + frac)
        let scale = exponent - 4
        if scale >= 0 {
            value *= Decimal(1 << scale)
        } else {
            value /= Decimal(1 << -scale)
        }
        if sign == 1 { value = -value }
        return value
    }

    /// Parses a `<type> #<amount>` shift token, returning (typeCode, amount).
    /// typeCode: lsl=0, lsr=1, asr=2, ror=3.
    private func parseShiftSpec(_ token: String, allowedTypes: [String], width: Int) throws -> (Int, Int) {
        let parts = token.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard parts.count == 2 else { throw Diagnostic.badOperand("bad shift '\(token)'") }
        let type = parts[0].lowercased()
        guard allowedTypes.contains(type) else { throw Diagnostic.badOperand("shift '\(type)' not allowed here") }
        let amount = try parseImmediate(parts[1])
        guard amount >= 0, amount < Int64(width) else { throw Diagnostic.immediateOutOfRange("shift amount \(amount) must be 0..\(width - 1)") }
        let code: Int
        switch type {
        case "lsl": code = 0
        case "lsr": code = 1
        case "asr": code = 2
        case "ror": code = 3
        default: throw Diagnostic.badOperand("bad shift '\(type)'")
        }
        return (code, Int(amount))
    }

    /// Parses a single-type shift (`lsl #n`) returning just the amount.
    private func parseShiftAmount(_ token: String, allowedTypes: [String]) throws -> Int {
        let (_, amount) = try parseShiftSpec(token, allowedTypes: allowedTypes, width: 64)
        return amount
    }

    // MARK: - Inverse DecodeBitMasks

    /// The inverse of `ARM64Decoder.decodeBitMasks`: given a concrete value and
    /// register width, find (N, immr, imms) such that DecodeBitMasks reproduces
    /// it — or nil if the value is not a valid logical-immediate bitmask. This is
    /// a from-scratch search over the legal element sizes (2,4,8,16,32,64), each
    /// of which encodes a rotated run of 1..esize-1 set bits replicated across
    /// the register.
    func encodeBitMasks(_ value: UInt64, width: Int) -> (n: UInt32, immr: Int, imms: Int)? {
        let widthMask: UInt64 = width >= 64 ? ~0 : ((UInt64(1) << UInt64(width)) - 1)
        let v = value & widthMask
        // All-zeros and all-ones are not encodable as a logical immediate.
        if v == 0 || v == widthMask { return nil }

        // Try each legal element size esize = 2^length (length 1..6). length==6
        // (esize 64) is the only N==1 form; smaller sizes encode the element size
        // in the high bits of `imms`. We build the candidate (N, immr, imms) and
        // ALWAYS confirm it through the forward algorithm before returning, so a
        // mis-constructed field can never escape as wrong bytes.
        for length in 1...6 {
            let esize = 1 << length
            if esize > width { break }
            let elementMask: UInt64 = esize >= 64 ? ~0 : ((UInt64(1) << UInt64(esize)) - 1)
            let element = v & elementMask
            guard isReplicated(v, element: element, esize: esize, width: width) else { continue }
            guard let (rotation, runLength) = contiguousRun(element, esize: esize) else { continue }

            let s = runLength - 1               // welem had (s+1) low set bits
            let levels = esize - 1
            guard s != levels else { continue } // all-ones element is not encodable

            // The forward algorithm derives `length` from HighestSetBit(N:NOT(imms)).
            // For length<6 (N=0) we need NOT(imms) to have its top set bit exactly
            // at `length`: imms[length]=0, imms[5:length+1]=1. For length==6 the N
            // bit supplies the high control bit, so imms[5:0] is just `s`.
            let n: UInt32
            let immsField: Int
            if length == 6 {
                n = 1
                immsField = s & 0x3f
            } else {
                n = 0
                let highOnes = (0x3f >> (length + 1)) << (length + 1)  // bits [5:length+1]
                immsField = (highOnes | s) & 0x3f
            }
            let immr = rotation % esize

            if forwardBitMask(n: n, imms: immsField, immr: immr, width: width) == v {
                return (n, immr, immsField)
            }
        }
        return nil
    }

    /// True if `value` is `element` replicated every `esize` bits across `width`.
    private func isReplicated(_ value: UInt64, element: UInt64, esize: Int, width: Int) -> Bool {
        var shift = 0
        while shift < width {
            let chunk = esize >= 64 ? value : ((value >> UInt64(shift)) & ((UInt64(1) << UInt64(esize)) - 1))
            if chunk != element { return false }
            if esize >= 64 { break }
            shift += esize
        }
        return true
    }

    /// If `element` (within `esize` bits) is a single contiguous run of set bits
    /// (after some right-rotation), returns (rotationToAlignLow, runLength).
    /// rotation is the amount the decoder's ROR applied to the low-aligned run.
    private func contiguousRun(_ element: UInt64, esize: Int) -> (rotation: Int, runLength: Int)? {
        let mask: UInt64 = esize >= 64 ? ~0 : ((UInt64(1) << UInt64(esize)) - 1)
        let popcount = element.nonzeroBitCount
        guard popcount > 0, popcount < esize else { return nil }
        // Try every rotation; the low-aligned form must be (1<<popcount)-1.
        let welem: UInt64 = (UInt64(1) << UInt64(popcount)) - 1
        for rotation in 0..<esize {
            let rotated: UInt64
            if rotation == 0 {
                rotated = welem & mask
            } else {
                rotated = ((welem >> UInt64(rotation)) | (welem << UInt64(esize - rotation))) & mask
            }
            if rotated == element {
                return (rotation, popcount)
            }
        }
        return nil
    }

    /// Forward DecodeBitMasks (mirrors ARM64Decoder) for self-verification.
    private func forwardBitMask(n: UInt32, imms: Int, immr: Int, width: Int) -> UInt64? {
        let control = (Int(n) << 6) | ((~imms) & 0x3f)
        var length = -1
        for bit in stride(from: 6, through: 0, by: -1) where (control & (1 << bit)) != 0 {
            length = bit; break
        }
        guard length >= 1 else { return nil }
        let esize = 1 << length
        let levels = esize - 1
        let s = imms & levels
        let r = immr & levels
        guard s != levels else { return nil }
        let elementMask: UInt64 = esize >= 64 ? ~0 : ((UInt64(1) << UInt64(esize)) - 1)
        let welem: UInt64 = (UInt64(1) << UInt64(s + 1)) - 1
        let rotation = r % esize
        let rotated: UInt64
        if rotation == 0 {
            rotated = welem & elementMask
        } else {
            rotated = ((welem >> UInt64(rotation)) | (welem << UInt64(esize - rotation))) & elementMask
        }
        var result: UInt64 = 0
        var shift = 0
        while shift < width {
            result |= rotated << UInt64(shift)
            shift += esize
        }
        if width < 64 { result &= (UInt64(1) << UInt64(width)) - 1 }
        return result
    }

    // MARK: - Text utilities

    /// Splits "mnemonic operands…" into the lowercased mnemonic and the operand
    /// remainder.
    static func split(_ text: String) -> (mnemonic: String, operands: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return (trimmed.lowercased(), "")
        }
        let mnemonic = String(trimmed[trimmed.startIndex..<spaceIndex]).lowercased()
        let operands = String(trimmed[trimmed.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
        return (mnemonic, operands)
    }

    /// Splits an operand string on commas, but keeps bracketed groups (`[...]`)
    /// and register lists (`{...}`) intact. Trims each result.
    static func splitOperands(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            switch ch {
            case "[", "{": depth += 1; current.append(ch)
            case "]", "}": depth -= 1; current.append(ch)
            case "," where depth == 0:
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty || !result.isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result.filter { !$0.isEmpty }
    }

    static func conditionCode(_ name: String) -> Int? {
        switch name.lowercased() {
        case "eq": return 0x0
        case "ne": return 0x1
        case "hs", "cs": return 0x2
        case "lo", "cc": return 0x3
        case "mi": return 0x4
        case "pl": return 0x5
        case "vs": return 0x6
        case "vc": return 0x7
        case "hi": return 0x8
        case "ls": return 0x9
        case "ge": return 0xa
        case "lt": return 0xb
        case "gt": return 0xc
        case "le": return 0xd
        case "al": return 0xe
        case "nv": return 0xf
        default: return nil
        }
    }
}
