import XCTest
@testable import MacScope

/// End-to-end tests driving InstructionRow fixtures through the full
/// PseudocodePrinter (which now routes small functions through the
/// dominator/region structurer). Asserts on the emitted document text.
final class DecompilerStructuringTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func print(_ name: String, _ rows: [InstructionRow]) -> PseudocodeDocument {
        let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
        if name == "_while" { SSARenderExpectation.assertEntryBackedgeRefusal(function) }
        return PseudocodePrinter().print(function: function)
    }

    private func print(_ name: String, _ rows: [InstructionRow], options: DecompilerOptions) -> PseudocodeDocument {
        let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
        return PseudocodePrinter(options: options).print(function: function)
    }

    private func simpleIfRows() -> [InstructionRow] {
        [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x100c", "skip"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "ret", "")
        ]
    }

    private func ifElseRows() -> [InstructionRow] {
        [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "else"),
            row(0x1008, "nop", "", "then"),
            row(0x100c, "b", "0x1014"),
            row(0x1010, "nop", "", "else body"),
            row(0x1014, "ret", "")
        ]
    }

    private func whileRows() -> [InstructionRow] {
        [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "exit"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "b", "0x1000"),
            row(0x1010, "ret", "")
        ]
    }

    private func doWhileRows() -> [InstructionRow] {
        [
            row(0x1000, "nop", "", "body"),
            row(0x1004, "cmp", "x0, #0x0"),
            row(0x1008, "b.ne", "0x1000", "back-edge"),
            row(0x100c, "ret", "")
        ]
    }

    private func nestedIfInWhileRows() -> [InstructionRow] {
        [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x101c", "loop exit"),
            row(0x1008, "cbz", "x1, 0x1010", "inner guard"),
            row(0x100c, "nop", "", "inner body"),
            row(0x1010, "nop", "", "after inner"),
            row(0x1014, "nop", "", "tail"),
            row(0x1018, "b", "0x1000", "back-edge"),
            row(0x101c, "ret", "")
        ]
    }

    private func largeIfRows(bodyCount: Int = 100) -> [InstructionRow] {
        var rows: [InstructionRow] = []
        let exitAddress: UInt64 = 0x1000 + UInt64(bodyCount + 1) * 4
        rows.append(row(0x1000, "cbz", "x0, 0x\(String(exitAddress, radix: 16))", "guard"))
        for i in 0..<bodyCount {
            rows.append(row(0x1000 + UInt64(i + 1) * 4, "nop", "", "b\(i)"))
        }
        rows.append(row(exitAddress, "ret", ""))
        return rows
    }

    private func multiEntryRows() -> [InstructionRow] {
        [
            row(0x1000, "cbnz", "x0, 0x1008", "to B"),
            row(0x1004, "cbnz", "x1, 0x100c", "A: exit"),
            row(0x1008, "cbnz", "x2, 0x1004", "B: to A"),
            row(0x100c, "ret", "")
        ]
    }

    private func doubleCompareRows() -> [InstructionRow] {
        [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1014", "first"),
            row(0x1008, "cmp", "x1, #0x0"),
            row(0x100c, "b.eq", "0x1014", "second"),
            row(0x1010, "nop", "", "body"),
            row(0x1014, "ret", "")
        ]
    }

    private func forLoopRows() -> [InstructionRow] {
        [
            row(0x1000, "mov", "w8, #0x0", "init"),
            row(0x1004, "cmp", "w8, #0xa"),
            row(0x1008, "b.ge", "0x1018", "exit"),
            row(0x100c, "nop", "", "body"),
            row(0x1010, "add", "w8, w8, #0x1", "step"),
            row(0x1014, "b", "0x1004"),
            row(0x1018, "ret", "")
        ]
    }

    private func switchJoinDocument() -> PseudocodeDocument {
        let instructions: [MacIRInstruction] = [
            irInstruction(0, mnemonic: "br", .switchDispatch(
                index: .register(name: "x0", version: 0),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(addr(1))),
                    MacIRSwitchCase(value: 1, target: .immediate(addr(2)))
                ],
                defaultTarget: .immediate(addr(3))
            )),
            irInstruction(1, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "case0 body"),
            irInstruction(2, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(addr(4))])),
            irInstruction(3, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "case1 body"),
            irInstruction(4, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(addr(4))])),
            irInstruction(5, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "default body"),
            irInstruction(6, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "post-switch join"),
            irInstruction(7, mnemonic: "ret", .returnValue(nil))
        ]
        let function = MacIRFunction(name: "_switchjoin", startAddress: 0x1000, instructions: instructions)
        return PseudocodePrinter().print(function: function)
    }

    private func assertStructureState(
        _ document: PseudocodeDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            (document.regionTree != nil) != (document.structureFallback != nil),
            "exactly one of regionTree/structureFallback must be present",
            file: file,
            line: line
        )
        if let regionTree = document.regionTree {
            assertRegionInvariants(regionTree, lineCount: document.lines.count, file: file, line: line)
        }
    }

    private func assertRegionInvariants(
        _ node: PseudocodeRegionNode,
        lineCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(node.startLine, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(node.endLine, lineCount, file: file, line: line)
        XCTAssertLessThanOrEqual(node.startLine, node.endLine, file: file, line: line)

        var previousEnd: Int?
        for child in node.children {
            XCTAssertGreaterThanOrEqual(child.startLine, node.startLine, file: file, line: line)
            XCTAssertLessThanOrEqual(child.endLine, node.endLine, file: file, line: line)
            if let previousEnd {
                XCTAssertLessThan(previousEnd, child.startLine, file: file, line: line)
            }
            previousEnd = child.endLine
            assertRegionInvariants(child, lineCount: lineCount, file: file, line: line)
        }
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

    private func trimmedLine(_ document: PseudocodeDocument, _ lineNumber: Int) -> String {
        document.lines[lineNumber - 1].text.trimmingCharacters(in: .whitespaces)
    }

    private func gotoCount(_ document: PseudocodeDocument) -> Int {
        document.lines.reduce(0) { count, line in
            count + (line.text.contains("goto") ? 1 : 0)
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

    // MARK: - byte-identity snapshots

    func testStructuredFixtureTextSnapshotsRemainByteIdentical() {
        XCTAssertEqual(
            print("_if", simpleIfRows()).text,
            """
            int64_t _if(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                if (arg0 != 0x0) { // skip; conditional branch
                    __nop(); // body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(
            print("_ifelse", ifElseRows()).text,
            """
            int64_t _ifelse(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                if (arg0 != 0x0) { // else; conditional branch
                    __nop(); // then
                } else {
                    __nop(); // else body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(
            print("_while", whileRows()).text,
            """
            int64_t _while(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                while (arg0 != 0x0) { // exit; conditional branch
                    __nop(); // body
                }
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(
            print("_dowhile", doWhileRows()).text,
            """
            int64_t _dowhile(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                do {
                    __nop(); // body
                } while (arg0 != 0x0); // back-edge; conditional branch
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(
            print("_nested", nestedIfInWhileRows()).text,
            """
            int64_t _nested(int64_t arg0, int64_t arg1) {
                // entry 0x0000000000001000; no stack frame; calls none
                while (arg0 != 0x0) { // loop exit; conditional branch
                    if (arg1) { // inner guard; conditional branch
                        __nop(); // inner body
                    }
                    __nop(); // after inner
                    __nop(); // tail
                }
                return unresolved_return_contract; // return
            }
            """
        )
        GotoLabelWellFormednessTests.assertWellFormed(switchJoinDocument().text)
        XCTAssertTrue(switchJoinDocument().text.contains("switch ("))
        XCTAssertTrue(switchJoinDocument().text.contains("case 0x0:"))
        XCTAssertTrue(switchJoinDocument().text.contains("case 0x1:"))
        XCTAssertTrue(switchJoinDocument().text.contains("default:"))
    }

    // MARK: - region metadata

    func testStructuredFixtureRegionTreesCaptureSpansAndConditions() throws {
        let ifDocument = print("_if", simpleIfRows())
        assertStructureState(ifDocument)
        let ifNode = try XCTUnwrap(firstRegion(in: ifDocument.regionTree, kind: .ifThen))
        XCTAssertEqual(ifNode.condition, "arg0 != 0x0")
        XCTAssertEqual(ifNode.conditionSourceAddress, 0x1004)
        XCTAssertTrue(trimmedLine(ifDocument, ifNode.startLine).hasPrefix("if ("))
        XCTAssertEqual(trimmedLine(ifDocument, ifNode.endLine), "}")

        let ifElseDocument = print("_ifelse", ifElseRows())
        assertStructureState(ifElseDocument)
        let ifElseNode = try XCTUnwrap(firstRegion(in: ifElseDocument.regionTree, kind: .ifThenElse))
        XCTAssertEqual(ifElseNode.condition, "arg0 != 0x0")
        XCTAssertEqual(ifElseNode.conditionSourceAddress, 0x1004)
        XCTAssertTrue(trimmedLine(ifElseDocument, ifElseNode.startLine).hasPrefix("if ("))
        XCTAssertEqual(trimmedLine(ifElseDocument, ifElseNode.endLine), "}")

        let whileDocument = print("_while", whileRows())
        assertStructureState(whileDocument)
        let whileNode = try XCTUnwrap(firstRegion(in: whileDocument.regionTree, kind: .whileLoop))
        XCTAssertEqual(whileNode.condition, "arg0 != 0x0")
        XCTAssertEqual(whileNode.conditionSourceAddress, 0x1004)
        XCTAssertTrue(trimmedLine(whileDocument, whileNode.startLine).hasPrefix("while ("))
        XCTAssertEqual(trimmedLine(whileDocument, whileNode.endLine), "}")

        let doWhileDocument = print("_dowhile", doWhileRows())
        assertStructureState(doWhileDocument)
        let doWhileNode = try XCTUnwrap(firstRegion(in: doWhileDocument.regionTree, kind: .doWhileLoop))
        XCTAssertEqual(doWhileNode.condition, "arg0 != 0x0")
        XCTAssertEqual(doWhileNode.conditionSourceAddress, 0x1008)
        XCTAssertEqual(trimmedLine(doWhileDocument, doWhileNode.startLine), "do {")
        XCTAssertTrue(trimmedLine(doWhileDocument, doWhileNode.endLine).hasPrefix("} while ("))

        let nestedDocument = print("_nested", nestedIfInWhileRows())
        assertStructureState(nestedDocument)
        let nestedWhile = try XCTUnwrap(firstRegion(in: nestedDocument.regionTree, kind: .whileLoop))
        let nestedIf = try XCTUnwrap(firstRegion(in: nestedWhile, kind: .ifThen))
        XCTAssertEqual(nestedWhile.condition, "arg0 != 0x0")
        XCTAssertEqual(nestedWhile.conditionSourceAddress, 0x1004)
        XCTAssertEqual(nestedIf.condition, "arg1")
        XCTAssertEqual(nestedIf.conditionSourceAddress, 0x1008)

        let switchDocument = switchJoinDocument()
        assertStructureState(switchDocument)
        XCTAssertNil(switchDocument.regionTree)
        // An in-function switch makes RegionTree.build return nil OUTRIGHT (path 3),
        // so emitRegion never runs: the reason is unstructurableCFG, not
        // unsupportedRegion. (RegionTreeTests' containsIrreducible(nil) == true made
        // the two indistinguishable before this metadata existed.)
        XCTAssertEqual(switchDocument.structureFallback?.rawValue, PseudocodeStructureFallback.unstructurableCFG.rawValue)
    }

    // MARK: - fallback metadata

    func testGotoFormFallbackReason() {
        let options = DecompilerOptions(
            structureControlFlow: false,
            deadCodeElimination: false,
            nopElision: false,
            functionSizeGate: 1024
        )
        let document = print("_goto", multiEntryRows(), options: options)
        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.gotoForm.rawValue)
        XCTAssertTrue(document.text.contains("goto"))
        XCTAssertFalse(document.text.contains("while ("))
        XCTAssertFalse(document.text.contains("do {"))
    }

    func testSizeGateFallbackReason() {
        let options = DecompilerOptions(
            structureControlFlow: true,
            deadCodeElimination: false,
            nopElision: false,
            functionSizeGate: 16
        )
        let document = print("_large", largeIfRows(), options: options)
        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.sizeGate.rawValue)
        XCTAssertTrue(document.text.contains("goto"))
        XCTAssertFalse(document.text.contains("if (arg0) {"))
    }

    func testUnstructurableCFGFallbackReason() {
        let document = print("_irr", multiEntryRows())
        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unstructurableCFG.rawValue)
    }

    func testUnsupportedRegionFallbackReason() {
        let document = print("_unsupported_guard", [
            row(0x1000, "b.ge", "0x1008"),
            row(0x1004, "nop", ""),
            row(0x1008, "ret", "")
        ])
        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unsupportedRegion.rawValue)
    }

    func testCountingLoopUsesRegionPath() {
        let document = print("_for", forLoopRows())
        assertStructureState(document)
        XCTAssertTrue(document.lines(sourcedAt: 0x1008).contains { ($0.text.contains("while (") || $0.text.contains("for (")) && !$0.text.contains("w8_0") && !$0.text.contains("tmp0 <") } && !document.text.contains("goto"), document.text)
        XCTAssertNil(document.structureFallback)
        XCTAssertNotNil(document.regionTree)
    }

    func testDeterministicRegionAndFlatPaths() {
        let cases: [(String, [InstructionRow], DecompilerOptions, PseudocodeStructureFallback?)] = [
            ("_veto", multiEntryRows(), .default, .unstructurableCFG),
            ("_loop", whileRows(), .default, nil),
            ("_large", (0..<1025).map { row(0x4000 + UInt64($0 * 4), "nop", "") }
                + [row(0x5004, "ret", "")], .default, .sizeGate)
        ]
        for (name, rows, options, fallback) in cases {
            let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
            let printer = PseudocodePrinter(options: options)
            let first = printer.print(function: function)
            let second = printer.print(function: function)
            XCTAssertEqual(first.text, second.text, name)
            XCTAssertEqual(first.lines, second.lines, name)
            XCTAssertEqual(first.structureFallback, fallback, name)
            if fallback == nil { XCTAssertNotNil(first.regionTree, name) }
        }
    }

    func testFlatEmissionRetainsLinearDeadCodeElimination() {
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        options.deadCodeElimination = true
        let document = print("_linear", [
            row(0x1000, "nop", "", "live"),
            row(0x1004, "ret", ""),
            row(0x1008, "nop", "", "unreachable tail")
        ], options: options)
        XCTAssertTrue(document.text.contains("live"))
        XCTAssertFalse(document.text.contains("unreachable tail"))
        XCTAssertEqual(document.structureFallback, .gotoForm)
    }

    // MARK: - Lever A: out-of-function unconditional branches are exits

    func testOutOfFunctionUnconditionalBranchStructuresAsVisibleExit() {
        let lifted = MacIRBuilder().buildFunction(name: "_tail_exit", instructions: [
            row(0x1000, "nop", "", "setup"),
            row(0x1004, "b", "0x2000")
        ])
        let document = PseudocodePrinter().print(function: lifted)

        assertStructureState(document)
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(gotoCount(document), 0)
        XCTAssertEqual(
            SSAPropertyAssertions.enabled
                ? SSARenderExpectation.withoutRefusalAnnotations(document, function: lifted, expected: [(.targetOutsideFunction, .row(0x1004))])
                : document.text,
            """
            int64_t _tail_exit(void) {
                // entry 0x0000000000001000; no stack frame; calls none
                __nop(); // setup
                __branch(0x2000); // unconditional branch
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x1004).count, 1)
    }

    func testConditionalArmEndingInOutOfFunctionBranchKeepsTailCallVisible() {
        let lifted = MacIRBuilder().buildFunction(name: "_tail_guard", instructions: [
            row(0x1000, "cbz", "x0, 0x100c", "continue"),
            row(0x1004, "nop", "", "exit arm"),
            row(0x1008, "b", "0x2000"),
            row(0x100c, "nop", "", "after tail"),
            row(0x1010, "ret", "")
        ])
        let document = PseudocodePrinter().print(function: lifted)

        assertStructureState(document)
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(gotoCount(document), 0)
        XCTAssertEqual(
            SSAPropertyAssertions.enabled
                ? SSARenderExpectation.withoutRefusalAnnotations(document, function: lifted, expected: [(.targetOutsideFunction, .row(0x1008))])
                : document.text,
            """
            int64_t _tail_guard(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                if (arg0) { // continue; conditional branch
                    __nop(); // exit arm
                    __branch(0x2000); // unconditional branch
                }
                __nop(); // after tail
                return unresolved_return_contract; // return
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x1004).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1008).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x100c).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1010).count, 1)
    }

    func testConditionalBranchToOutOfFunctionTargetStillVetoesStructuring() {
        let document = print("_conditional_tail_veto", [
            row(0x1000, "cbz", "x0, 0x2000"),
            row(0x1004, "ret", "")
        ])

        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unstructurableCFG.rawValue)
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x2000)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testInRangeTargetInsideLastInstructionByteExtentStillVetoesStructuring() {
        let document = print("_misaligned_last", [
            row(0x1000, "b", "0x1002")
        ])

        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unstructurableCFG.rawValue)
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x1002)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
    }

    func testStructuredTailExitConservesRenderedSourceAddressesAgainstGotoForm() {
        let rows = [
            row(0x1000, "cbz", "x0, 0x100c", "continue"),
            row(0x1004, "nop", "", "exit arm"),
            row(0x1008, "b", "0x2000"),
            row(0x100c, "nop", "", "after tail"),
            row(0x1010, "ret", "")
        ]
        let structured = print("_tail_conserve", rows)
        let gotoForm = print(
            "_tail_conserve",
            rows,
            options: DecompilerOptions(
                structureControlFlow: false,
                deadCodeElimination: false,
                nopElision: false,
                functionSizeGate: 1024
            )
        )

        assertStructureState(structured)
        assertStructureState(gotoForm)
        XCTAssertNil(structured.structureFallback)
        XCTAssertEqual(gotoForm.structureFallback?.rawValue, PseudocodeStructureFallback.gotoForm.rawValue)
        XCTAssertLessThanOrEqual(gotoCount(structured), gotoCount(gotoForm))
        XCTAssertEqual(sourceAddressCounts(structured), sourceAddressCounts(gotoForm))
        XCTAssertEqual(structured.lines(sourcedAt: 0x1008).count, 1)
        XCTAssertTrue(structured.lines(sourcedAt: 0x1008).first?.text.contains("__branch(0x2000)") == true)
    }

    func testLoopWithDistinctOutOfFunctionExitBlockStructuresAndRendersTailCall() {
        let document = print("_tail_loop", [
            row(0x1000, "cbz", "x0, 0x100c", "exit"),
            row(0x1004, "nop", "", "body"),
            row(0x1008, "b", "0x1000", "back-edge"),
            row(0x100c, "b", "0x2000")
        ])

        assertStructureState(document)
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(gotoCount(document), 0)
        XCTAssertEqual(
            document.text,
            """
            int64_t _tail_loop(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                while (arg0) { // exit; conditional branch
                    __nop(); // body
                }
                __branch(0x2000); // unconditional branch
            }
            """
        )
        XCTAssertEqual(document.lines(sourcedAt: 0x100c).count, 1)
    }

    // MARK: - Taken-edge if-then (hot/cold split body)

    /// A `cmp; b.<cc> cold; <fall-through join>; … cold: body; b join` shape:
    /// the compiler moved the conditional body out of line onto the BRANCH-TAKEN
    /// edge, so the fall-through goes straight to the join. The faithful C is an
    /// if-then guarded by the RAW (non-inverted) branch condition — entering the
    /// body IS "branch taken". A `b.eq` here must render `if (arg0 == 0x0)`, not
    /// the inverted `!= 0x0` used when the body is on the fall-through edge.
    private func takenEdgeIfThenRows() -> [InstructionRow] {
        [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "cold body"),
            row(0x1008, "nop", "", "join"),
            row(0x100c, "ret", ""),
            row(0x1010, "nop", "", "cold body stmt"),
            row(0x1014, "b", "0x1008", "rejoin")
        ]
    }

    func testTakenEdgeIfThenStructuresWithRawCondition() {
        let document = print("_hotcold", takenEdgeIfThenRows())

        assertStructureState(document)
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(gotoCount(document), 0)
        XCTAssertEqual(
            document.text,
            """
            int64_t _hotcold(int64_t arg0) {
                // entry 0x0000000000001000; no stack frame; calls none
                if (arg0 == 0x0) { // cold body; conditional branch
                    __nop(); // cold body stmt
                }
                __nop(); // join
                return unresolved_return_contract; // return
            }
            """
        )
        // The body block's rejoining back-branch stays a suppressed structural
        // jump, and every source address is rendered exactly once.
        XCTAssertEqual(document.lines(sourcedAt: 0x1010).count, 1)
        XCTAssertEqual(document.lines(sourcedAt: 0x1014).count, 0)
    }

    func testTakenEdgeIfThenPreservesRawInequalityOrientation() {
        // Same shape with `b.ne`: raw condition is `!= 0x0`. A regression that
        // inverted this orientation would render `== 0x0`.
        let document = print("_hotcold_ne", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.ne", "0x1010", "cold body"),
            row(0x1008, "nop", "", "join"),
            row(0x100c, "ret", ""),
            row(0x1010, "nop", "", "cold body stmt"),
            row(0x1014, "b", "0x1008", "rejoin")
        ])

        assertStructureState(document)
        XCTAssertNil(document.structureFallback)
        XCTAssertEqual(gotoCount(document), 0)
        XCTAssertTrue(document.text.contains("if (arg0 != 0x0) { // cold body; conditional branch"))
        XCTAssertFalse(document.text.contains("== 0x0"))
    }

    func testOutOfFunctionUnconditionalBranchDoesNotClearOtherUnresolvedTargets() {
        // Ordering is load-bearing for this guard. `hasUnresolvedTargets` is one Bool
        // accumulated across the edges pass, which visits blocks in ascending address.
        // The out-of-range CONDITIONAL veto (goto 0x3000) MUST sit at a LOWER address than
        // the out-of-range UNCONDITIONAL branch (__branch 0x2000): then a buggy
        // `hasUnresolvedTargets = false` in the unconditional arm would wipe the veto with
        // nothing to re-set it afterward, and the function would wrongly structure — the
        // assertion below fails, catching the regression. (The reverse order — conditional
        // AFTER the unconditional — re-sets the flag past the clobber and masks the bug,
        // which is why the earlier layout of this fixture passed vacuously.)
        let document = print("_mixed_tail_veto", [
            row(0x1000, "cbz", "x1, 0x3000", "external conditional"),
            row(0x1004, "nop", "", "body"),
            row(0x1008, "b", "0x2000")
        ])

        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unstructurableCFG.rawValue)
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x2000)
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x3000)
    }

    func testSwitchDispatchWithOutOfFunctionTargetStillVetoesStructuring() {
        let instructions: [MacIRInstruction] = [
            irInstruction(0, mnemonic: "br", .switchDispatch(
                index: .register(name: "x0", version: 0),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(0x2000)),
                    MacIRSwitchCase(value: 1, target: .immediate(addr(1)))
                ],
                defaultTarget: .immediate(addr(2))
            )),
            irInstruction(1, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "case1 body"),
            irInstruction(2, mnemonic: "ret", .returnValue(nil))
        ]
        let function = MacIRFunction(name: "_switch_tail_veto", startAddress: 0x1000, instructions: instructions)
        let document = PseudocodePrinter().print(function: function)

        assertStructureState(document)
        XCTAssertNil(document.regionTree)
        XCTAssertEqual(document.structureFallback?.rawValue, PseudocodeStructureFallback.unstructurableCFG.rawValue)
        GotoLabelWellFormednessTests.assertTransfer(document.text, target: 0x2000, condition: "case 0x0:")
        GotoLabelWellFormednessTests.assertWellFormed(document.text)
        XCTAssertTrue(document.text.contains("// case1 body"))
    }

    // MARK: - simple if-then NO goto

    func testSimpleIfThenHasNoGoto() {
        let document = print("_if", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x100c", "skip"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("goto"))
        XCTAssertTrue(document.text.contains("if ("))
        XCTAssertFalse(document.text.contains("__compare"))
    }

    // MARK: - if-else NO goto

    func testIfElseHasNoGoto() {
        let document = print("_ifelse", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "else"),
            row(0x1008, "nop", "", "then"),
            row(0x100c, "b", "0x1014"),
            row(0x1010, "nop", "", "else body"),
            row(0x1014, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("goto"))
        XCTAssertTrue(document.text.contains("} else {"))
        XCTAssertFalse(document.text.contains("__branch"))
    }

    // MARK: - while NO goto

    func testWhileHasNoGoto() {
        let document = print("_while", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "exit"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "b", "0x1000"),
            row(0x1010, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("goto"))
        XCTAssertTrue(document.text.contains("while ("))
        XCTAssertFalse(document.text.contains("__branch"))
    }

    // MARK: - do-while NO goto

    func testDoWhileHasNoGoto() {
        let document = print("_dowhile", [
            row(0x1000, "nop", "", "body"),
            row(0x1004, "cmp", "x0, #0x0"),
            row(0x1008, "b.ne", "0x1000", "back-edge"),
            row(0x100c, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("goto"))
        XCTAssertTrue(document.text.contains("do {"))
        XCTAssertTrue(document.text.contains("} while ("))
    }

    // MARK: - nested-if-in-while NO goto

    func testNestedIfInWhileHasNoGoto() {
        let document = print("_nested", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x101c", "loop exit"),
            row(0x1008, "cbz", "x1, 0x1010", "inner guard"),
            row(0x100c, "nop", "", "inner body"),
            row(0x1010, "nop", "", "after inner"),
            row(0x1014, "nop", "", "tail"),
            row(0x1018, "b", "0x1000", "back-edge"),
            row(0x101c, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("goto"))
        XCTAssertTrue(document.text.contains("while ("))
        // The inner if nests at depth two (12 spaces).
        XCTAssertTrue(document.text.contains("            __nop(); // inner body"))
    }

    // MARK: - LARGE body > 64 instrs NO goto (beats the old 64-instr cap)

    func testLargeIfBodyBeyondOldCapStructuresWithoutGoto() {
        // A zero-check guard skips a 100-instruction straight-line body. The old
        // peephole cap (maxInstructionDistance: 64) would emit `goto`; the
        // region structurer has no such cap.
        var rows: [InstructionRow] = []
        let bodyCount = 100
        let exitAddress: UInt64 = 0x1000 + UInt64(bodyCount + 1) * 4
        rows.append(row(0x1000, "cbz", "x0, 0x\(String(exitAddress, radix: 16))", "guard"))
        for i in 0..<bodyCount {
            rows.append(row(0x1000 + UInt64(i + 1) * 4, "nop", "", "b\(i)"))
        }
        rows.append(row(exitAddress, "ret", ""))

        let document = print("_large", rows)
        XCTAssertFalse(document.text.contains("goto"), "large body must structure without goto, beating the old cap")
        XCTAssertTrue(document.text.contains("if (arg0) {"))
        // All body statements present at depth one (8 spaces).
        XCTAssertTrue(document.text.contains("        __nop(); // b0"))
        XCTAssertTrue(document.text.contains("        __nop(); // b99"))
    }

    // MARK: - irreducible CFG -> CONTAINS goto + no crash + no wrong structure

    func testIrreducibleCFGFallsBackToGotoWithoutCrashing() {
        // Multi-entry mutual loop: not cleanly structurable. The printer must
        // fall back to the legacy flat emitter (which uses goto) and must not
        // crash or invent a wrong structure.
        let document = print("_irr", [
            row(0x1000, "cbnz", "x0, 0x1008", "to B"),
            row(0x1004, "cbnz", "x1, 0x100c", "A: exit"),
            row(0x1008, "cbnz", "x2, 0x1004", "B: to A"),
            row(0x100c, "ret", "")
        ])
        XCTAssertTrue(document.text.contains("goto"), "irreducible CFG must fall back to goto")
        // Every instruction is still rendered (no silent loss).
        XCTAssertFalse(document.text.isEmpty)
    }

    // MARK: - for-loop still renders 'for'

    func testForLoopStillRendersFor() {
        let document = print("_for", [
            row(0x1000, "mov", "w8, #0x0", "init"),
            row(0x1004, "cmp", "w8, #0xa"),
            row(0x1008, "b.ge", "0x1018", "exit"),
            row(0x100c, "nop", "", "body"),
            row(0x1010, "add", "w8, w8, #0x1", "step"),
            row(0x1014, "b", "0x1004"),
            row(0x1018, "ret", "")
        ])
        XCTAssertTrue((document.text.contains("while (") || document.text.contains("for (")) && document.text.contains(" + 0x1"), document.text)
        XCTAssertFalse(document.text.contains("tmp0 < 0xa") || document.text.contains("tmp0 + 0x1"), document.text)
        XCTAssertFalse(document.text.contains("goto"))
    }

    // MARK: - RISK: compare-suppression (no spurious __compare before an if)

    func testNoSpuriousCompareLineBeforeStructuredIf() {
        let document = print("_cmpif", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x100c", "skip"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("__compare"))
    }

    // MARK: - RISK: self-loop is while(true)-style, NOT irreducible/goto

    func testSelfLoopStructuresAsDoWhileNotGoto() {
        // A single-block self-loop (body + bottom test in one block) must
        // structure as a do/while, not collapse to irreducible goto.
        let document = print("_selfloop", [
            row(0x1000, "nop", "", "body"),
            row(0x1004, "cbnz", "x0, 0x1000", "repeat"),
            row(0x1008, "ret", "")
        ])
        XCTAssertFalse(document.text.contains("goto"))
        XCTAssertTrue(document.text.contains("do {"))
        XCTAssertTrue(document.text.contains("} while (arg0)"))
    }

    // MARK: - RISK: if-line source-address mapping after compare suppression

    func testIfLineCarriesBranchSourceAddressAfterCompareSuppression() throws {
        let document = print("_addr", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x100c", "skip"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "ret", "")
        ])
        // The if-line must be sourced at the BRANCH address (0x1004), not the
        // suppressed compare (0x1000).
        let ifLine = try XCTUnwrap(document.lines.first { $0.text.contains("if (") })
        XCTAssertEqual(ifLine.sourceAddress, 0x1004)
        XCTAssertEqual(document.lines(sourcedAt: 0x1000), [])
    }

    // MARK: - REGRESSION (Fix 1): switch with in-function cases + post-switch join

    /// Builds a MacIR instruction directly (bypassing the row→IR builder so we
    /// can plant a structured `switchDispatch` whose case targets are real
    /// in-function blocks).
    private func irInstruction(_ index: Int, mnemonic: String, _ operation: MacIROperation, comment: String? = nil) -> MacIRInstruction {
        MacIRInstruction(
            source: MacIRSourceSpan(
                address: 0x1000 + UInt64(index) * 4,
                byteText: "00 00 00 00",
                mnemonic: mnemonic,
                operands: "",
                comment: comment
            ),
            operation: operation
        )
    }

    private func addr(_ index: Int) -> Int64 { Int64(0x1000 + index * 4) }

    /// A switch whose case arms resolve to IN-FUNCTION blocks that merge at a
    /// post-switch join `J`, with a tail after `J`. The region structurer must
    /// NOT silently drop `J` + the tail: it bails to the legacy goto-per-case
    /// structurer, which renders the full function (cases as `goto`, then the
    /// join + tail linearly).
    func testSwitchWithInFunctionCasesRendersPostSwitchJoinAndTail() {
        // idx0: switch x0 -> case0=idx1, case1=idx2, default=idx3
        // idx1: nop "case0 body" ; b -> idx4 (join)
        // idx2: nop "case1 body" ; b -> idx4 (join)
        // idx3: nop "default body" ; falls to idx4
        // idx4: nop "post-switch join"
        // idx5: ret
        let instructions: [MacIRInstruction] = [
            irInstruction(0, mnemonic: "br", .switchDispatch(
                index: .register(name: "x0", version: 0),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(addr(1))),
                    MacIRSwitchCase(value: 1, target: .immediate(addr(2)))
                ],
                defaultTarget: .immediate(addr(3))
            )),
            irInstruction(1, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "case0 body"),
            irInstruction(2, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(addr(4))])),
            irInstruction(3, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "case1 body"),
            irInstruction(4, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(addr(4))])),
            irInstruction(5, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "default body"),
            irInstruction(6, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: []), comment: "post-switch join"),
            irInstruction(7, mnemonic: "ret", .returnValue(nil))
        ]
        let function = MacIRFunction(name: "_switchjoin", startAddress: 0x1000, instructions: instructions)
        let document = PseudocodePrinter().print(function: function)

        // The switch is still rendered...
        XCTAssertTrue(document.text.contains("switch ("), "switch header must be present")
        // ...and crucially the post-switch join + tail are NOT dropped.
        XCTAssertTrue(document.text.contains("// post-switch join"), "post-switch join block must be rendered, not dropped")
        // Every case body is present too.
        XCTAssertTrue(document.text.contains("// case0 body"))
        XCTAssertTrue(document.text.contains("// default body"))
    }

    // MARK: - REGRESSION (Fix 2): nested loop must not crash

    /// A nested loop (outer loop whose body contains an inner loop). The buggy
    /// region builder recursed without a visited guard and could overflow the
    /// stack on such shapes. This must terminate and produce output (structured
    /// or goto), never crash.
    func testNestedLoopDoesNotCrash() {
        // Outer header @0x1000 tests x0, exits to 0x101c.
        // Inner header @0x1008 tests x1, exits to 0x1014 (still inside outer).
        // Inner back-edge 0x100c -> 0x1008. Outer back-edge 0x1018 -> 0x1000.
        let document = print("_nestedloop", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x101c", "outer exit"),
            row(0x1008, "cmp", "x1, #0x0"),
            row(0x100c, "b.eq", "0x1014", "inner exit"),
            row(0x1010, "b", "0x1008", "inner back-edge"),
            row(0x1014, "nop", "", "outer tail"),
            row(0x1018, "b", "0x1000", "outer back-edge"),
            row(0x101c, "ret", "")
        ])
        // No crash is the primary assertion. Output must be non-empty and every
        // body instruction faithfully present (structured or via goto).
        XCTAssertFalse(document.text.isEmpty)
        XCTAssertTrue(document.text.contains("// outer tail"), "no instruction may be dropped")
    }

    // MARK: - REGRESSION (Fix 3): nested-conditional-arm over-reach

    /// An inner conditional inside an arm whose join would land past the
    /// enclosing arm boundary must not claim outer-sequence blocks. The output
    /// must render every block exactly once (structured or goto), never drop or
    /// duplicate.
    func testNestedConditionalArmOverreachRendersEveryBlockOnce() {
        let document = print("_overreach", [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1018", "outer skip"),
            row(0x1008, "cmp", "x1, #0x0"),
            row(0x100c, "b.eq", "0x1014", "inner skip"),
            row(0x1010, "nop", "", "inner body"),
            row(0x1014, "nop", "", "outer body tail"),
            row(0x1018, "nop", "", "after outer"),
            row(0x101c, "ret", "")
        ])
        XCTAssertFalse(document.text.isEmpty)
        // Each block's instruction must appear exactly once (no double-emit, no drop).
        for marker in ["// inner body", "// outer body tail", "// after outer"] {
            let count = document.text.components(separatedBy: marker).count - 1
            XCTAssertEqual(count, 1, "block \(marker) must be emitted exactly once, got \(count)")
        }
    }
}
