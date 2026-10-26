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

/// New tests-first selectors against the retained, complete real-input fixtures.
/// No hand-authored decoded stream or changed fixture is used. In-memory typed
/// or CFG contradictions are deliberately invalid proof inputs, not claims that
/// the corresponding machine bytes execute the mutated typed operation.
final class RegionalSwitchCertificateBoundaryTests: XCTestCase {
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


    func testUniqueExistingReturnPreservesColdRowsAndRejectsMidEpilogueEntry() throws {
        let (function, cfg) = try original(.jinit)
        let plan = try XCTUnwrap(RegionalBoundaryPlan.prove(function: function, cfg: cfg),
            "NEW_BOUNDARY_REQUIRED: unique CFG RET and typed-switch inventory must pass before the negatives")
        XCTAssertEqual(plan.terminalRows, [294])
        XCTAssertEqual(plan.suffixStart, 292)
        XCTAssertEqual(plan.exteriorRows.intersection(Set(292..<function.instructions.count)), Set(292...294))
        XCTAssertNil(plan.terminal)
        XCTAssertEqual(plan.callRows, Set(RegionalSwitchSeed.jinit.callRows))
        XCTAssertNotNil(plan.calls[317], "the actual call after lexical RET must remain a call boundary")
        XCTAssertFalse(plan.exteriorRows.contains(317))
        XCTAssertEqual(plan.calls[317]?.original, function.instructions[317])
        XCTAssertEqual(function.returnType, "void")
        XCTAssertNil(function.returnValue)
        XCTAssertEqual(function.instructions[294].operation, .returnValue(nil))

        for entryRow in [293, 294] {
            var contradictory = function
            // Rebind an existing late B's typed destination, preserving all
            // original native bytes/source. Boundary CFG must now detect an
            // entry into the middle of the original restore/RET interval.
            let branchRow = contradictory.instructions.count - 1
            guard case .intrinsic(nil, "branch", _) = contradictory.instructions[branchRow].operation else {
                return XCTFail("captured final cold B changed")
            }
            contradictory.instructions[branchRow].operation = .intrinsic(destination: nil, name: "branch",
                arguments: [.immediate(Int64(contradictory.instructions[entryRow].source.address))])
            let changedCFG = CFGBuilder.buildCFG(instructions: contradictory.instructions)
            XCTAssertNotNil(changedCFG.blockByStartIndex[entryRow], "mutation must create the targeted middle leader")
            XCTAssertNil(RegionalBoundaryPlan.prove(function: contradictory, cfg: changedCFG),
                "MID_EPILOGUE_ENTRY_MUST_REFUSE row \(entryRow)")
        }
        var twoReturns = function
        twoReturns.instructions[twoReturns.instructions.count - 1].operation = .returnValue(nil)
        XCTAssertNil(RegionalBoundaryPlan.prove(function: twoReturns,
            cfg: CFGBuilder.buildCFG(instructions: twoReturns.instructions)), "two typed returns are outside the boundary")
        var mismatchedDeclaration = function
        mismatchedDeclaration.returnValue = .register(name: "x0", version: 24)
        XCTAssertNil(RegionalBoundaryPlan.prove(function: mismatchedDeclaration, cfg: cfg),
            "the selected existing RET may not acquire a new returned atom")
    }

    func testTypedSwitchCertificateRejectsContradictionsAndBindsEveryOriginalCase() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let (function, cfg) = try original(.jinit)
            let state = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg),
                "NEW_SWITCH_STATE_REQUIRED: mutation refusal cannot stand in for an admitted original prerequisite")
            let row = 152
            guard case let .switchDispatch(selector, cases, defaultTarget) = function.instructions[row].operation else {
                return XCTFail("captured first switch missing")
            }
            if SSAPropertyAssertions.enabled {
                var alpha = SSAAlphaEquivalence()
                alpha.assertEquivalent([String(describing: selector)], ["w8_12"])
            } else {
                XCTAssertEqual(selector, .register(name: "w8", version: 12))
            }
            XCTAssertEqual(cases.map(\.value), Array(0...9).map(Int64.init))
            XCTAssertEqual(cases[1].target, cases[6].target)
            XCTAssertTrue(state.matches(function: function, cfg: cfg))

            func refuses(_ label: String, mutate: (inout MacIRFunction) -> Void) {
                var changed = function
                mutate(&changed)
                let changedCFG = CFGBuilder.buildCFG(instructions: changed.instructions)
                XCTAssertFalse(state.matches(function: changed, cfg: changedCFG), label)
                XCTAssertNil(RegionalPhysicalStatePlan.prove(function: changed, cfg: changedCFG), label)
            }
            refuses("selector must be the exact W definition, never the dispatched X target") {
                $0.instructions[row].operation = .switchDispatch(index: .register(name: "x10", version: 4),
                    cases: cases, defaultTarget: defaultTarget)
            }
            refuses("selector version must have the exact original unique definition") {
                $0.instructions[row].operation = .switchDispatch(index: .register(name: "w8", version: 13),
                    cases: cases, defaultTarget: defaultTarget)
            }
            refuses("ordered ordinal labels cannot be normalized") {
                var reordered = cases; reordered.swapAt(0, 1)
                $0.instructions[row].operation = .switchDispatch(index: selector, cases: reordered, defaultTarget: defaultTarget)
            }
            refuses("missing case must disagree with the exact W bounds compare") {
                $0.instructions[row].operation = .switchDispatch(index: selector, cases: Array(cases.dropLast()), defaultTarget: defaultTarget)
            }
            refuses("absent default must not be reconstructed from CFG or source") {
                $0.instructions[row].operation = .switchDispatch(index: selector, cases: cases, defaultTarget: nil)
            }
            refuses("non-address case must not disappear during CFG extraction") {
                var changedCases = cases; changedCases[6].target = .unknown("unresolved case")
                $0.instructions[row].operation = .switchDispatch(index: selector, cases: changedCases, defaultTarget: defaultTarget)
            }
            refuses("changed typed CMP cannot contradict unchanged decoded W CMP") {
                $0.instructions[145].operation = .intrinsic(destination: nil, name: "compare", arguments: [selector, .immediate(8)])
            }
            refuses("changed unsigned guard cannot contradict unchanged decoded B.HI") {
                guard case let .conditionalBranch(_, left, right, target) = $0.instructions[146].operation else { return }
                $0.instructions[146].operation = .conditionalBranch(condition: ">=", left: left, right: right, target: target)
            }
            refuses("missing real decoder sidecar cannot be treated as unavailable evidence") {
                $0.instructions[row].source.structuredOperands = nil
            }
            refuses("contradictory bytes cannot be repaired by a matching typed operation") {
                $0.instructions[145].source.byteText = function.instructions[144].source.byteText
            }
            refuses("bypass predecessor must not enter dispatch without the selector definition") {
                let branchRow = function.instructions.count - 1
                $0.instructions[branchRow].operation = .intrinsic(destination: nil, name: "branch",
                    arguments: [.immediate(Int64(function.instructions[147].source.address))])
            }

            // The old certificate must reject a changed repeated-label mapping even
            // though the ordered-distinct graph is IDENTICAL. A fresh model-relative
            // certificate is not obliged to reject that new input solely because it
            // differs from unavailable original raw tables; it must preserve it.
            var changedMapping = function
            var remappedCases = cases
            remappedCases[6].target = cases[3].target
            changedMapping.instructions[row].operation = .switchDispatch(index: selector,
                cases: remappedCases, defaultTarget: defaultTarget)
            let remappedCFG = CFGBuilder.buildCFG(instructions: changedMapping.instructions)
            XCTAssertEqual(remappedCFG.blocks, cfg.blocks)
            XCTAssertFalse(state.matches(function: changedMapping, cfg: remappedCFG),
                "same distinct CFG does not imply the same complete switch")
        }
    }

    func testNonfinalBoundaryKeepsJ16OriginalReturnAuthority() throws {
        let (function, cfg) = try original(.j16initC4Negative)
        if SSAPropertyAssertions.enabled {
            _ = try SSAWitnessAcceptance.requireColorConverterTerminal(function)
        } else {
            let boundary = try XCTUnwrap(RegionalBoundaryPlan.prove(function: function, cfg: cfg),
                "NEW_BOUNDARY_REQUIRED: do not credit the old lexical-last-RET refusal as terminal-origin coverage")
            XCTAssertEqual(boundary.terminalRows, [281])
            XCTAssertEqual(boundary.terminal?.alias.value, .register(name: "x0", version: 16))
            XCTAssertEqual(boundary.terminal?.row, 281)
            XCTAssertEqual(boundary.terminal?.exportRow, 279)
            XCTAssertEqual(boundary.calls[198]?.result?.value, .register(name: "x0", version: 12))
            XCTAssertEqual(boundary.calls[259]?.result?.value, .register(name: "x0", version: 16))
        }
        XCTAssertEqual(cfg.blocks[58].successors, [83])
        XCTAssertEqual(cfg.blocks[83].successors, [85, 84])
        XCTAssertEqual(cfg.blocks[84].successors, [86])
        XCTAssertEqual(cfg.blocks[85].successors, [86])
        if !SSAPropertyAssertions.enabled {
            XCTAssertEqual(function.instructions[281].operation, .returnValue(.register(name: "x0", version: 16)))
        }
        XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: cfg))
        // This establishes boundary reachability, not complete call/terminal-contract reason
        // isolation. The parent must separately establish all physical-state
        // prerequisites before claiming terminalOriginsPreserved gate coverage.
    }

    /// One complete producer lift per selector, no printer, decoder sweep,
    /// capture regeneration, synthetic fixture, or changed pinned expectation.
    private func original(_ seed: RegionalSwitchSeed) throws -> (MacIRFunction, CFG) {
        if seed != .j16initC4Negative {
            let full = try RegionalSchema2Bindings39A.prepare(function: seed.name, start: seed.start)
            let witness = try RegionalSwitchFixture.load(seed)
            try RegionalSwitchFixture.requireHistoricalSourceWitness(witness, capture: full.capture, original: full.original)
            return (full.original, CFGBuilder.buildCFG(instructions: full.original.instructions))
        }
        // Explicit historical historical-only negative, not fresh full authority.
        let capture = try RegionalSwitchFixture.load(seed)
        let input = try capture.restoredInput()
        let function = PseudocodePrinter(options: .default).buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables, objcSelectors: input.objcSelectors,
            constantStrings: input.constantStrings, signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, types: input.types, instructions: input.instructions)
        let capturedLines = capture.canonical_text.components(separatedBy: "\n")
        let baselineCallLines = try capture.calls.map { call in
            guard capturedLines.indices.contains(call.baseline_line_number - 1) else {
                throw RegionalSwitchFixture.Failure.invalid("call row \(call.lifted_index): captured line \(call.baseline_line_number) is out of range")
            }
            return capturedLines[call.baseline_line_number - 1]
        }
        RenderProperties.assertCallShape(function, callRows: seed.callRows,
            decoded: input.instructions, baselineCallLines: baselineCallLines)
        let returnRow = try RenderProperties.returnRow(decoded: input.instructions)
        XCTAssertEqual(returnRow, seed.returnRow, "decoded RET must retain its captured row")
        RenderProperties.assertReturnShape(function, returnRow: returnRow)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertEqual(cfg.blocks.count, capture.cfg_blocks.count, "captured CFG block count")
        for row in [198, 259, 279, 281] {
            let expected = try XCTUnwrap(capture.cfg_blocks.first {
                $0.start_index <= row && row < $0.end_index_exclusive
            }, "captured CFG block containing row \(row)")
            let actual = try XCTUnwrap(cfg.blocks.first {
                $0.startIndex <= row && row < $0.endIndex
            }, "current CFG block containing row \(row)")
            XCTAssertEqual(actual.startIndex, expected.start_index, "CFG row \(row): block span start")
            XCTAssertEqual(actual.endIndex, expected.end_index_exclusive, "CFG row \(row): block span end")
            XCTAssertEqual(actual.successors, expected.successors, "CFG row \(row): ordered successors")
        }
        return (function, cfg)
    }
}
