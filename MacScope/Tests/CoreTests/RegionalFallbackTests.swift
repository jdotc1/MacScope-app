import Foundation
import XCTest
@testable import MacScope

final class RegionalFallbackTests: XCTestCase {
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

    private func row(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String,
        _ comment: String? = nil
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func input() -> PseudocodeRenderInput {
        let instructions = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "nop", "", "regional prefix gap"),
            row(0x1008, "b.eq", "0x1010", "regional prefix branch"),
            row(0x100c, "nop", "", "regional prefix body"),
            row(0x1010, "cmp", "x1, #0x0"),
            row(0x1014, "nop", "", "regional suffix gap"),
            row(0x1018, "b.eq", "0x1024", "regional suffix branch"),
            row(0x101c, "nop", "", "regional suffix body"),
            row(0x1020, "b", "0x1010", "regional suffix backedge"),
            row(0x1024, "ret", "")
        ]
        let function = FunctionSummary(
            id: UUID(),
            name: "_rgn_partial_suffix",
            startAddress: 0x1000,
            endAddress: 0x1028,
            confidence: 1
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [function],
            instructions: instructions,
            xrefs: [],
            hexBytes: Data()
        )
        return snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
    }

    private func lineCount(_ text: String, containing needle: String) -> Int {
        text.split(separator: "\n").filter { $0.contains(needle) }.count
    }

    /// Conditional raw gotos only; the flat renderer also spells unconditional branches as goto.
    private func conditionalGotoCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { $0.contains("goto ") && !$0.contains("unconditional branch") }.count
    }

    private func firstRegion(
        in node: PseudocodeRegionNode?,
        kind: PseudocodeRegionNode.Kind,
        conditionAddress: UInt64
    ) -> PseudocodeRegionNode? {
        guard let node else { return nil }
        if node.kind == kind && node.conditionSourceAddress == conditionAddress {
            return node
        }
        for child in node.children {
            if let result = firstRegion(
                in: child, kind: kind, conditionAddress: conditionAddress
            ) {
                return result
            }
        }
        return nil
    }

    private func suffixSourceLines(_ document: PseudocodeDocument) -> [String] {
        document.lines.compactMap { line in
            guard let address = line.sourceAddress, address >= 0x1010 else {
                return nil
            }
            return line.text
        }
    }

    func testDefaultExportStructuresPrefixAndRetainsUnsupportedTerminalInterval() {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            let input = input()
            XCTAssertEqual(input.startAddress, 0x1000)
            XCTAssertEqual(input.instructions.count, 10)

            var legacyOptions = DecompilerOptions.default
            legacyOptions.structureControlFlow = false
            let service = DocumentExportService()
            let legacy = service.pseudocodeText(for: input, options: legacyOptions)
            let actual = service.pseudocodeText(for: input, options: .default)

            // A named behavioral red on baseline: default currently falls back to
            // the same whole-function legacy path and cannot reduce this count.
            XCTAssertLessThan(conditionalGotoCount(actual), conditionalGotoCount(legacy), actual)
            XCTAssertEqual(conditionalGotoCount(actual), 1, actual)
            XCTAssertLessThanOrEqual(
                lineCount(actual, containing: "goto "),
                lineCount(legacy, containing: "goto "),
                actual
            )
            XCTAssertTrue(actual.split(separator: "\n").contains {
                $0.contains("if (") && $0.contains(") {")
                    && $0.contains("regional prefix branch")
            }, actual)
            // Only the suffix targets receive labels.
            GotoLabelWellFormednessTests.assertGoto(actual, target: 0x1024, condition: "arg1 == 0x0")
            GotoLabelWellFormednessTests.assertGoto(actual, target: 0x1010)
            GotoLabelWellFormednessTests.assertWellFormed(actual)
            let labelAddresses = actual.split(separator: "\n").compactMap { line -> UInt64? in
                let text = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":;", with: ":")
                guard text.hasPrefix("L_"), text.hasSuffix(":") else { return nil }
                return UInt64(text.dropFirst(2).dropLast(), radix: 16)
            }
            XCTAssertEqual(Set(labelAddresses), Set<UInt64>([0x1010, 0x1024]))
            XCTAssertFalse(actual.contains("while ("), actual)
            XCTAssertFalse(actual.contains("do {"), actual)
            for marker in [
                "regional prefix gap", "regional prefix branch", "regional prefix body",
                "regional suffix gap", "regional suffix branch", "regional suffix body",
                "regional suffix backedge"
            ] {
                XCTAssertEqual(lineCount(actual, containing: marker), 1, marker)
            }
            // This family must not silently enable the separate CP2 defaults.
            XCTAssertFalse(DecompilerOptions.default.recoverSharedTails)
            XCTAssertFalse(DecompilerOptions.default.recoverLoopExits)
            XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions)
        }
    }

    func testDefaultRegionKeepsPrefixMetadataAndExactSuffixSourcePartition() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let input = input()
            let function = MacIRBuilder().buildFunction(
                name: input.functionName, instructions: input.instructions
            )
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertNotNil(RegionTree.buildTerminalSuffixFallback(cfg: cfg, instructions: function.instructions),
                            "CFG: \(cfg); IR: \(function.instructions)")
            var legacyOptions = DecompilerOptions.default
            legacyOptions.structureControlFlow = false
            let legacy = PseudocodePrinter(options: legacyOptions).print(function: function)
            let actual = PseudocodePrinter(options: .default).print(function: function)

            XCTAssertEqual(
                actual.text,
                DocumentExportService().pseudocodeText(for: input, options: .default)
            )
            // Second named behavioral red: the baseline throws away this region
            // when the subsequent terminal loop interval is unsupported.
            let prefix = try XCTUnwrap(firstRegion(
                in: actual.regionTree, kind: .ifThen, conditionAddress: 0x1008
            ), actual.text)
            XCTAssertGreaterThanOrEqual(prefix.startLine, 1)
            XCTAssertLessThanOrEqual(prefix.startLine, prefix.endLine)
            XCTAssertLessThanOrEqual(prefix.endLine, actual.lines.count)
            XCTAssertTrue(actual.lines[prefix.startLine - 1].text.contains("if ("))
            XCTAssertEqual(
                actual.lines[prefix.endLine - 1].text.trimmingCharacters(in: .whitespaces),
                "}"
            )

            // Do not turn this first family into new nonadjacent-CMP loop recovery.
            XCTAssertNil(firstRegion(
                in: actual.regionTree, kind: .whileLoop, conditionAddress: 0x1018
            ))
            XCTAssertNil(firstRegion(
                in: actual.regionTree, kind: .doWhileLoop, conditionAddress: 0x1018
            ))
            XCTAssertEqual(suffixSourceLines(actual), suffixSourceLines(legacy))
            for address: UInt64 in [
                0x1004, 0x1008, 0x100c, 0x1014, 0x1018, 0x101c, 0x1020, 0x1024
            ] {
                XCTAssertEqual(actual.lines(sourcedAt: address).count, 1,
                               "source \(String(address, radix: 16))")
            }
            XCTAssertTrue(actual.lines(sourcedAt: 0x1008).first?.text.contains(") {") == true)
            GotoLabelWellFormednessTests.assertGoto(actual.lines(sourcedAt: 0x1018).map(\.text).joined(separator: "\n"), target: 0x1024)
            GotoLabelWellFormednessTests.assertWellFormed(actual.text)
            GotoLabelWellFormednessTests.assertGoto(actual.lines(sourcedAt: 0x1020).map(\.text).joined(separator: "\n"), target: 0x1010)
        }
    }
}
