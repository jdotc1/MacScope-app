import Foundation

/// The ARM64 implementation of `Disassembler` (its `DecodedInstruction` output type
/// lives in `Disassembler.swift`).
struct ARM64Decoder: Disassembler, Sendable {
    #if DEBUG
    /// Enabled only by bounded decoder fixtures; no global mutable validation hook.
    var validateStructuredOperands: Bool = false
    #endif
    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int = 256) -> [DecodedInstruction] {
        guard bytes.count >= 4 else {
            return [
                DecodedInstruction(
                    address: baseAddress,
                    bytes: Array(bytes),
                    mnemonic: "unavailable",
                    operands: "",
                    branchTarget: nil,
                    comment: "No complete ARM64 instruction word is available"
                )
            ]
        }

        // `baseAddress` comes straight from a parsed section header and is
        // attacker-controlled: a VA near UInt64.max would make `baseAddress +
        // offset` trap partway through the sweep. Decode only the prefix whose
        // instruction addresses are representable; the unrepresentable tail is
        // omitted rather than wrapped to bogus low addresses (the loader also
        // rejects such sections upstream, but the decoder defends itself).
        // Instruction `index` sits at `baseAddress + index*4`, representable iff
        // `index*4 <= UInt64.max - baseAddress`, so at most `headroom/4 + 1`
        // instructions fit. `headroom/4` never exceeds ~2^62, so `Int(...)` is safe.
        let headroom = UInt64.max - baseAddress
        let representableCount = Int(headroom / 4) + 1
        let instructionCount = min(bytes.count / 4, maxInstructionCount, representableCount)
        // arm64 is fixed-width: instruction `index` is a pure function of the 4 bytes at
        // `index*4`, with NO dependency on any other instruction (unlike the variable-length x86
        // sweep). So the decode is embarrassingly parallel — map it concurrently, preserving order.
        // Read the words into a plain `[UInt8]` once so the workers index a contiguous array
        // rather than concurrently slicing the `Data` (and its non-zero-based indices).
        let code = [UInt8](bytes)
        return ConcurrentMap.map(count: instructionCount) { index in
            let offset = index * 4
            let word = UInt32(code[offset])
                | UInt32(code[offset + 1]) << 8
                | UInt32(code[offset + 2]) << 16
                | UInt32(code[offset + 3]) << 24
            let wordBytes = [code[offset], code[offset + 1], code[offset + 2], code[offset + 3]]
            let address = baseAddress + UInt64(offset)
            var decoded = decode(word: word, bytes: wordBytes, address: address)
            decoded.flow = Self.flow(for: decoded.mnemonic)
            return decoded
        }
    }

    /// Maps arm64 control-flow mnemonics onto the neutral `InstructionFlow`. This
    /// reproduces exactly the classification the analysis pipeline previously did
    /// inline on these mnemonics, so arm64 output is unchanged. (blr/braa/retaa and
    /// other PAC variants stay `.normal`, matching the prior behavior.)
    static func flow(for mnemonic: String) -> InstructionFlow {
        switch mnemonic {
        case "bl": return .call
        case "b": return .jump
        case "br": return .indirectJump
        case "ret": return .return
        // Debug/halt exceptions do not establish an ordinary fall-through. A debugger or
        // exception handler may resume execution, but that requires separate runtime evidence.
        case "brk", "hlt": return .trap
        // arm64e authenticated returns end EVERY PAC-protected function epilogue — without this
        // they would read as `.normal`, so the function never terminates (broken CFG/discovery).
        // `eret*` are exception returns (kernel/driver) — also terminators, consistent with the
        // data-xref resolver's `hasPrefix("eret")` handling.
        case "retaa", "retab", "eret", "eretaa", "eretab": return .return
        // FEAT_PAuth_LR returns (label and register-modifier forms) are returns like retaa/retab.
        case "retaasppc", "retabsppc", "retaasppcr", "retabsppcr": return .return
        // Indirect CALLS: plain `blr` (previously mis-read as `.normal`) + the arm64e authenticated
        // variants. A call returns, so it is NOT a terminator — just no static `branchTarget`.
        case "blr", "blraa", "blrab", "blraaz", "blrabz": return .indirectCall
        // Indirect BRANCHES (tail calls / dispatch): the arm64e authenticated `br` variants, like
        // plain `br` above — terminators with no static target.
        case "braa", "brab", "braaz", "brabz": return .indirectJump
        default:
            if mnemonic.hasPrefix("b.") || mnemonic == "cbz" || mnemonic == "cbnz"
                || mnemonic == "tbz" || mnemonic == "tbnz" {
                return .conditionalJump
            }
            return .normal
        }
    }

    private func decode(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        // SME/SVE (RX-18) are owned by ARM64Decoder+SME.swift / +SVE.swift. The hook returns nil for
        // every word it does not fully decode, so all other dispatch below is unchanged.
        if let inst = decodeScalableMatrixExtension(word: word, bytes: bytes, address: address) { return inst }
        // MS-24 shipping-macOS families (ARM64Decoder+ShippingExtensions.swift); nil for every other word.
        if let inst = decodeShippingExtension(word: word, bytes: bytes, address: address) { return inst }

        if (word & 0xffff_fc1f) == 0xd61f_0000 {
            let register = Int((word >> 5) & 0x1f)
            return instruction(address, bytes, "br", self.register(register, is64Bit: true))
        }

        if (word & 0xffff_fc1f) == 0xd63f_0000 {
            let register = Int((word >> 5) & 0x1f)
            return instruction(address, bytes, "blr", self.register(register, is64Bit: true))
        }

        if (word & 0xffff_fc1f) == 0xd65f_0000 {
            let register = Int((word >> 5) & 0x1f)
            let operands = register == 30 ? "" : self.register(register, is64Bit: true)
            return instruction(address, bytes, "ret", operands)
        }

        // Pointer-authenticated branches/returns: braa/brab/blraa/blrab (+z
        // forms), retaa/retab, eretaa/eretab. The M/Z flag (bit11=1) distinguishes
        // these from the plain br/blr/ret hooks above (whose mask excludes bit11).
        if (word & 0xfe1f_f800) == 0xd61f_0800 {
            return decodePointerAuthBranch(word: word, bytes: bytes, address: address)
        }

        // FEAT_PAuth_LR label forms: autiasppc/autibsppc (0xf380001f; otherwise inside the extract
        // hook's mask) and retaasppc/retabsppc (0x5500001f). Bits[31:22] and Rd/Rt=11111 are fixed.
        if (word & 0xffc0_001f) == 0xf380_001f || (word & 0xffc0_001f) == 0x5500_001f {
            return decodePointerAuthLRLabel(word: word, bytes: bytes, address: address)
        }

        if (word & 0xfc00_0000) == 0x1400_0000 {
            return decodeUnconditionalBranch(word: word, bytes: bytes, address: address, mnemonic: "b")
        }

        if (word & 0xfc00_0000) == 0x9400_0000 {
            return decodeUnconditionalBranch(word: word, bytes: bytes, address: address, mnemonic: "bl")
        }

        if (word & 0xff00_0010) == 0x5400_0000 {
            return decodeConditionalBranch(word: word, bytes: bytes, address: address)
        }

        if (word & 0x7e00_0000) == 0x3400_0000 {
            return decodeCompareAndBranch(word: word, bytes: bytes, address: address)
        }

        if (word & 0x7e00_0000) == 0x3600_0000 {
            return decodeTestAndBranch(word: word, bytes: bytes, address: address)
        }

        if (word & 0x9f00_0000) == 0x1000_0000 || (word & 0x9f00_0000) == 0x9000_0000 {
            return decodePCRelativeAddress(word: word, bytes: bytes, address: address)
        }

        // Move wide (immediate): movz/movn/movk, bits[28:23]=100101.
        if (word & 0x1f80_0000) == 0x1280_0000 {
            return decodeMoveWide(word: word, bytes: bytes, address: address)
        }

        // Logical (immediate): and/orr/eor/ands with a bitmask immediate, plus
        // the tst and mov aliases. bits[28:23]=100100 (bit23=0 separates it from
        // move-wide 0x12800000).
        if (word & 0x1f80_0000) == 0x1200_0000 {
            return decodeLogicalImmediate(word: word, bytes: bytes, address: address)
        }

        if (word & 0x1fe0_0000) == 0x1a80_0000 {
            return decodeConditionalSelect(word: word, bytes: bytes, address: address)
        }

        // Conditional compare (register and immediate): ccmp/ccmn.
        if (word & 0x3fe0_0000) == 0x3a40_0000 {
            return decodeConditionalCompare(word: word, bytes: bytes, address: address)
        }

        // Add/subtract (immediate): add/sub/adds/subs and the cmp/cmn aliases.
        // bits[28:23]=100010 (bit23=0 excludes the add/sub-immediate-with-tags form).
        if (word & 0x1f80_0000) == 0x1100_0000 {
            return decodeAddSubtractImmediate(word: word, bytes: bytes, address: address)
        }

        // Add/subtract (immediate, with tags): addg/subg. bits[28:23]=100011
        // (bit23=1 separates it from plain add/sub-immediate above).
        if (word & 0x1f80_0000) == 0x1180_0000 {
            return decodeAddSubtractImmediateTags(word: word, bytes: bytes, address: address)
        }

        // Bitfield: sbfm/bfm/ubfm and their lsl/lsr/asr/sxt/uxt/bfx/bfi aliases.
        if (word & 0x1f80_0000) == 0x1300_0000 {
            return decodeBitfield(word: word, bytes: bytes, address: address)
        }

        // Store-allocation-tag pair (MTE): stgp. This is in the load/store-pair
        // space but has opc=01 and L=0; decodeLoadStorePair would otherwise render
        // it as ldpsw because it treats opc=01 unconditionally.
        if (word & 0xfe40_0000) == 0x6800_0000 {
            return decodeStoreTagPair(word: word, bytes: bytes, address: address)
        }

        // Load/store pair: stp/ldp/ldpsw across 32- and 64-bit, in offset,
        // pre-indexed, and post-indexed forms. bits[29:25]=10100, V=0 (integer).
        if (word & 0x3e00_0000) == 0x2800_0000 {
            return decodeLoadStorePair(word: word, bytes: bytes, address: address)
        }

        // LRCPC load-acquire register forms (ldapr/ldaprb/ldaprh) share the load/store-exclusive
        // space with LSE atomics. Keep this exact hook before decodeLSEAtomic, whose broad
        // bit[29:24]==0x38 check would otherwise swallow these words and return `unknown`.
        if (word & 0x3fff_fc00) == 0x38bf_c000 {
            return decodeLRCPCLoadAcquireRegister(word: word, bytes: bytes, address: address)
        }

        // FEAT_MOPS CPYF*/CPY*/SET*/SETG*: bits[31:30]=00, bits[29:27]=011, bits[25:24]=01, bit21=0,
        // bits[11:10]=01. bits[11:10]=01 keeps them disjoint from LDAPUR/STLUR below (bits[11:10]=00).
        // decodeMemoryOperation returns nil for the register combinations LLVM rejects; those fall
        // through unchanged.
        if (word & 0xfb20_0c00) == 0x1900_0400, let inst = decodeMemoryOperation(word: word, bytes: bytes, address: address) {
            return inst
        }

        // FEAT_THE RCW[S]CAS(P) and the FEAT_D128 RCW[S]{CLR,SWP,SET}P: bit31=0, bits[29:24]=011001,
        // bit21=1. bit21=1 keeps them disjoint from LDAPUR/STLUR below (bit21=0); unrecognised opc
        // values return nil and fall through unchanged.
        if (word & 0xbf20_0000) == 0x1920_0000,
           let inst = decodeReadCheckWriteCompareAndSwap(word: word, bytes: bytes, address: address) {
            return inst
        }

        // LRCPC unscaled LDAPUR/STLUR forms live outside the ordinary scalar load/store corridor
        // (bits[29:24]=011001, bit21=0, bits[11:10]=00). bit25 MUST be checked (=0): without it this
        // mask also matches the data-processing 3-source group (bits[29:24]=011011), shadowing `msub`
        // (caught by the reference-output golden differential on /bin/ls, where 5 msubs decoded as stlur).
        if (word & 0x3f20_0c00) == 0x1900_0000 {
            return decodeLRCPCUnscaled(word: word, bytes: bytes, address: address)
        }

        // FEAT_THE RCW[S]CLR/RCW[S]SWP/RCW[S]SET: the LSE atomic space (bits[29:24]=111000, bit21=1)
        // with bit31=0, o3=1 and opc=001/010/011. Must precede decodeLSEAtomic, which renders these
        // o3/opc values as `unknown`.
        if (word & 0xbf20_fc00) == 0x3820_9000 || (word & 0xbf20_fc00) == 0x3820_a000
            || (word & 0xbf20_fc00) == 0x3820_b000 {
            return decodeReadCheckWriteAtomic(word: word, bytes: bytes, address: address)
        }

        // Large System Extensions (LSE) atomic read-modify-write (ldadd/ldclr/ldeor/ldset/
        // ldsmax/ldsmin/ldumax/ldumin/swp + their a/l/al and b/h variants). They live in the
        // load/store space (bits[29:24]=0b111000, bit21=1) but are distinguished from a
        // load/store register-offset (which has bits[11:10]=0b10) by bits[11:10]==0b00 — so this
        // MORE-SPECIFIC check MUST precede the general load/store-register decode below, or every
        // atomic gets swallowed by it and decoded as `unknown`.
        if ((word >> 24) & 0x3f) == 0x38 && ((word >> 21) & 0x1) == 1 && ((word >> 10) & 0x3) == 0 {
            return decodeLSEAtomic(word: word, bytes: bytes, address: address)
        }

        // Compare-and-swap (CAS/CASP): same load/store-exclusive space (bits[29:24]=0x08) as
        // ldxr/stxr/ldar/stlr/ldxp/stxp, distinguished only by the CAS-specific bits. decodeCAS
        // returns nil for the non-CAS exclusive instructions, so they fall through and stay
        // `unknown` (not a wrong CAS decode).
        if ((word >> 24) & 0x3f) == 0x08, let inst = decodeCAS(word: word, bytes: bytes, address: address) {
            return inst
        }

        // Load/store exclusive + ordered (ARM C3.2.6): the exclusives ldxr/stxr/ldaxr/stlxr and
        // their pair forms ldxp/stxp/ldaxp/stlxp, plus the ordered non-exclusive ldar/stlr and
        // the LOR ldlar/stllr — the atomic/lock primitives. Same bits[29:24]=0x08 space as CAS
        // (handled just above, which returns nil for the non-CAS family so they reach here).
        if ((word >> 24) & 0x3f) == 0x08, let inst = decodeLoadStoreExclusive(word: word, bytes: bytes, address: address) {
            return inst
        }

        // Load/store memory tag (MTE): top byte 0xd9 with bit21=1. The decoder
        // rejects reserved block-operation sub-slots by returning nil.
        if ((word >> 24) & 0xff) == 0xd9 && ((word >> 21) & 1) == 1 {
            if let inst = decodeLoadStoreMemoryTag(word: word, bytes: bytes, address: address) { return inst }
        }

        // SUBPS (MTE) must precede the broad load/store-register guard below:
        // bit29=1 makes subps look like bits[29:26]=1110 to that guard.
        if (word & 0xffe0_fc00) == 0xbac0_0000 {
            return decodeSubtractPointer(word: word, bytes: bytes, address: address, setsFlags: true)
        }

        // Add/subtract with carry (ADC/ADCS/SBC/SBCS and the NGC/NGCS aliases):
        // bits[28:21]=11010000, bits[15:10]=000000. Matched before the load/store-register
        // guard so valid ADCS/SBCS never render as a fabricated store.
        if (word & 0x1fe0_fc00) == 0x1a00_0000 {
            return decodeAddSubtractWithCarry(word: word, bytes: bytes, address: address)
        }

        // Load/store register (integer): unsigned-immediate, unscaled
        // (ldur/stur), pre/post-indexed, and register-offset forms across every
        // access size and sign-extension. bits[29:27]=111, bit26=0 (V) and bit25=0:
        // bit25=1 with bits[29:27]=111 is the data-processing (register) space with S=1
        // (ADCS/SBCS, RMIF, SETF, CCMP/CCMN), never a load or store.
        if (word & 0x3e00_0000) == 0x3800_0000 {
            return decodeLoadStoreRegister(word: word, bytes: bytes, address: address)
        }

        // FP/SIMD load/store pair (V=1): bits[29:25]=10101.
        if (word & 0x3e00_0000) == 0x2c00_0000 {
            return decodeFPLoadStorePair(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD load/store MULTIPLE structures (ld1–4/st1–4 + post-index): bits[29:24]=001100.
        // The full 6-bit match (not just bits[29:26]) is REQUIRED: bit25=0/bit24=0 distinguishes the
        // structure forms from the SIMD copy/permute group (dup/umov/tbl/zip…, which share bits[29:26]
        // =0011 but have bit25=1) — otherwise this would shadow them. Single-structure (bit24=1) is
        // left out (handled below). Conservative: decodeSIMDLoadStoreStructure returns nil for the
        // structure-count opcodes it doesn't implement, so they stay `unknown` rather than mis-decode.
        if ((word >> 24) & 0x3f) == 0x0c, let inst = decodeSIMDLoadStoreStructure(word: word, bytes: bytes, address: address) {
            return inst
        }

        // Advanced SIMD load/store SINGLE structure + replicate (ld1–4 lane forms, ld1r–ld4r):
        // bits[29:24]=001101 (the single-structure sibling of 0x0c, distinguished by bit24=1). Disjoint
        // from 0x0c (multiple), 0x0e (copy/permute), and the FP register space, so no shadowing.
        if ((word >> 24) & 0x3f) == 0x0d, let inst = decodeSIMDLoadStoreSingleStructure(word: word, bytes: bytes, address: address) {
            return inst
        }

        // FP/SIMD load/store register (V=1): bits[29:26]=1111 AND bit25=0. The bit25=0 term is
        // essential: every load/store register form has it, while the SIMD *data-processing* space
        // (scalar three-same/copy/by-element, bits[28:24]=1111x) has bit25=1 — without it this mask
        // would shadow those and force them to `unknown`.
        if (word & 0x3e00_0000) == 0x3c00_0000 {
            return decodeFPLoadStoreRegister(word: word, bytes: bytes, address: address)
        }

        // Load register (literal): opc(2) 011 V 00 imm19 Rt — fixed bits[29:27]=011, bits[25:24]=00
        // (opc/V free). Disjoint from every other load/store form; PC-relative like adr.
        if (word & 0x3b00_0000) == 0x1800_0000 {
            if let inst = decodeLoadLiteral(word: word, bytes: bytes, address: address) { return inst }
        }

        // Scalar floating-point: data-processing 1/2-source, compare, conditional
        // compare/select, immediate, and FP<->int conversions. Top byte 0x1e
        // (sf=0) or 0x9e (sf=1 conversions); the sub-group is routed internally by
        // bit21 and bits[15:10]. bits[30:24]=0011110.
        if (word & 0x7f00_0000) == 0x1e00_0000 {
            return decodeScalarFloatingPoint(word: word, bytes: bytes, address: address)
        }

        // Scalar FP data-processing (3 source): fmadd/fmsub/fnmadd/fnmsub. Top
        // byte 0x1f (disjoint from integer dp-3-source 0x1b000000).
        if (word & 0xff00_0000) == 0x1f00_0000 {
            return decodeFPDataProcessingThreeSource(word: word, bytes: bytes, address: address)
        }

        // ARMv8 crypto AES/SHA groups. Keep these ahead of the generic SIMD groups so
        // fixed crypto encodings do not get treated as ordinary vector arithmetic.
        if (word & 0xffff_cc00) == 0x4e28_4800 {
            return decodeCryptoAES(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD scalar two-register miscellaneous. These precise masks must precede
        // crypto SHA: the broad SHA two-register guard overlaps the standard scalar mask at the
        // mask level, but real SHA words use bits[21:17]=10100 rather than 10000/111100.
        if (word & 0xdf3e_0c00) == 0x5e20_0800 {
            if let inst = decodeSIMDScalarTwoRegMisc(word: word, bytes: bytes, address: address) { return inst }
        }
        if (word & 0xdf7e_0c00) == 0x5e78_0800 {
            if let inst = decodeSIMDScalarTwoRegMiscFP16(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar pairwise: addp / faddp/fmaxp/fminp/fmaxnmp/fminnmp
        // (h/s/d from a 2-element vector). Shares the scalar two-reg-misc mask,
        // but pins bits[21:17]=11000 instead of 10000, so it is disjoint at bit20.
        if (word & 0xdf3e_0c00) == 0x5e30_0800 {
            if let inst = decodeSIMDScalarPairwise(word: word, bytes: bytes, address: address) { return inst }
        }

        if (word & 0xffe0_0c00) == 0x5e00_0000 || (word & 0xff3f_cc00) == 0x5e28_0800 {
            return decodeCryptoSHA(word: word, bytes: bytes, address: address)
        }

        // The whole `0xce` top byte is the crypto SHA512/SHA3 four/three/two-register space; match it
        // all (decodeCryptoThreeReg512 returns unknown for sub-ops it doesn't implement). The earlier
        // `bit21==1` mask missed EOR3/XAR, whose `Op0` field has bit21=0.
        if (word & 0xff00_0000) == 0xce00_0000 {
            return decodeCryptoThreeReg512(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD three-different (vector): widening/narrowing mixed-width ops.
        if (word & 0x9f20_0c00) == 0x0e20_0000 {
            return decodeSIMDThreeDifferent(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD two-register miscellaneous FP16 (vector): half-precision unary,
        // compare-with-zero, and conversion ops. Disjoint from the ordinary two-reg-misc hook:
        // this class fixes bit22=1 and bits[21:17]=111100.
        if (word & 0x9f7e_0c00) == 0x0e78_0800 {
            return decodeSIMDTwoRegMiscFP16(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD two-register miscellaneous (vector): conversions and unary vector ops.
        if (word & 0x9f3e_0c00) == 0x0e20_0800 {
            return decodeSIMDTwoRegMisc(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD across-lanes reductions (addv/minv/maxv/*addlv). This is the sibling
        // two-register-misc block with bit20 set; keep it narrow so it does not shadow three-same.
        if (word & 0x9f3e_0c00) == 0x0e30_0800 {
            return decodeSIMDAcrossLanes(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD three-same FP16 (vector): half-precision element-wise arithmetic and
        // compares. Disjoint from the ordinary three-same hook because bit21 is fixed to 0 here.
        if (word & 0x9f60_8400) == 0x0e40_0400 {
            return decodeSIMDThreeSameFP16(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD three-same (vector): integer and FP element-wise ops.
        // bit31=0, bits[28:24]=01110, bit21=1, bit10=1.
        if (word & 0x9f20_0400) == 0x0e20_0400 {
            return decodeSIMDThreeSame(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD complex three-same extra: fcmla/fcadd vector. bit31=0, bit29=1,
        // bits[28:24]=01110, bit21=0, bits[15:14]=11, bit10=1. Exclude opcode 11x1,
        // which belongs to the BF16 three-same-extra block below.
        if (word & 0xbf20_c400) == 0x2e00_c400 && (word & 0x0000_e800) != 0x0000_e800 {
            return decodeSIMDComplex(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD copy (vector): dup/umov/smov/ins. bit31=0, bits[28:24]=01110,
        // bits[23:21]=000, bit15=0, bit10=1 — disjoint from three-same (which has bit21=1).
        if (word & 0x9fe0_8400) == 0x0e00_0400 {
            return decodeSIMDCopy(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD shift-by-immediate. immh must be non-zero; immh==0 is the modified-immediate
        // block below, so this guard prevents MOVI/MVNI from being shadowed.
        if (word & 0x9f80_0400) == 0x0f00_0400 && ((word >> 19) & 0xf) != 0 {
            return decodeSIMDShiftImmediate(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD modified immediate (vector): movi/mvni.
        // bit31=0, bits[28:24]=01111, bits[23:19]=00000, bit10=1.
        if (word & 0x9ff8_0400) == 0x0f00_0400 {
            return decodeSIMDModifiedImmediate(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD complex by indexed element: fcmla. Must precede the broader by-element
        // guard below, whose mask does not constrain bit29.
        if (word & 0xbf00_9400) == 0x2f00_1000 {
            return decodeSIMDComplexByElement(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD FP16 vector x indexed element. This is a strict refinement of the broad
        // by-element hook below (bits[23:22]=00) and must precede it; the generic decoder returns
        // nil for these half-precision FP lane forms.
        if (word & 0x9fc0_0400) == 0x0f00_0000 {
            if let inst = decodeSIMDByElementFP16(word: word, bytes: bytes, address: address) { return inst }
        }

        // Advanced SIMD vector x indexed element (integer/FP lane ops, dot-product, RDMA and BF16).
        // bit31=0, bits[28:24]=01111, bit10=0 — disjoint from modified-immediate and
        // shift-by-immediate (both bit10=1) and from the scalar by-element block (bits[28:24]=11111).
        if (word & 0x9f00_0400) == 0x0f00_0000 {
            if let inst = decodeSIMDByElement(word: word, bytes: bytes, address: address) { return inst }
        }

        // Advanced SIMD three-same (dot product): sdot/udot vector. bits[28:24]=01110, bits[23:21]=100,
        // bits[15:10]=100101. Placed before three-same so its 100101 opcode is not misread.
        if (word & 0x9fe0_fc00) == 0x0e80_9400 {
            if let inst = decodeSIMDDotProduct(word: word, bytes: bytes, address: address) { return inst }
        }

        // Advanced SIMD three-same-extra (BFloat16): bfdot / bfmmla / bfmlalb / bfmlalt.
        // bit31=0, U=1, bits[28:24]=01110, bit21=0, bit15=1, opcode[14:11]=11x1, bit10=1.
        if (word & 0xbf20_ec00) == 0x2e00_ec00 {
            if let inst = decodeSIMDBF16ThreeSameExtra(word: word, bytes: bytes, address: address) { return inst }
        }

        // Advanced SIMD three-same-extra (RDMA + i8mm): sqrdmlah/sqrdmlsh, usdot, smmla/ummla/usmmla.
        // bit31=0, bits[28:24]=01110, bit21=0, bit15=1, bit14=0, bit10=1. bit14=0
        // excludes complex/BF16 columns; sdot/udot are caught by the vector dot-product guard above.
        if (word & 0x9f20_c400) == 0x0e00_8400 {
            if let inst = decodeSIMDThreeSameExtra(word: word, bytes: bytes, address: address) { return inst }
        }

        // Advanced SIMD scalar three-different: sqdmull/sqdmlal/sqdmlsl register long.
        // bits[31:30]=01, bits[28:24]=11110, bit21=1, bits[11:10]=00.
        if (word & 0xdf20_0c00) == 0x5e20_0000 {
            if let inst = decodeSIMDScalarThreeDifferent(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar three-same FP16: fabd/fmulx/frecps/frsqrts/fcm**/fac** on h.
        // bits[31:30]=01, bits[28:24]=11110, bit22=1, bit21=0, bit15=0, bit10=1.
        if (word & 0xdf60_8400) == 0x5e40_0400 {
            if let inst = decodeSIMDScalarThreeSameFP16(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar three-same: bits[31:30]=01, bits[28:24]=11110, bit21=1, bit10=1.
        if (word & 0xdf20_0400) == 0x5e20_0400 {
            if let inst = decodeSIMDScalarThreeSame(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar three-same-extra (RDMA): sqrdmlah/sqrdmlsh scalar.
        // bit30=1 is required; bit30=0 is the scalar FP fixed-point convert group.
        if (word & 0xdf20_c400) == 0x5e00_8400 {
            if let inst = decodeSIMDScalarThreeSameExtra(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar copy (mov from lane): bits[31:30]=01, bits[28:24]=11110, bits[15:11]=00000, bit10=1.
        if (word & 0xdfe0_fc00) == 0x5e00_0400 {
            if let inst = decodeSIMDScalarCopy(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar x indexed element: bits[31:30]=01, bits[28:24]=11111, bit10=0.
        if (word & 0xdf00_0400) == 0x5f00_0000 {
            if let inst = decodeSIMDScalarByElement(word: word, bytes: bytes, address: address) { return inst }
        }
        // Advanced SIMD scalar shift-by-immediate: bits[31:30]=01, bits[28:23]=111110, bit10=1, immh!=0.
        if (word & 0xdf80_0400) == 0x5f00_0400 && ((word >> 19) & 0xf) != 0 {
            if let inst = decodeSIMDScalarShiftImm(word: word, bytes: bytes, address: address) { return inst }
        }

        // Advanced SIMD three-source permutations: zip1/zip2, uzp1/uzp2, trn1/trn2.
        // These instructions interleave or deinterleave elements between two vectors.
        // They match bit31=0, bits[28:24]=01110, bits[23:21]=000, bit11=1, bit15=0.
        // The six-bit opcode in bits[15:10] selects the specific operation:
        // 0b000110 (0x06) -> uzp1, 0b010110 (0x16) -> uzp2,
        // 0b001010 (0x0a) -> trn1, 0b011010 (0x1a) -> trn2,
        // 0b001110 (0x0e) -> zip1, 0b011110 (0x1e) -> zip2.
        // size:Q encodes the arrangement; size=3 with Q=0 is reserved and skipped.
        if (word & 0xbf20_8c00) == 0x0e00_0800 {
            return decodeSIMDZipPermute(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD table lookup (vector): tbl/tbx. Decodes a table-lookup
        // into up to four consecutive 128-bit table registers. The pattern is
        // bit31=0, bits[28:24]=01110, bits[23:21]=000, bit15=0, bits[11:10]=00.
        // The op bit at bit12 selects tbl (0) vs tbx (1), Q (bit30) selects
        // the element size (.8b/.16b), and the len field bits[14:13] encode
        // the number of table registers minus one. This check must precede the
        // generic integer groups so these SIMD instructions don't fall through.
        if (word & 0xBFE0_8C00) == 0x0E00_0000 {
            return decodeSIMDTableLookup(word: word, bytes: bytes, address: address)
        }

        // Advanced SIMD extract (vector): ext. Extracts a byte-indexed slice of
        // two concatenated vectors. The pattern is bit31=0, bits[28:24]=101110,
        // bits[23:21]=000, bit15=0, bit10=0. Q (bit30) selects .8b vs .16b
        // arrangement; imm4 at bits[14:11] supplies the index. For Q=0 the
        // high bit of imm4 must be zero (only indices 0–7 are valid); other
        // encodings are reserved and rejected as unknown.
        if (word & 0xBFE0_8400) == 0x2E00_0000 {
            return decodeSIMDExt(word: word, bytes: bytes, address: address)
        }

        // Add/subtract (shifted register): bits[28:24]=01011, bit21=0 (bit21=1 is
        // the extended-register form, handled separately below).
        if (word & 0x1f20_0000) == 0x0b00_0000 {
            return decodeAddSubtractShiftedRegister(word: word, bytes: bytes, address: address)
        }

        // Add/subtract (extended register): bits[28:21]=01011001 (cmp/cmn/sp forms
        // and array-index sxtw/uxtw addressing).
        if (word & 0x1fe0_0000) == 0x0b20_0000 {
            return decodeAddSubtractExtendedRegister(word: word, bytes: bytes, address: address)
        }

        // Logical (shifted register): bits[28:24]=01010.
        if (word & 0x1f00_0000) == 0x0a00_0000 {
            return decodeLogicalShiftedRegister(word: word, bytes: bytes, address: address)
        }

        // Data-processing (1 source): bit30=1, S (bit29)=0, bits[28:21]=11010110. S=1 is
        // unallocated (it reached the load/store guard before that guard required bit25=0).
        if (word & 0x7fe0_0000) == 0x5ac0_0000 {
            return decodeDataProcessingOneSource(word: word, bytes: bytes, address: address)
        }

        // Data-processing (2 source): bit30=0, S (bit29)=0, bits[28:21]=11010110.
        if (word & 0x7fe0_0000) == 0x1ac0_0000 {
            return decodeDataProcessingTwoSource(word: word, bytes: bytes, address: address)
        }

        // Data-processing (3 source): bits[28:24]=11011.
        if (word & 0x1f00_0000) == 0x1b00_0000 {
            return decodeDataProcessingThreeSource(word: word, bytes: bytes, address: address)
        }

        // Extract register: EXTR (+ ROR-immediate alias). bits[28:23]=100111
        // (bit23=1 separates it from the bitfield hook 0x13000000).
        if (word & 0x1f80_0000) == 0x1380_0000 {
            return decodeExtract(word: word, bytes: bytes, address: address)
        }

        // Exception generation: svc/hvc/smc/brk/hlt #imm16. bits[31:24]=11010100.
        if (word & 0xff00_0000) == 0xd400_0000 {
            return decodeException(word: word, bytes: bytes, address: address)
        }

        // System: hints (nop/yield/wfe/wfi/sev/sevl and PAC hint forms), barriers (dmb/dsb/isb), msr
        // immediate, and mrs/msr register. bits[31:22]=1101010100.
        if (word & 0xffc0_0000) == 0xd500_0000 {
            return decodeSystem(word: word, bytes: bytes, address: address)
        }

        return instruction(
            address,
            bytes,
            "unknown",
            String(format: "0x%08x", word),
            comment: "ARM64 decoder unavailable for this opcode"
        )
    }

    func unknownInstruction(_ address: UInt64, _ bytes: [UInt8], _ word: UInt32) -> DecodedInstruction {
        instruction(address, bytes, "unknown", String(format: "0x%08x", word), comment: "ARM64 decoder unavailable for this opcode")
    }

    func instruction(
        _ address: UInt64,
        _ bytes: [UInt8],
        _ mnemonic: String,
        _ operands: String,
        branchTarget: UInt64? = nil,
        comment: String? = nil,
        structuredOperands: InstructionOperands? = nil
    ) -> DecodedInstruction {
        let sidecar = structuredOperands ?? .unavailable(mnemonic: mnemonic, operands: operands)
        let decoded = DecodedInstruction(
            address: address,
            bytes: bytes,
            mnemonic: mnemonic,
            operands: operands,
            branchTarget: branchTarget,
            comment: comment,
            structuredOperands: sidecar
        )
        #if DEBUG
        if validateStructuredOperands {
            let rendered = ARM64OperandRenderer.render(sidecar, legacyMnemonic: mnemonic, legacyOperands: operands)
            assert(rendered?.mnemonic == mnemonic && rendered?.operands == operands,
                   "Structured operand rendering differs from legacy text at \(address)")
        }
        #endif
        return decoded
    }

    func register(_ index: Int, is64Bit: Bool, useStackPointer: Bool = false) -> String {
        if index == 31 {
            return useStackPointer ? (is64Bit ? "sp" : "wsp") : (is64Bit ? "xzr" : "wzr")
        }
        return "\(is64Bit ? "x" : "w")\(index)"
    }

    func formatImmediate(_ value: UInt64) -> String {
        value < 10 ? "\(value)" : String(format: "0x%llx", value)
    }

    func formatSignedImmediate(_ value: Int) -> String {
        // %llx, not %x: a 32-bit format truncates magnitudes of 2^32 and above
        // (`movn x0, #1, lsl #32` printed as `mov x0, #-0x1`).
        if value < 0 {
            return String(format: "-0x%llx", UInt64(value.magnitude))
        }
        return value < 10 ? "\(value)" : String(format: "0x%llx", UInt64(value))
    }

    func conditionName(_ condition: Int) -> String {
        switch condition {
        case 0x0: "eq"
        case 0x1: "ne"
        case 0x2: "hs"
        case 0x3: "lo"
        case 0x4: "mi"
        case 0x5: "pl"
        case 0x6: "vs"
        case 0x7: "vc"
        case 0x8: "hi"
        case 0x9: "ls"
        case 0xa: "ge"
        case 0xb: "lt"
        case 0xc: "gt"
        case 0xd: "le"
        case 0xe: "al"
        default: "nv"
        }
    }

    func invertedConditionName(_ condition: Int) -> String? {
        switch condition {
        case 0x0: "ne"
        case 0x1: "eq"
        case 0x2: "lo"
        case 0x3: "hs"
        case 0x4: "pl"
        case 0x5: "mi"
        case 0x6: "vc"
        case 0x7: "vs"
        case 0x8: "ls"
        case 0x9: "hi"
        case 0xa: "lt"
        case 0xb: "ge"
        case 0xc: "le"
        case 0xd: "gt"
        default: nil
        }
    }

    func addingSignedOffset(_ offset: Int, to address: UInt64) -> UInt64? {
        if offset >= 0 {
            let (result, overflow) = address.addingReportingOverflow(UInt64(offset))
            return overflow ? nil : result
        }

        let magnitude = UInt64(-offset)
        guard address >= magnitude else { return nil }
        return address - magnitude
    }

    func signExtend(_ value: Int, bitCount: Int) -> Int {
        let signBit = 1 << (bitCount - 1)
        let mask = (1 << bitCount) - 1
        let masked = value & mask
        return (masked ^ signBit) - signBit
    }
}
