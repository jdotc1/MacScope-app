import Foundation
import XCTest
@testable import MacScope

final class DecompilerStructuringReadabilityTests: XCTestCase {
    private func line(_ text: String, keywords: [String] = []) -> PseudocodeLine {
        .init(lineNumber: 1, text: text, tokens: keywords.map {
            .init(lineNumber: 1, kind: .keyword, text: $0, range: 0..<$0.count)
        })
    }

    func testAdmissionUsesRemovedGotosAndExactThresholdBoundaries() {
        let legacy = [line("    goto 0x1234;", keywords: ["goto"]), line("    goto 0x5678;", keywords: ["goto"])]
        let sameTransfers = [line("                if (c) break exit_0x1234;", keywords: ["if", "break"]),
                             line("    continue loop_0x5678;", keywords: ["continue"])]
        XCTAssertTrue(PseudocodePrinter.recoveryReadabilityAdmits(candidate: sameTransfers, legacy: legacy, startingAt: 0, options: .default))
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: sameTransfers + [line("    break exit_0x9999;", keywords: ["break"])], legacy: legacy, startingAt: 0, options: .default))
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: [line("                    return;", keywords: ["return"])], legacy: legacy, startingAt: 0, options: .default))
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: sameTransfers + [legacy[0]], legacy: legacy, startingAt: 0, options: .default), "Only removed gotos buy transfers")
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: [], legacy: [], startingAt: 0, options: .default))
    }

    func testCommentsAndStringContentsDoNotBuyRecoveryBudget() {
        let misleading = [line("    print(\"goto x;\"); // goto y;")]
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: [line("    return;", keywords: ["return"])], legacy: misleading, startingAt: 0, options: .default))
        let header = line("goto", keywords: ["goto"])
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: [header], legacy: [header], startingAt: 1, options: .default))
    }

    func testActualTokenizerExcludesQuotedAndCommentTransferNames() {
        let source = MacIRSourceSpan(address: 0x8000, byteText: "", mnemonic: "bl", operands: "",
                                     comment: "goto x; break exit_0x1234; continue loop_0x1234;")
        let function = MacIRFunction(name: "_quoted_control_words", startAddress: 0x8000, endAddress: 0x8008,
            instructions: [
                .init(source: source, operation: .intrinsic(destination: nil, name: "observe",
                    arguments: [.symbol("\"goto x; break exit_0x1234; continue loop_0x1234;\"")])),
                .init(source: .init(address: 0x8004, byteText: "", mnemonic: "ret", operands: ""),
                      operation: .returnValue(nil))
            ])
        let actual = PseudocodePrinter().print(function: function)
        XCTAssertTrue(actual.text.contains("goto x;"))
        let tokens = actual.lines.flatMap(\.tokens)
        XCTAssertTrue(tokens.contains { $0.kind == .literal && $0.text.contains("goto") })
        XCTAssertTrue(tokens.contains { $0.kind == .comment && $0.text.contains("goto") })
        XCTAssertFalse(tokens.contains { $0.kind == .keyword && ["goto", "break", "continue"].contains($0.text) })
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: [], legacy: actual.lines,
                                                                  startingAt: 0, options: .default))
    }

    func testReadabilityOptionConstructionAndMutationAreClamped() throws {
        let low = DecompilerOptions(structureControlFlow: true, deadCodeElimination: false, nopElision: false,
                                    functionSizeGate: 1024, recoveryMaxTransferRatioPercent: -1,
                                    recoveryMaxAdditionalNesting: -1)
        XCTAssertEqual(low.recoveryMaxTransferRatioPercent, 0)
        XCTAssertEqual(low.recoveryMaxAdditionalNesting, 0)
        let high = DecompilerOptions(structureControlFlow: true, deadCodeElimination: false, nopElision: false,
                                     functionSizeGate: 1024, recoveryMaxTransferRatioPercent: Int.max,
                                     recoveryMaxAdditionalNesting: Int.max)
        XCTAssertEqual(high.recoveryMaxTransferRatioPercent, 400)
        XCTAssertEqual(high.recoveryMaxAdditionalNesting, 16)
        var mutated = DecompilerOptions.default
        mutated.recoveryMaxTransferRatioPercent = Int.max
        mutated.recoveryMaxAdditionalNesting = Int.max
        let legacy = [line("    goto x;", keywords: ["goto"])]
        let tooMany = Array(repeating: line("    break exit_0x1234;", keywords: ["break"]), count: 5)
        XCTAssertFalse(PseudocodePrinter.recoveryReadabilityAdmits(candidate: tooMany, legacy: legacy, startingAt: 0, options: mutated))
        let name = "CP6Readability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(DecompilerOptions(userDefaults: defaults), .default)
        defaults.set(50_000, forKey: DecompilerOptions.Key.recoveryMaxTransferRatioPercent)
        defaults.set(-2, forKey: DecompilerOptions.Key.recoveryMaxAdditionalNesting)
        let loaded = DecompilerOptions(userDefaults: defaults)
        XCTAssertEqual(loaded.recoveryMaxTransferRatioPercent, 400)
        XCTAssertEqual(loaded.recoveryMaxAdditionalNesting, 0)
        XCTAssertEqual(DecompilerOptions.default.recoveryMaxTransferRatioPercent, 100)
        XCTAssertEqual(DecompilerOptions.default.recoveryMaxAdditionalNesting, 3)
    }

    func testAddressLabelAllocationIgnoresBlockIDsAndDisambiguatesDeterministically() {
        func names(ids: [Int], addressByID: [Int: UInt64]) -> [String] {
            var allocator = PseudocodePrinter.RecoveryLabelAllocator()
            return ids.map { allocator.label(prefix: "exit", address: addressByID[$0]!) }
        }
        let original = names(ids: [0, 1, 0, 2], addressByID: [0: 0x1000cc4a8, 1: 0x100143bd8, 2: 0x1000cc4a8])
        let renumbered = names(ids: [42, 7, 42, 99], addressByID: [42: 0x1000cc4a8, 7: 0x100143bd8, 99: 0x1000cc4a8])
        XCTAssertEqual(original, renumbered)
        XCTAssertEqual(original, ["exit_0x1000cc4a8", "exit_0x100143bd8", "exit_0x1000cc4a8_2", "exit_0x1000cc4a8_3"])
        XCTAssertEqual(original, names(ids: [0, 1, 0, 2], addressByID: [0: 0x1000cc4a8, 1: 0x100143bd8, 2: 0x1000cc4a8]))
        var allocator = PseudocodePrinter.RecoveryLabelAllocator()
        XCTAssertEqual(allocator.label(prefix: "loop", address: 0x1000), "loop_0x1000")
        XCTAssertEqual(allocator.label(prefix: "exit", address: 0x1000), "exit_0x1000")
        XCTAssertEqual(allocator.label(prefix: "loop", address: 0x1000), "loop_0x1000_2")
    }

    func testRecoveredLoopLabelsSurvivePhysicalBlockRenumbering() throws {
        let edges = [[1, 2], [0, 3], [], []]
        let original = CP2GraphFixture.function(edges)
        let starts = CP2GraphFixture.addresses(edges)
        let order = [0, 3, 1, 2]
        let end = try XCTUnwrap(original.endAddress)
        var reordered = original
        reordered.instructions = order.flatMap { node in
            let limit = node + 1 < starts.count ? starts[node + 1] : end
            return original.instructions.filter { $0.source.address >= starts[node] && $0.source.address < limit }
        }
        let a = CFGBuilder.buildCFG(instructions: original.instructions)
        let b = CFGBuilder.buildCFG(instructions: reordered.instructions)
        let oldIDs = Dictionary(uniqueKeysWithValues: a.blocks.map { (original.instructions[$0.startIndex].source.address, $0.index) })
        let newIDs = Dictionary(uniqueKeysWithValues: b.blocks.map { (reordered.instructions[$0.startIndex].source.address, $0.index) })
        XCTAssertNotEqual(oldIDs, newIDs, "Fixture must actually renumber CFG blocks")
        let before = PseudocodePrinter(options: .recoveryForSemantics).print(function: original)
        let after = PseudocodePrinter(options: .recoveryForSemantics).print(function: reordered)
        XCTAssertNil(before.structureFallback)
        XCTAssertNil(after.structureFallback)
        XCTAssertTrue(CP2TextOracle.equivalent(before, edges: edges))
        XCTAssertTrue(CP2TextOracle.equivalent(after, edges: edges))
        func loopNames(_ document: PseudocodeDocument) -> [String] {
            document.lines.compactMap { line in
                let text = line.text.trimmingCharacters(in: .whitespaces)
                return text.hasSuffix(": while (true) {") ? String(text.dropLast(16)) : nil
            }.sorted()
        }
        XCTAssertEqual(loopNames(before), ["loop_0x1000"])
        XCTAssertEqual(loopNames(before), loopNames(after))
    }

    func testCatalogueExamplesHaveAddressLabelsCompactGuardsAndKeywordTransfers() {
        var compact = 0, inverted = 0, labelled = 0, continueKeywords = 0
        for n in 1...3 {
            let choices = CP2GraphFixture.edgeChoices(n)
            let count = (0..<n).reduce(1) { value, _ in value * choices.count }
            for encoded in 0..<count {
                var code = encoded, edges: [[Int]] = []
                for _ in 0..<n { edges.append(choices[code % choices.count]); code /= choices.count }
                guard CP2GraphFixture.reachable(edges) else { continue }
                let function = CP2GraphFixture.function(edges)
                let before = PseudocodePrinter().print(function: function)
                let after = PseudocodePrinter(options: .recoveryOn).print(function: function)
                guard before.structureFallback != nil, after.structureFallback == nil else {
                    XCTAssertEqual(before.text, after.text)
                    continue
                }
                XCTAssertTrue(CP2TextOracle.equivalent(after, edges: edges))
                XCTAssertEqual(after.text, PseudocodePrinter(options: .recoveryOn).print(function: function).text)
                XCTAssertFalse(after.text.contains("cp2_exit_"))
                XCTAssertFalse(after.text.contains("cp2_loop_"))
                let executable = after.lines.filter { $0.kind == .instruction }
                for i in executable.indices {
                    let text = executable[i].text.trimmingCharacters(in: .whitespaces)
                    if text.contains("if ("), text.contains(") break ") || text.contains(") continue ") { compact += 1 }
                    if text.contains("if (x0_0 == 0x0)") { inverted += 1 }
                    if text.hasPrefix("exit_0x") || text.hasPrefix("loop_0x") {
                        labelled += 1
                        let hex = text.split(separator: ":")[0].split(separator: "_")[1].dropFirst(2)
                        XCTAssertNotNil(UInt64(hex, radix: 16))
                    }
                    if text == "} else {", i + 1 < executable.count {
                        XCTAssertNotEqual(executable[i + 1].text.trimmingCharacters(in: .whitespaces), "}")
                    }
                    for token in executable[i].tokens where token.text == "break" || token.text == "continue" {
                        XCTAssertEqual(token.kind, .keyword)
                        if token.text == "continue" { continueKeywords += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(compact, 0)
        XCTAssertGreaterThan(inverted, 0)
        XCTAssertGreaterThan(labelled, 0)
        XCTAssertGreaterThan(continueKeywords, 0)
    }
}
