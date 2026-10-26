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

/// Isolated CFG-algorithm negative, NOT a newly decoded binary or a physical
/// admission test. Uses every original captured row and a clearly derived graph.
/// New analysis API is a prospective test seam, not an absent-symbol RED receipt.
final class RegionalSingleCMPOriginTests: XCTestCase {
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


    func testCapturedJ12RefusesSecondNZCVWriterOnAlternatePath() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalSwitchFixture.make(.j12init)
            let function = fixture.function
            let source = try RegionalSwitchOracle.Program(fixture: fixture)
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertEqual(source.rows, fixture.capture.input_rows)
            XCTAssertEqual(source.code.count, function.instructions.count)
            XCTAssertEqual(function.instructions.count, 321)
            XCTAssertEqual(cfg.blocks.count, 98)
            XCTAssertEqual(function.instructions[205].operation,
                           .intrinsic(destination: nil, name: "branch_eq", arguments: [.immediate(0x28e34)]))
            for (row, immediate) in [(126, UInt64(1)), (129, UInt64(2))] {
                guard case let .compare("cmp", left, .immediate(right)) = source.code[row] else {
                    return XCTFail("Original CMP source required at row \(row)")
                }
                XCTAssertEqual(left.index, 8)
                XCTAssertEqual(left.width, 32)
                XCTAssertFalse(left.zero)
                XCTAssertEqual(right, immediate)
            }
            XCTAssertEqual(cfg.blocks[34].instructionRange, 122..<128)
            XCTAssertEqual(cfg.blocks[36].instructionRange, 129..<131)
            XCTAssertEqual(cfg.blocks[61].instructionRange, 205..<206)
            XCTAssertEqual(cfg.blocks[94].instructionRange, 309..<312)

            // Reuse the existing independent parser for the entire native stream.
            // No production writer set or hand-authored row identities supply facts.
            let writers = try Set(source.code.indices.filter { try writesNZCV(source.code[$0]) })
            XCTAssertEqual(writers.count, 48)
            XCTAssertTrue(writers.contains(126))
            XCTAssertTrue(writers.contains(129))
            XCTAssertFalse(writers.contains(127), "The real CBZ must not become an NZCV writer")
            let original = try XCTUnwrap(RegionalSingleCMPConditionPlan.analyze(
                rowCount: function.instructions.count, cfg: cfg, writerRows: writers),
                "ORIGINAL_GRAPH_ANALYSIS_REQUIRED: unknown or malformed input is not the intended refusal")
            XCTAssertEqual(original.reachingWriterRows[205], Set([126]))
            XCTAssertFalse(original.hasUnknownOrigin[205])
            XCTAssertEqual(original.uniqueWriterWithoutInterveningWriter(before: 205), 126)

            // Only an IR jump target is rebound to generate internally consistent
            // alternate topology. Native bytes/sidecars and the original proof input
            // remain untouched. Do not call full canonical/physical proof and credit
            // its earlier source/IR mismatch as an intervening-writer refusal.
            XCTAssertEqual(function.instructions[311].operation,
                           .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x28d6c)]))
            var routingOnly = function
            routingOnly.instructions[311].operation = .intrinsic(destination: nil, name: "branch",
                                                                  arguments: [.immediate(0x28c70)])
            XCTAssertEqual(routingOnly.instructions.map(\.source), function.instructions.map(\.source))
            var restored = routingOnly
            restored.instructions[311].operation = function.instructions[311].operation
            XCTAssertEqual(restored, function)
            let alternate = CFGBuilder.buildCFG(instructions: routingOnly.instructions)
            XCTAssertEqual(alternate.blocks.count, cfg.blocks.count)
            XCTAssertFalse(alternate.hasUnresolvedTargets)
            XCTAssertTrue(alternate.irreducibleBlocks.isEmpty)
            XCTAssertEqual(alternate.blocks.map(\.instructionRange), cfg.blocks.map(\.instructionRange))
            XCTAssertEqual(cfg.blocks[94].successors, [81])
            XCTAssertEqual(alternate.blocks[94].successors, [61])
            XCTAssertEqual(alternate.blocks[61].predecessors, [34, 94])
            XCTAssertEqual(alternate.blocks[34].successors, [61, 35])
            XCTAssertEqual(alternate.blocks[35].successors, [95, 36])
            XCTAssertEqual(alternate.blocks[36].successors, [94, 37])
            var reached = Set<Int>(), pending = [alternate.entryIndex]
            while let block = pending.popLast() {
                if reached.insert(block).inserted { pending += alternate.blocks[block].successors }
            }
            XCTAssertEqual(reached, Set(alternate.blocks.indices), "No unreachable-block shortcut")
            // Direct 34 -> 61 carries CMP126. The alternate 34 -> 35 -> 36 -> 94
            // -> 61 path carries the actual intervening CMP129. No fake writer row.
            let ambiguous = try XCTUnwrap(RegionalSingleCMPConditionPlan.analyze(
                rowCount: function.instructions.count, cfg: alternate, writerRows: writers),
                "ALTERNATE_GRAPH_ANALYSIS_REQUIRED: refusal must reach the writer proof")
            XCTAssertEqual(ambiguous.reachingWriterRows[205], Set([126, 129]),
                           "The precise two real reaching writers are the negative witness")
            XCTAssertFalse(ambiguous.hasUnknownOrigin[205], "Not an uninitialized-entry refusal")
            XCTAssertNil(ambiguous.uniqueWriterWithoutInterveningWriter(before: 205),
                         "INTERVENING_NZCV_WRITER_MUST_REFUSE: no single CMP may authorize this B.EQ")
        }
    }

    private func writesNZCV(_ instruction: RegionalSwitchOracle.Instruction) throws -> Bool {
        switch instruction {
        case let .compare(op, _, _):
            guard ["cmp", "cmn", "tst"].contains(op) else {
                throw RegionalSwitchOracle.Failure.invalid("unclassified compare opcode: \(op)")
            }
            return true
        case let .arithmetic(op, _, _, _, _):
            switch op {
            case "adds", "subs": return true
            case "add", "sub", "and", "lsl": return false
            default: throw RegionalSwitchOracle.Failure.invalid("unclassified arithmetic opcode: \(op)")
            }
        case .call: return true
        case let .branch(predicate, _, _):
            guard ["always", "eq", "ne", "hs", "lo", "lt", "gt", "le", "ge", "hi", "ls", "cbz", "cbnz"].contains(predicate) else {
                throw RegionalSwitchOracle.Failure.invalid("unclassified branch predicate: \(predicate)")
            }
            return false
        case let .memory(op, _, _):
            guard ["ldr", "ldrb", "str", "ldp", "stp"].contains(op) else {
                throw RegionalSwitchOracle.Failure.invalid("unclassified memory opcode: \(op)")
            }
            return false
        case .move, .page, .relative, .indirectBranch, .returned: return false
        }
    }

}
