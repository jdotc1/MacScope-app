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

/// Tests-first, source-only addition. One complete captured lift/default print;
/// no authored instruction stream, decoder replay, or changed main expectation.
final class RegionalUnfoldedConditionTests: XCTestCase {
    // Stack-local read-only fence encloses setup, body and teardown. No shared
    // snapshot state is needed when suites or test instances execute in parallel.
    override func invokeTest() {
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        defer {
            let after = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]
            XCTAssertTrue(before.isEqual(to: after),
                          "Mode tests must not change the application preference domain")
        }
        super.invokeTest()
    }


    func testCapturedJ12EQRequiresExactSingleCMPSourceCertificate() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalSwitchFixture.make(.j12init)
            let function = fixture.function
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            let row = 205
            let original = function.instructions[row]
            let target: MacIRValue = .immediate(0x28e34)
            XCTAssertEqual(fixture.input.instructions, fixture.capture.input_rows)
            try fixture.requireCompleteInputAuthority()
            XCTAssertEqual(function.instructions.count, 321)
            XCTAssertEqual(cfg.blocks.count, 98)
            XCTAssertFalse(cfg.hasUnresolvedTargets)
            XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
            XCTAssertEqual(original.source.address, 0x28c70)
            XCTAssertEqual(original.source.byteText, "20 0e 00 54")
            XCTAssertEqual(original.source.mnemonic, "b.eq")
            XCTAssertEqual(original.source.operands, "0x0000000000028e34")
            XCTAssertNotNil(original.source.structuredOperands)
            XCTAssertEqual(original.source.structuredOperands, fixture.rows[row].structuredOperands)
            XCTAssertEqual(original.operation, .intrinsic(destination: nil, name: "branch_eq", arguments: [target]))
            XCTAssertEqual(CFGBuilder.terminatorKind(of: original.operation), .conditionalBranch(target: 0x28e34))
            XCTAssertEqual(cfg.blockByStartIndex[row], 61)
            XCTAssertEqual(cfg.blocks[61].instructionRange, 205..<206)
            XCTAssertEqual(cfg.blocks[61].predecessors, [34])
            XCTAssertEqual(cfg.blocks[61].successors, [97, 62])
            XCTAssertEqual(cfg.blocks[34].instructionRange, 122..<128)
            XCTAssertEqual(cfg.blocks[34].successors, [61, 35])
            XCTAssertEqual(cfg.blocks[97].startIndex, 318)
            XCTAssertEqual(function.instructions[318].source.address, 0x28e34)
            XCTAssertEqual(cfg.blocks[62].startIndex, 206)
            // Actual incoming path is CMP -> CBZ -> B.EQ. The lexical BL at
            // row194 is not on that path and may not supply or invalidate its flags.
            XCTAssertEqual(Array(fixture.rows[125...127]).map(\.mnemonic), ["ldr", "cmp", "cbz"])
            XCTAssertEqual(fixture.rows[126].operands, "w8, #1")
            XCTAssertEqual(fixture.rows[127].operands, "w9, 0x0000000000028c70")
            XCTAssertEqual(fixture.rows[194].mnemonic, "bl")
            XCTAssertEqual(fixture.rows[194].operands, "_build_ycc_rgb_table")

            if fixture.document.regionTree == nil {
                XCTAssertEqual(fixture.document.text, fixture.baselineText,
                               "PRE_REPAIR_CONTEXT_IDENTITY_REQUIRED: fallback must retain the complete native context")
            }

            let state = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg),
                "UNFOLDED_CONDITION_STATE_REQUIRED: admit the actual source-certified branch_eq before refusal controls")
            XCTAssertTrue(state.matches(function: function, cfg: cfg))
            // Narrowed source-certificate requirement: exact EQ of one CFG CMP's original-width
            // snapshots, not a general current-Z bridge. The superseded generic-Z
            // source and its RED receipt remain in next-unfolded-condition-tests.
            XCTAssertEqual(state.singleCMPBranches, [205: 126])
            func project(_ width: Int, _ value: MacIRValue) -> MacIRValue {
                .unary(op: "(uint\(width)_t)", value: value)
            }
            let snapshotA: MacIRValue = .register(name: "rgn_regional_t126_0", version: 0)
            let snapshotB: MacIRValue = .register(name: "rgn_regional_t126_1", version: 0)
            let w8 = project(64, project(32, .register(name: "rgn_regional_r8", version: 0)))
            let one = project(64, .immediate(1))
            let expectedA = project(64, project(64, project(32, w8)))
            let expectedB = project(64, project(64, project(32, one)))
            guard state.groups[126].count >= 2,
                  case let .assign(actualA, valueA) = state.groups[126][0],
                  case let .assign(actualB, valueB) = state.groups[126][1] else {
                return XCTFail("Original CMP operand snapshots must remain at row126")
            }
            XCTAssertEqual(actualA, snapshotA)
            XCTAssertEqual(actualB, snapshotB)
            XCTAssertEqual(valueA, expectedA)
            XCTAssertEqual(valueB, expectedB)
            let condition = try XCTUnwrap(state.branchConditions[row])
            XCTAssertEqual(condition.branchIndex, row)
            XCTAssertNil(condition.compareIndex, "CMP effects remain owned exactly once")
            XCTAssertEqual(condition.left, project(32, snapshotA))
            XCTAssertEqual(condition.condition, "==")
            XCTAssertEqual(condition.right, project(32, snapshotB))
            XCTAssertFalse(condition.isZeroCheck)
            XCTAssertTrue(condition.continuationGotoTargets.isEmpty)
            XCTAssertTrue(state.groups[205].isEmpty)
            let control = try XCTUnwrap(RegionTree.certifiedRegionalRecoveryPlan(
                function: function, cfg: cfg, certifiedBy: state),
                "UNFOLDED_CONDITION_CONTROL_REQUIRED: route this exact original intrinsic only under its state certificate")
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(control, to: cfg))
            let native = try nativeFixture(.j12init)
            let root = try XCTUnwrap(native.document.regionTree,
                "UNFOLDED_CONDITION_DEFAULT_REPAIR_REQUIRED: use the actual default document, never a substitute")
            // ordinary-C presentation supersession only. The physical-plan snapshots above
            // remain mandatory model checks. Native output may invert EQ and use
            // an ordinary SSA value, but must prove that value and both actual edges.
            // This is not the dispatch ledger's Boolean-normalization allowance.
            try requireNativeCMP(native, root: root)
            let ownedLines = native.document.lines(sourcedAt: original.source.address)
            XCTAssertFalse(ownedLines.isEmpty)
            XCTAssertFalse(ownedLines.contains { $0.text.contains("goto ") || $0.text.contains("__branch") })
            for token in ["goto 0x", "goto "] {
                XCTAssertLessThan(native.document.text.split(separator: "\n").filter { $0.contains(token) }.count,
                                  native.baselineText.split(separator: "\n").filter { $0.contains(token) }.count)
            }
            for payload in native.callPayloads {
                XCTAssertEqual(payload.after, [payload.baseline], "Exact original call payload at row \(payload.row)")
            }
            XCTAssertEqual(native.document.lines.filter { $0.text.hasSuffix("// call") }.count, 10)
            var options = DecompilerOptions.default
            options.structureControlFlow = true
            options.recoverGuardRegions = true
            XCTAssertNil(RegionTree.recoveryPlan(cfg: cfg, instructions: function.instructions,
                options: options, veto: .conditionalDoubleGuardToJoin),
                "Legacy recovery must not inherit certified admission of this complete input")

            // Deliberate contradictory IR, NOT newly decoded binary coverage. Each
            // mutation starts from the admitted original, preserving every native
            // source byte, sidecar, call, return, and all other function metadata.
            let contradictions: [(String, MacIROperation)] = [
                ("wrong condition suffix", .intrinsic(destination: nil, name: "branch_ne", arguments: [target])),
                ("wrong target", .intrinsic(destination: nil, name: "branch_eq", arguments: [.immediate(0x28e28)])),
                ("result-bearing intrinsic", .intrinsic(destination: .register(name: "x8", version: 99),
                                                       name: "branch_eq", arguments: [target])),
                ("extra argument", .intrinsic(destination: nil, name: "branch_eq", arguments: [target, .immediate(0)]))
            ]
            for (label, operation) in contradictions {
                var changed = function
                changed.instructions[row].operation = operation
                XCTAssertNotEqual(operation, original.operation, label)
                XCTAssertEqual(changed.instructions.map(\.source), function.instructions.map(\.source), label)
                var restored = changed
                restored.instructions[row].operation = original.operation
                XCTAssertEqual(restored, function, "Only the one IR operation changed: \(label)")
                let changedCFG = CFGBuilder.buildCFG(instructions: changed.instructions)
                if label != "wrong target" {
                    XCTAssertEqual(changedCFG.blocks, cfg.blocks, "Same topology cannot authorize \(label)")
                }
                XCTAssertFalse(state.matches(function: changed, cfg: changedCFG), label)
                XCTAssertNil(RegionalPhysicalStatePlan.prove(function: changed, cfg: changedCFG), label)
                XCTAssertNil(RegionTree.certifiedRegionalRecoveryPlan(
                    function: changed, cfg: changedCFG, certifiedBy: state), "Stale function certificate: \(label)")
            }
            var reversedCFG = cfg
            reversedCFG.blocks[61].successors.swapAt(0, 1)
            XCTAssertEqual(reversedCFG.blocks[61].successors, [62, 97])
            XCTAssertFalse(state.matches(function: function, cfg: reversedCFG))
            XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: reversedCFG),
                         "Preserving the edge set does not preserve taken/fallthrough order")
            XCTAssertNil(RegionTree.certifiedRegionalRecoveryPlan(
                function: function, cfg: reversedCFG, certifiedBy: state), "Stale CFG certificate")
        }
    }

    func testCapturedJ12EQKeepsSSAComparisonBinding() throws {
        guard SSAPropertyAssertions.enabled else { return }
        let fixture = try RegionalSwitchFixture.make(.j12init)
        let function = fixture.function
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let original = function.instructions[205]
        XCTAssertEqual(original.operation,
                       .intrinsic(destination: nil, name: "branch_eq", arguments: [.immediate(0x28e34)]))
        let info = try XCTUnwrap(function.ssaInfo)
        let branchRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: original.source.address))
        let compareRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: fixture.rows[126].address))
        let read = try XCTUnwrap(info.plan.rowReadBindings[branchRow][96])
        let write = try XCTUnwrap(info.plan.rowWriteBindings[compareRow][96])
        XCTAssertEqual(info.plan.canonicalID(read), info.plan.canonicalID(write),
                       "the implicit NZCV use binds CMP126, independently of lexical comparison state")
        XCTAssertEqual(info.plan.definitions[info.plan.canonicalID(read)].origin,
                       .instruction(fixture.rows[126].address))
        XCTAssertNil(info.plan.rowWriteBindings[compareRow + 1][96], "CBZ does not replace NZCV")
        XCTAssertNil(info.plan.rowWriteBindings[branchRow][96], "B.EQ only reads NZCV")
        XCTAssertEqual(cfg.blocks[61].predecessors, [34], "the sole incoming path has no intervening flag writer")
    }


    /// The native-document proofs read the actual flag-on default document; the
    /// certificate controls around them stay on the flag-off model function.
    private func nativeFixture(_ seed: RegionalSwitchSeed) throws -> RegionalSwitchFixture {
        return try MacIRConfiguration.$ssaOverride.withValue(true) {
            return try RegionalSwitchFixture.make(seed)
        }
    }

    private typealias C = OrdinaryC
    private typealias L = OrdinaryCSourceEdgeLedger
    private typealias O = RegionalSwitchOracle

    private struct NativeDefinition {
        let pc: Int
        let name: String
        let value: C.Expression
    }

    /// Bounded independent proof, not an alternate emitter or imported product
    /// certificate. Positive input is the complete real default document only.
    /// SOURCE ONLY / NOT RUN until a new selector receipt is recorded.
    private func requireNativeCMP(_ fixture: RegionalSwitchFixture, root: PseudocodeRegionNode) throws {
        let decoded = try O.Program(fixture: fixture)
        let source = try L.source(rows: fixture.rows, color: fixture.capture)
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try C.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.baselineText, callRows: fixture.seed.callRows, blockAddresses: blocks)
        let candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        let owned = descendants(root).filter { $0.conditionSourceAddress == fixture.rows[205].address }
        XCTAssertEqual(owned.count, 1, "One native structured owner, regardless of inverted if/else layout")
        let owner = try XCTUnwrap(owned.first)
        XCTAssertTrue(owner.kind == .ifThen || owner.kind == .ifThenElse)
        for row in [3, 125, 205] {
            let lines = fixture.document.lines(sourcedAt: fixture.rows[row].address)
            XCTAssertFalse(lines.isEmpty)
            XCTAssertTrue(lines.allSatisfy { $0.source == fixture.function.instructions[row].source },
                          "Native source annotation must retain the complete original span at row \(row)")
        }
        let branch = try nativeCMP(candidate, decoded: decoded, source: source)
        XCTAssertEqual(try C.lex(XCTUnwrap(owner.condition)).map(\.text),
                       candidate.tokens[branch.span.first..<branch.span.last].map(\.text),
                       "Region metadata and the actually parsed predicate must agree")

        // Deliberate mutations of this actual predicate only, not new binary
        // fixtures or numerical kills. Parsing, types and protected payloads
        // must succeed BEFORE the named independent proof refusal is credited.
        let value = try nativeDefinition(candidate, row: 125)
        let other = try nativeDefinition(candidate, row: 124)
        guard case let .compare("cmp", _, .immediate(otherImmediate)) = decoded.code[129],
              otherImmediate == 2, case let .binary(op, _, _) = branch.node else {
            throw C.Failure.invalidContract("CMP_NATIVE_NEGATIVE_WITNESS: missing actual other CMP129")
        }
        let mutations: [(String, String, String)] = [
            ("wrong original W32 carrier", "\(other.name) \(op) (uint32_t)(1)", "CMP_NATIVE_OPERAND"),
            ("wrong actual CMP129 writer", "\(value.name) \(op) (uint32_t)(\(otherImmediate))", "CMP_NATIVE_OPERAND"),
            ("widened equality", "(uint64_t)(\(value.name)) \(op) (uint64_t)(1)", "CMP_NATIVE_WIDTH"),
            ("inverted edge polarity", "\(value.name) \(op == "==" ? "!=" : "==") (uint32_t)(1)", "CMP_NATIVE_POLARITY"),
            // A26 negatives: the bare-literal acceptance must stay a faithful model.
            ("bare literal against uint64_t operand", "(uint64_t)(\(value.name)) \(op) 1", "CMP_NATIVE_WIDTH"),
            ("bare literal against int64_t operand", "(int64_t)(\(value.name)) \(op) 1", "CMP_NATIVE_WIDTH"),
            ("bare literal of 2^32 or more", "\(value.name) \(op) 0x100000001", "CMP_NATIVE_WIDTH"),
            ("relational operator with bare literal", "\(value.name) < 1", "CMP_NATIVE_WIDTH"),
            ("unproved operand type", "1 \(op) 1", "CMP_NATIVE_WIDTH")
        ]
        for (name, replacement, expected) in mutations {
            let changed = try C.Program(lines: replacing(candidate, span: branch.span, with: replacement), contract: contract)
            XCTAssertEqual(changed.lines.map(\.source), candidate.lines.map(\.source), name)
            try requireNativeRefusal(changed, decoded: decoded, source: source, expected: expected, name: name)
        }
        var wrongMetadata = candidate.lines
        let line = candidate.tokens[branch.span.first].line - 1
        wrongMetadata[line] = .init(text: wrongMetadata[line].text,
            source: fixture.rows[129].address, envelope: wrongMetadata[line].envelope)
        let mistagged = try C.Program(lines: wrongMetadata, contract: contract)
        XCTAssertEqual(mistagged.lines.map(\.text), candidate.lines.map(\.text))
        try requireNativeRefusal(mistagged, decoded: decoded, source: source,
            expected: "CMP_NATIVE_OWNER", name: "predicate attributed to wrong actual CMP129")
    }

    private func nativeCMP(_ candidate: C.Program, decoded: O.Program, source: L.Source) throws -> C.Expression {
        guard decoded.rows == source.rows, decoded.code.count == 321,
              case let .compare("cmp", register, .immediate(immediate)) = decoded.code[126],
              register.index == 8, register.width == 32, !register.zero, immediate == 1,
              case let .branch("eq", nil, target) = decoded.code[205], target == source.rows[318].address,
              source.branchTargets[205] == 318 else {
            throw C.Failure.invalidContract("CMP_NATIVE_SOURCE: exact original CMP/B.EQ required")
        }
        // Rebuild row predecessors from the complete independently reconstructed
        // decoded CFG. Walk every predecessor, stopping at the FIRST writer.
        // No lexical adjacency, observed branch values or product writer set.
        var predecessors: [Int: Set<Int>] = [:]
        for block in source.blocks {
            for row in block.rows.dropFirst() { predecessors[row, default: []].insert(row - 1) }
            for successor in block.successors {
                predecessors[source.blocks[successor].rows.lowerBound, default: []].insert(block.rows.upperBound - 1)
            }
        }
        var reachable: Set<Int> = [], work = [0]
        while let block = work.popLast() {
            if reachable.insert(block).inserted { work += source.blocks[block].successors }
        }
        guard reachable == Set(source.blocks.indices) else {
            throw C.Failure.invalidContract("CMP_NATIVE_SOURCE: unreachable source cannot supply a vacuous proof")
        }
        func origins(before row: Int, writing: (O.Instruction) throws -> Bool) throws -> Set<Int> {
            var pending = Array(predecessors[row, default: []]), seen: Set<Int> = [], writers: Set<Int> = []
            guard !pending.isEmpty else { throw C.Failure.invalidContract("CMP_NATIVE_ORIGIN: missing predecessor") }
            while let prior = pending.popLast() {
                if !seen.insert(prior).inserted { continue }
                if try writing(decoded.code[prior]) { writers.insert(prior); continue }
                guard prior != 0, let incoming = predecessors[prior], !incoming.isEmpty else {
                    throw C.Failure.invalidContract("CMP_NATIVE_ORIGIN: unknown entry origin")
                }
                pending += incoming
            }
            guard !writers.isEmpty else { throw C.Failure.invalidContract("CMP_NATIVE_ORIGIN: no actual writer") }
            return writers
        }
        // Also inspect every row on any CMP126-to-B.EQ205 path, not only
        // the final reaching writer. The actual path contains only CBZ127;
        // lexical BL194 is outside it and cannot supply or invalidate NZCV.
        var reachingBranch: Set<Int> = [], backward = [205]
        while let row = backward.popLast() {
            if reachingBranch.insert(row).inserted { backward += predecessors[row, default: []] }
        }
        var between: Set<Int> = [], forward = [126]
        while let row = forward.popLast() {
            if row == 205 || !between.insert(row).inserted { continue }
            forward += predecessors.keys.filter { reachingBranch.contains($0) && predecessors[$0, default: []].contains(row) }
        }
        guard between == [126, 127], reachingBranch.contains(126) else {
            throw C.Failure.invalidContract("CMP_NATIVE_ORIGIN: changed CMP-to-branch path or intervening writer")
        }
        let writers = try Set(decoded.code.indices.filter { try writesNZCV(decoded.code[$0]) })
        guard writers.count == 48, !writers.contains(127), try origins(before: 205, writing: writesNZCV) == [126],
              try origins(before: 126, writing: { writesRegister($0, index: 8) }) == [125],
              try origins(before: 125, writing: { writesRegister($0, index: 19) }) == [3] else {
            throw C.Failure.invalidContract("CMP_NATIVE_ORIGIN: wrong/ambiguous NZCV or original operand writer")
        }
        guard case let .memory("ldr", destinations, address) = decoded.code[125], destinations.count == 1,
              destinations[0].index == 8, destinations[0].width == 32, !destinations[0].zero,
              address.base.index == 19, address.base.width == 64, !address.base.zero,
              address.index == nil, address.offset == 60, address.update == .none,
              case let .move(baseRegister, .register(inputRegister)) = decoded.code[3],
              baseRegister.index == 19, baseRegister.width == 64, !baseRegister.zero,
              inputRegister.index == 0, inputRegister.width == 64, !inputRegister.zero else {
            throw C.Failure.invalidContract("CMP_NATIVE_LOAD: independent original W8/address source roles disagree")
        }
        let branches = candidate.code.enumerated().compactMap { pc, instruction -> (Int, C.Expression)? in
            guard case let .branch(expression, _, _) = instruction.node,
                  (try? candidate.row(at: expression.span)) == 205 else { return nil }
            return (pc, expression)
        }
        guard branches.count == 1, let (branchPC, expression) = branches.first else {
            throw C.Failure.invalidContract("CMP_NATIVE_OWNER: require exactly one parsed row205 predicate")
        }
        let loaded = try nativeDefinition(candidate, row: 125), base = try nativeDefinition(candidate, row: 3)
        guard case let .cast(baseType, input) = base.value.node, baseType == .u64,
              case let .name(inputName) = input.node,
              candidate.contract.inputs.contains(where: { $0.name == inputName && $0.entrySlot == 0 && $0.type == .jpegPointer }),
              case let .load(loadType, location) = loaded.value.node, loadType == .u32,
              candidate.memorySites[loaded.value.span] == .init(row: 125, effectOrdinal: 0),
              case let .binary("+", lhs, rhs) = location.node,
              case let .name(baseName) = lhs.node, baseName == base.name,
              case let .literal(offset) = rhs.node, offset.bits == address.offset,
              candidate.expressionTypes[lhs.span] == .u64,
              candidate.symbols[base.name]?.type == .u64,
              candidate.symbols[loaded.name]?.type == .u32 else {
            throw C.Failure.invalidContract("CMP_NATIVE_LOAD: native load/address differs from original source operands")
        }
        try dominates(base.pc, use: loaded.pc, in: candidate)
        try dominates(loaded.pc, use: branchPC, in: candidate)
        // A26: a bare non-negative literal below 2^32 is the same predicate as
        // `(uint32_t)(literal)` against a proved uint32_t operand under C's usual
        // arithmetic conversions (== or != only; the literal is i32/u32 typed).
        guard case let .binary(op, left, right) = expression.node, op == "==" || op == "!=",
              candidate.expressionTypes[left.span] == .u32 else {
            throw C.Failure.invalidContract("CMP_NATIVE_WIDTH: exact unsigned W32 operand equality required")
        }
        let constant: C.Expression
        if case let .literal(bare) = right.node {
            guard bare.bits < (1 << 32), bare.type == .i32 || bare.type == .u32 else {
                throw C.Failure.invalidContract("CMP_NATIVE_WIDTH: exact unsigned W32 operand equality required")
            }
            constant = right
        } else {
            guard candidate.expressionTypes[right.span] == .u32 else {
                throw C.Failure.invalidContract("CMP_NATIVE_WIDTH: exact unsigned W32 operand equality required")
            }
            guard case let .cast(type, inner) = right.node, type == .u32 else {
                throw C.Failure.invalidContract("CMP_NATIVE_OPERAND: predicate must read CMP126's original W8 snapshot and immediate1")
            }
            constant = inner
        }
        guard case let .name(name) = left.node, name == loaded.name,
              case let .literal(value) = constant.node, value.bits == immediate else {
            throw C.Failure.invalidContract("CMP_NATIVE_OPERAND: predicate must read CMP126's original W8 snapshot and immediate1")
        }
        // The ledger alone checks non-dispatch topology, not predicate meaning.
        // Bind both of its complete actual routes to this proven equality here.
        let report = try L.analyze(candidate: candidate, source: source)
        try report.requireCompleteTopology()
        let routes = report.routes.filter { $0.fromBlock == source.blockAtRow[205] }
        guard routes.count == 2 else { throw C.Failure.invalidContract("CMP_NATIVE_POLARITY: missing or duplicate branch route") }
        var outcomes: Set<Bool> = []
        for route in routes {
            guard route.entryPC == branchPC, route.choices.count == 1,
                  let choice = route.choices.first, choice.pc == branchPC, choice.expression == expression.span,
                  route.origins.count == 1, let origin = route.origins.first, origin.row == 205,
                  route.residualSpans.isEmpty else {
                throw C.Failure.invalidContract("CMP_NATIVE_POLARITY: extra predicate/transfer or missing exact source edge")
            }
            let equality = op == "==" ? choice.taken : !choice.taken
            guard origin.role == (equality ? .taken : .notTaken),
                  route.toBlock == source.blockAtRow[equality ? 318 : 206] else {
                throw C.Failure.invalidContract("CMP_NATIVE_POLARITY: EQ must reach318 and NE must reach206")
            }
            outcomes.insert(choice.taken)
        }
        guard outcomes == [false, true] else { throw C.Failure.invalidContract("CMP_NATIVE_POLARITY: both actual outcomes required") }
        return expression
    }

    private func nativeDefinition(_ candidate: C.Program, row: Int) throws -> NativeDefinition {
        let definitions = candidate.code.enumerated().compactMap { pc, instruction -> NativeDefinition? in
            guard (try? candidate.row(at: instruction.span)) == row,
                  case let .assign(left, right) = instruction.node, left.count == 1, right.count == 1,
                  case let .name(name) = left[0].node else { return nil }
            return .init(pc: pc, name: name, value: right[0])
        }
        guard definitions.count == 1, let result = definitions.first else {
            throw C.Failure.invalidContract("CMP_NATIVE_DEFINITION: one actual source-owned scalar definition required")
        }
        var inventory = C.Resolver(contract: candidate.contract, tokens: candidate.tokens)
        try inventory.gather(candidate.root)
        guard inventory.definitions[result.name]?.count == 1,
              !inventory.allExpressions.contains(where: { expression in
                  if case let .update(name, _, _) = expression.node { return name == result.name }; return false
              }) else {
            throw C.Failure.invalidContract("CMP_NATIVE_DEFINITION: snapshot has another static or nested write")
        }
        return result
    }

    private func dominates(_ definition: Int, use: Int, in candidate: C.Program) throws {
        func reachable(stoppingAt stop: Int?) throws -> Set<Int> {
            var seen: Set<Int> = [], pending = [0]
            while let pc = pending.popLast() {
                guard candidate.code.indices.contains(pc) else { throw C.Failure.invalidContract("CMP_NATIVE_DOMINANCE: invalid actual CFG") }
                if !seen.insert(pc).inserted || pc == stop { continue }
                switch candidate.code[pc].node {
                case let .branch(_, yes, no): pending += [yes, no]
                case let .jump(target): pending.append(target)
                case .returned, .unavailableReturn: break
                case .unresolved: throw C.Failure.invalidContract("CMP_NATIVE_DOMINANCE: unresolved actual edge")
                default: pending.append(pc + 1)
                }
            }
            return seen
        }
        let all = try reachable(stoppingAt: nil)
        guard all.contains(definition), all.contains(use),
              try !reachable(stoppingAt: definition).contains(use) else {
            throw C.Failure.invalidContract("CMP_NATIVE_DOMINANCE: original value definition does not dominate its actual use")
        }
    }

    private func writesRegister(_ instruction: O.Instruction, index: Int) -> Bool {
        switch instruction {
        case let .move(destination, _), let .arithmetic(_, destination, _, _, _),
             let .page(destination, _), let .relative(destination, _): return !destination.zero && destination.index == index
        case let .memory(op, registers, address):
            return (op.hasPrefix("ld") && registers.contains { !$0.zero && $0.index == index }) ||
                (address.update != .none && address.base.index == index)
        case .call: return index <= 18 || index == 30
        case .compare, .branch, .indirectBranch, .returned: return false
        }
    }

    private func writesNZCV(_ instruction: O.Instruction) throws -> Bool {
        switch instruction {
        case let .compare(op, _, _):
            guard ["cmp", "cmn", "tst"].contains(op) else { throw C.Failure.invalidContract("CMP_NATIVE_SOURCE: unclassified compare") }; return true
        case let .arithmetic(op, _, _, _, _):
            guard ["adds", "subs", "add", "sub", "and", "lsl"].contains(op) else { throw C.Failure.invalidContract("CMP_NATIVE_SOURCE: unclassified arithmetic") }
            return op == "adds" || op == "subs"
        case .call: return true
        case .branch, .memory, .move, .page, .relative, .indirectBranch, .returned: return false
        }
    }

    private func requireNativeRefusal(_ candidate: C.Program, decoded: O.Program, source: L.Source,
                                     expected: String, name: String) throws {
        do {
            _ = try nativeCMP(candidate, decoded: decoded, source: source)
            XCTFail("\(name): altered predicate passed its native CMP obligation")
        } catch let C.Failure.invalidContract(message) {
            XCTAssertTrue(message.hasPrefix(expected + ":"), "\(name): wrong refusal: \(message)")
        }
    }

    private func replacing(_ candidate: C.Program, span: C.Span, with text: String) throws -> [C.TextLine] {
        let first = candidate.tokens[span.first], last = candidate.tokens[span.last - 1]
        guard first.line == last.line, !text.contains("\n"),
              try candidate.row(at: span) == 205 else { throw C.Failure.invalidContract("CMP_NATIVE_MUTATION: not the actual row205 predicate") }
        let line = first.line - 1, offset = candidate.lines.prefix(line).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(candidate.lines[line].text.utf8)
        bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset + last.text.utf8.count - offset), with: text.utf8)
        var lines = candidate.lines
        lines[line] = .init(text: String(decoding: bytes, as: UTF8.self), source: lines[line].source, envelope: lines[line].envelope)
        return lines
    }

    private func descendants(_ node: PseudocodeRegionNode) -> [PseudocodeRegionNode] {
        [node] + node.children.flatMap(descendants)
    }
}
