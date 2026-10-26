import Foundation

/// A first-increment x86_64 disassembler behind the `Disassembler` seam — the second
/// architecture, decoupled from the analysis pipeline by `DecodedInstruction`.
///
/// x86_64 is variable-length, so decode is a length-driven linear sweep: each
/// instruction's length comes from its ENCODING STRUCTURE (legacy prefixes, REX,
/// opcode, ModRM, SIB, displacement, immediate), not its semantics — so the sweep
/// stays byte-synchronized even across an opcode whose mnemonic isn't mapped yet
/// (it still advances by the correct length). Operands render in AT&T syntax to
/// match the `otool` ground truth the tests compare against.
///
/// Coverage grows incrementally (mirroring the arm64 arc). This increment targets
/// the highest-frequency real-binary families: mov/lea, push/pop, call/ret/jmp/jcc,
/// the ALU ops (add/or/adc/sbb/and/sub/xor/cmp) in their reg/imm/mem forms, the
/// group1/2/3/5 immediate/shift/unary encodings, test, movzx/movsx/movslq, setcc,
/// cmovcc, nop, leave, int3, syscall. A leading byte with no known opcode renders
/// as a single `.byte` and the sweep advances one byte (linear re-sync).
struct X86_64Decoder: Disassembler, Sendable {
	func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction] {
		let code = [UInt8](bytes)
		var instructions: [DecodedInstruction] = []
		var offset = 0
		while offset < code.count, instructions.count < maxInstructionCount {
			var decoded = decodeOne(code, at: offset, address: baseAddress &+ UInt64(offset))
			decoded.flow = Self.flow(for: decoded.mnemonic, branchTarget: decoded.branchTarget)
			instructions.append(decoded)
			offset += max(1, decoded.bytes.count)
		}
		return instructions
	}

	/// Maps x86_64 control-flow mnemonics onto the neutral `InstructionFlow`. call/jmp
	/// with a resolved `branchTarget` are direct; without one they are register/memory
	/// indirect. Every conditional (jcc/loop/jrcxz) carries a target and lands in the
	/// `default` arm, so it classifies as `.conditionalJump`.
	static func flow(for mnemonic: String, branchTarget: UInt64?) -> InstructionFlow {
		switch mnemonic {
		case "call": return branchTarget != nil ? .call : .indirectCall
		case "jmp": return branchTarget != nil ? .jump : .indirectJump
		case "ret", "lret": return .return
		default: return branchTarget != nil ? .conditionalJump : .normal
		}
	}

	// MARK: - Types

	private enum OperandSize { case byte, word, dword, qword }
	private enum Direction { case load, store }

	private struct Prefixes {
		var operandSize = false   // 0x66
		var addressSize = false   // 0x67
		var rep = false           // 0xF3
		var repne = false         // 0xF2
		var lock = false          // 0xF0
		var rexW = false
		var rexR = false
		var rexX = false
		var rexB = false
		var hasREX = false
		var segment: String?      // fs/gs/cs/ss/ds/es override, rendered on memory operands
	}

	private struct ModRM {
		var reg: Int           // reg field, REX.R-extended
		var rmText: String     // rendered r/m operand (register or memory)
		var length: Int        // bytes consumed: modrm + sib + displacement
		var ripDisp: Int64?    // set if RIP-relative (for resolved-address comment)
		var isRegisterDirect = false  // true when mod==3 (r/m is a register, not memory)
	}

	// MARK: - One instruction

	private func decodeOne(_ code: [UInt8], at start: Int, address: UInt64) -> DecodedInstruction {
		var cursor = start
		var prefixes = Prefixes()

		loop: while cursor < code.count {
			switch code[cursor] {
			case 0x66: prefixes.operandSize = true
			case 0x67: prefixes.addressSize = true
			case 0xF3: prefixes.rep = true
			case 0xF2: prefixes.repne = true
			case 0xF0: prefixes.lock = true
			case 0x2E: prefixes.segment = "cs"
			case 0x36: prefixes.segment = "ss"
			case 0x3E: prefixes.segment = "ds"
			case 0x26: prefixes.segment = "es"
			case 0x64: prefixes.segment = "fs"
			case 0x65: prefixes.segment = "gs"
			default: break loop
			}
			cursor += 1
		}
		// Consecutive REX prefixes are legal padding; only the final REX before the opcode applies.
		while cursor < code.count, code[cursor] & 0xF0 == 0x40 {
			let rex = code[cursor]
			prefixes.hasREX = true
			prefixes.rexW = rex & 0x08 != 0
			prefixes.rexR = rex & 0x04 != 0
			prefixes.rexX = rex & 0x02 != 0
			prefixes.rexB = rex & 0x01 != 0
			cursor += 1
		}

		guard cursor < code.count else {
			return raw(code, at: start, address: address, comment: "Truncated instruction")
		}
		let opcode = code[cursor]
		cursor += 1
		return decodeOpcode(opcode, code: code, start: start, opcodeEnd: cursor, prefixes: prefixes, address: address)
	}

	// MARK: - Opcode dispatch

	private func decodeOpcode(
		_ opcode: UInt8, code: [UInt8], start: Int, opcodeEnd: Int, prefixes: Prefixes, address: UInt64
	) -> DecodedInstruction {
		if opcode == 0xC4 || opcode == 0xC5 {
			return decodeVEX(opcode, code: code, start: start, opcodeEnd: opcodeEnd, address: address)
		}

		switch opcode {
		// --- EVEX prefix / AVX-512 (4-byte 0x62 prefix) ---
		case 0x62:
			return decodeEVEX(opcode, code: code, start: start, opcodeEnd: opcodeEnd,
							   prefixes: prefixes, address: address)
		// --- x87 FPU escape (D8–DF) ---
		case 0xD8...0xDF:
			return decodeX87(opcode, code: code, start: start, opcodeEnd: opcodeEnd,
							 prefixes: prefixes, address: address)

		// --- push/pop r64 (default 64-bit operand size) ---
		case 0x50...0x57:
			return emit(code, start, opcodeEnd, address, "push", Self.reg(Int(opcode & 7) | (prefixes.rexB ? 8 : 0), .qword))
		case 0x58...0x5F:
			return emit(code, start, opcodeEnd, address, "pop", Self.reg(Int(opcode & 7) | (prefixes.rexB ? 8 : 0), .qword))
		case 0x68: // push imm32
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: 4) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			return emit(code, start, opcodeEnd + n, address, "push", "$0x" + String(imm, radix: 16))
		case 0x6A: // push imm8
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			return emit(code, start, opcodeEnd + n, address, "push", "$0x" + String(imm, radix: 16))

		// --- single-byte, no operands ---
		case 0x90: return emit(code, start, opcodeEnd, address, "nop", "")
		case 0x91...0x97: return xchgAccumulator(opcode, code, start, opcodeEnd, prefixes, address)
		case 0x9E: return emit(code, start, opcodeEnd, address, "sahf", "")
		case 0x9F: return emit(code, start, opcodeEnd, address, "lahf", "")
		case 0xC3: return emit(code, start, opcodeEnd, address, "ret", "")
		case 0xCF: return emit(code, start, opcodeEnd, address, prefixes.rexW ? "iretq" : "iretl", "")
		case 0xC9: return emit(code, start, opcodeEnd, address, "leave", "")
		case 0xCC: return emit(code, start, opcodeEnd, address, "int3", "")
		case 0xD7: return emit(code, start, opcodeEnd, address, "xlatb", "")
		case 0xF4: return emit(code, start, opcodeEnd, address, "hlt", "")
		case 0x98: return emit(code, start, opcodeEnd, address, prefixes.rexW ? "cltq" : "cwtl", "")
		case 0x99: return emit(code, start, opcodeEnd, address, prefixes.rexW ? "cqto" : "cltd", "")
		case 0xF5: return emit(code, start, opcodeEnd, address, "cmc", "")
		case 0xF8: return emit(code, start, opcodeEnd, address, "clc", "")
		case 0xF9: return emit(code, start, opcodeEnd, address, "stc", "")
		case 0xFA: return emit(code, start, opcodeEnd, address, "cli", "")
		case 0xFB: return emit(code, start, opcodeEnd, address, "sti", "")
		case 0xFC: return emit(code, start, opcodeEnd, address, "cld", "")
		case 0xFD: return emit(code, start, opcodeEnd, address, "std", "")

		// --- test acc, imm ---
		case 0xA8: return aluAccImm(code, start, opcodeEnd, prefixes, address, "test", width: 1, byteForm: true)
		case 0xA9: return aluAccImm(code, start, opcodeEnd, prefixes, address, "test", width: prefixes.operandSize ? 2 : 4, byteForm: false)

		// --- imul r, r/m, imm (three-operand; imm stays 32-bit even under REX.W) ---
		case 0x69: return imulImm(code, start, opcodeEnd, prefixes, address, width: prefixes.operandSize ? 2 : 4)
		case 0x6B: return imulImm(code, start, opcodeEnd, prefixes, address, width: 1)

		// --- returns / frame setup / interrupts carrying operands (must consume them to stay synced) ---
		case 0xC2: // ret imm16
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: 2) else { return raw(code, at: start, address: address, comment: "Truncated immediate") }
			return emit(code, start, opcodeEnd + n, address, "ret", "$0x" + String(imm, radix: 16))
		case 0xCA: // retf imm16
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: 2) else { return raw(code, at: start, address: address, comment: "Truncated immediate") }
			return emit(code, start, opcodeEnd + n, address, "lret", "$0x" + String(imm, radix: 16))
		case 0xCB: return emit(code, start, opcodeEnd, address, "lret", "")
		case 0xC8: // enter imm16, imm8
			guard let (imm16, _) = Self.readImmediate(code, at: opcodeEnd, width: 2),
				  let (imm8, _) = Self.readImmediate(code, at: opcodeEnd + 2, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			return emit(code, start, opcodeEnd + 3, address, "enter", "$0x" + String(imm16, radix: 16) + ", $0x" + String(imm8, radix: 16))
		case 0xCD: // int imm8
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: 1) else { return raw(code, at: start, address: address, comment: "Truncated immediate") }
			return emit(code, start, opcodeEnd + n, address, "int", "$0x" + String(imm, radix: 16))
		case 0xCE: return emit(code, start, opcodeEnd, address, "into", "")
		case 0xF1: return emit(code, start, opcodeEnd, address, "int1", "")

		// --- loop / jrcxz (rel8) ---
		case 0xE0: return relative(code, start, opcodeEnd, address, "loopne", width: 1)
		case 0xE1: return relative(code, start, opcodeEnd, address, "loope", width: 1)
		case 0xE2: return relative(code, start, opcodeEnd, address, "loop", width: 1)
		case 0xE3: return relative(code, start, opcodeEnd, address, "jrcxz", width: 1)

		// --- flags push/pop, fwait ---
		case 0x9B: return emit(code, start, opcodeEnd, address, "fwait", "")
		case 0x9C: return emit(code, start, opcodeEnd, address, "pushf", "")
		case 0x9D: return emit(code, start, opcodeEnd, address, "popf", "")

		// --- port I/O and string I/O ---
		case 0x6C: return emit(code, start, opcodeEnd, address, "insb", "%dx, %es:(%rdi)")
		case 0x6D: return emit(code, start, opcodeEnd, address, "insl", "%dx, %es:(%rdi)")
		case 0x6E: return emit(code, start, opcodeEnd, address, "outsb", "(%rsi), %dx")
		case 0x6F: return emit(code, start, opcodeEnd, address, "outsl", "(%rsi), %dx")
		case 0xE4: return portIOImm(code, start, opcodeEnd, address, "inb", accumulator: "%al", output: false)
		case 0xE5: return portIOImm(code, start, opcodeEnd, address, "inl", accumulator: "%eax", output: false)
		case 0xE6: return portIOImm(code, start, opcodeEnd, address, "outb", accumulator: "%al", output: true)
		case 0xE7: return portIOImm(code, start, opcodeEnd, address, "outl", accumulator: "%eax", output: true)
		case 0xEC: return emit(code, start, opcodeEnd, address, "inb", "%dx, %al")
		case 0xED: return emit(code, start, opcodeEnd, address, "inl", "%dx, %eax")
		case 0xEE: return emit(code, start, opcodeEnd, address, "outb", "%al, %dx")
		case 0xEF: return emit(code, start, opcodeEnd, address, "outl", "%eax, %dx")

		// --- string operations (rep/repne-aware) ---
		case 0xA0...0xA3: return movabsMoffs(opcode, code, start, opcodeEnd, prefixes, address)
		case 0xA4: return stringOp(code, start, opcodeEnd, prefixes, address, "movs", byteForm: true)
		case 0xA5: return stringOp(code, start, opcodeEnd, prefixes, address, "movs", byteForm: false)
		case 0xA6: return stringOp(code, start, opcodeEnd, prefixes, address, "cmps", byteForm: true)
		case 0xA7: return stringOp(code, start, opcodeEnd, prefixes, address, "cmps", byteForm: false)
		case 0xAA: return stringOp(code, start, opcodeEnd, prefixes, address, "stos", byteForm: true)
		case 0xAB: return stringOp(code, start, opcodeEnd, prefixes, address, "stos", byteForm: false)
		case 0xAC: return stringOp(code, start, opcodeEnd, prefixes, address, "lods", byteForm: true)
		case 0xAD: return stringOp(code, start, opcodeEnd, prefixes, address, "lods", byteForm: false)
		case 0xAE: return stringOp(code, start, opcodeEnd, prefixes, address, "scas", byteForm: true)
		case 0xAF: return stringOp(code, start, opcodeEnd, prefixes, address, "scas", byteForm: false)

		// --- relative call / jmp / jcc ---
		case 0xE8: return relative(code, start, opcodeEnd, address, "call", width: 4)
		case 0xE9: return relative(code, start, opcodeEnd, address, "jmp", width: 4)
		case 0xEB: return relative(code, start, opcodeEnd, address, "jmp", width: 1)
		case 0x70...0x7F:
			return relative(code, start, opcodeEnd, address, Self.conditionMnemonics[Int(opcode & 0x0F)], width: 1)

		// --- mov r, imm ---
		case 0xB0...0xB7:
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let reg = Self.reg(Int(opcode & 7) | (prefixes.rexB ? 8 : 0), .byte, hasREX: prefixes.hasREX)
			return emit(code, start, opcodeEnd + n, address, "mov", "$0x" + String(imm, radix: 16) + ", " + reg)
		case 0xB8...0xBF:
			let width = prefixes.rexW ? 8 : (prefixes.operandSize ? 2 : 4)
			guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: width) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let reg = Self.reg(Int(opcode & 7) | (prefixes.rexB ? 8 : 0), Self.operandSize(prefixes))
			return emit(code, start, opcodeEnd + n, address, prefixes.rexW ? "movabs" : "mov", "$0x" + String(imm, radix: 16) + ", " + reg)

		// --- ALU r/m,r and r,r/m and acc,imm (8 ops × 6 forms) ---
		case 0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38:
			return aluModRM(code, start, opcodeEnd, prefixes, address, Self.aluNames[Int(opcode >> 3)], direction: .store, byteForm: true)
		case 0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31, 0x39:
			return aluModRM(code, start, opcodeEnd, prefixes, address, Self.aluNames[Int(opcode >> 3)], direction: .store, byteForm: false)
		case 0x02, 0x0A, 0x12, 0x1A, 0x22, 0x2A, 0x32, 0x3A:
			return aluModRM(code, start, opcodeEnd, prefixes, address, Self.aluNames[Int(opcode >> 3)], direction: .load, byteForm: true)
		case 0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B:
			return aluModRM(code, start, opcodeEnd, prefixes, address, Self.aluNames[Int(opcode >> 3)], direction: .load, byteForm: false)
		case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
			return aluAccImm(code, start, opcodeEnd, prefixes, address, Self.aluNames[Int(opcode >> 3)], width: 1, byteForm: true)
		case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
			return aluAccImm(code, start, opcodeEnd, prefixes, address, Self.aluNames[Int(opcode >> 3)], width: prefixes.operandSize ? 2 : 4, byteForm: false)

		// --- mov / lea / movslq / test (ModRM) ---
		case 0x88: return aluModRM(code, start, opcodeEnd, prefixes, address, "mov", direction: .store, byteForm: true)
		case 0x89: return aluModRM(code, start, opcodeEnd, prefixes, address, "mov", direction: .store, byteForm: false)
		case 0x8A: return aluModRM(code, start, opcodeEnd, prefixes, address, "mov", direction: .load, byteForm: true)
		case 0x8B: return aluModRM(code, start, opcodeEnd, prefixes, address, "mov", direction: .load, byteForm: false)
		case 0x8C: return segmentMov(code, start, opcodeEnd, prefixes, address, storeSegment: true)
		case 0x8E: return segmentMov(code, start, opcodeEnd, prefixes, address, storeSegment: false)
		case 0x8D: return aluModRM(code, start, opcodeEnd, prefixes, address, "lea", direction: .load, byteForm: false)
		case 0x8F: return popRM(code, start, opcodeEnd, prefixes, address)
		case 0x63: return aluModRM(code, start, opcodeEnd, prefixes, address, "movslq", direction: .load, byteForm: false, srcSize: .dword)
		case 0x84: return aluModRM(code, start, opcodeEnd, prefixes, address, "test", direction: .store, byteForm: true)
		case 0x85: return aluModRM(code, start, opcodeEnd, prefixes, address, "test", direction: .store, byteForm: false)
		// xchg r/m, r (ModRM form; the accumulator form is 0x91-0x97). AT&T renders reg, r/m.
		case 0x86: return aluModRM(code, start, opcodeEnd, prefixes, address, "xchg", direction: .store, byteForm: true)
		case 0x87: return aluModRM(code, start, opcodeEnd, prefixes, address, "xchg", direction: .store, byteForm: false)

		// --- group 1: op r/m, imm ---
		case 0x80: return groupImm(code, start, opcodeEnd, prefixes, address, names: Self.aluNames, width: 1, byteForm: true)
		case 0x81: return groupImm(code, start, opcodeEnd, prefixes, address, names: Self.aluNames, width: prefixes.operandSize ? 2 : 4, byteForm: false)
		case 0x83: return groupImm(code, start, opcodeEnd, prefixes, address, names: Self.aluNames, width: 1, byteForm: false)

		// --- group 2: shifts/rotates ---
		case 0xC0: return groupImm(code, start, opcodeEnd, prefixes, address, names: Self.shiftNames, width: 1, byteForm: true)
		case 0xC1: return groupImm(code, start, opcodeEnd, prefixes, address, names: Self.shiftNames, width: 1, byteForm: false)
		case 0xD0: return groupShift(code, start, opcodeEnd, prefixes, address, byteForm: true, by: nil)
		case 0xD1: return groupShift(code, start, opcodeEnd, prefixes, address, byteForm: false, by: nil)
		case 0xD2: return groupShift(code, start, opcodeEnd, prefixes, address, byteForm: true, by: "%cl")
		case 0xD3: return groupShift(code, start, opcodeEnd, prefixes, address, byteForm: false, by: "%cl")

		// --- mov r/m, imm ---
		case 0xC6: return groupSingleImm(code, start, opcodeEnd, prefixes, address, "mov", width: 1, byteForm: true)
		case 0xC7: return groupSingleImm(code, start, opcodeEnd, prefixes, address, "mov", width: prefixes.operandSize ? 2 : 4, byteForm: false)

		// --- group 3 (unary/test) and group 5 (inc/dec/call/jmp/push) ---
		case 0xF6: return group3(code, start, opcodeEnd, prefixes, address, byteForm: true)
		case 0xF7: return group3(code, start, opcodeEnd, prefixes, address, byteForm: false)
		case 0xFE: return group5(code, start, opcodeEnd, prefixes, address, byteForm: true)
		case 0xFF: return group5(code, start, opcodeEnd, prefixes, address, byteForm: false)

		// --- two-byte ---
		case 0x0F: return decodeTwoByte(code, start: start, opcodeEnd: opcodeEnd, prefixes: prefixes, address: address)

		default:
			return raw(code, at: start, address: address, comment: nil)
		}
	}

	private func decodeTwoByte(_ code: [UInt8], start: Int, opcodeEnd: Int, prefixes: Prefixes, address: UInt64) -> DecodedInstruction {
		guard opcodeEnd < code.count else { return raw(code, at: start, address: address, comment: nil) }
		let op2 = code[opcodeEnd]
		let after = opcodeEnd + 1
		let q = prefixes.rexW ? "q" : "l"

		// SSE / SSE2 (0x0F opcodes selected by a mandatory prefix) and the 3-byte escapes.
		if let sse = decodeSSE(op2, code: code, start: start, after: after, prefixes: prefixes, address: address) {
			return sse
		}
		if op2 == 0x38 { return decodeThreeByte(code, start: start, after: after, prefixes: prefixes, address: address, hasImm8: false) }
		if op2 == 0x3A { return decodeThreeByte(code, start: start, after: after, prefixes: prefixes, address: address, hasImm8: true) }

		switch op2 {
		// --- control/debug register moves: mov %crX/drX ↔ r64 ---
		case 0x20, 0x21, 0x22, 0x23:
			if let ctrl = decodeControlDebug(op2, code: code, start: start, after: after, prefixes: prefixes, address: address) {
				return ctrl
			}
			return raw(code, at: start, address: address, comment: nil)
		// --- rdmsr/wrmsr/rdpmc ---
		case 0x30: return emit(code, start, after, address, "wrmsr", "")
		case 0x32: return emit(code, start, after, address, "rdmsr", "")
		case 0x33: return emit(code, start, after, address, "rdpmc", "")
		// --- system instructions under 0F 01 escape ---
		case 0x01:
			if let inst = decode0F01(code, start: start, after: after, prefixes: prefixes, address: address) {
				return inst
			}
			return raw(code, at: start, address: address, comment: nil)
		// --- byte swap ---
		case 0xC8...0xCF:
			return decodeBSWAP(op2, code: code, start: start, after: after, prefixes: prefixes, address: address)

		case 0x05: return emit(code, start, after, address, "syscall", "")
		case 0x0B: return emit(code, start, after, address, "ud2", "")
		case 0x1E: // CET: F3 0F 1E FA/FB = endbr64/endbr32; otherwise a reserved nop r/m.
			if prefixes.rep, after < code.count {
				if code[after] == 0xFA { return emit(code, start, after + 1, address, "endbr64", "") }
				if code[after] == 0xFB { return emit(code, start, after + 1, address, "endbr32", "") }
			}
			return aluModRM(code, start, after, prefixes, address, "nop", direction: .load, byteForm: false, singleOperand: true)
		case 0x1F: return aluModRM(code, start, after, prefixes, address, "nop", direction: .load, byteForm: false, singleOperand: true)
		case 0x31: return emit(code, start, after, address, "rdtsc", "")
		case 0xA2: return emit(code, start, after, address, "cpuid", "")
		case 0x40...0x4F: return aluModRM(code, start, after, prefixes, address, "cmov" + Self.conditionSuffixes[Int(op2 & 0x0F)], direction: .load, byteForm: false)
		case 0x80...0x8F: return relative(code, start, after, address, "j" + Self.conditionSuffixes[Int(op2 & 0x0F)], width: 4)
		case 0x90...0x9F: return aluModRM(code, start, after, prefixes, address, "set" + Self.conditionSuffixes[Int(op2 & 0x0F)], direction: .store, byteForm: true, singleOperand: true)
		case 0xAE:
			if let fence = fence(code, start, after, address) {
				return fence
			}
			return raw(code, at: start, address: address, comment: nil)
		case 0xA3: return aluModRM(code, start, after, prefixes, address, "bt", direction: .store, byteForm: false)
		case 0xAB: return aluModRM(code, start, after, prefixes, address, "bts", direction: .store, byteForm: false)
		case 0xAF: return aluModRM(code, start, after, prefixes, address, "imul", direction: .load, byteForm: false)
		case 0xB0: return aluModRM(code, start, after, prefixes, address, "cmpxchg", direction: .store, byteForm: true)
		case 0xB1: return aluModRM(code, start, after, prefixes, address, "cmpxchg", direction: .store, byteForm: false)
		case 0xB6: return aluModRM(code, start, after, prefixes, address, "movzb" + q, direction: .load, byteForm: false, srcSize: .byte)
		case 0xB7: return aluModRM(code, start, after, prefixes, address, "movzw" + q, direction: .load, byteForm: false, srcSize: .word)
		case 0xB8:
			if prefixes.rep {
				return popcnt(code, start, after, prefixes, address)
			}
			return raw(code, at: start, address: address, comment: nil)
		case 0xB9: return aluModRM(code, start, after, prefixes, address, "ud1", direction: .load, byteForm: false)
		case 0xBC: return aluModRM(code, start, after, prefixes, address, prefixes.rep ? "tzcnt" : "bsf", direction: .load, byteForm: false)
		case 0xBD: return aluModRM(code, start, after, prefixes, address, prefixes.rep ? "lzcnt" : "bsr", direction: .load, byteForm: false)
		case 0xBE: return aluModRM(code, start, after, prefixes, address, "movsb" + q, direction: .load, byteForm: false, srcSize: .byte)
		case 0xBF: return aluModRM(code, start, after, prefixes, address, "movsw" + q, direction: .load, byteForm: false, srcSize: .word)
		case 0xA4: return shiftDouble(code, start, after, prefixes, address, "shld", byCL: false)
		case 0xA5: return shiftDouble(code, start, after, prefixes, address, "shld", byCL: true)
		case 0xAC: return shiftDouble(code, start, after, prefixes, address, "shrd", byCL: false)
		case 0xAD: return shiftDouble(code, start, after, prefixes, address, "shrd", byCL: true)
		case 0xB3: return aluModRM(code, start, after, prefixes, address, "btr", direction: .store, byteForm: false)
		case 0xBA: return bitGroupImm(code, start, after, prefixes, address)      // bt/bts/btr/btc r/m, imm8
		case 0xBB: return aluModRM(code, start, after, prefixes, address, "btc", direction: .store, byteForm: false)
		case 0xC0: return aluModRM(code, start, after, prefixes, address, "xadd", direction: .store, byteForm: true)
		case 0xC1: return aluModRM(code, start, after, prefixes, address, "xadd", direction: .store, byteForm: false)
		case 0xC3: return aluModRM(code, start, after, prefixes, address, "movnti", direction: .store, byteForm: false)
		case 0xC7:
			if let cmpxchg = cmpxchg8b16b(code, start, after, prefixes, address) {
				return cmpxchg
			}
			return raw(code, at: start, address: address, comment: nil)
		default: return raw(code, at: start, address: address, comment: nil)
		}
	}

	// MARK: - SSE / SSE2

	private enum MandatoryPrefix { case none, p66, f3, f2 }

	private func mandatoryPrefix(_ p: Prefixes) -> MandatoryPrefix {
		if p.rep { return .f3 }
		if p.repne { return .f2 }
		if p.operandSize { return .p66 }
		return .none
	}

	/// Decodes the SSE/SSE2 subset of the 0x0F opcode map; returns nil for 0x0F
	/// opcodes that aren't SSE (so the caller's integer/control switch handles them)
	/// or for prefix/opcode combinations this increment doesn't map yet.
	private func decodeSSE(_ op2: UInt8, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64) -> DecodedInstruction? {
		let mp = mandatoryPrefix(prefixes)
		func pick(_ n: String?, _ p66: String?, _ f3: String?, _ f2: String?) -> String? {
			switch mp { case .none: return n; case .p66: return p66; case .f3: return f3; case .f2: return f2 }
		}
		func reg(_ n: String?, _ p66: String?, _ f3: String?, _ f2: String?, _ dir: Direction = .load, imm8: Bool = false) -> DecodedInstruction? {
			guard let name = pick(n, p66, f3, f2) else { return nil }
			return sseRegRM(code, start, after, prefixes, address, name, direction: dir, imm8: imm8)
		}

		// The large 66-prefixed packed-integer family (punpck/pack/pcmpgt/pavg/pmul/
		// saturating add-sub/min-max + shift-by-xmm) all use the same xmm ModRM form.
		if mp == .p66 {
			if let name = Self.packed66[op2] {
				return sseRegRM(code, start, after, prefixes, address, name, direction: .load)
			}
			if op2 == 0x71 || op2 == 0x72 || op2 == 0x73 {
				return packedShiftImm(op2, code, start, after, prefixes, address, registerPrefix: "%xmm")
			}
		}
		if mp == .none {
			if let name = Self.packedMMX[op2] {
				return mmxRegRM(code, start, after, prefixes, address, name, direction: .load)
			}
			if op2 == 0x71 || op2 == 0x72 || op2 == 0x73 {
				return packedShiftImm(op2, code, start, after, prefixes, address, registerPrefix: "%mm")
			}
		}

		switch op2 {
		case 0x10: return reg("movups", "movupd", "movss", "movsd")
		case 0x11: return reg("movups", "movupd", "movss", "movsd", .store)
		case 0x12: return reg("movlps", "movlpd", "movsldup", "movddup")
		case 0x13: return reg("movlps", "movlpd", nil, nil, .store)
		case 0x14: return reg("unpcklps", "unpcklpd", nil, nil)
		case 0x15: return reg("unpckhps", "unpckhpd", nil, nil)
		case 0x16: return reg("movhps", "movhpd", "movshdup", nil)
		case 0x17: return reg("movhps", "movhpd", nil, nil, .store)
		case 0x28: return reg("movaps", "movapd", nil, nil)
		case 0x29: return reg("movaps", "movapd", nil, nil, .store)
		case 0x2A: // cvtsi2ss/sd: xmm <- r/m GPR
			guard let name = pick(nil, nil, "cvtsi2ss", "cvtsi2sd") else { return nil }
			return cvtIntToXMM(code, start, after, prefixes, address, name)
		case 0x2C: // cvttss2si/sd: GPR <- xmm/m
			guard let name = pick(nil, nil, "cvttss2si", "cvttsd2si") else { return nil }
			return cvtXMMToInt(code, start, after, prefixes, address, name)
		case 0x2D:
			guard let name = pick(nil, nil, "cvtss2si", "cvtsd2si") else { return nil }
			return cvtXMMToInt(code, start, after, prefixes, address, name)
		case 0x2E: return reg("ucomiss", "ucomisd", nil, nil)
		case 0x2F: return reg("comiss", "comisd", nil, nil)
		case 0x50:
			guard let name = pick("movmskps", "movmskpd", nil, nil) else { return nil }
			return sseMaskMove(code, start, after, prefixes, address, name)
		case 0x51: return reg("sqrtps", "sqrtpd", "sqrtss", "sqrtsd")
		case 0x53: return reg("rcpps", nil, "rcpss", nil)
		case 0x54: return reg("andps", "andpd", nil, nil)
		case 0x55: return reg("andnps", "andnpd", nil, nil)
		case 0x56: return reg("orps", "orpd", nil, nil)
		case 0x57: return reg("xorps", "xorpd", nil, nil)
		case 0x58: return reg("addps", "addpd", "addss", "addsd")
		case 0x59: return reg("mulps", "mulpd", "mulss", "mulsd")
		case 0x5A: return reg("cvtps2pd", "cvtpd2ps", "cvtss2sd", "cvtsd2ss")
		case 0x5B: return reg("cvtdq2ps", "cvtps2dq", "cvttps2dq", nil)
		case 0x5C: return reg("subps", "subpd", "subss", "subsd")
		case 0x5D: return reg("minps", "minpd", "minss", "minsd")
		case 0x5E: return reg("divps", "divpd", "divss", "divsd")
		case 0x5F: return reg("maxps", "maxpd", "maxss", "maxsd")
		case 0x6E: // movd/movq: xmm <- r/m GPR (66)
			if mp == .none { return movdGPRMMX(code, start, after, prefixes, address, store: false) }
			guard mp == .p66 else { return nil }
			return movdGPRXMM(code, start, after, prefixes, address, store: false)
		case 0x6F:
			if mp == .none { return mmxRegRM(code, start, after, prefixes, address, "movq", direction: .load) }
			return reg(nil, "movdqa", "movdqu", nil)
		case 0x70:
			if mp == .none { return mmxRegRM(code, start, after, prefixes, address, "pshufw", direction: .load, imm8: true) }
			return reg(nil, "pshufd", "pshufhw", "pshuflw", imm8: true)
		case 0x74: return reg(nil, "pcmpeqb", nil, nil)
		case 0x75: return reg(nil, "pcmpeqw", nil, nil)
		case 0x76: return reg(nil, "pcmpeqd", nil, nil)
		case 0x7C: return reg(nil, "haddpd", nil, "haddps")
		case 0x7D: return reg(nil, "hsubpd", nil, "hsubps")
		case 0x7E: // f3: movq xmm<-xmm/m64 ; 66: movd/movq r/m<-xmm
			if mp == .f3 { return reg(nil, nil, "movq", nil) }
			if mp == .none { return movdGPRMMX(code, start, after, prefixes, address, store: true) }
			guard mp == .p66 else { return nil }
			return movdGPRXMM(code, start, after, prefixes, address, store: true)
		case 0x7F:
			if mp == .none { return mmxRegRM(code, start, after, prefixes, address, "movq", direction: .store) }
			return reg(nil, "movdqa", "movdqu", nil, .store)
		case 0xC2: return reg("cmpps", "cmppd", "cmpss", "cmpsd", imm8: true)
		case 0xC4:
			if mp == .none || mp == .p66 {
				return pinsrw(code, start, after, prefixes, address, useXMM: mp == .p66)
			}
			return nil
		case 0xC5:
			if mp == .none || mp == .p66 {
				return pextrw(code, start, after, prefixes, address, useXMM: mp == .p66)
			}
			return nil
		case 0xC6: return reg("shufps", "shufpd", nil, nil, imm8: true)
		case 0xD4: return reg(nil, "paddq", nil, nil)
		case 0xD6: return reg(nil, "movq", nil, nil, .store) // movq xmm/m64 <- xmm
		case 0xD0: return reg(nil, "addsubpd", nil, "addsubps")
		case 0xD7:
			if mp == .none { return mmxMaskMove(code, start, after, prefixes, address, "pmovmskb") }
			guard mp == .p66 else { return nil }
			return sseMaskMove(code, start, after, prefixes, address, "pmovmskb")
		case 0xDB: return reg(nil, "pand", nil, nil)
		case 0xDF: return reg(nil, "pandn", nil, nil)
		case 0xE6: return reg(nil, "cvttpd2dq", "cvtdq2pd", "cvtpd2dq")
		case 0xEB: return reg(nil, "por", nil, nil)
		case 0xEF: return reg(nil, "pxor", nil, nil)
		case 0xF8: return reg(nil, "psubb", nil, nil)
		case 0xF9: return reg(nil, "psubw", nil, nil)
		case 0xFA: return reg(nil, "psubd", nil, nil)
		case 0xFB: return reg(nil, "psubq", nil, nil)
		case 0xFC: return reg(nil, "paddb", nil, nil)
		case 0xFD: return reg(nil, "paddw", nil, nil)
		case 0xFE: return reg(nil, "paddd", nil, nil)
		default: return nil
		}
	}

	/// xmm-register form: reg field and a register-direct r/m are xmm; memory r/m is normal.
	private func sseRegRM(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String, direction: Direction, imm8: Bool = false) -> DecodedInstruction {
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		var end = after + m.length
		let reg = "%xmm" + String(m.reg)
		let operands: String
		if imm8 {
			guard let (v, n) = Self.readImmediate(code, at: end, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			operands = "$0x" + String(v, radix: 16) + ", " + m.rmText + ", " + reg
			end += n
		} else {
			operands = direction == .store ? reg + ", " + m.rmText : m.rmText + ", " + reg
		}
		return finalize(code, start, end, address, mnemonic, operands, ripDisp: m.ripDisp)
	}

	/// MMX register form: reg field and register-direct r/m are `%mmN`; memory r/m is normal.
	private func mmxRegRM(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String, direction: Direction, imm8: Bool = false) -> DecodedInstruction {
		guard after < code.count,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		var end = after + m.length
		let reg = "%mm" + String((code[after] >> 3) & 0x7)
		let rmIndex = Int(code[after] & 0x7)
		let rm = m.isRegisterDirect ? "%mm" + String(rmIndex) : m.rmText
		let operands: String
		if imm8 {
			guard let (imm, n) = Self.readImmediate(code, at: end, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			operands = "$0x" + String(imm, radix: 16) + ", " + rm + ", " + reg
			end += n
		} else {
			operands = direction == .store ? reg + ", " + rm : rm + ", " + reg
		}
		return finalize(code, start, end, address, mnemonic, operands, ripDisp: m.ripDisp)
	}

	private func sseMaskMove(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String) -> DecodedInstruction {
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		let dest = Self.reg(m.reg, gprSize, hasREX: prefixes.hasREX)
		return finalize(code, start, after + m.length, address, mnemonic, m.rmText + ", " + dest, ripDisp: m.ripDisp)
	}

	private func mmxMaskMove(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String) -> DecodedInstruction {
		guard after < code.count,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		let dest = Self.reg(m.reg, gprSize, hasREX: prefixes.hasREX)
		let source = m.isRegisterDirect ? "%mm" + String(Int(code[after] & 0x7)) : m.rmText
		return finalize(code, start, after + m.length, address, mnemonic, source + ", " + dest, ripDisp: m.ripDisp)
	}

	private func movdGPRXMM(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, store: Bool) -> DecodedInstruction {
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: gprSize, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let xmm = "%xmm" + String(m.reg)
		let operands = store ? xmm + ", " + m.rmText : m.rmText + ", " + xmm
		return finalize(code, start, after + m.length, address, prefixes.rexW ? "movq" : "movd", operands, ripDisp: m.ripDisp)
	}

	private func movdGPRMMX(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, store: Bool) -> DecodedInstruction {
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		guard after < code.count,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: gprSize, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let mm = "%mm" + String((code[after] >> 3) & 0x7)
		let operands = store ? mm + ", " + m.rmText : m.rmText + ", " + mm
		return finalize(code, start, after + m.length, address, prefixes.rexW ? "movq" : "movd", operands, ripDisp: m.ripDisp)
	}

	private func pinsrw(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, useXMM: Bool) -> DecodedInstruction {
		guard after < code.count,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .dword, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let immStart = after + m.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let vector = (useXMM ? "%xmm" + String(m.reg) : "%mm" + String((code[after] >> 3) & 0x7))
		let operands = "$0x" + String(imm, radix: 16) + ", " + m.rmText + ", " + vector
		return finalize(code, start, immStart + n, address, "pinsrw", operands, ripDisp: m.ripDisp)
	}

	private func pextrw(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, useXMM: Bool) -> DecodedInstruction {
		guard after < code.count,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: useXMM) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let immStart = after + m.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let dest = Self.reg(m.reg, .dword)
		let rm = useXMM || !m.isRegisterDirect ? m.rmText : "%mm" + String(Int(code[after] & 0x7))
		let operands = "$0x" + String(imm, radix: 16) + ", " + rm + ", " + dest
		return finalize(code, start, immStart + n, address, "pextrw", operands, ripDisp: m.ripDisp)
	}

	private func cvtIntToXMM(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String) -> DecodedInstruction {
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: gprSize, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		return finalize(code, start, after + m.length, address, mnemonic, m.rmText + ", %xmm" + String(m.reg), ripDisp: m.ripDisp)
	}

	private func cvtXMMToInt(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String) -> DecodedInstruction {
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let gpr = Self.reg(m.reg, prefixes.rexW ? .qword : .dword)
		return finalize(code, start, after + m.length, address, mnemonic, m.rmText + ", " + gpr, ripDisp: m.ripDisp)
	}

	/// Packed shift-by-immediate group (0x0F 0x71/0x72/0x73): the ModRM reg field
	/// selects the operation and the (register-direct) r/m field is the vector operand.
	private func packedShiftImm(_ op2: UInt8, _ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, registerPrefix: String) -> DecodedInstruction {
		guard after < code.count,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let modrm = code[after]
		let regSel = Int((modrm >> 3) & 0x7)
		let rmIndex = Int(modrm & 0x7) | (registerPrefix == "%xmm" && prefixes.rexB ? 8 : 0)
		let rm = m.isRegisterDirect ? registerPrefix + String(rmIndex) : m.rmText
		let table: [Int: String]
		switch op2 {
		case 0x71: table = [2: "psrlw", 4: "psraw", 6: "psllw"]
		case 0x72: table = [2: "psrld", 4: "psrad", 6: "pslld"]
		default:   table = [2: "psrlq", 3: "psrldq", 6: "psllq", 7: "pslldq"]
		}
		let immAt = after + m.length
		guard let (v, n) = Self.readImmediate(code, at: immAt, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		return finalize(code, start, immAt + n, address, table[regSel] ?? "(psh)", "$0x" + String(v, radix: 16) + ", " + rm, ripDisp: m.ripDisp)
	}

	/// 3-byte escapes (0x0F 0x38 / 0x0F 0x3A). Length is fully determined by ModRM
	/// (+ imm8 for 0x3A), so the sweep stays synced even where the mnemonic is generic.
	private func decodeThreeByte(_ code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64, hasImm8: Bool) -> DecodedInstruction {
		guard after < code.count else { return raw(code, at: start, address: address, comment: nil) }
		let op3 = code[after]
		let modrmAt = after + 1
		if !hasImm8, op3 == 0xF0 || op3 == 0xF1 {
			if prefixes.repne {
				return crc32(op3, code, start, modrmAt, prefixes, address)
			}
			if !prefixes.rep {
				return movbe(op3, code, start, modrmAt, prefixes, address)
			}
		}
		guard let m = decodeModRM(code, at: modrmAt, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		var end = modrmAt + m.length
		let reg = "%xmm" + String(m.reg)
		if hasImm8 {
			guard let (v, n) = Self.readImmediate(code, at: end, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let name = Self.threeByte3A[op3] ?? "(sse3a)"
			end += n
			return finalize(code, start, end, address, name, "$0x" + String(v, radix: 16) + ", " + m.rmText + ", " + reg, ripDisp: m.ripDisp)
		}
		let name = Self.threeByte38[op3] ?? "(sse38)"
		return finalize(code, start, end, address, name, m.rmText + ", " + reg, ripDisp: m.ripDisp)
	}

	private func crc32(_ op3: UInt8, _ code: [UInt8], _ start: Int, _ modrmAt: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		let sourceSize: OperandSize
		if op3 == 0xF0 {
			sourceSize = .byte
		} else if prefixes.operandSize {
			sourceSize = .word
		} else {
			sourceSize = prefixes.rexW ? .qword : .dword
		}
		let destSize: OperandSize = prefixes.rexW ? .qword : .dword
		guard let m = decodeModRM(code, at: modrmAt, prefixes: prefixes, rmSize: sourceSize, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let dest = Self.reg(m.reg, destSize, hasREX: prefixes.hasREX)
		let mnemonic = "crc32" + Self.sizeSuffix(sourceSize)
		return finalize(code, start, modrmAt + m.length, address, mnemonic, m.rmText + ", " + dest, ripDisp: m.ripDisp)
	}

	private func movbe(_ op3: UInt8, _ code: [UInt8], _ start: Int, _ modrmAt: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		let size: OperandSize = prefixes.rexW ? .qword : (prefixes.operandSize ? .word : .dword)
		guard let m = decodeModRM(code, at: modrmAt, prefixes: prefixes, rmSize: size, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		// MOVBE requires a memory operand; mod==11 (register r/m) is #UD. Emit a
		// length-correct generic placeholder rather than a wrong `movbe` rendering.
		if m.isRegisterDirect {
			return finalize(code, start, modrmAt + m.length, address, "(sse38)", m.rmText, ripDisp: m.ripDisp)
		}
		let reg = Self.reg(m.reg, size, hasREX: prefixes.hasREX)
		let operands = op3 == 0xF1 ? reg + ", " + m.rmText : m.rmText + ", " + reg
		return finalize(code, start, modrmAt + m.length, address, "movbe" + Self.sizeSuffix(size), operands, ripDisp: m.ripDisp)
	}

	private func popcnt(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		let size: OperandSize = prefixes.rexW ? .qword : (prefixes.operandSize ? .word : .dword)
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: size, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let dest = Self.reg(m.reg, size, hasREX: prefixes.hasREX)
		return finalize(code, start, after + m.length, address, "popcnt" + Self.sizeSuffix(size), m.rmText + ", " + dest, ripDisp: m.ripDisp)
	}


	// MARK: - AVX / VEX

	private func decodeVEX(_ leading: UInt8, code: [UInt8], start: Int, opcodeEnd: Int, address: UInt64) -> DecodedInstruction {
		var cursor = opcodeEnd
		var prefixes = Prefixes()
		prefixes.hasREX = true
		var map = 1
		var vvvv = 0
		var vectorLength256 = false
		var pp = 0

		if leading == 0xC5 {
			guard cursor < code.count else { return raw(code, at: start, address: address, comment: "Truncated VEX") }
			let b1 = code[cursor]
			cursor += 1
			prefixes.rexR = (b1 & 0x80) == 0
			prefixes.rexX = false
			prefixes.rexB = false
			prefixes.rexW = false
			vvvv = Int((b1 >> 3) & 0x0F) ^ 0x0F
			vectorLength256 = (b1 & 0x04) != 0
			pp = Int(b1 & 0x03)
			map = 1
		} else {
			guard cursor + 1 < code.count else { return raw(code, at: start, address: address, comment: "Truncated VEX") }
			let b1 = code[cursor]
			let b2 = code[cursor + 1]
			cursor += 2
			prefixes.rexR = (b1 & 0x80) == 0
			prefixes.rexX = (b1 & 0x40) == 0
			prefixes.rexB = (b1 & 0x20) == 0
			prefixes.rexW = (b2 & 0x80) != 0
			vvvv = Int((b2 >> 3) & 0x0F) ^ 0x0F
			vectorLength256 = (b2 & 0x04) != 0
			pp = Int(b2 & 0x03)
			map = Int(b1 & 0x1F)
		}

		switch pp {
		case 1: prefixes.operandSize = true
		case 2: prefixes.rep = true
		case 3: prefixes.repne = true
		default: break
		}

		guard cursor < code.count else { return raw(code, at: start, address: address, comment: "Truncated VEX opcode") }
		let opcode = code[cursor]
		let afterOpcode = cursor + 1

		switch map {
		case 1:
			return decodeVEX0F(opcode, code: code, start: start, after: afterOpcode, prefixes: prefixes, address: address, vectorLength256: vectorLength256, vvvv: vvvv)
		case 2:
			return decodeVEXMap2(opcode, code: code, start: start, after: afterOpcode, prefixes: prefixes, address: address, vectorLength256: vectorLength256, vvvv: vvvv)
		case 3:
			return decodeVEXMap3(opcode, code: code, start: start, after: afterOpcode, prefixes: prefixes, address: address, vectorLength256: vectorLength256, vvvv: vvvv)
		default:
			return raw(code, at: start, address: address, comment: nil)
		}
	}

	private func decodeVEX0F(
		_ op2: UInt8, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64,
		vectorLength256: Bool, vvvv: Int
	) -> DecodedInstruction {
		let mp = mandatoryPrefix(prefixes)
		func pick(_ n: String?, _ p66: String?, _ f3: String?, _ f2: String?) -> String? {
			switch mp { case .none: return n; case .p66: return p66; case .f3: return f3; case .f2: return f2 }
		}
		func vec(_ index: Int, scalar: Bool = false) -> String {
			(vectorLength256 && !scalar ? "%ymm" : "%xmm") + String(index)
		}
		func rmVec(_ text: String, scalar: Bool = false) -> String {
			(vectorLength256 && !scalar) ? text.replacingOccurrences(of: "%xmm", with: "%ymm") : text
		}
		func vexRegRM(_ mnemonic: String, scalar: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = rmVec(m.rmText, scalar: scalar) + ", " + vec(vvvv, scalar: scalar) + ", " + vec(m.reg, scalar: scalar)
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func vexMove(_ mnemonic: String, store: Bool, scalar: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let regText = vec(m.reg, scalar: scalar)
			let rmText = rmVec(m.rmText, scalar: scalar)
			let operands = store ? regText + ", " + rmText : rmText + ", " + regText
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func vexTwoOperand(_ mnemonic: String, scalar: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = rmVec(m.rmText, scalar: scalar) + ", " + vec(m.reg, scalar: scalar)
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func vexImmTwoOperand(_ mnemonic: String, scalar: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let operands = "$0x" + String(imm, radix: 16) + ", " + rmVec(m.rmText, scalar: scalar) + ", " + vec(m.reg, scalar: scalar)
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func vexImmRegRM(_ mnemonic: String, scalar: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let operands = "$0x" + String(imm, radix: 16) + ", " + rmVec(m.rmText, scalar: scalar) + ", " + vec(vvvv, scalar: scalar) + ", " + vec(m.reg, scalar: scalar)
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		// Scalar vmovss/vmovsd: the REGISTER-direct r/m form (mod==11) is a 3-operand merge
		// (otool: rm, vvvv, reg for load / reg, vvvv, rm for store); a memory r/m is 2-operand.
		func vexScalarMove(_ mnemonic: String, store: Bool) -> DecodedInstruction {
			guard after < code.count, let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let isReg = (code[after] >> 6) & 0x3 == 0x3
			let reg = vec(m.reg, scalar: true)
			let rm = m.rmText
			let operands: String
			if isReg {
				operands = store ? (reg + ", " + vec(vvvv, scalar: true) + ", " + rm)
								 : (rm + ", " + vec(vvvv, scalar: true) + ", " + reg)
			} else {
				operands = store ? (reg + ", " + rm) : (rm + ", " + reg)
			}
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func vexKMov(_ opcode: UInt8) -> DecodedInstruction? {
			let mnemonic: String
			let gpSize: OperandSize
			switch mp {
			case .none:
				mnemonic = prefixes.rexW ? "kmovq" : "kmovw"
				gpSize = prefixes.rexW ? .qword : .dword
			case .p66:
				mnemonic = prefixes.rexW ? "kmovd" : "kmovb"; gpSize = .dword
			case .f2:
				mnemonic = prefixes.rexW ? "kmovq" : "kmovd"
				gpSize = prefixes.rexW ? .qword : .dword
			case .f3:
				return nil
			}
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: gpSize, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			func kReg(_ index: Int) -> String { "%k" + String(index & 0x7) }
			func kRM() -> String {
				if m.isRegisterDirect { return kReg(Int(code[after] & 0x07)) }
				return m.rmText
			}
			let operands: String
			switch opcode {
			case 0x90:
				operands = kRM() + ", " + kReg(m.reg)
			case 0x91:
				operands = kReg(m.reg) + ", " + kRM()
			case 0x92:
				operands = m.rmText + ", " + kReg(m.reg)
			case 0x93:
				operands = kRM() + ", " + Self.reg(m.reg, gpSize, hasREX: prefixes.hasREX)
			default:
				return nil
			}
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func kReg(_ index: Int) -> String { "%k" + String(index & 0x7) }
		func vexKWidthSuffix() -> String? {
			switch (mp, prefixes.rexW) {
			case (.none, false): return "w"
			case (.p66, false): return "b"
			case (.none, true): return "q"
			case (.p66, true): return "d"
			default: return nil
			}
		}
		func vexKMask3(_ base: String) -> DecodedInstruction? {
			guard vectorLength256, let suffix = vexKWidthSuffix() else { return nil }
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .dword, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = kReg(Int(code[after] & 0x07)) + ", " + kReg(vvvv) + ", " + kReg(m.reg)
			return finalize(code, start, after + m.length, address, base + suffix, operands, ripDisp: m.ripDisp)
		}
		func vexKMaskUnary(_ base: String) -> DecodedInstruction? {
			guard !vectorLength256, let suffix = vexKWidthSuffix() else { return nil }
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .dword, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = kReg(Int(code[after] & 0x07)) + ", " + kReg(m.reg)
			return finalize(code, start, after + m.length, address, base + suffix, operands, ripDisp: m.ripDisp)
		}
		func vexKMaskTest(_ base: String) -> DecodedInstruction? {
			guard !vectorLength256, let suffix = vexKWidthSuffix() else { return nil }
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .dword, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = kReg(Int(code[after] & 0x07)) + ", " + kReg(m.reg)
			return finalize(code, start, after + m.length, address, base + suffix, operands, ripDisp: m.ripDisp)
		}
		func vexKMaskUnpack() -> DecodedInstruction? {
			guard vectorLength256 else { return nil }
			let mnemonic: String
			switch (mp, prefixes.rexW) {
			case (.p66, false): mnemonic = "kunpckbw"
			case (.none, false): mnemonic = "kunpckwd"
			case (.none, true): mnemonic = "kunpckdq"
			default: return nil
			}
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .dword, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = kReg(Int(code[after] & 0x07)) + ", " + kReg(vvvv) + ", " + kReg(m.reg)
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		// Asymmetric-width packed convert: vcvtps2pd widens 128->256 (src stays xmm, dst ymm at L);
		// vcvtpd2ps narrows 256->128 (src ymm at L, dst xmm). The uniform L-bit width does NOT apply.
		func vexCvtPackedAsym(_ mnemonic: String, widen: Bool) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let dst = (vectorLength256 && widen ? "%ymm" : "%xmm") + String(m.reg)
			let src = (vectorLength256 && !widen) ? m.rmText.replacingOccurrences(of: "%xmm", with: "%ymm") : m.rmText
			// Narrowing converts leave an xmm dest for BOTH the 128- and 256-bit source, so a
			// MEMORY source is size-ambiguous -> otool/LLVM append an x (128) / y (256) suffix.
			// A register source carries its own width; widening converts vary the dest reg size.
			var mnem = mnemonic
			if !widen && !m.isRegisterDirect {
				mnem += vectorLength256 ? "y" : "x"
			}
			return finalize(code, start, after + m.length, address, mnem, src + ", " + dst, ripDisp: m.ripDisp)
		}

		if op2 == 0x77 {
			return emit(code, start, after, address, vectorLength256 ? "vzeroall" : "vzeroupper", "")
		}

		if mp == .p66, let packed = Self.packed66[op2], op2 != 0x70 {
			return vexRegRM("v" + packed)
		}
		if mp == .p66, op2 == 0x71 || op2 == 0x72 || op2 == 0x73 {
			return vexPackedShiftImm(op2, code, start, after, prefixes, address, vectorLength256: vectorLength256, vvvv: vvvv)
		}

		switch op2 {
		case 0x10:
			if let name = pick("vmovups", "vmovupd", "vmovss", "vmovsd") {
				return (mp == .f3 || mp == .f2) ? vexScalarMove(name, store: false) : vexMove(name, store: false)
			}
		case 0x11:
			if let name = pick("vmovups", "vmovupd", "vmovss", "vmovsd") {
				return (mp == .f3 || mp == .f2) ? vexScalarMove(name, store: true) : vexMove(name, store: true)
			}
		case 0x14:
			if let name = pick("vunpcklps", "vunpcklpd", nil, nil) { return vexRegRM(name) }
		case 0x15:
			if let name = pick("vunpckhps", "vunpckhpd", nil, nil) { return vexRegRM(name) }
		case 0x28:
			if let name = pick("vmovaps", "vmovapd", nil, nil) { return vexMove(name, store: false) }
		case 0x29:
			if let name = pick("vmovaps", "vmovapd", nil, nil) { return vexMove(name, store: true) }
		case 0x2A:
			if let name = pick(nil, nil, "vcvtsi2ss", "vcvtsi2sd") { return vexCvtIntToScalar(code, start, after, prefixes, address, name, vvvv: vvvv) }
		case 0x2C:
			if let name = pick(nil, nil, "vcvttss2si", "vcvttsd2si") { return cvtXMMToInt(code, start, after, prefixes, address, name) }
		case 0x2D:
			if let name = pick(nil, nil, "vcvtss2si", "vcvtsd2si") { return cvtXMMToInt(code, start, after, prefixes, address, name) }
		case 0x2E:
			if let name = pick("vucomiss", "vucomisd", nil, nil) { return vexTwoOperand(name, scalar: true) }
		case 0x2F:
			if let name = pick("vcomiss", "vcomisd", nil, nil) { return vexTwoOperand(name, scalar: true) }
		case 0x41:
			if let k = vexKMask3("kand") { return k }
		case 0x42:
			if let k = vexKMask3("kandn") { return k }
		case 0x44:
			if let k = vexKMaskUnary("knot") { return k }
		case 0x45:
			if let k = vexKMask3("kor") { return k }
		case 0x46:
			if let k = vexKMask3("kxnor") { return k }
		case 0x47:
			if let k = vexKMask3("kxor") { return k }
		case 0x4A:
			if let k = vexKMask3("kadd") { return k }
		case 0x4B:
			if let k = vexKMaskUnpack() { return k }
		case 0x51:
			if let name = pick("vsqrtps", "vsqrtpd", "vsqrtss", "vsqrtsd") {
				// Scalar vsqrtss/sd are 3-operand (rm, vvvv, reg); packed vsqrtps/pd are 2-operand.
				return (mp == .f3 || mp == .f2) ? vexRegRM(name, scalar: true) : vexTwoOperand(name)
			}
		case 0x54:
			if let name = pick("vandps", "vandpd", nil, nil) { return vexRegRM(name) }
		case 0x55:
			if let name = pick("vandnps", "vandnpd", nil, nil) { return vexRegRM(name) }
		case 0x56:
			if let name = pick("vorps", "vorpd", nil, nil) { return vexRegRM(name) }
		case 0x57:
			if let name = pick("vxorps", "vxorpd", nil, nil) { return vexRegRM(name) }
		case 0x58:
			if let name = pick("vaddps", "vaddpd", "vaddss", "vaddsd") { return vexRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0x59:
			if let name = pick("vmulps", "vmulpd", "vmulss", "vmulsd") { return vexRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0x5A:
			if let name = pick("vcvtps2pd", "vcvtpd2ps", "vcvtss2sd", "vcvtsd2ss") {
				// Scalar vcvtss2sd/sd2ss are 3-operand; the packed converts are asymmetric-width 2-operand
				// (vcvtps2pd widens, vcvtpd2ps narrows) so they cannot use the uniform L-bit renderer.
				if mp == .f3 || mp == .f2 { return vexRegRM(name, scalar: true) }
				return vexCvtPackedAsym(name, widen: mp == .none)
			}
		case 0x5B:
			// vcvttps2dq is F3-encoded (not F2): put it in the f3 slot.
			if let name = pick("vcvtdq2ps", "vcvtps2dq", "vcvttps2dq", nil) { return vexTwoOperand(name) }
		case 0xE6:
			if mp == .p66 { return vexCvtPackedAsym("vcvttpd2dq", widen: false) }
			if mp == .f2 { return vexCvtPackedAsym("vcvtpd2dq", widen: false) }
			if mp == .f3 { return vexCvtPackedAsym("vcvtdq2pd", widen: true) }
		case 0x5C:
			if let name = pick("vsubps", "vsubpd", "vsubss", "vsubsd") { return vexRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0x5D:
			if let name = pick("vminps", "vminpd", "vminss", "vminsd") { return vexRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0x5E:
			if let name = pick("vdivps", "vdivpd", "vdivss", "vdivsd") { return vexRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0x5F:
			if let name = pick("vmaxps", "vmaxpd", "vmaxss", "vmaxsd") { return vexRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0x6E:
			if mp == .p66 { return vexMovdGPRXMM(code, start, after, prefixes, address, store: false) }
		case 0x6F:
			if let name = pick(nil, "vmovdqa", "vmovdqu", nil) { return vexMove(name, store: false) }
		case 0x70:
			if let name = pick(nil, "vpshufd", "vpshufhw", "vpshuflw") { return vexImmTwoOperand(name) }
		case 0x7E:
			if mp == .p66 { return vexMovdGPRXMM(code, start, after, prefixes, address, store: true) }
			if mp == .f3 { return vexTwoOperand("vmovq", scalar: true) }
		case 0x7F:
			if let name = pick(nil, "vmovdqa", "vmovdqu", nil) { return vexMove(name, store: true) }
		case 0x90, 0x91, 0x92, 0x93:
			if let kmov = vexKMov(op2) { return kmov }
		case 0x98:
			if let k = vexKMaskTest("kortest") { return k }
		case 0x99:
			if let k = vexKMaskTest("ktest") { return k }
		case 0xC2:
			if let name = pick("vcmpps", "vcmppd", "vcmpss", "vcmpsd") { return vexImmRegRM(name, scalar: mp == .f3 || mp == .f2) }
		case 0xC6:
			if let name = pick("vshufps", "vshufpd", nil, nil) { return vexImmRegRM(name) }
		case 0xD6:
			if mp == .p66 || mp == .f3 { return vexMove("vmovq", store: true, scalar: true) }
		case 0xDB:
			if mp == .p66 { return vexRegRM("vpand") }
		case 0xDF:
			if mp == .p66 { return vexRegRM("vpandn") }
		case 0xEB:
			if mp == .p66 { return vexRegRM("vpor") }
		case 0xEF:
			if mp == .p66 { return vexRegRM("vpxor") }
		case 0xF8:
			if mp == .p66 { return vexRegRM("vpsubb") }
		case 0xF9:
			if mp == .p66 { return vexRegRM("vpsubw") }
		case 0xFA:
			if mp == .p66 { return vexRegRM("vpsubd") }
		case 0xFB:
			if mp == .p66 { return vexRegRM("vpsubq") }
		case 0xFC:
			if mp == .p66 { return vexRegRM("vpaddb") }
		case 0xFD:
			if mp == .p66 { return vexRegRM("vpaddw") }
		case 0xFE:
			if mp == .p66 { return vexRegRM("vpaddd") }
		default:
			break
		}

		return decodeVEX3BytePlaceholder("(vex)", code: code, start: start, after: after, prefixes: prefixes, address: address, vectorLength256: vectorLength256, hasImm8: false)
	}

	private func decodeVEXMap2(
		_ op3: UInt8, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64,
		vectorLength256: Bool, vvvv: Int
	) -> DecodedInstruction {
		let mp = mandatoryPrefix(prefixes)
		let key = Self.opcodePrefixKey(op3, mp)
		let size: OperandSize = prefixes.rexW ? .qword : .dword
		let suffix = Self.sizeSuffix(size)

		func vexMap2Widen(_ mnemonic: String) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let dest = (vectorLength256 ? "%ymm" : "%xmm") + String(m.reg)
			return finalize(code, start, after + m.length, address, mnemonic, m.rmText + ", " + dest, ripDisp: m.ripDisp)
		}
		func vexVec(_ index: Int, scalar: Bool = false) -> String {
			(vectorLength256 && !scalar ? "%ymm" : "%xmm") + String(index)
		}
		func vexRMVec(_ text: String, scalar: Bool = false) -> String {
			(vectorLength256 && !scalar) ? text.replacingOccurrences(of: "%xmm", with: "%ymm") : text
		}
		func vexMap2RegRM(_ mnemonic: String, scalar: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let operands = vexRMVec(m.rmText, scalar: scalar) + ", " + vexVec(vvvv, scalar: scalar) + ", " + vexVec(m.reg, scalar: scalar)
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}

		if mp == .p66 {
			switch op3 {
			case 0x13:
				return vexMap2Widen("vcvtph2ps")
			case 0x20:
				return vexMap2Widen("vpmovsxbw")
			case 0x21:
				return vexMap2Widen("vpmovsxbd")
			case 0x22:
				return vexMap2Widen("vpmovsxbq")
			case 0x23:
				return vexMap2Widen("vpmovsxwd")
			case 0x24:
				return vexMap2Widen("vpmovsxwq")
			case 0x25:
				return vexMap2Widen("vpmovsxdq")
			case 0x30:
				return vexMap2Widen("vpmovzxbw")
			case 0x31:
				return vexMap2Widen("vpmovzxbd")
			case 0x32:
				return vexMap2Widen("vpmovzxbq")
			case 0x33:
				return vexMap2Widen("vpmovzxwd")
			case 0x34:
				return vexMap2Widen("vpmovzxwq")
			case 0x35:
				return vexMap2Widen("vpmovzxdq")
			case 0x96:
				return vexMap2RegRM(prefixes.rexW ? "vfmaddsub132pd" : "vfmaddsub132ps")
			case 0x97:
				return vexMap2RegRM(prefixes.rexW ? "vfmsubadd132pd" : "vfmsubadd132ps")
			case 0x98:
				return vexMap2RegRM(prefixes.rexW ? "vfmadd132pd" : "vfmadd132ps")
			case 0x99:
				return vexMap2RegRM(prefixes.rexW ? "vfmadd132sd" : "vfmadd132ss", scalar: true)
			case 0x9A:
				return vexMap2RegRM(prefixes.rexW ? "vfmsub132pd" : "vfmsub132ps")
			case 0x9B:
				return vexMap2RegRM(prefixes.rexW ? "vfmsub132sd" : "vfmsub132ss", scalar: true)
			case 0x9C:
				return vexMap2RegRM(prefixes.rexW ? "vfnmadd132pd" : "vfnmadd132ps")
			case 0x9D:
				return vexMap2RegRM(prefixes.rexW ? "vfnmadd132sd" : "vfnmadd132ss", scalar: true)
			case 0x9E:
				return vexMap2RegRM(prefixes.rexW ? "vfnmsub132pd" : "vfnmsub132ps")
			case 0x9F:
				return vexMap2RegRM(prefixes.rexW ? "vfnmsub132sd" : "vfnmsub132ss", scalar: true)
			case 0xA6:
				return vexMap2RegRM(prefixes.rexW ? "vfmaddsub213pd" : "vfmaddsub213ps")
			case 0xA7:
				return vexMap2RegRM(prefixes.rexW ? "vfmsubadd213pd" : "vfmsubadd213ps")
			case 0xA8:
				return vexMap2RegRM(prefixes.rexW ? "vfmadd213pd" : "vfmadd213ps")
			case 0xA9:
				return vexMap2RegRM(prefixes.rexW ? "vfmadd213sd" : "vfmadd213ss", scalar: true)
			case 0xAA:
				return vexMap2RegRM(prefixes.rexW ? "vfmsub213pd" : "vfmsub213ps")
			case 0xAB:
				return vexMap2RegRM(prefixes.rexW ? "vfmsub213sd" : "vfmsub213ss", scalar: true)
			case 0xAC:
				return vexMap2RegRM(prefixes.rexW ? "vfnmadd213pd" : "vfnmadd213ps")
			case 0xAD:
				return vexMap2RegRM(prefixes.rexW ? "vfnmadd213sd" : "vfnmadd213ss", scalar: true)
			case 0xAE:
				return vexMap2RegRM(prefixes.rexW ? "vfnmsub213pd" : "vfnmsub213ps")
			case 0xAF:
				return vexMap2RegRM(prefixes.rexW ? "vfnmsub213sd" : "vfnmsub213ss", scalar: true)
			case 0xB6:
				return vexMap2RegRM(prefixes.rexW ? "vfmaddsub231pd" : "vfmaddsub231ps")
			case 0xB7:
				return vexMap2RegRM(prefixes.rexW ? "vfmsubadd231pd" : "vfmsubadd231ps")
			case 0xB8:
				return vexMap2RegRM(prefixes.rexW ? "vfmadd231pd" : "vfmadd231ps")
			case 0xB9:
				return vexMap2RegRM(prefixes.rexW ? "vfmadd231sd" : "vfmadd231ss", scalar: true)
			case 0xBA:
				return vexMap2RegRM(prefixes.rexW ? "vfmsub231pd" : "vfmsub231ps")
			case 0xBB:
				return vexMap2RegRM(prefixes.rexW ? "vfmsub231sd" : "vfmsub231ss", scalar: true)
			case 0xBC:
				return vexMap2RegRM(prefixes.rexW ? "vfnmadd231pd" : "vfnmadd231ps")
			case 0xBD:
				return vexMap2RegRM(prefixes.rexW ? "vfnmadd231sd" : "vfnmadd231ss", scalar: true)
			case 0xBE:
				return vexMap2RegRM(prefixes.rexW ? "vfnmsub231pd" : "vfnmsub231ps")
			case 0xBF:
				return vexMap2RegRM(prefixes.rexW ? "vfnmsub231sd" : "vfnmsub231ss", scalar: true)
			case 0xCF:
				// GFNI vgf2p8mulb (VEX.66.0F38.W0). W1 is #UD; fall through to placeholder.
				if !prefixes.rexW { return vexMap2RegRM("vgf2p8mulb") }
			default:
				break
			}
		}

		if key == 0xF300 {
			guard after < code.count else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let subOpcode = Int((code[after] >> 3) & 0x7)
			guard let base = Self.bmiF3Map2[subOpcode] else {
				return decodeVEX3BytePlaceholder("(vex38)", code: code, start: start, after: after, prefixes: prefixes, address: address, vectorLength256: vectorLength256, hasImm8: false)
			}
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: size, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let dest = Self.reg(vvvv, size)
			return finalize(code, start, after + m.length, address, base + suffix, m.rmText + ", " + dest, ripDisp: m.ripDisp)
		}

		if let base = Self.bmiMap2[key] {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: size, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let dest = Self.reg(m.reg, size)
			let vreg = Self.reg(vvvv, size)
			let operands: String
			switch base {
			case "andn", "pext", "pdep", "mulx":
				operands = m.rmText + ", " + vreg + ", " + dest
			default:
				operands = vreg + ", " + m.rmText + ", " + dest
			}
			return finalize(code, start, after + m.length, address, base + suffix, operands, ripDisp: m.ripDisp)
		}

		return decodeVEX3BytePlaceholder("(vex38)", code: code, start: start, after: after, prefixes: prefixes, address: address, vectorLength256: vectorLength256, hasImm8: false)
	}

	private func decodeVEXMap3(
		_ op3: UInt8, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64,
		vectorLength256: Bool, vvvv: Int
	) -> DecodedInstruction {
		let mp = mandatoryPrefix(prefixes)
		let key = Self.opcodePrefixKey(op3, mp)
		let size: OperandSize = prefixes.rexW ? .qword : .dword
		let suffix = Self.sizeSuffix(size)
		func kReg(_ index: Int) -> String { "%k" + String(index & 0x7) }
		func vexKMaskShift() -> DecodedInstruction? {
			guard mp == .p66, !vectorLength256 else { return nil }
			let mnemonic: String
			switch (op3, prefixes.rexW) {
			case (0x30, false): mnemonic = "kshiftrb"
			case (0x30, true): mnemonic = "kshiftrw"
			case (0x31, false): mnemonic = "kshiftrd"
			case (0x31, true): mnemonic = "kshiftrq"
			case (0x32, false): mnemonic = "kshiftlb"
			case (0x32, true): mnemonic = "kshiftlw"
			case (0x33, false): mnemonic = "kshiftld"
			case (0x33, true): mnemonic = "kshiftlq"
			default: return nil
			}
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .dword, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let operands = "$0x" + String(imm, radix: 16) + ", " + kReg(Int(code[after] & 0x07)) + ", " + kReg(m.reg)
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}

		if op3 >= 0x30, op3 <= 0x33, let kshift = vexKMaskShift() {
			return kshift
		}

		// GFNI affine (VEX.66.0F3A.W1 CE/CF): 4-operand `$imm, rm, vvvv(src), reg(dst)`,
		// XMM/YMM by vector length. W0 is #UD, so gate on rexW; otherwise fall through.
		if mp == .p66, prefixes.rexW, op3 == 0xCE || op3 == 0xCF {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let vecPrefix = vectorLength256 ? "%ymm" : "%xmm"
			let rmText = vectorLength256 ? m.rmText.replacingOccurrences(of: "%xmm", with: "%ymm") : m.rmText
			let mnemonic = op3 == 0xCE ? "vgf2p8affineqb" : "vgf2p8affineinvqb"
			let operands = "$0x" + String(imm, radix: 16) + ", " + rmText + ", " + vecPrefix + String(vvvv) + ", " + vecPrefix + String(m.reg)
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}

		if let base = Self.bmiMap3[key] {
			guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: size, rmIsXMM: false) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let dest = Self.reg(m.reg, size)
			let operands = "$0x" + String(imm, radix: 16) + ", " + m.rmText + ", " + dest
			return finalize(code, start, immStart + n, address, base + suffix, operands, ripDisp: m.ripDisp)
		}

		return decodeVEX3BytePlaceholder("(vex3a)", code: code, start: start, after: after, prefixes: prefixes, address: address, vectorLength256: vectorLength256, hasImm8: true)
	}

	private func vexCvtIntToScalar(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String, vvvv: Int) -> DecodedInstruction {
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: gprSize, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let operands = m.rmText + ", %xmm" + String(vvvv) + ", %xmm" + String(m.reg)
		return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
	}

	private func vexMovdGPRXMM(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, store: Bool) -> DecodedInstruction {
		let gprSize: OperandSize = prefixes.rexW ? .qword : .dword
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: gprSize, rmIsXMM: false) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let xmm = "%xmm" + String(m.reg)
		let operands = store ? xmm + ", " + m.rmText : m.rmText + ", " + xmm
		return finalize(code, start, after + m.length, address, prefixes.rexW ? "vmovq" : "vmovd", operands, ripDisp: m.ripDisp)
	}

	private func vexPackedShiftImm(_ op2: UInt8, _ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, vectorLength256: Bool, vvvv: Int) -> DecodedInstruction {
		guard after < code.count else { return raw(code, at: start, address: address, comment: "Truncated ModRM") }
		let modrm = code[after]
		let regSel = Int((modrm >> 3) & 0x7)
		let rm = Int(modrm & 0x7) | (prefixes.rexB ? 8 : 0)
		let table: [Int: String]
		switch op2 {
		case 0x71: table = [2: "vpsrlw", 4: "vpsraw", 6: "vpsllw"]
		case 0x72: table = [2: "vpsrld", 4: "vpsrad", 6: "vpslld"]
		default: table = [2: "vpsrlq", 3: "vpsrldq", 6: "vpsllq", 7: "vpslldq"]
		}
		let immAt = after + 1
		guard let (imm, n) = Self.readImmediate(code, at: immAt, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		// VEX shift-by-imm is 3-operand: vvvv is the DESTINATION, the r/m register the source.
		// otool prints `$imm, src, dst`.
		let prefix = vectorLength256 ? "%ymm" : "%xmm"
		let operands = "$0x" + String(imm, radix: 16) + ", " + prefix + String(rm) + ", " + prefix + String(vvvv)
		return finalize(code, start, immAt + n, address, table[regSel] ?? "(vpsh)", operands, ripDisp: nil)
	}

	private func decodeVEX3BytePlaceholder(_ mnemonic: String, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64, vectorLength256: Bool, hasImm8: Bool) -> DecodedInstruction {
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword, rmIsXMM: true) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		var end = after + m.length
		if hasImm8 {
			guard let (_, n) = Self.readImmediate(code, at: end, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			end += n
		}
		let regPrefix = vectorLength256 ? "%ymm" : "%xmm"
		let rmText = vectorLength256 ? m.rmText.replacingOccurrences(of: "%xmm", with: "%ymm") : m.rmText
		return finalize(code, start, end, address, mnemonic, rmText + ", " + regPrefix + String(m.reg), ripDisp: m.ripDisp)
	}

	// MARK: - ModRM-based forms

	private func aluModRM(
		_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64,
		_ mnemonic: String, direction: Direction, byteForm: Bool,
		srcSize: OperandSize? = nil, singleOperand: Bool = false
	) -> DecodedInstruction {
		let regSize: OperandSize = byteForm ? .byte : Self.operandSize(prefixes)
		let rmSize: OperandSize = srcSize ?? regSize
		guard let modrm = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: rmSize) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let end = opcodeEnd + modrm.length
		if singleOperand {
			return finalize(code, start, end, address, mnemonic, modrm.rmText, ripDisp: modrm.ripDisp)
		}
		let regText = Self.reg(modrm.reg, regSize, hasREX: prefixes.hasREX)
		let operands = direction == .store ? regText + ", " + modrm.rmText : modrm.rmText + ", " + regText
		return finalize(code, start, end, address, mnemonic, operands, ripDisp: modrm.ripDisp)
	}

	private func aluAccImm(
		_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64,
		_ mnemonic: String, width: Int, byteForm: Bool
	) -> DecodedInstruction {
		guard let (imm, n) = Self.readImmediate(code, at: opcodeEnd, width: width) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let acc = byteForm ? Self.reg(0, .byte, hasREX: prefixes.hasREX) : Self.reg(0, Self.operandSize(prefixes))
		return emit(code, start, opcodeEnd + n, address, mnemonic, "$0x" + String(imm, radix: 16) + ", " + acc)
	}

	private func groupImm(
		_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64,
		names: [String], width: Int, byteForm: Bool
	) -> DecodedInstruction {
		let size: OperandSize = byteForm ? .byte : Self.operandSize(prefixes)
		guard let modrm = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let opIndex = (Int(code[opcodeEnd]) >> 3) & 0x7
		let immStart = opcodeEnd + modrm.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: width) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let operands = "$0x" + String(imm, radix: 16) + ", " + modrm.rmText
		return finalize(code, start, immStart + n, address, names[opIndex], operands, ripDisp: modrm.ripDisp)
	}

	private func groupShift(
		_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64,
		byteForm: Bool, by: String?
	) -> DecodedInstruction {
		let size: OperandSize = byteForm ? .byte : Self.operandSize(prefixes)
		guard let modrm = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let opIndex = (Int(code[opcodeEnd]) >> 3) & 0x7
		let operands = by.map { $0 + ", " + modrm.rmText } ?? modrm.rmText
		return finalize(code, start, opcodeEnd + modrm.length, address, Self.shiftNames[opIndex], operands, ripDisp: modrm.ripDisp)
	}

	private func groupSingleImm(
		_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64,
		_ mnemonic: String, width: Int, byteForm: Bool
	) -> DecodedInstruction {
		let size: OperandSize = byteForm ? .byte : Self.operandSize(prefixes)
		guard let modrm = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let immStart = opcodeEnd + modrm.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: width) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let operands = "$0x" + String(imm, radix: 16) + ", " + modrm.rmText
		return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: modrm.ripDisp)
	}

	private func imulImm(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64, width: Int) -> DecodedInstruction {
		let size = Self.operandSize(prefixes)
		guard let m = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let immStart = opcodeEnd + m.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: width) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let operands = "$0x" + String(imm, radix: 16) + ", " + m.rmText + ", " + Self.reg(m.reg, size)
		return finalize(code, start, immStart + n, address, "imul", operands, ripDisp: m.ripDisp)
	}

	private func stringOp(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64, _ base: String, byteForm: Bool) -> DecodedInstruction {
		let suffix = byteForm ? "b" : (prefixes.rexW ? "q" : (prefixes.operandSize ? "w" : "l"))
		let rep = prefixes.rep ? "rep " : (prefixes.repne ? "repne " : "")
		return emit(code, start, opcodeEnd, address, rep + base + suffix, "")
	}

	private func portIOImm(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ address: UInt64, _ mnemonic: String, accumulator: String, output: Bool) -> DecodedInstruction {
		guard let (port, n) = Self.readImmediate(code, at: opcodeEnd, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		let portText = "$0x" + String(port, radix: 16)
		let operands = output ? accumulator + ", " + portText : portText + ", " + accumulator
		return emit(code, start, opcodeEnd + n, address, mnemonic, operands)
	}

	private func xchgAccumulator(_ opcode: UInt8, _ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		let size = Self.operandSize(prefixes)
		let other = Self.reg(Int(opcode & 0x7) | (prefixes.rexB ? 8 : 0), size)
		let accumulator = Self.reg(0, size)
		return emit(code, start, opcodeEnd, address, "xchg", other + ", " + accumulator)
	}

	private func movabsMoffs(_ opcode: UInt8, _ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		guard let (absolute, n) = Self.readImmediate(code, at: opcodeEnd, width: 8) else {
			return raw(code, at: start, address: address, comment: "Truncated moffs")
		}
		let addressText = Self.formatSignedHex(bitPattern: absolute)
		let accumulatorByte = Self.reg(0, .byte, hasREX: prefixes.hasREX)
		let accumulatorFull = Self.reg(0, Self.operandSize(prefixes))
		let operands: String
		switch opcode {
		case 0xA0: operands = addressText + ", " + accumulatorByte
		case 0xA1: operands = addressText + ", " + accumulatorFull
		case 0xA2: operands = accumulatorByte + ", " + addressText
		default:   operands = accumulatorFull + ", " + addressText
		}
		return emit(code, start, opcodeEnd + n, address, "movabs", operands)
	}

	/// shld/shrd r/m, reg, (imm8 | %cl) — AT&T renders the count first: `$imm, %reg, r/m`.
	private func shiftDouble(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64, _ mnemonic: String, byCL: Bool) -> DecodedInstruction {
		let size = Self.operandSize(prefixes)
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let reg = Self.reg(m.reg, size)
		if byCL {
			return finalize(code, start, after + m.length, address, mnemonic, "%cl, " + reg + ", " + m.rmText, ripDisp: m.ripDisp)
		}
		let immStart = after + m.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		return finalize(code, start, immStart + n, address, mnemonic, "$0x" + String(imm, radix: 16) + ", " + reg + ", " + m.rmText, ripDisp: m.ripDisp)
	}

	/// 0x0F 0xBA: bit-test group with imm8 — reg field selects bt/bts/btr/btc.
	private func bitGroupImm(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		let size = Self.operandSize(prefixes)
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let opIndex = (Int(code[after]) >> 3) & 0x7
		let names = ["", "", "", "", "bt", "bts", "btr", "btc"]
		let immStart = after + m.length
		guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
			return raw(code, at: start, address: address, comment: "Truncated immediate")
		}
		return finalize(code, start, immStart + n, address, opIndex >= 4 ? names[opIndex] : "(bt?)", "$0x" + String(imm, radix: 16) + ", " + m.rmText, ripDisp: m.ripDisp)
	}

	private func group3(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64, byteForm: Bool) -> DecodedInstruction {
		let size: OperandSize = byteForm ? .byte : Self.operandSize(prefixes)
		guard let modrm = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let opIndex = (Int(code[opcodeEnd]) >> 3) & 0x7
		let names = ["test", "test", "not", "neg", "mul", "imul", "div", "idiv"]
		if opIndex <= 1 { // test r/m, imm
			let width = byteForm ? 1 : (prefixes.operandSize ? 2 : 4)
			let immStart = opcodeEnd + modrm.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: width) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			return finalize(code, start, immStart + n, address, "test", "$0x" + String(imm, radix: 16) + ", " + modrm.rmText, ripDisp: modrm.ripDisp)
		}
		return finalize(code, start, opcodeEnd + modrm.length, address, names[opIndex], modrm.rmText, ripDisp: modrm.ripDisp)
	}

	private func group5(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64, byteForm: Bool) -> DecodedInstruction {
		guard opcodeEnd < code.count else { return raw(code, at: start, address: address, comment: "Truncated ModRM") }
		let opIndexPeek = (Int(code[opcodeEnd]) >> 3) & 0x7
		// call/jmp indirect and push operate on 64-bit operands.
		let size: OperandSize = (opIndexPeek >= 2 && !byteForm) ? .qword : (byteForm ? .byte : Self.operandSize(prefixes))
		guard let modrm = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let opIndex = (Int(code[opcodeEnd]) >> 3) & 0x7
		let names = ["inc", "dec", "call", "callf", "jmp", "jmpf", "push", "(bad)"]
		let indirect = opIndex == 2 || opIndex == 3 || opIndex == 4 || opIndex == 5
		let operands = (indirect ? "*" : "") + modrm.rmText
		return finalize(code, start, opcodeEnd + modrm.length, address, names[opIndex], operands, ripDisp: modrm.ripDisp)
	}

	private func segmentMov(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64, storeSegment: Bool) -> DecodedInstruction {
		guard opcodeEnd < code.count else { return raw(code, at: start, address: address, comment: "Truncated ModRM") }
		let segIndex = Int((code[opcodeEnd] >> 3) & 0x7)
		guard segIndex < Self.segmentNames.count else {
			return raw(code, at: start, address: address, comment: nil)
		}
		let gpSize: OperandSize = prefixes.rexW ? .qword : (prefixes.operandSize ? .word : .dword)
		guard let m = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: gpSize) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		let segment = "%" + Self.segmentNames[segIndex]
		let operands = storeSegment ? segment + ", " + m.rmText : m.rmText + ", " + segment
		return finalize(code, start, opcodeEnd + m.length, address, "mov", operands, ripDisp: m.ripDisp)
	}

	private func popRM(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction {
		guard opcodeEnd < code.count else { return raw(code, at: start, address: address, comment: "Truncated ModRM") }
		let opIndex = Int((code[opcodeEnd] >> 3) & 0x7)
		// pop r/m defaults to 64-bit in long mode; the 0x66 operand-size prefix selects the 16-bit form.
		let rmSize: OperandSize = prefixes.operandSize ? .word : .qword
		guard let m = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: rmSize) else {
			return raw(code, at: start, address: address, comment: "Truncated ModRM")
		}
		guard opIndex == 0 else {
			return finalize(code, start, opcodeEnd + m.length, address, "(bad)", m.rmText, ripDisp: m.ripDisp)
		}
		return finalize(code, start, opcodeEnd + m.length, address, "pop", m.rmText, ripDisp: m.ripDisp)
	}

	private func cmpxchg8b16b(_ code: [UInt8], _ start: Int, _ after: Int, _ prefixes: Prefixes, _ address: UInt64) -> DecodedInstruction? {
		guard after < code.count else { return nil }
		let opIndex = Int((code[after] >> 3) & 0x7)
		guard opIndex == 1,
			  let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword),
			  !m.isRegisterDirect else {
			return nil
		}
		return finalize(code, start, after + m.length, address, prefixes.rexW ? "cmpxchg16b" : "cmpxchg8b", m.rmText, ripDisp: m.ripDisp)
	}

	private func fence(_ code: [UInt8], _ start: Int, _ after: Int, _ address: UInt64) -> DecodedInstruction? {
		guard after < code.count else { return nil }
		let modrm = code[after]
		guard (modrm >> 6) == 0x3 else { return nil }
		switch (modrm >> 3) & 0x7 {
		case 5: return emit(code, start, after + 1, address, "lfence", "")
		case 6: return emit(code, start, after + 1, address, "mfence", "")
		case 7: return emit(code, start, after + 1, address, "sfence", "")
		default: return nil
		}
	}

	// MARK: - ModRM / SIB / displacement

	private func decodeModRM(_ code: [UInt8], at offset: Int, prefixes: Prefixes, rmSize: OperandSize, rmIsXMM: Bool = false, disp8Scale: Int = 1) -> ModRM? {
		guard offset < code.count else { return nil }
		let modrm = code[offset]
		let mod = Int(modrm >> 6)
		let regField = Int((modrm >> 3) & 0x7) | (prefixes.rexR ? 8 : 0)
		let rmField = Int(modrm & 0x7)
		var length = 1

		if mod == 3 {
			let rmReg = rmField | (prefixes.rexB ? 8 : 0)
			let rmText = rmIsXMM ? "%xmm" + String(rmReg) : Self.reg(rmReg, rmSize, hasREX: prefixes.hasREX)
			return ModRM(reg: regField, rmText: rmText, length: length, ripDisp: nil, isRegisterDirect: true)
		}

		if prefixes.addressSize {
			return decodeModRM32Address(code, at: offset, prefixes: prefixes, rmSize: rmSize, rmIsXMM: rmIsXMM, disp8Scale: disp8Scale)
		}

		var baseReg: Int?
		var indexReg: Int?
		var scale = 1
		var rip = false

		if rmField == 4 {
			guard offset + 1 < code.count else { return nil }
			let sib = code[offset + 1]
			length += 1
			scale = 1 << Int(sib >> 6)
			let indexField = Int((sib >> 3) & 0x7)
			if !(indexField == 4 && !prefixes.rexX) {
				indexReg = indexField | (prefixes.rexX ? 8 : 0)
			}
			let baseField = Int(sib & 0x7)
			if baseField == 5 && mod == 0 {
				baseReg = nil // [disp32 + index]
			} else {
				baseReg = baseField | (prefixes.rexB ? 8 : 0)
			}
		} else if rmField == 5 && mod == 0 {
			rip = true
		} else {
			baseReg = rmField | (prefixes.rexB ? 8 : 0)
		}

		var dispLen = 0
		if rip {
			dispLen = 4
		} else if mod == 1 {
			dispLen = 1
		} else if mod == 2 {
			dispLen = 4
		} else if mod == 0 && rmField == 4 && baseReg == nil {
			dispLen = 4
		}

		var disp: Int64 = 0
		if dispLen > 0 {
			guard offset + length + dispLen <= code.count else { return nil }
			var v: UInt64 = 0
			for i in 0..<dispLen { v |= UInt64(code[offset + length + i]) << (8 * i) }
			if dispLen == 1 {
				disp = Int64(Int8(bitPattern: UInt8(v & 0xff))) * Int64(disp8Scale)
			} else {
				disp = Int64(Int32(bitPattern: UInt32(v & 0xffff_ffff)))
			}
			length += dispLen
		}

		let segPrefix = prefixes.segment.map { "%" + $0 + ":" } ?? ""

		// Operand text follows LLVM's `X86ATTInstPrinter::printMemReference` so the rendering
		// byte-matches otool (verified against `clang -arch x86_64` + `otool -tvj` — the
		// NUMERIC form; `-V` invents a phantom `_sym(...)` on a zero-disp operand and lies here):
		//   • the displacement is emitted only when it is NON-ZERO, or when the address has
		//     neither a base nor an index register (a bare absolute). A zero displacement is
		//     otherwise suppressed — this covers the ABI-forced mod=01 disp8=0 on %rbp/%r13
		//     bases (mod=00 base=101 means RIP/disp32), an index-only [disp32==0], and a zero
		//     %rip displacement.
		//   • the SIB scale is emitted only when it is not 1.
		// `ripDisp` is still carried unconditionally so `finalize` resolves the address comment
		// even when the `0x0` text is suppressed.
		if rip {
			let dispText = disp != 0 ? Self.formatDisp(disp) : ""
			return ModRM(reg: regField, rmText: segPrefix + dispText + "(%rip)", length: length, ripDisp: disp)
		}

		var inner = ""
		if let base = baseReg { inner += Self.reg(base, .qword) }
		if let index = indexReg {
			inner += "," + Self.reg(index, .qword)
			if scale != 1 { inner += "," + String(scale) }
		}
		let hasRegister = !inner.isEmpty
		let dispText = (disp != 0 || !hasRegister) ? Self.formatDisp(disp) : ""
		let rmText = hasRegister ? dispText + "(" + inner + ")" : (dispText.isEmpty ? "0x0" : dispText)
		return ModRM(reg: regField, rmText: segPrefix + rmText, length: length, ripDisp: nil)
	}

	private func decodeModRM32Address(_ code: [UInt8], at offset: Int, prefixes: Prefixes, rmSize: OperandSize, rmIsXMM: Bool, disp8Scale: Int) -> ModRM? {
		guard offset < code.count else { return nil }
		let modrm = code[offset]
		let mod = Int(modrm >> 6)
		let regField = Int((modrm >> 3) & 0x7) | (prefixes.rexR ? 8 : 0)
		let rmField = Int(modrm & 0x7)
		var length = 1

		if mod == 3 {
			let rmReg = rmField | (prefixes.rexB ? 8 : 0)
			let rmText = rmIsXMM ? "%xmm" + String(rmReg) : Self.reg(rmReg, rmSize, hasREX: prefixes.hasREX)
			return ModRM(reg: regField, rmText: rmText, length: length, ripDisp: nil, isRegisterDirect: true)
		}

		var baseReg: Int?
		var indexReg: Int?
		var scale = 1
		var eip = false   // mod=00,rm=101 (no SIB) is EIP-relative in long mode, NOT absolute.

		if rmField == 4 {
			guard offset + 1 < code.count else { return nil }
			let sib = code[offset + 1]
			length += 1
			scale = 1 << Int(sib >> 6)
			let indexField = Int((sib >> 3) & 0x7)
			if !(indexField == 4 && !prefixes.rexX) {
				indexReg = indexField | (prefixes.rexX ? 8 : 0)
			}
			let baseField = Int(sib & 0x7)
			if baseField == 5 && mod == 0 {
				baseReg = nil   // SIB no-base: a true absolute [disp32].
			} else {
				baseReg = baseField | (prefixes.rexB ? 8 : 0)
			}
		} else if rmField == 5 && mod == 0 {
			baseReg = nil
			eip = true
		} else {
			baseReg = rmField | (prefixes.rexB ? 8 : 0)
		}

		var dispLen = 0
		if mod == 1 {
			dispLen = 1
		} else if mod == 2 || (mod == 0 && baseReg == nil) {
			dispLen = 4
		}

		var disp: Int64 = 0
		if dispLen > 0 {
			guard offset + length + dispLen <= code.count else { return nil }
			var v: UInt64 = 0
			for i in 0..<dispLen { v |= UInt64(code[offset + length + i]) << (8 * i) }
			if dispLen == 1 {
				disp = Int64(Int8(bitPattern: UInt8(v & 0xff))) * Int64(disp8Scale)
			} else {
				disp = Int64(Int32(bitPattern: UInt32(v & 0xffff_ffff)))
			}
			length += dispLen
		}

		let segPrefix = prefixes.segment.map { "%" + $0 + ":" } ?? ""
		if eip {
			// EIP-relative: mirror the 64-bit %rip path (suppress a zero disp, carry ripDisp for the comment).
			let dispText = disp != 0 ? Self.formatDisp(disp) : ""
			return ModRM(reg: regField, rmText: segPrefix + dispText + "(%eip)", length: length, ripDisp: disp)
		}
		var inner = ""
		if let base = baseReg { inner += Self.reg(base, .dword) }
		if let index = indexReg {
			inner += "," + Self.reg(index, .dword)
			if scale != 1 { inner += "," + String(scale) }
		}
		let hasRegister = !inner.isEmpty
		let dispText = (disp != 0 || !hasRegister) ? Self.formatDisp(disp) : ""
		let rmText = hasRegister ? dispText + "(" + inner + ")" : (dispText.isEmpty ? "0x0" : dispText)
		return ModRM(reg: regField, rmText: segPrefix + rmText, length: length, ripDisp: nil)
	}

	// MARK: - Emit helpers

	private func emit(_ code: [UInt8], _ start: Int, _ end: Int, _ address: UInt64, _ mnemonic: String, _ operands: String) -> DecodedInstruction {
		DecodedInstruction(address: address, bytes: slice(code, start, end), mnemonic: mnemonic, operands: operands, branchTarget: nil, comment: nil)
	}

	private func finalize(_ code: [UInt8], _ start: Int, _ end: Int, _ address: UInt64, _ mnemonic: String, _ operands: String, ripDisp: Int64?) -> DecodedInstruction {
		var comment: String?
		if let disp = ripDisp {
			let target = address &+ UInt64(end - start) &+ UInt64(bitPattern: disp)
			comment = "0x" + String(target, radix: 16)
		}
		return DecodedInstruction(address: address, bytes: slice(code, start, end), mnemonic: mnemonic, operands: operands, branchTarget: nil, comment: comment)
	}

	private func relative(_ code: [UInt8], _ start: Int, _ opcodeEnd: Int, _ address: UInt64, _ mnemonic: String, width: Int) -> DecodedInstruction {
		guard opcodeEnd + width <= code.count else {
			return raw(code, at: start, address: address, comment: "Truncated relative")
		}
		var v: UInt64 = 0
		for i in 0..<width { v |= UInt64(code[opcodeEnd + i]) << (8 * i) }
		let rel: Int64 = width == 1
			? Int64(Int8(bitPattern: UInt8(v & 0xff)))
			: Int64(Int32(bitPattern: UInt32(v & 0xffff_ffff)))
		let end = opcodeEnd + width
		let target = address &+ UInt64(end - start) &+ UInt64(bitPattern: rel)
		return DecodedInstruction(address: address, bytes: slice(code, start, end), mnemonic: mnemonic, operands: "0x" + String(target, radix: 16), branchTarget: target, comment: nil)
	}

	private func raw(_ code: [UInt8], at start: Int, address: UInt64, comment: String?) -> DecodedInstruction {
		DecodedInstruction(address: address, bytes: [code[start]], mnemonic: ".byte", operands: String(format: "0x%02x", code[start]), branchTarget: nil, comment: comment)
	}

	private func slice(_ code: [UInt8], _ start: Int, _ end: Int) -> [UInt8] {
		Array(code[start..<min(max(start, end), code.count)])
	}

	// MARK: - New helper decoders

	/// Decodes control (CR) and debug (DR) register moves. Returns nil if the ModRM form is unsupported.
	private func decodeControlDebug(_ op2: UInt8, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64) -> DecodedInstruction? {
		// op2 0x20/0x22 for control, 0x21/0x23 for debug. The ModRM `mod` field is
		// ARCHITECTURALLY IGNORED for these moves: the r/m operand is ALWAYS a register and
		// there is NO SIB/displacement, so the encoding is exactly opcode + one ModRM byte.
		// Using the general (mod-honoring) decodeModRM here would read a phantom
		// displacement/SIB whenever the byte carries mod != 11 (e.g. over data/padding in the
		// linear sweep), over-read by 1–4 bytes, and DESYNC the whole downstream listing.
		guard after < code.count else { return nil }
		let modrm = code[after]
		let debug = (op2 == 0x21 || op2 == 0x23)
		let destIsControl = (op2 == 0x22 || op2 == 0x23) // direction: to control/debug register
		let rmReg = Int(modrm & 0x7) | (prefixes.rexB ? 8 : 0)        // GPR operand (REX.B extends)
		let regIndex = Int((modrm >> 3) & 0x7) | (prefixes.rexR ? 8 : 0) // CR/DR number (REX.R extends to cr8/dr8)
		let names = debug ? Self.debugRegNames : Self.controlRegNames
		let regName = regIndex < names.count ? names[regIndex] : (debug ? "dr" + String(regIndex) : "cr" + String(regIndex))
		let gpr = Self.reg(rmReg, .qword)
		let end = after + 1 // opcode + one ModRM byte, never a displacement
		if destIsControl {
			// source is general register, dest is control/debug register
			return emit(code, start, end, address, "mov", gpr + ", %" + regName)
		} else {
			// source is control/debug register, dest is general register
			return emit(code, start, end, address, "mov", "%" + regName + ", " + gpr)
		}
	}

	/// Decodes the 0x0F 0x01 escape group (sgdt/sidt/lgdt/lidt/smsw/lmsw/invlpg/xgetbv/xsetbv/swapgs/rdtscp).
	private func decode0F01(_ code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64) -> DecodedInstruction? {
		guard after < code.count else { return nil }
		let next = code[after]
		// Single-byte forms (no ModRM)
		if next == 0xD0 { return emit(code, start, after + 1, address, "xgetbv", "") }
		if next == 0xD1 { return emit(code, start, after + 1, address, "xsetbv", "") }
		if next == 0xF8 { return emit(code, start, after + 1, address, "swapgs", "") }
		if next == 0xF9 { return emit(code, start, after + 1, address, "rdtscp", "") }
		// ModRM-based forms
		guard let m = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .qword) else { return nil }
		// The ModRM `reg` field is a pure 3-bit group-opcode extension here; REX.R must NOT
		// extend it (the CPU/otool ignore REX.R for 0F 01 dispatch). Extending it would push a
		// legal REX.R-prefixed encoding to selector 8–15, match no case, and fall through to a
		// 1-byte `.byte` — desyncing the sweep.
		let regSel = Int(code[after] >> 3) & 0x7
		let end = after + m.length
		switch regSel {
		case 0: // sgdt
			return finalize(code, start, end, address, "sgdt", m.rmText, ripDisp: m.ripDisp)
		case 1: // sidt
			return finalize(code, start, end, address, "sidt", m.rmText, ripDisp: m.ripDisp)
		case 2: // lgdt
			return finalize(code, start, end, address, "lgdt", m.rmText, ripDisp: m.ripDisp)
		case 3: // lidt
			return finalize(code, start, end, address, "lidt", m.rmText, ripDisp: m.ripDisp)
		case 4: // smsw: the MEMORY form is r/m16, but the REGISTER-DIRECT form (mod=11) follows
			// the operand size (smsw %eax / %rax / %ax), so only force .word for the memory form.
			let smswSize: OperandSize = ((code[after] >> 6) & 0x3) == 0x3 ? Self.operandSize(prefixes) : .word
			guard let mm = decodeModRM(code, at: after, prefixes: prefixes, rmSize: smswSize) else { return nil }
			return finalize(code, start, after + mm.length, address, "smsw", mm.rmText, ripDisp: mm.ripDisp)
		case 6: // lmsw r/m16
			guard let mm = decodeModRM(code, at: after, prefixes: prefixes, rmSize: .word) else { return nil }
			return finalize(code, start, after + mm.length, address, "lmsw", mm.rmText, ripDisp: mm.ripDisp)
		case 7: // invlpg
			return finalize(code, start, end, address, "invlpg", m.rmText, ripDisp: m.ripDisp)
		default:
			return nil
		}
	}

	/// Decodes bswap opcode 0xC8–0xCF (with possible REX.W).
	private func decodeBSWAP(_ op2: UInt8, code: [UInt8], start: Int, after: Int, prefixes: Prefixes, address: UInt64) -> DecodedInstruction {
		let base = Int(op2) - 0xC8
		let regIndex = base | (prefixes.rexB ? 8 : 0)
		let size: OperandSize = prefixes.rexW ? .qword : .dword
		let reg = Self.reg(regIndex, size)
		return emit(code, start, after, address, "bswap", reg)
	}

	// MARK: - EVEX / x87 decoders

	/// Decodes EVEX (AVX-512) 4-byte prefix instructions (leading byte 0x62). The
	/// three payload bytes (P0, P1, P2) are parsed to extract inverted R/X/B/R′
	/// bits, the mandatory prefix pp, the vector length L′L, the W bit, the
	/// 5-bit vvvvv register field (v′|vvvv), the opmask register aaa, the
	/// zeroing flag z and the broadcast bit. Only otool-verified AVX-512 forms
	/// are rendered here; other opcodes fall back to a length-correct placeholder.
	/// The byte LENGTH is always driven by the encoding structure (3 payload bytes
	/// + opcode + ModRM/SIB/disp [+imm8]) so the linear sweep stays byte-synchronized
	/// even where the mnemonic is generic.
	private func decodeEVEX(
		_ opcode: UInt8, code: [UInt8], start: Int, opcodeEnd: Int,
		prefixes: Prefixes, address: UInt64
	) -> DecodedInstruction {
		var cursor = opcodeEnd
		// Need three payload bytes (P0, P1, P2) after 0x62.
		guard cursor + 2 < code.count else {
			return raw(code, at: start, address: address, comment: "Truncated EVEX")
		}
		let p0 = code[cursor]
		let p1 = code[cursor + 1]
		let p2 = code[cursor + 2]
		cursor += 3
		// Map selection from P0 low bits; 0 is reserved.
		let map = Int(p0 & 0x03)
		guard map != 0 else {
			return raw(code, at: start, address: address, comment: "Invalid EVEX map")
		}
		// Initialize new prefix state; EVEX supersedes legacy prefixes.
		var pfx = Prefixes()
		pfx.hasREX = true
		// Inverted R/X/B bits from P0.
		pfx.rexR = (p0 & 0x80) == 0
		pfx.rexX = (p0 & 0x40) == 0
		pfx.rexB = (p0 & 0x20) == 0
		// R′ bit (bit4) extends the destination register by +16 when clear.
		let rPrime = (p0 & 0x10) == 0
		// P1: bit7 is W, bits6–3 encode inverted vvvv, bit2 must be 1,
		// bits1–0 are the mandatory prefix selector (pp).
		pfx.rexW = (p1 & 0x80) != 0
		let p1VLow = Int((p1 >> 3) & 0x0F) ^ 0x0F
		let p1Bit2 = (p1 & 0x04) != 0
		if !p1Bit2 {
			return raw(code, at: start, address: address, comment: "Invalid EVEX P1")
		}
		let pp = Int(p1 & 0x03)
		switch pp {
		case 1: pfx.operandSize = true      // 66 prefix
		case 2: pfx.rep = true              // F3 prefix
		case 3: pfx.repne = true            // F2 prefix
		default: break
		}
		// P2: bit7 = z (zeroing mask), bits6–5 = L′L (00=128,01=256,10=512),
		// bit4 = broadcast/embedded-rounding, bit3 = inverted V′, bits2–0 = aaa (opmask).
		let z = (p2 & 0x80) != 0
		let LL = Int((p2 >> 5) & 0x03)
		let broadcast = (p2 & 0x10) != 0
		let vPrime = (p2 & 0x08) == 0
		let aaa = Int(p2 & 0x07)
		// Combine V′ and vvvv to form vvvvv (0–31).
		var vvvvv = p1VLow
		if vPrime { vvvvv |= 0x10 }
		// Fetch the opcode following the EVEX prefix.
		guard cursor < code.count else {
			return raw(code, at: start, address: address, comment: "Truncated EVEX opcode")
		}
		let op = code[cursor]
		let after = cursor + 1
		// Determine the mandatory prefix enum for opcode dispatch.
		let mp = mandatoryPrefix(pfx)
		// Helper to choose among four variants based on mandatory prefix (none, 66, F3, F2).
		func pick(_ n: String?, _ p66: String?, _ f3: String?, _ f2: String?) -> String? {
			switch mp {
			case .none: return n
			case .p66: return p66
			case .f3:  return f3
			case .f2:  return f2
			}
		}
		// Render a vector register name given an index and scalar flag. Scalar forms always use XMM.
		func vec(_ index: Int, scalar: Bool = false, embeddedRounding: Bool = false) -> String {
			if scalar { return "%xmm" + String(index) }
			if embeddedRounding { return "%zmm" + String(index) }
			switch LL {
			case 1: return "%ymm" + String(index)
			case 2: return "%zmm" + String(index)
			default: return "%xmm" + String(index)
			}
		}
		func vec(_ index: Int, bytes: Int) -> String {
			if bytes > 32 { return "%zmm" + String(index) }
			if bytes > 16 { return "%ymm" + String(index) }
			return "%xmm" + String(index)
		}
		func vectorBytes(scalar: Bool = false, elementBytes: Int = 4) -> Int {
			if scalar { return elementBytes }
			switch LL {
			case 1: return 32
			case 2: return 64
			default: return 16
			}
		}
		func maskSuffix(includeZero: Bool = true) -> String {
			var s = ""
			if aaa != 0 { s = "{%k" + String(aaa) + "}" }
			if includeZero && z { s += (s.isEmpty ? "" : " ") + "{z}" }
			return s
		}
		func appendMask(_ operand: String, includeZero: Bool = true) -> String {
			let suffix = maskSuffix(includeZero: includeZero)
			return suffix.isEmpty ? operand : operand + " " + suffix
		}
		func evexTupleScale(scalar: Bool = false, elementBytes: Int = 4, allowBroadcast: Bool = true) -> Int {
			if scalar { return elementBytes }
			if broadcast && allowBroadcast && elementBytes >= 4 { return elementBytes }
			return vectorBytes(elementBytes: elementBytes)
		}
		func broadcastText(elementBytes: Int) -> String {
			"{1to" + String(max(1, vectorBytes(elementBytes: elementBytes) / elementBytes)) + "}"
		}
		func evexRounding(_ m: ModRM, saeOnly: Bool) -> String? {
			guard broadcast && m.isRegisterDirect else { return nil }
			if saeOnly { return "{sae}" }
			switch LL {
			case 0: return "{rn-sae}"
			case 1: return "{rd-sae}"
			case 2: return "{ru-sae}"
			default: return "{rz-sae}"
			}
		}
		// Placeholder to consume ModRM (and optional imm8) and produce a length-correct generic instruction.
		func evexPlaceholder(_ mnemonic: String, hasImm8: Bool = false) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			var end = after + m.length
			if hasImm8 {
				guard let (_, n) = Self.readImmediate(code, at: end, width: 1) else {
					return raw(code, at: start, address: address, comment: "Truncated immediate")
				}
				end += n
			}
			// Even in placeholder form, adjust the destination register index for R′.
			let destIndex = m.reg + (rPrime ? 16 : 0)
			let dest = appendMask(vec(destIndex, scalar: false))
			let operands = m.rmText + ", " + dest
			return finalize(code, start, end, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexRMOperand(_ m: ModRM, scalar: Bool = false, elementBytes: Int = 4, allowBroadcast: Bool = true, embeddedRounding: Bool = false) -> String? {
			if m.isRegisterDirect {
				if broadcast && !embeddedRounding { return nil }
				let low = Int(code[after] & 0x07)
				let index = low + (pfx.rexB ? 8 : 0) + (pfx.rexX ? 16 : 0)
				return vec(index, scalar: scalar, embeddedRounding: embeddedRounding)
			}
			if broadcast {
				guard allowBroadcast && !scalar && elementBytes >= 4 else { return nil }
				return m.rmText + broadcastText(elementBytes: elementBytes)
			}
			return m.rmText
		}
		// Common 3-operand reg/reg/mem handler. Computes dest from ModRM.reg plus
		// R′, uses vvvvv as the second source, and appends mask/zeroing to the dest.
		func evexRegRM(_ mnemonic: String, scalar: Bool = false, elementBytes: Int = 4, allowBroadcast: Bool = true, saeOnly: Bool? = nil, placeholder: String = "(evex)") -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(scalar: scalar, elementBytes: elementBytes, allowBroadcast: allowBroadcast)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let rounding = saeOnly.flatMap { evexRounding(m, saeOnly: $0) }
			let embeddedRounding = rounding != nil
			guard let rm = evexRMOperand(m, scalar: scalar, elementBytes: elementBytes, allowBroadcast: allowBroadcast, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder(placeholder)
			}
			let destIndex = m.reg + (rPrime ? 16 : 0)
			let dest = appendMask(vec(destIndex, scalar: scalar, embeddedRounding: embeddedRounding))
			let operands = [rounding, rm, vec(vvvvv, scalar: scalar, embeddedRounding: embeddedRounding), dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexMove(_ mnemonic: String, store: Bool, elementBytes: Int = 4, placeholder: String = "(evex)") -> DecodedInstruction {
			if broadcast || (store && z) { return evexPlaceholder(placeholder) }
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: false)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: false) else {
				return evexPlaceholder(placeholder)
			}
			let reg = vec(m.reg + (rPrime ? 16 : 0))
			let operands: String
			if store {
				operands = reg + ", " + appendMask(rm, includeZero: false)
			} else {
				operands = rm + ", " + appendMask(reg)
			}
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexExpandCompress(_ mnemonic: String, elementBytes: Int, store: Bool) -> DecodedInstruction {
			if broadcast { return evexPlaceholder("(evex38)") }
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: elementBytes) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			// compress can zero-mask a REGISTER destination ({z} valid); compress to MEMORY with {z} is illegal.
			if store && z && !m.isRegisterDirect { return evexPlaceholder("(evex38)") }
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: false) else {
				return evexPlaceholder("(evex38)")
			}
			let reg = vec(m.reg + (rPrime ? 16 : 0))
			let operands = store ? reg + ", " + appendMask(rm, includeZero: m.isRegisterDirect) : rm + ", " + appendMask(reg)
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexImmRegRM(_ mnemonic: String, scalar: Bool = false, elementBytes: Int = 4, allowBroadcast: Bool = true, saeOnly: Bool? = nil, placeholder: String = "(evex3a)") -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(scalar: scalar, elementBytes: elementBytes, allowBroadcast: allowBroadcast)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let rounding = saeOnly.flatMap { evexRounding(m, saeOnly: $0) }
			let embeddedRounding = rounding != nil
			guard let rm = evexRMOperand(m, scalar: scalar, elementBytes: elementBytes, allowBroadcast: allowBroadcast, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder(placeholder, hasImm8: true)
			}
			let destIndex = m.reg + (rPrime ? 16 : 0)
			let dest = appendMask(vec(destIndex, scalar: scalar, embeddedRounding: embeddedRounding))
			let operands = ["$0x" + String(imm, radix: 16), rounding, rm, vec(vvvvv, scalar: scalar, embeddedRounding: embeddedRounding), dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexMaskRegRM(_ mnemonic: String, elementBytes: Int = 4, allowBroadcast: Bool = true, placeholder: String = "(evex)") -> DecodedInstruction {
			if z { return evexPlaceholder(placeholder) }
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: allowBroadcast)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: allowBroadcast) else {
				return evexPlaceholder(placeholder)
			}
			let dest = appendMask("%k" + String(m.reg & 0x7), includeZero: false)
			let operands = rm + ", " + vec(vvvvv) + ", " + dest
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexVP2Intersect(_ mnemonic: String, elementBytes: Int) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: true)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: true) else {
				return evexPlaceholder("(evex38)")
			}
			let dest = "%k" + String(m.reg & 0x7)
			let operands = rm + ", " + vec(vvvvv) + ", " + dest
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func comparePredicate(_ imm: UInt64, suffix: String) -> String? {
			let names = [
				"eq", "lt", "le", "unord", "neq", "nlt", "nle", "ord",
				"eq_uq", "nge", "ngt", "false", "neq_oq", "ge", "gt", "true",
				"eq_os", "lt_oq", "le_oq", "unord_s", "neq_us", "nlt_uq", "nle_uq", "ord_s",
				"eq_us", "nge_uq", "ngt_uq", "false_os", "neq_os", "ge_oq", "gt_oq", "true_us",
			]
			guard imm < UInt64(names.count) else { return nil }
			return "vcmp" + names[Int(imm)] + suffix
		}
		func vpcmpPredicate(_ imm: UInt64) -> String? {
			switch imm {
			case 0: return "eq"
			case 1: return "lt"
			case 2: return "le"
			case 4: return "neq"
			case 5: return "nlt"
			case 6: return "nle"
			default: return nil
			}
		}
		func evexCompareImm(_ suffix: String, elementBytes: Int, scalar: Bool = false, saeOnly: Bool = true) -> DecodedInstruction {
			if z { return evexPlaceholder("(evex)", hasImm8: true) }
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(scalar: scalar, elementBytes: elementBytes, allowBroadcast: true)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let rounding = evexRounding(m, saeOnly: saeOnly)
			let embeddedRounding = rounding != nil
			guard let mnemonic = comparePredicate(imm, suffix: suffix),
				  let rm = evexRMOperand(m, scalar: scalar, elementBytes: elementBytes, allowBroadcast: true, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder("(evex)", hasImm8: true)
			}
			let dest = appendMask("%k" + String(m.reg & 0x7), includeZero: false)
			let operands = [rounding, rm, vec(vvvvv, scalar: scalar, embeddedRounding: embeddedRounding), dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexVPCmp(unsigned: Bool, size: String, elementBytes: Int) -> DecodedInstruction {
			if z { return evexPlaceholder("(evex3a)", hasImm8: true) }
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: true)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: true) else {
				return evexPlaceholder("(evex3a)", hasImm8: true)
			}
			let unsignedMarker = unsigned ? "u" : ""
			let dest = appendMask("%k" + String(m.reg & 0x7), includeZero: false)
			if let predicate = vpcmpPredicate(imm) {
				let mnemonic = "vpcmp" + predicate + unsignedMarker + size
				return finalize(code, start, immStart + n, address, mnemonic, rm + ", " + vec(vvvvv) + ", " + dest, ripDisp: m.ripDisp)
			}
			let mnemonic = "vpcmp" + unsignedMarker + size
			let operands = "$0x" + String(imm, radix: 16) + ", " + rm + ", " + vec(vvvvv) + ", " + dest
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		// Two-operand unary `rm, dest` (reg = dest, rm = source): converts, sqrt, abs.
		func evexUnary(_ mnemonic: String, elementBytes: Int = 4, allowBroadcast: Bool = true, saeOnly: Bool? = nil, placeholder: String = "(evex)") -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: allowBroadcast)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let rounding = saeOnly.flatMap { evexRounding(m, saeOnly: $0) }
			let embeddedRounding = rounding != nil
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: allowBroadcast, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder(placeholder)
			}
			let destIndex = m.reg + (rPrime ? 16 : 0)
			let dest = appendMask(vec(destIndex, embeddedRounding: embeddedRounding))
			let operands = [rounding, rm, dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		// Scalar float-to-GPR converts: r/m is the xmm/mem source, ModRM.reg is the
		// GPR destination. W selects only the GPR width; F3/F2 select ss/sd.
		func evexScalarCvtToGPR(_ mnemonic: String, elementBytes: Int, saeOnly: Bool) -> DecodedInstruction {
			if aaa != 0 || z { return evexPlaceholder("(evex)") }
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: elementBytes) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let rounding = evexRounding(m, saeOnly: saeOnly)
			let embeddedRounding = rounding != nil
			guard let source = evexRMOperand(m, scalar: true, elementBytes: elementBytes, allowBroadcast: false, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder("(evex)")
			}
			let dest = Self.reg(m.reg, pfx.rexW ? .qword : .dword)
			let operands = [rounding, source, dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexWiden(_ mnemonic: String, ratio: Int, saeOnly: Bool? = nil, placeholder: String = "(evex)") -> DecodedInstruction {
			if broadcast && saeOnly == nil { return evexPlaceholder(placeholder) }
			let destVectorBytes = vectorBytes()
			// The only SAE-aware widening converts currently routed here are ps -> uqq:
			// memory b-bit forms are 32-bit scalar broadcasts, while register b-bit forms are ER/SAE.
			let sourceElementBytes = 4
			let disp8Scale = broadcast ? sourceElementBytes : destVectorBytes / ratio
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: disp8Scale) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let rounding = saeOnly.flatMap { evexRounding(m, saeOnly: $0) }
			let embeddedRounding = rounding != nil
			let destBytes = embeddedRounding ? 64 : destVectorBytes
			let sourceBytes = destBytes / ratio
			let source: String
			if m.isRegisterDirect {
				let low = Int(code[after] & 0x07)
				let index = low + (pfx.rexB ? 8 : 0) + (pfx.rexX ? 16 : 0)
				source = vec(index, bytes: sourceBytes)
			} else if broadcast {
				let destElementBytes = sourceElementBytes * ratio
				let count = max(1, destBytes / destElementBytes)
				source = m.rmText + "{1to" + String(count) + "}"
			} else {
				source = m.rmText
			}
			let dest = appendMask(vec(m.reg + (rPrime ? 16 : 0), bytes: destBytes))
			let operands = [rounding, source, dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, after + m.length, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		// Imm8 two-operand unary `$imm, rm, dest` (no vvvvv operand): vpshufd, vpermq/vpermpd.
		func evexUnaryImm(_ mnemonic: String, elementBytes: Int = 4, allowBroadcast: Bool = true, saeOnly: Bool? = nil, placeholder: String = "(evex)") -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: allowBroadcast)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let immStart = after + m.length
			guard let (imm, n) = Self.readImmediate(code, at: immStart, width: 1) else {
				return raw(code, at: start, address: address, comment: "Truncated immediate")
			}
			let rounding = saeOnly.flatMap { evexRounding(m, saeOnly: $0) }
			let embeddedRounding = rounding != nil
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: allowBroadcast, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder(placeholder, hasImm8: true)
			}
			let destIndex = m.reg + (rPrime ? 16 : 0)
			let dest = appendMask(vec(destIndex, embeddedRounding: embeddedRounding))
			let operands = ["$0x" + String(imm, radix: 16), rounding, rm, dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, immStart + n, address, mnemonic, operands, ripDisp: m.ripDisp)
		}
		func evexNarrow(_ mnemonic: String, elementBytes: Int = 8, allowBroadcast: Bool = true, saeOnly: Bool? = nil, placeholder: String = "(evex)") -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: evexTupleScale(elementBytes: elementBytes, allowBroadcast: allowBroadcast)) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let rounding = saeOnly.flatMap { evexRounding(m, saeOnly: $0) }
			let embeddedRounding = rounding != nil
			guard let rm = evexRMOperand(m, elementBytes: elementBytes, allowBroadcast: allowBroadcast, embeddedRounding: embeddedRounding) else {
				return evexPlaceholder(placeholder)
			}
			let sourceBytes = embeddedRounding ? 64 : vectorBytes(elementBytes: elementBytes)
			let destIndex = m.reg + (rPrime ? 16 : 0)
			let dest = appendMask(vec(destIndex, bytes: max(16, sourceBytes / 2)))
			// A narrowing convert with a 128/256-bit source leaves an xmm dest (ambiguous), so a
			// plain MEMORY source needs an x/y operand-size suffix — matching the VEX forms. The
			// 512-bit source (ymm dest) and broadcast forms ({1toN} disambiguates) take no suffix.
			var mnem = mnemonic
			if !m.isRegisterDirect && !rm.contains("{1to") {
				if sourceBytes == 16 { mnem += "x" }
				else if sourceBytes == 32 { mnem += "y" }
			}
			let operands = [rounding, rm, dest].compactMap { $0 }.joined(separator: ", ")
			return finalize(code, start, after + m.length, address, mnem, operands, ripDisp: m.ripDisp)
		}
		// Broadcast instruction `src, dest`: a scalar element (or a 128/256-bit sub-vector)
		// splatted across the destination. disp8 uses the Tuple1Scalar / Tuple2/4/8 scale
		// (NOT the full-vector Full-tuple scale), passed explicitly per opcode. The register
		// source is always XMM (a scalar element); sub-vector forms are memory-only.
		func evexBroadcast(_ mnemonic: String, scale: Int, memoryOnly: Bool, placeholder: String) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true, disp8Scale: scale) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let src: String
			if m.isRegisterDirect {
				if memoryOnly { return evexPlaceholder(placeholder) }
				let low = Int(code[after] & 0x07)
				let index = low + (pfx.rexB ? 8 : 0) + (pfx.rexX ? 16 : 0)
				src = "%xmm" + String(index)
			} else {
				src = m.rmText
			}
			let dest = appendMask(vec(m.reg + (rPrime ? 16 : 0)))
			return finalize(code, start, after + m.length, address, mnemonic, src + ", " + dest, ripDisp: m.ripDisp)
		}
		// Broadcast from a general-purpose register: `%eax`/`%rax`, dest is a full vector.
		func evexBroadcastGPR(_ mnemonic: String, is64: Bool) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: is64 ? .qword : .dword, rmIsXMM: false, disp8Scale: is64 ? 8 : 4) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let dest = appendMask(vec(m.reg + (rPrime ? 16 : 0)))
			return finalize(code, start, after + m.length, address, mnemonic, m.rmText + ", " + dest, ripDisp: m.ripDisp)
		}
		// Broadcast from a mask register: `%k1, %zmm0` (register-only; source is ModRM.rm as a k-reg).
		func evexBroadcastMask(_ mnemonic: String, placeholder: String) -> DecodedInstruction {
			guard let m = decodeModRM(code, at: after, prefixes: pfx, rmSize: .qword, rmIsXMM: true) else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			guard m.isRegisterDirect else { return evexPlaceholder(placeholder) }
			let kSource = "%k" + String(Int(code[after] & 0x07))
			let dest = appendMask(vec(m.reg + (rPrime ? 16 : 0)))
			return finalize(code, start, after + m.length, address, mnemonic, kSource + ", " + dest, ripDisp: m.ripDisp)
		}
		func evexVSIB(_ mnemonic: String, dataElementBytes: Int, indexElementBytes: Int, scatter: Bool) -> DecodedInstruction {
			guard after < code.count else {
				return raw(code, at: start, address: address, comment: "Truncated ModRM")
			}
			let modrm = code[after]
			let mod = Int(modrm >> 6)
			let rmField = Int(modrm & 0x7)
			guard mod != 3, rmField == 4 else {
				return evexPlaceholder("(evex38)")
			}
			guard after + 1 < code.count else {
				return raw(code, at: start, address: address, comment: "Truncated SIB")
			}

			let sib = code[after + 1]
			let scale = 1 << Int(sib >> 6)
			let indexField = Int((sib >> 3) & 0x7)
			let indexReg = indexField | (pfx.rexX ? 8 : 0) | (vPrime ? 16 : 0)
			let baseField = Int(sib & 0x7)
			let baseReg = (baseField == 5 && mod == 0) ? nil : baseField | (pfx.rexB ? 8 : 0)
			var length = 2

			let dispLen: Int
			if mod == 1 {
				dispLen = 1
			} else if mod == 2 || (mod == 0 && baseReg == nil) {
				dispLen = 4
			} else {
				dispLen = 0
			}

			var disp: Int64 = 0
			if dispLen > 0 {
				guard after + length + dispLen <= code.count else {
					return raw(code, at: start, address: address, comment: "Truncated displacement")
				}
				var value: UInt64 = 0
				for i in 0..<dispLen { value |= UInt64(code[after + length + i]) << (8 * i) }
				if dispLen == 1 {
					disp = Int64(Int8(bitPattern: UInt8(value & 0xff))) * Int64(dataElementBytes)
				} else {
					disp = Int64(Int32(bitPattern: UInt32(value & 0xffff_ffff)))
				}
				length += dispLen
			}

			let fullVectorBytes = vectorBytes(elementBytes: dataElementBytes)
			let elementCount = max(1, fullVectorBytes / max(dataElementBytes, indexElementBytes))
			let dataBytes = elementCount * dataElementBytes
			let indexBytes = elementCount * indexElementBytes
			let vectorReg = vec(Int((modrm >> 3) & 0x7) | (pfx.rexR ? 8 : 0) | (rPrime ? 16 : 0), bytes: dataBytes)
			let index = vec(indexReg, bytes: indexBytes)

			var inner = ""
			if let base = baseReg { inner += Self.reg(base, .qword) }
			inner += "," + index
			if scale != 1 { inner += "," + String(scale) }
			let dispText = disp != 0 ? Self.formatDisp(disp) : ""
			let memory = dispText + "(" + inner + ")"
			let mask = " {%k" + String(aaa) + "}"
			let operands = scatter ? vectorReg + ", " + memory + mask : memory + ", " + vectorReg + mask
			return finalize(code, start, after + length, address, mnemonic, operands, ripDisp: nil)
		}
		// Dispatch on the EVEX map (mm field).
		switch map {
		case 1:
			// Map1 (0x0F) opcodes. Render only otool-verified AVX-512 forms; placeholders keep length.
			switch op {
			case 0x10:
				if let name = pick("vmovups", "vmovupd", nil, nil) {
					return evexMove(name, store: false, elementBytes: mp == .p66 ? 8 : 4)
				}
			case 0x11:
				if let name = pick("vmovups", "vmovupd", nil, nil) {
					return evexMove(name, store: true, elementBytes: mp == .p66 ? 8 : 4)
				}
			case 0x28:
				if let name = pick("vmovaps", "vmovapd", nil, nil) {
					return evexMove(name, store: false, elementBytes: mp == .p66 ? 8 : 4)
				}
			case 0x29:
				if let name = pick("vmovaps", "vmovapd", nil, nil) {
					return evexMove(name, store: true, elementBytes: mp == .p66 ? 8 : 4)
				}
			case 0x2C:
				if mp == .f3 { return evexScalarCvtToGPR("vcvttss2si", elementBytes: 4, saeOnly: true) }
				if mp == .f2 { return evexScalarCvtToGPR("vcvttsd2si", elementBytes: 8, saeOnly: true) }
			case 0x2D:
				if mp == .f3 { return evexScalarCvtToGPR("vcvtss2si", elementBytes: 4, saeOnly: false) }
				if mp == .f2 { return evexScalarCvtToGPR("vcvtsd2si", elementBytes: 8, saeOnly: false) }
			case 0x51:
				if let name = pick("vsqrtps", "vsqrtpd", nil, nil) {
					return evexUnary(name, elementBytes: mp == .p66 ? 8 : 4, saeOnly: false)
				}
			case 0x58:
				if let name = pick("vaddps", "vaddpd", "vaddss", "vaddsd") {
					let scalar = (mp == .f3 || mp == .f2)
					let elementBytes = (mp == .p66 || mp == .f2) ? 8 : 4
					return evexRegRM(name, scalar: scalar, elementBytes: elementBytes, saeOnly: false)
				}
			case 0x59:
				if let name = pick("vmulps", "vmulpd", nil, nil) {
					return evexRegRM(name, elementBytes: mp == .p66 ? 8 : 4, saeOnly: false)
				}
			case 0x5A:
				if mp == .none && !pfx.rexW { return evexWiden("vcvtps2pd", ratio: 2) }
				if mp == .p66 && pfx.rexW { return evexNarrow("vcvtpd2ps", elementBytes: 8, saeOnly: false) }
				if let name = pick(nil, nil, "vcvtss2sd", "vcvtsd2ss") {
					return evexRegRM(name, scalar: true, elementBytes: mp == .f2 ? 8 : 4, saeOnly: false)
				}
			case 0x5B:
				// none = vcvtdq2ps, 66 = vcvtps2dq, F3 = vcvttps2dq (all Full tuple, 32-bit elements).
				if mp == .none && pfx.rexW { return evexNarrow("vcvtqq2ps", elementBytes: 8, saeOnly: false) }
				if mp == .none && !pfx.rexW { return evexUnary("vcvtdq2ps", elementBytes: 4, saeOnly: false) }
				if mp == .p66 && !pfx.rexW { return evexUnary("vcvtps2dq", elementBytes: 4, saeOnly: false) }
				if mp == .f3 && !pfx.rexW { return evexUnary("vcvttps2dq", elementBytes: 4, saeOnly: true) }
			case 0x5C:
				if let name = pick("vsubps", "vsubpd", nil, nil) {
					return evexRegRM(name, elementBytes: mp == .p66 ? 8 : 4, saeOnly: false)
				}
			case 0x5D:
				if let name = pick("vminps", "vminpd", nil, nil) {
					return evexRegRM(name, elementBytes: mp == .p66 ? 8 : 4, saeOnly: true)
				}
			case 0x5E:
				if let name = pick("vdivps", "vdivpd", nil, nil) {
					return evexRegRM(name, elementBytes: mp == .p66 ? 8 : 4, saeOnly: false)
				}
			case 0x5F:
				if let name = pick("vmaxps", "vmaxpd", nil, nil) {
					return evexRegRM(name, elementBytes: mp == .p66 ? 8 : 4, saeOnly: true)
				}
			case 0x64:
				if mp == .p66 && !pfx.rexW { return evexMaskRegRM("vpcmpgtb", elementBytes: 1) }
			case 0x65:
				if mp == .p66 && !pfx.rexW { return evexMaskRegRM("vpcmpgtw", elementBytes: 2) }
			case 0x66:
				if mp == .p66 && !pfx.rexW { return evexMaskRegRM("vpcmpgtd", elementBytes: 4) }
			case 0x6C:
				if mp == .p66 && pfx.rexW { return evexRegRM("vpunpcklqdq", elementBytes: 8) }
			case 0x6D:
				if mp == .p66 && pfx.rexW { return evexRegRM("vpunpckhqdq", elementBytes: 8) }
			case 0x6F:
				if mp == .p66 { return evexMove(pfx.rexW ? "vmovdqa64" : "vmovdqa32", store: false, elementBytes: pfx.rexW ? 8 : 4) }
				if mp == .f3 { return evexMove(pfx.rexW ? "vmovdqu64" : "vmovdqu32", store: false, elementBytes: pfx.rexW ? 8 : 4) }
				if mp == .f2 { return evexMove(pfx.rexW ? "vmovdqu16" : "vmovdqu8", store: false, elementBytes: pfx.rexW ? 2 : 1) }
			case 0x70:
				if mp == .p66 && !pfx.rexW { return evexUnaryImm("vpshufd", elementBytes: 4) }
			case 0x74:
				if mp == .p66 && !pfx.rexW { return evexMaskRegRM("vpcmpeqb", elementBytes: 1) }
			case 0x75:
				if mp == .p66 && !pfx.rexW { return evexMaskRegRM("vpcmpeqw", elementBytes: 2) }
			case 0x76:
				if mp == .p66 && !pfx.rexW { return evexMaskRegRM("vpcmpeqd", elementBytes: 4) }
			case 0x78:
				if mp == .none && pfx.rexW { return evexNarrow("vcvttpd2udq", elementBytes: 8, saeOnly: true) }
				if mp == .none && !pfx.rexW { return evexUnary("vcvttps2udq", elementBytes: 4, saeOnly: true) }
				if mp == .p66 && pfx.rexW { return evexUnary("vcvttpd2uqq", elementBytes: 8, saeOnly: true) }
				if mp == .p66 && !pfx.rexW { return evexWiden("vcvttps2uqq", ratio: 2, saeOnly: true) }
				if mp == .f3 { return evexScalarCvtToGPR("vcvttss2usi", elementBytes: 4, saeOnly: true) }
				if mp == .f2 { return evexScalarCvtToGPR("vcvttsd2usi", elementBytes: 8, saeOnly: true) }
			case 0x79:
				if mp == .none && pfx.rexW { return evexNarrow("vcvtpd2udq", elementBytes: 8, saeOnly: false) }
				if mp == .none && !pfx.rexW { return evexUnary("vcvtps2udq", elementBytes: 4, saeOnly: false) }
				if mp == .p66 && pfx.rexW { return evexUnary("vcvtpd2uqq", elementBytes: 8, saeOnly: false) }
				if mp == .p66 && !pfx.rexW { return evexWiden("vcvtps2uqq", ratio: 2, saeOnly: false) }
				if mp == .f3 { return evexScalarCvtToGPR("vcvtss2usi", elementBytes: 4, saeOnly: false) }
				if mp == .f2 { return evexScalarCvtToGPR("vcvtsd2usi", elementBytes: 8, saeOnly: false) }
			case 0x7A:
				if mp == .f3 && pfx.rexW { return evexUnary("vcvtuqq2pd", elementBytes: 8, saeOnly: false) }
				if mp == .f3 && !pfx.rexW { return evexWiden("vcvtudq2pd", ratio: 2) }
				if mp == .f2 && pfx.rexW { return evexNarrow("vcvtuqq2ps", elementBytes: 8, saeOnly: false) }
				if mp == .f2 && !pfx.rexW { return evexUnary("vcvtudq2ps", elementBytes: 4, saeOnly: false) }
			case 0x7F:
				if mp == .p66 { return evexMove(pfx.rexW ? "vmovdqa64" : "vmovdqa32", store: true, elementBytes: pfx.rexW ? 8 : 4) }
				if mp == .f3 { return evexMove(pfx.rexW ? "vmovdqu64" : "vmovdqu32", store: true, elementBytes: pfx.rexW ? 8 : 4) }
				if mp == .f2 { return evexMove(pfx.rexW ? "vmovdqu16" : "vmovdqu8", store: true, elementBytes: pfx.rexW ? 2 : 1) }
			case 0xC2:
				if mp == .none { return evexCompareImm("ps", elementBytes: 4, saeOnly: true) }
				if mp == .p66 { return evexCompareImm("pd", elementBytes: 8, saeOnly: true) }
				if mp == .f3 { return evexCompareImm("ss", elementBytes: 4, scalar: true, saeOnly: true) }
				if mp == .f2 { return evexCompareImm("sd", elementBytes: 8, scalar: true, saeOnly: true) }
				return evexPlaceholder("(evex)", hasImm8: true)
			case 0xC6:
				// none = vshufps (32-bit), 66 = vshufpd (64-bit); imm8 selects the lanes.
				if let name = pick("vshufps", "vshufpd", nil, nil) {
					return evexImmRegRM(name, elementBytes: mp == .p66 ? 8 : 4)
				}
				return evexPlaceholder("(evex)", hasImm8: true)
			case 0xD4:
				if mp == .p66 && pfx.rexW { return evexRegRM("vpaddq", elementBytes: 8) }
			case 0xDB:
				if mp == .p66 { return evexRegRM(pfx.rexW ? "vpandq" : "vpandd", elementBytes: pfx.rexW ? 8 : 4) }
			case 0xDF:
				if mp == .p66 { return evexRegRM(pfx.rexW ? "vpandnq" : "vpandnd", elementBytes: pfx.rexW ? 8 : 4) }
			case 0xE6:
				if mp == .p66 && pfx.rexW { return evexNarrow("vcvttpd2dq", elementBytes: 8, saeOnly: true) }
				if mp == .f2 && pfx.rexW { return evexNarrow("vcvtpd2dq", elementBytes: 8, saeOnly: false) }
				if mp == .f3 && pfx.rexW { return evexUnary("vcvtqq2pd", elementBytes: 8, saeOnly: false) }
				if mp == .f3 && !pfx.rexW { return evexWiden("vcvtdq2pd", ratio: 2) }
			case 0xEB:
				if mp == .p66 { return evexRegRM(pfx.rexW ? "vporq" : "vpord", elementBytes: pfx.rexW ? 8 : 4) }
			case 0xEF:
				if mp == .p66 { return evexRegRM(pfx.rexW ? "vpxorq" : "vpxord", elementBytes: pfx.rexW ? 8 : 4) }
			case 0xF4:
				if mp == .p66 && pfx.rexW { return evexRegRM("vpmuludq", elementBytes: 8) }
			case 0xF8:
				if mp == .p66 && !pfx.rexW { return evexRegRM("vpsubb", elementBytes: 1, allowBroadcast: false) }
			case 0xF9:
				if mp == .p66 && !pfx.rexW { return evexRegRM("vpsubw", elementBytes: 2, allowBroadcast: false) }
			case 0xFA:
				if mp == .p66 && !pfx.rexW { return evexRegRM("vpsubd", elementBytes: 4) }
			case 0xFB:
				if mp == .p66 && pfx.rexW { return evexRegRM("vpsubq", elementBytes: 8) }
			case 0xFC:
				if mp == .p66 && !pfx.rexW { return evexRegRM("vpaddb", elementBytes: 1, allowBroadcast: false) }
			case 0xFD:
				if mp == .p66 && !pfx.rexW { return evexRegRM("vpaddw", elementBytes: 2, allowBroadcast: false) }
			case 0xFE:
				if mp == .p66 && !pfx.rexW { return evexRegRM("vpaddd", elementBytes: 4) }
			default:
				break
			}
			// Unknown map1 opcode: consume operands and return a placeholder.
			return evexPlaceholder("(evex)", hasImm8: [0x70, 0x71, 0x72, 0x73, 0xC2, 0xC6].contains(op))
		case 2:
			if mp == .p66 {
				// W selects d/q (32/64-bit element) for the parametric integer ops.
				let e = pfx.rexW ? 8 : 4
				switch op {
				// broadcasts (Tuple1Scalar element scale; sub-vector Tuple2/4/8 scale)
				case 0x18:
					return evexBroadcast("vbroadcastss", scale: 4, memoryOnly: false, placeholder: "(evex38)")
				case 0x19:
					// W1 = vbroadcastsd (1 double); W0 = vbroadcastf32x2 (2 floats, AVX-512DQ). Both Tuple2 scale 8.
					return evexBroadcast(pfx.rexW ? "vbroadcastsd" : "vbroadcastf32x2", scale: 8, memoryOnly: false, placeholder: "(evex38)")
				case 0x1A:
					return evexBroadcast(pfx.rexW ? "vbroadcastf64x2" : "vbroadcastf32x4", scale: 16, memoryOnly: true, placeholder: "(evex38)")
				case 0x1B:
					return evexBroadcast(pfx.rexW ? "vbroadcastf64x4" : "vbroadcastf32x8", scale: 32, memoryOnly: true, placeholder: "(evex38)")
				case 0x13:
					if !pfx.rexW { return evexWiden("vcvtph2ps", ratio: 2, placeholder: "(evex38)") }
				case 0x58:
					return evexBroadcast("vpbroadcastd", scale: 4, memoryOnly: false, placeholder: "(evex38)")
				case 0x59:
					// W1 = vpbroadcastq; W0 = vbroadcasti32x2 (AVX-512DQ). Both Tuple2 scale 8.
					return evexBroadcast(pfx.rexW ? "vpbroadcastq" : "vbroadcasti32x2", scale: 8, memoryOnly: false, placeholder: "(evex38)")
				case 0x5A:
					return evexBroadcast(pfx.rexW ? "vbroadcasti64x2" : "vbroadcasti32x4", scale: 16, memoryOnly: true, placeholder: "(evex38)")
				case 0x5B:
					return evexBroadcast(pfx.rexW ? "vbroadcasti64x4" : "vbroadcasti32x8", scale: 32, memoryOnly: true, placeholder: "(evex38)")
				case 0x78:
					return evexBroadcast("vpbroadcastb", scale: 1, memoryOnly: false, placeholder: "(evex38)")
				case 0x79:
					return evexBroadcast("vpbroadcastw", scale: 2, memoryOnly: false, placeholder: "(evex38)")
				case 0x7A:
					return evexBroadcastGPR("vpbroadcastb", is64: false)
				case 0x7B:
					return evexBroadcastGPR("vpbroadcastw", is64: false)
				case 0x7C:
					return evexBroadcastGPR(pfx.rexW ? "vpbroadcastq" : "vpbroadcastd", is64: pfx.rexW)
				case 0x00:
					return evexRegRM("vpshufb", elementBytes: 1, allowBroadcast: false, placeholder: "(evex38)")
				case 0x16:
					return evexRegRM(pfx.rexW ? "vpermpd" : "vpermps", elementBytes: e, placeholder: "(evex38)")
				case 0x1C:
					return evexUnary("vpabsb", elementBytes: 1, allowBroadcast: false, placeholder: "(evex38)")
				case 0x1E:
					return evexUnary("vpabsd", elementBytes: 4, placeholder: "(evex38)")
				case 0x1F:
					return evexUnary("vpabsq", elementBytes: 8, placeholder: "(evex38)")
				case 0x20:
					return evexWiden("vpmovsxbw", ratio: 2, placeholder: "(evex38)")
				case 0x21:
					return evexWiden("vpmovsxbd", ratio: 4, placeholder: "(evex38)")
				case 0x22:
					return evexWiden("vpmovsxbq", ratio: 8, placeholder: "(evex38)")
				case 0x23:
					return evexWiden("vpmovsxwd", ratio: 2, placeholder: "(evex38)")
				case 0x24:
					return evexWiden("vpmovsxwq", ratio: 4, placeholder: "(evex38)")
				case 0x25:
					return evexWiden("vpmovsxdq", ratio: 2, placeholder: "(evex38)")
				case 0x27:
					return evexMaskRegRM(pfx.rexW ? "vptestmq" : "vptestmd", elementBytes: e, placeholder: "(evex38)")
				case 0x28:
					if pfx.rexW { return evexRegRM("vpmuldq", elementBytes: 8, placeholder: "(evex38)") }
				case 0x2C:
					return evexRegRM(pfx.rexW ? "vscalefpd" : "vscalefps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x29:
					if pfx.rexW { return evexMaskRegRM("vpcmpeqq", elementBytes: 8, placeholder: "(evex38)") }
				case 0x30:
					return evexWiden("vpmovzxbw", ratio: 2, placeholder: "(evex38)")
				case 0x31:
					return evexWiden("vpmovzxbd", ratio: 4, placeholder: "(evex38)")
				case 0x32:
					return evexWiden("vpmovzxbq", ratio: 8, placeholder: "(evex38)")
				case 0x33:
					return evexWiden("vpmovzxwd", ratio: 2, placeholder: "(evex38)")
				case 0x34:
					return evexWiden("vpmovzxwq", ratio: 4, placeholder: "(evex38)")
				case 0x35:
					return evexWiden("vpmovzxdq", ratio: 2, placeholder: "(evex38)")
				case 0x37:
					if pfx.rexW { return evexMaskRegRM("vpcmpgtq", elementBytes: 8, placeholder: "(evex38)") }
				case 0x36:
					return evexRegRM(pfx.rexW ? "vpermq" : "vpermd", elementBytes: e, placeholder: "(evex38)")
				case 0x39:
					return evexRegRM(pfx.rexW ? "vpminsq" : "vpminsd", elementBytes: e, placeholder: "(evex38)")
				case 0x3B:
					return evexRegRM(pfx.rexW ? "vpminuq" : "vpminud", elementBytes: e, placeholder: "(evex38)")
				case 0x3D:
					return evexRegRM(pfx.rexW ? "vpmaxsq" : "vpmaxsd", elementBytes: e, placeholder: "(evex38)")
				case 0x3F:
					return evexRegRM(pfx.rexW ? "vpmaxuq" : "vpmaxud", elementBytes: e, placeholder: "(evex38)")
				case 0x42:
					return evexUnary(pfx.rexW ? "vgetexppd" : "vgetexpps", elementBytes: e, saeOnly: true, placeholder: "(evex38)")
				case 0x43:
					return evexRegRM(pfx.rexW ? "vgetexpsd" : "vgetexpss", scalar: true, elementBytes: e, saeOnly: true, placeholder: "(evex38)")
				case 0x44:
					return evexUnary(pfx.rexW ? "vplzcntq" : "vplzcntd", elementBytes: e, placeholder: "(evex38)")
				case 0x45:
					return evexRegRM(pfx.rexW ? "vpsrlvq" : "vpsrlvd", elementBytes: e, placeholder: "(evex38)")
				case 0x46:
					return evexRegRM(pfx.rexW ? "vpsravq" : "vpsravd", elementBytes: e, placeholder: "(evex38)")
				case 0x47:
					return evexRegRM(pfx.rexW ? "vpsllvq" : "vpsllvd", elementBytes: e, placeholder: "(evex38)")
				case 0x4C:
					return evexUnary(pfx.rexW ? "vrcp14pd" : "vrcp14ps", elementBytes: e, placeholder: "(evex38)")
				case 0x4D:
					return evexRegRM(pfx.rexW ? "vrcp14sd" : "vrcp14ss", scalar: true, elementBytes: e, placeholder: "(evex38)")
				case 0x4E:
					return evexUnary(pfx.rexW ? "vrsqrt14pd" : "vrsqrt14ps", elementBytes: e, placeholder: "(evex38)")
				case 0x4F:
					return evexRegRM(pfx.rexW ? "vrsqrt14sd" : "vrsqrt14ss", scalar: true, elementBytes: e, placeholder: "(evex38)")
				case 0x54:
					return evexUnary(pfx.rexW ? "vpopcntw" : "vpopcntb", elementBytes: pfx.rexW ? 2 : 1, allowBroadcast: false, placeholder: "(evex38)")
				case 0x55:
					return evexUnary(pfx.rexW ? "vpopcntq" : "vpopcntd", elementBytes: e, placeholder: "(evex38)")
				case 0x64:
					return evexRegRM(pfx.rexW ? "vpblendmq" : "vpblendmd", elementBytes: e, placeholder: "(evex38)")
				case 0x70:
					if pfx.rexW { return evexRegRM("vpshldvw", elementBytes: 2, allowBroadcast: false, placeholder: "(evex38)") }
				case 0x71:
					return evexRegRM(pfx.rexW ? "vpshldvq" : "vpshldvd", elementBytes: e, placeholder: "(evex38)")
				case 0x72:
					if pfx.rexW { return evexRegRM("vpshrdvw", elementBytes: 2, allowBroadcast: false, placeholder: "(evex38)") }
				case 0x73:
					return evexRegRM(pfx.rexW ? "vpshrdvq" : "vpshrdvd", elementBytes: e, placeholder: "(evex38)")
				case 0x75:
					return evexRegRM(pfx.rexW ? "vpermi2w" : "vpermi2b", elementBytes: pfx.rexW ? 2 : 1, allowBroadcast: false, placeholder: "(evex38)")
				case 0x76:
					return evexRegRM(pfx.rexW ? "vpermi2q" : "vpermi2d", elementBytes: e, allowBroadcast: true, placeholder: "(evex38)")
				case 0x77:
					return evexRegRM(pfx.rexW ? "vpermi2pd" : "vpermi2ps", elementBytes: e, allowBroadcast: true, placeholder: "(evex38)")
				case 0x7D:
					return evexRegRM(pfx.rexW ? "vpermt2w" : "vpermt2b", elementBytes: pfx.rexW ? 2 : 1, allowBroadcast: false, placeholder: "(evex38)")
				case 0x7E:
					return evexRegRM(pfx.rexW ? "vpermt2q" : "vpermt2d", elementBytes: e, allowBroadcast: true, placeholder: "(evex38)")
				case 0x7F:
					return evexRegRM(pfx.rexW ? "vpermt2pd" : "vpermt2ps", elementBytes: e, allowBroadcast: true, placeholder: "(evex38)")
				case 0x83:
					if pfx.rexW { return evexRegRM("vpmultishiftqb", elementBytes: 8, placeholder: "(evex38)") }
				case 0x88:
					return evexExpandCompress(pfx.rexW ? "vexpandpd" : "vexpandps", elementBytes: e, store: false)
				case 0x89:
					return evexExpandCompress(pfx.rexW ? "vpexpandq" : "vpexpandd", elementBytes: e, store: false)
				case 0x8A:
					return evexExpandCompress(pfx.rexW ? "vcompresspd" : "vcompressps", elementBytes: e, store: true)
				case 0x8B:
					return evexExpandCompress(pfx.rexW ? "vpcompressq" : "vpcompressd", elementBytes: e, store: true)
				case 0x8D:
					if !pfx.rexW { return evexRegRM("vpermb", elementBytes: 1, allowBroadcast: false, placeholder: "(evex38)") }
				case 0x90:
					return evexVSIB(pfx.rexW ? "vpgatherdq" : "vpgatherdd", dataElementBytes: e, indexElementBytes: 4, scatter: false)
				case 0x91:
					return evexVSIB(pfx.rexW ? "vpgatherqq" : "vpgatherqd", dataElementBytes: e, indexElementBytes: 8, scatter: false)
				case 0x92:
					return evexVSIB(pfx.rexW ? "vgatherdpd" : "vgatherdps", dataElementBytes: e, indexElementBytes: 4, scatter: false)
				case 0x93:
					return evexVSIB(pfx.rexW ? "vgatherqpd" : "vgatherqps", dataElementBytes: e, indexElementBytes: 8, scatter: false)
				case 0xA0:
					return evexVSIB(pfx.rexW ? "vpscatterdq" : "vpscatterdd", dataElementBytes: e, indexElementBytes: 4, scatter: true)
				case 0xA1:
					return evexVSIB(pfx.rexW ? "vpscatterqq" : "vpscatterqd", dataElementBytes: e, indexElementBytes: 8, scatter: true)
				case 0xA2:
					return evexVSIB(pfx.rexW ? "vscatterdpd" : "vscatterdps", dataElementBytes: e, indexElementBytes: 4, scatter: true)
				case 0xA3:
					return evexVSIB(pfx.rexW ? "vscatterqpd" : "vscatterqps", dataElementBytes: e, indexElementBytes: 8, scatter: true)
				case 0x40:
					if let name = Self.evex38[op] {
						return evexRegRM(pfx.rexW ? "vpmullq" : name, elementBytes: pfx.rexW ? 8 : 4, placeholder: "(evex38)")
					}
				case 0x96:
					return evexRegRM(pfx.rexW ? "vfmaddsub132pd" : "vfmaddsub132ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x97:
					return evexRegRM(pfx.rexW ? "vfmsubadd132pd" : "vfmsubadd132ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x98:
					return evexRegRM(pfx.rexW ? "vfmadd132pd" : "vfmadd132ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x99:
					return evexRegRM(pfx.rexW ? "vfmadd132sd" : "vfmadd132ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x9A:
					return evexRegRM(pfx.rexW ? "vfmsub132pd" : "vfmsub132ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x9B:
					return evexRegRM(pfx.rexW ? "vfmsub132sd" : "vfmsub132ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x9C:
					return evexRegRM(pfx.rexW ? "vfnmadd132pd" : "vfnmadd132ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x9D:
					return evexRegRM(pfx.rexW ? "vfnmadd132sd" : "vfnmadd132ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x9E:
					return evexRegRM(pfx.rexW ? "vfnmsub132pd" : "vfnmsub132ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0x9F:
					return evexRegRM(pfx.rexW ? "vfnmsub132sd" : "vfnmsub132ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xA6:
					return evexRegRM(pfx.rexW ? "vfmaddsub213pd" : "vfmaddsub213ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xA7:
					return evexRegRM(pfx.rexW ? "vfmsubadd213pd" : "vfmsubadd213ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xA8:
					return evexRegRM(pfx.rexW ? "vfmadd213pd" : "vfmadd213ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xA9:
					return evexRegRM(pfx.rexW ? "vfmadd213sd" : "vfmadd213ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xAA:
					return evexRegRM(pfx.rexW ? "vfmsub213pd" : "vfmsub213ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xAB:
					return evexRegRM(pfx.rexW ? "vfmsub213sd" : "vfmsub213ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xAC:
					return evexRegRM(pfx.rexW ? "vfnmadd213pd" : "vfnmadd213ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xAD:
					return evexRegRM(pfx.rexW ? "vfnmadd213sd" : "vfnmadd213ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xAE:
					return evexRegRM(pfx.rexW ? "vfnmsub213pd" : "vfnmsub213ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xAF:
					return evexRegRM(pfx.rexW ? "vfnmsub213sd" : "vfnmsub213ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xB4:
					if pfx.rexW { return evexRegRM("vpmadd52luq", elementBytes: 8, placeholder: "(evex38)") }
				case 0xB5:
					if pfx.rexW { return evexRegRM("vpmadd52huq", elementBytes: 8, placeholder: "(evex38)") }
				case 0xB6:
					return evexRegRM(pfx.rexW ? "vfmaddsub231pd" : "vfmaddsub231ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xB7:
					return evexRegRM(pfx.rexW ? "vfmsubadd231pd" : "vfmsubadd231ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xB8:
					return evexRegRM(pfx.rexW ? "vfmadd231pd" : "vfmadd231ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xB9:
					return evexRegRM(pfx.rexW ? "vfmadd231sd" : "vfmadd231ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xBA:
					return evexRegRM(pfx.rexW ? "vfmsub231pd" : "vfmsub231ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xBB:
					return evexRegRM(pfx.rexW ? "vfmsub231sd" : "vfmsub231ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xBC:
					return evexRegRM(pfx.rexW ? "vfnmadd231pd" : "vfnmadd231ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xBD:
					return evexRegRM(pfx.rexW ? "vfnmadd231sd" : "vfnmadd231ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xBE:
					return evexRegRM(pfx.rexW ? "vfnmsub231pd" : "vfnmsub231ps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xBF:
					return evexRegRM(pfx.rexW ? "vfnmsub231sd" : "vfnmsub231ss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: false, placeholder: "(evex38)")
				case 0xC4:
					return evexUnary(pfx.rexW ? "vpconflictq" : "vpconflictd", elementBytes: e, placeholder: "(evex38)")
				case 0xCF:
					if !pfx.rexW { return evexRegRM("vgf2p8mulb", elementBytes: 1, allowBroadcast: false, placeholder: "(evex38)") }
				default:
					break
				}
			}
			if mp == .f2 {
				switch op {
				case 0x68:
					return evexVP2Intersect(pfx.rexW ? "vp2intersectq" : "vp2intersectd", elementBytes: pfx.rexW ? 8 : 4)
				default:
					break
				}
			}
			if mp == .f3 {
				// mask-register-source broadcasts (avx512cd): src is ModRM.rm as a k-reg.
				switch op {
				case 0x2A:
					return evexBroadcastMask("vpbroadcastmb2q", placeholder: "(evex38)")
				case 0x3A:
					return evexBroadcastMask("vpbroadcastmw2d", placeholder: "(evex38)")
				default:
					break
				}
			}
			return evexPlaceholder("(evex38)", hasImm8: false)
		case 3:
			if mp == .p66 {
				switch op {
				case 0x08:
					return evexUnaryImm("vrndscaleps", elementBytes: 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x09:
					return evexUnaryImm("vrndscalepd", elementBytes: 8, saeOnly: true, placeholder: "(evex3a)")
				case 0x0A:
					return evexImmRegRM("vrndscaless", scalar: true, elementBytes: 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x0B:
					return evexImmRegRM("vrndscalesd", scalar: true, elementBytes: 8, saeOnly: true, placeholder: "(evex3a)")
				case 0x1E:
					return evexVPCmp(unsigned: true, size: pfx.rexW ? "q" : "d", elementBytes: pfx.rexW ? 8 : 4)
				case 0x1F:
					return evexVPCmp(unsigned: false, size: pfx.rexW ? "q" : "d", elementBytes: pfx.rexW ? 8 : 4)
				case 0x26:
					return evexUnaryImm(pfx.rexW ? "vgetmantpd" : "vgetmantps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x27:
					return evexImmRegRM(pfx.rexW ? "vgetmantsd" : "vgetmantss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x3E:
					return evexVPCmp(unsigned: true, size: pfx.rexW ? "w" : "b", elementBytes: pfx.rexW ? 2 : 1)
				case 0x3F:
					return evexVPCmp(unsigned: false, size: pfx.rexW ? "w" : "b", elementBytes: pfx.rexW ? 2 : 1)
				case 0x50:
					return evexImmRegRM(pfx.rexW ? "vrangepd" : "vrangeps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x51:
					return evexImmRegRM(pfx.rexW ? "vrangesd" : "vrangess", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x54:
					return evexImmRegRM(pfx.rexW ? "vfixupimmpd" : "vfixupimmps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x55:
					return evexImmRegRM(pfx.rexW ? "vfixupimmsd" : "vfixupimmss", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x56:
					return evexUnaryImm(pfx.rexW ? "vreducepd" : "vreduceps", elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x57:
					return evexImmRegRM(pfx.rexW ? "vreducesd" : "vreducess", scalar: true, elementBytes: pfx.rexW ? 8 : 4, saeOnly: true, placeholder: "(evex3a)")
				case 0x70:
					if pfx.rexW { return evexImmRegRM("vpshldw", elementBytes: 2, allowBroadcast: false, placeholder: "(evex3a)") }
				case 0x71:
					return evexImmRegRM(pfx.rexW ? "vpshldq" : "vpshldd", elementBytes: pfx.rexW ? 8 : 4, placeholder: "(evex3a)")
				case 0x72:
					if pfx.rexW { return evexImmRegRM("vpshrdw", elementBytes: 2, allowBroadcast: false, placeholder: "(evex3a)") }
				case 0x73:
					return evexImmRegRM(pfx.rexW ? "vpshrdq" : "vpshrdd", elementBytes: pfx.rexW ? 8 : 4, placeholder: "(evex3a)")
				case 0xCE:
					if pfx.rexW { return evexImmRegRM("vgf2p8affineqb", elementBytes: 8, placeholder: "(evex3a)") }
				case 0xCF:
					if pfx.rexW { return evexImmRegRM("vgf2p8affineinvqb", elementBytes: 8, placeholder: "(evex3a)") }
				default:
					break
				}
			}
			if mp == .p66, op == 0x00, pfx.rexW {
				return evexUnaryImm("vpermq", elementBytes: 8)
			}
			if mp == .p66, op == 0x25, let name = Self.evex3a[op] {
				return evexImmRegRM(pfx.rexW ? "vpternlogq" : name, elementBytes: pfx.rexW ? 8 : 4)
			}
			return evexPlaceholder("(evex3a)", hasImm8: true)
		default:
			return raw(code, at: start, address: address, comment: nil)
		}
	}

	/// Decodes x87 floating-point instructions for escape opcodes 0xD8–0xDF. For
	/// mod != 3 the memory form is handled via `decodeModRM` with an
	/// operand-size lookup; only a few common load instructions (flds/fldl/fildl/
	/// fildll) are explicitly mapped, the rest fall to a length-correct `(x87)`
	/// placeholder. For mod == 3 the register form uses the `x87RegReg` table to
	/// select the mnemonic and renders the operands as `%st, %st(i)` (source first
	/// in AT&T syntax). The instruction LENGTH (escape + ModRM [+SIB/disp]) is
	/// always correct so the linear sweep stays synchronized.
	private func decodeX87(
		_ opcode: UInt8, code: [UInt8], start: Int, opcodeEnd: Int,
		prefixes: Prefixes, address: UInt64
	) -> DecodedInstruction {
		// Must have a ModRM byte following the opcode.
		guard opcodeEnd < code.count else {
			return raw(code, at: start, address: address, comment: "Truncated x87")
		}
		let modrm = code[opcodeEnd]
		let mod = modrm >> 6
		let reg = Int((modrm >> 3) & 0x7)
		let rm = Int(modrm & 0x7)
		if mod != 3 {
			// Memory forms (mod != 3). Map a handful of common load instructions
			// (verified against clang/otool ground truth).
			func mem(_ mnem: String, _ size: OperandSize) -> DecodedInstruction {
				guard let m = decodeModRM(code, at: opcodeEnd, prefixes: prefixes, rmSize: size) else {
					return raw(code, at: start, address: address, comment: "Truncated ModRM")
				}
				return finalize(code, start, opcodeEnd + m.length, address, mnem, m.rmText, ripDisp: m.ripDisp)
			}
			switch (opcode, reg) {
			case (0xD9, 0): return mem("flds", .dword)    // FLD m32fp
			case (0xDD, 0): return mem("fldl", .qword)    // FLD m64fp
			case (0xDB, 0): return mem("fildl", .dword)   // FILD m32int
			case (0xDF, 2): return mem("fists", .word)    // FIST m16int
			case (0xDF, 5): return mem("fildll", .qword)  // FILD m64int
			default:
				// Unknown memory form: decode the operand to compute the length and emit a placeholder.
				return mem("(x87)", .qword)
			}
		} else {
			// Register forms (mod == 3). reg selects the sub-opcode.
			if let subTable = Self.x87RegReg[opcode], let mnem = subTable[reg] {
				// Operands are `%st, %st(i)` in AT&T syntax (source first).
				let operands = "%st, %st(" + String(rm) + ")"
				// Exactly two bytes: escape + ModRM.
				return emit(code, start, opcodeEnd + 1, address, mnem, operands)
			}
			// Unknown register form: emit a generic but consume both bytes.
			let operands = "%st(" + String(rm) + "), %st"
			return emit(code, start, opcodeEnd + 1, address, "(x87)", operands)
		}
	}

	/// Mapping of x87 register-form encodings (mod == 3) onto mnemonics. The
	/// outer key is the escape opcode (0xDE here), and each nested dictionary
	/// maps the ModRM.reg field (0–7) to an x87 mnemonic. Only the subset
	/// needed for faddp/fmulp/fsubp/fsubrp/fdivp/fdivrp is populated.
	private static let x87RegReg: [UInt8: [Int: String]] = [
		0xDE: [
			0: "faddp",  // de c0+i  faddp %st, %st(i)
			1: "fmulp",  // de c8+i  fmulp %st, %st(i)
			4: "fsubp",  // de e0+i  fsubp %st, %st(i)   (reg=4)
			5: "fsubrp", // de e8+i  fsubrp %st, %st(i)  (reg=5)
			6: "fdivrp", // de f0+i  fdivrp %st, %st(i)  (reg=6)
			7: "fdivp"   // de f8+i  fdivp %st, %st(i)   (reg=7)
		]
	]

	// MARK: - Tables / formatting

	private static func operandSize(_ prefixes: Prefixes) -> OperandSize {
		if prefixes.rexW { return .qword }
		if prefixes.operandSize { return .word }
		return .dword
	}

	private static func readImmediate(_ code: [UInt8], at offset: Int, width: Int) -> (UInt64, Int)? {
		guard offset + width <= code.count else { return nil }
		var v: UInt64 = 0
		for i in 0..<width { v |= UInt64(code[offset + i]) << (8 * i) }
		return (v, width)
	}

	private static func formatDisp(_ v: Int64) -> String {
		v < 0 ? "-0x" + String(-v, radix: 16) : "0x" + String(v, radix: 16)
	}

	private static func formatSignedHex(bitPattern bits: UInt64) -> String {
		let signed = Int64(bitPattern: bits)
		if signed < 0 {
			return "-0x" + String((~bits) &+ 1, radix: 16)
		}
		return "0x" + String(bits, radix: 16)
	}

	private static func sizeSuffix(_ size: OperandSize) -> String {
		switch size {
		case .byte: return "b"
		case .word: return "w"
		case .dword: return "l"
		case .qword: return "q"
		}
	}

	private static func prefixKey(_ prefix: MandatoryPrefix) -> Int {
		switch prefix {
		case .none: return 0
		case .p66: return 1
		case .f3: return 2
		case .f2: return 3
		}
	}

	private static func opcodePrefixKey(_ opcode: UInt8, _ prefix: MandatoryPrefix) -> Int {
		(Int(opcode) << 8) | prefixKey(prefix)
	}

	private static func reg(_ index: Int, _ size: OperandSize, hasREX: Bool = false) -> String {
		switch size {
		case .qword: return "%" + qwordNames[index]
		case .dword: return "%" + dwordNames[index]
		case .word: return "%" + wordNames[index]
		case .byte: return "%" + (hasREX ? byteREXNames[index] : byteLegacyNames[index])
		}
	}

	private static let qwordNames = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
	private static let dwordNames = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"]
	private static let wordNames = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"]
	private static let byteREXNames = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"]
	private static let byteLegacyNames = ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"]

	private static let aluNames = ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"]
	private static let shiftNames = ["rol", "ror", "rcl", "rcr", "shl", "shr", "shl", "sar"]
	private static let conditionSuffixes = ["o", "no", "b", "ae", "e", "ne", "be", "a", "s", "ns", "p", "np", "l", "ge", "le", "g"]
	private static let conditionMnemonics = ["jo", "jno", "jb", "jae", "je", "jne", "jbe", "ja", "js", "jns", "jp", "jnp", "jl", "jge", "jle", "jg"]
	private static let segmentNames = ["es", "cs", "ss", "ds", "fs", "gs"]

	private static let packed66: [UInt8: String] = [
		0x60: "punpcklbw", 0x61: "punpcklwd", 0x62: "punpckldq", 0x63: "packsswb",
		0x64: "pcmpgtb", 0x65: "pcmpgtw", 0x66: "pcmpgtd", 0x67: "packuswb",
		0x68: "punpckhbw", 0x69: "punpckhwd", 0x6A: "punpckhdq", 0x6B: "packssdw",
		0x6C: "punpcklqdq", 0x6D: "punpckhqdq",
		0xD1: "psrlw", 0xD2: "psrld", 0xD3: "psrlq", 0xD5: "pmullw",
		0xD8: "psubusb", 0xD9: "psubusw", 0xDA: "pminub", 0xDC: "paddusb", 0xDD: "paddusw", 0xDE: "pmaxub",
		0xE0: "pavgb", 0xE1: "psraw", 0xE2: "psrad", 0xE3: "pavgw", 0xE4: "pmulhuw", 0xE5: "pmulhw",
		0xE8: "psubsb", 0xE9: "psubsw", 0xEA: "pminsw", 0xEC: "paddsb", 0xED: "paddsw", 0xEE: "pmaxsw",
		0xF1: "psllw", 0xF2: "pslld", 0xF3: "psllq", 0xF4: "pmuludq", 0xF5: "pmaddwd", 0xF6: "psadbw",
	]

	private static let packedMMX: [UInt8: String] = [
		0x60: "punpcklbw", 0x61: "punpcklwd", 0x62: "punpckldq", 0x63: "packsswb",
		0x64: "pcmpgtb", 0x65: "pcmpgtw", 0x66: "pcmpgtd", 0x67: "packuswb",
		0x68: "punpckhbw", 0x69: "punpckhwd", 0x6A: "punpckhdq", 0x6B: "packssdw",
		0x74: "pcmpeqb", 0x75: "pcmpeqw", 0x76: "pcmpeqd",
		0xD1: "psrlw", 0xD2: "psrld", 0xD3: "psrlq", 0xD4: "paddq", 0xD5: "pmullw",
		0xD8: "psubusb", 0xD9: "psubusw", 0xDA: "pminub", 0xDB: "pand", 0xDC: "paddusb", 0xDD: "paddusw", 0xDE: "pmaxub", 0xDF: "pandn",
		0xE0: "pavgb", 0xE1: "psraw", 0xE2: "psrad", 0xE3: "pavgw", 0xE4: "pmulhuw", 0xE5: "pmulhw",
		0xE8: "psubsb", 0xE9: "psubsw", 0xEA: "pminsw", 0xEB: "por", 0xEC: "paddsb", 0xED: "paddsw", 0xEE: "pmaxsw", 0xEF: "pxor",
		0xF1: "psllw", 0xF2: "pslld", 0xF3: "psllq", 0xF4: "pmuludq", 0xF5: "pmaddwd", 0xF6: "psadbw",
		0xF8: "psubb", 0xF9: "psubw", 0xFA: "psubd", 0xFB: "psubq", 0xFC: "paddb", 0xFD: "paddw", 0xFE: "paddd",
	]

	private static let threeByte38: [UInt8: String] = [
		0x00: "pshufb", 0x0B: "pmulhrsw", 0x17: "ptest", 0x1C: "pabsb", 0x1D: "pabsw", 0x1E: "pabsd",
		0x20: "pmovsxbw", 0x21: "pmovsxbd", 0x22: "pmovsxbq", 0x23: "pmovsxwd", 0x24: "pmovsxwq", 0x25: "pmovsxdq",
		0x28: "pmuldq", 0x29: "pcmpeqq", 0x2B: "packusdw",
		0x30: "pmovzxbw", 0x31: "pmovzxbd", 0x32: "pmovzxbq", 0x33: "pmovzxwd", 0x34: "pmovzxwq", 0x35: "pmovzxdq",
		0x37: "pcmpgtq", 0x38: "pminsb", 0x39: "pminsd", 0x3A: "pminuw", 0x3B: "pminud",
		0x3C: "pmaxsb", 0x3D: "pmaxsd", 0x3E: "pmaxuw", 0x3F: "pmaxud", 0x40: "pmulld", 0x41: "phminposuw",
		0xCF: "gf2p8mulb",
		0xDB: "aesimc", 0xDC: "aesenc", 0xDD: "aesenclast", 0xDE: "aesdec", 0xDF: "aesdeclast",
	]
	private static let threeByte3A: [UInt8: String] = [
		0x08: "roundps", 0x09: "roundpd", 0x0A: "roundss", 0x0B: "roundsd", 0x0C: "blendps", 0x0D: "blendpd",
		0x0E: "pblendw", 0x0F: "palignr", 0x14: "pextrb", 0x15: "pextrw", 0x16: "pextrd", 0x17: "extractps",
		0x20: "pinsrb", 0x21: "insertps", 0x22: "pinsrd", 0x40: "dpps", 0x41: "dppd", 0x42: "mpsadbw", 0x44: "pclmulqdq",
		0xCE: "gf2p8affineqb", 0xCF: "gf2p8affineinvqb",
		0xDF: "aeskeygenassist",
	]

	private static let evex38: [UInt8: String] = [
		0x40: "vpmulld",
	]
	private static let evex3a: [UInt8: String] = [
		0x25: "vpternlogd",
	]
	private static let vex38: [UInt8: String] = [
		0x40: "vpmulld",
	]
	private static let vex3a: [UInt8: String] = [
		0x44: "vpclmulqdq",
	]
	private static let bmiMap2: [Int: String] = [
		0xF200: "andn",
		0xF500: "bzhi",
		0xF502: "pext",
		0xF503: "pdep",
		0xF603: "mulx",
		0xF700: "bextr",
		0xF701: "shlx",
		0xF702: "sarx",
		0xF703: "shrx",
	]
	private static let bmiMap3: [Int: String] = [
		0xF003: "rorx",
	]
	private static let bmiF3Map2: [Int: String] = [
		1: "blsr",
		2: "blsmsk",
		3: "blsi",
	]

	/// Control-register names for mov to/from control registers.
	private static let controlRegNames = [
		"cr0", "cr1", "cr2", "cr3", "cr4", "cr5", "cr6", "cr7",
		"cr8", "cr9", "cr10", "cr11", "cr12", "cr13", "cr14", "cr15"
	]
	/// Debug-register names for mov to/from debug registers.
	private static let debugRegNames = [
		"dr0", "dr1", "dr2", "dr3", "dr4", "dr5", "dr6", "dr7",
		"dr8", "dr9", "dr10", "dr11", "dr12", "dr13", "dr14", "dr15"
	]
}
