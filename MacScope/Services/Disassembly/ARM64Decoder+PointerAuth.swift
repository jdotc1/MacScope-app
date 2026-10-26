import Foundation

extension ARM64Decoder {
    // MARK: - Pointer authentication

    /// Decodes the opcode2==0b00001 pointer-authentication data-processing forms
    /// (pacia/pacib/autia/autib/xpaci/xpacd variants). All operate on X registers; the *za/*zb/xpac
    /// zero-modifier forms take a single register operand.
    func decodePointerAuthDataProcessing(
        word: UInt32,
        bytes: [UInt8],
        address: UInt64,
        opcode: UInt32,
        rn: Int,
        rd: Int
    ) -> DecodedInstruction {
        // Every PAC data-processing form is sf=1 (Apple rejects the sf=0 words, e.g. `5ac103e0`).
        guard (word & 0x8000_0000) != 0 else { return unknownInstruction(address, bytes, word) }
        if opcode & 0b110000 == 0b100000,
           let inst = decodePointerAuthLRDataProcessing(word: word, bytes: bytes, address: address, opcode: opcode, rn: rn, rd: rd) {
            return inst
        }
        let mnemonic: String?
        switch opcode {
        case 0b000000: mnemonic = "pacia"
        case 0b000001: mnemonic = "pacib"
        case 0b000010: mnemonic = "pacda"
        case 0b000011: mnemonic = "pacdb"
        case 0b000100: mnemonic = "autia"
        case 0b000101: mnemonic = "autib"
        case 0b000110: mnemonic = "autda"
        case 0b000111: mnemonic = "autdb"
        case 0b001000: mnemonic = "paciza"
        case 0b001001: mnemonic = "pacizb"
        case 0b001010: mnemonic = "pacdza"
        case 0b001011: mnemonic = "pacdzb"
        case 0b001100: mnemonic = "autiza"
        case 0b001101: mnemonic = "autizb"
        case 0b001110: mnemonic = "autdza"
        case 0b001111: mnemonic = "autdzb"
        case 0b010000: mnemonic = "xpaci"
        case 0b010001: mnemonic = "xpacd"
        default: mnemonic = nil
        }
        guard let mnemonic else { return unknownInstruction(address, bytes, word) }
        if opcode < 0b001000 {
            // The modifier is Xn|SP: Rn=31 is SP, not XZR (`dac103e0` is `pacia x0, sp`).
            return instruction(address, bytes, mnemonic, "\(register(rd, is64Bit: true)), \(register(rn, is64Bit: true, useStackPointer: true))")
        }
        // The zero-modifier (pac*z*/aut*z*) and xpac forms require Rn=11111 (`dac12c00`, pacdzb
        // with Rn=0, is unallocated; Apple rejects it).
        guard rn == 31 else { return unknownInstruction(address, bytes, word) }
        return instruction(address, bytes, mnemonic, register(rd, is64Bit: true))
    }

    func decodePointerAuthBranch(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let opc = (word >> 21) & 0xf
        let useKeyB = (word & 0x0000_0400) != 0 // bit10: 0=A key, 1=B key
        let rn = Int((word >> 5) & 0x1f)
        let rm = Int(word & 0x1f) // register-form modifier; 31 renders as SP

        switch opc {
        case 0b1000:
            return instruction(address, bytes, useKeyB ? "brab" : "braa", "\(register(rn, is64Bit: true)), \(register(rm, is64Bit: true, useStackPointer: true))")
        case 0b1001:
            return instruction(address, bytes, useKeyB ? "blrab" : "blraa", "\(register(rn, is64Bit: true)), \(register(rm, is64Bit: true, useStackPointer: true))")
        case 0b0000:
            guard rm == 31 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, useKeyB ? "brabz" : "braaz", register(rn, is64Bit: true))
        case 0b0001:
            guard rm == 31 else { return unknownInstruction(address, bytes, word) }
            return instruction(address, bytes, useKeyB ? "blrabz" : "blraaz", register(rn, is64Bit: true))
        case 0b0010:
            // FEAT_PAuth_LR RETAASPPCR/RETABSPPCR <Xm> share this encoding (Rn=31) with a modifier
            // register in Rm; Rm=31 is plain RETAA/RETAB.
            if rn == 31, rm != 31 {
                return instruction(address, bytes, useKeyB ? "retabsppcr" : "retaasppcr", register(rm, is64Bit: true))
            }
            return instruction(address, bytes, useKeyB ? "retab" : "retaa", "")
        case 0b0100:
            return instruction(address, bytes, useKeyB ? "eretab" : "eretaa", "")
        default:
            return unknownInstruction(address, bytes, word)
        }
    }

    // MARK: - FEAT_PAuth_LR

    /// FEAT_PAuth_LR data-processing forms (opcode2=0b00001, opcode=0b10xxxx, sf=1). Every form
    /// writes X30 (Rd=30). AUTIASPPCR/AUTIBSPPCR take the modifier register in Rn; the others fix
    /// Rn=31. Returns nil for any other encoding, which the caller keeps as `unknown`.
    func decodePointerAuthLRDataProcessing(
        word: UInt32,
        bytes: [UInt8],
        address: UInt64,
        opcode: UInt32,
        rn: Int,
        rd: Int
    ) -> DecodedInstruction? {
        guard (word & 0x8000_0000) != 0, rd == 30 else { return nil }
        switch opcode {
        case 0b100100: return instruction(address, bytes, "autiasppcr", register(rn, is64Bit: true))
        case 0b100101: return instruction(address, bytes, "autibsppcr", register(rn, is64Bit: true))
        default: break
        }
        guard rn == 31 else { return nil }
        let mnemonic: String
        switch opcode {
        case 0b100000: mnemonic = "pacnbiasppc"
        case 0b100001: mnemonic = "pacnbibsppc"
        case 0b100010: mnemonic = "pacia171615"
        case 0b100011: mnemonic = "pacib171615"
        case 0b101000: mnemonic = "paciasppc"
        case 0b101001: mnemonic = "pacibsppc"
        case 0b101110: mnemonic = "autia171615"
        case 0b101111: mnemonic = "autib171615"
        default: return nil
        }
        return instruction(address, bytes, mnemonic, "")
    }

    /// FEAT_PAuth_LR label forms: AUTIASPPC/AUTIBSPPC (`0xf380001f`, bit21 = key B) and
    /// RETAASPPC/RETABSPPC (`0x5500001f`). imm16 (bits[20:5]) is a backward word offset to the
    /// signing instruction: label = PC - imm16 * 4. The label is a PAC modifier, not a branch
    /// target, so `branchTarget` stays nil.
    func decodePointerAuthLRLabel(word: UInt32, bytes: [UInt8], address: UInt64) -> DecodedInstruction {
        let useKeyB = (word & 0x0020_0000) != 0
        let isReturn = (word & 0xffc0_001f) == 0x5500_001f
        let mnemonic = isReturn ? (useKeyB ? "retabsppc" : "retaasppc") : (useKeyB ? "autibsppc" : "autiasppc")
        let offset = Int((word >> 5) & 0xffff) << 2
        guard let label = addingSignedOffset(-offset, to: address) else {
            return instruction(
                address,
                bytes,
                mnemonic,
                "<address overflow>",
                comment: "PAC modifier label underflows the available address space"
            )
        }
        return instruction(address, bytes, mnemonic, label.hexAddress)
    }
}
