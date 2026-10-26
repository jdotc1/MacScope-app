import Foundation
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Numerical negative controls over the ACTUAL parsed candidate. SOURCE_ONLY /
/// NOT_RUN. Nothing here renders a document, executes an unchanged candidate,
/// reads a production plan, or supplies source register/branch values to it.
/// Call after the unchanged candidate's independently referenced scenario loop,
/// passing those completed references. A receipt requires parse, type checking,
/// normal return, complete frozen-script consumption and a semantic mismatch.
/// Missing/ambiguous AST sites and all infrastructure failures propagate.
enum OrdinaryCMutationControls {
    private typealias C = OrdinaryC
    struct Receipt: Equatable {
        let name: String
        let scenario: String
        let observation: String
    }
    struct Reference {
        let events: [RegionalCallOracle.Event]
        let memory: [UInt64: UInt8]
        let returned: Bool
        let terminal: UInt64?
        init(_ result: RegionalCallOracle.Result, terminal: UInt64? = nil) {
            events = result.events; memory = result.memory.bytes
            returned = result.returned; self.terminal = terminal
        }
        init(_ result: RegionalSwitchOracle.Result) {
            events = result.events; memory = result.memory.bytes
            returned = result.returned; terminal = nil
        }
    }

    static func color(_ original: OrdinaryC.Program, seed: RegionalSwitchSeed,
                      rows: [InstructionRow], scenarios: [RegionalSwitchOracle.Scenario],
                      references: [String: Reference]) throws -> [Receipt] {
        let store: Int, start: Int
        switch seed {
        case .jinit: store = 253; start = 251
        case .j12init: store = 246; start = 244
        default: throw C.Failure.invalidContract("mutation scope excludes j16")
        }
        try decoded(rows, at: store, mnemonic: "str", operands: "wzr, [x8], #0x60")
        try decoded(rows, at: start, mnemonic: "add", operands: "x8, x8, #0x94")
        let stride = try literalOperand(original, row: store, operation: "+", bits: 0x60)
        let pointer = try scalarDefinition(original, row: start) { rhs in
            descendants(rhs).contains { e in
                if case let .binary(op, _, rhs) = e.node { return op == "+" && literalBits(rhs) == 0x94 }
                return false
            }
        }
        let first = "gray-multiple-iterations", high = "gray-64-bit-pointer"
        return [
            try kill("color-zero-pointer-stride", scenario: first, original: original,
                     lines: replacing(original, span: stride.span, with: "0x0"),
                     input: colorScenario(first, scenarios, original.contract), reference: reference(first, references),
                     witness: .memoryAddress(store, false, 1)),
            // This high pointer crosses 0x200000000 before the first store.
            // Stores may define new bytes; no invalid load is used as the kill.
            try kill("color-X64-pointer-truncated-to-W32", scenario: high, original: original,
                     lines: replacing(original, span: pointer.rhs.span,
                                      with: "(uint64_t)((uint32_t)(\(text(original, pointer.rhs.span))))"),
                     input: colorScenario(high, scenarios, original.contract), reference: reference(high, references),
                     witness: .memoryAddress(store, false, 0))
        ]
    }

    static func upsampler(_ original: OrdinaryC.Program, seed: RegionalCallSeed,
                          rows: [InstructionRow], scenarios: [RegionalCallOracle.Scenario],
                          references: [String: Reference]) throws -> [Receipt] {
        guard seed == .jinit || seed == .j12init else { throw C.Failure.invalidContract("mutation scope excludes j16") }
        let first = seed == .jinit
        let advance = first ? 195 : 139, control = first ? 184 : 128
        let round = first ? 187 : 131, copy = first ? 188 : 132, join = first ? 194 : 138
        try decoded(rows, at: advance, mnemonic: "add", operands: "x25, x25, #0x60")
        try decoded(rows, at: control, mnemonic: "ldr", operands: "x28, [x8, #0x10]")
        try decoded(rows, at: round, mnemonic: "bl", operands: "_jround_up")
        try decoded(rows, at: copy, mnemonic: "mov", operands: "x2, x0")
        try decoded(rows, at: join, mnemonic: "str", operands: "x0, [x12, x22, lsl #3]")
        try decoded(rows, at: 39, mnemonic: "str", operands: "x0, [x19, #0x278]")
        let stride = try literalOperand(original, row: advance, operation: "+", bits: 0x60)
        let allocationName = try callName(original, row: 35)
        let allocation = try unique(statements(original.root).compactMap { statement -> C.Expression? in
            guard (try? original.row(at: statement.span)) == 39,
                  case let .assign(left, right) = statement.node, left.count == 1, right.count == 1,
                  case .load = left[0].node, depends(right[0], on: allocationName, in: original) else { return nil }
            return right[0]
        }, "actual allocation pointer store data", diagnostics: astEvidence(original, row: 39, requirement: "single memory store dependent on allocation call"))
        let roundName = try callName(original, row: round)
        let roundCopy = try scalarDefinition(original, row: copy) { depends($0, on: roundName, in: original) }
        let controlLoad = try scalarDefinition(original, row: control) { rhs in
            descendants(rhs).contains { if case .load = $0.node { return true }; return false }
        }
        let recurrence = "ordinary-store-aliases-loop-count"
        let high = "allocation-high64-return"
        let repeated = "current-X28-snapshot-and-later-control-reload"
        let joins = "multiple-distinct-joins-and-call-results"
        var result = [
            try kill("upsampler-zero-component-pointer-stride", scenario: recurrence, original: original,
                     lines: replacing(original, span: stride.span, with: "0x0"),
                     input: callScenario(recurrence, scenarios, original.contract), reference: reference(recurrence, references),
                     witness: .memoryAddress(first ? 71 : 72, true, 1)),
            try kill("upsampler-X64-allocation-truncated-to-W32", scenario: high, original: original,
                     lines: replacing(original, span: allocation.span,
                                      with: "(uint64_t)((uint32_t)(\(text(original, allocation.span))))"),
                     input: callScenario(high, scenarios, original.contract), reference: reference(high, references),
                     witness: .memoryData(39, 0)),
            try kill("upsampler-stale-other-predecessor-join-value", scenario: joins, original: original,
                     lines: freezingStoreData(original, row: join),
                     input: callScenario(joins, scenarios, original.contract), reference: reference(joins, references),
                     witness: .memoryData(join, 1)),
            try kill("upsampler-stale-prior-dynamic-round-result", scenario: repeated, original: original,
                     lines: freezingDefinition(original, definition: roundCopy, retainLoad: false),
                     input: callScenario(repeated, scenarios, original.contract), reference: reference(repeated, references),
                     witness: .callArgument(first ? 192 : 136, 1, 2)),
            // The real memory load still executes and is recorded on every visit;
            // only its import into the current scalar carrier is made stale.
            try kill("upsampler-missing-next-iteration-X28-import", scenario: repeated, original: original,
                     lines: freezingDefinition(original, definition: controlLoad, retainLoad: true),
                     input: callScenario(repeated, scenarios, original.contract), reference: reference(repeated, references),
                     witness: .callee(first ? 192 : 136, 1)),
            // Move the existing effect, never synthesize an extra read or change
            // the original call text. The ordinary source tag moves with it.
            try kill("upsampler-X28-load-moved-across-opaque-call", scenario: repeated, original: original,
                     lines: movingLoadRow(original, row: control, afterCall: round),
                     input: callScenario(repeated, scenarios, original.contract), reference: reference(repeated, references),
                     witness: .callee(first ? 192 : 136, 0))
        ]
        if first {
            try decoded(rows, at: 102, mnemonic: "bl", operands: "_jsimd_set_h1v2_fancy_upsample")
            try decoded(rows, at: 104, mnemonic: "cmp", operands: "w0, #0")
            try decoded(rows, at: 109, mnemonic: "csel", operands: "x9, x10, x9, eq")
            // Exact incoming edge108 ->109, with the distinct159/166 edge
            // retained unchanged. These are frozen bytes, not printed-name proof.
            for (row, address, bytes) in [(102, UInt64(0x3afb0), "37 74 00 94"),
                (104, 0x3afb8, "1f 00 00 71"), (108, 0x3afc8, "4a d1 0f 91"),
                (109, 0x3afcc, "49 01 89 9a"), (159, 0x3b094, "e6 73 00 94"),
                (161, 0x3b09c, "1f 00 00 71"), (166, 0x3b0b0, "c7 ff ff 17")] {
                guard rows.indices.contains(row), rows[row].address == address, rows[row].bytes == bytes else {
                    throw C.Failure.invalidContract("frozen CSEL incoming-edge bytes differ at row \(row)")
                }
            }
            let call = try callName(original, row: 102)
            let select = try unique(expressions(original.root).filter { e in
                guard (try? original.row(at: e.span)) == 109 else { return false }
                if case .select = e.node { return true }; return false
            }, "actual shared CSEL expression", diagnostics: astEvidence(original, row: 109, requirement: "unique select at source109"))
            guard case .select = select.node else { throw C.Failure.invalidContract("CSEL shape") }
            let widthMutation = try cselWidthMutation(in: original, selection: select, call: call)
            let widthCase = "fancy-h1v2-W0-zero-high64"
            // Read the original pre-truncation call result. Merely widening the
            // uint32_t join carrier would preserve its low bits and not mutate
            // the W-versus-X test. The protected call itself stays unchanged.
            result.append(try kill("CSEL-W32-test-widened-to-X64", scenario: widthCase, original: original,
                lines: replacing(original, span: widthMutation.span, with: widthMutation.replacement),
                input: callScenario(widthCase, scenarios, original.contract), reference: reference(widthCase, references),
                witness: .memoryData(110, 0)))
            let opposite = "same-execution-CSEL-writer-time-flags"
            result.append(try kill("CSEL-stale-previous-writer-time-condition", scenario: opposite, original: original,
                lines: freezingSelection(original, selection: select),
                input: callScenario(opposite, scenarios, original.contract), reference: reference(opposite, references),
                witness: .memoryData(110, 1)))
        } else {
            try decoded(rows, at: 76, mnemonic: "sdiv", operands: "w8, w8, w12")
            try decoded(rows, at: 77, mnemonic: "ldr", operands: "w10, [x19, #0x198]")
            try decoded(rows, at: 78, mnemonic: "ldr", operands: "w9, [x19, #0x19c]")
            try decoded(rows, at: 91, mnemonic: "lsl", operands: "w12, w11, #1")
            try decoded(rows, at: 92, mnemonic: "cmp", operands: "w12, w10")
            try decoded(rows, at: 93, mnemonic: "ccmp", operands: "w8, w9, #0, eq")
            try decoded(rows, at: 94, mnemonic: "b.eq", operands: "0x000000000003b934")
            let w8 = try scalarDefinition(original, row: 76) { _ in true }
            let w10 = try scalarDefinition(original, row: 77) { _ in true }
            let w9 = try scalarDefinition(original, row: 78) { _ in true }
            let w12 = try scalarDefinition(original, row: 91) { _ in true }
            // The same source conjunction may be emitted positively with its
            // taken arm first, or inverted with its fallthrough arm first.
            let condition = try ccmpCondition(in: original, lhs: w12.name, rhs: w10.name,
                secondLHS: w8.name, secondRHS: w9.name)
            guard case let .binary(_, left, right) = condition.node,
                  let replacementOperator = ccmpMutationOperator(condition, lhs: w12.name, rhs: w10.name,
                      secondLHS: w8.name, secondRHS: w9.name, in: original) else {
                throw C.Failure.invalidContract("CCMP oriented shape\n" + astDiagnostic(original, span: condition.span, reason: "selected condition no longer meets exact predicate contract"))
            }
            let name = "one-h2v2-bypass"
            result.append(try kill("CCMP-false-literal-conjunction-changed-to-disjunction", scenario: name, original: original,
                lines: replacing(original, span: condition.span,
                                 with: "((\(text(original, left.span))) \(replacementOperator) (\(text(original, right.span))))"),
                input: callScenario(name, scenarios, original.contract), reference: reference(name, references),
                witness: .memoryData(123, 0)))
        }
        return result
    }

    static func skip(_ original: OrdinaryC.Program, rows: [InstructionRow],
                     scenarios: [RegionalCallOracle.Scenario], references: [String: Reference]) throws -> [Receipt] {
        try decoded(rows, at: 24, mnemonic: "lsl", operands: "x9, x20, #8")
        let amount = try literalOperand(original, row: 24, operation: "<<", bits: 8)
        let name = "second-refill-changes-buffer-and-high64-count"
        // 0x2345 -> 0x11c5: both execute the same two callbacks and return1.
        // Wrong message data and skip argument, not a changed script, kill it.
        return [try kill("skip-wrong-length-byte-shift", scenario: name, original: original,
            lines: replacing(original, span: amount.span, with: "0x7"),
            input: callScenario(name, scenarios, original.contract), reference: reference(name, references),
            witness: .memoryData(34, 0))]
    }

    /// Deferred, not credited by this helper: jinit CCMP path mutation changes
    /// a SIMD call row under the current scripts (129 versus168), so it cannot
    /// be counted as a normal semantic kill. A same-call-shape real input or a
    /// separately contracted no-call boundary witness is required. Color shift
    /// mask mutations belong to the independently bound regional witnesses.
    /// Frozen call/exterior/return payloads must never be relaxed to close these.

    private enum Witness {
        case memoryAddress(Int, Bool, Int), memoryData(Int, Int)
        case callArgument(Int, Int, Int), callee(Int, Int)
    }
    private static func kill(_ name: String, scenario: String, original: C.Program,
                             lines: [C.TextLine], input: C.Scenario, reference: Reference, witness: Witness) throws -> Receipt {
        guard reference.returned else { throw C.Failure.invalidContract("\(name): reference did not return normally") }
        let mutant = try C.Program(lines: lines, contract: original.contract)
        // Keep the exact ordered K responses. The optional carrier assertions
        // are comparison conveniences, not K's outputs. Removing ONLY those
        // for this negative control lets its wrong actual carriers be recorded
        // and compared AFTER normal exit. Wrong call rows still fail at runtime.
        let input = C.Scenario(name: input.name, inputs: input.inputs, memory: input.memory,
            responses: input.responses.map { .init(row: $0.row, result: $0.result, writes: $0.writes,
                                                   expectedArguments: nil, expectedControl: nil) })
        let actual = try C.Machine(program: mutant, scenario: input).run()
        guard actual.returned, actual.consumedResponses == input.responses.count else {
            throw C.Failure.invalidContract("\(name): mutant did not consume the script and return normally")
        }
        do {
            try C.compare(actual, events: reference.events, memory: reference.memory, returned: reference.returned,
                          terminal: reference.terminal, contract: original.contract, name: name)
        } catch let failure as C.Failure {
            if case let .semanticMismatch(observation) = failure, observation.hasPrefix(name + ":") {
                try requireWitness(witness, actual: actual, reference: reference, name: name)
                return .init(name: name, scenario: scenario, observation: observation)
            }
            throw failure
        }
        throw C.Failure.invalidContract("\(name): numerical mutant survived; no mutation credit")
    }

    /// A changed load ordering alone cannot earn a numerical X28/control
    /// receipt. Each control must also change its named actual value/address.
    private static func requireWitness(_ witness: Witness, actual: C.Result, reference: Reference, name: String) throws {
        func memory(_ row: Int, loading: Bool, occurrence: Int, address: Bool) throws -> (UInt64, UInt64) {
            let source = reference.events.compactMap { event -> UInt64? in
                switch event {
                case let .load(site, location, _, bits) where loading && site == row: return address ? location : bits
                case let .store(site, location, _, bits) where !loading && site == row: return address ? location : bits
                default: return nil
                }
            }
            let candidate = actual.events.compactMap { event -> UInt64? in
                switch event {
                case let .load(site, _, location, _, bits) where loading && site.row == row: return address ? location : bits
                case let .store(site, _, location, _, bits) where !loading && site.row == row: return address ? location : bits
                default: return nil
                }
            }
            guard source.indices.contains(occurrence), candidate.indices.contains(occurrence) else {
                throw C.Failure.invalidContract("\(name): numerical witness occurrence missing at row \(row)")
            }
            return (source[occurrence], candidate[occurrence])
        }
        func call(_ row: Int, occurrence: Int) throws -> (RegionalCallOracle.Call, C.CallEvent) {
            let source = reference.events.compactMap { event -> RegionalCallOracle.Call? in
                if case let .call(value) = event, value.row == row, value.occurrence == occurrence { return value }; return nil
            }
            let candidate = actual.events.compactMap { event -> C.CallEvent? in
                if case let .call(value) = event, value.row == row, value.occurrence == occurrence { return value }; return nil
            }
            return (try unique(source, "source call occurrence"), try unique(candidate, "mutant call occurrence"))
        }
        let values: (UInt64, UInt64)
        switch witness {
        case let .memoryAddress(row, loading, occurrence):
            values = try memory(row, loading: loading, occurrence: occurrence, address: true)
        case let .memoryData(row, occurrence):
            values = try memory(row, loading: false, occurrence: occurrence, address: false)
        case let .callArgument(row, occurrence, argument):
            let (source, candidate) = try call(row, occurrence: occurrence)
            guard source.arguments.indices.contains(argument), candidate.arguments.indices.contains(argument) else {
                throw C.Failure.invalidContract("\(name): argument witness missing")
            }
            values = (source.arguments[argument].bits, candidate.arguments[argument].bits)
        case let .callee(row, occurrence):
            let (source, candidate) = try call(row, occurrence: occurrence)
            values = (try unique(source.control, "source control carrier").bits,
                      try unique(candidate.control, "candidate control carrier").bits)
        }
        guard values.0 != values.1 else {
            throw C.Failure.invalidContract("\(name): another mismatch occurred, but the named numerical witness did not differ")
        }
    }

    private struct Definition { let statement: C.Statement; let lhs: C.Expression; let rhs: C.Expression; let name: String }
    private static func scalarDefinition(_ program: C.Program, row: Int,
                                         matching: (C.Expression) -> Bool) throws -> Definition {
        let candidates = statements(program.root).compactMap { statement -> Definition? in
            guard (try? program.row(at: statement.span)) == row,
                  case let .assign(left, right) = statement.node, left.count == 1, right.count == 1,
                  case let .name(name) = left[0].node, matching(right[0]) else { return nil }
            return .init(statement: statement, lhs: left[0], rhs: right[0], name: name)
        }
        return try unique(candidates, "scalar operand at decoded row \(row)", diagnostics: astEvidence(program, row: row, requirement: "single scalar assignment/name with matching RHS predicate"))
    }
    private static func literalOperand(_ program: C.Program, row: Int, operation: String, bits: UInt64) throws -> C.Expression {
        let operands = expressions(program.root).compactMap { e -> C.Expression? in
            guard (try? program.row(at: e.span)) == row,
                  case let .binary(op, _, rhs) = e.node, op == operation else { return nil }
            let candidates = descendants(rhs).filter { if case let .literal(value) = $0.node { return value.bits == bits }; return false }
            return candidates.count == 1 ? candidates[0] : nil
        }
        return try unique(operands, "\(operation) literal operand at decoded row \(row)", diagnostics: astEvidence(program, row: row, requirement: "operation \(operation), unique literal \(bits)"))
    }
    private static func freezingDefinition(_ program: C.Program, definition: Definition, retainLoad: Bool) throws -> [C.TextLine] {
        guard let type = program.symbols[definition.name]?.type, !type.pointer,
              let rhsType = program.expressionTypes[definition.rhs.span], !rhsType.pointer else {
            throw C.Failure.invalidContract("unsupported snapshot scalar type")
        }
        let names = freshNames(program, count: 3), saved = names[0], seen = names[1], fresh = names[2]
        let rhs = try text(program, definition.rhs.span)
        if !retainLoad, !pure(definition.rhs) { throw C.Failure.invalidContract("stale scalar-copy mutation would skip an effect") }
        let value = retainLoad ? fresh : "(\(rhs))"
        let prefix = retainLoad ? "\(spelling(rhsType)) \(fresh) = \(rhs); " : ""
        let replacement = prefix + "\(definition.name) = (\(seen) != 0) ? \(saved) : \(value); "
            + "\(saved) = \(definition.name); \(seen) = 1;"
        var lines = try replacing(program, span: definition.statement.span, with: replacement)
        lines.insert(.init(text: "    \(spelling(type)) \(saved) = 0; uint32_t \(seen) = 0;", source: nil, envelope: .body), at: 1)
        return lines
    }
    private static func freezingStoreData(_ program: C.Program, row: Int) throws -> [C.TextLine] {
        let owner = try unique(statements(program.root).filter { statement in
            guard (try? program.row(at: statement.span)) == row,
                  case let .assign(left, right) = statement.node, left.count == 1, right.count == 1,
                  case .load = left[0].node else { return false }
            return true
        }, "actual shared-join store data", diagnostics: astEvidence(program, row: row, requirement: "single memory-store assignment"))
        guard case let .assign(left, right) = owner.node, case let .load(type, _) = left[0].node,
              pure(right[0]) else { throw C.Failure.invalidContract("shared-join store must have pure scalar data") }
        let names = freshNames(program, count: 2), saved = names[0], seen = names[1]
        let rhs = try text(program, right[0].span)
        let changed = try replacingText(program, whole: owner.span, part: right[0].span,
            with: "((\(seen) != 0) ? \(saved) : (\(rhs)))")
        var lines = try replacing(program, span: owner.span,
            with: changed + " \(saved) = \(rhs); \(seen) = 1;")
        lines.insert(.init(text: "    \(spelling(type)) \(saved) = 0; uint32_t \(seen) = 0;", source: nil, envelope: .body), at: 1)
        return lines
    }
    private static func freezingSelection(_ program: C.Program, selection: C.Expression) throws -> [C.TextLine] {
        guard case let .select(condition, _, _) = selection.node, pure(condition) else {
            throw C.Failure.invalidContract("CSEL condition must be a pure parsed scalar")
        }
        let owners = statements(program.root).filter { statement in
            if case let .assign(left, right) = statement.node {
                return left.count == 1 && right.count == 1 && contains(right[0].span, selection.span)
            }
            return false
        }
        let statement = try unique(owners, "scalar statement containing actual CSEL", diagnostics: [astDiagnostic(program, span: selection.span, reason: "requires unique scalar assignment owner")])
        let names = freshNames(program, count: 2), saved = names[0], seen = names[1]
        let old = try text(program, condition.span)
        let statementText = try replacingText(program, whole: statement.span, part: condition.span,
            with: "((\(seen) != 0) ? \(saved) : (\(old)))")
        var lines = try replacing(program, span: statement.span,
            with: statementText + " \(saved) = (\(old)); \(seen) = 1;")
        lines.insert(.init(text: "    uint32_t \(saved) = 0; uint32_t \(seen) = 0;", source: nil, envelope: .body), at: 1)
        return lines
    }
    private static func movingLoadRow(_ program: C.Program, row: Int, afterCall: Int) throws -> [C.TextLine] {
        let indices = program.lines.indices.filter { program.lines[$0].source.flatMap { program.contract.rowsByAddress[$0] } == row }
        guard let first = indices.first, let last = indices.last, indices == Array(first...last),
              !indices.isEmpty else { throw C.Failure.invalidContract("X28 reload source row is not one contiguous statement cluster") }
        let rowStatements = statements(program.root).filter { (try? program.row(at: $0.span)) == row }
        guard !rowStatements.isEmpty, rowStatements.allSatisfy({ s in
            if case let .assign(left, _) = s.node { return left.allSatisfy { if case .name = $0.node { return true }; return false } }
            return false
        }) else { throw C.Failure.invalidContract("X28 reload cluster contains non-scalar control/effects") }
        let targets = program.lines.indices.filter { index in
            program.lines[index].source.flatMap { program.contract.rowsByAddress[$0] } == afterCall &&
            String(program.lines[index].text.drop(while: { $0 == " " || $0 == "\t" })) == program.contract.calls[afterCall]?.payload
        }
        let target = try unique(targets, "protected round call line", diagnostics: astEvidence(program, row: afterCall, requirement: "exact protected call payload"))
        let callStatement = try unique(statements(program.root).filter { statement in
            if case let .call(site, _, _, _) = statement.node { return site == afterCall }; return false
        }, "protected round call AST", diagnostics: astEvidence(program, row: afterCall, requirement: "unique protected call AST"))
        guard rowStatements.allSatisfy({ $0.scopes == callStatement.scopes }) else {
            throw C.Failure.invalidContract("X28 timing mutation crosses a lexical scope, not just its opaque call")
        }
        guard last < target else { throw C.Failure.invalidContract("X28 load is not before the opaque call") }
        // Never move a value past an intervening read, which would turn this
        // numerical control into an uninitialized-read infrastructure failure.
        let defined = Set(rowStatements.flatMap { s -> [String] in
            guard case let .assign(left, _) = s.node else { return [] }
            return left.compactMap { if case let .name(name) = $0.node { return name }; return nil }
        })
        for s in statements(program.root) {
            guard let token = program.tokens[s.span.first..<s.span.last].first,
                  token.line - 1 > last, token.line - 1 <= target else { continue }
            let reads = readNames(s)
            guard reads.isDisjoint(with: defined) else {
                throw C.Failure.invalidContract("X28 timing mutation needs its full parsed snapshot chain; an intervening read would become uninitialized")
            }
        }
        var lines = program.lines
        let moved = Array(lines[first...last]); lines.removeSubrange(first...last)
        lines.insert(contentsOf: moved, at: target - moved.count + 1)
        return lines
    }

    private static func decoded(_ rows: [InstructionRow], at row: Int, mnemonic: String, operands: String) throws {
        guard rows.indices.contains(row), rows[row].mnemonic == mnemonic, rows[row].operands == operands else {
            throw C.Failure.invalidContract("frozen decoded mutation identity differs at row \(row)")
        }
    }
    private static func callName(_ program: C.Program, row: Int) throws -> String {
        guard let name = program.contract.calls[row]?.resultName else { throw C.Failure.invalidContract("missing frozen live call result \(row)") }; return name
    }
    private static func reference(_ name: String, _ values: [String: Reference]) throws -> Reference {
        guard let result = values[name] else { throw C.Failure.invalidContract("missing already-completed reference \(name)") }; return result
    }
    private static func colorScenario(_ name: String, _ scenarios: [RegionalSwitchOracle.Scenario], _ contract: C.Contract) throws -> C.Scenario {
        try C.scenario(unique(scenarios.filter { $0.name == name }, "frozen scenario \(name)"), contract: contract)
    }
    private static func callScenario(_ name: String, _ scenarios: [RegionalCallOracle.Scenario], _ contract: C.Contract) throws -> C.Scenario {
        try C.scenario(unique(scenarios.filter { $0.name == name }, "frozen scenario \(name)"), contract: contract)
    }
    private static func unique<T>(_ values: [T], _ identity: String, diagnostics: [String]? = nil) throws -> T {
        guard values.count == 1 else {
            let details = diagnostics ?? values.map { "candidate=\(String(describing: $0)); reason=non-AST uniqueness" }
            throw C.Failure.invalidContract("mutation AST gap: \(identity), found \(values.count), expected exactly1\n"
                + (details.isEmpty ? "candidate=<none>; reason=no candidate at required source" : details.joined(separator: "\n")))
        }
        return values[0]
    }
    private static func astDiagnostic(_ program: C.Program, span: C.Span, reason: String) -> String {
        let rendered = (try? text(program, span)) ?? "<source text unavailable>"
        let row = (try? program.row(at: span)).map { String($0) } ?? "unmapped"
        let phi = program.phiEdge(at: span).map { " block=\($0.blockAddress) predecessor=\($0.predecessorAddress)" } ?? ""
        return "candidate row=\(row)\(phi) rendered={\(rendered)}; reason=\(reason)"
    }
    private static func astEvidence(_ program: C.Program, row: Int, requirement: String) -> [String] {
        statements(program.root).filter { (try? program.row(at: $0.span)) == row }.map {
            astDiagnostic(program, span: $0.span, reason: "scoped observation; required filter: " + requirement + "; see actual uniqueness count")
        }
    }
    private static func literalBits(_ expression: C.Expression) -> UInt64? {
        if case let .literal(value) = expression.node { return value.bits }
        if case let .cast(_, child) = expression.node { return literalBits(child) }
        return nil
    }
    // Mutation-site recognition uses the comparison's effective C domain, not
    // identical operand spelling. SSA SDIV is i32 while LDR W is u32; their
    // usual arithmetic conversion is still exactly u32, never a wider test.
    private static func unsignedWord32Domain(_ a: C.Expression, _ b: C.Expression,
                                             in program: C.Program) -> Bool {
        guard let left = program.expressionTypes[a.span], let right = program.expressionTypes[b.span],
              !left.pointer, !right.pointer, left.width == 32, right.width == 32 else { return false }
        return (try? C.CType.common(left, right)) == .u32
    }
    static func firstWriterLow32Comparison(_ expression: OrdinaryC.Expression, call: String,
                                          in program: OrdinaryC.Program) -> Bool {
        guard (try? program.row(at: expression.span)) == 109,
              case let .binary(op, a, b) = expression.node, op == "==",
              program.expressionTypes[a.span] == .u32, literalBits(b) == 0,
              unsignedWord32Domain(a, b, in: program) else { return false }
        return depends(a, on: call, in: program)
    }
    static func word32Inequality(_ expression: OrdinaryC.Expression, lhs: String, rhs: String,
                                 in program: OrdinaryC.Program) -> Bool {
        guard case let .binary(op, a, b) = expression.node, op == "!=",
              case let .name(left) = a.node, case let .name(right) = b.node else { return false }
        return left == lhs && right == rhs && unsignedWord32Domain(a, b, in: program)
    }
    /// Resolve only this select's actual inline predicate or uniquely reaching
    /// Boolean carrier. Never search unrelated comparisons elsewhere in the AST.
    static func cselWidthMutation(in program: OrdinaryC.Program, selection: OrdinaryC.Expression,
                                  call: String) throws -> (span: OrdinaryC.Span, replacement: String) {
        guard (try? program.row(at: selection.span)) == 109,
              case let .select(condition, _, _) = selection.node else {
            throw cselFailure(program, selection: selection, reason: "source-bound CSEL required")
        }
        let inline: C.Expression?
        if firstWriterLow32Comparison(condition, call: call, in: program) { inline = condition }
        else if case let .binary("!=", inner, zero) = condition.node, literalBits(zero) == 0,
                firstWriterLow32Comparison(inner, call: call, in: program) { inline = inner }
        else { inline = nil }
        if let comparison = inline {
            guard case let .binary(_, low, _) = comparison.node else { throw cselFailure(program, selection: selection, reason: "CSEL comparison") }
            return (low.span, "(uint64_t)(\(call))")
        }
        guard case let .binary("!=", flag, zero) = condition.node, literalBits(zero) == 0,
              case let .name(name) = flag.node, program.expressionTypes[flag.span] == .i32 else {
            throw cselFailure(program, selection: selection, reason: "CSEL requires exact Boolean carrier != zero")
        }
        let owner = try unique(program.code.indices.filter { index in
            if case let .assign(_, values) = program.code[index].node {
                return values.contains { contains($0.span, selection.span) }
            }
            return false
        }, "CSEL executable owner", diagnostics: [astDiagnostic(program, span: selection.span, reason: "requires unique executable assignment owner")])
        let writers = program.code.indices.filter { writes(name, instruction: program.code[$0]) }
        guard let definition = exactIncomingFlagDefinition(writers: writers, use: owner, name: name, call: call, in: program) else {
            let diagnostics = writers.map { astDiagnostic(program, span: program.code[$0].span,
                reason: "actual flag write; selected108->109 edge not proven uniquely row102-dependent") }
            if writers.count != 1 {
                // Preserve the exact former refusal text for ambiguous edges.
                _ = try unique(writers, "CSEL flag definition (no redefinitions)", diagnostics: diagnostics)
            }
            throw C.Failure.invalidContract("CSEL flag definition does not dominate every use path\n"
                + astDiagnostic(program, span: selection.span, reason: "exact incoming edge is unproved")
                + "\n" + diagnostics.joined(separator: "\n"))
        }
        guard case let .assign(left, right) = program.code[definition].node,
              left.count == 1, right.count == 1, case .name(name) = left[0].node else {
            throw C.Failure.invalidContract("CSEL flag definition does not dominate every use path\n"
                + astDiagnostic(program, span: program.code[definition].span, reason: "definition is not an exact scalar assignment LHS"))
        }
        let rhs = right[0]
        let sourceBound = program.phiEdge(at: rhs.span).flatMap { program.contract.rowsByAddress[$0.blockAddress] } == 109
            || (program.phiEdge(at: rhs.span) == nil && (try? program.row(at: rhs.span)) == 109)
        guard sourceBound else { throw cselFailure(program, selection: selection, reason: "CSEL flag definition has unrelated source block") }
        let comparison: C.Expression
        if case let .select(_, positive, _) = rhs.node {
            // Resolver independently certifies all three equal, pure occurrences
            // and the exact sign/complement template. Only the signed32 form of
            // an explicit unsigned32 Boolean normalization is admitted here.
            guard program.representationCasts.contains(rhs.span),
                  case let .cast(signed, normalized) = positive.node, signed == .i32,
                  case let .cast(unsigned, inner) = normalized.node, unsigned == .u32 else {
                throw cselFailure(program, selection: selection, reason: "unproved CSEL Boolean transport")
            }
            comparison = inner
        } else { comparison = rhs }
        guard low32Comparison(comparison, call: call, in: program), pure(comparison) else {
            throw cselFailure(program, selection: selection, reason: "CSEL flag is not the source-bound low32 comparison")
        }
        // Comparison results are exactly0/1. Replacing the whole certified
        // Boolean transport coherently widens all repeated leaves at once.
        return (rhs.span, "((uint64_t)(\(call)) == 0x0)")
    }

    private static func cselFailure(_ program: C.Program, selection: C.Expression, reason: String) -> C.Failure {
        var details = [astDiagnostic(program, span: selection.span, reason: reason)]
        if case let .select(condition, _, _) = selection.node,
           case let .binary("!=", flag, _) = condition.node, case let .name(name) = flag.node {
            details += program.code.filter { writes(name, instruction: $0) }.map {
                astDiagnostic(program, span: $0.span, reason: "actual flag write; " + reason)
            }
        }
        return .invalidContract(reason + "\n" + details.joined(separator: "\n"))
    }

    /// Authority is conditional on the real108 ->109 incoming edge, not on
    /// global uniqueness at a join. Other/unowned incoming structures refuse.
    private static func exactIncomingFlagDefinition(writers: [Int], use: Int, name: String,
                                                    call: String, in program: C.Program) -> Int? {
        guard (1...2).contains(writers.count), let symbol = program.symbols[name], symbol.declared, !symbol.external,
              program.contract.rowsByAddress[0x3afc8] == 108,
              program.contract.rowsByAddress[0x3afcc] == 109,
              program.contract.rowsByAddress[0x3b0b0] == 166,
              program.contract.calls[102]?.resultName == call else { return nil }
        let otherCall = program.contract.calls[159]?.resultName
        guard writers.count == 1 || (otherCall != nil && otherCall != call) else { return nil }
        var selected: Int?, other: Int?
        for index in writers {
            // Declarations, reads, updates and phi arguments are not definitions.
            guard case let .assign(left, right) = program.code[index].node,
                  left.count == 1, right.count == 1, case .name(name) = left[0].node,
                  let edge = program.phiEdge(at: right[0].span), edge.blockAddress == 0x3afcc else { return nil }
            let comparison: C.Expression
            if case let .select(_, positive, _) = right[0].node {
                guard program.representationCasts.contains(right[0].span),
                      case let .cast(signed, bits) = positive.node, signed == .i32,
                      case let .cast(unsigned, inner) = bits.node, unsigned == .u32 else { return nil }
                comparison = inner
            } else { comparison = right[0] }
            guard pure(comparison) else { return nil }
            if edge.predecessorAddress == 0x3afc8,
               low32Comparison(comparison, call: call, in: program),
               !(otherCall.map { depends(comparison, on: $0, in: program) } ?? false), selected == nil { selected = index }
            else if let otherCall, edge.predecessorAddress == 0x3b0b0,
                    low32Comparison(comparison, call: otherCall, in: program),
                    !depends(comparison, on: call, in: program), other == nil { other = index }
            else { return nil }
        }
        guard let selected, writers.count == 1 || other != nil else { return nil }
        // Anchor at the actual ordinary predecessor ADD, not at the flag name
        // or its own definition (which would make dominance tautological).
        let predecessors = program.code.indices.filter { index in
            guard program.phiEdge(at: program.code[index].span) == nil,
                  (try? program.row(at: program.code[index].span)) == 108,
                  case let .assign(left, right) = program.code[index].node else { return false }
            guard left.count == 1, right.count == 1, case .name = left[0].node else { return false }
            return pure(right[0])
        }
        guard predecessors.count == 1, let predecessor = predecessors.first,
              predecessor < selected, selected < use else { return nil }
        var pending: [(Int, Bool)] = [(predecessor + 1, false)], seen: Set<Int> = [], reached = false
        while let (index, hasSelected) = pending.popLast() {
            guard program.code.indices.contains(index), index <= use else { return nil }
            guard seen.insert(index * 2 + (hasSelected ? 1 : 0)).inserted else { continue }
            if index == use { guard hasSelected else { return nil }; reached = true; continue }
            let instruction = program.code[index]
            var defined = hasSelected
            if case .declaration(name, _) = instruction.node { return nil }
            if writes(name, instruction: instruction) {
                guard index == selected, !defined else { return nil }
                defined = true
            }
            let next: [Int]
            switch instruction.node {
            case let .branch(_, yes, no): next = [yes, no]
            case let .jump(target): next = [target]
            case .returned, .unavailableReturn, .unresolved: return nil
            default: next = [index + 1]
            }
            for target in next {
                guard target > index, target <= use, program.code.indices.contains(target),
                      !(!instruction.scopes.contains(symbol.scope) && program.code[target].scopes.contains(symbol.scope)) else { return nil }
                pending.append((target, defined))
            }
        }
        return reached ? selected : nil
    }

    private static func low32Comparison(_ expression: C.Expression, call: String, in program: C.Program) -> Bool {
        guard case let .binary("==", a, b) = expression.node,
              program.expressionTypes[a.span] == .u32, literalBits(b) == 0,
              unsignedWord32Domain(a, b, in: program) else { return false }
        return depends(a, on: call, in: program)
    }

    private static func writes(_ name: String, instruction: C.Instruction) -> Bool {
        var values: [C.Expression] = []
        switch instruction.node {
        case let .assign(left, right):
            if left.contains(where: { if case .name(name) = $0.node { return true }; return false }) { return true }
            values = left + right
        case let .declaration(target, value):
            if target == name && value != nil { return true }; if let value { values = [value] }
        case let .call(_, target, control, arguments):
            if target == name { return true }; values = arguments; if let control { values.append(control) }
        case let .update(value), let .branch(value, _, _): values = [value]
        case let .returned(value): if let value { values = [value] }
        default: break
        }
        return values.flatMap(descendants).contains { if case .update(name, _, _) = $0.node { return true }; return false }
    }

    static func ccmpCondition(in program: OrdinaryC.Program, lhs: String, rhs: String,
                               secondLHS: String, secondRHS: String) throws -> OrdinaryC.Expression {
        var candidates: [C.Expression] = [], diagnostics: [String] = []
        for statement in statements(program.root) {
            guard case let .conditional(condition, _, _) = statement.node else { continue }
            let reason = ccmpRejection(condition, lhs: lhs, rhs: rhs, secondLHS: secondLHS, secondRHS: secondRHS, in: program)
            diagnostics.append(astDiagnostic(program, span: condition.span,
                reason: (reason ?? "accepted exact source/operator/definitions/domain") + "; " + ccmpCFGObservation(condition, in: program)))
            if reason == nil { candidates.append(condition) }
        }
        return try unique(candidates, "actual oriented CCMP writer/consumer conjunction", diagnostics: diagnostics)
    }
    static func ccmpMutationOperator(_ condition: OrdinaryC.Expression, lhs: String, rhs: String,
                                     secondLHS: String, secondRHS: String, in program: OrdinaryC.Program) -> String? {
        guard ccmpRejection(condition, lhs: lhs, rhs: rhs, secondLHS: secondLHS, secondRHS: secondRHS, in: program) == nil,
              case let .binary(op, _, _) = condition.node else { return nil }
        return op == "&&" ? "||" : "&&"
    }
    private static func ccmpRejection(_ condition: C.Expression, lhs: String, rhs: String,
                                      secondLHS: String, secondRHS: String, in program: C.Program) -> String? {
        guard (try? program.row(at: condition.span)) == 94 else { return "wrong source row; requires94" }
        guard case let .binary(op, a, b) = condition.node, op == "&&" || op == "||" else { return "requires positive AND or inverse OR" }
        let comparison = op == "&&" ? "==" : "!="
        func rejection(_ e: C.Expression, _ lhs: String, _ rhs: String) -> String? {
            guard case let .binary(operation, left, right) = e.node, operation == comparison else { return "requires both terms \(comparison)" }
            guard case let .name(actualLHS) = left.node, case let .name(actualRHS) = right.node,
                  actualLHS == lhs, actualRHS == rhs else { return "requires exact definition names \(lhs),\(rhs)" }
            guard unsignedWord32Domain(left, right, in: program) else {
                return "requires exact unsigned32 common domain; types=\(String(describing: program.expressionTypes[left.span])),\(String(describing: program.expressionTypes[right.span]))"
            }
            return nil
        }
        if let reason = rejection(a, lhs, rhs) { return "first term: " + reason }
        if let reason = rejection(b, secondLHS, secondRHS) { return "second term: " + reason }
        return nil
    }
    private static func ccmpCFGObservation(_ condition: C.Expression, in program: C.Program) -> String {
        let owners = program.code.indices.filter {
            if case let .branch(e, _, _) = program.code[$0].node { return e.span == condition.span }; return false
        }
        guard owners.count == 1, case let .branch(_, yes, no) = program.code[owners[0]].node else { return "diagnostic CFG owners=\(owners.count)" }
        return "diagnostic first arm rows=\(String(describing: firstArchitecturalRow(from: yes, in: program))),\(String(describing: firstArchitecturalRow(from: no, in: program))) (not an acceptance gate)"
    }

    private static func firstArchitecturalRow(from start: Int, in program: C.Program) -> Int? {
        var index = start, seen: Set<Int> = []
        while program.code.indices.contains(index), seen.insert(index).inserted {
            let instruction = program.code[index]
            switch instruction.node {
            case .nop, .declaration(_, nil): index += 1
            case let .jump(target): index = target
            case let .assign(left, right) where program.phiEdge(at: instruction.span) != nil
                && left.allSatisfy({ if case .name = $0.node { return true }; return false })
                && right.allSatisfy(pure): index += 1
            default: return try? program.row(at: instruction.span)
            }
        }
        return nil
    }

    private static func contains(_ whole: C.Span, _ part: C.Span) -> Bool { whole.first <= part.first && whole.last >= part.last }
    private static func spelling(_ type: C.CType) -> String { (type.unsigned ? "uint" : "int") + String(type.width) + "_t" }
    private static func pure(_ expression: C.Expression) -> Bool {
        !descendants(expression).contains { e in
            switch e.node { case .load, .field, .update: return true; default: return false }
        }
    }
    private static func freshNames(_ program: C.Program, count: Int) -> [String] {
        let used = Set(program.tokens.map(\.text)); var result: [String] = []; var index = 0
        while result.count < count {
            let name = "ordinary_mutation_snapshot_\(index)"; index += 1
            if !used.contains(name) { result.append(name) }
        }
        return result
    }
    private static func byteRange(_ program: C.Program, _ span: C.Span) throws -> Range<Int> {
        guard span.first < span.last, program.tokens.indices.contains(span.first), program.tokens.indices.contains(span.last - 1) else { throw C.Failure.invalidContract("mutation token span") }
        return program.tokens[span.first].byteOffset..<(program.tokens[span.last - 1].byteOffset + program.tokens[span.last - 1].text.utf8.count)
    }
    private static func text(_ program: C.Program, _ span: C.Span) throws -> String {
        let bytes = Array(program.lines.map(\.text).joined(separator: "\n").utf8)
        return String(decoding: bytes[try byteRange(program, span)], as: UTF8.self)
    }
    private static func replacingText(_ program: C.Program, whole: C.Span, part: C.Span, with replacement: String) throws -> String {
        guard contains(whole, part) else { throw C.Failure.invalidContract("mutation part outside owner") }
        let outer = try byteRange(program, whole), inner = try byteRange(program, part)
        var bytes = Array(try text(program, whole).utf8)
        bytes.replaceSubrange((inner.lowerBound - outer.lowerBound)..<(inner.upperBound - outer.lowerBound), with: replacement.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func replacing(_ program: C.Program, span: C.Span, with replacement: String) throws -> [C.TextLine] {
        let range = try byteRange(program, span), first = program.tokens[span.first], last = program.tokens[span.last - 1]
        guard first.line == last.line, !replacement.contains("\n") else { throw C.Failure.invalidContract("mutation requires one actual statement/expression line") }
        let line = first.line - 1
        guard program.lines[line].envelope == .body else { throw C.Failure.invalidContract("mutation touches envelope") }
        let row = program.lines[line].source.flatMap { program.contract.rowsByAddress[$0] }
        guard row != program.contract.terminalRow, row.flatMap({ program.contract.exterior[$0] }) == nil,
              row.flatMap({ program.contract.calls[$0] }) == nil else { throw C.Failure.invalidContract("mutation touches protected payload row") }
        let offset = program.lines.prefix(line).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(program.lines[line].text.utf8)
        bytes.replaceSubrange((range.lowerBound - offset)..<(range.upperBound - offset), with: replacement.utf8)
        var lines = program.lines
        lines[line] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[line].source, envelope: lines[line].envelope, phiEdge: lines[line].phiEdge)
        return lines
    }
    private static func depends(_ expression: C.Expression, on name: String, in program: C.Program) -> Bool {
        var definitions: [String: [C.Expression]] = [:]
        for statement in statements(program.root) {
            switch statement.node {
            case let .assign(left, right):
                for (lhs, rhs) in zip(left, right) { if case let .name(target) = lhs.node { definitions[target, default: []].append(rhs) } }
            case let .declaration(_, target, rhs): if let rhs { definitions[target, default: []].append(rhs) }
            default: break
            }
        }
        var visited: Set<String> = []
        func walk(_ e: C.Expression) -> Bool {
            for child in descendants(e) {
                if case let .name(local) = child.node {
                    if local == name { return true }
                    if visited.insert(local).inserted, definitions[local, default: []].contains(where: walk) { return true }
                }
            }
            return false
        }
        return walk(expression)
    }
    private static func readNames(_ statement: C.Statement) -> Set<String> {
        var expressions: [C.Expression] = []
        switch statement.node {
        case let .assign(left, right): expressions = right; for lhs in left { if case let .load(_, address) = lhs.node { expressions.append(address) } }
        case let .declaration(_, _, rhs), let .returned(rhs): if let rhs { expressions.append(rhs) }
        case let .call(_, _, control, args): expressions = args; if let control { expressions.append(control) }
        case let .conditional(e, _, _), let .whileLoop(e, _), let .doLoop(_, e), let .update(e): expressions = [e]
        case let .forLoop(_, e, _, _): if let e { expressions = [e] }
        default: break
        }
        return Set(expressions.flatMap(descendants).compactMap { e in
            switch e.node { case let .name(name), let .update(name, _, _): return name; default: return nil }
        })
    }
    private static func statements(_ root: C.Statement) -> [C.Statement] {
        var result: [C.Statement] = []
        func walk(_ s: C.Statement) {
            result.append(s)
            switch s.node {
            case let .compound(_, body): body.forEach(walk)
            case let .conditional(_, a, b): walk(a); if let b { walk(b) }
            case let .whileLoop(_, b), let .doLoop(b, _), let .label(_, b): walk(b)
            case let .forLoop(i, _, step, b): if let i { walk(i) }; walk(b); if let step { walk(step) }
            default: break
            }
        }
        walk(root); return result
    }
    private static func descendants(_ root: C.Expression) -> [C.Expression] {
        var result: [C.Expression] = []
        func walk(_ e: C.Expression) {
            result.append(e)
            switch e.node {
            case let .cast(_, e), let .unary(_, e), let .load(_, e), let .field(e, _): walk(e)
            case let .binary(_, a, b): walk(a); walk(b)
            case let .select(c, a, b): walk(c); walk(a); walk(b)
            case let .helper(_, args): args.forEach(walk)
            default: break
            }
        }
        walk(root); return result
    }
    private static func expressions(_ root: C.Statement) -> [C.Expression] {
        var result: [C.Expression] = []
        for statement in statements(root) {
            var direct: [C.Expression] = []
            switch statement.node {
            case let .declaration(_, _, e), let .returned(e): if let e { direct.append(e) }
            case let .assign(lhs, rhs): direct = lhs + rhs
            case let .update(e), let .conditional(e, _, _), let .whileLoop(e, _), let .doLoop(_, e): direct = [e]
            case let .forLoop(_, e, _, _): if let e { direct.append(e) }
            case let .call(_, _, c, args): direct = args; if let c { direct.append(c) }
            default: break
            }
            result += direct.flatMap(descendants)
        }
        return result
    }
}
