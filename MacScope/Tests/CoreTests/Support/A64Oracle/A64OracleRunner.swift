import Foundation
@testable import MacScope

/// Runs one oracle fixture through MacScope: decode `word` with `ARM64Decoder`, lift it with
/// `MacIRBuilder`, evaluate the MacIR with `MacIRConcreteEvaluator` over the seeded state, and
/// compare every expected output plus the unchanged-state invariants.
enum A64OracleRunner {
    enum Status: String, CaseIterable, Comparable {
        case pass = "PASS", fail = "FAIL", unlifted = "UNLIFTED", unsupported = "UNSUPPORTED", harness = "HARNESS"
        static func < (lhs: Status, rhs: Status) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    struct Outcome {
        let vector: A64OracleVector
        let decoded: String
        let status: Status
        /// The first mismatch, the unlifted instruction, or why the case is unsupported.
        let reason: String
        /// What else is known about a FAIL: `signedness` (passes with the other signedness),
        /// `access-width` (passes with another load/store width), `c-undefined`.
        let tags: [String]
        /// Expected outputs MacIR has no state for (NZCV, FPSR); never counted as a mismatch.
        let unmodeled: [String]
        /// True when the case ran as a synthesized `cmp` followed by the fixture's instruction.
        let viaSynthesizedCompare: Bool
    }

    /// Mnemonics that consume NZCV through MacIR's comparison seam; alone they lift to `.unknown`.
    static let flagConsumers: Set<String> = [
        "csel", "csinc", "csinv", "csneg", "cset", "csetm", "cinc", "cinv", "cneg", "fcsel",
    ]

    static func run(_ vector: A64OracleVector) -> Outcome {
        func outcome(_ status: Status, _ reason: String, decoded: String = "", tags: [String] = [],
                     unmodeled: [String] = [], synthesized: Bool = false) -> Outcome {
            Outcome(vector: vector, decoded: decoded, status: status, reason: reason, tags: tags,
                    unmodeled: unmodeled, viaSynthesizedCompare: synthesized)
        }
        let seeded: A64MachineState
        do { seeded = try A64MachineState(seeding: vector.inputs) } catch { return outcome(.harness, "\(error)") }
        guard let word = vector.wordValue else { return outcome(.harness, "bad word \(vector.word)") }

        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        guard let decodedInstruction = ARM64Decoder().decode(bytes, baseAddress: seeded.pc, maxInstructionCount: 1).first else {
            return outcome(.harness, "decoder returned nothing")
        }
        let mnemonic = decodedInstruction.mnemonic.lowercased()
        let decoded = decodedInstruction.operands.isEmpty ? mnemonic : "\(mnemonic) \(decodedInstruction.operands)"
        if mnemonic == "unavailable" || mnemonic == "unknown" || mnemonic.hasPrefix(".") {
            return outcome(.unlifted, "decoder: \(decoded)", decoded: decoded)
        }
        let row = InstructionRow(address: seeded.pc, bytes: decodedInstruction.byteText, mnemonic: mnemonic,
                                 operands: decodedInstruction.operands, hasBreakpoint: false, comment: nil)

        var result = attempt(rows: [row], seeded: seeded, vector: vector, decoded: decoded)
        if result.status == .unlifted, flagConsumers.contains(mnemonic), vector.inputs.nzcv != nil {
            result = attemptWithSynthesizedCompare(row: row, seeded: seeded, vector: vector, decoded: decoded) ?? result
        }
        return result
    }

    // MARK: Attempts

    private static func attempt(rows: [InstructionRow], seeded: A64MachineState, vector: A64OracleVector,
                                decoded: String, synthesized: Bool = false) -> Outcome {
        let function = MacIRBuilder().buildFunction(name: "oracle_\(vector.id)", instructions: rows)
        let primary = evaluate(function, seeded: seeded)
        func outcome(_ status: Status, _ reason: String, tags: [String] = [], unmodeled: [String] = []) -> Outcome {
            Outcome(vector: vector, decoded: decoded, status: status, reason: reason, tags: tags,
                    unmodeled: unmodeled, viaSynthesizedCompare: synthesized)
        }
        switch primary {
        case let .failure(.unlifted(text)):
            return outcome(.unlifted, text)
        case let .failure(.unsupported(text)):
            return outcome(.unsupported, text)
        case let .failure(.harness(text)):
            return outcome(.harness, text)
        case let .failure(.undefined(text)):
            var tags = ["c-undefined"]
            tags += alternativeTags(function, seeded: seeded, vector: vector)
            return outcome(.fail, "C undefined: \(text)", tags: tags)
        case let .success(final):
            let comparison = compare(final: final, seeded: seeded, expected: vector.expected)
            if let mismatch = comparison.mismatches.first {
                return outcome(.fail, mismatch, tags: alternativeTags(function, seeded: seeded, vector: vector),
                               unmodeled: comparison.unmodeled)
            }
            if comparison.modeledChecks == 0, !comparison.unmodeled.isEmpty {
                return outcome(.unsupported, "flags-only output (\(comparison.unmodeled.joined(separator: ", "))); MacIR has no NZCV/FPSR state",
                               unmodeled: comparison.unmodeled)
            }
            if comparison.unmodeled.contains("FPSR") {
                return outcome(.unsupported, "FPSR output is not modeled; numeric data checks matched", unmodeled: comparison.unmodeled)
            }
            return outcome(.pass, "", unmodeled: comparison.unmodeled)
        }
    }

    private static func evaluate(_ function: MacIRFunction, seeded: A64MachineState,
                                 alternateSignedness: Bool = false,
                                 accessOverride: (bytes: Int, signExtend: Bool)? = nil)
        -> Result<A64MachineState, MacIRConcreteEvaluator.Failure> {
        var evaluator = MacIRConcreteEvaluator(function: function, state: seeded)
        evaluator.alternateSignedness = alternateSignedness
        evaluator.accessOverride = accessOverride
        do {
            try evaluator.run(function.instructions)
            return .success(evaluator.state)
        } catch let failure as MacIRConcreteEvaluator.Failure {
            return .failure(failure)
        } catch {
            return .failure(.harness("\(error)"))
        }
    }

    /// Whether a failing case would pass under the other signedness reading, or with another
    /// load/store access width. Diagnostic only: the case stays FAIL.
    private static func alternativeTags(_ function: MacIRFunction, seeded: A64MachineState, vector: A64OracleVector) -> [String] {
        func passes(_ result: Result<A64MachineState, MacIRConcreteEvaluator.Failure>) -> Bool {
            guard case let .success(final) = result else { return false }
            return compare(final: final, seeded: seeded, expected: vector.expected).mismatches.isEmpty
        }
        var tags: [String] = []
        if passes(evaluate(function, seeded: seeded, alternateSignedness: true)) { tags.append("signedness") }
        let touchesMemory = function.instructions.contains { instruction in
            switch instruction.operation {
            case .load, .store, .loadWriteback, .storeWriteback: return true
            case let .intrinsic(_, name, _): return name == "save_pair" || name == "restore_pair"
            default: return false
            }
        }
        if touchesMemory {
            for bytes in [1, 2, 4, 8, 16] {
                for signExtend in [false, true] where !(signExtend && bytes >= 8) {
                    if passes(evaluate(function, seeded: seeded, accessOverride: (bytes, signExtend))) {
                        tags.append("access-width(\(bytes)\(signExtend ? "s" : "u"))")
                        return tags
                    }
                }
            }
        }
        return tags
    }

    /// Selection fixtures consume an NZCV value with no compare before them; MacIR resolves a
    /// condition only through a preceding compare. Seed two unused registers so that
    /// `cmp xA, xB` produces exactly the fixture's NZCV, and lift the pair.
    private static func attemptWithSynthesizedCompare(row: InstructionRow, seeded: A64MachineState,
                                                      vector: A64OracleVector, decoded: String) -> Outcome? {
        guard let text = vector.inputs.nzcv, let flags = A64MachineState.nzcv(text) else { return nil }
        guard let operands = compareOperands[flags] else {
            return Outcome(vector: vector, decoded: decoded, status: .unsupported,
                           reason: "NZCV \(text) is not produced by any cmp; selection needs a compare in MacIR",
                           tags: [], unmodeled: [], viaSynthesizedCompare: true)
        }
        var used = Set((vector.inputs.gpr ?? [:]).keys.compactMap(A64MachineState.gprIndex))
        used.formUnion((vector.expected.gpr ?? [:]).keys.compactMap(A64MachineState.gprIndex))
        for token in row.operands.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let first = token.first, first == "x" || first == "w", let index = Int(token.dropFirst()) { used.insert(index) }
        }
        let candidates = [16, 17, 14, 15, 12, 13, 10, 11, 9, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28].filter { !used.contains($0) }
        guard candidates.count >= 2 else { return nil }
        var state = seeded
        state.x[candidates[0]] = operands.left
        state.x[candidates[1]] = operands.right
        let compare = InstructionRow(address: seeded.pc &- 4, bytes: "00 00 00 00", mnemonic: "cmp",
                                     operands: "x\(candidates[0]), x\(candidates[1])", hasBreakpoint: false, comment: nil)
        return attempt(rows: [compare, row], seeded: state, vector: vector, decoded: "cmp; \(decoded)", synthesized: true)
    }

    /// For each NZCV a 64-bit `cmp a, b` can produce, one (a, b) that produces it.
    static let compareOperands: [UInt8: (left: UInt64, right: UInt64)] = {
        let values: [UInt64] = [0, 1, 2, .max, .max - 1, 1 << 63, (1 << 63) - 1, (1 << 63) + 1, 0x7fff_ffff, 0x8000_0000]
        var table: [UInt8: (left: UInt64, right: UInt64)] = [:]
        for a in values {
            for b in values {
                let result = a &- b
                let n: UInt8 = result >> 63 == 1 ? 8 : 0
                let z: UInt8 = result == 0 ? 4 : 0
                let c: UInt8 = a >= b ? 2 : 0
                let v: UInt8 = ((a ^ b) & (a ^ result)) >> 63 == 1 ? 1 : 0
                let flags = n | z | c | v
                if table[flags] == nil { table[flags] = (a, b) }
            }
        }
        return table
    }()

    // MARK: Comparison

    struct Comparison {
        var mismatches: [String] = []
        var unmodeled: [String] = []
        var modeledChecks = 0
    }

    static func compare(final: A64MachineState, seeded: A64MachineState, expected: A64OracleVector.State) -> Comparison {
        var result = Comparison()
        let expectedGPR = expected.gpr ?? [:]
        for index in 0...30 {
            let want = expectedGPR["X\(index)"].flatMap(A64OracleHex.uint64) ?? seeded.x[index]
            if expectedGPR["X\(index)"] != nil { result.modeledChecks += 1 }
            if final.x[index] != want {
                result.mismatches.append("X\(index)=\(A64OracleHex.format64(final.x[index])) want \(A64OracleHex.format64(want))")
            }
        }
        let wantSP = expected.sp.flatMap(A64OracleHex.uint64) ?? seeded.sp
        if expected.sp != nil { result.modeledChecks += 1 }
        if final.sp != wantSP {
            result.mismatches.append("SP=\(A64OracleHex.format64(final.sp)) want \(A64OracleHex.format64(wantSP))")
        }
        let wantPC = expected.pc.flatMap(A64OracleHex.uint64) ?? (A64MachineState.defaultPC &+ 4)
        if expected.pc != nil { result.modeledChecks += 1 }
        if final.pc != wantPC {
            result.mismatches.append("PC=\(A64OracleHex.format64(final.pc)) want \(A64OracleHex.format64(wantPC))")
        }
        let expectedV = expected.vectors ?? [:]
        for index in 0...31 {
            let want = expectedV["V\(index)"].flatMap(A64OracleHex.uint128)
                .map { A64MachineState.V128(low: $0.low, high: $0.high) } ?? seeded.v[index]
            if expectedV["V\(index)"] != nil { result.modeledChecks += 1 }
            if final.v[index] != want {
                result.mismatches.append("V\(index)=\(A64OracleHex.format128(low: final.v[index].low, high: final.v[index].high)) want \(A64OracleHex.format128(low: want.low, high: want.high))")
            }
        }
        var wantMemory = seeded.memory
        for patch in expected.memory ?? [] {
            result.modeledChecks += 1
            guard let base = A64OracleHex.uint64(patch.address), let bytes = A64OracleHex.bytes(patch.bytes) else {
                result.mismatches.append("unreadable expected memory at \(patch.address)")
                continue
            }
            for (offset, byte) in bytes.enumerated() {
                let address = base &+ UInt64(offset)
                if byte == 0 { wantMemory.removeValue(forKey: address) } else { wantMemory[address] = byte }
            }
        }
        if final.memory != wantMemory {
            let addresses = Set(final.memory.keys).union(wantMemory.keys).sorted()
            if let first = addresses.first(where: { final.memory[$0] != wantMemory[$0] }) {
                result.mismatches.append("mem[\(A64OracleHex.format64(first))]=\(final.memory[first] ?? 0) want \(wantMemory[first] ?? 0)")
            }
        }
        if let text = expected.nzcv, let flags = A64MachineState.nzcv(text), flags != seeded.nzcv {
            result.unmodeled.append("NZCV")
        }
        if expected.fpsr != nil {
            result.unmodeled.append("FPSR")
        }
        return result
    }
}
