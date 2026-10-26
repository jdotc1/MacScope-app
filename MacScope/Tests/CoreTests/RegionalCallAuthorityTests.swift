import Foundation
import XCTest
@testable import MacScope

/// call/terminal-contract authority regressions use the complete independently retained decoded
/// capture. These are refusal tests, not a claim that machine-callee behavior or
/// the legacy inferred return is correct. The legacy output is the authority
/// boundary: an unused printed call result cannot acquire a new physical use.
final class RegionalCallAuthorityTests: XCTestCase {
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


    /// An existing printed branch consumer does not grant terminal-return
    /// authority. This complete real capture already prints and tests x0_8,
    /// but its unchanged return names the independent constant result w0_1.
    func testExistingBranchResultCannotAcquireUnrelatedTerminalRoleControls() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalTerminalFixture.make(.finishDecompress)
            let function = fixture.function, cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            let expectedFixture = try SSAPropertyAssertions.enabled ? withLegacyLifter {
                try RegionalTerminalFixture.make(.finishDecompress, types: fixture.types)
            } : fixture
            var alpha = SSAAlphaEquivalence(expected: expectedFixture.function, actual: function)
            if SSAPropertyAssertions.enabled {
                RenderProperties.assertSameStatements(expectedFixture.legacy, baseline: fixture.seed.baselineText,
                    rows: [43, 44, 45, 52, 53, 54], allowing: [.labelSpelling, .branchSpelling])
                assertAlphaEquivalentStatements(fixture.legacy, expectedFixture.legacy,
                    rows: [43, 44, 45, 52, 53, 54], alpha: &alpha)
            } else {
                RenderProperties.assertSameStatements(fixture.legacy, baseline: fixture.seed.baselineText,
                    rows: [43, 44, 45, 52, 53, 54], allowing: [.labelSpelling, .branchSpelling])
            }
            guard case let .call(frame, result) = function.instructions[43].operation,
                  case let .conditionalBranch(condition, left, right, target) = function.instructions[44].operation else {
                return XCTFail("complete capture lost its original callback/branch")
            }
            XCTAssertNil(frame.knownSignature)
            XCTAssertEqual(result, .register(name: "x0", version: 8))
            XCTAssertEqual(condition, "!=")
            XCTAssertEqual(right, .immediate(0))
            XCTAssertEqual(target, .immediate(0x21814))
            var branchAtoms: Set<MacIRValue> = []
            RegionalBoundaryPlan.collectAtoms(left, into: &branchAtoms)
            XCTAssertTrue(branchAtoms.contains(try XCTUnwrap(result)),
                          "the original IR already consumes this opaque result")
            XCTAssertEqual(fixture.rows[44].mnemonic, "cbnz")
            XCTAssertEqual(fixture.rows[44].operands, "w0, 0x0000000000021814")
            let mentions = fixture.seed.baselineText.split(separator: "\n").filter {
                $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains("x0_8")
            }
            XCTAssertEqual(mentions.map { $0.trimmingCharacters(in: .whitespaces) }, [
                "x0_8 = (*tmp17)(x0_7); // call",
                "if ((uint32_t)(x0_8) != 0x0) goto 0x21814; // conditional branch"
            ], "this is role expansion, not a formerly-unused-result control")
            if SSAPropertyAssertions.enabled {
                alpha.assertEquivalent([String(describing: function.instructions[52].operation)],
                    [String(describing: MacIROperation.assign(
                        destination: .register(name: "w0", version: 1), source: .immediate(1)))])
            } else {
                XCTAssertEqual(function.instructions[52].operation,
                               .assign(destination: .register(name: "w0", version: 1), source: .immediate(1)))
            }

            // Symbolic decoded-path witness: any callback result with low32 == 0
            // follows CBNZ's false edge and B to the suffix, bypassing W0 = 1.
            // No fabricated call semantics or altered terminal IR is required.
            let path = [43, 44, 45, 53, 54, 55]
            try assertCapturedPath(path, function: function, cfg: cfg)
            XCTAssertEqual(function.instructions[45].operation,
                           .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x21850)]))
            XCTAssertEqual(fixture.rows[53].operands, "x29, x30, [sp, #0x10]")
            XCTAssertEqual(fixture.rows[54].operands, "x20, x19, [sp], #0x20")
            XCTAssertFalse(path.contains(52), "the original terminal producer does not execute on this path")

            XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg),
                         "C4_TERMINAL_ROLE_REQUIRED: an existing branch use cannot authorize a new return role")
            XCTAssertNil(fixture.document.regionTree,
                         "C4_TERMINAL_ROLE_REQUIRED: refuse the new callback-result terminal export")
            RenderProperties.assertSameStatements(fixture.document, fixture.legacy)
            RenderProperties.assertSourceCoverage(fixture.document, rows: fixture.rows, required: [43, 44, 52, 53, 55])
            let consumers = try function.instructions.indices.filter { index in
                guard index != 43 else { return false }
                let values = try XCTUnwrap(RegionalBoundaryPlan.values(function.instructions[index].operation))
                var atoms: Set<MacIRValue> = []
                values.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &atoms) }
                return atoms.contains(try XCTUnwrap(result))
            }
            XCTAssertEqual(consumers, [44], "row 43 call result has exactly the captured branch consumer")
            XCTAssertEqual(fixture.document.lines, fixture.legacy.lines)
            for payload in fixture.callPayloads { XCTAssertEqual(payload.after, [payload.baseline]) }
        }
    }

    func testExistingBranchResultCannotAcquireUnrelatedTerminalRole() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(true) {
            XCTAssertTrue(SSAPropertyAssertions.enabled)
            let fixture = try RegionalTerminalFixture.make(.finishDecompress)
            let function = fixture.function, cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertTrue(function.ssaEnabled)
            XCTAssertEqual(function.returnType, "int32_t")
            // Both captured paths meet at the cell-0 phi. The return uses its
            // 32-bit view; row 52's constant is only one incoming producer.
            if SSAPropertyAssertions.enabled {
                if let phi = SSAPropertyAssertions.phi(function, block: 0x21850, cell: 0, width: 64,
                    incoming: [(predecessor: fixture.rows[45].address, producer: fixture.rows[43].address),
                               (predecessor: fixture.rows[52].address, producer: fixture.rows[52].address)]) {
                    SSAPropertyAssertions.assertView(function.returnValue, of: phi, width: 32)
                    guard case let .returnValue(returned) = function.instructions[55].operation else {
                        return XCTFail("captured terminal must remain a return")
                    }
                    SSAPropertyAssertions.assertView(returned, of: phi, width: 32)
                }
            } else {
                RenderProperties.assertSingleReturnProducer(function, row: 52, alias: .register(name: "w0", version: 1))
                RenderProperties.assertSameStatements(fixture.legacy, baseline: fixture.seed.baselineText,
                    rows: [55], allowing: [.labelSpelling, .branchSpelling])
                XCTAssertEqual(function.instructions[55].operation, .returnValue(.register(name: "w0", version: 1)))
            }
            RenderProperties.assertNoMarkers(fixture.document, rows: [55])
            let boundary = try XCTUnwrap(RegionalBoundaryPlan.prove(function: function, cfg: cfg))
            XCTAssertEqual(boundary.terminal?.exportRow, 53)
            if SSAPropertyAssertions.enabled {
                XCTAssertEqual(boundary.terminal?.alias.value, function.returnValue)
            } else {
                XCTAssertEqual(boundary.terminal?.alias.value, .register(name: "w0", version: 1))
            }
        }
    }

    /// Complete small real positive control: both return paths replace X0 with
    /// W21's own zero/one constants before the suffix. No opaque result is
    /// promoted to a return, so a blanket nonvoid refusal is not acceptable.
    func testConstantW21TerminalRetainsExactSkipVariableAdmission() throws {
        let fixture = try RegionalTerminalFixture.make(.skipVariable)
        let function = fixture.function, cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let expectedFunction = function.ssaEnabled
            ? SSAAlphaEquivalence.legacyFunction(from: try XCTUnwrap(fixture.capturedInput)) : function
        var alpha = SSAAlphaEquivalence(expected: expectedFunction, actual: function)
        if function.ssaEnabled {
            let input = try XCTUnwrap(fixture.capturedInput)
            var options = DecompilerOptions.default
            options.structureControlFlow = false
            let expected = PseudocodePrinter(options: options).print(function: expectedFunction,
                types: input.types, nameOverrides: input.nameOverrides,
                registerNameOverrides: input.registerNameOverrides,
                stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
            RenderProperties.assertSameStatements(expected, baseline: fixture.seed.baselineText,
                rows: fixture.seed.protectedRows, allowing: [.labelSpelling, .branchSpelling])
            assertAlphaEquivalentStatements(fixture.legacy, expected,
                rows: fixture.seed.protectedRows.filter { $0 != 51 }, alpha: &alpha)
            if let phi = SSAPropertyAssertions.phi(function, block: 0x334e4, cell: 21, width: 32,
                incoming: [(predecessor: 0x334c4, producer: 0x334ac),
                           (predecessor: 0x334dc, producer: 0x334ac),
                           (predecessor: 0x334e0, producer: 0x334e0)]) {
                guard case let .assign(destination, source) = function.instructions[51].operation else {
                    return XCTFail("terminal MOV must retain its assignment")
                }
                XCTAssertEqual(destination, .register(name: "x0", version: 9))
                SSAPropertyAssertions.assertView(source, of: phi, width: 64)
                guard case let .register("w21", version) = phi.destination else {
                    return XCTFail("width-32 cell-21 phi must retain its W view")
                }
                XCTAssertEqual(fixture.legacy.lines(sourcedAt: fixture.rows[51].address).map {
                    $0.text.trimmingCharacters(in: .whitespaces)
                }, ["x0_9 = (uint64_t)((uint32_t)(w21_\(version)));"])
            }
        } else {
            RenderProperties.assertSameStatements(fixture.legacy, baseline: fixture.seed.baselineText,
                rows: fixture.seed.protectedRows, allowing: [.labelSpelling, .branchSpelling])
        }
        XCTAssertEqual(function.returnType, "int64_t")
        XCTAssertEqual(function.returnValue, .register(name: "x0", version: 9))
        assertDeterministic(try XCTUnwrap(fixture.capturedInput))
        XCTAssertEqual(function.instructions[37].operation,
                       .assign(destination: .register(name: "w21", version: 1), source: .immediate(1)))
        XCTAssertEqual(function.instructions[50].operation,
                       .assign(destination: .register(name: "w21", version: 2), source: .immediate(0)))
        XCTAssertEqual(fixture.rows[51].mnemonic, "mov")
        XCTAssertEqual(fixture.rows[51].operands, "x0, x21")
        XCTAssertEqual(function.instructions[57].operation, .returnValue(.register(name: "x0", version: 9)))
        // The zero path and both one paths all pass through the real terminal
        // MOV. The one paths contain real calls, but retain W21 across them.
        try assertCapturedPath([12, 13, 50, 51, 52, 53, 54, 55, 56, 57], function: function, cfg: cfg)
        try assertCapturedPath(Array(37...43) + Array(51...57), function: function, cfg: cfg)
        try assertCapturedPath(Array(37...49) + Array(51...57), function: function, cfg: cfg)

        let state = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg),
                                 "NONVOID_POSITIVE_REQUIRED: constant W21 terminal must remain admissible")
        XCTAssertEqual(state.boundaries.terminal?.exportRow, 52)
        if case .failure = RegionalPhysicalStatePlan.proveClassified(function: function, cfg: cfg) {
            XCTFail("A41: positive class proves as .success")
        }
        XCTAssertEqual(state.boundaries.terminal?.alias.value, .register(name: "x0", version: 9))
        XCTAssertNotNil(fixture.document.regionTree,
                        "NONVOID_POSITIVE_REQUIRED: do not replace structural authority checks with a nonvoid ban")
        XCTAssertGreaterThan(RenderProperties.shape(fixture.legacy).goto + RenderProperties.shape(fixture.legacy).label, 0)
        XCTAssertLessThan(RenderProperties.shape(fixture.document).goto, RenderProperties.shape(fixture.legacy).goto)
        if function.ssaEnabled {
            let frozen = try OrdinaryC.contract(rows: fixture.rows, function: expectedFunction,
                baseline: fixture.seed.baselineText, callRows: fixture.seed.callRows)
            let translated = try frozen.alphaEquivalent(to: fixture.document, using: &alpha)
            try RegionalCallRowOwnership.require(document: fixture.document, rows: fixture.rows,
                function: function, baseline: fixture.seed.baselineText, callRows: fixture.seed.callRows,
                preparedContract: translated)
        } else {
            try RegionalCallRowOwnership.require(document: fixture.document, rows: fixture.rows,
                function: function, baseline: fixture.seed.baselineText, callRows: fixture.seed.callRows)
        }
        XCTAssertEqual(fixture.document.parameters, fixture.legacy.parameters)
        XCTAssertEqual(fixture.document.returnType, fixture.legacy.returnType)
        XCTAssertEqual(fixture.document.nameBindings, fixture.legacy.nameBindings)
        XCTAssertEqual(fixture.document.callTargets, fixture.legacy.callTargets)
        XCTAssertEqual(fixture.document.callSignatures, fixture.legacy.callSignatures)
        XCTAssertEqual(fixture.document.localVariables, fixture.legacy.localVariables)
        XCTAssertEqual(fixture.document.stackFrameSize, fixture.legacy.stackFrameSize)
        for row in Array(0..<fixture.seed.prefixEnd) + Array(fixture.seed.suffixStart..<fixture.seed.rowCount) {
            let address = fixture.rows[row].address
            let before = fixture.legacy.lines(sourcedAt: address).map { $0.text.trimmingCharacters(in: .whitespaces) }
            let after = fixture.document.lines(sourcedAt: address).map { $0.text.trimmingCharacters(in: .whitespaces) }
            for payload in before { XCTAssertEqual(after.filter { $0 == payload }.count, 1) }
        }
        XCTAssertEqual(fixture.document.lines(sourcedAt: fixture.rows[57].address).map {
            $0.text.trimmingCharacters(in: .whitespaces)
        }, ["return x0_9; // return"])
        for payload in fixture.callPayloads {
            if function.ssaEnabled { alpha.assertEquivalent(payload.after, [payload.baseline]) }
            else { XCTAssertEqual(payload.after, [payload.baseline]) }
        }
    }

    func testCapturedResultReadStopsAtRedefinition() throws {
        let fixture = try RegionalCallFixture.make(.jinit)
        let callRow = 192, beforeRead = 193
        XCTAssertEqual(fixture.rows[callRow].mnemonic, "blr")
        XCTAssertEqual(fixture.rows[beforeRead].operands, "x12, x24")
        XCTAssertEqual(fixture.rows[194].operands, "x0, [x12, x22, lsl #3]")
        XCTAssertTrue(RegionalCallOracle.Program.capturedResultIsRead(rows: fixture.rows, afterCall: callRow))
        let original = try OrdinaryC.contract(rows: fixture.rows, function: fixture.function,
            baseline: fixture.seed.baselineText, callRows: fixture.seed.callRows)
        let result = try XCTUnwrap(original.calls[callRow]?.resultName)
        XCTAssertEqual(try OrdinaryC.baselineAuthorityIdentifierCounts(fixture.seed.baselineText)[result], 1,
                       "this live result needs captured observation, not a lexical alias")
        // Either width redefines the same physical result before its first read.
        for highByte: UInt8 in [0xaa, 0x2a] {
            let replacement = try XCTUnwrap(ARM64Decoder().decode(
                Data([0xe0, 0x03, 0x1f, highByte]), baseAddress: fixture.rows[beforeRead].address).first)
            XCTAssertEqual(replacement.mnemonic, "mov")
            XCTAssertEqual(replacement.operands, highByte == 0xaa ? "x0, xzr" : "w0, wzr")
            var rows = fixture.rows
            rows[beforeRead] = InstructionRow(address: replacement.address, bytes: replacement.byteText,
                mnemonic: replacement.mnemonic, operands: replacement.operands, hasBreakpoint: false,
                comment: replacement.comment, structuredOperands: replacement.structuredOperands)
            XCTAssertEqual(rows.indices.filter { rows[$0] != fixture.rows[$0] }, [beforeRead])
            XCTAssertFalse(RegionalCallOracle.Program.capturedResultIsRead(rows: rows, afterCall: callRow))
            XCTAssertThrowsError(try OrdinaryC.contract(rows: rows, function: fixture.function,
                baseline: fixture.seed.baselineText, callRows: fixture.seed.callRows)) { error in
                guard case let OrdinaryC.Failure.invalidContract(message) = error else {
                    return XCTFail("wrong refusal: \(error)")
                }
                XCTAssertEqual(message, "frozen baseline result authority differs at 192")
            }
        }
    }

    func testJoinedSelectRefusesOnePredecessorCompareWidth() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalCallFixture.make(.jinit)
            let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
            let certificate = try XCTUnwrap(RegionalPhysicalStatePlan.joinedObservableUses(
                function: fixture.function, cfg: cfg))
            XCTAssertEqual(certificate.selectWriters[109], [20: 104, 36: 161])
            XCTAssertEqual(Set(try XCTUnwrap(certificate.storeDefinitions[194]).keys), Set([17, 22, 43]))
            let writer = 161
            XCTAssertEqual(fixture.rows[writer].mnemonic, "cmp")
            XCTAssertEqual(fixture.rows[writer].operands, "w0, #0")
            var bytes = try fixture.rows[writer].bytes.split(separator: " ").map {
                try XCTUnwrap(UInt8($0, radix: 16))
            }
            XCTAssertEqual(bytes.count, 4)
            guard bytes.count == 4 else { return XCTFail("one complete CMP required") }
            bytes[3] |= 0x80
            let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: fixture.rows[writer].address)
            XCTAssertEqual(decoded.count, 1)
            let replacement = try XCTUnwrap(decoded.first)
            XCTAssertEqual(replacement.mnemonic, "cmp")
            XCTAssertEqual(replacement.operands, "x0, #0")
            var input = try XCTUnwrap(fixture.capturedInput)
            input.instructions[writer] = InstructionRow(address: replacement.address,
                bytes: replacement.byteText, mnemonic: replacement.mnemonic,
                operands: replacement.operands, hasBreakpoint: false,
                comment: replacement.comment, structuredOperands: replacement.structuredOperands)
            XCTAssertEqual(input.instructions.indices.filter { input.instructions[$0] != fixture.rows[$0] }, [writer])
            let function = PseudocodePrinter(options: .default).buildFunction(
                functionName: input.functionName, startAddress: input.startAddress,
                jumpTables: input.jumpTables, objcSelectors: input.objcSelectors,
                constantStrings: input.constantStrings, signatureOverrides: input.signatureOverrides,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                directCallVoidResultTargets: input.directCallVoidResultTargets,
                slotCallContracts: input.slotCallContracts, callerReturnWidth: input.callerReturnWidth,
                callerReturnType: input.callerReturnType, types: input.types, instructions: input.instructions)
            let changedCFG = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertEqual(changedCFG.blocks, cfg.blocks)
            assertDeterministic(input)
            let changed = try XCTUnwrap(RegionalPhysicalStatePlan.joinedObservableUses(
                function: function, cfg: changedCFG), "the independent store certificate remains available")
            XCTAssertNil(changed.selectWriters[109], "one incoming CMP of a different width invalidates the joined select")
            XCTAssertNotNil(changed.storeDefinitions[194])
            XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: changedCFG))
        }
    }

    func testJoinedStoreRefusesOneLoopCarriedAddressWriterWidth() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalCallFixture.make(.jinit)
            let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
            let physical = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: fixture.function, cfg: cfg))
            let ordinary = try XCTUnwrap(RegionalOrdinaryValuePlan.prove(
                function: fixture.function, cfg: cfg, certifiedBy: physical))
            let indexUse = try XCTUnwrap(ordinary.useBindings.first { $0.row == 194 && $0.register.index == 22 })
            XCTAssertEqual(indexUse.register.width, 64)
            XCTAssertEqual(indexUse.definition, .join(block: 15, register: 22),
                "the unmodified address must retain its loop-carried phi identity")
            let writer = 196
            XCTAssertEqual(fixture.rows[writer].mnemonic, "add")
            XCTAssertEqual(fixture.rows[writer].operands, "x22, x22, #1")
            var bytes = try fixture.rows[writer].bytes.split(separator: " ").map {
                try XCTUnwrap(UInt8($0, radix: 16))
            }
            XCTAssertEqual(bytes.count, 4)
            guard bytes.count == 4 else { return XCTFail("one complete ADD required") }
            bytes[3] &= 0x7f
            try assertJoinedStoreMutationDeclines(fixture, row: writer, bytes: bytes,
                mnemonic: "add", operands: "w22, w22, #1")
        }
    }

    func testJoinedStoreRefusesClobberedCallResult() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalCallFixture.make(.jinit)
            XCTAssertEqual(fixture.rows[192].mnemonic, "blr")
            XCTAssertEqual(fixture.rows[192].operands, "x28")
            XCTAssertEqual(fixture.rows[193].mnemonic, "mov")
            XCTAssertEqual(fixture.rows[193].operands, "x12, x24")
            // This incoming edge kills the call's X0 result while still defining
            // X12 at full width, so address initialization cannot explain refusal.
            try assertJoinedStoreMutationDeclines(fixture, row: 193,
                bytes: [0x00, 0x33, 0x40, 0xa9], mnemonic: "ldp", operands: "x0, x12, [x24]")
        }
    }

    /// The intended ON companion must not inherit the host's default mode.
    /// Lexical overrides keep the existing OFF controls independent.


    private func withLegacyLifter<T>(_ body: () throws -> T) rethrows -> T {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            return try body()
        }
    }

    private func assertAlphaEquivalentStatements(_ actual: PseudocodeDocument,
        _ expected: PseudocodeDocument, rows: Set<Int>, alpha: inout SSAAlphaEquivalence,
        file: StaticString = #filePath, line: UInt = #line) {
        let allowing: Set<RenderProperties.Relaxation> = [.labelSpelling, .branchSpelling]
        let actualStatements = RenderProperties.normalize(actual, rows: nil, allowing: allowing)
            .filter { rows.contains($0.sourceRow ?? -1) }
        let expectedStatements = RenderProperties.normalize(expected, rows: nil, allowing: allowing)
            .filter { rows.contains($0.sourceRow ?? -1) }
        XCTAssertEqual(actualStatements.map(\.sourceRow), expectedStatements.map(\.sourceRow),
            "protected statement source rows stay exact", file: file, line: line)
        XCTAssertEqual(actualStatements.map(\.kind), expectedStatements.map(\.kind),
            "protected statement kinds stay exact", file: file, line: line)
        alpha.assertEquivalent(actualStatements.map(\.text), expectedStatements.map(\.text),
            file: file, line: line)
    }

    /// These certificates consume the legacy reconciliation markers.


    private func assertJoinedStoreMutationDeclines(_ fixture: RegionalCallFixture,
        row: Int, bytes: [UInt8], mnemonic: String, operands: String,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
        let certificate = try XCTUnwrap(RegionalPhysicalStatePlan.joinedObservableUses(
            function: fixture.function, cfg: cfg), file: file, line: line)
        XCTAssertEqual(certificate.selectWriters[109], [20: 104, 36: 161], file: file, line: line)
        XCTAssertEqual(Set(try XCTUnwrap(certificate.storeDefinitions[194], file: file, line: line).keys),
            Set([17, 22, 43]), file: file, line: line)
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: fixture.rows[row].address)
        XCTAssertEqual(decoded.count, 1, file: file, line: line)
        let replacement = try XCTUnwrap(decoded.first, file: file, line: line)
        XCTAssertEqual(replacement.mnemonic, mnemonic, file: file, line: line)
        XCTAssertEqual(replacement.operands, operands, file: file, line: line)
        var input = try XCTUnwrap(fixture.capturedInput, file: file, line: line)
        input.instructions[row] = InstructionRow(address: replacement.address,
            bytes: replacement.byteText, mnemonic: replacement.mnemonic,
            operands: replacement.operands, hasBreakpoint: false,
            comment: replacement.comment, structuredOperands: replacement.structuredOperands)
        XCTAssertEqual(input.instructions.indices.filter { input.instructions[$0] != fixture.rows[$0] },
            [row], "one coherently decoded instruction changes", file: file, line: line)
        let printer = PseudocodePrinter(options: .default)
        let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            jumpTables: input.jumpTables, objcSelectors: input.objcSelectors,
            constantStrings: input.constantStrings, signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets,
            slotCallContracts: input.slotCallContracts, callerReturnWidth: input.callerReturnWidth,
            callerReturnType: input.callerReturnType, types: input.types, instructions: input.instructions)
        let changedCFG = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertEqual(changedCFG.blocks, cfg.blocks, file: file, line: line)
        assertDeterministic(input, file: file, line: line)
        let changed = try XCTUnwrap(RegionalPhysicalStatePlan.joinedObservableUses(
            function: function, cfg: changedCFG), "the independent select certificate remains available",
            file: file, line: line)
        XCTAssertEqual(changed.selectWriters[109], [20: 104, 36: 161], file: file, line: line)
        XCTAssertNil(changed.storeDefinitions[194], "every incoming stored-value and address role must be proved",
            file: file, line: line)
        XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: changedCFG), file: file, line: line)
        var legacyOptions = DecompilerOptions.default
        legacyOptions.structureControlFlow = false
        let legacy = PseudocodePrinter(options: legacyOptions).print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        let actual = printer.print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        XCTAssertNil(actual.regionTree, file: file, line: line)
        XCTAssertEqual(actual.text, legacy.text, "decline preserves byte-identical fallback", file: file, line: line)
        XCTAssertEqual(actual.lines, legacy.lines, file: file, line: line)
    }

    /// Check an explicit source-row path against the complete captured CFG.
    /// Conditional edge feasibility is stated and checked at the selector site;
    /// this helper neither derives facts from pseudocode nor pretends to execute.
    private func assertCapturedPath(_ rows: [Int], function: MacIRFunction, cfg: CFG,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        for (from, to) in zip(rows, rows.dropFirst()) {
            let fromBlock = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(from) }, file: file, line: line)
            let toBlock = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(to) }, file: file, line: line)
            if fromBlock.index == toBlock.index {
                XCTAssertEqual(to, from + 1, "contiguous captured block path", file: file, line: line)
            } else {
                XCTAssertEqual(from, fromBlock.endIndex - 1, file: file, line: line)
                XCTAssertEqual(to, toBlock.startIndex, file: file, line: line)
                XCTAssertTrue(fromBlock.successors.contains(toBlock.index), "captured CFG edge \(from) -> \(to)", file: file, line: line)
            }
            XCTAssertEqual(function.instructions[from].source.address, function.startAddress + UInt64(from * 4), file: file, line: line)
        }
    }

    /// red_kind: behavioral. Frozen regional-multicall-v1 admits this exact
    /// capture and exports either unused error-callback result through X0.
    /// This selector must fail against that unchanged product before repair.
    func testJ16UnusedOpaqueResultsCannotAcquireTerminalExportControls() throws {
        let fixture = try RegionalCallFixture.make(.j16init)
        let function = fixture.function
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let expectedFixture = try SSAPropertyAssertions.enabled ? withLegacyLifter {
            try RegionalCallFixture.make(.j16init, types: fixture.types)
        } : fixture
        var alpha = SSAAlphaEquivalence(expected: expectedFixture.function, actual: function)
        if SSAPropertyAssertions.enabled {
            RenderProperties.assertSameStatements(expectedFixture.legacy, baseline: fixture.seed.baselineText,
                rows: fixture.seed.protectedRows.subtracting([fixture.seed.returnRow]), allowing: [.labelSpelling, .branchSpelling])
            assertAlphaEquivalentStatements(fixture.legacy, expectedFixture.legacy,
                rows: fixture.seed.protectedRows.subtracting([fixture.seed.returnRow]), alpha: &alpha)
        } else {
            RenderProperties.assertSameStatements(fixture.legacy, baseline: fixture.seed.baselineText,
                rows: fixture.seed.protectedRows.subtracting([fixture.seed.returnRow]), allowing: [.labelSpelling, .branchSpelling])
        }

        for (row, version) in [(21, 2), (52, 6)] {
            guard case let .call(frame, result) = function.instructions[row].operation else {
                return XCTFail("complete captured error callback is missing at row \(row)")
            }
            XCTAssertNil(frame.knownSignature, "unknown callbacks may return")
            XCTAssertEqual(result, .register(name: "x0", version: version))
            let value = try XCTUnwrap(result)
            // This is stronger than a substring test: no other original IR
            // operation mentions the result, even as a destination or sidecar
            // carrier. The fixture retains the independently decoded input.
            for index in function.instructions.indices where index != row {
                let values = try XCTUnwrap(RegionalBoundaryPlan.values(function.instructions[index].operation))
                var atoms: Set<MacIRValue> = []
                values.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &atoms) }
                XCTAssertFalse(atoms.contains(value), "formerly unused result at row \(row), other row \(index)")
            }
            let token = "x0_\(version)"
            let mentions = fixture.seed.baselineText.split(separator: "\n").filter { line in
                line.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains(Substring(token))
            }
            XCTAssertEqual(mentions.count, 1, "the original result is printed only at its call")
            XCTAssertTrue(mentions.first?.hasSuffix("// call") == true)
        }

        XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg),
                     "C4_RESULT_AUTHORITY_REQUIRED: refuse a new terminal consumer of an unused opaque result")
        XCTAssertNil(fixture.document.regionTree,
                     "C4_RESULT_AUTHORITY_REQUIRED: unsound capture must not receive regional admission")
        RenderProperties.assertSameStatements(fixture.document, fixture.legacy)
        XCTAssertEqual(fixture.document.lines, fixture.legacy.lines,
                       "transactional refusal leaves no physical-state declarations, aliases or source/token changes")
        XCTAssertFalse(fixture.document.lines.contains { $0.kind == .declaration && $0.text.contains("rgn_regional_") })
        for payload in fixture.callPayloads {
            if SSAPropertyAssertions.enabled {
                alpha.assertEquivalent(payload.after, [payload.baseline])
            } else {
                XCTAssertEqual(payload.after, [payload.baseline], "the original call payload remains unchanged")
            }
        }
    }

    func testJ16UnusedOpaqueResultsCannotAcquireTerminalExport() throws {
        let fixture = try RegionalCallFixture.make(.j16init)
        let function = fixture.function
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        if SSAPropertyAssertions.enabled {
            XCTAssertTrue(["int32_t", "int64_t"].contains(function.returnType),
                "boundary return-type precondition: actual \(function.returnType), expected int32_t or int64_t")
            let info = try XCTUnwrap(function.ssaInfo)
            let graph = try XCTUnwrap(function.cfg)
            let four: Set<SSAPropertyAssertions.CellZeroOrigin> = [
                .entryX0, .callResult(0x3c08c), .callResult(0x3c0c4), .callResult(0x3c108)
            ]
            let eight = four.union([
                .instruction(0x3c198), .instruction(0x3c1f0),
                .callResult(0x3c258), .callResult(0x3c2b4)
            ])
            let terminal = try XCTUnwrap(SSAPropertyAssertions.phi(function,
                block: 0x3c30c, cell: 0, width: 64,
                incoming: [(0x3c130, 0x3c10c), (0x3c278, 0x3c264)]))
            _ = SSAPropertyAssertions.phi(function, block: 0x3c158, cell: 0, width: 64,
                incoming: [(0x3c154, 0x3c10c), (0x3c274, 0x3c264)])
            _ = SSAPropertyAssertions.phi(function, block: 0x3c260, cell: 0, width: 64,
                incoming: [(0x3c1a0, 0x3c198), (0x3c1f4, 0x3c1f0), (0x3c25c, 0x3c258)])
            for (blockAddress, predecessors) in [
                (UInt64(0x3c30c), [UInt64(0x3c130), 0x3c278]),
                (UInt64(0x3c158), [UInt64(0x3c154), 0x3c274])
            ] {
                let block = try XCTUnwrap(graph.blocks.first { $0.startAddress == blockAddress })
                let phi = try XCTUnwrap(info.plan.phis.first { $0.block == block.index && $0.cell == 0 })
                XCTAssertEqual(phi.incoming.map(\.machineAddress), predecessors.map { Optional($0) })
                for (slot, expected) in zip(phi.incoming, [four, eight]) {
                    XCTAssertEqual(SSAPropertyAssertions.cellZeroOrigins(slot.definition, info: info), expected)
                }
            }
            let returnRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x3c324))
            let reaching = try XCTUnwrap(info.plan.rowReadBindings[returnRow][0])
            XCTAssertEqual(SSAPropertyAssertions.cellZeroOrigins(reaching, info: info), eight)
            SSAPropertyAssertions.assertView(info.values[info.plan.canonicalID(reaching)], of: terminal, width: 64)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
            guard case let .returnValue(returned) = function.instructions[returnRow].operation else {
                return XCTFail("captured terminal must remain a return")
            }
            XCTAssertEqual(returned, function.returnValue)
            XCTAssertNil(RegionalBoundaryPlan.prove(function: function, cfg: cfg))
        } else {
            // Complete return-producer evidence is required; opaque
            // callback X0 dataflow alone cannot authorize a function result.
            // Keep the exact historical statement check, correcting only its
            // now-unsound terminal expectation rather than omitting that row.
            RenderProperties.assertSameStatements(fixture.legacy, baseline: fixture.seed.baselineText,
                rows: [fixture.seed.returnRow],
                expectedTextByRow: [fixture.seed.returnRow: "return unresolved_return_contract; // return"],
                allowing: [.labelSpelling, .branchSpelling])
            XCTAssertTrue(["int32_t", "int64_t"].contains(function.returnType),
                "unresolved result authority does not establish void")
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
            XCTAssertEqual(function.instructions[fixture.seed.returnRow].operation,
                           .returnValue(.unknown("unresolved_return_contract")))
            XCTAssertEqual(fixture.legacy.lines(sourcedAt: fixture.rows[fixture.seed.returnRow].address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, ["return unresolved_return_contract; // return"])
            XCTAssertNil(RegionalBoundaryPlan.prove(function: function, cfg: cfg))
        }

        // Both independent returning paths retain current X0 until the original
        // suffix, with no intervening call or scalar use. No nonreturning error
        // callback assumption can justify granting these results authority.
        // Observation is explicit in either mode and never treats the marker
        // as a numeric value. The same complete source witness and scenarios
        // below still establish the architectural X0 value at RET.
        XCTAssertThrowsError(try RegionalCallOracle.Program(rows: fixture.rows, function: function))
        let source = try RegionalCallOracle.Program(rows: fixture.rows, function: function,
            observePhysicalX0WithoutReturnAuthority: true)
        for (row, invalidPrecision, preliminaryError) in [(21, true, false), (52, false, true)] {
            let scenario = try RegionalCallOracle.UpsamplerScenarios.make(seed: .j16init,
                name: "C4-unused-result-terminal-\(row)", paths: [],
                invalidPrecision: invalidPrecision, preliminaryError: preliminaryError)
            let result = try RegionalCallOracle.Machine(program: source, scenario: scenario).run()
            XCTAssertTrue(result.returned)
            XCTAssertEqual(result.calls.map(\.row), [row])
            XCTAssertEqual(result.rowVisits[181], 1)
            XCTAssertEqual(result.returnBits, result.calls.first?.result,
                           "physical terminal export would expose this formerly-unused result")
        }
    }

    func testPhysicalX0ObservationRequiresMatchingUnresolvedReturn() throws {
        let fixture = try RegionalCallFixture.make(.j16init)
        let function = fixture.function
        let returnRow = fixture.seed.returnRow
        XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        XCTAssertEqual(function.instructions[returnRow].operation,
                       .returnValue(.unknown("unresolved_return_contract")))
        let physical = try RegionalCallOracle.Program(rows: fixture.rows, function: function,
            observePhysicalX0WithoutReturnAuthority: true)
        XCTAssertTrue(physical.returnsX0)
        // Opt-in physical observation must not silently become pseudocode authority.
        XCTAssertThrowsError(try RegionalCallOracle.Program(rows: fixture.rows, function: function)) { error in
            guard case let RegionalCallOracle.Failure.invalid(message) = error else {
                return XCTFail("Expected terminal authority refusal, got \(error)")
            }
            XCTAssertEqual(message, "terminal observation is not X0")
        }
        let invalidReturns: [(MacIRValue?, MacIRValue?)] = [
            (.register(name: "x0", version: 1), .register(name: "x0", version: 1)),
            (nil, nil),
            (.unknown("unresolved_return_contract"), .register(name: "x0", version: 1)),
            (.register(name: "x0", version: 1), .unknown("unresolved_return_contract"))
        ]
        for (declared, terminal) in invalidReturns {
            var altered = function
            altered.returnValue = declared
            altered.instructions[returnRow].operation = .returnValue(terminal)
            XCTAssertThrowsError(try RegionalCallOracle.Program(rows: fixture.rows, function: altered,
                observePhysicalX0WithoutReturnAuthority: true)) { error in
                guard case let RegionalCallOracle.Failure.invalid(message) = error else {
                    return XCTFail("Expected physical observation refusal, got \(error)")
                }
                XCTAssertEqual(message, "physical X0 observation requires a matching unresolved return contract")
            }
        }
    }

    func testJ16MappedReturnExpectationRejectsWrongCarrierInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                let fixture = try RegionalCallFixture.make(.j16init)
                let row = fixture.seed.returnRow
                XCTAssertEqual(row, 187)
                let expected = [row: "return unresolved_return_contract; // return"]
                RenderProperties.assertSameStatements(fixture.legacy, baseline: fixture.seed.baselineText,
                    rows: [row], expectedTextByRow: expected)
                XCTAssertNil(RenderProperties.capturedStatementFailure(fixture.legacy,
                    baseline: fixture.seed.baselineText, rows: [row], expectedTextByRow: expected))

                XCTAssertEqual(RenderProperties.capturedStatementFailure(fixture.legacy,
                    baseline: fixture.seed.baselineText, rows: [row],
                    expectedTextByRow: [row: "return x0_12; // return"]),
                    " statement 0, row 187: actual [return unresolved_return_contract; // return] expected [return x0_12; // return]")

                var wrong = fixture.legacy
                let indices = wrong.lines.indices.filter {
                    wrong.lines[$0].sourceAddress == fixture.rows[row].address
                        && wrong.lines[$0].kind == .instruction
                }
                XCTAssertEqual(indices.count, 1)
                let index = try XCTUnwrap(indices.first)
                wrong.lines[index].text = "return x0_12; // return"
                // This is the exact mapped comparison used by the XCTFail wrapper,
                // not an expected XCTest failure or a parallel substring oracle.
                XCTAssertEqual(RenderProperties.capturedStatementFailure(wrong,
                    baseline: fixture.seed.baselineText, rows: [row], expectedTextByRow: expected),
                    " statement 0, row 187: actual [return x0_12; // return] expected [return unresolved_return_contract; // return]")
                XCTAssertEqual(RenderProperties.capturedStatementFailure(fixture.legacy,
                    baseline: fixture.seed.baselineText.replacingOccurrences(
                        of: "return x0_13; // return", with: "return unresolved_return_contract; // return"),
                    rows: [row], expectedTextByRow: expected),
                    "rows [187]: actual document vs expected capture has no independent source-row mapping")
            }
        }
    }

    // Red-team counterexample to a blanket refusal: an independently supplied
    // result contract, unlike an opaque callback write, authorizes the carrier.
    func testExplicitReturnAuthorityStillExportsOpaqueCallCarrierInBothModes() {
        let rows = [
            InstructionRow(address: 0x7000, bytes: "00 01 3f d6", mnemonic: "blr", operands: "x8",
                hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x7004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                hasBreakpoint: false, comment: nil)
        ]
        for ssa in [false, true] {
            let builder = MacIRBuilder(ssaEnabled: ssa)
            let unbound = builder.buildFunction(name: "_opaque_return_control", instructions: rows)
            let bound = builder.buildFunction(name: "_opaque_return_control",
                authoritativeReturnLocation: .single(.gpr(index: 0, carrierWidth: 64)),
                authoritativeReturnType: "uint64_t", instructions: rows)
            XCTAssertEqual(unbound.ssaEnabled, ssa)
            XCTAssertEqual(bound.ssaEnabled, ssa)
            XCTAssertEqual(unbound.returnValue, .unknown("unresolved_return_contract"))
            XCTAssertEqual(bound.returnValue, .register(name: "x0", version: 1))
            XCTAssertEqual(bound.instructions[1].operation,
                           .returnValue(.register(name: "x0", version: 1)))
            XCTAssertEqual(bound.instructions[0].operation, unbound.instructions[0].operation,
                           "only independent enclosing result authority changed")
            XCTAssertEqual(bound.instructions.map(\.source), unbound.instructions.map(\.source))
        }
    }

    /// A single encoded edge in the complete jinit capture is redirected from
    /// the allocation join to the real MOV X20, X0 immediately after allocation.
    /// Nothing is hand-lifted: the entire altered byte stream is decoded and
    /// lifted under the original authored context. This is a negative CFG
    /// perturbation, not a new positive fixture or an IR contradiction control.
    private func nonterminalFixture() throws -> (RegionalCallFixture, [InstructionRow], PseudocodeRenderInput, MacIRFunction) {
        try RegionalCallAttributionFixtures.nonterminal()
    }

    func testUnusedOpaqueResultCannotAcquireNonterminalCopyAndStoreControls() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let (fixture, changedRows, changedInput, function) = try nonterminalFixture()
            let seed = fixture.seed, branchRow = 26, targetRow = 36, callRow = 21
            let printer = PseudocodePrinter(options: .default)
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            let boundary = try XCTUnwrap(RegionalBoundaryPlan.prove(function: function, cfg: cfg))
            XCTAssertNil(boundary.terminal, "a void terminal cannot explain the expected refusal")
            guard case let .call(frame, result) = function.instructions[callRow].operation else {
                return XCTFail("captured callback missing after one-edge perturbation")
            }
            XCTAssertNil(frame.knownSignature)
            XCTAssertEqual(result, .register(name: "x0", version: 2))
            let value = try XCTUnwrap(result)
            for index in function.instructions.indices where index != callRow {
                let values = try XCTUnwrap(RegionalBoundaryPlan.values(function.instructions[index].operation))
                var atoms: Set<MacIRValue> = []
                values.forEach { RegionalBoundaryPlan.collectAtoms($0, into: &atoms) }
                XCTAssertFalse(atoms.contains(value), "the existing linear IR still has no consumer of x0_2")
            }
            var legacyOptions = DecompilerOptions.default
            legacyOptions.structureControlFlow = false
            let legacy = PseudocodePrinter(options: legacyOptions).print(function: function, types: changedInput.types,
                nameOverrides: changedInput.nameOverrides, registerNameOverrides: changedInput.registerNameOverrides,
                stackLocalOverrides: changedInput.stackLocalOverrides, resolvedIndirectCalls: changedInput.resolvedIndirectCalls)
            let mentions = legacy.text.split(separator: "\n").filter {
                $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains("x0_2")
            }
            if SSAPropertyAssertions.enabled {
                if let phi = try assertNonterminalPhi(function) {
                    guard case let .assign(_, source) = function.instructions[targetRow].operation else {
                        return XCTFail("join must retain its MOV operation")
                    }
                    SSAPropertyAssertions.assertView(source, of: phi, width: 64)
                }
                let callLines = legacy.lines(sourcedAt: changedRows[callRow].address)
                    .filter { $0.kind == .instruction && $0.text.hasSuffix("// call") }
                XCTAssertEqual(callLines.count, 1)
                let expectedFixture = try withLegacyLifter { try RegionalCallFixture.make(.jinit) }
                var alpha = SSAAlphaEquivalence(expected: expectedFixture.function, actual: function)
                assertAlphaEquivalentStatements(legacy, expectedFixture.legacy,
                    rows: [callRow], alpha: &alpha)
            } else {
                XCTAssertEqual(mentions.count, 1)
                XCTAssertTrue(mentions.first?.hasSuffix("// call") == true)
            }
            let source = try RegionalCallOracle.Program(rows: changedRows, function: function)
            let scenario = try RegionalCallOracle.UpsamplerScenarios.make(seed: seed,
                name: "C4-unused-result-nonterminal-edge", paths: [], invalidPrecision: true)
            let observed = try RegionalCallOracle.Machine(program: source, scenario: scenario).run()
            XCTAssertTrue(observed.returned)
            XCTAssertNil(observed.returnBits)
            XCTAssertEqual(observed.calls.map(\.row), [callRow])
            XCTAssertEqual(observed.rowVisits[branchRow], 1)
            XCTAssertEqual(observed.rowVisits[targetRow], 1)
            XCTAssertNil(observed.rowVisits[35], "the real allocation call is bypassed")
            let stored = observed.events.compactMap { event -> UInt64? in
                if case let .store(row, _, bytes, bits) = event, row == 39, bytes == 8 { return bits }
                return nil
            }
            XCTAssertEqual(stored, [try XCTUnwrap(observed.calls.first).result],
                           "physical copy and then memory store would expose the unused callback result")

            XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg),
                         "C4_RESULT_AUTHORITY_REQUIRED: refuse a new nonterminal read before X0 is killed")
            let actual = printer.print(function: function, types: changedInput.types,
                nameOverrides: changedInput.nameOverrides, registerNameOverrides: changedInput.registerNameOverrides,
                stackLocalOverrides: changedInput.stackLocalOverrides, resolvedIndirectCalls: changedInput.resolvedIndirectCalls)
            XCTAssertNil(actual.regionTree,
                         "C4_RESULT_AUTHORITY_REQUIRED: no admission for this negative edge perturbation")
            RenderProperties.assertSameStatements(actual, legacy)
            XCTAssertEqual(actual.lines, legacy.lines)
            for row in seed.callRows {
                let address = changedRows[row].address
                let before = legacy.lines(sourcedAt: address).filter { $0.text.hasSuffix("// call") }
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                let after = actual.lines(sourcedAt: address).filter { $0.text.hasSuffix("// call") }
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                XCTAssertEqual(before.count, 1)
                XCTAssertEqual(after, before)
            }
        }
    }
    func testUnusedOpaqueResultCannotAcquireNonterminalCopyAndStore() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(true) {
            let (_, rows, input, function) = try nonterminalFixture()
            guard case let .call(_, allocationResult) = function.instructions[35].operation,
                  case let .assign(_, source) = function.instructions[36].operation else {
                return XCTFail("row 35 allocation call and row 36 MOV must retain their operations")
            }
            let expected = try XCTUnwrap(allocationResult, "row 35 allocation must retain its result")
            if SSAPropertyAssertions.enabled {
                if let phi = try assertNonterminalPhi(function) {
                    SSAPropertyAssertions.assertView(source, of: phi, width: 64)
                }
            } else {
                XCTAssertEqual(source, expected, "row 36 MOV source must equal the allocation result alias from row 35")
            }
            var options = DecompilerOptions.default
            options.structureControlFlow = false
            let document = PseudocodePrinter(options: options).print(function: function, types: input.types,
                nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
                stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
            for line in document.lines(sourcedAt: rows[36].address) { print("ROW36: \(line.text)") }
            RenderProperties.assertNoMarkers(document, rows: [36])
        }
    }

    private func assertNonterminalPhi(_ function: MacIRFunction,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> MacIRPhi? {
        let phi = SSAPropertyAssertions.phi(function, block: 0x3aea8, cell: 0, width: 64,
            incoming: [(predecessor: 0x3ae80, producer: 0x3ae70),
                       (predecessor: 0x3aea4, producer: 0x3aea4)], file: file, line: line)
        let info = try XCTUnwrap(function.ssaInfo, file: file, line: line)
        let graph = try XCTUnwrap(function.cfg, file: file, line: line)
        let block = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x3aea8 }, file: file, line: line)
        let planned = try XCTUnwrap(info.plan.phis.first { $0.block == block.index && $0.cell == 0 },
                                    file: file, line: line)
        XCTAssertEqual(planned.incoming.map(\.machineAddress), [0x3ae80, 0x3aea4], file: file, line: line)
        let expected: [Set<SSAPropertyAssertions.CellZeroOrigin>] = [
            [.entryX0, .callResult(0x3ae6c)], [.callResult(0x3aea4)]
        ]
        for (slot, origins) in zip(planned.incoming, expected) {
            XCTAssertEqual(SSAPropertyAssertions.cellZeroOrigins(slot.definition, info: info, file: file, line: line),
                           origins, file: file, line: line)
        }
        let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x3aea8), file: file, line: line)
        let read = try XCTUnwrap(info.plan.rowReadBindings[row][0], file: file, line: line)
        XCTAssertEqual(info.plan.canonicalID(read), info.plan.canonicalID(planned.destination), file: file, line: line)
        XCTAssertEqual(SSAPropertyAssertions.cellZeroOrigins(read, info: info, file: file, line: line),
                       expected[0].union(expected[1]), file: file, line: line)
        return phi
    }

    private func assertDeterministic(_ input: PseudocodeRenderInput,
                                     file: StaticString = #filePath, line: UInt = #line) {
        RenderProperties.assertDeterministic({
            PseudocodePrinter(options: .default).buildFunction(functionName: input.functionName,
                startAddress: input.startAddress, jumpTables: input.jumpTables,
                objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
                signatureOverrides: input.signatureOverrides,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                directCallVoidResultTargets: input.directCallVoidResultTargets,
                slotCallContracts: input.slotCallContracts, callerReturnWidth: input.callerReturnWidth,
                callerReturnType: input.callerReturnType, types: input.types, instructions: input.instructions)
        }, file: file, line: line)
    }

}

// New test-only seam; the original fixture body and assertion order are retained.
enum RegionalCallAttributionFixtures {
    static func nonterminal() throws -> (RegionalCallFixture, [InstructionRow], PseudocodeRenderInput, MacIRFunction) {
        let fixture = try RegionalCallFixture.make(.jinit)
        let seed = fixture.seed, branchRow = 26, targetRow = 36
        XCTAssertEqual(fixture.rows[branchRow].address, 0x3ae80)
        XCTAssertEqual(fixture.rows[branchRow].mnemonic, "b")
        XCTAssertEqual(fixture.rows[targetRow].mnemonic, "mov")
        XCTAssertEqual(fixture.rows[targetRow].operands, "x20, x0")

        var bytes = try fixture.rows.flatMap { row in
            try row.bytes.split(separator: " ").map { try XCTUnwrap(UInt8($0, radix: 16)) }
        }
        // AArch64 B immediate is signed words from the instruction PC. This
        // forward edge is +40 bytes (ten words), preserving all other bytes.
        XCTAssertEqual(fixture.rows[targetRow].address - fixture.rows[branchRow].address, 40)
        bytes.replaceSubrange((branchRow * 4)..<(branchRow * 4 + 4), with: [0x0a, 0x00, 0x00, 0x14])
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: seed.start)
        XCTAssertEqual(decoded.count, fixture.rows.count)
        guard decoded.count == fixture.rows.count else {
            XCTFail("complete edge perturbation failed to decode")
            throw RegionalCallFixture.Failure.invalidCapture
        }
        let changedRows = decoded.enumerated().map { index, instruction -> InstructionRow in
            let original = fixture.rows[index]
            // Existing symbolic BL identities remain their opaque captured
            // spellings; the unchanged numeric envelopes still come from decode.
            return InstructionRow(address: instruction.address, bytes: instruction.byteText,
                mnemonic: instruction.mnemonic,
                operands: instruction.mnemonic == "bl" ? original.operands : instruction.operands,
                hasBreakpoint: false, comment: instruction.comment,
                structuredOperands: instruction.structuredOperands)
        }
        XCTAssertEqual(changedRows.indices.filter { changedRows[$0] != fixture.rows[$0] }, [branchRow],
                       "only one complete real instruction changes")
        XCTAssertEqual(changedRows[branchRow].operands, "0x000000000003aea8")
        let printer = PseudocodePrinter(options: .default)
        var changedInput = try XCTUnwrap(fixture.capturedInput)
        changedInput.instructions = changedRows
        let function = printer.buildFunction(functionName: changedInput.functionName, startAddress: changedInput.startAddress,
            jumpTables: changedInput.jumpTables, objcSelectors: changedInput.objcSelectors,
            constantStrings: changedInput.constantStrings, signatureOverrides: changedInput.signatureOverrides,
            authoredCallSignaturesByTarget: changedInput.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: changedInput.directCallVoidResultTargets,
            slotCallContracts: changedInput.slotCallContracts, callerReturnWidth: changedInput.callerReturnWidth,
            callerReturnType: changedInput.callerReturnType, types: changedInput.types, instructions: changedInput.instructions)
        RenderProperties.assertDeterministic {
            MacIRBuilder().buildFunction(name: changedInput.functionName, startAddress: changedInput.startAddress,
                jumpTables: changedInput.jumpTables, objcSelectors: changedInput.objcSelectors,
                constantStrings: changedInput.constantStrings, callerReturnWidth: changedInput.callerReturnWidth,
                authoredCallSignaturesByTarget: changedInput.authoredCallSignaturesByTarget,
                directCallVoidResultTargets: changedInput.directCallVoidResultTargets,
                slotCallContracts: changedInput.slotCallContracts, instructions: changedRows)
        }
        return (fixture, changedRows, changedInput, function)
    }
}
