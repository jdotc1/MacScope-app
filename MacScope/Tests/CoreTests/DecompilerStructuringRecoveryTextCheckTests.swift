import Foundation
import XCTest
@testable import MacScope

#if DEBUG
/// These mutations use the real printer's output and its precise block-boundary
/// snapshot. CP2TextOracle remains a separate synthetic-payload implementation.
final class DecompilerStructuringRecoveryTextCheckTests: XCTestCase {
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

    private func snapshot(_ function: MacIRFunction,
                          file: StaticString = #filePath, line: UInt = #line) throws -> CP6RecoveryTextCheck.Snapshot {
        var options = DecompilerOptions.recoveryOn
        // Test the syntax/proof independently of the owner's readability gate.
        options.recoveryMaxTransferRatioPercent = 400
        options.recoveryMaxAdditionalNesting = 16
        let capture = CP6RecoveryTextCheck.Capture()
        var printer = PseudocodePrinter(options: options)
        printer.bypassRecoveryReadabilityForTesting = true
        printer.recoveryTextCheckCapture = capture
        let document = printer.print(function: function)
        XCTAssertNil(document.structureFallback, file: file, line: line)
        let result = try XCTUnwrap(capture.snapshot, file: file, line: line)
        XCTAssertTrue(result.isValid, failure(result), file: file, line: line)
        XCTAssertEqual(Array(document.lines.prefix(result.lines.count)), result.lines, file: file, line: line)
        return result
    }

    private func loopSnapshot() throws -> CP6RecoveryTextCheck.Snapshot {
        try snapshot(CP2GraphFixture.function([[1, 2], [0, 3], [], []]))
    }

    private func nestedSnapshot() throws -> CP6RecoveryTextCheck.Snapshot {
        try snapshot(CP2GraphFixture.function([[1, 5], [2, 4], [1, 3], [0, 4], [5], []]))
    }

    private func failure(_ snapshot: CP6RecoveryTextCheck.Snapshot) -> String {
        CP6RecoveryTextCheck.failure(lines: snapshot.lines, plan: snapshot.plan,
                                    cfg: snapshot.cfg, emission: snapshot.emission) ?? "valid"
    }

    func testParsesRealOutputIncludingEmptyBranchOnlyBlocks() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let result = try loopSnapshot()
            XCTAssertTrue(result.emission.blocks.contains { $0.payload.isEmpty },
                          "CFG branch trampolines must remain distinct observable visits")
            XCTAssertTrue(result.lines.contains { $0.text.contains("if (") && !$0.text.contains("{") },
                          "exercise the compact named-transfer form")
            XCTAssertTrue(result.lines.contains { $0.text.contains("loop_0x") })
            XCTAssertTrue(result.isValid)
        }
    }

    func testRejectsActualPredicatePolaritySwapAndUnknownCondition() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let original = try loopSnapshot()
            let branch = try XCTUnwrap(original.emission.branches.first)
            let inverted = try XCTUnwrap(branch.inverted)
            var swapped = original
            let existing = swapped.lines[branch.lineIndex].text.contains("if (\(branch.forward))")
                ? branch.forward : inverted
            let opposite = existing == branch.forward ? inverted : branch.forward
            swapped.lines[branch.lineIndex].text = swapped.lines[branch.lineIndex].text
                .replacingOccurrences(of: "if (\(existing))", with: "if (\(opposite))")
            XCTAssertFalse(swapped.isValid, "valid inverse syntax still has to preserve taken/fallthrough order")
            var changed = original
            changed.lines[branch.lineIndex].text = changed.lines[branch.lineIndex].text
                .replacingOccurrences(of: "if (\(existing))", with: "if (unrelated_predicate)")
            XCTAssertFalse(changed.isValid)
            var source = original
            source.lines[branch.lineIndex].source?.address += 4
            XCTAssertFalse(source.isValid, "a decision is attributed to its actual branch instruction")
        }
    }

    func testRejectsMissingDuplicateAndChangedRealPayloads() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let original = try loopSnapshot()
            let event = try XCTUnwrap(original.emission.blocks.first { !$0.payload.isEmpty })
            var changed = original
            changed.lines[event.start].text += " changed_statement();"
            XCTAssertFalse(changed.isValid)
            var missing = original
            missing.lines.remove(at: event.start)
            XCTAssertFalse(missing.isValid)
            var duplicate = original
            duplicate.lines.insert(duplicate.lines[event.start], at: event.start)
            XCTAssertFalse(duplicate.isValid)
        }
    }

    func testRejectsMissingAndMislabeledEmptyOccurrenceMetadata() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let original = try loopSnapshot()
            let empty = try XCTUnwrap(original.emission.blocks.firstIndex { $0.payload.isEmpty })
            var missing = original
            missing.emission.blocks.remove(at: empty)
            XCTAssertFalse(missing.isValid, "branch-only blocks cannot disappear behind epsilon edges")
            var changed = original
            changed.emission.blocks[empty].block = (changed.emission.blocks[empty].block + 1) % changed.cfg.blocks.count
            XCTAssertFalse(changed.isValid)
            var duplicate = original
            duplicate.emission.blocks.insert(duplicate.emission.blocks[empty], at: empty)
            XCTAssertFalse(duplicate.isValid)
        }
    }

    func testRejectsMalformedBracesAndUnboundNamedTransfers() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let original = try loopSnapshot()
            let close = try XCTUnwrap(original.lines.firstIndex { $0.text.trimmingCharacters(in: .whitespaces) == "}" })
            var missing = original
            missing.lines.remove(at: close)
            XCTAssertFalse(missing.isValid)
            var extraElse = original
            extraElse.lines[close].text = "} else {"
            XCTAssertFalse(extraElse.isValid)
            var unbound = original
            let transfer = try XCTUnwrap(unbound.lines.firstIndex { $0.text.contains("break exit_0x") })
            let label = try XCTUnwrap(transferLabel(unbound.lines[transfer].text, keyword: "break"))
            unbound.lines[transfer].text = unbound.lines[transfer].text.replacingOccurrences(of: label, with: "exit_0xdeadbeef")
            XCTAssertFalse(unbound.isValid)
        }
    }

    func testRejectsWrongBoundBreakTarget() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let original = try nestedSnapshot()
            var scopes: [String] = []
            var checked = false
            // Scopes declared before a transfer include its live ancestors. A
            // substituted closed label is rejected too; require at least one
            // *bound* wrong destination by excluding that parser failure explicitly.
            for (index, line) in original.lines.enumerated() {
                let value = line.text.trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("exit_0x"), value.hasSuffix(": {") { scopes.append(String(value.dropLast(3))) }
                guard let target = transferLabel(value, keyword: "break") else { continue }
                for alternate in scopes where alternate != target {
                    var changed = original
                    changed.lines[index].text = changed.lines[index].text.replacingOccurrences(of: target, with: alternate)
                    let reason = failure(changed)
                    if reason == "ordered text transition differs from plan or CFG" {
                        checked = true
                        XCTAssertFalse(changed.isValid)
                    }
                }
            }
            XCTAssertTrue(checked, "fixture must exercise a lexically valid wrong break destination")
        }
    }

    func testRejectsWrongBoundContinueTarget() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            // A branch from the inner loop to the outer header cannot be replaced
            // by the inner loop's own natural continuation.
            let original = try snapshot(CP2GraphFixture.function([[1, 3], [2, 3], [0, 1], []]))
            var labels: [String] = []
            var checked = false
            for (index, line) in original.lines.enumerated() {
                let value = line.text.trimmingCharacters(in: .whitespaces)
                if value.hasSuffix(": while (true) {") { labels.append(String(value.dropLast(16))) }
                guard let target = transferLabel(value, keyword: "continue") else { continue }
                for alternate in labels where alternate != target {
                    var changed = original
                    changed.lines[index].text = changed.lines[index].text.replacingOccurrences(of: target, with: alternate)
                    if failure(changed) == "ordered text transition differs from plan or CFG" {
                        checked = true
                        XCTAssertFalse(changed.isValid)
                    }
                }
            }
            XCTAssertTrue(checked, "fixture must exercise a lexically valid wrong loop continuation")
        }
    }

    func testPhiSharedTailBypassesRecoverySnapshotCapture() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let function = MacIRBuilder().buildFunction(name: "_shared", instructions: DecompilerStructuringRecoveryTests.sharedTail)
            let capture = CP6RecoveryTextCheck.Capture()
            var printer = PseudocodePrinter(options: .recoveryOn)
            printer.bypassRecoveryReadabilityForTesting = true
            printer.recoveryTextCheckCapture = capture
            let document = printer.print(function: function)
            XCTAssertTrue(function.phis.isEmpty)
            XCTAssertTrue(function.retainsPhiControlPresentation)
            XCTAssertNil(capture.snapshot)
            XCTAssertNil(document.regionTree)
            XCTAssertNil(document.structureFallback)
            XCTAssertTrue(document.text.contains("goto L_8228;"))
        }
    }

    func testChecksVisibleTerminationRatherThanManufacturingExitFromMetadata() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let original = try loopSnapshot()
            let terminal = try XCTUnwrap(original.emission.blocks.firstIndex {
                original.cfg.blocks[$0.block].successors.isEmpty
            })
            var changed = original
            let payloadIndex = try XCTUnwrap(changed.emission.blocks[terminal].payload.firstIndex {
                $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("return")
            })
            let lineIndex = changed.emission.blocks[terminal].start + payloadIndex
            changed.lines[lineIndex].text = "    ordinary_call();"
            changed.emission.blocks[terminal].payload[payloadIndex] = changed.lines[lineIndex]
            XCTAssertFalse(changed.isValid)
            XCTAssertEqual(failure(changed), "payload termination differs from CFG")
        }
    }

    func testParsesRenderedCompoundOperandsAndQuotedCommentDelimiters() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            var function = CP2GraphFixture.function([[1, 2], [0, 3], [], []])
            var changedBranches = 0
            for index in function.instructions.indices {
                guard case let .conditionalBranch(condition, _, right, target) = function.instructions[index].operation else { continue }
                let left: MacIRValue = changedBranches == 0
                    ? .binaryExpression(op: "&", left: .register(name: "x3", version: 0), right: .immediate(7))
                    : .symbol("\"quoted ) // { text\"")
                function.instructions[index].operation = .conditionalBranch(condition: condition, left: left, right: right, target: target)
                changedBranches += 1
            }
            let result = try snapshot(function)
            XCTAssertEqual(changedBranches, 2)
            XCTAssertTrue(result.lines.contains { $0.text.contains("quoted ) // { text") })
            XCTAssertTrue(result.isValid)
        }
    }

    func testAllowsDeterministicallyDisambiguatedAddressLabels() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            var result = try loopSnapshot()
            let scope = try XCTUnwrap(result.lines.first { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("exit_0x") })
            let label = String(scope.text.trimmingCharacters(in: .whitespaces).dropLast(3))
            for index in result.lines.indices {
                result.lines[index].text = result.lines[index].text.replacingOccurrences(of: label, with: label + "_2")
            }
            XCTAssertTrue(result.isValid, failure(result))
        }
    }

    func testUnnegatableCompoundKeepsForwardPredicateAndBracedFalseArm() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let (function, address) = try functionWithUnnegatableCompound(condition: "!=")
            let result = try snapshot(function)
            let branch = try XCTUnwrap(result.emission.branches.first { $0.source.address == address })
            XCTAssertEqual(branch.forward, "x1_0 || x2_0")
            XCTAssertNil(branch.inverted, "the existing renderer cannot faithfully negate bare register terms")
            XCTAssertEqual(result.lines[branch.lineIndex].text.components(separatedBy: " //")[0].trimmingCharacters(in: .whitespaces),
                           "if (x1_0 || x2_0) {")
            XCTAssertEqual(result.lines[branch.lineIndex + 1].text.trimmingCharacters(in: .whitespaces),
                           "} else {", "retain an empty then arm when the false arm cannot safely be inverted")
            XCTAssertFalse(result.lines.contains { $0.text.contains("x1_0 || x2_0 == 0x0") })
            XCTAssertTrue(result.isValid)
        }
    }

    func testUnnegatableCompoundEqualityRejectsRecoveryAndPreservesLegacyBytes() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let (function, _) = try functionWithUnnegatableCompound(condition: "==")
            let legacy = PseudocodePrinter().print(function: function)
            let capture = CP6RecoveryTextCheck.Capture()
            var printer = PseudocodePrinter(options: .recoveryOn)
            printer.bypassRecoveryReadabilityForTesting = true
            printer.recoveryTextCheckCapture = capture
            let result = printer.print(function: function)
            XCTAssertNotNil(result.structureFallback)
            XCTAssertNil(capture.snapshot, "unsafe forward rendering must not enter the recovery grammar")
            XCTAssertEqual(result.text, legacy.text)
            XCTAssertEqual(result.structureFallback, legacy.structureFallback)
        }
    }

    private func functionWithUnnegatableCompound(condition: String) throws -> (MacIRFunction, UInt64) {
        var function = CP2GraphFixture.function([[1, 2], [0, 3], [], []])
        let original = try snapshot(function)
        // Select an actual false-arm-only presentation, rather than assuming
        // a block number or relying on the renderer to choose an inversion.
        let branch = try XCTUnwrap(original.emission.branches.first { branch in
            guard let inverse = branch.inverted else { return false }
            return original.lines[branch.lineIndex].text.contains("if (\(inverse))")
        })
        let instructionIndex = original.cfg.blocks[branch.block].endIndex - 1
        guard case let .conditionalBranch(_, _, _, target) = function.instructions[instructionIndex].operation else {
            XCTFail("selected occurrence must be a conditional branch")
            throw NSError(domain: "RecoveryTextCheckFixture", code: 1)
        }
        function.instructions[instructionIndex].operation = .conditionalBranch(
            condition: condition,
            left: .binaryExpression(op: "||", left: .register(name: "x1", version: 0),
                                    right: .register(name: "x2", version: 0)),
            right: .immediate(0), target: target
        )
        return (function, branch.source.address)
    }

    private func transferLabel(_ text: String, keyword: String) -> String? {
        guard let range = text.range(of: keyword + " ") else { return nil }
        let remainder = text[range.upperBound...]
        guard let end = remainder.firstIndex(of: ";") else { return nil }
        return String(remainder[..<end])
    }
}
#endif
