import Foundation
import XCTest
@testable import MacScope

/// Test-only reference for complete captured ARM64 streams. Scalar transitions
/// come from literal decoded assembly, never MacIR scalar SSA or production plans.
/// Only the original opaque call frame and terminal observation are model inputs.
/// This is model-relative K composition, not an implementation of any callee.
enum RegionalCallOracle {
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case let .invalid(message): return message } }
    }

    struct Write: Equatable {
        let address: UInt64
        let bytes: Int
        let bits: UInt64
    }
    struct Memory: Equatable {
        var bytes: [UInt64: UInt8] = [:]
        mutating func initialize(_ address: UInt64, count: Int, byte: UInt8 = 0) {
            for offset in 0..<count { bytes[address &+ UInt64(offset)] = byte }
        }
        mutating func store(_ write: Write) throws {
            guard [1, 2, 4, 8].contains(write.bytes) else { throw Failure.invalid("unsupported memory width") }
            for offset in 0..<write.bytes {
                bytes[write.address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: write.bits >> (offset * 8))
            }
        }
        func load(_ address: UInt64, bytes count: Int) throws -> UInt64 {
            guard [1, 2, 4, 8].contains(count) else { throw Failure.invalid("unsupported memory width") }
            var value: UInt64 = 0
            for offset in 0..<count {
                guard let byte = bytes[address &+ UInt64(offset)] else {
                    throw Failure.invalid("undefined memory byte at 0x\(String(address &+ UInt64(offset), radix: 16))")
                }
                value |= UInt64(byte) << (offset * 8)
            }
            return value
        }
    }
    struct Carrier: Equatable {
        let register: Int
        let width: Int
        let bits: UInt64
    }
    struct Call: Equatable {
        let row: Int
        let occurrence: Int
        let target: String
        let control: [Carrier]
        let arguments: [Carrier]
        let result: UInt64
        let writes: [Write]
    }
    enum Event: Equatable {
        case load(row: Int, address: UInt64, bytes: Int, bits: UInt64)
        case store(row: Int, address: UInt64, bytes: Int, bits: UInt64)
        case call(Call)
    }
    struct Branch: Equatable {
        let row: Int
        let taken: Bool
        let target: UInt64
    }
    struct Result {
        var memory: Memory
        var events: [Event] = []
        var branches: [Branch] = []
        var rowVisits: [Int: Int] = [:]
        var returnBits: UInt64?
        var returned = false
        var finalRegisters: [Int: UInt64] = [:]
        var calls: [Call] { events.compactMap { if case let .call(call) = $0 { return call }; return nil } }
    }
    /// Each response belongs to one dynamic event. Exhaustion, wrong call row,
    /// or unused responses are failures, not implicit zero/identity callees.
    struct Response {
        let row: Int
        let result: UInt64
        var writes: [Write] = []
        var expectedArguments: [UInt64]? = nil
        var expectedControl: [UInt64]? = nil
    }
    struct Scenario {
        let name: String
        var registers: [Int: UInt64]
        var memory: Memory
        var responses: [Response]
        var expectedVisits: [Int: Int] = [:]
    }
    struct Register {
        let index: Int
        let width: Int
        let zero: Bool
        init(_ text: String) throws {
            if text == "sp" { index = 31; width = 64; zero = false; return }
            if text == "xzr" || text == "wzr" {
                index = 31; width = text == "xzr" ? 64 : 32; zero = true; return
            }
            guard let prefix = text.first, prefix == "x" || prefix == "w",
                  let value = Int(text.dropFirst()), (0...30).contains(value),
                  String(value) == String(text.dropFirst()) else { throw Failure.invalid("unsupported register \(text)") }
            index = value; width = prefix == "x" ? 64 : 32; zero = false
        }
    }
    enum Operand { case register(Register), immediate(UInt64) }
    struct Address {
        let base: Register
        let index: Register?
        let shift: Int
        let offset: UInt64
        let update: Update
        enum Update: Equatable { case none, pre, post }
    }
    enum Instruction {
        case move(Register, Operand)
        case arithmetic(String, Register, Register, Operand, Int)
        case multiplySubtract(Register, Register, Register, Register)
        case compare(String, Register, Operand)
        case conditionalCompare(Register, Operand, UInt64, String)
        case select(Register, Register?, Register?, String)
        case memory(String, [Register], Address)
        case page(Register, UInt64)
        case branch(String, Register?, UInt64)
        case call
        case returned
    }
    struct Program {
        let rows: [InstructionRow]
        let code: [Instruction]
        let calls: [Int: MacIRCallFrame]
        let returnsX0: Bool
        init(rows: [InstructionRow], function: MacIRFunction,
             observePhysicalX0WithoutReturnAuthority: Bool = false) throws {
            guard !rows.isEmpty, rows.count == function.instructions.count else { throw Failure.invalid("incomplete source/function correspondence") }
            var parsed: [Instruction] = [], calls: [Int: MacIRCallFrame] = [:]
            for (index, row) in rows.enumerated() {
                guard row.byteWidth == 4, row.structuredOperands != nil,
                      row.address == rows[0].address &+ UInt64(index * 4),
                      row.address == function.instructions[index].source.address else { throw Failure.invalid("missing original decoded row \(index)") }
                let instruction = try Self.parse(row)
                try Self.validate(row, instruction, ir: function.instructions[index])
                parsed.append(instruction)
                if row.mnemonic == "bl" || row.mnemonic == "blr" {
                    guard case let .call(frame, result) = function.instructions[index].operation,
                          frame.knownSignature == nil, frame.richArguments == nil,
                          frame.indirectResultPointer == nil,
                          let result, case let .register(name, _) = result, name == "x0" else {
                        throw Failure.invalid("unsupported original opaque operation at row \(index)")
                    }
                    for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
                        guard case let .gpr(register, width) = argument.location,
                              (0..<8).contains(register), [32, 64].contains(width) else {
                            throw Failure.invalid("unsupported original call carrier")
                        }
                    }
                    if row.mnemonic == "bl" {
                        guard frame.target == row.operands, frame.controlInputs.canonicalControlInputsForAudit.isEmpty else {
                            throw Failure.invalid("direct call target mismatch")
                        }
                    } else {
                        let target = try Register(row.operands)
                        guard target.width == 64, !target.zero,
                              frame.controlInputs.canonicalControlInputsForAudit.count == 1,
                              let control = frame.controlInputs.indirectTarget,
                              control.register == .gpr(index: target.index) else { throw Failure.invalid("indirect call control mismatch") }
                    }
                    calls[index] = frame
                } else if case .call = function.instructions[index].operation {
                    throw Failure.invalid("unaccounted original opaque call")
                }
            }
            guard let last = function.instructions.last, case let .returnValue(value) = last.operation else { throw Failure.invalid("unsupported terminal observation") }
            if observePhysicalX0WithoutReturnAuthority {
                guard function.returnValue == .unknown("unresolved_return_contract"),
                      value == function.returnValue else {
                    throw Failure.invalid("physical X0 observation requires a matching unresolved return contract")
                }
                // Either lifter may refuse return authority. This explicit test-only
                // observation requires the same unresolved model and terminal value.
                // Observe the architectural state at RET without granting the
                // pseudocode function authority to export it as a return value.
                returnsX0 = true
            } else if let value {
                guard case let .register(name, _) = value, name == "x0" else { throw Failure.invalid("terminal observation is not X0") }
                returnsX0 = true
            } else { returnsX0 = false }
            self.rows = rows; code = parsed; self.calls = calls
        }
        /// Cross-check semantic operand facts independently of the emitter. The
        /// fixture additionally fingerprints the full captured envelope, including
        /// presentation and encoded-immediate witnesses not evaluated here.
        private static func validate(_ row: InstructionRow, _ parsed: Instruction, ir: MacIRInstruction) throws {
            guard let envelope = row.structuredOperands, envelope.architecture == .arm64,
                  envelope.schemaVersion == 1 else { throw Failure.invalid("missing ARM64 envelope") }
            if envelope.coverage == .unavailable {
                guard envelope == .unavailable(mnemonic: row.mnemonic, operands: row.operands),
                      ["mov", "mul", "sdiv", "msub", "lsl", "and", "ccmp", "cset", "csel", "blr", "ret"].contains(row.mnemonic),
                      ir.memoryAccess == nil else { throw Failure.invalid("altered unavailable envelope") }
                return
            }
            guard envelope.coverage == .complete, envelope.legacyText == nil else { throw Failure.invalid("partial or contradictory envelope") }
            func register(_ actual: InstructionOperands.Register, _ expected: Register) throws {
                guard actual.bank == .general, actual.index == expected.index, actual.width == expected.width,
                      actual.role == (expected.zero ? .zero : expected.index == 31 ? .stackPointer : .ordinary),
                      actual.arrangement == nil, actual.lane == nil else { throw Failure.invalid("register metadata disagrees with literal stream") }
            }
            func plain(_ actual: InstructionOperands.Operand, _ expected: Register) throws {
                guard case let .register(value) = actual else { throw Failure.invalid("missing typed register") }
                try register(value, expected)
            }
            func operand(_ actual: InstructionOperands.Operand, _ expected: Operand, shift: Int = 0) throws {
                switch (actual, expected) {
                case let (.register(value), .register(wanted)):
                    guard shift == 0 else { throw Failure.invalid("missing register modifier") }; try register(value, wanted)
                case let (.modifiedRegister(value, modifier), .register(wanted)):
                    guard modifier.kind == .lsl, modifier.amount == shift,
                          modifier.presentationKind == nil else { throw Failure.invalid("wrong register modifier") }; try register(value, wanted)
                case let (.immediate(value), .immediate(wanted)):
                    guard shift == 0 else { throw Failure.invalid("unexpected immediate modifier") }
                    let bits: UInt64
                    switch value.value {
                    case let .signed(value): bits = UInt64(bitPattern: value)
                    case let .unsigned(value): bits = value
                    default: throw Failure.invalid("noninteger source immediate")
                    }
                    guard bits == wanted else { throw Failure.invalid("immediate metadata mismatch") }
                default: throw Failure.invalid("operand metadata shape mismatch")
                }
            }
            func pc(_ actual: InstructionOperands.Operand, target: UInt64?, page: Bool) throws {
                guard case let .pcRelative(value) = actual, value.baseAddress == row.address,
                      value.pageRelative == page else { throw Failure.invalid("PC reference metadata mismatch") }
                let base = page ? row.address & ~UInt64(0xfff) : row.address
                let sum = value.displacement < 0 ? base.subtractingReportingOverflow(value.displacement.magnitude)
                    : base.addingReportingOverflow(UInt64(value.displacement))
                guard !sum.overflow, target == nil || sum.partialValue == target else { throw Failure.invalid("PC target mismatch") }
            }
            let values = envelope.operands
            switch parsed {
            case let .memory(op, registers, address):
                guard envelope.opcodeClass == op, values.count == registers.count + 1,
                      let last = values.last, case let .memory(actual) = last else { throw Failure.invalid("memory operand metadata mismatch") }
                for index in registers.indices { try plain(values[index], registers[index]) }
                try register(actual.base, address.base)
                switch (actual.index, address.index) {
                case (nil, nil): guard actual.modifier == nil else { throw Failure.invalid("modifier without memory index") }
                case let (.some(value), .some(wanted)):
                    try register(value, wanted)
                    if let modifier = actual.modifier {
                        guard modifier.kind == .lsl, modifier.amount == address.shift else { throw Failure.invalid("memory index shift mismatch") }
                    } else if address.shift != 0 { throw Failure.invalid("missing memory index shift") }
                default: throw Failure.invalid("memory index mismatch")
                }
                let indexing: InstructionOperands.Memory.Indexing = address.update == .none ? .offset : address.update == .pre ? .preIndex : .postIndex
                let bytes = op == "strb" ? 1 : op == "ldrsw" ? 4 : registers[0].width / 8
                let extensionKind: MacIRMemoryAccess.ExtensionKind = op == "ldrsw" ? .sign : .none
                guard UInt64(bitPattern: actual.displacement) == address.offset,
                      actual.indexing == indexing, actual.writeback == (address.update != .none),
                      envelope.semantics?.memoryAccessWidth == bytes * 8,
                      envelope.semantics?.memoryAccess == (op.hasPrefix("ld") ? .read : .write),
                      ir.memoryAccess?.byteWidth == bytes,
                      ir.memoryAccess?.extensionKind == extensionKind else {
                    throw Failure.invalid("memory width/sign/index/writeback metadata mismatch")
                }
            case let .move(destination, source):
                guard envelope.opcodeClass == "movz", values.count == 2 else { throw Failure.invalid("unsupported complete MOV envelope") }
                try plain(values[0], destination); try operand(values[1], source)
            case let .arithmetic(op, destination, left, right, shift):
                guard envelope.opcodeClass == op, values.count == 3 else { throw Failure.invalid("arithmetic metadata mismatch") }
                try plain(values[0], destination); try plain(values[1], left); try operand(values[2], right, shift: shift)
            case let .compare(op, left, right):
                guard envelope.opcodeClass == (op == "cmp" ? "subs" : "adds"), values.count == 3 else { throw Failure.invalid("comparison metadata mismatch") }
                try plain(values[0], Register(left.width == 32 ? "wzr" : "xzr"))
                try plain(values[1], left); try operand(values[2], right)
            case let .page(destination, target):
                guard envelope.opcodeClass == "adrp", values.count == 2 else { throw Failure.invalid("ADRP envelope mismatch") }
                try plain(values[0], destination); try pc(values[1], target: target, page: true)
            case let .branch(predicate, compared, target):
                if let compared {
                    guard envelope.opcodeClass == predicate, values.count == 2 else { throw Failure.invalid("compare-branch envelope mismatch") }
                    try plain(values[0], compared); try pc(values[1], target: target, page: false)
                } else if predicate == "always" {
                    guard envelope.opcodeClass == "b", values.count == 1 else { throw Failure.invalid("branch envelope mismatch") }
                    try pc(values[0], target: target, page: false)
                } else {
                    guard envelope.opcodeClass == "b.cond", values.count == 2,
                          case let .condition(actual) = values[1], actual.rawValue == predicate else { throw Failure.invalid("condition metadata mismatch") }
                    try pc(values[0], target: target, page: false)
                }
            case .call:
                guard row.mnemonic == "bl", envelope.opcodeClass == "bl", values.count == 1 else { throw Failure.invalid("unsupported complete call envelope") }
                // Symbol spelling and original opaque target are checked above;
                // the byte/envelope fingerprint pins the symbol's original PC.
                try pc(values[0], target: nil, page: false)
            default: throw Failure.invalid("unexpected complete source envelope")
            }
            if case .memory = parsed {} else {
                guard envelope.semantics == nil, ir.memoryAccess == nil else { throw Failure.invalid("hidden memory semantics") }
            }
        }
        private static func split(_ text: String) throws -> [String] {
            var depth = 0, current = "", result: [String] = []
            for character in text {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
                guard (0...1).contains(depth) else { throw Failure.invalid("invalid source operand brackets") }
                if character == ",", depth == 0 {
                    result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                } else { current.append(character) }
            }
            guard depth == 0 else { throw Failure.invalid("unclosed source operand brackets") }
            if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
            return result
        }
        static func number(_ text: String) throws -> UInt64 {
            var value = text
            if value.hasPrefix("#") { value.removeFirst() }
            let negative = value.hasPrefix("-")
            if negative { value.removeFirst() }
            let hex = value.hasPrefix("0x")
            if hex { value.removeFirst(2) }
            guard !value.isEmpty, let bits = UInt64(value, radix: hex ? 16 : 10) else { throw Failure.invalid("unsupported number \(text)") }
            return negative ? 0 &- bits : bits
        }
        private static func operand(_ text: String) throws -> Operand {
            if text.hasPrefix("#") { return .immediate(try number(text)) }
            return .register(try Register(text))
        }
        private static func amount(_ text: String) throws -> Int {
            let tokens = text.split(separator: " ").map(String.init)
            guard tokens.count == 2, tokens[0] == "lsl", let value = Int(exactly: try number(tokens[1])), (0..<64).contains(value) else {
                throw Failure.invalid("unsupported source shift \(text)")
            }
            return value
        }
        private static func address(_ operands: [String]) throws -> Address {
            guard (1...2).contains(operands.count), let first = operands.first, first.hasPrefix("[") else { throw Failure.invalid("unsupported memory address") }
            let pre = first.hasSuffix("]!")
            guard pre || first.hasSuffix("]") else { throw Failure.invalid("unsupported memory suffix") }
            let inner = String(first.dropFirst().dropLast(pre ? 2 : 1))
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...3).contains(parts.count) else { throw Failure.invalid("unsupported memory index") }
            let base = try Register(parts[0])
            guard base.width == 64, !base.zero else { throw Failure.invalid("invalid address base") }
            var index: Register?, shift = 0, offset: UInt64 = 0
            if parts.count >= 2 {
                if parts[1].hasPrefix("#") { offset = try number(parts[1]); guard parts.count == 2 else { throw Failure.invalid("shifted immediate address") } }
                else { index = try Register(parts[1]); guard index?.width == 64 else { throw Failure.invalid("unsupported narrow memory index") } }
            }
            if parts.count == 3 { shift = try amount(parts[2]) }
            if operands.count == 2 {
                guard parts.count == 1, !pre else { throw Failure.invalid("conflicting address writeback") }
                offset = try number(operands[1])
            }
            guard !(pre && index != nil) else { throw Failure.invalid("indexed pre-writeback") }
            return .init(base: base, index: index, shift: shift, offset: offset, update: pre ? .pre : operands.count == 2 ? .post : .none)
        }
        private static func condition(_ text: String) throws -> String {
            guard ["eq", "ne", "hs", "lo", "lt", "gt", "le", "ge", "hi", "ls"].contains(text) else { throw Failure.invalid("unsupported condition \(text)") }
            return text
        }
        /// Observe only literal captured rows, never candidate text or lifted
        /// values. Follow each decoded path until X0/W0 is read or redefined.
        /// Calls kill the old value; their inferred ABI arguments are not reads.
        /// Unsupported instructions end that path without granting evidence.
        static func capturedResultIsRead(rows: [InstructionRow], afterCall callRow: Int) -> Bool {
            guard rows.indices.contains(callRow), ["bl", "blr"].contains(rows[callRow].mnemonic) else { return false }
            let indexed = Dictionary(grouping: rows.indices, by: { rows[$0].address })
            guard indexed.values.allSatisfy({ $0.count == 1 }) else { return false }
            func isResult(_ register: Register?) -> Bool {
                register.map { !$0.zero && $0.index == 0 && [32, 64].contains($0.width) } ?? false
            }
            func readsResult(_ operand: Operand) -> Bool {
                if case let .register(register) = operand { return isResult(register) }
                return false
            }
            var pending = [callRow + 1], visited: Set<Int> = []
            while let row = pending.popLast() {
                guard rows.indices.contains(row), visited.insert(row).inserted,
                      let instruction = try? parse(rows[row]) else { continue }
                var reads = false, writes = false
                switch instruction {
                case let .move(destination, source):
                    reads = readsResult(source); writes = isResult(destination)
                case let .arithmetic(_, destination, left, right, _):
                    reads = isResult(left) || readsResult(right); writes = isResult(destination)
                case let .multiplySubtract(destination, first, second, addend):
                    reads = isResult(first) || isResult(second) || isResult(addend)
                    writes = isResult(destination)
                case let .compare(_, left, right), let .conditionalCompare(left, right, _, _):
                    reads = isResult(left) || readsResult(right)
                case let .select(destination, yes, no, _):
                    reads = isResult(yes) || isResult(no); writes = isResult(destination)
                case let .memory(op, values, address):
                    let load = op.hasPrefix("ld")
                    reads = isResult(address.base) || isResult(address.index)
                        || (!load && values.contains { isResult($0) })
                    writes = (load && values.contains { isResult($0) })
                        || (address.update != .none && isResult(address.base))
                case let .page(destination, _):
                    writes = isResult(destination)
                case let .branch(predicate, compared, target):
                    if isResult(compared) { return true }
                    if let next = indexed[target]?.first { pending.append(next) }
                    if predicate != "always" { pending.append(row + 1) }
                    continue
                case .call:
                    // An explicit BLR X0 reads the target before replacing X0.
                    if rows[row].mnemonic == "blr", isResult(try? Register(rows[row].operands)) { return true }
                    continue
                case .returned:
                    continue
                }
                if reads { return true }
                if !writes { pending.append(row + 1) }
            }
            return false
        }

        private static func parse(_ row: InstructionRow) throws -> Instruction {
            let a = try split(row.operands), op = row.mnemonic
            func arity(_ count: Int) throws { guard a.count == count else { throw Failure.invalid("wrong arity at \(row.address): \(op) \(row.operands)") } }
            switch op {
            case "mov": try arity(2); return .move(try Register(a[0]), try operand(a[1]))
            case "add", "sub", "mul", "sdiv", "and", "lsl":
                guard a.count == 3 || (op == "add" && a.count == 4) else { throw Failure.invalid("unsupported arithmetic arity") }
                let d = try Register(a[0]), left = try Register(a[1]), right = try operand(a[2])
                guard d.width == left.width else { throw Failure.invalid("mixed-width source arithmetic") }
                if case let .register(r) = right, r.width != d.width { throw Failure.invalid("mixed-width right operand") }
                let shift = a.count == 4 ? try amount(a[3]) : 0
                guard shift < d.width else { throw Failure.invalid("shift exceeds register width") }
                return .arithmetic(op, d, left, right, shift)
            case "msub": try arity(4); return .multiplySubtract(try Register(a[0]), try Register(a[1]), try Register(a[2]), try Register(a[3]))
            case "cmp", "cmn": try arity(2); return .compare(op, try Register(a[0]), try operand(a[1]))
            case "ccmp": try arity(4); let flags = try number(a[2]); guard flags < 16 else { throw Failure.invalid("invalid NZCV literal") }; return .conditionalCompare(try Register(a[0]), try operand(a[1]), flags, try condition(a[3]))
            case "cset": try arity(2); return .select(try Register(a[0]), nil, nil, try condition(a[1]))
            case "csel": try arity(4); return .select(try Register(a[0]), try Register(a[1]), try Register(a[2]), try condition(a[3]))
            case "ldr", "ldur", "ldrsw", "str", "strb":
                guard (2...3).contains(a.count) else { throw Failure.invalid("memory arity") }
                return .memory(op, [try Register(a[0])], try address(Array(a.dropFirst())))
            case "ldp", "stp":
                guard (3...4).contains(a.count) else { throw Failure.invalid("pair arity") }
                let first = try Register(a[0]), second = try Register(a[1])
                guard first.width == second.width else { throw Failure.invalid("mixed-width pair") }
                return .memory(op, [first, second], try address(Array(a.dropFirst(2))))
            case "adrp": try arity(2); let target = try number(a[1]); guard target & 0xfff == 0 else { throw Failure.invalid("unaligned ADRP") }; return .page(try Register(a[0]), target)
            case "b": try arity(1); return .branch("always", nil, try number(a[0]))
            case "cbz", "cbnz": try arity(2); return .branch(op, try Register(a[0]), try number(a[1]))
            case "bl", "blr": try arity(1); return .call
            case "ret": try arity(0); return .returned
            default:
                if op.hasPrefix("b.") { try arity(1); return .branch(try condition(String(op.dropFirst(2))), nil, try number(a[0])) }
                throw Failure.invalid("unsupported decoded instruction: \(op) \(row.operands)")
            }
        }
    }
    struct Flags {
        var n: Bool, z: Bool, c: Bool, v: Bool
        init(literal: UInt64) { n = literal & 8 != 0; z = literal & 4 != 0; c = literal & 2 != 0; v = literal & 1 != 0 }
        init(left: UInt64, right: UInt64, width: Int, adding: Bool) {
            let mask = width == 64 ? UInt64.max : UInt64(UInt32.max)
            let a = left & mask, b = right & mask, sign = UInt64(1) << (width - 1)
            let result = (adding ? a &+ b : a &- b) & mask
            n = result & sign != 0; z = result == 0
            c = adding ? (width == 64 ? a.addingReportingOverflow(b).overflow : a + b > mask) : a >= b
            v = adding ? (~(a ^ b) & (a ^ result) & sign != 0) : ((a ^ b) & (a ^ result) & sign != 0)
        }
        func test(_ condition: String) throws -> Bool {
            switch condition {
            case "eq": return z
            case "ne": return !z
            case "hs": return c
            case "lo": return !c
            case "lt": return n != v
            case "gt": return !z && n == v
            case "le": return z || n != v
            case "ge": return n == v
            case "hi": return c && !z
            case "ls": return !c || z
            default: throw Failure.invalid("unsupported flag condition")
            }
        }
    }
    struct Machine {
        let program: Program
        let scenario: Scenario
        var registers: [Int: UInt64]
        var flags: Flags?
        var result: Result
        var responseIndex = 0
        init(program: Program, scenario: Scenario) {
            self.program = program; self.scenario = scenario
            registers = scenario.registers; result = .init(memory: scenario.memory)
        }
        func run() throws -> Result { var copy = self; return try copy.execute() }
        private func read(_ register: Register) throws -> UInt64 {
            if register.zero { return 0 }
            guard let bits = registers[register.index] else { throw Failure.invalid("uninitialized source register \(register.index)") }
            return register.width == 32 ? bits & 0xffff_ffff : bits
        }
        private mutating func write(_ register: Register, _ bits: UInt64) {
            if !register.zero { registers[register.index] = register.width == 32 ? bits & 0xffff_ffff : bits }
        }
        private func read(_ operand: Operand) throws -> UInt64 {
            switch operand { case let .register(register): return try read(register); case let .immediate(bits): return bits }
        }
        private func condition(_ name: String) throws -> Bool {
            guard let flags else { throw Failure.invalid("source predicate reads killed NZCV") }
            return try flags.test(name)
        }
        private mutating func load(_ address: UInt64, bytes: Int, row: Int) throws -> UInt64 {
            let bits = try result.memory.load(address, bytes: bytes)
            result.events.append(.load(row: row, address: address, bytes: bytes, bits: bits)); return bits
        }
        private mutating func store(_ address: UInt64, bytes: Int, bits: UInt64, row: Int) throws {
            let mask: UInt64 = bytes == 8 ? .max : (UInt64(1) << (bytes * 8)) - 1
            try result.memory.store(.init(address: address, bytes: bytes, bits: bits))
            result.events.append(.store(row: row, address: address, bytes: bytes, bits: bits & mask))
        }
        private mutating func opaqueCall(row: Int) throws {
            guard let frame = program.calls[row], responseIndex < scenario.responses.count else { throw Failure.invalid("unscripted opaque call at row \(row)") }
            let response = scenario.responses[responseIndex]
            guard response.row == row else { throw Failure.invalid("expected call row \(response.row), executed \(row)") }
            var arguments: [Carrier] = [], control: [Carrier] = []
            for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
                guard case let .gpr(index, width) = argument.location else { throw Failure.invalid("unsupported call argument") }
                arguments.append(.init(register: index, width: width, bits: try read(Register("\(width == 32 ? "w" : "x")\(index)"))))
            }
            for input in frame.controlInputs.canonicalControlInputsForAudit {
                guard case let .gpr(index) = input.register else { throw Failure.invalid("unsupported call control") }
                control.append(.init(register: index, width: 64, bits: try read(Register("x\(index)"))))
            }
            if let expected = response.expectedArguments, expected != arguments.map(\.bits) { throw Failure.invalid("source call argument scenario mismatch at row \(row)") }
            if let expected = response.expectedControl, expected != control.map(\.bits) { throw Failure.invalid("source call control scenario mismatch at row \(row)") }
            // Explicit retained relation: current X19...X29 and SP survive K.
            // All modeled volatile GPRs and NZCV become unavailable; X0 is then
            // defined by this event's original opaque result, never a cached atom.
            for index in Array(0...18) + [30] { registers.removeValue(forKey: index) }
            flags = nil
            for write in response.writes { try result.memory.store(write) }
            registers[0] = response.result
            let occurrence = result.calls.filter { $0.row == row }.count
            result.events.append(.call(.init(row: row, occurrence: occurrence, target: frame.target,
                control: control, arguments: arguments, result: response.result, writes: response.writes)))
            responseIndex += 1
        }
        private mutating func execute() throws -> Result {
            var pc = 0, fuel = 20_000
            let positions = Dictionary(uniqueKeysWithValues: program.rows.enumerated().map { ($0.element.address, $0.offset) })
            while program.code.indices.contains(pc), fuel > 0 {
                fuel -= 1
                result.rowVisits[pc, default: 0] += 1
                switch program.code[pc] {
                case let .move(destination, source): write(destination, try read(source))
                case let .page(destination, address): write(destination, address)
                case let .arithmetic(op, destination, left, right, shift):
                    let a = try read(left), b = try read(right) << shift, value: UInt64
                    switch op {
                    case "add": value = a &+ b
                    case "sub": value = a &- b
                    case "mul": value = a &* b
                    case "and": value = a & b
                    case "lsl": guard b < UInt64(destination.width) else { throw Failure.invalid("source immediate shift outside width") }; value = a << Int(b)
                    case "sdiv":
                        let x = destination.width == 32 ? Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: a))) : Int64(bitPattern: a)
                        let y = destination.width == 32 ? Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: b))) : Int64(bitPattern: b)
                        if y == 0 { value = 0 }
                        else if x == Int64.min && y == -1 { value = UInt64(bitPattern: Int64.min) }
                        else { value = UInt64(bitPattern: x / y) }
                    default: throw Failure.invalid("unsupported scalar arithmetic")
                    }
                    write(destination, value)
                case let .multiplySubtract(destination, first, second, addend):
                    let a = try read(first), b = try read(second), c = try read(addend)
                    write(destination, c &- (a &* b))
                case let .compare(op, left, right): flags = try .init(left: read(left), right: read(right), width: left.width, adding: op == "cmn")
                case let .conditionalCompare(left, right, literal, predicate):
                    if try condition(predicate) { flags = try .init(left: read(left), right: read(right), width: left.width, adding: false) }
                    else { flags = .init(literal: literal) }
                case let .select(destination, yes, no, predicate):
                    let selected = try condition(predicate)
                    if let yes, let no { write(destination, try read(selected ? yes : no)) }
                    else { write(destination, selected ? 1 : 0) }
                case let .memory(op, values, address):
                    let base = try read(address.base)
                    let index = try address.index.map { try read($0) << address.shift } ?? 0
                    let location = address.update == .post ? base : base &+ address.offset &+ index
                    let count = op == "strb" ? 1 : op == "ldrsw" ? 4 : values[0].width / 8
                    let loading = op.hasPrefix("ld")
                    if loading {
                        var loaded: [UInt64] = []
                        for slot in values.indices { loaded.append(try load(location &+ UInt64(slot * count), bytes: count, row: pc)) }
                        for slot in values.indices {
                            let bits = op == "ldrsw" ? UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: loaded[slot])))) : loaded[slot]
                            write(values[slot], bits)
                        }
                    } else {
                        let sources = try values.map(read)
                        for slot in values.indices { try store(location &+ UInt64(slot * count), bytes: count, bits: sources[slot], row: pc) }
                    }
                    if address.update != .none { write(address.base, base &+ address.offset) }
                case let .branch(predicate, register, target):
                    let taken: Bool
                    if predicate == "always" { taken = true }
                    else if let register { let zero = try read(register) == 0; taken = predicate == "cbz" ? zero : !zero }
                    else { taken = try condition(predicate) }
                    result.branches.append(.init(row: pc, taken: taken, target: target))
                    if taken {
                        guard let destination = positions[target] else { throw Failure.invalid("branch leaves complete captured function") }
                        pc = destination; continue
                    }
                case .call: try opaqueCall(row: pc)
                case .returned:
                    guard responseIndex == scenario.responses.count else { throw Failure.invalid("unused opaque-call responses") }
                    for (row, expected) in scenario.expectedVisits where result.rowVisits[row, default: 0] != expected { throw Failure.invalid("wrong scenario path at row \(row)") }
                    if program.returnsX0 { result.returnBits = try read(Register("x0")) }
                    result.returned = true; result.finalRegisters = registers; return result
                }
                pc += 1
            }
            throw Failure.invalid(fuel == 0 ? "source fuel exhausted" : "source fell out without RET")
        }
    }
}

extension RegionalCallOracle {
    /// Values are input data for the real complete streams, not authored rows.
    /// Deliberately small, named scenarios make a path mistake diagnosable.
    enum UpsamplerScenarios {
        static let context: UInt64 = 0x10000
        static let controller: UInt64 = 0x20000
        static let errorManager: UInt64 = 0x30000
        static let allocator: UInt64 = 0x40000
        static let upsampler: UInt64 = 0x50000
        static let components: UInt64 = 0x60000
        static let stack: UInt64 = 0x80000
        static let errorTarget: UInt64 = 0xf123_0000_0000_0100
        static let allocationTarget: UInt64 = 0xe234_0000_0000_0200
        static let bufferTarget: UInt64 = 0xd345_0000_0000_0300

        enum Path: String {
            case unused, fullsize, h2v1, h1v2, h2v2, integral, fractional
        }
        struct Component {
            let path: Path
            var scale: UInt32 = 1
            var width: UInt32 = 7
            var h: UInt32 = 1
            var v: UInt32 = 1
            var needed: UInt32 = 1
            init(_ path: Path) {
                self.path = path
                if path == .unused { needed = 0 }
            }
        }
        static func make(seed: RegionalCallSeed, name: String, paths: [Path],
                         allocate: Bool = false, fancy: Bool = false,
                         simdResults: [UInt64] = [], invalidPrecision: Bool = false,
                         preliminaryError: Bool = false, denominator: UInt32 = 1,
                         sampleWidth: UInt32 = 0xffff_fff1,
                         componentTransform: ((Int, inout Component) -> Void)? = nil,
                         change: ((inout Scenario) throws -> Void)? = nil) throws -> Scenario {
            var memory = Memory()
            for (address, size) in [(context, 0x300), (controller, 0x100), (errorManager, 0x80),
                                    (allocator, 0x40), (upsampler, 0x200), (components, max(1, paths.count) * 0x60)] {
                memory.initialize(address, count: size, byte: 0)
            }
            func put(_ address: UInt64, _ bits: UInt64, _ bytes: Int = 4) throws {
                try memory.store(.init(address: address, bytes: bytes, bits: bits))
            }
            try put(context, errorManager, 8); try put(errorManager, errorTarget, 8)
            try put(context + 8, allocator, 8); try put(allocator, allocationTarget, 8)
            try put(allocator + 0x10, bufferTarget, 8)
            try put(context + 0x238, controller, 8); try put(context + 0x278, upsampler, 8)
            try put(context + 0x130, components, 8)
            try put(controller + 0x14, 0); try put(controller + 0x70, allocate ? 0 : 1)
            let precision: UInt64 = seed == .jinit ? 8 : seed == .j12init ? 12 : 16
            try put(context + 0x128, invalidPrecision ? 0x8000_0000 : precision)
            try put(context + 0x18c, preliminaryError ? 1 : 0)
            try put(context + 0x64, fancy ? 1 : 0)
            try put(context + 0x1a0, UInt64(denominator))
            try put(context + 0x38, UInt64(paths.count)); try put(context + 0x88, UInt64(sampleWidth))
            // A single scenario has one global sampling grid. Mixed-path cases
            // use the 2x2 grid; 3x3 selects integral/remainder paths.
            let grid: UInt64 = paths.contains(.integral) || paths.contains(.fractional) ? 3 : 2
            try put(context + 0x198, grid); try put(context + 0x19c, grid)
            var responses: [Response] = []
            if invalidPrecision { responses.append(.init(row: 21, result: 0x8000_0000_1111_2222,
                expectedArguments: [context], expectedControl: [errorTarget])) }
            if allocate { responses.append(.init(row: 35, result: upsampler,
                expectedArguments: [context, 1, 0x130], expectedControl: [allocationTarget])) }
            if preliminaryError { responses.append(.init(row: seed == .jinit ? 51 : 52, result: 0xffff_ffff_0000_0000,
                expectedArguments: [context], expectedControl: [errorTarget])) }
            var simdIndex = 0
            for (index, path) in paths.enumerated() {
                var component = Component(path)
                switch path {
                case .unused, .fullsize: component.h = UInt32(grid); component.v = UInt32(grid)
                case .h2v1: component.h = 1; component.v = 2
                case .h1v2: component.h = 2; component.v = 1
                case .h2v2, .integral: component.h = 1; component.v = 1
                case .fractional: component.h = 2; component.v = 2
                }
                componentTransform?(index, &component)
                let base = components + UInt64(index * 0x60)
                try put(base + 8, UInt64(component.h)); try put(base + 12, UInt64(component.v))
                try put(base + 0x24, UInt64(component.scale)); try put(base + 0x2c, UInt64(component.width))
                try put(base + 0x34, UInt64(component.needed))
                if seed == .jinit {
                    let simdRow: Int?
                    switch path {
                    case .h2v1: simdRow = fancy && denominator > 1 && component.width >= 3 ? 122 : 129
                    case .h1v2: simdRow = fancy && denominator > 1 ? 102 : nil
                    case .h2v2: simdRow = fancy && denominator > 1 && component.width >= 3 ? 159 : 168
                    default: simdRow = nil
                    }
                    if let simdRow {
                        let value = simdIndex < simdResults.count ? simdResults[simdIndex] : 0x8000_0000_0000_0001
                        responses.append(.init(row: simdRow, result: value, expectedArguments: [context], expectedControl: []))
                        simdIndex += 1
                    }
                }
                if path == .fractional { responses.append(.init(row: seed == .jinit ? 149 : 159,
                    result: 0x8123_4567_0000_0000 | UInt64(index), expectedArguments: [context], expectedControl: [errorTarget])) }
                if allocate && path != .unused && path != .fullsize {
                    let round: UInt64 = 0xffff_ffff_0000_0100 | UInt64(index)
                    responses.append(.init(row: seed == .jinit ? 187 : 131, result: round,
                        expectedArguments: [UInt64(sampleWidth), grid], expectedControl: []))
                    responses.append(.init(row: seed == .jinit ? 192 : 136,
                        result: 0x9234_5678_0000_0000 | UInt64(index),
                        expectedArguments: [context, 1, round, grid], expectedControl: [bufferTarget]))
                }
            }
            var registers: [Int: UInt64] = [0: context, 31: stack]
            // High-bit entry snapshots must be saved/restored bit-for-bit.
            for index in 19...30 { registers[index] = 0x8000_0000_1234_0000 | UInt64(index) }
            var scenario = Scenario(name: name, registers: registers, memory: memory, responses: responses)
            scenario.expectedVisits[seed == .jinit ? 71 : 72] = paths.count
            try change?(&scenario)
            return scenario
        }

        static func all(for seed: RegionalCallSeed) throws -> [Scenario] {
            var cases: [Scenario] = []
            cases.append(try make(seed: seed, name: "zero-bypass-no-call-result", paths: []))
            cases.append(try make(seed: seed, name: "zero-allocation", paths: [], allocate: true))
            cases.append(try make(seed: seed, name: "two-returning-prefix-errors", paths: [],
                                  invalidPrecision: true, preliminaryError: true))
            for path in [Path.unused, .fullsize, .h2v1, .h1v2, .h2v2, .integral, .fractional] {
                cases.append(try make(seed: seed, name: "one-\(path.rawValue)-bypass", paths: [path]))
                cases.append(try make(seed: seed, name: "one-\(path.rawValue)-allocated", paths: [path], allocate: true))
            }
            cases.append(try make(seed: seed, name: "multiple-distinct-joins-and-call-results", paths: [.unused, .h2v1, .fullsize, .h2v2],
                                  allocate: true, simdResults: [0x0000_0001_0000_0000, 0xffff_ffff_0000_0001]))
            // Fancy requires denominator>1; multiply by two before division to
            // keep the selected grid ratios unchanged.
            for path in [Path.h2v1, .h1v2, .h2v2] {
                cases.append(try make(seed: seed, name: "fancy-\(path.rawValue)-W0-zero-high64", paths: [path],
                    allocate: true, fancy: true, simdResults: [0x8000_0000_0000_0000], denominator: 2,
                    componentTransform: { _, component in component.scale = 2 }))
            }
            cases.append(try make(seed: seed, name: "call-mutates-next-argument-and-loop-count", paths: [.h2v1, .h2v1], allocate: true, change: { scenario in
                let roundRow = seed == .jinit ? 187 : 131
                let bufferRow = seed == .jinit ? 192 : 136
                guard let round = scenario.responses.firstIndex(where: { $0.row == roundRow }),
                      let buffer = scenario.responses.firstIndex(where: { $0.row == bufferRow }) else { throw Failure.invalid("missing scenario call") }
                scenario.responses[round].writes = [.init(address: context + 0x19c, bytes: 4, bits: 0xffff_fffd)]
                scenario.responses[buffer].expectedArguments?[3] = 0xffff_fffd
                scenario.responses[buffer].writes = [.init(address: context + 0x38, bytes: 4, bits: 1)]
                scenario.responses = Array(scenario.responses.prefix(buffer + 1))
                scenario.expectedVisits[seed == .jinit ? 71 : 72] = 1
            }))
            cases.append(try make(seed: seed, name: "call-aliases-saved-stack-pair", paths: [], allocate: true, change: { scenario in
                scenario.responses[0].writes = [
                    .init(address: stack - 0x10, bytes: 8, bits: 0xfedc_ba98_7654_3210),
                    .init(address: stack - 8, bytes: 8, bits: 0x0123_4567_89ab_cdef)
                ]
            }))
            cases.append(try make(seed: seed, name: "negative-count-no-loop", paths: [], change: { scenario in
                try scenario.memory.store(.init(address: context + 0x38, bytes: 4, bits: 0xffff_ffff))
            }))
            for (name, v, scale, divisor) in [
                ("division-zero", UInt32(0x8000_0000), UInt32(1), UInt32(0)),
                ("division-min-by-negative-one", UInt32(0x8000_0000), UInt32(1), UInt32.max),
                ("negative-division-truncates-toward-zero", UInt32(0xffff_fffd), UInt32(1), UInt32(2)),
                ("multiply-wraps-before-signed-division", UInt32(0x8000_0001), UInt32(2), UInt32(1))
            ] {
                cases.append(try make(seed: seed, name: name, paths: [.unused], denominator: divisor,
                    componentTransform: { _, component in component.v = v; component.scale = scale }))
            }
            cases.append(try make(seed: seed, name: "remainder-min-div-negative-one-and-byte-narrowing", paths: [.integral],
                componentTransform: { _, component in component.h = .max }, change: { scenario in
                    try scenario.memory.store(.init(address: context + 0x198, bytes: 4, bits: 0x8000_0000))
                }))
            cases.append(try make(seed: seed, name: "ordinary-store-aliases-loop-count", paths: [.fullsize, .fullsize, .fullsize], change: { scenario in
                try scenario.memory.store(.init(address: context + 0x278, bytes: 8, bits: context - 0xb8))
                scenario.expectedVisits[seed == .jinit ? 71 : 72] = 2
            }))
            let precision: UInt64 = seed == .jinit ? 8 : seed == .j12init ? 12 : 16
            let lower: UInt64 = seed == .jinit ? 2 : precision - 3
            for (label, value, error) in [("lower-accepted", lower, false), ("below-range", lower - 1, true), ("above-range", precision + 1, true)] {
                cases.append(try make(seed: seed, name: "CMN-carry-\(label)", paths: [], invalidPrecision: error, change: { scenario in
                    try scenario.memory.store(.init(address: controller + 0x14, bytes: 4, bits: 1))
                    try scenario.memory.store(.init(address: context + 0x128, bytes: 4, bits: value))
                    scenario.expectedVisits[13] = 1
                }))
            }
            cases.append(try make(seed: seed, name: "negative-LDRSW-call-carrier", paths: [.integral], allocate: true, change: { scenario in
                try scenario.memory.store(.init(address: context + 0x198, bytes: 4, bits: 0xffff_fffd))
                guard let index = scenario.responses.firstIndex(where: { $0.row == (seed == .jinit ? 187 : 131) }) else { throw Failure.invalid("missing round event") }
                scenario.responses[index].expectedArguments?[1] = 0xffff_ffff_ffff_fffd
            }))
            cases.append(try make(seed: seed, name: "fancy-CSEL-nonzero-low32", paths: [.h1v2],
                fancy: true, simdResults: [0x8000_0000_0000_0001], denominator: 2,
                componentTransform: { _, component in component.scale = 2 }))
            cases.append(try make(seed: seed, name: "allocation-high64-return", paths: [], allocate: true, change: { scenario in
                scenario.responses[0] = .init(row: 35, result: 0x8000_0000_0005_0000,
                    expectedArguments: [context, 1, 0x130], expectedControl: [allocationTarget])
            }))
            cases.append(try make(seed: seed, name: "prior-call-result-survives-later-bypass", paths: [.fractional, .integral]))
            cases.append(try make(seed: seed, name: "same-static-error-call-new-event-result", paths: [.fractional, .fractional]))
            cases.append(try make(seed: seed, name: "high-bit-formal-pointer-import", paths: [], change: { scenario in
                let high: UInt64 = 0x8000_0000_0001_0000
                var relocated: [UInt64: UInt8] = [:]
                for offset in UInt64(0)..<UInt64(0x300) {
                    relocated[high + offset] = scenario.memory.bytes[context + offset]
                    scenario.memory.bytes.removeValue(forKey: context + offset)
                }
                scenario.memory.bytes.merge(relocated, uniquingKeysWith: { _, replacement in replacement })
                scenario.registers[0] = high
            }))
            cases.append(try make(seed: seed, name: "current-X28-snapshot-and-later-control-reload", paths: [.h2v1, .h2v1], allocate: true, change: { scenario in
                let rounds = scenario.responses.indices.filter { scenario.responses[$0].row == (seed == .jinit ? 187 : 131) }
                let buffers = scenario.responses.indices.filter { scenario.responses[$0].row == (seed == .jinit ? 192 : 136) }
                guard rounds.count == 2, buffers.count == 2 else { throw Failure.invalid("missing repeated control scenario calls") }
                let nextTarget: UInt64 = 0xc456_0000_0000_0400
                scenario.responses[rounds[0]].writes = [.init(address: allocator + 0x10, bytes: 8, bits: nextTarget)]
                scenario.responses[buffers[1]].expectedControl = [nextTarget]
            }))
            cases.append(try make(seed: seed, name: "same-execution-CSEL-writer-time-flags", paths: [.h1v2, .h2v2],
                fancy: true, simdResults: [0x8000_0000_0000_0001, 0x0000_0001_0000_0000], denominator: 2,
                componentTransform: { _, component in component.scale = 2 }))
            cases.append(try make(seed: seed, name: "high-bit-formal-call-argument", paths: [], allocate: true, change: { scenario in
                let high: UInt64 = 0x8000_0000_0001_0000
                var relocated: [UInt64: UInt8] = [:]
                for offset in UInt64(0)..<UInt64(0x300) {
                    relocated[high + offset] = scenario.memory.bytes[context + offset]
                    scenario.memory.bytes.removeValue(forKey: context + offset)
                }
                scenario.memory.bytes.merge(relocated, uniquingKeysWith: { _, replacement in replacement })
                scenario.registers[0] = high
                scenario.responses[0].expectedArguments?[0] = high
            }))
            return cases
        }
    }
}

/// ordinary-C candidate-dialect supersession. The literal decoded Program/Machine and
/// every original scenario above remain unchanged. The retired candidate parser
/// and exact old wrapper bodies are retained in the earlier presentation source snapshot.
/// These four selector identities remain live. SOURCE_ONLY / NOT_RUN: source
/// review is not a runtime receipt and no prior green is claimed for this diff.
final class RegionalCallSemanticTests: XCTestCase {
    func testJinitUpsamplerDynamicCallsMemoryAndJoins() throws {
        try RegionalNativeUpsamplerAdapter.compare(.jinit)
    }
    func testJ12initUpsamplerDynamicCallsMemoryAndJoins() throws {
        try RegionalNativeUpsamplerAdapter.compare(.j12init)
    }
}

/// Changed actual-text checks only: these selectors never execute an unchanged
/// candidate for mutation credit. Each mutant must parse, consume the identical
/// ordered K rows/results/writes and return normally before a named mismatch.
final class RegionalCallSemanticMutationTests: XCTestCase {
    func testJinitActualEmittedTextSemanticMutations() throws {
        try RegionalNativeUpsamplerAdapter.mutations(.jinit)
    }
    func testJ12initActualEmittedTextSemanticMutations() throws {
        try RegionalNativeUpsamplerAdapter.mutations(.j12init)
    }
    func testLiteralArgument3RequiresEveryPathCurrentLoad() throws {
        try RegionalNativeUpsamplerAdapter.argumentBindingControls()
    }
    func testLiteralArgument3OverwriteKeepsLoadAndRejectsSiblingBindings() throws {
        try RegionalNativeUpsamplerAdapter.argumentOverwriteControls()
    }
    func testLiteralCounterBindingRequiresExactUnsigned64Operand() throws {
        try RegionalNativeUpsamplerAdapter.counterBindingControls()
    }
    func testLiteralCCMPPolarityRetainsExactUnsigned32Writers() throws {
        try RegionalNativeUpsamplerAdapter.ccmpBindingControls()
    }

    func testLiteralCCMPBindingRejectsSameNameReachingWriterOverwrite() throws {
        typealias A = RegionalNativeUpsamplerAdapter
        for predicate in ["(doubled == maxH) && (vertical == maxV)",
                          "(doubled != maxH) || (vertical != maxV)"] {
            let producers = [
                "uint32_t doubled; doubled = 2;",
                "uint32_t maxH; maxH = 4;",
                "int32_t vertical; vertical = 2;",
                "uint32_t maxV; maxV = 2;"
            ]
            let original = try A.literalProgram(producers + ["condition = \(predicate);"])
            let condition = try A.scalar(original, row: 4).right
            _ = try A.ccmpFirstComparison(original, condition: condition, row: 4,
                doubled: A.scalar(original, row: 0),
                maxH: A.scalar(original, row: 1),
                vertical: A.scalar(original, row: 2),
                maxV: A.scalar(original, row: 3))

            // All four source-producer statements and the entire predicate text
            // remain identical. Only the writer reaching doubled has changed.
            for overwrite in ["doubled = maxH;", "if (maxH == 4) { doubled = maxH; }",
                              "maxH = doubled;", "vertical = 0;", "maxV = doubled;"] {
                let changed = try A.literalProgram(producers + [overwrite, "condition = \(predicate);"])
                let changedCondition = try A.scalar(changed, row: 5).right
                XCTAssertThrowsError(try A.ccmpFirstComparison(changed, condition: changedCondition, row: 5,
                    doubled: A.scalar(changed, row: 0),
                    maxH: A.scalar(changed, row: 1),
                    vertical: A.scalar(changed, row: 2),
                    maxV: A.scalar(changed, row: 3))) { error in
                    guard let failure = error as? OrdinaryC.Failure,
                          case .invalidContract = failure else {
                        return XCTFail("Expected reaching-writer contract refusal, got \(error)")
                    }
                }
            }
            // A write after the consuming expression does not invalidate its
            // earlier reaching definition: this is deliberately not single-write.
            let later = try A.literalProgram(producers + ["condition = \(predicate);", "doubled = maxH;"])
            _ = try A.ccmpFirstComparison(later, condition: A.scalar(later, row: 4).right, row: 4,
                doubled: A.scalar(later, row: 0), maxH: A.scalar(later, row: 1),
                vertical: A.scalar(later, row: 2), maxV: A.scalar(later, row: 3))
        }
    }

    func testLiteralCounterBindingRejectsSameNameReachingWriterOverwrite() throws {
        typealias A = RegionalNativeUpsamplerAdapter
        let producers = ["uint64_t counter; counter = 0;", "uint64_t other; other = 7;"]
        let original = try A.literalProgram(producers + ["result = counter + 1;"])
        _ = try A.counterLiteral(original, addition: A.scalar(original, row: 2).right, row: 2,
            operand: [A.scalar(original, row: 0)])

        // This is the singleton SSA-style carrier obligation, NOT the native
        // loop slot's intentional entry/backedge pair of reaching definitions.
        for overwrite in ["counter = other;", "if (other == 7) { counter = other; }"] {
            let changed = try A.literalProgram(producers + [overwrite, "result = counter + 1;"])
            XCTAssertThrowsError(try A.counterLiteral(changed, addition: A.scalar(changed, row: 3).right, row: 3,
                operand: [A.scalar(changed, row: 0)])) { error in
                guard let failure = error as? OrdinaryC.Failure,
                      case .invalidContract = failure else {
                    return XCTFail("Expected reaching-writer contract refusal, got \(error)")
                }
            }
        }
        let later = try A.literalProgram(producers + ["result = counter + 1;", "counter = other;"])
        _ = try A.counterLiteral(later, addition: A.scalar(later, row: 2).right, row: 2,
            operand: [A.scalar(later, row: 0)])
        let unrelated = try A.literalProgram(producers + ["other = 9;", "result = counter + 1;"])
        _ = try A.counterLiteral(unrelated, addition: A.scalar(unrelated, row: 3).right, row: 3,
            operand: [A.scalar(unrelated, row: 0)])
    }
}

private enum RegionalNativeUpsamplerAdapter {
    typealias C = OrdinaryC
    typealias O = RegionalCallOracle
    typealias S = O.UpsamplerScenarios
    typealias M = OrdinaryCMutationControls

    struct Prepared {
        let fixture: OrdinaryCRecordedCallFixture
        let source: O.Program
        let candidate: C.Program
        let scenarios: [O.Scenario]
        let restores: [Restore]
    }
    struct Restore {
        let row: Int
        let registers: [Int]
        let left: [C.Expression]
        let names: [String]
    }
    struct Definition {
        let statement: C.Statement
        let left: C.Expression
        let right: C.Expression
        let name: String
    }

    static func prepare(_ seed: RegionalCallSeed) throws -> Prepared {
        // Full typed output is the product obligation. The explicitly opaque
        // derivative exists only for the unchanged frozen semantic oracle.
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        let full = fixtures.full
        let audit = try OrdinaryCOutputAudit.analyze(document: full.document,
            function: full.function, baselineText: full.baselineText)
        guard audit.errors.isEmpty,
              !audit.tokens.contains(where: { $0.text.hasPrefix("rgn_regional_") }),
              audit.rawEquivalentTotal < seed.baselineRaw,
              audit.gotoEquivalentTotal < seed.baselineTotal,
              !audit.loops.isEmpty else {
            throw C.Failure.unsupportedSyntax("REGIONAL_NATIVE_REPAIR_REQUIRED: ordinary complete output and genuine transfer reduction required; \(audit.errors)")
        }
        try fixtures.requireFullTypedRowOwnership()
        let fixture = fixtures.opaque
        let contract = try C.contract(for: fixture)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let source = try O.Program(rows: fixture.rows, function: fixture.function)
        let original = try S.all(for: seed)
        guard Set(original.map(\.name)).count == original.count else {
            throw C.Failure.invalidContract("duplicate original upsampler scenario")
        }
        // Add one real complete-input CCMP witness; none of the original inputs,
        // decoded instructions, source authorities, or K responses are replaced.
        let supplemental = try sameCallCCMP(seed)
        guard !original.contains(where: { $0.name == supplemental.name }) else {
            throw C.Failure.invalidContract("CCMP supplement collides with an original scenario")
        }
        return try .init(fixture: fixture, source: source, candidate: candidate,
            scenarios: original + [supplemental], restores: bindRestores(candidate, source: source, seed: seed))
    }

    static func compare(_ seed: RegionalCallSeed) throws {
        let prepared = try prepare(seed)
        try rejectMalformedText(prepared)
        for scenario in prepared.scenarios {
            let expected = try O.Machine(program: prepared.source, scenario: scenario).run()
            let actual = try C.Machine(program: prepared.candidate,
                scenario: C.scenario(scenario, contract: prepared.candidate.contract)).run()
            try C.compare(actual, events: expected.events, memory: expected.memory.bytes,
                returned: expected.returned, terminal: expected.returnBits,
                contract: prepared.candidate.contract, name: scenario.name)
            XCTAssertNil(expected.returnBits, "the original upsampler terminal remains void")
            XCTAssertNil(actual.terminal)
            XCTAssertEqual(actual.consumedResponses, scenario.responses.count)
            try compareRestores(actual, expected: expected, bindings: prepared.restores, name: scenario.name)
            if scenario.name == ccName {
                try requireSameCallSource(expected, seed: seed)
            }
        }
    }

    /// Bind BEFORE execution by original LDP destination order, actual protected
    /// AST lhs spans and independently manifested ordered memory effect slots.
    /// Printed register names and reference-value matching confer no authority.
    static func bindRestores(_ candidate: C.Program, source: O.Program,
                             seed: RegionalCallSeed) throws -> [Restore] {
        var result: [Restore] = []
        let assignments = statements(candidate.root)
        for row in seed.suffixStart..<(seed.rowCount - 1) {
            guard case let .memory(op, registers, address) = source.code[row], op == "ldp",
                  registers.count == 2, registers.allSatisfy({ $0.width == 64 && !$0.zero }),
                  address.base.index == 31, candidate.contract.exterior[row] != nil else {
                throw C.Failure.invalidContract("original immutable restore identity at row \(row)")
            }
            let statement = try unique(assignments.filter {
                guard (try? candidate.row(at: $0.span)) == row else { return false }
                if case .assign = $0.node { return true }; return false
            }, "parsed restore row \(row)")
            guard case let .assign(left, right) = statement.node else {
                throw C.Failure.invalidContract("restore assignment disappeared")
            }
            let architectural = registers.map(\.index) + (address.update == .none ? [] : [address.base.index])
            guard left.count == architectural.count, right.count == architectural.count else {
                throw C.Failure.invalidContract("restore destination count at row \(row)")
            }
            var names: [String] = []
            for ordinal in left.indices {
                guard case let .name(name) = left[ordinal].node,
                      candidate.symbols[name]?.type == .u64,
                      try candidate.row(at: left[ordinal].span) == row else {
                    throw C.Failure.invalidContract("restore lhs ownership at row \(row), slot \(ordinal)")
                }
                if ordinal < registers.count {
                    guard case let .load(type, _) = right[ordinal].node, type == .u64,
                          candidate.memorySites[right[ordinal].span] == .init(row: row, effectOrdinal: ordinal) else {
                        throw C.Failure.invalidContract("restore load ownership at row \(row), slot \(ordinal)")
                    }
                } else if candidate.expressionTypes[right[ordinal].span] != .u64 {
                    throw C.Failure.invalidContract("restore SP writeback width")
                }
                names.append(name)
            }
            result.append(.init(row: row, registers: architectural, left: left, names: names))
        }
        guard result.count == 6, result.flatMap(\.registers).count == 13,
              Set(result.flatMap(\.registers)) == Set(19...31),
              Set(result.flatMap(\.names)).count == 13 else {
            throw C.Failure.invalidContract("complete original twelve-register/SP restore ownership")
        }
        return result
    }

    static func compareRestores(_ actual: C.Result, expected: O.Result,
                                bindings: [Restore], name: String) throws {
        let rows = Set(bindings.map(\.row))
        let commits = actual.commits.filter { $0.sourceRow.map(rows.contains) == true }
        guard commits.map(\.span) == bindings.flatMap({ $0.left.map(\.span) }),
              commits.map(\.name) == bindings.flatMap(\.names),
              commits.map(\.sourceRow) == bindings.flatMap({ binding in binding.registers.map { _ in Optional(binding.row) } }),
              commits.allSatisfy({ $0.value.type == .u64 }) else {
            throw C.Failure.semanticMismatch("\(name): restore destination commits missing, duplicated, reordered or wrong-width")
        }
        for binding in bindings {
            guard expected.rowVisits[binding.row] == 1 else {
                throw C.Failure.invalidContract("reference restore must occur once per complete scenario")
            }
            let values = actual.commits.filter { $0.sourceRow == binding.row }.map(\.value.bits)
            let wanted = try binding.registers.map { register -> UInt64 in
                guard let bits = expected.finalRegisters[register] else {
                    throw C.Failure.invalidContract("missing literal final register \(register)")
                }; return bits
            }
            guard values == wanted else {
                throw C.Failure.semanticMismatch("\(name): current-memory restore bits differ at row \(binding.row)")
            }
        }
    }

    enum Refusal { case syntax, contract, undefined, authority }
    static func refuse(_ wanted: Refusal, _ name: String, reason: String? = nil,
                       _ operation: () throws -> Void) throws {
        do { try operation() }
        catch let failure as C.Failure {
            let actual: String
            switch (wanted, failure) {
            case let (.syntax, .unsupportedSyntax(message)), let (.contract, .invalidContract(message)),
                 let (.undefined, .undefinedC(message)), let (.authority, .callAuthorityViolation(message)): actual = message
            default: throw C.Failure.invalidContract("\(name): wrong refusal category: \(failure)")
            }
            guard reason == nil || reason == actual else {
                throw C.Failure.invalidContract("\(name): wrong refusal reason: \(actual)")
            }
            return
        }
        throw C.Failure.invalidContract("\(name): malformed candidate was admitted")
    }

    /// Original fixture-specific refusal parity, not generic parser-unit credit.
    /// These are explicitly refusals, NEVER numerical mutation kills.
    static func rejectMalformedText(_ prepared: Prepared) throws {
        let original = prepared.candidate
        for kind in [C.EnvelopeKind.body, .metadata, .signature, .closingBrace] {
            var lines = original.lines
            lines.insert(.init(text: "oracle_unknown_helper();", source: nil, envelope: kind), at: 1)
            let wanted: Refusal = kind == .signature || kind == .closingBrace ? .contract : .syntax
            let reason = kind == .body ? "unknown executable helper oracle_unknown_helper"
                : kind == .metadata ? "executable metadata" : "function envelope changed"
            try refuse(wanted, "unsupported or misclassified executable \(kind)", reason: reason) {
                _ = try C.Program(lines: lines, contract: original.contract)
            }
        }
        for (text, reason) in [("int64_t double;", "expected scalar identifier, got double"),
                               ("if (false) { 1 = 2; }", "invalid assignment target"),
                               ("0: { }", "unsupported expression statement"),
                               ("return: { }", "unsupported expression :")] {
            var lines = original.lines
            lines.insert(.init(text: text, source: nil, envelope: .body), at: lines.count - 1)
            try refuse(.syntax, "complete-AST unreachable malformed syntax: \(text)", reason: reason) {
                _ = try C.Program(lines: lines, contract: original.contract)
            }
        }
        for row in original.contract.calls.keys.sorted() {
            let call = try callStatement(original, row: row)
            guard case let .call(_, result, _, _) = call.node, let result,
                  original.contract.calls[row]?.resultName == result else {
                throw C.Failure.invalidContract("original protected call result identity")
            }
            let index = original.tokens[call.span.first].line - 1
            let tokens = original.tokens[call.span.first..<call.span.last]
            guard tokens.count > 2, tokens[tokens.startIndex].text == result,
                  tokens[tokens.startIndex + 1].text == "=" else {
                throw C.Failure.invalidContract("protected call result assignment not present")
            }
            let offset = original.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
            let cut = tokens[tokens.startIndex + 1].byteOffset - offset + 1
            let bytes = Array(original.lines[index].text.utf8)
            var changed = original.lines
            changed[index] = .init(text: String(decoding: bytes.dropFirst(cut), as: UTF8.self),
                                  source: changed[index].source, envelope: changed[index].envelope)
            try refuse(.contract, "removing original call result row \(row)", reason: "missing/changed protected call \(row)") {
                _ = try C.Program(lines: changed, contract: original.contract)
            }
        }
        // Dead printed results remain dead even in an unreachable unused copy.
        // Exact call text alone is not sufficient to protect result authority.
        for row in original.contract.deadResults.sorted() {
            guard let result = original.contract.calls[row]?.resultName else {
                throw C.Failure.invalidContract("missing protected dead-result binding")
            }
            let fresh = freshName(original)
            var lines = original.lines
            lines.insert(.init(text: "if (false) { int64_t \(fresh) = \(result); }",
                               source: nil, envelope: .body), at: lines.count - 1)
            try refuse(.authority, "dead result acquired unreachable consumption at row \(row)",
                       reason: "baseline-dead call row \(row) read anywhere in complete AST") {
                _ = try C.Program(lines: lines, contract: original.contract)
            }
        }
        var lines = original.lines
        lines.insert(.init(text: "int64_t \(freshName(original)) = (int64_t)(uint64_t)0x8000000000000000;",
                           source: nil, envelope: .body), at: 1)
        let badCast = try C.Program(lines: lines, contract: original.contract)
        let input = try unique(prepared.scenarios.filter { $0.name == "zero-bypass-no-call-result" }, "original zero-call scenario")
        try refuse(.undefined, "high unsigned bits cannot acquire implementation-defined signed cast",
                   reason: "unsigned/signed conversion not representable") {
            _ = try C.Machine(program: badCast, scenario: C.scenario(input, contract: original.contract)).run()
        }
    }

    static func mutations(_ seed: RegionalCallSeed) throws {
        let prepared = try prepare(seed)
        var references: [String: M.Reference] = [:]
        var results: [String: O.Result] = [:]
        for scenario in prepared.scenarios {
            let result = try O.Machine(program: prepared.source, scenario: scenario).run()
            results[scenario.name] = result; references[scenario.name] = .init(result)
        }
        // These reviewed actual-AST controls retain the old STRIDE, stale prior
        // dynamic result, early/late X28 and CSEL obligations. Their additional
        // X64/joins/W32/CCMP controls strengthen rather than replace the originals.
        // Every receipt requires strict parse/type/authority, identical K, normal
        // return and a named numeric value/address divergence. No old selector is
        // called and no successful candidate execution is replayed here.
        let receipts = try M.upsampler(prepared.candidate, seed: seed, rows: prepared.fixture.rows,
            scenarios: prepared.scenarios, references: references)
        let required: Set<String> = ["upsampler-zero-component-pointer-stride",
            "upsampler-stale-prior-dynamic-round-result", "upsampler-missing-next-iteration-X28-import",
            "upsampler-X28-load-moved-across-opaque-call"]
        guard required.isSubset(of: Set(receipts.map(\.name))),
              receipts.count == (seed == .jinit ? 8 : 7),
              Set(receipts.map(\.name)).count == receipts.count,
              seed != .jinit || receipts.contains(where: { $0.name == "CSEL-stale-previous-writer-time-condition" }) else {
            throw C.Failure.invalidContract("missing original upsampler mutation obligation")
        }
        for receipt in receipts {
            print("REGIONAL_NATIVE_NUMERICAL_MUTATION name=\(receipt.name) scenario=\(receipt.scenario) observation=\(receipt.observation)")
        }
        try staleArgument(prepared, seed: seed, results: results)
        try wrongCounter(prepared, seed: seed, results: results)
        try wrongCCMPWriter(prepared, seed: seed, results: results)
    }

    /// The protected buffer argument3 is supplied by its actual parsed alias.
    /// Change only that alias's source-bound RHS to the earlier pre-K vertical
    /// sample. The post-K load remains present and all call bytes stay exact.
    static func staleArgument(_ prepared: Prepared, seed: RegionalCallSeed,
                              results: [String: O.Result]) throws {
        let program = prepared.candidate, first = seed == .jinit
        let before = first ? 77 : 78, after = first ? 189 : 133, buffer = first ? 192 : 136
        try decoded(prepared.source, row: before, mnemonic: "ldr", operands: "w9, [x19, #0x19c]")
        try decoded(prepared.source, row: after, mnemonic: "ldr", operands: "w3, [x19, #0x19c]")
        try decoded(prepared.source, row: buffer, mnemonic: "blr", operands: "x28")
        let previous = try scalar(program, row: before), current = try scalar(program, row: after)
        for (definition, row) in [(previous, before), (current, after)] {
            guard case let .load(type, _) = definition.right.node, type == .u32,
                  program.memorySites[definition.right.span] == .init(row: row, effectOrdinal: 0) else {
                throw C.Failure.invalidContract("stale-argument source load/effect identity")
            }
        }
        let binding = try argumentBinding(program, before: before, after: after, buffer: buffer)
        let changed: [C.TextLine]
        if let alias = binding.alias {
            let rhs = try renamed(program, span: alias.right.span, from: current.name, to: previous.name)
            changed = try replacing(program, span: alias.right.span, with: rhs)
        } else {
            // The approved direct-carrier control retains the real load and
            // protected call. An uninitialized declaration alone confers no value.
            let declared = try declaringCarrier(program, binding: binding)
            let declarationOnly = try C.Program(lines: declared, contract: program.contract)
            let same = try argumentBinding(declarationOnly, before: before, after: after, buffer: buffer)
            guard same.current.name == binding.current.name, (same.alias.map { _ in false } ?? true) else {
                throw C.Failure.invalidContract("declaration-only changed argument3 reaching-load binding")
            }
            changed = try overwriteLines(declarationOnly, binding: same, at: same.current.statement.span,
                row: after, width: .u32, target: same.current.name)
            let overwritten = try C.Program(lines: changed, contract: program.contract)
            try validateOverwrite(overwritten, original: declarationOnly, binding: same, after: after, buffer: buffer)
            try refuse(.contract, "approved stale overwrite binding",
                       reason: "argument3 stale binding: overwrite instead of reaching load row \(after)") {
                _ = try argumentBinding(overwritten, before: before, after: after, buffer: buffer)
            }
            try overwriteSiblingControls(declarationOnly, binding: same, before: before, after: after, buffer: buffer)
        }
        let name = "call-mutates-next-argument-and-loop-count"
        let pair = try runMutation("stale-call-input-alias", prepared: prepared, lines: changed,
            scenario: scenario(name, prepared), reference: reference(name, results))
        let actualCalls = calls(pair.actual), expectedCalls = pair.expected.calls
        try sameCallFacts(actualCalls, expectedCalls, row: buffer, argument: 3)
        let a = actualCalls.filter { $0.row == buffer }, e = expectedCalls.filter { $0.row == buffer }
        guard e.map({ $0.arguments[3].bits }) == [0xffff_fffd],
              a.map({ $0.arguments[3].bits }) == [2],
              memoryEvents(pair.actual) == memoryEvents(pair.expected),
              pair.actual.memory == pair.expected.memory.bytes else {
            throw C.Failure.semanticMismatch("stale-call-input-alias: exact post-K argument3 witness or unaffected effects differ")
        }
        print("REGIONAL_NATIVE_NUMERICAL_MUTATION name=stale-call-input-alias argument3=4294967293->2 normalReturn=true sameK=true")
    }

    static func wrongCounter(_ prepared: Prepared, seed: RegionalCallSeed,
                             results: [String: O.Result]) throws {
        let program = prepared.candidate, row = seed == .jinit ? 196 : 140
        try decoded(prepared.source, row: row, mnemonic: "add", operands: "x22, x22, #1")
        try sourceBytes(prepared.source, row: row, expected: "d6060091")
        let definition = try scalar(program, row: row)
        let additions = descendants(definition.right).filter { if case .binary("+", _, _) = $0.node { return true }; return false }
        let addition = try unique(additions, "original X22 increment expression")
        let instruction = try unique(prepared.fixture.function.instructions.filter {
            $0.source.address == prepared.fixture.rows[row].address
        }, "original X22 increment IR instruction")
        guard case let .binary(destination, operation, operand, amount) = instruction.operation,
              operation == "+", amount == .immediate(1),
              case let .register(destinationRegister, _) = destination, destinationRegister == "x22" else {
            throw C.Failure.invalidContract("original X22 increment source operand binding")
        }
        let expectedOperand: String
        let operandDefinitions: [Definition]
        let first = seed == .jinit, initial = first ? 62 : 63
        let entry = first ? 70 : 71, header = first ? 71 : 72, backedge = first ? 199 : 143
        if prepared.fixture.function.ssaInfo != nil {
            guard case let .register(register, version) = operand, register == "x22" else {
                throw C.Failure.invalidContract("SSA X22 increment source operand binding")
            }
            let bindings = prepared.fixture.function.nameBindings.filter {
                $0.target == .register(name: register, version: version)
            }
            guard bindings.count <= 1 else { throw C.Failure.invalidContract("ambiguous SSA X22 operand name binding") }
            expectedOperand = bindings.first?.name ?? operand.description
            try decoded(prepared.source, row: initial, mnemonic: "mov", operands: "x22, #0")
            try sourceBytes(prepared.source, row: initial, expected: "160080d2")
            operandDefinitions = try ssaCounterDefinitions(program, operand: expectedOperand,
                update: definition, initial: initial, entry: entry, backedge: backedge,
                headerAddress: prepared.source.rows[header].address,
                entryAddress: prepared.source.rows[entry].address,
                backedgeAddress: prepared.source.rows[backedge].address)
        } else {
            // Q9: native loop slots are not function register name bindings.
            // Their complete entry/backedge chain is a separate, exact proof.
            try decoded(prepared.source, row: initial, mnemonic: "mov", operands: "x22, #0")
            try sourceBytes(prepared.source, row: initial, expected: "160080d2")
            try decoded(prepared.source, row: backedge, mnemonic: "b.lt",
                        operands: first ? "0x000000000003af34" : "0x000000000003b894")
            try sourceBytes(prepared.source, row: backedge, expected: first ? "0bf0ff54" : "2bf7ff54")
            let seedInstruction = try unique(prepared.fixture.function.instructions.filter {
                $0.source.address == prepared.fixture.rows[initial].address
            }, "native X22 initialization IR row")
            guard case let .assign(seedDestination, seedValue) = seedInstruction.operation,
                  case let .register(register, _) = seedDestination, register == "x22",
                  seedValue == .immediate(0), operand == .unknown("unavailable_x22"),
                  try scalar(program, row: initial).name == seedDestination.description,
                  definition.name == destination.description else {
                throw C.Failure.invalidContract("native X22 seed/update full-width source binding")
            }
            let instructions = prepared.fixture.function.instructions
            let cfg = CFGBuilder.buildCFG(instructions: instructions)
            guard !cfg.hasUnresolvedTargets else { throw C.Failure.invalidContract("native X22 unresolved machine CFG binding") }
            let loopHeader = try unique(cfg.blocks.filter {
                instructions[$0.startIndex].source.address == prepared.fixture.rows[header].address
            }, "native X22 machine loop header")
            let predecessors = loopHeader.predecessors.map { instructions[cfg.blocks[$0].endIndex - 1].source.address }
            guard predecessors.count == 2,
                  Set(predecessors) == Set([prepared.fixture.rows[entry].address, prepared.fixture.rows[backedge].address]) else {
                throw C.Failure.invalidContract("native X22 machine entry/backedge binding")
            }
            expectedOperand = try nativeCounterOperand(program, addition: addition, update: definition,
                initial: initial, entry: entry, header: header, backedge: backedge)
            // The unchanged native proof has already authenticated this exact pair.
            operandDefinitions = try [entry, backedge].map { sourceRow in
                try unique(definitions(program, row: sourceRow).filter { $0.name == expectedOperand },
                    "native X22 selected source writer")
            }
        }
        let literal = try counterLiteral(program, addition: addition, row: row,
            operand: operandDefinitions)
        let name = "ordinary-store-aliases-loop-count"
        let pair = try runMutation("incorrect-loop-counter-step", prepared: prepared,
            lines: replacing(program, span: literal.span, with: "0x2"),
            scenario: scenario(name, prepared), reference: reference(name, results))
        let load = seed == .jinit ? 71 : 72
        guard loads(pair.expected, row: load).map(\.address) == [S.components + 0x24, S.components + 0x84],
              loads(pair.actual, row: load).map(\.address) == [S.components + 0x24],
              loads(pair.actual, row: load).map(\.bytes) == [4],
              pair.expected.calls.isEmpty, calls(pair.actual).isEmpty,
              pair.actual.memory != pair.expected.memory.bytes else {
            throw C.Failure.semanticMismatch("incorrect-loop-counter-step: required skipped-component address/final-byte witness absent")
        }
        print("REGIONAL_NATIVE_NUMERICAL_MUTATION name=incorrect-loop-counter-step X22Step=1->2 componentVisits=2->1 normalReturn=true sameK=true")
    }

    static let ccName = "same-K-CCMP-writer-swaps-two-original-component-paths"
    static func sameCallCCMP(_ seed: RegionalCallSeed) throws -> O.Scenario {
        // Global grid 4x2; component0 is exact H2V1 and component1 integral4x1.
        // Inverting only CMP(2*h,maxH) moves the one original SIMD129 callback
        // from component0 to component1. Its order/result/arguments remain the
        // same; the method-pointer outputs change. J12 has the analogous no-call
        // paths. This avoids miscrediting OR->AND's wrong-script rejection.
        try S.make(seed: seed, name: ccName, paths: [.h2v1, .integral],
            simdResults: [0x8000_0000_0000_0001], componentTransform: { index, component in
                component.h = index == 0 ? 2 : 1; component.v = 2
            }, change: { scenario in
                try scenario.memory.store(.init(address: S.context + 0x198, bytes: 4, bits: 4))
                try scenario.memory.store(.init(address: S.context + 0x19c, bytes: 4, bits: 2))
            })
    }
    static func requireSameCallSource(_ source: O.Result, seed: RegionalCallSeed) throws {
        let row = seed == .jinit ? 93 : 94
        guard source.branches.filter({ $0.row == row }).map(\.taken) == [true, false],
              source.calls.map(\.row) == (seed == .jinit ? [129] : []),
              try source.memory.load(S.upsampler + 0x98, bytes: 8) == (seed == .jinit ? 0x57f50 : 0x3bc8c),
              try source.memory.load(S.upsampler + 0xa0, bytes: 8) == (seed == .jinit ? 0x3b67c : 0x3bf58) else {
            throw C.Failure.invalidContract("literal same-K CCMP input/path proof differs")
        }
    }
    static func wrongCCMPWriter(_ prepared: Prepared, seed: RegionalCallSeed,
                                results: [String: O.Result]) throws {
        let program = prepared.candidate, shift = seed == .jinit ? 0 : 1
        try decoded(prepared.source, row: 75 + shift, mnemonic: "sdiv", operands: "w8, w8, w12")
        try decoded(prepared.source, row: 76 + shift, mnemonic: "ldr", operands: "w10, [x19, #0x198]")
        try decoded(prepared.source, row: 77 + shift, mnemonic: "ldr", operands: "w9, [x19, #0x19c]")
        try decoded(prepared.source, row: 90 + shift, mnemonic: "lsl", operands: "w12, w11, #1")
        try decoded(prepared.source, row: 91 + shift, mnemonic: "cmp", operands: "w12, w10")
        try decoded(prepared.source, row: 92 + shift, mnemonic: "ccmp", operands: "w8, w9, #0, eq")
        try sourceBytes(prepared.source, row: 91 + shift, expected: "9f010a6b")
        try sourceBytes(prepared.source, row: 92 + shift, expected: "0001497a")
        try decoded(prepared.source, row: 93 + shift, mnemonic: "b.eq",
                    operands: seed == .jinit ? "0x000000000003afec" : "0x000000000003b934")
        let vertical = try scalar(program, row: 75 + shift), maxH = try scalar(program, row: 76 + shift)
        let maxV = try scalar(program, row: 77 + shift), doubledH = try scalar(program, row: 90 + shift)
        let branch = try unique(statements(program.root).compactMap { statement -> C.Expression? in
            guard (try? program.row(at: statement.span)) == 93 + shift,
                  case let .conditional(condition, _, _) = statement.node else { return nil }; return condition
        }, "actual first CCMP consumer")
        // CCMP ..., #0, eq yields Z = firstEqual && secondEqual.
        // Its inverse is !firstEqual || !secondEqual. Flipping only the
        // first equality (or inequality in the inverse) is the SAME mutant.
        let firstComparison = try ccmpFirstComparison(program, condition: branch,
            row: 93 + shift, doubled: doubledH, maxH: maxH, vertical: vertical, maxV: maxV)
        guard case let .binary(comparison, lhs, rhs) = firstComparison.node else {
            throw C.Failure.invalidContract("CCMP first comparison disappeared")
        }
        let expected = try reference(ccName, results)
        try requireSameCallSource(expected, seed: seed)
        let inverted = comparison == "==" ? "!=" : "=="
        let replacement = "(\(try text(program, lhs.span)) \(inverted) \(try text(program, rhs.span)))"
        let pair = try runMutation("CCMP-wrong-first-writer-polarity-same-K", prepared: prepared,
            lines: replacing(program, span: firstComparison.span, with: replacement),
            scenario: scenario(ccName, prepared), reference: expected)
        try sameCallFacts(calls(pair.actual), expected.calls)
        let originalFirst = try expected.memory.load(S.upsampler + 0x98, bytes: 8)
        let originalSecond = try expected.memory.load(S.upsampler + 0xa0, bytes: 8)
        let memory = O.Memory(bytes: pair.actual.memory)
        guard originalFirst != originalSecond,
              try memory.load(S.upsampler + 0x98, bytes: 8) == originalSecond,
              try memory.load(S.upsampler + 0xa0, bytes: 8) == originalFirst else {
            throw C.Failure.semanticMismatch("CCMP same-K mutation did not swap the two named method-pointer values")
        }
        print("REGIONAL_NATIVE_NUMERICAL_MUTATION name=CCMP-wrong-first-writer-polarity-same-K methodPointerSlots=0x98,0xa0 normalReturn=true sameK=true")
    }

    static func runMutation(_ name: String, prepared: Prepared, lines: [C.TextLine],
                            scenario: O.Scenario, reference: O.Result) throws -> (actual: C.Result, expected: O.Result) {
        let original = prepared.candidate
        // The SAME immutable source contract validates every changed candidate.
        // Extra/missing calls, changed result authority or exterior text cannot
        // become numeric kills. Optional input-carrier assertions alone are
        // removed so the actual wrong carrier may be observed AFTER normal exit.
        let mutant = try C.Program(lines: lines, contract: original.contract)
        let input = try C.scenario(scenario, contract: original.contract)
        let observationInput = C.Scenario(name: input.name, inputs: input.inputs, memory: input.memory,
            responses: input.responses.map { .init(row: $0.row, result: $0.result, writes: $0.writes,
                                                   expectedArguments: nil, expectedControl: nil) })
        let actual = try C.Machine(program: mutant, scenario: observationInput).run()
        guard actual.returned, reference.returned, actual.consumedResponses == input.responses.count,
              actual.terminal?.bits == reference.returnBits else {
            throw C.Failure.invalidContract("\(name): incomplete K script, non-normal exit, or changed terminal")
        }
        do {
            try C.compare(actual, events: reference.events, memory: reference.memory.bytes,
                returned: reference.returned, terminal: reference.returnBits, contract: original.contract, name: name)
        } catch let failure as C.Failure {
            guard case let .semanticMismatch(observation) = failure, observation.hasPrefix(name + ":") else { throw failure }
            return (actual, reference)
        }
        throw C.Failure.invalidContract("\(name): semantic mutant survived")
    }

    static func sameCallFacts(_ actual: [C.CallEvent], _ expected: [O.Call],
                              row: Int? = nil, argument: Int? = nil) throws {
        guard actual.count == expected.count else { throw C.Failure.semanticMismatch("mutation changed call count") }
        for (a, e) in zip(actual, expected) {
            guard a.row == e.row, a.occurrence == e.occurrence, a.target == e.target,
                  a.result == e.result, a.writes.map({ O.Write(address: $0.address, bytes: $0.bytes, bits: $0.bits) }) == e.writes,
                  a.control.map({ O.Carrier(register: $0.register, width: $0.width, bits: $0.bits) }) == e.control,
                  a.arguments.count == e.arguments.count else {
                throw C.Failure.semanticMismatch("mutation changed unrelated protected call/K facts")
            }
            for (index, pair) in zip(a.arguments, e.arguments).enumerated() {
                guard pair.0.register == pair.1.register, pair.0.width == pair.1.width,
                      (a.row == row && index == argument) || pair.0.bits == pair.1.bits else {
                    throw C.Failure.semanticMismatch("mutation changed an unrelated call carrier")
                }
            }
        }
    }
    static func calls(_ actual: C.Result) -> [C.CallEvent] {
        actual.events.compactMap { if case let .call(call) = $0 { return call }; return nil }
    }
    static func memoryEvents(_ actual: C.Result) -> [O.Event] {
        actual.events.compactMap {
            switch $0 {
            case let .load(site, _, address, bytes, bits): return .load(row: site.row, address: address, bytes: bytes, bits: bits)
            case let .store(site, _, address, bytes, bits): return .store(row: site.row, address: address, bytes: bytes, bits: bits)
            default: return nil
            }
        }
    }
    static func memoryEvents(_ expected: O.Result) -> [O.Event] {
        expected.events.filter { if case .call = $0 { return false }; return true }
    }
    static func loads(_ actual: C.Result, row: Int) -> [O.Write] {
        memoryEvents(actual).compactMap { if case let .load(site, address, bytes, bits) = $0, site == row {
            return .init(address: address, bytes: bytes, bits: bits)
        }; return nil }
    }
    static func loads(_ expected: O.Result, row: Int) -> [O.Write] {
        expected.events.compactMap { if case let .load(site, address, bytes, bits) = $0, site == row {
            return .init(address: address, bytes: bytes, bits: bits)
        }; return nil }
    }
    static func scenario(_ name: String, _ prepared: Prepared) throws -> O.Scenario {
        try unique(prepared.scenarios.filter { $0.name == name }, "unchanged scenario \(name)")
    }
    static func reference(_ name: String, _ values: [String: O.Result]) throws -> O.Result {
        guard let result = values[name] else { throw C.Failure.invalidContract("missing independent source result \(name)") }; return result
    }
    static func sourceBytes(_ source: O.Program, row: Int, expected: String) throws {
        guard source.rows.indices.contains(row),
              source.rows[row].bytes.lowercased().filter({ !$0.isWhitespace }) == expected else {
            throw C.Failure.invalidContract("mutation source byte identity at row \(row)")
        }
    }
    static func decoded(_ source: O.Program, row: Int, mnemonic: String, operands: String) throws {
        guard source.rows.indices.contains(row), source.rows[row].mnemonic == mnemonic,
              source.rows[row].operands == operands else { throw C.Failure.invalidContract("decoded mutation identity at row \(row)") }
    }
    struct ArgumentBinding {
        let previous: Definition
        let current: Definition
        let call: C.Statement
        let alias: Definition?
    }
    static func codeIndex(_ program: C.Program, statement: C.Statement) throws -> Int {
        try unique(program.code.indices.filter { program.code[$0].span == statement.span && {
            switch program.code[$0].node { case .assign, .call: return true; default: return false }
        }($0) }, "executable definition/use span")
    }
    /// Backward finite CFG closure stops at the first actual write on EACH
    /// predecessor. Entry/undefined and declaration resets are definitions too;
    /// they cannot be discarded merely because another path has the right row.
    static func controlFlow(_ program: C.Program) throws -> (predecessors: [Int: Set<Int>], reachable: Set<Int>) {
        var predecessors: [Int: Set<Int>] = [:]
        var reachable: Set<Int> = [], pending = [0]
        func successors(_ i: Int) throws -> [Int] {
            switch program.code[i].node {
            case let .branch(_, a, b): return [a, b]
            case let .jump(target): return [target]
            case .returned, .unavailableReturn: return []
            case .unresolved: throw C.Failure.invalidContract("argument3 unresolved CFG edge")
            default: return [i + 1]
            }
        }
        while let i = pending.popLast() {
            guard program.code.indices.contains(i), reachable.insert(i).inserted else { continue }
            for next in try successors(i) {
                guard next >= 0, next <= program.code.count else { throw C.Failure.invalidContract("argument3 invalid CFG target") }
                predecessors[next, default: []].insert(i); pending.append(next)
            }
        }
        return (predecessors, reachable)
    }
    static func instructionWrites(_ instruction: C.Instruction, name: String) -> Bool {
        func updates(_ e: C.Expression) -> Bool {
            descendants(e).contains { if case let .update(n, _, _) = $0.node { return n == name }; return false }
        }
        func writes(_ instruction: C.Instruction) -> Bool {
            switch instruction.node {
            case let .declaration(n, initializer): return n == name || (initializer.map(updates) ?? false)
            case let .assign(left, right):
                return left.contains { if case let .name(n) = $0.node { return n == name }; return updates($0) }
                    || right.contains(where: updates)
            case let .call(_, result, control, arguments):
                return result == name || (control.map(updates) ?? false) || arguments.contains(where: updates)
            case let .update(e), let .branch(e, _, _): return updates(e)
            case let .returned(e): return e.map(updates) ?? false
            default: return false
            }
        }
        return writes(instruction)
    }
    static func reaching(_ program: C.Program, name: String, before use: Int) throws -> Set<Int> {
        let graph = try controlFlow(program), predecessors = graph.predecessors, reachable = graph.reachable
        var pending: [Int] = []
        guard reachable.contains(use) else { throw C.Failure.invalidContract("argument3 unreachable use") }
        var result: Set<Int> = [], seen: Set<Int> = []
        pending = Array(predecessors[use, default: []])
        if use == 0 || pending.isEmpty { result.insert(-1) }
        while let i = pending.popLast() {
            guard seen.insert(i).inserted else { continue }
            if instructionWrites(program.code[i], name: name) { result.insert(i); continue }
            let prior = predecessors[i, default: []]
            if i == 0 || prior.isEmpty { result.insert(-1) }
            pending += prior
        }
        guard !result.isEmpty else { throw C.Failure.invalidContract("argument3 no finite reaching definition") }
        return result
    }
    static func transportedName(_ program: C.Program, _ e: C.Expression) -> String? {
        switch e.node {
        case let .name(name): return name
        case let .cast(type, child) where !type.pointer && type.width == 32:
            guard let source = program.expressionTypes[child.span], !source.pointer, source.width == 32 else { return nil }
            return transportedName(program, child)
        case let .select(_, positive, _) where program.representationCasts.contains(e.span):
            guard program.expressionTypes[e.span] == .i32 else { return nil }
            return transportedName(program, positive)
        default: return nil
        }
    }
    static func argumentBinding(_ program: C.Program, before: Int, after: Int, buffer: Int) throws -> ArgumentBinding {
        let previous = try scalar(program, row: before)
        let candidates = definitions(program, row: after).filter {
            guard case let .load(type, _) = $0.right.node else { return false }
            return type == .u32 && program.memorySites[$0.right.span] == .init(row: after, effectOrdinal: 0)
        }
        let current = try unique(candidates, "argument3 exact post-call load definition")
        guard program.symbols[current.name]?.type == .u32, program.symbols[previous.name]?.type == .u32,
              case let .load(type, _) = previous.right.node, type == .u32,
              program.memorySites[previous.right.span] == .init(row: before, effectOrdinal: 0) else {
            throw C.Failure.invalidContract("argument3 wrong carrier width or source load binding")
        }
        let call = try callStatement(program, row: buffer)
        guard case let .call(_, _, _, arguments) = call.node, arguments.count == 4,
              let consumed = transportedName(program, arguments[3]) else {
            throw C.Failure.invalidContract("argument3 exact consumed carrier binding")
        }
        let loadIndex = try codeIndex(program, statement: current.statement)
        let callIndex = try codeIndex(program, statement: call)
        guard try reaching(program, name: previous.name, before: loadIndex) == [codeIndex(program, statement: previous.statement)] else {
            throw C.Failure.invalidContract("argument3 pre-call sample has stale/partial reaching definition")
        }
        let alias: Definition?
        let use: Int
        if consumed == current.name { alias = nil; use = callIndex }
        else {
            let definition = try unique(definitions(program, row: buffer).filter { $0.name == consumed }, "argument3 source-bound alias")
            guard transportedName(program, definition.right) == current.name else {
                throw C.Failure.invalidContract("argument3 alias uses different reaching definition")
            }
            let index = try codeIndex(program, statement: definition.statement)
            guard try reaching(program, name: consumed, before: callIndex) == [index] else {
                throw C.Failure.invalidContract("argument3 alias stale/partial path binding")
            }
            alias = definition; use = index
        }
        guard try reaching(program, name: current.name, before: use) == [loadIndex] else {
            throw C.Failure.invalidContract("argument3 stale binding: overwrite instead of reaching load row \(after)")
        }
        return .init(previous: previous, current: current, call: call, alias: alias)
    }
    static func declaringCarrier(_ program: C.Program, binding: ArgumentBinding) throws -> [C.TextLine] {
        guard let symbol = program.symbols[binding.current.name], symbol.type == .u32, !symbol.external else {
            throw C.Failure.invalidContract("argument3 declaration carrier width binding")
        }
        if symbol.declared { return program.lines }
        var lines = program.lines
        lines.insert(.init(text: "uint32_t \(binding.current.name);", source: nil, envelope: .body), at: 1)
        return lines
    }
    static func overwriteLines(_ program: C.Program, binding: ArgumentBinding, at span: C.Span,
                               row: Int, width: C.CType, target: String) throws -> [C.TextLine] {
        guard row == (try program.row(at: binding.current.statement.span)), width == .u32,
              target == binding.current.name else {
            throw C.Failure.invalidContract("argument3 overwrite row/width/reaching-definition binding")
        }
        let anchor = program.tokens[span.first].line - 1
        guard span == binding.current.statement.span else {
            throw C.Failure.invalidContract("argument3 overwrite must follow exact reaching load before call")
        }
        var lines = program.lines
        lines.insert(.init(text: "\(target) = \(binding.previous.name);", source: lines[anchor].source, envelope: .body), at: anchor + 1)
        return lines
    }
    static func validateOverwrite(_ changed: C.Program, original: C.Program, binding: ArgumentBinding,
                                  after: Int, buffer: Int) throws {
        let carrier = binding.current.name, previous = binding.previous.name
        guard changed.symbols[carrier]?.type == .u32 else {
            throw C.Failure.invalidContract("argument3 overwrite wrong width binding")
        }
        let writes = statements(changed.root).compactMap { statement -> Definition? in
            guard case let .assign(left, right) = statement.node, left.count == 1, right.count == 1,
                  case let .name(name) = left[0].node, name == carrier else { return nil }
            return .init(statement: statement, left: left[0], right: right[0], name: name)
        }
        let load = try unique(writes.filter {
            if case let .load(type, _) = $0.right.node {
                return type == .u32 && changed.memorySites[$0.right.span] == .init(row: after, effectOrdinal: 0)
            }; return false
        }, "argument3 overwrite preserved real load")
        let overwrite = try unique(writes.filter { $0.statement.span != load.statement.span }, "argument3 exactly one overwrite")
        guard (try changed.row(at: overwrite.statement.span)) == after else {
            throw C.Failure.invalidContract("argument3 overwrite wrong source row binding")
        }
        guard case let .name(rhs) = overwrite.right.node, rhs == previous,
              changed.expressionTypes[overwrite.right.span] == .u32 else {
            throw C.Failure.invalidContract("argument3 overwrite different reaching definition binding")
        }
        let call = try callStatement(changed, row: buffer)
        let loadIndex = try codeIndex(changed, statement: load.statement)
        let writeIndex = try codeIndex(changed, statement: overwrite.statement)
        let callIndex = try codeIndex(changed, statement: call)
        guard try reaching(changed, name: carrier, before: writeIndex) == [loadIndex],
              try reaching(changed, name: carrier, before: callIndex) == [writeIndex] else {
            throw C.Failure.invalidContract("argument3 overwrite not between reaching load and call on every path")
        }
        let old = try scalar(changed, row: try original.row(at: binding.previous.statement.span))
        let oldIndex = try codeIndex(changed, statement: old.statement)
        guard try reaching(changed, name: previous, before: writeIndex) == [oldIndex] else {
            throw C.Failure.invalidContract("argument3 overwrite different reaching definition binding")
        }
        // No source authority or effect changes hide behind the scalar control.
        guard try text(changed, load.statement.span) == text(original, binding.current.statement.span),
              try text(changed, call.span) == text(original, binding.call.span),
              changed.memorySites.count == original.memorySites.count else {
            throw C.Failure.invalidContract("argument3 overwrite changed real load/call/effect binding")
        }
    }
    static func overwriteSiblingControls(_ program: C.Program, binding: ArgumentBinding,
                                         before: Int, after: Int, buffer: Int) throws {
        let loadLine = program.tokens[binding.current.statement.span.first].line - 1
        let callLine = program.tokens[binding.call.span.first].line - 1
        let cases: [(Int, Int, Bool, String, String)] = [
            (loadLine, before, false, binding.previous.name, "argument3 overwrite wrong source row binding"),
            (callLine + 1, buffer, false, binding.previous.name, "argument3 overwrite wrong source row binding"),
            (loadLine + 1, after, true, binding.previous.name, "argument3 overwrite wrong width binding"),
            (loadLine + 1, after, false, binding.current.name, "argument3 overwrite different reaching definition binding"),
            (loadLine, after, false, binding.previous.name, "argument3 overwrite not between reaching load and call on every path")]
        for (position, row, wide, rhs, reason) in cases {
            var lines = program.lines
            if wide {
                let declaration = "uint32_t \(binding.current.name);"
                let index = try unique(lines.indices.filter { lines[$0].text == declaration }, "argument3 same declaration for width sibling")
                lines[index] = .init(text: "uint64_t \(binding.current.name);", source: lines[index].source,
                                    envelope: lines[index].envelope, phiEdge: lines[index].phiEdge)
            }
            let source = try unique(program.contract.rowsByAddress.filter { $0.value == row }.map(\.key), "argument3 sibling source row")
            lines.insert(.init(text: "\(binding.current.name) = \(rhs);", source: source, envelope: .body), at: position)
            // Parse/type/contract success is a precondition, NEVER refusal credit.
            let sibling = try C.Program(lines: lines, contract: program.contract)
            try refuse(.contract, "argument3 sibling overwrite refusal", reason: reason) {
                try validateOverwrite(sibling, original: program, binding: binding, after: after, buffer: buffer)
            }
        }
    }
    static func literalArgumentProgram(_ variant: String = "direct") throws -> C.Program {
        let callText = "buffer(0, 0, 0, carrier);"
        let contract = C.Contract(signature: "void argument_control() {",
            inputs: [.init(name: "choice", type: .u32, entrySlot: 0)], fields: [],
            calls: [4: .init(row: 4, payload: callText, target: "buffer", resultName: nil,
                            control: nil, arguments: (0..<4).map { .init(register: $0, width: 32) })],
            exterior: [:], terminalRow: 5, terminalPayload: "return;", terminalName: nil, returnType: nil,
            rowsByAddress: Dictionary(uniqueKeysWithValues: (0...5).map { (UInt64(0x1000 + 4 * $0), $0) }),
            allowedLabels: [], memoryEffects: [0: [.init(loading: true, bytes: 4)],
                (variant == "wrong-row" ? 3 : 2): [.init(loading: true, bytes: 4)]],
            helpers: [:], deadResults: [], permissions: [])
        var lines: [C.TextLine] = [.init(text: contract.signature, source: nil, envelope: .signature),
            .init(text: "uint32_t carrier;", source: nil, envelope: .body),
            .init(text: "previous = *(uint32_t *)((uint64_t)0x1000);", source: 0x1000, envelope: .body)]
        if variant == "partial" { lines.append(.init(text: "if (choice) {", source: 0x1004, envelope: .body)) }
        lines.append(.init(text: "carrier = *(uint32_t *)((uint64_t)0x1004);", source: variant == "wrong-row" ? 0x100c : 0x1008, envelope: .body))
        if variant == "partial" { lines.append(.init(text: "}", source: nil, envelope: .body)) }
        if variant == "stale" { lines.append(.init(text: "carrier = previous;", source: 0x100c, envelope: .body)) }
        if variant == "forged-name" {
            lines.append(.init(text: "uint32_t forged; forged = 0;", source: 0x100c, envelope: .body))
        }
        // A forged call spelling gets its own frozen literal payload so the
        // binding refusal, not envelope/parsing, is the negative's witness.
        if variant == "forged-name" {
            let changed = C.Contract(signature: contract.signature, inputs: contract.inputs, fields: [],
                calls: [4: .init(row: 4, payload: "buffer(0, 0, 0, forged);", target: "buffer", resultName: nil,
                                control: nil, arguments: (0..<4).map { .init(register: $0, width: 32) })],
                exterior: [:], terminalRow: 5, terminalPayload: "return;", terminalName: nil, returnType: nil,
                rowsByAddress: contract.rowsByAddress, allowedLabels: [], memoryEffects: contract.memoryEffects,
                helpers: [:], deadResults: [], permissions: [])
            lines += [.init(text: "buffer(0, 0, 0, forged);", source: 0x1010, envelope: .body),
                      .init(text: "return;", source: 0x1014, envelope: .body),
                      .init(text: "}", source: nil, envelope: .closingBrace)]
            return try C.Program(lines: lines, contract: changed)
        }
        lines += [.init(text: callText, source: 0x1010, envelope: .body),
                  .init(text: "return;", source: 0x1014, envelope: .body),
                  .init(text: "}", source: nil, envelope: .closingBrace)]
        return try C.Program(lines: lines, contract: contract)
    }
    static func argumentBindingControls() throws {
        let original = try literalArgumentProgram()
        _ = try argumentBinding(original, before: 0, after: 2, buffer: 4)
        for (variant, reason) in [
            ("wrong-row", "argument3 exact post-call load definition: expected one actual AST binding, found 0"),
            ("stale", "argument3 stale binding: overwrite instead of reaching load row 2"),
            ("partial", "argument3 stale binding: overwrite instead of reaching load row 2"),
            ("forged-name", "argument3 source-bound alias: expected one actual AST binding, found 0")] {
            let p = try literalArgumentProgram(variant)
            try refuse(.contract, "literal argument3 \(variant)", reason: reason) {
                _ = try argumentBinding(p, before: 0, after: 2, buffer: 4)
            }
        }
    }
    static func argumentOverwriteControls() throws {
        let original = try literalArgumentProgram()
        let binding = try argumentBinding(original, before: 0, after: 2, buffer: 4)
        let lines = try overwriteLines(original, binding: binding, at: binding.current.statement.span,
            row: 2, width: .u32, target: binding.current.name)
        let mutated = try C.Program(lines: lines, contract: original.contract)
        try validateOverwrite(mutated, original: original, binding: binding, after: 2, buffer: 4)
        try refuse(.contract, "literal approved stale overwrite",
                   reason: "argument3 stale binding: overwrite instead of reaching load row 2") {
            _ = try argumentBinding(mutated, before: 0, after: 2, buffer: 4)
        }
        try overwriteSiblingControls(original, binding: binding, before: 0, after: 2, buffer: 4)
    }
    /// Literal AST adversaries supplement, never replace, the three complete
    /// fixture numerical witnesses. They execute in either mode without a renderer.
    static func literalProgram(_ body: [String], sourceRows: [Int: Int] = [:]) throws -> C.Program {
        let rows = Dictionary(uniqueKeysWithValues: (0...body.count).map { (UInt64(0x1000 + 4 * $0), $0) })
        let contract = C.Contract(signature: "void literal_control() {", inputs: [], fields: [],
            calls: [:], exterior: [:], terminalRow: body.count, terminalPayload: "return;",
            terminalName: nil, returnType: nil, rowsByAddress: rows, allowedLabels: [],
            memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        let lines: [C.TextLine] = [.init(text: contract.signature, source: nil, envelope: .signature)]
            + body.enumerated().map { .init(text: $0.element, source: UInt64(0x1000 + 4 * (sourceRows[$0.offset] ?? $0.offset)), envelope: .body) }
            + [.init(text: "return;", source: UInt64(0x1000 + 4 * body.count), envelope: .body),
               .init(text: "}", source: nil, envelope: .closingBrace)]
        return try C.Program(lines: lines, contract: contract)
    }
    static func counterBindingControls() throws {
        try nativeCounterControls()
        try ssaCounterControls()
        func expression(_ declaration: String, _ expression: String) throws -> (C.Program, C.Expression) {
            let p = try literalProgram([declaration, "uint64_t other; other = 0x0;", "result = " + expression + ";"])
            return (p, try scalar(p, row: 2).right)
        }
        for rhs in ["counter + 0x1", "counter + (uint64_t)0x1"] {
            let (p, e) = try expression("uint64_t counter; counter = 0x0;", rhs)
            let literal = try counterLiteral(p, addition: e, row: 2, operand: [try scalar(p, row: 0)])
            guard case let .literal(value) = literal.node, value.bits == 1 else {
                throw C.Failure.invalidContract("literal counter control lost exact one")
            }
        }
        let negatives = [
            ("int32_t counter; counter = 0x0;", "counter + 0x1", "original X22 +1 operand/width binding"),
            ("uint64_t counter; counter = 0x0;", "other + 0x1", "original X22 +1 wrong reaching operand binding"),
            ("counter = (uint64_t)0x0;", "counter + 0x1", "X22 increment requires declared unsigned64 source carrier binding"),
            ("int32_t counter; counter = 0x0;", "(uint64_t)counter + (uint64_t)0x1", "X22 increment requires declared unsigned64 source carrier binding"),
            ("int64_t counter; counter = 0x0;", "(uint64_t)counter + (uint64_t)0x1", "X22 increment requires declared unsigned64 source carrier binding"),
            ("uint64_t counter; counter = 0x0;", "counter + 0x2", "original X22 +1 literal binding")]
        for (declaration, rhs, reason) in negatives {
            let (p, e) = try expression(declaration, rhs)
            try refuse(.contract, "literal X22 refusal", reason: reason) {
                _ = try counterLiteral(p, addition: e, row: 2, operand: [try scalar(p, row: 0)])
            }
        }
    }
    static func ccmpBindingControls() throws {
        func expression(_ firstType: String, _ secondType: String, _ predicate: String) throws -> (C.Program, C.Expression) {
            let p = try literalProgram(["\(firstType) doubled; doubled = 2; \(secondType) maxH; maxH = 4;",
                "int32_t vertical; vertical = 2; uint32_t maxV; maxV = 2;",
                "condition = \(predicate);"])
            return (p, try scalar(p, row: 2).right)
        }
        for predicate in ["(doubled == maxH) && (vertical == maxV)", "(doubled != maxH) || (vertical != maxV)"] {
            let (p, e) = try expression("uint32_t", "uint32_t", predicate)
            _ = try ccmpFirstComparison(p, condition: e, row: 2,
                doubled: namedDefinition(p, row: 0, name: "doubled"),
                maxH: namedDefinition(p, row: 0, name: "maxH"),
                vertical: namedDefinition(p, row: 1, name: "vertical"),
                maxV: namedDefinition(p, row: 1, name: "maxV"))
        }
        let negatives = [
            ("uint32_t", "uint32_t", "(doubled == maxH) || (vertical == maxV)"),
            ("uint32_t", "uint32_t", "(doubled != maxH) && (vertical != maxV)"),
            ("uint32_t", "uint32_t", "(doubled == maxV) && (vertical == maxH)"),
            ("uint64_t", "uint32_t", "(doubled == maxH) && (vertical == maxV)"),
            ("int32_t", "int32_t", "(doubled == maxH) && (vertical == maxV)")]
        for (a, b, predicate) in negatives {
            let (p, e) = try expression(a, b, predicate)
            try refuse(.contract, "literal CCMP refusal", reason: "CCMP literal W32 CMP/CCMP operands and false NZCV arm binding") {
                _ = try ccmpFirstComparison(p, condition: e, row: 2,
                    doubled: namedDefinition(p, row: 0, name: "doubled"),
                    maxH: namedDefinition(p, row: 0, name: "maxH"),
                    vertical: namedDefinition(p, row: 1, name: "vertical"),
                    maxV: namedDefinition(p, row: 1, name: "maxV"))
            }
        }
    }
    /// Literal component controls for source-selected phi copies. These do not
    /// claim that an actual renderer emitted the authored lines.
    static func ssaCounterControls() throws {
        func candidate(_ variant: String) throws -> C.Program {
            var body = ["seed = (uint64_t)0;", "uint64_t slot; slot = seed;", "while (true) {",
                "result = slot + (uint64_t)1;", "if (true) { break; } else {",
                "slot = result;", "}", "}"]
            var entryLine = 1
            let copyLine = 5
            if variant.hasPrefix("snapshot") {
                body[0] += " uint64_t backSnapshot;"
                body[1] = "uint64_t slot; entrySnapshot = seed; slot = entrySnapshot;"
                body[5] = "backSnapshot = result; slot = backSnapshot;"
            }
            if variant == "snapshot-overwrite" {
                body[5] = "backSnapshot = result; backSnapshot = seed; slot = backSnapshot;"
            }
            if variant == "snapshot-wrong-input" {
                body[5] = "backSnapshot = seed; slot = backSnapshot;"
            }
            if variant == "snapshot-bypass" {
                // The final-copy inner cycle can execute without repeating the
                // snapshot. Static reaching still sees its one exact writer.
                body[5] = "backSnapshot = result; while (true) { slot = backSnapshot; if (true) { break; } }"
            }
            if variant == "partial-copy" {
                body[5] = "if (true) { slot = result; }"
            }
            if variant == "entry-from-update" {
                body = [body[0], "uint64_t slot; while (true) {", "slot = seed;",
                    "result = slot + (uint64_t)1;", body[4], body[5], "}", "}"]
                entryLine = 2
            }
            if variant == "wrong-input" { body[5] = "slot = seed;" }
            let base = try literalProgram(body, sourceRows: [entryLine: 1, copyLine: 4])
            var lines = base.lines
            for (line, predecessor) in [(entryLine, UInt64(0x1004)), (copyLine, UInt64(0x1010))] {
                let index = line + 1
                lines[index] = .init(text: lines[index].text, source: nil, envelope: .body,
                    phiEdge: .init(blockAddress: 0x1008, predecessorAddress: predecessor))
            }
            if variant == "wrong-edge" {
                lines[copyLine + 1].phiEdge = .init(blockAddress: 0x100c, predecessorAddress: 0x1010)
            }
            if variant == "missing-edge" {
                lines[copyLine + 1] = .init(text: lines[copyLine + 1].text,
                    source: 0x1010, envelope: .body)
            }
            return try C.Program(lines: lines, contract: base.contract)
        }
        func bind(_ program: C.Program) throws {
            let update = try scalar(program, row: 3)
            let copies = try ssaCounterDefinitions(program, operand: "slot", update: update,
                initial: 0, entry: 1, backedge: 4, headerAddress: 0x1008,
                entryAddress: 0x1004, backedgeAddress: 0x1010)
            _ = try counterLiteral(program, addition: update.right, row: 3, operand: copies)
        }
        try bind(candidate("direct"))
        try bind(candidate("snapshot"))
        for variant in ["wrong-edge", "missing-edge", "wrong-input", "partial-copy",
                        "entry-from-update", "snapshot-overwrite", "snapshot-wrong-input",
                        "snapshot-bypass"] {
            let program = try candidate(variant)
            let phaseReasons = [
                "partial-copy": "SSA X22 iteration bypasses backedge copy",
                "entry-from-update": "SSA X22 entry copy reachable from update",
                "snapshot-bypass": "SSA X22 snapshot copy window bypass"]
            if let reason = phaseReasons[variant] {
                try refuse(.contract, "SSA literal copy \(variant)", reason: reason) { try bind(program) }
            } else {
                do {
                    try bind(program)
                    throw C.Failure.semanticMismatch("SSA literal copy control accepted \(variant)")
                } catch C.Failure.invalidContract { /* expected source/copy refusal */ }
            }
        }
    }
    static func nativeCounterControls() throws {
        func candidate(_ variant: String) throws -> C.Program {
            let type = variant == "narrow" ? "uint32_t" : variant == "signed" ? "int64_t" : "uint64_t"
            var body = ["seed = (uint64_t)0x0;", "\(type) slot; slot = seed;", "while (true) {",
                        "result = slot + (uint64_t)0x1;", "if (true) { break; } else {", "slot = result;", "}", "}"]
            var rows = [5: 4]
            if variant == "third-write" { body[3] += " slot = result;" }
            if variant == "wrong-seed" { body[1] = "uint64_t slot; other = (uint64_t)0x0; slot = other;" }
            if variant == "removed-backedge" { body[5] = ";" }
            if variant == "before-exit-test" {
                body = [body[0], body[1], body[2], body[3], "slot = result;", body[4], ";", "}", "}"]
                rows = [4: 4, 5: 4]
            }
            if variant == "partial-backedge" {
                body = [body[0], body[1], body[2], body[3], body[4], "if (true) {", "slot = result;", "}", "}", "}"]
                rows = [6: 4]
            }
            return try literalProgram(body, sourceRows: rows)
        }
        func bind(_ program: C.Program) throws -> String {
            let update = try unique(definitions(program, row: 3).filter { $0.name == "result" }, "literal native counter update")
            let name = try nativeCounterOperand(program, addition: update.right, update: update,
                initial: 0, entry: 1, header: 2, backedge: 4)
            _ = try counterLiteral(program, addition: update.right, row: 3,
                operand: [namedDefinition(program, row: 1, name: name),
                          namedDefinition(program, row: 4, name: name)])
            return name
        }
        guard try bind(candidate("original")) == "slot" else { throw C.Failure.invalidContract("literal native counter positive binding") }
        for (variant, reason) in [
            ("third-write", "native X22 slot exactly two assignment binding"),
            ("narrow", "native X22 slot unsigned64 declaration binding"),
            ("signed", "native X22 slot unsigned64 declaration binding"),
            ("wrong-seed", "native X22 initialization/backedge source binding"),
            ("removed-backedge", "native X22 slot exactly two assignment binding"),
            ("before-exit-test", "native X22 import is not owned by continuing backedge arm"),
            ("partial-backedge", "native X22 assignment missing from an entry/backedge binding")] {
            let program = try candidate(variant)
            try refuse(.contract, "literal native counter \(variant)", reason: reason) { _ = try bind(program) }
        }
    }
    static func nativeCounterOperand(_ program: C.Program, addition: C.Expression, update: Definition,
                                     initial: Int, entry: Int, header: Int, backedge: Int) throws -> String {
        guard case let .binary("+", left, _) = addition.node, case let .name(slot) = left.node,
              let symbol = program.symbols[slot], symbol.declared, symbol.type == .u64 else {
            throw C.Failure.invalidContract("native X22 slot unsigned64 declaration binding")
        }
        let declarations = statements(program.root).filter { statement in
            switch statement.node {
            case let .declaration(type, name, value): return name == slot && type == .u64 && (value.map { _ in false } ?? true)
            case let .declarations(type, names): return type == .u64 && names.filter({ $0 == slot }).count == 1
            default: return false
            }
        }
        guard declarations.count == 1 else { throw C.Failure.invalidContract("native X22 slot unique declaration binding") }
        let assignments = statements(program.root).compactMap { statement -> Definition? in
            guard case let .assign(left, right) = statement.node, left.count == 1, right.count == 1,
                  case let .name(name) = left[0].node, name == slot else { return nil }
            return .init(statement: statement, left: left[0], right: right[0], name: name)
        }
        guard assignments.count == 2 else { throw C.Failure.invalidContract("native X22 slot exactly two assignment binding") }
        let entryWrite = try unique(assignments.filter { (try? program.row(at: $0.statement.span)) == entry }, "native X22 entry assignment")
        let backWrite = try unique(assignments.filter { (try? program.row(at: $0.statement.span)) == backedge }, "native X22 backedge assignment")
        let seed = try scalar(program, row: initial)
        guard case let .cast(type, zero) = seed.right.node, type == .u64,
              case let .literal(value) = zero.node, value.bits == 0,
              program.symbols[seed.name]?.type == .u64,
              case let .name(fromEntry) = entryWrite.right.node, fromEntry == seed.name,
              case let .name(fromBack) = backWrite.right.node, fromBack == update.name else {
            throw C.Failure.invalidContract("native X22 initialization/backedge source binding")
        }
        let entryIndex = try codeIndex(program, statement: entryWrite.statement)
        let backIndex = try codeIndex(program, statement: backWrite.statement)
        let addIndex = try codeIndex(program, statement: update.statement)
        let seedIndex = try codeIndex(program, statement: seed.statement)
        let declarationIndices = program.code.indices.filter {
            if case let .declaration(name, nil) = program.code[$0].node { return name == slot }; return false
        }
        let declarationIndex = try unique(declarationIndices, "native X22 uninitialized slot declaration")
        let writes = Set(program.code.indices.filter { instructionWrites(program.code[$0], name: slot) })
        guard writes == Set([declarationIndex, entryIndex, backIndex]) else {
            throw C.Failure.invalidContract("native X22 slot has another write binding")
        }
        guard try reaching(program, name: seed.name, before: entryIndex) == [seedIndex],
              try reaching(program, name: update.name, before: backIndex) == [addIndex],
              try reaching(program, name: slot, before: addIndex) == Set([entryIndex, backIndex]) else {
            throw C.Failure.invalidContract("native X22 slot reaching definition binding")
        }
        let loop = try unique(statements(program.root).filter {
            guard (try? program.row(at: $0.span)) == header else { return false }
            if case .whileLoop = $0.node { return true }; return false
        }, "native X22 loop header")
        let headerIndex = try unique(program.code.indices.filter {
            guard program.code[$0].span == loop.span else { return false }
            if case .branch = program.code[$0].node { return true }; return false
        }, "native X22 parsed header branch")
        let terminal = try unique(statements(program.root).filter {
            guard (try? program.row(at: $0.span)) == backedge else { return false }
            if case .conditional = $0.node { return true }; return false
        }, "native X22 terminating conditional")
        guard case let .conditional(_, exit, continuation) = terminal.node, let continued = continuation,
              backWrite.statement.span.first >= continued.span.first,
              backWrite.statement.span.last <= continued.span.last,
              statements(exit).filter({ if case .breakLoop = $0.node { return true }; return false }).count == 1,
              statements(exit).allSatisfy({
                  switch $0.node { case .compound, .empty, .breakLoop: return true; default: return false }
              }) else {
            throw C.Failure.invalidContract("native X22 import is not owned by continuing backedge arm")
        }
        let graph = try controlFlow(program)
        func inside(_ span: C.Span) -> Bool { span.first >= loop.span.first && span.last <= loop.span.last }
        let incoming = graph.predecessors[headerIndex, default: []]
        let entries = incoming.filter { !inside(program.code[$0].span) }
        let backedges = incoming.filter { inside(program.code[$0].span) }
        guard !entries.isEmpty, !backedges.isEmpty, inside(update.statement.span), inside(backWrite.statement.span) else {
            throw C.Failure.invalidContract("native X22 loop entry/backedge placement binding")
        }
        for predecessor in incoming {
            let found: Set<Int>
            if instructionWrites(program.code[predecessor], name: slot) { found = [predecessor] }
            else { found = try reaching(program, name: slot, before: predecessor) }
            let required = inside(program.code[predecessor].span) ? backIndex : entryIndex
            guard found == [required] else {
                throw C.Failure.invalidContract("native X22 assignment missing from an entry/backedge binding")
            }
        }
        // An external jump into the loop body must not bypass the header proof.
        var pending = Array(graph.predecessors[addIndex, default: []]), seen: Set<Int> = [], foundHeader = false
        while let pc = pending.popLast() {
            if pc == headerIndex { foundHeader = true; continue }
            guard seen.insert(pc).inserted else { continue }
            guard pc != 0, !graph.predecessors[pc, default: []].isEmpty else {
                throw C.Failure.invalidContract("native X22 counter read bypasses loop header binding")
            }
            pending += graph.predecessors[pc, default: []]
        }
        guard foundHeader else { throw C.Failure.invalidContract("native X22 missing loop header binding") }
        return slot
    }
    /// The omitted cast is allowed only for the already declared u64 source
    /// operand. The caller separately binds ADD X22,X22,#1 to exact source IR.
    static func counterLiteral(_ program: C.Program, addition: C.Expression, row: Int,
                               operand: [Definition]) throws -> C.Expression {
        guard let expected = operand.first, operand.allSatisfy({ $0.name == expected.name }) else {
            throw C.Failure.invalidContract("original X22 missing source writer binding")
        }
        guard case let .binary("+", left, right) = addition.node,
              program.expressionTypes[addition.span] == .u64,
              program.expressionTypes[left.span] == .u64 else {
            throw C.Failure.invalidContract("original X22 +1 operand/width binding")
        }
        let underlying: C.Expression
        if case let .cast(type, child) = left.node, type == .u64 { underlying = child }
        else { underlying = left }
        guard case let .name(name) = underlying.node, name == expected.name else {
            throw C.Failure.invalidContract("original X22 +1 wrong reaching operand binding")
        }
        guard let binding = program.symbols[name], binding.declared, binding.type == .u64 else {
            throw C.Failure.invalidContract("X22 increment requires declared unsigned64 source carrier binding")
        }
        let literal: C.Expression
        if case let .cast(type, child) = right.node, type == .u64 { literal = child }
        else {
            guard case .name = left.node, let symbol = program.symbols[name],
                  symbol.declared, symbol.type == .u64 else {
                throw C.Failure.invalidContract("bare X22 increment requires declared unsigned64 operand")
            }
            literal = right
        }
        guard case let .literal(value) = literal.node, value.bits == 1,
              !value.type.pointer else {
            throw C.Failure.invalidContract("original X22 +1 literal binding")
        }
        try requireReachingDefinitions(program, expected: operand, consumer: addition, row: row)
        return literal
    }
    static func ccmpFirstComparison(_ program: C.Program, condition: C.Expression, row: Int,
                                    doubled: Definition, maxH: Definition, vertical: Definition,
                                    maxV: Definition) throws -> C.Expression {
        guard case let .binary(op, left, right) = condition.node,
              op == "&&" || op == "||" else {
            throw C.Failure.invalidContract("CCMP exact AND/equality or inverse OR/inequality binding")
        }
        let comparison = op == "&&" ? "==" : "!="
        func bound(_ e: C.Expression, _ lhs: String, _ rhs: String) -> Bool {
            guard case let .binary(actual, a, b) = e.node, actual == comparison,
                  case let .name(left) = a.node, case let .name(right) = b.node,
                  left == lhs, right == rhs,
                  let at = program.expressionTypes[a.span], let bt = program.expressionTypes[b.span],
                  !at.pointer, !bt.pointer, at.width == 32, bt.width == 32,
                  (try? C.CType.common(at, bt)) == .u32 else { return false }
            return true
        }
        guard bound(left, doubled.name, maxH.name), bound(right, vertical.name, maxV.name) else {
            throw C.Failure.invalidContract("CCMP literal W32 CMP/CCMP operands and false NZCV arm binding")
        }
        for producer in [doubled, maxH, vertical, maxV] {
            try requireReachingDefinitions(program, expected: [producer], consumer: condition, row: row)
        }
        return left
    }
    /// Resolve the actual consuming instruction, not another use of the same name.
    /// Only cast wrappers may surround this pure bound expression: an update in
    /// a sibling expression would require intra-instruction sequencing authority.
    static func consumingIndex(_ program: C.Program, expression: C.Expression, row: Int) throws -> Int {
        func owns(_ root: C.Expression) -> Bool {
            if root.span == expression.span { return true }
            if case let .cast(_, child) = root.node { return owns(child) }
            return false
        }
        guard try program.row(at: expression.span) == row else {
            throw C.Failure.invalidContract("reaching writer consumer source row mismatch")
        }
        return try unique(program.code.indices.filter { index in
            guard (try? program.row(at: program.code[index].span)) == row else { return false }
            switch program.code[index].node {
            case let .assign(left, right):
                guard left.count == 1, right.count == 1, case .name = left[0].node else { return false }
                return owns(right[0])
            case let .branch(condition, _, _): return owns(condition)
            default: return false
            }
        }, "reaching writer actual consuming expression")
    }
    static func requireReachingDefinitions(_ program: C.Program, expected: [Definition],
                                           consumer: C.Expression, row: Int) throws {
        guard let first = expected.first, expected.allSatisfy({ $0.name == first.name }) else {
            throw C.Failure.invalidContract("reaching writer missing or mixed source definitions")
        }
        let use = try consumingIndex(program, expression: consumer, row: row)
        let writers = try expected.map { definition -> Int in
            let index = try codeIndex(program, statement: definition.statement)
            guard case let .assign(left, right) = program.code[index].node,
                  left.count == 1, right.count == 1,
                  left[0].span == definition.left.span, right[0].span == definition.right.span,
                  case let .name(name) = left[0].node, name == definition.name else {
                throw C.Failure.invalidContract("reaching writer definition is not its actual assignment")
            }
            return index
        }
        guard Set(writers).count == writers.count,
              try reaching(program, name: first.name, before: use) == Set(writers) else {
            throw C.Failure.invalidContract("source operand has a different reaching writer")
        }
    }
    static func namedDefinition(_ program: C.Program, row: Int, name: String) throws -> Definition {
        try unique(definitions(program, row: row).filter { $0.name == name }, "named source definition")
    }
    /// Bind only the two original machine-edge copies of the SSA X22 loop phi.
    /// This is not a fallback which gathers arbitrary same-name assignments.
    static func ssaCounterDefinitions(_ program: C.Program, operand: String, update: Definition,
                                      initial: Int, entry: Int, backedge: Int,
                                      headerAddress: UInt64, entryAddress: UInt64,
                                      backedgeAddress: UInt64) throws -> [Definition] {
        let seed = try scalar(program, row: initial)
        func zero(_ expression: C.Expression) -> Bool {
            if case let .cast(type, child) = expression.node, !type.pointer { return zero(child) }
            if case let .literal(value) = expression.node { return value.bits == 0 && !value.type.pointer }
            return false
        }
        guard zero(seed.right), program.symbols[operand]?.type == .u64 else {
            throw C.Failure.invalidContract("SSA X22 seed/phi width binding")
        }
        func copyName(_ expression: C.Expression) -> String? {
            switch expression.node {
            case let .name(name): return name
            case let .cast(type, child) where type == .u64: return copyName(child)
            default: return nil
            }
        }
        func ownsEdge(_ definition: Definition, predecessorAddress: UInt64) -> Bool {
            let line = program.tokens[definition.statement.span.first].line - 1
            return program.lines.indices.contains(line) && program.lines[line].envelope == .body
                && program.lines[line].source == nil
                && program.lines[line].phiEdge == C.PhiEdgeSource(
                    blockAddress: headerAddress, predecessorAddress: predecessorAddress)
        }
        let copies = try [(entry, entryAddress, seed), (backedge, backedgeAddress, update)].map {
            predecessor, address, original -> Definition in
            let definition = try namedDefinition(program, row: predecessor, name: operand)
            guard ownsEdge(definition, predecessorAddress: address),
                  let input = copyName(definition.right) else {
                throw C.Failure.invalidContract("SSA X22 exact entry/backedge source copy binding")
            }
            if input == original.name {
                try requireReachingDefinitions(program, expected: [original],
                    consumer: definition.right, row: predecessor)
            } else {
                // Printer's only staged form is one same-edge snapshot followed
                // by the phi write. Do not follow arbitrary named aliases.
                let snapshot = try namedDefinition(program, row: predecessor, name: input)
                guard ownsEdge(snapshot, predecessorAddress: address),
                      program.expressionTypes[snapshot.right.span] == .u64,
                      copyName(snapshot.right) == original.name else {
                    throw C.Failure.invalidContract("SSA X22 exact same-edge snapshot binding")
                }
                try requireReachingDefinitions(program, expected: [original],
                    consumer: snapshot.right, row: predecessor)
                try requireReachingDefinitions(program, expected: [snapshot],
                    consumer: definition.right, row: predecessor)
                let start = try codeIndex(program, statement: snapshot.statement)
                let end = try codeIndex(program, statement: definition.statement)
                let graph = try controlFlow(program)
                guard start < end else {
                    throw C.Failure.invalidContract("SSA X22 snapshot not before final copy")
                }
                // Each instruction in the retained straight-line copy batch has
                // only its immediate predecessor. No path can reuse a snapshot
                // from a prior iteration while bypassing this iteration's write.
                for pc in (start + 1)...end {
                    guard graph.predecessors[pc, default: []] == Set([pc - 1]) else {
                        throw C.Failure.invalidContract("SSA X22 snapshot copy window bypass")
                    }
                }
            }
            return definition
        }
        try requireCounterCopyPhase(program, update: update, entry: copies[0], backedge: copies[1])
        return copies
    }
    /// A set of reaching writer indices does not distinguish loop iterations.
    /// Every finite route to this ADD must cross a selected import since the
    /// previous ADD, and the initial import must not be reachable from the ADD.
    static func requireCounterCopyPhase(_ program: C.Program, update: Definition,
                                        entry: Definition, backedge: Definition) throws {
        let use = try consumingIndex(program, expression: update.right,
            row: program.row(at: update.right.span))
        let initial = try codeIndex(program, statement: entry.statement)
        let repeatCopy = try codeIndex(program, statement: backedge.statement)
        let graph = try controlFlow(program)
        guard graph.reachable.contains(use), initial != repeatCopy else {
            throw C.Failure.invalidContract("SSA X22 missing reachable copy phase")
        }
        var pending = Array(graph.predecessors[use, default: []]), seen: Set<Int> = []
        while let pc = pending.popLast() {
            if pc == initial || pc == repeatCopy { continue }
            guard pc != use else {
                throw C.Failure.invalidContract("SSA X22 iteration bypasses backedge copy")
            }
            guard seen.insert(pc).inserted else { continue }
            guard pc != 0, !graph.predecessors[pc, default: []].isEmpty else {
                throw C.Failure.invalidContract("SSA X22 use bypasses entry copy")
            }
            pending += graph.predecessors[pc, default: []]
        }
        pending = Array(graph.predecessors[initial, default: []]); seen = []
        while let pc = pending.popLast() {
            guard pc != use else {
                throw C.Failure.invalidContract("SSA X22 entry copy reachable from update")
            }
            guard seen.insert(pc).inserted else { continue }
            pending += graph.predecessors[pc, default: []]
        }
    }

    static func scalar(_ program: C.Program, row: Int) throws -> Definition {
        try unique(definitions(program, row: row), "source-owned scalar definition at row \(row)")
    }
    static func definitions(_ program: C.Program, row: Int) -> [Definition] {
        statements(program.root).compactMap { s in
            guard (try? program.row(at: s.span)) == row,
                  case let .assign(left, right) = s.node, left.count == 1, right.count == 1,
                  case let .name(name) = left[0].node else { return nil }
            return .init(statement: s, left: left[0], right: right[0], name: name)
        }
    }
    static func callStatement(_ program: C.Program, row: Int) throws -> C.Statement {
        try unique(statements(program.root).filter { if case let .call(site, _, _, _) = $0.node { return site == row }; return false }, "protected call row \(row)")
    }
    static func unique<T>(_ values: [T], _ identity: String) throws -> T {
        guard values.count == 1 else { throw C.Failure.invalidContract("\(identity): expected one actual AST binding, found \(values.count)") }; return values[0]
    }
    static func freshName(_ program: C.Program) -> String {
        let used = Set(program.tokens.map(\.text)); var index = 0
        while used.contains("ordinary_refusal_\(index)") { index += 1 }
        return "ordinary_refusal_\(index)"
    }
    static func statements(_ root: C.Statement) -> [C.Statement] {
        var result = [root]
        switch root.node {
        case let .compound(_, body): result += body.flatMap(statements)
        case let .conditional(_, a, b): result += statements(a); if let b { result += statements(b) }
        case let .whileLoop(_, body), let .doLoop(body, _), let .label(_, body): result += statements(body)
        case let .forLoop(initial, _, step, body):
            if let initial { result += statements(initial) }; result += statements(body); if let step { result += statements(step) }
        default: break
        }
        return result
    }
    static func descendants(_ e: C.Expression) -> [C.Expression] {
        switch e.node {
        case let .cast(_, child), let .unary(_, child), let .load(_, child), let .field(child, _): return [e] + descendants(child)
        case let .binary(_, a, b): return [e] + descendants(a) + descendants(b)
        case let .select(c, a, b): return [e] + descendants(c) + descendants(a) + descendants(b)
        case let .helper(_, args): return [e] + args.flatMap(descendants)
        default: return [e]
        }
    }
    static func text(_ program: C.Program, _ span: C.Span) throws -> String {
        guard span.first < span.last, program.tokens.indices.contains(span.first), program.tokens.indices.contains(span.last - 1) else {
            throw C.Failure.invalidContract("invalid actual AST span")
        }
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        let bytes = Array(program.lines.map(\.text).joined(separator: "\n").utf8)
        return String(decoding: bytes[first.byteOffset..<(last.byteOffset + last.text.utf8.count)], as: UTF8.self)
    }
    static func renamed(_ program: C.Program, span: C.Span, from: String, to: String) throws -> String {
        var bytes = Array(try text(program, span).utf8)
        let base = program.tokens[span.first].byteOffset
        let sites = program.tokens[span.first..<span.last].filter { $0.text == from }
        guard !sites.isEmpty else { throw C.Failure.invalidContract("stale alias has no actual operand tokens") }
        for token in sites.reversed() {
            bytes.replaceSubrange((token.byteOffset - base)..<(token.byteOffset - base + token.text.utf8.count), with: to.utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func replacing(_ program: C.Program, span: C.Span, with replacement: String) throws -> [C.TextLine] {
        _ = try text(program, span)
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line, !replacement.contains("\n") else {
            throw C.Failure.invalidContract("mutation must occupy exactly one actual source line")
        }
        let index = first.line - 1, row = try program.row(at: span)
        guard program.lines[index].envelope == .body, row != program.contract.terminalRow,
              program.contract.exterior[row] == nil,
              program.contract.calls[row]?.payload != String(program.lines[index].text.drop(while: { $0 == " " || $0 == "\t" })) else {
            throw C.Failure.invalidContract("mutation touches protected call/exterior/return text")
        }
        let offset = program.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(program.lines[index].text.utf8)
        bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset - offset + last.text.utf8.count), with: replacement.utf8)
        var lines = program.lines
        lines[index] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[index].source, envelope: lines[index].envelope)
        return lines
    }
}
