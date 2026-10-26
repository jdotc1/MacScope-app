import Foundation

extension MacIRBuilder {
    struct NEONIndexedOperands {
        let effect: MacIRNEONBufferMemory.Effect
        let vector: String; let base: String; let index: String
        let extensionKind: MacIRNEONIndexedMemory.IndexExtension; let shift: Int
    }
    static func encodedNEONIndexedMemory<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        guard let w=neonBufferSequenceWord(row) else { return false }
        // Q register-offset class, including reserved options/op2, never scalar SIMD.
        return w & 0xffa00000 == 0x3ca00000
    }
    static func neonIndexedMemory<Row: DecompilerInstructionRow>(_ row: Row) -> NEONIndexedOperands? {
        guard let w=neonBufferSequenceWord(row), w & 0xffa00c00 == 0x3ca00800,
              let ext=MacIRNEONIndexedMemory.IndexExtension(rawValue:Int((w>>13)&7)) else { return nil }
        let n=Int((w>>5)&31), m=Int((w>>16)&31), t=Int(w&31)
        guard n != 31 else { return nil }
        let load=w & 0x00400000 != 0, shift=w & 0x1000 != 0 ? 4 : 0
        let prefix=ext.width == 32 ? "w" : "x", index=m == 31 ? prefix+"zr" : prefix+String(m)
        let suffix: String
        switch ext {
        case .lsl: suffix=shift == 0 ? "" : ", lsl #4"
        case .uxtw: suffix=", uxtw"+(shift == 0 ? "" : " #4")
        case .sxtw: suffix=", sxtw"+(shift == 0 ? "" : " #4")
        case .sxtx: suffix=", sxtx"+(shift == 0 ? "" : " #4")
        }
        guard row.mnemonic == (load ? "ldr" : "str"),row.operands == "q\(t), [x\(n), \(index)\(suffix)]" else { return nil }
        return .init(effect:load ? .load : .store,vector:"q\(t)",base:"x\(n)",index:index,extensionKind:ext,shift:shift)
    }
}
