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

/// Tests-first source only. No selector in this file has been executed by its
/// author. The two void cases are prospective behavioral REDs, NOT eligibility
/// evidence. An identity/load/compile error is not an acceptable behavioral RED.
final class DecodedRegionalSwitchTests: XCTestCase {
    func testCapturedInputsPreserveNativeContextAndCompatibilityIndices() throws {
        for seed in RegionalSwitchSeed.allCases {
            let capture = try RegionalSwitchFixture.load(seed)
            let input = try capture.restoredInput()
            XCTAssertEqual(input.functionName, seed.name)
            XCTAssertEqual(input.startAddress, seed.start)
            XCTAssertEqual(input.instructions, capture.input_rows)
            XCTAssertEqual(RegionalSwitchContext(input), capture.render_input_context)
            XCTAssertEqual(RegionalSwitchParameterIndex.capture(input), capture.signature_parameter_compatibility_indices)
            XCTAssertEqual(capture.signature_parameter_compatibility_indices.count, 424)
            XCTAssertEqual(capture.signature_parameter_compatibility_indices.filter { $0.compatibility_index != 0 }.count, 194)
            // Native schemas own nil/default omissions. Compare native semantics,
            // not re-encoded JSON spelling; the file SHA pins original spelling.
            let restoredContext = try JSONDecoder().decode(RegionalSwitchContext.self,
                from: JSONEncoder().encode(capture.render_input_context))
            let restoredRows = try JSONDecoder().decode([InstructionRow].self,
                from: JSONEncoder().encode(capture.input_rows))
            let roundTrip = try restoredContext.restore(rows: restoredRows,
                indices: capture.signature_parameter_compatibility_indices)
            XCTAssertEqual(roundTrip, input)
            XCTAssertEqual(RegionalSwitchParameterIndex.capture(roundTrip), capture.signature_parameter_compatibility_indices,
                           "native == omits compatibility indices, so this separate assertion is mandatory")
            XCTAssertEqual(input.types.count, 72)
            XCTAssertEqual(input.jumpTables.count, 30)
            XCTAssertEqual(input.constantStrings.count, 136)
            XCTAssertEqual(input.signatureOverrides.count, 115)
            XCTAssertEqual(input.authoredCallSignaturesByTarget.count, 115)
            XCTAssertNil(input.callerReturnWidth)
            XCTAssertTrue(input.nameOverrides.isEmpty)
            XCTAssertTrue(input.registerNameOverrides.isEmpty)
            XCTAssertTrue(input.stackLocalOverrides.isEmpty)
            XCTAssertTrue(input.objcSelectors.isEmpty)
            XCTAssertTrue(input.resolvedIndirectCalls.isEmpty)
            XCTAssertEqual(capture.input_roundtrip.count, 5)
            XCTAssertTrue(capture.input_roundtrip.values.allSatisfy { $0 })
            XCTAssertEqual(capture.projected_model_replay, "not performed")
            XCTAssertEqual(input.instructions.indices.filter { input.instructions[$0].mnemonic == "ret" }, [seed.returnRow])
            XCTAssertLessThan(seed.returnRow, input.instructions.count - 1,
                              "The real sole RET is NOT the physically last instruction")
            XCTAssertEqual(input.instructions.last?.mnemonic, "b")
            if seed == .j16initC4Negative {
                XCTAssertNil(input.signatureOverrides[seed.start])
                XCTAssertEqual(capture.authority_role, "fail_closed_c4_negative")
            } else {
                let signature = try XCTUnwrap(input.signatureOverrides[seed.start])
                XCTAssertEqual(signature.returnType, "void")
                guard case let .authoritative(parameters) = signature.parameterList else {
                    return XCTFail("captured authoritative parameter list is missing")
                }
                XCTAssertEqual(parameters.count, 1)
                XCTAssertEqual(capture.authority_role, "prospective_authoritative_void_not_proven_eligible")
            }
            XCTAssertEqual(capture.switch_facts.count, 2)
            for fact in capture.switch_facts { try checkCapturedSwitch(fact, input: input) }
            XCTAssertEqual(capture.calls.map(\.lifted_index), seed.callRows)
            for call in capture.calls {
                XCTAssertEqual(try RegionalSwitchContext.address(call.source_address), input.instructions[call.lifted_index].address)
                XCTAssertEqual(call.effect_ordinal, 0)
                XCTAssertTrue(capture.canonical_text.split(separator: "\n", omittingEmptySubsequences: false).contains(Substring(call.baseline_text)))
            }
            XCTAssertEqual(lines(containing: "goto 0x", in: capture.canonical_text), capture.baseline_counts.raw_goto_lines)
            XCTAssertEqual(lines(containing: "goto ", in: capture.canonical_text), capture.baseline_counts.total_goto_lines)
            XCTAssertEqual(lines(containing: "__branch(", in: capture.canonical_text), capture.baseline_counts.raw_branch_lines)
        }
    }

    func testJinitColorDeconverterPreservesCallsAndStructuresDefaultExport() throws {
        try checkProspectiveVoidRepair(.jinit)
    }

    func testJ12initColorDeconverterPreservesCallsAndStructuresDefaultExport() throws {
        try checkProspectiveVoidRepair(.j12init)
    }

    func testJ16ColorDeconverterRefusesUnprovedReturnAuthority() throws {
        let fixture = try RegionalSwitchFixture.make(.j16initC4Negative)
        XCTAssertNil(fixture.input.signatureOverrides[fixture.seed.start])
        XCTAssertEqual(fixture.function.returnType, "int64_t")
        let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
        XCTAssertEqual(cfg.blocks.count, fixture.capture.cfg_blocks.count)
        XCTAssertEqual(fixture.function.instructions.count, fixture.rows.count)
        for (actual, expected) in zip(fixture.function.instructions, fixture.rows) {
            XCTAssertEqual(actual.source.address, expected.address)
            XCTAssertEqual(actual.source.byteText, expected.bytes)
            XCTAssertEqual(actual.source.mnemonic, expected.mnemonic)
            XCTAssertEqual(actual.source.operands, expected.operands)
        }
        for expected in fixture.capture.cfg_blocks {
            let actual = try XCTUnwrap(cfg.blocks.first { $0.index == expected.index })
            XCTAssertEqual(actual.startIndex, expected.start_index)
            XCTAssertEqual(actual.endIndex, expected.end_index_exclusive)
            XCTAssertEqual(actual.predecessors, expected.predecessors)
            XCTAssertEqual(actual.successors, expected.successors)
        }
        if SSAPropertyAssertions.enabled {
            _ = try SSAWitnessAcceptance.requireColorConverterTerminal(fixture.function)
        } else {
            // The structural CFG union contains seven captured call definitions.
            // That overapproximation does not prove seven feasible paths, and
            // the lexical last call's x0_16 is not unique return authority.
            XCTAssertEqual(fixture.function.returnValue, .unknown("unresolved_return_contract"))
            XCTAssertEqual(fixture.function.instructions[281].operation,
                           .returnValue(.unknown("unresolved_return_contract")))
            XCTAssertNil(RegionalBoundaryPlan.prove(function: fixture.function, cfg: cfg))
            for version in [12, 16] {
                // These are deliberately forged typed proof inputs, not machine
                // executions or repaired return authority for the real capture.
                let value = MacIRValue.register(name: "x0", version: version)
                var forged = fixture.function
                forged.returnValue = value
                forged.instructions[281].operation = .returnValue(value)
                let boundary = try XCTUnwrap(RegionalBoundaryPlan.prove(function: forged, cfg: cfg))
                XCTAssertEqual(boundary.terminalRows, [281])
                XCTAssertEqual(boundary.terminal?.alias.value, value)
                XCTAssertEqual(boundary.terminal?.row, 281)
                XCTAssertEqual(boundary.terminal?.exportRow, 279)
                XCTAssertEqual(boundary.calls[198]?.result?.value, .register(name: "x0", version: 12))
                XCTAssertEqual(boundary.calls[259]?.result?.value, .register(name: "x0", version: 16))
                XCTAssertNil(RegionalPhysicalStatePlan.prove(function: forged, cfg: cfg))
                // One-arm source/typed contradiction: row277 remains LDR W8 in
                // captured bytes. Refusal is not claimed to isolate a later gate.
                var secondDefinition = forged
                secondDefinition.instructions[277].operation = .assign(
                    destination: .register(name: "x0", version: 17), source: .immediate(0))
                XCTAssertNil(RegionalPhysicalStatePlan.prove(function: secondDefinition, cfg: cfg))
            }
        }
        guard case let .call(_, result) = fixture.function.instructions[198].operation else {
            return XCTFail("captured C4 callback is missing")
        }
        XCTAssertEqual(result, .register(name: "x0", version: 12))
        XCTAssertEqual(fixture.rows[198].address, 0x2a9b4)
        XCTAssertEqual(fixture.rows[199].address, 0x2a9b8)
        // Exact captured path: row199 branches to 83, then 84/85 converge at 86.
        // No X0 write/call intervenes. A physical-X0 terminal import would newly
        // make x0_12 observable under the old printed x0_16 return: not authority.
        XCTAssertEqual(fixture.capture.cfg_blocks[83].successors, [85, 84])
        XCTAssertEqual(fixture.capture.cfg_blocks[84].successors, [86])
        XCTAssertEqual(fixture.capture.cfg_blocks[85].successors, [86])
        XCTAssertEqual(fixture.capture.cfg_blocks[86].end_index_exclusive, 282)
        if SSAPropertyAssertions.enabled {
            var flatOptions = DecompilerOptions.default
            flatOptions.structureControlFlow = false
            let flat = PseudocodePrinter(options: flatOptions).print(function: fixture.function,
                types: fixture.input.types, nameOverrides: fixture.input.nameOverrides,
                registerNameOverrides: fixture.input.registerNameOverrides,
                stackLocalOverrides: fixture.input.stackLocalOverrides,
                resolvedIndirectCalls: fixture.input.resolvedIndirectCalls)
            RenderProperties.assertSameStatements(fixture.document, flat)
        } else {
            let oldReturn = "return x0_16; // return"
            XCTAssertEqual(fixture.baselineText.components(separatedBy: oldReturn).count - 1, 1,
                           "the independent capture must identify exactly one historical terminal")
            let expected = fixture.baselineText.replacingOccurrences(of: oldReturn,
                with: "return unresolved_return_contract; // return")
            XCTAssertEqual(fixture.document.text, expected,
                           "C4_REFUSAL_REQUIRED: only the unsupported terminal expectation changes")
            XCTAssertEqual(fixture.document.lines(sourcedAt: fixture.rows[281].address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, ["return unresolved_return_contract; // return"])
        }
        XCTAssertNil(fixture.document.regionTree)
        XCTAssertFalse(fixture.document.lines.contains { $0.kind == .declaration && $0.text.contains("rgn_regional_") })
        checkCalls(fixture)
    }

    // Source-only regressions. Each positive is the real complete captured byte
    // stream; invalid documents/typed inputs below never replace its authority.
    func testByteBackedTwoSiteSwitchOwnershipInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalSwitchSeed.jinit, .j12init] {
                    try checkProspectiveVoidRepair(seed)
                }
            }
        }
    }

    func testByteBackedIncompleteResidualInventoryRefusesInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalSwitchSeed.jinit, .j12init] {
                    let fixture = try RegionalSwitchFixture.make(seed)
                    try fixture.requireCompleteInputAuthority()
                    let report = try OriginalDispatchOwnership.verify(fixture)
                    let original = try ownershipCandidate(fixture)
                    let source = try OrdinaryCSourceEdgeLedger.source(rows: fixture.rows, color: fixture.capture)
                    // This conditional occurrence is present in all four owner dumps.
                    // Its taken edge skips the real payload in block2; it is not
                    // an assumed unconditional fallthrough shape.
                    let origin = try XCTUnwrap(source.origins.first {
                        $0.row == 10 && $0.role == .taken && $0.edge.fromBlock == 1 && $0.edge.toBlock == 3
                    })
                    XCTAssertEqual(source.blocks[1].successors, [3, 2])
                    let slots = report.residualSlots.filter { $0.origins == [origin] }
                    XCTAssertEqual(slots.count, 1)
                    let slot = try XCTUnwrap(slots.first)
                    XCTAssertEqual(slot.pc, ssa ? 31 : 27)
                    XCTAssertEqual(slot.span, .init(first: ssa ? 218 : 204, last: ssa ? 221 : 207))
                    XCTAssertEqual(original.tokens[slot.span.first].line, ssa ? 29 : 16)
                    let account = try XCTUnwrap(report.accounts.first { $0.origin == origin })
                    XCTAssertFalse(account.routeIndices.isEmpty)
                    XCTAssertEqual(account.residualSpans, [slot.span])
                    XCTAssertTrue(account.routeIndices.allSatisfy { report.routes[$0].residualSpans.contains(slot.span) })

                    func nextLiteralBlock(from start: Int) throws -> Int {
                        var pc = start, seen: Set<Int> = []
                        while original.code.indices.contains(pc), seen.insert(pc).inserted {
                            if let block = report.anchors[pc] { return block }
                            switch original.code[pc].node {
                            case let .jump(target): pc = target
                            case .nop: pc += 1
                            default:
                                throw OrdinaryC.Failure.invalidContract("residual witness continuation is not administrative")
                            }
                        }
                        throw OrdinaryC.Failure.invalidContract("residual witness continuation has no literal anchor")
                    }
                    // Removing only the goto enters block2 instead of target3.
                    XCTAssertEqual(try nextLiteralBlock(from: slot.pc + 1), 2)
                    let index = original.tokens[slot.span.first].line - 1
                    XCTAssertEqual(fixture.document.lines[index].text.trimmingCharacters(in: .whitespaces),
                        "goto L_\(String(fixture.rows[18].address, radix: 16));")
                    var changed = fixture.document
                    changed.lines[index].text = "    // removed actual residual transfer"
                    changed.lines[index].tokens = []
                    let mutant = replacingDocument(fixture, with: changed)
                    XCTAssertEqual(mutant.rows, fixture.rows)
                    let candidate = try ownershipCandidate(mutant) // grammar/type errors earn no refusal credit
                    let actualGotos = candidate.tokens.filter { $0.text == "goto" }.count
                    XCTAssertEqual(actualGotos, original.tokens.filter { $0.text == "goto" }.count - 1)
                    XCTAssertNotEqual(report.residualSlots.count, actualGotos,
                        "the unchanged inventory count clause must reject the stale complete inventory")
                    let incomplete = try OrdinaryCSourceEdgeLedger.analyze(candidate: candidate, source: source)
                    XCTAssertEqual(incomplete.accounts.filter { $0.origin == origin }.map(\.disposition), [.unresolved])
                    let missingOrigin = "block 1, successor 0, taken, target 3, row 10"
                    XCTAssertTrue(incomplete.gaps.contains {
                        $0.kind == "unaccounted-source-origin" && $0.detail == missingOrigin
                    })
                    XCTAssertThrowsError(try incomplete.requireCompleteTopology()) { error in
                        guard case let OrdinaryC.Failure.invalidContract(reason) = error else {
                            return XCTFail("unrelated residual refusal: \(error)")
                        }
                        XCTAssertTrue(reason.hasPrefix("SOURCE_EDGE_COVERAGE_GAP:"))
                        XCTAssertTrue(reason.contains("unaccounted-source-origin: \(missingOrigin)"))
                    }
                    XCTAssertThrowsError(try OriginalDispatchOwnership.verify(mutant)) { error in
                        guard case let OrdinaryC.Failure.invalidContract(reason) = error else {
                            return XCTFail("unrelated ownership refusal: \(error)")
                        }
                        XCTAssertTrue(reason.hasPrefix("SOURCE_EDGE_COVERAGE_GAP:"))
                        XCTAssertTrue(reason.contains("unaccounted-source-origin: \(missingOrigin)"))
                    }
                }
            }
        }
    }

    func testByteBackedMissingOrMergedDispatchIdentityRefusesInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalSwitchSeed.jinit, .j12init] {
                    let fixture = try RegionalSwitchFixture.make(seed)
                    try fixture.requireCompleteInputAuthority()
                    _ = try OriginalDispatchOwnership.verify(fixture)
                    let sites = try fixture.capture.switch_facts.map {
                        try RegionalSwitchContext.address($0.source_address)
                    }
                    XCTAssertEqual(Set(sites).count, 2)
                    let indices = fixture.document.lines.indices.filter {
                        fixture.document.lines[$0].sourceAddress == sites[1]
                    }
                    XCTAssertFalse(indices.isEmpty)
                    for merge in [false, true] {
                        var changed = fixture.document
                        for index in indices {
                            if merge { changed.lines[index].source?.address = sites[0] }
                            else { changed.lines[index].source = nil }
                            changed.lines[index].tokens = []
                        }
                        XCTAssertEqual(changed.text, fixture.document.text)
                        XCTAssertEqual(changed.regionTree, fixture.document.regionTree,
                                       "a forged structured claim must not substitute for original site inventory")
                        let mutant = replacingDocument(fixture, with: changed)
                        _ = try ownershipCandidate(mutant) // do not count a grammar/type refusal
                        XCTAssertThrowsError(try OriginalDispatchOwnership.verify(mutant)) { error in
                            guard case OrdinaryC.Failure.invalidContract = error else {
                                return XCTFail("unrelated dispatch-identity refusal: \(error)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testByteBackedProductProofRejectsMissingOrMergedDispatchSites() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            for seed in [RegionalSwitchSeed.jinit, .j12init] {
                let fixture = try RegionalSwitchFixture.make(seed)
                try fixture.requireCompleteInputAuthority()
                let function = fixture.function
                let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
                let state = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg))
                let rows = fixture.capture.switch_facts.map(\.lifted_index)
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(Set(state.switches.keys), Set(rows))
                for row in rows {
                    XCTAssertEqual(state.switches[row]?.guardRow, row - 6,
                                   "the elision authority is the original captured bounds guard")
                }
                for merge in [false, true] {
                    var changed = function
                    if merge { changed.instructions[rows[1]].source.address = changed.instructions[rows[0]].source.address }
                    else {
                        changed.instructions[rows[1]].operation = .intrinsic(destination: nil,
                            name: "branch_register", arguments: [])
                    }
                    let changedCFG = CFGBuilder.buildCFG(instructions: changed.instructions)
                    XCTAssertFalse(state.matches(function: changed, cfg: changedCFG))
                    XCTAssertNil(RegionalPhysicalStatePlan.prove(function: changed, cfg: changedCFG),
                                 "missing/merged original identities cannot acquire a new elision proof")
                }
            }
        }
    }

    func testByteBackedSignedWordCMPPredicatesInBothModes() throws {
        let values: [UInt64] = [0, 1, 2, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff]
        let cases: [(bytes: [UInt8], bound: Int64, condition: String, expected: [UInt64])] = [
            // LDR W8,[X0]; CMP W8,#0; B.LE +8; STR W8,[X0,#4]; RET.
            ([0x08,0x00,0x40,0xb9, 0x1f,0x01,0x00,0x71, 0x4d,0x00,0x00,0x54,
              0x08,0x04,0x00,0xb9, 0xc0,0x03,0x5f,0xd6], 0, "<=", [1,0,0,0,1,1]),
            // Identical flow, CMP W8,#2 and B.LT +8.
            ([0x08,0x00,0x40,0xb9, 0x1f,0x09,0x00,0x71, 0x4b,0x00,0x00,0x54,
              0x08,0x04,0x00,0xb9, 0xc0,0x03,0x5f,0xd6], 2, "<", [1,1,0,0,1,1])
        ]
        for item in cases {
            let rows = try signedWordRows(item.bytes)
            XCTAssertEqual(rows[0].mnemonic, "ldr")
            XCTAssertEqual(rows[0].operands, "w8, [x0]")
            XCTAssertEqual(rows[1].mnemonic, "cmp")
            for ssa in [false, true] {
                let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(
                    name: "signed_word_cmp", startAddress: 0x7000, instructions: rows)
                XCTAssertEqual(function.ssaEnabled, ssa, "the primary SSA case is a real control")
                let load = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7000 })
                let branch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
                guard case let .load(destination, _) = load.operation,
                      case let .conditionalBranch(condition, left, right, target) = branch.operation else {
                    return XCTFail("byte-backed load/branch shape was not retained")
                }
                XCTAssertEqual(condition, item.condition)
                XCTAssertEqual(target, .immediate(0x7010))
                if case let .binaryExpression(marker, original,
                    .binaryExpression(context, .immediate(32), partner)) = left {
                    XCTAssertEqual(marker, MacIRBuilder.signedProjectionOperator)
                    XCTAssertEqual(context, MacIRBuilder.projectionContextOperator)
                    XCTAssertEqual(original, destination)
                    XCTAssertEqual(partner, .immediate(item.bound))
                } else {
                    XCTFail("the signed word predicate must retain its exact width and partner")
                }
                XCTAssertEqual(MacIRBuilder.droppingSignedProjection(left), destination)
                XCTAssertEqual(MacIRBuilder.droppingSignedProjection(right), .immediate(item.bound))
                let names = PseudocodeNameContext(function: function,
                    registerNameOverrides: ["w8": "source_word"])
                // conditionText delegates to the identical branch renderCondition.
                let statement = PseudocodePrinter(options: .default).render(operation: .compareToBool(
                    destination: .temporary(0), condition: condition, left: left, right: right), names: names)
                let signature = "int32_t signed_word_predicate(uint32_t source_word) {"
                let terminal = "return tmp_0;"
                // 0x7100 is test-observation scaffolding, not an encoded RET or
                // authority to return anything from the original machine function.
                let observation: UInt64 = 0x7100
                let contract = OrdinaryC.Contract(signature: signature,
                    inputs: [.init(name: "source_word", type: .u32, entrySlot: 8)],
                    fields: [], calls: [:], exterior: [:], terminalRow: 99,
                    terminalPayload: terminal, terminalName: "tmp_0", returnType: .i32,
                    rowsByAddress: [branch.source.address: 2, observation: 99], allowedLabels: [],
                    memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
                let program = try OrdinaryC.Program(lines: [
                    .init(text: signature, source: nil, envelope: .signature),
                    .init(text: statement + ";", source: branch.source.address, envelope: .body),
                    .init(text: terminal, source: observation, envelope: .body),
                    .init(text: "}", source: nil, envelope: .closingBrace)
                ], contract: contract)
                for (index, bits) in values.enumerated() {
                    let result = try OrdinaryC.Machine(program: program, scenario: .init(
                        name: "signed-word-\(ssa)-\(item.bound)-\(bits)",
                        inputs: ["source_word": .init(bits, .u32)], memory: [:], responses: [])).run()
                    XCTAssertTrue(result.returned)
                    XCTAssertEqual(result.terminal?.bits, item.expected[index],
                        "the emitted C predicate must interpret the source W32 sign bit")
                }
            }
        }
    }

    func testByteBackedNativeSignedCMPRejectsOtherFlagSources() throws {
        let bytes: [UInt8] = [
            0x08,0x00,0x40,0xb9, 0x1f,0x01,0x00,0x71, 0x4d,0x00,0x00,0x54,
            0x08,0x04,0x00,0xb9, 0xc0,0x03,0x5f,0xd6
        ]
        let original = try signedWordRows(bytes)
        let contradictoryWords = [
            "0a 01 09 2b", // ADDS W10,W8,W9, not CMP immediate.
            "3f 01 00 71", // CMP W9,#0, not the retained W8 operand.
            "1f 05 00 71", // CMP W8,#1, not the retained #0 operand.
            "1f 01 00 f1", // CMP X8,#0, not a W32 word.
            "1f 05 40 71", // CMP W8,#1,LSL#12, outside the unshifted gate.
            "1f 01 00"     // No complete instruction word.
        ]
        for word in contradictoryWords {
            var rows = original
            rows[1].bytes = word
            let function = MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "contradictory_word_cmp", startAddress: 0x7000, instructions: rows)
            let branch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
            guard case let .conditionalBranch(_, left, _, _) = branch.operation else {
                return XCTFail("unchanged native comparison route is missing")
            }
            XCTAssertEqual(MacIRBuilder.droppingSignedProjection(left), left,
                "a byte/operand mismatch must not mint the native signed-CMP projection")
        }
        // A genuine ADDS source is not merely contradictory metadata. It must
        // remain outside this CMP-only repair, including its INT32_MIN seam.
        let adds = try signedWordRows([
            0x08,0x00,0x40,0xb9, 0x09,0x04,0x40,0xb9, 0x0a,0x01,0x09,0x2b,
            0x4a,0x00,0x00,0x54, 0x08,0x08,0x00,0xb9, 0xc0,0x03,0x5f,0xd6
        ])
        XCTAssertEqual(adds[2].mnemonic, "adds")
        XCTAssertEqual(adds[2].operands, "w10, w8, w9")
        let function = MacIRBuilder(ssaEnabled: false).buildFunction(
            name: "signed_adds_control", startAddress: 0x7000, instructions: adds)
        let branch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x700c })
        guard case let .conditionalBranch(_, left, _, _) = branch.operation else {
            return XCTFail("existing ADDS comparison route is missing")
        }
        XCTAssertEqual(MacIRBuilder.droppingSignedProjection(left), left,
            "ADDS provenance cannot acquire this subtraction-only interpretation")
    }

    func testSSARequestedNativeFallbackPreservesComparisonReplayPolicy() throws {
        // Three blocks with a real entry backedge are outside the two-block
        // bounded-entry SSA class. No call, table or returned value is invented.
        let rows = try signedWordRows([
            0x08,0x00,0xb0,0x52, // MOV W8,#0x80000000.
            0x1f,0x01,0x00,0x71, // CMP W8,#0.
            0x6d,0x00,0x00,0x54, // B.LE 0x7014.
            0x29,0x00,0x80,0x52, // MOV W9,#1.
            0xfc,0xff,0xff,0x17, // B 0x7000.
            0xc0,0x03,0x5f,0xd6
        ])
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "native_comparison_replay_control", startAddress: 0x7000, instructions: rows)
        XCTAssertFalse(function.ssaEnabled, "this control must exercise the native fallback")
        XCTAssertTrue(function.phis.isEmpty)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertEqual(cfg.blocks.count, 3)
        XCTAssertEqual(cfg.blocks[cfg.entryIndex].predecessors, [1])
        XCTAssertNotNil(function.reconciliationEvidence, "force the actual deferred producer path")
        XCTAssertFalse(function.nonMarkerDifference,
            "the lexical twin must preserve the original request's comparison policy")
        XCTAssertTrue(function.reconciliationMarkers.isEmpty)
        let branch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
        guard case let .conditionalBranch(_, left, _, _) = branch.operation else {
            return XCTFail("the retained native comparison route is missing")
        }
        XCTAssertEqual(MacIRBuilder.droppingSignedProjection(left), left,
            "an SSA-requested fallback must not receive the default-native-only projection")
    }

    func testNativeSignedWordCSETGE() throws {
        try checkNativeSignedWordConsumer("cset", suffix: "ge", word: 0x9a9fb7e0)
    }

    func testNativeSignedWordCSETLT() throws {
        try checkNativeSignedWordConsumer("cset", suffix: "lt", word: 0x9a9fa7e0)
    }

    func testNativeSignedWordCSETGT() throws {
        try checkNativeSignedWordConsumer("cset", suffix: "gt", word: 0x9a9fd7e0)
    }

    func testNativeSignedWordCSETLE() throws {
        try checkNativeSignedWordConsumer("cset", suffix: "le", word: 0x9a9fc7e0)
    }

    func testNativeSignedWordCSETMGE() throws {
        try checkNativeSignedWordConsumer("csetm", suffix: "ge", word: 0xda9fb3e0)
    }

    func testNativeSignedWordCSETMLT() throws {
        try checkNativeSignedWordConsumer("csetm", suffix: "lt", word: 0xda9fa3e0)
    }

    func testNativeSignedWordCSETMGT() throws {
        try checkNativeSignedWordConsumer("csetm", suffix: "gt", word: 0xda9fd3e0)
    }

    func testNativeSignedWordCSETMLE() throws {
        try checkNativeSignedWordConsumer("csetm", suffix: "le", word: 0xda9fc3e0)
    }

    func testNativeSignedWordCSELGE() throws {
        try checkNativeSignedWordConsumer("csel", suffix: "ge", word: 0x9a8aa120)
    }

    func testNativeSignedWordCSELLT() throws {
        try checkNativeSignedWordConsumer("csel", suffix: "lt", word: 0x9a8ab120)
    }

    func testNativeSignedWordCSELGT() throws {
        try checkNativeSignedWordConsumer("csel", suffix: "gt", word: 0x9a8ac120)
    }

    func testNativeSignedWordCSELLE() throws {
        try checkNativeSignedWordConsumer("csel", suffix: "le", word: 0x9a8ad120)
    }

    func testNativeSignedWordCSINCGE() throws {
        try checkNativeSignedWordConsumer("csinc", suffix: "ge", word: 0x9a8aa520)
    }

    func testNativeSignedWordCSINCLT() throws {
        try checkNativeSignedWordConsumer("csinc", suffix: "lt", word: 0x9a8ab520)
    }

    func testNativeSignedWordCSINCGT() throws {
        try checkNativeSignedWordConsumer("csinc", suffix: "gt", word: 0x9a8ac520)
    }

    func testNativeSignedWordCSINCLE() throws {
        try checkNativeSignedWordConsumer("csinc", suffix: "le", word: 0x9a8ad520)
    }

    func testNativeSignedWordCSINVGE() throws {
        try checkNativeSignedWordConsumer("csinv", suffix: "ge", word: 0xda8aa120)
    }

    func testNativeSignedWordCSINVLT() throws {
        try checkNativeSignedWordConsumer("csinv", suffix: "lt", word: 0xda8ab120)
    }

    func testNativeSignedWordCSINVGT() throws {
        try checkNativeSignedWordConsumer("csinv", suffix: "gt", word: 0xda8ac120)
    }

    func testNativeSignedWordCSINVLE() throws {
        try checkNativeSignedWordConsumer("csinv", suffix: "le", word: 0xda8ad120)
    }

    func testNativeSignedWordCSNEGGE() throws {
        try checkNativeSignedWordConsumer("csneg", suffix: "ge", word: 0xda8aa520)
    }

    func testNativeSignedWordCSNEGLT() throws {
        try checkNativeSignedWordConsumer("csneg", suffix: "lt", word: 0xda8ab520)
    }

    func testNativeSignedWordCSNEGGT() throws {
        try checkNativeSignedWordConsumer("csneg", suffix: "gt", word: 0xda8ac520)
    }

    func testNativeSignedWordCSNEGLE() throws {
        try checkNativeSignedWordConsumer("csneg", suffix: "le", word: 0xda8ad520)
    }

    func testNativeSignedWordCINCGE() throws {
        try checkNativeSignedWordConsumer("cinc", suffix: "ge", word: 0x9a89b520)
    }

    func testNativeSignedWordCINCLT() throws {
        try checkNativeSignedWordConsumer("cinc", suffix: "lt", word: 0x9a89a520)
    }

    func testNativeSignedWordCINCGT() throws {
        try checkNativeSignedWordConsumer("cinc", suffix: "gt", word: 0x9a89d520)
    }

    func testNativeSignedWordCINCLE() throws {
        try checkNativeSignedWordConsumer("cinc", suffix: "le", word: 0x9a89c520)
    }

    func testNativeSignedWordCINVGE() throws {
        try checkNativeSignedWordConsumer("cinv", suffix: "ge", word: 0xda89b120)
    }

    func testNativeSignedWordCINVLT() throws {
        try checkNativeSignedWordConsumer("cinv", suffix: "lt", word: 0xda89a120)
    }

    func testNativeSignedWordCINVGT() throws {
        try checkNativeSignedWordConsumer("cinv", suffix: "gt", word: 0xda89d120)
    }

    func testNativeSignedWordCINVLE() throws {
        try checkNativeSignedWordConsumer("cinv", suffix: "le", word: 0xda89c120)
    }

    func testNativeSignedWordCNEGGE() throws {
        try checkNativeSignedWordConsumer("cneg", suffix: "ge", word: 0xda89b520)
    }

    func testNativeSignedWordCNEGLT() throws {
        try checkNativeSignedWordConsumer("cneg", suffix: "lt", word: 0xda89a520)
    }

    func testNativeSignedWordCNEGGT() throws {
        try checkNativeSignedWordConsumer("cneg", suffix: "gt", word: 0xda89d520)
    }

    func testNativeSignedWordCNEGLE() throws {
        try checkNativeSignedWordConsumer("cneg", suffix: "le", word: 0xda89c520)
    }

    /// The runner mode does not change these native-defect fixtures.
    /// Evaluation observes the actual consumer statement, not a forged predicate
    /// or a claim about the function's return authority.
    private func checkNativeSignedWordConsumer(_ mnemonic: String, suffix: String,
                                               word: UInt32) throws {
        let words: [UInt32] = [
            0xd28000a9, // MOV X9,#5: before CMP, never between producer/consumer.
            0xd280012a, // MOV X10,#9.
            0xb9400008, // LDR W8,[X0].
            0x7100011f, // CMP W8,#0.
            word, 0xd65f03c0
        ]
        let bytes = words.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
        let rows = try signedWordRows(bytes)
        XCTAssertEqual(rows[3].mnemonic, "cmp")
        XCTAssertEqual(rows[3].operands, "w8, #0")
        XCTAssertEqual(rows[4].mnemonic, mnemonic)
        let operands: String
        switch mnemonic {
        case "cset", "csetm": operands = "x0, \(suffix)"
        case "cinc", "cinv", "cneg": operands = "x0, x9, \(suffix)"
        default: operands = "x0, x9, x10, \(suffix)"
        }
        XCTAssertEqual(rows[4].operands, operands)
        let function = MacIRBuilder(ssaEnabled: false).buildFunction(
            name: "native_signed_word_\(mnemonic)_\(suffix)", startAddress: 0x7000,
            instructions: rows)
        XCTAssertFalse(function.ssaEnabled)
        let load = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
        let consumer = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7010 })
        guard case let .load(loaded, _) = load.operation else {
            return XCTFail("real byte-backed W load was not retained")
        }
        let left: MacIRValue
        switch consumer.operation {
        case let .compareToBool(_, _, value, _):
            XCTAssertEqual(mnemonic, "cset"); left = value
        case let .select(_, _, value, _, _, _):
            XCTAssertNotEqual(mnemonic, "cset"); left = value
        default: return XCTFail("the decoded conditional consumer was not lifted")
        }
        XCTAssertEqual(MacIRBuilder.droppingSignedProjection(left), loaded)
        guard case let .binaryExpression(marker, _, .binaryExpression(context, .immediate(32), partner)) = left else {
            return XCTFail("exact native CMP must own a W32 signed projection")
        }
        XCTAssertEqual(marker, MacIRBuilder.signedProjectionOperator)
        XCTAssertEqual(context, MacIRBuilder.projectionContextOperator)
        XCTAssertEqual(partner, .immediate(0))
        let names = PseudocodeNameContext(function: function, registerNameOverrides: [
            "w8": "source_word", "x9": "selected_a", "x10": "selected_b", "x0": "result"
        ])
        let printer = PseudocodePrinter(options: .default)
        XCTAssertEqual(printer.printedScalarType(of: loaded, names: names), "uint32_t")
        let statement = printer.render(instruction: consumer, names: names)
        let signature = "int64_t native_signed_word(uint32_t source_word, int64_t selected_a, int64_t selected_b) {"
        let terminal = "return result;"
        let observation: UInt64 = 0x7100
        let contract = OrdinaryC.Contract(signature: signature,
            inputs: [.init(name: "source_word", type: .u32, entrySlot: 8),
                     .init(name: "selected_a", type: .i64, entrySlot: 9),
                     .init(name: "selected_b", type: .i64, entrySlot: 10)],
            fields: [], calls: [:], exterior: [:], terminalRow: 99,
            terminalPayload: terminal, terminalName: "result", returnType: .i64,
            rowsByAddress: [consumer.source.address: 4, observation: 99], allowedLabels: [],
            memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        let program = try OrdinaryC.Program(lines: [
            .init(text: signature, source: nil, envelope: .signature),
            .init(text: statement + ";", source: consumer.source.address, envelope: .body),
            .init(text: terminal, source: observation, envelope: .body),
            .init(text: "}", source: nil, envelope: .closingBrace)
        ], contract: contract)
        let bits: [UInt64] = [0x80000000, 0xffffffff, 0, 0x7fffffff]
        let predicates: [String: [Bool]] = [
            "ge": [false, false, true, true], "lt": [true, true, false, false],
            "gt": [false, false, false, true], "le": [true, true, true, false]
        ]
        let expectedPredicates = try XCTUnwrap(predicates[suffix])
        for (index, input) in bits.enumerated() {
            let holds = expectedPredicates[index]
            let expected: Int64
            switch mnemonic {
            case "cset": expected = holds ? 1 : 0
            case "csetm": expected = holds ? -1 : 0
            case "csel": expected = holds ? 5 : 9
            case "csinc": expected = holds ? 5 : 10
            case "csinv": expected = holds ? 5 : -10
            case "csneg": expected = holds ? 5 : -9
            case "cinc": expected = holds ? 6 : 5
            case "cinv": expected = holds ? -6 : 5
            case "cneg": expected = holds ? -5 : 5
            default: return XCTFail("unknown test consumer")
            }
            let result = try OrdinaryC.Machine(program: program, scenario: .init(
                name: "native-\(mnemonic)-\(suffix)-\(input)",
                inputs: ["source_word": .init(input, .u32),
                         "selected_a": .init(5, .i64), "selected_b": .init(9, .i64)],
                memory: [:], responses: [])).run()
            XCTAssertTrue(result.returned)
            XCTAssertEqual(result.terminal?.bits, UInt64(bitPattern: expected),
                           "the actual emitted consumer must use signed W32 predicates")
        }
    }

    func testNativeSignedWordConsumersExcludeADDS() throws {
        try checkNativeSignedWordExclusion([0x2b09010b], mnemonics: ["adds"])
    }

    func testNativeSignedWordConsumersExcludeCMN() throws {
        try checkNativeSignedWordExclusion([0x3100011f], mnemonics: ["cmn"])
    }

    func testNativeSignedWordConsumersExcludeShiftedCMP() throws {
        try checkNativeSignedWordExclusion([0x7140051f], mnemonics: ["cmp"])
    }

    func testNativeSignedWordConsumersExcludeXRegisterCMP() throws {
        try checkNativeSignedWordExclusion([0xf100011f], mnemonics: ["cmp"])
    }

    func testNativeSignedWordConsumersExcludeInterveningFlagWriter() throws {
        // FRESH_TST_AUTHORITY_AFTER_CMP: 340 independently certifies this TST.
        try checkNativeSignedWordExclusion([0x7100011f, 0x6a09011f], mnemonics: ["cmp", "tst"],
                                          expectsFreshTST: true)
    }

    func testNativeSignedWordConsumersRequireAdjacentProducer() throws {
        try checkNativeSignedWordExclusion([0x7100011f, 0xaa0903eb], mnemonics: ["cmp", "mov"])
    }

    private func checkNativeSignedWordExclusion(_ producers: [UInt32], mnemonics: [String],
                                               expectsFreshTST: Bool = false) throws {
        let consumers: [(String, UInt32)] = [
            ("cset", 0x9a9fb7e0),
            ("cset", 0x9a9fa7e0),
            ("cset", 0x9a9fd7e0),
            ("cset", 0x9a9fc7e0),
            ("csetm", 0xda9fb3e0),
            ("csetm", 0xda9fa3e0),
            ("csetm", 0xda9fd3e0),
            ("csetm", 0xda9fc3e0),
            ("csel", 0x9a8aa120),
            ("csel", 0x9a8ab120),
            ("csel", 0x9a8ac120),
            ("csel", 0x9a8ad120),
            ("csinc", 0x9a8aa520),
            ("csinc", 0x9a8ab520),
            ("csinc", 0x9a8ac520),
            ("csinc", 0x9a8ad520),
            ("csinv", 0xda8aa120),
            ("csinv", 0xda8ab120),
            ("csinv", 0xda8ac120),
            ("csinv", 0xda8ad120),
            ("csneg", 0xda8aa520),
            ("csneg", 0xda8ab520),
            ("csneg", 0xda8ac520),
            ("csneg", 0xda8ad520),
            ("cinc", 0x9a89b520),
            ("cinc", 0x9a89a520),
            ("cinc", 0x9a89d520),
            ("cinc", 0x9a89c520),
            ("cinv", 0xda89b120),
            ("cinv", 0xda89a120),
            ("cinv", 0xda89d120),
            ("cinv", 0xda89c120),
            ("cneg", 0xda89b520),
            ("cneg", 0xda89a520),
            ("cneg", 0xda89d520),
            ("cneg", 0xda89c520)
        ]
        for (mnemonic, consumerWord) in consumers {
            let words: [UInt32] = [0xd28000a9, 0xd280012a, 0xb9400008]
                + producers + [consumerWord, 0xd65f03c0]
            let bytes = words.flatMap { word in
                (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
            }
            let rows = try signedWordRows(bytes)
            XCTAssertEqual(Array(rows[3..<(3 + producers.count)].map(\.mnemonic)), mnemonics)
            XCTAssertEqual(rows[3 + producers.count].mnemonic, mnemonic)
            let function = MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "native_signed_word_exclusion", startAddress: 0x7000, instructions: rows)
            let address = rows[3 + producers.count].address
            let consumer = try XCTUnwrap(function.instructions.first { $0.source.address == address })
            let operands: [MacIRValue]
            switch consumer.operation {
            case let .compareToBool(_, _, left, right): operands = [left, right]
            case let .select(_, _, left, right, _, _): operands = [left, right]
            case .unknown: operands = [] // Existing honest refusal, not new admission.
            default: return XCTFail("unexpected exclusion consumer shape")
            }
            func hasProjection(_ value: MacIRValue) -> Bool {
                switch value {
                case let .binaryExpression(op, left, right):
                    return op == MacIRBuilder.signedProjectionOperator
                        || hasProjection(left) || hasProjection(right)
                case let .unary(_, inner): return hasProjection(inner)
                default: return false
                }
            }
            if expectsFreshTST {
                let load = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
                let move = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7000 })
                let tst = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7010 })
                XCTAssertEqual(tst.source.mnemonic, "tst")
                XCTAssertEqual(tst.source.operands, "w8, w9")
                XCTAssertEqual(tst.source.address + 4, consumer.source.address)
                guard case let .load(loaded, _) = load.operation,
                      case let .assign(other, _) = move.operation,
                      operands.count == 2 else {
                    return XCTFail("fresh TST fixture must retain both real operand definitions")
                }
                let expectedBits = MacIRValue.binaryExpression(op: "&",
                    left: .unary(op: "(uint32_t)", value: loaded),
                    right: .unary(op: "(uint32_t)", value:
                        .unary(op: "(uint32_t)", value: other)))
                XCTAssertEqual(operands[0], MacIRBuilder.signedProjection(expectedBits,
                    width: 32, partner: .immediate(0)),
                    "fresh TST, never the overwritten CMP, owns this projection")
                XCTAssertNotEqual(MacIRBuilder.droppingSignedProjection(operands[0]), loaded)
                XCTAssertEqual(operands[1], .immediate(0))
                XCTAssertEqual(tst.operation, .intrinsic(destination: nil, name: "compare",
                    arguments: [operands[0], .immediate(0)]))
            } else {
                XCTAssertFalse(operands.contains(where: hasProjection),
                    "excluded provenance must not gain the native CMP-only projection")
            }
        }
    }

    private func signedWordRows(_ bytes: [UInt8]) throws -> [InstructionRow] {
        XCTAssertEqual(bytes.count % 4, 0)
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: 0x7000,
                                            maxInstructionCount: bytes.count / 4)
        XCTAssertEqual(decoded.count, bytes.count / 4)
        let rows = decoded.map { InstructionRow(decoded: $0) }
        XCTAssertFalse(rows.contains { $0.mnemonic == "unknown" || $0.mnemonic == ".word" })
        return rows
    }

    private func ownershipCandidate(_ fixture: RegionalSwitchFixture) throws -> OrdinaryC.Program {
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try OrdinaryC.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.baselineText, callRows: fixture.seed.callRows, blockAddresses: blocks)
        return try OrdinaryC.Program(lines: OrdinaryC.lines(fixture.document), contract: contract)
    }

    private func replacingDocument(_ fixture: RegionalSwitchFixture,
                                   with document: PseudocodeDocument) -> RegionalSwitchFixture {
        RegionalSwitchFixture(seed: fixture.seed, capture: fixture.capture,
            schema2InputAuthority: fixture.schema2InputAuthority, input: fixture.input,
            function: fixture.function, document: document)
    }

    private func checkProspectiveVoidRepair(_ seed: RegionalSwitchSeed) throws {
        let fixture = try RegionalSwitchFixture.make(seed)
        XCTAssertEqual(fixture.input.signatureOverrides[seed.start]?.returnType, "void")
        XCTAssertEqual(fixture.function.returnType, "void")
        XCTAssertNil(fixture.function.returnValue)
        XCTAssertEqual(fixture.function.instructions[seed.returnRow].operation, .returnValue(nil))
        checkCalls(fixture)
        let beforeRaw = fixture.capture.baseline_counts.raw_goto_lines
        let beforeTotal = fixture.capture.baseline_counts.total_goto_lines
        let afterRaw = lines(containing: "goto 0x", in: fixture.document.text)
        let afterTotal = lines(containing: "goto ", in: fixture.document.text)
        if afterRaw == beforeRaw && afterTotal == beforeTotal {
            XCTAssertEqual(fixture.document.text, fixture.baselineText,
                           "PRE_REPAIR_CONTEXT_IDENTITY_REQUIRED: do not strip context to obtain a RED")
        }
        XCTAssertLessThan(afterRaw, beforeRaw,
                          "REGIONAL_SWITCH_REPAIR_REQUIRED: prospective reduction, eligibility not yet proven")
        XCTAssertLessThan(afterTotal, beforeTotal,
                          "REGIONAL_SWITCH_REPAIR_REQUIRED: relabeling earns no credit")
        let root = try XCTUnwrap(fixture.document.regionTree,
                                "REGIONAL_SWITCH_REPAIR_REQUIRED: structured switch regions, not raw dispatch text")
        let sites = try Set(fixture.capture.switch_facts.map { try RegionalSwitchContext.address($0.source_address) })
        XCTAssertEqual(sites.count, 2, "the two original dispatch identities remain distinct")
        let structuredKinds: Set<PseudocodeRegionNode.Kind> = [.switchDispatch, .ifThen, .ifThenElse]
        let ownedSites = Set(descendants(root).compactMap { node -> UInt64? in
            guard structuredKinds.contains(node.kind), let site = node.conditionSourceAddress,
                  sites.contains(site) else { return nil }
            return site
        })
        XCTAssertEqual(ownedSites, sites,
                       "each captured dispatch needs source-attributed structured ownership; switch or grouped if/else is allowed")
        for site in sites {
            let ownedLines = fixture.document.lines(sourcedAt: site)
            XCTAssertFalse(ownedLines.isEmpty)
        }
        // Supersedes only the old blanket no-goto-at-BR premise. An ordinary
        // default arm may retain a real transfer; every ordinal/default route
        // and every residual span must instead have exact original ownership.
        // The historical assertion remains in the pre-supersession source.
        _ = try OriginalDispatchOwnership.verify(fixture)
        // A separate reviewed oracle must establish control/effect equivalence;
        // these structural and exact-call checks are necessary, not sufficient.
    }

    private func checkCalls(_ fixture: RegionalSwitchFixture) {
        let changed = fixture.callPayloads.filter(\.changedBeyondIndentation)
        XCTAssertTrue(changed.isEmpty, "C4_CALL_TEXT_CHANGED: " + changed.map {
            "row \($0.row) @\(RegionalSwitchContext.hex($0.address)): \($0.baseline) -> \($0.after)"
        }.joined(separator: "\n"))
        XCTAssertEqual(fixture.document.lines.filter { $0.text.hasSuffix("// call") }.count, fixture.capture.calls.count,
                       "no lost, duplicated, or newly introduced printed call")
        // Only leading spaces may differ. In particular never introduce a result
        // assignment or alter a callee, argument, trailing comment, or return use.
    }
    private func lines(containing token: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.contains(token) }.count
    }
    private func descendants(_ node: PseudocodeRegionNode) -> [PseudocodeRegionNode] {
        [node] + node.children.flatMap(descendants)
    }
    private func checkCapturedSwitch(_ fact: RegionalSwitchFixture.CapturedSwitch,
                                     input: PseudocodeRenderInput) throws {
        let pc = try RegionalSwitchContext.address(fact.source_address)
        XCTAssertEqual(input.instructions[fact.lifted_index].address, pc)
        XCTAssertEqual(fact.input_row_indices, [fact.lifted_index])
        XCTAssertEqual(fact.effect_ordinal, 0)
        XCTAssertEqual(fact.selector.kind, "register")
        XCTAssertEqual(fact.cases.count, 10)
        XCTAssertEqual(fact.cases.map(\.ordinal), Array(0..<10))
        XCTAssertEqual(fact.cases.compactMap { Int64($0.value_decimal) }, Array(0..<10).map(Int64.init))
        let targets = try fact.cases.map { try UInt64(bitPattern: $0.typed_target.value()) }
        XCTAssertEqual(input.jumpTables[pc], targets)
        XCTAssertEqual(try fact.raw_table_targets?.map(RegionalSwitchContext.address), targets)
        for (item, target) in zip(fact.cases, targets) {
            XCTAssertEqual(try item.target_address.map(RegionalSwitchContext.address), target)
            XCTAssertNotNil(item.target_block)
        }
        XCTAssertNotNil(fact.default_target)
        XCTAssertEqual(try fact.default_target.map { try UInt64(bitPattern: $0.value()) },
                       try fact.default_address.map(RegionalSwitchContext.address))
        XCTAssertNotNil(fact.default_block)
        XCTAssertEqual(fact.ordered_distinct_target_blocks.count, 7)
        XCTAssertEqual(fact.block?.successors, fact.ordered_distinct_target_blocks)
        XCTAssertEqual(fact.raw_table_matches_ordered_cases, true)
        XCTAssertTrue(fact.case_values_match_ordinals)
        XCTAssertEqual(fact.target_projection_matches_cfg_successors, true)
        XCTAssertTrue(fact.all_case_and_default_targets_resolve_to_blocks)
    }
}

/// Bounded replacement for the two old Regional dispatch-presentation assertions.
/// SOURCE_ONLY / NOT_RUN. This proves static AST/source ownership, not numerical
/// equivalence, dynamic case coverage, or historical raw-transfer removal.
/// No product state/control/value certificate supplies candidate identities.
enum OriginalDispatchOwnership {
    private typealias C = OrdinaryC
    private typealias L = OrdinaryCSourceEdgeLedger

    static func verify(_ fixture: RegionalSwitchFixture) throws -> OrdinaryCSourceEdgeLedger.Report {
        let diagnosticDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-diagnostics-\(UUID().uuidString)", isDirectory: true)
        func retainDiagnostic(_ text: String, name: String) {
            do {
                try FileManager.default.createDirectory(at: diagnosticDirectory, withIntermediateDirectories: true)
                let url = diagnosticDirectory.appendingPathComponent(name)
                try text.write(to: url, atomically: true, encoding: .utf8)
                print("Dispatch diagnostic: \(url.path)")
            } catch {
                // Diagnostic persistence must not replace the original validation error.
            }
        }
        let blocks = Set(fixture.capture.cfg_blocks.map { fixture.rows[$0.start_index].address })
        let contract = try C.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.baselineText, callRows: fixture.seed.callRows, blockAddresses: blocks)
        let candidate: C.Program
        do {
            candidate = try C.Program(lines: C.lines(fixture.document), contract: contract)
        } catch {
            // Keep the exact failed input with the receipt; diagnosing grammar
            // must not require rerendering an unchanged function.
            let text = "DISPATCH_PARSE_INPUT\n\(fixture.document.text)\nEND_DISPATCH_PARSE_INPUT\n"
            if let data = text.data(using: .utf8) { FileHandle.standardError.write(data) }
            retainDiagnostic(text, name: "dispatch-ledger-input-\(fixture.rows.count).txt")
            throw error
        }
        guard Set(candidate.lines.compactMap(\.source)).isSubset(of: Set(fixture.rows.map(\.address))) else {
            throw C.Failure.invalidContract("dispatch document invents a source row")
        }
        let source = try L.source(rows: fixture.rows, color: fixture.capture)
        let report: L.Report
        do {
            report = try L.analyze(candidate: candidate, source: source)
        } catch {
            let text = "DISPATCH_LEDGER_INPUT\n\(fixture.document.text)\nEND_DISPATCH_LEDGER_INPUT\n"
            if let data = text.data(using: .utf8) { FileHandle.standardError.write(data) }
            retainDiagnostic(text, name: "dispatch-ledger-input-\(fixture.rows.count).txt")
            throw error
        }
        do { try report.requireCompleteTopology() } catch {
            retainDiagnostic(fixture.document.text, name: "dispatch-topology-\(fixture.rows.count).txt")
            throw error
        }
        guard source.dispatches.count == 2,
              Set(report.accounts.map(\.origin)) == source.origins,
              Set(report.printed.filter { $0.kind == .goto }.map(\.span)) == Set(report.residualSlots.map(\.span)),
              report.residualSlots.count == candidate.tokens.filter({ $0.text == "goto" }).count else {
            throw C.Failure.invalidContract("incomplete original dispatch or actual residual inventory")
        }
        for slot in report.residualSlots {
            let routes = report.routes.filter { $0.residualSpans.contains(slot.span) }
            let sourceRow = try candidate.row(at: slot.span)
            guard !routes.isEmpty, !slot.origins.isEmpty,
                  slot.origins == Set(routes.flatMap(\.origins)),
                  slot.origins.contains(where: {
                      $0.role == .tableDefault
                          ? source.dispatches[$0.row]?.guardRow == sourceRow : $0.row == sourceRow
                  }),
                  candidate.code.indices.contains(slot.pc),
                  case let .jump(destination) = candidate.code[slot.pc].node,
                  destination == slot.target else {
                throw C.Failure.invalidContract("residual source/target/span or plural origin accounting differs")
            }
        }
        for fact in fixture.capture.switch_facts {
            let row = fact.lifted_index
            guard fact.selector.kind == "register", fact.selector.name == "w8" else {
                throw C.Failure.invalidContract("original dispatch selector is not its W8 definition")
            }
            let dispatch = try XCTUnwrap(source.dispatches[row])
            let guardRow = dispatch.guardRow
            guard fixture.rows.indices.contains(guardRow),
                  fixture.rows[guardRow].mnemonic == "b.hi",
                  source.branchTargets[guardRow] == dispatch.defaultRow else {
                throw C.Failure.invalidContract("dispatch default is not its original bounds guard's taken target")
            }
            let accounts = report.accounts.filter { $0.origin.row == row }
            let roles = Set((0..<10).map { L.Role.tableCase($0) }).union([.tableDefault])
            guard accounts.count == 11, Set(accounts.map { $0.origin.role }) == roles else {
                throw C.Failure.invalidContract("dispatch must retain ten distinct ordinals and its original default")
            }
            for account in accounts {
                let destinationRow: Int, originRow: Int
                switch account.origin.role {
                case let .tableCase(ordinal):
                    destinationRow = dispatch.targets[ordinal]; originRow = row
                case .tableDefault:
                    destinationRow = dispatch.defaultRow; originRow = guardRow
                    guard account.origin.machineRole == .taken else {
                        throw C.Failure.invalidContract("dispatch default lost its bounds guard taken role")
                    }
                default: throw C.Failure.invalidContract("unexpected dispatch role")
                }
                guard account.origin.edge.fromBlock == source.blockAtRow[originRow],
                      account.origin.edge.toBlock == source.blockAtRow[destinationRow],
                      !account.routeIndices.isEmpty,
                      account.routeIndices.allSatisfy({ report.routes[$0].origins.contains(account.origin) }) else {
                    throw C.Failure.invalidContract("original dispatch role/target lost its actual route")
                }
            }
            for pair in [(1, 6), (3, 7), (4, 8), (5, 9)] {
                let first = try XCTUnwrap(accounts.first { $0.origin.role == .tableCase(pair.0) })
                let second = try XCTUnwrap(accounts.first { $0.origin.role == .tableCase(pair.1) })
                guard first.origin.edge == second.origin.edge, first.routeIndices == second.routeIndices else {
                    throw C.Failure.invalidContract("equal-target case ordinals were collapsed or separated")
                }
            }
            try bindSelector(row: row, fixture: fixture, candidate: candidate)
        }
        return report
    }

    /// Each immutable dispatch selects the W8 result of its own SUB #6, eight
    /// source rows earlier. Bind that actual definition and all its predicate
    /// reads, not a physical-bank spelling or a final assignment at the row.
    /// This fixes the output producer site/type/operation and use dominance;
    /// equivalence of its incoming operand remains a separate numerical/source
    /// def-use obligation, not authority inferred from this source tag.
    private static func bindSelector(row: Int, fixture: RegionalSwitchFixture,
                                     candidate: C.Program) throws {
        let producer = row - 8
        guard fixture.rows.indices.contains(producer), fixture.rows[producer].mnemonic == "sub",
              fixture.rows[producer].operands == "w8, w8, #6",
              fixture.rows[producer].bytes == "08 19 00 51" else {
            throw C.Failure.invalidContract("dispatch has no original W32 SUB selector producer")
        }
        var definitions: [(pc: Int, name: String)] = []
        for (pc, instruction) in candidate.code.enumerated() {
            guard (try? candidate.row(at: instruction.span)) == producer,
                  case let .assign(left, right) = instruction.node,
                  left.count == 1, right.count == 1,
                  case let .name(name) = left[0].node,
                  candidate.symbols[name]?.type == .u32,
                  case let .cast(type, arithmetic) = right[0].node, type == .u32,
                  case let .binary("-", input, six) = arithmetic.node,
                  candidate.expressionTypes[input.span] == .u32,
                  literal(six) == 6 else { continue }
            definitions.append((pc, name))
        }
        guard definitions.count == 1, let definition = definitions.first else {
            throw C.Failure.invalidContract("missing or ambiguous actual W32 selector definition")
        }
        var writes: [Int] = [], uses: [Int] = []
        for (pc, instruction) in candidate.code.enumerated() {
            let expressions: [C.Expression]
            switch instruction.node {
            case let .assign(left, right): expressions = left + right
            case let .declaration(_, initial): expressions = initial.map { [$0] } ?? []
            case let .branch(expression, _, _), let .update(expression): expressions = [expression]
            case let .call(_, _, control, arguments): expressions = (control.map { [$0] } ?? []) + arguments
            case let .returned(value): expressions = value.map { [$0] } ?? []
            default: expressions = []
            }
            guard !expressions.contains(where: { mutates($0, name: definition.name) }) else {
                throw C.Failure.invalidContract("selector is changed by a nested increment/decrement")
            }
            switch instruction.node {
            case let .assign(left, _):
                if left.contains(where: { if case let .name(name) = $0.node { return name == definition.name }; return false }) {
                    writes.append(pc)
                }
            case let .declaration(name, initial):
                if name == definition.name && initial != nil { writes.append(pc) }
            case let .update(expression):
                if names(expression).contains(definition.name) { writes.append(pc) }
            case let .branch(expression, _, _):
                if (try? candidate.row(at: expression.span)) == row {
                    guard names(expression) == [definition.name] else {
                        throw C.Failure.invalidContract("dispatch predicate reads a different source definition")
                    }
                    uses.append(pc)
                }
            default: break
            }
        }
        guard writes == [definition.pc], !uses.isEmpty else {
            throw C.Failure.invalidContract("selector is overwritten or has no actual dispatch reads")
        }
        // Source tags cannot establish dominance. Removing the actual producer
        // must make every actual dispatch use unreachable in the compiled AST.
        func reachable(excluding excluded: Int?) throws -> Set<Int> {
            var reached: Set<Int> = [], work = [0]
            while let pc = work.popLast() {
                guard pc != excluded, candidate.code.indices.contains(pc), reached.insert(pc).inserted else { continue }
                switch candidate.code[pc].node {
                case let .branch(_, yes, no): work += [yes, no]
                case let .jump(target): work.append(target)
                case .returned, .unavailableReturn: break
                case .unresolved: throw C.Failure.invalidContract("unresolved selector dominance route")
                default: work.append(pc + 1)
                }
            }
            return reached
        }
        let reached = try reachable(excluding: nil), bypass = try reachable(excluding: definition.pc)
        guard reached.contains(definition.pc), uses.allSatisfy({ reached.contains($0) && !bypass.contains($0) }) else {
            throw C.Failure.invalidContract("actual dispatch can bypass its original selector definition")
        }
    }

    private static func literal(_ expression: C.Expression) -> UInt64? {
        switch expression.node {
        case let .literal(value): return value.bits
        case let .cast(type, child):
            guard type == .u32, let value = literal(child), value <= UInt64(UInt32.max) else { return nil }
            return value
        default: return nil
        }
    }
    private static func names(_ expression: C.Expression) -> Set<String> {
        switch expression.node {
        case let .name(name), let .update(name, _, _): return [name]
        case let .cast(_, child), let .unary(_, child): return names(child)
        case let .binary(_, left, right): return names(left).union(names(right))
        case let .select(condition, yes, no): return names(condition).union(names(yes)).union(names(no))
        case let .load(_, address), let .field(address, _): return names(address)
        case let .helper(_, args): return args.reduce(into: Set<String>()) { $0.formUnion(names($1)) }
        case .literal: return []
        }
    }
    private static func mutates(_ expression: C.Expression, name: String) -> Bool {
        switch expression.node {
        case let .update(target, _, _): return target == name
        case let .cast(_, child), let .unary(_, child): return mutates(child, name: name)
        case let .binary(_, left, right): return mutates(left, name: name) || mutates(right, name: name)
        case let .select(condition, yes, no):
            return mutates(condition, name: name) || mutates(yes, name: name) || mutates(no, name: name)
        case let .load(_, address), let .field(address, _): return mutates(address, name: name)
        case let .helper(_, args): return args.contains { mutates($0, name: name) }
        case .literal, .name: return false
        }
    }
}


extension DecodedRegionalSwitchTests {
    func test340BICS32REGBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_GE", producer: 0x6a29010c, consumer: 0x5400004a,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_LT", producer: 0x6a29010c, consumer: 0x5400004b,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_GT", producer: 0x6a29010c, consumer: 0x5400004c,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_LE", producer: 0x6a29010c, consumer: 0x5400004d,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_GE", producer: 0x6a29010c, consumer: 0x9a9fb7e0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_LT", producer: 0x6a29010c, consumer: 0x9a9fa7e0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_GT", producer: 0x6a29010c, consumer: 0x9a9fd7e0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_LE", producer: 0x6a29010c, consumer: 0x9a9fc7e0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_GE", producer: 0x6a29010c, consumer: 0xda9fb3e0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_LT", producer: 0x6a29010c, consumer: 0xda9fa3e0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_GT", producer: 0x6a29010c, consumer: 0xda9fd3e0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_LE", producer: 0x6a29010c, consumer: 0xda9fc3e0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_GE", producer: 0x6a29010c, consumer: 0x9a8ea1a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_LT", producer: 0x6a29010c, consumer: 0x9a8eb1a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_GT", producer: 0x6a29010c, consumer: 0x9a8ec1a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_LE", producer: 0x6a29010c, consumer: 0x9a8ed1a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_GE", producer: 0x6a29010c, consumer: 0x9a8ea5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_LT", producer: 0x6a29010c, consumer: 0x9a8eb5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_GT", producer: 0x6a29010c, consumer: 0x9a8ec5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_LE", producer: 0x6a29010c, consumer: 0x9a8ed5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_GE", producer: 0x6a29010c, consumer: 0xda8ea1a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_LT", producer: 0x6a29010c, consumer: 0xda8eb1a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_GT", producer: 0x6a29010c, consumer: 0xda8ec1a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_LE", producer: 0x6a29010c, consumer: 0xda8ed1a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_GE", producer: 0x6a29010c, consumer: 0xda8ea5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_LT", producer: 0x6a29010c, consumer: 0xda8eb5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_GT", producer: 0x6a29010c, consumer: 0xda8ec5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_LE", producer: 0x6a29010c, consumer: 0xda8ed5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_GE", producer: 0x6a29010c, consumer: 0x9a8db5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_LT", producer: 0x6a29010c, consumer: 0x9a8da5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_GT", producer: 0x6a29010c, consumer: 0x9a8dd5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_LE", producer: 0x6a29010c, consumer: 0x9a8dc5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_GE", producer: 0x6a29010c, consumer: 0xda8db1a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_LT", producer: 0x6a29010c, consumer: 0xda8da1a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_GT", producer: 0x6a29010c, consumer: 0xda8dd1a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_LE", producer: 0x6a29010c, consumer: 0xda8dc1a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_GE", producer: 0x6a29010c, consumer: 0xda8db5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_LT", producer: 0x6a29010c, consumer: 0xda8da5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_GT", producer: 0x6a29010c, consumer: 0xda8dd5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_LE", producer: 0x6a29010c, consumer: 0xda8dc5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32LSLBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_GE", producer: 0x6a29050c, consumer: 0x5400004a,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_LT", producer: 0x6a29050c, consumer: 0x5400004b,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_GT", producer: 0x6a29050c, consumer: 0x5400004c,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_LE", producer: 0x6a29050c, consumer: 0x5400004d,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_GE", producer: 0x6a29050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_LT", producer: 0x6a29050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_GT", producer: 0x6a29050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_LE", producer: 0x6a29050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_GE", producer: 0x6a29050c, consumer: 0xda9fb3e0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_LT", producer: 0x6a29050c, consumer: 0xda9fa3e0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_GT", producer: 0x6a29050c, consumer: 0xda9fd3e0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_LE", producer: 0x6a29050c, consumer: 0xda9fc3e0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_GE", producer: 0x6a29050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_LT", producer: 0x6a29050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_GT", producer: 0x6a29050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_LE", producer: 0x6a29050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_GE", producer: 0x6a29050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_LT", producer: 0x6a29050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_GT", producer: 0x6a29050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_LE", producer: 0x6a29050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_GE", producer: 0x6a29050c, consumer: 0xda8ea1a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_LT", producer: 0x6a29050c, consumer: 0xda8eb1a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_GT", producer: 0x6a29050c, consumer: 0xda8ec1a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_LE", producer: 0x6a29050c, consumer: 0xda8ed1a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_GE", producer: 0x6a29050c, consumer: 0xda8ea5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_LT", producer: 0x6a29050c, consumer: 0xda8eb5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_GT", producer: 0x6a29050c, consumer: 0xda8ec5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_LE", producer: 0x6a29050c, consumer: 0xda8ed5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_GE", producer: 0x6a29050c, consumer: 0x9a8db5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_LT", producer: 0x6a29050c, consumer: 0x9a8da5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_GT", producer: 0x6a29050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_LE", producer: 0x6a29050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_GE", producer: 0x6a29050c, consumer: 0xda8db1a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_LT", producer: 0x6a29050c, consumer: 0xda8da1a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_GT", producer: 0x6a29050c, consumer: 0xda8dd1a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_LE", producer: 0x6a29050c, consumer: 0xda8dc1a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_GE", producer: 0x6a29050c, consumer: 0xda8db5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_LT", producer: 0x6a29050c, consumer: 0xda8da5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_GT", producer: 0x6a29050c, consumer: 0xda8dd5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_LE", producer: 0x6a29050c, consumer: 0xda8dc5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_GE", producer: 0x6a69050c, consumer: 0x5400004a,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_LT", producer: 0x6a69050c, consumer: 0x5400004b,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_GT", producer: 0x6a69050c, consumer: 0x5400004c,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_LE", producer: 0x6a69050c, consumer: 0x5400004d,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_GE", producer: 0x6a69050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_LT", producer: 0x6a69050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_GT", producer: 0x6a69050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_LE", producer: 0x6a69050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_GE", producer: 0x6a69050c, consumer: 0xda9fb3e0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_LT", producer: 0x6a69050c, consumer: 0xda9fa3e0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_GT", producer: 0x6a69050c, consumer: 0xda9fd3e0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_LE", producer: 0x6a69050c, consumer: 0xda9fc3e0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_GE", producer: 0x6a69050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_LT", producer: 0x6a69050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_GT", producer: 0x6a69050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_LE", producer: 0x6a69050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_GE", producer: 0x6a69050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_LT", producer: 0x6a69050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_GT", producer: 0x6a69050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_LE", producer: 0x6a69050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_GE", producer: 0x6a69050c, consumer: 0xda8ea1a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_LT", producer: 0x6a69050c, consumer: 0xda8eb1a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_GT", producer: 0x6a69050c, consumer: 0xda8ec1a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_LE", producer: 0x6a69050c, consumer: 0xda8ed1a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_GE", producer: 0x6a69050c, consumer: 0xda8ea5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_LT", producer: 0x6a69050c, consumer: 0xda8eb5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_GT", producer: 0x6a69050c, consumer: 0xda8ec5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_LE", producer: 0x6a69050c, consumer: 0xda8ed5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_GE", producer: 0x6a69050c, consumer: 0x9a8db5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_LT", producer: 0x6a69050c, consumer: 0x9a8da5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_GT", producer: 0x6a69050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_LE", producer: 0x6a69050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_GE", producer: 0x6a69050c, consumer: 0xda8db1a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_LT", producer: 0x6a69050c, consumer: 0xda8da1a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_GT", producer: 0x6a69050c, consumer: 0xda8dd1a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_LE", producer: 0x6a69050c, consumer: 0xda8dc1a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_GE", producer: 0x6a69050c, consumer: 0xda8db5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_LT", producer: 0x6a69050c, consumer: 0xda8da5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_GT", producer: 0x6a69050c, consumer: 0xda8dd5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_LE", producer: 0x6a69050c, consumer: 0xda8dc5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_GE", producer: 0x6aa9050c, consumer: 0x5400004a,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_LT", producer: 0x6aa9050c, consumer: 0x5400004b,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_GT", producer: 0x6aa9050c, consumer: 0x5400004c,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_LE", producer: 0x6aa9050c, consumer: 0x5400004d,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_GE", producer: 0x6aa9050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_LT", producer: 0x6aa9050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_GT", producer: 0x6aa9050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_LE", producer: 0x6aa9050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_GE", producer: 0x6aa9050c, consumer: 0xda9fb3e0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_LT", producer: 0x6aa9050c, consumer: 0xda9fa3e0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_GT", producer: 0x6aa9050c, consumer: 0xda9fd3e0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_LE", producer: 0x6aa9050c, consumer: 0xda9fc3e0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_GE", producer: 0x6aa9050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_LT", producer: 0x6aa9050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_GT", producer: 0x6aa9050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_LE", producer: 0x6aa9050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_GE", producer: 0x6aa9050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_LT", producer: 0x6aa9050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_GT", producer: 0x6aa9050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_LE", producer: 0x6aa9050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_GE", producer: 0x6aa9050c, consumer: 0xda8ea1a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_LT", producer: 0x6aa9050c, consumer: 0xda8eb1a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_GT", producer: 0x6aa9050c, consumer: 0xda8ec1a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_LE", producer: 0x6aa9050c, consumer: 0xda8ed1a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_GE", producer: 0x6aa9050c, consumer: 0xda8ea5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_LT", producer: 0x6aa9050c, consumer: 0xda8eb5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_GT", producer: 0x6aa9050c, consumer: 0xda8ec5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_LE", producer: 0x6aa9050c, consumer: 0xda8ed5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_GE", producer: 0x6aa9050c, consumer: 0x9a8db5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_LT", producer: 0x6aa9050c, consumer: 0x9a8da5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_GT", producer: 0x6aa9050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_LE", producer: 0x6aa9050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_GE", producer: 0x6aa9050c, consumer: 0xda8db1a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_LT", producer: 0x6aa9050c, consumer: 0xda8da1a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_GT", producer: 0x6aa9050c, consumer: 0xda8dd1a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_LE", producer: 0x6aa9050c, consumer: 0xda8dc1a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_GE", producer: 0x6aa9050c, consumer: 0xda8db5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_LT", producer: 0x6aa9050c, consumer: 0xda8da5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_GT", producer: 0x6aa9050c, consumer: 0xda8dd5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_LE", producer: 0x6aa9050c, consumer: 0xda8dc5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_GE", producer: 0x6ae9050c, consumer: 0x5400004a,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_LT", producer: 0x6ae9050c, consumer: 0x5400004b,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_GT", producer: 0x6ae9050c, consumer: 0x5400004c,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_LE", producer: 0x6ae9050c, consumer: 0x5400004d,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_GE", producer: 0x6ae9050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_LT", producer: 0x6ae9050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_GT", producer: 0x6ae9050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_LE", producer: 0x6ae9050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_GE", producer: 0x6ae9050c, consumer: 0xda9fb3e0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_LT", producer: 0x6ae9050c, consumer: 0xda9fa3e0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_GT", producer: 0x6ae9050c, consumer: 0xda9fd3e0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_LE", producer: 0x6ae9050c, consumer: 0xda9fc3e0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_GE", producer: 0x6ae9050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_LT", producer: 0x6ae9050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_GT", producer: 0x6ae9050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_LE", producer: 0x6ae9050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_GE", producer: 0x6ae9050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_LT", producer: 0x6ae9050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_GT", producer: 0x6ae9050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_LE", producer: 0x6ae9050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_GE", producer: 0x6ae9050c, consumer: 0xda8ea1a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_LT", producer: 0x6ae9050c, consumer: 0xda8eb1a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_GT", producer: 0x6ae9050c, consumer: 0xda8ec1a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_LE", producer: 0x6ae9050c, consumer: 0xda8ed1a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_GE", producer: 0x6ae9050c, consumer: 0xda8ea5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_LT", producer: 0x6ae9050c, consumer: 0xda8eb5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_GT", producer: 0x6ae9050c, consumer: 0xda8ec5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_LE", producer: 0x6ae9050c, consumer: 0xda8ed5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_GE", producer: 0x6ae9050c, consumer: 0x9a8db5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_LT", producer: 0x6ae9050c, consumer: 0x9a8da5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_GT", producer: 0x6ae9050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_LE", producer: 0x6ae9050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_GE", producer: 0x6ae9050c, consumer: 0xda8db1a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_LT", producer: 0x6ae9050c, consumer: 0xda8da1a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_GT", producer: 0x6ae9050c, consumer: 0xda8dd1a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_LE", producer: 0x6ae9050c, consumer: 0xda8dc1a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_GE", producer: 0x6ae9050c, consumer: 0xda8db5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_LT", producer: 0x6ae9050c, consumer: 0xda8da5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_GT", producer: 0x6ae9050c, consumer: 0xda8dd5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_LE", producer: 0x6ae9050c, consumer: 0xda8dc5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64IMMBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_BCOND_GE", producer: 0xf241011f, consumer: 0x5400004a,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_BCOND_LT", producer: 0xf241011f, consumer: 0x5400004b,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_BCOND_GT", producer: 0xf241011f, consumer: 0x5400004c,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_BCOND_LE", producer: 0xf241011f, consumer: 0x5400004d,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSET_GE", producer: 0xf241011f, consumer: 0x9a9fb7e0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSET_LT", producer: 0xf241011f, consumer: 0x9a9fa7e0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSET_GT", producer: 0xf241011f, consumer: 0x9a9fd7e0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSET_LE", producer: 0xf241011f, consumer: 0x9a9fc7e0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETMGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSETM_GE", producer: 0xf241011f, consumer: 0xda9fb3e0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETMLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSETM_LT", producer: 0xf241011f, consumer: 0xda9fa3e0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETMGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSETM_GT", producer: 0xf241011f, consumer: 0xda9fd3e0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSETMLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSETM_LE", producer: 0xf241011f, consumer: 0xda9fc3e0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSELGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSEL_GE", producer: 0xf241011f, consumer: 0x9a8ea1a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSELLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSEL_LT", producer: 0xf241011f, consumer: 0x9a8eb1a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSELGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSEL_GT", producer: 0xf241011f, consumer: 0x9a8ec1a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSELLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSEL_LE", producer: 0xf241011f, consumer: 0x9a8ed1a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINC_GE", producer: 0xf241011f, consumer: 0x9a8ea5a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINC_LT", producer: 0xf241011f, consumer: 0x9a8eb5a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINC_GT", producer: 0xf241011f, consumer: 0x9a8ec5a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINC_LE", producer: 0xf241011f, consumer: 0x9a8ed5a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINV_GE", producer: 0xf241011f, consumer: 0xda8ea1a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINV_LT", producer: 0xf241011f, consumer: 0xda8eb1a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINV_GT", producer: 0xf241011f, consumer: 0xda8ec1a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSINV_LE", producer: 0xf241011f, consumer: 0xda8ed1a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSNEG_GE", producer: 0xf241011f, consumer: 0xda8ea5a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSNEG_LT", producer: 0xf241011f, consumer: 0xda8eb5a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSNEG_GT", producer: 0xf241011f, consumer: 0xda8ec5a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CSNEG_LE", producer: 0xf241011f, consumer: 0xda8ed5a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINC_GE", producer: 0xf241011f, consumer: 0x9a8db5a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINC_LT", producer: 0xf241011f, consumer: 0x9a8da5a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINC_GT", producer: 0xf241011f, consumer: 0x9a8dd5a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINC_LE", producer: 0xf241011f, consumer: 0x9a8dc5a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINV_GE", producer: 0xf241011f, consumer: 0xda8db1a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINV_LT", producer: 0xf241011f, consumer: 0xda8da1a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINV_GT", producer: 0xf241011f, consumer: 0xda8dd1a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CINV_LE", producer: 0xf241011f, consumer: 0xda8dc1a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CNEG_GE", producer: 0xf241011f, consumer: 0xda8db5a0,
            family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CNEG_LT", producer: 0xf241011f, consumer: 0xda8da5a0,
            family: "tst", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CNEG_GT", producer: 0xf241011f, consumer: 0xda8dd5a0,
            family: "tst", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64IMMCNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_IMM_CNEG_LE", producer: 0xf241011f, consumer: 0xda8dc5a0,
            family: "tst", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_BCOND_GE", producer: 0xea09011f, consumer: 0x5400004a,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_BCOND_LT", producer: 0xea09011f, consumer: 0x5400004b,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_BCOND_GT", producer: 0xea09011f, consumer: 0x5400004c,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_BCOND_LE", producer: 0xea09011f, consumer: 0x5400004d,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSET_GE", producer: 0xea09011f, consumer: 0x9a9fb7e0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSET_LT", producer: 0xea09011f, consumer: 0x9a9fa7e0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSET_GT", producer: 0xea09011f, consumer: 0x9a9fd7e0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSET_LE", producer: 0xea09011f, consumer: 0x9a9fc7e0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETMGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSETM_GE", producer: 0xea09011f, consumer: 0xda9fb3e0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETMLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSETM_LT", producer: 0xea09011f, consumer: 0xda9fa3e0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETMGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSETM_GT", producer: 0xea09011f, consumer: 0xda9fd3e0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSETMLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSETM_LE", producer: 0xea09011f, consumer: 0xda9fc3e0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSELGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSEL_GE", producer: 0xea09011f, consumer: 0x9a8ea1a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSELLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSEL_LT", producer: 0xea09011f, consumer: 0x9a8eb1a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSELGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSEL_GT", producer: 0xea09011f, consumer: 0x9a8ec1a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSELLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSEL_LE", producer: 0xea09011f, consumer: 0x9a8ed1a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINC_GE", producer: 0xea09011f, consumer: 0x9a8ea5a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINC_LT", producer: 0xea09011f, consumer: 0x9a8eb5a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINC_GT", producer: 0xea09011f, consumer: 0x9a8ec5a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINC_LE", producer: 0xea09011f, consumer: 0x9a8ed5a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINV_GE", producer: 0xea09011f, consumer: 0xda8ea1a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINV_LT", producer: 0xea09011f, consumer: 0xda8eb1a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINV_GT", producer: 0xea09011f, consumer: 0xda8ec1a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSINV_LE", producer: 0xea09011f, consumer: 0xda8ed1a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSNEG_GE", producer: 0xea09011f, consumer: 0xda8ea5a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSNEG_LT", producer: 0xea09011f, consumer: 0xda8eb5a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSNEG_GT", producer: 0xea09011f, consumer: 0xda8ec5a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CSNEG_LE", producer: 0xea09011f, consumer: 0xda8ed5a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINC_GE", producer: 0xea09011f, consumer: 0x9a8db5a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINC_LT", producer: 0xea09011f, consumer: 0x9a8da5a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINC_GT", producer: 0xea09011f, consumer: 0x9a8dd5a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINC_LE", producer: 0xea09011f, consumer: 0x9a8dc5a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINV_GE", producer: 0xea09011f, consumer: 0xda8db1a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINV_LT", producer: 0xea09011f, consumer: 0xda8da1a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINV_GT", producer: 0xea09011f, consumer: 0xda8dd1a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CINV_LE", producer: 0xea09011f, consumer: 0xda8dc1a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CNEG_GE", producer: 0xea09011f, consumer: 0xda8db5a0,
            family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CNEG_LT", producer: 0xea09011f, consumer: 0xda8da5a0,
            family: "tst", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CNEG_GT", producer: 0xea09011f, consumer: 0xda8dd5a0,
            family: "tst", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64REGCNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_REG_CNEG_LE", producer: 0xea09011f, consumer: 0xda8dc5a0,
            family: "tst", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64LSLBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_BCOND_GE", producer: 0xea09051f, consumer: 0x5400004a,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_BCOND_LT", producer: 0xea09051f, consumer: 0x5400004b,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_BCOND_GT", producer: 0xea09051f, consumer: 0x5400004c,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_BCOND_LE", producer: 0xea09051f, consumer: 0x5400004d,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSET_GE", producer: 0xea09051f, consumer: 0x9a9fb7e0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSET_LT", producer: 0xea09051f, consumer: 0x9a9fa7e0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSET_GT", producer: 0xea09051f, consumer: 0x9a9fd7e0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSET_LE", producer: 0xea09051f, consumer: 0x9a9fc7e0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETMGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSETM_GE", producer: 0xea09051f, consumer: 0xda9fb3e0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETMLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSETM_LT", producer: 0xea09051f, consumer: 0xda9fa3e0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETMGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSETM_GT", producer: 0xea09051f, consumer: 0xda9fd3e0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSETMLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSETM_LE", producer: 0xea09051f, consumer: 0xda9fc3e0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSELGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSEL_GE", producer: 0xea09051f, consumer: 0x9a8ea1a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSELLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSEL_LT", producer: 0xea09051f, consumer: 0x9a8eb1a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSELGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSEL_GT", producer: 0xea09051f, consumer: 0x9a8ec1a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSELLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSEL_LE", producer: 0xea09051f, consumer: 0x9a8ed1a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINC_GE", producer: 0xea09051f, consumer: 0x9a8ea5a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINC_LT", producer: 0xea09051f, consumer: 0x9a8eb5a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINC_GT", producer: 0xea09051f, consumer: 0x9a8ec5a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINC_LE", producer: 0xea09051f, consumer: 0x9a8ed5a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINV_GE", producer: 0xea09051f, consumer: 0xda8ea1a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINV_LT", producer: 0xea09051f, consumer: 0xda8eb1a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINV_GT", producer: 0xea09051f, consumer: 0xda8ec1a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSINV_LE", producer: 0xea09051f, consumer: 0xda8ed1a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSNEG_GE", producer: 0xea09051f, consumer: 0xda8ea5a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSNEG_LT", producer: 0xea09051f, consumer: 0xda8eb5a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSNEG_GT", producer: 0xea09051f, consumer: 0xda8ec5a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CSNEG_LE", producer: 0xea09051f, consumer: 0xda8ed5a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINC_GE", producer: 0xea09051f, consumer: 0x9a8db5a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINC_LT", producer: 0xea09051f, consumer: 0x9a8da5a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINC_GT", producer: 0xea09051f, consumer: 0x9a8dd5a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINC_LE", producer: 0xea09051f, consumer: 0x9a8dc5a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINV_GE", producer: 0xea09051f, consumer: 0xda8db1a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINV_LT", producer: 0xea09051f, consumer: 0xda8da1a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINV_GT", producer: 0xea09051f, consumer: 0xda8dd1a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CINV_LE", producer: 0xea09051f, consumer: 0xda8dc1a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CNEG_GE", producer: 0xea09051f, consumer: 0xda8db5a0,
            family: "tst", form: "LSL", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CNEG_LT", producer: 0xea09051f, consumer: 0xda8da5a0,
            family: "tst", form: "LSL", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CNEG_GT", producer: 0xea09051f, consumer: 0xda8dd5a0,
            family: "tst", form: "LSL", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSLCNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSL_CNEG_LE", producer: 0xea09051f, consumer: 0xda8dc5a0,
            family: "tst", form: "LSL", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_BCOND_GE", producer: 0xea49051f, consumer: 0x5400004a,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_BCOND_LT", producer: 0xea49051f, consumer: 0x5400004b,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_BCOND_GT", producer: 0xea49051f, consumer: 0x5400004c,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_BCOND_LE", producer: 0xea49051f, consumer: 0x5400004d,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSET_GE", producer: 0xea49051f, consumer: 0x9a9fb7e0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSET_LT", producer: 0xea49051f, consumer: 0x9a9fa7e0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSET_GT", producer: 0xea49051f, consumer: 0x9a9fd7e0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSET_LE", producer: 0xea49051f, consumer: 0x9a9fc7e0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSETM_GE", producer: 0xea49051f, consumer: 0xda9fb3e0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSETM_LT", producer: 0xea49051f, consumer: 0xda9fa3e0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSETM_GT", producer: 0xea49051f, consumer: 0xda9fd3e0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSETM_LE", producer: 0xea49051f, consumer: 0xda9fc3e0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSELGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSEL_GE", producer: 0xea49051f, consumer: 0x9a8ea1a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSELLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSEL_LT", producer: 0xea49051f, consumer: 0x9a8eb1a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSELGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSEL_GT", producer: 0xea49051f, consumer: 0x9a8ec1a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSELLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSEL_LE", producer: 0xea49051f, consumer: 0x9a8ed1a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINC_GE", producer: 0xea49051f, consumer: 0x9a8ea5a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINC_LT", producer: 0xea49051f, consumer: 0x9a8eb5a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINC_GT", producer: 0xea49051f, consumer: 0x9a8ec5a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINC_LE", producer: 0xea49051f, consumer: 0x9a8ed5a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINV_GE", producer: 0xea49051f, consumer: 0xda8ea1a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINV_LT", producer: 0xea49051f, consumer: 0xda8eb1a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINV_GT", producer: 0xea49051f, consumer: 0xda8ec1a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSINV_LE", producer: 0xea49051f, consumer: 0xda8ed1a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSNEG_GE", producer: 0xea49051f, consumer: 0xda8ea5a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSNEG_LT", producer: 0xea49051f, consumer: 0xda8eb5a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSNEG_GT", producer: 0xea49051f, consumer: 0xda8ec5a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CSNEG_LE", producer: 0xea49051f, consumer: 0xda8ed5a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINC_GE", producer: 0xea49051f, consumer: 0x9a8db5a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINC_LT", producer: 0xea49051f, consumer: 0x9a8da5a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINC_GT", producer: 0xea49051f, consumer: 0x9a8dd5a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINC_LE", producer: 0xea49051f, consumer: 0x9a8dc5a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINV_GE", producer: 0xea49051f, consumer: 0xda8db1a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINV_LT", producer: 0xea49051f, consumer: 0xda8da1a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINV_GT", producer: 0xea49051f, consumer: 0xda8dd1a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CINV_LE", producer: 0xea49051f, consumer: 0xda8dc1a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CNEG_GE", producer: 0xea49051f, consumer: 0xda8db5a0,
            family: "tst", form: "LSR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CNEG_LT", producer: 0xea49051f, consumer: 0xda8da5a0,
            family: "tst", form: "LSR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CNEG_GT", producer: 0xea49051f, consumer: 0xda8dd5a0,
            family: "tst", form: "LSR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64LSRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_LSR_CNEG_LE", producer: 0xea49051f, consumer: 0xda8dc5a0,
            family: "tst", form: "LSR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64ASRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_BCOND_GE", producer: 0xea89051f, consumer: 0x5400004a,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_BCOND_LT", producer: 0xea89051f, consumer: 0x5400004b,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_BCOND_GT", producer: 0xea89051f, consumer: 0x5400004c,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_BCOND_LE", producer: 0xea89051f, consumer: 0x5400004d,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSET_GE", producer: 0xea89051f, consumer: 0x9a9fb7e0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSET_LT", producer: 0xea89051f, consumer: 0x9a9fa7e0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSET_GT", producer: 0xea89051f, consumer: 0x9a9fd7e0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSET_LE", producer: 0xea89051f, consumer: 0x9a9fc7e0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSETM_GE", producer: 0xea89051f, consumer: 0xda9fb3e0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSETM_LT", producer: 0xea89051f, consumer: 0xda9fa3e0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSETM_GT", producer: 0xea89051f, consumer: 0xda9fd3e0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSETM_LE", producer: 0xea89051f, consumer: 0xda9fc3e0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSELGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSEL_GE", producer: 0xea89051f, consumer: 0x9a8ea1a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSELLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSEL_LT", producer: 0xea89051f, consumer: 0x9a8eb1a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSELGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSEL_GT", producer: 0xea89051f, consumer: 0x9a8ec1a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSELLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSEL_LE", producer: 0xea89051f, consumer: 0x9a8ed1a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINC_GE", producer: 0xea89051f, consumer: 0x9a8ea5a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINC_LT", producer: 0xea89051f, consumer: 0x9a8eb5a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINC_GT", producer: 0xea89051f, consumer: 0x9a8ec5a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINC_LE", producer: 0xea89051f, consumer: 0x9a8ed5a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINV_GE", producer: 0xea89051f, consumer: 0xda8ea1a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINV_LT", producer: 0xea89051f, consumer: 0xda8eb1a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINV_GT", producer: 0xea89051f, consumer: 0xda8ec1a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSINV_LE", producer: 0xea89051f, consumer: 0xda8ed1a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSNEG_GE", producer: 0xea89051f, consumer: 0xda8ea5a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSNEG_LT", producer: 0xea89051f, consumer: 0xda8eb5a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSNEG_GT", producer: 0xea89051f, consumer: 0xda8ec5a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CSNEG_LE", producer: 0xea89051f, consumer: 0xda8ed5a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINC_GE", producer: 0xea89051f, consumer: 0x9a8db5a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINC_LT", producer: 0xea89051f, consumer: 0x9a8da5a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINC_GT", producer: 0xea89051f, consumer: 0x9a8dd5a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINC_LE", producer: 0xea89051f, consumer: 0x9a8dc5a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINV_GE", producer: 0xea89051f, consumer: 0xda8db1a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINV_LT", producer: 0xea89051f, consumer: 0xda8da1a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINV_GT", producer: 0xea89051f, consumer: 0xda8dd1a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CINV_LE", producer: 0xea89051f, consumer: 0xda8dc1a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CNEG_GE", producer: 0xea89051f, consumer: 0xda8db5a0,
            family: "tst", form: "ASR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CNEG_LT", producer: 0xea89051f, consumer: 0xda8da5a0,
            family: "tst", form: "ASR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CNEG_GT", producer: 0xea89051f, consumer: 0xda8dd5a0,
            family: "tst", form: "ASR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64ASRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ASR_CNEG_LE", producer: 0xea89051f, consumer: 0xda8dc5a0,
            family: "tst", form: "ASR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST64RORBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_BCOND_GE", producer: 0xeac9051f, consumer: 0x5400004a,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_BCOND_LT", producer: 0xeac9051f, consumer: 0x5400004b,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_BCOND_GT", producer: 0xeac9051f, consumer: 0x5400004c,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_BCOND_LE", producer: 0xeac9051f, consumer: 0x5400004d,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSET_GE", producer: 0xeac9051f, consumer: 0x9a9fb7e0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSET_LT", producer: 0xeac9051f, consumer: 0x9a9fa7e0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSET_GT", producer: 0xeac9051f, consumer: 0x9a9fd7e0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSET_LE", producer: 0xeac9051f, consumer: 0x9a9fc7e0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETMGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSETM_GE", producer: 0xeac9051f, consumer: 0xda9fb3e0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETMLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSETM_LT", producer: 0xeac9051f, consumer: 0xda9fa3e0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETMGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSETM_GT", producer: 0xeac9051f, consumer: 0xda9fd3e0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSETMLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSETM_LE", producer: 0xeac9051f, consumer: 0xda9fc3e0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSELGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSEL_GE", producer: 0xeac9051f, consumer: 0x9a8ea1a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSELLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSEL_LT", producer: 0xeac9051f, consumer: 0x9a8eb1a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSELGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSEL_GT", producer: 0xeac9051f, consumer: 0x9a8ec1a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSELLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSEL_LE", producer: 0xeac9051f, consumer: 0x9a8ed1a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINC_GE", producer: 0xeac9051f, consumer: 0x9a8ea5a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINC_LT", producer: 0xeac9051f, consumer: 0x9a8eb5a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINC_GT", producer: 0xeac9051f, consumer: 0x9a8ec5a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINC_LE", producer: 0xeac9051f, consumer: 0x9a8ed5a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINV_GE", producer: 0xeac9051f, consumer: 0xda8ea1a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINV_LT", producer: 0xeac9051f, consumer: 0xda8eb1a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINV_GT", producer: 0xeac9051f, consumer: 0xda8ec1a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSINV_LE", producer: 0xeac9051f, consumer: 0xda8ed1a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSNEG_GE", producer: 0xeac9051f, consumer: 0xda8ea5a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSNEG_LT", producer: 0xeac9051f, consumer: 0xda8eb5a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSNEG_GT", producer: 0xeac9051f, consumer: 0xda8ec5a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CSNEG_LE", producer: 0xeac9051f, consumer: 0xda8ed5a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINCGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINC_GE", producer: 0xeac9051f, consumer: 0x9a8db5a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINCLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINC_LT", producer: 0xeac9051f, consumer: 0x9a8da5a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINCGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINC_GT", producer: 0xeac9051f, consumer: 0x9a8dd5a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINCLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINC_LE", producer: 0xeac9051f, consumer: 0x9a8dc5a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINVGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINV_GE", producer: 0xeac9051f, consumer: 0xda8db1a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINVLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINV_LT", producer: 0xeac9051f, consumer: 0xda8da1a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINVGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINV_GT", producer: 0xeac9051f, consumer: 0xda8dd1a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCINVLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CINV_LE", producer: 0xeac9051f, consumer: 0xda8dc1a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCNEGGE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CNEG_GE", producer: 0xeac9051f, consumer: 0xda8db5a0,
            family: "tst", form: "ROR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCNEGLT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CNEG_LT", producer: 0xeac9051f, consumer: 0xda8da5a0,
            family: "tst", form: "ROR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCNEGGT() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CNEG_GT", producer: 0xeac9051f, consumer: 0xda8dd5a0,
            family: "tst", form: "ROR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST64RORCNEGLE() throws {
        try LogicalRemainder340Fixture.check("TST_64_ROR_CNEG_LE", producer: 0xeac9051f, consumer: 0xda8dc5a0,
            family: "tst", form: "ROR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64IMMBCONDGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_BCOND_GE", producer: 0xf240010c, consumer: 0x5400004a,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMBCONDLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_BCOND_LT", producer: 0xf240010c, consumer: 0x5400004b,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMBCONDGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_BCOND_GT", producer: 0xf240010c, consumer: 0x5400004c,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMBCONDLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_BCOND_LE", producer: 0xf240010c, consumer: 0x5400004d,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSET_GE", producer: 0xf240010c, consumer: 0x9a9fb7e0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSET_LT", producer: 0xf240010c, consumer: 0x9a9fa7e0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSET_GT", producer: 0xf240010c, consumer: 0x9a9fd7e0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSET_LE", producer: 0xf240010c, consumer: 0x9a9fc7e0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETMGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSETM_GE", producer: 0xf240010c, consumer: 0xda9fb3e0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETMLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSETM_LT", producer: 0xf240010c, consumer: 0xda9fa3e0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETMGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSETM_GT", producer: 0xf240010c, consumer: 0xda9fd3e0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSETMLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSETM_LE", producer: 0xf240010c, consumer: 0xda9fc3e0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSELGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSEL_GE", producer: 0xf240010c, consumer: 0x9a8ea1a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSELLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSEL_LT", producer: 0xf240010c, consumer: 0x9a8eb1a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSELGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSEL_GT", producer: 0xf240010c, consumer: 0x9a8ec1a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSELLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSEL_LE", producer: 0xf240010c, consumer: 0x9a8ed1a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINC_GE", producer: 0xf240010c, consumer: 0x9a8ea5a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINC_LT", producer: 0xf240010c, consumer: 0x9a8eb5a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINC_GT", producer: 0xf240010c, consumer: 0x9a8ec5a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINC_LE", producer: 0xf240010c, consumer: 0x9a8ed5a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINV_GE", producer: 0xf240010c, consumer: 0xda8ea1a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINV_LT", producer: 0xf240010c, consumer: 0xda8eb1a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINV_GT", producer: 0xf240010c, consumer: 0xda8ec1a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSINV_LE", producer: 0xf240010c, consumer: 0xda8ed1a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSNEG_GE", producer: 0xf240010c, consumer: 0xda8ea5a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSNEG_LT", producer: 0xf240010c, consumer: 0xda8eb5a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSNEG_GT", producer: 0xf240010c, consumer: 0xda8ec5a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CSNEG_LE", producer: 0xf240010c, consumer: 0xda8ed5a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINC_GE", producer: 0xf240010c, consumer: 0x9a8db5a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINC_LT", producer: 0xf240010c, consumer: 0x9a8da5a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINC_GT", producer: 0xf240010c, consumer: 0x9a8dd5a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINC_LE", producer: 0xf240010c, consumer: 0x9a8dc5a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINV_GE", producer: 0xf240010c, consumer: 0xda8db1a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINV_LT", producer: 0xf240010c, consumer: 0xda8da1a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINV_GT", producer: 0xf240010c, consumer: 0xda8dd1a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CINV_LE", producer: 0xf240010c, consumer: 0xda8dc1a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CNEG_GE", producer: 0xf240010c, consumer: 0xda8db5a0,
            family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CNEG_LT", producer: 0xf240010c, consumer: 0xda8da5a0,
            family: "ands", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CNEG_GT", producer: 0xf240010c, consumer: 0xda8dd5a0,
            family: "ands", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64IMMCNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_IMM_CNEG_LE", producer: 0xf240010c, consumer: 0xda8dc5a0,
            family: "ands", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, retOnly: false)
    }
    func test340ANDS64REGBCONDGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_BCOND_GE", producer: 0xea09010c, consumer: 0x5400004a,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGBCONDLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_BCOND_LT", producer: 0xea09010c, consumer: 0x5400004b,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGBCONDGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_BCOND_GT", producer: 0xea09010c, consumer: 0x5400004c,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGBCONDLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_BCOND_LE", producer: 0xea09010c, consumer: 0x5400004d,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSET_GE", producer: 0xea09010c, consumer: 0x9a9fb7e0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSET_LT", producer: 0xea09010c, consumer: 0x9a9fa7e0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSET_GT", producer: 0xea09010c, consumer: 0x9a9fd7e0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSET_LE", producer: 0xea09010c, consumer: 0x9a9fc7e0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETMGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSETM_GE", producer: 0xea09010c, consumer: 0xda9fb3e0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETMLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSETM_LT", producer: 0xea09010c, consumer: 0xda9fa3e0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETMGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSETM_GT", producer: 0xea09010c, consumer: 0xda9fd3e0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSETMLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSETM_LE", producer: 0xea09010c, consumer: 0xda9fc3e0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSELGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSEL_GE", producer: 0xea09010c, consumer: 0x9a8ea1a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSELLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSEL_LT", producer: 0xea09010c, consumer: 0x9a8eb1a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSELGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSEL_GT", producer: 0xea09010c, consumer: 0x9a8ec1a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSELLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSEL_LE", producer: 0xea09010c, consumer: 0x9a8ed1a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINC_GE", producer: 0xea09010c, consumer: 0x9a8ea5a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINC_LT", producer: 0xea09010c, consumer: 0x9a8eb5a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINC_GT", producer: 0xea09010c, consumer: 0x9a8ec5a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINC_LE", producer: 0xea09010c, consumer: 0x9a8ed5a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINV_GE", producer: 0xea09010c, consumer: 0xda8ea1a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINV_LT", producer: 0xea09010c, consumer: 0xda8eb1a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINV_GT", producer: 0xea09010c, consumer: 0xda8ec1a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSINV_LE", producer: 0xea09010c, consumer: 0xda8ed1a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSNEG_GE", producer: 0xea09010c, consumer: 0xda8ea5a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSNEG_LT", producer: 0xea09010c, consumer: 0xda8eb5a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSNEG_GT", producer: 0xea09010c, consumer: 0xda8ec5a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CSNEG_LE", producer: 0xea09010c, consumer: 0xda8ed5a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINC_GE", producer: 0xea09010c, consumer: 0x9a8db5a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINC_LT", producer: 0xea09010c, consumer: 0x9a8da5a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINC_GT", producer: 0xea09010c, consumer: 0x9a8dd5a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINC_LE", producer: 0xea09010c, consumer: 0x9a8dc5a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINV_GE", producer: 0xea09010c, consumer: 0xda8db1a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINV_LT", producer: 0xea09010c, consumer: 0xda8da1a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINV_GT", producer: 0xea09010c, consumer: 0xda8dd1a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CINV_LE", producer: 0xea09010c, consumer: 0xda8dc1a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CNEG_GE", producer: 0xea09010c, consumer: 0xda8db5a0,
            family: "ands", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CNEG_LT", producer: 0xea09010c, consumer: 0xda8da5a0,
            family: "ands", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CNEG_GT", producer: 0xea09010c, consumer: 0xda8dd5a0,
            family: "ands", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64REGCNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_REG_CNEG_LE", producer: 0xea09010c, consumer: 0xda8dc5a0,
            family: "ands", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340ANDS64LSLBCONDGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_BCOND_GE", producer: 0xea09050c, consumer: 0x5400004a,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLBCONDLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_BCOND_LT", producer: 0xea09050c, consumer: 0x5400004b,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLBCONDGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_BCOND_GT", producer: 0xea09050c, consumer: 0x5400004c,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLBCONDLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_BCOND_LE", producer: 0xea09050c, consumer: 0x5400004d,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSET_GE", producer: 0xea09050c, consumer: 0x9a9fb7e0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSET_LT", producer: 0xea09050c, consumer: 0x9a9fa7e0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSET_GT", producer: 0xea09050c, consumer: 0x9a9fd7e0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSET_LE", producer: 0xea09050c, consumer: 0x9a9fc7e0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETMGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSETM_GE", producer: 0xea09050c, consumer: 0xda9fb3e0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETMLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSETM_LT", producer: 0xea09050c, consumer: 0xda9fa3e0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETMGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSETM_GT", producer: 0xea09050c, consumer: 0xda9fd3e0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSETMLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSETM_LE", producer: 0xea09050c, consumer: 0xda9fc3e0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSELGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSEL_GE", producer: 0xea09050c, consumer: 0x9a8ea1a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSELLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSEL_LT", producer: 0xea09050c, consumer: 0x9a8eb1a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSELGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSEL_GT", producer: 0xea09050c, consumer: 0x9a8ec1a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSELLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSEL_LE", producer: 0xea09050c, consumer: 0x9a8ed1a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINC_GE", producer: 0xea09050c, consumer: 0x9a8ea5a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINC_LT", producer: 0xea09050c, consumer: 0x9a8eb5a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINC_GT", producer: 0xea09050c, consumer: 0x9a8ec5a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINC_LE", producer: 0xea09050c, consumer: 0x9a8ed5a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINV_GE", producer: 0xea09050c, consumer: 0xda8ea1a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINV_LT", producer: 0xea09050c, consumer: 0xda8eb1a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINV_GT", producer: 0xea09050c, consumer: 0xda8ec1a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSINV_LE", producer: 0xea09050c, consumer: 0xda8ed1a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSNEG_GE", producer: 0xea09050c, consumer: 0xda8ea5a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSNEG_LT", producer: 0xea09050c, consumer: 0xda8eb5a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSNEG_GT", producer: 0xea09050c, consumer: 0xda8ec5a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CSNEG_LE", producer: 0xea09050c, consumer: 0xda8ed5a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINC_GE", producer: 0xea09050c, consumer: 0x9a8db5a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINC_LT", producer: 0xea09050c, consumer: 0x9a8da5a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINC_GT", producer: 0xea09050c, consumer: 0x9a8dd5a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINC_LE", producer: 0xea09050c, consumer: 0x9a8dc5a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINV_GE", producer: 0xea09050c, consumer: 0xda8db1a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINV_LT", producer: 0xea09050c, consumer: 0xda8da1a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINV_GT", producer: 0xea09050c, consumer: 0xda8dd1a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CINV_LE", producer: 0xea09050c, consumer: 0xda8dc1a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CNEG_GE", producer: 0xea09050c, consumer: 0xda8db5a0,
            family: "ands", form: "LSL", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CNEG_LT", producer: 0xea09050c, consumer: 0xda8da5a0,
            family: "ands", form: "LSL", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CNEG_GT", producer: 0xea09050c, consumer: 0xda8dd5a0,
            family: "ands", form: "LSL", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSLCNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSL_CNEG_LE", producer: 0xea09050c, consumer: 0xda8dc5a0,
            family: "ands", form: "LSL", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_BCOND_GE", producer: 0xea49050c, consumer: 0x5400004a,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_BCOND_LT", producer: 0xea49050c, consumer: 0x5400004b,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_BCOND_GT", producer: 0xea49050c, consumer: 0x5400004c,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_BCOND_LE", producer: 0xea49050c, consumer: 0x5400004d,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSET_GE", producer: 0xea49050c, consumer: 0x9a9fb7e0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSET_LT", producer: 0xea49050c, consumer: 0x9a9fa7e0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSET_GT", producer: 0xea49050c, consumer: 0x9a9fd7e0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSET_LE", producer: 0xea49050c, consumer: 0x9a9fc7e0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSETM_GE", producer: 0xea49050c, consumer: 0xda9fb3e0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSETM_LT", producer: 0xea49050c, consumer: 0xda9fa3e0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSETM_GT", producer: 0xea49050c, consumer: 0xda9fd3e0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSETM_LE", producer: 0xea49050c, consumer: 0xda9fc3e0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSELGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSEL_GE", producer: 0xea49050c, consumer: 0x9a8ea1a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSELLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSEL_LT", producer: 0xea49050c, consumer: 0x9a8eb1a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSELGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSEL_GT", producer: 0xea49050c, consumer: 0x9a8ec1a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSELLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSEL_LE", producer: 0xea49050c, consumer: 0x9a8ed1a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINC_GE", producer: 0xea49050c, consumer: 0x9a8ea5a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINC_LT", producer: 0xea49050c, consumer: 0x9a8eb5a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINC_GT", producer: 0xea49050c, consumer: 0x9a8ec5a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINC_LE", producer: 0xea49050c, consumer: 0x9a8ed5a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINV_GE", producer: 0xea49050c, consumer: 0xda8ea1a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINV_LT", producer: 0xea49050c, consumer: 0xda8eb1a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINV_GT", producer: 0xea49050c, consumer: 0xda8ec1a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSINV_LE", producer: 0xea49050c, consumer: 0xda8ed1a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSNEG_GE", producer: 0xea49050c, consumer: 0xda8ea5a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSNEG_LT", producer: 0xea49050c, consumer: 0xda8eb5a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSNEG_GT", producer: 0xea49050c, consumer: 0xda8ec5a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CSNEG_LE", producer: 0xea49050c, consumer: 0xda8ed5a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINC_GE", producer: 0xea49050c, consumer: 0x9a8db5a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINC_LT", producer: 0xea49050c, consumer: 0x9a8da5a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINC_GT", producer: 0xea49050c, consumer: 0x9a8dd5a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINC_LE", producer: 0xea49050c, consumer: 0x9a8dc5a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINV_GE", producer: 0xea49050c, consumer: 0xda8db1a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINV_LT", producer: 0xea49050c, consumer: 0xda8da1a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINV_GT", producer: 0xea49050c, consumer: 0xda8dd1a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CINV_LE", producer: 0xea49050c, consumer: 0xda8dc1a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CNEG_GE", producer: 0xea49050c, consumer: 0xda8db5a0,
            family: "ands", form: "LSR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CNEG_LT", producer: 0xea49050c, consumer: 0xda8da5a0,
            family: "ands", form: "LSR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CNEG_GT", producer: 0xea49050c, consumer: 0xda8dd5a0,
            family: "ands", form: "LSR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64LSRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_LSR_CNEG_LE", producer: 0xea49050c, consumer: 0xda8dc5a0,
            family: "ands", form: "LSR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_BCOND_GE", producer: 0xea89050c, consumer: 0x5400004a,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_BCOND_LT", producer: 0xea89050c, consumer: 0x5400004b,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_BCOND_GT", producer: 0xea89050c, consumer: 0x5400004c,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_BCOND_LE", producer: 0xea89050c, consumer: 0x5400004d,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSET_GE", producer: 0xea89050c, consumer: 0x9a9fb7e0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSET_LT", producer: 0xea89050c, consumer: 0x9a9fa7e0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSET_GT", producer: 0xea89050c, consumer: 0x9a9fd7e0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSET_LE", producer: 0xea89050c, consumer: 0x9a9fc7e0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSETM_GE", producer: 0xea89050c, consumer: 0xda9fb3e0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSETM_LT", producer: 0xea89050c, consumer: 0xda9fa3e0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSETM_GT", producer: 0xea89050c, consumer: 0xda9fd3e0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSETM_LE", producer: 0xea89050c, consumer: 0xda9fc3e0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSELGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSEL_GE", producer: 0xea89050c, consumer: 0x9a8ea1a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSELLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSEL_LT", producer: 0xea89050c, consumer: 0x9a8eb1a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSELGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSEL_GT", producer: 0xea89050c, consumer: 0x9a8ec1a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSELLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSEL_LE", producer: 0xea89050c, consumer: 0x9a8ed1a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINC_GE", producer: 0xea89050c, consumer: 0x9a8ea5a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINC_LT", producer: 0xea89050c, consumer: 0x9a8eb5a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINC_GT", producer: 0xea89050c, consumer: 0x9a8ec5a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINC_LE", producer: 0xea89050c, consumer: 0x9a8ed5a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINV_GE", producer: 0xea89050c, consumer: 0xda8ea1a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINV_LT", producer: 0xea89050c, consumer: 0xda8eb1a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINV_GT", producer: 0xea89050c, consumer: 0xda8ec1a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSINV_LE", producer: 0xea89050c, consumer: 0xda8ed1a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSNEG_GE", producer: 0xea89050c, consumer: 0xda8ea5a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSNEG_LT", producer: 0xea89050c, consumer: 0xda8eb5a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSNEG_GT", producer: 0xea89050c, consumer: 0xda8ec5a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CSNEG_LE", producer: 0xea89050c, consumer: 0xda8ed5a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINC_GE", producer: 0xea89050c, consumer: 0x9a8db5a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINC_LT", producer: 0xea89050c, consumer: 0x9a8da5a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINC_GT", producer: 0xea89050c, consumer: 0x9a8dd5a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINC_LE", producer: 0xea89050c, consumer: 0x9a8dc5a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINV_GE", producer: 0xea89050c, consumer: 0xda8db1a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINV_LT", producer: 0xea89050c, consumer: 0xda8da1a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINV_GT", producer: 0xea89050c, consumer: 0xda8dd1a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CINV_LE", producer: 0xea89050c, consumer: 0xda8dc1a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CNEG_GE", producer: 0xea89050c, consumer: 0xda8db5a0,
            family: "ands", form: "ASR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CNEG_LT", producer: 0xea89050c, consumer: 0xda8da5a0,
            family: "ands", form: "ASR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CNEG_GT", producer: 0xea89050c, consumer: 0xda8dd5a0,
            family: "ands", form: "ASR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64ASRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ASR_CNEG_LE", producer: 0xea89050c, consumer: 0xda8dc5a0,
            family: "ands", form: "ASR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORBCONDGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_BCOND_GE", producer: 0xeac9050c, consumer: 0x5400004a,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORBCONDLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_BCOND_LT", producer: 0xeac9050c, consumer: 0x5400004b,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORBCONDGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_BCOND_GT", producer: 0xeac9050c, consumer: 0x5400004c,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORBCONDLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_BCOND_LE", producer: 0xeac9050c, consumer: 0x5400004d,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSET_GE", producer: 0xeac9050c, consumer: 0x9a9fb7e0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSET_LT", producer: 0xeac9050c, consumer: 0x9a9fa7e0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSET_GT", producer: 0xeac9050c, consumer: 0x9a9fd7e0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSET_LE", producer: 0xeac9050c, consumer: 0x9a9fc7e0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETMGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSETM_GE", producer: 0xeac9050c, consumer: 0xda9fb3e0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETMLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSETM_LT", producer: 0xeac9050c, consumer: 0xda9fa3e0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETMGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSETM_GT", producer: 0xeac9050c, consumer: 0xda9fd3e0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSETMLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSETM_LE", producer: 0xeac9050c, consumer: 0xda9fc3e0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSELGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSEL_GE", producer: 0xeac9050c, consumer: 0x9a8ea1a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSELLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSEL_LT", producer: 0xeac9050c, consumer: 0x9a8eb1a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSELGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSEL_GT", producer: 0xeac9050c, consumer: 0x9a8ec1a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSELLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSEL_LE", producer: 0xeac9050c, consumer: 0x9a8ed1a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINC_GE", producer: 0xeac9050c, consumer: 0x9a8ea5a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINC_LT", producer: 0xeac9050c, consumer: 0x9a8eb5a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINC_GT", producer: 0xeac9050c, consumer: 0x9a8ec5a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINC_LE", producer: 0xeac9050c, consumer: 0x9a8ed5a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINV_GE", producer: 0xeac9050c, consumer: 0xda8ea1a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINV_LT", producer: 0xeac9050c, consumer: 0xda8eb1a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINV_GT", producer: 0xeac9050c, consumer: 0xda8ec1a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSINV_LE", producer: 0xeac9050c, consumer: 0xda8ed1a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSNEG_GE", producer: 0xeac9050c, consumer: 0xda8ea5a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSNEG_LT", producer: 0xeac9050c, consumer: 0xda8eb5a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSNEG_GT", producer: 0xeac9050c, consumer: 0xda8ec5a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CSNEG_LE", producer: 0xeac9050c, consumer: 0xda8ed5a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINCGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINC_GE", producer: 0xeac9050c, consumer: 0x9a8db5a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINCLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINC_LT", producer: 0xeac9050c, consumer: 0x9a8da5a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINCGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINC_GT", producer: 0xeac9050c, consumer: 0x9a8dd5a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINCLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINC_LE", producer: 0xeac9050c, consumer: 0x9a8dc5a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINVGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINV_GE", producer: 0xeac9050c, consumer: 0xda8db1a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINVLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINV_LT", producer: 0xeac9050c, consumer: 0xda8da1a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINVGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINV_GT", producer: 0xeac9050c, consumer: 0xda8dd1a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCINVLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CINV_LE", producer: 0xeac9050c, consumer: 0xda8dc1a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCNEGGE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CNEG_GE", producer: 0xeac9050c, consumer: 0xda8db5a0,
            family: "ands", form: "ROR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCNEGLT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CNEG_LT", producer: 0xeac9050c, consumer: 0xda8da5a0,
            family: "ands", form: "ROR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCNEGGT() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CNEG_GT", producer: 0xeac9050c, consumer: 0xda8dd5a0,
            family: "ands", form: "ROR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340ANDS64RORCNEGLE() throws {
        try LogicalRemainder340Fixture.check("ANDS_64_ROR_CNEG_LE", producer: 0xeac9050c, consumer: 0xda8dc5a0,
            family: "ands", form: "ROR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64REGBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_GE", producer: 0xea29010c, consumer: 0x5400004a,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_LT", producer: 0xea29010c, consumer: 0x5400004b,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_GT", producer: 0xea29010c, consumer: 0x5400004c,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_LE", producer: 0xea29010c, consumer: 0x5400004d,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_GE", producer: 0xea29010c, consumer: 0x9a9fb7e0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_LT", producer: 0xea29010c, consumer: 0x9a9fa7e0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_GT", producer: 0xea29010c, consumer: 0x9a9fd7e0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_LE", producer: 0xea29010c, consumer: 0x9a9fc7e0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_GE", producer: 0xea29010c, consumer: 0xda9fb3e0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_LT", producer: 0xea29010c, consumer: 0xda9fa3e0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_GT", producer: 0xea29010c, consumer: 0xda9fd3e0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_LE", producer: 0xea29010c, consumer: 0xda9fc3e0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_GE", producer: 0xea29010c, consumer: 0x9a8ea1a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_LT", producer: 0xea29010c, consumer: 0x9a8eb1a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_GT", producer: 0xea29010c, consumer: 0x9a8ec1a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_LE", producer: 0xea29010c, consumer: 0x9a8ed1a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_GE", producer: 0xea29010c, consumer: 0x9a8ea5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_LT", producer: 0xea29010c, consumer: 0x9a8eb5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_GT", producer: 0xea29010c, consumer: 0x9a8ec5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_LE", producer: 0xea29010c, consumer: 0x9a8ed5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_GE", producer: 0xea29010c, consumer: 0xda8ea1a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_LT", producer: 0xea29010c, consumer: 0xda8eb1a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_GT", producer: 0xea29010c, consumer: 0xda8ec1a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_LE", producer: 0xea29010c, consumer: 0xda8ed1a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_GE", producer: 0xea29010c, consumer: 0xda8ea5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_LT", producer: 0xea29010c, consumer: 0xda8eb5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_GT", producer: 0xea29010c, consumer: 0xda8ec5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_LE", producer: 0xea29010c, consumer: 0xda8ed5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_GE", producer: 0xea29010c, consumer: 0x9a8db5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_LT", producer: 0xea29010c, consumer: 0x9a8da5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_GT", producer: 0xea29010c, consumer: 0x9a8dd5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_LE", producer: 0xea29010c, consumer: 0x9a8dc5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_GE", producer: 0xea29010c, consumer: 0xda8db1a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_LT", producer: 0xea29010c, consumer: 0xda8da1a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_GT", producer: 0xea29010c, consumer: 0xda8dd1a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_LE", producer: 0xea29010c, consumer: 0xda8dc1a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_GE", producer: 0xea29010c, consumer: 0xda8db5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_LT", producer: 0xea29010c, consumer: 0xda8da5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_GT", producer: 0xea29010c, consumer: 0xda8dd5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_LE", producer: 0xea29010c, consumer: 0xda8dc5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64LSLBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_GE", producer: 0xea29050c, consumer: 0x5400004a,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_LT", producer: 0xea29050c, consumer: 0x5400004b,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_GT", producer: 0xea29050c, consumer: 0x5400004c,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_LE", producer: 0xea29050c, consumer: 0x5400004d,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_GE", producer: 0xea29050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_LT", producer: 0xea29050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_GT", producer: 0xea29050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_LE", producer: 0xea29050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_GE", producer: 0xea29050c, consumer: 0xda9fb3e0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_LT", producer: 0xea29050c, consumer: 0xda9fa3e0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_GT", producer: 0xea29050c, consumer: 0xda9fd3e0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_LE", producer: 0xea29050c, consumer: 0xda9fc3e0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_GE", producer: 0xea29050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_LT", producer: 0xea29050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_GT", producer: 0xea29050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_LE", producer: 0xea29050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_GE", producer: 0xea29050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_LT", producer: 0xea29050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_GT", producer: 0xea29050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_LE", producer: 0xea29050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_GE", producer: 0xea29050c, consumer: 0xda8ea1a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_LT", producer: 0xea29050c, consumer: 0xda8eb1a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_GT", producer: 0xea29050c, consumer: 0xda8ec1a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_LE", producer: 0xea29050c, consumer: 0xda8ed1a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_GE", producer: 0xea29050c, consumer: 0xda8ea5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_LT", producer: 0xea29050c, consumer: 0xda8eb5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_GT", producer: 0xea29050c, consumer: 0xda8ec5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_LE", producer: 0xea29050c, consumer: 0xda8ed5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_GE", producer: 0xea29050c, consumer: 0x9a8db5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_LT", producer: 0xea29050c, consumer: 0x9a8da5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_GT", producer: 0xea29050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_LE", producer: 0xea29050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_GE", producer: 0xea29050c, consumer: 0xda8db1a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_LT", producer: 0xea29050c, consumer: 0xda8da1a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_GT", producer: 0xea29050c, consumer: 0xda8dd1a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_LE", producer: 0xea29050c, consumer: 0xda8dc1a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_GE", producer: 0xea29050c, consumer: 0xda8db5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_LT", producer: 0xea29050c, consumer: 0xda8da5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_GT", producer: 0xea29050c, consumer: 0xda8dd5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_LE", producer: 0xea29050c, consumer: 0xda8dc5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_GE", producer: 0xea69050c, consumer: 0x5400004a,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_LT", producer: 0xea69050c, consumer: 0x5400004b,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_GT", producer: 0xea69050c, consumer: 0x5400004c,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_LE", producer: 0xea69050c, consumer: 0x5400004d,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_GE", producer: 0xea69050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_LT", producer: 0xea69050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_GT", producer: 0xea69050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_LE", producer: 0xea69050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_GE", producer: 0xea69050c, consumer: 0xda9fb3e0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_LT", producer: 0xea69050c, consumer: 0xda9fa3e0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_GT", producer: 0xea69050c, consumer: 0xda9fd3e0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_LE", producer: 0xea69050c, consumer: 0xda9fc3e0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_GE", producer: 0xea69050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_LT", producer: 0xea69050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_GT", producer: 0xea69050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_LE", producer: 0xea69050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_GE", producer: 0xea69050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_LT", producer: 0xea69050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_GT", producer: 0xea69050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_LE", producer: 0xea69050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_GE", producer: 0xea69050c, consumer: 0xda8ea1a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_LT", producer: 0xea69050c, consumer: 0xda8eb1a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_GT", producer: 0xea69050c, consumer: 0xda8ec1a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_LE", producer: 0xea69050c, consumer: 0xda8ed1a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_GE", producer: 0xea69050c, consumer: 0xda8ea5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_LT", producer: 0xea69050c, consumer: 0xda8eb5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_GT", producer: 0xea69050c, consumer: 0xda8ec5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_LE", producer: 0xea69050c, consumer: 0xda8ed5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_GE", producer: 0xea69050c, consumer: 0x9a8db5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_LT", producer: 0xea69050c, consumer: 0x9a8da5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_GT", producer: 0xea69050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_LE", producer: 0xea69050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_GE", producer: 0xea69050c, consumer: 0xda8db1a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_LT", producer: 0xea69050c, consumer: 0xda8da1a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_GT", producer: 0xea69050c, consumer: 0xda8dd1a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_LE", producer: 0xea69050c, consumer: 0xda8dc1a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_GE", producer: 0xea69050c, consumer: 0xda8db5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_LT", producer: 0xea69050c, consumer: 0xda8da5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_GT", producer: 0xea69050c, consumer: 0xda8dd5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_LE", producer: 0xea69050c, consumer: 0xda8dc5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_GE", producer: 0xeaa9050c, consumer: 0x5400004a,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_LT", producer: 0xeaa9050c, consumer: 0x5400004b,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_GT", producer: 0xeaa9050c, consumer: 0x5400004c,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_LE", producer: 0xeaa9050c, consumer: 0x5400004d,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_GE", producer: 0xeaa9050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_LT", producer: 0xeaa9050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_GT", producer: 0xeaa9050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_LE", producer: 0xeaa9050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_GE", producer: 0xeaa9050c, consumer: 0xda9fb3e0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_LT", producer: 0xeaa9050c, consumer: 0xda9fa3e0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_GT", producer: 0xeaa9050c, consumer: 0xda9fd3e0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_LE", producer: 0xeaa9050c, consumer: 0xda9fc3e0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_GE", producer: 0xeaa9050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_LT", producer: 0xeaa9050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_GT", producer: 0xeaa9050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_LE", producer: 0xeaa9050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_GE", producer: 0xeaa9050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_LT", producer: 0xeaa9050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_GT", producer: 0xeaa9050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_LE", producer: 0xeaa9050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_GE", producer: 0xeaa9050c, consumer: 0xda8ea1a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_LT", producer: 0xeaa9050c, consumer: 0xda8eb1a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_GT", producer: 0xeaa9050c, consumer: 0xda8ec1a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_LE", producer: 0xeaa9050c, consumer: 0xda8ed1a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_GE", producer: 0xeaa9050c, consumer: 0xda8ea5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_LT", producer: 0xeaa9050c, consumer: 0xda8eb5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_GT", producer: 0xeaa9050c, consumer: 0xda8ec5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_LE", producer: 0xeaa9050c, consumer: 0xda8ed5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_GE", producer: 0xeaa9050c, consumer: 0x9a8db5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_LT", producer: 0xeaa9050c, consumer: 0x9a8da5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_GT", producer: 0xeaa9050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_LE", producer: 0xeaa9050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_GE", producer: 0xeaa9050c, consumer: 0xda8db1a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_LT", producer: 0xeaa9050c, consumer: 0xda8da1a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_GT", producer: 0xeaa9050c, consumer: 0xda8dd1a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_LE", producer: 0xeaa9050c, consumer: 0xda8dc1a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_GE", producer: 0xeaa9050c, consumer: 0xda8db5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_LT", producer: 0xeaa9050c, consumer: 0xda8da5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_GT", producer: 0xeaa9050c, consumer: 0xda8dd5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_LE", producer: 0xeaa9050c, consumer: 0xda8dc5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_GE", producer: 0xeae9050c, consumer: 0x5400004a,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_LT", producer: 0xeae9050c, consumer: 0x5400004b,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_GT", producer: 0xeae9050c, consumer: 0x5400004c,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_LE", producer: 0xeae9050c, consumer: 0x5400004d,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_GE", producer: 0xeae9050c, consumer: 0x9a9fb7e0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_LT", producer: 0xeae9050c, consumer: 0x9a9fa7e0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_GT", producer: 0xeae9050c, consumer: 0x9a9fd7e0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_LE", producer: 0xeae9050c, consumer: 0x9a9fc7e0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_GE", producer: 0xeae9050c, consumer: 0xda9fb3e0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_LT", producer: 0xeae9050c, consumer: 0xda9fa3e0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_GT", producer: 0xeae9050c, consumer: 0xda9fd3e0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_LE", producer: 0xeae9050c, consumer: 0xda9fc3e0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_GE", producer: 0xeae9050c, consumer: 0x9a8ea1a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_LT", producer: 0xeae9050c, consumer: 0x9a8eb1a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_GT", producer: 0xeae9050c, consumer: 0x9a8ec1a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_LE", producer: 0xeae9050c, consumer: 0x9a8ed1a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_GE", producer: 0xeae9050c, consumer: 0x9a8ea5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_LT", producer: 0xeae9050c, consumer: 0x9a8eb5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_GT", producer: 0xeae9050c, consumer: 0x9a8ec5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_LE", producer: 0xeae9050c, consumer: 0x9a8ed5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_GE", producer: 0xeae9050c, consumer: 0xda8ea1a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_LT", producer: 0xeae9050c, consumer: 0xda8eb1a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_GT", producer: 0xeae9050c, consumer: 0xda8ec1a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_LE", producer: 0xeae9050c, consumer: 0xda8ed1a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_GE", producer: 0xeae9050c, consumer: 0xda8ea5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_LT", producer: 0xeae9050c, consumer: 0xda8eb5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_GT", producer: 0xeae9050c, consumer: 0xda8ec5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_LE", producer: 0xeae9050c, consumer: 0xda8ed5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_GE", producer: 0xeae9050c, consumer: 0x9a8db5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_LT", producer: 0xeae9050c, consumer: 0x9a8da5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_GT", producer: 0xeae9050c, consumer: 0x9a8dd5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_LE", producer: 0xeae9050c, consumer: 0x9a8dc5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_GE", producer: 0xeae9050c, consumer: 0xda8db1a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_LT", producer: 0xeae9050c, consumer: 0xda8da1a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_GT", producer: 0xeae9050c, consumer: 0xda8dd1a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_LE", producer: 0xeae9050c, consumer: 0xda8dc1a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGGE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_GE", producer: 0xeae9050c, consumer: 0xda8db5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGLT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_LT", producer: 0xeae9050c, consumer: 0xda8da5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGGT() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_GT", producer: 0xeae9050c, consumer: 0xda8dd5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGLE() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_LE", producer: 0xeae9050c, consumer: 0xda8dc5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340TST32IMMBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_BCOND_GE", producer: 0x7201011f, consumer: 0x5400004a,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32IMMBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_BCOND_LT", producer: 0x7201011f, consumer: 0x5400004b,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32IMMBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_BCOND_GT", producer: 0x7201011f, consumer: 0x5400004c,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32IMMBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_BCOND_LE", producer: 0x7201011f, consumer: 0x5400004d,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32REGBCONDGE() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_BCOND_GE", producer: 0x6a09011f, consumer: 0x5400004a,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32REGBCONDLT() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_BCOND_LT", producer: 0x6a09011f, consumer: 0x5400004b,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32REGBCONDGT() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_BCOND_GT", producer: 0x6a09011f, consumer: 0x5400004c,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32REGBCONDLE() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_BCOND_LE", producer: 0x6a09011f, consumer: 0x5400004d,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340TST32IMMCSETGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSET_GE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a9fb7e0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSET_LT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a9fa7e0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSET_GT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a9fd7e0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSET_LE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a9fc7e0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETMGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSETM_GE_RET_ONLY", producer: 0x7201011f, consumer: 0xda9fb3e0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETMLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSETM_LT_RET_ONLY", producer: 0x7201011f, consumer: 0xda9fa3e0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETMGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSETM_GT_RET_ONLY", producer: 0x7201011f, consumer: 0xda9fd3e0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSETMLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSETM_LE_RET_ONLY", producer: 0x7201011f, consumer: 0xda9fc3e0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSELGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSEL_GE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8ea1a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSELLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSEL_LT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8eb1a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSELGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSEL_GT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8ec1a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSELLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSEL_LE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8ed1a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINCGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINC_GE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8ea5a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINCLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINC_LT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8eb5a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINCGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINC_GT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8ec5a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINCLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINC_LE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8ed5a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINVGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINV_GE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8ea1a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINVLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINV_LT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8eb1a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINVGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINV_GT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8ec1a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSINVLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSINV_LE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8ed1a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSNEGGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSNEG_GE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8ea5a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSNEGLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSNEG_LT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8eb5a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSNEGGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSNEG_GT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8ec5a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCSNEGLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CSNEG_LE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8ed5a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINCGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINC_GE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8db5a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINCLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINC_LT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8da5a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINCGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINC_GT_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8dd5a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINCLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINC_LE_RET_ONLY", producer: 0x7201011f, consumer: 0x9a8dc5a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINVGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINV_GE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8db1a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINVLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINV_LT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8da1a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINVGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINV_GT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8dd1a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCINVLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CINV_LE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8dc1a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCNEGGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CNEG_GE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8db5a0,
            family: "tst", form: "IMM", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCNEGLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CNEG_LT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8da5a0,
            family: "tst", form: "IMM", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCNEGGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CNEG_GT_RET_ONLY", producer: 0x7201011f, consumer: 0xda8dd5a0,
            family: "tst", form: "IMM", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32IMMCNEGLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_IMM_CNEG_LE_RET_ONLY", producer: 0x7201011f, consumer: 0xda8dc5a0,
            family: "tst", form: "IMM", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSET_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a9fb7e0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSET_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a9fa7e0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSET_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a9fd7e0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSET_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a9fc7e0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETMGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSETM_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda9fb3e0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETMLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSETM_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda9fa3e0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETMGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSETM_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda9fd3e0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSETMLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSETM_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda9fc3e0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSELGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSEL_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8ea1a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSELLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSEL_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8eb1a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSELGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSEL_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8ec1a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSELLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSEL_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8ed1a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINCGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINC_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8ea5a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINCLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINC_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8eb5a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINCGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINC_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8ec5a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINCLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINC_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8ed5a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINVGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINV_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8ea1a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINVLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINV_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8eb1a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINVGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINV_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8ec1a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSINVLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSINV_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8ed1a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSNEGGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSNEG_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8ea5a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSNEGLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSNEG_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8eb5a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSNEGGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSNEG_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8ec5a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCSNEGLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CSNEG_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8ed5a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINCGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINC_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8db5a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINCLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINC_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8da5a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINCGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINC_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8dd5a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINCLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINC_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0x9a8dc5a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINVGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINV_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8db1a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINVLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINV_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8da1a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINVGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINV_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8dd1a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCINVLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CINV_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8dc1a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCNEGGERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CNEG_GE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8db5a0,
            family: "tst", form: "REG", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCNEGLTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CNEG_LT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8da5a0,
            family: "tst", form: "REG", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCNEGGTRETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CNEG_GT_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8dd5a0,
            family: "tst", form: "REG", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340TST32REGCNEGLERETONLY() throws {
        try LogicalRemainder340Fixture.check("TST_32_REG_CNEG_LE_RET_ONLY", producer: 0x6a09011f, consumer: 0xda8dc5a0,
            family: "tst", form: "REG", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: true)
    }
    func test340BICS32REGBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_GE_RD31", producer: 0x6a29011f, consumer: 0x5400004a,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_LT_RD31", producer: 0x6a29011f, consumer: 0x5400004b,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_GT_RD31", producer: 0x6a29011f, consumer: 0x5400004c,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_BCOND_LE_RD31", producer: 0x6a29011f, consumer: 0x5400004d,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_GE_RD31", producer: 0x6a29011f, consumer: 0x9a9fb7e0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_LT_RD31", producer: 0x6a29011f, consumer: 0x9a9fa7e0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_GT_RD31", producer: 0x6a29011f, consumer: 0x9a9fd7e0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSET_LE_RD31", producer: 0x6a29011f, consumer: 0x9a9fc7e0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_GE_RD31", producer: 0x6a29011f, consumer: 0xda9fb3e0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_LT_RD31", producer: 0x6a29011f, consumer: 0xda9fa3e0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_GT_RD31", producer: 0x6a29011f, consumer: 0xda9fd3e0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSETM_LE_RD31", producer: 0x6a29011f, consumer: 0xda9fc3e0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_GE_RD31", producer: 0x6a29011f, consumer: 0x9a8ea1a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_LT_RD31", producer: 0x6a29011f, consumer: 0x9a8eb1a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_GT_RD31", producer: 0x6a29011f, consumer: 0x9a8ec1a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSEL_LE_RD31", producer: 0x6a29011f, consumer: 0x9a8ed1a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_GE_RD31", producer: 0x6a29011f, consumer: 0x9a8ea5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_LT_RD31", producer: 0x6a29011f, consumer: 0x9a8eb5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_GT_RD31", producer: 0x6a29011f, consumer: 0x9a8ec5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINC_LE_RD31", producer: 0x6a29011f, consumer: 0x9a8ed5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_GE_RD31", producer: 0x6a29011f, consumer: 0xda8ea1a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_LT_RD31", producer: 0x6a29011f, consumer: 0xda8eb1a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_GT_RD31", producer: 0x6a29011f, consumer: 0xda8ec1a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSINV_LE_RD31", producer: 0x6a29011f, consumer: 0xda8ed1a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_GE_RD31", producer: 0x6a29011f, consumer: 0xda8ea5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_LT_RD31", producer: 0x6a29011f, consumer: 0xda8eb5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_GT_RD31", producer: 0x6a29011f, consumer: 0xda8ec5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CSNEG_LE_RD31", producer: 0x6a29011f, consumer: 0xda8ed5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_GE_RD31", producer: 0x6a29011f, consumer: 0x9a8db5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_LT_RD31", producer: 0x6a29011f, consumer: 0x9a8da5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_GT_RD31", producer: 0x6a29011f, consumer: 0x9a8dd5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINC_LE_RD31", producer: 0x6a29011f, consumer: 0x9a8dc5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_GE_RD31", producer: 0x6a29011f, consumer: 0xda8db1a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_LT_RD31", producer: 0x6a29011f, consumer: 0xda8da1a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_GT_RD31", producer: 0x6a29011f, consumer: 0xda8dd1a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CINV_LE_RD31", producer: 0x6a29011f, consumer: 0xda8dc1a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_GE_RD31", producer: 0x6a29011f, consumer: 0xda8db5a0,
            family: "bics", form: "REG", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_LT_RD31", producer: 0x6a29011f, consumer: 0xda8da5a0,
            family: "bics", form: "REG", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_GT_RD31", producer: 0x6a29011f, consumer: 0xda8dd5a0,
            family: "bics", form: "REG", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32REGCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_REG_CNEG_LE_RD31", producer: 0x6a29011f, consumer: 0xda8dc5a0,
            family: "bics", form: "REG", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS32LSLBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_GE_RD31", producer: 0x6a29051f, consumer: 0x5400004a,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_LT_RD31", producer: 0x6a29051f, consumer: 0x5400004b,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_GT_RD31", producer: 0x6a29051f, consumer: 0x5400004c,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_BCOND_LE_RD31", producer: 0x6a29051f, consumer: 0x5400004d,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_GE_RD31", producer: 0x6a29051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_LT_RD31", producer: 0x6a29051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_GT_RD31", producer: 0x6a29051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSET_LE_RD31", producer: 0x6a29051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_GE_RD31", producer: 0x6a29051f, consumer: 0xda9fb3e0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_LT_RD31", producer: 0x6a29051f, consumer: 0xda9fa3e0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_GT_RD31", producer: 0x6a29051f, consumer: 0xda9fd3e0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSETM_LE_RD31", producer: 0x6a29051f, consumer: 0xda9fc3e0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_GE_RD31", producer: 0x6a29051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_LT_RD31", producer: 0x6a29051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_GT_RD31", producer: 0x6a29051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSEL_LE_RD31", producer: 0x6a29051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_GE_RD31", producer: 0x6a29051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_LT_RD31", producer: 0x6a29051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_GT_RD31", producer: 0x6a29051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINC_LE_RD31", producer: 0x6a29051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_GE_RD31", producer: 0x6a29051f, consumer: 0xda8ea1a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_LT_RD31", producer: 0x6a29051f, consumer: 0xda8eb1a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_GT_RD31", producer: 0x6a29051f, consumer: 0xda8ec1a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSINV_LE_RD31", producer: 0x6a29051f, consumer: 0xda8ed1a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_GE_RD31", producer: 0x6a29051f, consumer: 0xda8ea5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_LT_RD31", producer: 0x6a29051f, consumer: 0xda8eb5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_GT_RD31", producer: 0x6a29051f, consumer: 0xda8ec5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CSNEG_LE_RD31", producer: 0x6a29051f, consumer: 0xda8ed5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_GE_RD31", producer: 0x6a29051f, consumer: 0x9a8db5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_LT_RD31", producer: 0x6a29051f, consumer: 0x9a8da5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_GT_RD31", producer: 0x6a29051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINC_LE_RD31", producer: 0x6a29051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_GE_RD31", producer: 0x6a29051f, consumer: 0xda8db1a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_LT_RD31", producer: 0x6a29051f, consumer: 0xda8da1a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_GT_RD31", producer: 0x6a29051f, consumer: 0xda8dd1a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CINV_LE_RD31", producer: 0x6a29051f, consumer: 0xda8dc1a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_GE_RD31", producer: 0x6a29051f, consumer: 0xda8db5a0,
            family: "bics", form: "LSL", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_LT_RD31", producer: 0x6a29051f, consumer: 0xda8da5a0,
            family: "bics", form: "LSL", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_GT_RD31", producer: 0x6a29051f, consumer: 0xda8dd5a0,
            family: "bics", form: "LSL", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSLCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSL_CNEG_LE_RD31", producer: 0x6a29051f, consumer: 0xda8dc5a0,
            family: "bics", form: "LSL", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_GE_RD31", producer: 0x6a69051f, consumer: 0x5400004a,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_LT_RD31", producer: 0x6a69051f, consumer: 0x5400004b,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_GT_RD31", producer: 0x6a69051f, consumer: 0x5400004c,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_BCOND_LE_RD31", producer: 0x6a69051f, consumer: 0x5400004d,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_GE_RD31", producer: 0x6a69051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_LT_RD31", producer: 0x6a69051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_GT_RD31", producer: 0x6a69051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSET_LE_RD31", producer: 0x6a69051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_GE_RD31", producer: 0x6a69051f, consumer: 0xda9fb3e0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_LT_RD31", producer: 0x6a69051f, consumer: 0xda9fa3e0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_GT_RD31", producer: 0x6a69051f, consumer: 0xda9fd3e0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSETM_LE_RD31", producer: 0x6a69051f, consumer: 0xda9fc3e0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_GE_RD31", producer: 0x6a69051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_LT_RD31", producer: 0x6a69051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_GT_RD31", producer: 0x6a69051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSEL_LE_RD31", producer: 0x6a69051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_GE_RD31", producer: 0x6a69051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_LT_RD31", producer: 0x6a69051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_GT_RD31", producer: 0x6a69051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINC_LE_RD31", producer: 0x6a69051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_GE_RD31", producer: 0x6a69051f, consumer: 0xda8ea1a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_LT_RD31", producer: 0x6a69051f, consumer: 0xda8eb1a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_GT_RD31", producer: 0x6a69051f, consumer: 0xda8ec1a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSINV_LE_RD31", producer: 0x6a69051f, consumer: 0xda8ed1a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_GE_RD31", producer: 0x6a69051f, consumer: 0xda8ea5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_LT_RD31", producer: 0x6a69051f, consumer: 0xda8eb5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_GT_RD31", producer: 0x6a69051f, consumer: 0xda8ec5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CSNEG_LE_RD31", producer: 0x6a69051f, consumer: 0xda8ed5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_GE_RD31", producer: 0x6a69051f, consumer: 0x9a8db5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_LT_RD31", producer: 0x6a69051f, consumer: 0x9a8da5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_GT_RD31", producer: 0x6a69051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINC_LE_RD31", producer: 0x6a69051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_GE_RD31", producer: 0x6a69051f, consumer: 0xda8db1a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_LT_RD31", producer: 0x6a69051f, consumer: 0xda8da1a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_GT_RD31", producer: 0x6a69051f, consumer: 0xda8dd1a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CINV_LE_RD31", producer: 0x6a69051f, consumer: 0xda8dc1a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_GE_RD31", producer: 0x6a69051f, consumer: 0xda8db5a0,
            family: "bics", form: "LSR", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_LT_RD31", producer: 0x6a69051f, consumer: 0xda8da5a0,
            family: "bics", form: "LSR", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_GT_RD31", producer: 0x6a69051f, consumer: 0xda8dd5a0,
            family: "bics", form: "LSR", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32LSRCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_LSR_CNEG_LE_RD31", producer: 0x6a69051f, consumer: 0xda8dc5a0,
            family: "bics", form: "LSR", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_GE_RD31", producer: 0x6aa9051f, consumer: 0x5400004a,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_LT_RD31", producer: 0x6aa9051f, consumer: 0x5400004b,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_GT_RD31", producer: 0x6aa9051f, consumer: 0x5400004c,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_BCOND_LE_RD31", producer: 0x6aa9051f, consumer: 0x5400004d,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_GE_RD31", producer: 0x6aa9051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_LT_RD31", producer: 0x6aa9051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_GT_RD31", producer: 0x6aa9051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSET_LE_RD31", producer: 0x6aa9051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_GE_RD31", producer: 0x6aa9051f, consumer: 0xda9fb3e0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_LT_RD31", producer: 0x6aa9051f, consumer: 0xda9fa3e0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_GT_RD31", producer: 0x6aa9051f, consumer: 0xda9fd3e0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSETM_LE_RD31", producer: 0x6aa9051f, consumer: 0xda9fc3e0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_GE_RD31", producer: 0x6aa9051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_LT_RD31", producer: 0x6aa9051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_GT_RD31", producer: 0x6aa9051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSEL_LE_RD31", producer: 0x6aa9051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_GE_RD31", producer: 0x6aa9051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_LT_RD31", producer: 0x6aa9051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_GT_RD31", producer: 0x6aa9051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINC_LE_RD31", producer: 0x6aa9051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_GE_RD31", producer: 0x6aa9051f, consumer: 0xda8ea1a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_LT_RD31", producer: 0x6aa9051f, consumer: 0xda8eb1a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_GT_RD31", producer: 0x6aa9051f, consumer: 0xda8ec1a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSINV_LE_RD31", producer: 0x6aa9051f, consumer: 0xda8ed1a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_GE_RD31", producer: 0x6aa9051f, consumer: 0xda8ea5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_LT_RD31", producer: 0x6aa9051f, consumer: 0xda8eb5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_GT_RD31", producer: 0x6aa9051f, consumer: 0xda8ec5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CSNEG_LE_RD31", producer: 0x6aa9051f, consumer: 0xda8ed5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_GE_RD31", producer: 0x6aa9051f, consumer: 0x9a8db5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_LT_RD31", producer: 0x6aa9051f, consumer: 0x9a8da5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_GT_RD31", producer: 0x6aa9051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINC_LE_RD31", producer: 0x6aa9051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_GE_RD31", producer: 0x6aa9051f, consumer: 0xda8db1a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_LT_RD31", producer: 0x6aa9051f, consumer: 0xda8da1a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_GT_RD31", producer: 0x6aa9051f, consumer: 0xda8dd1a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CINV_LE_RD31", producer: 0x6aa9051f, consumer: 0xda8dc1a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_GE_RD31", producer: 0x6aa9051f, consumer: 0xda8db5a0,
            family: "bics", form: "ASR", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_LT_RD31", producer: 0x6aa9051f, consumer: 0xda8da5a0,
            family: "bics", form: "ASR", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_GT_RD31", producer: 0x6aa9051f, consumer: 0xda8dd5a0,
            family: "bics", form: "ASR", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32ASRCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ASR_CNEG_LE_RD31", producer: 0x6aa9051f, consumer: 0xda8dc5a0,
            family: "bics", form: "ASR", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_GE_RD31", producer: 0x6ae9051f, consumer: 0x5400004a,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_LT_RD31", producer: 0x6ae9051f, consumer: 0x5400004b,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_GT_RD31", producer: 0x6ae9051f, consumer: 0x5400004c,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_BCOND_LE_RD31", producer: 0x6ae9051f, consumer: 0x5400004d,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_GE_RD31", producer: 0x6ae9051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_LT_RD31", producer: 0x6ae9051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_GT_RD31", producer: 0x6ae9051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSET_LE_RD31", producer: 0x6ae9051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_GE_RD31", producer: 0x6ae9051f, consumer: 0xda9fb3e0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_LT_RD31", producer: 0x6ae9051f, consumer: 0xda9fa3e0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_GT_RD31", producer: 0x6ae9051f, consumer: 0xda9fd3e0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSETM_LE_RD31", producer: 0x6ae9051f, consumer: 0xda9fc3e0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_GE_RD31", producer: 0x6ae9051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_LT_RD31", producer: 0x6ae9051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_GT_RD31", producer: 0x6ae9051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSEL_LE_RD31", producer: 0x6ae9051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_GE_RD31", producer: 0x6ae9051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_LT_RD31", producer: 0x6ae9051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_GT_RD31", producer: 0x6ae9051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINC_LE_RD31", producer: 0x6ae9051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_GE_RD31", producer: 0x6ae9051f, consumer: 0xda8ea1a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_LT_RD31", producer: 0x6ae9051f, consumer: 0xda8eb1a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_GT_RD31", producer: 0x6ae9051f, consumer: 0xda8ec1a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSINV_LE_RD31", producer: 0x6ae9051f, consumer: 0xda8ed1a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_GE_RD31", producer: 0x6ae9051f, consumer: 0xda8ea5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_LT_RD31", producer: 0x6ae9051f, consumer: 0xda8eb5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_GT_RD31", producer: 0x6ae9051f, consumer: 0xda8ec5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CSNEG_LE_RD31", producer: 0x6ae9051f, consumer: 0xda8ed5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_GE_RD31", producer: 0x6ae9051f, consumer: 0x9a8db5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_LT_RD31", producer: 0x6ae9051f, consumer: 0x9a8da5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_GT_RD31", producer: 0x6ae9051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINC_LE_RD31", producer: 0x6ae9051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_GE_RD31", producer: 0x6ae9051f, consumer: 0xda8db1a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_LT_RD31", producer: 0x6ae9051f, consumer: 0xda8da1a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_GT_RD31", producer: 0x6ae9051f, consumer: 0xda8dd1a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CINV_LE_RD31", producer: 0x6ae9051f, consumer: 0xda8dc1a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_GE_RD31", producer: 0x6ae9051f, consumer: 0xda8db5a0,
            family: "bics", form: "ROR", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_LT_RD31", producer: 0x6ae9051f, consumer: 0xda8da5a0,
            family: "bics", form: "ROR", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_GT_RD31", producer: 0x6ae9051f, consumer: 0xda8dd5a0,
            family: "bics", form: "ROR", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS32RORCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_32_ROR_CNEG_LE_RD31", producer: 0x6ae9051f, consumer: 0xda8dc5a0,
            family: "bics", form: "ROR", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64REGBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_GE_RD31", producer: 0xea29011f, consumer: 0x5400004a,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_LT_RD31", producer: 0xea29011f, consumer: 0x5400004b,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_GT_RD31", producer: 0xea29011f, consumer: 0x5400004c,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_BCOND_LE_RD31", producer: 0xea29011f, consumer: 0x5400004d,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_GE_RD31", producer: 0xea29011f, consumer: 0x9a9fb7e0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_LT_RD31", producer: 0xea29011f, consumer: 0x9a9fa7e0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_GT_RD31", producer: 0xea29011f, consumer: 0x9a9fd7e0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSET_LE_RD31", producer: 0xea29011f, consumer: 0x9a9fc7e0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_GE_RD31", producer: 0xea29011f, consumer: 0xda9fb3e0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_LT_RD31", producer: 0xea29011f, consumer: 0xda9fa3e0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_GT_RD31", producer: 0xea29011f, consumer: 0xda9fd3e0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSETM_LE_RD31", producer: 0xea29011f, consumer: 0xda9fc3e0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_GE_RD31", producer: 0xea29011f, consumer: 0x9a8ea1a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_LT_RD31", producer: 0xea29011f, consumer: 0x9a8eb1a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_GT_RD31", producer: 0xea29011f, consumer: 0x9a8ec1a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSEL_LE_RD31", producer: 0xea29011f, consumer: 0x9a8ed1a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_GE_RD31", producer: 0xea29011f, consumer: 0x9a8ea5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_LT_RD31", producer: 0xea29011f, consumer: 0x9a8eb5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_GT_RD31", producer: 0xea29011f, consumer: 0x9a8ec5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINC_LE_RD31", producer: 0xea29011f, consumer: 0x9a8ed5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_GE_RD31", producer: 0xea29011f, consumer: 0xda8ea1a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_LT_RD31", producer: 0xea29011f, consumer: 0xda8eb1a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_GT_RD31", producer: 0xea29011f, consumer: 0xda8ec1a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSINV_LE_RD31", producer: 0xea29011f, consumer: 0xda8ed1a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_GE_RD31", producer: 0xea29011f, consumer: 0xda8ea5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_LT_RD31", producer: 0xea29011f, consumer: 0xda8eb5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_GT_RD31", producer: 0xea29011f, consumer: 0xda8ec5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CSNEG_LE_RD31", producer: 0xea29011f, consumer: 0xda8ed5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_GE_RD31", producer: 0xea29011f, consumer: 0x9a8db5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_LT_RD31", producer: 0xea29011f, consumer: 0x9a8da5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_GT_RD31", producer: 0xea29011f, consumer: 0x9a8dd5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINC_LE_RD31", producer: 0xea29011f, consumer: 0x9a8dc5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_GE_RD31", producer: 0xea29011f, consumer: 0xda8db1a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_LT_RD31", producer: 0xea29011f, consumer: 0xda8da1a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_GT_RD31", producer: 0xea29011f, consumer: 0xda8dd1a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CINV_LE_RD31", producer: 0xea29011f, consumer: 0xda8dc1a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_GE_RD31", producer: 0xea29011f, consumer: 0xda8db5a0,
            family: "bics", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_LT_RD31", producer: 0xea29011f, consumer: 0xda8da5a0,
            family: "bics", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_GT_RD31", producer: 0xea29011f, consumer: 0xda8dd5a0,
            family: "bics", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64REGCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_REG_CNEG_LE_RD31", producer: 0xea29011f, consumer: 0xda8dc5a0,
            family: "bics", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: false, retOnly: false)
    }
    func test340BICS64LSLBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_GE_RD31", producer: 0xea29051f, consumer: 0x5400004a,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_LT_RD31", producer: 0xea29051f, consumer: 0x5400004b,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_GT_RD31", producer: 0xea29051f, consumer: 0x5400004c,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_BCOND_LE_RD31", producer: 0xea29051f, consumer: 0x5400004d,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_GE_RD31", producer: 0xea29051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_LT_RD31", producer: 0xea29051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_GT_RD31", producer: 0xea29051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSET_LE_RD31", producer: 0xea29051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_GE_RD31", producer: 0xea29051f, consumer: 0xda9fb3e0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_LT_RD31", producer: 0xea29051f, consumer: 0xda9fa3e0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_GT_RD31", producer: 0xea29051f, consumer: 0xda9fd3e0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSETM_LE_RD31", producer: 0xea29051f, consumer: 0xda9fc3e0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_GE_RD31", producer: 0xea29051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_LT_RD31", producer: 0xea29051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_GT_RD31", producer: 0xea29051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSEL_LE_RD31", producer: 0xea29051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_GE_RD31", producer: 0xea29051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_LT_RD31", producer: 0xea29051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_GT_RD31", producer: 0xea29051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINC_LE_RD31", producer: 0xea29051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_GE_RD31", producer: 0xea29051f, consumer: 0xda8ea1a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_LT_RD31", producer: 0xea29051f, consumer: 0xda8eb1a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_GT_RD31", producer: 0xea29051f, consumer: 0xda8ec1a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSINV_LE_RD31", producer: 0xea29051f, consumer: 0xda8ed1a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_GE_RD31", producer: 0xea29051f, consumer: 0xda8ea5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_LT_RD31", producer: 0xea29051f, consumer: 0xda8eb5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_GT_RD31", producer: 0xea29051f, consumer: 0xda8ec5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CSNEG_LE_RD31", producer: 0xea29051f, consumer: 0xda8ed5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_GE_RD31", producer: 0xea29051f, consumer: 0x9a8db5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_LT_RD31", producer: 0xea29051f, consumer: 0x9a8da5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_GT_RD31", producer: 0xea29051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINC_LE_RD31", producer: 0xea29051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_GE_RD31", producer: 0xea29051f, consumer: 0xda8db1a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_LT_RD31", producer: 0xea29051f, consumer: 0xda8da1a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_GT_RD31", producer: 0xea29051f, consumer: 0xda8dd1a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CINV_LE_RD31", producer: 0xea29051f, consumer: 0xda8dc1a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_GE_RD31", producer: 0xea29051f, consumer: 0xda8db5a0,
            family: "bics", form: "LSL", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_LT_RD31", producer: 0xea29051f, consumer: 0xda8da5a0,
            family: "bics", form: "LSL", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_GT_RD31", producer: 0xea29051f, consumer: 0xda8dd5a0,
            family: "bics", form: "LSL", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSLCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSL_CNEG_LE_RD31", producer: 0xea29051f, consumer: 0xda8dc5a0,
            family: "bics", form: "LSL", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_GE_RD31", producer: 0xea69051f, consumer: 0x5400004a,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_LT_RD31", producer: 0xea69051f, consumer: 0x5400004b,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_GT_RD31", producer: 0xea69051f, consumer: 0x5400004c,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_BCOND_LE_RD31", producer: 0xea69051f, consumer: 0x5400004d,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_GE_RD31", producer: 0xea69051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_LT_RD31", producer: 0xea69051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_GT_RD31", producer: 0xea69051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSET_LE_RD31", producer: 0xea69051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_GE_RD31", producer: 0xea69051f, consumer: 0xda9fb3e0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_LT_RD31", producer: 0xea69051f, consumer: 0xda9fa3e0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_GT_RD31", producer: 0xea69051f, consumer: 0xda9fd3e0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSETM_LE_RD31", producer: 0xea69051f, consumer: 0xda9fc3e0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_GE_RD31", producer: 0xea69051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_LT_RD31", producer: 0xea69051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_GT_RD31", producer: 0xea69051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSEL_LE_RD31", producer: 0xea69051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_GE_RD31", producer: 0xea69051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_LT_RD31", producer: 0xea69051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_GT_RD31", producer: 0xea69051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINC_LE_RD31", producer: 0xea69051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_GE_RD31", producer: 0xea69051f, consumer: 0xda8ea1a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_LT_RD31", producer: 0xea69051f, consumer: 0xda8eb1a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_GT_RD31", producer: 0xea69051f, consumer: 0xda8ec1a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSINV_LE_RD31", producer: 0xea69051f, consumer: 0xda8ed1a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_GE_RD31", producer: 0xea69051f, consumer: 0xda8ea5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_LT_RD31", producer: 0xea69051f, consumer: 0xda8eb5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_GT_RD31", producer: 0xea69051f, consumer: 0xda8ec5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CSNEG_LE_RD31", producer: 0xea69051f, consumer: 0xda8ed5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_GE_RD31", producer: 0xea69051f, consumer: 0x9a8db5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_LT_RD31", producer: 0xea69051f, consumer: 0x9a8da5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_GT_RD31", producer: 0xea69051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINC_LE_RD31", producer: 0xea69051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_GE_RD31", producer: 0xea69051f, consumer: 0xda8db1a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_LT_RD31", producer: 0xea69051f, consumer: 0xda8da1a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_GT_RD31", producer: 0xea69051f, consumer: 0xda8dd1a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CINV_LE_RD31", producer: 0xea69051f, consumer: 0xda8dc1a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_GE_RD31", producer: 0xea69051f, consumer: 0xda8db5a0,
            family: "bics", form: "LSR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_LT_RD31", producer: 0xea69051f, consumer: 0xda8da5a0,
            family: "bics", form: "LSR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_GT_RD31", producer: 0xea69051f, consumer: 0xda8dd5a0,
            family: "bics", form: "LSR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64LSRCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_LSR_CNEG_LE_RD31", producer: 0xea69051f, consumer: 0xda8dc5a0,
            family: "bics", form: "LSR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_GE_RD31", producer: 0xeaa9051f, consumer: 0x5400004a,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_LT_RD31", producer: 0xeaa9051f, consumer: 0x5400004b,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_GT_RD31", producer: 0xeaa9051f, consumer: 0x5400004c,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_BCOND_LE_RD31", producer: 0xeaa9051f, consumer: 0x5400004d,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_GE_RD31", producer: 0xeaa9051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_LT_RD31", producer: 0xeaa9051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_GT_RD31", producer: 0xeaa9051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSET_LE_RD31", producer: 0xeaa9051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_GE_RD31", producer: 0xeaa9051f, consumer: 0xda9fb3e0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_LT_RD31", producer: 0xeaa9051f, consumer: 0xda9fa3e0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_GT_RD31", producer: 0xeaa9051f, consumer: 0xda9fd3e0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSETM_LE_RD31", producer: 0xeaa9051f, consumer: 0xda9fc3e0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_GE_RD31", producer: 0xeaa9051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_LT_RD31", producer: 0xeaa9051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_GT_RD31", producer: 0xeaa9051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSEL_LE_RD31", producer: 0xeaa9051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_GE_RD31", producer: 0xeaa9051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_LT_RD31", producer: 0xeaa9051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_GT_RD31", producer: 0xeaa9051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINC_LE_RD31", producer: 0xeaa9051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_GE_RD31", producer: 0xeaa9051f, consumer: 0xda8ea1a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_LT_RD31", producer: 0xeaa9051f, consumer: 0xda8eb1a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_GT_RD31", producer: 0xeaa9051f, consumer: 0xda8ec1a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSINV_LE_RD31", producer: 0xeaa9051f, consumer: 0xda8ed1a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_GE_RD31", producer: 0xeaa9051f, consumer: 0xda8ea5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_LT_RD31", producer: 0xeaa9051f, consumer: 0xda8eb5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_GT_RD31", producer: 0xeaa9051f, consumer: 0xda8ec5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CSNEG_LE_RD31", producer: 0xeaa9051f, consumer: 0xda8ed5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_GE_RD31", producer: 0xeaa9051f, consumer: 0x9a8db5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_LT_RD31", producer: 0xeaa9051f, consumer: 0x9a8da5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_GT_RD31", producer: 0xeaa9051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINC_LE_RD31", producer: 0xeaa9051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_GE_RD31", producer: 0xeaa9051f, consumer: 0xda8db1a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_LT_RD31", producer: 0xeaa9051f, consumer: 0xda8da1a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_GT_RD31", producer: 0xeaa9051f, consumer: 0xda8dd1a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CINV_LE_RD31", producer: 0xeaa9051f, consumer: 0xda8dc1a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_GE_RD31", producer: 0xeaa9051f, consumer: 0xda8db5a0,
            family: "bics", form: "ASR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_LT_RD31", producer: 0xeaa9051f, consumer: 0xda8da5a0,
            family: "bics", form: "ASR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_GT_RD31", producer: 0xeaa9051f, consumer: 0xda8dd5a0,
            family: "bics", form: "ASR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64ASRCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ASR_CNEG_LE_RD31", producer: 0xeaa9051f, consumer: 0xda8dc5a0,
            family: "bics", form: "ASR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_GE_RD31", producer: 0xeae9051f, consumer: 0x5400004a,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_LT_RD31", producer: 0xeae9051f, consumer: 0x5400004b,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_GT_RD31", producer: 0xeae9051f, consumer: 0x5400004c,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORBCONDLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_BCOND_LE_RD31", producer: 0xeae9051f, consumer: 0x5400004d,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_GE_RD31", producer: 0xeae9051f, consumer: 0x9a9fb7e0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_LT_RD31", producer: 0xeae9051f, consumer: 0x9a9fa7e0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_GT_RD31", producer: 0xeae9051f, consumer: 0x9a9fd7e0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSET_LE_RD31", producer: 0xeae9051f, consumer: 0x9a9fc7e0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_GE_RD31", producer: 0xeae9051f, consumer: 0xda9fb3e0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_LT_RD31", producer: 0xeae9051f, consumer: 0xda9fa3e0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_GT_RD31", producer: 0xeae9051f, consumer: 0xda9fd3e0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSETMLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSETM_LE_RD31", producer: 0xeae9051f, consumer: 0xda9fc3e0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_GE_RD31", producer: 0xeae9051f, consumer: 0x9a8ea1a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_LT_RD31", producer: 0xeae9051f, consumer: 0x9a8eb1a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_GT_RD31", producer: 0xeae9051f, consumer: 0x9a8ec1a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSELLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSEL_LE_RD31", producer: 0xeae9051f, consumer: 0x9a8ed1a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_GE_RD31", producer: 0xeae9051f, consumer: 0x9a8ea5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_LT_RD31", producer: 0xeae9051f, consumer: 0x9a8eb5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_GT_RD31", producer: 0xeae9051f, consumer: 0x9a8ec5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINC_LE_RD31", producer: 0xeae9051f, consumer: 0x9a8ed5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_GE_RD31", producer: 0xeae9051f, consumer: 0xda8ea1a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_LT_RD31", producer: 0xeae9051f, consumer: 0xda8eb1a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_GT_RD31", producer: 0xeae9051f, consumer: 0xda8ec1a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSINV_LE_RD31", producer: 0xeae9051f, consumer: 0xda8ed1a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_GE_RD31", producer: 0xeae9051f, consumer: 0xda8ea5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_LT_RD31", producer: 0xeae9051f, consumer: 0xda8eb5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_GT_RD31", producer: 0xeae9051f, consumer: 0xda8ec5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCSNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CSNEG_LE_RD31", producer: 0xeae9051f, consumer: 0xda8ed5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_GE_RD31", producer: 0xeae9051f, consumer: 0x9a8db5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_LT_RD31", producer: 0xeae9051f, consumer: 0x9a8da5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_GT_RD31", producer: 0xeae9051f, consumer: 0x9a8dd5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINCLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINC_LE_RD31", producer: 0xeae9051f, consumer: 0x9a8dc5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_GE_RD31", producer: 0xeae9051f, consumer: 0xda8db1a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_LT_RD31", producer: 0xeae9051f, consumer: 0xda8da1a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_GT_RD31", producer: 0xeae9051f, consumer: 0xda8dd1a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCINVLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CINV_LE_RD31", producer: 0xeae9051f, consumer: 0xda8dc1a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGGERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_GE_RD31", producer: 0xeae9051f, consumer: 0xda8db5a0,
            family: "bics", form: "ROR", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGLTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_LT_RD31", producer: 0xeae9051f, consumer: 0xda8da5a0,
            family: "bics", form: "ROR", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGGTRD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_GT_RD31", producer: 0xeae9051f, consumer: 0xda8dd5a0,
            family: "bics", form: "ROR", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }
    func test340BICS64RORCNEGLERD31() throws {
        try LogicalRemainder340Fixture.check("BICS_64_ROR_CNEG_LE_RD31", producer: 0xeae9051f, consumer: 0xda8dc5a0,
            family: "bics", form: "ROR", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "", preservation: true, refusal: true, retOnly: false)
    }

}


// Source-authored component fixtures. No method in this extension was executed.
// OrdinaryC evaluates the actual emitted producer and consumer statements, with
// explicit destination declarations; this grants no original-function return proof.
enum LogicalRemainder340Fixture {
    static func check(_ id: String, producer: UInt32, consumer: UInt32,
        family: String, form: String, width: Int, suffix: String, mnemonic: String,
        guardSuffix: String = "", preservation: Bool = false, refusal: Bool = false, retOnly: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let chain = family == "ccmp" || family == "ccmn"
        let loads: [UInt32] = width == 32
            ? [0xb9400268, 0xb9400289, 0xb94002aa]
            : [0xf9400268, 0xf9400289, 0xf94002aa]
        let first: UInt32 = width == 32 ? 0x7100055f : 0xf100055f
        let tail: [UInt32] = retOnly ? [0xd65f03c0] : [0x710001ff, 0xd65f03c0]
        let words = loads + (chain ? [first] : []) + [producer, consumer] + tail
        let rows = decode(words)
        XCTAssertEqual(rows.count, words.count, id, file: file, line: line)
        XCTAssertFalse(rows.contains { $0.mnemonic == "unknown" || $0.mnemonic == ".word" },
            id, file: file, line: line)
        let producerAddress: UInt64 = chain ? 0x7010 : 0x700c
        let consumerAddress = producerAddress + 4
        let function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_340_cell", instructions: rows)
        let legacy = MacIRBuilder(skippingRejectedCFGReconciliation: false,
            explicitCFGEnabled: nil, nativeSignedWordCMPEnabled: false)
            .buildFunction(name: "_340_cell", instructions: rows)
        XCTAssertFalse(function.ssaEnabled, id, file: file, line: line)
        let prefix = width == 32 ? "w" : "x"
        let overrides = [prefix + "8": "source_word", prefix + "9": "other_word",
            prefix + "10": "guard_word", prefix + "12": "logical_result",
            "x13": "selected_a", "x14": "selected_b", "x0": "result"]
        let printer = PseudocodePrinter(options: .default)
        let names = PseudocodeNameContext(function: function, registerNameOverrides: overrides)
        let oldNames = PseudocodeNameContext(function: legacy, registerNameOverrides: overrides)
        let p = try XCTUnwrap(function.instructions.first { $0.source.address == producerAddress },
            id, file: file, line: line)
        let c = try XCTUnwrap(function.instructions.first { $0.source.address == consumerAddress },
            id, file: file, line: line)
        let oldP = try XCTUnwrap(legacy.instructions.first { $0.source.address == producerAddress },
            id, file: file, line: line)
        let oldC = try XCTUnwrap(legacy.instructions.first { $0.source.address == consumerAddress },
            id, file: file, line: line)
        XCTAssertEqual(p.source.mnemonic, family, id, file: file, line: line)
        XCTAssertEqual(c.source.mnemonic, mnemonic, id, file: file, line: line)
        if preservation {
            XCTAssertEqual(function.instructions, legacy.instructions, id, file: file, line: line)
            XCTAssertEqual(printer.print(function: function, registerNameOverrides: overrides).text,
                printer.print(function: legacy, registerNameOverrides: overrides).text,
                id, file: file, line: line)
            if refusal {
                if mnemonic.hasPrefix("b.") {
                    guard case let .intrinsic(nil, name, _) = c.operation else {
                        return XCTFail("expected explicit branch refusal", file: file, line: line)
                    }
                    XCTAssertEqual(name, "branch_" + suffix, file: file, line: line)
                } else {
                    guard case .unknown = c.operation else {
                        return XCTFail("expected explicit unknown consumer", file: file, line: line)
                    }
                }
            }
            return
        }
        // Before the fix this assertion is a behavioral RED, not a compile-error claim.
        XCTAssertNotEqual(c.operation, oldC.operation, id, file: file, line: line)
        let actual = printer.render(instruction: c, names: names)
        let producerText = printer.render(instruction: p, names: names)
        let oldProducerText = printer.render(instruction: oldP, names: oldNames)
        let statement: String
        if mnemonic.hasPrefix("b.") {
            guard case let .conditionalBranch(condition, left, right, _) = c.operation else {
                return XCTFail("\(id): expected actual branch", file: file, line: line)
            }
            statement = printer.render(operation: .compareToBool(destination: .register(name: "x0", version: 0),
                condition: condition, left: left, right: right), names: names)
            XCTAssertTrue(actual.contains("if (\(statement.dropFirst("result = ".count)))"),
                actual, file: file, line: line)
        } else { statement = actual }
        XCTAssertFalse(statement.contains("__unknown("), statement, file: file, line: line)
        XCTAssertTrue(statement.contains(width == 32 ? "0x80000000" : "0x8000000000000000"),
            statement, file: file, line: line)
        let writesResult = !chain && family != "tst" && producer & 31 != 31
        if writesResult {
            guard case let .assign(destination, _) = p.operation,
                  case let .register(register, version) = destination else {
                return XCTFail("\(id): expected register result", file: file, line: line)
            }
            let target = MacIRNameBindingTarget.register(name: register, version: version)
            XCTAssertEqual(function.nameBindings.first { $0.target == target }?.type, "int\(width)_t",
                id, file: file, line: line)
            XCTAssertEqual(function.nameBindings, legacy.nameBindings,
                "no declaration, binding or inferred type may change", file: file, line: line)
            XCTAssertNotEqual(producerText, oldProducerText, id, file: file, line: line)
            XCTAssertTrue(producerText.contains("logical_result = "), producerText, file: file, line: line)
            XCTAssertTrue(producerText.contains(width == 32 ? "0x80000000" : "0x8000000000000000"),
                producerText, file: file, line: line)
            XCTAssertTrue(statement.contains("(uint\(width)_t)"), statement, file: file, line: line)
        }
        let signature = "int64_t cell340(uint\(width)_t source_word, uint\(width)_t other_word, uint\(width)_t guard_word, int64_t selected_a, int64_t selected_b) {"
        let observation: UInt64 = 0x7100
        let inputType: OrdinaryC.CType = width == 32 ? .u32 : .u64
        let contract = OrdinaryC.Contract(signature: signature,
            inputs: [.init(name: "source_word", type: inputType, entrySlot: 8),
                .init(name: "other_word", type: inputType, entrySlot: 9),
                .init(name: "guard_word", type: inputType, entrySlot: 10),
                .init(name: "selected_a", type: .i64, entrySlot: 13),
                .init(name: "selected_b", type: .i64, entrySlot: 14)],
            fields: [], calls: [:], exterior: [:], terminalRow: 99,
            terminalPayload: "return result;", terminalName: "result", returnType: .i64,
            rowsByAddress: [producerAddress: 3, consumerAddress: 4, observation: 99],
            allowedLabels: [], memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        var lines: [OrdinaryC.TextLine] = [.init(text: signature, source: nil, envelope: .signature)]
        if writesResult {
            // Explicit signed declaration is essential: inference from the RHS
            // alone would conceal an out-of-range assignment in the real C.
            lines += [.init(text: "int\(width)_t logical_result;", source: nil, envelope: .body),
                .init(text: producerText + ";", source: producerAddress, envelope: .body)]
        }
        lines += [.init(text: "int64_t result;", source: nil, envelope: .body),
            .init(text: statement + ";", source: consumerAddress, envelope: .body),
            .init(text: "return result;", source: observation, envelope: .body),
            .init(text: "}", source: nil, envelope: .closingBrace)]
        let program = try OrdinaryC.Program(lines: lines, contract: contract)
        let boundaries: [UInt64] = width == 32 ? [0x80000000, 0xffffffff, 0, 0x7fffffff]
            : [0x8000000000000000, 0xffffffffffffffff, 0, 0x7fffffffffffffff]
        let other: UInt64 = chain ? 1 : family == "bics" ? 0 : width == 32 ? 0xffffffff : UInt64.max
        var scenarios: [(UInt64, UInt64)] = []
        if chain {
            let pairs: [String: (UInt64, UInt64)] = ["eq": (1, 0), "ne": (0, 1),
                "hs": (2, 0), "lo": (0, 2), "hi": (2, 0), "ls": (0, 2),
                "ge": (2, boundaries[0]), "lt": (boundaries[0], 2),
                "gt": (2, boundaries[0]), "le": (boundaries[0], 2)]
            let guards = try XCTUnwrap(pairs[guardSuffix], id, file: file, line: line)
            for bits in boundaries { scenarios += [(bits, guards.0), (bits, guards.1)] }
            // Independent first-guard boundaries catch CCMN's otherwise-masked defect.
            for guardBits in boundaries { scenarios.append((0, guardBits)) }
        } else { scenarios = boundaries.map { ($0, 0) } }
        for (bits, guardBits) in scenarios {
            do {
                let observed = try OrdinaryC.Machine(program: program, scenario: .init(
                    name: "\(id)-\(bits)-\(guardBits)",
                    inputs: ["source_word": .init(bits, inputType), "other_word": .init(other, inputType),
                        "guard_word": .init(guardBits, inputType), "selected_a": .init(5, .i64),
                        "selected_b": .init(9, .i64)], memory: [:], responses: [])).run()
                let holds: Bool
                if chain {
                    let guardHolds = comparison(guardBits, 1, suffix: guardSuffix, width: width)
                    let executed = family == "ccmp"
                        ? comparison(bits, 1, suffix: suffix, width: width)
                        : signedRelation(signed(bits, width: width), -1, suffix: suffix)
                    let nzcv = producer & 15, n = nzcv & 8 != 0, z = nzcv & 4 != 0, v = nzcv & 1 != 0
                    let fallback: Bool
                    switch suffix {
                    case "ge": fallback = n == v
                    case "lt": fallback = n != v
                    case "gt": fallback = !z && n == v
                    default: fallback = z || n != v
                    }
                    holds = guardHolds ? executed : fallback
                } else {
                    let resultBits = form == "IMM" ? bits & (width == 32 ? 0x80000000 : 0x8000000000000000) : bits
                    holds = signedRelation(signed(resultBits, width: width), 0, suffix: suffix)
                }
                let expected: Int64
                switch mnemonic {
                case "cset": expected = holds ? 1 : 0
                case "csetm": expected = holds ? -1 : 0
                case "csel": expected = holds ? 5 : 9
                case "csinc": expected = holds ? 5 : 10
                case "csinv": expected = holds ? 5 : -10
                case "csneg": expected = holds ? 5 : -9
                case "cinc": expected = holds ? 6 : 5
                case "cinv": expected = holds ? -6 : 5
                case "cneg": expected = holds ? -5 : 5
                default: expected = holds ? 1 : 0
                }
                XCTAssertTrue(observed.returned, id, file: file, line: line)
                XCTAssertEqual(observed.terminal?.bits, UInt64(bitPattern: expected),
                    "\(id), \(bits), \(guardBits): \(producerText); \(statement)", file: file, line: line)
            } catch { XCTFail("\(id), \(bits), \(guardBits): \(error)", file: file, line: line) }
        }
    }

    static func decode(_ words: [UInt32]) -> [InstructionRow] {
        let bytes = words.flatMap { word in [UInt8(truncatingIfNeeded: word),
            UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word >> 16),
            UInt8(truncatingIfNeeded: word >> 24)] }
        return ARM64Decoder().decode(Data(bytes), baseAddress: 0x7000,
            maxInstructionCount: words.count).map { InstructionRow(decoded: $0) }
    }
    private static func signed(_ bits: UInt64, width: Int) -> Int64 {
        width == 32 ? Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: bits))) : Int64(bitPattern: bits)
    }
    private static func signedRelation(_ a: Int64, _ b: Int64, suffix: String) -> Bool {
        switch suffix { case "ge": return a >= b; case "lt": return a < b
        case "gt": return a > b; default: return a <= b }
    }
    private static func comparison(_ a: UInt64, _ b: UInt64, suffix: String, width: Int) -> Bool {
        switch suffix {
        case "eq": return a == b
        case "ne": return a != b
        case "hs": return a >= b
        case "lo": return a < b
        case "hi": return a > b
        case "ls": return a <= b
        default: return signedRelation(signed(a, width: width), signed(b, width: width), suffix: suffix)
        }
    }
}


extension DecodedRegionalSwitchTests {
    private func gate340(_ tail: [UInt32], width: Int = 32) -> String? {
        let producer: UInt32 = width == 32 ? 0x6a09011f : 0xea09011f
        let rows = LogicalRemainder340Fixture.decode([producer, 0x9a9fb7e0] + tail)
        let sources = rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
            mnemonic: $0.mnemonic, operands: $0.operands) }
        return MacIRBuilder.nativeLogicalContinuationRefusal(producer: sources[0],
            consumer: sources[1], sources: sources)
    }

    func test340CFGRejectsIndirectBranch() { XCTAssertEqual(gate340([0xd61f0200]), "indirect-branch") }
    func test340CFGRejectsCall() { XCTAssertEqual(gate340([0x94000001, 0xd65f03c0]), "call") }
    func test340CFGRejectsTailTransfer() { XCTAssertEqual(gate340([0x14000020]), "tail-or-unresolved-successor") }
    func test340CFGRejectsUnknownRow() { XCTAssertEqual(gate340([0xffffffff]), "unknown-or-undecoded") }
    func test340CFGRejectsMissingSuccessor() { XCTAssertEqual(gate340([0xd503201f]), "unknown-or-undecoded") }
    func test340CFGRejectsRowCap() {
        XCTAssertEqual(gate340(Array(repeating: 0xd503201f, count: 63)), "row-cap")
    }
    func test340CFGRejectsBlockCap() {
        // Each CBZ has both fallthrough and target+8; no edge is pruned.
        XCTAssertEqual(gate340(Array(repeating: 0xb4000048, count: 18) + [0xd65f03c0, 0xd65f03c0]), "block-cap")
    }
    func test340CFGRejectsSecondNZCVReader() { XCTAssertEqual(gate340([0x9a9fb7e1, 0xd65f03c0]), "nzcv-reader") }
    func test340CFGRejectsADCReader() { XCTAssertEqual(gate340([0x9a09010b, 0xd65f03c0]), "nzcv-reader") }
    func test340CFGRejectsCCMPBeforeClosingWriter() {
        XCTAssertEqual(gate340([0x7a41a908, 0xd65f03c0]), "nzcv-reader")
    }
    func test340CFGRejectsUnclosedCycle() { XCTAssertEqual(gate340([0x14000000]), "unclosed-cycle") }
    func test340CFGRejectsProducerBypass() {
        XCTAssertEqual(gate340([0x17ffffff]), "producer-bypass")
    }
    func test340CFGClosesAtExactRET() { XCTAssertNil(gate340([0xd65f03c0])) }
    func test340CFGClosesAtExactXCMPLiteral() { XCTAssertNil(gate340([0xf10001ff, 0xd65f03c0], width: 64)) }
    func test340CFGRejectsMismatchedWriterOperands() {
        let producer = MacIRSourceSpan(address: 0x7000, byteText: "1f 01 09 6a", mnemonic: "tst", operands: "w8, w9")
        let consumer = MacIRSourceSpan(address: 0x7004, byteText: "e0 b7 9f 9a", mnemonic: "cset", operands: "x0, ge")
        let forged = MacIRSourceSpan(address: 0x7008, byteText: "ff 01 00 71", mnemonic: "cmp", operands: "w14, #0x0")
        XCTAssertEqual(MacIRBuilder.nativeLogicalContinuationRefusal(producer: producer,
            consumer: consumer, sources: [producer, consumer, forged]), "unsupported-neutral-or-unknown")
    }
    private func unchanged340(_ words: [UInt32], file: StaticString = #filePath, line: UInt = #line) {
        let rows = LogicalRemainder340Fixture.decode(words)
        let candidate = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_340_negative", instructions: rows)
        let old = MacIRBuilder(skippingRejectedCFGReconciliation: false,
            explicitCFGEnabled: nil, nativeSignedWordCMPEnabled: false)
            .buildFunction(name: "_340_negative", instructions: rows)
        XCTAssertEqual(candidate.instructions, old.instructions, file: file, line: line)
        XCTAssertEqual(PseudocodePrinter().print(function: candidate).text,
            PseudocodePrinter().print(function: old).text, file: file, line: line)
    }
    func test340NonadjacentProducerPreservesMain() {
        unchanged340([0xea29010c, 0xd503201f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test340InterveningFlagWriterPreservesMain() {
        unchanged340([0xea29010c, 0xf100013f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test340NoUnsignedLoadProofPreservesSignedDestination() {
        unchanged340([0xea09010c, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test340IncomingEdgeSkippingUnsignedLoadsPreservesMain() {
        // Entry branch skips two of three load rows and lands at the producer.
        unchanged340([0x14000004, 0xf9400268, 0xf9400289, 0xf94002aa,
            0xea29010c, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test340XTSTHighNegativeHexMaskIsDefined() throws {
        try LogicalRemainder340Fixture.check("X-TST-high-negative-mask", producer: 0xf261811f,
            consumer: 0x9a9fb7e0, family: "tst", form: "REG", width: 64, suffix: "ge", mnemonic: "cset")
    }
    func test340XTSTLowMaskKeepsMain() throws {
        try LogicalRemainder340Fixture.check("X-TST-low-mask", producer: 0xf240011f,
            consumer: 0x9a9fb7e0, family: "tst", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset", preservation: true)
    }
    func test340XANDSHighMaskRetainsRefusal() throws {
        try LogicalRemainder340Fixture.check("X-ANDS-high-mask", producer: 0xf241010c,
            consumer: 0x9a9fb7e0, family: "ands", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset", preservation: true)
    }
}


extension DecodedRegionalSwitchTests {
    func test340BICSNonzeroDestinationLaterReaderKeepsExistingSignedValue() {
        // No unsigned-load certificate: both the signed producer and its later
        // value reader must stay byte-for-byte on the established native path.
        unchanged340([0xea29010c, 0x9a9fb7e0, 0x710001ff, 0xaa0c03e0, 0xd65f03c0])
    }
    func test340NonUniqueXProducerKeepsBothOperationsAndPrintedLines() throws {
        let rows = LogicalRemainder340Fixture.decode([0xf9400268, 0xf9400289, 0xf94002aa,
            0xea09010c, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0])
        let candidate = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_340_pair", instructions: rows)
        let old = MacIRBuilder(skippingRejectedCFGReconciliation: false,
            explicitCFGEnabled: nil, nativeSignedWordCMPEnabled: false)
            .buildFunction(name: "_340_pair", instructions: rows)
        let p = try XCTUnwrap(candidate.instructions.first { $0.source.address == 0x700c })
        let c = try XCTUnwrap(candidate.instructions.first { $0.source.address == 0x7010 })
        let op = try XCTUnwrap(old.instructions.first { $0.source.address == 0x700c })
        let oc = try XCTUnwrap(old.instructions.first { $0.source.address == 0x7010 })
        XCTAssertNotEqual(p.operation, op.operation)
        let proposal = NativeSignedWordLogicalPair(producerSource: op.source,
            originalProducer: op.operation, replacementProducer: p.operation,
            consumerSource: oc.source, originalConsumer: oc.operation, replacementConsumer: c.operation)
        let ambiguous = [op, op, oc]
        let result = MacIRBuilder.committingNativeLogicalPairs([proposal], to: ambiguous)
        XCTAssertEqual(result, ambiguous)
        let printer = PseudocodePrinter()
        let names = PseudocodeNameContext(function: old)
        XCTAssertEqual(result.map { printer.render(instruction: $0, names: names) },
            ambiguous.map { printer.render(instruction: $0, names: names) })
    }
}


// Item340 v2 D2: subordinate later-use witnesses. Source authored, NOT RUN.
// The actual LSR reader and its exact unsigned operand are observed separately;
// the latter is a pure observation sink, not an edit to the lifted function.
extension DecodedRegionalSwitchTests {
    func test340RepairedWProducerLaterReaderSeesUnsignedBoundaryValue() throws {
        try check340RepairedLaterUnsignedRead(width: 32)
    }

    func test340RepairedXProducerLaterReaderSeesUnsignedBoundaryValue() throws {
        try check340RepairedLaterUnsignedRead(width: 64)
    }

    private func check340RepairedLaterUnsignedRead(width: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let loads: [UInt32] = width == 32
            ? [0xb9400268, 0xb9400289, 0xb94002aa]
            : [0xf9400268, 0xf9400289, 0xf94002aa]
        let producer: UInt32 = width == 32 ? 0x6a29010c : 0xea29010c
        // BICS {W,X}12,{W,X}8,{W,X}9; CSET X0,GE; CMP W15,#0;
        // LSR X16,X12,#1; RET. The exact CMP closes NZCV before the value read.
        let rows = LogicalRemainder340Fixture.decode(loads
            + [producer, 0x9a9fb7e0, 0x710001ff, 0xd341fd90, 0xd65f03c0])
        XCTAssertEqual(rows.count, 8, file: file, line: line)
        let function = MacIRBuilder(ssaEnabled: false)
            .buildFunction(name: "_340_later_unsigned", instructions: rows)
        let legacy = MacIRBuilder(skippingRejectedCFGReconciliation: false,
            explicitCFGEnabled: nil, nativeSignedWordCMPEnabled: false)
            .buildFunction(name: "_340_later_unsigned", instructions: rows)
        let p = try XCTUnwrap(function.instructions.first { $0.source.address == 0x700c },
            file: file, line: line)
        let c = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7010 },
            file: file, line: line)
        let reader = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7018 },
            file: file, line: line)
        let oldP = try XCTUnwrap(legacy.instructions.first { $0.source.address == 0x700c },
            file: file, line: line)
        let oldC = try XCTUnwrap(legacy.instructions.first { $0.source.address == 0x7010 },
            file: file, line: line)
        let oldReader = try XCTUnwrap(legacy.instructions.first { $0.source.address == 0x7018 },
            file: file, line: line)
        XCTAssertFalse(function.ssaEnabled, file: file, line: line)
        XCTAssertEqual(p.source.mnemonic, "bics", file: file, line: line)
        XCTAssertEqual(reader.source.mnemonic, "lsr", file: file, line: line)
        XCTAssertEqual(reader.source.operands, "x16, x12, #1", file: file, line: line)
        guard case let .assign(destination, _) = p.operation,
              case let .register(register, version) = destination,
              case let .binary(_, ">>", unsignedRead, .immediate(1)) = reader.operation else {
            return XCTFail("missing repaired assignment or exact later LSR operation", file: file, line: line)
        }
        let expectedRead: MacIRValue
        if width == 32 {
            expectedRead = .unary(op: "(uint64_t)",
                value: .unary(op: "(uint64_t)",
                    value: .unary(op: "(uint32_t)", value: destination)))
        } else {
            expectedRead = .unary(op: "(uint64_t)", value: destination)
        }
        XCTAssertEqual(unsignedRead, expectedRead,
            "the actual reader must consume the repaired destination as unsigned", file: file, line: line)
        XCTAssertEqual(reader.operation, oldReader.operation,
            "existing later-use normalization must not be replaced or fabricated", file: file, line: line)
        XCTAssertEqual(function.nameBindings, legacy.nameBindings, file: file, line: line)
        let target = MacIRNameBindingTarget.register(name: register, version: version)
        XCTAssertEqual(function.nameBindings.first { $0.target == target }?.type, "int\(width)_t",
            file: file, line: line)
        XCTAssertNotEqual(p.operation, oldP.operation, file: file, line: line)
        XCTAssertNotEqual(c.operation, oldC.operation, file: file, line: line)

        let prefix = width == 32 ? "w" : "x"
        let overrides = [prefix + "8": "source_word", prefix + "9": "other_word",
            prefix + "10": "guard_word", prefix + "12": "logical_result",
            "x0": "condition_result", "x16": "later_value", "x17": "unsigned_input"]
        let printer = PseudocodePrinter()
        let names = PseudocodeNameContext(function: function, registerNameOverrides: overrides)
        let oldNames = PseudocodeNameContext(function: legacy, registerNameOverrides: overrides)
        let producerText = printer.render(instruction: p, names: names)
        let consumerText = printer.render(instruction: c, names: names)
        let readerText = printer.render(instruction: reader, names: names)
        XCTAssertEqual(readerText, printer.render(instruction: oldReader, names: oldNames),
            file: file, line: line)
        XCTAssertNotEqual(producerText, printer.render(instruction: oldP, names: oldNames),
            file: file, line: line)
        XCTAssertNotEqual(consumerText, printer.render(instruction: oldC, names: oldNames),
            file: file, line: line)
        XCTAssertEqual(printer.printedScalarType(of: unsignedRead, names: names), "uint64_t",
            file: file, line: line)
        XCTAssertTrue(readerText.contains("(uint64_t)"), readerText, file: file, line: line)
        if width == 32 {
            XCTAssertTrue(readerText.contains("(uint32_t)"), readerText, file: file, line: line)
        }

        // Copy only the actual pure reader operand to an untagged observation
        // sink. No instruction, name binding or source authority is added to IR.
        let inputObservation = printer.render(operation: .assign(
            destination: .register(name: "x17", version: 0), source: unsignedRead), names: names)
        let signature = "uint64_t later340(uint\(width)_t source_word, uint\(width)_t other_word) {"
        let inputType: OrdinaryC.CType = width == 32 ? .u32 : .u64
        let contract = OrdinaryC.Contract(signature: signature,
            inputs: [.init(name: "source_word", type: inputType, entrySlot: 8),
                .init(name: "other_word", type: inputType, entrySlot: 9)],
            fields: [], calls: [:], exterior: [:], terminalRow: 99,
            terminalPayload: "return unsigned_input;", terminalName: "unsigned_input", returnType: .u64,
            rowsByAddress: [0x700c: 3, 0x7010: 4, 0x7018: 6, 0x7100: 99],
            allowedLabels: [], memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        let program = try OrdinaryC.Program(lines: [
            .init(text: signature, source: nil, envelope: .signature),
            .init(text: "int\(width)_t logical_result;", source: nil, envelope: .body),
            .init(text: "int64_t condition_result;", source: nil, envelope: .body),
            .init(text: "int64_t later_value;", source: nil, envelope: .body),
            .init(text: "uint64_t unsigned_input;", source: nil, envelope: .body),
            .init(text: producerText + ";", source: 0x700c, envelope: .body),
            .init(text: consumerText + ";", source: 0x7010, envelope: .body),
            .init(text: inputObservation + ";", source: nil, envelope: .body),
            .init(text: readerText + ";", source: 0x7018, envelope: .body),
            .init(text: "return unsigned_input;", source: 0x7100, envelope: .body),
            .init(text: "}", source: nil, envelope: .closingBrace)], contract: contract)
        let boundaries: [UInt64] = width == 32
            ? [0x80000000, 0xffffffff, 0, 0x7fffffff]
            : [0x8000000000000000, 0xffffffffffffffff, 0, 0x7fffffffffffffff]
        for bits in boundaries {
            do {
                let result = try OrdinaryC.Machine(program: program, scenario: .init(
                    name: "340-later-\(width)-\(bits)",
                    inputs: ["source_word": .init(bits, inputType), "other_word": .init(0, inputType)],
                    memory: [:], responses: [])).run()
                XCTAssertTrue(result.returned, file: file, line: line)
                XCTAssertEqual(result.terminal?.bits, bits,
                    "later reader must see the complete unsigned architectural value", file: file, line: line)
                let actualReaderWrite = try XCTUnwrap(result.commits.last { $0.name == "later_value" },
                    file: file, line: line)
                XCTAssertEqual(actualReaderWrite.value.bits, bits >> 1,
                    "actual emitted LSR must use logical, not signed arithmetic, shift", file: file, line: line)
                let actualConsumerWrite = try XCTUnwrap(result.commits.last { $0.name == "condition_result" },
                    file: file, line: line)
                let sign: UInt64 = width == 32 ? 0x80000000 : 0x8000000000000000
                XCTAssertEqual(actualConsumerWrite.value.bits, bits & sign == 0 ? 1 : 0,
                    "the repaired signed condition and later unsigned use must both agree", file: file, line: line)
            } catch { XCTFail("later-reader width\(width), bits\(bits): \(error)", file: file, line: line) }
        }
    }
}
