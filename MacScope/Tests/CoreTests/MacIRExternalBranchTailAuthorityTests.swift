import XCTest
@testable import MacScope

// Machine bytes are retained vectors,
// except the explicitly synthetic mid-target and frame-guard counterexamples.
final class MacIRExternalBranchTailAuthorityTests: XCTestCase {
    private func row(_ address: UInt64, _ bytes: String, _ mnemonic: String,
                     _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: nil)
    }

    func testFourRetainedLeafWrappersWithIndependentVoidContracts() {
        let vectors: [(String, UInt64, String, UInt64, String)] = [
            ("_jpeg_destroy_compress", 0xe3c, "d3 69 00 14", 0x1b588, "_jpeg_destroy"),
            ("_jpeg_abort_compress", 0xe40, "bc 69 00 14", 0x1b530, "_jpeg_abort"),
            ("_jpeg_destroy_decompress", 0x213e0, "6a e8 ff 17", 0x1b588, "_jpeg_destroy"),
            ("_jpeg_abort_decompress", 0x213e4, "53 e8 ff 17", 0x1b530, "_jpeg_abort")
        ]
        // jpeglib.h declares both wrapper and generic callee void. These are
        // independent injected contracts, not inferred from a missing X0 read.
        for (name, start, bytes, target, callee) in vectors {
            let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
                name: name, startAddress: start,
                authoritativeReturnLocation: .void, authoritativeReturnType: "void",
                authoredCallSignaturesByTarget: [callee: .init(returnType: "void")],
                knownTailCallTargets: [target: callee],
                instructions: [row(start, bytes, "b", "0x" + String(target, radix: 16))])
            XCTAssertTrue(result.instructions.contains { if case .call = $0.operation { return true }; return false })
            XCTAssertEqual(result.instructions.last?.operation, .returnValue(nil))
            XCTAssertFalse(result.refusals.contains { $0.reason == .targetOutsideFunction })
        }
    }

    func testUnknownReturnAuthorityIsNotVoid() {
        let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: false).buildFunction(
            name: "_unknown_contract", startAddress: 0xe3c,
            knownTailCallTargets: [0x1b588: "_jpeg_destroy"],
            instructions: [row(0xe3c, "d3 69 00 14", "b", "0x1b588")])
        XCTAssertEqual(result.returnValue, .unknown("unresolved_return_contract"))
    }

    func testMidFunctionTargetDoesNotInheritStartIdentity() {
        // Synthetic B 0x1000 -> 0x2004; only 0x2000 is a proven start.
        let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
            name: "_mid_target", startAddress: 0x1000,
            knownTailCallTargets: [0x2000: "_callee"],
            instructions: [row(0x1000, "01 04 00 14", "b", "0x2004")])
        XCTAssertTrue(result.refusals.contains { $0.reason == .targetOutsideFunction })
        XCTAssertFalse(result.instructions.contains { if case .call = $0.operation { return true }; return false })
    }

    func testUnbalancedFrameMustRetainExternalBranchRefusal() {
        // Synthetic SUB SP,#16; B to exact known start. This expectation exposes
        // the preimage CFG gap; the postimage must honor per-site frame proof.
        let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
            name: "_frame_guard", startAddress: 0x1000,
            knownTailCallTargets: [0x2000: "_callee"],
            instructions: [row(0x1000, "ff 43 00 d1", "sub", "sp, sp, #0x10"),
                           row(0x1004, "ff 03 00 14", "b", "0x2000")])
        XCTAssertFalse(result.instructions.contains { if case .call = $0.operation { return true }; return false })
        XCTAssertTrue(result.refusals.contains { $0.reason == .targetOutsideFunction })
    }

    func testOneProvenSiteCannotMaskAnotherSiteToSameTarget() {
        let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
            name: "_same_target", startAddress: 0x1000,
            knownTailCallTargets: [0x2000: "_callee"],
            instructions: [row(0x1000, "00 04 00 14", "b", "0x2000"),
                           row(0x1004, "ff 03 00 14", "b", "0x2000")])
        XCTAssertFalse(result.refusals.contains {
            $0.reason == .targetOutsideFunction && $0.scope == .row(0x1000)
        })
        XCTAssertTrue(result.refusals.contains {
            $0.reason == .targetOutsideFunction && $0.scope == .row(0x1004)
        })
    }

    func testDuplicateAddressRowsCannotBorrowTailProof() {
        let ambiguous = [row(0x1000, "00 04 00 14", "b", "0x2000"),
                         row(0x1000, "00 08 00 14", "b", "0x3000")]
        let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true).buildFunction(
            name: "_duplicate_site", startAddress: 0x1000,
            knownTailCallTargets: [0x2000: "_first", 0x3000: "_second"],
            instructions: ambiguous)
        XCTAssertFalse(result.instructions.contains { if case .call = $0.operation { return true }; return false })
        XCTAssertTrue(result.refusals.contains { $0.reason == .targetOutsideFunction })
        XCTAssertTrue(MacIRBuilder.provenTailCalls(rows: ambiguous, entry: 0x1000,
            knownTargets: [0x2000: "_first", 0x3000: "_second"], recoveredSwitches: []).isEmpty)
    }

    private func declaredTailSnapshot(
        rows: [InstructionRow], start: UInt64 = 0x1000, end: UInt64? = nil,
        target: UInt64 = 0x2000, sourceName: String = "_declared_source",
        targetName: String = "_declared_callee", callerType: String? = "void",
        calleeType: String? = "void", extras: [FunctionSummary] = []
    ) -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: sourceName, startAddress: start,
                endAddress: end ?? (rows.last!.address + 4), confidence: 1),
            FunctionSummary(id: UUID(), name: targetName, startAddress: target,
                endAddress: target + 4, confidence: 1)
        ] + extras
        analysis.instructions = rows
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture",
            path: "/fixture/declared-tail", kind: "executable", architecture: "arm64", slot: .primary),
            analysis: analysis)
        if let callerType {
            snapshot.addressOverrides[.primary(start)] = AddressOverride(
                signature: .init(returnType: callerType))
        }
        if let calleeType {
            snapshot.addressOverrides[.primary(target)] = AddressOverride(
                signature: .init(returnType: calleeType))
        }
        return snapshot
    }

    private func buildDeclaredTail(_ input: PseudocodeRenderInput) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            knownTailCallTargets: input.knownTailCallTargets,
            instructions: input.instructions)
    }

    private func assertDeclaredLeafTail(name: String, start: UInt64, bytes: String,
                                        target: UInt64, callee: String) {
        // Fresh inputs in each mode: an SSA handoff is not reused as legacy authority.
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                MacIRConfiguration.$returnContractOverride.withValue(false) {
                    let snapshot = declaredTailSnapshot(
                        rows: [row(start, bytes, "b", "0x" + String(target, radix: 16))],
                        start: start, target: target, sourceName: name, targetName: callee)
                    let input = snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary)
                    XCTAssertEqual(input.knownTailCallTargets[target], enabled ? callee : nil)
                    let function = buildDeclaredTail(input)
                    XCTAssertEqual(function.instructions.contains {
                        if case .call = $0.operation { return true }; return false
                    }, enabled)
                    if enabled {
                        XCTAssertEqual(function.instructions.last?.operation, .returnValue(nil))
                        XCTAssertFalse(function.refusals.contains { $0.reason == .targetOutsideFunction })
                    }
                }
            }
        }
    }

    func testDeclaredVoidCompressionWrappersUseSSAOnlyIdentityHandoff() {
        assertDeclaredLeafTail(name: "_jpeg_destroy_compress", start: 0xe3c,
            bytes: "d3 69 00 14", target: 0x1b588, callee: "_jpeg_destroy")
        assertDeclaredLeafTail(name: "_jpeg_abort_compress", start: 0xe40,
            bytes: "bc 69 00 14", target: 0x1b530, callee: "_jpeg_abort")
    }

    func testDeclaredVoidDecompressionWrappersUseSSAOnlyIdentityHandoff() {
        assertDeclaredLeafTail(name: "_jpeg_destroy_decompress", start: 0x213e0,
            bytes: "6a e8 ff 17", target: 0x1b588, callee: "_jpeg_destroy")
        assertDeclaredLeafTail(name: "_jpeg_abort_decompress", start: 0x213e4,
            bytes: "53 e8 ff 17", target: 0x1b530, callee: "_jpeg_abort")
    }

    func testVoidTailHandoffDoesNotInventEitherContractOrUniqueIdentity() {
        MacIRConfiguration.$ssaOverride.withValue(true) {
            MacIRConfiguration.$returnContractOverride.withValue(false) {
                let rows = [row(0x1000, "00 04 00 14", "b", "0x2000")]
                let duplicateTarget = FunctionSummary(id: UUID(), name: "_other",
                    startAddress: 0x2000, endAddress: 0x2004, confidence: 1)
                let duplicateName = FunctionSummary(id: UUID(), name: "_declared_callee",
                    startAddress: 0x3000, endAddress: 0x3004, confidence: 1)
                let duplicateSource = FunctionSummary(id: UUID(), name: "_other_source",
                    startAddress: 0x1000, endAddress: 0x1004, confidence: 1)
                let cases = [
                    declaredTailSnapshot(rows: rows, callerType: nil),
                    declaredTailSnapshot(rows: rows, calleeType: nil),
                    declaredTailSnapshot(rows: rows, callerType: "uint32_t"),
                    declaredTailSnapshot(rows: rows, calleeType: "uint32_t"),
                    declaredTailSnapshot(rows: rows, targetName: ""),
                    declaredTailSnapshot(rows: rows, targetName: " _padded "),
                    declaredTailSnapshot(rows: rows, targetName: "_first,_second"),
                    declaredTailSnapshot(rows: rows, targetName: "x8"),
                    declaredTailSnapshot(rows: rows, extras: [duplicateTarget]),
                    declaredTailSnapshot(rows: rows, extras: [duplicateName]),
                    declaredTailSnapshot(rows: rows, extras: [duplicateSource])
                ]
                for snapshot in cases {
                    let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                    XCTAssertEqual(input.instructions.map(\.address), [0x1000])
                    XCTAssertTrue(input.knownTailCallTargets.isEmpty)
                    let function = buildDeclaredTail(input)
                    XCTAssertFalse(function.instructions.contains {
                        if case .call = $0.operation { return true }; return false
                    })
                    XCTAssertTrue(function.refusals.contains { $0.reason == .targetOutsideFunction })
                }
            }
        }
    }

    func testVoidTailHandoffRetainsPerSiteFrameAndExactTargetChecks() {
        MacIRConfiguration.$ssaOverride.withValue(true) {
            MacIRConfiguration.$returnContractOverride.withValue(false) {
                let cases = [
                    [row(0x1000, "ff 43 00 d1", "sub", "sp, sp, #0x10"),
                     row(0x1004, "ff 03 00 14", "b", "0x2000")],
                    [row(0x1000, "01 04 00 14", "b", "0x2004")]
                ]
                for rows in cases {
                    let input = declaredTailSnapshot(rows: rows)
                        .pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                    XCTAssertEqual(input.knownTailCallTargets[0x2000], "_declared_callee")
                    let function = buildDeclaredTail(input)
                    XCTAssertFalse(function.instructions.contains {
                        if case .call = $0.operation { return true }; return false
                    })
                    XCTAssertTrue(function.refusals.contains { $0.reason == .targetOutsideFunction })
                }
            }
        }
    }

    func testVoidTailHandoffRejectsIntraFunctionTargetBeyondRetainedRows() {
        MacIRConfiguration.$ssaOverride.withValue(true) {
            MacIRConfiguration.$returnContractOverride.withValue(false) {
                // Only the entry B is retained, but the declared owner includes 0x2000.
                // A second discovered start does not override that ownership interval.
                let snapshot = declaredTailSnapshot(
                    rows: [row(0x1000, "00 04 00 14", "b", "0x2000")], end: 0x2004)
                let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                XCTAssertTrue(input.knownTailCallTargets.isEmpty)
                let function = buildDeclaredTail(input)
                XCTAssertFalse(function.instructions.contains {
                    if case .call = $0.operation { return true }; return false
                })
                XCTAssertTrue(function.refusals.contains { $0.reason == .targetOutsideFunction })
            }
        }
    }

    func testVoidTailHandoffKeepsIndirectTransferBarrier() {
        MacIRConfiguration.$ssaOverride.withValue(true) {
            MacIRConfiguration.$returnContractOverride.withValue(false) {
                for (bytes, mnemonic) in [("00 01 1f d6", "br"), ("00 01 3f d6", "blr")] {
                    let snapshot = declaredTailSnapshot(rows: [
                        row(0x1000, bytes, mnemonic, "x8"),
                        row(0x1004, "ff 03 00 14", "b", "0x2000")])
                    let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                    XCTAssertTrue(input.knownTailCallTargets.isEmpty)
                }
            }
        }
    }

    func testVoidTailHandoffDoesNotReclassifySourceJumpTableAuthority() {
        MacIRConfiguration.$ssaOverride.withValue(true) {
            MacIRConfiguration.$returnContractOverride.withValue(false) {
                let rows = [row(0x1000, "00 04 00 14", "b", "0x2000")]
                var snapshot = declaredTailSnapshot(rows: rows)
                // Even conflicting source-row switch authority prevents this fallback.
                snapshot.jumpTables = [0x1000: [0x2000]]
                XCTAssertTrue(snapshot.pseudocodeRenderInput(selectedAddress: 0x1000,
                    in: .primary).knownTailCallTargets.isEmpty)
                // An unrelated image-wide table must not block this direct leaf.
                snapshot.jumpTables = [0x3000: [0x4000]]
                XCTAssertEqual(snapshot.pseudocodeRenderInput(selectedAddress: 0x1000,
                    in: .primary).knownTailCallTargets[0x2000], "_declared_callee")
            }
        }
    }

    func testVoidTailHandoffRejectsUnknownDeclaredSourceExtent() {
        MacIRConfiguration.$ssaOverride.withValue(true) {
            MacIRConfiguration.$returnContractOverride.withValue(false) {
                for end in [UInt64(0x1000), UInt64(0x0ffc)] {
                    let snapshot = declaredTailSnapshot(
                        rows: [row(0x1000, "00 04 00 14", "b", "0x2000")], end: end)
                    let source = snapshot.analysis(in: .primary)!.functions[0]
                    // The exact-ID API explicitly retains the entry row for a degenerate range.
                    guard let input = snapshot.pseudocodeRenderInput(exactFunctionID: source.id,
                        in: .primary) else { XCTFail("missing exact source fixture"); continue }
                    XCTAssertEqual(input.instructions.map(\.address), [0x1000])
                    XCTAssertTrue(input.knownTailCallTargets.isEmpty)
                    let function = buildDeclaredTail(input)
                    XCTAssertTrue(function.refusals.contains { $0.reason == .targetOutsideFunction })
                    XCTAssertFalse(function.instructions.contains {
                        if case .call = $0.operation { return true }; return false
                    })
                }
            }
        }
    }

    // Synthetic A64 words are fixed vectors, not assembled/decoded at runtime.
    // Each assertion covers legacy/SSA and return-contract OFF/ON independently.
    private func assertPathVector(_ rows: [InstructionRow], terminal: UInt64,
                                  certified: Bool, admitted: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let admission = admitted ?? certified
        let proofRows = rows.map { MacIRTailCallProof.Instruction(address: $0.address,
            mnemonic: $0.mnemonic, operands: $0.operands) }
        let decision = MacIRTailCallProof.certifyRetainedFramePaths(proofRows,
            at: rows.firstIndex { $0.address == terminal }!, entry: 0x1000,
            knownFunctionStarts: [0x2000], recoveredSwitches: [])
        XCTAssertEqual(decision.certified, certified, decision.reason, file: file, line: line)
        for ssa in [false, true] {
            for contracts in [false, true] {
                MacIRConfiguration.$returnContractOverride.withValue(contracts) {
                    let tails = MacIRBuilder.provenTailCalls(rows: rows, entry: 0x1000,
                        knownTargets: [0x2000: "_path_target"], recoveredSwitches: [],
                        pathCompleteEnabled: ssa && contracts)
                    XCTAssertEqual(tails[terminal] != nil, admission && ssa && contracts,
                                   file: file, line: line)
                    let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa).buildFunction(
                        name: "_path_source", startAddress: 0x1000,
                        knownTailCallTargets: [0x2000: "_path_target"], instructions: rows)
                    XCTAssertEqual(result.instructions.contains { instruction in
                        guard instruction.source.address == terminal else { return false }
                        if case .call = instruction.operation { return true }
                        return false
                    }, admission && ssa && contracts, file: file, line: line)
                    if admission && ssa && contracts {
                        XCTAssertTrue(result.instructions.contains {
                            $0.operation == .returnValue(.unknown("unresolved_return_contract"))
                        }, file: file, line: line)
                    }
                }
            }
        }
    }

    private func diamond(_ middle: InstructionRow? = nil) -> [InstructionRow] {
        [row(0x1000, "60 00 00 b4", "cbz", "x0, 0x100c"),
         middle ?? row(0x1004, "1f 20 03 d5", "nop", ""),
         row(0x1008, "02 00 00 14", "b", "0x1010"),
         row(0x100c, "1f 20 03 d5", "nop", ""),
         row(0x1010, "fc 03 00 14", "b", "0x2000")]
    }

    func testPathCompleteFramelessDiamondPreservesUnknownReturn() {
        assertPathVector(diamond(), terminal: 0x1010, certified: true)
    }

    func testPathCompleteFramelessConditionalJoin() {
        assertPathVector([row(0x1000, "40 00 00 b4", "cbz", "x0, 0x1008"),
            row(0x1004, "1f 20 03 d5", "nop", ""),
            row(0x1008, "fe 03 00 14", "b", "0x2000")], terminal: 0x1008, certified: true)
    }

    func testPathCompleteEqualStateBackedgeConvergesWithoutAnalyzabilityClaim() {
        assertPathVector([row(0x1000, "60 00 00 b4", "cbz", "x0, 0x100c"),
            row(0x1004, "1f 20 03 d5", "nop", ""),
            row(0x1008, "fe ff ff 17", "b", "0x1000"),
            row(0x100c, "fd 03 00 14", "b", "0x2000")], terminal: 0x100c, certified: true)
    }

    private func restoredFrame(_ mutation: InstructionRow? = nil) -> [InstructionRow] {
        [row(0x1000, "fd 7b bf a9", "stp", "x29, x30, [sp, #-0x10]!"),
         row(0x1004, "fd 03 00 91", "mov", "x29, sp"),
         row(0x1008, "fe 03 1f aa", "mov", "x30, xzr"),
         row(0x100c, "60 00 00 b4", "cbz", "x0, 0x1018"),
         mutation ?? row(0x1010, "1f 20 03 d5", "nop", ""),
         row(0x1014, "02 00 00 14", "b", "0x101c"),
         row(0x1018, "1f 20 03 d5", "nop", ""),
         row(0x101c, "fd 7b c1 a8", "ldp", "x29, x30, [sp], #0x10"),
         row(0x1020, "f8 03 00 14", "b", "0x2000")]
    }

    func testPathCompleteSavedLRDiamondRestoresExactEntryValue() {
        assertPathVector(restoredFrame(), terminal: 0x1020, certified: true)
    }

    func testPathCompleteFPAliasLoadRestoresExactLR() {
        var rows = restoredFrame()
        rows[7] = row(0x101c, "be 07 40 f9", "ldr", "x30, [x29, #0x8]")
        rows[8] = row(0x1020, "ff 43 00 91", "add", "sp, sp, #0x10")
        rows.append(row(0x1024, "f7 03 00 14", "b", "0x2000"))
        assertPathVector(rows, terminal: 0x1024, certified: true)
        let facts = MacIRTailCallProof.certifyRetainedFramePaths(rows.map {
            .init(address: $0.address, mnemonic: $0.mnemonic, operands: $0.operands)
        }, at: 9, entry: 0x1000, knownFunctionStarts: [0x2000], recoveredSwitches: [])
        XCTAssertFalse(facts.entryFPPreserved) // LR restoration does not establish entry-FP preservation.
    }

    func testPathCompleteCopiedLRTokenSurvivesDiamond() {
        var rows = diamond()
        rows.insert(row(0x0ffc, "e9 03 1e aa", "mov", "x9, x30"), at: 0)
        // Relocate the fixed vector by four bytes; branch displacements stay fixed.
        rows = rows.map { row($0.address + 4, $0.bytes, $0.mnemonic,
            $0.operands == "x0, 0x100c" ? "x0, 0x1010" : $0.operands == "0x1010" ? "0x1014" : $0.operands) }
        rows[2] = row(0x1008, "fe 03 09 aa", "mov", "x30, x9")
        rows[5] = row(0x1014, "fb 03 00 14", "b", "0x2000")
        assertPathVector(rows, terminal: 0x1014, certified: true)
    }

    func testPathCompleteOneBadSPPathVetoesGoodSibling() {
        assertPathVector(diamond(row(0x1004, "ff 43 00 d1", "sub", "sp, sp, #0x10")),
                         terminal: 0x1010, certified: false)
    }

    func testPathCompleteOneBadLRPathVetoesGoodSibling() {
        assertPathVector(diamond(row(0x1004, "fe 03 1f aa", "mov", "x30, xzr")),
                         terminal: 0x1010, certified: false)
    }

    func testPathCompletePartialSavedLRStoreVetoesRestore() {
        assertPathVector(restoredFrame(row(0x1010, "bf 23 00 39", "strb", "wzr, [x29, #0x8]")),
                         terminal: 0x1020, certified: false)
    }

    func testPathCompleteUnknownAliasStoreVetoesSavedSlot() {
        assertPathVector(restoredFrame(row(0x1010, "1f 00 00 f9", "str", "xzr, [x0]")),
                         terminal: 0x1020, certified: false)
    }

    func testPathCompleteEscapedStackAcrossCallRemainsRefused() {
        var rows = restoredFrame(row(0x1010, "e0 03 00 91", "mov", "x0, sp"))
        rows[6] = row(0x1018, "00 01 3f d6", "blr", "x8")
        assertPathVector(rows, terminal: 0x1020, certified: false)
    }

    func testPathCompleteChangingLoopStateRefuses() {
        assertPathVector([row(0x1000, "60 00 00 b4", "cbz", "x0, 0x100c"),
            row(0x1004, "ff 43 00 d1", "sub", "sp, sp, #0x10"),
            row(0x1008, "fe ff ff 17", "b", "0x1000"),
            row(0x100c, "fd 03 00 14", "b", "0x2000")], terminal: 0x100c, certified: false)
    }

    func testPathCompleteUnreachableIncomingPredecessorRefuses() {
        assertPathVector([row(0x1000, "02 00 00 14", "b", "0x1008"),
            row(0x1004, "01 00 00 14", "b", "0x1008"),
            row(0x1008, "fe 03 00 14", "b", "0x2000")], terminal: 0x1008, certified: false)
    }

    func testPathCompleteOpaqueTargetCannotBorrowExactEntryAuthority() {
        var rows = diamond()
        rows[1] = row(0x1004, "00 01 1f d6", "br", "x8")
        assertPathVector(rows, terminal: 0x1010, certified: false)
        let intra = [row(0x1000, "40 00 00 b4", "cbz", "x0, 0x1008"),
            row(0x1004, "1f 20 03 d5", "nop", ""),
            row(0x1008, "fe ff ff 17", "b", "0x1000")]
        for enabled in [false, true] {
            XCTAssertTrue(MacIRBuilder.provenTailCalls(rows: intra, entry: 0x1000,
                knownTargets: [0x1000: "_same_entry"], recoveredSwitches: [],
                pathCompleteEnabled: enabled).isEmpty)
        }
    }

    private func indexedLoadSidecar(width: Int = 64, writeback: Bool = false) -> InstructionRow {
        var instruction = row(0x1004, "2a 79 68 f8", "ldr", "x10, [x9, x8, lsl #3]")
        instruction.structuredOperands = .init(coverage: .complete, opcodeClass: "ldr",
            operands: [.register(.init(index: 10, width: 64)),
                .memory(.init(base: .init(index: 9, width: 64), index: .init(index: 8, width: 64),
                    modifier: .init(.lsl, amount: 3), writeback: writeback))],
            presentation: .init(mnemonic: "ldr"),
            semantics: .init(memoryAccessWidth: width, memoryAccess: .read))
        return instruction
    }

    func testPathCompleteIndexedSidecarAgreesWithoutChangingDefaultGate() {
        assertPathVector(diamond(indexedLoadSidecar()), terminal: 0x1010, certified: true)
    }

    func testPathCompleteSidecarWidthMismatchRefusesAdmission() {
        assertPathVector(diamond(indexedLoadSidecar(width: 32)), terminal: 0x1010,
                         certified: true, admitted: false)
    }

    func testPathCompleteSidecarHiddenWritebackRefusesAdmission() {
        assertPathVector(diamond(indexedLoadSidecar(writeback: true)), terminal: 0x1010,
                         certified: true, admitted: false)
    }

    func testPathCompleteDoesNotChangeExistingNumericLeafOrOrdinaryBL() {
        let leaf = [row(0x1000, "00 04 00 14", "b", "0x2000")]
        let ordinary = [row(0x1000, "00 04 00 94", "bl", "0x2000"),
                        row(0x1004, "c0 03 5f d6", "ret", "")]
        for ssa in [false, true] {
            for contracts in [false, true] {
                MacIRConfiguration.$returnContractOverride.withValue(contracts) {
                    let tails = MacIRBuilder.provenTailCalls(rows: leaf, entry: 0x1000,
                        knownTargets: [0x2000: ""], recoveredSwitches: [],
                        pathCompleteEnabled: ssa && contracts)
                    XCTAssertEqual(tails[0x1000]?.callOperands, "0x2000")
                    let result = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa).buildFunction(
                        name: "_ordinary", startAddress: 0x1000,
                        authoritativeReturnLocation: .void, authoritativeReturnType: "void",
                        knownTailCallTargets: [0x2000: ""], instructions: ordinary)
                    XCTAssertEqual(result.instructions.filter { if case .call = $0.operation { return true }; return false }.count, 1)
                    XCTAssertFalse(result.refusals.contains { $0.reason == .targetOutsideFunction })
                }
            }
        }
    }
}
