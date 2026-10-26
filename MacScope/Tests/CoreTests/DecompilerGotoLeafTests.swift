import XCTest
@testable import MacScope

final class DecompilerGotoLeafTests: XCTestCase {
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

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func function(_ name: String, _ rows: [InstructionRow]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: name, instructions: rows)
    }

    private func forcedDocument(
        _ name: String,
        rows: [InstructionRow],
        region: Region,
        options: DecompilerOptions = .default
    ) -> PseudocodeDocument {
        PseudocodePrinter(options: options).print(
            function: function(name, rows),
            forcedRegionForTesting: region
        )
    }

    private func legacyDocument(
        _ name: String,
        rows: [InstructionRow],
        options: DecompilerOptions = .default
    ) -> PseudocodeDocument {
        PseudocodePrinter(options: options).print(function: function(name, rows))
    }

    private func legacyGotoFormDocument(_ name: String, rows: [InstructionRow]) -> PseudocodeDocument {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        return legacyDocument(name, rows: rows, options: options)
    }

    private func firstRegion(
        in node: PseudocodeRegionNode?,
        kind: PseudocodeRegionNode.Kind
    ) -> PseudocodeRegionNode? {
        guard let node else { return nil }
        if node.kind == kind { return node }
        for child in node.children {
            if let match = firstRegion(in: child, kind: kind) {
                return match
            }
        }
        return nil
    }

    private func regions(
        in node: PseudocodeRegionNode?,
        kind: PseudocodeRegionNode.Kind
    ) -> [PseudocodeRegionNode] {
        guard let node else { return [] }
        var matches = node.kind == kind ? [node] : []
        for child in node.children {
            matches.append(contentsOf: regions(in: child, kind: kind))
        }
        return matches
    }

    private func explicitGotoCount(_ document: PseudocodeDocument) -> Int {
        document.lines.reduce(0) { count, line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return count + (trimmed.hasPrefix("goto ") || trimmed.contains(" goto ") ? 1 : 0)
        }
    }

    private func sourceAddressCounts(_ document: PseudocodeDocument) -> [UInt64: Int] {
        var counts: [UInt64: Int] = [:]
        for line in document.lines {
            guard let address = line.sourceAddress else { continue }
            counts[address, default: 0] += 1
        }
        return counts
    }

    private func regionDiagnosticsText(_ rows: [InstructionRow]) -> String {
        let function = function("_diagnostics", rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        return RegionTree
            .buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
            .diagnostics
            .siteCountsText()
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func e2RejoiningTailRows(base: UInt64 = 0x8000, sharedMnemonic: String = "mov", sharedOperands: String = "x0, #0x2", sharedComment: String = "shared tail") -> [InstructionRow] {
        [
            row(base + 0x00, "cbz", "x0, 0x\(String(base + 0x0c, radix: 16))", "else arm"),
            row(base + 0x04, "nop", "", "then private"),
            row(base + 0x08, "b", "0x\(String(base + 0x18, radix: 16))", "then to shared"),
            row(base + 0x0c, "cbz", "x1, 0x\(String(base + 0x20, radix: 16))", "else skips shared"),
            row(base + 0x10, "nop", "", "else private"),
            row(base + 0x14, "b", "0x\(String(base + 0x18, radix: 16))", "else to shared"),
            row(base + 0x18, sharedMnemonic, sharedOperands, sharedComment),
            row(base + 0x1c, "b", "0x\(String(base + 0x20, radix: 16))", "rejoin continuation"),
            row(base + 0x20, "nop", "", "continuation"),
            row(base + 0x24, "ret", "")
        ]
    }

    func testGotoLeafCapabilityRendersGuardAndLeafThroughLegacyStructurer() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x1000, "cmp", "x0, #0x0"),
                row(0x1004, "nop", "", "between compare and branch"),
                row(0x1008, "b.eq", "0x1010", "guard"),
                row(0x100c, "nop", "", "wrapper"),
                row(0x1010, "ret", "")
            ]

            let document = forcedDocument(
                "_goto_leaf_guard",
                rows: rows,
                region: .sequence([.block(blockIndex: 0), .gotoLeaf(blocks: [1, 2])])
            )
            let legacy = legacyGotoFormDocument("_goto_leaf_guard", rows: rows)

            XCTAssertNil(document.structureFallback)
            XCTAssertNotNil(firstRegion(in: document.regionTree, kind: .gotoLeaf))
            XCTAssertEqual(sourceAddressCounts(document), sourceAddressCounts(legacy))
            GotoLabelWellFormednessTests.assertWellFormed(document.text)
            GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x1010, condition: "arg0 == 0x0")
            XCTAssertEqual(document.text, legacy.text)
        }
    }

    func testGotoLeafRejectsNonContiguousBlockSetAndFallsBack() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x2000, "cbz", "x0, 0x200c", "split"),
                row(0x2004, "nop", "", "leaf start"),
                row(0x2008, "b", "0x2014"),
                row(0x200c, "nop", "", "interleaved block"),
                row(0x2010, "b", "0x2014"),
                row(0x2014, "ret", "")
            ]

            let document = forcedDocument(
                "_goto_leaf_noncontiguous",
                rows: rows,
                region: .sequence([.block(blockIndex: 0), .gotoLeaf(blocks: [1, 3])])
            )
            let legacy = legacyGotoFormDocument("_goto_leaf_noncontiguous", rows: rows)

            XCTAssertNil(document.regionTree)
            XCTAssertEqual(document.structureFallback, .unsupportedRegion)
            XCTAssertEqual(document.text, legacy.text)
        }
    }

    func testGotoLeafRejectsDuplicateBlockPartitionAndFallsBack() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x3000, "nop", "", "once"),
                row(0x3004, "ret", "")
            ]

            let document = forcedDocument(
                "_goto_leaf_duplicate",
                rows: rows,
                region: .sequence([.block(blockIndex: 0), .gotoLeaf(blocks: [0])])
            )
            let legacy = legacyGotoFormDocument("_goto_leaf_duplicate", rows: rows)

            XCTAssertNil(document.regionTree)
            XCTAssertEqual(document.structureFallback, .unsupportedRegion)
            XCTAssertEqual(document.text, legacy.text)
        }
    }

    func testGotoLeafRejectsGotoCountIncreaseAndFallsBack() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x4000, "cmp", "x0, #0x0"),
                row(0x4004, "b.eq", "0x400c", "skip"),
                row(0x4008, "nop", "", "body"),
                row(0x400c, "ret", "")
            ]

            let document = forcedDocument(
                "_goto_leaf_count",
                rows: rows,
                region: .sequence([.block(blockIndex: 0), .gotoLeaf(blocks: [1])])
            )
            let legacy = legacyGotoFormDocument("_goto_leaf_count", rows: rows)

            XCTAssertNil(document.regionTree)
            XCTAssertEqual(document.structureFallback, .unsupportedRegion)
            XCTAssertEqual(document.text, legacy.text)
        }
    }

    func testGotoLeafRendersUnknownInstructionVerbatim() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x5000, "b", "0x5004"),
                row(0x5004, "mystery", "x0, x0", "unknown in leaf"),
                row(0x5008, "ret", "")
            ]

            let document = forcedDocument(
                "_unknown_leaf",
                rows: rows,
                region: .sequence([.block(blockIndex: 0), .gotoLeaf(blocks: [1])])
            )

            XCTAssertNil(document.structureFallback)
            XCTAssertNotNil(firstRegion(in: document.regionTree, kind: .gotoLeaf))
            GotoLabelWellFormednessTests.assertWellFormed(document.text)
            XCTAssertTrue(document.lines(sourcedAt: 0x5004).contains { $0.text.contains("__unknown(\"mystery\", \"x0, x0\")") })
            XCTAssertTrue(document.text.contains("unresolved_return_contract"))
        }
    }

    func testGotoLeafDCEUsesFreshLeafState() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x6000, "ret", ""),
                row(0x6004, "nop", "", "fresh leaf after return")
            ]
            var options = DecompilerOptions.default
            options.deadCodeElimination = true

            let document = forcedDocument(
                "_dce_leaf",
                rows: rows,
                region: .sequence([.block(blockIndex: 0), .gotoLeaf(blocks: [1])]),
                options: options
            )
            let legacy = legacyDocument("_dce_leaf", rows: rows, options: options)

            XCTAssertNil(document.structureFallback)
            XCTAssertTrue(document.text.contains("__nop(); // fresh leaf after return"))
            XCTAssertFalse(legacy.text.contains("__nop(); // fresh leaf after return"))
        }
    }

    func testE1TerminalSharedExitGotoLeafStructuresRawGuards() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x7000, "cbnz", "x0, 0x7014", "guard fail"),
                row(0x7004, "cbz", "x1, 0x7010", "success guard"),
                row(0x7008, "nop", "", "continuation"),
                row(0x700c, "b", "0x7014"),
                row(0x7010, "ret", ""),
                row(0x7014, "mov", "x0, #0x1", "fail"),
                row(0x7018, "ret", "")
            ]

            let document = legacyDocument("_e1_terminal_shared_exit", rows: rows)
            let legacy = legacyGotoFormDocument("_e1_terminal_shared_exit", rows: rows)

            XCTAssertNil(document.structureFallback)
            XCTAssertGreaterThanOrEqual(regions(in: document.regionTree, kind: .gotoLeaf).count, 1)
            XCTAssertLessThanOrEqual(explicitGotoCount(document), explicitGotoCount(legacy))
            GotoLabelWellFormednessTests.assertWellFormed(document.text)
            GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x7014, condition: "arg0 != 0x0")
            GotoLabelWellFormednessTests.assertGoto(document.text, target: 0x7010, condition: "arg1 == 0x0")
        }
    }

    func testE2RejoiningTailGotoLeafStructuresWithoutDiagnostics() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = e2RejoiningTailRows()
            let document = legacyDocument("_e2_rejoining_tail", rows: rows)
            let legacy = legacyGotoFormDocument("_e2_rejoining_tail", rows: rows)

            XCTAssertNil(document.structureFallback)
            if SSAPropertyAssertions.enabled {
                let lifted = function("_rejoining_phi", rows)
                XCTAssertNotNil(document.regionTree)
                XCTAssertNotNil(firstRegion(in: document.regionTree, kind: .gotoLeaf))
                SSARenderExpectation.assertRejoiningPhi(lifted, block: 0x8000 + 0x20,
                    entryPredecessor: 0x8000 + 0x0c, definingPredecessor: 0x8000 + 0x1c,
                    definitionAddress: 0x8000 + 0x18)
                SSARenderExpectation.assertEdgeCopyAgreement(document, legacy, function: lifted)
            } else {
                XCTAssertNil(document.regionTree)
            }
            XCTAssertLessThanOrEqual(explicitGotoCount(document), explicitGotoCount(legacy))
            XCTAssertTrue(document.text.contains("if (arg1 == 0x0) {"))
            if !SSAPropertyAssertions.enabled {
                XCTAssertTrue(document.text.contains("goto L_8020;"))
            }
            XCTAssertEqual(occurrenceCount(of: "shared tail", in: document.text), 1)
            XCTAssertEqual(occurrenceCount(of: "continuation", in: document.text), 2)
        }
    }

    func testE2RejoiningTailRejectsNonContiguousSharedTailAndFallsBack() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x8100, "cbz", "x0, 0x810c", "else arm"),
                row(0x8104, "nop", "", "then private"),
                row(0x8108, "b", "0x8118", "then to shared head"),
                row(0x810c, "cbz", "x1, 0x8120", "else skips shared"),
                row(0x8110, "nop", "", "else private"),
                row(0x8114, "b", "0x8118", "else to shared head"),
                row(0x8118, "mov", "x0, #0x1", "shared head"),
                row(0x811c, "b", "0x8128", "shared jumps over continuation"),
                row(0x8120, "nop", "", "interleaved continuation"),
                row(0x8124, "b", "0x8130", "continuation to join"),
                row(0x8128, "add", "x0, x0, #0x1", "shared tail"),
                row(0x812c, "b", "0x8130", "shared rejoins"),
                row(0x8130, "ret", "")
            ]
            let document = legacyDocument("_e2_rejoining_noncontiguous", rows: rows)
            let legacy = legacyGotoFormDocument("_e2_rejoining_noncontiguous", rows: rows)

            XCTAssertNil(document.regionTree)
            XCTAssertEqual(document.structureFallback, .unsupportedRegion)
            XCTAssertEqual(document.text, legacy.text)
            XCTAssertTrue(regionDiagnosticsText(rows).contains("gotoLeafRejoiningNonContiguous:1"))
        }
    }

    func testRejoiningPrivateConditionalPreservesBothSubtreesWithoutCopies() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x8500, "cbz", "x0, 0x8518", "outer guard"),
                row(0x8504, "cbz", "x1, 0x8510", "private split"),
                row(0x8508, "cbz", "x2, 0x8520", "fall subtree guard"),
                row(0x850c, "b", "0x8528", "fall subtree skips leaf"),
                row(0x8510, "cbz", "x3, 0x8520", "taken subtree guard"),
                row(0x8514, "b", "0x8528", "taken subtree skips leaf"),
                row(0x8518, "cbz", "x4, 0x8528", "outer else guard"),
                row(0x851c, "b", "0x8520"),
                row(0x8520, "nop", "", "shared effect"),
                row(0x8524, "b", "0x8528"),
                row(0x8528, "nop", "", "continuation effect"),
                row(0x852c, "ret", "")
            ]
            var lifted = MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "_rejoining_private_conditionals", instructions: rows)
            lifted.ssaEnabled = true
            let document = PseudocodePrinter().print(function: lifted)
            var flatOptions = DecompilerOptions.default
            flatOptions.structureControlFlow = false
            let flat = PseudocodePrinter(options: flatOptions).print(function: lifted)

            XCTAssertTrue(lifted.instructions.allSatisfy { $0.source.syntheticPhiEdge == nil })
            XCTAssertNil(document.structureFallback)
            XCTAssertNotNil(document.regionTree)
            XCTAssertGreaterThanOrEqual(regions(in: document.regionTree, kind: .ifThenElse).count, 2)
            for address: UInt64 in [0x8500, 0x8504, 0x8508, 0x850c, 0x8510, 0x8514, 0x8518] {
                XCTAssertEqual(sourceAddressCounts(document)[address], 1, "private control source \(address)")
            }
            XCTAssertEqual(occurrenceCount(of: "shared effect", in: document.text), 1)
            XCTAssertEqual(occurrenceCount(of: "continuation effect", in: document.text), 1)
            XCTAssertLessThanOrEqual(explicitGotoCount(document), explicitGotoCount(flat))
        }
    }

    func testRejoiningPrivatePrefixEmitsCommonSuccessorOnce() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x8700, "cbz", "x0, 0x871c", "outer guard"),
                row(0x8704, "cbz", "x1, 0x8710", "skip private prefix"),
                row(0x8708, "nop", "", "exclusive effect"),
                row(0x870c, "b", "0x8710"),
                row(0x8710, "cbz", "x2, 0x8724", "common private guard"),
                row(0x8714, "nop", "", "common private effect"),
                row(0x8718, "b", "0x872c", "private skips leaf"),
                row(0x871c, "cbz", "x3, 0x872c", "outer else guard"),
                row(0x8720, "b", "0x8724"),
                row(0x8724, "nop", "", "shared effect"),
                row(0x8728, "b", "0x872c"),
                row(0x872c, "ret", "")
            ]
            var lifted = MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "_rejoining_private_prefix", instructions: rows)
            lifted.ssaEnabled = true
            let document = PseudocodePrinter().print(function: lifted)
            var flatOptions = DecompilerOptions.default
            flatOptions.structureControlFlow = false
            let flat = PseudocodePrinter(options: flatOptions).print(function: lifted)

            XCTAssertNil(document.structureFallback)
            XCTAssertNotNil(document.regionTree)
            XCTAssertGreaterThanOrEqual(regions(in: document.regionTree, kind: .ifThen).count, 1)
            for address: UInt64 in [0x8700, 0x8704, 0x8710, 0x8718, 0x871c] {
                XCTAssertEqual(sourceAddressCounts(document)[address], 1, "private control source \(address)")
            }
            for effect in ["exclusive effect", "common private effect", "shared effect"] {
                XCTAssertEqual(occurrenceCount(of: effect, in: document.text), 1)
            }
            XCTAssertLessThanOrEqual(explicitGotoCount(document), explicitGotoCount(flat))
        }
    }

    private func sharedEntrySwitchFunction() -> MacIRFunction {
        let rows = [
            row(0x8800, "nop", "", "switch"),
            row(0x8804, "nop", "", "first case"),
            row(0x8808, "b", "0x8818"),
            row(0x880c, "cbz", "x0, 0x881c", "second case"),
            row(0x8810, "b", "0x8818"),
            row(0x8814, "b", "0x881c", "default"),
            row(0x8818, "nop", "", "shared head"),
            row(0x881c, "ret", "", "shared middle")
        ]
        var result = MacIRBuilder(ssaEnabled: false).buildFunction(
            name: "_shared_entry_switch", instructions: rows)
        result.ssaEnabled = true
        result.instructions[0].operation = .switchDispatch(index: .immediate(2), cases: [
            .init(value: 0, target: .immediate(0x8804)),
            .init(value: 1, target: .immediate(0x880c)),
            .init(value: 2, target: .immediate(0x8804)),
            .init(value: 3, target: .immediate(0x8814))
        ], defaultTarget: .immediate(0x8814))
        result.cfg = nil
        return result
    }

    private func recoveryBlockCounts(_ root: RegionTree.RecoveryRegion) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        func visit(_ node: RegionTree.RecoveryRegion) {
            switch node {
            case let .sequence(parts): parts.forEach(visit)
            case let .block(block, exits):
                counts[block, default: 0] += 1
                exits.forEach(visit)
            case let .scope(_, body), let .loop(_, body): visit(body)
            case .breakTo, .continueAt: break
            }
        }
        visit(root)
        return counts
    }

    func testSSARecoveryOwnsMultipleSharedEntriesAndSwitchAliasesOnce() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let function = sharedEntrySwitchFunction()
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            let plan = try XCTUnwrap(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))

            XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan, to: cfg))
            XCTAssertEqual(recoveryBlockCounts(plan),
                Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.index, 1) }))
            XCTAssertEqual(cfg.blocks[0].successors.map {
                function.instructions[cfg.blocks[$0].startIndex].source.address
            }, [0x8804, 0x880c, 0x8814])
            var reordered = cfg
            reordered.blocks[0].successors.swapAt(0, 1)
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(plan, to: reordered))
            XCTAssertNil(RegionTree.ssaRecoveryPlan(function: function, cfg: reordered))
        }
    }

    func testSSARecoveryRejectsUnknownSwitchTargetsAndUnfoldedPredicates() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            var function = sharedEntrySwitchFunction()
            function.instructions[0].operation = .switchDispatch(index: .immediate(2), cases: [
                .init(value: 0, target: .immediate(0x8804))
            ], defaultTarget: .immediate(0x999c))
            var cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertTrue(cfg.hasUnresolvedTargets)
            XCTAssertNil(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
            cfg.hasUnresolvedTargets = false
            XCTAssertNil(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg),
                         "exact target validation must not depend solely on the unresolved bit")

            function = sharedEntrySwitchFunction()
            let branch = function.instructions.firstIndex { $0.source.address == 0x880c }!
            function.instructions[branch].operation = .intrinsic(
                destination: nil, name: "branch_eq", arguments: [.immediate(0x881c)])
            cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertFalse(cfg.hasUnresolvedTargets)
            XCTAssertNil(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
        }
    }

    func testSSARecoveryPreservesLoopEdgesAndFlagOffBoundary() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            var function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_original_loop", instructions: [
                row(0x8900, "nop", "", "entry"),
                row(0x8904, "add", "x1, x1, #1", "loop payload"),
                row(0x8908, "cbnz", "x0, 0x8904", "backedge"),
                row(0x890c, "ret", "")
            ])
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertNil(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
            function.ssaEnabled = true
            let plan = try XCTUnwrap(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan, to: cfg))
            XCTAssertEqual(recoveryBlockCounts(plan),
                Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.index, 1) }))
            XCTAssertEqual(cfg.backEdges.count, 1)
        }
    }

    func testSSARecoveryKeepsCallFallthroughAdjacentWithSharedEntry() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(
                name: "_shared_call_fallthrough", instructions: [
                    row(0x8a00, "cbz", "x0, 0x8a10"),
                    row(0x8a04, "cbz", "x1, 0x8a0c"),
                    row(0x8a08, "blr", "x8"),
                    row(0x8a0c, "ret", ""),
                    row(0x8a10, "cbz", "x2, 0x8a08"),
                    row(0x8a14, "b", "0x8a0c")
                ])
            let cfg = try XCTUnwrap(function.cfg).compatibilityCFG
            let plan = try XCTUnwrap(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan, to: cfg))
            XCTAssertEqual(recoveryBlockCounts(plan),
                Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.index, 1) }))
            var order: [Int] = []
            var exitsByBlock: [Int: [RegionTree.RecoveryRegion]] = [:]
            func visit(_ node: RegionTree.RecoveryRegion) {
                switch node {
                case let .sequence(parts): parts.forEach(visit)
                case let .scope(_, body), let .loop(_, body): visit(body)
                case let .block(block, exits):
                    order.append(block)
                    exitsByBlock[block] = exits
                    exits.forEach(visit)
                case .breakTo, .continueAt: break
                }
            }
            visit(plan)
            let call = try XCTUnwrap(cfg.blocks.first {
                function.instructions[$0.startIndex].source.address == 0x8a08
            }?.index)
            let terminal = try XCTUnwrap(cfg.blocks.first {
                function.instructions[$0.startIndex].source.address == 0x8a0c
            }?.index)
            let position = try XCTUnwrap(order.firstIndex(of: call))
            XCTAssertEqual(order.dropFirst(position + 1).first, terminal)
            let callExit = try XCTUnwrap(exitsByBlock[call]?.first)
            guard case let .sequence(parts) = callExit else {
                return XCTFail("physical call fallthrough must not acquire a transfer")
            }
            XCTAssertTrue(parts.isEmpty)
            let emission = try XCTUnwrap(PseudocodeSSARecoveryEmitter.emit(
                function: function, cfg: cfg, plan: plan, copies: [:], depth: 0, lineOffset: 0,
                rendering: .init(block: { _, _, _ in [] }, value: { "\($0)" },
                    condition: { _, _ in "condition" }, copy: { _ in "copy" },
                    comment: { _ in "" }, cancelled: { false })))
            XCTAssertTrue(emission.fragments.contains {
                $0.text.trimmingCharacters(in: .whitespaces) == "L_8a0c:"
            })
            XCTAssertTrue(emission.fragments.contains {
                $0.source?.address == 0x8a04 && $0.text.contains("goto L_8a0c")
            })
            XCTAssertTrue(emission.fragments.contains {
                $0.source?.address == 0x8a14 && $0.text.contains("goto L_8a0c")
            })
        }
    }

    func testSSARecoveryLabelsRetainOriginalBlockEntrySource() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(
                name: "_label_source", instructions: [
                    row(0x8c00, "cbz", "x0, 0x8c10"),
                    row(0x8c04, "cbz", "x1, 0x8c0c"),
                    row(0x8c08, "blr", "x8"),
                    row(0x8c0c, "ret", ""),
                    row(0x8c10, "cbz", "x2, 0x8c08"),
                    row(0x8c14, "b", "0x8c0c")
                ])
            let cfg = try XCTUnwrap(function.cfg).compatibilityCFG
            let plan = try XCTUnwrap(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
            let emission = try XCTUnwrap(PseudocodeSSARecoveryEmitter.emit(
                function: function, cfg: cfg, plan: plan, copies: [:], depth: 0, lineOffset: 0,
                rendering: .init(block: { _, _, _ in [] }, value: { "\($0)" },
                    condition: { _, _ in "condition" }, copy: { _ in "copy" },
                    comment: { _ in "" }, cancelled: { false })))
            let labels = emission.fragments.filter {
                $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("L_")
            }
            XCTAssertFalse(labels.isEmpty, "The fixture must exercise residual target labels")
            for label in labels {
                let source = try XCTUnwrap(label.source, "Labels retain their original block-entry identity")
                let block = try XCTUnwrap(cfg.blocks.first {
                    function.instructions[$0.startIndex].source.address == source.address
                })
                XCTAssertEqual(source, function.instructions[block.startIndex].source)
                XCTAssertEqual(label.text.trimmingCharacters(in: .whitespaces),
                               "L_\(String(source.address, radix: 16)):")
                XCTAssertNil(source.syntheticPhiEdge, "An original label must not borrow a synthetic copy identity")
            }
        }
    }

    func testSSARecoveryLabelUsesFollowingTransferWithoutRedundantNullStatement() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(
                name: "_label_transfer", instructions: [
                    row(0x8d00, "cbz", "x0, 0x8d08"),
                    row(0x8d04, "b", "0x8d0c"),
                    row(0x8d08, "b", "0x8d04"),
                    row(0x8d0c, "ret", "")
                ])
            let cfg = try XCTUnwrap(function.cfg).compatibilityCFG
            let plan = RegionTree.RecoveryRegion.sequence(cfg.blocks.map { block in
                .block(block.index, exits: block.successors.map { .breakTo($0) })
            })
            let emission = try XCTUnwrap(PseudocodeSSARecoveryEmitter.emit(
                function: function, cfg: cfg, plan: plan, copies: [:], depth: 0, lineOffset: 0,
                rendering: .init(block: { _, _, _ in [] }, value: { "\($0)" },
                    condition: { _, _ in "condition" }, copy: { _ in "copy" },
                    comment: { _ in "" }, cancelled: { false })))
            let fragments = emission.fragments
            let transferLabel = try XCTUnwrap(fragments.firstIndex {
                $0.text.trimmingCharacters(in: .whitespaces) == "L_8d04:"
            })
            XCTAssertEqual(fragments[transferLabel + 1].text.trimmingCharacters(in: .whitespaces),
                           "goto L_8d0c;")
            XCTAssertEqual(fragments[transferLabel + 1].source?.address, 0x8d04)
            let terminalLabel = try XCTUnwrap(fragments.firstIndex {
                $0.text.trimmingCharacters(in: .whitespaces) == "L_8d0c:"
            })
            XCTAssertEqual(fragments[terminalLabel + 1].text.trimmingCharacters(in: .whitespaces), ";",
                           "An empty labelled payload without a following transfer still needs a C statement")
        }
    }

    func testSSARecoveryEmitsCaseOnlyDispatchWithSeparateGuardDefault() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(
                name: "_guarded_case_dispatch", jumpTables: [0x8b08: [0x8b0c, 0x8b10]],
                instructions: [
                    row(0x8b00, "cmp", "w0, #1"),
                    row(0x8b04, "b.hi", "0x8b14"),
                    row(0x8b08, "br", "x8"),
                    row(0x8b0c, "b", "0x8b18"),
                    row(0x8b10, "b", "0x8b18"),
                    row(0x8b14, "b", "0x8b18"),
                    row(0x8b18, "ret", "")
                ])
            let cfg = try XCTUnwrap(function.cfg).compatibilityCFG
            let dispatch = try XCTUnwrap(cfg.blocks.first {
                function.instructions[$0.startIndex].source.address == 0x8b08
            })
            let terminal = function.instructions[dispatch.endIndex - 1]
            guard case let .switchDispatch(_, cases, defaultTarget) = terminal.operation else {
                return XCTFail("resolved machine table must retain typed switch metadata")
            }
            XCTAssertEqual(cases.map { CFGBuilder.address(of: $0.target) }, [0x8b0c, 0x8b10])
            XCTAssertEqual(defaultTarget.flatMap { CFGBuilder.address(of: $0) }, 0x8b14)
            XCTAssertEqual(dispatch.successors.map {
                function.instructions[cfg.blocks[$0].startIndex].source.address
            }, [0x8b0c, 0x8b10])
            let plan = try XCTUnwrap(RegionTree.ssaRecoveryPlan(function: function, cfg: cfg))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan, to: cfg))
            let emission = try XCTUnwrap(PseudocodeSSARecoveryEmitter.emit(
                function: function, cfg: cfg, plan: plan, copies: [:], depth: 0, lineOffset: 0,
                rendering: .init(block: { _, _, _ in [] }, value: { "\($0)" },
                    condition: { _, _ in "condition" }, copy: { _ in "copy" },
                    comment: { _ in "" }, cancelled: { false })))
            XCTAssertFalse(emission.fragments.contains {
                $0.source?.address == 0x8b08 && $0.text.contains("goto L_8b14")
            })
            let guardBlock = try XCTUnwrap(cfg.blocks.first {
                function.instructions[$0.endIndex - 1].source.address == 0x8b04
            })
            XCTAssertEqual(guardBlock.successors.map {
                function.instructions[cfg.blocks[$0].startIndex].source.address
            }, [0x8b14, 0x8b08])
            XCTAssertTrue(emission.fragments.contains {
                $0.source?.address == 0x8b04 && $0.text.contains("if (condition)")
            })
        }
    }

    private func loopRejoiningTailRows(reenterBeforeLatch: Bool) -> [InstructionRow] {
        let prefix = [
            row(0x8600, "nop", "", "entry"),
            row(0x8604, "cbz", "x0, 0x8614", "loop private fork"),
            row(0x8608, "cbz", "x1, 0x861c", "first arm reaches shared"),
            row(0x860c, "nop", "", "first private effect"),
            row(0x8610, "b", "0x8624", "first arm skips shared"),
            row(0x8614, "cbz", "x2, 0x8624", "second arm skips shared"),
            row(0x8618, "b", "0x861c", "second arm reaches shared"),
            row(0x861c, "nop", "", "shared effect"),
            row(0x8620, "b", "0x8624", "shared reaches continuation")
        ]
        if reenterBeforeLatch {
            return prefix + [
                row(0x8624, "cbnz", "x5, 0x861c", "reenter shared before latch"),
                row(0x8628, "cbnz", "x3, 0x8604", "next iteration"),
                row(0x862c, "ret", "")
            ]
        }
        return prefix + [
            row(0x8624, "cbnz", "x3, 0x8604", "next iteration"),
            row(0x8628, "ret", "")
        ]
    }

    func testRejoiningTailStopsReachabilityAtLoopBoundary() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let lifted = MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "_loop_rejoining_tail", instructions: loopRejoiningTailRows(reenterBeforeLatch: false))
            let cfg = CFGBuilder.buildCFG(instructions: lifted.instructions)
            let legacy = RegionTree.buildWithDiagnostics(
                cfg: cfg, instructions: lifted.instructions, collectDiagnostics: true)
            let bounded = RegionTree.buildWithDiagnostics(
                cfg: cfg, instructions: lifted.instructions, collectDiagnostics: true,
                allowRejoiningContinuationGotos: true)

            XCTAssertTrue(legacy.diagnostics.siteCountsText().contains("gotoLeafRejoiningDoubleReachable"))
            XCTAssertNil(bounded.diagnostics.fatalVeto)
            let region = try XCTUnwrap(bounded.region)
            var owners: [Int: Int] = [:]
            var loopCount = 0
            var sharedLeafCount = 0
            func claimCondition(_ condition: BranchCondition) {
                guard let block = cfg.blocks.first(where: { $0.instructionRange.contains(condition.branchIndex) }) else {
                    XCTFail("condition has no source block")
                    return
                }
                owners[block.index, default: 0] += 1
            }
            func visit(_ node: Region) {
                switch node {
                case let .sequence(items):
                    items.forEach(visit)
                case let .block(block):
                    owners[block, default: 0] += 1
                case let .gotoLeaf(blocks):
                    for block in blocks {
                        owners[block, default: 0] += 1
                        if lifted.instructions[cfg.blocks[block].startIndex].source.address == 0x861c {
                            sharedLeafCount += 1
                        }
                    }
                case let .ifThen(condition, body, _, _):
                    claimCondition(condition)
                    visit(body)
                case let .ifThenElse(condition, thenBody, elseBody, _):
                    claimCondition(condition)
                    visit(thenBody)
                    visit(elseBody)
                case let .doWhileLoop(body, condition):
                    loopCount += 1
                    claimCondition(condition)
                    visit(body)
                default:
                    XCTFail("unexpected region in bounded loop fixture")
                }
            }
            visit(region)
            XCTAssertEqual(loopCount, 1)
            XCTAssertEqual(sharedLeafCount, 1)
            XCTAssertEqual(owners, Dictionary(uniqueKeysWithValues: cfg.blocks.map { ($0.index, 1) }))
        }
    }

    func testRejoiningTailStillRejectsReentryBeforeLoopBoundary() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let lifted = MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "_loop_rejoining_reentry", instructions: loopRejoiningTailRows(reenterBeforeLatch: true))
            let cfg = CFGBuilder.buildCFG(instructions: lifted.instructions)
            let result = RegionTree.buildWithDiagnostics(
                cfg: cfg, instructions: lifted.instructions, collectDiagnostics: true,
                allowRejoiningContinuationGotos: true)

            XCTAssertNotNil(result.diagnostics.fatalVeto)
        }
    }

    func testE2RejoiningTailRejectsDoubleReachableSharedBlockAndFallsBack() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = [
                row(0x8200, "cbz", "x0, 0x820c", "else arm"),
                row(0x8204, "nop", "", "then private"),
                row(0x8208, "b", "0x821c", "then to shared head"),
                row(0x820c, "cbz", "x1, 0x8228", "else skips shared"),
                row(0x8210, "cbz", "x2, 0x8220", "else enters shared middle"),
                row(0x8214, "nop", "", "else private"),
                row(0x8218, "b", "0x821c", "else to shared head"),
                row(0x821c, "nop", "", "shared head"),
                row(0x8220, "mov", "x0, #0x3", "shared middle double entry"),
                row(0x8224, "b", "0x8228", "rejoin"),
                row(0x8228, "ret", "")
            ]
            let document = legacyDocument("_e2_rejoining_double_reachable", rows: rows)
            let legacy = legacyGotoFormDocument("_e2_rejoining_double_reachable", rows: rows)

            XCTAssertNil(document.regionTree)
            XCTAssertNil(document.structureFallback)
            XCTAssertEqual(document.text, legacy.text)
            XCTAssertTrue(regionDiagnosticsText(rows).contains("gotoLeafRejoiningDoubleReachable:1"))
        }
    }

    func testE2RejoiningTailGotoLeafRendersUnknownInstructionVerbatim() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let rows = e2RejoiningTailRows(
                base: 0x8300,
                sharedMnemonic: "mystery",
                sharedOperands: "x0, x0",
                sharedComment: "unknown in shared leaf"
            )
            let document = legacyDocument("_e2_unknown_rejoining_leaf", rows: rows)
            let legacy = legacyGotoFormDocument("_e2_unknown_rejoining_leaf", rows: rows)

            XCTAssertNil(document.structureFallback)
            XCTAssertNotNil(firstRegion(in: document.regionTree, kind: .gotoLeaf))
            XCTAssertLessThanOrEqual(explicitGotoCount(document), explicitGotoCount(legacy))
            XCTAssertTrue(document.text.contains("__unknown(\"mystery\", \"x0, x0\"); // unknown in shared leaf"))
        }
    }

    func testE2RejoiningTailGotoLeafWithDCEKeepsLeafStatements() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            var options = DecompilerOptions.default
            options.deadCodeElimination = true
            let rows = e2RejoiningTailRows(base: 0x8400, sharedComment: "shared tail under dce")
            let document = legacyDocument("_e2_rejoining_tail_dce", rows: rows, options: options)
            let legacy = legacyGotoFormDocument("_e2_rejoining_tail_dce", rows: rows)

            XCTAssertNil(document.structureFallback)
            if SSAPropertyAssertions.enabled {
                let lifted = function("_rejoining_phi", rows)
                XCTAssertNotNil(document.regionTree)
                XCTAssertNotNil(firstRegion(in: document.regionTree, kind: .gotoLeaf))
                SSARenderExpectation.assertRejoiningPhi(lifted, block: 0x8400 + 0x20,
                    entryPredecessor: 0x8400 + 0x0c, definingPredecessor: 0x8400 + 0x1c,
                    definitionAddress: 0x8400 + 0x18)
                SSARenderExpectation.assertEdgeCopyAgreement(document, legacy, function: lifted)
            } else {
                XCTAssertNil(document.regionTree)
            }
            XCTAssertLessThanOrEqual(explicitGotoCount(document), explicitGotoCount(legacy))
            XCTAssertTrue(document.text.contains("shared tail under dce"))
        }
    }
}
