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

/// NEW, never-run selectors. Complete original native fixtures feed the existing
/// printer entry point. This class does not change an old selector or synthesize
/// instructions. Static source authoring is not a RED/GREEN execution receipt.
final class OrdinaryCFixtureAcceptanceTests: XCTestCase {
    private typealias A = OrdinaryCOutputAudit
    private struct Baseline {
        let start: UInt64
        let sha256: String
        let lines: Int
        let gotos: Int
        let rawBranches: Int
    }
    private struct GrowthException {
        let maximumLines: Int
        let reviewReference: String
        let justification: String
    }
    // No exception has been approved. A >1.5x candidate is blocked until a
    // function-specific reviewed justification is explicitly added here.
    // An exception never relaxes syntax, state, transfer, or semantic gates.
    private let reviewedGrowthExceptions: [UInt64: GrowthException] = [:]
    // Upsampler and skip_variable digests follow the reconciled-legacy capture refresh and the frame-size header.
    private let baselines: [UInt64: Baseline] = [
        0x26c78: .init(start: 0x26c78, sha256: "551e15d6a6289a140b433e8dc7182c897c88328bc77552a113e7f05aacd67a46", lines: 325, gotos: 68, rawBranches: 36),
        0x2893c: .init(start: 0x2893c, sha256: "0f71380a5b8705fbcbf00bb44224011229d52324992be053aad026519ba7a6fa", lines: 315, gotos: 65, rawBranches: 35),
        0x3ae18: .init(start: 0x3ae18, sha256: "ef83ca5183a3b19954bfca97256608c17e61987141b6f3fea04f5084ffdb7bc3", lines: 213, gotos: 21, rawBranches: 13),
        0x3b774: .init(start: 0x3b774, sha256: "24f2271ec1422b09c4c7c392d9ffa4c16d0d88721d22b610b35b8da838a20724", lines: 185, gotos: 18, rawBranches: 10),
        0x33418: .init(start: 0x33418, sha256: "48a8d34bdb719e8f630cb380f983a01a48fd739dc1a7febf1dee0abadb36bde9", lines: 60, gotos: 5, rawBranches: 1)
    ]

    func testCapturedJinitColorDeconverterRequiresOrdinaryCFullExport() throws {
        try color(.jinit)
    }
    func testCapturedJ12ColorDeconverterRequiresOrdinaryCFullExport() throws {
        try color(.j12init)
    }
    func testCapturedJinitUpsamplerRequiresOrdinaryCFullExport() throws {
        try upsampler(.jinit)
    }
    func testCapturedJ12UpsamplerRequiresOrdinaryCFullExport() throws {
        try upsampler(.j12init)
    }
    func testCapturedSkipVariableRequiresOrdinaryCFullExport() throws {
        let fixture = try OrdinaryCRecordedCallFixture.skipVariable()
        var alpha = fixture.function.ssaEnabled ? SSAAlphaEquivalence(
            expected: SSAAlphaEquivalence.legacyFunction(from: fixture.input), actual: fixture.function) : nil
        XCTAssertEqual(fixture.rows.count, 58)
        XCTAssertEqual(fixture.rows.first?.address, 0x33418)
        XCTAssertEqual(fixture.rows.last?.address, 0x334fc)
        for payload in fixture.callPayloads {
            if var identities = alpha {
                identities.assertEquivalent(payload.after, [payload.baseline])
                alpha = identities
            } else {
                XCTAssertEqual(payload.after, [payload.baseline], "exact call payload at source \(A.hex(payload.address))")
            }
        }
        try requireExterior(document: fixture.document, rows: fixture.rows, baselineText: fixture.baselineText,
                            prefix: 0..<6, suffix: 52..<58, alpha: &alpha)
        try requireOrdinaryC(document: fixture.document, function: fixture.function,
            baselineText: fixture.baselineText, start: fixture.start, callCount: 4)
    }

    private func upsampler(_ seed: RegionalCallSeed) throws {
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
        try fixtures.requireFullTypedRowOwnership()
        // Full typed output was audited above; the frozen semantic/payload oracle is explicitly opaque.
        let fixture = fixtures.opaque
        var alpha = fixture.function.ssaEnabled ? SSAAlphaEquivalence(
            expected: SSAAlphaEquivalence.legacyFunction(from: fixture.input), actual: fixture.function) : nil
        XCTAssertTrue(seed == .jinit || seed == .j12init)
        XCTAssertEqual(fixture.function.parameters.count, 1)
        XCTAssertEqual(fixture.function.parameters.first?.name, "cinfo")
        XCTAssertEqual(fixture.function.returnType, "void")
        XCTAssertNil(fixture.function.returnValue)
        for payload in fixture.callPayloads {
            if var identities = alpha {
                identities.assertEquivalent(payload.after, [payload.baseline])
                alpha = identities
            } else {
                XCTAssertEqual(payload.after, [payload.baseline], "exact call payload at source \(A.hex(payload.address))")
            }
        }
        try requireExterior(document: fixture.document, rows: fixture.rows, baselineText: seed.baselineText,
                            prefix: 0..<7, suffix: seed.suffixStart..<seed.rowCount, alpha: &alpha)
        try requireOrdinaryC(document: fixture.document, function: fixture.function,
            baselineText: seed.baselineText, start: seed.start, callCount: seed.callRows.count)
    }

    private func color(_ seed: RegionalSwitchSeed) throws {
        let fixture = try RegionalSwitchFixture.make(seed)
        var alpha = fixture.function.ssaEnabled ? SSAAlphaEquivalence(
            expected: SSAAlphaEquivalence.legacyFunction(from: fixture.input), actual: fixture.function) : nil
        XCTAssertTrue(seed == .jinit || seed == .j12init)
        XCTAssertEqual(fixture.input.instructions, fixture.capture.input_rows)
        try fixture.requireCompleteInputAuthority()
        XCTAssertEqual(fixture.function.returnType, "void")
        XCTAssertNil(fixture.function.returnValue)
        for payload in fixture.callPayloads {
            if var identities = alpha {
                identities.assertEquivalent(payload.after, [payload.baseline])
                alpha = identities
            } else {
                XCTAssertEqual(payload.after, [payload.baseline], "exact call payload at source \(A.hex(payload.address))")
            }
        }
        try requireExterior(document: fixture.document, rows: fixture.rows, baselineText: fixture.baselineText,
                            prefix: 0..<3, suffix: (seed.returnRow - 2)..<(seed.returnRow + 1), alpha: &alpha)
        let report = try requireOrdinaryC(document: fixture.document, function: fixture.function,
            baselineText: fixture.baselineText, start: seed.start, callCount: seed.callRows.count)
        try requireDirectWriterLoop(fixture, report: report)
        // Preserve the independent literal-source 0/1/multiple boundary without
        // hardcoding any candidate variable names or legacy physical bindings.
        // This reference witness alone is NOT emitted-candidate equivalence.
        try requireIndependentColorReference(fixture)
    }

    private func requireExterior(document: PseudocodeDocument, rows: [InstructionRow], baselineText: String,
                                 prefix: Range<Int>, suffix: Range<Int>,
                                 alpha: inout SSAAlphaEquivalence?) throws {
        let lines = baselineText.components(separatedBy: "\n")
        let returns = lines.indices.filter { lines[$0].hasSuffix("// return") }
        XCTAssertEqual(returns.count, 1, "one retained terminal in the exact native baseline")
        let terminal = try XCTUnwrap(returns.first)
        guard terminal + 1 >= suffix.count, lines.count >= 2 + prefix.count else {
            throw A.Failure.invalid("incomplete retained exterior baseline")
        }
        let prefixText = Array(lines.dropFirst(2).prefix(prefix.count))
        let suffixText = Array(lines[(terminal + 1 - suffix.count)...terminal])
        for (row, payload) in Array(zip(prefix, prefixText)) + Array(zip(suffix, suffixText)) {
            let expected = payload.trimmingCharacters(in: .whitespaces)
            let actual = document.lines(sourcedAt: rows[row].address).map { $0.text.trimmingCharacters(in: .whitespaces) }
            if var identities = alpha {
                let matches = actual.filter { text in
                    var candidate = identities
                    return candidate.mismatch(actual: text, expected: expected) == nil
                }
                XCTAssertEqual(matches.count, 1,
                    "immutable source-mapped exterior row \(row), including real saved-stack restores after opaque calls")
                if let match = matches.first { identities.assertEquivalent([match], [expected]) }
                alpha = identities
            } else {
                XCTAssertEqual(actual.filter { $0 == expected }.count, 1,
                               "immutable source-mapped exterior row \(row), including real saved-stack restores after opaque calls")
            }
        }
        if var identities = alpha {
            identities.assertEquivalent(document.lines(sourcedAt: rows[suffix.upperBound - 1].address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, [lines[terminal].trimmingCharacters(in: .whitespaces)])
            alpha = identities
        } else {
            XCTAssertEqual(document.lines(sourcedAt: rows[suffix.upperBound - 1].address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, [lines[terminal].trimmingCharacters(in: .whitespaces)], "exact original terminal/result role")
        }
    }

    @discardableResult
    private func requireOrdinaryC(document: PseudocodeDocument, function: MacIRFunction,
                                  baselineText: String, start: UInt64, callCount: Int,
                                  file: StaticString = #filePath, line: UInt = #line) throws -> A.Report {
        let expected = try XCTUnwrap(baselines[start], file: file, line: line)
        XCTAssertEqual(RegionalSwitchFixture.sha256(Data(baselineText.utf8)), expected.sha256,
                       "immutable complete native baseline, not fresh disabled-options text", file: file, line: line)
        XCTAssertEqual(A.physicalLines(baselineText), expected.lines, file: file, line: line)
        let beforeTokens = try A.lex(baselineText)
        XCTAssertEqual(beforeTokens.filter { $0.text == "goto" }.count, expected.gotos, file: file, line: line)
        XCTAssertEqual(beforeTokens.filter { $0.text == "__branch" }.count, expected.rawBranches, file: file, line: line)
        XCTAssertEqual(document.lines.filter { $0.kind == .signature }.map(\.text),
                       [String(baselineText.split(separator: "\n").first!)], file: file, line: line)
        XCTAssertEqual(document.lines.filter { $0.text.hasSuffix("// call") }.count, callCount,
                       "no lost/duplicated/new opaque call; source mapping checked separately", file: file, line: line)
        let report = try A.analyze(document: document, function: function, baselineText: baselineText)
        let tokens = report.tokens.map(\.text)
        let legacyNames = Set(tokens.filter { $0.hasPrefix("rgn_regional_") })
        XCTAssertTrue(legacyNames.isEmpty,
                      "ORDINARY_C_NATIVE_SSA_REQUIRED: no parallel physical-state namespace: \(legacyNames.sorted())", file: file, line: line)
        let flagNames = Set(tokens.filter { A.matches(#"(?i)^(?:nzcv(?:_[0-9]+)?|(?:rgn_regional_)?[nzcv]_[0-9]+|(?:negative|zero|carry|overflow)_flag(?:_[0-9]+)?)$"#, $0) })
        XCTAssertTrue(flagNames.isEmpty,
                      "ORDINARY_C_WRITER_PREDICATES_REQUIRED: printed flag storage/uses: \(flagNames.sorted())", file: file, line: line)
        XCTAssertTrue(report.errors.isEmpty,
                      "ORDINARY_C_CONTROL_REQUIRED:\n" + report.errors.joined(separator: "\n") + "\n" + report.ledger,
                      file: file, line: line)
        XCTAssertLessThanOrEqual(report.gotoEquivalentTotal, expected.gotos,
            "NO_PER_FUNCTION_TRANSFER_GROWTH: all goto tokens plus each labelled break/continue count once. __branch remains a separate diagnostic, not a redefinition of the historical total.\n\(report.ledger)", file: file, line: line)
        let actualLines = A.physicalLines(document.text)
        if actualLines * 2 > expected.lines * 3 {
            let exception = reviewedGrowthExceptions[start]
            XCTAssertNotNil(exception,
                "ORDINARY_C_GROWTH_REVIEW_REQUIRED: \(actualLines)/\(expected.lines) physical lines exceeds 1.5x; no per-function approved justification", file: file, line: line)
            if let exception {
                XCTAssertFalse(exception.reviewReference.isEmpty, file: file, line: line)
                XCTAssertFalse(exception.justification.isEmpty, file: file, line: line)
                XCTAssertLessThanOrEqual(actualLines, exception.maximumLines, file: file, line: line)
            }
        }
        // Existing native register/temporary conventions permit fresh SSA join
        // values, but not a renamed general-purpose register/flag/state bank.
        let baselineNames = Set(beforeTokens.map(\.text).filter(A.identifier))
        let keywords: Set<String> = ["if", "else", "while", "do", "for", "break", "continue", "goto", "true", "false", "switch", "case", "default", "bool"]
        // A27 (94c68a453): an SSA flags phi joins one condition per incoming edge into a fresh boolean
        // `flag_<row pc>_<condition>_0` (the only name the lifter invents; DecodedRegionalCallTests A29/A33
        // require the `flag_` prefix). It is a phi destination, not a renamed physical flag bank, so the
        // flag-storage names refused above stay refused.
        let flagsPhiName = SSAPropertyAssertions.enabled
            ? "|flag_[0-9a-f]+_(?:eq|ne|hs|cs|lo|cc|mi|pl|vs|vc|hi|ls|ge|lt|gt|le)_0" : ""
        let extraNames = Set(tokens.filter(A.identifier)).subtracting(baselineNames).subtracting(keywords).filter {
            !A.matches("^(?:[xw][0-9]+_[0-9]+|sp_[0-9]+|tmp_?[0-9]+|L_[0-9a-fA-F]+|u?int(?:8|16|32|64)_t\(flagsPhiName))$", $0)
        }
        XCTAssertTrue(extraNames.isEmpty,
            "NATIVE_NAMING_REQUIRED: new names must use existing SSA/registerNameContext/temporary paths, not renamed state machinery: \(extraNames.sorted())", file: file, line: line)
        // A reduced raw-literal count is not payoff. A source conditional must
        // actually be owned by native if/loop syntax and have no residual transfer
        // at that source. Every goto L_x stays in the uncredited ledger.
        let branchPCs = Set(function.instructions.compactMap { instruction -> UInt64? in
            if case .conditionalBranch = CFGBuilder.terminatorKind(of: instruction.operation) { return instruction.source.address }
            return nil
        })
        let residualPCs = Set(report.transfers.filter { $0.countsAsGoto || A.isRawControlHelper($0.kind) }.compactMap(\.source))
        let structured = report.structuredSourceAddresses.intersection(branchPCs).subtracting(residualPCs)
        XCTAssertFalse(structured.isEmpty,
                       "SOURCE_EDGE_PAYOFF_REQUIRED: renaming raw gotos to labels earns no removed-edge credit", file: file, line: line)
        // Initial RED must be these behavioral assertions on real output. Stop
        // before the deeper source predicate/reference checks after an invalid
        // document; unsupported grammar is never converted into semantic GREEN.
        guard legacyNames.isEmpty, flagNames.isEmpty, report.errors.isEmpty,
              extraNames.isEmpty, !structured.isEmpty,
              report.gotoEquivalentTotal <= expected.gotos,
              actualLines * 2 <= expected.lines * 3 || reviewedGrowthExceptions[start] != nil else {
            throw A.Failure.invalid("ORDINARY_C_ACCEPTANCE_BLOCKED: complete fixture output is not ordinary C; ledger above")
        }
        return report
    }

    /// `tmp = old - 1;` followed by exactly `old == 1` (loop exit) or `old != 1`
    /// (loop test) is the same predicate as `tmp == 0` / `tmp != 0` modulo 2^n.
    /// Any other operand, constant or operator is not accepted.
    static func comparesOldValueOfDecrement(condition: [String], writer: [String], exit: Bool) -> Bool {
        let ones: Set<String> = ["1", "0x1", "0x01"]
        guard let assign = writer.firstIndex(of: "="), writer.indices.contains(assign + 3),
              A.identifier(writer[assign - 1]), A.identifier(writer[assign + 1]),
              writer[assign + 2] == "-", ones.contains(writer[assign + 3]),
              writer.count == assign + 4 || writer[assign + 4] == ";" else { return false }
        return condition.count == 3 && condition[0] == writer[assign + 1]
            && condition[1] == (exit ? "==" : "!=") && ones.contains(condition[2])
    }

    func testOldValueDecrementPredicateAcceptsOnlyTheExactEquivalent() {
        let writer = ["tmp1", "=", "x9_4", "-", "0x1", ";"]
        XCTAssertTrue(Self.comparesOldValueOfDecrement(condition: ["x9_4", "==", "0x1"], writer: writer, exit: true))
        XCTAssertTrue(Self.comparesOldValueOfDecrement(condition: ["x9_4", "!=", "1"], writer: writer, exit: false))
        XCTAssertFalse(Self.comparesOldValueOfDecrement(condition: ["x9_4", "==", "0x0"], writer: writer, exit: true))
        XCTAssertFalse(Self.comparesOldValueOfDecrement(condition: ["x9_4", "!=", "0x1"], writer: writer, exit: true))
        XCTAssertFalse(Self.comparesOldValueOfDecrement(condition: ["x8_4", "==", "0x1"], writer: writer, exit: true))
        XCTAssertFalse(Self.comparesOldValueOfDecrement(condition: ["x9_4", "==", "0x1"],
                                                        writer: ["tmp1", "=", "x9_4", "-", "0x2", ";"], exit: true))
    }

    private func requireDirectWriterLoop(_ fixture: RegionalSwitchFixture, report: A.Report) throws {
        let writer = fixture.seed == .jinit ? 254 : 247
        let branch = writer + 1
        XCTAssertEqual(fixture.rows[writer].mnemonic, "subs")
        XCTAssertEqual(fixture.rows[writer].operands, "x9, x9, #1")
        XCTAssertEqual(fixture.rows[branch].mnemonic, "b.ne")
        XCTAssertEqual(fixture.rows[writer].bytes, "29 05 00 f1")
        XCTAssertEqual(fixture.rows[branch].bytes, "c1 ff ff 54")
        let writerPC = fixture.rows[writer].address, branchPC = fixture.rows[branch].address
        let direct = report.loops.filter { $0.condition.contains { $0.source == branchPC } }
        let exits = report.predicates.filter { predicate in
            guard predicate.condition.contains(where: { $0.source == branchPC }) else { return false }
            let firstLine = report.tokens[predicate.first].line
            let lastLine = report.tokens[predicate.last - 1].line
            return report.transfers.contains { $0.kind == "break" && $0.target == nil && $0.source == branchPC
                && (firstLine...lastLine).contains($0.line) && $0.proof.hasPrefix("plain break, innermost real loop") }
        }
        XCTAssertEqual(direct.count + exits.count, 1,
            "SUBS/B.NE needs exactly one source-bound result predicate, either a loop test or a certified loop-local exit with required edge copies")
        guard direct.count + exits.count == 1 else { throw A.Failure.invalid("missing/duplicated writer-result predicate") }
        let isExit = !exits.isEmpty
        let predicateTokens = isExit ? exits[0].condition : direct[0].condition
        let condition = predicateTokens.map(\.text)
        XCTAssertFalse(condition == ["true"] || condition == ["1"], "the predicate itself must use the writer result")
        func assignedNames(at source: UInt64) throws -> Set<String> {
            let tokens = try A.lex(fixture.document.lines(sourcedAt: source).map(\.text).joined(separator: "\n"))
            return Set(tokens.indices.compactMap { index -> String? in
                guard tokens[index].text == "=", index > 0, A.identifier(tokens[index - 1].text) else { return nil }
                return tokens[index - 1].text
            })
        }
        let writerResults = try assignedNames(at: writerPC)
        // Native SSA aliases are discovered only from their ORIGINAL preheader
        // source assignment, not by a physical-name convention. The X64 writer
        // and its B.NE bytes above independently anchor the absorbed operation.
        XCTAssertEqual(fixture.rows[writer - 2].mnemonic, "sub")
        XCTAssertEqual(fixture.rows[writer - 2].operands, "x9, x9, #1")
        let initialCarriers = try assignedNames(at: fixture.rows[writer - 2].address)
        let loopIncrement = direct.first?.increment.map(\.text) ?? []
        let operation = isExit ? "==" : "!="
        func compares(_ tokens: [String], to constants: Set<String>) -> Bool {
            tokens.contains(operation) && tokens.contains(where: constants.contains)
        }
        let explicitResult = !writerResults.intersection(condition).isEmpty && compares(condition, to: ["0", "0x0", "0x00"])
        func decrementedCarriers(_ tokens: [String], prefix: Bool) -> Set<String> {
            Set(tokens.indices.compactMap { index -> String? in
                guard tokens[index] == "--" else { return nil }
                let other = prefix ? index + 1 : index - 1
                guard tokens.indices.contains(other), A.identifier(tokens[other]) else { return nil }
                return tokens[other]
            })
        }
        let prefix = decrementedCarriers(condition, prefix: true).intersection(initialCarriers)
        let postfix = decrementedCarriers(condition, prefix: false).intersection(initialCarriers)
        let prefixResult = !prefix.isEmpty && compares(condition, to: ["0", "0x0", "0x00"])
        // (old--) != 1 is the exact X64 equivalent of (new != 0), not
        // (old--) != 0. The independent candidate oracle must also prove timing.
        let postfixResult = !postfix.isEmpty && compares(condition, to: ["1", "0x1", "0x01"])
        let latchCarriers = decrementedCarriers(loopIncrement, prefix: true)
            .union(decrementedCarriers(loopIncrement, prefix: false)).intersection(initialCarriers)
        let forResult = direct.first?.kind == "for" && !latchCarriers.intersection(condition).isEmpty
            && compares(condition, to: ["0", "0x0", "0x00"])
        // SSA propagation may fold `(old - 1) == 0` into `old == 1` while the
        // writer assignment stays; that is exactly the writer-result predicate.
        let writerTokens = try A.lex(fixture.document.lines(sourcedAt: writerPC).map(\.text).joined(separator: "\n")).map(\.text)
        let oldValueResult = Self.comparesOldValueOfDecrement(condition: condition, writer: writerTokens, exit: isExit)
        XCTAssertTrue(explicitResult || prefixResult || postfixResult || forResult || oldValueResult,
            "predicate must consume writer result, a source-bound decrement, or exact for-latch carrier; no flags or unrelated temp; condition \(condition.joined(separator: " ")) increment \(loopIncrement.joined(separator: " ")) writerResults \(writerResults.sorted()) carriers \(initialCarriers.sorted()) kind \(direct.first?.kind ?? (isExit ? "exit" : "none")) writer lines \(fixture.document.lines(sourcedAt: writerPC).map(\.text)) branch lines \(fixture.document.lines(sourcedAt: branchPC).map(\.text))")
        if prefixResult || postfixResult || forResult {
            XCTAssertTrue(writerResults.isEmpty, "absorbed decrement must not also execute as a separate writer assignment")
            XCTAssertEqual((condition + loopIncrement).filter { $0 == "--" }.count, 1,
                           "one source SUBS must not become duplicate decrements")
        }
        XCTAssertFalse(condition.contains(where: { $0.hasPrefix("rgn_") }), "no physical-register loop condition")
        // This is a syntax/source-binding gate, not timing equivalence. A fused
        // prefix/postfix/for form (or while(true)+source-bound exit) STILL needs
        // the independently reviewed candidate oracle and edge-copy proof.
    }

    private func requireIndependentColorReference(_ fixture: RegionalSwitchFixture) throws {
        typealias O = RegionalSwitchOracle
        let source = try O.Program(fixture: fixture)
        let wanted = ["gray-zero-iterations": 0, "gray-one-iteration": 1, "gray-multiple-iterations": 3]
        let scenarios = try O.ColorScenarios.all(for: fixture.seed).filter { wanted[$0.name] != nil }
        XCTAssertEqual(Set(scenarios.map(\.name)), Set(wanted.keys))
        let store = fixture.seed == .jinit ? 253 : 246
        for scenario in scenarios {
            XCTAssertEqual(scenario.startRow, 0, "full entry, not a synthetic regional binding")
            XCTAssertTrue(scenario.regionalBindings.isEmpty)
            let result = try O.Machine(program: source, scenario: scenario).run()
            let count = try XCTUnwrap(wanted[scenario.name])
            XCTAssertEqual(result.rowVisits[store, default: 0], count, scenario.name)
            XCTAssertEqual(result.rowVisits[store + 1, default: 0], count, "X64 SUBS recurrence")
            XCTAssertEqual(result.rowVisits[store + 2, default: 0], count, "B.NE recurrence")
            let writes = result.events.compactMap { event -> O.Write? in
                if case let .store(row, address, bytes, bits) = event, row == store {
                    return .init(address: address, bytes: bytes, bits: bits)
                }; return nil
            }
            XCTAssertEqual(writes.count, count)
            XCTAssertTrue(writes.allSatisfy { $0.bytes == 4 && $0.bits == 0 })
            XCTAssertTrue(result.returned)
            if count > 0 { XCTAssertEqual(result.afterRows[store + 1]?.last?.registers[9], 0) }
        }
    }
}
