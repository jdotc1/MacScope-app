import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// The missing reference adapter is deliberately restricted to the complete
/// retained58-row _skip_variable capture. It interprets literal ARM64 rows.
/// It never reads candidate text, MacIR scalar RHSs or an ordinary value plan.
enum OrdinaryCSkipSourceOracle {
    typealias O = RegionalCallOracle
    typealias S = RegionalSwitchOracle
    enum Instruction { case scalar(S.Instruction), or(S.Register, S.Register, S.Register) }
    struct Program {
        let rows: [InstructionRow]
        let code: [Instruction]
        let calls: [Int: MacIRCallFrame]
        init(rows: [InstructionRow], function: MacIRFunction) throws {
            guard rows.count == 58, rows.first?.address == 0x33418, rows.last?.address == 0x334fc,
                  function.instructions.count == rows.count,
                  rows[37].operands == "w21, #1", rows[50].operands == "w21, #0",
                  rows[51].operands == "x0, x21", rows[57].mnemonic == "ret" else {
                throw OrdinaryC.Failure.invalidContract("not the retained skip terminal reference")
            }
            var code: [Instruction] = [], calls: [Int: MacIRCallFrame] = [:]
            for (index, row) in rows.enumerated() {
                guard row.address == 0x33418 + UInt64(index * 4), row.structuredOperands != nil else {
                    throw OrdinaryC.Failure.invalidContract("incomplete literal skip row")
                }
                if row.mnemonic == "orr" {
                    let parts = row.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 3 else { throw OrdinaryC.Failure.invalidContract("unsupported source ORR") }
                    code.append(.or(try S.Register(parts[0]), try S.Register(parts[1]), try S.Register(parts[2])))
                } else { code.append(.scalar(try S.Program.parse(row))) }
                if row.mnemonic == "blr" {
                    guard [12,21,40,48].contains(index), case let .call(frame, _) = function.instructions[index].operation,
                          frame.knownSignature == nil, frame.richArguments == nil else { throw OrdinaryC.Failure.invalidContract("changed skip opaque source frame") }
                    calls[index] = frame
                }
            }
            guard Set(calls.keys) == [12,21,40,48] else { throw OrdinaryC.Failure.invalidContract("skip call manifest") }
            self.rows = rows; self.code = code; self.calls = calls
        }
    }
    struct Machine {
        let program: Program
        let scenario: O.Scenario
        var registers: [Int: UInt64]
        var flags: S.Flags?
        var result: O.Result
        var responseIndex = 0
        init(program: Program, scenario: O.Scenario) {
            self.program = program; self.scenario = scenario; registers = scenario.registers
            result = .init(memory: scenario.memory)
        }
        func run() throws -> O.Result { var machine = self; return try machine.execute() }
        func read(_ register: S.Register) throws -> UInt64 {
            if register.zero { return 0 }
            guard let bits = registers[register.index] else { throw S.Failure.invalid("uninitialized skip source register") }
            return register.width == 32 ? bits & 0xffff_ffff : bits
        }
        func read(_ operand: S.Operand) throws -> UInt64 {
            switch operand { case let .register(register): return try read(register); case let .immediate(bits): return bits }
        }
        mutating func write(_ register: S.Register, _ value: UInt64) {
            if !register.zero { registers[register.index] = register.width == 32 ? value & 0xffff_ffff : value }
        }
        mutating func call(_ row: Int) throws {
            guard let frame = program.calls[row], scenario.responses.indices.contains(responseIndex) else { throw S.Failure.invalid("unscripted skip source call") }
            let response = scenario.responses[responseIndex]
            guard response.row == row else { throw S.Failure.invalid("skip source call ordering") }
            let arguments = try frame.arguments.canonicalPhysicalEntriesForAudit.map { argument -> O.Carrier in
                guard case let .gpr(index, width) = argument.location else { throw S.Failure.invalid("skip source carrier") }
                return .init(register: index, width: width, bits: try read(S.Register("\(width == 32 ? "w" : "x")\(index)")))
            }
            let controls = try frame.controlInputs.canonicalControlInputsForAudit.map { control -> O.Carrier in
                guard case let .gpr(index) = control.register else { throw S.Failure.invalid("skip source callee") }
                return .init(register: index, width: 64, bits: try read(S.Register("x\(index)")))
            }
            if let expected = response.expectedArguments, expected != arguments.map(\.bits) { throw S.Failure.invalid("skip source expected arguments") }
            if let expected = response.expectedControl, expected != controls.map(\.bits) { throw S.Failure.invalid("skip source expected control") }
            for register in Array(0...18) + [30] { registers.removeValue(forKey: register) }
            flags = nil
            for write in response.writes { try result.memory.store(write) }
            registers[0] = response.result
            let occurrence = result.calls.filter { $0.row == row }.count
            result.events.append(.call(.init(row: row, occurrence: occurrence, target: frame.target, control: controls,
                arguments: arguments, result: response.result, writes: response.writes)))
            responseIndex += 1
        }
        mutating func execute() throws -> O.Result {
            let positions = Dictionary(uniqueKeysWithValues: program.rows.enumerated().map { ($0.element.address, $0.offset) })
            var pc = 0, fuel = 2_000
            while program.code.indices.contains(pc) {
                guard fuel > 0 else { throw S.Failure.invalid("skip source fuel exhausted") }; fuel -= 1
                result.rowVisits[pc, default: 0] += 1
                switch program.code[pc] {
                case let .or(destination, a, b): write(destination, try read(a) | read(b))
                case let .scalar(instruction):
                    switch instruction {
                    case let .move(destination, source): write(destination, try read(source))
                    case let .arithmetic(op, destination, a, b, shift):
                        let left = try read(a), right = try read(b) << shift, value: UInt64
                        switch op {
                        case "add": value = left &+ right
                        case "sub", "subs":
                            value = left &- right
                            if op == "subs" { flags = .init(left: left, right: right, width: destination.width, adding: false) }
                        case "lsl":
                            guard right < UInt64(destination.width) else { throw S.Failure.invalid("skip source shift") }
                            value = left << Int(right)
                        default: throw S.Failure.invalid("unsupported skip scalar")
                        }
                        write(destination, value)
                    case let .compare(op, a, b):
                        guard op == "cmp" else { throw S.Failure.invalid("skip comparison") }
                        flags = .init(left: try read(a), right: try read(b), width: a.width, adding: false)
                    case let .memory(op, values, address):
                        let oldBase = try read(address.base)
                        let index = try address.index.map { try read($0) << address.shift } ?? 0
                        let location = address.update == .post ? oldBase : oldBase &+ address.offset &+ index
                        let bytes = op == "ldrb" ? 1 : values[0].width / 8
                        if op.hasPrefix("ld") {
                            var loaded: [UInt64] = []
                            for slot in values.indices {
                                let address = location &+ UInt64(slot * bytes), bits = try result.memory.load(address, bytes: bytes)
                                result.events.append(.load(row: pc, address: address, bytes: bytes, bits: bits)); loaded.append(bits)
                            }
                            for slot in values.indices { write(values[slot], loaded[slot]) }
                        } else {
                            let sources = try values.map(read)
                            for slot in values.indices {
                                let address = location &+ UInt64(slot * bytes), bits = sources[slot]
                                try result.memory.store(.init(address: address, bytes: bytes, bits: bits))
                                result.events.append(.store(row: pc, address: address, bytes: bytes,
                                    bits: bytes == 8 ? bits : bits & ((UInt64(1) << (bytes * 8)) - 1)))
                            }
                        }
                        if address.update != .none { write(address.base, oldBase &+ address.offset) }
                    case let .branch(predicate, register, target):
                        let taken: Bool
                        if predicate == "always" { taken = true }
                        else if let register { let zero = try read(register) == 0; taken = predicate == "cbz" ? zero : !zero }
                        else { guard let flags else { throw S.Failure.invalid("skip source killed flags") }; taken = try flags.test(predicate) }
                        result.branches.append(.init(row: pc, taken: taken, target: target))
                        if taken {
                            guard let target = positions[target] else { throw S.Failure.invalid("skip branch outside capture") }
                            pc = target; continue
                        }
                    case .call: try call(pc)
                    case .returned:
                        guard pc == 57, responseIndex == scenario.responses.count else { throw S.Failure.invalid("skip source terminal/script") }
                        for (row, expected) in scenario.expectedVisits where result.rowVisits[row, default: 0] != expected { throw S.Failure.invalid("skip source scenario row \(row)") }
                        result.returnBits = try read(S.Register("x0")); result.returned = true; result.finalRegisters = registers
                        return result
                    case .page, .relative, .indirectBranch: throw S.Failure.invalid("unsupported skip source family")
                    }
                }
                pc += 1
            }
            throw S.Failure.invalid("skip source fell out")
        }
    }
    enum Scenarios {
        static let context: UInt64 = 0x10000, manager: UInt64 = 0x20000, errors: UInt64 = 0x30000
        static let buffer: UInt64 = 0x40000, refillBuffer: UInt64 = 0x50000, stack: UInt64 = 0x90000
        static let refill: UInt64 = 0xa100_0000_0000_0001, message: UInt64 = 0xa200_0000_0000_0002, skip: UInt64 = 0xa300_0000_0000_0003
        static func make(name: String, count: UInt64 = 2, length: UInt16 = 3, first: UInt64? = nil,
                         second: UInt64? = nil, aliasStack: Bool = false, callbackWrites: Bool = false) throws -> O.Scenario {
            var memory = O.Memory()
            memory.initialize(context, count: 0x240, byte: 0x91)
            memory.initialize(manager, count: 0x30, byte: 0x92)
            memory.initialize(errors, count: 0x38, byte: 0x93)
            memory.initialize(stack - 0x50, count: 0x50, byte: 0x94)
            func put(_ address: UInt64, _ bits: UInt64, _ bytes: Int = 8) throws { try memory.store(.init(address: address, bytes: bytes, bits: bits)) }
            try put(context, errors); try put(context + 0x28, manager); try put(context + 0x234, 0x1234_5678, 4)
            try put(manager, buffer); try put(manager + 8, count); try put(manager + 0x18, refill); try put(manager + 0x20, skip)
            try put(errors + 8, message)
            try put(buffer, UInt64(length >> 8), 1); try put(buffer + 1, UInt64(length & 255), 1)
            try put(refillBuffer, UInt64(length & 255), 1)
            var responses: [O.Response] = []
            var successful = true
            if let first {
                let success = first & 0xffff_ffff != 0; successful = success
                responses.append(.init(row: 12, result: first, writes: success ? [
                    .init(address: manager, bytes: 8, bits: buffer), .init(address: manager + 8, bytes: 8, bits: second == nil ? 2 : 1)
                ] : [], expectedArguments: [context], expectedControl: [refill]))
            }
            if successful, let second {
                let success = second & 0xffff_ffff != 0; successful = success
                responses.append(.init(row: 21, result: second, writes: success ? [
                    .init(address: manager, bytes: 8, bits: refillBuffer), .init(address: manager + 8, bytes: 8, bits: 0x0000_0001_0000_0003)
                ] : [], expectedArguments: [context], expectedControl: [refill]))
            }
            if successful {
                var writes: [O.Write] = []
                if callbackWrites {
                    writes += [.init(address: manager, bytes: 8, bits: 0xbad0), .init(address: manager + 8, bytes: 8, bits: 0xbad1)]
                }
                if aliasStack {
                    writes += [.init(address: stack - 0x10, bytes: 8, bits: 0xfedc_ba98_7654_3210),
                               .init(address: stack - 8, bytes: 8, bits: 0x1234_5678_9abc_def0)]
                }
                responses.append(.init(row: 40, result: 0xd00d_0000_0000_0000, writes: writes,
                    expectedArguments: [context,1], expectedControl: [message]))
                if length >= 3 {
                    responses.append(.init(row: 48, result: 0xc00c_0000_0000_0000,
                        writes: callbackWrites ? [.init(address: context + 0x234, bytes: 4, bits: 0x8877_6655)] : [],
                        expectedArguments: [context, UInt64(length) - 2], expectedControl: [skip]))
                }
            }
            var registers: [Int: UInt64] = [0: context,31: stack]
            for index in 19...30 { registers[index] = 0xf000_0000_0000_0000 | UInt64(index) }
            return .init(name: name, registers: registers, memory: memory, responses: responses,
                         expectedVisits: [57:1,40:successful ? 1 : 0,48:successful && length >= 3 ? 1 : 0])
        }
        static func all() throws -> [O.Scenario] {
            [try make(name: "no-refill-length-below-cutoff", length: 2),
             try make(name: "no-refill-length-at-cutoff", length: 3),
             try make(name: "no-refill-length-zero-unsigned-underflow", length: 0),
             try make(name: "first-refill-zero-failure", count: 0, first: 0),
             try make(name: "first-refill-high64-low32zero-failure", count: 0, first: 0x8000_0000_0000_0000),
             try make(name: "first-refill-success", count: 0, first: 0xffff_ffff_0000_0001),
             try make(name: "second-refill-zero-failure", count: 1, second: 0),
             try make(name: "second-refill-high64-low32zero-failure", count: 1, second: 0x1000_0000_0000_0000),
             try make(name: "second-refill-changes-buffer-and-high64-count", count: 1, length: 0x2345, second: 1),
             try make(name: "both-refills-return-with-changed-snapshots", count: 0, length: 0x6789, first: 1, second: 1),
             try make(name: "message-and-skip-callback-memory-writes", callbackWrites: true),
             try make(name: "message-aliases-saved-stack", aliasStack: true),
             try make(name: "high64-only-initial-count", count: 0x0000_0001_0000_0000)]
        }
    }
}
