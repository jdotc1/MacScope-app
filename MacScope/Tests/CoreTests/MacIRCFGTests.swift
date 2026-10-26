import Foundation
import XCTest
@testable import MacScope

final class MacIRCFGTests: XCTestCase {
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


    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "",
                     _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func assertAgreement(_ rows: [InstructionRow], name: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let enabled = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: false).buildFunction(name: name, instructions: rows)
        let disabled = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(name: name, instructions: rows)
        let cfg = try XCTUnwrap(enabled.cfg, name, file: file, line: line)
        XCTAssertNil(disabled.cfg, name, file: file, line: line)
        XCTAssertEqual(enabled.instructions, disabled.instructions, name, file: file, line: line)
        XCTAssertEqual(enabled.phis, disabled.phis, name, file: file, line: line)
        XCTAssertEqual(cfg.compatibilityCFG, CFGBuilder.buildCFG(instructions: enabled.instructions),
                       name, file: file, line: line)
        for phi in enabled.phis {
            let block = try XCTUnwrap(cfg.blocks.first { $0.startAddress == phi.blockAddress },
                                      name, file: file, line: line)
            let predecessors = block.predecessors.map {
                enabled.instructions[cfg.blocks[$0].instructionRange.upperBound - 1].source.address
            }
            XCTAssertEqual(phi.incoming.count, predecessors.count, name, file: file, line: line)
            XCTAssertEqual(phi.incoming.map(\.machineAddress), predecessors.map { Optional($0) },
                           name, file: file, line: line)
        }
    }

    func testRepeatedLiftProducesIdenticalExplicitGraph() throws {
        let rows = scalarFixtures[2].rows
        let first = MacIRBuilder(explicitCFGEnabled: true).buildFunction(name: "repeat", instructions: rows)
        let second = MacIRBuilder(explicitCFGEnabled: true).buildFunction(name: "repeat", instructions: rows)
        XCTAssertNotNil(first.cfg)
        XCTAssertEqual(first.cfg, second.cfg)
        XCTAssertEqual(first.refusals, second.refusals)
        XCTAssertEqual(first.instructions, second.instructions)
    }

    func testAdapterAgreesOnScalarStateFixturesAndPhiArity() throws {
        for fixture in scalarFixtures {
            try assertAgreement(fixture.rows, name: fixture.name)
        }
        let bypass = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: false).buildFunction(
            name: "bypassed_phi", instructions: scalarFixtures[2].rows)
        XCTAssertEqual(bypass.phis.count, 1)
        let loop = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: false).buildFunction(
            name: "loop_phis", instructions: scalarFixtures[9].rows)
        XCTAssertEqual(loop.phis.filter { $0.blockAddress == 0x9008 }.count, 2)
    }

    func testAdapterAgreesOnGotoLeafFixtures() throws {
        for fixture in gotoFixtures {
            try assertAgreement(fixture.rows, name: fixture.name)
        }
        try assertAgreement(rejoiningRows(), name: "rejoining")
        try assertAgreement(rejoiningRows(base: 0x8300, sharedMnemonic: "mystery",
            sharedOperands: "x0, x0", sharedComment: "unknown in shared leaf"), name: "unknown_rejoining")
        try assertAgreement(rejoiningRows(base: 0x8400, sharedComment: "shared tail under dce"),
                            name: "rejoining_dce")
    }

    private func decodedRows(_ hex: String, base: UInt64) throws -> [InstructionRow] {
        let bytes = try hex.split(whereSeparator: \.isWhitespace).map { try XCTUnwrap(UInt8($0, radix: 16)) }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: base)
        XCTAssertEqual(decoded.count * 4, bytes.count)
        return decoded.map { InstructionRow(decoded: $0) }
    }

    func testAdapterAgreesOnDecodedScalarFixtures() throws {
        for base: UInt64 in [0x21704, 0x3704, 0x913804, 0x3a704, 0x4b704] {
            try assertAgreement(decodedRows(Self.planarBytes, base: base), name: "planar_\(base)")
        }
        try assertAgreement(decodedRows(Self.indirectBytes, base: 0x17cb0), name: "indirect")
        for fixture in Self.decodedMemoryFixtures {
            try assertAgreement(decodedRows(fixture.bytes, base: fixture.base), name: fixture.name)
        }
    }

    func testAdapterAgreesOnContradictoryDecodedRowAuthority() throws {
        let original = try decodedRows(Self.planarBytes, base: 0x4b704)
        let load = try XCTUnwrap(original[0].structuredOperands)
        let pair = try XCTUnwrap(original[9].structuredOperands)
        let returned = try XCTUnwrap(original[83].structuredOperands)
        func envelope(_ source: InstructionOperands, coverage: InstructionOperands.Coverage? = nil,
                      operands: [InstructionOperands.Operand]? = nil,
                      semantics: InstructionOperands.Semantics? = nil,
                      legacyText: InstructionOperands.LegacyText? = nil) -> InstructionOperands {
            .init(architecture: source.architecture, schemaVersion: source.schemaVersion,
                  coverage: coverage ?? source.coverage, opcodeClass: source.opcodeClass,
                  operands: operands ?? source.operands, presentation: source.presentation,
                  semantics: semantics ?? source.semantics, legacyText: legacyText ?? source.legacyText)
        }
        var badLoad = load.operands
        badLoad[0] = .register(.init(index: 8, width: 32))
        for (index, changed): (Int, InstructionOperands) in [
            (0, envelope(load, operands: badLoad)),
            (0, envelope(load, coverage: .partial)),
            (0, envelope(load, semantics: .init(memoryAccessWidth: 64, memoryAccess: .read))),
            (9, envelope(pair, semantics: .init(memoryAccessWidth: 64, memoryAccess: .write))),
            (83, envelope(returned, legacyText: .init(mnemonic: "ret", operands: "x1"))),
            (83, envelope(returned, semantics: .init(memoryAccessWidth: 64, memoryAccess: .write)))
        ] {
            var rows = original
            rows[index].structuredOperands = changed
            try assertAgreement(rows, name: "contradictory_\(index)")
        }
    }

    func testCancelledLiftDoesNotPublishPartialGraphOrPhis() async {
        let rows = scalarFixtures[2].rows
        let expected = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(name: "cancelled", instructions: rows)
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return MacIRBuilder(explicitCFGEnabled: true).buildFunction(name: "cancelled", instructions: rows)
        }.value
        XCTAssertNil(cancelled.cfg)
        XCTAssertTrue(cancelled.phis.isEmpty)
        XCTAssertEqual(cancelled.refusals.map(\.reason), [.cancelled])
        XCTAssertEqual(cancelled.refusals.map(\.scope), [.function])
        if SSAPropertyAssertions.enabled {
            XCTAssertNil(cancelled.ssaInfo)
            XCTAssertNil(cancelled.returnValue)
            XCTAssertEqual(cancelled.instructions.map(\.source.address), rows.map(\.address))
            for instruction in cancelled.instructions {
                guard case let .unknown(destination, inputs, _, _) = instruction.operation else {
                    XCTFail("cancelled rows must come from the fresh opaque pass")
                    continue
                }
                XCTAssertNil(destination)
                for read in inputs.mayRead + inputs.definiteRead {
                    XCTAssertEqual(read.value, .unknown("cancelled_\(read.register)"))
                }
            }
        } else {
            XCTAssertEqual(cancelled.instructions, expected.instructions)
        }
    }

    func testDiamondDominanceFrontiersDescribeBothArms() throws {
        let function = MacIRBuilder(explicitCFGEnabled: true).buildFunction(
            name: "frontiers", instructions: scalarFixtures[0].rows)
        let cfg = try XCTUnwrap(function.cfg)
        let left = try XCTUnwrap(cfg.blocks.first { $0.startAddress == 0x1004 })
        let right = try XCTUnwrap(cfg.blocks.first { $0.startAddress == 0x100c })
        let join = try XCTUnwrap(cfg.blocks.first { $0.startAddress == 0x1010 })
        XCTAssertEqual(cfg.dominanceFrontier[left.index], [join.index])
        XCTAssertEqual(cfg.dominanceFrontier[right.index], [join.index])
        XCTAssertEqual(cfg.idom[join.index], 0)
        XCTAssertTrue(cfg.unreachable.isEmpty)
    }

    func testUnreachableBlocksAreRetainedAndRefused() throws {
        let rows = [row(0xc000, "ret"), row(0xc004, "nop"), row(0xc008, "ret")]
        let function = MacIRBuilder(explicitCFGEnabled: true).buildFunction(name: "orphan", instructions: rows)
        let cfg = try XCTUnwrap(function.cfg)
        XCTAssertEqual(cfg.blocks.count, 2)
        XCTAssertEqual(cfg.unreachable, [1])
        XCTAssertTrue(function.refusals.contains { $0.reason == .unreachableBlock && $0.scope == .block(1) })
        XCTAssertEqual(cfg.compatibilityCFG, CFGBuilder.buildCFG(instructions: function.instructions))
    }

    func testUnresolvedIndirectRefusalPreservesLegacyAdapter() throws {
        let rows = [row(0xd000, "br", "x9"), row(0xd004, "ret")]
        let function = MacIRBuilder(explicitCFGEnabled: true).buildFunction(name: "indirect", instructions: rows)
        let cfg = try XCTUnwrap(function.cfg)
        XCTAssertTrue(function.refusals.contains { $0.reason == .unresolvedIndirectBranch && $0.scope == .row(0xd000) })
        XCTAssertEqual(cfg.compatibilityCFG, CFGBuilder.buildCFG(instructions: function.instructions))
        XCTAssertFalse(cfg.compatibilityCFG.hasUnresolvedTargets)
    }

    func testTrapAndOutsideTargetKeepLegacyRenderingTopology() throws {
        for rows in [[row(0xe000, "brk", "#0"), row(0xe004, "ret")],
                     [row(0xe000, "b", "0xf000"), row(0xe004, "ret")]] {
            try assertAgreement(rows, name: "exit_compatibility")
        }
    }

    func testJumpTablePreservesCaseOrderAndLegacyAdapter() throws {
        let rows = [row(0xf000, "br", "x9"), row(0xf004, "ret"), row(0xf008, "ret")]
        let function = MacIRBuilder(explicitCFGEnabled: true).buildFunction(name: "switch_targets",
            jumpTables: [0xf000: [0xf008, 0xf004, 0xf008]], instructions: rows)
        let cfg = try XCTUnwrap(function.cfg)
        let dispatch = try XCTUnwrap(cfg.blocks.first { $0.startAddress == 0xf000 })
        let targets = dispatch.successors.filter { $0.kind == .jumpTable }.compactMap { $0.to }
        XCTAssertEqual(targets.map { cfg.blocks[$0].startAddress }, [0xf008, 0xf004, 0xf008])
        XCTAssertEqual(cfg.compatibilityCFG, CFGBuilder.buildCFG(instructions: function.instructions))
        XCTAssertFalse(function.refusals.contains { $0.reason == .unresolvedIndirectBranch })
    }

    func testEntryLoopHasAnEntryDominanceFrontier() throws {
        let rows = [row(0x6000, "add", "x0, x0, #1"), row(0x6004, "subs", "x1, x1, #1"),
                    row(0x6008, "b.ne", "0x6000"), row(0x600c, "ret")]
        let cfg = try XCTUnwrap(MacIRBuilder(explicitCFGEnabled: true)
            .buildFunction(name: "entry_loop", instructions: rows).cfg)
        XCTAssertEqual(cfg.dominanceFrontier[0], [0], "Entry's implicit incoming edge meets its backedge")
        XCTAssertEqual(cfg.loops.first?.body, [0], "The self-loop body contains only its header")
    }

    func testInstructionMutationInvalidatesDerivedGraph() throws {
        var function = MacIRBuilder(explicitCFGEnabled: true)
            .buildFunction(name: "mutated", instructions: scalarFixtures[0].rows)
        XCTAssertNotNil(function.cfg)
        function.instructions[0].operation = .returnValue(nil)
        XCTAssertNil(function.cfg, "A changed transfer cannot retain stale graph successors")
    }

    func testValueOnlyRepairPreservesEntryLoopGraphAndStructuring() throws {
        let rows = try decodedRows("28 44 40 b8 48 14 00 38 63 04 00 71 a1 ff ff 54 c0 03 5f d6",
                                   base: 0x30150)
        let function = MacIRBuilder(explicitCFGEnabled: true)
            .buildFunction(name: "_noscale", instructions: rows)
        let graph = try XCTUnwrap(function.cfg)
        if function.ssaEnabled {
            XCTAssertTrue(MacIRBuilder.hasBoundedEntryLoopProof(function))
            let info = try XCTUnwrap(function.ssaInfo)
            XCTAssertEqual(info.sourceAddresses, rows.map(\.address))
            XCTAssertEqual(graph.blocks.map(\.startAddress), [0x30150, 0x30160])
            XCTAssertEqual(graph.blocks[0].predecessors, [0])
            XCTAssertEqual(graph.blocks[1].predecessors, [0])
            XCTAssertFalse(function.phis.isEmpty)
            for phi in function.phis {
                XCTAssertEqual(phi.blockAddress, 0x30150)
                XCTAssertEqual(phi.incoming.filter { $0.predecessor == .functionEntry }.count, 1)
                XCTAssertEqual(phi.incoming.map(\.predecessor), [.functionEntry, .machine(0x3015c)])
            }
            XCTAssertFalse(function.instructions.contains { $0.source.syntheticPhiEdge != nil })
            let document = PseudocodePrinter().print(function: function)
            let initialCopies = document.lines.filter {
                $0.kind == .instruction && $0.syntheticPhiEdge?.predecessor == .functionEntry
            }
            XCTAssertTrue(initialCopies.isEmpty, "Native recurrence initializes storage from the actual entry input")
            XCTAssertTrue(document.text.contains("uint64_t x1_1 = (uint64_t)(in_x1);"))
            XCTAssertTrue(document.text.contains("uint64_t x2_1 = (uint64_t)(in_x2);"))
            XCTAssertTrue(document.text.contains("uint32_t w3_1 = (uint32_t)(in_w3);"))
            XCTAssertTrue(document.text.contains("do {"))
            XCTAssertTrue(document.text.contains("} while ((uint32_t)(w3_1) != 0x0);"))
            XCTAssertFalse(document.text.contains("goto "))
            XCTAssertFalse(document.lines.contains { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix(":") })
            XCTAssertFalse(document.text.contains("__entry_phi"))
            XCTAssertFalse(document.text.contains("__edge_"))
            XCTAssertTrue(function.reconciliationMarkers.isEmpty, "Bounded SSA preserves its original IR, not legacy repairs")
            return
        }
        XCTAssertFalse(function.reconciliationMarkers.isEmpty, "The loop requires actual operand repairs")
        XCTAssertFalse(function.nonMarkerDifference, "Value repair must preserve lexical graph equality")
        let repair = try XCTUnwrap(RegionalLexicalProof(reconciled: function))
        XCTAssertEqual(repair.function.cfg, graph, "Repair retains every graph field")
        let lexical = MacIRBuilder(skippingRejectedCFGReconciliation: true, explicitCFGEnabled: true)
            .buildFunction(name: "_noscale", instructions: rows)
        XCTAssertEqual(repair.function.instructions, lexical.instructions, "Repair restores lexical operands")
        let enabled = PseudocodePrinter().print(function: function)
        let disabled = PseudocodePrinter().print(function: MacIRBuilder(explicitCFGEnabled: false)
            .buildFunction(name: "_noscale", instructions: rows))
        XCTAssertTrue(enabled.text.contains("do {"), "The repaired entry loop still structures")
        XCTAssertEqual(enabled.text, disabled.text, "Graph retention preserves flag-off loop rendering")
    }

    @MainActor
    func testLibjpegExplicitGraphAcceptanceAndExport() throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_LIBJPEG_WITNESS"] == "1" else {
            throw XCTSkip("Set MACSCOPE_LIBJPEG_WITNESS=1 for the explicitly authorized graph witness")
        }
        guard let output = ProcessInfo.processInfo.environment["MACSCOPE_CFG_OUT"] else {
            throw XCTSkip("Set MACSCOPE_CFG_OUT to an unused graph witness output directory")
        }
        let inputURL = URL(fileURLWithPath: "/opt/homebrew/lib/libjpeg.8.dylib")
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw XCTSkip("libjpeg witness input is absent")
        }
        let destination = URL(fileURLWithPath: output, isDirectory: true)
        for name in ["pseudocode-on.txt", "cfg-acceptance.json"] {
            guard !FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path) else {
                throw NSError(domain: "CFGWitness", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Existing witness artifact must not be overwritten: \(name)"])
            }
        }
        // Volatile process-local defaults never change the installed app's preferences.
        let defaults = UserDefaults.standard
        return try MacIRConfiguration.$explicitCFGOverride.withValue(true) {
            let began = Date()
            let headers = try CalleeWitnessHeaders.load(into: AnalysisEngine().analyze(url: inputURL))
            let snapshot = headers.snapshot
            let slot = snapshot.primarySlot
            let analysis = try XCTUnwrap(snapshot.analysis(in: slot))
            _ = try XCTUnwrap(snapshot.imageWideIndirectCalls(in: slot, compute: true))
            let printer = PseudocodePrinter(options: DecompilerOptions(userDefaults: defaults))
            let required: Set<UInt64> = [
                0x6b88, 0x6c80, 0x739c, 0x7448, 0x7484, 0x8b88, 0x8e38, 0x9394, 0x972c,
                0x9a54, 0x9ae8, 0x1761c, 0x179e0, 0x1a104, 0x1a37c, 0x1b344, 0x1c360,
                0x1c678, 0x1ca14, 0x1ce2c, 0x24548, 0x25e0c, 0x2b918, 0x2be84, 0x2df5c,
                0x2f334, 0x2f748, 0x32540, 0x39674, 0x399a4, 0x3cd18, 0x3cfe4, 0x3d480,
                0x3e078, 0x3e460, 0x3e870, 0x3eccc, 0x4204c, 0x4945c, 0x4a894, 0x4be18,
                0x4c078, 0x4c668, 0x4cf5c, 0x4de74, 0x4e130, 0x4e56c, 0x4e9a8, 0x4ede4,
                0x4f220, 0x4f65c, 0x4fa98, 0x4fed4, 0x50054, 0x501d4, 0x50350, 0x504d0,
                0x5064c, 0x507c8, 0x50944, 0x51410, 0x517d8, 0x51cec, 0x51d78, 0x52f34,
                0x56714, 0x56c40, 0x57444, 0x57550
            ]
            var observed: Set<UInt64> = []
            var acceptance: [[String: Any]] = []
            var dump = ""
            var ssaAcceptance = SSAWitnessAcceptance()
            for identity in analysis.functions {
                let input = snapshot.pseudocodeRenderInput(selectedAddress: identity.startAddress, in: slot)
                // Same build/print seam and arguments as the canonical census render.
                let perfBuild = MacScopePerfPhaseClock.begin("witness.build", function: identity.startAddress)
                let function = printer.buildFunction(functionName: input.functionName,
                    startAddress: input.startAddress, jumpTables: input.jumpTables,
                    objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
                    signatureOverrides: input.signatureOverrides,
                    authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                    callerReturnWidth: input.callerReturnWidth, types: input.types,
                    instructions: input.instructions)
                MacScopePerfPhaseClock.end(perfBuild)
                if SSAPropertyAssertions.enabled {
                    try ssaAcceptance.observe(function: function, input: input)
                }
                if required.contains(identity.startAddress) {
                    observed.insert(identity.startAddress)
                    let scoped = !function.refusals.isEmpty && function.refusals.allSatisfy { refusal in
                        switch refusal.scope {
                        case .row, .cell, .block: return true
                        case .function: return false
                        }
                    }
                    XCTAssertTrue(function.cfg != nil || scoped,
                                  "Every acceptance function needs a complete graph or located refusals")
                    acceptance.append(["start": identity.startAddress, "name": identity.name,
                        "cfg": function.cfg != nil, "blocks": function.cfg?.blocks.count ?? 0,
                        "refusals": function.refusals.map { ["reason": $0.reason.rawValue,
                            "scope": String(describing: $0.scope), "detail": $0.detail ?? ""] }])
                    if identity.startAddress == 0x32540 {
                        let cfg = try XCTUnwrap(function.cfg)
                        let dispatches = cfg.terminators.enumerated().filter {
                            if case let .indirect(table?) = $0.element { return table.count == 63 }
                            return false
                        }
                        XCTAssertEqual(dispatches.count, 1, "The marker dispatch retains its 63-entry table")
                        if let dispatch = dispatches.first {
                            XCTAssertEqual(cfg.blocks[dispatch.offset].successors.filter { $0.kind == .jumpTable }.count,
                                           63, "Each marker case has a labelled jump-table edge")
                        }
                    }
                }
                let perfPrint = MacScopePerfPhaseClock.begin("witness.print", function: identity.startAddress)
                let document = printer.print(function: function, types: input.types,
                    nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
                    stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
                MacScopePerfPhaseClock.end(perfPrint)
                let name = identity.name.replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
                dump += "// FUNCTION name=\(name) start=0x\(String(identity.startAddress, radix: 16))\n"
                    + document.text + "\n\n"
            }
            if SSAPropertyAssertions.enabled { try ssaAcceptance.finish(output: destination) }
            XCTAssertEqual(observed, required, "Every required function was visited at its exact address")
            let receipt: [String: Any] = [
                "sourceHead": ProcessInfo.processInfo.environment["MACSCOPE_WITNESS_SOURCE_HEAD"] ?? "unrecorded",
                "functions": analysis.functions.count, "acceptance": acceptance,
                "explicitCFG": true, "nativeSleighExport": false,
                "renderPath": "DocumentExportService.pseudocodeText printer build/print seams; one render per function",
                "seconds": Date().timeIntervalSince(began)
            ]
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(dump.utf8).write(to: destination.appendingPathComponent("pseudocode-on.txt"), options: .withoutOverwriting)
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("cfg-acceptance.json"), options: .withoutOverwriting)
        }
    }

    // Fixture rows copied from the named suites so these tests have no source-file dependency.
    private var scalarFixtures: [(name: String, rows: [InstructionRow])] {
        [
            ("testDiamondJoinSelectsTheTakenPredecessorValue_rows", [
            row(0x1000, "cbz", "x0, 0x100c"),
            row(0x1004, "mov", "x1, #1"),
            row(0x1008, "b", "0x1010"),
            row(0x100c, "mov", "x1, #2"),
            row(0x1010, "mov", "x0, x1"),
            row(0x1014, "ret")
        ]),
            ("testAgreedPredecessorsPreserveValueAtJoin_rows", [
            row(0x2000, "mov", "x1, #7"),
            row(0x2004, "cbz", "x0, 0x2010"),
            row(0x2008, "nop"),
            row(0x200c, "b", "0x2014"),
            row(0x2010, "nop"),
            row(0x2014, "mov", "x0, x1"),
            row(0x2018, "ret")
        ]),
            ("testBypassIntoOneArmUsesTypedPhiInsteadOfUnjustifiedSelect_rows", [
            row(0x1000, "cbz", "x2, 0x1008"),
            row(0x1004, "cbz", "x0, 0x1010"),
            row(0x1008, "mov", "x1, #1"),
            row(0x100c, "b", "0x1014"),
            row(0x1010, "mov", "x1, #2"),
            row(0x1014, "mov", "x0, x1"),
            row(0x1018, "ret")
        ]),
            ("testDivergentReturnRegisterPhiNeedsReturnContract_rows", [
            row(0x2800, "cbz", "x1, 0x280c"),
            row(0x2804, "mov", "x0, #1"),
            row(0x2808, "b", "0x2810"),
            row(0x280c, "mov", "x0, #2"),
            row(0x2810, "ret")
        ]),
            ("testUnresolvedTargetAndBackEdgeRefuseBoundedRoute_unresolved", [
            row(0x3000, "cbz", "x0, 0x3020"),
            row(0x3004, "mov", "x1, #1"),
            row(0x3008, "mov", "x0, x1"),
            row(0x300c, "ret")
        ]),
            ("testUnresolvedTargetAndBackEdgeRefuseBoundedRoute_loop", [
            row(0x4000, "mov", "x1, #0"),
            row(0x4004, "cbz", "x0, 0x4010"),
            row(0x4008, "b", "0x4004"),
            row(0x400c, "nop"),
            row(0x4010, "ret")
        ]),
            ("testLoopAdmissionRefusesBypassedFlagsAndEntryBackedge_bypassedFlags", [
            row(0x5000, "cbz", "x0, 0x5008"),
            row(0x5004, "subs", "x1, x1, #1"),
            row(0x5008, "b.ne", "0x5004"),
            row(0x500c, "ret")
        ]),
            ("testLoopAdmissionRefusesBypassedFlagsAndEntryBackedge_entryBackedge", [
            row(0x6000, "add", "x0, x0, #1"),
            row(0x6004, "subs", "x1, x1, #1"),
            row(0x6008, "b.ne", "0x6000"),
            row(0x600c, "ret")
        ]),
            ("testUnknownClobberRemainsAnEffectBarrier_rows", [
            row(0x8000, "cbz", "x0, 0x800c"),
            row(0x8004, "ldaxr", "x1, [x2]"),
            row(0x8008, "b", "0x8010"),
            row(0x800c, "mov", "x1, #2"),
            row(0x8010, "mov", "x0, x1"),
            row(0x8014, "ret")
        ]),
            ("testLoopHeaderPhisBindEntryAndBackedgeSSAValues_rows", [
            row(0x9000, "mov", "x1, #0"),
            row(0x9004, "cbz", "x0, 0x9014"),
            row(0x9008, "add", "x1, x1, x0"),
            row(0x900c, "subs", "x0, x0, #1"),
            row(0x9010, "b.ne", "0x9008"),
            row(0x9014, "mov", "x0, x1"),
            row(0x9018, "ret")
        ]),
            ("partialJoin_rows", [row(0xa000, "cbz", "x0, 0xa00c"),
                    row(0xa004, "nop"), row(0xa008, "b", "0xa010"),
                    row(0xa00c, "nop"), row(0xa010, "ret")]),
        ]
    }

    private var gotoFixtures: [(name: String, rows: [InstructionRow])] {
        [
            ("testGotoLeafCapabilityRendersGuardAndLeafThroughLegacyStructurer_rows", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "nop", "", "between compare and branch"),
            row(0x1008, "b.eq", "0x1010", "guard"),
            row(0x100c, "nop", "", "wrapper"),
            row(0x1010, "ret", "")
        ]),
            ("testGotoLeafRejectsNonContiguousBlockSetAndFallsBack_rows", [
            row(0x2000, "cbz", "x0, 0x200c", "split"),
            row(0x2004, "nop", "", "leaf start"),
            row(0x2008, "b", "0x2014"),
            row(0x200c, "nop", "", "interleaved block"),
            row(0x2010, "b", "0x2014"),
            row(0x2014, "ret", "")
        ]),
            ("testGotoLeafRejectsDuplicateBlockPartitionAndFallsBack_rows", [
            row(0x3000, "nop", "", "once"),
            row(0x3004, "ret", "")
        ]),
            ("testGotoLeafRejectsGotoCountIncreaseAndFallsBack_rows", [
            row(0x4000, "cmp", "x0, #0x0"),
            row(0x4004, "b.eq", "0x400c", "skip"),
            row(0x4008, "nop", "", "body"),
            row(0x400c, "ret", "")
        ]),
            ("testGotoLeafRendersUnknownInstructionVerbatim_rows", [
            row(0x5000, "b", "0x5004"),
            row(0x5004, "mystery", "x0, x0", "unknown in leaf"),
            row(0x5008, "ret", "")
        ]),
            ("testGotoLeafDCEUsesFreshLeafState_rows", [
            row(0x6000, "ret", ""),
            row(0x6004, "nop", "", "fresh leaf after return")
        ]),
            ("terminalSharedExitGotoLeaf_rows", [
            row(0x7000, "cbnz", "x0, 0x7014", "guard fail"),
            row(0x7004, "cbz", "x1, 0x7010", "success guard"),
            row(0x7008, "nop", "", "continuation"),
            row(0x700c, "b", "0x7014"),
            row(0x7010, "ret", ""),
            row(0x7014, "mov", "x0, #0x1", "fail"),
            row(0x7018, "ret", "")
        ]),
            ("nonContiguousSharedTail_rows", [
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
        ]),
            ("doubleReachableSharedBlock_rows", [
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
        ]),
        ]
    }

    private func rejoiningRows(base: UInt64 = 0x8000, sharedMnemonic: String = "mov", sharedOperands: String = "x0, #0x2", sharedComment: String = "shared tail") -> [InstructionRow] {
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

    private static let planarBytes = """
    09 5c 40 b9 08 30 40 b9 3f 0d 00 71 e0 03 00 54
    3f 11 00 71 c1 06 00 54 9f 04 00 71 8b 09 00 54
    88 02 00 34 49 28 40 a9 29 59 63 f8 4a 59 63 f8
    4b 30 41 a9 6b 59 63 f8 8c 59 63 f8 ed 03 08 aa
    2e 00 40 f9 cf 01 40 39 2f 15 00 38 cf 05 40 39
    4f 15 00 38 cf 09 40 39 6f 15 00 38 cf 0d 40 39
    8f 15 00 38 ce 11 00 91 ad 05 00 f1 c1 fe ff 54
    21 20 00 91 63 04 00 11 9f 08 00 71 84 04 00 51
    63 06 00 54 e7 ff ff 17 9f 04 00 71 0b 06 00 54
    28 02 00 34 49 28 40 a9 29 59 63 f8 4a 59 63 f8
    4b 08 40 f9 6b 59 63 f8 2c 00 40 f9 ed 03 08 aa
    8e 01 40 39 2e 15 00 38 8e 05 40 39 4e 15 00 38
    8e 09 40 39 6e 15 00 38 8c 0d 00 91 ad 05 00 f1
    01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
    84 04 00 51 43 03 00 54 ea ff ff 17 9f 04 00 71
    eb 02 00 54 2a 7d 40 93 5f 05 00 71 eb 01 00 54
    0b 00 80 d2 48 01 00 34 4c 78 6b f8 8c 59 63 f8
    2d 00 40 f9 ee 03 08 aa af 69 6b 38 8f 15 00 38
    ad 01 0a 8b ce 05 00 f1 81 ff ff 54 6b 05 00 91
    7f 01 09 eb 81 fe ff 54 21 20 00 91 63 04 00 11
    9f 04 00 71 84 04 00 51 8c fd ff 54 c0 03 5f d6
    """

    private static let indirectBytes = """
    08 14 41 f9 4a 00 40 39 09 58 40 b9 0b d8 41 b9
    eb 03 2b 2a 29 01 0b 0b 0b 00 80 12 69 21 c9 1a
    29 01 0a 0b 89 00 00 b9 a9 04 00 71 20 01 00 54
    4b 04 00 91 8c 10 00 91 6d 15 40 38 aa 01 0a 4b
    8a 45 00 b8 ea 03 0d aa 29 05 00 71 61 ff ff 54
    09 3c 41 b9 c9 00 00 34 09 a1 01 91 2a d9 61 b8
    4a 05 00 71 2a d9 21 b8 00 03 00 54 09 cc 41 b9
    3f 0d 00 71 6d 01 00 54 3f 15 00 71 8c 03 00 54
    3f 11 00 71 a0 06 00 54 3f 15 00 71 81 04 00 54
    08 cd 21 8b 09 00 00 b0 29 b1 01 91 3a 00 00 14
    3f 05 00 71 40 03 00 54 3f 09 00 71 60 06 00 54
    3f 0d 00 71 41 03 00 54 08 cd 21 8b 09 00 00 90
    29 21 3d 91 30 00 00 14 2a 7c 40 93 0b 3c 41 b9
    0c 98 41 b9 6b 09 cc 1a 2b 79 2a b8 08 0d 0a 8b
    09 00 00 90 29 c1 32 91 27 00 00 14 3f 19 00 71
    c0 03 00 54 3f 1d 00 71 21 01 00 54 08 cd 21 8b
    09 00 00 b0 29 61 06 91 1f 00 00 14 08 cd 21 8b
    09 00 00 90 29 f1 38 91 1b 00 00 14 08 00 40 f9
    2a 02 80 52 0a 25 05 29 08 d0 41 b9 09 00 40 f9
    28 31 00 b9 08 d4 41 b9 09 00 40 f9 28 35 00 b9
    08 d8 41 b9 09 00 40 f9 28 39 00 b9 08 00 40 f9
    01 01 40 f9 20 00 1f d6 08 cd 21 8b 09 00 00 90
    29 51 3f 91 08 00 00 14 08 cd 21 8b 09 00 00 b0
    29 01 04 91 04 00 00 14 08 cd 21 8b 09 00 00 90
    29 01 3b 91 09 0d 00 f9 c0 03 5f d6
    """

    private static var decodedMemoryFixtures: [(name: String, base: UInt64, bytes: String)] {
        [
            ("planar8", 0x27b30, """
            09 38 40 b9 08 88 40 b9 3f 0d 00 71 e0 03 00 54
            3f 11 00 71 c1 06 00 54 9f 04 00 71 8b 09 00 54
            88 02 00 34 29 28 40 a9 29 59 62 f8 4a 59 62 f8
            2b 30 41 a9 6b 59 62 f8 8c 59 62 f8 ed 03 08 aa
            6e 00 40 f9 2f 15 40 38 cf 01 00 39 4f 15 40 38
            cf 05 00 39 6f 15 40 38 cf 09 00 39 8f 15 40 38
            cf 0d 00 39 ce 11 00 91 ad 05 00 f1 c1 fe ff 54
            42 04 00 11 63 20 00 91 9f 08 00 71 84 04 00 51
            63 06 00 54 e7 ff ff 17 9f 04 00 71 0b 06 00 54
            28 02 00 34 29 28 40 a9 29 59 62 f8 4a 59 62 f8
            2b 08 40 f9 6b 59 62 f8 6c 00 40 f9 ed 03 08 aa
            2e 15 40 38 8e 01 00 39 4e 15 40 38 8e 05 00 39
            6e 15 40 38 8e 09 00 39 8c 0d 00 91 ad 05 00 f1
            01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
            84 04 00 51 43 03 00 54 ea ff ff 17 9f 04 00 71
            eb 02 00 54 2a 7d 40 93 5f 05 00 71 eb 01 00 54
            0b 00 80 d2 48 01 00 34 2c 78 6b f8 8c 59 62 f8
            6d 00 40 f9 ee 03 08 aa 8f 15 40 38 af 69 2b 38
            ad 01 0a 8b ce 05 00 f1 81 ff ff 54 6b 05 00 91
            7f 01 09 eb 81 fe ff 54 63 20 00 91 42 04 00 11
            9f 04 00 71 84 04 00 51 8c fd ff 54 c0 03 5f d6
            """),
            ("rgbToPlanes8", 0x3854, """
            9f 04 00 71 0b 03 00 54 08 30 40 b9 28 02 00 34
            49 28 40 a9 29 59 63 f8 4a 59 63 f8 4b 08 40 f9
            6b 59 63 f8 2c 00 40 f9 ed 03 08 aa 8e 01 40 39
            2e 15 00 38 8e 05 40 39 4e 15 00 38 8e 09 40 39
            6e 15 00 38 8c 0d 00 91 ad 05 00 f1 01 ff ff 54
            21 20 00 91 63 04 00 11 9f 08 00 71 84 04 00 51
            62 fd ff 54 c0 03 5f d6
            """),
            ("planesToBGR16", 0x29a70, """
            9f 04 00 71 2b 03 00 54 08 88 40 b9 29 28 40 a9
            2b 08 40 f9 08 02 00 34 2c 59 62 f8 4d 59 62 f8
            6e 59 62 f8 6f 00 40 f9 ef 11 00 91 f0 03 08 aa
            91 25 40 78 f1 01 00 79 b1 25 40 78 f1 e1 1f 78
            d1 25 40 78 f1 c1 1f 78 ef 19 00 91 10 06 00 f1
            01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
            84 04 00 51 82 fd ff 54 c0 03 5f d6
            """),
            ("bgrToPlanes8", 0x3924, """
            9f 04 00 71 2b 03 00 54 08 30 40 b9 48 02 00 34
            49 28 40 a9 29 59 63 f8 4a 59 63 f8 4b 08 40 f9
            6b 59 63 f8 2c 00 40 f9 8c 09 00 91 ed 03 08 aa
            8e 01 40 39 2e 15 00 38 8e f1 5f 38 4e 15 00 38
            8e e1 5f 38 6e 15 00 38 8c 0d 00 91 ad 05 00 f1
            01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
            84 04 00 51 42 fd ff 54 c0 03 5f d6
            """),
            ("bgrToPlanes16", 0x4e84, """
            9f 04 00 71 2b 03 00 54 08 30 40 b9 49 28 40 a9
            4b 08 40 f9 08 02 00 34 2c 59 63 f8 4d 59 63 f8
            6e 59 63 f8 2f 00 40 f9 ef 11 00 91 f0 03 08 aa
            f1 01 40 79 91 25 00 78 f1 e1 5f 78 b1 25 00 78
            f1 c1 5f 78 d1 25 00 78 ef 19 00 91 10 06 00 f1
            01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
            84 04 00 51 82 fd ff 54 c0 03 5f d6
            """),
            ("planesToBGR8", 0x27d58, """
            9f 04 00 71 2b 03 00 54 08 88 40 b9 48 02 00 34
            29 28 40 a9 29 59 62 f8 4a 59 62 f8 2b 08 40 f9
            6b 59 62 f8 6c 00 40 f9 8c 09 00 91 ed 03 08 aa
            2e 15 40 38 8e 01 00 39 4e 15 40 38 8e f1 1f 38
            6e 15 40 38 8e e1 1f 38 8c 0d 00 91 ad 05 00 f1
            01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
            84 04 00 51 42 fd ff 54 c0 03 5f d6
            """),
            ("returnHalfwordInput", 0x4c58, """
            09 5c 40 b9 08 30 40 b9 3f 0d 00 71 e0 03 00 54
            3f 11 00 71 c1 06 00 54 9f 04 00 71 eb 09 00 54
            49 28 40 a9 4b 30 41 a9 48 02 00 34 2d 59 63 f8
            4e 59 63 f8 ef 03 08 aa 70 59 63 f8 91 59 63 f8
            20 00 40 f9 02 00 40 79 a2 25 00 78 02 04 40 79
            c2 25 00 78 02 08 40 79 02 26 00 78 02 0c 40 79
            22 26 00 78 00 20 00 91 ef 05 00 f1 c1 fe ff 54
            21 20 00 91 63 04 00 11 9f 08 00 71 84 04 00 51
            c3 06 00 54 e9 ff ff 17 9f 04 00 71 6b 06 00 54
            49 28 40 a9 4b 08 40 f9 e8 01 00 34 2c 59 63 f8
            4d 59 63 f8 ee 03 08 aa 6f 59 63 f8 30 00 40 f9
            11 02 40 79 91 25 00 78 11 06 40 79 b1 25 00 78
            11 0a 40 79 f1 25 00 78 10 1a 00 91 ce 05 00 f1
            01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
            84 04 00 51 a3 03 00 54 ec ff ff 17 9f 04 00 71
            4b 03 00 54 2a 7d 40 93 4b f9 7f d3 5f 05 00 71
            2b 02 00 54 0c 00 80 d2 2d 00 40 f9 48 01 00 34
            4e 78 6c f8 ce 59 63 f8 ef 03 0d aa f0 03 08 aa
            f1 01 40 79 d1 25 00 78 ef 01 0b 8b 10 06 00 f1
            81 ff ff 54 8c 05 00 91 ad 09 00 91 9f 01 09 eb
            61 fe ff 54 21 20 00 91 63 04 00 11 9f 04 00 71
            84 04 00 51 4c fd ff 54 c0 03 5f d6
            """),
            ("returnHalfwordOutput", 0x2983c, """
            09 38 40 b9 08 88 40 b9 3f 0d 00 71 e0 03 00 54
            3f 11 00 71 c1 06 00 54 9f 04 00 71 eb 09 00 54
            29 28 40 a9 2b 30 41 a9 48 02 00 34 2d 59 62 f8
            4e 59 62 f8 ef 03 08 aa 70 59 62 f8 91 59 62 f8
            60 00 40 f9 a1 25 40 78 01 00 00 79 c1 25 40 78
            01 04 00 79 01 26 40 78 01 08 00 79 21 26 40 78
            01 0c 00 79 00 20 00 91 ef 05 00 f1 c1 fe ff 54
            42 04 00 11 63 20 00 91 9f 08 00 71 84 04 00 51
            c3 06 00 54 e9 ff ff 17 9f 04 00 71 6b 06 00 54
            29 28 40 a9 2b 08 40 f9 e8 01 00 34 2c 59 62 f8
            4d 59 62 f8 ee 03 08 aa 6f 59 62 f8 70 00 40 f9
            91 25 40 78 11 02 00 79 b1 25 40 78 11 06 00 79
            f1 25 40 78 11 0a 00 79 10 1a 00 91 ce 05 00 f1
            01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
            84 04 00 51 a3 03 00 54 ec ff ff 17 9f 04 00 71
            4b 03 00 54 2a 7d 40 93 4b f9 7f d3 5f 05 00 71
            2b 02 00 54 0c 00 80 d2 6d 00 40 f9 48 01 00 34
            2e 78 6c f8 ce 59 62 f8 ef 03 0d aa f0 03 08 aa
            d1 25 40 78 f1 01 00 79 ef 01 0b 8b 10 06 00 f1
            81 ff ff 54 8c 05 00 91 ad 09 00 91 9f 01 09 eb
            61 fe ff 54 63 20 00 91 42 04 00 11 9f 04 00 71
            84 04 00 51 4c fd ff 54 c0 03 5f d6
            """),
            ("returnYCC", 0x3f18, """
            9f 04 00 71 eb 05 00 54 08 0c 41 f9 08 15 40 f9
            09 30 40 b9 c9 04 00 34 4a 2c 40 a9 4a 59 63 f8
            6b 59 63 f8 4c 08 40 f9 8c 59 63 f8 2d 00 40 f9
            ad 0d 00 91 ee 03 09 aa af e1 5f 38 b0 f1 5f 38
            b1 45 40 38 0f 0d 0f 8b e0 01 40 f9 10 0d 10 8b
            05 02 48 b9 11 0d 11 8b 26 02 50 b9 a0 00 00 0b
            00 00 06 0b 00 7c 10 53 40 15 00 38 e0 01 58 b9
            05 02 60 b9 26 02 68 b9 a0 00 00 0b 00 00 06 0b
            00 7c 10 53 60 15 00 38 ef 01 68 b9 10 02 70 b9
            31 02 78 b9 0f 02 0f 0b ef 01 11 0b ef 7d 10 53
            8f 15 00 38 ce 05 00 f1 81 fc ff 54 21 20 00 91
            63 04 00 11 9f 08 00 71 84 04 00 51 c2 fa ff 54
            c0 03 5f d6
            """),
        ]
    }
}

extension MacIRCFGTests {
    func testModeEnvironmentParsingPreservesExistingEnableOnlySemantics() {
        for value: String? in [nil, "", "0", "false", "true", "YES", " 1", "1 ", "2"] {
            XCTAssertFalse(MacIRConfiguration.enabled(environmentValue: value, preference: false))
            XCTAssertTrue(MacIRConfiguration.enabled(environmentValue: value, preference: true))
        }
        XCTAssertTrue(MacIRConfiguration.enabled(environmentValue: "1", preference: false))
        var preferenceWasRead = false
        func preference() -> Bool { preferenceWasRead = true; return false }
        XCTAssertTrue(MacIRConfiguration.enabled(environmentValue: "1", preference: preference()))
        XCTAssertFalse(preferenceWasRead)
    }

    func testModeScopesRestoreAfterThrowWithoutWritingAppDomain() throws {
        let domain = "org.macscope.app"
        let before = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let inheritedSSA = MacIRConfiguration.ssaOverride
        let inheritedCFG = MacIRConfiguration.explicitCFGOverride
        enum Expected: Error { case stop }
        XCTAssertThrowsError(try MacIRConfiguration.$ssaOverride.withValue(true) {
            XCTAssertTrue(MacIRBuilder().ssaEnabled)
            XCTAssertFalse(MacIRBuilder(ssaEnabled: false).ssaEnabled)
            try MacIRConfiguration.$explicitCFGOverride.withValue(true) {
                XCTAssertTrue(MacIRConfiguration.explicitCFGEnabled)
                MacIRConfiguration.$ssaOverride.withValue(false) {
                    XCTAssertFalse(MacIRBuilder().ssaEnabled)
                }
                XCTAssertTrue(MacIRBuilder().ssaEnabled)
                throw Expected.stop
            }
        })
        XCTAssertEqual(MacIRConfiguration.ssaOverride, inheritedSSA)
        XCTAssertEqual(MacIRConfiguration.explicitCFGOverride, inheritedCFG)
        let after = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: after))
    }

    func testConcurrentModeScopesAndCancellationDoNotLeak() async {
        let inheritedSSA = MacIRConfiguration.ssaOverride
        let values = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for enabled in [false, true] {
                group.addTask {
                    await MacIRConfiguration.$ssaOverride.withValue(enabled) {
                        await Task.yield()
                        let child = await Task { MacIRBuilder().ssaEnabled }.value
                        withUnsafeCurrentTask { $0?.cancel() }
                        await Task.yield()
                        return child == enabled && MacIRBuilder().ssaEnabled == enabled
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values, [true, true])
        XCTAssertEqual(MacIRConfiguration.ssaOverride, inheritedSSA)
        let detached = await MacIRConfiguration.$ssaOverride.withValue(true) {
            await Task.detached { MacIRConfiguration.ssaOverride }.value
        }
        XCTAssertNil(detached)
    }
}


extension MacIRCFGTests {
    func testImmutableRunnerBaselineRejectsConflictsAndReachesDetachedWork() async throws {
        let baseline = try XCTUnwrap(MacIRConfiguration.installedTestBaseline)
        XCTAssertTrue(MacIRConfiguration.installTestBaseline(baseline))
        XCTAssertFalse(MacIRConfiguration.installTestBaseline(.init(
            ssa: !baseline.ssa, explicitCFG: baseline.explicitCFG,
            returnContract: baseline.returnContract)))
        XCTAssertEqual(MacIRConfiguration.installedTestBaseline, baseline)
        XCTAssertEqual(DecompilerOptions(userDefaults: .standard), .default)
        let detachedMode = await MacIRConfiguration.$ssaOverride.withValue(!baseline.ssa) {
            await Task.detached { MacIRBuilder().ssaEnabled }.value
        }
        XCTAssertEqual(detachedMode, baseline.ssa)
    }
}


extension MacIRCFGTests {
    func testInstalledLaunchModeInjectionIsExplicitAndPreferenceFree() {
        XCTAssertNil(MacIRConfiguration.launchTestBaseline(environment: [:]))
        XCTAssertNil(MacIRConfiguration.launchTestBaseline(environment: ["MACSCOPE_SSA_LIFTER": "1"]))
        XCTAssertEqual(MacIRConfiguration.launchTestBaseline(environment: [
            "MACSCOPE_TEST_MODE_BASELINE": "1"
        ]), .init(ssa: false, explicitCFG: false, returnContract: false))
        XCTAssertEqual(MacIRConfiguration.launchTestBaseline(environment: [
            "MACSCOPE_TEST_MODE_BASELINE": "1", "MACSCOPE_SSA_LIFTER": "1",
            "MACSCOPE_EXPLICIT_CFG": "1", "MACSCOPE_RETURN_CONTRACT_TABLE": "1"
        ]), .init(ssa: true, explicitCFG: true, returnContract: true))
    }
}
