import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Source-only drafted test helper, not executed evidence.
/// Literal captured ARM64 scalar semantics plus explicit model-relative opaque K.
/// No production scalar RHS, switch case array or region plan supplies a value.
/// Complete rows include cold blocks beyond RET. Positive terminals are void only.
enum RegionalSwitchOracle {
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case let .invalid(message): return message } }
    }

    typealias Write = RegionalCallOracle.Write
    typealias Memory = RegionalCallOracle.Memory
    typealias Carrier = RegionalCallOracle.Carrier
    typealias Call = RegionalCallOracle.Call
    typealias Event = RegionalCallOracle.Event
    typealias Response = RegionalCallOracle.Response
    typealias Branch = RegionalCallOracle.Branch
    struct Snapshot { let registers: [Int: UInt64]; let flags: Flags? }
    struct Result {
        var memory: Memory
        var events: [Event] = []
        var branches: [Branch] = []
        var rowVisits: [Int: Int] = [:]
        var afterRows: [Int: [Snapshot]] = [:]
        var returned = false
        var reachedRegionBoundary = false
        var finalRegisters: [Int: UInt64] = [:]
        var calls: [Call] { events.compactMap { if case let .call(call) = $0 { return call }; return nil } }
    }
    struct Scenario {
        let name: String
        var registers: [Int: UInt64]
        var memory: Memory
        var responses: [Response]
        var expectedVisits: [Int: Int] = [:]
        var expectedAbsentRows: Set<Int> = []
        var startRow = 0
        var stopBeforeRow: Int? = nil
        var premises: [String] = []
        var regionalBindings: [String: UInt64] = [:]
    }
    struct OpaqueSite {
        let row: Int
        let address: UInt64
        let frame: MacIRCallFrame
        let exactStatement: String
        let printedDestination: String?
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
        let indexIsUXTW: Bool
        let offset: UInt64
        let update: Update
        enum Update: Equatable { case none, pre, post }
    }
    enum Instruction {
        case move(Register, Operand)
        case arithmetic(String, Register, Register, Operand, Int)
        case compare(String, Register, Operand)
        case memory(String, [Register], Address)
        case page(Register, UInt64)
        case relative(Register, UInt64)
        case branch(String, Register?, UInt64)
        case indirectBranch(Register)
        case call
        case returned
    }
    struct Program {
        let rows: [InstructionRow]
        let code: [Instruction]
        let calls: [Int: MacIRCallFrame]
        let opaqueSites: [Int: OpaqueSite]
        let returnRows: Set<Int>
        init(fixture: RegionalSwitchFixture) throws {
            let rows = fixture.rows, function = fixture.function
            guard fixture.seed != .j16initC4Negative,
                  fixture.input.signatureOverrides[fixture.seed.start]?.returnType == "void",
                  !rows.isEmpty, rows.count == function.instructions.count else {
                throw Failure.invalid("unsupported original terminal / incomplete source correspondence")
            }
            let payloads = fixture.callPayloads
            guard Set(payloads.map(\.row)).count == payloads.count else { throw Failure.invalid("duplicate retained call payload") }
            var parsed: [Instruction] = [], calls: [Int: MacIRCallFrame] = [:]
            var sites: [Int: OpaqueSite] = [:], returns: Set<Int> = []
            for (index, row) in rows.enumerated() {
                guard row.byteWidth == 4, row.structuredOperands != nil,
                      row.address == rows[0].address &+ UInt64(index * 4),
                      row.address == function.instructions[index].source.address else {
                    throw Failure.invalid("missing original decoded row \(index)")
                }
                let instruction = try Self.parse(row)
                try Self.validate(row, instruction, ir: function.instructions[index])
                parsed.append(instruction)
                if row.mnemonic == "bl" || row.mnemonic == "blr" {
                    guard case let .call(frame, result) = function.instructions[index].operation,
                          frame.knownSignature == nil, frame.richArguments == nil,
                          frame.indirectResultPointer == nil,
                          let payload = payloads.first(where: { $0.row == index }),
                          payload.address == row.address, !payload.changedBeyondIndentation else {
                        throw Failure.invalid("changed or unsupported original opaque operation at row \(index)")
                    }
                    let statement = payload.baseline
                    let destination: String?
                    if let separator = statement.range(of: " = ") {
                        let candidate = String(statement[..<separator.lowerBound])
                        guard let result, case let .register(name, version) = result,
                              name == "x0", candidate == "x0_\(version)" else {
                            throw Failure.invalid("call acquired or changed its original printed result")
                        }
                        destination = candidate
                    } else { destination = nil }
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
                              control.register == .gpr(index: target.index) else {
                            throw Failure.invalid("indirect call control mismatch")
                        }
                    }
                    calls[index] = frame
                    sites[index] = .init(row: index, address: row.address, frame: frame,
                                        exactStatement: statement, printedDestination: destination)
                } else if case .call = function.instructions[index].operation {
                    throw Failure.invalid("unaccounted original opaque call")
                }
                if row.mnemonic == "ret" {
                    guard case .returnValue(nil) = function.instructions[index].operation else {
                        throw Failure.invalid("non-void original terminal is not physical-X0 authority")
                    }
                    returns.insert(index)
                }
            }
            guard returns == [fixture.seed.returnRow], Set(calls.keys) == Set(fixture.seed.callRows),
                  Set(calls.keys) == Set(payloads.map(\.row)) else {
                throw Failure.invalid("incomplete terminal or opaque-call coverage")
            }
            self.rows = rows; code = parsed; self.calls = calls
            opaqueSites = sites; returnRows = returns
        }
        /// Cross-check semantic operand facts independently of the emitter. The
        /// fixture additionally fingerprints the full captured envelope, including
        /// presentation and encoded-immediate witnesses not evaluated here.
        private static func validate(_ row: InstructionRow, _ parsed: Instruction, ir: MacIRInstruction) throws {
            guard let envelope = row.structuredOperands, envelope.architecture == .arm64,
                  envelope.schemaVersion == 1 else { throw Failure.invalid("missing ARM64 envelope") }
            if envelope.coverage == .unavailable {
                guard envelope == .unavailable(mnemonic: row.mnemonic, operands: row.operands),
                      ["mov", "lsl", "and", "tst", "br", "blr", "ret"].contains(row.mnemonic),
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
                        guard modifier.kind == (address.indexIsUXTW ? .uxtw : .lsl), modifier.amount == address.shift else { throw Failure.invalid("memory index shift mismatch") }
                    } else if address.shift != 0 { throw Failure.invalid("missing memory index shift") }
                default: throw Failure.invalid("memory index mismatch")
                }
                let indexing: InstructionOperands.Memory.Indexing = address.update == .none ? .offset : address.update == .pre ? .preIndex : .postIndex
                let bytes = op == "ldrb" ? 1 : registers[0].width / 8
                let extensionKind: MacIRMemoryAccess.ExtensionKind = op == "ldrb" ? .zero : .none
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
                guard envelope.opcodeClass == (op == "cmp" ? "subs" : op == "cmn" ? "adds" : "ands"), values.count == 3 else { throw Failure.invalid("comparison metadata mismatch") }
                try plain(values[0], Register(left.width == 32 ? "wzr" : "xzr"))
                try plain(values[1], left); try operand(values[2], right)
            case let .page(destination, target):
                guard envelope.opcodeClass == "adrp", values.count == 2 else { throw Failure.invalid("ADRP envelope mismatch") }
                try plain(values[0], destination); try pc(values[1], target: target, page: true)
            case let .relative(destination, target):
                guard envelope.opcodeClass == "adr", values.count == 2 else { throw Failure.invalid("ADR envelope mismatch") }
                try plain(values[0], destination); try pc(values[1], target: target, page: false)
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
            var index: Register?, shift = 0, offset: UInt64 = 0, uxtw = false
            if parts.count >= 2 {
                if parts[1].hasPrefix("#") { offset = try number(parts[1]); guard parts.count == 2 else { throw Failure.invalid("shifted immediate address") } }
                else { index = try Register(parts[1]); guard index?.zero == false else { throw Failure.invalid("zero memory index is outside captured grammar") } }
            }
            if parts.count == 3 {
                let modifier = parts[2].split(separator: " ").map(String.init)
                guard modifier.count == 2, ["lsl", "uxtw"].contains(modifier[0]),
                      let value = Int(exactly: try number(modifier[1])), (0..<64).contains(value) else {
                    throw Failure.invalid("unsupported memory modifier")
                }
                shift = value; uxtw = modifier[0] == "uxtw"
            }
            if let index {
                guard index.width == (uxtw ? 32 : 64) else { throw Failure.invalid("memory index extension width mismatch") }
            } else if uxtw { throw Failure.invalid("modifier without index") }
            if operands.count == 2 {
                guard parts.count == 1, !pre else { throw Failure.invalid("conflicting address writeback") }
                offset = try number(operands[1])
            }
            guard !(pre && index != nil) else { throw Failure.invalid("indexed pre-writeback") }
            return .init(base: base, index: index, shift: shift, indexIsUXTW: uxtw, offset: offset, update: pre ? .pre : operands.count == 2 ? .post : .none)
        }
        private static func condition(_ text: String) throws -> String {
            guard ["eq", "ne", "hs", "lo", "lt", "gt", "le", "ge", "hi", "ls"].contains(text) else { throw Failure.invalid("unsupported condition \(text)") }
            return text
        }
        static func parse(_ row: InstructionRow) throws -> Instruction {
            let a = try split(row.operands), op = row.mnemonic
            func arity(_ count: Int) throws { guard a.count == count else { throw Failure.invalid("wrong arity at \(row.address): \(op) \(row.operands)") } }
            switch op {
            case "mov": try arity(2); return .move(try Register(a[0]), try operand(a[1]))
            case "add", "sub", "subs", "and", "lsl":
                guard a.count == 3 || (op == "add" && a.count == 4) else { throw Failure.invalid("unsupported arithmetic arity") }
                let d = try Register(a[0]), left = try Register(a[1]), right = try operand(a[2])
                guard d.width == left.width else { throw Failure.invalid("mixed-width source arithmetic") }
                if case let .register(r) = right, r.width != d.width { throw Failure.invalid("mixed-width right operand") }
                let shift = a.count == 4 ? try amount(a[3]) : 0
                guard shift < d.width else { throw Failure.invalid("shift exceeds register width") }
                return .arithmetic(op, d, left, right, shift)
            case "cmp", "cmn", "tst":
                try arity(2)
                let left = try Register(a[0]), right = try operand(a[1])
                if case let .register(register) = right, register.width != left.width { throw Failure.invalid("comparison operand width mismatch") }
                return .compare(op, left, right)
            case "ldr", "ldrb", "str":
                guard (2...3).contains(a.count) else { throw Failure.invalid("memory arity") }
                let register = try Register(a[0])
                guard op != "ldrb" || register.width == 32 else { throw Failure.invalid("LDRB must define a W register") }
                return .memory(op, [register], try address(Array(a.dropFirst())))
            case "ldp", "stp":
                guard (3...4).contains(a.count) else { throw Failure.invalid("pair arity") }
                let first = try Register(a[0]), second = try Register(a[1])
                guard first.width == second.width else { throw Failure.invalid("mixed-width pair") }
                return .memory(op, [first, second], try address(Array(a.dropFirst(2))))
            case "adrp": try arity(2); let target = try number(a[1]); guard target & 0xfff == 0 else { throw Failure.invalid("unaligned ADRP") }; return .page(try Register(a[0]), target)
            case "adr": try arity(2); return .relative(try Register(a[0]), try number(a[1]))
            case "br":
                try arity(1); let register = try Register(a[0])
                guard register.width == 64, !register.zero, register.index != 31 else { throw Failure.invalid("invalid indirect branch register") }
                return .indirectBranch(register)
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
        init(n: Bool, z: Bool, c: Bool, v: Bool) { self.n = n; self.z = z; self.c = c; self.v = v }
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
            if program.opaqueSites[row]?.printedDestination != nil { registers[0] = response.result }
            // A printless K never defines a hidden physical-X0 result for reuse.
            let occurrence = result.calls.filter { $0.row == row }.count
            result.events.append(.call(.init(row: row, occurrence: occurrence, target: frame.target,
                control: control, arguments: arguments, result: response.result, writes: response.writes)))
            responseIndex += 1
        }
        private func validateOutcome() throws {
            guard responseIndex == scenario.responses.count else { throw Failure.invalid("unused opaque-call responses") }
            for (row, expected) in scenario.expectedVisits where result.rowVisits[row, default: 0] != expected {
                throw Failure.invalid("wrong source scenario visit row \(row): \(scenario.name)")
            }
            for row in scenario.expectedAbsentRows where result.rowVisits[row, default: 0] != 0 {
                throw Failure.invalid("forbidden source row \(row): \(scenario.name)")
            }
        }
        private mutating func execute() throws -> Result {
            guard program.code.indices.contains(scenario.startRow),
                  scenario.stopBeforeRow.map({ program.code.indices.contains($0) }) ?? true else {
                throw Failure.invalid("invalid regional entry or stop")
            }
            var pc = scenario.startRow, fuel = 20_000
            let positions = Dictionary(uniqueKeysWithValues: program.rows.enumerated().map { ($0.element.address, $0.offset) })
            while program.code.indices.contains(pc), fuel > 0 {
                if scenario.stopBeforeRow == pc {
                    try validateOutcome()
                    result.reachedRegionBoundary = true; result.finalRegisters = registers; return result
                }
                fuel -= 1
                result.rowVisits[pc, default: 0] += 1
                switch program.code[pc] {
                case let .move(destination, source): write(destination, try read(source))
                case let .page(destination, address), let .relative(destination, address): write(destination, address)
                case let .arithmetic(op, destination, left, right, shift):
                    let a = try read(left), b = try read(right) << shift, value: UInt64
                    switch op {
                    case "add": value = a &+ b
                    case "sub", "subs":
                        value = a &- b
                        if op == "subs" { flags = .init(left: a, right: b, width: destination.width, adding: false) }
                    case "and": value = a & b
                    case "lsl":
                        // ARM64 register LSL masks the dynamic amount. This is
                        // source behavior, NOT a permissive emitted-C shift rule.
                        if case .register = right { value = a << Int(b & UInt64(destination.width - 1)) }
                        else {
                            guard b < UInt64(destination.width) else { throw Failure.invalid("source immediate shift outside width") }
                            value = a << Int(b)
                        }
                    default: throw Failure.invalid("unsupported scalar arithmetic")
                    }
                    write(destination, value)
                case let .compare(op, left, right):
                    let a = try read(left), b = try read(right)
                    if op == "tst" {
                        let bits = a & b
                        flags = .init(n: bits & (UInt64(1) << (left.width - 1)) != 0,
                                      z: bits == 0, c: false, v: false)
                    } else { flags = .init(left: a, right: b, width: left.width, adding: op == "cmn") }
                case let .memory(op, values, address):
                    let base = try read(address.base)
                    let index = try address.index.map { try read($0) << address.shift } ?? 0
                    let location = address.update == .post ? base : base &+ address.offset &+ index
                    let count = op == "ldrb" ? 1 : values[0].width / 8
                    let loading = op.hasPrefix("ld")
                    if loading {
                        var loaded: [UInt64] = []
                        for slot in values.indices { loaded.append(try load(location &+ UInt64(slot * count), bytes: count, row: pc)) }
                        for slot in values.indices {
                            let bits = loaded[slot]
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
                        result.afterRows[pc, default: []].append(.init(registers: registers, flags: flags))
                        pc = destination; continue
                    }
                case let .indirectBranch(register):
                    let target = try read(register)
                    guard let destination = positions[target] else { throw Failure.invalid("computed BR leaves complete captured function") }
                    result.branches.append(.init(row: pc, taken: true, target: target))
                    result.afterRows[pc, default: []].append(.init(registers: registers, flags: flags))
                    pc = destination; continue
                case .call: try opaqueCall(row: pc)
                case .returned:
                    guard program.returnRows.contains(pc), scenario.stopBeforeRow == nil else {
                        throw Failure.invalid("unexpected return before declared regional stop")
                    }
                    try validateOutcome()
                    result.returned = true; result.finalRegisters = registers; return result
                }
                result.afterRows[pc, default: []].append(.init(registers: registers, flags: flags))
                pc += 1
            }
            throw Failure.invalid(fuel == 0 ? "source fuel exhausted" : "source fell out without RET")
        }
    }
}
