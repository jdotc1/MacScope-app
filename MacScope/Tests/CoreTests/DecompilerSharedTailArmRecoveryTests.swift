import XCTest
@testable import MacScope

final class DecompilerSharedTailArmRecoveryTests: XCTestCase {
    private let edges = [[1, 2], [3], [3, 4], [4], []]

    func testBypassArmUsesBoundedProvenTailDuplication() throws {
        let function = CP2GraphFixture.function(edges)
        XCTAssertTrue(function.phis.isEmpty)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let diagnostics = RegionTree.buildWithDiagnostics(
            cfg: cfg, instructions: function.instructions, collectDiagnostics: true
        ).diagnostics
        XCTAssertEqual(diagnostics.fatalVeto, .gotoLeafRejoiningArmUnstructured)
        let veto = try XCTUnwrap(diagnostics.fatalVeto)
        let plan = try XCTUnwrap(RegionTree.recoveryPlan(
            cfg: cfg, instructions: function.instructions,
            options: .recoveryForSemantics, veto: veto
        ))
        let tailAddress = CP2GraphFixture.addresses(edges)[3]
        let tail = try XCTUnwrap(cfg.blocks.first {
            function.instructions[$0.startIndex].source.address == tailAddress
        })
        XCTAssertEqual(plan.originalVeto, .gotoLeafRejoiningArmUnstructured)
        XCTAssertEqual(plan.duplicatedBlocks, Set([tail.index]))
        XCTAssertEqual(plan.extraInstructionCount, 2)
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan.root, to: cfg))
    }

    func testArmRecoveryStillRequiresSharedTailOption() {
        let function = CP2GraphFixture.function(edges)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        var options = DecompilerOptions.recoveryForSemantics
        options.recoverSharedTails = false
        XCTAssertNil(RegionTree.recoveryPlan(
            cfg: cfg, instructions: function.instructions, options: options,
            veto: .gotoLeafRejoiningArmUnstructured
        ))
    }

    func testArmRecoveryRefusesIrreducibleGraph() {
        let function = CP2GraphFixture.function([[1, 2], [2], [1]])
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertFalse(cfg.irreducibleBlocks.isEmpty)
        XCTAssertNil(RegionTree.recoveryPlan(
            cfg: cfg, instructions: function.instructions, options: .recoveryForSemantics,
            veto: .gotoLeafRejoiningArmUnstructured
        ))
    }

    func testArmRecoveryRefusesUnresolvedTargets() {
        let function = CP2GraphFixture.function(edges)
        var cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        cfg.hasUnresolvedTargets = true
        XCTAssertNil(RegionTree.recoveryPlan(
            cfg: cfg, instructions: function.instructions, options: .recoveryForSemantics,
            veto: .gotoLeafRejoiningArmUnstructured
        ))
    }

    func testTailOneInstructionOverBudgetRetainsFallbackBytes() {
        let function = CP2GraphFixture.function(edges)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        // The shared assignment plus its branch costs two instructions.
        var bounded = DecompilerOptions.recoveryForSemantics
        bounded.sharedTailInstructionLimit = 1
        XCTAssertNil(RegionTree.recoveryPlan(
            cfg: cfg, instructions: function.instructions, options: bounded,
            veto: .gotoLeafRejoiningArmUnstructured
        ))
        var disabled = bounded
        disabled.recoverSharedTails = false
        let legacy = PseudocodePrinter(options: disabled).print(function: function)
        let limited = PseudocodePrinter(options: bounded).print(function: function)
        XCTAssertEqual(legacy.structureFallback, .unsupportedRegion)
        XCTAssertEqual(limited.structureFallback, legacy.structureFallback)
        XCTAssertEqual(limited.lines, legacy.lines)
    }
}
