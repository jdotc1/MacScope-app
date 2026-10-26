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

final class NativeScalarConverterAdmissionTests: XCTestCase {
    private func fixture(_ seed: NativeScalarSeed, ssaEnabled: Bool) throws -> NativeScalarFixture {
        let captures = try RegionalSchema2Fixture.load(resource: RegionalSchema2Bindings39A.resourceURL,
            binding: RegionalSchema2Bindings39A.binding)
        let capture = try XCTUnwrap(captures.first {
            $0.function == seed.name && $0.start == NativeScalarContext.hex(seed.start)
        })
        let input = try capture.restoredInput()
        try RegionalSchema2BuiltFixture.requireCompleteInputAuthority(input, capture: capture)
        let printer = PseudocodePrinter(options: .default)
        let original = printer.buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets,
            slotCallContracts: input.slotCallContracts, callerReturnWidth: input.callerReturnWidth,
            callerReturnType: input.callerReturnType, types: input.types,
            ssaEnabled: ssaEnabled, instructions: input.instructions)
        XCTAssertEqual(original.ssaEnabled, ssaEnabled)
        let document = printer.print(function: original, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        return .init(seed: seed, capture: .schema2View(capture, input: input),
            input: input, original: original, document: document)
    }

    private func plans(_ fixture: NativeScalarFixture) throws
        -> (MacIRFunction, CFG, DecodedScalarCFGPlan, DecodedScalarNativeValuePlan, DecodedScalarRegionPlan) {
        let lexical = fixture.original.ssaEnabled ? nil : RegionalLexicalProof(reconciled: fixture.original)
        let function = lexical?.function ?? fixture.original
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let state = try XCTUnwrap(DecodedScalarCFGPlan.prove(function: function, cfg: cfg,
            lexicalProof: lexical, attemptLexical: false))
        let topology = try XCTUnwrap(RegionTree.build(cfg: cfg, instructions: function.instructions, certifiedBy: state))
        let region = try XCTUnwrap(DecodedScalarRegionPlan.prove(cfg: cfg,
            instructions: function.instructions, state: state, control: topology))
        let names = PseudocodeNameContext(function: function, types: fixture.input.types,
            callTargetRenames: fixture.input.nameOverrides,
            registerNameOverrides: fixture.input.registerNameOverrides)
        let reserved = Set(names.argumentNames.values).union(names.localsByOffset.values.map(\.name))
            .union(names.registerNamesByValue.values).union(names.registerNameOverrides.values)
        let values = try XCTUnwrap(DecodedScalarNativeValuePlan.prove(function: function, cfg: cfg,
            certifiedBy: state, renderedName: { PseudocodePrinter(options: .default).valueText(for: $0, names: names) },
            reservedNames: reserved, authoritativeTypes: names.valueTypes, lexicalProof: lexical))
        return (function, cfg, state, values, region)
    }

    func testExtrgbNativeOutputRetainsExactSUBSWriterInBothModes() throws {
        for enabled in [false, true] {
            let fixture = try fixture(.interleavedRGB8, ssaEnabled: enabled)
            XCTAssertEqual(fixture.rows[18].bytes, "ad 05 00 f1")
            XCTAssertEqual(fixture.rows[18].operands, "x13, x13, #1")
            XCTAssertEqual(fixture.rows[19].bytes, "01 ff ff 54")
            XCTAssertEqual(fixture.rows[19].address, 0x38a0)
            let (function, cfg, state, values, region) = try plans(fixture)
            let control = try XCTUnwrap(DecodedScalarNativeControlPlan.prove(function: function,
                cfg: cfg, state: state, topology: region, values: values))
            XCTAssertEqual(control.ownedRows, Set(function.instructions.indices))
            XCTAssertEqual(control.ownedBlocks, Set(cfg.blocks.indices))
            XCTAssertEqual(values.conditionBindings[19]?.writerRow, 18)
            XCTAssertEqual(values.conditionBindings[19]?.definitions, Set([.source(row: 18, slot: 0)]))
            let result = try XCTUnwrap(values.definitionBindings.first { $0.definition == .source(row: 18, slot: 0) })
            XCTAssertEqual(values.branchConditions[19]?.left, result.value)
            XCTAssertEqual(values.branchConditions[19]?.condition, "!=")
            XCTAssertNotNil(fixture.document.regionTree)
            XCTAssertNil(fixture.document.structureFallback)
            XCTAssertFalse(try OrdinaryCOutputAudit.lex(fixture.document.text).contains { $0.text == "goto" })
            let terminal = try XCTUnwrap(fixture.document.lines.lastIndex {
                $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("return ")
            })
            XCTAssertTrue(fixture.document.lines.dropFirst(terminal + 1).allSatisfy {
                $0.text.trimmingCharacters(in: .whitespaces) == "}"
            })
            XCTAssertTrue(fixture.document.lines[terminal].text.contains("unresolved_return_contract"))
        }
    }

    func testNullWidthProofRetainsSevenLoopRefusalInBothModes() throws {
        for enabled in [false, true] {
            let fixture = try fixture(.nullRGB8, ssaEnabled: enabled)
            XCTAssertEqual(fixture.rows[61].bytes, "2a 7d 40 93")
            XCTAssertEqual(fixture.rows[61].mnemonic, "sxtw")
            XCTAssertEqual(fixture.rows[61].operands, "x10, w9")
            let (function, cfg, state, values, region) = try plans(fixture)
            XCTAssertEqual(cfg.loopHeaders.count, 7)
            XCTAssertEqual(fixture.rows[15].bytes, "ed 03 08 aa")
            XCTAssertEqual(fixture.rows[15].operands, "x13, x8")
            let widened = try XCTUnwrap(values.useBindings.first { $0.row == 15 && $0.register.index == 8 })
            XCTAssertEqual(widened.register.width, 64)
            XCTAssertEqual(widened.definition, .source(row: 1, slot: 0))
            let load = try XCTUnwrap(values.definitionBindings.first { $0.definition == .source(row: 1, slot: 0) })
            XCTAssertEqual(load.nativeType, "uint32_t")
            XCTAssertTrue(load.knownZeroHigh32)
            let moves = values.groups[15].compactMap { item -> MacIRInstruction? in
                if case let .instruction(instruction) = item { return instruction }; return nil
            }
            XCTAssertEqual(moves.count, 1)
            guard let move = moves.first, case let .assign(_, movedValue) = move.operation else {
                return XCTFail("W-load to X-register transport must remain a scalar assignment")
            }
            XCTAssertEqual(movedValue, .unary(op: "(uint64_t)", value: load.value))
            let source = try XCTUnwrap(values.useBindings.first { $0.row == 61 && $0.register.index == 9 })
            XCTAssertEqual(source.register.width, 32)
            XCTAssertEqual(source.definition, .source(row: 0, slot: 0))
            let output = try XCTUnwrap(values.definitionBindings.first { $0.definition == .source(row: 61, slot: 0) })
            XCTAssertEqual(output.register.index, 10)
            XCTAssertEqual(output.architecturalWidth, 64)
            let instructions = values.groups[61].compactMap { item -> MacIRInstruction? in
                if case let .instruction(instruction) = item { return instruction }; return nil
            }
            XCTAssertEqual(instructions.count, 1)
            guard let instruction = instructions.first,
                  case let .select(destination, condition, left, right, positive, negative) = instruction.operation else {
                return XCTFail("SXTW must retain its exact source-owned sign transport")
            }
            let low = MacIRValue.unary(op: "(uint32_t)", value: source.value)
            let wide = MacIRValue.unary(op: "(uint64_t)", value: source.value)
            // The source is an unsigned W load; its typed native value already
            // supplies the low32 projection without a redundant cast.
            XCTAssertEqual(destination, output.value)
            XCTAssertEqual(condition, "==")
            XCTAssertEqual(left, .binaryExpression(op: "&", left: source.value,
                right: .unary(op: "(uint32_t)", value: .immediate(0x8000_0000))))
            XCTAssertEqual(right, .immediate(0))
            XCTAssertEqual(positive, wide)
            XCTAssertEqual(negative, .binaryExpression(op: "|", left: wide,
                right: .unary(op: "~", value: .unary(op: "(uint64_t)", value: .immediate(0xffff_ffff)))))
            XCTAssertNotEqual(positive, low)
            XCTAssertNil(DecodedScalarNativeControlPlan.prove(function: function, cfg: cfg,
                state: state, topology: region, values: values))
            ExcludedNullFallback39A.requireRefusal(function: fixture.original, document: fixture.document)
        }
    }

    func testNullExactRefusalTextRejectsCarrierWidthAndTargetMutations() throws {
        for enabled in [false, true] {
            let fixture = try fixture(.nullRGB8, ssaEnabled: enabled)
            let capture = try XCTUnwrap(fixture.capture.schema2_input_authority)
            try ExcludedNullFallback39A.requireCaptured(.init(capture: capture,
                input: fixture.input, original: fixture.original, document: fixture.document))
            let expected = enabled ? ExcludedNullFallback39A.nullConvert3704SSAFlatText
                : ExcludedNullFallback39A.nullConvert3704FlatText
            XCTAssertEqual(fixture.document.text, expected)
            let mutations: [(String, String)] = [
                ("tmp38 = (int32_t)(tmp0);", "tmp38 = (int32_t)(tmp1);"),
                ("tmp38 = (int32_t)(tmp0);", "tmp38 = (int64_t)(tmp0);"),
                ("if (tmp0 == 0x3) goto L_378c;", "if (tmp0 == 0x3) goto L_37f0;"),
                ("    L_378c:", "    loc_378c:")
            ]
            for (original, replacement) in mutations {
                XCTAssertEqual(fixture.document.text.components(separatedBy: original).count - 1, 1)
                let changed = fixture.document.text.replacingOccurrences(of: original, with: replacement)
                XCTAssertNotEqual(changed, expected,
                    "the exact refusal comparison must detect carrier, width, edge and label corruption")
            }
        }
    }

    func testForgedConsumerAndPersistedPhiCannotAcquireNativeAuthority() throws {
        for enabled in [false, true] {
            let fixture = try fixture(.interleavedRGB8, ssaEnabled: enabled)
            let original = fixture.original
            let cfg = CFGBuilder.buildCFG(instructions: original.instructions)
            XCTAssertNotNil(DecodedScalarCFGPlan.prove(function: original, cfg: cfg, attemptLexical: false))
            var forged = original
            guard case let .binary(_, "-", oldOperand, _) = original.instructions[18].operation,
                  case let .conditionalBranch(_, _, _, target) = original.instructions[19].operation else {
                return XCTFail("literal SUBS/branch premise changed")
            }
            forged.instructions[19].operation = .conditionalBranch(condition: "!=", left: oldOperand,
                right: .immediate(0), target: target)
            XCTAssertNotEqual(forged.instructions, original.instructions)
            XCTAssertEqual(forged.instructions.map(\.source), original.instructions.map(\.source))
            XCTAssertNil(DecodedScalarCFGPlan.prove(function: forged, cfg: cfg, attemptLexical: false))
            var changedPhi = original
            if let index = changedPhi.phis.firstIndex(where: { !$0.incoming.isEmpty }) {
                changedPhi.phis[index].incoming[0].value = .immediate(0x1234)
            } else {
                changedPhi.phis.append(MacIRPhi(blockAddress: 0x3860,
                    destination: .register(name: "x1", version: 99), bitWidth: 64,
                    incoming: [.init(predecessorAddress: 0x385c, value: .immediate(0x1234))], cell: 1))
            }
            XCTAssertEqual(changedPhi.instructions, original.instructions)
            XCTAssertNotEqual(changedPhi.phis, original.phis)
            XCTAssertNil(DecodedScalarCFGPlan.prove(function: changedPhi, cfg: cfg, attemptLexical: false))
        }
    }
}
