import XCTest
@testable import MacScope

final class GotoLabelWellFormednessTests: XCTestCase {
    // Ignore comments and string literals: branch-looking user text is not control flow.
    private static func code(_ text: String) -> String {
        text.replacingOccurrences(of: #"/\*[\s\S]*?\*/|//[^\n]*|\"(?:\\.|[^\"\\])*\""#,
                                  with: "", options: .regularExpression)
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Invalid property expression: \(pattern)")
            return []
        }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) }
    }

    static func assertWellFormed(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let source = code(text)
        let gotos = captures(#"\bgoto\s+([^;\s]+)\s*;"#, in: source)
        let definitions = captures(#"(?m)^\s*([A-Za-z_]\w*)\s*:"#, in: source)
        XCTAssertFalse(source.contains("goto 0x"), text, file: file, line: line)
        for target in gotos {
            XCTAssertNotNil(target.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression),
                            "Invalid goto identifier: \(target)", file: file, line: line)
            XCTAssertEqual(definitions.filter { $0 == target }.count, 1,
                           "Expected exactly one definition for \(target)\n\(text)", file: file, line: line)
        }
    }

    static func assertGoto(_ text: String, target: UInt64, condition: String? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
        let matching = code(text).components(separatedBy: "\n").filter { row in
            captures(#"\bgoto\s+L_([0-9a-fA-F]+)\s*;"#, in: row)
                .contains { UInt64($0, radix: 16) == target }
        }
        XCTAssertFalse(matching.isEmpty, "Missing goto to \(String(target, radix: 16))\n\(text)", file: file, line: line)
        if let condition {
            XCTAssertTrue(matching.contains { $0.contains(condition) }, text, file: file, line: line)
        }
    }

    static func assertTransfer(_ text: String, target: UInt64, condition: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        let matching = code(text).components(separatedBy: "\n").filter { row in
            captures(#"\b__branch\(0x([0-9a-fA-F]+)\)"#, in: row)
                .contains { UInt64($0, radix: 16) == target }
        }
        XCTAssertFalse(matching.isEmpty, "Missing explicit branch to \(String(target, radix: 16))\n\(text)", file: file, line: line)
        if let condition {
            XCTAssertTrue(matching.contains { $0.contains(condition) }, text, file: file, line: line)
        }
        XCTAssertFalse(code(text).contains("goto 0x"), text, file: file, line: line)
    }

    private func row(_ address: UInt64, _ operation: MacIROperation) -> MacIRInstruction {
        .init(source: .init(address: address, byteText: "00 00 00 00", mnemonic: "redacted", operands: ""),
              operation: operation)
    }
    private var value: MacIRValue { .register(name: "x0", version: 0) }
    private func guardRow(_ address: UInt64, _ target: Int64) -> MacIRInstruction {
        row(address, .conditionalBranch(condition: "==", left: value, right: .immediate(0), target: .immediate(target)))
    }
    private func branch(_ address: UInt64, _ target: Int64) -> MacIRInstruction {
        row(address, .intrinsic(destination: nil, name: "branch", arguments: [.immediate(target)]))
    }
    private func function(_ instructions: [MacIRInstruction]) -> MacIRFunction {
        .init(name: "labels", startAddress: 0x1000, instructions: instructions)
    }
    private func check(_ function: MacIRFunction, options: DecompilerOptions = .default,
                       region: Region? = nil, file: StaticString = #filePath, line: UInt = #line) -> PseudocodeDocument {
        let printer = PseudocodePrinter(options: options)
        func render() -> PseudocodeDocument {
            if let region { return printer.print(function: function, forcedRegionForTesting: region) }
            return printer.print(function: function)
        }
        let document = render()
        Self.assertWellFormed(document.text, file: file, line: line)
        XCTAssertEqual(document.text, render().text, "Printing must be idempotent", file: file, line: line)
        return document
    }

    func testFlatConditionalUnconditionalAndSwitchTargets() {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let ir = function([
            guardRow(0x1000, 0x1010), guardRow(0x1004, 0x1006), // In range, no instruction there.
            branch(0x1008, 0x1000),
            row(0x100c, .switchDispatch(index: value, cases: [
                .init(value: 0, target: .immediate(0x1010)),
                .init(value: 1, target: .immediate(0x9000))
            ], defaultTarget: .immediate(0x1006))),
            row(0x1010, .returnValue(nil))
        ])
        let document = check(ir, options: options)
        Self.assertGoto(document.text, target: 0x1010)
        Self.assertGoto(document.text, target: 0x1000)
        Self.assertTransfer(document.text, target: 0x1006)
        Self.assertTransfer(document.text, target: 0x9000)
    }

    func testExternalUnconditionalAndComputedTransferAreExplicitBranches() {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let external = check(function([branch(0x1000, 0x9000)]), options: options)
        Self.assertTransfer(external.text, target: 0x9000)
        let computed = check(function([row(0x1000,
            .intrinsic(destination: nil, name: "branch", arguments: [value]))]), options: options)
        XCTAssertTrue(computed.text.contains("__branch(x0_0)"))
    }

    func testSizeGateAndUnresolvedCFGAndUnsupportedRegionFallbacks() {
        let ir = function([guardRow(0x1000, 0x9000), row(0x1004, .returnValue(nil))])
        var options = DecompilerOptions.default
        options.functionSizeGate = 1
        let size = check(ir, options: options)
        XCTAssertEqual(size.structureFallback, .sizeGate)
        Self.assertTransfer(size.text, target: 0x9000)
        let unresolved = check(ir)
        XCTAssertEqual(unresolved.structureFallback, .unstructurableCFG)
        Self.assertTransfer(unresolved.text, target: 0x9000)
        let internalIR = function([guardRow(0x1000, 0x1008),
                                   row(0x1004, .returnValue(nil)), row(0x1008, .returnValue(nil))])
        let unsupported = check(internalIR, region: .irreducible([0, 1, 2]))
        XCTAssertEqual(unsupported.structureFallback, .unsupportedRegion)
        Self.assertGoto(unsupported.text, target: 0x1008)
    }

    func testStructuredRowSwitchLabelsItsPrintedTargetsAndRejectsMissingTargets() {
        let ir = function([
            row(0x1000, .switchDispatch(index: value, cases: [
                .init(value: 0, target: .immediate(0x1004)),
                .init(value: 1, target: .immediate(0x9000))
            ], defaultTarget: .immediate(0x1008))),
            row(0x1004, .returnValue(.immediate(1))), row(0x1008, .returnValue(.immediate(2)))
        ])
        let document = check(ir, region: .sequence([
            .switchDispatch(index: 0, cases: [1], default: 2), .block(blockIndex: 1), .block(blockIndex: 2)
        ]))
        XCTAssertNil(document.structureFallback)
        Self.assertGoto(document.text, target: 0x1004)
        Self.assertGoto(document.text, target: 0x1008)
        Self.assertTransfer(document.text, target: 0x9000)
    }

    func testSharedConditionalRowLabelsItsPrintedTarget() {
        let ir = function([guardRow(0x1000, 0x1008), row(0x1004, .returnValue(nil)), row(0x1008, .returnValue(nil))])
        let document = check(ir, region: .sequence([
            .block(blockIndex: 0), .block(blockIndex: 1), .block(blockIndex: 2)
        ]))
        XCTAssertNil(document.structureFallback)
        Self.assertGoto(document.text, target: 0x1008)
    }

    func testGotoLeafTargetsAnotherPrintedRegion() {
        let ir = function([guardRow(0x1000, 0x1008), branch(0x1004, 0x1008), row(0x1008, .returnValue(nil))])
        let document = check(ir, region: .sequence([.gotoLeaf(blocks: [0, 1]), .block(blockIndex: 2)]))
        XCTAssertNil(document.structureFallback)
        Self.assertGoto(document.text, target: 0x1008)
    }

    func testRetainedSecondaryLoopExitUsesOneContinuationLabel() {
        var rows: [MacIRInstruction] = [
            row(0x1000, .intrinsic(destination: nil, name: "effect", arguments: [])),
            guardRow(0x1004, 0x1018),
            row(0x1008, .assign(destination: .register(name: "x1", version: 1), source: .immediate(1))),
            guardRow(0x100c, 0x1000),
            row(0x1010, .intrinsic(destination: nil, name: "continuation", arguments: [])),
            row(0x1018, .returnValue(nil))
        ]
        for index in rows.indices {
            if case .conditionalBranch = rows[index].operation { rows[index].source.mnemonic = "cbz" }
        }
        let document = check(function(rows))
        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
        Self.assertGoto(document.text, target: 0x1018)
    }

    func testPhiCFGAndUnresolvedPhiFallback() {
        let rows = [guardRow(0x1000, 0x100c), branch(0x1004, 0x100c), row(0x100c, .returnValue(value))]
        var ir = function(rows)
        ir.phis = [.init(blockAddress: 0x100c, destination: value, bitWidth: 64, incoming: [
            .init(predecessorAddress: 0x1000, value: .immediate(1)),
            .init(predecessorAddress: 0x1004, value: .immediate(2))
        ])]
        let phi = check(ir)
        XCTAssertTrue(phi.text.contains("__edge_"))
        Self.assertGoto(phi.text, target: 0x100c)
        ir.instructions[0] = guardRow(0x1000, 0x9000)
        let unresolved = check(ir)
        Self.assertTransfer(unresolved.text, target: 0x9000)
    }

    func testCroppedPreviewReportsTruncationAndStopsBeforeTargetLabel() {
        var rows = [InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "cbz",
                                   operands: "x0, 0x1100", hasBreakpoint: false)]
        rows += (1..<64).map { index in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: "unknown", operands: "", hasBreakpoint: false,
                           comment: "preview_row_\(index)")
        }
        rows.append(InstructionRow(address: 0x1100, bytes: "00 00 00 00", mnemonic: "ret",
                                   operands: "", hasBreakpoint: false, comment: "preview_tail"))
        let preview = PseudocodePrinter().printBoundedText(
            functionName: "preview", startAddress: 0x1000, instructions: rows, maximumUTF8Bytes: 256)

        XCTAssertTrue(preview.wasTruncated)
        XCTAssertLessThanOrEqual(preview.text.utf8.count, 256)
        XCTAssertGreaterThan(preview.emittedLineCount, 0)
        XCTAssertLessThan(preview.emittedLineCount, rows.count)
        XCTAssertFalse(preview.text.contains("preview_tail"))
        let source = Self.code(preview.text)
        let targets = Self.captures(#"\bgoto\s+([A-Za-z_]\w*)\s*;"#, in: source)
        let definitions = Self.captures(#"(?m)^\s*([A-Za-z_]\w*)\s*:"#, in: source)
        XCTAssertFalse(targets.isEmpty, preview.text)
        XCTAssertTrue(targets.contains { !definitions.contains($0) }, preview.text)
        // Cropped previews deliberately stop early and are exempt from assertWellFormed.
    }

    func testPrinterDoesNotRetainLabelPlansAcrossFunctions() {
        let printer = PseudocodePrinter()
        let first = function([guardRow(0x1000, 0x1008), row(0x1004, .returnValue(nil)), row(0x1008, .returnValue(nil))])
        let second = function([guardRow(0x1000, 0x9000), row(0x1004, .returnValue(nil))])
        Self.assertWellFormed(printer.print(function: first).text)
        let output = printer.print(function: second).text
        Self.assertWellFormed(output)
        Self.assertTransfer(output, target: 0x9000)
        XCTAssertEqual(output, PseudocodePrinter().print(function: second).text)
    }
}
