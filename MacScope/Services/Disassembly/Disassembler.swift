import Foundation

/// The architecture-neutral control-flow role of an instruction. Each decoder maps
/// its own mnemonics onto this enum so the analysis pipeline can classify calls,
/// branches, and block boundaries WITHOUT switching on arm64-specific mnemonics
/// (`bl`/`b`/`br`) — which is what lets x86_64 (`call`/`jmp`/`jcc`/`ret`) flow
/// through the same basic-block, CFG, and function-discovery passes.
enum InstructionFlow: Hashable, Sendable {
    case normal            // no control-flow effect
    case call              // direct call; `branchTarget` is the callee
    case indirectCall      // call through a register/memory operand
    case jump              // unconditional direct branch; `branchTarget` is the destination
    case indirectJump      // branch through a register/memory operand (tail call / switch)
    case conditionalJump   // conditional branch; taken target in `branchTarget`, fall-through is next
    case `return`          // function return
    case trap              // synchronous exception; no proven ordinary successor
}

/// One decoded machine instruction, architecture-NEUTRAL: `mnemonic`/`operands`
/// are rendered text, `branchTarget` is a resolved absolute address, and `flow`
/// classifies its control-flow role — so the same type carries arm64, x86_64, or
/// any future ISA's output and the analysis pipeline (basic blocks, CFG, functions,
/// xrefs) consumes only these fields, staying decoder-agnostic.
struct DecodedInstruction: Hashable, Sendable {
    var address: UInt64
    var bytes: [UInt8]
    var mnemonic: String
    var operands: String
    var branchTarget: UInt64?
    var comment: String?
    var flow: InstructionFlow = .normal
    /// Additive derived metadata. Legacy text remains the display authority.
    var structuredOperands: InstructionOperands? = nil

    var byteText: String {
        HexByteFormatter.spacedHex(bytes)
    }
}

/// A machine-code disassembler for one architecture. Extracting this seam lets
/// `AnalysisEngine` consume `any Disassembler` instead of a concrete decoder, so a
/// second architecture (x86_64, …) plugs in without touching the analysis pipeline.
/// `ARM64Decoder` is the sole implementor today.
protocol Disassembler: Sendable {
    /// Linearly decodes up to `maxInstructionCount` instructions starting at
    /// `baseAddress`. Unknown encodings are emitted as a placeholder rather than
    /// dropped, so instruction addressing stays contiguous.
    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction]
}

/// Shared decode-to-listing adapter used by AnalysisEngine and focused transport tests.
extension InstructionRow {
    init(decoded: DecodedInstruction) {
        self.init(address: decoded.address, bytes: decoded.byteText,
                  mnemonic: decoded.mnemonic, operands: decoded.operands,
                  hasBreakpoint: false, comment: decoded.comment,
                  structuredOperands: decoded.structuredOperands)
    }
}
