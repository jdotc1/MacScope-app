import Foundation
import XCTest
@testable import MacScope

final class DecompilerStructuringRecoveryTests:XCTestCase {
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


    // Legacy-output expectations: isolate from the process SSA setting (A62 legacy isolation).

    static func row(_ a:UInt64,_ m:String,_ o:String = "",_ c:String? = nil)->InstructionRow {
        .init(address:a,bytes:"00 00 00 00",mnemonic:m,operands:o,hasBreakpoint:false,comment:c)
    }
    static var sharedTail:[InstructionRow] {
        [row(0x8200,"cbz","x0, 0x820c","else arm"),
         row(0x8204,"nop","","then private"),row(0x8208,"b","0x821c"),
         row(0x820c,"cbz","x1, 0x8228"),row(0x8210,"cbz","x2, 0x8220"),
         row(0x8214,"nop"),row(0x8218,"b","0x821c"),
         row(0x821c,"nop","","shared head"),row(0x8220,"mov","x0, #0x3","shared middle"),
         row(0x8224,"b","0x8228"),row(0x8228,"ret")]
    }
    static var secondaryExit:[InstructionRow] {
        [row(0x2000,"cbz","x0, 0x2014","primary exit"),
         row(0x2004,"nop","","body"),row(0x2008,"cbz","x1, 0x2020","secondary exit"),
         row(0x200c,"nop","","latch work"),row(0x2010,"b","0x2000","back edge"),
         row(0x2014,"mov","x2, #0x1","primary continuation"),row(0x2018,"b","0x2028"),
         row(0x201c,"nop","","unreachable") /* removed below */,
         row(0x2020,"mov","x3, #0x2","secondary continuation"),row(0x2024,"b","0x2028"),
         row(0x2028,"ret")].filter { $0.address != 0x201c }
    }
    static var doubleGuard:[InstructionRow] {
        [row(0x3000,"cmp","x0, #0x0"),row(0x3004,"b.eq","0x3014"),
         row(0x3008,"cmp","x1, #0x0"),row(0x300c,"b.eq","0x3014"),
         row(0x3010,"mov","x2, #0x4","guarded side effect"),row(0x3014,"ret")]
    }
    /// Recovery ships off; opting in selects a valid region without an output race.
    func testRecoveryShipsOffAndDefaultsPrintThePreCP2Text() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            XCTAssertFalse(DecompilerOptions.default.recoverSharedTails)
            XCTAssertFalse(DecompilerOptions.default.recoverLoopExits)
            XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions)
            let f = MacIRBuilder().buildFunction(name: "_secondary", instructions: Self.secondaryExit)
            let shipped = PseudocodePrinter().print(function: f)
            XCTAssertEqual(shipped.structureFallback, .unsupportedRegion)
            XCTAssertTrue(shipped.text.contains("goto "))
            XCTAssertFalse(shipped.text.contains("cp2_"))
            let optedIn = PseudocodePrinter(options: .recoveryOn).print(function: f)
            XCTAssertNil(optedIn.structureFallback)
            XCTAssertNotNil(optedIn.regionTree)
        }
    }
    func testBoundedSharedTailRecoveryIsStructured() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let f=MacIRBuilder().buildFunction(name:"_shared",instructions:Self.sharedTail)
            let cfg=CFGBuilder.buildCFG(instructions:f.instructions)
            XCTAssertEqual(RegionTree.buildWithDiagnostics(cfg:cfg,instructions:f.instructions,collectDiagnostics:true).diagnostics.fatalVeto,.gotoLeafRejoiningDoubleReachable)
            let printed=PseudocodePrinter(options: .recoveryOn).print(function:f)
            XCTAssertNil(printed.structureFallback)
            XCTAssertNil(printed.regionTree)
            XCTAssertTrue(printed.text.contains("goto L_8228;"))
        }
    }
    func testSecondaryExitUsesTargetedLabelledTransfers() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let f=MacIRBuilder().buildFunction(name:"_secondary",instructions:Self.secondaryExit)
            let cfg=CFGBuilder.buildCFG(instructions:f.instructions)
            XCTAssertEqual(RegionTree.buildWithDiagnostics(cfg:cfg,instructions:f.instructions,collectDiagnostics:true).diagnostics.fatalVeto,.loopSecondaryExitNotInContinuation)
            let printed=PseudocodePrinter(options: .recoveryForSemantics).print(function:f)
            XCTAssertNil(printed.structureFallback)
            XCTAssertTrue(printed.text.contains("break exit_0x"))
            // A tail continue is the loop's natural fallthrough and can disappear.
            XCTAssertTrue(printed.text.contains("loop_0x2000: while (true)"))
            XCTAssertFalse(printed.text.contains("goto "))
        }
    }
    func testDoubleGuardRecoveryRetainsGuardedSideEffect() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let f=MacIRBuilder().buildFunction(name:"_guards",instructions:Self.doubleGuard)
            let printed=PseudocodePrinter(options: .recoveryOn).print(function:f)
            let cfg = CFGBuilder.buildCFG(instructions: f.instructions)
            let plan = RegionTree.recoveryPlan(cfg: cfg, instructions: f.instructions, options: .recoveryOn,
                                               veto: .conditionalDoubleGuardToJoin)
            XCTAssertNotNil(plan)
            XCTAssertTrue(plan.map { RegionTree.recoveryIsEquivalent($0.root, to: cfg) } ?? false)
            // The region path owns this fused double guard.
            XCTAssertNil(printed.structureFallback)
            XCTAssertNotNil(printed.regionTree)
            XCTAssertEqual(printed.text.components(separatedBy:"guarded side effect").count-1,1)
        }
    }

    func testAlreadyGotoFreeLegacyGuardIsNotReformatted() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let f = MacIRBuilder().buildFunction(name: "_guards", instructions: Self.doubleGuard)
            var legacy = DecompilerOptions.default
            legacy.recoverSharedTails = false
            legacy.recoverLoopExits = false
            legacy.recoverGuardRegions = false
            let before = PseudocodePrinter(options: legacy).print(function: f)
            XCTAssertFalse(before.text.contains("goto "))
            XCTAssertEqual(PseudocodePrinter(options: .recoveryOn).print(function: f).text, before.text)
        }
    }

    func testConcreteTextOracleChecksCatalogueLoop() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let edges = [[1, 2], [0, 3], [], []]
            let f = CP2GraphFixture.function(edges)
            let document = PseudocodePrinter(options: .recoveryForSemantics).print(function: f)
            XCTAssertNil(document.structureFallback)
            XCTAssertTrue(document.text.contains("loop_0x"))
            _ = try CP2TextOracle.parse(document, edges: edges)
            XCTAssertTrue(CP2TextOracle.equivalent(document, edges: edges))
        }
    }

    private func transform(_ node: RegionTree.RecoveryRegion,
                           _ edit: (RegionTree.RecoveryRegion) -> RegionTree.RecoveryRegion?) -> RegionTree.RecoveryRegion {
        if let replacement = edit(node) { return replacement }
        switch node {
        case .sequence(let children): return .sequence(children.map { transform($0, edit) })
        case .block(let index, let exits): return .block(index, exits: exits.map { transform($0, edit) })
        case .scope(let target, let body): return .scope(target: target, body: transform(body, edit))
        case .loop(let header, let body): return .loop(header: header, body: transform(body, edit))
        default: return node
        }
    }

    func testProofRejectsWrongPolarityDroppedVisitsAndWrongExits() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let f = CP2GraphFixture.function([[1, 2], [0, 3], [], []])
            let cfg = CFGBuilder.buildCFG(instructions: f.instructions)
            let plan = try XCTUnwrap(RegionTree.recoveryPlan(cfg: cfg, instructions: f.instructions,
                                                            options: .recoveryOn, veto: .loopMultipleExitTargets))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan.root, to: cfg))
            let reversed = transform(plan.root) {
                if case .block(let block, let exits) = $0, exits.count == 2 { return .block(block, exits: Array(exits.reversed())) }
                return nil
            }
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(reversed, to: cfg), "taken/fallthrough swap must fail")
            let dropped = transform(plan.root) {
                if case .block(let block, let exits) = $0, block == cfg.entryIndex { return .sequence(exits) }
                return nil
            }
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(dropped, to: cfg), "missing entry side effect must fail")
            let wrongExit = transform(plan.root) {
                if case .breakTo = $0 { return .breakTo(9999) }
                return nil
            }
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(wrongExit, to: cfg), "unbound target must fail")
            let wrongContinue = transform(plan.root) {
                // Natural tail continues may have been removed; inject an unbound
                // continue into an actual ordered exit rather than mutating nothing.
                if case .block(let index, let exits) = $0, !exits.isEmpty {
                    return .block(index, exits: [.continueAt(9999)] + exits.dropFirst())
                }
                return nil
            }
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(wrongContinue, to: cfg))
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(.sequence([plan.root, plan.root]), to: cfg),
                           "unreachable duplicated payload is not an accepted plan")
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(.loop(header: 0, body: .sequence([])), to: cfg))
        }
    }

    func testTextOracleRejectsMutatedConditionTransferAndPayload() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let edges = [[1, 2], [0, 3], [], []]
            let f = CP2GraphFixture.function(edges)
            let original = PseudocodePrinter(options: .recoveryForSemantics).print(function: f)
            XCTAssertTrue(CP2TextOracle.equivalent(original, edges: edges))
            var predicate = original
            let branch = try XCTUnwrap(predicate.lines.firstIndex { $0.text.contains("if (") })
            let oldOperator = predicate.lines[branch].text.contains("!=") ? "!=" : "=="
            let newOperator = oldOperator == "!=" ? "==" : "!="
            predicate.lines[branch].text = predicate.lines[branch].text.replacingOccurrences(of: oldOperator, with: newOperator)
            XCTAssertFalse(CP2TextOracle.equivalent(predicate, edges: edges))
            var exit = original
            let transfer = try XCTUnwrap(exit.lines.firstIndex { $0.text.contains("break exit_0x") })
            exit.lines[transfer].text = "break exit_0x9999;"
            XCTAssertFalse(CP2TextOracle.equivalent(exit, edges: edges))
            var payload = original
            let event = try XCTUnwrap(payload.lines.firstIndex { $0.source?.comment == "visit_0" })
            payload.lines[event].text = payload.lines[event].text.replacingOccurrences(of: "0x0;", with: "0x1;")
            XCTAssertFalse(CP2TextOracle.equivalent(payload, edges: edges))
            payload = original
            payload.lines.remove(at: event)
            XCTAssertFalse(CP2TextOracle.equivalent(payload, edges: edges))
            payload = original
            payload.lines.insert(payload.lines[event], at: event)
            XCTAssertFalse(CP2TextOracle.equivalent(payload, edges: edges))
        }
    }

    func testTailBudgetZeroRetainsExactLegacyBytes() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let f = MacIRBuilder().buildFunction(name: "_shared", instructions: Self.sharedTail)
            var disabled = DecompilerOptions.default
            disabled.recoverSharedTails = false
            var bounded = DecompilerOptions.recoveryOn
            bounded.sharedTailInstructionLimit = 0
            let legacy = PseudocodePrinter(options: disabled).print(function: f)
            let limited = PseudocodePrinter(options: bounded).print(function: f)
            XCTAssertEqual(limited.text, legacy.text)
            XCTAssertNil(limited.structureFallback)
            let cfg = CFGBuilder.buildCFG(instructions: f.instructions)
            let plan = try XCTUnwrap(RegionTree.recoveryPlan(cfg: cfg, instructions: f.instructions,
                                                            options: .recoveryOn, veto: .gotoLeafRejoiningDoubleReachable))
            XCTAssertFalse(plan.duplicatedBlocks.isEmpty)
            XCTAssertGreaterThan(plan.extraInstructionCount, 0)
            XCTAssertLessThanOrEqual(plan.extraInstructionCount, 64)
        }
    }

    func testIrreducibleAndUnresolvedGraphsNeverRecover() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let irreducible = CP2GraphFixture.function([[1, 2], [2], [1]])
            let cfg = CFGBuilder.buildCFG(instructions: irreducible.instructions)
            XCTAssertFalse(cfg.irreducibleBlocks.isEmpty)
            XCTAssertNil(RegionTree.recoveryPlan(cfg: cfg, instructions: irreducible.instructions,
                                                 options: .recoveryOn, veto: .loopMultipleExitTargets))
            var unresolved = cfg
            unresolved.irreducibleBlocks = []
            unresolved.hasUnresolvedTargets = true
            XCTAssertNil(RegionTree.recoveryPlan(cfg: unresolved, instructions: irreducible.instructions,
                                                 options: .recoveryOn, veto: .loopMultipleExitTargets))
        }
    }

    func testRecoveryOptionsReadDefaultsAndExplicitOff() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let name = "CP2Tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            XCTAssertEqual(DecompilerOptions(userDefaults: defaults), .default)
            for key in [DecompilerOptions.Key.recoverSharedTails, DecompilerOptions.Key.recoverLoopExits,
                        DecompilerOptions.Key.recoverGuardRegions] { defaults.set(false, forKey: key) }
            defaults.set(-99, forKey: DecompilerOptions.Key.sharedTailInstructionLimit)
            let options = DecompilerOptions(userDefaults: defaults)
            XCTAssertFalse(options.recoverSharedTails)
            XCTAssertFalse(options.recoverLoopExits)
            XCTAssertFalse(options.recoverGuardRegions)
            XCTAssertEqual(options.sharedTailInstructionLimit, 0)
        }
    }

    func testNestedLoopsKeepInnerAndOuterExitTargetsDistinct() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let edges = [[1, 5], [2, 4], [1, 3], [0, 4], [5], []]
            let f = CP2GraphFixture.function(edges)
            let cfg = CFGBuilder.buildCFG(instructions: f.instructions)
            XCTAssertGreaterThanOrEqual(cfg.loopHeaders.count, 2)
            let document = PseudocodePrinter(options: .recoveryForSemantics).print(function: f)
            XCTAssertNil(document.structureFallback)
            XCTAssertTrue(CP2TextOracle.equivalent(document, edges: edges))
            XCTAssertGreaterThanOrEqual(document.lines.filter { $0.text.contains(": while (true) {") }.count, 2)
        }
    }

    func testReachableGraphsThroughThreeNodesAndReversedBranchPolarity() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            var checked = 0
            for count in 1...3 {
                let choices = CP2GraphFixture.edgeChoices(count)
                let total = (0..<count).reduce(1) { value, _ in value * choices.count }
                for encoded in 0..<total {
                    var code = encoded, graph: [[Int]] = []
                    for _ in 0..<count { graph.append(choices[code % choices.count]); code /= choices.count }
                    guard CP2GraphFixture.reachable(graph) else { continue }
                    for edges in [graph, graph.map { Array($0.reversed()) }] {
                        let f = CP2GraphFixture.function(edges)
                        var old = DecompilerOptions.default
                        old.recoverSharedTails = false; old.recoverLoopExits = false; old.recoverGuardRegions = false
                        let before = PseudocodePrinter(options: old).print(function: f)
                        let after = PseudocodePrinter(options: .recoveryOn).print(function: f)
                        if before.structureFallback != nil && after.structureFallback == nil {
                            XCTAssertTrue(CP2TextOracle.equivalent(after, edges: edges), "n=\(count), code=\(encoded), edges=\(edges)")
                        } else { XCTAssertEqual(before.text, after.text) }
                        checked += 1
                    }
                }
            }
            XCTAssertEqual(checked, 286)
        }
    }
}
