import Foundation

/// The `Disassembler` for CPU types MacScope does not disassemble — anything that is
/// neither arm64 (incl. arm64e) nor x86_64: 32-bit ARM/Thumb, i386, PowerPC, 68k, or a
/// corrupt/unknown cpuType (see PARITY_CONTRACT.md §4).
///
/// Rather than mis-decode foreign machine code as arm64 — which yields confidently-wrong
/// disassembly, the opposite of the project's correctness-over-coverage ethos — it emits
/// each byte as a `.byte` data directive (the same honest fallback `X86_64Decoder` uses
/// for an unmapped opcode) and attaches a diagnostic naming the architecture. The bytes
/// are surfaced as data with NO invented control flow, so function/block/CFG discovery
/// correctly finds nothing while the rest of the binary (headers, symbols, strings,
/// segments) stays fully inspectable.
struct UnsupportedArchitectureDecoder: Disassembler, Sendable {
    let cpuType: Int32

    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction] {
        let code = [UInt8](bytes)
        let count = min(code.count, maxInstructionCount)
        guard count > 0 else { return [] }

        let reason = "Unsupported architecture (cpu type 0x\(String(format: "%08x", cpuType))); "
            + "MacScope disassembles only arm64 and x86_64 — bytes shown as data"

        return (0..<count).map { offset in
            DecodedInstruction(
                address: baseAddress &+ UInt64(offset),
                bytes: [code[offset]],
                mnemonic: ".byte",
                operands: String(format: "0x%02x", code[offset]),
                branchTarget: nil,
                // Anchor the diagnostic on the first row only so the listing isn't flooded.
                comment: offset == 0 ? reason : nil,
                flow: .normal
            )
        }
    }
}
